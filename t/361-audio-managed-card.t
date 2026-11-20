# tests-for: lib/JawnOS/Domain/Audio.pm lib/JawnOS/Audio/SystemMix.pm
# covers:    the card rule's mode: a local input routed to a bus or bound
#            interface/speakers needs duplex (both nodes), while a plan whose
#            inputs live on another machine, or whose route is muted or to an
#            unbound sink, needs playback only. A running engine on a different
#            backend/device is asked to quit so the supervisor respawns on the
#            saved choice; a matching engine is patched without a quit.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP ();

require JawnOS::Audio::Engine;
require JawnOS::Audio::SystemMix;
require JawnOS::Domain::Audio;

# The domain reads only these two helpers; this is the whole database it needs.
our %STORE;
{
	package subs;
	sub setting_setter {
		my ($settings) = @_;
		my $key = join '/', $settings->{'app'} // '', $settings->{'setting'} // '',
			$settings->{'device'} // '';
		$main::STORE{$key} = $settings->{'value'};
		return;
	}
	sub setting_grabber {
		my ($settings) = @_;
		my $key = join '/', $settings->{'app'} // '', $settings->{'setting'} // '',
			$settings->{'device'} // '';
		return $main::STORE{$key};
	}
}

# Nothing here may reach the host's PulseAudio/WirePlumber: the engine is a
# fake, and the supervisor's state directory is a tempdir.
my $scratch = tempdir(CLEANUP => 1);
local $ENV{HOME} = $scratch;
local $ENV{JAWNOS_AUDIO_PLAN} = "$scratch/audio-plan.json";
local $ENV{JAWNOS_WIREPLUMBER_DIR} = "$scratch/wireplumber";
local $ENV{JAWNOS_SYSTEMCTL} = '';
local $ENV{PATH} = tempdir(CLEANUP => 1);

# --- the plan's mode mirrors Patchbay::wants_input ---------------------------
{
	my $table = {
		sources => [
			{ id => 'gtr', kind => 'input', machine => 'table', channel => 0 },
		],
		buses => [ { id => 'house' } ],
		sinks => [ { id => 'out', kind => 'interface', machine => 'table', channel => 0 } ],
		routes => [ { from => 'gtr', to => 'house' } ],
	};
	is(JawnOS::Audio::SystemMix::plan_mode($table, 'table'), 'duplex',
		'a local input routed to a bus needs capture');

	my $laptop = {
		sources => [
			{ id => 'gtr', kind => 'input', machine => 'table', channel => 0 },
			{ id => 'mix', kind => 'device' },
		],
		buses => [ { id => 'house' } ],
		sinks => [ { id => 'out', kind => 'interface', channel => 0 } ],
		routes => [
			{ from => 'gtr', to => 'house' },
			{ from => 'mix', to => 'house' },
		],
	};
	is(JawnOS::Audio::SystemMix::plan_mode($laptop, 'vivotop'), 'playback',
		'an input that lives on another machine needs playback only');
	is(JawnOS::Audio::SystemMix::plan_mode($laptop, 'table'), 'duplex',
		'the same plan on its own machine needs capture');

	my $speakers = {
		sources => [ { id => 'gtr', kind => 'input', channel => 0 } ],
		buses   => [],
		sinks   => [ { id => 'spk', kind => 'speakers', channel => 0 } ],
		routes  => [ { from => 'gtr', to => 'spk' } ],
	};
	is(JawnOS::Audio::SystemMix::plan_mode($speakers, ''), 'duplex',
		'a local input routed to bound speakers needs capture');

	my $zone = {
		sources => [ { id => 'gtr', kind => 'input', channel => 0 } ],
		buses   => [],
		sinks   => [ { id => 'amp', kind => 'zone', channel => 0 } ],
		routes  => [ { from => 'gtr', to => 'amp' } ],
	};
	is(JawnOS::Audio::SystemMix::plan_mode($zone, ''), 'playback',
		'a route to an unbound zone needs playback only');

	my $muted = {
		sources => [ { id => 'gtr', kind => 'input', channel => 0 } ],
		buses   => [ { id => 'house' } ],
		sinks   => [],
		routes  => [ { from => 'gtr', to => 'house', mute => 1 } ],
	};
	is(JawnOS::Audio::SystemMix::plan_mode($muted, ''), 'playback',
		'a muted route needs playback only');

	my $device = {
		sources => [ { id => 'mix', kind => 'device' } ],
		buses   => [ { id => 'house' } ],
		sinks   => [],
		routes  => [ { from => 'mix', to => 'house' } ],
	};
	is(JawnOS::Audio::SystemMix::plan_mode($device, ''), 'playback',
		'a device source is not a hardware input');

	my $unrouted = {
		sources => [ { id => 'gtr', kind => 'input', channel => 0 } ],
		buses   => [ { id => 'house' } ],
		sinks   => [],
		routes  => [],
	};
	is(JawnOS::Audio::SystemMix::plan_mode($unrouted, ''), 'playback',
		'an unrouted input needs playback only');
}

# --- a device change while manage is on asks the old engine to quit ---------
{
	my $plan = {
		sources => [ { id => 'gtr', kind => 'input', channel => 0 } ],
		buses   => [ { id => 'house' } ],
		sinks   => [],
		routes  => [ { from => 'gtr', to => 'house' } ],
	};
	%STORE = (
		'sound/audio_plan/all'   => JSON::PP->new->encode($plan),
		'sound/audio_manage/all' => '1',
	);
	# The saved choice the supervisor will use on its next spawn.
	open(my $fh, '>', $ENV{JAWNOS_AUDIO_PLAN}) or die "boot plan: $!";
	print {$fh} JSON::PP->new->encode({
		manage => 1, plan => $plan, backend => 'alsa', device => 'hw:0,0',
	});
	close $fh;

	our ($quit_count, $patch_count);
	$quit_count  = 0;
	$patch_count = 0;
	{
		no warnings 'redefine';
		local *JawnOS::Audio::Engine::audio_engine_available = sub { 1 };
		local *JawnOS::Audio::Engine::audio_engine_status = sub {
			return {
				ok => 1, state => 'patching', mode => 'playback',
				backend => 'pipewire', device => 'default',
			};
		};
		local *JawnOS::Audio::Engine::audio_engine_quit = sub {
			$main::quit_count++;
			return { ok => 1 };
		};
		local *JawnOS::Audio::Engine::audio_engine_patch = sub {
			$main::patch_count++;
			return { ok => 1, state => 'patching' };
		};

		my $on = subs::audio_manage_set(1);
		is($on->{ok}, 1, 'turning the switch on succeeds');
		is($on->{applied}{restarted}, 1, 'the mismatch is reported as a restart');
		is($main::quit_count, 1, 'the old engine is asked to quit');
		is($main::patch_count, 0, 'and is not patched on the wrong device');
	}

	# A matching engine (the prefixed device form is the same choice) is
	# patched, not restarted.
	$quit_count  = 0;
	$patch_count = 0;
	{
		no warnings 'redefine';
		local *JawnOS::Audio::Engine::audio_engine_available = sub { 1 };
		local *JawnOS::Audio::Engine::audio_engine_status = sub {
			return {
				ok => 1, state => 'patching', mode => 'playback',
				backend => 'alsa', device => 'alsa|hw:0,0',
			};
		};
		local *JawnOS::Audio::Engine::audio_engine_quit = sub {
			$main::quit_count++;
			return { ok => 1 };
		};
		local *JawnOS::Audio::Engine::audio_engine_patch = sub {
			$main::patch_count++;
			return { ok => 1, state => 'patching' };
		};

		subs::audio_manage_set(1);
		is($main::quit_count, 0, 'a matching device does not restart the engine');
		is($main::patch_count, 1, 'and the plan is applied to the running engine');
	}
}

# --- the manager installs the duplex union during a transition --------------
{
	my $playback_plan = {
		sources => [ { id => 'mix', kind => 'device' } ],
		buses   => [ { id => 'house' } ],
		sinks   => [],
		routes  => [ { from => 'mix', to => 'house' } ],
	};
	my $duplex_plan = {
		sources => [ { id => 'gtr', kind => 'input', channel => 0 } ],
		buses   => [ { id => 'house' } ],
		sinks   => [],
		routes  => [ { from => 'gtr', to => 'house' } ],
	};

	sub apply_with_modes {
		my ($plan, $status_mode) = @_;
		%STORE = (
			'sound/audio_plan/all'   => JSON::PP->new->encode($plan),
			'sound/audio_manage/all' => '1',
		);
		open(my $fh, '>', $ENV{JAWNOS_AUDIO_PLAN}) or die "boot plan: $!";
		print {$fh} JSON::PP->new->encode({
			manage => 1, plan => $plan, backend => 'alsa', device => 'hw:0,0',
		});
		close $fh;

		my ($ensure_mode, $patches, $quits);
		$patches = 0;
		$quits   = 0;
		{
			no warnings 'redefine';
			local *JawnOS::Audio::Engine::audio_engine_available = sub { 1 };
			local *JawnOS::Audio::Engine::audio_engine_status = sub {
				return {
					ok => 1, state => 'patching',
					backend => 'alsa', device => 'hw:0,0', mode => $status_mode,
				};
			};
			local *JawnOS::Audio::Engine::audio_engine_quit = sub {
				$quits++;
				return { ok => 1 };
			};
			local *JawnOS::Audio::Engine::audio_engine_patch = sub {
				$patches++;
				return { ok => 1, state => 'patching' };
			};
			local *JawnOS::Audio::SystemMix::ensure = sub {
				my ($dir, $device, $mode) = @_;
				$ensure_mode = $mode;
				return { ok => 1, source => 'jawn_system.monitor' };
			};
			subs::audio_manage_set(1);
		}
		return ($ensure_mode, $patches, $quits);
	}

	my ($ensure, $patches, $quits)
		= apply_with_modes($playback_plan, 'duplex');
	is($ensure, 'duplex', 'plan playback plus engine duplex provisions capture');
	is($patches, 1, 'the plan is still applied');
	is($quits, 0, 'and the matching device is not restarted');

	($ensure, $patches, $quits) = apply_with_modes($duplex_plan, 'playback');
	is($ensure, 'duplex', 'plan duplex plus engine playback provisions capture');
	is($patches, 1, 'the new duplex plan is applied without failure');
	is($quits, 0, 'and the device still matches');

	($ensure, $patches, $quits) = apply_with_modes($playback_plan, 'playback');
	is($ensure, 'playback', 'only when both say playback is the rule sink-only');
	is($patches, 1, 'and the plan is applied');
}

done_testing();
