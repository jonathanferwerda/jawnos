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
like($autoscale, qr/sleep 0\.5;/, 'the supervisor samples twice a second');
like($autoscale, qr/\$kind eq 'end' && \$now - \$at <= \$recent_ms/, 'a recent end is activity');
my $calendar = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
like($calendar, qr/\$request_busy_depth > 0 \? 'start ' : 'end '/, 'the marker names a start and an end');
like($autoscale, qr/return \$prefork if \$max <= \$min;/,
	'a cap equal to the pool never even starts the supervisor');

done_testing();
