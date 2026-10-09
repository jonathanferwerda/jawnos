# AGENTS.md — field notes for agents working on JawnOS

Written 2026-10-09 by an agent after a session on the store accounting, the budget app's
invoices display, and the invoice-by-email paper. Facts here were verified against the live
system unless marked "(unverified)". Read this before rediscovering anything the hard way.

## Runtime and restart

- Entry point: `./jawn` (master) — spawns `President.pl` in a PTY; President.pl spawns workers
  with `$ENV{PURPOSE}` set (`manager`, `websocket`, etc.), running `Manager.pl`, `Websocket.pl`.
- Log: `~/manager.log`. Database: `/home/jawn/initial.db` (SQLite, WAL).
- **Restart without detaching:** `printf 'restart' > ~/.president/status`. `jawn` polls the file
  every 2 s, sees `restart`, writes `good` back, kills the President.pl tree, and reboots it.
  This is the sanctioned path — it shows up in the user's terminal. Do not start `./jawn`
  yourself unless asked, and never leave a detached process behind.
- Status file values: `good` / `restart` / `frozen`.
- `jawn` refuses to run twice: it probes `~/.process_watch` with a length-prefixed Sereal
  query; a bare connect() is not proof of life (children inherit the fd).

## Hot reload rules

| Change | Needs restart? | Notes |
|---|---|---|
| `.ep` template | no | view mtime is checked per request |
| `.pl` (Manager/President/subs) | yes | `perl -c Manager.pl` first |
| `public/js/*.js` | yes for the browser to see it | the cache-buster query only changes on restart; the user may need a hard refresh |

## Database and data model

- Access from scripts: `chdir('/home/jawn/jawnos'); require './subroutines.pl';` then
  `&subs::db_query(...)`, `&subs::db_update(...)`, etc. `database_grabber()` returns a
  Mojo::SQLite database on `/home/jawn/initial.db`.
- `appointments` is the one big table: `app, uuid, type, movement, timestamp (ms),
  server_time (ms), duration, status, account, project, item, model, options, data (JSON),
  file (JSON array), notes, ...`.
- **`app` is the category/document app. `account` is the account app** (banking, koho, …).
  The budget statement queries `where account = ?` per account app (from settings `pos`/`mab`
  = `account`), so **a transaction with an empty `account` is invisible to the statement
  display** (it still exists and still tallies nowhere). Pass a real account when recording
  payments.
- Money rules (consistent as of this session): a line = unit price × quantity; discount ×
  quantity; `numbers.subtotal/total` are sums of lines. This machine has `sales_tax = 1`, so
  total = subtotal.
- Documents (store):
  - `type` = `invoice` or `quote`, `movement` = `income`, `status` column = `open` /
    `completed` (quotes usually have no status).
  - `data.id` = document number like `1092026-5de3` (MMDDYYYY-NXXX).
  - `data.numbers` = `{subtotal, tax, discount, total, balance, cost, markup, tax_rate}`.
  - `data.payments` = `[{account, amount, timestamp, server_time, appt_uuid, uuid}]` where
    `appt_uuid` is the income transaction that paid it.
- `db_insert` ignores its 3rd argument (the where clause is meaningless for inserts anyway —
  don't copy-paste `db_update` call shapes onto it).
- `->hashes` returns **one** `Mojo::Collection`; `my ($a,$b) = $q->hashes` does not split rows.
- `subroutines.pl` is `require`d at file scope into `package subs`. Features do not leak into
  required files — no named signatures there. `write_file`/`read_file` are File::Slurp, unprefixed.

## Store → invoice → email flow (routes that matter)

- `post /store/quote/save` (`quote` JSON, `cx`, `movement`, `item`, `uuid`, `timestamp`).
- `post /store/quote/move` (`action` = `invoice`, `type` = `quote`): converts and **consumes
  the source** (delete_app; files filed away; deletion queued for remotes). It does not
  reverse stock.
- `get /store/email` → compose window JSON `{html}` for a doc (`type`, `uuid`, `cx_uuid`).
- `post /manager/mail/email/send` → sends, files a copy. **The only address that may ever
  receive mail is `jonathan.ferwerda@outlook.com`.** All drivers guard with a die; keep it.
- `post /manager/transaction/record` with `vendor` = invoice's app,
  `transaction_information` = invoice uuid, `movement` = income: writes the transaction and
  then pushes a payment onto the invoice, decrements `numbers.balance`, and sets the invoice
  `status` to `completed` when the balance hits 0. (See `Manager.pl` ~L8110.)
- Recorded when sent: `subs::sent_mail_filer` writes an `email` appointment on the
  recipient's app (`data = {mail_uuid, email}`), copies attachments (each with `mail_uuid`),
  then `file_encrypter` seals them. `delete_app` on mail-bearing files deletes the mailbox row.

## The white-paper trap (settled — do not re-investigate)

- `email_send` draws the invoice PDF **from the compose's own HTML via a temp file and
  `weasyprint` — no network**. This is deliberate: weasyprint's URL fetcher has a 10 s
  timeout, and asking it to fetch this machine's own URL from inside the accepting worker
  makes the worker serve itself → timeout → silent fallback to the **public** URL
  (`thejunderground.com:3000`, a **different machine** with a dark theme) → dark PDF.
- Verifying the paper: the filed attachment is encrypted; fetch it through
  `/file_open?file=/home/jawn/Documents/<app>/<file>.pdf.enc` with a session cookie to get
  the PDF. White paper ≈ 155 KB (229k of 242k sampled pixels pure white at 50 dpi); the dark
  remote render is ≈ 13 KB. `pdftoppm` + PIL pixel sampling is the reliable "eye"; this model
  cannot view images directly. `pdftotext -layout` reads the numbers.
- The paper template is `templates/store/printer/header.html.ep`; print CSS pins white;
  `.paper` is the sheet. The QR code intentionally points at the public address.

## Mail websockets

- Running inside the websocket-purpose workers: per-app sockets in `/tmp/ws/<app>` and the
  mail socket `/tmp/ws/mailws`; listeners are re-armed by 5 s recurring timers.
- Mail arrivals: `mailws_sender` matches a message against tabs, `arrival` messages raise the
  start-menu dot and fall back to `notification_sender` when no mailbox is watching.

## Budget app (`templates/budget.html.ep`, `get /manager/budget`)

- Displays: `statement`, `budgets`, `invoices`, `daily_sheet` (`display` select persists via
  `new_settings`).
- **`scope` comes from the settings row, not the request param** (`$settings->{scope} || hour`).
  Window start/end come from `father_time` (or explicit start/end times; then the end bound is
  inclusive, otherwise exclusive: `$t2_comp`).
- `movement` setting filters transactions by **`type`** (default `["transaction"]`), which is
  why invoice rows never entered the old stub.
- The invoices display is a **document ledger**: `documents` in the JSON/stash, one query for
  `type in ('invoice','quote')` over the window, per-doc `paid`/`balance` computed from
  `data.payments`, footer totals split invoice vs quote. Clicking `.budget_invoice` opens the
  document (JS in `public/js/manager/budget.js`).
- Historical bug (fixed): the invoices branch used to run its unrestricted window query
  **inside the per-account loop**, returning all rows once per account (×7) — totals inflated,
  balances multiplied, and invoice rows dropped by the type filter. Do not move window-wide
  queries into that loop.
- Statement view queries per account app; transactions whose `account` is empty are invisible
  there (`account = ''` matches nothing in the accounts list).
- `budget_runner` and `budget_calculator` write `cache` rows; `budget_current_information`
  renders autocalc panels.

## Client-side conventions

- Windows: `windowMaker(response.html)`; selectors `.wind[app=...]`, details container
  `.re_details`.
- Open an appointment: `appointmentGrabber(app, timestamp)` to spawn the window, then
  `GET /manager/appointment_details` with `{app, uuid?, timestamp, scope, sorts, ...}`.
  **The route requires `scope`** or it 500s with `unknown time span:` — always send one
  (the client default is from localStorage).
- `deloreanBringer()` (in `manager.js`) builds the standard request params (timestamp ms,
  scope, timeshift, time_machine, sorts, filter, …). localStorage keys are the app's state.
- Icons: `&subs::icon_for('/path.png')` / `icon_path(...)` pick from the active icon set
  (`icon_set` setting); `public/icons/sets/build.js` is the generator. `thejunderground.com`
  is a different machine — do not assume it runs this code or these icons.

## Testing fixtures and drivers (this machine)

- Session cookie jar: `/tmp/jawn_cookies.txt` (Netscape format). **`cookie_jar->load` fails on
  curl files** — parse line by line into `Mojo::Cookie::Response` (name/value/domain/path,
  secure=1, strip trailing newline). Working snippet in `/tmp/drive_store.pl`.
- Base URL for curl/UA: `https://127.0.0.1:3000` (`-k` or `->insecure(1)`).
- Customer `email_test`: uuid `ATk7iH7ehPmwOd1siil9YwRlL`, email address set. Has model
  `standard` ($60/$30) and option `rush` ($25/$10). Invoices `1092026-1de3`…`5de3`; `5de3`
  (uuid `FL30eZLVM0pynRTomEut2XDo8`) is $230 = 3×standard + 2×rush.
- Sender mail server uuid `PofO7Us0QEfSt2Eyfeq73fRgu` (app `me`, jawnferroda@gmail.com).
- Driver scripts in `/tmp` (untracked): `drive_store.pl` (full quote→invoice→compose→send),
  `send_existing_invoice.pl <invoice uuid>`, `pay_invoice_driver.pl <invoice uuid> <amount…>`
  (partial/full payment via the real route), `pay_invoice_cleanup.pl <invoice uuid>` (deletes
  the payment transactions through `/manager/delete_app` and restores the invoice from the
  snapshot the driver wrote), `email_test_math.pl`, `mail_test.pl`.
- Older dark emails: invoices `1de3`–`4de3` (sent before the paper fix). `5de3` (sent
  15:24, 2026-10-09) is the first white one — verified by pixel sampling.

## Pitfalls

- Standalone-script writes to `appointments` can be overwritten later by the running app when
  its own routes touch the row (observed with the `email_test` invoice status flipping back
  after a script update; likely a deferred/queued route write replaying a cached row). Use the
  app's own routes for writes that must stick, and re-read to confirm.
- The details route 500s without `scope`; that is not a code bug.
- Do not trust a shell `weasyprint` test to prove what the app renders — test by sending and
  checking the filed attachment (size / pixels).
- `git commit` only your own files; other agents frequently have uncommitted work in
  `public/js/manager/*` and `templates/`.
- When testing accounting, restore fixtures afterwards (see `pay_invoice_cleanup.pl`) and say
  so in your report: the user's books are real.

## Watch and deck firmware (`jw/jw.ino`, `jt/jt.ino`)

Added 2026-10-09 (evening) by the agent who chased the room-push crashes. Verified on the
bench watch (`/dev/ttyACM0`) and the T-Deck (`/dev/ttyACM1`).

- Build/flash: `/home/jawn/.platformio/penv/bin/pio run -d jw -t upload --upload-port
  /dev/ttyACM0` (deck: `-d jt -e deck --upload-port /dev/ttyACM1`). Libraries:
  `lib_extra_dirs = /home/jawn/jawnos-fw/watch-libs`; ELF for decode:
  `jw/.pio/build/watch/firmware.elf` (addr2line from
  `~/.platformio/packages/toolchain-xtensa-esp-elf/bin`).
- **Never print from the BLE write callback.** It runs on the BLE stack's own task; at the end
  of a 52-chunk room push it had **1.9 KB of stack left**, and `Serial.printf` wants more. The
  symptom is a *silent* hang or a panic with no dump (the "needs a hard reset" mornings). All
  reporting lives in `loop2` (watch) / `loop()` (deck).
- **Never copy the room push.** It is ~25 KB and the path used to hold five live copies (queue,
  consumer, splice, payload, `before_me`). Every handover is a move; `WString::move` is
  protected, so use the move operator (`*p = std::move(s)`); the payload is carved out of the
  raw message in place with `raw_json_field_span`, and only `__specs.time` is parsed for the
  clock.
- **Big prints wedge the USB-Serial/JTAG console**, which reads as dead silicon while the app
  keeps running. A 25 KB config dump at boot did this; `readFile` logs a size now — keep it
  that way, and prefer a prefix over a whole message.
- Breadcrumbs: `crumb("tag")` writes into `RTC_NOINIT_ATTR` memory (plain `RTC_DATA_ATTR` is
  reloaded from the image on this reset type), the boot log prints the last one, and the
  `crumb` console command dumps the 32-entry ring with the free heap at each mark. `crash`
  aborts on purpose to test the path. A 20 s task watchdog on `loop2` reboots it instead of
  hanging.
- Serial console (921600; `stty -F /dev/ttyACM0 -hupcl` before writing, or the DTR toggles a
  reset): `tilt on|off|now|status`, `tiltdbg on|off` (`[t] x y z` stream while dozing),
  `tiltsim` (feeds the raise state machine a synthetic raise), `time`, `heap`, `crumb`,
  `crash`, `blestop on|off` (stop the state_request that makes the phone push), `blesim`,
  `blesimframe [n]` (the daemon's 52-chunk push from a BTC-sized task).
- Wrist raise: the BMA423's interrupt line cannot announce it (any-motion detection crash-loops
  the radio — do not re-enable), so `wristPoll()` samples at 10-25 Hz inside the doze beat and
  runs a rise/settle/angle state machine; a raise earns a 10 s look and a touch hands the wake
  back to the normal timeout. The **light-sleep** path (`lightsleep on`) still uses the
  interrupt-gated `wristRaiseGate()`, so a raise there is not caught — port the polling into
  the light-sleep nap loop if LS gets turned on.
- The phone's BLE bridge dies when the phone sleeps (~10 min of screen-off); the tablet keeps
  it alive. The watch asks for state 3 s after a connect, so the room hydrates by itself once
  the bridge is back (START BLE BRIDGE in the API app).
- Logging: **one** `cat /dev/ttyACM0` logger at a time. The loop shells
  (`while :; do cat /dev/ttyACM0 >> log; sleep 1; done`) restart their `cat`, so
  `pkill -f 'cat /dev/ttyACM0'` alone leaves them fighting over the tty (bytes split randomly
  between logs); kill `pkill -f 'while :; do cat /dev/ttyACM0'` too.

## Device lister and the scan

- `GET /manager/configure/device_lister` passes the typed box as `host` → `ip_range`; each row's
  Scan button is `load_type=ping_scan`. A typed host is honoured even when `ip neigh` has
  entries (patch 4c775b5), and the aliveness ping waits 1.2 s (a sleeping esp32 answers
  slowly).
- Boards serve `/device_query` on **PORT_DOCK (3000)** — the fallback URL in `device_lister`
  (`http://<ip>:3000/device_query`) is correct; the T-Deck answers there with
  `purpose: teletype`.
- The listing renders the **devices table** after the scan saves its fresh data, so a scan that
  drops a device leaves no row behind. If a device pings but never lists, check
  `ip neigh show dev <nic>` (a quiet device's ARP entry expires) and that the running workers
  actually have the new `subroutines.pl`: compare the file mtime with the worker start
  (`stat -c %Y subroutines.pl /proc/<worker pid>`) — prefork workers preload the app, so every
  `.pl` change needs a real restart, and "the app was restarted" may have been before your
  edit.
- Headless testing: the ticket URLs (`https://127.0.0.1:3000/box_office/<uuid>?s=…`) log in and
  set the `president` session cookie; curl the route with the cookie jar afterwards. A direct
  `PERL5LIB=/home/jawn/perl5/lib/perl5 perl -MData::UUID -MJSON::PP -MMojo::UserAgent -e
  'chdir "/home/jawn/jawnos"; require "./subroutines.pl"; …'` runs the same code path outside
  the app (President.pl is what loads some of the modules, hence the `-M`s).
