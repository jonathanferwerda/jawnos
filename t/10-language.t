use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

# The core interface catalog (language.pl). AGENTS.md: English plus fifteen
# interface languages, and every core label exists in all sixteen. Missing keys
# are backfilled from English at load, so this suite checks the contract a page
# relies on - every key resolves in every language, and placeholders survive.

my @languages = @language::languages;
my @codes     = map { $_->{code} } @languages;
my %code      = map { $_ => 1 } @codes;
my $catalog   = \%language::catalog;

is(scalar(@languages), 16, 'the app offers sixteen interface languages');
is($language::DEFAULT, 'en', 'English is the default');
is($languages[0]{code}, 'en', 'English is listed first');
my %seen;
is(scalar(grep { $seen{$_}++ } @codes), 0, 'language codes are unique');

is_deeply([ sort keys %$catalog ], [ sort @codes ],
	'every listed language has a catalog and there are no stray catalogs');

my @en = sort keys %{ $catalog->{en} };
cmp_ok(scalar(@en), '>', 300, 'the English catalog is populated');

# Every English key resolves to a non-empty string in every language.
my @missing;
for my $lang (@codes) {
	for my $key (@en) {
		my $value = $catalog->{$lang}{$key};
		push @missing, "$lang/$key" unless defined $value && length $value;
	}
}
is_deeply(\@missing, [], 'every language has a value for every English key');

# A value is never left as the bare key.
my @bare;
for my $lang (@codes) {
	for my $key (@en) {
		push @bare, "$lang/$key" if $catalog->{$lang}{$key} eq $key;
	}
}
is_deeply(\@bare, [], 'no label falls back to printing its key');

# A translated string that dropped {0} would render "Welcome to !".
my @placeholder;
for my $key (@en) {
	my @want = $catalog->{en}{$key} =~ /\{(\d+)\}/g or next;
	@want = sort @want;
	for my $lang (@codes) {
		my @got = sort(($catalog->{$lang}{$key} // '') =~ /\{(\d+)\}/g);
		push @placeholder, "$lang/$key"
			unless join(',', @want) eq join(',', @got);
	}
}
is_deeply(\@placeholder, [], 'every translation keeps the English placeholders');

# translate() folds in the English fallback and substitutes args.
is(language::translate('en', 'home.welcome', 'JawnOS'),
	'Welcome to JawnOS!', 'translate substitutes arguments');
is(language::translate('xx', 'home.welcome', 'JawnOS'),
	'Welcome to JawnOS!', 'an unknown language reads as English');
is(language::translate('en', 'no.such.key'),
	'no.such.key', 'a missing key reads as itself');
{
	my $want = $catalog->{fr}{'home.welcome'};
	$want =~ s/\{0\}/JawnOS/g;
	is(language::translate('fr', 'home.welcome', 'JawnOS'), $want,
		'translate substitutes into the chosen language');
}

# ---- language metadata -----------------------------------------------------
is(language::valid('fr'),    'fr', 'a known code is valid');
is(language::valid('xx'),    'en', 'an unknown code falls back to English');
is(language::valid(undef),   'en', 'an undefined code falls back to English');
is(language::dir_for('ar'),  'rtl', 'Arabic reads right to left');
is(language::dir_for('fr'),  'ltr', 'French reads left to right');
is(language::label('fr'),    'Français', 'a language is named in its own words');
is(language::label('zh'),    '中文', 'a non-Latin language is named in its own script');

# ---- what a page hands to its scripts --------------------------------------
my $js = language::for_javascript('fr');
is(ref $js, 'HASH', 'the JavaScript catalog is a hash');
my @js_missing = grep { !defined $js->{$_} } @en;
is_deeply(\@js_missing, [], 'the JavaScript catalog carries every English key');
cmp_ok(scalar(keys %$js), '>=', scalar(@en), 'the JavaScript catalog is not truncated');

done_testing();
