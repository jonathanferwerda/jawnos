# The gateway's engine ports — a contract for Phase 4b

**Status:** draft, 2026-11-20. Written against trunk `v0.1.3447`, to be handed to
the audio-engine work. It is the engine half of `docs/ivr-hierarchy.md` Phase 4;
the house half (the backend seam, `ready`, the pane) landed in `v0.1.3438`.
**Phase 4b-1 is implemented in this change** (the same change that rewrote
“The plan” below into a socket command); 4b-2, the PCM move, is not.

The rule this note exists to protect: **the engine is optional.** A gateway must
be able to say `audio: pipewire` (today's `pactl` path) forever, and a phone must
never see "able" for a machine whose audio cannot carry the call.

## The call, as it stands

The phone answers a screened call and routes its audio to the Bluetooth
Hands-Free link. On the gateway machine the reception mixer (`JawnOS::Sco::Mixer`)
does three things with `pactl`:

- `jawn_call_in` — a null sink the Bluetooth source-output is moved into; its
  monitor is **the caller's voice**.
- `jawn_prompt` — a null sink the gateway plays prompts into; its monitor is
  remapped as `jawn_ivr_mic`, which the phone's SCO microphone reads.
- `jawn_ivr_mic` — that remap, presented to the call as the microphone.

`perl/sco/sco_helper.c` owns the call's PCM: it opens BlueALSA or spawns
`parec`/`pacat` (`--pipe-in`/`--pipe-out`), speaks 8 kHz mono s16le, and copies
the caller's voice to a tee FIFO for the transcript reader.

The engine already does part of this: `patchbay.rs` binds a `handset` source
from `jawn_call_in.monitor`, and its monitor bus already feeds the Listen path.
It writes only to its own output, and it does not bind `jawn_prompt`.

## The three ports

| port | engine's view | node | format at the boundary | today |
| --- | --- | --- | --- | --- |
| `gateway.call_in` | capture | `jawn_call_in.monitor` | 8 kHz mono s16le, resampled to the house rate | `{cmd:"gateway"}` bind (4b-1), or a `handset` source if the plan declares one |
| `gateway.prompt` | write | `jawn_prompt` | 8 kHz mono s16le, resampled from the house rate | helper's `pacat` |
| `gateway.monitor` | bus | a plan bus (default `gateway`) | both directions, 8 kHz mono for the reader | helper's `--tee` FIFO |

The engine's graph runs at the house rate; the call is 8 kHz. **The engine owns
that rate boundary**, the same way `Codec::Pcm16k` already resamples a small
device's input on receive. Nothing in the call path may assume 48 kHz on the
wire. In 4b-1 the capture asks `parec` for 8000/1 directly, so nothing is
resampled yet; the boundary becomes real when 4b-2 moves the PCM.

## The socket command (not the plan)

**The gateway does not ride the saved audio plan.** The Sound/Studio UI rewrites
the plan on every save — `audio_plan_normalize` returns only the four lists, so
any key it does not know is dropped — which means a `gateway` section would
vanish silently the first time a person edits the patchbay. The gateway is
machine-local and exists only while a call is up, which is the lifetime of a
control-socket command, not of a saved document. So it is three transient
commands, answered in the same one-object-per-line protocol:

```
{"cmd":"gateway","action":"bind","call_in":"jawn_call_in"}
{"cmd":"gateway","action":"release"}
{"cmd":"gateway","action":"status"}
```

- `bind` starts **one** capture of `<call_in>.monitor` through the same
  `system_capture.rs` mechanism as the system mix (`SystemCapture::start_sink`,
  generalised from a fixed source to any sink name), at 8 kHz mono. It answers
  `{"ok":true,"gateway":{...}}`. Binding while already bound is idempotent and
  keeps the first capture.
- A sink the machine cannot capture (no `parec`, or the server does not list
  the monitor source) still answers `ok` with `call_in:"silent"`. A missing
  sink is never fatal — the same rule the patchbay follows.
- `release` stops the capture and its worker: no child, no thread, no ring,
  and `call_in` returns to `off`.
- `status` answers the gateway object below, and an unknown action answers
  `{"ok":false,"error":"…"}`.

```json
"gateway": {
  "call_in": "captured" | "silent" | "off",
  "prompt": "silent",
  "monitor": "silent",
  "rate": 8000,
  "channels": 1,
  "peak": 0.0,
  "frames": 0
}
```

The same fragment is spliced into every `status` line (including the patch
line) and into the `patch` reply, so a page that already polls the engine sees
it without a second command. `off` means no bind has been made; `silent` on
`prompt`/`monitor` is the honest answer for 4b-1.

`call_in` is a **PipeWire sink name**, not a plan node id: the null sink is
owned by the reception mixer. The rate and width are fixed in 4b-1 (8000/1);
nothing in the call path assumes 48 kHz on the wire.

`JawnOS::Audio::Plan` is **not** touched: it keeps returning the four lists, and
an older engine stays compatible because it never sees a `gateway` key.

## What 4b-1 implements

1. **`gateway.call_in`** — one `parec` capture of `<call_in>.monitor`, exactly
   the system-mix mechanism (`system_capture.rs`): a 20 ms process latency, a
   lock-free ring, retries while the engine runs. The samples are **drained and
   dropped** on the engine's own worker, which keeps only a frame count and a
   peak level. 4b-1 writes no tee file, no WAV and no monitor bus, and does not
   touch `jawn_prompt`.
2. **`gateway.prompt`** and **`gateway.monitor`** — reported `silent`; their
   writers are 4b-2.

Failure to bind reports the port `silent`; it never fails the engine or the
patch.

## The helper (`sco_helper --engine`) — 4b-2

This section describes 4b-2; 4b-1 leaves the helper's `parec`/`pacat` path
exactly as it is.

New flag `--engine <socket>` (the same socket as `JawnOS::Audio::Engine`),
mutually exclusive with `--pipe-in`, `--pipe-out` and `--pcm`.

The helper keeps what only it can do: the Bluetooth/SCO link, the 8 kHz framing,
the flow's state lines, and the watchdog. It stops owning PCM. Two one-way
streams on the engine socket:

```
{"cmd":"gateway.in"}                 engine -> helper   (the caller's voice)
{"cmd":"gateway.out"}                helper -> engine   (the prompt audio)
```

Each is answered `{"ok":true}` and then carries frames:

```
u32 len | u32 seq | u64 master_sample | u32 reserved | len bytes of s16le mono
```

One frame per 10 ms (80 samples, 160 bytes at 8 kHz). `master_sample` is the
engine's clock for `gateway.in` and ignored for `gateway.out`. A second
`gateway.in` while one is open is refused — the house has one call at a time.

Two compatibility rules:

- **The transcript path does not move.** The engine writes the `gateway` bus to
  the same file the helper's `--tee` used (`~/.president/sco/tee.pcm`, the path
  `perl/sco/sco_helper.c` already opens), so `scripts/whisper_stream.py` and the
  transcript tests are untouched. The engine may replace the FIFO with its own
  monitor later; it must not change the reader.
- **An unbound gateway is not an error at startup.** `gateway.in` and
  `gateway.out` answer `{"ok":false,"error":"the gateway ports are not bound"}`;
  the helper exits non-zero and the armer records that reason.

## Ownership and lifecycle

- `Mixer` still creates and removes the null sinks and moves the Bluetooth
  streams (`prepare`/`attach`). The engine does **not** own the BlueZ device in
  4b; that is a later step, and mixing the two in one change is how a call ends
  up with two owners.
- The writer is lazy (first prompt frame in 4b-2) and the capture is bound by
the `gateway` command; both stop on `release` (helper close, or the mixer's
`detach`). A `quit` releases the capture too, so the engine never leaves a
`parec` child behind.
- One call at a time. `release` (helper close, or the mixer's `detach`) leaves no
  child process and no ring behind.

## Readiness and the advert

`JawnOS::Sco::Backend`'s `engine` backend reports ready only when all three hold:

1. the engine socket answers a status, and
2. its `gateway` object reports `call_in`/`prompt`/`monitor` all bound, and
3. the helper binary was built with `--engine`.

Otherwise `ready` is 0 with the engine's own reason, and the gateway uses
`pactl` if that is ready. `ivr.audio` is `engine` or `pipewire`; `able` is
`ready` plus the light-load gate. **The phone is unchanged**: it reads `able`,
`bluetooth`, and its own live `scoState`.

**4b-1 does not change readiness.** The engine still reports `prompt` and
`monitor` as `silent`, so `JawnOS::Sco::Backend`'s engine backend keeps
answering not-ready with "the engine has no gateway ports yet", and the advert
keeps saying `pipewire`. That file is not edited in 4b-1; readiness moves in
4b-2, when all three ports can be bound.

## Build it in two slices

**4b-1 (done in this change) — the truth, no PCM move.** The socket command
binds `call_in`, and the engine reports all three ports (the other two as
`silent`). The helper keeps `parec`/`pacat`; the engine only *reports*, keeps a
frame count and a peak, and drops the samples. Files: `engine/src/socket.rs`
(the command, the drain worker, the status fragment), `engine/src/system_capture.rs`
(`start_sink`/`monitor_name`), `engine/tests/socket.rs`. Readiness deliberately
stays `pipewire` (above).

**4b-2 — the engine carries the call.** `gateway.out`/`gateway.in` and
`sco_helper --engine`, so the engine owns the prompt and the capture, plus the
readiness rule above. Only after 4b-1 has run on the table for a real call.

Do not merge the two: 4b-1 is how the house learns whether the engine's ports are
real, and 4b-2 depends on that answer.

## Acceptance

1. Rust, null device (4b-1, done): `gateway bind` answers `call_in:"captured"`
   with a capture on `PATH`; without one it answers `silent` and the engine keeps
   serving; a second bind keeps the first capture; `release` returns to `off`
   with no child, thread or ring; the ring drops rather than blocks and the drain
   still answers a frame count and a peak.
2. Rust, proto (4b-2): a gateway frame round-trips; a short frame is refused.
3. Perl (4b-2): `Backend` says `engine` ready only with all three ports bound
   (fake socket); the advert's `audio`/`ready` follow; `ready` implies `able`
   when the load is light.
4. On the table (4b-2): one screened call with `audio=engine`, transcript filed;
   kill the engine mid-call — the gateway reports the drop and the watchdog ends
   the line; the next call falls back to `pactl` if the engine is not ready.
5. No engine, no plan: `audio=pipewire`, exactly today's behaviour (holds in
   4b-1).

## Non-goals

- No engine-owned BlueZ/SCO device in 4b; no Opus in the call path; no change to
  the phone app.
- No new required dependency: a house with no engine and no pactl still starts,
  and its gateway simply advertises `ready=0`.

## Questions for the engine owner

1. Is a per-port `silent` report in the patch status the right shape, or should
   readiness be its own `{"cmd":"gateway"}`?
   **Answered in 4b-1: both, in one place.** The `{"cmd":"gateway"}` action set
   owns `bind`/`release`/`status`, and its object is spliced into every `status`
   line (the patch line included) and the `patch` reply. There is no separate
   readiness command; `call_in:"captured"` is the only fact the house needs to
   distinguish a real port from `silent`/`off`.
2. Does the engine's rate boundary resample 8k ↔ 48k today, or does the helper
   keep that job for 4b-2?
   **For 4b-1, neither: the gateway capture asks `parec` for 8000/1.** The
   8k ↔ house-rate resample is still unbuilt and belongs to 4b-2.
3. Should `jawn_call_in`/`jawn_prompt` stay mixer constants, or become plan
   settings in the same change that adds the `gateway` object?
   **They stay mixer constants in 4b-1.** The `bind` command names the sink, so
   the engine has no constant of its own to drift; `prompt` is still 4b-2's.
