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
//! Capture feeds two rings: the **record ring** the take's `drain_ring` writes to
//! disk (the same shape and strip the Oboe take uses) and a **monitor ring** the
//! optional playback endpoint reads back through a small bounded fifo.

#![allow(dead_code)]

use std::ffi::CStr;
use std::os::raw::{c_char, c_void};
use std::sync::atomic::AtomicBool;
#[cfg(any(target_os = "android", feature = "oboe"))]
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::thread;

use crate::control::{error_json, into_c_string, json_escape, lock_control};
use crate::monbus;
use crate::plan::ChannelPlan;

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

/// The monitor ring handed from the capture side to the playback side. The same
/// floor `monbus` uses: about 85 ms of stereo at 48 kHz.
pub(crate) const MONITOR_RING_FRAMES: usize = monbus::MIN_FRAMES;

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

/// The monitor fifo must hold the whole priming runway, plus one URB of refill
/// and the backlog bound. The extra URB is what the first post-priming drain
/// adds before the packets consume it, so priming never trims real audio.
fn monitor_fifo_frames(prime_frames: usize, frames_per_out_urb: usize) -> usize {
    prime_frames.max(frames_per_out_urb) + frames_per_out_urb + OUT_BACKLOG_FRAMES
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

/// Little-endian 16-bit stereo to the duplicated mono the rings carry. The left
/// sample is the mono value, exactly as `plan::Strip` reads the ring; the two
/// halves are never summed, so a mic that lands on one channel keeps its level.
fn decode_packet(
    packet: &[u8],
    stereo: &mut [f32],
    record: &monbus::Producer,
    monitor: &monbus::Producer,
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
        // The monitor leg is a loopback, so its own drops are the monitor's
        // problem, not the take's; still push so the OUT side has audio.
        let _ = monitor.push(block);
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

/// Absorb one completed capture URB into the fixed counters and the two rings.
/// No allocation, no lock, no log: every buffer here was sized at setup.
///
/// # Safety
/// `done` must point at a live URB image whose `buffer` covers
/// `number_of_packets * packet` bytes; `stereo` must hold at least
/// `packet / 2` samples.
unsafe fn absorb_in(
    done: *mut UsbdevfsUrb,
    packet: usize,
    histogram: &mut [u64],
    stats: &mut InStats,
    record: &monbus::Producer,
    monitor: &monbus::Producer,
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
            decode_packet(slice, stereo, record, monitor, stats, peak);
        }
    }
}

/// The bounded monitor queue feeding the playback URBs. Frames arrive faster
/// than packets need them only when the producer runs ahead; the oldest frame is
/// discarded beyond the capacity, so the monitor's latency is bounded. A packet
/// the queue cannot fill is zero-padded and counted as one underrun.
struct OutFifo {
    data: Vec<f32>,
    capacity: usize,
    head: usize,
    len: usize,
    dropped: u64,
}

impl OutFifo {
    fn new(frames: usize) -> Self {
        let capacity = frames.max(1);
        OutFifo {
            data: vec![0.0f32; capacity * 2],
            capacity,
            head: 0,
            len: 0,
            dropped: 0,
        }
    }

    fn push(&mut self, stereo: &[f32]) {
        let frames = stereo.len() / 2;
        for frame in 0..frames {
            if self.len == self.capacity {
                // The oldest frame goes; the newest is what the monitor wants.
                self.head = (self.head + 1) % self.capacity;
                self.len -= 1;
                self.dropped += 1;
            }
            let slot = ((self.head + self.len) % self.capacity) * 2;
            self.data[slot] = stereo[frame * 2];
            self.data[slot + 1] = stereo[frame * 2 + 1];
            self.len += 1;
        }
    }

    /// Fill `frames` stereo frames of `out` (4 bytes each), padding with silence
    /// when the queue is short. Returns how many frames came from the queue; a
    /// caller treats a shortfall as one underrun.
    fn fill_packet(&mut self, frames: usize, out: &mut [u8]) -> usize {
        let wanted = frames.min(out.len() / 4);
        let got = wanted.min(self.len);
        for frame in 0..got {
            let slot = ((self.head + frame) % self.capacity) * 2;
            let left = crate::wav::to_i16(self.data[slot]).to_le_bytes();
            let right = crate::wav::to_i16(self.data[slot + 1]).to_le_bytes();
            out[frame * 4] = left[0];
            out[frame * 4 + 1] = left[1];
            out[frame * 4 + 2] = right[0];
            out[frame * 4 + 3] = right[1];
        }
        for byte in &mut out[got * 4..wanted * 4] {
            *byte = 0;
        }
        self.head = (self.head + got) % self.capacity;
        self.len -= got;
        got
    }

    fn dropped(&self) -> u64 {
        self.dropped
    }

    /// Frames waiting to be played. The priming loop reads this, so it is the
    /// same count the packets will drain.
    fn len(&self) -> usize {
        self.len
    }
}

/// What one take's monitor (OUT) side carried. The priming split lives here so
/// a future take can tell a slow start from starvation.
#[derive(Default)]
struct OutStats {
    packets: u64,
    bytes: u64,
    underruns: u64,
    /// The underruns already counted when warm-up ended. Priming fills the fifo
    /// before the first submit, so this is zero unless a caller fills OUT while
    /// still warming up.
    underruns_start: u64,
}

/// Drain the monitor ring into `fifo` and write every packet of one OUT URB.
///
/// # Safety
/// `done` must point at a live OUT URB image with a buffer of
/// `number_of_packets * packet` bytes.
unsafe fn fill_out_urb(
    done: *mut UsbdevfsUrb,
    packet: usize,
    fifo: &mut OutFifo,
    consumer: &monbus::Consumer,
    scratch: &mut [f32],
    stats: &mut OutStats,
) {
    let got = consumer.pop(scratch);
    if got > 0 {
        fifo.push(&scratch[..got * 2]);
    }
    let frames_per_packet = packet / 4;
    let header = &*done;
    let base = header.buffer as *mut u8;
    let count = header.number_of_packets.max(0) as usize;
    for index in 0..count {
        let out = std::slice::from_raw_parts_mut(base.add(index * packet), packet);
        if fifo.fill_packet(frames_per_packet, out) < frames_per_packet {
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
    pub out_rate: UsbOutRate,
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
    out_rate: UsbOutRate,
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
        "{{\"ok\":true,\"backend\":\"usb\",\"rate\":{},\"packets_in\":{},\"missed_in\":{},\"bytes_in\":{},\"frames_in\":{},\"underruns_out\":{},\"underruns_out_start\":{},\"dropped_out\":{},\"out_packets\":{},\"out_bytes\":{},\"monitor_ms\":{},\"setinterface\":{{\"ret\":{},\"errno\":{}}},\"sched\":{{\"policy\":{},\"priority\":{},\"errno\":{}}},\"frames_captured\":{},\"frames_written\":{},\"dropped_ring\":{},\"dropped_disk\":{},\"peak\":{:.6},\"out_rate\":{{\"ret\":{},\"errno\":{},\"raw\":\"{}\",\"hz\":{}}},\"plan\":\"{}\",\"take\":\"{}\"}}",
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
        pub(super) fn sched_setscheduler(
            pid: c_int,
            policy: c_int,
            param: *const SchedParam,
        ) -> c_int;
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
/// `record` is the take's record ring producer. The monitor loopback's ring is
/// private to this function.
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
    let have_out = config.ep_out >= 0 && config.packet_out > 0;
    let packet_out = if have_out {
        config.packet_out as usize
    } else {
        0
    };

    // Select the alternate settings. Java already did this through
    // `UsbDeviceConnection.setInterface()`; the ioctl is a cross-check, so a
    // refusal is recorded and the take continues.
    let (ret, errno) = unsafe { sys::set_interface(config.fd, config.iface_in, config.alt_in) };
    let setinterface = UsbSetInterface { ret, errno };
    if have_out {
        let _ = unsafe { sys::set_interface(config.fd, config.iface_out, config.alt_out) };
    }

    // Ask the playback endpoint its own sampling frequency, once, before any
    // streaming: UAC1's class GET_CUR (`0xA2`, request `0x81`, `wValue 0x0100`,
    // `wIndex` = the endpoint, 3 bytes). The P0 probe answered 32000 on an
    // endpoint whose alt is 192 B/ms, so this records whether that is still
    // true. A refusal is recorded and never fatal — the alt setting, not this
    // probe, is what the stream actually runs at.
    let out_rate = if have_out {
        let mut bytes = [0u8; 3];
        let (ret, errno) = unsafe {
            sys::control_in(
                config.fd,
                0xA2,
                0x81,
                0x0100,
                config.ep_out as u16,
                &mut bytes,
                250,
            )
        };
        let read = (ret.max(0) as usize).min(bytes.len());
        UsbOutRate {
            ret,
            errno,
            raw: hex_bytes(&bytes[..read]),
            hz: decode_sample_rate(&bytes[..read]),
        }
    } else {
        UsbOutRate {
            ret: -1,
            ..UsbOutRate::default()
        }
    };

    let sched = sys::request_realtime();

    // One data buffer per direction, sized once. Each URB's buffer points at its
    // own slice; nothing is resized or moved while the kernel owns a URB.
    let mut in_urbs: Vec<Urb> = (0..URB_COUNT).map(|_| Urb::new(PACKETS_PER_URB)).collect();
    let mut in_data = vec![0u8; URB_COUNT * PACKETS_PER_URB * packet_in];
    let mut in_ptrs: Vec<*mut UsbdevfsUrb> = Vec::with_capacity(URB_COUNT);
    for (index, urb) in in_urbs.iter_mut().enumerate() {
        let buffer = unsafe {
            in_data
                .as_mut_ptr()
                .add(index * PACKETS_PER_URB * packet_in) as *mut c_void
        };
        let pointer = urb.ptr();
        unsafe {
            prepare_urb(
                pointer,
                config.ep_in as u8,
                packet_in,
                PACKETS_PER_URB,
                buffer,
            )
        };
        in_ptrs.push(pointer);
    }

    let mut out_urbs: Vec<Urb> = Vec::new();
    let mut out_data: Vec<u8> = Vec::new();
    let mut out_ptrs: Vec<*mut UsbdevfsUrb> = Vec::new();
    if have_out {
        out_urbs = (0..OUT_URB_COUNT)
            .map(|_| Urb::new(OUT_PACKETS_PER_URB))
            .collect();
        out_data = vec![0u8; OUT_URB_COUNT * OUT_PACKETS_PER_URB * packet_out];
        for (index, urb) in out_urbs.iter_mut().enumerate() {
            let buffer = unsafe {
                out_data
                    .as_mut_ptr()
                    .add(index * OUT_PACKETS_PER_URB * packet_out)
                    as *mut c_void
            };
            let pointer = urb.ptr();
            unsafe {
                prepare_urb(
                    pointer,
                    config.ep_out as u8,
                    packet_out,
                    OUT_PACKETS_PER_URB,
                    buffer,
                )
            };
            out_ptrs.push(pointer);
        }
    }

    let (monitor_producer, monitor_consumer) = monbus::new(MONITOR_RING_FRAMES);
    let frames_per_out_packet = packet_out / 4;
    let frames_per_out_urb = OUT_PACKETS_PER_URB * frames_per_out_packet;
    // The whole OUT depth is what priming must fill before the first submit.
    let prime_frames = if have_out {
        OUT_URB_COUNT * frames_per_out_urb
    } else {
        0
    };
    let fifo_frames = monitor_fifo_frames(prime_frames, frames_per_out_urb);
    let mut fifo = OutFifo::new(fifo_frames);
    let mut monitor_scratch = vec![0.0f32; fifo_frames.max(1) * 2];
    // At most one packet's worth of duplicated mono samples.
    let mut packet_stereo = vec![0.0f32; (packet_in / 2).max(2)];

    let mut histogram = vec![0u64; packet_in + 2];
    let mut stats = InStats::default();
    let mut peak = 0.0f32;
    let mut out_stats = OutStats::default();

    let mut in_flight = [false; URB_COUNT];
    let mut out_flight = [false; OUT_URB_COUNT];
    let mut outstanding: usize = 0;
    let mut submit_error: Option<i32> = None;

    for index in 0..URB_COUNT {
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

    // Prime the monitor before the first OUT submit. At t=0 the monitor ring is
    // empty, so submitting straight away would send 32 packets of silence and
    // read as an underrun. Reap capture completions through the same
    // `absorb_in` path until the fifo holds the whole OUT depth (or the bounded
    // warm-up expires), then submit. Capture is already live, so these frames
    // are the take's first frames, not a delay in the record path.
    let prime_started = Instant::now();
    while outstanding > 0 && fifo.len() < prime_frames {
        if stop.load(Ordering::Acquire)
            || prime_started.elapsed() >= Duration::from_millis(PRIME_TIMEOUT_MS)
        {
            break;
        }
        let done = match unsafe { sys::reap(config.fd) } {
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
            unsafe {
                absorb_in(
                    done,
                    packet_in,
                    &mut histogram,
                    &mut stats,
                    record,
                    &monitor_producer,
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
            // Take only what the runway still needs; the rest stays in the
            // ring for the first OUT fill, so priming cannot overfill the fifo.
            while fifo.len() < prime_frames {
                let need = prime_frames - fifo.len();
                let got = monitor_consumer.pop(&mut monitor_scratch[..need * 2]);
                if got == 0 {
                    break;
                }
                fifo.push(&monitor_scratch[..got * 2]);
            }
            continue;
        }
        // No OUT URB exists yet, so anything else is not ours.
        thread::sleep(Duration::from_micros(200));
    }
    out_stats.underruns_start = out_stats.underruns;

    if have_out {
        for index in 0..OUT_URB_COUNT {
            unsafe {
                clear_urb(out_ptrs[index]);
                fill_out_urb(
                    out_ptrs[index],
                    packet_out,
                    &mut fifo,
                    &monitor_consumer,
                    &mut monitor_scratch,
                    &mut out_stats,
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
            unsafe {
                absorb_in(
                    done,
                    packet_in,
                    &mut histogram,
                    &mut stats,
                    record,
                    &monitor_producer,
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

        if let Some(index) = out_ptrs.iter().position(|&pointer| pointer == done) {
            if out_flight[index] {
                out_flight[index] = false;
                outstanding -= 1;
            }
            unsafe {
                clear_urb(done);
                fill_out_urb(
                    done,
                    packet_out,
                    &mut fifo,
                    &monitor_consumer,
                    &mut monitor_scratch,
                    &mut out_stats,
                );
            }
            match unsafe { sys::submit(config.fd, done) } {
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
            continue;
        }

        // A pointer the kernel returned that is not ours: leave it alone.
        thread::sleep(Duration::from_micros(200));
    }

    // Ask the kernel to discard whatever is still in flight, then reap it. The
    // fd stays open; Java closes it.
    for index in 0..URB_COUNT {
        if in_flight[index] {
            unsafe { sys::discard(config.fd, in_ptrs[index]) };
        }
    }
    if have_out {
        for index in 0..OUT_URB_COUNT {
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

    Ok(UsbIoReport {
        packets_in: histogram_rows(&histogram),
        missed_in: stats.missed_in,
        bytes_in: stats.bytes_in,
        frames_in: stats.frames_in,
        dropped_ring: stats.dropped_ring,
        underruns_out: out_stats.underruns,
        underruns_out_start: out_stats.underruns_start,
        dropped_out: fifo.dropped(),
        out_packets: out_stats.packets,
        out_bytes: out_stats.bytes,
        monitor_ms: monitor_runway_ms(
            OUT_URB_COUNT,
            OUT_PACKETS_PER_URB,
            packet_out,
            config.rate,
        ),
        out_rate,
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
        out_rate: io.out_rate,
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
        let mut fifo = OutFifo::new(96);
        let block: Vec<f32> = (0..100)
            .flat_map(|frame| {
                // Frame 4 is the first that survives the drop; a distinct
                // in-range value proves it leads the packet.
                let value = if frame == 4 { 0.25 } else { -0.25 };
                [value, value]
            })
            .collect();
        fifo.push(&block);
        assert_eq!(fifo.dropped(), 4, "the oldest four frames go");

        let mut packet = [0u8; 48 * 4];
        assert_eq!(fifo.fill_packet(48, &mut packet), 48);
        let left = i16::from_le_bytes([packet[0], packet[1]]);
        assert_eq!(left, crate::wav::to_i16(0.25), "frame 4, not frame 0, leads");

        let mut fifo = OutFifo::new(96);
        let short: Vec<f32> = (0..10).flat_map(|_| [1.0f32, 1.0]).collect();
        fifo.push(&short);
        let mut packet = [0x7fu8; 48 * 4];
        assert_eq!(fifo.fill_packet(48, &mut packet), 10, "an underrun is short");
        assert_eq!(i16::from_le_bytes([packet[9 * 4], packet[9 * 4 + 1]]), 32767);
        assert_eq!(packet[10 * 4], 0, "the rest is silence, not a stale tail");
        assert_eq!(packet[48 * 4 - 1], 0);
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
        assert_eq!(prime, 384, "eight 1 ms packets of 48 frames");
        let mut fifo = OutFifo::new(monitor_fifo_frames(prime, frames_per_out_urb));
        assert_eq!(fifo.len(), 0, "the monitor starts empty");
        let block: Vec<f32> = (0..prime).flat_map(|_| [0.1f32, 0.1]).collect();
        fifo.push(&block);
        assert_eq!(fifo.len(), prime, "the fifo holds the whole runway");
        assert_eq!(fifo.dropped(), 0, "priming is not trimmed by the backlog bound");
        assert!(
            monitor_fifo_frames(prime, frames_per_out_urb) >= prime + frames_per_out_urb,
            "one URB of refill fits on top of the runway"
        );
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
        let (producer, consumer) = monbus::new(monbus::MIN_FRAMES);
        // Three of the four 48-frame packets exist; the fourth must zero-fill.
        let block: Vec<f32> = (0..144).flat_map(|_| [0.5f32, 0.5]).collect();
        producer.push(&block);
        let frames_per_out_urb = packets * (packet / 4);
        let mut fifo = OutFifo::new(monitor_fifo_frames(
            OUT_URB_COUNT * frames_per_out_urb,
            frames_per_out_urb,
        ));
        let mut scratch = vec![0.0f32; monbus::MIN_FRAMES * 2];
        let mut stats = OutStats::default();
        unsafe {
            fill_out_urb(pointer, packet, &mut fifo, &consumer, &mut scratch, &mut stats)
        };
        assert_eq!(stats.packets, packets as u64, "every packet is submitted");
        assert_eq!(stats.bytes, (packet * packets) as u64, "192 bytes per packet");
        assert_eq!(stats.underruns, 1, "only the last packet fell short");
        assert_eq!(stats.underruns_start, 0, "no warm-up underrun was snapshotted");
        assert_eq!(fifo.len(), 0, "the audio that existed was played");
        assert_eq!(data[3 * packet], 0, "the short packet is silence, not stale audio");
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
            out_rate: UsbOutRate {
                ret: 3,
                errno: 0,
                raw: "80bb00".to_string(),
                hz: 48_000,
            },
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
            "\"out_rate\":{\"ret\":3,\"errno\":0,\"raw\":\"80bb00\",\"hz\":48000}",
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
    }
}
