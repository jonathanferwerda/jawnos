# Roadmap / handoff

The remaining plan, as of **v0.1.757** (2026-10-18). Done work is marked so it is
not redone; everything unmarked is still to do. Keep this in step as items land.

---

## Phone — calling & messaging

Done: native call screen (avatar, name over number, Answer/Decline, wake-on-ring);
the app records each call once and the house files it (one appointment per call);
incoming/outgoing/missed → appointment on the caller's own app; Box Office
blacklist + two-press Block; caller-ID (Call screening) role; Voicemail-style
"respond via message" service; ringtones (`ring.mp3` etc.) + custom sound upload;
Known/Recent/Blocked/All panes; multi-line contacts (a second number resolves to
the person).

Still to do:
- **App owns the ringtone** — silence the system ring and play the house's, instead
  of only firing `ring.mp3` when the appointment's `notification` ability is on.
- **Lock-screen capture from the real device** — we have mock geometry only
  (`.shots/call_screen_logo.png`); take a real one.
- **MMS end to end** — machinery is declared (klinkerapps push/transaction,
  `RECEIVE_MMS`); never observed a real MMS in or out.
- **SMS role from Settings** — SMS had to be granted over adb (`cmd role
  add-role-holder --user 0 android.app.role.SMS com.termux`); the user could set
  Phone but not SMS from Settings. Re-check after the next build; `JawnRespondViaMessageService`
  was the gate.
- **Replace termux with native** — audio, image, video (camera record), contacts,
  call log. The call log's `termux-call-log` "hasn't been working"; the app's own
  `JawnInCallService` record is now the source, so verify the log pane is current.
- **Wider messaging** — MMS (above), RCS, and possibly relaying Facebook Messenger.
- **Native contacts/calls already partly done** — finish: names/numbers of unsaved
  people arrive as their own app, then get renamed/merged (merge panel below).
- **WebRTC as the road** (the eventual answer, replacing Bluetooth HFP):
  - phone ↔ guests/residents through their ticket — one transport per person.
  - a `webrtc` entry in the chat transport dropdown (webrtc joins chat/sms/lora).
  - route call audio to the laptop (remote_machines).
- **Test VOIP** — a free service to call in from another number (Fongo is installed
  on the handset as the current other-number path).

## Chat / mailbox deconsolidation

Done: **Phone**, **Email**, **Chat** split into their own apps; the appointment
Connect group's Chat button opens a person's one conversation in-window with a
back button; friends list = one row per person with every line; per-line sms
choice in the transport dropdown; history under any of a person's numbers
re-files onto their ticket thread. The **Email** window is now a mail client of
its own - a folder rail, the message list beside it, Compose in the toolbar, and
a message or a draft in a reading pane - with its styling scoped to
`.wind[app="email"]` (the shared conversation partial is kept for the thread) so
Mailbox and Chat are untouched. Switching a folder or an address refreshes just
the list in place: the shared `mailMaker()` used to send the split apps to
`/manager/mailbox`, which answered `app="mailbox"` and made a *second* window.
The Email window reads and writes in a pane of its own with a **Back** button
(not the window drawer) and carries the ordinary client kit: **Reply / Reply all
/ Forward** with the original quoted and `Re:`/`Fwd:` on the subject, **Cc** and
**Bcc** (new `mailbox` columns), a list **search**, unread bolding, and a **Send**
that goes out at once over the account's own SMTP rather than through the
`email_sender` utility (kept for lists). Letters that answer one another are
grouped into one **thread** row (a `thread` key of subject + party) and open as
the whole exchange; a message can be **starred**, marked **unread** or
**archived** (Starred and Archive folders in the rail), and incoming **Cc** is
parsed now, so a carbon copy someone else sent is shown too. A thread follows
the **message headers** (`Message-ID`/`In-Reply-To`/`References`) where they
exist, so a reply stays in its thread even if its subject changes. The reading
pane's **Move** is a folder menu (Inbox, Archive, Drafts, Trash), **attachments
open** as links, and the split mail windows now **restore on a page refresh**
(`appWindowOpener` grew email/chat/pen branches instead of falling to the
appointment path).
onto their ticket thread.

Still to do:
- **Pen** — finish moving it out (the last mailbox section that has a route but no
  own window/UI work).
- **LoRa** — its own app on regular **LoRaWAN** protocols (not the current
  mailbox Lora section); decide whether it stays in the chat dropdown meanwhile.
- **Messages** — the plain "messages" home for sms when it is not a person thread.
- **`$gb::known_appts`** — add `phone`, `email`, `chat` (and later `pen`, `lora`)
  as each lands, so the start menu / taskbar know them.
- **Merge panel shortcut** — a "select all non-defaults" button (the panel already
  pre-selects the non-default side per row).

## Contacts & identity

Done: typed **Phones**/**Emails** abilities (Mobile/Home/Work/Custom) beside the
plain row; lookups (calls, tickets, mail, in-call naming) match the list too;
contact sync fills the list instead of overwriting; the rename-merge panel drops
window state and always shows contacts either side holds.

Still to do:
- Unknown→known flow polish: the number-app → person rename/merge is in place;
  make the "keep existing vs keep new per setting" screen reachable on mobile
  (it is; verify) and consider the select-all shortcut above.
- Blacklist: blocked-number calls are filed as cancelled; confirm naming/blacklist
  edge cases (a blocked number that is later named).

## Native app (Android) — `~/jawnos-app/termux-app` (branch `jawnos`, remote `fork`)

**Every APK change bumps `versionCode` and is published** (`perl scripts/app_build.pl`
then `perl scripts/app_publish.pl`). Last shipped here: **1039 / 0.118.40**.

Still to do:
- **Notification badge** — stop the native termux app showing its own notifications
  on the home-screen icon; carry the program's own notifications there instead.
- **Status/nav bars** — an option (in the admin panel) to show the Android
  clock/battery/notification bar and always-on home/back buttons.
- **Native camera / video / audio** in the appointment camera buttons and the
  start-menu **Camera** app (replacing the termux pipeline); webcam on desktop is
  done.
- **Native NFC** — a scan currently falls through to the system NFC page; want the
  Chrome-like read/write the web side has (`jawnNfc*`).
- **WebUSB** — enable it (a MIDI keyboard is planned).
- **Permissions** — the web app half reported `navigator.*` not working; verify
  geolocation/camera/mic/notifications grants in the WebView.
- **Gate behaviour** — if the webapp is unreachable within ~3s, show the logo with
  a glow and an **Admin Panel** button instead of a blank gate.
- **Default apps** — Phone is settable; SMS needed adb (see Phone above).

## Desktop — `desktop/`

Done: splash, black background, GitHub auto-update, APK-style version numbering,
an update **button** (not a background refresh while working).

Still to do:
- Make the desktop **as beautiful as the Android app** (visual pass).
- Same permissions as the app, **except GPS when there is no module** — and keep
  ignoring the ISP's low-accuracy position (navigation already disregards it).
- The Guide associate on desktop: confirm the mic permissions and that the
  "hey jawn" requirement is gone; the close button had a drag bug (check).

## Gate / startup / login

Done/known: ticket URL mints the session; the tablet gate stuck fixes landed;
the redirect animation and logo work.

Still to do:
- **Bypass the login while keeping the view intact** — go straight to `/manager`
  without the loading animation when a session is already held (target <1s).
- Gate polish: **Admin Panel** button on the gate, the logo at the top, and the
  logo-with-glow splash while the webapp loads (pairs with the app item above).

## Data / records

- **Records recovery** — the self-heal that lists appointments a repair shortened
  from the sealed snapshot and restores only the named apps (co-agent area,
  `scripts/records_recover.pl`, `subs::records_*`). In review; keep the "leave this
  app alone" silences honest.

## Devices & networks

Done: a scan sweeps each local subnet as well as reading the neighbour table, so
an appliance the machine has never talked to - the printer at 192.168.2.6 - now
appears where the ARP cache alone never listed it (`subs::subnet_sweep`, nmap
with a ping-sweep fallback, private ranges only; only resolved rows are kept, so
a half-resolved ARP entry is not mistaken for a device). The **Dev** panel is
grouped by network: one section per subnet (its address, the machines and
interfaces that reach it) over the device tables, with the machines named once
above. A scan no longer prunes a device it has a reason to keep - one the person
locked, a machine in the mesh, or one carrying a real purpose - so an away
machine (or an away printer) stays listed.

**A device names itself as it joins.** jw, jt and the alarmclock advertise
`_jawnos._tcp` over mDNS (the built-in `ESPmDNS` on the ESP32s, `SimpleMDNS` on
the Pico 2 W) carrying chip_id, name, purpose, model and its abilities; a printer
is recognised the same way from `_ipp._tcp`. `subs::mdns_merge_address` folds
those records into the device row - naming the device, or adding one the
neighbour read missed - and `subs::device_mdns_sync` runs that on a 15-second tick
(`President.pl`), so a plugged-in watch, deck or pico is listed with its purpose
and abilities within seconds and without a Scan. A device with **no WiFi** at all
(a fresh deck) is met by radio instead: `subs::ble_adopt_scan` scans for a board
advertising the Nordic UART service and the server adopts it the moment it names
itself over the link (see T-Deck parity).

Still to do:
- A full scan **cadence** (the mDNS tick covers the devices; the nmap sweep still
  runs only on Scan).
- A device's abilities are shown but not yet acted on (the `App`/Embedded panels
  do not yet read `capabilities` to offer only what a device can do).

## T-Deck parity (from the watch)

The deck (`jt.ino`) now carries the watch's BLE transport: outbound notifies are
cut to the link's MTU (`ble_notify_payload`) and gated on the central's
subscription (`ble_link_ready` / `MyTxCallbacks`), a compressed bridge payload is
inflated (`ble_inflate_if_zlib`), and a button tap goes over BLE first
(`tap_over_ble`, wired into mb1..mb8) with queued taps flushed the same way - the
tap envelope is ~450 bytes and is no longer truncated to 20.

Still to do:
- **Voice clips on the deck (route A) are in.** A recording (`/recordings/
  <epoch>.wav`, 16 kHz mono) is folded to 8 kHz, compressed to IMA ADPCM (~8:1 on
  the deck: 128000 -> 16444 bytes, verified) and sent as one base64 `voice`
  message over the BLE bridge, which `subs::voice_ingest` funnels into the same
  transcription a tap reaches (`deck_voice_compress`/`deck_voice_ble_send`).
  **The link is in too, and needs no WiFi.** `subs::ble_adopt_scan` (a 30 s tick
  in `President.pl`) asks the bridge daemon to scan; the daemon now reports each
  device's advertised service uuids (`desktop/jawnos_desktop/ble.py`), and a
  scanned device whose advertisement carries the Nordic UART service, and whose
  address the tree does not already hold, is one of ours. The server connects to
  it, the board's own `state_request` (chip_id + purpose) is what records it
  (`ble_message_processor` -> `ble_device_record`), and the ordinary host rule
  bridges it - "plug it in and it is known", with no access point at all. A device
  that speaks NUS but is not ours is tried once and left alone for ten minutes.
  Verified end to end on 2026-10-16: the deck (`98:A3:16:CD:EC:8D`, chip
  `13495436`) was adopted by radio and linked.
- **A stale machine id no longer strands a device.** `manager_file_maker` builds
  an id as `<who>@<database>.<computer>`, so renaming the database (initial ->
  jawnos) retired every stored id: a device's record then named a machine no row
  held, `ble_homebase_alive` treated that phantom as alive forever, and the real
  homebase yielded its own device every 60 s - which is why this box never bridged
  the watch or the deck. `ble_machine_match` compares the parts that survive a
  rename (the person and the computer name), so the homebase recognizes its own
  device again; `ble_rehome_check` then rewrites the record to the current id. The
  deck re-homed itself to `Jonathan Ferwerda@jawnos.Laptop`. The anti-thrash in
  `ble_enforce_hosts` keeps a single link on the device it already holds, since the
  daemon bridges one radio at a time, and `ble_yield` now releases the link only
  when the device being yielded is the one actually linked (yielding the watch
  used to drop the deck, which then reconnected and cycled).
- **The deck's partition table is our own** (`jt/partitions.csv`, wired with
  `board_build.partitions`): two 6 MB OTA app slots and a 3.875 MB FFat, instead
  of the stock two 3 MB slots + 9.9 MB FFat. The sketch sat at 95% of 3 MB with
  the BLE transport, voice clips and UI already in, so there was no room for the
  wake-word stack still to come; it now sits at ~48% of 6 MB, with FFat still
  holding ~30 clips. Flashing the new table erased the FFat (config restored to
  defaults; the deck's BLE identity is the server's record, so it stayed known).
- Wake words (`hey jawn` / `jawn do`) still need the TFLM stack copied over
  (`voice_models.h` -> `jawn_micro_features` + the model headers). `jawn_do` is
  not trained yet either. The VAD/manual clip is the first target.
- The deck's **FFat was corrupt** (it mounted, listed no files, yet reported only
  part free, and every write failed); it now heals that at boot with a write
  probe and a reformat, which is what let recordings land again.
- The deck's blank screen was **the wrong firmware**: `pio run -t upload` with
  two boards on USB auto-picked the watch's port, so the deck was running `jw` and
  resetting in a loop on the LilyGoWatch S3 board assert. Flash with the port
  named - deck `--upload-port /dev/ttyACM0` (SER 98:A3:...), watch
  `/dev/ttyACM1` (64:E8:...) - and it boots the deck UI.

## Shopping / Market / warehouse

Done: `quantity` as a first-class budget — a stream **rate** from the appointment
`quantity` over the window, and a fixed form (`6quantity`) that reads the
warehouse on hand; `budget_autocalc` fixed to a rate (no more window-averaging);
the **Market** app (vendor + list dropdowns, a need/want dial per row, Enter adds,
a `Here:` list from the position and the vendor's home plate); named lists
prepopulated from the house categories; cart → **Checkout** writes a `purchase`
per line on the item's own app; a **barcode scan** resolves a code once (house
item, then a catalogue, then the model's naming) and makes a house item app; the
native **JawnScan** bridge; **packaging autofill** via the model; the
forgot-to-check-out reminder; and reading a whole **receipt** — the scanner (ADF
feeds a long one in one pass) or a photo → the vision model reads the lines → a
confirm panel names each in our terms and links it into the list in the cart.
A **Receipts** pane reopens what was kept — its page thumbnails open inline and
**Add to list** puts its lines back on the list in the cart; the scanner buttons
follow the host's feeds (a computer, not a server), and an ADF batch is read in
page order rather than modification-time order. A scan also shows its work live —
the scanner's own line (with `--progress`) and each page as it comes off the feeder
(scanimage writes a page only when it is complete, so the image pops in then) —
Cancel stops it mid-feed, and a run that produces nothing says why (no paper,
device busy). The confirm shows the page full size beside the lines, with the
date, total, paid-by and tender reference editable so they can be checked against
the paper; and a barcode scan can be
handed to another tab in the house (that tab opens its own Google scanner as if
it had pressed Scan, and the code comes back to the tab that asked; a browser
without one gets a live camera view), selected from the abilities list
(camera, scan, printer) the capability table now carries. A phone browsing its
own jawn is reached through the peer rail: the camera tabs of every enrolled
peer are gathered in parallel, and the chosen peer's own manager relays the scan
command to its tab. A scan run is a session: the machine that pressed Scan owns
it and remembers the device it used last (a phone chosen once is the default),
the phone re-opens its scanner for each read (rapid fire), and the reads collect
on a scanning page - Done puts them on the list, Cancel (or the phone's Back)
throws them away, and either ends the phone's sheet (a native stop broadcast,
since the WebView is paused behind it). The picker stays on the scanning page, so
a second input can join the same run and each can be stopped on its own. A
computer with a webcam reads with zbar on the server instead, real time. Displayed app names are run through
`format_name`; the unformatted name is only ever the key. Market also reopens the
list it was last on. Checkout fills an expense transaction from the cart without
writing anything yet; Save is what records the purchases and stock, after the
person has set each line's quantity and packaging (a + beside Unit names a new
one on the spot). An account app carries a
`payment_type` in its Configure panel (cash, debit, credit, visa, mastercard,
amex, interac, crypto, ...), and a receipt's printed tender is matched to it —
an exact word first, then its family when that family has a single account
(credit -> the only mastercard/visa, debit or interac -> the only debit card);
Checkout writes the purchases, then opens the list's category with an expense
transaction prefilled from the cart for a person to check and save.

Still to do:
- **A real receipt through the ADF** — the paths are built, the live view and the
  page order are proven, but the feeder is currently answering `Device busy` (a
  failed pull leaves it needing a clear/reset); load a real receipt, press
  Receipt → Scan (ADF), and confirm a long one arrives as its pages in order.

- **Low-confidence lines** — the confirm panel trusts the names; mark a line the
  batch naming was unsure of, or one whose prices do not sum to the printed total,
  so it is the one a person checks.
- **Vendor ↔ list "shops at"** — currently learned only by adding an item with
  both set; make it an explicit, editable section.
- **Add a due item that is not on the list** — a warehouse-short item is only
  upgraded to a need when it is already there (`market_upgrade_need`); add it on
  open instead of waiting for a person to type it.
- **Cadence** — the warehouse check runs on Market open (`/manager/market/refresh`);
  make it a timer too, so a due item surfaces without the app being opened (the
  "always keep 6 beers" notify/shopping-list side).
- **`market_cart_watcher`** — the forgot-to-check-out reminder (`Alarm.pl`) is
  written but never time-tested.
- **Native receipt capture** — the JawnScan bridge sends a barcode today; give it
  a photo path so a receipt can be captured on the phone as well as loaded.

## Platforms & multi-user — findings (2026-10-18)

Two different questions are hiding in "ports":

- a **house** runs the Perl tree and SQLite and owns the data;
- a **client** is a browser or WebView that opens a ticket URL.

A platform can be either. The client half travels almost for free (the UI is
web); the house half is the port problem. The same distinction decides
multi-user: a shared house is a roles/ACL problem, not a sync problem.

### Port readiness

| Platform | Client today | House today | Real gaps |
| --- | --- | --- | --- |
| **Linux** | yes | yes — reference target | none; `desktop/` is the native shell |
| **Android** | yes (WebView) | yes, via the Termux fork | Play Store policy (sideload only); the native replacement of termux APIs is already roadmap work |
| **macOS** | yes | likely, untested | `/proc` reads, `shred`, `timeout`, `xclip`, `ip`, `systemd`; Homebrew for `ffmpeg`/`magick`/`tesseract`/`qrencode`/`nmap`/`sox`; GTK desktop shell is Linux-only |
| **Windows** | yes | no | `fork`/PTY, AF_UNIX IPC, POSIX shell, `/proc`, signals. WSL2 sidesteps all of it; native needs a process/IPC layer |
| **iOS** | yes (WebView/PWA) | **not viable** | no Perl runtime, no long-lived background listener; App Store rules; call/SMS recording is not available to third-party apps |

The seams are measurable, not speculative. `jawn` supervises the tree through
`Mojo::IOLoop::ReadWriteFork` with a `bash -i` PTY (`jawn` 614-701). The core
has roughly 60 fork/PTY references, ~350 shell-command lines, 12 `/proc` reads,
and AF_UNIX sockets for internal IPC (`Manager.pl`, `subroutines.pl`,
`Websocket.pl`, `Alarm.pl`). The shell surface is concrete: `shred` 54, `mkdir`
38, `hostname` 30, `echo` 19, `sqlite3` 17, `timeout` 15, `touch` 14, `magick`
12, `ls` 11, `pkill` 5, `openssl` 5, `ffmpeg` 4, plus `xclip`, `tesseract`,
`qrencode`, `ip`, `ps`, `df`, `whoami`, `uname`, and the `termux-*` bridges.

Practical order:

1. **macOS house** — keep Perl; replace the `/proc` reads with `ps`/`sysctl`,
   `shred` with `rm -P`, `timeout` with a Perl alarm or `gtimeout`, `xclip` with
   `pbcopy`; package the Homebrew dependencies. Rough: 1-3 weeks with tests.
2. **Windows house via WSL2** — days, no code change; document it as the
   supported Windows house path. Strawberry Perl is the best native runtime but
   does not solve `fork`/PTY/AF_UNIX/`/proc`/signals; Cygwin or MSYS2 Perl (a
   POSIX emulation layer) is the likeliest way to run the tree unmodified, and is
   worth a spike. A native Strawberry house is a separate 2-4 month job
   (process/session layer, IPC, PTY, path/home handling, service wrapper).
3. **iOS client** — a Swift WKWebView shell that opens a ticket to a house on the
   LAN/cloud. Rough: 2-4 weeks. Do not plan an iOS house. iSH (x86 Linux
   emulation) can run Perl and is worth a spike, but iOS suspends the app, so it
   cannot be an always-on house; treat it as a demo, not a distribution path.
4. **Native shells** — Windows/macOS desktop supervisors are separate from the
   house. `desktop/README.md` already names the Windows work (`core_win`,
   WinRT BLE); macOS would need its own shell (PyGObject/GTK via brew is not a
   good answer).

### Multi-user readiness

**The vocabulary exists; the boundary does not.**

What is already in the tree:

- `$gb::social_constructs` (`gb.pl` 217) defines six dimensions — communities,
  teams, clubs, projects, accounts, people — each with a singular name, a
  default, and a picker order.
- `mailbox` carries all six as columns (`database/schema.sql` 69); `appointments`
  carries only project/club/account (line 22); `warehouse` carries
  project/account. So **only mail is fully construct-keyed today**.
- `$gb::master_plan` (`gb.pl` 938) is a code-resident containment tree
  (team → clubs → communities → projects). It is read by one template, the
  ticket-request team dropdown (`templates/store/ticket_request_privilege.html.ep`);
  it is not stored, editable, or linked to any row.
- `$gb::chairs` (`gb.pl` 111) is the only role hash: guest/resident/citizen/
  blacklisted with ranks 0-3. Routes enforce it ad hoc with
  `if $c->session('privilege') eq 'citizen'`.
- `tickets` are session grants; `paired_devices` and `device_requests` are
  device identities with challenge/response login. A paired device is minted
  `citizen` (`device_store_pubkey`) and gets the same `me` settings as everyone
  else. `tickets.name` is a display label, not a principal.
- Mail **public channels** (`/manager/mail/public_channel`, `mail_channel_key`)
  are the one existing sharing primitive: a citizen advertises one construct
  tuple to guests. It is mail-only and guest-only.
- One key: `house_key`/`suds_grabber`/`session_suds` give every session and
  every peer the same data key. Per-note encryption already takes a secret
  (`note_encrypter($secret, ...)`), which is the seam a per-construct key needs.
- Peer sync replicates every table with a `server_time` except a small forbidden
  list (`sync_table_list`). Every peer is fully trusted and holds the key.

What is missing for the team/community model:

- **A person principal.** No `users` table; every session is the same citizen.
  A person is already an app whose `pos` or `mab` setting is `person`, so do not
  add a parallel people table: use the person app as the principal. The app's
  `uuid` setting is per-device (settings rows are keyed by `device`), so use the
  app name as the house-wide identity, or add one canonical `person_id` record
  and keep names/`aka` as aliases across rename-merge. Carry that id on tickets
  and paired devices, and read `me` settings per person (or person+device).
- **A persisted construct registry.** Constructs are already apps
  (`pos`/`mab` = community, team, club, project, account, person); what is
  missing is the hierarchy and the memberships. Add a small
  `construct_links`/`construct_members` pair keyed by the app (name, with `aka`
  aliases), and derive the tree from `$gb::master_plan` at migration time. Do not
  duplicate the app rows into a second noun table.
- **Membership and roles.** A `construct_members` table
  (`construct, person_id, role`) with explicit verbs (owner/manager/member/
  viewer/guest). This is the `$gb::roles` that does not exist yet.
- **One authorization gate.** A single `can($principal, $verb, $row)` helper that
  every route calls. The current spread of ad-hoc privilege checks is the main
  correctness risk; adding a scope column without one gate will leak.
- **Construct scope on data.** Appointments and warehouse need a narrowest-scope
  column (or the missing construct columns), with ancestor resolution for reads.
  Keep the existing columns for the mail picker during migration.
- **A key decision.** With a thin client (community data stays on the community
  server) server-side ACLs may be enough. With a thick house (community data
  replicated to the house) per-construct keys are required. Decide thin/thick
  first; it sets how much crypto work P3 carries.
- **Scoped sync.** Full-table replication is correct for one person's devices and
  wrong for shared constructs across houses. Construct-scoped sync is a later,
  separate project.
- **UX**: a share gesture, a team view, a role admin panel, and a visible "who am
  I" (today the UI has one `me`).

Naming note: there is no `$gb::roles` in the tree today. If that name is meant to
hold the per-construct role matrix, create it as such; do not overload
`$gb::chairs`, which is only a rank.

Rough readiness: construct vocabulary ~60%; identity, authorization, keying and
sharing ~15%. This is a design-and-implementation project, not a configuration
change.

### Deployment model (from the discussion)

This is the working model:

- **House** = one person's machines, which is what the mesh already is:
  `signatorial` + `remote_machines` + the sync group. Give the house one owner
  person and one house keypair; its machines are peers.
- **Community** = the umbrella/host: the machine(s) that run club containers,
  keep the directory of clubs, and issue/verify tickets. A community of one club
  is still a community.
- **Club** = the business/tenant: its own server/container, database,
  `.house.key`, signatorial identity, port block (`PORT_AHOY`..`PORT_COMS`) and
  `~/.president`. Several clubs can live on one community host, one container
  each; the host owns TLS/reverse proxy, backups, monitoring and port allocation.
- **Team / project** = a construct *inside* a club container, not its own
  container at first. Scope rows, not processes. A team becomes its own
  container only if it is a separate trust/legal tenant; otherwise per-team
  containers force cross-container federation before the ACL exists.
- **Admission** = the club's governing role issues a signed ticket to a house.
  The ticket binds club/team, house pubkey/signatorial, person id, construct id,
  role, expiry and issuer; the house presents it, the club verifies it. The
  community host records the issuance and can revoke it.
  The substrate is already here: `signatorial`, `remote_machines.pubkey`,
  `peer_sign_request`/`peer_verify`, `paired_devices` challenge/response, and the
  `tickets` table. Extend the ticket rather than invent a new PKI.
- **Data placement** = personal data stays in the house; shared club/team data
  lives on the club server and is reached as a thin client. Do not replicate the
  club DB to every phone. That keeps one house key for personal data and
  server-side ACLs for shared data; per-construct keys are only needed if the
  club DB is replicated or the server/backups are untrusted.
- **Client** = each container is another JawnOS URL with its own ticket. A house
  can hold tickets to several communities; the v1 client can switch between them
  rather than federating their data. Cross-community sharing is a later
  federation protocol, not a same-DB merge.

A shared family/work computer is the same decision at a smaller scale: make it a
client holding several tickets, or run one container per person. Do not build
per-appointment visibility for a shared DB; if a household genuinely shares data,
treat the household as a small club/tenant with members and roles.

### Identity, UUIDs, and the active context (from the discussion)

**One person id, minted once.** A person is already an app (`pos`/`mab` =
person), but the app's `uuid` setting is per-device. Mint one canonical
`person_id` per person, store it on a small `people`/construct record, and keep
the app name + `aka` as aliases. That id is what a ticket, a membership row and
a record's `person` column carry. A person may be in several clubs/teams; the
same id is used everywhere. A house is admitted separately (`house_uuid` +
keypair), so a person can have a personal house and a work house, both bound to
the same person id.

**People column vs membership table.** Keep both, for different jobs:

- `appointments.person` (and `mailbox.person` where it already exists) says who
  the record belongs to or who acted. A record shared by several people needs a
  `record_people` join table (or a JSON list for a first cut).
- `construct_members(construct, person_id, role, since, until)` is the roster and
  the authority. Trust comes from this table plus the ticket, not from a people
  list on the record.
- Every write also records `construct`, `actor_person`, `actor_role` and the
  issuing ticket in the audit.

**Static UUIDs for settings.** The current row `uuid` is random per machine
(`db_insert` 15 chars, `setting_initializer` 20), so two machines that create
the same row independently produce two rows. A deterministic uuid fixes that,
but it is a migration, not a formatting change:

1. Classify every setting as **house-wide** or **per-device**. A single uuid
   shared by all machines is right for app config and construct links, and
   wrong for `me` rows, window geometry, open tabs and timers. `@gb::protected`,
   `@misc_settings` and `durable_settings_where` are the starting lists.
2. Canonicalize app identity first: one app uuid per house (it survives rename
   via `aka`), then row uuid = hash(app_uuid, setting, subsetting[, signatorial]).
3. Audit every stored reference. `sc_*` settings are JSON arrays of **app
   uuids** (`setting_setter` rewrites them on a `pos` change), so they must be
   rewritten in the same transaction; check `aka`, `nfc`, relational buckets and
   any other JSON list that stores a construct uuid.
4. Migrate on one machine with sync paused: update uuids, rewrite `sc_*`,
   tombstone the old uuids with `deletion_registration`, stamp
   `server_time = now`. Let peers pull, dedupe by the natural key for a
   transition window, then run the same check on every machine.
5. Only after the counts agree, add a unique index on the natural key. A
   pre-flight script should report duplicate natural keys, unresolved `sc_*`
   references and proposed collisions before anything writes.

**Active context (keyboard and writes).** The keyboard's `#accounts` and
`#projects` are viewer filters; they are not an authority. Add one explicit
scope, per browser tab: `Community > Club > Team > Project`, with Account and
Person as attachments. Show it as a breadcrumb above the keyboard with
`Home`/`All`; "All" means all within the active scope, never all in the
database. A write sends the narrowest construct (plus its ancestors) and the
actor; the server checks membership and role, stamps the record, and rejects a
scope the person is not in. When no scope is chosen, say **Personal**
explicitly. Switching a crumb or Home changes the scope for new appointments
and refreshes the open views; it does not rewrite existing records.

**Club as the tenant.** This is the clean reading of the discussion:

- Community = the umbrella/host; Club = the business/tenant and its container.
- Team (at least one per member) and Project live inside the club; Accounts and
  People attach to the club/team.
- A club membership must name at least one team; roles are per membership and
  inherit downward (a club manager can act on its teams, a team lead on its
  projects), never upward.
- Current `$gb::master_plan` is inverted (team > clubs > communities >
  projects) and must be re-rooted or replaced; `$gb::social_constructs` order
  (community, club, team, person, project, account) is closer to the new model.
- Per-team/project containers are only for separate trust/legal tenants; the
  normal case is scope rows inside the club container.

### Hosting strategy

Android/Linux-only houses are practical: the house is an appliance/server, and
every other platform is a browser/PWA client. This avoids the Windows native
rewrite and the impossible iOS house. The costs are native iOS integration
(push, BLE, background sync), App Store 4.2 for a thin WebView, and Android
Doze/battery if a phone is the always-on house. A community host or a small
Linux box is the reliable house; a Mac/Windows-only user can use WSL2 or a
club/community server. Being usable on Apple devices does not require beating
Apple.

### Recommended minimum shape (one club, several houses)

1. **Person = principal.** The person app is the principal; a ticket or paired
   device names it. Keep one canonical id per person (reused across houses),
   with names/`aka` as aliases.
2. **Constructs stay apps; hierarchy and membership are rows**: one table for the
   hierarchy, one for membership, roles as verbs.
3. **One gate**: every read/write resolves a row's narrowest construct upward and
   asks `can(...)`. No route compares `privilege` directly.
4. **Scope data by the narrowest construct**; a team view is a query, not a
   separate database.
5. **Decide thin/thick before keying.** Thin (shared data stays on the club
   server): server-side ACLs are enough. Thick (shared data replicated to
   houses): per-construct keys are required.
6. **Notifications target a construct + role**, not the global `citizen` role
   (`notification_sender` already takes a `role` key).

Do **not** fork a Perl tree or a SQLite database per team: cross-team views,
shared people, and the audit/recovery tools all assume one database. Scope rows,
not processes.

### Phases (rough, one developer)

- **P0 — identity + UUID pre-flight (2-3 weeks).** Mint one canonical person id
  per person; give each house a `house_uuid`; classify settings as house-wide vs
  per-device; write the audit for duplicate natural keys and `sc_*` references.
  No writes yet.
- **P1 — canonical UUIDs + membership (3-4 weeks).** Migrate app and settings
  uuids, rewrite `sc_*` and every stored construct reference, dedupe, tombstone
  the old ids; add `construct_members`; re-root `master_plan`; write `can()` with
  tests.
- **P2 — admission + context (2-3 weeks).** Extend `tickets`/`remote_machines`
  with house/person/construct/role/issuer/signature; issue and verify signed
  tickets at the club edge; add the scope bar and server-stamped writes.
- **P3 — scoped shared data (4-6 weeks).** Appointments/warehouse scope on the
  club server; route-by-route adoption of `can()`; team views; share control;
  construct notifications; audit entries. The bulk of the work.
- **P4 — federation, only if needed (months).** Per-team containers,
  per-construct keys, scoped sync between clubs/communities. Do not start here.

### Decisions needed before code

1. **Tenancy**: Club = the container/tenant, Community = the umbrella/host?
   Recommendation: yes; a community can run several club containers on one host.
2. **Hierarchy**: re-root `$gb::master_plan` to Community > Club > Team >
   Project, with Accounts/People attached. Recommendation: yes; the current
   plan is inverted.
3. **Person id**: one id minted once per person, reused across every club/team,
   with the house bound separately? Recommendation: yes.
4. **Static uuid key**: approve the classification of house-wide vs per-device
   settings before the migration. A wrong call here rewrites a lot of rows.
5. **Thin vs thick**: thin for community/club data, thick only for the house's
   own data? Recommendation: yes.
6. **Trust**: may a stolen club DB or a peer read everything, or are
   per-construct keys required with the first shared data?
7. **Shared device**: client with several tickets (recommended), or one
   container per person?
8. **iOS**: client-only (recommended), with iSH as a demo only?
9. **Windows**: WSL2 as the supported house, with Cygwin/MSYS2 as a spike?
10. **Hosting**: accept Android/Linux-only houses, with browser clients
    everywhere? Recommendation: yes.

## Cross-cutting

- **Help** — update each app's topic in the same commit as its UI, then
  `perl scripts/help_audit.pl`; the audit runs on push (`.githooks/pre-push`).
- **Version & restart discipline** — bump `./VERSION`, commit `v<version> - …`,
  push, then `printf 'restart' > ~/.president/status` and wait for `good`.
- **Selftest/home-away** — the phone gets stuck (timeline won't move) until the app
  is fully exited and reopened; investigate the websocket/reconnect path.
- **Access-denied errors** on laptop and phone (from an earlier session) — believed
  fixed with the session/secret pinning; re-verify if seen again.

---

### Quick file map for the phone/chat/mail work

- Routes: `Manager.pl` — `/manager/phone`, `/manager/phone/sync`, `/manager/phone/call`,
  `/manager/chat`, `/manager/email`, `/manager/pen`, `mail_checker`,
  `phone_directory`, `phone_names`, `ticket_request_known`, `email_receiver`.
- Shared helpers: `subroutines.pl` — `contact_normalizer`, `contact_matches`,
  `contact_apps`, `contact_lines`, `contact_line_label`, `phone_number_app`,
  `merge_setting_values`, `name_change_pairs`/`_apply`.
- Templates: `templates/apps/phone.html.ep`, `templates/apps/chat.html.ep`,
  `templates/mail/conversation.html.ep`, `templates/mail/mailbox.html.ep`,
  `templates/configure/appointment_list.html.ep`, `templates/appointment_wrapper.html.ep`.
- JS: `public/js/manager/phone.js`, `public/js/manager/chat.js`,
  `public/js/manager/configure.js`, `public/js/mailbox.js`.
- App release: `scripts/app_build.pl`, `scripts/app_release.pl`, `scripts/app_publish.pl`;
  repo `~/jawnos-app/termux-app` (`jawnos` branch, `fork` remote).
- Probes/scratch: `.shots/` (gitignored), ticket in `.shots/ticket.txt`.

### Quick file map for the shopping / market / receipt work

- Routes: `Manager.pl` — `/manager/market`, `/manager/market/item_add`,
  `/item_kind`, `/item_delete`, `/item_flag`, `/cancel`, `/checkout`, `/scan`,
  `/receipt`, `/receipt/apply`, `/need`, `/refresh`.
- Shared helpers: `Manager.pl` — `market_list`, `market_lists_*`, `market_item_due`,
  `market_upgrade_need`, `market_sweep_needs`, `market_barcode_*`,
  `market_receipt_*` (read/name-batch/lines/scan/store/file), `scanner_scan_command`;
  `subroutines.pl` — `warehouse_on_hand`, `warehouse_restock_for`,
  `warehouse_money_mirror`.
- Templates/JS: `templates/market/market.html.ep`, `public/js/manager/market.js`;
  the budget picker `templates/configure/budget_goals.html.ep`.
- The scanner is an OfficeJet 3830 (`hpaio:/net/officejet_3830_series`), feeds
  `ADF` + `Flatbed`, in `config.json`.
- The live receipt test used `.shots/receipt_probe.pl` (read) and the cleanup
  `.shots/receipt_cleanup.pl` / `market_restore.pl`.
- Snapshot recovery for a bad write: `subs::records_backup_decrypt` unseals
  `database/backups/jawnos_<ms>.enc`; **beware `subs::vacuum($app)`** —
  `delete_app` runs it and it wipes *all* of an app's settings when the app has no
  appointments and is not `permanent`.
