# Pedal audit — the circuit behind each Studio pedal

> Companion to `docs/studio-effects.md`. That file is the wire contract: the
> names, the controls, the natural units and the numbering both implementations
> share. This file is the other half: **what each pedal is actually modelling**.
>
> The rule for the audit is simple. A pedal keeps the contract's name and
> controls, and the sound comes from a real circuit instead of a generic curve.
> Where the circuit and the contract disagree (the JH-2 has no tone knob), the
> extra control is a documented mod, never a silent invention.

## The pedals

| Pedal | Real circuit | Controls (unchanged) | Native model | Browser mirror |
| --- | --- | --- | --- | --- |
| `fuzz` | **JH-2**, a Fuzz Face-derived two-transistor fuzz. The published schematic uses MPSA18 NPN devices; the engine uses germanium parameters (hFE ~75, soft 1.45-ideality knee, leakage). | `gain`, `tone`, `level` | `engine/src/effect/fuzz.rs`: the four circuit nodes are solved with Ebers-Moll transistors and the schematic's resistors; the asymmetric curve is built once in `prepare`. `gain` is the 1 kΩ fuzz pot's AC gain; `tone` is the **feedback-cap mod** (the real pedal has no tone knob); `level` is the 500 kΩ output pot. | `studioJH2Curve` is an asymmetric transfer table in the same family, not the solved node voltages, with the 7 Hz input and 25 Hz output coupling caps and a tone lowpass. |
| `amp` | **Four valve voices**: 6V6 combo 1×12, 6L6 open 2×12, EL34 closed 4×12, tweed 4×10. | `gain`, `bass`, `mid`, `treble`, `cabinet` | `engine/src/effect/amp.rs`: two single-ended valve stages with interstage coupling, a power-stage sag, the passive tone stack, and a **generated 256-tap cabinet impulse** (cone/box resonances, baffle step, mic reflection) convolved directly. `cabinet` chooses the whole voice, because box and amplifier are one voicing. | `studioTubeCurve` + the shelf tone stack + a `ConvolverNode` over `studioCabinetImpulse`, the same four voices. |
| `distortion` | **ProCo RAT**: LM308 gain stage, gain-dependent bandwidth and slew, silicon diode hard clip, post-clip lowpass. | `drive` | `engine/src/effect.rs`: RAT gain 2..200 from the drive travel, 4× oversampled diode clip, fixed 4 kHz filter (the contract has no Filter knob). | `preGain → WaveShaper(diode) → lowpass`; the LM308's falling bandwidth needs an AudioWorklet for the full model. |
| `delay` | **Boss DM-2**: BBD line, NE570-style 2:1 compander, bandwidth that narrows as the clock slows, lowpass in the feedback. | `time`, `feedback`, `vol` | `engine/src/effect.rs`: envelope compressor/expander, anti-alias and reconstruction one-poles that follow the delay time, deterministic clock feedthrough gated by the signal. | `DynamicsCompressor → DelayNode → lowpass`, with the lowpass in the feedback; the expander needs an AudioWorklet. |
| `compressor` | **MXR Dyna Comp**: CA3080 OTA, full-wave detector, fast attack / slow release, level-dependent squash. | `thresh`, `attack`, `ratio`, `release`, `knee`, `mix` | `engine/src/effect.rs`: the six contract knobs map onto the OTA's detector, slope and knee; a `tanh` output stage models the finite swing. | `DynamicsCompressor → WaveShaper(tanh)` + mix; the level-dependent squash needs an AudioWorklet. |
| `tone` | **Passive FMV tone stack** (Marshall JMP50 values: 470 pF treble, 33 kΩ slope, 22 nF bass/mid, 250 k/1 M/25 k pots). | `bass`, `mid`, `treble`, `gain` | `engine/src/effect.rs`: a 5×5 nodal solve at the block edge, so the three controls load each other the way the circuit does. `gain` stays an output trim. | The browser keeps the three-biquad approximation; the exact interaction needs an AudioWorklet. |
| `equalizer` | **Baxandall bass/treble** with shared feedback loading, plus a 1 kHz mid bell. | `low`, `mid`, `high` | `engine/src/effect/equalizer.rs`: one coupled second-order bass/treble section whose poles shift with the balance, then the mid peaking section. Flat is bit-exactly transparent. | `IIRFilterNode` for the coupled section; live knobs rebuild it (the current three biquads are the cheap approximation). |
| `flanger` | **Electro-Harmonix Electric Mistress**: SAD1024 BBD, input compander, output expander, colour feedback, 6.8 kHz reconstruction. | `rate`, `depth`, `feedback`, `mix` | `engine/src/effect/flanger.rs`: clocked BBD with triangle LFO, compander, filtered colour feedback, clock-tracking bandwidth. | The node graph (gain → compressor → delay → 6.8 kHz LP/HP → mix) is close; the clock term and the expander need an AudioWorklet. |
| `phaser` | **MXR Phase 90**: four JFET allpass stages swept together by an LFO, summed with the dry signal at a fixed 50/50 blend. Its one knob is Speed. | `rate`, `depth`, `feedback`, `mix` | `engine/src/effect/phaser.rs`: four first-order allpass stages at one swept corner (`a = (1 − tan(π·fc/fs)) / (1 + tan(π·fc/fs))`), an LFO from `rate`, a `depth`-scaled sweep, the last stage returned to the input for resonance and a wet/dry mix. The Phase 90 has no depth, feedback or mix control: those three are the documented mods. | `studioEffectPhaser`: four staggered `allpass` biquads, one LFO through a per-stage depth gain, feedback from the last stage through a DelayNode (a WebAudio cycle needs one) and an internal dry/wet pair feeding the shell's wet node. |
| `reverb` | **Fender 6G15 spring** (model 1) and **EMT 140 plate** (model 2); Room/Hall/Cave share the same mechanical network at different scales. | `mix`, `volume`, `model` | `engine/src/reverb.rs`: the spring is two dispersive allpass loops; the plate is short lines plus diffusers and a Householder feedback matrix. Still convolution, still zero added latency. | The browser can build the same tank offline into the `ConvolverNode`'s buffer. |
| `limiter` | **UREI 1176**: FET shunt, 20 µs attack, program-dependent release, soft FET knee, hard ceiling. | `ceiling`, `release` | `engine/src/effect/limiter.rs`: peak follower with a sustain memory blending fast and slow release; the output can never pass the ceiling. | Needs an AudioWorklet for the real detector; `DynamicsCompressor` is the current approximation. |
| `maximizer` | The same 1176 detector behind a 0..18 dB drive. | `ceiling`, `loudness` | `engine/src/effect/maximizer.rs`: shares `FetDetector` with the limiter. | Same as the limiter. |
| `autotune` (JawnPitch) | Not an analogue pedal: a monophonic pitch corrector. | `speed`, `amount`, `key`, `scale` | `engine/src/effect/autotune.rs`: autocorrelation period, nearest scale tone, two crossfaded delay taps. Deliberately not polyphonic. | The browser has its own detector and grain shifter. |
| `stereowidener` | A mid/side width control, not a pedal. | `width`, `mix` | Browser only; the native insert chain is mono. | `studioEffectStereoWidener`. |
| `stereo_panner` | An LFO on the channel's pan; not a pedal. | `rate`, `depth`, `shape` | `engine/src/effect/stereo_panner.rs`: a pass-through insert whose `rate`, `depth` and `shape` configure the channel's pan LFO. The channel applies `pan + depth * lfo` per sample at its pan stage, where the L/R pair exists; depth 0 is the plain pan exactly, and the last panner in chain order wins. | `studioEffectStereoPanner`, a `StereoPannerNode` with an LFO on its `pan`; a tempo-synced rate is resolved to Hz before it is sent. |
| `tuner` (Jtune) | Listen-only chromatic tuner. | — | No audio path, no `InsertKind`. | The browser taps its input for the display. |

## What the audit changes, in one paragraph

The fuzz and the amp are the two the person hears as wrong: the old fuzz was a
gated `tanh`, and the old amp was one `tanh` plus four biquads, which is why it
read as compression. Both now derive their shape from the circuit (the JH-2's
solved node voltages; the valve stages and a generated speaker impulse). The
other pedals keep their contract but gain a named circuit: RAT, DM-2, Dyna Comp,
FMV tone stack, Baxandall, Electric Mistress, Phase 90, 6G15/EMT 140, 1176.

## The honest approximation

- The engine's fuzz is **quasi-static**: the coupling and bypass caps are
  filters around a solved DC curve, not extra solved nodes. There is no charge
  storage, zener noise, or per-device leakage spread.
- The amp's cabinet is a **short generated impulse**, not a sampled cabinet. It
  has the speaker's resonances, the box's roll-off and one mic reflection; it
  does not have a real room or a measured microphone.
- The browser cannot run the nonlinear detectors of the 1176, the Dyna Comp or
  the DM-2 expander without an `AudioWorklet`. Those pedals keep the node-graph
  approximation there; the engine is the reference.
- Controls are the contract's, not the pedal's. The JH-2's two real knobs are
  Fuzz and Level; `tone` is the feedback-cap mod. The RAT's Filter and the
  1176's ratio are fixed values because the contract has no control for them.
  The Phase 90's one knob is Speed and its dry/wet is fixed at 50/50, so
  `depth`, `feedback` and `mix` are mods: `depth` opens the sweep span,
  `feedback` adds resonance the pedal does not have, and `mix` moves the fixed
  blend.
- The panner is not an L/R insert: the engine pans at the channel stage, so
  its LFO moves the channel's existing pan rather than a separate stereo
  position. A centred channel therefore sweeps both speakers and a hard-left
  one only reaches the middle, because the result is clamped to `-1..1`.

## Verification

`cd engine && cargo test --offline -j 2 -- --test-threads=1` covers the
per-circuit tests inside each module: the fuzz curve's monotonic, asymmetric
shape and the crest factor falling with the fuzz pot; the amp's valve drive,
cabinet top-end and closed-box low end; the flanger's BBD bandwidth and
compander; the reverb's spring comb and plate density; the 1176's ceiling and
release; the Baxandall's flat transparency and mid interaction; the RAT, DM-2,
Dyna Comp and FMV stack.

## Next

The remaining browser mirrors (the 1176, Dyna Comp, DM-2 expander, the exact
FMV stack and the Baxandall's coupled section) are AudioWorklet work. The
engine models are the reference and are already in the tree.
