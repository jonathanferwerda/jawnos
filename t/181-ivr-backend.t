# tests-for: lib/JawnOS/Sco/Backend.pm perl/crew.pl lib/JawnOS/Controller/manager_phone.pm templates/apps/phone.html.ep perl/help/topics_web.pl
# covers:    The audio backend seam: pactl readiness and its reasons, the engine's
#            honest not-ready answer, the crew advert's ready/ready_note, the pane's
#            audio line and the help sentence. The pactl roles are thin Mixer calls
#            and are not executed here (they would reach pactl); readiness is.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use Mojo::Template;
use POSIX qw(_exit);

use RepoSource;
use JawnOSTest;
use lib root() . '/lib';

use JawnOS::Sco::Backend;

require(root() . '/perl/crew.pl');
require(root() . '/lib/JawnOS/Manager/Part12.pm');

# --------------------------------------------------------------- the pactl seam
my $pactl = JawnOS::Sco::Backend->new(
	backend => 'pactl', helper => 1, adapter => 1, pactl => 1,
);
is($pactl->name, 'pactl', 'a pactl backend names itself');
is($pactl->audio, 'pipewire', 'and names the PipeWire stack the advert shows');
{
	my ($ready, $why) = $pactl->ready();
	ok($ready, 'it is ready when the helper, an adapter and pactl are present');
	ok(!defined $why, 'with no reason to give');
}

# A missing prerequisite is not ready, and the reason names the one that is
# missing: a person reading the pane can fix it.
foreach my $case (
	[ helper  => 'the audio helper is not built' ],
	[ adapter => 'no Bluetooth adapter is present' ],
	[ pactl   => 'pactl is not installed' ],
) {
	my ($key, $reason) = @{$case};
	my %args = (backend => 'pactl', helper => 1, adapter => 1, pactl => 1);
	$args{$key} = 0;
	my $backend = JawnOS::Sco::Backend->new(%args);
	my ($ready, $why) = $backend->ready();
	ok(!$ready, "without $key the backend is not ready");
	ok(defined $why && length $why, "and it says why ($key)");
	is($why, $reason, "the reason names $key");
}

# --------------------------------------------------------------- the engine seam
# A mock engine answers one status line; the helper is a file whose usage text
# either names `--engine` or does not, which is exactly the check readiness makes.
my @engine_pids;
END { kill 'KILL', grep { defined } @engine_pids }

sub engine_helper_file {
	my ($with_engine) = @_;
	my $dir = tempdir(CLEANUP => 1);
	my $path = "$dir/sco_helper";
	open(my $fh, '>', $path) or die "$path: $!";
	print {$fh} $with_engine ? "usage: sco_helper --engine DIR\n" : "usage: sco_helper --pipe-in CMD\n";
	close $fh;
	chmod 0755, $path;
	return $path;
}

sub start_engine {
	my ($capable) = @_;
	my $dir  = tempdir(CLEANUP => 1);
	my $path = "$dir/audio.sock";
	my $pid  = fork();
	die "fork: $!" unless defined $pid;
	if (!$pid) {
		my $listener = IO::Socket::UNIX->new(
			Type => SOCK_STREAM, Local => $path, Listen => 5,
		) or _exit(1);
		while (my $client = $listener->accept) {
			my $line = <$client>;
			next unless defined $line;
			my $cap = $capable ? 'true' : 'false';
			print {$client} '{"ok":true,"gateway":{"call_in":"off","prompt":"silent",'
				. '"monitor":"helper","capable":' . $cap . '}}' . "\n";
			close $client;
		}
		_exit(0);
	}
	push @engine_pids, $pid;
	my $deadline = time + 3;
	until (-S $path) {
		last if time > $deadline;
		select undef, undef, undef, 0.01;
	}
	die "mock engine did not listen on $path\n" unless -S $path;
	return ($path, $pid);
}

my $with_engine = engine_helper_file(1);
my $without_engine = engine_helper_file(0);

my $engine = JawnOS::Sco::Backend->new(
	backend => 'engine', helper => 1, adapter => 1, helper_path => $with_engine,
);
is($engine->name, 'engine', 'an engine backend names itself');
is($engine->audio, 'engine', 'and names the engine stack the advert shows');

# A gateway with no adapter can never take the Hands-Free link, so its ports
# cannot make it ready. The reason is the pactl branch's own sentence.
{
	my $no_adapter = JawnOS::Sco::Backend->new(
		backend => 'engine', helper => 1, adapter => 0, helper_path => $with_engine,
	);
	my ($ready, $why) = $no_adapter->ready();
	ok(!$ready, 'an engine with no Bluetooth adapter is not ready');
	is($why, 'no Bluetooth adapter is present', 'and gives the same reason the pactl branch gives');
}

{
	my ($path, $pid) = start_engine(1);
	local $ENV{JAWNOS_AUDIO_SOCKET} = $path;
	my ($ready, $why) = $engine->ready();
	ok($ready, 'the engine is ready when its socket answers capable');
	ok(!defined $why, 'with no reason to give');
	kill 'KILL', $pid;
	waitpid($pid, 0);
	$engine_pids[-1] = undef;
}

{
	my ($path, $pid) = start_engine(0);
	local $ENV{JAWNOS_AUDIO_SOCKET} = $path;
	my ($ready, $why) = $engine->ready();
	ok(!$ready, 'an engine that cannot carry the gateway is not ready');
	like($why, qr/parec and pacat/, 'and says which tools it is missing');
	kill 'KILL', $pid;
	waitpid($pid, 0);
	$engine_pids[-1] = undef;
}

{
	my $dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_AUDIO_SOCKET} = "$dir/not-here.sock";
	my ($ready, $why) = $engine->ready();
	ok(!$ready, 'a machine with no engine socket does not claim the engine');
	like($why, qr/not running/, 'and says the engine is not running');
}

{
	my ($path, $pid) = start_engine(1);
	local $ENV{JAWNOS_AUDIO_SOCKET} = $path;
	my $old = JawnOS::Sco::Backend->new(
		backend => 'engine', helper => 1, adapter => 1, helper_path => $without_engine,
	);
	my ($ready, $why) = $old->ready();
	ok(!$ready, 'an engine-capable socket with a helper built without --engine is not ready');
	is($why, $JawnOS::Sco::Backend::ENGINE_NO_HELPER, 'and says the helper is the half that is missing');
	kill 'KILL', $pid;
	waitpid($pid, 0);
	$engine_pids[-1] = undef;
}

# A helper rebuilt at the same path must not stay cached as stale for the life
# of a manager: the cache is keyed by path, mtime and size.
{
	my $path = engine_helper_file(1);
	my $rebuilt = JawnOS::Sco::Backend->new(
		backend => 'engine', helper => 1, adapter => 1, helper_path => $path,
	);
	ok($rebuilt->helper_engine_capable(), 'the staged helper names --engine');
	open(my $fh, '>', $path) or die "$path: $!";
	print {$fh} "usage: --pipe-in CMD\n";
	close $fh;
	chmod 0755, $path;
	ok(!$rebuilt->helper_engine_capable(), 'a helper rebuilt in place is read again, not served stale');
}

# Once ready, the engine backend keeps the mixer's jobs: the null sinks, the
# stream moves and the call's own liveness. Only the two `in`/`out` commands are
# the transport's, and the engine carries those on its FIFOs.
{
	package FakeMixer;
	sub new { bless {}, shift }
	sub ensure { 2 }
	sub attach { my ($self, $address) = @_; return { ok => 1, streams => 2, moved => 1, address => $address } }
	sub call_active { 1 }
	sub detach { 1 }
	sub capture_command { 'CAT' }
	sub playback_command { 'PLAY' }
}
my $roles = JawnOS::Sco::Backend->new(
	backend => 'engine', helper => 1, adapter => 1, helper_path => $with_engine, mixer => FakeMixer->new(),
);
is($roles->prepare, 2, 'prepare keeps loading the mixer sinks');
is_deeply($roles->attach('00:11:22:33:44:55'),
	{ ok => 1, streams => 2, moved => 1, address => '00:11:22:33:44:55' },
	'attach keeps moving the call streams');
is($roles->status->{'active'}, 1, 'status still reads the caller sink');
is($roles->release, 1, 'release still puts the streams back');
is($roles->monitor, '', 'the monitor is still the helper tee, not a second bus');
foreach my $role (qw(in out)) {
	my @answer = $roles->$role();
	is($answer[0], 0, "the engine's $role has no command to return");
	like($answer[1], qr/parec and pacat|engine cannot carry/, "and $role says where the PCM comes from");
}

# --------------------------------------------------------------- the crew advert
{
	my $abilities = crew::abilities({ refresh => 1 });
	my $ivr = $abilities->{'ivr'};
	is(ref $ivr, 'HASH', 'the crew advert carries the ivr ability');
	foreach my $key (qw(ready ready_note)) {
		ok(exists $ivr->{$key}, "the ivr ability carries $key");
	}
	like($ivr->{'audio'}, qr/^(?:pipewire|engine)?$/, 'audio is one of the two stack words');
	ok($ivr->{'ready'} eq '0' || $ivr->{'ready'} eq '1' || $ivr->{'ready'} == 0 || $ivr->{'ready'} == 1,
		'ready is a 0/1 answer');
	ok(!$ivr->{'able'} || $ivr->{'ready'}, 'able implies ready');
	ok($ivr->{'ready'} || length($ivr->{'ready_note'}),
		'a not-ready advert carries a reason');
}

# An engine-ready machine advertises the engine; anything else keeps the pactl
# word. The choice lives in one place, so the pane and the phone agree.
{
	local *JawnOS::Sco::Backend::ready = sub { return (1) };
	my $abilities = crew::abilities({ refresh => 1 });
	is($abilities->{'ivr'}{'audio'}, 'engine',
		'an engine-ready machine advertises engine audio');
	ok($abilities->{'ivr'}{'ready'}, 'and says it is ready');
}

# --------------------------------------------------------------- the pane's state
{
	local *Manager::phone_self_signatorial = sub { return 'me' };
	local *crew::advert_get = sub {
		my ($key) = @_;
		return undef unless $key eq 'gw-sig';
		return {
			abilities => {
				ivr => {
					audio => 'engine', ready => 0,
					ready_note => 'the engine has no gateway ports yet',
				},
			},
		};
	};
	require(root() . '/lib/JawnOS/Controller/manager_phone.pm');
	my $state = Manager::_ivr_audio_state({}, 'gw-sig');
	is($state->{'backend'}, 'engine', 'a remote gateway backend comes from its advert');
	is($state->{'audio'}, 'engine', 'and its audio word does too');
	is($state->{'ready'}, 0, 'readiness follows the advert, not this machine');
	like($state->{'ready_note'}, qr/no gateway ports yet/, 'with the advert\'s own reason');
}
{
	local *Manager::phone_self_signatorial = sub { return 'me' };
	local *crew::advert_get = sub { return undef };
	my $state = Manager::_ivr_audio_state({}, 'gw-sig');
	is($state->{'backend'}, '', 'a gateway that never advertised gets no invented backend');
	is($state->{'ready'}, 0, 'and is not ready');
	like($state->{'ready_note'}, qr/has not reported/, 'with a note that says so');
}

# The local pane asks the same way the advert does: the engine first, then the
# pactl fallback, so a gateway's own page cannot disagree with its advert.
{
	local *JawnOS::Sco::Backend::ready = sub {
		return $_[0]->name eq 'engine' ? (1) : (0, 'pactl is not installed');
	};
	my $state = Manager::_ivr_audio_state({}, '');
	is($state->{'backend'}, 'engine', 'the local pane prefers the engine when it is ready');
	is($state->{'audio'}, 'engine', 'and shows the engine word');
	ok($state->{'ready'}, 'and is ready');
}
{
	local *JawnOS::Sco::Backend::ready = sub {
		return $_[0]->name eq 'engine' ? (0, 'the audio engine is not running on this machine') : (1);
	};
	my $state = Manager::_ivr_audio_state({}, '');
	is($state->{'backend'}, 'pactl', 'a not-ready engine leaves the local pane on pactl');
	ok($state->{'ready'}, 'and the pactl backend is still asked');
}

# The gateway sends the phone channel's gain on the bind, so the engine's
# prompt pacat can carry the same level the helper's does.
{
	require(root() . '/lib/JawnOS/Sco/Gateway.pm');
	my $dir = tempdir(CLEANUP => 1);
	my $gw = JawnOS::Sco::Gateway->new(
		dir => "$dir/sco", helper => '/bin/false', status_path => "$dir/sco.json", pipe => 1,
	);
	$gw->{'engine_backend'} = bless({}, 'EngineReady');
	$gw->{'mixer'} = bless({}, 'GainMixer');
	no warnings 'once';
	local *GainMixer::playback_volume = sub { 37 };
	my $captured;
	local *JawnOS::Sco::Gateway::_engine_request = sub {
		my ($self, $request) = @_;
		$captured = $request;
		return { ok => 1, gateway => {
			call_in => 'silent',
			paths => { call_in => '/p/call_in', prompt => '/p/prompt' } } };
	};
	$gw->_engine_begin();
	$gw->_engine_stop_wait();
	is($captured->{'cmd'}, 'gateway', 'the gain rides the gateway command');
	is($captured->{'action'}, 'bind', 'on the bind');
	is($captured->{'volume'}, 37, 'the bind request carries the phone channel gain');
	is($captured->{'call_in'}, 'jawn_call_in', 'and names the call sink');
	is($captured->{'prompt'}, 'jawn_prompt', 'and the prompt sink');
	$gw->cancel();
}

# --------------------------------------------------------------- the pane wording
{
	my $ivr;
	{
		local *subs::setting_grabber = sub { return undef };
		$ivr = Manager::phone_ivr_settings();
	}
	$ivr->{'machine'} = 'gw-sig';
	$ivr->{'machine_label'} = 'gateway';
	$ivr->{'machine_available'} = 1;
	$ivr->{'audio'} = 'pipewire';
	$ivr->{'backend'} = 'pactl';
	$ivr->{'ready'} = 1;
	$ivr->{'ready_note'} = '';

	my $render = sub {
		my $mt = Mojo::Template->new(vars => 1, auto_escape => 1);
		return $mt->render_file(
			root() . '/templates/apps/phone.html.ep',
			{
				calls => [], known => [], numbers => [], blocked => [],
				ivr => $ivr,
				ringtone => 'notifications/ring.mp3',
				own_lines => [],
				ivr_machines => [],
				ivr_candidates => [],
				ivr_voices => [ &subs::say_voices() ],
				caller_choices => [],
			},
		);
	};

	my $out = eval { $render->() };
	is($@, '', 'the Phone template renders with the audio line');
	like($out, qr/class="phone_app_ivr_audio"/, 'the IVR status line names the audio backend');
	like($out, qr/Audio:\s*pipewire.*ready/s, 'and says pipewire is ready');

	$ivr->{'audio'} = '';
	$ivr->{'ready'} = 0;
	$ivr->{'ready_note'} = 'pactl is not installed';
	$out = eval { $render->() };
	is($@, '', 'the template renders a not-ready backend');
	like($out, qr/Audio: not ready/, 'the line says it is not ready');
	like($out, qr/pactl is not installed/, 'and gives the reason');
}

# --------------------------------------------------------------- the help topic
my $help = help_source();
like($help, qr/which audio backend the gateway uses and whether it is ready/,
	'the IVR help topic explains audio readiness');
like($help, qr/Two gateways that share a Bluetooth name are flagged, because the phone can only answer on the first one it bonded\./,
	'and warns that a shared Bluetooth name is flagged');

# --------------------------------------------------------------- the wiring
my $crew = read_file(root() . '/perl/crew.pl');
like($crew, qr/JawnOS::Sco::Backend/, 'the advert asks the backend for readiness');
like($crew, qr/\$ivr\{'able'\}\s*=\s*\(\$audio_ready/, 'able is readiness plus the load check');

my $controller = read_file(root() . '/lib/JawnOS/Controller/manager_phone.pm');
like($controller, qr/_ivr_audio_state\(\$ivr/, 'the pane payload is filled from the backend state');
like($controller, qr/\$ivr->\{'ready_note'\}/, 'the payload carries the reason');

done_testing();
