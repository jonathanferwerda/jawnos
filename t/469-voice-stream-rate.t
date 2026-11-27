# tests-for: lib/JawnOS/Domain/Ai.pm lib/JawnOS/Domain/Ble2.pm jw/jw_01_globals.ino jw/jw_07_house_audio.ino jw/jw_08_voice.ino jw/jw_09_voice_ship.ino
# covers:    A streamed watch clip carries its capture rate: adpcm_wav_wrap writes
#           it into the WAV header (and still defaults to 8 kHz for an older watch),
#           and Ble2 forwards the voice_stream message's rate to that wrapper. The
#           IMA ADPCM block layout stays 1024 bytes / 2041 samples at either rate.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use MIME::Base64 qw(encode_base64);
use Mojo::JSON qw(encode_json);
use File::Slurp qw(read_file);

use JawnOSTest;

require(root() . '/lib/JawnOS/Domain/Ai.pm');
require JawnOS::Domain::Ble2;

# adpcm_wav_wrap writes a 60-byte RIFF/fmt/fact/data header. These read the same
# fields the server's wrapper and the watch's file path name.
sub header_u32 { return unpack('V', substr($_[0], $_[1], 4)); }
sub header_u16 { return unpack('v', substr($_[0], $_[1], 2)); }

# Two IMA ADPCM blocks. The wrapper only reads the length, so the bytes are filler.
my $audio = 'Z' x 2048;

# ------------------------------------------------------------ the default rate
{
	my $wav = subs::adpcm_wav_wrap($audio);
	is(length($wav), 60 + length($audio), 'a 60-byte header rides in front of the blocks');
	is(substr($wav, 0, 4), 'RIFF', 'and starts as a RIFF file');
	is(header_u32($wav, 24), 8000, 'an absent rate is 8 kHz, for an older watch');
	is(header_u32($wav, 28), int(8000 * 1024 / 2041), 'the byte rate follows 8 kHz');
	is(header_u16($wav, 32), 1024, 'the block align is 1024 bytes');
	is(header_u16($wav, 38), 2041, 'and a block carries 2041 samples');
	is(header_u32($wav, 48), 2 * 2041, 'fact counts both blocks at 2041 samples');
	is(header_u32($wav, 56), length($audio), 'the data size is the encoded length');
	is(substr($wav, 60), $audio, 'the encoded bytes are untouched');
}

# An explicit 8 kHz is what every watch sent before the rate field existed.
is(subs::adpcm_wav_wrap($audio, 8000), subs::adpcm_wav_wrap($audio),
	'explicit 8 kHz is byte-identical to the default');

# ------------------------------------------------------------ 16 kHz
{
	my $wav = subs::adpcm_wav_wrap($audio, 16000);
	is(header_u32($wav, 24), 16000, '16 kHz is written into the fmt header');
	is(header_u32($wav, 28), int(16000 * 1024 / 2041), 'and the byte rate follows 16 kHz');
	is(header_u16($wav, 32), 1024, 'a 16 kHz block is still 1024 bytes');
	is(header_u16($wav, 38), 2041, 'and still 2041 samples: the layout is rate-independent');
	is(header_u32($wav, 48), 2 * 2041, 'so the fact sample count does not move either');
	is(length($wav), 60 + length($audio), 'the header is the same length');
	is(substr($wav, 60), $audio, 'and the encoded bytes ride through untouched');
}

# ------------------------------------------------------------ Ble2 forwards it
# The watch streams in parts; only the part marked last is reassembled and
# wrapped. Feed each clip two parts and check what the wrapper was handed.
{
	local $gb::voice_rx = {};
	my @rates;
	{
		no warnings 'redefine';
		local *subs::ble_link_key = sub { return '' };
		local *subs::ble_device_record = sub { };
		local *subs::voice_clip_fresh = sub { return 1 };
		local *subs::adpcm_wav_wrap = sub {
			my ($bytes, $rate) = @_;
			push @rates, $rate;
			return 'WAV';
		};
		local *subs::bluetooth_sender_async = sub { };
		local *subs::subprocessor = sub { };

		my $part = encode_base64('A' x 200, '');
		my $stream = sub {
			my ($ts, $rate) = @_;
			foreach my $last (0, 1) {
				my $msg = {
					type => 'voice_stream', chip_id => 'watch-1', edt => 'watch',
					ts => $ts, voice => 'vad', seq => $last, last => $last,
					audio => $part,
				};
				$msg->{'rate'} = $rate if defined $rate;
				subs::ble_message_processor(encode_json($msg), '');
			}
		};
		$stream->(1, 16000);
		$stream->(2, 8000);
		$stream->(3, undef);
	}
	is(scalar @rates, 3, 'each completed clip is wrapped once');
	is($rates[0], 16000, 'a 16 kHz stream reaches the wrapper as 16000');
	is($rates[1], 8000, 'an 8 kHz stream reaches it as 8000');
	ok(!defined $rates[2], 'no rate in the message reaches it as absent, so 8 kHz is the default');
}

# ------------------------------------------------------------ the watch's choice
# The firmware cannot run here, so pin the decision points the server's rate
# field depends on: which copy each transport gets, and what names its rate.
my $voice = read_file('jw/jw_08_voice.ino');
like($voice, qr/voice_compress_clip\(const String &in_path, const String &out_path, bool fold_half, uint32_t rate\)/,
	'the compressor takes the output rate');
like($voice, qr/voice_wr32\(buf \+ 24, rate\); voice_wr32\(buf \+ 28, abps\)/,
	'and writes that rate into the fmt header and byte rate');
like($voice, qr/\\"rate\\":8000/, 'the live stream message carries its fixed 8 kHz rate');

my $ship = read_file('jw/jw_09_voice_ship.ino');
like($ship, qr/capture_rate = \(WiFi\.status\(\) == WL_CONNECTED\) \? MIC_I2S_SAMPLE_RATE : VOICE_SAMPLE_RATE/,
	'the file rate is chosen from WiFi at capture start');
like($ship, qr/f\.write\(\(uint8_t \*\)in16, n \* 2\)/, 'a WiFi capture writes the full-rate samples');
like($ship, qr/f\.write\(\(uint8_t \*\)folded, m \* 2\)/, 'otherwise it writes the folded samples');
like($ship, qr/voice_stream_feed\(folded, m\)/, 'the live stream always gets the folded copy');
like($ship, qr/finalize_wav_sizes\(VOICE_WAV_PATH\.c_str\(\), pcm_bytes, capture_rate\)/,
	'the WAV header is finalized at that same rate');
like($ship, qr/voice_compress_clip\(VOICE_WAV_PATH, VOICE_ADPCM_PATH, false, capture_rate\)/,
	'and the compressed header carries it too');

my $globals = read_file('jw/jw_01_globals.ino');
like($globals, qr/voice_compress_clip\(const String &in_path, const String &out_path, bool fold_half, uint32_t rate\)/,
	'the forward declaration takes the rate');

my $house = read_file('jw/jw_07_house_audio.ino');
like($house, qr/voice_compress_clip\(src, packed, true, MIC_I2S_SAMPLE_RATE \/ 2\)/,
	'the Rec memo folds to half the mic rate and names it');

done_testing();
