# Studio USB audio — the direct path (UAC1, isochronous)

Status (2026-11-26): built and measured on the tablet (SM-X400) with a Behringer
UM2. Capture is lossless 48 kHz. The monitor runs through a direct usbfs output,
but the UM2's playback endpoint is **currently set to 32 kHz** and our `SET_CUR`
for 48 kHz was refused, so the output rate must be fixed (or resampled) before
the monitor is trusted. That is the next defect after the pacing work, not a
buffer tweak.

## 1. Why a direct path

Java's `android.hardware.usb.UsbRequest` speaks bulk and interrupt only; it cannot
queue isochronous transfers. Android's audio HAL is the supported path, but it
measured **13.1 ms** wired (UM2 patch cable) and **58.5 ms** on the phone's own
speaker/mic (`docs/studio-oboe-slice.md` §11). The USB host controller already
speaks isochronous; the connection's usbfs fd can carry it. The gate (app
1362/1363) proved the app can force-claim the UM2's AudioControl and
AudioStreaming interfaces and submit `USBDEVFS_SUBMITURB` URBs on
`UsbDeviceConnection.getFileDescriptor()`.

Why not libusb/rusb: libusb's Android path wraps this same fd and issues these
same ioctls. The probe proved the ioctls; adding `libusb1-sys` would add an
Android cross-build for no new capability.

## 2. The interface

Behringer UM2, UAC1, full speed, 1 ms frames. It supports **32, 44.1 and 48 kHz**.

| direction | iface / alt | endpoint | max packet | current rate | packet |
| --- | --- | --- | --- | --- | --- |
| capture | 2 / 1 | `0x84` | 196 | 48,000 (`GET_CUR` `80 bb 00`) | 192 B = 48 frames/ms |
| playback | 1 / 1 | `0x02` | 192 | **32,000** (`GET_CUR` `00 7d 00`) | 192 B is the max; 32 kHz needs 128 B = 32 frames/ms |

The playback rate is the open defect. The probe's `SET_CUR` for 48,000 Hz was
refused (`-1`) on the endpoint recipient, the interface recipient, and the alt-0
fallback. So 32 kHz is the endpoint's current setting, not the device's limit:
either find the control and ordering the UM2 accepts, or resample the monitor
48 -> 32 and send 32 frames/ms (128-byte packets). Feeding 48 frames/ms to an
endpoint running at 32 kHz overruns it and distorts independently of buffer
depth.

## 3. The engine

`engine/src/usb_device.rs` (Android-only, raw usbfs ioctls, no libusb):

- Kernel structs are `#[repr(C)]` with compile-time size assertions; the `_IOC`
  numbers are derived and tested; `USBDEVFS_URB_TYPE_ISO` is 0, not 1.
- Capture: 4 URBs × 8 packets by default, `ISO_ASAP`, resubmit; 16-bit LE stereo
  is decoded into the same duplicated-mono record ring the Oboe take uses, so
  the strip, `DiskWriter` and reports are unchanged.
- Monitor: one FIFO on the USB thread between IN decode and OUT fill, primed to
  the output runway and trimmed at a high water; every trim is counted. At least
  two OUT URBs stay in flight.
- Safety: every in-flight URB is `DISCARDURB`ed and reaped before its buffer is
  freed; an URB the kernel still owns after the bounded reap is deliberately
  leaked; the fd is owned by Java and is never closed or freed here.
- One process-wide control slot: `jawn_audio_stop`/`jawn_audio_status` stop and
  read the USB take exactly as they do the Oboe one.

C ABI (optional to the app shim; an older engine still loads):

```c
char *jawn_audio_start_usb(int fd,
    int iface_in, int alt_in, int ep_in, int packet_in,
    int iface_out, int alt_out, int ep_out, int packet_out,
    double seconds, const char *out_path, const char *plan);
char *jawn_audio_set_usb_depth(int in_urbs, int in_packets,
                               int out_urbs, int out_packets);
char *jawn_audio_roundtrip_usb(int fd,
    int iface_in, int alt_in, int ep_in, int packet_in,
    int iface_out, int alt_out, int ep_out, int packet_out,
    int millis);
```

`set_usb_depth` clamps each dimension to 1..=8 and keeps `out_urbs` at a floor of
2; `monitor_ms = out_urbs × out_packets`. The take report carries `in_depth`,
`out_depth`, `monitor_ms`, `in_delivery_ms`, `out_urbs_effective`, `out_lag_ms`,
`monitor_fill_max_ms`, `monitor_fill_avg_ms`, `fifo_capacity_ms`,
`high_water_ms`, `out_rate`, and the existing capture counters.

## 4. The app

App 1364-1370 (0.118.372). `JawnUsbAudio` finds any attached USB audio device
with an AudioStreaming interface and an isochronous IN endpoint (no
vendor/product constants), force-claims AudioControl and the streaming
interfaces, selects the operational alternate, and holds the
`UsbDeviceConnection` for the session. `JawnUsbAudioService` is the foreground
anchor (`microphone|connectedDevice`, `PARTIAL_WAKE_LOCK`); its notification Stop
is the way out, and `pagehide` only stops the poll. `JawnUsbAudio` is a
process-wide singleton so the Activity and the service share one connection.

The Studio panel puts **USB take (direct)** first, with a device line and
Refresh, a `Monitor buffer (ms)` select (8/4/2), the result line, and the USB
probe (which now also runs the cable round trip). The final report is written to
`/sdcard/Download/jawnos-usb-take-<stamp>.json` with the WAV path and counters.

## 5. Measurements (tablet, 2026-11-26)

Capture, 5.000 s of speech: **5,000/5,000** packets of 192 bytes, `missed_in 0`,
`dropped_ring 0`, `dropped_disk 0`, 240,000 frames written. The WAV measures
peak -21.4 dBFS, RMS -41.6 dBFS, with speech rising from about 1 s. Capture is
done.

Cable round trip, patch cable OUT -> IN: **2.841 ms**, score 0.462. The tablet's
HCD returns `start_frame = 0`, so this is the monotonic fallback (±1-2 ms), which
also includes the OUT scheduling delay. The Linux ALSA path on the same
interface measures 2.71-2.79 ms. The 0.462 score is partly the 48 kHz chirp
played into a 32 kHz endpoint; re-measure after the rate fix.

Monitor depth sweep after the two-URB fix (engine v0.1.3848, app 1370):

| runway | out_lag_ms | dropped_out | underruns_out | heard |
| --- | --- | --- | --- | --- |
| 8 ms (2×4) | 0-8 (the prime) | 0 | 4 | a couple of clicks |
| 4 ms (2×2) | 16 | 572 | 2 | more clicks |
| 2 ms (2×1) | 83 | 3,886 | 1 | lots of clicks |

## 6. The pacing lessons

- **One OUT URB is wrong.** With one in flight the next is submitted only after
  the previous completes, leaving a 0.3-0.5 ms hole. The host sent only
  944/890/831/768 packets/s instead of 1000; that is audible static, worse as
  the URB shortens. Two or more URBs keep one queued while the other refills.
- **One thread, one FIFO.** `absorb_in` and the OUT fill run on the same USB
  thread; the intermediate monitor ring bought nothing and hid drops. Push
  straight into the FIFO and count every trim.
- **Absorb before refill.** Reap ready IN completions before filling a completed
  OUT URB, or one URB of every fill is zero-padded.
- **High water, not capacity.** Size for a capture burst; trim at
  `prime + one IN burst`; the steady fill is the runway.
- **Poll, then count.** `poll(fd, 1 ms)` wakes on completion; `out_lag_ms`,
  `dropped_out`, `underruns_out` and `monitor_fill_*` make continuity visible.
- **No RT on stock Android.** `sched_setscheduler(SCHED_FIFO)` is EPERM
  (`sched.errno 1`); a 1-2 ms runway can starve, and the counters say so.

## 7. Latency

The direct loop is **~2.8 ms** before any queue, so 2-3 ms end to end is below
the interface's own floor. The practical monitor adds the input delivery and the
output runway; the 8 ms preset is the current clean-ish setting. Without RT,
4 ms starves. A deeper pipeline at the same runway (4×2 or 8×1 OUT with 8×2 IN)
buys refill slack; a negative nice or a performance-core affinity is worth
trying where `SCHED_FIFO` is refused. Below ~3 ms needs a high-speed UAC2
interface (125 us microframes) and a feedback-aware output path; the current
backend assumes full-speed 1 ms frames.

## 8. Next

1. **Playback rate**: set 48 kHz correctly, or resample 48 -> 32 and send 128-byte
   packets; re-run the cable round trip and the sweep.
2. The 4×2 / 8×1 output shape with an 8×2 input at the same 8 ms runway.
3. A per-device latency preset in the Studio configuration (Safe 16 / Balanced 8
   / Low 4 / Ultra 2), storing the measured floor and the last take's health; Auto
   picks the smallest preset that ran clean.
4. Playback of a file into the UM2.
5. A high-speed UAC2 interface for the sub-3 ms target.

## 9. Reproduce

- App 1370; patch cable OUT -> IN and tap **USB probe** for `usb_roundtrip`; run
  the USB take at monitor buffer 8/4/2.
- Pull `/sdcard/Download/jawnos-usb-take-*.json` and read `out_lag_ms`,
  `dropped_out`, `underruns_out`, `monitor_fill_*`, `out_rate`.
- The probe's `usb_iso` and `usb_roundtrip` live in
  `/sdcard/Download/jawnos-usb-probe-*.json`.
