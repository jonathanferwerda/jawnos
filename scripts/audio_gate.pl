#!/usr/bin/perl
# Studio's P2 alignment gate, repeatable.
#
# The gate asks one question: does a take the engine recorded through a patch
# cable land on the transport's click grid within one sample, and do four
# tracks of the same take share one start stamp? It runs four checks:
#
#   1. loopback - the staged binary's own round-trip measurement, three times.
#   2. record    - the transport's click goes out, the patched input comes back
#                  as a take, and the take's click onsets are compared with the
#                  120 bpm grid. The take is armed first, so its file contains
#                  the first beat; the transport starts once capture is running.
#                  The first detected onset is therefore the round-trip offset
#                  plus that small start lead and the detector's threshold on
#                  the click's soft rise (the loopback in step 1 is the
#                  interface's own round-trip number). Every later onset must be
#                  within one sample of the first onset plus whole beats.
#   3. playback  - the take just recorded is placed on the transport with the
#                  transport click muted, recorded back through the same cable,
#                  and analysed against the same grid.
#   4. four-track - four tracks all read the same patched input. The reply's one
#                  `start_sample` and the tracks' first-onset spread show the
#                  shared start stamp. This is deliberately *not* four ADCs:
#                  the UM2 has two inputs, so the same converted signal is
#                  duplicated. The step proves the stamp, not four converters.
#
# Run it with Studio idle: the gate starts a transport and a take, and refuses
# to displace one that is already recording, playing, listening or patching.
# The engine must already be serving the socket; this script starts no daemon.
#
#   perl scripts/audio_gate.pl                    # auto-detect the CODEC card
#   perl scripts/audio_gate.pl --device hw:2,0    # when detection is ambiguous
#   perl scripts/audio_gate.pl --json             # one machine-readable object
#   perl scripts/audio_gate.pl --out-dir .shots/gate   # keep the takes
#
# The patch cable must connect the interface's output to the input named by
# --input (default 1, the UM2's instrument input).
#
# Exit 0 only when every check passes; 1 when the hardware or the grid fails;
# 2 on a usage error.

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Getopt::Long qw(GetOptions);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use File::Spec;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use JSON::PP ();
use Time::HiRes qw(sleep time);
use JawnOS::Audio::Engine ();
use JawnOS::Audio::Gate qw(gate_analyse gate_detect_device);

my $json = 0;
my $help = 0;
my %opt = (
	rate             => 0,
	period           => 0,
	buffer           => 0,
	bpm              => 120,
	'beats-per-bar'  => 4,
	seconds          => 4,
	tracks           => 4,
	input            => 1,
	backend          => 'alsa',
);

GetOptions(
	\%opt,
	'socket=s',
	'device=s',
	'rate=i',
	'period=i',
	'buffer=i',
	'bpm=f',
	'beats-per-bar=i',
	'seconds=f',
	'tracks=i',
	'input=i',
	'backend=s',
	'binary=s',
	'out-dir=s',
	'json' => \$json,
	'help' => \$help,
) or usage(2, 'could not read the options');

usage(0) if $help;

usage(2, '--bpm must be greater than zero') unless $opt{bpm} > 0;
usage(2, '--beats-per-bar must be 1..32')
	unless $opt{'beats-per-bar'} >= 1 && $opt{'beats-per-bar'} <= 32;
usage(2, '--seconds must be greater than zero') unless $opt{seconds} > 0;
usage(2, '--seconds must cover at least two beats')
	unless $opt{seconds} > 60 / $opt{bpm};
usage(2, '--tracks must be 2..32 for the shared-start step')
	unless $opt{tracks} >= 2 && $opt{tracks} <= 32;
usage(2, '--input must be a non-negative channel number')
	unless $opt{input} >= 0;
usage(2, '--period must be positive') if $opt{period} < 0;
usage(2, '--buffer must be positive') if $opt{buffer} < 0;
usage(2, '--rate must be positive') if $opt{rate} < 0;

my $socket = $opt{socket} // JawnOS::Audio::Engine::audio_engine_socket();
local $ENV{JAWNOS_AUDIO_SOCKET} = $socket;

# The take directory: a tempdir unless the operator wants to inspect the WAVs.
my $take_dir;
if (defined $opt{'out-dir'} && length $opt{'out-dir'}) {
	$take_dir = File::Spec->rel2abs($opt{'out-dir'});
	make_path($take_dir);
}
else {
	$take_dir = tempdir('jawnos-audio-gate-XXXXXX', TMPDIR => 1, CLEANUP => 1);
}

my @errors;
my @notes;
my @checks;
my $ok = 1;
my $check = sub {
	my ($name, $pass, $detail) = @_;
	push @checks, {
		name   => $name,
		pass   => $pass ? 1 : 0,
		detail => defined $detail ? $detail : '',
	};
	$ok = 0 unless $pass;
	return $pass ? 1 : 0;
};

# The engine is the authority on the device, rate, period and buffer for the
# take steps; an idle or absent engine still lets the loopback run and report.
my $status = JawnOS::Audio::Engine::audio_engine_status();
my $engine_up = ref $status eq 'HASH' && $status->{ok} ? 1 : 0;

my $rate   = $opt{rate}   || ($engine_up && $status->{rate}   || 0) || 48_000;
my $period = $opt{period} || ($engine_up && $status->{period} || 0) || 64;
my $buffer = $opt{buffer} || ($engine_up && $status->{buffer} || 0) || 256;
my $bpm    = $opt{bpm};
my $bpb    = $opt{'beats-per-bar'};
my $seconds = $opt{seconds};
my $tracks = $opt{tracks};
my $input  = $opt{input};

# Which card the loopback should measure. An explicit --device wins; else the
# /proc card match; else the device the running engine was started with. The
# last is a fallback, and a disagreement is a note, not a quiet substitution.
my $detect = defined $opt{device} ? undef : gate_detect_device();
my $engine_device = $engine_up ? ($status->{device} // '') : '';
my $device = $opt{device};
$device = $detect->{device} if !defined $device && $detect && $detect->{ok};
$device = $engine_device if !defined $device && length $engine_device;

if ($detect && $detect->{ok} && length $engine_device
	&& $detect->{device} ne $engine_device) {
	push @notes, "auto-detected $detect->{device}, but the running engine uses $engine_device; "
		. "the loopback measured $detect->{device}. Pass --device $engine_device to measure the engine's card.";
}
if (defined $opt{device} && length $engine_device && $opt{device} ne $engine_device) {
	push @notes, "the loopback uses --device $opt{device}; the running engine uses $engine_device.";
}
if ($engine_up && defined $opt{rate} && $opt{rate} > 0 && $status->{rate}
	&& $status->{rate} != $opt{rate}) {
	push @notes, "the loopback uses $opt{rate} Hz; the running engine uses $status->{rate} Hz.";
}

my $binary = $opt{binary} // JawnOS::Audio::Engine::audio_engine_binary();
my $expected = expected_clicks($seconds, $bpm);

my $report = {
	ok        => 1,
	kind      => 'jawnos-audio-gate',
	take_dir  => $take_dir,
	options   => {
		device        => $device,
		socket        => $socket,
		rate          => $rate,
		period        => $period,
		buffer        => $buffer,
		bpm           => $bpm,
		beats_per_bar => $bpb,
		seconds       => $seconds,
		tracks        => $tracks,
		input         => $input,
		backend       => $opt{backend},
		binary        => $binary,
		expected      => $expected,
	},
	device_detect => $detect,
	engine        => {
		socket => $socket,
		status => $status,
	},
	loopback      => {
		ok     => 0,
		device => $device,
		binary => $binary,
		runs   => [],
	},
	clicks        => undef,
	playback      => undef,
	four_track    => undef,
	notes         => \@notes,
	errors        => \@errors,
	checks        => \@checks,
};

if (!defined $device || !length $device) {
	push @errors, 'no CODEC card found and no --device given; '
		. 'pass --device hw:N,0 (the UM2 is usually hw:2,0 when a webcam owns card 0)';
	$check->('device resolved', 0, $errors[-1]);
	finish_and_exit($report);
}
$check->('device resolved', 1, $device);

# --- 1. loopback -----------------------------------------------------------
my @runs;
if (!-x $binary) {
	push @errors, "the staged engine binary is not executable at $binary; "
		. 'run perl scripts/build_engine.pl first';
	$check->('loopback (3 runs)', 0, $errors[-1]);
}
else {
	for my $run (1 .. 3) {
		my @cmd = (
			$binary, '--loopback',
			'--backend', $opt{backend},
			'--device', $device,
			'--rate', $rate,
			'--period', $period,
			'--buffer', $buffer,
			'--json',
		);
		my ($exit, $stdout, $stderr) = run_process(@cmd);
		my $decoded = decode_line($stdout);
		my $good = $decoded && $decoded->{ok}
			&& defined $decoded->{samples} && $decoded->{samples} > 0;
		push @runs, {
			run               => $run,
			exit              => $exit,
			ok                => $good ? 1 : 0,
			samples           => $decoded ? $decoded->{samples} : undef,
			ms                => $decoded ? $decoded->{ms} : undef,
			precision_samples => $decoded ? $decoded->{precision_samples} : undef,
			method            => $decoded ? $decoded->{method} : undef,
			error             => $decoded ? $decoded->{error}
				: ($exit == 124 ? 'timed out' : 'no JSON line'),
			stderr            => trim($stderr),
		};
	}
	$report->{loopback}{runs} = \@runs;
	my $passed = !(grep { !$_->{ok} } @runs);
	$report->{loopback}{ok} = $passed ? 1 : 0;
	$check->(
		'loopback (3 runs)',
		$passed,
		$passed
			? sprintf('samples %s; precision %s sample(s)',
				join('/', map { $_->{samples} } @runs),
				join('/', map { defined $_->{precision_samples} ? $_->{precision_samples} : '-' } @runs))
			: 'a loopback run failed: '
				. join('; ', map { "run $_->{run}: $_->{error}" } grep { !$_->{ok} } @runs),
	);
}

# --- the engine must answer for the take steps -----------------------------
unless ($engine_up) {
	push @errors, "the audio engine is not answering at $socket: "
		. ($status->{error} // 'no answer')
		. '; start it before the take steps';
	$check->('engine answered', 0, $errors[-1]);
	finish_and_exit($report);
}
$check->('engine answered', 1, "socket $socket");

my $engine_channels = $status->{device_channels} // 0;
$report->{engine}{channels} = $engine_channels;
$report->{engine}{config} = {
	backend  => $status->{backend},
	device   => $status->{device},
	rate     => $status->{rate},
	period   => $status->{period},
	buffer   => $status->{buffer},
	channels => $engine_channels,
};

my $busy = '';
$busy = $status->{state}
	if ($status->{state} // '') =~ /\A(?:recording|playing|listening|patching)\z/;
$busy = 'transport' if ($status->{transport}{state} // '') eq 'playing';
if (length $busy) {
	push @errors, "the engine is busy ($busy); stop the Studio take/transport/listen/patch "
		. 'before running the gate';
	$check->('engine idle', 0, $errors[-1]);
	finish_and_exit($report);
}
$check->('engine idle', 1, 'no take, transport, listen or patch is running');

# --- 2. record the transport's click through the patch cable ---------------
my $take1 = File::Spec->catfile($take_dir, 'take-ch1.wav');
my $click_take = take_with_transport(
	path    => $take1,
	tracks  => 1,
	inputs  => [ $input ],
	seconds => $seconds,
	bpm     => $bpm,
	bpb     => $bpb,
	gain    => 0.5,
);

my $click_analysis;
if (!$click_take->{ok}) {
	push @errors, 'the click take did not complete: ' . $click_take->{error};
	$report->{clicks} = { ok => 0, path => $take1, error => $click_take->{error} };
	$check->('recorded click grid', 0, $click_take->{error});
}
else {
	$click_analysis = gate_analyse(
		$take1,
		bpm           => $bpm,
		beats_per_bar => $bpb,
		expected      => $expected,
		channel       => 0,
	);
	$report->{clicks} = {
		ok       => 1,
		path     => $take1,
		record   => summarize_record($click_take->{record}),
		analysis => $click_analysis,
	};
	$check->(
		'recorded click grid',
		$click_analysis->{passed},
		$click_analysis->{passed}
			? "first onset $click_analysis->{first} sample(s), max delta $click_analysis->{max_delta}"
			: $click_analysis->{reason},
	);
}

# --- 3. play the take back with the transport click muted ------------------
my $take2 = File::Spec->catfile($take_dir, 'playback-ch1.wav');
if ($click_take->{ok} && -f $take1) {
	my $clip = {
		file     => File::Spec->rel2abs($take1),
		start    => 0,
		offset   => 0,
		duration => 0,
		gain     => 1,
		pan      => 0,
	};
	my $play_take = take_with_transport(
		path    => $take2,
		tracks  => 1,
		inputs  => [ $input ],
		seconds => $seconds,
		bpm     => $bpm,
		bpb     => $bpb,
		gain    => 0,
		clips   => [ $clip ],
	);
	if (!$play_take->{ok}) {
		push @errors, 'the playback take did not complete: ' . $play_take->{error};
		$report->{playback} = { ok => 0, path => $take2, error => $play_take->{error} };
		$check->('playback grid', 0, $play_take->{error});
	}
	else {
		my $analysis = gate_analyse(
			$take2,
			bpm           => $bpm,
			beats_per_bar => $bpb,
			expected      => $expected,
			channel       => 0,
		);
		$report->{playback} = {
			ok       => 1,
			path     => $take2,
			clip     => $clip,
			record   => summarize_record($play_take->{record}),
			analysis => $analysis,
		};
		$check->(
			'playback grid',
			$analysis->{passed},
			$analysis->{passed}
				? "first onset $analysis->{first} sample(s), max delta $analysis->{max_delta}"
				: $analysis->{reason},
		);
	}
}
else {
	my $why = 'the click take is not on disk, so there is nothing to play back';
	push @errors, $why;
	$report->{playback} = { ok => 0, path => $take2, error => $why };
	$check->('playback grid', 0, $why);
}

# --- 4. four tracks from the one patched input -----------------------------
my $take4 = File::Spec->catfile($take_dir, 'four-track.wav');
my $four = {
	ok           => 0,
	tracks       => $tracks,
	input        => $input,
	start_sample => undef,
	paths        => [ take_paths($take4, $tracks) ],
	firsts       => [],
	spread       => undef,
	analyses     => [],
	error        => '',
};

# A take may carry more tracks than the interface has channels: the engine lets
# several tracks name the same input, which is how four tracks fit the UM2's two
# inputs. The step proves the shared start stamp, not four ADCs.
{
	my @inputs = ($input) x $tracks;
	my $four_take = take_with_transport(
		path    => $take4,
		tracks  => $tracks,
		inputs  => \@inputs,
		seconds => $seconds,
		bpm     => $bpm,
		bpb     => $bpb,
		gain    => 0.5,
	);
	$four->{paths} = $four_take->{paths};
	if (!$four_take->{ok}) {
		$four->{error} = $four_take->{error};
		push @errors, 'the four-track take did not complete: ' . $four->{error};
		$check->('four-track shared start', 0, $four->{error});
	}
	else {
		$four->{start_sample} = $four_take->{record}{start_sample};
		my @firsts;
		for my $path (@{ $four->{paths} }) {
			my $analysis = gate_analyse(
				$path,
				bpm           => $bpm,
				beats_per_bar => $bpb,
				expected      => $expected,
				channel       => 0,
			);
			push @{ $four->{analyses} }, {
				track  => scalar(@{ $four->{analyses} }) + 1,
				path   => $path,
				ok     => $analysis->{ok},
				passed => $analysis->{passed},
				first  => $analysis->{first},
				max_delta => $analysis->{max_delta},
				reason => $analysis->{reason},
				error  => $analysis->{error},
			};
			push @firsts, $analysis->{first} if defined $analysis->{first};
		}
		$four->{firsts} = \@firsts;
		if (@firsts) {
			my ($low, $high) = ($firsts[0], $firsts[0]);
			for my $value (@firsts) {
				$low = $value if $value < $low;
				$high = $value if $value > $high;
			}
			$four->{spread} = $high - $low;
		}

		my $all = @{ $four->{analyses} } == $tracks
			&& !(grep { !$_->{passed} } @{ $four->{analyses} })
			&& defined $four->{spread} && $four->{spread} <= 1
			&& defined $four->{start_sample};
		$four->{ok} = $all ? 1 : 0;
		$four->{error} = $all ? '' : 'a track missed the grid or the onset spread exceeded one sample';
		$check->(
			'four-track shared start',
			$all,
			$all
				? "one start_sample $four->{start_sample}; spread $four->{spread} sample(s)"
				: $four->{error},
		);
		push @errors, 'the four-track step failed: ' . $four->{error} unless $all;
	}
	$report->{four_track} = $four;
}

# --- the answer ------------------------------------------------------------
finish_and_exit($report);

# ---------------------------------------------------------------------------
# Helpers

sub usage {
	my ($exit, $error) = @_;
	print STDERR "audio_gate: $error\n" if defined $error && length $error;
	print <<'USAGE';
audio_gate.pl - Studio's P2 alignment gate through the patch cable

  perl scripts/audio_gate.pl [options]

The engine must already be running and Studio must be idle. Patch the
interface's output into the input named by --input (default 1, the UM2's
instrument input). The script starts a transport and a take, measures the
click grid on the recorded take, plays that take back with the transport
click muted, and records four tracks from the same input.

  --socket PATH        engine control socket (default: Engine's own)
  --device NAME        ALSA PCM for the loopback (default: auto-detect the
                       PCM2902 / Burr-Brown / "USB Audio CODEC" card)
  --rate HZ            sample rate (default: the engine's, else 48000)
  --period N           period/block size (default: the engine's, else 64)
  --buffer N           buffer size (default: the engine's, else 256)
  --bpm N              transport tempo (default 120)
  --beats-per-bar N    transport signature (default 4)
  --seconds N          take length (default 4)
  --tracks N           tracks in the shared-start step (default 4; 2..32)
  --input N            0-based input the cable is patched into (default 1)
  --backend NAME       loopback backend (default alsa)
  --binary PATH        staged engine binary (default: Engine's own)
  --out-dir DIR        keep the takes here instead of a cleaned tempdir
  --json               one JSON object instead of the table
  --help               this text

The four-track step needs the engine configured with at least N capture
channels; duplicating one input across tracks does not bypass that check. On a
two-input UM2 the engine must be started with a larger --channels and a device
that grants them, or --tracks lowered. The step proves one shared start stamp,
not four independent converters.

Exit 0 when every check passes, 1 on a gate failure, 2 on a usage error.
USAGE
	exit $exit;
}

# Make the click grid's expected count. A take of `seconds` at `bpm` contains
# the beat at 0, 0.5, ... less than `seconds`; a whole number of beats excludes
# the one exactly at the end.
sub expected_clicks {
	my ($seconds, $bpm) = @_;
	my $slots = $seconds * $bpm / 60;
	my $whole = int($slots);
	return $slots == $whole ? $whole : $whole + 1;
}

sub trim {
	my ($text) = @_;
	return '' unless defined $text;
	$text =~ s/^\s+//;
	$text =~ s/\s+$//;
	return $text;
}

sub decode_line {
	my ($text) = @_;
	return undef unless defined $text;
	my $line;
	for my $candidate (split /\n/, $text) {
		$line = $candidate if $candidate =~ /\S/;
	}
	return undef unless defined $line && $line =~ /\S/;
	my $decoded = eval { JSON::PP->new->decode($line) };
	return ref $decoded eq 'HASH' ? $decoded : undef;
}

# Run a child with its stdout and stderr captured. A loopback is bounded by the
# engine itself; the alarm is the backstop for a wedged binary, not a normal
# path.
sub run_process {
	my (@command) = @_;
	my $err = gensym;
	my ($in, $out);
	my $pid = eval { open3($in, $out, $err, @command) };
	return (127, '', "cannot run $command[0]: $@") unless $pid;
	close $in;

	my ($stdout, $stderr) = ('', '');
	my $finished = eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		alarm 30;
		local $/;
		$stdout = <$out> // '';
		$stderr = <$err> // '';
		waitpid($pid, 0);
		alarm 0;
		1;
	};
	unless ($finished) {
		my $why = $@ || 'unknown';
		kill 'TERM', $pid;
		waitpid($pid, 0);
		alarm 0;
		return (124, $stdout, $stderr . "gate timed out ($why)");
	}

	my $exit = $? >> 8;
	$exit = 128 + ($? & 127) if $? & 127;
	return ($exit, $stdout, $stderr);
}

# The engine's take file names: one track keeps the path, more add -ch1...
sub take_paths {
	my ($out, $count) = @_;
	return ($out) if $count <= 1;
	my $dir  = dirname($out);
	my $file = basename($out);
	$file =~ s/\.[^.]*$//;
	my @paths;
	for my $track (1 .. $count) {
		push @paths, File::Spec->catfile($dir, "$file-ch$track.wav");
	}
	return @paths;
}

# The record reply is a status line, not a file list; keep only what a reviewer
# needs, so the JSON does not grow by four duplicate track objects.
sub summarize_record {
	my ($record) = @_;
	return undef unless ref $record eq 'HASH';
	my %keep = map { $_ => $record->{$_} }
		qw(ok take state channels start_sample monitor_input monitor_gain error);
	return \%keep;
}

# Wait until the take thread has actually read a block, so the transport's
# first beat is not emitted before capture is open. The lead this adds is small
# and is named in the report rather than hidden.
sub wait_for_capture {
	my ($timeout) = @_;
	my $deadline = time + ($timeout // 1.0);
	while (time < $deadline) {
		my $status = JawnOS::Audio::Engine::audio_engine_status();
		return 1 if $status->{ok}
			&& ($status->{state} // '') eq 'recording'
			&& ($status->{frames} // 0) > 0;
		sleep 0.01;
	}
	return 0;
}

sub stop_everything {
	my $transport = JawnOS::Audio::Engine::audio_engine_transport('stop', {});
	my $take = JawnOS::Audio::Engine::audio_engine_stop();
	return ($transport, $take);
}

# Start a monitor-less take, wait for capture, start the transport, let the
# take run its length, then stop both. The take has no monitor of its own, so
# the engine allows it beside the transport: the transport owns the output and
# the take owns the input.
sub take_with_transport {
	my (%args) = @_;
	my $tracks = $args{tracks} // 1;
	my $inputs = $args{inputs} // [ $args{input} // 0 ];
	my @paths = take_paths($args{path}, $tracks);

	my $record = JawnOS::Audio::Engine::audio_engine_record(
		$args{path}, $args{seconds}, 0,
		{ tracks => $tracks, inputs => $inputs },
	);
	unless ($record->{ok}) {
		return {
			ok     => 0,
			paths  => \@paths,
			record => $record,
			error  => $record->{error} // 'the take did not start',
		};
	}

	unless (wait_for_capture(1.0)) {
		stop_everything();
		return {
			ok     => 0,
			paths  => \@paths,
			record => $record,
			error  => 'the take did not begin capturing within one second',
		};
	}

	my $fields = {
		position      => 0,
		bpm           => $args{bpm},
		beats_per_bar => $args{bpb},
		gain          => $args{gain},
		loop_start    => 0,
		loop_end      => 0,
	};
	$fields->{clips} = $args{clips} if exists $args{clips};
	my $transport = JawnOS::Audio::Engine::audio_engine_transport('start', $fields);
	unless ($transport->{ok}) {
		stop_everything();
		return {
			ok        => 0,
			paths     => \@paths,
			record    => $record,
			transport => $transport,
			error     => 'the transport did not start: '
				. ($transport->{error} // 'unknown'),
		};
	}

	# The take runs exactly `seconds` on hardware; the margin lets the writer
	# finish its last block before `stop` joins it.
	sleep($args{seconds} + 0.35);
	my ($transport_stop, $take_stop) = stop_everything();

	my @missing = grep { !-f $_ } @paths;
	if (@missing) {
		my $detail = $take_stop && ($take_stop->{error} // '') ne ''
			? ': ' . $take_stop->{error}
			: '';
		return {
			ok             => 0,
			paths          => \@paths,
			record         => $record,
			transport      => $transport,
			transport_stop => $transport_stop,
			stop           => $take_stop,
			error          => 'the take did not write ' . join(', ', @missing) . $detail,
		};
	}

	return {
		ok             => 1,
		paths          => \@paths,
		record         => $record,
		transport      => $transport,
		transport_stop => $transport_stop,
		stop           => $take_stop,
	};
}

sub finish_and_exit {
	my ($report) = @_;
	$report->{ok} = $ok ? 1 : 0;
	if ($json) {
		print JSON::PP->new->canonical->encode($report), "\n";
	}
	else {
		print_report($report);
	}
	exit($report->{ok} ? 0 : 1);
}

sub print_report {
	my ($r) = @_;
	my $o = $r->{options};
	print "JawnOS audio gate: Studio P2 alignment\n";
	print "=======================================\n";
	print "device   : $o->{device}\n";
	if ($r->{device_detect} && $r->{device_detect}{ok}) {
		print "detected : card $r->{device_detect}{card} [$r->{device_detect}{id}] "
			. "$r->{device_detect}{name}\n";
	}
	my $status = $r->{engine}{status};
	if ($status && $status->{ok}) {
		print "engine   : socket $r->{engine}{socket}, backend $status->{backend}, "
			. "device $status->{device}, rate $status->{rate}, period $status->{period}, "
			. "buffer $status->{buffer}, channels $status->{device_channels}\n";
	}
	else {
		print "engine   : socket $r->{engine}{socket} - "
			. ($status->{error} // 'no answer') . "\n";
	}
	print "settings : rate $o->{rate}, period $o->{period}, buffer $o->{buffer}, "
		. "bpm $o->{bpm}, $o->{beats_per_bar} beats/bar, $o->{seconds}s, "
		. "$o->{tracks} tracks from input $o->{input}\n";
	print "takes    : $r->{take_dir}\n";
	for my $note (@{ $r->{notes} }) {
		print "note     : $note\n";
	}
	print "\n";

	print "Loopback (three runs through the staged binary)\n";
	printf "  %-4s %-10s %-10s %s\n", 'run', 'samples', 'ms', 'result';
	for my $run (@{ $r->{loopback}{runs} || [] }) {
		printf "  %-4s %-10s %-10s %s\n",
			$run->{run},
			defined $run->{samples} ? $run->{samples} : '-',
			defined $run->{ms} ? sprintf('%.3f', $run->{ms}) : '-',
			$run->{ok} ? 'ok' : 'FAIL: ' . ($run->{error} // 'no JSON line');
	}
	print '  ' . ($r->{loopback}{ok} ? 'PASS' : 'FAIL') . "\n\n";

	print_analysis('Recorded click (take start - the round-trip offset)',
		$r->{clicks}) if $r->{clicks};
	print_analysis('Playback of that take (transport click muted)',
		$r->{playback}) if $r->{playback};
	print_four($r->{four_track}) if $r->{four_track};

	print "Checks\n";
	for my $check (@{ $r->{checks} }) {
		printf "  %-4s %-28s %s\n",
			$check->{pass} ? 'PASS' : 'FAIL',
			$check->{name},
			$check->{detail};
	}
	if (@{ $r->{errors} }) {
		print "\nErrors\n";
		print "  $_\n" for @{ $r->{errors} };
	}
	print "\nRESULT: " . ($r->{ok} ? 'PASS' : 'FAIL') . "\n";
}

sub print_analysis {
	my ($title, $entry) = @_;
	print "$title\n";
	unless ($entry->{ok}) {
		print '  FAIL: ' . ($entry->{error} // 'the take did not complete') . "\n\n";
		return;
	}
	my $analysis = $entry->{analysis};
	unless ($analysis && $analysis->{ok}) {
		print '  FAIL: ' . ($analysis ? ($analysis->{error} // $analysis->{reason}) : 'no analysis')
			. "\n\n";
		return;
	}
	print "  file: $analysis->{path} ($analysis->{channels} channel(s), "
		. "$analysis->{frames} frames at $analysis->{rate} Hz)\n";
	if (defined $analysis->{first}) {
		printf "  first onset: %d samples (%.3f ms); this is the loopback round trip plus "
			. "the start lead and the detector's threshold on the click's rise\n",
			$analysis->{first}, $analysis->{first_ms};
	}
	printf "  expected %s click(s), found %d\n",
		defined $analysis->{expected} ? $analysis->{expected} : '-',
		$analysis->{count};
	if (@{ $analysis->{beats} }) {
		printf "  %-5s %-9s %-10s %-10s %s\n",
			'beat', 'bar.beat', 'sample', 'nominal', 'delta';
		for my $beat (@{ $analysis->{beats} }) {
			printf "  %-5d %-9s %-10d %-10d %+d\n",
				$beat->{index},
				"$beat->{bar}.$beat->{beat}",
				$beat->{sample},
				$beat->{nominal},
				$beat->{delta};
		}
	}
	if (defined $analysis->{max_delta}) {
		printf "  max delta: %d sample(s), tolerance %d -> %s\n",
			$analysis->{max_delta}, $analysis->{tolerance},
			$analysis->{passed} ? 'PASS' : 'FAIL';
	}
	else {
		print '  ' . ($analysis->{reason} // 'not measured') . "\n";
	}
	print "\n";
}

sub print_four {
	my ($four) = @_;
	print "Four-track take (the same patched input duplicated across tracks)\n";
	if (($four->{error} // '') ne '' && !@{ $four->{analyses} }) {
		print "  FAIL: $four->{error}\n\n";
		return;
	}
	printf "  start_sample: %s (one stamp for all %d tracks)\n",
		defined $four->{start_sample} ? $four->{start_sample} : '-',
		$four->{tracks};
	printf "  %-6s %-10s %s\n", 'track', 'first', 'result';
	for my $analysis (@{ $four->{analyses} }) {
		printf "  ch%-4d %-10s %s\n",
			$analysis->{track},
			defined $analysis->{first} ? $analysis->{first} : '-',
			$analysis->{passed}
				? 'grid OK'
				: 'FAIL: ' . ($analysis->{reason} // $analysis->{error} // 'no analysis');
	}
	printf "  first-onset spread: %s sample(s), tolerance 1\n",
		defined $four->{spread} ? $four->{spread} : '-';
	print "  This proves one shared start stamp, not four independent converters.\n";
	print '  ' . ($four->{ok} ? 'PASS' : 'FAIL') . "\n\n";
}
