# Screenshot gallery

One command captures the JawnOS UI from the demo VM on the table and rebuilds
the `#screenshots` wall on jawnos.ca.

```sh
scripts/gallery/run.sh --boot --sync --all --deploy-both   # from a cold table
scripts/gallery/run.sh --all --sync            # update the guest, reseed, capture, publish
scripts/gallery/run.sh                         # capture + publish only
scripts/gallery/run.sh --shoot --only 14-clock # one scene, for a quick check
scripts/gallery/run.sh --publish --deploy      # publish and upload to Cloudflare Pages
scripts/gallery/run.sh --publish --deploy-50webs
scripts/gallery/run.sh --publish --deploy-both
```

## What it touches

```
table.jonathanferwerda.com (SSH 8022)
  qemu-system-x86_64  JawnOS-Demo     <- the live USB image, KVM, headless
    sshd 127.0.0.1:2222               <- the table relays; the guest sees its own loopback
      https://127.0.0.1:45545/manager <- the manager the capture drives
```

`run.sh` opens two SSH forwards (laptop -> table -> guest sshd -> guest
loopback). The guest manager sees a loopback caller, so the app gate is off.
No ticket is exposed beyond the two loopbacks, and the table host's own
`~/jawnos/database/jawnos.db` is never opened.

The guest's loopback session is a **resident**. The shoot phase mints a
**citizen** ticket with `scripts/app_ticket.pl gallery`, consumes it through the
same tunnel, and passes the session cookie to headless Chromium. That is what
makes the citizen-only apps (People) render; without it they are empty.

## Stages

- `--boot` — copies `vm_boot.sh` to the table and starts QEMU if it is not
  already running, then waits for the guest's sshd on port 2222. The image must
  be the prepared demo image (`/etc/jawnos-demo-image`, sshd, tty1 autologin);
  `table_prepare_demo.sh` is the one-time preparation.
- `--sync` — `git reset --hard origin/main` in the guest's `~/jawnos`, then
  restart the tree. Use it whenever the UI has moved since the image was built.
  The guest's database and `config.json` are gitignored and survive.
- `--seed` — builds `.shots/demo.db` from `.shots/seed.db`, copies it to the
  guest, and runs `demo_extra_seed.py` + `gallery_seed.py` there. The seed
  refuses unless the guest carries `/etc/jawnos-demo-image`.
- `--shoot` — `capture.mjs` drives CDP at 1920x1080, one scene per entry in
  `scenes.json`, and records each window's real rectangle in `rects.json`.
  Output is `.shots/scenes-live/`.
- `--publish` — `publish.py` crops each window, writes `assets/gallery/*.webp`
  (full + `-thumb`), rewrites the `gallery:generated` block in the site's
  `index.html`, drops stale WebPs, and stages `dist/` with `build_pages.sh`.
- `--deploy` / `--deploy-50webs` / `--deploy-both` — upload `dist/` to
  Cloudflare Pages (`pages.env`) and/or the 50webs host (`deploy.env`).

Nothing is written to the site until every included scene has a usable PNG, so
a partial capture cannot blank the live gallery. A failed included scene makes
`capture.mjs` exit non-zero and `run.sh` stop before publishing.

## First-time inputs

The repo does not carry these (they are gitignored or media):

| Path | What it is |
| --- | --- |
| `.shots/seed.db` | a pristine schema+settings database from the live image, no personal rows |
| `~/Pictures/{T-Watch,T-Deck,Studio,Plein Air,Portraits}` in the guest | album photos; `scripts/gallery/seed/media.sh` generates and copies them |
| `~/Pictures/{travel,Backgrounds}` in the guest | map art and wallpapers for the layout scenes |
| `scripts/gallery/scenes.json` | scenes, crops, and the site's copy |

`media.sh` needs ImageMagick and ffmpeg:

```sh
scripts/gallery/seed/media.sh              # generate and copy to the guest
scripts/gallery/seed/media.sh --stage-only # only fill .shots/demo_media
```

## Looking at the result

Do not open a capture PNG (~0.2–2.7 MB) in the agent or the editor; its base64
is what triggers `413 payload too large`. Build a small contact sheet first:

```sh
magick montage ../jawnos-website/assets/gallery/*-thumb.webp \
  -tile 4x -geometry 240x135+4+4 -quality 78 /tmp/gallery-sheet.jpg
```

Then open the sheet. The full-size files are for the browser, not for review.

## A scene that will not open

`scenes.json` entries have a `kind`:

- `app` — `openApp` calls the app's own opener, then records the window rect.
- `composite` — several `windows` with fixed rects; used for the lead shot.
- `layout` — sets the desktop layout/theme and calls no app.
- `start-menu` — opens two apps to populate Recents, then opens the menu.

An app that needs a citizen session (People) gets 45 s. Other apps get 12 s.
If a scene still fails, run it alone (`--shoot --only 08-people`) and check the
manager log in the guest (`~/manager.log`).

## Android screenshots

The Android app (`~/jawnos-app/termux-app`) runs the same tree on a phone. The
capture host is the table's x86_64 emulator:

```
table.jonathanferwerda.com (SSH 8022)
  ~/android-sdk                    SDK + emulator
  ~/.android/avd/jawnos.avd        AVD (android-36, x86_64, 1080x2400)
    com.termux (jawnos-x86.apk)    the app; tree at files/home/jawnos
```

Start it headless with
`~/android-sdk/emulator/emulator -avd jawnos -no-window -no-audio -no-boot-anim
-gpu swiftshader_indirect -memory 3072 -cores 4 -no-snapshot`, then `adb root`
and `adb shell settings put global settings_enable_monitor_phantom_procs false`
(the emulator kills the Perl workers as "phantom processes" otherwise). `jawn`
also now falls back to `~/.president` when `/tmp` exists but is not writable,
which is the case on this emulator.

Dependencies: the app's first launch runs
`perl scripts/jawnos_deps.pl --install`. On this emulator `IO::Pty` fails
cpanm's configure once; build it by hand from the cached `IO-Tty-*` directory,
then install `Mojo::IOLoop::ReadWriteFork`.

Seed the phone-side demo database:

```sh
scripts/gallery/seed/media.sh --stage-only
python3 scripts/gallery/seed/phone_seed.py \
  --home /data/data/com.termux/files/home
```

`phone_seed.py` runs the extra and gallery seeds, gives each album an app-named
copy (`Pictures/plein_air`, etc.) with its `.thumbs`, and points every row at
the phone's own home. Push `Pictures`, `Music` and `Documents` from
`.shots/demo_media` plus `.shots/phone-demo.db` into the app tree. The emulator's
app cannot read `/sdcard`; exchange files through `/data/local/tmp`, which
`run-as com.termux` can read. Copy the database over
`database/jawnos.db` while jawn is stopped, and set `"live": true` in
`config.json` so the app's own loopback opens the manager without a ticket (the
demo database's vault canary does not match this emulator's key). Restart from
the admin panel (`JawnDashboardActivity`): Stop, copy the database, Start.

Capture: `--es app <name>` opens the manager and then the app's own window. Use
`--activity-clear-task`, or Android just redelivers the intent to the last
instance:

```sh
adb shell am start -n com.termux/com.termux.app.JawnAppActivity \
  --activity-clear-task --es app gallery
adb shell screencap -p /sdcard/android-gallery.png
```

The native home is `JawnHomeActivity`, the admin panel is
`JawnDashboardActivity`. `scripts/gallery/android.sh --shoot` captures the
home, gallery, music, synth, handbook, accounting, travel and clock screens.
Accounting opens with `--es app budget` (the window's start-menu icon is
`#budget`); the app named `account` is an ordinary app and falls back to an
appointment window.

Publish: `scripts/gallery/android.sh --publish` writes
`assets/gallery/android-*.webp` and rewrites the `android:generated` block in
the site's `index.html`; add `--deploy` to upload. The site keeps the
screenshots **high-definition**: the full image is the capture's native width
(1080x2400, quality 94) and the wall thumb is 420 px tall (quality 82).

**When an agent needs to look at a capture, do not open the PNG** (a 1080x2400
screenshot is 0.3-0.7 MB and its base64 is larger still; that is what a
`413 payload too large` is made of). Downscale to a small WebP first:

```sh
magick in.png -resize 360x -quality 80 /tmp/small.webp   # then read /tmp/small.webp
magick montage *.png -tile 4x2 -geometry 270x600+6+6 -quality 78 sheet.webp
```

That rule is for the agent's own eyes only - never publish those downscaled
copies.

Known app bug (0.118.158): `JawnAppActivity.injectApp` looks up the start-menu
icon by `id`, but several icons are class-only (`warehouse_toggle`,
`account_toggle`, `weather_toggle`), so those apps fall back to a plain
appointment window. Apps whose icons carry an id (gallery, studio, clock, email,
mailbox, handbook, folders, music, notes) open normally. Fix: look up
`#' + app + '_toggle, .' + app + '_toggle'` and rebuild the APK.
