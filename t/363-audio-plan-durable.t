# tests-for: lib/JawnOS/Audio/Engine.pm lib/JawnOS/Domain/Audio.pm lib/JawnOS/Platform/Paths.pm perl/Audio.pl perl/President.pl perl/jobs.pl jawn
# covers:    the audio engine's durable state: the plan and the system-mix
#            state resolve under $XDG_STATE_HOME/jawnos/audio (else
#            ~/.local/state/jawnos/audio), outside the ~/.president directory
#            ./jawn wipes at boot; the old run-state copies migrate once; the
#            picker's backend/device round-trips through the device-scoped
#            settings row with the boot file absent; the manager rebuilds the
#            boot file from the settings rows at app start; and ./jawn migrates
#            before it wipes.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use JSON::PP ();

# The domain module under test reads only these helpers from its own package.
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

require JawnOS::Audio::Engine;
require JawnOS::Domain::Audio;

# --- the durable path, with XDG set and unset -------------------------------
{
	local $ENV{HOME} = '/house';
	delete $ENV{JAWNOS_AUDIO_PLAN};

	local $ENV{XDG_STATE_HOME} = '/state';
	is(JawnOS::Audio::Engine::audio_engine_plan_path(),
		'/state/jawnos/audio/audio-plan.json',
		'the plan lives under XDG_STATE_HOME, outside ~/.president');
	is(JawnOS::Audio::Engine::audio_engine_state_dir(), '/state/jawnos/audio',
		'and the system-mix state is beside it');

	delete $ENV{XDG_STATE_HOME};
	is(JawnOS::Audio::Engine::audio_engine_plan_path(),
		'/house/.local/state/jawnos/audio/audio-plan.json',
		'without XDG it falls back to ~/.local/state/jawnos/audio');
	is(JawnOS::Audio::Engine::audio_engine_state_dir(),
		'/house/.local/state/jawnos/audio',
		'and the state dir follows the plan');

	local $ENV{JAWNOS_AUDIO_PLAN} = '/pin/plan.json';
	is(JawnOS::Audio::Engine::audio_engine_plan_path(), '/pin/plan.json',
		'JAWNOS_AUDIO_PLAN still pins one file for a test or a probe');
}

# --- the one-time migration out of the wiped run directory ------------------
{
	my $dir  = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	make_path("$home/.president");
	local $ENV{HOME} = $home;
	delete $ENV{XDG_STATE_HOME};
	delete $ENV{JAWNOS_AUDIO_PLAN};

	my $old_plan = "$home/.president/audio-plan.json";
	my $old_mix  = "$home/.president/audio-system-mix.json";
	write_file($old_plan, '{"manage":1,"backend":"pipewire","device":"default","plan":{"sources":[],"buses":[],"sinks":[],"routes":[]}}');
	write_file($old_mix, '{"active":false}');

	my $moved = JawnOS::Audio::Engine::audio_engine_plan_migrate();
	is($moved->{ok}, 1, 'the migration succeeds');
	is($moved->{migrated}, 2, 'the plan and the mix state both move');
	ok(!-e $old_plan, 'the run-state copy of the plan is gone');
	ok(!-e $old_mix, 'and so is the run-state mix state');
	my $new_plan = "$home/.local/state/jawnos/audio/audio-plan.json";
	my $new_mix  = "$home/.local/state/jawnos/audio/audio-system-mix.json";
	ok(-e $new_plan, 'the plan is at the durable path');
	ok(-e $new_mix, 'and the mix state beside it');
	like(read_file($new_plan), qr/"backend":"pipewire"/,
		'with the picker pair intact');

	my $again = JawnOS::Audio::Engine::audio_engine_plan_migrate();
	is($again->{migrated}, 0, 'a second boot has nothing to move');

	# A durable file already present wins over a stale run-state copy.
	write_file($old_plan, '{"stale":1}');
	my $third = JawnOS::Audio::Engine::audio_engine_plan_migrate();
	is($third->{migrated}, 0, 'the durable copy is not overwritten');
	ok(!-e $old_plan, 'and the stale run-state file is removed');
	like(read_file($new_plan), qr/"backend":"pipewire"/,
		'the durable plan is untouched');

	local $ENV{JAWNOS_AUDIO_PLAN} = "$dir/pinned.json";
	write_file($old_plan, '{}');
	my $pinned = JawnOS::Audio::Engine::audio_engine_plan_migrate();
	is($pinned->{skipped}, 'explicit plan path',
		'an explicit plan path never pulls a real file into a test');
}

# --- the picker pair survives the boot file being absent --------------------
{
	%STORE = ();
	my $dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_AUDIO_PLAN} = "$dir/audio-plan.json";
	local $ENV{JAWNOS_AUDIO_SOCKET} = "$dir/no.sock";
	require JawnOS::Audio::SystemMix;
	{
		no warnings 'redefine';
		local *JawnOS::Audio::SystemMix::remove = sub { return { ok => 1, skipped => 1 } };
	}
	is(subs::audio_engine_device_read()->{backend}, 'alsa',
		'a machine that never chose uses the supervisor default');
	my $saved = subs::audio_engine_device_write('pipewire', 'default');
	is($saved->{ok}, 1, 'a picker choice saves');
	unlink $ENV{JAWNOS_AUDIO_PLAN};
	ok(!-e $ENV{JAWNOS_AUDIO_PLAN}, 'the boot file is gone');
	is_deeply(
		subs::audio_engine_device_read(),
		{ backend => 'pipewire', device => 'default' },
		'the device-scoped settings row still answers with the pair'
	);
	is($STORE{'sound/audio_engine_device/test-computer'}, 'pipewire|default',
		'and the pair is what the row holds');
}

# --- the manager rebuilds the boot file from the settings rows --------------
{
	%STORE = ();
	my $dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_AUDIO_PLAN} = "$dir/audio-plan.json";
	$STORE{'sound/audio_plan/all'} = '{"sources":[],"buses":[],"sinks":[],"routes":[]}';
	$STORE{'sound/audio_manage/all'} = '1';
	$STORE{'sound/audio_engine_device/test-computer'} = 'alsa|hw:0,0';

	my $written = subs::audio_boot_file_write();
	is($written->{ok}, 1, 'the boot write succeeds');
	ok(-f $ENV{JAWNOS_AUDIO_PLAN}, 'from the settings rows with no file present');
	my $doc = JSON::PP::decode_json(read_file($ENV{JAWNOS_AUDIO_PLAN}));
	is($doc->{manage}, 1, 'the manage switch comes from its row');
	is_deeply($doc->{plan}, subs::audio_plan_read(), 'and so does the plan');
	is($doc->{backend}, 'alsa', 'the picker backend comes from the device row');
	is($doc->{device}, 'hw:0,0', 'and the device with it');
}

# --- a machine that never chose keeps the safe fallback ---------------------
{
	%STORE = ();
	my $dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_AUDIO_PLAN} = "$dir/audio-plan.json";
	$STORE{'sound/audio_plan/all'} = '{"sources":[],"buses":[],"sinks":[],"routes":[]}';
	$STORE{'sound/audio_manage/all'} = '0';

	subs::audio_boot_file_write();
	my $doc = JSON::PP::decode_json(read_file($ENV{JAWNOS_AUDIO_PLAN}));
	ok(!exists $doc->{backend}, 'a machine that never chose pins no backend');
	ok(!exists $doc->{device}, 'and no device, so the supervisor fallback decides');
	ok(!exists $STORE{'sound/audio_engine_device/test-computer'},
		'and the boot invents no pair row');
}

# --- boot also seeds the pair from a migrated file --------------------------
{
	%STORE = ();
	my $dir = tempdir(CLEANUP => 1);
	local $ENV{JAWNOS_AUDIO_PLAN} = "$dir/audio-plan.json";
	write_file($ENV{JAWNOS_AUDIO_PLAN},
		'{"manage":0,"backend":"pipewire","device":"default","plan":{"sources":[],"buses":[],"sinks":[],"routes":[]}}');

	is(subs::_audio_engine_device_setting_read(), undef,
		'a machine upgrading from the old build has no pair row yet');
	subs::audio_boot_file_write();
	is($STORE{'sound/audio_engine_device/test-computer'}, 'pipewire|default',
		'and the boot seeds it from the file so a later loss costs nothing');
	my $doc = JSON::PP::decode_json(read_file($ENV{JAWNOS_AUDIO_PLAN}));
	is($doc->{backend}, 'pipewire', 'the rebuilt file keeps the pair');
	is($doc->{device}, 'default', 'both halves of it');
}

# --- the call sites put the file out of the wipe's reach --------------------
{
	my $root = "$FindBin::Bin/..";
	my $jawn = read_file("$root/jawn");
	like($jawn, qr/audio_engine_plan_migrate\(\)/,
		'./jawn migrates the durable audio files');
	my $migrate_at = index($jawn, 'audio_engine_plan_migrate()');
	my $wipe_at = index($jawn, 'remove_tree("$dump_dir/$entry")');
	ok($migrate_at >= 0 && $wipe_at >= 0 && $migrate_at < $wipe_at,
		'and it does so before the ~/.president wipe');

	my $president = read_file("$root/perl/President.pl");
	like($president, qr/&subs::audio_boot_file_write\(\)/,
		'the master rebuilds the boot file at app start');

	my $audio = read_file("$root/perl/Audio.pl");
	like($audio, qr/audio_engine_plan_migrate/,
		'the supervisor migrates when it is started first');
	unlike($audio, qr/\$state_dir\/audio-plan\.json/,
		'and no longer defaults the plan under ~/.president');
}

done_testing();
