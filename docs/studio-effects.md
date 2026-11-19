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

**Jtune is not an effect.** It is a chromatic tuner planned for the shelf, with
no audio implementation: it is not an `InsertKind`, it has no alias, and a
legacy `Jtune` entry in a song is dropped on load rather than mapped to
`autotune`.

| name | purpose | controls (UI `0..100`) |
| --- | --- | --- |
| `reverb` | the reverb family | `mix`, `volume`, `model` |
| `flanger` | swept comb | `rate`, `depth`, `feedback`, `mix` |
| `fuzz` | hard, gated distortion | `gain`, `tone`, `level` |
| `amp` | amplifier + cabinet | `gain`, `bass`, `mid`, `treble`, `cabinet` |
| `limiter` | peak limiter | `ceiling`, `release` |
| `autotune` | monophonic pitch correction (JawnPitch in the UI) | `speed`, `amount`, `key`, `scale` |
| `equalizer` | three-band tone shaping | `low`, `mid`, `high` |
| `tone` | the strip's own bass/mid/treble (existing) | `bass`, `mid`, `treble`, `gain` |
| `distortion` | existing | `drive` |
| `delay` | existing | `time`, `feedback`, `vol` |
| `compressor` | existing | `thresh`, `attack`, `ratio`, `release`, `knee`, `mix` |

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
| `reverb.model` | 0..4 as above, default 2 |

The UI slider is `0..100`; each implementation maps it to natural units. For the
controls that are amounts (gains, mixes, depths) the mapping is the slider over
100. For dB controls the mapping is fixed across both sides:

| control | UI 0..100 maps to |
| --- | --- |
| `equalizer.low/mid/high`, `amp.bass/mid/treble`, `tone.*` | -12 .. +12 dB |
| `limiter.ceiling`, `maximizer.ceiling`, `master_limiter.ceiling` | -24 .. 0 dB |
| `limiter.release` | 10 .. 500 ms |
| `compressor.thresh` | -60 .. 0 dB |
| `compressor.ratio` | 1 .. 20 |
| `compressor.attack` | 1 .. 200 ms |
| `compressor.release` | 50 .. 1000 ms |
| `compressor.knee` | 0 .. 24 dB |
| `maximizer.loudness` | 0 .. 1 (the slider over 100) |

## Master rack

The master chain is a fixed set of inserts applied to the mixer's stereo bus,
after every channel. The UI must expose them as one rack, not as a pedal on a
track.

| name | controls |
| --- | --- |
| `master_comp` | `thresh`, `attack`, `mix` |
| `master_eq` | `low`, `mid`, `high` |
| `master_reverb` | `mix`, `model`, `volume` |
| `master_maximizer` | `ceiling`, `loudness` |
| `master_limiter` | `ceiling`, `release` |

In Rust, `master_*` maps to the same effect implementations as the channel
versions; the prefix exists so the socket and the song document can say where
the insert belongs.

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

While a take records with live input, the page trims or mutes it through a
fourth `param` target:

```
POST /manager/studio/take  { action: "param", target: "input",
                             name: "gain", value: V }
```

`gain` is the only name this target carries; anything else is refused
(`target "input" only carries "gain"`). `V` is a finite number clamped
`0..=4` and mirrored in `status`. A take with no live input answers
`no live input is being monitored`.
