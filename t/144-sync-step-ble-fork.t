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

# The bridge client waits for the radio to acknowledge the write, and a watch
# that has slept suspends its link: the wait runs to the link-supervision
# timeout. subprocessor() runs inline when another job is already running, so
# every caller that can reach bluetooth_sender must ask for a real child.
my $ble = read_file("$root/lib/JawnOS/Domain/Ble.pm");
like( $ble, qr/name => 'embedded toggle push', fork => 1/, 'the toggle push rides a child' );
like( $ble, qr/name => 'ble send', fork => 1/,             'the async BLE send rides a child' );

my $notify = read_file("$root/lib/JawnOS/Domain/Notify.pm");
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
like( $part36, qr/sync_plan_step\(\$plan, 1\)/, 'the mobile cap is one table per pass' );

done_testing();
