# tests-for: scripts/where.pl lib/JawnOS/Routes/ perl/help/
# covers:    the point locator - helper/domain/route resolution, JavaScript and
#           firmware declarations, mention lines, the map the output agrees
#           with, and the map-drift report

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

done_testing();
