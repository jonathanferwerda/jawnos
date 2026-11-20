# The gateway's engine ports — a contract for Phase 4b

**Status:** implemented, 2026-11-20. Phase 4b-1 (bind and report the inbound
port) and 4b-2 (the engine carries the call's PCM) are both in the tree. The
house half (the backend seam, `ready`, the pane) landed in `v0.1.3438`.

The rule this note exists to protect: **the engine is optional.** A gateway must
be able to say `audio: pipewire` (the `pactl` path) forever, and a phone must
never see "able" for a machine whose audio cannot carry the call. When in doubt,
the gateway stays on `pactl`.

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
the caller's voice to a tee FIFO for the transcript reader. In 4b-2 it can
instead take the caller's voice from, and write the prompt to, two FIFOs the
engine owns (`--engine`).

The engine already does part of this: `patchbay.rs` binds a `handset` source
from `jawn_call_in.monitor`, and its monitor bus already feeds the Listen path.
It writes only to its own output, and it does not bind `jawn_prompt` as part of
the saved plan.

## The three ports

| port | engine's view | node | format at the boundary | today |
| --- | --- | --- | --- | --- |
| `gateway.call_in` | capture → FIFO write | `jawn_call_in.monitor` | 8 kHz mono s16le | `{cmd:"gateway"}` bind |
| `gateway.prompt` | FIFO read → `pacat` | `jawn_prompt` | 8 kHz mono s16le | engine's `pacat` (4b-2) |
| `gateway.monitor` | bus | the helper's `--tee` FIFO | 8 kHz mono for the reader | still the helper's (`monitor:"helper"`) |

The engine's graph runs at the house rate; the call is 8 kHz. **The engine owns
that rate boundary.** `gateway bind` asks `parec` for 8000/1 directly, and the
drain downmixes the capture's stereo ring to mono s16le. Nothing in the call
path assumes 48 kHz on the wire.

## The socket command (not the plan)

**The gateway does not ride the saved audio plan.** The Sound/Studio UI rewrites
the plan on every save — `audio_plan_normalize` returns only the four lists, so
any key it does not know is dropped — which means a `gateway` section would
vanish silently the first time a person edits the patchbay. The gateway is
machine-local and exists only while a call is up, which is the lifetime of a
control-socket command, not of a saved document. So it is three transient
commands, answered in the same one-object-per-line protocol:

```
{"cmd":"gateway","action":"bind","call_in":"jawn_call_in","prompt":"jawn_prompt","volume":37}
{"cmd":"gateway","action":"release"}
{"cmd":"gateway","action":"status"}
```

- `bind` creates the per-call directory and its two FIFOs, starts **one**
  capture of `<call_in>.monitor` through the same `system_capture.rs` mechanism
  as the system mix (`SystemCapture::start_sink`, generalised from a fixed
  source to any sink name), and opens the prompt port. It answers
  `{"ok":true,"gateway":{...}}`. Binding while already bound is idempotent and
  keeps the first capture. `"prompt"` is optional and defaults to
  `jawn_prompt`; `"volume"` is optional and, when present, is the phone
  channel's gain in percent (0..100, clamped and rounded like the mixer's), so
  the engine's `pacat` carries the same level the helper's did.
- A sink the machine cannot capture still answers `ok` with
  `call_in:"silent"` and **schedules a bounded retry** (below). A missing sink
  is never fatal — the same rule the patchbay follows.
- `release` stops the capture, reaps the prompt child, removes the per-call
  directory, and returns `call_in` to `off`.
- `status` answers the gateway object below, and an unknown action answers
  `{"ok":false,"error":"…"}`.

```json
"gateway": {
  "call_in": "captured" | "silent" | "off",
  "prompt": "writing" | "silent",
  "monitor": "helper",
  "rate": 8000,
  "channels": 1,
  "peak": 0.0,
  "frames": 0,
  "dropped": 0,
  "paths": { "call_in": "/home/me/.president/gateway-1234/call_in",
             "prompt":  "/home/me/.president/gateway-1234/prompt" },
  "capable": true
}
```

The same fragment is spliced into every `status` line (including the patch
line) and into the `patch` reply, so a page that already polls the engine sees
it without a second command.

- `off` means no bind has been made.
- `monitor:"helper"` is a promise: the transcript copy is still the helper's
  `--tee` FIFO, at the same path `scripts/whisper_stream.py` reads. 4b-2 does
  not move it, and this slice does not make it part of readiness.
- `dropped` counts frames the ring or a full `call_in` pipe could not take.
- `capable` says the engine **can** carry a gateway — the socket answers (this
  one does) and both `parec` and `pacat` are on `PATH`. It is independent of
  whether a call is bound, so readiness reads it while idle. It is not a
  promise that a particular sink exists; that is `call_in`.
- `paths` is `{}` before a bind and after a release. The two paths are
  **absolute**, because the helper is given the directory and neither side may
  depend on a working directory.

`call_in` is a **PipeWire sink name**, not a plan node id: the null sink is
owned by the reception mixer. `JawnOS::Audio::Plan` is **not** touched: it keeps
returning the four lists, and an older engine stays compatible because it never
sees a `gateway` key.

## The transport: two FIFOs, not a binary socket mode

The control socket stays line-based, one JSON object per line. PCM never
crosses it. This is deliberate:

- the protocol is already line-based, and a second mode inside it would make
  every reader (the Perl client, the supervisor, a probe) parse a framing it
  does not otherwise need;
- `sco_helper` already speaks a JSON line protocol on stdin/stdout and taps the
  caller's voice to a FIFO (`--tee`). Two more named pipes are the same shape
  it already has;
- a FIFO gives the backpressure rule for free: a non-blocking write either
  lands or is dropped, with no head-of-line blocking on the command socket.

`bind` creates `<state dir>/gateway-<pid>/` and two named pipes in it:

- `<dir>/call_in` — the engine writes the caller's voice, the helper reads it.
- `<dir>/prompt` — the helper writes prompt bytes, the engine feeds them to
  `pacat`.

The state dir is the same convention on both sides: the saved plan's directory
when there is one, else the control socket's, else `~/.president`. On the Perl
side that is `JawnOS::Audio::Engine::audio_engine_state_dir()`; the engine
derives the same path from its own `--plan`/`--socket`.

`release` removes the directory. A crash leaves a stale one, and the next
`bind` removes it before creating its own — the directory is keyed by the
engine's pid, so it cannot be another live engine's.

### The capture side (`call_in`)

The drain pops the 8 kHz stereo f32 ring 10 ms at a time, downmixes each frame
to mono (`(L+R)/2`), converts to s16le, and writes one **160-byte** frame. The
write is non-blocking: a full pipe drops the frame and increments `dropped`, the
same rule the ring follows. `frames` and `peak` still describe what the capture
heard. The `call_in` write end opens lazily, because a FIFO refuses a writer
until a reader exists; a frame that arrives before the helper is a counted
drop.

### The prompt side (`prompt`)

`bind` opens the FIFO's read end but **spawns no process**. The prompt worker
waits on the FIFO and starts

```
pacat --playback --raw --device=<prompt_sink> --format=s16le --rate=8000 \
      --channels=1 --latency-msec=20 [--volume=<n>%] \
      --client-name=jawn-sco-prompt --stream-name=jawn-sco-prompt
```

The optional `--volume` comes from the bind's `volume`, which
`JawnOS::Sco::Gateway` fills from `Mixer::playback_volume` (the phone channel's
`sound_channel_gain`, the same number the helper's `pacat` uses). Absent means
`pacat`'s default.

The two names are the mixer's: `attach` repairs the prompt stream's route by
`application.name = jawn-sco-prompt`, and an unnamed `pacat` can inherit a saved
route onto `jawn_call_in` (the greeting played into the caller's own sink). The
engine's child wears the name the helper's did.

on the **first prompt byte**, so a bind with no call runs only the capture. A
dead `pacat` is reported (`prompt:"silent"`), never fatal; it is killed and
reaped on `release`, and the next prompt byte starts a fresh one.

### The silent-bind retry

The reception mixer creates `jawn_call_in` a moment after the engine is asked to
bind it, so the first look can honestly be `silent`. The port must not stay
silent forever: when `source_exists` says the sink is not there, the server
retries the capture every **500 ms for 5 s** while `call_in` stays requested,
and reports `captured` when it succeeds. The retry runs from the serve loop,
which polls the listener non-blockingly, so it works while no client is
connected (a call holds the FIFOs, not the socket). `release` clears it.

## The helper (`sco_helper --engine`)

`perl/sco/sco_helper.c` gains `--engine <dir>`, mutually exclusive with
`--pcm`, `--pipe-in` and `--pipe-out`. It opens `<dir>/call_in` `O_RDONLY` and
`<dir>/prompt` `O_WRONLY` (non-blocking, so a full prompt FIFO drops a frame
rather than stalling the plan). `backend_read`/`backend_write` use those
descriptors. Nothing else changes: the radio, the 8 kHz framing, DTMF, the
recording, the events and the **tee** are exactly as they were.

A missing FIFO is an error event and a non-zero exit, not a hang: the open
polls for two seconds and then answers `{"event":"error","error":"…"}`. The
armer records the reason and falls back rather than leaving a call on a dead
port.

There is also `--engine-selftest <dir>`: it opens the pair and echoes one
frame, so `t/158-sco-gateway.t` can prove the transport with two plain FIFOs — no
radio, no PipeWire and no engine process — using the same read and write a real
call makes.

## Readiness and selection

`JawnOS::Sco::Backend`'s `engine` backend reports ready only when all four
hold:

1. the helper binary is built,
2. that binary names `--engine` (one cached scan of its usage text, keyed by
   path, mtime and size so a rebuilt helper is re-read), and
3. a Bluetooth adapter is present — the engine carries the PCM, not the radio,
   and without an adapter the helper can never take the Hands-Free link,
4. the eval-guarded engine socket answers a `status` whose `gateway.capable` is
   true.

Otherwise `ready` is 0 with the engine's own reason, and the gateway uses
`pactl`. The engine backend's `prepare`/`attach`/`status`/`release` remain thin
`Mixer` calls — the mixer still owns the null sinks, the stream moves and the
call's liveness; only the PCM direction moved. `in`/`out` answer not-ready,
because the engine has no command to return.

`perl/crew.pl` asks the engine backend first and falls back to `pactl`, so the
advert's `ivr.audio` is `engine` when the backend is engine-ready, else
`pipewire`. `able` still means `ready` plus the light-load gate. A machine
without the engine socket never claims engine.

At arm time, `JawnOS::Sco::Gateway` asks the same backend before spawning the
helper:

- engine-ready: `gateway bind` for `jawn_call_in`/`jawn_prompt`, then spawn the
  helper with `--engine <dir>`;
- bind answers `captured`: start the helper immediately;
- bind answers `silent`: poll `gateway status` every 500 ms for five seconds
  (the engine's own retry window). If it reaches `captured`, start the helper on
  the FIFOs; if not, `gateway release` and spawn the current
  `--pipe-in`/`--pipe-out` helper **for that call**;
- bind is refused: use the pipes immediately.

At detach or end, the gateway sends `gateway release`. The engine is chosen only
where the virtual-handset pipes would be used (`sco_pipe`); the raw SCO and
BlueALSA transports are not touched. **The phone is unchanged**: it reads
`able`, `bluetooth`, and its own live `scoState`.

## Ownership and lifecycle

- `Mixer` still creates and removes the null sinks and moves the Bluetooth
  streams (`prepare`/`attach`). The engine does **not** own the BlueZ device in
  4b; that is a later step, and mixing the two in one change is how a call ends
  up with two owners.
- The prompt child is lazy (first prompt byte) and the capture is bound by the
  `gateway` command; both stop on `release` (helper close, or the mixer's
  `detach`). A `quit` releases them too, so the engine never leaves a `parec`
  or `pacat` child behind.
- One call at a time. `release` leaves no child, thread, ring or directory
  behind.

## What 4b-1 implemented

1. **`gateway.call_in`** — one `parec` capture of `<call_in>.monitor`, exactly
   the system-mix mechanism (`system_capture.rs`): a 20 ms process latency, a
   lock-free ring, retries while the engine runs.
2. **`gateway.prompt`** and **`gateway.monitor`** — reported `silent`; their
   writers are 4b-2's.

Failure to bind reports the port `silent`; it never fails the engine or the
patch.

## What 4b-2 implements

1. The per-call FIFO directory and both paths in the bind reply.
2. The drain's downmix to mono s16le and its non-blocking write to `call_in`
   with a drop count.
3. The lazy prompt `pacat`, fed from the `prompt` FIFO and reaped on `release`.
4. `monitor:"helper"`, `capable`, and the silent-bind retry.
5. `sco_helper --engine` and `--engine-selftest`.
6. The readiness rule and the arm-time choice with the pipe fallback; the
   advert's `audio`.

## Acceptance

1. Rust, null device (4b-1, done): `gateway bind` answers `call_in:"captured"`
   with a capture on `PATH`; without one it answers `silent` and the engine keeps
   serving; a second bind keeps the first capture; `release` returns to `off`
   with no child, thread or ring; the ring drops rather than blocks and the drain
   still answers a frame count and a peak.
2. Rust, FIFOs (4b-2, done): bind creates absolute FIFOs; the drain writes
   160-byte mono frames; a full `call_in` pipe drops and counts; `pacat` is
   spawned only by the first byte and reaped on release; a silent bind retries
   to `captured`; release removes the directory; `status` before a bind is `off`
   with `capable` from the environment.
3. C (4b-2, done): `--engine-selftest` over plain FIFOs reads `call_in`, writes
   `prompt`, exits zero; a missing FIFO is an error event and a non-zero exit.
4. Perl (4b-2, done): `Backend` says `engine` ready only with a capable socket
   and an engine-built helper (fake socket); a machine with no socket never
   claims it; the arm-time choice, the silent fallback to pipe mode, and the
   advert's `audio`/`ready` follow.
5. On the table (the remaining check): one screened call with `audio=engine`,
   transcript filed; kill the engine mid-call — the gateway reports the drop and
   the watchdog ends the line; the next call falls back to `pactl` if the engine
   is not ready.
6. No engine, no plan: `audio=pipewire`, exactly today's behaviour.

## Non-goals

- No engine-owned BlueZ/SCO device in 4b; no Opus in the call path; no change to
  the phone app.
- No new required dependency: a house with no engine and no pactl still starts,
  and its gateway simply advertises `ready=0`.
- The transcript copy does not move yet: `monitor:"helper"` says the tee is
  still the helper's.

## Questions for the engine owner

1. Is a per-port `silent` report in the patch status the right shape, or should
   readiness be its own `{"cmd":"gateway"}`?
   **Answered in 4b-1: both, in one place.** The `{"cmd":"gateway"}` action set
   owns `bind`/`release`/`status`, and its object is spliced into every `status`
   line (the patch line included) and the `patch` reply. There is no separate
   readiness command; `capable` is what readiness reads while idle, and
   `call_in:"captured"` is what the call path needs.
2. Does the engine's rate boundary resample 8k ↔ 48k today, or does the helper
   keep that job for 4b-2?
   **Neither, and that is deliberate:** the gateway capture asks `parec` for
   8000/1 and the drain writes 8 kHz mono; the prompt `pacat` asks for 8000/1.
   The engine's house rate is never involved in the gateway path.
3. Should `jawn_call_in`/`jawn_prompt` stay mixer constants, or become plan
   settings in the same change that adds the `gateway` object?
   **They stay mixer constants.** `bind` names both sinks (`prompt` defaults to
   `jawn_prompt`), so the engine has no constant of its own to drift.
