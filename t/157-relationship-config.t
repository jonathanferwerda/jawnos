# tests-for: lib/JawnOS/Domain/Headless.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Accounting.pm lib/JawnOS/Controller/manager_configure4.pm perl/gb/01_state_and_defaults.pl perl/gb/02_labels_and_collectives.pl templates/apps/people_person.html.ep templates/apps/people/body.html.ep templates/configure/appointment_list.html.ep public/js/manager/people/01_crest_tabs.js public/js/manager/configure.js
# covers:    Relationship is a configuration (self/friend/stranger/enemy), not an app measure.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;
use JawnOSTest;

sub slurp {
	my $file = shift;
	open(my $fh, '<', $file) or die "$file: $!\n";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text // '';
}

# ---------------------------------------------------------------- the words
is &subs::relationship_value('self'), 'self', 'self is a relationship of its own, not friend';
is &subs::relationship_value('friend'), 'friend', 'friend reads back';
is &subs::relationship_value('enemy'), 'enemy', 'enemy reads back';
is &subs::relationship_normalize(''), 'stranger', 'an unset relationship defaults to stranger';
is &subs::relationship_normalize('bogus'), 'stranger', 'an unknown relationship defaults to stranger';
is &subs::relationship_normalize('self, enemy'), 'enemy', 'the most negative word wins in a list';
is &subs::relationship_normalize('self, friend'), 'self', 'self survives alongside friend';
is &subs::relationship_rank('self'), 1, 'self sits at the safest rank';
is &subs::relationship_rank('friend'), 1, 'friend sits at the safest rank';
is &subs::relationship_rank('stranger'), 2, 'stranger sits in the middle';
is &subs::relationship_rank('enemy'), 3, 'enemy sits at the dangerous rank';

my $options = &subs::relationship_options();
is_deeply [ map { $_->{'value'} } @{$options} ],
	[ qw(self friend stranger enemy) ], 'the options are self, friend, stranger, enemy';
like $options->[0]->{'label'}, qr/self/i, 'the self option is labelled';
is $options->[0]->{'rating'}, 1, 'the self option carries the safest rating';

# ---------------------------------------------------------------- the wiring
my $gb1 = slurp(root() . '/perl/gb/01_state_and_defaults.pl');
like $gb1, qr/\$relationship_types/, 'the relationship enum is declared once';
like $gb1, qr/'self'/, 'the enum includes self';

my $gb2 = slurp(root() . '/perl/gb/02_labels_and_collectives.pl');
unlike $gb2, qr/'relationship'\s*=>/, 'relationship is no longer declared as an app measure';

my $loader = slurp(root() . '/lib/JawnOS/Domain/Loader.pm');
like $loader, qr/relationship_normalize/, 'the new relationship helpers are in the loader map';
like $loader, qr/relationship_label/, 'the label helper is in the loader map';

my $accounting = slurp(root() . '/lib/JawnOS/Domain/Accounting.pm');
like $accounting, qr/relationship_setting_v1/, 'the old measure has a direct-setting migration';

my $people = slurp(root() . '/templates/apps/people_person.html.ep');
like $people, qr/people_relationship_select/, 'the person card still carries the relationship select';
unlike $people, qr/>Not set</, 'an unset relationship is shown as stranger, not as a blank';
like $people, qr/relationship_options/, 'the card reads the one options list';

my $configure = slurp(root() . '/templates/configure/appointment_list.html.ep');
like $configure, qr/configure_relationship/, 'the Configure person card has the relationship select';
like $configure, qr/setting="relationship"/, 'it saves the direct relationship setting';

# One configuration for the phone. The abilities grid used to offer both the
# singular phone row and the phones list; the singular one now folds into the
# list, which shows the main line as its first row. Both settings still read
# and write, so no row is lost.
like $configure, qr/next if \$b eq 'phone' && \$abilities->\{'phones'\}/,
	'the singular phone ability is not offered beside the phones list';
like $configure, qr/contact_row_primary/, 'the phones list shows the main line as a row of its own';
like $configure, qr/setting="phone"/, 'the main line still writes the phone setting';
like $configure, qr/&subs::ui\('Main line'\)/, 'the row is named for the person reading it';
like $configure, qr/&subs::ui\('Calls and texts route here'\)/, 'and says what the main line is for';

my $people_js = slurp(root() . '/public/js/manager/people/01_crest_tabs.js');
like $people_js, qr{url:\s*'/manager/configure'}, 'the People card saves through the configuration route';
like $people_js, qr/setting:\s*'relationship'/, 'the People card saves the relationship setting';
unlike $people_js, qr{measure:\s*'relationship'}, 'the People card no longer writes the measure';

my $configure_js = slurp(root() . '/public/js/manager/configure.js');
like $configure_js, qr/configure_relationship/, 'the Configure panel handles the relationship select';

done_testing();
