# tests-for: public/css/manager.css public/js/manager/inventory.js public/js/manager/inventory/ templates/apps/inventory.html.ep
# covers:    The inventory panel paints the share wheel and the budget-status cells from one pair of palettes, defined in m...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root template_source js_source);

# The inventory panel paints the share wheel and the budget-status cells from
# one pair of palettes, defined in manager.css: one for the light theme and one
# for body.dark_theme. The sets must stay complete (eight hues), distinguishable
# within themselves, differ by lightness as well as hue, and never be the same
# colours as each other. The wheel reads them back from the panel, so a theme
# change repaints the slices and the rows together.

my $root = repo_root();
my $css = read_file("$root/public/css/manager.css");

my ($light) = $css =~ /^\.inventory_details \{(.*?)^\}/ms;
my ($dark)  = $css =~ /^body\.dark_theme \.inventory_details \{(.*?)^\}/ms;
ok(defined $light, 'the light palette is on the inventory panel');
ok(defined $dark, 'the dark palette is on the inventory panel under body.dark_theme');
unlike($light || '', qr/dark_theme/, 'the first block is the light one, not the dark selector');

sub palette_of {
	my $block = shift || '';
	my %colors;
	while ($block =~ /--inv-color-(\d+)\s*:\s*(#[0-9a-fA-F]{6})\s*;/g) {
		$colors{$1 + 0} = lc $2;
	}
	return \%colors;
}

sub luminance {
	my $hex = shift;
	my @rgb = map { hex } ($hex =~ /^#(..)(..)(..)$/);
	my @lin = map {
		my $v = $_ / 255;
		$v <= 0.03928 ? $v / 12.92 : (($v + 0.055) / 1.055) ** 2.4;
	} @rgb;
	return 0.2126 * $lin[0] + 0.7152 * $lin[1] + 0.0722 * $lin[2];
}

my $light_palette = palette_of($light);
my $dark_palette = palette_of($dark);

for my $mode ( [ 'light', $light_palette ], [ 'dark', $dark_palette ] ) {
	my ($name, $palette) = @{$mode};
	is_deeply([ sort { $a <=> $b } keys %{$palette} ], [ 1 .. 8 ], "$name: the palette has eight hues");
	my %seen;
	$seen{$_}++ for values %{$palette};
	is(scalar keys %seen, 8, "$name: no two slices share a colour");
	my %levels;
	$levels{sprintf('%.2f', luminance($_))}++ for values %{$palette};
	cmp_ok(scalar keys %levels, '>=', 4, "$name: the hues differ by lightness as well as hue");
}

my %shared = map { $_ => 1 } grep { $dark_palette->{$_} } values %{$light_palette};
is(scalar keys %shared, 0, 'dark mode does not reuse a light colour');

for my $block ( [ 'light', $light ], [ 'dark', $dark ] ) {
	my ($name, $source) = @{$block};
	like($source, qr/--inv-ink\s*:\s*#[0-9a-fA-F]{6}/, "$name: the legend ink is defined");
	like($source, qr/--inv-slice-edge\s*:\s*#[0-9a-fA-F]{6}/, "$name: the slice edge is defined");
	like($source, qr/--inv-quiet-ink\s*:\s*#[0-9a-fA-F]{6}/, "$name: the empty-wheel ink is defined");
	for my $status (qw(budgeted accomplished burnt_out overkill achievable neglected abandoned)) {
		my ($bg) = $source =~ /--inv-\Q$status\E-bg\s*:\s*(#[0-9a-fA-F]{6})/;
		my ($ink) = $source =~ /--inv-\Q$status\E-ink\s*:\s*(#[0-9a-fA-F]{6})/;
		ok($bg, "$name: $status has a fill");
		ok($ink, "$name: $status has an ink");
		isnt($bg, $ink, "$name: ${status} ink differs from its fill") if $bg && $ink;
	}
}

like($css, qr/\.inventory_details \.statistic_entry\.inv_status_burnt_out\s*\{/, 'a status class paints the cell, not an inline colour');
like($css, qr/var\(--inv-budgeted-bg\)/, 'a status class reads the palette');

my $js = js_source('public/js/manager/inventory.js');
like($js, qr/--inv-color-/, 'the wheel reads its hues from the panel');
like($js, qr/--inv-ink/, 'the wheel reads its legend ink from the panel');
like($js, qr/--inv-slice-edge/, 'the wheel reads its slice edge from the panel');
like($js, qr/inventoryAllocationScope/, 'the wheel looks up the share of the selected scope');
like($js, qr/inventoryShares/, 'the older clocks still round their shares to a whole 100');

my $tpl = template_source('apps/inventory.html.ep');
like($tpl, qr/inv_status_/, 'a cell wears its budget status as a class');
like($tpl, qr/data-empty="No time recorded"/, 'the empty wheel has a state of its own');
like($tpl, qr/value="scope"/, 'the wheel offers the selected scope as its reading');
unlike($tpl, qr/value="period"/, 'the old page-of-periods share is gone');

done_testing();
