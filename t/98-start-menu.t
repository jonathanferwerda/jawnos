# tests-for: templates/start_menu/start_menu.html.ep public/js/manager/manager/05_start_menu.js
# covers:    the running list lists open sessions only, and Internet is the one web entry point

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use DBI;
use File::Slurp qw(read_file);
use JawnOSTest;

# The running list is built straight in the template. It used to take every
# `start`/`record` row, so a row a stop had already sealed (type=start,
# stop_seen=yes - the shape a stop/start race left behind) stayed on the menu
# forever. The query under test is lifted from the template itself and run
# against throwaway fixtures, so it is the shipped SQL that is pinned, not a
# copy. Nothing here touches the live database.

my $template = read_file(root() . '/templates/start_menu/start_menu.html.ep');

# The Web app is a component of Internet now; the start menu offers Internet
# alone, so two icons cannot open the same pages from different places.
unlike($template, qr/id="web_toggle"/, 'no separate Web icon in the start menu');
like($template, qr/id="internet_toggle"/, 'Internet is the one web entry point');
my $menu_js = read_file(root() . '/public/js/manager/manager/05_start_menu.js');
unlike($menu_js, qr/web_toggle/, 'the start menu no longer maps a Web icon');

my ($run_sql) = $template =~ /if \(\$menu eq 'run'\) \{\s*\$query = &subs::db_query\('([^']+)'/s;
ok(defined $run_sql, 'the run list has its own query');

like($run_sql, qr/\(\s*type=\?\s+or\s+type=\?\s*\)/,
	'the run list looks at start and record sessions');
like($run_sql, qr/stop_seen\s+is\s+null/,
	'the run list only lists a session that no stop has sealed');

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
	{ RaiseError => 1, PrintError => 0, AutoCommit => 1 });
$dbh->do('create table appointments (app text, type text, timestamp integer, stop_seen text)');

my $now = 1_790_000_000_000;
my $insert = $dbh->prepare(
	'insert into appointments (app, type, timestamp, stop_seen) values (?, ?, ?, ?)');

$insert->execute('brushing', 'start', $now - 60_000, undef);   # running now
$insert->execute('toothpaste', 'start', $now - 50_000, 'yes'); # a stop sealed it, the row still says start
$insert->execute('shower', 'record', $now - 40_000, 'yes');    # a sealed recording, same shape
$insert->execute('later', 'start', $now + 60_000, undef);      # begins in the future
$insert->execute('shower', 'stop', $now - 30_000, 'yes');      # an ordinary stop row
$insert->execute('toothpaste', 'usual', $now - 20_000, undef); # the usual template is not a session

my $rows = $dbh->selectall_arrayref($run_sql, undef, 'start', 'record', $now);
my @apps = map { $_->[0] } @{ $rows || [] };

is_deeply(\@apps, ['brushing'],
	'only the session still running is listed; a sealed start row is not');


like($template, qr/id="keyboard_toggle"/, 'the keyboard is a start-menu app');
like($template, qr/id="calculator_toggle"/, 'and the calculator');

done_testing();
