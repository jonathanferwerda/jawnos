# Transcription roadmap — the handoff

What is built, what is frozen, and what is left. Written 2026-11-27 so the work can be
picked up cold. Design rationale lives in `docs/voice-inputs.md`; this file is the order
of work. Everything below assumes the house rules in `AGENTS.md` (worktree per task,
`tests_for.pl --staged --run` before a commit, `land_enqueue.pl --wait` to land).

## Status: complete — 2026-11-27

The transcription engine is **whisper.cpp**: local on a laptop, tablet or phone
(Termux builds it natively, so the phone is independent), or a house peer's through
the `whisper.transcribe` Crew job as a last resort. The Guide and the soft keyboard
can also name **Android on-device (OEM)**, a live-microphone service the manager
never runs. Every transcription row offers whisper — this machine or another —
including the watch and deck rows; the live rows also offer OEM.

The phone/tablet run the app runtime (`com.jawnos`): it has no compiler, so the
prebuilt arm64 whisper.cpp v1.7.4 binaries (static, no OpenMP, only libc/libm/libdl)
and the models are installed under `~/.local/share/jawnos/whisper`. A Termux install
can build them with `jawnos_deps.pl` instead, and `JAWNOS_WHISPER_PREBUILT` stages a
copy on either. The file engine needs only the CLI/server and a model; the Python
streamer is the live-call reader's, so the app runtime (no Python) still transcribes a
clip. The CLI wrapper reads the WAV the tree pipes to `--file -`, and the manager
converts the browser's webm to 16 kHz WAV before the warm-server POST because the
native server reads WAV only.

The 20M streaming sherpa-onnx model was **shelved on accuracy**. On 170 clips (50 real
LibriSpeech utterances, 60 house-voice commands, 30 noisy, 30 at 8 kHz) it measured
23.6% WER on real speech and 56.9% on clean commands, against whisper tiny 5.9% / 7.1%
and base 2.5% / 5.7%; on clips under 4 s it was 64.8%. It was not faster on
clip-length audio (RTF 0.13 on real clips, the same as tiny). The `jawn-asr` engine and
its version/ABI gate remain in the tree for a future model, but no role offers it.

What remains is operational, not transcription accuracy: R5–R8 below.

## Where it stands

| Landed | What it did |
| --- | --- |
| v0.1.3922 | Per-surface transcription roles: `transcription_keyboard`, `_guide`, `_watch`, `_teletype`, plus the shared `transcription_assistant`. `android:oem` is a client-only service the manager never runs. |
| v0.1.3924 | `have_whisper` checks `scripts/whisper_stream.py`; the 8 kHz/16 kHz decision is written into `docs/voice-inputs.md`. |
| v0.1.3925 | Watch file records 16 kHz when WiFi is up at capture start, 8 kHz otherwise; the live stream stays 8 kHz. `adpcm_wav_wrap($data, $rate)`. |
| v0.1.3926 | `transcription_ivr` + the Phone pane select; the gateway resolves the role to a concrete local model. |
| v0.1.3928 | The dock keyboard and the Guide use `window.JawnSpeech` when their role is `android:oem`, with the recorder as fallback. |
| v0.1.3929 | Help topics for that choice; the Guide's floating associate follows it too. |
| v0.1.3930 | Engine `PushedSource` + six C exports, so audio pushed from the app is a microphone. |
| v0.1.3933 | Asymmetric file-is-truth: a memo waits for the whole-clip file (stream returns `deferred`), a command takes whichever arrives first. Claim is a marker file under `~/.president/voice-seen` (O_EXCL) because the BLE ingest is forked. A streamed memo withholds `voice_recv` so the file is still retried. |
| v0.1.3934 | `jawn-asr`, a separate binary in the engine crate, sherpa-onnx via the C API behind an off-by-default feature. `docs/engine-asr.md`. |
| App 1374 / 0.118.376 | The IME now exposes `window.JawnSpeech`; commit `247d1b6f` is an ancestor of the published build. |

## Frozen decisions — do not re-litigate

- **Whisper is the engine.** The 20M streaming sherpa model is shelved on accuracy (see Status);
  the engine binary and its version/ABI gate stay for a future model, but no role offers it.
  The other fifteen languages stay on whisper by design.
- **OEM is a live-microphone service only.** It can never take a file: the watch, deck and IVR
  roles must name a file engine.
- **8 kHz live stream; 16 kHz file only when WiFi carries it.** The MTU experiment is deferred
  (requesting 512 disturbed the watch display); without it, BLE-only streaming cannot keep up.
- **Memos come from the file; commands take whichever transcript arrives first.**
- **sherpa is a separate process** (`jawn-asr`), not inference inside the audio callback.

## Remaining operational work

### R1 — Vendor sherpa and prove it (the gate) — **done 2026-11-27**

Nothing downstream is trustworthy until the binary links and transcribes. Network is available
from this shell.

```sh
cd ~/jawnos            # or a worktree; the libs and model are never committed
wget https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.3/sherpa-onnx-v2.0.3-linux-x64-shared.tar.bz2
wget https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2
tar xf sherpa-onnx-v2.0.3-linux-x64-shared.tar.bz2
tar xf sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2
cd engine
SHERPA_ONNX_LIB_DIR="$HOME/jawnos/sherpa-onnx-v2.0.3-linux-x64-shared/lib" \
  cargo build --offline --release --features sherpa --bin jawn-asr
LD_LIBRARY_PATH="$HOME/jawnos/sherpa-onnx-v2.0.3-linux-x64-shared/lib" \
  ./target/release/jawn-asr --model-dir "$HOME/jawnos/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17" \
  -f /path/to/ten-seconds.wav
```

Done when: real text comes back, and the run's wall time and maximum RSS are recorded (the
S922X is roughly 3x slower than this laptop). Then `SHERPA_ONNX_LIB_DIR=… perl
scripts/build_engine.pl --features sherpa` and run `perl/audio/jawn-asr` to prove the `$ORIGIN`
rpath finds its siblings.

**Result (this laptop, x86-64):** 6.6 s of audio in **0.86 s** wall (RTF 0.13) and **86 MiB**
peak RSS, model load included; at the S922X's ~3x that is still under realtime. The staged
`perl/audio/jawn-asr` ran with no `LD_LIBRARY_PATH`, so the `$ORIGIN` rpath finds its siblings.

The proof also found and fixed a real defect: **the opening words of every clip were dropped**
(nothing preceded the take, and the streaming front-end needs silence there). `jawn-asr` now
feeds `lead_silence` (0.5 s) and `tail_silence` (0.8 s), the same padding sherpa's own CLI uses.
On the three test WAVs it matches that CLI word for word, including the CLI's own miss of the
first word on 1.wav and 8k.wav and "BROFFALS" for "BROTHELS".

Risk: the `extern "C"` struct layouts in `engine/src/sherpa.rs` are transcribed from the v2.0.3
`c-api.h`. A different sherpa version needs that header re-checked, not assumed compatible.

### R2 — `local:sherpa` as a service — **shelved 2026-11-27**

Implemented, benchmarked and reverted: see Status. The service code (the `sherpa_*` subs, the
Loader entries, the Plat option and its test) was removed; the engine and its ABI gate stay. If a
future model is evaluated, this is the shape to bring back, but whisper is the engine for now.

### R3 — Wire the engine to the audio — **not pursued (sherpa shelved)**

- **Phone:** the BLE stream decodes to PCM and is pushed through the six `jawn_audio_pushed_*`
  exports (`engine/src/pushed.rs:392`); add the JNI declarations in `JawnAudioEngineJni.cpp` and
  the push in the BLE decode path. 8 kHz in, so a resample to 16 kHz is needed for sherpa —
  `LinearResampler` exists (`engine/src/bearing.rs:965`).
- **Laptop and Gou:** `SystemCapture` already captures a named PipeWire source through `parec`;
  the screened call's `jawn_call_in.monitor` is the source there.
- Done when a pushed clip and the IVR monitor each produce partial lines in the log.

### R4 — Surface partials — **not pursued (sherpa shelved)**

`Domain/Ble2.pm` transcribes every N parts as they arrive instead of only on `last`, and sends a
`voice_partial` message; the phone's transcript pane already renders partials (`public/js/manager/phone.js:1735`).
Caveat: a BLE-only watch at MTU 23 cannot sustain the stream (12 payload bytes per notify), so
partials are real on WiFi and on the laptop; de-scope or wait for the MTU work.

### R5 — Build and stage the watch firmware

The 16 kHz change is committed but never built. `cd jw && pio run -j 4` (cap jobs), then
`perl scripts/stage_firmware.pl`; the manager serves `jw/build/watch/firmware.bin`, and an
unstaged build would OTA the previous firmware. `jw/VERSION` is already 0.1.2285.

### R6 — The claim across machines

`~/.president/voice-seen` is per machine; two machines that both ingest the same relayed clip
would each act on it. Decide: a synced marker / DB row, or accept single-machine atomicity.

### R7 — Phone verification

Install 1374 and check, on the device: the IME's recogniser starts (permission already granted?),
a silent press falls back to the recorder instead of dying, the restart-after-phrase loop, and
that `android:oem` set in Plat actually reaches the keyboard page without a reload.

### R8 — Housekeeping

- Rotate the Gou password: it was found in a world-readable systemd drop-in and removed.
- The landed worktrees can be removed (`git worktree list`; `git worktree remove <dir>` and
  `git branch -D <branch>` for each landed branch).

## Gates

`perl scripts/tests_for.pl --staged --run` while iterating; the queue runs the suite on landing.
Prose-only changes (this file) run no test. Never bare `prove -l t`.

## File map

- Roles and services: `lib/JawnOS/Domain/Ai.pm` (`transcription_role_for`, `transcription_service_for`,
  `whisper_transcribe`, `voice_ingest`, `voice_clip_fresh`), `Domain/Ai2.pm` (`ai_role_models`).
- Watch path: `Domain/Ble2.pm`, `perl/watch.pl`, `jw/jw_08_voice.ino`, `jw/jw_09_voice_ship.ino`.
- IVR: `lib/JawnOS/Sco/Gateway.pm`, `templates/apps/phone.html.ep`.
- Engine: `engine/src/pushed.rs`, `engine/src/sherpa.rs`, `engine/src/bin/jawn_asr.rs`,
  `engine/build.rs`, `scripts/build_engine.pl`, `docs/engine-asr.md`.
- App: `JawnSpeech.java`, `JawnImeService.java`, `JawnAudioEngineJni.cpp` (JNI, R3).
- Tests that claim this work: `t/179`, `t/468`, `t/469`, `t/470`, `t/471`, `t/472`, `t/473`;
  the engine's version/ABI gate is `t/332`.
