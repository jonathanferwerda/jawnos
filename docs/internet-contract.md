# Internet, usage and the session shell — build contract

Frozen for the first build. Native surfaces are **siblings** of the manager, never
nested inside it: a live browser cannot run inside a WebView/WebKit page, so
"Browse" opens a native window (desktop) or activity (Android).

## 1. Surfaces

| Surface | Where | Owner |
| --- | --- | --- |
| `Internet` app window | `/manager/internet`, `templates/internet/` | manager (Perl) |
| **Web** component | existing `websites`/measures pipeline, unchanged routes | manager (Perl) |
| **Browse** component | native WebKitGTK window / Android `JawnBrowserActivity` | desktop app / Android app |
| Session bar | `desktop/jawnos_desktop/shell.py` (layer-shell) | desktop app |
| App-focus watcher | `desktop/jawnos_desktop/usage.py` (Sway IPC) | desktop app |
| HOME launcher | Android `JawnHomeActivity` | Android app |

The Internet window's Browse tab is a **launcher and history panel**, not an
embedded page. It calls the native bridge and falls back to `window.open`.

## 2. Launch bridge (manager page -> native browser)

The manager page calls, in order:

1. `window.JawnBrowse.open(url, mode, app, uuid)` — `mode` is `browse` or
   `measure`; `app`/`uuid` may be empty strings.
   - Desktop: the desktop app injects a `JawnBrowse` shim whose `open` posts to
     `window.webkit.messageHandlers.jawnos` with
     `{action:'browse', url, mode, app, uuid}`.
   - Android: `@JavascriptInterface` named `JawnBrowse`, attached to the
     **manager** WebView only.
2. Fallback: `window.open(url, '_blank')` if `JawnBrowse` is absent.

**Never** attach `JawnBrowse` (or any other bridge) to the browser WebView.

## 3. Usage sessions

Table `usage_sessions` (per-device; no raw URL sync by default):

```
uuid, device, kind ('site'|'app'), key_name, started_at, ended_at, idle_ms,
source ('browser'|'sway'|'usage_stats'), hostname, title, url, server_time, ost
```

`started_at`/`ended_at` are epoch **milliseconds** (strings in SQLite).

### POST `/manager/usage/session`

Auth: the normal app/session gate. The caller is the installed app, so it
already holds a device key or ticket — do **not** mint a new capability token.

```
kind, key, started_at, ended_at, idle_ms?, source?, url?, title?
```

- Clamp `ended_at` to now; reject a span under 1 s or over 12 h.
- `key` is the registrable domain for `kind=site` (e.g. `facebook.com`) and the
  `app_id`/package for `kind=app`.
- Answer `{ ok: 1, uuid }`.

### GET `/manager/usage/summary?from=&to=&kind=`

```
{ from, to, kind, rows: [ { key, total_ms, sessions, last_at } ] }
```

`total_ms` subtracts `idle_ms`. Rows are ordered by `total_ms` desc.

### GET `/manager/usage/timeline?from=&to=&kind=`

```
{ from, to, kind, rows: [ { hour, key, total_ms } ] }
```

`hour` is the local hour bucket, `YYYY-MM-DDTHH`.

**Accounting rule:** site-time is the focused tab's registrable domain while the
browser is foreground and the device is not idle. App-time is the focused
Sway window's `app_id` while the session is active. Do not count background
tabs or audio-only playback as active time.

## 4. Measuring a live page

### POST `/manager/web/measure/live`

```
app, uuid?, url?, selector, index?, html, title?
```

- `html` is the live document (`document.documentElement.outerHTML`), capped at
  2 MB. Treat it as untrusted data; never evaluate it.
- Runs the existing `subs::web_measure_candidates($dom, $json, $selector, $index)`
  and returns the same shape as `/manager/web/measure/set`, plus
  `confirmation` HTML rendered from `web/web_measure_confirm`.
- The browser shows the candidates and, on Save, posts the existing
  `/manager/web/measure/submit` with the chosen `spec`.

## 5. Security invariants

- The browser WebView/WebKit view must not share the manager's cookie jar or
  data store, must not carry any `@JavascriptInterface`, and must not ignore TLS
  errors for external sites.
- A page loaded in Browse must not be able to reach the manager on localhost;
  block private-network navigation from the browser surface.
- The manager's own TLS handling (self-signed/wildcard) applies only to the
  app's own HTTP client, never to the browse view.
- Padlock/app-gate rules are unchanged. A native surface is admitted exactly as
  the app it belongs to.

## 6. Android home widget (implemented)

The launcher's **today** card reads `usage_sessions` directly from
`database/jawnos.db`. The app and Termux share a UID, and the manager's session
cookie is HttpOnly, so an HTTP request from the activity cannot see it. The card
is therefore offline and independent of the manager. It filters
`kind='site'` until the UsageStatsManager job lands.

## 7. Internet bookmarks and domain -> app

- `GET /manager/internet/sites` returns `{ sites, apps }`; each site is
  `{ domain, url, app, total_ms, last_at }`. `apps` is the picker's catalog
  (`{app,title}`): the house's built-ins and every appointment, so a site can
  belong to any app the house knows.
- `POST /manager/internet/site/app` with `domain`, `app` (empty clears) stores
  the mapping in settings `internet.domain_apps` (JSON, synced).
- In the page, the domain opens the native browser, the app opens
  `appointmentGrabber(app)`, and a type-in picker assigns the app. The picker
  offers every appointment the visibility rule shows here and now (the place's
  level and the running people set it; a hidden appointment stays out of the
  suggestions). The active tab is remembered in `localStorage.internet_tab`.
- Cookies persist in both browsers: Android's WebView cookie store (flushed on
  pause/stop) and the desktop browser's own `WebsiteDataManager` under
  `~/.local/share/jawnos/browser`.

## 8. Launcher apps and single-app view

- `GET /apps/list` is public (app names and icon paths only):
  `{ apps: [ { app, title, icon } ] }`, built from the system catalog plus apps
  with a `main_image` setting (not every record's app).
- A JawnOS app opens as a single window at
  `GET /manager/centre_view?app=<name>&timestamp=<ms>&source=ws` (app-gated;
  the WebView's session cookie is the credential). Fallback: the manager page.

## 9. Printer widgets

- `GET /manager/printer?kind=<clockface|timeline|leaderboard|calendar|narrator|continent>&w=<px>&h=<px>`
  (app-gated) renders a standalone page that draws the real printer on a canvas
  and sets `window.__jawnPrinterReady = 1` / `document.title = 'ready'`.
- The Android widget uses a headless WebView with the app's session, waits for
  ready, captures the WebView to a Bitmap and pushes it through RemoteViews.
  Update every 30 minutes; tap opens the manager.

## 10. Out of scope for this slice

- Android `UsageStatsManager` app-time (separate permission path).
- Enforcement/blocking (overlay or device-owner).
- Replacing Android recents.
- Widevine/DRM on desktop.
- Syncing raw URLs across the mesh.
