# tests-for: lib/JawnOS/Platform/Audio.pm lib/JawnOS/Domain/Sound.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_sound.pm lib/JawnOS/Routes/manager_sound.pm templates/apps/sound.html.ep public/js/manager/sound/03_apps.js
# covers:    The Apps pill's data: sink-input and source-output rows normalized
#            from pactl's JSON (front-left/mono first, mean otherwise), the
#            house-channel and app-level dispatch, the stream volume/mute verbs,
#            and the two routes and their controller actions.

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
use RepoSource;

my $root = repo_root();
my $scratch = tempdir(CLEANUP => 1);
my $log = "$scratch/writes.log";
write_file($log, '');

sub write_exe {
	my ($path, $body) = @_;
	write_file($path, "#!/bin/sh\n$body\n");
	chmod 0755, $path;
}

my $fixture = "$scratch/fixture";
make_path($fixture);

write_file("$fixture/sink-inputs.json", <<'JSON');
[
  {
    "index": 12,
    "state": "RUNNING",
    "mute": false,
    "corked": false,
    "sink": 0,
    "volume": {
      "front-left": { "value": 32768, "value_percent": "50%" },
      "front-right": { "value": 32768, "value_percent": "50%" }
    },
    "properties": {
      "application.name": "Firefox",
      "media.name": "Night Drive",
      "application.process.binary": "firefox"
    }
  },
  {
    "index": 13,
    "state": "IDLE",
    "mute": true,
    "corked": true,
    "sink": 2,
    "volume": { "mono": { "value": 65536, "value_percent": "100%" } },
    "properties": {
      "application.name": "mpv",
      "media.name": "Clip",
      "application.process.binary": "mpv"
    }
  },
  {
    "index": 14,
    "mute": false,
    "sink": 1,
    "volume": { "mono": { "value": 16384 } },
    "properties": {}
  },
  {
    "index": 15,
    "mute": false,
    "sink": 1,
    "volume": {
      "rear-left": { "value": 32768 },
      "rear-right": { "value": 65536 }
    },
    "properties": {}
  },
  {
    "index": "not-a-number",
    "volume": {},
    "properties": {}
  }
]
JSON

write_file("$fixture/source-outputs.json", <<'JSON');
[
  {
    "index": 21,
    "state": "RUNNING",
    "mute": false,
    "corked": false,
    "source": 5,
    "volume": { "mono": { "value": 45875, "value_percent": "70%" } },
    "properties": {
      "application.name": "Chromium",
      "media.name": "Voice note",
      "application.process.binary": "chromium"
    }
  },
  {
    "index": 22,
    "state": "RUNNING",
    "mute": true,
    "corked": true,
    "source": 6,
    "volume": { "front-left": { "value": 65536 } },
    "properties": { "application.process.binary": "arecord" }
  }
]
JSON

# --- fake pactl --------------------------------------------------------------
my $pactl_bin = "$scratch/pactl";
make_path($pactl_bin);
write_exe("$pactl_bin/pactl", <<'SH');
case "$1" in
	info) echo "Server Name: fake"; exit 0 ;;
	set-sink-input-volume|set-sink-input-mute|set-source-output-volume|set-source-output-mute)
		printf '%s\n' "$*" >> "$SOUND_LOG"; exit 0 ;;
esac
if [ "$1" = "-f" ] && [ "$2" = "json" ] && [ "$3" = "list" ]; then
	case "$4" in
		sink-inputs) /bin/cat "$SOUND_FIXTURE/sink-inputs.json"; exit 0 ;;
		source-outputs) /bin/cat "$SOUND_FIXTURE/source-outputs.json"; exit 0 ;;
	esac
fi
echo "Command \"$1\" requires a running PulseAudio server." >&2
exit 1
SH

# A stock pactl that answers text to every request: no JSON list, no die.
my $plain_bin = "$scratch/plain";
make_path($plain_bin);
write_exe("$plain_bin/pactl", <<'SH');
if [ "$1" = "info" ]; then echo "Server Name: fake"; exit 0; fi
echo "Failure: Command \"$1\" not understood"
exit 0
SH

require "$root/lib/JawnOS/Platform/Audio.pm";
require "$root/lib/JawnOS/Domain/Sound.pm";

no warnings 'redefine';
*subs::device_setter = sub { 'computer' };
*subs::format_name = sub {
	my $word = shift || '';
	$word =~ s/_/ /g;
	return ucfirst $word;
};

# The settings and profile helpers live in other domain modules; these stubs
# keep the store in memory and name the profile answer the Apps reading expects.
my (%store, %levels);
*subs::setting_grabber = sub {
	my ($settings) = @_;
	return $store{ $settings->{'setting'} };
};
*subs::setting_setter = sub {
	my ($settings) = @_;
	$store{ $settings->{'setting'} } = $settings->{'value'};
	return 1;
};
*subs::sound_open_window_apps = sub { [ 'Music', 'Studio' ] };
*subs::sound_profile_rows = sub {
	return { profile => { Music => 'quiet' }, legacy => {} };
};
*subs::sound_profile_rows_level = sub {
	my ($rows, $app) = @_;
	return $rows->{'profile'}->{$app} || 'passive';
};
*subs::sound_app_level_write = sub {
	my ($app, $level) = @_;
	return 0 unless defined $app && length $app;
	$levels{$app} = $level;
	return 1;
};

# ============================================================================
# the reading
# ============================================================================
{
	local $ENV{PATH} = "$pactl_bin";
	local $ENV{SOUND_FIXTURE} = $fixture;
	local $ENV{SOUND_LOG} = $log;
	JawnOS::Platform::Audio::reset_backend();
	$subs::sound_backend_memo = undef;

	my $reading = subs::sound_apps_reading();
	is($reading->{ok}, 1, 'the Apps reading succeeds');
	is($reading->{channels}{music}{volume}, 70, 'the house channels are carried');
	is(scalar @{ $reading->{apps} }, 2, 'the JawnOS apps are carried');
	is($reading->{apps}[0]{name}, 'Music', 'the app name is preserved');
	is($reading->{apps}[0]{level}, 'quiet', 'and its profile level');

	my $play = $reading->{playback};
	is(scalar @{$play}, 4, 'every usable sink-input is listed');
	is($play->[0]{id}, 12, 'the stream id is the pactl index');
	is($play->[0]{app}, 'Firefox', 'the application name is the app');
	is($play->[0]{media}, 'Night Drive', 'the media name is the media');
	is($play->[0]{binary}, 'firefox', 'the binary is carried');
	is($play->[0]{sink}, '0', 'the sink is carried');
	is($play->[0]{volume}, 50, 'front-left is the volume');
	is($play->[0]{mute}, 0, 'the mute state is read');
	is($play->[0]{corked}, 0, 'the corked state is read');
	is($play->[0]{state}, 'RUNNING', 'the state is read');

	is($play->[1]{volume}, 100, 'mono is the fallback volume');
	is($play->[1]{mute}, 1, 'a muted stream says so');
	is($play->[1]{corked}, 1, 'a corked stream says so');

	is($play->[2]{app}, '', 'a stream with no properties has a blank app');
	is($play->[2]{volume}, 25, 'a raw value is read as a percentage');

	is($play->[3]{volume}, 75, 'the mean of the channels is the last resort');

	my $rec = $reading->{recording};
	is(scalar @{$rec}, 2, 'every source-output is listed');
	is($rec->[0]{id}, 21, 'the recording id is the pactl index');
	is($rec->[0]{app}, 'Chromium', 'the recording app is named');
	is($rec->[0]{media}, 'Voice note', 'the recording media is named');
	is($rec->[0]{source}, '5', 'the input source is carried');
	is($rec->[0]{volume}, 70, 'the recording volume is read');
	is($rec->[1]{app}, 'arecord', 'a missing app name falls back to the binary');
	is($rec->[1]{volume}, 100, 'a raw front-left value is read');
	is($rec->[1]{mute}, 1, 'a muted recording says so');
}

# ============================================================================
# the stream writes
# ============================================================================
{
	local $ENV{PATH} = "$pactl_bin";
	local $ENV{SOUND_FIXTURE} = $fixture;
	local $ENV{SOUND_LOG} = $log;
	JawnOS::Platform::Audio::reset_backend();
	$subs::sound_backend_memo = undef;
	write_file($log, '');

	my $answer = subs::sound_apps_set('playback', undef, 12, 40, undef);
	is($answer->{ok}, 1, 'a playback volume is set');
	is($answer->{changed}{volume}, 40, 'and the answer names it');
	like(read_file($log), qr/^set-sink-input-volume 12 40%$/m, 'the playback volume verb ran');

	$answer = subs::sound_apps_set('playback', undef, 12, undef, 1);
	is($answer->{ok}, 1, 'a playback mute is set');
	like(read_file($log), qr/^set-sink-input-mute 12 1$/m, 'the playback mute verb ran');

	$answer = subs::sound_apps_set('recording', undef, 21, 55, undef);
	is($answer->{ok}, 1, 'a recording volume is set');
	like(read_file($log), qr/^set-source-output-volume 21 55%$/m, 'the recording volume verb ran');

	$answer = subs::sound_apps_set('recording', undef, 21, undef, 'off');
	is($answer->{ok}, 1, 'a recording mute is set');
	like(read_file($log), qr/^set-source-output-mute 21 0$/m, 'the recording mute verb ran');

	is(subs::sound_apps_set('playback', undef, '12; rm -rf /', 10)->{ok}, 0,
		'a non-numeric stream id is refused');
	is(subs::sound_apps_set('playback', undef, 12, 101)->{ok}, 0,
		'an out-of-range stream volume is refused');
	is(subs::sound_apps_set('playback', undef, 12, undef, 'maybe')->{ok}, 0,
		'an unknown mute state is refused');
	unlike(read_file($log), qr/rm -rf/, 'nothing unvalidated reached the command');
}

# ============================================================================
# the channel and app dispatch
# ============================================================================
{
	local $ENV{PATH} = "$pactl_bin";
	local $ENV{SOUND_FIXTURE} = $fixture;
	JawnOS::Platform::Audio::reset_backend();
	$subs::sound_backend_memo = undef;

	my $answer = subs::sound_apps_set('channel', 'music', undef, 40, 0);
	is($answer->{ok}, 1, 'a house channel is set');
	is($answer->{channels}{music}{volume}, 40, 'the answer carries the channels');
	is(subs::sound_channels()->{music}{volume}, 40, 'the write is read back');

	is(subs::sound_apps_set('channel', 'nonsense', undef, 40, 0)->{ok}, 0,
		'an unknown channel is refused');
	is(subs::sound_apps_set('channel', 'music', undef, 101, 0)->{ok}, 0,
		'an out-of-range channel volume is refused');

	$answer = subs::sound_apps_set('app', 'Music', undef, 50, undef);
	is($answer->{ok}, 1, 'an app level is set from the slider');
	is($answer->{changed}{level}, 'quiet', 'the nearest profile stop is chosen');
	is($levels{'Music'}, 'quiet', 'and reaches the profile store');

	$answer = subs::sound_apps_set('app', 'Music', undef, undef, undef, 'mute');
	is($answer->{ok}, 1, 'an app level can be named directly');
	is($levels{'Music'}, 'mute', 'the named level is stored');

	is(subs::sound_apps_set('app', '', undef, 50, undef)->{ok}, 0,
		'an empty app name is refused');
	is(subs::sound_apps_set('app', 'Music', undef, 50, undef, 'loud')->{ok}, 0,
		'an unknown app level is refused');
	is(subs::sound_apps_set('nonsense', 'Music', undef, 50, undef)->{ok}, 0,
		'an unknown kind is refused');
}

# ============================================================================
# a stock pactl is an empty list, not a die
# ============================================================================
{
	local $ENV{PATH} = "$plain_bin";
	JawnOS::Platform::Audio::reset_backend();
	$subs::sound_backend_memo = undef;
	my @playback = @{ JawnOS::Platform::Audio::stream_inputs() };
	my @recording = @{ JawnOS::Platform::Audio::stream_outputs() };
	is(scalar @playback, 0, 'a text-only pactl gives no playback streams');
	is(scalar @recording, 0, 'and no recording streams');
	my $reading = eval { subs::sound_apps_reading() };
	ok(ref $reading eq 'HASH', 'the reading still answers');
}

{
	local $ENV{PATH} = "$scratch/nothing";
	JawnOS::Platform::Audio::reset_backend();
	$subs::sound_backend_memo = undef;
	is(scalar @{ JawnOS::Platform::Audio::stream_outputs() }, 0,
		'a machine with no pactl lists no streams');
}

# ============================================================================
# routes, controller and template
# ============================================================================
{
	my $routes = read_file("$root/lib/JawnOS/Routes/manager_sound.pm");
	like($routes, qr{\[\s*53035\s*,\s*'get'\s*,\s*'/manager/sound/apps'}, 'the Apps read route exists');
	like($routes, qr{\[\s*53036\s*,\s*'post'\s*,\s*'/manager/sound/app'}, 'the Apps write route exists');

	my $controller = read_file("$root/lib/JawnOS/Controller/manager_sound.pm");
	like($controller, qr/^sub action_53035\b/m, 'the read action exists');
	like($controller, qr/^sub action_53036\b/m, 'the write action exists');
	like($controller, qr/&subs::sound_apps_reading\(/, 'the read action calls the domain');
	like($controller, qr/&subs::sound_apps_set\(/, 'the write action calls the domain');

	my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
	like($loader, qr/JawnOS::Domain::Sound' for qw\([^)]*\bsound_apps_reading\b/,
		'the reading is mapped in the loader');
	like($loader, qr/JawnOS::Domain::Sound' for qw\([^)]*\bsound_apps_set\b/,
		'the dispatcher is mapped in the loader');

	my $template = read_file("$root/templates/apps/sound.html.ep");
	like($template, qr/data-section="apps"/, 'the template has the Apps pill');
	like($template, qr/id="sound_apps_playback"/, 'and the playing group');
	like($template, qr/id="sound_apps_recording"/, 'and the recording group');

	my $js = read_file("$root/public/js/manager/sound/03_apps.js");
	like($js, qr{url: '/manager/sound/apps'}, 'the section reads the read route');
	like($js, qr{url: '/manager/sound/app'}, 'and writes the write route');
	like($js, qr/\}, 2000\);/, 'and polls every two seconds');
}

done_testing();
