# tests-for: perl/Sco.pl lib/JawnOS/Sco/ scripts/build_sco.pl perl/sco/ lib/JawnOS/Routes/manager_sco.pm lib/JawnOS/Controller/manager_sco.pm perl/President.pl perl/Reception.pl public/js/manager/phone.js
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

{ package ScoRows;
  sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
  sub hashes { return $_[0]->{'rows'}; }
}

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
	[52007, 'post', '/manager/sco/say'],
	[52008, 'post', '/manager/sco/hold'],
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
# The hold music library, in a temp folder: the gateway resolves a chosen track
# on its own machine, so the test gives it two short WAVs to convert.
my $music_dir = "$dir/music";
make_path($music_dir);
my $tiny_wav = sub {
	my ($secs) = @_;
	my $n = 8000 * $secs;
	my $data = join '', map { pack('s<', int(sin(2 * 3.14159 * 440 * $_ / 8000) * 6000)) } 0 .. $n - 1;
	return 'RIFF' . pack('V', 36 + length $data)
		. 'WAVEfmt ' . pack('VvvVVvv', 16, 1, 1, 8000, 16000, 2, 16)
		. 'data' . pack('V', length $data) . $data;
};
write_file("$music_dir/One.wav", $tiny_wav->(1));
write_file("$music_dir/Two.wav", $tiny_wav->(1));
$ENV{'JAWNOS_HOLD_MUSIC'} = $music_dir;
$ENV{'JAWNOS_HOLD_CACHE'} = "$dir/hold-cache";
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

# ------------------------------------- which gateway the house points at
# A phone has no helper and no socket: it reads the IVR pane's machine, finds
# that machine in the roster, and dials its sco_port with the house token.
# Resolution is a settings read and one roster read - no fork, no network - so
# it can happen inside a page route.
{
	local *subs::misc_setting = sub { return undef };
	local *subs::signatorial_designer = sub { return 'self-sig' };
	local *subs::home = sub {
		my $path = shift;
		$path =~ s{^~}{$dir};
		return $path;
	};
	my %setting = (sco_port => '45701', sco_token => 'house-token');
	local *subs::setting_grabber = sub {
		my $request = shift;
		return $setting{ $request->{'setting'} };
	};
	my @rows = (
		{ signatorial => 'gw-sig', ip => '10.0.0.5', connection => 'active' },
		{ signatorial => '10.0.0.9', ip => '10.0.0.9', connection => 'active' },
	);
	local *subs::db_select = sub {
		my ($table, $columns, $where) = @_;
		my @match = grep {
			my $ok = 1;
			foreach my $key ( keys %{ $where || {} } ) {
				$ok = 0 if (($$_{$key} // '') ne ($where->{$key} // ''));
			}
			$ok;
		} @rows;
		return ScoRows->new(\@match);
	};

	# (a) the machine in front of you - and no machine named at all - is local
	local *subs::phone_ivr_grab = sub { return 'self-sig' };
	my $here = JawnOS::Sco::Client->new();
	ok(!$here->remote(), 'the machine in front of you is the local socket');
	is($here->path(), "$dir/.president/sco.sock", 'and its path is the gateway socket');
	local *subs::phone_ivr_grab = sub { return '' };
	ok(!JawnOS::Sco::Client->new()->remote(), 'no machine named is the local socket');

	# (b) another machine is found by its signatorial, then dialled
	local *subs::phone_ivr_grab = sub { return 'gw-sig' };
	my $remote = JawnOS::Sco::Client->new();
	ok($remote->remote(), 'a named machine makes the gateway remote');
	is($remote->where(), '10.0.0.5:45701', 'the roster address and the house port are dialled');
	is($remote->{'token'}, 'house-token', 'and a line carries the house token');
	is($remote->machine(), 'gw-sig', 'the named machine is kept for the log');
	# the pane keys a machine by signatorial, but an older key is the ip
	local *subs::phone_ivr_grab = sub { return '10.0.0.9' };
	is(JawnOS::Sco::Client->new()->where(), '10.0.0.9:45701',
		'a machine named by its ip resolves through the roster');
	# no sco_port row: the daemon's documented default
	delete $setting{'sco_port'};
	is(JawnOS::Sco::Client->new()->where(), '10.0.0.9:45700',
		'a house with no sco_port uses 45700');
	$setting{'sco_port'} = '45701';

	# (c) an address named outright still wins
	$setting{'sco_gateway'} = '10.9.9.9:45999';
	local *subs::phone_ivr_grab = sub { return 'gw-sig' };
	my $named = JawnOS::Sco::Client->new();
	is($named->where(), '10.9.9.9:45999', 'sco_gateway wins over the machine named in the app');
	is($named->{'token'}, 'house-token', 'and it still carries the house token');
	delete $setting{'sco_gateway'};

	# a machine the roster cannot place: local, and the reason names it
	local *subs::db_select = sub { return ScoRows->new([]) };
	local *subs::phone_ivr_grab = sub { return 'gone-sig' };
	my $lost = JawnOS::Sco::Client->new();
	ok(!$lost->remote(), 'a machine with no roster row falls back to the local socket');
	my $reason = $lost->call({ cmd => 'status' });
	is($reason->{'ok'}, 0, 'and that call is an ordinary answer');
	like($reason->{'error'}, qr/gone-sig.*no address/, 'which names the machine it could not place');
}

my $president = read_file("$repo/perl/President.pl");
like($president, qr/'--listen',\s*'0\.0\.0\.0:'/,
	'the master puts the gateway on the network face');
like($president, qr/sco_token/, 'with the house token, minted when it is missing');
like($president, qr/local \@ARGV/, 'handed to the gateway child, not to the master');
like($president, qr/'--token'/, 'and the token travels as an argument');
like($president, qr/\$is_gateway/, 'only the machine the house names as the gateway listens');
like($president, qr/if \(\$is_gateway\)/, 'and only it starts the Reception armer');

my $daemon = read_file("$repo/perl/Sco.pl");
like($daemon, qr/--listen/, 'the daemon can listen on the tailnet');
like($daemon, qr/--listen needs --token/, 'and refuses to listen without a token');
like($daemon, qr/bad token/, 'a line without the token is refused');
like($daemon, qr/merge_clips/, 'the daemon renders the words a phone sends');
like($controller, qr/words => \\%words/, 'an arm carries the words');
like($controller, qr/\$client->remote\(\)/,
	'and only a local arm renders its clips here');
my $reception_src = read_file("$repo/perl/Reception.pl");
like($reception_src, qr/words => \{ map/,
	'Reception sends words too, for a gateway on another machine');
like($reception_src, qr/unless \(\$client->remote\(\)\)/,
	'and renders clips only when the gateway is this one');
like($reception_src, qr/\$not_the_gateway/, 'a helper box that is not the gateway does not arm it');
like($daemon, qr/note_caller/, 'a status poll carries the caller to the gateway');
like($controller, qr/param\('number'\)/, 'the status route passes the caller number');

# ------------------------------------------------------------- the clips
is(JawnOS::Sco::Render::key('hello', 'piper-a'), JawnOS::Sco::Render::key('hello', 'piper-a'),
	'the same words and voice make the same cache key');
isnt(JawnOS::Sco::Render::key('hello', 'piper-a'), JawnOS::Sco::Render::key('hello', 'piper-b'),
	'a different voice is a different clip');
isnt(JawnOS::Sco::Render::key('hello!', 'piper-a'), JawnOS::Sco::Render::key('hello', 'piper-a'),
	'editing the prompt makes a new clip');
# The gateway fills in the clips a phone could not render: paths from another
# machine are not clips, and a phone has no Piper to make them.
{
	local *JawnOS::Sco::Render::render = sub {
		my ($text, $voice) = @_;
		return '' unless defined $text && length $text;
		return "/rendered/$text-$voice.raw";
	};
	my $existing = "$dir/existing.raw";
	write_file($existing, 'x');
	my $merged = JawnOS::Sco::Render::merge_clips(
		{ greeting => $existing, prompt => '/phone/never.raw' },
		{ greeting => 'Hello', prompt => 'Who is this?', thanks => 'Thanks' },
		'piper-john',
	);
	is($merged->{'greeting'}, $existing, 'a clip this machine can see is kept');
	is($merged->{'prompt'}, '/rendered/Who is this?-piper-john.raw',
		'a path from the phone is rendered from its words');
	is($merged->{'thanks'}, '/rendered/Thanks-piper-john.raw',
		'a missing clip is rendered from its words too');
}
{
	local *JawnOS::Sco::Render::render = sub { return '' };
	is_deeply(JawnOS::Sco::Render::merge_clips({}, {}, ''), {},
		'nothing to speak leaves no clip behind');
}

# The caller is the phone's fact, not the Bluetooth link's: its status poll
# carries the number, and the gateway resolves the house's name for it.
{
	local *subs::phone_number_app = sub { return 'john_smith' };
	local *subs::format_name = sub { return 'John Smith' };
	my $cg = JawnOS::Sco::Gateway->new(
		dir => $dir, helper => ['/bin/false'], status_path => "$dir/sco-caller.json", pipe => 1);
	ok($cg->note_caller('+1 (555) 555-0101'), 'a status poll names the caller');
	is($cg->status->{'caller'}->{'name'}, 'John Smith', 'and the house resolves their name');
	is($cg->status->{'caller'}->{'number'}, '+1 (555) 555-0101', 'while keeping the number as it arrived');
	local *subs::phone_number_app = sub { return '5555550199' };
	$cg->note_caller('+1 (555) 555-0199');
	is($cg->status->{'caller'}->{'name'}, '', 'a number the house does not know has no name');
	ok(!$cg->note_caller(''), 'an empty poll is not a caller');
	is($cg->status->{'caller'}->{'number'}, '+1 (555) 555-0199',
		'and the last caller is kept when the phone id goes stale');
	$cg->cancel();
	is_deeply($cg->status->{'caller'}, {}, 'cancelling forgets the caller');
}
# The virtual handset's commands and its stream matching.
{
	require JawnOS::Sco::Mixer;
	my $mixer = JawnOS::Sco::Mixer->new();
	ok($mixer, 'the mixer constructs');
	like($mixer->capture_command(), qr/jawn_call_in\.monitor/, 'capture reads the call sink monitor');
	like($mixer->playback_command(), qr/jawn_prompt/, 'playback writes the prompt sink');
	like($mixer->playback_command(), qr/latency-msec=20/, 'and asks for a small buffer');
	# WirePlumber restores the last device per application name, so a stream
	# called plain `pacat`/`parec` can be pulled off our sinks by a route some
	# earlier run left behind (measured: the prompt was moved to jawn_call_in
	# at the first word). The helper's streams carry names of their own.
	like($mixer->playback_command(), qr/--client-name=jawn-sco-prompt/,
		'the prompt playback is its own client, not a bare pacat');
	like($mixer->capture_command(), qr/--client-name=jawn-sco-caller/,
		'and the caller capture is its own client, not a bare parec');
	is_deeply($mixer->call_streams(''), { sink_input => undef, source_output => undef },
		'no address means no streams');
	# The helper's pipe mode calls its transport "pcm", and every pulse-compat
	# block contains `Format: pcm`: matching on that moved our own prompt into
	# the caller sink and recorded the greeting. Only an address identifies a
	# stream.
	is_deeply($mixer->call_streams('pcm'), { sink_input => undef, source_output => undef },
		'a transport label is not an address, so it matches no stream');
}

# Moving a stream that is already ours re-links it and drops a word of the
# greeting, so a move happens only when the stream is somewhere else.
{
	require JawnOS::Sco::Mixer;
	my $mixer = JawnOS::Sco::Mixer->new();
	my $moves = '';
	my $sink_on = 3472;
	my $source_on = 3473;
	my $prompt_on = 0;
	my $caller_on = 0;
	my %name = (
		3472 => 'alsa_output.pci-0000_00_1f.3.analog-stereo',
		3657 => 'jawn_call_in',
		3664 => 'jawn_prompt',
		3473 => 'alsa_input.pci-0000_00_1f.3.analog-stereo',
		3672 => 'jawn_ivr_mic',
		3675 => 'jawn_call_in.monitor',
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
			my $out = "Sink Input #41\n\tSink: $sink_on\n\tProperties:\n\t\tdevice.string = \"00:2B:70:E9:7E:B2\"\n\n";
			$out .= "Sink Input #43\n\tSink: $prompt_on\n\tProperties:\n\t\tapplication.name = \"jawn-sco-prompt\"\n\n"
				if $prompt_on;
			return $out;
		}
		if ($line eq 'list source-outputs') {
			my $out = "Source Output #42\n\tSource: $source_on\n\tProperties:\n\t\tdevice.string = \"00:2B:70:E9:7E:B2\"\n\n";
			$out .= "Source Output #44\n\tSource: $caller_on\n\tProperties:\n\t\tapplication.name = \"jawn-sco-caller\"\n\n"
				if $caller_on;
			return $out;
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
	# The session manager has been seen to move the prompt player onto
	# jawn_call_in mid-greeting (the caller hears one word and the rest is
	# recorded); the gateway puts it back on the sink the phone reads.
	$moves = '';
	$prompt_on = 3657;
	my $third = $mixer->attach('00:2B:70:E9:7E:B2');
	is_deeply($third->{'moved'}, [ 'prompt' ], 'a prompt player on the wrong sink is moved back');
	like($moves, qr/move-sink-input 43 jawn_prompt/, 'and that is the move it makes');
	$moves = '';
	$prompt_on = 3664;
	my $fourth = $mixer->attach('00:2B:70:E9:7E:B2');
	is_deeply($fourth->{'moved'}, [], 'a prompt player already on jawn_prompt is left alone');
	is($moves, '', 'with no move');
	# Our capture is the other half: a saved route can park it on jawn_ivr_mic,
	# which is our own prompt, and the "caller" records the greeting.
	$moves = '';
	$caller_on = 3672;
	my $fifth = $mixer->attach('00:2B:70:E9:7E:B2');
	is_deeply($fifth->{'moved'}, [ 'caller' ], 'a capture left on the prompt source is moved back');
	like($moves, qr/move-source-output 44 jawn_call_in\.monitor/, 'and that is the move it makes');
	$moves = '';
	$caller_on = 3675;
	my $sixth = $mixer->attach('00:2B:70:E9:7E:B2');
	is_deeply($sixth->{'moved'}, [], 'a capture already on the call sink is left alone');
	is($moves, '', 'with no move');
	$caller_on = 0;
}

# The card's profile name does not decide the direction. The Table's Intel card
# reports `audio-gateway` even when the phone holds the call and is the Audio
# Gateway, and an earlier version read that name as a cue to swap the two
# streams: the prompt went to the phone's own earpiece and the room was
# recorded instead of the caller. Streaming is the same shape as any HFP card -
# the caller is the sink-input, our prompt is the source-output - so the mixer
# must not consult the card at all.
{
	require JawnOS::Sco::Mixer;
	my $mixer = JawnOS::Sco::Mixer->new();
	my @calls;
	local *JawnOS::Sco::Mixer::pactl = sub {
		my @arg = @_;
		my $line = join ' ', @arg;
		if ($line eq 'list cards') {
			return "Card #473\n\tName: bluez_card.00_2B_70_E9_7E_B2\n\t\tapi.bluez5.address = \"00:2B:70:E9:7E:B2\"\n\tActive Profile: audio-gateway\n";
		}
		if ($line eq 'list short sinks') {
			return "608\tjawn_call_in\tPipeWire\ts16 2ch\tRUNNING\n615\tjawn_prompt\tPipeWire\ts16 2ch\tIDLE\n";
		}
		if ($line eq 'list short sources') {
			return "631\tbluez_input.00_2B_70_E9_7E_B2\tPipeWire\ts16 1ch\tRUNNING\n";
		}
		if ($line eq 'list sink-inputs') {
			return "Sink Input #41\n\tSink: 63\n\tProperties:\n\t\tdevice.string = \"00:2B:70:E9:7E:B2\"\n\n";
		}
		if ($line eq 'list source-outputs') {
			return "Source Output #42\n\tSource: 631\n\tProperties:\n\t\tdevice.string = \"00:2B:70:E9:7E:B2\"\n\n";
		}
		push @calls, $line;
		return '';
	};
	my $streams = $mixer->call_streams('00:2B:70:E9:7E:B2');
	is($streams->{'mode'}, undef, 'an audio-gateway card is not turned into a mode');
	like($mixer->capture_command(), qr/--device=jawn_call_in\.monitor/,
		'the caller is captured from our sink whatever the card says');
	$mixer->attach('00:2B:70:E9:7E:B2');
	ok(grep { $_ eq 'move-sink-input 41 jawn_call_in' } @calls,
		'the caller sink-input is moved to jawn_call_in');
	ok(grep { $_ eq 'move-source-output 42 jawn_ivr_mic' } @calls,
		'and the prompt source-output to jawn_ivr_mic');
	ok($mixer->call_active(), 'the caller sink running means the line is up');
	is_deeply($mixer->{'moved'}, [ 'sink-input', 'source-output' ], 'exactly the two moves');
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
say_line({ event => 'accepted', peer => ($ENV{FAKE_PEER} || '00:11:22:33:44:55') });
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
my $rest_watch = Mojo::IOLoop->recurring(0.05 => sub {
	my $state = $gateway->{'state'} || '';
	return unless $state eq 'done' || $state eq 'idle';
	$stopped = 1;
	Mojo::IOLoop->stop;
});
# a plan that never finishes must fail the test, not hang the suite
my $rest_bell = Mojo::IOLoop->timer(6 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;
# both of those belong to this gateway: left armed, they would stop the loop
# the hold test below starts
Mojo::IOLoop->remove($rest_watch);
Mojo::IOLoop->remove($rest_bell);
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

# ---------------------------------------------------------------- hold music
# After the thanks the caller waits through the house's music while somebody
# decides to pick up. A track is a file on the gateway machine, chosen by the
# phone as a relative path; nothing may name its way out of the library.
require JawnOS::Sco::Hold;
# The house's own library is the fallback when nothing overrides it: the first
# build returned '' here, and only the tests (which set the override) passed.
{
	local $ENV{'JAWNOS_HOLD_MUSIC'};
	delete $ENV{'JAWNOS_HOLD_MUSIC'};
	like(JawnOS::Sco::Hold::music_root(), qr{/Music/Jon Ferwerda$},
		'the library is ~/Music/Jon Ferwerda when nothing points it elsewhere');
}
is_deeply(JawnOS::Sco::Hold::tracks(1), [ 'One.wav', 'Two.wav' ],
	'the library lists the tracks it can play');
is(JawnOS::Sco::Hold::label('Two.wav'), 'Two', 'a track is named by its file, without the extension');
is_deeply(JawnOS::Sco::Hold::playlist('none'), [], 'none is no music');
is_deeply(JawnOS::Sco::Hold::playlist(''), [], 'so is an empty choice');
is(JawnOS::Sco::Hold::in_library('../../etc/passwd'), '', 'a choice cannot leave the library');
is_deeply(JawnOS::Sco::Hold::playlist('../secret.mp3'), [], 'and one that tries plays nothing');
SKIP: {
	skip 'ffmpeg is not installed, so no track can be converted', 4
		unless system('sh', '-c', 'command -v ffmpeg >/dev/null 2>&1') == 0;
	my $all = JawnOS::Sco::Hold::playlist('shuffle');
	is(scalar @{$all}, 2, 'shuffle offers every track');
	ok(!(grep { !-s $_ } @{$all}), 'and each is converted to a raw clip the helper can play');
	my $one = JawnOS::Sco::Hold::playlist('One.wav');
	is(scalar @{$one}, 1, 'one chosen track is one clip');
	ok(-s $one->[0], 'and it is converted too');
}

# A held call: the plan does not run to its end, it plays the next track when
# the helper finishes one, and the state stays in_call.
my $hold_fake = "$dir/hold-helper";
$ENV{'HOLD_PLAYS'} = "$dir/hold-plays";
write_file($hold_fake, <<'HOLDHELPER');
#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP;
my $json = JSON::PP->new;
sub say_line { print $json->encode(shift), "\n"; $| = 1; }
$| = 1;
say_line({ event => 'listening', local => 'fake' });
say_line({ event => 'accepted', peer => '00:11:22:33:44:55' });
my $plays = 0;
while (my $line = <STDIN>) {
	my $cmd = eval { $json->decode($line) } || {};
	my $id = $cmd->{id} || 0;
	my $verb = $cmd->{cmd} || '';
	if ($verb eq 'play' || $verb eq 'tone') {
		select(undef, undef, undef, 0.06);
		say_line({ event => 'played', id => $id, ms => 60 });
		$plays++;
		if ($ENV{HOLD_PLAYS}) {
			open(my $pf, '>', $ENV{HOLD_PLAYS}) or next;
			print {$pf} $plays;
			close $pf;
		}
	}
	elsif ($verb eq 'record') {
		open(my $fh, '>', $cmd->{file}) or next;
		print {$fh} 'RIFF' . ('x' x 40);
		close $fh;
		say_line({ event => 'recorded', id => $id, file => $cmd->{file}, ms => 100, silence => JSON::PP::false });
	}
	elsif ($verb eq 'quit') { last; }
}
exit 0;
HOLDHELPER
chmod 0755, $hold_fake;

my $held = JawnOS::Sco::Gateway->new(
	dir => "$dir/hold-sco",
	helper => $hold_fake,
	status_path => "$dir/hold-sco.json",
);
my $hold_armed = $held->arm(
	local => 'E0:E1:A9:3D:4B:B8',
	clips => { greeting => $clip, prompt => $clip, thanks => $clip },
	record => { ms => 5000 },
	hold => 'shuffle',
	call_id => 'hold-call',
);
is($hold_armed->{'ok'}, 1, 'a gateway arms with hold music');
ok((grep { $_ eq 'hold' } @{ $held->status()->{'plan'} }),
	'and the plan ends with the hold instead of stopping at the thanks');
Mojo::IOLoop->timer(1.6 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;
is($held->{'state'}, 'in_call', 'a held call stays up instead of running to the end of the plan');
ok($held->{'holding'}, 'the gateway knows the caller is on the music');
my $hold_plays = -e $ENV{'HOLD_PLAYS'} ? read_file($ENV{'HOLD_PLAYS'}) : 0;
ok($hold_plays >= 2, 'one track follows another while the hold lasts');
is(JawnOS::Sco::Gateway::call_over('in_call', undef, 100, 1), '',
	'a held call is not ended by the 42 s plan limit');
is(JawnOS::Sco::Gateway::call_over('in_call', undef, 661, 1), 'hold limit',
	'a hold nobody answers still ends');
is(JawnOS::Sco::Gateway::call_over('in_call', undef, 100, 0), 'call limit',
	'an unheld call keeps the old limit');

# A person watching a screening can type to the caller. The gateway answers for
# what it cannot do, and the words join the transcript.
{
	my $say = JawnOS::Sco::Gateway->new(dir => "$dir/say-sco", helper => $hold_fake, status_path => "$dir/say.json");
	is($say->say_to_caller(text => '  ')->{'ok'}, 0, 'an empty message is not spoken');
	is($say->say_to_caller(text => 'hello')->{'ok'}, 0, 'and neither is one with no call up');
	my $src = read_file("$repo/lib/JawnOS/Sco/Gateway.pm");
	like($src, qr/sub say_to_caller/, 'the gateway can speak to the caller');
	like($src, qr/\$self->\{'step_id'\} = \$id/, 'the message takes the step, so the hold resumes after it');
	like(read_file("$repo/public/js/manager/screening.js"), qr{/manager/sco/say},
		'and the panel posts to it');
}

# The app's Hold button: on and off, and a stop the house asked for is not the
# end of the call.
{
	my $h = JawnOS::Sco::Gateway->new(dir => "$dir/hold-sco", helper => $hold_fake, status_path => "$dir/hold-only.json");
	is($h->set_hold(on => 1)->{'ok'}, 0, 'a hold cannot start with no call up');
	$h->{'state'} = 'in_call';
	is($h->set_hold(on => 1)->{'ok'}, 0, 'and not on a call whose plan has no music');
	# a plan that does have a hold step
	$h->{'steps'} = [ { hold => 1, key => 'hold', list => [ $clip ] } ];
	$h->{'step_at'} = 0;
	my $on = $h->set_hold(on => 1);
	is($on->{'ok'}, 1, 'the music starts on demand');
	ok($h->{'holding'}, 'and the call is a held call');
	my $off = $h->set_hold(on => 0);
	is($off->{'ok'}, 1, 'the same button stops it');
	ok($h->{'hold_paused'}, 'leaving the caller the line');
	$h->event({ event => 'stopped' });
	is($h->{'state'}, 'in_call', 'a stop the house asked for does not end the call');
}

# ---------------------------------------------------------- the phone's link
# A phone that walked out of range comes back with its Bluetooth link gone and
# nothing retries the dropped ACL, so the next call has no audio. The gateway
# asks it to connect again, on a backoff.
require JawnOS::Sco::Reconnect;
{
	my @cmds;
	my $up = 0;
	my $r = JawnOS::Sco::Reconnect->new(
		peer => '00:2B:70:E9:7E:B2',
		wait => 30,
		run => sub {
			push @cmds, [@_];
			return $_[0] eq 'info'
				? ($up ? "Connected: yes\n" : "Connected: no\n")
				: do { $up = 1; "Connection successful\n" };
		},
	);
	is($r->tick(1000), 'reconnected', 'a phone that came back is asked to reconnect');
	is_deeply(\@cmds, [ [ 'info', '00:2B:70:E9:7E:B2' ], [ 'connect', '00:2B:70:E9:7E:B2' ] ],
		'it looks first, then asks');
	is($r->tick(1010), 'connected', 'and the next look finds the link up');
	is(scalar(grep { ($_->[0] || '') eq 'connect' } @cmds), 1, 'so it is never asked twice');
	# walking back to the table must not wait five minutes for the next look
	my $far = JawnOS::Sco::Reconnect->new(peer => 'AA:BB:CC:DD:EE:FF', run => sub { "Failed to connect\n" });
	$far->tick(1000);
	for my $at (1030, 1090, 1150, 1210, 1270, 1330) { $far->tick($at); }
	ok($far->{'backoff'} <= 60, 'the retry never waits more than a minute');
}
{
	my $up = JawnOS::Sco::Reconnect->new(peer => 'AA:BB:CC:DD:EE:FF', run => sub { "Connected: yes\n" });
	is($up->tick(1000), 'connected', 'a link that is already up is left alone');

	my @tries;
	my $away = JawnOS::Sco::Reconnect->new(
		peer => 'AA:BB:CC:DD:EE:FF',
		wait => 30,
		run => sub { push @tries, $_[0]; return "Failed to connect: org.bluez.Error.Failed\n" },
	);
	is($away->tick(1000), 'unreachable', 'a phone still away is unreachable');
	is($away->tick(1020), 'too soon', 'the first retry waits');
	is($away->tick(1031), 'unreachable', 'then it asks again after the backoff');
	is(scalar(grep { $_ eq 'connect' } @tries), 2, 'one attempt per backoff, not one per tick');
}
is(JawnOS::Sco::Reconnect->new(peer => '')->tick(1000), '', 'with no address there is nobody to ask');
like(read_file("$repo/perl/Reception.pl"), qr/keep_bluetooth_ready/,
	'the worker that keeps the gateway armed keeps the link up too');
my $hold_status = $held->status;
is(scalar @{ $hold_status->{'hold_tracks'} || [] }, 2,
	'the status names the tracks the pane offers');

# Connect me during the hold: rtc() stops the clip so the person is not talked
# over, and that stop must not take the gateway idle - Reception would arm
# again and cancel the helper under a live, bridged call.
my $bridged = JawnOS::Sco::Gateway->new(
	dir => "$dir/bridged-sco",
	helper => $hold_fake,
	status_path => "$dir/bridged.json",
);
$bridged->{'state'} = 'in_call';
$bridged->{'holding'} = 1;
$bridged->{'rtc_up'} = 1;
$bridged->event({ event => 'stopped' });
is($bridged->{'state'}, 'in_call', 'a stopped clip while somebody is bridged leaves the call up');
is($bridged->{'rtc_up'}, 1, 'and the bridge is left alone');
my $other = JawnOS::Sco::Gateway->new(
	dir => "$dir/plain-sco",
	helper => $hold_fake,
	status_path => "$dir/plain.json",
);
$other->{'state'} = 'in_call';
$other->event({ event => 'stopped' });
is($other->{'state'}, 'idle', 'an unbridged stop still ends the plan');
$held->end_call('test over');

# A call whose line drops ends through `closed`, which does not pass through
# end_call: the flag used to survive into `waiting`, where the next call would
# be excused the 42 s limit without any music at all.
{
	my $dropped = JawnOS::Sco::Gateway->new(
		dir => "$dir/dropped-sco",
		helper => $hold_fake,
		status_path => "$dir/dropped.json",
	);
	$dropped->{'state'} = 'in_call';
	$dropped->{'holding'} = 1;
	$dropped->event({ event => 'closed', reason => 'link' });
	ok(!$dropped->{'holding'}, 'a dropped line clears the hold');
	$dropped->{'holding'} = 1;
	$dropped->arm(clips => { greeting => $clip }, hold => 'shuffle', call_id => 'next-call');
	ok(!$dropped->{'holding'}, 'and so does the next arm');
}

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

# The helper's pipe transport is labelled "pcm" and sent as the peer. Taking it
# replaced the phone's address, and the mixer then searched for a stream called
# "pcm" - which every block satisfies because each says `Format: pcm`. A
# non-address peer must never replace the address the arm pinned.
{
	local $ENV{'FAKE_PEER'} = 'pcm';
	my $pinned = JawnOS::Sco::Gateway->new(
		dir => "$dir/sco-peer",
		helper => $fake,
		status_path => "$dir/sco-peer.json",
	);
	my $peer_armed = $pinned->arm(
		local => 'E0:E1:A9:3D:4B:B8',
		peer => '00:2B:70:E9:7E:B2',
		clips => { greeting => $clip, prompt => $clip, thanks => $clip },
		record => { ms => 5000 },
		call_id => 'peer-call',
	);
	is($peer_armed->{'ok'}, 1, 'a pinned peer arms');
	Mojo::IOLoop->timer(1.5 => sub { Mojo::IOLoop->stop });
	Mojo::IOLoop->start;
	is($pinned->{'peer'}, '00:2B:70:E9:7E:B2',
		'the transport label never replaces the phone address');
	$pinned->cancel();
}

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
	skip 'the SCO helper is not built on this machine', 9 unless -x $helper;
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
	# The narrowband shape a real screened call leaves (clips 1793986149-4312 and
	# 1793986224-ac0f): the line's own floor is near-digital, and the name arrives
	# as bursts whose quieter windows sit well under the old 0.015 margin. The
	# measured windows were 246, 1986, 1391, 157, 103, 115, 1209, 211, 528, 1343,
	# 487, 200 RMS - at 0.015 every one under 750 was invisible, so the clip ran
	# to its ceiling and was filed as silence after the caller had spoken.
	my $room = sub { my ($ms) = @_; return pack('s<', 15) x (8 * $ms) };
	my $speech = sub {
		my ($ms, $rms) = @_;
		my $amp = int(($rms || 500) * 1.4142);
		return join('', map { pack('s<', int(sin(2 * 3.14159 * 220 * $_ / 8000) * $amp)) }
			0 .. int(8 * $ms) - 1);
	};
	# the ceiling sits under the clip, so a missed name reports silence instead
	# of simply running to the end of the file
	my $narrow = $record->('narrow',
		$room->(500) . $room->(1500)
			. $speech->(300) . $room->(120) . $speech->(400) . $room->(6000),
		ms => 8000, silence_ms => 2000, min_ms => 400);
	ok($narrow > 60000 && $narrow < 96000,
		'a quiet narrowband name is recorded and ends on its pause, not the ceiling');
	like($last_events, qr/"silence":false/,
		'and the clip that ends on the pause after it is a name');
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

# The line is kept fed between prompts, not only while a clip plays. A source
# that goes quiet lets the phone's own buffer drain, and the tail it still holds
# is lost - measured: the end of the greeting and of the name prompt were cut
# off. A real headset sends silence between words, so the helper does too.
SKIP: {
	skip 'the SCO helper is not built on this machine', 3 unless -x $helper;
	require IPC::Open2;
	my $fed = "$dir/pipe-fed.raw";
	unlink $fed;
	my $clip = "$dir/pipe-clip.raw";
	my $pattern = join '', map { pack('s<', 8000) } 1 .. 600;   # 1200 bytes, no zeros
	write_file($clip, $pattern);
	my ($out, $in);
	my $pid = IPC::Open2::open2($out, $in, $helper,
		'--pipe-in', 'cat /dev/zero', '--pipe-out', "cat > $fed");
	$in->autoflush(1);
	print {$in} '{"cmd":"line"}' . "\n";
	select(undef, undef, undef, 2.6);   # the settle runs from the first frame
	print {$in} '{"cmd":"play","id":1,"file":"' . $clip . '"}' . "\n";
	select(undef, undef, undef, 1.0);
	print {$in} '{"cmd":"quit"}' . "\n";
	close $in;
	close $out;
	waitpid($pid, 0);
	my $raw = '';
	if (open(my $rf, '<:raw', $fed)) { local $/; $raw = <$rf> // ''; close $rf; }
	ok(length $raw > 4000, 'the line is fed with silence around a clip, so it never idles');
	ok(index($raw, $pattern) >= 0, 'and the clip itself is delivered whole');
	ok(-s $fed > 4000, 'the feed is what the playback command receives');
}

# The transcript taps the caller, not the plan. The hold music is one long clip,
# and the caller talking over it has to still be heard: the tee is written from
# every downlink frame, whatever the uplink is doing.
SKIP: {
	skip 'the SCO helper is not built on this machine', 2 unless -x $helper;
	require IPC::Open2;
	my $tee = "$dir/tee-while-playing.raw";
	# the helper opens the tee path without O_CREAT (the gateway makes a FIFO
	# there first), so the probe has to bring its own file
	write_file($tee, '');
	my $music = "$dir/tee-music.raw";
	write_file($music, join '', map { pack('s<', 7000) } 1 .. 32000);   # 4 s of music
	my $feeder = "$dir/tee-feeder.pl";
	write_file($feeder, <<'FEED2');
#!/usr/bin/perl
# the caller's side, in real time: a second of room, then speech, then room,
# while the gateway is busy playing the music
for (1 .. 50)  { print pack('s<', 0)    x 160; select(undef, undef, undef, 0.02); }
for (1 .. 75)  { print pack('s<', 9000) x 160; select(undef, undef, undef, 0.02); }
for (1 .. 100) { print pack('s<', 0)    x 160; select(undef, undef, undef, 0.02); }
FEED2
	chmod 0755, $feeder;
	my ($out, $in);
	my $pid = IPC::Open2::open2($out, $in, $helper,
		'--pipe-in', $feeder, '--pipe-out', 'cat > /dev/null', '--tee', $tee);
	$in->autoflush(1);
	print {$in} '{"cmd":"line"}' . "\n";
	select(undef, undef, undef, 0.4);
	print {$in} '{"cmd":"play","id":1,"file":"' . $music . '"}' . "\n";
	select(undef, undef, undef, 3.0);
	print {$in} '{"cmd":"quit"}' . "\n";
	close $in;
	close $out;
	waitpid($pid, 0);
	my $raw = '';
	if (open(my $tf, '<:raw', $tee)) { local $/; $raw = <$tf> // ''; close $tf; }
	ok(length $raw > 8000, 'the caller is tapped while a clip is playing');
	ok(index($raw, pack('s<', 9000) x 400) >= 0, 'and the words said over it arrive');
}

done_testing();
