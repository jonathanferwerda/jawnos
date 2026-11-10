# tests-for: lib/JawnOS/Domain/Key.pm lib/JawnOS/Domain/Loader.pm perl/Websocket.pl lib/JawnOS/Manager/Core2_worker_boot.pm lib/JawnOS/Domain/Devicews.pm lib/JawnOS/Controller/manager_misc12.pm perl/Music/01_remote_audio_receiver.pl t/lib/JawnOSTest.pm
# covers:    the websocket sockets and the ws_watcher live in the tree's run/
#            directory - not under ~/.president and not in /tmp - and every
#            producer asks the same helper instead of rebuilding the path.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);
use JawnOSTest;

my $dir = tempdir('jawnos-ws-run-XXXXXX', TMPDIR => 1, CLEANUP => 1);

{
	local $subs::install_dir = $dir;
	local $ENV{'JAWNOS_RUN_DIR'} = '';
	is(subs::runtime_dir(), "$dir/run", 'the runtime dir sits beside the database');
	ok(-d "$dir/run", 'the runtime dir is made on first ask');
	is(subs::ws_dir(), "$dir/run/ws", 'the ws sockets live in run/ws');
	ok(-d "$dir/run/ws", 'the ws dir is made on first ask');
	is(subs::ws_watcher_path(), "$dir/run/ws_watcher", 'the watcher sits beside the ws dir');
	unlike(subs::ws_dir(), qr{^/tmp/ws(?:/|$)}, 'the ws dir is never the old /tmp/ws');
	unlike(subs::ws_dir(), qr{\.president}, 'the ws dir is never ~/.president');
}

{
	local $subs::install_dir = $dir;
	local $ENV{'JAWNOS_RUN_DIR'} = "$dir/elsewhere";
	is(subs::ws_dir(), "$dir/elsewhere/ws", 'JAWNOS_RUN_DIR overrides the tree location');
}

my $ws = read_file("$FindBin::Bin/../perl/Websocket.pl");
unlike($ws, qr/\$gb::tmp_dir\s*\.\s*'\/ws\//, 'Websocket.pl no longer builds ws paths from tmp_dir');
like($ws, qr/subs::ws_dir\(\)/, 'Websocket.pl asks for the runtime ws dir');
like($ws, qr/subs::ws_watcher_path\(\)/, 'Websocket.pl asks for the runtime watcher');

my $boot = read_file("$FindBin::Bin/../lib/JawnOS/Manager/Core2_worker_boot.pm");
unlike($boot, qr/\$gb::tmp_dir\s*\.\s*'\/ws/, 'the worker boot no longer builds ws paths from tmp_dir');
like($boot, qr/subs::ws_dir\(\)/, 'the worker boot asks for the runtime ws dir');

my $misc = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_misc12.pm");
unlike($misc, qr{\.president/ws_watcher}, 'the manager read no longer names ~/.president');
like($misc, qr/subs::ws_watcher_path\(\)/, 'the manager read asks for the runtime watcher');

my $music = read_file("$FindBin::Bin/../perl/Music/01_remote_audio_receiver.pl");
unlike($music, qr{\.president/ws_watcher}, 'the music receiver no longer names ~/.president');
like($music, qr/subs::ws_watcher_path\(\)/, 'the music receiver asks for the runtime watcher');

done_testing();
