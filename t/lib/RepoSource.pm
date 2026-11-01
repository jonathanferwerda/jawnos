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

our @EXPORT_OK = qw(repo_root manager_source template_source);
our @EXPORT    = qw(repo_root manager_source template_source);

sub repo_root { abs_path(dirname(__FILE__) . '/../..') }

sub manager_source {
	my $root  = repo_root();
	my @files = (
		"$root/perl/Manager.pl",
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

# A big page is composed from partials now: templates/apps/video.html.ep holds
# the locals and includes templates/apps/video/*.html.ep. A source-grep test that
# pins a page's markup reads the page AND its fragments, the way it spreads over
# the pieces of a split .pl. Give it the path without the extension.
sub template_source {
	my $rel  = shift;
	$rel =~ s/\.html\.ep$//;
	my $root  = repo_root();
	my $page  = "$root/templates/$rel.html.ep";
	my @files = (-f $page ? ($page) : ());
	push @files, sort grep { -f } glob("$root/templates/$rel/*.html.ep");
	my $text = '';
	for my $file (@files) {
		open(my $fh, '<', $file) or die "$file: $!";
		local $/;
		$text .= <$fh> . "\n";
	}
	return $text;
}

1;
