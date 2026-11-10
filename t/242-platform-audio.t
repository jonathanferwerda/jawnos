# tests-for: lib/JawnOS/Platform/Audio.pm lib/JawnOS/Domain/Sound.pm lib/JawnOS/Domain/Pay2.pm lib/JawnOS/Domain/Clock.pm lib/JawnOS/Domain/Clock2.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Say.pm lib/JawnOS/Sco/Mixer.pm perl/Music/01_remote_audio_receiver.pl perl/Music/02_remote_audio_stream.pl perl/Music/03_remote_video.pl lib/JawnOS/Controller/manager_misc12.pm
# covers:    the audio seam: the pactl/wpctl/amixer probe order, the parsed
#            device shapes, the default-device reads and writes, the sink-input
#            report, and the exact player/recorder/sox/espeak argv the Music,
#            SCO, Clock, Notify and Say call sites now use.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);

use JawnOS::Platform::Audio ();

my $scratch = tempdir(CLEANUP => 1);
my $os_bin = "$scratch/os";
make_path($os_bin);
my $log = "$scratch/audio.log";
write_file($log, '');

sub write_exe {
	my ($path, $body) = @_;
	write_file($path, "#!/bin/sh\n$body\n");
	chmod 0755, $path;
}

# --- pactl -------------------------------------------------------------------
my $pactl_dir = "$scratch/pactl";
make_path($pactl_dir);
write_exe("$pactl_dir/pactl", <<'SH');
case "$1" in
	info) echo "Server Name: fake"; exit 0 ;;
	get-default-sink) echo "fake_sink"; exit 0 ;;
	get-default-source) echo "fake_source"; exit 0 ;;
	get-sink-volume) printf '%s\n' "$*" >> "$AUDIO_LOG"; echo "Volume: front-left: 36044 / 55% / -10.00 dB,   front-right: 36044 / 55% / -10.00 dB"; exit 0 ;;
	get-source-volume) printf '%s\n' "$*" >> "$AUDIO_LOG"; echo "Volume: mono: 45875 / 70% / -7.00 dB"; exit 0 ;;
	get-sink-mute) printf '%s\n' "$*" >> "$AUDIO_LOG"; echo "Mute: no"; exit 0 ;;
	get-source-mute) printf '%s\n' "$*" >> "$AUDIO_LOG"; echo "Mute: yes"; exit 0 ;;
	list)
		if [ "$2" = "short" ]; then
			printf '%s\n' '0	fake_sink	PipeWire	s16le	RUNNING'
			exit 0
		fi
		if [ "$2" = "sinks" ]; then
			printf '%s\n' 'Sink #0' '	Name: fake_sink' '	Description: Fake Speaker' '	Mute: no' '	Volume: front-left: 36044 / 55% / -10.00 dB' 'Sink #1' '	Name: other_sink' '	Description: Other Speaker' '	Mute: yes' '	Volume: front-left: 1 / 25% / 0 dB'
			exit 0
		fi
		if [ "$2" = "sources" ]; then
			printf '%s\n' 'Source #2' '	Name: fake_source' '	Description: Fake Microphone' '	Mute: yes' '	Volume: mono: 45875 / 70% / -7.00 dB'
			exit 0
		fi
		;;
	-f)
		if [ "$2" = "json" ] && [ "$3" = "list" ] && [ "$4" = "sink-inputs" ]; then
			echo '[{"index":3,"mute":false,"volume":{"front-left":{"value_percent":"100%"}},"properties":{"application.name":"jawnos-music"},"buffer_latency_usec":1000,"sink_latency_usec":2000}]'
			exit 0
		fi
		;;
	set-sink-volume|set-source-volume|set-sink-mute|set-source-mute|set-default-sink|set-default-source|set-sink-input-mute|set-sink-input-volume)
		printf '%s\n' "$*" >> "$AUDIO_LOG"
		exit 0 ;;
esac
exit 1
SH

# --- wpctl -------------------------------------------------------------------
my $wpctl_dir = "$scratch/wpctl";
make_path($wpctl_dir);
write_exe("$wpctl_dir/wpctl", <<'SH');
case "$1" in
	status)
		printf '%s\n' 'Audio' ' ├─ Sinks:' ' │  *   45. Built-in Audio Analog Stereo    [vol: 0.70]' ' │      46. USB Speaker                     [vol: 0.25 MUTED]' ' ├─ Sources:' ' │  *   47. Built-in Audio Analog Stereo    [vol: 0.90]'
		exit 0 ;;
	get-volume)
		printf '%s\n' "$*" >> "$AUDIO_LOG"
		case "$2" in
			46) echo "Volume: 0.25 [MUTED]" ;;
			*) echo "Volume: 0.70" ;;
		esac
		exit 0 ;;
	set-volume|set-mute|set-default)
		printf '%s\n' "$*" >> "$AUDIO_LOG"; exit 0 ;;
esac
exit 1
SH

# --- amixer ------------------------------------------------------------------
my $amixer_dir = "$scratch/amixer";
make_path($amixer_dir);
write_exe("$amixer_dir/amixer", <<'SH');
case "$1 $2" in
	"sget Master"|"sget Master Playback Volume") printf '%s\n' "Simple mixer control 'Master',0" '  Front Left: Playback 45875 [70%] [-10.00dB] [on]' '  Front Right: Playback 45875 [70%] [-10.00dB] [on]'; exit 0 ;;
	"sget Capture") printf '%s\n' "Simple mixer control 'Capture',0" '  Front Left: Capture 39322 [60%] [-12.00dB] [off]'; exit 0 ;;
	"sset Master"|"sset Master Playback Volume"|"sset Capture") printf '%s\n' "$*" >> "$AUDIO_LOG"; exit 0 ;;
esac
exit 1
SH

# --- the rest of the tools the seam can name ---------------------------------
my $tools_dir = "$scratch/tools";
make_path($tools_dir);
write_exe("$tools_dir/pacat", 'exit 0');
write_exe("$tools_dir/parec", 'exit 0');
write_exe("$tools_dir/espeak", 'exit 0');

# ============================================================================
# parsers
# ============================================================================
{
	my $parsed = JawnOS::Platform::Audio::parse_pactl_devices(<<'OUT', 'output');
Sink #0
	Name: s0
	Description: Speaker Zero
	Mute: no
	Volume: front-left: 1 / 55% / 0 dB
OUT
	is(scalar @{$parsed}, 1, 'a long sink listing is parsed');
	is($parsed->[0]{id}, 's0', 'the Name is the id');
	is($parsed->[0]{name}, 'Speaker Zero', 'the Description is the name');
	is($parsed->[0]{volume}, 55, 'the volume is read');
	is($parsed->[0]{muted}, 0, 'the mute state is read');
	is_deeply(JawnOS::Platform::Audio::parse_pactl_devices('', 'output'), [], 'no text is no devices');
}
{
	my $parsed = JawnOS::Platform::Audio::parse_pactl_short("0\tfoo\tPipeWire\ts16le\tRUNNING\n", 'input');
	is($parsed->[0]{id}, 'foo', 'a short listing uses column two');
	is($parsed->[0]{kind}, 'source', 'and carries the input kind');
}
{
	my ($out, $in) = JawnOS::Platform::Audio::parse_wpctl(<<'OUT');
Audio
 ├─ Sinks:
 │  *   45. Built-in Audio Analog Stereo    [vol: 0.70]
 │      46. USB Speaker                     [vol: 0.25 MUTED]
 │
 ├─ Sources:
 │  *   47. Built-in Audio Analog Stereo    [vol: 0.90]
OUT
	is(scalar @{$out}, 2, 'two wpctl sinks are parsed');
	is($out->[0]{id}, '45', 'the leading number is the id');
	is($out->[0]{volume}, 70, '0.70 becomes 70%');
	is($out->[0]{default}, 1, 'the star is the default');
	is($out->[1]{muted}, 1, 'MUTED is read');
	is($in->[0]{id}, '47', 'the source section is separate');
}

# ============================================================================
# the backend order and the pactl reads and writes
# ============================================================================
{
	local $ENV{'PATH'} = "$pactl_dir:$os_bin";
	local $ENV{'AUDIO_LOG'} = $log;
	JawnOS::Platform::Audio::reset_backend();
	write_file($log, '');

	is(JawnOS::Platform::Audio::backend()->{kind}, 'pactl', 'pactl wins when its server answers');
	like(JawnOS::Platform::Audio::info(), qr/Server Name: fake/, 'info asks pactl');
	is(JawnOS::Platform::Audio::get_volume('output', 'fake_sink'), 55, 'a sink volume is read');
	is(JawnOS::Platform::Audio::get_volume('input', 'fake_source'), 70, 'a source volume is read');
	like(read_file($log), qr/^get-sink-volume fake_sink$/m, 'the sink verb names the device');
	like(read_file($log), qr/^get-source-volume fake_source$/m, 'the source verb names the device');
	is(JawnOS::Platform::Audio::get_mute('output', 'fake_sink'), 0, 'an unmuted sink reads 0');
	is(JawnOS::Platform::Audio::get_mute('input', 'fake_source'), 1, 'a muted source reads 1');

	write_file($log, '');
	is(JawnOS::Platform::Audio::get_volume('output'), 55, 'the default sink is read without an id');
	like(read_file($log), qr/^get-sink-volume \@DEFAULT_SINK\@$/m, 'the pulse sentinel is used');

	write_file($log, '');
	is(JawnOS::Platform::Audio::set_volume('output', 'fake_sink', 40), 1, 'a sink volume is written');
	like(read_file($log), qr/^set-sink-volume fake_sink 40%$/m, 'the exact argv reaches pactl');
	is(JawnOS::Platform::Audio::set_mute('input', 'fake_source', 1), 1, 'a source mute is written');
	like(read_file($log), qr/^set-source-mute fake_source 1$/m, 'the mute argv reaches pactl');
	is(JawnOS::Platform::Audio::set_volume('output', '--help', 40), 0, 'an option-shaped id is refused');
	is(JawnOS::Platform::Audio::set_default('output', 'other_sink'), 1, 'a default sink is chosen');
	like(read_file($log), qr/^set-default-sink other_sink$/m, 'the default argv reaches pactl');
	is(JawnOS::Platform::Audio::default('output'), 'fake_sink', 'the default sink is read back');
	is(JawnOS::Platform::Audio::default('input'), 'fake_source', 'and the default source');

	my $devices = JawnOS::Platform::Audio::devices('output');
	is(scalar @{$devices}, 2, 'the device list names both sinks');
	is($devices->[0]{default}, 1, 'the first is the default');
	is(JawnOS::Platform::Audio::devices('input')->[0]{id}, 'fake_source', 'the source list is separate');

	my $streams = JawnOS::Platform::Audio::stream_inputs();
	is(scalar @{$streams}, 1, 'the sink-input JSON decodes');
	is($streams->[0]{index}, 3, 'the browser stream index is kept');
	write_file($log, '');
	is(JawnOS::Platform::Audio::set_stream_input_mute(3, 0), 1, 'a stream input is unmuted');
	like(read_file($log), qr/^set-sink-input-mute 3 0$/m, 'the stream mute argv is exact');
	is(JawnOS::Platform::Audio::set_stream_input_volume(3, 100), 1, 'a stream input is set');
	like(read_file($log), qr/^set-sink-input-volume 3 100%$/m, 'the stream volume argv is exact');
}

# ============================================================================
# wpctl
# ============================================================================
{
	local $ENV{'PATH'} = "$wpctl_dir:$os_bin";
	local $ENV{'AUDIO_LOG'} = $log;
	JawnOS::Platform::Audio::reset_backend();
	write_file($log, '');

	is(JawnOS::Platform::Audio::backend()->{kind}, 'wpctl', 'wpctl is the fallback backend');
	is(JawnOS::Platform::Audio::get_volume('output', 45), 70, 'wpctl volume is a percentage');
	is(JawnOS::Platform::Audio::get_volume('output'), 70, 'the default sink sentinel is read');
	is(JawnOS::Platform::Audio::get_mute('output', 46), 1, 'MUTED reads as a muted device');
	is(JawnOS::Platform::Audio::set_volume('output', 45, 30), 1, 'wpctl volume is written');
	like(read_file($log), qr/^set-volume 45 30%$/m, 'the wpctl volume argv is exact');
	is(JawnOS::Platform::Audio::set_mute('output', 46, 0), 1, 'wpctl mute is written');
	like(read_file($log), qr/^set-mute 46 0$/m, 'the wpctl mute argv is exact');
	is(JawnOS::Platform::Audio::default('output'), '45', 'the starred sink is the default');
	is(JawnOS::Platform::Audio::set_default('output', 46), 1, 'wpctl default is written');
	like(read_file($log), qr/^set-default 46$/m, 'the wpctl default argv is exact');
	is(scalar @{ JawnOS::Platform::Audio::devices('input') }, 1, 'the wpctl source is listed');
}

# ============================================================================
# amixer
# ============================================================================
{
	local $ENV{'PATH'} = "$amixer_dir:$os_bin";
	local $ENV{'AUDIO_LOG'} = $log;
	JawnOS::Platform::Audio::reset_backend();
	write_file($log, '');

	my $backend = JawnOS::Platform::Audio::backend();
	is($backend->{kind}, 'amixer', 'amixer is the last backend');
	is($backend->{control}, 'Master', 'the probed control is kept');
	is(JawnOS::Platform::Audio::get_volume('output', 'Master'), 70, 'the Master volume is read');
	is(JawnOS::Platform::Audio::get_volume('input', 'Capture'), 60, 'the Capture volume is read');
	is(JawnOS::Platform::Audio::get_mute('output', 'Master'), 0, 'the Master switch is read');
	is(JawnOS::Platform::Audio::get_mute('input', 'Capture'), 1, 'the Capture switch is read');
	is(JawnOS::Platform::Audio::set_volume('output', 'Master', 50), 1, 'amixer volume is written');
	like(read_file($log), qr/^sset Master 50%$/m, 'the amixer volume argv is exact');
	is(JawnOS::Platform::Audio::set_mute('input', 'Capture', 0), 1, 'amixer mute is written');
	like(read_file($log), qr/^sset Capture unmute$/m, 'the amixer mute argv is exact');
	is(JawnOS::Platform::Audio::default('output'), 'Master', 'amixer has one output control');
	is(JawnOS::Platform::Audio::default('input'), 'Capture', 'and one input control');
	is(JawnOS::Platform::Audio::set_default('output', 'Master'), undef, 'amixer cannot choose a default');
	is(JawnOS::Platform::Audio::get_volume('output', 'Master Playback Volume'), 70, 'the spaced control works');
}

# ============================================================================
# no backend at all
# ============================================================================
{
	my $empty = "$scratch/empty";
	make_path($empty);
	local $ENV{'PATH'} = $empty;
	JawnOS::Platform::Audio::reset_backend();

	is(JawnOS::Platform::Audio::backend()->{kind}, 'none', 'no mixer answers none');
	is(JawnOS::Platform::Audio::get_volume('output'), undef, 'no backend has no volume');
	is(JawnOS::Platform::Audio::get_mute('output'), undef, 'no backend has no mute');
	is(JawnOS::Platform::Audio::set_volume('output', undef, 50), undef, 'no backend refuses a write');
	is(JawnOS::Platform::Audio::set_mute('output', undef, 1), undef, 'and a mute write');
	is(JawnOS::Platform::Audio::default('output'), '', 'and names no default');
	is_deeply(JawnOS::Platform::Audio::devices('output'), [], 'and lists no devices');
	is_deeply(JawnOS::Platform::Audio::stream_inputs(), [], 'and reports no streams');
	is((JawnOS::Platform::Audio::play_argv(rate => 44100))[0], 'pacat', 'the player falls back to the bare name');
	is((JawnOS::Platform::Audio::record_argv(rate => 8000))[0], 'parec', 'the recorder too');
	is_deeply([ JawnOS::Platform::Audio::speak_argv('hi', 'en-us') ], [], 'and espeak is absent');
}

# ============================================================================
# the argv arrays
# ============================================================================
{
	local $ENV{'PATH'} = "$tools_dir:$os_bin";
	JawnOS::Platform::Audio::reset_backend();

	is_deeply(
		[ JawnOS::Platform::Audio::play_argv(
			rate => 44100, channels => 2, latency => 30,
			volume => 65536, client => 'jawnos-music', stream => 'jawnos-music') ],
		[ "$tools_dir/pacat", '--playback', '--raw', '--format=s16le', '--rate=44100',
			'--channels=2', '--latency-msec=30', '--volume=65536',
			'--client-name=jawnos-music', '--stream-name=jawnos-music' ],
		'the Music receiver argv is pinned');
	is_deeply(
		[ JawnOS::Platform::Audio::play_argv(
			client => 'jawn-sco-prompt', stream => 'jawn-sco-prompt',
			rate => 8000, channels => 1, latency => 20,
			volume => '100%', device => 'jawn_prompt') ],
		[ "$tools_dir/pacat", '--playback', '--raw', '--format=s16le', '--rate=8000',
			'--channels=1', '--latency-msec=20', '--volume=100%',
			'--client-name=jawn-sco-prompt', '--stream-name=jawn-sco-prompt',
			'--device=jawn_prompt' ],
		'the SCO prompt argv is pinned');
	is_deeply(
		[ JawnOS::Platform::Audio::record_argv(
			client => 'jawn-sco-caller', stream => 'jawn-sco-caller',
			rate => 8000, channels => 1, latency => 20,
			device => 'jawn_call_in.monitor') ],
		[ "$tools_dir/parec", '--client-name=jawn-sco-caller',
			'--stream-name=jawn-sco-caller', '--raw', '--format=s16le',
			'--rate=8000', '--channels=1', '--latency-msec=20',
			'--device=jawn_call_in.monitor' ],
		'the SCO capture argv is pinned');
	is_deeply([ JawnOS::Platform::Audio::player_argv('chime.mp3', '0.40') ],
		[ 'play', '-q', '-v', '0.40', 'chime.mp3' ], 'the sox player keeps its bare name and flags');
	is_deeply([ JawnOS::Platform::Audio::player_argv('chime.mp3') ],
		[ 'play', '-q', 'chime.mp3' ], 'a player with no level has no -v');
	is_deeply([ JawnOS::Platform::Audio::speak_argv('hello', 'en-us') ],
		[ "$tools_dir/espeak", '-a70', '-v', 'en-us', 'hello' ], 'espeak keeps -a70 and the chosen voice');
	is_deeply([ JawnOS::Platform::Audio::speak_argv('hello') ],
		[ "$tools_dir/espeak", '-a70', '-v', 'en-us', 'hello' ], 'the default voice is en-us');
}

done_testing();
