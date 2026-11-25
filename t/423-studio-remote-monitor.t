# tests-for: lib/JawnOS/Controller/manager_misc9.pm public/js/manager/studio/07_layout.js
# covers:    The controller follow-up to remote Studio control: the Monitor
#            picker that chooses the controlled machine's own physical output
#            (the same list and default the Sound app writes), its two relayed
#            routes, and the read-only arrangement mirror — the target's clips
#            in the target's track colours plus a playhead at its position,
#            drawn over the controller's timeline and cleared on the way out.

use strict;
use warnings;

use FindBin;
use Test::More;
use File::Slurp qw(read_file);

my $root       = "$FindBin::Bin/..";
my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my $routes     = read_file("$root/lib/JawnOS/Routes/manager_misc9.pm");
my $layout     = read_file("$root/public/js/manager/studio/07_layout.js");
my $markup     = read_file("$root/templates/studio/markup.html.ep");
my $style      = read_file("$root/templates/studio/style.html.ep");

# --- the two routes ----------------------------------------------------------
my @routes = (
	[ 'get',  '/manager/studio/remote_devices', 'action_44042' ],
	[ 'post', '/manager/studio/remote_device',  'action_44043' ],
);
for my $row (@routes) {
	my ($method, $path, $action) = @{$row};
	like($routes, qr/\[\s*\d+\s*,\s*'\Q$method\E'\s*,\s*'\Q$path\E'\s*,\s*'\Q$action\E'\s*\]/,
		"$method $path is registered to $action");
	like($controller, qr/^\s*sub\s+\Q$action\E\b/m, "$action exists in the controller");
}

# --- the device list is the target's, shape is {id,label,default} ------------
like($controller, qr/sub studio_remote_devices_read/, 'one reader answers the list');
like($controller, qr/subs::sound_status\(\)/, 'it asks the sound system for the devices');
like($controller, qr/\$status->\{'outputs'\}/, 'the physical outputs are the list');
like($controller, qr/id => \$device->\{'id'\}/, 'each row carries its id');
like($controller, qr/label => \(\$device->\{'name'\} \|\| \$device->\{'id'\}\)/,
	'its display name');
like($controller, qr/default => \(\$device->\{'default'\} \? 1 : 0\)/, 'and whether it is the default');
like($controller, qr/ok => 1, outputs => \\\@outputs, current => \$current/,
	'the answer is {ok, outputs, current}');
like($controller, qr/subs::setting_grabber\(\{ app => 'studio', setting => 'remote_monitor' \}\)/,
	'the remembered choice is a Studio setting');
like($controller, qr/grep \{ \$_->\{'id'\} eq \$stored \} \@outputs/,
	'and only counts while the device is still there');

# --- choosing is the target's default output ---------------------------------
like($controller, qr/sub studio_remote_device_set/, 'one writer picks the output');
like($controller, qr/subs::sound_default\('output', \$id\)/,
	'it is the same default the Sound app sets');
like($controller, qr/ok => \$ok \? 1 : 0, id => \$id, current => \$id/,
	'the write answers the id back as current');
like($controller, qr/subs::setting_setter\(\{ app => 'studio', setting => 'remote_monitor', value => \$id \}\)/,
	'and remembers it for a re-entry');

# --- both routes relay with the remote checks --------------------------------
for my $action (qw(action_44042 action_44043)) {
	my ($body) = $controller =~ /(sub \Q$action\E \{.*?\n\})/s;
	ok($body && length($body), "$action has a body");
	like($body, qr/\(\$c->param\('remoted'\) \|\| ''\) eq 'yes'/, "$action lets a relayed request answer here");
	like($body, qr/studio_remote_peer\(\$target\)/, "$action checks the target is active");
	like($body, qr/\$c->param\('remote_uuid' => \$peer->\{'uuid'\}\)/, "$action names the peer on the relay");
	like($body, qr/studio_remote_relay\(\$c\)/, "$action relays through the signed rail");
	like($body, qr/that machine is not reachable/, "$action refuses an inactive peer");
	like($body, qr/status => 409/, "$action answers a conflict");
}
like($controller, qr/sub action_44043 \{.*?studio_remote_value\(\$c, \$body, 'id'\)/s,
	'the write reads the chosen device id');

# --- the top-bar picker ------------------------------------------------------
like($markup, qr/id="studio_remote_monitor_picker"/, 'the bar carries a Monitor group');
like($markup, qr/id="studio_remote_monitor"/, 'with its own select');
like($markup, qr/for="studio_remote_monitor"[^>]*>.*?Monitor/s, 'labelled Monitor');
like($markup, qr/subs::ui\('Monitor'\)/, 'in translatable words');
like($markup, qr/id="studio_remote_monitor_picker"[^\n]*\bhidden\b/,
	'it starts hidden while this window drives itself');
like($markup, qr/id="studio_remote_overlay"/, 'the viewer has a mirror overlay');

# --- the monitor picker's JS -------------------------------------------------
like($layout, qr/function studioRemoteMonitorLoad\(\)/, 'the picker has one loader');
like($layout, qr{url: '/manager/studio/remote_devices'}, 'it asks remote_devices');
like($layout, qr/data: \{ target: target \}/, 'for the chosen target');
like($layout, qr/reply\.outputs/, 'and builds one option per output');
like($layout, qr/reply\.current/, 'selecting the remembered output');
like($layout, qr{url: '/manager/studio/remote_device'}, 'a choice posts to remote_device');
like($layout, qr/data: \{ target: target, id: String\(id\) \}/, 'with the target and the device id');
like($layout, qr/function studioRemoteMonitorPick\(id\)/, 'one picker sends the write');
like($layout, qr/\$\('#studio_remote_monitor'\)\.prop\('disabled', !show\)/,
	'the select is disabled while this machine is chosen');
like($layout, qr/\.attr\('hidden', 'hidden'\)/, 'and the group is hidden with it');
like($layout, qr/studioRemoteMonitorLoad\(\);\s*\n\s*studioRemotePollStart\(\);/,
	'entering remote mode loads the target devices');
like($layout, qr/studioRemoteMonitorPickerShow\(false\);\s*\n\s*studioRemoteOverlayClear\(\);/,
	'leaving remote mode hides the picker and clears the mirror');

# --- the arrangement mirror --------------------------------------------------
like($layout, qr/function studioRemoteOverlayPaint\(\)/, 'the controller paints an overlay');
like($layout, qr/studioTimelineXAt\(lane, studioKnobNumber\(clip\.start, 0\)\)/,
	'clip start reuses the timeline geometry');
like($layout, qr/studioTimelineWidth\(lane, studioKnobNumber\(clip\.length, 0\)\)/,
	'clip length reuses it too');
like($layout, qr/studioRemoteOverlayColour\(state, ch\)/, 'clips take the track colour');
like($layout, qr/studioColourRgba\(colour, 0\.5\)/, 'through the shared colour helper');
like($layout, qr/studioTrackColour\(ch\)/, 'with the target track colour as fallback');
like($layout, qr/byTrack\[ch\]/, 'clips are grouped by the track they sit on');
like($layout, qr/\(state\.transport \|\| \{\}\)\.position/, 'the playhead is the target position');
like($layout, qr/ctx\.moveTo\(px, 0\);\s*\n\s*ctx\.lineTo\(px, h\);/, 'drawn down the lanes');
like($layout, qr/studioRemoteOverlayPaint\(\);\s*\n\s*return true;\s*\n\}/,
	'it is repainted on every 500 ms poll that renders');
like($layout, qr/function studioRemoteOverlayClear\(\)/, 'the mirror can be cleared');
like($layout, qr/studioRemoteOverlayQueue\(\)/, 'a viewer scroll or resize repaints it');
like($layout, qr/colour: \(typeof studioTrackColour === 'function'\) \? studioTrackColour\(ch\) : ''/,
	'the published track carries its colour for the controller');

# The mirror is read-only: the overlay block names no command, transport seek
# or local paint, so nothing it draws can drag, trim, split or cut.
my ($mirror) = $layout =~ /(\/\/ ---- the peer's arrangement.*?)\/\/ ---- the controller paints the peer's state/s;
ok($mirror && length($mirror), 'the overlay block is present');
unlike($mirror // '', qr/studioRemoteCommand\(/, 'the mirror never sends a command');
unlike($mirror // '', qr/studioSeek\(/, 'it never seeks the local transport');
unlike($mirror // '', qr/studioDrawTracks\(/, 'it never repaints the local lanes');
unlike($mirror // '', qr/studioStartDrag|studioTakeDrag|studioTrim|studioSplit/,
	'and carries no drag, trim or split');

# --- the overlay is a passive layer in CSS -----------------------------------
like($style, qr/\.studio_remote_monitor_picker/, 'the Monitor group is styled');
like($style, qr/\.studio_remote_monitor_picker\[hidden\]/, 'hidden actually hides it');
like($style, qr/\.studio_remote_monitor \{/, 'the select is styled');
like($style, qr/\.studio_remote_overlay \{/, 'the overlay is styled');
like($style, qr/\.studio_remote_overlay \{[^}]*pointer-events: none/s,
	'and takes no pointer, so the mirror cannot be edited');
like($style, qr/#studio\.studio_remote_controller \.studio_remote_overlay \{\s*\n?\s*display: block;/,
	'appearing only while a peer is controlled');

done_testing();
