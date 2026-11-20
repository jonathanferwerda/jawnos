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
use Mojo::Template;

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
my $engine = JawnOS::Sco::Backend->new(backend => 'engine');
is($engine->name, 'engine', 'an engine backend names itself');
{
	my ($ready, $why) = $engine->ready();
	ok(!$ready, 'the engine backend is never ready');
	like($why, qr/has no gateway ports yet/,
		'because the engine has no way to bind the caller streams');
}
foreach my $role (qw(prepare attach in out monitor status release)) {
	my @answer = $engine->$role('00:11:22:33:44:55');
	is($answer[0], 0, "the engine's $role answers not-ready");
	like($answer[1], qr/has no gateway ports yet/, "and $role gives the same honest reason");
}

# --------------------------------------------------------------- the crew advert
{
	my $abilities = crew::abilities({ refresh => 1 });
	my $ivr = $abilities->{'ivr'};
	is(ref $ivr, 'HASH', 'the crew advert carries the ivr ability');
	foreach my $key (qw(ready ready_note)) {
		ok(exists $ivr->{$key}, "the ivr ability carries $key");
	}
	like($ivr->{'audio'}, qr/^(?:pipewire)?$/, 'audio stays the stack word');
	ok($ivr->{'ready'} eq '0' || $ivr->{'ready'} eq '1' || $ivr->{'ready'} == 0 || $ivr->{'ready'} == 1,
		'ready is a 0/1 answer');
	ok(!$ivr->{'able'} || $ivr->{'ready'}, 'able implies ready');
	ok($ivr->{'ready'} || length($ivr->{'ready_note'}),
		'a not-ready advert carries a reason');
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
