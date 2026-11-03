# tests-for: scripts/where.pl lib/JawnOS/Routes/ perl/help/
# covers:    the point locator - helper/domain/route resolution, JavaScript and
#           firmware declarations and their bodies, mention lines, the map the
#           output agrees with, and the map-drift report

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# scripts/where.pl prints file:line for one name, so an agent can find a helper
# without reading the 611-line Index.pm or grepping nine parts. These checks pin
# the three lookups an agent actually asks for (helper, domain sub, route), the
# terse and context switches, and the drift report that makes the name map
# self-auditing.

my $root   = "$FindBin::Bin/..";
my $script = "$root/scripts/where.pl";

# The locator records every lookup in the live database. A test that runs it must
# not write into the house ledger; the one test that checks the row turns this off
# for itself and points JAWNOS_WHERE_DB at a fixture.
local $ENV{'JAWNOS_WHERE_LOG_OFF'} = 1;

sub where {
	my @args = @_;
	my $err  = gensym;
	my $pid  = open3(my $in, my $out, $err, $^X, $script, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

# --- a Manager helper -------------------------------------------------------
{
	my ($code, $out) = where('guide_find_target');
	is($code, 0, 'a helper resolves');
	like($out, qr{^Manager::guide_find_target\tlib/JawnOS/Manager/Part29\.pm:(\d+)$}m,
		'named with its part and line');

	my ($line) = $out =~ /:(\d+)$/m;
	my @src = split /\n/, read_file("$root/lib/JawnOS/Manager/Part29.pm");
	like($src[$line - 1], qr/^\s*sub\s+guide_find_target\b/,
		'the line is the sub, not an approximation');
}

# --- a domain sub, with and without its package -----------------------------
for my $name (qw(subs::path_name path_name)) {
	my ($code, $out) = where($name);
	is($code, 0, "$name resolves");
	like($out, qr{lib/JawnOS/Domain/Format\.pm:\d+}, "$name is in Format.pm");
}

# --- --terse keeps only file:line ------------------------------------------
{
	my ($code, $out) = where('--terse', 'path_name');
	is($code, 0, 'terse resolves');
	like($out, qr{^lib/JawnOS/Domain/Format\.pm:\d+\n\z}, 'and prints nothing else');
}

# --- --context shows the lines under the sub -------------------------------
{
	my (undef, $out) = where('--context', 2, 'guide_find_target');
	like($out, qr/\$app = &subs::unformat_name/,
		'the first body lines come with the hit');
}

# --- a route, by action and by path ---------------------------------------
{
	my (undef, $out) = where('action_7408');
	like($out, qr{^Manager::action_7408\tlib/JawnOS/Controller/js_misc\.pm:\d+$}m,
		'a route action resolves to its controller');
	like($out, qr{get /js/manager/app\.js -> action_7408}, 'and names its route');

	(undef, $out) = where('/js/manager/app.js');
	like($out, qr{^route\tlib/JawnOS/Routes/js_misc\.pm:\d+\tget /js/manager/app\.js -> action_7408$}m,
		'a route path resolves to the row');
	like($out, qr{^  action\tlib/JawnOS/Controller/js_misc\.pm:\d+$}m,
		'and to the action body');
}

# --- a help topic, by name --------------------------------------------------
{
	my ($code, $out) = where('gallery');
	is($code, 0, 'a help topic resolves');
	like($out, qr{^help::gallery\tperl/help/topics_apps\.pl:\d+$}m,
		'with the part it is defined in');
	like($out, qr/^  app: gallery$/m, 'and the app it explains');

	(undef, $out) = where('start menu');
	like($out, qr/^help::start_menu\t/m, 'a spaced name resolves like help() does');
}

# --- a file, and the topic that covers it -----------------------------------
{
	my ($code, $out) = where('templates/apps/gallery.html.ep');
	is($code, 0, 'a template resolves to its topic');
	like($out, qr/^named by help::gallery\t/m, 'through the topic that lists it');

	# tasks has a topic but no templates list entry: the app field is the index.
	(undef, $out) = where('templates/apps/tasks.html.ep');
	like($out, qr/^app help::tasks\t/m, 'and through the app field when no list names it');

	(undef, $out) = where('public/js/manager/chat.js');
	like($out, qr/help::chat/, 'an app script resolves the same way');
}

# --- --topics is the whole registry, one line each --------------------------
{
	my ($code, $out) = where('--topics');
	is($code, 0, '--topics lists the registry');
	my @lines = grep { length } split /\n/, $out;
	cmp_ok(scalar @lines, '>=', 70, 'every topic is listed');
	is(scalar(grep { !/^help::[a-z0-9_]+\tperl\/help\/topics_\w+\.pl:\d+$/ } @lines), 0,
		'each line is a topic and its definition line');
}

# --- a JavaScript declaration ---------------------------------------------
{
	my ($code, $out) = where('jawnosAgentsPanel');
	is($code, 0, 'a JS function resolves outside the Perl maps');
	like($out, qr{^jawnosAgentsPanel\tpublic/js/manager/agents\.js:(\d+)$}m,
		'with its script and line');

	my ($line) = $out =~ /agents\.js:(\d+)/;
	my @src = split /\n/, read_file("$root/public/js/manager/agents.js");
	like($src[$line - 1], qr/^\s*function\s+jawnosAgentsPanel\b/,
		'the line is the declaration, not a call');
}

# --- a single declaration brings its body ----------------------------------
{
	my ($code, $out) = where('jawnosAgentsPanel');
	is($code, 0, 'a single JS declaration resolves');
	like($out, qr{^  var panel = \$\('#jawnos_agents'\);$}m,
		'and its first body line arrives by default, dedented');
	like($out, qr{^  \.\.\.$}m, 'a long body is capped and the cut is marked');
	unlike($out, qr{^\s*function\s+jawnosAgentsPanel\b}m,
		'the declaration line is not repeated in the body');

	(undef, $out) = where('--no-body', 'jawnosAgentsPanel');
	is(scalar(grep { /^  / } split /\n/, $out), 0, '--no-body prints no code');

	(undef, $out) = where('--body-lines', 3, 'jawnosAgentsPanel');
	my @body = grep { /^  / } split /\n/, $out;
	is(scalar @body, 4, '--body-lines 3 prints three lines and the cut');

	(undef, $out) = where('--terse', 'jawnosAgentsPanel');
	like($out, qr{^public/js/manager/agents\.js:\d+\n\z}, '--terse still suppresses the body');
}

# --- a short body ends at its brace, not at the cap ------------------------
{
	my (undef, $out) = where('now_ms');
	like($out, qr{^    return epoch_ms \+ \(uint32_t\)\(millis\(\) - epoch_ref\);$}m,
		'the sketch body comes through');
	like($out, qr{^  \}$}m, 'and stops on its closing brace');
	unlike($out, qr{offset_sane}, 'the next function is not pulled in');

	(undef, $out) = where('load_clock_font');
	like($out, qr{^  src = open\(path\)\.read\(\)$}m,
		'a python def brings its body, dedented');
}

# --- a body is opt-in for Perl, and several hits stay locations ------------
{
	my (undef, $out) = where('--body', 'guide_find_target');
	like($out, qr{^  \$opts = \{\} unless ref \$opts eq 'HASH';$}m,
		'--body works for a Perl map hit too, dedented');

	(undef, $out) = where('loop');
	is(scalar(grep { /^  / } split /\n/, $out), 0,
		'several declarations print locations only, not a wall of bodies');
}

# --- a firmware declaration, and no generated tree -------------------------
{
	my ($code, $out) = where('now_ms');
	is($code, 0, 'a sketch function resolves');
	like($out, qr{^now_ms\tjp/alarmclock/alarmclock_01_globals_clock_ble\.ino:\d+$}m,
		'to the sketch that defines it');
	unlike($out, qr{music\.js}, 'a local variable of the same name does not win');
	unlike($out, qr{/\.pio/|/build/}, 'generated trees are not searched');

	(undef, $out) = where('HOUSE_MAX');
	like($out, qr{^HOUSE_MAX\tjp/alarmclock/\S+\.ino:\d+$}m, 'a firmware #define resolves');

	(undef, $out) = where('load_clock_font');
	like($out, qr{^load_clock_font\tjw/tools/face_preview\.py:\d+$}m, 'a firmware tool def resolves');
}

# --- a mention prints the matching line, grep-style ------------------------
{
	my ($code, $out) = where('chat_method_label');
	is($code, 0, 'an undeclared name still resolves');
	like($out, qr{^  public/js/manager/chat\.js:\d+: .*chat_method_label}m,
		'a JS mention comes with its line');
	like($out, qr{^  templates/apps/chat\.html\.ep:\d+: .*chat_method_label}m,
		'and so does a template mention');
}

# --- a fixture: JS const declarations and generated-tree pruning -----------
{
	my $tmp = tempdir(CLEANUP => 1);
	make_path("$tmp/public/js", "$tmp/jw/.pio/build");
	write_file("$tmp/public/js/app.js", <<'JS');
function plainOne() {
}
const probeConst = function (x) {
	return x;
};
JS
	write_file("$tmp/jw/sketch.ino", "void probe_fn() {\n}\n");
	write_file("$tmp/jw/.pio/build/dup.cpp", "void probe_fn() {\n}\n");
	write_file("$tmp/jw/big_model.h", "#define probe_big 1\n" . ('x' x 140000) . "\n");
	write_file("$tmp/public/js/jquery.js", "function probe_vendored() {\n}\n");

	my (undef, $out) = where('--root', $tmp, 'probeConst');
	like($out, qr{^probeConst\tpublic/js/app\.js:3$}m, 'a const-function is a declaration');

	(undef, $out) = where('--root', $tmp, 'probe_fn');
	like($out, qr{^probe_fn\tjw/sketch\.ino:1$}m, 'the sketch that defines it');
	unlike($out, qr{\.pio|dup\.cpp}, 'the build copy is pruned');

	my ($code) = where('--root', $tmp, 'probe_big');
	is($code, 1, 'a generated header over the size cap is skipped');

	($code) = where('--root', $tmp, 'probe_vendored');
	is($code, 1, 'a vendored library is skipped');
}

# --- a name nobody has -----------------------------------------------------
{
	my ($code, $out, $err) = where('no_such_helper_at_all');
	is($code, 1, 'an unknown name exits 1');
	is($out, '', 'and prints no hit');
	like($err, qr/no_such_helper_at_all/, 'and says which name');
}

# --- the printed file agrees with Index.pm ---------------------------------
{
	my $index = read_file("$root/lib/JawnOS/Manager/Index.pm");
	my ($name, $part) = $index =~ /'([A-Za-z_]\w*)'\s*=>\s*'(JawnOS\/Manager\/Part\d+\.pm)'/;
	ok($name && $part, 'Index.pm has an entry to check');

	my ($code, $out) = where('--terse', $name);
	is($code, 0, "$name resolves");
	like($out, qr{\Qlib/$part\E:\d+}, 'to the part the map names');
	unlike($out, qr/map drift/, 'with no drift reported for a healthy map');
}

# --- a map that has drifted is reported, not believed ----------------------
{
	my $tmp = tempdir(CLEANUP => 1);
	make_path("$tmp/lib/JawnOS/Manager");
	write_file("$tmp/lib/JawnOS/Manager/Index.pm", <<'PM');
package JawnOS::Manager::Index;
our %SUB = (
	'mapped_elsewhere' => 'JawnOS/Manager/Part01.pm',
);
1;
PM
	write_file("$tmp/lib/JawnOS/Manager/Part01.pm", "package Manager;\n\nsub other_thing {\n}\n\n1;\n");
	write_file("$tmp/lib/JawnOS/Manager/Part02.pm", "package Manager;\n\nsub mapped_elsewhere {\n}\n\n1;\n");

	my ($code, $out) = where('--root', $tmp, 'mapped_elsewhere');
	is($code, 0, 'a drifted name still resolves');
	like($out, qr{Part02\.pm:3}, 'where the sub really is');
	like($out, qr/map drift: lib\/JawnOS\/Manager\/Part01\.pm/,
		'and the map is named as drifted');

	my (undef, $out2) = where('--root', $tmp, 'other_thing');
	like($out2, qr{Part01\.pm:3}, 'a sub missing from the map is still found');
}

# --- a function in perl/ or scripts/ is in scope ---------------------------
{
	my ($code, $out) = where('coding_prompt');
	is($code, 0, 'a function in perl/ resolves');
	like($out, qr{^coding_prompt\tperl/help\.pl:\d+$}m, 'to the file that defines it');
}

# --- --outline lists a file's declarations ---------------------------------
{
	my ($code, $out) = where('--outline', 'lib/JawnOS/Domain/Format.pm');
	is($code, 0, 'an outline resolves');
	like($out, qr{^\d+\tsub path_name$}m, 'with the line and kind of a declaration');
}

# --- the body has a character budget as well as a line budget --------------
{
	my (undef, $out) = where('--body-chars', 300, 'jawnosAgentsPanel');
	cmp_ok(length($out), '<', 400, 'a small character budget bounds the body');
	like($out, qr{^  \.\.\.$}m, 'and marks the cut');
}

# --- every lookup is recorded, hit and miss --------------------------------
{
	my $dir = tempdir(CLEANUP => 1);
	my $db  = "$dir/where.db";
	require DBI;
	my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
	$dbh->do('create table where_calls (uuid text, machine text, minute text, name text, hit int, hits int, ost text, server_time text)');
	$dbh->disconnect;

	local $ENV{'JAWNOS_WHERE_LOG_OFF'};
	delete $ENV{'JAWNOS_WHERE_LOG_OFF'};
	local $ENV{'JAWNOS_WHERE_DB'} = $db;

	where('jawnosAgentsPanel');
	where('no_such_helper_at_all');

	my $check = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
	my $rows  = $check->selectall_arrayref('select name, hit from where_calls');
	$check->disconnect;
	my %by = map { $_->[0] => $_->[1] } @{$rows};
	is(scalar @{$rows}, 2, 'one row for the hit and one for the miss');
	is($by{'jawnosAgentsPanel'}, 1, 'the declaration is a hit');
	is($by{'no_such_helper_at_all'}, 0, 'the unknown name is a miss');
}

done_testing();
