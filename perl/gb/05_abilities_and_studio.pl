package gb;
use strict;
no warnings;

our $measures;

our $abilities = {
	notifications => {},
	category => {},
	description => {},
	duration => {},
	warranty => {},
	schedule => {},
	phone => {},
	phones => {},
	notes => {},
	email => {},
	emails => {},
	web => {},
	logo => {},
	address => {},
	specs => {},
	command => {},
	position => {},
	formulas => {},
	kill => {},
	cost => {},
	worth => {},
	minimum => {},
	aka => {},
	budget => {},
	goals => {},
	measures => {},
	packaging => {},
	record => { config => 'select', options => ['system', 'security', 'audio', 'video', 'screen'], formatted => 'yes' },
	currency => { config => 'select', options => [ grep { grep { $_ eq 'currency' }  @{$gb::measures->{$_}->{'types'}} } keys %{$measures} ]},
	payment_type => { config => 'select', options => [ '', 'cash', 'debit', 'credit', 'visa', 'mastercard', 'amex', 'interac', 'crypto', 'cheque', 'gift', 'other' ], formatted => 'yes' },
	unit => { config => 'select', options => [ sort keys %{$measures} ]},
	manufacturer => { config => 'select', options => [ ], formatted => 'yes' },
	inventory_method => { config => 'select', options => [ 'none', 'fifo', 'lifo', 'depreciate' ], formatted => 'yes' },
	stock_movement => { config => 'select', options => [ 'off', 'consume', 'produce' ], formatted => 'yes' },
	stock_item => {},
	stock_place => {},
	low_stock_days => {},
	urgent_stock_days => {},
	quantity => {},
	home_plate => {},
	nfc => {},
	navigation => { config => 'select', options => ['none','once','1s','3s','5s','10s','20s','30s','1m','2m','5m','7m','10m','20m','30m','45m','1h','2h','3h','6h','12h','24h','2d','3d','5d','1w','2w','3w','4w','1M'] },
	# birthday and evaluation wear the shape of an ability in the App panel (a date
	# input, the evaluation controls/report) but are special-cased there. Registering
	# them keeps the ability filter in /manager/configure/appointment_display from
	# dropping them when the panel refreshes just that one tile after a save.
	birthday => {},
	evaluation => {}
};

our $numerics = {
	1 => 'one',
	2 => 'two',
	3 => 'three',
	4 => 'four',
	5 => 'five',
	6 => 'six',
	7 => 'seven',
	8 => 'eight',
	9 => 'nine',
	10 => 'ten',
	11 => 'eleven',
	12 => 'twelve',
	13 => 'thirteen',
	14 => 'fourteen',
	15 => 'fifteen',
	16 => 'sixteen',
	17 => 'seventeen',
	18 => 'eighteen',
	19 => 'nineteen',
	20 => 'twenty',
	21 => 'twentyone',
	22 => 'twentytwo',
	23 => 'twentythree',
	24 => 'twentyfour',
	25 => 'twentyfive',
	26 => 'twentysix',
	27 => 'twentyseven',
	28 => 'twentyeight',
	29 => 'twentynine',
	30 => 'thirty',
	31 => 'thirtyone',
	32 => 'thirtytwo',
	33 => 'thirtythree',
	34 => 'thirtyfour',
	35 => 'thirtyfive',
	36 => 'thirtysix',
	37 => 'thirtyseven',
	38 => 'thirtyeight',
	39 => 'thirtynine',
	40 => 'forty'
};

our $embedded_components = {
	'button' => { 'direction' => 'input' },
	'relay' => { 'direction' => 'output' }, 
	'switch' => { 'direction' => 'input',  }, 
	'pot' => { 'direction' => 'input', 'state' => 'numeric' },
	'led' => { 'direction' => 'output' },
	'servo' => { 'direction' => 'output', 'state' => 'numeric' }
};

# The tempo divisions the sync text field offers. These are datalist choices,
# not a closed set: the page's parser accepts any `n/d` fraction and the `d`
# (dotted) and `t` (triplet) suffixes, a bare whole-note count, and a manual
# `250ms`. `off` returns the effect to its manual knob.
my @tempo_divisions = qw(off 1/16 1/8 1/4 1/2 3/4 1 2 3 4 1/8d 1/8t 250ms);

our $studio = {
	tempo_divisions => [ @tempo_divisions ],
	knobs => [
		{ control => 'gain', colour => 'cyan', flip => 180, placement => 'channel' },
		{ control => 'treble', colour => 'yellow', flip => 180, placement => 'channel' },
		{ control => 'mid', colour => 'green', flip => 180, placement => 'channel' },
		{ control => 'bass', colour => 'red', flip => 180, placement => 'channel' },
		{ control => 'pan', colour => 'blue', flip => 180, placement => 'channel' },
		{ control => 'volume', colour => 'grey_plain', placement => 'metronome' }
	],
	pedals => [{ 
		# Jtune is a chromatic tuner, not an effect: its artwork's yellow panel is
		# the tuner display, its pink switch starts and stops the listening, and it
		# has no audio implementation, so it never joins the rack.
		name => 'Jtune',
		image => 'jtune',
		tuner => 1,
		buttons => [{
			control => 'automatic', colour => 'ruby_red', left => '17%', top => '76%', height => '15%', width => '25%', status => 'depressed', hint => 'Start or stop the tuner'
		}]
	},{ 
		name => 'CompressionX',
		image => 'compressionX',
		knobs => [{
			control => 'attack', colour => 'aqua_logo', flip => 20, left => '7%', top => '26%', width => '25%'
		},{
			control => 'thresh', colour => 'teal_rounded', width => '25%', flip => 20, range => .75, left => '36%', top => '26%'
		},{
			control => 'mix', colour => 'aqua_logo', flip => 20, left => '63%', top => '26%', width => '25%'
		}]
	},{ 
		name => 'Distorjawn',
		image => 'distorjawn',
		knobs => [{
			control => 'gain', colour => 'grey_plain', left => '29%', top => '26%', width => '33%'
		}]
	},{ 
		name => 'Delayed',
		image => 'delayed',
		knobs => [{
			control => 'time', colour => 'star_trek',  left => '3%', top => '30%', width => '25%', range => .75
		},{
			control => 'vol', colour => 'orange_grower', direction => 'counter', width => '23%', flip => 5, range => .8, left => '34%', top => '31%'
		},{
			control => 'feedback', colour => 'fire_j', flip => 0, range => .75, left => '64%', top => '32%', width => '25%'
		}]
	},{ 
		name => 'reverb2',
		image => 'reverb2',
		knobs => [{
			control => 'mix', colour => 'green_rounded', flip => 180, left => '7%', top => '28%', 'width' => '60px'
		},{
			control => 'volume', colour => 'red_numbered', direction => 'counter', width => '60px', flip => 180, range => .65, left => '53%', top => '26%'
		}]
	},{
		name => 'JawnSynth',
		image => 'synth',
		knobs => [{
			control => 'cutoff', colour => 'orange', left => '6%', top => '24%', width => '24%'
		},{
			control => 'reso', colour => 'red', left => '37%', top => '24%', width => '24%'
		},{
			control => 'attack', colour => 'green', left => '68%', top => '24%', width => '24%'
		},{
			control => 'release', colour => 'blue', left => '6%', top => '58%', width => '24%'
		},{
			control => 'detune', colour => 'yellow', left => '37%', top => '58%', width => '24%'
		},{
			control => 'lfo', colour => 'pink', left => '68%', top => '58%', width => '24%'
		}]
	}],
	# The drum machine's voices. `name` is the wire name the browser renders and
	# plays; `key` is the computer key it starts on; `note` is the Web MIDI note
	# it answers. No samples: every voice is built from oscillators and noise in
	# the browser once (see public/js/manager/studio/11_drums.js).
	drums => [
		{ name => 'kick', label => 'Kick', key => 'a', note => 36 },
		{ name => 'snare', label => 'Snare', key => 's', note => 38 },
		{ name => 'closed_hat', label => 'Closed Hat', key => 'd', note => 42 },
		{ name => 'open_hat', label => 'Open Hat', key => 'f', note => 46 },
		{ name => 'clap', label => 'Clap', key => 'g', note => 39 },
		{ name => 'low_tom', label => 'Low Tom', key => 'h', note => 41 },
		{ name => 'high_tom', label => 'High Tom', key => 'j', note => 45 },
		{ name => 'rim', label => 'Rim', key => 'k', note => 37 }
	],
	# The drum kits. `name` is the wire name saved in the song and compared by the
	# browser; `label` is what people read in the Kit list. A kit is the same
	# eight voices with its own shapes on top (see studioDrumsKitSpecs in
	# public/js/manager/studio/11_drums.js), so a kit never changes a row, key or
	# step. Acoustic is the unfiltered base every other kit overrides.
	drum_kits => [
		{ name => 'acoustic', label => 'Acoustic' },
		{ name => 'electronic', label => 'Electronic' },
		{ name => 'techno', label => 'Techno' },
		{ name => 'beats', label => 'Beats' },
		{ name => 'latin', label => 'Latin' },
		{ name => 'pearl', label => 'Pearl' },
		{ name => 'tama', label => 'Tama' },
		{ name => 'gretsch', label => 'Gretsch' },
		{ name => '808', label => '808' },
		{ name => 'metal', label => 'Metal' }
	],
	# The shared effect contract (docs/studio-effects.md) and the circuit map (docs/pedal-audit.md). `effects` is what the
	# rack palette offers and what the browser's studioInsert() builds; `master`
	# is the fixed chain after the mix. A control with `options` is a dropdown,
	# a control with `typed` is a visible text field plus a datalist (the tempo
	# sync divisions), and the rest are 0..100 sliders. Keep these names and
	# their order in step with engine/src/effect.rs, or the palette offers a
	# pedal the engine ignores. stereowidener and stereo_panner are the two
	# deliberate exceptions: both need the L/R pair the engine's mono insert
	# chain does not hold, so the browser owns them.
	effects => {
		reverb => { label => 'Reverb', controls => [
			{ control => 'mix', label => 'Mix' },
			{ control => 'volume', label => 'Volume' },
			{ control => 'model', label => 'Model', options => [ qw(Room Spring Plate Hall Cave) ] }
		] },
		flanger => { label => 'Flanger', controls => [
			{ control => 'rate', label => 'Rate' },
			{ control => 'depth', label => 'Depth' },
			{ control => 'feedback', label => 'Feedback' },
			{ control => 'mix', label => 'Mix' },
			{ control => 'sync', label => 'Sync', typed => 1, options => [ @tempo_divisions ], hint => 'A note division, milliseconds, or off' }
		] },
		fuzz => { label => 'Fuzz', controls => [
			{ control => 'gain', label => 'Gain' },
			{ control => 'tone', label => 'Tone' },
			{ control => 'level', label => 'Level' }
		] },
		amp => { label => 'Amp', controls => [
			{ control => 'gain', label => 'Gain' },
			{ control => 'bass', label => 'Bass' },
			{ control => 'mid', label => 'Mid' },
			{ control => 'treble', label => 'Treble' },
			# 0 Combo (1x12), 1 Open (2x12), 2 Closed (4x12), 3 Tweed (4x10)
			{ control => 'cabinet', label => 'Cabinet', hint => 'Choose the cabinet', options => [ qw(Combo Open Closed Tweed) ] }
		] },
		limiter => { label => 'Limiter', controls => [
			{ control => 'ceiling', label => 'Ceiling' },
			{ control => 'release', label => 'Release' }
		] },
		# The wire name stays autotune for the engine, the socket and saved
		# songs; only the label people read is JawnPitch. Do not rename the key.
		autotune => { label => 'JawnPitch', controls => [
			{ control => 'speed', label => 'Speed' },
			{ control => 'amount', label => 'Amount' },
			{ control => 'key', label => 'Key', hint => 'Choose the key', options => [ qw(C C# D D# E F F# G G# A A# B) ] },
			# 0 Major, 1 Minor, 2 Chromatic, 3 Pentatonic
			{ control => 'scale', label => 'Scale', hint => 'Choose the scale', options => [ qw(Major Minor Chromatic Pentatonic) ] }
		] },
		equalizer => { label => 'Equaliser', controls => [
			{ control => 'low', label => 'Low' },
			{ control => 'mid', label => 'Mid' },
			{ control => 'high', label => 'High' }
		] },
		tone => { label => 'Tone', controls => [
			{ control => 'bass', label => 'Bass' },
			{ control => 'mid', label => 'Mid' },
			{ control => 'treble', label => 'Treble' },
			{ control => 'gain', label => 'Gain' }
		] },
		distortion => { label => 'Distortion', controls => [
			{ control => 'drive', label => 'Drive' }
		] },
		delay => { label => 'Delay', controls => [
			{ control => 'time', label => 'Time' },
			{ control => 'feedback', label => 'Feedback' },
			{ control => 'vol', label => 'Volume' },
			{ control => 'sync', label => 'Sync', typed => 1, options => [ @tempo_divisions ], hint => 'A note division, milliseconds, or off' }
		] },
		compressor => { label => 'Compressor', controls => [
			{ control => 'thresh', label => 'Threshold' },
			{ control => 'attack', label => 'Attack' },
			{ control => 'ratio', label => 'Ratio' },
			{ control => 'release', label => 'Release' },
			{ control => 'knee', label => 'Knee' },
			{ control => 'mix', label => 'Mix' }
		] },
		tremolo => { label => 'Tremolo', controls => [
			{ control => 'rate', label => 'Rate' },
			{ control => 'depth', label => 'Depth' },
			{ control => 'shape', label => 'Shape', hint => 'Choose the shape', options => [ qw(Sine Triangle Square) ] },
			{ control => 'sync', label => 'Sync', typed => 1, options => [ @tempo_divisions ], hint => 'A note division, milliseconds, or off' }
		] },
		# Browser only: a true panner needs the L/R pair the engine's mono insert
		# chain does not hold, so `InsertKind::parse` refuses the name and a native
		# take omits the pedal (engine/src/effect.rs).
		stereo_panner => { label => 'Stereo Panner', controls => [
			{ control => 'rate', label => 'Rate' },
			{ control => 'depth', label => 'Depth' },
			{ control => 'shape', label => 'Shape', hint => 'Choose the shape', options => [ qw(Sine Triangle Square) ] },
			{ control => 'sync', label => 'Sync', typed => 1, options => [ @tempo_divisions ], hint => 'A note division, milliseconds, or off' }
		] },
		# Browser only: the native insert chain is mono, so there is no L/R pair
		# to take a mid/side matrix from and engine/src/effect.rs has no kind for
		# it. A take omits the pedal instead of faking it.
		stereowidener => { label => 'Stereo Widener', controls => [
			{ control => 'width', label => 'Width' },
			{ control => 'mix', label => 'Mix' }
		] }
	},
	# The order the Add list offers them. The entries are wire names; the Add
	# list shows each effect's label (autotune appears as JawnPitch).
	palette => [ qw(reverb flanger fuzz amp limiter tremolo stereo_panner autotune equalizer tone distortion delay compressor stereowidener) ],
	# A palette effect with no hand-drawn artwork is drawn from the theme instead:
	# the template gives it the same body, one knob per slider (the colours below,
	# in control order) and a dropdown per choice, so its tile matches the artwork
	# pedals rather than being a bare on/off button. The colours are knob artwork
	# the shelf already ships; the list at the end is the fallback rotation.
	palette_art => {
		flanger   => [ qw(orange blue pink green) ],
		fuzz      => [ qw(cyan yellow red) ],
		amp       => [ qw(cyan red green yellow) ],
		limiter   => [ qw(red_numbered blue) ],
		tremolo   => [ qw(cyan pink blue) ],
		stereo_panner => [ qw(blue cyan pink) ],
		autotune  => [ qw(cyan pink) ],
		equalizer => [ qw(red green yellow) ],
		tone      => [ qw(red green yellow cyan) ],
	},
	palette_knob_colours => [ qw(red yellow green blue orange pink cyan navy) ],
	# The order of the reverb model dropdown; both implementations agree.
	reverb_models => [ qw(Room Spring Plate Hall Cave) ],
	# The fixed mastering chain: after every channel, before the destination.
	master => [
		{ name => 'master_comp', label => 'Compressor', controls => [
			{ control => 'thresh', label => 'Threshold' },
			{ control => 'attack', label => 'Attack' },
			{ control => 'mix', label => 'Mix' }
		] },
		# A ten-band graphic equaliser, one vertical fader per octave. The
		# control names are the contract's (`docs/studio-effects.md`); `layout`
		# tells the template to render the wide fader block instead of knobs.
		{ name => 'master_eq', label => 'Equaliser', layout => 'graphic', controls => [
			{ control => 'b32',  label => '32' },
			{ control => 'b64',  label => '64' },
			{ control => 'b125', label => '125' },
			{ control => 'b250', label => '250' },
			{ control => 'b500', label => '500' },
			{ control => 'b1k',  label => '1k' },
			{ control => 'b2k',  label => '2k' },
			{ control => 'b4k',  label => '4k' },
			{ control => 'b8k',  label => '8k' },
			{ control => 'b16k', label => '16k' }
		] },
		{ name => 'master_stereowidener', label => 'Stereo Widener', controls => [
			{ control => 'width', label => 'Width' },
			{ control => 'mix', label => 'Mix' }
		] },
		{ name => 'master_reverb', label => 'Reverb', controls => [
			{ control => 'mix', label => 'Mix' },
			{ control => 'model', label => 'Model', options => [ qw(Room Spring Plate Hall Cave) ] },
			{ control => 'volume', label => 'Volume' }
		] },
		{ name => 'master_maximizer', label => 'Maximiser', controls => [
			{ control => 'ceiling', label => 'Ceiling' },
			{ control => 'loudness', label => 'Loudness' }
		] },
		{ name => 'master_limiter', label => 'Limiter', controls => [
			{ control => 'ceiling', label => 'Ceiling' },
			{ control => 'release', label => 'Release' }
		] }
	]
};
