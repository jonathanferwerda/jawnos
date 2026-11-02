# Runtime parts (video, media, ocr)

The Android runtime used to be one archive. A clean install still unpacks a
pinned **core** archive, and now may also download optional **parts** into the
same `$PREFIX`. The core keeps only what must run before a part is installed;
the parts are separate, independently versioned archives:

* `video` — ffmpeg/ffprobe and their codec/delegate libraries (the largest
  optional payload).
* `media` — ImageMagick and the libraries it links.
* `ocr` — Tesseract, leptonica and English tessdata.

The aarch64 core went from **69,360,792 B** (`0.1.1706`) to **31,311,461 B**
(`0.1.1750`) by moving ffmpeg out. A device that never uses ffmpeg downloads
~38 MB less; installing `video` brings the total back to roughly the old core.

## Manifest (`releases/jawnrt.json`, baked into the APK)

`abi` is the core map old app versions already read. `parts` is new: a map of
ABI -> part name -> descriptor. An old app ignores `parts` and keeps installing
the core exactly as before.

```json
{
  "abi": {
    "aarch64": { "file": "jawnrt-aarch64-0.1.1750.zip", "sha256": "...", "size": 31311461, "version": "0.1.1750" },
    "x86_64":  { "file": "jawnrt-x86_64-0.1.1702.zip",  "sha256": "...", "size": 90070656, "version": "0.1.1702" }
  },
  "parts": {
    "aarch64": {
      "video": {
        "file": "jawnrt-aarch64-video-0.1.1750.zip",
        "sha256": "5ef9fcd4...",
        "size": 38049353,
        "version": "0.1.1750",
        "min_core": "0.1.1750",
        "provides": ["usr/lib/libavcodec.so.62", "usr/lib/libx265.so", "..."],
        "bins": ["bin/ffmpeg", "bin/ffprobe"],
        "optional": true
      },
      "media": { "...": "same fields, jawnrt-aarch64-media-0.1.1750.zip" },
      "ocr":   { "...": "same fields, jawnrt-aarch64-ocr-0.1.1750.zip" }
    },
    "x86_64": {}
  }
}
```

| field | meaning |
| --- | --- |
| `file` | release asset name; download from `https://github.com/jonathanferwerda/jawnos/releases/download/releases/<file>` |
| `sha256` / `size` | verified before unpacking, exactly like the core |
| `version` | the part's own version (a part can move without a core move) |
| `min_core` | oldest core `version` the part runs against; compare with `.jawnrt-version` |
| `provides` | the **exact** paths the archive adds, relative to `files/` (`usr/...`, no globs) |
| `bins` | executables the part unlocks; they ride in the APK as jniLibs, not in the archive |
| `optional` | always `true`; a part failure must never block startup |

Archive format is the same central-directory zip as the core (modes and
symlinks survive). Part archives are built `--no-bin`: the executables are not
inside them.

## Ownership and overlap

* **Core** owns every path in its archive (3044 entries for `0.1.1750`; it no
  longer carries ffmpeg, ffprobe or the codec stack).
* **A part owns exactly its `provides` list** and nothing else. It is packed
  against the pinned core (`--baseline <core.zip>`), so every path the core
  already carries is excluded from the part. A part never writes a core path.
* The parts overlap where their dependencies do: `video` and `media` both carry
  `libaom`, `libx264`, `libx265`, `libdav1d` and `libjxl` (libheif/ImageMagick
  need them too); `media` and `ocr` both carry `libjpeg.so.8`, `libtiff.so`,
  `libopenjp2.so`, `libpng16.so`, `libwebp.so`, `libwebpmux.so` and
  `libxml2.so.16`. The copies are byte-identical (same Termux packages), so
  installing them in any order is idempotent. `provides` remains exact per
  archive; an overlap is not shared ownership.
* Core still carries the boot set only: perl + modules, sqlite3, openssl,
  curl, git, ssh/sshd, coreutils, and their DT_NEEDED closure (40 libraries).
  `lib/libz.so` is kept explicitly (`--keep`) because `video` names the
  unversioned soname while core's own ELFs name `libz.so.1`; the part then
  points at a core path instead of shipping a cross-part link.

## Update, install and rollback order

1. **Core first.** The app installs/updates the core as it already does. A core
   install wipes `$PREFIX`, so every part marker disappears with it.
2. **Then re-apply enabled parts.** Before wiping for a core update, remember
   which parts the person had enabled (app preferences, not `$PREFIX`); after
   the core is in place, install those parts again. A part with
   `min_core > installed core version` is not installed.
3. **Part update:** download, verify sha256/size, unpack additively (overwrite
   files/symlinks in the new archive), then delete only old `provides` paths
   that the new archive no longer lists. Write the new marker last.
4. **Part rollback:** re-install the previous part archive from the release
   (old runtime assets are never deleted by `app_publish.pl`). Its `provides`
   replace the newer set; no core path is touched.
5. A failed part download/unpack deletes nothing and leaves the old marker in
   place; it is retried on the next start or when the person asks.

## App-side (Java) contract

`JawnRuntime` keeps reading `abi[abiName]` and the `.jawnrt-version` marker.
For parts:

* `parts[abiName][name]` may be absent -> the part is not offered for this
  device. `parts` may be absent entirely -> an older APK; do not try to parse.
* Download `BASE + descriptor.file`, check `size` and `sha256`, then unpack
  **additively** into `$PREFIX` (reuse the existing zip unpack, which overwrites
  a file and replaces a symlink; do not delete the prefix first).
* Per-part marker: `$PREFIX/.jawnrt-part-<name>` with
  `version=<version>\nsha256=<sha256>\npath=<each provides entry>\n`
  (atomic temp+rename, same as `.jawnrt-version`). The `path=` lines are the
  old `provides` set used to clean up on the next update.
* Delete a path only when it appears in the **old** part marker, is absent from
  the **new** `provides`, and is not a core path. Resolve every `provides`
  entry under `files/` (so `usr/lib/x` is `$PREFIX/lib/x`); never delete
  outside `files/`; never delete a path the core archive provides.
* Markers live in `$PREFIX` and therefore reset with a core reinstall; the
  enabled-part list lives in app preferences and drives re-installation.
* Executables: `bin/ffmpeg`, `bin/ffprobe`, `bin/magick` and `bin/tesseract`
  are **not** in the part archives. They ride in the APK as `libbin_*.so`
  (jniLibs) and are linked at start by `JawnRuntimeBins`, whose
  `assets/runtime-bins.txt` stays three tab-separated fields.
  `assets/runtime-bins-parts.txt` (optional, written by
  `scripts/app_build.pl`) maps `part<TAB>path<TAB>kind` if the updater wants to
  gate link creation on the part being installed. Creating the links before the
  part exists is harmless: the executable only fails once executed, and its
  libraries/data arrive with the part.
* `optional: true` is a hard rule: no part download or unpack may prevent the
  core tree from starting.

## Building the core and the parts

Termux aarch64 packages (index:
`https://packages.termux.dev/apt/termux-main/dists/stable/main/binary-aarch64/Packages.gz`)
are extracted into a normal prefix, then packed against the pinned core. The
core itself is rebuilt from the previous core archive with its executables
restored into `bin/` from `releases/native-bins/` (the archive is `--no-bin`):

```sh
# core: previous core + its jniLib executables in a staging prefix
unzip -q releases/jawnrt-aarch64-0.1.1706.zip -d /tmp/rtp/coreprefix
# restore every runtime-bins.txt entry into /tmp/rtp/coreprefix (file -> copy
# releases/native-bins/<abi>/lib<slug>.so, link -> relative symlink)
perl scripts/runtime_build.pl --from /tmp/rtp/coreprefix --part core \
  --keep lib/libz.so --abi aarch64 --version 0.1.1750 --no-bin

# parts: the same prefix rewrite the core uses (both paths are equal length)
RW=/data/data/com.termux/files/usr=/data/data/com.jawnos/files/usr
perl scripts/runtime_build.pl --from /tmp/rtp/coreprefix --part video \
  --baseline releases/jawnrt-aarch64-0.1.1750.zip --abi aarch64 \
  --version 0.1.1750 --min-core 0.1.1750 --rewrite-prefix "$RW" --no-bin
perl scripts/runtime_build.pl --from /tmp/rtp/prefix --part media \
  --baseline releases/jawnrt-aarch64-0.1.1750.zip --abi aarch64 \
  --version 0.1.1750 --min-core 0.1.1750 --rewrite-prefix "$RW" --no-bin
perl scripts/runtime_build.pl --from /tmp/rtp/prefix --part ocr \
  --baseline releases/jawnrt-aarch64-0.1.1750.zip --abi aarch64 \
  --version 0.1.1750 --min-core 0.1.1750 --rewrite-prefix "$RW" --no-bin
```

`--part core` (the default) is the boot runtime; it has no `--baseline`.
`--list` shows the selection without writing. `--keep` forces an exact path the
closure cannot infer (here the `lib/libz.so` alias). The `.zip.json` written
beside an archive carries the same `provides` set.

To refresh the APK's jniLibs, build the same parts **without** `--no-bin`, feed
all archives to the merged converter, and merge the result with the existing
core manifest:

```sh
RW=/data/data/com.termux/files/usr=/data/data/com.jawnos/files/usr
perl scripts/runtime_build.pl --from /tmp/rtp/coreprefix --part video --baseline ... \
  --abi aarch64 --min-core 0.1.1750 --rewrite-prefix "$RW" --out /tmp/video-full.zip
perl scripts/runtime_build.pl --from /tmp/rtp/prefix --part media --baseline ... \
  --abi aarch64 --min-core 0.1.1750 --rewrite-prefix "$RW" --out /tmp/media-full.zip
perl scripts/runtime_build.pl --from /tmp/rtp/prefix --part ocr --baseline ... \
  --abi aarch64 --min-core 0.1.1750 --rewrite-prefix "$RW" --out /tmp/ocr-full.zip
perl scripts/runtime_native_bins.pl --zip video=/tmp/video-full.zip \
  --zip media=/tmp/media-full.zip --zip ocr=/tmp/ocr-full.zip \
  --out /tmp/native-parts --abi arm64-v8a
# copy /tmp/native-parts/arm64-v8a/*.so into releases/native-bins/<abi>/ and
# merge its runtime-bins.txt / runtime-bins-parts.txt with the core one
```

`app_publish.pl` uploads every part named by the pin that is staged and
matching. A missing or mismatched part is reported and skipped; it never fails
the APK or core publish.

## What shipped, and what was pruned

Measured on 2026-11-01 (aarch64, Termux `stable`, `--no-bin`):

| archive | version | compressed | uncompressed | files |
| --- | --- | --- | --- | --- |
| core (old, kept for older APKs) | 0.1.1706 | 69,360,792 B | 185 MB | 3146 |
| **core (new)** | 0.1.1750 | **31,311,461 B** | 94.8 MB | 3044 |
| video | 0.1.1750 | **37,957,201 B** | 81.7 MB | 99 |
| media | 0.1.1750 | **27,838,364 B** | 69.5 MB | 104 |
| ocr | 0.1.1750 | **16,151,930 B** | 33.7 MB | 50 |

The core shrank by 38,049,331 B. Installing core+video is 69,268,662 B — about
the old core alone. A device that never uses ffmpeg keeps the gain.

Moved from core to `video`: ffmpeg/ffprobe, libavcodec/avformat/avfilter/
avutil/avdevice/swscale/swresample, x264/x265, aom, rav1e, SvtAv1, dav1d, vpx,
ass, bluray/dvd*, glslang + OpenCL/placebo, openmpt, mp3lame/mpg123,
opus/vorbis/ogg, theora, vidstab/vmaf, samplerate/soxr/rubberband, srt/ssh,
zimg/zmq and their transitive delegates. Nothing that must run before a part
is installed names them, so they leave the boot set entirely.

**The Vulkan loader is the device's.** Termux's `libvulkan.so.1.4.363` needs
vendor HIDL libraries (`android.hardware.configstore@1.0.so`, `libgfxgrab.so`)
that an app's linker namespace does not expose on Android 13+; with it in the
prefix, `ffmpeg -version` died with `CANNOT LINK EXECUTABLE`. The closure now
leaves `libvulkan.so` to `/system/lib64`, where `libplacebo` finds it. Remove
any prefix copy if a rebuild reintroduces it.

Rebuilt because the core no longer supplies their dependencies: `media` now
carries fontconfig/freetype/glib/harfbuzz/png/webp/xml2/lcms/fftw3/jxl/heif's
owners and the codec libs its libheif/libjxl names; `ocr` carries libpng,
libwebp(+mux/sharpyuv), libxml2 and libc++_shared. `video` and `media` now share
libaom/x264/x265/dav1d/jxl; `media` and `ocr` share jpeg/tiff/openjp2/png/webp/
xml2. All overlap is byte-identical.

Pruned from the three parts' Termux packages because no DT_NEEDED chain and no
coder needs them: `include/`, `share/doc`, `share/man`, `lib/pkgconfig`, the
`Magick*-config` scripts, Magick++ (no shipped binary links it), all Tesseract
training binaries (`classifier_tester`, `combine_lang_model`, `lstmtraining`,
...) and training libraries, ghostscript's data/fonts (only `libgs.so.10` is
linked), and font files (the ImageMagick type XML is kept; `ttf-dejavu` as a
package is not). `libgs`, pango/cairo, gdk-pixbuf, librsvg, graphviz (`libgvc`),
OpenEXR, libraw, libheif and djvulibre **are** shipped in `media`:
`libMagickCore` names them in its DT_NEEDED, so the loader requires them.

`tesseract-data` is not a separate Termux package; `tesseract_5.5.4` ships
`share/tessdata/eng.traineddata` (23,466,654 B) and the config files, and the
`ocr` part carries them. `osd.traineddata` is not included.

## Verification limits

The build host is x86_64 with no aarch64 loader, so the staged binaries cannot
be executed here. Static verification performed: every ELF in the core and in
all three part archives has its DT_NEEDED chain satisfied by that archive plus
the pinned core (or Android system libraries), no symlink dangles inside an
installed core+part set, no part carries a core path, and no
`/data/data/com.termux` string remains in any archive. `RegisterTIFFImage`,
`RegisterXCFImage`, `RegisterPNGImage` and `RegisterJPEGImage` are compiled into
`libMagickCore`, `eng.traineddata` is present, and the version strings in the
libraries are `ImageMagick 7.1.2-35` and `tesseract 5.5.4`. On a device, still
run `ffmpeg -version`, `ffprobe -version`, `tesseract --version`,
`tesseract --list-langs`, `magick -version`, `magick in.tiff out.png` and
`magick in.xcf out.png`.
