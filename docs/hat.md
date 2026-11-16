# The JawnHat — a displayless sensor cap for JawnOS

Status: prototype. Not built yet. This is the plan, the parts, and the reasons.

## Why no display

The hat started as an AR project: overlay `home_plate` and nearby places on the world, in view. That
was dropped deliberately, and the reason is registration, not money. A marker needs roughly a tenth of
a degree of angular accuracy to sit still on a real object. Cheap tracking — GPS plus a consumer IMU —
lands within five to fifteen degrees. A marker ten degrees off looks broken; a voice ten degrees off
sounds fine.

So the hat carries no optics. It senses, it speaks, and it buzzes. The visual output goes to screens
JawnOS already has.

## What it is

A BLE peripheral on a cap brim. Five capabilities:

- **Hears.** Wake word, then a mic array at the brim front.
- **Sees.** A forward camera, fired on request — no viewfinder needed.
- **Knows which way it faces.** An IMU, so any answer can be given relative to the wearer.
- **Answers in the ear.** Bone conduction at the temples, panned by head pose.
- **Ticks.** A coin vibration motor, so direction can be felt without sound.

Visual output is routed, not worn:

| Where | What | Why |
| --- | --- | --- |
| `jw` JawnWatch (T-Watch S3) | 240x240 LVGL, glanceable card | already built, already BLE, already on the wrist |
| `jt` JawnTeletype (T-Deck) | bigger screen, keyboard, GPS, LoRa | the controller for typing and maps |
| `/manager/travel/viewer` | the full Travel view on any screen | already a standalone, parameterised page |

The hat is therefore not a computer. It is a peripheral, and that choice is what makes it cheap and
certifiable.

## Interaction

- **Walk.** A tick in the right ear grows as you turn toward the place; the voice says "two blocks,
  behind your left". Head-tracked, so it stays true as you turn.
- **Look and ask.** "What is this?" The frame goes to JawnOS, the answer comes back in the ear. This is
  better than a viewfinder for the guide job — no framing, no squinting.
- **Log.** "Here, this one." The frame lands in the Camera app's unclaimed media with GPS and heading
  attached, ready for Travel.
- **Talk.** Full guide conversation through the wake word.

### The one honest loss

Audio cannot say *which* of five identical houses you are looking at. Vision could. The mitigation is
description ("the blue one with the red door, on your right"), and the camera still gives identity on
demand. A forgiving trade, but a real one.

## Mechanical design

Electronics are hidden, and split to the two sides of the cap so the weight balances. Nothing rides at
the very front of the brim — that is the longest moment arm and the first place a cap droops.

| Location | Carries | Rough mass |
| --- | --- | --- |
| Left crown pod | 1000 mAh LiPo (or 800 mAh, the largest cell Solarbotics stocks) + TP4056 charger | ~22 g |
| Right crown pod | ESP32-S3 board, amp, IMU | ~6 g |
| Brim front, flex tail from the right pod | camera + two mics | ~3 g |
| Temples, inside the sweatband | bone conduction transducers | ~10 g |
| Brim edge, left | coin vibration motor | ~2 g |
| Cable channel along the brim seam | wiring, connectors | ~10 g |

Target: **under 90 g added**, with left and right within about 5 g of each other, measured on a
kitchen scale. Pods sit inside the crown behind the sweatband, under a fabric flap; the cap shell stays
cosmetically untouched.

The bone conduction transducers must contact the temporal bone. The sweatband presses them there for
free — the reason this build suits a cap rather than glasses.

## Parts, Canadian prices (checked 2026-11-16)

Assumptions: 1.40 CAD/USD, HST at 13%. Only the Solarbotics rows are real prices seen on a Canadian
page. Every other figure is still an estimate, and is marked so, because digikey.ca, RobotShop,
Amazon.ca and Lee's Electronic all refuse scripted fetches. Confirm in a browser before ordering.

DigiKey.ca ships free over CAD 100, so bundle the stockable parts.

**Do not use creatroninc.com.** The domain no longer belongs to the Toronto store: it now serves
unrelated SEO spam and redirects to a subdomain. Treat any link from it as unsafe, which is why no row
below names it as a source.

| Part | AliExpress | Canadian | Seen in CA? | Notes |
| --- | --- | --- | --- | --- |
| XIAO ESP32S3 Sense | 19 | ~26 | **estimate** | DigiKey.ca or RobotShop; both need a real browser |
| ICM-20948 breakout | 10 | ~30 | **estimate** | genuine SparkFun ~30; clone modules fine here |
| Bone conduction pair | 12 | — | **not stocked** | confirmed absent from Solarbotics; AliExpress only |
| MAX98357A amp | 6 | ~9 | **estimate** | |
| TP4056 charger | 3 | ~5 | **estimate** | |
| Coin vibration motor | 3 | **3.80 / 5.59** | **verified** | Solarbotics; the 3.80 one is store-only, phone to order |
| LiPo 3.7 V, one cell | 11 (1000 mAh) | **12.99 (800 mAh) / 18.29 (1700 mAh)** | **verified** | Solarbotics; no 1000 mAh SKU exists in Canada |
| Breadboard + jumpers | 8 | **4.50 (170-hole) / 12.60 (board + zipwire)** | **verified** | Solarbotics; 400-point solderless not confirmed |
| Wire, foam, JST, heat shrink | 10 | ~15 | **estimate** | Sayal or Lee's if nearby |

Confirmed Solarbotics (Calgary) figures, all pre-tax and in stock at the time of checking: 400 mAh
8.79, 800 mAh 12.99, 1700 mAh 18.29, mini vibration motor 3.80, vibrating disk motor 5.59, 170-hole
solderless breadboard 4.50, breadboard plus zipwire bundle 12.60. Several of those carry an "In Stock
- Store Only" flag and need a phone order rather than a web checkout.

What that costs: roughly CAD 95 through AliExpress, or about CAD 135 from Canadian vendors if the
estimates hold, before tax. The unverified rows are where that number can move most.

Practical: buy the Canadian-stocked parts locally and AliExpress only the bone conduction and the
spares. Budget about CAD 100 and order two of the cheap parts.

Two customs notes: never let a parts order ship courier — DHL or UPS brokerage often exceeds the part
cost — and electronics from China are generally MFN duty-free, so it is tax plus small handling.

The LiPo connector (JST-PH versus JST-SH) is the most common "part arrived, does not fit" failure;
order the matching pigtail at the same time.

**The breadboards are for Phase 0 and never worn.** They add 40-60 g and a lot of volume; the worn
build has none.

## JawnOS integration

Everything the hat needs already exists in the tree:

- `home_plate` is a JSON setting on `app=me`, published by the mobile view (see
  `lib/JawnOS/Manager/Part13.pm`), read back through `setting_grabber`.
- `public/js/manager/travel/03_near3d.js` already converts lat/lon to local metres about a centre, and
  already draws a place as a house, a pin and a label, with tag decluttering.
- `/manager/travel/viewer` is a standalone parameterised page — the render target for the watch, the
  handheld and any borrowed screen.
- The Camera app takes unclaimed media, which is where a logged frame belongs.
- `jt` and `jw` already carry the wake word, the mic array, the audio pipeline, BLE, and the OTA sweep.

New firmware would be a fifth PlatformIO target beside `jp`, `jt` and `jw` — say `jh` — reusing `jt`'s
skeleton rather than starting fresh.

Because `travel/viewer` is a plain page, the hat stays hardware-independent: the same view serves this
cap, a used pair of glasses, a phone, or anything that arrives later.

## Roadmap

### Phase 0 — Bench proof of concept

Breadboards, no cap. Prove the loop end to end: wake word, then a camera frame to JawnOS, then an
answer, then speech in the ear. Prove IMU heading is stable on a desk.

*Exit:* stand in a room, say the wake word, ask what is in front, and hear a correct answer.
*Cost:* electronics only.

### Phase 1 — Wearable proof of concept

Into the cap, split across the two pods. Measure what a breadboard hides: two-hour comfort, real
battery life, whether the tick gives usable direction, wind noise on the brim mics.

*Exit:* walk to a known `home_plate` and arrive using only audio and haptics.

### Phase 2 — Display handoff

Route the visual layer to `jw` and `jt` over the existing BLE path.

*Exit:* a glanceable Travel card on the wrist and a typed command surface on the handheld, with no
display on the hat.

### Phase 3 — Field trial

Real trips. No new features — only fixes, and a written failure list.

*Exit:* five consecutive trips with no intervention.

### Phase 4 — Design for manufacture

- Custom PCB instead of breakouts, with a flex tail into the brim.
- **Certification is the gate, not the electronics.** A radio device sold in Canada needs ISED; the US
  needs FCC. The cost-saving route is a pre-certified module — the ESP32-S3 module carries its own FCC
  ID and ISED — with the antenna layout left exactly as specified, inheriting the module's
  certification instead of paying for full testing.
- UN38.3 for the lithium cell, plus a genuine safety review of a battery worn on the head.
- Soft-goods or enclosure tooling, connector selection, and a test jig.

*Exit:* a rev-B prototype someone else can assemble from a drawing.

### Phase 5 — Small batch

Ten to fifty units through JLCPCB or PCBWay assembly plus hand assembly.

*Realistic math:* the BOM falls to roughly CAD 35-50 per unit at fifty pieces, but NRE — PCB design,
certification, tooling — is CAD 3-10k **before unit one**. That is the decision point, not the parts
cost.

## Open questions

1. Camera frame rate the board can sustain while streaming.
2. Whether wind noise on a brim mic is tolerable, or the array needs a different baffle.
3. Whether the tick or the voice carries direction better in practice — the field trial decides.
4. Where the GPS fix comes from: the phone, or `jt`'s receiver over BLE.
5. Whether phase 5 is a kit, a finished product, or a small run for personal use — the answer changes
   how much certification is worth buying.
