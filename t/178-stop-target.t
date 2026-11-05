# tests-for: lib/JawnOS/Manager/Part14.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Manager/Part29.pm
# covers:    a stop resolves one (oldest) open session before the relay, so every machine closes the same uuid; a named session is a hard match

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

# A stop is one press for one session. The press is relayed to every peer, so the
# uuid must be resolved on the machine that received it: a relay that carried no
# uuid made each peer fall back to its own copy of the database, and two open rows
# for one app then closed two different sessions (today's laydown at 15:03 and the
# one at 17:31 both ended at the same stop timestamp from two writes).
#
# The fallback, and the header the stop button reads, name the OLDEST open
# start/record - the session that has been running longest, and the one a missing
# stop left behind. A client that names a session still gets that exact row (a hard
# match), and a duplicate or unsynced name closes nothing.

my $root    = repo_root();
my $part14  = read_file("$root/lib/JawnOS/Manager/Part14.pm");
my $calendar = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
my $part29  = read_file("$root/lib/JawnOS/Manager/Part29.pm");

# --- manager_reset resolves the target before it relays ----------------------

my $stop_resolve = index($part14, "if (\$type eq 'stop' && !\$target_uuid)");
my $relay        = index($part14, "&remote_relay_request(\$c, { dissemination => 'yes' })");
ok($stop_resolve >= 0, 'manager_reset resolves a stop that named no session');
ok($relay >= 0, 'and it still relays the press');
ok($stop_resolve < $relay, 'the resolution happens before the relay, so the uuid travels with it');

my ($between) = $part14 =~ /(my \$target_uuid = .*?&remote_relay_request\(\$c, \{ dissemination => 'yes' \}\);)/s;
like($between, qr/&subs::stop_target_row\(\$app, '', \$timestamp\)/,
	'the target is the stop resolver, not a second query');
like($between, qr/\$target_uuid = \$resolved->\{'uuid'\};\s*\$uuid = \$target_uuid;\s*\$c->param\('uuid' => \$uuid\);/,
	'and the resolved uuid replaces the minted one the relay would have sent');

# --- the stop resolvers name the oldest open session ------------------------

my ($open_sub) = $calendar =~ /(sub open_session_uuid \{.*?\n\})/s;
ok($open_sub, 'open_session_uuid is one sub');
like($open_sub, qr/order by timestamp asc limit 1/,
	'the header names the oldest running session, so the stop button echoes it');

my ($target_sub) = $calendar =~ /(sub stop_target_row \{.*?\n\})/s;
ok($target_sub, 'stop_target_row is one sub');
like($target_sub, qr/select \* from appointments where app=\? and \(type=\? or type=\?\) and timestamp <= \? and stop_seen is null order by timestamp asc limit 1/,
	'the unnamed fallback is the oldest open session at or before the press');
like($target_sub, qr/return \(\$named && \$named->\{'uuid'\}\) \? \$named : undef;/,
	'a named session stays a hard match: it never falls through to another row');

my ($guide_sub) = $part29 =~ /(sub guide_open_target\(.*?\n\})/s;
ok($guide_sub, 'guide_open_target is one sub');
like($guide_sub, qr/stop_seen is null order by timestamp asc limit 1/,
	'"stop it" follows the same oldest-first rule');

# --- behaviour: the resolver picks the row the SQL asks for ----------------

# A tiny stand-in for Mojo::SQLite::Results. It honours the ORDER BY the code
# wrote, so the test fails if the query and the chosen row disagree.
my @rows = (
	{ uuid => 'old', type => 'start', timestamp => 1_000, stop_seen => undef },
	{ uuid => 'new', type => 'record', timestamp => 2_000, stop_seen => undef },
	{ uuid => 'shut', type => 'start', timestamp => 500, stop_seen => 'yes' },
);

{
	package StopResults;
	sub new { my ($class, $rows) = @_; bless { rows => $rows }, $class }
	sub hashes { $_[0]->{'rows'} }
}

my @issued;
{
	no warnings 'redefine';
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		push @issued, $sql;
		my @pool = grep {
			(!defined $_->{'stop_seen'} || $_->{'stop_seen'} eq '')
				&& ($_->{'type'} || '') =~ /^(?:start|record)$/
		} @rows;
		if ($sql =~ /uuid=\?/) {
			my $want = $args[1] // '';
			@pool = grep { $_->{'uuid'} eq $want } @pool;
		}
		elsif ($sql =~ /timestamp <=\?/) {
			my $until = $args[3] // 0;
			@pool = grep { $_->{'timestamp'} <= $until } @pool;
		}
		@pool = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @pool
			if $sql =~ /order by timestamp asc/;
		@pool = sort { $b->{'timestamp'} <=> $a->{'timestamp'} } @pool
			if $sql =~ /order by timestamp desc/;
		return StopResults->new(\@pool);
	};

	is(&subs::stop_target_row('laydown', '', 9_999)->{'uuid'}, 'old',
		'a stop that names no session closes the oldest open one');
	is(&subs::stop_target_row('laydown', 'new', 9_999)->{'uuid'}, 'new',
		'a named open session is closed instead');
	ok(!defined &subs::stop_target_row('laydown', 'gone', 9_999),
		'a named session this machine does not hold closes nothing');
	is(&subs::open_session_uuid('laydown'), 'old',
		'the header echoes the oldest open session');
}

done_testing();
