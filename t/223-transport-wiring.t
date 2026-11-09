# tests-for: jawn perl/control.pl lib/JawnOS/LogBus.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Process.pm lib/JawnOS/Transport.pm
# covers:    the master's three listeners and the four clients all go through
#            the transport module, and the token is part of each wire.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Slurp qw(read_file);

my $master  = read_file("$FindBin::Bin/../jawn");
my $control = read_file("$FindBin::Bin/../perl/control.pl");
my $logbus  = read_file("$FindBin::Bin/../lib/JawnOS/LogBus.pm");
my $calendar = read_file("$FindBin::Bin/../lib/JawnOS/Domain/Calendar.pm");
my $process = read_file("$FindBin::Bin/../lib/JawnOS/Domain/Process.pm");

like($master, qr/^use JawnOS::Transport;/m, 'the master loads the transport module');
like($master, qr/server_args\('control'\)/, 'the control listener asks the transport');
like($master, qr/server_args\('log'\)/, 'the log listener asks the transport');
like($master, qr/server_args\('watch'\)/, 'the watch listener asks the transport');
like($master, qr/token_ok\(\$req->\{'token'\}\)/, 'the log listener checks the token');
like($master, qr/token_ok\(\$process->\{'token'\}\)/, 'the watch listener checks the token');
like($master, qr/transport => \(\$tcp \? 'tcp' : 'unix'\)/, 'the control handler sees the transport');
like($master, qr/transport_token transport_base/, 'a wipe keeps the rendezvous files');

like($control, qr/JawnOS::Transport::token_ok/, 'the control handler checks the token');
like($control, qr/client_socket\('control'/, 'the control client asks the transport');
like($control, qr/JawnOS::Transport::token/, 'the control client carries the token');

like($logbus, qr/client_socket\('log'/, 'the log client asks the transport');
like($logbus, qr/JawnOS::Transport::token\(\)/, 'the log client carries the token');

like($calendar, qr/JawnOS::Transport::tcp/, 'the watch sender knows the transport');
like($calendar, qr/client_socket\('watch'/, 'the watch sender asks the transport');
like($calendar, qr/token => JawnOS::Transport::token\(\)/, 'the watch record carries the token');

like($process, qr/JawnOS::Transport::tcp/, 'the process heartbeat knows the transport');

done_testing();
