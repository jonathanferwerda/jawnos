# tests-for: lib/JawnOS/Domain/Audio.pm lib/JawnOS/Audio/Plan.pm lib/JawnOS/Audio/Engine.pm lib/JawnOS/Controller/manager_sound.pm lib/JawnOS/Routes/manager_sound.pm templates/apps/sound.html.ep public/js/manager/sound.js public/js/manager/sound/01_patchbay.js perl/help/topics_apps.pl engine/src/patchbay.rs engine/src/system_capture.rs
# covers:    the saved house plan (docs/studio-audio-roadmap.md §8): a default plan reads as four
#            empty lists, a valid plan saves on the house row, a dangling route is refused, the
#            master switch is the only thing that applies an engine patch, a sink's declared
#            latency adds up from its source, and the engine client spells "patch" and "stop".

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use JSON::PP ();
use RepoSource ();

my $root = "$FindBin::Bin/..";

# Point the engine's startup copy at a scratch file, so the domain writes the
# boot plan on every save and switch without touching the real ~/.president.
my $scratch = tempdir(CLEANUP => 1);
local $ENV{JAWNOS_AUDIO_PLAN} = "$scratch/audio-plan.json";

# A fixture for the ALSA card list, so the device picker is testable on a
# machine with no sound card (and on CI, which always has none).
my $cards = "$scratch/asound-cards";
open(my $cards_fh, '>', $cards) or die "cards fixture: $!";
print {$cards_fh} " 0 [PCH            ]: HDA-Intel - HDA Intel PCH\n";
print {$cards_fh} " 1 [UM2            ]: USB-Audio - BEHRINGER UMC 202HD 192k\n";
close $cards_fh;
local $ENV{JAWNOS_ASOUND_CARDS} = $cards;

# One in-memory settings table, keyed the way setting_grabber/setter write,
# and this machine's name for the device-scoped rows. The domain module under
# test reads only these three helpers, so this is the whole database it needs.
our %STORE;
{
	package subs;
	sub device_setter { return 'test-computer' }
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

require JawnOS::Audio::Plan;
require JawnOS::Audio::Engine;
require JawnOS::Domain::Audio;

# --- the default and the write path -----------------------------------------
{
	%STORE = ();
	is_deeply(
		subs::audio_plan_read(),
		{ sources => [], buses => [], sinks => [], routes => [] },
		'a house with no plan reads four empty lists'
	);
	is(subs::audio_manage_read(), 0, 'and the engine does not own the machine');

	my $plan = {
		sources => [ { id => 'gtr', kind => 'input', channel => 1, latency_ms => 2 } ],
		buses   => [ { id => 'house' } ],
		sinks   => [ { id => 'out', kind => 'interface', channel => 0 } ],
		routes  => [
			{ from => 'gtr',   to => 'house', gain => 0.8, pan => 0 },
			{ from => 'house', to => 'out' },
		],
	};
	my $saved = subs::audio_plan_write($plan);
	is($saved->{ok}, 1, 'a valid plan saves');
	ok(exists $STORE{'sound/audio_plan/all'}, 'on the house row, not a device row');
	ok(!defined $saved->{'applied'}, 'a save with the switch off does not touch the engine');
	is($saved->{plan}{sources}[0]{channel}, 1, 'the saved plan keeps the device channel');

	my $refused = subs::audio_plan_write(
		{ sources => [], buses => [], sinks => [], routes => [ { from => 'ghost', to => 'house' } ] }
	);
	is($refused->{ok}, 0, 'a route to an undeclared node is refused');
	like($refused->{error}, qr/not valid/, 'and the refusal says the plan is not valid');
	is_deeply(
		subs::audio_plan_read()->{routes},
		$saved->{plan}{routes},
		'the refused save left the stored plan alone'
	);
}

# --- the switch is the only thing that applies a plan ------------------------
{
	%STORE = ();
	our $PATCHED;
	our $UNPATCHED;
	# `local` so the real client is back for the next block: a global
	# redefinition would leave the mock in place and the wrapper test below
	# would be testing the mock, not the module.
	no warnings 'redefine';
	local *JawnOS::Audio::Engine::audio_engine_available = sub { 1 };
	local *JawnOS::Audio::Engine::audio_engine_patch = sub {
		$main::PATCHED = $_[0];
		return { ok => 1, state => 'patching' };
	};
	local *JawnOS::Audio::Engine::audio_engine_unpatch = sub {
		$main::UNPATCHED = 1;
		return { ok => 1, state => 'done' };
	};
	local *JawnOS::Audio::Engine::audio_engine_status = sub {
		return { ok => 1, state => 'patching', frames => 96 };
	};

	my $plan = {
		sources => [ { id => 'gtr', kind => 'input', channel => 1, latency_ms => 2 } ],
		buses   => [ { id => 'house' } ],
		sinks   => [ { id => 'out', kind => 'interface', channel => 0 } ],
		routes  => [
			{ from => 'gtr',   to => 'house' },
			{ from => 'house', to => 'out' },
		],
	};
	my $saved = subs::audio_plan_write($plan);
	is($saved->{ok}, 1, 'the plan saves while the switch is off');

	my $on = subs::audio_manage_set(1);
	is($on->{ok}, 1, 'turning the switch on succeeds');
	is(subs::audio_manage_read(), 1, 'and it is stored');
	is_deeply($PATCHED, $saved->{plan}, 'turning it on applies the saved plan, whole');
	is($on->{applied}{state}, 'patching', 'the engine answer is relayed');

	my $status = subs::audio_plan_status();
	is($status->{engine_available}, 1, 'the status says the engine is there');
	is($status->{manage}, 1, 'and carries the switch');
	is($status->{engine}{frames}, 96, 'and the engine reading');
	is($status->{latency}{out}, 2, 'the sink latency adds the source declaration');
	is($status->{engine_device}{backend}, 'alsa', 'the status carries the saved engine backend');
	is($status->{engine_device}{device}, 'hw:1,0', 'and the default device');
	ok(scalar @{ $status->{devices} } > 0, 'and the picker choices');

	subs::audio_manage_set(0);
	is($UNPATCHED, 1, 'turning it off hands the outputs back');
	is(subs::audio_manage_read(), 0, 'and the switch is off');
	is_deeply(
		subs::audio_plan_read()->{sources},
		$saved->{plan}{sources},
		'the plan is kept for the day it is turned on again'
	);
}

# --- the engine's startup copy follows the plan and the switch ---------------
{
	%STORE = ();
	my $path = $ENV{JAWNOS_AUDIO_PLAN};
	my $plan = {
		sources => [ { id => 'gtr', kind => 'input', channel => 1 } ],
		buses   => [],
		sinks   => [ { id => 'out', kind => 'interface', channel => 0 } ],
		routes  => [ { from => 'gtr', to => 'out' } ],
	};

	subs::audio_plan_write($plan);
	ok(-f $path, 'a save writes the engine startup copy');
	{
		my $doc = JSON::PP::decode_json(read_file($path));
		is($doc->{manage}, 0, 'the copy says the engine does not own the machine yet');
		is_deeply($doc->{plan}, subs::audio_plan_read(), 'and carries the normalised plan');
	}

	subs::audio_manage_set(1);
	{
		my $doc = JSON::PP::decode_json(read_file($path));
		is($doc->{manage}, 1, 'turning the switch on flips the copy');
		is_deeply($doc->{plan}, subs::audio_plan_read(), 'and the plan is still the saved one');
	}

	subs::audio_manage_set(0);
	{
		my $doc = JSON::PP::decode_json(read_file($path));
		is($doc->{manage}, 0, 'turning it off flips the copy back');
	}
}

# --- the client spells the two commands --------------------------------------
{
	my $seen;
	{
		no warnings 'redefine';
		local *JawnOS::Audio::Engine::audio_engine_command = sub {
			$seen = $_[0];
			return { ok => 1 };
		};
		my $plan = {
			sources => [ { id => 'gtr', kind => 'input' } ],
			buses   => [],
			sinks   => [ { id => 'out', kind => 'interface' } ],
			routes  => [ { from => 'gtr', to => 'out' } ],
		};
		my $answer = JawnOS::Audio::Engine::audio_engine_patch($plan);
		is($seen->{cmd}, 'patch', 'a patch is the engine\'s patch command');
		is_deeply($seen->{plan}, $plan, 'and the plan goes over the socket whole');
		is($answer->{ok}, 1, 'the engine answer is relayed');
		ok(!exists $seen->{system_device}, 'a patch without a source sends no system device');

		JawnOS::Audio::Engine::audio_engine_patch($plan, 'jawn_system.monitor');
		is($seen->{system_device}, 'jawn_system.monitor',
			'a managed patch names the machine\'s own-audio source');

		my $refused = JawnOS::Audio::Engine::audio_engine_patch('not a plan');
		is($refused->{ok}, 0, 'a non-object plan is refused before the socket');

		JawnOS::Audio::Engine::audio_engine_unpatch();
		is($seen->{cmd}, 'unpatch', 'unpatch is the engine\'s own unpatch command, not stop');

		JawnOS::Audio::Engine::audio_engine_patch_param(2, 'gain', 0.5);
		is($seen->{cmd}, 'param', 'a live fader is the param command');
		is($seen->{target}, 'patch', 'and it targets the patch, not a track');
		is($seen->{route}, 2, 'and names the route by its 0-based index');
		is($seen->{name}, 'gain', 'and the knob by name');
		is($seen->{value}, 0.5, 'and the value');
	}
}

# --- the page and the routes name the plan -----------------------------------
{
	my $routes = read_file("$root/lib/JawnOS/Routes/manager_sound.pm");
	like($routes, qr{\[\s*53030\s*,\s*'post'\s*,\s*'/manager/sound/plan'}, 'the save route exists');
	like($routes, qr{\[\s*53031\s*,\s*'get'\s*,\s*'/manager/sound/plan'}, 'the read route exists');
	like($routes, qr{\[\s*53032\s*,\s*'post'\s*,\s*'/manager/sound/manage'}, 'the switch route exists');
	like($routes, qr{\[\s*53033\s*,\s*'post'\s*,\s*'/manager/sound/param'}, 'the live-fader route exists');
	like($routes, qr{\[\s*53034\s*,\s*'post'\s*,\s*'/manager/sound/device'}, 'the device route exists');

	my $controller = read_file("$root/lib/JawnOS/Controller/manager_sound.pm");
	like($controller, qr/^sub action_53030\b/m, 'the save action exists');
	like($controller, qr/^sub action_53031\b/m, 'the read action exists');
	like($controller, qr/^sub action_53032\b/m, 'the switch action exists');
	like($controller, qr/^sub action_53033\b/m, 'the live-fader action exists');
	like($controller, qr/^sub action_53034\b/m, 'the device action exists');
	like($controller, qr/audio_engine_device_write\(/, 'the device action calls the domain');
	like($controller, qr/&subs::audio_plan_write\(/, 'the save action calls the domain');
	like($controller, qr/&subs::audio_plan_status\(/, 'the window and read action use the status');
	like($controller, qr/&subs::audio_manage_set\(/, 'the switch action calls the domain');
	like($controller, qr/audio_engine_patch_param\(/, 'the live-fader action calls the engine wrapper');

	my $template = read_file("$root/templates/apps/sound.html.ep");
	like($template, qr/id="sound_patch_matrix"/, 'the window carries the matrix');
	like($template, qr/id="sound_manage"/, 'and the master switch');
	like($template, qr/id="sound_patch_save"/, 'and the save button');
	like($template, qr/id="sound_source_machine"/, 'the source form has a machine input');
	like($template, qr/id="sound_sink_machine"/, 'and so does the sink form');
	like($template, qr/id="sound_engine_device"/, 'the picker is in the patchbay');
	like($template, qr/id="sound_engine_device_apply"/, 'and has an apply button');

	my $js = RepoSource::js_source('public/js/manager/sound.js');
	like($js, qr#url: '/manager/sound/plan'#, 'the page reads and saves the plan route');
	like($js, qr#url: '/manager/sound/manage'#, 'and posts the switch');
	like($js, qr#url: '/manager/sound/param'#, 'and posts a live fader');
	like($js, qr#/manager/sound/device#, 'and saves the engine device');
	like($js, qr/function soundPatchDeviceApply/, 'the picker has an apply handler');
	like($js, qr/function soundPatchRender/, 'the matrix has a renderer');
	like($js, qr/function soundPatchFader/, 'the fader has a debounced poster');
	like($js, qr/#sound_source_machine/, 'the source form reads its machine');

	my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
	like($loader, qr/JawnOS::Domain::Audio' for qw\([^)]*\baudio_plan_read\b/,
		'the plan reader is in the domain loader');
	like($loader, qr/JawnOS::Domain::Audio' for qw\([^)]*\baudio_manage_set\b/,
		'the switch writer is in the domain loader');
	like($loader, qr/JawnOS::Domain::Audio' for qw\([^)]*\baudio_engine_device_write\b/,
		'the device writer is in the domain loader');
}

# --- the engine device picker ------------------------------------------------
{
	%STORE = ();
	unlink $ENV{JAWNOS_AUDIO_PLAN};

	is_deeply(
		subs::audio_engine_device_read(),
		{ backend => 'alsa', device => 'hw:1,0' },
		'a machine with no saved choice uses the supervisor default'
	);

	my $devices = subs::audio_engine_devices();
	my ($um2) = grep { $_->{device} eq 'hw:1,0' } @$devices;
	ok($um2, 'the ALSA card list names hw:1,0');
	like($um2->{name}, qr/UMC 202HD/, 'and carries the card description');
	ok((grep { $_->{backend} eq 'pipewire' } @$devices), 'PipeWire is offered');
	ok((grep { $_->{backend} eq 'null' } @$devices), 'and null');

	my $saved = subs::audio_engine_device_write('alsa', 'hw:0,0');
	is($saved->{ok}, 1, 'a device choice saves');
	is_deeply(
		subs::audio_engine_device_read(),
		{ backend => 'alsa', device => 'hw:0,0' },
		'and is read back for the supervisor'
	);
	{
		my $doc = JSON::PP::decode_json(read_file($ENV{JAWNOS_AUDIO_PLAN}));
		is($doc->{backend}, 'alsa', 'the startup copy carries the backend');
		is($doc->{device}, 'hw:0,0', 'and the device');
	}
	is(subs::audio_engine_device_write('bogus', 'x')->{ok}, 0, 'an unknown backend is refused');
	is(subs::audio_engine_device_write('alsa', 'a b')->{ok}, 0, 'a device with an unsafe character is refused');

	my $plan = {
		sources => [ { id => 'gtr', kind => 'input', channel => 1 } ],
		buses   => [],
		sinks   => [ { id => 'out', kind => 'interface' } ],
		routes  => [ { from => 'gtr', to => 'out' } ],
	};
	subs::audio_plan_write($plan);
	{
		my $doc = JSON::PP::decode_json(read_file($ENV{JAWNOS_AUDIO_PLAN}));
		is($doc->{device}, 'hw:0,0', 'a plan save keeps the chosen device');
	}
	subs::audio_manage_set(0);
	{
		my $doc = JSON::PP::decode_json(read_file($ENV{JAWNOS_AUDIO_PLAN}));
		is($doc->{device}, 'hw:0,0', 'and so does the switch');
	}

	my $quit;
	{
		no warnings 'redefine';
		local *JawnOS::Audio::Engine::audio_engine_available = sub { 1 };
		local *JawnOS::Audio::Engine::audio_engine_quit = sub {
			$quit = 1;
			return { ok => 1, state => 'done' };
		};
		subs::audio_manage_set(1);
		my $applied = subs::audio_engine_device_write('pipewire', 'default');
		is($applied->{ok}, 1, 'a device choice while managed succeeds');
		is($quit, 1, 'and quits the engine so the supervisor restarts on it');
		subs::audio_manage_set(0);
	}
}

# --- a device choice restarts a running engine whatever the switch says ----
{
	%STORE = ();
	my $quit;
	{
		no warnings 'redefine';
		local *JawnOS::Audio::Engine::audio_engine_available = sub { 1 };
		local *JawnOS::Audio::Engine::audio_engine_quit = sub {
			$quit = 1;
			return { ok => 1, state => 'done' };
		};
		is(subs::audio_manage_read(), 0, 'the master switch is off');
		my $written = subs::audio_engine_device_write('pipewire', 'default');
		is($written->{ok}, 1, 'the choice still saves');
		is($quit, 1, 'and a running engine is asked to restart on it anyway');
		is($written->{applied}{ok}, 1, 'the answer carries that quit');
	}

	{
		my $tried = 0;
		no warnings 'redefine';
		local *JawnOS::Audio::Engine::audio_engine_available = sub { 0 };
		local *JawnOS::Audio::Engine::audio_engine_quit = sub { $tried = 1; return { ok => 1 } };
		my $written = subs::audio_engine_device_write('alsa', 'hw:0,0');
		is($written->{ok}, 1, 'a machine with no engine still saves the choice');
		is($written->{applied}{skipped}, 1, 'and says there was nothing to restart');
		is($tried, 0, 'nothing pretends to quit');
	}
}

# --- a PipeWire switch turned on restarts an engine that predates the mix ---
{
	%STORE = ();
	require JawnOS::Audio::SystemMix;
	open(my $bfh, '>', $ENV{JAWNOS_AUDIO_PLAN}) or die "boot plan: $!";
	print {$bfh} '{"manage":0,"backend":"pipewire","device":"default",'
		. '"plan":{"sources":[],"buses":[],"sinks":[],"routes":[]}}';
	close $bfh;

	my ($quit, $patched) = (0, 0);
	{
		no warnings 'redefine';
		local *JawnOS::Audio::Engine::audio_engine_available = sub { 1 };
		local *JawnOS::Audio::Engine::audio_engine_status = sub {
			return { ok => 1, state => 'patching', backend => 'pipewire', device => 'default' };
		};
		local *JawnOS::Audio::Engine::audio_engine_patch = sub {
			$patched = 1;
			return { ok => 1, state => 'patching' };
		};
		local *JawnOS::Audio::Engine::audio_engine_quit = sub {
			$quit = 1;
			return { ok => 1, state => 'done' };
		};
		local *JawnOS::Audio::SystemMix::ensure = sub {
			return {
				ok => 1, source => 'jawn_system.monitor',
				previous_default => 'alsa_output.real',
				playback_device  => 'alsa_output.real',
				created          => 1,
			};
		};

		my $on = subs::audio_manage_set(1);
		is($on->{applied}{restarted}, 1,
			'a pipewire engine that started before the mix is restarted');
		is($quit, 1, 'which is a quit');
		is($patched, 0, 'and the patch waits for the respawn');
		is($on->{applied}{system_mix}{playback_device}, 'alsa_output.real',
			'the answer names the output the engine will play through');
	}
	subs::audio_manage_set(0);
}

# --- the manager gate: ALSA and every PipeWire plan get the mix ------------
#
# A duplex PipeWire plan used to keep the ordinary path because one
# pipewire-alsa process could not play one node and capture another. The
# engine now plays the replaced node and captures each routed input through its
# own stream, so the gate is the backend alone.
{
	require JawnOS::Audio::SystemMix;
	for my $case (
		{ backend => 'pipewire', mode => 'duplex',   device => 'default', name => 'a duplex PipeWire plan' },
		{ backend => 'pipewire', mode => 'playback', device => 'default', name => 'a playback PipeWire plan' },
		{ backend => 'alsa',     mode => 'duplex',   device => 'hw:1,0',  name => 'a duplex ALSA plan' },
		{ backend => 'alsa',     mode => 'playback', device => 'hw:1,0',  name => 'a playback ALSA plan' },
	) {
		%STORE = (
			'sound/audio_plan/all' => JSON::PP::encode_json({
				sources => [ { id => 'gtr', kind => 'input', channel => 0 } ],
				buses   => [],
				sinks   => [ { id => 'out', kind => 'interface' } ],
				routes  => [ { from => 'gtr', to => 'out' } ],
			}),
		);
		open(my $pfh, '>', $ENV{JAWNOS_AUDIO_PLAN}) or die "boot plan: $!";
		print {$pfh} '{"manage":0,"backend":"' . $case->{backend} . '",'
			. '"device":"' . $case->{device} . '",'
			. '"plan":{"sources":[],"buses":[],"sinks":[],"routes":[]}}';
		close $pfh;

		my ($ensured, $quit, $patched) = (0, 0, 0);
		{
			no warnings 'redefine';
			local *JawnOS::Audio::Engine::audio_engine_available = sub { 1 };
			local *JawnOS::Audio::Engine::audio_engine_status = sub {
				return { ok => 1, state => 'patching', mode => $case->{mode},
					backend => $case->{backend}, device => $case->{device} };
			};
			local *JawnOS::Audio::Engine::audio_engine_patch = sub {
				$patched = 1;
				return { ok => 1, state => 'patching' };
			};
			local *JawnOS::Audio::Engine::audio_engine_quit = sub {
				$quit = 1;
				return { ok => 1, state => 'done' };
			};
			local *JawnOS::Audio::SystemMix::ensure = sub {
				$ensured++;
				return { ok => 1, source => 'jawn_system.monitor',
					previous_default => 'alsa_output.real', created => 0 };
			};

			my $on = subs::audio_manage_set(1);
			is($ensured, 1, "$case->{name} creates the system mix");
			is($quit, 0, "$case->{name} does not restart when the mix was already there");
			is($patched, 1, "$case->{name} applies the plan");
			is($on->{applied}{system_mix}{source}, 'jawn_system.monitor',
				"$case->{name} names the mix source in the answer");
		}
		subs::audio_manage_set(0);
	}
}

done_testing();
