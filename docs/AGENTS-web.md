# Web interface (moved from AGENTS.md)

Read this when a change is visible in the WebUI.

- **Test the WebUI in the real desktop view.** The desktop view is **Qt WebEngine
  (Chromium)** — the manager, Browse and the session bar all use it. Headless Chromium is for
  **automated checks only** (DOM smoke tests, route/JS error capture) — it is a different build
  with different flags from the Qt view, so it does not prove the real one. When a change is
  WebUI-visible, exercise it in the real JawnOS WebUI. A feature that depends on an engine detail
  (CSS `filter: url(#…)`, `canvas.toBlob`, `createImageBitmap`, WebCodecs, WebRTC) is not proven
  by headless Chromium alone — say so and check the real engine.
- Log in with a ticket URL: `https://127.0.0.1:3000/box_office/<uuid>?s=<token>`. The live token is in
  `.shots/ticket.txt` (gitignored, a real credential).
- It mints the `president` session cookie and redirects to
  `https://127.0.0.1:<working_port>/manager` (`working_port` from `config.json`; ticket served on `port`).
- curl: `https://127.0.0.1:3000 -k`. Headless: `/usr/bin/chromium --headless=new --no-sandbox
  --disable-gpu --ignore-certificate-errors --remote-debugging-port=<p> --user-data-dir=/tmp/<p>`, over CDP.
