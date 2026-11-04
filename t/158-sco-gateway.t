# tests-for: perl/Sco.pl lib/JawnOS/Sco/ scripts/build_sco.pl perl/sco/ lib/JawnOS/Routes/manager_sco.pm lib/JawnOS/Controller/manager_sco.pm perl/President.pl
# covers:    The SCO gateway's socket client, prompt cache, one-call plan and
#            the routes that arm it; the helper's loopback mode when built.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use IO::Socket::UNIX;
use JSON::PP;
use Mojo::IOLoop;

use RepoSource;
use JawnOSTest;

use lib repo_root() . '/lib';
use JawnOS::Sco::Client;
use JawnOS::Sco::Render;
use JawnOS::Sco::Gateway;

my $repo = root();

# ------------------------------------------------------------- the routes
my $routes = read_file("$repo/lib/JawnOS/Routes/manager_sco.pm");
my $controller = read_file("$repo/lib/JawnOS/Controller/manager_sco.pm");
foreach my $row (
	[52001, 'get', '/manager/sco/status'],
	[52002, 'post', '/manager/sco/arm'],
	[52003, 'post', '/manager/sco/cancel'],
	[52004, 'get', '/manager/sco/result'],
	[52005, 'get', '/manager/sco/recording'],
) {
	my ($idx, $method, $path) = @{$row};
	like($routes, qr/\[\s*$idx\s*,\s*'$method'\s*,\s*'$path'\s*,\s*'action_$idx'\s*\]/,
		"$method $path is registered as action_$idx");
	like($controller, qr/^sub action_$idx\b/m, "action_$idx is defined");
}
like(read_file("$repo/lib/JawnOS/Routes.pm"), qr/\bmanager_sco\b/, 'the route group is loaded');
like($controller, qr/content_type\('audio\/wav'\)/, 'a recording is served as a WAV');
like($controller, qr/\^\[A-Za-z0-9\._-\]\+\\\.wav\$/, 'the recording name is a bare file name');
like(read_file("$repo/perl/President.pl"), qr/perl\/sco\/sco_helper/, 'the master starts the gateway when the helper is built');
like(read_file("$repo/jawn"), qr/\bsco\.sock\b/, 'the boot wipe keeps the gateway socket');

# ------------------------------------------------------------- the client
my $dir = tempdir(CLEANUP => 1);
my $sock_path = "$dir/test.sock";
my $server = IO::Socket::UNIX->new(Local => $sock_path, Listen => 1, Type => SOCK_STREAM);
ok($server, 'a stub gateway socket was created');
my $pid = fork();
if (!defined $pid) {
	die "fork: $!\n";
}
if (!$pid) {
	my $peer = $server->accept();
	if ($peer) {
		my $line = <$peer>;
		my $request = eval { JSON::PP->new->decode($line // '') } || {};
		my $reply = { ok => 1, echo => $request->{'cmd'} || '', state => 'idle' };
		print {$peer} JSON::PP->new->encode($reply) . "\n";
		close $peer;
	}
	close $server;
	exit 0;
}
my $answer = JawnOS::Sco::Client->new(path => $sock_path, timeout => 5)->call({ cmd => 'status' });
is($answer->{'ok'}, 1, 'the client reads a JSON line back');
is($answer->{'echo'}, 'status', 'the command reached the gateway');
waitpid($pid, 0);
my $missing = JawnOS::Sco::Client->new(path => "$dir/none.sock")->call({ cmd => 'status' });
is($missing->{'ok'}, 0, 'no socket is an ordinary answer, not a crash');
like($missing->{'error'}, qr/no gateway socket/, 'and it says why');

# ------------------------------------------------------------- the clips
is(JawnOS::Sco::Render::key('hello', 'piper-a'), JawnOS::Sco::Render::key('hello', 'piper-a'),
	'the same words and voice make the same cache key');
isnt(JawnOS::Sco::Render::key('hello', 'piper-a'), JawnOS::Sco::Render::key('hello', 'piper-b'),
	'a different voice is a different clip');
isnt(JawnOS::Sco::Render::key('hello', 'piper-a'), JawnOS::Sco::Render::key('hello!', 'piper-a'),
	'editing the prompt makes a new clip');
# The virtual handset's commands and its stream matching.
{
	require JawnOS::Sco::Mixer;
	my $mixer = JawnOS::Sco::Mixer->new();
	ok($mixer, 'the mixer constructs');
	like($mixer->capture_command(), qr/jawn_call_in\.monitor/, 'capture reads the call sink monitor');
	like($mixer->playback_command(), qr/jawn_prompt/, 'playback writes the prompt sink');
	like($mixer->playback_command(), qr/latency-msec=20/, 'and asks for a small buffer');
	is_deeply($mixer->call_streams(''), { sink_input => undef, source_output => undef },
		'no address means no streams');
}

JawnOS::Sco::Render::prune();

# ------------------------------------------------------------- the gateway
# A stand-in helper that speaks the protocol: it listens, accepts at once, and
# answers each command, so the gateway's plan can be walked without a radio.
my $fake = "$dir/fake-helper";
$ENV{'FAKE_ARGV'} = "$dir/argv.txt";
write_file($fake, <<'FAKE');
#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP;
my $json = JSON::PP->new;
sub say_line { print $json->encode(shift), "\n"; $| = 1; }
if ($ENV{FAKE_ARGV}) {
	open(my $af, '>', $ENV{FAKE_ARGV}) or exit 0;
	print {$af} join(" ", @ARGV), "\n";
	close $af;
}
$| = 1;
say_line({ event => 'listening', local => 'fake' });
select(undef, undef, undef, 0.05);
say_line({ event => 'accepted', peer => '00:11:22:33:44:55' });
while (my $line = <STDIN>) {
	my $cmd = eval { $json->decode($line) } || {};
	my $id = $cmd->{id} || 0;
	if (($cmd->{cmd} || '') eq 'play' || ($cmd->{cmd} || '') eq 'tone') {
		say_line({ event => 'played', id => $id, ms => 10 });
	}
	elsif (($cmd->{cmd} || '') eq 'record') {
		open(my $fh, '>', $cmd->{file}) or next;
		binmode $fh;
		print {$fh} 'RIFF' . ('x' x 40);
		close $fh;
		say_line({ event => 'recorded', id => $id, file => $cmd->{file}, ms => 1234, silence => JSON::PP::true });
	}
	elsif (($cmd->{cmd} || '') eq 'quit') {
		last;
	}
}
exit 0;
FAKE
chmod 0755, $fake;

my $clip = "$dir/clip.raw";
write_file($clip, "\0" x 160);

my $gateway = JawnOS::Sco::Gateway->new(
	dir => "$dir/sco",
	helper => $fake,
	status_path => "$dir/sco.json",
);
my $armed = $gateway->arm(
	local => 'E0:E1:A9:3D:4B:B8',
	clips => { greeting => $clip, prompt => $clip, thanks => $clip },
	record => { ms => 5000 },
	call_id => 'test-call',
);
is($armed->{'ok'}, 1, 'the gateway arms');
is($gateway->{'state'}, 'armed', 'and waits for the link');

my $stopped = 0;
Mojo::IOLoop->recurring(0.05 => sub {
	my $state = $gateway->{'state'} || '';
	return unless $state eq 'done' || $state eq 'idle';
	$stopped = 1;
	Mojo::IOLoop->stop;
});
# a plan that never finishes must fail the test, not hang the suite
Mojo::IOLoop->timer(6 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;
ok($stopped, 'the gateway reached a resting state on its own');

is($gateway->{'state'}, 'done', 'the plan runs to the end');
like(-e "$dir/argv.txt" ? read_file("$dir/argv.txt") : '', qr/--local E0:E1:A9:3D:4B:B8/,
	'the adapter the caller named reaches the helper');
is(scalar @{ $gateway->{'recordings'} }, 1, 'one name was recorded');
my $recording = $gateway->{'recordings'}->[0];
is($recording->{'ms'}, 1234, 'the helper length is kept');
ok($recording->{'silence'}, 'and the silence verdict travels with it');
ok(-s $recording->{'file'}, 'the file the helper wrote is reported');
ok(-s "$dir/sco.json", 'the status file is written');
my $status = JSON::PP->new->decode(read_file("$dir/sco.json"));
is($status->{'state'}, 'done', 'the status file agrees with the daemon');
is($status->{'last_error'}, '', 'and no error is carried');

ok($gateway->recording_path('name-test-call.wav'), 'a recording by bare name is served');
is($gateway->recording_path('../../etc/passwd'), '', 'a path is not a name');
is($gateway->recording_path('.hidden'), '', 'a dot file is not served');

my $cancelled = $gateway->cancel();
is($cancelled->{'state'}, 'idle', 'cancel puts the gateway down');

# Pipe mode returns before the adapter branch, and used to leave the record
# options unset: a screened call then ran the helper's 30 s / 1.8 s defaults
# instead of the 20 s / 2 s the phone asked for.
my $pipeway = JawnOS::Sco::Gateway->new(
	dir => "$dir/sco-pipe",
	helper => $fake,
	status_path => "$dir/sco-pipe.json",
	pipe => 1,
);
my $pipe_armed = $pipeway->arm(record => { ms => 20000, silence_ms => 2000, min_ms => 400 });
is($pipe_armed->{'state'}, 'waiting', 'pipe mode waits for the call streams');
is($pipeway->{'record_opts'}->{'ms'}, 20000, 'the record ceiling reaches pipe mode');
is($pipeway->{'record_opts'}->{'silence_ms'}, 2000, 'and so does the pause that ends a name');
is($pipeway->{'record_opts'}->{'min_ms'}, 400, 'and the speech floor');
$pipeway->cancel();

# ------------------------------------------------------- the real helper
# The voice gate, with a file standing in for the caller. These are the cases a
# screened call actually has: a caller who waits a moment, a line whose own
# noise ticks once before the caller speaks (the tick used to open the clip and
# 1.2 s of line noise then close it, so the name was cut off before it began),
# and a caller who says nothing at all.
my $helper = "$repo/perl/sco/sco_helper";
SKIP: {
	skip 'the SCO helper is not built on this machine', 4 unless -x $helper;
	my $voice = sub {
		my ($ms) = @_;
		return join('', map { pack('s<', int(sin(2 * 3.14159 * 440 * $_ / 8000) * 8000)) } 0 .. int(8 * $ms) - 1);
	};
	my $quiet = sub { "\0" x (16 * $_[0]) };
	my $record = sub {
		my ($name, $audio, %opts) = @_;
		my $raw = "$dir/$name.raw";
		open(my $rh, '>', $raw) or die "$raw: $!";
		binmode $rh;
		print {$rh} $audio;
		close $rh;
		my $out = "$dir/$name.wav";
		my $fh;
		open($fh, '|-', $helper, '--loopback', $raw, '--fast') or die "helper: $!";
		print {$fh} JSON::PP->new->encode({
			cmd => 'record', id => 1, file => $out,
			ms => $opts{'ms'} || 8000,
			silence_ms => $opts{'silence_ms'} || 600,
			min_ms => $opts{'min_ms'} || 300,
		}) . "\n";
		close $fh;
		open(my $wav, '<', $out) or return 0;
		binmode $wav;
		seek($wav, 44, 0);
		local $/;
		my $pcm = <$wav> // '';
		close $wav;
		return length $pcm;
	};
	# half a second of room, then a name the caller took their time to start
	my $patient = $record->('patient', $quiet->(600) . $voice->(700) . $quiet->(1600));
	ok($patient > 16000, 'the name is recorded once the caller speaks');
	ok($patient > 25600 && $patient < 41600,
		'the clip runs to the pause after the name, not to the ceiling');
	# a tick of line noise, then a pause, then the name: the tick is not a name
	my $blip = $record->('blip', $quiet->(1200) . $voice->(20) . $quiet->(800)
		. $voice->(600) . $quiet->(1500));
	ok($blip > 38400, 'a single tick does not open the clip or cut the name short');
	# nobody spoke: the ceiling ends it, and the clip is marked as silent
	my $none = $record->('none', $quiet->(3000), ms => 1500);
	ok($none >= 16000 && $none <= 24000, 'a silent caller is ended by the ceiling');
}

done_testing();
