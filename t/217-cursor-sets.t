# tests-for: lib/JawnOS/Domain/Contrast.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Name.pm lib/JawnOS/Controller/manager_configure.pm perl/gb/01_state_and_defaults.pl perl/gb/02_labels_and_collectives.pl perl/subroutines.pl perl/help/topics_features.pl perl/help/topics_configure.pl templates/configure/misc_setting_list.html.ep templates/layouts/manager.html.ep public/css/chat.css public/css/keyboard.css public/css/manager.css public/css/music.css public/css/soft_keyboard.css public/css/store.css public/css/universal.css public/css/jquery-ui.css public/js/universal/05_theme_ink_icon_swap.js public/js/manager/taskbar/01_inputs.js public/js/manager/leaderboardprinter.js public/js/manager/folders/02_archive_and_keyboard.js public/js/manager/manager/06_appointment_distance.js public/js/music.js public/cursors/build.pl
# covers:    Cursor sets are part of a theme and can be picked from Misc. Every set draws every role, a theme names one, a push moves the body's marker, and the sheets ask for the set through custom properties instead of hard-coded keywords.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);
use RepoSource;
use File::Find qw(find);

my $root = repo_root();

# --- the sets and their art -------------------------------------------------
cmp_ok(scalar(@gb::cursor_sets), '>', 1, 'the house ships more than one cursor set');
for my $set ( @gb::cursor_sets ) {
	ok(defined $gb::cursor_set_labels{$set} && length $gb::cursor_set_labels{$set},
		"$set has a label for the picker");
	ok(-d "$root/public/cursors/sets/$set", "$set has a folder of cursor images");
	my @missing = grep { !-e "$root/public/cursors/sets/$set/$_.png" } @gb::cursor_roles;
	is_deeply(\@missing, [], "$set draws every role the sheet can ask for");
}

my @no_hotspot = grep { !defined $gb::cursor_hotspots{$_} } @gb::cursor_roles;
is_deeply(\@no_hotspot, [], 'every role names its hotspot');

# --- the sizes --------------------------------------------------------------
is_deeply( [ sort { $a <=> $b } @gb::cursor_sizes ], [ 16, 24, 32, 40, 48 ],
	'the slider offers the five sized cuts');
is( &subs::cursor_size(), 32, 'with no choice the pointer is 32px' );
for my $set ( @gb::cursor_sets ) {
	for my $size ( grep { $_ != 32 } @gb::cursor_sizes ) {
		my @missing = grep { !-e "$root/public/cursors/sets/$set/$size/$_.png" }
			qw/default pointer text/;
		is_deeply(\@missing, [], "$set draws its main roles at ${size}px" );
	}
}

# --- a theme carries the set; a bare or unknown name does not ---------------
my $deep = &subs::theme_bundle('deepjawn');
is($deep->{'cursor_set'}, 'bold', 'the Deepjawn preset carries its cursor set');
my $neon = &subs::theme_bundle('neon');
is($neon->{'cursor_set'}, 'neon', 'the Neon preset carries its cursor set');
my $phosphor = &subs::theme_bundle('phosphor');
is($phosphor->{'cursor_set'}, 'contrast', 'the Phosphor preset wears High Contrast');
my $unknown = &subs::theme_bundle('not-a-theme');
is_deeply($unknown, {}, 'an unknown theme resolves to no bundle, so no cursor');

# Each set is a silhouette, not only a paint.
my $read_svg = sub { read_file("$root/public/cursors/sets/$_[0]/$_[1].svg") };
like($read_svg->('white', 'default'), qr/M6 3 L6 26/,
	'White draws the slim needle arrow');
like($read_svg->('mono', 'default'), qr/H11 V9/,
	'Mono draws the pixel staircase');
like($read_svg->('outline', 'pointer'), qr/fill="none"/,
	'Outline draws the hand hollow');
like($read_svg->('neon', 'wait'), qr/A11 11/,
	'Neon waits with a spinner');
like($read_svg->('pastel', 'wait'), qr/<circle/,
	'Pastel waits with four soft dots');
like($read_svg->('contrast', 'default'), qr/M4 3 L4 28/,
	'Contrast draws the oversized block arrow');

# --- the server writes every set's role map once ----------------------------
my $css = &subs::cursor_css();
like($css, qr/body\[data-cursor-set="bold"\]\{/,
	'the CSS names each set on the body marker');
like($css, qr/--jawnos-cursor-default:url\('\/cursors\/sets\/bold\/default\.png'\) 5 5, default/,
	'the default arrow keeps its own hotspot and falls back to the system cursor');
like($css, qr/--jawnos-cursor-pointer:url\('\/cursors\/sets\/neon\/pointer\.png'\) 12 7, pointer/,
	'the hand keeps its tip and falls back to the pointer keyword');
like($css, qr/--jawnos-cursor-not-allowed:url\('\/cursors\/sets\/pastel\/not-allowed\.png'\)/,
	'a refused cursor is part of the set too');
like($css, qr/cursor:var\(--jawnos-cursor-default, auto\)/,
	'the body itself wears the set, so unstyled descendants inherit it');

# a size change points the same set at its numbered folder
{
	no warnings 'redefine';
	local *subs::cursor_size = sub { 24 };
	my $sized = &subs::cursor_css();
	like($sized, qr{url\('/cursors/sets/bold/24/default\.png'\) 5 5, default},
		'a 24px cut is picked when the slider says 24');
	like($sized, qr{body\[data-cursor-set="contrast"\]\{},
		'High Contrast is in the map like every other set');
}

# --- the layout seeds the marker and the mapping ----------------------------
my $layout = read_file("$root/templates/layouts/manager.html.ep");
like($layout, qr/data-cursor-set="<%= &subs::cursor_set\(\) %>"/,
	'the layout writes the active set onto the body');
like($layout, qr/<style id="jawnos_cursor_css"><%== &subs::cursor_css\(\) %>/,
	'and writes every set\'s role map into a block the push can replace');

# --- the sheets ask for the set, not for a hard-coded keyword ---------------
for my $sheet ( qw/chat.css jquery-ui.css keyboard.css manager.css music.css soft_keyboard.css store.css universal.css/ ) {
	my $text = read_file("$root/public/css/$sheet");
	unlike($text, qr/cursor:\s*(?!var\()[a-z-]/,
		"$sheet has no cursor that ignores the set");
}
my $universal = read_file("$root/public/css/universal.css");
like($universal, qr/cursor: var\(--jawnos-cursor-pointer, pointer\)/,
	'a pointer control asks the pointer variable');
like($universal, qr/cursor: var\(--jawnos-cursor-text, text\)/,
	'a text field asks the text variable');
my $music = read_file("$root/public/css/music.css");
like($music, qr/cursor: var\(--jawnos-cursor-ns-resize, ns-resize\)/,
	'the music splitter asks the resize variable');

# Inline styles and the style blocks inside app templates are part of the same
# desk: a hover element built with style="cursor:pointer" would otherwise keep
# the system arrow while the sheets follow the set. `auto` is included on
# purpose: it is what the printer canvases were parked on, and an inline auto
# outranks the body's cursor-set rule just as a literal pointer does.
my $roles = join '|', map { quotemeta($_) } ( @gb::cursor_roles, 'auto' );
my $literal = qr/['"]?cursor['"]?\s*:\s*['"]?($roles)\b/;
my (@inline, @offenders);
find({ no_chdir => 1, wanted => sub {
	push @inline, $File::Find::name if /\.(?:ep|js)$/;
} }, "$root/templates", "$root/public/js/manager", "$root/public/js/universal",
	"$root/public/js/music.js");
for my $file ( @inline ) {
	next unless -f $file;
	my $text = read_file($file);
	push @offenders, $file =~ s{^\Q$root\E/}{}r if $text =~ $literal;
}
is_deeply(\@offenders, [], 'no template or manager script keeps a literal cursor')
	or diag('add var(--jawnos-cursor-<role>, <role>) in: ' . join(', ', @offenders));

# The printer canvases are the desk itself, so a pointer resting on the
# timeline must stay the set's arrow. The hover handler used to park an inline
# `auto` on every .background canvas between items, which is the system cursor
# and outranks the body rule.
my $leaderboard = read_file("$root/public/js/manager/leaderboardprinter.js");
like($leaderboard, qr/var\(--jawnos-cursor-default, default\)/,
	'a printer canvas falls back to the set\'s own arrow');
unlike($leaderboard, qr/\$\(['"]\.background['"]\)\.css\(\{['"]cursor['"]: ['"]auto['"]\}\)/,
	'and never parks the system arrow on a canvas');
my $manager_sheet = read_file("$root/public/css/manager.css");
like($manager_sheet, qr/canvas\.background\s*\{[^}]*cursor:\s*var\(--jawnos-cursor-default, auto\)/s,
	'a background canvas asks the set in CSS as well');

# --- the push moves the marker ---------------------------------------------
my $js = read_file("$root/public/js/universal/05_theme_ink_icon_swap.js");
like($js, qr/function jawnosCursorApply\(set\)/,
	'the desk has one function that sets the cursor marker');
like($js, qr/if \('cursor_set' in bundle\) \{ jawnosCursorApply\(bundle\.cursor_set \|\| ''\); \}/,
	'a theme push applies the cursor set with the rest of the bundle');
like($js, qr/function jawnosCursorCssApply\(css\)/,
	'a size push replaces the cursor style block');
like($js, qr/if \(typeof bundle\.cursor_css === 'string'\)/,
	'the bundle carries the rebuilt block');
like($js, qr/function jawnosCursorInlineGuard\(/,
	'the desk guards against an inline cursor parked at auto');
like($js, qr/new MutationObserver\(guard\)/,
	'the guard watches the body style jQuery UI writes');
my $inputs = read_file("$root/public/js/manager/taskbar/01_inputs.js");
like($inputs, qr/setting == 'cursor_set' \|\| setting == 'cursor_set_override'/,
	'picking a cursor set from Misc applies it at once');

# --- the setting and the theme save route carry it --------------------------
my $name = read_file("$root/lib/JawnOS/Domain/Name.pm");
like($name, qr/\$setting eq 'cursor_set_override' \|\| \$setting eq 'cursor_set' \|\| \$setting eq 'cursor_size'/,
	'a cursor set or size change is one of the settings that pushes the desk');
my $controller = read_file("$root/lib/JawnOS/Controller/manager_configure.pm");
like($controller, qr/my \$cursor_set = \$c->param\('cursor_set'\)/,
	'the theme save route reads the cursor set');
like($controller, qr/cursor_set => \$cursor_set, texture => \$texture/,
	'and writes it into the saved theme');
my $contrast = read_file("$root/lib/JawnOS/Domain/Contrast.pm");
like($contrast, qr/qw\/scheme background icon_set cursor_set texture font corner accent name\//,
	'a running appointment theme overlays its cursor with the rest of the dressing');
like($contrast, qr/\( \$bg, &icon_set\(\), &cursor_set\(\), &cursor_size\(\), &texture_name\(\)/,
	'the signature carries the cursor, so the push is not filtered as unchanged');
like($contrast, qr/cursor_set => \$cursor_set,/,
	'the websocket bundle sends the effective cursor');
like($contrast, qr/&cursor_set\(\), &cursor_size\(\), &texture_name\(\)/,
	'the signature carries the size, so a size move is not filtered as unchanged');
like($contrast, qr/cursor_css => \$cursor_css,/,
	'the push carries the rebuilt size map');

# --- the panel offers it, and the theme editor saves it --------------------
my $tpl = read_file("$root/templates/configure/misc_setting_list.html.ep");
like($tpl, qr/setting="<%= \$active_theme \? 'cursor_set_override' : 'cursor_set' %>"/,
	'Misc reads the override while a theme is active and the plain setting otherwise');
like($tpl, qr/<select id="theme_cursor_set">/,
	'the theme editor has a cursor picker');
like($tpl, qr/cursor_set: \$\('#theme_cursor_set'\)\.val\(\)/,
	'and the save request sends the chosen set');
like($tpl, qr/jawnosPreviewCursors\(/,
	'the picker shows the art it is choosing');
like($tpl, qr/setting="cursor_size" device="<%= \$dev %>" min="16" max="48" step="8"/,
	'the size slider has its five stops');
like($tpl, qr/jawnosCursorPreviewUrl\(/,
	'the preview reads the chosen size');
like($tpl, qr/id="cursor_size_value_/, 'the slider carries a readout');

my $help = read_file("$root/perl/help/topics_features.pl");
like($help, qr/\$topic\{'cursor_sets'\}/, 'the Guide explains cursor sets');
like($help, qr/High Contrast/, 'the Guide names the high-contrast set');
like($help, qr/Cursor Size/, 'the Guide names the size slider');

done_testing();
