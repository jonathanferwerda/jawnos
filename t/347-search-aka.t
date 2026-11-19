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
like($js, qr/aka_list\[k\]\.plain\.indexOf\(words\[i\]\)/,
	'a word may be found in an aka');
like($js, qr/rank: named \? exact \* 2 \+ prefix : 4/,
	'an aka-only match ranks below every name match');
like($js, qr/function jawnosSearchLabel\(match\)/,
	'the row label is its own function');
like($js, qr/\Qtext += ' (' + match.aka.join(', ') + ')'\E/,
	'the label puts the matched aka in brackets');

# The matching and the label are run in a bare JS context, so the words a row
# prints are played out rather than only counted in the source. The harness is
# written here, not kept in t/lib, because a t/lib change selects the full suite.
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my ($harness_fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $harness_fh <<'JS';
'use strict';
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync(process.argv[2], 'utf8');

// A chainable stand-in for jQuery. Loading the file must not draw anything, so
// $(fn) returns without calling fn and every other call chains.
function chain() {
	const fn = function () { return proxy; };
	const proxy = new Proxy(fn, {
		get: function (target, prop) {
			if (prop === 'length') { return 0; }
			if (prop === 'then') { return undefined; }
			if (prop === 'val') { return function () { return ''; }; }
			if (prop === 'is') { return function () { return false; }; }
			return proxy;
		},
		apply: function () { return proxy; },
	});
	return proxy;
}

const sandbox = {
	console: console,
	Math: Math,
	JSON: JSON,
	Date: Date,
	setTimeout: function () { return 0; },
	clearTimeout: function () {},
	setInterval: function () { return 0; },
	clearInterval: function () {},
	localStorage: {
		getItem: function () { return null; },
		setItem: function () {},
	},
	document: { addEventListener: function () {}, getElementById: function () { return null; } },
	window: {},
};
sandbox.window = sandbox;
sandbox.$ = chain;
sandbox.jQuery = sandbox.$;

vm.createContext(sandbox);
vm.runInContext(source, sandbox, { filename: '04_search.js' });

let failures = 0;
function check(ok, name) {
	if (!ok) { failures++; }
	console.log((ok ? 'ok ' : 'not ok ') + name);
}

sandbox.jawnosSearchApps = [
	{ app: 'sleep', name: 'Sleep', aka: [ 'zzz', 'shuteye' ] },
	{ app: 'zzz_snooze', name: 'Zzz Snooze', aka: [] },
	{ app: 'coffee', name: 'Coffee', aka: [ 'joe' ] },
];

function find(list, app) {
	return list.filter(function (m) { return m.app.app === app; })[0];
}

let list = sandbox.jawnosSearchMatches('zzz');
check(list.length === 2, 'a word finds the name that carries it and the app whose aka does');
check(list[0].app.app === 'zzz_snooze', 'a name match is listed before an aka-only match');
const sleep = find(list, 'sleep');
check(!!sleep && sleep.aka.length === 1 && sleep.aka[0] === 'zzz',
	'the aka that supplied the word travels with the match');
check(sandbox.jawnosSearchLabel(sleep) === 'Sleep (zzz)',
	'the row prints the matched aka in brackets');
check(sandbox.jawnosSearchLabel(find(list, 'zzz_snooze')) === 'Zzz Snooze',
	'a name match prints no brackets');

list = sandbox.jawnosSearchMatches('shuteye');
check(sandbox.jawnosSearchLabel(find(list, 'sleep')) === 'Sleep (shuteye)',
	'a second aka prints the word it matched, not the first');

list = sandbox.jawnosSearchMatches('sleep');
check(sandbox.jawnosSearchLabel(find(list, 'sleep')) === 'Sleep',
	'a match on the printed name adds no brackets');

list = sandbox.jawnosSearchMatches('zzz shuteye');
const both = find(list, 'sleep');
check(!!both && both.aka.join(',') === 'zzz,shuteye', 'a query matching two akas carries both');
check(sandbox.jawnosSearchLabel(both) === 'Sleep (zzz, shuteye)',
	'and the row prints both in brackets');

console.log((failures ? 'not ok ' : 'ok ') + failures + ' failure(s)');
process.exit(failures);
JS
	close $harness_fh;
	my $out = `$node "$harness" "$root/public/js/manager/manager/04_search.js" 2>&1`;
	my @lines = split /\n/, $out;
	unlike($out, qr/^not ok/m, 'every aka-row assertion passes');
	is($lines[-1] // '', 'ok 0 failure(s)', 'the aka-row harness exits clean');
	diag($out) unless ($lines[-1] // '') eq 'ok 0 failure(s)';
}
else {
	diag('node is not installed; the aka-row rendering checks are skipped');
}

done_testing();
