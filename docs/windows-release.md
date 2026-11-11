# Releasing JawnOS for Windows

The Windows release is the per-user Inno Setup wrapper around the portable
bundle described in `installer/windows/README.md`. That README explains what the
bundle contains and how to install it; this is the release and publish runbook.

The release is two artifacts and one small feed:

- `dist\JawnOS-<version>-Setup.exe` — the per-user installer.
- `dist\JawnOS-<version>.zip` — the same payload as a portable archive.
- `windows_release.json` — the machine-readable "what is current" file, served
  from a fixed GitHub URL beside the Android app's `app_release.json`.

Build outputs belong in the gitignored `releases/` folder; `dist/` is scratch
build output and must not be committed either (it is not currently ignored).
Never commit an installer to the tracked tree: `releases/` is excluded from the
payload, so a staged Setup.exe cannot ride into the next build.

## Preconditions

- A clean checkout of the release commit, already on the trunk. `build-portable.ps1`
  takes `app\` from `git archive HEAD`, so uncommitted or untracked files are not
  in the bundle. Confirm `git status --porcelain` is empty.
- `VERSION` at the repo root names the release (`0.1.2724` here). The builder
  reads it; do not type a version that differs from the staged folder.
- Windows 11 x64 build machine with:
  - Inno Setup 6 installed and `iscc` on `PATH` (normally
    `C:\Program Files (x86)\Inno Setup 6\ISCC.exe`).
  - A prepared Strawberry Perl tree — the one you ran `cpanm` into — carrying
    both `perl\bin\perl.exe` and `c\bin`. Both directories are required; see the
    bundled-PATH note in the installer README.
  - `git`, PowerShell 5.1, and an authenticated `gh` (`gh auth status`).
- No code-signing certificate is needed to build. One is needed to claim trust;
  see [Signing](#signing).

## Build

From the repo root on the build machine:

```powershell
powershell -ExecutionPolicy Bypass -File installer\windows\build-portable.ps1 `
    -RuntimeDir C:\path\to\strawberry-perl
```

That stages `dist\JawnOS-<version>\` (`app\`, `runtime\`, the install scripts and
`README.txt`) and writes `dist\JawnOS-<version>.zip`. `-NoZip` skips the archive;
a release keeps it for the portable/Scoop path. `-OutDir` and `-TreeDir` exist
for a build outside the checkout.

Compile the wrapper against that staged folder:

```powershell
$version = (Get-Content VERSION -Raw).Trim()
iscc /DAppVersion=$version /DPayloadDir="$PWD\dist" installer\windows\jawnos.iss
```

`/DAppVersion` and `/DPayloadDir` are Inno preprocessor defines. `jawnos.iss`
otherwise falls back to `JAWNOS_VERSION` and `..\..\dist`; the explicit defines
are what a release should use, because they name both inputs in one command.
`iscc` writes:

- `dist\JawnOS-<version>-Setup.exe` (`OutputBaseFilename` in `jawnos.iss`)
- no other output — the payload folder and zip come from the PowerShell step

Copy the finished files into the tracked-excluded staging folder before hashing:

```powershell
New-Item -ItemType Directory -Force releases | Out-Null
Copy-Item "dist\JawnOS-$version-Setup.exe" releases\
Copy-Item "dist\JawnOS-$version.zip" releases\
```

## Integrity

Sign **before** hashing, if the build is signed at all. The hash in
`windows_release.json` must describe the bytes a person downloads.

```powershell
$exe = "releases\JawnOS-$version-Setup.exe"
$zip = "releases\JawnOS-$version.zip"
$exeHash = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
$zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"$exeHash  JawnOS-$version-Setup.exe`n$zipHash  JawnOS-$version.zip" |
    Set-Content -Encoding ascii releases\SHA256SUMS
```

`SHA256SUMS` is the plain `<hash>  <file>` format the usual tools read. Lowercase
hex matches what `windows_release.json` carries.

### The versionCode

`versionCode` is an integer that only ever increases, so a client can compare two
manifests without parsing a version string:

```text
versionCode = major * 100000000 + minor * 1000000 + patch
```

For `0.1.2724`: `0 * 100000000 + 1 * 1000000 + 2724 = 1002724`. It is the
Windows product's own counter; it is not compared with the Android app's
`versionCode`, because the two manifests name different products.

### windows_release.json

```json
{
  "product": "windows",
  "version": "0.1.2724",
  "versionCode": 1002724,
  "filename": "JawnOS-0.1.2724-Setup.exe",
  "sha256": "<64 lowercase hex characters>",
  "size": 0,
  "url": "https://github.com/jonathanferwerda/jawnos/releases/download/releases/JawnOS-0.1.2724-Setup.exe",
  "notes": "JawnOS 0.1.2724 for Windows x64.",
  "min_os": "10.0.22000",
  "signed": false
}
```

Write it from the built file so no number is retyped:

```powershell
$v = (Get-Content VERSION -Raw).Trim().Split('.')
$code = [int]$v[0] * 100000000 + [int]$v[1] * 1000000 + [int]$v[2]
$exe = Get-Item "releases\JawnOS-$version-Setup.exe"
$manifest = [ordered]@{
    product     = 'windows'
    version     = $version
    versionCode = $code
    filename    = $exe.Name
    sha256      = (Get-FileHash $exe.FullName -Algorithm SHA256).Hash.ToLower()
    size        = [int64]$exe.Length
    url         = "https://github.com/jonathanferwerda/jawnos/releases/download/releases/$($exe.Name)"
    notes       = "JawnOS $version for Windows x64."
    min_os      = '10.0.22000'
    signed      = $false
}
$manifest | ConvertTo-Json |
    Set-Content -Encoding utf8 releases\windows_release.json
```

Field notes:

- The numbers in the JSON example above are placeholders; the PowerShell block
  writes the real hash, size and versionCode.
- `product` is fixed `windows`, so a reader can tell this file from
  `app_release.json` on the same release.
- `filename` must be the exact asset name uploaded to the feed. The download
  URL is the fixed feed base plus that name.
- `size` is the exact byte count of the Setup.exe, not megabytes.
- `min_os` is a Windows build string; `10.0.22000` is Windows 11 21H2, the floor
  the installer targets. Do not lower it without testing on the older build.
- `signed` stays `false` until a CA-issued certificate (or Azure Trusted
  Signing / SignPath Foundation) signs this exact file. A self-signed test
  signature does **not** make it `true`: Windows still reports an untrusted
  publisher. This field is what lets a future updater refuse an unsigned file.

### The fixed feed

The manifest always lives at:

```text
https://github.com/jonathanferwerda/jawnos/releases/download/releases/windows_release.json
```

It rides the same fixed `releases` git tag as `app_release.json`; the two
product manifests coexist. The URL deliberately carries no version: clients and
the download page pin it once, and each release replaces the bytes behind it.
The versioned Setup.exe stays on its own `v<version>` release, where the bytes
never change.

## Publish

### The versioned release (permanent record and winget)

```powershell
gh release create "v$version" `
    "releases\JawnOS-$version-Setup.exe" `
    "releases\JawnOS-$version.zip" `
    "releases\SHA256SUMS" `
    --repo jonathanferwerda/jawnos `
    --title "JawnOS $version (Windows)" `
    --draft `
    --notes "Windows x64 per-user installer and portable zip. Verify with SHA256SUMS."
```

Review the draft on GitHub, then publish it:

```powershell
gh release edit "v$version" --draft=false --repo jonathanferwerda/jawnos
```

The tag is `v<version>` (for example `v0.1.2724`), distinct from the fixed
`releases` feed tag. Winget points at this release's Setup.exe because those
bytes are immutable; a hash in a winget manifest cannot be repointed later.

### The fixed feed (what an updater reads)

Upload the Setup.exe first and the manifest last, so a reader never sees a
manifest naming an asset that is not there yet:

```powershell
gh release upload releases "releases\JawnOS-$version-Setup.exe" `
    --clobber --repo jonathanferwerda/jawnos
gh release upload releases "releases\windows_release.json" `
    --clobber --repo jonathanferwerda/jawnos
```

If the `releases` release does not exist yet (normally `app_publish.pl` creates
it), create it once:

```powershell
gh release create releases --repo jonathanferwerda/jawnos `
    --title "JawnOS release feeds" --notes "App and Windows update manifests."
```

Then remove the previous Windows installer from the feed so the release does not
advertise two current versions. **Only** delete `JawnOS-*-Setup.exe` assets;
leave `app_release.json`, every `jawnos-*.apk`, and every `jawnrt-*` zip alone —
the Android devices and older app builds still read them.

```powershell
gh release view releases --repo jonathanferwerda/jawnos --json assets -q '.assets[].name'
# after checking the output:
gh release delete-asset releases "JawnOS-<previous-version>-Setup.exe" `
    --yes --repo jonathanferwerda/jawnos
```

### What each asset is for

| Asset | Lives on | Purpose |
| --- | --- | --- |
| `JawnOS-<version>-Setup.exe` | `v<version>` | permanent download, winget URL, archived release |
| `JawnOS-<version>.zip` | `v<version>` | portable/Scoop path; unpack and run `Install.bat` |
| `SHA256SUMS` | `v<version>` | human verification of both files |
| `JawnOS-<version>-Setup.exe` | `releases` feed | current stable bytes for the site and updater |
| `windows_release.json` | `releases` feed | current version/hash/size at a fixed URL |
| app assets | `releases` feed | Android; untouched by a Windows release |

Upload the same Setup.exe bytes to both releases (copy, never rebuild between
them), so the feed hash and the winget hash describe the same file.

## Signing

### Current state

The Setup.exe carries a **self-signed test signature** — `CN=JawnOS Test
Signing`, SHA-256, timestamped by DigiCert — and Windows reports an untrusted
publisher because the chain ends at a certificate nobody trusts. It exercises
the signing and timestamping path; it proves nothing about who built the file.
The test certificate is `C:\winxfer\JawnOS-test-signing.cer` on VM200.

`signed` in `windows_release.json` is `false` in this state. Do not write `true`
and do not tell people the download is trusted.

### What real trust requires

One of:

- A CA-issued **OV** or **EV** code-signing certificate whose private key lives
  on a hardware token or HSM. EV usually earns SmartScreen reputation
  immediately; OV and Trusted Signing build it as downloads accumulate.
- **Azure Trusted Signing** (Microsoft-operated; the organization must pass
  Microsoft's validation, which asks for a few years of verifiable business
  history).
- **SignPath Foundation**, free for OSI-licensed public projects. JawnOS is
  BSD-2-Clause and public, and the project is applying there.

Until one of those signs the exact published bytes, SmartScreen will warn no
matter how many times the file is re-signed with the test key.

### Re-signing

Sign the Setup.exe; the zip cannot carry Authenticode and is verified by
`SHA256SUMS`.

```powershell
$thumb = 'THUMBPRINT-OF-THE-SIGNING-CERT'
$cert  = Get-Item "Cert:\LocalMachine\My\$thumb"
Set-AuthenticodeSignature -FilePath "releases\JawnOS-$version-Setup.exe" `
    -Certificate $cert -HashAlgorithm SHA256 `
    -TimestampServer 'http://timestamp.digicert.com'
Get-AuthenticodeSignature "releases\JawnOS-$version-Setup.exe" |
    Format-List Status, StatusMessage, SignerCertificate
```

`Status` must be `Valid`; `UnknownError` or a non-empty `StatusMessage` means the
certificate is not trusted or the timestamp failed. If the CA's tooling provides
`signtool`, the equivalent is:

```powershell
signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 `
    /a "releases\JawnOS-$version-Setup.exe"
```

Timestamping matters: without it the signature stops validating when the
certificate expires. Sign, then hash, then write the manifest and upload. A
re-sign after publishing changes the bytes and invalidates both `SHA256SUMS` and
the submitted winget hash.

## SmartScreen text for the download page

Use this wording only while the file is signed by the test certificate or not
signed at all. Replace it when a CA certificate lands.

> **Windows may warn about this download.** The JawnOS Windows installer is not
> yet signed by a certificate authority, so Windows cannot verify its
> publisher. The browser may ask you to keep the file (Edge: **Downloads → … →
> Keep**; Chrome: **Downloads → Keep anyway**). If Windows SmartScreen says
> "Windows protected your PC", choose **More info** and then **Run anyway**.
> Verify the file before running it: compare `Get-FileHash
> .\JawnOS-<version>-Setup.exe -Algorithm SHA256` with the `SHA256SUMS` attached
> to the release. A warning here is expected, not a sign that the download is
> corrupted.

**Updating is manual for now.** The Windows bundle carries no `.git`, so the app
cannot update itself yet; a Setup.exe updater is in progress. To update, download
and run the new `JawnOS-<version>-Setup.exe`. It stops the running house and
keeps `config.json`, the database and `unlock-code.txt`. If a removed file
lingers after the upgrade, back up the database and reinstall cleanly.

## winget

The manifest is `installer/windows/winget/JawnOS.yaml`, a singleton. Before
submitting it:

1. Replace `<VERSION>` and `<SHA256>`. The URL must point at the **versioned**
   release (`v<version>`), not the fixed `releases` feed: winget pins the hash,
   and the feed's bytes change every release.
2. Validate and test on a clean VM:

   ```powershell
   winget validate installer\windows\winget\JawnOS.yaml
   winget install --manifest installer\windows\winget\JawnOS.yaml
   winget uninstall JonathanFerwerda.JawnOS
   ```

3. Submit to `microsoft/winget-pkgs`. Either fork the repo and add
   `manifests/j/JonathanFerwerda/JawnOS/<version>/JonathanFerwerda.JawnOS.yaml`,
   or let `wingetcreate` do it:

   ```powershell
   wingetcreate update JonathanFerwerda.JawnOS --version $version `
       --urls "https://github.com/jonathanferwerda/jawnos/releases/download/v$version/JawnOS-$version-Setup.exe" `
       --submit
   ```

The first submission is reviewed by hand; the package identifier is permanent
after that. The manifest uses `InstallerType: inno`, `Scope: user`, and the
silent switches skip the LAN/firewall task, so a silent install raises no UAC
prompt and takes the computer name and defaults. `winget upgrade` runs the new
Setup.exe over the old install — the same manual upgrade path.

## Scoop and the portable ZIP

The zip extracts to `JawnOS-<version>\` and is the honest portable path today:
unpack it and run `Install.bat`. A Scoop manifest can carry the URL and hash
with `extract_dir`, but a genuine unattended Scoop install needs a post-install
step that seeds the house and writes the shortcut; do not publish a Scoop
manifest that claims a silent install the scripts do not offer yet.

**No Microsoft Store or MSIX.** MSIX wants a signed package and a package
identity, and the app is a Perl tree that writes its config and database beside
itself under `%LOCALAPPDATA%`. Store distribution would add a Partner Center
identity and re-signing for no benefit, so it is not pursued.

## Troubleshooting

**The first boot looks stuck.** The first run builds and seeds the database and
starts the manager; the master's boot watchdog gives it 90 seconds and restarts
the tree up to three times if the web port is late. A cold Perl runtime plus
antivirus scanning can exceed that, so one self-restart is normal. Wait; then
open `https://127.0.0.1:<working_port>/manager` (`working_port` in
`config.json`) or read `%LOCALAPPDATA%\JawnOS\master.log`. `install.ps1` warns
after 120 seconds and leaves the house to finish starting. Do not reinstall
over it: the seed keeps an existing config and database.

**The install kept my settings and data.** That is deliberate. On upgrade,
`PrepareToInstall` stops the running house, then Inno overwrites the payload.
`config.json`, the database and `unlock-code.txt` are not in the payload
(`git archive` excludes them), so they survive.

**Uninstall removed the database.** Also deliberate: the house lives inside the
install folder (`%LOCALAPPDATA%\JawnOS\app\database`), and `[UninstallDelete]`
removes the generated files with the folder. Back the database up before
uninstalling. `-PurgeData` additionally removes `%USERPROFILE%\.president` (the
per-user runtime state and job logs).

**Stale files after an upgrade.** Inno overwrites files but does not delete ones
the new version removed. A clean uninstall/reinstall — after backing up
`config.json` and the database — is the current answer; an `[InstallDelete]`
narrow enough to leave those two files alone is the eventual fix.

**SmartScreen still warns after signing.** If the signer is the test
certificate, that is expected. Only a CA-issued certificate (or Trusted
Signing/SignPath) can change it, and reputation accrues over time.

**winget reports a hash mismatch.** The manifest URL must be the versioned
release whose bytes were hashed. The fixed `releases` feed is overwritten each
release and will not match an older manifest.

**The house does not start.** Check `%LOCALAPPDATA%\JawnOS\master.log`. The
launcher must put both `runtime\c\bin` and `runtime\perl\bin` on `PATH`, with
`c\bin` first; confirm the port in `config.json`.
