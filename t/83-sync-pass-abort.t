# tests-for: lib/JawnOS/Manager/Part36.pm
# covers:    The reconnector walks the roster inside one bare `eval`.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;

# The reconnector walks the roster inside one bare `eval`. When that pass threw,
# the exception vanished: the log kept saying "a peer announced new rows; running
# the pass now" with no `sync pull` line after it, and the machine simply stopped
# dialling. A tablet sat that way for an hour on 2026-11-01.
#
# The pass now records that it reached the end, and logs a distinct abort once per
# process. Pin both halves: the sentinel is set only after the walk, and the
# failure branch names the error instead of rethrowing it.

my $file = repo_root() . '/lib/JawnOS/Manager/Part36.pm';
my $source = '';
if (-f $file) {
	open(my $fh, '<', $file) or die "$file: $!";
	local $/;
	$source = <$fh>;
	close $fh;
}
ok(length $source, 'the reconnector source was read');

like($source, qr/my \$pass_ok = 0;\s*\n\teval \{/,
	'the pass starts with a completion sentinel');

like($source, qr/\$pass_ok = 1;\s*\n\t\};/,
	'the sentinel is set only after the whole roster walk');

like($source, qr/if \(!\$pass_ok\) \{/,
	'a pass that never reached the end is noticed');

like($source, qr/sync pass aborted: ' \. \$err/,
	'the abort names its exception in the log');

like($source, qr/our %sync_pass_error_seen;/,
	'the abort log is throttled to once per distinct error');

# A top-level `return` inside the eval would leave the sub before the sentinel,
# reporting a healthy pass as an abort on every tick. The nested
# `sub remote_pseudonyms` keeps its own return, so indentation is the guard: a
# return at two tabs or less is the pass's own.
my ($body) = $source =~ /sub remote_machine_reconnector\(\$c\) \{(.*?)\n\}/s;
ok(defined $body && length $body, 'the reconnector body was found');

if (defined $body) {
	my @indent = $body =~ /^(\t*)return\b/mg;
	my $top = grep { length($_) <= 2 } @indent;
	ok(!$top, 'no top-level return leaves the pass before its sentinel')
		or diag("a return at <= 2 tabs would skip \$pass_ok; found $top");
}

done_testing();
