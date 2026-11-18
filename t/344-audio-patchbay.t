# tests-for: lib/JawnOS/Domain/Audio.pm lib/JawnOS/Audio/Plan.pm lib/JawnOS/Audio/Engine.pm lib/JawnOS/Controller/manager_sound.pm lib/JawnOS/Routes/manager_sound.pm templates/apps/sound.html.ep public/js/manager/sound.js public/js/manager/sound/01_patchbay.js perl/help/topics_apps.pl engine/src/patchbay.rs
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

# One in-memory settings table, keyed the way setting_grabber/setter write.
# The domain module under test reads only these two helpers, so this is the
# whole database it needs.
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

	my $controller = read_file("$root/lib/JawnOS/Controller/manager_sound.pm");
	like($controller, qr/^sub action_53030\b/m, 'the save action exists');
	like($controller, qr/^sub action_53031\b/m, 'the read action exists');
	like($controller, qr/^sub action_53032\b/m, 'the switch action exists');
	like($controller, qr/^sub action_53033\b/m, 'the live-fader action exists');
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

	my $js = RepoSource::js_source('public/js/manager/sound.js');
	like($js, qr#url: '/manager/sound/plan'#, 'the page reads and saves the plan route');
	like($js, qr#url: '/manager/sound/manage'#, 'and posts the switch');
	like($js, qr#url: '/manager/sound/param'#, 'and posts a live fader');
	like($js, qr/function soundPatchRender/, 'the matrix has a renderer');
	like($js, qr/function soundPatchFader/, 'the fader has a debounced poster');
	like($js, qr/#sound_source_machine/, 'the source form reads its machine');

	my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
	like($loader, qr/JawnOS::Domain::Audio' for qw\([^)]*\baudio_plan_read\b/,
		'the plan reader is in the domain loader');
	like($loader, qr/JawnOS::Domain::Audio' for qw\([^)]*\baudio_manage_set\b/,
		'the switch writer is in the domain loader');
}

done_testing();
