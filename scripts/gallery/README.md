# Screenshot gallery

One command captures the JawnOS UI from the demo VM on the table and rebuilds
the `#screenshots` wall on jawnos.ca.

```sh
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
| `~/Pictures/{Maps,Backgrounds}` in the guest | map art and wallpapers for the layout scenes |
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
