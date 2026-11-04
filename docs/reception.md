# The phone reception: how a screened call is answered by the house

A phone call the house decides to screen is answered by the phone app, its
audio is carried over Bluetooth to a **gateway machine**, and that machine
plays the house's prompts and records the caller's name. Nothing about the
call passes through the phone's own speaker or microphone.

This file records the working setup, because it is the part that is not in the
code: it lives in the audio stack of whichever machine owns the Bluetooth
adapter.

## The pieces

| Piece | Where | What it does |
| --- | --- | --- |
| `JawnPhoneBridge.ivrFlowFor` | app | decides `ring`, `ivr`, `voicemail` or `reject` for a number: its own route, else the person's relationship, else `unknown` |
| `JawnInCallService` | app | answers a screened call without the in-call screen, routes it through **Telecom** (`CallAudioState.ROUTE_BLUETOOTH`), and keeps re-applying the route as the call settles |
| `perl/Sco.pl` | gateway | one-call daemon on `~/.president/sco.sock`; owns the audio helper and the plan |
| `lib/JawnOS/Sco/Gateway.pm` | gateway | greeting → name prompt → record → thanks, and the state in `~/.president/sco.json` |
| `lib/JawnOS/Sco/Mixer.pm` | gateway | the virtual handset (below): moves the call's own two streams onto devices it owns |
| `lib/JawnOS/Sco/Render.pm` | gateway | Piper → raw 8 kHz s16le, cached by words and voice |
| `perl/sco/sco_helper.c` | gateway | the audio half: `--pcm` (BlueALSA) or `--pipe` (`parec`/`pacat`), one JSON line per event |
| `perl/Reception.pl` | gateway | keeps the gateway armed from the phone's settings, and keeps the names a call left in `~/.president/sco/kept/` |

## Why a virtual handset

The Linux Bluetooth stack offers two ways to be the other end of a phone call,
and on the laptops we tried:

- **BlueALSA** as the Hands-Free side: a proper PCM, but in practice it carried
  only our outgoing audio (the radio trace showed our frames going out and none
  coming back).
- **PipeWire** as the Audio Gateway: it carries the call correctly, but it
  exposes **no audio nodes** for the phone's card, and it plays the caller to
  the machine's *default sink* and takes input from the *default source*. That
  is why a caller could hear the room.

The second one is what works, and the way to own it without changing the
machine's defaults is to move only the call's own streams:

```
jawn_call_in    null sink  - the caller's voice lands here; the gateway captures its monitor
jawn_prompt     null sink  - what the gateway plays here is the caller's "microphone"
jawn_ivr_mic    remap      - jawn_prompt.monitor, presented as a source
```

`Mixer::attach` moves the Bluetooth card's **sink-input** to `jawn_call_in` and
its **source-output** to `jawn_ivr_mic`. Local music keeps playing on the real
sink and never reaches the caller; nothing in the machine's defaults changes, so
nothing has to be restored if the gateway dies (the streams fall back on their
own when they vanish).

### Setup on the gateway machine

```
# BlueZ + PipeWire (Manjaro: installed; no extra packages)
sudo systemctl enable --now bluetooth
# the phone paired with the machine's adapter; PipeWire puts its card on the
# "audio-gateway" profile
```

Settings, per machine (`app = misc`):

| setting | value |
| --- | --- |
| `sco_pipe` | `yes` — use the virtual handset backend |
| `sco_peer` | the phone's Bluetooth address, e.g. `00:2B:70:E9:7E:B2` |
| `sco_pcm` | empty — this is the BlueALSA backend, not used with `sco_pipe` |

The phone side picks its own adapter by name: the IVR pane's *Gateway Bluetooth
name* (default `jawn-gateway`). It matches against the SCO devices the phone
can see, so a second headset connected to the phone does not steal the call.

Nothing needs a systemd unit of its own: `President.pl` starts `perl/Sco.pl`
and `perl/Reception.pl` when `perl/sco/sco_helper` exists (build it with
`perl scripts/build_sco.pl`), and `Mixer::ensure` creates the virtual devices
the first time a call needs them.

## The plan

1. The phone answers; PipeWire's gateway streams appear within a second or two.
2. `Gateway::watch_streams` sees both streams, moves them, and starts the helper
   with `--pipe-in 'parec … jawn_call_in.monitor'` and
   `--pipe-out 'pacat … jawn_prompt'`.
3. The helper treats the **first frame of call audio** as the start of the call
   (an open PCM is not a call), waits 1.2 s for the phone's audio path to settle,
   leaves a 450 ms lead-in, then plays the plan.
4. The greeting and the name prompt play, then a 400 ms cue tone, then the name
   is recorded to `~/.president/sco/name-<call_id>.wav`. The clip is opened the
   way dictation opens a phrase: half a second reads the room, speech has to
   hold before it counts as the name, and the pause that ends it is measured
   against that room and the name's own peak (`silence_ms`, 2 s). A caller who
   waits keeps the line up to the ceiling (`ms`, 20 s); a single tick of line
   noise no longer opens and closes the clip before they speak. `Reception.pl`
   copies the clip to `~/.president/sco/kept/<call_id>.wav`, transcribes it to
   the name and appends a line to `kept/index.jsonl`.
5. Routes: `GET /manager/sco/status|result|recording`, `POST /manager/sco/arm|cancel`.

## Known limits

- The **voicemail greeting is not used yet**: the phone decides the flow at
  ring time, but the gateway is armed before it knows which caller arrived, so
  every screened call gets the same plan. Splitting them needs the phone to send
  the flow to the gateway at ring time.
- **The kept recordings stay on the gateway machine.** Nothing moves a name into
  the house's own records yet.
- A screened call is answered even if the gateway is not ready; the phone's
  watchdog closes it (40 s for a name, 120 s for a message) so the line is
  never left open.
- The PipeWire path needs the phone to be **bonded to the machine's adapter**;
  the gateway name in the IVR pane is what the phone matches on.

## Troubleshooting

- `~/.president/sco.json` is the truth: `state`, `plan`, `peer`, `last_error`,
  `recordings`.
- `journalctl -k | grep -i "SCO"` — `corrupted SCO packet` means the adapter's
  SCO path is broken; try another adapter (a cheap dongle may be worse than the
  built-in radio).
- `pactl list short sink-inputs` during a call: the Bluetooth stream should carry
  the phone's address; if it does not, the phone is not routed to the machine.
- The helper logs `waiting for call audio` every few seconds while it waits; a
  `pcm open failed` means the PCM device name is wrong (BlueALSA only).
