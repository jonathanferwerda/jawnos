# tests-for: lib/JawnOS/Domain/Sound.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_sound.pm lib/JawnOS/Routes/manager_sound.pm lib/JawnOS/Routes.pm templates/apps/sound.html.ep templates/apps/sound/media.html.ep public/js/manager/sound.js public/js/manager/taskbar_sound.js public/icons/sound.svg templates/start_menu/start_menu.html.ep public/css/manager.css lib/JawnOS/Manager/Core1_tables_hooks.pm public/js/manager/windows/01_storage.js public/js/manager/taskbar_edit.js perl/language.pl perl/help/topics_apps.pl perl/help/topics_features.pl perl/gb/02_labels_and_collectives.pl
# covers:    The Sound app: pactl/wpctl/amixer/the Android bridge readings, the
#            validated writers and the default-device choice, plus the route,
#            start-menu, taskbar-widget, lazy-chunk, translation and help wiring.

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
use Mojo::Template;
use RepoSource;

my $root = repo_root();
my $scratch = tempdir(CLEANUP => 1);
my $log = "$scratch/writes.log";
write_file($log, '');

# A PATH with no real mixer on it: only the fake tools and the one external
# command the fake scripts use. The domain finds a backend by scanning PATH, so
# a real pactl beside the fake wpctl would be found first and the test would
# pass by accident on one machine and fail on another.
my $os_bin = "$scratch/os";
make_path($os_bin);
symlink('/bin/cat', "$os_bin/cat") if -x '/bin/cat' && !-e "$os_bin/cat";

sub write_exe {
	my ($path, $body) = @_;
	write_file($path, "#!/bin/sh\n$body\n");
	chmod 0755, $path;
}

# --- fake pactl --------------------------------------------------------------
my $pactl_bin = "$scratch/pactl";
make_path($pactl_bin);
write_exe("$pactl_bin/pactl", <<'SH');
case "$1" in
	info) echo "Server Name: fake"; exit 0 ;;
	get-default-sink) echo "fake_sink"; exit 0 ;;
	get-default-source) echo "fake_source"; exit 0 ;;
	get-sink-volume) echo "Volume: front-left: 36044 / 55% / -10.00 dB,   front-right: 36044 / 55% / -10.00 dB"; exit 0 ;;
	get-source-volume) echo "Volume: mono: 45875 / 70% / -7.00 dB"; exit 0 ;;
	get-sink-mute) echo "Mute: no"; exit 0 ;;
	get-source-mute) echo "Mute: yes"; exit 0 ;;
	set-sink-volume|set-source-volume|set-sink-mute|set-source-mute|set-default-sink|set-default-source)
		printf '%s\n' "$*" >> "$SOUND_LOG"; exit 0 ;;
	list)
		if [ "$2" = "sinks" ]; then cat <<'OUT'
Sink #0
	State: RUNNING
	Name: fake_sink
	Description: Fake Speaker
	Mute: no
	Volume: front-left: 36044 / 55% / -10.00 dB,   front-right: 36044 / 55% / -10.00 dB
	        balance 0.00

Sink #1
	State: SUSPENDED
	Name: other_sink
	Description: Other Speaker
	Mute: yes
	Volume: front-left: 65536 / 100% / 0.00 dB,   front-right: 65536 / 100% / 0.00 dB
OUT
			exit 0
		fi
		if [ "$2" = "sources" ]; then cat <<'OUT'
Source #0
	State: RUNNING
	Name: fake_source
	Description: Fake Microphone
	Mute: yes
	Volume: mono: 45875 / 70% / -7.00 dB
OUT
			exit 0
		fi
		if [ "$2" = "short" ] && [ "$3" = "sinks" ]; then
			printf '0\tfake_sink\tPipeWire\ts16le 2ch 48000Hz\tRUNNING\n1\tother_sink\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED\n'
			exit 0
		fi
		if [ "$2" = "short" ] && [ "$3" = "sources" ]; then
			printf '0\tfake_source\tPipeWire\ts16le 1ch 48000Hz\tRUNNING\n'
			exit 0
		fi
		exit 1 ;;
esac
exit 1
SH

# --- fake wpctl --------------------------------------------------------------
my $wpctl_bin = "$scratch/wpctl";
make_path($wpctl_bin);
write_exe("$wpctl_bin/wpctl", <<'SH');
case "$1" in
	status) cat <<'OUT'
Audio
 ├─ Devices:
 │      42. Built-in Audio Analog Stereo    [vol: 1.00]
 │
 ├─ Sinks:
 │  *   45. Built-in Audio Analog Stereo    [vol: 0.70]
 │      46. USB Speaker                     [vol: 0.25 MUTED]
 │
 ├─ Sources:
 │  *   47. Built-in Audio Analog Stereo    [vol: 0.90]
 │
 ├─ Filters:
 │
 └─ Streams:
OUT
		exit 0 ;;
	set-volume|set-mute|set-default)
		printf '%s\n' "$*" >> "$SOUND_LOG"; exit 0 ;;
esac
exit 1
SH

# --- fake amixer -------------------------------------------------------------
my $amixer_bin = "$scratch/amixer";
make_path($amixer_bin);
write_exe("$amixer_bin/amixer", <<'SH');
case "$1 $2" in
	"sget Master"|"sget Master Playback Volume") cat <<'OUT'
Simple mixer control 'Master',0
  Capabilities: pvolume pswitch
  Playback channels: Front Left - Front Right
  Limits: Playback 0 - 65536
  Front Left: Playback 45875 [70%] [-10.00dB] [on]
  Front Right: Playback 45875 [70%] [-10.00dB] [on]
OUT
		exit 0 ;;
	"sget Capture") cat <<'OUT'
Simple mixer control 'Capture',0
  Capabilities: cvolume cswitch
  Capture channels: Front Left - Front Right
  Front Left: Capture 39322 [60%] [-12.00dB] [off]
  Front Right: Capture 39322 [60%] [-12.00dB] [off]
OUT
		exit 0 ;;
	"sget PCM"|"sget Speaker"|"sget Mic") exit 1 ;;
	"sset Master"|"sset Master Playback Volume"|"sset Capture"|"sset PCM"|"sset Speaker"|"sset Mic")
		printf '%s\n' "$*" >> "$SOUND_LOG"; exit 0 ;;
esac
exit 1
SH

require "$root/lib/JawnOS/Domain/Sound.pm";

no warnings 'redefine';
*subs::device_setter = sub { 'computer' };
*subs::format_name = sub {
	my $word = shift || '';
	$word =~ s/_/ /g;
	return ucfirst $word;
};

# ============================================================================
# parser and validator units
# ============================================================================
is(subs::sound_kind_normalize('output'), 'output', 'output is a device kind');
is(subs::sound_kind_normalize('source'), 'input', 'source is the input kind');
is(subs::sound_kind_normalize('speaker'), 'output', 'speaker is the output kind');
is(subs::sound_kind_normalize('nonsense'), undef, 'an unknown kind is refused');

ok(subs::sound_volume_valid(0), 'zero volume is valid');
ok(subs::sound_volume_valid(100), 'full volume is valid');
ok(!subs::sound_volume_valid(101), 'over 100 is refused');
ok(!subs::sound_volume_valid('12x'), 'a non-number is refused');
ok(!subs::sound_volume_valid(undef), 'an undefined volume is refused');

is(subs::sound_mute_value('on'), 1, 'on is mute');
is(subs::sound_mute_value('0'), 0, 'zero is unmute');
is(subs::sound_mute_value('bogus'), undef, 'an unknown mute state is refused');

ok(subs::sound_pactl_id_ok('alsa_output.pci-0000_00_1f.3.analog-stereo'), 'a pactl name is valid');
ok(!subs::sound_pactl_id_ok('--help'), 'a leading dash is refused');
ok(!subs::sound_pactl_id_ok('a b'), 'a space is refused');
ok(subs::sound_wpctl_id_ok('45'), 'a wpctl id is valid');
ok(!subs::sound_wpctl_id_ok('4x'), 'a wpctl id must be numeric');
ok(subs::sound_amixer_id_ok('Master'), 'an amixer control is valid');
ok(subs::sound_amixer_id_ok('Master Playback Volume'), 'the spaced codec control is valid');
ok(!subs::sound_amixer_id_ok('Master Playback Volume; rm -rf /'), 'a control with junk after it is refused');
ok(!subs::sound_amixer_id_ok('Anything'), 'an unknown amixer control is refused');

{
	my $parsed = subs::sound_parse_pactl_devices(<<'OUT', 'output');
Sink #0
	Name: s0
	Description: Speaker Zero
	Mute: no
	Volume: front-left: 1 / 55% / 0 dB
OUT
	is(scalar @{$parsed}, 1, 'a long sink listing is parsed');
	is($parsed->[0]{id}, 's0', 'the name is the id');
	is($parsed->[0]{name}, 'Speaker Zero', 'the description is the name');
	is($parsed->[0]{volume}, 55, 'the volume is read');
	is($parsed->[0]{muted}, 0, 'the mute state is read');
}
{
	my $parsed = subs::sound_parse_pactl_short("0\tfoo\tPipeWire\ts16le\tRUNNING\n", 'output');
	is($parsed->[0]{id}, 'foo', 'a short listing falls back to its name');
}
{
	my ($out, $in) = subs::sound_parse_wpctl(<<'OUT');
Audio
 ├─ Sinks:
 │  *   45. Built-in Audio Analog Stereo    [vol: 0.70]
 │      46. USB Speaker                     [vol: 0.25 MUTED]
 │
 ├─ Sources:
 │  *   47. Built-in Audio Analog Stereo    [vol: 0.90]
OUT
	is(scalar @{$out}, 2, 'two wpctl sinks are parsed');
	is($out->[0]{id}, '45', 'the wpctl id is the leading number');
	is($out->[0]{volume}, 70, 'the wpctl volume is a percentage');
	is($out->[0]{default}, 1, 'the star is the default');
	is($out->[1]{muted}, 1, 'MUTED is parsed');
	is($in->[0]{id}, '47', 'the wpctl source is parsed');
	is($in->[0]{default}, 1, 'and its default flag');
}

# ============================================================================
# pactl
# ============================================================================
{
	local $ENV{PATH} = "$pactl_bin:$os_bin";
	local $ENV{SOUND_LOG} = $log;
	$subs::sound_backend_memo = undef;
	write_file($log, '');

	my $status = subs::sound_status();
	is($status->{ok}, 1, 'pactl gives a reading');
	is($status->{backend}, 'pactl', 'the backend is pactl');
	is(scalar @{$status->{outputs}}, 2, 'two sinks are listed');
	is(scalar @{$status->{inputs}}, 1, 'one source is listed');
	my $out = $status->{output};
	is($out->{id}, 'fake_sink', 'the default sink is the output');
	is($out->{name}, 'Fake Speaker', 'its description is the name');
	is($out->{volume}, 55, 'its volume is read');
	is($out->{muted}, 0, 'its mute state is read');
	is($out->{default}, 1, 'and it is marked default');
	my $in = $status->{input};
	is($in->{id}, 'fake_source', 'the default source is the input');
	is($in->{volume}, 70, 'the input volume is read');
	is($in->{muted}, 1, 'the input mute state is read');
	is($status->{input_supported}, 1, 'the inputs are supported');
	is($status->{output_mute}, 1, 'the output can be muted');
	is($status->{input_mute}, 1, 'the input can be muted');
	is($status->{volume}, 55, 'the status carries the top-level volume');
	is($status->{muted}, 0, 'and the top-level mute state');

	my $set = subs::sound_set('output', 'fake_sink', 40);
	is($set->{ok}, 1, 'the output volume is set');
	is($set->{changed}{volume}, 40, 'the answer names the new volume');
	like(read_file($log), qr/set-sink-volume fake_sink 40%/, 'the fixed command array ran');
	like(read_file($log), qr/^set-sink-volume fake_sink 40%$/m, 'the platform seam wrote the exact argv');

	my $bad = subs::sound_set('output', 'fake_sink', 101);
	is($bad->{ok}, 0, 'an out-of-range volume is refused');
	$bad = subs::sound_set('output', '--help', 40);
	is($bad->{ok}, 0, 'an option-shaped id is refused');
	unlike(read_file($log), qr/--help/, 'and it never reached the command');

	my $mute = subs::sound_mute('input', 'fake_source', 'on');
	is($mute->{ok}, 1, 'the input is muted');
	like(read_file($log), qr/set-source-mute fake_source 1/, 'the mute verb ran');

	my $default = subs::sound_default('output', 'other_sink');
	is($default->{ok}, 1, 'another sink can be made default');
	like(read_file($log), qr/set-default-sink other_sink/, 'the default verb ran');
	$default = subs::sound_default('output', 'not_a_sink');
	is($default->{ok}, 0, 'an unknown device cannot become the default');
}
write_file($log, '');
{
	local $ENV{PATH} = "$pactl_bin:$os_bin";
	local $ENV{SOUND_LOG} = $log;
	$subs::sound_backend_memo = undef;
	my $default = subs::sound_default('input', 'fake_source');
	is($default->{ok}, 1, 'the input can be made default');
	like(read_file($log), qr/set-default-source fake_source/, 'the source default verb ran');
	is(JawnOS::Platform::Audio::get_volume('input', 'fake_source'), 70, 'the seam reads the same source volume');
}

# ============================================================================
# wpctl
# ============================================================================
{
	local $ENV{PATH} = "$wpctl_bin:$os_bin";
	local $ENV{SOUND_LOG} = $log;
	$subs::sound_backend_memo = undef;
	write_file($log, '');

	my $status = subs::sound_status();
	is($status->{ok}, 1, 'wpctl gives a reading');
	is($status->{backend}, 'wpctl', 'the backend is wpctl');
	is(scalar @{$status->{outputs}}, 2, 'two wpctl sinks are listed');
	is($status->{output}{id}, '45', 'the starred sink is the output');
	is($status->{output}{volume}, 70, 'its volume is a percentage');
	is(scalar @{$status->{inputs}}, 1, 'one wpctl source is listed');
	is($status->{input}{id}, '47', 'and it is the default');

	my $set = subs::sound_set('output', '45', 30);
	is($set->{ok}, 1, 'the wpctl volume is set');
	like(read_file($log), qr/set-volume 45 30%/, 'the wpctl volume verb ran');
	my $mute = subs::sound_mute('output', '46', 'off');
	is($mute->{ok}, 1, 'the wpctl mute is set');
	like(read_file($log), qr/set-mute 46 0/, 'the wpctl mute verb ran');
	my $default = subs::sound_default('output', '46');
	is($default->{ok}, 1, 'the wpctl default is set');
	like(read_file($log), qr/set-default 46/, 'the wpctl default verb ran');
}

# ============================================================================
# amixer
# ============================================================================
{
	local $ENV{PATH} = "$amixer_bin:$os_bin";
	local $ENV{SOUND_LOG} = $log;
	$subs::sound_backend_memo = undef;
	write_file($log, '');

	my $status = subs::sound_status();
	is($status->{ok}, 1, 'amixer gives a reading');
	is($status->{backend}, 'amixer', 'the backend is amixer');
	is($status->{output}{id}, 'Master', 'the Master control is the output');
	is($status->{output}{volume}, 70, 'the amixer volume is read');
	is($status->{output}{muted}, 0, 'the amixer on switch is read');
	is($status->{input}{id}, 'Capture', 'the Capture control is the input');
	is($status->{input}{volume}, 60, 'the capture volume is read');
	is($status->{input}{muted}, 1, 'the capture mute state is read');

	# The codec's control has a space, so the probe must hand it as one argv.
	my $spaced = subs::sound_amixer_control("$amixer_bin/amixer", 'Master Playback Volume');
	ok($spaced, 'the spaced codec control is probed');
	is($spaced->{id}, 'Master Playback Volume', 'and keeps its name');

	my $set = subs::sound_set('output', 'Master', 50);
	is($set->{ok}, 1, 'the amixer volume is set');
	like(read_file($log), qr/sset Master 50%/, 'the amixer volume verb ran');
	my $mute = subs::sound_mute('input', 'Capture', 'off');
	is($mute->{ok}, 1, 'the amixer capture is unmuted');
	like(read_file($log), qr/sset Capture unmute/, 'the amixer mute verb ran');
	my $default = subs::sound_default('output', 'Master');
	is($default->{ok}, 0, 'amixer cannot choose a default');
	is($default->{supported}, 0, 'and says it is unsupported');
}

# ============================================================================
# channels: the launcher's master output plus music, phone and alarm
# ============================================================================
# The settings helpers are stubbed with an in-memory map: the real ones read and
# write the database, and this file must not touch it. That is enough to check
# the defaults, the validation and the read-back through the same calls the
# domain makes.
{
	my %store;
	*subs::setting_grabber = sub {
		my ($settings) = @_;
		return $store{ $settings->{'setting'} };
	};
	*subs::setting_setter = sub {
		my ($settings) = @_;
		$store{ $settings->{'setting'} } = $settings->{'value'};
		return 1;
	};

	my $channels = subs::sound_channels();
	is($channels->{music}{volume}, 70, 'music defaults to 70');
	is($channels->{phone}{volume}, 100, 'phone defaults to 100');
	is($channels->{alarm}{volume}, 100, 'alarm defaults to 100');
	is($channels->{music}{muted}, 0, 'music starts unmuted');

	is(subs::sound_channel_gain('music'), 0.7, 'the gain is the volume fraction');
	is(subs::sound_channel_gain('phone'), 1, 'full volume is a gain of one');

	my $set = subs::sound_channel_set('music', 40, 0);
	is($set->{ok}, 1, 'a channel is set');
	is($set->{channels}{music}{volume}, 40, 'the answer names the new volume');
	$channels = subs::sound_channels();
	is($channels->{music}{volume}, 40, 'the write is read back');
	is($channels->{phone}{volume}, 100, 'an untouched channel keeps its default');

	my $bad = subs::sound_channel_set('nonsense', 40, 0);
	is($bad->{ok}, 0, 'an unknown channel is refused');
	$bad = subs::sound_channel_set('music', 101, 0);
	is($bad->{ok}, 0, 'an out-of-range volume is refused');
	$bad = subs::sound_channel_set('music', 40, 'bogus');
	is($bad->{ok}, 0, 'an unknown mute state is refused');
	$channels = subs::sound_channels();
	is($channels->{music}{volume}, 40, 'a refused write changes nothing');

	subs::sound_channel_set('alarm', undef, 1);
	is(subs::sound_channel_gain('alarm'), 0, 'a muted channel has no gain');
	is(subs::sound_channels()->{alarm}{volume}, 100, 'a mute-only write keeps the volume');
	is(subs::sound_channel_gain('nonsense'), 0, 'an unknown channel has no gain');

	local $ENV{PATH} = "$amixer_bin:$os_bin";
	$subs::sound_backend_memo = undef;
	my $status = subs::sound_status();
	ok(ref $status->{channels} eq 'HASH', 'the status carries the channels');
	is($status->{channels}{music}{volume}, 40, 'and their current volumes');
}

# ============================================================================
# the Android bridge
# ============================================================================
{
	my $music = { stream => 'music', volume => 9, max_volume => 15, muted => 0 };
	my $ring = { stream => 'ring', volume => 3, max_volume => 7, muted => 0 };
	*subs::device_call = sub {
		my ($method, $args) = @_;
		return undef unless $method eq 'audio.volume';
		if (ref $args eq 'HASH' && defined $args->{'stream'}) {
			$music->{'volume'} = $args->{'volume'} if $args->{'stream'} eq 'music';
		}
		return { streams => [ $music, $ring ] };
	};
	*subs::device_setter = sub { 'mobile' };
	local $ENV{PATH} = '/bin';
	$subs::sound_backend_memo = undef;

	my $status = subs::sound_status();
	is($status->{ok}, 1, 'the bridge gives a reading');
	is($status->{backend}, 'android', 'the backend is android');
	is(scalar @{$status->{outputs}}, 2, 'the bridge streams are outputs');
	is($status->{output}{id}, 'music', 'the media stream is the default output');
	is($status->{output}{volume}, 60, 'the level is a percentage of its maximum');
	is($status->{input_supported}, 0, 'the bridge has no inputs');
	is($status->{output_mute}, 0, 'the bridge cannot set mute');

	my $set = subs::sound_set('output', 'music', 80);
	is($set->{ok}, 1, 'the bridge volume is set');
	is($set->{changed}{volume}, 80, 'the answer names the new percentage');
	my $mute = subs::sound_mute('output', 'music', 'on');
	is($mute->{ok}, 0, 'the bridge mute is refused');
	is($mute->{supported}, 0, 'and marked unsupported');
	my $default = subs::sound_default('output', 'ring');
	is($default->{ok}, 0, 'the bridge cannot choose a default');

	*subs::device_setter = sub { 'computer' };
}

# ============================================================================
# routing, controller and tier
# ============================================================================
{
	my $routes = read_file("$root/lib/JawnOS/Routes/manager_sound.pm");
	like($routes, qr/\[\s*53020\s*,\s*'get'\s*,\s*'\/manager\/sound'\s*,\s*'action_53020'\s*\]/,
		'the app window has its route');
	like($routes, qr/\[\s*53021\s*,\s*'get'\s*,\s*'\/manager\/sound_status'\s*,\s*'action_53021'\s*\]/,
		'the status route is outside the app prefix');
	like($routes, qr{/manager/sound/volume}, 'the volume route exists');
	like($routes, qr{/manager/sound/mute}, 'the mute route exists');
	like($routes, qr{/manager/sound/default}, 'the default route exists');
	like($routes, qr{/manager/sound/level}, 'the house-level route exists');
	like($routes, qr{/manager/sound/profile}, 'the per-app profile route exists');

	my $controller = read_file("$root/lib/JawnOS/Controller/manager_sound.pm");
	like($controller, qr/^sub action_53020\b/m, 'the window action exists');
	like($controller, qr/^sub action_53021\b/m, 'the status action exists');
	like($controller, qr/^sub action_53025\b/m, 'the level action exists');
	like($controller, qr/^sub action_53026\b/m, 'the profile action exists');
	like($controller, qr/&subs::sound_set\(/, 'the volume action calls the domain');
	like($controller, qr/&subs::sound_mute\(/, 'the mute action calls the domain');
	like($controller, qr/&subs::sound_default\(/, 'the default action calls the domain');
	like($controller, qr/&subs::sound_house_level_write\(/, 'the level action calls the domain');
	like($controller, qr/&subs::sound_app_level_write\(/, 'the profile action calls the domain');
	like($controller, qr/template => 'apps\/sound'/, 'the window renders the Sound template');

	my $names = read_file("$root/lib/JawnOS/Routes.pm");
	like($names, qr/\bmanager_sound\b/, 'the route module is registered');

	my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
	like($loader, qr/JawnOS::Domain::Sound' for qw\([^)]*\bsound_status\b/, 'the status helper is in the loader');
	like($loader, qr/JawnOS::Domain::Sound' for qw\([^)]*\bsound_set\b/, 'the setter is in the loader');
	like($loader, qr/JawnOS::Domain::Sound' for qw\([^)]*\bsound_default\b/, 'the default helper is in the loader');

	require "$root/qa/lib/Probe.pm";
	is(Probe::tier_needed('/manager/sound'), 'resident', 'the Sound window is a resident route');
	is(Probe::tier_needed('/manager/sound_status'), 'resident', 'the taskbar reading is a resident route');
	my $tiers = read_file("$root/perl/subroutines.pl");
	like($tiers, qr{/manager/\(\?:configure\|security\|magazine/publish\|power\)},
		'the citizen tier table does not swallow Sound');
}

# ============================================================================
# the start menu, the lazy maps and the restore branch
# ============================================================================
{
	my $menu = read_file("$root/templates/start_menu/start_menu.html.ep");
	like($menu, qr/id="sound_toggle"/, 'the start menu carries the Sound icon');
	like($menu, qr/hint="<%= &subs::lang\('sound'\) %>"/, 'its hint is a core label');
	like($menu, qr{/icons/sound\.svg}, 'and uses the Sound icon');

	my $labels = read_file("$root/perl/gb/02_labels_and_collectives.pl");
	like($labels, qr/sound => \{ icon => '\/icons\/sound\.svg' \}/, 'the app is in the icon registry');

	my $core = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");
	like($core, qr{/js/manager/taskbar_sound\.js}, 'the widget poller is in the core bundle');
	like($core, qr{sound\s*=>\s*\[qw\(/js/manager/sound\.js\)\]}, 'the app has its lazy chunk');
	like($core, qr{sound\s*=>\s*\[qw\(soundOpener\)\]}, 'the opener has its entry stub');
	like($core, qr/sound_toggle\s*=>\s*'sound'/, 'the first click is replayed to the app');

	my $windows = read_file("$root/public/js/manager/windows/01_storage.js");
	like($windows, qr/i == 'sound'/, 'a restored Sound window uses its own opener');
	like($windows, qr/soundOpener\(timestamp\)/, 'and calls the opener');
}

# ============================================================================
# the taskbar widget
# ============================================================================
{
	my $edit = read_file("$root/public/js/manager/taskbar_edit.js");
	like($edit, qr/sound: \{ hint: 'Sound', icon: '\/icons\/sound\.svg' \}/, 'Sound is a widget');
	like($edit, qr/w == 'sound'/, 'the widget builder has a Sound branch');
	like($edit, qr/jawnosSoundTaskbarLoad/, 'the builder asks for a first reading');

	my $widget = read_file("$root/public/js/manager/taskbar_sound.js");
	like($widget, qr{url: '/manager/sound_status'}, 'the widget reads the sound status');
	like($widget, qr/function jawnosSoundTaskbarRender\(/, 'it has a renderer');
	like($widget, qr/jawnosT\('sound_muted'\)/, 'it names the mute state');
	like($widget, qr/setInterval\(jawnosSoundTaskbarLoad, 45000\)/, 'it polls every 45 seconds');
	like($widget, qr/appWindowOpener\('sound'/, 'a press opens Sound');
	like($widget, qr/jawnosTaskbarEditing/, 'a press in edit mode does not open the app');
	like($widget, qr/data-sound-level/, 'the panel carries the house level');

	my $css = read_file("$root/public/css/manager.css");
	like($css, qr/\.taskbar_sound_glyph/, 'the speaker glyph has a style');
	like($css, qr/\[state=muted\].*taskbar_sound_glyph/s, 'mute draws a slash');
	ok(-e "$root/public/icons/sound.svg", 'the widget icon exists');

	my $template = read_file("$root/templates/apps/sound.html.ep");
	like($template, qr/<div id="sound" app="sound">/, 'the app template is a Sound window');
	like($template, qr/id="sound_output_list"/, 'it has an output list');
	like($template, qr/id="sound_input_list"/, 'it has an input list');
	like($template, qr/id="sound_output_volume"/, 'it has an output volume slider');
	like($template, qr/id="sound_output_mute"/, 'it has an output mute');
	like($template, qr/class="sound_default"/, 'device rows carry Set default');
	like($template, qr/id="sound_level"/, 'it has the house level');
	like($template, qr/id="sound_profiles_list"/, 'and the per-app profiles');

	no warnings 'redefine';
	*subs::lang = sub { $_ [0] };
	*subs::ui = sub { $_ [0] };
	@subs::SOUND_LEVELS = qw( passive sound quiet mute silence );
	*subs::sound_level_label = sub { my ($level) = @_; return ucfirst($level) };
	# The app renderer supplies include(); the bare render below does not parse it.
	my $sound_tpl = read_file("$root/templates/apps/sound.html.ep");
	$sound_tpl =~ s/^[^\n]*include 'apps\/sound\/media'[^\n]*\n//m;
	my $html = Mojo::Template->new(vars => 1, auto_escape => 1)->render(
		$sound_tpl,
		{
			status => {
				ok => 1,
				outputs => [ { id => 's1', name => 'Speaker <script>', volume => 40, default => 1 } ],
				inputs => [ { id => 'i1', name => 'Microphone', volume => 60, default => 1 } ],
				output => { id => 's1', name => 'Speaker <script>', volume => 40, muted => 0, default => 1 },
				input => { id => 'i1', name => 'Microphone', volume => 60, muted => 1, default => 1 },
				input_supported => 1,
			},
		}
	);
	like($html, qr/id="sound_output_list"/, 'the template renders its output list');
	like($html, qr/id="sound_input_list"/, 'the template renders its input list');
	like($html, qr/value="40"/, 'the output volume fills the slider');
	like($html, qr/id="sound_level"/, 'the house level renders');
	like($html, qr/id="sound_profiles_list"/, 'the profiles list renders');
	unlike($html, qr/<script>/, 'a device name is escaped');
}

# ============================================================================
# labels and help
# ============================================================================
{
	require "$root/perl/language.pl";
	for my $lang (@language::languages) {
		for my $key (qw(sound sound_output sound_muted sound_profile sound_passive sound_quiet sound_silence sound_level sound_profiles sound_running sound_add_profile)) {
			isnt(language::translate($lang->{code}, $key), $key,
				$lang->{code} . " translates $key");
		}
	}

	require "$root/perl/help.pl";
	my $topic = $help::topic{'sound'};
	ok($topic, 'the help registry has a Sound topic');
	is($topic->{app}, 'sound', 'the topic names the app');
	is($topic->{category}, 'apps', 'it lives in the app category');
	like($topic->{summary}, qr/volume/i, 'the summary names the volume');
	like(join(' ', @{ $topic->{body} }), qr/walkboy/i,
		'the topic says walkboy is still the media picker');
	like(join(' ', @{ $topic->{body} }), qr/house level/, 'the topic explains the house level');

	my $taskbar = $help::topic{'taskbar'};
	like(join(' ', @{ $taskbar->{body} }), qr/Sound shows/, 'the taskbar topic lists Sound');
	like(join(' ', @{ $taskbar->{steps} }), qr/sound widget/, 'and has a Sound step');
}


like(read_file("$root/templates/apps/sound/media.html.ep"), qr/id="sound_media_list"/, 'Sound lists the browser media devices');
like(read_file("$root/public/js/manager/sound.js"), qr/function soundMediaRender\(/, 'and renders them as the media pickers');

done_testing();
