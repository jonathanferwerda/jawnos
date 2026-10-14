// JawnOS synth preset library: twelve instruments, twenty sounds each, the most
// popular first. Pure data - synth.js reads window.jawnosSynthFamilies and builds
// a patch per entry by copying the family's base patch and applying the entry's
// overrides (dotted keys reach nested filter/amp/fenv/lfo, osc1./osc2. reach the
// oscillator, and engine/wave/noise/damping/brightness/drive/voices/transpose are
// patch-level). Kept apart from the engine so the sound list can grow without
// touching it.
window.jawnosSynthFamilies = [
	{
		name: 'Acoustic Piano',
		base: {
			engine: 'subtractive', wave: 'piano', noise: 0.16, voices: 32,
			osc: [{ octave: 0, detune: 0, level: 1.0 }, { octave: 0, detune: 4, level: 0.5 }],
			filter: { type: 'lowpass', cutoff: 3800, q: 0.6, env: 0.25, keytrack: 0.35 },
			amp: { a: 0.004, d: 2.6, s: 0.0, r: 0.5 },
			fenv: { a: 0.002, d: 1.4, s: 0.0, r: 0.4 },
			lfo: { rate: 0, pitch: 0, cutoff: 0, amp: 0 }
		},
		presets: [
			['Concert Grand', {}],
			['Bright Grand', { 'filter.cutoff': 5400, 'filter.env': 0.3 }],
			['Soft Grand', { 'filter.cutoff': 2500, 'amp.d': 3.0, noise: 0.1 }],
			['Mellow Grand', { 'filter.cutoff': 2000, 'osc2.detune': 3 }],
			['Honky Tonk', { 'osc1.detune': -7, 'osc2.detune': 9, 'filter.cutoff': 3300 }],
			['Upright', { 'filter.cutoff': 2900, noise: 0.24, 'amp.d': 2.2 }],
			['Jazz Grand', { 'filter.cutoff': 3000, 'filter.q': 0.5, 'amp.d': 3.4 }],
			['Pop Grand', { 'filter.cutoff': 4600, drive: 0.06 }],
			['Rock Grand', { 'filter.cutoff': 5200, drive: 0.14 }],
			['Ballad Grand', { 'amp.a': 0.012, 'amp.d': 3.6, 'filter.cutoff': 2700 }],
			['Stadium Grand', { 'filter.cutoff': 4800, 'amp.d': 3.2 }],
			['Vintage Grand', { 'filter.cutoff': 3000, drive: 0.09, 'osc2.detune': 8 }],
			['Cinematic Grand', { 'amp.a': 0.02, 'amp.d': 4.2, 'filter.cutoff': 3100, 'lfo.rate': 0.3, 'lfo.pitch': 0.008 }],
			['Dark Grand', { 'filter.cutoff': 1800 }],
			['Detuned Grand', { 'osc1.detune': -9, 'osc2.detune': 9 }],
			['Studio Grand', { 'filter.cutoff': 3600, drive: 0.04 }],
			['Warm Grand', { 'filter.cutoff': 2400, 'osc2.level': 0.62 }],
			['Live Grand', { 'filter.cutoff': 4400, 'amp.r': 0.7 }],
			['Octave Grand', { 'osc2.octave': 1, 'osc2.level': 0.35 }],
			['Piano Pad', { 'amp.a': 0.06, 'amp.d': 3.8, 'amp.s': 0.18, 'filter.cutoff': 2300, 'lfo.rate': 0.25, 'lfo.pitch': 0.01 }]
		]
	},
	{
		name: 'Electric Piano',
		base: {
			engine: 'subtractive', wave: 'sine', noise: 0.05, voices: 24,
			osc: [{ octave: 0, detune: 0, level: 1.0 }, { octave: 1, detune: 3, level: 0.3 }],
			filter: { type: 'lowpass', cutoff: 2600, q: 0.9, env: 0.4, keytrack: 0.5 },
			amp: { a: 0.004, d: 1.8, s: 0.0, r: 0.4 },
			fenv: { a: 0.002, d: 0.9, s: 0.0, r: 0.3 },
			lfo: { rate: 3.6, pitch: 0, cutoff: 0, amp: 0.12 }
		},
		presets: [
			['Tine EP', {}],
			['Suitcase EP', { 'lfo.amp': 0.2, 'lfo.rate': 4.4 }],
			['Wurly', { noise: 0.12, 'filter.cutoff': 2200, 'filter.env': 0.6, drive: 0.1 }],
			['Dyno', { 'filter.cutoff': 3400, 'filter.env': 0.3 }],
			['Reed EP', { 'osc2.level': 0.5, 'osc2.octave': 2, 'filter.cutoff': 2000 }],
			['Bell EP', { 'osc2.octave': 3, 'osc2.level': 0.35, 'amp.d': 2.6 }],
			['Warm EP', { 'filter.cutoff': 1900, 'osc2.level': 0.22 }],
			['Chorus EP', { 'lfo.amp': 0.28, 'lfo.rate': 1.8 }],
			['Tremolo EP', { 'lfo.amp': 0.35, 'lfo.rate': 5.4 }],
			['Soft Tines', { 'amp.d': 2.4, 'filter.cutoff': 2200, noise: 0.03 }],
			['Bite EP', { 'filter.env': 0.8, 'filter.cutoff': 2800, drive: 0.12 }],
			['Vintage EP', { drive: 0.12, 'lfo.amp': 0.16, 'filter.cutoff': 2300 }],
			['FM EP', { 'osc2.octave': 2, 'osc2.detune': 5, 'osc2.level': 0.45, 'filter.cutoff': 3200 }],
			['Smooth EP', { 'amp.a': 0.02, 'amp.d': 2.2, 'filter.cutoff': 2000 }],
			['Bright EP', { 'filter.cutoff': 4200, 'filter.env': 0.5 }],
			['Phase EP', { 'lfo.amp': 0.22, 'lfo.rate': 0.7 }],
			['Ballad EP', { 'amp.a': 0.01, 'amp.d': 2.6, 'filter.cutoff': 2100 }],
			['Funk EP', { 'filter.env': 0.7, 'filter.q': 3, drive: 0.1 }],
			['Dreamy EP', { 'amp.d': 3.0, 'lfo.amp': 0.18, 'lfo.rate': 2.6, 'filter.cutoff': 1800 }],
			['Glass EP', { 'osc2.octave': 3, 'osc2.level': 0.4, 'filter.cutoff': 4200, noise: 0.01 }]
		]
	},
	{
		name: 'Organ',
		base: {
			engine: 'subtractive', wave: 'organ', noise: 0.0, voices: 16,
			osc: [{ octave: 0, detune: 0, level: 1.0 }, { octave: 1, detune: 0, level: 0.4 }],
			filter: { type: 'lowpass', cutoff: 5000, q: 0.4, env: 0.0, keytrack: 0.4 },
			amp: { a: 0.01, d: 0.1, s: 0.95, r: 0.1 },
			fenv: { a: 0.01, d: 0.1, s: 1.0, r: 0.1 },
			lfo: { rate: 6.4, pitch: 0, cutoff: 0, amp: 0.06 }
		},
		presets: [
			['Drawbar Organ', {}],
			['Full Drawbars', { 'osc2.level': 0.7 }],
			['Jazz Organ', { 'lfo.amp': 0.12, 'lfo.rate': 6.0, 'filter.cutoff': 4200 }],
			['Rock Organ', { drive: 0.18, 'filter.cutoff': 5600 }],
			['Gospel Organ', { 'lfo.amp': 0.2, 'lfo.rate': 6.8, 'filter.cutoff': 5200 }],
			['Church Organ', { 'osc2.octave': 1, 'osc2.level': 0.5, 'amp.a': 0.05, 'filter.cutoff': 6000 }],
			['Pipe Organ', { 'amp.a': 0.08, 'amp.r': 0.3, 'filter.cutoff': 6500, 'lfo.amp': 0.0 }],
			['Percussive Organ', { 'amp.d': 0.3, 'amp.s': 0.6, 'filter.cutoff': 5000 }],
			['Vox Organ', { wave: 'strings', 'filter.cutoff': 3800, 'lfo.amp': 0.24, 'lfo.rate': 6.2 }],
			['Farfisa', { wave: 'square', 'filter.cutoff': 4400 }],
			['Rotary Slow', { 'lfo.amp': 0.3, 'lfo.rate': 0.8 }],
			['Rotary Fast', { 'lfo.amp': 0.3, 'lfo.rate': 7.5 }],
			['Ballad Organ', { 'filter.cutoff': 3200, 'lfo.amp': 0.14 }],
			['Bright Organ', { 'filter.cutoff': 6800 }],
			['Dark Organ', { 'filter.cutoff': 2200 }],
			['Chapel', { 'amp.a': 0.1, 'amp.r': 0.5, 'filter.cutoff': 5600, 'lfo.amp': 0.0 }],
			['Combo Organ', { wave: 'square', 'filter.cutoff': 4000, drive: 0.08 }],
			['Synth Organ', { wave: 'sawtooth', 'filter.cutoff': 3600, 'lfo.amp': 0.1 }],
			['Cathedral', { 'amp.a': 0.2, 'amp.r': 0.9, 'filter.cutoff': 6000, 'osc2.octave': 2, 'osc2.level': 0.35 }],
			['Tonewheel', { 'osc2.octave': 1, 'osc2.level': 0.45, 'lfo.amp': 0.08, 'lfo.rate': 6.4 }]
		]
	},
	{
		name: 'Strings',
		base: {
			engine: 'subtractive', wave: 'strings', noise: 0.02, voices: 24,
			osc: [{ octave: 0, detune: -12, level: 0.6 }, { octave: 0, detune: 12, level: 0.6 }],
			filter: { type: 'lowpass', cutoff: 2400, q: 0.8, env: 0.3, keytrack: 0.3 },
			amp: { a: 0.5, d: 0.8, s: 0.8, r: 0.9 },
			fenv: { a: 0.6, d: 1.0, s: 0.6, r: 0.8 },
			lfo: { rate: 5.0, pitch: 0.05, cutoff: 0.08, amp: 0 }
		},
		presets: [
			['Warm Ensemble', {}],
			['Slow Strings', { 'amp.a': 0.9, 'amp.r': 1.4, 'filter.cutoff': 2000 }],
			['String Pad', { 'amp.a': 0.7, 'amp.s': 0.9, 'filter.cutoff': 1800, 'lfo.rate': 0.4, 'lfo.cutoff': 0.2 }],
			['Violin Section', { 'filter.cutoff': 3200, 'lfo.pitch': 0.07, 'lfo.rate': 5.6 }],
			['Cello Section', { transpose: -12, 'filter.cutoff': 2000 }],
			['Cinematic Strings', { 'amp.a': 0.8, 'filter.cutoff': 2600, 'lfo.cutoff': 0.15 }],
			['Analog Strings', { wave: 'sawtooth', 'filter.cutoff': 2200, 'lfo.rate': 0.5, 'lfo.pitch': 0.08 }],
			['Octave Strings', { 'osc2.octave': 1, 'osc2.level': 0.5 }],
			['Bright Strings', { 'filter.cutoff': 4200 }],
			['Soft Strings', { 'filter.cutoff': 1600, 'amp.a': 0.7 }],
			['Marcato', { 'amp.a': 0.15, 'amp.d': 0.5, 'amp.s': 0.85, 'filter.env': 0.5 }],
			['Legato', { 'amp.a': 0.35, 'amp.r': 0.6 }],
			['Tremolo Strings', { 'lfo.amp': 0.35, 'lfo.rate': 8.0 }],
			['Chamber', { 'filter.cutoff': 2800, 'lfo.pitch': 0.04, 'lfo.rate': 4.4 }],
			['Symphony', { voices: 32, 'filter.cutoff': 2600, 'osc1.detune': -16, 'osc2.detune': 16 }],
			['Vintage Strings', { 'filter.cutoff': 2000, 'lfo.rate': 6.0, 'lfo.pitch': 0.06, drive: 0.05 }],
			['Attack Strings', { 'amp.a': 0.08, 'amp.d': 0.6, 'filter.env': 0.6 }],
			['Airy Strings', { 'lfo.cutoff': 0.25, 'lfo.rate': 0.35, 'filter.cutoff': 2200 }],
			['Deep Strings', { transpose: -12, 'osc2.octave': 0, 'filter.cutoff': 1500 }],
			['String Swell', { 'amp.a': 1.2, 'amp.s': 0.85, 'filter.cutoff': 2600, 'fenv.d': 1.6 }]
		]
	},
	{
		name: 'Brass',
		base: {
			engine: 'subtractive', wave: 'sawtooth', noise: 0.03, voices: 16,
			osc: [{ octave: 0, detune: -6, level: 0.8 }, { octave: 0, detune: 6, level: 0.8 }],
			filter: { type: 'lowpass', cutoff: 2000, q: 1.2, env: 0.6, keytrack: 0.4 },
			amp: { a: 0.06, d: 0.4, s: 0.7, r: 0.3 },
			fenv: { a: 0.08, d: 0.5, s: 0.5, r: 0.3 },
			lfo: { rate: 5.0, pitch: 0.04, cutoff: 0, amp: 0 }
		},
		presets: [
			['Brass Section', {}],
			['Trumpet', { transpose: 12, 'filter.cutoff': 2600, 'filter.env': 0.7 }],
			['Trombone', { transpose: -12, 'filter.cutoff': 1600 }],
			['French Horn', { 'amp.a': 0.15, 'filter.cutoff': 1400, 'lfo.rate': 4.4, 'lfo.pitch': 0.03 }],
			['Tuba', { transpose: -24, 'filter.cutoff': 900 }],
			['Synth Brass', { 'filter.cutoff': 2400, 'filter.q': 3, 'lfo.rate': 0.4, 'lfo.pitch': 0.07 }],
			['Fanfare', { 'filter.cutoff': 3000, 'filter.env': 0.8, transpose: 7 }],
			['Muted Trumpet', { 'filter.cutoff': 1800, 'filter.type': 'bandpass', 'filter.q': 2 }],
			['Big Brass', { voices: 24, 'filter.cutoff': 2000, 'osc1.detune': -10, 'osc2.detune': 10 }],
			['Soft Brass', { 'filter.cutoff': 1300, 'filter.env': 0.4, 'amp.a': 0.12 }],
			['Bright Brass', { 'filter.cutoff': 3600, 'filter.env': 0.7 }],
			['Analog Brass', { drive: 0.12, 'filter.q': 4, 'lfo.rate': 0.5, 'lfo.pitch': 0.06 }],
			['Stab Brass', { 'amp.a': 0.02, 'amp.d': 0.3, 'amp.s': 0.5, 'filter.env': 0.8 }],
			['Epic Brass', { voices: 32, 'filter.cutoff': 2200, 'osc1.detune': -16, 'osc2.detune': 16 }],
			['Horn Swell', { 'amp.a': 0.4, 'amp.s': 0.85, 'fenv.d': 1.2 }],
			['Brass Pad', { 'amp.a': 0.6, 'amp.r': 1.0, 'filter.cutoff': 1500 }],
			['Jazz Horns', { 'filter.cutoff': 1700, 'filter.env': 0.45, 'lfo.rate': 5.2, 'lfo.pitch': 0.05 }],
			['Vintage Brass', { drive: 0.08, 'filter.cutoff': 1800, 'lfo.rate': 5.6, 'lfo.pitch': 0.05 }],
			['Punch Brass', { 'filter.env': 0.9, 'filter.cutoff': 2600, 'amp.a': 0.03 }],
			['Solo Trumpet', { transpose: 12, voices: 2, 'filter.cutoff': 2800, 'lfo.rate': 5.5, 'lfo.pitch': 0.06 }]
		]
	},
	{
		name: 'Woodwind',
		base: {
			engine: 'subtractive', wave: 'triangle', noise: 0.08, voices: 8,
			osc: [{ octave: 0, detune: 0, level: 1.0 }, { octave: 1, detune: 2, level: 0.2 }],
			filter: { type: 'lowpass', cutoff: 2600, q: 0.6, env: 0.3, keytrack: 0.5 },
			amp: { a: 0.05, d: 0.3, s: 0.85, r: 0.2 },
			fenv: { a: 0.05, d: 0.3, s: 0.7, r: 0.2 },
			lfo: { rate: 5.2, pitch: 0.03, cutoff: 0, amp: 0 }
		},
		presets: [
			['Flute', { transpose: 12 }],
			['Clarinet', { wave: 'square', 'filter.cutoff': 2000, noise: 0.03 }],
			['Oboe', { wave: 'sawtooth', 'filter.cutoff': 2800, noise: 0.06 }],
			['Bassoon', { transpose: -12, 'filter.cutoff': 1400, noise: 0.05 }],
			['Piccolo', { transpose: 24, 'filter.cutoff': 3200 }],
			['Recorder', { transpose: 12, wave: 'square', 'filter.cutoff': 2400, noise: 0.05 }],
			['Pan Flute', { noise: 0.16, 'amp.a': 0.09, 'lfo.rate': 4.6, 'lfo.pitch': 0.04 }],
			['Sax', { wave: 'sawtooth', 'filter.cutoff': 2400, 'lfo.rate': 5.4, 'lfo.pitch': 0.05, noise: 0.05 }],
			['Synth Flute', { 'lfo.rate': 0.4, 'lfo.pitch': 0.05, 'filter.cutoff': 3000 }],
			['Airy Flute', { noise: 0.2, 'filter.cutoff': 2200 }],
			['Woodwind Ensemble', { voices: 16, 'osc1.detune': -8, 'osc2.detune': 8 }],
			['Breath Flute', { noise: 0.24, 'amp.a': 0.06 }],
			['Shaku', { transpose: 12, noise: 0.18, 'filter.cutoff': 2000 }],
			['Native Flute', { noise: 0.2, 'lfo.rate': 4.8, 'lfo.pitch': 0.04, 'filter.cutoff': 2400 }],
			['Tin Whistle', { transpose: 12, wave: 'sine', 'filter.cutoff': 3400, noise: 0.03 }],
			['Irish Flute', { noise: 0.14, 'filter.cutoff': 2600 }],
			['Bass Flute', { transpose: -12, 'filter.cutoff': 1600, noise: 0.12 }],
			['Vibrato Sax', { 'lfo.rate': 6.0, 'lfo.pitch': 0.07, wave: 'sawtooth', 'filter.cutoff': 2400 }],
			['Warm Reed', { wave: 'sawtooth', 'filter.cutoff': 1800, 'filter.q': 2 }],
			['Soft Clarinet', { wave: 'square', 'filter.cutoff': 1500, noise: 0.04 }]
		]
	},
	{
		name: 'Guitar & Plucked',
		base: {
			engine: 'pluck', damping: 0.5, brightness: 0.6, voices: 24,
			amp: { a: 0.001, d: 1.6, s: 0.0, r: 0.35 },
			lfo: { rate: 0, pitch: 0, cutoff: 0, amp: 0 }
		},
		presets: [
			['Nylon Pluck', { damping: 0.35, brightness: 0.45 }],
			['Steel Guitar', { damping: 0.55, brightness: 0.8 }],
			['Harpsichord', { damping: 0.72, brightness: 0.9, 'amp.d': 1.0, 'amp.r': 0.22 }],
			['Acoustic Guitar', { damping: 0.45, brightness: 0.65 }],
			['Electric Clean', { damping: 0.6, brightness: 0.55, 'amp.d': 2.2 }],
			['Twelve String', { damping: 0.5, brightness: 0.75, 'amp.d': 2.0 }],
			['Koto', { damping: 0.4, brightness: 0.7, transpose: 12 }],
			['Sitar', { damping: 0.3, brightness: 0.9, transpose: 12 }],
			['Banjo', { damping: 0.65, brightness: 0.95, 'amp.d': 1.0 }],
			['Mandolin', { damping: 0.55, brightness: 0.85, transpose: 12, 'amp.d': 1.2 }],
			['Harp', { damping: 0.25, brightness: 0.55, 'amp.d': 2.8, 'amp.r': 0.7 }],
			['Clav', { damping: 0.7, brightness: 0.85, 'amp.d': 0.7, 'amp.r': 0.15 }],
			['Marimba', { damping: 0.6, brightness: 0.5, 'amp.d': 0.9 }],
			['Kalimba', { damping: 0.5, brightness: 0.8, transpose: 12, 'amp.d': 1.4 }],
			['Ukulele', { damping: 0.4, brightness: 0.8, transpose: 12, 'amp.d': 1.3 }],
			['Lute', { damping: 0.35, brightness: 0.5 }],
			['Dulcimer', { damping: 0.3, brightness: 0.7, transpose: 12 }],
			['Zither', { damping: 0.28, brightness: 0.75 }],
			['Pizzicato', { damping: 0.68, brightness: 0.7, 'amp.d': 0.5, 'amp.r': 0.15 }],
			['Toy Piano', { damping: 0.75, brightness: 0.95, transpose: 12, 'amp.d': 0.9 }]
		]
	},
	{
		name: 'Bells & Mallets',
		base: {
			engine: 'subtractive', wave: 'bell', noise: 0.02, voices: 16,
			osc: [{ octave: 0, detune: 0, level: 1.0 }, { octave: 1, detune: 7, level: 0.4 }],
			filter: { type: 'bandpass', cutoff: 3000, q: 1.2, env: 0.2, keytrack: 0.6 },
			amp: { a: 0.002, d: 3.5, s: 0.0, r: 1.2 },
			fenv: { a: 0.002, d: 2.0, s: 0.0, r: 0.8 },
			lfo: { rate: 0, pitch: 0, cutoff: 0, amp: 0 }
		},
		presets: [
			['Tubular Bells', {}],
			['Bell', { 'amp.d': 3.0 }],
			['Church Bell', { transpose: -12, 'amp.d': 4.5 }],
			['Glockenspiel', { transpose: 24, 'filter.cutoff': 5000, 'amp.d': 1.6 }],
			['Celesta', { transpose: 12, wave: 'sine', 'osc2.octave': 2, 'osc2.level': 0.3, 'amp.d': 2.4 }],
			['Vibraphone', { wave: 'sine', 'osc2.octave': 1, 'osc2.level': 0.22, 'lfo.rate': 5.5, 'lfo.amp': 0.25, 'amp.d': 2.6, 'amp.r': 0.9 }],
			['Music Box', { transpose: 24, wave: 'sine', 'osc2.octave': 2, 'osc2.level': 0.25, 'amp.d': 1.9, 'amp.r': 0.6 }],
			['Chimes', { 'amp.d': 4.0, 'filter.cutoff': 4200 }],
			['Gamelan', { transpose: 12, 'filter.cutoff': 3600, 'amp.d': 1.8 }],
			['Marimba Bell', { wave: 'sine', 'osc2.octave': 2, 'osc2.level': 0.16, 'amp.d': 0.9 }],
			['Glass Bell', { 'filter.cutoff': 5600, 'amp.d': 3.2 }],
			['Dream Bell', { 'amp.a': 0.01, 'amp.d': 4.2, 'lfo.rate': 0.3, 'lfo.pitch': 0.02 }],
			['Ice Bell', { transpose: 12, 'filter.cutoff': 6000 }],
			['Steel Drum', { transpose: 12, 'filter.cutoff': 3400, 'amp.d': 1.4 }],
			['Temple Bell', { transpose: -12, 'amp.d': 5.0, 'filter.cutoff': 1600 }],
			['Wine Glass', { transpose: 24, 'filter.cutoff': 5200, 'amp.d': 3.0, 'lfo.rate': 0.2, 'lfo.pitch': 0.02 }],
			['Clock Chime', { 'amp.d': 2.0, 'filter.cutoff': 3800 }],
			['Xylophone', { transpose: 24, wave: 'triangle', 'osc2.octave': 2, 'amp.d': 0.7 }],
			['Bell Pad', { 'amp.a': 0.1, 'amp.d': 4.0, 'amp.s': 0.2, 'filter.cutoff': 3000 }],
			['Crystal', { transpose: 24, 'filter.cutoff': 6400, 'amp.d': 3.6 }]
		]
	},
	{
		name: 'Bass',
		base: {
			engine: 'subtractive', wave: 'square', noise: 0.0, voices: 6,
			osc: [{ octave: -1, detune: 0, level: 1.0 }, { octave: 0, detune: 0, level: 0.25 }],
			filter: { type: 'lowpass', cutoff: 900, q: 4.0, env: 0.7, keytrack: 0.1 },
			amp: { a: 0.008, d: 0.5, s: 0.6, r: 0.15 },
			fenv: { a: 0.005, d: 0.35, s: 0.1, r: 0.2 },
			lfo: { rate: 0, pitch: 0, cutoff: 0, amp: 0 }
		},
		presets: [
			['Sub Bass', {}],
			['Deep Sub', { transpose: -12, 'osc2.level': 0.1 }],
			['Finger Bass', { wave: 'sawtooth', 'filter.cutoff': 1200, drive: 0.05 }],
			['Pick Bass', { wave: 'sawtooth', 'filter.cutoff': 1600, 'filter.env': 0.8, drive: 0.08 }],
			['Synth Bass', { wave: 'sawtooth', 'filter.cutoff': 1400, 'filter.q': 6 }],
			['Acid Bass', { 'filter.q': 12, 'filter.env': 0.9, wave: 'sawtooth' }],
			['Reese Bass', { 'osc1.detune': -14, 'osc2.detune': 14, wave: 'sawtooth', 'filter.cutoff': 800 }],
			['Growl Bass', { drive: 0.3, 'filter.q': 8, 'lfo.rate': 6, 'lfo.cutoff': 0.4 }],
			['Round Bass', { wave: 'sine', 'filter.cutoff': 700, 'filter.env': 0.4 }],
			['Upright Bass', { wave: 'triangle', 'filter.cutoff': 600, 'amp.d': 0.9, 'amp.s': 0.2 }],
			['Slap Bass', { 'filter.env': 1.0, drive: 0.12, 'filter.cutoff': 2200 }],
			['Wobble Bass', { 'lfo.rate': 4, 'lfo.cutoff': 0.6, 'filter.q': 9 }],
			['Warm Bass', { wave: 'sine', 'filter.cutoff': 850, drive: 0.05 }],
			['Pluck Bass', { 'filter.env': 0.9, 'amp.d': 0.25, 'amp.s': 0.2 }],
			['FM Bass', { 'osc2.octave': 1, 'osc2.level': 0.4, 'osc2.detune': 3, 'filter.cutoff': 1600 }],
			['Octave Bass', { 'osc2.octave': 1, 'osc2.level': 0.5 }],
			['Muted Bass', { 'filter.cutoff': 500, 'amp.d': 0.4, 'amp.s': 0.1 }],
			['Bass Pad', { 'amp.a': 0.4, 'amp.s': 0.8, 'filter.cutoff': 800 }],
			['Distorted Bass', { drive: 0.45, 'filter.cutoff': 1500 }],
			['Clean Bass', { 'osc2.level': 0.2, 'filter.cutoff': 1000, wave: 'triangle' }]
		]
	},
	{
		name: 'Lead',
		base: {
			engine: 'subtractive', wave: 'sawtooth', noise: 0.0, voices: 8,
			osc: [{ octave: 0, detune: -10, level: 0.8 }, { octave: 0, detune: 10, level: 0.8 }],
			filter: { type: 'lowpass', cutoff: 3200, q: 3.5, env: 0.6, keytrack: 0.4 },
			amp: { a: 0.01, d: 0.3, s: 0.7, r: 0.25 },
			fenv: { a: 0.02, d: 0.5, s: 0.3, r: 0.3 },
			lfo: { rate: 5.2, pitch: 0.06, cutoff: 0, amp: 0 }
		},
		presets: [
			['Saw Lead', {}],
			['Square Lead', { wave: 'square' }],
			['Super Saw', { voices: 16, 'osc1.detune': -18, 'osc2.detune': 18, 'filter.q': 2.5 }],
			['Sync Lead', { 'filter.q': 8, 'filter.env': 0.8 }],
			['Portamento Lead', { 'amp.a': 0.02, 'lfo.rate': 0.3, 'lfo.pitch': 0.05 }],
			['Bright Lead', { 'filter.cutoff': 5200 }],
			['Detuned Lead', { 'osc1.detune': -24, 'osc2.detune': 24 }],
			['Screamer', { drive: 0.35, 'filter.q': 6 }],
			['Solo Lead', { voices: 2, 'filter.cutoff': 3000 }],
			['Hard Lead', { drive: 0.25, wave: 'square' }],
			['Soft Lead', { 'filter.cutoff': 1800, 'filter.q': 1.5, 'amp.a': 0.05 }],
			['Pulse Lead', { wave: 'square', 'filter.cutoff': 2600, 'lfo.rate': 0.4, 'lfo.pitch': 0.07 }],
			['Fifth Lead', { 'osc2.octave': 1, 'osc2.detune': 7, 'osc2.level': 0.6 }],
			['Octave Lead', { 'osc2.octave': 1, 'osc2.level': 0.5 }],
			['Whistle Lead', { wave: 'sine', 'filter.cutoff': 4200, 'lfo.rate': 5.6, 'lfo.pitch': 0.08 }],
			['Retro Lead', { drive: 0.12, 'lfo.rate': 5.4, 'lfo.pitch': 0.06 }],
			['Trance Lead', { voices: 16, 'filter.cutoff': 3800, 'filter.q': 4, 'amp.a': 0.005 }],
			['Vocal Lead', { 'filter.type': 'bandpass', 'filter.q': 3, 'filter.cutoff': 2200 }],
			['Lead Stack', { voices: 24, 'osc1.detune': -12, 'osc2.detune': 12, 'filter.cutoff': 3000 }],
			['Mono Lead', { voices: 1, 'filter.cutoff': 3400, drive: 0.1 }]
		]
	},
	{
		name: 'Pad',
		base: {
			engine: 'subtractive', wave: 'sawtooth', noise: 0.0, voices: 24,
			osc: [{ octave: 0, detune: -7, level: 0.7 }, { octave: 0, detune: 7, level: 0.7 }],
			filter: { type: 'lowpass', cutoff: 1400, q: 1.4, env: 0.5, keytrack: 0.2 },
			amp: { a: 0.9, d: 1.2, s: 0.75, r: 1.6 },
			fenv: { a: 1.2, d: 1.5, s: 0.4, r: 1.2 },
			lfo: { rate: 0.5, pitch: 0.04, cutoff: 0.15, amp: 0 }
		},
		presets: [
			['Warm Pad', {}],
			['Soft Pad', { 'filter.cutoff': 1000, 'amp.a': 1.4 }],
			['Air Pad', { 'filter.cutoff': 2200, 'lfo.rate': 0.25, 'lfo.cutoff': 0.3 }],
			['Bright Pad', { 'filter.cutoff': 2800 }],
			['Dark Pad', { 'filter.cutoff': 700 }],
			['Sweep Pad', { 'fenv.d': 3.0, 'fenv.s': 0.6, 'filter.env': 0.7 }],
			['Choir Pad', { wave: 'strings', 'filter.cutoff': 1800, 'lfo.rate': 0.4, 'lfo.pitch': 0.05 }],
			['Analog Pad', { 'lfo.rate': 0.6, 'lfo.pitch': 0.07, 'lfo.cutoff': 0.2 }],
			['Evolving Pad', { 'fenv.d': 4.0, 'lfo.rate': 0.15, 'lfo.cutoff': 0.4 }],
			['Glass Pad', { wave: 'sine', 'osc2.octave': 2, 'osc2.level': 0.3, 'filter.cutoff': 3200 }],
			['Dream Pad', { 'amp.a': 1.6, 'lfo.rate': 0.3, 'lfo.cutoff': 0.25 }],
			['Halo Pad', { wave: 'sine', 'filter.cutoff': 2600, 'lfo.amp': 0.1, 'lfo.rate': 0.4 }],
			['Ambient Pad', { 'amp.a': 2.0, 'amp.r': 2.4, 'lfo.rate': 0.2, 'lfo.cutoff': 0.3 }],
			['Deep Pad', { transpose: -12, 'filter.cutoff': 800 }],
			['Shimmer Pad', { 'osc2.octave': 2, 'osc2.detune': 12, 'filter.cutoff': 3000, 'lfo.rate': 0.5, 'lfo.pitch': 0.05 }],
			['Motion Pad', { 'lfo.rate': 0.25, 'lfo.cutoff': 0.5, 'lfo.pitch': 0.05 }],
			['Bowed Pad', { wave: 'strings', 'amp.a': 1.2, 'lfo.rate': 0.4, 'lfo.pitch': 0.06 }],
			['Strings Pad', { 'osc1.detune': -14, 'osc2.detune': 14, 'filter.cutoff': 1600 }],
			['Slow Pad', { 'amp.a': 1.8, 'amp.r': 2.0 }],
			['Space Pad', { voices: 32, 'filter.cutoff': 1200, 'lfo.rate': 0.12, 'lfo.cutoff': 0.35 }]
		]
	},
	{
		name: 'Synth Poly',
		base: {
			engine: 'subtractive', wave: 'sawtooth', noise: 0.0, voices: 16,
			osc: [{ octave: 0, detune: -5, level: 0.8 }, { octave: 1, detune: 5, level: 0.4 }],
			filter: { type: 'lowpass', cutoff: 2600, q: 1.8, env: 0.45, keytrack: 0.3 },
			amp: { a: 0.02, d: 0.6, s: 0.5, r: 0.5 },
			fenv: { a: 0.03, d: 0.8, s: 0.3, r: 0.5 },
			lfo: { rate: 0.6, pitch: 0.03, cutoff: 0.1, amp: 0 }
		},
		presets: [
			['Poly Synth', {}],
			['Brass Poly', { 'filter.env': 0.7, 'filter.cutoff': 2400 }],
			['String Poly', { 'amp.a': 0.4, 'amp.s': 0.8, 'filter.cutoff': 2000 }],
			['Pluck Poly', { 'amp.a': 0.005, 'amp.d': 0.4, 'amp.s': 0.1, 'filter.env': 0.8 }],
			['Bell Poly', { 'osc2.octave': 2, 'osc2.level': 0.3, 'amp.d': 1.6, 'amp.s': 0.0 }],
			['Organ Poly', { wave: 'organ', 'amp.s': 0.9, 'filter.cutoff': 4000 }],
			['Square Poly', { wave: 'square', 'filter.cutoff': 2400 }],
			['Octave Poly', { 'osc2.octave': 1, 'osc2.level': 0.6 }],
			['Fifth Poly', { 'osc2.octave': 1, 'osc2.detune': 7, 'osc2.level': 0.5 }],
			['Detuned Poly', { 'osc1.detune': -14, 'osc2.detune': 14 }],
			['Bright Poly', { 'filter.cutoff': 4200 }],
			['Dark Poly', { 'filter.cutoff': 1400 }],
			['Stab Poly', { 'amp.a': 0.005, 'amp.d': 0.25, 'amp.s': 0.2, 'filter.env': 0.9 }],
			['Sweep Poly', { 'filter.env': 0.9, 'fenv.d': 2.0 }],
			['Retro Poly', { drive: 0.1, 'lfo.rate': 5.0, 'lfo.pitch': 0.05 }],
			['Glass Poly', { wave: 'sine', 'osc2.octave': 2, 'osc2.level': 0.35, 'filter.cutoff': 3600 }],
			['Choir Poly', { wave: 'strings', 'filter.cutoff': 1800, 'lfo.rate': 0.5, 'lfo.pitch': 0.05 }],
			['Warm Poly', { 'filter.cutoff': 1800, 'osc2.level': 0.3 }],
			['Mono Poly', { 'lfo.rate': 0.4, 'lfo.pitch': 0.06, 'filter.q': 3 }],
			['Digital Poly', { wave: 'square', 'osc2.octave': 2, 'osc2.level': 0.25, 'filter.cutoff': 3400 }]
		]
	}
];
