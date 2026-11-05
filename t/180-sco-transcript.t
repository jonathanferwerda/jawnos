# tests-for: lib/JawnOS/Sco/Gateway.pm lib/JawnOS/Domain/Phone.pm lib/JawnOS/Controller/manager_phone.pm perl/sco/sco_helper.c scripts/vosk_stream.py public/js/manager/phone.js templates/apps/phone.html.ep public/js/manager/websocket/01_message_handler.js
# covers:    A screened call's live transcript: the helper's non-blocking tap
#           above the recorder's gate, the gateway keeping a sentence in the
#           status and on disk, the partial that is not yet a line, a bounded
#           history, the Phone pane's bubbles, and the streamer's segmentation
#           arithmetic without Vosk installed.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use JSON::PP;

use RepoSource;
use JawnOSTest;

use lib repo_root() . '/lib';
use JawnOS::Sco::Gateway;

my $repo = root();
my $dir  = tempdir(CLEANUP => 1);

# --------------------------------------------------------- the helper's tap
my $helper = read_file("$repo/perl/sco/sco_helper.c");
like($helper, qr/--tee/, 'the helper takes a tee FIFO');
like($helper, qr/tee_chunk\(buf, len\);\s*\n\s*if \(!rec_active\)/,
	'the tap is above the recorder gate, so the whole call is heard, not only the name');
like($helper, qr/tee_fd = open\(tee_path, O_WRONLY \| O_NONBLOCK\)/,
	'a reader that is slow or gone cannot stall the audio');

# --------------------------------------------------------- the gateway's side
my $gw = JawnOS::Sco::Gateway->new(
	dir => $dir,
	helper => ['/bin/false'],
	status_path => "$dir/sco.json",
	pipe => 1,
);
$gw->{'call_id'} = 'test-call';
$gw->{'peer'} = '00:11:22:33:44:55';
$gw->{'transcript_file'} = "$dir/caller.jsonl";

$gw->_transcript_event({ event => 'partial', text => 'may i ask' });
is($gw->status->{'partial'}, 'may i ask', 'the sentence being said is in the status');
is(scalar @{ $gw->status->{'transcript'} }, 0, 'a partial is not a finished line yet');

$gw->_transcript_event({ event => 'line', text => 'may i ask whose calling', ms => 2400 });
is(scalar @{ $gw->status->{'transcript'} }, 1, 'a finished line is kept');
is($gw->status->{'transcript'}->[0]->{'text'}, 'may i ask whose calling', 'as the caller said it');
is($gw->status->{'transcript'}->[0]->{'who'}, 'caller', 'and attributed to the caller');
is($gw->status->{'partial'}, '', 'the partial is cleared when its line lands');
ok(-s "$dir/caller.jsonl", 'the line is on disk for the Chat app to file');
my ($saved) = map { eval { decode_json($_) } } grep { /\S/ } split /\n/, read_file("$dir/caller.jsonl");
is($saved->{'text'}, 'may i ask whose calling', 'the saved line carries the same words');

$gw->_transcript_event({ event => 'error', message => 'the model would not load' });
like($gw->status->{'transcript_note'}, qr/model would not load/,
	'a reader that fails says why, and the call carries on');
is(scalar @{ $gw->status->{'transcript'} }, 1, 'an error does not disturb the lines already heard');

for my $n (1 .. 205) {
	$gw->_transcript_event({ event => 'line', text => "line $n" });
}
is(scalar @{ $gw->status->{'transcript'} }, 200, 'the transcript is bounded');
is($gw->status->{'transcript'}->[-1]->{'text'}, 'line 205', 'and keeps the newest lines');

# --------------------------------------------------------- filing into Chat
my $sco = tempdir(CLEANUP => 1);
my $tr  = "$sco/transcripts";
mkdir $tr;
my $now = int(time);
write_file("$tr/one.jsonl", join('', map { encode_json($_) . "\n" }
	{ who => 'caller', text => 'may i ask whose calling', at => $now, ms => 2400 },
	{ who => 'caller', text => 'this is john', at => $now, ms => 900 }));
write_file("$tr/old.jsonl", encode_json({ who => 'caller', text => 'another call', at => $now - 3600 }) . "\n");
utime($now - 3600, $now - 3600, "$tr/old.jsonl");
local $ENV{'JAWNOS_SCO_DIR'} = $sco;

my ($picked, $said) = subs::phone_call_transcript_lines($now * 1000);
like($picked, qr{/one\.jsonl$}, 'the transcript of this call is the one picked, not an older call\'s');
is_deeply($said, ['may i ask whose calling', 'this is john'], 'and its lines are the caller\'s words');

my @gone = subs::phone_call_transcript_lines(($now - 7200) * 1000);
is(scalar @gone, 0, 'a call whose words are long gone files nothing');

# A house with no key cannot seal a message, so nothing is written and the
# transcript is left for the next attempt rather than being lost or stored open.
is(subs::phone_call_transcript_note('+1 (555) 123-4567', 0, $now * 1000), 0,
	'no key means no message');
ok(-e "$tr/one.jsonl", 'and the transcript is kept, not spent');

# --------------------------------------------------------- the pane and the socket
my $js = read_file("$repo/public/js/manager/phone.js");
like($js, qr/function jawnPhoneTranscriptLine/, 'the Phone pane draws a finished line as a bubble');
like($js, qr/phone_transcript_partial/, 'and the sentence being said, dimmed');
like($js, qr/slice\(jawnPhoneTranscriptSeen\)/, 'a poll adds only the lines it has not drawn');
like($js, qr/function jawnPhoneTranscriptPushed/, 'a pushed line reaches the pane');
my $ws = read_file("$repo/public/js/manager/websocket/01_message_handler.js");
like($ws, qr/sco_transcript/, 'the websocket dispatcher knows the transcript event');
my $tpl = read_file("$repo/templates/apps/phone.html.ep");
like($tpl, qr/id="phone_transcript_lines"/, 'the Phone app has a transcript box');
like($tpl, qr/Live transcript/, 'labelled as such');

# --------------------------------------------------------- the streamer's arithmetic
my $stream = read_file("$repo/scripts/vosk_stream.py");
like($stream, qr/args\.rate \* 2 == 16000/,
	'the 8 kHz call is doubled in this process, not through a second program');
my ($py3) = grep { -x } map { "$_/python3" } split /:/, ($ENV{'PATH'} || '');
SKIP: {
	skip 'no python3 on PATH', 2 unless $py3;
	my $probe = "$dir/probe.py";
	write_file($probe, <<'PY');
import importlib.util, sys
spec = importlib.util.spec_from_file_location("vs", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
silence = b"\x00\x00" * 1600
loud = (1000).to_bytes(2, 'little', signed=True) * 1600
assert int(m.rms16(silence)) == 0, "silence is not zero"
assert 999 <= int(m.rms16(loud)) <= 1001, "a flat tone is its own level"
seg = m.Segmenter(object(), object(), 0.7, 0.4, 20)
assert seg.pause_windows == 7, "0.7 s is seven 100 ms windows"
assert seg.min_windows == 4, "0.4 s is four"
assert seg.ceiling_windows == 200, "20 s is two hundred"
up = m.upsample2((1000).to_bytes(2, 'little', signed=True) * 4)
import array
samples = array.array('h')
samples.frombytes(up)
assert len(samples) == 8, "8 kHz samples double"
assert list(samples) == [1000] * 8, "a level stays its level"
print("ok")
PY
	my $out = qx{'$py3' '$probe' '$repo/scripts/vosk_stream.py' 2>&1};
	is($? >> 8, 0, 'the streamer loads without Vosk installed');
	like($out, qr/^ok/m, 'and its window arithmetic is right');
}

done_testing();
