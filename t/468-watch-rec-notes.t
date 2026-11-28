# tests-for: lib/JawnOS/Domain/Ai.pm lib/JawnOS/Domain/Loader.pm jw/jw_01_globals.ino jw/jw_04_loop.ino jw/jw_06_net_face.ino jw/jw_07_house_audio.ino jw/jw_08_voice.ino jw/jw_09_voice_ship.ino jw/jw_11_configure.ino jw/jw_14_settings.ino
# covers:    The watch's Rec button files a spoken memo in Notes and keeps the ten
#           most recent per device; the Com button records a push-to-talk command
#           whose clip is read as a wake-word capture (command first, then the
#           Guide); the Wigi and Play buttons moved on the clock and Net pages;
#           the firmware ships a Rec clip tagged "note" and a Com clip tagged
#           "command", and prunes the recording folder.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::SQLite;

require(root() . '/lib/JawnOS/Domain/Ai.pm');

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

# Nothing here touches the live database: a throwaway SQLite file is installed as
# the holder, the way t/86-notes-status.t proves the notes read and write paths.
my ($fh, $dbfile) = tempfile('jawnos-watch-rec-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table notes (uuid text unique, timestamp text, server_time text, '
	. 'app text, device text, text text, ost text, category text, status text)');
my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $dbfile,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};
$subs::say_quiet = 1;
$subs::sync_table_cache = undef;

# Deterministic uuids, so a cap assertion can name the rows it expects to lose.
my $seq = 0;
local *subs::random_string_creator = sub { 'rec-note-' . ++$seq };

is($subs::VOICE_NOTE_MODE, 'note', 'the Rec capture is tagged as a note');
is($subs::VOICE_NOTE_LIMIT, 10, 'a watch keeps ten memos');

sub live_notes {
	my ($device) = @_;
	return $db->query(
		"select uuid, text, ost from notes where device = ? and app = 'notes' "
		. "and coalesce(text, '') != '' and coalesce(ost, '') != ? "
		. "order by cast(coalesce(timestamp, '0') as integer) desc, "
		. "cast(coalesce(server_time, '0') as integer) desc",
		$device, &subs::notes_delete_marker()
	)->hashes;
}

# --------------------------------------------------- the store and the cap
my $stored = &subs::voice_note_store('remember to water the plants', 1_700_000_000_000, 'watch-chip');
is($stored, 'remember to water the plants', 'a Rec memo is stored as a note');
my $first = $db->query('select device, text, ost from notes where uuid = ?', 'rec-note-1')->hash;
is($first->{'device'}, 'watch-chip', 'the note names the watch that spoke it');
ok(!&subs::notes_tombstoned($first->{'ost'}), 'a fresh memo is not tombstoned');

# A blink, a noise or a single word is still not a note.
is(&subs::voice_note_store('[BLANK_AUDIO]', 1_700_000_000_100, 'watch-chip'), undef,
	'a clip that said nothing is not a note');
is(&subs::voice_note_store('mumble mumble', 1_700_000_000_200, 'watch-chip'), undef,
	'a two-word fragment is not a note');

# The eleventh memo pushes the oldest out; it is tombstoned, not erased.
for my $i (1 .. 10) {
	my $text = "spoken memo number $i";
	is(&subs::voice_note_store($text, 1_700_000_000_000 + $i * 1000, 'watch-chip'), $text,
		"memo $i is stored");
}
my $live = live_notes('watch-chip');
is(scalar(@{$live}), 10, 'a device holds ten live memos');
is($live->[0]{'text'}, 'spoken memo number 10', 'the newest memo is the first row');
is($live->[-1]{'text'}, 'spoken memo number 1', 'and the oldest survivor is the first spoken memo');
my $dropped = $db->query('select ost from notes where uuid = ?', 'rec-note-1')->hash;
is($dropped->{'ost'}, &subs::notes_delete_marker(), 'the first memo past the limit is tombstoned');
my $kept_row = $db->query('select ost from notes where uuid = ?', 'rec-note-2')->hash;
ok(!&subs::notes_tombstoned($kept_row->{'ost'}), 'the newest ten stay live');

# A note written by hand names no device, so it is never counted or pruned.
&subs::db_insert('notes', {
	uuid => 'typed-note', app => 'notes', text => 'a note typed on the desk',
	timestamp => 1_700_000_009_000, server_time => 1_700_000_009_000,
});
&subs::voice_note_store('one more spoken memo', 1_700_000_020_000, 'watch-chip');
is(scalar(@{ live_notes('watch-chip') }), 10, 'the watch is still at ten live memos');
my $typed = $db->query('select ost from notes where uuid = ?', 'typed-note')->hash;
ok(!&subs::notes_tombstoned($typed->{'ost'}), 'a typed note is never pruned by the memo cap');

# --------------------------------------------------- the ingest routing
# voice_ingest may only claim an utterance; whisper, the socket and the Guide's
# model are stubbed so this test observes the routing alone. A settings row gives
# the command path an app to toggle.
$db->query('create table settings (app text, setting text, value text)');
$db->query("insert into settings (app, setting, value) values ('email test', 'toggle', 'off')");
my (@guided, @applied, @acked, @frames, @replied);
local *subs::whisper_transcribe = sub { $main::WHISPER };
local *subs::voice_clip_ack    = sub { push @acked, $_[0]{'ts'} };
local *subs::guide_set_message = sub { push @guided, $_[0] };
local *subs::voice_brain       = sub { $main::BRAIN };
local *subs::voice_command_apply = sub { push @applied, $_[0]; return {} };
# A recognised command answers on the watch now (the Com button's reply), so
# watch_reply is observed here instead of being allowed to touch the bridge.
local *subs::watch_reply = sub { push @replied, [ 'watch', $_[1] ]; return 1 };
local *subs::say_it      = sub { push @replied, [ 'say', $_[0] ]; return 1 };
local *Websocket::send = sub { return 1 };
local *Websocket::console_command = sub { return '{}' };

sub reset_observers { @guided = @applied = @acked = @replied = (); }

# The Rec button's mode files a note and never touches the Guide or a command.
reset_observers();
$main::WHISPER = 'remember to buy the milk';
$main::BRAIN   = undef;
my $note_result = &subs::voice_ingest('raw', { voice => 'note', chip_id => 'watch-chip', ts => 1_700_000_030_000 });
is($note_result->{'status'}, 'note', 'a note-mode clip is filed as a note');
is(scalar(@guided), 0, 'a Rec memo is not sent to the Guide');
is(scalar(@applied), 0, 'a Rec memo is not read as a command');
is(scalar(@acked), 1, 'the clip is acked so the watch stops retrying it');
my $spoken = $db->query("select text from notes where text = ?", 'remember to buy the milk')->hash;
ok($spoken, 'the transcript reached the Notes table');

# Command first: a wake-word start/stop with a known app still runs.
reset_observers();
$main::WHISPER = 'start email test';
$main::BRAIN   = undef;
my $cmd_result = &subs::voice_ingest('raw', { voice => 'hey_jawn', chip_id => 'watch-chip', ts => 1_700_000_040_000 });
is($cmd_result->{'status'}, 'done', 'a wake-word start command still runs');
is($cmd_result->{'app'}, 'email test', 'the target resolves to the app');
is_deeply(\@applied, ['email test'], 'the app is toggled');
is_deeply(\@replied, [ [ 'watch', 'Email Test on.' ] ], 'a recognised command is answered on the watch');
is(scalar(@guided), 0, 'a running command is not also sent to the Guide');
my $cmd_note = $db->query("select uuid from notes where text = ?", 'start email test')->hash;
ok(!$cmd_note, 'a command is not filed as a note');

# Anything else addressed goes to the Guide, and never to Notes.
reset_observers();
$main::WHISPER = 'what is the weather';
$main::BRAIN   = undef;
my $guide_result = &subs::voice_ingest('raw', { voice => 'hey_jawn', chip_id => 'watch-chip', ts => 1_700_000_050_000 });
is($guide_result->{'status'}, 'guide', 'a non-command wake-word clip goes to the Guide');
is_deeply(\@guided, ['what is the weather'], 'the Guide receives the spoken words');
is(scalar(@applied), 0, 'a question is not applied as a command');
is(scalar(@acked), 1, 'the Guide path consumes the clip too');
my $not_note = $db->query("select uuid from notes where text = ?", 'what is the weather')->hash;
ok(!$not_note, 'a wake-word question is not filed as a note');

# A verb with a target that is not an app falls through to the Guide rather than
# being dropped.
reset_observers();
$main::WHISPER = 'start a conversation about the roof';
$main::BRAIN   = undef;
my $unknown_result = &subs::voice_ingest('raw', { voice => 'hey_jawn', chip_id => 'watch-chip', ts => 1_700_000_060_000 });
is($unknown_result->{'status'}, 'guide', 'an unknown command target goes to the Guide');
is(scalar(@applied), 0, 'and nothing is toggled');
is_deeply(\@guided, ['start a conversation about the roof'], 'the Guide hears the whole sentence');

# Jawn Do routes the same way.
reset_observers();
$main::WHISPER = 'what is on today';
$main::BRAIN   = undef;
my $do_result = &subs::voice_ingest('raw', { voice => 'jawn_do', chip_id => 'watch-chip', ts => 1_700_000_070_000 });
is($do_result->{'status'}, 'guide', 'Jawn Do also goes to the Guide');
is_deeply(\@guided, ['what is on today'], 'and hands the Guide its message');

# A Guide that answers is still the same route, and it does not become a note.
reset_observers();
$main::WHISPER = 'what is the weather like';
$main::BRAIN   = { handled => 1, action => 'say', said => 'Mild and clear.' };
my $brain_result = &subs::voice_ingest('raw', { voice => 'hey_jawn', chip_id => 'watch-chip', ts => 1_700_000_080_000 });
is($brain_result->{'status'}, 'brain', 'an answered wake-word turn reports the brain');
is_deeply(\@guided, ['what is the weather like'], 'the Guide still received the words');
my $brain_note = $db->query("select uuid from notes where text = ?", 'what is the weather like')->hash;
ok(!$brain_note, 'an answered turn is not also filed as a note');

# Any-speech still runs a command when the phrase is in the transcript, and a
# room sentence without the phrase is neither a Guide message nor a note.
reset_observers();
$main::WHISPER = 'hey jawn start email test';
$main::BRAIN   = undef;
my $vad_cmd = &subs::voice_ingest('raw', { voice => 'vad', chip_id => 'watch-chip', ts => 1_700_000_090_000 });
is($vad_cmd->{'status'}, 'done', 'a VAD clip with the phrase still runs the command');
is_deeply(\@applied, ['email test'], 'and toggles the same app');

reset_observers();
$main::WHISPER = 'hey jawn what is the weather';
$main::BRAIN   = undef;
my $vad_guide = &subs::voice_ingest('raw', { voice => 'vad', chip_id => 'watch-chip', ts => 1_700_000_100_000 });
is($vad_guide->{'status'}, 'guide', 'a VAD clip with the phrase and no command goes to the Guide');
is(scalar(@applied), 0, 'and is not applied');
my $vad_note = $db->query("select uuid from notes where text = ?", 'hey jawn what is the weather')->hash;
ok(!$vad_note, 'and is not a note');

reset_observers();
$main::WHISPER = 'the room is quiet';
$main::BRAIN   = undef;
my $vad_result = &subs::voice_ingest('raw', { voice => 'vad', chip_id => 'watch-chip', ts => 1_700_000_110_000 });
is($vad_result->{'status'}, 'no_wake', 'a VAD clip without the phrase is not addressed');
is(scalar(@guided), 0, 'and is not sent to the Guide');
my $room_note = $db->query("select uuid from notes where text = ?", 'the room is quiet')->hash;
ok(!$room_note, 'and is not a note');

# The Com button tags its clip "command", which is the wake-word path without the
# on-device phrase: command first, then the Guide.
reset_observers();
$main::WHISPER = 'start email test';
$main::BRAIN   = undef;
my $com_cmd = &subs::voice_ingest('raw', { voice => 'command', chip_id => 'watch-chip', ts => 1_700_000_120_000 });
is($com_cmd->{'status'}, 'done', 'a Com clip runs a recognised command');
is_deeply(\@applied, ['email test'], 'and toggles the app');
is($com_cmd->{'reply'}, 'Email Test on.', 'the Com reply names the app and its new state');
is_deeply(\@replied, [ [ 'watch', 'Email Test on.' ] ], 'so the Com button is no longer silent');
is(scalar(@guided), 0, 'a Com command does not go to the Guide');

reset_observers();
$main::WHISPER = 'what is the weather';
$main::BRAIN   = undef;
my $com_guide = &subs::voice_ingest('raw', { voice => 'command', chip_id => 'watch-chip', ts => 1_700_000_130_000 });
is($com_guide->{'status'}, 'guide', 'a Com clip that is not a command goes to the Guide');
is_deeply(\@guided, ['what is the weather'], 'with the spoken words');
my $com_note = $db->query("select uuid from notes where text = ?", 'what is the weather')->hash;
ok(!$com_note, 'and is not a note');

# --------------------------------------------------- the firmware wiring
my $globals = read_file('jw/jw_01_globals.ino');
like($globals, qr/#define\s+REC_NOTE_MODE\s+"note"/, 'the watch tags a Rec clip as a note');
like($globals, qr/#define\s+COMMAND_MODE\s+"command"/, 'and a Com clip as a command');
like($globals, qr/#define\s+REC_NOTE_LIMIT\s+10/, 'and keeps ten memos');

my $audio = read_file('jw/jw_07_house_audio.ino');
like($audio, qr/rec_is_note\s*=\s*false/, 'the Com press records a command');
like($audio, qr/rec_clip_wav\s*=\s*"\/com\.wav"/, 'to its own temp clip');
like($audio, qr/const char \*mode = note \? REC_NOTE_MODE : COMMAND_MODE/, 'a Rec clip ships as note, a Com clip as command');
like($audio, qr/voice_ship_clip\(ship_path, ts, mode\)/, 'the ship carries the clip kind');
like($audio, qr/rec_note_prune\(clip_path\)/, 'only a Rec capture prunes the memo folder');
like($audio, qr/n\s*-\s*REC_NOTE_LIMIT/, 'the prune keeps the limit');

my $clock = read_file('jw/jw_11_configure.ino');
like($clock, qr/lv_obj_set_pos\(playbtn1, 130, 136 \)/, 'Play moved to the old Wigi slot');
like($clock, qr/lv_obj_set_pos\(combtn, 60, 136 \)/, 'Com sits where Play was');
unlike($clock, qr/wigi_btn = lv_btn_create/, 'the clock page no longer builds the Wigi button');

my $net = read_file('jw/jw_14_settings.ino');
like($net, qr/lv_obj_set_pos\(wigi_btn, 185, 75 \)/, 'the Wigi button sits under BT on the Net page');
like($net, qr/face_bt = face_label_maker\(10, 75, [^\n]*165\)/, 'the Bluetooth line sits beside the Wigi button');
like($net, qr/lv_label_set_long_mode\(face_bt, LV_LABEL_LONG_WRAP\)/, 'a long bridge name wraps to a second line');
like($net, qr/lv_obj_set_height\(face_bt, 44\)/, 'the wrapped Bluetooth line stops above the addresses');

my $loop = read_file('jw/jw_04_loop.ino');
like($loop, qr/voiceRecording \|\| comRecording/, 'a Com capture shows the listening ring');

my $voice = read_file('jw/jw_08_voice.ino');
like($voice, qr/voice_compress_clip\(const String &in_path, const String &out_path, bool fold_half, uint32_t rate\)/,
	'the compressor takes the memo path, folds 16 kHz for it, and names the output rate');

my $ship = read_file('jw/jw_09_voice_ship.ino');
like($ship, qr/voice_ship_clip\(const String &path, long ts, const char \*mode\)/,
	'the ship carries the clip stamp and mode');
like($ship, qr/voice_compress_clip\(VOICE_WAV_PATH, VOICE_ADPCM_PATH, false, capture_rate\)/,
	'the listener compresses its own capture and names the rate it recorded at');
like($ship, qr/voice_ship_clip\(ship_path, ts, voice_mode_name\)/,
	'and ships with the model that heard it');

# The capture ring: orange for a spoken command, teal while the Rec button's
# memo is the capture. The note flag is tracked separately, so a Rec -> Com
# hand-off recolors a ring that never went out between them.
like($loop, qr/bool note_capture = isRecording && rec_is_note/,
	'the Rec hold counts as a capture for the ring');
like($loop, qr/voice_border_show\(want_border, want_note\)/,
	'the ring is told a memo from a command on every color change');
like($ship, qr/#define VOICE_BORDER_NOTE\s+0x00b3b3/, 'a Rec memo wears a teal ring');
like($ship, qr/static void voice_border_show\(bool on, bool note\)/,
	'the ring takes the note flag');

# A note that could not be sent is retried inside a bounded window instead of
# being left on flash after one attempt (the Rec test that never reached Notes).
like($audio, qr/#define REC_SHIP_WINDOW_MS 15000UL/, 'a note gets a bounded retry window');
like($audio, qr/while \(!ok && millis\(\) - ship_started < REC_SHIP_WINDOW_MS\)/,
	'and is retried until a send succeeds or the window ends');

done_testing();
