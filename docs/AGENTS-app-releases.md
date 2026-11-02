# App releases (the APK store)

Moved out of `AGENTS.md` (a per-task reference, not an every-request map).

## App releases (the APK store)

- Built JawnOS Android APKs live in **`releases/`** at the repo root (gitignored: a ~35 MB binary per
  version would bloat git history forever, so the file rides the mesh as a **blob, not through git**).
  Names: `releases/jawnos-<product>-<versionCode>-<versionName>.apk` (`product` = `app` | `api`).
- **Stage a build:** `perl scripts/app_release.pl <apk>` reads its `versionCode`/`versionName` (via
  `aapt`) and copies it in, replacing older builds of the same product. It prints a note when a build
  does not out-number the staged one (devices would not see an update).
- **Build the next one:** `perl scripts/app_build.pl` bumps the app repo's versionCode and the
  versionName patch, builds the debug APK and stages it — so the next release is always the current
  number + 1 (1258 shipped; the next is 1259). `--no-build` stops after the bump.
- **Publish it (don't skip this):** `perl scripts/app_publish.pl` (needs an authenticated `gh`) uploads
  the newest staged APK **and** a matching `app_release.json` manifest to the GitHub `releases`
  release, so a device can pull it from github.com as well as from a peer. **A build that is only
  staged never reaches GitHub** — peers carry it, but a device reading the GitHub manifest sees the old
  versionCode and stays "up to date". Always build **and** publish.
- **Runtime zips ride the same release.** `scripts/runtime_build.pl` assembles the Perl runtime the APK
  unpacks on first run (`jawnrt-<arch>-<version>.zip` for the core, `jawnrt-<arch>-<part>-<version>.zip`
  for the optional parts such as `video`, `media`, `ocr`), and `app_publish.pl` uploads one when the
  GitHub release is missing it (or all of them with `--runtime`; `--no-runtime` skips). `releases/`
  holds the APK, those zips, and `native-bins` (the executables the app supplies as jniLibs).
- **The app repo has its own guide:** `~/jawnos-app/termux-app/AGENTS.md` — every change to the APK
  bumps `versionCode` and is published. Keep this section and that file in step.
- **Who serves it:** every jawn serves `GET /manager/app_release` (JSON: versions + sha256) and
  `GET /manager/app_download?product=app` (the bytes), `signatorial`-gated like `self_deploy`.
- **Who carries it:** `subs::app_release_sync()` (a 5-min loop in `President.pl`) reads local
  `releases/`, asks each reachable peer, and pulls the newest APK in (temp → sha256 → rename). Every
  device ends up holding the newest and can serve it.
- **Who installs it:** the Android app (`~/jawnos-app/termux-app`, branch `jawnos`, remote `fork`) reads
  the staged APK and offers a one-tap "Update app". Bump `versionCode` in `app/build.gradle` per release.
- The whole path is "whoever has the newest is the authority" — no fixed server. The desktop app has no
  such store: it is a copy of `desktop/`, so it follows the code sync.
- **table builds both artefacts itself** (2026-11-01): mkosi + a full jdk17-openjdk are installed there.
  `qa/nightly_build.sh` builds the QEMU image and then `assembleDebug`, unattended, under
  `jawnos-qa-build.timer` (Sun 03:00 — a cold image build is 20-40 min, so not nightly). Both are dev
  builds: no versionCode bump, nothing staged into `releases/`.
