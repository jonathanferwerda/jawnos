# tests-for: public/js/manager/keyboard/03_editor_switcher.js
# covers:    The note textarea's upgrader asked for textarea[upgradeable="yes"
#           with no closing bracket. Sizzle rejects that selector, so the call
#           threw and the rich editor never replaced the note. The answer is
#           async as well: a restore that ran the pass twice started two
#           editors for one note, so the field is now claimed before asking.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $js = read_file("$root/public/js/manager/keyboard/03_editor_switcher.js");

like($js, qr/\$\('textarea\[upgradeable="yes"\]'\)/,
	'the upgrader selector closes its attribute');
unlike($js, qr/textarea\[upgradeable="yes"'\s*\)/,
	'no attribute selector is left unterminated');

my ($upgrader) = $js =~ /(function textareaUpgrader\(\) \{.*?\n\})/s;
ok($upgrader, 'the upgrader function is still here');
like($upgrader // '', qr/ta\.attr\('upgraded', 'yes'\);\s*\$\.ajax\(/s,
	'the field is claimed before the request leaves');
like($upgrader // '', qr/error: function\(\) \{ ta\.removeAttr\('upgraded'\); \}/,
	'a failed request gives the field back');

# --- the function itself, with a fake jQuery --------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my $harness = "$FindBin::Bin/lib/textarea_upgrader.js";
	my $out = `$node "$harness" "$root/public/js/manager/keyboard/03_editor_switcher.js" 2>&1`;
	my $status = $? >> 8;
	my @lines = grep { /^(?:not )?ok / } split /\n/, $out;
	ok(scalar @lines >= 5, 'the upgrader harness ran');
	for my $line (@lines) {
		my ($verdict, $name) = $line =~ /^(ok|not ok) (.*)$/;
		ok($verdict eq 'ok', $name);
	}
	is($status, 0, 'the upgrader harness exits clean');
}
else {
	skip 'node is not installed', 7;
}

done_testing();
