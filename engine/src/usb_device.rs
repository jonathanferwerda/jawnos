//! Direct-USB (usbfs) capture and monitor, without `libusb` or `rusb`.
//!
//! Android's `android.hardware.usb.UsbRequest` speaks only bulk and interrupt
//! transfers, so a UAC1 isochronous stream cannot be built on it. The kernel's
//! `usbfs` interface *can* carry iso URBs, and `UsbDeviceConnection` exposes the
//! connection's own fd, so this module submits `USBDEVFS_SUBMITURB` directly on
//! that fd. The gate is proven: on a Behringer UM2 (UAC1, full speed, 48 kHz,
//! 1 ms frames) 37 of 41 URBs completed with status 0, ~192 bytes per packet,
//! 48,160 frames in 300 ms, real voice.
//!
//! The safety properties mirror the C++ reference (`JawnUsbIso.cpp`):
//!
//! - each URB's struct image and its audio slice live in buffers allocated once,
//!   before the first submit, and are never resized or moved while in flight;
//! - every buffer is freed only after the kernel has returned its URB; an URB
//!   still outstanding after the bounded cleanup is deliberately **leaked**,
//!   because freeing memory the kernel may still write is worse;
//! - the fd is **never closed** — Java owns it;
//! - the reap path does no allocation, takes no lock, logs nothing and does no
//!   I/O. It absorbs completion fields into fixed-size counters and resubmits.
//!
//! Only the syscall glue is `#[cfg(target_os = "android")]`. The kernel structs,
//! the ioctl numbers, the monitor fifo and the report are compiled everywhere so
//! a host can unit-test them.
//!
//! Capture feeds two destinations: the **record ring** the take's `drain_ring`
//! writes to disk (the same shape and strip the Oboe take uses; still a
//! `monbus` ring to the drain thread) and a **monitor fifo** the optional
//! playback endpoint fills from. Both the absorb and the OUT fill run on the
//! same USB thread, so the monitor has no cross-thread ring: its fifo is trimmed
//! at a high water instead of being bursted into from a second queue.
//!
//! The four depth numbers (IN URBs, IN packets per URB, OUT URBs, OUT packets
//! per URB) are one process-wide setting — `jawn_audio_set_usb_depth` — read once
//! when a take starts, so the monitor runway can be swept from 8 ms down to
//! 1–2 ms. `jawn_audio_roundtrip_usb` measures the cable loop with the kernel's
//! USB bus frame numbers (`urb.start_frame`) rather than the wall clock.

#![allow(dead_code)]

use std::ffi::CStr;
use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;

use crate::control::{error_json, into_c_string, json_escape, lock_control};
use crate::monbus;
use crate::plan::ChannelPlan;
#[cfg(target_os = "android")]
use crate::roundtrip as rt;

/// The rate a UAC1 full-speed device on this path runs at. The report carries
/// it so a WAV and a sidecar agree with the frames the kernel handed over.
pub const USB_RATE: u32 = 48_000;

/// Capture URBs in flight. Four 8-packet URBs cover 32 ms at 1 ms/packet: the
/// jitter runway the IN side needs to ride out a scheduling gap.
pub(crate) const URB_COUNT: usize = 4;
/// Isochronous packets in each capture URB.
pub(crate) const PACKETS_PER_URB: usize = 8;

/// Monitor (OUT) URBs in flight. The two directions have different jobs: the IN
/// runway absorbs jitter, while every queued OUT URB is *latency* the person
/// hears. Two 4-packet URBs are 8 ms of runway instead of 32.
pub(crate) const OUT_URB_COUNT: usize = 2;
/// Isochronous packets in each monitor URB.
pub(crate) const OUT_PACKETS_PER_URB: usize = 4;

/// Every depth dimension is clamped into this inclusive range. It is also the
/// range a take may be swept over: eight 8-packet URBs is already 64 ms of IN
/// runway. The OUT side has the higher floor [`OUT_URBS_MIN`] — two 1-packet
/// URBs are the shortest monitor that still keeps one URB in flight. Values
/// beyond [`DEPTH_SANE_MAX`] are nonsense rather than something to clamp
/// silently.
pub(crate) const DEPTH_MIN: i32 = 1;
pub(crate) const DEPTH_MAX: i32 = 8;
pub(crate) const DEPTH_SANE_MAX: i32 = 64;

/// The monitor needs at least two URBs in flight. With one, the next URB is only
/// submitted after the previous completes, leaving a scheduling hole of several
/// hundred microseconds every millisecond; the device hears a discontinuous
/// stream as static and the fifo backs up and trims. With two, one URB is always
/// in the host/device pipeline while the other is being refilled.
pub(crate) const OUT_URBS_MIN: i32 = 2;

/// The four numbers that shape a take. Read once at the start of
/// [`run_usb_plan`], so a depth change while a take runs applies to the next
/// one, never to a stream whose buffers are already in flight.
///
/// The monitor's average added latency is roughly
/// `in_packets / 2 + out_urbs * out_packets` ms: half an IN URB of capture
/// batching plus the whole OUT runway. That is a budget comment, not a promise
/// the report makes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct UsbDepth {
    pub(crate) in_urbs: usize,
    pub(crate) in_packets: usize,
    pub(crate) out_urbs: usize,
    pub(crate) out_packets: usize,
}

impl UsbDepth {
    /// The landed take's depth: four 8-packet IN URBs and two 4-packet OUT
    /// URBs (32 ms of capture runway, 8 ms of monitor runway).
    pub(crate) const DEFAULT: UsbDepth = UsbDepth {
        in_urbs: URB_COUNT,
        in_packets: PACKETS_PER_URB,
        out_urbs: OUT_URB_COUNT,
        out_packets: OUT_PACKETS_PER_URB,
    };

    /// Validate the C ABI's four numbers: a negative value or one past
    /// [`DEPTH_SANE_MAX`] is a refusal, everything else is clamped into
    /// [`DEPTH_MIN`]..=[`DEPTH_MAX`]. `out_urbs` has its own floor of
    /// [`OUT_URBS_MIN`]: a single OUT URB in flight leaves a hole every URB.
    fn from_args(in_urbs: i32, in_packets: i32, out_urbs: i32, out_packets: i32) -> Result<Self, String> {
        let values = [
            ("in_urbs", in_urbs),
            ("in_packets", in_packets),
            ("out_urbs", out_urbs),
            ("out_packets", out_packets),
        ];
        for (name, value) in values {
            if value < 0 {
                return Err(format!("{name} is {value}; a depth cannot be negative"));
            }
            if value > DEPTH_SANE_MAX {
                return Err(format!(
                    "{name} is {value}; {DEPTH_SANE_MAX} is already far past the {DEPTH_MAX} maximum"
                ));
            }
        }
        Ok(UsbDepth {
            in_urbs: in_urbs.clamp(DEPTH_MIN, DEPTH_MAX) as usize,
            in_packets: in_packets.clamp(DEPTH_MIN, DEPTH_MAX) as usize,
            out_urbs: out_urbs.clamp(OUT_URBS_MIN, DEPTH_MAX) as usize,
            out_packets: out_packets.clamp(DEPTH_MIN, DEPTH_MAX) as usize,
        })
    }

    /// The OUT runway: every queued packet is 1 ms of audio at 48 kHz.
    pub(crate) fn monitor_ms(self) -> u32 {
        (self.out_urbs * self.out_packets) as u32
    }

    /// How long one IN URB's worth of packets covers; also the batching half of
    /// the monitor's added latency.
    pub(crate) fn in_delivery_ms(self) -> u32 {
        self.in_packets as u32
    }

    /// Frames the monitor must hold before its first OUT submit: the whole OUT
    /// depth, at the configured packet size.
    pub(crate) fn prime_frames(self, frames_per_packet: usize) -> usize {
        self.out_urbs * self.out_packets * frames_per_packet
    }
}

// The process-wide depth, packed into one word so a reader can never see two
// new numbers and two old ones. A take re-reads it once before allocating.
const fn pack_depth(depth: UsbDepth) -> u64 {
    (depth.in_urbs as u64)
        | ((depth.in_packets as u64) << 8)
        | ((depth.out_urbs as u64) << 16)
        | ((depth.out_packets as u64) << 24)
}

fn unpack_depth(bits: u64) -> UsbDepth {
    UsbDepth {
        in_urbs: ((bits & 0xff) as i32).clamp(DEPTH_MIN, DEPTH_MAX) as usize,
        in_packets: (((bits >> 8) & 0xff) as i32).clamp(DEPTH_MIN, DEPTH_MAX) as usize,
        out_urbs: (((bits >> 16) & 0xff) as i32).clamp(OUT_URBS_MIN, DEPTH_MAX) as usize,
        out_packets: (((bits >> 24) & 0xff) as i32).clamp(DEPTH_MIN, DEPTH_MAX) as usize,
    }
}

static USB_DEPTH: AtomicU64 = AtomicU64::new(pack_depth(UsbDepth::DEFAULT));

/// The depth a take started now would use.
pub(crate) fn current_depth() -> UsbDepth {
    unpack_depth(USB_DEPTH.load(Ordering::Relaxed))
}

fn store_depth(depth: UsbDepth) {
    USB_DEPTH.store(pack_depth(depth), Ordering::Relaxed);
}

fn depth_json(depth: UsbDepth) -> String {
    format!(
        "{{\"urbs\":{},\"packets\":{}}}",
        depth.in_urbs, depth.in_packets
    )
}

fn out_depth_json(depth: UsbDepth) -> String {
    format!(
        "{{\"urbs\":{},\"packets\":{}}}",
        depth.out_urbs, depth.out_packets
    )
}

fn depth_status_json(depth: UsbDepth) -> String {
    format!(
        "{{\"ok\":true,\"in_depth\":{},\"out_depth\":{},\"out_urbs_effective\":{},\"monitor_ms\":{},\"in_delivery_ms\":{}}}",
        depth_json(depth),
        out_depth_json(depth),
        depth.out_urbs,
        depth.monitor_ms(),
        depth.in_delivery_ms()
    )
}

/// How long the monitor may be primed before the first OUT submit. Long enough
/// for a few 1 ms capture packets, short enough that a silent device cannot
/// stall the take's start.
pub(crate) const PRIME_TIMEOUT_MS: u64 = 100;

/// `USBDEVFS_URB_TYPE_ISO` is 0, not 1. Getting this wrong submits a control
/// URB with an iso struct and the kernel rejects every one.
pub const USBDEVFS_URB_TYPE_ISO: u8 = 0;
/// Start the URB as soon as the bus is free rather than at `start_frame`.
pub const USBDEVFS_URB_ISO_ASAP: u32 = 0x02;

/// The monitor fifo's jitter allowance, in frames, on top of the whole OUT
/// depth. A producer that runs further ahead than this is trimmed from the
/// oldest end so the monitor's latency cannot grow without bound.
pub(crate) const OUT_BACKLOG_FRAMES: usize = 96;

/// The kernel's packet status for a missed frame (`-EXDEV`).
const EXDEV: i32 = -18;

// --- the kernel's usbfs structs (arm64 / LP64) -------------------------------

/// `struct usbdevfs_iso_packet_desc`.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct UsbdevfsIsoPacketDesc {
    pub length: u32,
    pub actual_length: u32,
    pub status: u32,
}

/// `struct usbdevfs_urb`, *without* the trailing flexible array of packet
/// descriptors. The image on the heap is this header followed by
/// `number_of_packets` [`UsbdevfsIsoPacketDesc`]s.
#[repr(C)]
pub struct UsbdevfsUrb {
    pub type_: u8,
    pub endpoint: u8,
    pub status: i32,
    pub flags: u32,
    pub buffer: *mut c_void,
    pub buffer_length: i32,
    pub actual_length: i32,
    pub start_frame: i32,
    pub number_of_packets: i32,
    pub error_count: i32,
    pub signr: u32,
    pub usercontext: *mut c_void,
}

/// `struct usbdevfs_ctrltransfer`.
#[repr(C)]
pub struct UsbdevfsCtrlTransfer {
    pub request_type: u8,
    pub request: u8,
    pub value: u16,
    pub index: u16,
    pub length: u16,
    pub timeout: u32,
    pub data: *mut c_void,
}

/// `struct usbdevfs_setinterface`.
#[repr(C)]
pub struct UsbdevfsSetInterface {
    pub interface: u32,
    pub altsetting: u32,
}

const URB_BYTES: usize = std::mem::size_of::<UsbdevfsUrb>();
const DESC_BYTES: usize = std::mem::size_of::<UsbdevfsIsoPacketDesc>();

// A wrong `sizeof` corrupts an ioctl instead of failing it, so the layouts are
// asserted at compile time against the arm64-v8a header values.
const _: () = assert!(std::mem::size_of::<UsbdevfsIsoPacketDesc>() == 12);
const _: () = assert!(std::mem::size_of::<UsbdevfsUrb>() == 56);
const _: () = assert!(std::mem::size_of::<UsbdevfsCtrlTransfer>() == 24);
const _: () = assert!(std::mem::size_of::<UsbdevfsSetInterface>() == 8);

// --- the ioctl numbers -------------------------------------------------------

/// `_IOC(dir, type, nr, size)` as the kernel's `<asm-generic/ioctl.h>` spells
/// it. `dir` is 2 bits (none/write/read/read-write), `type` 8, `nr` 8, `size`
/// 14.
const fn ioc(dir: u32, ty: u32, nr: u32, size: u32) -> u64 {
    ((dir << 30) | (ty << 8) | nr | (size << 16)) as u64
}

const U: u32 = b'U' as u32;
const IOC_NONE: u32 = 0;
const IOC_WRITE: u32 = 1;
const IOC_READ: u32 = 2;
const IOC_READ_WRITE: u32 = 3;

pub const USBDEVFS_CONTROL: u64 = 0xC018_5500;
pub const USBDEVFS_SETINTERFACE: u64 = 0x8008_5504;
pub const USBDEVFS_SUBMITURB: u64 = 0x8038_550A;
pub const USBDEVFS_DISCARDURB: u64 = 0x0000_550B;
pub const USBDEVFS_REAPURBNDELAY: u64 = 0x4008_550D;
pub const USBDEVFS_CLAIMINTERFACE: u64 = 0x8004_550F;
pub const USBDEVFS_RELEASEINTERFACE: u64 = 0x8004_5510;

/// `SCHED_FIFO` on Linux. The USB thread asks for it, records the answer and
/// keeps running at whatever policy it got.
const SCHED_FIFO: i32 = 1;
const SCHED_PRIORITY: i32 = 80;

// --- the URB image -----------------------------------------------------------

/// One URB's memory: the 56-byte header plus its packet descriptors, in
/// 8-byte words. A `Vec<u8>` would not promise the alignment the kernel writes
/// a `#[repr(C)]` struct through; a `Vec<u64>` does, and the extra tail bytes
/// past the header are simply never read.
///
/// The `Vec` must outlive the URB. The driver keeps every `Urb` alive until its
/// final reap (or leaks it).
pub(crate) struct Urb {
    words: Vec<u64>,
    packets: usize,
}

impl Urb {
    fn new(packets: usize) -> Self {
        let bytes = URB_BYTES + packets * DESC_BYTES;
        Urb {
            words: vec![0u64; (bytes + 7) / 8],
            packets,
        }
    }

    /// The header pointer. 8-aligned by construction (`Vec<u64>`).
    fn ptr(&mut self) -> *mut UsbdevfsUrb {
        self.words.as_mut_ptr() as *mut UsbdevfsUrb
    }

    fn byte_len(&self) -> usize {
        URB_BYTES + self.packets * DESC_BYTES
    }
}

/// Fill the header and every descriptor's request length. Called once, before
/// the first submit; resubmits use [`clear_urb`] so the request fields stay.
///
/// # Safety
/// `urb` must point at a live [`Urb`] image of at least
/// `URB_BYTES + packets * DESC_BYTES` bytes.
unsafe fn prepare_urb(
    urb: *mut UsbdevfsUrb,
    endpoint: u8,
    packet: usize,
    packets: usize,
    buffer: *mut c_void,
) {
    let header = &mut *urb;
    header.type_ = USBDEVFS_URB_TYPE_ISO;
    header.endpoint = endpoint;
    header.status = 0;
    header.flags = USBDEVFS_URB_ISO_ASAP;
    header.buffer = buffer;
    header.buffer_length = (packet * packets) as i32;
    header.actual_length = 0;
    header.start_frame = 0;
    header.number_of_packets = packets as i32;
    header.error_count = 0;
    header.signr = 0;
    header.usercontext = std::ptr::null_mut();
    let descs = (urb as *mut u8).add(URB_BYTES) as *mut UsbdevfsIsoPacketDesc;
    for index in 0..packets {
        let desc = &mut *descs.add(index);
        desc.length = packet as u32;
        desc.actual_length = 0;
        desc.status = 0;
    }
}

/// Reset the completion fields only. The request (`type`, `endpoint`, `flags`,
/// `buffer`, packet `length`s, packet count) is preserved for the resubmit.
///
/// # Safety
/// `urb` must point at a live, kernel-returned [`Urb`] image.
unsafe fn clear_urb(urb: *mut UsbdevfsUrb) {
    let header = &mut *urb;
    header.status = 0;
    header.actual_length = 0;
    header.error_count = 0;
    header.start_frame = 0;
    let packets = header.number_of_packets.max(0) as usize;
    let descs = (urb as *mut u8).add(URB_BYTES) as *mut UsbdevfsIsoPacketDesc;
    for index in 0..packets {
        let desc = &mut *descs.add(index);
        desc.actual_length = 0;
        desc.status = 0;
    }
}

// --- pure helpers ------------------------------------------------------------

/// Count one packet's `actual_length` into a fixed histogram. Index `i` is the
/// length; the last bucket collects everything longer than the expected packet
/// (index `packet + 1`) so the table is bounded.
fn record_packet_length(histogram: &mut [u64], length: usize) {
    if histogram.is_empty() {
        return;
    }
    let index = length.min(histogram.len() - 1);
    histogram[index] += 1;
}

/// Non-zero buckets as `(length, count)`, ascending. The last index, when
/// present, means "longer than one packet".
fn histogram_rows(histogram: &[u64]) -> Vec<(u32, u64)> {
    histogram
        .iter()
        .enumerate()
        .filter(|(_, count)| **count > 0)
        .map(|(length, count)| (length as u32, *count))
        .collect()
}

/// The monitor's playback latency, in whole milliseconds: every queued OUT
/// packet is 1 ms of audio, so the depth times the packet is the runway.
fn monitor_runway_ms(urb_count: usize, packets_per_urb: usize, packet: usize, rate: u32) -> u32 {
    if rate == 0 {
        return 0;
    }
    let frames = urb_count * packets_per_urb * (packet / 4);
    ((frames as u64 * 1000 + (rate as u64) / 2) / rate as u64) as u32
}

/// The monitor fifo's physical size: the priming runway, one IN burst, one OUT
/// burst and the backlog bound. The headroom above the high water is what lets a
/// capture burst arrive without dropping frames the OUT side is about to play.
fn monitor_fifo_capacity(
    prime_frames: usize,
    frames_in_burst: usize,
    frames_out_burst: usize,
) -> usize {
    prime_frames.max(frames_out_burst) + frames_in_burst + frames_out_burst + OUT_BACKLOG_FRAMES
}

/// The fill level above which the oldest monitor frames are dropped. It is the
/// priming runway plus one capture burst: a burst may land while the OUT side is
/// between fills, but the monitor's latency never grows past that.
fn monitor_high_water(prime_frames: usize, frames_in_burst: usize) -> usize {
    prime_frames + frames_in_burst
}

/// Frames as whole milliseconds, rounded.
fn frames_to_ms(frames: u64, rate: u32) -> u32 {
    if rate == 0 {
        return 0;
    }
    ((frames * 1_000 + u64::from(rate) / 2) / u64::from(rate)) as u32
}

/// The OUT stream's continuity for one take, measured rather than inferred.
/// `out_frames` is what the submitted packets actually carry; comparing it with
/// the captured duration makes a hole in the OUT stream visible as `out_lag_ms`
/// (capture time minus playback time). A continuous stream that keeps up sits at
/// zero; a starved one grows. The two rates differ when the monitor is resampled
/// to the endpoint's own rate; the capture side is always `in_rate`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Cadence {
    pub(crate) out_frames: u64,
    pub(crate) capture_ms: u64,
    pub(crate) out_ms: u64,
    pub(crate) out_lag_ms: i64,
}

fn cadence(
    frames_in: u64,
    out_packets: u64,
    out_frames_per_packet: usize,
    in_rate: u32,
    out_rate: u32,
) -> Cadence {
    let out_frames = out_packets * out_frames_per_packet as u64;
    let capture_ms = if in_rate == 0 {
        0
    } else {
        (frames_in * 1_000 + u64::from(in_rate) / 2) / u64::from(in_rate)
    };
    let out_ms = if out_rate == 0 {
        0
    } else {
        (out_frames * 1_000 + u64::from(out_rate) / 2) / u64::from(out_rate)
    };
    Cadence {
        out_frames,
        capture_ms,
        out_ms,
        out_lag_ms: capture_ms as i64 - out_ms as i64,
    }
}

/// The chirp [`crate::roundtrip::click`] fits in six 1 ms packets at 48 kHz
/// (288 frames), so the probe's single OUT URB carries all of it in its first
/// six packets and silence after that.
pub(crate) const CLICK_PACKETS: usize = 6;

/// One USB bus frame is one millisecond, and one millisecond is 48 audio frames
/// at this rate. A captured sample offset is converted to a fractional bus
/// frame with this divisor.
pub(crate) const FRAMES_PER_BUS_FRAME: f64 = 48.0;

/// Where one isochronous packet's frames landed on the bus. The capture buffer
/// is a flat mono sample run, so `capture_offset` is its frame index at the
/// packet's first sample and `bus_frame` is the kernel's `urb.start_frame` plus
/// the packet's position in the URB. A 49-frame packet (196 bytes) therefore
/// shifts every later offset by that extra frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Segment {
    pub(crate) capture_offset: usize,
    pub(crate) bus_frame: u32,
    pub(crate) frames: usize,
}

/// The fractional bus frame a captured sample offset was heard on. The last
/// segment at or before the offset wins; offsets past the last segment
/// extrapolate from it, so a click at the very end of the capture still maps.
fn frame_at_offset(segments: &[Segment], offset: usize) -> Option<f64> {
    let segment = segments
        .iter()
        .rev()
        .find(|segment| offset >= segment.capture_offset)?;
    Some(
        f64::from(segment.bus_frame)
            + (offset - segment.capture_offset) as f64 / FRAMES_PER_BUS_FRAME,
    )
}

/// Write the chirp's frames into the first [`CLICK_PACKETS`] packets of a
/// stereo S16LE OUT buffer and zero everything else. Returns how many frames of
/// the chirp were placed; a packet shorter than the chirp simply stops early.
fn place_click(buffer: &mut [u8], packet: usize, click: &[f32]) -> usize {
    for byte in buffer.iter_mut() {
        *byte = 0;
    }
    if packet < 4 || buffer.is_empty() {
        return 0;
    }
    let frames_per_packet = packet / 4;
    let mut placed = 0usize;
    for packet_index in 0..CLICK_PACKETS {
        let start = packet_index * packet;
        if start + packet > buffer.len() {
            break;
        }
        for frame in 0..frames_per_packet {
            if placed >= click.len() {
                break;
            }
            let bytes = crate::wav::to_i16(click[placed]).to_le_bytes();
            let (left, right) = (bytes[0], bytes[1]);
            let offset = start + frame * 4;
            buffer[offset] = left;
            buffer[offset + 1] = right;
            buffer[offset + 2] = left;
            buffer[offset + 3] = right;
            placed += 1;
        }
        if placed >= click.len() {
            break;
        }
    }
    placed
}

/// The bus-frame subtraction, with its refusals. A bus frame is 1 ms, so the
/// difference in whole bus frames *is* the difference in milliseconds; the
/// audio-frame count is that same number times the number of frames per
/// millisecond.
fn bus_round_trip_ms(click_frame: u32, heard_frame: f64) -> Result<f64, String> {
    if click_frame == 0 {
        return Err("the playback URB did not report a bus frame".to_string());
    }
    if !heard_frame.is_finite() {
        return Err("the heard bus frame was not finite".to_string());
    }
    let delta = heard_frame - f64::from(click_frame);
    if delta < 0.0 {
        return Err(format!(
            "the click was heard at bus frame {heard_frame:.3}, before the playback URB's frame {click_frame}; the two frames do not share a counter"
        ));
    }
    if delta > 1_000.0 {
        return Err(format!(
            "the measured round trip is {delta:.1} ms, which is not a click in the same window"
        ));
    }
    Ok(delta)
}

/// UAC1's class GET_CUR for the sampling frequency answers three little-endian
/// bytes (`tSamFreq[3]`). A short read has no rate to report, so it decodes to 0.
fn decode_sample_rate(bytes: &[u8]) -> u32 {
    if bytes.len() < 3 {
        return 0;
    }
    u32::from(bytes[0]) | (u32::from(bytes[1]) << 8) | (u32::from(bytes[2]) << 16)
}

/// Lowercase, unpadded hex of the bytes a control read returned.
fn hex_bytes(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// The three little-endian bytes UAC1's `SAMPLING_FREQ_CONTROL` carries
/// (`tSamFreq[3]`). The inverse of [`decode_sample_rate`].
fn sample_rate_bytes(hz: u32) -> [u8; 3] {
    [hz as u8, (hz >> 8) as u8, (hz >> 16) as u8]
}

/// The rate a 16-bit stereo full-speed packet implies: `packet / 4` frames in
/// each 1 ms USB frame. A 192-byte packet is 48 frames/ms, a 128-byte packet 32.
fn monitor_rate_for_packet(packet: usize) -> u32 {
    (packet / 4) as u32 * 1_000
}

/// Whether the endpoint's read rate is safe to drive with `packet`-sized
/// frames. A zero rate means the read itself failed, which is not evidence of a
/// mismatch — some fixed-rate cards simply implement no `GET_CUR`.
fn monitor_rate_ok(packet: usize, hz: u32) -> bool {
    hz == 0 || hz == monitor_rate_for_packet(packet)
}

/// The rate the monitor can run at, given the packet the caller asked for and
/// the endpoint's read rate. A rate equal to the capture rate needs no
/// conversion; a lower rate is resampled to. `None` means the endpoint is at a
/// rate this 1 ms-packet path cannot carry as whole frames (44.1 kHz, for
/// example), so the monitor must stay off rather than drift.
fn monitor_fallback_rate(packet: usize, endpoint_hz: u32) -> Option<u32> {
    if monitor_rate_ok(packet, endpoint_hz) {
        return Some(monitor_rate_for_packet(packet));
    }
    if endpoint_hz >= 8_000 && endpoint_hz % 1_000 == 0 {
        Some(endpoint_hz)
    } else {
        None
    }
}

/// Little-endian 16-bit stereo to the duplicated mono the rings carry. The left
/// sample is the mono value, exactly as `plan::Strip` reads the ring; the two
/// halves are never summed, so a mic that lands on one channel keeps its level.
///
/// The record ring is the one cross-thread hop left; the monitor's frames go
/// straight into the loop's own [`OutFifo`], because both sides run on the same
/// USB thread.
fn decode_packet(
    packet: &[u8],
    stereo: &mut [f32],
    record: &monbus::Producer,
    monitor: Option<&mut OutFifo>,
    stats: &mut InStats,
    peak: &mut f32,
) {
    let frames = (packet.len() / 4).min(stereo.len() / 2);
    for frame in 0..frames {
        let offset = frame * 4;
        let sample = i16::from_le_bytes([packet[offset], packet[offset + 1]]);
        let value = f32::from(sample) / 32768.0;
        let magnitude = value.abs();
        if magnitude > *peak {
            *peak = magnitude;
        }
        stereo[frame * 2] = value;
        stereo[frame * 2 + 1] = value;
    }
    if frames > 0 {
        let block = &stereo[..frames * 2];
        // A full record ring drops the newest frames; count them here rather
        // than letting the loss disappear into frames_captured - frames_written.
        stats.dropped_ring += record.push(block) as u64;
        // Still the monitor's problem, not the take's: count its drops on the
        // fifo (visible as `dropped_out`), never silently.
        if let Some(fifo) = monitor {
            fifo.push(block);
        }
    }
    stats.frames_in += frames as u64;
}

#[derive(Default)]
struct InStats {
    bytes_in: u64,
    frames_in: u64,
    missed_in: u64,
    dropped_ring: u64,
}

/// Absorb one completed capture URB into the fixed counters, the record ring
/// and (when a monitor is configured) the loop's own fifo. No allocation, no
/// lock, no log: every buffer here was sized at setup.
///
/// # Safety
/// `done` must point at a live URB image whose `buffer` covers
/// `number_of_packets * packet` bytes; `stereo` must hold at least
/// `packet / 2` samples.
#[allow(clippy::too_many_arguments)]
unsafe fn absorb_in(
    done: *mut UsbdevfsUrb,
    packet: usize,
    histogram: &mut [u64],
    stats: &mut InStats,
    record: &monbus::Producer,
    mut monitor: Option<&mut OutFifo>,
    stereo: &mut [f32],
    peak: &mut f32,
) {
    let header = &*done;
    let base = header.buffer as *const u8;
    let count = header.number_of_packets.max(0) as usize;
    let descs = (done as *const u8).add(URB_BYTES) as *const UsbdevfsIsoPacketDesc;
    for index in 0..count {
        let desc = &*descs.add(index);
        record_packet_length(histogram, desc.actual_length as usize);
        stats.bytes_in += u64::from(desc.actual_length);
        if desc.status as i32 == EXDEV {
            stats.missed_in += 1;
        }
        if desc.status == 0 && desc.actual_length > 0 {
            let length = (desc.actual_length as usize).min(packet);
            let slice = std::slice::from_raw_parts(base.add(index * packet), length);
            decode_packet(
                slice,
                stereo,
                record,
                monitor.as_deref_mut(),
                stats,
                peak,
            );
        }
    }
}

/// The bounded monitor queue feeding the playback URBs. Frames arrive only from
/// the USB thread that also fills the OUT packets, so there is no ring and no
/// lock between them. The oldest frame is discarded above the **high water**
/// (`prime + one IN burst`), not above the capacity, so a capture burst can land
/// without loss while the steady fill stays at the priming runway. A packet the
/// queue cannot fill is zero-padded and counted as one underrun.
struct OutFifo {
    data: Vec<f32>,
    capacity: usize,
    high_water: usize,
    head: usize,
    len: usize,
    dropped: u64,
}

/// One stereo frame as 16-bit little-endian, the shape the OUT packet wants.
fn write_monitor_frame(out: &mut [u8], frame: usize, left: f32, right: f32) {
    let left = crate::wav::to_i16(left).to_le_bytes();
    let right = crate::wav::to_i16(right).to_le_bytes();
    out[frame * 4] = left[0];
    out[frame * 4 + 1] = left[1];
    out[frame * 4 + 2] = right[0];
    out[frame * 4 + 3] = right[1];
}

impl OutFifo {
    /// `capacity` is the physical ring size and `high_water` the fill level the
    /// oldest frame is dropped above. Trimming at the high water keeps the
    /// steady-state latency at the priming runway instead of the capacity.
    fn new(capacity: usize, high_water: usize) -> Self {
        let capacity = capacity.max(1);
        let high_water = high_water.clamp(1, capacity);
        OutFifo {
            data: vec![0.0f32; capacity * 2],
            capacity,
            high_water,
            head: 0,
            len: 0,
            dropped: 0,
        }
    }

    /// Append stereo frames, dropping the oldest first so the queue never sits
    /// above its high water. When a single block is larger than the high water,
    /// only its newest frames are kept. Every dropped frame is counted.
    fn push(&mut self, stereo: &[f32]) {
        let frames = stereo.len() / 2;
        if frames == 0 {
            return;
        }
        let keep = frames.min(self.high_water);
        let skip = frames - keep;
        // Frames the block itself sheds are losses too; count them.
        self.dropped += skip as u64;
        // Leave exactly enough room for the frames this block will keep.
        let room = self.high_water - keep;
        while self.len > room && self.len > 0 {
            self.head = (self.head + 1) % self.capacity;
            self.len -= 1;
            self.dropped += 1;
        }
        for frame in skip..frames {
            let slot = ((self.head + self.len) % self.capacity) * 2;
            self.data[slot] = stereo[frame * 2];
            self.data[slot + 1] = stereo[frame * 2 + 1];
            self.len += 1;
        }
    }

    /// The oldest stereo frame without consuming it.
    fn front(&self) -> Option<(f32, f32)> {
        (self.len > 0).then(|| {
            let slot = self.head * 2;
            (self.data[slot], self.data[slot + 1])
        })
    }

    /// Consume the oldest stereo frame.
    fn pop(&mut self) -> Option<(f32, f32)> {
        let frame = self.front()?;
        self.head = (self.head + 1) % self.capacity;
        self.len -= 1;
        Some(frame)
    }

    /// Fill `frames` stereo frames of `out` (4 bytes each), padding with silence
    /// when the queue is short. Returns how many frames came from the queue; a
    /// caller treats a shortfall as one underrun.
    fn fill_packet(&mut self, frames: usize, out: &mut [u8]) -> usize {
        let wanted = frames.min(out.len() / 4);
        let got = wanted.min(self.len);
        for frame in 0..got {
            let slot = ((self.head + frame) % self.capacity) * 2;
            write_monitor_frame(out, frame, self.data[slot], self.data[slot + 1]);
        }
        for byte in &mut out[got * 4..wanted * 4] {
            *byte = 0;
        }
        self.head = (self.head + got) % self.capacity;
        self.len -= got;
        got
    }

    /// Fill one packet by linearly resampling the queue to the endpoint's rate.
    /// The queue itself stays at the capture rate, so priming, the high-water
    /// trim and the fill counters keep their meaning; only the frames written
    /// into the packet are converted. Returns how many output frames came from
    /// real input; a caller treats a shortfall as one underrun.
    fn fill_packet_resampled(
        &mut self,
        resampler: &mut MonitorResampler,
        frames: usize,
        out: &mut [u8],
    ) -> usize {
        let wanted = frames.min(out.len() / 4);
        if !resampler.primed {
            match self.pop() {
                Some((left, right)) => {
                    resampler.prev_l = left;
                    resampler.prev_r = right;
                    resampler.pos = 0.0;
                    resampler.primed = true;
                }
                None => {
                    for byte in &mut out[..wanted * 4] {
                        *byte = 0;
                    }
                    return 0;
                }
            }
        }
        let mut produced = 0;
        for frame in 0..wanted {
            let Some((cur_l, cur_r)) = self.front() else {
                // The queue ran dry mid-packet: silence the rest and let the
                // next fill re-prime rather than extrapolate from a stale one.
                for byte in &mut out[frame * 4..wanted * 4] {
                    *byte = 0;
                }
                resampler.primed = false;
                return produced;
            };
            let alpha = resampler.pos as f32;
            let left = resampler.prev_l + (cur_l - resampler.prev_l) * alpha;
            let right = resampler.prev_r + (cur_r - resampler.prev_r) * alpha;
            write_monitor_frame(out, frame, left, right);
            produced += 1;
            resampler.pos += resampler.step;
            while resampler.pos >= 1.0 {
                match self.pop() {
                    Some((left, right)) => {
                        resampler.prev_l = left;
                        resampler.prev_r = right;
                        resampler.pos -= 1.0;
                    }
                    None => {
                        resampler.pos = 0.0;
                        break;
                    }
                }
            }
        }
        produced
    }

    fn dropped(&self) -> u64 {
        self.dropped
    }

    /// Frames waiting to be played. The priming loop reads this, so it is the
    /// same count the packets will drain.
    fn len(&self) -> usize {
        self.len
    }

    fn capacity(&self) -> usize {
        self.capacity
    }

    fn high_water(&self) -> usize {
        self.high_water
    }
}

/// Linear resampling for the **monitor only**, from the capture rate to the
/// endpoint's own rate. Capture, the record ring and the take stay at the
/// capture rate; this converts the frames on their way into the OUT packets.
/// One frame of lookahead (`prev`) keeps the step continuous across packets, so
/// a 3:2 decimation does not click at a packet or URB boundary.
struct MonitorResampler {
    /// Input frames per output frame (48k -> 32k is 1.5).
    step: f64,
    /// Fractional position of the next output relative to `prev`.
    pos: f64,
    prev_l: f32,
    prev_r: f32,
    primed: bool,
}

impl MonitorResampler {
    fn new(in_rate: u32, out_rate: u32) -> Self {
        let step = if out_rate == 0 {
            1.0
        } else {
            f64::from(in_rate) / f64::from(out_rate)
        };
        Self {
            step,
            pos: 0.0,
            prev_l: 0.0,
            prev_r: 0.0,
            primed: false,
        }
    }
}

/// What one take's monitor (OUT) side carried. The priming split lives here so
/// a future take can tell a slow start from starvation. The fill sample is taken
/// just before every OUT URB is filled, so the latency the report claims is the
/// fill the loop actually saw.
#[derive(Default)]
struct OutStats {
    packets: u64,
    bytes: u64,
    underruns: u64,
    /// The underruns already counted when warm-up ended. Priming fills the fifo
    /// before the first submit, so this is zero unless a caller fills OUT while
    /// still warming up.
    underruns_start: u64,
    fill_samples: u64,
    fill_frames_sum: u64,
    fill_frames_max: usize,
}

/// Write every packet of one OUT URB from the loop's own `fifo`, with no rate
/// conversion. Kept as the plain-monitor shape; [`fill_out_urb_with`] is the
/// core the take uses when the endpoint runs at another rate.
///
/// # Safety
/// `done` must point at a live OUT URB image with a buffer of
/// `number_of_packets * packet` bytes.
unsafe fn fill_out_urb(
    done: *mut UsbdevfsUrb,
    packet: usize,
    fifo: &mut OutFifo,
    stats: &mut OutStats,
) {
    fill_out_urb_with(done, packet, fifo, stats, None);
}

/// Write every packet of one OUT URB from the loop's own `fifo`. When
/// `resampler` is present the packet is filled at the endpoint's rate while the
/// fifo stays at the capture rate.
///
/// # Safety
/// `done` must point at a live OUT URB image with a buffer of
/// `number_of_packets * packet` bytes.
unsafe fn fill_out_urb_with(
    done: *mut UsbdevfsUrb,
    packet: usize,
    fifo: &mut OutFifo,
    stats: &mut OutStats,
    mut resampler: Option<&mut MonitorResampler>,
) {
    let fill = fifo.len();
    stats.fill_samples += 1;
    stats.fill_frames_sum += fill as u64;
    if fill > stats.fill_frames_max {
        stats.fill_frames_max = fill;
    }
    let frames_per_packet = packet / 4;
    let header = &*done;
    let base = header.buffer as *mut u8;
    let count = header.number_of_packets.max(0) as usize;
    for index in 0..count {
        let out = std::slice::from_raw_parts_mut(base.add(index * packet), packet);
        let produced = match resampler.as_deref_mut() {
            Some(resampler) => fifo.fill_packet_resampled(resampler, frames_per_packet, out),
            None => fifo.fill_packet(frames_per_packet, out),
        };
        if produced < frames_per_packet {
            stats.underruns += 1;
        }
        stats.packets += 1;
        stats.bytes += packet as u64;
    }
}

// --- the report --------------------------------------------------------------

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct UsbSetInterface {
    pub ret: i32,
    pub errno: i32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct UsbSched {
    pub policy: i32,
    pub priority: i32,
    pub errno: i32,
}

/// The playback endpoint's own `GET_CUR` sampling frequency, read once before
/// streaming. The P0 probe answered 32000 on an endpoint whose alt implies 192
/// B/ms (48 kHz mono-equivalent), so the take records what it says now.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UsbOutRate {
    /// The ioctl's return; negative means the probe failed (never fatal).
    pub ret: i32,
    pub errno: i32,
    /// The bytes the kernel returned, lowercase hex.
    pub raw: String,
    /// Those bytes decoded as a 24-bit little-endian rate; 0 when unread.
    pub hz: u32,
}

/// One attempt to bring the playback endpoint to the rate its packet size
/// implies. The rate control is UAC1's `SAMPLING_FREQ_CONTROL`, which is
/// standard class, not a Behringer constant; what varies per card is whether it
/// exposes the control at all, on which recipient, and which rates the alternate
/// setting can carry.
///
/// `verified` is true only after a `GET_CUR` readback returned `target`, so the
/// report never claims a rate the device did not acknowledge.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct UsbRateSet {
    /// The rate the configured packet size implies at 1 ms per packet.
    pub target: u32,
    /// The last `SET_CUR` ioctl's return; negative is a refusal.
    pub ret: i32,
    pub errno: i32,
    /// `"endpoint"`, `"interface"`, `"already"` or `"none"`.
    pub recipient: &'static str,
    /// True only when the readback after the attempt equals `target`.
    pub verified: bool,
}

/// What one direct-USB take got, in the same accounting shape as `OboeReport`
/// plus the usbfs counters a device gate needs to read.
#[derive(Debug, Clone)]
pub struct UsbReport {
    pub rate: u32,
    /// `actual_length` histogram: the gate expects 192 and 196.
    pub packets_in: Vec<(u32, u64)>,
    /// Packets whose status was `-EXDEV` (a missed frame).
    pub missed_in: u64,
    pub bytes_in: u64,
    pub frames_in: u64,
    pub underruns_out: u64,
    /// The subset of `underruns_out` counted during warm-up, before the first
    /// OUT submit.
    pub underruns_out_start: u64,
    pub dropped_out: u64,
    /// Packets submitted on the monitor endpoint, and the bytes they carried.
    pub out_packets: u64,
    pub out_bytes: u64,
    /// The monitor's runway: every queued OUT packet is 1 ms of audio.
    pub monitor_ms: u32,
    /// The configured capture depth as `(urbs, packets_per_urb)`.
    pub in_depth: (usize, usize),
    /// The configured monitor depth as `(urbs, packets_per_urb)`.
    pub out_depth: (usize, usize),
    /// How many 1 ms packets one IN URB delivers: the batching half of the
    /// monitor's added latency.
    pub in_delivery_ms: u32,
    /// The fifo fill observed just before each OUT URB was filled, so the
    /// monitor latency claim is measured rather than inferred.
    pub monitor_fill_max_ms: u32,
    pub monitor_fill_avg_ms: u32,
    /// The fifo's physical capacity and the high water it trims above, in ms.
    pub fifo_capacity_ms: u32,
    pub high_water_ms: u32,
    /// The OUT cadence: frames the submitted packets carry, the capture and
    /// playback durations in ms, and their difference. `out_lag_ms` near zero
    /// means the OUT stream is continuous and keeping up; a positive value is
    /// the hole the device was fed.
    pub out_frames: u64,
    pub capture_ms: u64,
    pub out_ms: u64,
    pub out_lag_ms: i64,
    pub out_rate: UsbOutRate,
    /// The `SET_CUR` attempt and its readback, beside the final `out_rate`.
    pub rate_set: UsbRateSet,
    /// Why the monitor was left off, if it was (`Some("playback rate")` when the
    /// endpoint's read rate did not match the packet size). Capture still ran.
    pub monitor_off: Option<&'static str>,
    pub setinterface: UsbSetInterface,
    pub sched: UsbSched,
    pub frames_captured: u64,
    pub frames_written: u64,
    pub dropped_ring: u64,
    pub dropped_disk: u64,
    pub peak: f32,
    pub plan: String,
    pub take: String,
}

/// The driver's capture-side result, before the disk thread's counts are merged.
pub(crate) struct UsbIoReport {
    packets_in: Vec<(u32, u64)>,
    missed_in: u64,
    bytes_in: u64,
    frames_in: u64,
    dropped_ring: u64,
    underruns_out: u64,
    underruns_out_start: u64,
    dropped_out: u64,
    out_packets: u64,
    out_bytes: u64,
    monitor_ms: u32,
    in_delivery_ms: u32,
    monitor_fill_max_ms: u32,
    monitor_fill_avg_ms: u32,
    fifo_capacity_ms: u32,
    high_water_ms: u32,
    out_frames: u64,
    capture_ms: u64,
    out_ms: u64,
    out_lag_ms: i64,
    in_depth: UsbDepth,
    out_depth: UsbDepth,
    out_rate: UsbOutRate,
    rate_set: UsbRateSet,
    monitor_off: Option<&'static str>,
    setinterface: UsbSetInterface,
    sched: UsbSched,
    peak: f32,
}

/// The take's configuration, captured from the C ABI's arguments.
pub(crate) struct UsbConfig {
    pub(crate) fd: i32,
    pub(crate) iface_in: i32,
    pub(crate) alt_in: i32,
    pub(crate) ep_in: i32,
    pub(crate) packet_in: i32,
    pub(crate) iface_out: i32,
    pub(crate) alt_out: i32,
    pub(crate) ep_out: i32,
    pub(crate) packet_out: i32,
    pub(crate) rate: u32,
    pub(crate) seconds: f64,
    pub(crate) out: Option<String>,
    pub(crate) plan: Option<ChannelPlan>,
}

fn histogram_json(rows: &[(u32, u64)]) -> String {
    let mut out = String::from("{");
    for (index, (length, count)) in rows.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        out.push('"');
        out.push_str(&length.to_string());
        out.push_str("\":");
        out.push_str(&count.to_string());
    }
    out.push('}');
    out
}

/// One JSON object, the same status style the Oboe backend emits.
fn report_json(report: &UsbReport) -> String {
    format!(
        "{{\"ok\":true,\"backend\":\"usb\",\"rate\":{},\"packets_in\":{},\"missed_in\":{},\"bytes_in\":{},\"frames_in\":{},\"underruns_out\":{},\"underruns_out_start\":{},\"dropped_out\":{},\"out_packets\":{},\"out_bytes\":{},\"monitor_ms\":{},\"in_depth\":{{\"urbs\":{},\"packets\":{}}},\"out_depth\":{{\"urbs\":{},\"packets\":{}}},\"in_delivery_ms\":{},\"monitor_fill_max_ms\":{},\"monitor_fill_avg_ms\":{},\"fifo_capacity_ms\":{},\"high_water_ms\":{},\"out_frames\":{},\"capture_ms\":{},\"out_ms\":{},\"out_lag_ms\":{},\"setinterface\":{{\"ret\":{},\"errno\":{}}},\"sched\":{{\"policy\":{},\"priority\":{},\"errno\":{}}},\"frames_captured\":{},\"frames_written\":{},\"dropped_ring\":{},\"dropped_disk\":{},\"peak\":{:.6},\"out_rate\":{{\"ret\":{},\"errno\":{},\"raw\":\"{}\",\"hz\":{}}},\"rate_set\":{{\"target\":{},\"ret\":{},\"errno\":{},\"recipient\":\"{}\",\"verified\":{}}},\"monitor_off\":{},\"plan\":\"{}\",\"take\":\"{}\"}}",
        report.rate,
        histogram_json(&report.packets_in),
        report.missed_in,
        report.bytes_in,
        report.frames_in,
        report.underruns_out,
        report.underruns_out_start,
        report.dropped_out,
        report.out_packets,
        report.out_bytes,
        report.monitor_ms,
        report.in_depth.0,
        report.in_depth.1,
        report.out_depth.0,
        report.out_depth.1,
        report.in_delivery_ms,
        report.monitor_fill_max_ms,
        report.monitor_fill_avg_ms,
        report.fifo_capacity_ms,
        report.high_water_ms,
        report.out_frames,
        report.capture_ms,
        report.out_ms,
        report.out_lag_ms,
        report.setinterface.ret,
        report.setinterface.errno,
        report.sched.policy,
        report.sched.priority,
        report.sched.errno,
        report.frames_captured,
        report.frames_written,
        report.dropped_ring,
        report.dropped_disk,
        report.peak,
        report.out_rate.ret,
        report.out_rate.errno,
        json_escape(&report.out_rate.raw),
        report.out_rate.hz,
        report.rate_set.target,
        report.rate_set.ret,
        report.rate_set.errno,
        json_escape(report.rate_set.recipient),
        report.rate_set.verified,
        optional_json_string(report.monitor_off),
        json_escape(&report.plan),
        json_escape(&report.take),
    )
}

// --- the syscall glue (Android only) -----------------------------------------

#[cfg(target_os = "android")]
mod sys {
    use super::*;
    use std::os::raw::{c_int, c_ulong};

    /// `struct sched_param` starts with the priority; FIFO reads no more.
    #[repr(C)]
    pub(super) struct SchedParam {
        pub(super) sched_priority: c_int,
    }

    extern "C" {
        pub(super) fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
        pub(super) fn poll(fds: *mut PollFd, nfds: c_ulong, timeout: c_int) -> c_int;
        pub(super) fn sched_setscheduler(
            pid: c_int,
            policy: c_int,
            param: *const SchedParam,
        ) -> c_int;
    }

    /// `struct pollfd`.
    #[repr(C)]
    pub(super) struct PollFd {
        pub(super) fd: c_int,
        pub(super) events: i16,
        pub(super) revents: i16,
    }

    /// `POLLIN`: usbfs makes the fd readable when a completion is queued.
    const POLLIN: i16 = 0x0001;

    /// Wait until usbfs has a completion to reap, or the timeout expires.
    /// `Ok(true)` is ready; `Ok(false)` is a timeout or an `EINTR` retry, not an
    /// error. The caller falls back to a short sleep only on a real error.
    pub(super) unsafe fn wait_reap(fd: c_int, timeout_ms: c_int) -> std::io::Result<bool> {
        let mut item = PollFd {
            fd,
            events: POLLIN,
            revents: 0,
        };
        let ret = poll(&mut item as *mut PollFd, 1, timeout_ms);
        if ret < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                return Ok(false);
            }
            return Err(error);
        }
        Ok(ret > 0 && (item.revents & POLLIN) != 0)
    }

    pub(super) unsafe fn submit(fd: c_int, urb: *mut UsbdevfsUrb) -> std::io::Result<()> {
        if ioctl(fd, USBDEVFS_SUBMITURB as c_ulong, urb) < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    pub(super) unsafe fn discard(fd: c_int, urb: *mut UsbdevfsUrb) {
        let _ = ioctl(fd, USBDEVFS_DISCARDURB as c_ulong, urb);
    }

    pub(super) unsafe fn reap(fd: c_int) -> std::io::Result<*mut UsbdevfsUrb> {
        let mut done: *mut UsbdevfsUrb = std::ptr::null_mut();
        let ret = ioctl(
            fd,
            USBDEVFS_REAPURBNDELAY as c_ulong,
            &mut done as *mut *mut UsbdevfsUrb,
        );
        if ret < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(done)
        }
    }

    pub(super) unsafe fn set_interface(fd: c_int, interface: i32, altsetting: i32) -> (i32, i32) {
        let request = UsbdevfsSetInterface {
            interface: interface as u32,
            altsetting: altsetting as u32,
        };
        let ret = ioctl(
            fd,
            USBDEVFS_SETINTERFACE as c_ulong,
            &request as *const UsbdevfsSetInterface,
        );
        (ret, if ret < 0 { errno() } else { 0 })
    }

    /// One class/vendor control IN into `data`. Returns the ioctl's ret and the
    /// errno that explains a refusal.
    pub(super) unsafe fn control_in(
        fd: c_int,
        request_type: u8,
        request: u8,
        value: u16,
        index: u16,
        data: &mut [u8],
        timeout_ms: u32,
    ) -> (i32, i32) {
        let transfer = UsbdevfsCtrlTransfer {
            request_type,
            request,
            value,
            index,
            length: data.len() as u16,
            timeout: timeout_ms,
            data: data.as_mut_ptr() as *mut c_void,
        };
        let ret = ioctl(
            fd,
            USBDEVFS_CONTROL as c_ulong,
            &transfer as *const UsbdevfsCtrlTransfer,
        );
        (ret, if ret < 0 { errno() } else { 0 })
    }

    /// One class/vendor control OUT from `data`. usbfs takes the same
    /// `usbdevfs_ctrltransfer` for both directions and reads `data` for an OUT,
    /// so the const slice is passed through as the struct's `*mut`. Returns the
    /// ioctl's ret and the errno that explains a refusal.
    pub(super) unsafe fn control_out(
        fd: c_int,
        request_type: u8,
        request: u8,
        value: u16,
        index: u16,
        data: &[u8],
        timeout_ms: u32,
    ) -> (i32, i32) {
        let transfer = UsbdevfsCtrlTransfer {
            request_type,
            request,
            value,
            index,
            length: data.len() as u16,
            timeout: timeout_ms,
            data: data.as_ptr() as *mut c_void,
        };
        let ret = ioctl(
            fd,
            USBDEVFS_CONTROL as c_ulong,
            &transfer as *const UsbdevfsCtrlTransfer,
        );
        (ret, if ret < 0 { errno() } else { 0 })
    }

    pub(super) fn errno() -> i32 {
        std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
    }

    pub(super) fn request_realtime() -> UsbSched {
        let param = SchedParam {
            sched_priority: SCHED_PRIORITY,
        };
        let ret = unsafe { sched_setscheduler(0, SCHED_FIFO, &param) };
        UsbSched {
            policy: SCHED_FIFO,
            priority: SCHED_PRIORITY,
            errno: if ret < 0 { errno() } else { 0 },
        }
    }
}

/// The USB loop itself: submit, reap, absorb, resubmit until the deadline or the
/// stop flag. It runs on the take's worker thread, so the `sched_setscheduler`
/// call applies to the thread the kernel wakes for reaps.
///
/// The depth is read once here ([`current_depth`]); the monitor's average added
/// latency is roughly `in_packets / 2 + out_urbs * out_packets` ms — half an IN
/// URB of capture batching plus the whole OUT runway. Sweeping the OUT depth is
/// what moves that number; the IN depth only sets how much jitter it can ride
/// out.
///
/// `record` is the take's record ring producer, the one cross-thread hop left.
/// The monitor's frames are pushed by the same reap/absorb loop that fills the
/// OUT URBs, into that loop's own [`OutFifo`], with no ring or lock between.
#[cfg(target_os = "android")]
fn wait_for_reap(fd: i32) {
    // `poll` wakes as soon as a completion lands; a 1 ms bound keeps a silent
    // device from parking the loop. A real poll error falls back to the old
    // short sleep rather than spinning on the fd.
    match unsafe { sys::wait_reap(fd, 1) } {
        Ok(_) => {}
        Err(_) => thread::sleep(std::time::Duration::from_micros(200)),
    }
}

/// The playback endpoint's own class `GET_CUR` for the sampling frequency
/// (`0xA2`, request `0x81`, `wValue 0x0100`, `wIndex` = the endpoint, 3 bytes).
/// A refusal is a fact to report, not a take error.
#[cfg(target_os = "android")]
unsafe fn read_endpoint_rate(fd: i32, ep: i32) -> UsbOutRate {
    let mut bytes = [0u8; 3];
    let (ret, errno) = sys::control_in(fd, 0xA2, 0x81, 0x0100, ep as u16, &mut bytes, 250);
    let read = (ret.max(0) as usize).min(bytes.len());
    UsbOutRate {
        ret,
        errno,
        raw: hex_bytes(&bytes[..read]),
        hz: decode_sample_rate(&bytes[..read]),
    }
}

/// Read the rate back until it matches `target` or a short bound expires. A
/// device may apply a `SET_CUR` a few frames after acknowledging it; declaring a
/// refusal on the first readback would then be a false negative. The bound is
/// paid only when the readback disagrees, so a fixed-rate card costs ~10 ms at
/// the start of a take.
#[cfg(target_os = "android")]
unsafe fn await_endpoint_rate(fd: i32, ep: i32, target: u32) -> UsbOutRate {
    let mut last = read_endpoint_rate(fd, ep);
    for _ in 0..5 {
        if last.ret >= 0 && last.hz == target {
            break;
        }
        thread::sleep(std::time::Duration::from_millis(2));
        last = read_endpoint_rate(fd, ep);
    }
    last
}

/// Ask the playback endpoint to run at `target`, then require a `GET_CUR`
/// readback before believing it.
///
/// UAC1's `SAMPLING_FREQ_CONTROL` is a class request to the isochronous
/// **endpoint**: bmRequestType `0x22`, bRequest SET_CUR `0x01`, wValue `0x0100`,
/// wIndex the endpoint address, a 3-byte `tSamFreq`. A device that implements
/// the selector on the interface instead gets one second attempt at `0x21`; the
/// selector is the same, only the recipient differs. This runs after
/// `SET_INTERFACE` and before any URB is submitted, so no isochronous schedule
/// is live for the control transfer.
///
/// Nothing is reported as set without the readback. A refused or unsupported
/// control is a fact the report carries; it is not fatal to the capture.
#[cfg(target_os = "android")]
unsafe fn set_playback_rate(
    fd: i32,
    iface_out: i32,
    ep_out: i32,
    target: u32,
) -> (UsbOutRate, UsbRateSet) {
    let first = read_endpoint_rate(fd, ep_out);
    if first.ret >= 0 && first.hz == target {
        let ret = first.ret;
        return (
            first,
            UsbRateSet {
                target,
                ret,
                errno: 0,
                recipient: "already",
                verified: true,
            },
        );
    }

    let bytes = sample_rate_bytes(target);
    let mut last_ret = -1;
    let mut last_errno = 0;
    let mut last_read = first;
    for (request_type, index, recipient) in [
        (0x22u8, ep_out as u16, "endpoint"),
        (0x21u8, iface_out as u16, "interface"),
    ] {
        let (ret, errno) =
            sys::control_out(fd, request_type, 0x01, 0x0100, index, &bytes, 250);
        last_ret = ret;
        last_errno = errno;
        let readback = await_endpoint_rate(fd, ep_out, target);
        if readback.ret >= 0 && readback.hz == target {
            return (
                readback,
                UsbRateSet {
                    target,
                    ret,
                    errno,
                    recipient,
                    verified: true,
                },
            );
        }
        last_read = readback;
    }

    (
        last_read,
        UsbRateSet {
            target,
            ret: last_ret,
            errno: last_errno,
            recipient: "none",
            verified: false,
        },
    )
}

#[cfg(target_os = "android")]
pub(crate) fn run_usb_plan(
    config: &UsbConfig,
    stop: &AtomicBool,
    record: &monbus::Producer,
) -> Result<UsbIoReport, String> {
    use std::time::{Duration, Instant};

    if config.fd < 0 {
        return Err("the USB connection has no usable file descriptor".to_string());
    }
    if config.packet_in <= 0 || config.ep_in < 0 {
        return Err("the capture endpoint needs an endpoint number and a positive packet size"
            .to_string());
    }

    let packet_in = config.packet_in as usize;
    let mut have_out = config.ep_out >= 0 && config.packet_out > 0;
    let mut packet_out = if have_out {
        config.packet_out as usize
    } else {
        0
    };
    if have_out && packet_out < 4 {
        return Err(
            "the playback endpoint needs at least one stereo frame per packet".to_string(),
        );
    }
    // One read for the whole take: buffers, in-flight flags and the priming
    // threshold are all sized from this, and never resized while the kernel owns
    // a URB.
    let mut depth = current_depth();
    if have_out {
        // Defence in depth: the setter and the decoded word both clamp, but a
        // take must never run the monitor with a single URB in flight.
        depth.out_urbs = depth.out_urbs.max(OUT_URBS_MIN as usize);
    }

    // Select the alternate settings. Java already did this through
    // `UsbDeviceConnection.setInterface()`; the ioctl is a cross-check, so a
    // refusal is recorded and the take continues.
    let (ret, errno) = unsafe { sys::set_interface(config.fd, config.iface_in, config.alt_in) };
    let setinterface = UsbSetInterface { ret, errno };
    if have_out {
        let _ = unsafe { sys::set_interface(config.fd, config.iface_out, config.alt_out) };
    }

    // Bring the playback endpoint to the rate the packet size implies, then
    // require a GET_CUR readback before trusting it. This runs after
    // SET_INTERFACE and before any URB is submitted, so no isochronous schedule
    // is live for the control transfer (the PCM2902 refuses one that is).
    let (out_rate, rate_set) = if have_out {
        unsafe {
            set_playback_rate(
                config.fd,
                config.iface_out,
                config.ep_out,
                monitor_rate_for_packet(packet_out),
            )
        }
    } else {
        (
            UsbOutRate {
                ret: -1,
                ..UsbOutRate::default()
            },
            UsbRateSet {
                target: 0,
                ret: -1,
                errno: 0,
                recipient: "none",
                verified: false,
            },
        )
    };
    // A readback that disagrees with the packet size means the endpoint runs at
    // another rate. If that rate can be carried by an integer number of frames
    // per 1 ms packet, resample the monitor to it (capture and the take stay at
    // 48 kHz); otherwise leave the monitor off rather than overrun the endpoint.
    // A failed read (hz == 0) is not evidence of a mismatch and keeps 48 kHz.
    let mut monitor_off = None;
    let monitor_out_rate = if have_out {
        match monitor_fallback_rate(packet_out, out_rate.hz) {
            Some(rate) => rate,
            None => {
                have_out = false;
                monitor_off = Some("playback rate");
                config.rate
            }
        }
    } else {
        config.rate
    };
    if have_out && monitor_out_rate != config.rate {
        packet_out = (monitor_out_rate as usize / 1_000) * 4;
    }

    let sched = sys::request_realtime();

    // One data buffer per direction, sized once. Each URB's buffer points at its
    // own slice; nothing is resized or moved while the kernel owns a URB.
    let mut in_urbs: Vec<Urb> = (0..depth.in_urbs)
        .map(|_| Urb::new(depth.in_packets))
        .collect();
    let mut in_data = vec![0u8; depth.in_urbs * depth.in_packets * packet_in];
    let mut in_ptrs: Vec<*mut UsbdevfsUrb> = Vec::with_capacity(depth.in_urbs);
    for (index, urb) in in_urbs.iter_mut().enumerate() {
        let buffer = unsafe {
            in_data
                .as_mut_ptr()
                .add(index * depth.in_packets * packet_in) as *mut c_void
        };
        let pointer = urb.ptr();
        unsafe {
            prepare_urb(
                pointer,
                config.ep_in as u8,
                packet_in,
                depth.in_packets,
                buffer,
            )
        };
        in_ptrs.push(pointer);
    }

    let mut out_urbs: Vec<Urb> = Vec::new();
    let mut out_data: Vec<u8> = Vec::new();
    let mut out_ptrs: Vec<*mut UsbdevfsUrb> = Vec::new();
    if have_out {
        out_urbs = (0..depth.out_urbs)
            .map(|_| Urb::new(depth.out_packets))
            .collect();
        out_data = vec![0u8; depth.out_urbs * depth.out_packets * packet_out];
        for (index, urb) in out_urbs.iter_mut().enumerate() {
            let buffer = unsafe {
                out_data
                    .as_mut_ptr()
                    .add(index * depth.out_packets * packet_out)
                    as *mut c_void
            };
            let pointer = urb.ptr();
            unsafe {
                prepare_urb(
                    pointer,
                    config.ep_out as u8,
                    packet_out,
                    depth.out_packets,
                    buffer,
                )
            };
            out_ptrs.push(pointer);
        }
    }

    let frames_per_out_packet = packet_out / 4;
    // Input frames one OUT packet consumes. They differ from the device-rate
    // frames only when the monitor is resampled; the fifo, priming and the
    // high-water trim all stay at the capture rate.
    let frames_per_out_packet_in = if monitor_out_rate == config.rate {
        frames_per_out_packet
    } else {
        let net = frames_per_out_packet as u64 * u64::from(config.rate);
        let out = u64::from(monitor_out_rate);
        ((net + out - 1) / out) as usize
    };
    let frames_per_out_urb = depth.out_packets * frames_per_out_packet_in;
    let frames_per_in_urb = depth.in_packets * (packet_in / 4);
    // The whole OUT depth is what priming must fill before the first submit.
    let prime_frames = if have_out {
        depth.prime_frames(frames_per_out_packet_in)
    } else {
        0
    };
    // One on-thread queue: capture pushes into it and the OUT fills drain it,
    // both here. No monbus ring, so a burst cannot pile up off-thread and then
    // arrive all at once above the trim point.
    let mut fifo = have_out.then(|| {
        OutFifo::new(
            monitor_fifo_capacity(prime_frames, frames_per_in_urb, frames_per_out_urb),
            monitor_high_water(prime_frames, frames_per_in_urb),
        )
    });
    let mut monitor_resampler =
        (have_out && monitor_out_rate != config.rate)
            .then(|| MonitorResampler::new(config.rate, monitor_out_rate));
    // At most one packet's worth of duplicated mono samples.
    let mut packet_stereo = vec![0.0f32; (packet_in / 2).max(2)];

    let mut histogram = vec![0u64; packet_in + 2];
    let mut stats = InStats::default();
    let mut peak = 0.0f32;
    let mut out_stats = OutStats::default();

    let mut in_flight = vec![false; depth.in_urbs];
    let mut out_flight = vec![false; depth.out_urbs];
    let mut outstanding: usize = 0;
    let mut submit_error: Option<i32> = None;

    for index in 0..depth.in_urbs {
        match unsafe { sys::submit(config.fd, in_ptrs[index]) } {
            Ok(()) => {
                in_flight[index] = true;
                outstanding += 1;
            }
            Err(error) => {
                if submit_error.is_none() {
                    submit_error = Some(error.raw_os_error().unwrap_or(0));
                }
            }
        }
    }
    if outstanding == 0 {
        return Err(format!(
            "every isochronous capture URB submit was refused (errno {})",
            submit_error.unwrap_or(0)
        ));
    }

    // Prime the monitor before the first OUT submit. At t=0 the fifo is empty,
    // so submitting straight away would send a whole OUT URB of silence and read
    // as an underrun. Reap capture completions through the same `absorb_in` path
    // until the fifo holds the whole OUT depth (or the bounded warm-up expires),
    // then submit. Capture is already live, so these frames are the take's first
    // frames, not a delay in the record path.
    let prime_started = Instant::now();
    while outstanding > 0 && fifo.as_ref().map_or(0, |fifo| fifo.len()) < prime_frames {
        if stop.load(Ordering::Acquire)
            || prime_started.elapsed() >= Duration::from_millis(PRIME_TIMEOUT_MS)
        {
            break;
        }
        let done = match unsafe { sys::reap(config.fd) } {
            Ok(pointer) => pointer,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                wait_for_reap(config.fd);
                continue;
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        if done.is_null() {
            wait_for_reap(config.fd);
            continue;
        }
        if let Some(index) = in_ptrs.iter().position(|&pointer| pointer == done) {
            if in_flight[index] {
                in_flight[index] = false;
                outstanding -= 1;
            }
            unsafe {
                absorb_in(
                    done,
                    packet_in,
                    &mut histogram,
                    &mut stats,
                    record,
                    fifo.as_mut(),
                    &mut packet_stereo,
                    &mut peak,
                );
                clear_urb(done);
            }
            match unsafe { sys::submit(config.fd, done) } {
                Ok(()) => {
                    in_flight[index] = true;
                    outstanding += 1;
                }
                Err(error) => {
                    if submit_error.is_none() {
                        submit_error = Some(error.raw_os_error().unwrap_or(0));
                    }
                }
            }
            continue;
        }
        // No OUT URB exists yet, so anything else is not ours.
        wait_for_reap(config.fd);
    }
    out_stats.underruns_start = out_stats.underruns;

    if have_out {
        for index in 0..depth.out_urbs {
            unsafe {
                clear_urb(out_ptrs[index]);
                fill_out_urb_with(
                    out_ptrs[index],
                    packet_out,
                    fifo
                        .as_mut()
                        .expect("have_out built the monitor fifo"),
                    &mut out_stats,
                    monitor_resampler.as_mut(),
                );
            }
            match unsafe { sys::submit(config.fd, out_ptrs[index]) } {
                Ok(()) => {
                    out_flight[index] = true;
                    outstanding += 1;
                }
                Err(error) => {
                    if submit_error.is_none() {
                        submit_error = Some(error.raw_os_error().unwrap_or(0));
                    }
                }
            }
        }
    }

    let started = Instant::now();
    let limit = if config.seconds > 0.0 {
        Some(Duration::from_secs_f64(config.seconds))
    } else {
        None
    };

    loop {
        let ending = stop.load(Ordering::Acquire)
            || limit.map_or(false, |limit| started.elapsed() >= limit);
        if ending || outstanding == 0 {
            break;
        }
        let done = match unsafe { sys::reap(config.fd) } {
            Ok(pointer) => pointer,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                wait_for_reap(config.fd);
                continue;
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        if done.is_null() {
            wait_for_reap(config.fd);
            continue;
        }

        if let Some(index) = in_ptrs.iter().position(|&pointer| pointer == done) {
            if in_flight[index] {
                in_flight[index] = false;
                outstanding -= 1;
            }
            unsafe {
                absorb_in(
                    done,
                    packet_in,
                    &mut histogram,
                    &mut stats,
                    record,
                    fifo.as_mut(),
                    &mut packet_stereo,
                    &mut peak,
                );
                clear_urb(done);
            }
            match unsafe { sys::submit(config.fd, done) } {
                Ok(()) => {
                    in_flight[index] = true;
                    outstanding += 1;
                }
                Err(error) => {
                    if submit_error.is_none() {
                        submit_error = Some(error.raw_os_error().unwrap_or(0));
                    }
                }
            }
            continue;
        }

        if out_ptrs.iter().any(|&pointer| pointer == done) {
            let mut pending: [*mut UsbdevfsUrb; DEPTH_MAX as usize + 1] =
                [std::ptr::null_mut(); DEPTH_MAX as usize + 1];
            let mut pending_len = 0usize;
            pending[pending_len] = done;
            pending_len += 1;

            // Before filling this OUT URB, absorb every capture completion that
            // is already queued. The IN URB covering the same interval finishes
            // first but may still be waiting to be reaped; filling ahead of it
            // is what zero-pads one whole OUT URB at the start of a take.
            let bound = depth.in_urbs + depth.out_urbs;
            for _ in 0..bound {
                let extra = match unsafe { sys::reap(config.fd) } {
                    Ok(pointer) => pointer,
                    Err(_) => break,
                };
                if extra.is_null() {
                    break;
                }
                if let Some(in_index) = in_ptrs.iter().position(|&pointer| pointer == extra) {
                    if in_flight[in_index] {
                        in_flight[in_index] = false;
                        outstanding -= 1;
                    }
                    unsafe {
                        absorb_in(
                            extra,
                            packet_in,
                            &mut histogram,
                            &mut stats,
                            record,
                            fifo.as_mut(),
                            &mut packet_stereo,
                            &mut peak,
                        );
                        clear_urb(extra);
                    }
                    match unsafe { sys::submit(config.fd, extra) } {
                        Ok(()) => {
                            in_flight[in_index] = true;
                            outstanding += 1;
                        }
                        Err(error) => {
                            if submit_error.is_none() {
                                submit_error = Some(error.raw_os_error().unwrap_or(0));
                            }
                        }
                    }
                } else if let Some(out_index) =
                    out_ptrs.iter().position(|&pointer| pointer == extra)
                {
                    // Another OUT completed too; it is filled after the absorb.
                    if out_flight[out_index] {
                        out_flight[out_index] = false;
                        outstanding -= 1;
                    }
                    if pending_len < pending.len() {
                        pending[pending_len] = extra;
                        pending_len += 1;
                    }
                }
            }

            for slot in 0..pending_len {
                let pointer = pending[slot];
                let Some(index) = out_ptrs.iter().position(|&candidate| candidate == pointer)
                else {
                    continue;
                };
                unsafe {
                    clear_urb(pointer);
                    fill_out_urb_with(
                        pointer,
                        packet_out,
                        fifo
                            .as_mut()
                            .expect("have_out built the monitor fifo"),
                        &mut out_stats,
                        monitor_resampler.as_mut(),
                    );
                }
                match unsafe { sys::submit(config.fd, pointer) } {
                    Ok(()) => {
                        out_flight[index] = true;
                        outstanding += 1;
                    }
                    Err(error) => {
                        if submit_error.is_none() {
                            submit_error = Some(error.raw_os_error().unwrap_or(0));
                        }
                    }
                }
            }
            continue;
        }

        // A pointer the kernel returned that is not ours: leave it alone.
        wait_for_reap(config.fd);
    }

    // Ask the kernel to discard whatever is still in flight, then reap it. The
    // fd stays open; Java closes it.
    for index in 0..depth.in_urbs {
        if in_flight[index] {
            unsafe { sys::discard(config.fd, in_ptrs[index]) };
        }
    }
    if have_out {
        for index in 0..depth.out_urbs {
            if out_flight[index] {
                unsafe { sys::discard(config.fd, out_ptrs[index]) };
            }
        }
    }
    let mut tries = 0;
    while outstanding > 0 && tries < 200 {
        match unsafe { sys::reap(config.fd) } {
            Ok(pointer) if !pointer.is_null() => {
                if let Some(index) = in_ptrs.iter().position(|&candidate| candidate == pointer) {
                    if in_flight[index] {
                        in_flight[index] = false;
                        outstanding -= 1;
                    }
                } else if let Some(index) =
                    out_ptrs.iter().position(|&candidate| candidate == pointer)
                {
                    if out_flight[index] {
                        out_flight[index] = false;
                        outstanding -= 1;
                    }
                }
            }
            _ => {
                tries += 1;
                thread::sleep(Duration::from_millis(1));
            }
        }
    }
    if outstanding > 0 {
        // The kernel may still write to these buffers. Leaking them is the safe
        // choice; Java's fd close drops the URBs right after this take.
        eprintln!(
            "jawn-audio usb: leaving {outstanding} isochronous URB(s) to the kernel; the fd close will drop them"
        );
        std::mem::forget(in_urbs);
        std::mem::forget(in_data);
        if have_out {
            std::mem::forget(out_urbs);
            std::mem::forget(out_data);
        }
    }

    let monitor_fill_max_ms = frames_to_ms(out_stats.fill_frames_max as u64, config.rate);
    let monitor_fill_avg_ms = if out_stats.fill_samples > 0 {
        frames_to_ms(
            out_stats.fill_frames_sum / out_stats.fill_samples,
            config.rate,
        )
    } else {
        0
    };
    let (fifo_capacity, high_water) = fifo
        .as_ref()
        .map_or((0, 0), |fifo| (fifo.capacity(), fifo.high_water()));
    let fifo_capacity_ms = frames_to_ms(fifo_capacity as u64, config.rate);
    let high_water_ms = frames_to_ms(high_water as u64, config.rate);
    let cadence = cadence(
        stats.frames_in,
        out_stats.packets,
        frames_per_out_packet,
        config.rate,
        monitor_out_rate,
    );

    Ok(UsbIoReport {
        packets_in: histogram_rows(&histogram),
        missed_in: stats.missed_in,
        bytes_in: stats.bytes_in,
        frames_in: stats.frames_in,
        dropped_ring: stats.dropped_ring,
        underruns_out: out_stats.underruns,
        underruns_out_start: out_stats.underruns_start,
        dropped_out: fifo.as_ref().map_or(0, |fifo| fifo.dropped()),
        out_packets: out_stats.packets,
        out_bytes: out_stats.bytes,
        monitor_ms: depth.monitor_ms(),
        in_delivery_ms: depth.in_delivery_ms(),
        monitor_fill_max_ms,
        monitor_fill_avg_ms,
        fifo_capacity_ms,
        high_water_ms,
        out_frames: cadence.out_frames,
        capture_ms: cadence.capture_ms,
        out_ms: cadence.out_ms,
        out_lag_ms: cadence.out_lag_ms,
        in_depth: depth,
        out_depth: depth,
        out_rate,
        rate_set,
        monitor_off,
        setinterface,
        sched,
        peak,
    })
}

// --- the take (Android with the Oboe feature, for the shared drain) ----------

#[cfg(all(target_os = "android", feature = "oboe"))]
fn run_usb_take(config: UsbConfig, stop: Arc<AtomicBool>) -> Result<UsbReport, String> {
    let plan_label = config
        .plan
        .as_ref()
        .map(|plan| plan.label())
        .unwrap_or_else(|| "raw".to_string());
    let rate = config.rate;
    // One ms of audio per packet at 48 kHz; the disk drain works in whole
    // packets, exactly as the Oboe take works in whole bursts.
    let period = (config.packet_in.max(4) as usize) / 4;
    let take = config.out.clone().unwrap_or_default();

    let (record, consumer) = monbus::new(crate::oboe_device::RING_FRAMES);
    let disk = match config.out.as_deref() {
        Some(path) => Some(
            crate::disk::DiskWriter::spawn(
                std::path::Path::new(path),
                rate,
                1,
                period,
                crate::oboe_device::DISK_QUEUE_BLOCKS,
            )
            .map_err(|error| format!("cannot write {path}: {error}"))?,
        ),
        None => None,
    };

    let sink_stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&sink_stop);
    let plan = config.plan.clone();
    let sink = thread::Builder::new()
        .name("jawn-audio-usb-disk".to_string())
        .spawn(move || {
            crate::oboe_device::drain_ring(consumer, disk, period, &thread_stop, plan, rate)
        })
        .map_err(|error| format!("cannot start the USB disk thread: {error}"))?;

    let io_result = run_usb_plan(&config, &stop, &record);
    sink_stop.store(true, Ordering::Release);
    let drained = sink
        .join()
        .map_err(|_| "the USB disk thread panicked".to_string())?
        .map_err(|error| format!("cannot finish the USB take: {error}"))?;
    let io = io_result?;

    Ok(UsbReport {
        rate,
        packets_in: io.packets_in,
        missed_in: io.missed_in,
        bytes_in: io.bytes_in,
        frames_in: io.frames_in,
        underruns_out: io.underruns_out,
        underruns_out_start: io.underruns_out_start,
        dropped_out: io.dropped_out,
        out_packets: io.out_packets,
        out_bytes: io.out_bytes,
        monitor_ms: io.monitor_ms,
        in_depth: (io.in_depth.in_urbs, io.in_depth.in_packets),
        out_depth: (io.out_depth.out_urbs, io.out_depth.out_packets),
        in_delivery_ms: io.in_delivery_ms,
        monitor_fill_max_ms: io.monitor_fill_max_ms,
        monitor_fill_avg_ms: io.monitor_fill_avg_ms,
        fifo_capacity_ms: io.fifo_capacity_ms,
        high_water_ms: io.high_water_ms,
        out_frames: io.out_frames,
        capture_ms: io.capture_ms,
        out_ms: io.out_ms,
        out_lag_ms: io.out_lag_ms,
        out_rate: io.out_rate,
        rate_set: io.rate_set,
        monitor_off: io.monitor_off,
        setinterface: io.setinterface,
        sched: io.sched,
        frames_captured: io.frames_in,
        frames_written: drained.written,
        dropped_ring: io.dropped_ring,
        dropped_disk: drained.dropped,
        peak: io.peak,
        plan: plan_label,
        take,
    })
}

#[cfg(not(all(target_os = "android", feature = "oboe")))]
fn run_usb_take(_config: UsbConfig, _stop: Arc<AtomicBool>) -> Result<UsbReport, String> {
    Err("the direct-USB backend needs the Android build (aarch64-linux-android with --features oboe)"
        .to_string())
}

// --- the plain-C ABI ---------------------------------------------------------

/// Set the process-wide USB depth for the next take. Every value is clamped
/// into 1..=8, except `out_urbs`, which is clamped into 2..=8: one OUT URB in
/// flight leaves a scheduling hole every URB. A negative number, or one past 64,
/// is refused with `{"ok":false,"error":...}`. The default stays four 8-packet
/// IN URBs and two 4-packet OUT URBs (32 ms capture, 8 ms monitor).
///
/// On success the answer repeats the applied depth, the effective OUT URBs
/// (`out_urbs_effective`), the OUT runway (`monitor_ms`, `out_urbs *
/// out_packets`) and the IN delivery window
/// (`in_delivery_ms`, `in_packets`). A take already in flight keeps the depth it
/// started with; the next `jawn_audio_start_usb` reads this one.
///
/// # Safety
/// The returned pointer is a C string this crate allocated; the caller owns it
/// and releases it the same way it releases every other reply from this ABI.
#[no_mangle]
pub unsafe extern "C" fn jawn_audio_set_usb_depth(
    in_urbs: i32,
    in_packets: i32,
    out_urbs: i32,
    out_packets: i32,
) -> *mut c_char {
    match UsbDepth::from_args(in_urbs, in_packets, out_urbs, out_packets) {
        Ok(depth) => {
            store_depth(depth);
            into_c_string(depth_status_json(depth))
        }
        Err(error) => into_c_string(error_json(&error)),
    }
}

/// Start a direct-USB (usbfs) take on a worker thread and return a JSON status
/// immediately. `ep_out < 0` is capture-only; `seconds <= 0` runs until
/// `jawn_audio_stop`. The one process-wide slot is shared with the Oboe take, so
/// `jawn_audio_stop` and `jawn_audio_status` reach this take too.
///
/// `plan` is parsed exactly as `jawn_audio_start_plan` parses it; a refused plan
/// arms no take.
///
/// # Safety
/// `out_path` and `plan` must be null or valid NUL-terminated C strings.
#[no_mangle]
pub unsafe extern "C" fn jawn_audio_start_usb(
    fd: i32,
    iface_in: i32,
    alt_in: i32,
    ep_in: i32,
    packet_in: i32,
    iface_out: i32,
    alt_out: i32,
    ep_out: i32,
    packet_out: i32,
    seconds: f64,
    out_path: *const c_char,
    plan: *const c_char,
) -> *mut c_char {
    let take = if out_path.is_null() {
        None
    } else {
        Some(CStr::from_ptr(out_path).to_string_lossy().into_owned())
    };
    let plan_text = if plan.is_null() {
        None
    } else {
        Some(CStr::from_ptr(plan).to_string_lossy().into_owned())
    };
    let plan = match crate::plan::parse_plan(plan_text.as_deref()) {
        Ok(plan) => plan,
        Err(error) => {
            return into_c_string(error_json(&format!("the take plan was refused: {error}")))
        }
    };
    if fd < 0 {
        return into_c_string(error_json("the USB connection has no usable file descriptor"));
    }
    if ep_in < 0 || packet_in <= 0 {
        return into_c_string(error_json(
            "the capture endpoint needs an endpoint number and a positive packet size",
        ));
    }

    let config = UsbConfig {
        fd,
        iface_in,
        alt_in,
        ep_in,
        packet_in,
        iface_out,
        alt_out,
        ep_out,
        packet_out,
        rate: USB_RATE,
        seconds,
        out: take.clone(),
        plan,
    };
    let plan_label = config
        .plan
        .as_ref()
        .map(|plan| plan.label())
        .unwrap_or_else(|| "raw".to_string());

    let mut current = lock_control();
    if current.handle.is_some() {
        return into_c_string(error_json("a take is already running"));
    }
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&stop);
    let status = match take.as_deref() {
        Some(path) => format!(
            "{{\"ok\":true,\"state\":\"started\",\"backend\":\"usb\",\"plan\":\"{}\",\"take\":\"{}\"}}",
            json_escape(&plan_label),
            json_escape(path)
        ),
        None => format!(
            "{{\"ok\":true,\"state\":\"started\",\"backend\":\"usb\",\"plan\":\"{}\"}}",
            json_escape(&plan_label)
        ),
    };
    current.status = status;
    current.stop = Some(Arc::clone(&stop));
    match thread::Builder::new()
        .name("jawn-audio-usb-take".to_string())
        .spawn(move || {
            let result = run_usb_take(config, thread_stop);
            let json = match result {
                Ok(report) => report_json(&report),
                Err(error) => error_json(&error),
            };
            let mut current = lock_control();
            current.status = json;
            current.handle = None;
            current.stop = None;
        }) {
        Ok(handle) => current.handle = Some(handle),
        Err(error) => {
            current.stop = None;
            current.status = error_json(&format!("cannot start the USB take thread: {error}"));
            let failed = current.status.clone();
            drop(current);
            return into_c_string(failed);
        }
    }
    let status = current.status.clone();
    drop(current);
    into_c_string(status)
}

// --- the direct-USB latency probe -------------------------------------------

/// One direct-USB round-trip measurement. `round_trip_frames` and
/// `round_trip_ms` carry the same number: the difference is in USB bus frames,
/// and one bus frame is one millisecond. `click_frame` and `heard_frame` are
/// `None` only on the monotonic fallback, which has no bus-frame space to name.
#[derive(Debug, Clone)]
pub(crate) struct UsbRoundTrip {
    pub(crate) method: String,
    pub(crate) click_frame: Option<u32>,
    pub(crate) heard_frame: Option<f64>,
    pub(crate) round_trip_frames: f64,
    pub(crate) round_trip_ms: f64,
    pub(crate) score: f32,
    pub(crate) packets_in: Vec<(u32, u64)>,
    pub(crate) missed_in: u64,
    pub(crate) in_depth: UsbDepth,
    pub(crate) out_rate: UsbOutRate,
    pub(crate) rate_set: UsbRateSet,
    pub(crate) sched: UsbSched,
    pub(crate) note: Option<String>,
}

/// The probe either measured, or heard nothing and still owes the caller the
/// best correlation it saw. A plain `Err` stays a refusal (a bad fd, a refused
/// submit, a click that could not be placed).
#[cfg(target_os = "android")]
pub(crate) enum ProbeOutcome {
    Measured(UsbRoundTrip),
    NoClick { best: f32, floor: f32 },
}

fn optional_u32(value: Option<u32>) -> String {
    value.map_or_else(|| "null".to_string(), |value| value.to_string())
}

fn optional_f64(value: Option<f64>) -> String {
    value.map_or_else(|| "null".to_string(), |value| format!("{value:.3}"))
}

fn optional_json_string(value: Option<&str>) -> String {
    value.map_or_else(|| "null".to_string(), |value| format!("\"{}\"", json_escape(value)))
}

fn roundtrip_json(report: &UsbRoundTrip) -> String {
    format!(
        "{{\"ok\":true,\"backend\":\"usb\",\"probe\":\"roundtrip\",\"method\":\"{}\",\"click_frame\":{},\"heard_frame\":{},\"round_trip_frames\":{:.3},\"round_trip_ms\":{:.3},\"score\":{:.3},\"packets_in\":{},\"missed_in\":{},\"in_depth\":{},\"out_rate\":{{\"ret\":{},\"errno\":{},\"raw\":\"{}\",\"hz\":{}}},\"rate_set\":{{\"target\":{},\"ret\":{},\"errno\":{},\"recipient\":\"{}\",\"verified\":{}}},\"sched\":{{\"policy\":{},\"priority\":{},\"errno\":{}}},\"note\":{}}}",
        json_escape(&report.method),
        optional_u32(report.click_frame),
        optional_f64(report.heard_frame),
        report.round_trip_frames,
        report.round_trip_ms,
        report.score,
        histogram_json(&report.packets_in),
        report.missed_in,
        depth_json(report.in_depth),
        report.out_rate.ret,
        report.out_rate.errno,
        json_escape(&report.out_rate.raw),
        report.out_rate.hz,
        report.rate_set.target,
        report.rate_set.ret,
        report.rate_set.errno,
        json_escape(report.rate_set.recipient),
        report.rate_set.verified,
        report.sched.policy,
        report.sched.priority,
        report.sched.errno,
        optional_json_string(report.note.as_deref()),
    )
}

/// The Oboe probe's failure shape: `ok:false`, the best correlation and the
/// floor, so a quiet cable reads as a number short of a detection rather than a
/// bare refusal.
fn roundtrip_no_click_json(best: f32, floor: f32, depth: UsbDepth) -> String {
    format!(
        "{{\"ok\":false,\"backend\":\"usb\",\"probe\":\"roundtrip\",\"error\":\"the probe heard no click (best correlation {best:.3}, floor {floor:.3}); the loopback may be open, silent or too quiet\",\"score\":{best:.3},\"floor\":{floor:.3},\"in_depth\":{}}}",
        depth_json(depth)
    )
}

/// Copy one completed IN URB into the probe's flat capture run and record where
/// each packet's frames landed on the bus. No allocation: `capture` and
/// `segments` were sized before the first submit.
///
/// # Safety
/// `done` must point at a kernel-returned URB image whose buffer covers
/// `number_of_packets * packet` bytes.
unsafe fn absorb_in_probe(
    done: *mut UsbdevfsUrb,
    packet: usize,
    capture: &mut [u8],
    captured_bytes: &mut usize,
    segments: &mut Vec<Segment>,
    histogram: &mut [u64],
    stats: &mut InStats,
) {
    let header = &*done;
    let base = header.buffer as *const u8;
    let count = header.number_of_packets.max(0) as usize;
    let start_frame = header.start_frame.max(0) as u32;
    let descs = (done as *const u8).add(URB_BYTES) as *const UsbdevfsIsoPacketDesc;
    for index in 0..count {
        let desc = &*descs.add(index);
        record_packet_length(histogram, desc.actual_length as usize);
        stats.bytes_in += u64::from(desc.actual_length);
        if desc.status as i32 == EXDEV {
            stats.missed_in += 1;
        }
        if desc.status != 0 || desc.actual_length == 0 {
            continue;
        }
        let length = (desc.actual_length as usize).min(packet);
        let frames = (length / 4).min(capture.len().saturating_sub(*captured_bytes) / 4);
        if frames == 0 {
            continue;
        }
        let source = std::slice::from_raw_parts(base.add(index * packet), frames * 4);
        capture[*captured_bytes..*captured_bytes + frames * 4].copy_from_slice(source);
        segments.push(Segment {
            capture_offset: *captured_bytes / 4,
            bus_frame: start_frame + index as u32,
            frames,
        });
        *captured_bytes += frames * 4;
        stats.frames_in += frames as u64;
    }
}

/// The probe the C ABI runs: capture for a 100 ms pre-roll, submit one OUT URB
/// whose first six packets carry the chirp, keep capturing, then place the chirp
/// in the capture and subtract the two bus frames.
///
/// The kernel fills `urb.start_frame` when it schedules an URB and returns it
/// with the completion; both directions come from the same controller counter,
/// so their difference is the round trip. When the playback completion carries
/// no frame (a zero or an HCD that does not write it back), the fallback times
/// the OUT submit and the IN completion with `Instant` and subtracts the frames
/// captured after the chirp — a number good to ±1–2 ms, reported as such.
#[cfg(target_os = "android")]
unsafe fn probe_usb_roundtrip(
    fd: i32,
    iface_in: i32,
    alt_in: i32,
    ep_in: i32,
    packet_in: i32,
    iface_out: i32,
    alt_out: i32,
    ep_out: i32,
    packet_out: i32,
    millis: i32,
) -> Result<ProbeOutcome, String> {
    use std::time::{Duration, Instant};

    if fd < 0 {
        return Err("the USB connection has no usable file descriptor".to_string());
    }
    if ep_in < 0 || packet_in < 4 {
        return Err(
            "the capture endpoint needs an endpoint number and at least one stereo frame per packet"
                .to_string(),
        );
    }
    if ep_out < 0 || packet_out < 4 {
        return Err(
            "the probe needs a playback endpoint and at least one stereo frame per packet"
                .to_string(),
        );
    }

    let packet_in = packet_in as usize;
    let packet_out = packet_out as usize;
    let depth = current_depth();
    let window_ms = millis.clamp(200, 1_500) as usize;
    let pre_roll_ms = 100.min(window_ms / 2);
    let post_roll_ms = window_ms - pre_roll_ms;

    let _ = sys::set_interface(fd, iface_in, alt_in);
    let _ = sys::set_interface(fd, iface_out, alt_out);

    // Bring the playback endpoint to the rate the probe's packet size implies
    // before the chirp is played, so the measurement is not a 48 kHz chirp into
    // a 32 kHz endpoint. The readback is reported beside the score either way.
    let (out_rate, rate_set) = set_playback_rate(
        fd,
        iface_out,
        ep_out,
        monitor_rate_for_packet(packet_out),
    );
    let sched = sys::request_realtime();

    // Every buffer is sized before the first submit, and never moves.
    let mut in_urbs: Vec<Urb> = (0..depth.in_urbs)
        .map(|_| Urb::new(depth.in_packets))
        .collect();
    let mut in_data = vec![0u8; depth.in_urbs * depth.in_packets * packet_in];
    let mut in_ptrs: Vec<*mut UsbdevfsUrb> = Vec::with_capacity(depth.in_urbs);
    for (index, urb) in in_urbs.iter_mut().enumerate() {
        let buffer = unsafe {
            in_data
                .as_mut_ptr()
                .add(index * depth.in_packets * packet_in) as *mut c_void
        };
        let pointer = urb.ptr();
        prepare_urb(
            pointer,
            ep_in as u8,
            packet_in,
            depth.in_packets,
            buffer,
        );
        in_ptrs.push(pointer);
    }

    // One OUT URB: six click packets and silence after them. A configured OUT
    // depth shorter than the chirp is widened for the probe only, so the whole
    // 288-frame chirp is always on the bus.
    let out_packets = depth.out_packets.max(CLICK_PACKETS);
    let click = rt::click(USB_RATE);
    let mut out_urb = Urb::new(out_packets);
    let mut out_data = vec![0u8; out_packets * packet_out];
    let placed = place_click(&mut out_data, packet_out, &click);
    if placed == 0 {
        return Err("the playback packet is too small to carry the click".to_string());
    }
    let out_ptr = out_urb.ptr();
    prepare_urb(
        out_ptr,
        ep_out as u8,
        packet_out,
        out_packets,
        out_data.as_mut_ptr() as *mut c_void,
    );

    // The capture run: up to the whole window plus a margin, stereo S16LE.
    let max_frames = (window_ms + 64) * (USB_RATE as usize / 1_000);
    let mut capture = vec![0u8; max_frames * 4];
    let mut captured_bytes = 0usize;
    // One row per packet, and every packet is at most 49 frames. Room for the
    // whole window plus the URBs the kernel still holds at the end, so the reap
    // path never grows the table.
    let mut segments: Vec<Segment> = Vec::with_capacity(
        max_frames / 48 + depth.in_urbs * depth.in_packets + 64,
    );
    let mut histogram = vec![0u64; packet_in + 2];
    let mut stats = InStats::default();

    let mut in_flight = vec![false; depth.in_urbs];
    let mut outstanding = 0usize;
    let mut submit_error: Option<i32> = None;
    for index in 0..depth.in_urbs {
        match sys::submit(fd, in_ptrs[index]) {
            Ok(()) => {
                in_flight[index] = true;
                outstanding += 1;
            }
            Err(error) => {
                if submit_error.is_none() {
                    submit_error = Some(error.raw_os_error().unwrap_or(0));
                }
            }
        }
    }
    if outstanding == 0 {
        return Err(format!(
            "every isochronous capture URB submit was refused (errno {})",
            submit_error.unwrap_or(0)
        ));
    }

    // Capture first and let it settle: the first URB's frames are a transient.
    let pre_roll_end = Instant::now() + Duration::from_millis(pre_roll_ms as u64);
    while Instant::now() < pre_roll_end && outstanding > 0 {
        let done = match sys::reap(fd) {
            Ok(pointer) => pointer,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_micros(200));
                continue;
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        if done.is_null() {
            thread::sleep(Duration::from_micros(200));
            continue;
        }
        if let Some(index) = in_ptrs.iter().position(|&pointer| pointer == done) {
            if in_flight[index] {
                in_flight[index] = false;
                outstanding -= 1;
            }
            absorb_in_probe(
                done,
                packet_in,
                &mut capture,
                &mut captured_bytes,
                &mut segments,
                &mut histogram,
                &mut stats,
            );
            clear_urb(done);
            match sys::submit(fd, done) {
                Ok(()) => {
                    in_flight[index] = true;
                    outstanding += 1;
                }
                Err(error) => {
                    if submit_error.is_none() {
                        submit_error = Some(error.raw_os_error().unwrap_or(0));
                    }
                }
            }
        }
    }

    // One OUT URB, submitted once. Its completion's `start_frame` is the bus
    // frame the chirp starts on. A refused submit is reported after the IN URBs
    // have been reaped, so no buffer is freed while the kernel owns it.
    let submit_at = Instant::now();
    let mut out_flight = false;
    let mut out_submit_error: Option<i32> = None;
    match sys::submit(fd, out_ptr) {
        Ok(()) => {
            out_flight = true;
            outstanding += 1;
        }
        Err(error) => {
            out_submit_error = Some(error.raw_os_error().unwrap_or(0));
        }
    }

    let deadline = submit_at + Duration::from_millis(post_roll_ms as u64);
    let mut out_start_frame: Option<u32> = None;
    let mut completions: Vec<(Instant, usize)> = Vec::with_capacity(window_ms + 64);

    while Instant::now() < deadline && outstanding > 0 {
        let done = match sys::reap(fd) {
            Ok(pointer) => pointer,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_micros(200));
                continue;
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        if done.is_null() {
            thread::sleep(Duration::from_micros(200));
            continue;
        }
        if let Some(index) = in_ptrs.iter().position(|&pointer| pointer == done) {
            if in_flight[index] {
                in_flight[index] = false;
                outstanding -= 1;
            }
            absorb_in_probe(
                done,
                packet_in,
                &mut capture,
                &mut captured_bytes,
                &mut segments,
                &mut histogram,
                &mut stats,
            );
            if completions.len() < completions.capacity() {
                completions.push((Instant::now(), captured_bytes / 4));
            }
            clear_urb(done);
            match sys::submit(fd, done) {
                Ok(()) => {
                    in_flight[index] = true;
                    outstanding += 1;
                }
                Err(error) => {
                    if submit_error.is_none() {
                        submit_error = Some(error.raw_os_error().unwrap_or(0));
                    }
                }
            }
            continue;
        }
        if done == out_ptr {
            if out_flight {
                out_flight = false;
                outstanding -= 1;
            }
            let header = &*done;
            if header.start_frame > 0 && out_start_frame.is_none() {
                out_start_frame = Some(header.start_frame as u32);
            }
            // No resubmit: one chirp, one frame to name.
            continue;
        }
        thread::sleep(Duration::from_micros(200));
    }

    // Cancel and reap every URB before returning; the fd stays Java's. If the
    // kernel still owns one after the bounded drain, leak it rather than free
    // memory it may still write.
    if out_flight {
        sys::discard(fd, out_ptr);
    }
    for index in 0..depth.in_urbs {
        if in_flight[index] {
            sys::discard(fd, in_ptrs[index]);
        }
    }
    let mut tries = 0;
    while outstanding > 0 && tries < 200 {
        match sys::reap(fd) {
            Ok(pointer) if !pointer.is_null() => {
                if let Some(index) = in_ptrs.iter().position(|&candidate| candidate == pointer) {
                    if in_flight[index] {
                        in_flight[index] = false;
                        outstanding -= 1;
                    }
                } else if pointer == out_ptr && out_flight {
                    out_flight = false;
                    outstanding -= 1;
                }
            }
            _ => {
                tries += 1;
                thread::sleep(Duration::from_millis(1));
            }
        }
    }
    if outstanding > 0 {
        eprintln!(
            "jawn-audio usb probe: leaving {outstanding} isochronous URB(s) to the kernel; the fd close will drop them"
        );
    }
    if in_flight.iter().any(|&flight| flight) {
        std::mem::forget(in_urbs);
        std::mem::forget(in_data);
    }
    if out_flight {
        std::mem::forget(out_urb);
        std::mem::forget(out_data);
    }
    if let Some(errno) = out_submit_error {
        return Err(format!("the playback URB submit was refused (errno {errno})"));
    }

    // Left channel only: the device's first channel is the signal on this path.
    let mono: Vec<f32> = capture[..captured_bytes]
        .chunks_exact(4)
        .map(|frame| f32::from(i16::from_le_bytes([frame[0], frame[1]])) / 32768.0)
        .collect();
    if mono.is_empty() {
        return Err("the probe captured no frames".to_string());
    }
    let from = (USB_RATE as usize / 20).min(mono.len());
    let best = rt::best_click(USB_RATE, &mono, from)
        .ok_or_else(|| "the probe captured less than one chirp".to_string())?;
    let heard = match rt::find_click(USB_RATE, &mono, from) {
        Some(hit) => hit,
        None => {
            return Ok(ProbeOutcome::NoClick {
                best: best.score,
                floor: rt::MIN_SCORE,
            })
        }
    };

    let (method, click_frame, heard_frame, round_trip_ms, note) =
        match out_start_frame.filter(|frame| *frame > 0) {
            Some(click_frame) => {
                let heard_frame = frame_at_offset(&segments, heard.offset).ok_or_else(|| {
                    "the capture segment table has no row for the heard sample".to_string()
                })?;
                let delta = bus_round_trip_ms(click_frame, heard_frame)?;
                (
                    "urb.start_frame".to_string(),
                    Some(click_frame),
                    Some(heard_frame),
                    delta,
                    None,
                )
            }
            None => {
                // Truly unavailable: time the OUT submit against the IN
                // completion that first contained the chirp, then take off the
                // frames captured after it. Good to ±1–2 ms.
                let (done_at, frames_then) = completions
                    .iter()
                    .copied()
                    .find(|(_, frames)| *frames > heard.offset)
                    .ok_or_else(|| {
                        "no capture completion contained the heard click".to_string()
                    })?;
                let elapsed_ms = done_at.saturating_duration_since(submit_at).as_secs_f64() * 1_000.0;
                let frames_after = (frames_then - heard.offset) as f64;
                let ms = elapsed_ms - frames_after / FRAMES_PER_BUS_FRAME;
                if !ms.is_finite() || ms < 0.0 {
                    return Err(format!(
                        "the monotonic timing is {ms:.3} ms; the click and the submit do not agree"
                    ));
                }
                if ms > 1_000.0 {
                    return Err(format!(
                        "the measured round trip is {ms:.1} ms, which is not a click in the same window"
                    ));
                }
                (
                    "monotonic (start_frame unavailable)".to_string(),
                    None,
                    None,
                    ms,
                    Some(
                        "start_frame was zero or absent; the monotonic fallback is ±1-2 ms"
                            .to_string(),
                    ),
                )
            }
        };

    Ok(ProbeOutcome::Measured(UsbRoundTrip {
        method,
        click_frame,
        heard_frame,
        round_trip_frames: round_trip_ms,
        round_trip_ms,
        score: heard.score,
        packets_in: histogram_rows(&histogram),
        missed_in: stats.missed_in,
        in_depth: depth,
        out_rate,
        rate_set,
        sched,
        note,
    }))
}

/// Measure the input-to-output round trip through the UM2's own cable loop,
/// using the kernel's USB bus frame numbers rather than wall-clock timestamps.
/// Blocks for at most `millis` (clamped to 200..=1500 ms).
///
/// The IN endpoints are open and streaming before the single OUT URB with the
/// chirp is submitted; both are selected with `SETINTERFACE` and both alts are
/// read back into the report's own probe. An `ok:false` answer carries either a
/// refusal sentence or, when the chirp was not heard, the best correlation and
/// the floor. The fd is never closed.
///
/// # Safety
/// `fd` must be a live usbfs connection owned by the caller; this function
/// submits and cancels iso URBs on it but never closes it. The returned pointer
/// is a C string this crate allocated.
#[no_mangle]
pub unsafe extern "C" fn jawn_audio_roundtrip_usb(
    fd: i32,
    iface_in: i32,
    alt_in: i32,
    ep_in: i32,
    packet_in: i32,
    iface_out: i32,
    alt_out: i32,
    ep_out: i32,
    packet_out: i32,
    millis: i32,
) -> *mut c_char {
    #[cfg(target_os = "android")]
    {
        match probe_usb_roundtrip(
            fd, iface_in, alt_in, ep_in, packet_in, iface_out, alt_out, ep_out, packet_out, millis,
        ) {
            Ok(ProbeOutcome::Measured(report)) => into_c_string(roundtrip_json(&report)),
            Ok(ProbeOutcome::NoClick { best, floor }) => {
                into_c_string(roundtrip_no_click_json(best, floor, current_depth()))
            }
            Err(error) => into_c_string(error_json(&error)),
        }
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = (
            fd, iface_in, alt_in, ep_in, packet_in, iface_out, alt_out, ep_out, packet_out, millis,
        );
        into_c_string(error_json(
            "the direct-USB round-trip probe needs the Android build (aarch64-linux-android) with the USB connection's fd",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{align_of, size_of};

    #[test]
    fn the_ioctl_numbers_match_the_ioc_derivation() {
        assert_eq!(USBDEVFS_CONTROL, ioc(IOC_READ_WRITE, U, 0, 24));
        assert_eq!(USBDEVFS_SETINTERFACE, ioc(IOC_READ, U, 4, 8));
        assert_eq!(USBDEVFS_SUBMITURB, ioc(IOC_READ, U, 10, 56));
        assert_eq!(USBDEVFS_DISCARDURB, ioc(IOC_NONE, U, 11, 0));
        assert_eq!(USBDEVFS_REAPURBNDELAY, ioc(IOC_WRITE, U, 13, 8));
        assert_eq!(USBDEVFS_CLAIMINTERFACE, ioc(IOC_READ, U, 15, 4));
        assert_eq!(USBDEVFS_RELEASEINTERFACE, ioc(IOC_READ, U, 16, 4));
        assert_eq!(USBDEVFS_URB_TYPE_ISO, 0, "iso is type 0, not 1");
        assert_eq!(USBDEVFS_URB_ISO_ASAP, 0x02);
    }

    #[test]
    fn the_kernel_structs_have_the_arm64_sizes() {
        assert_eq!(size_of::<UsbdevfsIsoPacketDesc>(), 12);
        assert_eq!(size_of::<UsbdevfsUrb>(), 56);
        assert_eq!(size_of::<UsbdevfsCtrlTransfer>(), 24);
        assert_eq!(size_of::<UsbdevfsSetInterface>(), 8);
        assert_eq!(URB_BYTES, 56);
        assert_eq!(DESC_BYTES, 12);
        // The trailing flexible array of descriptors starts immediately after
        // the 56-byte header; a test elsewhere writes and reads one at that
        // offset.
        assert_eq!(size_of::<UsbdevfsUrb>() + 8 * size_of::<UsbdevfsIsoPacketDesc>(), 152);
    }

    #[test]
    fn the_urb_image_is_aligned_and_sized_for_the_kernel() {
        let mut urb = Urb::new(PACKETS_PER_URB);
        assert_eq!(urb.byte_len(), 56 + PACKETS_PER_URB * 12);
        assert_eq!(
            urb.ptr() as usize % align_of::<UsbdevfsUrb>(),
            0,
            "the kernel writes a repr(C) struct through this pointer"
        );
    }

    #[test]
    fn preparing_an_urb_sets_the_request_the_kernel_reads() {
        let mut urb = Urb::new(PACKETS_PER_URB);
        let pointer = urb.ptr();
        unsafe {
            prepare_urb(
                pointer,
                0x84,
                196,
                PACKETS_PER_URB,
                std::ptr::null_mut::<c_void>(),
            );
            let header = &*pointer;
            assert_eq!(header.type_, USBDEVFS_URB_TYPE_ISO);
            assert_eq!(header.endpoint, 0x84);
            assert_eq!(header.flags, USBDEVFS_URB_ISO_ASAP);
            assert_eq!(header.number_of_packets, PACKETS_PER_URB as i32);
            assert_eq!(header.buffer_length, (196 * PACKETS_PER_URB) as i32);
            let descs = (pointer as *const u8).add(URB_BYTES) as *const UsbdevfsIsoPacketDesc;
            for index in 0..PACKETS_PER_URB {
                assert_eq!((*descs.add(index)).length, 196);
            }
            clear_urb(pointer);
            assert_eq!((*pointer).status, 0);
            assert_eq!((*descs).length, 196, "the request length survives a clear");
        }
    }

    #[test]
    fn the_out_fifo_drops_the_oldest_and_pads_an_underrun() {
        // Trim happens at the high water, not at the physical capacity.
        let mut fifo = OutFifo::new(200, 96);
        let block: Vec<f32> = (0..100)
            .flat_map(|frame| {
                // Frame 4 is the first that survives the trim; a distinct
                // in-range value proves it leads the packet.
                let value = if frame == 4 { 0.25 } else { -0.25 };
                [value, value]
            })
            .collect();
        fifo.push(&block);
        assert_eq!(fifo.dropped(), 4, "the oldest four frames go at the high water");
        assert_eq!(fifo.len(), 96);

        let mut packet = [0u8; 48 * 4];
        assert_eq!(fifo.fill_packet(48, &mut packet), 48);
        let left = i16::from_le_bytes([packet[0], packet[1]]);
        assert_eq!(left, crate::wav::to_i16(0.25), "frame 4, not frame 0, leads");

        let mut fifo = OutFifo::new(96, 96);
        let short: Vec<f32> = (0..10).flat_map(|_| [1.0f32, 1.0]).collect();
        fifo.push(&short);
        let mut packet = [0x7fu8; 48 * 4];
        assert_eq!(fifo.fill_packet(48, &mut packet), 10, "an underrun is short");
        assert_eq!(i16::from_le_bytes([packet[9 * 4], packet[9 * 4 + 1]]), 32767);
        assert_eq!(packet[10 * 4], 0, "the rest is silence, not a stale tail");
        assert_eq!(packet[48 * 4 - 1], 0);
    }

    #[test]
    fn the_monitor_resampler_turns_48k_into_32k_without_a_shortfall() {
        let mut fifo = OutFifo::new(1_000, 1_000);
        let block: Vec<f32> = (0..48)
            .flat_map(|frame| {
                let value = frame as f32 / 48.0;
                [value, value]
            })
            .collect();
        fifo.push(&block);

        let mut resampler = MonitorResampler::new(48_000, 32_000);
        let mut packet = [0u8; 32 * 4];
        assert_eq!(
            fifo.fill_packet_resampled(&mut resampler, 32, &mut packet),
            32,
            "48 input frames carry 32 output frames at 3:2"
        );
        assert_eq!(
            i16::from_le_bytes([packet[0], packet[1]]),
            0,
            "the first output is the first input frame"
        );
        let last = i16::from_le_bytes([packet[31 * 4], packet[31 * 4 + 1]]);
        assert!(last > 30_000, "the ramp reaches the end: {last}");

        // A packet the queue cannot feed is short rather than a stale tail.
        let mut short = OutFifo::new(100, 100);
        short.push(&[0.0, 0.0, 0.5, 0.5, 1.0, 1.0]);
        let mut resampler = MonitorResampler::new(48_000, 32_000);
        let mut packet = [0x7fu8; 32 * 4];
        assert!(
            short.fill_packet_resampled(&mut resampler, 32, &mut packet) < 32,
            "an underrun is short"
        );
        assert_eq!(packet[32 * 4 - 1], 0, "the rest is silence");
    }

    #[test]
    fn the_out_depth_is_its_own_and_the_monitor_runway_is_eight_ms() {
        assert_eq!(URB_COUNT, 4, "the capture runway stays four URBs deep");
        assert_eq!((OUT_URB_COUNT, OUT_PACKETS_PER_URB), (2, 4));
        assert_eq!(
            monitor_runway_ms(OUT_URB_COUNT, OUT_PACKETS_PER_URB, 192, USB_RATE),
            8,
            "two four-packet monitor URBs are 8 ms, not the IN side's 32"
        );
        assert_eq!(
            monitor_runway_ms(OUT_URB_COUNT, OUT_PACKETS_PER_URB, 288, USB_RATE),
            12,
            "a 24-bit stereo packet is 72 frames, so four packets are still 1 ms"
        );
        assert_eq!(monitor_runway_ms(OUT_URB_COUNT, OUT_PACKETS_PER_URB, 192, 0), 0);
    }

    #[test]
    fn the_monitor_priming_threshold_is_the_whole_out_depth() {
        let prime = OUT_URB_COUNT * OUT_PACKETS_PER_URB * (192 / 4);
        let frames_per_out_urb = OUT_PACKETS_PER_URB * (192 / 4);
        let frames_per_in_urb = PACKETS_PER_URB * (192 / 4);
        assert_eq!(prime, 384, "eight 1 ms packets of 48 frames");
        let capacity = monitor_fifo_capacity(prime, frames_per_in_urb, frames_per_out_urb);
        let high_water = monitor_high_water(prime, frames_per_in_urb);
        let mut fifo = OutFifo::new(capacity, high_water);
        assert_eq!(fifo.len(), 0, "the monitor starts empty");
        let block: Vec<f32> = (0..prime).flat_map(|_| [0.1f32, 0.1]).collect();
        fifo.push(&block);
        assert_eq!(fifo.len(), prime, "the fifo holds the whole runway");
        assert_eq!(fifo.dropped(), 0, "priming is not trimmed");
        assert_eq!(high_water, prime + frames_per_in_urb, "one capture burst of headroom");
        assert_eq!(
            capacity,
            prime + frames_per_in_urb + frames_per_out_urb + OUT_BACKLOG_FRAMES
        );
    }

    #[test]
    fn the_depth_clamps_to_one_through_eight_and_keeps_the_default() {
        assert_eq!(
            UsbDepth::DEFAULT,
            UsbDepth {
                in_urbs: 4,
                in_packets: 8,
                out_urbs: 2,
                out_packets: 4,
            },
            "the landed depth stays the default"
        );
        assert_eq!(UsbDepth::DEFAULT.monitor_ms(), 8);
        assert_eq!(UsbDepth::DEFAULT.in_delivery_ms(), 8, "eight 1 ms IN packets");

        // Zero is not negative: it clamps up to the shortest depth, except the
        // OUT URBs, which never go below two in flight.
        assert_eq!(
            UsbDepth::from_args(0, 0, 0, 0).unwrap(),
            UsbDepth {
                in_urbs: 1,
                in_packets: 1,
                out_urbs: 2,
                out_packets: 1,
            }
        );
        // One OUT URB leaves a hole every URB; the effective depth is two.
        assert_eq!(UsbDepth::from_args(4, 8, 1, 8).unwrap().out_urbs, 2);
        assert_eq!(UsbDepth::from_args(4, 8, 2, 8).unwrap().out_urbs, 2);
        // A large but sane value clamps down to eight.
        assert_eq!(
            UsbDepth::from_args(64, 64, 64, 64).unwrap(),
            UsbDepth {
                in_urbs: 8,
                in_packets: 8,
                out_urbs: 8,
                out_packets: 8,
            }
        );
        // Nonsense is refused, not clamped.
        assert!(UsbDepth::from_args(-1, 8, 2, 4).is_err());
        assert!(UsbDepth::from_args(4, 8, 2, 65).is_err());
        assert!(UsbDepth::from_args(4, i32::MIN, 2, 4).is_err());

        // The process-wide word packs all four, so a reader cannot see a mix.
        let depth = UsbDepth {
            in_urbs: 1,
            in_packets: 2,
            out_urbs: 3,
            out_packets: 4,
        };
        assert_eq!(unpack_depth(pack_depth(depth)), depth);
        assert_eq!(unpack_depth(pack_depth(UsbDepth::DEFAULT)), UsbDepth::DEFAULT);
        // Even a stale word carrying one OUT URB decodes to the floor.
        let one_out = UsbDepth {
            out_urbs: 1,
            ..UsbDepth::DEFAULT
        };
        assert_eq!(
            unpack_depth(pack_depth(one_out)).out_urbs,
            OUT_URBS_MIN as usize
        );
        assert!(depth_status_json(UsbDepth::from_args(4, 8, 1, 8).unwrap())
            .contains("\"out_urbs_effective\":2"));
    }

    #[test]
    fn the_priming_threshold_follows_the_configured_depth() {
        let frames_per_packet = 192 / 4;
        for out_urbs in 1..=8usize {
            for out_packets in 1..=8usize {
                let depth = UsbDepth {
                    in_urbs: 4,
                    in_packets: 8,
                    out_urbs,
                    out_packets,
                };
                let prime = depth.prime_frames(frames_per_packet);
                assert_eq!(prime, out_urbs * out_packets * frames_per_packet);
                assert_eq!(depth.monitor_ms(), (out_urbs * out_packets) as u32);
                let frames_per_out_urb = out_packets * frames_per_packet;
                let frames_per_in_urb = depth.in_packets * frames_per_packet;
                let capacity =
                    monitor_fifo_capacity(prime, frames_per_in_urb, frames_per_out_urb);
                let high_water = monitor_high_water(prime, frames_per_in_urb);
                assert_eq!(
                    capacity,
                    prime + frames_per_in_urb + frames_per_out_urb + OUT_BACKLOG_FRAMES
                );
                assert_eq!(high_water, prime + frames_per_in_urb);
                let mut fifo = OutFifo::new(capacity, high_water);
                let block: Vec<f32> = (0..prime).flat_map(|_| [0.1f32, 0.1]).collect();
                fifo.push(&block);
                assert_eq!(fifo.len(), prime, "a {out_urbs}x{out_packets} depth primes whole");
                assert_eq!(fifo.dropped(), 0, "the scaled fifo does not trim the prime");
            }
        }
        // The IN side's delivery window is its own packet count.
        for in_packets in 1..=8usize {
            let depth = UsbDepth {
                in_packets,
                ..UsbDepth::DEFAULT
            };
            assert_eq!(depth.in_delivery_ms(), in_packets as u32);
        }
    }

    #[test]
    fn the_monitor_fifo_trims_at_its_high_water_at_every_depth() {
        let frames = 48usize;
        for in_packets in 1..=8usize {
            for out_urbs in 1..=8usize {
                for out_packets in 1..=8usize {
                    let depth = UsbDepth {
                        in_urbs: 4,
                        in_packets,
                        out_urbs,
                        out_packets,
                    };
                    let in_burst = in_packets * frames;
                    let out_burst = out_packets * frames;
                    let prime = depth.prime_frames(frames);
                    let capacity = monitor_fifo_capacity(prime, in_burst, out_burst);
                    let high_water = monitor_high_water(prime, in_burst);
                    assert!(capacity > high_water, "the capacity leaves room above the high water");

                    let mut fifo = OutFifo::new(capacity, high_water);
                    let prime_block: Vec<f32> = (0..prime).flat_map(|_| [0.25f32, 0.25]).collect();
                    fifo.push(&prime_block);
                    assert_eq!(fifo.len(), prime, "the prime sits at the runway");
                    assert_eq!(fifo.dropped(), 0);

                    // One whole capture burst may land on top, still lossless.
                    let burst: Vec<f32> = (0..in_burst).flat_map(|_| [0.5f32, 0.5]).collect();
                    fifo.push(&burst);
                    assert_eq!(fifo.len(), high_water, "one IN burst fills to the high water");
                    assert_eq!(fifo.dropped(), 0, "a burst at the trim point is not loss");

                    // A second burst drops exactly its own frames, and counts them.
                    fifo.push(&burst);
                    assert_eq!(fifo.len(), high_water);
                    assert_eq!(
                        fifo.dropped(),
                        in_burst as u64,
                        "the excess is counted, never silently lost"
                    );

                    // The OUT side then drains without a pad while audio holds.
                    let mut out_burst_bytes = vec![0u8; out_burst * 4];
                    for packet in 0..out_packets {
                        let slice = &mut out_burst_bytes[packet * frames * 4..(packet + 1) * frames * 4];
                        assert_eq!(fifo.fill_packet(frames, slice), frames);
                    }
                }
            }
        }
    }

    #[test]
    fn the_segment_table_maps_an_offset_to_a_fractional_bus_frame() {
        // A 49-frame (196-byte) packet shifts every later capture offset by one
        // frame: offset 97 is the start of the third packet, not 96.
        let segments = vec![
            Segment {
                capture_offset: 0,
                bus_frame: 100,
                frames: 48,
            },
            Segment {
                capture_offset: 48,
                bus_frame: 101,
                frames: 49,
            },
            Segment {
                capture_offset: 97,
                bus_frame: 102,
                frames: 48,
            },
        ];
        assert_eq!(frame_at_offset(&segments, 0), Some(100.0));
        assert!((frame_at_offset(&segments, 24).unwrap() - 100.5).abs() < 1e-9);
        assert_eq!(frame_at_offset(&segments, 48), Some(101.0));
        assert!((frame_at_offset(&segments, 60).unwrap() - 101.25).abs() < 1e-9);
        assert_eq!(
            frame_at_offset(&segments, 97),
            Some(102.0),
            "the 49-frame packet is counted, not assumed to be 48"
        );
        assert!((frame_at_offset(&segments, 145).unwrap() - 103.0).abs() < 1e-9);
        assert_eq!(frame_at_offset(&[], 0), None);

        // The subtraction: a click on bus frame 100 heard on 102.25 is 2.25 ms.
        assert_eq!(bus_round_trip_ms(100, 102.25).unwrap(), 2.25);
        assert!(bus_round_trip_ms(0, 102.0).is_err(), "no start_frame is no measurement");
        assert!(bus_round_trip_ms(100, 99.0).is_err(), "heard before played is refused");
        assert!(bus_round_trip_ms(100, 1_101.0).is_err(), "over a second is not this click");
    }

    #[test]
    fn the_click_fills_six_packets_and_the_rest_is_silence() {
        let click = crate::roundtrip::click(USB_RATE);
        assert_eq!(click.len(), 288, "6 ms of chirp at 48 kHz");
        let packet = 192usize;
        let mut buffer = vec![0x7fu8; packet * 8];
        assert_eq!(place_click(&mut buffer, packet, &click), 288);
        let first = i16::from_le_bytes([buffer[0], buffer[1]]);
        assert_eq!(first, crate::wav::to_i16(click[0]));
        assert_eq!(buffer[2], buffer[0], "the mono chirp is on both channels");
        assert_eq!(buffer[3], buffer[1]);
        assert!(
            buffer[CLICK_PACKETS * packet..].iter().all(|byte| *byte == 0),
            "everything after the sixth packet is silence"
        );

        // A 49-frame packet holds six frames more than the chirp: those, and the
        // packets after them, are zero.
        let packet = 196usize;
        let mut buffer = vec![0x7fu8; packet * 8];
        assert_eq!(place_click(&mut buffer, packet, &click), 288);
        assert!(buffer[288 * 4..CLICK_PACKETS * packet].iter().all(|byte| *byte == 0));
        assert!(buffer[CLICK_PACKETS * packet..].iter().all(|byte| *byte == 0));
    }

    #[test]
    fn the_roundtrip_report_carries_the_bus_frame_measurement() {
        let report = UsbRoundTrip {
            method: "urb.start_frame".to_string(),
            click_frame: Some(100),
            heard_frame: Some(102.5),
            round_trip_frames: 2.5,
            round_trip_ms: 2.5,
            score: 0.912,
            packets_in: vec![(192, 5_000), (196, 3)],
            missed_in: 0,
            in_depth: UsbDepth::DEFAULT,
            out_rate: UsbOutRate {
                ret: 3,
                errno: 0,
                raw: "007d00".to_string(),
                hz: 32_000,
            },
            rate_set: UsbRateSet {
                target: 48_000,
                ret: -1,
                errno: 22,
                recipient: "none",
                verified: false,
            },
            sched: UsbSched {
                policy: 1,
                priority: 80,
                errno: 13,
            },
            note: None,
        };
        let text = roundtrip_json(&report);
        for needle in [
            "\"ok\":true",
            "\"backend\":\"usb\"",
            "\"probe\":\"roundtrip\"",
            "\"method\":\"urb.start_frame\"",
            "\"click_frame\":100",
            "\"heard_frame\":102.500",
            "\"round_trip_frames\":2.500",
            "\"round_trip_ms\":2.500",
            "\"score\":0.912",
            "\"packets_in\":{\"192\":5000,\"196\":3}",
            "\"missed_in\":0",
            "\"in_depth\":{\"urbs\":4,\"packets\":8}",
            "\"out_rate\":{\"ret\":3,\"errno\":0,\"raw\":\"007d00\",\"hz\":32000}",
            "\"rate_set\":{\"target\":48000,\"ret\":-1,\"errno\":22,\"recipient\":\"none\",\"verified\":false}",
            "\"sched\":{\"policy\":1,\"priority\":80,\"errno\":13}",
            "\"note\":null",
        ] {
            assert!(text.contains(needle), "{needle} missing from {text}");
        }

        // The fallback names its method and its precision, and has no bus frame.
        let fallback = UsbRoundTrip {
            method: "monotonic (start_frame unavailable)".to_string(),
            click_frame: None,
            heard_frame: None,
            round_trip_ms: 3.5,
            round_trip_frames: 3.5,
            note: Some("±1-2 ms".to_string()),
            ..report
        };
        let text = roundtrip_json(&fallback);
        assert!(text.contains("\"method\":\"monotonic (start_frame unavailable)\""));
        assert!(text.contains("\"click_frame\":null"));
        assert!(text.contains("\"heard_frame\":null"));
        assert!(text.contains("\"note\":\"±1-2 ms\""));

        let miss = roundtrip_no_click_json(0.21, crate::roundtrip::MIN_SCORE, UsbDepth::DEFAULT);
        assert!(miss.contains("\"ok\":false"));
        assert!(miss.contains("\"score\":0.210"));
        assert!(miss.contains("\"floor\":0.350"));
    }

    #[test]
    fn a_short_prime_is_padded_and_counted_as_an_underrun() {
        let packet = 192usize;
        let packets = OUT_PACKETS_PER_URB;
        let mut urb = Urb::new(packets);
        let mut data = vec![0u8; packet * packets];
        let pointer = urb.ptr();
        unsafe {
            prepare_urb(
                pointer,
                0x03,
                packet,
                packets,
                data.as_mut_ptr() as *mut c_void,
            );
        }
        // Three of the four 48-frame packets exist; the fourth must zero-fill.
        let block: Vec<f32> = (0..144).flat_map(|_| [0.5f32, 0.5]).collect();
        let frames_per_out_urb = packets * (packet / 4);
        let frames_per_in_urb = PACKETS_PER_URB * (packet / 4);
        let prime = OUT_URB_COUNT * frames_per_out_urb;
        let mut fifo = OutFifo::new(
            monitor_fifo_capacity(prime, frames_per_in_urb, frames_per_out_urb),
            monitor_high_water(prime, frames_per_in_urb),
        );
        fifo.push(&block);
        let mut stats = OutStats::default();
        unsafe { fill_out_urb(pointer, packet, &mut fifo, &mut stats) };
        assert_eq!(stats.packets, packets as u64, "every packet is submitted");
        assert_eq!(stats.bytes, (packet * packets) as u64, "192 bytes per packet");
        assert_eq!(stats.underruns, 1, "only the last packet fell short");
        assert_eq!(stats.underruns_start, 0, "no warm-up underrun was snapshotted");
        assert_eq!(stats.fill_samples, 1, "the fill was observed");
        assert_eq!(stats.fill_frames_max, 144, "the fifo held three packets");
        assert_eq!(fifo.len(), 0, "the audio that existed was played");
        assert_eq!(data[3 * packet], 0, "the short packet is silence, not stale audio");
    }

    #[test]
    fn the_out_pipeline_primes_and_refills_two_urbs() {
        let packet = 192usize;
        let frames = packet / 4;
        let out_packets = 4usize;
        let out_urbs = 2usize;
        let in_packets = 8usize;
        let out_burst = out_packets * frames;
        let in_burst = in_packets * frames;
        let depth = UsbDepth {
            in_urbs: 4,
            in_packets,
            out_urbs,
            out_packets,
        };
        let prime = depth.prime_frames(frames);
        let capacity = monitor_fifo_capacity(prime, in_burst, out_burst);
        let high_water = monitor_high_water(prime, in_burst);
        assert_eq!(prime, out_urbs * out_burst);

        let mut urbs: Vec<Urb> = (0..out_urbs).map(|_| Urb::new(out_packets)).collect();
        let mut data = vec![0u8; out_urbs * out_packets * packet];
        let mut ptrs = Vec::new();
        for (index, urb) in urbs.iter_mut().enumerate() {
            let buffer = unsafe {
                data.as_mut_ptr().add(index * out_packets * packet) as *mut c_void
            };
            let pointer = urb.ptr();
            unsafe { prepare_urb(pointer, 0x02, packet, out_packets, buffer) };
            ptrs.push(pointer);
        }

        // Priming fills both URBs; neither is short and the fifo is emptied.
        let mut fifo = OutFifo::new(capacity, high_water);
        fifo.push(&vec![0.5f32; prime * 2]);
        let mut stats = OutStats::default();
        for &pointer in &ptrs {
            unsafe { fill_out_urb(pointer, packet, &mut fifo, &mut stats) };
        }
        assert_eq!(stats.underruns, 0, "both primed URBs were full");
        assert_eq!(stats.packets, (out_urbs * out_packets) as u64);
        assert_eq!(fifo.len(), 0);

        // The first URB completes. The second stays in flight while the capture
        // burst for the next interval is absorbed and the first is refilled.
        fifo.push(&vec![0.5f32; in_burst * 2]);
        unsafe { clear_urb(ptrs[0]); fill_out_urb(ptrs[0], packet, &mut fifo, &mut stats) };
        assert_eq!(
            stats.underruns, 0,
            "with two URBs queued, absorb-then-refill leaves no gap"
        );
        assert_eq!(fifo.len(), in_burst - out_burst);

        // The same refill before the absorb would have been short once.
        let mut fifo = OutFifo::new(capacity, high_water);
        fifo.push(&vec![0.5f32; prime * 2]);
        let mut stats = OutStats::default();
        for &pointer in &ptrs {
            unsafe { fill_out_urb(pointer, packet, &mut fifo, &mut stats) };
        }
        unsafe { clear_urb(ptrs[0]); fill_out_urb(ptrs[0], packet, &mut fifo, &mut stats) };
        assert_eq!(
            stats.underruns, out_packets as u64,
            "refilling ahead of the absorb starves the refill"
        );
    }

    #[test]
    fn the_cadence_counters_expose_a_starved_out_stream() {
        let frames_per_packet = 48usize;
        let balanced = cadence(48_000, 1_000, frames_per_packet, 48_000, 48_000);
        assert_eq!(balanced.out_frames, 48_000);
        assert_eq!(balanced.capture_ms, 1_000);
        assert_eq!(balanced.out_ms, 1_000);
        assert_eq!(balanced.out_lag_ms, 0, "a continuous OUT stream lags nothing");

        let starved = cadence(48_000, 944, frames_per_packet, 48_000, 48_000);
        assert_eq!(starved.out_ms, 944);
        assert_eq!(starved.out_lag_ms, 56, "the hole is visible as lag");

        // A shorter take rounds both sides to the same whole millisecond.
        let short = cadence(13_272, 277, frames_per_packet, 48_000, 48_000);
        assert_eq!(short.capture_ms, 277);
        assert_eq!(short.out_ms, 277);
        assert_eq!(short.out_lag_ms, 0);

        assert_eq!(
            cadence(48_000, 1_000, frames_per_packet, 0, 0).out_lag_ms,
            0
        );

        // A 32 kHz monitor: 1,000 packets of 32 frames is still 1,000 ms even
        // though the capture side is 48 kHz.
        let resampled = cadence(48_000, 1_000, 32, 48_000, 32_000);
        assert_eq!(resampled.out_frames, 32_000);
        assert_eq!(resampled.capture_ms, 1_000);
        assert_eq!(resampled.out_ms, 1_000);
        assert_eq!(resampled.out_lag_ms, 0);
    }

    #[test]
    fn absorbing_the_completed_capture_before_refilling_removes_the_start_underrun() {
        let packet = 192usize;
        let frames = packet / 4;
        let out_packets = 4usize; // 1x4: a 4 ms runway
        let in_packets = 8usize; // one IN burst is 8 ms
        let out_burst = out_packets * frames;
        let in_burst = in_packets * frames;
        let prime = out_burst; // out_urbs = 1
        let capacity = monitor_fifo_capacity(prime, in_burst, out_burst);
        let high_water = monitor_high_water(prime, in_burst);

        let mut urb = Urb::new(out_packets);
        let mut data = vec![0u8; packet * out_packets];
        let pointer = urb.ptr();
        unsafe {
            prepare_urb(pointer, 0x02, packet, out_packets, data.as_mut_ptr() as *mut c_void);
        }

        // Old order: the first URB drains the whole prime, then the refill runs
        // before the capture covering that interval has been absorbed.
        let mut fifo = OutFifo::new(capacity, high_water);
        fifo.push(&vec![0.5f32; prime * 2]);
        let mut stats = OutStats::default();
        unsafe { fill_out_urb(pointer, packet, &mut fifo, &mut stats) };
        assert_eq!(stats.underruns, 0, "the prime fills the first OUT URB");
        unsafe { clear_urb(pointer); fill_out_urb(pointer, packet, &mut fifo, &mut stats) };
        assert_eq!(
            stats.underruns, out_packets as u64,
            "refilling ahead of the capture zero-pads one whole URB"
        );

        // New order: absorb the capture burst that covers the same interval
        // first, then refill from the fresher fifo.
        let mut fifo = OutFifo::new(capacity, high_water);
        fifo.push(&vec![0.5f32; prime * 2]);
        let mut stats = OutStats::default();
        unsafe { fill_out_urb(pointer, packet, &mut fifo, &mut stats) };
        fifo.push(&vec![0.5f32; in_burst * 2]);
        unsafe { clear_urb(pointer); fill_out_urb(pointer, packet, &mut fifo, &mut stats) };
        assert_eq!(stats.underruns, 0, "absorb-then-refill leaves no gap");
        assert_eq!(fifo.len(), in_burst - out_burst, "steady fill stays near the runway");
    }

    #[test]
    fn the_out_rate_probe_decodes_the_uac1_three_bytes() {
        assert_eq!(decode_sample_rate(&[0x80, 0xbb, 0x00]), 48_000);
        assert_eq!(
            decode_sample_rate(&[0x00, 0x7d, 0x00]),
            32_000,
            "the P0 probe's answer on the playback endpoint"
        );
        assert_eq!(decode_sample_rate(&[0x80, 0xbb]), 0, "a short read has no rate");
        assert_eq!(hex_bytes(&[0x80, 0xbb, 0x00]), "80bb00");
        assert_eq!(hex_bytes(&[]), "");
    }

    #[test]
    fn the_rate_target_comes_from_the_packet_and_is_encoded_little_endian() {
        assert_eq!(monitor_rate_for_packet(192), 48_000);
        assert_eq!(monitor_rate_for_packet(128), 32_000);
        assert_eq!(monitor_rate_for_packet(4), 1_000);
        assert_eq!(sample_rate_bytes(48_000), [0x80, 0xbb, 0x00]);
        assert_eq!(sample_rate_bytes(32_000), [0x00, 0x7d, 0x00]);
        assert_eq!(decode_sample_rate(&sample_rate_bytes(44_100)), 44_100);
        assert!(monitor_rate_ok(192, 48_000));
        assert!(
            monitor_rate_ok(192, 0),
            "a failed read is not evidence of a mismatch"
        );
        assert!(!monitor_rate_ok(192, 32_000));
        assert!(!monitor_rate_ok(128, 48_000));
        assert_eq!(monitor_fallback_rate(192, 48_000), Some(48_000));
        assert_eq!(
            monitor_fallback_rate(192, 32_000),
            Some(32_000),
            "the UM2's endpoint rate is an integer number of frames per ms"
        );
        assert_eq!(
            monitor_fallback_rate(192, 44_100),
            None,
            "44.1 kHz cannot be carried by whole 1 ms packets"
        );
        assert_eq!(
            monitor_fallback_rate(192, 0),
            Some(48_000),
            "a failed read keeps the capture rate"
        );
    }

    #[test]
    fn the_packet_histogram_counts_each_length_and_the_overflow() {
        let packet = 196usize;
        let mut histogram = vec![0u64; packet + 2];
        record_packet_length(&mut histogram, 192);
        record_packet_length(&mut histogram, 196);
        record_packet_length(&mut histogram, 196);
        record_packet_length(&mut histogram, 300);
        assert_eq!(
            histogram_rows(&histogram),
            vec![(192, 1), (196, 2), (197, 1)]
        );
        assert_eq!(histogram_json(&[(192, 1), (196, 2)]), "{\"192\":1,\"196\":2}");
    }

    #[test]
    fn the_report_json_escapes_the_take_and_plan() {
        let report = UsbReport {
            rate: 48_000,
            packets_in: vec![(192, 37), (196, 4)],
            missed_in: 2,
            bytes_in: 7_680,
            frames_in: 1_920,
            underruns_out: 0,
            underruns_out_start: 0,
            dropped_out: 0,
            out_packets: 0,
            out_bytes: 0,
            monitor_ms: 8,
            in_depth: (4, 8),
            out_depth: (2, 4),
            in_delivery_ms: 8,
            monitor_fill_max_ms: 9,
            monitor_fill_avg_ms: 7,
            fifo_capacity_ms: 13,
            high_water_ms: 11,
            out_frames: 141_312,
            capture_ms: 3_000,
            out_ms: 2_944,
            out_lag_ms: 56,
            out_rate: UsbOutRate {
                ret: 3,
                errno: 0,
                raw: "80bb00".to_string(),
                hz: 48_000,
            },
            rate_set: UsbRateSet {
                target: 48_000,
                ret: 3,
                errno: 0,
                recipient: "endpoint",
                verified: true,
            },
            monitor_off: None,
            setinterface: UsbSetInterface { ret: 0, errno: 0 },
            sched: UsbSched {
                policy: 1,
                priority: 80,
                errno: 13,
            },
            frames_captured: 1_920,
            frames_written: 1_920,
            dropped_ring: 0,
            dropped_disk: 0,
            peak: 0.31,
            plan: "tone+delay".to_string(),
            take: "/data/a\"b\\c.wav".to_string(),
        };
        let text = report_json(&report);
        for needle in [
            "\"ok\":true",
            "\"backend\":\"usb\"",
            "\"packets_in\":{\"192\":37,\"196\":4}",
            "\"missed_in\":2",
            "\"frames_in\":1920",
            "\"underruns_out\":0",
            "\"underruns_out_start\":0",
            "\"out_packets\":0",
            "\"out_bytes\":0",
            "\"monitor_ms\":8",
            "\"in_depth\":{\"urbs\":4,\"packets\":8}",
            "\"out_depth\":{\"urbs\":2,\"packets\":4}",
            "\"in_delivery_ms\":8",
            "\"monitor_fill_max_ms\":9",
            "\"monitor_fill_avg_ms\":7",
            "\"fifo_capacity_ms\":13",
            "\"high_water_ms\":11",
            "\"out_frames\":141312",
            "\"capture_ms\":3000",
            "\"out_ms\":2944",
            "\"out_lag_ms\":56",
            "\"out_rate\":{\"ret\":3,\"errno\":0,\"raw\":\"80bb00\",\"hz\":48000}",
            "\"rate_set\":{\"target\":48000,\"ret\":3,\"errno\":0,\"recipient\":\"endpoint\",\"verified\":true}",
            "\"monitor_off\":null",
            "\"setinterface\":{\"ret\":0,\"errno\":0}",
            "\"sched\":{\"policy\":1,\"priority\":80,\"errno\":13}",
            "\"frames_written\":1920",
            "\"plan\":\"tone+delay\"",
        ] {
            assert!(text.contains(needle), "{needle} missing from {text}");
        }
        assert!(
            text.contains("\"take\":\"/data/a\\\"b\\\\c.wav\""),
            "the take path is escaped: {text}"
        );

        // A refused rate is reported with the reason the monitor stayed off.
        let mut refused = report;
        refused.monitor_off = Some("playback rate");
        assert!(report_json(&refused).contains("\"monitor_off\":\"playback rate\""));
    }
}
