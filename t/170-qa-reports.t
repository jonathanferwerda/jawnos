# tests-for: lib/JawnOS/Domain/Remote.pm lib/JawnOS/Domain/Crypt.pm lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Routes/manager_configure2.pm perl/hooks.pl qa/installers/run.sh qa/nightly_build.sh qa/android/run.sh qa/loc_nightly.sh qa/systemd/jawnos-qa-loc.service qa/systemd/jawnos-qa-loc.timer scripts/qa_report.pl scripts/jawnos_deps.pl qa/run.pl templates/configure/qa_panel.html.ep public/js/manager/configure/07_qa_nightly.js perl/help/topics_configure.pl
# covers:    Configure -> Plat -> QA shows the last 14 days of QA runs: the
#           05:00 suite, the 05:30 UX loop and the 06:00 coding night, the
#           installer check (nightly), the line count (nightly), the weekly build
#           and the emulator run, each an accordion labelled with its cadence and
#           a table per section. The line count also draws a trend across the
#           retained runs, above the drawers, with the change since the run
#           before it; a run that wrote a broken report or no count leaves a gap
#           in that trend rather than a zero. A job writes
#           $QA_ROOT/reports/<kind>/<stamp>/report.json and status.txt; the panel
#           reads that directory on the machine that did the work (the same
#           signed hop readiness uses), so a laptop sees the QA box's own reports
#           without anything being synced here. A run that died early still
#           appears with the status it managed, and retention is days, not a
#           count of runs.

use strict;
use warnings;

use FindBin;
use File::Path qw(make_path remove_tree);
use File::Slurp qw(read_file write_file);
use File::Temp ();
use JSON::PP;
use Mojo::Collection;
use Test::More;

use lib "$FindBin::Bin/../lib";
require "$FindBin::Bin/../perl/subroutines.pl";

my $root = "$FindBin::Bin/..";
my $tmp  = File::Temp::tempdir(CLEANUP => 1);

sub make_run {
	my (%arg) = @_;
	my $base = $arg{'root'} || $tmp;
	my $dir = "$base/$arg{'kind'}/$arg{'stamp'}";
	make_path($dir);
	write_file("$dir/status.txt", "$arg{'status'}\n") if $arg{'status'};
	write_file("$dir/report.json", $arg{'report'}) if defined $arg{'report'};
	return $dir;
}

my $installer_doc = JSON::PP->new->canonical->encode({
	ok => 1, metadata_only => 1, generated => 1_793_836_854,
	summary => { missing => 0, outdated => 2, android_missing => 0 },
	modules => [ { name => 'Mojo::SQLite', installed => '3.009', latest => '4.0.0', status => 'outdated' } ],
	debian => [], arch => [], android => [], toolchain => [],
});
my $build_doc = JSON::PP->new->canonical->encode({
	ok => 1, kind => 'build', schedule => 'weekly', title => 'Weekly build',
	status => 'ok', note => '2 step(s)',
	sections => [ { title => 'Steps', columns => [ 'Step', 'Result' ], rows => [ [ 'android', 'ok' ] ] } ],
});

make_run(kind => 'installers', stamp => '20261103T034500Z', status => 'ok',     report => $installer_doc);
make_run(kind => 'installers', stamp => '20261104T034500Z', status => 'failed', report => $installer_doc);
make_run(kind => 'installers', stamp => '20261105T034500Z', status => 'skipped');
make_run(kind => 'build',      stamp => '20261102T030000Z', status => 'ok',     report => $build_doc);
make_run(kind => 'build',      stamp => 'not-a-run',        status => 'ok',     report => $build_doc);

# --- the list the panel is given ---------------------------------------------

my $reports = subs::qa_reports_list({ root => $tmp });
is( scalar @$reports, 4, 'every kind is listed, and only run directories' );
is( $reports->[0]{'stamp'}, '20261105T034500Z', 'newest first across kinds' );
is( $reports->[0]{'kind'}, 'installers', 'the kind travels with the row' );
is( $reports->[0]{'status'}, 'skipped', 'a run that never reached the check keeps its own status' );
ok( !defined $reports->[0]{'report'}, 'and has no report, rather than a made-up one' );
is( $reports->[2]{'stamp'}, '20261103T034500Z', 'the third nightly run' );
is( $reports->[2]{'report'}{'modules'}[0]{'name'}, 'Mojo::SQLite', 'rows survive the trip' );
is( $reports->[3]{'stamp'}, '20261102T030000Z', 'the weekly build is in the same list' );
is( $reports->[3]{'kind'}, 'build', 'labelled as the build' );
is( $reports->[3]{'report'}{'schedule'}, 'weekly', 'and carries the cadence the accordion shows' );
is( scalar @{ subs::qa_reports_list({ root => $tmp, limit => 2 }) }, 2, 'the list is capped for the panel' );

# A status file without a trailing newline, and a run with a broken report:
# neither may take the panel down.
my $odd = "$tmp/emulator/20261102T034500Z";
make_path($odd);
write_file("$odd/status.txt", 'ok');
write_file("$odd/report.json", 'not json at all');
my $with_odd = subs::qa_reports_list({ root => $tmp });
is( $with_odd->[3]{'kind'}, 'emulator', 'a third kind is picked up too' );
is( $with_odd->[3]{'status'}, 'ok', 'a status without a newline still reads' );
ok( !defined $with_odd->[3]{'report'}, 'a broken report is dropped, not fatal' );
ok( ref subs::qa_reports_list({ root => "$tmp/nowhere" }) eq 'ARRAY', 'a machine with no runs answers with an empty list' );

# --- the line-count trend -----------------------------------------------------
# The count is a number per night, so the card draws it across the retained runs.
# A run that never counted (no report, a broken report, no metric) leaves a gap:
# a missing count must not read as zero authored lines.
my $loc_root = File::Temp::tempdir(CLEANUP => 1);
sub loc_doc {
	my ($code, $files) = @_;
	return JSON::PP->new->canonical->encode({
		ok => 1, kind => 'loc', schedule => 'nightly', status => 'ok',
		title => 'Line count', note => "$code authored lines in $files files at abc1234",
		metrics => { authored_code => $code, authored_files => $files },
		sections => [ { title => 'Languages', columns => [ 'Language', 'Files', 'Lines', 'Code' ],
			rows => [ [ 'Perl', $files, $code, $code ] ] } ],
	});
}
make_run(root => $loc_root, kind => 'loc', stamp => '20261103T023000Z', status => 'ok', report => loc_doc(1000, 10));
make_run(root => $loc_root, kind => 'loc', stamp => '20261104T023000Z', status => 'ok', report => loc_doc(1050, 11));
make_run(root => $loc_root, kind => 'loc', stamp => '20261105T023000Z', status => 'ok', report => loc_doc(1040, 11));
make_run(root => $loc_root, kind => 'loc', stamp => '20261106T023000Z', status => 'failed');
make_run(root => $loc_root, kind => 'loc', stamp => '20261107T023000Z', status => 'ok', report => 'not json at all');
make_run(root => $loc_root, kind => 'loc', stamp => '20261108T023000Z', status => 'ok', report => '{"ok":1,"metrics":{}}');

my $loc_reports = subs::qa_reports_list({ root => $loc_root, limit => 2 });
is( $loc_reports->[0]{'kind'}, 'loc', 'the line count is a listed kind' );
is( $loc_reports->[0]{'stamp'}, '20261108T023000Z', 'its runs sort with every other kind' );
is( $loc_reports->[0]{'status'}, 'ok', 'a run whose count failed still carries its status' );

my $trend = subs::qa_reports_trend('loc', { root => $loc_root });
is( scalar @$trend, 3, 'only the runs that counted become a point' );
is( $trend->[0]{'stamp'}, '20261105T023000Z', 'newest first, like the list' );
is( $trend->[0]{'code'}, 1040, 'the authored code count travels' );
is( $trend->[0]{'files'}, 11, 'and the file count with it' );
is( $trend->[0]{'change'}, -10, 'the change is against the run before it' );
is( $trend->[1]{'change'}, 50, 'a growing night reads positive' );
ok( !exists $trend->[2]{'change'}, 'the oldest retained point has nothing to compare with' );
is( scalar @{ subs::qa_reports_trend('loc', { root => $loc_root, trend_limit => 2 }) }, 2,
	'the trend is capped to the retained window' );
is_deeply( subs::qa_reports_trend('loc', { root => "$loc_root/nowhere" }), [], 'a machine with no counts has no trend' );
is_deeply( subs::qa_reports_trend('', { root => $loc_root }), [], 'a trend needs a kind' );

# --- the long trend file outlives the report tree -----------------------------
# One line a night, kept after the 14-day directories prune. The reader prefers
# it, folds a duplicate stamp to the later line, and skips a broken one.
my $long_root = File::Temp::tempdir(CLEANUP => 1);
make_path("$long_root/loc");
my $long_file = "$long_root/loc/trend.jsonl";
write_file($long_file, join('', map { JSON::PP->new->canonical->encode($_) . "\n" } (
	{ stamp => '20260101T023000Z', authored_code => 100, authored_files => 5 },
	{ stamp => '20260102T023000Z', authored_code => 150, authored_files => 6 },
	{ stamp => '20260103T023000Z', authored_code => 140, authored_files => 6 },
	{ stamp => '20260102T023000Z', authored_code => 160, authored_files => 6 },
)) . "{not json}\n");
make_run(root => $long_root, kind => 'loc', stamp => '20260103T023000Z',
	status => 'ok', report => loc_doc(999, 9));

my $long = subs::qa_reports_trend('loc', { root => $long_root });
is( scalar @$long, 3, 'one point a night, a repeated stamp folded to one' );
is( $long->[0]{'stamp'}, '20260103T023000Z', 'the long file reads newest first' );
is( $long->[0]{'code'}, 140, 'the long file wins over a report directory' );
is( $long->[0]{'change'}, -20, 'the change is against the night before' );
is( $long->[1]{'code'}, 160, 'a later line corrects that night' );
is( $long->[1]{'change'}, 60, 'and the correction reaches the change column' );
ok( !exists $long->[2]{'change'}, 'the oldest point has nothing to compare with' );
is( scalar @{ subs::qa_reports_trend('loc', { root => $long_root, trend_limit => 2 }) }, 2,
	'the long trend is capped for the card' );

# --- the report writer every job shares --------------------------------------

my $qa_root = File::Temp::tempdir(CLEANUP => 1);
my $steps = "$qa_root/steps.tsv";
write_file($steps, "Step\tResult\tTime\nqemu\tok\t21m\nandroid\tok\t0m10s\n");
my $rc = system($^X, "$root/scripts/qa_report.pl",
	'--kind=build', '--schedule=weekly', '--status=ok', '--title=Weekly build',
	"--table=Steps:$steps", "--root=$qa_root");
is( $rc, 0, 'the writer runs' );
my ($build_dir) = glob("$qa_root/reports/build/*");
ok( defined $build_dir && -d $build_dir, 'it writes one directory per run' );
is( slurp("$build_dir/status.txt"), "ok\n", 'and the status the panel falls back to' );
my $written = eval { decode_json(slurp("$build_dir/report.json")) };
is( $written->{'schedule'}, 'weekly', 'the cadence is stamped on the report' );
is( $written->{'sections'}[0]{'columns'}[0], 'Step', 'the table headings come from the file' );
is( $written->{'sections'}[0]{'rows'}[1][1], 'ok', 'and so do the rows' );

# A job that writes its own document (the installer check) hands it over as
# --base: the generic fields are stamped on, the rows are kept.
my $base = "$qa_root/base.json";
write_file($base, $installer_doc);
system($^X, "$root/scripts/qa_report.pl",
	'--kind=installers', '--schedule=nightly', '--status=ok', '--title=Installer check',
	"--base=$base", "--root=$qa_root");
my ($inst_dir) = glob("$qa_root/reports/installers/*");
my $inst = eval { decode_json(slurp("$inst_dir/report.json")) };
is( $inst->{'kind'}, 'installers', 'the base document is stamped with its kind' );
is( $inst->{'schedule'}, 'nightly', 'and its cadence' );
is( $inst->{'modules'}[0]{'name'}, 'Mojo::SQLite', 'without losing the rows it carried' );

# Retention: an old run of the same kind is dropped on the next write.
make_path("$qa_root/reports/build/20200101T000000Z");
write_file("$qa_root/reports/build/20200101T000000Z/status.txt", "ok\n");
system($^X, "$root/scripts/qa_report.pl", '--kind=build', '--prune-only', "--root=$qa_root");
ok( !-d "$qa_root/reports/build/20200101T000000Z", 'a report older than 14 days is removed' );
ok( -d $build_dir, 'and this week\'s is kept' );

# --- what each job writes ----------------------------------------------------

my $installers = read_file("$root/qa/installers/run.sh");
like( $installers, qr/reports\/installers\/\$STAMP/, 'the installer check writes into the reports tree' );
like( $installers, qr/--kind=installers --schedule=nightly/, 'labelled nightly' );
like( $installers, qr/--base "\$RUN_DIR\/report.json"/, 'by stamping the document the check wrote' );
like( $installers, qr/^KEEP_DAYS=14$/m, 'reports are kept for 14 days' );
like( $installers, qr/-mtime \+"\$KEEP_DAYS"/, 'retention is by age, not a count of runs' );

my $weekly = read_file("$root/qa/nightly_build.sh");
like( $weekly, qr/--kind=build --schedule=weekly/, 'the weekly build labels its run weekly' );
like( $weekly, qr/STEP_TSV/, 'and records one row per step' );
like( $weekly, qr/Installing Android SDK/, 'a component the build had to download fails the run' );

my $emulator = read_file("$root/qa/android/run.sh");
like( $emulator, qr/--kind=emulator --schedule="\$\{QA_SCHEDULE:-manual\}"/,
	'the emulator run reports itself, with the cadence it was started on' );
like( $emulator, qr/qa_report failed "\$\*"/, 'and reports a failure, not only a pass' );

# The 05:00 suite is a job like the others: it publishes through qa_report.pl, so
# the card cannot show the installer, build and emulator runs while the suite,
# the UX loop and the coding night are invisible.
my $suite_job = read_file("$root/qa/run.pl");
like( $suite_job, qr/--kind=suite/, 'the nightly suite labels its run suite' );
like( $suite_job, qr/--schedule=nightly/, 'on the nightly cadence' );
like( $suite_job, qr/--title=Nightly suite/, 'with the title the card shows' );
like( $suite_job, qr/'--table=' \. \$_/, 'a table per layer and for the budgets' );
like( $suite_job, qr/JAWNOS_QA_ROOT/, 'the report goes to the QA root the unit names' );
my $publishes = () = $suite_job =~ /publish_panel_report\(/g;
is( $publishes, 2, 'and both the full run and the l0-only exit publish it' );
like( $suite_job, qr/return 0 if .*\$opt->\{'source'\}.*'head'.*'worktree'/,
	'a coding-night gate run (--source worktree) publishes no suite report' );
my $guard_at = index($suite_job, "eq 'worktree'");
my $writer_at = index($suite_job, "'--kind=suite'");
ok( $guard_at >= 0 && $writer_at > $guard_at,
	'the skip comes before the writer, so a default head run still publishes' );

my $deps = read_file("$root/scripts/jawnos_deps.pl");
like( $deps, qr/'report-file=s'/, 'the checker takes a report file' );
like( $deps, qr/generated => time/, 'and the report says when it was made' );

# The line count is a job like the others: it publishes through qa_report.pl, so
# the panel renders it with no branch of its own, and it always says which tree
# it counted.
my $loc_job = read_file("$root/qa/loc_nightly.sh");
like( $loc_job, qr/--kind=loc --schedule=nightly/, 'the line count labels its run nightly' );
like( $loc_job, qr/loc\.pl" --json/, 'it counts with the locator script' );
like( $loc_job, qr/--note "\$note" --stamp "\$STAMP"/, 'every run carries a note and its stamp' );
like( $loc_job, qr/rev-parse --short HEAD/, 'the note names the commit it counted' );
like( $loc_job, qr/\+dirty/, 'and marks a checkout with edits nobody committed' );
like( $loc_job, qr/--table "Languages:\$TSV" --metrics "\$METRICS"/,
	'one row per language, and the metrics the trend reads' );
like( $loc_job, qr/QA_ROOT=\$\{QA_ROOT:-\$HOME\/jawnos-qa\}/, 'the root is explicit and overridable' );
like( $loc_job, qr/STAMP=\$\{STAMP:-/, 'a rehearsal can pin the stamp' );
like( $loc_job, qr/GIT_OPTIONAL_LOCKS=0/, 'a read-only checkout is not refreshed' );
like( $loc_job, qr/-mtime \+"\$KEEP_DAYS"/, 'its run dirs age out on the same 14 days' );
like( $loc_job, qr/trend\.jsonl/, 'it appends the long history the card reads' );
like( $loc_job, qr/>> "\$TREND"/, 'the long history is appended, never pruned' );

my $loc_unit  = read_file("$root/qa/systemd/jawnos-qa-loc.service");
my $loc_timer = read_file("$root/qa/systemd/jawnos-qa-loc.timer");
like( $loc_unit, qr/Environment=QA_ROOT=\/home\/jawn\/jawnos-qa/,
	'the service writes where the panel reads' );
like( $loc_unit, qr/ExecCondition=.*qa\/device_target\.pl/, 'it runs on the chosen machine only' );
like( $loc_unit, qr/ExecStart=\/bin\/sh .*qa\/loc_nightly\.sh/, 'it starts the count' );
like( $loc_unit, qr/ReadWritePaths=\/home\/jawn\/jawnos-qa/, 'and writes only the QA root' );
like( $loc_timer, qr/OnCalendar=\*-\*-\* 02:30:00/, 'nightly at 02:30, before the build lane' );
like( $loc_timer, qr/Unit=jawnos-qa-loc\.service/, 'the timer starts that service' );

# --- the route the panel calls -----------------------------------------------

my $routes = read_file("$root/lib/JawnOS/Routes/manager_configure2.pm");
like( $routes, qr{'/manager/configure/qa_reports',\s*'action_\d+'}, 'the reports have a route' );

my $controller = read_file("$root/lib/JawnOS/Controller/manager_configure2.pm");
like( $controller, qr/sub action_50008/, 'and an action' );
like( $controller, qr/qa_reports_for\(\$c->param\('target'\)/, 'which asks for the chosen machine' );
like( $controller, qr/peer_verify\(\$c, \$rm\)/, 'a peer is verified, as readiness is' );
like( $controller, qr/authentication'\) eq 'approved'/, 'a person must be signed in' );

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like( $loader, qr/qa_reports_for/, 'the domain sub is registered in the loader' );
like( $loader, qr/\bqa_reports_trend\b/, 'and so is the trend it draws' );

my $remote = read_file("$root/lib/JawnOS/Domain/Remote.pm");
like( $remote, qr/sub qa_reports_for/, 'the domain sub exists' );
like( $remote, qr/qa_reports\?signatorial=/, 'it hops to the chosen machine over the signed rail' );
like( $remote, qr/sub qa_hop_answer\b/, 'a refused hop is told apart from a silent one' );
like( $remote, qr/qa_hop_answer\(\$res, 'that machine did not answer the report request'/,
	'the reports hop uses it' );
like( $remote, qr/qa_nightly_is_off/, 'Off stands the panel down as every other QA card does' );
like( $remote, qr/sub qa_report_kinds/, 'the kinds it lists are named in one place' );
like( $remote, qr/qw\(suite ux coding installers security loc build emulator\)/,
	'the core nightly jobs come first, then the installer, audit, count, build and emulator' );
is_deeply( [ subs::qa_coding_lanes_known() ], [ qw(notes ux security installers) ],
	'the UX findings lane is offered in canonical order' );
like( $remote, qr/trend => &qa_reports_trend\('loc'/, 'the card is handed the trend with the drawers' );

# --- the peer lookup the QA reads share ---------------------------------------
# Dev learns the Laptop through the hub's mirror blob, not as a direct roster
# row. The reports, readiness and schedule routes must find it there, and a
# mirror with no key must not become an unsigned first contact.

my $hub = { signatorial => 'hub', mirrors => encode_json([
	{ signatorial => 'laptop', pubkey => 'MIRROR KEY' },
	{ signatorial => 'keyless' },
]) };
my $direct_same = { signatorial => 'laptop', pubkey => 'DIRECT KEY' };

is( subs::peer_roster_row_in('laptop', [ $direct_same, $hub ])->{'pubkey'}, 'DIRECT KEY',
	'a direct roster row wins over a mirror' );
is( subs::peer_roster_row_in('laptop', [ $hub ])->{'pubkey'}, 'MIRROR KEY',
	'a mirror the hub listed is a usable peer' );
ok( !defined subs::peer_roster_row_in('keyless', [ $hub ]),
	'a mirror with no key is not proof and is refused' );
my $keyless_direct = { signatorial => 'laptop' };
is( subs::peer_roster_row_in('laptop', [ $keyless_direct, $hub ])->{'pubkey'}, 'MIRROR KEY',
	'a direct row that lost its key takes the hub copy' );
ok( !defined subs::peer_roster_row_in('nobody', [ $hub ]), 'an unknown caller still resolves to nothing' );
my $collection = Mojo::Collection->new($hub);
is( subs::peer_roster_row_in('laptop', $collection)->{'pubkey'}, 'MIRROR KEY',
	'a blessed collection from db_select->hashes is accepted' );
ok( !defined subs::peer_roster_row_in('laptop', [ { signatorial => 'hub', mirrors => 'not json' } ]),
	'a broken mirror blob is ignored, not fatal' );

# A Gate page is a refusal, not a timeout: the panel must name the pairing fix.
{
	package QAAnswerFake;
	sub new { my ($class, $body) = @_; return bless { body => $body }, $class; }
	sub body { return $_[0]->{'body'}; }
}
is( subs::qa_hop_answer(QAAnswerFake->new('{"ok":1,"reports":[]}'), 'fallback', 'dev')->{'ok'}, 1,
	'a JSON answer is returned as it came' );
is( subs::qa_hop_answer(QAAnswerFake->new('{"ok":0,"error":"not signed in"}'), 'fallback', 'dev')->{'error'}, 'not signed in',
	'a JSON refusal keeps the reason the peer gave' );
my $gate = subs::qa_hop_answer(QAAnswerFake->new('<title>Gate</title>'), 'that machine did not answer the report request', 'dev');
is( $gate->{'ok'}, 0, 'a Gate page is a refusal' );
like( $gate->{'error'}, qr/not paired/, 'and says the machine has to be paired, not that it did not answer' );
is( subs::qa_hop_answer(undef, 'that machine did not answer the report request', 'dev')->{'error'},
	'that machine did not answer the report request', 'a real no-answer keeps the action wording' );

# --- the card ----------------------------------------------------------------

my $panel = read_file("$root/templates/configure/qa_panel.html.ep");
like( $panel, qr/id="qa_reports"/, 'the QA panel has the reports area' );
like( $panel, qr/id="qa_reports_refresh"/, 'with its own refresh' );
like( $panel, qr/14 days/, 'and says how far back it goes' );
like( $panel, qr/line count/, 'the card copy names the line count' );
like( $panel, qr/trend across those runs/, 'and the trend it draws' );

my $js = read_file("$root/public/js/manager/configure/07_qa_nightly.js");
like( $js, qr/\$\.getJSON\('\/manager\/configure\/qa_reports'/, 'the script asks the route' );
like( $js, qr/<details class="qa_report"/, 'each run is an accordion' );
like( $js, qr/<table class="qa_report_table"/, 'each section is a table' );
like( $js, qr/qa_report_schedule/, 'the cadence is shown on the accordion' );
like( $js, qr/report\.sections/, 'a job that brings its own sections is rendered' );
like( $js, qr/function qaReportEscape/, 'values are escaped before they reach the DOM' );
like( $js, qr/function qaReportTrend/, 'the line-count trend has its own renderer' );
like( $js, qr/qaReportTrend\(r\.trend\)/, 'drawn from the trend the route returns' );
like( $js, qr/Since the previous run/, 'the change column names what it compares with' );
like( $js, qr/\\u2014/, 'a point with no earlier run shows a dash, not a zero' );
like( $js, qr/entry\.kind === 'installers'/, 'the package wording is scoped to the installer kind' );
unlike( $js, qr/!bits\.length && entry\.report\)\s*\{/,
	'so a count or emulator run never borrows it' );

my $help = read_file("$root/perl/help/topics_configure.pl");
like( $help, qr/Nightly reports/, 'the help topic describes the card' );
like( $help, qr/line count/, 'and names the count among the nightly runs' );

sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

done_testing;
