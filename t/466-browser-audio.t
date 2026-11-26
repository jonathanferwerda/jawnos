# tests-for: lib/JawnOS/Domain/Say.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Platform/Audio.pm public/js/manager/websocket/01_message_handler.js
# covers:    Windows hears the house's sound through the browser. A machine with no SoX `play`
#            (Platform::Audio::player_available) hands a notification's chime and piper's voice
#            to the page over the socket it already holds: `type => 'sound'` names the shipped
#            file, `type => 'speech'` carries the WAV base64. Linux keeps its local voice.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use MIME::Base64 qw(encode_base64 decode_base64);

my $root = "$FindBin::Bin/..";
sub source { my $text = read_file("$root/$_[0]"); return defined $text ? $text : ''; }

# --- the sound URL -----------------------------------------------------------
# Only the shipped folder is served, and the settings store the file as a
# `./public/...` path. Anything else answers '', so the caller stays silent
# rather than inventing a URL the page cannot fetch.
require JawnOS::Domain::Notify;

is(subs::sound_web_url('./public/sounds/notifications/ding.mp3'),
	'/sounds/notifications/ding.mp3', 'a shipped chime becomes a web path');
is(subs::sound_web_url('public/sounds/notifications/chime.mp3'),
	'/sounds/notifications/chime.mp3', 'so does one without the dot-slash');
is(subs::sound_web_url('/sounds/notifications/crystal.mp3'),
	'/sounds/notifications/crystal.mp3', 'an already-web path is left alone');
is(subs::sound_web_url('https://example.test/a.mp3'),
	'https://example.test/a.mp3', 'and a remote URL');
is(subs::sound_web_url('/home/someone/ambient.mp3'), '',
	'a filesystem path outside public is not served');
is(subs::sound_web_url('./public/notes.mp3'), '',
	'only the notifications folder is served');
is(subs::sound_web_url(undef), '', 'a missing sound names nothing');
is(subs::sound_web_url(''), '', 'so does an empty one');

# --- the speech frame ---------------------------------------------------------
# A finished WAV goes out as the audio itself, not a path: base64 in the frame
# the socket already carries. The file is the caller's and is removed.
require JawnOS::Domain::Say;

{
	no warnings 'redefine';
	*Websocket::send = sub { push @Websocket::SENT, [@_]; return 1 };
}

sub wav_fixture {
	my ($bytes) = @_;
	my ($fh, $path) = tempfile(SUFFIX => '.wav', UNLINK => 0);
	binmode $fh;
	print {$fh} $bytes;
	close $fh;
	return $path;
}

{
	local @Websocket::SENT = ();
	my $bytes = 'RIFF' . pack('C*', 1 .. 8) . 'WAVE';
	my $path = wav_fixture($bytes);
	ok(subs::say_broadcast_wav($path), 'a rendered clip is sent');
	ok(!-e $path, 'and the temp file does not outlive it');
	is(scalar @Websocket::SENT, 1, 'one frame leaves');
	my ($channel, $frame) = @{ $Websocket::SENT[0] };
	is($channel, 'server', 'on the server channel every page holds');
	is($frame->{'type'}, 'speech', 'the frame names speech');
	is($frame->{'mime'}, 'audio/wav', 'and the WAV type');
	is(decode_base64($frame->{'audio'}), $bytes, 'the audio is the bytes themselves');
}

{
	local @Websocket::SENT = ();
	local $subs::say_broadcast_max_bytes = 4;
	my $path = wav_fixture('too long for the cap');
	ok(!subs::say_broadcast_wav($path), 'an oversized clip is refused');
	ok(!-e $path, 'and still removed');
	is(scalar @Websocket::SENT, 0, 'nothing is sent');
}

ok(!subs::say_broadcast_wav('/nonexistent/clip.wav'), 'a missing clip sends nothing');

# --- the switch ---------------------------------------------------------------
my $audio = source('lib/JawnOS/Platform/Audio.pm');
like($audio, qr/^sub player_available\b/m, 'the seam answers whether a local player exists');
like($audio, qr/which\('play'\)/, 'by looking for SoX play');

my $say = source('lib/JawnOS/Domain/Say.pm');
like($say, qr/^sub say_broadcast_wav\b/m, 'the voice has a browser path');
like($say, qr/player_available\(\)/, 'and the local voice asks the seam first');
like($say, qr/type => 'speech'/, 'the frame it sends names speech');
like($say, qr/encode_base64\(\$bytes, ''\)/, 'and carries the WAV as base64');

my $notify = source('lib/JawnOS/Domain/Notify.pm');
like($notify, qr/^sub sound_web_url\b/m, 'a notification sound gets a web URL');
like($notify, qr/player_available\(\)/, 'the chime asks the seam first');
like($notify, qr/type => 'sound'/, 'a machine with no player sends the chime to the page');
like($notify, qr/name => "Synth player"/, 'and a machine with one keeps the local fork');

my $js = source('public/js/manager/websocket/01_message_handler.js');
like($js, qr/function jawnosSoundPlay\b/, 'the page can play a clip');
like($js, qr/function jawnosSpeechPlay\b/, 'and a speech frame');
like($js, qr/data\['type'\] == 'sound'/, 'the dispatcher hears the chime');
like($js, qr/data\['type'\] == 'speech'/, 'and the voice');
like($js, qr/atob\(encoded\)/, 'decoding the base64 frame');

done_testing();
