# tests-for: lib/JawnOS/Manager/Part14.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Manager/Part29.pm
# covers:    a stop resolves one (oldest) open session before the relay, so every machine closes the same uuid; a named session is a hard match while it is still open and had started by the press; a name this machine does not hold - or holds already closed by this same press - closes nothing, so one relayed press cannot close a different same-name session on each machine; a name closed by an earlier press (the panel one header behind) or begun after a backdated press falls back to the oldest open session at or before that moment, bounded so a late duplicate or a time-machine stop never closes a newer one

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

my $stop_resolve = index($part14, "if (\$type eq 'stop') {");
my $relay        = index($part14, "&remote_relay_request(\$c, { dissemination => 'yes' })");
ok($stop_resolve >= 0, 'manager_reset resolves a stop that named no session');
ok($relay >= 0, 'and it still relays the press');
ok($stop_resolve < $relay, 'the resolution happens before the relay, so the uuid travels with it');

my ($between) = $part14 =~ /(my \$target_uuid = .*?&remote_relay_request\(\$c, \{ dissemination => 'yes' \}\);)/s;
like($between, qr/&subs::stop_target_row\(\$app, \$target_uuid, \$timestamp\)/,
	'the press is resolved before the relay even when the client named a session');
like($between, qr/\$target_uuid = \(\$resolved && \$resolved->\{'uuid'\}\) \? \$resolved->\{'uuid'\} : &subs::random_string_creator\(40\);/,
	'a press that closes nothing travels with a uuid no row holds');
like($between, qr/\$uuid = \$target_uuid;\s*\$c->param\('uuid' => \$uuid\);/,
	'and the resolved uuid replaces whatever the relay would have sent');

# --- the stop resolvers name the oldest open session ------------------------

my ($open_sub) = $calendar =~ /(sub open_session_uuid \{.*?\n\})/s;
ok($open_sub, 'open_session_uuid is one sub');
like($open_sub, qr/order by timestamp asc limit 1/,
	'the header names the oldest running session, so the stop button echoes it');

my ($target_sub) = $calendar =~ /(sub stop_target_row \{.*?\n\})/s;
ok($target_sub, 'stop_target_row is one sub');
like($target_sub, qr/select \* from appointments where app=\? and \(type=\? or type=\?\) and timestamp <= \? and stop_seen is null order by timestamp asc limit 1/,
	'the unnamed fallback is the oldest open session at or before the press');
like($target_sub, qr/my \$started = defined \$named->\{'timestamp'\} \? \(0 \+ \$named->\{'timestamp'\}\) : 0;/,
	'a named session is bounded by the press moment');
like($target_sub, qr/return \$named if \$started <= \(0 \+ \$timestamp\);/,
	'a named open session is closed on its own unless it began after the press');
like($target_sub, qr/select \* from appointments where uuid=\? limit 1/,
	'a named session is looked up by its uuid alone, so absence is distinguishable from closure');
like($target_sub, qr/return undef unless \$named && \(\$named->\{'app'\} \/\/ ''\) eq \$app;/,
	'a name this machine does not hold - or holds under another app - closes nothing');
like($target_sub, qr/\(0 \+ \$named->\{'stop_timestamp'\}\) == \(0 \+ \$timestamp\)/,
	'a name this press already closed closes nothing on a relayed copy');
like($target_sub, qr/timestamp <= \? and stop_seen is null order by timestamp asc limit 1/,
	'a name closed by an earlier press falls back to the bounded oldest open one');

my ($guide_sub) = $part29 =~ /(sub guide_open_target\(.*?\n\})/s;
ok($guide_sub, 'guide_open_target is one sub');
like($guide_sub, qr/stop_seen is null order by timestamp asc limit 1/,
	'"stop it" follows the same oldest-first rule');

# --- behaviour: the resolver picks the row the SQL asks for ----------------

# A tiny stand-in for Mojo::SQLite::Results. It honours the ORDER BY the code
# wrote, so the test fails if the query and the chosen row disagree.
my @rows = (
	{ app => 'laydown', uuid => 'old', type => 'start', timestamp => 1_000, stop_seen => undef },
	{ app => 'laydown', uuid => 'new', type => 'record', timestamp => 2_000, stop_seen => undef },
	{ app => 'laydown', uuid => 'shut', type => 'stop', timestamp => 500, stop_seen => 'yes', stop_timestamp => 800 },
	{ app => 'other', uuid => 'elsewhere', type => 'start', timestamp => 500, stop_seen => undef },
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
		my @pool = @rows;
		if ($sql =~ /where uuid=\?/) {
			# the stop resolver's own lookup: any row, open or closed, by uuid
			my $want = $args[0] // '';
			@pool = grep { $_->{'uuid'} eq $want } @pool;
		}
		elsif ($sql =~ /uuid=\?/) {
			my $want = $args[1] // '';
			@pool = grep {
				$_->{'app'} eq $args[0]
					&& (!defined $_->{'stop_seen'} || $_->{'stop_seen'} eq '')
					&& ($_->{'type'} || '') =~ /^(?:start|record)$/
					&& $_->{'uuid'} eq $want
			} @pool;
		}
		elsif ($sql =~ /timestamp <= \?/) {
			my $until = $args[3] // 0;
			@pool = grep {
				$_->{'app'} eq $args[0]
					&& (!defined $_->{'stop_seen'} || $_->{'stop_seen'} eq '')
					&& ($_->{'type'} || '') =~ /^(?:start|record)$/
					&& $_->{'timestamp'} <= $until
			} @pool;
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
	is(&subs::stop_target_row('laydown', 'old', 1_500)->{'uuid'}, 'old',
		'a timeline between two open sessions stops the one before it, named or not');
	is(&subs::stop_target_row('laydown', 'new', 1_500)->{'uuid'}, 'old',
		'a backdated press never closes a session begun after that moment; it closes the oldest open before it');
	ok(!defined &subs::stop_target_row('laydown', 'new', 500),
		'a backdated press before every open session closes nothing rather than a later one');

	# One press must not close a different session on a machine whose copy lacks
	# the named row: that is how two same-name sessions ended together.
	ok(!defined &subs::stop_target_row('laydown', 'gone', 9_999),
		'a named session this machine does not hold closes nothing, not another open one');
	ok(!defined &subs::stop_target_row('laydown', 'gone', 1_500),
		'a name this machine does not hold stays closed even with a session before the press');
	ok(!defined &subs::stop_target_row('laydown', 'gone', 500),
		'a stop stamped before every open session closes nothing');
	ok(!defined &subs::stop_target_row('laydown', 'elsewhere', 9_999),
		'a row under another app is not this app\'s session to close');

	# A relayed copy arrives after the origin closed the named row. Its stop
	# timestamp is this press, so it is the same closure, not a stale header.
	ok(!defined &subs::stop_target_row('laydown', 'shut', 800),
		'a name this press already closed closes nothing on a relayed copy');
	is(&subs::stop_target_row('laydown', 'shut', 5_000)->{'uuid'}, 'old',
		'a name closed by an earlier press is the stale header, so it falls back to the oldest open one');
	is(&subs::open_session_uuid('laydown'), 'old',
		'the header echoes the oldest open session');
}

done_testing();
