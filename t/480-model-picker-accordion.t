# tests-for: public/js/manager/model_picker.js public/css/manager.css templates/apps/search.html.ep templates/apps/help.html.ep templates/configure/plat_setting_list.html.ep templates/mail/pen_sections.html.ep lib/JawnOS/Manager/Core1_tables_hooks.pm perl/help/topics_functions.pl perl/help/topics_features.pl
# covers: the model pickers open as a provider accordion, each provider a
#         section listing its models, and every chooser wears the marker.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $js   = read_file("$root/public/js/manager/model_picker.js");
my $css  = read_file("$root/public/css/manager.css");

like($js, qr/jawnos_model_select/, 'the picker enhances the marked selects');
like($js, qr/OPTGROUP/, 'it reads the provider optgroups');
like($js, qr/model_picker_group/, 'each provider is an accordion section');
like($js, qr/model_picker_group_head/, 'with a heading that opens it');
like($js, qr/model_picker_item/, 'and each model a row');
like($js, qr/dispatchEvent\(new Event\('change'/, 'a choice fires change so the savers run');
like($js, qr/MutationObserver/, 'newly drawn windows are enhanced too');
like($js, qr/scrollIntoView/, 'the chosen model is brought into view');
like($js, qr/aria-expanded/, 'the accordion reports its state');

my $core = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");
like($core, qr{/js/manager/model_picker\.js}, 'the picker rides the core bundle');

like($css, qr/\.model_picker_panel/, 'the panel has its own styles');
like($css, qr/\.model_picker_group\.open/, 'the accordion opens a provider');
like($css, qr/\.model_picker_item\.selected/, 'and marks the chosen model');
like($css, qr/\.model_picker_native/, 'the native select steps out of the way');

for my $pair (
	[ 'templates/apps/search.html.ep', 'the Search AI picker' ],
	[ 'templates/apps/help.html.ep', 'the Guide picker' ],
	[ 'templates/configure/plat_setting_list.html.ep', 'the Plat role and fallback pickers' ],
	[ 'templates/mail/pen_sections.html.ep', 'the Pen picker' ],
) {
	my ($file, $what) = @{$pair};
	my $tpl = read_file("$root/$file");
	like($tpl, qr/jawnos_model_select/, "$what is enhanced");
}

my $plat_help = read_file("$root/perl/help/topics_functions.pl");
like($plat_help, qr/accordion|a heading you open|open to see its models/i,
	'the Plat topic describes the provider accordion');
my $search_help = read_file("$root/perl/help/topics_features.pl");
like($search_help, qr/provider headings|grouped by provider|open a provider/i,
	'the Search topic describes the provider groups');

done_testing();
