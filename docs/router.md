# The router

Status: design, 2026-11-03. Companion to `docs/app-sdk.md`, `docs/app-databases.md` and
`docs/app-sandbox.md`.

The router is the layer that lets an app talk to another app, to a database broker, to a browser and
to a peer without knowing which of those it is. It is the first new component to build, and apps are
wired into it one at a time.

**The rule that keeps it shippable:** the routing table and the policy are central; the bytes are
not. A single process that carries every stream would be a single point of failure and a bandwidth
bottleneck — and Music, the availability test, cannot depend on it until it is proven.

## What it routes

| Edge | Example | Transport |
|---|---|---|
| app ↔ app | Gallery asks Travel for a place name | `local` or `unix` |
| app ↔ host | settings, files, crypto, events | `local` (core) or `unix` (sandboxed) |
| app ↔ DB broker | typed CRUD for `app_<name>` | `unix` |
| app ↔ browser | layouts, text, chat, padlock state | `ws` |
| app ↔ stream | audio PCM, video frames, screenshare | `ws`, `unix`, `tunnel`, later WebRTC |
| local ↔ peer | presence, relay, sync control | `tunnel` |
| app ↔ app store | release records, bundles | HTTP via junderground |

It does not understand SQL, decrypt payloads or transcode media. Those are **providers**: the DB
broker, the crypto service, the media service. The router moves typed envelopes and keeps the ACL.

## The envelope

```perl
{
  v            => 1,
  id           => 'uuid',          # dedupe / reply correlation
  from         => 'app:gallery'    # or peer:<signatorial>, ui:<session>
  to           => 'db:gallery',    # or app:..., topic:..., stream:...
  kind         => 'rpc' | 'topic' | 'stream' | 'presence' | 'control' | 'blob',
  content_type => 'application/json',
  seq          => 0,               # per stream
  ttl          => 30,              # seconds, for ephemeral work
  reply_to     => 'id',            # for rpc
  caps         => { ... },         # requested/required capability
}
```

- **rpc** — request/response; at-most-once by default, at-least-once with an id and a dedupe window
  for durable work. No exactly-once promise.
- **topic** — pub/sub; ephemeral unless a durable topic is backed by the host's event log.
- **stream** — ordered frames with credits; the drop policy is per content type (see below).
- **presence** — who is connected, used by the UI and by peers.
- **control** — open/close/credit/ping, never dropped.
- **blob** — a large payload by reference (`sha256` + provider), so a 40 MB video does not become a
  JSON message.

## Transports (adapters behind one API)

| Adapter | Used by | Notes |
|---|---|---|
| `local` | host + core apps | a function call, no copying |
| `unix` | sandboxed apps, DB brokers | `SOCK_SEQPACKET` for control, `SOCK_STREAM` for streams; token + `SO_PEERCRED` |
| `ws` | browsers | JSON control + binary frames; one socket, many channels |
| `http` | uploads, fallbacks, store | request/response only |
| `tunnel` | peers | reuse `perl/tunnel.pl`'s channel multiplexing and `Mojo::Tunnel` |
| `memfd` | large blobs | shared memory ring, only if measured necessary |
| `webrtc` | video/screenshare | signalling through the router; media peer-to-peer or relayed |

The first three are enough for R0–R2. WebRTC is an option for R5, not a dependency.

## Frame format

Reuse what the tree already proves: a small binary header, not JSON, for data.

```
byte 0      type      (1 control, 2 data, 3 credit, 4 close, 5 ping)
bytes 1-4   channel   (big-endian, as tunnel.pl)
bytes 5-8   length
bytes 9-12  seq
bytes 13..  payload
```

Control frames carry JSON (small, human-readable). Data frames carry opaque bytes. `LogBus`'s
"JSON header + raw body" and `tunnel.pl`'s "4-byte channel + payload" are the two proven precedents;
the router unifies them.

## Delivery and backpressure

- **Credits per channel.** A producer may send only what the consumer has granted. High/low
  watermarks, not unbounded buffers.
- **Drop policy is content-aware, not generic:** a video frame may be dropped in favour of the
  latest; an audio gap is filled or the stream restarts; a chat line or a control frame is never
  dropped.
- **Quotas:** bytes/s, frames/s, max frame size, per-app channel count, and the sandbox's
  `MemoryMax`/`TasksMax` underneath.
- **Stalls are visible:** a channel that has been credit-starved or dropping for N seconds is a health
  signal, not a silent condition.

## Security and policy

- **Identity:** app token + `SO_PEERCRED` on Unix; browser session on `ws`; `peer_verify`/crest on
  peer links; store publishers signed.
- **ACL:** the manifest declares the edges (`provides`, `requires`, topics, content types). The
  router refuses an edge that is not declared, even if both ends are up.
- **Opaque payloads:** the router never decrypts; an encrypted chat or DB blob is bytes. The broker
  decrypts its own database; the app decrypts its own messages.
- **No ambient authority:** no app gets a DB handle, a file path or another app's socket; only the
  routes it declared.
- **Limits:** max frame, max channels, rate, TTL; a `blob` is fetched from a provider by hash, not
  trusted from the envelope.

## The database edge

"Databases talking to databases" is **broker RPC**, not a raw SQL channel:

- `db:<app>` is a provider registered with the router; the app sends typed CRUD frames
  (`docs/app-database-encryption.md`).
- A cross-app read is a capability call (`$host->app('places')`) or a broker-to-broker RPC, never a
  join across schemas.
- Change events (`photo.added`, `row.updated`) are **topic** messages produced by the broker; sync
  and backup consume them through the host, not through the stream path.

## The browser edge

One WebSocket per tab, many channels:

- `ui:<app>` for layouts, text, padlock state and toasts (replaces `Websocket::send` calls);
- `stream:<id>` for audio, video and screenshare;
- `chat:<id>` for message text and typing state.

The padlock/session gate that `Websocket.pl` applies today becomes a router policy: a locked house
drops non-lock channels, not a separate check in every sender.

## The stream edge

Music already proves the model: `perl/Music/04_music_websockets.pl` carries a 16-byte video header
(magic, media time, sequence) and JSON control on the same socket, with source and peer roles, and a
receiver overlay. The router generalizes that:

- content types: `audio/pcm`, `audio/opus`, `video/h264`, `image/jpeg`, `text/plain`,
  `application/json`, `application/x-jawnos-layout`, `application/x-jawnos-screen`,
  `application/octet-stream` (encrypted);
- signalling (open/close/seek/subtitle) is `control`; the picture is the `stream`;
- for a viewer count or bitrate above a threshold, the router **signals** a WebRTC/peer path and
  steps out of the media path; it is not a video server by default.

## Observability

Per channel: bytes, frames, drops, credit stalls, latency, reconnects. A router that cannot report
its own drops is not shippable. `Log::Ring` is the trace buffer; the health panel reads the counters;
the app's SLO includes the router's contribution.

## Failure and supervision

- The router worker is supervised like any other subprocessor: warranty, heartbeat, restart
  (`Domain/Process.pm` is the model).
- The `local` path keeps core routes working if the worker dies; socket and WS clients reconnect with
  backoff.
- **No persistent state in the router.** Subscriptions are ephemeral; durable events live in the host
  and its database. A restart loses channels, not data.

## Build order

| Phase | Work | Acceptance |
|---|---|---|
| R0 | Envelope + `local` + `unix` + RPC; the host API rides it; one app (Gallery) | Gallery talks to the host only through the router; tests for auth, ordering, reconnect |
| R1 | Topics + events + the DB broker channel | A broker change event reaches a subscriber; a cross-app capability call works |
| R2 | Streams + credits + drop policy; Music audio in **shadow** | PCM survives a slow consumer; v0 Music still serves; the switch flips back |
| R3 | `ws` adapter + UI channels; migrate `Websocket::send` | A browser tab receives a layout and a chat line over one socket, many channels |
| R4 | `tunnel` adapter + presence | Two machines exchange an RPC and a stream; a dead peer is detected |
| R5 | Video/screenshare signalling; WebRTC or relay; Music video in shadow | The Music checklist passes through the router, with v0 as the fallback |
| R6 | Quotas, observability, ACL audit, store/sandbox integration | Drop/stall metrics visible; an undeclared edge is refused |

Music is wired in **shadow** from R2 and cut over only when the Music invariant passes
(`docs/v1-strategy.md`). R0 ships alone first; no streams, no video, no peer.

## API sketch

```perl
my $router = JawnOS::Router->new(host => $host);

$router->register(app => 'gallery', transport => $sock);
$router->publish('ui:gallery', { type => 'refresh' });
$router->subscribe('events:photo.added', sub { my ($env) = @_; ... });

my $reply = $router->request('db:gallery', 'select', { table => 'albums' });

my $ch = $router->open('stream:music', to => 'peer:abc',
    content_type => 'audio/pcm', credits => 64);
$ch->write($pcm);
$ch->on_credit(sub { ... });
$ch->close;
```

## Risks

1. **God-router.** One process for all bytes is a SPOF and a bottleneck. Keep the table central, the
   data path adapter-local, and media peer-to-peer above a threshold.
2. **Backpressure bugs.** Credits are easy to get wrong; a slow consumer must stall its producer, not
   the host. Test with a deliberately slow reader.
3. **ACL gaps.** A routing layer with an ambient capability is worse than direct calls. The manifest
   declares edges; the router refuses the rest.
4. **Delivery semantics.** Do not promise exactly-once. Use ids and dedupe for durable work; accept
   at-most-once for streams.
5. **Latency.** An extra hop is real for audio and interactive text. Measure the Music path before
   and after; the `local` adapter exists so core apps pay nothing.
6. **A second host.** If the router starts holding settings, sessions or database state, it has
   become a second JawnOS. It holds subscriptions and counters only.
7. **Complexity before value.** Building every content type before one app is wired is how the
   router becomes a research project. R0 with Gallery is the whole first milestone.
8. **The credit card.** Music must keep its current direct path until the router's shadow passes the
   invariant; a router that is merely "probably fine" is not allowed on the serving path.
