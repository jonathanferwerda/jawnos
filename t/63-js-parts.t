# tests-for: lib/JawnOS/Controller/js_misc.pm lib/JawnOS/Domain/Format.pm lib/JawnOS/Manager.pm lib/JawnOS/Manager/Core1_tables_hooks.pm lib/JawnOS/Routes/js_misc.pm public/js/manager/ public/js/universal.js templates/
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

# One node process compiles a list of files. Running `node --check` once per
# file was most of this test's run time (~450 startups); vm.Script performs the
# same compile check without executing anything.
my $NODE_CHECK = <<'JS';
var fs = require('fs'), vm = require('vm');
var list = fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(function (s) { return s.length; });
var bad = 0;
list.forEach(function (f) {
	try { new vm.Script(fs.readFileSync(f, 'utf8'), { filename: f }); }
	catch (e) { bad++; console.log(f + ': ' + e.message); }
});
process.exit(bad ? 1 : 0);
JS

sub node_check {
	my ($files) = @_;
	my ($lh, $list) = tempfile(SUFFIX => '.txt', UNLINK => 1);
	print $lh map { "$_\n" } @$files;
	close $lh;
	my ($ch, $checker) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $ch $NODE_CHECK;
	close $ch;
	my $out = `$node "$checker" "$list" 2>&1`;
	return ($? >> 8, $out);
}

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

# The canvas layouts' printers are a third list: neither core nor an app chunk.
# The desk never draws them, so they load as one chunk; see @manager_layout_files.
my ($layout_block) = $manager_pm =~ /our \@manager_layout_files = qw\((.*?)\);/s;
ok(defined $layout_block, 'the layout printer list is found');
my @layout_entries = grep { length } split /\s+/, ($layout_block // '');
ok(@layout_entries >= 3, 'the layout chunk names the canvas printers');
my %layout_files = map { $_ => 1 } @layout_entries;
foreach my $file (@layout_entries) {
	ok($bundle{$file}, "the layout chunk names the bundle entry $file");
	ok(!$lazy{$file}, "$file is not also an app's script");
}

my @core = grep { !$lazy{$_} && !$layout_files{$_} } @bundle_entries;
ok(@core >= 20, 'a real core bundle remains');

foreach my $app (sort keys %apps) {
	ok(@{ $apps{$app} }, "$app has at least one script");
	foreach my $file (@{ $apps{$app} }) {
		ok($bundle{$file}, "$app names the bundle entry $file");
	}
}
is_deeply([ sort(@core, keys %lazy, keys %layout_files) ], [ sort @bundle_entries ],
	'every bundle entry is core, an app chunk or the layout chunk');

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
		my ($rc, $out) = node_check( [ parts_for($index) ] );
		diag($out) if $rc;
		is($rc, 0, 'the universal.js index and every part parse');
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

# --- no top-level function is defined twice ---------------------------------
# The core bundle and every lazy chunk are concatenated into one global scope,
# so a second `function name()` silently replaces the first and the earlier file
# becomes dead code. That is how a "restored" budgetLight in the budget chunk
# left the appointment view broken while every file still parsed (v0.1.1810).
# Only declarations at column 0 are counted: a function nested in another
# function or an IIFE gives no global and is not a collision.
{
	my (%seen, @dupes);
	foreach my $file (@all) {
		my $rel = $file;
		$rel =~ s{^\Q$root/public/\E}{};
		my $text = read_file($file);
		while ($text =~ /^function\s+([A-Za-z_\$][A-Za-z0-9_\$]*)\s*\(/mg) {
			my $name = $1;
			if ($seen{$name} && $seen{$name} ne $rel) {
				push @dupes, "$name is declared in both $seen{$name} and $rel";
			}
			$seen{$name} ||= $rel;
		}
	}
	is_deeply(\@dupes, [], 'no top-level function is declared twice in the bundle')
		or diag(join("\n", @dupes));
}

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
	# the batched checker must still fail on a broken file, or the loops above
	# would pass by never reporting anything
	my ($bh, $bad) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $bh "function broken( {\n";
	close $bh;
	my ($rc, $out) = node_check([$bad]);
	isnt($rc, 0, 'the batched syntax check catches a broken file');
	like($out, qr/\Q$bad\E/, 'and names the file it could not parse');

	my ($rc_all, $out_all) = node_check(\@all);
	diag($out_all) if $rc_all;
	is($rc_all, 0, 'every bundle source parses on its own');

	my ($core_raw) = build_entries(@core);
	my ($fh, $tmp) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh $core_raw;
	close $fh;
	my $core_out = `$node --check "$tmp" 2>&1`;
	my $ok = ($? == 0) ? 1 : 0;
	diag($core_out) unless $ok;
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

	my ($layout_raw) = build_entries(@layout_entries);
	my ($lfh, $ltmp) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $lfh $layout_raw;
	close $lfh;
	my $layout_out = `$node --check "$ltmp" 2>&1`;
	is(($? == 0) ? 1 : 0, 1, 'the layout chunk parses as one script') or diag($layout_out);
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
like($lazy, qr/function jawnosLoadLayout\(/, 'the loader defines the layout chunk too');
like($lazy, qr{/js/manager/layout\.js\?string=}, 'the layout chunk asks its own route');
like($lazy, qr/layout != 'desk'/, 'the desk asks for no layout chunk');
like($lazy, qr/window\.calculator = wrapper/, 'the first calculator draw waits for the chunk');

my $js_misc = read_file("$root/lib/JawnOS/Controller/js_misc.pm");
like($js_misc, qr/\@manager_core_files/, 'the page bundle serves the core list');
like($js_misc, qr/sub action_7408/, 'the chunk action exists');
like($js_misc, qr/sub action_7409/, 'the layout chunk action exists');
like($js_misc, qr/\@manager_layout_files/, 'the layout chunk is built from the printer list');
like($js_misc, qr/js_minify\(\$raw\)/, 'the layout chunk is minified');
like($js_misc, qr/content_encoding\('gzip'\)/, 'the bundle is gzipped when asked');
my $routes = read_file("$root/lib/JawnOS/Routes/js_misc.pm");
like($routes, qr{'/js/manager/app\.js'.*action_7408}s, 'the chunk route is registered');
like($routes, qr{'/js/manager/layout\.js'.*action_7409}s, 'the layout chunk route is registered');

my %core_set = map { $_ => 1 } @core;
ok(!$core_set{'/js/manager/timelineprinter.js'}, 'the timeline printer is not in the core bundle');
ok($core_set{'/js/manager/printer_common.js'}, 'the shared header and hit areas stay core');
ok($core_set{'/js/manager/backgroundprinter.js'}, 'the desk wallpaper printer stays core');

# The press that opens a window from a canvas control has to be in the core
# bundle: the desk draws its rail without ever requesting the layout chunk, so a
# press left in a printer is dead there and the rail's buttons do nothing.
my $common = read_file("$root/public/js/manager/printer_common.js");
like($common, qr/\$\(document\)\.on\('click', '\.background'/,
	'the canvas press that opens a window is core');
like($common, qr/appointmentGrabber\(o\[4\]\['name'\],timestamp\);/,
	'and it reaches the window opener');
unlike(read_file("$root/public/js/manager/leaderboardprinter.js"), qr/\$\(document\)\.on\('click', '\.background'/,
	'no layout printer carries a press the desk cannot load');

ok($bundle{'/js/universal.js'}, 'universal.js is in the core bundle');
ok($bundle{'/js/manager/websocket.js'}, 'websocket.js is in the core bundle');
ok($bundle{'/js/manager/jp.js'}, 'jp.js is in the core bundle');

# --- one bundle, not fourteen tags ------------------------------------------
# The manager page used to load universal, websocket and jp as fourteen
# separate parser-blocking tags. They are in the one core bundle now (the route
# expands each split index), so a laptop pays one parse and one request instead
# of fourteen round trips before the desk stands. The IME page still loads
# soft_keyboard on its own through js_script_urls.
my $layout = read_file("$root/templates/layouts/manager.html.ep");
unlike($layout, qr/js_script_urls\('public\/js\/manager\/websocket\.js'\)/,
	'the manager layout no longer loads websocket as separate tags');
unlike($layout, qr/js_script_urls\('public\/js\/manager\/jp\.js'\)/,
	'and no longer loads jp as separate tags');
unlike($layout, qr/js_script_urls\('public\/js\/universal\.js'\)/,
	'and no longer loads universal as separate tags');
like($layout, qr/var jawnos_app_scripts =/, 'the layout stamps the app chunk map');
like($layout, qr/var jawnos_app_entry =/, 'the layout stamps the entry stubs');
like($layout, qr/var jawnos_toggle_apps =/, 'the layout stamps the toggle map');
like($layout, qr/rel="preload" as="script" href="\/js\/manager\/bundle\.js/,
	'the core bundle is preloaded');
my $ime = read_file("$root/templates/ime.html.ep");
like($ime, qr/js_script_urls\('public\/js\/manager\/soft_keyboard\.js'\)/,
	'the IME page expands soft_keyboard parts');

# --- a refresh replaces the app body, not the window -------------------------
# The Security app's unlock redraw and its share/passkey refreshes used to ask
# for window_maker=yes and then $('#security').replaceWith(r.html): the reply
# was a whole .wind, so every unlock or refresh nested another Security window.
# Only the start-menu toggle opens a window.
my $house_key = read_file("$root/public/js/manager/security/01_house_key.js");
unlike($house_key, qr/window_maker\s*:\s*['"]yes['"]/,
	'a Security view refresh replaces #security and never asks for a window');
my $security_index = read_file("$root/public/js/manager/security.js");
like($security_index, qr/window_maker\s*:\s*['"]yes['"].*?windowMaker\(/s,
	'the start-menu Security toggle still opens a window through windowMaker');

# The app-unlock redraw used to name Passkeys, so the fingerprint on the
# Padlock tab landed on Passkeys. It now redraws the view the person chose;
# the tab press has already saved security_view before the locked reply.
my ($refresh_block) = $house_key =~ /(function securityRefresh\(\).*?\n\t\})/s;
ok(defined $refresh_block, 'the Security refresh is found');
unlike($refresh_block, qr/security_view/,
	'the app unlock redraws the chosen view, not a hard-coded Passkeys');

# --- the phone key can open the whole house ---------------------------------
# With a house-wide inactivity lock and this phone's own screen open, s.locked
# is false and there is no target to sign. The page used to say "No screen is
# locked" and hide its Unlock button, which was a dead end. It now offers the
# house unlock and signs the house name.
my $key_script = read_file("$root/templates/padlock_key/script.html.ep");
like($key_script, qr/padlockKeyHouse\s*=\s*true/,
	'the phone key offers a whole-house unlock when only the house timer is closed');
like($key_script, qr/\+= 'house/,
	'it signs the house name rather than a target screen');
like($key_script, qr/body\.set\('house', '1'\)/,
	'and posts house=1 to padlock_unlock');
my $key_markup = read_file("$root/templates/padlock_key/markup.html.ep");
like($key_markup, qr/id="padlock_key_back"/,
	'the phone key page has a way back to the house');

# The Padlock view's phone page is a button now, and the key page offers the
# house open even when its own manager says open: a peer can hold the lock.
my $padlock_view = read_file("$root/templates/security/padlock.html.ep");
like($padlock_view, qr/<button[^>]*id="padlock_key_show"/,
	'the phone unlock page is a button');
unlike($padlock_view, qr/<a[^>]*id="padlock_key_show"/,
	'and no longer a link');
like($padlock_view, qr/id="padlock_key_show"[^>]*onclick="[^"]*padlock_key/,
	'the button navigates from the template, not only the cached app chunk');
like(read_file("$root/public/js/manager/security.js"), qr/#padlock_key_show[\s\S]{0,300}padlock_key/,
	'and the button opens the key page');
like($key_script, qr/Nothing is locked here\. Unlock the whole house/,
	'the key page offers the house open when its own state is open');

diag("split scripts found: $splits; core entries: " . scalar(@core)
	. "; lazy apps: " . scalar(keys %apps));
done_testing();
