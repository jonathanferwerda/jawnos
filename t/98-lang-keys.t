# tests-for: perl/language.pl perl/language/*.pl
# covers:    every literal subs::lang() key a page asks for resolves to a label

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Find qw(find);
use Test::More;
use JawnOSTest;

# A label is a catalog key. When the key is not in language.pl, translate()
# falls back to the key itself, so a page prints "keyboard" or
# "power_screen_off" where a word belongs. The start menu's keyboard icon was
# exactly that. This walks every page, template and domain call site and checks
# the literal keys. Dynamic keys (constructed from a code) are not visible here;
# the power actions, which the app builds as 'power_' . $action, are checked
# below because that template has no fallback.

my $root = root();
my @missing;
my $uses = 0;

find(
	{
		no_chdir => 1,
		wanted   => sub {
			my $path = $File::Find::name;
			if (-d $path) {
				$File::Find::prune = 1 if $path =~ m{/(?:\.git|\.worktrees|\.pio|build|language)\z};
				return;
			}
			return unless $path =~ /\.(?:pl|pm|ep)\z/;
			open(my $fh, '<:encoding(UTF-8)', $path) or return;
			my $line = 0;
			while (<$fh>) {
				$line++;
				while (/(?<![\w:])&?(?:subs::)?lang\(\s*(['"])([^'"]+)\1\s*[,)]/g) {
					my $key = $2;
					# An interpolated or concatenated argument is not a key yet.
					next if $key =~ /[\$\@\{\}]/;
					$uses++;
					next if exists $language::catalog{'en'}->{$key};
					(my $rel = $path) =~ s{^\Q$root\E/+}{};
					push @missing, "$rel:$line $key";
				}
			}
			close $fh;
		},
	},
	map { "$root/$_" } qw(templates lib perl)
);

is_deeply(\@missing, [], 'every literal subs::lang key has an English catalog entry');
cmp_ok($uses, '>', 300, 'the scan sees the pages and templates that draw labels');

# templates/apps/power.html.ep labels each system power button with
# lang('power_' . $action), and power_actions() can offer these five.
my @power_missing = grep { !length($language::catalog{'en'}->{$_} // '') }
	map { "power_$_" } qw(restart shutdown sleep screen_off logout);
is_deeply(\@power_missing, [], 'every power action button has a label');

done_testing();
