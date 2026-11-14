# tests-for: scripts/model_duplicates.pl lib/JawnOS/Controller/manager_store.pm public/js/manager/attributes.js perl/help/topics_features.pl
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
$add_appt->execute('news', $json->encode({ uuid => 'dropcbc', name => 'cbc', quantity => 1 }), 100);
$add_appt->finish;

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

sub add_model {
	my (%p) = @_;
	my @inserted;
	my @updated;
	my @existing = @{ $p{'existing'} || [] };
	{
		no warnings 'redefine';
		local *subs::db_query = sub {
			my ($sql) = @_;
			like($sql, qr/from model where app = \? and name = \?/, 'the duplicate check names the app and the name');
			return ModelAddRows->new(\@existing);
		};
		local *subs::db_insert = sub { push @inserted, [@_]; return 1 };
		local *subs::db_update = sub { push @updated, [@_]; return 1 };
		my $c = ModelAddProbe->new(
			att => $p{'att'} // 'model',
			uuid => $p{'uuid'} // 'new',
			app => $p{'app'} // 'news',
			name => $p{'name'} // 'global',
			timestamp => 1_700_000_000_000,
		);
		Manager::action_6625($c);
		return ($c->{'rendered'}, \@inserted, \@updated);
	}
}

my ($reply, $inserted) = add_model(existing => [ { uuid => 'keepglobal' } ]);
is(scalar @{$inserted}, 0, 'adding a name the catalogue holds writes no second row');
is($reply->{'uuid'}, 'keepglobal', 'the reply names the row already there');
ok($reply->{'duplicate'}, 'and marks the answer as the existing row');

($reply, $inserted) = add_model(existing => [], name => 'bbc');
is(scalar @{$inserted}, 1, 'a new name is inserted once');
is($inserted->[0]->[0], 'model', 'into the model table');
is($inserted->[0]->[1]->{'name'}, 'bbc', 'under the name that was typed');
is(length($inserted->[0]->[1]->{'uuid'}), 50, 'with the 50-character catalogue uuid');
ok(!$inserted->[0]->[1]->{'duplicate'}, 'and is not marked a duplicate');

($reply, $inserted) = add_model(existing => [ { uuid => 'keepoption' } ], att => 'option');
is(scalar @{$inserted}, 1, 'an option name is not guarded: the same name can sit in two categories');

# ------------------------------------------------------- what the person sees
my $js = read_file("$root/public/js/manager/attributes.js");
like($js, qr/if \(response\.duplicate\)/, 'the Register notices the existing row');
like($js, qr/That model already exists/, 'and says so rather than letting the press look wasted');
my $help = read_file("$root/perl/help/topics_features.pl");
like($help, qr/a name the catalogue already holds opens that row instead of adding a second one/,
	'the guide says an existing name opens its row');

done_testing();
