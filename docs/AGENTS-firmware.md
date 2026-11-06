# Firmware / OTA (stage every build)

Moved out of `AGENTS.md` (a per-task reference, not an every-request map).

## Firmware / OTA (stage every build)

The manager serves device firmware from **hardwired paths**, not from a device's `.pio/build/`. An
unstaged build means an OTA sends the previous firmware.

- **alarmclock (Pico 2 W)** — OTA reads
  `jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin`. After `pio run` in
  `jp/alarmclock`, run `perl scripts/stage_firmware.pl` (or `--build` to build first). It copies
  `.pio/build/pico2w/firmware.bin` onto that path; add an entry to its `@targets` when another
  device gains a hardwired OTA path.
- **Versions are per board.** Each firmware project carries its own `VERSION` — `jt/VERSION` (deck),
  `jw/VERSION` (watch), `jp/alarmclock/VERSION` (Pico). `scripts/fw_version.py` stamps the nearest one
  into the build, and `scripts/stage_firmware.pl` writes it into the sidecar the manager reads, so a
  board is only "behind" relative to its own number: the house moving on does not make every device
  look stale. **A change to a board's firmware bumps that board's version in the same commit** —
  `perl scripts/fw_bump.pl deck|watch|alarmclock` (patch bump; `--list` shows all three) — then build
  and stage. Staging warns when an image's firmware sources changed but its version did not: the device
  would otherwise report the new image under the old number and read as up to date for ever.
- **OTA needs a LittleFS partition.** `jp/alarmclock/platformio.ini` sets
  `board_build.filesystem_size = 2M` (2 MB sketch + 2 MB filesystem). The default 0 MB filesystem
  leaves the uploaded image nowhere to live and the new firmware boots without `config.txt`, so
  the device drops to its AP. Keep the split when changing the build.
- **ESP32 boards** — the panel hands over the picked `.bin` (`ota_uploader_wifi`), so pick the build
  from that device's `.pio/build/<env>/`; `usb_upload` builds on the machine over USB.
- **LoRaWAN (T-Deck SX1262)** — Chat's **LoRa** section owns the network mode. Credentials are
  `mail/lorawan_*` settings (band, sub-band, Join/Dev EUI, App key, port, confirmed); the manager
  pushes them to the deck's `/lorawan_config` and drives `/lorawan_join`, `/lorawan_send` and
  `/lorawan_status`. A LoRaWAN network server forwards uplinks to `/watch/lorawan?token=…` (the URL
  is shown in the panel), and downlinks reach `/watch/chat_received?transport=lorawan`. While
  LoRaWAN is on, the old raw-LoRa point-to-point broadcast/receive stand down. Build and stage the
  firmware with the same `stage_firmware.pl` path before an OTA.
