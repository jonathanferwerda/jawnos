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
perl qa/run.pl --layers l4         # Android emulator (table: SDK + AVD)
perl qa/run.pl --layers l5         # QEMU image boot (table: KVM + qemu)
perl qa/run.pl --layers l5 --device-contract   # + install, boot the disk twice
perl qa/run.pl --layers l6         # nightly UX loop (fenced; needs notes)
perl qa/ux/run --limit 5           # the UX loop on its own, with its own timer
perl qa/run.pl --layers l4 --apk releases/jawnos-app-1256-0.118.257.apk
perl qa/run.pl --source worktree   # test uncommitted code
perl qa/run.pl --no-namespace      # read the warning first
perl qa/run.pl --layers l0         # just the old regression suite
perl qa/budget.pl <metrics.json>   # judge one device file on its own
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
namespaces were real, and whether the live repo was mounted read-only. It closes
with the budget table: every number the layers measured against the limit it must
stay under.

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

**One deliberate hole, for l4 only.** The Android layer needs the emulator's
WebView to reach a real QA instance, and a socket in the fence's net namespace
is unreachable from `adb reverse`. Since unix sockets are files, a relay socket
in the run root (never `/tmp`, which the mount namespace makes private) is
visible from both sides: `qa/lib/Relay.pm` listens on it inside the instance's
namespace and forwards to `https://127.0.0.1:<port>`, and `qa/android/run.sh`
listens on `127.0.0.1:<port>` on the host and forwards into the socket. The
port is the same number on both sides because the instance's port is free on
the host. Its risk: for the life of the layer any **local** process on the host
can dial that loopback port (nothing is opened on 0.0.0.0 and no route to the
LAN is added), and it reaches only the QA copy - the hop still meets the QA
house's ticket/session gate. `Harness` takes `relay => 1` to start the inside
half; the default is off, so l1-l3 and the nightly are unchanged.

The live files are snapshotted (inode/size/mtime) before and after for the
report. They may legitimately move because the live app is running; that is
recorded as drift, not as a verdict. The verdict is the PID audit.

## Layers

| Layer | What | Status |
| --- | --- | --- |
| `l0` | `prove -l t` (runs outside the fence; it is hermetic) | done |
| `l1` | every classified GET route over HTTP, signed-in and anonymous; timings; crash detection + restart; fence audit | done |
| `l2` | database contracts: integrity, stamps, real query plans | done |
| `l3` | Chromium CDP smoke + WebKitGTK engine probe | done on table |
| `l4` | Android emulator: cold/warm start, rotation, offline, repeat jank, WebView CDP, crash/ANR | done on table |
| `l5` | QEMU image: version fidelity, boot evidence, install + reboot persistence, host/guest measures | done on table |
| `l6` | UX loop: the owner's JawnOS notes attempted in a fenced copy, judged easy/help/works | harness + rubric + skip when unmodelled |

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

The report also carries a **PSS slope** (least squares over the whole series,
MB per hour). A soak's question is not "how high did it get" but "is it still
going up"; a flat run reports ~0 instead of a false spike.

## Budgets

`qa/budgets.json` holds the limits; `qa/lib/Budget.pm` compares each measured
value with its limit and `qa/run.pl` applies it before it computes PASS/FAIL.
A measurement nobody compares against anything is a chart, not a test.

| metric | limit | level | baseline (table, 2026-11-01) |
| --- | --- | --- | --- |
| `l1.p50_ms` / `l1.p95_ms` | 60 / 250 ms | warn | 13-14 / ~90 ms |
| `l1.max_ms` | 6000 ms | warn | one known slow page |
| `monitor.pss_peak_mb` | 1200 MB | **fail** | ~1 GB nightly peak |
| `monitor.cpu_peak_cores` | 6 | warn | 8 cores on table |
| `monitor.cpu_seconds` | 900 | warn | ~120 s for l1 |
| `monitor.rss_slope_mb_per_h` | 48 | **fail** | soak: must not climb |
| `l2.db_failures` | 0 | **fail** | 10 checks pass |
| `l3.ui_failures` | 0 | **fail** | 0 |
| `l3.pages_captured` | 8 (minimum) | warn | 7-8 |
| `l4.cold_start_s` | 10 s | warn | 6.2-8.1 s |
| `l4.pss_mb` | 300 MB | warn | 96-113 MB |
| `l5.health_s` | 420 s | warn | 285 s (firstboot seed) |
| `l5.host_rss_mb` | 3400 MB | **fail** | 3093 MB at 3072 MB guest RAM |

Rules that keep the file honest:

- A bare number defaults to **warn**; a limit that fails a run must say
  `"level": "fail"` on purpose.
- A metric that was not measured is `skip`, never `pass`.
- A **minimum** (pages captured) is written as `"min": true`; the checker then
  fails when the value is *below* the limit. Direction belongs to the budget.
- A budget entry naming a metric `Budget.pm` cannot read is a typo;
  `t/67-qa-budgets.t` fails on it.
- `l4.jank_pct` is deliberately **not** gated: the emulator is software-rendered
  and reports 95-100 % janky frames on every run, so a threshold there would warn
  forever. It is still measured (`results/device.json`) and shown when it moves.
- The VM's host RSS is guest RAM + ~20 MB. `qa/qemu/run.sh` therefore defaults to
  `QA_VM_RAM=3072`, `QA_VM_CPUS=2`, which fits table next to the live tree.
- An image older than the tree cannot prove the tree. `l5` records
  `l5.version_match`; the runner warns when the artefact and the checkout
  disagree (it does today: image 0.1.1739, tree 0.1.1757+).

A device script is also usable alone; both write the same flat shape:

```sh
sh qa/android/run.sh /path/to/app.apk      # QA_RESULTS/device.json
sh qa/qemu/run.sh [--version-check|--contract] [image.raw]
perl qa/budget.pl results/device.json
```

## Android and QEMU

Both are rebuilt from the **newest source every run**, on purpose, so a dev
build cannot pass as a release:

- `qa/android/build.sh` runs gradle `assembleDebug` against
  `~/jawnos-app/termux-app` and copies the APK into the run. It does **not**
  bump `versionCode` and does **not** stage into `releases/` (that is
  `scripts/app_build.pl`'s job for a real release).
- `qa/android/run.sh` copies the AVD, boots it headless, installs the APK with
  `-s "$SERIAL"` (a real tablet on the bus must never receive it), and drives
  the real flows: cold start, warm start, rotation, airplane-mode relaunch and a
  three-launch jank series. It scans `logcat` for `FATAL EXCEPTION`/ANR **for the
  package only** and fails the layer on one. It then attaches to the app's
  WebView over `webview_devtools_remote_<pid>` (`qa/android/webview_probe.js`)
  and records console errors and DOM nodes; with no manager reachable the page
  stays on `android_asset/splash.html` and the result is an explicit **skip**,
  never a pass. It writes `results/device.json` and runs `qa/budget.pl` on it.
  It talks only to the QA instance (`adb reverse`), never to a real tablet.
  With `QA_INSTANCE=1` it boots a fenced instance itself (`qa/android/instance.pl`),
  bridges it through the run-root relay, mints the app ticket
  (`scripts/app_ticket.pl`) and opens it with the `com.jawnos.app.EXTRA_URL`
  extra. The factory seed does not create the vault, so the helper first runs
  one real login (`qa/android/vault_seed.pl`); without that the ticket renders
  the Gate. The app already proceeds on a self-signed certificate for
  `127.0.0.1`, so no CA is installed. When a ticket was minted and the
  WebView still lands on the splash, the layer **fails** with the probe JSON as
  evidence, rather than reporting a pass.
- `qa/qemu/run.sh` (POSIX sh) boots headlessly with `-snapshot=on` and
  `-display none`, drives the serial console through `qa/qemu/serial.pl`, and
  has three modes:
  - `--version-check` mounts the image read-only with `qemu-nbd` and compares its
    `VERSION` with the checkout's; nothing is booted.
  - default: boot, wait for `manager/health` on the forwarded port, record boot
    markers from the serial transcript and the VM process's `VmHWM`.
  - `--contract`: additionally installs to a throwaway 16 G qcow2 target, boots
    the installed disk, reboots it, and proves persistence with the QA-PERSIST
    marker. The live image is never written.
  Output: `version.txt`, `phase-*.txt`, `serial-*.log/.status`, `qemu.txt` and
  `results/device.json`.
- The shipped image boots `quiet splash loglevel=3 plymouth.ignore-serial-consoles`,
  so **no manager/health or session line ever reaches the serial console**. The
  harness reads the manager line from `/home/jawn/manager.log` instead. Any
  expectation of a serial "health" marker is wrong for 0.1.1739 and earlier.

Neither device layer runs unless `--layers l4` or `l5` is asked for, and both
are expected on `table` where the SDK, AVD and KVM live. Table's Java is
JRE-only (`jre17-openjdk-headless`, no `jlink`/`javac`), so a gradle build there
fails in `JdkImageTransform`; `qa/android/build.sh` must run on a machine with a
full JDK, or the layer takes `--apk` / the newest staged APK from `releases/`.

## Validated so far (2026-11-01)

| where | what | result |
| --- | --- | --- |
| table | `l1` full (signed + anonymous) | PASS, 201 requests, p50 14 ms, p95 117 ms; budgets 0 fail, 1 warn (`max_ms` = the store page) |
| table | `l2` | PASS, 10 checks |
| table | `l3` | PASS; WebKit `hasMenu: true` (`QAHouse`, 480 nodes); 8 Chromium pages tried, 7 captured — `/manager/store` still exceeds the navigate timeout (the tree survives it now) |
| table | `l4` emulator + app flows | PASS: cold 8.1 s, warm 0.5 s, PSS 96.3 MB, jank 100/100/100 %, rotation + offline ok, 0 crash/ANR; CDP **skip** (no manager reachable) |
| table | `l5` boot | health 285 s (HTTP 403 gated), host peak 3093 MB at 3072 MB guest RAM |
| table | `l5 --contract` | install 41 s; installed boot 24 s, second boot 23 s; **persistence yes** (16 G qcow2) |
| table | `l5` version check | image **0.1.1739**, tree 0.1.1757 → match **no** (table cannot rebuild: no `mkosi`) |
| table | nightly service | PASS, 0 failures, 1 GB peak; timer enabled, next 04:01 |
| laptop | `l0` + `l1` full | PASS |
| laptop | `l2` | PASS, 10 checks |
| laptop | `l3` | 9 UI checks, 0 failures; WebKit **loads the manager** (`QAHouse`, 479 nodes) |
| laptop | `qa/android/build.sh` | PASS, `jawnos-qa-3207084f.apk` from the app repo's HEAD |
| laptop | `qa/qemu/build.sh` | `mkosi` is installed; the image in `desktop/mkosi/output` is the artefact l5 boots |
| table | `l0` | FAILS at `t/44-native-bins.t` (pre-existing: the native-bin converter/compile toolchain is not installed there) |
| table | Android build | FAILS: table's Java is JRE-only (`jre17-openjdk-headless`); no `jlink`, so `JdkImageTransform` fails. Use `--apk` / the staged APK |

The phone/tablet build needs JDK 17-21: AGP 8.7/Gradle 8.9 fail in `JdkImageTransform`
on Java 26, which is the only JDK on the laptop until `jdk17-openjdk` was installed
for this run. `qa/android/build.sh` prefers it.
The phone/tablet build needs JDK 17-21: AGP 8.7/Gradle 8.9 fail in
`JdkImageTransform` on Java 26, which is the only JDK on the laptop until
`jdk17-openjdk` was installed for this run. `qa/android/build.sh` prefers it.

## l6 — UX (nightly, separate from the 05:00 job)

`qa/ux/run` reads the owner's **JawnOS**-category notes, newest first
(`--limit N`, default: the Notes per night setting, 3), opens the live database with
`sqlite3 'file:<live>/database/jawnos.db?mode=ro'`, and seeds those notes into
a `Harness` copy. Every attempted task runs against that copy. The live notes
are never written and the query never holds a lock.

For each note it makes a browser attempt over CDP (`qa/ux/attempt.js`): open
Notes, look for the note, click the JawnOS chip, screenshot, and collect
console errors and the step trail. The **rubric** answers three questions:

- **easy** — was the described task easy to do?
- **help** — was the in-app help useful for it?
- **works** — do the parts actually work (no console error, no dead step)?

**No model is `skip`, never `pass`.** With `--model NAME` the runner asks the
Guide's own model call (`subs::evaluation_model_call`) for the three verdicts;
a call that errors, or with no model configured, leaves the note at `skip`.

Output (under `--results`, normally `~/jawnos-qa/ux/`):

```
ux-report.md        the human nightly report
report.json         the same, with per-note evidence and screenshots
queue.json          note id, title, verdict, suggested next action
notes/<id>/         attempt.json + shots/*.webp per note
metrics.json        l6.ux_failures, l6.notes, l6.duration_s
```

`queue.json` is the Coding agent handoff. It is a queue, not an instruction to
autonomously edit code: the Coding agent (`public/js/manager/coding.js`, the
Configure → Plat → Self-healing watch) reads the same errors from
`~/pty.log`, `manager.log` and browser fatals. Point it at `queue.json` when
the owner wants a suggested fix turned into a patch; this loop never edits
application code.

**The one live write.** With `--file-handbook`, `qa/ux/run` posts the summary
through the app's own `POST /manager/note_save` route (category `jawnos`, or
`journal` when there was nothing to evaluate). It does not write SQL. The
post happens in the parent process, after the fenced child has exited, because
the fence deliberately removes the live network.

### Schedule it

```sh
sudo cp qa/systemd/jawnos-qa-ux.service qa/systemd/jawnos-qa-ux.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now jawnos-qa-ux.timer
systemctl list-timers jawnos-qa-ux.timer
```

It runs at 05:30 with a 15-minute random delay, not in the 05:00 l0-l2 job, so
a 20-minute UX run cannot hold the route/database layers. The service has the
same second fence (`ProtectHome=read-only`, only `~/jawnos-qa` writable,
loopback-only) and calls the runner with `--results ~/jawnos-qa/ux`. A missing
`~/jawnos/.shots/ticket.txt` leaves the report on disk and only logs that the
handbook filing was skipped.

## Coding nightly (06:00)

`qa/coding_night/run.pl` is the one QA job that writes the house. It runs at
06:00 on the machine chosen in Configure -> Plat -> QA (the service carries the
same `qa/device_target.pl` ExecCondition, and the runner re-checks it, so a
manual run on another machine is a skip).

**Notes per night.** Configure -> Plat -> QA has a second picker, 1..25,
persisted as the house setting `__president/qa_note_limit` (device `all`,
default 3). Both nightlies read it: `qa/coding_night/run.pl` takes that many
notes and `qa/ux/run` uses it as its `--limit` default. `--limit N` overrides
it on either command; both clamp to 1..25, and the panel's server-side save
clamps again, so a hand-made POST cannot ask for a thousand notes.

The runner, one note at a time:

1. **Gate** - exit 0 unless this machine is the chosen one.
2. **Read** - the top *open* JawnOS notes (`category = 'jawnos'`, not
   `completed`, not tombstoned), newest first, from
   `sqlite3 'file:<db>?mode=ro'`. It never writes the live database.
3. **Fetch + worktree** - `git fetch origin`, then
   `git worktree add ~/jawnos-qa/work/<stamp>-<n> -b qa/nightly-<stamp>-<n>
   origin/main`.
4. **Agent** - the hook below, with cwd = that worktree.
5. **Suite** - `qa/run.pl --source worktree --root ~/jawnos-qa/nightly
   --layers l0,l1`, plus `l2,l3` when the changed file list touches
   `templates/`, `public/js/`, `lib/JawnOS/Controller|Routes` or `perl/*.pl`.
6. **Green** - `scripts/version_bump.pl`, one commit
   `v<version> - <note title>`, push the branch, `git merge --ff-only` into
   main, push main, `scripts/restart.pl --reason ...`, require HTTP 200 from
   `/manager/health`, then mark the note `completed` through
   `POST /manager/note_save` (ticket-minted session) and file a Handbook
   report note in the `journal` category. The worktree is removed afterwards.

**Red is a stop.** The worktree stays for inspection, its branch is detached
and deleted, the note stays open, and `~/jawnos-qa/coding/<stamp>/report.md`
names the layer and log. A dirty main tree is also a stop: it refuses to merge
over other work. A non-zero agent exit is handled the same way.

**Two lanes.** A note that names the Android app's vocabulary - `android`,
`apk`, `app`, `termux`, `status bar`, `navigation bar`, `soft keyboard`, `ime`,
`webview`, `wakelock`, `vibrate` - or that carries an explicit `[app]` marker
(or an `app`/`android` tag) is built in the app checkout, not here. That checkout
is `$JAWNOS_APP_DIR`, default `~/jawnos-app/termux-app`, on branch `jawnos`; the
worktree is `~/jawnos-qa/work-app/<stamp>-<n>` and the branch is still
`qa/nightly-<stamp>-<n>`. The agent's context is that checkout's `AGENTS.md` and
`JAWNOS.md`, never this repository's. The gate is
`JAVA_HOME=/usr/lib/jvm/java-17-openjdk ./gradlew --max-workers=4
:app:assembleDebug`. Only after a green build are `versionCode` and the
`versionName` patch bumped, the APK rebuilt, `v<versionName> - <title>`
committed, the branch pushed, `jawnos` fast-forwarded and `fork` pushed. Then
`scripts/app_release.pl <apk>` stages it and `scripts/app_publish.pl` publishes
it; with no authenticated `gh` the stage is kept and the report says
`publish: skipped (no gh auth)`. A failed build bumps, pushes and stages
nothing and leaves the note open. The app checkout is only fast-forwarded when
it is clean and already on `jawnos`: another agent's WIP is never committed,
merged or reset around, and the report says `jawnos was not fast-forwarded`.
There is no manager restart or health gate in this lane - the APK is not this
process.

**No agent is exit 3.** It prints `no coding agent configured`, fetches
nothing, creates no worktree or branch, and leaves every note open. With
`qa/coding_night/agent.pl` wired to the hook, the same exit 3 means no Coding
model is set (Configure -> Platform -> Coding); it changes nothing. The stub
still exists so the pipeline itself can be exercised.

### The agent hook

`JAWNOS_CODING_AGENT` (environment, wins) or `__president/qa_coding_agent`
(a house setting) holds a **command line**. It is split the way a shell splits
it and exec'd with no shell, so it can be a path or `program --flag value`.
The runner sets, for each note:

| variable | value |
| --- | --- |
| `JAWNOS_NOTE_ID` | the note's uuid |
| `JAWNOS_NOTE_TITLE` | its first line, whitespace-collapsed, 90 chars |
| `JAWNOS_NOTE_TEXT` | the whole note text |

and runs it with cwd = the fresh worktree. Exit 0 means "I changed the tree";
any other code is a failed note. `qa/coding_night/agent_stub.pl` always exits
3, so the pipeline (fetch, worktree, red/cleanup path, report) can be tested
end to end without a model:

```sh
JAWNOS_CODING_AGENT="/usr/bin/perl /home/jawn/jawnos/qa/coding_night/agent_stub.pl" \
  perl qa/coding_night/run.pl --dry-run
```

`--dry-run` prints the queue, the note limit, the agent and each planned
worktree/branch, and writes nothing (no lock file, fetch, worktree or report).
One run at a time is held by `flock` on `~/jawnos-qa/.coding-night.lock`.

### The 06:00 agent

`qa/coding_night/agent.pl` is the command to point the hook at once a Coding
model is configured. It runs in the worktree and:

1. **Assembles the context from the main checkout** (`$HOME/jawnos` or
   `--context-dir`): `AGENTS.md`, `docs/AGENTS-notes.md`, this README, and the
   help topic for the app the note names. In the app lane the context is the
   app checkout's `AGENTS.md`, `JAWNOS.md` and `README.md` instead. Each is
   capped at 20 KB and the prompt says when it was truncated.
2. **Redacts before sending.** A line that mentions `.secrets/`, `.shots/`,
   `config.json`, `downloads.json`, a `*.pem`, or one of the secret words
   (password, passphrase, token, api key, secret, credential, signatorial, a
   ticket uuid) is replaced whole; a PEM block is withheld with its body.
   Absolute `/home/<user>/jawnos` paths become repository-relative. The note
   itself is redacted only for pasted values, so "fix the password field" still
   works.
3. **Calls the configured model exactly as the Coding app does**:
   `mail/coding_assistant` (fallback `coding_assistant_fallback`, thinking from
   `ai_role_thinking('coding_assistant')`) through
   `subs::ai_chat_parts_with_fallback` - the same helper behind
   `POST /manager/coding/heal`. No second provider configuration exists here.
4. **Applies only whole-file writes or unified diffs inside the worktree.**
   A reply may be a bare JSON object, a JSON object in ```` ```json ```` fences,
   a bare unified diff, or a patch in ```` ```diff ````/```` ```patch ```` fences;
   prose around either is ignored. A reply that is neither is written verbatim
   to the agent log (`----- BEGIN RAW REPLY -----`) before it is rejected, so a
   refused turn can be diagnosed from the log alone. Absolute paths, `..`,
   symlinks and anything that resolves outside are
   refused; `.git`, `.secrets`, `.shots`, `.president`, `releases`,
   `signatorials`, `database/*.db`, `config.json`, `downloads.json` and `*.pem`
   are never written. Binary files are refused, and the whole run may write at
   most 256 KB. A refused turn writes nothing.
5. **Checks each turn**: `perl -c` for Perl and `node --check` for JavaScript;
   a failure is fed back to the model. It stops when the model says done and
   the checks pass, or after `--max-turns` (default 6).

It never bumps, commits, pushes or restarts - the runner does that after the
suite is green. Exit 0 means the worktree changed and its checks passed; 1 means
the note could not be attempted; 2 is a usage or environment failure; 3 is no
model. `--dry-run` prints the prompt, the documents and the call plan and writes
nothing. `--responder FILE` replaces the model with a fixture (tests only).

```sh
# point the nightly at the agent, then see the plan without touching anything
JAWNOS_CODING_AGENT="/usr/bin/perl /home/jawn/jawnos/qa/coding_night/agent.pl" \
  perl qa/coding_night/run.pl --dry-run

# or assemble the prompt for a note by hand (cwd should be a worktree)
JAWNOS_NOTE_ID=demo JAWNOS_NOTE_TITLE="a note" JAWNOS_NOTE_TEXT="the task" \
  perl qa/coding_night/agent.pl --dry-run
```

### Schedule it

```sh
sudo cp qa/systemd/jawnos-qa-coding.service qa/systemd/jawnos-qa-coding.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now jawnos-qa-coding.timer
systemctl list-timers jawnos-qa-coding.timer
```

The service is the one nightly **without** `ProtectHome=read-only`: the agent
edits a worktree, a green night bumps/commits/merges/pushes main, and the
restart is the master's own path. It still has `Nice`, `MemoryMax=4G`,
`CPUQuota=300%`, `ProtectSystem=strict`, and only the checkout and the QA root
in `ReadWritePaths`. It needs real networking (git, the agent's model, the live
health route). It never runs `scripts/manager_killer.pl` and never asks a QA
tree for a graceful shutdown: a bound process is SIGKILLed.

## Nightly

`qa/systemd/` holds a hardened system unit and a timer:

```sh
sudo cp qa/systemd/jawnos-qa.service qa/systemd/jawnos-qa.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now jawnos-qa.timer
systemctl list-timers jawnos-qa.timer
```

It runs `l0,l1,l2` at 05:00 with a five-minute random delay, as `jawn`, with the
repo read-only (`ProtectHome=read-only`, `ProtectSystem=strict`), only
`~/jawnos-qa` writable, loopback-only networking, `MemoryMax=4G` and
`CPUQuota=300%` (3 cores; 200% made `nproc` report 2 and `t/43`'s `--jobs=3`
legitimately clamp). `qa/prune.pl --keep 14` runs first. UI (`l3`) is
deliberately not in the nightly set while the JavaScript refactor is in flight.
The UX loop (`l6`) has its own timer at 05:30 - do not add it to this unit, or a
20-minute UX run can hold the route/database layers.

### Which machine runs the night

Configure -> Plat -> QA names one machine for the nightly, and the choice is the
house setting `__president/qa_nightly_device` (device `all`). It holds the
signatorial of a **computer** or **server**; a phone or tablet is never offered,
and the save and install actions refuse one. An empty value is the local
fallback: every machine runs its own suite, as it always did.

Both timers honour the choice through `qa/device_target.pl`:

```
ExecCondition=/usr/bin/perl /home/jawn/jawnos/qa/device_target.pl
```

The helper reads the setting from `database/jawnos.db` with `sqlite3`, compares
it with this machine's identity (`~/.jawnos_signatorial_id`, or the copy beside
the database), and exits 0 when this machine is the chosen one. It exits 1 for
every other machine, and systemd skips the unit without marking it failed. It
also exits 0 when no choice is saved, the row is missing, or no identity file
can be read - the local fallback is always the safe answer. Install the units on
every machine that might be chosen; the unchosen ones still have the timer, they
just skip their run.

There are three nightly units, and the Configure choice applies to all three: the
suite at **05:00**, the UX loop at **05:30**, and the coding night at **06:00**. The weekly artefact build
(`jawnos-qa-build.timer`, Sunday 03:00) deliberately does **not** carry the
condition: it belongs where the toolchain is (mkosi, qemu, a full JDK), not on
the machine that happens to run the route/database suite.

The panel's readiness card asks the chosen machine what it has: the checkout,
`perl` and `prove`, `sqlite3`, `unshare` (the fence) are required for the
nightly; `mkosi`, `qemu-system-x86_64`, `java`/`javac`/`jlink`, `adb` and an
Android AVD are the artefact and device layers. Install runs on the target over
the app's existing signed remote-command rail (`POST /manager/remote_command`,
peer-verified at the far end); it installs only what is missing, and a dry run
(used by the tests) returns the plan without running anything.

## Known findings from the first runs (2026-11-01/02)

- **Live-tree wedge on table (recovered).** The live master sat in `wait_woken`
  while every worker blocked in `file_tty_write`, with the accept queue growing
  and no `manager.log` line for over an hour; the master watchdog had already
  restarted once at 18:37 for the same reason. This is the PTY deadlock, not a
  QA-suite failure (the QA instance never shares the master's PTY). Recovery:
  `kill -TERM <master>` → `perl scripts/manager_killer.pl` → relaunch `./jawn`;
  health returned and the database was intact. The wedge's trigger is still open.
- **The QEMU image is old.** The table artefact is 0.1.1739 while the checkout is
  0.1.1757+, and table has no `mkosi`, so l5 currently proves an old artefact.
  `l5.version_match=no` is reported and warned; rebuilding must happen on a
  machine with `mkosi` and the image shipped over.
- **Table cannot build the app either**: `jre17-openjdk-headless` has no `jlink`
  or `javac`, so gradle fails in `JdkImageTransform`. Install a full JDK there or
  keep building the APK on the laptop and passing `--apk`.
- **The WebView never reaches the manager in l4** because no QA instance/ticket
  exists on table for the app to load; it stays on `android_asset/splash.html`.
  The layer records that as a skip. Giving the app a real page needs a QA
  instance reachable over `adb reverse`, which the netns in the fence deliberately
  prevents; that is a design decision for the next pass, not a bug.
- **The serial console of the shipped image shows no manager line**
  (`quiet splash loglevel=3 plymouth.ignore-serial-consoles`). Boot markers must
  accept agetty/motd lines, and the manager's own line is read from
  `/home/jawn/manager.log`.
- **`dumpsys gfxinfo reset` is issued while the app is force-stopped**, so the
  readback cannot confirm zero and the three jank figures may be cumulative;
  they are recorded separately and flagged.
- `POST /manager/clothesline` and `POST /manager/mail/email/server/delete` are
  each registered twice (`manager_misc12:41744`/`:41867`,
  `manager_mail:31319`/`:31328`); first-match-wins means the later handler can
  never run. Pinned as a `TODO` in `t/58-route-contract.t`.
- `Root_misc:47831` registers `manager/ws/remote_control` without a leading
  slash. Same TODO.
- **Nightly on table (2026-11-01):** `jawnos-qa.timer` is enabled and the
  service now passes (0 failures, 1 GB peak, live tree 200). The first two runs
  failed only on environment/WIP: `Archive::Zip` was missing, and `t/55`
  expected the `runtime_build.pl` `video`-part change before it was committed
  (it landed as v0.1.1756). The same test used to call `skip()` outside a `SKIP`
  block, which aborted the whole file on a machine with no
  `releases/jawnrt.json`; that skip is fixed.
- The runner exited **255** on a passing run: the END cleanup re-`waitpid`ed
  children the normal path had already reaped, which sets `$?` to -1. Teardown
  is now idempotent and a PASS exits 0.
- `/manager/store` can take the whole tree down when a **browser** loads it:
  the worker logs `A response has already been rendered`
  (`Mojolicious/Controller.pm:189`) after `store.html.ep:39` warns about an
  uninitialised value, and the tree exits. `l1` sees it as a slow (40 s) route;
  `l3` reaches it with Chromium and names it as the route that killed the
  instance. This is in the area of the in-flight JavaScript/template refactor
  and was not fixed here.
- The Android runner had four defects, fixed after the first run: `dumpsys
  meminfo` stopped before `TOTAL PSS`, `top` was CPU-sorted so the idle app was
  absent, `adb install` omitted `-s "$SERIAL"` (a real tablet on the bus could
  have received the QA APK), and `adb wait-for-device` had no timeout.

- **Live-tree wedge during this work (2026-11-01, 15:29-15:43).** A
  `restart.pl` request left the live master in `wait_woken` while its workers
  blocked in `file_tty_write`: the tree's output filled the PTY faster than the
  master drained it, the master then blocked writing to the same PTY, and the
  accept queue grew to 925. The database was intact (`PRAGMA quick_check` ok).
  Recovery was `kill -TERM <master>`, `perl scripts/manager_killer.pl`, then a
  fresh `./jawn`; health returned in ~20 s. The restart path's synchrony with
  the PTY is a real follow-up, not a QA-suite issue - the QA instance never
  shares the master's PTY or its PID namespace.
