# tests-for: scripts/clothesline_audit.pl
# covers:    the read-only clothesline audit - one block per learned day, the
#            rest that opened it, the profile summary and the night window on
#            the house clock, the --json form, and the promise that a run
#            writes nothing to the database.
#
# The audit is driven as a process against a throwaway store (JAWNOS_STORE_DIR)
# holding three dense, minute-level days and an empty websockets table. The days
# are UTC and the seeded clock_timezone is UTC, so the house clock in the report
# is the fixture's own clock whatever the box is set to.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);

eval { require Mojo::SQLite; 1 } or plan skip_all => 'Mojo::SQLite is not installed';
eval { require Time::Local; 1 } or plan skip_all => 'Time::Local is not installed';
require IPC::Open3;
require Symbol;
require Time::Local;

my $root = File::Spec->rel2abs("$FindBin::Bin/..");
my $script = "$root/scripts/clothesline_audit.pl";
plan skip_all => "no audit script at $script" unless -f $script;

# --- a throwaway store --------------------------------------------------------

my $dir = tempdir('clothesline-audit-XXXXXX', TMPDIR => 1, CLEANUP => 1);
make_path("$dir/database", "$dir/run", "$dir/.president");

open(my $cfg, '>', "$dir/config.json") or die "config: $!";
print $cfg JSON::PP->new->canonical->encode({
	device => 'computer', language => 'en', environment => 'test',
	logfile => "$dir/manager.log", port => '3000', working_port => '3001', ws_port => '3001',
});
close $cfg;

my $db_file = "$dir/database/jawnos.db";
my $sql = Mojo::SQLite->new("sqlite:$db_file");
my $dbh = $sql->db;
$dbh->query(q{create table appointments (app varchar(500), timestamp varchar(25), stop_timestamp varchar(25), type varchar(500), source varchar(100), source_uuid varchar(255))});
$dbh->query(q{create table settings (setting varchar(50), value varchar(50), timestamp varchar(25), id integer primary key autoincrement, app varchar(50), server_time varchar(500), device varchar(255))});
$dbh->query(q{create table websockets (timestamp varchar(255), server_time varchar(255), connected varchar(25), type varchar(25), browser_tab_id varchar(255), user_agent text, remote_address varchar(255))});
$dbh->query(q{insert into settings (setting, value, app, device) values (?, ?, ?, ?)}, 'clock_timezone', 'UTC', 'misc', 'computer');

# Three dense days: a step every two minutes from 08:00 to 22:00 with a
# sixty-minute lunch, so each day has two waves and the night is a real rest.
my @apps = qw(wake_up coffee water vape dump facebook breakfast water coffee vape make_up_bed);
my @now = gmtime(time());
my $today0 = Time::Local::timegm(0, 0, 0, $now[3], $now[4], $now[5]);
my $inserted = 0;
for my $off (3, 2, 1) {
	my $base = $today0 - ($off * 86400);
	my $k = 0;
	for (my $minute = 8 * 60; $minute <= 22 * 60; $minute += 2) {
		next if $minute >= 13 * 60 && $minute < 14 * 60;   # the lunch pause
		my $ms = ($base + $minute * 60) * 1000;
		$dbh->query(q{insert into appointments (app, timestamp, stop_timestamp, type, source, source_uuid) values (?, ?, ?, ?, ?, ?)},
			$apps[$k++ % scalar @apps], $ms, '', 'stop', 'press', '');
		$inserted++;
	}
}
cmp_ok($inserted, '>', 100, 'the fixture seeded a dense window');
# Leave a clean WAL database: the app's connection only re-issues WAL when the
# file is not already in it, so this keeps the run a pure read.
$dbh->query('PRAGMA journal_mode=WAL');
$dbh->query('PRAGMA wal_checkpoint(TRUNCATE)');
$dbh->disconnect;
undef $sql;

ok(-s $db_file > 5000, 'the fixture database is large enough not to be bootstrapped');

sub db_hash {
	open(my $fh, '<', $db_file) or die "read $db_file: $!";
	binmode $fh;
	local $/;
	my $bytes = <$fh>;
	close $fh;
	return sha256_hex($bytes);
}
my $before = db_hash();

# --- run the script -----------------------------------------------------------

sub run_script {
	my (@args) = @_;
	my ($out, $err) = ('', '');
	my $err_fh = Symbol::gensym();
	my $pid;
	{
		local %ENV = (%ENV,
			JAWNOS_STORE_DIR => $dir,
			JAWNOS_RUN_DIR => "$dir/run",
			HOME => $dir,
			TZ => 'UTC',
		);
		delete $ENV{'JAWNOS_DIR'};
		$pid = IPC::Open3::open3(my $in, my $out_fh, $err_fh, $^X, $script, @args);
		close $in;
		local $/;
		$out = <$out_fh>;
		$err = <$err_fh>;
		close $out_fh;
		close $err_fh;
	}
	waitpid($pid, 0);
	my $rc = $? >> 8;
	$out = '' unless defined $out;
	$err = '' unless defined $err;
	return ($rc, $out, $err);
}

my ($rc, $out, $err) = run_script('--days', 4);
is($rc, 0, 'the audit exits 0') or diag("stderr: $err");
like($out, qr/^== DAYS$/m, 'it prints the day section');
like($out, qr/^== PROFILES$/m, 'and the profile section');
like($out, qr/done - nothing written\./, 'and says it wrote nothing');

my @date_lines = grep { /^\d{4}-\d{2}-\d{2} \w{3}  / } split /\n/, $out;
is(scalar @date_lines, 3, 'one block per seeded day');
my @wave_lines = grep { /waves 2, gap 10m/ } split /\n/, $out;
is(scalar @wave_lines, 3, 'each day carries its two waves and their gap');

like($out, qr/opened by rest 22:00->08:00 \(10h 00m, mid 03:00, profile 0\)/,
	'the rest that opened a day is printed with its profile');
like($out, qr/^\s+profile 0 \*\s+2 rest\(s\)\s+22:00->08:00\s+opener wake_up/m,
	'the learned profile is summarised and marked selected');
like($out, qr/^night window 22:00->08:00 over 2 rest\(s\)/m,
	'and the learned night window is printed');
like($out, qr/^\s+head now: /m, 'the newest day carries the rail head');
like($out, qr/liveness: none \(no retained sockets\)/, 'empty sockets are reported as no liveness');

is(db_hash(), $before, 'the text run leaves the database byte-for-byte unchanged');

# --- --json is the same data, and still writes nothing ------------------------

($rc, $out, $err) = run_script('--days', 4, '--json');
is($rc, 0, '--json exits 0') or diag("stderr: $err");
my $j = eval { JSON::PP::decode_json($out) };
ok(ref $j eq 'HASH', '--json emits a structure') or diag("stdout: $out");
is(scalar @{ $j->{'days'} || [] }, 3, 'with one day entry per seeded day');
is($j->{'zone'}, 'UTC', 'read on the house clock');
is($j->{'liveness'}{'used'}, 0, 'and records that liveness did not reach the segments');
is($j->{'night_window'}{'start_hour'}, 22, 'the night window start is in the structure');
is($j->{'night_window'}{'stop_hour'}, 8, 'and its stop');
is($j->{'days'}[1]{'state'}, 'closed', 'the middle day closed at its night');
is($j->{'days'}[2]{'state'}, 'resting', 'the newest day is resting at its night');
ok($j->{'days'}[2]{'rest'}, 'the newest day names the rest that opened it');
ok($j->{'days'}[2]{'head'}, 'and only the newest day carries a head');
is(db_hash(), $before, 'the --json run writes nothing either');

done_testing();
