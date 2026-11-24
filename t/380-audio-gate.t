# tests-for: lib/JawnOS/Audio/Gate.pm scripts/audio_gate.pl
# covers:    reading a PCM16 take, the click grid, and the CODEC card parser

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib";
use File::Temp qw(tempdir);
use Test::More;
use JawnOS::Audio::Gate qw(
	gate_read_wav
	gate_channel
	gate_find_onsets
	gate_nominal_grid
	gate_analyse
	gate_detect_device
);

my $dir = tempdir(CLEANUP => 1);

sub put_file {
	my ($path, $text) = @_;
	open my $fh, '>', $path or die "cannot write $path: $!";
	print $fh $text;
	close $fh;
	return $path;
}

# A PCM16 WAV with one impulse at each frame in `clicks`. The gate only needs
# an onset at a known sample; an impulse is the least ambiguous such signal.
sub write_wav {
	my ($path, %args) = @_;
	my $rate     = $args{rate} // 48_000;
	my $channels = $args{channels} // 1;
	my $frames   = $args{frames};
	my $clicks   = $args{clicks} // [];
	my $only     = $args{channel};
	my %click_at = map { $_ => 1 } @$clicks;

	my @samples;
	for my $frame (0 .. $frames - 1) {
		for my $channel (0 .. $channels - 1) {
			my $value = $click_at{$frame}
				&& (!defined $only || $only == $channel) ? 16_384 : 0;
			push @samples, $value;
		}
	}

	my $data = pack('v*', map { $_ & 0xFFFF } @samples);
	my $size = length $data;
	my $header = pack(
		'A4 V A4 A4 V v v V V v v A4 V',
		'RIFF', 36 + $size, 'WAVE', 'fmt ', 16,
		1, $channels, $rate, $rate * $channels * 2, $channels * 2, 16,
		'data', $size,
	);
	open my $fh, '>:raw', $path or die "cannot write $path: $!";
	print $fh $header, $data;
	close $fh;
	return $path;
}

# --- the reader ------------------------------------------------------------
my $mono = write_wav("$dir/mono.wav", frames => 60_000, clicks => [ 1000, 25_000, 49_000 ]);
my $wav = gate_read_wav($mono);
ok($wav->{ok}, 'a mono PCM16 take reads');
ok(!defined $wav->{error}, 'with no error');
is($wav->{rate}, 48_000, 'the rate comes from the fmt chunk');
is($wav->{channels}, 1, 'a mono take has one channel');
is($wav->{frames}, 60_000, 'the frames come from the data chunk');
is(scalar @{ gate_channel($wav, 0) }, 60_000, 'the channel has one sample per frame');

my $stereo = write_wav("$dir/stereo.wav",
	frames => 60_000, channels => 2, clicks => [ 1000, 25_000, 49_000 ]);
my $stereo_wav = gate_read_wav($stereo);
ok($stereo_wav->{ok}, 'a stereo PCM16 take reads');
is($stereo_wav->{channels}, 2, 'a stereo take has two channels');
is($stereo_wav->{frames}, 60_000, 'the frame count is per channel');
is(scalar @{ gate_channel($stereo_wav, 0) }, 60_000, 'the left channel is one sample per frame');
is(scalar @{ gate_channel($stereo_wav, 1) }, 60_000, 'the right channel is too');

# --- the grid --------------------------------------------------------------
my $onsets = gate_find_onsets(gate_channel($wav, 0), rate => 48_000);
is_deeply($onsets, [ 1000, 25_000, 49_000 ],
	'the onset detector reports the click samples');
is_deeply(gate_nominal_grid(1000, 3, 48_000, 120), [ 1000, 25_000, 49_000 ],
	'the nominal 120 bpm grid is 24,000 samples per beat');

my $pass = gate_analyse($mono, bpm => 120, beats_per_bar => 4, expected => 3);
ok($pass->{ok}, 'the analysis read the take');
ok($pass->{passed}, 'clicks on the 120 bpm grid pass');
is_deeply($pass->{onsets}, [ 1000, 25_000, 49_000 ], 'the onsets are the known samples');
is($pass->{first}, 1000, 'the first onset anchors the grid');
is($pass->{max_delta}, 0, 'an exact grid has no delta');
is($pass->{peak}, 0.5, 'the report names the channel peak');

my $shift = write_wav("$dir/shift.wav",
	frames => 60_000, clicks => [ 1000, 25_002, 49_000 ]);
my $bad = gate_analyse($shift, bpm => 120, expected => 3);
ok(!$bad->{passed}, 'a two-sample shift fails');
is($bad->{max_delta}, 2, 'and the delta names the shift');

my $missing = write_wav("$dir/missing.wav",
	frames => 60_000, clicks => [ 1000, 25_000 ]);
my $short = gate_analyse($missing, bpm => 120, expected => 3);
ok(!$short->{passed}, 'a missing click fails');
like($short->{reason}, qr/expected 3 click\(s\), found 2/, 'and names the count');

my $lenient = gate_analyse($missing, bpm => 120, expected => 3, strict_count => 0);
ok($lenient->{passed}, 'a short count is a note when the grid is still exact');
like($lenient->{count_note}, qr/expected 3 click\(s\), found 2/, 'and the note names the count');

my $edge = write_wav("$dir/edge.wav",
	frames => 60_000, clicks => [ 985, 25_000, 49_000 ]);
my $unsettled = gate_analyse($edge, bpm => 120, expected => 3);
ok(!$unsettled->{passed}, 'a first-click edge offset fails without a settle');
my $settled = gate_analyse($edge, bpm => 120, expected => 3, settle => 1);
ok($settled->{passed}, 'one settled click makes the steady grid exact');
is($settled->{max_delta}, 0, 'and the steady grid has no delta');
is($settled->{anchor}, 25_000, 'the grid anchors on the second onset');
is($settled->{settle}, 1, 'and reports the settled click');

my $stereo_pass = gate_analyse($stereo, channel => 1, bpm => 120, expected => 3);
ok($stereo_pass->{passed}, 'a stereo take passes on its second channel');

my $right = write_wav("$dir/right.wav",
	frames => 60_000, channels => 2, channel => 1,
	clicks => [ 1000, 25_000, 49_000 ]);
my $right_pass = gate_analyse($right, channel => 1, bpm => 120, expected => 3);
ok($right_pass->{passed}, 'the right-channel-only take passes on that channel');
is($right_pass->{peak}, 0.5, 'and its peak is the channel\'s own');
my $left_silent = gate_analyse($right, channel => 0, bpm => 120, expected => 3);
ok(!$left_silent->{passed}, 'the silent left channel has no onsets');
like($left_silent->{reason}, qr/no click onset/, 'and says why');

# --- the card parser -------------------------------------------------------
my $cards = put_file("$dir/cards", <<'CARDS');
 0 [Webcam         ]: USB-Audio - HD Pro Webcam C920
                      Logitech, Inc. HD Pro Webcam C920 at usb-0000:00:14.0-1, high speed
 1 [PCH            ]: HDA-Intel - HDA Intel PCH
                      HDA Intel PCH at 0xf7f10000 irq 30
 2 [CODEC          ]: USB-Audio - USB Audio CODEC
                      Burr-Brown from TI USB Audio CODEC at usb-0000:00:14.0-2, full speed
CARDS
my $detect = gate_detect_device($cards);
ok($detect->{ok}, 'the CODEC card is detected');
is($detect->{device}, 'hw:2,0', 'as hw:2,0');
is($detect->{card}, 2, 'card 2');
is($detect->{id}, 'CODEC', 'the card id is trimmed');
like($detect->{name}, qr/USB Audio CODEC/, 'the name says what it is');
is(scalar @{ $detect->{matches} }, 1, 'one card matches');

my $webcam = put_file("$dir/webcam", <<'CARDS');
 0 [Webcam         ]: USB-Audio - HD Pro Webcam C920
                      Logitech, Inc. HD Pro Webcam C920 at usb-0000:00:14.0-1, high speed
 1 [PCH            ]: HDA-Intel - HDA Intel PCH
                      HDA Intel PCH at 0xf7f10000 irq 30
CARDS
my $none = gate_detect_device($webcam);
ok(!$none->{ok}, 'a machine with no CODEC card is not a match');
like($none->{error}, qr/no PCM2902/, 'and says how to proceed');

my $absent = gate_detect_device("$dir/does-not-exist");
ok(!$absent->{ok}, 'a missing /proc file is an error, not a crash');
like($absent->{error}, qr/cannot read/, 'with the path and reason');

# --- refusals, not noise ---------------------------------------------------
my $not_wav = put_file("$dir/not-a-wav", 'not a wav');
my $refused = gate_read_wav($not_wav);
ok(!$refused->{ok}, 'a non-WAV is refused');
like($refused->{error}, qr/not a RIFF\/WAVE file/, 'by name');

my $missing_file = gate_read_wav("$dir/no-such-take.wav");
ok(!$missing_file->{ok}, 'a missing take is an error');
like($missing_file->{error}, qr/cannot open/, 'by name');

done_testing;
