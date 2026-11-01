use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource;

# A big browser script keeps its old path as an index (its first part) and puts
# the rest in a folder of the same name, in numeric order. The bundle route,
# the help inventory and js_source() all follow that one convention, so this
# test guards the pieces a split can silently break:
#
#   - every part folder has an index beside it;
#   - every part is named NN_something.js (the order is the name order);
#   - the index carries a [[js-split]] manifest naming every part;
#   - every bundle file (index and parts) still parses;
#   - the assembled manager bundle still parses as one script.

my $root = repo_root();

my $manager_pm = read_file("$root/lib/JawnOS/Manager.pm");
my ($bundle_block) = $manager_pm =~ /our \@manager_bundle_files = qw\((.*?)\);/s;
ok(defined $bundle_block, 'the manager bundle list is found');
my @bundle_entries = grep { length } split /\s+/, ($bundle_block // '');
ok(@bundle_entries > 50, 'the bundle list names the manager scripts');

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
my $have_node = ($node && -x $node) ? 1 : 0;

sub parts_for {
	my ($index) = @_;
	my @files = (-f $index ? ($index) : ());
	(my $dir = $index) =~ s{\.js$}{};
	push @files, sort grep { -f } glob("$dir/*.js") if -d $dir;
	return @files;
}

# --- every split is an index plus numbered parts -----------------------------
my @split_dirs = sort grep { -d } glob("$root/public/js/manager/*/");
my $splits = 0;
foreach my $dir (@split_dirs) {
	my @parts = sort grep { -f } glob("$dir*.js");
	next unless @parts;
	$splits++;
	(my $name = $dir) =~ s{/$}{};
	$name =~ s{.*/}{};
	my $index = "$root/public/js/manager/$name.js";
	ok(-f $index, "$name has an index beside its parts");

	my $text = -f $index ? read_file($index) : '';
	my ($manifest) = $text =~ /\/\* \[\[js-split\]\](.*?)\[\[\/js-split\]\] \*\//s;
	ok(defined $manifest, "$name.js carries a [[js-split]] manifest");

	foreach my $part (@parts) {
		(my $base = $part) =~ s{.*/}{};
		like($base, qr/^\d{2}_[a-z0-9_]+\.js$/,
			"$name part $base is numbered so the order is the name order");
		like($manifest // '', qr/\Q$base\E/,
			"$name.js names its part $base");
	}

	my @named = ($manifest // '') =~ /\b(\d{2}_[a-z0-9_]+\.js)\b/g;
	my %named = map { $_ => 1 } @named;
	my %real  = map { my $b = $_; $b =~ s{.*/}{}; $b => 1 } @parts;
	is_deeply([sort keys %named], [sort keys %real],
		"$name.js names every part and no file that is gone");
}

# --- everything the bundle reads still parses --------------------------------
my $raw = '';
my @all;
foreach my $entry (@bundle_entries) {
	my $index = "$root/public$entry";
	ok(-f $index, "bundle source public$entry exists");
	next unless -f $index;
	foreach my $file (parts_for($index)) {
		push @all, $file;
		$raw .= "\n;/* $entry */\n" . read_file($file) . "\n;\n";
	}
}
ok(@all >= @bundle_entries, 'every bundle entry resolved to at least its index');

if ($have_node) {
	my $failed = 0;
	foreach my $file (@all) {
		my $out = `$node --check "$file" 2>&1`;
		if ($? != 0) {
			$failed++;
			diag("$file: $out");
		}
	}
	is($failed, 0, 'every bundle source parses on its own');

	my ($fh, $tmp) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh $raw;
	close $fh;
	my $out = `$node --check "$tmp" 2>&1`;
	my $ok = ($? == 0) ? 1 : 0;
	diag($out) unless $ok;
	ok($ok, 'the concatenated manager bundle parses as one script');
}
else {
	diag('node is not installed; the syntax checks are skipped');
}

# --- scripts loaded outside the bundle reach their parts --------------------
# websocket and jp are separate <script> tags in the manager layout; the IME
# page loads soft_keyboard on its own. They go through js_script_urls so a
# folder of parts is not silently skipped when the page is opened.
my $layout = read_file("$root/templates/layouts/manager.html.ep");
like($layout, qr/js_script_urls\('public\/js\/manager\/websocket\.js'\)/,
	'the manager layout expands websocket parts');
like($layout, qr/js_script_urls\('public\/js\/manager\/jp\.js'\)/,
	'the manager layout expands jp parts');
my $ime = read_file("$root/templates/ime.html.ep");
like($ime, qr/js_script_urls\('public\/js\/manager\/soft_keyboard\.js'\)/,
	'the IME page expands soft_keyboard parts');

diag("split scripts found: $splits");
done_testing();
