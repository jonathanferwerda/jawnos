# tests-for: templates/apps/clothesline/flow.html.ep templates/apps/clothesline.html.ep lib/JawnOS/Controller/manager_misc6.pm lib/JawnOS/Domain/Misc.pm
# covers:    The clothesline now paints the day's window flow from window_events:
#            window_events_spans pairs each open with its close, and the flow
#            partial draws one row per app and one bar per span across the house
#            clock's 24 hours, naming the app and the time range on every bar and
#            marking a span still open apart from a closed one. The read is
#            bounded to today and guarded, so no events (or a missing table)
#            renders no strip and no error, and the rail route carries the same
#            server-rendered strip in its reply.

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
my ($flow_fh, $flow_file) = tempfile('jawnos-flow-XXXXXX', TMPDIR => 1, UNLINK => 1);
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

# The house day the strip draws: midnight to midnight on the person's clock,
# read the same way the partial reads it.
my $now = &subs::rightNow();
my $restore_zone = &subs::clock_zone_adopt(&subs::clock_zone_house()) || sub { };
my @house_now = localtime(int($now / 1000));
my $day_from = Time::Local::timelocal(0, 0, 0, $house_now[3], $house_now[4], $house_now[5]) * 1000;
my $day_to = Time::Local::timelocal(0, 0, 0, $house_now[3] + 1, $house_now[4], $house_now[5]) * 1000 - 1;
$restore_zone->();

my $hour = 3600 * 1000;
my $seed = sub {
	my ($uuid, $window_id, $app, $event, $at, $tab) = @_;
	$flow_db->query(
		q{insert into window_events (uuid, window_id, browser_tab_id, app, event, timestamp, server_time, hostname, warranty, ost)
		  values (?,?,?,?,?,?,?,?,?,?)},
		$uuid, $window_id, $tab, $app, $event, $at, $at, 'test-box', $at + 86400000, $at,
	);
};

# Two whole windows and one still open, all on today's house day.
$seed->('f1', 'window_notes', 'notes',   'open',  $day_from + (8 * $hour), 'tab-flow');
$seed->('f2', 'window_notes', 'notes',   'close', $day_from + (9 * $hour), 'tab-flow');
$seed->('f3', 'window_mail',  'mailbox', 'open',  $day_from + (13 * $hour), 'tab-flow');
$seed->('f4', 'window_mail',  'mailbox', 'close', $day_from + (14 * $hour), 'tab-flow');
$seed->('f5', 'window_clock', 'clock',   'open',  $day_from + (11 * $hour), 'tab-flow');

my $mt = Mojo::Template->new(vars => 1, auto_escape => 1);
my $partial = "$root/templates/apps/clothesline/flow.html.ep";
my $html = eval { $mt->render_file($partial, {}) };
is($@, '', 'the flow strip renders without error');

my @bars = ($html =~ /class="clothes_flow_bar /g);
is(scalar @bars, 3, 'one bar per span');
is(scalar(() = $html =~ /class="clothes_flow_bar clothes_flow_closed"/g), 2,
	'a closed span is drawn as closed');
is(scalar(() = $html =~ /class="clothes_flow_bar clothes_flow_open"/g), 1,
	'a span still open is drawn apart from a closed one');

like($html, qr/id="clothes_flow_notes"/, 'a row names the notes app');
like($html, qr/id="clothes_flow_mailbox"/, 'a row names the mailbox app');
like($html, qr/id="clothes_flow_clock"/, 'a row names the clock app');

my $eight = &subs::clock_zone_text($day_from + (8 * $hour), undef, '%I:%M%P');
my $nine = &subs::clock_zone_text($day_from + (9 * $hour), undef, '%I:%M%P');
like($html, qr/title="\QNotes, open $eight to $nine\E"/,
	'the bar title names the app and the house-clock range');
like($html, qr/title="Clock, open [^"]+, still open"/,
	'an open span says it is still open');
like($html, qr/aria-label="\QNotes, open $eight to $nine\E"/,
	'the bar carries the same words to a screen reader');
like($html, qr/style="left: [\d.]+%; width: [\d.]+%;"/,
	'the bar is placed and sized across the day');

# The rail route carries the same server-rendered strip: a stand-in controller
# renders the partial for real and keeps the JSON the action would send.
my $render_partial = sub {
	my ($name) = @_;
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
my $rail = FakeRailController->new();
eval { Manager::action_25345($rail) };
is($@, '', 'the rail action answers with the flow strip');
my $flow = $rail->{'payload'}->{'flow'} // '';
like($flow, qr/class="clothes_flow_bar /, 'the rail reply carries the painted strip');
is(scalar(() = $flow =~ /class="clothes_flow_bar /g), 3, 'and every span is on it');

# No events means no strip: not an empty box, not an error.
$flow_db->query('delete from window_events');
my $empty = eval { $mt->render_file($partial, {}) };
is($@, '', 'an empty day renders without error');
unlike($empty, qr/clothes_flow/, 'an empty day draws no strip at all');

done_testing();
