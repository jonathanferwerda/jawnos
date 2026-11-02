use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::SQLite;
use Mojo::Template;
use RepoSource;

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

# Notes carry a status (open / completed), an existing note's category and status
# can be changed in place through the app's own save route, and a delete marks
# the row instead of removing it so a peer that still holds it learns it is gone.
# Nothing here touches the live database: the migration and the read/write paths
# are proven on a throwaway SQLite file installed as the holder, as in t/74.

# --------------------------------------------------------------- the statuses
is_deeply( [ &subs::notes_status_keys() ], [qw(open completed)],
	'a note is open or completed' );
is( &subs::notes_status_default(), 'open', 'a new note is open' );
is( &subs::notes_status_valid('Completed'), 'completed', 'a status is normalised' );
is( &subs::notes_status_valid('  open '), 'open', 'the value is trimmed' );
is( &subs::notes_status_valid('done'), '', 'an unknown status is refused' );
is( &subs::notes_status_effective(undef), 'open', 'a row written before the column reads as open' );
is( &subs::notes_status_effective('completed'), 'completed', 'a stored status reads back' );
is( &subs::notes_status_label_key('completed'), 'notes.status.completed',
	'a status label is a core string' );
is( &subs::notes_status_label_key('done'), '', 'no label for a refused status' );

my $statuses = &subs::notes_status_list();
is( scalar(@{$statuses}), 2, 'the picker offers both states' );
is( $statuses->[1]{'label'}, &subs::lang('notes.status.completed'),
	'the picker wears the translated label' );

# ------------------------------------------------------- the delete marker
is( &subs::notes_delete_marker(), 'deleting', 'the project delete marker' );
is( &subs::notes_tombstoned('deleting'), 1, 'the marker reads as deleted' );
is( &subs::notes_tombstoned('1790000000000'), 0, 'an ordinary original stamp is not deleted' );
is( &subs::notes_tombstoned(undef), 0, 'a missing marker is not deleted' );

# ------------------------------------- the migration on a pre-status database
my ($fh, $dbfile) = tempfile( 'jawnos-notes-status-XXXXXX', TMPDIR => 1, UNLINK => 1 );
close $fh;
my $sql = Mojo::SQLite->new( 'sqlite:' . $dbfile );
my $db  = $sql->db;
# The notes table as it was before this change: category, but no status.
$db->query('create table notes (uuid text unique, timestamp text, server_time text, '
	. 'app text, device text, text text, ost text, category text)');
my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $dbfile,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};
$subs::say_quiet = 1;
$subs::sync_table_cache = undef;

$db->query( 'insert into notes (uuid, timestamp, server_time, app, device, text, ost, category) '
	. 'values (?,?,?,?,?,?,?,?)',
	'old-note', '1000', '1000', 'notes', '', 'an older note', '1000', '' );

my $migrations = read_file('lib/JawnOS/Domain/Migrations.pm');
my ($status_alter) = $migrations =~ /^[ \t]*"(alter table notes add column status[^"]*)"/mi;
ok( $status_alter, 'the migration list carries the status column' ) or diag('no status ALTER found');
ok( !&subs::migration_already_applied($status_alter), 'an older database is missing the column' );
&subs::db_query($status_alter);
ok( &subs::migration_already_applied($status_alter), 'after the pass the guard skips it' );

my %cols = map { $_->{'name'} => 1 } @{ $db->query('select name from pragma_table_info(?)', 'notes')->hashes || [] };
ok( $cols{'category'}, 'the notes table has a category column' );
ok( $cols{'status'},   'the notes table has a status column' );
ok( $cols{'ost'},      'and the row marker column' );

my $old = &subs::db_query('select status, ost from notes where uuid = ?', 'old-note')->hash;
is( $old->{'status'}, 'open', 'an older row is read as open' );
is( &subs::notes_status_effective($old->{'status'}), 'open', 'and effective agrees' );

# ------------------------------------------- status and category persistence
# The save route writes through db_insert/db_update, the same calls this test
# makes; a new note starts open and Uncategorized.
&subs::db_insert('notes', {
	uuid        => 'new-note',
	app         => 'notes',
	text        => 'fix the leaking tap',
	category    => 'uncategorized',
	status      => &subs::notes_status_default(),
	timestamp   => '2000',
	server_time => '2000',
});
my $saved = &subs::db_query('select text, category, status from notes where uuid = ?', 'new-note')->hash;
is( $saved->{'status'}, 'open', 'a new note is open' );
is( $saved->{'category'}, 'uncategorized', 'and Uncategorized unless a category is chosen' );

# Marking it completed persists exactly as the Coding agent does it.
&subs::db_update('notes', { status => 'completed', server_time => '2100' }, { uuid => 'new-note' });
my $done = &subs::db_query('select status from notes where uuid = ?', 'new-note')->hash;
is( $done->{'status'}, 'completed', 'a status transition persists' );
my %shown = map { $_->{'uuid'} => $_->{'status'} } @{ &subs::notes_category_rows() };
is( $shown{'new-note'}, 'completed', 'the list reads the completed status back' );
is( $shown{'old-note'}, 'open', 'and an older row as open' );

# The per-note editor changes category and status together, through the same
# update the save route performs.
&subs::db_update('notes', {
	text        => 'fix the leaking tap',
	category    => 'jawnos',
	status      => 'open',
	server_time => '2200',
}, { uuid => 'new-note' });
my $edited = &subs::db_query('select text, category, status from notes where uuid = ?', 'new-note')->hash;
is( $edited->{'category'}, 'jawnos', 'category changes on an existing note' );
is( $edited->{'status'}, 'open', 'status changes on an existing note' );
is( $edited->{'text'}, 'fix the leaking tap', 'and the words are untouched' );

# ------------------------------------------------------------ the tombstone
my $before = &subs::rightNow();
my $tombstoned = &subs::notes_tombstone('new-note');
is( $tombstoned, 1, 'the delete route tombstone-marks the row' );
my $gone = &subs::db_query('select uuid, text, ost, server_time from notes where uuid = ?', 'new-note')->hash;
ok( $gone && $gone->{'uuid'}, 'the row is still present after delete' );
is( $gone->{'ost'}, &subs::notes_delete_marker(), 'ost carries the delete marker' );
cmp_ok( (0 + $gone->{'server_time'}), '>=', $before, 'server_time is stamped by the delete' );
is( $gone->{'text'}, 'fix the leaking tap', 'the tombstone keeps the words the row had' );

my %listed = map { $_->{'uuid'} => 1 } @{ &subs::notes_category_rows() };
ok( !$listed{'new-note'}, 'a tombstoned note is not listed' );
ok( $listed{'old-note'}, 'the other notes still are' );

# A repeat delete is a no-op: no fresh stamp, no fresh tombstone.
my $stamp = $gone->{'server_time'};
&subs::db_update('notes', { server_time => '2300' }, { uuid => 'new-note' });
is( &subs::notes_tombstone('new-note'), 1, 'a repeat delete still answers success' );
my $again = &subs::db_query('select ost, server_time from notes where uuid = ?', 'new-note')->hash;
is( $again->{'ost'}, &subs::notes_delete_marker(), 'the marker stays' );
is( $again->{'server_time'}, '2300', 'and a repeat delete does not rewrite the row' );

# ------------------------------------------------------------ the sync path
my $tables = &subs::sync_table_list();
ok( (grep { $_ eq 'notes' } @{ $tables }), 'notes rides the generic sync' );
my $misc3 = read_file('lib/JawnOS/Controller/manager_misc3.pm');
like( $misc3, qr/select rowid as __sync_rowid, \* from/,
	'the sync reader takes every column, so category and status ride along' );
unlike( $misc3, qr/select rowid as __sync_rowid, [^*]/,
	'the sync reader never narrows notes to an explicit column list' );
my $part17 = read_file('lib/JawnOS/Manager/Part17.pm');
like( $part17, qr/&subs::db_insert\(\$q,\$r\)/,
	'the merge writes the whole peer row, columns included' );
like( $part17, qr/&subs::db_update\(\$q,\$r, \{ uuid => \$r->\{'uuid'\} \} \)/,
	'and updates the whole row, columns included' );

# --------------------------------------------------- the route and the app
my $controller = read_file('lib/JawnOS/Controller/manager_misc6.pm');
like( $controller, qr/statuses => &subs::notes_status_list\(\)/,
	'the route hands the template the status picker' );
like( $controller, qr/notes_status_valid\(\s*\$status_param\s*\)/,
	'a save validates the status it was handed' );
like( $controller, qr/\$set\{'status'\} = \$status if defined \$status_param/,
	'an existing note updates its status in place' );
like( $controller, qr/\$set\{'category'\} = \$category if defined \$category_param/,
	'an existing note updates its category in place' );
like( $controller, qr/&subs::notes_tombstone\(\$uuid\)/,
	'the delete route tombstones rather than deleting' );
unlike( $controller, qr/db_delete\('notes'/,
	'and never removes a note row outright' );

# The Guide's search reads the same table; a tombstoned note must not surface
# there either.
my $help = read_file('lib/JawnOS/Controller/manager_help.pm');
like( $help, qr/from notes where text like \? and coalesce\(ost, ''\) != \?/,
	'the Guide search skips tombstoned notes' );

my $template = template_source('notes/notes');
like( $template, qr/class="note_status note_status_<%= \$status %>"/,
	'a note shows its status badge' );
like( $template, qr/class="note_edit note_category_edit"/, 'a note has a category editor' );
like( $template, qr/class="note_edit note_status_edit"/, 'and a status editor' );
like( $template, qr/note_completed/, 'a completed note is marked visibly done' );
like( $template, qr/env\(safe-area-inset-bottom/, 'the composer keeps the safe-area inset' );
like( $template, qr/max-height: 45%/, 'the composer is bounded so it cannot push off-screen' );
unlike( $template, qr/#notes_input_row[^>]*position:\s*absolute/,
	'the composer is not absolutely positioned' );

my $js = js_source('js/manager/notes.js');
like( $js, qr/\.note_category_edit, \.note_status_edit/, 'the app script wires the per-note editor' );
like( $js, qr/status: status/, 'the editor posts the chosen status' );
like( $js, qr/cancel: '\.note_delete, \.note_editor, \.note_edit'/, 'the editor is not dragged' );

# ------------------------------------------------ the labels, all sixteen
my @languages = map { $_->{code} } @language::languages;
is( scalar(@languages), 16, 'the app offers sixteen interface languages' );
my @keys = qw(notes.category.uncategorized notes.status notes.status.open notes.status.completed notes.set_category_status delete);
my @missing;
for my $lang (@languages) {
	for my $key (@keys) {
		my $value = $language::catalog{$lang}{$key};
		push @missing, "$lang/$key"
			unless defined $value && length $value && $value ne $key;
	}
}
is_deeply( \@missing, [], 'every new label has a translation in all sixteen languages' )
	or diag( 'missing: ' . join( ', ', @missing ) );

# -------------------------------------------- and the template still renders
my $rendered = eval {
	Mojo::Template->new( vars => 1, auto_escape => 1, name => 'notes/notes' )->render(
		$template,
		{
			categories => &subs::notes_category_list(),
			statuses   => &subs::notes_status_list(),
			counts     => { uncategorized => 1, jawnos => 1 },
			total      => 2,
			selected   => &subs::notes_category_default(),
			notes      => [
				{ uuid => 'u1', timestamp => '1000', app => 'notes',
				  category => 'jawnos', status => 'completed', text => 'done thing' },
				{ uuid => 'u2', timestamp => '900', app => 'notes',
				  category => 'uncategorized', status => 'open', text => 'open thing' },
			],
		}
	);
};
ok( defined $rendered && length $rendered, 'the Notes template renders' ) or diag($@);
like( $rendered, qr/note_status_completed[^>]*>Completed</, 'the completed badge is drawn' );
like( $rendered, qr/class="note hover note_completed"/, 'the completed row carries its mark' );
like( $rendered, qr/note_status_open[^>]*>Open</, 'the open badge is drawn' );
like( $rendered, qr/>Uncategorized</, 'the Uncategorized label is translated text' );
like( $rendered, qr/<option value="uncategorized" selected/, 'the picker defaults to Uncategorized' );
unlike( $rendered, qr/<%/, 'nothing is left unrendered' );

done_testing();
