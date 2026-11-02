# Infrastructure roadmap — dev box, tailnet and the cloud server

**Status:** proposed — P0–P2 are ready to start; P5 is blocked on the questions in §6.
**Started:** 2026-11-02
**Related:** `AGENTS.md` (run/restart, the database-is-per-device rule, the mesh rules),
`docs/AGENTS-restart.md`, `t/README.md` (what the suite does and does not touch)

The plan for taking the programming and test load off the laptop and onto a dedicated server,
**without** moving the house's live data and **without** taking the tailnet down while the cloud
server is repurposed. Compare `docs/migration-roadmap.md`, which is about the stack, not the metal.

---

## 1. Charter

> Move the work that needs cores to a box with cores, and leave the house, its database and its
> name where they are.

What this buys, in order:

1. **A test suite that does not make the laptop unusable.** Today eight forked Perl children pin
   two P-cores and spill eight threads of work onto E-cores; the editor is scheduled around them.
2. **A fan that is not the first thing you notice** — by moving the load, not by capping clocks
   (D6 below keeps the clock policy at maximum).
3. **A single place to run builds** (Gradle, PlatformIO, the suite) with 64 GB and NVMe, instead
   of competing with the editor for 16 GB.

What it deliberately does not do: see §5, non-goals.

---

## 2. Verified baseline — 2026-11-02

Measured, not assumed. Re-measure before acting; this section goes stale.

### The laptop (the client)

- ASUS Vivobook X1504ZA, i5-1235U: 2 P-cores + 8 E-cores, 12 threads.
- 15.6 GB RAM. 8 GB soldered plus one SODIMM, and it is already at 8+8 — 16 GB is ASUS's ceiling
  for this model. **There is no RAM upgrade path.**
- At rest with Zed and a few agents: load 2.9 (1 min) / 5.8 (15 min), ~16% of the machine.
  Zed + `perlnavigator` + `gitstatusd` ≈ 0.9 core / 2.7 GB; Chromium + WebKit ≈ 0.8 core / 3.0 GB;
  the JawnOS server (34 `President.pl` processes) ≈ 0.2 core / 4.1 GB.
- Thermals: 65–68 °C package, fan 4700 RPM, trip point 100 °C. **No throttling observed.**
  `governor = performance`, turbo on, `energy_performance_preference = performance`, PL1 39 W,
  average clock 2.87 GHz at that load. The heat is a power policy consequence, not a load one.
- The suite: 149 files, ~12–20 s at 8 jobs. `t/README.md` is explicit that **nothing in `t/`
  writes to the live database, the repo, or a fixed port** — every test gets a temp sandbox.

### The new server (Kimsufi)

- Intel Xeon E3-1270 v6: 4 cores / 8 threads, 3.8–4.2 GHz, 72 W, no throttling in a server chassis.
- 64 GB DDR4-2400 ECC — the platform maximum.
- 2 × 450 GB SSD NVMe, soft RAID. **450 GB usable, not 900.**
- 500 Mbit/s unmetered. Beauharnois, Canada East (same region as the current cloud server).
- Unmanaged: assume **no IPMI/KVM console**, hardware replacement only, rescue mode as the fallback.

### The cloud server (the tailnet's control plane)

This is the finding that sets the order. The box known as `cloud` is not a spare:

- **Headscale control plane.** Every node's `ControlURL` is `https://thejunderground.com`, and
  `GET /health` there answers `{"status":"pass"}` from that address.
- **Exit node.** It offers `0.0.0.0/0`; the laptop is currently pinned to it (`ExitNodeID: "2"`).
  Wiping it without clearing or moving that selection takes the laptop's internet with it.
- **The junderground hub** on `:45545`, the docs site, a copy of JawnOS, and the SSH entry point.

Clients in the tailnet: `laptop`, `table`, `phone`, `tablet`. The laptop runs `RouteAll: false`
(`--accept-routes` off) and `ExitNodeAllowLANAccess: true`.

---

## 3. Decisions

| # | Decision | State |
|---|---|---|
| D1 | **Proxmox VE** on the Kimsufi host, for snapshots and rollback on a box with no console | decided |
| D2 | The JawnOS dev instance runs in an **LXC**, not a VM — near-zero overhead, shares the kernel | decided |
| D3 | Networking: **host-level `tailscaled` + an advertised subnet route** for the container | proposed (§5 P3) |
| D4 | The **exit node moves to the KS-5** (500 Mbit unmetered, not the control-plane host) | decided |
| D5 | **Headscale stays on the VPS** with the public name | proposed (§5 P5) |
| D6 | The laptop keeps `performance`; the fan noise is accepted in exchange for maximum clocks | decided by the person, 2026-11-02 |
| D7 | The dev container gets a **fresh database** and stays **off the mesh** | decided — a rule, not a preference |

D1 is not a performance argument. Proxmox costs about 0.5–1% of a core and ~1 GB RAM on this box;
its value is the snapshot you take before a network change on a machine you cannot walk over to.
The reputation for "Proxmox is a drain" is ZFS's default ARC (50% of RAM — 32 GB here) and
oversubscribing small machines.

---

## 4. Target topology

- **VPS (`cloud`)** — public name, always-on, low CPU: Headscale, the Elixir hub, TLS.
- **KS-5** — cores, RAM, bandwidth: the dev container, the suite, the builds, the exit node.
- **House machines** — clients. The tailnet is still the VPS's tailnet.

Nothing on the KS-5 needs an inbound public port: it joins by dialing the control plane, and
the JawnOS houses dial out to the hub (`Lan.pm`) rather than being dialed.

---

## 5. Phases

Nothing is deleted until its replacement answers. That ordering *is* the rollback plan.

### P0 — Power policy: no action

- [x] Decided: keep `governor = performance`, turbo on, PL1 39 W. The fan is accepted (D6).
- [ ] Do not re-litigate this during the migration. The sluggishness was contention, and P3 is
      what fixes it. Record the number: the laptop's ceiling is thermal, not policy.

### P1 — Install the host

- [ ] Install Proxmox VE. Check the panel's image list first; if there is no PVE image, a minimal
      Debian plus the PVE repository is the fallback.
- [ ] ZFS mirror across both NVMe. **Cap ARC**: the default is 50% of RAM (32 GB);
      `zfs_arc_max` at 8–12 GB is right for a box with 64 GB and one container.
- [ ] Firewall 8006 off the internet; SSH keys only; unattended upgrades.
- [ ] Assume no console: `console=ttyS0` in the kernel line, and change networking only with a
      second SSH session open and a snapshot to roll back to.
- **Exit:** host up, ARC capped, 8006 unreachable from outside, one snapshot taken.

### P2 — Join the tailnet

- [ ] `tailscale up --login-server https://thejunderground.com --authkey …` on the host.
      **Outbound only** — no inbound rule, no port forward, no public IP needed for this.
- **Exit:** `tailscale status` on the laptop lists the new node as active.

### P3 — The dev container

- [ ] Privileged LXC, Debian, ~8 GB RAM, the repo cloned inside (never `releases/`, never `.secrets/`).
- [ ] **Fresh database** from `database/schema.sql`. Never a copy of the live `jawnos.db` — that
      is the cross-machine restore `AGENTS.md` documents, and it leaves the container wearing the
      laptop's `devices` row and `remote_machines` list (D7).
- [ ] No mesh: no `remote_machines`, no sync cursors, no tunnels.
- [ ] Reachability, one of:
      **(a)** host advertises the bridge — `tailscale up --advertise-routes=10.20.0.0/24`, approve
      it with `headscale routes enable`, and every client needs `tailscale set --accept-routes`
      (the laptop has it off today); or
      **(b)** `tailscaled` inside the container with `/dev/net/tun` passed through, so the container
      has its own tailnet identity.
- [ ] Zed remote over SSH into the container. `perlnavigator` and `git status` move there.
- [ ] `perl scripts/run_tests.pl --jobs 6` — 6 on 4C/8T, not the default 8.
- **Exit:** green suite on the server, Zed editing the remote tree, laptop `zed+ext` down to
  roughly 0.2 core.

### P4 — Move the exit node

- [ ] Offer an exit node from the KS-5; select it on the laptop; confirm the traffic path.
- [ ] Then clear the old selection (`tailscale set --exit-node=`) so `cloud` is no longer fleet egress.
- **Exit:** laptop's internet carried by the KS-5; the VPS is only a control plane and a name.

### P5 — Headscale: stay or move

**(a) Stays on the VPS** — the default. The public name lives where the public name is.
**(b) Moves to the KS-5** — then the KS-5 owns `thejunderground.com`:

- [ ] Back up `/var/lib/headscale/` (`db.sqlite`, `noise_private.key`, `private.key`) and the TLS
      material (`/etc/letsencrypt` or equivalent).
- [ ] Move the state, swap DNS, and wait for every node to reconnect. Nodes keep their identity
      when the state moves; a rebuild instead forces `headscale nodes register` on every device.
- **Exit:** the decision is written down here, and if (b), every node is active without `cloud`.

### P6 — Repurpose the VPS, last

- [ ] Only after P4 and P5 leave the tailnet healthy without `cloud`.
- [ ] Back up the Headscale state and TLS material **before** touching the disk.
- [ ] Verify from `laptop` and `table`, not just the shell you are already in.
- [ ] Wipe and install the hub. Keep `:45545` and the public name answering throughout the change.
- **Exit:** hub answering, tailnet healthy, no JawnOS copy left on the VPS.

### Non-goals

- **Not moving the live `jawnos.db`.** The database is per device; the house stays on the laptop
  until that is a separate, deliberate decision with the identity repair attached.
- **Not moving Manager/Websocket/President.** That process group is 0.2 core and 4.1 GB. Moving it
  costs LAN reachability for device OTA and the desktop app, latency on every route, and a second
  mesh identity — to save a fifth of one core.
- **Not making the laptop a browser-only client** unless the Coding agent is meant to carry the
  whole loop. It can edit, compile, commit, push and restart, but it is one staged write with no
  LSP and no hand-editable diff; that is the wrong tool for multi-file refactors.

---

## 6. Open questions

1. **Does Headscale run on `cloud` itself, or on another host behind that reverse proxy?** The
   DNS points at `cloud`, and `/health` answers there — but this decides whether P5 is mandatory
   before P6 or merely a preference.
2. **Is the Elixir hub the process already answering on `:45545`?** If yes, "install
   thejunderground on the VPS" is a redeploy and the name must never stop answering; if no, P6 is
   a first deploy and the risk is lower.
3. **Which branch of P5** — (a) or (b)?
4. **Where is the hub's load ceiling?** BEAM wants cores; a small VPS will be the bottleneck long
   before the Xeon is. If that happens the hub is the easiest workload to move, since it has no
   LAN dependencies.

---

## 7. Risk and rollback

- **Today's single point of failure** is `cloud`: control plane *and* egress for the fleet. P4
  removes half of that; P5 decides the other half.
- **The one irreversible act** is wiping `cloud`. The Headscale state backup is what makes it
  survivable — without it, every node re-authenticates.
- **The one easy own-goal** is a broken bridge on a host with no console. Snapshot first, keep the
  old SSH session open, and prefer the NAT'd container: nothing here needs inbound ingress.
- **The one rule that must not be bent** is D7. A copied database on the dev container looks like
  it works and then quietly poisons the mesh.

---

## 8. Cost

- KS-5: **$26.69 installation + $11.89/month**.
- The VPS stays: ~$9 CAD/month (the figure `scripts/sponsors_goal.pl` uses). Update that default
  if the bill changes, so the sponsor goal keeps telling the truth.
