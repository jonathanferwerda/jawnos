# Third-party notices

JawnOS is mostly a runtime that *uses* other people's software. This file covers the
narrower set of third-party assets that JawnOS itself **bundles or redistributes** — the
things that actually ship in (or alongside) the repo or its blob store. It does **not**
cover the packages JawnOS merely depends on and installs from your own distribution
(see the last section).

Each entry was verified against the upstream source at the time of writing. Where a
licence could not be verified, it is marked **unverified** rather than guessed.

Legend: **bundled** = the file is redistributed by JawnOS; **blob store** = redistributed
through JawnOS's own blob-sync mechanism rather than committed to git.

---

## 1. JawnOS itself

| Asset | Licence (SPDX) | Where |
| --- | --- | --- |
| JawnOS | **BSD-2-Clause** | `LICENSE` |

`LICENSE` is the BSD 2-Clause License, Copyright (c) 2026, Jonathan Ferwerda. Everything
first-party in this repository (the Perl services, templates, `public/` assets, firmware,
and the `releases/` APKs JawnOS builds) is under that licence unless a file says otherwise.

---

## 2. Bundled / redistributed assets

| # | Asset | Upstream source | Licence (SPDX) | Where it lives |
| --- | --- | --- | --- | --- |
| 2.1 | Piper TTS engine (prebuilt Linux binary) | https://github.com/rhasspy/piper (v1.2.0) | **MIT** | `voices/piper/piper` (blob store) |
| 2.1a | ↳ espeak-ng 1.52.0 (bundled inside the Piper build) | https://github.com/espeak-ng/espeak-ng | **GPL-3.0-or-later** | `voices/piper/espeak-ng`, `libespeak-ng.so.1.52.0.1`, `espeak-ng-data/` |
| 2.1b | ↳ ONNX Runtime 1.14.1 | https://github.com/microsoft/onnxruntime | **MIT** | `voices/piper/libonnxruntime.so.1.14.1` |
| 2.1c | ↳ piper-phonemize 1.2.0 | https://github.com/rhasspy/piper-phonemize | **MIT** | `voices/piper/libpiper_phonemize.so.1.2.0`, `piper_phonemize` |
| 2.1d | ↳ libtashkeel diacritization model | https://github.com/mush42/libtashkeel | **MIT** (model artifact — see note) | `voices/piper/libtashkeel_model.ort` |
| 2.2 | Piper voice models `.onnx` (+ `.onnx.json`) | https://huggingface.co/rhasspy/piper-voices | **MIT** (repo-level; per-voice notes below) | `voices/*.onnx` (blob store) |
| 2.3 | Noto Sans Bold webfonts (C headers) | https://github.com/notofonts/noto-fonts | **OFL-1.1** | `jt/NotoSansBold15.h`, `jt/NotoSansBold36.h` |
| 2.4 | Montserrat clock digits (C source) | https://github.com/JulietaUla/Montserrat | **OFL-1.1** | `jw/fonts/clock_font_72.c` |
| 2.5 | Montserrat fonts in LVGL | https://github.com/JulietaUla/Montserrat | **OFL-1.1** (LVGL itself is MIT) | used via `lv_font_montserrat_*` in `jw/jw.ino` |
| 2.6 | "Final Frontier" display font | unknown | **unverified** | `jt/Final_Frontier_28.h` |
| 2.7 | "Latin + Hiragana" font | unknown | **unverified** | `jt/Latin_Hiragana_24.h` |
| 2.8 | "Unicode Test" font | unknown | **unverified** | `jt/Unicode_Test_72.h` |

### 2.1 Piper TTS engine

The prebuilt Linux binary under `voices/piper/` reports `piper --version` = `1.2.0` and
corresponds to the `rhasspy/piper` release asset
`https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz`
(the `2023.11.14-2` release; use `piper_linux_aarch64.tar.gz` for arm64 hosts).

- `rhasspy/piper` is licensed **MIT** (its `LICENSE.md`: "MIT License, Copyright (c)
  2022 Michael Hansen"). The repository is now **archived**, and development has moved to
  https://github.com/OHF-Voice/piper1-gpl, which is **GPL-3.0**. The vendored binary here
  is the older, MIT-licensed 1.2.0 build — that is the version this notice describes.
- The Piper release archive is not the engine alone: it also redistributes **espeak-ng**,
  **ONNX Runtime**, **piper-phonemize** and a **libtashkeel** model. Their licences are
  listed as `2.1a`–`2.1d`. Note in particular that **espeak-ng is GPL-3.0-or-later**, so
  the Piper bundle as a whole contains a copyleft component even though Piper itself is
  MIT.
- The binary and its library/data files are carried as blobs (like the APKs), not committed
  to git; only `say_piper_binary()` in `subroutines.pl` and the sync loop reference them.

### 2.2 Piper voice models

The `*.onnx` models (and their `*.onnx.json` configs) are downloaded from the HuggingFace
**model** repository `rhasspy/piper-voices`. Its `README.md` front-matter declares
`license: mit`, and the repository's HuggingFace tags include `license:mit`. The related
dataset repository `rhasspy/piper-checkpoints` also declares `license:mit`.

Each voice also has a per-voice `MODEL_CARD` naming the **training dataset**, whose licence
can differ from the model repository's MIT declaration. For the three voices JawnOS ships:

| Voice | Upstream folder | Training dataset / licence |
| --- | --- | --- |
| `en_US-ljspeech-medium` | `en/en_US/ljspeech/medium` | LJSpeech (keithito.com/LJ-Speech-Dataset) — **public domain** |
| `en_US-libritts_r-medium` | `en/en_US/libritts_r/medium` | LibriTTS-R (OpenSLR 141) — **CC BY 4.0** |
| `en_GB-alba-medium` | `en/en_GB/alba/medium` | Edinburgh DataShare 10283/3270 — **CC BY 4.0** |

Each voice's training dataset carries its own licence, which the repository-level MIT tag
does not override, so JawnOS ships only cleanly-permissive voices (public domain or CC BY —
never NC or ND). Two earlier voices were dropped for exactly this reason:
`en_US-amy-medium` (dataset "see URL") and `en_US-ryan-medium` (**CC BY-NC-SA 4.0**,
non-commercial). A voice removed from `say_voices()` is deleted from `voices/` and pruned
from every device by `voice_sync`.

### 2.3–2.5 Fonts

- `jt/NotoSansBold15.h` and `jt/NotoSansBold36.h` are the Noto Sans family (Bold),
  licensed **OFL-1.1** by Google/Noto. The headers carry no attribution of their own; the
  font name is in the array identifier and matches Noto Sans.
- `jw/fonts/clock_font_72.c` states it was "generated from Montserrat-Medium.ttf by
  tools/lv_font_digits.py". The Montserrat typeface is **OFL-1.1**.
- The watch's `lv_font_montserrat_*` fonts come from LVGL. The **Montserrat typeface is
  OFL-1.1**; the LVGL library that bundles the converted tables is **MIT** and is fetched
  by the PlatformIO build (see the dependency note below).

### 2.6–2.8 Unverified fonts

`jt/Final_Frontier_28.h`, `jt/Latin_Hiragana_24.h` and `jt/Unicode_Test_72.h` are bitmap
font tables in the same converted-header format, but their headers contain **only generic
conversion instructions** (a pointer to the tomeko.net hex tool) — no font name, author or
licence. They cannot be attributed confidently from the repo contents alone:

- `Final_Frontier_28.h` — a display font named "Final Frontier"; source/licence **unknown**.
- `Latin_Hiragana_24.h` — a font covering Latin + Hiragana; source/licence **unknown**.
- `Unicode_Test_72.h` — a broad-coverage test font; source/licence **unknown**.

**Action:** trace where each was obtained (they came in with the initial commit) and replace
this with the real licence, or replace the font with a clearly-licensed one.

### Firmware assets bundled as C headers (outside the font scope)

The watch firmware also embeds model weights as C headers, generated from `.tflite` files
under `~/jawnos-fw/models/`:

- `jw/vad_model.h`, `jw/hey_jawn_model.h`, `jw/jawn_do_model.h` — microWakeWord-format
  models. The **microWakeWord** framework (https://github.com/kahrendt/microWakeWord) is
  **Apache-2.0**, and the on-device runtime, TensorFlow Lite Micro
  (https://github.com/tensorflow/tflite-micro), is **Apache-2.0**. `hey_jawn` / `jawn_do`
  are JawnOS-trained (recipe in `docs/training-hey-jawn.md`). The **licence of the model
  artifacts themselves is unverified here** — flag for review if this document is meant to
  be exhaustive.

---

## 3. Dependencies JawnOS does NOT redistribute

The apt / pacman / Termux packages and the CPAN Perl modules listed in
`scripts/jawnos_deps.pl` are **not** bundled or redistributed by JawnOS. They are installed
by the user from their own distribution's repositories (or from CPAN), under those
projects' own licences, and are therefore out of scope for this file. This includes the
command-line tools (Perl, OpenSSL, SQLite, curl, FFmpeg, ImageMagick, Tesseract, SoX,
espeak, …), the desktop extras (WebKitGTK, GStreamer), and the Perl modules
(Mojolicious, Minion, CryptX, …).

Likewise, the firmware's PlatformIO-managed libraries (LVGL, TFT_eSPI, TinyGPS++,
tflite-micro, etc.) are fetched by the build rather than committed here; only the headers
enumerated in section 2 are actually redistributed.

---

## 4. How to refresh / verify

Re-run these against upstream before relying on this file:

```sh
# JawnOS's own licence
head -3 LICENSE

# Piper engine + its bundled libraries (repo licence; note it is archived and MIT)
curl -s https://api.github.com/repos/rhasspy/piper | grep -A3 '"license"'
curl -s https://raw.githubusercontent.com/rhasspy/piper/master/LICENSE.md | head -3
curl -s https://api.github.com/repos/espeak-ng/espeak-ng        | grep '"spdx_id"'   # GPL-3.0
curl -s https://api.github.com/repos/microsoft/onnxruntime      | grep '"spdx_id"'   # MIT
curl -s https://api.github.com/repos/rhasspy/piper-phonemize    | grep '"spdx_id"'   # MIT
curl -s https://api.github.com/repos/mush42/libtashkeel         | grep '"spdx_id"'   # MIT
# vendored build version:
voices/piper/piper --version

# Voice models: canonical repo is the MODEL repo, not the /datasets/ path
# (the /datasets/ URL currently returns HTTP 401 for anonymous access)
curl -sL https://huggingface.co/rhasspy/piper-voices/raw/main/README.md | sed -n '1,3p'
curl -sL https://huggingface.co/rhasspy/piper-voices/raw/main/en/en_US/ljspeech/medium/MODEL_CARD
curl -sL https://huggingface.co/rhasspy/piper-voices/raw/main/en/en_US/libritts_r/medium/MODEL_CARD
curl -sL https://huggingface.co/rhasspy/piper-voices/raw/main/en/en_GB/alba/medium/MODEL_CARD

# Fonts
curl -s https://api.github.com/repos/notofonts/noto-fonts   | grep '"spdx_id"'   # OFL-1.1
curl -s https://api.github.com/repos/JulietaUla/Montserrat  | grep '"spdx_id"'   # OFL-1.1

# Firmware model framework
curl -s https://api.github.com/repos/kahrendt/microWakeWord | grep '"spdx_id"'   # Apache-2.0
```

For the three unverified headers in 2.6–2.8, verification requires locating their original
`.vlw`/`.ttf` sources — they are not recoverable from the committed C arrays.
