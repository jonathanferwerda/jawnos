# Facts that save a search (verified 2026-11-02)

Read this when a question is about the data model, the journal, maps or chat.

**Data model.** `appointments` is the big table; satellites: `warehouse`, `mailbox`, `notes`,
`model`/`option`/`subcategory`, `continent`, `magazine`, `credentials`, `devices`. Sync: `sync_log`,
`sync_cursors`, `sync_jobs`, `sync_snapshots`, `staged_appointments`. Every synced table carries `ost`
and `server_time` or the rail skips it. Schema: `database/schema.sql`; deep notes: `docs/AGENTS-notes.md`.

**Journal is a use case, not a table** — `notes` plus the Handbook, no `journal` table or template.
**Maps are measured images** — `public/js/manager/mapengine.js` places a scan by a `home_plate` pixel +
scale bar; `travel.js` is the picker; coordinates live in `continent`, no `maps` table.
**Chat is a set of roads** — `templates/apps/chat.html.ep` sections `sms, dial, list, tickets, rooms,
lora`; SMS/MMS via the Android app, LoRa via the T-Watch/T-Deck. **WebRTC is not a transport yet** (the
only code is `public/js/manager/jp/01_watcher_webrtc.js`); the destination is per-thread (`chat.js`).
