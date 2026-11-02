# tests-for: jawn perl/Manager.pl perl/control.pl scripts/restart.pl
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
	# and connects to a socket that is not there yet
	my $bound_by = time + 5;
	sleep 0.01 until -S $path || time > $bound_by;
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
my $reply = &control::send({ cmd => 'status' }, socket => $socket, timeout => 10);
&reap($pid);
is($reply->{'ok'}, 1, 'the client decodes the master answer');
is($reply->{'status'}, 'started', 'and hands back its fields');

unlink $socket;
$pid = &fake_master($socket, undef);   # accepts, answers nothing, hangs up
$reply = &control::send({ cmd => 'restart' }, socket => $socket, timeout => 2);
&reap($pid);
is($reply->{'error'}, 'timeout', 'a master that never answers reads as a timeout, not a crash');

unlink $socket;
$reply = &control::send({ cmd => 'restart' }, socket => "$dir/absent", timeout => 2);
is($reply->{'error'}, 'no-master', 'no socket reads as no master, by name');
like($reply->{'message'}, qr/no jawn master/, 'with a message a person can act on');

done_testing();
