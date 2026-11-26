# Studio effects — the shared contract

> One effect list, two implementations: the browser (`public/js/manager/studio.js`,
> WebAudio) and the native engine (`engine/src/effect.rs`, Rust). The UI slider is
> always `0..100`; each side maps it to its own natural units. A name or control
> added on one side must be added on the other, or the pedal board will offer a
> pedal the engine silently ignores.

## Insert kinds

`InsertKind::parse` (Rust) and `studioInsert` (JS) accept these names. The
`reverb2` name is kept as an alias of `reverb` so old songs still load.

`autotune` is the **wire name** used by `InsertKind`, the socket and saved
songs. The UI shows it as **JawnPitch**; keep the key `autotune` so old songs
and the engine keep working.

**Jtune is a listen-only insert, not an `InsertKind`.** `studioInsert` builds the
fallback pass-through for it because it has no builder, so it never colours the
sound, and if it were given a builder the native engine's plan would send it a
name `InsertKind::parse` rejects. Leave it without a builder and without an
alias: the browser taps its input for the tuner display, the rack orders and
bypasses it like any pedal, and the song keeps it in the chain.

| name | purpose | controls (UI `0..100`) |
| --- | --- | --- |
| `reverb` | the reverb family | `mix`, `volume`, `model` |
| `flanger` | swept comb | `rate`, `depth`, `feedback`, `mix` |
| `phaser` | swept allpass notches | `rate`, `depth`, `feedback`, `mix` |
| `fuzz` | germanium two-transistor fuzz (JH-2) | `gain`, `tone`, `level` |
| `amp` | valve amp + cabinet (four voices) | `gain`, `bass`, `mid`, `treble`, `cabinet` |
| `limiter` | peak limiter | `ceiling`, `release` |
| `autotune` | monophonic pitch correction (JawnPitch in the UI) | `speed`, `amount`, `key`, `scale` |
| `equalizer` | three-band tone shaping | `low`, `mid`, `high` |
| `tone` | the strip's own bass/mid/treble (existing) | `bass`, `mid`, `treble`, `gain` |
| `distortion` | existing | `drive` |
| `delay` | existing | `time`, `feedback`, `vol` |
| `compressor` | existing | `thresh`, `attack`, `ratio`, `release`, `knee`, `mix` |
| `tremolo` | amplitude modulation, three LFO shapes | `rate`, `depth`, `shape` |
| `stereo_panner` | channel pan modulation, three LFO shapes | `rate`, `depth`, `shape` |
| `harmonizer` | monophonic diatonic harmony, one detected note | `key`, `scale`, `degree`, `mix` |
| `de_esser` | split-band high-frequency de-esser | `thresh`, `freq`, `amount` |
| `modulator` | ring modulator | `rate`, `depth`, `mix` |
| `pitch_shift` | fixed-interval granular pitch shifter | `semitones`, `mix` |
| `gate` | noise gate | `thresh`, `attack`, `hold`, `release`, `range` |
| `slider` | hard-cutting tremolo (chopper) | `rate`, `depth`, `duty` |
| `overdrive` | valve-like overdrive | `drive`, `tone`, `level` |
| `wah` | LFO-swept resonant bandpass | `rate`, `depth`, `mix` |
| `chorus` | one modulated short delay | `rate`, `depth`, `mix` |
| `vibrato` | modulated short delay, no dry path | `rate`, `depth` |

The names and controls above are the contract. **What each pedal models** —
the real circuit, the control mapping and the honest approximation — is in
`docs/pedal-audit.md`. Read it before changing a pedal's sound: the two sides
share the control names, not a claim of a sample-identical circuit.

`harmonizer` and `pitch_shift` add latency and suit one note at a time. The
harmonizer detects the played note and moves it a scale step through crossfaded
grains, so a chord confuses its detector. `pitch_shift` does not detect: it
reads the whole signal through a stream of resampled grains at a fixed ratio
from -24 to +24 semitones, so a chord shifts too (with the usual granular warble
at the extremes).

`stereowidener` is a **browser-only** insert. A mid/side matrix needs an L/R
pair, and the engine's insert chain is mono, so `InsertKind::parse` answers
`None` for it; a native take or listen omits the pedal instead of faking a
mono version (engine/src/effect.rs). The browser builds it with
`studioEffectStereoWidener`.

`stereo_panner` is **native**, and it is not a mono insert on either side. The
engine builds it as a transparent pass-through that carries an LFO
configuration, and the channel applies that LFO at its own pan stage, where the
L/R pair exists (`engine/src/effect/stereo_panner.rs`, `Effect::pan_lfo`). The
browser mirrors this: `studioEffectStereoPanner` is a pass-through exposing
`fx.panner`, and `studioPanLfoAll` applies the last enabled panner at the
channel's pan stage after the chain (`c.playPan.pan`). The two sides share the
controls and the shape indexes.

## Tempo-synced time controls

`delay.time`, `flanger.rate`, `phaser.rate`, `tremolo.rate`, `stereo_panner.rate`,
`modulator.rate`, `slider.rate`, `wah.rate`, `chorus.rate` and `vibrato.rate`
accept a `sync` field. It is a **UI-only string**: it is stored in the insert's
`values.sync`, saved with the song, and resolved by the page into the effect's
natural `time` or `rate` before anything is sent. It is **not** an engine
control and **not** in `InsertKind::controls` or `Plan.pm`'s control lists.

The pedal renders it as a visible text field with a `<datalist>` of the common
divisions, not a closed dropdown, because the parser accepts more than the list:

| input | meaning |
| --- | --- |
| `1/16`, `1/8`, `1/4`, `1/2`, `3/4` | `4n/d` beats; a `1/4` is one beat |
| `1`, `2`, `3`, `4` | whole notes: `N` means `4N` beats |
| `1/8d` | dotted: the division times 1.5 |
| `1/8t` | triplet: the division times 2/3 |
| `250ms`, `250.0` | a manual millisecond value; sync is off |
| `off`, blank | sync is off; the manual knob is authoritative |

A delay time is `60 / bpm * beats` seconds. An LFO rate is `bpm / 60 / beats`
Hz. A manual value is milliseconds: seconds for `delay.time`, a period for an
LFO (`1000 / ms` Hz). `studioTempoSyncAll()` re-applies every synced insert on a
BPM change and after a sync or manual change; `01_transport.js` resolves the
same values before an engine plan is sent.

Both sides keep the manual ranges they had. The delay's Time knob still maps to
`0..1.5 s`, but the line accepts up to `8.0 s` and is `8.5 s` long, because four
bars at 120 BPM is 8 seconds. The browser's `DelayNode` is likewise 8 s. The
flanger's Rate knob still maps to `0.05..5 Hz`, but the effect accepts up to
`8 Hz` (a 1/16 at 120 BPM) and clamps a faster resolved rate to that cap. The
phaser's Rate knob shares that `0.05..5 Hz` mapping and both sides cap the
resolved rate at `5 Hz`. The new LFO knobs map to `0.1..20 Hz`; a resolved rate
past 20 Hz is clamped there. The five newer LFOs sync the same way on their
`rate`: `modulator`, `slider`, `wah` and `vibrato` accept a resolved rate up to
`20 Hz`, while `chorus` maps `0.05..5 Hz` and clamps a resolved rate at `5 Hz`.

## Tremolo and stereo panner

`tremolo` is a mono amplitude modulator. `depth` is the swing and `shape` is the
shared index below; the gain is `1 - depth/2 + (depth/2) * lfo`, so full depth
reaches silence at the trough. The engine is `engine/src/effect/tremolo.rs` and
the browser is `studioEffectTremolo`; both hold the same rate/depth/shape band.
The square shape keeps its edges (it is the pedal's hard switch), while knob
moves are one-pole smoothed.

`stereo_panner` modulates the channel's pan with the same three-shape LFO.
The insert chain is mono, so the engine does not pan inside it: the
`stereo_panner` insert is a pass-through that hands its LFO to the channel's
pan stage, which applies `pan + depth * lfo` per sample around the channel's
own pan (clamped to `-1..1`). `depth` is the swing in the `-1..1` field, so
depth 0 is exactly the plain pan and is bit-identical to it. When the rack
holds two panners, the last one in chain order wins; a bypassed panner is not
run, so it does not modulate. The browser mirrors this at the same place: the
panner insert is a pass-through, and `studioPanLfoAll` rides its LFO on the
channel's own pan stage after the chain, so the static channel pan and the
panner add on that one node. Because that stage is a mix stage, the panner is
heard on playback; it is not printed into a take (the same as the plain channel
pan).

The `sync` string never reaches either engine: the page sends `delay.time` in
seconds (up to 8) or an LFO `rate` in Hz, in the effect's own units.

## Reverb models

`model` is a whole number, quantised from the slider. Both implementations must
agree on the order; the sound may differ in detail (the Rust one is a generated
impulse, the browser one a `ConvolverNode` over the same shape).

| value | model | character |
| --- | --- | --- |
| 0 | Room | 0.8 s, strong early reflections, little low end |
| 1 | Spring | 1.8 s, metallic, bright, narrow |
| 2 | Plate | 2.2 s, dense, bright, no early gap |
| 3 | Hall | 3.4 s, long, dark tail |
| 4 | Cave | 6.0 s, very long, low-mid heavy |

The default model is **2 (Plate)**, which keeps an old `reverb2` patch sounding
like the pedal it was.

## Numbering that both sides must share

An index means the same thing everywhere; only the fine detail of the sound may
differ. These are pinned here so the Rust and browser implementations cannot
drift apart.

| control | values |
| --- | --- |
| `amp.cabinet` | 0 Combo 1x12, 1 Open 2x12, 2 Closed 4x12, 3 Tweed 4x10 |
| `autotune.scale` | 0 Major, 1 Minor, 2 Chromatic, 3 Pentatonic |
| `autotune.key` | 0..11 = C, C#, D, … B |
| `harmonizer.key` | 0..11 = C, C#, D, … B |
| `harmonizer.scale` | 0 Major, 1 Minor, 2 Chromatic, 3 Pentatonic |
| `harmonizer.degree` | 0..6 = 4th Below, 3rd Below, 2nd Below, Unison, 2nd Above, 3rd Above, 4th Above |
| `reverb.model` | 0..4 as above, default 2 |
| `tremolo.shape`, `stereo_panner.shape` | 0 Sine, 1 Triangle, 2 Square |

The UI slider is `0..100`; each implementation maps it to natural units. For the
controls that are amounts (gains, mixes, depths) the mapping is the slider over
100. For dB controls the mapping is fixed across both sides:

| control | UI 0..100 maps to |
| --- | --- |
| `equalizer.low/mid/high`, `amp.bass/mid/treble`, `tone.*` | -12 .. +12 dB |
| `master_eq.b32` … `master_eq.b16k` (and the `low`/`mid`/`high` aliases) | -12 .. +12 dB |
| `limiter.ceiling`, `maximizer.ceiling`, `master_limiter.ceiling` | -24 .. 0 dB |
| `limiter.release` | 10 .. 500 ms |
| `compressor.thresh` | -60 .. 0 dB |
| `compressor.ratio` | 1 .. 20 |
| `compressor.attack` | 1 .. 200 ms |
| `compressor.release` | 50 .. 1000 ms |
| `compressor.knee` | 0 .. 24 dB |
| `maximizer.loudness` | 0 .. 1 (the slider over 100) |
| `de_esser.thresh` | -60 .. 0 dB |
| `de_esser.freq` | 4000 .. 12000 Hz |
| `modulator.rate` | 0.1 .. 20 Hz |
| `pitch_shift.semitones` | -24 .. +24, rounded to a whole semitone |
| `gate.thresh` | -60 .. 0 dB |
| `gate.attack` | 0.1 .. 50 ms |
| `gate.hold` | 0 .. 500 ms |
| `gate.release` | 20 .. 1000 ms |
| `gate.range` | -80 .. 0 dB |
| `slider.rate` | 0.1 .. 20 Hz |
| `slider.duty` | 0.05 .. 0.95 (the open fraction) |
| `wah.rate` | 0.1 .. 20 Hz |
| `chorus.rate` | 0.05 .. 5 Hz |
| `vibrato.rate` | 0.1 .. 20 Hz |

## Master rack

The master chain is a fixed set of inserts applied to the mixer's stereo bus,
after every channel. The UI must expose them as one rack, not as a pedal on a
track. The order is the house's chain, not a per-song list:

1. `master_comp`
2. `master_eq`
3. `master_stereowidener` (browser only; a native take omits it)
4. `master_reverb`
5. `master_maximizer`
6. `master_limiter`

| name | controls |
| --- | --- |
| `master_comp` | `thresh`, `attack`, `mix` |
| `master_eq` | `b32`, `b64`, `b125`, `b250`, `b500`, `b1k`, `b2k`, `b4k`, `b8k`, `b16k` |
| `master_stereowidener` | `width`, `mix` |
| `master_reverb` | `mix`, `model`, `volume` |
| `master_maximizer` | `ceiling`, `loudness` |
| `master_limiter` | `ceiling`, `release` |

The master EQ is a **ten-band graphic**: one peaking bell per octave at 32, 64,
125, 250, 500 Hz and 1, 2, 4, 8, 16 kHz, Q 1.4, each fader -12 .. +12 dB. The
control names are `b32` … `b16k`. The three names the old three-knob master EQ
used — `low`, `mid`, `high` — are **legacy aliases** for `b125`, `b1k` and
`b8k`, so a song saved before the faders existed still loads and still moves
the same part of the mix. The native engine builds `GraphicEq`
(`engine/src/effect/graphic_eq.rs`); the browser builder is
`studioEffectGraphicEq` (`public/js/manager/studio/08_effects.js`), the same ten
bands as ten peaking biquads.

In Rust, the other `master_*` names map to the same effect implementations as
their channel versions; the prefix exists so the socket and the song document
can say where the insert belongs. `master_eq` is the exception: `InsertKind::MasterEq`
is its own kind, not the channel `equalizer`, because the two have different
controls and different circuits.

## A source's inserts in the house plan

The house plan (`docs/studio-audio-roadmap.md` §8) is one document for every
source, bus and sink, and a **source** may carry its own pedal board. This is
how a voice, a deck or the guitar is coloured without owning a Studio track:
the engine builds the chain on the source's signal, before any route's gain and
pan, so the effect belongs to the source rather than to one destination.

The field is `inserts` on a source in `lib/JawnOS/Audio/Plan.pm`. Its shape is
stable and is what the engine compiles:

```json
{
  "id": "voice", "kind": "peer", "machine": "table", "gain": 0.8,
  "inserts": [
    { "name": "reverb", "bypass": 0, "controls": { "mix": 0.35, "model": 2 } },
    { "name": "delay",  "bypass": 0, "controls": { "time": 0.25, "feedback": 0.3, "vol": 0.4 } }
  ]
}
```

| field | meaning |
| --- | --- |
| `gain` | the source's own trim, before its inserts and every route: the engine's `0..=4` recording gain, default unity |
| `name` | one canonical `InsertKind::parse` name from the table above; never a `master_` prefix and never `stereowidener`, which the native engine does not build |
| `bypass` | whole `0` or `1`; `1` keeps the insert in the chain and passes the signal through |
| `controls` | sparse map of that effect's own control names to **native units** (the dB, second, millisecond, hertz, 0..1 and index scales above), never the UI's 0..100 slider; an absent control is the effect's default |

Rules:

1. **Order is the chain.** The first array entry hears the source first; the last
   feeds the first route. Two entries may name the same effect.
2. **Only a source has inserts.** A sink takes what the buses send it; an insert
   on that edge belongs to the route, not the sink, and the write path refuses
   one.
3. **The manager owns the shape.** `audio_plan_normalize` keeps a known name and
   that effect's known controls, dropping an unknown name whole and a typo'd
   control from the map; `audio_plan_valid` refuses both instead of repairing a
   write. A chain is bounded at sixteen.
4. **The engine clamps a control.** Rule 3 of this document applies: a control
   thread may send anything, and the effect clamps it to its own range. The
   engine applies a plan's `controls` in each insert's own slot before the chain
   is prepared, so an effect starts at the declared value, not at its web
   default.
5. **A source with no `inserts` is an empty board.** Every plan written before
   this field normalises to `inserts: []`, so the engine reads one shape. A
   source with no `gain` is unity.
6. **The footswitch is live, not a plan field.** A `patch_source` param named
   `mute` moves the source's own mute gain without touching its trim; `status`
   reports the result in `source_effects[].mute`.

## Rules both sides obey

1. **Prepare allocates, process does not.** The audio thread has one period
   between blocks. No allocation, lock or panic inside `process`.
2. **Smoothing.** A knob move is a target, not a jump: one-pole smoothing with a
   short time constant, so a dragged slider cannot click.
3. **Clamp in the effect.** A control thread may send anything; the effect
   clamps to its own range and ignores NaN.
4. **Honest approximation.** `autotune` (JawnPitch in the UI) is a monophonic pitch corrector: it
   detects the input period, picks the nearest scale tone, and shifts with a
   short crossfaded delay line. It is not a polyphonic Antares clone, and it
   must be documented as such, never silently bypassed.
5. **A pedal is toggled, not removed.** Clicking a pedal's footswitch bypasses
   it in place; the insert stays in the rack and keeps its controls. Removing is
   a separate action.

## The control path

The page moves a knob; the engine hears it. Three addresses, one vocabulary:

```
POST /manager/studio/take  { action: "param", track: N,
                             name: "<insert>.<control>", value: V }
POST /manager/studio/take  { action: "param", target: "master",
                             name: "master_comp.thresh", value: V }
POST /manager/studio/take  { action: "param", target: "listen",
                             name: "<insert>.<control>", value: V }
```

`V` is in the effect's own units, not the slider's: the dB ranges, the
millisecond and hertz ranges and the 0..1 mixes above. The browser does the
0..100 mapping before it sends — the same mapping it applies to its own
`AudioParam`s — so the engine never has to guess which scale a number is on.
Whole-number controls (`reverb.model`, `amp.cabinet`, `autotune.key`,
`autotune.scale`) travel as their index.

The engine accepts `<insert>.<control>` only when that insert is in the armed
chain and that control belongs to it. Anything else is a refusal on the socket,
never a silent no-op. The master rack is a separate address because it is not a
track; `master_*` names resolve to the same effect implementations.

### Patch sources

A patchbay source's `gain` and `inserts` are the plan shape above: the chain
runs before that source's routes and sends, so the bus a take records is the
effected source and the mix hears the same signal. A stereo source (`device`,
`handset`) runs one independent instance of each effect per side, because an
effect is a mono processor.

A live knob is addressed to the source, not to a route:

```
POST /manager/sound/param  target=patch_source  source=N
                           name=gain|mute|<insert>.<control>  value=V
```

`source` is the 0-based index in the plan's `sources` array. The engine refuses
a source that is not in the running plan, and an insert the source did not arm.
`mute` is the source's own footswitch: `1` silences it without changing its
trim, `0` restores it. `status` reports every source's compiled chain, live
trim and mute as `source_effects: [{id, gain, mute, inserts: [names]}]`.

### Monitoring several inputs

The historical `listen` monitors one input. The same command accepts a
`channels` array instead of `channel`, and builds one strip per input, summed on
the output:

```
{"cmd":"listen","channels":[0,1],"gain":0.8,"pan":0,"inserts":["tone"]}
```

The single-input reply and `stop` shape are unchanged; a multi-input `status`
adds `channels: [..]` beside the first channel. `POST /manager/sound/monitor`
(`action=start|stop|status`, `channels=0,1` or a JSON array) exposes it to the
Sound page. When a plan is running, the patchbay is already the multi-source
monitor: every routed source mixes to the sink, and each source's inserts run
first.

A change is forwarded only while the engine is the path that is actually
playing (a take is armed, or live monitoring is on). The browser's own graph
stays authoritative when it is; a knob is not sent twice for one movement.

## Live input on the monitor bus

An engine take can send its live input to the monitor outputs without changing
what is recorded. Two `record` fields arm it:

| field | meaning |
| --- | --- |
| `monitor_input` | boolean, default `false`; `true` sums the take's live input into the monitor bus |
| `monitor_gain` | finite number, default `1.0`, clamped `0..=4`; trims live input on the monitor bus only |

The live input goes through each track's strip and then the monitor's master
chain, so it hears the same mastering as a monitor file. It is never written to
the take. `monitor_gain` `0` is silence, which is how the page mutes live input
without ending the take. A `monitor_input` take may have no `monitor` files: the
monitor runs for the take's length.

A track's plan entry also carries `channels`, a whole `1` or `2` and defaulting
to `1`. `1` reads the single device channel `input`; `2` reads `input` and
`input+1`, sums them at `0.5` each before the strip, and claims both channels.
Inputs stay unique by claimed channel, so a stereo pair at `0` and a mono at
`1` is refused (`tracks_json track 2 input 1 overlaps track 1's stereo pair
0-1`), and a claimed channel may not pass `31`.

While a take records, the page trims, mutes or starts its live input through
a fourth `param` target:

```
POST /manager/studio/take  { action: "param", target: "input",
                             name: "gain", value: V }
```

`gain` is the only name this target carries; anything else is refused
(`target "input" only carries "gain"`). `V` is a finite number clamped
`0..=4` and mirrored in `status`. With no take recording, the target answers
`no live input is being monitored`.

Every take builds the live ring, whether or not it monitors, and the capture
thread pushes into it only while the take is armed. A take armed with
`monitor_input` off is unarmed but ready, so a positive `param` gain arms it
mid-take: no restart, and nothing already recorded is lost. The ring was empty
before that point, so the monitor opens on the live edge rather than on a
backlog. The reply says which side of the edge the take is on:

```
{"ok":true,"target":"input","name":"gain","gain":1,"monitor_input":true}
```

`monitor_input` is `true` once the take is pushing, so a page reads the arming
from this answer instead of asking `status` again. A `0` gain only silences; a
silenced take stays unarmed until a positive value arrives. Arming probes the
outputs exactly as `record` does and leaves the take unarmed if that fails; a
take with no frames left refuses with `the take has no time left to monitor`.
A monitor `record` already started holds the same ring, so raising the gain on
an armed take, or on a monitor-file take armed with `monitor_input` off,
rebuilds nothing. A monitor that has already finished stays finished: arming
after its files have ended starts the push, and `monitor_dropped` counts what
no monitor was left to drain.
