# tests-for: scripts/where_audit.pl scripts/where.pl lib/JawnOS/Domain/Run.pm lib/JawnOS/Domain/Migrations.pm
# covers:    the locator's audit - misses, wrong reports, map drift, the near
#           leads a miss left behind, the JSON shape, the Coding agent's task
#           brief and the strict exit.

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

# --- the leads a miss printed, and whether one was followed ----------------
{
	my $ldir = tempdir(CLEANUP => 1);
	my $ldb  = "$ldir/where.db";
	my $ldbh = DBI->connect("dbi:SQLite:dbname=$ldb", '', '', { RaiseError => 1, PrintError => 0 });
	$ldbh->do('create table where_calls (uuid text, machine text, minute text, name text, hit int, hits int, context text, ost text, server_time text)');
	$ldbh->do('create table where_feedback (uuid text, call_uuid text, machine text, minute text, name text, verdict text, selected text, found text, note text, ost text, server_time text)');
	$ldbh->do("insert into where_calls (uuid,machine,minute,name,hit,hits,context) values ('l1','me',?,?,0,0,?)",
		undef, $minute, 'lead_missed', '{"near":["good_sub","ghost_sub"]}');
	$ldbh->do("insert into where_calls (uuid,machine,minute,name,hit,hits) values ('l2','me',?,'good_sub',1,1)", undef, $minute);
	$ldbh->do("insert into where_calls (uuid,machine,minute,name,hit,hits,context) values ('l3','me',?,?,0,0,?)",
		undef, $minute, 'cold_missed', '{"near":["ghost_sub"]}');
	$ldbh->disconnect;

	my ($lcode, $lout) = run_audit('--db', $ldb, '--root', $tree, '--days', 14);
	is($lcode, 0, 'a ledger with leads still exits 0');
	like($lout, qr/NEAR LEADS/, 'the report has a lead section');
	like($lout, qr/1 of 2 led somewhere/, 'counting the leads that were followed');
	like($lout, qr/lead_missed\s+offered good_sub, ghost_sub · followed good_sub/,
		'and naming the lead the next lookup used');
	like($lout, qr/cold_missed\s+offered ghost_sub\s*$/m, 'while a cold lead has no followed name');

	my (undef, $ljson) = run_audit('--db', $ldb, '--root', $tree, '--days', 14, '--json');
	my $ldata = decode_json($ljson);
	is($ldata->{'leads'}{'offered'}, 2, 'the JSON counts the misses that offered a lead');
	is($ldata->{'leads'}{'followed'}, 1, 'and how many led somewhere');
	my ($follower) = grep { $_->{'name'} eq 'lead_missed' } @{ $ldata->{'leads'}{'rows'} };
	is_deeply($follower->{'followed'}, ['good_sub'], 'with the name that was used');

	my (undef, $lbrief) = run_audit('--db', $ldb, '--root', $tree, '--days', 14, '--prompt');
	like($lbrief, qr/NEAR LEADS nobody followed/, 'the brief raises the lead nobody used');
	like($lbrief, qr/cold_missed offered ghost_sub/, 'with the names it offered');
	unlike($lbrief, qr/lead_missed offered/, 'and leaves out the one that was followed');
}

# --- a flag lookup is not a name to cover ----------------------------------
{
	my $fdir = tempdir(CLEANUP => 1);
	my $fdb  = "$fdir/where.db";
	my $fdbh = DBI->connect("dbi:SQLite:dbname=$fdb", '', '', { RaiseError => 1, PrintError => 0 });
	$fdbh->do('create table where_calls (uuid text, machine text, minute text, name text, hit int, hits int, context text, ost text, server_time text)');
	$fdbh->do('create table where_feedback (uuid text, call_uuid text, machine text, minute text, name text, verdict text, selected text, found text, note text, ost text, server_time text)');
	$fdbh->do("insert into where_calls (uuid,machine,minute,name,hit,hits) values ('g1','me','$minute','--topics probe',0,0)");
	$fdbh->do("insert into where_calls (uuid,machine,minute,name,hit,hits) values ('g2','me','$minute','real_miss',0,0)");
	$fdbh->disconnect;

	my ($code, $out) = run_audit('--db', $fdb, '--root', $tree, '--days', 14);
	is($code, 0, 'a ledger with a flag row still exits 0');
	like($out, qr/MISSES/ , 'the report still has its miss section');
	like($out, qr/real_miss/, 'naming the missed code name');
	unlike($out, qr/--topics probe/, 'but a flag pattern is not a name to cover');

	my (undef, $json) = run_audit('--db', $fdb, '--root', $tree, '--days', 14, '--json');
	my $data = decode_json($json);
	is($data->{'summary'}{'calls'}, 2, 'the JSON still counts every lookup');
	ok(!(grep { $_->{'name'} =~ /^--/ } @{ $data->{'misses'} }),
		'while its misses hold only names');

	my (undef, $brief) = run_audit('--db', $fdb, '--root', $tree, '--days', 14, '--prompt');
	unlike($brief, qr/--topics probe/, 'and the brief does not send an agent to cover a flag');
}

# --- a context byte that is not UTF-8 does not break the JSON -------------
{
	my $udir = tempdir(CLEANUP => 1);
	my $udb  = "$udir/where.db";
	my $udbh = DBI->connect("dbi:SQLite:dbname=$udb", '', '', { RaiseError => 1, PrintError => 0 });
	$udbh->do('create table where_calls (uuid text, machine text, minute text, name text, hit int, hits int, context text, ost text, server_time text)');
	$udbh->do('create table where_feedback (uuid text, call_uuid text, machine text, minute text, name text, verdict text, selected text, found text, note text, ost text, server_time text)');
	# A byte string with no UTF-8 flag, as where.pl used to write a caller's
	# command line verbatim. The app decodes the report with JSON::PP->utf8, so
	# one lone 0xC2 here turned every scheduled run into "invalid JSON".
	$udbh->do(
		'insert into where_calls (uuid,machine,minute,name,hit,hits,context) values (?,?,?,?,?,?,?)',
		undef, 'u1', 'me', $minute, 'probe_name', 1, 1,
		'{"parent":"probe ' . pack('C', 0xC2) . ' tail"}',
	);
	$udbh->disconnect;

	my ($code, $out) = run_audit('--db', $udb, '--root', $tree, '--days', 14, '--json');
	is($code, 0, 'the audit still runs');
	unlike($out, qr/\xC2(?![\x80-\xBF])/, 'emitting no lone 0xC2 byte');
	my $data = eval { decode_json($out) };
	ok(ref $data eq 'HASH', 'and the app can decode the report as UTF-8');
}


# --- a miss the locator answered later stops being a gap -------------------
{
	my $rdir = tempdir(CLEANUP => 1);
	my $rdb  = "$rdir/where.db";
	my $rdbh = DBI->connect("dbi:SQLite:dbname=$rdb", '', '', { RaiseError => 1, PrintError => 0 });
	$rdbh->do('create table where_calls (uuid text, machine text, minute text, name text, hit int, hits int, context text, ost text, server_time text)');
	$rdbh->do('create table where_feedback (uuid text, call_uuid text, machine text, minute text, name text, verdict text, selected text, found text, note text, ost text, server_time text)');
	my $later = strftime('%Y-%m-%d %H:%M', localtime(time + 60));
	$rdbh->do("insert into where_calls (uuid,machine,minute,name,hit,hits) values ('r1','me',?,'resolved_name',0,0)", undef, $minute);
	$rdbh->do("insert into where_calls (uuid,machine,minute,name,hit,hits) values ('r2','me',?,'resolved_name',1,2)", undef, $later);
	$rdbh->do("insert into where_calls (uuid,machine,minute,name,hit,hits) values ('r3','me',?,'stale_name',1,1)", undef, $minute);
	$rdbh->do("insert into where_calls (uuid,machine,minute,name,hit,hits) values ('r4','me',?,'stale_name',0,0)", undef, $later);
	$rdbh->do("insert into where_calls (uuid,machine,minute,name,hit,hits) values ('r5','me',?,'only_miss',0,0)", undef, $minute);
	$rdbh->disconnect;

	my ($code, $out) = run_audit('--db', $rdb, '--root', $tree, '--days', 14);
	is($code, 0, 'the report still exits 0');
	unlike($out, qr/resolved_name/, 'a name with a later hit is no longer a miss');
	like($out, qr/stale_name/, 'a name that missed again after its hit is still one');
	like($out, qr/only_miss/, 'and so is a name that never hit');

	my (undef, $json) = run_audit('--db', $rdb, '--root', $tree, '--days', 14, '--json');
	my $data = decode_json($json);
	my @names = map { $_->{'name'} } @{ $data->{'misses'} };
	ok(!(grep { $_ eq 'resolved_name' } @names), 'the JSON drops the resolved name');
	ok((grep { $_ eq 'stale_name' } @names), 'and keeps the one that missed again');
	ok((grep { $_ eq 'only_miss' } @names), 'and the one that never hit');

	my (undef, $brief) = run_audit('--db', $rdb, '--root', $tree, '--days', 14, '--prompt');
	unlike($brief, qr/resolved_name/, 'and the brief does not send an agent to cover it');
}

done_testing();
