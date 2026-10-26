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
sudo perl scripts/mkosi_build.pl --vm          # build, then boot it in QEMU
```

The build needs root (mkosi uses a container/chroot), network access to the Arch
mirrors and to CPAN, and a few GB of room. `--stage-only` stages without
touching mkosi.

> **Built and booted on 2026-10-26.** The Arch image builds under mkosi 27 and
> boots in QEMU to a login prompt; the first boot seeds `config.json`, the
> database and the unlock code as described below. The installer, the A/B
> update path and a real USB boot are still unverified.

## Try it in a VM

```sh
sudo perl scripts/mkosi_build.pl --vm
```

mkosi boots the finished disk with QEMU and an OVMF firmware. The first boot
seeds `config.json` from [`config.default.json`](config.default.json), builds a
fresh encrypted database, creates the standard desktop folders, paints a
JawnOS wallpaper, and writes a generated unlock code to `~/UNLOCK-CODE.txt`.

The live desktop **opens the manager directly**: while `config.json` carries
`"live": true`, the manager trusts the machine's own loopback, so the view is
the house rather than the gate. The intro is deliberate, not a blank install:
the **Cutefish** theme (Teal, pastel icons, soft material), a ten-item
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

Write it to a stick:

```sh
sudo dd if=desktop/mkosi/output/jawnos-live_0.1.raw of=/dev/sdX bs=16M status=progress conv=fsync
```

## What the image is

| Partition | Label | Holds |
| --- | --- | --- |
| 1 | `jawnos-esp` | one unified kernel image at `EFI/BOOT/BOOTX64.EFI` (kernel, initrd, command line) |
| 2 | `jawnos-root` | the system, read-only at boot |
| 3 | `jawnos-state` | `/home/jawn`: the checkout, `config.json`, the database |

The kernel command line is `systemd.volatile=overlay`: **the root is read-only
and every change to it lives in RAM until reboot.** The house lives on partition
3, so the settings, data and sealed vault you make while trying the stick are
still there after a reboot. That is the "live with persistence" part.

On first boot `jawnos-firstboot` copies `/opt/jawnos/tree` and
`/opt/jawnos/home-skel` onto the state partition, then runs
`scripts/jawnos_setup.pl --seed` as `jawn` to write `config.json` and the
machine's database from the factory seed. A second boot finds `~/.seeded` and
does nothing; a first boot that failed is retried.

## Install to disk

```sh
jawnos-install            # prints the plan, writes nothing
sudo jawnos-install --yes /dev/sdX
```

It copies the running image byte for byte (so the ESP and bootloader travel with
it), grows the partitions to fill the disk, and copies `/home/jawn` onto the new
disk's `jawnos-state`. What you changed on the stick is what you keep.

The installer refuses to write to the stick it is running from, and needs
`--yes` before it touches anything.

## The parts still unverified

Recorded honestly:

- The image builds and boots in QEMU (mkosi 27, OVMF), and first boot seeds the
  house. A boot from a real USB stick has not been tried.
- `systemd.volatile=overlay` + a separately mounted `/home/jawn` works; the boot
  log shows the state partition mounted before firstboot, and the house present
  on it afterwards.
- The `dd`-then-`systemd-repart --size=auto` growth path (the installer) is the
  least certain step; a fallback is to `parted`/`growpart` the root and
  `resize2fs` it. `jawnos-install` has not been run.
- The A/B root, dm-verity and systemd-sysupdate update path is still roadmap,
  not code.
- The image seeds the tree **without `.git`**, so code sync is off until the
  installed disk joins a checkout (`git init` + a remote, or clone fresh). The
  live stick is for seeing JawnOS, not for being the authority.
- `config.json` and the database are seeded at first boot from the image's
  defaults (`config.default.json`); the code is a demo convenience written to
  `~/UNLOCK-CODE.txt` and should be replaced on a machine you keep.

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
