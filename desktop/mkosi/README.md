# JawnOS as an image (mkosi)

One artefact that is both the **try-it live USB** and the **installer**. Boot it,
use JawnOS, and run `jawnos-install /dev/sdX` to keep it. Nothing on the stick is
a commitment until that command runs.

Arch is the first backend. Debian is the second (see the end).

## Build

`mkosi` is **not installed on this machine yet**, so nothing here has been built
or booted. Install it on the build box first:

```sh
pip install mkosi                 # or: sudo pacman -S mkosi
```

Then:

```sh
perl scripts/mkosi_build.pl --dry-run     # stage the tree, print the command
perl scripts/mkosi_build.pl               # build desktop/mkosi/output/jawnos-live.raw
```

The build needs root (mkosi uses a container/chroot), network access to the Arch
mirrors, and a few GB of room. `--stage-only` stages without touching mkosi.

Write it to a stick:

```sh
sudo dd if=desktop/mkosi/output/jawnos-live.raw of=/dev/sdX bs=16M status=progress conv=fsync
```

## What the image is

| Partition | Label | Holds |
| --- | --- | --- |
| 1 | `jawnos-esp` | kernel, initramfs, systemd-boot |
| 2 | `jawnos-root` | the system, read-only at boot |
| 3 | `jawnos-state` | `/home/jawn`: the checkout, `config.json`, the database |

The kernel command line is `systemd.volatile=overlay`: **the root is read-only
and every change to it lives in RAM until reboot.** The house lives on partition
3, so the settings, data and sealed vault you make while trying the stick are
still there after a reboot. That is the "live with persistence" part.

On first boot `jawnos-firstboot` copies `/opt/jawnos/tree` and
`/opt/jawnos/home-skel` onto the state partition, then hands it to `jawn`. A
second boot finds the checkout and does nothing.

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

Recorded honestly, because none of this has run yet:

- `mkosi` itself is untested on this tree. The package list, the repart layout
  and the profile syntax follow mkosi's documented shapes but have never been
  built here.
- `systemd.volatile=overlay` + a separately mounted `/home/jawn` is a standard
  pair, but the ordering (mount before firstboot, firstboot before getty) has not
  been watched on a real boot.
- The `dd`-then-`systemd-repart --size=auto` growth path is the least certain
  step; a fallback is to `parted`/`growpart` the root and `resize2fs` it.
- The image seeds the tree **without `.git`**, so code sync is off until the
  installed disk joins a checkout (`git init` + a remote, or clone fresh). The
  live stick is for seeing JawnOS, not for being the authority.
- `config.json` is seeded from `config.json.example` when present; the first-run
  wizard may still ask for the things an example cannot know.

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
