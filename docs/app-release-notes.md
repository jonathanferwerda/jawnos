# JawnOS app release notes

The body of the GitHub release (`releases` tag). `scripts/app_publish.pl` reads
this file, adds the release date and the version codes that are actually
staged, and writes it back to the release. Keep the newest release at the top
under a dated heading; older sections stay as history.

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
