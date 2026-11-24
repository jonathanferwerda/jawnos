# tests-for: perl/Music/09_remote_control.pl perl/Music.pl public/js/music.js public/js/manager/taskbar_sound.js public/js/manager/websocket/00_console_router.js templates/apps/music/music.html.ep templates/apps/music/remote.html.ep templates/apps/video/script.html.ep public/css/music.css public/css/manager.css perl/help/topics_apps.pl
# covers:    A Music window can become another machine's Music app, and the Sound
#            taskbar widget can start and drive Music (locally or on a peer).
#            The command crosses as a named console instruction, never as source;
#            the local player is not stopped or re-tuned by choosing a remote;
#            only playback settings travel to the controlled machine.

use strict;
use warnings;

use FindBin;
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
my $remote = read_file("$root/perl/Music/09_remote_control.pl");
my $music = read_file("$root/public/js/music.js");
my $taskbar = read_file("$root/public/js/manager/taskbar_sound.js");
my $router = read_file("$root/public/js/manager/websocket/00_console_router.js");
my $music_tpl = read_file("$root/templates/apps/music/music.html.ep");
my $remote_tpl = read_file("$root/templates/apps/music/remote.html.ep");
my $video_tpl = read_file("$root/templates/apps/video/script.html.ep");
my $music_css = read_file("$root/public/css/music.css");
my $manager_css = read_file("$root/public/css/manager.css");
my $boot = read_file("$root/perl/Music.pl");

# --- the routes ------------------------------------------------------------
for my $route (qw(/music/remote_machines /music/remote_target /music/transport /music/transport_state /music/remote_setting /music/remote_settings)) {
	like($remote, qr{\Q$route\E}, "the remote control route $route is registered");
}
like($boot, qr{require "\./perl/Music/09_remote_control\.pl";}, 'Music.pl loads the remote control module');

# --- the command crosses as a named instruction ----------------------------
like($remote, qr/console_command\('musicTransportLocal'/, 'transport sends a console instruction');
like($remote, qr/console_command\(\s*'musicPlayFiles',\s*\$files,/, 'play_files carries its queue as an array');
like($remote, qr/console_command\('musicSettingApply'/, 'a remote setting is applied in the peer player');
like($router, qr/musicTransportLocal: function/, 'the browser router whitelists the transport');
like($router, qr/musicPlayFiles: function/, 'and the handed queue');
like($router, qr/musicSettingApply: function/, 'and the setting push');

# --- only playback settings travel -----------------------------------------
like($remote, qr/my %music_remote_setting = map \{ \$_ => 1 \} qw\(normalize video equalizer subtitles\);/,
	'the remote-setting whitelist is exactly the playback settings');
unlike($remote, qr/%music_remote_setting.*\blibrary\b/, 'a controller cannot move the host library');
unlike($remote, qr/%music_remote_setting.*\bremote_target\b/, 'a controller cannot nest another controller');

# --- the two pickers keep their own memories --------------------------------
like($remote, qr/setting => 'remote_target'/, 'the Music window remembers its target');
like($remote, qr/setting => 'widget_target'/, 'the taskbar widget remembers its target separately');
like($remote, qr/scope.*widget/, 'the save route takes the scope');

# --- state -----------------------------------------------------------------
like($remote, qr/sub music_transport_state/, 'the state reader is one shape');
like($remote, qr/context => 'player'/, 'it reads the browser-written player cache');
like($remote, qr/playing => \(\$player->\{'state'\} \? 1 : 0\)/, 'a saved state becomes playing');

# --- the widget ------------------------------------------------------------
like($taskbar, qr/data-sound-section', 'music'/, 'the Sound panel has a Music section');
like($taskbar, qr/data-music-action', action/, 'the transport buttons carry their action');
like($taskbar, qr/data-music-target/, 'the widget has a machine picker');
like($taskbar, qr{url: '/music/transport'}, 'a remote press is relayed by the transport route');
like($taskbar, qr{url: '/music/remote_target'}, 'the picker remembers its machine');
like($taskbar, qr/musicTransportLocal/, 'the local press uses the page player, not a round trip');
like($manager_css, qr/\.taskbar_music_transport/, 'the taskbar styles the transport row');

# --- the Music window -------------------------------------------------------
like($music_tpl, qr/id="music_remote_toggle"/, 'the interface carries the remote button');
like($music_tpl, qr/id="music_remote_panel"/, 'and the remote drawer');
like($music_tpl, qr/remote_target="/, 'the window carries the chosen target');
like($music_tpl, qr/id="music_remote_now"/, 'and a line naming the remote track');
like($remote_tpl, qr/data-remote-target="local"/, 'the panel can return to this machine');
like($remote_tpl, qr/foreach my \$rm \( \@machines \)/, 'the panel lists the reachable peers');

like($music, qr/function musicRemoteTarget\(\)/, 'the window reads its remote target');
like($music, qr/function musicRemoteChoose/, 'choosing a target switches the window');
like($music, qr/function musicPlayFiles/, 'a handed queue opens and starts the peer player');
like($music, qr/function musicTransportLocal/, 'the local transport exists for the widget');
like($music, qr/music_remote_mode/, 'remote mode is a class on the window');
like($video_tpl, qr/musicRemoteTarget\(\).*seek_percent/s, 'a seek while controlling a peer moves the peer');

# The local player must survive the choice. musicRemoteChoose may search the
# peer library and open the peer app, but it must never pause or re-tune this
# machine's own player.
my ($choose) = $music =~ /function musicRemoteChoose\(target\) \{(.*?)\n\}/s;
ok(defined $choose && length $choose, 'musicRemoteChoose is readable as a hunk');
unlike($choose || '', qr/tree\.sound\.pause|musicPlayToggleLocal|musicNormalizeApply/,
	'choosing a remote target does not stop or re-tune the local player');

# --- no picture -------------------------------------------------------------
like($music, qr/function theatreModeOn\(\) \{\s*\n\s*if \(musicRemoteTarget\(\)\) \{ return; \}/,
	'Theatre mode steps aside in remote mode');
like($music, qr/function musicFullscreenOn\(\) \{\s*\n\s*if \(musicRemoteTarget\(\)\) \{ return; \}/,
	'full screen steps aside in remote mode');
like($music_css, qr/#music\.music_remote_mode #video/, 'the remote window hides the video surface');
like($music_css, qr/#music\.music_remote_mode \[hint="Fullscreen"\]/, 'and the full-screen button');

# --- settings arrive on the controlled machine ------------------------------
like($music, qr/function musicSettingSave/, 'a setting save knows the remote mode');
like($music, qr/function musicSettingApply/, 'and the peer can apply the pushed setting');
like($music, qr/function musicRemoteApplyPlaying/, 'the remote row has its own marker class');
my ($play_item) = $music =~ /function musicRemotePlayItem\(item\) \{(.*?)\n\}/s;
ok(defined $play_item && length $play_item, 'musicRemotePlayItem is readable as a hunk');
unlike($play_item || '', qr/tree\.current_track\s*=/, 'a remote play does not move the local queue cursor');
like($video_tpl, qr/if \(typeof musicRemoteTarget === 'function' && musicRemoteTarget\(\)\)/,
	'the local bar tick stands down while the window controls a peer');
like($music, qr/#music_library_select[\s\S]{0,1600}musicRemoteSnapshotRestore/,
	'choosing another library leaves the remote-control session');
like($music, qr/setting == 'normalize'/, 'normalization is applied in the peer player');
like($music, qr/setting == 'video'/, 'video enhancement is applied in the peer player');

done_testing();
