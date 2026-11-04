# tests-for: lib/JawnOS/Domain/Sync.pm templates/start_menu/htop.html.ep public/js/manager/manager/05_start_menu.js
# covers:    the System card's sync line reports rows moved and the time left at
#            the job's own pace, and the card polls it every ten seconds.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);
use Mojo::JSON qw(encode_json);

require JawnOS::Domain::Sync;

ok( subs::provides('sync_progress'), 'the domain loader maps sync_progress' );
ok( defined &subs::sync_progress, 'Domain::Sync defines it' );

# sync_jobs is read through db_query; the fixtures below stand in for the table
# so the live database is never touched.
{
	package FakeRows;
	sub new { my ($class, $rows) = @_; return bless { rows => $rows }, $class; }
	sub hashes { return $_[0]->{'rows'}; }
}

my $now = subs::rightNow();

sub progress_for {
	my ($job) = @_;
	local *subs::db_query = sub {
		my ($sql) = @_;
		return FakeRows->new([]) if defined $sql && $sql =~ /^\s*update/i;
		return FakeRows->new([ $job ]);
	};
	return subs::sync_progress();
}

# A running pull: two tables moved 600 of 2,100 rows in ten seconds.
# sync_jobs stores its steps as JSON, so the fixture does too. sync_job_list
# replaces the string with the decoded list on the hash it is given, hence a
# fresh copy per job instead of sharing one.
my $steps = sub {
	return encode_json([
		{ key => 'merge:appointments', state => 'running', current => 500, total => 2000 },
		{ key => 'merge:continent',    state => 'done',    current => 100, total => 100 },
		# The pull's own marker carries no rows; counting it would double the work.
		{ key => 'merge', state => 'running', current => 0, total => 0 },
	]);
};
my $running = {
	uuid => 'abc', direction => 'pull', peer => '100.64.0.9', phase => 'merge',
	state => 'running', current => 0, total => 0, note => '',
	started => $now - 10000, updated => $now,
	steps => $steps->(),
};
my $sp = progress_for($running);
is( $sp->{'rows'}, 600, 'rows are summed from the per-table steps only' );
is( $sp->{'total'}, 2100, 'the total is the same sum of the steps' );
ok( $sp->{'active'}, 'a running job reads as active' );
is( int($sp->{'rate'}), 60, 'the pace is the job\'s own rows over its own elapsed seconds' );
is( $sp->{'eta'}, 25, 'time left is the rows remaining at that pace' );

# A finished pull still names what it moved, but must not invent an estimate.
my $done = { %{$running}, state => 'done', note => 'rows merged 600', steps => $steps->() };
$sp = progress_for($done);
ok( !$sp->{'active'}, 'a done job is not active' );
ok( !defined $sp->{'eta'}, 'a finished job has no time left to report' );
is( $sp->{'rows'}, 600, 'the finished job keeps its row count' );
ok( defined $sp->{'age'} && $sp->{'age'} < 5, 'the age is seconds since the job last moved' );

# Nothing has run: the card has nothing to say.
$sp = progress_for(undef);
ok( !$sp->{'known'}, 'an empty table reports no job' );
is( $sp->{'rows'}, 0, 'and no rows' );

# A rate needs a real window: one instant is noise, not a pace.
my $instant = { %{$running}, started => $now, updated => $now, steps => $steps->() };
$sp = progress_for($instant);
ok( !defined $sp->{'eta'}, 'no estimate from a job that has not spent a second yet' );

# The card is live at ten seconds and shows the line inside the swapped block.
my $card = read_file('templates/start_menu/htop.html.ep');
like( $card, qr/sync_progress\(\)/, 'the card asks for the sync progress' );
like( $card, qr/<div id="htop_viewer">[\s\S]*levels_sync/, 'the sync line lives inside the block the poll replaces' );
my $js = read_file('public/js/manager/manager/05_start_menu.js');
like( $js, qr/setTimeout\(function\(\) \{ htopViewer\(\); \}, 10000\)/, 'the System card polls every ten seconds' );

done_testing();
