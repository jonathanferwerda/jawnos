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
JawnOS::Sco::Render::prune();

# ------------------------------------------------------------- the gateway
# A stand-in helper that speaks the protocol: it listens, accepts at once, and
# answers each command, so the gateway's plan can be walked without a radio.
my $fake = "$dir/fake-helper";
write_file($fake, <<'FAKE');
#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP;
my $json = JSON::PP->new;
sub say_line { print $json->encode(shift), "\n"; $| = 1; }
$| = 1;
say_line({ event => 'listening', local => 'fake' });
select(undef, undef, undef, 0.05);
say_line({ event => 'accepted', peer => '00:11:22:33:44:55' });
while (my $line = <STDIN>) {
	my $cmd = eval { $json->decode($line) } || {};
	my $id = $cmd->{id} || 0;
	if (($cmd->{cmd} || '') eq 'play') {
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

# ------------------------------------------------------- the real helper
my $helper = "$repo/perl/sco/sco_helper";
SKIP: {
	skip 'the SCO helper is not built on this machine', 3 unless -x $helper;
	my $down = "$dir/down.raw";
	my $samples = 8000;    # one second of a tone, then a second of quiet
	open(my $raw, '>', $down) or die "$down: $!";
	binmode $raw;
	for my $i (0 .. $samples - 1) { print {$raw} pack('s<', int(sin(2 * 3.14159 * 440 * $i / 8000) * 8000)); }
	print {$raw} pack('s<', 0) x 16000;
	close $raw;
	my $out = "$dir/loopback.wav";
	my $fh;
	my $child = open($fh, '|-', $helper, '--loopback', $down, '--fast');
	print {$fh} JSON::PP->new->encode({ cmd => 'record', id => 1, file => $out, ms => 5000,
		silence_ms => 300, min_ms => 300 }) . "\n";
	close $fh;
	ok(-s $out, 'the helper records the downlink in loopback');
	open(my $wav, '<', $out) or die "$out: $!";
	binmode $wav;
	seek($wav, 44, 0);
	local $/;
	my $pcm = <$wav>;
	close $wav;
	ok(length($pcm) > 16000, 'the clip holds the caller');
	ok(length($pcm) <= 24000, 'the clip stops at the silence, not at the maximum');
}

done_testing();
