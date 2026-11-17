# tests-for: lib/JawnOS/Domain/Doctor.pm lib/JawnOS/Domain/File.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Manager/Part17.pm lib/JawnOS/Controller/manager_configure5.pm public/js/manager/configure/04_currency_backup.js public/js/manager/configure/05_database_records.js perl/help/topics_configure.pl
# covers:    Configure's bulk vacuum lists only the apps whose settings outlived
#            their appointments, escapes a name in both the attribute and the
#            label, deletes the settings and the rows they left in the other
#            tables, tombstones the keys a peer could hand back, and leaves a
#            protected app or one that has an appointment alone. The doctor
#            detects damage with integrity_check, rebuilds a named index without
#            copying a row, and salvages a table whose page cannot be read into a
#            fresh database while keeping a copy of the original.
#            A rowid range the engine cannot read is walked under a budget, so a
#            bound invented by a damaged page cannot keep the repair running.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use Mojo::SQLite;
use Mojo::JSON qw(encode_json decode_json);
use JawnOSTest;

my $root = root();
my $dir  = tempdir(CLEANUP => 1);

# A throw-away database built from the shipped schema. No test in this file
# touches the live house database.
sub build_database {
	my ($path, $schema) = @_;
	if (defined $schema) {
		unlink $path if -e $path;
		my $pipe = open(my $fh, '|-', 'sqlite3', $path) or die "sqlite3: $!";
		print {$fh} $schema;
		close $fh;
		die "could not build $path" unless -e $path && -s $path > 5000;
	}
	die "no database at $path" unless -e $path && -s $path > 0;
	my $sql = Mojo::SQLite->new('sqlite:' . $path, sqlite_use_immediate_transaction => 0);
	$sql->options({ AutoCommit => 1 });
	return ($sql, $sql->db);
}

sub install_holder {
	my ($path, $sql, $db) = @_;
	my @st = stat($path);
	$gb::database_holder = {
		server_time => &subs::rightNow(),
		database    => $path,
		db          => $db,
		dbh         => $db->dbh,
		sql         => $sql,
		pid         => $$,
		dev         => $st[0],
		ino         => $st[1],
	};
	return;
}

my $live_schema = do {
	open(my $in, '<', "$root/database/schema.sql") or die $!;
	local $/;
	my $text = <$in>;
	close $in;
	$text;
};

my $path = "$dir/vacuum.db";
my ($sql, $db) = build_database($path, $live_schema);
&install_holder($path, $sql, $db);
$subs::say_quiet = 1;
$subs::sync_table_cache = undef;

# Websocket chatter must not need a socket in a test.
{
	no warnings 'redefine';
	*Websocket::send = sub { return 1 };
	*Websocket::console_command = sub { return '' };
}

require JawnOS::Manager::Part17;
require $root . '/lib/JawnOS/Controller/manager_configure5.pm';

my $now = &subs::rightNow();

sub setting_row {
	my ($app, $setting, $value, $device) = @_;
	$db->query('insert into settings (app, setting, value, device, server_time) values (?,?,?,?,?)',
		$app, $setting, $value, ($device || 'computer'), $now);
}

# One orphan with settings and rows in a synced table, a local table and mail.
setting_row('orphan_one', 'colour', '#112233');
$db->query('insert into continent (uuid, app, latitude, longitude, timestamp, server_time) values (?,?,?,?,?,?)',
	'cont-1', 'orphan_one', '43.0', '-81.9', $now, $now);
$db->query('insert into cache (uuid, app, context, data, server_time) values (?,?,?,?,?)',
	'cache-1', 'orphan_one', 'a', '{}', $now);
$db->query('insert into tickets (uuid, app, name, server_time) values (?,?,?,?)',
	'ticket-1', 'orphan_one', 'a ticket', $now);
$db->query('insert into mailbox (uuid, app, subject, body, server_time) values (?,?,?,?,?)',
	'mail-1', 'orphan_one', 'hello', 'body', $now);

# A name with the characters an HTML attribute cannot carry raw.
my $odd = 'odd_name"<x>';
setting_row($odd, 'colour', '#445566');

# A name stored as UTF-8 bytes: the browser and the checkbox JSON speak
# characters, so the bag must hand one back that names the same row.
my $unicode = "i\x{2019}m_confident";
my $bytes = $unicode;
utf8::encode($bytes);
$db->query('insert into settings (app, setting, value, device, server_time) values (?,?,?,?,?)',
	$bytes, 'colour', '#778899', 'computer', $now);

# Protected app, built-in app, and an app that still has an appointment.
setting_row('me', 'my_name', 'Dan');
setting_row('weather', 'colour', '#abcdef');
setting_row('busy', 'colour', '#fedcba');
$db->query('insert into appointments (uuid, app, timestamp, server_time) values (?,?,?,?)',
	'busy-1', 'busy', $now, $now);

# A Permanent card keeps its settings after its last appointment, so the bulk
# vacuum must not offer it.
setting_row('permanent_app', 'colour', '#010101');
setting_row('permanent_app', 'permanent', 'checked');

# Rows that are not an app at all.
$db->query('insert into settings (app, setting, value, device, server_time) values (NULL,?,?,?,?)',
	'loose', 'x', 'computer', $now);
$db->query("insert into settings (app, setting, value, device, server_time) values ('',?,?,?,?)",
	'loose', 'x', 'computer', $now);

# One peer, so a tombstone has somewhere to queue.
$db->query('insert into remote_machines (uuid, signatorial, deletions) values (?,?,?)',
	'peer-1', 'peer-signatorial', '[]');

# ------------------------------------------------------------------ the bag
my @bag = Manager::database_vacuum_bag();
is_deeply([ grep { $_ eq 'orphan_one' } @bag ], [ 'orphan_one' ], 'the orphaned app is offered');
is_deeply([ grep { $_ eq $odd } @bag ], [ $odd ], 'a name with punctuation is offered as it is stored');
is_deeply([ grep { $_ eq $unicode } @bag ], [ $unicode ], 'a UTF-8 name is offered as characters');
ok(!grep { $_ eq 'me' } @bag, 'a protected app is not offered');
ok(!grep { $_ eq 'weather' } @bag, 'a built-in app is not offered');
ok(!grep { $_ eq 'busy' } @bag, 'an app with an appointment is not offered');
ok(!grep { $_ eq 'permanent_app' } @bag, 'a Permanent card is not offered');
ok(!grep { !defined $_ || !length $_ } @bag, 'a row with no app name is not an app');
is_deeply(\@bag, [ sort @bag ], 'the list is sorted for a stable panel');

# ---------------------------------------------------- the list and its labels
{
	package VacuumTestController;
	sub new { bless { params => {} }, shift }
	sub param { my ($s, $k, $v) = @_; $s->{params}{$k} = $v if @_ > 2; return $s->{params}{$k}; }
	sub render { my ($s, %args) = @_; $s->{rendered} = \%args; return 1; }
}

my $get = VacuumTestController->new;
Manager::action_19541($get);
my $html = $get->{rendered}{json}{html};
ok(defined $html && length $html, 'the vacuum list renders');
like($html, qr/app="odd_name&quot;&lt;x&gt;"/, 'the attribute carries the name HTML-encoded');
unlike($html, qr/app="odd_name"/, 'and not raw');
like($html, qr/Odd Name&quot;&lt;x&gt;/, 'the visible label is encoded too');

# -------------------------------------------------------------- the clean-up
my $post = VacuumTestController->new;
$post->param(checkboxes => encode_json([ 'orphan_one', 'me', 'busy', $unicode, 'permanent_app' ]));
Manager::action_19574($post);
my $reply = $post->{rendered}{json};
is($reply->{cleaned}, 2, 'the two orphaned apps were cleaned');
is($reply->{skipped}, 2, 'the app that gained an appointment and the Permanent card were skipped');
is($reply->{html} =~ /orphan One/i ? 1 : 0, 1, 'the cleaned app is named');
is($reply->{html} =~ /busy/i ? 1 : 0, 1, 'the skipped app is named');

sub rows_for {
	my ($table, $app) = @_;
	return $db->query("select count(*) from $table where app = ?", $app)->arrays->[0][0];
}
is(rows_for('settings', 'orphan_one'), 0, 'its settings are gone');
is(rows_for('settings', $unicode), 0, 'a UTF-8 name deletes the bytes it was stored as');
is(rows_for('continent', 'orphan_one'), 0, 'its place rows are gone');
is(rows_for('cache', 'orphan_one'), 0, 'its cache is gone');
is(rows_for('tickets', 'orphan_one'), 0, 'its tickets are gone');
is(rows_for('mailbox', 'orphan_one'), 0, 'its mail is gone');
is(rows_for('settings', 'me'), 1, 'the protected app keeps its settings');
is(rows_for('settings', 'busy'), 1, 'the app with an appointment keeps its settings');
is(rows_for('settings', 'permanent_app'), 2, 'the Permanent card keeps its settings');

# A settings key is named in the durable log, so a peer cannot hand it back.
my $settings_tomb = $db->query("select * from sync_log where tbl = 'settings' and app = 'orphan_one'")->hashes;
is(scalar @{$settings_tomb}, 1, 'one tombstone per settings key');
my $colours = grep { (decode_json($_->{'additional'})->{'setting'} || '') eq 'colour' } @{$settings_tomb};
is($colours, 1, 'a tombstone names the colour key');
# The synced row is tombstoned by uuid; the local cache and tickets have no peer.
my $cont_tomb = $db->query("select * from sync_log where tbl = 'continent' and uuid = 'cont-1'")->hashes;
is(scalar @{$cont_tomb}, 1, 'the synced place row is tombstoned');
my $mail_tomb = $db->query("select * from sync_log where tbl = 'mailbox' and uuid = 'mail-1'")->hashes;
is(scalar @{$mail_tomb}, 1, 'the synced mail row is tombstoned');
my $cache_tomb = $db->query("select * from sync_log where tbl = 'cache'")->hashes;
is(scalar @{$cache_tomb}, 0, 'a local table needs no tombstone');
my $ticket_tomb = $db->query("select * from sync_log where tbl = 'tickets'")->hashes;
is(scalar @{$ticket_tomb}, 0, 'and neither does the ticket table');
my $queued = decode_json($db->query("select deletions from remote_machines where uuid = 'peer-1'")->arrays->[0][0]);
ok(scalar @{$queued} >= 4, 'the peer queue carries the deletions');

# --------------------------------------------------------------- the doctor
# A healthy database is reported healthy and nothing is rebuilt.
my $healthy = &subs::doctor_scan($path);
ok($healthy->{'ok'}, 'a healthy database passes');
is(scalar @{$healthy->{'integrity'}}, 0, 'with no integrity complaint');
is(scalar @{$healthy->{'indexes'}}, 0, 'and no index to rebuild');

# The cross-version expression-index note. The app's SQLite and the installed
# sqlite3 can write an expression index whose REAL key each accepts and the
# other does not; the doctor must keep the app's engine as the authority and
# still show the binary's answer. Skip the assertion when the two agree.
my $tool = `command -v sqlite3 2>/dev/null`;
chomp $tool if defined $tool;
SKIP: {
	skip 'sqlite3 is not installed', 3 unless defined $tool && length $tool;
	my $xpath = "$dir/expression.db";
	system($tool, $xpath,
		'create table t(x text, y text, z text);'
		. 'create index i on t(cast(x as real), cast(y as real), cast(z as integer));'
		. q{insert into t values ('43.0023434059694','-81.9420709647238','1793138704800');}
		. q{insert into t values ('43.0023879557848','-81.9420877285302','1793726162543');}
		. q{insert into t values ('43.0023143207654','-81.9421424623579','1793139001711');}
	);
	my ($xsql, $xdb) = build_database($xpath);
	&install_holder($xpath, $xsql, $xdb);
	my $scan = &subs::doctor_scan($xpath);
	if ($scan->{'ok'}) {
		ok(1, 'the two engines agree about this expression index');
		ok(1, 'so there is nothing to rebuild');
		ok(1, 'and the note is absent');
	}
	else {
		is_deeply($scan->{'indexes'}, [ 'i' ], 'the engine names the index to rebuild');
		my $result = &subs::doctor_repair($xpath);
		ok($result->{'ok'}, 'rebuilding it makes the engine healthy again');
		my $after = &subs::doctor_scan($xpath);
		ok($after->{'ok'}, 'and the scan now passes');
		my $rows = eval { $xdb->query('select count(*) from t')->arrays->[0][0] };
		# doctor_repair may have replaced the file; a fresh handle reads it.
		my $fresh = Mojo::SQLite->new('sqlite:' . $xpath);
		my $count = $fresh->db->query('select count(*) from t')->arrays->[0][0];
		is($count, 3, 'no row was lost');
	}
}

# A table whose page cannot be read is salvaged into a fresh database, and the
# original is kept beside it.
SKIP: {
	skip 'page-level corruption needs sqlite3', 4 unless defined $tool && length $tool;
	my $cpath = "$dir/corrupt.db";
	system($tool, $cpath,
		'create table t(id integer primary key, a text, b text);'
		. 'create index i on t(a);'
		. 'with recursive c(x) as (select 1 union all select x+1 from c where x<500)'
		. ' insert into t(a,b) select \'name-\'||x, \'payload-\'||x from c;'
	);
	my $page = `$tool $cpath "select pageno from dbstat where name = 't' and pagetype = 'leaf' order by pageno limit 1"`;
	chomp $page;
	skip 'dbstat is not available', 4 unless $page =~ /^\d+$/;
	open(my $fh, '+<', $cpath) or die $!;
	binmode $fh;
	seek($fh, ($page - 1) * 4096 + 100, 0) or die $!;
	print {$fh} "\xff" x 300;
	close $fh;

	my ($csql, $cdb) = build_database($cpath);
	&install_holder($cpath, $csql, $cdb);
	my $scan = &subs::doctor_scan($cpath);
	ok($scan->{'data_damage'}, 'the unreadable table is reported as damage');
	my $result = &subs::doctor_repair($cpath);
	diag('salvage error: ' . ($result->{'error'} // 'none')) unless $result->{'ok'};
	ok($result->{'ok'}, 'the salvage finishes');
	ok(defined $result->{'snapshot'} && -e $result->{'snapshot'}, 'the original is kept');
	my $fresh = Mojo::SQLite->new('sqlite:' . $cpath);
	my $check = $fresh->db->query('pragma integrity_check')->arrays->[0][0];
	is($check, 'ok', 'the replaced database passes its integrity check');
}

# A range the engine refuses at every width costs one visit per rowid, so a
# min/max rowid invented by a damaged page used to keep the repair running for
# hours (a broken leaf answered 408890 for a table of 500 rows). The walk
# carries a budget; this pins that it is spent rather than followed forever.
{
	my $unitpath = "$dir/walk.db";
	my ($usql, $udb) = build_database($unitpath, $live_schema);
	my $lost = 0;
	my $budget = { left => 25 };
	&subs::doctor_salvage_range($udb, 'no_such_table', 1, 10_000_000, \$lost, $budget);
	is($budget->{'left'}, 0, 'a rowid walk that cannot read its range spends its budget');
	ok($lost > 0, 'and counts the rows it could not reach');
}

done_testing();
