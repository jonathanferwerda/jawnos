# tests-for: jawn perl/Manager.pl perl/control.pl scripts/restart.pl lib/JawnOS/Transport.pm
# covers:    The master's control socket: one JSON line in, one JSON line out, so a caller learns what happened to a restar...

use strict;
use warnings;

use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use POSIX qw(WNOHANG);
use Test::More;

# The master's control socket: one JSON line in, one JSON line out, so a caller
# learns what happened to a restart instead of writing a word into a file and
# hoping. ./jawn owns the socket plumbing (Mojo::IOLoop), so what is pinned here
# is the part both ends share - the request/verdict mapping in perl/control.pl,
# the record every restart leaves behind, and the client scripts/restart.pl uses.
# A regression here is a restart request nobody can interpret.

require File::Spec->rel2abs("$FindBin::Bin/../perl/control.pl");

# ------------------------------------------------------------ status_reason
# The status file said exactly "restart" for years, so that must keep working;
# anything after it is the reason the caller gave.
is_deeply([ &control::status_reason('restart') ],        [ 1, '' ],           'a bare restart is still a restart');
is_deeply([ &control::status_reason("restart\n") ],      [ 1, '' ],           'trailing whitespace is not a reason');
is_deeply([ &control::status_reason('restart: pulled code from a peer') ],
	[ 1, 'pulled code from a peer' ], 'a colon carries the reason');
is_deeply([ &control::status_reason('restart - the update installed') ],
	[ 1, 'the update installed' ], 'a dash carries the reason');
is_deeply([ &control::status_reason('good') ],   [ 0, '' ], 'good is not a restart');
is_deeply([ &control::status_reason('frozen') ], [ 0, '' ], 'frozen is not a restart');
is_deeply([ &control::status_reason('') ],       [ 0, '' ], 'an empty file is not a restart');
is_deeply([ &control::status_reason('restarted') ], [ 0, '' ], 'a longer word is not the command');

# ------------------------------------------------------------------ clean_text
my $messy = &control::clean_text("line one\nline two\t\tthree  ", 400);
is($messy, 'line one line two three', 'a reason is flattened to one line');
my $long = &control::clean_text('x' x 40, 10);
is($long, ('x' x 10) . '...', 'a long reason is capped and marked');
is(&control::clean_text(undef), '', 'undef reads as empty');
is(&control::clean_text({ not => 'text' }), '', 'a reference is not text');

# --------------------------------------------------------------------- handle
my $ctx = {
	status => 'started',
	pid => 4242,
	version => '0.1.1732',
	why => '',
	pending => 0,
	last => { reason => 'the last one', source => 'agent' },
	verify => sub { { ok => 1, summary => '745 file(s) pass (base HEAD)' } },
};

my $answer = &control::handle('{"cmd":"status"}', $ctx);
is($answer->{'reply'}->{'status'}, 'started', 'status reports what the master is doing');
is($answer->{'reply'}->{'pid'}, 4242, 'and which master is doing it');
is($answer->{'reply'}->{'version'}, '0.1.1732', 'and the version it runs');
is($answer->{'reply'}->{'last_restart'}->{'reason'}, 'the last one', 'and why the last restart happened');
ok(!$answer->{'action'}, 'status asks for no action');

$answer = &control::handle('{"cmd":"verify"}', $ctx);
is($answer->{'reply'}->{'verified'}, 1, 'verify runs the guard and reports it passed');
like($answer->{'reply'}->{'verify'}, qr/745 file/, 'and quotes its summary');

my $bad_ctx = { %$ctx, verify => sub { { ok => 0, report => 'FAIL perl/Manager.pl' } } };
$answer = &control::handle('{"cmd":"verify"}', $bad_ctx);
is($answer->{'reply'}->{'ok'}, 0, 'verify reports a broken tree');
like($answer->{'reply'}->{'report'}, qr/perl\/Manager\.pl/, 'and names the file');

$answer = &control::handle('{"cmd":"restart","reason":"v0.1.1740 - the fix","source":"agent","pid":99}', $ctx);
is($answer->{'action'}, 'restart', 'a restart is an action, not an immediate reply');
is($answer->{'reason'}, 'v0.1.1740 - the fix', 'the reason is carried');
is($answer->{'source'}, 'agent', 'and who asked');
is($answer->{'requested_by'}, 99, 'and the caller pid');
ok(!$answer->{'reply'}, 'no verdict is invented before the guard runs');

$answer = &control::handle('{"cmd":"restart"}', $ctx);
is($answer->{'reason'}, 'asked over the control socket', 'a missing reason still gives one');
is($answer->{'source'}, 'control-socket', 'and a source');

$answer = &control::handle('{"cmd":"restart","reason":"line one\nline two"}', $ctx);
is($answer->{'reason'}, 'line one line two', 'a pasted multiline reason cannot break the protocol');

$answer = &control::handle('{"cmd":"frobnicate"}', $ctx);
is($answer->{'reply'}->{'error'}, 'unknown-command', 'an unknown command is refused by name');

$answer = &control::handle('not json at all', $ctx);
is($answer->{'reply'}->{'error'}, 'bad-request', 'garbage is refused as such');

$answer = &control::handle('{"cmd":"status"}', { %$ctx, status => 'frozen', why => 'the tree exited on its own' });
is($answer->{'reply'}->{'why'}, 'the tree exited on its own', 'status explains why a frozen tree is frozen');

# -------------------------------------------------------------- restart_reply
my $accept = &control::restart_reply({
	proof => { ok => 1, summary => '745 file(s) pass (base HEAD)' },
	reason => 'the fix', source => 'agent', version => '0.1.1732', pid => 7,
	status_before => 'started',
});
is($accept->{'ok'}, 1, 'an accepted restart answers ok');
is($accept->{'accepted'}, 1, 'and says it was accepted');
is($accept->{'verified'}, 1, 'and that the guard ran');
like($accept->{'verify'}, qr/745 file/, 'quoting the guard summary');
is($accept->{'reason'}, 'the fix', 'with the reason it will be remembered by');

my $refuse = &control::restart_reply({
	proof => { ok => 0, report => "FAIL perl/Manager.pl\n        perl -c: syntax error" },
	reason => 'the fix', source => 'agent', pid => 7,
});
is($refuse->{'ok'}, 0, 'a refused restart is not ok');
is($refuse->{'refused'}, 'verify', 'it says the guard refused');
like($refuse->{'report'}, qr/syntax error/, 'and carries the report to fix');
like($refuse->{'report'}, qr/^FAIL perl\/Manager\.pl perl -c/, 'flattened to one line');

my $frozen = &control::restart_reply({
	proof => { ok => 1, skipped => 'not verified: the tree was already down' },
	reason => 'the tree exited on its own', source => 'master-watchdog',
});
is($frozen->{'accepted'}, 1, 'a down tree is restarted');
is($frozen->{'verified'}, 0, 'without pretending the guard ran');
like($frozen->{'verify'}, qr/already down/, 'and saying why');

# ------------------------------------------------------------------- the record
my $dir = tempdir(CLEANUP => 1);
ok(&control::write_record({ reason => 'a test restart', source => 'unit', ok => 1 }, dir => $dir),
	'the record is written');
my $record = &control::read_record(dir => $dir);
is($record->{'reason'}, 'a test restart', 'and reads back with its reason');
is($record->{'source'}, 'unit', 'and its source');
like($record->{'at'} || '', qr/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/, 'and a timestamp');
ok(($record->{'epoch'} || 0) > 1_600_000_000, 'and an epoch a machine can sort on');
ok(-f "$dir/restart.log", 'every restart also lands in the history log');
my @lines = do { open(my $fh, '<', "$dir/restart.log") or die $!; <$fh> };
is(scalar @lines, 1, 'the log has one line per restart');

&control::write_record({ reason => 'a second restart', source => 'unit', ok => 0 }, dir => $dir);
@lines = do { open(my $fh, '<', "$dir/restart.log") or die $!; <$fh> };
is(scalar @lines, 2, 'and appends, rather than forgetting the first');
is(&control::read_record(dir => $dir)->{'reason'}, 'a second restart',
	'while restart.json is always the latest');

# the log is rotated by size so a long-lived house does not keep one growing file
open(my $big, '>', "$dir/restart.log") or die $!;
print $big 'x' x 300_000;
close $big;
&control::write_record({ reason => 'after the rotation', source => 'unit', ok => 1 }, dir => $dir);
ok(-f "$dir/restart.log.1", 'a full log is rotated aside');
is(scalar(() = do { open(my $fh, '<', "$dir/restart.log") or die $!; <$fh> }), 1,
	'and the new log starts clean');

is(&control::read_record(dir => "$dir/nothing-here"), undef, 'no record reads as undef, not as an error');

# -------------------------------------------------------------------- the client
# A stand-in master: accept once, read one line, answer with a canned reply.
sub fake_master {
	my ($path, $reply, %opt) = @_;
	my $pid = fork();
	die "fork: $!" unless defined $pid;
	if (!$pid) {
		require IO::Socket::UNIX;
		require IO::Select;
		my $server = IO::Socket::UNIX->new(Local => $path, Listen => 5) or exit 1;
		# accept() has no timeout of its own. A parent that never connects would
		# leave this child listening forever and its waitpid would wait with it -
		# that pair hung a loaded 8-job run for minutes, with nothing failed and
		# nothing printed. Bound the wait so a lost race fails a test instead.
		my $select = IO::Select->new($server);
		my $client = $select->can_read(15) ? $server->accept : undef;
		exit 2 unless $client;
		my $request = <$client>;
		if (defined $request && length $request) {
			print $client $reply, "\n" if defined $reply;
		}
		close $client;
		close $server;
		exit 0;
	}
	# wait for the child to bind before connecting, or the parent loses the race
	# and connects to a socket that is not there yet. The bound is generous: a
	# fork plus a bind under a loaded 8-job run is not instant, and a 5s bound
	# produced a rare "no-master" here that had nothing to do with the client.
	my $bound_by = time + 20;
	sleep 0.01 until -S $path || time > $bound_by;
	ok(-S $path, 'the stand-in master bound its socket') or die "no socket at $path\n";
	return $pid;
}

# Reap the stand-in master without being able to wait forever: a child that is
# still listening gets killed, so this reports a bad reply rather than hanging
# the suite (see the accept note above).
sub reap {
	my ($pid) = @_;
	my $deadline = time + 20;
	while (1) {
		my $got = waitpid($pid, WNOHANG);
		return if $got == $pid || $got == -1;
		last if time > $deadline;
		select undef, undef, undef, 0.02;
	}
	kill 'KILL', $pid;
	waitpid($pid, 0);
}

my $socket = "$dir/control";
my $pid = &fake_master($socket, '{"ok":1,"cmd":"status","status":"started","pid":9}');
my $reply = &control::send({ cmd => 'status' }, socket => $socket, dir => $dir, timeout => 10);
&reap($pid);
is($reply->{'ok'}, 1, 'the client decodes the master answer');
is($reply->{'status'}, 'started', 'and hands back its fields');

unlink $socket;
$pid = &fake_master($socket, undef);   # accepts, answers nothing, hangs up
$reply = &control::send({ cmd => 'restart' }, socket => $socket, dir => $dir, timeout => 2);
&reap($pid);
is($reply->{'error'}, 'timeout', 'a master that never answers reads as a timeout, not a crash');

unlink $socket;
$reply = &control::send({ cmd => 'restart' }, socket => "$dir/absent", dir => $dir, timeout => 2);
is($reply->{'error'}, 'no-master', 'no socket reads as no master, by name');
like($reply->{'message'}, qr/no jawn master/, 'with a message a person can act on');

# A restart with no reason still has one to match: the wording the master
# substitutes for a request over the socket. That is what keeps a caller from
# reading another restart's record as its own answer.
unlink $socket;
&control::write_record({ ok => 1, reason => 'asked over the control socket', source => 'scripts/restart.pl' }, dir => $dir);
my $no_reason_pid = &fake_master_frames($socket, []);
my $no_reason = &control::send({ cmd => 'restart' }, socket => $socket, dir => $dir, timeout => 2);
&reap($no_reason_pid);
is($no_reason->{'from'}, 'record', 'a reasonless restart is matched by the socket wording');

# --------------------------------------------------------------- the tree stop
# The tree serves ~/.president/tree so a Windows master - which cannot signal a
# child - can ask it to leave. The mapping is pure, like control::handle.
my $stop = &control::tree_handle('{"cmd":"stop","reason":"the master is restarting"}', $ctx);
is($stop->{'action'}, 'stop', 'a stop request is an action the tree performs');
is($stop->{'reason'}, 'the master is restarting', 'with the reason it was given');

$stop = &control::tree_handle('{"cmd":"stop"}', $ctx);
is($stop->{'reason'}, 'asked over the tree control socket', 'a bare stop still has a reason');

$stop = &control::tree_handle('{"cmd":"status"}', { %$ctx, status => 'running' });
is($stop->{'reply'}->{'cmd'}, 'status', 'tree status is answered directly');
is($stop->{'reply'}->{'version'}, '0.1.1732', 'with the version it runs');

$stop = &control::tree_handle('{"cmd":"frobnicate"}', $ctx);
is($stop->{'reply'}->{'error'}, 'unknown-command', 'an unknown tree command is refused by name');

$stop = &control::tree_handle('not json', $ctx);
is($stop->{'reply'}->{'error'}, 'bad-request', 'garbage is refused as such');

# A TCP tree must present the boot token, exactly as the master's own socket
# does. JAWNOS_DATA_DIR keeps the live token file out of the test.
{
	local $ENV{'JAWNOS_TRANSPORT'} = 'tcp';
	local $ENV{'JAWNOS_TRANSPORT_TOKEN'} = 'secret';
	local $ENV{'JAWNOS_DATA_DIR'} = $dir;
	my $denied = &control::tree_handle('{"cmd":"status"}', { transport => 'tcp' });
	is($denied->{'reply'}->{'error'}, 'unauthorized', 'a TCP stop without the token is refused');
	my $allowed = &control::tree_handle('{"cmd":"status","token":"secret"}', { transport => 'tcp' });
	is($allowed->{'reply'}->{'ok'}, 1, 'and the boot token lets it through');
}

# The master's client end: delivered is not the same as stopped.
unlink $socket;
my $tree_pid = &fake_master($socket, '{"ok":1,"cmd":"stop"}');
my $asked = &control::ask_tree_stop(socket => $socket, timeout => 5, reason => 'a test');
&reap($tree_pid);
ok($asked, 'the master can ask the tree to stop over its channel');

ok(!&control::ask_tree_stop(socket => "$dir/absent", timeout => 1),
	'and a missing tree is reported as not asked, not as a crash');

# ------------------------------------------------- the client's own @INC
# Windows has no getpwuid - the call dies rather than returning nothing - and a
# service or scheduled task has no HOME. The BEGIN that seeds local::lib into
# @INC used to call getpwuid unguarded, so scripts/restart.pl aborted before it
# could ask the master anything. Order it like the platform module and guard the
# last answer.
{
	my $restart;
	open(my $fh, '<', "$FindBin::Bin/../scripts/restart.pl") or die $!;
	{ local $/; $restart = <$fh> }
	close $fh;
	my ($begin) = $restart =~ /(BEGIN \{.*?\n\})/s;
	ok($begin, 'scripts/restart.pl still seeds @INC in BEGIN');
	like($begin, qr/\$ENV\{USERPROFILE\}/, 'the Windows home is consulted');
	like($begin, qr/\$ENV\{HOMEDRIVE\}[\s\S]*\$ENV\{HOMEPATH\}/,
		'then the older HOMEDRIVE+HOMEPATH pair');
	like($begin, qr/eval \{ \(getpwuid \$<\)\[7\] \}/,
		'and getpwuid only inside an eval');
	# Comments may name it; only a call counts.
	(my $code = $begin) =~ s/^\s*#.*$//mg;
	$code =~ s/eval \{ \(getpwuid \$<\)\[7\] \}/eval/;
	unlike($code, qr/getpwuid/, 'no unguarded getpwuid call is left');

	# It must not die before doing anything when HOME is absent: this is the
	# launch shape a Windows service or a coded agent's shell has.
	{
		local %ENV = %ENV;
		delete @ENV{qw(HOME HOMEDRIVE HOMEPATH)};
		$ENV{'USERPROFILE'} = $dir;
		my $out = `$^X -c "$FindBin::Bin/../scripts/restart.pl" 2>&1`;
		is($?, 0, 'restart.pl compiles with no HOME (USERPROFILE fallback)') or diag($out);
	}
}

# ---------------------------------------------- the master's TCP listener
# Strawberry's sockets are inheritable and CreateProcess runs with
# bInheritHandles=1 for the runner's socket, so a tree started by a restart
# inherited the master's private listeners and the parent's poll went deaf after
# the second swap. Windows clears HANDLE_FLAG_INHERIT instead of the CLOEXEC
# fcntl (Strawberry's Fcntl has no F_SETFD macro at all).
{
	my $master;
	open(my $fh, '<', "$FindBin::Bin/../jawn") or die $!;
	{ local $/; $master = <$fh> }
	close $fh;
	my ($tcp) = $master =~ /(sub private_tcp_listener \{.*?\n\})/s;
	ok($tcp, 'the master has private_tcp_listener');
	like($tcp, qr/fcntl\(\$handle, F_SETFD, FD_CLOEXEC\) if \$\^O ne 'MSWin32';/,
		'the Unix fcntl CLOEXEC path is kept for every other platform');
	like($tcp, qr/if \(\$\^O eq 'MSWin32'\) \{.*?require Win32API::File;.*?SetHandleInformation\(\$os, 1, 0\);.*?\};/s,
		'on Windows the listener clears HANDLE_FLAG_INHERIT via SetHandleInformation');
	like($tcp, qr/Win32API::File::FdGetOsFHandle\(fileno \$handle\)/,
		'from the listener handle\'s own OS handle');
	my ($cleared) = $tcp =~ /(if \(\$\^O eq 'MSWin32'\) \{.*?\n\t\})/s;
	ok($cleared && $cleared =~ /eval \{/, 'and the binding is wrapped in eval, never fatal');
	ok($cleared && $cleared =~ /could not be made private/,
		'and a listener that could not be made private is said out loud');
	unlike($tcp, qr/fcntl\(\$handle, F_SETFD, FD_CLOEXEC\);\n/,
		'and no unguarded Fcntl call remains');
	my ($unix) = $master =~ /(sub private_unix_listener \{.*?\n\})/s;
	like($unix, qr/fcntl\(\$handle, F_SETFD, FD_CLOEXEC\);\n/,
		'Unix sockets still clear CLOEXEC');
}

# ------------------------------------------ the control stream waits for the verdict
# A restart is answered when its guard lands, and the guard takes minutes. Mojo's
# default 15s idle timeout closed the accepted stream first, so a pending restart
# could never carry its verdict back to the caller. The client bounds the wait
# itself (scripts/restart.pl --timeout), so only the control callback drops it.
# The log socket and the process watch keep their timeouts: they are not asked to
# wait on a sweep.
{
	my $master;
	open(my $fh, '<', "$FindBin::Bin/../jawn") or die $!;
	{ local $/; $master = <$fh> }
	close $fh;

	my ($control) = $master =~ /(sub control_socket\(\).*?\n\})/s;
	ok($control, 'jawn defines control_socket');

	# Up to the read handler: the timeout must be dropped on the accepted stream
	# in the accept callback, not merely mentioned somewhere in the sub.
	my ($accept) = $control =~ /Mojo::IOLoop->server\(\$args => sub \{(.*?)\$stream->on\(read/s;
	ok($accept, 'the control listener has an accept callback');
	like($accept, qr/\$stream->timeout\(0\);/,
		'and drops the idle timeout, so a restart can wait for its guard');

	my ($log) = $master =~ /(sub log_socket\(\).*?\n\})/s;
	ok($log, 'the log socket is present');
	unlike($log, qr/->timeout\(0\)/, 'and keeps Mojo\'s idle timeout');
}

# ------------------------------------------------------- the acknowledgement
# A restart's verdict waits for the guard, which is minutes on a cold tree. The
# master acknowledges the request the moment it is read, on the same connection,
# so a caller that has to give up can say "accepted, still verifying" instead of
# "the master did not answer" - the shape that made a working master look dead.
my $action = &control::handle('{"cmd":"restart","reason":"ack me","pid":7}', $ctx);
ok($action->{'ack'}, 'a restart request is acknowledged as soon as it is read');
is($action->{'ack'}->{'ack'}, 1, 'and the ack is marked as one');
is($action->{'ack'}->{'state'}, 'verifying', 'it says what is running');
is($action->{'ack'}->{'reason'}, 'ack me', 'with the reason it will act on');
is($action->{'ack'}->{'pid'}, 4242, 'and which master took it');
ok(!exists $action->{'ack'}->{'verified'}, 'an ack claims no verdict');
ok(!exists $action->{'ack'}->{'accepted'}, 'and is not an acceptance');
ok(!&control::handle('{"cmd":"status"}', $ctx)->{'ack'}, 'status is answered directly, with no ack');

# ------------------------------------------------------ two frames, one answer
# A stand-in master that accepts one request and writes the given lines back, in
# order, then hangs up. An empty list is a master that read the request and said
# nothing at all.
sub fake_master_frames {
	my ($path, $lines) = @_;
	my $pid = fork();
	die "fork: $!" unless defined $pid;
	if (!$pid) {
		require IO::Socket::UNIX;
		require IO::Select;
		my $server = IO::Socket::UNIX->new(Local => $path, Listen => 5) or exit 1;
		my $select = IO::Select->new($server);
		my $client = $select->can_read(15) ? $server->accept : undef;
		exit 2 unless $client;
		my $request = <$client>;
		if (defined $request && length $request) {
			for my $line (@{ $lines || [] }) { print $client $line, "\n" }
		}
		close $client;
		close $server;
		exit 0;
	}
	my $bound_by = time + 20;
	sleep 0.01 until -S $path || time > $bound_by;
	ok(-S $path, 'the stand-in master bound its socket') or die "no socket at $path\n";
	return $pid;
}

my $ack_line = '{"ok":1,"ack":1,"cmd":"restart","state":"verifying","pending":1,"pid":4242}';

unlink $socket;
my $frames_pid = &fake_master_frames($socket, [ $ack_line,
	'{"ok":1,"cmd":"restart","accepted":1,"verified":1,"reason":"ack me","verify":"745 file(s) pass"}' ]);
my $two = &control::send({ cmd => 'restart', reason => 'ack me' }, socket => $socket, dir => $dir, timeout => 10);
&reap($frames_pid);
is($two->{'accepted'}, 1, 'the verdict is the frame after the ack');
is($two->{'verify'}, '745 file(s) pass', 'and it is returned, not the acknowledgement');
ok(!$two->{'ack'}, 'the ack is not mistaken for the verdict');

# The ack alone: the guard is still sweeping. That is an answer, and it is not
# the same as a master that never read the line.
unlink $socket;
$frames_pid = &fake_master_frames($socket, [ $ack_line ]);
my $still = &control::send({ cmd => 'restart', reason => 'ack me' }, socket => $socket, dir => $dir, timeout => 2);
&reap($frames_pid);
is($still->{'error'}, 'pending', 'an ack with no verdict reads as pending');
is($still->{'ack'}->{'pid'}, 4242, 'naming the master that took the request');
like($still->{'message'}, qr/still verifying/, 'and saying what it is doing');
like($still->{'message'}, qr/restart\.json/, 'and where the verdict will land');

# No frame at all, but the restart did happen: the record the master writes
# before it swaps the tree answers, so a reply lost to a re-exec or a stream
# that stopped being read is not the same as a restart that never happened.
unlink $socket;
&control::write_record({
	ok => 1, reason => 'the reply was lost', source => 'scripts/restart.pl',
	version => '0.1.9999', verify => '744 file(s) pass',
}, dir => $dir);
$frames_pid = &fake_master_frames($socket, []);
my $lost = &control::send({ cmd => 'restart', reason => 'the reply was lost' }, socket => $socket, dir => $dir, timeout => 2);
&reap($frames_pid);
is($lost->{'from'}, 'record', 'a lost reply is answered from the record');
is($lost->{'ok'}, 1, 'with the verdict the master wrote there');
is($lost->{'verify'}, '744 file(s) pass', 'including the guard summary');

# A record that names another restart is not this caller's answer.
unlink $socket;
$frames_pid = &fake_master_frames($socket, []);
my $not_ours = &control::send({ cmd => 'restart', reason => 'a reason no record names' }, socket => $socket, dir => $dir, timeout => 1);
&reap($frames_pid);
is($not_ours->{'error'}, 'timeout', 'another restart\'s record is not read as this one\'s');

# ------------------------------------------------- the status file must not lie
# It is what a person and a script read when nothing else answers, and the tree
# writes `good` for itself at boot: a tree that never came back left a good
# behind it, for hours, with only the master on the box.
is(&control::watch_status(serving => 1), 'good', 'a serving tree reads good');
my $down = &control::watch_status(serving => 0, why => 'the web port stopped answering for ~25s');
is($down, 'frozen: the web port stopped answering for ~25s',
	'a tree that is not serving is named, with the reason');
unlike(&control::watch_status(serving => 0), qr/^good/, 'and never reads good');
is_deeply([ &control::status_reason($down) ], [ 0, '' ],
	'the published value is not read back as a restart request');
is(&control::status_file(dir => $dir), "$dir/status", 'the status file has one home');

my $status = "$dir/status";
ok(&control::publish_status($status, 'frozen: no tree'), 'the master publishes the state');
is(&control::read_text($status), 'frozen: no tree', 'and a reader gets it whole, with no newline');
ok(!&control::publish_status($status, 'frozen: no tree'), 'publishing the same value again changes nothing');
open(my $status_fh, '>', $status) or die $!;
print $status_fh 'restart: an agent asked';
close $status_fh;
ok(!&control::publish_status($status, 'good'), 'a pending restart request is never overwritten');
is(&control::read_text($status), 'restart: an agent asked', 'the request survives the publisher');
open($status_fh, '>', $status) or die $!;
print $status_fh 'frozen: an older failure';
close $status_fh;
ok(&control::publish_status($status, 'good'), 'a plain state is replaced once the tree answers');
is(&control::read_text($status), 'good', 'and the file says so');

# --------------------------------------------- the Windows rendezvous, for real
# On Windows the transport is TCP and a token is mandatory: the client takes the
# port from the base, the secret from ~/.president/transport_token, and the
# master's own handler refuses a request without it. Nothing else in the suite
# runs that client end, so both ends are driven here - the real transport, the
# real client, and control::handle as the master - on a loopback port.
#
# The stand-in master binds port 0 and writes the port it was given: picking a
# base and racing another test to it made this fail on a loaded suite run, and
# the port is the one thing the client must be told rather than guess.
SKIP: {
	require JawnOS::Transport;

	sub tcp_master {
		my (%arg) = @_;
		my $dir = tempdir(CLEANUP => 1);
		my $port_file = "$dir/port";
		if (defined $arg{'file_token'}) {
			open(my $tf, '>', "$dir/transport_token") or die $!;
			print $tf $arg{'file_token'};
			close $tf;
		}
		my $pid = fork();
		die "fork: $!" unless defined $pid;
		if (!$pid) {
			require IO::Socket::INET;
			require IO::Select;
			$ENV{'JAWNOS_DATA_DIR'} = $dir;
			$ENV{'JAWNOS_TRANSPORT_TOKEN'} = $arg{'server_token'}
				if defined $arg{'server_token'};
			my $server = IO::Socket::INET->new(
				LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
				Listen => 5, ReuseAddr => 1,
			) or exit 1;
			open(my $pf, '>', $port_file) or exit 1;
			print $pf $server->sockport;
			close $pf;
			my $select = IO::Select->new($server);
			my $client = $select->can_read(20) ? $server->accept : undef;
			exit 2 unless $client;
			my $line = <$client>;
			if (defined $line && length $line) {
				my $answer = &control::handle($line, {
					transport => 'tcp', status => 'started', pid => $$,
					version => '0.1.9999', pending => 0,
				});
				my $out = $answer->{'reply'} || $answer->{'ack'};
				print $client control::encode_json($out), "\n" if $out;
			}
			close $client;
			close $server;
			exit 0;
		}
		my $bound_by = time + 20;
		my $port = '';
		while (time < $bound_by) {
			if (-s $port_file && open(my $pf, '<', $port_file)) {
				$port = <$pf> // '';
				close $pf;
				last if $port =~ /^\d+$/;
			}
			sleep 0.02;
		}
		return ($pid, $dir, ($port =~ /^(\d+)$/ ? $1 + 0 : 0));
	}

	# The master's end: one request, answered by control::handle with the TCP
	# rules (which is where the token is checked), and the boot secret on disk
	# exactly as the master writes it.
	my ($pid, $tcpdir, $port) = &tcp_master(file_token => 'boot-secret');
	if (!$port) {
		kill 'KILL', $pid;
		waitpid($pid, 0);
		skip 'no loopback port for the TCP round trip', 4;
	}
	else {
		# The transport holds one base; the control port is base + 7. The client
		# is told the base, never the port, which is what the offset table is for.
		my $base = $port - 7;
		{
			local $ENV{'JAWNOS_TRANSPORT'} = 'tcp';
			local $ENV{'JAWNOS_DATA_DIR'} = $tcpdir;
			local $ENV{'JAWNOS_TRANSPORT_BASE'} = $base;
			is(&JawnOS::Transport::port_for('control'), $port,
				'the control port is the base plus its offset');
			my $tcp = &control::send({ cmd => 'status' }, timeout => 10);
			&reap($pid);
			is($tcp->{'status'}, 'started', 'the TCP client reaches the master with the boot token');
			is($tcp->{'version'}, '0.1.9999', 'and the answer comes back decoded');
		}
	}

	# The same request with the wrong secret is refused by name - so the token is
	# actually on the wire and actually checked, which is the whole Windows path.
	my ($refuse_pid, $refuse_dir, $refuse_port) = &tcp_master(server_token => 'master-secret');
	if (!$refuse_port) {
		kill 'KILL', $refuse_pid;
		waitpid($refuse_pid, 0);
		skip 'no loopback port for the refusal test', 1;
	}
	else {
		{
			local $ENV{'JAWNOS_TRANSPORT'} = 'tcp';
			local $ENV{'JAWNOS_DATA_DIR'} = $refuse_dir;
			local $ENV{'JAWNOS_TRANSPORT_BASE'} = $refuse_port - 7;
			local $ENV{'JAWNOS_TRANSPORT_TOKEN'} = 'wrong-one';
			my $tcp = &control::send({ cmd => 'status' }, timeout => 10);
			&reap($refuse_pid);
			is($tcp->{'error'}, 'unauthorized', 'a request without the boot token is refused by name');
		}
	}
}

 done_testing();
