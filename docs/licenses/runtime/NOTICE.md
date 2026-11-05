# Runtime archive notices

This directory is copied into every `jawnrt-*.zip` under `licenses/` by
`scripts/runtime_zip.pl`, so a device that downloads a runtime has the notices
with it (the runtime is a stripped Termux prefix and carries no `share/doc` of
its own).

The archive is an aggregate of separate programs built from Termux recipes
(https://github.com/termux/termux-packages). The versions in a given archive
are the ones pinned in the app's `assets/jawnrt.json`; the build pins the same
versions in `releases/`. Each program keeps its own licence; its corresponding
source is the Termux recipe and the upstream release at that version.

| Component | Licence | Text here |
| --- | --- | --- |
| bash, coreutils, findutils, sed, grep, gawk, rsync | GPL-3.0 | `GPL-3.0.txt` |
| git | GPL-2.0-only | `GPL-2.0.txt` |
| ffmpeg | LGPL-2.1-or-later (GPL if GPL-only codecs are enabled) | `LGPL-2.1.txt` |
| perl | Artistic-1.0 or GPL | `Artistic-1.0.txt`, `GPL-3.0.txt` |
| openssl | Apache-2.0 | `Apache-2.0.txt` |
| curl | curl licence | `curl.txt` |
| OpenSSH, zstd | BSD | `BSD-2-Clause.txt`, `BSD-3-Clause.txt` |
| zip | Info-ZIP | `Info-ZIP.txt` |
| ImageMagick | ImageMagick licence | `ImageMagick.txt` |
| sqlite3, xz | public domain | — |
| other Termux packages | per package | see the recipe |

The archive also contains other programs from the Termux prefix. Their recipe
at the pinned version is the authoritative licence and source: if a package is
not named above, look it up there.

**Source:** https://github.com/termux/termux-packages. The exact version of
each package is the one recorded in the app's `assets/jawnrt.json` (and in the
build's `releases/jawnrt.json`), so the recipe at that version is the
Corresponding Source.
