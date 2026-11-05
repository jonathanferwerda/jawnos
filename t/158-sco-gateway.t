# tests-for: perl/Sco.pl lib/JawnOS/Sco/ scripts/build_sco.pl perl/sco/ lib/JawnOS/Routes/manager_sco.pm lib/JawnOS/Controller/manager_sco.pm perl/President.pl public/js/manager/phone.js
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
use IO::Socket::INET;
use IPC::Open2 ();
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

# ------------------------------------------------ the gateway in the bag
# The house can drive a daemon that is not on this machine: the same line over
# TCP, carrying the token that daemon requires.
my $tcp = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
	Listen => 1, ReuseAddr => 1,
);
ok($tcp, 'a stub gateway listener was created on the tailnet face');
my $tcp_port = $tcp->sockport;
my $tcp_pid = fork();
die "fork: $!\n" unless defined $tcp_pid;
if (!$tcp_pid) {
	my $peer = $tcp->accept();
	if ($peer) {
		my $line = <$peer>;
		my $request = eval { JSON::PP->new->decode($line // '') } || {};
		print {$peer} JSON::PP->new->encode({
			ok => 1,
			echo => $request->{'cmd'} || '',
			token => $request->{'token'} || '',
		}) . "\n";
		close $peer;
	}
	close $tcp;
	exit 0;
}
my $bag = JawnOS::Sco::Client->new(
	host => '127.0.0.1', port => $tcp_port, token => 's3cret', timeout => 5);
ok($bag->remote(), 'a named address makes the gateway remote');
is($bag->where(), "127.0.0.1:$tcp_port", 'and it says where it is');
my $over_tcp = $bag->call({ cmd => 'status' });
is($over_tcp->{'echo'}, 'status', 'the command reaches a gateway over TCP');
is($over_tcp->{'token'}, 's3cret', 'and carries the token that gateway requires');
waitpid($tcp_pid, 0);

my $unreachable = JawnOS::Sco::Client->new(
	host => '127.0.0.1', port => 1, timeout => 2)->call({ cmd => 'status' });
is($unreachable->{'ok'}, 0, 'a puck that is not there is an ordinary answer');
like($unreachable->{'error'}, qr/unreachable/, 'and the error names the address');

my $daemon = read_file("$repo/perl/Sco.pl");
like($daemon, qr/--listen/, 'the daemon can listen on the tailnet');
like($daemon, qr/--listen needs --token/, 'and refuses to listen without a token');
like($daemon, qr/bad token/, 'a line without the token is refused');

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

# Moving a stream that is already ours re-links it and drops a word of the
# greeting, so a move happens only when the stream is somewhere else.
{
	require JawnOS::Sco::Mixer;
	my $mixer = JawnOS::Sco::Mixer->new();
	my $moves = '';
	my $sink_on = 3472;
	my $source_on = 3473;
	my %name = (
		3472 => 'alsa_output.pci-0000_00_1f.3.analog-stereo',
		3657 => 'jawn_call_in',
		3473 => 'alsa_input.pci-0000_00_1f.3.analog-stereo',
		3672 => 'jawn_ivr_mic',
	);
	local *JawnOS::Sco::Mixer::pactl = sub {
		my @arg = @_;
		my $line = join ' ', @arg;
		if ($line eq 'list short sinks') {
			return join '', map { "$_\t$name{$_}\tPipeWire\ts16 2ch\tRUNNING\n" } sort keys %name;
		}
		if ($line eq 'list short sources') {
			return join '', map { "$_\t$name{$_}\tPipeWire\ts16 2ch\tRUNNING\n" } sort keys %name;
		}
		if ($line eq 'list sink-inputs') {
			return "Sink Input #41\n\tSink: $sink_on\n\tProperties:\n\t\tdevice.string = \"00:2B:70:E9:7E:B2\"\n\n";
		}
		if ($line eq 'list source-outputs') {
			return "Source Output #42\n\tSource: $source_on\n\tProperties:\n\t\tdevice.string = \"00:2B:70:E9:7E:B2\"\n\n";
		}
		$moves .= "$line\n" if $arg[0] =~ /^move-/;
		return '';
	};
	my $first = $mixer->attach('00:2B:70:E9:7E:B2');
	is_deeply($first->{'moved'}, [ 'sink-input', 'source-output' ],
		'streams on the laptop\'s own devices are moved');
	like($moves, qr/move-sink-input 41 jawn_call_in/, 'the caller\'s voice is moved');
	like($moves, qr/move-source-output 42 jawn_ivr_mic/, 'and the phone\'s capture');
	$moves = '';
	$sink_on = 3657;
	$source_on = 3672;
	my $second = $mixer->attach('00:2B:70:E9:7E:B2');
	is_deeply($second->{'moved'}, [], 'streams already on our devices are left alone');
	is($moves, '', 'and nothing is re-linked');
}

JawnOS::Sco::Render::prune();

# ------------------------------------------------ the band the gateway is on
# Bluetooth and WiFi share one antenna on a combo card, and a 2.4 GHz
# connection starves the SCO link, so the gateway says which band it is on.
is(JawnOS::Sco::Gateway::wifi_band_of("Connected to aa:bb\n\tfreq: 2462.0\n"), '2.4',
	'a 2.4 GHz association is named');
is(JawnOS::Sco::Gateway::wifi_band_of("Connected to aa:bb\n\tfreq: 5180.0\n"), '5',
	'and a 5 GHz one');
is_deeply(
	[ JawnOS::Sco::Gateway::wifi_interfaces_of("\tInterface wlo1\n\t\tifindex 3\n\tInterface wlp0s20f0u4i2\n") ],
	[ 'wlo1', 'wlp0s20f0u4i2' ],
	'iw indents the interface list, and both interfaces are found');
is(JawnOS::Sco::Gateway::wifi_band_of('Not connected.'), '', 'a machine on a wire has no band');
is(JawnOS::Sco::Gateway::wifi_band_of(undef), '', 'and neither has one with no wireless');
my $gateway_src = read_file("$repo/lib/JawnOS/Sco/Gateway.pm");
like($gateway_src, qr/wifi => \$wifi,/, 'the status carries the band');
like($gateway_src, qr/wifi eq '2\.4'/, 'and warns when it is the crowded one');
like($gateway_src, qr/cmd => 'line'/, 'the gateway tells a new line it is up');
like(read_file("$repo/public/js/manager/phone.js"), qr/res\.wifi === '2\.4'/,
	'the pane says so on the IVR tab');

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

# The call a plan was just spoken into is still up for a moment after the
# thanks, so the gateway must not serve it a second plan. A finished plan is put
# down when its line stops being fed, and only then can Reception arm again.
{
	my $finished = JawnOS::Sco::Gateway->new(
		dir => "$dir/sco-done",
		helper => $fake,
		status_path => "$dir/sco-done.json",
	);
	$finished->{'state'} = 'done';
	$finished->end_call('line idle');
	is($finished->{'state'}, 'idle', 'a finished plan lets go of its line');
	ok(JawnOS::Sco::Mixer->can('call_active'), 'the mixer can say whether a call is being fed');
	like(read_file("$repo/perl/Reception.pl"), qr/\$state eq 'in_call' \|\| \$state eq 'done'/,
		'a finished plan is not armed over');
	# A finished plan lets go of its line quickly: the caller has heard the
	# thanks, and the phone is only holding the call for its own limit.
	is(JawnOS::Sco::Gateway::call_over('done', 3, 30), '',
		'a finished plan keeps its line for a moment');
	is(JawnOS::Sco::Gateway::call_over('done', 5, 30), 'plan done',
		'then the gateway is free for the next call');
	is(JawnOS::Sco::Gateway::call_over('in_call', undef, 50), 'call limit',
		'a step that never ends is bounded');
	is(JawnOS::Sco::Gateway::call_over('in_call', undef, 10), '',
		'a live call is left alone');
}

my $cancelled = $gateway->cancel();
is($cancelled->{'state'}, 'idle', 'cancel puts the gateway down');

# The phone's Hands-Free pair outlives the plan, and Reception arms again as
# soon as a finished plan lets go of its line. So a pair that is already up at
# arm time is the call that has just heard its plan, not a new caller: it is
# held until it goes, and nothing is spoken into it. (The `line` word greets a
# silent caller the moment the pair appears, so the helper's old wait-for-audio
# guard cannot do this any more - measured: a second greeting went into a call
# still holding its line.)
{
	require JawnOS::Sco::Mixer;
	local *JawnOS::Sco::Mixer::pactl = sub {
		my $line = join ' ', @_;
		return "3657\tjawn_call_in\tPipeWire\ts16 2ch\tRUNNING\n3664\tjawn_prompt\tPipeWire\ts16 2ch\tRUNNING\n"
			if $line eq 'list short sinks';
		return "3672\tjawn_ivr_mic\tPipeWire\ts16 2ch\tRUNNING\n"
			if $line eq 'list short sources';
		return "Sink Input #41\n\tSink: 3657\n\tProperties:\n\t\tdevice.string = \"00:2B:70:E9:7E:B2\"\n\n"
			if $line eq 'list sink-inputs';
		return "Source Output #42\n\tSource: 3672\n\tProperties:\n\t\tdevice.string = \"00:2B:70:E9:7E:B2\"\n\n"
			if $line eq 'list source-outputs';
		return '';
	};
	my $heldway = JawnOS::Sco::Gateway->new(
		dir => "$dir/sco-held",
		helper => $fake,
		status_path => "$dir/sco-held.json",
		pipe => 1,
	);
	my $held_armed = $heldway->arm(
		peer => '00:2B:70:E9:7E:B2',
		clips => { greeting => $clip, prompt => $clip, thanks => $clip },
	);
	is($held_armed->{'state'}, 'waiting', 'pipe mode still waits for the call');
	is($heldway->{'held'}, 1, 'a pair already up at arm time is the finished call');
	my $spoke = 0;
	Mojo::IOLoop->timer(0.5 => sub { $spoke = 1 if $heldway->{'pid'} });
	Mojo::IOLoop->timer(0.7 => sub { Mojo::IOLoop->stop });
	Mojo::IOLoop->start;
	is($heldway->{'state'}, 'waiting', 'and no second plan is spoken into it');
	ok(!$spoke, 'no helper is started for a pair that has had its plan');
	$heldway->cancel();
}

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
	skip 'the SCO helper is not built on this machine', 8 unless -x $helper;
	my $voice = sub {
		my ($ms) = @_;
		return join('', map { pack('s<', int(sin(2 * 3.14159 * 440 * $_ / 8000) * 8000)) } 0 .. int(8 * $ms) - 1);
	};
	my $quiet = sub { "\0" x (16 * $_[0]) };
	# what the last run announced, so a verdict can be checked, not guessed
	my $last_events = '';
	my $record = sub {
		my ($name, $audio, %opts) = @_;
		my $raw = "$dir/$name.raw";
		open(my $rh, '>', $raw) or die "$raw: $!";
		binmode $rh;
		print {$rh} $audio;
		close $rh;
		my $out = "$dir/$name.wav";
		my $events = "$dir/$name.json";
		my $fh;
		# the helper speaks JSON on its stdout; keep it out of the TAP stream
		# so the verdict it announced can be read back
		my $spawned = open($fh, '|-');
		die "helper: $!" unless defined $spawned;
		if (!$spawned) {
			open(STDOUT, '>', $events) or die "$events: $!";
			exec($helper, '--loopback', $raw, '--fast') or die "helper: $!";
		}
		print {$fh} JSON::PP->new->encode({
			cmd => 'record', id => 1, file => $out,
			ms => $opts{'ms'} || 8000,
			silence_ms => $opts{'silence_ms'} || 600,
			min_ms => $opts{'min_ms'} || 300,
		}) . "\n";
		close $fh;
		$last_events = '';
		if (open(my $ef, '<', $events)) {
			local $/;
			$last_events = <$ef> // '';
			close $ef;
		}
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
	like($last_events, qr/"silence":false/,
		'a name that ends on a pause is not reported as silence');
	# a tick of line noise, then a pause, then the name: the tick is not a name
	my $blip = $record->('blip', $quiet->(1200) . $voice->(20) . $quiet->(800)
		. $voice->(600) . $quiet->(1500));
	ok($blip > 38400, 'a single tick does not open the clip or cut the name short');
	# nobody spoke: the ceiling ends it, and the clip is marked as silent
	my $none = $record->('none', $quiet->(3000), ms => 1500);
	ok($none >= 16000 && $none <= 24000, 'a silent caller is ended by the ceiling');
	# The gateway can see the phone's two Hands-Free streams, so it knows the
	# call is up before a frame arrives and says so. Without that word a line
	# of zeros is not a call, and a caller waiting to be greeted is never
	# greeted at all.
	my $pipe_run = sub {
		my ($with_line) = @_;
		my ($out, $in);
		my $pid = IPC::Open2::open2($out, $in, $helper,
			'--pipe-in', 'cat /dev/zero', '--pipe-out', 'cat > /dev/null');
		print {$in} JSON::PP->new->encode({ cmd => 'line' }) . "\n" if $with_line;
		$in->flush;
		select(undef, undef, undef, 3.6);
		close $in;
		my $said = do { local $/; <$out> // '' };
		close $out;
		waitpid($pid, 0);
		return $said;
	};
	like($pipe_run->(1), qr/"event":"accepted"/,
		'a silent line the gateway says is up is greeted anyway');
	unlike($pipe_run->(0), qr/"event":"accepted"/,
		'and a line of zeros with no word from the gateway is not a call');
}

# A link that hands the gateway nothing but digital silence is not a call yet:
# the phone's gateway nodes keep feeding our sink with silence between calls,
# and speaking then speaks into nothing. The plan waits for a frame that
# carries something.
SKIP: {
	skip 'the SCO helper is not built on this machine', 2 unless -x $helper;
	require IPC::Open2;
	my $accepted_within = sub {
		my ($source, $seconds) = @_;
		my ($out, $in);
		my $pid = IPC::Open2::open2($out, $in, $helper,
			'--pipe-in', $source, '--pipe-out', 'cat > /dev/null');
		return 0 unless $pid;
		$in->autoflush(1);
		my $start = time;
		my $buffer = '';
		my $seen = 0;
		while (time - $start < $seconds) {
			my $rin = '';
			vec($rin, fileno($out), 1) = 1;
			my $rout = $rin;
			next unless select($rout, undef, undef, 0.5);
			my $got = sysread($out, my $chunk, 4096);
			last unless $got;
			$buffer .= $chunk;
			if ($buffer =~ /"event":"accepted"/) { $seen = 1; last; }
		}
		print {$in} '{"cmd":"quit"}' . "\n";
		close $in;
		close $out;
		waitpid($pid, 0);
		return $seen;
	};
	ok(!$accepted_within->('cat /dev/zero', 3), 'a link of pure silence is not answered yet');
	ok($accepted_within->('yes', 4), 'a link that carries audio is answered');
}

# Two seconds without a frame is the end of a call, and it is measured in wall
# time. Counting polls instead measured twenty milliseconds, and a buffer that
# arrived a little late ended a live call in the middle of the greeting.
SKIP: {
	skip 'the SCO helper is not built on this machine', 2 unless -x $helper;
	require IPC::Open2;
	my $feeder = "$dir/feeder.pl";
	write_file($feeder, <<'FEED');
#!/usr/bin/perl
# like parec: 20 ms of audio every 20 ms for two seconds, then silence with the
# pipe still open
for (1 .. 100) { print pack('s<', 6000) x 160; select(undef, undef, undef, 0.02); }
select(undef, undef, undef, 2.5);
FEED
	chmod 0755, $feeder;
	my ($out, $in);
	my $pid = IPC::Open2::open2($out, $in, $helper,
		'--pipe-in', $feeder, '--pipe-out', 'cat > /dev/null');
	$in->autoflush(1);
	my $start = time;
	my ($accepted_at, $closed_at);
	my $buffer = '';
	while (time - $start < 7) {
		my $rin = '';
		vec($rin, fileno($out), 1) = 1;
		my $rout = $rin;
		next unless select($rout, undef, undef, 0.5);
		my $got = sysread($out, my $chunk, 4096);
		last unless $got;
		$buffer .= $chunk;
		$accepted_at = time - $start if !$accepted_at && $buffer =~ /"event":"accepted"/;
		if ($buffer =~ /"event":"closed"/) { $closed_at = time - $start; last; }
	}
	print {$in} '{"cmd":"quit"}' . "\n";
	close $in;
	close $out;
	waitpid($pid, 0);
	ok($accepted_at, 'a paced stream is answered');
	ok($closed_at && $closed_at - $accepted_at >= 2,
		'a quiet line ends the call after two seconds, not after forty polls');
}

done_testing();
