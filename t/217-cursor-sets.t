# tests-for: lib/JawnOS/Domain/Contrast.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Name.pm lib/JawnOS/Controller/manager_configure.pm perl/gb/01_state_and_defaults.pl perl/gb/02_labels_and_collectives.pl perl/subroutines.pl perl/help/topics_features.pl perl/help/topics_configure.pl templates/configure/misc_setting_list.html.ep templates/layouts/manager.html.ep public/css/chat.css public/css/keyboard.css public/css/manager.css public/css/music.css public/css/soft_keyboard.css public/css/store.css public/css/universal.css public/js/universal/05_theme_ink_icon_swap.js public/js/manager/taskbar/01_inputs.js public/cursors/build.pl
# covers:    Cursor sets are part of a theme and can be picked from Misc. Every set draws every role, a theme names one, a push moves the body's marker, and the sheets ask for the set through custom properties instead of hard-coded keywords.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);
use RepoSource;

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

# --- a theme carries the set; a bare or unknown name does not ---------------
my $deep = &subs::theme_bundle('deepjawn');
is($deep->{'cursor_set'}, 'bold', 'the Deepjawn preset carries its cursor set');
my $neon = &subs::theme_bundle('neon');
is($neon->{'cursor_set'}, 'neon', 'the Neon preset carries its cursor set');
my $unknown = &subs::theme_bundle('not-a-theme');
is_deeply($unknown, {}, 'an unknown theme resolves to no bundle, so no cursor');

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

# --- the layout seeds the marker and the mapping ----------------------------
my $layout = read_file("$root/templates/layouts/manager.html.ep");
like($layout, qr/data-cursor-set="<%= &subs::cursor_set\(\) %>"/,
	'the layout writes the active set onto the body');
like($layout, qr/<%== &subs::cursor_css\(\) %>/,
	'and writes every set\'s role map into the page');

# --- the sheets ask for the set, not for a hard-coded keyword ---------------
for my $sheet ( qw/chat.css keyboard.css manager.css music.css soft_keyboard.css store.css universal.css/ ) {
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

# --- the push moves the marker ---------------------------------------------
my $js = read_file("$root/public/js/universal/05_theme_ink_icon_swap.js");
like($js, qr/function jawnosCursorApply\(set\)/,
	'the desk has one function that sets the cursor marker');
like($js, qr/if \('cursor_set' in bundle\) \{ jawnosCursorApply\(bundle\.cursor_set \|\| ''\); \}/,
	'a theme push applies the cursor set with the rest of the bundle');
my $inputs = read_file("$root/public/js/manager/taskbar/01_inputs.js");
like($inputs, qr/setting == 'cursor_set' \|\| setting == 'cursor_set_override'/,
	'picking a cursor set from Misc applies it at once');

# --- the setting and the theme save route carry it --------------------------
my $name = read_file("$root/lib/JawnOS/Domain/Name.pm");
like($name, qr/\$setting eq 'cursor_set_override' \|\| \$setting eq 'cursor_set'/,
	'a cursor change is one of the settings that pushes the desk');
my $controller = read_file("$root/lib/JawnOS/Controller/manager_configure.pm");
like($controller, qr/my \$cursor_set = \$c->param\('cursor_set'\)/,
	'the theme save route reads the cursor set');
like($controller, qr/cursor_set => \$cursor_set, texture => \$texture/,
	'and writes it into the saved theme');
my $contrast = read_file("$root/lib/JawnOS/Domain/Contrast.pm");
like($contrast, qr/qw\/scheme background icon_set cursor_set texture font corner accent name\//,
	'a running appointment theme overlays its cursor with the rest of the dressing');
like($contrast, qr/\( \$bg, &icon_set\(\), &cursor_set\(\), &texture_name\(\)/,
	'the signature carries the cursor, so the push is not filtered as unchanged');
like($contrast, qr/cursor_set => \$cursor_set,/,
	'the websocket bundle sends the effective cursor');

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

my $help = read_file("$root/perl/help/topics_features.pl");
like($help, qr/\$topic\{'cursor_sets'\}/, 'the Guide explains cursor sets');

done_testing();
