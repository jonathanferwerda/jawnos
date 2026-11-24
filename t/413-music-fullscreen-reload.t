# tests-for: public/js/music.js public/css/music.css public/css/manager.css templates/apps/video/script.html.ep public/js/manager/windows/02_fit.js public/js/manager/windows/00_store.js public/js/manager/keyboard/03_editor_switcher.js
# covers:    A reload comes back to the Music player's full-screen view. A
#            browser will not re-enter its top layer without a press, so the
#            choice rides in the player cache as an intent (not the live
#            element a reload clears), the restored view is the
#            `music_fullscreen` dress on #music plus `window_music_full` on its
#            window, and the first press asks for the real fullscreen again.
#            Escape leaves the dress; a reload's own leave must not erase the
#            choice; a stored window shell drops the runtime classes.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $music = read_file("$root/public/js/music.js");
my $music_css = read_file("$root/public/css/music.css");
my $manager_css = read_file("$root/public/css/manager.css");
my $video = read_file("$root/templates/apps/video/script.html.ep");
my $keys = read_file("$root/public/js/manager/keyboard/03_editor_switcher.js");
my $fit = read_file("$root/public/js/manager/windows/02_fit.js");
my $store = read_file("$root/public/js/manager/windows/00_store.js");

# --- the choice rides in the player cache -----------------------------------
my ($saver) = $music =~ /(function playerCacheSaver\(type, force\)\s*\{.*?\n\})/s;
ok(defined $saver, 'playerCacheSaver is found');
like($saver // '', qr/fullscreen: musicFullscreenIntent \? 1 : 0/,
	'the player cache carries the full-screen choice');
like($saver // '', qr/theatre_mode: \$\('#video'\)\.attr\('theatre_mode'\)/,
	'beside the theatre choice it already carried');
unlike($saver // '', qr/fullscreen: *document\.fullscreenElement/,
	'not the live element, which a reload has already cleared');

# --- the restore reads it and hands it to the player ------------------------
my ($init) = $music =~ /(async function musicInit\(method\)\s*\{.*?\n\})/s;
ok(defined $init, 'musicInit is found');
like($init // '', qr/musicFullscreenRestorePending = !!pd\.fullscreen;/,
	'the saved choice arms the restore');
my $pending_at = index($init // '', 'musicFullscreenRestorePending = !!pd.fullscreen;');
my $maker_at = index($init // '', 'mediaMaker({ file: saved_file');
ok($pending_at >= 0 && $maker_at > $pending_at,
	'armed before the restored track is loaded');

my ($maker) = $music =~ /(function mediaMaker\(data\)\s*\{.*?\n\})/s;
ok(defined $maker, 'mediaMaker is found');
like($maker // '', qr/musicFullscreenRestoreApply\(\);/,
	'mediaMaker applies the restored dress');
my $theatre_at = index($maker // '', 'theatreModeOff();');
my $apply_at = index($maker // '', 'musicFullscreenRestoreApply();');
ok($theatre_at >= 0 && $apply_at > $theatre_at,
	'after the theatre has repainted the player');

# --- the apply: dress, first press, then the real thing ---------------------
my ($apply) = $music =~ /(function musicFullscreenRestoreApply\(\)\s*\{.*?\n\})/s;
ok(defined $apply, 'musicFullscreenRestoreApply is found');
like($apply // '', qr/if \(!musicFullscreenRestorePending\) \{ return; \}/,
	'it does nothing unless the reload armed it');
like($apply // '', qr/musicFullscreenOn\(\);/, 'the apply paints the full-screen view');
like($apply // '', qr/musicFullscreenRestoreArm\(\);/, 'arms the first press');
like($apply // '', qr/musicPlayerFullscreen\(\);/, 'and asks for the top layer once');

my ($arm) = $music =~ /(function musicFullscreenRestoreArm\(\)\s*\{.*?\n\})/s;
ok(defined $arm, 'musicFullscreenRestoreArm is found');
like($arm // '', qr/pointerdown\.music_fs_restore/, 'the first press is a pointerdown in the player');
like($arm // '', qr/\.one\('pointerdown\.music_fs_restore'/, 'and it is armed once only');
like($arm // '', qr/musicPseudoFullscreen\(\) && !musicFullscreenElement\(\)/,
	'only while the dress is still up');
like($arm // '', qr/musicPlayerFullscreen\(\)/, 'that press asks for the real fullscreen');

my ($on) = $music =~ /(function musicFullscreenOn\(\)\s*\{.*?\n\})/s;
ok(defined $on, 'musicFullscreenOn is found');
like($on // '', qr/addClass\('music_fullscreen'\)/, 'the dress is a class on #music');
like($on // '', qr/musicFullscreenWindow\(true\)/, 'and on its window');
like($on // '', qr/musicFullscreenIntent = true/, 'the choice is remembered');
like($on // '', qr/musicPicturePlace\(\);/, 'the picture takes the big style');
like($on // '', qr/musicChaptersRefresh\(\);/, 'and the chapter row comes with it');
like($on // '', qr/musicChromeArm\(\);/, 'the bars can slide away again');
like($on // '', qr/musicChromeShow\(\$\('#music \.media_controls\.music_player_bar'\)\);/, 'and start in reach');

my ($off) = $music =~ /(function musicFullscreenOff\(\)\s*\{.*?\n\})/s;
ok(defined $off, 'musicFullscreenOff is found');
like($off // '', qr/removeClass\('music_fullscreen'\)/, 'leaving takes the class off');
like($off // '', qr/musicFullscreenWindow\(false\)/, 'and the window class');
like($off // '', qr/musicFullscreenRestoreDisarm\(\)/, 'and the armed press');

# --- the desktop app can supply the press -------------------------------
my ($gesture) = $music =~ /(function musicFullscreenGestureAsk\(\)\s*\{.*?\n\})/s;
ok(defined $gesture, 'musicFullscreenGestureAsk is found');
like($gesture // '', qr/if \(!window\.JawnDesktop \|\| !window\.webkit \|\| !window\.webkit\.messageHandlers/,
	'it only runs in the desktop app');
like($gesture // '', qr/messageHandlers\.jawnos\.postMessage/, 'and asks the shell through its own shim');
like($gesture // '', qr/action: 'resume_fullscreen'/, 'for the trusted click');
like($gesture // '', qr/rect\.left \+ rect\.width \/ 2/, 'targeting the corner target\'s own middle');
like($gesture // '', qr/id="music_fullscreen_gesture"/, 'a corner target catches that click');
like($gesture // '', qr/musicPlayerFullscreen\(\)/, 'and turns it into the real request');
like($gesture // '', qr/setTimeout\(musicFullscreenGestureRemove, 1200\)/,
	'the target does not linger if no click comes');
like($apply // '', qr/musicFullscreenGestureAsk\(\);/, 'the restore asks for the desktop gesture');
like($off // '', qr/musicFullscreenGestureRemove\(\);/, 'leaving the dress removes the target');

my ($leave) = $music =~ /(function musicFullscreenLeave\(\)\s*\{.*?\n\})/s;
ok(defined $leave, 'musicFullscreenLeave is found');
like($leave // '', qr/musicPseudoFullscreen\(\)/, 'it only acts on the restored dress');
like($leave // '', qr/musicFullscreenIntent = false/, 'an explicit leave forgets the choice');
like($leave // '', qr/playerCacheSaver\(undefined, true\)/, 'and writes it at once');

# --- a reload's own exit must not erase the choice --------------------------
my ($change) = $music =~ /(\$\(document\)\.on\('fullscreenchange webkitfullscreenchange'.*?\n\}\);)/s;
ok(defined $change, 'the fullscreenchange handler is found');
like($change // '', qr/musicWasFullscreen/, 'the handler knows a real fullscreen ended');
like($change // '', qr/setTimeout\(function\(\) \{/, 'and waits before clearing the choice');
like($change // '', qr/\}, 1200\);/, 'longer than the leave a reload causes');
like($change // '', qr/if \(!document\.hidden\)/, 'a backgrounded page keeps the choice');
like($change // '', qr/musicFullscreenRestoreDisarm\(\)/, 'the top layer disarms the restored press');
like($change // '', qr/removeClass\('music_fullscreen'\)/, 'the real fullscreen supplies the same dress');
like($change // '', qr/musicFullscreenIntent = true/, 'and remembers it');
like($change // '', qr/musicChromeShow\(\$\('#music \.media_controls\.music_player_bar'\)\);/, 'the real fullscreen starts with the bar in reach');

# --- the player toggle promotes and exits honestly --------------------------
my ($player_fs) = $music =~ /(function musicPlayerFullscreen\(\)\s*\{.*?\n\})/s;
ok(defined $player_fs, 'musicPlayerFullscreen is found');
like($player_fs // '', qr/if \(musicFullscreenAsking\) \{ return; \}/, 'one request at a time');
like($player_fs // '', qr/musicFullscreenIntent = false/, 'a second press forgets the choice');
like($player_fs // '', qr/playerCacheSaver\(undefined, true\)/, 'and writes it');
like($player_fs // '', qr/if \(p && p\.then\)/, 'the request promise has a handler');
like($player_fs // '', qr/catch \(e\) \{ p = null; \}/, 'and a synchronous refusal cannot break the restore');

my ($content) = $music =~ /(function musicContentCache\(html\)\s*\{.*?\n\})/s;
ok(defined $content, 'musicContentCache is found');
like($content // '', qr/removeClass\('music_fullscreen'\)/,
	'a stored content shell does not replay the dress');
like($content // '', qr/removeClass\('window_music_full'\)/,
	'nor the window class');
like($content // '', qr/find\('#music_fullscreen_gesture'\)\.remove\(\)/,
	'and the desktop gesture target');

# --- the stylesheet dresses the same player ---------------------------------
like($music_css, qr/#music:fullscreen,\s*\n#music:-webkit-full-screen,\s*\n#music\.music_fullscreen \{/,
	'the dress joins the fullscreen selector, not a copy that can drift');
like($music_css, qr/#music\.music_fullscreen #music_theatre \{/,
	'the theatre fills the screen in the dress');
like($music_css, qr/#music\.music_fullscreen #music_library \{/,
	'and the library is put away');
like($manager_css, qr/\.wind\.window_music_full \{/, 'the window takes the whole glass');
like($manager_css, qr/\.wind\.window_music_full > \.top_navbar \{ display: none !important; \}/,
	'with its title bar away');
like($manager_css, qr/#browser:has\(> \.wind\.window_music_full/, 'and is raised over the taskbar and dock');
like($manager_css, qr/\.wind\.window_music_full > \.window_fullview_exit \{ display: none !important; \}/,
	'and hides the window full-view corner restore while the dress is on');
like($fit, qr/hasClass\('window_music_full'\)/, 'a window fit leaves the dress alone');
like($store, qr/classList\.remove\('window_music_full'\)/, 'a stored shell drops the runtime window class');
like($store, qr/classList\.remove\('music_fullscreen'\)/, 'and the player class too');
like($store, qr/child\.id == 'music_fullscreen_gesture'/, 'and the desktop gesture target is dropped');

# --- the bar's own handlers know the dress ----------------------------------
like($video, qr/closest\('\.music_fullscreen'\)\.length/, 'the bars hide in a restored full screen');
like($video, qr/closest\('\.music_fullscreen'\)\[0\]/, 'the seek preview follows it, not the window frame');
like($keys, qr/musicFullscreenLeave\(\)/, 'Escape leaves the restored dress');

done_testing();
