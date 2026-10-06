# JawnOS

**A personal, self-hosted operating environment — "my operating system… kinda."**

JawnOS is a long-running hobby project by Jon ("Jawn") Ferwerda that turns a single Perl web
server into a personal command centre. It isn't really an operating system — it's a
browser-based dashboard that pulls together the things one person actually does with a
computer: managing files and media, keeping track of appointments and money, logging where
you've been and what you've been doing, taking notes, sending mail, and driving a handful of
handheld and wearable devices.

It works with the **LilyGo T-Watch S3**, the **LilyGo T-Deck (Plus, with GPS)**, and the
**Raspberry Pi Pico 2W**, and it has been wired into some home-automation bits and pieces.

It's still under active development, and finishing it is a "someday, hopefully" kind of goal —
but it's genuinely useful in the meantime, and I hope it's of some use to you too.

## Features

- **Files & media** — browse folders, play video and audio, and view photos through an
  on-the-fly thumbnailer with a disk cache.
- **Appointments & scheduling** — a full calendaring system with alarms, recurring
  appointments, reminders, and calendar export.
- **Money** — budgeting, invoicing, and day-to-day accounting helpers.
- **Location & activity** — location logging, travel history, distance/speed calculations,
  and a "father time" activity clock.
- **Notes & documents** — note-taking, document scanning, OCR (Tesseract), barcode/QR
  scanning (zbar), and PDF rendering (WeasyPrint).
- **Communication** — email (IMAP/SMTP), SMS, and an internal message/paper-route system.
- **AI** — chat and image generation through local [Ollama](https://ollama.com) models and
  Cloudflare Workers AI, plus speech (espeak) and transcription (whisper.cpp).
- **Utilities & security** — password and pseudonym generation, QR codes, encryption helpers,
  screen locking, and a keyring-style secret store.
- **Devices** — first-class support for the T-Watch, T-Deck and Pico 2W, with remote control,
  SSH tunnelling, and encrypted sync between machines.

## How it's built

- **Backend:** Perl, using [Mojolicious::Lite](https://mojolicious.org) as the web framework.
  `President.pl` is the entry point and boots the HTTP/WebSocket server, background workers
  ([Minion](https://metacpan.org/pod/Minion)), and the rest of the machinery.
- **Data:** SQLite (via `Mojo::SQLite` / `SQL::Abstract`). Most internal message passing between
  processes is [Sereal](https://metacpan.org/pod/Sereal)-encoded over Unix sockets.
- **Real-time:** WebSockets push updates to the browser so windows, notifications and status
  stay live without polling.
- **Front end:** Embedded-Perl (`.ep`) templates in `templates/`, rendered into a jQuery-driven
  "desktop in a browser" UI in `public/`.
- **Firmware:** Arduino sketches under `jp/`, `jt/` and `jw/` for the handheld/wearable devices.

### Repository layout

| Path | What it is |
| --- | --- |
| `President.pl` | Entry point — boots the Mojolicious app, workers and sockets |
| `jawn` | Supervisor — runs `President.pl` in a PTY and restarts it if it dies |
| `Manager.pl` | The main application: routes and the bulk of the features |
| `gb.pl` | Global state shared across the app |
| `subroutines.pl` | Shared helper library |
| `Websocket.pl` | WebSocket server and live updates |
| `Alarm.pl`, `Music.pl`, `pen.pl`, `teletype.pl`, `watch.pl`, `hooks.pl` | Feature modules (alarms, music, notes, terminals, smartwatch, device hooks) |
| `templates/` | Embedded-Perl page templates |
| `public/` | Front-end JavaScript, CSS, hand-drawn icons and images |
| `jp/`, `jt/`, `jw/` | Device firmware (Pico 2W, T-Deck, T-Watch) |
| `scripts/` | Supporting scripts |
| `database/` | Starting (encrypted) database |

## Requirements

- Perl 5 with the CPAN modules listed in the installation section below
  (`Mojolicious`, `Mojo::SQLite`, `Minion`, `Sereal`, `Crypt::Simple`, and friends).
- A handful of command-line tools: `ffmpeg`, `imagemagick`, `tesseract`, `sqlite3`, `qrencode`,
  `zbar`, `espeak`, `curl`, `rsync`, `openssl`, `sshpass` and `autossh` (see below).

## Installation

### Android (Termux)

Download and install F-Droid.

Install Termux.
Install Termux:api.

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
```

Activate developer settings by going to Settings -> About Device -> Software Information.
Tap Build Number 7 times.

In Developer options turn on Wireless debugging.
Tap it, then pair device.

```
adb pair ip:port
adb connect ip:port
adb shell settings put global settings_enable_monitor_phantom_procs 0
adb shell settings put global max_phantom_processes 2147483647
```

```
cd jawnos

chmod +x President.pl

To run

./President.pl
```

### Debian

```
sudo apt update; sudo apt upgrade;
sudo apt install net-tools lib32z1-dev cpanminus \
ssh espeak build-essential zip openssl libssl-dev \
perl tesseract-ocr imagemagick sqlite3 sshpass \
ssh curl sox iproute2 qrencode rsync ffmpeg libbarcode-zbar-perl \
tmux weasyprint autossh net-tools dnsmasq ollama

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
GatewayPorts yes
```

Make swap (if not already created):

```
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Edit sudoers to allow dnsmasq to be restarted:

```
jawn ALL=(ALL) NOPASSWD: /usr/bin/pkill -HUP dnsmasq
```

Free up port 53 by stopping systemd-resolve:

```
sudo nano /etc/systemd/resolved.conf
DNSStubListener=no
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
```

Tell dnsmasq to look in the `jawnos/server/hosts` directory:

```
sudo mkdir -p /etc/dnsmasq.d/hosts/
```

Add this line to `/etc/dnsmasq.conf`:

```
addn-hosts=/etc/dnsmasq.d/hosts/
```

```
sudo systemctl restart dnsmasq
```

Own the folder:

```
sudo chown -R $USER:$USER /etc/dnsmasq.d/hosts/
```

Put the folder location in the config:

```
"dnsmasq_location": "/etc/dnsmasq.d/hosts/"
```

```
cd jawnos
./President.pl
```

### Manjaro

```
sudo pacman -Syu
sudo pacman -S base-devel cpanminus sqlite3 \
chromium xclip rsync sshpass certbot zip \
imagemagick espeak-ng tesseract xsane sox \
net-tools xdotool qrencode zbar fprintd python-weasyprint \
autossh lm_sensors ollama cmake python-pip

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

## Post-install

To access the database, move or copy `database/initial.enc` to your home directory.
Then copy the `config.json.example` file to `config.json`:

```
cp -v database/initial.enc ~/initial.enc
cp -v config.json.example config.json
```

Or just modify the existing `config.json`.

In `config.json`, change `signatorial` to a file on your computer that won't change. It'll read
that file when the program starts, generate an MD5, and use it to encrypt the cookies.

```
cd jawnos
./President.pl
```

Your default browser should automatically open with the database highlighted.
Password: `password`

## Status

JawnOS is a work in progress. A more sophisticated icon set is on the roadmap — the current
icons are hand-drawn.

## License

BSD 2-Clause. See [LICENSE](LICENSE).
