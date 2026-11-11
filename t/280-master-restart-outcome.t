# tests-for: jawn perl/control.pl scripts/restart.pl
# covers:    A Windows restart connected to the master and got no answer, and the
#            watchdog's own restart could leave the master alone with no tree and
#            a status file that still said good. The protocol now acknowledges a
#            request before the guard sweeps and answers from the record when the
#            reply is lost; the master publishes the truth, catches a spawn that
#            dies, retries a boot a bounded number of times and names the failure
#            in the record before it stands down.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use JawnOSTest;

require File::Spec->rel2abs("$FindBin::Bin/../perl/control.pl");

my $root = root();

sub read_source {
	my ($rel) = @_;
	open(my $fh, '<', "$root/$rel") or die "read $rel: $!\n";
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

sub codes_only {
	my ($text) = @_;
	$text =~ s/^\s*#.*$//mg;
	$text =~ s/\s+#[^\n]*$//mg;
	return $text;
}

my $master  = read_source('jawn');
my $restart = read_source('scripts/restart.pl');
my $dir     = tempdir(CLEANUP => 1);

# ------------------------------------------------- the ack is not a verdict
# The master's first frame says the request arrived; the verdict is the second.
# A caller that treated the ack as an answer would report a restart as accepted
# (or verified) before the guard had judged anything.
my $ack = &control::ack_reply({
	reason => 'v0.1.9999 - the fix', source => 'scripts/restart.pl',
	pid => 4242, version => '0.1.9999', status_before => 'started',
});
is($ack->{'ack'}, 1, 'the acknowledgement is marked as one');
is($ack->{'state'}, 'verifying', 'and says the guard is running');
is($ack->{'reason'}, 'v0.1.9999 - the fix', 'carrying the reason it will act on');
is($ack->{'pid'}, 4242, 'and the master that took it');
ok(!exists $ack->{'verified'}, 'it claims no guard verdict');
ok(!exists $ack->{'accepted'}, 'and no acceptance');
ok(!exists $ack->{'refused'}, 'and no refusal');

# A verdict from control::restart_reply is not an ack, so the two frames can
# never be confused by the client.
my $verdict = &control::restart_reply({ proof => { ok => 1 }, reason => 'r', source => 's' });
ok(!$verdict->{'ack'}, 'a verdict is not an acknowledgement');

# -------------------------------------------------- one record, one request
# The record is the answer that survives a lost reply, so it has to be *this*
# request's record, not the last restart's.
my $now = int(time);
my $booted = { ok => 1, reason => 'the landed one', source => 'agent', epoch => $now };
ok(&control::record_is_ours($booted, since => $now, reason => 'the landed one'),
	'a record written for this request answers it');
ok(&control::record_is_ours($booted, since => $now, reason => ''),
	'a caller that gave no reason takes the newest record');
is(&control::record_is_ours($booted, since => $now, reason => 'a different errand'), 0,
	'another restart is not this caller\'s answer');
is(&control::record_is_ours({ %$booted, epoch => $now - 600 }, since => $now, reason => 'the landed one'), 0,
	'a record older than the caller\'s pass is not read as its answer');
is(&control::record_is_ours({ %$booted, epoch => undef }, since => $now, reason => 'the landed one'), 0,
	'a record with no epoch cannot prove it answers this pass');
is(&control::record_is_ours(undef, since => $now), 0, 'no record is not an answer');
is(&control::record_is_ours('not a record', since => $now), 0, 'garbage is not an answer');

&control::write_record({ %$booted, verify => '744 file(s) pass' }, dir => $dir);
my $waited = &control::await_record(dir => $dir, since => $now, reason => 'the landed one', timeout => 0);
ok($waited && $waited->{'reason'} eq 'the landed one', 'await_record hands back the matching record');
is(&control::await_record(dir => $dir, since => $now, reason => 'nothing names this', timeout => 0), undef,
	'and waits for nothing that is not there');

# ------------------------------------------- the master survives a dead spawn
# On Windows the runner's start() needs Win32API::File and Win32::API, and
# CreateProcess can refuse a command line. That death used to come out of
# terminal_pty_runner with $status already 'restarting' and no recovery armed,
# which is exactly a master alive, holding its transport ports, with no tree -
# and a status file that still said good.
my ($runner) = $master =~ /(sub terminal_pty_runner\(\) \{.*?\n\})/s;
ok($runner, 'the master still has terminal_pty_runner');
like($runner, qr/my \$started = eval \{/, 'the spawn is caught instead of thrown');
like($runner, qr/unless \(\$started\) \{.*?\$status = 'frozen';.*?return undef;/s,
	'a spawn that fails leaves the tree marked down and reports it');
like($runner, qr/the tree could not be started/, 'naming the failure in the log');

my ($commit) = $master =~ /(sub restart_commit \{.*?\n\})/s;
ok($commit, 'the master still has restart_commit');
like($commit, qr/my \$started = eval \{ \$fork = &terminal_pty_runner/,
	'the restart sequence catches a spawn that dies');
like($commit, qr/unless \(\$started\) \{.*?\$status_why = 'the tree could not be started: '/s,
	'and turns it into a tree that is down with the reason');
unlike(codes_only($commit), qr/unless \(\$status eq 'restarting'\)/,
	'no failure is excused because the state said restarting');
is(scalar(() = $commit =~ /&arm_boot_watch\(\);/g) >= 2 ? 1 : 0, 1,
	'the boot watch is armed on the good path and on the dead one');
my $spawn_at = index($commit, 'my $started = eval { $fork = &terminal_pty_runner');
my $arm_at   = index($commit, '&arm_boot_watch();');
ok($spawn_at >= 0 && $arm_at > $spawn_at, 'and armed after the spawn attempt, so it always runs');

# ----------------------------------- a boot that never comes up is bounded
# The boot watch is the only thing that notices a tree that never bound a port.
# It retries three times, then stands down so a launcher can start a fresh
# master - and before it goes it must leave the reason where a person looks.
my ($boot) = $master =~ /(sub arm_boot_watch \{.*?\n\})/s;
ok($boot, 'the master still has arm_boot_watch');
like($boot, qr/refused => 'boot'/, 'a boot that did not come up is recorded as a refusal');
like($boot, qr/report => &control::clean_text\(length \$status_why/,
	'and the record carries the reason in hand');
my $give_up = index($boot, 'standing down for a fresh launch');
my $publish = index($boot, '&publish_status(0, $why);');
ok($give_up >= 0 && $publish >= 0, 'standing down publishes the truth');
my $exit_at = index($boot, 'exit 1;');
ok($publish >= 0 && $exit_at > $publish,
	'and does it before the master is gone, or nobody could');
like($boot, qr/\$deadline && !\$master_boot_dead/,
	'a tree that announced its own exit is retried without the 90s grace');

# ---------------------------------------- the tick does not stack restarts
# The old tick restarted a frozen tree every second even with a boot watch
# armed, so a boot that merely needed time was torn down and started again.
my ($tick) = $master =~ /(Mojo::IOLoop->recurring\(1 => sub \{.*?\n\t\}\);)/s;
ok($tick, 'the one-second tick is found');
like($tick, qr/elsif \(!\$master_boot_watch\) \{\s*\$request = \{ reason => \$down, source => 'master-watchdog' \};/s,
	'a watchdog restart waits while the boot watch owns the boot');
like($tick, qr/&publish_status\(0, \$status_why\);/, 'a dead tree is published as frozen with its reason');
like($tick, qr/&publish_status\(1\);/, 'and a tree that answers again is published as good');

# ------------------------------------------------ the ack leaves first
# The acknowledgement has to reach the caller while the loop is still running
# and before the connection becomes a pending restart, and it must not close
# the stream the verdict will use.
my ($socket) = $master =~ /(sub control_socket\(\).*?\n\})/s;
ok($socket, 'the master still has control_socket');
my $ack_at = index($socket, "control_write_now(\$stream, encode_json(\$answer->{'ack'})");
my $pending_at = index($socket, '$pending_restart = {');
ok($ack_at >= 0, 'the accept path writes the acknowledgement');
ok($pending_at > $ack_at, 'before the request becomes the pending restart');
like(substr($socket, $ack_at, 40), qr/control_write_now/, 'on a write that leaves the stream open');
my ($answer) = $master =~ /(sub answer_restart \{.*?\n\})/s;
like($answer, qr/&control_write\(\$stream, encode_json\(\$reply\)/,
	'and the verdict still closes the connection it was asked on');

# Windows only: a listener that could not be made private is said out loud,
# because a child holding it is what makes the master stop answering at all.
like($master, qr/could not be made private/, 'a listener that stayed inheritable is reported');

# ------------------------------------------- restart.pl has one home to look in
# The status-file fallback built its path from $ENV{HOME}, which a Windows
# service and a scheduled task do not set: the restart was written to
# ./.president/status in the caller's directory, where no master reads it.
my $restart_code = codes_only($restart);
like($restart_code, qr/&control::status_file\(\)/, 'the fallback asks the platform for the status file');
unlike($restart_code, qr/\$ENV\{'HOME'\}[^\n]*president[\/\\]status/,
	'and no longer builds it from HOME');
like($restart_code, qr/&control::await_record\(/, 'the fallback waits for the record instead of hoping');
like($restart_code, qr/'pending'/, 'a caller that gave up on the verdict is told so plainly');

done_testing();
