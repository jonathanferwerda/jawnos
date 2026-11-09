# tests-for: perl/President.pl jawn lib/JawnOS/Platform.pm
# covers:    the two entry points consult the platform module: no threads, a
#            Daemon instead of Prefork in portable mode, and a pipe instead of
#            a pty for the master's tree runner. The choice itself is exercised
#            in t/219; this pins the wiring that cannot be booted in a test.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Slurp qw(read_file);

my $president = read_file("$FindBin::Bin/../perl/President.pl");
my $master    = read_file("$FindBin::Bin/../jawn");

unlike($president, qr/^use threads\b/m, 'the tree no longer loads threads');
unlike($president, qr/threads->create/, 'no browser-open thread remains');

like($president, qr/^require '\.\/lib\/JawnOS\/Platform\.pm';/m,
	'President loads the platform module');
like($president, qr/^sub run_server\b/m, 'the server chooser exists');
like($president, qr/JawnOS::Platform::portable\(\)/,
	'the chooser consults portable mode');
like($president, qr/Mojo::Server::Daemon->new\(listen => \$listeners\)/,
	'portable mode uses a single Daemon');
like($president, qr/Mojo::Server::Prefork->new\(listen => \$listeners\)/,
	'native mode keeps Prefork');
like($president, qr/^sub run_dev_server\b/m, 'development has the same choice');

like($master, qr/^require '\.\/lib\/JawnOS\/Platform\.pm';/m,
	'the master loads the platform module');
like($master, qr/type => 'pipe'/, 'the master can run the tree on a pipe');
like($master, qr/type => 'pty'/, 'the master still uses a pty when native');

done_testing();
