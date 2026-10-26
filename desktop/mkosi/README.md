# JawnOS as an image (mkosi)

One artefact that is both the **try-it live USB** and the **installer**. Boot it,
use JawnOS, and run `jawnos-install /dev/sdX` to keep it. Nothing on the stick is
a commitment until that command runs.

Arch is the first backend. Debian is the second (see the end).

## Build

`mkosi` is not part of this tree. Install it on the build box first:

```sh
sudo pacman -S mkosi qemu-desktop edk2-ovmf \
    systemd-ukify python-pefile mtools
# or: pip install mkosi   (plus the host tools mkosi calls: qemu, OVMF, ukify,
#                          python-pefile, mtools)
```

Then:

```sh
sudo perl scripts/mkosi_build.pl --dry-run     # stage the tree, print the command
sudo perl scripts/mkosi_build.pl               # build desktop/mkosi/output/jawnos-live_0.1.raw
sudo perl scripts/mkosi_build.pl --vm          # build, then boot it in QEMU (16G disk)
sudo perl scripts/mkosi_build.pl --vm --disk-size 32   # the same, with a 32G disk
```

The built artefact stays at its minimum size (1G ESP + 5G root + 2G state ≈
8.1G) so the download stays small. `--disk-size` only affects the QEMU disk
(10–4096 GB, default 16): the image's `jawnos-grow` service expands the state
partition into the extra space at boot. The build needs root (mkosi uses a
container/chroot), network access to the Arch mirrors and to CPAN, and a few GB
of room. `--stage-only` stages without touching mkosi.

> **Built and booted on 2026-10-26.** The Arch image builds under mkosi 27 and
> boots in QEMU to a login prompt; the first boot seeds `config.json`, the
> database and the unlock code as described below. The installer path is
> exercised end to end on loop devices (see below); a real USB boot and the A/B
> update path are still unverified.

## Try it in a VM

```sh
sudo perl scripts/mkosi_build.pl --vm                  # 16G disk
sudo perl scripts/mkosi_build.pl --vm --disk-size 32   # 32G disk
```

To boot the image that is already built, without rebuilding it, use the
launcher (it opens the newest `desktop/mkosi/output/*.raw` with a 4 GB RAM, a
4-core KVM guest and `snapshot=on`, so the image is never modified):

```sh
scripts/jawnos_vm.sh            # or launch "JawnOS VM" from the applications menu
scripts/jawnos_vm.sh --check    # show the image, firmware and command
```

mkosi boots the finished disk with QEMU and an OVMF firmware. `--disk-size N`
passes `--runtime-size NG` to mkosi *and* `--ephemeral yes`: the VM runs on a
temporary copy grown to N GB and the built artefact is never modified. The
guest's `jawnos-grow` service grows `jawnos-state` (and its ext4) into the free
space, so the house has the whole disk. Only the state partition grows; the
root is a read-only overlay and cannot grow online. A VM run therefore never
turns the published image into a 32G file.

The first boot seeds `config.json` from [`config.default.json`](config.default.json),
builds a fresh encrypted database, creates the standard desktop folders, paints a
JawnOS wallpaper, and writes a generated unlock code to `~/UNLOCK-CODE.txt`.

The live desktop **opens the manager directly**: while `config.json` carries
`"live": true`, the manager trusts the machine's own loopback, so the view is
the house rather than the gate. The intro is deliberate, not a blank install:
the **Nord** theme (Polar Night paint, outline icons, fabric material), a ten-item
clothesline (sleep, walk, breakfast, lunch, dinner, water, read, stretch,
meditate, wind down), and the standard XDG folders. The unlock code in
`~/UNLOCK-CODE.txt` is still the key to the vault and to an installed machine.

`jawnos-install` removes the `live` flag, so the installed disk gets the real
Gate back, and offers `--new-signatorial` to mint a fresh identity (the default
carries the live install's own).

The defaults are deliberately plain: machine name `JawnOS`, device `computer`,
language `en`, domain `127.0.0.1`, web ports 3000 and 45545, SSH 8022, no
scanners and three public search engines. Change them in Configure after the
first login, or edit `config.default.json` before a build. The builder's own
`config.json` is **excluded** from the image, so a distributable image never
carries someone else's identity, domain or signatorial.

To boot an image you already built without rebuilding, run mkosi directly:

```sh
sudo mkosi -C desktop/mkosi --profile live --extra-tree desktop/mkosi/.stage/extra \
    --output-dir desktop/mkosi/output vm
```

Write it to a stick, and (optionally) put the theme file on it:

```sh
# after downloading every jawnos-live.raw.zst.part* from the release:
cat jawnos-live.raw.zst.part* | zstd -d > jawnos-live.raw
sudo dd if=jawnos-live.raw of=/dev/sdX bs=16M status=progress conv=fsync
# then copy jawnos-theme.txt (from jawnos.ca) to the root of the JAWNOS-ESP
# partition that appears as a small FAT drive
```

A stick needs at least 9 GB (the built image is ~8.1 GiB, and marketed
capacities round down); 16 GB or more is comfortable. The built image is
written at its minimum size, and the installer (or `jawnos-grow`, when the image
is flashed directly) expands the state partition to fill the rest.

## Choosing a theme before installing

The jawnos.ca download page offers five presets (Jawnfish, Nord, Deepjawn, Sage,
Neon) and generates a two-line `jawnos-theme.txt`:

```
# JawnOS install theme
theme=nord
```

The person copies that file to the root of the **jawnos-esp** FAT partition
(Windows/macOS can see it; the state partition is ext4 and cannot be). Two
paths read it:

- **Installer:** `jawnos-install` mounts the live ESP read-only, validates the
  slug, and writes the `appearance_theme` row into the newly copied database.
  `--theme SLUG` overrides the file; an unknown slug is rejected, not silently
  replaced with the factory theme.
- **Flashed directly (no install):** `jawnos-theme-apply.service` runs after
  firstboot, applies the same slug to the live database, and writes
  `~/.theme-applied` so a later choice in Configure → Appearance is never
  overwritten by the file still sitting on the stick.

Both call `/usr/local/bin/jawnos-theme`, which accepts `theme=nord`, a bare
`nord`, CRLF endings and comments, and only the curated presets from
`subroutines.pl::%theme_presets`. `scripts/jawnos_setup.pl --theme nord` (or
`JAWNOS_THEME=nord`) is the same validation for an unattended seed.

## What the image is

| Partition | Size | Label | Holds |
| --- | --- | --- | --- |
| 1 | 1G fixed | `jawnos-esp` | one unified kernel image at `EFI/BOOT/BOOTX64.EFI` (kernel, initrd, command line); reads `jawnos-theme.txt` from its root when the person puts one there |
| 2 | 5G fixed | `jawnos-root` | the system, read-only at boot |
| 3 | 2G min → disk | `jawnos-state` | `/home/jawn`: the checkout, `config.json`, the database |

The ESP and root are fixed sizes on purpose: every byte they do not take is a
byte the state partition can use on a stick. systemd-repart cannot grow a
filesystem on a generic partition type, so `jawnos-grow` runs `resize2fs`
explicitly after growing the partition.

The kernel command line is `systemd.volatile=overlay`: **the root is read-only
and every change to it lives in RAM until reboot.** The house lives on partition
3, so the settings, data and sealed vault you make while trying the stick are
still there after a reboot. That is the "live with persistence" part.

On first boot `jawnos-grow` first expands `jawnos-state` into whatever free
space the disk has, then `jawnos-firstboot` copies `/opt/jawnos/tree` and
`/opt/jawnos/home-skel` onto the state partition and runs
`scripts/jawnos_setup.pl --seed` as `jawn` to write `config.json` and the
machine's database from the factory seed. `jawnos-theme-apply` then applies a
theme file if one is on the ESP. A second boot finds `~/.seeded` and does
nothing; a first boot that failed is retried.

## Install to disk

```sh
jawnos-install            # prints the plan, writes nothing
sudo jawnos-install --yes /dev/sdX
sudo jawnos-install --yes --theme nord /dev/sdX   # override the file on the ESP
```

It creates a fresh partition table on the target from the same repart
definitions the image was built with, sized to the whole device: 1G ESP, 5G
root, and a `jawnos-state` that takes everything left. It then copies the ESP
and root **partitions** byte for byte (the bootloader and kernel travel with
them), copies `/home/jawn` **as files** (so the live session's changes are kept),
and applies the theme from `jawnos-theme.txt` on the live ESP. The house
partition is already full-size, so there is no post-copy grow step to get wrong.

The installer refuses to write to the stick it is running from, needs `--yes`
before it touches anything, refuses a disk with mounted filesystems on it, and
refuses a target smaller than 9G. It copies only the two system partitions, not
the live stick's grown state partition, so installing from a 64G live stick to
a 32G target is fine.

Partition nodes are refreshed after repart (`partx -u` plus a udev settle) and
the target partitions are found by filesystem label on the target disk, not with
`blkid -L` (a second JawnOS disk carries the same labels). Note that vfat
upper-cases its label (`JAWNOS-ESP`), so labels are compared case-insensitively.

## Publish the download

```sh
perl scripts/mkosi_publish.pl                 # compress + upload (needs gh auth)
perl scripts/mkosi_publish.pl --dry-run       # show the plan
perl scripts/mkosi_publish.pl --no-upload     # compress + hash + manifest only
perl scripts/mkosi_publish.pl --xz            # smaller, much slower
```

The newest `desktop/mkosi/output/*.raw` is compressed next to itself and
uploaded to the **`desktop` release**. GitHub caps one release asset at 2 GiB
and the compressed image is ~3 GiB, so it ships as pieces with a stable base
name:

- `https://github.com/<repo>/releases/download/desktop/jawnos-live.raw.zst.part01`
- `https://github.com/<repo>/releases/download/desktop/jawnos-live.raw.zst.part02`
- `https://github.com/<repo>/releases/download/desktop/desktop_release.json`

`desktop_release.json` lists every part (name, size, sha256), the compressed
and raw sha256 values, and the reassembly command. The website links the stable
release page and the manifest rather than guessing the part count:

```sh
gh release download desktop --repo <owner>/<repo> -p 'jawnos-live.raw.zst.part*'
cat jawnos-live.raw.zst.part* | zstd -d > jawnos-live.raw
```

`--part-size MB` controls the pieces (default 1900, max 2000). Even a small
image is written as one `part01`, so the instructions never change shape.
The release is created if it does not exist; no `--latest` is used, so the APK
release keeps that flag.

Compression tradeoff, measured on the first 8.1G image:

| Codec | Result | Time |
| --- | --- | --- |
| zstd -3 (default) | ~3.0 GiB (36% of raw) | ~50 s |
| xz -6 (`--xz`) | smaller | over 5 min here |

zstd is the default because publishing repeats and `zstd -d` is widely
available. `--xz` exists for a release where the last few hundred MB matter more
than CPU time. **Do not pre-grow the image for the download**; growth belongs to
the guest at first boot.

Credentials are not needed to prepare a build. Without `gh` auth (or without
`gh`), the script still compresses, hashes and writes the manifest, then prints
the exact `gh release create` / `gh release upload` commands and exits 0. In CI,
pass `--require-upload` to make that a failure. Placeholders:

- `GH_TOKEN=<token>` (or `gh auth login`) — a token with `repo` scope.
- `JAWNOS_DESKTOP_REPO=OWNER/NAME` — default `jonathanferwerda/jawnos`.
- `JAWNOS_DESKTOP_TAG=TAG` — default `desktop`.

## Keeping the download small

The build already drops generated firmware trees that nothing on a running
system reads: `jt/.pio`, `jt/build`, `jw/.pio`, `jw/build` and
`jp/alarmclock/.pio` (about 540 MB in the tree, copied to the state partition
too). The alarmclock's hardwired OTA path `jp/alarmclock/build` is deliberately
kept. The post-install step also removes `/root/.cpanm`, the CPAN build cache,
which was ~214 MB in every image. Together that is roughly 750 MB off the root
filesystem and off the state partition firstboot fills.

Deliberately **not** removed: `base-devel` (the post-install step needs it to
build CPAN modules, and a read-only overlay cannot install packages at runtime),
`linux-firmware` (needed for real Wi-Fi/GPU/audio hardware), and the
`voices/` models (the assistant uses them).

## The parts still unverified

Recorded honestly:

- The image builds and boots in QEMU (mkosi 27, OVMF), and first boot seeds the
  house. A boot from a real USB stick has not been tried.
- The install path was exercised end to end on **loop devices** in a sandbox:
  a 32G target was repartitioned to 1G/5G/26G, the ESP and root were copied,
  the house was rsynced, the theme row landed, and the live flag was dropped.
  A real USB install is still the missing proof.
- `jawnos-grow` (partition growth + online `resize2fs`) was proven on a mounted
  loop-device state partition; the boot service itself has not been boot-tested.
  systemd-repart logs "GrowFileSystem=yes … not supported" for the generic state
  partition, which is why the explicit `resize2fs` is there.
- QEMU `--runtime-size` grows the disk image, but in mkosi 27 it does not grow
  the partitions; the in-guest `jawnos-grow` service is what makes the space
  usable. A `--vm --disk-size 32` boot has not been re-run since the service was
  added.
- The A/B root, dm-verity and systemd-sysupdate update path is still roadmap,
  not code.
- The image seeds the tree **without `.git`**, so code sync is off until the
  installed disk joins a checkout (`git init` + a remote, or clone fresh). The
  live stick is for seeing JawnOS, not for being the authority.
- `config.json` and the database are seeded at first boot from the image's
  defaults (`config.default.json`); the code is a demo convenience written to
  `~/UNLOCK-CODE.txt` and should be replaced on a machine you keep.
- The theme is proven through the installer and the helper, not through a real
  first boot of `jawnos-theme-apply.service`.

## Debian, second

Add `mkosi.profiles/debian.conf` with `Distribution=debian` and
`Release=stable`, and translate the package list — Arch names do not carry over
(`webkit2gtk-4.1`, `pipewire`, `bluez` are close; `intel-media-driver`,
`libva-utils`, `gst-plugins-*` and `python-gobject` are not). Build it with
`--profile debian`; keep the profile separate rather than branching `mkosi.conf`,
so an Arch build cannot be broken by a Debian change.

`--output-dir` is per build, so two backends can sit side by side.

## Not Yocto

Yocto is for a sealed Linux appliance with a fixed board and a support window,
not for a desktop image. It is recorded in `docs/roadmap-handoff.md` and stays
out of this tree until that product exists.
