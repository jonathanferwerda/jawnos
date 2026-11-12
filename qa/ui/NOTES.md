# Opening probe

`open_probe.js` is the tile's regression check: it signs in with a ticket, clears
the desk, then opens a row of apps through `appWindowOpener` (the function the
start menu calls) and reads back the `tile` slot each window took. A `--reload`
in the app list reloads the page after the 10s heartbeat has saved the layout,
so the restore path is exercised before the remaining apps open.

```sh
node qa/ui/open_probe.js .shots/ticket.txt notes,clock,weather,power,sound,network,help
node qa/ui/open_probe.js .shots/ticket.txt notes,clock,--reload,power,sound
```

The ticket file holds the full `https://127.0.0.1:3000/box_office/...` URL. The
probe exits non-zero on a duplicate slot, a missing slot, a window that never
opened, or a page exception; it closes what it opened so the desk is clean.
`OPEN_PROBE_PORT`, `CHROMIUM` and `OPEN_PROBE_SETTLE` override its port, browser
and per-open wait. It is a regression probe, not part of the nightly sweep.

# Qt WebEngine probe — the real-engine check

`webkit_probe.py` loads the QA manager in **Qt WebEngine** (PySide6), the
engine the desktop app uses. The file keeps its old name so the QA commands,
`Ui.pm` and `t/64` keep working; the engine value in the report is
`qtwebengine`.

The QA instance serves HTTPS with a self-signed certificate, so the probe has
to accept that certificate before the page will load. Qt exposes it through the
page's `certificateError` signal; the handler accepts only an overridable
certificate (the house's own), and Qt then retries the load itself. The old
WebKit reload dance, with its host-keyed `allow_tls_certificate_for_host` and
delayed reload, is gone with the view it belonged to.

## The report

The probe writes the same JSON keys the harness already judges: `title`, `url`,
`hasMenu`, `buttons`, `unlabeled`, `inputs`, `unlabeledInputs`, `imgsNoAlt`,
`smallTargets`, `overflow`, `nodes`, `budgetLight`, plus `engine`, `load`,
`errors` and `events`. It also grabs a PNG of the page to
`<outdir>/shots/<page>.png` and names it in `screenshot`, beside the Chromium
probe's screenshots.

A timeout carries a `reason` and the last ten signals (`events`), which `Ui.pm`
folds into one line, so the next failure names itself.

## Per-run profile

Qt WebEngine keeps its profile under `XDG_DATA_HOME`/`XDG_CACHE_HOME`, and a
service worker or cookie from one run can follow the next onto the same
loopback origin. `Ui.pm` points those variables at a fresh
`results/ui/qtwebengine-profile/` per run — the same isolation Chromium gets
from `--user-data-dir=results/ui/chrome`.

## Validate

```sh
perl qa/run.pl --layers l3
```

Expect no `warn qtwebengine`, and `results/ui/qtwebengine.json` with the real
`https://127.0.0.1:<port>/manager` URL and `"hasMenu": true`. The probe needs
`xvfb-run` and `python3` with **PySide6 Qt WebEngine**. It sets
`QT_QPA_PLATFORMTHEME=generic` so a GTK desktop cannot pull `libgtk` into the
probe process.
