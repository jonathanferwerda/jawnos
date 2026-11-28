# tests-for: lib/JawnOS/Domain/Ai.pm lib/JawnOS/Domain/Ble2.pm perl/watch.pl
# covers:    Which copy of a clip is the truth. For a memo the whole-clip file is
#           the transcript, so a streamed memo is deferred before whisper, before
#           an ack and before any note; the file then stores one note and acks.
#           For a command whichever copy arrives first wins, and the other is a
#           duplicate that is never transcribed, so a WiFi file after a BLE
#           stream (or the reverse) acts once. The source is carried by the
#           caller: Ble2 sends 'stream' or 'file', /watch/voice sends 'file'.
#           The claim is a marker file created O_CREAT|O_EXCL under
#           ~/.president/voice-seen, so two processes racing one clip settle on
#           one winner and a stale marker is reclaimed after 300 s. A memo's
#           stream sends no voice_recv - its file does - while a command's
#           stream confirms at once.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Config;
use JawnOSTest;
use File::Temp qw(tempfile tempdir);
use File::Slurp qw(read_file);
use MIME::Base64 qw(encode_base64);
use Mojo::JSON qw(encode_json);
use Mojo::SQLite;
use POSIX ();

require(root() . '/lib/JawnOS/Domain/Ai.pm');
require(root() . '/lib/JawnOS/Domain/Ble2.pm');

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

# Nothing here touches the live database: a throwaway SQLite file is installed as
# the holder, the way t/468-watch-rec-notes.t proves the notes paths.
my ($fh, $dbfile) = tempfile('jawnos-file-truth-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table notes (uuid text unique, timestamp text, server_time text, '
	. 'app text, device text, text text, ost text, category text, status text)');
$db->query('create table settings (app text, setting text, value text)');
$db->query("insert into settings (app, setting, value) values ('email test', 'toggle', 'off')");
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

# The fallback half of the claim ledger is process memory; start empty. The
# claim itself is a marker file, exercised below.
$gb::voice_seen = {};

# voice_ingest may only claim an utterance; whisper, the socket, the Guide and
# the ack are stubbed so this test observes the routing alone. The note store is
# NOT stubbed: a memo must really reach the Notes table.
my (@whisper, @acked, @applied, @guided);
local *subs::whisper_transcribe   = sub { push @whisper, $_[0]; return $main::WHISPER };
local *subs::voice_clip_ack       = sub { push @acked, $_[0]{'ts'} };
# An applied command speaks its confirmation now; keep the bridge out of a test.
local *subs::watch_reply          = sub { return 1 };
local *subs::say_it               = sub { return 1 };
local *subs::voice_command_apply  = sub { push @applied, $_[0]; return {} };
local *subs::guide_set_message    = sub { push @guided, $_[0] };
local *subs::voice_brain          = sub { return undef };
local *Websocket::send            = sub { return 1 };
local *Websocket::console_command = sub { return '{}' };

sub reset_observers { @whisper = @acked = @applied = @guided = (); }

sub note_text {
	my ($text) = @_;
	return $db->query(
		"select text, timestamp from notes where text = ? and app = 'notes' "
		. "and coalesce(ost, '') != ?", $text, &subs::notes_delete_marker()
	)->hash;
}

# ------------------------------------------------ a memo is the file's to file
# The stream is the always-on copy; for a memo it is not the transcript. It must
# stop before whisper, before an ack and before a note. The same clip stamp then
# arrives as a file - which must be allowed through, so the stream cannot have
# claimed it.
reset_observers();
$main::WHISPER = 'remember to call the plumber';
my $deferred = &subs::voice_ingest('raw',
	{ voice => 'note', source => 'stream', chip_id => 'watch-chip', ts => 1_700_000_200 });
is($deferred->{'status'}, 'deferred', 'a streamed memo is deferred');
is(scalar(@whisper), 0, 'and never reaches whisper');
is(scalar(@acked), 0, 'and is not acked, so nothing is deleted before the file lands');
ok(!note_text('remember to call the plumber'), 'and is not filed as a note');

# The whole-clip file for that same clip is the transcript.
reset_observers();
$main::WHISPER = 'remember to call the plumber';
my $memo = &subs::voice_ingest('raw',
	{ voice => 'note', source => 'file', chip_id => 'watch-chip', ts => 1_700_000_200 });
is($memo->{'status'}, 'note', 'the memo file is filed as a note');
is(scalar(@whisper), 1, 'the file is transcribed');
is(scalar(@acked), 1, 'the file is acked so the watch drops its copy');
is($acked[0], 1_700_000_200_000, 'the ack carries the normalized clip stamp');
my $row = note_text('remember to call the plumber');
ok($row, 'the transcript reached the Notes table');
is($row->{'timestamp'}, 1_700_000_200_000, 'the note is stamped at the clip, not at processing time');

# A memo that names no source is a file (the caller default), so the WiFi route
# and an older caller keep filing memos exactly as before.
reset_observers();
$main::WHISPER = 'remember to feed the cat';
my $default = &subs::voice_ingest('raw',
	{ voice => 'note', chip_id => 'watch-chip', ts => 1_700_000_250 });
is($default->{'status'}, 'note', 'a memo with no source is treated as the file');
ok(note_text('remember to feed the cat'), 'and is filed');

# ------------------------------------------------ a command: first copy wins
# The stream arrives first and runs the command once.
reset_observers();
$main::WHISPER = 'start email test';
my $from_stream = &subs::voice_ingest('raw',
	{ voice => 'hey_jawn', source => 'stream', chip_id => 'watch-chip', ts => 1_700_000_300 });
is($from_stream->{'status'}, 'done', 'a command from the stream acts');
is_deeply(\@applied, ['email test'], 'and toggles the app once');
is(scalar(@whisper), 1, 'the stream is transcribed');

# The same clip then arrives as a WiFi file: it must not act again.
my $then_file = &subs::voice_ingest('raw',
	{ voice => 'hey_jawn', source => 'file', chip_id => 'watch-chip', ts => 1_700_000_300 });
is($then_file->{'status'}, 'duplicate', 'the same command from the file is a duplicate');
is_deeply(\@applied, ['email test'], 'the command still acted only once');
is(scalar(@whisper), 1, 'and the duplicate was never transcribed');

# A file command alone acts, with no stream ever seen.
reset_observers();
$main::WHISPER = 'start email test';
my $file_only = &subs::voice_ingest('raw',
	{ voice => 'hey_jawn', source => 'file', chip_id => 'watch-chip', ts => 1_700_000_400 });
is($file_only->{'status'}, 'done', 'a command from the file alone acts');
is_deeply(\@applied, ['email test'], 'and toggles the app');

# Whichever arrives first wins in the other direction too: a streamed copy after
# the file is the duplicate.
my $stream_after_file = &subs::voice_ingest('raw',
	{ voice => 'hey_jawn', source => 'stream', chip_id => 'watch-chip', ts => 1_700_000_400 });
is($stream_after_file->{'status'}, 'duplicate', 'a streamed command after the file is a duplicate');
is_deeply(\@applied, ['email test'], 'and the command is not run twice');
is(scalar(@whisper), 1, 'nor transcribed again');

# The reverse of the memo pair: a streamed command is claimed, so no file may
# then re-file it - the claim is what the memo path deliberately skips.
reset_observers();
$main::WHISPER = 'what is the weather';
my $streamed_question = &subs::voice_ingest('raw',
	{ voice => 'hey_jawn', source => 'stream', chip_id => 'watch-chip', ts => 1_700_000_500 });
is($streamed_question->{'status'}, 'guide', 'an unanswered command goes to the Guide');
my $later_file = &subs::voice_ingest('raw',
	{ voice => 'hey_jawn', source => 'file', chip_id => 'watch-chip', ts => 1_700_000_500 });
is($later_file->{'status'}, 'duplicate', 'the file copy of a claimed command is a duplicate');

# ------------------------------------------------ the claim crosses processes
# The BLE ingest is a forked worker and /watch/voice a request worker, so the
# claim has to live where both can see it. A sandbox HOME keeps the markers out
# of the real ~/.president and lets this test inspect the directory.
SKIP: {
	skip 'fork() is unavailable on this platform', 8 unless $Config{'d_fork'};
	my $marker_home = tempdir('jawnos-voice-seen-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	local $ENV{'HOME'} = $marker_home;
	local $subs::home_dir = $marker_home;
	my $seen_dir = "$marker_home/.president/voice-seen";
	my $markers  = sub {
		opendir(my $dh, $seen_dir) or return ();
		my @name = grep { /\.seen\z/ } readdir $dh;
		closedir $dh;
		return @name;
	};

	my ($chip, $ts) = ('race-chip', 1_700_000_900);
	my $marker = "$seen_dir/" . &subs::path_name($chip . '|' . $ts) . '.seen';

	# Two real processes race the same clip stamp. Each records what it got; the
	# O_CREAT|O_EXCL create, not a per-process map, is the arbiter.
	my @answer = map { "$marker_home/claim-$_.txt" } (1, 2);
	my @kid;
	for my $i (0, 1) {
		my $pid = fork();
		if (!defined $pid) {
			BAIL_OUT('fork failed: ' . $!);
		}
		if (!$pid) {
			my $won = &subs::voice_clip_fresh($chip, $ts);
			open(my $out, '>', $answer[$i]) or POSIX::_exit(2);
			print $out $won ? '1' : '0';
			close($out);
			POSIX::_exit(0);
		}
		push @kid, $pid;
	}
	waitpid($_, 0) for @kid;
	my @won = map {
		open(my $in, '<', $_) or BAIL_OUT("claim answer missing: $_");
		my $v = <$in>;
		close($in);
		0 + ($v // '');
	} @answer;
	is(scalar(grep { $_ == 1 } @won), 1, 'exactly one process wins the claim race');
	is(scalar(grep { $_ == 0 } @won), 1, 'and the other is told it is a duplicate');
	ok(-f $marker, 'the winner left one marker named from chip_id|ts');
	is(scalar($markers->()), 1, 'and only one marker exists, not one per process');
	is(&subs::voice_clip_fresh($chip, $ts), 0, 'a later call in this process is a duplicate too');

	# The window is mtime-based: past 300 s the marker is no longer a duplicate.
	my $old = time() - 400;
	utime($old, $old, $marker) or BAIL_OUT("could not age the marker: $!");
	is(&subs::voice_clip_fresh($chip, $ts), 1, 'a marker older than the TTL is claimed again');
	ok((stat($marker))[9] >= time() - 5, 'and the claim recreated it with a current stamp');
	is(&subs::voice_clip_fresh($chip, $ts), 0, 'while an immediate repeat is still a duplicate');
}

# ------------------------------------------------ the stream's ack, by mode
# ble_message_processor is where voice_recv is sent. The sender, the forked
# worker and the ingest are stubbed so the test sees only which message goes out.
{
	my (@frames, @ingest);
	local *subs::bluetooth_sender_async = sub { push @frames, $_[0]{'message'} };
	local *subs::subprocessor           = sub { my $body = shift; $body->(); return 1 };
	local *subs::voice_ingest           = sub { push @ingest, [ $_[1]{'source'}, $_[1]{'voice'} ] };
	local *subs::ble_link_key           = sub { return 'link-test' };
	local *subs::ble_device_record      = sub { return 1 };
	local *subs::firmware_version_note  = sub { return 1 };
	my $audio = encode_base64('A' x 200, '');

	# A memo's stream is not the truth: no voice_recv, but the ingest is still
	# asked (it will defer).
	@frames = @ingest = ();
	&subs::ble_message_processor(encode_json({
		type => 'voice_stream', seq => 0, last => 1, audio => $audio,
		voice => 'note', chip_id => 'watch-chip', ts => 1_700_001_000, rate => 8000,
	}), 'AA:BB');
	is(scalar(@frames), 0, 'a streamed memo sends no voice_recv');
	is_deeply(\@ingest, [ [ 'stream', 'note' ] ], 'though the stream still reaches the ingest');

	# A command's stream confirms at once: whichever copy wins is fine.
	@frames = @ingest = ();
	&subs::ble_message_processor(encode_json({
		type => 'voice_stream', seq => 0, last => 1, audio => $audio,
		voice => 'command', chip_id => 'watch-chip', ts => 1_700_001_100, rate => 8000,
	}), 'AA:BB');
	is(scalar(@frames), 1, 'a streamed command sends one voice_recv');
	is($frames[0]{'type'}, 'voice_recv', 'and it is the receipt the watch expects');
	is_deeply(\@ingest, [ [ 'stream', 'command' ] ], 'the command stream reaches the ingest');

	# The whole-clip file is a memo's confirmation, so it always sends voice_recv.
	@frames = @ingest = ();
	&subs::ble_message_processor(encode_json({
		type => 'voice', data => $audio,
		voice => 'note', chip_id => 'watch-chip', ts => 1_700_001_200,
	}), 'AA:BB');
	is(scalar(@frames), 1, 'a memo file sends voice_recv');
	is($frames[0]{'type'}, 'voice_recv', 'the file is the memo receipt');
	is_deeply(\@ingest, [ [ 'file', 'note' ] ], 'and the file reaches the ingest as a file');
}

# ------------------------------------------------ the callers name the copy
# The source is the caller's to know: the BLE whole-clip message is a file, the
# reassembled stream is a stream, and the WiFi route is a file. The BLE layer no
# longer makes the claim itself, so a memo file is never blocked there.
my $ble = read_file('lib/JawnOS/Domain/Ble2.pm');
like($ble, qr/voice_ingest\(\$raw,[^\n]*source => 'file'/,
	'the BLE whole-clip ingest is tagged as a file');
like($ble, qr/voice_ingest\(\$wav,[^\n]*source => 'stream'/,
	'the reassembled BLE stream is tagged as a stream');
unlike($ble, qr/voice_clip_fresh/,
	'the BLE layer no longer claims the clip; the central ingest does');
like($ble, qr/\(\$rec->\{'voice'\} \/\/ ''\) ne \$VOICE_NOTE_MODE/,
	'the streamed voice_recv is withheld for a memo');

my $watch = read_file('perl/watch.pl');
like($watch, qr/source => 'file', t_arrival => \$t_arrival/,
	'the WiFi route names its body a file');

# A WiFi clip is a whole file, so the route sends the same receipt the BLE
# whole-clip path sends on reassembly - before whisper or the Guide run. The
# watch holds the file and re-POSTs it every six seconds until it hears this,
# and its POST timeout is 4 s, so an inline ingest made every clip retry for
# the whole 45 s cap.
like($watch, qr/type => 'voice_recv'[^\n]*ts => \(0 \+ \(\$ts \|\| 0\)\)/,
	'the WiFi route sends the clip receipt');
like($watch, qr/subprocessor\(sub \{\s*&subs::voice_ingest/, 
	'the WiFi route ingests off the request');
unlike($watch, qr/^\s*&subs::voice_ingest\(\$raw, \{ edt => \$edt/m,
	'the WiFi route no longer transcribes inline in the request');
like($watch, qr/peer_ip => \$peer_ip/, 'the WiFi route hands the device source address on');
like($watch, qr/t_arrival => \$t_arrival/, 'the WiFi route stamps when the clip arrived');

# The timing ledger answers "where did the 30 s go?". Stub the Guide's model
# and the command app so this observes the log line alone.
{
	my @logged;
	{
		no warnings 'redefine';
		local *TLog::info = sub { push @logged, $_[1] };
		local *TLog::error = sub { push @logged, $_[1] };
		local $subs::log = bless {}, 'TLog';
		$main::WHISPER = 'start email test';
		&subs::voice_ingest('raw', {
			voice => 'hey_jawn', source => 'file', chip_id => 'timing-chip',
			ts => 1_700_002_000, t_arrival => &subs::rightNow() - 250,
		});
	}
	ok(scalar(grep { /voice: timing stage=asr/ } @logged),
		'the ingest logs when whisper finished');
	ok(scalar(grep { /voice: timing stage=command/ } @logged),
		'the ingest logs when the command was applied');
	ok(scalar(grep { /since_onset=\d+ms/ } @logged),
		'and the line carries the person-side clock');
}

done_testing();
