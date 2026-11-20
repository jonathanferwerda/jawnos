# tests-for: scripts/model_duplicates.pl lib/JawnOS/Controller/manager_store.pm public/js/manager/attributes.js public/js/manager/attributes/01_upload_copy_migration.js perl/help/topics_features.pl
# covers:    a catalogue name is one row: the Add route answers with the existing
#            model instead of minting a twin, the dedupe tool keeps the row the
#            records point at, repoints the rest, and tombstones what it removes
#            so a peer cannot hand the twin back.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use DBI;
use JSON::PP ();
use JawnOSTest;

my $json = JSON::PP->new->utf8;
my $root = root();

# --------------------------------------------------------------- the dedupe tool
my $dir = tempdir(CLEANUP => 1);
my $db  = "$dir/dupes.db";
# The identity beside the database, which is the machine the tombstone must
# name - not the checkout the tool happens to run from.
open(my $idfh, '>', "$dir/.jawnos_signatorial_id") or die "identity: $!";
print $idfh "0123456789abcdef0123456789abcdef\n";
close $idfh;
my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });

$dbh->do(q{create table model (
	app text, name text, price text, characteristics text, timestamp text,
	server_time text, uuid text unique, files text, cost text, description text,
	discount text, markup text, ost text, manufacturer text, def text,
	quantity text, unit text, save_app text, file text, delay_start text,
	delay_stop text, def_month text, def_day text, def_hour text, def_wday text)});
$dbh->do(q{create table option (
	app text, name text, price text, characteristics text, timestamp text,
	server_time text, uuid text unique, files text, cost text, description text,
	discount text, markup text, ost text, manufacturer text, def text,
	quantity text, unit text, save_app text, file text, delay_start text,
	delay_stop text, def_month text, def_day text, def_hour text, def_wday text)});
$dbh->do(q{create table option_category (app text, name text, uuid text)});
$dbh->do(q{insert into option_category (app, name, uuid) values ('coffee', 'brand', 'cat_brand')});
$dbh->do(q{create table appointments (rowid integer primary key, app text,
	model text, item text, option text, options text, server_time text)});
$dbh->do(q{create table sync_log (id integer primary key autoincrement,
	server_time text, signatorial text, tbl text, app text, uuid text,
	scope text, ost text, additional text)});
$dbh->do(q{create table remote_machines (uuid text, signatorial text, deletions text)});

my $add_model = $dbh->prepare(q{insert into model
	(app, name, uuid, timestamp, ost, server_time, save_app, unit, def)
	values (?,?,?,?,?,?,?,?,?)});
$add_model->execute('news', 'global', 'keepglobal', 3000, 3000, 3000, 'on', 'news', 'on');
$add_model->execute('news', 'global', 'dropglobal', 1000, 1000, 1000, '', '', 'off');
$add_model->execute('news', 'cbc', 'keepcbc', 3000, 3000, 3000, '', 'news', 'off');
$add_model->execute('news', 'cbc', 'dropcbc', 1000, 1000, 1000, 'on', '', 'off');
$add_model->execute('other', 'global', 'otherkeep', 3000, 3000, 3000, '', '', 'off');
$add_model->execute('other', 'global', 'otherdrop', 1000, 1000, 1000, '', '', 'off');
$add_model->finish;

my $add_appt = $dbh->prepare(q{insert into appointments (app, model, server_time) values (?,?,?)});
for my $n (1 .. 3) {
	$add_appt->execute('news', $json->encode({ uuid => 'keepglobal', name => 'global', quantity => 1 }), 100);
}
$add_appt->execute('news', $json->encode({ uuid => 'dropglobal', name => 'global', quantity => 1 }), 100);
$add_appt->execute('news', $json->encode({ uuid => 'keepcbc', name => 'cbc', quantity => 1 }), 100);
$add_appt->finish;

my $brand = $json->encode([ { name => 'option_category', uuid => 'char_brand', value => 'cat_brand', timestamp => 1 } ]);
my $other = $json->encode([ { name => 'option_category', uuid => 'char_other', value => 'cat_other', timestamp => 1 } ]);
my $add_option = $dbh->prepare(q{insert into option
	(app, name, uuid, timestamp, ost, server_time, unit, quantity, def, save_app, characteristics)
	values (?,?,?,?,?,?,?,?,?,?,?)});
$add_option->execute('coffee', 'maxwell_house', 'keepopt', 3000, 3000, 3000, 'oz', '10', 'off', '', $brand);
$add_option->execute('coffee', 'maxwell_house', 'dropopt', 1000, 1000, 1000, 'maxwell_house', '', 'off', '', $brand);
$add_option->execute('coffee', 'maxwell_house', 'otheropt', 2000, 2000, 2000, 'oz', '', 'off', '', $other);
$add_option->finish;

my $add_opt_appt = $dbh->prepare(q{insert into appointments (app, options, server_time) values (?,?,?)});
$add_opt_appt->execute('coffee', $json->encode([
	{ uuid => 'keepopt', name => 'maxwell_house', unit => 'oz', quantity => '10' },
	{ uuid => 'sugar', name => 'sugar', unit => 'tsp', quantity => 2 },
]), 100);
$add_opt_appt->execute('coffee', $json->encode([
	{ uuid => 'dropopt', name => 'maxwell_house', unit => 'maxwell_house', quantity => '' },
	{ uuid => 'sugar', name => 'sugar', unit => 'tsp', quantity => 2 },
]), 100);
$add_opt_appt->finish;

$dbh->do(q{insert into remote_machines (uuid, signatorial, deletions) values ('peer1', 'peer1', '[]')});
$dbh->disconnect;

my $script = "$root/scripts/model_duplicates.pl";
sub run_script {
	my @args = @_;
	my $out = qx{$^X "$script" @args 2>&1};
	return ($? >> 8, $out);
}

my ($rc, $out) = run_script("--database=$db", '--app', 'news');
is($rc, 0, 'the dry run exits 0');
like($out, qr/news\/global/, 'and names the duplicated model');
like($out, qr/keepglobal/, 'showing the row it would keep');
like($out, qr/dropglobal/, 'and the row it would drop');
like($out, qr/dry run: nothing changed/, 'and writes nothing');

($rc, $out) = run_script("--database=$db", '--app', 'coffee');
is($rc, 0, 'the option dry run exits 0');
like($out, qr/option coffee\/maxwell_house \[brand\]/, 'an option is keyed by its category, and the category is named');
like($out, qr/keepopt/, 'and names the option row it would keep');
like($out, qr/dropopt/, 'and the one it would drop');

my $count = sub {
	my ($sql, @args) = @_;
	my $h = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
	my $n = $h->selectrow_array($sql, undef, @args) || 0;
	$h->disconnect;
	return $n;
};
is($count->("select count(*) from model where app = 'news'"), 4, 'the dry run left both copies in place');

($rc, $out) = run_script("--database=$db", '--apply', '--no-backup');
is($rc, 1, 'applying every app without naming one is refused');
like($out, qr/refusing to apply every app at once/, 'and says why');
is($count->("select count(*) from model where app = 'news'"), 4, 'the refusal wrote nothing');

($rc, $out) = run_script("--database=$db", '--app=news', '--apply', '--no-backup');
is($rc, 0, 'the app run applies') or diag($out);
like($out, qr/removed 1 row\(s\), repointed 1 record\(s\), left 1 row\(s\) in place/, 'one pair merges, one is left for a person')
	or diag($out);

is($count->("select count(*) from model where uuid = 'dropglobal'"), 0, 'the unconfigured twin is gone');
is($count->("select count(*) from model where uuid = 'keepglobal'"), 1, 'the row the records pointed at is kept');
is($count->("select count(*) from model where app = 'news' and name = 'cbc'"), 2,
	'a pair where the row to drop carries a setting the keeper lacks is left whole');
is($count->("select count(*) from option where app = 'coffee'"), 3,
	"an --app run leaves the other apps' option duplicates alone");

my $dbh2 = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
my @repointed;
for my $raw ( @{ $dbh2->selectcol_arrayref("select model from appointments where app = 'news'") } ) {
	push @repointed, $json->decode($raw);
}
is(scalar(grep { $_->{'uuid'} eq 'keepglobal' } @repointed), 4, 'the record that named the loser now names the keeper');
is(scalar(grep { $_->{'uuid'} eq 'keepcbc' } @repointed) + scalar(grep { $_->{'uuid'} eq 'dropcbc' } @repointed), 1,
	'the refused pair keeps its record untouched');
is($dbh2->selectrow_array("select count(*) from sync_log where tbl = 'model' and uuid = 'dropglobal' and app = 'news' and scope = 'single'"), 1,
	'the removed row leaves a durable tombstone');
is($dbh2->selectrow_array("select signatorial from sync_log where uuid = 'dropglobal'"), '0123456789abcdef0123456789abcdef',
	'signed by the machine that owns the database, not the checkout running the tool');
is($dbh2->selectrow_array("select count(*) from sync_log where uuid in ('keepcbc', 'dropcbc')"), 0, 'the refused pair leaves none');
my ($deletions) = $dbh2->selectrow_array("select deletions from remote_machines where uuid = 'peer1'");
my $queued = $json->decode($deletions);
is(scalar(grep { ($_->{'uuid'} // '') eq 'dropglobal' && ($_->{'table'} // '') eq 'model' } @{$queued}), 1,
	'and the peer rail is queued with it');
is(scalar(grep { ($_->{'uuid'} // '') eq 'dropcbc' } @{$queued}) + scalar(grep { ($_->{'uuid'} // '') eq 'keepcbc' } @{$queued}), 0,
	'while the refused pair is not queued');

($rc, $out) = run_script("--database=$db", '--app=news', '--apply', '--no-backup', '--force');
is($rc, 0, '--force merges the pair a person was left to decide') or diag($out);
is($count->("select count(*) from model where app = 'news' and name = 'cbc'"), 1, 'one cbc row is left');
my ($survivor) = $dbh2->selectrow_array("select uuid from model where app = 'news' and name = 'cbc'");
my ($survivor_refs) = @{ $dbh2->selectcol_arrayref("select model from appointments where model like ?", undef, '%' . $survivor . '%') };
ok($survivor_refs && ($json->decode($survivor_refs)->{'uuid'} // '') eq $survivor,
	'and the cbc record names the row that survived');
is($dbh2->selectrow_array("select count(*) from sync_log where uuid in ('keepcbc', 'dropcbc')"), 1,
	'with a tombstone for the row removed by --force');

# ------------------------------------------------------------------ options
($rc, $out) = run_script("--database=$db", '--app=coffee', '--apply', '--no-backup');
is($rc, 0, 'the option run applies') or diag($out);
is($count->("select count(*) from option where app = 'coffee' and name = 'maxwell_house' and uuid = 'keepopt'"), 1,
	'the option the records point at is kept');
is($count->("select count(*) from option where uuid = 'dropopt'"), 0, 'and its twin is gone');
is($count->("select count(*) from option where uuid = 'otheropt'"), 1,
	'a same-named option in another category is not the same key and is kept');
my @coffee_options = map { $json->decode($_) } @{ $dbh2->selectcol_arrayref("select options from appointments where app = 'coffee' order by rowid") };
is(scalar @coffee_options, 2, 'both coffee records survive');
is($coffee_options[0]->[0]->{'uuid'}, 'keepopt', 'the record that already named the keeper still does');
is($coffee_options[1]->[0]->{'uuid'}, 'keepopt', 'the record that named the option loser now names the keeper');
is($coffee_options[1]->[0]->{'name'}, 'maxwell_house', 'and keeps the name it recorded');
is($coffee_options[1]->[1]->{'uuid'}, 'sugar', 'the other option on that record is untouched');
is($coffee_options[0]->[1]->{'uuid'}, 'sugar', 'and the other record is untouched');
is($dbh2->selectrow_array("select count(*) from sync_log where tbl = 'option' and uuid = 'dropopt' and app = 'coffee' and scope = 'single'"), 1,
	'the option row leaves a durable option tombstone');
my ($deletions_after) = $dbh2->selectrow_array("select deletions from remote_machines where uuid = 'peer1'");
my $queued_after = $json->decode($deletions_after);
is(scalar(grep { ($_->{'uuid'} // '') eq 'dropopt' && ($_->{'table'} // '') eq 'option' } @{$queued_after}), 1,
	'and the peer rail queues the option deletion');
$dbh2->disconnect;

# ------------------------------------------------- the Register's Add route
require 'JawnOS/Controller/manager_store.pm';

{
	package ModelAddProbe;
	sub new {
		my ($class, %p) = @_;
		return bless { params => \%p, stash => { att => $p{'att'} }, rendered => undef }, $class;
	}
	sub param { my ($s, $k) = @_; return $s->{'params'}->{$k} }
	sub stash { my ($s, $k) = @_; return $s->{'stash'}->{$k} }
	sub render { my ($s, %o) = @_; $s->{'rendered'} = $o{'json'}; return $s }
	sub render_to_string { return 'LIST' }
	package ModelAddRows;
	sub new { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
	package main;
}

sub option_chars {
	my ($category) = @_;
	return $json->encode([ { name => 'option_category', value => $category, timestamp => 1, uuid => 'char' } ]);
}

sub add_model {
	my (%p) = @_;
	my @inserted;
	my @updated;
	my @existing_model = @{ $p{'existing_model'} || [] };
	my @existing_option = @{ $p{'existing_options'} || [] };
	{
		no warnings 'redefine';
		local *subs::db_query = sub {
			my ($sql) = @_;
			if ($sql =~ /from option\b/) {
				like($sql, qr/from option where app = \? and name = \?/, 'the option check names the app and the name');
				return ModelAddRows->new(\@existing_option);
			}
			like($sql, qr/from model where app = \? and name = \?/, 'the model check names the app and the name');
			return ModelAddRows->new(\@existing_model);
		};
		local *subs::db_insert = sub { push @inserted, [@_]; return 1 };
		local *subs::db_update = sub { push @updated, [@_]; return 1 };
		local *subs::db_select = sub {
			my ($table, $cols, $where) = @_;
			return ModelAddRows->new(($table // '') eq 'option' ? \@existing_option : \@existing_model);
		};
		my $c = ModelAddProbe->new(
			att => $p{'att'} // 'model',
			uuid => $p{'uuid'} // 'new',
			app => $p{'app'} // 'news',
			name => $p{'name'} // 'global',
			def => $p{'def'},
			timestamp => 1_700_000_000_000,
			option_category => $p{'option_category'} // '',
		);
		Manager::action_6625($c);
		return ($c->{'rendered'}, \@inserted, \@updated);
	}
}

my ($reply, $inserted) = add_model(existing_model => [ { uuid => 'keepglobal' } ]);
is(scalar @{$inserted}, 0, 'adding a name the catalogue holds writes no second row');
is($reply->{'uuid'}, 'keepglobal', 'the reply names the row already there');
ok($reply->{'duplicate'}, 'and marks the answer as the existing row');

($reply, $inserted) = add_model(existing_model => [], name => 'bbc');
is(scalar @{$inserted}, 1, 'a new name is inserted once');
is($inserted->[0]->[0], 'model', 'into the model table');
is($inserted->[0]->[1]->{'name'}, 'bbc', 'under the name that was typed');
is(length($inserted->[0]->[1]->{'uuid'}), 50, 'with the 50-character catalogue uuid');
ok(!$inserted->[0]->[1]->{'duplicate'}, 'and is not marked a duplicate');

# An option's key includes its category, so the guard matches only that key.
($reply, $inserted) = add_model(
	att => 'option', name => 'maxwell_house', option_category => 'catA',
	existing_options => [ { uuid => 'keepoption', characteristics => option_chars('catA') } ],
);
is(scalar @{$inserted}, 0, 'an option with the same app, name and category writes no second row');
is($reply->{'uuid'}, 'keepoption', 'the reply names the option already in that category');
ok($reply->{'duplicate'}, 'and marks it a duplicate');

($reply, $inserted) = add_model(
	att => 'option', name => 'maxwell_house', option_category => 'catB',
	existing_options => [ { uuid => 'keepoption', characteristics => option_chars('catA') } ],
);
is(scalar @{$inserted}, 1, 'the same option name in another category is inserted');
my $entered = $json->decode($inserted->[0]->[1]{'characteristics'} // '[]');
is($entered->[0]->{'name'}, 'option_category', 'and the Add stores the category chosen beside the name');
is($entered->[0]->{'value'}, 'catB', 'as the value the guard compared');

($reply, $inserted) = add_model(
	att => 'option', name => 'maxwell_house', option_category => '',
	existing_options => [ { uuid => 'plainoption', characteristics => '' } ],
);
is(scalar @{$inserted}, 0, 'an uncategorised name matches an uncategorised option');

($reply, $inserted) = add_model(
	att => 'option', name => 'maxwell_house', option_category => 'catB',
	existing_options => [ { uuid => 'plainoption', characteristics => '' } ],
);
is(scalar @{$inserted}, 1, 'while a categorised add does not match an uncategorised one');

# A model default is one row. The save clears the others in the database, not
# just the checkboxes the panel happened to redraw, so a second default cannot
# come back with the next sync.
my (undef, undef, $updated_default) = add_model(
	uuid => 'keepmodel', name => 'medium', def => 'on',
	existing_model => [ { uuid => 'keepmodel' }, { uuid => 'stale' } ],
);
my @cleared = grep { ($_->[0] // '') eq 'model' && ($_->[1]->{'def'} // '') eq 'off' } @{$updated_default};
is(scalar @cleared, 1, 'setting a model default clears the other model default');
is($cleared[0]->[2]->{'uuid'}, 'stale', 'and only the other row, not the one saved');

# Options may hold several defaults (honey with milk), so another option's
# default is left alone.
my (undef, undef, $updated_option) = add_model(
	att => 'option', uuid => 'keepopt', name => 'honey', def => 'on',
	existing_options => [ { uuid => 'keepopt' }, { uuid => 'milkopt' } ],
);
is(scalar(grep { ($_->[0] // '') eq 'option' && ($_->[1]->{'def'} // '') eq 'off' } @{$updated_option}), 0,
	'another option default is not cleared');

# A catalogue row deleted in Configure leaves a durable tombstone. Without it a
# peer that still held the row handed it back on the next pull.
{
	package DeleteProbe;
	sub new { my ($class, %p) = @_; return bless { params => \%p, rendered => undef }, $class }
	sub param { my ($s, $k) = @_; return $s->{'params'}->{$k} }
	sub render { my ($s, %o) = @_; $s->{'rendered'} = $o{'text'}; return $s }
	package main;
}
my (@deleted, @registered);
{
	no warnings 'redefine';
	local *subs::db_select = sub { return ModelAddRows->new([ { uuid => 'doomed', server_time => '4242', app => 'tea' } ]) };
	local *subs::db_delete = sub { push @deleted, [@_]; return 1 };
	local *Manager::deletion_registration = sub { push @registered, @_; return 1 };
	my $c = DeleteProbe->new(uuid => 'doomed', att => 'model');
	Manager::action_6893($c);
	is($c->{'rendered'}, 'ok', 'the delete answers ok');
}
is(scalar @deleted, 1, 'the catalogue row is deleted');
is($deleted[0]->[0], 'model', 'from its own table');
is($deleted[0]->[1]->{'uuid'}, 'doomed', 'by uuid');
is(scalar @registered, 1, 'and a deletion is registered so the next sync cannot hand it back');
is($registered[0]->{'table'}, 'model', 'the tombstone names the table');
is($registered[0]->{'uuid'}, 'doomed', 'and the row');
is($registered[0]->{'server_time'}, '4242', 'with the stamp the row had');
is($registered[0]->{'scope'}, 'single', 'as a whole-row deletion');

# ------------------------------------------------------- what the person sees
my $js = read_file("$root/public/js/manager/attributes.js");
like($js, qr/if \(response\.duplicate\)/, 'the Register notices the existing row');
like($js, qr/That model already exists/, 'and says so rather than letting the model press look wasted');
like($js, qr/That option already exists in this category/, 'and names the option key in its own notice');
like($js, qr/option_category: option_category/, 'the Add carries the option category chosen beside the name');
like($js, qr/if \(att_uuid == 'new'\) \{ return; \}/, 'a new row leaves its category for the Add to save');
like($js, qr/attribute === 'model'/, 'only a model default clears its siblings');
like($js, qr/\.attribute\[att="model"\]\[app="/, 'the uncheck is scoped to the model list, not every catalogue table');
like($js, qr/\.attribute\[att="'\s*\+\s*\w+\s*\+\s*'"\]\[uuid=/, 'a saved row is replaced by its own catalogue table');
like($js, qr/\.attribute\[att="'\s*\+\s*att\s*\+\s*'"\]\[uuid=/, 'the characteristic setter replaces its own row');
my $copy_js = read_file("$root/public/js/manager/attributes/01_upload_copy_migration.js");
like($copy_js, qr/\.attribute\[att="'\s*\+\s*att\s*\+\s*'"\]\[uuid=/, 'the copy tool replaces its own row too');
my $help = read_file("$root/perl/help/topics_features.pl");
like($help, qr/a name the catalogue already holds \(in the same option category\) opens that row/,
	'the guide names the option category in that rule');

done_testing();
