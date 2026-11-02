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

# A note is filed under one of six categories. Nothing here touches the live
# database: the migration and the read path are proven on a throwaway SQLite file
# this test creates and installs as the holder, the way t/14-warranty.t does.

# ------------------------------------------------------------- the six, once
my @codes = &subs::notes_category_keys();
is_deeply( \@codes, [qw(journal roadmap social shopping dreams jawnos)],
	'the six categories, in chip order' );
my @filter = &subs::notes_category_filter_keys();
is_deeply( \@filter, [qw(uncategorized journal roadmap social shopping dreams jawnos)],
	'the filter shows Uncategorized plus the six categories' );
is( &subs::notes_category_default(), 'uncategorized',
	'a note with no other home is Uncategorized, never silently Journal' );
my %seen;
is( scalar( grep { $seen{$_}++ } @filter ), 0, 'no filter value is listed twice' );

# ------------------------------------------------- the labels are core strings
# Every category label and every hand-off button is a core interface string, so it
# must be written in all sixteen languages rather than falling back to English.
my @languages = map { $_->{code} } @language::languages;
is( scalar(@languages), 16, 'the app offers sixteen interface languages' );

my @keys = ( 'notes.category', 'notes.all', 'delete' );
push @keys, map { "notes.category.$_" } @filter;
push @keys, qw(notes.status notes.status.open notes.status.completed notes.set_category_status);
push @keys, map { "notes.open.$_" } qw(store market handbook people);

for my $key (@keys) {
	my $en = $language::catalog{'en'}{$key};
	ok( defined $en && length $en && $en ne $key, "English names $key" );
}

my @missing;
for my $lang (@languages) {
	for my $key (@keys) {
		my $value = $language::catalog{$lang}{$key};
		push @missing, "$lang/$key"
			unless defined $value && length $value && $value ne $key;
	}
}
is_deeply( \@missing, [], 'every label has a translation in all sixteen languages' )
	or diag( 'missing: ' . join( ', ', @missing ) );

# ------------------------------------------------------- what a row reads back
is( &subs::notes_category_valid('Shopping'), 'shopping', 'a code is normalised' );
is( &subs::notes_category_valid('  dreams '), 'dreams', 'the value is trimmed' );
is( &subs::notes_category_valid('Diary'), '', 'a label is not a code' );
is( &subs::notes_category_valid(undef), '', 'nothing is no category' );

is( &subs::notes_category_effective( undef, 'notes' ), 'uncategorized',
	'a note that names no category reads as Uncategorized' );
is( &subs::notes_category_effective( '', '' ), 'uncategorized',
	'a note with no app at all reads as Uncategorized' );
is( &subs::notes_category_effective( undef, 'home' ), '',
	'an appointment draft has no category of its own' );
is( &subs::notes_category_effective( 'dreams', 'home' ), 'dreams',
	'a stored category wins over the app it came from' );
is( &subs::notes_category_effective( 'journal', 'notes' ), 'journal',
	'an old row the backfill stamped keeps reading as Journal' );
is( &subs::notes_category_effective( 'garbage', 'notes' ), 'uncategorized',
	'an unknown stored value reads as the default, never as a missing label' );

is( &subs::notes_category_label_key('social'), 'notes.category.social',
	'a row label is a core string' );
is( &subs::notes_category_label_key('uncategorized'), 'notes.category.uncategorized',
	'Uncategorized is a core string too' );
is( &subs::notes_category_label_key('garbage'), '', 'no label for a refused code' );

# ------------------------------------------------------------------ hand-offs
is( &subs::notes_category_target('roadmap'),  'store',    'Roadmap opens Store' );
is( &subs::notes_category_target('shopping'), 'market',   'Shopping opens Market' );
is( &subs::notes_category_target('social'),   'people',   'Social opens People' );
is( &subs::notes_category_target('dreams'),   'handbook', 'Dreams opens the Handbook\'s Today' );
is( &subs::notes_category_target('journal'),  '',         'Journal stays in Notes' );
is( &subs::notes_category_target('jawnos'),   '',         'JawnOS stays in Notes as the nightly queue' );
is( &subs::notes_category_target('nonsense'), '',         'an unknown category opens nothing' );

my $list = &subs::notes_category_list();
is( scalar(@{$list}), 7, 'the chips are Uncategorized plus the six categories' );
is( $list->[0]{'code'}, 'uncategorized', 'Uncategorized is the first chip' );
is( $list->[0]{'label'}, &subs::lang('notes.category.uncategorized'), 'the Uncategorized chip wears the core label' );
is( $list->[1]{'label'}, &subs::lang('notes.category.journal'), 'a chip wears the core label' );
is( $list->[2]{'target'}, 'store', 'the Roadmap chip carries its hand-off' );
is( $list->[2]{'open_label'}, &subs::lang('notes.open.store'), 'the hand-off button is translated too' );
is( $list->[0]{'open_label'}, '', 'Uncategorized has no hand-off button' );
is( $list->[1]{'open_label'}, '', 'Journal has no hand-off button' );

# ------------------------------------- the migration on a pre-category database
my ($fh, $dbfile) = tempfile( 'jawnos-notes-XXXXXX', TMPDIR => 1, UNLINK => 1 );
close $fh;
my $sql = Mojo::SQLite->new( 'sqlite:' . $dbfile );
my $db  = $sql->db;
# The notes table as it was before this change: no category column.
$db->query('create table notes (uuid text unique, timestamp text, server_time text, '
	. 'app text, device text, text text, ost text)');
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

$db->query( 'insert into notes (uuid, timestamp, server_time, app, device, text) values (?,?,?,?,?,?)',
	'old-typed', '1000', '1000', 'notes', '', 'a note typed before categories existed' );
$db->query( 'insert into notes (uuid, timestamp, server_time, app, device, text) values (?,?,?,?,?,?)',
	'old-watch', '2000', '2000', '', '', 'a note the watch filed' );
$db->query( 'insert into notes (uuid, timestamp, server_time, app, device, text) values (?,?,?,?,?,?)',
	'old-draft', '3000', '3000', 'home', '', 'the half-typed notes field of an appointment' );

my $migrations = read_file('lib/JawnOS/Domain/Migrations.pm');
my ($alter) = $migrations =~ /^[ \t]*'(alter table notes add column category[^']*)'/mi;
ok( $alter, 'the migration list carries the category column' ) or diag('no ALTER found');

ok( !&subs::migration_already_applied($alter), 'an older database is missing the column' );
&subs::db_query($alter);
ok( &subs::migration_already_applied($alter),
	'after the pass the guard skips it, so a second pass is not run' );

my ($backfill) = $migrations =~ /^[ \t]*"(update notes set category[^"]*)"/mi;
ok( $backfill, 'the migration list carries the backfill' ) or diag('no UPDATE found');
&subs::db_query($backfill);

# The status column arrives with the same table and the read path selects it.
my ($status_alter) = $migrations =~ /^[ \t]*"(alter table notes add column status[^"]*)"/mi;
ok( $status_alter, 'the migration list carries the status column' ) or diag('no status ALTER found');
ok( !&subs::migration_already_applied($status_alter), 'the older database is missing the status column' );
&subs::db_query($status_alter);
ok( &subs::migration_already_applied($status_alter), 'the status column is applied once' );

my %stored = map { $_->{'uuid'} => $_->{'category'} } @{ $db->query('select uuid, category from notes')->hashes };
is( $stored{'old-typed'}, 'journal', 'an older typed note is stamped as a journal note' );
is( $stored{'old-watch'}, 'journal', 'a note the watch filed is stamped the same way' );
is( $stored{'old-draft'}, undef, 'an appointment draft is left uncategorised' );

# ------------------------------------------------- the app's own read path
my %shown = map { $_->{'uuid'} => $_->{'category'} } @{ &subs::notes_category_rows() };
is( $shown{'old-typed'}, 'journal', 'the list reads an older note as a journal note' );
is( $shown{'old-draft'}, '', 'the list shows a draft under no category' );

# A note saved with a category survives a re-read, through the same insert the
# save route uses.
&subs::db_insert('notes', {
	uuid => 'new-note',
	app => 'notes',
	text => 'two pairs of shoes',
	category => 'shopping',
	timestamp => '4000',
	server_time => '4000',
});
my $kept = &subs::db_query('select category from notes where uuid = ?', 'new-note')->hash;
is( $kept->{'category'}, 'shopping', 'a note keeps the category it was saved under' );

my $rows = &subs::notes_category_rows();
my %again = map { $_->{'uuid'} => $_->{'category'} } @{ $rows };
is( $again{'new-note'}, 'shopping', 'and the app reads it back as that category' );

my ($counts, $total) = &subs::notes_category_counts($rows);
is( $total, 4, 'every note counts toward All' );
is( $counts->{'shopping'}, 1, 'Shopping counts its one note' );
is( $counts->{'journal'}, 2, 'the two older plain notes count as Journal' );
is( $counts->{'dreams'}, 0, 'an empty category counts zero' );
is( scalar( grep { $counts->{$_} } keys %{$counts} ), 2,
	'a draft counts toward All and toward no category' );

# ------------------------------- the route and the template still agree
my $controller = read_file('lib/JawnOS/Controller/manager_misc6.pm');
like( $controller, qr/sub action_22702\b/, 'the Notes route action is unchanged' );
like( $controller, qr/notes_category_rows\(\)/, 'the route reads rows through the category helper' );
like( $controller, qr/categories => &subs::notes_category_list\(\)/,
	'the route hands the template the chips' );
like( $controller, qr/counts => \$counts/, 'the route hands the template the counts' );
like( $controller, qr/notes_category_valid\(\s*\$category_param\s*\)/,
	'a save validates the category it was handed' );

my $template = template_source('notes/notes');
like( $template, qr/class="notes_chip"/, 'the chips are on screen' );
like( $template, qr/id="notes_category"/, 'the picker is on screen' );
like( $template, qr/class="notes_category_open"/, 'the hand-off button is on screen' );
like( $template, qr/category="<%= \$n->\{'category'\} %>"/,
	'each row carries its own category' );
like( $template, qr/subs::lang\( 'notes\.category\.' \. \$n->\{'category'\} \)/,
	'a row label goes through the core catalog' );
like( $template, qr/subs::lang\('notes\.all'\)/, 'the All chip is a core label' );

my $js = js_source('js/manager/notes.js');
like( $js, qr/function notesCategoryApply/, 'the filter is applied by the app script' );
like( $js, qr/notesCategoryFilter/, 'the chosen category outlives a refresh of the list' );
like( $js, qr/appWindowOpener\(target/, 'Store, Market and People open through the window opener' );
like( $js, qr/handbookGrabber\('today'\)/, 'Dreams opens the Handbook on Today' );
like( $js, qr/category: \$\('#notes_category'\)\.val\(\)/, 'a save names its category' );

# ------------------------------------- and the template draws what it promises
# Source greps cannot catch a template that no longer compiles, so render it the
# way the window does: one note, the chips, and the picker.
my $rendered = eval {
	Mojo::Template->new( vars => 1, auto_escape => 1, name => 'notes/notes' )->render(
		$template,
		{
			categories => &subs::notes_category_list(),
			statuses   => &subs::notes_status_list(),
			counts     => { journal => 1 },
			total      => 1,
			selected   => &subs::notes_category_default(),
			notes      => [ {
				uuid => 'u1', timestamp => '1000', app => 'notes',
				category => 'journal', status => 'open', text => 'hello <world>',
			} ],
		}
	);
};
ok( defined $rendered && length $rendered, 'the Notes template renders' ) or diag($@);

my @chips = $rendered =~ /class="notes_chip"/g;
is( scalar(@chips), 8, 'All plus Uncategorized and the six categories are drawn' );
like( $rendered, qr/note_status note_status_open/, 'a note wears its open status badge' );
like( $rendered, qr/class="note_edit note_category_edit"/, 'each note has a category editor' );
like( $rendered, qr/class="note_edit note_status_edit"/, 'and a status editor' );
my @opens = $rendered =~ /class="notes_category_open"/g;
is( scalar(@opens), 4, 'only the four categories that live elsewhere get a hand-off button' );
like( $rendered, qr/class="note_category"[^>]*>Journal</, 'a note wears its category label' );
like( $rendered, qr/id="notes_category"/, 'the picker is drawn' );
like( $rendered, qr/hello &lt;world&gt;/, 'note text is escaped as it was before' );
unlike( $rendered, qr/<%/, 'nothing is left unrendered' );

done_testing();
