# IT Strip — roadmap note (deferred)

**Status:** idea captured 2026-10-25. Not scheduled. Nothing built.
**One line:** a customer-owned USB dongle they plug in and *arm* when something breaks, so the
tech (with AI assistance) can drive the machine out-of-band — then unplug it and put it away.

## Why it is not "remote desktop, but hardware"

Remote desktop already covers a machine that boots and has internet. The strip wins only on what
software cannot do:

- **UL/secure desktop input.** Windows ignores synthetic input at UAC and on the lock screen;
  real USB HID is accepted. So are BitLocker pre-boot and UEFI setup.
- **Nothing installed, nothing left behind.** No service, no agent, no stored credential.
  That is the answer for a customer who was just phished.
- **Zero-install** on a machine whose remote access is broken or malware-disabled.
- **It can be their network adapter** when the internet is down (USB NIC → Wi-Fi or phone hotspot).

## The two SKUs (do not collapse these)

| | **Stick** (~$10 BOM) | **Box** (+ HDMI in/out passthrough, ~$35 BOM) |
| --- | --- | --- |
| HID keyboard/mouse | yes | yes |
| Screen | software capture once in | always — BIOS, lock screen, dead OS |
| Dead machine | no | yes |
| Typical calls | slow PC, popups, phishing mail, cleanup, settings | no boot, BSOD loop, ransomware, BIOS |

Ship the stick first. Most calls are the left column, and the box costs $20 of capture hardware
plus certification. The box is a premium tier, not the entry product.

## The arming rule (non-negotiable)

**The device cannot be activated remotely.** A physical button press by the person holding it is
the only way a session starts. No persistent tunnel, no inbound port, no sleeping agent. This is
what makes it a key the owner turns rather than an implant in a stranger's house, and it is the
pitch: *"It can't be switched on unless you press it. Unplugged, it's a rock."*

Session UX to match the rule:

- LEDs: green idle · amber connected · red while injecting.
- **Pause my keyboard** — the customer types their own password while the tech watches, with
  "customer is typing" shown on the tech side. Nobody ships this today; it is the trust moment.
- **Shred** at the end: drop the tunnel, drop HID, clear state.
- **End-of-session report** is the deliverable: what was found, removed, and what to watch for.
  It is also the tech's defence if a customer later claims damage.

## Architecture (when it is built)

- **Firmware:** fork the `jp/alarmclock` shape (Pico 2 W, HTTPS + device token to the manager,
  OTA, 2 MB LittleFS split). Add composite HID + CDC. Stage every build via
  `scripts/stage_firmware.pl`; reuse the `app_release` OTA pattern so a strip that sat in a drawer
  updates before the call.
- **Relay:** dial-out only, behind NAT, revocable per device. Per-device keys in hardware.
- **Manager:** an `it_strip` app — `/manager/it_strip`, `templates/apps/it_strip.html.ep`,
  `public/js/manager/it_strip.js`. Live view, AI suggestion with approve/deny, pause-keyboard,
  shred, report. Log every injected keystroke and every returned line.
- **Agent:** reuse `subs::evaluation_model_call` with tools `screenshot / ocr / type / key /
  click / serial_run / wait`. Destructive verbs (`diskpart`, `bcdedit`, `format`,
  `Remove-Item -Recurse`, registry wipes) require human approval, always.
- **Return channel (the part that makes diagnostics real):** the strip presents HID + CDC, so the
  target gets a `COMx`. Injected commands pipe exact text back both ways — no OCR. The fast tier
  is a one-line PowerShell socket back to the manager (full shell, file transfer, and
  `CopyFromScreen` screenshots). Be honest: that tier is mechanically an RAT bootstrap; Defender
  and AMSI will flag it, so it needs a signed payload, a trusted host, and an allow-list story.
- **Offline forensics** is a separate mode on the JawnOS host: mount the customer's disk read-only
  and read event logs, registry hives, Amcache/ShimCache, prefetch, `$MFT`. BitLocker blocks it —
  no recovery key, no analysis.

## Costs that gate a real product

- **USB Vendor ID** — own VID or a licensed suballocation (`pid.codes` is for experimentation,
  not retail).
- **FCC / CE / UKCA** for the radio-equipped final assembly. The Pico W module's modular cert
  helps, but the enclosure and antenna are ours.
- RoHS, returns/replacement, liability insurance.
- Expect a few thousand dollars and a couple of months, not a weekend. Decide this before
  promising a ship date.

## Certification and risk notes

- **Certification is the schedule.** Firmware is a weekend; the marks are the project.
- **A relay breach is a fleet of remote implants** in customers' homes. Arming rule, per-device
  keys, one-click revocation, and no stored Wi-Fi password are the mitigations.
- **Never store the customer's Wi-Fi password** on the device — reprovision at plug-in (captive
  portal from their phone, phone hotspot, or the USB-NIC path).
- **Keyboard layout:** HID scancodes are US-layout; a non-US target turns `ipconfig` into
  gibberish. Detect, or ask, before injecting layout-sensitive punctuation.
- **Typing speed:** 10–20 ms between keys. Faster drops characters, and superhuman typing is an
  anomaly some EDR watches for.
- **Mouse in UEFI** is unreliable; keyboard-only is the firmware contract.
- **A customer who sells the house leaves the dongle behind.** Revocable, per-device identity.
- **Privacy:** seeing the screen means seeing their personal data. Session recording, retention
  policy, and a signed remote-access agreement are part of the product, not paperwork.

## Phase plan

| Phase | Deliverable | Gate |
| --- | --- | --- |
| 0 | Pico 2 W as composite HID + CDC; manager route "type this string"; proven on a Windows VM | bench |
| 1 | Return channel: PowerShell serial loop, exact text for `whoami` / `ipconfig` / `Get-WinEvent` | bench |
| 2 | Manager `it_strip` app: live view, AI suggestion, approve/deny, pause-keyboard, shred, report | 5 friendly customers |
| 3 | Decide the box (HDMI passthrough) from recorded call data | evidence, not enthusiasm |
| 4 | Certification, per-device keys, revocation | business decision |

**The experiment that decides everything:** five sticks with friendly customers, free, and record
what the calls actually are. Do not build the box until a call proves it is needed.

## Open questions

- Relay: self-hosted per house, or one shared relay with per-device keys?
- Does the stick need a battery-backed clock for log timestamps, or is target time enough?
- Support Windows only first, or macOS/Linux HID too (same firmware, different UX)?
- Pricing: device + monthly, or per-incident with the device as a loss-leader?
- Where does the AI's "next command" suggestion live — manager UI only, or also a phone view for
  the tech on a call?
