# `qa/` — the instance-level suite

`t/` tests functions. `qa/` tests the *running house*: every route over HTTP, a
real browser, the Android app, the QEMU image, and the CPU/memory the tree uses
while all of that happens.

Nothing here touches the live database. That is the design constraint the rest
of this file is about.

## Run it

```sh
perl qa/run.pl                     # smoke: t/ + signed-in route pass
perl qa/run.pl --profile full      # adds the anonymous gate pass
perl qa/run.pl --layers l1         # route layer only
perl qa/run.pl --layers l2         # database contracts and query plans
perl qa/run.pl --layers l3         # UI: Chromium breadth + WebKitGTK engine
perl qa/run.pl --source worktree   # test uncommitted code
perl qa/run.pl --no-namespace      # read the warning first
perl qa/run.pl --layers l0         # just the old regression suite
```

Results land in `$HOME/jawnos-qa/runs/<stamp>/` (override with `--root`):

```
results/report.md      the human summary
results/report.json    the same, machine-readable
results/routes.tsv     one row per request
results/monitor.jsonl  one CPU/memory sample per second
logs/                  instance output and the PTY transcript
tree/ home/            the throwaway copy and its private home
```

`report.md` opens with the fence audit: how many instance processes existed, how
many referenced the live database (**must be 0**), whether the PID and net
namespaces were real, and whether the live repo was mounted read-only.

## The fence

The app hardwires its database to `<install dir>/database/jawnos.db`, where the
install dir is resolved from `perl/subroutines.pl`'s **real** path. A symlink
farm (the trick `t/lib/JawnOSTest.pm` uses, safely, because it never writes)
would resolve back to the live tree. So:

1. **A real copy.** `git archive HEAD` into `--root`, never a symlink tree. The
   copy has `database/schema.sql` and `database/initial.enc` only.
2. **A fresh house.** `scripts/jawnos_setup.pl --seed --code 424242` builds the
   database from the factory seed. No user secret, no personal rows.
3. **User + PID + net + mount namespaces** (`unshare`):
   - *PID*: `scripts/manager_killer.pl` stops "everything jawn runs" by process
     name, machine-wide. A second tree calling it can kill the live tree. In its
     own PID namespace it can only see itself.
   - *net*: the tree binds `https://*:PORT`; inside a netns that is loopback
     only, so the QA house is never on the LAN and cannot reach a peer, a mail
     relay or a model API.
   - *mount*: the live repo is bind-mounted read-only and `/tmp` is a private
     tmpfs.
4. **SIGKILL teardown.** Never the graceful path - that runs
   `manager_killer.pl`.
5. **An audit.** After the route pass, every instance PID's `/proc/<pid>/maps`
   and fds are checked for the live database. SQLite mmaps it, so maps is the
   check that catches a wrong path.

If `unshare` or unprivileged user namespaces are unavailable, the runner
**refuses** to run (pass `--no-namespace` to override, and read the warning).

The live files are snapshotted (inode/size/mtime) before and after for the
report. They may legitimately move because the live app is running; that is
recorded as drift, not as a verdict. The verdict is the PID audit.

## Layers

| Layer | What | Status |
| --- | --- | --- |
| `l0` | `prove -l t` (runs outside the fence; it is hermetic) | done |
| `l1` | every classified GET route over HTTP, signed-in and anonymous; timings; crash detection + restart; fence audit | done |
| `l2` | database contracts: integrity, stamps, real query plans | done |
| `l3` | Chromium CDP smoke + WebKitGTK engine probe | experimental |
| `l4` | Android emulator, WebView CDP, PSS/jank/start | scaffolded |
| `l5` | QEMU image boot, first-boot seed, persistence, host/guest measures | scaffolded |

### l1 classification

796 routes. The suite never guesses: `Probe::classify` sends a route only when
a policy rule names it as a read. Everything else is recorded as skipped with a
reason, and the report counts them. The policy is `qa/routes.policy.json`:

- `skip` - writes, hardware, peers, mail, model calls, heavy file walks. A POST
  is skipped by default even without a rule.
- `tolerate` - routes that legitimately answer 500 without the query arguments
  the UI sends; recorded as warnings so they cannot hide a regression.
- `tier_exempt` - rails that authenticate themselves (the padlock protocol), so
  a resident session is expected to reach them even though the tier table says
  `citizen`.
- `allow` - a way to opt a specific write back in when its turn comes.

If a route takes the tree down, the suite names it, restarts the instance and
continues; a dead tree must not hide the next hundred routes.

### l2 — the database

The factory seed is the schema as it shipped; a boot runs the app's migrations
and `app_schema_ensure`. `l2` boots the copy once (with a loopback session),
stops it, then reads the database read-only through `sqlite3`:

- `PRAGMA integrity_check` and `foreign_key_check`
- every table in `database/schema.sql` exists
- the synced tables carry `ost` and `server_time`; local bookkeeping tables
  (`sync_cursors`, `sync_jobs`) are intentionally not in that list
- `EXPLAIN QUERY PLAN` for the hot readers in `qa/db.checks.json`; a query whose
  `expect` is `index` must name an index. The duties query is recorded but not
  demanded to use one today (its leading column is long text).

### l3 — the UI (experimental)

Chromium over CDP visits the manager, help, chat, people, clock, warehouse,
configure and store, collecting console errors, failed requests, 4xx assets,
unlabelled controls and horizontal overflow; screenshots land in
`results/ui/shots` (WebP). WebKitGTK 4.1 - the desktop app's engine - loads the
manager under Xvfb and runs the same probe.

Status: Chromium captures all eight pages; `/manager/store` exceeds the CDP
navigate timeout and is reported as "not captured". WebKitGTK currently times
out here and is recorded as **not run**, never as a pass. First-run warnings:
`ReferenceError: $ is not defined` on fragment pages (a direct load has no
manager shell, so its jQuery is absent), 2-12 unlabelled controls per page, and
the slow store page.

## CPU and memory

`qa/lib/Monitor.pm` forks a sampler that writes one JSON line per second:
per-process CPU and RSS, the **summed PSS** (RSS double-counts every page two
perl workers share, which makes a prefork tree look like several GB), process
count, host `MemAvailable`, load and PSI memory pressure, database and WAL
sizes. `report.md` shows peaks and total CPU seconds; `monitor.jsonl` is the
raw series.

## Android and QEMU

Both are rebuilt from the **newest source every run**, on purpose, so a dev
build cannot pass as a release:

- `qa/android/build.sh` runs gradle `assembleDebug` against
  `~/jawnos-app/termux-app` and copies the APK into the run. It does **not**
  bump `versionCode` and does **not** stage into `releases/` (that is
  `scripts/app_build.pl`'s job for a real release).
- `qa/android/run.sh` copies the AVD, boots it headless, installs that APK,
  drives the WebView over CDP, and records `am start -W`, `gfxinfo` jank,
  `dumpsys meminfo` PSS, and battery. It talks only to the QA instance
  (`adb reverse`), never to a real tablet.
- `qa/qemu/build.sh` runs `sudo perl scripts/mkosi_build.pl`, so the image is
  the current tree.
- `qa/qemu/run.sh` boots it with `-snapshot` and `-display none`, waits for
  `manager/health` over a forwarded port, measures host and guest, then powers
  off through QMP.

Neither device layer runs unless `--layers l4` or `l5` is asked for, and both
are expected on `table` where the SDK, AVD and KVM live.

## Validated so far (2026-11-01)

| where | what | result |
| --- | --- | --- |
| table | `l1` full (signed + anonymous) | PASS, 201 requests, p50 14 ms, p95 89 ms |
| table | `l2` | PASS, 10 checks |
| table | QEMU image boot | health after 303 s (HTTP 403, gated), host RSS 2.1 GB, live tree stayed 200 |
| laptop | `l0` + `l1` full | PASS |
| laptop | `l2` | PASS, 10 checks |
| laptop | `l3` | 9 UI checks, 0 failures; WebKit **not run** (timeout) |
| laptop | `qa/android/build.sh` | PASS, `jawnos-qa-3207084f.apk` from the app repo's HEAD |
| table | `l0` | FAILS at `t/44-native-bins.t` (pre-existing: the native-bin converter/compile toolchain is not installed there) |
| table | Android run | has the `jawnos` AVD and JDK 17, but no app repo; copy the APK from the build machine or set `JAWNOS_APP_DIR` |
| laptop | QEMU image build | `mkosi` is installed; the build is `qa/qemu/build.sh` and was not run in this pass |

The phone/tablet build needs JDK 17-21: AGP 8.7/Gradle 8.9 fail in
`JdkImageTransform` on Java 26, which is the only JDK on the laptop until
`jdk17-openjdk` was installed for this run. `qa/android/build.sh` prefers it.

## Known findings from the first runs (2026-11-01)

- `POST /manager/clothesline` and `POST /manager/mail/email/server/delete` are
  each registered twice (`manager_misc12:41744`/`:41867`,
  `manager_mail:31319`/`:31328`); first-match-wins means the later handler can
  never run. Pinned as a `TODO` in `t/58-route-contract.t`.
- `Root_misc:47831` registers `manager/ws/remote_control` without a leading
  slash. Same TODO.
- `/manager/store` exceeds a 40 s client timeout on a fresh house with no
  network. Warned, not failed, until the UI layer measures it with a real
  session.

- **Live-tree wedge during this work (2026-11-01, 15:29-15:43).** A
  `restart.pl` request left the live master in `wait_woken` while its workers
  blocked in `file_tty_write`: the tree's output filled the PTY faster than the
  master drained it, the master then blocked writing to the same PTY, and the
  accept queue grew to 925. The database was intact (`PRAGMA quick_check` ok).
  Recovery was `kill -TERM <master>`, `perl scripts/manager_killer.pl`, then a
  fresh `./jawn`; health returned in ~20 s. The restart path's synchrony with
  the PTY is a real follow-up, not a QA-suite issue - the QA instance never
  shares the master's PTY or its PID namespace.
