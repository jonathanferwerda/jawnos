# The IVR gateway hierarchy

**Status:** design, 2026-11-19. Phase 1 (the ordered setting and the
reorderable pane), the crew `ivr` ability, Phase 2 (every enabled candidate
listens and arms; a request can name the machine a call chose; only the first
candidate keeps the phone's Bluetooth link warm), Phase 3 (the app answers
from the first candidate that is ready, and names it on every gateway request)
and Phase 4a (the backend seam, the truthful `ready` advert and the pane's audio
line) are implemented. Phase 4b-1 is implemented too: the engine binds the
gateway's inbound port over a control-socket command and reports it, without
moving any call audio. Phase 4b-2 (the PCM move and `sco_helper --engine`)
remains. This note records what existed, the rule we want, and the smallest set
of changes that gets there without answering a call into silence.

## Today: one gateway, by name

The reception has exactly one gateway at a time:

- `phone.ivr_machine` names one machine (its signatorial), and
  `phone.ivr_bluetooth` names that machine's Bluetooth adapter
  (`templates/apps/phone.html.ep:294-303`).
- `President.pl` starts `perl/Sco.pl` and `perl/Reception.pl` only on the
  machine the house named (`perl/President.pl:838-860`). A controller is not a
  gateway unless it is named explicitly; a 2 GB board is otherwise left alone.
- The phone app reads the `ivr` object from `GET /manager/phone/sync`
  (`lib/JawnOS/Controller/manager_phone.pm:431-475`). It answers a screened
  call only when `JawnIvrAudio.gatewayProblem` accepts the named adapter
  (`app/src/main/java/com/jawnos/app/JawnInCallService.java:299-331`); if not,
  the call is left to ring. It never falls back to "the first SCO device"
  (`JawnIvrAudio.java:70-78`), because that once sent a call to a JBL headset
  and the caller heard silence.
- The app resolves the gateway from `ivr_bluetooth` only. There is no
  proximity choice: `gateway()` finds the bonded device by exact name,
  `scoDevice()` matches that address, and `JawnOS::Sco::Client::_resolve()`
  resolves one `ivr_machine` (or `sco_gateway`) without iterating the roster.

That is the whole current shape. The hierarchy below changes the selection,
not the plan a gateway speaks.

## The rule we want

A screened call should be answered by the first gateway in a ranked list that
is **available** and **able**; if none is, the call rings through as it does
today.

- **Available** means the house can reach the machine now: the local machine,
  or a `remote_machines` row whose `connection` is `active`.
- **Able** means the machine advertises the `ivr` crew ability: the SCO helper
  is built, a Bluetooth adapter is present, the gateway daemon can listen, and
  its audio backend is ready (the `pactl`/PipeWire path today, the JawnOS audio
  engine later). The advert is a pre-filter; the live `scoState` check on the
  chosen candidate is the final gate.
- **The phone's link** is the final local gate: the named adapter must be
  bonded and its Hands-Free profile open. That is `gatewayProblem`, unchanged.

The list is ordered by preference: table, laptop, odroid go. The first one
that passes all three gates is the gateway for that call. The others stay
warm but idle. **No mid-call failover**: the call's audio is on one SCO link;
the hierarchy is an answer-time decision, not a live migration.

## The setting

Add one house row, `phone.ivr_machines`, a JSON array in priority order:

```json
[
  { "key": "<table-signatorial>",  "bluetooth": "jawn-table",   "enabled": true  },
  { "key": "<laptop-signatorial>", "bluetooth": "jawn-laptop",  "enabled": true  },
  { "key": "<odroid-signatorial>", "bluetooth": "jawn-odroid",  "enabled": false }
]
```

- `key` is the machine's signatorial, or the literal key `local` for the
  machine the pane is open on when it has the helper. The server resolves
  `local` to this machine's signatorial on save, so a list synced to a peer
  names the same machine.
- `bluetooth` is the adapter name the phone matches on. Give every gateway a
  name of its own; two bonded adapters with the same name make the phone's
  choice ambiguous (`gateway()` returns the first bonded match, not the
  nearest).
- `enabled` lets a machine stay in the list without being a candidate.

The existing `ivr_machine` and `ivr_bluetooth` rows stay and are written from
the first enabled entry. They are the fallback for an older app build and for
every current route that still reads one machine. The list is the truth when
it exists; the scalar rows are its shadow.

`phone_ivr_settings` (`lib/JawnOS/Domain/Phone.pm:701-715`) grows a `machines`
array, defaulting to the legacy pair. `phone_ivr_save`
(`lib/JawnOS/Manager/Part12.pm:582-690`) accepts `machines` as JSON, validates
keys against the pane's machine list, drops disabled/unknown keys, and writes
the house row plus the legacy first entry. `sco_gateway` (`host:port`) remains
the older explicit override; when it is set, it is the only candidate.

## What "able" is advertised as

`perl/crew.pl` already advertises a machine's facts to its peers every five
minutes, and the last advert is kept in the `cache` table (`app => 'crew'`,
`crew.pl:220-290`). Add an `ivr` block to `_compute_abilities`:

```json
"ivr": {
  "helper": true,
  "adapter": true,
  "audio": "pipewire",      // or "engine"
  "listening": true,        // Sco.pl bound the socket
  "armed": true,            // Reception.pl has a plan ready
  "port": 45700,
  "bluetooth": "jawn-table",
  "checked_at": 1763500000000
}
```

and a light job kind so the existing `can()` / load check applies:

```perl
'ivr.answer' => { handler => ..., timeout => 20, needs => ['ivr'], cost => 'light' }
```

The phone's fact builder merges three sources:

1. the ordered list (rank, enabled, Bluetooth name),
2. `remote_machines` / the local machine (available, hostname, IP, device),
3. the fresh crew advert (able, audio, load, RAM, adapter name).

A machine with no fresh advert is **not able**; the pane says "no advert" or
"stale advert" rather than pretending. The advert's `armed` can be minutes old
(the sync is every five minutes), so it is a hint, not the final answer. The
phone checks the chosen gateway's live state before it answers.

## Answer-time algorithm

The app already waits for the gateway before answering; the loop only replaces
the single name with the ranked list.

```
for candidate in machines where enabled:
    if not candidate.available:            continue
    if not candidate.able:                 continue
    if gatewayProblem(candidate.bluetooth): continue
    if not scoState(candidate).ready:      continue
    chosen = candidate; break

if chosen:
    postFlow(chosen, flow)
    routeCallToGateway(chosen.bluetooth)
    answer()
else:
    showScreen()          # ring through; never answer into silence
```

- **`gatewayProblem`** is unchanged (`JawnIvrAudio.java:166-218`): it checks
  the bond, asks the Hands-Free profile to open, and waits up to 1.5 s. That
  is the only place the phone knows about proximity.
- **`scoState`** is `GET /manager/sco/status?machine=<key>`; the house proxies
  to that candidate's `Sco.pl`. The current "Send to gateway" already uses
  this handshake (`JawnInCallService.java:1059-1094`); answer time reuses it.
  A gateway that says `idle`/`armed`/`waiting` is ready; a gateway that does
  not answer is skipped.
- **Bound the loop**: at most three candidates, and at most one 1.5 s connect
  attempt each. The caller is still hearing ringback; the phone's 40 s
  watchdog is the ceiling. If the list is long, the pane can mark later rows
  "fallback" and the app can try only the first two.
- **The fast gate** (`JawnPhoneBridge.ivrShouldScreen`, `JawnPhoneBridge.java:269-272`)
  should return true when IVR is on and the flow is screened and **any**
  enabled candidate exists. It must not require a specific machine to be
  available, or the app will ring before the async loop can try the second
  candidate. If no candidate exists at all, ring immediately.

The chosen key travels with the call:

- `Trip` grows `gatewayMachine` and `gatewayBluetooth`.
- `JawnPhoneBridge.scoFlow/scoState/scoHold/scoVoicemail` take the key and send
  `machine=<key>`; the house validates it against the list.
- The `POST /manager/phone/call` events carry `gateway=<key>`; the manager
  files the transcript from that machine (`phone_call_transcript_note`,
  `lib/JawnOS/Domain/Phone.pm:724+`). The screening face's
  `GET /manager/sco/status` uses the call's chosen key, not the first entry.
- A call whose chosen gateway disappears mid-call is not migrated. The phone's
  watchdog closes it, or the person presses **Connect phone** as today.

## The pane

Replace the two scalar controls in the IVR pane with one reorderable list:

```
Gateways, in order
  [≡] [x] table        online · able · engine   [jawn-table ]  [up] [down] [remove]
  [≡] [x] vitals       online · able · pipewire [jawn-laptop]  [up] [down] [remove]
  [≡] [ ] odroid go    offline · no advert      [jawn-odroid]  [up] [down] [remove]
  [+ Add machine ▾]
```

- **Rows** are the ordered list. Drag the handle, or use the up/down buttons
  (keyboard and accessibility; drag alone is not enough).
- **The checkbox** is `enabled`. A disabled row keeps its place and name but
  is not a candidate.
- **The status** is read from the manager's merged fact: `online/offline`,
  `able/no advert/stale`, `pipewire/engine`, and load/RAM when the advert
  carries it. The phone's own bond state is not visible to the manager; the
  app is the one that knows it, and the row can say "phone will confirm."
- **The Bluetooth name** is per row. Prefill it from the machine's advert when
  it has one, but keep the saved value; a rename on the gateway should be
  visible and editable here.
- **Add machine** lists the machines `phone_ivr_machines` already offers
  (local first when it has the helper, then online, then offline). A machine
  already in the list is not offered twice.
- **Save** posts `machines` JSON plus the existing flow/words fields. The
  server writes the house row, mirrors the first enabled entry to
  `ivr_machine`/`ivr_bluetooth`, and relays the save to peers as it does now.
- **Arm the gateway** arms every enabled candidate (the relay reaches each
  `Reception.pl`); the per-row status shows which ones answered. The old
  single-gateway behavior is the one-row case.
- **The help topic** (`perl/help/topics_web.pl`, the IVR topic) changes in the
  same commit: "Gateways, in order" and the first-able rule.

The list is web UI served by the manager, so the native app's IVR screen is
the same page. The app change is in the call-selection logic, not the pane.

## The gateway side: who listens and who arms

There are two different questions, and the current code answers both with one
name:

1. **Who listens and arms locally?** Every enabled candidate should run its
   own `Sco.pl` and `Reception.pl`, because the phone may choose any of them.
   `President.pl` should start them when this machine's signatorial is **in**
   the enabled list, not only when it equals `ivr_machine`
   (`perl/President.pl:838-860`). The helper check and the controller
   exclusion stay: a controller in the list is explicitly named, so it runs;
   one that is not stays out. The 2 GB warning still applies.
2. **Which gateway does the manager/app talk to for this call?** The chosen
   one, carried in the request. `JawnOS::Sco::Client` grows a
   `machine => <key>` option, validated against the list; without it, it
   keeps resolving the first enabled entry (`Client.pm:_resolve`).

`Reception.pl` currently refuses to arm when `Client.pm` resolves a remote
gateway (`perl/Reception.pl:59-66`). That guard must become **local**: the
worker arms the socket on this machine when this machine is a candidate, not
the machine the first entry names. Give it a local client
(`path => ~/.president/sco.sock`) for arm/status, and keep the remote client
only for the "is this call on another gateway?" message.

The **Bluetooth pre-warm** is the other trap. `Reception.pl`'s
`keep_bluetooth_ready` (`Reception.pl:40-56`) asks the phone to reconnect to
*this* machine's adapter. With three candidates, three machines would tug the
same phone. The phone should own that link: its `gatewayProblem` connects the
chosen adapter at call time, and Android reconnects a bonded headset on its
own. Keep the gateway-side reconnect only for the single-candidate case (or
the first candidate), or retire it. This is a deliberate regression in
pre-warm, not a bug: one owner beats three.

## The audio engine

Today the IVR is the last big `pactl` caller:

- `lib/JawnOS/Sco/Mixer.pm` loads the null sinks/remap (`jawn_call_in`,
  `jawn_prompt`, `jawn_ivr_mic`), moves the Bluetooth card's sink-input and
  source-output, and restores them with `pactl`.
- `perl/sco/sco_helper.c` opens BlueALSA (`--pcm`) or pipes `parec`/`pacat`
  (`--pipe`). The helper, not the engine, owns the call's PCM.
- `lib/JawnOS/Audio/Engine.pm` and `engine/src/socket.rs` are a **take and
  playback** control socket: record, play, monitor, patchbay. Since 4b-1 it
  also binds the gateway's inbound port (`{"cmd":"gateway",...}`) and reports
  it, but it moves no call PCM and has no prompt writer yet.

So the hierarchy must not depend on the engine being in the IVR path. Keep
the selection backend-agnostic:

- Add `JawnOS::Sco::Backend` as the gateway's audio role: `prepare`, `attach`,
  `in`, `out`, `monitor`, `status`, `release`. (`JawnOS::Sco::Audio` is a
  different thing: the recorded greeting clips.)
- The **`pactl` backend** wraps today's `Mixer` and the helper's `--pipe` /
  `--pcm` modes. The hierarchy ships on this backend.
- The **engine backend** is phase 4b. **4b-1 (implemented)** adds a transient
  `{"cmd":"gateway"}` `bind`/`release`/`status` on the engine's control socket:
  `bind` captures `jawn_call_in.monitor`, drains it, and reports
  `{call_in,prompt,monitor,rate,channels,peak,frames}` on the status line. The
  gateway is a command rather than a plan section because the Studio UI rewrites
  the saved plan on every save. It writes no PCM and does not touch
  `jawn_prompt`, so the helper and the `pactl` path are unchanged. **4b-2** adds
  `gateway.prompt` (the caller's microphone), `gateway.monitor` (the
  transcript/recorder tap), and `sco_helper --engine` so the engine carries the
  call's PCM instead of spawning `parec`/`pacat`; the engine's monitor bus can
  then replace the helper's `--tee` FIFO.
- The advert's `ivr.audio` says which backend a machine uses; `ivr.ready` is
  the backend's own readiness, and `ivr.ready_note` says why not. The pane
  shows it; the phone's choice only needs the `able` boolean, which is `ready`
  plus the light-load check.
- The hierarchy's `scoState` handshake is the same for both backends: a
  gateway that has no ready audio says so and is skipped.

Phase 4a ships the seam and the advert on `pactl`; the engine backend answers
not-ready with "the engine has no gateway ports yet". **Phase 4b-1 (implemented)**
lets the engine bind and report the inbound port, so the house can check whether
the ports are real before any audio moves; readiness deliberately does not
change yet. Phase 4b-2 (`sco_helper --engine`, the prompt and monitor ports, and
the readiness rule) remains.

## Backward compatibility

- No `ivr_machines` row: the pane and the app see a one-entry list built from
  `ivr_machine`/`ivr_bluetooth`. Nothing changes for an existing install.
- Older app builds keep reading the scalar rows, which are the first enabled
  entry. They cannot use the second candidate, but they do not break.
- `sco_gateway` still wins as the explicit address; the hierarchy is for the
  named-machine arrangement.
- A disabled first row does not disable the reception: the next enabled row is
  the legacy scalar, or the scalar is left empty and the call rings.
- A candidate with the same Bluetooth name as another is a configuration
  error; the pane warns and the app still matches the first bonded one.

## Phases and files

**Phase 0 (this note).** Design and the backpack BOM.

**Phase 1 (implemented): the setting and the pane.** No app change yet; the
app still uses the first entry, so this is safe to land alone.

- `lib/JawnOS/Domain/Phone.pm`: `phone_ivr_defaults` (`:18-35`),
  `phone_ivr_machines_clean` / `phone_ivr_flag` (new), `phone_ivr_grab`
  (`:675-683`), `phone_ivr_settings` (`:701-715`).
- `lib/JawnOS/Domain/Loader.pm`: the two new domain names.
- `lib/JawnOS/Manager/Part12.pm`: `phone_ivr_save` (`:582-690`),
  `phone_ivr_machines` (`:712-754`), `phone_ivr_candidates` (new),
  `phone_ivr_machine` (`:756-770`).
- `lib/JawnOS/Manager/Index.pm` / `Declarations.pm`: the `phone_ivr_candidates`
  map entry and forward declaration.
- `lib/JawnOS/Controller/manager_phone.pm`: the IVR page (`:89-120`), the save
  (`:297-324`), the sync (`:431-475`).
- `templates/apps/phone.html.ep`: the IVR pane (`:294-303`).
- `public/js/manager/phone.js`: the save payloads (`:284-286`, `:1683-1690`).
- `perl/help/topics_web.pl`: the IVR topic.
- Tests: the settings save/read, order, disabled rows, legacy fallback, and
  the `/manager/phone/sync` `ivr.machines` shape. Update the help test.

**Phase 2 (implemented): who listens and who arms.**

- `perl/President.pl:838-860`: start on `in the list`.
- `perl/Reception.pl:40-66`, `:250`: local arming; retire/limit the
  pre-warm.
- `lib/JawnOS/Sco/Client.pm`: `machine => <key>`; a chosen machine wins over
  the older `sco_gateway`, and a chosen machine with no roster address is an
  unresolved answer, not a fallback to the local socket.
- `lib/JawnOS/Controller/manager_sco.pm`: every SCO route accepts `machine`;
  the recording route never serves this machine's same-named file for another
  machine's call.
- `perl/President.pl`: every enabled candidate in the list starts `Sco.pl` and
  `Reception.pl`; an explicit empty list starts none.
- `perl/Reception.pl`: local arming on the candidate's own socket; only the
  first enabled candidate pre-warms the phone's Bluetooth link.
- `perl/crew.pl`: the `ivr` ability and the `ivr.answer` kind.
- Tests: the chosen-machine resolution (including the unresolved answer), the
  source contracts for the master/armer, and the legacy fallback.

**Phase 3 (the app; done).**

- `app/.../JawnPhoneBridge.java`: parses `ivr.machines` into `Gateway` rows,
  ranks them as saved (an absent list is the older single machine), and every
  gateway request - `scoFlow`, `scoStatus`, `scoState`, `scoHold`,
  `scoVoicemail`, `scoRtc`, `cancelGateway` - carries the chosen key.
  `ivrShouldScreen` treats an explicit empty list as no gateway.
- `app/.../JawnInCallService.java`: `screenWhenGatewayReady` walks the list in
  order and takes the first candidate that is online, advertises the ability,
  is paired with the phone and answers the live status probe; the trip records
  the machine and its adapter, and the flow, route and answer follow. None ready
  means the call rings and the screen shows. The call record carries `gateway`.
- `app/.../JawnScreenFace.java`: the screening face polls the chosen machine.
- The page posts that `gateway` on `/manager/phone/call`; the manager files the
  transcript from that machine's live status and reads a local `.jsonl` only
  when the chosen gateway is this machine.
- APK 0.118.352 (`versionCode` 1350), built, staged and published, and the
  surface checks the same in `t/180-sco-transcript.t`.

**Phase 4a (implemented): the backend seam and truthful readiness.**
`JawnOS::Sco::Backend` is the gateway's audio role (`prepare`, `attach`, `in`,
`out`, `monitor`, `status`, `release`); the `pactl` backend wraps `Mixer` and the
`engine` backend answers not-ready with "the engine has no gateway ports yet".
The crew `ivr` advert keeps `audio` and gains `ready`/`ready_note`, and `able`
is now `ready` plus the light-load check. The Phone pane's IVR status line names
the backend and says whether it is ready (or why not), and the help topic says
the same. Files: `lib/JawnOS/Sco/Backend.pm`, `perl/crew.pl`,
`lib/JawnOS/Controller/manager_phone.pm`, `templates/apps/phone.html.ep`,
`perl/help/topics_web.pl`, `t/181-ivr-backend.t`.

**Phase 4b-1 (implemented): the engine binds and reports the inbound port.**
The engine answers `{"cmd":"gateway","action":"bind","call_in":"jawn_call_in"}`,
`release` and `status` on its control socket. `bind` starts one `parec` capture
of `<call_in>.monitor` through `system_capture.rs` (generalised to a sink name),
drains it on its own worker, and keeps only a frame count and a peak; the samples
are dropped. `release` leaves no child, thread or ring. The gateway object
(`call_in`, `prompt`, `monitor`, `rate`, `channels`, `peak`, `frames`) rides every
`status` line and the `patch` reply. `prompt`/`monitor` are `silent`, and
`JawnOS::Sco::Backend` still answers not-ready, so the advert still says
`pipewire` and the helper keeps `parec`/`pacat`.

**Phase 4b-2 (remaining).** `sco_helper --engine` and the `gateway.in`/
`gateway.out` PCM streams, so the engine owns the prompt and the capture; the
monitor bus replaces the helper's `--tee` FIFO without changing the transcript
reader; and the engine backend becomes ready only when all three ports bind.

## Open questions

1. **Live `scoState` or advert only?** The advert is five minutes stale. The
   recommended rule is advert pre-filter + live `scoState` on the chosen
   candidate. If that adds too much answer latency, the fallback is a
   shorter advert sync for `ivr` only (e.g., 30 s), at the cost of more peer
   requests.
2. **How many candidates to try?** Three is the user's example. The loop
   should be bounded; a fourth and fifth candidate can be marked "manual" in
   the pane.
3. **Mid-call failover?** Recommend no. The SCO link is the call; moving it
   means re-routing and a second gateway handshake. Keep the hierarchy for
   answering.
4. **Who owns the Bluetooth pre-warm?** Resolved: the phone owns the link at
   call time (`gatewayProblem`); only the first enabled candidate pre-warms, so
   a ranked list cannot become a tug of war.
5. **Should the phone prefer an already-connected adapter over the top-ranked
   one that would need a 1.5 s connect?** The user's stated rule is rank
   first. Keep rank first; the connect attempt is bounded.
6. **What if two candidates share a Bluetooth name?** Reject/warn in the
   pane; the app still matches the first bonded one.
7. **Does the controller count?** Yes, when it is in the list and enabled.
   Its advert should show its 2 GB and load; the pane can warn that the
   reception is heavy for it.
8. **What does "pick up" mean for silence mode?** Silence forces the
   receptionist flow for every caller. If no gateway is able, the call should
   still ring through (or the flow's After), not be answered into nothing.
   Confirm the desired behavior.
9. **The engine's gateway API is new.** It landed in 4b-1 as a control-socket
   command, not a plan section (the Studio UI rewrites the plan on save). The
   hierarchy still ships on `pactl`; phase 4b-2 moves the audio once readiness
   follows the ports.

## Risk

Phase 2 changed the arming model: every enabled candidate listens and arms,
sharing the house `sco_token`, and only the first candidate pre-warms the
phone. The remaining risk is the live choice: with several candidates warm the
phone must pick the same one its Bluetooth link is on, and only a real second
machine proves the fall-through (the first candidate off or unbonded, the
second answering). The tests pin the decision order and the source contracts,
not the radio.
