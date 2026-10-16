# Roadmap / handoff

The remaining plan, as of **v0.1.534** (2026-10-16). Done work is marked so it is
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
and abilities within seconds and without a Scan.

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
  What was missing was the **link**, and the pieces for it are now in: the deck
  and the watch put `mac=<bluetooth>` in their `_jawnos._tcp` TXT, and the server
  keeps it in the device's `mac_addresses->{bluetooth}` (`mdns_merge_address`),
  which is the field `bluetooth_sender` connects the daemon with. The catch that
  remains: **nothing is on WiFi**, so nothing advertises mDNS - the deck's
  `/config.json` was wiped when its corrupt FFat was reformatted, so it has no
  credentials and `setup()` (which now joins WiFi when configured) never does.
  Onboard the deck (its AP form at `http://192.168.4.1:3000/`, or the phone app
  pushing WiFi over BLE the way the watch was onboarded) and the server will see
  it and can bridge it. The other route, needing no WiFi: have the bridge daemon
  **scan** for the NUS service and let the server adopt a fresh deck by radio -
  the natural "plug it in and it is known" flow, and the one to build next.
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

Still to do:
- **A real receipt through the ADF** — the paths are built and the model read a
  synthetic one; load a real receipt, press Receipt → Scan (ADF), and check a long
  one arrives as its pages in order.
- **A receipts view** — the kept receipts live in the Market app's own `receipts`
  setting (vendor, date, total, the lines, the page paths); nothing shows them
  yet. Give Market a small receipts pane that opens the pages and offers "add
  these lines to the list" again.
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
