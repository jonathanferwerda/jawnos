# Studio USB audio — the direct path (UAC1, isochronous)

Status (2026-11-26): built and measured on the tablet (SM-X400) with a Behringer
UM2. Capture is lossless 48 kHz. The UM2's playback endpoint answered **32 kHz**
and `SET_CUR` for 48 kHz stalls (`EPIPE`), so the engine runs the strict UAC1
rate sequence (Sec. 2.1), verifies it with `GET_CUR`, and then **resamples the
monitor 48 -> 32** and sends 128-byte packets (Sec. 2.2). Capture, the take and
the DSP stay at 48 kHz. A rate this 1 ms-packet path cannot carry as whole
frames (44.1 kHz) still leaves the monitor off and records why. The 32 kHz
monitor works: four takes on the tablet, all audible, with the resample in place
(Sec. 5.1). **8 ms is clean when the fifo does not trim** (one take: 0 drops);
the same preset trimmed 1,336 frames on another and crackled. 4/2 ms crackle
more. `SCHED_FIFO` is still EPERM, and the next tuning is the OUT shape at the
same runway (Sec. 8).

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

The playback rate is the open defect. The P0 probe's `SET_CUR` for 48,000 Hz was
refused (`-1`) on the endpoint recipient, the interface recipient, and the alt-0
fallback; the tablet's takes now confirm the stall as `EPIPE` (errno 32). The
engine retries the strict endpoint request and then the interface form, requires
a `GET_CUR` readback, and when the readback stays at 32 kHz it **resamples the
monitor** and sends 32 frames/ms (128-byte packets). Feeding 48 frames/ms to an
endpoint running at 32 kHz overruns it and distorts independently of buffer
depth.

### 2.1 The PCM2902 rate sequence (implemented; device gate pending)

The part is a TI PCM2902 (08bb:2902). `GET_CUR` works and returns `00 7d 00`, so
the control transport is fine; the stall is the chip's state machine refusing
`SET_CUR` at that moment. The strict UAC1 request is an **endpoint** request:

| field | value |
| --- | --- |
| bmRequestType | `0x22` (class, host to device, endpoint) |
| bRequest | `0x01` (SET_CUR) |
| wValue | `0x0100` (SAMPLING_FREQ_CONTROL selector in the high byte) |
| wIndex | `0x0002` (the playback OUT endpoint address, not interface 1) |
| wLength | `3` |
| data | `80 bb 00` (48,000, 24-bit little-endian) |

An interface recipient (`0x21`) or a zero `wValue` always stalls on this part.
The engine now tries the endpoint form first, then the interface form for cards
that implement the selector there, and reads the rate back after each attempt
(`set_playback_rate` in `engine/src/usb_device.rs`). Nothing is reported as set
without that readback. The 1363 probe already sent the endpoint form at alt 1
with no ISO in flight and got `-1`, so the remaining variables are the alternate
setting and the exact order:

1. **Pick the right alternate.** Dump interface 1's alternates and choose the one
   with `bNrChannels = 2`, `bSubframeSize = 2`, `bBitResolution = 16` and
   `wMaxPacketSize = 192` (48 frames x 4 bytes in one 1 ms frame). A 128-byte or
   96-byte alternate cannot carry 48 frames and will reject 48,000 Hz.
2. **Quiesce the endpoint.** No ISO OUT URBs in flight or scheduled: cancel,
   discard and reap them before the control transfer. The PCM2902's SpAct PLL
   locks to the ISO cadence, and a `SET_CUR` while the schedule is live is
   refused.
3. **Set the alternate, then the rate, then read it back.** `SET_INTERFACE`
   (bmRequestType `0x01`, bRequest `0x0B`, `wValue` = the chosen alternate,
   `wIndex` = 1), then immediately the `SET_CUR` above, then `GET_CUR`
   (bmRequestType `0xA2`, bRequest `0x81`, same `wValue`/`wIndex`/length) and
   require `80 bb 00` **before** submitting any 192-byte/ms stream. Do not claim
   the rate was set without that readback.

If that still stalls, the chip is going to stay at its current setting; the
engine takes the fallback below rather than burning another session on it. The
report carries the attempt in `rate_set` and the monitor's device rate in
`out_rate.hz`; `monitor_off` appears only when the endpoint's rate cannot be
carried by whole 1 ms packets.

### 2.2 Fallback: monitor at the endpoint's current rate (implemented)

When the playback endpoint stays at 32 kHz, the engine resamples the monitor
48 -> 32 (linear interpolation, an exact 3:2 ratio) and sends **128-byte packets
= 32 stereo 16-bit frames per 1 ms**. The capture, the record ring and the DSP
stay at 48 kHz; the monitor FIFO also stays in 48 kHz frames, so priming, the
high-water trim and the fill counters keep their meaning. Only the packet fill
converts, with one frame of lookahead so the 3:2 step does not click at a packet
boundary. `out_rate.hz` reports 32000 and `out_packets`/`underruns_out` say
whether the monitor kept up. The cost is a 16 kHz monitor bandwidth; the capture
is unaffected.

## 3. The engine

`engine/src/usb_device.rs` (Android-only, raw usbfs ioctls, no libusb):

- Kernel structs are `#[repr(C)]` with compile-time size assertions; the `_IOC`
  numbers are derived and tested; `USBDEVFS_URB_TYPE_ISO` is 0, not 1.
- Capture: 4 URBs × 8 packets by default, `ISO_ASAP`, resubmit; 16-bit LE stereo
  is decoded into the same duplicated-mono record ring the Oboe take uses, so
  the strip, `DiskWriter` and reports are unchanged.
- Monitor: one FIFO on the USB thread between IN decode and OUT fill, primed to
  the output runway and trimmed at a high water; every trim is counted. At least
  two OUT URBs stay in flight. When the endpoint runs below 48 kHz, a linear
  resampler converts each OUT packet (48 -> 32 at the UM2's rate) while the FIFO
  stays in 48 kHz frames.
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
`high_water_ms`, `out_rate` (the monitor's device rate; 32000 means the packets
are resampled), `rate_set` (target, the `SET_CUR` return and errno, which
recipient accepted it, and `verified`), `monitor_off`, and the existing capture
counters.

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
interface measures 2.71-2.79 ms. The rate sequence proved the endpoint will not
move to 48 kHz, so this probe is still a 48 kHz chirp into a 32 kHz endpoint;
its score is not comparable until the probe resamples the chirp too (Sec. 8).

Monitor depth sweep after the two-URB fix (engine v0.1.3848, app 1370):

| runway | out_lag_ms | dropped_out | underruns_out | heard |
| --- | --- | --- | --- | --- |
| 8 ms (2×4) | 0-8 (the prime) | 0 | 4 | a couple of clicks |
| 4 ms (2×2) | 16 | 572 | 2 | more clicks |
| 2 ms (2×1) | 83 | 3,886 | 1 | lots of clicks |

### 5.1 The 32 kHz monitor resample — 2026-11-26

Engine v0.1.3869, app 1370, `out_rate.hz 32000`, `rate_set.verified false`
(`EPIPE`), `monitor_off null` on all four takes. Every take was audible, so the
48 -> 32 monitor path is in service. Four takes, one after another:

| preset | out depth | out_lag_ms | dropped_out | underruns_out | fill max/avg | heard |
| --- | --- | --- | --- | --- | --- | --- |
| 8 ms | 2×4 | 32 | 1,336 | 4 | 16/10 | a little crackling |
| 4 ms | 2×2 | 6 | 188 | 2 | 8/5 | more crackling |
| 2 ms | 2×1 | 78 | 3,694 | 1 | 4/3 | a lot |
| 8 ms | 2×4 | -4 | **0** | 8 | 16/10 | **clean** |

The clean 8 ms take and the crackling one share a depth and a fill pattern
(max 16, avg 10), so the difference was whether a capture burst pushed the fifo
over its high water and trimmed. `dropped_out` is the audible quantity here;
`underruns_out` alone (8 on the clean take) does not explain the clicks. The
fill sits at the high water (prime + one IN burst) in every preset, so an 8 ms
IN burst can arrive before the 4 ms OUT refill drains. More, smaller OUT URBs at
the same runway (4×2 or 8×1) are the next thing to try; the engine's depth ABI
already accepts them, only the app's preset mapping needs to ask.

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
output runway; the 8 ms preset is the clean setting when the fifo does not trim
(Sec. 5.1), and its observed fill averages 10 ms because the high water is the
prime plus one IN burst. Without RT, 4 ms and 2 ms starve. A deeper pipeline at
the same runway (4×2 or 8×1 OUT with 8×2 IN) buys refill slack; a negative nice
or a performance-core affinity is worth trying where `SCHED_FIFO` is refused.
Below ~3 ms needs a high-speed UAC2 interface (125 us microframes) and a
feedback-aware output path; the current backend assumes full-speed 1 ms frames.

## 8. Next

1. **Monitor at 32 kHz**: answered (Sec. 5.1). The resample is in service and 8
   ms was clean when the fifo did not trim. Re-run the cable round trip when the
   OUT shape below is chosen, so the score is measured against the final
   monitor.
2. **OUT shape at 8 ms**: 4×2 or 8×1 OUT with the same 8×2 input runway, so the
   fifo drains more often and a capture burst is less likely to trim. The engine
   accepts it today through `jawn_audio_set_usb_depth`; the app's monitor-preset
   mapping is the change.
3. A per-device latency preset in the Studio configuration (Safe 16 / Balanced 8
   / Low 4 / Ultra 2), storing the measured floor and the last take's health; Auto
   picks the smallest preset that ran clean.
4. Playback of a file into the UM2.
5. A high-speed UAC2 interface for the sub-3 ms target.

## 9. Reproduce

- App 1370; patch cable OUT -> IN and tap **USB probe** for `usb_roundtrip`; run
  the USB take at monitor buffer 8/4/2.
- Pull `/sdcard/Download/jawnos-usb-take-*.json` and read `out_lag_ms`,
  `dropped_out`, `underruns_out`, `monitor_fill_*`, `out_rate`, `rate_set` and
  `monitor_off`.
- The probe's `usb_iso` and `usb_roundtrip` live in
  `/sdcard/Download/jawnos-usb-probe-*.json`; `usb_roundtrip` now runs the same
  rate sequence before the chirp and reports its own `rate_set`.
