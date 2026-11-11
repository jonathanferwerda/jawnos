# JawnOS on Windows

A per-user install of the JawnOS Perl tree and its web interface, for a clean
Windows 11 x64 box with **no Perl, Python, WSL or Docker**. The bundle carries a
prepared Strawberry Perl runtime; `Install.bat` copies it under
`%LOCALAPPDATA%\JawnOS`, seeds `config.json` and the database, writes the unlock
code, and arranges the shortcuts.

## What works today

- The manager, the web interface (`https://127.0.0.1:<working_port>/manager`),
  the database, and the verified restart path (the web UI's Restart button is a
  kill and a start).
- A Start menu shortcut, autostart with Windows by default (`-NoAutostart`
  turns it off), and a program-scoped firewall rule for the bundled
  `perl.exe` on the private profile.
- First-run seeding without `sqlite3`, `tail` or a browser: `install.ps1`
  writes `config.json`, runs `scripts\jawnos_setup.pl --seed`, and saves a
  six-digit unlock code to `unlock-code.txt`.

Not here yet: the Qt desktop shell (P3). The web interface is the whole surface
this installer delivers.

## Build

From the repo root, with a prepared Strawberry Perl tree (the one you ran
`cpanm` into):

```powershell
powershell -ExecutionPolicy Bypass -File installer\windows\build-portable.ps1 `
    -RuntimeDir C:\path\to\strawberry-perl
```

`-RuntimeDir` is mandatory. Defaults: `-TreeDir` is the repo root (two levels
above this folder); `-OutDir` is `<TreeDir>\dist`. The staged payload is
`dist\JawnOS-<version>\` and the zip is `dist\JawnOS-<version>.zip`; pass
`-NoZip` to skip the archive. The script prints the version, the payload size
and the zip size.

`app\` comes from `git archive HEAD` - tracked files only, no `.git`, no local
`config.json`, no database, no untracked state. `runtime\` is copied from
`-RuntimeDir` with robocopy.

The reproducible build path is deliberately deferred: download the portable
Strawberry Perl archive and `cpanm` the pinned module set, the way
`.github/workflows/platform-p0.yml` does on a runner, instead of accepting a
prepared tree. That is the next slice.

## Install and test

1. On a clean Windows 11 x64 VM, extract the zip (or copy
   `dist\JawnOS-<version>\`).
2. Double-click `Install.bat`. It invokes `install.ps1` with
   `-ExecutionPolicy Bypass`, then pauses so a double-click can read the output.
3. Accept the SmartScreen prompt if it appears (the bundle is unsigned).
4. Confirm the web interface answers, the unlock code opens it, the Restart
   button works, and the Start menu shortcut starts the app.
5. Run `uninstall.ps1` and confirm the folder, shortcuts and firewall rule are
   gone; add `-PurgeData` to remove `%USERPROFILE%\.president` as well.

Useful switches: `-InstallDir <path>`, `-Quiet` (no completion dialog),
`-NoLaunch`, `-NoBrowser`, `-NoAutostart`, `-Desktop`.

## The bundled-PATH finding

The runtime needs **both** `runtime\c\bin` and `runtime\perl\bin` on `PATH`,
with `c\bin` first. `perl.exe` and the pure-Perl modules live in `perl\bin`;
`Net::SSLeay` loads `libcrypto` and `libssl` from `c\bin`. With only `perl\bin`
the module probe in `install.ps1` fails. The installer sets and `launch.bat`
reproduces:

```text
%LOCALAPPDATA%\JawnOS\runtime\c\bin;%LOCALAPPDATA%\JawnOS\runtime\perl\bin;%PATH%
```

The tree is relocatable: a copied Strawberry install works and `@INC` points at
the copy, which is what makes the bundle possible.

## Deferred / follow-ups

- **Signing.** `Setup.exe`, the zip and the PowerShell scripts are unsigned.
  Authenticode signing and SmartScreen reputation are TODO; until then the
  installer tells the person to choose "More info" then "Run anyway".
- **Seed `verify-manifest` at install time.** The first restart pays the cold
  `verify_change.pl --all` sweep (minutes, per `docs/platform-roadmap.md`);
  writing the manifest during install makes that first restart fast. Not part
  of this change.
- **Inno Setup wrapper.** `jawnos.iss` is a phase-2 skeleton for one
  `Setup.exe`; it has not been compiled or tested. `Install.bat` is the
  supported path.

## Files

- `build-portable.ps1` - stage `app\`, `runtime\`, the installer scripts and
  `README.txt`; zip them.
- `install.ps1` - per-user install, first-run seed, shortcuts, firewall,
  launch and wait.
- `uninstall.ps1` - stop the master, remove the rule and shortcuts, delete the
  folder (`-PurgeData` for `%USERPROFILE%\.president`).
- `Install.bat` - the double-click entry point.
- `jawnos.iss` - the untested Inno Setup 6 wrapper.
