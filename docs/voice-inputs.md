# Voice inputs beyond the watch (desktop, phone, Pico)

The watch is live (see `docs/voice-wake-words.md`). This is the plan for the other
places you'd speak from, captured so it is not lost between sessions. Nothing here is
built yet; it is a design and the decision points still open.

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

## Parked items (pick up any)

1. **Pico mic + gain spec, and the SDK port** (same models).
2. **Far-field augmentation** for the wake-word training notebook.
3. **Desktop/phone always-on listener** — native daemon reusing the watch's models +
   `micro_features`, POSTing to the existing `/watch/voice` (everything downstream works).
   Then the Android foreground service.
4. **ES7210 mic-gain** on the watch (helps the close/whisper case actually used today).
5. **WiFi-join verification** on the watch (creds are in the DB; just needs the join).

The spoken-input brain those all feed is the guide's; see `docs/voice-brain-handoff.md`.
