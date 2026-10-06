#!/usr/bin/perl


use strict;
no warnings;

require './subroutines.pl';
use Mojo::Cache;


package gb;
our $pwd = `pwd`;
chomp $pwd;
our $count = 0;
our $duty_time = &subs::rightNow();
our $ws = {};
our $remote_ws = {};
our $mailws = {};
our $paperboy = {};
our $subprocessed = 0;
our $remote = {};
our $pamphlet = "";
our $syncing = 'no';
our $ws_workers = 1;
our $signatorial;
our $suds;
our $secret_maker;
our $father_time = {};
our $utility_functions_watcher = 0;
our @ports = qw/PORT_AHOY PORT_MSG PORT_BELL PORT_ARM PORT_BESTOW PORT_DOCK PORT_COMS PORT_SSH PORT_MAIL/;
our $pen = { '__statements' => [], '__lexicon' => [] };
our $universal_splitter = "--simple--split--and--whatnot--";
our $jcache = Mojo::Cache->new(max_keys => 100);
our $user_agent = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36';
our $last_update = &subs::newest_folder_checker();
our $database_holder = {};
our $gallery_thumbnails = 75;
our $tmp_dir = &subs::home('~/.president');
our $dump_dir = $tmp_dir;
our $terminal_forker;
our $ws_apps = [ 'music', 'server', 'tab' ];
if (&subs::device_setter() ne 'mobile') {
	$tmp_dir = '/tmp';
}

our $planet_radius = 6372.8;
our $site_types = {

	'private' => { colour => 'yellow', icon => '/images/decipherable/home.png', name => 'private', rating => 1 },
	'public' => { colour => 'lightgreen', icon => '/images/make believe/crown.png', name => 'public', rating => 2 },
	'dangerous' => { colour => 'red', icon => '/images/make believe/explosion.png', name => 'dangerous', rating => 3 }
};

our $last_updater = sub() {
	return &subs::newest_folder_checker();
};
our $forbidden = {
	tables => ['cache', 'magazine', 'devices', 'remote_machines', 'neighbour_link', 'websocket_messages', 'websockets', 'security', 'tickets', 'tunnels' ]
};

our $capabilities = {
	mobile => {
		camera => [ 0, 1 ]
	},
	computer => {
		camera => [ 'webcam' ],
		scan => [ 'adf', 'flatbed' ]
	},
	server => {
		scan => [ 'adf', 'flatbed' ]
	}
};


our $timeouts = {
	'alarm_haircut' => { interval => 10 * 60, toggle => 'off', timeout => 30 },
	'housekeeping' => { interval => 60 * 60, toggle => 'off', beaconable => 'yes', timeout => 30 },
	'budget' => { interval => 60 * 20, toggle => 'off', beaconable => 'yes', timeout => 180 },
	'clothesline' => { interval => 5 * 60, toggle => 'off', beaconable => 'yes', timeout => 180 },
	'tasks' => { interval => 5 * 60, toggle => 'off', beaconable => 'yes', timeout => 180 },
	'remote_machine_sync' => { interval => (2 * 60), interval_divider => 10, last_run => &subs::rightNow(), toggle => 'off', timeout => 1000 },
	'navigation' => { interval => 10 * 60, interval_divider => 10, last_run => &subs::rightNow(), toggle => 'off', timeout => 90 },
	'sms' => { interval => 30 * 10, toggle => 'off', timeout => 90 },
	'backups' => { interval => 1 * 60 * 60, toggle => 'on', beaconable => 'yes', timeout => 360 },
	'headless_browser' => { interval => 10 * 60, toggle => 'off', beaconable => 'yes', timeout => 370 },
	'telephone_check' => { interval => 1 * 60 * 5, toggle => 'off', beaconable => 'yes', timeout => 90 },
	'email_sender' => { interval => 1 * 30, toggle => 'off', beaconable => 'yes', timeout => 90 },
	'email_receiver' => { interval => 5 * 60, toggle => 'off', beaconable => 'yes', timeout => 390 },
	'tunnels' => { interval => (2 * 60), interval_divider => 10, last_run => &subs::rightNow(), ip_addresses => [], network => {}, toggle => 'off', timeout => 390 },
	'htop' => { interval => 40, toggle => 'off', timeout => 360 },
	'manager' => { interval => 15, last_run => &subs::rightNow(), toggle => 'off', timeout => 20 }
};

$gb::alarm_running = 0;
$gb::budget_running = 0;
$gb::housekeeping_running = 0;
$gb::clothesline_running = 0;
$gb::alarm_haircut_running = 0;

our $whatevs = {};

our $chairs = {
	guest => { rank => 3 },
	resident => { rank => 2 },
	citizen => { rank => 1 },
	blacklisted => { rank => 0 },
};

our @device_types = qw/mobile computer server/;
our $settings;
our $printer_brands = {
	hp => {},
	brother => {},
	canon => {},
	epson => {}
};

our $piano = [
	{ '__specs' => { ratio => 1.05945454545 } },
	{ note => 'C', colour => 'white', freq => 261.64  },
	{ note => 'C#', colour => 'black', aka => 'Db', freq => 277.2 },
	{ note => 'D', colour => 'white', freq => 293.68 },
	{ note => 'D#', colour => 'black', aka => 'Eb', freq => 311.14 },
	{ note => 'E', colour => 'white', freq => 329.64 },
	{ note => 'F', colour => 'white', freq => 349.24 },
	{ note => 'F#', colour => 'black', aka => 'Gb', freq => 370 },
	{ note => 'G', colour => 'white', aka => 'G', freq => 392 },
	{ note => 'G#', colour => 'black', aka => 'Ab', freq => 415.308 },
	{ note => 'A', colour => 'white', freq => 440 },
	{ note => 'A#', colour => 'black', aka => 'Bb' },
	{ note => 'B', colour => 'white',  },
];

our @protected = qw/me misc __president music_folder_toggle __DEBRIEFING__ teletype budget ide config box_office studio synth cards terminal video gallery security/;

our @misc_settings = qw/homepage homepage_content manager start_menu gate configure store store_header soundroom_sidebar_container mail_sidebar_container ide_sidebar_container pseudonym pseudonym_home box_office notifications console keyboard calculator walkboy delorean controller remote_control /;

our $pos = {
	idea => {},
	person => {
		template => 'pos/person',
		app_template => 'apps/person', 
		app_measures => {
			'friend' => { type => 'range', min => 0, max => 100 },
			'volition' => { type => 'range', min => 0, max => 100 }, 
			'fun' => { type => 'range', min => 0, max => 100 },
			'relationship' => { 'type' => 'multiple_select', options => [ 'self', 'combative', 'hostile', 'adversarial', 'competitive', 'indifferent', 'neutral', 'familial', 'amicable',  'professional', 'friendly', 'sexual', 'marital', 'holy' ] }
		} 
	},
	project => {
		app_template => 'apps/project'
	},
	account => {
		app_template => 'apps/account'
	},
	feel => {
		template => 'pos/feel',
		app_template => 'apps/feel', 
		app_measures => {
			'intensity' => { type => 'range' }, 
			'polarity' => { type => 'range' } 
		}
	},
	action => {},
	event => { template => 'pos/event', store_template => 'store/event' },
	vendor => {},
	community => { template => 'pos/community', app_template => 'apps/community' },
	club => {},
	team => {},
	manufacturer => { template => 'pos/manufacturer' },
	government => {},
	corporation => {},
	institution => {},
	product => { template => 'pos/product', store_template => 'store/product' },
	service => { template => 'pos/service', store_template => 'store/service' },
	media => { template => 'pos/media', store_template => 'store/product', formats => { 
		'tv_show' => [ 'drama', 'comedy', 'documentary', 'mockumentary', 'horror', 'kids', 'cartoon', 'historical', 'news' ], 
		'movie' => [ 'drama', 'comedy', 'documentary', 'horror', 'mockumentary', 'kids', 'cartoon', 'historical' ],
		'book' => [ 'novel', 'biography', 'autobiography', 'textbook', 'sci-fi', 'comedy', 'kids', 'historical' ],
		'magazine' => [ 'lifestyle', 'comedy', 'news', 'world', 'entertainment', 'historical' ],
		'album' => [ 'ep', 'lp', 'cd', 'cassette', 'vinyl', 'digital', 'streaming', 'live', 'remastered', 'ceramic', 'compilation', 'parody' ],
		'song' => [ 'rock_and_roll', 'pop', 'hip-hop', 'country', 'classical', 'r&b', 'traditional', 'jazz', 'funk', 'parody', 'indie', 'punk', 'heavy_metal', 'death_metal' ],
		'artist' => [ 'band', 'solo', 'parody' ]
		} 
	},
	place => { template => 'pos/place', store_template => 'store/service' },
	category => { template => 'pos/category' },
	thing => {},
};

our $social_constructs = {
	communities => { name => 'communities', list => [], sing => 'community', def => 'local', order => 0 },
	teams => { name => 'teams', list => [], sing => 'team', def => 'family', order => 2 },
	clubs => { name => 'clubs', list => [], sing => 'club', def => 'peers', order => 1 },
	projects => { name => 'projects', list => [], sing => 'project', def => 'life', order => 4 },
	accounts => { name => 'accounts', list => [], sing => 'account', def => 'cash', order => 5 },
	people => { name => 'people', list => [], sing => 'person', def => 'self', order => 3 },
};

our $relationals = {};

foreach my $p ( keys %{$pos} ) {
		$relationals->{$p} = { name => $p, sing => $p, list => [], def => undef };
}



our @store_types = qw/product service event place media/;

our $known_appts = {
	configure => { icon => "/images/decipherable/wrench.png" },
	handbook => { icon => "/images/decipherable/handbook.png" },
	budget => { icon => "/images/decipherable/chart.png" },
	travel => { icon => "/images/decipherable/aeroplane.png" },
	mailbox => { icon => "/images/decipherable/envelope.png" },
	music => { icon => "/images/make believe/music.png" },
	embedded => { icon => "/images/decipherable/microchip.png" },
	box_office => { icon => "/images/decipherable/ticket.png" },
	cards => { icon => "/images/decipherable/cards.png" },
	security => { icon => "/images/make believe/badge.png" },
	terminal => { icon => "/images/decipherable/code.png" },
	ide => { icon => "/images/make believe/monitor.png" },
	gallery => { icon => "/images/decipherable/gallery.png" },
	synth => { icon => "/images/decipherable/piano.png" },
	editor => { icon => "/images/decipherable/love letter.png" },
	marker => { icon => "/images/decipherable/marker.png" },
	twirl => { icon => "/images/decipherable/tetris.png" },
	studio => { icon => "/images/decipherable/mixer.png" },
	video => { icon => "/images/make believe/camera.png" },
	store => { icon => "/images/decipherable/register.png" },
	citizen => { icon => "/images/jbuttons/appts.png" },
	resident => { icon => "/images/jbuttons/shop.png" },
	guest => { icon => "/images/jbuttons/home.png" },
	blacklisted => { icon => "/images/jbuttons/ne pas.png" },
	relational => { icon => "/images/make believe/strawbeery.png" },
	web => { icon => "/images/make believe/web_button.png" },
	warehouse => { icon => '/icons/pos/manufacturer.png' },
	measures => { icon => '/images/decipherable/measures.png' },
	folders => { icon => '/images/decipherable/folder.png' }
};

our $known_icons = {
	file => '/images/decipherable/file.png',
	folder => '/images/decipherable/folder.png',
	'delete' => '/icons/trash.png',
	cut => '/images/palette/crop.png',
	
};

our $inventory_states = [
	'ordered',
	'delivered',
	'in_stock',
	'shipped',
	'returned'
];

our $transaction_states = [
	'open',
	'completed',
	'warranty'
];

our $budget_modes = {
	occurences => { 
		formatted => sub() {
			my $b = shift;
			return sprintf("%.2f", $b);
		},
		unformatted => sub() {
			my $b = shift;
			$b =~ s/[^0-9.]//gi;
			return $b;
		}
	},
	duration => {
		formatted => sub() {
			my $b = shift;
			return &subs::duration_sayer($b / 1000);
		},
		unformatted => sub() {
			my $b = shift;
			$b = &subs::time_abbrev_translator($b);
			return $b;
		}
	},
	total => {
		formatted => sub() {
			my $b = shift;
			return &subs::price_formatter($b);
		},
		unformatted => sub() {
			my $b = shift;
			$b =~ s/^[0-9.]//gi;
			return $b;
		}
	},
	quantity => {
		formatted => sub() {
			my $b = shift;
			return $b;
		},
		unformatted => sub() {
			my $b = shift;
			return $b;
		}
	}
};

our $budget_statuses = {
	budgeted => {
		notifier => sub(){
			my $rt = shift;
			$rt->{'colour'} = 'lightgreen';
			$rt->{'status'} = 'budgeted';
			return $rt;
		},
		n => 4
	},
	accomplished => {
		notifier => sub(){
			my $rt = shift;
			$rt->{'colour'} = 'pink';
			$rt->{'status'} = 'accomplished';
			return $rt;
		},
		n => 3
	},
	burnt_out => {
		notifier => sub() {
			my $rt = shift;
			$rt->{'colour'} = 'orange';
			$rt->{'status'} = 'burnt out';
			return $rt;
		},
		n => 2
	},
	abused => {
		notifier => sub(){
			my $rt = shift;
			$rt->{'colour'} = 'red';
			$rt->{'text-colour'} = 'white';
			$rt->{'status'} = 'abused';
			return $rt;
		},
		n => 1
	},
	achievable => {
		notifier => sub(){
			my $rt = shift;
			$rt->{'colour'} = 'lightblue';
			$rt->{'status'} = 'achievable';
			return $rt;
		},
		n => 5
	},
	neglected => {
		notifier => sub(){
			my $rt = shift;
			$rt->{'colour'} = 'yellow';
			$rt->{'status'} = 'neglected';
			return $rt;
		},
		n => 6
	},
	abandoned => {
		notifier => sub() {
			my $rt = shift;
			$rt->{'colour'} = 'lightgrey';
			$rt->{'status'} = 'abandoned';
			return $rt
		},
		n => 7
	},
};

our $months = [
	{ 'abbrev' => 'jan', name => 'January', days => 31, leap_days => 31, number => 0 },
	{ 'abbrev' => 'feb', name => 'February', days => 28, leap_days => 29, number => 1 },
	{ 'abbrev' => 'mar', name => 'March', days => 31, leap_days => 31, number => 2 },
	{ 'abbrev' => 'apr', name => 'April', days => 30, leap_days => 30, number => 3 },
	{ 'abbrev' => 'may', name => 'May', days => 31, leap_days => 31, number => 4 },
	{ 'abbrev' => 'jun', name => 'June', days => 30, leap_days => 30, number => 5 },
	{ 'abbrev' => 'jul', name => 'July', days => 31, leap_days => 31, number => 6 },
	{ 'abbrev' => 'aug', name => 'August', days => 31, leap_days => 31, number => 7 },
	{ 'abbrev' => 'sep', name => 'September', days => 30, leap_days => 30, number => 8 },
	{ 'abbrev' => 'oct', name => 'October', days => 31, leap_days => 31, number => 9 },
	{ 'abbrev' => 'nov', name => 'November', days => 30, leap_days => 30, number => 10 },
	{ 'abbrev' => 'dec', name => 'December', days => 31, leap_days => 31, number => 11 },
];

our $wdays = [
	{ 'abbrev' => 'sun', name => 'Sunday', number => 0 },
	{ 'abbrev' => 'mon', name => 'Monday', number => 1 },
	{ 'abbrev' => 'tue', name => 'Tuesday', number => 2 },
	{ 'abbrev' => 'wed', name => 'Wednesday', number => 3 },
	{ 'abbrev' => 'thu', name => 'Thursday', number => 4 },
	{ 'abbrev' => 'fri', name => 'Friday', number => 5 },
	{ 'abbrev' => 'sat', name => 'Saturday', number => 6 }
];

our $hours = [
	{ 'abbrev' => '12am', number => 0 },
	{ 'abbrev' => '1am', number => 1 },
	{ 'abbrev' => '2am', number => 2 },
	{ 'abbrev' => '3am', number => 3 },
	{ 'abbrev' => '4am', number => 4 },
	{ 'abbrev' => '5am', number => 5 },
	{ 'abbrev' => '6am', number => 6 },
	{ 'abbrev' => '7am', number => 7 },
	{ 'abbrev' => '8am', number => 8 },
	{ 'abbrev' => '9am', number => 9 },
	{ 'abbrev' => '10am', number => 10 },
	{ 'abbrev' => '11am', number => 11 },
	{ 'abbrev' => '12pm', number => 12 },
	{ 'abbrev' => '1pm', number => 13 },
	{ 'abbrev' => '2pm', number => 14 },
	{ 'abbrev' => '3pm', number => 15 },
	{ 'abbrev' => '4pm', number => 16 },
	{ 'abbrev' => '5pm', number => 17 },
	{ 'abbrev' => '6pm', number => 18 },
	{ 'abbrev' => '7pm', number => 19 },
	{ 'abbrev' => '8pm', number => 20 },
	{ 'abbrev' => '9pm', number => 21 },
	{ 'abbrev' => '10pm', number => 22 },
	{ 'abbrev' => '11pm', number => 23 }
];

our $measures = {
	'each' => { name => 'each' },
	ft => { name => 'foot', types => [ 'distance' ], plural => 'feet', symbol => "'", formulas => [ 'x * 30.48cm', 'x * 12in'] },
	in => { name => 'inch', types => [ 'distance' ], plural => 'inches', symbol => '"' },
	mm => { name => 'millimetre', types => [ 'distance' ] },
	cm => { name => 'centimetre', types => [ 'distance' ], formulas => ['x * .001m', 'x * 100mm']},
	'm' => { name => 'metre', types => [ 'distance' ], formulas => [ 'x * 0.00062136mi', 'x * .0001km', ] },
	km => { name => 'kilometre', types => [ 'distance' ], formulas => ['x * 1000m', 'x * 0.621371mi'] },
	mi => { name => 'mile', types => [ 'distance' ], formulas => [ 'x * 1689.344m', 'x * 1.609344km' ] },
	mL => { name => 'millilitre', types => [ 'volume' ], formulas => [ 'x * .2tsp', 'x * .06667tbsp', 'x * .03333oz', 'x * .00416667cup', 'x * .001L' ] },
	L => { name => 'litre', types => [ 'volume' ], formulas => [ 'x * 100mL' ] },
	CAD => { name => 'Canadian Dollar', types => [ 'currency' ], symbol => '$', format => '$0.00', formulas => [ 'x * .52EUR', 'x * .73USD'] },
	USD => { name => 'American Dollar', types => [ 'currency' ], symbol => '$', format => '$0.00', formulas => [ 'x * 1.37CAD' ] },
	EUR => { name => 'Euro', types => [ 'currency' ], symbol => '€', formulas => [ 'x * 1.48CAD' ] },
	JPY => { name => 'Japanese Yen', types => [ 'currency' ], symbol => '¥', formulas => [ 'x * .0088CAD' ] },
	g => { name => 'gram', types => [ 'mass', 'weight' ], formulas => [ 'x * 1000mg', 'x * .0001kg' ] },
	mg => { name => 'milligram', types => [ 'mass', 'weight' ], formulas => [ 'x * .0001g' ] },
	kg => { name => 'kilogram', types => [ 'mass', 'weight' ], formulas => [ 'x * 1000g' ] },
	oz => { name => 'ounce', types => [ 'weight', 'mass', 'volume' ], fomulas => [ 'x * 2tbsp', 'x * 6tsp', 'x * 29.5735mL', 'x * 28.3495g' ] },
	lb => { name => 'pound', types => [ 'weight', 'mass' ], formulas => [ 'x * 453.592g', 'x * 16oz' ] },
	tsp => { name => 'teaspoon', types => [ 'volume' ], formulas => [ 'x * .667oz', 'x * .0625cup', 'x * 5mL', 'x * .33333tbsp' ] },
	tbsp => { name => 'tablespoon', types => [ 'volume' ], formulas => [ 'x * 0.5oz', 'x * 15mL', 'x * 3tsp', 'x * .0625cup' ] },
	cup => { name => 'cup', types => [ 'volume' ], formulas => [ 'x * 48tsp', 'x * 237mL', 'x * 8oz', 'x * 16tbsp', 'x * .5pint', 'x * .0625gal' ] },
	pint => { name => 'pint', types => [ 'volume' ], formulas => [ 'x * .125gal' ] },
	gal => { name => 'gallon', types => [ 'volume' ], formulas => [ 'x * 8pint', 'x * 16cup',  ]},
	C => { name => 'celsius', types => [ 'temperature' ], unit => 'degree', symbol => '°', formulas => ['(xF - 32) * 5/9' ] },
	F => { name => 'fahrenheit', types => [ 'temperature' ], unit => 'degree', symbol => '°', formulas => [ '(xC * 9/5) + 32' ]  },
	V => { name => 'volt', types => [ 'power' ], formulas => [ 'V = A * R' ] },
	A => { name => 'amp', types => [ 'power' ] },
	ohm => { name => 'resistance', types => [ 'power' ], unit => 'ohm', symbol => 'Ω' },
	yo => { name => 'age', unit => 'year' },
	kpa => { name => 'kilopascals' },
	deg => { name => 'degree', symbol => '°', formulas => [ ] },
	'time' => { name => 'time' },
	'km/h' => { name => 'km/h', types => ['speed'] },
	'mph' => { name => 'mph', types => ['speed'] }
};

our $abilities = {
	notifications => {},
	category => {},
	description => {},
	duration => {},
	warranty => {},
	schedule => {},
	phone => {},
	notes => {},
	email => {},
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
	unit => { config => 'select', options => [ sort keys %{$measures} ]},
	manufacturer => { config => 'select', options => [ ], formatted => 'yes' },
	inventory_method => { config => 'select', options => [ 'none', 'fifo', 'lifo', 'depreciate' ], formatted => 'yes' },
	quantity => {},
	home_plate => {},
	nfc => {},
	navigation => { config => 'select', options => ['none','once','1s','3s','5s','10s','20s','30s','1m','2m','5m','7m','10m','20m','30m','45m','1h','2h','3h','6h','12h','24h','2d','3d','5d','1w','2w','3w','4w','1M'] }
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
	}]
};

our $movements = {
	assign => {},
	config => {},
	purchase => {},
	delay => {},
	cancel => {},
	public => {},
	request => {},
	register => {},
	quote => {},
	ticket => {},
	text => {},
	msg => {},
	category => {}, 
	telephone => {},
	encrypt => {},
	decrypt => {},
	calc => {},
	usual => {},
	invoice => {},
	quote => {},
	receipt => {},
	upload => {},
	stop => {},
	'listen' => {},
	'kill' => {},
	mix => {},
	sms => {},
	'open' => {},
	scraper => {},
	search => {},
	id => {},
	depart => {},
	entry => {},
	dingaling => {},
	snapshot => {},
	backup => {},
	web => {},
	view => {},
	file => {},
	command => {},
	scan => {},
	audio => {},
	camera => {},
	image => {},
	transaction => {},
	software => {},
	video => {},
	screen => {},
	complete => {},
	'reset' => {},
	note => {},
	record => {},
	start => {},
	quit => {},
	add => {},
	pause => {},
	resume =>{},
	measure => {},
	studio => {}
};

our @movements = sort keys %{$movements};
push @movements, 'all';

our $transaction_types = {
	income => {},
	expense => {},
	transfer => {},
	inventory => {},
};

our @all_device_types = sort qw/hmmm printer watch teletype computer router mobile server client controller microcontroller/;

our $photo_sizes = ["Raw", "3840x2160", "2699x1519", "1920x1080", "1366x768", "800x600", "640x480"];
our $thumbnail_sizes = ["none", "100x100", "150x150", "200x200", "250x250", "300x300", "350x350", "400x400"];

our $time_plinkos = [
	{	name => 'sec', n => 0, count => '', clothes => [], reoccuring => {}, span => 'm', },
	{	name => 'min', n => 1, count => '', clothes => [], reoccuring => {}, span => 'h', },
	{	name => 'hour', n => 2, count => '', clothes => [], reoccuring => {}, span => 'd', },
	{	name => 'mday', n => 3, count => '', clothes => [], reoccuring => {}, span => 'M' },
	{	name => 'mon', n => 4, count => '', clothes => [], reoccuring => {}, span => 'y' },
	{	name => 'year', n => 5, count => '', clothes => [], reoccuring => {}, span => 'D' },
	{	name => 'wday', n => 6, count => '', clothes => [], reoccuring => {}, span => 'w' },
	{	name => 'yday', n => 7, count => '', clothes => [], reoccuring => {}, span => 'y' },
	{	name => 'isdst', n => 8, count => '', clothes => [], reoccuring => {}, span => 'y' }
];

our $inputs = [
	{ c => 'Q', num => 81 },
	{ c => 'W', num => 87, },
	{ c => 'E', num => 69 },
	{ c => 'R', num => 82 },
	{ c => 'T', num => 84 },
	{ c => 'Y', num => 89 },
	{ c => 'U', num => 85 },
	{ c => 'I', num => 73 },
	{ c => 'O', num => 79 },
	{ c => 'P', num => 80 },
	{ c => 'L', num => 76 },
	{ c => 'K', num => 75 },
	{ c => 'J', num => 74 },
	{ c => 'H', num => 72 },
	{ c => 'G', num => 71 },
	{ c => 'F', num => 70 },
	{ c => 'D', num => 68 },
	{ c => 'S', num => 83 },
	{ c => 'A', num => 65 },
	{ c => 'Z', num => 90 },
	{ c => 'X', num => 88 },
	{ c => 'C', num => 67 },
	{ c => 'V', num => 86 },
	{ c => 'B', num => 66 },
	{ c => 'N', num => 78 },
	{ c => 'M', num => 77 },
	{ c => 'q', num => 113 },
	{ c => 'w', num => 119 },
	{ c => 'e', num => 101 },
	{ c => 'r', num => 114 },
	{ c => 't', num => 116 },
	{ c => 'y', num => 121 },
	{ c => 'u', num => 117 },
	{ c => 'i', num => 105 },
	{ c => 'o', num => 111 },
	{ c => 'p', num => 112 },
	{ c => 'l', num => 108 },
	{ c => 'k', num => 107 },
	{ c => 'j', num => 106 },
	{ c => 'h', num => 104 },
	{ c => 'g', num => 103 },
	{ c => 'f', num => 102 },
	{ c => 'd', num => 100 },
	{ c => 's', num => 115 },
	{ c => 'a', num => 97 },
	{ c => 'z', num => 122 },
	{ c => 'x', num => 120 },
	{ c => 'c', num => 99 },
	{ c => 'v', num => 118 },
	{ c => 'b', num => 98 },
	{ c => 'n', num => 110 },
	{ c => 'm', num => 109 },
	{ c => '1', num => 49 },
	{ c => '2', num => 50 },
	{ c => '3', num => 51 },
	{ c => '4', num => 52 },
	{ c => '5', num => 53 },
	{ c => '6', num => 54 },
	{ c => '7', num => 55 },
	{ c => '8', num => 56 },
	{ c => '9', num => 57 },
	{ c => '0', num => 48 },
	{ c => ",", num => 44, img => 'comma' },
	{ c => '.', num => 46, img => 'period' },
	{ c => ':', num => 58 },
	{ c => ';', img => 'semicolon', num => 59 },
	{ c => '/', img => 'forwardslash', num => 47 },
	{ c => '~', num => undef, img => 'tilde' },
	{ c => '`', num => undef }, 
	{ c => '"', num => 34, img => },
	{ c => '\'', img => 'apostrophe', num => 39 },
	{ c => '\\', img => 'backslash', num => undef },
	{ c => '!', num => 33 },
	{ c => '@', img => 'at', num => 64 },
	{ c => '#', num => 35 },
	{ c => '$', num => 36, img => 'dollar' },
	{ c => '%', num => undef, img => 'percent' },
	{ c => '^', num => undef, img => 'carat' },
	{ c => '&', num => undef, img => 'ampersand' },
	{ c => '*', img => 'star', num => 42 },
	{ c => '(', num => 40 },
	{ c => ')', num => 41 },
	{ c => '-', num => 45  },
	{ c => '_', num => 95, img => 'underscore' },
	{ c => '+', num => 43, img => 'star' },
	{ c => '', num => 13, img => 'return', trigger => 'key' },
	{ c => ' ', num => 32, img => 'space', trigger => 'key' },
	{ c => 'clear', num => undef },
	{ c => 'backspace', img => 'BackSpace', num => 8, trigger => 'key' },
	{ c => 'magic_wand', num => undef },
	{ c => 'Enter', num => 13, img => 'return' }
];

#our $secret_maker = [&subs::random_string_creator(rand(130)),&subs::random_string_creator(rand(42)),&subs::random_string_creator(rand(420)), &subs::random_string_creator(rand(982)),&subs::random_string_creator(rand(436))];


our $master_plan = [
	{ team => 'President' },
	{ team => 'Offerings',
		clubs => [{
			team => 'Research',
			communities => [
				{ team => 'Internal Knowledge' }
			]
		},{
			team => 'Projects'
		},{
			team => 'Quality'
		},{
			team => 'Customer Service'
		},{
			team => 'Pricing',
			communities => [
				{ team => 'Formulas' }
			]
		},{
			team => 'Sales'
		}]
	},
	{ team => 'Organization',
		clubs => [{
			team => 'Location',
			communities => [
				{ team => 'Warehouse',
					projects => [ 'Inventory Controls', 'Stock Moves', 'Transportaion' ]
				},
				{ team => 'Waste Disposal',
					projects => [ 'bins' ]
				},
				{
					team => 'Offices',
					projects => [ 'Barns', 'Giant Whiteboards', 'Furniture',
						'Rent v. Buy', 'Number', 'Art', 'Decord', 'Work From Home',
						'Floor Plan'
					]
				},
				{
					team => 'Home Base'
				}
			]
		},{
			team => 'Corporate Culture',
			communities => [
				{ team => 'Recognition' },
				{ team => 'Express Love' },
				{ team => 'Meals' }
			]
		},{
			team => 'Chain of Command',
			communities => [
				{ team => 'My Roles',
					projects => [ 'Travelling', 'Retirement', 'Boundaries',
						'Fulfillment', 'Personal Goals', 'Management Style',
						'Speeches', 'Successor', 'Timeline', 'Vacations', 
						'Hours', 'Salary'
					]
				},
				{ team => 'Job Delegation' },
				{ team => 'Departments' }
			]
		},{
			team => 'Positions',
			communities => [
				{ team => 'Growth Transitions' },
				{ team => 'Graduating' }
			]
		}]
	},
	{ team => 'Systems',
		clubs => [{
			team => 'Code of Conduct',
			communities => [
				{ team => 'Conflict Resolution' }
			]
		},{
			team => 'I.T.',
			communities => [
				{ team => 'Computers' },
				{ team => 'Network' }
			]
		},{
			team => 'Time Management' 
		},{
			team => 'Ethical/Legal'
		},{
			team => 'Software',
			communities => [
				{ team => 'Design' },
				{ team => 'Capabilities' },
				{ team => 'Security' }
			]
		}]
	},
	{ team => 'Planning',
		clubs => [{
			team => 'Business Plan', 
			communities => [
				{ team => 'Scope' },
				{ team => 'Timeline' }
			]
		},{
			team => 'Mission',
			communities => [
				{ team => 'Competitive Advantages' },
				{ team => 'Value' }
			]
		},{
			team => 'Goals and Milestones',
			communities => [
				{ team => 'Measurement' },
				{ team => 'Revenue' },
				{ team => 'Forecasts',
					projects => [ 'employees', 'customers' ]
				},
				{ team => 'Growth' }
			]
		},{
			team => 'Budgeting'
		},{
			team => 'Disaster'
		},{
			community => 'Mentors'
		},{
			team => 'Fund Acquisition',
			communities => [
				{ team => 'Benefits' },
				{ team => 'Savings' },
				{ team => 'Loans',
					projects => [ 'Cost of Plan' ],
				}
			]
		}]
	},
	{ team => 'Operations',
		clubs => [{
			team => 'Purchasing',
			communities => [
				{ team => 'Replenish' },
				{ team => 'Suppliers' }
			]
		},{
			team => 'Administration',
			communities => [
				{ team => 'Collections' },
				{ team => 'Secretary' },
				{ team => 'Payroll' },
				{ team => 'Invoicing',
					projects => [ 'Utilities' ]
				}
			]
		},{
			team => 'Staff',
			communities => [
				{ team => 'Product' },
				{ team => 'Incentive Programs' },
				{ team => 'Benefit' },
				{ team => 'Scheduling' },
				{ team => 'HR' }
			]
		},{
			team => 'Training',
			communities => [
				{ team => 'Probation' },
				{ team => 'Apprenticeship' },
				{ team => 'Manuals' }
			]
		}]
	},
	{ team => 'Marketing',
		clubs => [{
			team => 'Our Customers',
			communities => [
				{ team => 'Community' }
			]
		},{
			team => 'Brand',
			communities => [
				{ team => 'Name' },
				{ team => 'CSR',
					projects => [ 'Classes' ]
				},
				{ team => 'Logo' }
			],
			projects => [ 'Psychographics' ]
		},{
			team => 'Communication',
			projects => [ 'Letterhead', 'Phones', 'Email' ]
		},{
			team => 'Web Presence',
			projects => [ 'Videohelp Forums', 'Blog' ],
		}, {
			team => 'Public Image',
			communities => [
				{ team => 'Trade Shows' },
				{ team => 'Punctuality' },
				{ team => 'Vehicles' },
				{ team => 'Briefcases' },
				{ team => 'Uniforms' }
			]
		}]
	},
	{ team => 'Financial/Legal',
		clubs => [{
			team => 'Debt/Asset'
		},{
			team => 'Terms of Use'
		},{
			team => 'Accounting',
			communities => [
				{ team => 'Book Keeping' },
				{ team => 'Tax' }
			]
		},{
			team => 'Wages',
			communities => [
				{ team => 'Contracts' },
				{ team => 'Employees' }
			]
		},{
			team => 'Insurance',
			communities => [
				{ team => 'Warranties' }
			]
		},{
			team => 'Cash Flow'
		},{
			team => 'Contracts'
		},{
			team => 'Pricing',
			communities => [
				{ team => 'Sales' },
				{ team => 'Formulas' }
			]
		}]
	},
	{ team => 'I.T. Services',
		communities => [
			{ team => 'Businesses' },
			{ team => 'Homes' },
			{ team => 'Appointments',
				projects => [ 'Punchclock', 'Maps' ]
			},
			{ team => 'Farms' }
		]
	},
	{ team => 'Server Software',
		communities => [
			{ team => 'Farms' },
			{ team => 'Bare Metal Dedi' },
			{ team => 'Databases' },
			{ team => 'Programming Services'}
		]
	},
	{ team => 'Embedded',
		communities => [
			{ team => 'SBC' },
			{ team => 'Wireless' },
			{ team => 'Circuits' },
			{ team => 'Sensors' },
			{ team => 'Interfaces' },
			{ team => 'Microcontrollers' }
		]
	}
];

our @taunts = (
	'keep trying there tiger!',
	'you might get it this time!',
	'don\'t you want to get in?',
	'Cuz 7 8 9!',
	'You might have gotten it right already',
	'there\'s a whole lot of padlock here',
	'change your mind about everything',
	'believe in yourself, or whatever!',
	'Drooling',
	'You already tried that one!',
	'there, now you\'re in, see!?',
	'Call a friend',
	'Remember all the times you had it right',
	'it\'s 7, just trust me, all sevens!',
	'Yup, this is the whole program',
	'try spinning yourself counterclockwise at the same time',
	'Do you need a hint?',
	'Ready?',
	'Now you\'re in! Good job!',
	'What are we having for dinner?',
	'Same thing you tried last time...',
	'Just wait and see if it unlocks itself...',
	'Got the idea from high school lockers',
	'Really great textbooks inside!',
	'Just get the boltcutters already!',
	'Whatever, it\'s not important anyways!',
	'Give me a chance to help you with that',
	'How did they get in?',
	'Hahahahahahahahaha!',
	'lol',
	'Think of an angle that I would think about',
	'You need to get inside my head to know the combination',
	'Did you try 4 5 6 yet?',
	'This is your final try, then I\'m shutting it down',
	'I can see them all coming together',
	'In the morning the combinations are usually divisible by 14',
	'I tried to tell you the combination 201 months ago!',
	'You need it',
	'Buy me a coffee first',
	'three divided by seven plus 4 minus 8',
	'9 plus 11 minus 3 plus 4',
	'1 + 4 - 7 + 11 - 8',
	'get a haircut!',
	'get down!',
	'It worked, it really worked',
	'what a miracle!',
	'In January',
	'On Sept 14',
	'1923',
	'673',
	'936',
	'11 - 0 - 5',
	'6 - 3 - 7',
	'1 - 5 - 3',
	'9 - 1 - 5',
	'905',
	'519',
	'416',
	'705',
	'226',
	'647',
	'403',
	'401',
	'402',
	'You\'re drunk!',
	'Just one more number and you\'re in!',
	'Authority level 7',
	'Hypnotize yourself into feeling the number',
	'It\'s on the 734th page of Oxford\'s seventh edition',
	'How many constellations are there?',
	'What is the year of the magna carta?',
	'It rhymes with cranatera',
	'Yes, that was it, but I don\'t feel like unlocking',
	'You achieved it!',
	'You really entered the right combination',
	'All doors are swinging wide for you!',
	'Remember 3 - 7 - 10',
	'Maybe this whole project has been a padlock?',
	'The entire program is a single padlock',
	'Are you on your computer?',
	'Is your fridge running?',
	'What is your height?',
	'What is your birthweight?',
	'What is the year of your first car?',
	'What is your mother\'s maiden name?',
	'It rhymes with pree nun greven',
	'This is a disclaimer! You will have fun!',
	'Fun is mandatory, start having it!',
	'You\'re ornery!',
	'You\'re ornary!',
	'You\'re ornarry!',
	'You stink!',
	'You look like a badger with a much larger snout!',
	'You have headlice!',
	'You have gangrene!',
	'You have athlete\'s foot!',
	'Your clothes are covered in dandruff',
	'Your neckhair could construct an eagle\s nest',
	'Donate your armpit hair!',
	'You love it!',
	'Thank you, thank you thank you!'
);

our $microcontrollers = {
	'Raspberry Pi Pico 2W' => {
		pins => {
			1 => { GP => 0, SPI => { 0 => 'RX' }, I2C => { 0 => 'SDA' }, UART => { 0 => 'TX', 'default' } },
			2 => { GP => 1, SPI => { 0 => 'CSn' }, I2C => { 0 => 'SCL' }, UART => { 0 => 'TX', 'default' } },
			3 => { 'GND' },
			4 => { GP => 2, SPI => { 0 => 'SCK' }, I2C => { 1 => 'SDA' } },
			5 => { GP => 3, SPI => { 0 => 'TX' }, I2C => { 1 => 'SCL' } },
			6 => { GP => 4, SPI => { 0 => 'RX' }, I2C => { 0 => 'SDA', 'default' }, UART => { 1 => 'TX' } },
			7 => { GP => 5, SPI => { 0 => 'CSn' }, I2C => { 0 => 'SCL', 'default' }, UART => { 1 => 'RX' } },
			8 => { 'GND' },
			9 => { GP => 6, SPI => { 0 => 'SCK' }, I2C => { 1 => 'SDA' } },
			10 => { GP => 7, SPI => { 0 => 'TX' }, I2C => { 1 => 'SCL' } },
			11 => { GP => 8, SPI => { 1 => 'RX' }, I2C => { 0 => 'SDA' }, UART => { 1 => 'TX' } },
			12 => { GP => 9, SPI => { 1 => 'SCn' }, I2C => { 0 => 'SCL' }, UART => { 1 => 'RX' } },
			13 => { 'GND' },
			14 => { GP => 10, SPI => { 1 => 'SCK' }, I2C => { 1 => 'SDA' } },
			15 => { GP => 11, SPI => { 1 => 'TX' }, I2C => { 1 => 'SCL' } },
			16 => { GP => 12, SPI => { 1 => 'RX' }, I2C => { 0 => 'SDA' }, UART => { 0 => 'TX' } },
			17 => { GP => 13, SPI => { 1 => 'CSn' }, I2C => { 0 => 'SCL' }, UART => { 0 => 'RX' } },
			18 => { 'GND' },
			19 => { GP => 14, SPI => { 1 => 'SCK' }, I2C => { 1 => 'SDA' } },
			20 => { GP => 15, SPI => { 1 => 'TX' }, I2C => { 1 => 'SCL' } },
			21 => { GP => 16, SPI => { 0 => 'RX', 'default' }, I2C => { 0 => 'SDA' }, UART => { 0 => 'TX' } },
			22 => { GP => 17, SPI => { 0 => 'CSn', 'default' }, I2C => { 0 => 'SCL' }, UART => { 0 => 'RX' } },
			23 => { 'GND' },
			24 => { GP => 18, SPI => { 0 => 'SCK', 'default' }, I2C => { 1 => 'SDA' } },
			25 => { GP => 19, SPI => { 0 => 'TX', 'default' }, I2C => { 1 => 'SCL' } },
			26 => { GP => 20, I2C => { 0 => 'SDA' } },
			27 => { GP => 21, I2C => { 0 => 'SCL' } },
			28 => { 'GND' },
			29 => { GP => 22 },
			30 => { RUN => 1, colour => 'pink' },
			31 => { GP => 26, ADC => 0, I2C => { 1 => 'SDA' } },
			32 => { GP => 27, ADC => 1, I2C => { 1 => 'SCL' } },
			33 => { 'GND', 'AGND' },
			34 => { GP => 28, ADC => 2 },
			35 => { 'ADC_REF' => 1, colour => 'olive' },
			36 => { '3V3_OUT' => 1, colour => 'red' },
			37 => { '3V3_EN' => 1, colour => 'pink' },
			38 => { 'GND' },
			39 => { VSYS => 1, colour => 'red' },
			40 => { VBUS => 1, colour => 'red' }
		},
		debug => {
			SWCLK => { },
			GND => { },
			SWDIO => { }
		}
	}
};

1;