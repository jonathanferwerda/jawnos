# tests-for: perl/President.pl perl/President/prefork_autoscale.pl lib/JawnOS/Domain/Calendar.pm
# covers:    A phone starts the dock/ticket listener, no tty listeners, and never grows its main pool.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A handheld carried two teletype doors nothing on it can use: a session needs a
# shell on the machine it runs on, and Android offers none. Each was a whole app
# - a prefork manager plus a worker - in a tree Android's low-memory killer is
# already watching, so a phone skips them.
#
# The dock door is different: it is the local ticket desk. app_ticket.pl mints
# the forever ticket on that port, the app opens .shots/ticket.txt there, and
# JawnFirstRun waits for it, so it runs on every device. v0.1.2169 removed it
# with the tty servers and the phone could no longer sign in; the master's
# watchdog, which asks every configured port, then restarted the healthy tree
# every 90 seconds. The main pool also stops growing on a phone: every extra
# worker was a fork of a 100 MB+ process, and that spike is what tripped the
# killer.

my $root = repo_root();
my $src = read_file("$root/perl/President.pl");
my $autoscale = read_file("$root/perl/President/prefork_autoscale.pl");

my @guards;
while ($src =~ /if \(\$device ne 'mobile'\) \{/g) {
	push @guards, pos($src);
}
is(scalar @guards, 1, 'a phone skips the teletype listeners only');

like($src, qr/&server_process\('\.\/perl\/Manager\.pl', \[[^\]]*\],\s*purpose => 'locker', name => 'Pro Locker Server'/s,
	'the dock/ticket listener starts on a phone');

my $rest = $src;
$rest =~ s/if \(\$device ne 'mobile'\) \{.*?\n\t\t\}\n//s;
for my $keep ('Pro Locker Server', 'Pro WS Server', 'Pro Main Server', 'Pro Alarm Server', 'Watch Server') {
	like($rest, qr/name => '\Q$keep\E'/, "$keep still starts on a phone");
}

like($src, qr/my \$configured_max = .*?main_workers_max/s, 'a configured burst ceiling is read');
like($src, qr/autoscale_max => \$main_workers_max\)/, 'the ceiling reaches the pool');
like($autoscale, qr/my \$recent_ms = 3000;/, 'a worker that just finished still counts as active');
like($autoscale, qr/my \$grow_by = 3;/, 'a burst opens three slots at a time');
like($autoscale, qr/my \$shrink_after = 20;/, 'ten quiet seconds retires workers at a half-second sample');
like($autoscale, qr/select\(undef, undef, undef, 0\.5\);/, 'the supervisor samples twice a second without a busy loop');
like($autoscale, qr/\$kind eq 'end' && \$now - \$at <= \$recent_ms/, 'a recent end is activity');
my $calendar = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
like($calendar, qr/\$request_busy_depth > 0 \? 'start ' : 'end '/, 'the marker names a start and an end');
like($autoscale, qr/return \$prefork if \$max <= \$min;/,
	'a cap equal to the pool never even starts the supervisor');

# The pool emptied on the live phone: a shrink burst was coalesced into fewer
# TTIN deliveries than the supervisor counted, so a later TTOU retired workers
# that did not exist. At workers=0 the manager (Mojo::Server::Prefork) never
# spawns again - `_manage` adds spare only for workers already shutting down -
# and it keeps the listening socket open while answering nothing.
like($autoscale, qr/sub prefork_live_workers \{/,
	'the supervisor reads the manager\'s real pool, not only its own target');
like($autoscale, qr/if \(\$low >= \$shrink_after && \$live > \$min\)/,
	'shrinking starts from the real pool');
like($autoscale, qr/\$drop = \$live - \$min if \$live - \$drop < \$min;/,
	'and never plans to retire below the resting pool');
like($src, qr/worker exit purpose=/, 'a worker exit says which pool lost it');
like($src, qr/\$prefork->accepts\(500\) if \$device eq 'mobile'/,
	'a phone still recycles a worker after 500 accepts');
like($src, qr/\$prefork->heartbeat_interval\(1\)/, 'the fallback heartbeat is a second');
like($src, qr/\$prefork->heartbeat_timeout\(200\)/, 'the heartbeat timeout is still 200 seconds');

subtest 'the manager refuses a target below the resting pool' => sub {
	require Mojo::Server::Prefork;
	require "$root/perl/President/prefork_autoscale.pl";
	my $pool = President::PoolPrefork->new(listen => [], min_workers => 3);
	ok($pool->isa('Mojo::Server::Prefork'), 'the floored pool is still a Prefork');
	$pool->workers(7);
	is($pool->workers, 7, 'growing is accepted');
	$pool->workers(0);
	is($pool->workers, 3, 'a shrink to zero is held at the resting pool');
	$pool->workers(2);
	is($pool->workers, 3, 'a one-worker overshoot is held too');
};

subtest 'the supervisor counts the manager\'s real children' => sub {
	my $kid = fork();
	skip 'cannot fork', 1 unless defined $kid;
	if (!$kid) { select(undef, undef, undef, 0.3); exit 0 }
	my $seen = President::prefork_live_workers($$);
	is($seen, 1, 'one worker child is one worker, not the count minus one');
	waitpid $kid, 0;
};

done_testing();
