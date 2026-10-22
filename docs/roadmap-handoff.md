# Roadmap / handoff

The remaining plan, as of **v0.1.796** (2026-10-18). Done work is marked so it is
not redone; everything unmarked is still to do. Keep this in step as items land.

---

## House key (next up)

The password is no longer a citizen login (v0.1.938), but it still unwraps the
vault. Phase 2 — a random `K_house`, wrapped to device keys, with the password
as a recovery share — is written up in
[`docs/house-key-phase2.md`](house-key-phase2.md). Do not demote the password
further until a `K_house` recovery drill passes.

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

## Phone — digital assistant (deferred)

**Not started (2026-10-22).** Goal: let the JawnOS Android app hold Android's
**Digital assistant** role and send the assistant trigger to the Guide. The APK
(`~/jawnos-app/termux-app`, branch `jawnos`) declares no `ACTION_ASSIST` activity
and no `VoiceInteractionService`, so JawnOS is not offered under Settings → Apps
→ Default apps → Digital assistant today.

Planned first cut (press-to-talk; no hotword):
- `JawnAssistActivity` (exported, `ACTION_ASSIST` + `CATEGORY_DEFAULT`,
  `Theme.NoDisplay`, `noHistory`, `excludeFromRecents`) starts
  `JawnWebViewActivity` with `jawn_assistant_listen` (or `jawn_assistant_ask`).
- `JawnWebViewActivity.injectLaunchExtras` hands those to the page through
  `window.__jawnLaunchExtras`; `help.js` grows `helpOpenAndAsk()` — open the
  Guide, clear `jawnos_help_coding`, then `helpChatIngest(text)` or `helpAsk()`
  with an empty box (the existing mic → `/manager/help/listen` →
  `whisper_transcribe` path).
- Dashboard **Permissions → Assistant** requests `RoleManager.ROLE_ASSISTANT`
  (API 29+), falling back to the voice-input settings on older/odd builds.
- Update the help topic; bump the APK `versionCode`/`versionName` and build,
  stage and publish per `~/jawnos-app/termux-app/AGENTS.md`.

Caveats recorded from the design pass:
- **No hotword.** "Hey Jawn" on the phone needs a `VoiceInteractionService` plus
  a hotword detector; the assist activity is press-the-assistant-trigger, then
  talk. It replaces Google/Bixby for that role and grants no extra permissions.
- **OEM pickers vary.** Some phones list only their own assistant plus Google;
  once the activity exists, the adb fallback is `adb shell cmd role
  add-role-holder android.app.role.ASSISTANT com.termux`.
- The assist intent does not reliably hand over a transcript; collect the
  request in the Guide. Selected text can be read from `AssistStructure` if
  wanted.
- The Guide needs a model under Configure → Plat → Agent models → Help guide;
  the mic path needs a **Transcription (speech in)** model.

**Transcription: Plat, not Android `SpeechRecognizer`.** The Guide's mic posts
raw audio to `/manager/help/listen`; `subs::whisper_transcribe` uses
`transcription_assistant` — local whisper.cpp or the configured cloud model.
`SpeechRecognizer` would instead use the phone's recognizer (usually Google),
return text only (no raw audio for Plat), send audio off the phone, and need its
own conversation/echo handling; it is not the chosen path.

**Streaming (not built).** Plat is a batch transcriber; the watch's
`voice_stream` only reassembles, then transcribes at the end. Near-streaming is
possible without a new engine: capture PCM in the WebView, send it over an
authenticated `/manager/help/stream` WebSocket, re-transcribe a rolling window
with the same Plat model every ~1–1.5 s, show **provisional** partials, and make
the final full-clip transcript authoritative. Guard one decode in flight, cap
30 s, drop silence hallucinations, and use local tiny for partials when the
configured model is cloud (or disable partials for cloud). This improves the
feel, not the final answer latency; a true streaming final needs a streaming
engine — sherpa-onnx/Vosk locally or Deepgram/AssemblyAI/Google/Azure — because
whisper.cpp has no streaming HTTP API. Repeated POSTs to
`/manager/help/listen` were rejected as the shipping design: each blocks a
manager worker and re-uploads the growing clip.

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
- **The padlock is a server-side gate now (P0, v0.1.802+).** Shadow logs what
  it would refuse; Enforce answers `423` and the locked page. The session-level
  work (P1/P2) below is what remains.

## JawnOS as the OS / session — the real gate

The padlock is the **only** thing between a person sitting at an otherwise wide
open desktop and every house record, so it cannot stay a browser overlay. Today
it is one: `authentication_passer` notices that `pl_time` has expired and calls
`lock_session`, but the request still returns its data underneath. Anything that
can reach `/manager/...` or hold the websocket reads the house behind the lock
screen. The old dial was 1,728 combinations and awkward with a mouse (it
committed only once the pointer passed the digit), and the phone QR was a bearer
token on a screen — a photo of it worked for 10–20 s. **Both are gone**
(v0.1.804): neither was a gate, so they were removed rather than polished.

Decision: **the session is the gate**. JawnOS boots to a greeter, then a
**Treeland (Wayland) session** whose lock screen is `ext-session-lock-v1`; jawn
runs as a **service under its own user**, and the UI talks to it over a socket
with peer-credential checks. A locked session **denies data**; it does not
decorate it. The camera/phone-image path the user likes stays as an **opt-in
fallback**, never as the only way in.

### Unlock: device signature only; the paper code is the emergency

The primary unlock is the phone already in the person's hand: a paired device
signs a nonce with the Ed25519 key it already has, and the server verifies it
against `paired_devices.pubkey`. No typing, no dial, nothing to photograph.

- Reuse `public/js/device.js` (non-extractable WebCrypto Ed25519 key in
  IndexedDB `jawn_device` / `device_key`) and `subs::signature_verify`.
- New message: `padlock-unlock\n<uuid>\n<nonce>`. Nonce from
  `POST /manager/security/padlock_challenge`, **single use**, **60 s**, bound to
  the device uuid and the requesting address; `POST /manager/security/padlock_unlock`
  verifies it, clears `pl_time`, and broadcasts `padlock_open` to every tab.
- Only a **paired, active** device may sign. Failures are logged and
  rate-limited (five per address per five minutes) so the nonce endpoint is not
  a free oracle; the dial's `padlock_pulls` stays separate.
- Only a **remote** device may sign: a request from this machine itself is
  refused (`padlock_request_is_local`), so the locked screen cannot open its own
  door with the key it holds. The paper code is the lost-phone path.
- A screen locking shows its own lock screen and no longer broadcasts the
  unlock page to every device (that auto-navigation added history entries and
  left images stale when a phone woke). The person presses **Unlock** on the
  locked screen; the house writes a short-lived request and prompts paired
  phones/laptops **in place**. The device that confirms keeps its page and
  history: it confirms with the app's native fingerprint prompt or WebAuthn
  where available (v0.1.816) and signs the nonce (v0.1.810) for the named
  screen. A phone that was asleep finds the request in `padlock_state` on its
  next connection and is never sent to another page. The taskbar padlock locks
  **this screen** with one tap and the **whole house** with a double tap
  (v0.1.816). A single-screen lock is a per-device row; a whole-house lock is
  the house stamp. Unlocking a screen after a whole-house lock gives that
  screen its own timer and leaves the others locked (v0.1.816). The inactivity
  timeout is the other whole-house lock.
- **The dial and the camera/QR key were removed in v0.1.804.** The dial's
  handler, the QR canvas, the rotation timer, the camera watch/poll and its
  `/frame` and `/active` routes are gone (the routes answer "disabled").
  `padlock_phone_show` only sends the request (and stores it for a waking
  device); it cannot unlock. The recovery code stays as the only other way in.

### Emergency: paper code **and** FDE (both)

- **FDE = full-disk encryption.** LUKS2 on the system disk: the disk is
  ciphertext without the key, so pulling the drive or booting a USB stick does
  not read the house. It does **not** protect a machine that is already unlocked
  and running — that is exactly the session gate's job — and it does not help
  against someone who knows the passphrase. Enrol the TPM2 for normal boots
  (`systemd-cryptenroll --tpm2-device=auto`) **plus** a passphrase for recovery.
- **Paper recovery code** is the app-level reset: one long random code, printed
  and kept offline, stored as a sealed verifier (it must unwrap the house key,
  so it cannot be a one-way hash), and accepted only at the gate with a
  per-address throttle. It clears the padlock; it does not decrypt the disk.

### Phases

**P0 — make the lock real (server-side).** This is the piece that matters even
before any compositor work, and it is small.
- Ship a **shadow gate** first (`padlock_gate=shadow`): compute the deny-list and
  log what it *would* block, while still serving. Flip to enforcing only after
  the log is clean and the paper unlock has been rehearsed. This is what makes
  P0 testable on the live machine without risking a lockout.
- Deny by default in `authentication_passer` / `hooks.pl` while `pl_time` is
  expired. Allow only: the lock page, the unlock endpoints, static assets
  (`/css`, `/js`, `/images`, `/icons`, `/sounds`, `/favicon`), `/manager/ws`,
  `/box_office`, `/manager/health`. JSON/XHR gets `423 Locked`; a document gets
  the minimal lock page. `/manager` itself renders the lock, not the app.
- Stop the **websocket** leaking while locked: no data fan-out to a locked tab
  (or drop the socket); the unlock broadcast is the first thing it sees.
- Device-signature unlock as above; keep `lock_session`'s early-return list for
  the watcher/key routes, and add every new polling route to it.
- Recovery code, and **test that path first** — deploy the gate only after a
  deliberate "lock it, unlock it with paper" rehearsal, so a bug cannot lock the
  user out of a running machine.
- Already done and kept: auto-show on the phone (v0.1.792), rejoin after sleep
  (v0.1.794), no re-expiry after a concurrent unlock (v0.1.793). The dial and
  the camera watch (v0.1.792) were removed in v0.1.804. A mobile tab that
  connects while a screen is locked reads `padlock_state` and opens the unlock
  page (v0.1.808), so a phone that slept through the lock still gets there. The
  page waits for the person to press **Unlock** (v0.1.810), so the house does
  not open itself while the phone is in use. A manual lock is a row per device
  (`security.level = padlock_device`) and the signature names the target
  (v0.1.811), so only that screen opens. Timers are stored as plain
  milliseconds, readable by every worker, with a decrypt fallback for old rows
  (v0.1.817); the gate reads them directly, with no one-second cache
  (v0.1.818).
  - Lock-screen polish (v0.1.821): the denial image is centred, a fifteen-second
    generated-art screensaver (with the house logo every twenty-two seconds)
    yields to any mouse or key, the locked page offers a local `fprintd`
    fingerprint, and the Android app carries a native `BiometricPrompt` bridge
    (app v0.118.49 / versionCode 1048).
- **Landed in v0.1.802.** Shadow logged real requests and still served;
  Enforce answered a document with `423` and the locked page; the dial (since
  removed) unlocked; the websocket drops data pushes while locked; a throwaway
  paired device completed challenge/sign/login and its valid padlock signature
  was refused as local.
- **Remote signature proven live in v0.1.804.** A throwaway key generated on the
  phone and paired from the laptop completed challenge/sign/unlock from
  `192.168.2.4`; the log recorded `padlock: opened by Phone Probe`, and the probe
  device was then revoked. The default is now **Enforce**, seeded at boot for a
  house that has a paper recovery code (so a fresh house cannot lock itself out).
  The paper-code success path stays unexercised because the existing recovery
  code was left untouched.

**P1 — greetd greeter.** Boot to **greetd** (no autologin) with a JawnOS greeter
that calls the same verifier over the service socket, then starts the session.
The greeter is one verifier with a second front end, not a second auth system.
- jawn becomes a **system service** in its own user; it owns `initial.db` and
  `~/.house.key`. The kiosk user cannot read them (`0700` home, `0600` key, DB
  directory not traversable by that user).
- Socket `/run/jawn/gate.sock`, mode `0660`, group `jawn-gate`; every request
  checks `SO_PEERCRED` (uid/gid) before answering.
- No TTY/VT escape to the data: other VTs either get no login or `nologin`, and
the service refuses a peer that is not in the gate group, so a shell on the
kiosk VT cannot read the house.

**P2 — Treeland session lock.** Use Treeland's own lock screen, or a small
client built on `ext-session-lock-v1`; idle timeout and an explicit lock, both
routed to the phone signature. On lock, signal jawn to expire the session and
invalidate web sessions, so the browser behind the compositor is denied too.
`treeland-debug` (`windows`, `screenshot`) is the test harness. If Treeland's
lock API turns out to be awkward, Sway/wlroots is the fallback — the verifier
and the service socket do not change.

**P3 — custody and at rest.** Service-owned key + peer checks (P1), LUKS/TPM
(above), and the signature as the only remote unlock. The dial and the camera/QR
key were removed in v0.1.804, so there is no fallback to refine: the paper
recovery code is the emergency, and the session gate itself is P1/P2.

**P4 — the image.** An archiso overlay built from `desktop/wayland/`: greetd +
Treeland + the jawn service + greeter/lock client, with FDE, the paper code, a
recovery USB, and signed updates. The desktop app then follows the code sync as
today.

**P5 — multi-user, only if needed.** The signature would have to name a *person*,
not just a device; that needs the canonical person id and per-person containers
from *Platforms & multi-user* below. Do not build it before P0–P2 are honest.

### Treeland findings (2026-10-18)

- `extra/treeland 0.9.1-1` in Arch; wlroots 0.20 + QtQuick.
- Ships a **lock screen** (`src/lockscreen/`, `src/plugins/lockscreen/`,
  `treeland-screensaver-v2`), a **greeter** (`src/greeter/`), and **ddm** as the
  display manager (recommended runtime dependency).
- Implements **`ext-session-lock-v1`** (headers under `/usr/include` in the
  Wayland/wlr/protocol set), so the standard lock client contract exists.
- `treeland-debug` can inspect windows, inject input, and screenshot — enough to
  drive the lock/unlock path in tests.

### Testing as it lands (and the ProDesk display)

Each phase is testable without committing the machine to it:

- **P0 is browser-only.** No boot or display change. Shadow gate first (above);
  keep an SSH session open, use a second browser profile to lock and unlock, and
  rehearse the paper code before enforcing.
- **P1/P2 are an added session, not a replacement.** Register a
  `jawnos-wayland.desktop` session and pick it at the display manager; keep the
  current X11/autologin entry as the default until it passes. From a TTY,
  `dbus-run-session treeland` (or `sway -c …`) is enough to try it.
  Ctrl+Alt+F2 and SSH are the way out.
- **`ext-session-lock-v1` is single-owner**: only the client that created the
  lock can unlock it. If the lock client crashes the session stays locked, so
  test with SSH open and be ready to restart the compositor.
- **P4** goes on a spare disk/USB (or a VM for everything but the monitor),
  never the only installed system.

**The ProDesk monitor.** `xrandr -s 1366x768` is X11-only; under Treeland it does
nothing. It also runs *after* login, so it cannot fix the greeter or the lock
screen — those start before any user script. Put the mode at the layer that
runs first:

- **kernel/GRUB**: `video=<connector>:1366x768@60` on
  `GRUB_CMDLINE_LINUX_DEFAULT` (find the connector with `ls /sys/class/drm/` on
  the ProDesk), plus `GRUB_GFXMODE=1366x768x32` and
  `GRUB_GFXPAYLOAD_LINUX=keep` for a clean console handoff. This reaches the
  greeter and the compositor.
- **compositor**: Sway `output <name> mode 1366x768`; Treeland's output config,
  or `wlr-randr --output <name> --mode 1366x768` to try it live in a session.
- If the monitor's EDID is wrong (the mode is missing rather than merely
  unchosen), use `drm_kms_helper.edid_firmware=` or an EDID emulator. Do **not**
  use `nomodeset` — Wayland needs KMS.

The dev laptop is already LUKS-encrypted (`cryptdevice=` in `/proc/cmdline`);
the ProDesk runbook (`docs/appliance-provisioning.md`) enables TPM 2.0 for
auto-unlock.

### Decision (settled, 2026-10-18)

The strict model was confirmed: **server-side gate + paired-device signature as
the primary + paper code and FDE for emergencies.** P0 is built. The dial and
the camera/QR key were removed in v0.1.804; the signature is the only remote
unlock, and it opened the live house from the phone in the same release. The
gate now defaults to **Enforce** for a house that has a paper recovery code;
Shadow remains available to check the deny list first.

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

The product is the **house**: a bundled app that runs the Perl tree and SQLite
on the device. The WebView is the house's own UI, not a separate client. "No
clients" means every supported platform needs a house app; the browser is a
fallback, not the product. That makes the port matrix a house matrix.

### Port readiness

| Platform | Browser UI today | House today | Real gaps |
| --- | --- | --- | --- |
| **Linux** | yes | yes — reference target | none; `desktop/` is the house app |
| **Android** | yes (WebView) | yes, via the Termux fork | Play Store policy (sideload only); the native replacement of termux APIs is already roadmap work |
| **macOS** | yes | likely, untested | `/proc` reads, `shred`, `timeout`, `xclip`, `ip`, `systemd`; Homebrew for `ffmpeg`/`magick`/`tesseract`/`qrencode`/`nmap`/`sox`; GTK desktop shell is Linux-only |
| **Windows** | yes | no | `fork`/PTY, AF_UNIX IPC, POSIX shell, `/proc`, signals. WSL2 sidesteps all of it; native needs a process/IPC layer |
| **iOS** | yes (Safari) | **foreground only** | no Perl runtime, no long-lived background listener; iSH runs Perl but iOS suspends it; a true house is a Swift local-first rewrite |

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
3. **iOS house** — iSH can run Perl and is worth a spike, but iOS suspends the
   app, so it is a foreground house, not an always-on one. A real iOS house is a
   Swift local-first rewrite (same schema, native UI, background sync via the
   OS), not the Perl tree. Choose one; do not call it a client.
4. **Desktop house apps** — the Windows/macOS supervisors are part of the house
   app, not separate clients. `desktop/README.md` already names the Windows work
   (`core_win`, WinRT BLE); macOS needs its own supervisor shell
   (PyGObject/GTK via brew is not a good answer).

### Multi-user readiness

**The vocabulary exists; the boundary does not.**

What is already in the tree:

- `$gb::social_constructs` (`gb.pl` 217) defines six dimensions — communities,
  teams, clubs, projects, accounts, people — each with a singular name, a
  default, and a picker order.
- `mailbox` carries all six as columns (`database/schema.sql` 69); `appointments`
  carries only project/club/account (line 22); `warehouse` carries
  project/account. So **only mail is fully construct-keyed today**.
- *(2026-10-21)* The tuple grew to eleven — communities, clubs, teams, people,
  projects, institutions, governments, corporations, places, vendors, events —
  and `accounts` was retired as an address coordinate (its mail column stays
  for rows already filed under one). The mailbox reader, the list, delete, the
  websocket filer, the depublicizer and `/watch/chat_received` all derive the
  tuple from the hash now, and the People app grows a tab per kind on its own.
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
- **A key decision.** "No clients" forces the thick path: shared data is
  replicated to member houses, so per-construct keys are required and each house
  enforces `can()` against a signed roster. The only real choice is whether
  member houses are trusted to enforce it, or the roster arrives as signed deltas
  so a house cannot grant itself a role.
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
- **Team / project** = a construct *inside* the tenant container (the club, or
  the top-level `team` per `master_plan`), not its own container at first. Scope
  rows, not processes. A team becomes its own container only if it is a separate
  trust/legal tenant; otherwise per-team containers force cross-container
  federation before the ACL exists.
- **Admission** = the club's governing role issues a signed ticket to a house.
  The ticket binds club/team, house pubkey/signatorial, person id, construct id,
  role, expiry and issuer; **any house verifies it offline**, and the community
  host records the issuance and publishes revocations as signed deltas. The
  substrate is already here: `signatorial`, `remote_machines.pubkey`,
  `peer_sign_request`/`peer_verify`, `paired_devices` challenge/response, and the
  `tickets` table. Extend the ticket rather than invent a new PKI.
- **No clients** = every device runs a house app; there is no thin browser
  client. The app bundles the tree, the database and the UI (a WebView to
  localhost), and the house is a peer of the club/community containers.
- **Data placement** = personal data stays in the house; shared club/team data
  is **replicated to member houses** (thick), because a house must work offline
  and cannot ask a server to render a view. That makes per-construct keys and
  scoped sync mandatory, not optional, and every house enforces `can()` locally.

A shared family/work computer is the same decision at a smaller scale: run one
house container per person, or one house with multiple people. Do not build
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

**Stabilize the app identity value, not the row uuid.** There are two uuids:

- `settings.setting = 'uuid'`, `value = <uuid>` is the **app identity**; it is
  what `sc_*` arrays and `settings_grabber({ uuid => ... })` reference. This is
  the value to make one-per-app across every machine.
- `settings.uuid` is the **row handle** used by sync/merge. Leave it random; it
  is a finder key, not an identity.

So the migration is much smaller than rewriting every row:

1. Pick one canonical app identity per app (the oldest/server copy), update the
   `uuid` setting on every device to that value, and rewrite every reference:
   `sc_*` JSON arrays, any stored `cx_uuid`/construct value, and derived caches
   (`relational` buckets/bubbles). `aka` holds names, not uuids; `nfc` holds
   appointment/file uuids, not app identities, so check them but do not rewrite
   them blindly.
2. Stop minting divergent identities. `settings_grabber` currently creates a
   `uuid` setting when the current device lacks one; it should first look for
   the app's identity **on any device** and reuse it, minting only when none
   exists. `setting_initializer` should do the same.
3. Use the app's `unique` flag (Configure -> appointment list: visible/unique/
   permanent) as the per-device signal. `unique = checked` means the app's
   settings are device-local (the restart commands on a phone vs a computer),
   and `merge_table_rows` already refuses to take them from a peer. Keep those
   rows per-device; do not force one shared value. `@gb::protected` and the
   sync-excluded settings (`open_tabs`, `scrollTop`, `jopen`, `dimensions`) are
   the other device-local cases.
   **Caveat:** `merge_table_rows` skips **all** settings for a `unique` app,
   including the `uuid` row. Make the identity row (and `pos`/`mab`/name/`aka`)
   an exception that always merges; only the app's operational settings stay
   device-local, or `unique` apps such as "restart" keep divergent identities.
4. Verify: one app identity per app, every `sc_*` reference resolves, no two
   devices hold different identities for the same app, and a `unique` app still
   has its per-device values. Row uuids stay as they are; the merge path changes
   only to let the identity row through.

**Active context (keyboard and writes).** The keyboard's `#accounts` and
`#projects` are viewer filters; they are not an authority. Add one explicit
scope, per browser tab: `Community > Club > Team > Project`, with Account and
Person as attachments. Show it as a breadcrumb above the keyboard with
`Home`/`All`; "All" means all within the active scope, never all in the
database. A write sends the narrowest construct (plus its ancestors) and the
actor; the house checks membership and role against its signed roster, stamps
the record, and rejects a scope the person is not in. When no scope is chosen,
say **Personal** explicitly. Switching a crumb or Home changes the scope for new
appointments and refreshes the open views; it does not rewrite existing records.

**Club as the tenant.** This is the clean reading of the discussion:

- Community = the host/umbrella; Club = the business unit, and the container is
  set up for its teams/projects/accounts/people. If the top-level `team` in
  `master_plan` is the actual business, the container boundary follows that
  level instead; confirm the mapping.
- If a club is a business, a member is in at least one team below it; roles are
  per membership and inherit downward, never upward.
- `$gb::master_plan` is the authority. The earlier "inverted" note is
  withdrawn: take its nesting as the hierarchy and map the words onto it (the
  top-level `team` nodes are the governing layer; `clubs`, `communities` and
  `projects` nest below). `$gb::social_constructs` order is only the picker's
  display order, not the hierarchy.
- Per-team/project containers are only for separate trust/legal tenants; the
  normal case is scope rows inside the club container.

### Hosting strategy

"No clients" means every platform needs a **house app**, not a browser tab:

- **Linux** = the reference: app + tree + LXC per club/community container.
- **Android** = already a house app (Termux fork + dashboard); Doze/battery make
  it a personal house, not an always-on server.
- **macOS** = keep Perl; the house app is a supervisor + WKWebView; the remaining
  port is `/proc`, `shred`, `timeout`, `xclip` and the Homebrew tool set.
- **Windows** = WSL2 (supported) or Cygwin/MSYS2 (spike) until a native
  process/IPC layer exists; LXC is not native, so containment is the VM/app
  sandbox.
- **iOS** = the hard one. iSH can run Perl but iOS suspends the app, so it is a
  foreground house, not an always-on one. A true iOS house is a Swift local-first
  rewrite (same schema, native UI, background sync via the OS), not the Perl
  tree. Containment does not solve the OS lifecycle.

Being usable on Apple devices still does not require beating Apple; it requires
deciding whether iOS gets a foreground iSH house or a native local-first one.

### Hardware classes (manufacturing)

Four device classes, matching the mesh's existing shapes:

- **Embedded** — ESP32 / Pico 2 W firmware (`jp/`, `jt/`, `jw/`). It is not a
  house host; it advertises `_jawnos._tcp` / BLE and is driven by a house. This
  is the easiest to brand: use a pre-certified module, design the carrier board
  and enclosure, and keep the module's antenna and grant conditions. Say
  "Powered by ESP32/RP2350" under the vendor's brand rules; you cannot call the
  chip your own.
- **Mobile** — the house app on Android. The clean path is AOSP without GMS,
  your app preinstalled as a system app, and your own OTA; that sits outside the
  Play/sideload verification path. A GMS-certified phone pulls you into Google's
  OEM terms. Voice telephony needs carrier certification (PTCRB/GCF, VoLTE,
  E911); a Wi-Fi/data-only handheld avoids most of it. Designing a phone from
  scratch is an ODM business, not a first product.
- **Computer** — a mini-PC/SBC appliance: buy components, integrate, install
  the house image, brand and warrant it. This is the natural first hardware
  product and the physical form of "no clients."
- **Server** — the same appliance with ECC/RAID/rack options and LXC per
  club/community. Start as a software SKU on the computer, not a separate board.

Order: computer/server appliance -> embedded carrier boards -> mobile via ODM.
Do not do all four at once.

Compliance is the real gate, not assembly:

- A pre-certified radio module simplifies FCC/ISED/CE-RED, but the final product
  still needs EMC/safety testing and the module's integration/label conditions;
  budget a test house per product and region.
- Branding the final product makes you the manufacturer of record for
  compliance, warranty and liability, even when a contract manufacturer builds
  it. Product liability insurance and an RMA/spares plan are part of the
  product.
- Android without GMS means no Play/FCM; the house already speaks WebSockets,
  but background delivery on a phone is an OS problem, not an app one.
- Batteries add UN38.3/IEC 62133; laptops add thermal/safety work; phones add
  carrier certification. Start with mains-powered, fanless appliances.
- Ship review includes GPL/firmware licences and privacy (the house holds
  personal data), and secure boot / signed OTA for every shipped board.

The software already has the shape: `@device_types` is the three house hosts
(mobile/computer/server), and embedded is the fourth mesh class (`jw`/`jt`/`jp`),
which does not run the Perl tree. Add `embedded` to inventory/capability
reporting, not blindly to the manager's `@device_types` loops.

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
5. **Thick is forced by "no clients."** Shared data is replicated to member
   houses, so per-construct keys and scoped sync are required; each house
   enforces `can()` locally against a signed membership graph.
6. **Notifications target a construct + role**, not the global `citizen` role
   (`notification_sender` already takes a `role` key).

Do **not** fork a Perl tree or a SQLite database per team: cross-team views,
shared people, and the audit/recovery tools all assume one database. Scope rows,
not processes.

### Phases (rough, one developer)

- **P0 — identity + identity pre-flight (2-3 weeks).** Mint one canonical
  person id per person; give each house a `house_uuid`; audit the app identity
  values, duplicate app identities and `sc_*` references; use the app `unique`
  flag to mark device-local settings. No writes yet.
- **P1 — app identity + membership (3-4 weeks).** Canonicalize the app identity
  value (not row uuids), rewrite `sc_*`/stored references, fix the mint path;
  add `construct_members`; take `master_plan` as the hierarchy; write `can()`.
- **P2 — admission + context (2-3 weeks).** Extend `tickets`/`remote_machines`
  with house/person/construct/role/issuer/signature; make tickets verifiable
  offline; add the scope bar and house-stamped writes.
- **P3 — scoped shared data + keys (4-6 weeks).** Appointments/warehouse scope in
  each house; route-by-route adoption of `can()`; team views; share control;
  construct notifications; audit entries; per-construct keys and scoped sync so
  a replicated club DB is readable only by its members. The bulk of the work.
- **P4 — more containers / cross-club federation (months).** Per-team
  containers and cross-club sharing. Only if a trust/legal boundary demands it.

### Decisions needed before code

1. **Tenancy boundary**: is the container the club, or the top-level `team` in
   `master_plan`? The nesting is authoritative; the container follows the level
   that owns the business.
2. **App identity**: one identity per app across every device, even for an app
   with `unique` checked (`unique` governs settings, not identity)? The
   recommendation is yes.
3. **Canonical copy**: when two devices already disagree, which one wins (the
   oldest row, the server, the one with references)?
4. **Person id**: one id minted once per person, reused across every club/team,
   with the house bound separately? Recommendation: yes.
5. **Trust**: since there are no clients, may a member house enforce `can()` on
   its own copy, or must membership rosters arrive as signed deltas (with
   per-construct keys) so a house cannot grant itself a role?
6. **Shared device**: with no clients, a family/work computer runs several house
   containers (one per person) or one house with multiple people?
   Recommendation: containers.
7. **iOS**: foreground iSH house, or a native Swift local-first house that uses
   the same schema but not the Perl tree?
8. **Windows**: WSL2, Cygwin/MSYS2, or the native process/IPC layer? And in what
   order do those platforms ship relative to Linux/Android?

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
