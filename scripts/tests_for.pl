#!/usr/bin/perl

# Pick the tests that cover a change, so iteration does not pay for the whole
# suite. The pre-push hook still runs every test in parallel: this is a
# shortcut, and it fails safe - a changed path no test claims selects the full
# suite rather than nothing.
#
#   perl scripts/tests_for.pl                   working tree vs HEAD (and new files)
#   perl scripts/tests_for.pl --staged          what is staged
#   perl scripts/tests_for.pl --range A..B      a commit range
#   perl scripts/tests_for.pl --files a b       explicit paths
#   perl scripts/tests_for.pl --run             run the selection (parallel)
#   perl scripts/tests_for.pl --all             every test
#   perl scripts/tests_for.pl --list-for PATH   tests that claim PATH
#   perl scripts/tests_for.pl --json            machine-readable
#   perl scripts/tests_for.pl --strict          exit 2 instead of running everything
#
# Each t/*.t declares its surface in a header, within the first 40 lines:
#
#   # tests-for: perl/subroutines.pl lib/JawnOS/Domain/*.pm
#   # covers:    name formatting and path safety
#
# A path is claimed when a `tests-for:` glob matches it, or when the test body
# spells the path out (a source-grep test usually does). Globs: `*` within one
# path segment, `**` across segments, `?` one character, a trailing `/` means
# everything under that directory.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin ();
use Getopt::Long qw(GetOptions);

my $root = abs_path("$FindBin::Bin/..");

my ($staged, $range, $all, $run, $json, $strict, $list_for, $files_flag);
GetOptions(
	'staged'     => \$staged,
	'range=s'    => \$range,
	'all'        => \$all,
	'run'        => \$run,
	'json'       => \$json,
	'strict'     => \$strict,
	'list-for=s' => \$list_for,
	'files'      => \$files_flag,
	'help|h'     => sub { usage(); exit 0 },
) or do { usage(); exit 2 };

# Leftover arguments are paths, so `tests_for.pl lib/Foo.pm` works.
my @given = @ARGV;

# --- what the tests claim ----------------------------------------------------

my $HEADER_LINES = 40;

my %globs;    # t/foo.t => [ 'lib/…', … ]
my %covers;   # t/foo.t => human phrase
my %body;     # t/foo.t => whole file, for the mention tier
my %glob_re;

sub rel {
	my $path = shift;
	$path =~ s{^\Q$root\E/+}{};
	return $path;
}

sub read_headers {
	my @tests = sort glob("$root/t/*.t");
	for my $file (@tests) {
		my $rel = rel($file);
		open(my $fh, '<', $file) or next;
		my $text = do { local $/; <$fh> };
		close $fh;
		$body{$rel} = $text;

		my @lines = split /\n/, $text;
		my $last  = @lines > $HEADER_LINES ? $HEADER_LINES - 1 : $#lines;
		for my $line (@lines[0 .. $last]) {
			if ($line =~ /^#\s*tests-for:\s*(.*?)\s*$/) {
				push @{ $globs{$rel} }, split ' ', $1;
			}
			elsif ($line =~ /^#\s*covers:\s*(.*?)\s*$/) {
				$covers{$rel} = $1;
			}
		}
	}
}
read_headers();

sub glob_to_re {
	my $glob = shift;
	$glob =~ s{^\./}{};
	my $prefix = $glob =~ s{/$}{} ? 1 : 0;
	my $re = quotemeta $glob;
	$re =~ s/\\\*\\\*/.*/g;
	$re =~ s/\\\*/[^\/]*/g;
	$re =~ s/\\\?/[^\/]/g;
	$re .= '(?:/.*)?' if $prefix;
	return qr/^$re$/;
}

# Tests that claim a single repo-relative path, best match first.
sub tests_for_path {
	my $path = shift;
	my @hit;
	for my $test (sort keys %globs) {
		my $claimed = 0;
		for my $glob (@{ $globs{$test} }) {
			my $re = $glob_re{$glob} ||= glob_to_re($glob);
			if ($path =~ $re) { $claimed = 1; last }
		}
		$claimed = 1 if !$claimed && index($body{$test}, $path) >= 0;
		push @hit, $test if $claimed;
	}
	return @hit;
}

# --- the change --------------------------------------------------------------

sub git_lines {
	my @cmd = @_;
	open(my $fh, '-|', 'git', '-C', $root, @cmd) or return ();
	my @out = map { chomp; $_ } grep { /\S/ } <$fh>;
	close $fh;
	return @out;
}

my @changed;
if ($list_for) {
	my @hit = tests_for_path(rel($list_for));
	if ($json) {
		print "{\"path\":\"$list_for\",\"tests\":[" .
			join(',', map { qq{"$_"} } @hit) . "]}\n";
	}
	else {
		printf "%-32s %s\n", $_, ($covers{$_} || '') for @hit;
	}
	exit(@hit ? 0 : 1);
}
elsif (@given) {
	@changed = map { rel($_) } @given;
}
elsif ($range) {
	@changed = git_lines('diff', '--name-only', '--no-renames', $range);
}
elsif ($staged) {
	@changed = git_lines('diff', '--name-only', '--cached', '--no-renames');
}
elsif (!$all) {
	@changed = (
		git_lines('diff', '--name-only', '--no-renames', 'HEAD'),
		git_lines('ls-files', '--others', '--exclude-standard'),
	);
}

my %seen;
@changed = grep { length && !$seen{$_}++ } @changed;

my @every = sort keys %globs;

# --- map the change ----------------------------------------------------------

# A change under t/lib is in every test's process; no header can scope it.
sub forces_full_suite {
	my $path = shift;
	return 1 if $path =~ m{^t/lib/};
	return 0;
}

# Nothing a test can observe. Kept short and explicit so a new directory is
# unmapped (and therefore safe) rather than silently ignored.
my @NOT_TESTED = (
	qr{^docs/},
	qr{^\.shots/},
	qr{^releases/},
	qr{^server/},
	qr{\.md$},
	qr{^LICENSE$},
	qr{^\.gitignore$},
	qr{^\.gitattributes$},
	qr{^config\.json$},
);

sub not_tested {
	my $path = shift;
	for my $re (@NOT_TESTED) {
		return 1 if $path =~ $re;
	}
	return 0;
}

my (%selected, %path_tests, @unmapped, @ignored);
for my $path (@changed) {
	if ($path =~ m{^t/([^/]+\.t)$}) {
		# a test's own edit selects that test
		$selected{"t/$1"} = 1;
		$path_tests{$path} = [ "t/$1" ];
		next;
	}
	if (forces_full_suite($path)) {
		push @unmapped, $path;
		$path_tests{$path} = 'unmapped';
		next;
	}
	if (not_tested($path)) {
		push @ignored, $path;
		$path_tests{$path} = '(not tested)';
		next;
	}
	my @hit = tests_for_path($path);
	if (@hit) {
		$selected{$_} = 1 for @hit;
		$path_tests{$path} = \@hit;
	}
	else {
		push @unmapped, $path;
		$path_tests{$path} = 'unmapped';
	}
}

my @tests = $all ? @every : sort keys %selected;
my $full  = $all ? 1 : (@unmapped ? 1 : 0);
@tests = @every if $full;

# --- say it ------------------------------------------------------------------

my $command = join(' ', $^X, 'scripts/run_tests.pl', @tests);

if ($json) {
	my $q = sub { join(',', map { qq{"$_"} } @_) };
	print '{"changed":[' . $q->(@changed) . '],"tests":[' . $q->(@tests) . '],'
		. '"unmapped":[' . $q->(@unmapped) . '],"full":' . ($full ? 1 : 0) . "}\n";
	exit 2 if $strict && @unmapped;
}
else {
	if ($strict && @unmapped) {
		print "strict: refusing to guess\n";
		exit 2;
	}
	if (@changed) {
		print "changed: ", scalar(@changed), "\n";
		for my $path (@changed) {
			my $hit = $path_tests{$path};
			printf "  %-44s %s\n", $path,
				(ref $hit ? join(' ', @$hit) : (defined $hit ? $hit : ''));
		}
	}
	if (@unmapped) {
		print "UNMAPPED: $_ (no test declares it)\n" for @unmapped;
		print "running the full suite; add a `tests-for:` line to the test that covers it\n"
			unless $strict;
	}
	if (!@tests) {
		print "no test needs to run for this change\n";
		exit 0;
	}
	printf "selected %d of %d tests\n", scalar(@tests), scalar(@every);
	if (@tests <= 8) {
		printf "  %-34s %s\n", $_, ($covers{$_} || '') for @tests;
	}
	print "run: $command\n";
}

if ($run) {
	exec($^X, "$root/scripts/run_tests.pl", @tests)
		or die "tests_for: cannot run run_tests.pl: $!\n";
}
exit 0;

sub usage {
	print <<'USAGE';
Usage: perl scripts/tests_for.pl [options] [path...]

  --staged         map what is staged (default: working tree vs HEAD)
  --range A..B     map a commit range
  --files a b      map explicit paths
  --all            every test (no mapping)
  --run            run the selection with scripts/run_tests.pl
  --list-for PATH  print the tests that claim PATH
  --json           one machine-readable line
  --strict         exit 2 rather than falling back to the full suite

A path is claimed by a `# tests-for:` glob in a test's first 40 lines, or by
the test spelling the path out. Anything unclaimed runs the full suite.
USAGE
}
