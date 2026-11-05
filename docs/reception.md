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
| `scripts/vosk_stream.py` | gateway | reads the helper's `--tee` FIFO, segments the caller's voice and asks Vosk for one sentence at a time |

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
# and keep this machine off 2.4 GHz while it is the gateway: on a combo card the
# Bluetooth and WiFi radios share one antenna, and the caller's voice then
# arrives as "corrupted SCO packet". The dev box on 2.4 GHz logged 367 of them in
# 500 kernel lines and every name was a silent clip; on 5 GHz, none.
```

Settings, per machine (`app = misc`):

| setting | value |
| --- | --- |
| `sco_pipe` | `yes` — use the virtual handset backend |
| `sco_peer` | the phone's Bluetooth address, e.g. `00:2B:70:E9:7E:B2` |
| `sco_pcm` | empty — this is the BlueALSA backend, not used with `sco_pipe` |

The phone side resolves that name to the gateway's **bonded address**: the IVR
pane's *Gateway Bluetooth name* (default `jawn-gateway`) names the device, and
only a Hands-Free candidate with that address is chosen. Another headset
connected at the same time is never used - when the framework offers only that
headset, no communication device is set and the call stays on Telecom's route
to the gateway. (It used to fall back to "the first SCO device": with a JBL
Tune 520BT connected, a measured call went to the headset and the caller heard
silence while the gateway recorded 20 s of digital zeros.)

Nothing needs a systemd unit of its own: `President.pl` starts `perl/Sco.pl`
and `perl/Reception.pl` when `perl/sco/sco_helper` exists (build it with
`perl scripts/build_sco.pl`), and `Mixer::ensure` creates the virtual devices
the first time a call needs them.

## The live transcript

A person watching the Phone pane should read the caller's words while the call
is up. The helper copies **every frame** of the caller's voice to a FIFO
(`--tee`), above the recorder's gate, so the transcript hears the greeting-side
silence and the conversation rather than only the name. The write is
non-blocking and a missing reader is retried once a second: a transcript must
never stall the audio.

`scripts/vosk_stream.py` reads the FIFO, resamples 8 kHz to the 16 kHz Vosk
wants, learns the room's level, and emits one sentence per pause (0.7 s) with
partials while it is being said. `Gateway.pm` keeps the lines in `sco.json`,
writes `~/.president/sco/transcripts/<call_id>.jsonl`, and pushes each one on
the phone's websocket so the pane draws it as a bubble.

Vosk must be installed on the gateway machine (Configure → Plat → AI →
Transcription, `local:vosk`; `scripts/jawnos_deps.pl --extras-only --install`
puts it under `~/.local/share/jawnos/vosk`). Without it the call is unchanged
and the pane says why there is no text. **Termux cannot run Vosk** (Bionic, no
wheel), so the phone does not transcribe its own screened call - the audio is
on the gateway anyway.

When the call ends, the phone files the call appointment, and that is the
moment the transcript reaches Chat: `phone_call_transcript_note` picks the
spent transcript whose mtime is within five minutes of the call, writes one
message into the number's Chat thread, and renames the file `.filed` so a
retried call log cannot file it twice. The gateway never learns the caller's
number - the phone knows it - which is why the filing lives on the phone's call
log rather than on the gateway.

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
6. The phone's Hands-Free nodes outlive the call they were made for, and
   PipeWire remembers the device an application used last. So the pair is moved
   onto our devices at every arm and again once a second while the call is being
   fed. A pair left on the laptop's own sink and microphone is the room on the
   caller's ear and silence in our recording.
7. A finished plan (`done`) lets go of its line four seconds after the thanks:
   the caller has heard it and the phone is only holding the call for its own
   40 s limit, so a call placed straight after the last one is not left waiting
   on a busy gateway. A step that never ends is bounded at 42 s, and a pair of
   streams that stay away for three seconds ends it sooner. Then the helper is
   put down and the gateway is idle; Reception arms only from
   `idle`/`armed`/`waiting`, and that arm holds a pair that is already up, so
   the call that just heard its plan is not greeted a second time.

## Known limits

- The helper waits for a frame that carries something before it speaks. The
  phone's gateway nodes outlive a call and keep feeding our sink with digital
  silence between calls, so a frame of zeros is not a call. A line that never
  carries anything ends when the phone's 40 s limit hangs it up and the streams
  go - the caller is not greeted into nothing.
- The **voicemail greeting is not used yet**: the phone decides the flow at
  ring time, but the gateway is armed before it knows which caller arrived, so
  every screened call gets the same plan. Splitting them needs the phone to send
  the flow to the gateway at ring time.
- **The kept recordings stay on the gateway machine.** Nothing moves a name into
  the house's own records yet.
- **The transcript is filed by the phone's call log**, so the gateway machine and
  the manager that handles that phone's call log must be the same house. A
  gateway on a different machine would need the transcript fetched over the
  peer rail before it can be filed.
- **Vosk's model is per language.** The installer brings English; another
  language is a model directory dropped under `~/.local/share/jawnos/vosk/models`.
  A language with no model leaves the transcript empty (whisper.cpp is the
  fallback for a *clip*, not for the stream).
- A screened call is answered even if the gateway is not ready; the phone's
  watchdog closes it (40 s for a name, 120 s for a message) so the line is
  never left open.
- The PipeWire path needs the phone to be **bonded to the machine's adapter**;
  the gateway name in the IVR pane is what the phone matches on.
- **A Realtek RTL8821CU dongle (`0bda:c820`) carries the call one way.** Prompts
  reach the caller and nothing comes back: the streams are moved correctly, the
  plan runs, and every clip is a silent 20 s. Measured on 5 GHz with the dongle's
  own WiFi unmanaged, so it is the radio, not coexistence. Use the built-in
  adapter and keep the dongle for a machine with no other Bluetooth.

## Troubleshooting

- `~/.president/sco.json` is the truth: `state`, `plan`, `peer`, `last_error`,
  `recordings`.
- `journalctl -k | grep -i "SCO"` — `corrupted SCO packet` means the adapter's
  SCO path is broken, and the usual cause is not the adapter: a combo WiFi card
  on 2.4 GHz shares its antenna with Bluetooth. Move the machine to 5 GHz (or
  wired) before blaming the radio; on the laptop that took the count from 367 to
  zero. Only then try another adapter.
- `pactl list short sink-inputs` during a call: the Bluetooth stream should carry
  the phone's address; if it does not, the phone is not routed to the machine.
- `pactl list short sink-inputs` should show the phone's playback on
  `jawn_call_in`, and `pactl list short source-outputs` its capture on
  `jawn_ivr_mic`. On the laptop's own sink and microphone instead, the caller
  hears the room and nothing is recorded.
- `pactl list short sinks | grep jawn_call_in` is `RUNNING` even between calls
  (the phone's gateway nodes keep feeding it with silence), so it does not mark
  a call; the helper's own silence gate does.
- The helper logs `waiting for call audio` every few seconds while it waits; a
  `pcm open failed` means the PCM device name is wrong (BlueALSA only).
