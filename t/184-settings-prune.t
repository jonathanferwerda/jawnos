# tests-for: scripts/settings_prune.pl lib/JawnOS/Domain/Name.pm
# covers:    the settings prune removes payload keys and orphan rows, keeps the
#            card draws and strips their image streams

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use RepoSource;
use File::Temp qw(tempfile);
use Mojo::SQLite;
use Mojo::JSON qw(encode_json decode_json);

# The settings table is read on every request and every index copies every key.
# A row whose `app` was a whole document (6.3 MB on the phone), __orphan_* rows a
# rename left behind, and the cards draw list's legacy `stream` images had grown
# it to 1.06 GB. This drives the prune on a throwaway database: it never touches
# the live one.

my ($fh, $dbfile) = tempfile('jawnos-prune-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text)');
$db->query('create table cache (app text, context text, subcontext text, data text, '
	. 'device text, timestamp text, server_time text, uuid text, ost text)');
$db->query('create table remote_machines (uuid text, signatorial text, deletions text)');
$db->query('create table sync_log (id integer primary key autoincrement, '
	. 'server_time text, signatorial text, tbl text, app text, uuid text, '
	. 'scope text, additional text, ost text)');
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

my $draws = encode_json([
	{ cards => [ 'the moon', 'the sun' ], title => 'a reading', timestamp => 1, stream => ('x' x 5000) },
]);
$db->query('insert into settings (app, setting, value, device, server_time) values (?,?,?,?,?)',
	'cards', 'spread', $draws, 'all', 1);
$db->query('insert into settings (app, setting, value, device, server_time) values (?,?,?,?,?)',
	'x' x 5000, 'probe', 'on', 'all', 2);
$db->query("insert into settings (app, setting, value, device, server_time) values ('__orphan_abc_2','note','gone','all',3)");
$db->query('insert into settings (app, setting, value, device, server_time) values (?,?,?,?,?)',
	'me', 'my_name', 'Dan', 'all', 4);

# The script chdirs to its own root and requires the domain layer. It calls
# main() at its top level unless a caller asks for it, so load it from inside a
# sub - that is the caller the guard looks for.
sub load_prune { require(repo_root() . '/scripts/settings_prune.pl'); }
load_prune();

my ($stripped, $saved) = main::strip_card_streams($draws);
ok(defined $stripped, 'strip_card_streams rewrites a list that carries a stream');
ok($saved >= 5000, 'and reports the bytes it saved');
my $kept = decode_json($stripped);
is_deeply($kept->[0]->{'cards'}, [ 'the moon', 'the sun' ], 'the draw is kept');
ok(!exists $kept->[0]->{'stream'}, 'the image stream is gone');

sub quietly {
	my ($code) = @_;
	my $tmp = File::Temp->new(TMPDIR => 1, SUFFIX => '.out');
	open(my $saved_out, '>&STDOUT') or die "dup stdout: $!";
	open(STDOUT, '>', $tmp->filename) or die "redirect: $!";
	my $rc = $code->();
	open(STDOUT, '>&', $saved_out) or die "restore stdout: $!";
	close $saved_out;
	my $buffer = slurp_file($tmp->filename);
	return ($rc, $buffer);
}

sub slurp_file {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text // '';
}

my $rows = sub {
	my ($where) = @_;
	return $db->query("select count(*) as n from settings" . ($where ? " where $where" : ''))->hash->{'n'};
};

my ($rc, $out) = quietly(sub { main() });
is($rc, 0, 'a dry run succeeds');
like($out, qr/nothing written/, 'and says so');
is($rows->("length(app) > 100"), 1, 'a dry run deletes nothing');
is($rows->("app like '__orphan%'"), 1, 'not even the orphans');

my $before_bytes = -s $dbfile;
($rc, $out) = quietly(sub { main('--apply') });
is($rc, 0, 'apply succeeds') or diag($out);
like($out, qr/file \d+ MB -> \d+ MB/, 'the report names the file sizes');
ok((-s $dbfile) <= $before_bytes, 'the vacuum did not grow the file');
is($rows->("length(app) > 100"), 0, 'the payload key is gone');
is($rows->("app like '__orphan%'"), 0, 'the orphan rows are gone');
my $cards = $db->query("select value from settings where app = 'cards'")->hash;
my $list = decode_json($cards->{'value'});
is_deeply($list->[0]->{'cards'}, [ 'the moon', 'the sun' ], 'the draws survive the prune');
ok(!exists $list->[0]->{'stream'}, 'the stream does not');
is($rows->("app = 'me' and setting = 'my_name'"), 1, 'an ordinary setting is untouched');

done_testing();
