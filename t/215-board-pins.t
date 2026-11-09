# tests-for: lib/JawnOS/Domain/Boardpins.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_embedded.pm lib/JawnOS/Routes/manager_embedded.pm
# covers:    a board's self-description (bare JSON or the "JAWNPINS" console
#            line), adopting it into the door record without inventing apps,
#            attaching a discovered pin to an appointment's door and ia map, and
#            the two route rows that reach those helpers.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json encode_json);
use JawnOSTest;

for my $name (qw(
	board_pins_parse board_pins_usb_read board_pins_http_read
	board_pins_adopt board_pins_attach
	settings_grabber setting_grabber setting_setter
)) {
	subs::preload($name);
}

for my $name (qw(
	board_pins_parse board_pins_usb_read board_pins_http_read
	board_pins_adopt board_pins_attach
)) {
	ok(subs::provides($name), "the domain loader maps $name");
}

my $report = {
	t => 'pins',
	chip => 'F130174C19C1FACB',
	version => '0.1.2278',
	purpose => 'microcontroller',
	components => [
		{ pin => 3, component => 'relay', app => 'weather', inverted => '1' },
	],
	free => [4, 5, 6],
	probe => [
		{ pin => 15, kind => 'grounded', analog => 0 },
		{ pin => 16, kind => 'floating', analog => 512 },
	],
};

subtest 'parse accepts a bare object and the console line' => sub {
	my $json = encode_json $report;

	my $bare = subs::board_pins_parse($json);
	ok($bare, 'a bare JSON object parses');
	is($bare->{'chip'}, 'F130174C19C1FACB', 'the chip survives');
	is($bare->{'version'}, '0.1.2278', 'and the build');
	is(scalar @{$bare->{'components'}}, 1, 'components are there');
	is_deeply($bare->{'free'}, [4, 5, 6], 'free pins are there');

	my $line = subs::board_pins_parse("booting\r\nJAWNPINS $json\r\n");
	ok($line, 'the USB console line parses');
	is($line->{'chip'}, 'F130174C19C1FACB', 'the console line carries the chip');
	is(scalar @{$line->{'probe'}}, 2, 'and the probe results');

	ok(!defined subs::board_pins_parse(''), 'empty text is nothing');
	ok(!defined subs::board_pins_parse('JAWNPINS not json'), 'garbage is nothing');
	ok(!defined subs::board_pins_parse('{"t":"pins","chip":"x"}'),
		'an object without components is not a pins report');
	ok(!defined subs::board_pins_parse('JAWNPINS ' . encode_json({ components => 'x', probe => [] })),
		'components must be an array');
	ok(!defined subs::board_pins_parse('JAWNPINS ' . encode_json({ components => [], probe => ['x'] })),
		'probe entries must be objects');
};

subtest 'adopt drops keys the board cannot have and keeps the rest' => sub {
	my %store = (
		operator_door => encode_json({
			relay28 => { app => 'weather', component => 'relay', pin => '28' },
			led16 => { app => 'lights', component => 'led', pin => '16' },
			__specs => { name => 'Pico' },
			__shutup => { patience => 'abc' },
			'3' => { app => 'junk' },
			'<2' => 1,
			'>2' => 1,
			led => 1,
			relay => 1,
		}),
	);
	my %wrote;
	{
		no warnings 'redefine';
		local *subs::setting_grabber = sub {
			my ($a) = @_;
			return $store{ $a->{'setting'} };
		};
		local *subs::setting_setter = sub {
			my ($a) = @_;
			$wrote{ $a->{'setting'} } = $a->{'value'};
			return 1;
		};

		my $summary = subs::board_pins_adopt($report, {
			edt => 'microcontroller', chip_id => 'chip1',
		});
		ok($summary->{'ok'}, 'adopt succeeds');
		is($summary->{'chip'}, 'F130174C19C1FACB', 'the summary names the chip');
		is($summary->{'version'}, '0.1.2278', 'and the build');
		is($summary->{'components'}, 1, 'it counts the board components');
		is($summary->{'free'}, 3, 'and the free pins');
		is($summary->{'probed'}, 2, 'and the probe results');
		is_deeply([ sort @{ $summary->{'dropped'} } ],
			[ sort qw(3 <2 >2 led relay) ], 'junk keys are named');

		my $door = decode_json($wrote{'operator_door'});
		is_deeply($door->{'relay28'},
			{ app => 'weather', component => 'relay', pin => '28' },
			'a real component entry is kept exactly as it was');
		is_deeply($door->{'led16'},
			{ app => 'lights', component => 'led', pin => '16' },
			'the second real entry is kept');
		ok($door->{'__specs'}, '__specs is not wiring and is kept');
		ok($door->{'__shutup'}, '__shutup is kept');
		ok(!exists $door->{'3'}, 'the numeric key is gone');
		ok(!exists $door->{'<2'}, 'the comparison key is gone');
		ok(!exists $door->{'led'}, 'a component name with no pin is gone');

		my $pins = decode_json($wrote{'board_pins'});
		is($pins->{'chip'}, 'F130174C19C1FACB',
			"the board's own truth is stored beside the door");
	}
};

subtest 'adopt does not rewrite a door it did not repair' => sub {
	my %store = (
		operator_door => encode_json({
			relay28 => { app => 'weather', component => 'relay', pin => '28' },
		}),
	);
	my %wrote;
	{
		no warnings 'redefine';
		local *subs::setting_grabber = sub {
			my ($a) = @_;
			return $store{ $a->{'setting'} };
		};
		local *subs::setting_setter = sub {
			my ($a) = @_;
			$wrote{ $a->{'setting'} } = $a->{'value'};
			return 1;
		};

		my $summary = subs::board_pins_adopt($report, {
			edt => 'microcontroller', chip_id => 'chip1',
		});
		is_deeply($summary->{'dropped'}, [], 'nothing is dropped');
		ok(!exists $wrote{'operator_door'}, 'a clean door is not rewritten');
		ok(exists $wrote{'board_pins'}, 'but the live report is still recorded');
	}
};

subtest 'attach refuses bad pins, components and apps' => sub {
	{
		no warnings 'redefine';
		local *subs::setting_grabber = sub {
			my ($a) = @_;
			return 'uuid-lights' if ($a->{'setting'} // '') eq 'uuid' && $a->{'app'} eq 'lights';
			return undef;
		};
		local *subs::settings_grabber = sub {
			my ($a) = @_;
			return { app => $a->{'app'}, uuid => 'uuid-lights' } if $a->{'app'} eq 'lights';
			return { app => $a->{'app'} };
		};
		my %wrote;
		local *subs::setting_setter = sub {
			my ($a) = @_;
			$wrote{ $a->{'setting'} } = $a->{'value'};
			return 1;
		};

		my $bad_pin = subs::board_pins_attach({
			edt => 'microcontroller', chip_id => 'chip1',
			pin => 30, component => 'relay', app => 'lights',
		});
		ok(!$bad_pin->{'ok'}, 'pin 30 is refused');
		like($bad_pin->{'error'}, qr/0 to 29/, 'and the range is named');

		my $bad_component = subs::board_pins_attach({
			edt => 'microcontroller', chip_id => 'chip1',
			pin => 28, component => 'lamp', app => 'lights',
		});
		ok(!$bad_component->{'ok'}, 'an unknown component is refused');
		like($bad_component->{'error'}, qr/unknown component/, 'and named');

		my $bad_app = subs::board_pins_attach({
			edt => 'microcontroller', chip_id => 'chip1',
			pin => 28, component => 'relay', app => 'nope',
		});
		ok(!$bad_app->{'ok'}, 'an app that does not exist is refused');
		like($bad_app->{'error'}, qr/no such appointment/, 'and named');

		is(scalar keys %wrote, 0, 'a refused attach writes nothing');
	}
};

subtest 'attach writes the door and the appointment wiring' => sub {
	my %store = (
		operator_door => encode_json({
			relay28 => { app => 'old', component => 'relay', pin => '28', measure => 'temperature' },
		}),
		ia => encode_json({ chip1 => { 5 => { app => 'other', movement => 'start' } } }),
	);
	my %wrote;
	{
		no warnings 'redefine';
		local *subs::setting_grabber = sub {
			my ($a) = @_;
			return 'uuid-lights' if ($a->{'setting'} // '') eq 'uuid' && $a->{'app'} eq 'lights';
			return $store{ $a->{'setting'} };
		};
		local *subs::settings_grabber = sub {
			my ($a) = @_;
			return { app => $a->{'app'}, uuid => 'uuid-lights' } if $a->{'app'} eq 'lights';
			return { app => $a->{'app'} };
		};
		local *subs::setting_setter = sub {
			my ($a) = @_;
			$wrote{ $a->{'setting'} } = $a->{'value'};
			return 1;
		};

		my $r = subs::board_pins_attach({
			edt => 'microcontroller', chip_id => 'chip1',
			pin => 28, component => 'relay', app => 'lights',
			inverted => 1, movement => 'start',
		});
		ok($r->{'ok'}, 'a relay attaches');
		is($r->{'attached'}->{'key'}, 'relay28', 'the door key is component+pin');

		my $door = decode_json($wrote{'operator_door'});
		is($door->{'relay28'}->{'app'}, 'lights', 'the door names the appointment');
		is($door->{'relay28'}->{'direction'}, 'output', 'a relay is an output');
		is($door->{'relay28'}->{'edt'}, 'microcontroller', 'the device class is recorded');
		is($door->{'relay28'}->{'pin'}, '28', 'the pin is a string, as doors store it');
		is($door->{'relay28'}->{'inverted'}, 1, 'the inversion is kept');
		is($door->{'relay28'}->{'movement'}, 'start', 'the movement is kept');
		is($door->{'relay28'}->{'measure'}, 'temperature',
			'a field the attach did not name is preserved');

		my $ia = decode_json($wrote{'ia'});
		is($ia->{'chip1'}->{'28'}->{'app'}, 'lights',
			"the appointment's wiring map reaches the pin");
		is($ia->{'chip1'}->{'28'}->{'direction'}, 'output', 'with the same direction');
		is($ia->{'chip1'}->{'28'}->{'inverted'}, 1, 'and the same inversion');
		is($ia->{'chip1'}->{'5'}->{'app'}, 'other',
			'other wiring in the map is untouched');

		%wrote = ();
		my $button = subs::board_pins_attach({
			edt => 'microcontroller', chip_id => 'chip1',
			pin => 14, component => 'button', app => 'lights',
		});
		ok($button->{'ok'}, 'a button attaches');
		my $door2 = decode_json($wrote{'operator_door'});
		is($door2->{'button14'}->{'direction'}, 'input', 'a button is an input');
		is($door2->{'button14'}->{'inverted'}, 0, 'an absent inversion is zero');
		is($door2->{'button14'}->{'movement'}, 'start', 'an absent movement defaults to start');
	}
};

subtest 'the board pin routes reach their actions' => sub {
	my $routes = read_file(root() . '/lib/JawnOS/Routes/manager_embedded.pm');
	my %row;
	while ($routes =~ /\[\s*(\d+)\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'(action_\d+)'\s*\]/g) {
		$row{$1} = [ $1, $2, $3, $4 ];
	}
	for my $id (43934, 43947) {
		my $r = $row{$id};
		ok($r, "route row $id exists");
		is($r->[3], 'action_' . $r->[0], "row $id names its own action") if $r;
	}
	is($row{43934}->[1], 'get', 'board_pins is a read');
	is($row{43934}->[2], '/manager/embedded/board_pins', 'at the board_pins path');
	is($row{43947}->[1], 'post', 'board_pins_attach is a write');
	is($row{43947}->[2], '/manager/embedded/board_pins_attach', 'at its own path');

	my $controller = read_file(root() . '/lib/JawnOS/Controller/manager_embedded.pm');
	like($controller, qr/sub\s+action_43934\b/, 'the board_pins action is defined');
	like($controller, qr/sub\s+action_43947\b/, 'the attach action is defined');
};

done_testing();
