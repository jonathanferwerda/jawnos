# tests-for: t/ scripts/
# covers:    every tracked source file is claimed by a test, or is named debt

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# A file nobody tests is a file that can change without a red suite: the mapper
# selects the full suite for it (so nothing is missed at push time) but no test
# ever asserts anything about it, which is the same as not testing it at all.
#
# This enumerates the gap instead of leaving it implicit. A new source file that
# no test claims fails here, and the fix is one line either way: claim it in the
# test that covers it, or delete the file. The list below is debt, not policy.

my $root = abs_path("$FindBin::Bin/..");

sub git_paths {
	my @args = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, 'git', '-C', $root, 'ls-files', '-z', @args);
	close $in;
	local $/;
	my $raw = <$out> // '';
	close $out;
	close $err;
	waitpid($pid, 0);
	return grep { length } split /\0/, $raw;
}

sub untested {
	my @files = @_;
	return () unless @files;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err,
		$^X, "$root/scripts/tests_for.pl", '--json', '--files', @files);
	close $in;
	local $/;
	my $json = <$out> // '';
	close $out;
	close $err;
	waitpid($pid, 0);

	my ($list) = $json =~ /"unmapped":\[([^]]*)\]/;
	return () unless defined $list && length $list;
	my @out;
	# The array holds JSON strings; a path is the element between the delimiters.
	for my $part (split /","/, $list) {
		($part = $part) =~ s/^"//;
		$part =~ s/"$//;
		push @out, $part if length $part;
	}
	return @out;
}

# Vendored code and tooling that is not Perl or JavaScript: nothing of ours to
# assert, and a test here would only pin somebody else's library.
my @no_behaviour = (
	qr{^public/js/(?:jquery-ui|jquery\.ui\.touch-punch|moment|numeral)},
	qr{^scripts/gallery/},
	qr{\.(?:sh|py|mjs|json)$},
);

# Our own code that no test claims yet. Remove a name when its test lands; this
# list may shrink, and a name that is no longer untested is reported as stale.
my %owed = map { $_ => 1 } qw(
	public/js/gate.js
	public/js/pm.js
	public/js/screensaver.js
	scripts/app_displayer.pl
	scripts/app_ticket.pl
	scripts/black_images.pl
	scripts/deploy_neighbours.pl
	scripts/factory_seed.pl
	scripts/help_audit.pl
	scripts/home_plate_self_migrate.pl
	scripts/internet_appointments_repair.pl
	scripts/jawnos_network.pl
	scripts/keyboard_shortcuts.pl
	scripts/mkosi_build.pl
	scripts/mkosi_publish.pl
	scripts/paper_share_qr.pl
	scripts/pph_compare.pl
	scripts/sponsors_goal.pl
	scripts/store_invoice_email_driver.pl
	scripts/thumb_reorient.pl
	scripts/tls_issue.pl
	scripts/web_measures_audit.pl
);

my @source = git_paths(qw(lib perl templates public/js scripts));
ok(scalar(@source) > 500, 'the tracked source tree was read (' . scalar(@source) . ' files)');

my @unclaimed = untested(@source);
ok(scalar(@unclaimed) > 0, 'the mapper reports the files no test claims');

my (@ignored, @debt, @new);
for my $path (@unclaimed) {
	if (grep { $path =~ $_ } @no_behaviour) { push @ignored, $path; next }
	if ($owed{$path})                      { push @debt,    $path; next }
	push @new, $path;
}

is_deeply(\@new, [], 'every source file is claimed by a test, or named as debt')
	or diag("no test claims these and they are not in %owed:\n  " . join("\n  ", @new)
		. "\nadd a `tests-for:` line to the test that covers the file, or delete it");

my %is_unclaimed = map { $_ => 1 } @unclaimed;
my @stale = sort grep { !$is_unclaimed{$_} } keys %owed;
note(scalar(@stale) . ' debt entr(y/ies) now have a test - prune %owed: ' . join(', ', @stale))
	if @stale;

my @gone = sort grep { !-e "$root/$_" } keys %owed;
is_deeply(\@gone, [], 'every debt entry is still a file') or diag("@gone");

done_testing();
