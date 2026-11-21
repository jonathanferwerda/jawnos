package JawnOS::Audio::Gate;

# The measurement half of Studio's P2 alignment gate: read a take the engine
# wrote, find the click onsets through a patched-back cable, and compare them
# with the grid the transport was asked for. It is deliberately small and
# hardware-free: the WAV reader, an envelope onset detector and the /proc card
# parser are the only moving parts, so a test can prove the arithmetic on
# synthetic files and the script can run the same code against the UM2.
#
# Why an envelope and not a sample threshold: the engine's click is a 20 ms
# tone whose first beat of each bar is louder and 200 Hz higher. A threshold on
# the waveform alone trips several samples earlier on the accent than on the
# regular beat, which looks like a timing error that is not there. A short
# backward-looking energy window measures the click's sine envelope, and a
# second threshold taken relative to each click's own peak removes the level
# difference too. The onset position is still a *detection* position, a few
# samples after the true first sample; the gate compares onset against onset,
# so the constant part cancels and the spacing is what is measured.
#
# Nothing here starts a process, opens a device or reads a setting. PCM16 is
# the one format the engine records (`engine/src/wav.rs`), mono or stereo is
# the pair the transport takes back (`engine/src/wav_read.rs`), and every other
# shape is a named refusal rather than a take read as noise.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
	gate_read_wav
	gate_channel
	gate_mono
	gate_peak
	gate_envelope
	gate_find_onsets
	gate_beat_frames
	gate_nominal_grid
	gate_analyse
	gate_detect_device
);

# What the transport and the engine agree on unless a caller says otherwise.
our $gate_default_rate = 48_000;
our $gate_default_bpm  = 120;

# The card the P2 gate is about: a PCM2902 (Burr-Brown) USB interface, which
# ALSA reports as "USB Audio CODEC". The pattern is matched against the whole
# card block, because the useful words are often on the continuation line.
our $gate_device_pattern = qr/PCM2902|Burr-Brown|USB Audio CODEC/i;

# A click is a tone, not one sample. The envelope window is two milliseconds:
# longer than one period of either 900 Hz or 1100 Hz at 48 kHz, so the energy
# no longer depends on which accent the transport chose. The floor keeps a
# silent or noisy input from being read as a hundred clicks; the level of a
# patched-back click is about 0.004 full scale, far above it.
our $gate_envelope_seconds = 0.002;
our $gate_signal_floor     = 0.0002;
our $gate_coarse_fraction  = 0.02;
our $gate_fine_fraction    = 0.05;
our $gate_min_gap_seconds  = 0.05;
our $gate_local_span_seconds = 0.05;

# Trim the spaces ALSA pads a card id with.
sub _trim {
	my ($text) = @_;
	return '' unless defined $text;
	$text =~ s/^\s+//;
	$text =~ s/\s+$//;
	return $text;
}

# One PCM16 RIFF/WAVE file, as the engine writes it.
#
# Returns a hash either way, so a caller relays the sentence instead of
# catching a die. `samples` is interleaved little-endian i16, exactly as the
# file held it; `frames` is the per-channel count.
sub gate_read_wav {
	my ($path) = @_;
	my $fail = sub {
		return { ok => 0, path => $path, error => $_[0] };
	};
	return $fail->('read_wav needs a file path')
		unless defined $path && !ref $path && length $path;

	open my $fh, '<:raw', $path or return $fail->("cannot open $path: $!");
	local $/;
	my $bytes = <$fh>;
	close $fh;
	return $fail->("$path is empty") unless defined $bytes && length $bytes;
	return $fail->("$path is not a RIFF/WAVE file")
		unless length($bytes) >= 12
			&& substr($bytes, 0, 4) eq 'RIFF'
			&& substr($bytes, 8, 4) eq 'WAVE';

	my ($format, $data_offset, $data_size);
	my $pos = 12;
	while ($pos + 8 <= length $bytes) {
		my $id   = substr($bytes, $pos, 4);
		my $size = unpack('V', substr($bytes, $pos + 4, 4));
		my $body = $pos + 8;

		# The engine's writer keeps these sizes honest. A chunk that claims
		# more bytes than the file holds is a cut-short take, not a shape to
		# guess around.
		if ($body + $size > length $bytes) {
			return $fail->("$path is truncated: $id says $size bytes past $body")
				if $id eq 'fmt ' || $id eq 'data';
			last;
		}

		if ($id eq 'fmt ') {
			return $fail->("$path has a short fmt chunk") if $size < 16;
			my ($tag, $channels, $rate, $byte_rate, $block_align, $bits)
				= unpack('v v V V v v', substr($bytes, $body, 16));
			$format = {
				tag         => $tag,
				channels    => $channels,
				rate        => $rate,
				byte_rate   => $byte_rate,
				block_align => $block_align,
				bits        => $bits,
			};
		}
		elsif ($id eq 'data') {
			$data_offset = $body;
			$data_size   = $size;
			last;
		}

		$pos = $body + $size + ($size % 2);
	}

	return $fail->("$path has no fmt chunk")   unless $format;
	return $fail->("$path has no data chunk")  unless defined $data_offset;
	return $fail->("$path is not uncompressed PCM (format $format->{tag})")
		unless $format->{tag} == 1;
	return $fail->("$path is not 16-bit (bits $format->{bits})")
		unless $format->{bits} == 16;
	return $fail->("$path has $format->{channels} channels; only mono and stereo are read")
		unless $format->{channels} == 1 || $format->{channels} == 2;

	my $pcm = substr($bytes, $data_offset, $data_size);
	# A whole frame is 2 or 4 bytes; an odd tail is a malformed data chunk,
	# and dropping it is safer than unpacking half a sample.
	$pcm = substr($pcm, 0, length($pcm) - 1) if length($pcm) % 2;
	my @samples = unpack('s<*', $pcm);

	return {
		ok       => 1,
		path     => $path,
		rate     => $format->{rate},
		channels => $format->{channels},
		bits     => 16,
		frames   => int(@samples / $format->{channels}),
		samples  => \@samples,
	};
}

# One channel as normalised floats (-1..1), which is what both the detector
# and a person reading a report expect. An out-of-range channel is `undef`;
# the caller already has the shape from `gate_read_wav`.
sub gate_channel {
	my ($wav, $channel) = @_;
	return undef unless ref $wav eq 'HASH' && $wav->{ok};
	$channel = 0 unless defined $channel;
	return undef if $channel < 0 || $channel >= $wav->{channels};

	my $channels = $wav->{channels};
	my $samples  = $wav->{samples};
	my @out;
	for (my $i = $channel; $i < @$samples; $i += $channels) {
		push @out, $samples->[$i] / 32768;
	}
	return \@out;
}

# The take as one mono timeline. Summing is the engine's own rule
# (`WavAudio::mono`): a centred source at gain g is g/√2 in each channel, and
# the sum restores g. Detection only needs the shape, but using the same rule
# keeps a mono and a stereo take directly comparable in a report.
sub gate_mono {
	my ($wav) = @_;
	return undef unless ref $wav eq 'HASH' && $wav->{ok};

	my $channels = $wav->{channels};
	my $samples  = $wav->{samples};
	my @out;
	if ($channels == 1) {
		@out = map { $_ / 32768 } @$samples;
	}
	else {
		for (my $i = 0; $i + 1 < @$samples; $i += 2) {
			push @out, ($samples->[$i] + $samples->[$i + 1]) / 32768;
		}
	}
	return \@out;
}

# The largest absolute normalised sample. `undef` channel means the whole take
# (the mono sum); a channel number means that channel alone.
sub gate_peak {
	my ($wav, $channel) = @_;
	my $samples = defined $channel ? gate_channel($wav, $channel) : gate_mono($wav);
	return 0 unless $samples;

	my $peak = 0;
	for my $sample (@$samples) {
		my $value = abs $sample;
		$peak = $value if $value > $peak;
	}
	return $peak;
}

# A backward-looking mean-square envelope. The window is short in seconds, so
# the same options mean the same thing at any rate. This is what makes an
# accented 1100 Hz click and a regular 900 Hz click cross the detector at the
# same place in their shared sine envelope.
sub gate_envelope {
	my ($samples, $window) = @_;
	return [] unless ref $samples eq 'ARRAY';

	$window = 1 unless defined $window && $window =~ /\A\d+\z/ && $window >= 1;
	my $count = @$samples;
	my @energy = (0) x $count;
	my $sum = 0;
	for my $index (0 .. $count - 1) {
		my $sample = $samples->[$index];
		$sum += $sample * $sample;
		my $drop = $index - $window;
		if ($drop >= 0) {
			my $old = $samples->[$drop];
			$sum -= $old * $old;
		}
		$energy[$index] = $sum / $window;
	}
	return \@energy;
}

# The onset sample of every click, in order.
#
# Two thresholds: a coarse crossing finds a click region, and a fine crossing
# taken relative to that click's own peak places the onset. The fine crossing
# is the same fraction of every click's envelope, so the accent's extra level
# does not move it. `min_gap_samples` is a refractory period: the engine's
# click is 20 ms and the default beat spacing is 500 ms, so one click cannot
# count twice.
sub gate_find_onsets {
	my ($samples, $opts) = @_;
	$opts = {} unless ref $opts eq 'HASH';
	return [] unless ref $samples eq 'ARRAY' && @$samples;

	my $rate = $opts->{rate};
	$rate = $gate_default_rate unless defined $rate && $rate > 0;

	my $window = $opts->{window};
	$window = int($rate * $gate_envelope_seconds) unless defined $window && $window > 0;
	$window = 1 if $window < 1;

	my $envelope = gate_envelope($samples, $window);
	my $count = @$envelope;
	return [] unless $count;

	my $peak = 0;
	for my $value (@$envelope) {
		$peak = $value if $value > $peak;
	}
	my $floor = $opts->{floor};
	$floor = $gate_signal_floor unless defined $floor;
	return [] if $peak < $floor * $floor;

	my $coarse_fraction = $opts->{peak_fraction};
	$coarse_fraction = $gate_coarse_fraction unless defined $coarse_fraction;
	my $coarse = $peak * $coarse_fraction;
	return [] if $coarse <= 0;

	my $fine_fraction = $opts->{fine_fraction};
	$fine_fraction = $gate_fine_fraction unless defined $fine_fraction;
	my $min_gap = $opts->{min_gap_samples};
	$min_gap = int($rate * $gate_min_gap_seconds) unless defined $min_gap;
	$min_gap = 1 if $min_gap < 1;
	my $local_span = $opts->{local_span_samples};
	$local_span = int($rate * $gate_local_span_seconds) unless defined $local_span;
	$local_span = 1 if $local_span < 1;

	my @onsets;
	my $index = 0;
	while ($index < $count) {
		if ($envelope->[$index] < $coarse) {
			$index++;
			next;
		}

		# The click's own peak is within the next few milliseconds. Reading it
		# locally is what removes the accent/regular level difference.
		my $end = $index + $local_span;
		$end = $count if $end > $count;
		my $local = 0;
		for my $probe ($index .. $end - 1) {
			$local = $envelope->[$probe] if $envelope->[$probe] > $local;
		}
		my $fine = $local * $fine_fraction;

		my $onset = $index;
		my $probe = $index;
		$probe++ while $probe < $end && $envelope->[$probe] < $fine;
		$onset = $probe if $probe < $end;

		push @onsets, $onset;
		$index = $onset + $min_gap;
	}
	return \@onsets;
}

# The nominal distance between beats, in samples. Kept fractional: rounding
# once per beat (in `gate_nominal_grid`) is what keeps a non-integer tempo
# from accumulating a drift the transport does not have.
sub gate_beat_frames {
	my ($rate, $bpm) = @_;
	return undef unless defined $rate && $rate > 0
		&& defined $bpm && $bpm > 0;
	return $rate * 60 / $bpm;
}

sub gate_nominal_grid {
	my ($first, $count, $rate, $bpm) = @_;
	my $frames = gate_beat_frames($rate, $bpm);
	return undef unless defined $frames;
	$count = 0 unless defined $count && $count > 0;
	my @grid;
	for my $beat (0 .. $count - 1) {
		push @grid, $first + int($beat * $frames + 0.5);
	}
	return \@grid;
}

# The whole alignment answer for one take.
#
# The first onset anchors the grid: it is the click the take happened to catch
# first, so the report calls it the offset. Every later onset is compared with
# that anchor plus a whole number of beats; `passed` is true when every delta
# is within `tolerance` samples (one by default).
#
# `expected` is the number of clicks the caller knows were played. A missed
# click is not a pass with a shorter grid: it is a failure that names the
# count. Without `expected`, any two onsets are enough to measure spacing.
sub gate_analyse {
	my ($input, %opts) = @_;
	my $wav = ref $input eq 'HASH' ? $input : gate_read_wav($input);

	my $report = {
		ok            => 0,
		passed        => 0,
		path          => ref $input eq 'HASH' ? ($input->{path} // '') : $input,
		error         => '',
		reason        => '',
		onsets        => [],
		count         => 0,
		beats         => [],
		max_delta     => undef,
		first         => undef,
		first_ms      => undef,
		beat_frames   => undef,
		tolerance     => defined $opts{tolerance} ? $opts{tolerance} : 1,
		bpm           => defined $opts{bpm} ? $opts{bpm} : $gate_default_bpm,
		beats_per_bar => defined $opts{beats_per_bar} ? $opts{beats_per_bar} : 4,
		channel       => defined $opts{channel} ? $opts{channel} : 0,
		expected      => $opts{expected},
	};

	unless (ref $wav eq 'HASH' && $wav->{ok}) {
		$report->{error} = $wav->{error} // 'the take could not be read';
		$report->{reason} = $report->{error};
		return $report;
	}

	$report->{ok}       = 1;
	$report->{rate}     = $wav->{rate};
	$report->{channels} = $wav->{channels};
	$report->{frames}   = $wav->{frames};
	$report->{path}     = $wav->{path};

	my $rate = $opts{rate};
	$rate = $wav->{rate} unless defined $rate && $rate > 0;
	$report->{rate_used} = $rate;

	my $samples = $opts{mono}
		? gate_mono($wav)
		: gate_channel($wav, $report->{channel});
	unless ($samples) {
		$report->{reason} = "channel $report->{channel} is not in this take";
		return $report;
	}
	$report->{peak} = gate_peak($samples);

	my %detector;
	for my $key (qw(threshold floor peak_fraction fine_fraction
		min_gap_samples local_span_samples window)) {
		$detector{$key} = $opts{$key} if exists $opts{$key};
	}
	# `threshold` is the documented absolute floor; the detector's own name
	# for the same number is `floor`.
	$detector{floor} = $detector{threshold}
		if exists $detector{threshold} && !exists $detector{floor};
	$detector{rate} = $rate;

	my $onsets = gate_find_onsets($samples, \%detector);
	$report->{onsets} = $onsets;
	$report->{count}  = scalar @$onsets;

	my $beat_frames = gate_beat_frames($rate, $report->{bpm});
	$report->{beat_frames} = $beat_frames;

	if (!@$onsets) {
		$report->{reason} = 'no click onset above the detector threshold';
		return $report;
	}

	my $first = $onsets->[0];
	$report->{first} = $first;
	$report->{first_ms} = $first / $rate * 1000;

	if (defined $report->{expected} && @$onsets != $report->{expected}) {
		my $note = sprintf(
			'expected %d click(s), found %d',
			$report->{expected}, scalar @$onsets,
		);
		if ($opts{strict_count} // 1) {
			$report->{reason} = $note;
			return $report;
		}
		# The hardware take starts after the transport and a quiet regular beat
		# can fall under the detector; the grid is still the measurement. The
		# caller keeps the count as a note rather than a failure.
		$report->{count_note} = $note;
	}

	# `settle` drops the first N onsets from the grid. A clip's first click can
	# sit on the transport's start edge, where the mixer's gain has not reached
	# its settled level; the later clicks are the steady grid. The dropped
	# onsets still count, but they do not move the anchor.
	my $settle = $opts{settle} // 0;
	$settle = 0 unless defined $settle && $settle =~ /\A\d+\z/;
	$report->{settle} = $settle;
	if ($settle > $#$onsets - 1) {
		$report->{reason} = $settle
			? "a grid needs at least two onsets after the first $settle"
			: 'a grid needs at least two onsets to measure spacing';
		return $report;
	}

	my $anchor = $onsets->[$settle];
	$report->{anchor}     = $anchor;
	$report->{anchor_ms}  = $anchor / $rate * 1000;
	my $bars  = $report->{beats_per_bar};
	$bars = 1 unless defined $bars && $bars > 0;
	my @beats;
	my $max_delta = 0;
	for my $index ($settle + 1 .. $#$onsets) {
		my $ordinal = $index - $settle;
		my $nominal = $anchor + int($ordinal * $beat_frames + 0.5);
		my $delta   = $onsets->[$index] - $nominal;
		$max_delta = abs($delta) if abs($delta) > $max_delta;
		push @beats, {
			index   => $ordinal,
			bar     => int($ordinal / $bars) + 1,
			beat    => ($ordinal % $bars) + 1,
			sample  => $onsets->[$index],
			nominal => $nominal,
			delta   => $delta,
		};
	}
	$report->{beats}     = \@beats;
	$report->{max_delta} = $max_delta;
	$report->{passed}    = $max_delta <= $report->{tolerance} ? 1 : 0;
	$report->{reason}    = $report->{passed}
		? ($settle
			? "every onset after the first $settle is within $report->{tolerance} sample(s) of the $report->{bpm} bpm grid"
			: "every onset is within $report->{tolerance} sample(s) of the $report->{bpm} bpm grid")
		: "an onset is $max_delta sample(s) from the $report->{bpm} bpm grid (tolerance $report->{tolerance})";
	return $report;
}

# Find the PCM2902 / Burr-Brown / "USB Audio CODEC" card in /proc/asound/cards
# and return the ALSA PCM name (`hw:N,0`) the engine and `--loopback` take.
#
# A card block is its bracketed header line plus every indented continuation
# line, because the useful words are often on the second line. The first match
# wins: a machine with two such interfaces is a machine where the operator
# should pass `--device`.
sub gate_detect_device {
	my ($path) = @_;
	$path = '/proc/asound/cards' unless defined $path && length $path;

	my $report = {
		ok      => 0,
		path    => $path,
		error   => '',
		cards   => [],
		matches => [],
	};

	open my $fh, '<', $path or do {
		$report->{error} = "cannot read $path: $!";
		return $report;
	};

	my @cards;
	my $current;
	while (defined(my $line = <$fh>)) {
		chomp $line;
		if ($line =~ /^\s*(\d+)\s+\[([^\]]*)\]\s*:\s*(.*)$/) {
			$current = {
				card   => 0 + $1,
				id     => _trim($2),
				header => _trim($3),
				lines  => [ $line ],
			};
			push @cards, $current;
		}
		elsif ($current && $line =~ /^\s+\S/) {
			push @{ $current->{lines} }, $line;
		}
	}
	close $fh;

	$report->{cards} = \@cards;
	for my $card (@cards) {
		my $text = join("\n", @{ $card->{lines} });
		next unless $text =~ $gate_device_pattern;
		push @{ $report->{matches} }, {
			card   => $card->{card},
			id     => $card->{id},
			name   => $card->{header},
			device => "hw:$card->{card},0",
			match  => $&,
		};
	}

	if (@{ $report->{matches} }) {
		my $match = $report->{matches}[0];
		$report->{ok}     = 1;
		$report->{card}   = $match->{card};
		$report->{id}     = $match->{id};
		$report->{name}   = $match->{name};
		$report->{device} = $match->{device};
		$report->{match}  = $match->{match};
		return $report;
	}

	$report->{error} = "no PCM2902 / Burr-Brown / USB Audio CODEC card in $path; pass --device hw:N,0";
	return $report;
}

1;
