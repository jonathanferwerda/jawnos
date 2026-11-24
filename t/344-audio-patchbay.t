# tests-for: lib/JawnOS/Domain/Audio.pm lib/JawnOS/Audio/Plan.pm lib/JawnOS/Audio/Engine.pm lib/JawnOS/Controller/manager_sound.pm lib/JawnOS/Routes/manager_sound.pm templates/apps/sound.html.ep public/js/manager/sound.js public/js/manager/sound/01_patchbay.js perl/help/topics_apps.pl engine/src/patchbay.rs engine/src/system_capture.rs
# covers:    the saved house plan (docs/studio-audio-roadmap.md §8): a default plan reads as four
#            empty lists, a valid plan saves on the house row, a dangling route is refused, the
#            master switch is the only thing that applies an engine patch, a sink's declared
#            latency adds up from its source, and the engine client spells "patch" and "stop".
#            An input source tagged with this machine's hostname is still local, while one
#            tagged with another machine stays refused. The house uplink's address is
#            validated and cleared, its session key is generated once and kept, and the
#            boot file carries the uplink and key only for a peer source on this machine.
#            A peer source's declared latency_ms is kept in the saved plan and the boot
#            copy, where the engine places that source earlier.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Path qw(make_path);
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

# --- the input's own capture source ------------------------------------------
# A take on a laptop with a built-in mic and a UM2 has to be able to name which
# one it means. The Studio input picker saves the choice on the plan's input
# source for that device channel, and reading the plan back hands the picker
# the same node, so the two never disagree.
{
	%STORE = ();
	my $node = 'alsa_input.usb-BEHRINGER_UMC202HD-00.analog-stereo';
	my $plan = {
		sources => [
			{ id => 'mic', kind => 'input', channel => 1 },
			{ id => 'gtr', kind => 'input', channel => 0 },
		],
		buses  => [],
		sinks  => [ { id => 'out', kind => 'interface', channel => 0 } ],
		routes => [],
	};
	is(subs::audio_plan_write($plan)->{ok}, 1, 'a plan with two local inputs saves');

	my $picked = subs::audio_plan_source_node_write(1, $node);
	is($picked->{ok}, 1, 'the picker saves a capture node on channel 1');
	is($picked->{source}{node}, $node, 'and answers with the node it saved');
	is(subs::audio_plan_read()->{sources}[0]{node}, $node,
		'the saved plan reads the node back, so the picker opens on it');
	is(subs::audio_plan_read()->{sources}[1]{node}, '',
		'and the other channel keeps its own source, unchanged');

	my $cleared = subs::audio_plan_source_node_write(1, '');
	is($cleared->{ok}, 1, 'an empty name is a choice too');
	is(subs::audio_plan_read()->{sources}[0]{node}, '',
		'and puts the channel back on the machine default');

	my $path = subs::audio_plan_source_node_write(1, '/dev/snd/by-id/mic');
	is($path->{ok}, 0, 'a path is refused rather than saved');
	my $option = subs::audio_plan_source_node_write(1, '-device');
	is($option->{ok}, 0, 'and so is a name parec would read as an option');
	my $missing = subs::audio_plan_source_node_write(7, $node);
	is($missing->{ok}, 0, 'a channel with no input source is refused');
	like($missing->{error}, qr/no input source on channel 7/, 'and says why');
	is(subs::audio_plan_read()->{sources}[0]{node}, '',
		'a refused choice changes nothing');
}

# --- a source may name this machine explicitly --------------------------------
# Sound's source form writes the machine name into the field, and the engine
# writes the hostname, so a plan that says `machine: table` is still this
# machine's plan. A blank machine is the older spelling of the same thing. A
# source tagged with another machine is not this machine's, and stays refused.
{
	%STORE = ();
	require Sys::Hostname;
	no warnings 'redefine';
	local *Sys::Hostname::hostname = sub { 'table' };
	my $um2 = 'alsa_input.usb-BEHRINGER_UMC202HD-00.analog-stereo';
	my $plan = {
		sources => [
			{ id => 'um2-in0', kind => 'input', label => 'Mic (UM2 in 0)', machine => 'table', channel => 0, node => '' },
			{ id => 'um2-in1', kind => 'input', label => 'Mic (UM2 in 1)', machine => 'TABLE', channel => 1, node => '' },
			{ id => 'far',     kind => 'input', label => 'Far mic',         machine => 'elsewhere', channel => 2, node => '' },
		],
		buses  => [],
		sinks  => [],
		routes => [],
	};
	is(subs::audio_plan_write($plan)->{ok}, 1, 'a plan may name this machine on its sources');
	is(subs::audio_plan_read()->{sources}[0]{machine}, 'table', 'and the saved plan keeps the machine');

	my $here = subs::audio_plan_source_node_write(0, $um2);
	is($here->{ok}, 1, 'a source tagged with this machine is a local input');
	is($here->{source}{node}, $um2, 'the choice is written to it');
	is(subs::audio_plan_read()->{sources}[0]{node}, $um2,
		'and the plan reads the node back, so the picker opens on it');

	my $folded = subs::audio_plan_source_node_write(1, $um2);
	is($folded->{ok}, 1, 'the machine name compares without regard to case');

	my $far = subs::audio_plan_source_node_write(2, $um2);
	is($far->{ok}, 0, 'a source tagged with another machine is still refused');
	like($far->{error}, qr/no input source on channel 2/, 'and says which channel it looked at');
	is(subs::audio_plan_read()->{sources}[2]{node}, '', 'while its node is left alone');
}

# --- the machine's capture sources, as the picker lists them ------------------
# The short listing is the truth about what is present; a `.monitor` row is a
# sink's own playback tap, not a microphone, so it is never offered. The long
# listing's Description is the human name, and a source without one is
# prettified rather than shown blank.
{
	my $short = join "\n",
		"2\talsa_output.pci-0000_00_1f.3.analog-stereo.monitor\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED",
		"3\talsa_input.pci-0000_00_1f.3.analog-stereo\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED",
		"4\talsa_input.usb-BEHRINGER_UMC202HD-00.analog-stereo\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED";
	my $long = join "\n",
		'Source #3',
		"\tState: SUSPENDED",
		"\tName: alsa_input.pci-0000_00_1f.3.analog-stereo",
		"\tDescription: Built-in Audio Analog Stereo",
		'Source #4',
		"\tState: SUSPENDED",
		"\tName: alsa_input.usb-BEHRINGER_UMC202HD-00.analog-stereo",
		"\tDescription: BEHRINGER UMC 202HD 192k Analog Stereo";

	my $sources = subs::audio_capture_sources($short, $long);
	is_deeply(
		[ map { $_->{node} } @$sources ],
		[ 'alsa_input.pci-0000_00_1f.3.analog-stereo', 'alsa_input.usb-BEHRINGER_UMC202HD-00.analog-stereo' ],
		'the monitor is left out and both microphones are offered'
	);
	is($sources->[0]{name}, 'Built-in Audio Analog Stereo', 'the long listing names a source for a person');
	is($sources->[1]{name}, 'BEHRINGER UMC 202HD 192k Analog Stereo', 'and so does the second');

	my $unnamed = subs::audio_capture_sources("5\talsa_input.usb_mic\tPipeWire\ts16le 1ch 48000Hz\tIDLE", '');
	is($unnamed->[0]{name}, 'usb mic', 'a source with no description is prettified, never blank');
	my $none = subs::audio_capture_sources('', '');
	is_deeply($none, [], 'a machine with no sources offers nothing rather than a blank row');
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

	# --- the uplink address is a house setting, validated and clearable ---------
	{
		%STORE = ();
		is(subs::audio_uplink_read(), '', 'a house with no uplink reads empty (off)');

		my $saved = subs::audio_uplink_write('127.0.0.1:7060');
		is($saved->{ok}, 1, 'a host and port saves');
		is($STORE{'sound/audio_uplink/all'}, '127.0.0.1:7060', 'on the house row');
		is(subs::audio_uplink_read(), '127.0.0.1:7060', 'and reads back');

		is(subs::audio_uplink_write('not an address')->{ok}, 0, 'a bare word is refused');
		is(subs::audio_uplink_write('127.0.0.1')->{ok}, 0, 'an address with no port is refused');
		is(subs::audio_uplink_write('127.0.0.1:0')->{ok}, 0, 'port 0 is refused');
		is(subs::audio_uplink_write('127.0.0.1:70000')->{ok}, 0, 'a port above 65535 is refused');
		is(subs::audio_uplink_read(), '127.0.0.1:7060', 'a refused address changed nothing');

		is(subs::audio_uplink_write('')->{ok}, 1, 'an empty address is a choice too');
		is(subs::audio_uplink_read(), '', 'and turns the uplink off');
		is($STORE{'sound/audio_uplink/all'}, '', 'the row holds empty, not undef');
	}

	# --- the uplink's session key is generated once and kept ---------------------
	{
		%STORE = ();
		my $first = subs::audio_session_key_read();
		like($first, qr/\A[0-9a-f]{64}\z/, 'a session key is 32 bytes as 64 hex characters');
		is($STORE{'sound/audio_session_key/all'}, $first, 'and is stored on the house row');
		is(subs::audio_session_key_read(), $first, 'reading again returns the same key');

		my $stored = 'ab' x 32;
		$STORE{'sound/audio_session_key/all'} = $stored;
		is(subs::audio_session_key_read(), $stored, 'a stored key is kept, not replaced');
	}

	# --- the boot file names the uplink only for a peer on this machine ---------
	{
		%STORE = ();
		my $path = $ENV{JAWNOS_AUDIO_PLAN};
		is(subs::audio_uplink_write('127.0.0.1:7060')->{ok}, 1, 'the uplink saves before a plan uses it');

		my $no_peer = {
			sources => [ { id => 'gtr', kind => 'input', channel => 0 } ],
			buses   => [],
			sinks   => [ { id => 'out', kind => 'interface' } ],
			routes  => [ { from => 'gtr', to => 'out' } ],
		};
		subs::audio_plan_write($no_peer);
		my $doc = JSON::PP::decode_json(read_file($path));
		ok(!exists $doc->{uplink}, 'a plan with no peer source writes no uplink');
		ok(!exists $doc->{session_key}, 'and no session key');

		my $with_peer = {
			sources => [
				{ id => 'phone', kind => 'peer', channel => 0, latency_ms => 45 },
				{ id => 'gtr',   kind => 'input', channel => 1, latency_ms => 2 },
			],
			buses  => [],
			sinks  => [ { id => 'out', kind => 'interface' } ],
			routes => [ { from => 'phone', to => 'out' }, { from => 'gtr', to => 'out' } ],
		};
		my $written_peer = subs::audio_plan_write($with_peer);
		is($written_peer->{ok}, 1, 'a plan with a peer source is valid');
		is($written_peer->{plan}{sources}[0]{latency_ms}, 45,
			'a peer latency is kept in the saved plan');
		$doc = JSON::PP::decode_json(read_file($path));
		is($doc->{plan}{sources}[0]{latency_ms}, 45,
			'and in the boot copy the engine reads');
		is($doc->{uplink}, '127.0.0.1:7060', 'a peer source on this machine adds the uplink');
		like($doc->{session_key}, qr/\A[0-9a-f]{64}\z/, 'and the audio session key');
		is($doc->{session_key}, subs::audio_session_key_read(), 'the key is the stored one');

		my $far_peer = {
			sources => [ { id => 'far', kind => 'peer', machine => 'elsewhere', channel => 0 } ],
			buses   => [],
			sinks   => [ { id => 'out', kind => 'interface' } ],
			routes  => [ { from => 'far', to => 'out' } ],
		};
		subs::audio_plan_write($far_peer);
		$doc = JSON::PP::decode_json(read_file($path));
		ok(!exists $doc->{uplink}, 'a peer on another machine does not open the uplink here');

		subs::audio_uplink_write('');
		subs::audio_plan_write($with_peer);
		$doc = JSON::PP::decode_json(read_file($path));
		ok(!exists $doc->{uplink}, 'clearing the address removes the uplink from the boot file');
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
	like($controller, qr/&subs::audio_uplink_write\(/, 'the same save path carries the uplink');
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
	like($template, qr/id="sound_uplink"/, 'the patchbay has an uplink field');
	like($template, qr/id="sound_uplink_save"/, 'and a save button for it');
	like($template, qr/<option value="peer">/, 'the source picker offers peer');
	like($template, qr/#sound \.sound_patch_node_latency/, 'a peer row has a place for its latency');
	like($template, qr/#sound \.sound_patch_node_buffer/, 'and for its read buffer');

	my $js = RepoSource::js_source('public/js/manager/sound.js');
	like($js, qr#url: '/manager/sound/plan'#, 'the page reads and saves the plan route');
	like($js, qr#url: '/manager/sound/manage'#, 'and posts the switch');
	like($js, qr#url: '/manager/sound/param'#, 'and posts a live fader');
	like($js, qr#/manager/sound/device#, 'and saves the engine device');
	like($js, qr/function soundPatchDeviceApply/, 'the picker has an apply handler');
	like($js, qr/function soundPatchRender/, 'the matrix has a renderer');
	like($js, qr/function soundPatchFader/, 'the fader has a debounced poster');
	like($js, qr/#sound_source_machine/, 'the source form reads its machine');
	like($js, qr/function soundPatchUplinkSave/, 'the uplink field has a saver');
	like($js, qr/data: \{ uplink: value \}/, 'which posts the address on the plan route');
	like($js, qr/class="sound_peer_latency"/, 'a peer source row carries a latency input');
	like($js, qr/min="0" max="2000"/, 'which offers 0 to 2000 milliseconds');
	like($js, qr/node\.latency_ms = value/, 'and writes the plan node rather than a second save path');
	like($js, qr/class="sound_peer_buffer"/, 'a peer source row carries a buffer input');
	like($js, qr/min="85" max="2000"/, 'which offers the engine floor to two seconds');
	like($js, qr/node\.buffer_ms = value/, 'and writes it into the same plan node');
	like($js, qr/from 85 to 2000/, 'and judges a value outside that range');
	like($js, qr/Held in the plan; it applies when the plan is saved/, 'the page says when the value takes effect');
	like($js, qr/a number of milliseconds from 0 to 2000/, 'and judges a value outside that range');

	my $help = read_file("$root/perl/help/topics_apps.pl");
	like($help, qr/Peer latency, a number of milliseconds from 0 to 2000/,
		'the Sound topic explains the peer latency control');
	like($help, qr/engine reads them when it patches the peer source/,
		'and says when the value takes effect');
	like($help, qr/set Peer latency on its source row/, 'the steps name the control');
	like($help, qr/Peer buffer is how far behind the clock/, 'the Sound topic explains the peer buffer');
	like($help, qr/raise Peer buffer on the same row/, 'and the steps say when to raise it');

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
	my ($um2) = grep { $_->{device} eq 'hw:UM2,0' } @$devices;
	ok($um2, 'the ALSA card list names the card by its id, not its number');
	is($um2->{id}, 'alsa|hw:UM2,0', 'which is the same spelling the picker posts');
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

# --- the picker offers a card's PipeWire profiles --------------------------
#
# Profiles are the card's, not the engine pair's: choosing Pro Audio saves
# `card|profile` beside `pipewire|default`, sets the card, moves the default to
# the sink the profile names, and restarts the engine. A profile change needs a
# free card, so the engine is quit first - an ALSA engine holds `hw:N,0` - and
# the fake pactl here records the argv rather than proving the hardware.
{
	%STORE = ();
	unlink $ENV{JAWNOS_AUDIO_PLAN};
	require JawnOS::Platform::Audio;
	my $tools = "$scratch/tools";
	make_path($tools);
	my $log = "$scratch/cards.log";
	write_file($log, '');
	write_file("$tools/pactl", <<'SH');
case "$1" in
	info) echo "Server Name: fake"; exit 0 ;;
	get-default-sink) echo "alsa_output.usb-BEHRINGER_UMC_202HD_192k-00.pro-output-0"; exit 0 ;;
	get-default-source) echo "alsa_input.usb-BEHRINGER_UMC_202HD_192k-00.pro-input-0"; exit 0 ;;
	get-sink-volume|get-source-volume) echo "Volume: front-left: 32768 / 50% / 0 dB"; exit 0 ;;
	get-sink-mute|get-source-mute) echo "Mute: no"; exit 0 ;;
	list)
		case "$2" in
		cards) cat "$AUDIO_CARDS"; exit 0 ;;
		sinks) printf '%s\n' 'Sink #0' '	Name: alsa_output.usb-BEHRINGER_UMC_202HD_192k-00.pro-output-0' '	Description: UM2 Pro' '	Mute: no' '	Volume: front-left: 32768 / 50% / 0 dB' 'Sink #1' '	Name: alsa_output.pci-0000_00_1f.3.analog-stereo' '	Description: PCH' '	Mute: no' '	Volume: front-left: 32768 / 50% / 0 dB'; exit 0 ;;
		sources) printf '%s\n' 'Source #0' '	Name: alsa_input.usb-BEHRINGER_UMC_202HD_192k-00.pro-input-0' '	Description: UM2 Pro' '	Mute: no' '	Volume: mono: 32768 / 50% / 0 dB'; exit 0 ;;
		esac ;;
	set-card-profile|set-default-sink|set-default-source)
		printf '%s\n' "$*" >> "$AUDIO_LOG"; exit 0 ;;
esac
exit 1
SH
	chmod 0755, "$tools/pactl";

	my $card_text = "$scratch/pactl-cards";
	write_file($card_text, <<'CARDS');
Card #49
	Name: alsa_card.pci-0000_00_1f.3
	Properties:
		alsa.card = "0"
	Profiles:
		off: Off (sinks: 0, sources: 0, priority: 0, available: yes)
		output:analog-stereo: Analog Stereo Output (sinks: 1, sources: 0, priority: 6500, available: yes)
		pro-audio: Pro Audio (sinks: 32, sources: 32, priority: 1, available: yes)
	Active Profile: output:analog-stereo

Card #50
	Name: alsa_card.usb-BEHRINGER_UMC_202HD_192k-00
	Properties:
		alsa.card = "1"
	Profiles:
		off: Off (sinks: 0, sources: 0, priority: 0, available: yes)
		output:analog-stereo: Analog Stereo Output (sinks: 1, sources: 0, priority: 6500, available: yes)
		input:analog-stereo: Analog Stereo Input (sinks: 0, sources: 1, priority: 6500, available: yes)
		pro-audio: Pro Audio (sinks: 6, sources: 6, priority: 1, available: yes)
	Active Profile: pro-audio
CARDS

	local $ENV{'PATH'} = "$tools:" . ($ENV{'PATH'} || '');
	local $ENV{'AUDIO_CARDS'} = $card_text;
	local $ENV{'AUDIO_LOG'} = $log;
	JawnOS::Platform::Audio::reset_backend();

	my $devices = subs::audio_engine_devices();
	my ($um2_pro) = grep {
		($_->{id} || '') eq 'pipewire|default|alsa_card.usb-BEHRINGER_UMC_202HD_192k-00|pro-audio'
	} @$devices;
	ok($um2_pro, 'the UM2 offers Pro Audio as a PipeWire choice');
	like($um2_pro->{name}, qr/^PipeWire \x{2014} Pro Audio \(/, 'named by the profile and the card');
	is($um2_pro->{active}, 1, 'and says it is the profile the card is on');
	my ($um2_alsa) = grep { ($_->{device} || '') eq 'hw:UM2,0' } @$devices;
	is($um2_alsa->{name}, "ALSA \x{2014} BEHRINGER UMC 202HD 192k",
		'the ALSA entry leads with ALSA, never the PCM name');
	is($um2_alsa->{card}, 'alsa_card.usb-BEHRINGER_UMC_202HD_192k-00',
		'and carries the PipeWire card it maps to');
	ok((grep { ($_->{id} || '') eq 'pipewire|default' } @$devices), 'plain PipeWire stays a choice');
	ok((grep { ($_->{id} || '') eq 'pipewire|default|alsa_card.pci-0000_00_1f.3|output:analog-stereo' } @$devices),
		'and another card offers its own profiles');

	# An input node the new profile will rename.
	subs::audio_plan_write({
		sources => [ { id => 'gtr', kind => 'input', channel => 1,
			node => 'alsa_input.usb-BEHRINGER_UMC_202HD_192k-00.pro-input-0' } ],
		buses => [], sinks => [ { id => 'out', kind => 'interface' } ],
		routes => [ { from => 'gtr', to => 'out' } ],
	});

	require JawnOS::Audio::SystemMix;
	my $quit = 0;
	{
		no warnings 'redefine';
		local *JawnOS::Audio::SystemMix::remove = sub { return { ok => 1 } };
		local *JawnOS::Audio::Engine::audio_engine_available = sub { 1 };
		local *JawnOS::Audio::Engine::audio_engine_quit = sub {
			$quit++;
			return { ok => 1, state => 'done' };
		};

		write_file($log, '');
		my $saved = subs::audio_engine_device_write('pipewire', 'default', 'pro-audio',
			'alsa_card.usb-BEHRINGER_UMC_202HD_192k-00');
		is($saved->{ok}, 1, 'a PipeWire profile saves');
		is($saved->{profile}, 'pro-audio', 'and the answer names it');
		is($STORE{'sound/audio_engine_profile/test-computer'},
			'alsa_card.usb-BEHRINGER_UMC_202HD_192k-00|pro-audio',
			'stored beside the pair on this device row');
		is($STORE{'sound/audio_engine_device/test-computer'}, 'pipewire|default',
			'while the pair stays plain PipeWire');
		my $written = read_file($log);
		like($written, qr/set-card-profile alsa_card\.usb-BEHRINGER_UMC_202HD_192k-00 pro-audio/,
			'the card is set through pactl');
		like($written, qr/set-default-sink alsa_output\.usb-BEHRINGER_UMC_202HD_192k-00\./,
			'and the default output moves to the profile\'s sink');
		is($quit, 2, 'the engine is quit to free the card and again to reopen the new sink');
		is_deeply(
			subs::audio_engine_device_read(),
			{ backend => 'pipewire', device => 'default', profile => 'pro-audio',
			  card => 'alsa_card.usb-BEHRINGER_UMC_202HD_192k-00' },
			'and the profile reads back with the pair'
		);
		is(subs::audio_plan_read()->{sources}[0]{node}, '',
			'a plan input the profile renamed is cleared to the default source');

		my $refused = subs::audio_engine_device_write('pipewire', 'default', 'output:iec958-stereo',
			'alsa_card.usb-BEHRINGER_UMC_202HD_192k-00');
		is($refused->{ok}, 0, 'a profile the card does not offer is refused');
		like($refused->{error}, qr/not a profile this card offers/, 'and the refusal says so');
		is($STORE{'sound/audio_engine_profile/test-computer'},
			'alsa_card.usb-BEHRINGER_UMC_202HD_192k-00|pro-audio',
			'and the stored profile is left alone');

		my $plain = subs::audio_engine_device_write('pipewire', 'default');
		is($plain->{ok}, 1, 'the plain PipeWire choice saves');
		ok(!length($STORE{'sound/audio_engine_profile/test-computer'} // ''),
			'and clears the saved profile');
		is_deeply(subs::audio_engine_device_read(), { backend => 'pipewire', device => 'default' },
			'so the pair reads back without one');
		is($quit, 3, 'and the plain choice restarts the engine once');
	}

	JawnOS::Platform::Audio::reset_backend();
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
