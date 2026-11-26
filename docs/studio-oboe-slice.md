# Studio Oboe slice — the phone engine, first pass

The first slice of `docs/studio-mobile-audio.md` §4: an optional `oboe` backend on
the existing Rust engine, cross-compiled for `aarch64-linux-android`, reusing the
effect, mixer, disk and protocol modules unchanged. One input, 48 kHz, mono,
capture only, recording a local WAV beside a status line that reports what the
stream was actually granted.

This document is the plan of record. It is written as a patch list with
`file:line` anchors so the change can be applied without re-deriving it.

## 0. Verdict for this checkout - applied and cross-compiled (2026-11-25)

**Both halves are applied.** The engine changes in section 2 and the app changes in section 5
are in the tree; the app side shipped in builds 1353–1356 (measured at 1356 / 0.118.358), and
the feature-on build loads on the device and names `oboe: true` (section 9, Result). The
previous verdicts (the crate was not cached, so the feature could not be added without breaking
`--offline`; then engine-only) are no longer true. What is still true is the split the plan
relies on - the dependency is **optional**, the feature is **off** by default, and the
default/offline build compiles no C or C++ at all.

Evidence gathered on this machine:

| Check | Result |
| --- | --- |
| NDK | `/home/jawn/android-sdk/ndk/30.0.16248370` (the app's `ndkVersion`) |
| `rustup target add aarch64-linux-android` | installed |
| `cargo fetch` (once, online) in `engine/` | fetched `oboe 0.6.1`, `oboe-sys 0.6.1`, `cc`, `num-*`; `engine/Cargo.lock` is committed with them |
| `cargo build --offline` in `engine/`, default features | green; no C/C++ |
| `cargo test --offline -j 2 -- --test-threads=1` | green |
| `perl scripts/build_engine.pl --android --out-dir ...` with the NDK | green; staged `libjawn_audio.so` |
| Cross-compiled artifact | `arm64-v8a/libjawn_audio.so`, 963,096 bytes, ELF aarch64, **for Android 26**, built by NDK r30; `NEEDED` only `liblog.so`, `libOpenSLES.so`, `libdl.so`, `libm.so`, `libc.so` (the C++ runtime is static) |
| Exported C ABI | `jawn_audio_start`, `jawn_audio_stop`, `jawn_audio_status`, `jawn_audio_free` |

The Linux/suite contract is `t/428-oboe-backend.t`: `oboe:false`, the prose
sentence, and the rebuild refusal. The feature-on build is a compile check on
Linux and a real stream only on the phone (section 9).

## 0.1 The Oboe crate API this slice uses

Pinned in `engine/Cargo.toml` as `oboe = { version = "0.6.1", optional = true }`;
`oboe-sys 0.6.1` compiles Oboe's C++ with the `cc` crate (not CMake) and links
it statically. The API actually used in `engine/src/oboe_device.rs`:

- `AudioStreamBuilder::default()`, then `set_direction::<Input>()`,
  `set_performance_mode(PerformanceMode::LowLatency)`,
  `set_sharing_mode(SharingMode::Exclusive | Shared)`,
  `set_sample_rate(48_000)`, `set_channel_count::<Mono>()`, `set_format::<i16>()`,
  and optional `set_device_id(id)`.
- `set_callback(cb).open_stream() -> Result<AudioStreamAsync<Input, F>>`. The
  callback is `AudioInputCallback` with `FrameType = (i16, Mono)`, so
  `on_audio_ready(&mut dyn AudioInputStreamSafe, &[i16])` gets one i16 per frame.
- `AudioStream::start()` / `stop()` (blocking). Read back through
  `AudioStreamBase::get_sample_rate`, `get_channel_count` (a `ChannelCount`),
  `get_buffer_size_in_frames`, `get_sharing_mode`, `get_performance_mode`, and
  `AudioStreamSafe::get_frames_per_burst`, `get_xrun_count` (returns
  `Result<i32>`; an unsupported count is reported as 0).
- There is no `FullDuplex`: the duplex half reads the input from an output
  callback, which is why this slice is input-only.

## 0.2 Is there an option other than Oboe?

Yes, and it is the one to reach for if the crate ever becomes unavailable:
**AAudio**. Oboe is a thin C++ wrapper; on API 26+ it drives AAudio directly
(OpenSL ES is its fallback on older releases). AAudio is a stable NDK **C** API
(`<aaudio/AAudio.h>`, `libaaudio.so`), so it can be bound without any crate:
declare the handful of functions and enums in an `extern "C"` block, link
`-laaudio`, and drive `AAudioStreamBuilder` / `AAudioStream_read` from a
callback exactly as this module drives `AudioStreamBuilder` / `on_audio_ready`.
That costs hand-maintained declarations and loses Oboe's automatic OpenSL ES
fallback, but it removes the dependency and the C++ build entirely - which is
precisely the failure mode that stopped the earlier attempt. The app's
`minSdk` is 26, so AAudio is present on every device the app supports. Any such
change stays behind the same `oboe` feature and the same `OboeReport` contract.

## 1. Scope

| In the slice | Deliberately not in the slice |
| --- | --- |
| One Oboe input/duplex stream, 48 kHz, mono | UDP transport, clock session, peer placement (P3/P4) |
| The existing strip, `Effect` names and `Channel` fixture | Opus encoding (`Codec::Opus10` is named, not implemented) |
| A local 16-bit WAV through `DiskWriter` | Multi-track recording |
| A status/report line: rate, frames, buffer, sharing and performance mode, xruns, timestamps | Patchbay and `Plan.pm` routing |
| `--backend oboe` in `--run`, `--backends --json` naming `oboe` | A required monitoring path (monitoring stays headphone-only, last) |
| A foreground service and an in-process/JNI start path | Direct USB access through `UsbManager` |
| The `docs/studio-mobile-audio.md` §6 round-trip measurement | Browser UI changes or DSP rewrites |

## 2. Engine patch list

Every item below is a separate, reviewable change. 2.1-2.3 and 2.5-2.6 give a
Linux build that reports `oboe: false`; 2.4 is the stream itself, and 2.7-2.8
stage and pin it.

### 2.1 `engine/Cargo.toml`

- `[lib]` (`:9-11`): add `crate-type = ["lib", "cdylib"]`. The same crate stays
  a binary for the house machines and becomes a loadable `libjawn_audio.so` for
  the app. The `[[bin]]` target (`:13-15`) is unchanged; `build_engine.pl` keeps
  staging `target/<profile>/jawn-audio`.
- `[features]` (`:21-24`): add `oboe = ["dep:oboe"]`. `default` stays `[]`.
- `[dependencies]` (`:26-28`): add
  `oboe = { version = "0.6", optional = true }`.

Pin the exact version and checksum the build machine's index offers; `0.6` is
the crate's current line, not a version verified on this machine. The lockfile
must be committed in the same change so `--offline` resolves it.

The Oboe crate's `oboe-sys` builds C++ with the `cc` crate (not CMake). On
the Linux suite that never happens:
the dependency is optional and the feature is off, so `cargo test --offline`
still compiles no C/C++ at all. This is the reason the module is cfg-gated in
§2.3 rather than conditionally linked.

### 2.2 `engine/src/backends.rs`

The contract change, in one file:

| Site | Change |
| --- | --- |
| `BackendKind` (`:16-21`) | add `Oboe` |
| `parse()` (`:25-33`) | `"oboe" => Some(BackendKind::Oboe)` |
| `name()` (`:35-42`) | `BackendKind::Oboe => "oboe"` |
| `device_name()` (`:46-53`) | `BackendKind::Oboe => requested.unwrap_or("default").to_string()` — the Android HAL names devices, so the string is a label, not a PCM |
| `Availability` (`:64-70`) | add `pub oboe: bool` |
| `availability()` (`:72-79`) | `oboe: cfg!(feature = "oboe")` |
| `json()` (`:155-160`) | `{"alsa":…,"pipewire":…,"jack":…,"oboe":…,"null":…}` — a fifth key after `jack`, with `null` last |
| `prose()` (`:163-191`) | one `oboe:` line after `jack:`: `yes (built with --features oboe)` / `no (built without --features oboe)` |
| tests (`:226-254`) | add `Oboe` to the parse round trip; assert the JSON has all five keys and that `oboe` is `false` without the feature |

The JSON is the contract the manager reads; `t/428` pins it. Key order is
stable, but consumers must not depend on it; the keys and the boolean truth are
what is pinned.

### 2.3 `engine/src/lib.rs`

At `:37-40`, beside the existing feature modules:

```rust
#[cfg(feature = "oboe")]
pub mod oboe_device;
```

Re-export the report type at `:50` next to `device`:

```rust
#[cfg(feature = "oboe")]
pub use oboe_device::{OboeReport, run_duplex};
```

### 2.4 `engine/src/oboe_device.rs` (new)

Follow the ALSA module's shape (`engine/src/alsa_device.rs:218,488,565`): a free
function per role, not a `Device` implementation (see §3). The first slice needs
one entry point. It is capture-only in this slice; the duplex variant (monitor
out) arrives with the headphone-only monitoring half:

```rust
pub struct OboeReport {
    pub device: String,
    pub rate: u32,            // getSampleRate() after open
    pub frames: usize,        // frames per data callback
    pub buffer_frames: usize, // getBufferSizeInFrames()
    pub channels: usize,
    pub sharing: String,      // getSharingMode(): "Exclusive" | "Shared"
    pub performance: String,  // getPerformanceMode(): "LowLatency" | ...
    pub xruns: u32,           // getXRunCount()
    pub frames_captured: u64,
    pub frames_written: u64,   // DiskWriter::finish()
    pub dropped: u64,          // captured but not written
    pub dropped_ring: u64,     // ring full, drain fell behind
    pub dropped_disk: u64,     // disk queue full, writer fell behind
    pub dropped_callback: u64, // one callback larger than the scratch
    pub peak: f32,
}

pub fn run_duplex(
    device_id: Option<i32>,
    seconds: f64,
    out: Option<&str>,
) -> Result<OboeReport, String>;
```

Implementation notes, all of them load-bearing:

- `AudioStreamBuilder`: `set_direction(Direction::Input)` for a capture-only take;
  a duplex variant sets `Direction::Output` and reads the input from the output
  callback (Oboe has no `FullDuplex`; the app's C++ slice already records this at
  `app/src/main/cpp/JawnAudioOboe.cpp:6-11`).
- `set_performance_mode(PerformanceMode::LowLatency)`,
  `set_sharing_mode(SharingMode::Exclusive)` first, falling back to `Shared`,
  `set_sample_rate(48_000)`, `set_channel_count(1)`, and `set_device_id(id)` when a
  `--device` index is given (the phone's mic and the UM2 are both
  `AudioDeviceInfo` ids).
- Read back `get_sample_rate()`, `get_frames_per_burst()`,
  `get_buffer_size_in_frames()`, `get_sharing_mode()`, `get_performance_mode()`
  and `get_xrun_count()` (the AAudio names are the Java/C++ spellings). The
  granted values, not the requested ones, go in `OboeReport`.
- The data callback never allocates, locks, or logs. It writes into a fixed ring
  (`engine/src/monbus.rs`) and a `DiskWriter` (`engine/src/disk.rs`) owns the
  WAV, exactly as `capture.rs` does on Linux.
- A short read is padded with silence and counted; it is not retried.
- A 48 kHz request that is not granted is reported, not silently resampled.
  The take's WAV is written at the granted rate, and the report says so.

Entry points live in this module, because this is the cdylib Android loads.
The `jni` crate is not a dependency: the module exports the plain-C ABI below,
and a small Java `native` wrapper marshals `String`/`int` (Java's JNI can call a
C signature directly). All the entry points are implemented in
`engine/src/oboe_device.rs`:

```c
char *jawn_audio_start(int device_id, double seconds, const char *out);
char *jawn_audio_start_plan(int device_id, double seconds, const char *out,
                            const char *plan_json);
char *jawn_audio_fixture_plan(void);
char *jawn_audio_stop(void);
char *jawn_audio_status(void);
void  jawn_audio_free(char *text);
```

`start` returns immediately (the take runs on a worker thread) with a JSON
status; `stop` joins the worker and returns the final report; `status` answers
the last report. `device_id < 0` asks the HAL to pick; a NULL `out` runs without
a WAV. Each returned string is freed with `jawn_audio_free`.

`jawn_audio_start_plan` is the additive ABI for one `Channel` (§11). A NULL or
empty plan is exactly `start`'s raw path. `jawn_audio_fixture_plan` returns the
one fixture plan's JSON bytes, so the app does not keep a second copy that could
drift from the Linux test.

### 2.5 `engine/src/main.rs`

| Site | Change |
| --- | --- |
| usage `--run` (`:70`), `--record` (`:82`), `--loopback` (`:157`), `--listen` (`:180`), play (`:218`), serve (`:238`), patch (`:263`) | add `oboe` to the backend list, with the note that it exists only in a `--features oboe` build |
| prose (`:305-306`) | name the Oboe feature beside ALSA and JACK |
| `--backend` parse (`:717-722`) | update the error text to `(want null, alsa, pipewire, jack or oboe)` |
| `Mode::Check` (`:1097-1105`) | add `oboe {}` to the `backends:` line so `--check` and `--backends` agree |
| `run_device()` (`:1243-1250`) | `BackendKind::Oboe => oboe_run(&device, options)` |
| `oboe_run` (new, near `:1329`) | `#[cfg(feature = "oboe")]` calls `oboe_device::run_duplex`; the `#[cfg(not(...))]` arm returns `"this build has no Oboe backend; rebuild with --features oboe"` |

Adding the enum variant makes every exhaustive `match backend` a compile error
until it has an arm. That is the intended forcing function; the known sites are:

- `engine/src/capture.rs:538`
- `engine/src/loopback.rs:217`
- `engine/src/main.rs:1245, 2578, 2725, 3023, 3142, 3226, 3256, 3286, 3386, 3642, 3743, 3772`
- `engine/src/socket.rs:6652, 6818, 6996, 7535, 7711`

Every arm except `run_device` should return a clear "Oboe is capture-only in
this slice" error in the first pass. Do not wire Oboe into `--record`,
`--listen`, `--play`, `--patch` or `--serve` until the capture path is measured;
a half-wired backend is worse than an honest refusal.

### 2.6 `engine/src/socket.rs` — the control path

The existing control socket is a Unix socket (`engine/src/socket.rs:81`) at a
`~/.president/...` path (`:223`). Android has neither that home directory nor a
way for the WebView page (JavaScript) to open a Unix socket.

First slice, in order of preference:

1. **In-process JNI.** `JawnAudioService` owns the engine; start, stop and
   status are direct calls. No socket, no port, no new dependency. This is the
   path the slice should ship.
2. **Loopback TCP.** When the Studio page must drive the engine, bind
   `127.0.0.1:0` (ephemeral) and keep the existing one-JSON-object-per-line
   protocol. The bound port is read from the service and handed to the page.
   Loopback-only is the rule; the line protocol already carries `status`,
   `record`, `param` and `stop`. Add a per-start token as the first line if the
   page and the service are not the same UID (they are, in this app).
3. **`LocalSocket`.** Android's `LocalSocket` uses the abstract namespace, which
   `std::os::unix::net::UnixStream` cannot address; it needs `libc` or a small
   Java relay (`LocalServerSocket`). That is a later, separate change, and only
   if the loopback port proves unattractive on the device.

Keep `socket.rs` unchanged in the slice. The Android path is selected in the
service/bridge, not by rewriting the Linux control socket.

### 2.7 `scripts/build_engine.pl`

Add an opt-in Android path; the default stays the Linux binary build:

```
perl scripts/build_engine.pl --android [--ndk PATH] [--out-dir DIR]
```

- `--android` drives the NDK's clang directly (no `cargo-ndk` needed): it sets
  `ANDROID_NDK_HOME`, `CC_aarch64-linux-android`, `CXX_aarch64-linux-android`,
  `AR_aarch64-linux-android` and
  `CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER` to the API-26 wrappers and runs
  `cargo build --lib --release --features oboe --target aarch64-linux-android -j 4`
  (the app's `minSdk` is 26). `cargo ndk` is not required; if it is already
  installed it is an acceptable substitute.
- The NDK is `--ndk PATH`, else `ANDROID_NDK_HOME`/`NDK_HOME`/`ANDROID_NDK_ROOT`,
  else the newest NDK under `ANDROID_SDK_ROOT/ndk` or `~/android-sdk/ndk`.
- `--out-dir` defaults to `app/src/main/jniLibs` when it exists, otherwise it
  errors with the path it wanted.
- Stage `libjawn_audio.so`, not `jawn-audio`: the app already loads a different
  `libjawnaudio.so` for `window.JawnAudioOboe`, and the two must not clobber
  each other.
- `-j 4` on the shared box; the existing `--if-stale` logic needs no change
  (its `newest_source_mtime` already covers `Cargo.toml`, `Cargo.lock` and
  `engine/src`).
- A machine without the NDK keeps the sentence-style refusal: the engine is
  optional, and the desktop path is unaffected.

### 2.8 `t/428-oboe-backend.t` (new) and `t/332-engine-build.t`

`t/428` is a **no-feature** contract test, so it is green on every machine:

- `# tests-for: engine/src/backends.rs engine/src/main.rs engine/src/lib.rs engine/src/oboe_device.rs engine/Cargo.toml scripts/build_engine.pl`
- `jawn-audio --backends --json` parses as JSON with exactly the five keys
  `alsa`, `pipewire`, `jack`, `oboe`, `null`; all booleans; `null` is `true`.
- In a build with no features, `oboe` is `false`.
- `jawn-audio --backends` (prose) has an `oboe:` line saying
  `no (built without --features oboe)`.
- `jawn-audio --backend oboe --run` exits 2 with the rebuild sentence.
- `jawn-audio --help` names `oboe` in the `--backend` line; `--check` agrees.
- `build_engine.pl --android` refuses a missing NDK in a sentence, not a shell
  error, and stages nothing.
- The source keeps `oboe` optional, `default = []`, the C ABI present, and no
  `jni` dependency.

`t/332` needs no assertion change because it pins the build script, not the
backend set. Add one line to its `# covers:` header only if the Android build
path changes what the script promises.

The feature-on build (an actual Oboe stream) cannot be tested on this Linux
machine; §9 lists the on-device checks that stand in for it.

## 3. The `Device` trait caveat

`engine/src/device.rs:17` declares `Device`, and `NullDevice` (`:30-94`) is the
only implementation. The ALSA path never implemented it: `alsa_device.rs`
exposes module-level `run_capture`, `run_playback` and `run_listen` free
functions. So "an Oboe backend behind the existing seam" is only half true — the
seam is declared and tested, but the first real backend bypassed it.

Two honest options:

1. **Follow the ALSA free-function shape** (`run_duplex`/`run_capture` beside
   `run_playback`). Fastest, least churn, and consistent with the only real
   backend in the tree. This is what §2.4 does.
2. **Promote `Device` to a duplex trait first** (`read_block`/`write_block`,
   timestamps, xruns, a granted-shape report), implement it for `NullDevice`,
   ALSA and Oboe, and delete the free-function duplication. Cleaner, small, and
   contained — but it is a refactor of code this slice is told not to touch, so
   it belongs in its own change.

The slice takes (1) and records (2) as the follow-up. A `Device` implementation
that only one platform uses would repeat the mistake the ALSA path already made.

## 4. Cross-compiling

On this machine the NDK is already installed, so the cross-build is:

```sh
rustup target add aarch64-linux-android
ANDROID_NDK_HOME=/home/jawn/android-sdk/ndk/30.0.16248370 \
  perl scripts/build_engine.pl --android --out-dir /tmp/jawn-jni
```

The script's command, equivalent to the manual one:

```sh
cargo build --lib --release --features oboe --target aarch64-linux-android -j 4 \
  --manifest-path engine/Cargo.toml
```

- The script exports the NDK's API-26 clang as CC/CXX and as the Rust linker;
  it needs no `cargo-ndk`. The app pins `ndkVersion=30.0.16248370`
  (`gradle.properties:30`); use the same one.
- The app is `arm64-v8a` only (`app/build.gradle:79-81`), so build one ABI.
- The default Linux build is unchanged: `cargo build --offline` compiles no C++
  and produces the same `jawn-audio` binary plus an unused `libjawn_audio.so`
  (from `crate-type`). `build_engine.pl` still stages the binary.
- `oboe-sys` links the C++ runtime statically (`c++_static`), so the artifact's
  `NEEDED` entries are only `liblog`, `libOpenSLES`, `libdl`, `libm`, `libc`.
  No `libc++_shared.so` needs staging; verify with `llvm-readelf -d` rather
  than assume.

## 5. App patch list

The app already has an Oboe path, but it is a **C++ monitoring bridge**, not the
Rust engine: `app/src/main/cpp/JawnAudioOboe.cpp`, `JawnAudioOboe.java`
(`window.JawnAudioOboe`), the prefab dependency at `app/build.gradle:53-55`, and
`prefab true` at `:30`. The slice adds the Rust engine beside it; do not
delete the existing bridge until the new path is measured.

| File | Change |
| --- | --- |
| `app/src/main/java/com/jawnos/app/JawnAudioEngine.java` (new) | `System.loadLibrary("jawn_audio")`; `nativeStart(int deviceId, double seconds, String out)`, `nativeStop()`, `nativeStatus()`, `nativeTakePath()`. Every method answers `{"ok":0,"error":…}` when the library is absent, following `JawnAudioOboe.java:52-65`. Register as `window.JawnAudioEngine` only if the page needs it; the service does not. |
| `app/src/main/java/com/jawnos/app/JawnAudioService.java` (new) | A foreground `Service` that owns the engine. `onStartCommand` starts the take, `startForeground(id, notification, FOREGROUND_SERVICE_TYPE_MICROPHONE \| CONNECTED_DEVICE)`, a `Binder` for status/stop, `onDestroy` stops and closes the WAV. It is the process anchor; the take survives a page reload. |
| `app/src/main/AndroidManifest.xml` | Register `.app.JawnAudioService` with `android:exported="false"`, `android:foregroundServiceType="microphone\|connectedDevice"`, and `android:stopWithTask="false"`. The permissions already exist: `FOREGROUND_SERVICE_CONNECTED_DEVICE` (`:42`), `FOREGROUND_SERVICE_MICROPHONE` (`:45`), `RECORD_AUDIO` (`:69`), `MODIFY_AUDIO_SETTINGS` (`:70`), `POST_NOTIFICATIONS` (`:47`). |
| `app/build.gradle` | Bump `versionCode`/`versionName` (`:64-65`) — every APK change does. Add an opt-in `cargoNdk` `Exec` task (`-PjawnEngine=1`; never a default-build dependency), with `-j 4` and the §4 command (Gradle itself runs `--max-workers=4` on this shared box), and point `sourceSets.main.jniLibs.srcDirs` at a staged folder using the existing `-PjawnNativeBins` pattern (`:113-120`). Keep `useLegacyPackaging true` (`:184-188`). |
| `app/src/main/jniLibs/arm64-v8a/libjawn_audio.so` | The staged artifact; gitignore it or commit it per the repo's release convention, never both. |
| `app/src/main/cpp/CMakeLists.txt` | No change. The Rust library is packaged by Gradle, not linked by the app's CMake. |

Do not fold the audio service into `DeviceService.java:1-80`: that service is
the broad device bridge, and a microphone foreground type there would claim the
mic for every device feature.

## 6. Foreground service, focus and permissions

| Concern | Requirement |
| --- | --- |
| Foreground service | `startForeground` must name the type. `microphone` requires `RECORD_AUDIO` to be granted *before* the call on Android 14+; `connectedDevice` covers the USB interface. Android 12+ refuses a start from the background, so the service starts from the activity or a user action. |
| Microphone permission | `RECORD_AUDIO` (`AndroidManifest.xml:69`) is runtime. The existing `JawnAudioOboe` already requests it (`REQ_PERMS = 7101`); the service should refuse to start with a sentence, not crash, when it is missing. |
| Audio focus | Capture alone needs none. Monitoring or playback needs `AudioFocusRequest`: `AUDIOFOCUS_GAIN` for a whole session, `AUDIOFOCUS_GAIN_TRANSIENT` for one take. On `AUDIOFOCUS_LOSS_TRANSIENT`, mute monitoring and keep recording (D14); never drop the take. On permanent loss, close the WAV cleanly. |
| USB | Use the HAL's `AudioDeviceInfo` and pass its id to `set_device_id`. A direct `UsbManager` path needs USB permission and cannot do isochronous transfers; it is out of scope. |
| Screen off | A foreground service keeps the process; a `PARTIAL_WAKE_LOCK` (released in `onDestroy`) is what keeps the CPU on for audio when the screen sleeps. Add it with the service, and let the notification say a take is running. |
| Storage | App-private files directory; `DiskWriter` writes as it records, so a kill costs the tail, not the take. The manager imports the WAV later. |

## 7. What the reports must say

One JSON object per status call, matching the engine's existing style:

```json
{"ok":true,"backend":"oboe","device":"Built-in Mic","rate":48000,
 "frames":192,"buffer":960,"channels":1,"sharing":"Exclusive",
 "performance":"LowLatency","xruns":0,"frames_captured":288000,
 "frames_written":288000,"dropped":0,"dropped_ring":0,"dropped_disk":0,
 "dropped_callback":0,"peak":0.31,"plan":"tone+delay",
 "take":"/data/user/0/com.jawnos/files/studio/take-…wav"}
```

`frames_captured` is what the callback received, `frames_written` what the WAV
holds, and `dropped` (`dropped_ring + dropped_disk`) explains any difference;
`dropped_callback` counts a single callback larger than the fixed scratch
(normally 0). A take is complete when `frames_written == frames_captured`.
`plan` is `raw` when no plan was given, else the plan's own name or its chain
(`tone+delay`), so the sidecar says which strip made the WAV.

`--backends --json` in an Oboe build says `"oboe":true`; in every other build it
says `false`. That pair is the honesty test the roadmap asks for.

## 8. Deliberately not in the slice

- **UDP and the session** (P3/P4): nothing in `engine/src` binds a UDP socket for
  audio yet, and the phone is not placed on the house clock here.
- **Opus**: `proto.rs` names the codec in its enum; the encoder is a later
  slice. The take is `pcm_s16` WAV on disk.
- **Multi-track**: one input, one track, one WAV. `Mixer` supports more, but the
  phone slice does not arm more.
- **Patchbay**: `Plan.pm` and `patchbay.rs` routing are untouched.
- **A monitoring path**: the existing `window.JawnAudioOboe` C++ duplex stream
  stays the monitor; the Rust engine is capture-first. Monitoring through the
  phone speaker with an open mic howls, so the Rust monitor is headphone-only
  and last.
- **Browser UI**: the Studio page learns the new backend through the service's
  status, not through a new page in this change.

## 9. Done test

The slice is done when all of these are true:

1. Ten minutes of 48 kHz mono capture on the phone with zero unreported xruns,
   and a WAV that opens and matches its declared length.
2. `jawn-audio --backends --json` on the phone names `oboe: true`; the Linux
   no-feature build names `oboe: false` and `t/428` is green.
3. The same `Channel` fixture (`tone` then `delay`) run through the phone's
   strip and the Linux null build agree within a stated tolerance.
4. The phone reports `getSharingMode()` and `getPerformanceMode()` for both the
   built-in mic and the UM2 over USB.
5. The `docs/studio-mobile-audio.md` §6 measurement is recorded: Oboe round trip
   split by granted sharing mode, three runs per mode, median, granted rate,
   `getBufferSizeInFrames()`, and `getXRunCount()` over ten minutes.

Item 5 is the one that decides whether M1 earns a monitoring half. If the phone
only ever gets a shared stream, the native engine is still worth shipping —
local-first takes, the same strip, the house uplink — but the latency claim in
§3 of the mobile-audio doc must be corrected before the work continues.

### Result (2026-11-25)

Measured on a tablet `SM-X400`, app **1356 / 0.118.358**, engine landed **v0.1.3783**. The
feature-on build loads on the device: `jawn-audio --backends --json` reports
`{"alsa":false,"pipewire":false,"jack":false,"oboe":true,"null":true}`.

| Gate | Result |
| --- | --- |
| 1. Ten minutes of 48 kHz mono, zero unreported xruns, a WAV that opens and matches its declared length | **PASS** with findings (a) and (b) — 599.956 s WAV, xruns 0 |
| 2. `oboe: true` on the phone; `oboe: false` and `t/428` green on Linux | **PASS** — `{"alsa":false,"pipewire":false,"jack":false,"oboe":true,"null":true}` |
| 3. The `Channel` fixture agrees with the Linux null build within a stated tolerance | **RUNNABLE, not claimed passed** — the strip is unit-tested on Linux and the on-device take now names `plan:"tone+delay"`; a direct same-input Linux/phone comparison is still a follow-up |
| 4. Sharing and performance mode for the built-in mic and the UM2 over USB | **PASS** — both Exclusive / LowLatency; UM2 device id 176, input 0 |
| 5. The mobile-audio §6 round trip recorded | **MEASURED** — UM2 patch cable 13.111 / 12.959 / 15.702 ms (median **13.111 ms**); phone speaker/mic 59.098 / 58.001 ms (median **58.55 ms**); input Exclusive, output Shared; full table in `docs/studio-mobile-audio.md` §6 |

- **(a) The loss is in-take overflow, not the stop-path tail.** 0 frames on the 10 s smoke,
480 frames / 10.0 ms on the 60 s USB take, 1,152 frames / 24.0 ms on the 10 min take — each an
exact multiple of the 96-frame burst (5 and 12 callbacks). `drain_ring` already drains the ring
after the stream stops, so the tail is not the cause: the frames were captured and then
discarded while the take ran. `OboeReport` did not carry the loss; it now reports
`frames_written` and a `dropped` total split into `dropped_ring` and `dropped_disk`. The 1358
sidecars answered it: `dropped_ring` was **0** and `dropped_disk` carried the whole loss (1,344
frames on the 60 s UM2 take, 6,528 on the 10 s tone+delay take), so the queue depth is now 256
blocks (§11.7).
- **(b) The 10 min built-in-mic take clipped** at 1.000 (0.0 dBFS); the USB take did not (peak
0.195862, −14.2 dBFS).
- **(c) The granted buffer is 2,976 frames / 62.0 ms** (burst 96 frames / 2.0 ms) on every run —
the leading indicator flagged for the round trip; measured, it is a ceiling (the wired UM2 round
trip is 13.1 ms), not the effective latency.

Gate 3 is runnable, not a claim of passing: the strip is unit-tested on Linux, the plan-carrying
ABI reaches the phone, and the on-device take names `plan:"tone+delay"`, but the two sides still
need a same-input take-to-take comparison. Gate 5 is **measured** — the UM2 patch cable is
13.1 ms and the phone's own speaker/mic is 58.0–59.1 ms (`docs/studio-mobile-audio.md` §6).
Per-run numbers and the full finding text are in the mobile-audio doc.

## 10. Landing checklist (once the cache has the crate)

1. Apply §2, then `cargo test --offline -j 2 -- --test-threads=1` in `engine/`
   with no features — this must stay green and compile no C++.
2. Apply `t/428`; run `perl scripts/run_tests.pl --serial t/428-oboe-backend.t
   t/332-engine-build.t`.
3. `cargo check --offline --features oboe` on a machine with the crate and a
   C++ toolchain; on Linux, an Oboe *stream* still cannot be opened, so the
   feature build is a compile check, not a runtime one.
4. Apply §5 in `~/jawnos-app/termux-app`, bump `versionCode`/`versionName`, build
   and publish the APK in the same change (the app repo's rule).
5. Run the §9 on-device measurement and write the numbers back into
   `docs/studio-mobile-audio.md` §6.

---

## 11. Second slice — the strip plan and the duplex probe (2026-11-25)

Engine **v0.1.3801**, app **1358 / 0.118.360**, installed on `SM-X400`. Two
additions, one of them complete and the other deliberately stopped short of the
UI.

### 11.1 One Channel in the take

`jawn_audio_start_plan` takes the same arguments as `jawn_audio_start` plus a
plan string. A NULL or empty plan is the existing raw path, byte for byte:

```json
{"gain":1.0,"pan":0.0,
 "tone":{"bass":0.0,"mid":0.0,"treble":0.0,"gain":1.0},
 "delay":{"time":0.20,"feedback":0.25,"vol":0.45}}
```

The knobs are exactly the names `Channel::set_insert` takes (`tone.bass`,
`tone.mid`, `tone.treble`, `tone.gain`; `delay.time`, `delay.feedback`,
`delay.vol`). The object's key order is the chain order; an explicit
`"inserts":["tone","delay"]` array may fix it, and the objects then supply that
insert's knobs. `"name"` sets the report label; without one it is the chain
(`tone+delay`) or `raw`.

`engine/src/plan.rs` is the parser and the strip, always compiled (no Oboe, no
new dependency). The callback is unchanged: it still duplicates mono into the
stereo ring. The drain thread builds the `Channel`, calls
`Channel::prepare(rate, period)` once, and calls `process_mono` on each block
before `DiskWriter::push`. The audio callback does no allocation and takes no
lock; the drain does its allocation at thread start. The strip reads the left
sample and writes **one channel**, so the WAV stays mono. `pan` is accepted,
clamped and reported, but a mono take has no second channel to place it in.

`plan` joins the report JSON, so `<take>.wav.json` says `raw` or `tone+delay`.

### 11.2 How Linux and the phone agree (the stated tolerance)

The fixture is one string, `engine/src/plan.rs::FIXTURE_PLAN`. The Linux test
(`effect::tests::the_tone_then_delay_fixture_echoes_the_burst_at_200_ms`) parses
that exact string, builds the same `Channel`, runs a 10 ms 1 kHz burst through
it, and asserts:

- the dry burst's RMS is > 0.05 (the tone stack did not swallow it);
- the gap at 100–110 ms is < 5 % of the dry RMS (no early repeat);
- the 200–210 ms window is **0.50–0.80× the dry RMS** (measured 0.659 on this
  build; a bypassed delay is 0, a runaway is above 1);
- every sample is finite, and a silent block stays exactly silent.

The phone runs the same `Channel` with the same knobs, because the bridge asks
the engine for `jawn_audio_fixture_plan()` rather than keeping a second copy.
The on-device half of item 3 is therefore a **live take**, not a sample-for-
sample file comparison: the person starts the panel's *Tone + delay fixture*
take, and the sidecar must say `"plan":"tone+delay"` with
`frames_written == frames_captured`. Gate 3 is runnable; it is **not claimed
passed** until that take is recorded.

### 11.3 The app path

- `JawnAudioEngine` adds `startPlan(deviceId, seconds, out, plan)` and
  `fixturePlan()`; the JNI shim resolves `jawn_audio_start_plan` and
  `jawn_audio_fixture_plan` with the same optional-symbol rule as `backends`.
  An older engine still starts a raw take when the plan is empty, and answers a
  sentence when it cannot run a non-empty plan.
- `JawnAudioService` carries `EXTRA_PLAN`; the four-argument `start` delegates
  with an empty plan. No plan is the unchanged path.
- The native panel gains **Take through** — *Raw (no strip)* or *Tone + delay
  fixture* — and passes the bytes the engine returned. The status block lists
  `plan`.

### 11.4 The duplex probe — the measurement, then the button

`engine/src/roundtrip.rs` (always compiled, Oboe-free) holds the measurement:
a 6 ms 1 kHz→5 kHz chirp, a normalized cross-correlation with a 0.35 floor, the
`StreamStamp` extrapolation at the granted rate, and `measure` (the difference
of the two streams' CLOCK_MONOTONIC times). Nine unit tests cover a clean click,
a click in noise, noise alone, a scan that starts after an electrical leak, and
the timestamp arithmetic including a backwards pair.

`oboe_device::run_roundtrip` is the Oboe glue: an input and an output stream at
48 kHz mono f32, Exclusive **as a pair** then Shared as a pair, a click a quarter
second in, 1.5 s of capture, and `getTimestamp(CLOCK_MONOTONIC)` on both
streams. It refuses when the two grant different rates, when the capture ring
dropped frames, when either stream has no timestamp, when a timestamp's frame
position is outside the probe's own counter, or when the correlation misses.

At 1358 the probe was engine-only on purpose: whether two Oboe streams on the
phone grant comparable CLOCK_MONOTONIC positions, and whether the built-in
speaker→microphone path clears the correlation floor, were both unproven. The
probe is now exposed (§11.7), and the UM2 patch-cable run is still the row that
has to produce the number; no round-trip figure is claimed before it does.

### 11.5 Verification run

- `cargo test --offline -j 4 --lib` in `engine/`: **411 passed**, including the
  nine probe tests and the fixture DSP test.
- `perl scripts/build_engine.pl --android`: `libjawn_audio.so` exports
  `jawn_audio_start_plan` and `jawn_audio_fixture_plan`; the stripped copy in the
  APK still exports both.
- App release **1358 / 0.118.360** signed with the release key, published as
  `jawnos-app-1358-0.118.360.apk`, installed over the previous build.
- On-device fixture take: **pending the person's tap** (the service is not
  exported, so it cannot be started from adb). Steps in §11.6.

### 11.6 What the person taps

1. Open the app's manager shell, then open the **Studio** window: the
   **Native take** panel appears over it. (The panel is injected on the shell,
   not on a direct `/manager/studio` URL, and it shows only while the Studio
   window is visible.)
2. **Take through** → *Tone + delay fixture*.
3. **Seconds** → 10, then **Start**; speak or make a short sound, and **Stop**.
4. The panel's status shows `plan: tone+delay`. The sidecar is
   `/sdcard/Download/jawnos-native-take-<stamp>.wav.json`; it must carry
   `"plan":"tone+delay"` and `frames_written == frames_captured`.

That records the phone half of item 3. Item 5 still needs a measured number
from the panel's round-trip button (§11.7) on the UM2 patch cable and the
built-in path, three runs per sharing mode, before the §6 table is filled.

### 11.7 The disk queue and the round-trip button (2026-11-25)

App **1359 / 0.118.361**, engine landed with this change. Two pieces close the
slice's open ends: the measured cause of the take's losses, and the probe's
route to the panel.

**The loss was the disk queue, not the ring.** The sidecars from 1358 split the
drop both ways, and the split is unambiguous:

| Take | `frames_captured` | `frames_written` | `dropped` | `dropped_ring` | `dropped_disk` |
| --- | --- | --- | --- | --- | --- |
| 60 s raw, UM2 input 176 | 28,799,616 | 28,798,272 | 1,344 | **0** | **1,344** |
| 10 s tone+delay, UM2 input 176 | 479,328 | 472,800 | 6,528 | **0** | **6,528** |

`engine/src/oboe_device.rs` passed `queue_blocks = 8` to `DiskWriter::spawn`.
At the granted 96-frame burst that is 768 frames — **16 ms** of audio — shorter
than one filesystem stall, so every stall cost whole blocks (the 10 s take lost
68 of them). The ring never overflowed. The queue is now
`DISK_QUEUE_BLOCKS = 256` in the same file: 24,576 frames / **512 ms** at 96
frames, preallocated by the bounded channel before the stream starts. The audio
callback still allocates nothing and `DiskWriter::push` still never blocks; only
the writer's slack grew. The delta between 128 and 256 blocks is 48 KiB of S16
mono, so 256 is the chosen size rather than a marginal one.

**Expected tolerance.** A 10 s take must report `dropped_disk: 0` with the WAV
holding `frames_written == frames_captured`. Any residual is stated in frames
and as whole 96-frame blocks against the retry that produced it; a residual is
**not** rounded away. The on-device run is the person's (§11.8); this document
records no number until the sidecar carries it.

**The probe is exported additively.** `jawn_audio_roundtrip(int device_in, int
device_out)` joins the C ABI; a negative id means the HAL's default, the same
rule as `jawn_audio_start`. It returns the report JSON or the error JSON, and it
blocks for the probe's ~1.5–3 s capture window. `RoundTripReport` and its
`to_json` now live in `engine/src/roundtrip.rs` (always compiled), with
`device_from_id` and three Linux unit tests: both numeric ids beside their
labels, `round_trip_ms`/`round_trip_frames`, every granted shape (`sharing_*`,
`performance_*`, `buffer_*`, `xruns_*`), and `-1` meaning default.

New report keys: `device_in_id`, `device_out_id` (additive; the existing
`device_in`/`device_out` labels and every prior key are unchanged).

**The app path.** `JawnAudioEngineJni.cpp` resolves `jawn_audio_roundtrip` as
optional, exactly like `jawn_audio_backends`, and exports
`nativeRoundTrip(int, int)`. `JawnAudioEngineBridge.roundtrip()` runs the
blocking call on a daemon worker thread and returns the started sentence;
`roundtripStatus()` is polled until the report replaces it, so the WebView never
freezes. The bridge writes the result to
`/sdcard/Download/jawnos-native-roundtrip-<timestamp>.json` (best effort) and
adds its `file` key to the returned JSON. `outputs()` lists
`AudioManager.GET_DEVICES_OUTPUTS` with USB outputs flagged, beside the existing
`devices()` inputs.

**The panel.** A *Round trip* section carries *Round trip input*, *Round trip
output*, *Measure round trip* and a result line. Every option shows its numeric
id and `[USB]` marker, and the result repeats both selected ids beside the
engine's report, so a number cannot be attributed to the wrong path. The phone
row leaves both selects on *default*; the UM2 patch-cable row selects the USB
input (176 on the tablet) and the matching USB output.

**Now measured:** item 5 was open when this slice landed; the probe is exposed and the panel
records the number. The UM2 patch-cable and default speaker/mic runs landed on 2026-11-25 — see
`docs/studio-mobile-audio.md` §6 ("Round trip measured") and §9 above. The wired UM2
(**13.111 ms** median) is a monitoring path; the phone's own speaker (**58.55 ms** median) is not.

### 11.8 What the person taps for the two proofs

1. **Disk queue.** Open Studio, leave *Input* on the UM2 (or choose it), *Take
   through* → *Raw (no strip)*, *Seconds* → 10, **Start**, stay quiet, **Stop**.
   The sidecar `/sdcard/Download/jawnos-native-take-<stamp>.wav.json` must say
   `"dropped_disk":0` and `"frames_written"` equal to `"frames_captured"`.
   Report any residual in frames and blocks; do not round it.
2. **UM2 patch cable.** Cable the UM2's headphone out to its instrument input
   (gain as for the `table` measurement). In *Round trip*, choose the USB input
   (233 in the 2026-11-25 duplex run; 176 in the earlier capture) and the
   matching USB output (229). **Measure round trip**, three times per granted
   sharing mode. Record `round_trip_ms`, both ids, both sharing/performance
   modes, the buffers and xruns from the result line and
   `/sdcard/Download/jawnos-native-roundtrip-<stamp>.json`.
3. **Phone speaker/mic.** Leave both selects on *default* and measure again.
   This row may fail the 0.35 correlation floor (AGC, the 62 ms buffer); a
   refusal is a result and is recorded as one, not as a latency.

### 11.9 Verification run

- `cargo test --offline -j 4 --lib` in `engine/` (no features): **482 passed**, including the
  three new always-compiled probe tests (report JSON + ids, escaping, `-1` = default).
- `perl scripts/run_tests.pl --serial t/428-oboe-backend.t`: **66 assertions, PASS** — the
  queue constant is named and at least 128 blocks, the Oboe spawn uses it, the C ABI exports
  `jawn_audio_roundtrip`, and the probe's report/device rule stays in always-compiled code.
- `perl scripts/build_engine.pl --android`: the arm64 `libjawn_audio.so` exports
  `jawn_audio_roundtrip` beside the existing symbols. (The Linux `--features oboe` check
  cannot compile `oboe-sys`'s C++ here — the host `c++` rejects `-Wshadow-field` — so the
  Android target is the compile check, as §10 says.)
- App release **1359 / 0.118.361** built signed with the release key and published as
  `jawnos-app-1359-0.118.361.apk`. The APK carries both `libjawn_audio.so` and the shim
  `libjawnaudio.so`; `llvm-nm` finds `jawn_audio_roundtrip` in the first and
  `Java_com_jawnos_app_JawnAudioEngine_nativeRoundTrip` in the second.
- Tablet install: `adb connect 192.168.1.84:45491` was refused twice (the host answers and the
  port is open, so the wireless-debug pairing, not the network, is the blocker). The build is
  published for the in-app updater; installation is the person's step, or a fresh pairing.
- On-device runs: the disk-queue take and both round-trip rows landed on 2026-11-25 (§11.8) —
  UM2 patch cable **13.111 ms** median, phone speaker/mic **58.55 ms** median; item 5 is
  **measured** and recorded in `docs/studio-mobile-audio.md` §6.
