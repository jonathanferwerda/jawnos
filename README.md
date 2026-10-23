# JawnOS

**A personal, self-hosted operating environment.**

Website: **[jawnos.ca](https://jawnos.ca)**

## Support

JawnOS is free and open-source software, released under the [BSD 2-Clause licence](#license).
Development is funded through **[GitHub Sponsors](https://github.com/sponsors/jonathanferwerda)**,
which pays for the AI token budget behind the project's parallel, agent-assisted development
loops. If JawnOS is useful to you, sponsoring is the most direct way to keep it moving.

## About

JawnOS is not an operating system in the kernel sense. It is a self-hosted personal environment
that runs as an ordinary application and presents itself through the browser. A single Perl
codebase sits behind the Linux desktop app, the headless server daemon and the Android build that
runs under Termux; each machine keeps its own local database, and the machines keep one another
in step over the network without a central authority.

The aim is to gather the things one person actually does with a computer into one place: files
and media, appointments and tasks, budgets and invoices, inventory and mail, notes and location
history, maps, AI assistance and a spoken interface. It integrates natively with the **LilyGo
T-Watch S3**, the **LilyGo T-Deck (Plus, with GPS)** and the **Raspberry Pi Pico 2W**, and it can
reach into the physical world through home-automation hardware and network devices.

A few ideas hold the system together:

- **One record type.** An appointment is the atom: a timestamped record with a type, status,
  duration and a body. Files, invoices, measurements, notes, calls and mail are appointments
  under the hood, which is why they can refer to one another and why one window can gather
  everything about a record.
- **One house, many machines.** Every device holds the same software and its own database. Code,
  data, app builds and backups move between them on a "newest wins" rule; a deletion travels as a
  tombstone until every device acknowledges it.
- **Everything is an app.** Each app is a record type with its own window, icon, colour, measures,
  budgets, rules and settings. The catalogue is data, so an app can be renamed, merged, themed or
  hidden without a new build.
- **Local first, AI optional.** The core runs offline against a local SQLite database. AI features
  use a local Ollama model or a chosen provider, and are configured in one place.
- **The interface can be reshaped.** Bars, borders, materials, colour schemes, icon sets,
  languages and zoom are all settings, and the built-in help explains each one.

JawnOS is under active development, and "finished" remains a moving target.

## Features

### The desktop

JawnOS is a windowed desktop that lives in a browser tab. Windows open, stack, minimise,
maximise, snap to half the screen and enter a move mode from their own drop-down menu, and the
furniture around them is largely user-defined:

- **A configurable taskbar.** The bar is an ordered list of slots — the open windows, the clock,
  the start button, the search box and any pinned apps or keyboards — that can be rearranged in
  an edit mode. Right-clicking (or long-pressing on touch) opens a context menu for the bar, its
  tiles and each window; the bar can be shown, hidden or set to auto-hide, and the clock offers
  12- or 24-hour time and a choice of time zone.
- **A desk.** A configurable desktop folder whose icons line up down the left side, with Computer
  and the Recycle Bin always in reach. Files can be dragged onto it, apps can be pinned to it,
  and any folder can be made the desk folder. The background can be the appointment view or the
  continent map, and the desk's own clock sits with it.
- **A start menu** with recently used apps, a category rail, pages for what is running, upcoming
  and expiring, and a System view of the house's CPU, memory, battery and device levels.
- **Instant search.** A search box that can ride the menu, the taskbar or the dock, finding real
  apps by name as you type, with icons, recency and keyboard control.
- **A dock** that can be placed on any edge and slides away when idle.
- **A "clothesline"** — a rail along the top of the screen that hangs the routines and rituals
  that belong at the current hour, in the order they usually happen. It can be switched off, and
  each pill is drawn in the chosen material.
- **Dialogs as windows.** Alerts, folder questions and background job progress each get a
  taskbar tile, so they can be raised, minimised and dismissed like anything else.
- **Global display zoom** (20%–200%), adjustable bar heights, configurable window and button
  borders (width and colour), and a screensaver.
- **Nine colour schemes** — Blue, Graphite, Green, Indigo, Steel, Amber, Teal, Plum and Rose —
  each in a light and a dark cut, **seventeen selectable icon sets**, and a choice of textures
  (plain, round, sandglass, glass, paper, fabric, wood and metal) layered over every surface.
- **Sixteen interface languages** — English plus Mandarin, French, Spanish, German, Portuguese,
  Hindi, Arabic, Bengali, Russian, Japanese, Punjabi, Indonesian, Korean, Italian and Turkish —
  and an on-demand translator that reaches 107 languages through the Guide's model.

### The desktop app (a computer)

The phone's app has a Linux counterpart: a per-user dashboard that starts, stops and restarts
jawn, opens its UI, tails the log and drives the Bluetooth bridge — the same two jobs, on a
computer. It embeds the whole JawnOS UI in the same window through **WebKitGTK**, logging in with
a ticket you import once (kept encrypted in your keyring), with camera and microphone access,
F11 fullscreen and hardware-accelerated video. Its Bluetooth LE bridge is a real BlueZ central
speaking the phone's protocol, so a watch links to whichever machine is in range. The dashboard
and the embedded view are one window; the app can come up as a kiosk session (a starting Sway
configuration ships in `desktop/wayland/`) or sit in the tray, and it holds the machine awake
while media plays. The app updates itself in place, and reports the house version it is running.

### Files, media & creation

- **Folders** — the file manager. It browses your media locations with a Places sidebar, tabs and
  extra windows, a grid or list view, full multi-select and keyboard shortcuts, and a complete
  right-click menu (new file and folder, rename, open, open with, copy, cut, paste, delete,
  shred, archive and properties). Drag and drop moves a selection; Ctrl copies instead. Deletes
  go to a **Recycle Bin** that can restore or empty, Properties shows dates, permissions and
  owner, and the toolbar can browse another machine and its archive. Files can be **sealed** —
  encrypted with your credentials under a name of their own — and opened again from the same
  menu, with long jobs reporting their progress. Moving, sealing, opening or deleting a file
  carries the appointments, mail attachments and store entries that named it along with it. A
  per-app media padlock keeps not-visible folders out of sight until it is unlocked.
- **Gallery** — the photo and video browser, opening on one album cover per app with an All
  photos view. The grid loads as you scroll, search and sort find an item, and the full-screen
  viewer offers Previous, Next, file information, Set as main image, Fetch home and Delete.
  Hidden albums wait behind a padlock that unlocks with a paired device's fingerprint or the
  recovery code.
- **Camera** — capture from the device's own camera or a desktop webcam, with an unclaimed media
  pool in which to list, search and claim what has been captured.
- **Marker** — a layered paint board with pencil, paintbrush, spray, fill and matching erase
  tools, undo/redo, and zoom and pan. It reads stylus pressure, ignores your palm on a tablet,
  draws straight from the last point, and autosaves so a refresh does not lose a painting;
  sessions can be saved and reopened.
- **Music and studio** — a multitrack studio with takes, crossfades, waveform clips and a
  pedalboard routed onto channels; a polyphonic **Synth** with a full 88-key range, playable from
  the screen, your computer keyboard or a USB MIDI controller (twelve instruments and 240 presets,
  an arpeggiator, a step sequencer and MIDI learn) that can also be routed as a channel or a
  pedal; and a music player with a seek bar, volume, a theatre view, resume after a refresh, and
  visualisers for tracks that carry no artwork. On a phone it keeps playing with the screen off.
- **Video** — a player for the files in your media folders, with scrubbing by wheel, swipe or
  drag, volume by vertical swipe, and fullscreen.
- **Text, code and shell** — a rich text editor whose variables can answer for a `self`
  appointment; a colour-coded IDE for Perl, JavaScript, HTML and templates; a web browser that can
  also watch a number on a page as a measure; and a **Terminal** with a real VT screen, independent
  sessions per window, readable command and error lists, and remote shells to other machines.
- **Cards and Twirl** — a small deck drawn from your own records, and a quiet interactive toy.

### Appointments, tasks & routines

- **Appointments & scheduling** — a full calendaring system with alarms, recurring appointments,
  reminders and calendar export. Opening one spawns a centre view that gathers the record, its
  history and every file, mail, transaction and other appointment that names it. Occurrences your
  own habits imply but nobody has scheduled are drawn as faded **ghost appointments** ahead of
  now, and the taskbar clock is a **time machine**: type "-3h", "jul 16", "last dec 25" or a
  habitual phrase such as "next coffee time" to travel there.
- **Tasks** — nested checklists whose items carry a colour, a priority, a renewal interval and a
  budget, and that can record the matching appointment when you tick one off.
- **The wardrobe (clothesline)** — apps and routines are "hung" on the rail for the hours they
  belong to, with automatic hanging of the routines the history shows you actually perform.
- **Measures** — record a number against a time and chart it: ranges, multiple-selects and free
  values, read back over a day, a week, a month or a year, and legible to the evaluation.
- **Handbook** — the day as a journal. Today gathers what the house already knows (money moved,
  bills due, the day's shape, recent measures, notes, projects and people), and a header steps
  through days or jumps to a typed date. The Journal box saves an entry, and **Plant with the
  Guide** turns its forward-looking ideas into quiet appointments on the days they belong to.
  Predicted by your records shows the same ghost appointments for that day.

### People, places & navigation

- **People** — the house's **crest**: one hand-drawn picture, signed with the house key, with a
  fingerprint and a card another house can check. A crest can be scanned or uploaded, shown as a
  QR code, written to an NFC tag, imported from another house, vouched for, and backed by the
  house's other machines. A construct can carry its own signed logo. Every person the house knows
  gets a card with their crest, their memberships and the ways to reach them.
- **Relational** — the social structure behind People: people, teams, clubs, communities,
  projects, institutions, governments, corporations, places, vendors and events, linked in both
  directions on a drag-and-drop workspace. Constructs can answer to more than one name, and the
  house can publish their name and members to another house that looks it up.
- **Travel** — a pannable map of every map you have measured. Store a map image, measure its
  scale and home plate by hand, by OCR or by asking the vision model, and it lands at its true
  place on the globe; an optional tile basemap (OpenStreetMap, OpenTopoMap, Carto, Esri, a county
  GIS, or a custom URL) can lie over it. Routes, distance and speed are drawn from logged
  position fixes, and the blanks between measured maps can be conservatively guessed by the
  image model. The same map is the continent desktop background.
- **Navigation** — the autonomous location log: one GPS fix per interval, screen on or off, filed
  against a running appointment, with each point's distance, leg length and speed listed on the
  record. Crossing a home plate can start or stop the matching appointment on its own.

### Money, stock & documents

- **Accounting** — accrual **income statement**, **balance sheet**, **cash flow**, account
  activity, receivables and payables, read from a real double-entry journal with a **trial
  balance**. It also holds the ledger, the document ledger of invoices and quotes, a day book,
  and a **bank reconciliation** that imports CSV, QIF or OFX, matches lines by amount and date,
  and sets the account's balance from the statement. Bills can repeat on a fixed or written
  schedule and be paid in part; a payment named in a bank notification books itself. Each app
  keeps its own budget light, read as a **pace** against the part of its period that has run.
- **Store & invoicing** — a store of items, models and options that each carry their own prices,
  browsed as shelves with filters, search and a docked detail pane. Quotes and invoices are built
  from them, print to a white, house-styled paper, and can be delivered by email; a **Register**
  journals sales and payments per customer, and **Correspondence** journals the mail and chats
  exchanged with them. Recording a payment updates the balance and closes the document at zero;
  deleting the transaction reopens it.
- **Crypto** — wallet accounts that hold a coin, per-invoice Bitcoin receiving addresses derived
  from an account xpub, live fiat and coin rates, and cost or market valuation. JawnOS never holds
  a key and cannot spend; a payment is recorded against an invoice with its txid, and a payer's
  signed **PAY1Z** proof can be verified against their crest. Currency tracking writes rate
  history as measures.
- **Warehouse & stock** — money and goods tracked per place: what is where and how much of it,
  packaging that carries real quantities (a carton of twelve, a box of nails by weight) and
  shelf life so expired stock is swept up on its own, a journal of every stock movement and its
  reason, and a **moves ledger** that folds stock and money into one signed list. On-hand is read
  in an item's own unit, and a target turns into a package-aware restock plan.
- **Market** — the shopping side: lists by kind and vendor, a need/want dial on each row, and a
  Shopping view filtered to needs, wants or all. An item the warehouse is short of is raised to
  a need on its own. A barcode can be scanned by a phone or a webcam, a whole paper receipt can
  be read by the vision model, and Checkout opens the purchase transaction filled line by line
  from the cart, with each purchase writing its stock move.
- **Inventory** — each app's own record of what it holds and has been up to: its measures,
  documents and reports together, with charts, a share wheel and the **Evaluation** reports.
- **Notes & documents** — note-taking with document scanning, OCR (Tesseract), barcode/QR
  reading (zbar) and PDF rendering (WeasyPrint). A note is an appointment like everything else,
  can be dragged onto an appointment to attach it, and is where speech that named no command
  lands.

### Communication & assistance

- **Mailbox** — email over IMAP/SMTP, SMS, LoRaWAN, the house's radio "dial", its ticket threads
  and the **Pen** assistant, gathered in one window and also available as separate **Email**,
  **Chat**, **Phone** and **Pen** apps. Mail arrives on the desktop, threads by message headers,
  searches the body as well as the subject, and files sent mail back onto the recipient's app
  with its attachments sealed. Chat keeps one thread per person across transports, with SMS,
  MMS and LoRaWAN roads. Phone adds recent calls, contacts, multiple lines per person, a dial pad,
  caller ID and blocking. Pen holds assistant conversations, each with its own model and voice.
- **AI assistance** — chat and image generation through local [Ollama](https://ollama.com)
  models, Cloudflare Workers AI and OpenAI, Anthropic (Claude), Google (Gemini), xAI (Grok),
  DeepSeek, Mistral, Groq and OpenRouter, with multimodal chat (images, and the shapes for audio
  and video); plus speech ([Piper](https://github.com/rhasspy/piper), with espeak as a fallback)
  and transcription (cloud ASR from Cloudflare or Groq, falling back to a local whisper.cpp
  build). A model can be pinned to one machine, an agent can hold a thinking level and a fallback
  model for when a provider is out of credit, and Configure → Plat shows each provider's balance
  beside its key against the house's shared AI ledger.
- **The Guide** — the help agent you can ask in words. It answers, and it can also act: search
  your records, open an app, bring up photos, play a track, centre a map, reporting each step as
  it goes. It reads the calendar and the clock for you — written and relative dates, holidays,
  birthdays and ages, past or future — and it can create, change, delay, stop or delete an
  appointment, each change staged for you to confirm and undoable. You can also hold a spoken
  conversation with it, turn after turn, without repeating the wake word.
- **Agents** — the Guide can call associates for a second opinion, and a **Coding agent** chatbox
  sits in the Terminal and the IDE, with several agents able to work at once, each with its own
  conversation.
- **Evaluation** — a model-backed appraisal of any app's activity, run on demand over a chosen
  range or on a nightly cadence, that reads what the app is and what it has been doing, weighs
  day, week, month and year together, notices the conditions and relationships around each
  occurrence, and leaves a report beside the app with a headline and links to everything it names.
- **Translation** — a target-language picker under Configure → Misc can translate the visible
  window on demand, and the Guide can translate a phrase or a window in any of its 107 languages.
  Translations are cached on the server and the device and never change the saved interface
  language.

### Voice and the wake word

The T-Watch and T-Deck can listen for you. They detect speech — or a wake phrase — record a
short clip and ship it to JawnOS over Bluetooth or Wi-Fi, where the clip is transcribed and either
run as a command or kept as a note. The wake phrases are custom-trained for JawnOS rather than
stock — **Hey Jawn**, and **Jawn Do** on the watch — and each device's mode (off, any speech, or a
phrase) is chosen from its row in the Embedded panel, beside a noise floor that can be automatic
or pinned. Listening continues with the screen off, and the screen wakes with a chime when it
hears you. JawnOS answers aloud through a neural **Piper** voice, and the reply streams to the
device as it is written — the text on screen and the spoken clip in parts over the bridge, so the
first word lands in about a second and a half. A watch carries two-way audio with an **Audio
replies** toggle on its row, and the T-Deck runs the same code with its own microphone.

### System, security & devices

- **System & monitoring** — a **Process Monitor** with live CPU and memory readings, per-core
  graphs, a sortable process list, and a health strip with load, uptime, sync, database size and
  battery charge, temperature, voltage and per-hour draw. The server grows a worker under load
  and retires it when the burst passes, so a slow model call does not queue the whole interface.
- **The Utility controller** — every background chore (backups, mail, tunnels, sync, navigation,
  alarms, budgets, stock expiry and more) with a run switch, an interval, a last-run time and a
  good/bad reading, set per machine.
- **Self-updating & backup** — a git watcher fast-forwards the checkout and reloads open tabs onto
  the new revision; a machine with no route to the source pulls the tree as a git bundle from the
  newest reachable peer instead. Backups and restores are built in.
- **The mesh** — several machines keep one another in step without a central authority: code,
  app builds, data and deletions all move the same way ("whoever has the newest is the authority"),
  over whatever network they share or a tunnel when one is behind a router. Sync topology can be
  automatic, a full mesh or a hub, and the transfer repairs only the blocks or weekly bands that
  differ. Every machine can be logged into from another with a ticket, with a privilege of guest,
  resident, trusted or citizen, and a new machine can be migrated the whole house at once.
- **Security** — a screen padlock unlocked by a paired phone's fingerprint, this computer's reader,
  the paper recovery code or three paper shares; a gate that can shadow or enforce the lock; an app
  gate that admits only the installed desktop and Android apps and the signed peer rail; device
  pairing approved from Security; and a keyring-style secret store with password and pseudonym
  generation, QR codes and encryption helpers. The house key can be rotated, re-sealing the
  database and every sealed file, with the old key kept so old seals still open.
- **Box Office** — issue, suspend, renew and revoke the single-use ticket links that log a visitor
  in, with a QR, an access log and a privilege per ticket. Public requests can carry a signed crest;
  approving mints a ticket, declining forgets it, and blacklisting or blocking a number keeps it
  out at the door and off the phone.
- **Built-in help** — a **Help** app that explains any app, feature, function or device in plain
  language: hover (or long-press) a control for a hint, press **F1** for whatever window you are
  focused on, or use the question-mark button in a window's title bar. Its **Guide** is the chat
  that can also drive the screen, and **Handbook** is its longer-form, chaptered cousin.
- **The self-healing watch & the coding agent** — a watcher reads the server and browser logs (and
  the Guide's own conversations), catches the faults, and stages a fix, compile-checking and
  applying it only when you approve — or on its own, within a daily token budget — and listing
  everything it has fixed so far. Beside it sits a **Coding agent** chatbox in the Terminal and
  the IDE, with several agents able to work at once.
- **Devices & firmware** — first-class support for the T-Watch, T-Deck and Pico 2W, with remote
  control, a Bluetooth Low Energy bridge, a password-less websocket tunnel between machines, and
  encrypted sync. The wireless boards update **over the air** — the manager relays a chosen
  firmware image to the board's own update endpoint — or over USB from a button in the Embedded
  panel; a board stuck in its provisioning AP can be restored over USB. The LoRaWAN credentials
  for the T-Deck live in Chat's LoRa section.
- **App releases** — the Android build has a store of its own: stage a built APK and every device
  pulls the newest from the mesh and can serve it in turn. A release is built and published with
  one script (the manifest rides to GitHub beside the APK), and the app offers a one-tap update
  from whichever host holds the newest build.

## Screenshots

**The desktop.** The clothesline runs along the top, hanging the routines that belong at the
current hour; the taskbar and the dock share the edges.

![The JawnOS desktop](docs/screenshots/desktop.png)

**The start menu.** It opens on the recent apps, with a category rail for the whole catalogue and
a search that can ride the menu, the taskbar or the dock.

![The start menu](docs/screenshots/start-menu.png)

**The taskbar's context menu.** From here the bar is rearranged, repositioned, set to auto-hide
and repopulated with pinned apps and keyboards; the clock's format and time zone live here too.

![The taskbar's context menu](docs/screenshots/taskbar-menu.png)

**Process Monitor.** Live CPU and memory readings, per-core graphs and a sortable process list.

![The Process Monitor](docs/screenshots/monitor.png)

**On a phone.** The bars can be moved, hidden or set to auto-hide, and the interface scales to
the screen.

![JawnOS on a phone](docs/screenshots/phone.png)

## How it's built

- **Backend:** Perl, using [Mojolicious::Lite](https://mojolicious.org) as the web framework.
  `jawn` is the launcher — it runs `President.pl` in a PTY and restarts it if it dies — and
  `President.pl` is the Mojolicious app that boots the servers, workers and sockets.
- **Data:** SQLite (via `Mojo::SQLite` / `SQL::Abstract`). Most internal message passing between
  processes is [Sereal](https://metacpan.org/pod/Sereal)-encoded over Unix sockets, and
  [Minion](https://metacpan.org/pod/Minion) carries the background jobs.
- **Processes:** the app runs as a set of purpose-specific servers. `President.pl` starts a dock
  server, a WebSocket server, the main prefork server, an alarm worker, and the watch, teletype
  and music servers, each identified by `PURPOSE` and each loading the module that suits it. In
  development they run under Morbo for hot reloading; in production they run as prefork workers,
  recycled as their heaps grow.
- **Real-time:** WebSockets push updates to the browser so windows, notifications and status stay
  live without polling.
- **Front end:** Embedded-Perl (`.ep`) templates in `templates/` — pages at the top level and one
  folder per feature — rendered into a jQuery-driven "desktop in a browser" UI in `public/`; the
  manager's app scripts are served as one memoised, ETag-revalidated bundle, so a script change is
  live on the next refresh.
- **Mesh:** machines reach each other over HTTP — through a tunnel when one is behind a router —
  and code and data travel as git bundles and backups on the same "newest wins" rule;
  `tunnel.pl` carries the transport.
- **Voice:** the boards run an on-device voice-activity detector and a wake-word listener
  (microWakeWord, with models trained for JawnOS); a shipped clip is transcribed with whisper.cpp
  and JawnOS speaks through Piper.
- **Firmware:** Arduino sketches under `jp/`, `jt/` and `jw/` for the Pico 2W, T-Deck and
  T-Watch, built with PlatformIO and updated over the air or over USB from the Embedded panel.

### Repository layout

| Path | What it is |
| --- | --- |
| `jawn` | Launcher/supervisor — starts `President.pl` in a PTY and restarts it on crash |
| `President.pl` | The Mojolicious app — boots the servers, workers and sockets |
| `Manager.pl` | The main application: routes and the bulk of the features |
| `gb.pl` | Global state shared across the app |
| `subroutines.pl` | Shared helper library |
| `Websocket.pl` | WebSocket server and live updates |
| `Alarm.pl`, `Music.pl`, `teletype.pl`, `watch.pl`, `tunnel.pl`, `hooks.pl` | Feature modules (alarms, music, notes, terminals, smartwatch, the peer tunnel, device hooks) |
| `help.pl` | The built-in guide's topic registry, served by the Help app |
| `templates/` | Embedded-Perl page templates: pages at the top level plus per-feature folders (`apps/`, `folders/`, `store/`, `mail/`, `configure/`, `travel/`, `handbook/`, …) |
| `public/` | Front-end JavaScript, CSS and images (including the icon sets in `public/icons/sets/`) |
| `desktop/` | The Linux app: the GTK dashboard, the CLI, the BlueZ BLE bridge and the embedded WebKitGTK view |
| `jp/`, `jt/`, `jw/` | Device firmware (Pico 2W, T-Deck, T-Watch) |
| `scripts/` | Supporting scripts — the dependency checker, the first-run wizard, firmware and app-release staging, the help and records audits, the BLE bridge and maintenance tools |
| `database/` | `schema.sql` (used to build a fresh database) and a starting encrypted database |
| `docs/` | Documentation and screenshots |
| `training/` | The wake-word training notebook |
| `voices/`, `releases/` | Blob stores (gitignored): Piper voice models, and staged Android APKs |
| `server/` | TLS material and the inventory seed |

## Requirements

- Perl 5 with the CPAN modules listed in the installation section below
  (`Mojolicious`, `Mojo::SQLite`, `Minion`, `Sereal`, `Crypt::Simple` and friends).
- A handful of command-line tools: `ffmpeg`, `imagemagick`, `tesseract`, `sqlite3`, `qrencode`,
  `zbar`, `espeak`, `curl`, `rsync`, `openssl`, `sshpass` and `autossh` (see below).
- Optional, for the full feature set: Python `weasyprint` (PDF rendering), `ollama` (local AI
  models), and a `whisper.cpp` build with the base model (audio transcription).
- Optional, for the Linux desktop app (`desktop/`, the phone's dashboard and BLE bridge on a
  computer): `python3-gi`, `python3-dbus`, BlueZ, **WebKitGTK 4.1** (the embedded view), the
  **GStreamer** plugin set with the **VA-API** decode plugin, and — importantly — the **VA-API
  driver for your GPU**. Without the driver the plugin exposes nothing and HD video falls back to
  software decode (choppy, and heavy on the CPU). See
  [`desktop/README.md`](desktop/README.md#media-and-video).

You do not have to install any of this by hand. The first time you run `./jawn` it checks for
every dependency and offers to install whatever is missing. The per-platform sections below are
the do-it-yourself fallback.

## Installation

The first run of `./jawn` drives the whole install: it gets missing dependencies, then opens a web
wizard that writes `config.json` and builds you an encrypted database (see
[First run](#first-run)). If you would rather install the dependencies yourself first, the
per-platform instructions below will do it — the wizard still handles the config and database.

To check (and optionally install) dependencies on their own:

```
perl scripts/jawnos_deps.pl           # report, then offer to install
perl scripts/jawnos_deps.pl --report  # report only; exits non-zero if anything is missing
perl scripts/jawnos_deps.pl --sh      # print the install commands as a shell script
perl scripts/jawnos_deps.pl --desktop # also check/install the desktop app's WebKitGTK
                                      # and GStreamer media plugins (optional)
```

### Android (Termux)

Install F-Droid, then install **Termux** and **Termux:api** from it.

In Termux:

```
termux-setup-storage

pkg install openssh termux-api espeak build-essential \
perl tesseract imagemagick zip sqlite sshpass openssh \
curl sox iproute2 libqrencode rsync zbar ffmpeg tmux \
autossh android-tools ollama termux-services

cpan App::cpanminus

cpanm Net::SSLeay

cpanm --notest --force Mojolicious::Lite \
 Net::SSLeay CryptX \
 WWW::Mechanize Time::Piece Time::Duration \
 Date::Parse Hash::Merge Encode Data::Dumper \
 File::Find File::Slurp Number::Format \
 SQL::Abstract Mojo::SQLite Data::UUID \
 Mojolicious::Plugin::RenderFile \
 LWP::UserAgent Crypt::Simple File::Type \
 HTML::Strip URI::Encode LWP::Protocol::https \
 URI::Escape MIME::Base64 Math::Trig List::Util \
 Net::IMAP::Client MIME::Parser \
 Email::Stuffer Authen::SASL \
 Minion Minion::Backend::SQLite Mojo::IOLoop::ReadWriteFork \
 Sereal::Encoder WebService::Ollama

pip install weasyprint

# Piper, for the natural speech voice: glibc-repo adds the repo glibc-runner needs
# (Termux is bionic, so the glibc Piper build runs under glibc-runner)
pkg install -y glibc-repo && pkg install -y glibc-runner
```

`perl scripts/jawnos_deps.pl` installs Piper (engine and voices) for you as an
"extra", and re-runs on every code update; the `pkg install` line above is the manual
equivalent.

Activate developer settings: go to **Settings → About Device → Software Information** and tap
**Build Number** seven times. In **Developer options**, turn on **Wireless debugging**, tap it,
then pair the device:

```
adb pair ip:port
adb connect ip:port
adb shell settings put global settings_enable_monitor_phantom_procs 0
adb shell settings put global max_phantom_processes 2147483647
```

```
cd jawnos

chmod +x jawn President.pl

./jawn
```

### Debian

```
sudo apt update; sudo apt upgrade;
sudo apt install lib32z1-dev cpanminus \
ssh espeak build-essential zip openssl libssl-dev \
perl tesseract-ocr imagemagick sqlite3 sshpass \
ssh curl sox iproute2 qrencode rsync ffmpeg libbarcode-zbar-perl \
tmux weasyprint autossh net-tools ollama

# For the Linux desktop app (desktop/): the embedded view and smooth video.
# gstreamer1.0-vaapi is the decode plugin; it ALSO needs the VA-API driver for
# your GPU (pick one below), or HD video decodes in software and is choppy.
sudo apt install python3-gi python3-dbus bluez gir1.2-webkit2-4.1 \
gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
gstreamer1.0-plugins-ugly gstreamer1.0-libav gstreamer1.0-vaapi vainfo
#   Intel (Gen8+):  sudo apt install intel-media-va-driver-non-free
#   Intel (older):  sudo apt install i965-va-driver
#   AMD / Mesa:     sudo apt install mesa-va-drivers
#   NVIDIA:         sudo apt install nvidia-vaapi-driver
# Confirm hardware decode with:  vainfo && gst-inspect-1.0 vah264dec

sudo cpanm --notest --force Mojolicious::Lite \
 WWW::Mechanize Time::Piece Time::Duration \
 Date::Parse  Hash::Merge Encode Data::Dumper \
 File::Find File::Slurp Number::Format \
 SQL::Abstract Mojo::SQLite Data::UUID \
 Mojolicious::Plugin::RenderFile \
 LWP::UserAgent Crypt::Simple File::Type \
 HTML::Strip URI::Encode LWP::Protocol::https \
 URI::Escape MIME::Base64 Math::Trig \
 List::Util Net::SSLeay \
 Net::IMAP::Client MIME::Parser \
 Email::Stuffer Authen::SASL \
 CryptX Minion Minion::Backend::SQLite
 Mojo::IOLoop::ReadWriteFork Sereal::Encoder \
 WebService::Ollama
```

Edit `/etc/ssh/sshd_config`:

```
MaxSessions 1000000
```

Create swap, if you have not already:

```
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

```
cd jawnos
./jawn
```

### Manjaro

```
sudo pacman -Syu
sudo pacman -S base-devel cpanminus sqlite3 \
chromium xclip rsync sshpass certbot zip \
imagemagick espeak-ng tesseract xsane sox \
net-tools xdotool qrencode zbar fprintd python-weasyprint \
autossh lm_sensors ollama cmake python-pip

# For the Linux desktop app (desktop/): the embedded view and smooth video.
# The VA-API plugin now ships inside gst-plugins-bad (older Arch had it as
# gst-plugin-va); it ALSO needs the VA-API driver for your GPU (pick one below),
# or HD video decodes in software and is choppy. Install the gst-* set together
# -- they pin each other exactly.
sudo pacman -S webkit2gtk-4.1 python-gobject python-dbus bluez bluez-utils \
gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly \
gst-libav libva-utils
#   Intel Gen8+:  sudo pacman -S intel-media-driver
#   Intel older:  sudo pacman -S libva-intel-driver
#   AMD:          sudo pacman -S libva-mesa-driver
# Confirm hardware decode with:  vainfo && gst-inspect-1.0 vah264dec

git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
make

# Fetch the base model configuration
bash ./models/download-ggml-model.sh base

sudo cpanm --notest --force Mojolicious::Lite \
 WWW::Mechanize Time::Piece Time::Duration \
 Date::Parse Hash::Merge Encode Data::Dumper \
 File::Find File::Slurp Number::Format \
 SQL::Abstract Mojo::SQLite Data::UUID \
 Mojolicious::Plugin::RenderFile \
 LWP::UserAgent Crypt::Simple File::Type \
 HTML::Strip URI::Encode LWP::Protocol::https \
 URI::Escape MIME::Base64 Math::Trig \
 List::Util Net::SSLeay \
 Net::IMAP::Client MIME::Parser \
 Email::Stuffer Authen::SASL \
 CryptX Minion Minion::Backend::SQLite \
 Mojo::IOLoop::ReadWriteFork Sereal::Encoder \
 WebService::Ollama
```

## First run

From the `jawnos` directory:

```
chmod +x jawn President.pl
./jawn
```

On the first run — or any time `config.json` is missing — JawnOS walks you through setup:

1. **Dependencies.** `scripts/jawnos_deps.pl` checks for the required command-line tools and Perl
   modules and offers to install anything that is missing (using `apt`, `pacman` or Termux's
   `pkg`, plus `cpanm`). It also reports which key-derivation features OpenSSL offers: recovery
   shares use Argon2id (from OpenSSL 3.2+, or from the `argon2` tool with the same parameters
   where OpenSSL is older), falling back to scrypt and then PBKDF2 only when neither provider is
   present, and the share records the one it used. No libsodium or compiler is needed —
   the Ed25519 → X25519 conversion is plain Perl on top of CryptX.
2. **`config.json`.** A web wizard opens at <http://127.0.0.1:3210/wizard> where you fill in your
   name, device, ports and media folders; it writes `config.json` for you. The
   `signatorial` is a file that will not change — JawnOS reads it at start-up, hashes it and uses
   it to encrypt cookies. Leave that field blank and the wizard generates one for you.
3. **Database.** There is nothing to pick or move. The wizard builds the machine's one database,
   `database/jawnos.db`, from the shipped factory seed (`database/initial.enc`) and shows you a
   numeric unlock code it generated. Write that code down — you type it at the gate screen to
   unlock JawnOS. The copy it seals into `database/backups/` is the app's own backup; `initial.enc`
   stays the factory template (regenerate it with `perl scripts/factory_seed.pl`).

When setup finishes the wizard closes and JawnOS boots. Your browser opens at the gate with the
new database listed; enter your unlock code to get in.

To re-run the wizard later, start with `./jawn --setup`. To run just the wizard:

```
perl scripts/jawnos_setup.pl              # opens at http://127.0.0.1:3210/wizard
perl scripts/jawnos_setup.pl --port 4000  # use a different port
perl scripts/jawnos_setup.pl --no-browser # don't try to open a browser
```

## Status

JawnOS is a work in progress. It ships sixteen interface languages, seventeen selectable icon
sets, hover and long-press hints throughout the interface, and an in-app guide that explains
every topic. Development is continuous and the tree changes daily, so expect rough edges,
particularly in the newest apps.

Recent work has gone into the **Folders** file manager and the desk (tabs, Places, the Recycle
Bin and desk shortcuts); into **Gallery** (albums, lazy grids and a full-screen viewer); into the
money side (**Accounting** with its double-entry journal and bank reconciliation, **Crypto**
wallets, and the Store's Register); into **People** and **Relational** (the signed house crest,
construct crests and cross-house lookup); into **Handbook**; and into the mesh's band-level sync
repair. Voice and the wake word, the Guide and its agents, and the self-healing watch remain
active areas.

## License

BSD 2-Clause. See [LICENSE](LICENSE). The third-party components JawnOS bundles or
redistributes — the Piper TTS engine and its voice models, and any bundled fonts — are listed
with their licences in [THIRD-PARTY.md](THIRD-PARTY.md).
