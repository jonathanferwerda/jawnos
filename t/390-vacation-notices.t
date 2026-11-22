# tests-for: lib/JawnOS/Domain/VacationDigest.pm templates/configure/away_notices.html.ep lib/JawnOS/Routes/manager_vacation_notices.pm lib/JawnOS/Controller/manager_vacation_notices.pm
# covers:    the fuller review of an ended away period: the notices that were
#            held (non-urgent apps) between the period's bounds, newest first,
#            bounded and listed as plain fields; the urgent apps are dropped; an
#            empty app is kept; and the partial names the helper it renders.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempfile);
use JSON::PP qw(encode_json);
use Mojo::SQLite;
use JawnOSTest;

# The helper is new; the Loader is wired by the main thread, so load the module
# directly and call the package subs.
require "$FindBin::Bin/../lib/JawnOS/Domain/VacationDigest.pm";

my $now = ts(2026, 11, 15, 12, 0, 0);

my ($fh, $dbfile) = tempfile('jawnos-vacation-notices-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table settings (setting text, value text, timestamp text, id integer primary key autoincrement, app text, server_time text, device text, browser_tab_id text, uuid text, ost text, subsetting text)');
$db->query('create table notifications (timestamp text, message text, title text, tag text, key text, id integer, image text, uuid text unique, server_time text, ost text, role text, app text)');
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

sub set_policy {
	my ($keep) = @_;
	my $json = encode_json({
		version => 1,
		periods => [],
		policy  => {
			notifications => 'hold',
			keep_apps     => { budgets => [], routines => [], notifications => $keep },
		},
		auto => { detect => 0, after_hours => 24 },
	});
	$db->query('delete from settings where app = ? and setting = ? and device = ?', '__president', 'vacation', 'all');
	$db->query('insert into settings (setting, value, app, device, uuid, server_time) values (?,?,?,?,?,?)',
		'vacation', $json, '__president', 'all', 'vacation-policy', $now);
	&subs::vacation_forget();
}

sub notice {
	my ($uuid, $app, $title, $message, $at) = @_;
	$db->query('insert into notifications (uuid, app, title, message, timestamp, server_time) values (?,?,?,?,?,?)',
		$uuid, $app, $title, $message, $at, $at);
}

my $start = ts(2026, 11, 1, 0, 0, 0);
my $end   = ts(2026, 11, 8, 0, 0, 0);

# The policy keeps security; shop and market are held. An out-of-period notice
# and one exactly at the half-open end must not appear.
set_policy([ 'security' ]);
notice('s1', 'shop',   'Budget', 'The grocery budget passed its floor.', ts(2026, 11, 3, 10, 0, 0));
notice('m1', 'market', 'Staples', 'Two items are running low.',          ts(2026, 11, 5, 10, 0, 0));
notice('u1', 'security', 'Door',  'The front door opened.',               ts(2026, 11, 4, 10, 0, 0));
notice('o1', 'shop',   'Later',  'This arrived after the trip.',          ts(2026, 11, 10, 10, 0, 0));
notice('b1', 'shop',   'Edge',   'This arrived at the end boundary.',     $end);

my $held = &subs::vacation_held_notices($start, $end);
is($held->{'count'}, 2, 'only the two held notices in the period are returned');
is_deeply(
	[ map { $_->{'uuid'} } @{ $held->{'notices'} } ],
	[ 'm1', 's1' ],
	'the newest held notice comes first'
);
is_deeply(
	[ map { $_->{'app'} } @{ $held->{'notices'} } ],
	[ 'market', 'shop' ],
	'each row carries its app'
);
ok(!grep({ ($_->{'app'} // '') eq 'security' } @{ $held->{'notices'} }),
	'the urgent app is not in the held review');
is($held->{'notices'}->[0]->{'title'}, 'Staples', 'each row carries its title');
is($held->{'notices'}->[0]->{'message'}, 'Two items are running low.', 'each row carries its message');
is($held->{'notices'}->[0]->{'timestamp'}, ts(2026, 11, 5, 10, 0, 0), 'each row carries its timestamp');

is(&subs::vacation_notice_count($start, $end), 2, 'the convenience count agrees');

# A limit narrows the glance to the newest rows.
my $one = &subs::vacation_held_notices($start, $end, limit => 1);
is($one->{'count'}, 1, 'the limit bounds the review');
is($one->{'notices'}->[0]->{'uuid'}, 'm1', 'the limit keeps the newest row');

# A bad span is empty, not an error.
is(&subs::vacation_held_notices($end, $start)->{'count'}, 0, 'an inverted span has no notices');
is(&subs::vacation_held_notices('nope', $end)->{'count'}, 0, 'a non-numeric span has no notices');

# The policy's keep list decides what was held: put shop on it and shop drops.
set_policy([ 'security', 'shop' ]);
my $kept_shop = &subs::vacation_held_notices($start, $end);
is($kept_shop->{'count'}, 1, 'an app on the keep list is not part of the held review');
is($kept_shop->{'notices'}->[0]->{'app'}, 'market', 'the other held app remains');

# A notice with no app is house news, so it is kept.
$db->query('delete from notifications');
set_policy([ 'security' ]);
notice('h1', '', 'House', 'A general note.', ts(2026, 11, 4, 9, 0, 0));
my $house = &subs::vacation_held_notices($start, $end);
is($house->{'count'}, 1, 'a notice with an empty app is kept');
is($house->{'notices'}->[0]->{'app'}, '', 'its empty app is preserved');

# --- the partial ------------------------------------------------------------
sub slurp {
	my ($path) = @_;
	open(my $in, '<', $path) or die "$path: $!";
	local $/;
	my $text = <$in>;
	close $in;
	return defined $text ? $text : '';
}
my $root = "$FindBin::Bin/..";
my $partial = slurp("$root/templates/configure/away_notices.html.ep");
like($partial, qr/<details class="away_notices">/, 'the partial renders the details block');
like($partial, qr/vacation_held_notices/, 'the partial asks the held-notice helper');
like($partial, qr/What arrived while you were away/, 'the partial heads the review');
like($partial, qr/Nothing was held\./, 'the partial says when nothing was held');
like($partial, qr/vacation_status/, 'the partial reads the away status when not handed one');

# --- the route and its action ----------------------------------------------
my $route_src = slurp("$root/lib/JawnOS/Routes/manager_vacation_notices.pm");
like($route_src, qr{/manager/vacation/notices}, 'the route path is registered');
like($route_src, qr/action_60020/, 'the route names its action');

my $controller_src = slurp("$root/lib/JawnOS/Controller/manager_vacation_notices.pm");
like($controller_src, qr/sub action_60020\b/, 'the controller defines the action');
like($controller_src, qr/vacation_held_notices/, 'the action calls the helper');

my $route_loaded = eval { require "$root/lib/JawnOS/Routes/manager_vacation_notices.pm"; 1 };
ok($route_loaded, 'the route module compiles') or diag $@;
my $controller_loaded = eval { require "$root/lib/JawnOS/Controller/manager_vacation_notices.pm"; 1 };
ok($controller_loaded, 'the controller compiles') or diag $@;

done_testing();
