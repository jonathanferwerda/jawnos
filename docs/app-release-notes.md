# JawnOS app release notes

The body of the GitHub release (`releases` tag). `scripts/app_publish.pl` reads
this file, adds the release date and the version codes that are actually
staged, and writes it back to the release. Keep the newest release at the top
under a dated heading; older sections stay as history.

## 2026-11-19 — each app's notification stands on its own

- **A notice's app names its channel.** Mail, Clock, Market, Scan, Security and
  the rest each get their own notification channel, so each has its own sound,
  importance and badge in Settings instead of sharing one JawnOS switch. The
  app channels start at their defaults; the old JawnOS channel still governs a
  notice that names no app.
- **It wears its own icon.** A small envelope, clock, cart, scanner, calendar
  and so on replaces the house mark in the status bar, chosen from the app that
  sent the notice. The large picture the notice already carried is unchanged.
- **It no longer shares the JawnOS bundle.** Each app has its own group, so mail
  stops folding in with a Clock alarm or a Market receipt. Two or more waiting
  notices from one app collapse under a header named for that app ("Mail");
  a single notice is left uncollapsed so it stands on its own.
- **A dismissed notice takes its header with it.** When the last notice in a
  group is swiped away, tapped, or removed by the manager, the group header is
  pruned instead of lingering.
- **Home tiles wear the count.** The JawnOS row on the launcher badges each app
  with the notices waiting for it, read from the house's own database. An app
  with notices that the start menu does not list gets its own tile, so an
  appointment app's start/stop stands with its own count; the tile wears the
  newest notice's picture when it has one, and a shared or sealed picture falls
  back to that app's own colour and initials. Answering or clearing the notice
  clears the badge on the next visit to Home.
- **A sealed photo reaches the notification.** A notice with a sealed main
  image decrypts it in memory for its Android large icon and carries the JPEG
  over the device bridge; the `.enc` stays sealed and no plaintext thumbnail is
  cached.
- **The shade still says JawnOS.** Android attributes a notification to the
  package that posted it, so the header line and the launcher badge remain
  JawnOS; a second APK would be needed to change that. Build 1349.

## 2026-11-17 — the alarm face stays until it is answered, with a five-minute backstop

- **A ring stays until it is answered, or five minutes.** Dismiss or Snooze ends
  it at once, and an alarm nobody answers now stops after five minutes instead
  of sounding all day. Its face stays in front of the phone for that whole
  time. The Clock window's ring card follows the same rule and comes down only
  when the server confirms the answer or its own five-minute guard runs out, so
  a failed Dismiss no longer pretends the alarm is over.
- **Home cannot hide the ringing face.** Pressing Home or opening another app
  while the alarm is still sounding brings the alarm screen back. A screen that
  is off is left off, and a face that has been answered (or timed out) never
  returns.
- **Volume down is a snooze.** A hand can quiet a ringing alarm in the dark
  without finding the screen. A Math or NFC gate still stands in the way, just
  as it does for the tap.
- **A snooze is visible in the Clock app.** The sleeping alarm's row wears a
  Snoozed badge, its countdown names the next chime, and a Dismiss button sits
  in the row, so the snooze can be called off as soon as the app is open.
- **A missed Dismiss cannot leave the phone ringing.** While an alarm sounds,
  the app watches the house's own ring record and stops when it says the ring
  is over, even if the dismiss broadcast was frozen or lost. A dismiss also
  cannot re-arm the moment that just ended.

## 2026-11-15 — the house rings, and pictures arrive

- **The Phone app's ringtone is the house's.** A new Ringtone pane (Ring, Chime,
  Sonar) saves the choice for this phone; the app plays it on the incoming call
  and the house's own notice stays quiet. A call that rings through now writes
  its appointment at the ring, so the Alarm loop can fire for a live call
  instead of waiting for the hangup.
- **Inbound MMS reaches Chat.** The app reads the phone's MMS store
  (`mms.list`), and the house files the text and each media part into the
  conversation, deduped by the carrier's message id. A five-minute poll files
  pictures that arrived while the app was away.
- **Group MMS names its people.** The app returns every address on an inbound
  MMS; the house marks the group and shows "with <people>" under the bubble.
  The thread still belongs to the sender; a true group thread is the next step.
- **Inbound pictures get a preview.** A media part is shrunk to a 320 px
  thumbnail before it is sealed, so the Chat bubble draws a small picture even
  when the house's upload thumbnails are off.
- **A live ring fires the alarm path even when the caller's app has
  notifications off.** The notice stays silent (the phone's ringer owns the
  sound), so it appears in Notifications without a second ring.

## 2026-11-14 — the alarm face outlives an update, and opens unlocked

- **The alarm screen no longer depends on the permission Android resets.**
  `USE_FULL_SCREEN_INTENT` is a special access on Android 14+, and Android
  revokes it on every APK update for a sideloaded build — the reason the
  lock-screen grant had to be turned on again each time. The alarm face now
  uses **Display over other apps**, which is granted once, persists across
  updates, and is the exemption Android needs to open an activity from the
  background. The full-screen intent remains a bonus; the ring notification
  offers the overlay grant (not the lock-screen switch) when it is missing.
- **The alarm screen comes to the front when the screen is already on.**
  Previously the direct start was attempted only when the phone was locked or
  asleep, so an alarm that arrived while the phone was in use sat in the
  notification drawer. It is now asked for on every screen state; the overlay
  grant is what lets Android honour it while unlocked.
- **A skipped day stays skipped.** The phone's already-queued AlarmManager wake
  checks the schedule file before sounding: if the next alarm has moved (a
  skip, a dismiss, an edit or another machine's change), the stale wake is
  ignored. Two Skip taps also get one request file each instead of overwriting
  the same file, and a stale half-hour notice can no longer name a day the
  alarm does not fire on.
- **A lost grant is offered once per update.** If an APK update leaves the
  overlay or notification grant missing, the dashboard opens the permission
  screen once for that version instead of waiting for an alarm to be missed.
  The permission screen names overlay as the alarm grant, adds the
  **Alarms & reminders** page for exact timing, and keeps the full-screen
  intent as optional. Exact alarms now fall back to a doze-surviving inexact
  wake rather than failing to arm at all.

## 2026-11-11 — the tailnet server is an admin setting

- **The control URL is no longer built into the APK.** The dashboard's Tailnet
  card has a **Tailnet server** field. It stores an `https://` URL in the
  device's `jawn_tailnet` prefs, rejects anything without a host, and the
  tunnel reports `needs_server` until it is set. Moving the Headscale switch no
  longer needs a new APK.
- **Provisioning accepts the server too.** The adb broadcast now takes
  `--es control_url <url>` alongside `auth_key`, so a device can be pointed at
  the new switch and joined in one command.

- **A phone that was asleep is not ambushed by the sign-in screen.** The view's
  one-ticket fallback stayed spent after its first recovery, so the next lapsed
  session - the cookieless first request a woken WebView sends - went straight
  to the logo splash, with **Try again** as the only way out. The fallback now
  re-arms whenever the manager itself loads, so every lapse gets its own ticket
  handover and the splash stays only the escape hatch for a ticket that can no
  longer sign in.

## 2026-11-10 — the browser opens again, and a site visit stays one appointment

- **Browse opens on a phone again.** The browser runs in its own process, and
  its WebView data directory has to be named before the WebView provider loads.
  The application was loading the provider first (to set the remote-debugging
  flag), so the browser's suffix call came too late; both processes then shared
  one data directory, which the WebView refuses with "Using WebView from more
  than one process at once with the same data directory is not supported." The
  suffix is set in the application now, before the debugging flag, for the
  browser process only.
- **A page-to-page move is still the same visit.** The site tick used to stop
  the mapped appointment after a quiet gap and start a new one when spans
  resumed, so moving around a site produced several appointments. The desktop
  browser also closed its site span on every URL change. Both keep the visit
  now: the desktop span follows the site, and a stop the tick made is reopened
  as the same appointment when the site returns within two minutes. A person's
  own stop is never reopened.
- **Subdomains belong to the site.** A span carries its full host in its URL,
  so marketplace.facebook.com counts for the facebook.com assignment; an
  explicit assignment to that subdomain wins over the site's.

## 2026-11-06 — a refused call holds a silent line, then ends

- **A refused call is answered and held for four seconds before it is ended.**
  The `reject` flow used to answer and hang up in the same breath, which some
  carriers read as a call that never connected and sent the caller to
  voicemail anyway. `JawnInCallService.refuseAtNetwork` now answers the call,
  keeps it up for four seconds, and disconnects; the caller hears nothing in
  that window because the phone's microphone is muted for the whole hold and
  the call is never routed to the Bluetooth gateway. A different call answered
  during the window cancels the pending disconnect, and the refused call is
  still filed as ignored, never as answered. The `voicemail` flow and the
  manual Decline button are unchanged.

## 2026-11-06 — the screening face names the caller, and the app installs again

- **The screening face says who is calling.** The gateway's status now carries
  the phone's caller id, and the face paints *Call from: <name or number>*
  above the live transcript. A caller in the house's records is named; anyone
  else shows as their number.
- **The build in the store installs over the one on the phone.** 0.118.296 was
  built with the development keystore: correctly numbered, published, and
  refused by every phone already running a release build (`SIGNATURE_MISMATCH`).
  0.118.297 is the same code signed with the house's release key. The build
  script now defaults to that key and checks the artifact's certificate before
  staging, so a wrong-identity build cannot ride the mesh or GitHub again.

## 2026-11-04 — Back puts the keyboard away first

- **Back hides the manager's keyboard before it leaves the screen.** The
  on-screen keyboard is part of the page, not an Android input method, so the
  WebView's Back press walked history and took the person out of the app. On
  the manager page and in an app window, Back now hides the keyboard when it is
  up; the next press walks the history (or the app's own back steps) as before.

## 2026-11-03 — the alarm at the level you chose, and answerable anywhere

- **The alarm sets the phone to the Clock's volume, then puts it back.** The
  player still asks for Android's alarm channel, so Do Not Disturb and the
  ringer's alarm rules still apply. Instead of forcing the alarm stream to
  maximum, the app moves it to the alarm's own Volume for the ring and restores
  the previous alarm-stream step when the ring ends - Dismiss, Snooze, a timer
  finishing, or the five-minute guard. A 30% alarm is 30%, and the phone is left
  where the person had it.
- **Timers get the same Volume.** A timer's creator now has a Volume slider, so
  its chime uses the same phone alarm channel at the level chosen instead of a
  fixed 70%, and the previous alarm volume comes back when the chime finishes.
- **Computer alarms set the machine's output volume too.** On a computer with
  `pactl`, `wpctl` or `amixer`, an alarm moves the machine's own output volume
  to its Volume for the ring and restores the previous level on Dismiss,
  Snooze, a timer finishing or the five-minute guard. A machine with no mixer
  keeps the old sox scaling.
- **Every open Manager window shows the ring card.** The card's duplicate
  guard lived in localStorage, which every window on a machine shares, so only
  the first window to hear the push drew it. Each window now keeps its own
  guard. A ring also tells the other machines, so a Manager window on another
  device draws the same card; Dismiss and Snooze then reach every machine.
- **Alarms can open over the lock screen again.** The move to targetSdk 36 made
  `USE_FULL_SCREEN_INTENT` a special access that a sideloaded build can be left
  without, turning the full-screen alarm into a heads-up notice. The ring
  notification now offers **Allow over lock screen** when the permission is
  missing, the dashboard's Grant device permissions screen has the same page,
  and a locked phone is asked for the alarm face directly as a fallback.

## 2026-10-31 — appointment photos that land

- **A photo from an appointment's Details view no longer ends in HTTP 500.**
  The capture itself worked and the JPEG reached the phone's folder, then the
  OCR step ran `tesseract`, found no output (the Termux image ships without
  it), and read the missing `.txt` - which raised the request into a 500 before
  the appointment row was updated. OCR is now optional: no engine or no text
  means no text, never a failed capture. The same guard covers an upload.
- **The app camera hands back a file, not megabytes of base64.** A normal
  phone photo travelled through `evaluateJavascript` as base64, which the
  WebView's binder cannot carry, so the camera opened and the result never
  arrived. It now stages the capture in the shared Termux home
  (`.jawn/captures`), returns only the path, and the manager moves it into the
  appointment's folder. Videos travel the same way.
- **The wrapper's native camera files onto its appointment.** It used to post
  with only an app name, which created a new row instead of adding the picture
  to the appointment the button belongs to. It now names the app's newest row.

## 2026-10-29 — NFC tags that fit, and a write that lands on the first tap

- **A tag payload that fits.** An appointment tag used to carry the whole
  settings row - its action, tap count and stored serials - 150 bytes and
  growing with every tap. That overran a 144-byte NTAG213, so a write worked on
  a larger tag and failed on a small one, or stopped working once a tag had
  been used enough. A tag now carries a short twelve-character tag id, and the
  manager finds the row by it; tags written the old way still read by their
  full uuid.
- **The first tap writes.** Android's reader mode reports a tag once per
  presence, so arming a write while the tag was already resting on the reader
  waited for a tag that never came again - the tag had to be lifted and
  re-tapped. The bridge restarts reader mode when it arms a write, so a present
  tag is written straight away. A write that is abandoned now expires and can
  be cancelled, so it cannot quietly overwrite the next unrelated tag tapped.
- **A writer that never wedges.** A failed or timed-out write clears its state
  and re-arms the reader, and the tag card shows "Hold the tag to the phone",
  "Tag saved" or the reason it failed. A reader mode that reports one presence
  twice now acts only once, and a tag seen during or just after a write is not
  mistaken for a tap.

## 2026-10-28 — upright clothesline pictures and the app's own title bar

- **Upright icons.** A camera photo keeps its pixels in the frame it was
  stored in and carries an EXIF orientation tag; Android's decoder ignored the
  tag, so the portrait main images (Vape, Coffee, Programming) lay on their
  side in the clothesline. The launcher now applies the tag before drawing the
  tile, and decodes at a quarter size first, so the row costs less memory than
  it did.
- **The title bar is back in the single-app view.** Opening an app from Home
  keeps the window's own title bar - its icon and its name - so a custom app
  is identifiable at a glance. Its window buttons are left out: Android's Back
  leaves the app, and closing the only window would strand the view on the
  desktop the manager hides.

## 2026-10-28 — the vault fills a whole form, and the keyboard fits its window

- **One keyboard, not two.** The input method now loads the manager's own
  `/manager/keyboard/ime` page - the same `soft_keyboard` fragment and script
  the dock uses - so the layouts, shift, calculator, symbol page, magnified key,
  hold-to-delete and conversion row cannot drift apart. It signs in with the
  app's session (or the saved ticket), and falls back to the bundled keyboard
  when the house is unreachable, retrying the manager page on the next field
  once it is back. On a house with app access enforced it waits for the JawnOS
  app's own sign-in and keeps the bundled keyboard usable until then.
- **The keyboard fits its window.** Its WebView is the dock's height above the
  system navigation strip, so the last key row is no longer behind the gesture
  bar and the focus machinery cannot scroll the page away from the keys. The
  fallback keyboard fills its window too.
- **Dictation in the keyboard.** The microphone is offered in the input method,
  not only the dock: it uses the manager's own `getUserMedia` +
  `/manager/dictate` pipeline, and the phrase lands in the focused Android
  editor through the same insert path as the keys.
- **The vault.** The house gains a `credentials` table - the non-secret scope
  (app, origin, kind, label, hints) beside a payload sealed with the house key -
  and it syncs with the house like any other record. The keyboard bar's key
  fills the focused field from a saved entry, or opens a save drawer typed into
  with the keyboard's own keys; the Manager dock fills every field in the same
  form. Entries are offered only to their site or app package and are refused
  while the house is padlocked.
- **Android autofill.** `JawnAutofillService` is the other half: Android hands
  it a whole screen's form and a page's domain, so one dataset fills the
  username and password together in Chrome and other apps, and the system save
  prompt files a new password (Chrome keeps its own manager and never asks the
  service to save). It talks to the manager over loopback with the app's
  session and trusts the house certificate for that host only. A browser's
  native toolbar has no web domain and is never offered the password. Enable it
  once from the dashboard's Keyboard card.
- **Home icons.** The clothesline and the JawnOS row now take each app's picture
  from `/apps/icon` - the person's main image, else the active icon set's glyph
  - cached for a minute so the ten-second poll does not refetch. Android cannot
  decode the sets' SVG, so those are served as PNG; an app with no icon keeps
  the initial-in-a-colour-circle tile.

## 2026-10-27 — Home NFC, named Recents cards, Browser + Search, and the JawnOS keyboard

- **Home NFC.** The home screen reads NFC tags through Android's reader mode and
  posts the same tap the manager's Web NFC shim would, so a start, stop or
  command tag works from the launcher without opening the manager first.
- **Recents.** A JawnOS app opens in its own task, so Android's Recents shows a
  card named for the app instead of one manager entry. An "Opening <app>"
  cover holds the screen while the manager boots; the chrome is hidden as the
  page finishes, and the poll runs every 100 ms.
- **Search from the Browser.** The tabs row gains + Search: it asks the house
  for the page's OpenSearch template (or the search parameter already in its
  address) and adds the site to Search's engines. Search's gear panel switches
  engines on and off, and a custom engine can be removed there.
- **JawnOS keyboard.** The JawnOS IME is now the manager's own keyboard drawn
  as an HTML page in a WebView: the light panel, white keys with a soft edge,
  grey specials and the yellow return, with abc / 123 / #+= pages and a number
  page that comes up by itself in a number field. Enable it once in Android's
  settings from the dashboard's Keyboard card; the desk's own dock still
  serves JawnOS apps.
- **Home search.** The home screen no longer raises the keyboard by itself when
  it returns from an app, and Enter hands the words to the manager's Search app
  instead of only filtering the installed list.

## 2026-10-26 — launcher, single-app windows and the printer widget

This build makes the app feel like the system it is meant to be, rather than a
browser wrapped around the manager.

- **JawnOS home.** A native home screen with a clock, search, app grid, dock
  and a "today" usage card. The JawnOS row is now the start menu's own app
  list, so it matches what the desk offers. A second row is the clothesline:
  the apps the house is running now, refreshed while Home is on screen.
- **System app shelves.** The installed apps are grouped into Communication,
  Games, System, Accessories and Other. Long-press an app, drag it onto a
  shelf chip, and it stays there on this device. Android's own app category
  and the system flag choose the starting shelf.
- **The launcher wears the desk's theme.** Its background, the ink (black on a
  light desk, white/light grey on a dark one), the cards, the dock and the
  system bars all follow the manager's background colour, re-read every ten
  seconds so a theme an app changes shows up on the home screen too.
- **Single-app windows.** Tapping a JawnOS app opens just that app, full
  screen. Each app goes through the start menu's own opener, so Box Office
  opens the ticket maker, Budget the ledger, Clock the alarms, Gallery the
  albums, Music the player — not a generic appointment window. The app's title
  bar and the native bar are both removed, so the app owns the whole screen;
  Android's Back gesture or button leaves it. A person's own app (Autumn,
  Coffee and the rest) still opens its appointment window.
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
