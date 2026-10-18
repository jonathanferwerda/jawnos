# Prototype appliance — HP ProDesk 600 G3 (i5-6500T)

A runbook for turning one SFF box into a JawnOS **house**: Debian minimal, the
house seeded from the factory template, a systemd service, and an LXC layout for
clubs/communities. This is the reference build for the first appliance SKU.

The box is a separate machine from the development laptop; run this on the
ProDesk, not in the checkout you are developing in.

## 1. Hardware

- **CPU** — i5-6500T (4C/4T, 35 W). Enough for one house plus a few club
  containers; cap builds at `-j4` and give each container 1–2 vCPUs.
- **RAM** — 16 GB recommended (2 × 8 GB DDR4). Check the DIMM slots before
  buying 32 GB modules.
- **Storage** — NVMe SSD for the OS, database and app; a second 2.5" SSD for
  archives/backups if the bay is free. Do not run the live database on a
  spinning disk.
- **Network** — wired Ethernet (Intel I219-LM). Wi-Fi is unnecessary; use mDNS
  for the `.local` name.
- **TPM** — enable TPM 2.0 in the BIOS if you want LUKS auto-unlock. AES-NI is
  present; disk encryption is cheap.
- **Bluetooth** — optional. The ProDesk usually has none; a USB BLE dongle plus
  `jawnos-bt-daemon` is only needed for the watch/deck bridge. The embedded
  devices normally arrive over Wi-Fi/mDNS.
- **Power** — 35 W CPU, one SSD, idle is roughly 15–25 W; a small UPS is worth
  more than a bigger CPU.

## 2. BIOS (F10 at boot)

- **After Power Loss** = Power On (so the house returns after an outage).
- **Wake on LAN** = on (for remote wake).
- **Virtualization** = VT-x and VT-d on (containers do not need it, VMs do).
- **Intel AMT / vPro** = off unless you use it.
- **Secure Boot** — leave on if you install a signed Debian kernel; otherwise
  disable it for the install and decide later.
- **Fan profile** = quiet/balanced; clean the dust while the lid is off.
- **BIOS password** and a boot order that prefers the internal SSD.
- Record the serial number and MAC; they go in the asset sheet.

## 3. Debian minimal

Install **Debian 13 (trixie) netinst**, no desktop, SSH server, standard system
utilities. Ubuntu Server LTS also works; the dependency script supports both.
Manjaro is not ideal for an appliance (rolling release).

- Hostname: `jawn-house`.
- User: `jawn`, in `sudo`.
- Disk: ext4 is fine for the prototype. LVM-thin or btrfs give LXC snapshots;
  choose one if you want container rollback from day one.
- Swap: 4 GB (or zram).
- Static IP or a DHCP reservation. Do not rely on a changing address for
  tickets.
- SSH: key-only, no root login, no password auth.

## 4. Base host

```sh
sudo apt update
sudo apt install -y git curl ca-certificates avahi-daemon chrony \
    ufw smartmontools lm-sensors unattended-upgrades
sudo systemctl enable --now avahi-daemon chrony
sudo timedatectl set-ntp true
```

Time sync matters: the sync engine resolves conflicts by `server_time`, so a
drifting clock causes false conflicts.

Firewall (adjust the LAN range):

```sh
sudo ufw allow from 192.168.0.0/16 to any port 22 proto tcp
sudo ufw allow from 192.168.0.0/16 to any port 3000 proto tcp
sudo ufw allow from 192.168.0.0/16 to any port 3001 proto tcp
sudo ufw enable
```

The app uses a PTY and a set of internal ports (`PORT_AHOY`, `PORT_MSG`,
`PORT_BELL`, `PORT_ARM`, `PORT_BESTOW`, `PORT_DOCK`, `PORT_COMS`). On a single
house they are local; open the web/websocket ports you actually serve to the
LAN. If you later put clubs in containers with their own LAN addresses, each
container gets the same ports on a different IP.

## 5. Install JawnOS

```sh
sudo adduser --disabled-password --gecos "" jawn
sudo usermod -aG sudo jawn
sudo -iu jawn
git clone https://github.com/jonathanferwerda/jawnos.git ~/jawnos
cd ~/jawnos
perl scripts/jawnos_deps.pl --report
perl scripts/jawnos_deps.pl --install
```

The dependency script uses `sudo` for distro packages and CPAN modules, and
installs optional apps (Piper) under `~/.local`. Resolve anything `--report`
still lists before going on.

## 6. First boot / seed

The appliance path is the non-interactive seed: it writes `config.json` and
builds the database from `database/initial.enc`, keeping only the rows for the
machine's device kind.

```sh
cd ~/jawnos
mkdir -p ~/archive
JAWNOS_NAME="House" \
JAWNOS_EMAIL="me@example.com" \
JAWNOS_DOMAIN="jawn-house.local" \
JAWNOS_DEVICE=server \
JAWNOS_ARCHIVE_DIR="$HOME/archive" \
perl scripts/jawnos_setup.pl --seed --code 123456
```

Use a real unlock code, not the example. The script prints it; store it in the
asset sheet and a password manager. `JAWNOS_DOMAIN` is what
`scripts/app_ticket.pl` puts in the ticket URL — set it to the name clients
will actually resolve. A bare `./jawn` on a box with no `config.json` would run
the same seed automatically, but provisioning it explicitly first keeps the
systemd service from starting mid-setup.

## 7. Service

```sh
cd ~/jawnos
./desktop/install.sh --headless
# it prints the unit path; install it as root:
sudo install -m 0644 /tmp/jawnos-server.service /etc/systemd/system/jawnos.service
sudo systemctl daemon-reload
sudo systemctl enable --now jawnos
```

Run the installer as `jawn` (not root) so `jawnosctl` lands in
`~/.local/bin`; install the unit as root. Stop any `./jawn` running in a tmux
pane first, or the ports fight.

```sh
jawnosctl status
jawnosctl log -n 100
systemctl status jawnos
```

## 8. Ticket

```sh
cd ~/jawnos
perl scripts/app_ticket.pl desktop
perl scripts/app_ticket.pl phone --save
```

The ticket is a real credential. `--save` writes it to `.shots/ticket.txt`
(0600). The URL host comes from `config.json`; if it is a `.local` name, the
client needs mDNS. The app serves a self-signed certificate — fine for a
prototype (click through), but for a product install a local CA (step-ca or
mkcert) or terminate TLS at a reverse proxy, and put that CA on the clients.

## 9. LXC layout

The host can be the first house, or stay minimal and run every house in a
container. For the prototype: host = `server` house; clubs/communities get
containers.

```sh
sudo apt install -y lxc lxc-templates bridge-utils uidmap
sudo lxc-create -t download -n club1 -- -d debian -r bookworm -a amd64
```

Networking: a LAN bridge with one address per container is simplest for
tickets and clients. NAT plus port-forwarding is painful because each house has
several ports.

```sh
# host, /etc/network/interfaces (NIC name from `ip link`)
auto br0
iface br0 inet static
    address 192.168.2.50/24
    gateway 192.168.2.1
    bridge_ports enp0s31f6
    bridge_stp off
    bridge_fd 0
```

Container config:

```
lxc.net.0.type = veth
lxc.net.0.link = br0
lxc.net.0.flags = up
lxc.net.0.ipv4.address = 192.168.2.51/24
lxc.net.0.ipv4.gateway = 192.168.2.1

lxc.cgroup2.memory.max = 3G
lxc.cgroup2.cpuset.cpus = 0-1
lxc.cgroup2.pids.max = 4096
```

Inside the container, repeat sections 4–7 with `JAWNOS_DEVICE=server`, its own
domain/IP and its own unlock code. **Seed fresh; do not clone a configured
house.** If you clone a template container, delete `config.json`, the database,
`~/.house.key`, `~/.jawnos_signatorial_id` and `~/.president` before seeding —
two houses with the same signatorial will fight on the mesh.

## 10. Backups, UPS, monitoring

- **App backups** — point `archive_dir` at the second SSD; the `backups` timer
  writes sealed backups under `database/backups`. Verify one restores with
  `scripts/sealed_selftest.pl` / `scripts/records_recover.pl`.
- **Host backups** — `restic` or `borg` to an external disk/NAS:
  `~/jawnos/database`, `~/.house.key`, `~/.jawnos_signatorial_id`,
  `~/.president`, `/etc` (network, LXC), and container rootfs. Encrypt and
  test a restore.
- **SQLite** — never copy a live WAL database with `cp`; use the app's backup
  path or `sqlite3 ... ".backup"`.
- **UPS** — `nut` with a USB-HID UPS; graceful shutdown on low battery; BIOS
  Power On after AC loss. A sudden loss can corrupt the live DB.
- **Monitoring** — `jawnosctl status`, `https://<domain>/manager/health`,
  `journalctl -u jawnos -f`, `smartctl -a`, `sensors`, `df -h`. A cron ping to
  a healthcheck service is enough for a prototype.

## 11. Updates

- **OS** — `unattended-upgrades` for security only; reboot in a window.
- **App** — take a DB backup first; stage the new tag in a container, then
  `git fetch && git checkout <tag>`, `perl scripts/jawnos_deps.pl --extras-only
  --install`, and `printf restart > ~/.president/status` (or
  `jawnosctl restart`). Verify `jawnosctl status` and a login. The tree can pull
  itself; for an appliance, point it at a release branch or leave the watcher
  off so updates are deliberate.

## 12. Acceptance tests

1. Cold boot → `jawnosctl status` reports running.
2. Ticket login from a laptop and a phone.
3. Create a fixture appointment; confirm it syncs both ways.
4. Restart the service; state survives.
5. Pull the power (with the UPS bypassed); boot and confirm the DB opens.
6. Restore a backup into a scratch home; confirm the data.
7. Update to a new tag; confirm a ticket still logs in.
8. 72-hour soak: logs clean, disk flat, memory stable.
9. `perl scripts/records_audit.pl`, `perl scripts/sealed_selftest.pl`.
10. Measure idle power and record it in the asset sheet.

## 13. Factory / clone hygiene

Each house needs its own:

- `~/.jawnos_signatorial_id` (machine identity),
- `~/.house.key` and the sealed database,
- `config.json` (domain, device, port),
- unlock code.

Never image a configured house to a new unit. Image the **OS + repo + factory
seed**, then run `jawnos_setup.pl --seed` on first boot (or have a first-boot
unit do it when `config.json` is absent). That is the difference between an
appliance and a copy.
