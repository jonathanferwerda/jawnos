# tests-for: lib/JawnOS/Domain/Ai.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Say.pm perl/watch.pl
# covers:    The house side of the watch's voice path, and the chunked WiFi upload
#           that overlaps the send with the recording. voice_clip_shape says what
#           an arriving clip actually is (container, rate, non-zero samples), so a
#           silent capture is distinguishable from a clip that never arrived.
#           voice_stream_chunk assembles per-session chunks under a bounded home
#           directory, wraps raw IMA ADPCM once, and refuses a bad session, an
#           oversized chunk, or a session that was never opened. /watch/voice now
#           refuses (403/400) instead of answering a false 200, and
#           /watch/voice/stream runs the assembly and hands the last chunk to
#           voice_ingest as source=stream. The reply transport stamps a timing
#           ledger line so the ~5 s budget is measurable.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);

require(root() . '/lib/JawnOS/Domain/Ai.pm');

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

$subs::say_quiet = 1;

# ------------------------------------------------------------ the loader map
ok(subs::provides('voice_clip_shape'), 'voice_clip_shape is in the domain loader');
ok(subs::provides('voice_stream_chunk'), 'voice_stream_chunk is in the domain loader');

# ------------------------------------------------------------ clip shape
sub pcm_wav {
	my ($pcm, $rate) = @_;
	$rate ||= 8000;
	return 'RIFF' . pack('V', 36 + length($pcm)) . 'WAVE'
		. 'fmt ' . pack('VvvVVvv', 16, 1, 1, $rate, $rate * 2, 2, 16)
		. 'data' . pack('V', length($pcm)) . $pcm;
}

{
	my $audio = 'Z' x 2048;   # two IMA ADPCM blocks of non-zero bytes
	my $wav = subs::adpcm_wav_wrap($audio, 8000);
	my $shape = subs::voice_clip_shape($wav);
	like($shape, qr/\Abytes=\d+ wav=adpcm rate=8000 ch=1 bits=4/,
		'an ADPCM clip names its container, rate and width');
	like($shape, qr/data=2048 nonzero=2048\/2048/, 'and its data is not silence');

	my $silent = subs::adpcm_wav_wrap("\0" x 2048, 8000);
	like(subs::voice_clip_shape($silent), qr/nonzero=0\/2048/,
		'an all-zero clip is recognised as silence');

	my $pcm = pcm_wav('P' x 200, 16000);
	my $pshape = subs::voice_clip_shape($pcm);
	like($pshape, qr/wav=pcm rate=16000 ch=1 bits=16/, 'a PCM clip names PCM and its rate');
	like($pshape, qr/data=200 nonzero=200\/200/, 'and counts its data');

	like(subs::voice_clip_shape('hello'), qr/\Abytes=5 raw nonzero=5\/5\z/,
		'raw bytes are reported as raw, not guessed into a WAV');
	is(subs::voice_clip_shape(''), 'bytes=0', 'an empty clip says zero bytes');
}

# ------------------------------------------------------------ chunk assembly
{
	my $home = tempdir('jawnos-voice-stream-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	local $ENV{'HOME'} = $home;
	local $subs::home_dir = $home;

	my $A = 'A' x 1024;
	my $B = 'B' x 1024;
	my $C = 'C' x 1024;
	my $t_arrival = subs::rightNow() - 500;
	my %base = (chip_id => 'watch-chip', ts => 1_700_000_000, session => 'sess-1',
		voice => 'command', rate => 16000, t_arrival => $t_arrival);

	my $r0 = subs::voice_stream_chunk($A, { %base, seq => 0, last => 0 });
	is($r0->{'status'}, 'ok', 'the first chunk opens the session');
	is($r0->{'bytes'}, 1024, 'and counts its bytes');
	is($r0->{'t_arrival'}, $t_arrival, 'the session keeps the first chunk arrival for the ledger');

	my $r1 = subs::voice_stream_chunk($B, { %base, seq => 1, last => 0 });
	is($r1->{'status'}, 'ok', 'a middle chunk appends');
	is($r1->{'bytes'}, 2048, 'and the running byte count grows');

	my $r2 = subs::voice_stream_chunk($C, { %base, seq => 2, last => 1 });
	is($r2->{'status'}, 'complete', 'the last chunk completes the clip');
	is($r2->{'bytes'}, 3072, 'with all the chunk bytes');
	is($r2->{'rate'}, 16000, 'at the rate the session declared');
	is($r2->{'wav'}, subs::adpcm_wav_wrap($A . $B . $C, 16000),
		'the assembly is wrapped in exactly one ADPCM header');
	is(length($r2->{'wav'}), 60 + 3072, 'with a 60-byte header and the bytes after it');
	is(unpack('V', substr($r2->{'wav'}, 24, 4)), 16000, 'and the header names 16 kHz');

	my $dir = "$home/.president/voice-stream";
	my @left = -d $dir ? do { opendir(my $dh, $dir); grep { !/^\.\.?\z/ } readdir $dh } : ();
	is_deeply(\@left, [], 'a completed session leaves no part or meta file behind');
}

# ------------------------------------------------------------ refusals
{
	my $home = tempdir('jawnos-voice-stream-bad-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	local $ENV{'HOME'} = $home;
	local $subs::home_dir = $home;

	is(subs::voice_stream_chunk('x', { chip_id => 'c', ts => 1, session => 'bad id', seq => 0 })->{'status'},
		'bad_session', 'a session id with a space is refused');
	is(subs::voice_stream_chunk('x', { chip_id => '', ts => 1, session => 's', seq => 0 })->{'status'},
		'bad_session', 'a chunk with no chip is refused');
	is(subs::voice_stream_chunk('x', { chip_id => 'c', ts => 'x', session => 's', seq => 0 })->{'status'},
		'bad_session', 'a non-numeric clip stamp is refused');
	is(subs::voice_stream_chunk('x', { chip_id => 'c', ts => 1, session => 'never-opened', seq => 2 })->{'status'},
		'no_session', 'a later chunk for a session that never opened is refused');

	my $big = 'x' x (512 * 1024 + 1);
	is(subs::voice_stream_chunk($big, { chip_id => 'c', ts => 1, session => 'big', seq => 0 })->{'status'},
		'too_large', 'an oversized chunk is refused');

	my $tiny = subs::voice_stream_chunk('x' x 50,
		{ chip_id => 'c', ts => 2, session => 'tiny', seq => 0, last => 1 });
	is($tiny->{'status'}, 'empty', 'a completed clip too small to hold speech is refused');

	# A session nobody finished is swept on the next chunk (the watch went away).
	my $dir = "$home/.president/voice-stream";
	make_path($dir);
	my $old = "$dir/abandoned.part";
	write_file($old, { binmode => ':raw' }, 'x' x 8);
	my $past = time() - 300;
	utime($past, $past, $old);
	subs::voice_stream_chunk('y', { chip_id => 'c', ts => 3, session => 'fresh', seq => 0 });
	ok(!-e $old, 'a session abandoned for over two minutes is swept');
}

# ------------------------------------------------------------ a WAV is not wrapped twice
{
	my $home = tempdir('jawnos-voice-stream-wav-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	local $ENV{'HOME'} = $home;
	local $subs::home_dir = $home;

	my $full = pcm_wav('P' x 400, 8000);
	my %base = (chip_id => 'c', ts => 9, session => 'wav', voice => 'command', rate => 8000);
	subs::voice_stream_chunk(substr($full, 0, 100), { %base, seq => 0 });
	subs::voice_stream_chunk(substr($full, 100, 100), { %base, seq => 1 });
	my $done = subs::voice_stream_chunk(substr($full, 200), { %base, seq => 2, last => 1 });
	is($done->{'status'}, 'complete', 'whole WAV chunks complete');
	is($done->{'wav'}, $full, 'and are not wrapped in a second RIFF header');
}

# ------------------------------------------------------------ the ingest ledger
{
	my $home = tempdir('jawnos-voice-ledger-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	local $ENV{'HOME'} = $home;
	local $subs::home_dir = $home;
	my @logged;
	{
		no warnings 'redefine';
		local *TLog::info = sub { push @logged, $_[1] };
		local *TLog::error = sub { push @logged, $_[1] };
		local $subs::log = bless {}, 'TLog';
		local *subs::whisper_transcribe = sub { return $main::WHISPER };
		local *subs::voice_warm_piper = sub { return 0 };

		# A clip that arrived and was silent: the arrival line must already name
		# the mode and the bytes before the silence line explains the outcome.
		$main::WHISPER = '';
		my $silent = subs::voice_ingest('ABCDEFG',
			{ voice => 'vad', chip_id => 'ledger-chip', ts => 1_700_000_000 });
		is($silent->{'status'}, 'silence', 'a silent transcript stops at the ingest');
		ok(scalar(grep { /voice: arrival source=file mode=vad chip=ledger-chip .*nonzero=7\/7/ } @logged),
			'the arrival line names source, mode, chip and the bytes');
		ok(scalar(grep { /voice: stt empty .*mode=vad/ } @logged),
			'and an empty transcript says so');

		# The same clip again is a duplicate and says which copy it was.
		@logged = ();
		my $dupe = subs::voice_ingest('ABCDEFG',
			{ voice => 'vad', chip_id => 'ledger-chip', ts => 1_700_000_000 });
		is($dupe->{'status'}, 'duplicate', 'the second copy is a duplicate');
		ok(scalar(grep { /voice: duplicate clip dropped .*mode=vad source=file/ } @logged),
			'the duplicate line names the mode and source');

		# A memo stream is deferred before whisper, and the ledger still shows it.
		@logged = ();
		my $deferred = subs::voice_ingest('raw',
			{ voice => 'note', source => 'stream', chip_id => 'ledger-chip', ts => 1_700_000_100 });
		is($deferred->{'status'}, 'deferred', 'a streamed memo waits for its file');
		ok(scalar(grep { /voice: memo streamed; waiting for the whole-clip file/ } @logged),
			'and the deferral is on the ledger');
		ok(scalar(grep { /voice: arrival source=stream mode=note/ } @logged),
			'with the arrival line naming the stream and the note mode');

		# A note too short to keep says why it was dropped.
		@logged = ();
		is(subs::voice_note_store('two words', 1_700_000_200, 'ledger-chip'), undef,
			'a two-word clip is still not a note');
		ok(scalar(grep { /voice: note dropped \(fewer than three words\)/ } @logged),
			'and the log says it was too short, not that it failed');
	}
}

# ------------------------------------------------------------ the routes
{
	my $watch = read_file('perl/watch.pl');
	like($watch, qr{post '/watch/voice/stream' => sub\(\$c\)},
		'the chunked upload route exists');
	like($watch, qr/my \$session = \$c->param\('session'\)/, 'it reads a session id');
	like($watch, qr/subs::voice_stream_chunk\(\$chunk/, 'and hands each chunk to the assembler');
	like($watch, qr/source => 'stream'/, 'the completed clip reaches voice_ingest as a stream');
	like($watch, qr/voice: stream rejected \(authorization\)/, 'a refused stream is logged');
	like($watch, qr/rendered\(400\)/, 'an unusable chunk is refused, not acked');
	like($watch, qr/if \(\$voice ne 'note'\)/, 'only a command stream sends voice_recv at once');
	like($watch, qr/voice: timing stage=/, 'the route stamps an upload ledger line');
	like($watch, qr/source=stream session=/, 'naming the stream and its session');

	# The whole-clip route: it must log the arrival, and it must not answer a
	# success to a clip it did not take.
	like($watch, qr/voice: arrival route=wifi source=file/, 'the WiFi arrival is logged with its bytes');
	like($watch, qr/voice_clip_shape\(\$raw\)/, 'and the arrival says what the bytes are');
	like($watch, qr/voice: wifi clip rejected \(authorization\)/, 'a refused clip is logged');
	like($watch, qr/voice: wifi clip too short/, 'and a too-short body is refused');
}

{
	my $say = read_file('lib/JawnOS/Domain/Say.pm');
	like($say, qr/voice: timing stage=reply transport=/, 'the reply transport has a ledger line');
	like($say, qr/since_onset=/, 'carrying the person-side clock');
	like($say, qr/since_arrival=/, 'and the arrival-side clock the budget is measured against');
}

done_testing();
