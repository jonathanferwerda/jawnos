# JawnOS app release notes

The body of the GitHub release (`releases` tag). `scripts/app_publish.pl` reads
this file, adds the release date and the version codes that are actually
staged, and writes it back to the release. Keep the newest release at the top
under a dated heading; older sections stay as history.

## 2026-10-26 — launcher, single-app windows and the printer widget

This build makes the app feel like the system it is meant to be, rather than a
browser wrapped around the manager.

- **JawnOS home.** A native home screen with a clock, search, app grid, dock
  and a "today" usage card. The JawnOS row above the grid lists the manager's
  own apps — Marker, Music, Gallery, IDE, Box Office and the rest — so they are
  one tap away without opening the manager first.
- **Single-app windows.** Tapping a JawnOS app opens just that app, full
  screen, with a Back bar. The window is the manager's own window pinned over
  the desktop chrome, so the app keeps its exact behaviour and its live state.
  Fixed: the view could stay black because the manager had paused WebView
  timers process-wide; it now resumes them before loading.
- **Printer widget.** The clockface printer is available as a home-screen
  widget. The card is drawn natively immediately, then replaced by the real
  JavaScript printer when the manager can render it; a tap opens the manager.
- **Internet.** Web and Browse now remember which half you were using. Visited
  domains are bookmarks: tap a domain to open it in the browser, or assign the
  domain to a JawnOS app so the time you spend on it is added to that app. The
  site table shows today's minutes per domain.
- **Sign-in.** The app-gate page retries its sign-in once when the first
  attempt runs before the key bridge is ready, instead of stranding the app on
  "Could not sign in this app".
