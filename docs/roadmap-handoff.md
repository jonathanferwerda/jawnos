# Roadmap / handoff

The remaining plan, as of **v0.1.525** (2026-10-16). Done work is marked so it is
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
choice in the transport dropdown; history under any of a person's numbers re-files
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
