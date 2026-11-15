# tests-for: scripts/loc.pl
# covers:    the authored line count - the language buckets, the comment rules,
#           vendored and generated data kept out of the table, and every tracked
#           file landing in exactly one bucket

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use JSON::PP ();
use Symbol qw(gensym);
use Test::More;

my $root = abs_path("$FindBin::Bin/..");
my $loc  = "$root/scripts/loc.pl";

# The count is only worth quoting if it is reproducible and honest about its
# edges, so this pins three things: the lexical rules (blank, comment and code
# on a known file), the two exclusions (vendored libraries, generated data), and
# the arithmetic - languages plus vendored plus not-code is every tracked file
# the script can read. Six tracked symlinks in desktop/mkosi point at files that
# do not exist in the checkout, so the buckets cover the tracked regular files.

sub run_loc {
	my @args = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $loc, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	close $out;
	close $err;
	waitpid($pid, 0);
	return ($stdout, $stderr, $? >> 8);
}

sub json_loc {
	my @args = @_;
	my ($stdout, $stderr, $code) = run_loc('--json', @args);
	is($code, 0, "loc.pl --json @args exits 0") or diag($stderr);
	return JSON::PP->new->decode($stdout);
}

sub put {
	my ($path, $text) = @_;
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh $text;
	close $fh;
}

sub physical_lines {
	my $path = shift;
	open(my $fh, '<', $path) or return -1;
	my $lines = 0;
	$lines++ while <$fh>;
	close $fh;
	return $lines;
}

sub tracked_files {
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, 'git', '-C', $root, 'ls-files', '-z');
	close $in;
	local $/;
	my $raw = <$out> // '';
	close $out;
	close $err;
	waitpid($pid, 0);
	return grep { -f "$root/$_" } grep { length } split /\0/, $raw;
}

# --- the lexical rules, on fixtures ------------------------------------------

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/sub");

put("$dir/a.pl", <<'FIXTURE');
#!/usr/bin/perl
# leading comment

=head1 POD

Body text.

=cut

my $x = 1; # trailing
print "$x\n";
FIXTURE

put("$dir/b.js", <<'FIXTURE');
// head
/* block
   still block */
var a = 1; // tail
var b = "http://x"; // not a comment start
/* one */ var c = 2;
FIXTURE

put("$dir/c.py", <<'FIXTURE');
# comment
"""doc
still doc"""
x = 1
FIXTURE

put("$dir/d.sh", <<'FIXTURE');
#!/bin/sh
# comment

echo hi
FIXTURE

put("$dir/e.sql", <<'FIXTURE');
-- comment
/* block */
SELECT 1;
FIXTURE

# no extension: the language comes from the interpreter
put("$dir/sub/launcher", "#!/usr/bin/env perl\nprint 1;\n");

put("$dir/lib.min.js", "var x=1;\n");
put("$dir/notes.md", "# notes\n\nnot code\n");

my $fixture = json_loc('--root', $dir);
my %lang = map { $_->{language} => $_ } @{ $fixture->{languages} };

is($fixture->{total}{files}, 6, 'only the fixture code files are in the table');
is($fixture->{total}{lines}, 30, 'fixture line total');
is($fixture->{total}{blank}, 5, 'blank lines are counted apart');
is($fixture->{total}{comment}, 16, 'comments are counted apart');
is($fixture->{total}{code}, 9, 'code is the remainder');

is($lang{'Perl'}{files}, 2, 'a .pl and a shebang-only launcher are one language');
is($lang{'Perl'}{comment}, 6, 'shebang, hash comment and POD are comments');
is($lang{'Perl'}{code}, 3, 'print and assignment are code');
is($lang{'Perl'}{blank}, 4, 'blank lines inside POD are still blank');

is($lang{'JavaScript'}{files}, 1, 'a minified build is not JavaScript the house wrote');
is($lang{'JavaScript'}{code}, 3, 'inline block comments leave the code visible');
is($lang{'JavaScript'}{comment}, 3, 'a URL inside a string is not a comment marker');

is($lang{'Python'}{comment}, 3, 'a docstring is a comment');
is($lang{'Python'}{code}, 1, 'the statement under the docstring is code');

is($lang{'Shell'}{comment}, 2, 'shebang and hash comment');
is($lang{'SQL'}{code}, 1, 'a statement after SQL comments is code');

is($fixture->{vendored}{files}, 1, 'the minified file is weighed as vendored');
is($fixture->{not_counted}{files}, 1, 'markdown is not code');
is($fixture->{not_counted}{by_extension}{md}{lines}, 3, 'markdown lines are still reported');

for my $row (@{ $fixture->{languages} }) {
	is($row->{lines}, $row->{blank} + $row->{comment} + $row->{code},
		"$row->{language}: every line is blank, comment or code");
}

# --- the real tree ------------------------------------------------------------

my $repo = json_loc();

my @rows = @{ $repo->{languages} };
my %sum = (files => 0, lines => 0, blank => 0, comment => 0, code => 0);
for my $row (@rows) {
	$sum{$_} += $row->{$_} for keys %sum;
}
is($repo->{total}{files}, $sum{files}, 'total files is the sum of the languages');
is($repo->{total}{lines}, $sum{lines}, 'total lines is the sum of the languages');
is($repo->{total}{code}, $sum{code}, 'total code is the sum of the languages');

is($rows[0]{language}, 'Perl', 'Perl is the largest language');

my %present = map { $_->{language} => 1 } @rows;
my @expected = ("Perl", "JavaScript", "CSS", "Python", "Shell", "SQL", "C/C++ (Arduino)", "Perl (Mojo templates)", "C/C++ header");
ok($present{$_}, "the repo has $_") for @expected;

my %tracked = map { $_ => 1 } tracked_files();
is($repo->{total}{files} + $repo->{vendored}{files} + $repo->{not_counted}{files},
	scalar(keys %tracked), 'every tracked file lands in exactly one bucket');

my @vendor = @{ $repo->{vendored}{paths} };
is(scalar @vendor, $repo->{vendored}{files}, 'the vendored list is the vendored count');
ok(scalar @vendor > 0, 'the tree has vendored and generated files to keep out');

for my $entry (@vendor) {
	my $rel = $entry->{path};
	ok($tracked{$rel}, "$rel is still tracked");
	is($entry->{lines}, physical_lines("$root/$rel"), "$rel line count is real");
}

my $all = json_loc('--all');
is($all->{vendored}{files}, 0, '--all folds the vendored files into their languages');
is($all->{total}{lines}, $repo->{total}{lines} + $repo->{vendored}{lines},
	'--all adds exactly the vendored lines');

# --- the human table ----------------------------------------------------------

my ($table) = run_loc();
like($table, qr/^LANGUAGE\s+FILES\s+LINES\s+BLANK\s+COMMENT\s+CODE$/m, 'table header');
like($table, qr/^TOTAL\s+[0-9]+/m, 'table totals row');
like($table, qr/vendored or generated, not counted/, 'the exclusions are still weighed');
like($table, qr/lines not code/, 'the non-code files are still weighed');

my ($help, $help_err, $help_code) = run_loc('--help');
is($help_code, 0, '--help exits 0');
like($help, qr/usage: loc\.pl/, 'usage line names the script');

done_testing();
