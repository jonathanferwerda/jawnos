# tests-for: jawn perl/President.pl
# covers:    The master launches President on a pty and now keeps the tree's console stream in a bounded, sequenced ring (J...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Mojo::IOLoop;
use Mojo::IOLoop::ReadWriteFork;

# The master launches President on a pty and now keeps the tree's console
# stream in a bounded, sequenced ring (JawnOS::LogBus) served at
# ~/.president/log for the error watch; there is no ~/pty.log file to tee.
# The pty itself stays: it is the master's merged stdout+stderr, the death-text
# source and the shutdown signal's target.

my $launcher = "$FindBin::Bin/../jawn";
open(my $fh, '<', $launcher) or die "$launcher: $!";
my $src = do { local $/; <$fh> };
close $fh;

# The pty stays the native default; portable mode adds a pipe.
like($src, qr/sub\s+terminal_pty_runner/, 'the master still runs the tree on a pty');
like($src, qr/type\s*=>\s*'pty'/, 'the native conduit is still a pty');
like($src, qr/type\s*=>\s*'pipe'/, 'portable mode can run the tree on a pipe');
like($src, qr/JawnOS::Platform::portable\(\)/, 'the choice follows the platform mode');
unlike($src, qr/pty_log_fh/, 'the console is no longer teed into a pty.log file');
like($src, qr/JawnOS::LogBus/, 'the master keeps the console stream in the log bus');
like($src, qr/ring_append/, 'and appends every pty read to its ring');
like($src, qr/sub\s+log_socket/, 'and serves the ring over ~/.president/log');
like($src, qr/sub\s+log_seed/, 'the master seeds the ring from the supervisor tail');
like($src, qr/jawn-stdout\.log/, 'the crash record is the supervisor\'s jawn-stdout.log');
like($src, qr/&log_seed\(\)/, 'and seeds before the tree starts');

# The shell layer is gone.
unlike($src, qr/program\s*=>\s*["']bash["']/, 'no interactive bash between the master and President');
unlike($src, qr/\b(?:INPUTRC|PROMPT_COMMAND)\b/, 'no bash-only environment is left behind');
unlike($src, qr/write\(\s*["']\\x03["']/, 'no ^C byte is written into a raw pty');

# The argv it runs.
like($src, qr/sub\s+president_process/, 'the President argv has one definition');
like($src, qr/program_args\s*=>\s*\[\s*'\.\/perl\/President\.pl'\s*\]/, 'it names President.pl as an argument');
like($src, qr/program\s*=>\s*\$data->\{'program'\}/, 'the runner execs that program');
like($src, qr/program_args\s*=>\s*\$data->\{'program_args'\}/, 'and passes its arguments');

# The mechanism the launcher now relies on: a raw pty with a direct argv still
# delivers the child's output, still lets the master signal it, and still hands
# back the exit status. This is the same shape as terminal_pty_runner.
my ($out, $exit, $sig) = ('', undef, undef);
my $rwf = Mojo::IOLoop::ReadWriteFork->new;
$rwf->conduit({ raw => 1, type => 'pty' });
$rwf->on(read => sub { $out .= $_[1] });
$rwf->on(close => sub { ($exit, $sig) = ($_[1], $_[2]) });
$rwf->on(finish => sub {
	($exit, $sig) = ($_[1], $_[2]);
	Mojo::IOLoop->stop;
});
$rwf->start({
	program      => $^X,
	program_args => [ '-e', '$SIG{INT} = sub { print "INT\n"; exit 7 }; print "READY\n"; $| = 1; while (1) { select(undef, undef, undef, 0.1) }' ],
	env          => { %ENV, TERM => 'dumb' },
});
Mojo::IOLoop->timer(1 => sub { kill 'INT', $rwf->pid });
Mojo::IOLoop->timer(8 => sub { kill 'KILL', $rwf->pid });
Mojo::IOLoop->start;

like($out, qr/READY/, 'the pty delivers the child output');
like($out, qr/INT/, 'an explicit INT reaches the pty child (the shutdown path)');
is($exit, 7, 'the child exit status reaches the master');
is($sig, 0, 'and it is an exit, not a signal');

done_testing();
