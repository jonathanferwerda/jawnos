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
- **`hey_jawn`** and **`jawn_do`** (62 KB each, trained on Colab) are
  embedded as `jw/hey_jawn_model.h` / `jw/jawn_do_model.h`.
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
  `vtrig off` for tuning.

## Next steps

1. Train the other phrases (`sup jawn`, `jawnski`, `sup ya hoser`) the same way;
   embed each as another `*_model.h` and add a `voice_words[]` row.
2. Tune each model's `probability_cutoff` from its `tflite_streaming_roc.txt`
   (was 0.90 and hey jawn did not fire on a walk; lowered to 0.75 for both wake
   words. The hey jawn ROC file was lost, so 0.75 is still a guess - retrain for
   the curve, or lower further if it still misses).
3. Deck (`jt/`): same `voice_models.h`/`micro_features` wiring (it already has
   `esp_vad` and an ES7210 mic).
