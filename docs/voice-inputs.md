# Voice inputs beyond the watch (desktop, phone, Pico)

The watch is live (see `docs/voice-wake-words.md`). The **T-Deck is next**: it has
fallen behind and must be brought to the watch's feature set before this file's other
input sources matter — the checklist lives in `docs/voice-wake-words.md` under
"T-Deck parity". This is the plan for the other places you'd speak from, captured so
it is not lost between sessions. Nothing here is built yet; it is a design and the
decision points still open.

## Always-on listening on the desktop app and the Termux fork

**Native, in the app, handled behind the scenes** — not the browser:

- **Desktop app (Linux):** no OS restriction on a background mic; a "voice listener"
  service fits beside the existing BT-bridge daemon. Straightforward.
- **Termux fork (Android):** needs a real **foreground service** (persistent
  notification + `RECORD_AUDIO`, and the `microphone` FGS type on Android 14+). Termux
  alone gets killed in the background — which is why `termux-tts` / `termux-dialog
  speech` feel like they "stop" and give no unending listening. The fork can host it.

**Model choice — do NOT run whisper continuously.** Even tiny, whisper is orders of
magnitude heavier than the wake-word model, so 24/7 it would spin CPU and battery for an
almost-always-empty result. Instead, the same shape as the watch:

- **Gate** on the portable microWakeWord tflite (`~/jawnos-fw/models/{vad,hey_jawn,jawn_do}.tflite`)
  — cheap, always-on. VAD mode swaps the gate to `vad.tflite`.
- **whisper only on the captured utterance.**

The models are identical across watch/deck/laptop/phone/Pico, so the wake words are the
same everywhere.

**Mic selection:** a native daemon needs the **host's** device list (`pactl list short
sources` / `arecord -l` on Linux; Android's inputs in the fork), stored as a **per-device
setting**, surfaced in the **Plat** panel of Configure. (Not the browser `.media_picker`,
which only knows the browser's devices — that is the browser-based variant below.)

## The browser-based variant (and its trap)

A `getUserMedia` listener in the page (reusing `.media_picker` + `jawnosDevicePick*` from
`jp.js`/`keyboard.js`) works on **laptop, tablet and phone**, and bypasses Termux's speech
APIs. **But** mobile browsers/WebViews **suspend mic capture the moment the tab is
backgrounded or the screen locks** — that is an OS rule, so a browser listener is only
"always-on" while **foregrounded with the screen on**. Genuinely unending on a phone needs
the native foreground service above. So: browser is fine for desktop/tablet and
phone-while-open; the phone's true always-on is a native piece.

## Privacy defaults (the phone especially)

"Phone always listening isn't really ideal" — design for that:

- a **visible indicator** whenever it is listening (the watch's orange ring; on
  phone/desktop the FGS notification does double duty);
- **foreground/screen-on only**, or an explicit **toggle** — not literally 24/7 by default;
- maybe **desktop-mostly** (plugged in, no battery worry) and leave mobile to the watch.

## Pico 2 W as a room node (RP2350)

**Compute is a non-issue:** the RP2350 runs the same microfrontend + TFLite-Micro + the
same `.tflite` files; the port is SDK-side (Pico SDK), as `docs/voice-wake-words.md` notes.

**"Across the room" (~20 ft) is an acoustics problem, not a compute one.** The wall is the
room's **critical distance** (~1–2 m):

- Level: a normal voice is ~60 dB SPL at 1 m; at 6 m the *direct* sound is ~44 dB SPL. A
  good MEMS mic's floor is ~30 dB SPL, so direct SNR is ~10–14 dB — workable **in a quiet
  room**.
- Past the critical distance the **reverberant field dominates** (the mic mostly hears
  reflections), and that collapsed direct-to-reverberant ratio — not raw level — is what
  wrecks far-field recognition. It is a wall, not a slope.
- A normal room's noise (HVAC, fridge, traffic: 35–45 dB SPL) can drop SNR to ~0 dB and it
  simply will not fire. ("Quiet room" is doing a lot of work.)
- For reference, commercial far-field (Alexa-class) uses a **mic array + beamforming +
  AEC + a far-field-trained model** and still tops out ~10–20 ft in quiet.

**Levers, in order:** (1) **retrain the wake word with far-field augmentation** (reverb +
noise + gain/distance) — biggest single win, doable in the existing notebook; (2) a good
low-noise I2S mic (INMP441/ICS-43434 class) with well-set gain; (3) a small **mic array +
delay-and-sum beamforming**; (4) a lower cutoff (recall over precision). And remember
**whisper must hear the command** at that distance too — the gate firing is necessary, not
sufficient.

**Reframe:** distance is the enemy, so **several cheap near nodes beat one far node.** Put
a Pico (or a watch) *near* where you are — a 1–2 m pickup is trivially reliable with a
decent mic, versus fighting 20 ft of reverb.

## Capture rates today (the watch's live stream and its file)

The **live BLE stream stays 8 kHz.** The **whole-clip file** records **16 kHz when WiFi is up
at capture start** and 8 kHz otherwise — it is uploaded over HTTP, not notified, so it can
afford the rate that the link cannot.

Why the stream was assumed unable to follow: at **MTU 23** a notify carries **12 payload bytes**
(`jw/jw_02_ble.ino:115`), so an 8 kHz stream would run roughly **11x slower than realtime**
and the sender abandons it rather than truncate the clip (`jw/jw_08_voice.ino:319-331`).

**Measured 2026-11-27: the watch/phone link negotiates MTU 512, not 23.** The Android bridge
requests 512 and the watch grants it (`scripts/jawn-bt status` on the phone reports
`"mtu":512` while connected), so a notify carries 509 bytes and the 4 KB stream parts fit in
about 11 notifies each. The display contention that made 512 an opt-in was an Android request
time issue, not a reason to stay at 23; the watch's fragmentation already follows
`getPeerMTU()`. The desktop bridge has no MTU API of its own, so it now reads BlueZ's
`GattCharacteristic1.MTU` after subscribing and reports the negotiated value instead of the
number it asked for (`desktop/jawnos_desktop/ble.py`). If a link really has settled at 23,
that is now visible instead of hidden behind a reported 512.

The **WiFi route returns at once.** `/watch/voice` sends the same `voice_recv` receipt the BLE
whole-clip path sends, and runs whisper + the Guide in a child; previously it did both inline,
the watch's 4 s POST timed out, and the watch re-shipped the clip over BLE for up to 45 s.

**Open decision:** whether the live stream or the whole-clip file is the **authoritative
transcript**. *File-is-truth* was built: a memo waits for the file; a command takes whichever
copy arrives first (`lib/JawnOS/Domain/Ai.pm`, `docs/transcription-roadmap.md`).

## Parked items (pick up any)

1. **Pico mic + gain spec, and the SDK port** (same models).
2. **Far-field augmentation** for the wake-word training notebook.
3. **Desktop/phone always-on listener** — native daemon reusing the watch's models +
   `micro_features`, POSTing to the existing `/watch/voice` (everything downstream works).
   Then the Android foreground service.
4. **ES7210 mic-gain** on the watch (helps the close/whisper case actually used today).
5. **WiFi-join verification** on the watch (creds are in the DB; just needs the join).
6. **A spoken reply on a machine with no piper.** The Android app runtime runs no glibc
   binary and ships no python, so `scripts/jawnos_deps.pl` deliberately skips piper there and
   the watch's phone homebase was answering in text only. The reply paths now fall back to the
   OpenAI-compatible `/audio/speech` endpoint the `text_to_audio_assistant` role names
   (`groq:playai-tts` by default), transcribed to 8 kHz mono with ffmpeg. Before the cloud,
   the reply paths ask the Crew for a peer with piper (`say.render`, gated on the `piper`
   tool) and stream the 8 kHz PCM it returns, so the house voice stays the house voice. Piper
   stays first wherever it can run, so a desktop's own voice does not change. Groq retired the PlayAI model,
   so that setting is mapped to `canopylabs/orpheus-v1-english` (voice `hannah`) and the log
   names the model that actually spoke. Note the privacy trade: a reply spoken through the
   cloud sends that sentence to the provider.

The spoken-input brain those all feed is the guide's; see `docs/voice-brain-handoff.md`.
