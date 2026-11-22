# tests-for: lib/JawnOS/Domain/Sync.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Backup.pm lib/JawnOS/Domain/Ble.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Say.pm lib/JawnOS/Manager/Part09.pm lib/JawnOS/Manager/Part35.pm lib/JawnOS/Manager/Part36.pm
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
ok( subs::provides('sync_bucket_gaps'), 'the domain loader maps sync_bucket_gaps' );
ok( subs::provides('sync_bucket_band_for'), 'the domain loader maps sync_bucket_band_for' );
require JawnOS::Domain::Sync;
ok( defined &subs::sync_plan_step, 'Domain::Sync defines it' );

# Settings are the one table whose durable count carries a row per device class
# and appointments are re-stamped in bulk, so the planner keeps offering them and
# the map is what keeps a quiet house quiet. At the weekly band one write moved
# the single bucket that held the whole week and every pull read all ~29k
# settings or ~37k appointments back. The peer refuses any band under one hour,
# so both localise by that floor and every other table keeps the week.
is( subs::sync_bucket_band_for('settings'), 3600000,
	'settings localise by the hour' );
is( subs::sync_bucket_band_for('settings_durable'), 3600000,
	'the durable map is measured at the same hour' );
is( subs::sync_bucket_band_for('appointments'), 3600000,
	'appointments localise by the book too' );
is( subs::sync_bucket_band_for('notes'), 7 * 24 * 60 * 60 * 1000,
	'every other table keeps the weekly band' );
cmp_ok( subs::sync_bucket_band_for('settings'), '>=', 3600000,
	'the hourly band meets the peer floor' );

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
	routers      => { count => 3,  sum => 30,   max => 30 },
	where_calls  => { count => 5,  sum => 50,   max => 50 },
};
my $theirs = {
	appointments => { count => 12, sum => 1500, max => 1200 },
	ai_house     => { count => 2,  sum => 300,  max => 200 },
	ai_jobs      => { count => 31, sum => 5000, max => 3000 },
	routers      => { count => 9,  sum => 90,   max => 90 },
	where_calls  => { count => 8,  sum => 80,   max => 80 },
};
my $guarded = subs::sync_plan($mine, $theirs, {}, {}, 1);
ok( exists $guarded->{'appointments'}, 'a real divergence still triggers its table' );
ok( !exists $guarded->{'ai_house'}, 'a carry-only table does not trigger a pull' );
ok( !exists $guarded->{'ai_jobs'},  'and neither does the other carry-only ledger' );
ok( !exists $guarded->{'routers'}, 'the network inventory rides, it does not take the slot' );
ok( !exists $guarded->{'where_calls'}, 'nor does the locator ledger' );
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
# Warehouse changes are the person's stock and are expected on the other
# machines as soon as they happen, so it goes ahead of the rotation whenever it
# is divergent. It leaves the plan once reconciled, so nothing is starved.
my $warehouse_priority = subs::sync_plan_step(
	{ appointments => 0, warehouse => 0 },
	1,
	{ appointments => { seen_at => 1 }, warehouse => { seen_at => 200 } },
);
is_deeply( [ keys %{$warehouse_priority} ], ['warehouse'],
	'warehouse takes the cap slot ahead of the rotation' );
my $warehouse_settled = subs::sync_plan_step(
	{ appointments => 0 },
	1,
	{ appointments => { seen_at => 1 } },
);
is_deeply( [ keys %{$warehouse_settled} ], ['appointments'],
	'and the rotation resumes once warehouse is out of the plan' );

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

# An appointment's write time is not comparable across machines after a
# re-stamp, so the same rows land in different bands. Completeness there is
# judged by the row count, or a finished whole-table read is never recorded and
# the next tick reads all ~121k rows again.
{
	local *subs::sync_table_digest = sub { return { count => 300, sum => 1, max => 1 } };
	my $map = { band => 3600000, buckets => {
		10 => { count => 120, sum => 999, max => 99 },
		11 => { count => 80,  sum => 999, max => 99 },
	} };
	ok( subs::sync_bands_complete('appointments', $map),
		'a divergent band picture is complete when every row is held' );
	$map->{'buckets'}->{11}->{'count'} = 181;
	ok( !subs::sync_bands_complete('appointments', $map),
		'a peer row we do not hold is still incomplete' );
	ok( subs::sync_table_complete('appointments', { count => 200, sum => 1, max => 1 }),
		'the whole-table fallback counts rows too' );
	ok( !subs::sync_table_complete('appointments', { count => 301, sum => 1, max => 1 }),
		'and still names a row we do not hold' );
}

# A band the local table already covers is not a gap, even when the peer's
# baseline says the band moved. A local appointment write comes back through a
# peer's merge; with one-week bands the current week holds ~42k appointments, so
# reading that band back every tick is a whole table-sized pull every few
# minutes. Only a peer band that is newer, larger, or newer-summed is read.
{
	my $local = {
		1 => { count => 42341, sum => 76014875947713774, max => 1795361550140 },
		2 => { count => 10,    sum => 100,                max => 100 },
	};
	my $peer = {
		1 => { count => 42328, sum => 75991536250919174, max => 1795361216646 },
		2 => { count => 11,    sum => 110,                max => 110 },
	};
	is_deeply( subs::sync_bucket_gaps($local, $peer, [ 1, 2 ]), [2],
		'a band the local table already covers is not read back' );
	is_deeply( subs::sync_bucket_gaps($local, $peer), [2],
		'the same filter names every uncovered peer band without a change list' );
	my $newer = { 1 => { count => 42341, sum => 76014875947713775, max => 1795361550141 } };
	is_deeply( subs::sync_bucket_gaps($local, $newer, [1]), [1],
		'a peer row newer than ours is still a gap' );
	my $more = { 1 => { count => 42342, sum => 76014875947713774, max => 1795361550140 } };
	is_deeply( subs::sync_bucket_gaps($local, $more, [1]), [1],
		'a peer row we do not hold is still a gap' );
	my $extra = { 3 => { count => 1, sum => 1, max => 1 } };
	is_deeply( subs::sync_bucket_gaps($local, $extra, [3]), [3],
		'a band we do not hold at all is still a gap' );
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
# A volume_result is best-effort. The listener runs inside a subprocessor child,
# where the send used to go inline and wait out the link-supervision timeout:
# one press every sixteen seconds, with every later tap queued behind it.
like( $ble, qr/sub bluetooth_sender_async \{.*?\$opts->\{'fork'\}/s,
	'the async send can be asked to fork even in a child' );
my $ble2 = read_file("$root/lib/JawnOS/Domain/Ble2.pm");
my @vol_ack = ( $ble2 =~ /type => 'volume_result'.*?\}, \{ fork => 1 \}\)/gs );
is( scalar @vol_ack, 2, 'both volume_result replies ride their own child' );

my $notify = read_file("$root/lib/JawnOS/Domain/Notify.pm");
like( $notify, qr/if \(\$watch_ip\) \{.*?\$http_ok = eval \{ \$send_http->\(\) \}/s,
	'a board with a LAN address takes the HTTP route before the bridge' );
my @notify = ( $notify =~ /name => 'embedded toggle (?:sender|refresh)', fork => 1/g );
is( scalar @notify, 2, 'both embedded toggle halves ride a child' );

my $say = read_file("$root/lib/JawnOS/Domain/Say.pm");
like( $say, qr/name => 'watch reply wifi', fork => 1/,  'the WiFi reply rides a child' );
like( $say, qr/name => 'watch reply audio', fork => 1/, 'the audio reply rides a child' );

my $part35 = read_file("$root/lib/JawnOS/Manager/Part35.pm");
like( $part35, qr/name => 'now me push', fork => 1/, 'the Now Me push rides a child' );

my $part36 = read_file("$root/lib/JawnOS/Manager/Part36.pm");
like( $part36, qr/\$plan_pull && !\$gimme && \(&subs::device_setter\(\) eq 'mobile' \|\| \$mobile_peer\)/,
	'a mobile pull caps the plan, and so does a pull from a mobile peer' );
like( $part36, qr/sync_plan_step\(\$plan, 1, \$seen\)/, 'the mobile cap is one table per pass, rotated by seen_at' );
# The planner and the puller must name one carry list: a table the planner
# refuses to let trigger is a table the pull must still carry, or it stops
# travelling altogether when it becomes carry-only.
my $part09 = read_file("$root/lib/JawnOS/Manager/Part09.pm");
like( $part09, qr/%carry = map \{ \$_ => 1 \} \@\{ &subs::sync_carry_tables\(\) \}/,
	'the pull carries every table the planner refuses to let trigger' );
like( $part09, qr/sync_bucket_gaps\(/, 'the pull reads only bands the local table does not cover' );
like( $part09, qr/sync_bucket_band_for\(\$table\)/, 'the pull measures each table at its own band' );
like( $part09, qr/\$table ne 'settings' && ref \$base eq 'HASH'/,
	'a settled settings baseline is not mistaken for a stale short-pull one' );
like( $part09, qr/\$have_base = 0 if \$have_base && .*\$table_band/,
	'a baseline from another band is not diffed against this map' );
my $carry = subs::sync_carry_tables();
ok( (grep { $_ eq 'routers' } @{$carry}), 'the network inventory is carry-only' );
ok( (grep { $_ eq 'where_calls' } @{$carry}), 'so is the locator ledger' );
ok( (grep { $_ eq 'window_events' } @{$carry}), 'window events ride a pull but do not start one' );
ok( (grep { $_ eq 'appointments' } @{$carry}) == 0, 'appointments still starts a pull' );

# ---- the fork option, behaviourally ---------------------------------------
# In a subprocessor child the default is an inline send, to keep a run of
# messages in order. { fork => 1 } opts out.
subs::preload('bluetooth_sender_async');
{
	no warnings 'redefine';
	my (@sent, @forked);
	local *subs::bluetooth_sender = sub { push @sent, $_[0]->{'message'}->{'type'} };
	local *subs::subprocessor = sub {
		my ($sub, $params) = @_;
		push @forked, $params->{'name'};
		return 1;
	};
	local $gb::subprocessed = 1;
	my $msg = { intent => 'x', chip_id => '1', edt => 'watch',
		message => { type => 'volume_result' } };
	subs::bluetooth_sender_async($msg, { fork => 1 });
	is( scalar @sent, 0, 'a forced fork does not send inline in a child' );
	is_deeply( \@forked, ['ble send'], 'it hands the send to its own child' );
	subs::bluetooth_sender_async($msg);
	is( scalar @sent, 1, 'and the default still sends inline to keep its place' );
}

# --- one output command at a time per board ---------------------------------
# A Pico services one HTTP client. Two presses answered at once leave the first
# half-answered and the second lost, and the board looks wedged until a physical
# switch wakes the link. The sender takes a per-chip file lock across both roads.
like($notify, qr/sub device_command_lock \{/, 'one helper serializes a board\'s output commands');
like($notify, qr/flock\(\$fh, LOCK_EX \| LOCK_NB\)/, 'the lock is exclusive and bounded');
like($notify, qr/device_command_lock\(\$chip_id\)/, 'the toggle sender takes it');
like($notify, qr/my \$send_http = sub \{/, 'the HTTP send is one closure');
like($notify, qr/select\(undef, undef, undef, 0\.15\)/, 'a failed send gets one short retry');
like($notify, qr/device command not delivered/, 'a command neither road carried is logged');
ok(index($notify, q{($asked || '?') . ' -> ' . ($state || '?')}) >= 0,
	'a delivered command logs the asked state and the board\'s answer');
like($notify, qr/\(bridge\)/, 'and the bridge road says so too');
like($notify, qr/\(http failed\)/, 'a failed own route is logged');
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/'JawnOS::Domain::Notify' for qw\([^)]*device_command_lock/,
	'the loader maps the lock helper');

done_testing();

