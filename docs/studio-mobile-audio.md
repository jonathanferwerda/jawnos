# Studio mobile audio — the phone as a recorder

> The phone half of the audio plan: what the Android app can capture today, where the
> gain actually lives, what latency Android will and will not give, and what a native
> JawnOS engine on the phone would reuse from `engine/`. The engine plan is
> `docs/studio-audio-roadmap.md`; the effect contract is `docs/studio-effects.md`.

**Status:** plan, 2026-11-18; first native slice built and measured, 2026-11-25. The browser
path and the Linux engine are in the tree, and the `oboe` slice of §4 now records on a real
tablet (`SM-X400`, app 1356 / 0.118.358): 48 kHz mono capture, Exclusive/LowLatency, zero xruns,
from the built-in mic and from the UM2 over USB. Open: the `Channel` fixture comparison and the
duplex round trip — §6 is **not** measured (see "First slice result" there).

**How to read the numbers.** Every figure carries one of three marks:

| Mark | Means |
| --- | --- |
| **Known** | In this repository, or measured on `table` and recorded in the roadmap. |
| **Expected** | How Android or Chromium is documented to behave; not verified on a phone here. |
| **Measure** | Must be taken on the real phone, with the named method, before it can be relied on. |

No number in this file is an estimate dressed as a measurement. Where a range appears it is
**Expected**, wide on purpose, and the measurement that replaces it is named.

---

## 1. The interface's own knobs

### What the interface exposes to software

The `table` interface enumerates as a **Texas Instruments PCM2902** (`08bb:2902`) on a
full-speed root port, 2 in / 2 out, 48 kHz / 16-bit (**Known**, roadmap §2). It is a
class-compliant codec: the USB control interface carries the standard feature units and
nothing vendor-specific.

On `table`, `amixer -c 1 controls` returns exactly two:

```
PCM Playback Switch
PCM Playback Volume
```

Both are **playback** controls. There is no `Capture`, no `Mic Boost`, no AGC, no input
selector, and no mixer element that could attenuate or lift the ADC's input (**Known** on
`table`, 2026-11-17).

### Why the gain cannot move

The UM2's gain knobs and its headphone dial are **analogue potentiometers**: the gain sits in
the signal path before the PCM2902's ADC, the headphone level after the DAC. They have no
register, no USB control request and no ALSA element. Nothing in software — ALSA, PipeWire,
the engine, WebAudio, AAudio — can move them. The same is true of the phone's own
microphones: Android exposes no capture-gain API. `AudioRecord` and AAudio give you a source
preset (`UNPROCESSED`, `VOICE_RECOGNITION`, `MIC`) that changes **processing**, and
`setMicrophoneMute()` is a mute switch, not a level. `AudioManager`'s volume is a
**route/output** volume.

State it plainly, because it decides the design:

> **Input gain on this hardware is an analogue knob and a digital mix control. Software can
> only do the second.**

### Where the gain lives instead

| Place | What it is | Where it is implemented |
| --- | --- | --- |
| The interface's gain knob | The only stage that improves signal-to-noise | Hardware, by hand |
| The engine's strip gain | Mix and record level, after the ADC | `Channel::set("gain", …)` (`engine/src/effect.rs:756`, clamped to `MAX_GAIN = 4.0`) |
| The browser's trim | The same thing on the WebAudio path | `studioChannelEngine`'s `trim` (`public/js/manager/studio.js:243`) |
| The phone's engine gain | The same strip, once M1 exists | The same `Channel`, no new control |

Digital gain lifts the noise floor with the signal, so it cannot recover a clipped ADC or a
source buried under the converter's own noise. That is why the roadmap's class A promise
starts at the analogue knob, and why a phone take is placed by latency and not saved by
normalisation.

---

## 2. The phone as a recorder

### What works today

The app's WebView already grants microphone capture to house origins, holds the runtime
permission and disables the media-user-gesture gate:

- `JawnWebViewActivity.HouseChrome.onPermissionRequest` maps `RESOURCE_AUDIO_CAPTURE` to
  `RECORD_AUDIO` and refuses origins outside the house
  (`~/jawnos-app/termux-app/.../JawnWebViewActivity.java:601-620`).
- `RECORD_AUDIO` and `MODIFY_AUDIO_SETTINGS` are declared, and the microphone is optional
  hardware (`AndroidManifest.xml:69-70`, `:95`).
- `setMediaPlaybackRequiresUserGesture(false)` at `JawnWebViewActivity.java:109`.
- minSdk 26, targetSdk 36, `arm64-v8a` only (`gradle.properties:28-30`, `app/build.gradle:74`).

On the page, the path is already the right one in shape: `studioInputStreamGrabber` asks for
AEC/NS/AGC off and an optional rate and channel count (`public/js/manager/studio/05_inputs.js:241-249`),
calls `getUserMedia` (`:266`), reads back the track's latency (`:278-282`), pushes the stream
through the channel strip (`studioAttachInput`, `public/js/manager/studio.js:337`) and records
the strip's `MediaStreamDestination` with `MediaRecorder` (`05_inputs.js:346`). The probe
(`studio.js:506`) and the report (`studio.js:432`) already exist, which is what P0's browser
half reuses.

| Capability | Status | Note |
| --- | --- | --- |
| Phone microphone over `getUserMedia` | **Known works** | AEC/NS/AGC already disabled in code |
| USB class-compliant interface as an input | **Expected** | Android's USB audio HAL accepts UAC 1; the PCM2902 is UAC 1. Needs an OTG host port and a selectable `deviceId`. **Measure** whether WebView lists it and whether it is the default input |
| `sampleRate: { ideal: 48000 }` | **Requested** | Verify with `track.getSettings().sampleRate`; the OS may resample |
| `channelCount` 1 or 2 | **Requested** | Phone mics are usually mono even when 2 is asked; the UM2 presents 2 |
| `latencyHint` | **Requested** | Chromium chooses the buffer; see §3 |
| `AudioWorklet` | **Known works** | The latency probe is one; the house page is served over HTTPS, so it is a secure context |
| `track.getSettings().latency` | **Measure** | Read by the code, but Android builds may report 0 or omit it |
| `ctx.outputLatency` | **Measure** | Often 0 on Android; `baseLatency` is the one that is usually populated |
| `MediaRecorder` sample-accurate start | **Not possible** | `start()` is called with no timeslice (`05_inputs.js:371`); the blob arrives at `stop`, and its start is a wall clock |
| Bluetooth headset as an input | **Known works** | 150–300 ms whatever the app does; refuse it for monitoring |
| `deviceId`/label before permission | **Expected blank** | Ask for the microphone once, then enumerate |

### The constraints to try

The phone's own microphone, raw:

```js
var constraints = {
  audio: {
    echoCancellation: false,
    noiseSuppression: false,
    autoGainControl: false,
    channelCount: { ideal: 1 },
    sampleRate: { ideal: 48000 },
    latency: { ideal: 0.01 }        // seconds; a hint, not a grant
  },
  video: false
};
var stream = await navigator.mediaDevices.getUserMedia(constraints);
```

The UM2 over USB — stereo, because its mic (channel 0) and instrument (channel 1) are two
mono sources, not a stereo pair (roadmap §7):

```js
var devices = await navigator.mediaDevices.enumerateDevices();
var um2 = devices.find(function (d) {
  return d.kind === 'audioinput' && /PCM2902|UM ?2|USB/i.test(d.label);
});
var usb = {
  audio: {
    deviceId: um2 ? { exact: um2.deviceId } : undefined,
    echoCancellation: false,
    noiseSuppression: false,
    autoGainControl: false,
    channelCount: { ideal: 2 },
    sampleRate: { ideal: 48000 },
    latency: { ideal: 0.01 }
  },
  video: false
};
```

Use `ideal`, never `exact`, for `sampleRate` and `channelCount`: an `exact` that the device
cannot honour throws `OverconstrainedError` and the channel stays unarmed. `deviceId` may be
`exact` once a device has been chosen, because the user picked it. Skip the legacy `goog*`
constraints: current Chromium ignores them, and the three standard flags above are the honest
ones to report.

A two-channel stream must be split before the strip, because a strip is one input:
`studioAttachInput` (`studio.js:342`) currently connects the source straight to `trim`, which
would sum the mic and the instrument. A `ChannelSplitterNode` plus one strip per input is the
engine's own model and belongs in the same change.

### The context to build

```js
var ctx = new AudioContext({ latencyHint: 'interactive', sampleRate: 48000 });
// or a numeric target in seconds, when 'interactive' is not low enough:
var ctx = new AudioContext({ latencyHint: 0.005, sampleRate: 48000 });
```

`sampleRate` is the **context's** rate. If it differs from the device's rate, Chromium
resamples; asking for 48000 on a 48 kHz device avoids that one resample and matches the
house's rate decision (roadmap D6). Both options are fixed at construction, which is why
`studioRebuildWindow` (`studio.js:123`) already tears the window down when either changes.

### Where each change belongs

| Change | File and line |
| --- | --- |
| The constraint object: `deviceId`, `latency`, keep rate/channels `ideal` | `public/js/manager/studio/05_inputs.js:241-249` |
| Record `track.getSettings()` (rate, channels, latency, processing flags) and the label | `public/js/manager/studio/05_inputs.js:278-283` |
| `AudioContext` options | `studioContext`, `public/js/manager/studio.js:56-77` |
| New report keys (`deviceId`, `deviceLabel`, `trackSettings`, `channelCount`) | `studioAudioReport`, `public/js/manager/studio.js:432-455` |
| Split a two-channel USB stream into two strips | `studioAttachInput`, `public/js/manager/studio.js:337-347` |
| Use the probe's number when no explicit offset is set | `studioRecordOffset`, `public/js/manager/studio/03_editing.js:1` |
| The report's shape is pinned by a source-reading test | `t/333-studio-audio-report.t:22` |
| The probe's measured round trip | `studioLatencyMeter`, `public/js/manager/studio.js:506-592` |

The offset deserves one sentence of honesty: `studioRecordOffset` prefers an explicit
setting, then `ctx.baseLatency + ctx.outputLatency + trackLatency`. On Android
`outputLatency` is often 0, so that sum under-corrects; the acoustic probe is the number
that is actually true. The change is to write the probe's result into the setting when the
setting is empty, and to say in the readout that it was measured rather than derived.

### What the OS resamples

Android mixes at a device primary rate, and 48 kHz is the norm (**Expected**; the house already
chose 48 kHz, roadmap D6). Whenever the requested rate is not the device's rate, a resampler
runs — AudioFlinger's for the built-in path, the USB audio HAL's for an interface — and it
costs:

- **a filter and group delay** in the capture or playback path, which must be declared, not
  hidden (roadmap D7);
- **CPU**, small but real, on a battery budget;
- **a different signal**: the resampler is not bit-transparent, so a take is usable but is not
  the converter's samples.

Three checks, all cheap, and all worth doing in M0's report:

- Output: `AudioManager.getProperty(PROPERTY_OUTPUT_SAMPLE_RATE)`.
- Input device: `AudioDeviceInfo.getSampleRates()` for the chosen input.
- What actually reached the page: `track.getSettings().sampleRate` and `ctx.sampleRate`.

If any of those disagree with 48000, the report says so and the take declares the rate it
really had. That is the whole point of the report.

---

## 3. Low latency on Android

### The paths compared

| Path | How samples move | Round trip | Status | What it can promise |
| --- | --- | --- | --- | --- |
| WebAudio, `latencyHint: 'interactive'`, 48 kHz | Chromium's audio service → AAudio/OpenSL ES → AudioFlinger mixer | Tens of milliseconds each way | **Measure** | Nothing beyond "the control surface works". No exclusive access, no chosen buffer |
| AAudio/Oboe, `PerformanceMode::LowLatency`, shared | AAudio asks for a **fast track**; AudioFlinger still mixes | Roughly 15–35 ms | **Measure** | Monitoring on the phone; not a booth |
| AAudio/Oboe, `LowLatency` + `SharingMode::Exclusive` (MMAP) | Direct to the HAL, no system mixer, no resample hop | Roughly 8–20 ms, device-dependent | **Measure** | The best this phone will do, never a cross-device promise |
| Class-compliant USB through the Android HAL | USB audio HAL, the interface's 1 ms isochronous frames | Roughly 20–40 ms | **Measure** | The interface is a source, not a monitoring promise |
| Bluetooth SCO/A2DP | The Bluetooth stack's own buffering | 150–300 ms | **Known** (roadmap risk) | Nothing; refuse it for monitoring |

The ordering is the interesting part: **the phone's own microphone in exclusive mode is
expected to beat the USB interface**, because the USB audio HAL normally cannot offer the
MMAP fast track. That is an expectation, not a result — the USB row is exactly what §6
measures. It does not make the interface worse — it is still the right input when the
source is a guitar or a real microphone — but it means the phone's latency story is two
stories, and the UI must show which one is in use.

WebAudio has no "give me 194 frames" call. `latencyHint` (a name or a number of seconds) is
the only lever, and Chromium's audio service picks the device buffer after the OS mixer, so
`baseLatency` is the render quantum, not the interface's buffer. That is the same defect the
roadmap records for the browser's `latencyHint` (§3 of `docs/studio-audio-roadmap.md`), one
layer down.

### What is a request, not a guarantee

- `PERFORMANCE_MODE_LOW_LATENCY` is a **hint**. Oboe falls back to a shared stream without
  failing. Read back `getPerformanceMode()` and `getSharingMode()` and report them; a UI that
  claims "low latency" without those two facts is guessing.
- `AAUDIO_SHARING_MODE_EXCLUSIVE` is honoured only where the device supports MMAP. It also
  means the system mixer is out of the path: the stream's own volume applies, system effects
  are bypassed, and audio focus still matters for anything the phone plays.
- Exclusive mode does **not** give analogue gain (see §1). It gives a shorter path, not a
  hotter one.
- The fast track is a property of the device build, not of the app. It can differ between two
  phones of the same model after an OS update, and it can be demoted under thermal load or
  when the screen is off. A foreground service is necessary for a long take; it is not a
  performance guarantee.
- **Capture start is not sample-accurate by itself.** Use the stream's timestamp
  (`AAudioStream_getTimestamp`, or `AudioRecord.getTimestamp(…, TIMEBASE_MONOTONIC)` on the
  framework path) to map a frame position to the monotonic clock, then let the session's
  master place the take by its declared latency. Without that mapping, the take's start is a
  wall clock again — the same defect the browser path has.
- Nothing here is a promise across devices, across a case or dongle, or over Bluetooth.

### The 48 kHz norm

Open the stream at **the device's own rate**, which on a phone is normally 48 kHz, and let the
engine resample once at the edge if a source is not 48 kHz (roadmap D6). Asking for 44.1 kHz
on a 48 kHz primary either loses the fast track or adds a resample, and buys nothing: the UM2
is 48 kHz-only and the house is 48 kHz inside.

The API surfaces to read before assuming anything: `AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE`,
`AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER`, `AudioDeviceInfo.getSampleRates()`, and
after opening, the stream's own `getSampleRate()`, `getBufferSizeInFrames()` and
`getXRunCount()`. Also check `PackageManager.FEATURE_AUDIO_PRO` and
`FEATURE_AUDIO_LOW_LATENCY`: a device that advertises neither is not a candidate for the
tight numbers, and saying so is cheaper than discovering it at a session.

---

## 4. A JawnOS mobile engine

### What it reuses

The point of the engine split (roadmap D1/D2) is that the DSP and the contract are portable;
only the device and the lifecycle are Android's.

| Engine module | Reused on the phone | Change |
| --- | --- | --- |
| `engine/src/effect.rs` | `Effect`, `InsertKind`, `Channel`, `ToneStack`, the inserts and their smoothing | None — the phone must accept the same names, or the pedal board lies (`docs/studio-effects.md`) |
| `engine/src/graph.rs` | Strip gain and equal-power pan, mono into stereo | None |
| `engine/src/mixer.rs` | Tracks and the lock-free `ParamQueue` | None; a phone may arm fewer tracks |
| `engine/src/listen.rs` | Input → strip → stereo monitor | None in the DSP; the stream shape changes |
| `engine/src/disk.rs`, `wav.rs` | Local-first take, 16-bit WAV | Path is app-private storage |
| `engine/src/proto.rs` | The 32-byte header, `pcm_s16`, `pcm_s24`, `pcm16k`, flags | Opus is named in the codec enum but **not implemented**; the encoder is a later slice |
| `engine/src/session.rs` | Election, offset, drift alignment | None; the phone is a candidate, not a preferred master |
| `engine/src/socket.rs` | One JSON object per line on a local socket | Android has no `~/.president`; use `LocalSocket` or a loopback TCP port |
| `engine/src/backends.rs` | `--backends` and `BackendKind` | Add an `oboe` backend honestly: a new key in `json()`/`prose()` and in `t/332` |
| `engine/src/alsa_device.rs` | Not reused | It is the **model**: open, grant a period and buffer, read, write, count xruns |

One structural caveat found in the tree: the `Device` trait (`engine/src/device.rs:17`) is
implemented only by `NullDevice`. The ALSA path is module-level `run_capture`,
`run_playback`, `run_listen` functions, not a `Device` implementation. So "an Oboe backend
behind the existing seam" is half true: the seam is declared and tested, but the first real
backend bypassed it. A mobile slice should either implement the same free functions
(fastest, least churn) or promote the trait to a duplex `Device` first. Doing the latter is
the cleaner answer and is a small, contained refactor.

### What is Android-specific

| Concern | What it means concretely |
| --- | --- |
| Oboe backend | `AudioStreamBuilder`: `Direction::Input`, `PerformanceMode::LowLatency`, `SharingMode::Exclusive` first then shared, `setSampleRate(48000)`, `setChannelCount(1)`, `setDeviceId(...)` to bind the USB input, `setBufferSizeInFrames()` after open; read back `getSampleRate`, `getSharingMode`, `getPerformanceMode`, `getXRunCount`; use `getTimestamp()` for placement |
| Audio focus | Capture alone needs none. Monitoring or playback needs an `AudioFocusRequest` (`AUDIOFOCUS_GAIN` for a session, `GAIN_TRANSIENT` for a take). On `AUDIOFOCUS_LOSS_TRANSIENT`, mute monitoring and keep recording (roadmap D14); never drop the take |
| Foreground service | `foregroundServiceType="microphone"` (API 30+), plus `connectedDevice` for USB. The app already declares `FOREGROUND_SERVICE_MICROPHONE` and `FOREGROUND_SERVICE_CONNECTED_DEVICE` (`AndroidManifest.xml:42,45`). Android 12+ blocks a background start; Android 14 requires the type and the while-in-use permission. A new `JawnAudioService` is cleaner than folding audio into `DeviceService` |
| Permissions | `RECORD_AUDIO` runtime (already granted for the WebView path), `MODIFY_AUDIO_SETTINGS` (declared). USB permission is **not** needed if the framework's audio HAL owns the device. It **is** needed if the app opens the USB device directly |
| USB device access | The Java `UsbManager` API exposes bulk transfers only; there is no isochronous transfer. A direct native USB audio path would have to be a new driver. **Recommendation: use the HAL's `AudioDeviceInfo` through Oboe/AAudio**, not a private USB stack |
| Process lifecycle | The service is the anchor. A kill costs the tail, not the take, because `DiskWriter` writes as it records (D14). Doze allows a foreground service; the fast track may still be demoted |
| Storage | App-private files directory; the manager imports the take later. `Scoped storage` is not a problem for app-private files |
| Native build | The engine is a `bin`; Android 10+ will not reliably execute a binary from writable app storage. Build the crate as a **cdylib** and load it through JNI, or ship it in `jniLibs/arm64-v8a/` and enter through an exported JNI symbol |

### Cross-compiling the existing engine

**Yes, it can.** `aarch64-linux-android` is a Rust target with `std`. The recipe is:

```sh
rustup target add aarch64-linux-android
cargo ndk -t arm64-v8a -o app/src/main/jniLibs build --release \
  --features oboe --manifest-path engine/Cargo.toml
```

`cargo-ndk` selects the NDK's clang as linker and sets the sysroot; the app already pins an
NDK (`gradle.properties:30`). What changes in the crate:

1. **The first C/C++ dependency.** `oboe` is C++; the `oboe` crate builds it with CMake.
   `engine/` currently has no `build.rs` and no C dependency, and the Linux suite must keep
   building with **no features** — which is why the Oboe module is `#[cfg(feature = "oboe")]`
   and never part of the default set.
2. **A library target.** Add `crate-type = ["lib", "cdylib"]` so the same crate is a binary on
   the house machines and a loadable library on Android.
3. **A socket that exists on Android.** `socket.rs` uses `UnixStream`; replace with a
   `LocalSocket` (or a loopback TCP listener) for the app's own control path, and keep the
   Unix path for Linux.
4. **The backend contract.** `BackendKind` is a four-variant enum and `Availability` a
   four-field struct; `json()`, `prose()` and `t/332-engine-build.t` pin the contract. Adding
   `oboe` is a deliberate contract change, not a silent one — the JSON gains a fifth key, and
   a build without the feature must still report `oboe: false`.

An alternative is `cpal`, which already has an Android backend and is what the roadmap names
as the cross-platform seam. It is a reasonable second choice, but it hides the two facts this
phase exists to report — the granted sharing mode and the buffer in frames. Use the `oboe`
crate directly and keep `cpal` for P8.

### A first slice

One input, 48 kHz, mono, capture only. It records to a local WAV and reports its shape. No
UDP, no Opus, no multi-track, no patchbay.

| File | Change |
| --- | --- |
| `engine/Cargo.toml` | `oboe` optional dependency, `oboe` feature, `crate-type = ["lib", "cdylib"]` |
| `engine/src/oboe_device.rs` (new) | The `Device`/duplex implementation: open, buffer, timestamp, xruns, monitor callback |
| `engine/src/backends.rs` | `BackendKind::Oboe`, `Availability.oboe`, JSON and prose, tests |
| `engine/src/lib.rs` | `#[cfg(feature = "oboe")] pub mod oboe_device;` |
| `engine/src/main.rs` | `--backend oboe` in parsing, usage and error text |
| `engine/src/socket.rs` | A local-socket strategy for Android, or a loopback TCP bind |
| `scripts/build_engine.pl` | A `--target`/`--ndk` path that stages a `.so` into `jniLibs` |
| `t/332-engine-build.t` | The backend contract; a no-feature build still passes |
| `app/src/main/java/com/jawnos/app/JawnAudioEngine.java` (new) | JNI entry points: start, stop, status, take path |
| `app/src/main/java/com/jawnos/app/JawnAudioService.java` (new) | Foreground service, focus, notification |
| `AndroidManifest.xml` | The new service and its foreground types |
| `app/build.gradle` | The cargo/NDK task, `--max-workers=4`, `arm64-v8a` |

Any APK change bumps `versionCode`/`versionName` and is built and published in the same
change (`~/jawnos-app/termux-app/AGENTS.md`).

### The monitor stream

The engine's live monitor is what puts a phone in the monitor's seat (roadmap class C).
`{"cmd":"monitor","action":"start","port":0}` binds a loopback TCP port and the engine writes
its final stereo mix as S16LE at 48 kHz; the manager's existing Music receiver plays it with
`pacat`, so the tablet needs no decoder and no browser is in the path.

The stream follows the engine's **output bus**, not any one source:

- While the Studio transport owns the output, `TapSource` pushes each finished block — after the
  master rack and the click — into the lock-free ring (`engine/src/stream.rs`).
- While the house patch owns the output, the patchbay pushes its final mix — after the bus sends,
  the system fallback and a bus take's click — into the same ring (`engine/src/patchbay.rs`).
- A transport stop does **not** stop the stream. The listener, the port and a connected
  controller stay up; if nothing is feeding the ring the writer simply sends nothing, so a later
  patch (or the next transport) is heard live rather than from a stale backlog.

That is the ownership rule unchanged: the transport owns the output *while it runs* and a patch
refuses while it does, but the monitor is not the output — it is the ear on whoever owns it. The
stream ends on exactly three things: an explicit `monitor stop`, engine shutdown
(`MonitorTap::finish`), or the controller disconnecting. The manager keeps the Music source until
one of those, so a refused start still tears down the port and the source together and the page
never shows a stream the engine did not open.

---

## 5. Phases

Three phases, each with one gate. A failed gate is a finding that changes the next phase,
not a reason to argue with the measurement.

### M0 — Browser first (2–3 days)

Make the page tell the truth on a phone: the input's real rate, channel count, device label,
the processing flags, `baseLatency`, `outputLatency` (or null), and the acoustic round trip.
Split a two-channel USB stream into two strips. Use the probe's measured round trip as the
record offset when no offset is set. No native code.

**Done test:** `t/333-studio-audio-report.t` is green with the new report keys and a fixture
for the report's shape. On the phone, `window.studioAudioReport()` names the chosen input,
reports the rate and channel count actually granted, and carries a `roundTrip` with at least
two echoes. A take from the phone mic and a take from the UM2's instrument input (channel 1)
both replay against the click with the measured offset applied. If a take is still late, the
number is the finding and M0 still delivers the table.

### M1 — The native phone engine (1–2 weeks)

The slice in §4: Oboe capture, the existing strip, a local WAV, a status line with rate,
frames, xruns, sharing mode and timestamp. The phone's own mic and the USB input are both
selectable. Monitoring through the phone's output is the last part, not the first — and it is
headphone-only, for the reason the page already gives: an open microphone plus a speaker
howls.

**Done test:** ten minutes of 48 kHz mono capture with zero unreported xruns, a WAV on the
phone, and `jawn-audio --backends --json` naming `oboe: true`. The same `Channel` fixture
(`tone` then `delay`) produces the same output as the Linux null build within a stated
tolerance. The phone reports its granted `getSharingMode()`/`getPerformanceMode()` for both
the built-in mic and the USB input, and a round trip measured with the UM2 patch cable
(headphone out → instrument in) for each.

**Result — 2026-11-25:** item 1 passes with the tail-loss and clipping findings, item 2 passes,
item 4 passes for the built-in mic and the UM2. Item 3 is blocked on the take ABI (no `Channel`)
and item 5 is blocked because the slice is capture-only. Numbers, findings and why the round
trip is still open are in §6.

### M2 — The phone on the house clock (P3/P4 work, 2–3 weeks)

The phone becomes a source on the master's engine. **This phase is blocked on P3's transport**
— `engine/src/proto.rs` encodes a datagram, but there is no UDP transport in the tree yet.

**Done test:** guitar on the UM2 and voice on the phone in one session, ten minutes, both in
time with the click on one take, each placed within ±1 sample on the master's timeline.
Pulling the phone's cable mid-take loses neither take: the phone's local WAV survives and
imports on reconnect. Sound's matrix shows the phone's node with its declared latency and
moves its fader live.

### What M2 needs from the house

The plan shape is already there; the transport and the phone-side facts are not.

| Need | State |
| --- | --- |
| A source kind for a phone | **Already accepted.** The code says so: `peer` and `device` are source kinds, and `peer` is also a sink kind (`lib/JawnOS/Audio/Plan.pm:26-27`) |
| A node's machine, rate, channels, channel and `latency_ms` | **Already normalised** (`lib/JawnOS/Audio/Plan.pm:131`). A phone is expressible in a plan today |
| A node this machine cannot bind is silent, not fatal | **Already the engine's rule** (`engine/src/patchbay.rs:13-18`), so an absent phone is visible and harmless |
| A declared latency shown beside the route | **Already in the matrix** (roadmap P5) |
| UDP transport and a session | **Missing** (P3). Nothing in `engine/src` binds a UDP socket |
| A mic lease, a stream id per channel, a per-datagram MAC and an expiry | **Missing.** The session id and the existing peer handshake are the foundation (roadmap §10) |
| The phone's audio facts in the machine registry | **Missing.** `remote_machines` carries `uuid`, `tailnet_ip`, `pubkey`, `ws_auth`, `connection` and `version` (`database/schema.sql:140`), but no audio facts. Store them in the existing `data` LONGTEXT under an `audio` key (engine present, UDP port, streams, rate, buffer, latency, sharing mode) before considering a new column and a migration |
| Discovery | The firmware already publishes mDNS TXT keys (`arm`, `coms`, `bestow`); the phone's engine announces one more, `audio`, with the same facts (roadmap §10) |
| Pushing a plan slice to the phone | **Missing.** The manager writes `~/.president/audio-plan.json` for the server's own engine (`perl/Audio.pl:392`), which is a file on *that* machine. A phone's slice must arrive over the control channel, which is P3's work |
| A local-first take on the phone | **Already designed** (D14/D15): the phone records alone, stamps the session, imports on reconnect |

---

## 6. The one measurement that sizes the native phase

Everything in §3 is **Expected** until this is done on the real phone:

> **Measure the input-to-output round trip of an Oboe stream on the phone, split by the
> granted sharing mode, for the built-in microphone and for the UM2 over USB.**

Method: the same acoustic probe the page already runs (`studioLatencyMeter`,
`public/js/manager/studio.js:506`) ported to the native path, or a click through the phone's
speaker into its microphone; run it three times per mode; report the median, the granted
sample rate, `getBufferSizeInFrames()`, `getXRunCount()` over ten minutes, and
`getSharingMode()`/`getPerformanceMode()` for each run. For the USB row, use the UM2's own
patch cable (headphone out → instrument input) with the instrument gain set as it was for the
`table` measurement, so the acoustic path is not part of the number.

Why this one: it decides whether the native engine is a **monitoring** path or only a
**capture and routing** path. If exclusive mode is granted and the local round trip leaves
room for the network inside the roadmap's ≤ 20 ms class C target, M1 earns its monitoring
half. If the phone only ever gets a shared stream and lands near the browser's number, the
native engine is still worth building — local-first takes, the same strip, the house uplink —
but it must not be sold as lower latency, and the §3 table must say so before the work starts.

The USB row is not optional: it is the row that decides whether a guitar on the phone is a
usable source at all, and it is the only row that can reuse a measured house figure.

### First slice result — 2026-11-25

The first native slice (§4) ran on a tablet `SM-X400`, app 1356 / 0.118.358, engine landed
v0.1.3783. `jawn-audio --backends --json` reports
`{"alsa":false,"pipewire":false,"jack":false,"oboe":true,"null":true}`: the feature-on build
loads and opens Oboe on the device.

| Run | Rate / channels | WAV | `frames_captured` / WAV | Sharing / performance | Buffer / burst | xruns | Peak |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10 s smoke, built-in/default | 48 kHz mono | 9.986 s | 479,328 / 479,328 | Exclusive / LowLatency | 2,976 (62.0 ms) / 96 (2.0 ms) | 0 | 0.005127 (−45.8 dBFS) |
| 10 min, built-in/default | 48 kHz mono | 599.956 s | 28,799,040 / 28,797,888 (1,152 frames, 24.0 ms) | Exclusive / LowLatency | 2,976 / 96 | 0 | 1.000 (0.0 dBFS; mean −33.4 dB) |
| 60 s USB, UM2 input 0, device id 176 | 48 kHz mono | 59.986 s | 2,879,808 / 2,879,328 (480 frames, 10.0 ms) | Exclusive / LowLatency | 2,976 / 96 | 0 | 0.195862 (−14.2 dBFS; mean −43.1 dB) |

| Gate | Result |
| --- | --- |
| 1. Ten minutes of 48 kHz mono, zero unreported xruns, a WAV that opens and matches its declared length | **PASS** with findings (a) and (b) — 599.956 s WAV, xruns 0 |
| 2. `oboe: true` on the phone; `oboe: false` and `t/428` green on Linux | **PASS** — `{"alsa":false,"pipewire":false,"jack":false,"oboe":true,"null":true}` |
| 3. The `Channel` fixture agrees with the Linux null build within a stated tolerance | **BLOCKED** — the Oboe take ABI carries no `Channel` or plan and the capture path writes raw S16 |
| 4. Sharing and performance mode for the built-in mic and the UM2 over USB | **PASS** — both Exclusive / LowLatency; UM2 device id 176, input 0 |
| 5. This section's round trip recorded | **BLOCKED** — capture-only, no duplex stream and no click, so the round trip was not measured |

Three findings, none of them a reason to argue with the numbers:

- **(a) The stop path loses the ring tail.** 0 frames on the 10 s take, 480 frames / 10.0 ms on
the 60 s USB take, 1,152 frames / 24.0 ms on the 10 min take — one partial buffer fill each
time. `OboeReport` does not carry the loss, so a take can be short of `frames_captured` with
nothing in the status line saying so.
- **(b) The 10 min built-in-mic take clipped.** Peak 1.000 (0.0 dBFS, mean −33.4 dB); the UM2
take did not (peak 0.195862, −14.2 dBFS, mean −43.1 dB). The built-in mic's gain, not the
engine's S16 path, is where to look.
- **(c) The granted buffer is 2,976 frames / 62.0 ms** (burst 96 frames / 2.0 ms). It is the
leading indicator for the round trip below.

**The round trip is NOT measured.** This slice opens an input stream and no output, so there is
no click to hear and no duplex stream to time; the UM2 patch-cable row above cannot run until a
duplex slice exists. A round trip cannot come in under one input buffer plus one output buffer,
so the number to settle next is the granted **2,976 frames / 62.0 ms**: if a duplex stream is
granted the same buffer, the round trip starts at 62 ms before any scheduling, USB or acoustic
time. Measure it before the §3 latency table is used to argue for a monitoring half.
