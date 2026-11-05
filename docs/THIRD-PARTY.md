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
first-party in this repository (the Perl services, templates, `public/` assets and firmware)
is under that licence unless a file says otherwise. The `releases/` APKs are **not** covered
by it: the Android host app is a GPL-3.0-only derivative of Termux (see 2.14), and the
runtime archives carry their own licences (see 2.15).

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
| 2.3 | Noto Sans Bold webfonts (C headers) | https://github.com/notofonts/noto-fonts | **OFL-1.1** | `jt/NotoSansBold15.h`, `jt/NotoSansBold36.h`; text in `jt/OFL-NotoSans.txt` |
| 2.4 | Montserrat clock digits (C source) | https://github.com/JulietaUla/Montserrat | **OFL-1.1** | `jw/fonts/clock_font_72.c`; text in `jw/OFL-Montserrat.txt` |
| 2.5 | Montserrat fonts in LVGL | https://github.com/JulietaUla/Montserrat | **OFL-1.1** (LVGL itself is MIT) | used via `lv_font_montserrat_*` in `jw/jw.ino`; text in `jw/OFL-Montserrat.txt` |
| 2.6 | Final_Frontier_28 (TFT_eSPI smooth font) | https://github.com/Bodmer/TFT_eSPI (`examples/Smooth Fonts/FLASH_Array/Unicode_test`) | **BSD-2-Clause** (FreeBSD) | `jt/Final_Frontier_28.h`; text in `jt/TFT_eSPI-LICENSE.txt` |
| 2.7 | Latin_Hiragana_24 (TFT_eSPI smooth font) | same TFT_eSPI example | **BSD-2-Clause** (FreeBSD) | `jt/Latin_Hiragana_24.h`; text in `jt/TFT_eSPI-LICENSE.txt` |
| 2.8 | Unicode_Test_72 (TFT_eSPI smooth font) | same TFT_eSPI example | **BSD-2-Clause** (FreeBSD) | `jt/Unicode_Test_72.h`; text in `jt/TFT_eSPI-LICENSE.txt` |
| 2.9 | jQuery 3.6.1 | https://jquery.com | **MIT** | `public/js/jquery.js` |
| 2.10 | jQuery UI 1.13.2 | https://jqueryui.com | **MIT** | `public/js/jquery-ui.js`, `public/css/jquery-ui.css`, `public/css/images/ui-icons_*.png` |
| 2.11 | jQuery UI Touch Punch 0.2.3 | https://github.com/furf/jquery-ui-touch-punch | **MIT** or **GPL-2.0** (dual) | `public/js/jquery.ui.touch-punch.min.js` |
| 2.12 | numeral.js 2.0.6 | https://github.com/adamwdraper/Numeral-js | **MIT** | `public/js/numeral.min.js` |
| 2.13 | Moment.js 2.29.4 | https://momentjs.com | **MIT** | `public/js/moment.js` |
| 2.14 | JawnOS Android host app | https://github.com/jonathanferwerda/termux-app (fork of `termux/termux-app`) | **GPL-3.0-only** | `releases/jawnos-app-*.apk` (blob store) |
| 2.15 | JawnOS runtime archives | built from `termux/termux-packages` recipes | **mixed** (GPL-3.0, GPL-2.0, LGPL-2.1+, MIT, BSD, Apache-2.0, Artistic-1.0, public domain) | `releases/jawnrt-*.zip` (blob store) |

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
- Because espeak-ng is **GPL-3.0-or-later**, the source offer travels with the
  bundle: `scripts/jawnos_deps.pl` writes `SOURCE.txt` and a `COPYING` (the
  GPL-3.0 text) beside the installed piper binary (`piper_offer()`), and the
  same text is in `docs/licenses/runtime/GPL-3.0.txt`. The source is espeak-ng
  1.52.0: https://github.com/espeak-ng/espeak-ng/tree/1.52.0.

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

The two CC BY 4.0 voices require attribution: the dataset, author, and licence
are recorded in `docs/voice-attribution.md`, and `voice_sync` writes the same
notice to `~/jawnos/voices/ATTRIBUTION.md` on every device.

### 2.3–2.5 Fonts

- `jt/NotoSansBold15.h` and `jt/NotoSansBold36.h` are the Noto Sans family (Bold),
  licensed **OFL-1.1** by Google/Noto. The headers carry no attribution of their own; the
  font name is in the array identifier and matches Noto Sans.
- `jw/fonts/clock_font_72.c` states it was "generated from Montserrat-Medium.ttf by
  tools/lv_font_digits.py". The Montserrat typeface is **OFL-1.1**.
- The watch's `lv_font_montserrat_*` fonts come from LVGL. The **Montserrat typeface is
  OFL-1.1**; the LVGL library that bundles the converted tables is **MIT** and is fetched
  by the PlatformIO build (see the dependency note below).

### 2.6–2.8 TFT_eSPI smooth fonts

The three smooth-font headers are **byte-identical** to the fonts in TFT_eSPI's
`examples/Smooth Fonts/FLASH_Array/Unicode_test/` example (the md5s match
upstream): `Final_Frontier_28.h`, `Latin_Hiragana_24.h` and
`Unicode_Test_72.h`. TFT_eSPI is **BSD-2-Clause** (its “FreeBSD License”),
Copyright (c) Bodmer; the text travels with the sketch as
`jt/TFT_eSPI-LICENSE.txt`. The headers' own comments name only the vlw-to-array
tool, which is why they looked unattributed.
### 2.9–2.13 JavaScript libraries

These are loaded by `templates/layouts/manager.html.ep:13,205-209`; the gate,
homepage and locked layouts load jQuery and numeral too. All are unmodified
except for the minified Touch Punch build.

Each file's copyright line, followed by the shared MIT text:

- **jQuery 3.6.1** — Copyright OpenJS Foundation and other contributors, https://openjsf.org/
- **jQuery UI 1.13.2** — Copyright jQuery Foundation and other contributors, https://jquery.org/
  (includes the Smoothness theme images under `public/css/images/`)
- **numeral.js 2.0.6** — Copyright (c) 2012 Adam Draper
- **Moment.js 2.29.4** — Copyright (c) JS Foundation and other contributors
- **jQuery UI Touch Punch 0.2.3** — Copyright 2011–2014, Dave Furfero
  (dual MIT / GPL-2.0; used here under MIT)

> Permission is hereby granted, free of charge, to any person obtaining a copy of
> this software and associated documentation files (the "Software"), to deal in
> the Software without restriction, including without limitation the rights to
> use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
> of the Software, and to permit persons to whom the Software is furnished to do
> so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.


### Firmware assets bundled as C headers (outside the font scope)

The watch firmware also embeds model weights as C headers, generated from `.tflite` files
under `~/jawnos-fw/models/`:

- `jw/vad_model.h` — the `vad.tflite` model from
  https://github.com/esphome/micro-wake-word-models (v2), **Apache-2.0**; the text is
  `jw/Apache-2.0.txt`, and the attribution is `jw/NOTICE.txt`.
- `jw/hey_jawn_model.h`, `jw/jawn_do_model.h` — **JawnOS-trained** models (the Colab
  recipe is `docs/jawn_do_colab.ipynb`), first-party under BSD-2. The training framework,
  microWakeWord (https://github.com/kahrendt/microWakeWord), and the on-device runtime,
  TensorFlow Lite Micro (https://github.com/tensorflow/tflite-micro), are **Apache-2.0**.

### 2.14 JawnOS Android host app (GPL-3.0-only)

The APK is a fork of Termux's `termux-app` (base tag `v0.118.3`) and still contains
code derived from it, so the **binary is GPL-3.0-only** even though `jawnos-shared`
has been rewritten as BSD-2 and the app package was renamed. Three app source files
still show 52–67% similarity to upstream (`JawnInstaller`, `UserAction`,
`CrashUtils`) and six resource files are byte-identical. A BSD-2 relicense needs
those rewritten and a clean-room review — it cannot be done by changing the label,
because the upstream copyright holders' GPL-3.0-only grant still applies.

- Source: https://github.com/jonathanferwerda/termux-app (branch `jawnos`).
  `scripts/app_publish.pl` records the exact commit a build came from in
  `releases/app_release.json` and `server/downloads.json` (`sourceCommit`), and a
  commit archive is available at
  `https://github.com/jonathanferwerda/termux-app/archive/<sourceCommit>.tar.gz`.
- Licence text: `app/src/main/assets/licenses/GPL-3.0.txt`, also inside the APK
  under `assets/licenses/`.
- Notices: `app/src/main/assets/licenses/NOTICE.md` lists the Apache-2.0
  components (`terminal-view`, `terminal-emulator`, AndroidX, Guava, Markwon,
  android-smsmms), the BSD-3-Clause `libtailscale`, and the runtime licences.

### 2.15 Runtime archives (mixed licences)

`jawnrt-*.zip` are built by `scripts/runtime_build.pl` and `runtime_zip.pl` from
Termux packages and are redistributed as release assets; the app downloads the
archive pinned in `app/src/main/assets/jawnrt.json`. They aggregate separate
programs, each under its own licence:

- bash, coreutils, findutils, sed, grep, gawk, rsync — **GPL-3.0**
- git — **GPL-2.0-only**
- ffmpeg — **LGPL-2.1-or-later**, or GPL if the build enables GPL-only codecs
- perl — **Artistic-1.0 or GPL**
- openssl — **Apache-2.0**; sqlite3 — **public domain**; curl — **curl licence**
- OpenSSH — **BSD**; zip — **Info-ZIP**; xz — **public domain**; zstd — **BSD**
- ImageMagick — **ImageMagick licence**

The corresponding source for each program is the Termux recipe and the upstream
release at the version named in the pin
(https://github.com/termux/termux-packages). Keep the pin with the archive: the
archive is only compliant while its exact versions can be rebuilt from those
recipes.

Every archive built by `scripts/runtime_zip.pl` copies
`docs/licenses/runtime/` into `licenses/` at the archive root, because the
runtime is a stripped Termux prefix with no `share/doc` of its own. The notice
there names each component and the text to read.

### 2.16 First-party assets recorded for review

These are JawnOS's own works (BSD-2), listed because they are the assets most
often mistaken for third-party material:

- `public/images/cards/*.png` — the “Deck of Jawn!” tarot deck, hand-drawn in
  pencil crayon and scanned by Jonathan Ferwerda. No third-party deck art is used.
- `public/sounds/alarms/*.mp3` and `public/sounds/notifications/*.mp3` — written
  and recorded by Jonathan Ferwerda.
- `public/js/manager/twirl/*.js` — an original falling-block implementation with
  original art (the brick wall and the house palette). The genre's rules are not
  copyrightable and no Tetris art, palette or naming is used.
- `public/images/make believe/*`, `public/images/decipherable/*`,
  `public/images/jbuttons/*`, `public/images/studio/*`,
  `public/images/palette/*`, `public/images/jonathans/*` — original hand-drawn
  artwork.

### 2.17 Residual notes

- The core runtime (aarch64 0.1.1751) now carries `licenses/`. The optional
  parts (0.1.1750) and the x86_64 archive (0.1.1702) predate the injection and
  will carry it on their next build; the same texts are attached to the release
  as `jawnrt-licenses.tar.gz` until then.
- The three TFT_eSPI smooth fonts are covered by TFT_eSPI's FreeBSD licence, but
  the typefaces they were converted from are not named upstream. If you want to
  remove even that ambiguity, regenerate `Final_Frontier_28` from Montserrat
  (OFL-1.1); the other two are used only by the Unicode test screen.
- `app/dev_keystore.jks` in the app repo is the **debug** signing key, not the
  release key, and `app/build.gradle` uses it for the debug build. It is public
  by design; the release key is `.secrets/jawnos-release.jks` and stays
  gitignored.
- Publishing from a dirty app tree still warns rather than refusing, so commit
  `~/jawnos-app/termux-app` before a publish to keep `sourceCommit` exact.

---

## 3. Dependencies JawnOS does NOT redistribute

The apt / pacman / Termux packages and the CPAN Perl modules listed in
`scripts/jawnos_deps.pl` are **not** bundled or redistributed by JawnOS. They are installed
by the user from their own distribution's repositories (or from CPAN), under those
projects' own licences, and are therefore out of scope for this file. This includes the
command-line tools (Perl, OpenSSL, SQLite, curl, FFmpeg, ImageMagick, Tesseract, SoX,
espeak, …), the desktop extras (WebKitGTK, GStreamer), and the Perl modules
(Mojolicious, Minion, CryptX, …).

The exception is the desktop image built by `desktop/mkosi`: it installs Debian
packages and redistributes them inside the image. Each package carries its own
`/usr/share/doc/<pkg>/copyright` in the image, and the image also carries this
file and `docs/licenses/`. The firmware's PlatformIO-managed libraries (LVGL,
TFT_eSPI, TinyGPS++, tflite-micro, etc.) are fetched by the build rather than
committed here; only the headers and models enumerated in section 2 are
actually redistributed.

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

The three smooth-font headers in 2.6–2.8 are byte-identical to TFT_eSPI's
`Unicode_test` example; re-verify with
`https://github.com/Bodmer/TFT_eSPI/tree/master/examples/Smooth%20Fonts/FLASH_Array/Unicode_test`.
