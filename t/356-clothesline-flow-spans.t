# tests-for: lib/JawnOS/Controller/manager_misc6.pm lib/JawnOS/Domain/Misc.pm
# covers:    action_25345 now carries the day's window flow as numbers for the
#            rail canvas: flow_spans is [ from_ms, to_ms, open_flag, app ] per
#            span, bounded to today on the house clock, with an open span ending
#            at now, and flow_day names those bounds. Yesterday is absent, the
#            painted strip is still in the reply, and a day of more than 300
#            spans thins evenly to the cap rather than truncating.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::SQLite;
use Mojo::Template;
use Time::Local ();
use RepoSource qw(repo_root);
use JawnOSTest ();

my $root = repo_root();

# A private database from the shipped schema, so the seed below is the only
# window flow it holds. table_holder is how the domain reads a database, so
# point it at this file before any read runs.
my ($flow_fh, $flow_file) = tempfile('jawnos-flow-spans-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $flow_fh;
my $flow_sql = Mojo::SQLite->new('sqlite:' . $flow_file);
my $flow_db = $flow_sql->db;
my $schema = read_file("$root/database/schema.sql");
my @statements = grep { /\S/ } split /;[ \t]*\n/, $schema;
my @failed;
for my $statement ( @statements ) {
	my $ok = eval { $flow_db->query($statement); 1 };
	push @failed, ($@ || 'failed') unless $ok;
}
is_deeply(\@failed, [], 'the schema builds the flow database') or diag(join("\n", @failed));

my @flow_stat = stat($flow_file);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $flow_file,
	db          => $flow_db,
	dbh         => $flow_db->dbh,
	sql         => $flow_sql,
	pid         => $$,
	dev         => $flow_stat[0],
	ino         => $flow_stat[1],
};

# The house day the action bounds its read to, read the same way it reads it.
my $now = &subs::rightNow();
my $restore_zone = &subs::clock_zone_adopt(&subs::clock_zone_house()) || sub { };
my @house_now = localtime(int($now / 1000));
my $day_from = Time::Local::timelocal(0, 0, 0, $house_now[3], $house_now[4], $house_now[5]) * 1000;
my $day_to = Time::Local::timelocal(0, 0, 0, $house_now[3] + 1, $house_now[4], $house_now[5]) * 1000 - 1;
$restore_zone->();

my $hour = 3600 * 1000;
# the still-open span must begin before the action's "now", whatever the
# clock says: halfway between midnight and now is always in the past today
my $clock_open = $day_from + int(($now - $day_from) / 2);
my $seed = sub {
	my ($uuid, $window_id, $app, $event, $at, $tab) = @_;
	$flow_db->query(
		q{insert into window_events (uuid, window_id, browser_tab_id, app, event, timestamp, server_time, hostname, warranty, ost)
		  values (?,?,?,?,?,?,?,?,?,?)},
		$uuid, $window_id, $tab, $app, $event, $at, $at, 'test-box', $at + 86400000, $at,
	);
};

# Two whole windows today and one still open; one window yesterday, which the
# day-bounded read must never carry.
$seed->('s1', 'window_notes_s', 'notes',   'open',  $day_from + (8 * $hour), 'tab-spans');
$seed->('s2', 'window_notes_s', 'notes',   'close', $day_from + (9 * $hour), 'tab-spans');
$seed->('s3', 'window_clock_s', 'clock',   'open',  $clock_open, 'tab-spans');
$seed->('s4', 'window_mail_s',  'mailbox', 'open',  $day_from - (10 * $hour), 'tab-spans');
$seed->('s5', 'window_mail_s',  'mailbox', 'close', $day_from - (9 * $hour), 'tab-spans');

# A stand-in controller renders the strip for real and keeps the JSON the action
# would send, as t/354 does.
my $render_partial = sub {
	my ($name) = @_;
	my $mt = Mojo::Template->new(vars => 1, auto_escape => 1);
	return $mt->render_file("$root/templates/$name.html.ep", {});
};
{
	package FakeRailController;
	sub new { return bless {}, shift }
	sub param { return '' }
	sub render_to_string {
		my ($self, %opt) = @_;
		return $render_partial->($opt{'template'});
	}
	sub render {
		my ($self, %arg) = @_;
		$self->{'payload'} = $arg{'json'};
		return 1;
	}
}

require "$root/lib/JawnOS/Controller/manager_misc6.pm";
my $now_before = &subs::rightNow();
my $rail = FakeRailController->new();
eval { Manager::action_25345($rail) };
my $now_after = &subs::rightNow();
is($@, '', 'the rail action answers');
my $payload = $rail->{'payload'} || {};

my $spans = $payload->{'flow_spans'};
is(ref $spans, 'ARRAY', 'the reply carries flow_spans as an array');
is(scalar @{$spans}, 2, 'today carries its two spans and not the one from yesterday');
like($payload->{'flow'} // '', qr/class="clothes_flow_bar /, 'the reply still carries the painted strip');

my ($notes) = grep { $_->[3] eq 'notes' } @{$spans};
is_deeply($notes, [ $day_from + (8 * $hour), $day_from + (9 * $hour), 0, 'notes' ],
	'a closed span keeps its open and close in milliseconds, marked closed');
my ($clock) = grep { $_->[3] eq 'clock' } @{$spans};
ok($clock, 'the still-open span is carried');
is($clock->[0], $clock_open, 'an open span starts at its open');
is($clock->[2], 1, 'and is marked open');
cmp_ok($clock->[1], '>=', $now_before, 'an open span ends at now');
cmp_ok($clock->[1], '<=', $now_after, 'and not later');
is(scalar(grep { $_->[3] eq 'mailbox' } @{$spans}), 0, 'yesterday is absent from the band');

is_deeply($payload->{'flow_day'}, [ $day_from, $day_to ], 'the reply states the house day');

# The band is bounded: more than 300 spans in a day are thinned to 300, still
# covering the whole day rather than truncating at noon.
$flow_db->query('delete from window_events');
my $cap = 305;
for my $i (0 .. $cap - 1) {
	my $at = $day_from + $hour + ($i * 120000);
	my $wid = 'window_cap_' . $i;
	$seed->("cap${i}o", $wid, 'notes', 'open',  $at, 'tab-cap');
	$seed->("cap${i}c", $wid, 'notes', 'close', $at + 60000, 'tab-cap');
}
my $rail_cap = FakeRailController->new();
eval { Manager::action_25345($rail_cap) };
is($@, '', 'the rail action answers a busy day');
my $capped = $rail_cap->{'payload'}->{'flow_spans'};
is(ref $capped, 'ARRAY', 'a busy day still carries flow_spans');
is(scalar @{$capped}, 300, 'the reply is capped at 300 spans');
cmp_ok($capped->[-1][0], '>', $day_from + (9 * $hour), 'the cap thins across the day, not just the morning');

done_testing();
