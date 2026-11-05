# tests-for: lib/JawnOS/Domain/Ble.pm
# covers:    a function call written inside backticks is never interpolated; the BLE scan built
#           its command that way, so the shell got the literal text and the scan never ran

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Find;
use JawnOSTest;

my $root = root();

# Backticks interpolate $ and @, never a call: `tool &quote($path)` reaches the
# shell as the literal text '&quote', which is a syntax error. `&&cmd` is shell
# syntax, so a `&` preceded by another `&` is not this shape.
sub offender {
	my ($text) = @_;
	my @found;
	foreach my $line (split /\n/, $text) {
		while ($line =~ /`([^`]*)`/g) {
			# copy first: the test below has no captures of its own, which would reset $1
			my $segment = $1;
			push @found, $segment if $segment =~ /(?<![&\w])&[a-zA-Z_][a-zA-Z0-9_]*\s*\(/;
		}
	}
	return @found;
}

# The check itself has to catch the bug it guards, and leave ordinary shell text alone.
is(scalar(&offender('my $out = `tool &shell_quote($perl) scan`;')), 1, 'a call inside backticks is caught');
is(scalar(&offender('my $out = `tool $perl scan`;')), 0, 'a variable inside backticks is fine');
is(scalar(&offender('my $out = `build && make install`;')), 0, 'a shell && chain is not a call');

my @files;
foreach my $dir (qw(lib perl scripts)) {
	find({ no_chdir => 1, wanted => sub {
		return unless /\.(?:pm|pl)$/ && -f $_;
		push @files, $File::Find::name;
	} }, "$root/$dir");
}
ok(scalar(@files) > 100, 'the scan saw the tree (' . scalar(@files) . ' files)');

my @bad;
foreach my $file (@files) {
	open(my $fh, '<', $file) or next;
	local $/;
	my $text = <$fh>;
	close $fh;
	foreach my $hit (&offender($text)) {
		(my $where = $file) =~ s{^\Q$root\E/}{};
		push @bad, "$where: $hit";
	}
}

is_deeply(\@bad, [], 'no source calls a function inside backticks') or diag(join("\n", @bad));

done_testing();
