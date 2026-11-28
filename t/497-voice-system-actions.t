# tests-for: perl/gb/03_engines_and_tools.pl perl/gb/11_voice_actions_system.pl lib/JawnOS/Routes.pm perl/help/topics_apps.pl perl/help/topics_configure.pl perl/help/topics_features.pl perl/help/topics_mail.pl perl/help/topics_people.pl perl/help/topics_web.pl
# covers:    The system/app actions voice was missing: power, notifications,
#           packages, network, security, handbook, scan, studio, notes, search,
#           IDE and the process monitor. Every entry names a route the server
#           dispatches, a kind and method that agree, an app-scoped help topic,
#           and a speech sub; the key reads and writes name the routes they do.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

require './perl/gb/03_engines_and_tools.pl';
my $base = scalar @gb::app_actions;
require './perl/gb/11_voice_actions_system.pl';
require './perl/help.pl';
require 'JawnOS/Routes.pm';

my %mine_key = map { $_ => 1 } qw(power/status power/plan power/charge power/sleep notifications/list notifications/clear notifications/seen packages/outdated packages/upgrade packages/install network/status network/wifi_scan network/wifi_connect network/radio network/vpn security/lock handbook/journal handbook/plant scan/capture studio/transport notes/save search/web ide/save process_monitor/read);
my @mine = grep { $mine_key{ ($_->{'app'} // '') . '/' . ($_->{'do'} // '') } } @gb::app_actions;
ok(scalar @mine, 'the system actions file declares entries');

# ------------------------------------------------------------ every entry
my %route = map { lc($_->[1]) . ' ' . $_->[2] => $_->[3] } @{ JawnOS::Routes->table };
my %topic_app = map { (help::get($_->{'id'})->{'app'} // '') => 1 } help::catalogue();
my %seen;
foreach my $a ( @mine ) {
	my $label = $a->{'app'} . ' ' . $a->{'do'};
	ok(!$seen{$label}++, $label . ' is declared once');
	ok(defined $a->{'desc'} && length $a->{'desc'}, $label . ' has a description');
	my $key = lc($a->{'method'} // '') . ' ' . ($a->{'route'} // '');
	ok($route{$key}, $label . ' names a real route');
	like($a->{'kind'} // '', qr/^(?:read|write)$/, $label . ' has a known kind');
	is(lc($a->{'method'} // ''), ($a->{'kind'} // '') eq 'read' ? 'get' : 'post',
		$label . ' uses the method its kind requires');
	ok($topic_app{ $a->{'app'} }, $label . ' names an app with a help topic');
	ok(ref $a->{'speech'} eq 'CODE', $label . ' can speak its result');
	like($a->{'confirm'} // '', qr/\S/, $label . ' carries a confirmation')
		if ($a->{'kind'} // '') eq 'write';
	is(ref $a->{'params'}, 'HASH', $label . ' declares a parameter map');
	foreach my $p ( sort keys %{ $a->{'params'} || {} } ) {
		like($p, qr/^[a-z][a-z0-9_]*$/, $label . ' parameter name is a plain key');
	}
	my $said = eval { $a->{'speech'}->({}, {}) };
	ok(defined $said && length $said, $label . ' speaks a sentence from an empty answer');
}

# ------------------------------------------------------------ the families
my %by;
$by{ $_->{'app'} . '/' . $_->{'do'} } = $_ for @mine;

sub entry_is {
	my ($key, $kind, $method, $path, $name) = @_;
	my $a = $by{$key};
	ok($a, $name . ' is declared') or return;
	is($a->{'kind'}, $kind, $name . ' is a ' . $kind);
	is(lc($a->{'method'}), $method, $name . ' uses ' . uc($method));
	is($a->{'route'}, $path, $name . ' names ' . $path);
}

# Power: status, plan, charge ceiling, sleep.
entry_is('power/status',   'read',  'get',  '/manager/power_status', 'power status');
entry_is('power/plan',     'write', 'post', '/manager/power/plan',   'power plan');
entry_is('power/charge',   'write', 'post', '/manager/power/charge', 'power charge ceiling');
entry_is('power/sleep',    'write', 'post', '/manager/power/sleep',  'power sleep');

# Notifications: list (the JSON status), clear/remove, mark seen.
entry_is('notifications/list',  'read',  'get',  '/manager/notifications/status', 'notifications list');
entry_is('notifications/clear', 'write', 'post', '/manager/notifications/remove', 'notifications clear');
entry_is('notifications/seen',  'write', 'post', '/manager/notifications/seen',   'notifications seen');

# Packages: outdated, upgrade, install.
entry_is('packages/outdated', 'read',  'get',  '/manager/packages/outdated', 'packages outdated');
entry_is('packages/upgrade',  'write', 'post', '/manager/packages/upgrade',  'packages upgrade');
entry_is('packages/install',  'write', 'post', '/manager/packages/install',  'packages install');

# Network: status, Wi-Fi scan and connect, radio, VPN.
entry_is('network/status',       'read',  'get',  '/manager/network/status',       'network status');
entry_is('network/wifi_scan',    'write', 'post', '/manager/network/wifi_scan',    'network Wi-Fi scan');
entry_is('network/wifi_connect', 'write', 'post', '/manager/network/wifi_connect', 'network Wi-Fi connect');
entry_is('network/radio',        'write', 'post', '/manager/network/radio',        'network radio');
entry_is('network/vpn',          'write', 'post', '/manager/network/vpn',          'network VPN');

# Security: lock this screen or the house.
entry_is('security/lock', 'write', 'post', '/manager/lock_session', 'security lock');

# Handbook, scan, notes, IDE and process monitor each answer JSON.
entry_is('handbook/journal', 'write', 'post', '/manager/handbook/journal', 'handbook journal');
entry_is('handbook/plant',   'write', 'post', '/manager/handbook/plant',   'handbook plant');
entry_is('scan/capture',     'write', 'post', '/manager/scan/capture',     'scan capture');
entry_is('notes/save',       'write', 'post', '/manager/note_save',        'notes save');
entry_is('ide/save',         'write', 'post', '/manager/ide/save',         'IDE save');
entry_is('process_monitor/read', 'read', 'get', '/manager/process_monitor/data', 'process monitor read');
entry_is('search/web',       'read',  'get',  '/manager/search/web',       'search web');
entry_is('studio/transport', 'write', 'post', '/manager/studio/transport', 'studio transport');

# ------------------------------------------------------------ speech shapes
my $power = $by{'power/status'};
like($power->{'speech'}->({ battery => { present => 1, percentage => 82, status => 'discharging' } }),
	qr/82 percent/, 'power status reads the percentage');
like($power->{'speech'}->({ battery => { present => 0 } }),
	qr/mains power/, 'power status says a machine without a pack is on mains');

my $notifs = $by{'notifications/list'};
like($notifs->{'speech'}->({ total => 3, seen => 100, notifications => [
	{ timestamp => 50 }, { timestamp => 150 }, { timestamp => 200 },
] }), qr/3 notices, 2 new/, 'notifications list counts the new ones');
like($notifs->{'speech'}->({ total => 0 }), qr/no notices/, 'an empty list says there are no notices');

like($by{'notifications/clear'}->{'speech'}->([ 'a', 'b' ]), qr/Removed 2 notices/,
	'notifications clear counts what it removed');

like($by{'packages/outdated'}->{'speech'}->({ count => 4 }), qr/4 packages are out of date/,
	'packages outdated counts');
like($by{'packages/outdated'}->{'speech'}->({ count => 0 }), qr/up to date/,
	'packages outdated says none are behind');

like($by{'network/status'}->{'speech'}->({ wifi => {
	radio_powered => 1,
	interfaces => [ { state => 'connected', ssid => 'the house' } ],
} }), qr/the house/, 'network status names the connected SSID');

like($by{'security/lock'}->{'speech'}->({ target => '' }), qr/house is locked/,
	'a whole-house lock says so');
like($by{'security/lock'}->{'speech'}->({ target => 'abc' }), qr/screen is locked/,
	'a single-screen lock says so');

like($by{'search/web'}->{'speech'}->({ engines => [
	{ results => [ { title => 'First hit' }, { title => 'Second hit' } ] },
] }, { q => 'perl' }), qr/2 web results.*First hit/, 'search web counts and names a first hit');

done_testing();
