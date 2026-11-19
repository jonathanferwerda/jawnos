# tests-for: public/js/manager/studio.js public/js/manager/studio/02_canvas.js public/js/manager/studio/13_strip.js public/js/manager/studio/07_layout.js templates/studio/markup.html.ep templates/studio/style.html.ep t/353-studio-strip.t
# covers:    The channel strip's M and S buttons: the markup and its hints, the
#            delegated handlers that toggle mixer[ch].mute / mixer[ch].solo and
#            call studioApplyMuteSolo() and studioSaver(), aria-pressed painted
#            from that state, the solo dimming on the row and the strip, the
#            repaint after a song load, and a recycled or new track starting
#            unsoloed and unmuted. Structure only; pixels are not asserted here.

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

my $root   = $FindBin::Bin;
$root =~ s{/t$}{};
my $markup = slurp("$root/templates/studio/markup.html.ep");
my $style  = slurp("$root/templates/studio/style.html.ep");
my $strip  = slurp("$root/public/js/manager/studio/13_strip.js");
my $layout = slurp("$root/public/js/manager/studio/07_layout.js");
my $canvas = slurp("$root/public/js/manager/studio/02_canvas.js");
my $studio = slurp("$root/public/js/manager/studio.js");

# --- the markup: two buttons under the fader, each with its own hint --------
like($markup, qr/class="studio_strip_mute_solo"/,
	'the strip has a mute/solo block under the fader');
like($markup, qr/class="studio_strip_body"[\s\S]*?class="studio_strip_mute_solo"[\s\S]*?studio_strip_mute[\s\S]*?studio_strip_solo/,
	'the block sits under the strip body, M before S');
like($markup, qr/<button class="studio_strip_mute hover" channel="<%=\s*\$ch\s*%>" aria-pressed="false" hint="<%=\s*&subs::ui\('Mute this channel'\)\s*%>">M<\/button>/,
	'M is a native button that starts unpressed and says what it does');
like($markup, qr/<button class="studio_strip_solo hover" channel="<%=\s*\$ch\s*%>" aria-pressed="false" hint="<%=\s*&subs::ui\('Solo this channel'\)\s*%>">S<\/button>/,
	'S is a native button that starts unpressed and says what it does');

# --- the stylesheet paints the two states and the solo dimming -------------
like($style, qr/\.studio_strip_mute_solo\s*\{[^}]*flex:\s*0 0 22px/s,
	'the block sits under the strip body');
like($style, qr/\.studio_strip_mute\[aria-pressed="true"\]\s*\{[^}]*background:/s,
	'a muted strip paints its button');
like($style, qr/\.studio_strip_solo\[aria-pressed="true"\]\s*\{[^}]*background:/s,
	'a soloed strip paints its button');
like($style, qr/\.channel\.studio_solo_muted\s*\{[^}]*opacity:/s,
	'a strip the solo leaves out is dimmed rather than removed');

# --- one renderer, from mixer state ---------------------------------------
like($strip, qr/^function studioStripMuteSoloRender\(\)/m,
	'one function paints every strip');
like($strip, qr/\$\.each\(mixer, function \(key, state\) \{[\s\S]*?if \(!\/\^\[0-9\]\+\$\/\.test\(String\(key\)\)\) \{ return; \}/,
	'it reads only the numeric channels of mixer');
like($strip, qr/if \(state && state\.solo\) \{ soloed = true; \}/,
	'any soloed channel is what turns the dimming on');
like($strip, qr/\$\(\x27\.studio_strip_mute\[channel="\x27 \+ ch \+ \x27"\]\x27\)\.attr\(\x27aria-pressed\x27, state\.mute \? \x27true\x27 : \x27false\x27\);/,
	'M paints its aria-pressed from mixer[ch].mute');
like($strip, qr/\$\(\x27\.studio_strip_solo\[channel="\x27 \+ ch \+ \x27"\]\x27\)\.attr\(\x27aria-pressed\x27, state\.solo \? \x27true\x27 : \x27false\x27\);/,
	'S paints its aria-pressed from mixer[ch].solo');
like($strip, qr/\$\(\x27#studio_track_row_\x27 \+ ch \+ \x27, #studio_mixer_strips \.channel_\x27 \+ ch\)/,
	'the row and its strip are dimmed together');
like($strip, qr/\.toggleClass\(\x27studio_solo_muted\x27, soloed && !state\.solo\)/,
	'a channel is dimmed only while something else is soloed');
like($strip, qr/return soloed;/, 'the renderer reports whether anything is soloed');

# --- the M click: state, then paint, then apply, then save ----------------
like($strip, qr/\$\(document\)\.on\(\x27click\x27, \x27\.studio_strip_mute\x27/,
	'an M click is delegated, so a cloned strip needs no rebinding');
my ($mute_handler) = $strip =~ /(\$\(document\)\.on\('click', '\.studio_strip_mute'[\s\S]*?\n\}\);)/;
ok($mute_handler, 'the M handler is one block');
like($mute_handler, qr/parseInt\(\$\(this\)\.attr\('channel'\), 10\)/,
	'the M handler reads the button channel');
like($mute_handler, qr/mixer\[ch\]\.mute = !mixer\[ch\]\.mute;[\s\S]*?studioStripMuteSoloRender\(\);[\s\S]*?typeof studioApplyMuteSolo === 'function'[\s\S]*?studioSaver\(\);/,
	'M toggles the channel, repaints, then applies the mix and saves');
unlike($mute_handler, qr/\.solo/, 'M never touches solo');

# --- the S click: the same path for solo ----------------------------------
like($strip, qr/\$\(document\)\.on\(\x27click\x27, \x27\.studio_strip_solo\x27/,
	'an S click is delegated too');
my ($solo_handler) = $strip =~ /(\$\(document\)\.on\('click', '\.studio_strip_solo'[\s\S]*?\n\}\);)/;
ok($solo_handler, 'the S handler is one block');
like($solo_handler, qr/parseInt\(\$\(this\)\.attr\('channel'\), 10\)/,
	'the S handler reads the button channel');
like($solo_handler, qr/mixer\[ch\]\.solo = !mixer\[ch\]\.solo;[\s\S]*?studioStripMuteSoloRender\(\);[\s\S]*?typeof studioApplyMuteSolo === 'function'[\s\S]*?studioSaver\(\);/,
	'S toggles the channel, repaints, then applies the mix and saves');
unlike($solo_handler, qr/\.mute/, 'S never touches mute');
unlike($strip, qr/'keydown', '\.studio_strip_/,
	'no extra key handler: the buttons are native and already keyboard-accessible');

# --- a song load and a fresh window both get a repaint --------------------
like($strip, qr/\$\(document\)\.on\('studio:mute-solo', function \(\) \{ studioStripMuteSoloRender\(\); \}\);/,
	'loading a song asks the strip to repaint through one document event');
like($strip, qr/\$\(document\)\.on\('jawnos_synth_panel', function \(\) \{ studioStripMuteSoloRender\(\); \}\);/,
	'a window opened after this part loads paints mixer state, not the defaults');

# --- a recycled clone starts clean ----------------------------------------
like($layout, qr/function studioResetChannelMarkup\(node, ch\)[\s\S]*?if \(mixer\[ch\]\) \{ mixer\[ch\]\.mute = false; mixer\[ch\]\.solo = false; \}/,
	'the reset clears the clone channel\x27s mute and solo state');
like($layout, qr/function studioResetChannelMarkup\(node, ch\)[\s\S]*?node\.find\('\.studio_strip_mute, \.studio_strip_solo'\)\.removeAttr\('aria-pressed'\)/,
	'the reset drops the cloned buttons\x27 pressed state');
like($layout, qr/function studioResetChannelMarkup\(node, ch\)[\s\S]*?node\.removeClass\('studio_solo_muted'\);\s*\n\s*node\.find\('\.studio_solo_muted'\)\.removeClass\('studio_solo_muted'\);/,
	'the reset clears the solo dimming from the node and its children');
like($layout, qr/studioResetChannelMarkup\(row, ch\);[\s\S]*?studioResetChannelMarkup\(strip, ch\);/,
	'a new track resets both its row and its strip');

# --- a new track is audible, unsoloed and painted -------------------------
like($layout, qr/if \(!mixer\[ch\]\.armed\) \{ mixer\[ch\]\.armed = \{ state: 'off', text: 'O' \}; \}[\s\S]*?mixer\[ch\]\.mute = false;[\s\S]*?mixer\[ch\]\.solo = false;/,
	'a new channel starts unmuted and unsoloed');
like($layout, qr/mixer\[ch\]\.solo = false;[\s\S]*?if \(typeof studioStripMuteSoloRender === 'function'\) \{ studioStripMuteSoloRender\(\); \}/,
	'creating a track repaints the strips, if the strip part is loaded');

# --- deleting the soloed track does not leave the rest dimmed --------------
like($layout, qr/function studioRemoveTrack\(ch, quiet\)[\s\S]*?\$\('#studio_mixer_strips \.channel_' \+ ch\)\.remove\(\);[\s\S]*?if \(typeof studioStripMuteSoloRender === 'function'\) \{ studioStripMuteSoloRender\(\); \}/,
	'removing a track repaints mute/solo once it is gone');

# --- the rest of the clone reset is untouched -----------------------------
like($layout, qr/function studioResetChannelMarkup\(node, ch\)[\s\S]*?node\.removeAttr\('data-colour'\)/,
	'the reset still clears the inherited colour');
like($layout, qr/studioResetChannelMarkup[\s\S]*?studio_strip_led'\)\.removeClass\('lit'\)/,
	'a recycled strip starts with its meter dark');
like($layout, qr/studioCreateTrack[\s\S]*?studioApplyTrackColour\(ch, studioRandomTrackColour\(\)\)/,
	'a new track still gets its own colour');
like($layout, qr/studioCreateTrack[\s\S]*?studioChannelEngine\(ch\)/,
	'a new track still creates its engine channel');

# --- the ten-LED level ladder and the dB scale -----------------------------
like($markup, qr/class="studio_strip_meter" channel="<%=\s*\$ch\s*%>"/,
	'the strip carries a level meter');
like($markup, qr/data-led="<%=\s*\$led\s*%>"/, 'each LED carries its index');
like($markup, qr/for my \$led \(0 \.\. 9\)/, 'the meter renders ten LEDs');
like($markup, qr/\$led < 5 \? 'led_green' : \(\$led < 8 \? 'led_yellow' : 'led_red'\)/,
	'five green, three yellow and two red LEDs');
like($markup, qr/class="studio_strip_scale"[\s\S]*?0\.0[\s\S]*?-6[\s\S]*?-12[\s\S]*?-24[\s\S]*?infin/,
	'the fader carries a dB scale with 0.0 at the top');
like($markup, qr/class="studio_strip_control"[\s\S]*?studio_strip_fader_group[\s\S]*?studio_strip_meter[\s\S]*?studio_strip_mute_solo/,
	'mute and solo sit under the fader and meter');
like($style, qr/\.studio_strip_control\s*\{[^}]*flex:\s*0 0 47px/s,
	'the fader and meter share one control column');
like($style, qr/\.studio_strip_led\.led_yellow\.lit\s*\{[^}]*background:/s,
	'the yellow LEDs have their own lit colour');
like($style, qr/\.studio_strip_scale\s*\{[^}]*position:\s*absolute/s,
	'the dB scale is drawn inside the fader');
like($studio, qr/meterAnalyser:\s*ctx\.createAnalyser\(\)/, 'each channel owns a level analyser');
like($canvas, qr/studio_strip_led[\s\S]{0,220}toggleClass\('lit'/,
	'each transport repaint lights the LED ladder');


done_testing();
