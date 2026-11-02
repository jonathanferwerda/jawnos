# tests-for: lib/JawnOS/Controller/js_misc.pm lib/JawnOS/Domain/Format.pm lib/JawnOS/Manager.pm lib/JawnOS/Routes/js_misc.pm public/js/manager/ public/js/universal.js templates/
# covers:    A big browser script keeps its old path as an index (its first part) and puts the rest in a folder of the same...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource;

# A big browser script keeps its old path as an index (its first part) and puts
# the rest in a folder of the same name, in numeric order. The page loads one
# core bundle; an app's scripts are a lazy chunk fetched on first open. This
# test guards everything a split or a lazy map can silently break:
#
#   - every part folder has an index beside it;
#   - every part is named NN_something.js (the order is the name order);
#   - the index carries a [[js-split]] manifest naming every part;
#   - every bundle entry is either core or named by an app chunk;
#   - every app's files are real bundle entries and its toggle/entry maps agree;
#   - the core bundle and every app chunk parse as one script;
#   - the loader, the click replay and the entry stubs are present;
#   - the layout stamps the maps and preloads the core bundle.

my $root = repo_root();
# The bundle and app maps live in the Core*.pm boot parts now: read the index
# plus every part it requires eagerly, in require order.
my $manager_pm = read_file("$root/lib/JawnOS/Manager.pm");
my @boot_parts = grep { m{^JawnOS/Manager/Core} } ($manager_pm =~ /^require\s+'([^']+)';/mg);
$manager_pm .= read_file("$root/lib/$_") for @boot_parts;

my ($bundle_block) = $manager_pm =~ /our \@manager_bundle_files = qw\((.*?)\);/s;
ok(defined $bundle_block, 'the manager bundle list is found');
my @bundle_entries = grep { length } split /\s+/, ($bundle_block // '');
ok(@bundle_entries > 50, 'the bundle list names the manager scripts');
my %bundle = map { $_ => 1 } @bundle_entries;

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

# --- the lazy map ------------------------------------------------------------
my ($apps_block) = $manager_pm =~ /our %manager_app_scripts = \((.*?)\n\);/s;
ok(defined $apps_block, 'the app chunk map is found');
my %apps;
while (($apps_block // '') =~ /(\w+)\s*=>\s*\[qw\(([^)]*)\)\]/g) {
	my ($app, $list) = ($1, $2);
	$apps{$app} = [ grep { length } split /\s+/, $list ];
}
ok(scalar(keys %apps) >= 15, 'the app map names the lazy apps');

my %lazy = map { $_ => 1 } map { @$_ } values %apps;
my @core = grep { !$lazy{$_} } @bundle_entries;
ok(@core >= 20, 'a real core bundle remains');

foreach my $app (sort keys %apps) {
	ok(@{ $apps{$app} }, "$app has at least one script");
	foreach my $file (@{ $apps{$app} }) {
		ok($bundle{$file}, "$app names the bundle entry $file");
	}
}
is_deeply([ sort(@core, keys %lazy) ], [ sort @bundle_entries ],
	'every bundle entry is either core or owned by an app chunk');

# entry stubs: a function core may call before the chunk arrives
my ($entry_block) = $manager_pm =~ /our %manager_app_entry = \((.*?)\n\);/s;
ok(defined $entry_block, 'the entry-stub map is found');
my %entry;
while (($entry_block // '') =~ /(\w+)\s*=>\s*\[qw\(([^)]*)\)\]/g) {
	my ($app, $list) = ($1, $2);
	$entry{$app} = [ grep { length } split /\s+/, $list ];
}
foreach my $app (sort keys %entry) {
	ok($apps{$app}, "entry stub $app has a script chunk");
	foreach my $name (@{ $entry{$app} }) {
		like($name, qr/^[A-Za-z_][A-Za-z0-9_]*$/, "entry $name is a function name");
	}
}

# start-menu toggles: the first click has to be caught in core
my ($toggle_block) = $manager_pm =~ /our %manager_toggle_apps = \((.*?)\n\);/s;
ok(defined $toggle_block, 'the toggle dispatcher map is found');
my %toggle;
while (($toggle_block // '') =~ /(\w+)\s*=>\s*'([^']+)'/g) {
	$toggle{$1} = $2;
}
foreach my $key (sort keys %toggle) {
	ok($apps{ $toggle{$key} }, "toggle $key maps to the lazy app $toggle{$key}");
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

# --- universal.js is a split too, outside the manager folder -----------------
# Every page (the gate included) loads it through subs::js_script_urls, so a
# part that is not named in the manifest would silently stop loading.
{
	my $index = "$root/public/js/universal.js";
	ok(-f $index, 'universal.js has an index');
	my @parts = grep { $_ ne $index } parts_for($index);
	ok(scalar @parts, 'universal.js has parts in universal/');
	my ($manifest) = read_file($index) =~ /\/\* \[\[js-split\]\](.*?)\[\[\/js-split\]\] \*\//s;
	ok(defined $manifest, 'universal.js carries a [[js-split]] manifest');
	foreach my $part (@parts) {
		(my $base = $part) =~ s{.*/}{};
		like($base, qr/^\d{2}_[a-z0-9_]+\.js$/, "universal part $base is numbered");
		like($manifest // '', qr/\Q$base\E/, "universal.js names its part $base");
	}
	my @named = ($manifest // '') =~ /\b(\d{2}_[a-z0-9_]+\.js)\b/g;
	my %named = map { $_ => 1 } @named;
	my %real = map {
		my $b = $_;
		$b =~ s{.*/}{};
		$b => 1;
	} @parts;
	is_deeply([sort keys %named], [sort keys %real],
		'universal.js names every part and no file that is gone');
	if ($have_node) {
		my $failed = 0;
		foreach my $file (parts_for($index)) {
			my $out = `$node --check "$file" 2>&1`;
			if ($? != 0) {
				$failed++;
				diag("$file: $out");
			}
		}
		is($failed, 0, 'the universal.js index and every part parse');
	}
}

# --- every script still parses ----------------------------------------------
my @all;
foreach my $entry (@bundle_entries) {
	my $index = "$root/public$entry";
	ok(-f $index, "bundle source public$entry exists");
	next unless -f $index;
	push @all, parts_for($index);
}
ok(@all >= @bundle_entries, 'every bundle entry resolved to at least its index');

sub build_entries {
	my (@entries) = @_;
	my ($raw, @files) = ('');
	foreach my $entry (@entries) {
		foreach my $file (parts_for("$root/public$entry")) {
			push @files, $file;
			$raw .= "\n;/* $entry */\n" . read_file($file) . "\n;\n";
		}
	}
	return ($raw, @files);
}

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

	my ($core_raw) = build_entries(@core);
	my ($fh, $tmp) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh $core_raw;
	close $fh;
	my $out = `$node --check "$tmp" 2>&1`;
	my $ok = ($? == 0) ? 1 : 0;
	diag($out) unless $ok;
	ok($ok, 'the concatenated core bundle parses as one script');

	my $chunks_failed = 0;
	foreach my $app (sort keys %apps) {
		my ($raw) = build_entries(@{ $apps{$app} });
		my ($fh2, $tmp2) = tempfile(SUFFIX => '.js', UNLINK => 1);
		print $fh2 $raw;
		close $fh2;
		my $err = `$node --check "$tmp2" 2>&1`;
		if ($? != 0) {
			$chunks_failed++;
			diag("$app chunk: $err");
		}
	}
	is($chunks_failed, 0, 'every lazy app chunk parses as one script');
}
else {
	diag('node is not installed; the syntax checks are skipped');
}

# --- the loader and its safety nets -----------------------------------------
my $lazy = read_file("$root/public/js/manager/lazy.js");
like($lazy, qr/function jawnosLoadApp\(/, 'the loader defines jawnosLoadApp');
like($lazy, qr/function jawnosLoadPump\(/, 'one chunk request is in flight at a time');
like($lazy, qr{/js/manager/app\.js\?files=}, 'the loader asks the chunk route');
like($lazy, qr/function jawnosToggleApp\(/, 'the click dispatcher is present');
like($lazy, qr/stopImmediatePropagation/, 'the first click waits for the chunk');
like($lazy, qr/trigger\('click'\)/, 'the click is replayed after the chunk');
like($lazy, qr/appWindowOpener\(app, Date\.now\(\)/, 'a re-rendered menu falls back to the opener');
like($lazy, qr/window\[name\] = stub/, 'entry functions get a loading stub');

my $js_misc = read_file("$root/lib/JawnOS/Controller/js_misc.pm");
like($js_misc, qr/\@manager_core_files/, 'the page bundle serves the core list');
like($js_misc, qr/sub action_7408/, 'the chunk action exists');
like($js_misc, qr/content_encoding\('gzip'\)/, 'the bundle is gzipped when asked');
my $routes = read_file("$root/lib/JawnOS/Routes/js_misc.pm");
like($routes, qr{'/js/manager/app\.js'.*action_7408}s, 'the chunk route is registered');

# --- scripts loaded outside the bundle reach their parts --------------------
# websocket and jp are separate <script> tags in the manager layout; the IME
# page loads soft_keyboard on its own. They go through js_script_urls so a
# folder of parts is not silently skipped when the page is opened.
my $layout = read_file("$root/templates/layouts/manager.html.ep");
like($layout, qr/js_script_urls\('public\/js\/manager\/websocket\.js'\)/,
	'the manager layout expands websocket parts');
like($layout, qr/js_script_urls\('public\/js\/manager\/jp\.js'\)/,
	'the manager layout expands jp parts');
like($layout, qr/var jawnos_app_scripts =/, 'the layout stamps the app chunk map');
like($layout, qr/var jawnos_app_entry =/, 'the layout stamps the entry stubs');
like($layout, qr/var jawnos_toggle_apps =/, 'the layout stamps the toggle map');
like($layout, qr/rel="preload" as="script" href="\/js\/manager\/bundle\.js/,
	'the core bundle is preloaded');
my $ime = read_file("$root/templates/ime.html.ep");
like($ime, qr/js_script_urls\('public\/js\/manager\/soft_keyboard\.js'\)/,
	'the IME page expands soft_keyboard parts');

diag("split scripts found: $splits; core entries: " . scalar(@core)
	. "; lazy apps: " . scalar(keys %apps));
done_testing();
