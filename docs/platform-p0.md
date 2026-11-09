# Platform P0 — portable mode, probe and hardware gate

**Status:** slices 1–2 landed 2026-11-08. The answers are recorded in
`docs/platform-roadmap.md` §3. No Mac or Windows hardware is present yet, so this
runbook separates what Linux can prove now from what waits for the machines.
**Related:** `docs/platform-roadmap.md` (the plan), `docs/migration-roadmap.md`
(the Go alternative), `docs/docker.md` (the headless server).

## What P0 proves

Native Windows is the risk, and the risk is the process model, not Qt. P0 asks
one question on Linux: **can the tree boot, serve and restart without Prefork,
without a PTY, and without `use threads`?** If yes, the remaining work is
platform modules and packaging (P1–P3). If no, the honest exit is the Go path in
`docs/migration-roadmap.md`.

P0 cannot prove WinRT BLE, CoreBluetooth, WASAPI, CoreAudio, the spooler, the
serial lane, notarization or signing without the hardware. Those are P2/P3.

## Slice 1 (landed)

- `lib/JawnOS/Platform.pm` — `portable`, `strict`, the `*_available`/`use_*`
  split, the transport choice, and the `JAWNOS_DIR`/`JAWNOS_DATA_DIR` overrides.
- `scripts/platform_probe.pl` — the capability report, human and JSON, with
  `--check` for CI.
- `perl/President.pl` — `run_server`/`run_dev_server` choose a single
  `Mojo::Server::Daemon` in portable mode and keep Prefork otherwise. `use
  threads` is gone; the browser open is detached instead.
- `jawn` — the master runs the tree on a plain pipe in portable mode and keeps
  the PTY otherwise.
- Tests: `t/219-platform-capabilities.t`, `t/220-platform-probe.t`,
  `t/221-portable-entrypoints.t`.
- CI: `.github/workflows/platform-p0.yml` probes Linux, Windows and macOS. The
  Windows/macOS jobs are report-only until the hardware landings.

## Run it on Linux now

```sh
perl scripts/platform_probe.pl
perl scripts/platform_probe.pl --json --check
JAWNOS_PORTABLE=1 perl scripts/run_tests.pl --jobs 2
```

The probe starts nothing. The suite is the same one the pre-push hook runs,
with portable mode on; a failure here is a real dependency on Prefork, a PTY or
UNIX sockets.

### Smoke house

A human on a **spare checkout or spare machine** may start the master; an agent
must not start `./jawn` on the serving box. Use a production config:

- copy `config.json.example` to `config.json`;
- set `environment` to `production`, `open_browser` to `no`, and a free
  `working_port`;
- run `JAWNOS_PORTABLE=1 ./jawn`.

Check, in this order:

1. the panel answers on the working port (ticket URL or the locker port);
2. `ps -o pid,ppid,cmd -C perl` shows one process per server purpose, not a
   Prefork parent with workers;
3. the master's first log line says `starting fork` and the conduit is a pipe
   (no PTY);
4. a restart through `perl scripts/restart.pl --reason "p0 smoke"` returns a
   verdict and the tree comes back;
5. the log view and the process watch still answer.

**Expected gap:** control, log and watch moved to the transport in slice 2, but
the websocket worker's own control socket and the alarm/memory sockets still use
`IO::Socket::UNIX`. A clean P0 run should note the rest, not hide it.

## Slice 2 (landed)

`lib/JawnOS/Transport.pm` is the one place that knows where the master's private
surfaces live:

- **Ports:** `working_port + 7` control, `+ 8` log, `+ 9` process watch. The
  occupied offsets are `+1` wss, `+2` watch/arm, `+3` bestow, `+4` coms, `+5`
  alarm, `+6` peer, `+101` plain WS. The base is `working_port`, then `port`,
  then 45545 when config.json names neither.
- **Files:** the master writes `~/.president/transport_base` and
  `~/.president/transport_token` (0600) after the run-state wipe, and rotates
  the token on every boot. Both files survive the wipe and a reload.
- **Wire:** unchanged in shape. Control and log stay one JSON line each way; the
  watch stays a 4-byte length prefix plus Sereal. The token rides in the request
  object (control), in the first line (log), or as a record field (watch), and
  each listener rejects a missing or wrong token.
- **Clients:** `perl/control.pl` (`control::send`), `lib/JawnOS/LogBus.pm`, and
  the process watch in `lib/JawnOS/Domain/Calendar.pm` and `Process.pm` read the
  same two files and choose the same transport.
- **Guard:** the one-master probe at the top of `jawn` speaks the same transport,
  so a second launch stands down without a UNIX socket.
- **Native:** AF_UNIX stays the default on Linux and macOS. `JAWNOS_TRANSPORT=tcp`
  forces TCP for the spike, so the same path is exercised on Linux before a
  Windows box exists.
- **Tests:** `t/222-transport.t` (unit plus real control and log round trips) and
  `t/223-transport-wiring.t`.

To exercise it on a spare checkout:

```sh
JAWNOS_PORTABLE=1 JAWNOS_TRANSPORT=tcp ./jawn
```

The base and token files appear under `~/.president`; the panel, the log view,
the process watch and `perl scripts/restart.pl --status` must all still answer.

### One Daemon that grows

A single `Mojo::Server::Daemon` is one process and one event loop. It holds many
connections, but a blocking handler serializes them; growing in the parallel
sense needs more processes. Without fork, the portable shape is N Daemons on
distinct loopback ports behind a small master-side dispatcher, or the slow work
moves to Minion. P0 measures which routes actually block before choosing.
Portable mode currently runs one Daemon per purpose; the `workers` argument is a
hint for the dispatcher, not a Prefork pool.

## Slice 3 (in flight) — process and network parsing

Process identity, state, CPU ticks and the process-group scan now live in
`lib/JawnOS/Platform/Process.pm` with the Linux `/proc` backend;
`parent_guard.pl`, `Domain/Process.pm` and `Ble/Guard.pm` call it and keep
their own rules. A platform without `/proc` answers `''`, `undef` or `[]`, so
the caller's existing fallback is what runs. The macOS (`ps`/`sysctl`) and
Windows (`Win32::Process`/`tasklist`) bodies, and the remaining direct `/proc`
readers (`jawn`, `manager_misc.pm`, `crew.pl`, `scripts/manager_killer.pl`), are
the rest of this slice. `t/227-platform-process.t` pins the seam, including the
zombie/reaped distinction and the grandchild group scan.

Put process identity and state behind one module and test the macOS
implementation against recorded fixtures on Linux:

- start time, descendants, alive, kill: `/proc` today (`Domain/Process.pm`,
  `parent_guard.pl`, `Ble/Guard.pm`, `manager_misc.pm`, `crew.pl`,
  `scripts/manager_killer.pl`); macOS `ps -o lstart`/`sysctl`; Windows
  `Win32::Process`/`tasklist`.
- interfaces, routes, neighbours: `ifconfig`, `ip route`, `netstat -avnpt`,
  `arp` in `Device.pm`, `Edt.pm`, `Network.pm` and `manager_configure2.pm`;
  macOS `ifconfig`/`route`/`netstat`; Windows `ipconfig`/`Get-Net*`/
  `netstat -ano`.
- mDNS: `avahi-browse`/`avahi-publish-service` → `dns-sd` (macOS) and DNS-SD
  (Windows).

No hardware is needed for the parsing and fixture work.

## Hardware gate

### Machines and devices

- One Apple Silicon Mac (primary), macOS current; one Intel Mac or a CI runner
  for the x64 build.
- One Windows 11 x64 mini-PC: BT 5.x, USB-A and USB-C, wired/wireless LAN,
  audio in/out, an IPP printer.
- A Pico 2 W (alarmclock firmware), a watch, a deck or phone for the mesh, and a
  known-good USB Bluetooth dongle.
- A USB serial board (ESP32) for the serial lane.
- No reception rig for v1 (Q8 is `Later`).

CI covers compile and probe on `windows-latest` and a macOS runner; the
hardware acceptance run is recorded by hand against a version.

### Common acceptance

On a fresh machine with no Perl, Python, Docker or WSL installed by the person:

1. install the package; first run opens the app and the unlock code;
2. the panel, app windows, Browse and the session bar work;
3. a restart from the app returns a verdict and the tree returns;
4. the log view, backup and restore work;
5. autostart and auto-update work; uninstall leaves no service behind;
6. the probe reports every required module and the expected transport.

### macOS

- Notarized `.app`, hardened runtime, signed dylibs and bundled Perl.
- Menu bar, LaunchAgent, Sparkle-style update.
- CoreBluetooth watch link; CoreAudio music and TTS; `/dev/cu.*` serial and an
  OTA; `dns-sd` discovery; CUPS print; clipboard/open.
- Entitlements and privacy: Bluetooth, local network, microphone, camera,
  user-selected files; Keychain for the ticket.

### Windows

- Signed MSI/MSIX, tray, "Start with Windows", firewall rules for the fixed and
  tunnel ranges, updater.
- WinRT BLE; WASAPI audio and TTS; `COM*` serial and an OTA; DNS-SD; spooler
  print; clipboard/toast/`ShellExecute`; Credential Manager/DPAPI for the ticket.
- No WSL, Docker, Perl or Python installed by the person.

Record the version, OS build, CPU, adapter, printer and board with each result,
against the `Must` rows in `docs/platform-roadmap.md` §7.

## Known gaps — do not mistake these for P0 success

- Resident loops still fork through `subs::subprocessor`; Windows needs the
  supervised process layer (P1/P3).
- The subprocessor reaper reads `/proc` through `JawnOS::Platform::Process`;
  its macOS and Windows backends are not written yet, so a non-Linux box still
  gets the empty/liveness fallbacks rather than a native answer.
- `Mojo::IOLoop::ReadWriteFork` is the master's runner; Windows needs a
  `Win32::Process` equivalent.
- The Minion worker is itself a subprocessor.
- `lib/JawnOS/Manager.pm`, `perl/Websocket.pl` and `perl/Alarm.pl` still `use
  IO::Socket::UNIX` at compile time; the websocket worker control socket and the
  alarm/memory sockets need the same treatment before a Windows boot.
- The memory (`~/.president/memory`) and alarm (`~/.president/alarm`) sockets
  stay UNIX; they need a TCP path or a clean no-op on Windows.
- No Windows or macOS packaging exists yet.

## Definition of done for P0

- the probe is green on Linux, macOS and Windows (CI at least);
- a portable smoke house on Linux serves the panel, logs, and restarts;
- the suite is green with `JAWNOS_PORTABLE=1`;
- a written go/no-go on the Windows process model, with the fork surface named;
- the hardware checklist is ready before the machines arrive (this file).
