# The backpack gateway: parts, power, pack and sewing

**Status:** planning note, 2026-11-19. Prices are **approximate CAD** for
planning, not quotes; they exclude tax and shipping and move with stock. The
two builds are interchangeable: pick the board you can buy, then use the
shared kit.

The job: a Linux machine in the bag that is the Bluetooth Hands-Free end of a
screened call, reachable by the phone over the house tailnet, running the
JawnOS manager, `Sco.pl`, `Reception.pl`, Piper and whisper. It is not a
laptop replacement; it is a small always-on gateway.

## Three builds

| | **Raspberry Pi 4** | **Radxa ROCK 4B+** | **Radxa ROCK 3C** |
| --- | --- | --- | --- |
| SoC / RAM | BCM2711, 4 GB (8 GB optional) | RK3399 (2×A72 + 4×A53), 4 GB | RK3566 (4×A55), 4 GB |
| Storage | microSD or USB SSD (no eMMC) | 16/32/64/128 GB onboard eMMC | microSD; eMMC module optional |
| Wi-Fi / BT | Wi-Fi 5 (5 GHz) + BT 5.0 | Wi-Fi 5 (5 GHz) + BT 5.0 | Wi-Fi 5 + BT 5 (choose this variant) |
| Video out | 2× micro-HDMI (adapter needed) | 1× full HDMI | micro-HDMI (check the revision) |
| USB | 2× USB 3.0, 2× USB 2.0 | 1× USB 3.0 host, 1× USB 3.0 OTG, 2× USB 2.0 | 1× USB 3.0, 1× USB 2.0 |
| Network | GbE | GbE, M.2 M-key | GbE |
| Power | 5 V/3 A USB-C | 5 V/3 A USB-C | 5 V/3 A USB-C |
| OS | Raspberry Pi OS / Ubuntu / Armbian | Radxa Debian/Ubuntu / Armbian | Radxa Debian/Ubuntu / Armbian |
| Why | Best community support, official PSU/case, easy to replace | eMMC is more robust for the SQLite DB; full HDMI; GbE/M.2 | Cheapest 4 GB; efficient; enough for prompts and a name, slower for live transcript |

The 3C is the value pick when you are not sure yet how much compute the
backpack needs; the 4B+ is the safer general pick, and the 5C/8 GB or an N100
is the pick if the live transcript must keep up. All three are ARM64 and run
the same JawnOS stack. Keep the machine on **5 GHz** while it is the gateway
(`docs/reception.md:86-91`). On the 3C, buy the **Wi-Fi 5 / BT 5** variant,
not the Wi-Fi 6 / BT 5.4 one, unless you have tested its Bluetooth HFP path:
the newer module is less proven for the Hands-Free role.

If you already own the Odroid Go Ultra controller, skip the board line: it is
the project's intended "in a bag" gateway (`perl/President.pl:841`). Check its
USB Wi-Fi/Bluetooth dongle is not the Realtek RTL8821CU that carries the call
one way (`docs/reception.md:329-333`), and check its battery.

## Bill of materials

Shared kit, whichever board:

| Item | Spec | Qty | Each (CAD) | Ext. (CAD) | Notes |
| --- | --- | --- | --- | --- | --- |
| Power bank | 20,000 mAh, 30 W USB-C PD, pass-through | 1 | 55 | 55 | The board runs while the bank charges; low-current mode helps |
| USB-C PSU | 5 V/3 A (15–30 W) | 1 | 18 | 18 | Official Pi 15 W or Radxa 30 W; for charging at a desk |
| USB-C cable | USB-C to USB-C, 60 W, 2 m | 1 | 14 | 14 | Short/right-angle is nicer in the bag |
| Heatsink + case | Passive, vented, plastic | 1 | 20 | 20 | No metal case: it blocks Wi-Fi/BT |
| microSD card | 32 GB high-endurance | 1 | 18 | 18 | SanDisk High/Max Endurance, Samsung PRO Endurance |
| Card reader | USB-A/C microSD | 1 | 12 | 12 | For flashing and backups |
| LiPo-safe bag | Fire-resistant pouch | 1 | 18 | 18 | For the power bank; do not charge in the bag |
| **Shared total** | | | | **155** | |

Board-specific:

| Item | Pi 4 build | Radxa 4B+ build | Radxa 3C build |
| --- | --- | --- | --- |
| Board | Pi 4 Model B, 4 GB — **85** | ROCK 4B+, 4 GB / 32 GB eMMC — **120** | ROCK 3C, 4 GB — **70** |
| Boot media | 32 GB high-endurance microSD above | 32 GB eMMC included | microSD above; eMMC module optional, **30** |
| Video adapter | micro-HDMI → HDMI, **12** | full HDMI; a regular HDMI cable for setup, **10** | micro-HDMI → HDMI, **12** |
| Optional robust storage | 128 GB USB SSD + USB 3.0 adapter, **50** | eMMC already; M.2 NVMe optional | eMMC module, **30** |
| Optional UPS | Geekworm X728 (Pi 4), **55** | 5 V UPS/pass-through, **50** | 5 V UPS/pass-through, **50** |
| **Board subtotal** | **97** (no SSD/UPS) | **130** (no UPS) | **82** (no eMMC/UPS) |

Planning totals, no optional SSD/UPS/pack:

- **Pi 4 4 GB:** 155 shared + 97 = **~CAD 252**.
- **Radxa ROCK 4B+ 4 GB/32 GB:** 155 shared + 130 = **~CAD 285**.
- **Radxa ROCK 3C 4 GB:** 155 shared + 82 = **~CAD 237**; with the 32 GB
  eMMC module **~CAD 267**.

With the optional clean-shutdown UPS: **~CAD 307** (Pi) / **~CAD 335**
(4B+) / **~CAD 287** (3C). With the Pi's USB SSD: **~CAD 302**; plus UPS
**~CAD 357**.

These are the numbers that matter:

- **Board** is the biggest single line; the **power bank** is the second.
- The Pi's microSD is the weak point for a SQLite/WAL database. A
  high-endurance card is the minimum; a USB SSD is the robust choice.
- The Radxa's eMMC avoids the SD-card problem at the cost of a less common
  board and a slightly higher price.
- A UPS HAT is optional but buys a clean shutdown; a power bank with
  pass-through and a shutdown script is the cheaper version.
- **Compute:** the RK3566 in the 3C is enough for Piper and a short whisper
  name; the live transcript is where it lags. The RK3399 in the 4B+ is faster;
  the RK3588 in the 5C or an N100 is for live transcript/local models. A
  solenoid or a few sensors are GPIO work and do not change the board choice.

## Power, heat and network

- **Power:** the Pi 4 draws roughly 3–5 W idle and 7–10 W under whisper; the
  Rock 4B+ is similar. A 20,000 mAh (≈74 Wh) bank gives roughly 10–20 h idle
  and 7–10 h loaded, less with the phone hotspot. Use a pass-through bank so
  the gateway can run while the bank charges.
- **Heat:** a heatsink and a vented case. Do not seal the board in foam, and
  do not wrap the antenna end in the power bank. A fan is optional; in a bag
  it adds noise, dust and power, so passive first.
- **Network:** the phone must reach the gateway over the tailnet
  (`remote_machines` row with an IP, `sco_port` 45700). In the bag, use the
  phone's **5 GHz** hotspot. A 2.4 GHz hotspot puts the gateway's Wi-Fi and
  Bluetooth on the same antenna band, which is the failure the reception
  notes describe. USB tethering is the alternative if Wi-Fi coexistence is
  stubborn; it adds a cable.
- **Storage safety:** a power cut in a bag can corrupt a microSD or an eMMC.
  A UPS HAT or a bank with pass-through plus a clean shutdown is the
  difference between "the gateway is down" and "the gateway needs a reflash".
- **Bluetooth:** pair the phone to the board's adapter, give it a unique name
  (`jawn-table`, `jawn-laptop`, `jawn-odroid`), and offer the `hfp_hf` role
  (`docs/reception.md:76-84`). The hierarchy's rows carry that name.
- **Software:** Debian 13 / Ubuntu 24.04 or Armbian (WirePlumber 0.5 for the
  `51-jawn-hfp.conf` setup), Piper/whisper arm64, `perl scripts/build_sco.pl`,
  then the JawnOS installer. A stock vendor image older than that may need a
  WirePlumber upgrade before HFP works.

## Extras: a zipper that locks

A lock is a separate load and a separate safety decision; it does not change
the compute choice. The GPIO side is trivial, so a 3C is plenty.

### The lock

- **Servo latch (recommended first):** SG90/MG90 (~8–15), a printed latch arm
  and bracket (~5–15), a 5 V feed and a PWM GPIO. No holding current, no
  flyback diode, quiet enough for a bag. A limit switch (~4) tells the board
  whether the bolt is home. **~CAD 20–35.**
- **Solenoid bolt:** a 5 V or 12 V cabinet solenoid (~10–20), a MOSFET/relay
  driver (~6–10), a flyback diode (~1), a fuse holder (~3), a 12 V boost
  (~10) if you use a 12 V coil, a bulk capacitor (~5), wire/connectors (~8).
  A continuous-duty solenoid draws 0.5–1 A while energized and gets hot; a
  **latching solenoid** (~20–30) pulses to lock/unlock and is better for a
  bag, but needs a reversing driver (H-bridge or two relays). **~CAD 40–80**
  (latching: ~50–90).
- **Electric cabinet lock:** a solenoid bolt in a housing (~15–30); easier to
  mount, same driver and power rules.
- **Mechanical capture:** the lock captures the **zipper pull**, not the
  teeth. Sew a reinforced webbing loop/D-ring to the pull, or a small pull
  pocket, and let a bolt pass through it. A manual release (a cable or lever
  reachable from inside/outside) is mandatory.

### Power and safety

- Never drive the coil from a GPIO. Use a MOSFET/relay with a flyback diode
  (solenoid) or a servo driver (servo); the Pi/Radxa GPIO is 3.3 V logic.
- A 12 V solenoid needs its own 12 V rail (3S Li-ion with a BMS, or a boost
  converter with a bulk capacitor). The 5 V/3 A bank may brown out the board
  on the surge; the solenoid and the board should not share a rail without a
  capacitor and a fuse.
- Choose **fail-safe (unlocked on power loss)** or **fail-secure (locked)**
  deliberately. A bag that traps the zipper when the battery dies is worse
  than an unlocked bag. A latching solenoid keeps its last state with no
  current; a spring-return solenoid does not.
- Fuse the lock circuit; add a manual override; strain-relieve the wires; do
  not run the coil wires beside the Wi-Fi/Bluetooth antenna.
- A lock is casual tamper resistance, not security: fabric can be cut. Treat
  it as a "don't unzip it by accident" latch, not a safe.

### Control

- The board's 40-pin GPIO (3.3 V) drives the servo/MOSFET; a small service or
  a shell script owns the pin. A button or a keypad is simpler and safer than
  a network unlock; if the phone is to unlock it, put that behind the house
  session and a deliberate second press, the way destructive controls work.
- Report the lock state (limit switch or servo position) in the pane; a lock
  you cannot see is a lock you will forget.

### Budget

- Servo latch: **~CAD 20–35**.
- Solenoid (5 V/12 V, continuous): **~CAD 40–70**, plus a 12 V pack (~20–40)
  if you do not already have one.
- Latching solenoid: **~CAD 50–90**, plus the 12 V pack.
- Add **~CAD 10–20** for the bracket/webbing/sewing consumables.

## The pack: three depths

### Level 0 — buy a patch-friendly pack and a patch (no sewing)

- A pack with a **Velcro patch field** and/or **MOLLE/PALS** webbing, plus a
  padded laptop/tablet sleeve: 5.11 Rush 12 (~150), Condor Urban Go Pack
  (~90), Helikon-Tex EDC (~120), Direct Action Dragon Egg (~180), or a budget
  MOLLE pack (~60).
- A **padded electronics pouch** or camera insert (~25–40) for the board,
  bank and cables.
- A **custom patch** (15–30 one-off; 5–10 each in bulk): embroidered with a
  Velcro backing, or PVC. A Velcro panel can be sewn onto any pack; a
  MOLLE patch panel (~10–20) adds a field.
- **Total:** ~CAD 100–250 on top of the board kit; no machine, no pattern.

### Level 1 — sew the insert (beginner)

A zip pouch with a padded divider, a mesh window and a cable pass-through is
the right first sewing project: straight seams, one zipper, no curves.

- **Cut list (approx.):** 22 × 13 × 6 cm body; a 1 cm seam allowance; a
  divider; a mesh window; a 1" webbing handle; a Velcro patch panel.
- **Materials:** 500D Cordura (~0.5 yd, 10–15), 210D liner (5), spacer mesh
  (5), #5 YKK zipper (5), 1" webbing (5), Velcro (5), bonded nylon thread
  (5), needles/clips (10). **~CAD 40–60.**
- **Tools:** a sewing machine (150–300 if not owned), rotary cutter/mat/ruler
  (~40), seam ripper, iron, clips.
- **Add:** a grommet or bound slot for the USB-C cable; a mesh vent over the
  board's heatsink; a clear label window with the gateway name; a
  "do not charge in the bag" tag.
- This teaches the skills for a full pack without committing to one.

### Level 2 — modify a generic pack

Add a padded sleeve, a cable port, a mesh vent and a MOLLE panel to a pack
you already like. This is the best effort-to-result step if the pack is
otherwise right.

### Level 3 — sew a full backpack (advanced)

A pattern (LearnMYOG, Bag Buff, Prickly Gorse), 500D/1000D Cordura, foam,
spacer mesh, webbing, buckles, YKK zippers, bartacks. Materials ~CAD 100–150
plus tools and time. It is a separate hobby project; the gateway only needs
Level 0 or 1.

## Patch options

- **Embroidered patch, Velcro backing:** best for a logo; one-off 15–30;
  bulk (10+) 5–10 each. The embroiderer digitizes the logo (DST/PES); ask for
  a proof.
- **PVC patch:** waterproof and durable; 8–15 each in bulk.
- **Woven label:** 1–3 each in bulk; sew-on, not Velcro.
- **Where:** a local embroiderer, Etsy, Sticker Mule (PVC), Dutch Label Shop
  (woven). A one-off is fine for a prototype; bulk only after the logo is
  settled.

## Safety and bag hygiene

- The power bank is the fire risk: a quality bank, a LiPo-safe pouch, no
  charging in a closed bag, and no cheap no-name cells.
- Vent the board; keep the antenna end clear of the bank and any metal.
- Strain-relieve the USB-C cable; a right-angle adapter saves the port.
- A power switch or a UPS button; a visible label so the bag's owner knows
  what is running.
- Keep the phone and the gateway in the same bag or on the same person;
  Bluetooth is the link, and the tailnet is the network.

## Sources (check stock and price)

- **Boards:** PiShop.ca, BuyPi.ca, Canada Computers, Amazon.ca; Radxa
  distributors (ALLNET, Arace) or Digi-Key/Mouser Canada; Radxa's own store.
- **Power/storage:** Amazon.ca, Canada Computers, Memory Express; a
  high-endurance card from a reputable brand.
- **Fabric/sewing:** local fabric stores, Fabricland, Sailrite (Canada),
  Ripstop by the Roll (US), Bag Buff and LearnMYOG patterns.
- **Patches:** local embroiderer, Etsy, Sticker Mule, Dutch Label Shop.
- **Servos/solenoids:** Amazon.ca, Canaduino, SparkFun/Adafruit (US), local
  electronics; 3D printing at a local library or an online print service.

## Minimum viable vs. ambitious

- **Minimum viable:** board + shared kit + a patch-friendly pack + a padded
  pouch + a patch. No sewing, ~CAD 350–500 all in *without* a lock.
- **Ambitious:** the same, plus a sewn insert and patch panel. +CAD 40–100 in
  materials, plus a machine if needed.
- **With a lock:** add ~CAD 20–90 (servo to latching solenoid) and the
  mechanical work; it is a Level 2/3 sewing/printing project.
- **Full pack:** a pattern and a full sew; +CAD 150–350 and a lot of time. Not
  required for the gateway.

## Open questions

1. **Pi 4 or Rock 4B+?** The Pi is the safer support story; the Rock's eMMC is
   the safer storage story. If the board is hard to buy, the Rock 3C 4 GB or
   the Zero 3W 4 GB are the fallbacks, with the wireless-module caveat in
   `docs/ivr-hierarchy.md`.
2. **UPS or pass-through bank?** A UPS HAT buys a clean shutdown; a bank with
   pass-through is lighter and cheaper. The eMMC/SSD choice changes the risk.
3. **How much sewing?** Level 0 is enough to ship; Level 1 is the learning
   project; Level 3 is its own hobby.
4. **Logo format.** A vector logo is needed for embroidery; a high-res PNG
   can be digitized, but a clean SVG is cheaper and sharper.
5. **Carry style.** A dedicated electronics pouch inside a daily pack is
   easier than a built-in pocket; the latter is nicer but harder to service.
6. **Zipper lock: servo or solenoid?** A servo is simpler and lower power; a
   latching solenoid is stronger and silent when set. Decide fail-safe vs.
   fail-secure and where the manual release lives before cutting the pack.
