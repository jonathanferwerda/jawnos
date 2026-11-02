# Infrastructure roadmap — dev box, tailnet and the cloud server

**Status:** proposed — P0–P2 are ready to start; P5/P6 depend on the domain decision in §4.
**Started:** 2026-11-02 · **Baseline measured** 2026-11-02 by logging into all four hosts.
**Related:** `AGENTS.md` (run/restart, the database-is-per-device rule, the mesh rules),
`docs/AGENTS-restart.md`, `t/README.md` (what the suite does and does not touch)

The plan for taking the programming and test load off the laptop and onto a dedicated server,
**without** moving the house's live data and **without** taking the tailnet down while the cloud
server is repurposed. Compare `docs/migration-roadmap.md`, which is about the stack, not the metal.

---

## 1. Charter

> Move the work that needs cores to a box with cores, and leave the house, its database and its
> public name where they are.

What this buys, in order:

1. **A test suite that does not make the laptop unusable.** Eight forked Perl children pin two
   P-cores and spill eight threads of work onto E-cores; the editor is scheduled around them.
2. **A cloud server that is not at 90% of two cores.** Today it runs the tailnet control plane,
   the house's always-on JawnOS server, the public tunnel hub, DNS and a mail stack on 2 vCPU.
3. **One place to run builds** (Gradle, PlatformIO, the suite) with 64 GB and NVMe.

---

## 2. Verified baseline — 2026-11-02

Measured, not assumed. Re-measure before acting; this section goes stale.

### The house, as it is

| Host | What it is | What it runs |
|---|---|---|
| **laptop** | ASUS Vivobook X1504ZA, i5-1235U (2P+8E), 15.6 GB, Manjaro | the editor, the agents, its own JawnOS |
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

This is the finding that sets the order. It is not a spare box, and it is not idle:

- **Headscale owns `0.0.0.0:443` on the apex domain.** `server_url: https://thejunderground.com`,
  `listen_addr: 0.0.0.0:443`, embedded DERP enabled. So `thejunderground.com:443` is the control
  plane and nothing else: `/manager` is **404** there, `/windows` is Headscale's own page.
  State is tiny and portable: `/var/lib/headscale/db.sqlite` (~86 KB) plus
  `noise_private.key` and `derp_server_private.key`.
- **The always-on JawnOS house server** (`jawnos.service`, `User=jawn`,
  `WorkingDirectory=/home/jawn/jawnos`, 1.1 GB) listening on **3000** (manager, ticket) and
  **45545 / 45546 / 45550** (the public hub and its websocket). `:45545` is what other houses dial
  (`Lan.pm`, `tunnel_hub_url`).
- **The tailnet exit node**, offering `0.0.0.0/0`. The laptop is pinned to it.
- **dnsmasq on `:53`**, whose whole config is `addn-hosts` for `jawnferroda.com` — a local name
  resolver, **not** the public DNS. Public DNS is Cloudflare, so a move touches one Cloudflare
  record, not a zone file.
- **A mail stack**: exim4 (loopback only), rspamd, clamav-daemon + freshclam, valkey.
- SSH on 8022.
- **Load 1.83 / 0.88 / 0.66 on 2 vCPU.** PSI CPU `some avg10≈9.5`; sys time up to 48% and
  context switches in the thousands — it is **CPU/context-switch bound, not IO bound**. The top
  consumers are the JawnOS Perl processes, then `tailscaled` relaying the exit-node traffic.
  ClamAV is not in the top CPU or memory sample.

**Elixir is not running anywhere.** No `beam.smp`, no `elixir` process on any host.

---

## 3. Decisions

| # | Decision | State |
|---|---|---|
| D1 | **Proxmox VE** on the Kimsufi host, for snapshots and rollback on a box with no console | decided |
| D2 | Containers, not VMs, for the JawnOS instances — near-zero overhead, shares the kernel | decided |
| D3 | Networking: **host-level `tailscaled` + an advertised subnet route** for the containers | proposed (§5 P3) |
| D4 | The **exit node moves to the KS-5** (500 Mbit unmetered, not the control-plane host) | decided |
| D5 | **Headscale stays on the VPS.** The control plane must not live on the box that gets | decided |
| | snapshotted and rebooted during development — a dev reboot would drop the whole tailnet | |
| D6 | The laptop keeps `performance`; the fan noise is accepted in exchange for maximum clocks | decided by the person, 2026-11-02 |
| D7 | Any dev container gets a **fresh database** and stays **off the mesh** | decided — a rule |
| D8 | The **house's always-on JawnOS server moves to its own container** on the KS-5, separate | proposed (§4) |
| | from the dev container, so a coding-agent restart or a test run cannot touch it | |
| D9 | **Domain layout**: Headscale keeps the apex `:443`; the hub and the Elixir app take | proposed (§4) |
| | subdomains | |

D1 is not a performance argument. Proxmox costs about 0.5–1% of a core and ~1 GB RAM on the KS-5;
its value is the snapshot you take before a network change on a machine you cannot walk over to,
and the second container that D8 needs. The "Proxmox is a drain" reputation is ZFS's default ARC
(50% of RAM — 32 GB here) and oversubscribing small machines.

---

## 4. Target topology, and the domain conflict

- **VPS (`cloud`)** — public apex name, always-on, low CPU: **Headscale**, then the Elixir app.
  JawnOS, the mail stack and dnsmasq come off it (§5 P5, P6).
- **KS-5** — cores, RAM, bandwidth: an **exit node** on the host, plus two containers:
  `house` (the always-on JawnOS server and public hub) and `dev` (Zed remote, the suite, builds).
- **House machines** — clients. The tailnet stays the VPS's tailnet.

Nothing on the KS-5 needs an inbound public port to *join* the tailnet. The `house` container
needs one public name for the hub, because other houses dial it.

### The domain conflict (this is the decision P5/P6 wait on)

Headscale already answers on `thejunderground.com:443`, and `server_url` is that exact origin.
Changing it means every node's `ControlURL` changes and each device re-registers. So the apex is
spoken for, and three services need names:

| Service | Today | Options |
|---|---|---|
| Headscale | apex `:443` | keep (no re-auth), or move to `headscale.…` (every node re-registers) |
| JawnOS hub | apex `:45545` | keep on the VPS, or `hub.thejunderground.com` → KS-5 |
| Elixir app | not deployed | `app.thejunderground.com` → VPS |

Two coherent layouts:

**(L1) Keep the apex where it is.** Headscale stays on the VPS; the hub moves to
`hub.thejunderground.com` on the KS-5; Elixir takes `app.thejunderground.com` on the VPS.
No node re-registers. Each house's `tunnel_hub` setting changes once — or not at all if the hub
learns to advertise its own new URL (`tunnel_hub_url` already prefers the handshake).

**(L2) The apex follows the hub to the KS-5.** One name, everything on the new box: Headscale
state migrates (it is 86 KB), DNS repoints, nodes reconnect on their own because the name does not
change. The VPS becomes Elixir-only. Cost: the tailnet control plane now shares a host with the
dev containers — a reboot during development takes the tailnet with it.

**L1 is the recommendation.** It keeps the one thing that must never be rebooted casually on the
box that is only rebooted deliberately, and it costs one subdomain.

---

## 5. Phases

Nothing is deleted until its replacement answers. That ordering *is* the rollback plan.

### P0 — Power policy: no action

- [x] Decided: keep `governor = performance`, turbo on, PL1 39 W. The fan is accepted (D6).
- [ ] Do not re-litigate this. The sluggishness was contention, and P3 is what fixes it.

### P1 — Install the host

- [ ] Install Proxmox VE. Check the panel's image list first; otherwise minimal Debian plus the
      PVE repository.
- [ ] ZFS mirror across both NVMe. **Cap ARC** — the default is 50% of RAM (32 GB);
      `zfs_arc_max` at 8–12 GB is right for 64 GB and two containers.
- [ ] Firewall 8006 off the internet; SSH keys only; unattended upgrades.
- [ ] Assume no console: `console=ttyS0`, change networking only with a second SSH session open
      and a snapshot to roll back to.
- **Exit:** host up, ARC capped, 8006 unreachable from outside, one snapshot taken.

### P2 — Join the tailnet

- [ ] `tailscale up --login-server https://thejunderground.com --authkey …` on the host.
      **Outbound only** — no inbound rule, no port forward, no public IP needed for this.
- **Exit:** `headscale nodes list` on the VPS shows the new node.

### P3 — The two containers

- [ ] `dev`: privileged LXC, Debian, ~8 GB RAM, the repo cloned inside (never `releases/`,
      never `.secrets/`).
- [ ] **Fresh database** from `database/schema.sql`. Never a copy of the live `jawnos.db` — that
      is the cross-machine restore `AGENTS.md` documents, and it leaves the container wearing the
      laptop's `devices` row and `remote_machines` list (D7). No mesh, no tunnels.
- [ ] `house`: a second LXC for the always-on server that moves off the VPS in P6 (D8). It keeps
      its own copy of the database, migrated deliberately, and nothing else shares its instance.
- [ ] Reachability, one of:
      **(a)** the host advertises the bridge — `tailscale up --advertise-routes=10.20.0.0/24`,
      approved with `headscale routes enable`, and clients need `tailscale set --accept-routes`
      (the laptop has it off today); or
      **(b)** `tailscaled` inside each container with `/dev/net/tun` passed through.
- [ ] Zed remote over SSH into `dev`. `perlnavigator` and `git status` move there.
- [ ] `perl scripts/run_tests.pl --jobs 6` — 6 on 4C/8T, not the default 8.
- **Exit:** green suite on the server, Zed editing the remote tree, laptop `zed+ext` down to
  roughly 0.2 core.

### P4 — Move the exit node

- [ ] Offer an exit node from the KS-5; select it on the laptop; confirm the traffic path.
- [ ] Then clear the old selection (`tailscale set --exit-node=`) so the VPS stops carrying the
      fleet's egress. It is already CPU-contended; this is free relief.
- **Exit:** the VPS is no longer an exit node and `tailscaled` there is quiet.

### P5 — Shed the VPS down to the control plane

Measured order, biggest relief first. Re-measure `uptime` and PSI CPU after each step.

- [ ] Move the always-on JawnOS server (`jawnos.service`) to the `house` container. It is the top
      CPU consumer on the VPS by a wide margin — this is the step that fixes the 2-vCPU box.
- [ ] Move the public hub name with it (L1: `hub.thejunderground.com`; update `tunnel_hub` on each
      house once, or let the handshake advertise the new URL).
- [ ] Drop the mail stack if nothing outbound depends on it (exim4 + rspamd + clamav + valkey) —
      verify with the notification path first; these are RAM and attack surface, not core work.
- [ ] Keep dnsmasq only if `jawnferroda.com` names are still needed; the public zone is Cloudflare.
- [ ] Headscale stays. It is a Go binary on 443 with an 86 KB database; 2 vCPU is plenty once
      JawnOS and the mail stack are gone.
- **Exit:** VPS load under 0.5 at rest, Headscale still answering `/health`, hub answering on the
  new name from outside.

### P6 — Elixir on the VPS, last

- [ ] Only after P5 leaves the VPS quiet. Then the Elixir app gets the freed capacity.
- [ ] Give it a subdomain (L1: `app.thejunderground.com`); the apex `:443` belongs to Headscale.
- [ ] Back up the Headscale state (`db.sqlite`, `noise_private.key`, `derp_server_private.key`)
      and the TLS material before any reinstall on that host.
- **Exit:** Elixir serving its subdomain, Headscale untouched and still answering, no JawnOS copy
  left on the VPS.

### Non-goals

- **Not moving the live `jawnos.db` between machines casually.** The database is per device; the
  house's own server moves once, deliberately, in P5, with the identity rules from `AGENTS.md`.
- **Not making the laptop a browser-only client** unless the Coding agent is meant to carry the
  whole loop. It can edit, compile, commit, push and restart, but it is one staged write with no
  LSP and no hand-editable diff; that is the wrong tool for multi-file refactors.
- **Not putting Headscale on the dev box.** See D5.

---

## 6. Open questions

1. **L1 or L2** (§4)? Everything in P5/P6 hangs on it.
2. **Does anything depend on the outbound mail stack** (notifications, mail flows)? If not, P5 can
   delete it rather than migrate it.
3. **Does the hub's public URL live in a setting on each house** (`tunnel_hub`), or is it always
   learned from the handshake? This decides whether moving the hub is one change or one per house.
4. **Where is the Elixir app's load ceiling?** BEAM wants cores. If it outgrows the 2-vCPU VPS, it
   is the easiest workload to move, because it has no LAN dependencies — but it must not land on
   the dev box.

---

## 7. Risk and rollback

- **Today's single point of failure** is `cloud`: control plane, house server and egress on one
  over-subscribed VPS. P4 and P5 split those three apart.
- **The one irreversible act** is wiping `cloud`. The Headscale state backup is what makes it
  survivable — without it, every node re-authenticates.
- **The one easy own-goal** is a broken bridge on a host with no console. Snapshot first, keep the
  old SSH session open, and prefer NAT'd containers: nothing here needs inbound ingress except the
  hub's name.
- **The one rule that must not be bent** is D7. A copied database on a dev container looks like it
  works and then quietly poisons the mesh.
- **The one coupling to avoid** is D5: a control plane on the box you reboot while developing.

---

## 8. Cost

- KS-5: **$26.69 installation + $11.89/month**.
- The VPS stays: ~$9 CAD/month (the figure `scripts/sponsors_goal.pl` uses). Update that default
  if the bill changes, so the sponsor goal keeps telling the truth.
