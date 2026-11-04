# scripts/tools — shareable diagnostic probes

Small, read-only-by-default probes for a JawnOS box that is hot, stuck, slow to
sync, or losing its BLE bridge. They take a PID / host / MAC / port as an
argument; nothing here contains a token, ticket URL, cookie, phone number,
address, or per-person path.

Run from the repo root, or with an explicit path. `sh` tools run under
`sh`/`dash`/`mksh`; `.py` tools need Python 3 (the phone's Termux Python is fine).

| Tool | Answers | Example | R/W |
|---|---|---|---|
| `cpuspy.py` | Which process is burning a core right now? (per-process CPU from `/proc`) | `./scripts/tools/cpuspy.py 3 15` | read |
| `pid-io.py` | Is this PID burning CPU, or moving bytes to a pipe/file? (`/proc/<pid>/io` rates) | `./scripts/tools/pid-io.py 12345 3 ~/manager.log` | read |
| `pid-where.sh` | What is this PID doing? syscall samples, io deltas, fds, cwd | `./scripts/tools/pid-where.sh 12345` | read |
| `hot-catch.sh` | Which process sustains a core, and what is it doing? (auto-catch, then dump) | `./scripts/tools/hot-catch.sh --pattern jawn-bt --seconds 600` | read; `--out FILE` writes |
| `jawn-tree.sh` | What does the JawnOS process tree look like (parent, age, ticks, PURPOSE)? | `./scripts/tools/jawn-tree.sh` | read |
| `fork-watch.sh` | Is something spawning `jawn-bt`/helpers in a loop, and how fast is the log growing? | `./scripts/tools/fork-watch.sh jawn-bt 20` | read |
| `mem-report.py` | Where is memory going, by category and by JawnOS PURPOSE? (RSS/PSS) | `./scripts/tools/mem-report.py` | read |
| `heat-watch.sh` | Is the phone hot / charging / draining, and which worker is busy? | `./scripts/tools/heat-watch.sh --interval 60 --count 10` | read; `--log FILE` writes |
| `ble-bridge-probe.py` | Does the BLE bridge read loop block, or does `select()` return immediately? | `./scripts/tools/ble-bridge-probe.py --seconds 6` | read |
| `ble-mock.py` | Fake bridge (`hold`/`close`/`data`) to test `jawn-bt listen` with no device | `./scripts/tools/ble-mock.py 45998 hold` | read (binds a port) |
| `port-scan.py` | Which port is open in a range (e.g. Android wireless debugging)? | `./scripts/tools/port-scan.py 192.0.2.10 30000 50000` | read |
| `net-latency.sh` | Which peer is slow or unreachable, and is it connect or server time? | `./scripts/tools/net-latency.sh --port 45545 192.0.2.1 192.0.2.2` | read |
| `sync-watch.sh` | Is a sync stuck, how many pulls finished, and is the box loaded? | `./scripts/tools/sync-watch.sh --samples 5` | read; `--log FILE` writes |
| `db-state.sh` | Is the database in WAL, how big is the WAL, can read-only see new rows? | `./scripts/tools/db-state.sh ./database/jawnos.db` | read |
| `serial-watch.py` | What is the bridge board printing, with timestamps? (DTR-aware) | `./scripts/tools/serial-watch.py /dev/ttyACM0 30 reset` | read; `reset` reboots the board |
| `android-battery-log.sh` | Android battery/power/wakefulness and top CPU consumers over adb | `./scripts/tools/android-battery-log.sh SERIAL 40 15` | read |

## Notes

- `cpuspy.py` and `pid-io.py` are ports of the scratch `cpuspy.pl` and
  `iospy.pl`; `ble-bridge-probe.py`/`ble-mock.py` are ports of `bt_probe.pl`/
  `ble_mock.pl`. The algorithms are unchanged; only argument handling and
  absolute paths were made portable.
- `hot-catch.sh` prints evidence to stdout unless `--out FILE` is given (then it
  appends, per the `# WRITES:` header).
- `android-battery-log.sh` shells out to `adb`; it never uses a credential and
  runs only `dumpsys`/`settings get`/`ps`.

## Deliberately left behind

- `adb_press.sh`, `adb_race.sh`, `adb_state_cpu.sh`, `adb_children.sh`,
  `adb_stop_named.sh`, `adb_plain.sh` — one-off `email_test` fixture repros
  that POST start/stop writes and depend on a live ticket URL (a token).
- `phone_diag*.sh`, `phone_hot*.sh`, `phone_live.sh`, `phone_sock.sh`,
  `phone_kids.sh`, `phone_stuck.sh`, `phone_four.sh`, `phone_chain.sh`,
  `phone_window.sh`, `phone_schema*.sh`, `phone_sizes.sh`, `phone_synclog*.sh`,
  `phone_query.sh`, `phone_treecheck.sh`, `phone_status.sh` — hardcoded PIDs,
  timestamps and fixture rows; their useful parts are covered by
  `pid-where.sh`, `hot-catch.sh`, `jawn-tree.sh`, `db-state.sh`,
  `sync-watch.sh`.
- `bt_repro.pl`, `bt_second.sh`, `phone_bt_cycle.sh`, `connect_dev*.pl` — tied
  to `scripts/jawn-bt` or a fixture, and they kill/restart processes; use
  `ble-bridge-probe.py` + `ble-mock.py` instead.
- `cpu_sampler.pl`, `cpu_inspect.sh`, `cpu.sh`, `cpu_watch.pl`,
  `cpu_report.pl` — narrower purpose-attribution or hardcoded master PIDs and a
  live cookie jar; superseded by `cpuspy.py`/`jawn-tree.sh`.
- `proc_dump.pl`, `subprocesses_probe.pl` — read the launcher's private
  `~/.process_watch` Sereal socket; not portable without the launcher.
- `load_probe.pl`, `render_htop.pl`, `log_reader_snapshot.pl` — fixture
  snapshot probes with absolute `chdir` paths.
- `ble_leak.py`, `ble_leak2.py`, `voice_arm_leak.py` — firmware heap probes
  hardcoding `/dev/ttyACM0` and board commands; `serial-watch.py` covers the
  console need.
- `ble_adopt_probe.pl`, `ble_read_probe.pl`, `ble_reply_probe.pl`,
  `probe_ble_props.py` — live scan / BlueZ probes with hardcoded MACs, UUIDs or
  D-Bus paths.
- `bridge_cluster_probe.py` — reads a device token and pushes files to the
  device; writes and unsafe to share.
- `sync_diag_probe.pl` — contains peer `signatorial` secrets; rejected outright.
- `wake_probe.py`, `keepawake_test.py`, `webkit_cpu_probe.py`, `qa_poll.pl`,
  `qa_health.pl`, `cdp_*.mjs` — UI, QEMU or browser-debugging probes outside
  the CPU/process/BLE/network/sync brief.
- `watch_serial.py` — superseded by `serial-watch.py`.
- `tiltlog_*.py` — post-processing of an already captured tilt log, not a live
  probe.
