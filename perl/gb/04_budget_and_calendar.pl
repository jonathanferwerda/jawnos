package gb;
use strict;
no warnings;

our $known_icons = {
	file => '/images/decipherable/file.png',
	folder => '/images/decipherable/folder.png',
	archive => '/images/decipherable/diskette.png',
	'delete' => '/icons/trash.png',
	cut => '/images/palette/crop.png',
	encrypt => '/images/make believe/lock.png',
	decrypt => '/images/make believe/key.png',
	pin_app => '/images/decipherable/forward.png',
	desk_folder => '/images/decipherable/computer.png',
	desk_folder_reset => '/images/decipherable/home.png',
	browser_back => '/images/make believe/left arrow.png',
	browser_refresh => '/images/make believe/renew.png',
	open_tab => '/images/decipherable/forward.png',
	open_window => '/images/decipherable/windows.png',
	restore_trash => '/images/make believe/renew.png',
	open_trash => '/icons/trash.png',
	empty_trash => '/icons/trash.png',
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
		formatted => sub {
			my $b = shift;
			return sprintf("%.2f", $b);
		},
		unformatted => sub {
			my $b = shift;
			$b =~ s/[^0-9.]//gi;
			return $b;
		}
	},
	duration => {
		formatted => sub {
			my $b = shift;
			return &subs::duration_sayer($b / 1000);
		},
		unformatted => sub {
			my $b = shift;
			$b = &subs::time_abbrev_translator($b);
			return $b;
		}
	},
	total => {
		formatted => sub {
			my $b = shift;
			return &subs::price_formatter($b);
		},
		unformatted => sub {
			my $b = shift;
			$b =~ s/^[0-9.]//gi;
			return $b;
		}
	},
	quantity => {
		formatted => sub {
			my $b = shift;
			return $b;
		},
		unformatted => sub {
			my $b = shift;
			return $b;
		}
	}
};

our $budget_statuses = {
	budgeted => {
		notifier => sub {
			my $rt = shift;
			$rt->{'colour'} = 'lightgreen';
			$rt->{'status'} = 'budgeted';
			return $rt;
		},
		n => 4
	},
	accomplished => {
		notifier => sub {
			my $rt = shift;
			$rt->{'colour'} = 'pink';
			$rt->{'status'} = 'accomplished';
			return $rt;
		},
		n => 3
	},
	burnt_out => {
		notifier => sub {
			my $rt = shift;
			$rt->{'colour'} = 'orange';
			$rt->{'status'} = 'burnt out';
			return $rt;
		},
		n => 2
	},
	overkill => {
		notifier => sub {
			my $rt = shift;
			$rt->{'colour'} = 'red';
			$rt->{'text-colour'} = 'white';
			$rt->{'status'} = 'overkill';
			return $rt;
		},
		n => 1
	},
	achievable => {
		notifier => sub {
			my $rt = shift;
			$rt->{'colour'} = 'lightblue';
			$rt->{'status'} = 'achievable';
			return $rt;
		},
		n => 5
	},
	neglected => {
		notifier => sub {
			my $rt = shift;
			$rt->{'colour'} = 'yellow';
			$rt->{'status'} = 'neglected';
			return $rt;
		},
		n => 6
	},
	abandoned => {
		notifier => sub {
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
	'm' => { name => 'metre', types => [ 'distance' ], formulas => [ 'x * 0.00062136mi', 'x * .001km', ] },
	km => { name => 'kilometre', types => [ 'distance' ], formulas => ['x * 1000m', 'x * 0.621371mi'] },
	mi => { name => 'mile', types => [ 'distance' ], formulas => [ 'x * 1609.344m', 'x * 1.609344km' ] },
	mL => { name => 'millilitre', types => [ 'volume' ], formulas => [ 'x * .2tsp', 'x * .06667tbsp', 'x * .03333oz', 'x * .00416667cup', 'x * .001L' ] },
	L => { name => 'litre', types => [ 'volume' ], formulas => [ 'x * 1000mL' ] },
	CAD => { name => 'Canadian Dollar', types => [ 'currency' ], symbol => '$', format => '$0.00', formulas => [ 'x * .52EUR', 'x * .73USD'] },
	USD => { name => 'American Dollar', types => [ 'currency' ], symbol => '$', format => '$0.00', formulas => [ 'x * 1.37CAD' ] },
	EUR => { name => 'Euro', types => [ 'currency' ], symbol => '€', formulas => [ 'x * 1.48CAD' ] },
	JPY => { name => 'Japanese Yen', types => [ 'currency' ], symbol => '¥', formulas => [ 'x * .0088CAD' ] },
	g => { name => 'gram', types => [ 'mass', 'weight' ], formulas => [ 'x * 1000mg', 'x * .001kg' ] },
	mg => { name => 'milligram', types => [ 'mass', 'weight' ], formulas => [ 'x * .001g' ] },
	kg => { name => 'kilogram', types => [ 'mass', 'weight' ], formulas => [ 'x * 1000g' ] },
	oz => { name => 'ounce', types => [ 'weight', 'mass', 'volume' ], formulas => [ 'x * 2tbsp', 'x * 6tsp', 'x * 29.5735mL', 'x * 28.3495g' ] },
	lb => { name => 'pound', types => [ 'weight', 'mass' ], formulas => [ 'x * 453.592g', 'x * 16oz' ] },
	tsp => { name => 'teaspoon', types => [ 'volume' ], formulas => [ 'x * .16667oz', 'x * .02083333cup', 'x * 5mL', 'x * .33333tbsp' ] },
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
