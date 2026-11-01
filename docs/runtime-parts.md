# Runtime parts (media, ocr)

The Android runtime used to be one archive. A clean install still unpacks a
pinned **core** archive, and now may also download optional **parts** into the
same `$PREFIX`. The core is unchanged in shape and in download; the parts are
separate, independently versioned archives that add ImageMagick (`media`) and
Tesseract with English tessdata (`ocr`).

The goal is a tablet that does not have to download one ~69 MB archive to get
`magick` or `tesseract`, and an image/OCR feature a person can add later.

## Manifest (`releases/jawnrt.json`, baked into the APK)

`abi` is the core map old app versions already read. `parts` is new: a map of
ABI -> part name -> descriptor. An old app ignores `parts` and keeps installing
the core exactly as before.

```json
{
  "abi": {
    "aarch64": { "file": "jawnrt-aarch64-0.1.1706.zip", "sha256": "...", "size": 69360792, "version": "0.1.1706" },
    "x86_64":  { "file": "jawnrt-x86_64-0.1.1702.zip",  "sha256": "...", "size": 90070656, "version": "0.1.1702" }
  },
  "parts": {
    "aarch64": {
      "media": {
        "file": "jawnrt-aarch64-media-0.1.1741.zip",
        "sha256": "7796c105...",
        "size": 14700113,
        "version": "0.1.1741",
        "min_core": "0.1.1706",
        "provides": ["usr/etc/ImageMagick-7/colors.xml", "usr/lib/libMagickCore-7.Q16HDRI.so", "..."],
        "bins": ["bin/magick", "bin/convert"],
        "optional": true
      },
      "ocr": { "...": "same fields, file jawnrt-aarch64-ocr-0.1.1741.zip" }
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

* **Core** owns every path in its archive (3145 entries for `0.1.1706`).
* **A part owns exactly its `provides` list** and nothing else. It is packed
  against the pinned core (`--baseline <core.zip>`), so every path the core
  already carries is excluded from the part. A part never writes a core path.
* `media` and `ocr` overlap on the delegate libraries both link against
  (`libjpeg.so.8`, `libtiff.so`, `libopenjp2.so`). Those files are byte-identical
  in both parts (same Termux packages), so installing both is idempotent.
  `provides` remains exact per archive; an overlap is not shared ownership.
* Data and delegate libraries the core already has (fontconfig, freetype, glib,
  harfbuzz, libpng, libwebp, libxml2, lcms, zlib, zstd, lzma, bz2, libjxl,
  fftw3) are not carried by either part.

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
* Executables: `bin/magick` / `bin/tesseract` are **not** in the part archives.
  They ride in the APK as `libbin_magick.so` / `libbin_tesseract.so` (jniLibs)
  and are linked at start by `JawnRuntimeBins`, whose `assets/runtime-bins.txt`
  stays three tab-separated fields. `assets/runtime-bins-parts.txt` (optional,
  written by `scripts/app_build.pl`) maps `part<TAB>path<TAB>kind` if the
  updater wants to gate link creation on the part being installed. Creating the
  links before the part exists is harmless: the executable only fails once
  executed, and its libraries/data arrive with the part.
* `optional: true` is a hard rule: no part download or unpack may prevent the
  core tree from starting.

## Building a part

Termux aarch64 packages (index:
`https://packages.termux.dev/apt/termux-main/dists/stable/main/binary-aarch64/Packages.gz`)
are extracted into a normal prefix, then packed against the pinned core:

```sh
# after extracting imagemagick, tesseract and their Depends into /tmp/rtp/prefix
# (the prefix rewrite is the same one the core build uses; both paths are
# equal length, so no ELF offset moves)
RW=/data/data/com.termux/files/usr=/data/data/com.jawnos/files/usr
perl scripts/runtime_build.pl --from /tmp/rtp/prefix --part media \
  --baseline releases/jawnrt-aarch64-0.1.1706.zip --abi aarch64 \
  --min-core 0.1.1706 --rewrite-prefix "$RW" --no-bin

perl scripts/runtime_build.pl --from /tmp/rtp/prefix --part ocr \
  --baseline releases/jawnrt-aarch64-0.1.1706.zip --abi aarch64 \
  --min-core 0.1.1706 --rewrite-prefix "$RW" --no-bin
```

`--part core` (the default) is the old behaviour. `--list` shows the selection
without writing. The `.zip.json` written beside an archive carries the same
`provides` set.

To refresh the APK's jniLibs, build the same parts **without** `--no-bin`, feed
all archives to the merged converter, and merge the result with the existing
core manifest:

```sh
RW=/data/data/com.termux/files/usr=/data/data/com.jawnos/files/usr
perl scripts/runtime_build.pl --from /tmp/rtp/prefix --part media --baseline ... \
  --abi aarch64 --min-core 0.1.1706 --rewrite-prefix "$RW" --out /tmp/media-full.zip
perl scripts/runtime_build.pl --from /tmp/rtp/prefix --part ocr   --baseline ... \
  --abi aarch64 --min-core 0.1.1706 --rewrite-prefix "$RW" --out /tmp/ocr-full.zip
perl scripts/runtime_native_bins.pl --zip media=/tmp/media-full.zip \
  --zip ocr=/tmp/ocr-full.zip --out /tmp/native-parts --abi arm64-v8a
# copy /tmp/native-parts/arm64-v8a/*.so into releases/native-bins/<abi>/ and
# merge its runtime-bins.txt / runtime-bins-parts.txt with the core one
```

`app_publish.pl` uploads every part named by the pin that is staged and
matching. A missing or mismatched part is reported and skipped; it never fails
the APK or core publish.

## What shipped, and what was pruned

Measured on 2026-11-01 (aarch64, Termux `stable`, `--no-bin`):

| part | version | compressed | uncompressed | files |
| --- | --- | --- | --- | --- |
| core (pin, unchanged) | 0.1.1706 | 69,360,792 B | 368 MB | 3145 |
| media | 0.1.1741 | 14,700,113 B | 39.6 MB | 71 |
| ocr | 0.1.1741 | 14,796,519 B | 30.7 MB | 43 |

Pruned from the Termux packages because no DT_NEEDED chain and no coder needs
them: `include/`, `share/doc`, `share/man`, `lib/pkgconfig`, the `Magick*-config`
scripts, Magick++ (no shipped binary links it), all Tesseract training binaries
(`classifier_tester`, `combine_lang_model`, `lstmtraining`, ...) and training
libraries, ghostscript's data/fonts (only `libgs.so.10` is linked), and font
files (the ImageMagick type XML is kept; `ttf-dejavu` as a package is not).
`libgs`, pango/cairo, gdk-pixbuf, librsvg, graphviz (`libgvc`), OpenEXR, libraw,
libheif and djvulibre **are** shipped: `libMagickCore` names them in its
DT_NEEDED, so the loader requires them.

`tesseract-data` is not a separate Termux package; `tesseract_5.5.4` ships
`share/tessdata/eng.traineddata` (23,466,654 B) and the config files, and the
`ocr` part carries them. `osd.traineddata` is not included.

## Verification limits

The build host is x86_64 with no aarch64 loader, so the staged binaries cannot
be executed here. Static verification performed: every ELF in both published
archives has its DT_NEEDED chain satisfied by the part plus the pinned core
(or Android system libraries), no symlink dangles, `RegisterTIFFImage`,
`RegisterXCFImage`, `RegisterPNGImage` and `RegisterJPEGImage` are compiled into
`libMagickCore`, `eng.traineddata` is present, and the version strings in the
libraries are `ImageMagick 7.1.2-35` and `tesseract 5.5.4`. On a device, still
run `tesseract --version`, `tesseract --list-langs`, `magick -version`,
`magick in.tiff out.png` and `magick in.xcf out.png`.
