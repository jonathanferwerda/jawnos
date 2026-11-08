# tests-for: perl/President.pl lib/JawnOS/Domain/Ai.pm lib/JawnOS/Sco/Gateway.pm lib/JawnOS/Domain/Loader.pm
# covers:    The warm whisper.cpp server is started by demand, not at boot, and
#            stopped once the house has been quiet for ten minutes. It held
#            147 MB resident at ggml-tiny on a 1.8 GB handheld that took no
#            dictation and no call. Every transcription request touches the
#            demand marker, a screened call touches it at arm time, and the loop
#            stops only the server it started itself.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $president = read_file("$root/perl/President.pl");
my $ai        = read_file("$root/lib/JawnOS/Domain/Ai.pm");
my $gateway   = read_file("$root/lib/JawnOS/Sco/Gateway.pm");
my $loader    = read_file("$root/lib/JawnOS/Domain/Loader.pm");

# --- the demand marker -----------------------------------------------------
my ($wanted) = $ai =~ /(sub whisper_server_wanted \{.*?\n\})/s;
ok($wanted, 'Domain::Ai still carries whisper_server_wanted');
like($wanted, qr/\$file = &subs::home\('~\/\.president\/whisper-want'\)/,
	'the marker lives beside the rest of the president state');
like($wanted, qr/utime\(undef, undef, \$file\) if \$touch;/,
	'a touch moves the mtime, which is what the loop reads');
like($wanted, qr/return \$mtime \|\| 0;/,
	'an untouched marker reports 0 rather than the epoch');

# --- the request path asks for it ------------------------------------------
my ($server_call) = $ai =~ /(sub whisper_server_transcribe \{.*?\n\})/s;
ok($server_call, 'whisper_server_transcribe is still one sub');
like($server_call, qr/&whisper_server_wanted\(1\);/,
	'a warm-server request asks for the server (and falls back to the CLI meanwhile)');

my ($transcript) = $gateway =~ /(sub _start_transcript \{.*?\n\})/s;
ok($transcript, '_start_transcript is still one sub');
# Reception re-arms the gateway every five minutes while it waits, so an arm is
# not a request for the model: asking here would hold it for as long as the
# house is armed. Pinned so the shortcut is not re-added.
unlike($transcript, qr/whisper_server_wanted/,
	'arming the gateway does not warm the model (Reception re-arms every five minutes)');
like($transcript, qr/&subs::whisper_available\(\)/,
	'it still says why there is no transcript when whisper.cpp is missing');

like($loader, qr/\bwhisper_server_wanted\b/,
	'Loader.pm maps the new domain sub (t/91 reads the same list)');

# --- the loop that starts and stops it -------------------------------------
my ($loop) = $president =~ /(&subs::subprocessor\(sub \{\s*my \$idle_limit = 600;.*?\}, \{ name => 'whisper server' \}\);)/s;
ok($loop, 'the whisper server loop is still registered as a subprocessor');
like($loop, qr/my \$want = &subs::whisper_server_wanted\(\);/,
	'the loop reads the demand marker');
like($loop, qr/my \$idle_limit = 600;/,
	'ten quiet minutes before the model is let go');
like($loop, qr/if \(!\$up && !\$server_pid && \$recent && -x \$bin && -e \$model\)/,
	'the server starts only for a fresh demand and only when it is not already up');
like($loop, qr/elsif \(\$up && \$server_pid && \$idle\)/,
	'and stops only the server this loop started, never one started by hand');
like($loop, qr/kill 'TERM', \$server_pid;/,
	'the idle stop asks politely first');
like($loop, qr/POSIX::WNOHANG\(\)/,
	'a server that died on its own is reaped, so no zombie stands in for it');

# The old shape started the model at every boot, whether or not anything here
# ever transcribed. That is the cost this test exists to keep out.
unlike($loop, qr/^\t\tsleep 30;\n/s,
	'the loop no longer warms the model at boot before anything asks');
like($loop, qr/sleep\(\$recent \? 5 : 30\);/,
	'it looks soon while the house is talking and coasts otherwise');

# --- the server the previous tree left behind -------------------------------
# The eager server this loop used to start survived a restart as an orphan
# (PPid 1). With demand-started servers the loop would read it as "already up"
# and never stop it, so the 147 MB would stay for good.
my ($orphans) = $ai =~ /(sub whisper_server_stop_orphans \{.*?\n\})/s;
ok($orphans, 'Domain::Ai carries whisper_server_stop_orphans');
like($orphans, qr/\$fields\[1\] eq '1'/,
	'it takes a server with no parent (PPid 1) and leaves a hand-started one');
like($orphans, qr/whisper\[-_\]/,
	'and matches whisper-server and the pip wrapper whisper_tool.py alike');
like($orphans, qr/--port\\s\+\\Q\$port\\E/,
	'and only a server on this machine whisper port');
like($orphans, qr/kill 'TERM', \$pid;/,
	'it asks that server to stop');
like($loop, qr/&subs::whisper_server_stop_orphans\(\);/,
	'the demand loop clears an inherited server before its first look');
like($loader, qr/\bwhisper_server_stop_orphans\b/,
	'Loader.pm maps that sub too');

done_testing();
