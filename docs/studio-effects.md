# Studio effects — the shared contract

> One effect list, two implementations: the browser (`public/js/manager/studio.js`,
> WebAudio) and the native engine (`engine/src/effect.rs`, Rust). The UI slider is
> always `0..100`; each side maps it to its own natural units. A name or control
> added on one side must be added on the other, or the pedal board will offer a
> pedal the engine silently ignores.

## Insert kinds

`InsertKind::parse` (Rust) and `studioInsert` (JS) accept these names. The
`reverb2` name is kept as an alias of `reverb` so old songs still load.

| name | purpose | controls (UI `0..100`) |
| --- | --- | --- |
| `reverb` | the reverb family | `mix`, `volume`, `model` |
| `flanger` | swept comb | `rate`, `depth`, `feedback`, `mix` |
| `fuzz` | hard, gated distortion | `gain`, `tone`, `level` |
| `amp` | amplifier + cabinet | `gain`, `bass`, `mid`, `treble`, `cabinet` |
| `limiter` | peak limiter | `ceiling`, `release` |
| `autotune` | monophonic pitch correction | `speed`, `amount`, `key`, `scale` |
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
4. **Honest approximation.** `autotune` is a monophonic pitch corrector: it
   detects the input period, picks the nearest scale tone, and shifts with a
   short crossfaded delay line. It is not a polyphonic Antares clone, and it
   must be documented as such, never silently bypassed.
5. **A pedal is toggled, not removed.** Clicking a pedal's footswitch bypasses
   it in place; the insert stays in the rack and keeps its controls. Removing is
   a separate action.
