# tests-for: lib/JawnOS/Controller/manager_misc7.pm lib/JawnOS/Manager/Part21.pm public/js/manager/manager/04_search.js perl/help/topics_features.pl
# covers:    the dock's app search and the Search app's Apps tab answer an app's
#           akas as well as its printed name, so "zzz" finds sleep; a hidden
#           (private) app never offers those names, and an aka edit moves the
#           index version the box watches.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::SQLite;
use RepoSource;
use JawnOSTest;

my $root = repo_root();
require "$root/lib/JawnOS/Manager/Part21.pm";
require "$root/lib/JawnOS/Controller/manager_misc7.pm";

# A throwaway database with the two tables the search reads, so the live house
# database is never touched.
my ($fh, $dbfile) = tempfile('jawnos-search-aka-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db = $sql->db;
$db->query('create table settings (app text, device text, setting text, value text, server_time text)');
$db->query('create table appointments (app text, account text, server_time text)');
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
$Manager::device = 'computer';

my $add = sub {
	my ($app, $device, $setting, $value, $server_time) = @_;
	$db->query('insert into settings (app, device, setting, value, server_time) values (?,?,?,?,?)',
		$app, $device, $setting, $value, $server_time || '1000');
};
$add->('sleep', 'all', 'aka', 'zzz, shuteye');
$add->('sleep', 'computer', 'visible', 'on');
$add->('sleep', 'computer', 'pos', 'moon');
$add->('secret', 'all', 'aka', 'hideout');
$add->('secret', 'computer', 'visible', 'private');
$add->('secret', 'computer', 'pos', 'lock');
$add->('zzz_snooze', 'computer', 'visible', 'on');
$db->query("insert into appointments (app, account, server_time) values ('sleep', 'personal', '1000')");

# A tiny controller: the action only asks for a param and renders JSON.
{
	package FakeSearchController;
	sub new { my ($class, $params) = @_; return bless { params => $params || {}, out => undef }, $class; }
	sub param { my ($self, $name) = @_; return $self->{params}{$name}; }
	sub render { my ($self, %args) = @_; $self->{out} = exists $args{'json'} ? $args{'json'} : $args{'text'}; return; }
}

# The hidden/private rule is the same one the menu and the timeline use; stub
# it so the test speaks about names and not about the privacy machinery, while
# still recording that it was asked about the aka-only app.
my @asked;
my %hidden = (secret => 1);
{
	no warnings 'redefine';
	*Manager::help_app_hidden = sub { push @asked, $_[0]; return $hidden{$_[0]} ? 1 : 0 };
	*Manager::search_index_icon = sub { return '' };
}
%gb::known_appts = ();

my $c = FakeSearchController->new;
Manager::action_26091($c);
my %indexed = map { $_->{'app'} => $_ } @{ $c->{out}{'apps'} || [] };

ok($indexed{'sleep'}, 'the dock index carries an app with an aka');
is_deeply($indexed{'sleep'}{'aka'}, [ 'zzz', 'shuteye' ],
	'the akas travel with the app so the browser can match them');
ok(!$indexed{'secret'}, 'a hidden app stays out of the dock index');
ok((grep { $_ eq 'secret' } @asked),
	'and the hidden rule is asked about an app found only through its settings');

# An aka edit has to move the version the dock watches, or the browser keeps
# the old list until a reload.
my $version = Manager::search_index_signature();
$db->query("update settings set server_time = '2000' where app = 'sleep' and setting = 'aka'");
isnt(Manager::search_index_signature(), $version,
	'an aka edit moves the index version');

# The version check answers without shipping the list again.
my $check = FakeSearchController->new({ check => 1 });
Manager::action_26091($check);
ok($check->{out}{'version'}, 'the check answers with a version');
ok(!exists $check->{out}{'apps'}, 'the check does not ship the list');

# The Search app's Apps tab asks the server, so it gets the same word.
my @apps;
@apps = map { $_->{'app'} } @{ Manager::search_app_matches('zzz') };
is_deeply(\@apps, [ 'zzz_snooze', 'sleep' ],
	'a name match comes before the app found only by its aka');

@apps = map { $_->{'app'} } @{ Manager::search_app_matches('hideout') };
ok(!(grep { $_ eq 'secret' } @apps),
	'a hidden app does not leak through an aka in the Search app either');

# The browser side of the dock.
my $js = read_file("$root/public/js/manager/manager/04_search.js");
like($js, qr/if \(app\.aka && app\.aka\.length\)/,
	'the dock reads the akas the index carries');
like($js, qr/aka\.indexOf\(words\[i\]\)/,
	'a word may be found in an aka');
like($js, qr/rank: named \? exact \* 2 \+ prefix : 4/,
	'an aka-only match ranks below every name match');

done_testing();
