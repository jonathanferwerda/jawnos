# tests-for: lib/JawnOS/Sco/Gateway.pm lib/JawnOS/Domain/Phone.pm lib/JawnOS/Controller/manager_phone.pm perl/sco/sco_helper.c scripts/vosk_stream.py public/js/manager/phone.js public/js/manager/screening.js public/css/manager.css templates/apps/phone.html.ep public/js/manager/websocket/01_message_handler.js
# covers:    A screened call's live transcript: the helper's non-blocking tap
#           above the recorder's gate, the gateway keeping a sentence in the
#           status and on disk, the partial that is not yet a line, a bounded
#           history, the Phone pane's bubbles, the caller's name header on the
#           filed message, a remote gateway's live status filing the words
#           when no local file exists, and the streamer's segmentation
#           arithmetic without Vosk installed.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use JSON::PP;
use Mojo::SQLite;

use RepoSource;
use JawnOSTest;

use lib repo_root() . '/lib';
use JawnOS::Sco::Gateway;
use JawnOS::Sco::Client;

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

# The caller's name comes from the house's contact rows, the way the phone's
# directory sees them. A throwaway database keeps the seeding - and the row
# phone_number_app writes for an unknown number - off the live house.
my $contact_db = "$sco/test.db";
my $contact_sql = Mojo::SQLite->new('sqlite:' . $contact_db);
my $contact = $contact_sql->db;
$contact->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text)');
my @contact_stat = stat($contact_db);
$gb::database_holder = {
	server_time => &subs::rightNow(), database => $contact_db,
	db => $contact, dbh => $contact->dbh, sql => $contact_sql,
	pid => $$, dev => $contact_stat[0], ino => $contact_stat[1],
};
my $seeded = &subs::rightNow();
&subs::db_insert('settings', {
	uuid => 'known-phone', app => 'john_smith', setting => 'phone',
	value => '5555550101', device => 'all',
	timestamp => $seeded, server_time => $seeded,
});

my ($picked, $said) = subs::phone_call_transcript_lines($now * 1000);
like($picked, qr{/one\.jsonl$}, 'the transcript of this call is the one picked, not an older call\'s');
is_deeply($said, ['may i ask whose calling', 'this is john'], 'and its lines are the caller\'s words');

{
	no warnings 'redefine';
	local *JawnOS::Sco::Client::call = sub { return { ok => 0, error => 'no gateway in tests' } };
	my @gone = subs::phone_call_transcript_lines(($now - 7200) * 1000);
	is(scalar @gone, 0, 'a call whose words are long gone files nothing');
}

# A house with no key cannot seal a message, so nothing is written and the
# transcript is left for the next attempt rather than being lost or stored open.
is(subs::phone_call_transcript_note('+1 (555) 123-4567', 0, $now * 1000), 0,
	'no key means no message');
ok(-e "$tr/one.jsonl", 'and the transcript is kept, not spent');
rename "$tr/one.jsonl", "$tr/one.jsonl.filed";

# --------------------------------------------------------- the caller's name
{
	my @msgs;
	no warnings 'redefine';
	local *subs::note_encrypter = sub { $_[1] };
	local *subs::db_insert = sub {
		my ($table, $row) = @_;
		push @msgs, $row if $table eq 'mailbox';
		return { rows => 1 };
	};

	write_file("$tr/known.jsonl", encode_json({ who => 'caller', text => 'may i ask whose calling', at => $now, ms => 2400 }) . "\n");
	utime($now, $now, "$tr/known.jsonl");
	is(&subs::phone_call_transcript_note('+1 (555) 555-0101', 0, $now * 1000), 1,
		'a known caller files one message');
	is(scalar @msgs, 1, 'exactly one message');
	like($msgs[0]->{'body'}, qr/\ACall from: John Smith\n\nmay i ask whose calling/,
		'the header names the caller and the words follow');
	is($msgs[0]->{'contact'}, 'john_smith', 'and the message still reaches their thread');
	ok(-e "$tr/known.jsonl.filed", 'the local transcript is spent');
	ok(!-e "$tr/known.jsonl", 'so it cannot be filed twice');

	write_file("$tr/stranger.jsonl", encode_json({ who => 'caller', text => 'hello there', at => $now }) . "\n");
	utime($now, $now, "$tr/stranger.jsonl");
	is(&subs::phone_call_transcript_note('+1 (555) 555-0199', 0, $now * 1000), 1,
		'an unknown caller still files their words');
	like($msgs[1]->{'body'}, qr/\ACall from: \+1 \(555\) 555-0199\n\nhello there/,
		'and the header is the number as the phone received it');

	# Remote gateway: no local .jsonl, but the live status holds the lines.
	{
		no warnings 'redefine';
		local *JawnOS::Sco::Client::call = sub {
			return {
				ok => 1, call_id => 'remote-call-7', since => $now - 5,
				transcript => [
					{ who => 'caller', text => 'this is john', at => $now, ms => 900 },
					{ who => 'caller', text => 'from an old call', at => $now - 600, ms => 900 },
				],
			};
		};
		is(&subs::phone_call_transcript_note('+1 (555) 555-0101', 0, $now * 1000), 1,
			"the gateway's live lines are filed when no transcript is local");
		is(scalar @msgs, 3, 'one remote message');
		like($msgs[-1]->{'body'}, qr/\ACall from: John Smith\n\nthis is john\z/,
			"the remote header and this call's words, not another call's");
	}
	{
		no warnings 'redefine';
		local *JawnOS::Sco::Client::call = sub {
			return { ok => 1, call_id => 'old-call', since => $now - 3600,
				transcript => [ { who => 'caller', text => 'long ago', at => $now - 3600, ms => 1 } ] };
		};
		is(&subs::phone_call_transcript_note('+1 (555) 555-0101', 0, $now * 1000), 0,
			'a status older than the window is not this call');
		is(scalar @msgs, 3, 'and files nothing');
	}
	{
		no warnings 'redefine';
		local *JawnOS::Sco::Client::call = sub {
			return { ok => 1, call_id => 'next-call', since => $now + 30,
				transcript => [ { who => 'caller', text => 'the next caller', at => $now + 20, ms => 1 } ] };
		};
		is(&subs::phone_call_transcript_note('+1 (555) 555-0101', 0, $now * 1000), 0,
			"a status from the next call is not this one's");
		is(scalar @msgs, 3, 'and files nothing');
	}
	{
		no warnings 'redefine';
		local *JawnOS::Sco::Client::call = sub { return { ok => 0, error => 'no gateway socket' } };
		is(&subs::phone_call_transcript_note('+1 (555) 555-0101', 0, $now * 1000), 0,
			'no gateway is an ordinary answer, not a failure');
		is(scalar @msgs, 3, 'so nothing is written');
	}
}

# --------------------------------------------------------- the pane and the socket
my $js = read_file("$repo/public/js/manager/phone.js");
like($js, qr/function jawnPhoneTranscriptLine/, 'the Phone pane draws a finished line as a bubble');
like($js, qr/phone_transcript_partial/, 'and the sentence being said, dimmed');
like($js, qr/slice\(jawnPhoneTranscriptSeen\)/, 'a poll adds only the lines it has not drawn');
like($js, qr/function jawnPhoneTranscriptPushed/, 'a pushed line reaches the pane');
like($js, qr/phone_transcript_title/, 'the transcript header is its own element');
like($js, qr/Call from:/, 'and names the caller when the status carries one');
my $screening = read_file("$repo/public/js/manager/screening.js");
like($screening, qr/incomingNumber/, 'the floating panel asks the phone for the caller');
like($screening, qr/Call from:/, 'and its header names the caller too');
# The panel belongs at the top, like the app's own screening face: at the foot
# the dock and taskbar painted over it, and the lift code measured `#dock`, the
# store's customer ribbon, which no Manager page has.
like($screening, qr/function jawnScreenTopOffset/, 'the panel measures the top edge before it opens');
like($screening, qr/getElementById\('pseudonym_home'\)/, 'and the dock it clears is the real #pseudonym_home');
like($screening, qr/getAttribute\('position'\) === 'top'/, 'only a dock on the top edge offsets it');
unlike($screening, qr/getElementById\('dock'\)/, 'the lookup for an id no Manager page has is gone');
like($screening, qr/min\(62vh/, 'and the panel still stops above the foot on a short window');
my $css = read_file("$repo/public/css/manager.css");
like($css, qr/\.jawn_screening\s*\{[^}]*top:\s*calc\(var\(--taskbar_top_h,\s*0px\)\s*\+\s*16px\)/s,
	'the panel hangs from the top, below a top taskbar');
unlike($css, qr/\.jawn_screening\s*\{[^}]*bottom:\s*16px/s,
	'it never sits at the foot where the bars cover it');
my $ws = read_file("$repo/public/js/manager/websocket/01_message_handler.js");
like($ws, qr/sco_transcript/, 'the websocket dispatcher knows the transcript event');
my $tpl = read_file("$repo/templates/apps/phone.html.ep");
like($tpl, qr/id="phone_transcript_lines"/, 'the Phone app has a transcript box');
like($tpl, qr/id="phone_transcript_title"/, 'with its own header');
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
