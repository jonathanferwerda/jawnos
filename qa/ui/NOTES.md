# WebKitGTK probe — why it failed and what the fence check found

`webkit_probe.py` loads the QA manager in WebKitGTK 4.1, the desktop's fallback
engine. The default Qt WebEngine view is not driven by this probe yet; it has
its own `--probe` in `desktop/jawnos-qt` (t/185). The QA instance serves HTTPS
with a self-signed certificate, so the
probe has to allow that certificate before the page will load.

## The bug (fixed)

`load-failed-with-tls-errors` was handled twice wrong:

1. `allow_tls_certificate_for_host(certificate, failing_uri)` passed the **URI**
   (`https://127.0.0.1:21000/manager`). The API takes a **host**
   (`127.0.0.1`); the exception was stored under a key the next request never
   matched, so the reload failed identically.
2. The reload was scheduled with `GLib.idle_add` from inside the handler. The
   reload cancelled the load that was still unwinding, which fired
   `load-failed` / `Operation was cancelled`, re-entered the TLS handler, and
   after a few loops left the view on `about:blank` — reported as
   `hasMenu: false`, or on a slower boot as a bare `timeout`.

Observed before the fix on the table host, against the real QA instance:

```
{"hasMenu": false, "url": "about:blank", "nodes": 3, "load": "finished",
 "errors": ["Operation was cancelled (https://127.0.0.1:21000/manager)"]}
```

The fix parses the host out of the failing URI, allows the certificate for that
host only, reloads 150 ms after the handler returns, and caps the retries at
three. `load-failed` for the cancellation the reload causes is not an error.
A timeout now carries a `reason` and the last ten signals (`events`), which
`Ui.pm` folds into one line, so the next failure names itself.

## The second bug: a shared WebKit profile

Fixing TLS exposed a run-to-run failure of its own. WebKit keys its profile by
program name under `XDG_DATA_HOME` and keeps **service-worker registrations**
there (`~/.local/share/webkit_probe.py/serviceworkers/…`). The QA tree always
answers on the same loopback origin (`https://127.0.0.1:21000`), so the second
run resurrected the first run's service worker; its pass-through
`respondWith(fetch(request))` then failed and the manager landed on about:blank:

```
errors: ["FetchEvent.respondWith received an error: TypeError: Load failed …"]
```

`Ui.pm` now points `XDG_DATA_HOME`/`XDG_CACHE_HOME`/`XDG_CONFIG_HOME` at a fresh
`results/ui/webkit-profile/` per run — the same isolation Chromium already gets
from `--user-data-dir=results/ui/chrome` — so no state crosses a run boundary.

## What the bisect ruled out

Run on the table host under the same wrapper
(`xvfb-run -a -s '-screen 0 1280x900x24' …`):

| step | result |
| --- | --- |
| plain `http://127.0.0.1:<port>/` by `python3 -m http.server`, outside the fence | loads, `hasMenu: true` |
| the same page inside `unshare --user --map-root-user --mount --pid --fork --mount-proc --net` | loads, `hasMenu: true` |
| self-signed HTTPS, outside the fence | failed with the bug above |
| self-signed HTTPS, host parsed + delayed reload | loads, `hasMenu: true`, no errors |

So the user/PID/net namespaces, the loopback interface, and
`WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` are all fine: the web and network
processes start inside the fence and can reach the QA tree on loopback. The
failure was the certificate exception, not the sandbox or the instance.

## Validate

```sh
perl qa/run.pl --layers l3
```

Expect no `warn webkit`, and `results/ui/webkit.json` with the real
`https://127.0.0.1:<port>/manager` URL and `"hasMenu": true`. The probe needs
`xvfb-run` (Arch: `xorg-server-xvfb`) and `python3` with
`gi`/`WebKit2 4.1`.
