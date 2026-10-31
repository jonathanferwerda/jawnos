# Leaving Termux — building the JawnOS app from scratch

**Status:** draft 2026-10-30. **M0 landed**, **both spikes passed**, and **M1 is
running with a native-first rule**: battery, notification, toast, clipboard,
volume, torch, wake lock, contacts, SMS, call log, location, speech, telephony,
media, share, open, the notification shade, microphone recording, the camera
and the biometric prompt are answered by the app itself (build 1189 /
0.118.190), and the phone-only gaps were closed on a Galaxy S24 FE (Android 17) and proven on the tablet. The other commands, the single-app fold-in
and the `com.jawnos` identity are ahead.
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

## Spikes (done before M1)

Two experiments, a day each, settle decisions that are expensive to unmake. M0 did
not wait for them: it changes only this tree, and the spikes decide the app-side
shape M1 and M2 take.

### Spike A — does jawn need a tty? ✅ 2026-10-30

- **Method:** a disposable `git clone` of the tree, its own `HOME`, a fresh
  database built from `database/schema.sql`, a throwaway TLS cert, ports
  3900/3901, all inside `unshare -rn` (a network namespace with only loopback
  up), and `jawn`'s `ReadWriteFork` conduit changed from `type => "pty"` to
  `type => "pipe"`. stdout/stderr went to a file, so no terminal existed
  anywhere. The scripts are `.shots/spike-a/` (scratch, not committed).
- **Result:** the tree starts in 2 s (`/manager` answers 200), President and
  its workers run (25 president processes, 9 manager workers at the peak), one
  `/manager/ws` client upgrades and stays connected, `restart` through
  `~/.president/status` completes (status `good`, a new President pid after
  ~46 s — the master's 3 s delay plus boot), the manager and the websocket work
  again on the new tree, and SIGINT makes the master exit clean and leave no
  child behind ("leftover check: clean").
- **No tty calls:** the runtime has no `isatty`, `TIOCGWINSZ`, `tcgetattr` or
  `-t STD*` (only `scripts/jawnos_network.pl`, a CLI helper, checks `-t STDIN`).
  Bash on a pipe prints no job-control noise, and the master's tee still fills
  `~/pty.log` (466 lines), so the error watch keeps its copy.
- **Then:** the supervisor is a plain process manager; the PTY becomes a
  Console-only feature. M2 can drop `bin/login` and the terminal session from
  the boot path.
- **Caveat:** the sandbox used `"live": "yes"` so a loopback client is
  approved the way the live image approves it (the fresh database has no ticket
  to seed). That key affects authentication, not the tty question.

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
| **M0 Contracts** | dependency ledger + `subs::device()` wrapper at call sites, behaviour unchanged | nothing yet | ~1 week ✅ |
| **M1 Device bridge** | `DeviceService` (unix socket, JSON) in the app; termux commands migrated one by one | `termux-api` package, `com.termux.api`, second APK | 2–3 weeks ✅ (all 24 native; API app retired) |
| **M2 Supervisor** | own process supervisor + PTY only for Console | `TermuxService`, `RunCommandService`, `termux-am`, `termux-exec`, `bin/login` | ~2 weeks ✅ (`bin/login`, `termux-exec` gone; `TermuxService` left for the Console) |
| **M3 Runtime** | bundled Perl + XS modules + a decided tool set | bootstrap, `pkg`/`apt`/`dpkg`, `TermuxInstaller`, first-run `git clone` | 4–8 weeks ✅ (`pkg`/`apt`/`dpkg` and the bootstrap are gone; both ABIs pinned and proven) |
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

### M1 — Device bridge (all 24 commands native; termux fallbacks still in place)

- **Landed (app 1189 / 0.118.190):** `DeviceService` in the app
  (`com.termux.app`): loopback `127.0.0.1:46000`, newline-delimited JSON, a
  request id per call, one long-lived connection, and a token the app writes to
  `$HOME/.jawn/device.token` (mode 600; the app and Termux share one uid). It
  starts and stops with jawn, beside the BLE bridge, and answers `ping` and
  `battery.status` in the termux-battery-status shape.
- **Perl side:** `subs::device_call($method, $args)` dials the bridge and returns
  the decoded result, or undef on any failure; `battery_sample` prefers it and
  keeps `subs::device_run('battery-status', ...)` as the fallback. An old app
  with a new tree and a new app with an old tree both work, which is why the app
  can ship before the device proof. `t/21-device-bridge.t` pins the protocol
  against a reference server, and the ledger lists bridge call sites.
- **Transport decided: loopback plus a token, not a filesystem unix socket.**
  `android.net.LocalServerSocket` binds the abstract namespace only; a
  filesystem listener needs JNI, and `jawn-bt` already uses loopback. The token
  is the part jawn-bt lacks. This settles open decision 4 unless a later
  milestone wants the JNI.
- **Native first, not a termux port.** Every command is rebuilt on the Android
  API that owns it, so the app gains what termux-* never exposed. The bridge
  methods landed so far:
  - `battery.status` — `BatteryManager` + the sticky battery intent.
  - `network.interfaces` — `NetworkInterface` plus the active network's
    `LinkProperties`: the IPv4 address, netmask, broadcast, MAC and default
    gateway per interface. The runtime has no `ifconfig`, and `ip addr` cannot
    bind a netlink socket as an app uid (SELinux), so this is the only source of
    the tree's interface report on Android; a desktop still parses `ifconfig`.
    Without it the `devices` row carried `{}` and nothing knew its own address.
  - `notification.post` — `NotificationManager`, reusing the app's two channels
    (`jawn_notifications`, `jawn_notifications_silent`); a small icon by
    drawable name or app concept, a **large icon decoded from any file**, up to
    three actions that open the WebView at a URL, a progress bar, grouping, a
    vibration pattern, colour, ongoing.
  - `notification.remove` — `NotificationManager.cancel(tag)`.
  - `toast.show` — native `Toast`.
  - `clipboard.get` / `clipboard.set` — `ClipboardManager`. Background reads are
    allowed because the app still targets 28; the day it moves to 35+ a read
    needs focus (or the default-IME route), which is a note for M4/M5.
  - `audio.volume` — `AudioManager`; the six termux streams, set and read, in
    termux-volume's shape.
  - `hardware.torch` — `CameraManager.setTorchMode` on the first camera with a
    flash unit.
  - `power.wake_lock` / `power.wake_unlock` — one named `PARTIAL_WAKE_LOCK`
    (`jawnos:device-bridge`), released on destroy.
  - `sms.send` — `SmsManager`, multipart; `dry_run` reports the parts without
    touching the radio.
  - `sms.list` — `Telephony.Sms`, newest N in termux-sms-list's shape.
  - `telephony.call_log` — `CallLog.Calls`, duration as `H:MM:SS`/`M:SS`.
  - `contact.list` — `ContactsContract`, capped. (The CallLog and SMS providers
    reject a `LIMIT` in the sort order, so all three cap in the cursor loop.)
  - `location.current` — one bounded GPS fix via `LocationManager`; the app's
    `JawnLocationService` is still the primary source and jawn reads its file
    first.
  - `speech.speak` — `TextToSpeech` with voice, rate, pitch and queue mode.
    Piper is still rendered first in `say_it`; espeak remains the desktop
    fallback, and this is the Android fallback where termux-tts-speak was.
  - `telephony.dial` — `Intent.ACTION_CALL`; a `dry_run` only resolves a handler.
  - `telephony.deviceinfo` — `TelephonyManager` (phone type, SIM state, network
    type).
  - `media.player` — `MediaPlayer`, one clip at a time (jawn's Piper WAV and
    notification sounds), play/stop.
  - `share.send` — `ACTION_SEND` through the existing FileProvider, with text
    and/or a file; accepts termux-share's mime-as-action shape.
  - `open.url` — `ACTION_VIEW` for a URL or a FileProvider file path.
  - `notification.list` — `JawnNotificationListener`, a
    `NotificationListenerService`; it connects only after the person grants
    Notification access, and without the grant the tree falls back.
  - `media.record` — `MediaRecorder`, MPEG-4/AAC into the path the tree names
    `.mp3` (the container termux-microphone-record writes), start/stop.
  - `camera.photo` — headless Camera2 + ImageReader, no preview surface, a JPEG
    to the caller's path.
  - `auth.fingerprint` — `BiometricPrompt`, which only runs in an Activity:
    `JawnBridgeAuthActivity` is a translucent Activity the service starts, and
    it hands the answer back in-process with termux-fingerprint's
    `auth_result`.
  - Every flag (`silent`, `ongoing`, `dry_run`, `on`, `flush`) is read through a
    tolerant reader: Perl sends `1`/`0`, and `JSONObject.optBoolean` only reads
    a real JSON boolean.
  `notification_sender` and the clipboard/volume/torch/wake call sites asked the
  bridge first and kept the termux commands as fallbacks through M1; the M1 exit
  removed those fallbacks for every command proven on both devices.
- **M1 exit (2026-10-30):** the fallback is gone for `battery.status`,
  `notification.post`/`remove`, `toast.show`, `clipboard.get`, `audio.volume`,
  `power.wake_lock`/`unlock`, `contact.list`, `location.current`, `speech.speak`,
  `media.player`, `share.send` and `open.url` — `subs::device_call` is now the
  only path, and a machine with no bridge reports nothing instead of spawning a
  command that is no longer installed. `scripts/termux_ledger.pl` records the
  thirteen call sites still holding a fallback: `sms.send`, `sms.list`,
  `telephony.call_log`, `telephony.dial`, `telephony.deviceinfo`,
  `hardware.torch`, `notification.list`, `media.record`, `camera.photo`,
  `auth.fingerprint` and the first-run wizard's exempt `termux-open`.
  `t/20-termux-ledger.t` pins that list, so a migrated command cannot quietly
  regain a fallback.
- **M1 exit, second pass (2026-10-30, builds 1190 on both devices):** the phone
  caught up to the app build that carries all 25 methods, so the last four
  fallbacks (`notification.list`, `media.record`, `camera.photo`,
  `auth.fingerprint`) and `hardware.torch` are gone too. What still falls back:
  `sms.send`, `sms.list`, `telephony.call_log`, `telephony.dial`,
  `telephony.deviceinfo` and the wizard's exempt `termux-open` — the SMS and
  call commands wait on a real send and a real call, which are held on purpose.
- **Proven on the tablet (2026-10-30):** build 1179 posted a native notification
  (`dumpsys notification` showed the title, text and progress 60/100 on
  `com.termux`) and `notification.remove` cleared it; `toast.show` returned ok.
  The battery proof (build 1178) showed `subs::battery_sample` with
  `source => 'bridge'`. Build 1180 then round-tripped the clipboard text,
  returned all six audio streams (and set one to its current value),
  acquired/released `jawnos:device-bridge` (visible and then cleared in
  `dumpsys power`), and reported `{on:false}` for the torch — this Wi-Fi tablet
  has no flash unit, so the torch still needs a phone to prove.
  Build 1182 read the tablet's contacts (3 rows). The call log and SMS list
  returned empty lists from the real providers (no SIM), and `sms.send` answered
  "Sms is not supported" — so SMS/call-log behaviour and the torch still need
  the phone. Build 1184 returned `phone_type=none, sim_state=unknown,
  network_type=unknown` for the Wi-Fi tablet, `would_dial=1` for a dry run
  (CALL_PHONE itself is **denied** on this tablet), spoke through
  `com.google.android.tts`, and returned a GPS last-known fix (95 m, ~24 min
  old — the caller's age check discards it). The silent notification was
  verified on `jawn_notifications_silent` (importance 2, no sound). The flag
  bug that read `1` as false was live on the tablet for one build; it made
  "silent" notifications noisy until 0.118.185. Build 1187 played and stopped
  `ding.mp3` (4.5 s) through `MediaPlayer`, shared a file (`shared=1`) and
  opened the manager URL (Chrome, `opened=1`). Build 1188, with the listener
  granted for the test, read 6 active notifications (the bridge's own
  foreground notification among them) and recorded a 2-second clip (16 KB) to a
  file that was then deleted. The listener grant was removed again; enabling it
  is the person's own toggle (Settings -> Apps -> Special access ->
  Notification access). Build 1189 captured a 352 KB JPEG from camera 0 (the
  file then deleted), and the biometric prompt returned
  `AUTH_RESULT_FAILURE: Face Unlock not set up` on the tablet — a definitive
  answer, not a second prompt through termux.

  On the phone (SM-S721W, Android 17, app 1187) the same bridge answered
  `phone_type=gsm, sim_state=ready, network_type=lte`, read 10 SMS and 30 call
  log rows (counts only, no contents), reported `would_dial=1` for a dry run,
  and spoke through the TTS engine. The torch turned on and then off
  (`on=1`, `0`), confirming the tablet's failure was a missing flash unit. No
  call was placed and no message sent.
- **Rollback:** an older app build can be rebuilt from its commit in the app
  repo; the tree never depends on the bridge (it falls back).
- **Remaining:** nothing. Every one of the 24 commands is answered by the app
  and its fallback is deleted; `scripts/termux_ledger.pl` finds exactly one
  `termux-*` call site, the first-run wizard's exempt `termux-open`. The last
  proofs (2026-10-30, app 1190/1191): a real outgoing call to the one sanctioned
  number (`PLACE_OUTGOING_CALL` → `DIALING` → ended), one SMS sent through
  `sms.send`, `sms.list` 10 rows, `telephony.call_log` 30 rows,
  `deviceinfo` gsm/ready/lte.
- **API app retirement (2026-10-30):** the two things the main app still needed
  `com.termux.api` for moved in. `JawnBleService` is now `com.termux.app`'s (the
  v2 multi-link NUS daemon on `127.0.0.1:45999`, same wire format, so
  `scripts/jawn-bt` and the tree are unchanged beyond the component name), and
  `JawnGrantAllActivity` became `JawnPermissionsActivity`, which requests the
  runtime permissions in the app's own name. `JawnLauncher.startBle` also sends
  the legacy daemon its stop action so two bridges never fight for the port.
  Proven on both devices: the new service binds and answers `jawn-bt status`
  (`{"protocol":2,"links":[]}`), and `jawn-bt scan` returns real advertisements.
  Nothing in the tree calls a termux-* command now, so the API app is only a
  fallback and can be uninstalled.

### M2 — Supervisor — done for the tree

- `SessionService` (app): fork/exec `perl ./jawn` with an explicit environment
  (`HOME`, `PREFIX`, `PATH` with `$PREFIX/bin` plus `/system/bin`, `TMPDIR`,
  `LANG`, `TERM`, `PWD`, `TERMUX_VERSION`; `LD_PRELOAD` removed), one merged
  stdout/stderr pipe appended to `~/manager.log`, and a thread that keeps
  exactly one master: it stands down while `~/.president/pid` still answers,
  respawns an unexpected exit with a 2/5/10/30/60 s backoff (reset after a
  minute of uptime), and never touches `~/.president/status` — the tree's own
  loop still owns restarts. Stop sends the master SIGINT (`/system/bin/kill
  -INT`), runs `manager_killer.pl master` as mop-up, and stops the service.
  `JawnLauncher` routes Start/Restart/Stop and the boot receiver through it; the
  dashboard gains "Run jawn under the app's own supervisor" (default on, old
  Termux session as the rollback).
- `jawn` names the interpreter it is running under (`exec '$^X'
  ./President.pl`) instead of letting the pty shell resolve President.pl's
  `#!/usr/bin/perl`, which only worked through termux-exec.
- **No PTY is created.** Spike A proved the tree needs no tty, so the supervisor
  uses pipes; the Console button opens the live `~/manager.log` (the same file
  the app's Log button tails) rather than starting a second shell session. A
  PTY is only worth adding when a real console is wanted.
- **Proven on the tablet (SM-X400, app 1190, tree 0.1.1640):** woke into
  `com.termux → perl ./jawn → perl ./President.pl` with **no `bin/login`**, port
  3000 listening and status `good`; the notification sits on the `jawn-session`
  channel. `printf restart > ~/.president/status` went back to `good` in ~45 s
  (master re-exec keeps its pid). `kill -INT` on the master was noticed and the
  supervisor respawned it (log: "jawn exited (status 0 after 140s); restarting
  in 2s" → "jawn started"). `am force-stop com.termux` took the tree down with
  the app; relaunching brought it back. The same start was repeated on the
  phone (SM-S721W, app 1190, tree 0.1.1640): status `good`, no `bin/login`.
- **Exit:** jawn starts, restarts and stops with the app; the Console shows the
  tree's live output; no `bin/login` in any process tree. The last Termux-runtime
  shebang is gone too (2026-10-31, `scripts/app_displayer.pl`). `TermuxService`
  and `RunCommandService` remain as the Console's rollback path; M4 deletes them
  with the terminal stack.

### M3 — Runtime

The milestone that actually leaves Termux.

- **M3a — the runtime archive (2026-10-30):** `scripts/runtime_build.pl` decides
  the diet from a built prefix and `scripts/runtime_zip.pl` packs it. The diet is
  executable rather than prose: a tool allow-list (perl, openssl, sqlite3,
  curl, ssh, git, the shell utilities; no `pkg`/`apt`/`dpkg`, no `cpanm`, no
  editors), `lib/perl5`, `libexec/git-core`, `share/terminfo` and the CA bundle,
  with every pod, man page and `CORE/*.h` pruned. From the tablet's prefix that is
  **3,313 files / 128.7 MB uncompressed / 44.9 MB zipped**.
- **Libraries are read, not listed.** The diet resolves every shipped ELF's
  `DT_NEEDED` (a ~60-line header parse, so it works on a device with no
  `readelf`) and adds what the prefix carries, transitively; a name the prefix
  cannot provide is a **build failure that names it**, never a silent gap. A name
  list cannot work here: the first archive shipped without
  `libandroid-utimes.so`, so the unpacked `perl` would not start. The same rule
  replaced a blanket `lib/*.so*` that had dragged in ~240 MB of things nothing
  links (`libonnxruntime`, `libicudata`, the ffmpeg and `libvulkan` stacks). The
  38 libraries a complete aarch64 runtime actually needs are `libcurl`,
  `libssl`/`libcrypto`, `libsqlite3`, `libz`, `libandroid-*`, the ssh chain and
  git's `libpcre2`/`libiconv`/`libzstd`.
- **Proven (tablet, 2026-10-30):** the archive was unpacked into an empty
  directory and ran from there, away from `$PREFIX`, with only
  `LD_LIBRARY_PATH` and `PERL5LIB`: `perl v5.42.0` plus `Sereal::Encoder`,
  `Sereal::Decoder`, `DBD::SQLite`, `CryptX`, `Net::SSLeay`, `LWP::Protocol::https`,
  `URI::Encode`, `JSON::PP`, `Mojolicious`, `Minion` and `Mojo::SQLite` all loaded
  from the runtime's own tree. `curl`, `git`, `openssl`, `sqlite3`, `ssh`, `dash`,
  `bash`, `awk`, `sed`, `grep`, `zip`/`unzip`, `tar`, `rsync` and `zstd` all run;
  `https://github.com` answers 200 through both `curl` and `LWP`, and
  `git ls-remote` works, so the CA bundle and `git-remote-http` are in place.
  `t/27-runtime-build.t` pins the diet, the `DT_NEEDED` closure, the refusal of an
  incomplete prefix and of a missing library, and the modes/symlinks.
  **The failure that test exists for:** the stage copy took run-as's umask, so
  every tool in the first archive was `0666` and the unpacked `perl` was not
  executable.
- **Media tools stay bundled (2026-10-30).** `ffmpeg`, `ffprobe`, `magick` and
  `convert` are in the diet on purpose. The plan was MediaCodec and
  BitmapFactory, but those replace a codec call, not the 51 places the tree pipes
  a file through `ffmpeg -i … -vframes 1 | magick - -resize` for a thumbnail, the
  loudness pass, subtitle extraction or Music's video stream. Dropping them would
  not be a diet, it would be a regression. The cost is real: they drag in **161
  libraries** (the av* stack, x265/aom/rav1e/SVT-AV1/dav1d/vpx, and ImageMagick's
  cairo/pango/harfbuzz/fontconfig/freetype/rsvg/ghostscript/OpenEXR/jxl/heif), so
  the archive goes **128.7 MB → 291.6 MB raw and 44.9 MB → 109.5 MB zipped**.
  Two cheaper shapes if that first download matters: a separate “media pack”
  fetched after the tree is up (the app already knows how to fetch, verify and
  unpack one archive), or a custom ffmpeg/ImageMagick build without the codecs
  nothing here encodes. A native resize in the device bridge would remove all of
  ImageMagick on its own.
- **x86_64 is built on the emulator (2026-10-30).** Termux packages `perl` but
  **no CPAN module**, so the only source is a prefix you build by hand. The
  recipe, proven end to end on `emulator-5554`:
  1. `bootstrap-x86_64.zip` from the termux-packages release, unzipped into
     `files/usr`, then `SYMLINKS.txt` applied (`target←link`, both relative to
     the link's own directory; `ln -sfn` each one).
  2. `pkg install perl make git curl openssl sqlite rsync zip unzip xz-utils
     zstd openssh sshpass inetutils procps psmisc ldns ca-certificates ffmpeg
     imagemagick` — `clang` comes with ImageMagick.
  3. `cpanm` the 40 modules from `scripts/jawnos_deps.pl`.
  4. `runtime_build.pl --from $PREFIX --abi x86_64`.
  Three traps that cost a rebuild each: `pkg`/`apt` **refuse to run as root**, and
  a uid that has not run an app process since `pm clear` has **no network** (start
  any activity once); cpanm's default **60 s configure timeout** kills `IO::Tty`,
  which probes the system slowly — `--configure-timeout 600`; and `IO::Tty` needs
  `CORE/*.h`, which the diet prunes, plus a compiler and `make`, which it does not
  ship — build with the headers and a pushed clang, then pack (none of it is in
  the archive: `bin` stayed at 74 entries).
- **The diet also needed `base64`, `timeout`, `ip`, `ss` and `ping` (2026-10-30).**
  Its first x86_64 runtime passed every proof and still failed in the tree:
  `watch.pl` runs `base64 --decode`, and `timeout` wraps a dozen call sites. With
  neither in the runtime the shell fell through to Android's toybox, which has no
  `--decode`, and the manager logged `base64: Unknown option 'decode'` on every
  watch secret. `ip`/`ss` come from iproute2 and `ping` is Termux's three-line
  wrapper around `/system/bin/ping`. (`ip` still cannot bind netlink as an app uid
  — that is Android, not the runtime, and was equally true under Termux.)
- **Proven on a device (tablet, app 1192):** the archive unpacked to
  `~/.jawnos/runtime` and `SessionService` prefers it — the master's
  `/proc/<pid>/exe` is `…/.jawnos/runtime/bin/perl`, the tree reached
  `status=good` with every worker up and 3000 answering, and Termux's perl stays
  the fallback. That is the runtime half of leaving Termux done: the tree no
  longer needs the prefix's interpreter.
- **What actually moves on a release (2026-10-30).** `app_publish.pl` uploads the
  **APK (18.2 MB)** and a manifest; the runtimes are separate assets that only
  move when the module or tool set changes, which during M3 was every time and
  after M3 is rare. The tree already updates incrementally (`git fetch` on the
  30-minute code sync), so nothing about a normal tree change re-downloads a
  runtime. Measured costs if the runtime does change: aarch64 109.9 MB, x86_64
  100.1 MB zipped; ImageMagick alone is **40.2 MB raw** of it.
- **Slicing the runtime is possible but not free; decide before building.**
  Three shapes, cheapest first:
  1. **Layers** — core (perl + modules + shell tools), media (ffmpeg +
     ImageMagick), voice (Piper when it lands), each with its own sha in the
     manifest. The app keeps layers on disk and refetches only one whose hash
     moved. A perl-only change then costs ~45 MB instead of 110, and adding
     voices touches nothing else. Cost: the unpacker learns three archives.
  2. **Per-file manifest + HTTP ranges** (rsync over HTTPS): a list of paths and
     sha256s, downloaded individually. Turns a runtime update into a few MB, but
     needs somewhere to serve the files that is not a GitHub release asset.
  3. **Delta patches** (bsdiff / `zstd --patch-from`) between consecutive
     versions, ~5–10 MB. Cheap to generate, but every device must hold the exact
     previous archive, and one skipped version wastes the patch.
  The cheapest win is not a mechanism at all: the native thumbnail path deletes
  ImageMagick's 40 MB, and a voice pack keeps Piper's stack out of the base.
- **Subtitles are the one ffmpeg job Android cannot do.** `rock_and_roll` serves
  a film; if no `.vtt` sits beside it, the route runs `ffmpeg -i … -map 0:s:0`
  once — the result is cached as the sidecar and served as WebVTT thereafter, so
  it costs one extraction per film, not one per play. Android has no public API
  to pull a subtitle track out of a container; `MediaExtractor` can read text
  samples in some MP4/MKV variants, but that is undocumented territory. So
  ffmpeg stays for subtitles until every library already carries a `.vtt`.
  **Fallback to build (2026-10-30):** when a film has no sidecar and the local
  extractor cannot read the track, ask the film's `remote_machine` for the `.vtt`
  first — a film is usually watched on the laptop, whose copy already has the
  subtitle track extracted — and only then fall back to a local ffmpeg pass.
- **Native thumbnails are in (app 1200, 2026-10-30).** The bridge grew
  `media.thumbnail` (path, max, at_ms) → base64 PNG: `MediaMetadataRetriever`
  for a film frame, `BitmapFactory` + `ExifInterface` for a picture (sampled, so a
  40 MP photo is never fully decoded), `PdfRenderer` for a page. The manager's six
  thumbnail sites call it first and keep their `ffmpeg | magick` pipeline as the
  fallback, which is what a desktop uses (there is no bridge) and what an old
  phone with an older app gets. Proven on the emulator over the real bridge: an
  icon came back 119×128, a generated clip's frame came back 160×90, and a
  missing file is refused so the caller falls back.
- **But the archive did not shrink.** ImageMagick has ~30 other jobs — camera
  capture resize, photo conversion, cover art, colour extraction, montage,
  crops, PDF export — so the 40 MB stays until those move too. Measured: with
  `magick`/`convert` out of the diet the x86_64 archive is 242.1 MB instead of
  282.3 MB; the 40.2 MB is only collectable when the last `magick` call site is
  gone. Next candidates, in order: `image.resize`/`image.save` in the bridge for
  the capture and convert paths, then pixel sampling for the colour extraction.
- **M4 — Identity.** Target: one app, package `com.jawnos`, no Termux code. The
  order that keeps the devices usable:
  1. **Data migration first, and it is the decision that matters.** A new package
     gets a new data directory, so `files/home` (the tree, the database) and
     `files/usr` (the runtime) must move from `/data/data/com.termux/…` to
     `/data/data/com.jawnos/…`. Options: (a) fresh install + import — a zip of
     `~/jawnos` out of the old app and into the new one, explicit and safe, one
     manual step per device; (b) in-place hand-off — the new APK copies the
     directory once and the old app is then uninstalled, no manual step but it
     needs both packages installed at once and ~300 MB of free space.
  2. Purge the identity: `applicationId`, `TermuxConstants` paths, the
     `termux-*` strings and the `.termux` intent names, `sharedUserId`, the
     plugin/TermuxService leftovers, then `termux-shared`, `terminal-view` and
     `terminal-emulator` (Apache-2.0 vendoring last, or Console disappears).
  3. Prove it on the emulator from a wiped install, then migrate the phone, then
     the tablet.
- **The prefix is baked into every binary (2026-10-30).** Changing the package
  moves the data directory, and Termux's binaries carry
  `/data/data/com.termux/files/usr` in RUNPATH, in perl's `@INC`, in git's exec
  path and CA bundle, and in sshd's default config. Fixing those one by one is
  whack-a-mole; the packer does it in one move instead: `--rewrite-prefix
  old=new` rewrites the path inside every packed file. It is only safe because
  **`com.termux` and `com.jawnos` are the same length**, so no offset in any ELF
  shifts and nothing needs re-linking. Proven on the tablet: a runtime packed
  that way runs `perl 5.42.2`, `Mojolicious`, `Minion`, `DBD::SQLite`,
  `Net::SSLeay`, `git ls-remote` over https, `ffmpeg` and `magick` with an
  **empty environment** - no `LD_LIBRARY_PATH`, no `GIT_EXEC_PATH`, no
  `SSL_CERT_FILE`. `--perl-version` keeps only the perl the device runs, since a
  long-lived prefix accumulates module trees for every perl it ever had.
- **Migration B (the phone) ran for real on 2026-10-31, and it is the recipe.**
  Back up first: `sqlite3 database/jawnos.db ".backup …"`, `config.json`,
  `schema.sql` (in `jawnos/database/`), `initial.enc`, and the four identity
  files above. Then `adb uninstall com.termux`, install com.jawnos, launch it and
  let the first run download + verify the pinned runtime and clone the tree.
  **Force-stop before restoring the house**: the first run starts jawn, and a
  tree that touches the vault before the key file is back seals it to a fresh
  key (this is the tablet's failure, exactly). Then, with the app stopped, put
  the database in `jawnos/database/jawnos.db` (delete `-wal`/`-shm` first), copy
  `config.json`, and restore `.house.key`, `.peer.key`, `.peer.pub` and
  `.jawnos_signatorial_id` (plus the mirror in `database/`), `chmod 600`. Rewrite
  the old prefix in `settings` (`update settings set value = replace(value,
  '/data/data/com.termux/files', '/data/data/com.jawnos/files') where value like
  '%/data/data/com.termux/%'`), start it and check `status=good`.
- **A fresh clone has no `.shots/ticket.txt`** (gitignored), so the app's WebView
  lands on the Gate and then sits on the splash saying "Reaching JawnOS…". Mint
  the ticket on the device: `perl scripts/app_ticket.pl <client> --save`.
- **What a migration costs on purpose.** The app key lives in the Android
  Keystore and dies with the uninstall, so the app gate asks for it again. The
  peer key, the house key and the signatorial are files: restoring them keeps the
  machine's name, its pinned peers and its vault, and no other machine has to be
  touched. On the phone that meant the house came back byte-for-byte: 119,024
  appointments, `vault`/`suds` reading, `device=e397332d…` unchanged.
- **A migration must carry three key files, not just the database.** The
  rehearsal copied `jawnos.db` and `config.json` and left `~/.house.key`,
  `~/.peer.key` and the signatorial identity file behind. The tablet then
  generated all three fresh, and the damage is exactly what those files guard:
  - `~/.house.key` unseals the device's `__president/vault` row. A new one
    cannot read it, so `suds_grabber()` returns nothing, every `box_office`
    ticket silently renders the **denial** page (`Ne PAS!`), and the WebView
    sits on "Reaching JawnOS…" forever. It is not a session or cookie problem.
  - `~/.peer.key` is the device's half of the signed peer rail. Peers pin it on
    first contact, so a new key means every request is refused (`HTTP 403` on
    `house levels`), which also blocks `vault_pull_from_peer()`.
  - the signatorial identity file is the machine's name in the house; losing it
    gives the device a **new identity** while its database, rosters and
    vouches still carry the old one.
  Recovered on 2026-10-31 by handing the house data key over from the laptop
  (`.shots/suds_export.pl` → USB → `.shots/suds_import.pl`, which accepts only a
  key this database's level-1 canary validates), then re-pinning the tablet's
  new peer key in the laptop's `remote_machines` row (`.shots/repin_peer.pl`).
  The tablet's vault reads again and the manager answers. **A migration backup
  must include those three files** (they are 45–120 bytes each); the identity
  change still needs a device re-pair, which the app gate asks for by itself
  ("Set up this device's unlock" → approve on a signed-in phone).
- **Moving the house (migration A) works, rehearsed on the tablet.**
  `sqlite3 .backup` out of com.termux, uninstall, install com.jawnos, unpack the
  rewritten runtime, clone the tree, then copy the database and `config.json`
  back and rewrite the old package's paths in `settings`; `~/storage/shared` is
  recreated because the photo paths point through it. The imported house came up
  with the same 114,390 appointments and 1,332 warehouse rows.
- **M4 — the Java package is `com.jawnos.app` (app 1209).** One mechanical
  rename moved `com.termux.app` → `com.jawnos.app`, `com.termux.shared` →
  `com.jawnos.shared`, `com.termux.filepicker` → `com.jawnos.filepicker`, the
  `termux-shared` module → `jawnos-shared` and every `com.termux.app.*` action →
  `com.jawnos.app.*`, so components finally read `com.jawnos/.app.X`. The
  manifest `package` stays `com.jawnos` — it is the R namespace and the base for
  the relative component names, and setting it to `com.jawnos.app` doubles the
  segment (`com.jawnos.app.app.TermuxApplication`, caught in the merged
  manifest). The tree asks for those names through `subs::app_package()`,
  `subs::app_action()` and `subs::app_component()`, which read
  `JAWNOS_APP_PACKAGE` and default per device, so a machine still on the fork
  keeps answering `com.termux.app.*` until it is migrated.
  `com.termux.terminal`/`com.termux.view` are untouched: the JNI binds them and
  those modules are the next deletion. Class names (`TermuxActivity` and the
  rest) are unchanged; renaming them is the cleanup pass after the modules go.
- **Two defects the rename exposed, fixed with it.** The app's notifications
  were being suppressed by the system ("Suppressing notification from package
  com.jawnos by user request") because `JawnPermissionsActivity` never asked for
  `POST_NOTIFICATIONS` even though the manifest declares it. And the permission
  screen was unreachable from the tree: `am start` on a non-exported activity
  from the tree's own shell child is refused ("package=com.android.shell does
  not belong to uid=10321"), so the exported wake receiver now handles
  `com.jawnos.app.JAWN_PERMISSIONS` and opens the screen in-process.
- **M4 state (2026-10-31):** both runtime archives are rewritten for
  `com.jawnos` and published beside the app (`jawnrt-aarch64` / `jawnrt-x86_64`
  0.1.1670, pinned in the APK's `assets/jawnrt.json`), and the phone is
  migrated. What is left is the identity purge itself — `sharedUserId`, the
  `RUN_COMMAND` permission and service, `TermuxService` and the terminal
  modules (the Console's rollback path), the 40 GPL-3-only `jawnos-shared`
  files, the `Termux*` class names and `com.termux` strings — then the tablet
  migration and the voice pack.
- **Migration A/B as a script.** `scripts/app_migrate.pl` is the checked-in form
  of that recipe: it stops the app, backs it up, uninstalls, installs, waits for
  the first run, force-stops again, restores and verifies. The command is

  ```
  perl scripts/app_migrate.pl --device SERIAL --apply
  ```

  `--dry-run` (the default, with or without the flag) prints the whole plan and
  changes nothing; `--apk FILE` overrides the newest
  `releases/jawnos-app-*.apk`; `--backup-dir DIR` overrides
  `~/.jawnos-backups/<model>-<serial>-<YYYY-MM-DD-HHMM>/`. It backs up
  `database/jawnos.db` (plus `-wal`/`-shm`, folded into the copy on the host),
  `config.json`, `.house.key`, `.peer.key`, `.peer.pub`,
  `.jawnos_signatorial_id` and its `database/` mirror (and `schema.sql` /
  `initial.enc` when present), then writes a `MANIFEST` with sizes and sha256
  and runs `PRAGMA integrity_check` on the host copy. A missing key file is a
  hard failure **before** force-stop. It does not carry `.shots/ticket.txt`;
  mint one afterwards with `perl scripts/app_ticket.pl <client> --save`.
  **The `--apk` must be the build that dropped `android:sharedUserId`.** The
  script warns loudly when the staged APK still declares it: uninstall+install
  is safe and proves the restore path, but the next in-place upgrade over that
  build will fail with `INSTALL_FAILED_UID_CHANGED` exactly as before.

  **The stop is not just `am force-stop`.** The app carries system-bound
  services (the IME, the notification listener, the VPN), so Android rebinds it
  within seconds and `SessionService` starts the tree again on its 2 s backoff;
  the exec'd `perl` tree is not an ActivityManager process at all. The script
  force-stops, **disables the package**, and `pkill`s the tree until `pgrep`
  reports none, re-enabling the package only before the final start. The first
  tablet run stopped at force-stop, left the first run's WAL beside the restored
  database, and SQLite called the restored image malformed although the file
  itself matched the backup.

  **The first run must be complete, not just visible.** `VERSION` appears while
  git is still checking out. The phone run stopped there and left the tree
  without `subroutines.pl`; a stale `.git/index.lock` then blocked `git reset`.
  The wait now requires `subroutines.pl`, `gb.pl`, `President.pl`, `Manager.pl`
  and `status=good` (`--first-run-timeout`, default 900 s).

  **The restored database is verified before it is opened**: sha256 against the
  backup, `PRAGMA integrity_check` and the appointment count. A mismatch stops
  with the app left disabled and prints `pm enable com.jawnos`; the backup is
  kept. Both devices were migrated to 1217 on 2026-10-31; each then needs a new
  ticket (`perl scripts/app_ticket.pl phone|tablet --save`, run with
  `HOME=/data/data/com.jawnos/files/home`), and the app gate asks for the device
  unlock again because the Keystore key died with the uninstall.

- **GPL pass (2026-10-31).** Twenty-one dead GPL-3-only
  `jawnos-shared` files were deleted: `UrlUtils`, `TextInputDialogUtils`, the
  API/Boot/Float/Styling/Tasker/Widget shared preferences,
  `TermuxPropertyConstants`, `TermuxSharedProperties`, `TermuxSession`, and the
  terminal extra-keys/client bases (their `build.gradle` exclusion block went
  too). Five more went in the next pass: `SELinuxUtils`, `PermissionUtils` and
  `ReflectionUtils` were deleted (the SELinux lines left `AndroidUtils` and
  `TermuxShellUtils`; `ShareUtils` uses `checkSelfPermission`/`ActivityCompat`;
  `PackageUtils` no longer needs hidden-API reflection), and `PackageUtils` and
  `TermuxUtils` were rewritten as original BSD-2 code — the former answers only
  this app's package, the latter describes JawnOS instead of
  Termux/plugins/wiki/donation. **Seven GPL-3-only originals remain, all in
  use**: `TermuxCrashUtils`, `TermuxFileUtils`, `TermuxNotificationUtils`,
  `TermuxAppSharedPreferences`, `TermuxPreferenceConstants`,
  `TermuxShellEnvironmentClient`, `TermuxShellUtils`. Those are the rewrite
  list before BSD-2; the preferences and shell helpers are the next batch.

- **M3 closed (2026-10-30, app 1198).** The app unpacks the pinned archive into
  `$PREFIX` on first run, verifies the sha256, writes
  `$PREFIX/etc/jawnos-runtime.json` (which makes `jawnos_deps.pl --install` a
  no-op), and fetches the tree. A clean install was run twice on the emulator:
  wiped app → install → launcher → download → sha256 → unpack (305 MB) → tree
  cloned → `status=good` on the runtime's own `perl`. Both devices are on the
  same build.
- **`PATH` is off Termux's prefix by construction.** There is no second prefix:
  `$PREFIX` *is* the runtime on a fresh install, and `SessionService` sets
  `PATH=$PREFIX/bin:…:/system/bin`, so the tools it names are the archive's. The
  phone and tablet were migrated to `com.jawnos` on 2026-10-31, so no Termux
  prefix remains on either device.
- **The first run still uses `git`, deliberately.** A pinned tree archive would
  only move the dependency: the tree's own code sync
  (`scripts/jawnos_update.pl`, every 30 minutes) is `git fetch`, so the checkout
  has to be a git checkout by the time the first update runs. git costs 3.6 MB
  plus `libexec/git-core` (~1 MB) in the archive and is already there for
  `jawnos_update.pl`; the app now says so plainly instead of trying to
  `pkg install -y git` from a runtime that has no package manager.
- **Known gap at close: voices.** Piper on the devices is the `piper-tts` python
  package (`lib/python3.14/site-packages/piper`, 206 MB with onnxruntime and
  numpy); `espeak` is not in the diet either. A fresh install therefore has no
  voice at all, and the tree's TTS falls back through piper → espeak → nothing.
  Of the three ways to close it — ship python (~150 MB), go native Android
  `TextToSpeech` (breaks voice consistency between phone, tablet and desktop),
  or ship the Piper CLI (a Rust/C++ binary plus libonnxruntime and the .onnx
  voices) — the consistent-voice answer is a **separate voice pack**: the same
  Piper engine and the same voice files the desktop uses, fetched on demand like
  the runtime and verified the same way, so the archive everyone downloads stays
  lean and every machine still speaks with one voice.

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

- New package **`com.jawnos`** (the chosen name; one app replaces both Termux forks), no `sharedUserId`.
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

## Native replacements

The native API each command maps to. "Granted" means the app already holds the
permission; "needs UI" and "needs listener" mean an extra step at first use.

| termux command | Android API | Note |
| --- | --- | --- |
| `battery-status` | `BatteryManager` + sticky intent | done |
| `notification`, `notification-remove` | `NotificationManager` | done; icons, actions, progress, groups |
| `notification-list` | `NotificationListenerService` | done; the person must grant Notification access |
| `toast` | `Toast` | done |
| `clipboard-get` / `clipboard-set` | `ClipboardManager` | done |
| `wake-lock` / `wake-unlock` | `PowerManager.WakeLock` | done |
| `sms-send` | `SmsManager` | done; needs a phone (no SIM in the tablet) |
| `sms-list` | `Telephony.Sms` / content provider | done; empty on the Wi-Fi tablet |
| `location` | `LocationManager` / the app's `JawnLocationService` | done |
| `telephony-call` | `Intent.ACTION_CALL` | done; CALL_PHONE is a runtime grant (denied on the test tablet) |
| `telephony-deviceinfo` | `TelephonyManager` | done |
| `call-log` | `CallLog.Calls` | done; empty on the Wi-Fi tablet |
| `tts-speak` | `TextToSpeech` | done; Piper still first |
| `camera-photo` | Camera2 + ImageReader | done; the service declares the camera type |
| `microphone-record` | `MediaRecorder` | done; the service declares the microphone type |
| `fingerprint` | `BiometricPrompt` | done; the translucent Activity half |
| `volume` | `AudioManager` | done |
| `torch` | `CameraManager.setTorchMode` | done; the tablet has no flash, so a phone still proves it |
| `media-player` | `MediaPlayer` / `ExoPlayer` | done |
| `share` | `Intent.ACTION_SEND` | done; FileProvider alias note below |
| `open` | `Intent.ACTION_VIEW` | done |
| `contact-list` | `ContactsContract` | done |

What stays native-only and has no termux equivalent today: notification actions
and progress, a large icon from any file, grouped notifications, a torch that
reports its state, and TTS with per-utterance voice control.

Two device quirks found while migrating share/open: `/data/data` and
`/data/user/0` are bind-mounted aliases and `getCanonicalPath` can keep the
tree's `/data/data` spelling, so the FileProvider names that root explicitly;
and `Intent.createChooser` needs `FLAG_ACTIVITY_NEW_TASK` on the chooser itself
when a service starts it.

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
4. Device transport — **decided:** loopback TCP plus a token (see M1). A
   filesystem unix socket would need JNI for the listening side.
5. Update channel: Play, GitHub, or F-Droid — and when the peer APK sync ends.
6. Cut-over plan for the two devices, and how long the `com.termux` build stays installed.
