/* [[js-split]]
   synth.js is part 1. The rest live in synth/ in name order:
     01_engine.js - the whole synth engine as one IIFE - attach - voices - patches - MIDI - panel
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
// JawnOS synth: a polyphonic synthesizer engine the studio hosts.
//
// One engine, one AudioContext. When the studio is open the engine rides the
// studio's context (so the synth is just another source on a channel: it can be
// armed, recorded and monitored like a mic); on its own window it makes its own
// context. It exposes window.jawnosSynth:
//
//   attach(ctx, destination)   build the engine on a context, feeding destination
//   noteOn(note, velocity)     a MIDI note number (60 = middle C) and 0..1
//   noteOff(note)  allNotesOff()
//   set(param, value)  setPatch(obj)  getPatch()  loadPreset(name)  presets()
//   voices()                   how many are sounding right now
//   midi.start()  midi.devices()  midi.select(id)  midi.onnotes(fn)
//
// Two voice engines, chosen by the patch: 'subtractive' (two oscillators and a
// noise transient through a resonant filter, each with its own ADSR and a shared
// LFO) and 'pluck' (Karplus-Strong: a noise burst into a tuned delay line, which
// is where a convincing plucked string/piano comes from without any samples).
//
// Polyphony is capped by patch.voices (32 by default) with oldest-voice stealing,
// so a held sustain pedal never runs away.

