# JawnOS as a Sway shell

A starting point for the kiosk-style setup: **Sway** owns the windows, **JawnOS is
the session** (its embedded view fills the screen), and a taskbar lists the apps
you launch — Zed included. Read `desktop/README.md` first; this builds on it.

> These files are a **starting point, not a verified configuration**. They have
> not been run on a Sway box. The app ids in `sway.conf` (`jawnos-desktop`,
> `zed`, `foot`) come from the programs' own names — check yours with
> `swaymsg -t get_tree` and adjust.

## Why Sway, and what it does and does not give you

The browser gives you windows, a taskbar and a top navbar — but only for things
*inside the page*. A native app like Zed is a **separate Wayland surface**, and
only the **compositor** can position, layer or drag a surface. So the fastest
route is to let a real compositor be the window manager and keep JawnOS as the
fullscreen "desktop":

| You wanted | How it is met here |
|---|---|
| Zed appears in a taskbar | `waybar`'s `wlr/taskbar` module lists every toplevel |
| a top navbar **over** Zed's window | `waybar` sits in the layer-shell `top` layer, above normal windows |
| drag Zed around the desktop | `for_window … floating enable` — Sway drags floating windows |

That is waybar's bar, not JawnOS's DOM one. **Making it JawnOS's** is the next
step (see below); it is a small local app, not a change to the web UI.

## The machine: HP ProDesk/EliteDesk G3, i5-6500T

Skylake, Intel **HD Graphics 530** (Gen9) — fully supported:

- **Vulkan**: `mesa` + `vulkan-intel` (the ANV driver). Zed's GPU renderer uses it.
- **VA-API** (hardware video): `intel-media-driver` (iHD) + `libva-utils` for `vainfo`.
- Sway/wlroots: fine. Zed: fine for editing (it is a 2D text UI, not a game).

Notes for that box: install `intel-media-driver`, not `libva-intel-driver` (iHD is
the modern one for Gen9). It is a 35 W T-series, so skip `ollama` on it — no
usable GPU for inference. If it is the Mini, confirm UEFI boot and that Secure
Boot is off (or sign the kernel) before installing.

## Packages (minimal Arch)

```sh
# graphics
sudo pacman -S mesa vulkan-intel intel-media-driver libva-utils

# the session
sudo pacman -S sway swaybg swayidle swaylock waybar \
  foot fuzzel mako wl-clipboard grim slurp \
  xdg-desktop-portal-wlr polkit-gnome wireplumber pipewire

# JawnOS's own deps (server + the desktop app's view and media)
sudo pacman -S python-gobject python-dbus webkit2gtk-4.1 bluez bluez-utils
# then:  perl scripts/jawnos_deps.pl --desktop

# the editor
sudo pacman -S zed
```

## The files here

| File | Goes to | What it does |
|---|---|---|
| `sway.conf` | `~/.config/sway/config` | floats Zed/foot, fullscreens JawnOS, keybinds, starts the session |
| `waybar.conf` | anywhere (`waybar -c …`) | a top bar with a **taskbar** (`wlr/taskbar`) and a clock |
| `jawnos-session` | run from `sway.conf`'s `exec` | starts jawn (and the BLE bridge), waits for the port, then opens the fullscreen view |

Adjust the `~/jawnos` paths in `sway.conf` to wherever the tree lives on the box.

Log in and start Sway:

```sh
sway -c ~/.config/sway/config
# or from a TTY:  exec sway   (with ~/.config/sway/config in place)
```

For a true kiosk (no TTY, auto-login into Sway), add `greetd` with an
auto-login `sway` session — but get the session working first.

## Getting it onto the box (bootable USB)

Two routes; both use everything above.

### A. Install to disk, then bootstrap (recommended)

JawnOS keeps state — a `config.json` and an encrypted SQLite database — so a
read-only live system forgets it all on reboot. For a real test box, install:

1. Write the **stock Arch ISO** to a USB and boot it (UEFI; Secure Boot off):

   ```sh
   sudo dd if=archlinux-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. Install Arch to the disk (`archinstall`, or the manual guide). No desktop
   profile needed — this repo provides the session.
3. Reboot, log in, get this repo onto the box, then:

   ```sh
   ./desktop/wayland/bootstrap.sh
   ```

4. `./jawn` once to create the config + database (the first-run wizard), then
   `exec sway`.

`bootstrap.sh` installs the graphics/session packages, the app's and server's
deps, Zed, the app itself, and the sway/waybar config. It touches nothing about
the disk layout, the bootloader, or auto-login.

### B. A custom live ISO (archiso)

To boot straight from the flash drive, build an archiso profile. Do **not**
write one from scratch — start from the releng profile archiso ships and add to
it:

```sh
sudo pacman -S archiso
cp -r /usr/share/archiso/configs/releng ~/jawnos-iso
# 1. append the packages listed under "Packages" above to packages.x86_64
# 2. copy an overlay into airootfs/: this repo's sway/waybar configs and the
#    session script, plus a ~/.bash_profile that execs sway on tty1
# 3. autologin: airootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf
sudo mkarchiso -v -w ~/jawnos-work -o ~/out ~/jawnos-iso
```

Caveats specific to JawnOS:

- The live root is a **read-only squashfs with a RAM overlay**, so jawn's
  database is lost on reboot. Add a partition labelled **`persistent`** on the
  USB for a surviving overlay, or bake a `config.json` + database into
  `airootfs/`.
- With no baked-in config, the first run still needs the setup wizard — so a
  live ISO is best for a **demo of the shell**, not a daily driver.
- Size: WebKitGTK + GStreamer + Zed put it around **2–4 GB**.

### Either way

- **Secure Boot off** (or sign the kernel), UEFI boot, and confirm the NIC works
  before relying on a network install.
- Write the USB with `dd` (above) or balenaEtcher.
- On that HP, install `intel-media-driver` (iHD), not `libva-intel-driver`.

## What is still open

1. **JawnOS's own bar.** Replace waybar with a thin **layer-shell** surface that
   renders JawnOS's chrome (a transparent webview pinned to the `top` layer, with
   `wl_surface.set_input_region` so clicks pass through the gaps). That is what
   makes the navbar *JawnOS's* and puts it over Zed.
2. **JawnOS's DOM taskbar for native apps.** A small helper subscribes to
   `zwlr_foreign_toplevel_management` (the client list, titles, activation) and
   relays it to JawnOS over a websocket, so the HTML taskbar can render Zed and
   activate it. This is the piece that turns "JawnOS + a window manager" into
   "JawnOS as the desktop environment".
3. **Input injection** (the teletype): on Wayland, `xdotool` is out — see the
   "teletype input injection and Wayland" notes; install `dotool` (AUR) or
   `wtype` on this box.

Two protocols to remember: `wlr-layer-shell` and `zwlr-foreign-toplevel-management`
are **wlroots** extensions — Sway, Hyprland and labwc expose them; **GNOME and
KDE do not**. Picking Sway commits you to that family, which is exactly what
makes this approach work.
