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

our $studio = {
	knobs => [
		{ control => 'gain', colour => 'cyan', flip => 180, placement => 'channel' },
		{ control => 'treble', colour => 'yellow', flip => 180, placement => 'channel' },
		{ control => 'mid', colour => 'green', flip => 180, placement => 'channel' },
		{ control => 'bass', colour => 'red', flip => 180, placement => 'channel' },
		{ control => 'pan', colour => 'blue', flip => 180, placement => 'channel' },
		{ control => 'volume', colour => 'grey_plain', placement => 'metronome' }
	],
	pedals => [{ 
		name => 'Jtune',
		image => 'jtune',
		buttons => [{
			control => 'automatic', colour => 'ruby_red', left => '17%', top => '76%', height => '15%', width => '25%', status => 'depressed'
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
	}]
};
