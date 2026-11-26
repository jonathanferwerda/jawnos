# tests-for: public/js/manager/studio/04_knobs.js public/js/manager/studio/09_pedals.js public/js/manager/studio/03_editing.js public/js/manager/studio/05_inputs.js public/js/manager/studio/06_controls.js public/js/manager/studio/07_layout.js templates/studio/markup.html.ep templates/studio/style.html.ep perl/help/topics_apps.pl
# covers:    The Studio's small-screen reading: the pedalboard scrolls with a
#            one-wheel mouse and with a swipe (a press and hold is the reorder),
#            the track panel's hold/right-click menu carries Channel in,
#            Channel out and Delete, the strip's M and S are larger while the
#            fader and meter give up width, and the transport carries the
#            repeat button while its clock is a big m:ss.ffff time over a small
#            bar:beat line and the Engine/Browser badge lives on the layout bar.
#            Structure only; pixels are not asserted here.

use strict;
use warnings;

use FindBin;
use Test::More;

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or die "cannot read $path: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

my $root = $FindBin::Bin;
$root =~ s{/t$}{};
my $markup   = slurp("$root/templates/studio/markup.html.ep");
my $style    = slurp("$root/templates/studio/style.html.ep");
my $edit     = slurp("$root/public/js/manager/studio/03_editing.js");
my $knobs    = slurp("$root/public/js/manager/studio/04_knobs.js");
my $inputs   = slurp("$root/public/js/manager/studio/05_inputs.js");
my $controls = slurp("$root/public/js/manager/studio/06_controls.js");
my $layout   = slurp("$root/public/js/manager/studio/07_layout.js");
my $pedals   = slurp("$root/public/js/manager/studio/09_pedals.js");
my $help     = slurp("$root/perl/help/topics_apps.pl");

# --- the wheel moves the chain sideways, after the knobs took their press ---
like($knobs, qr/closest\('#studio_pedalboard_rack'\)/,
	'the wheel handler finds the pedalboard rack');
like($knobs, qr/rack\.scrollLeft -= studioWheelDelta\(event\)/,
	'a one-wheel mouse scrolls the rack sideways');
my $knob_at = index($knobs, "target.closest('.knob')");
my $rack_at = index($knobs, "target.closest('#studio_pedalboard_rack')");
ok($knob_at >= 0 && $rack_at > $knob_at,
	'the knob is tested before the rack, so a wheel on a knob still turns it');
like($style, qr/#studio_pedalboard_rack::-webkit-scrollbar\s*\{[^}]*display:\s*block/s,
	'the board brings its scrollbar back (the shared sheet hides them)');
like($style, qr/#studio_pedalboard_rack\s*\{[^}]*scrollbar-width:\s*thin/s,
	'Firefox gets the thin board scrollbar too');

# --- a touch hold drags a pedal; a swipe moves the board --------------------
like($pedals, qr/function studioBoardPressMode\(touch\)/,
	'one helper puts the board\'s drag into touch mode');
like($pedals, qr/delay: touch \? 250 : 0, distance: touch \? 8 : 0/,
	'a finger holds before a reorder; a mouse still drags at once');
like($pedals, qr/document\.addEventListener\('touchstart'[\s\S]*?studioBoardPressMode\(true\)/,
	'a touch start raises the hold');
like($pedals, qr/document\.addEventListener\('mousedown'[\s\S]*?event\.isTrusted === false[\s\S]*?studioBoardPressMode\(false\)/,
	'a real mouse press puts the drag back to instant');
like($pedals, qr/var studioBoardSwipe = null;/,
	'the swipe keeps one gesture at a time');
like($pedals, qr/sortable\._mouseStarted\) \{ studioBoardSwipe = null; return; \}/,
	'a press that became a reorder stops moving the board');
like($pedals, qr/swipe\.rack\.scrollLeft = swipe\.left - dx;/,
	'the swipe moves the rack by hand (Touch Punch cancelled the native scroll)');
like($pedals, qr/document\.elementFromPoint[\s\S]*?pedal_select_row/,
	'a touch on a knob or a list belongs to that control, not the board');
like($pedals, qr/\$\(document\)\.trigger\(\$\.Event\('mouseup'\)\);/,
	'a swipe cancels the pending press so a long swipe cannot become a drag');

# --- the track panel's hold/right-click menu -------------------------------
like($layout, qr/function studioTrackPanelMenu\(ch, at\)/,
	'the track panel has its own menu');
like($layout, qr/studioTrackPanelMenu[\s\S]*?row\('input', 'Channel in'\)[\s\S]*?row\('output', 'Channel out'\)[\s\S]*?row\('delete', 'Delete track'\)/,
	'the menu offers channel in, channel out and delete');
like($layout, qr/contextmenu', '\.studio_track_panel'/,
	'a mouse right-click opens it');
like($layout, qr/\}, 500\);/,
	'a touch opens it after a still half-second');
like($layout, qr/channelSelect\(ch, action, at\)/,
	'a menu row opens the picker at the menu\'s own point');
like($inputs, qr/async function channelSelect\(channel,direction,at\)/,
	'the picker accepts that point');
like($inputs, qr/isFinite\(at\.x\)\) \? at\.x : m\.x/,
	'and falls back to the pointer for a jack press');
like($layout, qr/action === 'delete'\)[\s\S]*?studioRemoveTrack\(ch\)/,
	'Delete removes the track from the same menu');
like($layout, qr/studioTrackHoldOpened[\s\S]*?stopPropagation\(\)/,
	'the hold that opened the menu cannot also select the track behind it');
like($layout, qr/document\.elementFromPoint[\s\S]*?studio_track_resize[\s\S]*?return;/,
	'the hold is taken anywhere but the resize grip');
like($markup, qr/hint="<%=\s*&subs::ui\('Tap to select; press and hold for channel in, out and delete'\)\s*%>"/,
	'the panel says how to reach the menu');

# --- bigger M and S, a smaller fader and meter -----------------------------
like($style, qr/\.studio_strip_mute_solo\s*\{[^}]*flex:\s*0 0 30px[^}]*height:\s*30px/s,
	'the mute/solo row is taller');
like($style, qr/\.studio_strip_mute,\s*\.studio_strip_solo\s*\{[^}]*flex:\s*1 1 0[^}]*height:\s*26px[^}]*font-size:\s*13px/s,
	'M and S fill the strip and read larger');
like($style, qr/\.studio_strip_control\s*\{[^}]*flex:\s*0 0 42px/s,
	'the fader and meter column narrowed');
like($style, qr/\.channel_fader\s*\{[^}]*width:\s*30px[^}]*flex:\s*0 0 30px/s,
	'the fader is narrower');
like($style, qr/\.studio_strip_meter\s*\{[^}]*flex:\s*0 0 8px[^}]*width:\s*8px/s,
	'and so is the meter graph');

# --- the layout bar carries the badge; the transport carries the repeat ----
like($markup, qr/id="studio_layout_bar"[\s\S]*id="studio_audio_path"/,
	'the Engine/Browser badge moved to the layout bar');
like($markup, qr/class="studio_transport_row"[\s\S]*id="studio_loop"/,
	'the repeat button moved to the transport');
unlike($markup, qr/id="studio_pedals"/, 'the Pedals button is gone');
unlike($markup, qr/id="pedalboard_hamburger"/, 'the transport burger is gone');
unlike($edit, qr/#studio_pedals|pedalboard_hamburger/,
	'the open path no longer mirrors either button');

# --- the clock: m:ss.ffff over bar:beat.hh ---------------------------------
like($controls, qr/function studioClockLabel\(seconds\)/,
	'one formatter serves every clock read');
like($controls, qr/fraction = Math\.round\(\(rest - whole\) \* 10000\)/,
	'the clock counts ten-thousandths');
like($controls, qr/\('0000' \+ fraction\)\.slice\(-4\)/,
	'and always writes four fraction digits');
like($controls, qr/\$\('#studio_time_display'\)\.html\(studioClockLabel\(time\)\)/,
	'the big line is the position in m:ss.ffff');
like($controls, qr/beatFraction = \(Math\.floor\(\(inBar \* 100\) \+ 1e-6\) \/ 100\)\.toFixed\(2\)/,
	'the beats line counts a hundredth of a beat');
like($controls, qr/\$\('#studio_time_beats'\)\.html\(mixer\['time'\]\['bar'\] \+ ':' \+ beatFraction\)/,
	'and reads bar:beat.hh');
like($markup, qr/<span class="studio_transport_clock"><span id="studio_time_display">0:00\.0000<\/span>[\s\S]*?<span id="studio_time_duration">0:00\.0000<\/span><\/span>\s*<span class="studio_transport_beats" id="studio_time_beats">0:0\.00<\/span>/,
	'the markup starts at m:ss.ffff with the beats line underneath');
like($style, qr/\.studio_transport_time\s*\{[^}]*flex-direction:\s*column[^}]*align-items:\s*flex-end/s,
	'the clock stacks the beats under the time');
like($style, qr/#studio_time_display\s*\{\s*font-size:\s*30px/m,
	'the time is the big read');
like($style, qr/#studio_time_beats\s*\{\s*font-size:\s*12px/m,
	'and the beats line is smaller');
like($layout, qr/\$\('#studio_time_duration'\)\.html\(studioClockLabel\(mixer\['time'\]\['duration'\]\)\)/,
	'the remote mirror writes the same duration format');

# --- help follows the controls ---------------------------------------------
like($help, qr/'Tap to select; press and hold for channel in, out and delete'/,
	'help names the panel hold menu');
like($help, qr/a wheel over the board moves it even when the mouse has only one wheel/,
	'help says the wheel moves the board');
like($help, qr/a press and hold picks a pedal up/,
	'help says a hold is the reorder on a touch screen');
like($help, qr/ten-thousandths/,
	'help describes the transport clock');
like($help, qr/Channel in and Channel out open the same input and output pickers/,
	'help says the menu opens the same pickers as the jacks');

done_testing();
