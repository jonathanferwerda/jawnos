use strict;
use warnings;

use FindBin;
use Test::More;
use File::Slurp qw(read_file);
use JSON::PP;

# The QA layers that are not plain Perl (a shell device script, a JS probe, a
# Python WebKit probe, the SQL check list) are invisible to verify_change.pl.
# These checks pin that they exist, parse, and still say what they claim.

my $qa = "$FindBin::Bin/../qa";

# --- the Perl modules ---------------------------------------------------------
for my $mod (qw(Db Ui)) {
	my $path = "$qa/lib/$mod.pm";
	ok(-f $path, "$mod.pm exists");
	my $rc = system($^X, '-Ilib', '-c', $path);
	is($rc, 0, "$mod.pm compiles");
}

# --- the query list -----------------------------------------------------------
my $cfg_text = read_file("$qa/db.checks.json");
my $cfg = eval { JSON::PP->new->utf8->decode($cfg_text) };
is(ref $cfg, 'HASH', 'db.checks.json is valid JSON');
ok(@{ $cfg->{'queries'} || [] } >= 3, 'several hot queries are pinned');
ok(scalar(grep { ($_->{'expect'} || '') eq 'index' } @{ $cfg->{'queries'} }),
	'at least one query must use an index');
ok(scalar(grep { ($_->{'expect'} || '') eq 'any' } @{ $cfg->{'queries'} }),
	'at least one query records its plan without demanding an index');
ok(@{ $cfg->{'synced'} || [] } >= 10, 'the synced-table list is populated');

# --- the browser probes -------------------------------------------------------
my $probe = "$qa/ui/probe.js";
ok(-f $probe, 'the Chromium probe exists');
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node) {
	is(system($node, '--check', $probe), 0, 'the Chromium probe parses');
}
else {
	pass('node is not installed; parse skipped');
}

my $webkit = "$qa/ui/webkit_probe.py";
ok(-f $webkit, 'the WebKit probe exists');
my $wk_src = read_file($webkit);
like($wk_src, qr/GLib\.Uri\.parse/, 'the TLS exception is keyed by host, not URI');
like($wk_src, qr/timeout_add\(150/, 'the reload waits for the handler to return');
like(read_file("$qa/lib/Ui.pm"), qr/XDG_DATA_HOME/,
	'each run gets a private WebKit profile');
my $py = `command -v python3 2>/dev/null`;
chomp $py if defined $py;
if ($py) {
	is(system($py, '-c', 'import ast,sys; ast.parse(open(sys.argv[1]).read())', $webkit),
		0, 'the WebKit probe parses');
}
else {
	pass('python3 is not installed; compile skipped');
}

# --- the policy and the runner agree on the layers ---------------------------
my $runner = read_file("$qa/run.pl");
like($runner, qr/known: l0 l1 l2 l3/, 'the runner names all four layers');
like($runner, qr/live => 1/, 'the UI layer boots a loopback session');
like($runner, qr/Db->checks/, 'the database layer runs the checks');
my $wk_at = index($runner, 'my $w = Ui->webkit');
my $cr_at = index($runner, 'my $r = Ui->probe');
ok($wk_at >= 0 && $cr_at > $wk_at,
	'WebKit runs before Chromium, so a handler that kills the tree cannot mask it');

done_testing();
