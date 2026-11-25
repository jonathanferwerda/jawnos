# tests-for: lib/JawnOS/Manager/Part09.pm lib/JawnOS/Domain/Sync.pm
# covers:    a whole-table row read remembers the last merged batch *before*
#            fetching the next one, and the next attempt starts after that
#            cursor instead of at row one.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;
require "$FindBin::Bin/../lib/JawnOS/Manager/Part09.pm";

package FakeSync;
sub done { my ($s, $state, $note) = @_; $s->{'state'} = $state; $s->{'note'} = $note; }
package main;

subs::preload('sync_resume_get');
subs::preload('sync_resume_put');
subs::preload('sync_resume_clear');

my $peer = 'e9ce731a06afcab8f8b4b502637a717d';
my $me   = 'de3f1c63ba2b3cfe3910ad2742c5a556';
subs::sync_resume_clear($peer, 'appointments');

my ($calls, $mode, $merged) = ([], 'die', 0);

{
	no warnings 'redefine';
	local *subs::sync_trace = sub { };
	local *subs::log_writer = sub { };
	local *subs::signatorial_designer = sub { $me };
	local *subs::session_suds = sub { 'suds' };
	local *subs::suds_grabber = sub { 'suds' };
	local *subs::decrypter = sub { 'secret' };
	local *subs::device_setter = sub { 'controller' };
	local *subs::sync_table_list = sub { [ 'appointments' ] };
	local *subs::sync_carry_tables = sub { [] };
	local *subs::sync_seen_get = sub { {} };
	local *subs::sync_seen_set = sub { };
	local *subs::sync_bucket_band_for = sub { 7 };
	local *subs::sync_bucket_normalize = sub { $_[0] };
	local *subs::sync_job_step = sub { };
	local *subs::sync_backoff_clear = sub { };
	local *subs::data_size = sub { '0 B' };
	local *Manager::update_database = sub { };
	local *Manager::misc_setting_list = sub { [] };
	local *Manager::sync_buckets_batch = sub { return (undef, 'no map'); };
	local *Manager::merge_finish = sub { };
	local *Manager::merge_table_rows = sub {
		my ($ctx, $table, $next_row) = @_;
		while (my $row = $next_row->()) { $merged++ }
		return 0;
	};
	local *Manager::sync_rows_batch = sub {
		my ($remote, $sig, $secret, $table, $cut, $after) = @_;
		push @{$calls}, { table => $table, cut => $cut, after => $after };
		if ($mode eq 'die' && scalar @{$calls} > 1) {
			die "simulated restart\n";
		}
		if ($mode eq 'resume') {
			return ({ ok => 1, rows => [ { uuid => 'c', server_time => 3 } ], total => 0, next => '', done => 1, wire_bytes => 5 }, undef);
		}
		return ({ ok => 1, rows => [ { uuid => 'a', server_time => 1 }, { uuid => 'b', server_time => 2 } ],
			total => 5000, next => '100', done => 0, wire_bytes => 10 }, undef);
	};

	my $c = bless {}, 'FakeC';
	my $params = {
		remote_signatorial => $peer,
		plan => { appointments => 0 },
		default_cut => 0,
		remote_digest => {},
		gimme => 0,
		database => 'sandbox.db',
	};
	my $remote = {
		manager => 'https://192.0.2.1:3000',
		signatorial => $peer,
		manager_verified => 1,
		data => { manager_colour => '#ffffff' },
		deletions => '[]',
	};
	my $job = 'job-1';

	my $sync1 = bless {}, 'FakeSync';
	my $died = !eval { Manager::sync_rows_pull($c, $params, $sync1, $job, $remote, 'auuid'); 1 };
	like($@, qr/simulated restart/, 'the first attempt is cut off mid-table');
	ok($died, 'as a restart would');

	my $marker = subs::sync_resume_get($peer, 'appointments', 0);
	is(ref $marker, 'HASH', 'the merged batch left a resume marker');
	is($marker->{'after'}, '100', 'the marker names the last merged rowid');
	is($marker->{'total'}, 5000, 'and the count of the read');
	is($calls->[0]->{'after'}, '', 'the first attempt began at row one');
	is(scalar @{$calls}, 2, 'the second fetch is where it stopped');

	$mode = 'resume';
	@{$calls} = ();
	$merged = 0;
	my $sync2 = bless {}, 'FakeSync';
	is(Manager::sync_rows_pull($c, $params, $sync2, $job, $remote, 'auuid'), 'done', 'the next attempt finishes');
	is($calls->[0]->{'after'}, '100', 'and it resumes after the merged cursor, not at row one');
	is($merged, 1, 'only the remaining row is merged');
	is($sync2->{'state'}, 'done', 'the pull reports done');
	ok(!defined subs::sync_resume_get($peer, 'appointments', 0), 'a finished table clears its marker');
}

done_testing();
