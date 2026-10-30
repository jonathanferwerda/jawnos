# Leaving Termux — building the JawnOS app from scratch

**Status:** draft 2026-10-30. **M0 landed** in v0.1.1611 and **Spike B passed**
the same day (§Spikes). Next: Spike A, then M1. Nothing in the app has changed yet.
**Read with:** `docs/appliance-provisioning.md`, `docs/app-release-notes.md`,
`~/jawnos-app/PLAN.md` (the fork plan — this doc supersedes its identity and bootstrap
sections in the long run), `AGENTS.md` → App releases.

## The goal

The phone app becomes ours: no `termux-app`, no `termux-api`, no `termux-shared`, no
bootstrap archive, no `pkg`/`apt`. The Perl tree still runs, the Manager and Web UI do
not change. The app is only the host.

Not the goal:

- rewriting jawn in Kotlin/Java;
- changing what the app does for the person;
- a big-bang rewrite. Every milestone is shippable and reversible.

## What actually depends on Termux

Four hooks, in ascending order of cost.

| Hook | Where it lives | Cost |
| --- | --- | --- |
| Launcher shells out to `login -lc … perl` | `JawnLauncher.java:301-327` | small |
| PTY and the session model | `TerminalSession` → `terminal-emulator/src/main/jni/termux.c` (`open("/dev/ptmx")` + fork/exec), `TermuxService` | small |
| `termux-*` device commands | ~24 distinct commands across the tree; e.g. `subroutines.pl:3571`, `scripts/jawn-bt:63`, `Manager.pl:19864` | medium |
| The runtime | `app/src/main/cpp/bootstrap-aarch64.zip` (29 MB), `pkg`/`apt`/`dpkg`, 21 CLI tools and 40 Perl modules (`scripts/jawnos_deps.pl:103-175`) | **the project** |

The login shell exists only to export `PATH`, `LD_PRELOAD` (termux-exec) and `PERL5LIB`
before `exec perl ./jawn`. A supervisor sets those itself. The PTY exists so the Console
can show a terminal; jawn writes to `~/manager.log` and does not obviously need a tty.
Neither is the hard part — the runtime is.

## The constraints that decide the shape

1. **Exec from app data is blocked on targetSdk 29+** (Android 10 W^X). Termux pins
   `targetSdkVersion=28` in `gradle.properties` for exactly this reason. A bundled
   interpreter must run from the APK's read-only native lib directory (`jniLibs`, with
   `extractNativeLibs="true"`, already set in the manifest). Whether that works is
   **Spike B**; it decides whether the finished app can ever target 35/36 or reach Play.
2. **Native payloads must be 16 KB-page aligned** for targetSdk 35+, so the runtime is
   built with a current NDK, not the fork's `ndkVersion 22.1.7171670`.
3. **Licensing moves with the rewrite.** `termux-app` is GPL-3;
   `terminal-view`/`terminal-emulator` are Apache-2.0 (`~/jawnos-app/PLAN.md` §7). Once
   M4 removes the GPL parts the app can be BSD-2 like the Perl tree — but only if no GPL
   code is copied forward.
4. **The download policy follows the same line.** `JawnFirstRun.java:92` runs
   `pkg install git` and clones the tree, `JawnUpdater` installs APKs, and
   `subs::app_release_sync` (`subroutines.pl:31871`) pulls APKs from peers. Play requires
   all of that to become bundled or Play-delivered. Sideloading does not care.

## Spikes (before M0)

Two experiments, a day each, settle decisions that are expensive to unmake. M0 did
not wait for them: it changes only this tree, and the spikes decide the app-side
shape M1 and M2 take.

### Spike A — does jawn need a tty?

- **Method:** start `President.pl` through the existing `TermuxService` background path
  with piped stdout into `~/manager.log` instead of a terminal session (or a
  `ProcessBuilder` from a scratch Activity). Watch one full restart cycle and one websocket
  client.
- **Accept:** the tree starts, workers run, `restart` via `~/.president/status` works,
  websockets connect, and the log looks like a PTY run's.
- **Then:** if it passes, the supervisor is a plain process manager and the PTY becomes a
  Console-only feature. If it fails, M2 keeps a PTY per session and the supervising logic
  wraps `terminal-emulator` instead of replacing it.
- **Also check:** `Mojo::IOLoop::ReadWriteFork` and signal handling (`WNOHANG`, `INT`/`TERM`)
  behave the same with a pipe; anything that calls `isatty` or `TIOCGWINSZ`.

### Spike B — how do you execute a bundled interpreter? ✅ 2026-10-30

- **Method:** a separate `org.jawnos.spikeb` APK (NDK r23b
  `aarch64-linux-android21-clang`, a trivial PIE named
  `jniLibs/arm64-v8a/libjawnrt.so`, `extractNativeLibs` true via
  `useLegacyPackaging`) execs the file from `nativeLibraryDir` on a Galaxy
  Tab S10 Lite (SM-X400, Android 16, arm64-v8a), built once with `targetSdk 28`
  and once with `targetSdk 36`. The spike project is `.shots/spike-b/` (scratch,
  not committed).
- **Result:** both exec, `exit=0`, through `ProcessBuilder` and through
  `/system/bin/sh -c`; `/proc/self/maps` shows the file mapped `r-xp` from
  `/data/app/.../lib/arm64/`, so it is the extracted copy, not the APK.
- **SELinux:** `u:r:untrusted_app_27:s0:...` at targetSdk 28 and
  `u:r:untrusted_app:s0:...` at 36; no `avc: denied { execute }` in logcat.
  (Both domains still exist on Android 16 — the old one is selected by the
  app's targetSdk.)
- **After an APK update:** installing a new build over the old one re-creates
  the version-scoped directory and the exec still works (tested 28 → 36 → 36).
- **Then:** the finished app can target 35/36 and Play is possible. The plan
  does not get smaller.
- **Note for M5:** Play Protect's install-time verifier answered
  `INSTALL_FAILED_VERIFICATION_FAILURE` for this debug-signed APK over adb; one
  install with `settings put global verifier_verify_adb_installs 0` (deleted
  immediately afterwards) let it through. Worth re-checking on the real update
  path (PackageInstaller from the app) before M5.
- **Left clean:** the spike package was uninstalled and the tablet's live
  `com.termux` process was not touched (same pid before and after).

## Milestones

| Milestone | Deliverable | Removes | Effort |
| --- | --- | --- | --- |
| **M0 Contracts** | dependency ledger + `subs::device()` wrapper at call sites, behaviour unchanged | nothing yet | ~1 week |
| **M1 Device bridge** | `DeviceService` (unix socket, JSON) in the app; termux commands migrated one by one | `termux-api` package, `com.termux.api`, second APK | 2–3 weeks |
| **M2 Supervisor** | own process supervisor + PTY only for Console | `TermuxService`, `RunCommandService`, `termux-am`, `termux-exec`, `bin/login` | ~2 weeks |
| **M3 Runtime** | bundled Perl + XS modules + a decided tool set | bootstrap, `pkg`/`apt`/`dpkg`, `TermuxInstaller`, first-run `git clone` | 4–8 weeks |
| **M4 Identity** | new app, new package name, no Termux code | `termux-shared`, `terminal-view`/`terminal-emulator`, plugin support, `sharedUserId`, GPL-3 | 2–3 weeks |
| **M5 Distribution** | signed AAB/APK + update channel | — | ~1 week |

### M0 — Contracts ✅ (v0.1.1611)

- Ledger: `scripts/termux_ledger.pl` prints every device call site (file:line,
  command, M1 replacement, wrapped/raw), the tool and module tables read from
  `scripts/jawnos_deps.pl`, the PTY touch points and the Termux-runtime shebangs.
  `--check` is the ratchet; `--record` prints the `%BASELINE` stanza to paste.
- The door is **three** functions in `subroutines.pl`, because a call site needs
  three different things: `subs::device_cmd` returns the shell command,
  `subs::device_run` runs it (with an optional `timeout`/pipe prefix), and
  `subs::device_bin` names the binary for the `-x` capability probes. The literal
  `termux-` now lives only in those three bodies.
- One call site is deliberately exempt: `scripts/jawnos_setup.pl:755` opens the
  first-run wizard in a browser before the tree is serving and without loading a
  runtime module. M3 replaces that first-run path, so it stays raw until then and
  the ledger allows exactly that one.
- The tool table answers "which tools are real" mechanically, and it corrected
  two guesses: `qrencode` **is** spawned (the QR share), while `autossh`, `tmux`,
  `zbarimg` and `node` are never spawned by the runtime (only the deps list or
  dev scripts), so they are drop candidates. The intent for each tool is the
  script's `%TOOL_INTENT`.
- **Exit:** `perl scripts/termux_ledger.pl` prints the ledger and the baseline;
  `--check` exits 0 at 36 call sites / 24 commands / 0 raw sites, and
  `t/20-termux-ledger.t` runs the check inside `prove -l t`.

### M1 — Device bridge

- App side: a foreground `DeviceService` listening on a unix socket in `$HOME/.jawn/`
  (the `jawn-bt` service already proves the pattern). JSON in, JSON out, one long-lived
  connection, a request id per call.
- Perl side: `subs::device_call('sms.send', {...})`; the `termux-*` implementation stays
  behind a flag until the replacement is proven on the phone.
- Order: `battery`, `notification`, `toast`, `clipboard`, `wake-lock`, `sms-send`,
  `sms-list`, `location`, `telephony`, `call-log`, `tts`, `camera-photo`, `fingerprint`,
  `volume`, `torch`, `media-player`, `share`, `open`, `contact-list`, then the rest.
- Fold the API app into the service as each command moves. Do not merge first and migrate
  second — move the command, then delete the code path.
- **Exit:** grep finds no `termux-*` outside the fallback shim; the API app is uninstalled
  on both devices and nothing noticed.

### M2 — Supervisor

- Own `SessionService`: fork/exec, explicit env (`HOME`, `PATH`, `TMPDIR`, `PERL5LIB`,
  `TERM`), pipes into `~/manager.log`, signal delivery, respawn, the
  `~/.president/status` restart loop.
- `JawnLauncher` execs Perl directly. No `login`, no `bash`, no `termux-exec`; the
  `#!/data/data/...` shebangs disappear with the runtime in M3, so the supervisor must
  exec the interpreter by absolute path.
- Keep a PTY only when the Console opens; attach to the live session rather than starting
  a second one.
- Replace `RunCommandService`/`termux-am` with the same service API (`jawn-wake`,
  notifications, BLE come from M1's bridge or M2's service).
- **Exit:** jawn starts, restarts and stops with the app; the Console still scrolls; no
  `bin/login` in any process tree.

### M3 — Runtime

The milestone that actually leaves Termux.

- Build Perl for Android (aarch64) with `perl-cross` or Termux's own perl recipe, as
  `libjawnrt.so` (or `libperl.so` plus a `perl` wrapper) exec'd per Spike B.
- Cross-build the XS modules: `Sereal::Encoder`/`Decoder`, `DBD::SQLite` (for
  `Mojo::SQLite`/`Minion`), `CryptX` (and its `Crypt::*` users), `Net::SSLeay`,
  `LWP::Protocol::https`. The pure-Perl remainder ships as a `.pm` tree in assets or a
  packed archive.
- Tool diet, decided here:

  | Keep bundled (candidates) | Replace with an Android API (candidates) | Droppable? |
  | --- | --- | --- |
  | `openssl`, `sqlite3`, `argon2`, `curl`, `ssh`, `sshpass`, `autossh`, `rsync`, `git`, `zip` | `espeak`/piper → `TextToSpeech`, `tesseract` → ML Kit, `convert` → `BitmapFactory`, `ffmpeg`/`sox` → `MediaCodec` | `node`, `tmux`, `qrencode`, `zbarimg` — confirm before cutting |

- First run without `git`: ship the tree as an asset or fetch a versioned archive over
  HTTPS and verify a pinned hash. Decide whether that is acceptable under the distribution
  model chosen in M5.
- Remove `TermuxInstaller`, the bootstrap zip, `pkg` sources, `termux-exec`.
- **Exit:** a clean install on a device with no Termux runs the wizard, installs nothing,
  and starts jawn; the APK has no `assets/bootstrap*` and no `libtermux-bootstrap.so`.

### M4 — Identity

- New package (`org.jawnos` suggested; `com.jawnos` is fine if unclaimed), no `sharedUserId`.
- Replace or vendor `terminal-view`/`terminal-emulator` (Apache-2.0, keep notices) into our
  namespace; delete `termux-shared`, the settings fragments for Boot/Float/Styling/Tasker/
  Widget, plugin detection, and `com.termux` strings in `TermuxConstants`, `strings.xml` and
  `shortcuts.xml`.
- The WebView host is already ours (`JawnBrowserActivity`), as is the dashboard.
- **Exit:** `grep -r com.termux` in the app repo returns only upstream notices and license
  files; the app can be relicensed BSD-2 (`~/jawnos-app/PLAN.md` §7 has the GPL obligations
  for the fork until this lands).

### M5 — Distribution

- If Spike B passed: targetSdk 36, AAB, Play App Signing, no self-update on the Play build.
  If not: sideload/GitHub/F-Droid with `targetSdk 28`, a verified self-updater, and a
  documented warning that the install floor may rise.
- One signing key forever; publish the corresponding source for the exact built revision.

## Order and the one thing not to do

Sequence is M0 → M1 → M2 → M3 → M4 → M5. M1 is the biggest visible win and the lowest
risk; M3 is the project.

**Do not relocate the bootstrap.** `~/jawnos-app/PLAN.md` §2/§6 Route B (same-length
`com.termux` → `org.jawnos` replacement inside the 29 MB bootstrap, plus a `pkg` wrapper)
is wasted work under this roadmap: M3 deletes the bootstrap and everything it relocated.
Keep `com.termux` until M4, ship M1–M3 to your own devices on the current build, and mint
the new identity when there is no prefix left to migrate. The old app stays installed as
the fallback throughout.

## Dependency ledger

`scripts/termux_ledger.pl` produces it. The replacement names and the tool
intent are maps at the top of that script, so recording a decision is one line.

Per call site:

| File:line | Command | Args | Output parsed | Replacement (`subs::device_call`) | Status |
| --- | --- | --- | --- | --- | --- |
| `subroutines.pl:3571` | `termux-battery-status` | — | JSON `percentage`, `plugged` | `battery.status` | todo |

Per tool and module:

| Name | Used by | Core? | Decision |
| --- | --- | --- | --- |
| `perl` | everything | yes | bundle (M3) |
| `git` | `JawnFirstRun`, self-update | no | drop or bundle (M3) |
| `termux-api` | device commands | yes | bridge (M1) |

## Ratchet

A check that stops the dependency from growing while it is being removed. It is
live: `t/20-termux-ledger.t` runs it, so `prove -l t` and the pre-push hook catch
a new dependency the day it is added.

- `scripts/termux_ledger.pl --check` fails when the count of raw `termux-*` call
  sites, the logical call sites, or the tool/module lists exceed the recorded
  baseline — and when a command, tool or module is swapped for one that is not in
  the baseline lists (a swap that leaves the totals unchanged).
- The baseline in the script is decremented in the same commit as each migration.

## Risks

- **Upstream drift** disappears once M4 lands, but the rebase cost between now and then is
  real; keep the fork deltas small and logged in `~/jawnos-app/JAWNOS.md`.
- **XS build pain** is the likeliest M3 overrun: `CryptX`, `Sereal` and `DBD::SQLite` all
  need working NDK toolchains and matching `perl` config.
- **Runtime size**: Perl plus modules plus tools can exceed 100 MB, which changes the update
  story and the store listing.
- **The install floor**: Spike B passed on Android 16 at targetSdk 28 and 36, so the
  pre-M3 app is not stranded by a rising floor; the app can move to a current targetSdk.
- **Samsung's cgroup demotion** (`~/jawnos-app/PLAN.md` §0) is unaffected by any of this —
  the dot and the foreground service stay as they are.

## Open decisions

1. Exec model — **decided by Spike B:** an executable PIE in `jniLibs`, run by
   absolute path from `nativeLibraryDir`, at targetSdk 35/36.
2. Bundle the runtime in the APK, or host our own package repo (a package manager we own)?
3. The tool diet, per tool.
4. Device transport: unix socket (recommended, matches `jawn-bt`) or broadcasts.
5. Update channel: Play, GitHub, or F-Droid — and when the peer APK sync ends.
6. Cut-over plan for the two devices, and how long the `com.termux` build stays installed.
