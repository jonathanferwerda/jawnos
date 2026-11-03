# tests-for: scripts/where_audit.pl scripts/where.pl lib/JawnOS/Domain/Run.pm lib/JawnOS/Domain/Migrations.pm
# covers:    the locator's audit - misses, wrong reports, map drift, the JSON
#           shape, the Coding agent's task brief and the strict exit.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Path qw(make_path);
use File::Slurp qw(write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use JSON::PP;
use POSIX qw(strftime);
use Symbol qw(gensym);
use Test::More;

my $root   = "$FindBin::Bin/..";
my $script = "$root/scripts/where_audit.pl";

sub run_audit {
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

my $dir  = tempdir(CLEANUP => 1);
my $db   = "$dir/where.db";
my $tree = "$dir/tree";
make_path("$tree/lib/JawnOS/Manager", "$tree/lib/JawnOS/Domain", "$tree/public/js");

write_file("$tree/lib/JawnOS/Manager/Index.pm", <<'PM');
package JawnOS::Manager::Index;
our %SUB = (
	'drifted_name' => 'JawnOS/Manager/Part01.pm',
	'healthy_name' => 'JawnOS/Manager/Part01.pm',
);
1;
PM
write_file("$tree/lib/JawnOS/Manager/Part01.pm", "package Manager;\n\nsub healthy_name {\n}\n\n1;\n");
write_file("$tree/lib/JawnOS/Domain/Loader.pm", <<'PM');
package JawnOS::Domain::Loader;
our %DOMAIN_MODULE = ();
$DOMAIN_MODULE{$_} = 'JawnOS::Domain::Format' for qw(good_sub missing_sub);
1;
PM
write_file("$tree/lib/JawnOS/Domain/Format.pm", "package JawnOS::Domain::Format;\n\nsub good_sub {\n}\n\n1;\n");
# Two JavaScript declarations of the same name: the locator returns both, so a
# report that names one of them is a ranking complaint, not coverage.
write_file("$tree/public/js/a.js", "function multi_probe() {\n}\n");
write_file("$tree/public/js/b.js", "function multi_probe() {\n}\n");

require DBI;
my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
$dbh->do('create table where_calls (uuid text, machine text, minute text, name text, hit int, hits int, context text, ost text, server_time text)');
$dbh->do('create table where_feedback (uuid text, call_uuid text, machine text, minute text, name text, verdict text, selected text, found text, note text, ost text, server_time text)');
my $minute = strftime('%Y-%m-%d %H:%M', localtime);
$dbh->do("insert into where_calls (uuid,machine,minute,name,hit,hits,context) values (?,?,?,?,?,?,?)", undef, 'c1', 'me', $minute, 'missed_name', 0, 0, '{"cwd":"/tmp/probe","args":"missed_name","parent":"sh","grandparent":"zed"}');
$dbh->do("insert into where_calls (uuid,machine,minute,name,hit,hits) values ('c2','me','$minute','good_name',1,1)");
$dbh->do("insert into where_feedback (uuid,machine,minute,name,verdict,found) values ('f1','me','$minute','missed_name','wrong','lib/JawnOS/Domain/Format.pm:140')");
$dbh->do("insert into where_feedback (uuid,machine,minute,name,verdict,selected,found) values ('f2','me','$minute','multi_probe','wrong','public/js/a.js:1','public/js/b.js:1')");
$dbh->do("insert into where_feedback (uuid,machine,minute,name,verdict) values ('f3','me','$minute','good_name','right')");
$dbh->do("insert into where_feedback (uuid,machine,minute,name,verdict,found) values ('f4','me','$minute','miss_probe','miss','lib/JawnOS/Domain/Format.pm:140')");
$dbh->disconnect;

my ($code, $out) = run_audit('--db', $db, '--root', $tree, '--days', 14);
is($code, 0, 'the audit exits 0 by default');
like($out, qr/calls 2/, 'it counts the lookups');
like($out, qr/MISSES/, 'it lists the misses');
like($out, qr/missed_name/, 'naming the missed lookup');
like($out, qr/WRONG/, 'and the wrong report');
like($out, qr/lib\/JawnOS\/Domain\/Format\.pm:140/, 'with the place the agent found');
like($out, qr/\[\w+ \/ coverage\]/, 'classifying a location the locator never returned');
like($out, qr/\[\w+ \/ ranking\]/, 'and a right answer that was among the hits');
like($out, qr/\[miss \/ coverage\]/, 'and a reported miss as coverage');
like($out, qr/cwd \/tmp\/probe/, 'with the context the call was made in');
like($out, qr/via zed/, 'including the agent above the shell');
like($out, qr/MAP DRIFT/, 'and the map drift');
like($out, qr/drifted_name/, 'naming the drifted Index entry');
like($out, qr/missing_sub/, 'and the missing domain entry');

my (undef, $json_out) = run_audit('--db', $db, '--root', $tree, '--days', 14, '--json');
my $data = decode_json($json_out);
is($data->{'summary'}{'calls'}, 2, 'the JSON carries the counts');
is($data->{'summary'}{'hits'}, 1, 'and the hits');
is($data->{'summary'}{'wrong'}, 3, 'and the wrong and missed reports');
my ($ranked) = grep { $_->{'name'} eq 'multi_probe' } @{ $data->{'wrong'} };
is($ranked->{'kind'}, 'ranking', 'the JSON carries the ranking/coverage distinction');
my ($missed) = grep { $_->{'name'} eq 'missed_name' } @{ $data->{'misses'} };
like($missed->{'context_text'}, qr/cwd \/tmp\/probe/, 'the JSON carries the miss context');
ok((grep { $_->{'name'} eq 'missed_name' } @{ $data->{'misses'} }), 'and the missed name');
ok((grep { $_->{'name'} eq 'drifted_name' } @{ $data->{'drift'} }), 'and the drift');

my (undef, $brief) = run_audit('--db', $db, '--root', $tree, '--days', 14, '--prompt');
like($brief, qr/Maintain the locator/, 'the brief names the job');
like($brief, qr/missed_name/, 'and the name to fix');
like($brief, qr/run_tests\.pl/, 'and the check to run');
like($brief, qr/ranking: the right answer/, 'and says what a ranking report means');
like($brief, qr/coverage: the locator did not return it/, 'and what a coverage report means');
like($brief, qr/miss \/ coverage/, 'the brief names the reported miss');
like($brief, qr/cwd \/tmp\/probe/, 'and shows the context it was made in');

my ($strict_code) = run_audit('--db', $db, '--root', $tree, '--days', 14, '--strict');
is($strict_code, 1, '--strict fails when there is anything to fix');

# --since is what the scheduled run uses: the window starts at its last
# successful minute, so a future bound sees no calls but the maps are still read.
my (undef, $since_out) = run_audit('--db', $db, '--root', $tree, '--since', '2099-01-01', '--json');
my $bounded = decode_json($since_out);
is($bounded->{'summary'}{'calls'}, 0, '--since bounds the lookup window');
is($bounded->{'since'}, '2099-01-01', 'and the window is reported');
ok((grep { $_->{'name'} eq 'drifted_name' } @{ $bounded->{'drift'} }),
	'while map drift is still read');

done_testing();
