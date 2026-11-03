# Encrypted app databases and the DB broker

Status: design, 2026-11-03. Companion to `docs/app-databases.md` and `docs/app-sandbox.md`.

Can an app's database be encrypted so only that app can open it, with the data streaming over a
socket (or several directional sockets) for throughput?

**Yes — and the strongest form does not give the app the key at all.** A per-app **broker** owns the
key and the file; the app speaks a framed protocol over Unix sockets. That is both the security and
the performance answer.

## Two key models

| Model | Who holds the key | Who opens the file | Use |
|---|---|---|---|
| **broker-held** | the broker (outside the sandbox) | the broker | sandboxed apps — the default |
| **app-held** | the app, injected at start | the app | standalone apps (Solo), where there is no broker |

"Only that app can open it" is enforced differently in each:

- broker-held: the app has **no path and no key**. The socket token and `SO_PEERCRED` decide which
  app may call the broker. Even a full escape from the app sandbox finds no key.
- app-held: the key arrives through an inherited `memfd` (or a pipe), is `mlock`ed, and is never in
  `argv` or the environment. The file is encrypted at rest; another app has a different key.

## Key hierarchy

```
K_house ──HKDF-SHA256(salt="jawnos-app", info=name||version)──▶ K_app
K_app   ──SQLCipher key / container secret / row key
```

- `K_app` is derived per app (and optionally per version). A version bump can rotate it.
- The host stores only a wrapped copy of `K_app` (under `K_house`), never `K_house` itself in an app
  database.
- House-key rotation rewraps `K_app` (or rekeys the DB); it does not require re-sealing every row.
- Uninstall deletes the wrapped `K_app` and the file: **crypto-shredding**. A backup of the file
  without the key is inert.
- Standalone mode derives `K_app` from the local master key (OS keyring) or a passphrase; the same
  hierarchy, a different root.

## Encrypting the file: a ladder, because SQLite needs random access

The existing house container (`Domain/Note.pm`) is `Salted__` + 8-byte salt + ciphertext, keyed by
PBKDF2-HMAC-SHA256, and `note_open_slice` can decrypt an arbitrary byte range (CTR is seekable by
advancing the IV; CBC starts at the block with the previous ciphertext block as IV). That is a
**read-side** capability. A live SQLite database also writes pages at random offsets, so a whole-file
container cannot be the working file.

Four options, in increasing strength:

| Mode | How | Trade-off |
|---|---|---|
| `row` | AES-GCM on sensitive columns/blobs; the rest of the DB is plaintext | Portable, incremental, no build; leaks schema, row counts, indexes, timing |
| `snapshot` | broker decrypts the DB into a tmpfs file at start, SQLite runs there, the host seals a snapshot on checkpoint/interval | Portable, uses the existing container; a crash can lose changes since the last seal; whole-file seal cost |
| `sqlcipher` | SQLite pages encrypted by SQLCipher; the broker opens with the key | The right answer for a live DB; **not a standard DBD::SQLite build** — a compile/link project, hardest on Android |
| `volume` | encrypted filesystem (`fscrypt`, LUKS, `gocryptfs`) mounted outside the sandbox | Strong at rest; desktop/OS only (FUSE and LUKS need capabilities Termux does not have); the key is in the kernel, not the app |

Recommended default: **`sqlcipher` on desktop/OS where the build is controlled, `snapshot` or `row`
on Android**, and always `broker-held` for sandboxed apps. The mode is recorded per app and shown in
the UI; the assurance must be honest, as with the sandbox level.

Platform notes:

- **Android**: the app's private storage is already FBE-encrypted at rest with the device key — that
  protects a stolen phone, not JawnOS from an app. SQLCipher in the Termux runtime is a build burden;
  `snapshot` + a small app DB is the practical first step.
- **Desktop**: SQLCipher is buildable; `gocryptfs` is a user-space fallback if a per-app mount is
  preferred.
- **Installed OS**: a per-app SQLCipher DB, or `fscrypt`/LUKS per app when the image controls the
  filesystem; systemd `StateDirectory` already gives the right directory and ownership.

## The broker

One process per app (simplest isolation) or one broker with per-app keys (more efficient). It runs
**outside the app sandbox**, under the host's user/unit, and owns:

- `K_app` (unwrapped in memory, `mlock`ed where available) and the encrypted file;
- the schema allowlist: only `app_<name>` tables, only declared columns; no `ATTACH`, no
  `load_extension`, no writable `PRAGMA`, no DDL outside migrations;
- quotas: statement timeout, max rows per response, max bytes per request, rate limit;
- the sync log writes and the backup snapshot hook.

Input validation is the whole game. Raw SQL from an untrusted app is a hole; the safe default is a
**typed CRUD API** (select/insert/update/delete with table and column names checked against the
manifest). Raw SQL is a capability for `human-reviewed` apps, still behind a SQLite authorizer and
the schema allowlist.

Crash isolation: a broker crash must not take the host. It is a child with a warranty/heartbeat
(`Domain/Process.pm` is the model) and restart-on-failure; a wedged broker is killed and its app
marked degraded.

## Transport: directional sockets

Yes — a family of unidirectional channels instead of one shared stream, so a long `SELECT` cannot
block a health ping or an event:

| Channel | Direction | Framing | Purpose |
|---|---|---|---|
| `control.sock` | app → broker | small length-prefixed frames (`SOCK_SEQPACKET`) | hello/auth, prepare, execute, cancel, ping |
| `rows.sock` | broker → app | binary row frames, batched | result sets |
| `blobs.sock` | both, one direction per stream | raw bytes | large blobs, file-like reads |
| `events.sock` | broker → app | small frames | change notifications, quota warnings |

Details that matter:

- **Handshake**: first frame carries `{ version, app, token }`. On Linux, `SO_PEERCRED` gives the
  peer PID/UID; with the `systemd` backend and `DynamicUser`, the UID is unique and the check is
  strong. On Android the UID is shared, so the token is the check.
- **Framing**: 1-byte type + 4-byte length + payload, or `SOCK_SEQPACKET` for control. Rows are
  binary (length-prefixed columns), not JSON; JSON is for control only.
- **Throughput**: batch rows into 64–256 KB frames; `sendmsg` with `MSG_MORE`; `splice()` from a
  memfd/temp file for blobs; prepared statements; WAL. Unix sockets are not the bottleneck — SQLite
  and encryption are — so measure before adding shared memory.
- **Backpressure**: each channel has its own buffer; a slow reader on `rows.sock` does not stall
  `control.sock`. The broker applies per-channel pauses (`MSG_DONTWAIT`, `poll`/`epoll`).
- **Shared memory (later)**: if the bulk path is measured short, a `memfd` ring + `eventfd` for
  result pages beats sockets; keep the sockets for control and fall back to the ring only for large
  payloads.
- **Mounts**: the app sees the four socket files in its runtime dir; it sees no database path. The
  sandbox bind-mounts exactly those sockets, nothing else.

## Backup, sync, rotation

- **Backup**: the host snapshots the encrypted file (SQLCipher) or asks the broker for a sealed
  snapshot (`snapshot` mode) under the export lock. The bundle carries the encrypted app DB plus the
  wrapped `K_app`; restore needs the host key.
- **Sync**: rows leave the broker decrypted and are re-encrypted by the existing sync rail; the
  broker (or the host on commit) writes `sync_log` with `{ db, table }` as in
  `docs/app-databases.md`. The app never writes the sync log.
- **Rotation**: `PRAGMA rekey` for SQLCipher, re-wrap for `snapshot`/`row`, and the existing
  house-key rotation gets one more step. A rotated key invalidates old backups unless their `K_app`
  was wrapped under the old key and kept.
- **Uninstall**: stop the broker, detach the schema, delete the file and `K_app` (purge), or keep both
  (keep-data). The tombstone still syncs; the key does not.

## Phases

| Phase | Work | Acceptance |
|---|---|---|
| DB1 | Broker + directional sockets + typed CRUD + token/`SO_PEERCRED`; plaintext DB under the broker | Gallery runs through the broker; the app has no DB path; quotas and cancel work |
| DB2 | `K_app` derivation, wrapped storage, `row` mode | An app key cannot read another app's rows; uninstall crypto-shreds |
| DB3 | `snapshot` mode (tmpfs + seal on checkpoint) | Restart restores; crash loses only the unsealed window; backup round-trips |
| DB4 | `sqlcipher` mode on desktop/OS (build, open, rekey) | Plain file is unreadable without the key; rekey works |
| DB5 | Android: SQLCipher or `snapshot` default, honest mode label | A rooted dump of the file yields no plaintext; the UI says which mode |
| DB6 | Shared-memory bulk path only if measured necessary | Throughput target met without changing the protocol |

## Risks

1. **SQLCipher is not free.** No `DBD::SQLCipher` on CPAN; it is a build of SQLite+DBD with the codec.
   Android makes that a real project. Do not promise it before it is built and tested on a device.
2. **`snapshot` mode has a loss window.** A crash loses changes since the last seal. Choose the seal
   interval against the app's write rate, and never call it "live encryption".
3. **Row mode leaks metadata.** Schema, counts, indexes and timing stay visible. Say so.
4. **The broker is the crown jewel.** It holds every app key and can read every app DB. Keep it small,
   outside the sandbox, with no network and no shell; compromise of the broker is compromise of the
   app data.
5. **Raw SQL is a capability.** A typed API is the default; an authorizer is mandatory for the
   exception.
6. **Key loss is data loss.** `K_app` wrapped under `K_house` is only as recoverable as the house key;
   the recovery drill must include an app DB.
7. **Android FBE is not per-app.** It protects a stolen device, not JawnOS from an app. Do not confuse
   the two in the UI.
8. **Performance.** Encryption plus a socket hop plus row framing is measurable on a phone. Benchmark
   the Gallery grid and the appointment write path before choosing the default mode.
