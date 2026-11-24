# tests-for: public/js/manager/studio/07_layout.js templates/studio/markup.html.ep templates/studio/style.html.ep
# covers:    A Studio panel can be pinned above the others: the title bar carries
#            a pin button for all four panels, the pin is part of the saved
#            panel record and survives a reload, and a pinned panel keeps a z
#            band no raised unpinned panel can cross. Structure only; no pixels.

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
my $markup  = slurp("$root/templates/studio/markup.html.ep");
my $drums   = slurp("$root/templates/studio/drums.html.ep");
my $style   = slurp("$root/templates/studio/style.html.ep");
my $layout  = slurp("$root/public/js/manager/studio/07_layout.js");
my $all     = $markup . $drums;

# --- every panel carries the pin button in its title bar --------------------
for my $panel (qw(transport tracks mixer drums)) {
	like($all, qr/class="studio_panel_pin hover" data-panel="$panel"[^>]*aria-pressed="false"/,
		"$panel has a pin button, unpressed by default");
}
like($all, qr/class="studio_panel_pin hover"[^>]*hint="<%= &subs::ui\('Keep this panel above the others'\) %>"/,
	'the pin button says what a press does');
like($markup, qr/id="studio_transport_panel"[\s\S]*?class="studio_panel_pin hover" data-panel="transport"/,
	'the pin sits inside the transport panel bar');

# --- pin is part of the saved panel record ----------------------------------
like($layout, qr/var studioPanelState = \{\};/, 'panel state is still one record per panel');
like($layout, qr/pinned:\s*!!state\.pinned/, 'the saved panel record carries pinned');
like($layout, qr/state\.pinned = !!saved\.pinned/, 'load reads pinned from a saved record');
like($layout, qr/state\.pinned = !!\(saved && saved\.pinned\)/,
	'a record without geometry still reads pinned, defaulting to false');
like($layout, qr/studio_panel_position_' \+ name/, 'the pin persists in the same saved panel record');

# --- the pin is a toggle with its own handler -------------------------------
like($layout, qr/function studioPanelSetPinned\(name, pinned, persist\)/,
	'the layout exposes studioPanelSetPinned');
like($layout, qr/studioPanelSetPinned\(name, !state\.pinned, true\)/,
	'a press toggles the panel\'s pin');
like($layout, qr/\$\(document\)\.on\('click', '\.studio_panel_pin'/,
	'the pin button has a delegated click handler');
like($layout, qr/\$\(e\.target\)\.closest\('\.studio_panel_pin'\)/,
	'pressing the pin does not raise the panel as a side effect');
like($layout, qr/panel\.toggleClass\('studio_panel_pinned', !!state\.pinned\)/,
	'the pin toggles the panel class');

# --- two z bands keep pinned panels above unpinned ones ---------------------
like($layout, qr/var STUDIO_PINNED_Z = \d+;/, 'there is a named pinned z band');
like($layout, qr/if \(state\.pinned\)\s*\{[\s\S]{0,200}?studioPanelPinnedZ \+= 1;/,
	'a pinned panel takes its top place from the pinned band');
like($layout, qr/function studioPanelAssignZ\(name\)/,
	'one helper places a panel in its band');
like($layout, qr/function studioPanelRaise\(name\)\s*\{[\s\S]*?studioPanelAssignZ\(name\)/,
	'raising goes through the band helper, so it cannot cross a pin');
like($layout, qr/function studioApplyPanelGeometry\(name\)\s*\{[\s\S]*?studioPanelReflectPin\(name\)[\s\S]*?z-index/,
	'applying a panel reflects its pin and its z-index');

my ($arrange) = $layout =~ /(function studioArrangeWindows\(.*?\n\})/s;
ok($arrange, 'the arrange preset is found');
unlike($arrange, qr/pinned\s*=/,
	'arranging windows keeps the pins (a stacking choice, not geometry)');

# --- the stylesheet gives the pin its own look ------------------------------
like($style, qr/\.studio_panel_pin\s*\{/, 'the stylesheet styles the pin button');
like($style, qr/\.studio_panel_pin\[aria-pressed="true"\]\s*\{/, 'a pinned button reads as pressed');

done_testing();
