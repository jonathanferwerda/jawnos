# tests-for: lib/JawnOS/Domain/Remote.pm lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Routes/manager_configure2.pm qa/installers/run.sh qa/nightly_build.sh qa/android/run.sh scripts/qa_report.pl scripts/jawnos_deps.pl templates/configure/qa_panel.html.ep public/js/manager/configure/07_qa_nightly.js perl/help/topics_configure.pl
# covers:    Configure -> Plat -> QA shows the last 14 days of QA runs: the
#           installer check (nightly), the weekly build and the emulator run,
#           each an accordion labelled with its cadence and a table per section.
#           A job writes $QA_ROOT/reports/<kind>/<stamp>/report.json and
#           status.txt; the panel reads that directory on the machine that did
#           the work (the same signed hop readiness uses), so a laptop sees the
#           QA box's own reports without anything being synced here. A run that
#           died early still appears with the status it managed, and retention
#           is days, not a count of runs.

use strict;
use warnings;

use FindBin;
use File::Path qw(make_path remove_tree);
use File::Slurp qw(read_file write_file);
use File::Temp ();
use JSON::PP;
use Test::More;

use lib "$FindBin::Bin/../lib";
require "$FindBin::Bin/../perl/subroutines.pl";

my $root = "$FindBin::Bin/..";
my $tmp  = File::Temp::tempdir(CLEANUP => 1);

sub make_run {
	my (%arg) = @_;
	my $dir = "$tmp/$arg{'kind'}/$arg{'stamp'}";
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
like( $emulator, qr/--kind=emulator --schedule=manual/, 'the emulator run reports itself' );
like( $emulator, qr/qa_report failed "\$\*"/, 'and reports a failure, not only a pass' );

my $deps = read_file("$root/scripts/jawnos_deps.pl");
like( $deps, qr/'report-file=s'/, 'the checker takes a report file' );
like( $deps, qr/generated => time/, 'and the report says when it was made' );

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

my $remote = read_file("$root/lib/JawnOS/Domain/Remote.pm");
like( $remote, qr/sub qa_reports_for/, 'the domain sub exists' );
like( $remote, qr/qa_reports\?signatorial=/, 'it hops to the chosen machine over the signed rail' );
like( $remote, qr/qa_nightly_is_off/, 'Off stands the panel down as every other QA card does' );
like( $remote, qr/sub qa_report_kinds/, 'the kinds it lists are named in one place' );

# --- the card ----------------------------------------------------------------

my $panel = read_file("$root/templates/configure/qa_panel.html.ep");
like( $panel, qr/id="qa_reports"/, 'the QA panel has the reports area' );
like( $panel, qr/id="qa_reports_refresh"/, 'with its own refresh' );
like( $panel, qr/14 days/, 'and says how far back it goes' );

my $js = read_file("$root/public/js/manager/configure/07_qa_nightly.js");
like( $js, qr/\$\.getJSON\('\/manager\/configure\/qa_reports'/, 'the script asks the route' );
like( $js, qr/<details class="qa_report"/, 'each run is an accordion' );
like( $js, qr/<table class="qa_report_table"/, 'each section is a table' );
like( $js, qr/qa_report_schedule/, 'the cadence is shown on the accordion' );
like( $js, qr/report\.sections/, 'a job that brings its own sections is rendered' );
like( $js, qr/function qaReportEscape/, 'values are escaped before they reach the DOM' );

my $help = read_file("$root/perl/help/topics_configure.pl");
like( $help, qr/Nightly reports/, 'the help topic describes the card' );

sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

done_testing;
