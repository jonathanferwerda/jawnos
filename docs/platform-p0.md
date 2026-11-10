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

**Expected gap:** none in the socket layer. Slice 2 moved control/log/watch,
and slice 4 moved the websocket worker, mailws, alarm and memory surfaces to
the same transport. What a clean run still proves is the process model (one
Daemon, a pipe, no `use threads`) and the go/no-go that follows it.

### Smoke result — 2026-11-09, v0.1.2474

Run from a spare worktree on the house box, with a temp `HOME`, a temp database
built from `database/schema.sql`, `JAWNOS_PORTABLE=1`, `JAWNOS_TRANSPORT=tcp`
and a free port range (working_port 46200, port 46300, ws 46301).

| Check | Result |
|---|---|
| 1. panel answers on the working port | pass (200) |
| 2. one process per purpose, no Prefork parent or worker pool | pass |
| 3. `starting fork`, conduit a pipe (fd1 `pipe:[…]`) | pass |
| 4. restart through `scripts/restart.pl` returns and the tree comes back | **fail** — the tree exited (status `frozen`, `signal=0`), panel `000` |
| 5. log view and process watch answer | pass (watch bound on 46207-46209) |

The restart failure was not the transport. `shut_down` swept `/proc` by command
line and `scripts/manager_killer.pl` matched every `President.pl` on the box, so
the smoke master stopped the live house's tree and the live master stopped the
smoke's — twice during the run, each time recovered by the master watchdog. To
the old sweep, two checkouts on one box were one tree.

Fixed in the same version: both sweeps are now held to the checkout they belong
to. The master chdirs to its root before it starts a child, so a child's cwd
names its checkout; `manager_killer.pl --cwd=DIR` keeps tree and master matches
to that directory, `shut_down` passes its root, and the master's own leftover
loop asks `pid_in_tree`. A cwd the kernel will not show (Android/SELinux, or no
`/proc`) keeps the old answer, so a stop is never missed. Shared helpers
(ollama, tts, ssh) are deliberately not scoped: they belong to the host, not a
checkout. `t/78` pins the two-checkout case.

Still to prove: checks 1-5 on a machine that serves nothing, recorded here. Do
not start a master from a worktree on the house box; the sweep is scoped now,
but the master also writes `~/.president`, which is the serving master's state.

#### Throwaway LXC re-run — 2026-11-09

A disposable Debian 13 LXC on the house's Proxmox host (4 cores, 4 GB), the only
checkout on it, running this commit. Same shape as above: temp `HOME`, a fresh
`database/jawnos.db` from `database/schema.sql`, `JAWNOS_PORTABLE=1`,
`JAWNOS_TRANSPORT=tcp`, ports 46200/46300/46301.

| Check | Result |
|---|---|
| 1. panel answers on the working port | pass (200) |
| 2. one process per purpose | pass (24 `President.pl`, one per purpose; no Prefork parent or pool) |
| 3. `starting fork`, conduit a pipe | pass (the President's fd0 and fd1 are both `pipe:[…]`) |
| 4. restart through `scripts/restart.pl` | pass — warm guard: accepted and verified in **0.8s**; the first (cold) guard ran ~5 min, longer than the client's 150s default, so pass `--timeout 600` once per checkout |
| 5. log view and process watch answer | pass (the log client returns bytes; the watch returns a 1451-byte Sereal frame) |

The restart record for the cold run still landed (`ok:1`, `verify_change: 1323
file(s) pass`) and the tree came back; only the caller gave up waiting, which is
the `--timeout` note above. Nothing in the cold path is portable-specific.

**Two checkouts, one box** — the case that disrupted the house. A second copy of
the tree with its own `HOME`, config and ports served alongside the first;
`kill -TERM` on the second master ran its `shut_down`. Its 23 Presidents
stopped; the first checkout's 24 kept the same pids and its panel stayed 200.
That is the scoped sweep working end to end, not just in `t/78`.

**Harness note:** a smoke config must name ports the tree actually binds. The
setup wizard's `--seed` default leaves `port` at 3000 while `working_port` is the
port served, and `tree_serving` asks *every* configured port — set `port` and
`working_port` consistently (or omit `port`) in a smoke config.

## Slice 2 (landed)

`lib/JawnOS/Transport.pm` is the one place that knows where the master's private
surfaces live:

- **Ports:** `working_port + 7` control, `+ 8` log, `+ 9` process watch. The
  occupied offsets are `+1` wss, `+2` watch/arm, `+3` bestow, `+4` coms, `+5`
  alarm, `+6` peer, `+101` plain WS. Slice 4 added `+10` alarm, `+11` memory,
  `+12` ws and `+13` mailws; one ws port carries every app (the payload names
  it). The base is `working_port`, then `port`, then 45545 when config.json
  names neither.
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

## Slice 3 (landed) — process, network and mDNS parsing

Process identity, state, CPU ticks and the process-group scan live in
`lib/JawnOS/Platform/Process.pm` with the Linux `/proc` backend;
`parent_guard.pl`, `Domain/Process.pm` and `Ble/Guard.pm` call it and keep
their own rules. Interfaces, the default gateway, the gateway MAC and `ip neigh`
live in `lib/JawnOS/Platform/Net.pm`; `Device.pm`, `Edt.pm` and
`manager_configure2.pm` call it. Avahi browse/publish lives in
`lib/JawnOS/Platform/Mdns.pm`; `Edt.pm` and `Network.pm` call it. A platform
that cannot answer gives `''`, `undef`, `[]` or `()` so the caller's fallback is
what runs. The macOS (`ps`/`sysctl`, `route`, `dns-sd`) and Windows
(`Win32::Process`/`tasklist`, `ipconfig`, DNS-SD) bodies, and the remaining
direct `/proc` readers (`jawn`, `manager_misc.pm`, `crew.pl`,
`scripts/manager_killer.pl`), are the P2/P3 work. `t/227-platform-process.t`
and `t/230-platform-net.t` pin the seams and the recorded parser fixtures.

What the slice moved, and what each backend replaces on P2/P3:

- start time, descendants, alive, kill: through `Platform::Process`
  (`Domain/Process.pm`, `parent_guard.pl`, `Ble/Guard.pm`, `manager_misc.pm`,
  `crew.pl`, `scripts/manager_killer.pl`); macOS `ps -o lstart`/`sysctl`;
  Windows `Win32::Process`/`tasklist`.
- interfaces, routes, neighbours: through `Platform::Net` in `Device.pm`,
  `Edt.pm`, `Network.pm` and `manager_configure2.pm`; macOS `ifconfig`/`route`;
  Windows `ipconfig`/`Get-Net*`/`netstat -ano`.
- mDNS: through `Platform::Mdns` in `Edt.pm` and `Network.pm` → `dns-sd`
  (macOS) and DNS-SD (Windows).

No hardware is needed for the parsing and fixture work.

## Slice 4 (landed) — the worker tail

The sockets a worker uses to hand work to another worker no longer depend on
`IO::Socket::UNIX`: no file in `lib/` or `perl/` imports it at compile time.
`lib/JawnOS/Transport.pm` now also names `alarm` (`+10`), `memory` (`+11`), `ws`
(`+12`) and `mailws` (`+13`), and maps a path back to its kind so the existing
per-app calls keep their shape.

- **Websocket worker:** one shared TCP ws port in portable mode carries every
  app (the payload names it); native still binds one path per app. The route and
the binder ask `ws_server_ensure`, so a second bind cannot take the port.
- **Alarm and memory:** the listener asks `server_args`, and both check the
  token on the decoded payload (`__transport_token` for the alarm's JSON line,
  `token` for the memory's Sereal frame).
- **SCO:** the client imports `SOCK_STREAM` from `Socket` and requires
  `IO::Socket::UNIX` only inside `_dial_unix`, so a Windows tree compiles.
- **Boot shape:** the master's `PERL5LIB` carries only local::lib, not the repo
  lib, so `President.pl` and `Devicews.pm` add `lib` to `@INC` themselves before
  their compile-time loads. A `use` without that BEGIN aborts the tree before it
  can log; `t/221` compiles both in that launch shape.
- **Tests:** `t/228-transport-tail.t` pins the compile guard and real TCP round
  trips for memory, ws and alarm; `t/222`/`t/223` cover the new kinds and the
  wiring; `t/221` covers the no-PERL5LIB boot.

The remaining P0 work is the written go/no-go, which now lives in
`docs/platform-go-no-go.md`; the smoke house runs on a spare machine, and the
checkout scope above is the one source change it forced.

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

- Resident loops and forks no longer have to be raw `fork()`: `subs::subprocessor`
  runs a registered named job or is a supervised child (`Platform/Job.pm`,
  `Platform/Server.pm`, v0.1.2530-2536), and `ReadWriteFork` sits behind the
  runner seam (`Platform/Runner.pm`, `Runner/Windows.pm`, v0.1.2508).
- `JawnOS::Platform::Process` has a Windows backend (v0.1.2589, `tasklist` + `Get-CimInstance`,
  fixture-tested); the live guard/killer path is not yet asserted. The macOS backend is not
  written, and the other Windows bodies are P3.
- `JawnOS::Platform::Net` and `::Mdns` are Linux backends; their macOS and
  Windows bodies are P2/P3, so a non-Linux box still gets the empty fallbacks.
  The same is true of the `Audio`, `Serial`, `Print` and `Shell` bodies.
- Database and certificate cold start now exist (`Domain/Key.pm` `database_bootstrap`,
  `Platform/TLS.pm`), and setup uses the same `lib/JawnOS/Database/Bootstrap.pm` path without
  `sqlite3` or `tail`. A clean Windows install was verified at v0.1.2612 (first `/manager` 200).
  Restart is the open gap: the master's accepted control stream never delivers a read, so
  `restart.pl` times out.
- No source imports `IO::Socket::UNIX` at compile time, but the SCO client still
  dials a UNIX socket at runtime; reception is `Later` on both native platforms.
- No Windows or macOS packaging exists yet.

## Definition of done for P0

- the probe is green on Linux, macOS and Windows (CI at least);
- a portable smoke house on Linux serves the panel, logs, and restarts;
- the suite is green with `JAWNOS_PORTABLE=1`;
- the written go/no-go on the Windows process model, with the fork surface
  named (`docs/platform-go-no-go.md`);
- the hardware checklist is ready before the machines arrive (this file).
