# Infrastructure roadmap — dev box, tailnet and the cloud server

**Status:** proposed — P0–P3 are ready to start; P5 is the cutover and needs a maintenance window.
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
4. **The VPS freed** for the Elixir app, with the apex `:443` still doing its one job.

---

## 2. Verified baseline — 2026-11-02

Measured, not assumed. Re-measure before acting; this section goes stale.

### The house, as it is

| Host | What it is | What it runs |
|---|---|---|
| **laptop** | ASUS Vivobook X1504ZA, i5-1235U (2P+8E), 15.6 GB, Manjaro | the editor, the agents, its own JawnOS, **the LAN manager the devices talk to** |
| **table** | Manjaro, 4 cores, 7.6 GB, 239 GB root (74% used) | its own JawnOS, GTK desktop |
| **cloud** | OVH VPS, Debian 13, **2 vCPU, 3.7 GB, 40 GB** | Headscale, the always-on JawnOS house server, the public hub, DNS, mail, exit node |
| **tablet** | Android | tailnet client only |
| **phone** | Android | **not registered in Headscale today** — treat it as off-tailnet until it appears |

Headscale lists four nodes: `table`, `cloud`, `laptop`, `tablet`.

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

### The new server (Kimsufi)

- Intel Xeon E3-1270 v6: 4 cores / 8 threads, 3.8–4.2 GHz, 72 W, no throttling in a server chassis.
- 64 GB DDR4-2400 ECC — the platform maximum.
- 2 × 450 GB SSD NVMe, soft RAID. **450 GB usable, not 900.**
- 500 Mbit/s unmetered. Beauharnois, Canada East — the same region as the VPS.
- Unmanaged: assume **no IPMI/KVM console**, hardware replacement only, rescue mode as the fallback.

### The cloud server (`cloud`, `vps-7c120a57`)

- **Headscale owns `0.0.0.0:443` on the apex domain.** `server_url: https://thejunderground.com`,
  `listen_addr: 0.0.0.0:443`, embedded DERP with `stun_listen_addr: 0.0.0.0:3478`,
  `automatically_add_embedded_derp_region: true`, `magic_dns: true`,
  `base_domain: jonathanferwerda.com`, prefixes `100.64.0.0/10` and `fd7a:115c:a1e0::/48`.
  `thejunderground.com:443` is the control plane and nothing else: `/manager` is **404** there,
  `/windows` is Headscale's own page.
  State is small and portable: `db.sqlite` (~86 KB) plus `noise_private.key`,
  `derp_server_private.key`, and the TLS pair in `/var/lib/headscale/tls/`.
- **TLS**: Let's Encrypt, `notAfter 2026-12-07`. The cert files are the source of truth
  (`tls_cert_path`/`tls_key_path` are set); the config also declares `HTTP-01` on `:http`.
  **Whatever renews it has to move too, or the name goes dark in December.**
- **The always-on JawnOS house server** (`jawnos.service`, `User=jawn`,
  `WorkingDirectory=/home/jawn/jawnos`, 1.1 GB) on **3000** (manager, ticket) and
  **45545 / 45546 / 45550** (the public hub and its websocket). `:45545` is what other houses dial
  (`Lan.pm`, `tunnel_hub_url`).
- **The tailnet exit node**, offering `0.0.0.0/0`. The laptop is pinned to it.
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
| D9 | **The apex domain follows Headscale to the KS-5.** The Elixir app takes a subdomain on the | decided |
| | VPS. One IP, one name, so no failover-IP or virtual-MAC work is needed. | |

**The cost of D5, stated plainly:** the tailnet's control plane now lives on the box that gets
snapshotted, rebuilt and rebooting. Mitigations, all in P5:

- Headscale runs on the **host** or in its own dedicated container — never in `dev`.
- A `dev` restart is a container restart, not a host reboot. Host reboots are a scheduled event.
- Existing tunnels survive a coordination outage (WireGuard keys and DERP paths are established);
  what breaks is new node joins, route changes and DNS refreshes.
- **Do not leave the laptop pinned to the KS-5 exit node by default.** If the KS-5 is down, a
  pinned laptop has no internet. Use the exit node deliberately, or point it at the VPS.

D1 is not a performance argument. Proxmox costs about 0.5–1% of a core and ~1 GB RAM on the KS-5;
its value is the snapshot you take before a network change on a machine you cannot walk over to,
and the second container that D8 needs. The "Proxmox is a drain" reputation is ZFS's default ARC
(50% of RAM — 32 GB here) and oversubscribing small machines.

---

## 4. Target topology

- **KS-5** — public apex name; cores, RAM and bandwidth:
  - the **host** — `tailscaled`, the exit node, Proxmox;
  - **Headscale** — own container (or host service), `:443` and DERP on `3478/udp`;
  - **`house`** — the always-on JawnOS server and public hub (`3000`, `45545`–`45550`);
  - **`dev`** — Zed remote, the suite, PlatformIO and Gradle builds.
- **VPS (`cloud`)** — Elixir only, on `app.thejunderground.com`. Quiet, cheap, always on.
- **laptop / table / tablet** — clients, *and* the **LAN manager for the embedded devices**
  (§5). This does not move.

Public DNS: Cloudflare. The apex A record moves from the VPS to the KS-5; everything else is
unchanged. Because the app is one name on one IP, there is no additional-IP or virtual-MAC
configuration in this design.

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
     plugged into.
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

### P1 — Install the host

- [ ] Install Proxmox VE. Check the panel's image list first; otherwise minimal Debian plus the
      PVE repository.
- [ ] ZFS mirror across both NVMe. **Cap ARC** — the default is 50% of RAM (32 GB);
      `zfs_arc_max` at 8–12 GB is right for 64 GB and several containers.
- [ ] Firewall 8006 off the internet; SSH keys only; unattended upgrades.
- [ ] Assume no console: `console=ttyS0`, change networking only with a second SSH session open
      and a snapshot to roll back to.
- **Exit:** host up, ARC capped, 8006 unreachable from outside, one snapshot taken.

### P2 — Join the tailnet (as a client, before anything moves)

- [ ] `tailscale up --login-server https://thejunderground.com --authkey …` on the host.
      **Outbound only** — no inbound rule needed for this one step.
- **Exit:** `headscale nodes list` on the VPS shows the new node.

### P3 — The containers

- [ ] `dev`: privileged LXC, Debian, ~8 GB RAM, the repo cloned inside (never `releases/`,
      never `.secrets/`).
- [ ] **Fresh database** from `database/schema.sql`. Never a copy of the live `jawnos.db` — that
      is the cross-machine restore `AGENTS.md` documents, and it leaves the container wearing the
      laptop's `devices` row and `remote_machines` list (D7). No mesh, no tunnels.
- [ ] `house`: a second LXC for the always-on server that moves off the VPS in P6 (D8).
- [ ] Reachability, one of:
      **(a)** the host advertises the bridge — `tailscale up --advertise-routes=10.20.0.0/24`,
      approved with `headscale routes enable`, and clients need `tailscale set --accept-routes`
      (the laptop has it off today); or
      **(b)** `tailscaled` inside each container with `/dev/net/tun` passed through.
- [ ] Zed remote over SSH into `dev`. `perlnavigator` and `git status` move there.
- [ ] `perl scripts/run_tests.pl --jobs 6` — 6 on 4C/8T, not the default 8.
- **Exit:** green suite on the server, Zed editing the remote tree, laptop `zed+ext` down to
  roughly 0.2 core.

### P4 — Exit node

- [ ] Offer an exit node from the KS-5; select it on the laptop **deliberately**, confirm the path.
- [ ] Clear the old selection (`tailscale set --exit-node=`) so the VPS stops carrying fleet egress.
- **Exit:** the VPS is no longer an exit node and `tailscaled` there is quiet.

### P5 — Move Headscale (the cutover; schedule it)

This is the one phase that can lock people out. Everything below happens in one window, with the
old host kept intact for a rollback.

- [ ] Lower the Cloudflare apex A TTL to 60 s a day ahead.
- [ ] `systemctl stop headscale` on the VPS (clean WAL), then copy **all** of
      `/var/lib/headscale/`: `db.sqlite` (+ `-wal`/`-shm` after the stop), `noise_private.key`,
      `derp_server_private.key`, and `tls/`.
- [ ] Install Headscale on the KS-5 with the **same** values: `server_url`, `listen_addr` on 443,
      `stun_listen_addr` on 3478, embedded DERP, the two prefixes, `magic_dns`,
      `base_domain`, the nameservers, and the same TLS paths.
- [ ] Open on the KS-5: **443/tcp**, **3478/udp** (STUN), **41641/udp** (tailscaled), and
      **80/tcp** if the ACME challenge is HTTP-01. Confirm the cert files were moved and that
      something still renews them before **2026-12-07**.
- [ ] Point the apex A record at the KS-5.
- [ ] Verify: `headscale nodes list` shows table, cloud, laptop and tablet; `tailscale status` on
      the laptop; the DERPMap carries the embedded region.
- [ ] **Never run both instances at once** — two servers with the same keys and diverging
      databases is the one unrecoverable state.
- [ ] Rollback: repoint the A record and start the old Headscale. The copied state is a snapshot;
      keep it for a week.
- **Exit:** every node online through the KS-5, the hub answering on the same name, the VPS's
  Headscale disabled.

### P6 — Shed the VPS

- [ ] Move the always-on JawnOS server to `house`. It is the top CPU consumer on the VPS: this is
      the step that fixes the 2-vCPU box.
- [ ] The hub moves with the apex, so it must already answer on the KS-5 before P5 repoints DNS.
- [ ] Remove what is not in the path (see §6): rspamd and valkey have no reference in the tree;
      exim4 is local-delivery only.
- [ ] Keep dnsmasq only if `jawnferroda.com` names are still needed; the public zone is Cloudflare.
- **Exit:** VPS load under 0.5 at rest, no JawnOS on it, Headscale answering `/health` from the
  KS-5.

### P7 — Elixir, last

- [ ] Only after P6 leaves the VPS quiet. Give it `app.thejunderground.com`; the apex `:443`
      belongs to Headscale.
- [ ] Back up the Headscale state and TLS material before any reinstall on that host.
- **Exit:** Elixir serving its subdomain, Headscale untouched, tailnet healthy.

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
2. **What renews the TLS certificate**, and can it run on the KS-5? The current pair expires
   **2026-12-07**.
3. **Does the hub's public URL live in a setting on each house** (`tunnel_hub`), or is it learned
   from the handshake? This decides whether moving the hub is one change or one per house.
4. **Where is the Elixir app's load ceiling?** BEAM wants cores; if it outgrows 2 vCPU, it is the
   easiest workload to move, and it must not land on the dev box.

---

## 9. Risk and rollback

- **Today's single point of failure** is `cloud`: control plane, house server and egress on one
  over-subscribed VPS. P4–P6 split those three apart, but D5 recombines two of them on the KS-5.
- **The one irreversible act** is a Headscale move done without a clean copy of
  `/var/lib/headscale/`. With it, a rollback is a DNS change and a service start; without it,
  every node re-registers.
- **The one easy own-goal** is a broken bridge or a closed 3478/udp on a host with no console.
  Snapshot first, keep the old SSH session open, and confirm the ports before repointing DNS.
- **The one dated risk** is the certificate: **2026-12-07**.
- **The one rule that must not be bent** is D7. A copied database on a dev container looks like it
  works and then quietly poisons the mesh.
- **The one coupling to watch** is D5: reboot the host deliberately, and never leave the laptop
  pinned to an exit node that lives on it.

---

## 10. Cost

- KS-5: **$26.69 installation + $11.89/month**.
- The VPS stays: ~$9 CAD/month (the figure `scripts/sponsors_goal.pl` uses). Update that default
  if the bill changes, so the sponsor goal keeps telling the truth.
