# tests-for: lib/JawnOS/Domain/Calendar.pm
# covers:    the twin window is a real time window: an open session five minutes
#            away is neither reused by a start nor retired by a stop, while a
#            session one second away still is; guards the bound-parameter casts
#            that keep SQLite from reading every integer as less than the text
#            tolerance (which made the window unlimited and one stop close two
#            same-name appointments)

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use Mojo::SQLite;

# A throwaway SQLite file installed as the holder, so the live database is never
# touched. The window is driven through the real selectors and real SQL: a mock
# of db_query cannot show the affinity bug this test exists for.
my ($fh, $dbfile) = tempfile('jawnos-twin-window-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table appointments (uuid text, app text, type text, '
	. 'timestamp text, stop_seen text, server_time text)');
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

my $app = 'twin_probe';
my $t1  = 1_700_000_000_000;
my $t2  = $t1 + 5 * 60 * 1000;   # the second same-name session, five minutes on
my $near = $t1 + 1_500;          # a replayed start, one and a half seconds on

$db->query('insert into appointments (uuid,app,type,timestamp,stop_seen,server_time) values (?,?,?,?,?,?)',
	'first', $app, 'start', $t1 . '', undef, $t1 . '');
$db->query('insert into appointments (uuid,app,type,timestamp,stop_seen,server_time) values (?,?,?,?,?,?)',
	'replay', $app, 'start', $near . '', undef, $near . '');

# A start at the second session's moment must not reuse the first (five minutes
# away); at that moment the second row does not exist yet.
my $open = &subs::session_open_near($app, 'start', $t2, 2000) || [];
is(scalar @{$open}, 0, 'a start five minutes from an open session finds no twin');
ok(!grep({ $_->{'uuid'} eq 'first' } @{$open}), 'the five-minute-old session is not reused');

$db->query('insert into appointments (uuid,app,type,timestamp,stop_seen,server_time) values (?,?,?,?,?,?)',
	'second', $app, 'start', $t2 . '', undef, $t2 . '');

my $near_open = &subs::session_open_near($app, 'start', $t1, 2000) || [];
is(scalar @{$near_open}, 2, 'the window still holds the row at the stamp and the replay beside it');
ok(!grep({ $_->{'uuid'} eq 'second' } @{$near_open}), 'and never the session minutes away');

# The stop's twin sweep is the one that closed both appointments: the second must
# stay open when the first is stopped at its own moment.
my $twins = &subs::session_twin_rows($app, 'first', $t1, 2000) || [];
is(scalar @{$twins}, 1, 'a stop retires only the replayed twin beside the row it closed');
is($twins->[0]->{'uuid'}, 'replay', 'the twin is the one just beside the named row');
ok(!grep({ $_->{'uuid'} eq 'second' } @{$twins}), 'the second same-name session is not retired');

my $none = &subs::session_twin_rows($app, 'first', $t1, 0) || [];
is(scalar @{$none}, 0, 'a zero window still has no twin');

done_testing();
