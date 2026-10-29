# JawnOS app release notes

The body of the GitHub release (`releases` tag). `scripts/app_publish.pl` reads
this file, adds the release date and the version codes that are actually
staged, and writes it back to the release. Keep the newest release at the top
under a dated heading; older sections stay as history.

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
