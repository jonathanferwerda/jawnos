# tests-for: perl/President.pl scripts/app_ticket.pl jawn
# covers: the ticket desk (the locker on config.json's `port`) runs on every
#         device, including a handheld. Removing it on mobile (v0.1.2169) left
#         the phone unable to sign in, and the master's two-port watchdog then
#         restarted a healthy tree every 90 seconds.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $root      = "$FindBin::Bin/..";
my $president = read_file("$root/perl/President.pl");
my $ticket    = read_file("$root/scripts/app_ticket.pl");
my $master    = read_file("$root/jawn");

# The locker is the local ticket desk, not the guest door.
my $prod_at   = index($president, "elsif (\$config->{'environment'} eq 'production')");
my $locker_at = index($president, 'Starting Pro Locker Server');
ok($prod_at >= 0, 'the production branch is present');
ok($locker_at > $prod_at, 'the locker server is started in the production branch');

# It must not sit behind the mobile-only skip that removed the tty servers:
# the app opens .shots/ticket.txt on this port, and JawnFirstRun waits for it.
my $before = $locker_at > $prod_at ? substr($president, $prod_at, $locker_at - $prod_at) : '';
unlike($before, qr/\$device\s+ne\s+'mobile'/, 'the locker is not skipped on a handheld');

# The forever ticket is minted on that port, so it is the desk the app opens.
like($ticket, qr/\$ENV\{PORT_DOCK\}/, 'the forever ticket is minted on the dock port');
like($ticket, qr/config->\{'port'\}/, 'the dock port comes from config.json');

# Both listeners are required: the master watchdog must recover a dead ticket
# desk as well as a dead manager.
like($master, qr/foreach my \$key \( 'port', 'working_port' \)/,
	'the watchdog asks the dock and the manager');

done_testing();
