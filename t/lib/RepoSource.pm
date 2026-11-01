package RepoSource;

# The app used to be one file. A source-grep test that read Manager.pl has to
# read everything Manager.pl became, or it stops seeing the code it pins:
#
#   Manager.pl                 the launcher (config-free, ~25 lines)
#   lib/JawnOS.pm              the application class (startup)
#   lib/JawnOS/Manager.pm      package Manager: config, state, helpers, hooks
#   lib/JawnOS/Routes.pm       the route table
#   lib/JawnOS/Routes/*.pm     one manifest per route group
#   lib/JawnOS/Controller/*.pm package Manager: the route actions
#
# The domain layer (lib/JawnOS/Domain, package subs) is still the split of
# subroutines.pl, so it is NOT included here: a test that used to read
# subroutines.pl reads that file plus the Domain modules on its own.
#
# Exports: repo_root()       the checkout root, absolute
#          manager_source()  those six groups, concatenated

use strict;
use warnings;
use Exporter 'import';
use Cwd       qw(abs_path);
use File::Basename qw(dirname);

our @EXPORT_OK = qw(repo_root manager_source);
our @EXPORT    = qw(repo_root manager_source);

sub repo_root { abs_path(dirname(__FILE__) . '/../..') }

sub manager_source {
	my $root  = repo_root();
	my @files = (
		"$root/Manager.pl",
		"$root/lib/JawnOS.pm",
		"$root/lib/JawnOS/Manager.pm",
		"$root/lib/JawnOS/Routes.pm",
		sort(glob("$root/lib/JawnOS/Routes/*.pm")),
		sort(glob("$root/lib/JawnOS/Controller/*.pm")),
		sort(glob("$root/lib/JawnOS/Manager/*.pm")),
	);
	my $text = '';
	for my $file (@files) {
		open(my $fh, '<', $file) or die "$file: $!";
		local $/;
		$text .= <$fh> . "\n";
	}
	return $text;
}

1;
