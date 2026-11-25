# tests-for: perl/Music/09_remote_control.pl perl/Music.pl perl/Music/05_library_and_queue.pl perl/Music/08_music_routes.pl public/js/music.js public/js/manager/taskbar_sound.js public/js/manager/websocket/00_console_router.js templates/apps/music/music.html.ep templates/apps/music/remote.html.ep templates/apps/sound.html.ep templates/apps/video/script.html.ep public/css/music.css public/css/manager.css perl/help/topics_apps.pl
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
use Mojo::JSON ();

my $root = "$FindBin::Bin/..";
my $remote = read_file("$root/perl/Music/09_remote_control.pl");
my $search_routes = read_file("$root/perl/Music/08_music_routes.pl");
my $queue_src = read_file("$root/perl/Music/05_library_and_queue.pl");
my $music = read_file("$root/public/js/music.js");
my $taskbar = read_file("$root/public/js/manager/taskbar_sound.js");
my $router = read_file("$root/public/js/manager/websocket/00_console_router.js");
my $music_tpl = read_file("$root/templates/apps/music/music.html.ep");
my $remote_tpl = read_file("$root/templates/apps/music/remote.html.ep");
my $video_tpl = read_file("$root/templates/apps/video/script.html.ep");
my $music_css = read_file("$root/public/css/music.css");
my $help = read_file("$root/perl/help/topics_apps.pl");
my $manager_css = read_file("$root/public/css/manager.css");
my $boot = read_file("$root/perl/Music.pl");

# --- the routes ------------------------------------------------------------
for my $route (qw(/music/remote_machines /music/remote_target /music/transport /music/transport_state /music/remote_setting /music/remote_settings)) {
	like($remote, qr{\Q$route\E}, "the remote control route $route is registered");
}
like($boot, qr{require "\./perl/Music/09_remote_control\.pl";}, 'Music.pl loads the remote control module');

# --- the command crosses as a named instruction ----------------------------
like($remote, qr/console_command\('musicTransportLocal'/, 'transport sends a console instruction');
like($remote, qr/Websocket::send\('server'/, 'the command rides the server console channel');
unlike($remote, qr/Websocket::send\('music'/, 'and never the player data channel');
like($remote, qr/console_command\(\s*'musicPlayFiles',\s*\$files,/, 'play_files carries its queue as an array');
like($remote, qr/console_command\('musicSettingApply'/, 'a remote setting is applied in the peer player');
like($router, qr/musicTransportLocal: function/, 'the browser router whitelists the transport');
like($router, qr/musicPlayFiles: function/, 'and the handed queue');
like($router, qr/musicSettingApply: function/, 'and the setting push');
like($router, qr/musicVolumeSet: function/, 'and the peer volume');
like($remote, qr/\$action eq 'volume'/, 'the transport can set the controlled player volume');
like($remote, qr/console_command\('musicVolumeSet'/, 'the volume crosses as a named instruction');
like($remote, qr/value => \$c->param\('value'\)/, 'the route carries the level');
like($taskbar, qr/data-music-volume/, 'the widget has a remote volume slider');
like($taskbar, qr/action: 'volume', value: level/, 'the slider rides the transport route');
like($taskbar, qr/function jawnosSoundTaskbarMusicMount/, 'Sound can mount the same controls');
like($taskbar, qr/\[data-music-section\] \[data-music-action\]/, 'the transport binds wherever the block is mounted');
like($taskbar, qr/\[data-music-section\] \[data-music-volume\]/, 'and so does the volume');
like($taskbar, qr/\[data-music-section\] \[data-music-target\]/, 'and the machine picker');
like($taskbar, qr/on\('input', '\.taskbar_sound_slider\[data-sound-volume\]'/, 'the house level only binds a slider that names its device');
like($taskbar, qr/on\('change', '\.taskbar_sound_slider\[data-sound-volume\]'/, 'and so does its save');
like($taskbar, qr/on\('wheel', '\.taskbar_sound_slider\[data-sound-volume\]'/, 'and its wheel gesture');
like($router, qr/playerCacheSaver\(undefined, true\)/, 'the peer writes the level back for the widget');
like($music, qr/volume: musicVolumeLevel\(\)/, 'the player cache records the level the player is using');

# --- the Music window's own bar is the controlled machine's -----------------
like($music, qr/function musicVolumeSetLocal\(level\)/, 'the level that acts on this machine is its own function');
like($music, qr/function musicVolumeSet\(level\) \{\s*\n\tlevel = musicVolumeClamp\(level\);\s*\n\tif \(musicRemoteTarget\(\)\) \{ musicRemoteLevelSend\(level\); return; \}/,
	'the player bar forwards while the window shows a peer');
like($music, qr/function musicRemoteLevelSend\(level\)/, 'the controlled machine gets the level');
like($music, qr/musicRemoteSend\('volume', \{ value: level \}\)/, 'over the same volume action the widget uses');
like($music, qr/function musicRemoteMuteSend\(on\)/, 'and gets the mute too');
like($music, qr/musicRemoteSend\('mute', \{ value: on \? 1 : 0 \}\)/, 'as its own mute action');
like($remote, qr/\$action eq 'mute'/, 'the transport can mute the controlled player');
like($remote, qr/console_command\('musicMuteSet'/, 'the mute crosses as a named instruction');
like($router, qr/musicMuteSet: function/, 'the browser router whitelists the mute');
like($music, qr/function musicMuteSet\(on\)/, 'the peer applies it in its own player');
like($router, qr/musicVolumeSetLocal/, 'a level aimed at this machine applies here, it never forwards');
like($music, qr/function musicVolumeBase\(\)/, 'a wheel nudge starts from the bar that is shown');
like($music, qr/music_remote_state\.volume/, 'the bar is painted from the controlled player');
like($music, qr/music_remote_state\.muted/, 'and its mute is too');
like($music, qr/if \(!musicRemoteTarget\(\)\) \{ \$\('#music_volume'\)\.val\(musicSystemLevel\); \}/,
	'a local mixer read does not repaint a peer bar');
like($music, qr/\$\('#music_volume'\)\.val\(musicVolumeLevel\(\)\);\s*\n\t\tupdateMusicMuteIcon\(\);\s*\n\t\treturn;/,
	'leaving the peer puts this machine\'s own bar back');
like($remote, qr/volume => \(defined \$volume \? \$volume \+ 0 : undef\)/, 'a peer that never saved a level answers null');
like($help, qr/its volume and its mute/, 'the Music help says the bar is the controlled machine\'s');
like($music, qr/function musicBarLevel\(\)/, 'a finger starts from the bar that is shown');
like($music, qr/if \(remote \? !!music_remote_state\.muted : music_muted\) \{ return 0; \}/,
	'and a muted bar starts the drag at zero');
like($video_tpl, qr/typeof musicBarLevel == 'function'\) \{ return musicBarLevel\(\); \}/,
	'the player gesture asks the bar, not this machine');

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
like($music, qr/function musicFullscreenOn\(force\) \{\s*\n\s*if \(musicRemoteTarget\(\) && !force\) \{ return; \}/,
	'full screen steps aside in remote mode unless a controller asks for the host');
like($music, qr/function musicFullscreenSet\(on\)/, 'the host can be sent into full screen');
like($music, qr/musicFullscreenGestureAsk\(\);\s*\n\s*return;/, 'and asks its own shell for the trusted press');
like($music, qr/musicPlayerFullscreen\(force\)/, 'the player full screen can be forced past remote mode');
like($router, qr/musicFullscreenSet: function/, 'the browser router whitelists the full-screen push');
like($remote, qr/console_command\('musicFullscreenSet'/, 'the full-screen press crosses as a named instruction');
like($remote, qr/\$action eq 'fullscreen'/, 'the transport has a full-screen action');
like($remote, qr/fullscreen => \(\$player->\{'fullscreen'\} \? 1 : 0\)/, 'the state reports the host full screen');
like($music, qr/musicRemoteSend\('fullscreen', \{ value: on \}\)/, 'the controller sends its press');
like($music_tpl, qr/id="music_remote_fullscreen"/, 'the remote Music window has its own full-screen button');
like($music_css, qr/#music\.music_remote_mode #music_remote_fullscreen/, 'and shows it only in remote mode');
like($music_css, qr/#music_remote_fullscreen \{ display: none; \}/, 'a local window does not carry it');
like($music_css, qr/#music\.music_remote_mode #video/, 'the remote window hides the video surface');
like($music_css, qr/#music\.music_remote_mode \[hint="Fullscreen"\]/, 'and the full-screen button');

# --- settings arrive on the controlled machine ------------------------------
like($music, qr/function musicSettingSave/, 'a setting save knows the remote mode');
like($music, qr/function musicSettingApply/, 'and the peer can apply the pushed setting');
like($search_routes, qr/my \$remote_view = \$c->param\('remote_view'\)/, 'the search route knows a remote view');
like($search_routes, qr/music_queue_recall\(\$settings, \$unlocked, 1\)/, 'a remote view recalls the host queue even when the archive is on');
like($queue_src, qr/sub music_queue_recall\(\$settings, \$unlocked, \$mirror = 0\)/, 'the recall takes a mirror flag');
like($queue_src, qr/return undef if !\$mirror && .*archive/, 'and only the ordinary replay refuses an archive list');
like($search_routes, qr/\$now_playing = \{ file => \$player->\{'file'\}/, 'the mirror marks the host current track');
like($search_routes, qr/\$selected_artist = \$remote_view \? \(\$crate->\{'artist'\}/, 'and returns the host selected artists');
like($search_routes, qr/\$selected_album = \$remote_view \? \(\$crate->\{'album'\}/, 'and albums');
like($music, qr/musicRemoteApplyPlaying\(r\.key, r\.file\)/, 'the remote row is found by key or path');

# --- the mirror gets the host's list even when the archive is on -------------
require "$FindBin::Bin/../perl/Music/05_library_and_queue.pl";
{
	no warnings 'redefine';
	local *subs::cache_get = sub { return { files => [ 'Music/a.mp3', 'Music/b.mp3' ], library => 'local' } };
	local *subs::music_queue_applies = sub { return 1 };
	local *Manager::music_queue_file_visible = sub { return 1 };
	my $archive_settings = { archive => 'on', library => 'local' };
	is(&Manager::music_queue_recall($archive_settings, 0), undef,
		'an ordinary replay still refuses an archive list');
	my $mirror = &Manager::music_queue_recall($archive_settings, 0, 1);
	is_deeply($mirror && $mirror->{'files'}, [ 'Music/a.mp3', 'Music/b.mp3' ],
		'a mirror replays the host queue even when the archive is on');
}
like($search_routes, qr/\$search = \$settings->\{'search'\} \/\/ ''/, 'and uses the host saved search');
like($music, qr/remote_view: 1/, 'the window asks for the host view when it takes a peer');
like($music, qr/remote_view \? '\{\}' : JSON.stringify\(nowPlaying\)/, 'the controller sends no now-playing of its own');
like($music, qr/function musicRemoteLocalViewSave/, 'the local view is remembered');
like($music, qr/sessionStorage.setItem\('music_remote_local_view'/, 'across a reload too');
like($music, qr/function musicRemoteLocalViewRestore/, 'and put back when This machine is chosen');
like($music, qr/fresh_search/, 'an in-place swap carries the host search word');
like($music, qr/fresh_library/, 'and the library label');
like($music, qr/function musicRemoteApplyPlaying/, 'the remote row has its own marker class');
my ($play_item) = $music =~ /function musicRemotePlayItem\(item\) \{(.*?)\n\}/s;
ok(defined $play_item && length $play_item, 'musicRemotePlayItem is readable as a hunk');
unlike($play_item || '', qr/tree\.current_track\s*=/, 'a remote play does not move the local queue cursor');
like($play_item || '', qr/musicRemoteSend\('play_track', \{ file: file \}\)/, 'a remote click names one file');
like($music, qr/function musicPlayTrack\(/, 'the host can start a named row');
like($music, qr/function musicPlayTrackFlush/, 'and waits for a window that is opening');
like($router, qr/musicPlayTrack: function/, 'the browser router whitelists the row');
like($remote, qr/console_command\('musicPlayTrack'/, 'the row crosses as a named instruction');
like($remote, qr/\$action eq 'play_track'/, 'the transport action exists');
like($video_tpl, qr/if \(typeof musicRemoteTarget === 'function' && musicRemoteTarget\(\)\)/,
	'the local bar tick stands down while the window controls a peer');
like($video_tpl, qr/musicRemoteSeekPercent\(percent\)/, 'a seek moves the peer bar at once');
like($music, qr/function musicRemoteProgressPaint/, 'the peer bar ticks between polls');
like($music, qr/function musicRemoteSeekPercent/, 'and takes a seek before the next poll');
my ($seek_hunk) = $music =~ /if \(action == 'seek_percent'\) \{(.*?)\n\t\}/s;
ok(defined $seek_hunk && length $seek_hunk, 'the seek hunk is readable');
like($seek_hunk || '', qr/playerCacheSaver\(undefined, true\)/, 'a seek writes its position at once');
like($music_css, qr/music_remote_glow/, 'the controlled machine glows');
unlike($music_css, qr/:not\(\[data-remote-target="local"\]\)/, 'This machine glows when its own library is on screen');
like($remote, qr{/music/remote_queue}, 'the controlled machine has a queue route');
like($remote, qr/sub music_remote_queue/, 'which reads the host queue cache');
like($music, qr/function musicToggle\(files, same_order, start_key\)/, 'a handed list can name its start row');
like($music, qr/if \(start_key\) \{ thisTrack\(start_key\); \}/, 'and opens on that row');
like($music, qr/tree\.all_songs\[n\]\.file === key/, 'thisTrack finds a row by its path');
like($music, qr/musicToggle\(files, same_order \? 1 : 0, key\)/, 'play_files hands the start row through');
like($taskbar, qr/action: 'play_track', file: file/, 'the Sound list names the row too');
like($boot, qr/my \$handed_list/, 'a handed list is recognised on open');
like($boot, qr/!\$handed_list/, 'and the old now-playing is not pushed ahead of it');
like($taskbar, qr{/music/remote_queue}, 'the Sound remote reads that queue');
like($taskbar, qr/data-remote-track/, 'and lists its tracks');
like($taskbar, qr/action: 'play_track', file: file/, 'a track press names the row, not a list');
like($music, qr/#music_library_select[\s\S]{0,1600}musicRemoteSnapshotRestore/,
	'choosing another library leaves the remote-control session');
like($music, qr/setting == 'normalize'/, 'normalization is applied in the peer player');
like($music, qr/setting == 'video'/, 'video enhancement is applied in the peer player');

# --- the controlled machine's outputs ---------------------------------------
like($remote, qr{/music/remote_outputs}, 'the controlled machine offers its outputs');
like($remote, qr{/music/remote_output}, 'and takes a chosen output');
like($remote, qr/sub music_output_catalogue/, 'the catalogue is the host\'s own mao map');
like($remote, qr/sub music_output_pick/, 'a choice is written on the host');
like($remote, qr/\$mao->\{\$other\} = 'off'/, 'the other outputs go off: it is a choice, not an addition');
like($remote, qr/\$mao->\{\$key\} = 'on'/, 'and the picked one plays');
like($remote, qr/console_command\('musicOutputApply'/, 'the host player is told without a reload');
like($router, qr/musicOutputApply: function/, 'the browser router whitelists the output push');
like($music, qr/function musicOutputApply\(value\)/, 'the host applies the picked output');
like($music, qr/musicStreamRestart|musicStreamOutputsChanged/, 'and restarts the stream when it must');
like($taskbar, qr/data-music-output/, 'Sound\'s Remote pill has an output picker');
like($taskbar, qr{url: '/music/remote_outputs'}, 'it reads the controlled machine\'s outputs');
like($taskbar, qr{url: '/music/remote_output'}, 'and sends the choice to that machine');
like($taskbar, qr/function jawnosSoundTaskbarMusicOutputsLoad/, 'the picker refreshes with the remote');
like($queue_src, qr/\&subs::machine_name\(\) \|\| \&subs::ui\('Local'\)/, 'a local library is named by this machine, not a synced leftover');

# --- a local library is named by this machine, not a synced leftover --------
{
	no warnings 'redefine';
	local *subs::setting_grabber = sub { return 'fe' };
	local *subs::config_reader = sub { return { name => 'Laptop' } };
	local *subs::ui = sub { return 'Local' };
	local *subs::machine_name = sub { return 'Laptop' };
	is(&Manager::music_library_label({ library => 'local' }, undef), 'Laptop',
		'the local label prefers the configured machine name');
	local *subs::machine_name = sub { return 'Phone' };
	is(&Manager::music_library_label({ library => 'local' }, undef), 'Phone',
		'a stale me/computer_name never becomes the library name');
	local *subs::machine_name = sub { return 'This machine' };
	{
		package LocalViewContext;
		sub param { return 'Table' }
	}
	my $c = bless {}, 'LocalViewContext';
	is(&Manager::music_library_label({ library => 'local' }, $c), 'Table',
		'a relayed library still names its host');
}

# --- the controlled machine's output catalogue and its choice ---------------
{
	package FakeMusicApp;
	sub routes { return bless {}, 'FakeMusicRoutes' }
	package FakeMusicRoutes;
	sub get { return 1 }
	sub post { return 1 }
	package main;
}
{
	no warnings 'redefine';
	local *Manager::app = sub { return bless {}, 'FakeMusicApp' };
	require "$root/perl/Music/09_remote_control.pl";
}
{
	no warnings 'redefine';
	my $mao = { me => 'on', srv => 'off', 'laptop.jonathanferwerda.com' => 'off', '127.0.0.1' => 'off' };
	local *subs::settings_grabber = sub { return { mao => Mojo::JSON::encode_json($mao) } };
	local *subs::remote_machine_lister = sub { return [
		{ uuid => 'u1', hostname => 'Laptop', fqdn => 'laptop.jonathanferwerda.com', ip => '1.2.3.4', connection => 'active', device => 'computer' },
		{ uuid => 'u2', hostname => 'hub', fqdn => 'hub.jonathanferwerda.com', ip => '1.2.3.5', connection => 'active', device => 'server' },
		{ uuid => 'u3', hostname => 'me', ip => '127.0.0.1' },
	] };
	local *subs::signatorial_designer = sub { return 'SELF' };
	local *subs::machine_name = sub { return 'Table' };
	local *subs::device_hostname_better = sub { return $_[0] };
	local *subs::ui = sub { return $_[0] };
	my $catalogue = &Manager::music_output_catalogue();
	is($catalogue->{'current'}, 'me', 'the output in use is the first one on');
	is_deeply([ map { $_->{'key'} } @{$catalogue->{'outputs'}} ],
		[ 'me', 'srv', 'laptop.jonathanferwerda.com', 'hub.jonathanferwerda.com' ],
		'the catalogue is this machine, the server, and the reachable peers, never the synthetic self row');
	is($catalogue->{'outputs'}[0]{'label'}, 'Table (internal speaker)', 'the machine output names itself and its speaker');
	my (@writes, @sent);
	local *subs::setting_setter = sub { push @writes, $_[0] };
	local *Websocket::send = sub { push @sent, [ @_ ] };
	local *Websocket::console_command = sub { return 'cmd(' . join(',', @_) . ')' };
	ok(&Manager::music_output_pick('laptop.jonathanferwerda.com'), 'a reachable output can be chosen');
	is(scalar @writes, 1, 'the choice is one setting write');
	is($writes[0]{'setting'}, 'mao', 'it writes the host mao');
	my $written = Mojo::JSON::decode_json($writes[0]{'value'});
	is($written->{'laptop.jonathanferwerda.com'}, 'on', 'the picked output plays');
	is($written->{'me'}, 'off', 'and the machine speaker goes quiet: this is a choice, not an addition');
	is($written->{'srv'}, 'off', 'nor is the server left on');
	is(scalar @sent, 1, 'the host player is told once');
	like($sent[0][1]{'console'}, qr/musicOutputApply/, 'by the named live-apply instruction');
	my $before = scalar @writes;
	ok(!&Manager::music_output_pick('not-an-output'), 'an unknown output is refused');
	is(scalar @writes, $before, 'and nothing is written');
}

done_testing();
