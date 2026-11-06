# tests-for: lib/JawnOS/Domain/Sync.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Ble.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Say.pm lib/JawnOS/Manager/Part35.pm lib/JawnOS/Manager/Part36.pm
# covers:    A mobile sync pass takes one table at a time, so a nine-table plan
#            no longer merges all nine in one request and runs the gauge hot for
#            most of a minute; and every subprocessor whose work can wait on the
#            BLE bridge is a real child, never inline in the request worker.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);

my $root = root();

ok( subs::provides('sync_plan_step'), 'the domain loader maps sync_plan_step' );
require JawnOS::Domain::Sync;
ok( defined &subs::sync_plan_step, 'Domain::Sync defines it' );

my $plan = { appointments => 1, continent => 0, settings => 2 };

my $one = subs::sync_plan_step($plan, 1);
is_deeply( [ sort keys %{$one} ], ['appointments'], 'one table, in a stable order' );

my $two = subs::sync_plan_step($plan, 2);
is_deeply( [ sort keys %{$two} ], [ 'appointments', 'continent' ], 'two tables when asked for two' );

is_deeply( subs::sync_plan_step($plan, 9), $plan, 'a plan already inside the cap is untouched' );
is_deeply( subs::sync_plan_step({}, 1), {}, 'an empty plan stays empty' );
is_deeply( subs::sync_plan_step($plan, 0), $plan, 'a non-positive cap means no cap' );
is_deeply( subs::sync_plan_step(undef, 1), {}, 'a missing plan is an empty plan' );

# Carry-only streams never start a pull. A machine's own ai_house row differs
# from every peer's by design, so it stayed divergent forever; because a capped
# mobile pass takes the first table in sorted order, ai_house claimed the one
# slot on every pass and appointments never got a turn (2026-11-05).
my $mine = {
	appointments => { count => 10, sum => 1000, max => 900 },
	ai_house     => { count => 1,  sum => 100,  max => 100 },
	ai_jobs      => { count => 0,  sum => 0,    max => 0 },
};
my $theirs = {
	appointments => { count => 12, sum => 1500, max => 1200 },
	ai_house     => { count => 2,  sum => 300,  max => 200 },
	ai_jobs      => { count => 31, sum => 5000, max => 3000 },
};
my $guarded = subs::sync_plan($mine, $theirs, {}, {}, 1);
ok( exists $guarded->{'appointments'}, 'a real divergence still triggers its table' );
ok( !exists $guarded->{'ai_house'}, 'a carry-only table does not trigger a pull' );
ok( !exists $guarded->{'ai_jobs'},  'and neither does the other carry-only ledger' );
is_deeply( [ keys %{ subs::sync_plan_step($guarded, 1) } ], ['appointments'],
	'the mobile cap gives its one slot to the real divergence' );

# An unchanged peer picture is not a reconciliation when our table still
# differs. Entries written before the completion check have no `seen_at`; they
# must be re-examined once, which is what heals the fleet after the update.
# A verified entry (`seen_at`) may be skipped. (The equal case is skipped at the
# top of sync_plan, before this branch is reached.)
my $stale = { appointments => { count => 12, sum => 1500, max => 1200, full => 1 } };
my $still = subs::sync_plan($mine, $theirs, {}, $stale, 1);
ok( exists $still->{'appointments'},
	'an unproven baseline does not hide a local gap' );
my $proven = { appointments => { count => 12, sum => 1500, max => 1200, full => 1, seen_at => 1 } };
my $settled = subs::sync_plan($mine, $theirs, {}, $proven, 1);
ok( !exists $settled->{'appointments'},
	'a completed baseline whose peer has not moved is skipped' );

# The cap must rotate: a constantly-written table (the phone's measures) would
# otherwise take the single mobile slot on every pass. The table reconciled
# longest ago goes first, and settings rotate through their durable key.
my $rotation = subs::sync_plan_step(
	{ appointments => 0, notes => 0 },
	1,
	{ appointments => { seen_at => 200 }, notes => { seen_at => 100 } },
);
is_deeply( [ keys %{$rotation} ], ['notes'],
	'the cap rotates to the table reconciled longest ago' );
my $settings_rotation = subs::sync_plan_step(
	{ appointments => 0, settings => 0 },
	1,
	{ appointments => { seen_at => 2 }, settings_durable => { seen_at => 1 } },
);
is_deeply( [ keys %{$settings_rotation} ], ['settings'],
	'settings rotate through their durable seen_at' );

# A pull may claim `full` only when we hold every row the peer's band map
# names. A peer that is merely behind does not make the pull incomplete (that
# would re-read its bands forever), while a row it holds and we missed does.
{
	local *subs::sync_table_digest = sub { return { count => 3, sum => 6, max => 3 } };
	ok( subs::sync_table_complete('notes', { count => 3, sum => 6, max => 3 }),
		'a matching table is complete' );
	ok( !subs::sync_table_complete('notes', { count => 4, sum => 9, max => 4 }),
		'a whole-table read that is still behind is not complete' );
}
{
	local *subs::sync_table_buckets = sub {
		my ($table, $band) = @_;
		return { band => $band, buckets => {
			1 => { count => 5, sum => 50, max => 50 },
			2 => { count => 5, sum => 50, max => 50 },
		} };
	};
	ok( subs::sync_bands_complete('notes', { band => 100, buckets => {
		1 => { count => 5, sum => 50, max => 50 },
		2 => { count => 4, sum => 40, max => 40 },
	}}), 'a peer that is behind is still fully held' );
	ok( !subs::sync_bands_complete('notes', { band => 100, buckets => {
		2 => { count => 6, sum => 60, max => 60 },
	}}), 'a peer row we do not hold is named' );
	ok( !subs::sync_bands_complete('notes', { band => 100, buckets => {
		1 => { count => 5, sum => 55, max => 55 },
	}}), 'the same count with a different picture is not complete' );
}

# The bridge client waits for the radio to acknowledge the write, and a watch
# that has slept suspends its link: the wait runs to the link-supervision
# timeout. subprocessor() runs inline when another job is already running, so
# every caller that can reach bluetooth_sender must ask for a real child.
my $ble = read_file("$root/lib/JawnOS/Domain/Ble.pm");
like( $ble, qr/name => 'embedded toggle push', fork => 1/, 'the toggle push rides a child' );
like( $ble, qr/foreach my \$edt \( qw\/microcontroller watch teletype\/ \)/,
	'the board is written first, so a sleeping watch cannot delay its relay' );
like( $ble, qr/\$found->\{'ip'\} = \$data->\{'ip'\}/,
	'the sighting keeps the board LAN address' );
like( $ble, qr/ip => \(\$chip->\{'ip'\} \|\| ''\)/,
	'and the device row carries it' );
like( $ble, qr/name => 'ble send', fork => 1/,             'the async BLE send rides a child' );

my $notify = read_file("$root/lib/JawnOS/Domain/Notify.pm");
like( $notify, qr/if \(\$watch_ip\) \{.*?return if \$http_ok;/s,
	'a board with a LAN address takes the HTTP route before the bridge' );
my @notify = ( $notify =~ /name => 'embedded toggle sender', fork => 1/g );
is( scalar @notify, 2, 'both embedded toggle senders ride a child' );

my $say = read_file("$root/lib/JawnOS/Domain/Say.pm");
like( $say, qr/name => 'watch reply wifi', fork => 1/,  'the WiFi reply rides a child' );
like( $say, qr/name => 'watch reply audio', fork => 1/, 'the audio reply rides a child' );

my $part35 = read_file("$root/lib/JawnOS/Manager/Part35.pm");
like( $part35, qr/name => 'now me push', fork => 1/, 'the Now Me push rides a child' );

my $part36 = read_file("$root/lib/JawnOS/Manager/Part36.pm");
like( $part36, qr/\$plan_pull && !\$gimme && \(&subs::device_setter\(\) eq 'mobile' \|\| \$mobile_peer\)/,
	'a mobile pull caps the plan, and so does a pull from a mobile peer' );
like( $part36, qr/sync_plan_step\(\$plan, 1, \$seen\)/, 'the mobile cap is one table per pass, rotated by seen_at' );

done_testing();
