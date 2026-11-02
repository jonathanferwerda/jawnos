# tests-for: scripts/web_measures_audit.pl
# covers:    the web-measure audit - the JSON report it prints, --app and --paths
#           with --limit, and that --prune without --apply removes nothing

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;

# The script loads perl/subroutines.pl, which reads ./config.json at compile
# time. That file is gitignored (it holds this machine's host and keys), so a
# fresh clone cannot run this at all - skip with the reason instead of failing.
plan skip_all => 'needs the local config.json (gitignored) to load the app'
	unless -f "$FindBin::Bin/../config.json";

use DBI;
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::JSON qw(decode_json);
use Symbol qw(gensym);

# The audit reads the live house database unless it is told otherwise, and a
# JSON app is fetched unless it is told to read `websites`. So every case here
# runs the script as a child with --root (a throwaway install tree holding a
# fixture jawnos.db) and --stored: no live row and no socket is touched.
#
# The JSON shape is the contract the web picker reads, so a result row's whole
# key set is pinned, not just the value. --prune is the destructive option: the
# case below proves the report-and-write split (without --apply it lists and
# changes nothing).

my $script = "$FindBin::Bin/../scripts/web_measures_audit.pl";
my $root   = tempdir(CLEANUP => 1);
my $db     = "$root/database/jawnos.db";
my $weath  = 'https://example.invalid/weather.json';

my $local_id = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';

sub build_fixture {
	mkdir "$root/database" or die "cannot make $root/database: $!";
	my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, AutoCommit => 1 });
	$dbh->do('CREATE TABLE settings (uuid TEXT, app TEXT, setting TEXT, subsetting TEXT, value TEXT, device TEXT, server_time INTEGER, ost INTEGER)');
	$dbh->do('CREATE TABLE websites (app TEXT, url TEXT, content TEXT, timestamp INTEGER)');
	$dbh->do('CREATE TABLE filler (blob TEXT)');

	my $m = $dbh->prepare('INSERT INTO settings (uuid, app, setting, subsetting, value, device, server_time, ost) VALUES (?, ?, ?, ?, ?, NULL, ?, ?)');
	my $n = 0;
	my $put = sub {
		my ($app, $setting, $subsetting, $value, $when) = @_;
		$m->execute(sprintf('fixture-%03d', ++$n), $app, $setting, $subsetting, $value, $when, $when);
	};

	$put->('weather', 'web', undef, $weath, 10);
	$put->('weather', 'web_format', undef, 'json', 10);
	$put->('weather', 'app_measures', undef,
		'{"temp":{"type":"number","unit":"C"},"humidity":{"type":"number"},"station":{"type":"text"}}', 10);
	$put->('weather', 'web_measure_data', 'temp', '{"path":"current.temp"}', 13);
	$put->('weather', 'web_measure_data', 'humidity', '{"path":"current.humidity"}', 12);
	$put->('weather', 'web_measure_data', 'station', '{"path":"meta.station"}', 11);
	# no app_measures entry - the dead config --prune exists for
	$put->('weather', 'web_measure_data', 'visibility', '{"path":"current.visibility"}', 14);

	$put->('metals', 'web', undef, 'https://example.invalid/metals.json', 10);
	$put->('metals', 'web_format', undef, 'json', 10);
	$put->('metals', 'app_measures', undef, '{"gold":{"type":"number"}}', 10);
	$put->('metals', 'web_measure_data', 'gold', '{"path":"gold.usd"}', 11);

	$put->('forecast', 'web', undef, 'https://example.invalid/forecast.html', 10);
	$put->('forecast', 'web_format', undef, 'html', 10);
	$put->('forecast', 'app_measures', undef, '{"high":{"type":"number"}}', 10);
	$put->('forecast', 'web_measure_data', 'high', '{"selector":".high"}', 11);

	my $site = $dbh->prepare('INSERT INTO websites (app, url, content, timestamp) VALUES (?, ?, ?, ?)');
	$site->execute('weather', $weath,
		'{"current":{"temp":21,"humidity":44},"meta":{"tags":["a","b"],"station":"north"}}', 1700000000);
	$site->execute('metals', 'https://example.invalid/metals.json', '{"gold":{"usd":2400}}', 1700000000);
	$site->execute('forecast', 'https://example.invalid/forecast.html', '<div>High: <span class="high">18</span></div>', 1700000000);

	# database_grabber only dials a file larger than 5000 bytes
	my $big = 'x' x 200;
	$dbh->do('INSERT INTO filler (blob) VALUES (?)', undef, $big) while -s $db <= 6000;

	$dbh->disconnect;
	# the signatorial lookup reads (and heals) these before it ever asks the DB
	for my $file ( "$root/database/.jawnos_signatorial_id", "$root/.jawnos_signatorial_id" ) {
		open my $fh, '>', $file or die "cannot write $file: $!";
		print $fh "$local_id\n";
		close $fh;
	}
	return $db;
}

build_fixture();

sub run_audit {
	my (@args) = @_;
	local $ENV{'HOME'} = $root;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $script, '--root', $root, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

sub report {
	my ($out, $err) = @_;
	my $data = eval { decode_json($out) };
	unless (ref $data eq 'HASH' && ref $data->{'results'} eq 'ARRAY') {
		BAIL_OUT('not a {"results":[...]} report: ' . ($err || $out));
	}
	return $data->{'results'};
}

# rows as the fixture holds them now: a subprocess must not have moved them
sub measure_rows {
	my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 });
	my $n = $dbh->selectrow_array("SELECT count(*) FROM settings WHERE setting = 'web_measure_data'");
	my $vis = $dbh->selectrow_array("SELECT value FROM settings WHERE app = 'weather' AND setting = 'web_measure_data' AND subsetting = 'visibility'");
	$dbh->disconnect;
	return ($n, $vis);
}

# --- the extraction report ---------------------------------------------------
{
	my ($rc, $out, $err) = run_audit('--stored', '--json');
	is($rc, 0, 'the audit runs against a fixture tree') or diag $err;
	my $rows = report($out, $err);
	is(scalar @{$rows}, 6, 'every measure row of every web app is reported');
	is_deeply([ sort map { $_->{'app'} } @{$rows} ], [ sort qw(forecast metals weather weather weather weather) ],
		'every app with a web url is read when none is named');
	my %by = map { $_->{'measure'} => $_ } @{$rows};

	is_deeply([ sort keys %{ $by{'temp'} } ],
		[ sort qw(app measure ok value used path error selector row match within count expr label container value_mode source format url) ],
		'a result row carries the documented key set');

	is($by{'temp'}->{'ok'}, 1, 'a measure whose path resolves succeeds');
	is($by{'temp'}->{'value'}, '21', 'a number measure goes through the number parser');
	is($by{'temp'}->{'expr'}, 'current.temp', 'the JSON path spec is echoed as expr');
	is($by{'temp'}->{'used'}, 'path', 'and says the path was how it was read');
	is($by{'temp'}->{'source'}, 'stored', '--stored read the page from websites');
	is($by{'temp'}->{'format'}, 'json', 'with the app format reported');
	is($by{'temp'}->{'url'}, $weath, 'and the url the app is configured with');

	is($by{'station'}->{'value'}, 'north', 'a text measure keeps its text');

	is($by{'high'}->{'value'}, '18', 'an HTML app is read from the stored page');
	is($by{'high'}->{'used'}, 'selector', 'through its CSS selector');
	is($by{'high'}->{'format'}, 'html', 'with the app format reported');
	is($by{'high'}->{'selector'}, '.high', 'and the selector echoed');

	is($by{'visibility'}->{'ok'}, 0, 'a path the document does not have is a failure');
	is($by{'visibility'}->{'error'}, 'JSON path not found', 'with the extractor error');
	ok(!defined $by{'visibility'}->{'value'}, 'and no value');
}

# --- --app narrows the report ------------------------------------------------
{
	my ($rc, $out, $err) = run_audit('--stored', '--json', '--app', 'metals');
	is($rc, 0, '--app metals runs');
	my $rows = report($out, $err);
	is_deeply([ map { $_->{'measure'} } @{$rows} ], ['gold'], 'only the named app is reported');
	is($rows->[0]->{'value'}, '2400', 'through the same number parser');
}

# --- --paths lists the document's scalar paths -------------------------------
{
	my ($rc, $out, $err) = run_audit('--stored', '--json', '--app', 'weather', '--paths');
	is($rc, 0, '--paths runs');
	my $rows = report($out, $err);
	is(scalar @{$rows}, 5, 'every scalar path in the stored document is listed');
	is_deeply([ map { $_->{'path'} } @{$rows} ],
		[ 'current.humidity', 'current.temp', 'meta.station', 'meta.tags[0]', 'meta.tags[1]' ],
		'in document order, arrays indexed');
	is($rows->[1]->{'value'}, 21, 'a path carries its value');
	is_deeply([ sort keys %{ $rows->[0] } ], [ sort qw(app path value) ],
		'a path row is app/path/value only');

	my ($rc2, $out2) = run_audit('--stored', '--json', '--app', 'weather', '--paths', '--limit', '2');
	my $few = report($out2);
	is(scalar @{$few}, 2, '--limit caps the path list');
	is_deeply([ map { $_->{'path'} } @{$few} ], [ 'current.humidity', 'current.temp' ],
		'and keeps the first paths');

	my ($rc3, $out3) = run_audit('--stored', '--json', '--app', 'weather', '--paths', '--limit', '0');
	is(scalar @{ report($out3) }, 0, '--limit 0 lists nothing');

	my ($rc4, $out4) = run_audit('--stored', '--json', '--app', 'forecast', '--paths');
	my $html = report($out4);
	is(scalar @{$html}, 1, 'an HTML app has no scalar paths to list');
	is($html->[0]->{'error'}, 'not JSON', 'and says why');
}

# --- --prune without --apply lists, and writes nothing -----------------------
{
	my ($before, $before_visibility) = measure_rows();
	is($before, 6, 'the fixture starts with six measure rows');

	my ($rc, $out, $err) = run_audit('--stored', '--json', '--prune');
	is($rc, 0, '--prune runs');
	my $rows = report($out, $err);
	is(scalar @{$rows}, 1, 'only the measure with no app_measures entry is listed');
	is($rows->[0]->{'app'}, 'weather', 'the dead row is named by app');
	is($rows->[0]->{'measure'}, 'visibility', 'and by measure');
	is($rows->[0]->{'prune'}, 1, 'and is marked as a prune finding');
	ok(!exists $rows->[0]->{'pruned'}, 'without --apply it is not marked removed');

	my ($after, $after_visibility) = measure_rows();
	is($after, $before, '--prune without --apply removes no settings row');
	is($after_visibility, $before_visibility, 'and leaves the dead row exactly as it was');

	my ($rc2, $text) = run_audit('--stored', '--prune');
	like($text, qr/^weather\s+visibility\s+would remove \(no app_measures entry\)$/m,
		'the human report says would remove');
	unlike($text, qr/\bremoved\b/, 'and never says a row was removed');
	is(( measure_rows() )[0], $before, 'the text run writes nothing either');

	my ($rc3, $out3) = run_audit('--stored', '--json', '--prune', '--app', 'metals');
	is(scalar @{ report($out3) }, 0, '--app narrows --prune the same way');
	is(( measure_rows() )[0], $before, 'and the fixture still holds all six rows');
}

done_testing();
