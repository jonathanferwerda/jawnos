# P0 go/no-go — native Windows and macOS

**Decision: GO.** P0 asked one question (roadmap §8): can the tree boot, serve
and restart with no Prefork, no PTY, no `use threads` and no UNIX socket? On
Linux it can, end to end. Nothing P0 found blocks P1. The Windows rows in
Appendix B are open for one reason only — there is no Windows box — and each is
already a P1/P3 task listed below.

Measured at v0.1.2477 on a throwaway Debian 13 LXC (4 cores, 4 GB) with no other
checkout on it, `JAWNOS_PORTABLE=1 JAWNOS_TRANSPORT=tcp`, a temp `HOME` and a
fresh `database/jawnos.db` from `database/schema.sql`; the two-checkout case ran
on the house box. Run detail: `docs/platform-p0.md`.

## What P0 proved

- **Boot and serve.** The panel answered 200 on the working port. `/manager/health`
  is an unauthenticated route (`lib/JawnOS/Routes/manager_misc13.pm:31`, action
  `lib/JawnOS/Controller/manager_misc13.pm:568`) and answers 200 on the house tree;
  the literal request was not repeated on the smoke box, which is the one check to
  repeat in P1's CI.
- **Process shape.** 24 `President.pl`, one per server purpose, no Prefork parent
  and no worker pool; the app's ports 46200-46205 and the shared ws port 46301.
- **Conduit.** The tree's fd0 and fd1 are both pipes. No PTY anywhere in the run.
- **Restart.** A warm restart through `scripts/restart.pl` was accepted and
  verified in 0.8s and the tree came back. The first (cold) verify guard took
  ~5 min, past the client's 150s default; the record still landed and the tree
  returned. Use `--timeout 600` once per checkout.
- **Private surfaces over TCP.** Control answered the status JSON with the
  transport token, the log client returned bytes with the token in its first
  line, and the process watch returned a 1451-byte Sereal frame with the token in
  the record. Same JSON lines as before; the watch frame is unchanged.
- **Two checkouts, one box.** Stopping a second checkout's master left the first
  checkout's 24 Presidents with identical pids and its panel at 200.
- **Suite.** `JAWNOS_PORTABLE=1 perl scripts/run_tests.pl --jobs 2` → 333 files,
  14,493 assertions, PASS.
- **Probe.** `JAWNOS_PORTABLE=1 JAWNOS_TRANSPORT=tcp perl scripts/platform_probe.pl
  --json --check` → `use_fork: 0`, `use_pty: 0`, `use_unix_socket: 0`,
  `transport: "tcp"`, `missing_required: []`.

## Appendix B, answered

| # | Question | Answer | What closes it |
|---|---|---|---|
| 1 | Boot and serve `/manager/health` with `fork` disabled? | **Proven on Linux.** Panel 200 under portable mode; the route is unauthenticated and 200 on the house tree. | One curl on the next portable run, then a CI assertion. |
| 2 | Does one `Mojo::Server::Daemon` per purpose replace Prefork (main, websocket, alarm, teletype)? | **Yes, mechanically.** One Daemon per purpose served the panel, the ws port and the private surfaces. Throughput is not measured: one Daemon serializes a blocking handler, and P0 did not profile routes. | P1 profiles the routes that block before choosing N Daemons vs Minion. |
| 3 | Do background jobs (upgrades, coding, tunnels, sync) run through Minion or a managed worker? | **Proven on Linux.** Minion with the SQLite backend, the coding daemon outside the tree (`coding.pid`, `coding-queue.db`), and the utility runner (24 slots; remote sync, worktree gc, weather and an app release in the run log). | The spawner is still `fork()` — see the P1 condition on the process layer. |
| 4 | Does the master's output work without a PTY, or does ConPTY work on the minimum Windows version? | **Without a PTY.** fd0/fd1 are pipes; master output, the log view and control all worked. ConPTY is not needed for the master. | A pipe runner replacing `ReadWriteFork` is P1 work, not a ConPTY question. |
| 5 | Do control/log/watch work over loopback TCP with the existing token and the same JSON lines? | **Yes.** Control and log use the same JSON lines with the same token; watch stays a 4-byte length plus Sereal, whose record carries the token. All three round-tripped on the smoke box. | Nothing; pinned by `t/222` and `t/228`. |
| 6 | Does the parent guard survive a killed master (Job Object or watchdog)? | **Partial.** `parent_guard.pl` exists and ran (`jawn guard`), and a deliberate TERM runs `shut_down` correctly. A SIGKILL of the master was not exercised. Windows needs `TerminateProcess`/Job Objects — `lib/JawnOS/Platform/Process.pm:150`. | A kill -9 test on Linux; Job Object design in P1, acceptance in P3. |
| 7 | Does `manager_killer` find the right processes through `Win32::Process::Info`/`tasklist`? | **Linux:** yes, and now scoped to its own checkout (`t/78`, plus the two-checkout run). **Windows:** open — the script reads `/proc` directly and the `Platform::Process` Windows backend is not written. | The P1 backend; see the checkout-identity note below. |
| 8 | Do the XS modules build and load under the chosen Strawberry Perl? | **Open.** Linux loads all of them: CryptX 0.085, DBD::SQLite 1.76, Net::SSLeay 1.94, Sereal 5.004, `ReadWriteFork` 2.02, Mojolicious 9.39, `missing_required: []`. | A Windows CI job that builds the set and runs `platform_probe.pl`. **This is the one row that can still stop the project.** |
| 9 | Do the fixed and tunnel port ranges pass Windows Firewall on a private network? | **Open.** On Linux the app's Daemons bind `0.0.0.0` (46200-46205); the master's private surfaces bind `127.0.0.1` (46207-46209), so only the app range needs a rule. | An installer rule for the app range on private networks; an acceptance run on a real LAN. |
| 10 | Does the Qt shell's `--probe`, the app-key bridge and the plain loopback WS path all pass? | **Partial.** The shared ws port bound and the worker answered (ws round trips in `t/228`); the Qt shell and the app-key bridge ran on the house box but not against a portable tree — the smoke box had no display. | Run the desktop app against a portable tree on a Linux desktop or VM; then macOS and Windows. |

## Conditions on the GO (P1 input)

1. **Process layer.** Replace `Mojo::IOLoop::ReadWriteFork` (`jawn:334`,
   `jawn:1695`, `lib/JawnOS/Manager.pm:96`, `lib/JawnOS/Domain/Ble2.pm:644`,
   `lib/JawnOS/Manager/Part25.pm:43`) and the nine raw `fork()` sites
   (`Domain/Process.pm:374`, `Domain/Coding.pm:640`, `Domain/House.pm:552`,
   `Domain/Network.pm:511`, `Manager/Part06.pm:200,256`, `President.pl:712`,
   `parent_guard.pl:44`, `President/prefork_autoscale.pl:32`) with one supervised
   spawn: `Win32::Process` plus a Job Object on Windows, `posix_spawn` on macOS.
2. **Checkout identity without `/proc`.** The sweeps now keep to their own
   checkout by reading `/proc/<pid>/cwd` (`jawn` `pid_in_tree`,
   `scripts/manager_killer.pl --cwd`). Windows does not hand out another
   process's cwd cheaply, so the portable answer is to spawn children with the
   **absolute** checkout path (the command line then names the checkout) or pass
   `JAWNOS_TREE` in the child environment. Do not rebuild the Linux trick on
   Windows.
3. **`Platform::Process` backends.** macOS (`ps`/`sysctl`) and Windows
   (`tasklist`/`Win32::Process`) replace the `/proc` reads in the reaper, the
   guard and `manager_killer`.
4. **XS in CI.** The Windows job is the gate for Q8: Strawberry Perl, the pinned
   module set, `platform_probe.pl --json --check` green, and the suite.
5. **Qt and WS against a portable tree.** `--probe`, the app-key bridge and a ws
   round trip with no Prefork behind them.

## What would stop it

Only two rows can: **Q8**, if the XS set cannot be built reproducibly for
Windows, or **Q6**, if the minimum Windows version gives no Job Object
equivalent for the guard. Either one stops the native path and takes
`docs/migration-roadmap.md` (roadmap §10) — that is the trigger, not a schedule
slip.
