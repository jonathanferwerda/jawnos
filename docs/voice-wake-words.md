# Voice & wake words (watch, deck, and later Pico)

On-device, hands-free voice for JawnOS: the watch/deck detect speech (and a wake
word), capture a clip, and ship it over BLE/WiFi to the server, where whisper
transcribes it and `subs::voice_command_parse` decides command vs. note. This
file records the runtime pieces and the plan, so it can be picked up later.

## The big finding (do not re-do this work)

The **ESP32 Arduino core (3.3.12) already bundles the runtime, prebuilt for the
S3** — nothing needs porting or vendoring:

- `esp-tflite-micro` — interpreter + kernels, as a prebuilt `.a` with headers:
  `~/jawnos-fw/data/packages/esp32/tools/esp32s3-libs/<ver>/lib/libespressif__esp-tflite-micro.a`
  and headers under `.../include/espressif__esp-tflite-micro/`. Include
  `tensorflow/lite/micro/...` and it links (verified by compiling a test sketch
  for `esp32:esp32:twatchs3`).
- `esp-sr` — Espressif's Speech Recognition, also prebuilt: `esp_vad` (VAD),
  `esp_wn_iface`/WakeNet (stock wake words), MultiNet, the audio front-end, and
  the model data `.../esp32s3-libs/<ver>/esp_sr/srmodels.bin`. This is where the
  T-Deck's `#include <esp_vad.h>` comes from.

So the "port TFLite-Micro to the watch" task is a **wiring** job, not a build job.

## Path chosen: microWakeWord (custom words)

Only microWakeWord trains *custom* phrases ("hey jawn", …). WakeNet only has
Espressif's fixed words (alexa, hilexin, xiaoaitongxue). Pieces:

| Piece | Where |
| --- | --- |
| Interpreter + kernels | bundled in the core (above) |
| 40-feature audio front-end (the "microfrontend") | upstream `tensorflow/tflite-micro`, `tensorflow/lite/experimental/microfrontend/lib/` (Espressif's fork trimmed it). Fetched via a sparse checkout. |
| Models | `vad.tflite` etc. from `esphome/micro-wake-word-models` (v2); custom models trained with `kahrendt/microWakeWord` |

**Front-end settings must match training exactly:** 16 kHz, 30 ms window, 10 ms
step, 40 channels, PCAN on, 125–7500 Hz, `out_type` uint16. Feed **160 samples
(10 ms)** at a time. (Source of truth: `microwakeword/audio/audio_utils.py`.)

## Wake phrases (target list)

`hey jawn`, `sup jawn`, `jawnski`, `sup ya hoser` (and `jawn do`) —
multi-syllable and distinctive, which train reliably and false-fire less than a
lone "Jawn". **Each phrase is its own `.tflite`** (one training run each, ~a day
on Colab); the firmware holds a **list of models** (`voice_words[]` in
`jw/voice_models.h`) so adding a phrase later is a file drop. `hey jawn` and
`jawn do` are trained; `sup jawn`, `jawnski`, `sup ya hoser` are still to do.

## Setting plumbing (already built)

`operator_door.__specs.voice_trigger` on a watch/deck, values `off` / `vad` /
`<phrase>`. The Embedded panel writes it and pushes a fresh Now Me
(`templates/embedded/embedded.html.ep` + `public/js/manager/embedded.js`);
`now_me` carries it to the device in the payload. Firmware maps it onto the
capture listener (`voice_trigger_apply()` in `jw/jw.ino`).

## Boards

- `jw/` — T-Watch S3 (I2S mic already at 16 kHz mono). Neural VAD + two wake words.
- `jt/` — T-Deck (ESP32-S3, ES7210 mic, **already uses `esp_vad`**, more
  flash/PSRAM + SD). VAD design is largely there; needs the wake word.
- Runtime wiring is chip-level, so a shared library under
  `~/jawnos-fw/watch-libs/` serves both.

## T-Deck parity (required)

The deck has **fallen behind the watch** and must be brought to the same feature set.
The panel already offers a `voice_trigger` for a deck, but on the deck it currently
arms nothing. This is the second half of the voice work and it is the *easier* of the
two: an ESP32-S3 with the **ES7210 mic already streaming 16 kHz**, `esp_vad` already
initialised, more flash/PSRAM, and an SD card.

**Reuse, do not reinvent.** All of this is chip-level and compiles for the deck as-is:

- `jw/voice_models.h` and the model headers (`vad`, `hey_jawn`, `jawn_do`) — the whole
  table-driven listener.
- The `jawn_micro_features` front-end in `~/jawnos-fw/watch-libs/`.

Only the *mic feed* differs: the deck's ES7210 arrives as one TDM frame of four slots,
so MIC1 (the first) is the mono track the front-end wants.

**Checklist — each line is a watch behaviour the deck lacks today:**

1. **microWakeWord listener.** Replace the deck's `esp_vad`-only capture with the
   model table (`voice_words[]`), one model at a time, tensor arena in PSRAM.
2. **`voice_trigger` plumbing.** `voice_trigger_apply()` arming on
   `voice_models_has()`, driven by the panel's `now_me` push (and the BLE path the
   watch already uses).
3. **Automatic capture.** A task that captures on wake / any speech, ships, and keeps
   listening. The deck records only via a **manual button** today.
4. **Clip compaction + ship.** IMA ADPCM WAV (~4:1, ffmpeg reads it as-is) over
   **WiFi-first, BLE fallback**, tagged with the *active* model (`voice_mode_name`),
   stamped at **utterance onset** (`onset_ts`). Inflate the deflate'd payload in a task
   with the ROM miniz — never in the BLE callback.
5. **Acks + feedback.** `voice_recv` / `voice_done`, the on-screen listening border,
   and the keep-the-screen-awake-while-capturing rule.
6. **Serial tools.** `voicedbg on`, `vtrig <mode>`, `voice` — same names as the watch.
7. **WiFi creds over BLE.** The `type:"wifi"` push the Embedded panel already sends.

**Check early:** the ES7210's **channel routing / gain** (MIC1 of four, 37.5 dB — that
is already its maximum) has to match what the watch's mono mic gives the model, and the
deck's larger buffers may want the same `loop2` split for inflate and capture.

## Pico 2 W (later, different ecosystem)

RP2350 — **not** ESP32, so none of the bundled Espressif libs apply. The
*approach* ports: build TFLite-Micro + the microfrontend with the **Pico SDK**,
use microWakeWord's own `vad.tflite` (no `esp-sr`), and add an external **I2S
mic** (the Pico has none). The trained `.tflite` models are identical across
watch, deck, laptop, and Pico.

## Status

- **VAD and two custom wake words are in the watch firmware.** `jw/voice_models.h`
  is table-driven (`voice_words[]`): one row per voice, holding its `.tflite` bytes
  and its `probability_cutoff`. `voice_models_init()` loads whichever row the
  setting asks for (one at a time) over the shared `micro_features` front-end;
  tensor arenas are in PSRAM. Adding a phrase is a file drop (train, run
  `.shots/tflite_to_header.py`, add an include and a row).
- **`voice_active_frame()` reports a state, not a self-clearing one-shot.** It
  used to clear its sliding window on every hit (a "cool off" to avoid a double
  detect), but the listener counts consecutive speech frames before it commits a
  capture, so that count reset every time and *no capture ever committed* - the
  VAD read speech (peak 255) yet nothing recorded, so no clip and no orange ring.
  It now returns "is there speech now?". Debug the path over serial with
  `voicedbg on` (prints `frames/maxamp/peak/fires/stride` once a second).
- **`hey_jawn`** is embedded as `jw/hey_jawn_model.h` (62 KB, trained on Colab).
  **`jawn_do` is currently the same model bytes under another name** — the two
  headers differ only in the generator comment and the array name, and every
  `*.tflite` copy (`~/Downloads/`, `~/jawnos-fw/models/`) is md5 `a3da6184…` — so
  the watch can only ever fire on "hey jawn" and the Jawn Do setting does nothing.
  Training the real phrase is a Colab run away: `~/Downloads/jawn_do_colab.ipynb`
  is the notebook with `target_word = 'jawn do'` and `dst = 'jawn_do.tflite'`
  already set; run it, then
  `.shots/tflite_to_header.py jawn_do.tflite jw/jawn_do_model.h jawn_do_model`
  and rebuild. Verify the *model bytes*, not the whole file: `cmp` the arrays
  past the first line (or md5 the new tflite/dump) — a fresh header always
  differs in the comment and array name, which is exactly how the copy slipped
  through.
- **A wake-word capture ends on frame energy, not on the model.** The model only
  speaks for its phrase, so using its output as the silence detector ended every
  command ~900 ms after "hey jawn" (the clip carried the wake word and nothing
  else, and the server heard a blank/fragmentary transcript). While recording a
  wake-word capture, `voiceListenTask` now ends on `VOICE_WAKE_RMS_FLOOR` instead;
  a VAD capture still uses the model.
- **The Embedded panel's voice select now arms the wake words too.**
  `voice_trigger_apply()` in `jw/jw.ino` asks `voice_models_has()` (true for `vad`
  and any phrase with a model), so picking a phrase in the panel starts the
  listener instead of disarming it as it did before the runtime landed.
- `micro_features` (the front-end) lives in `~/jawnos-fw/watch-libs/`, built by
  `.shots/micro_features_vendor.sh`.
- The interpreter is the ESP32 core's bundled `esp-tflite-micro`; nothing is
  vendored for it.
- The panel can't always push the setting over BLE (the phone usually owns the
  link), so the console has `vtrig hey_jawn` / `vtrig jawn_do` / `vtrig vad` /
  `vtrig off` for tuning. Two more console commands help testing with no hand on
  the watch: `awake` rebases the screen timeout (a tilt-sim raise only holds the
  screen ~5 s), and `heapfast <secs>` samples the DMA heap from a core-0 task
  while a sequence runs.
- **The payload path carries binary safely now, and the wake word persists.** The
  compressed daemon->watch payload is binary, but the BLE write callback built its
  chunk with `String(getValue().c_str())`, which stops at the first NUL -- every
  compressed part was truncated, so the inflate failed (`[ble] inflate failed`) and
  the big pushes (the room, the Now Me that carries `voice_trigger`) never applied.
  The callback copies the full length now. And `tinfl_decompress_mem_to_mem` keeps
  a ~10.5 KB `tinfl_decompressor` on the stack, so `loop2` went from 12 KB to 20 KB
  (its headroom during an inflate went from ~0.4 KB to ~8 KB). The chosen phrase is
  also saved in `config.json` (`voice_trigger`), so it no longer reverts to the VAD
  on every reboot.
- **The voice model's arenas live in PSRAM, so they stop starving the LCD.** The
  resource-variable arena is 8 KB per `voice_slots[]` row (three rows, one model
  active) -- ~24 KB of internal `.bss`. Once the room payloads started applying,
  that was enough to push the LCD's SPI DMA bounce (`max_transfer_sz`, 24 rows =
  11520 bytes) past the largest free internal block: `spi_master` could not
  allocate the bounce, draws failed, and the screen kept stale room pixels while
  taps appeared dead. The arena is `ps_malloc`'d with the tensor arena now, and the
  48 KB inflate scratch is PSRAM too; internal heap went ~39 KB -> ~64 KB and the
  DMA errors stopped.
- **`jawn_features_init` populates once.** Every listener arm called it, and each
  call ran `FrontendPopulateState` again -- which mallocs the window, filterbank,
  FFT and noise-reduction buffers -- without freeing the old ones. That leaked
  ~11.7 KB of internal RAM per screen wake (the same wake sequence with the
  listener off was perfectly flat), enough that a walk's wrist raises drained the
  heap into aborts. Populate now returns early once ready (`if (g_ready) { return
  true; }`); a three-wake probe holds one int figure the whole way. The vendor tree
  is not a repo: `jw/patches/microfeatures-populate-once.patch`.

## Next steps

1. Train the other phrases (`sup jawn`, `jawnski`, `sup ya hoser`) the same way;
   embed each as another `*_model.h` and add a `voice_words[]` row.
2. Tune each model's `probability_cutoff` from its `tflite_streaming_roc.txt`
   (was 0.90 and hey jawn did not fire on a walk; lowered to 0.75 for both wake
   words. The hey jawn ROC file was lost, so 0.75 is still a guess - retrain for
   the curve, or lower further if it still misses).
3. **Deck parity (`jt/`).** Bring the deck up to the watch — see **T-Deck parity**
   above for the full checklist (it already has `esp_vad` and an ES7210 mic, so this
   is the wiring, not new research).
