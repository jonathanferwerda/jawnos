package gb;
use strict;
no warnings;

our %texture_labels = (
	classic => 'Plain',
	round   => 'Round',
	soft    => 'Soft',
	sandglass => 'Sandglass',
	glass   => 'Glass',
	paper   => 'Paper',
	fabric  => 'Fabric',
	wood    => 'Wood',
	metal   => 'Metal',
);

# A theme may name a face. The list is a whitelist: the value is written into a
# CSS custom property, so only a house stack may reach the page. A stored value
# that is not here is still honoured by the Misc Font picker (it appends the
# current one), but a theme cannot introduce a new string.
our @theme_fonts = (
	{ value => 'system-ui, sans-serif', label => 'System' },
	{ value => 'Noto Sans, system-ui, sans-serif', label => 'Noto Sans' },
	{ value => 'Inter, system-ui, sans-serif', label => 'Inter' },
	{ value => 'Cantarell, system-ui, sans-serif', label => 'Cantarell' },
	{ value => 'Segoe UI, system-ui, sans-serif', label => 'Segoe UI' },
	{ value => 'Helvetica Neue, Helvetica, Arial, sans-serif', label => 'Helvetica' },
	{ value => 'Arial, sans-serif', label => 'Arial' },
	{ value => 'Verdana, sans-serif', label => 'Verdana' },
	{ value => '"Trebuchet MS", sans-serif', label => 'Trebuchet' },
	{ value => 'Georgia, serif', label => 'Georgia' },
	{ value => 'Palatino Linotype, Iowan Old Style, Georgia, serif', label => 'Palatino' },
	{ value => 'Times New Roman, serif', label => 'Times' },
	{ value => 'JetBrains Mono, Courier New, monospace', label => 'JetBrains Mono' },
	{ value => 'Courier New, monospace', label => 'Courier' },
);

our %cursor_set_labels = (
	bold    => 'Bold',
	white   => 'White',
	outline => 'Outline',
	neon    => 'Neon',
	pastel  => 'Pastel',
	mono    => 'Mono',
	contrast=> 'High Contrast',
);

our %icon_set_labels = (
	handdrawn    => 'Hand-drawn (original)',
	windows      => 'Jawndows',
	mac          => 'Cuperjawno',
	gnome        => 'GNOME',
	cartoon      => 'Cartoon',
	dark         => 'Dark',
	light        => 'Light',
	outline      => 'Outline',
	neon         => 'Neon',
	pastel       => 'Pastel',
	mono         => 'Mono',
	sunburst     => 'Sunburst',
	holographic  => 'Holographic',
	sticker      => 'Sticker',
	psychedelic  => 'Psychedelic',
	kaleidoscope => 'Kaleidoscope',
	clown        => 'Clown Barf',
);

our $pos = {
	idea => {},
	person => {
		template => 'pos/person',
		app_template => 'apps/person',
		app_measures => {
			'friend' => { type => 'range', min => 0, max => 100 },
			'volition' => { type => 'range', min => 0, max => 100 },
			'fun' => { type => 'range', min => 0, max => 100 },
		},
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

# The address tuple: the collectives a record can be filed under, in the order
# the pickers show them. Each entry is a settings kind (pos/mab) too, so the
# Relational window and the People app grow a section for it on their own.
#
# `accounts` is deliberately absent: an account is a financial coordinate, not
# a collective. The mailbox keeps its account column for the rows already filed
# under one, but the tuple no longer addresses by it.
our $social_constructs = {
	communities => { name => 'communities', list => [], sing => 'community', def => 'local', order => 0 },
	clubs => { name => 'clubs', list => [], sing => 'club', def => 'peers', order => 1 },
	teams => { name => 'teams', list => [], sing => 'team', def => 'family', order => 2 },
	people => { name => 'people', list => [], sing => 'person', def => 'self', order => 3 },
	projects => { name => 'projects', list => [], sing => 'project', def => 'life', order => 4 },
	institutions => { name => 'institutions', list => [], sing => 'institution', def => 'house', order => 5 },
	governments => { name => 'governments', list => [], sing => 'government', def => 'civic', order => 6 },
	corporations => { name => 'corporations', list => [], sing => 'corporation', def => 'sole', order => 7 },
	places => { name => 'places', list => [], sing => 'place', def => 'home', order => 8 },
	vendors => { name => 'vendors', list => [], sing => 'vendor', def => 'market', order => 9 },
	events => { name => 'events', list => [], sing => 'event', def => 'now', order => 10 },
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
	network => { icon => '/images/decipherable/server.png' },
	notifications => { icon => '/images/decipherable/bell.png' },
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
	folders => { icon => '/images/decipherable/folder.png' },
	process_monitor => { icon => '/images/decipherable/server.png' },
	market => { icon => '/icons/pos/vendor.png' },
	library => { icon => '/images/decipherable/handbook.png' },
	notes => { icon => '/images/decipherable/list.png' },
	phone => { icon => '/images/decipherable/phone.png' },
	clock => { icon => '/icons/clock.svg' },
	power => { icon => '/icons/power.svg' },
	sound => { icon => '/icons/sound.svg' },
	weather => { icon => "/images/make believe/new sun.png" },
	people => { icon => '/images/make believe/people.png' },
	email => { icon => '/images/decipherable/envelope.png' },
	chat => { icon => "/images/make believe/phone_sms.png" },
	search => { icon => '/images/make believe/search_button.png' },
	help => { icon => "/images/decipherable/question mark.png" }
};
