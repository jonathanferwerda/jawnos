# tests-for: public/js/manager/manager.js scripts/verify_change.pl
# covers:    verify_change.pl's truncation guard: a whole-file write that lost more than half its lines is the failure it e...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);

# verify_change.pl's truncation guard: a whole-file write that lost more than
# half its lines is the failure it exists to catch (a 4,151-line manager.js once
# shipped as 1,008 lines). A refactor that MOVES the content into new files is
# legitimate, so the guard asks whether files the same change adds cover what the
# shrinking file lost. These subtests pin both halves of that rule.

my $repo = tempdir(CLEANUP => 1);
my $script = "$FindBin::Bin/../scripts/verify_change.pl";
my $target = "$repo/scripts/verify_change.pl";
make_path("$repo/scripts");
open(my $in, '<', $script) or die "$script: $!";
open(my $script_out, '>', $target) or die "$target: $!";
print $script_out do { local $/; <$in> };
close $script_out;
close $in;

sub git {
	my @cmd = @_;
	my $out = `cd "$repo" && @cmd 2>&1`;
	die "git @cmd: $out" if $? != 0;
	return $out;
}

&git('git init -q');
&git('git config user.email test@example.invalid');
&git('git config user.name Test');
&git('git config commit.gpgsign false');

sub write_text {
	my ($rel, $text) = @_;
	make_path(dirname("$repo/$rel"));
	open(my $fh, '>', "$repo/$rel") or die "$repo/$rel: $!";
	print $fh $text;
	close $fh;
}

my $lines = join '', map { "line $_\n" } 1 .. 400;
write_text('big.txt', $lines);
&git('git add -A');
&git('git commit -qm base');

sub verify {
	my $out = `cd "$repo" && perl scripts/verify_change.pl --quiet 2>&1`;
	return ($? >> 8, $out);
}

# 1. a bare truncation is still the failure it always was
write_text('big.txt', "line 1\nline 2\nline 3\nline 4\nline 5\n");
my ($code, $out) = verify();
isnt($code, 0, 'a file truncated on its own is rejected');
like($out, qr/\Qbig.txt\E.*shrank/s, 'and the message names the file and the shrink');

# 2. the same shrink, with the content moved into new files, is a move
write_text('parts/a.txt', join('', map { "line $_\n" } 1 .. 200));
write_text('parts/b.txt', join('', map { "line $_\n" } 201 .. 400));
($code, $out) = verify();
is($code, 0, 'a shrink covered by the files the change adds is accepted')
	or diag($out);

# 3. one added file is not enough cover for a much bigger loss
unlink "$repo/parts/b.txt" or die $!;
($code, $out) = verify();
isnt($code, 0, 'a shrink the additions do not cover is still rejected');

done_testing();
