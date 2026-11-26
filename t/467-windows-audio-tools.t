# tests-for: installer/windows/build-portable.ps1 installer/windows/install.ps1 lib/JawnOS/Domain/Say.pm
# covers:    The Windows bundle's own audio. Piper (the voice) and SoX are
#            downloaded at build time, checksum-pinned, put on PATH and carried
#            with their licence/source offers; the public-domain default voice
#            travels so a lone Windows house can speak. SoX's Windows build has
#            no MP3 decoder, so the shipped chimes stay in the browser.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
sub source { my $text = read_file("$root/$_[0]"); return defined $text ? $text : ''; }

my $build = source('installer/windows/build-portable.ps1');
like($build, qr/piper_windows_amd64\.zip/, 'the bundle fetches the Windows Piper build');
like($build, qr#https://github\.com/rhasspy/piper/releases/download/2023\.11\.14-2/piper_windows_amd64\.zip#,
	'from the pinned release');
like($build, qr/f3c58906402b24f3a96d92145f58acba6d86c9b5db896d207f78dc80811efcea/,
	'with its pinned checksum');
like($build, qr/sox-14\.4\.2-win32\.zip/, 'and the official SoX Windows build');
like($build, qr/8072cc147cf1a3b3713b8b97d6844bb9389e211ab9e1101e432193fad6ae6662/,
	'with its pinned checksum');
like($build, qr/piper\\SOURCE\.txt/, 'Piper travels with its source offer');
like($build, qr/sox\\SOURCE\.txt/, 'and SoX with its own');
like($build, qr/espeak-ng 1\.52\.0, which is GPL-3\.0-or-later/,
	'the Piper offer names espeak-ng and its licence');
like($build, qr/no MP3 decoder/, 'the SoX note says MP3 is not decoded here');
like($build, qr/en_US-ljspeech-medium/, 'the public-domain default voice is bundled');
like($build, qr/-VoiceDir/, 'a build can name the voice folder');
like($build, qr/-ToolsDir/, 'and a folder of pre-downloaded tool archives');
like($build, qr/-NoTools/, 'and skip them deliberately');

my $install = source('installer/windows/install.ps1');
like($install, qr/runtime\\tools\\piper/, 'the launched house has Piper on PATH');
like($install, qr/runtime\\tools\\sox/, 'and SoX');
like($install, qr/speech and the synth chime will be silent/,
	'a bundle without them warns instead of failing');

# --- the executable's directory on either platform ---------------------------
# say_piper_parts points Piper at the espeak-ng data beside it, which needs the
# directory of a Windows path to split on its own separator.
require JawnOS::Domain::Say;

is(subs::say_piper_dir('C:\\jawnos\\runtime\\tools\\piper\\piper.exe'),
	'C:\\jawnos\\runtime\\tools\\piper', 'a Windows path splits on its backslash');
is(subs::say_piper_dir('/usr/local/bin/piper'), '/usr/local/bin', 'a Unix path still splits on its slash');
is(subs::say_piper_dir('piper'), '', 'a bare name has no directory');
is(subs::say_piper_dir(''), '', 'and an empty name answers empty');

like($build, qr/curl\.exe/, q{the fetch uses Windows curl, so a mirror cannot change the bytes});
done_testing();
