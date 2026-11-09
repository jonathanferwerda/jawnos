# tests-for: lib/JawnOS/Transport.pm perl/control.pl lib/JawnOS/LogBus.pm
# covers:    the base/token files, the port offsets, the token comparison and
#            real loopback round trips for the control and log clients.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use JSON::PP ();
use POSIX ();
use JawnOS::Transport;

my $dir = tempdir(CLEANUP => 1);
local $ENV{'HOME'} = $dir;
local $ENV{'JAWNOS_DATA_DIR'} = "$dir/data";
local $ENV{'JAWNOS_TRANSPORT'} = 'tcp';
local $ENV{'JAWNOS_TRANSPORT_BASE'} = '';
local $ENV{'JAWNOS_TRANSPORT_TOKEN'} = '';

ok(JawnOS::Transport::tcp(), 'TCP mode is selected');
is(JawnOS::Transport::set_base(45100), 1, 'the base is written');
is(JawnOS::Transport::base(), 45100, 'the base reads back');
is(JawnOS::Transport::port_for('control'), 45107, 'control is base + 7');
is(JawnOS::Transport::port_for('log'), 45108, 'log is base + 8');
is(JawnOS::Transport::port_for('watch'), 45109, 'watch is base + 9');
is(JawnOS::Transport::port_for('alarm'), 45110, 'alarm is base + 10');
is(JawnOS::Transport::port_for('memory'), 45111, 'memory is base + 11');
is(JawnOS::Transport::port_for('ws'), 45112, 'ws is base + 12');
is(JawnOS::Transport::port_for('mailws'), 45113, 'mailws is base + 13');
is(JawnOS::Transport::port_for('tree'), 45114, 'tree is base + 14');
is(JawnOS::Transport::path_for('watch'), "$dir/.process_watch", 'the watch path is the master path');
is(JawnOS::Transport::path_for('control'), "$dir/data/control", 'the control path is under the data dir');
is(JawnOS::Transport::path_for('alarm'), "$dir/data/alarm", 'the alarm path is under the data dir');
is(JawnOS::Transport::path_for('memory'), "$dir/data/memory", 'the memory path is under the data dir');
is(JawnOS::Transport::path_for('ws'), "$dir/data/ws", 'the ws folder is under the data dir');
is(JawnOS::Transport::path_for('tree'), "$dir/data/tree", 'the tree path is under the data dir');

is(JawnOS::Transport::kind_for_path("$dir/data/memory"), 'memory', 'a memory path names memory');
is(JawnOS::Transport::kind_for_path("$dir/data/alarm"), 'alarm', 'an alarm path names alarm');
is(JawnOS::Transport::kind_for_path("$dir/.process_watch"), 'watch', 'a watch path names watch');
is(JawnOS::Transport::kind_for_path("$dir/ws/music"), 'ws', 'a per-app path names the shared ws port');
is(JawnOS::Transport::kind_for_path("$dir/ws/mailws"), 'mailws', 'the mail path is its own kind, not an app');
is(JawnOS::Transport::kind_for_path("$dir/data/tree"), 'tree', 'a tree path names the stop channel');
is(JawnOS::Transport::kind_for_path("$dir/ws/tree"), 'ws', 'an app named tree still names the ws port');
is(JawnOS::Transport::kind_for_path("C:\\tmp\\ws\\tab"), 'ws', 'a Windows path is recognised too');
is(JawnOS::Transport::kind_for_path("$dir/data/control"), undef, 'a foreign path has no kind');
is(JawnOS::Transport::kind_for_path(undef), undef, 'no path has no kind');
is(JawnOS::Transport::set_base(70000), 0, 'an out-of-range base is refused');
is(JawnOS::Transport::set_base(65521), 1, 'a base that leaves room for the last offset is accepted');
is(JawnOS::Transport::set_base(65522), 0, 'a base that overflows the last offset is refused');
JawnOS::Transport::set_base(45100);
is(JawnOS::Transport::port_for('bogus'), undef, 'an unknown kind has no port');

ok(JawnOS::Transport::write_token('secret'), 'the token is written');
is(JawnOS::Transport::token(), 'secret', 'the token reads back');
ok(JawnOS::Transport::token_ok('secret'), 'the right token passes');
ok(!JawnOS::Transport::token_ok('wrong!'), 'the wrong token fails');
ok(!JawnOS::Transport::token_ok(''), 'an empty token fails');
ok(!JawnOS::Transport::token_ok(undef), 'a missing token fails');

my $args = JawnOS::Transport::server_args('control');
is($args->{'address'}, '127.0.0.1', 'the TCP server binds loopback');
is($args->{'port'}, 45107, 'the TCP server uses the control port');

{
	local $ENV{'JAWNOS_TRANSPORT'} = 'unix';
	my $path_args = JawnOS::Transport::server_args('control');
	is($path_args->{'path'}, "$dir/data/control", 'native mode keeps the UNIX path');
	my $ws_args = JawnOS::Transport::server_args('ws', path => "$dir/ws/music");
	is($ws_args->{'path'}, "$dir/ws/music", 'native ws keeps the per-app path');
	ok(!JawnOS::Transport::tcp(), 'native mode is not TCP');
}

require "$FindBin::Bin/../perl/control.pl";
require "$FindBin::Bin/../lib/JawnOS/LogBus.pm";

my $wrong = control::handle(JSON::PP->new->encode({ cmd => 'status', token => 'wrong' }),
	{ transport => 'tcp' });
is($wrong->{'reply'}{'error'}, 'unauthorized', 'the control handler refuses a wrong token');
my $right = control::handle(JSON::PP->new->encode({ cmd => 'status', token => 'secret' }),
	{ transport => 'tcp', status => 'good', pid => $$, version => 'v-test' });
is($right->{'reply'}{'ok'}, 1, 'the control handler accepts the right token');

SKIP: {
	skip 'fork is not available on this platform', 6 if $^O eq 'MSWin32' || !$Config::Config{'d_fork'};

	# Control round trip: the client must put the token on the wire.
	my $listener = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
		Listen => 5, ReuseAddr => 1,
	);
	ok($listener, 'a loopback control listener is bound');
	my $control_port = $listener->sockport;
	my $base = $control_port - 7;
	JawnOS::Transport::set_base($base);
	JawnOS::Transport::write_token('secret');

	my $child = fork();
	if (defined $child && $child == 0) {
		my $client = $listener->accept;
		my $line = <$client>;
		my $req = JSON::PP->new->decode($line // '{}');
		print $client JSON::PP->new->encode({
			ok => 1,
			cmd => $req->{'cmd'} // '',
			seen_token => $req->{'token'} // '',
		}) . "\n";
		close $client;
		POSIX::_exit(0);
	}
	my $reply = control::send({ cmd => 'status' }, timeout => 5);
	is($reply->{'ok'}, 1, 'the control client gets the reply');
	is($reply->{'seen_token'}, 'secret', 'the control client sent the token');
	waitpid($child, 0);
	close $listener;

	# Log round trip: the client must put the token on the wire and read bytes.
	my $log_listener = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
		Listen => 5, ReuseAddr => 1,
	);
	my $log_port = $log_listener->sockport;
	JawnOS::Transport::set_base($log_port - 8);
	JawnOS::Transport::write_token('secret');

	my $log_child = fork();
	if (defined $log_child && $log_child == 0) {
		my $client = $log_listener->accept;
		my $line = <$client>;
		my $req = JSON::PP->new->decode($line // '{}');
		my $ok = ($req->{'token'} // '') eq 'secret';
		print $client JSON::PP->new->encode({
			from => 0, to => 3, earliest => 0, total => 3,
			dropped => 0, reset => 0, bytes => 3,
			authorized => $ok ? 1 : 0,
		}) . "\n";
		print $client 'abc';
		close $client;
		POSIX::_exit(0);
	}
	my $log = JawnOS::LogBus::client_read("$dir/data/log", 0, 10, 3);
	ok($log, 'the log client gets a reply');
	is($log->{'bytes'}, 'abc', 'the log client gets the body');
	waitpid($log_child, 0);
	close $log_listener;
}

done_testing();
