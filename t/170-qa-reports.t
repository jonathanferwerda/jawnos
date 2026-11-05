# tests-for: lib/JawnOS/Domain/Remote.pm lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Routes/manager_configure2.pm qa/installers/run.sh templates/configure/qa_panel.html.ep public/js/manager/configure/07_qa_nightly.js perl/help/topics_configure.pl scripts/jawnos_deps.pl
# covers:    Configure -> Plat -> QA shows the last 14 days of nightly runs. A
#           run writes report.json and status.txt beside its log; the panel reads
#           that directory on the machine that did the work (the same signed hop
#           readiness uses), so a laptop sees the QA box's own reports without
#           anything being synced here. A run that died before the check still
#           appears with the status it managed, and the retention is days, not
#           a count of runs.

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

# --- the list the panel is given ---------------------------------------------

my $tmp = File::Temp::tempdir(CLEANUP => 1);

sub make_run {
	my (%arg) = @_;
	my $dir = "$tmp/$arg{'stamp'}";
	make_path($dir);
	write_file("$dir/status.txt", "$arg{'status'}\n") if $arg{'status'};
	write_file("$dir/report.json", $arg{'report'}) if defined $arg{'report'};
	return $dir;
}

my $good = JSON::PP->new->canonical->encode({
	ok => 1, metadata_only => 1, generated => 1_793_836_854,
	summary => { missing => 0, outdated => 2, android_missing => 0 },
	modules => [ { name => 'Mojo::SQLite', installed => '3.009', latest => '4.0.0', status => 'outdated' } ],
	debian  => [],
	arch    => [],
});

make_run(stamp => '20261103T034500Z', status => 'ok',     report => $good);
make_run(stamp => '20261104T034500Z', status => 'failed', report => $good);
make_run(stamp => '20261105T034500Z', status => 'skipped');
make_run(stamp => 'not-a-run', status => 'ok', report => $good);   # ignored

my $reports = subs::qa_reports_list({ root => $tmp });
is( scalar @$reports, 3, 'only run directories are listed' );
is( $reports->[0]{'stamp'}, '20261105T034500Z', 'newest first' );
is( $reports->[1]{'stamp'}, '20261104T034500Z', 'then the one before' );
is( $reports->[0]{'status'}, 'skipped', 'a run that never reached the check keeps its own status' );
ok( !defined $reports->[0]{'report'}, 'and has no report, rather than a made-up one' );
is( $reports->[1]{'status'}, 'failed', 'a failed run says failed' );
	is( $reports->[1]{'report'}{'ok'}, 1, 'the report is handed over whole' );
is( $reports->[2]{'report'}{'modules'}[0]{'name'}, 'Mojo::SQLite', 'rows survive the trip' );
is( scalar @{ subs::qa_reports_list({ root => $tmp, limit => 2 }) }, 2, 'the list is capped for the panel' );

# A status file written without a trailing newline, and a run with a broken
# report: neither may take the panel down.
my $odd = "$tmp/20261102T034500Z";
make_path($odd);
write_file("$odd/status.txt", 'ok');
write_file("$odd/report.json", 'not json at all');
my $with_odd = subs::qa_reports_list({ root => $tmp });
is( $with_odd->[3]{'status'}, 'ok', 'a status without a newline still reads' );
ok( !defined $with_odd->[3]{'report'}, 'a broken report is dropped, not fatal' );
ok( ref subs::qa_reports_list({ root => "$tmp/nowhere" }) eq 'ARRAY', 'a machine with no runs answers with an empty list' );

# --- what the run writes and how long it is kept -----------------------------

my $script = read_file("$root/qa/installers/run.sh");
like( $script, qr/--report-file "\$RUN_DIR\/report\.json"/, 'the run writes its report beside the log' );
like( $script, qr/status\.txt/, 'and the one-word status the panel falls back to' );
like( $script, qr/^KEEP_DAYS=14$/m, 'reports are kept for 14 days' );
like( $script, qr/-mtime \+"\$KEEP_DAYS"/, 'retention is by age, not by a count of runs' );
unlike( $script, qr/awk -v keep="\$KEEP"/, 'the old 14-run cap is gone' );

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

# --- the card ----------------------------------------------------------------

my $panel = read_file("$root/templates/configure/qa_panel.html.ep");
like( $panel, qr/id="qa_reports"/, 'the QA panel has the reports area' );
like( $panel, qr/id="qa_reports_refresh"/, 'with its own refresh' );
like( $panel, qr/14 days/, 'and says how far back it goes' );

my $js = read_file("$root/public/js/manager/configure/07_qa_nightly.js");
like( $js, qr/\$\.getJSON\('\/manager\/configure\/qa_reports'/, 'the script asks the route' );
like( $js, qr/<details class="qa_report"/, 'each run is an accordion' );
like( $js, qr/<table class="qa_report_table"/, 'each section is a table' );
like( $js, qr/function qaReportEscape/, 'values are escaped before they reach the DOM' );
like( $js, qr/qaT\('Perl modules \(CPAN\)'\)/, 'the sections are named as the log names them' );

my $help = read_file("$root/perl/help/topics_configure.pl");
like( $help, qr/Nightly reports/, 'the help topic describes the card' );

done_testing;
