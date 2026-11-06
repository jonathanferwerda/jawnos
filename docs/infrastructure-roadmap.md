# Infrastructure roadmap — dev box, tailnet and the cloud server

**Status:** in progress — the hub move is live on ks5. The 2026-11-03 re-pointing is rolling to
every device; what remains is the outside verification and cancelling the VPS at its renewal.
**Started:** 2026-11-02 · **Baseline measured** 2026-11-02 by logging into all four hosts.
**Related:** `AGENTS.md` (run/restart, the database-is-per-device rule, the mesh rules),
`docs/AGENTS-restart.md`, `docs/AGENTS-firmware.md`, `t/README.md` (what the suite touches)

The plan for taking the programming and test load off the laptop and onto a dedicated server, with
the tailnet control plane moving to that server too, and the VPS left as a quiet host for the
Elixir app. Compare `docs/migration-roadmap.md`, which is about the stack, not the metal.

---

## 1. Charter

> Move the work that needs cores to a box with cores; move the public names with it; leave the
> house's data and the LAN devices where they are.

What this buys, in order:

1. **A test suite that does not make the laptop unusable.** Eight forked Perl children pin two
   P-cores and spill eight threads of work onto E-cores; the editor is scheduled around them.
2. **A cloud server that is not at 90% of two cores.** Today it runs the tailnet control plane,
   the house's always-on JawnOS server, the public hub, DNS and a mail stack on 2 vCPU.
3. **One place to run builds** (Gradle, PlatformIO, the suite) with 64 GB and NVMe.
4. **The VPS retired** — one host instead of two, and one less thing to patch.

---

## 2. Verified baseline — 2026-11-02

Measured, not assumed. Re-measure before acting; this section goes stale.

### The house, as it is

| Host | What it is | What it runs |
|---|---|---|
| **laptop** | ASUS Vivobook X1504ZA, i5-1235U (2P+8E), 15.6 GB, Manjaro | the editor, the agents, its own JawnOS, **the LAN manager the devices talk to** |
| **table** | Manjaro, 4 cores, 7.6 GB, 239 GB root (74% used) | its own JawnOS, GTK desktop |
| **cloud** | OVH VPS, Debian 13, **2 vCPU, 3.7 GB, 40 GB** | DNS and mail; **its Headscale and JawnOS server are stopped** (state kept for rollback) |
| **ks5** | Kimsufi, Proxmox VE 9.2.25, **4c/8t, 64 GB, 2×450 GB NVMe** | the host + `tailscaled`; `dev` (100), `house` (101, the JawnOS server + hub) and `headscale` (102) on `vmbr1` |
| **tablet** | Android | tailnet client only |
| **phone** | Android | tailnet client — registered 2026-11-02, `100.64.0.9` |

Headscale lists `table`, `cloud`, `laptop`, `tablet`, `phone` and (since 2026-11-02) `ks5`.

### The laptop (the client)

- 15.6 GB RAM. 8 GB soldered plus one SODIMM, already at 8+8 — 16 GB is ASUS's ceiling for this
  model. **There is no RAM upgrade path.**
- At rest with Zed and a few agents: load 2.9 (1 min) / 5.8 (15 min), ~16% of the machine.
  Zed + `perlnavigator` + `gitstatusd` ≈ 0.9 core / 2.7 GB; Chromium + WebKit ≈ 0.8 core / 3.0 GB;
  the JawnOS server (34 `President.pl` processes) ≈ 0.2 core / 4.1 GB.
- Thermals: 65–68 °C package, fan 4700 RPM, trip point 100 °C. **No throttling observed.**
  `governor = performance`, turbo on, `energy_performance_preference = performance`, PL1 39 W,
  average clock 2.87 GHz at that load. The heat is a power-policy consequence, not a load one.
- The suite: 149 test files, ~12–20 s at 8 jobs. `t/README.md` is explicit that **nothing in `t/`
  writes to the live database, the repo, or a fixed port** — every test gets a temp sandbox.

### KS-5 — installed 2026-11-02 (reinstalled with ZFS root the same day)

Measured after the install and two reboot drills:

- Proxmox VE **9.2.25** (Debian 13, kernel 7.0.14-26-pve), hostname `ks5`.
- Intel Xeon E3-1270 v6: 4 cores / 8 threads; **64 GB** DDR4 ECC; 2 × 450 GB NVMe.
- Public **54.39.157.133** (gateway `.254`), tailnet **100.64.0.11**, SSH **8022**.
- **ZFS root**: `rpool` is a mirror of `nvme0n1p3` + `nvme1n1p3`, with `rpool/zd0` (80 GiB) on `/`
  and `root=ZFS=rpool/zd0`. A second mirror `data` uses the rest of both disks (~326 GiB) for
  `/var/lib/vz`. `/boot` (ext4) and `/boot/efi` (vfat) stay on md RAID1; swap is 2 × 1 GiB.
- ZFS ARC capped at **12 GB** (`/etc/modprobe.d/zfs.conf`); a baseline snapshot
  **`rpool/zd0@install-2026-11-02`** exists.
- The template created `data` with **`cachefile=none`**, so the first boot could not import it
  before `/var/lib/vz` mounted (systemd retried and succeeded ~12 s later). Fixed with
  `zpool set cachefile=/etc/zfs/zpool.cache data` and an initramfs rebuild; the mount now succeeds
  on the first try and `systemctl --failed` is clean.
- The `data` pool root also had **`mountpoint=none`**, so a container's ZFS subvol could not be
  mounted and `pct create` failed. `zfs set mountpoint=/data data` fixed it; `local-zfs` creates
  containers normally from there.
- The OVH template wrote **no `storage.cfg`**: `local` (dir on `/var/lib/vz`) was the only storage,
  so containers had no snapshot target. A **`local-zfs`** zfspool was added on `data` for
  `images,rootdir`; `local` keeps ISO/template/backup.
- Hardening in place: SSH keys only (`PasswordAuthentication no`, `PermitRootLogin
  prohibit-password`) on **8022** (22 closed), unattended upgrades on, `console=ttyS0` in the
  cmdline, and the PVE firewall enabled with `policy_in: ACCEPT` where **8006 accepts only
  `100.64.0.0/10`** and is dropped from the internet.
- **Headscale (P5)** runs in CT **102** (`10.20.0.30`), v0.29.5, with the VPS's state. DNAT
  forwards **443/tcp** and **3478/udp** to it; an OUTPUT rule is needed too, because the host's own
  traffic to its public IP does not traverse PREROUTING.
- **Host snapshots work** (`zfs snapshot rpool/zd0@…`), but a rollback needs rescue or the
  initramfs because `/` is mounted. Guest snapshots come from `local-zfs`.
- Unmanaged: **no IPMI/KVM console**, hardware replacement only, rescue mode as the fallback.

### The cloud server (`cloud`, `vps-7c120a57`)

- **Headscale moved to ks5 (P5); the VPS instance is stopped with its state intact for
  rollback.** `server_url: https://thejunderground.com`, `listen_addr: 0.0.0.0:443`, embedded DERP
  with `stun_listen_addr: 0.0.0.0:3478`, `automatically_add_embedded_derp_region: true`,
  `magic_dns: true`, `base_domain: jonathanferwerda.com`, prefixes `100.64.0.0/10` and
  `fd7a:115c:a1e0::/48`. The apex is the control plane and nothing else: `/manager` is **404**
  there, `/windows` is Headscale's own page. State is small and portable: `db.sqlite` (~86 KB)
  plus `noise_private.key`, `derp_server_private.key`, and the TLS pair.
- **TLS**: Let's Encrypt, `notAfter 2026-12-07`. The cert files are the source of truth
  (`tls_cert_path`/`tls_key_path` are set); the config also declares `HTTP-01` on `:http`.
  **Served from ks5 since P5; its renewal must move there too, or the name goes dark in
  December.**
- **The always-on JawnOS house server** (`jawnos.service`, `User=jawn`,
  `WorkingDirectory=/home/jawn/jawnos`, 1.1 GB) on **3000** (manager, ticket) and
  **45545 / 45546 / 45550** (the public hub and its websocket). `:45545` is what other houses dial
  (`Lan.pm`, `tunnel_hub_url`).
- **The exit node moved to ks5 (P4).** `cloud` no longer advertises one; the laptop is not
  pinned to any exit node by default.
- **dnsmasq on `:53`**, whose whole config is `addn-hosts` for `jawnferroda.com` — a local name
  resolver, **not** the public DNS. Public DNS is Cloudflare, so a move touches one A record.
- **A mail stack that is not a mail server.** See §5.3.
- SSH on 8022.
- **Load 1.83 / 0.88 / 0.66 on 2 vCPU.** PSI CPU `some avg10≈9.5`; sys time up to 48% and
  context switches in the thousands — **CPU/context-switch bound, not IO bound**. The top
  consumers are the JawnOS Perl processes, then `tailscaled` relaying exit-node traffic.

**Elixir is not running anywhere.** No `beam.smp`, no `elixir` process on any host.

---

## 3. Decisions

| # | Decision | State |
|---|---|---|
| D1 | **Proxmox VE** on the Kimsufi host, for snapshots and rollback on a box with no console | decided |
| D2 | Containers, not VMs, for the JawnOS instances — near-zero overhead, shares the kernel | decided |
| D3 | Networking: **host-level `tailscaled` + an advertised subnet route** for the containers | proposed (§7 P3) |
| D4 | The **exit node moves to the KS-5** (500 Mbit unmetered, not the control-plane host) | decided |
| D5 | **Headscale moves to the KS-5.** Chosen by the person 2026-11-02, replacing the earlier | decided |
| | "control plane stays on the VPS" plan. See the coupling cost below and the P5 mitigations. | |
| D6 | The laptop keeps `performance`; the fan noise is accepted in exchange for maximum clocks | decided by the person, 2026-11-02 |
| D7 | Any dev container gets a **fresh database** and stays **off the mesh** | decided — a rule |
| D8 | The house's always-on JawnOS server runs in its **own container**, separate from `dev` | decided |
| D9 | **The control plane gets its own name under the house wildcard** — | superseded — §4 |
| | `headscale.jonathanferwerda.com` — not a bare IP and not the apex. The hub is `hub.` under | |
| | the same wildcard. | |
| D10 | **64 GB of RAM, because it is the only configuration offered in Beauharnois.** 32 GB was the | decided |
| | preference on the measurements; the forced 64 GB buys page cache and headroom, not waste. | |
| D11 | **The VPS is retired** once the migration proves out. It is paid to the next renewal, which | decided |
| | is the migration window; off-box, rehearsed backups replace it as the insurance. | |

**The cost of D5, stated plainly:** the tailnet's control plane now lives on the box that gets
snapshotted, rebuilt and rebooting. Mitigations, all in P5:

- Headscale runs on the **host** or in its own dedicated container — never in `dev`.
- A `dev` restart is a container restart, not a host reboot. Host reboots are a scheduled event.
- Existing tunnels survive a coordination outage (WireGuard keys and DERP paths are established);
  what breaks is new node joins, route changes and DNS refreshes.
- **Do not leave the laptop pinned to the KS-5 exit node by default.** If the KS-5 is down, a
  pinned laptop has no internet. Use the exit node deliberately; the VPS no longer offers one (P4).

D1 is not a performance argument. Proxmox costs about 0.5–1% of a core and ~1 GB RAM on the KS-5;
its value is the snapshot you take before a network change on a machine you cannot walk over to,
and the second container that D8 needs. The "Proxmox is a drain" reputation is ZFS's default ARC
(50% of RAM — 32 GB here) and oversubscribing small machines.

**On ks5 the D1 promise holds**: root is `rpool/zd0`, so `zfs snapshot rpool/zd0@before-change`
exists (a baseline is already taken). A rollback still needs rescue or the initramfs, because `/`
is mounted; guest snapshots live on `local-zfs` (`data`).

---

## 4. Target topology and naming

- **KS-5** — cores, RAM and bandwidth, and the tailnet's names:
  - the **host** — `tailscaled`, the exit node, Proxmox;
  - **Headscale** — own container (or host service) at `headscale.jonathanferwerda.com`,
    `:443` and DERP on `3478/udp`;
  - **`house`** — the always-on JawnOS server and public hub at `hub.jonathanferwerda.com`
    (`3000`, `45545`–`45550`);
  - **`dev`** — Zed remote, the suite, PlatformIO and Gradle builds.
- **VPS (`cloud`)** — retired after the migration (D11). Elixir becomes a container on the KS-5
  when it exists (P7); `thejunderground.com` then either points at the KS-5 or lapses.
- **laptop / table / tablet** — clients, *and* the **LAN manager for the embedded devices**
  (§5). This does not move.

### Names and certificates

Two certificates already exist, and they already split along this line:

| Cert | Covers | Renewed by | Expires |
|---|---|---|---|
| `*.jonathanferwerda.com` | any subdomain — the house manager and hub today | **`jawnos-tls.timer` on the `house` container** (`scripts/tls_issue.pl --renew`) | 2027-02-01 |
| `thejunderground.com` | apex + `www` | **certbot on ks5** (standalone `:80`, deploy hook into headscale) | 2027-02-01 |

So the tailnet does **not** need the apex, and it does **not** need a certificate of its own: point
Headscale's `tls_cert_path`/`tls_key_path` at copies of `server/fullchain.pem` and
`server/privkey.pem` from the `house` tree, and `headscale.jonathanferwerda.com` validates against
the wildcard. `thejunderground.com` is then free for the Elixir app, which moves to the KS-5 with
it (D11); the apex certificate retires with the VPS.

**Where the wildcard is renewed (answered 2026-11-02).** On the **laptop**, not on either server.
`certbot-renew.timer` with `authenticator = dns-godaddy` renews `*.jonathanferwerda.com` into
`/etc/letsencrypt/live/jonathanferwerda.com-0001/`. The pair each machine serves
(`server/fullchain.pem` + `server/privkey.pem`) is **deployed, not issued** — the VPS holds the same
file, but nothing there renews it. The app's own path is `scripts/tls_issue.pl`, and since 2026-11-02
it runs from a **weekly user timer on the laptop** (`jawnos-tls.timer`, §12).
So the KS-5 is not self-sufficient until one of these is true:

- it runs `perl scripts/tls_issue.pl --renew` on a **weekly timer** (it writes `server/` itself), or
- the laptop's renewal copies the pair across and restarts the listener.

The first is better: the DNS credentials live in the `dns` settings app, sealed with the house key,
so they **ride the mesh** to the `house` container — the off-mesh `dev` container never gets them.
Hard date: **2027-01-31** (the wildcard was reissued on 2026-11-02).

**Correction, 2026-11-06.** The wildcard now renews on the **`house` container** through its own
weekly system `jawnos-tls.timer` and a `tls_issue.pl` lineage under `~/.jawnos_tls` (reissued
2026-11-03, expires 2027-02-01). The laptop no longer holds it: both `/etc/letsencrypt` lineages were
deleted and `certbot-renew.timer` disabled. `dev` renews its **own** host certificate
(`dev.jonathanferwerda.com`, lineage `host-dev.jonathanferwerda.com`), and the laptop and table serve
a **house-CA leaf** (valid to 2029) instead of a copied public certificate. The wildcard private key
therefore exists on the `house` container only.

**D9 was not implementable (found during P5, 2026-11-02).** Headscale v0.29.5 refuses a
`server_url` that sits inside `base_domain` while MagicDNS is on — MagicDNS could shadow the
control plane. `base_domain` must stay `jonathanferwerda.com` because the house names
(`phone.`, `laptop.`, `table.jonathanferwerda.com`) are resolved by MagicDNS, so
`headscale.jonathanferwerda.com` cannot be the control URL. The cutover therefore **keeps
`https://thejunderground.com`**, which also means **no node is re-pointed**: the apex A record
moves to ks5 and the apex certificate moves with it. Consequences: the apex stays in use for the
control plane (Elixir takes a `thejunderground.com` subdomain at P7), the apex certificate is
renewed on ks5 (certbot standalone on :80, deploy hook installed), and the
`headscale.jonathanferwerda.com` A record (created, unused) can be removed.

### Why not the IP, and why not a nameserver

A bare IP is not an option. Tailscale clients validate the control URL's certificate against the
system roots and there is no insecure switch; Let's Encrypt issues certificates for **names** (a
wildcard by DNS-01, and only short-lived IP certificates at the very edge of what it offers).
`https://<ip>` would fail verification.

The good news: none of this needs a nameserver on the box, or port 80. **DNS-01 writes a TXT
record through the provider's API** — exactly what `tls_issue.pl` already does for the house
wildcard. So:

- The public zones are split: **`jonathanferwerda.com` is GoDaddy** (the wildcard's DNS-01
  credential) and **`thejunderground.com` is Cloudflare** (the apex record). Nothing is delegated
  to the KS-5.
- One A record per name (`headscale`, `hub`) → the KS-5's single IP.
- No inbound 80; only **443/tcp**, **3478/udp** and **41641/udp**.
- No failover IPs and no virtual MACs: one name on one address.

**The cost, stated plainly: changing the control URL touches every node.** Each client must run
`tailscale up --login-server https://headscale.jonathanferwerda.com` and may need re-registering.
Four devices, and the phone is off-tailnet today — do it while every device is in reach. The
alternative that avoids all of it is keeping `thejunderground.com` as the control URL and giving
Elixir a subdomain instead: cheaper now, uglier later.

---

## 5. Working with the embedded devices

The firmware is hardwired to a **LAN** manager, not to the public name:

- **alarmclock (Pico 2 W)** — `const char* host = "192.168.1.3";`
  (`jp/alarmclock/alarmclock_01_globals_clock_ble.ino:16`).
- **T-Deck (`jt`) and T-Watch (`jw`)** — probe `192.168.2.3:45547` at setup
  (`jt/jt_03_setup.ino`), and store the house's `{"ip":…,"arm":45547}` in their config.

So **a manager on the KS-5 cannot serve them**: they are on the house WiFi and cannot route to a
remote address. The LAN manager (today the laptop) stays where it is, and so does its address —
changing it means reflashing or BLE re-provisioning every device.

**USB flashing can happen from the table as well**, and that is fine: USB is a local act with no
manager involved. Two ways to do it, and the light one is usually right: install PlatformIO on the
table so `usb_upload` can build there, **or** flash the artifact that was copied over the tailnet
with `esptool`/`picotool` and skip the toolchain. Either way the device is plugged into the port,
not into the server.

Keep exactly **one** authoritative LAN manager for OTA (the address compiled into the firmware).
The table is a flashing host, not a second staging host — a second staging tree is how a device
gets yesterday's firmware from the other machine.

That decides the build workflow the person asked about: **compile on the KS-5, bring the artifact
back to the LAN, upload from there.** In order:

1. **Build on the KS-5** in `dev`: `pio run -j 4` in `jp/alarmclock`, `jt`, or `jw`. PlatformIO
   toolchains are heavy and bursty — exactly right for the server. Cache them in the container;
   the first build of each board pulls ~1–2 GB.
2. **Copy the artifact to the LAN machine the devices talk to** — `rsync` over the tailnet into the
   same repo path, not a scratch directory, because both OTA paths are repo-relative.
3. **Stage or upload on the LAN machine:**
   - **Pico 2 W (OTA)** — `perl scripts/stage_firmware.pl` on the laptop copies
     `.pio/build/pico2w/firmware.bin` to the hardwired
     `jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin`. An unstaged build means the
     OTA sends the **previous** firmware.
   - **ESP32 boards (T-Deck, T-Watch)** — the panel's `ota_uploader_wifi` hands over a `.bin` you
     pick, so put the copied build in that device's `.pio/build/<env>/` and pick it.
   - **USB** — must be local anyway; `usb_upload` builds over USB on the machine the device is
     plugged into (the laptop or the table, per the note above).
4. **Keep the build settings** with the source: the Pico 2 W's
   `board_build.filesystem_size = 2M` split is not optional (at 0 MB the image boots without
   `config.txt` and the device drops to its AP), and the LoRaWAN mode/credentials stay the
   `mail/lorawan_*` settings that Chat's LoRa section pushes.

A shortcut worth building once: a small `rsync` helper that pulls the three artifact directories
from `dev` into the laptop's tree, so "compile remotely, stage locally" is one command and never
half-copied.

---

## 6. The VPS mail stack is not a mail server

Verified, because it changes what P6 deletes:

- **No IMAP/SMTP server** listens there (no 143/993; 25 is loopback only). JawnOS speaks **IMAP
  and SMTP directly to the account's provider** (`Net::IMAP::Client`, OAuth2/XOAUTH2 for
  Gmail/Outlook) — the help text is explicit that Send goes over the account's own SMTP server.
- **exim4** is `dc_eximconfig_configtype='local'`, bound to `127.0.0.1`/`::1`, no relay, no
  smarthost: it delivers system mail (cron, service noise) and nothing else.
- **rspamd** and **valkey** have **no reference anywhere** in `perl/`, `lib/` or `scripts/`.
- **clamd** is the one real piece: the mail help says attachment scanning "follows to the machine
  that receives the mail, where clamd answers on demand and stops itself when idle" — which is
  exactly `clamd-idle-stop.service` on the VPS. The laptop has no clamav installed, so confirm
  which machine actually fetches the mail before removing it. If it is the house server, the
  on-demand clamd belongs in the `house` container.

So P6 deletes rspamd, valkey and (if nothing local-mails) exim4, keeps clamd **where the IMAP
fetch happens**, and returns roughly 0.5 GB plus some attack surface.

---

## 7. Phases

Nothing is deleted until its replacement answers. That ordering *is* the rollback plan.

### P0 — Power policy: no action

- [x] Decided: keep `governor = performance`, turbo on, PL1 39 W. The fan is accepted (D6).
- [ ] Do not re-litigate this. The sluggishness was contention, and P3 is what fixes it.

### P1 — Install the host — DONE 2026-11-02

- [x] Installed **Proxmox VE 9.2.25** from the OVH template. The first pass left the root on
      ext4/md; reinstalled the same day with **ZFS root**: `rpool/zd0` (80 GiB) on `/`, a second
      mirror `data` (~326 GiB) for `/var/lib/vz`, with `/boot` and `/boot/efi` still ext4/vfat on
      md RAID1.
- [x] **ARC capped** at 12 GB in `/etc/modprobe.d/zfs.conf`, set at runtime too.
- [x] Firewall **8006 off the internet** (PVE firewall: accept from `100.64.0.0/10`, drop the rest).
      SSH keys only on 8022; unattended upgrades enabled.
- [x] `console=ttyS0,115200n8` already on the kernel cmdline.
- [x] **Two reboot drills passed**: both pools import, `/var/lib/vz` mounts, the ARC cap,
      `tailscaled` and the firewall all return.
- [x] Baseline snapshot **`rpool/zd0@install-2026-11-02`**.
- **Exit:** host up, ARC capped, 8006 unreachable from outside, host and guest snapshots available,
      reboots survived.

### P2 — Join the tailnet (as a client, before anything moves) — DONE 2026-11-02

- [x] `tailscale up --login-server https://thejunderground.com --authkey … --hostname ks5
      --accept-dns=false` on the host. Outbound only; `accept-dns=false` keeps the host's own
      resolver, which the containers need.
- [x] The reinstall invalidated the old node, so Headscale ID 10 was deleted before rejoining.
      `headscale nodes list` shows `ks5` at **100.64.0.11**, online.
- **Exit:** the new node is in the tailnet. P3 is next.

### P3 — The containers — DONE 2026-11-02

- [x] `dev`: privileged LXC **100**, Debian 13, **8 cores / 40 GB + 8 GB swap, 256 GB** on
      `local-zfs` (resized after P3; it was 4/8/40), `10.20.0.10` on `vmbr1`. Repo cloned as `jawn`
      at `/home/jawn/jawnos`; no `releases/`, no mesh, no tunnels. It joined the tailnet at P8.
- [x] **Fresh database** from `database/schema.sql` (38 tables). Never a copy of the live
      `jawnos.db` — that is the cross-machine restore `AGENTS.md` documents (D7).
- [x] `house`: unprivileged LXC **101**, 2 cores / 2 GB, 20 GB, `10.20.0.20`; the app moves in at P6.
- [x] Reachability chose **(a)**: `vmbr1` is `10.20.0.1/24` with NAT to `vmbr0`, the host advertises
      `10.20.0.0/24`, Headscale node 11 approved it, and the laptop runs
      `tailscale set --accept-routes`. Both containers answer on the tailnet route.
- [x] Both containers run `sshd` on **8022**, keys only, as `jawn`. Debian 13 socket-activates SSH,
      so the port is moved in an `ssh.socket` drop-in — `Port` in `sshd_config` does nothing.
- [x] **Zed remote**: `ssh -p 8022 jawn@10.20.0.10` works from the laptop; the remote tree is
      `/home/jawn/jawnos`.
- [x] `perl scripts/run_tests.pl --jobs 6`: **162 files, green, 21.8 s** on the server.
- **Fresh-clone gaps found and fixed:** a fresh clone has no gitignored `config.json`, and the
      scripts the suite spawns read `./config.json` — `dev` got the minimal boot config the harness
      itself writes. `scripts/app_migrate.pl` used IPC::Open3's `['&', $fh]` form, which Debian 13's
      perl 5.40 rejects; `'>&HANDLE'` works on both (v0.1.1928). `t/89` asserted that the gitignored
      deep notes are truncated, so that assertion now skips on a clone without them (v0.1.1928).
- **Exit:** the suite is green on the server and the remote tree is reachable; confirming Zed itself
      edits it is the person's step.

### P8 — `dev` joins the tailnet, and key-only SSH everywhere — DONE 2026-11-03

`dev` was the one node that could not see the other devices: it sat behind the ks5 NAT with no
route into the house LAN, and it held none of the house SSH keys. Both are fixed.

- [x] **`/dev/net/tun` in CT 100.** The container had no TUN device, so `tailscaled` died with
      `CreateTUN("tailscale0") failed`. Added to `/etc/pve/lxc/100.conf`:
      `lxc.cgroup2.devices.allow: c 10:200 rwm` and
      `lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file 0 0`. Needs a container restart.
- [x] **Headscale reachable from `vmbr1`.** `headscale-dnat.service` only DNATs `-i vmbr0` (internet)
      plus a host-local `OUTPUT` rule, so a container's own traffic to `54.39.157.133:443` matched
      neither and got connection-refused. Added `-i vmbr1 -d 54.39.157.133` to the unit. **The `-d`
      matters:** the first cut omitted it and hijacked *every* container's outbound 443, so `dev`
      reached Headscale's certificate for every HTTPS host and could not reach the DERP relay.
- [x] **`--accept-routes=false` on `dev`.** With it on, `dev` learned `10.20.0.0/24 dev tailscale0`
      back from ks5 into table 52, which shadowed its own `eth0` route to its own bridge and made
      `10.20.0.10` unreachable. `dev` is **100.64.0.4**; use the tailnet address, not the bridge one.
- [x] **Key-only SSH on every host** — `table`, `cloud`, `laptop`, `ks5`, `dev`, `phone`, `tablet`.
      Installed as `/etc/ssh/sshd_config.d/99-no-password.conf` (Termux: the same file under
      `$PREFIX/etc/ssh/sshd_config.d/`). The `99-` prefix is load-bearing: `sshd_config`'s `Include`
      sits at line 12, so drop-ins apply *after* its own `PasswordAuthentication` line — on ks5,
      `50-cloud-init.conf` was silently re-enabling passwords.
- [x] **Two keys authorised everywhere:** `jawnos-agent` (the laptop) and `jawnos-dev`
      (`~/.ssh/id_ed25519_github` on `dev`). The laptop previously had **no** `authorized_keys` and
      could not log into itself.
- [x] **Android specifics.** Both boxes run Termux-adjacent `sshd` as **`u0_a369`**, not `jawn`, and
      are started by hand (no pidfile, no systemd), so the invocation must be reproducible:
      `-o AuthorizedKeysFile=<app>/files/home/.ssh/authorized_keys -o StrictModes=no`
      `-o SetEnv=HOME=<app>/files/home`. A restart that expands `$PREFIX` wrongly makes sshd read
      `<app>/files/usr/home/...` and reject every key — that locked the phone out once.
      `StrictModes=no` is required because Android's `/data/data` is `0771 system:system`.
- [x] **`.secrets/ssh.txt` corrected.** Phone LAN is `192.168.1.124` (not `.140`); `cloud` is `agent`;
      the phone and tablet are `u0_a369`; the file's `100.64.0.2 # phone` was `cloud`.
- **Known gap:** the **tablet is LAN-only.** It has no Tailscale client and no `tailscale0`
      interface, so its Headscale node 8 (`100.64.0.8`) is stale and `dev` cannot reach it — `dev`
      has no route into `192.168.1.0/24`. Reach the tablet from the laptop, or re-enrol it.
- **Known gap:** `dev` holds the gitignored `docs/AGENTS-notes.md` but none of the token files
      (`cloudflare.*`, `youtube.env`); only `jawnos-release.jks` was there already.
- **Exit:** the laptop and `dev` each key-login to every tailnet host plus `ks5`, and password auth
      is refused everywhere it was tested.

### P4 — Exit node — DONE 2026-11-02

- [x] ks5 advertises an exit node (`tailscale set --advertise-exit-node`) alongside `10.20.0.0/24`;
      Headscale approved `0.0.0.0/0`, `::/0` and the bridge on node 11.
- [x] Selected on the laptop deliberately: egress became **54.39.157.133** over a direct path to
      `ks5:41641`.
- [x] Un-pinned again (`tailscale set --exit-node=`) so a ks5 outage cannot cut the laptop's
      internet (D5/§9); the tailnet stayed direct.
- [x] The VPS no longer advertises (`AdvertiseRoutes: null`) and its approved routes are cleared, so
      `cloud` is not an exit node in Headscale either.
- **Exit:** ks5 offers the exit node and the bridge, the laptop uses neither by default, and the VPS
      is quiet.

### P5 — Move Headscale (the cutover) — DONE 2026-11-02

Headscale runs in **CT 102** (`10.20.0.30`) with the VPS's state, listening on 443 with the apex
certificate. **The control URL stays `https://thejunderground.com`** (§4: D9's name is rejected by
headscale while MagicDNS owns `jonathanferwerda.com`), so **no node was re-pointed** — the apex A
record moved instead.

- [x] Headscale **v0.29.5** in an unprivileged container, onboot, using the copied
      `/var/lib/headscale/` (db.sqlite, noise and DERP keys, TLS) and the VPS config.
- [x] DNAT on ks5: **443/tcp** and **3478/udp** → `10.20.0.30`, persisted by
      `headscale-dnat.service`; 41641/udp is the host's own `tailscaled`. An **OUTPUT** DNAT was
      also required, or the host cannot reach its own control plane by name.
- [x] The VPS instance is **stopped** and left intact (`/tmp/headscale-state.tgz` is the rollback);
      never start both — same keys, diverging databases.
- [x] `thejunderground.com` A → **54.39.157.133**, DNS-only, in Cloudflare. Clients kept the same
      URL; Table, cloud, laptop, phone and ks5 are back online. **The tablet reconnects when it
      wakes** (it was asleep before the cutover; no config change is needed).
- [x] **Apex certificate reissued on ks5** the same day: certbot standalone on `:80`, with
      `/usr/local/sbin/headscale-deploy-cert.sh` as the renewal hook. Served cert now expires
      **2027-02-01**; `certbot.timer` renews and the hook pushes the pair into the container.
- [x] Rollback: move the A record back and start the VPS instance; its `server_url` is unchanged.
- **Exit:** every node returns on the same URL, the apex answers from ks5, the VPS instance is
      disabled.

### P6 — Move the house server off the VPS, then retire it — IN PROGRESS 2026-11-02

- [x] The always-on app moved to **`house`** (CT 101, 4 GB): the VPS's Perl/library set, config,
      `server/` state and a checkpointed `jawnos.db` (306 MB) were copied. The VPS `jawnos.service`
      is **stopped**. The manager answers on 3000 and the hub listeners on 45545/45546/45550. The
      `devices` row keeps its uuid and the `vps-7c120a57` hostname (the same logical server).
- [x] The hub answers publicly at **`hub.jonathanferwerda.com`** (GoDaddy A → ks5; DNAT
      45545/45546/45550 → `10.20.0.20`). MagicDNS shadows names under `base_domain`, so a headscale
      **`extra_records`** entry resolves the hub to 54.39.157.133 for tailnet clients too.
- [x] **Corrected 2026-11-03 — the exit node needs the same DNAT.** The laptop runs ks5 as its
      exit node (`RouteAll`, `ExitNodeID=11`), so its packets to the hub's public address arrive on
      `tailscale0`, not `vmbr0`; the vmbr0 rules never saw them and the house's Go window stayed
      white. `headscale-dnat.service` now installs the 443/45545/45546/45550 DNATs on `tailscale0`
      too (after `tailscaled`), and the manager answers from the laptop on the public name again.
      A peer whose manager still ships the image's `CN=localhost` certificate (the phone, dev) is a
      separate certificate problem; the desktop app now trusts it only in a peer Manager window.
- [x] `tunnel_hub = https://hub.jonathanferwerda.com:45545` on the laptop and the table, both apps
      restarted.
- [x] **Corrected 2026-11-03 — the config alone did not form a tunnel.** The house's `config.json`
      still named itself `cloud` (`name`, `public_host`), so every client that re-enrolled learned
      the retired name; each client's `sync_hub` still pointed at the cloud signatorial, and
      `tunnels` / `remote_machine_sync` were switched **off** in its utility row. The laptop's
      `tunnel=yes` on the hub was a stale row, not a live data plane. Fixed: the house names itself
      `house` at `hub.jonathanferwerda.com`; a client re-enrolls the house, drops the cloud row,
      sets `sync_hub`, and switches the two utilities on. `tunnel_checker` now starts a tunnel for a
      configured `tunnel_hub` even when no NIC neighbour table lists the hub (it sits behind the
      subnet route), and the tunnel control rail is tier-exempt like its session gate, so a rostered
      peer carrying a resident cookie can reserve its ports. Tests: `t/124`, `t/15`.
- [x] **Wildcard renewal in the house works.** The moved GoDaddy credential was bad (`401`) and the
      laptop's credential is sealed with a different house key, so the working key was unsealed on
      the laptop and re-sealed under the house's own key in transit. The timer is enabled and the
      pair was reissued the same day: it now expires **2027-02-01**.
- [x] **Off-box backups started and drilled** (§11): ks5 stages nightly at 03:30; the laptop pulls
      at 04:15 by a user timer, the table at 04:15 by cron. Both databases pass `integrity_check`,
      and the certificate/key pair and the 115,378-row appointment table were verified from the
      copy. The restore steps are written in §11.
- [x] Re-pointed the laptop, table, and phone: each enrols the house, drops the cloud row, sets
      `sync_hub`, and switches `tunnels` / `remote_machine_sync` on. All three tunnels report seven
      listeners, and the hub lists every one as `tunnel=yes` with a loopback manager. The phone also
      gained `tunnel_hub`; it was never set there. The tablet is a tailnet client only and reconnects
      when it wakes.
- [ ] Verify from outside the house (phone on cellular) and cancel the VPS at renewal. The VPS
      node stays online in the tailnet until then: it is the rollback, and `cloud.jonathanferwerda.com`
      is MagicDNS's name for it (the JawnOS service there is stopped).
- **Exit:** the hub and the tailnet answer from ks5, the VPS is cancelled, and the restore has been
      rehearsed once.

### P7 — Elixir, when it exists

- [ ] Elixir has no home once the VPS goes: it becomes an `elixir` container on the KS-5, on its
      own name under the wildcard (e.g. `app.jonathanferwerda.com`), once P6 is stable. It must
      not share the `dev` container.
- [ ] If it later needs isolation, its own public IP, or more cores than the KS-5 can spare, that
      is the moment to buy a small VPS again — not before.
- **Exit:** Elixir serving its subdomain, the tailnet and the house untouched.

### Non-goals

- **Not moving the live `jawnos.db` between machines casually.** The database is per device; the
  house's own server moves once, deliberately, in P6, with the identity rules from `AGENTS.md`.
- **Not moving the LAN manager.** The embedded devices are hardwired to it (§5).
- **Not making the laptop a browser-only client** unless the Coding agent is meant to carry the
  whole loop. It can edit, compile, commit, push and restart, but it is one staged write with no
  LSP and no hand-editable diff; that is the wrong tool for multi-file refactors.

---

## 8. Open questions

1. **Which machine fetches IMAP today** — the laptop or the VPS's JawnOS? This places clamd (§6).
2. **Does the hub's public URL live in a setting on each house** (`tunnel_hub`), or is it learned
   from the handshake? This decides whether moving the hub is one change or one per house.
3. **Where is the Elixir app's load ceiling?** BEAM wants cores, and after D11 the KS-5 is its
   only home. If it outgrows the box, it gets its own VPS then — not a bigger box now.

---

## 9. Risk and rollback

- **Today's single point of failure** is `cloud`: control plane, house server and egress on one
  over-subscribed VPS. P4–P6 split those three apart, but D5 recombines two of them on the KS-5.
- **The one irreversible act** is a Headscale move done without a clean copy of
  `/var/lib/headscale/`. With it, a rollback is a DNS change and a service start; without it,
  every node re-registers.
- **The one easy own-goal** is a broken bridge or a closed 3478/udp on a host with no console.
  Snapshot first, keep the old SSH session open, and confirm the ports before repointing DNS.
- **The one dated risk** is the wildcard: it expires **2027-02-01**. The `house` container renews it
  itself through `jawnos-tls.timer` (in place since 2026-11-03); no other machine holds the key.
  **The apex pair was reissued on ks5 on 2026-11-02 and expires 2027-02-01**, renewed by
  `certbot.timer` there with the deploy hook; the VPS's HTTP-01 renewal is no longer used.
- **The open certificate risk** was the house's wildcard renewal: the moved GoDaddy credential
  returned `401` and the laptop's credential used a different house key. **Closed 2026-11-02** by
  re-sealing the working key under the house's key; the timer is enabled and the pair now expires
  **2027-02-01**.
- **The one thing that cannot be done** is pointing Tailscale at a bare IP: the client validates
  the control certificate and will not connect without a name.
- **The one rule that must not be bent** is D7. A copied database on a dev container looks like it
  works and then quietly poisons the mesh.
- **The one coupling to watch** is D5: reboot the host deliberately, and never leave the laptop
  pinned to an exit node that lives on it.

---

## 10. Cost

Chosen configuration: **KS-5 at 64 GB** (mandatory in this region) — **$38.58/month + $26.69
setup**, so year one is about **$490** plus one or two VPS months, ≈ **$508**.

Rejected: the SYS-1 — at equal memory it is the dearer machine, and the extra cores buy seconds on
a 20-second test run rather than availability. Numbers in §11.

Update `scripts/sponsors_goal.pl`'s VPS default when the bill changes, so the sponsor goal keeps
telling the truth.

---

## 11. The purchase decision (2026-11-02)

### KS-5 vs SYS-1

Catalogue prices, 2026-11-02:

| | KS-5 | SYS-1 |
|---|---|---|
| CPU | Xeon E3-1270 v6, 4c/8t, 3.8–4.2 GHz | Xeon E-2136, 6c/12t, 3.3–4.5 GHz |
| Memory | 64 GB (only option in this region) | 32–128 GB |
| Storage | 2×450 GB NVMe | 2×512 GB NVMe |
| Public bandwidth | 300–500 Mbps | 500 Mbps–1 Gbps |
| Monthly / setup | **$38.58 / $26.69** at 64 GB | $44.39 / $44.39 at 32 GB; ≈$56 / $44 at 64 GB |

**Rejected.** Six cores instead of four is +50% threads, and on the measured suite (149 files,
12–20 s at 8 jobs) that is roughly five to ten seconds — not worth ~$17.70/month at equal 64 GB
memory plus a higher setup fee. The problem that started this was tests competing with the editor;
the first four cores fix it.

If the box is ever genuinely saturated — tests queueing, Gradle crawling, load above the thread
count — move up then. The data is small and the migration is a rebuild, so there is no lock-in now.

### Does it need 64 GB?

No. The working set, from the VPS and laptop measurements:

| Component | Peak |
|---|---|
| Proxmox host | ~1 GB |
| `headscale` container | <0.2 GB |
| `house` container (34 Perl processes — the measured VPS stack) | ~2.1 GB |
| `dev` container — suite (forked, copy-on-write) + Gradle + PlatformIO | ~5–6 GB |
| ZFS ARC (a cache, capped) | 8 GB |
| Later: `elixir` container | ~1 GB |

Ballpark **15–18 GB at a hard peak**, on a box that never runs the editor or a browser. 32 GB would
leave more headroom than the laptop has in total — but **Beauharnois only sells 64 GB**, so the
decision is made for you: the forced 64 GB becomes page cache and headroom, not waste. It is not a
reason to look elsewhere; every alternative costs more at equal memory (§13).

### What replaces the VPS

The VPS is paid to its next renewal — that is the migration window, so use it and cancel (D11).
It was never much insurance once the control plane, the house server and the hub all move off it.
The real insurance is a **restore that has been rehearsed**.

### The backup as built (2026-11-02)

- **ks5 stages** `/var/backups/jawnos/` nightly at 03:30 (`jawnos-backup.timer` +
  `jawnos-backup.sh`): headscale `db.sqlite` (SQLite `.backup`, no service stop), its
  `config.yaml`, the noise/DERP/TLS keys; the house `jawnos.db`, `config.json` and `server/`; and
  the apex pair from `/etc/letsencrypt/live/thejunderground.com/`.
- **The laptop pulls** it at 04:15 into `~/jawnos-backups/ks5/` (`jawnos-backup-pull.timer`, a user
  unit). **The table pulls** it at 04:15 by cron into the same path.
- **Drill, run the same day:** both databases pass `pragma integrity_check`; the house certificate
  and private key produce the same public-key hash; the headscale keys tarball carries
  `noise_private.key`, `derp_server_private.key` and `tls/`; the house DB holds **115,378**
  appointments. A full boot from the copy was deliberately **not** done: a second instance with the
  same keys or identity is the one state that must not exist.
- **Restore:** stop the service. Headscale: copy `db.sqlite`, `keys.tgz` (noise, DERP, `tls/`) and
  `config.yaml` into `/var/lib/headscale`, chown `headscale`, start. House: copy `jawnos.db` into
  `database/`, extract `state.tgz` (`config.json` + `server/`) into the tree, chown `jawn`,
  start. Apex pair: replace `/etc/letsencrypt/live/thejunderground.com/` and let the deploy hook
  restart headscale. Verify with `curl https://thejunderground.com/health`,
  `headscale nodes list`, the house manager, and `tailscale status`.

---

## 12. Standalone task — the weekly certificate timer (do this today)

Does not wait for the hardware. §4 established that **nothing renews the certificate on the
machine that serves it**; this closes that hole, first on the laptop so it is proven before the
migration, then in the `house` container.

`scripts/tls_issue.pl --renew` is safe to schedule: it renews only when due, compares the installed
pair before and after, writes `server/fullchain.pem` + `privkey.pem` only if they changed, and
requests the restart through the app's own `~/.president/status` channel. No root is needed.

**On the laptop, as the user that owns the tree** (`jawn`):

```
~/.config/systemd/user/jawnos-tls.service
[Unit]
Description=JawnOS house certificate renewal (DNS-01)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/perl %h/jawnos/scripts/tls_issue.pl --renew
```

```
~/.config/systemd/user/jawnos-tls.timer
[Unit]
Description=Weekly JawnOS certificate check

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
```

```
systemctl --user daemon-reload
systemctl --user enable --now jawnos-tls.timer
systemctl --user list-timers jawnos-tls.timer
```

**Prove it now, without waiting for a week:** `perl scripts/tls_issue.pl --renew` answers
*"certificate for *.jonathanferwerda.com is current (nothing to install)"* when the app's own certbot
lineage already exists. **Outcome of the first run (2026-11-02):** there was no lineage under
`~/.jawnos_tls`, so the proof did the stronger thing and issued: the hook wrote and cleaned up
`_acme-challenge.jonathanferwerda.com`, a fresh wildcard was installed (expires 2027-01-31), and the
house was asked to restart. That run also found a real defect, now fixed: certbot 5.x validates a
manual hook's first whitespace-separated token as a literal path, so `tls_issue.pl`'s quoted
`'/usr/bin/perl'` was reported as not found and the renewal died before ACME. `tls::certbot_hook()`
now emits bare paths (quoted only for a path with a space, with `--disable-hook-validation` then).
If the proof fails instead, the DNS credentials under Configure → Plat → DNS are the thing to fix,
and that is exactly what would have surfaced in December otherwise.

Notes:

- A **user** timer runs only while that user has a session. On a laptop that is fine; in the
  `house` container use a **system** timer (same two files under `/etc/systemd/system/`, with
  `User=jawn` in the unit), or `loginctl enable-linger jawn` if it must stay a user timer.
- Verify later with `systemctl --user list-timers` and
  `journalctl --user -u jawnos-tls.service`; a renewal logs either *"installed a new certificate
  … restart requested"* or *"is current (nothing to install)"*.
- **Retired 2026-11-06:** the laptop's `certbot-renew.timer` is disabled and its two
  `/etc/letsencrypt` lineages deleted; only the `house` container issues this name now.
- Hard date: **2027-02-01**.

---

## 13. Market check and the order (2026-11-02)

Confirmed at checkout: **KS-5 at 64 GB = $38.58/month + $26.69 setup**, year one ≈ **$490**.
Provisioning is about an hour on this account (seventh OVH dedicated server), so there is **no lead
time to wait out**.

| Offer | CPU | RAM | Disk | Network | $/month | Year 1 |
|---|---|---|---|---|---|---|
| **KS-5 (chosen)** | E3-1270 v6, 4c/8t | 64 GB ECC | 2×450 NVMe | 500 Mbps | **38.58** | **~490** |
| KS-GAME | i7-7700K, 4c/8t | 32–64 GB | 2×450 NVMe | 300 Mbps | 42.99 | ~559 |
| KS-A | i7-6700K, 4c/8t | 32 GB | 1×480 SATA | 100 Mbps | 81.99 | ~1,066 |
| SYS-1 | E-2136, 6c/12t | 32 GB | 2×512 NVMe | 0.5–1 Gbps | 44.39 | ~577 |
| Hetzner AX41 ≈ €40–45 | Ryzen 5 3600, 6c/12t | 64 GB | 2×512 NVMe | 1 Gbps | ~60–68 | ~720–816 |

Euro at ≈1.50 CAD, so Hetzner's monthly is **1.5–2× the KS-5** even with no setup fee. The earlier
“Hetzner is cheaper per core” note was a currency error and is withdrawn — per dollar the Kimsufi
wins. KS-A and KS-GAME are both rejects: one is slower network at 3× the price, the other is +$16
for ~7% single-thread and a lower RAM ceiling.

### Order now, or wait for the event — no codes exist

**There are no promo codes** (checked 2026-11-02). Kimsufi's own Black Friday page states the
discount "is applied automatically when you order, with no promo code", that it applies to **new**
server orders from existing accounts (not to renewals), and that stock is limited per datacentre.
The page is a placeholder until the event launches, so the size of the discount is unknown.
Third-party "Kimsufi coupon" sites are affiliate spam — one of them promises "free shipping" on a
dedicated server.

So the wait buys the **$26.69 setup fee and possibly a monthly discount** — which is worth more than
the fee if the event lands. Against that: three and a half weeks without the box, and no guarantee
the 64 GB KS-5 in Beauharnois stays in stock.

The decision, plainly: ask pre-sales for a waiver **now**, and if they grant one, order. If they
don't and the saving matters, wait for the event and watch stock; if the laptop being the bottleneck
is the real cost, pay the fee today. Ask about a multi-server discount on the monthly either way.

One thing to confirm either way: **whether $38.58 is ex-tax.** Kimsufi's catalogue prices are, so
the cart will add GST/HST/QST — budget roughly $43–44 as the real monthly.

If the box lands after **2026-12-02**, renew the VPS one more month (~$9) rather than compress the
cutover. The migration is the risky part; the VPS month is not.
