# Blackout readiness

What survives an internet outage, and what does not. The scope here is **the WAN is down, the
house LAN and its power are up**. A power outage is a different failure: it takes the router and
the AP with it, and no software path helps.

Run `perl scripts/offline_check.pl` for the current verdict on this machine. It is read-only and
makes no network calls unless you pass `--probe`.

From a linked worktree, pass `--root ~/jawnos` (or `--db`) so the check reads the live roster
rather than the worktree's seeded test database.

## The short version

| Outage | What still works | What stops |
|---|---|---|
| WAN only, you are on the home LAN | local managers, the peer rail over the LAN, direct LAN sync, files already on each machine | ks5 (`hub`, `dev`, `headscale`), the public names, remote access from outside, hub relays |
| ks5 down, WAN fine | the home LAN is untouched; established WireGuard paths may survive a coordination outage | new tailnet joins, route changes, MagicDNS refreshes, the hub's union view |
| Power out | phones on battery, Bluetooth/BLE, a hotspot if you make one | the router, the AP, every LAN address, the mesh |

## Why ks5 is a dependency

ks5 is a Kimsufi host in a datacenter, not a machine in the house. It runs the `house` hub and
`headscale`, the tailnet's control plane (`docs/infrastructure-roadmap.md`). The house names
(`*.jonathanferwerda.com`) resolve through the tailnet's DNS, so with the WAN down the names fail
too. Existing tunnels survive a *control-plane* outage because the WireGuard keys and paths are
already established; they do not survive the local ISP being down.

The laptop is the LAN manager the devices talk to, and each machine runs its own manager and its
own database. The panel and the app do not need ks5: the app opens loopback
(`loopback_manager`) and the laptop already maps its own domain to loopback.

## What carries the LAN

The peer rail has an explicit no-VPN path (`lib/JawnOS/Domain/House.pm`, "Peer addressing without
the tailnet"):

- Each `remote_machines` row carries literal LAN addresses, and the probe tries them before any
  name. The order is same-LAN, tailnet, off-LAN literal, public literal, name.
- `peer_live_manager` / `peer_literal_manager` fall back to a literal when the stored name does
  not resolve.
- `remote_machine_online` persists the address that answered, so the next pass starts there.
- Discovery is a signed UDP beacon on **45552**, broadcast plus unicast to known peers. It
  refreshes the peer's LAN IP and port and heals a DHCP move. Termux has no Avahi, so this is the
  path the phone and the computers share.
- The beacon only refreshes a row that already exists. It never introduces a stranger; first
  contact is the out-of-band join.

mDNS/Avahi is local-only, for `_jawnos-house._tcp`, `_jawnos._tcp` and printers. It is not the
peer rail, and Tailscale carries unicast DNS rather than multicast.

## What the check reads

- `database/jawnos.db`, opened read-only (`PRAGMA query_only`) and only selected from.
- `remote_machines` and the `sync_hub` / `sync/topology` settings.
- This machine's interfaces (`ip -o -4 addr` or `ifconfig`) and listening sockets (`ss` or
  `netstat`).
- `server/house-ca.pem` and the mDNS tool, if present.

It never prints the session cookie, the websocket auth or the pubkey.

Exit codes: **0** no blocker, **1** at least one blocker, **2** usage or database error.

`--probe` adds one short TCP connect per peer's best route. Use it deliberately; it is the only
part of the script that touches the network.

## What it cannot see

- **AP/client isolation.** A guest VLAN or an AP that drops peer-to-peer traffic makes every LAN
  address unreachable even though the roster is perfect.
- **A peer that was never in this machine's roster.** The beacon cannot introduce one, and the hub
  is often where the union lives.
- **Cross-subnet peers.** The beacon and literal routes do not cross a router; only the tailnet or
  a static route could.
- **Power.** The appliance spec calls for a UPS and a graceful shutdown
  (`docs/appliance-provisioning.md`); a house without one loses the LAN with the mains.
- **Whether the tailnet control plane is healthy.** That is a WAN question, and the check reports
  the rows with no LAN route as WAN-only rather than guessing.

## Rehearsal

On the laptop, with the LAN and power up:

1. `tailscale down` (or stop the tailnet service). Do not touch Wi-Fi.
2. Open the local manager on `https://127.0.0.1:<working_port>` and confirm it loads.
3. Run `perl scripts/offline_check.pl`. Expect the LAN peers on `192.168.1.x`, the hub reported as
   off-LAN, and no blocker for a peer that is at home.
4. Let a sync pass run, then confirm a peer's `manager` in the roster moved to its LAN literal.
5. `tailscale up` when you are done.

Do not open an appointment or centre view just to look; it fans out to every tab and pops windows
on the person's screen. Ask the panel instead.

Known gap: the tablet is LAN-only, and `dev` has no route into `192.168.1.0/24`
(`docs/infrastructure-roadmap.md`). From the laptop at home the tablet is still reachable on the
LAN.
