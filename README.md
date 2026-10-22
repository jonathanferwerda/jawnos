# JawnOS

**A personal, self-hosted operating environment.**

Website: **[jawnos.ca](https://jawnos.ca)**

## Support

JawnOS is free and open-source software, released under the [BSD 2-Clause licence](#license). It
turns a single Perl web server into a browser-based command centre — a desktop-like environment
that gathers the things one person actually does with a computer: files and media, appointments
and tasks, budgets and invoices, inventory and mail, notes and location history, maps, AI
assistance and a spoken interface, and a small fleet of handheld and wearable devices. It is a
**multi-device system** — the Linux desktop app, the headless server daemon, and the Android
build that runs under Termux — all driven from one shared Perl codebase, and it is built using
**high-velocity agent workflows**: parallel, AI-assisted development loops that draft, review and
test changes across the whole tree at once.

Community backing through **[GitHub Sponsors](https://github.com/sponsors/jonathanferwerda)**
directly funds that AI token budget, and that budget is what keeps the parallel dev loops active.
If JawnOS is useful to you, sponsoring is the most direct way to keep it moving.

## About

How did this happen? I was at the library in college, measuring where my life would go after
graduation; it had been almost 2 years since I heard about Linux, and I thought, there's no way I
have any hope of building something technical. But people kept bringing me their computers to fix,
and there was this phase of my life where I worked til midnight at a call centre, and I'd start
and end my day roaming the internet, learning as much about programming as I could to bring myself
out of this horrible situation where I had to sit tethered to a desk for 8 hours a day and act
happy to hear people call about their phones.

I started my first business a year later, fixing computers, and in 6 months I was tired of working
on other people's computers. I wanted to build, and I had a couple of customers I ended up building
business databases for. I learned the hard way that when people buy software, they think they're
buying you.

Four years ago, after recovering from a long stretch of burnout, I decided I'd take a run at it
again. First, I need to say: I'm not a great coder... make no mistake, there would be massive bugs
in my code if I didn't have AI helping me. I'm the kind of programmer that starts a feature, then
says, oh look! A feature! And jumps over to it to start building. So again I say, thank heavens
we've got AI to finish my work. Four years of writing a prompt in Perl by hand.

So, help me. Please sponsor my project, send me a cheque, an e-transfer, or drop cash off. Or
better, do you have an API key I can bum? This code is being updated live, so if you try to install
it, you'll find you need to refresh the window at least 12 times a day, and things will break on
you all day long. So, don't even try. I promise that as soon as I'm finished it'll work... probably,
see the licence about warranty.

It is not an operating system in the kernel sense, but a self-hosted personal environment that
runs as an ordinary application and presents itself through the browser. It integrates natively
with the **LilyGo T-Watch S3**, the **LilyGo T-Deck (Plus, with GPS)** and the **Raspberry Pi
Pico 2W**, and it can reach into the physical world through home-automation hardware and network
devices.

JawnOS is under active development, and "finished" remains a moving target — but it is genuinely
useful in the meantime, and I hope it is of some use to you too.

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
- **A start menu** with a recently used list, a category rail, and an optional search box that
  can ride the menu, the taskbar or the dock.
- **A dock** that can be placed on any edge and slides away when idle.
- **A "clothesline"** — a rail along the top of the screen that hangs the routines and rituals
  that belong at the current hour, in the order they usually happen.
- **Global display zoom** (20%–200%), adjustable bar heights and a configurable window border
  (width and colour), so the interface can be scaled for a phone, a tablet or a large display.
- **Nine colour schemes** — Blue, Graphite, Green, Indigo, Steel, Amber, Teal, Plum and Rose —
  each in a light and a dark cut, and **seventeen selectable icon sets**, with the original
  hand-drawn artwork as the default.

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

- **Files & folders** — browse with a full right-click menu (new file and folder, rename, open,
  open with, copy/cut/paste, delete, shred, archive and properties), and play video and audio or
  view photos through an on-the-fly thumbnailer backed by a disk cache. Files can be **sealed** —
  encrypted with your credentials under a name of their own — and opened again from the same
  menu, with the long jobs running in the background and reporting their progress. Moving,
  sealing, opening or deleting a file carries the appointments, mail attachments and store
  entries that named it along with it. An **archive queue** moves files off to a per-place
  archive over the tunnel, keeping a manifest so they can be fetched home again; the toolbar can
  browse another machine and its archive, and a bookmark drawer keeps the places you use.
- **Gallery** — the photo and video browser, including anything kept in the archive, with albums
  and a per-item view.
- **Camera** — capture from the device's own camera or a desktop webcam, with an unclaimed media
  pool in which to list, search and claim what has been captured.
- **Drawing (the marker)** — a layered paint board with pencil, paintbrush, spray, fill and
  matching erase tools, undo/redo, and zoom and pan. It reads stylus pressure, ignores your palm
  on a tablet, draws straight from the last point, and autosaves so a refresh does not lose a
  painting; sessions can be saved and reopened.
- **Music and studio** — a multitrack studio with takes, crossfades, waveform clips and a
  pedalboard routed onto channels; a polyphonic **Synth** with a full 88-key range, playable from
  the screen, your computer keyboard or a USB MIDI controller (twelve instruments and 240 presets,
  an arpeggiator, a step sequencer and MIDI learn) that can also be routed as a channel or a
  pedal; and a music player with a seek bar, volume, a theatre view, resume after a refresh, and
  visualisers for tracks that carry no artwork.
- **Text, code and shell** — a rich text editor whose variables can answer for a `self`
  appointment; a colour-coded IDE for Perl, JavaScript, HTML and templates; a web browser; and a
  terminal.

### Appointments, tasks & routines

- **Appointments & scheduling** — a full calendaring system with alarms, recurring
  appointments, reminders and calendar export. Occurrences your own habits imply but nobody has
  scheduled are drawn as faded **ghost appointments** ahead of now, and the taskbar clock accepts
  a typed time to travel to.
- **Tasks** — nested checklists whose items carry a colour, a priority, a renewal interval and a
  budget, and that can record the matching appointment when you tick one off.
- **The wardrobe (clothesline)** — apps and routines are "hung" on the rail for the hours they
  belong to, with automatic hanging of the routines the history shows you actually perform.
- **Measures** — record a number against a time and chart it: ranges, multiple-selects and free
  values, read back over a day, a week, a month or a year, and legible to the evaluation.

### Money, stock & documents

- **Budgeting** — a statement, budgets, a document ledger of invoices and quotes, and a daily
  sheet, all drawn from the same transaction history. A budget can be a ceiling or a floor and is
  read as a **pace** for the part of its period that has run, with the autocalc offering a
  recommended figure; its reading is named — **occurrences**, a money **total**, or a **quantity**
  taken off the appointment stream.
- **Store & invoicing** — a store of items, models and options that each carry their own prices,
  with quotes and invoices that print to a white, house-styled paper and can be delivered by
  email. Quotes and invoices total separately, and a quote reads as a draft. Recording a payment
  against a document updates its balance and closes it when the balance reaches zero; deleting
  that transaction reopens it.
- **Warehouse & stock** — money and goods tracked per place: what is where and how much of it,
  packaging that carries real quantities (a carton of twelve, a box of nails by weight) and
  shelf life so expired stock is swept up on its own, a journal of every stock movement and its
  reason, and a **moves ledger** that folds stock and money into one signed list. On-hand is read
  in an item's own unit, a target turns into a package-aware restock plan (a shortfall of six met
  by one pack of twenty), and a fixed-level quantity budget watches that on-hand.
- **Market** — the trading side of the warehouse and store: vendors, buyers and the deals
  between them, drawn from the same items, prices and stock. A **Shopping List** tab holds what to
  buy with a need/want dial on each row, and a **Shopping** view reads the same list through a
  Needs/Wants/All filter; an item the warehouse is short of is raised to a need on its own, so a
  run to the shops already knows what is missing.
- **Inventory** — each app's own record of what it holds and has been up to: its measures,
  documents and reports together, with charts, a share wheel and the **Evaluation** reports.
- **Notes & documents** — note-taking with document scanning, OCR (Tesseract), barcode/QR
  reading (zbar) and PDF rendering (WeasyPrint). A note is an appointment like everything else,
  can be dragged onto an appointment to attach it, and is where speech that named no command
  lands.

### Communication, location & assistance

- **Mail & messages** — email over IMAP/SMTP in its own **Email** app, alongside the **Pen**
  assistant, the internal message and paper-route system, and the ticket store, with mail that
  arrives straight on the desktop; sent mail is filed back onto the recipient's app and its
  attachments are sealed. The **Chat** app gathers the house's conversations in one place — a
  friends sidebar, one thread per person across transports, and a per-message road (chat, SMS or
  LoRa) — and the **Phone** app adds recent calls, contacts and a dial pad, handing a call placed
  on a machine that is not a phone to one that can make it. SMS runs through the app's own native
  bridge, and a message carrying files rides as an MMS, with a paperclip in the composer.
- **Location & activity** — autonomous location logging (one fix per interval, screen on or off),
  location history, distance and speed calculations, and a "father time" activity clock.
- **Maps** — a pannable map of every map you have measured: store a map image, measure its scale
  and home plate by hand, by OCR or by asking the vision model, and it lands at its true place on
  the globe, with an optional tile basemap (OpenStreetMap, OpenTopoMap, Carto, Esri, a county
  GIS, or a custom URL) laid over it. The same map is the continent desktop background.
- **AI assistance** — chat and image generation through local [Ollama](https://ollama.com)
  models, Cloudflare Workers AI and, now, OpenAI, Anthropic (Claude), Google (Gemini), xAI
  (Grok), DeepSeek, Mistral, Groq and OpenRouter, with multimodal chat (images, and the shapes
  for audio and video); plus speech ([Piper](https://github.com/rhasspy/piper), with espeak as a
  fallback) and transcription (cloud ASR from Cloudflare or Groq, falling back to a local
  whisper.cpp build). A model can be pinned to one machine (a device's own Ollama), an agent can
  hold a thinking level and a fallback model for when a provider is out of credit, and Configure →
  Plat shows each provider's balance beside its key against the house's shared AI ledger.
- **The Guide** — the help agent you can ask in words. It answers, and it can also act: search
  your records, open an app, bring up photos, play a track, centre a map, reporting each step as
  it goes. It reads the calendar and the clock for you — written and relative dates, holidays,
  birthdays and ages, past or future — and it can create, change, delay, stop or delete an
  appointment, each change staged for you to confirm and undoable. You can also hold a spoken
  conversation with it, turn after turn, without repeating the wake word.
- **Evaluation** — a model-backed appraisal of any app's activity, run on demand over a chosen
  range or on a nightly cadence, that reads what the app is and what it has been doing, weighs
  day, week, month and year together, notices the conditions and relationships around each
  occurrence, and leaves a report beside the app with a headline and links to everything it names.

### Voice and the wake word

The T-Watch can listen for you. It detects speech — or a wake phrase — records a short clip and
ships it to JawnOS over Bluetooth or Wi-Fi, where the clip is transcribed and either run as a
command or kept as a note. The wake phrases are custom-trained for JawnOS rather than stock —
**Hey Jawn** and **Jawn Do** so far — and each device's mode (off, any speech, or a phrase) is
chosen from its row in the Embedded panel. JawnOS answers aloud through a neural **Piper** voice,
and the reply streams to the watch as it is written — the text on screen and the spoken clip in
parts over the bridge, so the first word lands in about a second and a half. The watch carries
two-way audio with an **Audio replies** toggle on its row, and the **T-Deck** now works its own
microphone and runs the same code.

### System, security & devices

- **System & monitoring** — a **Process Monitor** with live CPU and memory readings, per-core
  graphs and a sortable process list; network **device discovery** with a one-row-per-address
  lister and a ping/`/device_query` scan; backup and restore; and a utility controller for the
  background chores, set per machine.
- **Self-updating** — a git watcher fast-forwards the checkout and reloads open tabs onto the new
  revision, keeping each tab's code and data in step; a machine with no route to the source pulls
  the tree as a git bundle from the newest reachable peer instead.
- **The mesh** — several machines keep one another in step without a central authority: code,
  app builds and data all move the same way ("whoever has the newest is the authority"), machines
  reach one another across whatever network they are on, and every machine can be logged into
  from another with a ticket. A deletion is carried as a tombstone until every device
  acknowledges it.
- **Utilities & security** — password and pseudonym generation, QR codes, encryption helpers,
  screen locking and a keyring-style secret store. A fresh browser pairs at the gate with a short
  code approved from Security's Devices view (and revoked there); a paper **Recovery code**
  re-pairs a device and restores access; and once a machine's key is pinned, unsigned or replayed
  peer traffic is refused.
- **Built-in help** — a **Help** app that explains any app, feature, function or device in plain
  language: hover (or long-press) a control for a hint, press **F1** for whatever window you are
  focused on, or use the question-mark button in a window's title bar. Its **Guide** is the chat
  that can also drive the screen (above).
- **The self-healing watch & the coding agent** — a watcher reads the server and browser logs (and
  the Guide's own conversations), catches the faults, and stages a fix, compile-checking and
  applying it only when you approve — or on its own, within a daily token budget — and listing
  everything it has fixed so far. Beside it sits a **Coding agent** chatbox in the Terminal and
  the IDE, with several agents able to work at once.
- **Devices & firmware** — first-class support for the T-Watch, T-Deck and Pico 2W, with remote
  control, a Bluetooth Low Energy bridge, a password-less websocket tunnel between machines, and
  encrypted sync. The ESP32 boards update **over the air** — the manager relays a chosen firmware
  image to the board's own update endpoint — or over USB from a button in the Embedded panel.
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
- **Front end:** Embedded-Perl (`.ep`) templates in `templates/`, rendered into a jQuery-driven
  "desktop in a browser" UI in `public/`; the manager's app scripts are served as one memoised,
  ETag-revalidated bundle.
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
| `templates/` | Embedded-Perl page templates |
| `public/` | Front-end JavaScript, CSS and images (including the icon sets in `public/icons/sets/`) |
| `desktop/` | The Linux app: the GTK dashboard, the CLI, the BlueZ BLE bridge and the embedded WebKitGTK view |
| `jp/`, `jt/`, `jw/` | Device firmware (Pico 2W, T-Deck, T-Watch) |
| `scripts/` | Supporting scripts — the dependency checker, the first-run wizard, the process killer, the app-release stager, the help auditor, the BLE bridge and the store invoice driver |
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

JawnOS is a work in progress. It ships with seventeen selectable icon sets and hover or long-press
hints throughout the interface, with the original hand-drawn icons still the default. Recent
attention has gone to **voice and the wake word** — the watch listens, ships a clip for
transcription, and now streams the spoken reply back in parts — and to the **Guide**, which
answers questions, drives the screen and now changes the calendar for you; to the **mesh**, so
machines carry code, app builds and data among themselves without a server; to the self-healing
watch that stages its own fixes; and to the apps around them: the new Chat, Phone, Camera and
Market apps, the Synth, the warehouse's on-hand and restock plan, and the evaluation reports.

## License

BSD 2-Clause. See [LICENSE](LICENSE). The third-party components JawnOS bundles or
redistributes — the Piper TTS engine and its voice models, and any bundled fonts — are listed
with their licences in [THIRD-PARTY.md](THIRD-PARTY.md).
