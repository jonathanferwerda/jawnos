# The gateway's engine ports — a contract for Phase 4b

**Status:** draft, 2026-11-20. Written against trunk `v0.1.3447`, to be handed to
the audio-engine work. It is the engine half of `docs/ivr-hierarchy.md` Phase 4;
the house half (the backend seam, `ready`, the pane) landed in `v0.1.3438`.

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
| `gateway.call_in` | capture | `jawn_call_in.monitor` | 8 kHz mono s16le, resampled to the house rate | `handset` source, if the plan declares one |
| `gateway.prompt` | write | `jawn_prompt` | 8 kHz mono s16le, resampled from the house rate | helper's `pacat` |
| `gateway.monitor` | bus | a plan bus (default `gateway`) | both directions, 8 kHz mono for the reader | helper's `--tee` FIFO |

The engine's graph runs at the house rate; the call is 8 kHz. **The engine owns
that rate boundary**, the same way `Codec::Pcm16k` already resamples a small
device's input on receive. Nothing in the call path may assume 48 kHz on the
wire.

## The plan

A top-level `gateway` object, ignored by every build that does not know it:

```json
"gateway": {
  "call_in": "jawn_call_in",
  "prompt":  "jawn_prompt",
  "monitor": "gateway",
  "rate": 8000,
  "channels": 1
}
```

- `call_in` and `prompt` are **PipeWire node names**, not plan node ids: they are
  owned by the reception mixer, not the patchbay.
- `monitor` names a bus the plan declares. The gateway section does not create
  buses; a name with no bus is refused on the write path and treated as silent on
  the read path, like every other dangling node.
- Defaults: the three names above, `rate` 8000, `channels` 1. An absent
  `gateway` object means "this machine is not a gateway" and costs nothing.

`JawnOS::Audio::Plan::audio_plan_normalize` currently returns only the four
lists, so it must carry `gateway` through (clamped, text-only) and
`audio_plan_valid` must accept and check it. The engine's plan reader ignores
keys it does not know, so an older engine stays compatible.

## What the engine compiles

1. **`gateway.call_in`** — one capture of `<call_in>.monitor`, bound like the
   `handset` source (the `system_capture.rs` mechanism, generalised from one
   fixed sink name to any name). A plan that declares both a `handset` source on
   `jawn_call_in` and a `gateway.call_in` on the same sink captures **once**.
   Failure to bind reports the port `silent`; it never fails the plan.
2. **`gateway.prompt`** — a writer into `<prompt>`. Follow `system_capture.rs`
   in reverse: a child process (`pacat --device=<prompt> --latency-msec=20`),
   a bounded lock-free ring, and a producer that drops and counts rather than
   stalling. The child is spawned on the first frame and closed when the gateway
   says the call is over, so an idle machine runs no extra process.
3. **`gateway.monitor`** — the plan's ordinary bus. The transcript reader gets
   both directions on it; the existing tee file path is kept (below).

The plan's status gains:

```json
"gateway": {"call_in":"captured","prompt":"writing","monitor":"bound","rate":8000}
```

A port that cannot be bound says `silent`; that is the only signal the house
needs to refuse to answer.

## The helper (`sco_helper --engine`)

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
- **A missing gateway section is not an error at startup.** `gateway.in` and
  `gateway.out` answer `{"ok":false,"error":"the gateway ports are not bound"}`;
  the helper exits non-zero and the armer records that reason.

## Ownership and lifecycle

- `Mixer` still creates and removes the null sinks and moves the Bluetooth
  streams (`prepare`/`attach`). The engine does **not** own the BlueZ device in
  4b; that is a later step, and mixing the two in one change is how a call ends
  up with two owners.
- The writer is lazy (first prompt frame) and the capture is bound with the
  plan; both stop when the helper closes its streams.
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

## Build it in two slices

**4b-1 — the truth, no PCM move.** The plan carries `gateway`, the engine binds
`call_in` and reports all three ports, and the advert's readiness follows. The
helper keeps `parec`/`pacat`; the engine only *reports* (and may tap the monitor
bus). This is small, testable, and safe to ship before the engine owns a frame.

**4b-2 — the engine carries the call.** `gateway.out`/`gateway.in` and
`sco_helper --engine`, so the engine owns the prompt and the capture. Only after
4b-1 has run on the table for a real call.

Do not merge the two: 4b-1 is how the house learns whether the engine's ports are
real, and 4b-2 depends on that answer.

## Acceptance

1. Rust, null device: a plan with `gateway` compiles; a missing sink reports
   `silent` and the plan still runs; the writer's ring drops rather than stalls;
   `gateway.in` frames are exactly 80 samples of s16le at 8 kHz.
2. Rust, proto: a gateway frame round-trips; a short frame is refused.
3. Perl: `Backend` says `engine` ready only with all three ports bound (fake
   socket); the advert's `audio`/`ready` follow; `ready` implies `able` when the
   load is light.
4. On the table: one screened call with `audio=engine`, transcript filed; kill
   the engine mid-call — the gateway reports the drop and the watchdog ends the
   line; the next call falls back to `pactl` if the engine is not ready.
5. No engine, no plan: `audio=pipewire`, exactly today's behaviour.

## Non-goals

- No engine-owned BlueZ/SCO device in 4b; no Opus in the call path; no change to
  the phone app.
- No new required dependency: a house with no engine and no pactl still starts,
  and its gateway simply advertises `ready=0`.

## Questions for the engine owner

1. Is a per-port `silent` report in the patch status the right shape, or should
   readiness be its own `{"cmd":"gateway"}`?
2. Does the engine's rate boundary resample 8k ↔ 48k today, or does the helper
   keep that job for 4b-2?
3. Should `jawn_call_in`/`jawn_prompt` stay mixer constants, or become plan
   settings in the same change that adds the `gateway` object?
