# tests-for: lib/JawnOS/Domain/Embedded2.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_misc10.pm lib/JawnOS/Routes/manager_misc10.pm templates/handbook/today.html.ep public/js/manager/manager/08_handbook.js public/css/manager.css perl/help/topics_configure.pl
# covers:    the house devices the Handbook's Today page lists (an app wired to
#            a relay or LED on an embedded microcontroller), its stored on/off
#            state, and the template, route and script that switch it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json encode_json);
use JawnOSTest;

for my $name (qw(embedded_relay_devices settings_grabber format_name)) {
	subs::preload($name);
}
ok(subs::provides('embedded_relay_devices'), 'the domain loader maps embedded_relay_devices');

subtest 'only a binary output on a microcontroller makes a house device' => sub {
	my $wired = encode_json({
		CHIPB => {
			'28' => { app => 'le_tableau_stereo', component => 'relay', direction => 'output', edt => 'microcontroller', ip => '192.168.1.122', pin => '28', movement => 'start' },
			'15' => { app => 'le_tableau_stereo', component => 'switch', direction => 'input', edt => 'microcontroller', ip => '192.168.1.122', pin => '15' },
			'1'  => { app => 'le_tableau_stereo', component => 'servo', direction => 'output', edt => 'microcontroller', ip => '192.168.1.122', pin => '1', movement => 'start' },
			'7'  => { app => 'weather', component => 'relay', direction => 'output', edt => 'microcontroller', ip => '192.168.1.122', pin => '7', movement => 'measure' },
		},
		CHIPA => {
			'9' => { app => 'le_tableau_stereo', component => 'relay', direction => 'output', edt => 'teletype', ip => '192.168.2.8', pin => '9' },
		},
	});
	my $led_only = encode_json({
		CHIPC => {
			'16' => { app => 'lights', component => 'led', direction => 'output', edt => 'microcontroller', ip => '192.168.1.112', pin => '16', movement => 'start' },
		},
	});
	my $input_only = encode_json({
		CHIPD => { '3' => { app => 'buttons', component => 'button', direction => 'input', edt => 'microcontroller', pin => '3', movement => 'start' } },
	});
	my $measure_only = encode_json({
		CHIPE => { '7' => { app => 'weather', component => 'relay', direction => 'output', edt => 'microcontroller', pin => '7', movement => 'measure' } },
	});
	my $rows = [
		{ app => 'le_tableau_stereo', value => $wired },
		{ app => 'lights', value => $led_only },
		{ app => 'buttons', value => $input_only },
		{ app => 'weather', value => $measure_only },
		{ app => 'broken', value => '{ not json' },
		{ app => 'empty', value => '[]' },
	];
	my %states = (le_tableau_stereo => 'on', lights => 'off', buttons => 'on');
	{
		no warnings 'redefine';
		local *subs::settings_grabber = sub {
			my ($a) = @_;
			return { toggle => $states{ $a->{'app'} } };
		};
		my $devices = subs::embedded_relay_devices($rows);
		is(scalar @{$devices}, 2, 'only apps with a relay or LED on a microcontroller are listed');
		my %by_app = map { $_->{'app'} => $_ } @{$devices};
		ok($by_app{'le_tableau_stereo'}, 'the relay app is listed');
		is($by_app{'le_tableau_stereo'}->{'name'}, 'Le Tableau Stereo', 'the app reads as its name');
		is($by_app{'le_tableau_stereo'}->{'state'}, 'on', 'the stored toggle is the state');
		is($by_app{'le_tableau_stereo'}->{'component'}, 'relay', 'the primary output is the relay');
		is($by_app{'le_tableau_stereo'}->{'pin'}, '28', 'and its pin');
		is($by_app{'le_tableau_stereo'}->{'chip_id'}, 'CHIPB', 'and its board');
		is($by_app{'le_tableau_stereo'}->{'ip'}, '192.168.1.122', 'and the address the command is sent to');
		is($by_app{'le_tableau_stereo'}->{'outputs'}, 1, 'a servo and an input do not add outputs');
		is($by_app{'lights'}->{'component'}, 'led', 'an LED-only app is a binary output too');
		is($by_app{'lights'}->{'state'}, 'off', 'and off still reads as off');
		ok(!$by_app{'buttons'}, 'an input-only app is not a house device');
		ok(!$by_app{'weather'}, 'a relay driven by a measurement is not an on/off device');
		ok(!$by_app{'broken'}, 'unreadable wiring is skipped');
		ok(!$by_app{'empty'}, 'a wiring map that is not an object is skipped');
	}
};

subtest 'a numeric or missing toggle is read as a state' => sub {
	my $wired = encode_json({
		CHIP => { '5' => { component => 'relay', direction => 'output', edt => 'microcontroller', ip => '192.168.1.50', pin => '5', movement => 'start' } },
	});
	my $rows = [
		{ app => 'one', value => $wired },
		{ app => 'zero', value => $wired },
		{ app => 'none', value => $wired },
	];
	{
		no warnings 'redefine';
		local *subs::settings_grabber = sub {
			my ($a) = @_;
			return { toggle => 1 } if $a->{'app'} eq 'one';
			return { toggle => 0 } if $a->{'app'} eq 'zero';
			return {};
		};
		my %by_app = map { $_->{'app'} => $_ } @{ subs::embedded_relay_devices($rows) };
		is($by_app{'one'}->{'state'}, 'on', '1 is on');
		is($by_app{'zero'}->{'state'}, 'off', '0 is off');
		is($by_app{'none'}->{'state'}, 'off', 'a missing toggle is off');
	}
};

subtest 'the Today page, its route and its script are wired together' => sub {
	my $root = root();
	my $template = read_file("$root/templates/handbook/today.html.ep");
	like($template, qr/handbook_today_devices/, 'the Devices card is on Today');
	like($template, qr/handbook_today_device_toggle/, 'each device carries a switch');
	like($template, qr/hint="<%= &subs::ui\('Turn this device on or off'\) %>"/,
		'the switch has a fixed, translatable hint');
	like($template, qr/\$t->\{'is_today'\}/, 'the card is drawn for today only');

	my @cards = qw(handbook_today_money handbook_today_devices handbook_today_projects handbook_today_life handbook_today_people);
	my @at = map { index($template, $_) } @cards;
	is_deeply(\@at, [ sort { $a <=> $b } @at ],
		'Money, Devices and Projects keep the left column, in that order');
	is(scalar(() = $template =~ /handbook_today_column/g), 2, 'the grid is two columns');

	my $css = read_file("$root/public/css/manager.css");
	like($css, qr/\.handbook_today_column \{ display: contents; \}/,
		'the phone view flattens the columns');
	like($css, qr/\.handbook_today_devices \{ order: 2; \}/,
		'and keeps Devices second, under Money');

	my $js = read_file("$root/public/js/manager/manager/08_handbook.js");
	like($js, qr#url: '/manager/handbook/device'#, 'the switch posts to the Handbook device route');
	like($js, qr/handbook_today_device_toggle/, 'and it handles the card\'s button');

	my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc10.pm");
	like($controller, qr/^sub action_34560\b/m, 'the route has its handler');
	like($controller, qr/setting => 'toggle'/, 'the handler writes the app toggle');
	like($controller, qr/source => 'panel'/, 'through the same settings path the app window uses');
	like($controller, qr/embedded_relay_devices/, 'and refuses a device the fleet does not wire');

	my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc10.pm");
	like($routes, qr/\[34560, 'post', '\/manager\/handbook\/device', 'action_34560'\]/,
		'the route row names the handler');

	my $help = read_file("$root/perl/help/topics_configure.pl");
	like($help, qr/Devices, under Money/, 'the Handbook topic explains the card');
};

done_testing();
