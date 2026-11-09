# tests-for: jawn perl/control.pl perl/Websocket.pl perl/Alarm.pl perl/President.pl lib/JawnOS/LogBus.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Devicews.pm lib/JawnOS/Domain/Process.pm lib/JawnOS/Manager/Core2_worker_boot.pm lib/JawnOS/Controller/manager_ws.pm lib/JawnOS/Sco/Client.pm lib/JawnOS/Transport.pm
# covers:    the master's listeners and every client go through the transport
#            module, the token is part of each wire, and no source file imports
#            IO::Socket::UNIX at compile time.

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
my $websocket = read_file("$FindBin::Bin/../perl/Websocket.pl");
my $alarm = read_file("$FindBin::Bin/../perl/Alarm.pl");
my $president = read_file("$FindBin::Bin/../perl/President.pl");
my $core2 = read_file("$FindBin::Bin/../lib/JawnOS/Manager/Core2_worker_boot.pm");
my $manager_ws = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_ws.pm");
my $devicews = read_file("$FindBin::Bin/../lib/JawnOS/Domain/Devicews.pm");
my $sco = read_file("$FindBin::Bin/../lib/JawnOS/Sco/Client.pm");

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
like($calendar, qr/client_socket\(\$kind/, 'the watch sender asks the transport for the kind it read');
like($calendar, qr/token => JawnOS::Transport::token\(\)/, 'the watch record carries the token');

like($process, qr/JawnOS::Transport::tcp/, 'the process heartbeat knows the transport');

like($websocket, qr/\$wsm->\{'token'\} = JawnOS::Transport::token\(\)/, 'the ws frame carries the token');
like($websocket, qr/unix_socket_sender\(\$file,\$wsm\)/, 'the ws sender no longer gates on a file existing');
like($websocket, qr/\$msg->\{'token'\} = JawnOS::Transport::token/, 'the mail frame carries the token');

like($alarm, qr/server_args\('alarm'/, 'the alarm listener asks the transport');
like($alarm, qr/token_ok\(\$appt->\{'__transport_token'\}\)/, 'the alarm listener checks the token');

like($president, qr/server_args\('memory'/, 'the memory listener asks the transport');
like($president, qr/token_ok\(\$query->\{'token'\}\)/, 'the memory listener checks the token');

like($core2, qr/server_args\('ws'/, 'the ws listener asks the transport');
like($core2, qr/server_args\('mailws'/, 'the mailws listener asks the transport');
like($core2, qr/sub ws_server_ensure/, 'one accessor owns the per-app or shared ws listener');
like($core2, qr/token_ok\(\$wsm->\{'token'\}\)/, 'the ws listener checks the token');
like($core2, qr/token_ok\(\$m->\{'token'\}\)/, 'the mailws listener checks the token');

like($manager_ws, qr/ws_server_ensure\(\$app\)/, 'the route asks the accessor, not the binder');
like($devicews, qr/JawnOS::Transport::tcp/, 'the device bus knows the transport');
like($calendar, qr/client_socket\('alarm'/, 'the alarm poke asks the transport');
like($calendar, qr/kind_for_path/, 'the sender reads its kind back from the path');

like($sco, qr/^use Socket qw\(SOCK_STREAM\);/m, 'the SCO client gets its socket type from Socket');
like($sco, qr/require IO::Socket::UNIX;/, 'the SCO client loads the UNIX module only when it dials one');

foreach my $pair (
	[ 'Websocket.pl' => $websocket ],
	[ 'Alarm.pl' => $alarm ],
	[ 'President.pl' => $president ],
	[ 'Core2_worker_boot.pm' => $core2 ],
	[ 'manager_ws.pm' => $manager_ws ],
	[ 'Sco/Client.pm' => $sco ],
) {
	unlike($pair->[1], qr/^use IO::Socket::UNIX;/m, $pair->[0] . ' does not import IO::Socket::UNIX at compile time');
}

done_testing();
