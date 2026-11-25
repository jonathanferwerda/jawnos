# Studio Oboe slice — the phone engine, first pass

The first slice of `docs/studio-mobile-audio.md` §4: an optional `oboe` backend on
the existing Rust engine, cross-compiled for `aarch64-linux-android`, reusing the
effect, mixer, disk and protocol modules unchanged. One input, 48 kHz, mono,
capture only, recording a local WAV beside a status line that reports what the
stream was actually granted.

This document is the plan of record. It is written as a patch list with
`file:line` anchors so the change can be applied without re-deriving it.

## 0. Verdict for this checkout — the crate is not cached

**The engine and app changes below are planned, not applied.** The repository's
suite builds with `--offline`, and this machine's cargo cache does not contain
the `oboe` crate, so adding it to `engine/Cargo.toml` today would break every
offline build before a single line of Oboe code compiled.

Evidence gathered on this machine:

| Check | Result |
| --- | --- |
| `ls ~/.cargo/registry/cache/*/` | 25 crate files (both `bitflags` majors, three `winapi` variants): `alsa`, `alsa-sys`, `bitflags`, `block-buffer`, `cfg-if`, `cpufeatures`, `crypto-common`, `digest`, `generic-array`, `hmac`, `jack`, `jack-sys`, `lazy_static`, `libc`, `libloading`, `log`, `pkg-config`, `sha2`, `subtle`, `typenum`, `version_check`, `winapi*` |
| `find ~/.cargo -iname '*oboe*'` | no match (cache, src, or index) |
| `find ~/.cargo/registry/index -path '*ob/oe/oboe*'` | no match |
| `cargo tree --offline` in `engine/` | resolves only the `hmac`/`sha2` tree and the two in-tree voice crates |
| `grep -i oboe engine/Cargo.lock` | no match |
| `rustup target list --installed` | `x86_64-unknown-linux-gnu` only — no `aarch64-linux-android` |
| `ANDROID_NDK_HOME` / `NDK_HOME` | unset |
| `which cargo-ndk` | not installed |

The related transfer crates (`ndk`, `jni`, `cpal`) are also absent, so none of
the obvious alternatives is a cached one either. The no-feature baseline is
green: `cargo test --offline -j 2 -- --test-threads=1` in `engine/` and
`perl scripts/run_tests.pl --serial t/332-engine-build.t` both pass.

**When the cache has it** (or on the Android build machine), land the patch
list in §2 and §5 as one change. Until then, keep `engine/Cargo.toml` as it is
and keep the Oboe module behind `#[cfg(feature = "oboe")]`, never in `default`.

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

The Oboe crate builds C++ through CMake. On the Linux suite that never happens:
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

JNI entry points live in this module, because this is the cdylib Android loads:

```rust
#[no_mangle]
pub extern "system" fn Java_com_jawnos_app_JawnAudioEngine_nativeStart(
    env: JNIEnv, _class: JClass, device_id: jint, seconds: jdouble, out: JString,
) -> jstring { /* run_duplex; JSON status */ }
```

`JNIEnv`/`JClass`/`JString` need the `jni` crate, which is also not cached. The
alternative, and the one to prefer if only `oboe` is cached, is to export plain
C symbols (`jawn_audio_start`, `jawn_audio_stop`, `jawn_audio_status`) and let a
small Java `native` wrapper marshal `String`/`int`; Java's JNI can call a C
signature directly. Keep the exported C ABI in this file either way.

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

- `--android` selects `cargo ndk -t arm64-v8a -p 26 build --lib --release
  --features oboe --manifest-path engine/Cargo.toml` (the app's `minSdk` is 26,
  `gradle.properties:28`).
- `--out-dir` defaults to `app/src/main/jniLibs` when it exists, otherwise it
  errors with the path it wanted.
- Stage `libjawn_audio.so`, not `jawn-audio`: the app already loads a different
  `libjawnaudio.so` for `window.JawnAudioOboe`, and the two must not clobber
  each other.
- `-j 4` on the shared box; the existing `--if-stale` logic needs no change
  (its `newest_source_mtime` already covers `Cargo.toml`, `Cargo.lock` and
  `engine/src`).
- A machine without `cargo-ndk` or the NDK keeps the current sentence-style
  refusal: the engine is optional, and the desktop path is unaffected.

### 2.8 `t/428-oboe-backend.t` (new) and `t/332-engine-build.t`

`t/428` is a **no-feature** contract test, so it is green on every machine:

- `# tests-for: engine/src/backends.rs engine/src/main.rs scripts/build_engine.pl`
- `jawn-audio --backends --json` parses as JSON with exactly the five keys
  `alsa`, `pipewire`, `jack`, `oboe`, `null`; all booleans; `null` is `true`.
- In a build with no features, `oboe` is `false`.
- `jawn-audio --backends` (prose) has an `oboe:` line saying
  `no (built without --features oboe)`.
- `jawn-audio --backend oboe --run` exits 2 with the rebuild sentence.
- `jawn-audio --help` names `oboe` in the `--backend` line.

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

On the Android build machine:

```sh
rustup target add aarch64-linux-android
cargo ndk -t arm64-v8a -p 26 -o app/src/main/jniLibs \
  build --lib --release --features oboe --manifest-path engine/Cargo.toml
```

- `cargo-ndk` sets the NDK's clang as linker and the sysroot. The app pins
  `ndkVersion=30.0.16248370` (`gradle.properties:30`); use the same one.
- The app is `arm64-v8a` only (`app/build.gradle:79-81`), so build one ABI.
- The default Linux build is unchanged: `cargo build --offline` compiles no C++
  and produces the same `jawn-audio` binary plus an unused `libjawn_audio.so`
  (from `crate-type`). `build_engine.pl` still stages the binary.
- If the linker asks for `libc++_shared.so`, copy it from
  `$NDK/toolchains/llvm/prebuilt/*/sysroot/usr/lib/aarch64-linux-android/` into
  the same `jniLibs/arm64-v8a/`. The app's own CMake already uses
  `-DANDROID_STL=c++_shared` (`app/build.gradle:85-89`), so the library may
  already be packaged; verify rather than assume.

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
 "peak":0.31,"take":"/data/user/0/com.jawnos/files/studio/take-…wav"}
```

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
