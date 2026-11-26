# tests-for: lib/JawnOS/Manager/Part09.pm lib/JawnOS/Domain/Sync.pm
# covers:    A carry-only stream is written while a pull walks it, so a band
#            can return fewer rows than the map named. That is the stream
#            changing, not a lost read, and a row the local schema refuses is
#            the same kind of best-effort miss: neither may fail the pull, or a
#            machine stops on "routers: short read" and nothing behind it
#            merges. A planned table still fails a short band read or a row it
#            could not merge.

use strict;
use warnings;
no warnings 'once';
no warnings 'redefine';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;
require "$FindBin::Bin/../lib/JawnOS/Manager/Part09.pm";

package FakeSync;
sub done { my ($s, $state, $note) = @_; $s->{'state'} = $state; $s->{'note'} = $note; }
package main;

sub fake_result {
	my (@rows) = @_;
	return bless { rows => \@rows }, 'FakeResults';
}
package FakeResults;
sub hashes { return $_[0]->{rows}; }
sub hash { return $_[0]->{rows}[0]; }
package main;

sub run_pull {
	my ($table, $carry, $rows_per_band, $merge_mode) = @_;
	$rows_per_band = 3 unless defined $rows_per_band;
	$merge_mode = 0 unless defined $merge_mode;
	my $peer = 'e9ce731a06afcab8f8b4b502637a717d';
	my $me = 'de3f1c63ba2b3cfe3910ad2742c5a556';
	my ($band_calls, $merged) = (0, 0);
	my $seen_map;
	my $sync = bless {}, 'FakeSync';

	local $subs::sync_table_cache;
	$subs::sync_table_cache = undef;
	local *subs::sync_trace = sub { };
	local *subs::log_writer = sub { };
	local *subs::signatorial_designer = sub { $me };
	local *subs::rightNow = sub { 1_700_000_000_000 };
	local *subs::random_string_creator = sub { 'TRACE' };
	local *subs::session_suds = sub { 'suds' };
	local *subs::suds_grabber = sub { 'suds' };
	local *subs::decrypter = sub { 'secret' };
	local *subs::device_setter = sub { 'controller' };
	local *subs::db_query = sub { return fake_result() };
	local *subs::db_select = sub {
		my ($q) = @_;
		return fake_result({ credential => 'cred' }) if $q eq 'security';
		return fake_result();
	};
	local *subs::sync_table_list = sub { [ $table ] };
	local *subs::sync_carry_tables = sub { $carry ? [ $table ] : [] };
	local *subs::sync_seen_get = sub { {} };
	local *subs::sync_seen_set = sub { $seen_map = $_[1] };
	local *subs::sync_bucket_band_for = sub { 7 };
	local *subs::sync_bucket_normalize = sub { $_[0] };
	local *subs::sync_table_buckets = sub { { band => 7, buckets => {} } };
	local *subs::sync_bucket_gaps = sub { [ 1, 2 ] };
	local *subs::sync_bucket_diff = sub { [ 1, 2 ] };
	local *subs::sync_bucket_range = sub { ($_[1], $_[1] + 1) };
	local *subs::sync_job_step = sub { };
	local *subs::sync_backoff_active = sub { 0 };
	local *subs::sync_backoff_clear = sub { };
	local *subs::sync_bands_complete = sub { 0 };
	local *subs::data_size = sub { '1 KB' };
	local *Manager::update_database = sub { };
	local *Manager::misc_setting_list = sub { [] };
	local *Manager::merge_finish = sub { };
	local *Manager::sync_buckets_batch = sub {
		# Four buckets of five rows: bands 1 and 2 are half, so the pull walks
		# them rather than reading the table whole.
		return ({
			band => 7,
			server_time => 1_700_000_000_000,
			buckets => {
				1 => { count => 5, sum => 5, max => 5 },
				2 => { count => 5, sum => 5, max => 5 },
				3 => { count => 5, sum => 5, max => 5 },
				4 => { count => 5, sum => 5, max => 5 },
			},
		}, undef);
	};
	local *Manager::sync_rows_batch = sub {
		$band_calls++;
		# Each band answers with the rows the test asks for: three where the map
		# named five is a short read, five is a complete band.
		my @rows = map { { uuid => chr(96 + $_) . $band_calls, server_time => $_ } } 1 .. $rows_per_band;
		return ({
			ok => 1,
			rows => \@rows,
			next => '', done => 1, wire_bytes => 10,
		}, undef);
	};
	local *Manager::merge_table_rows = sub {
		my ($ctx, $q, $next_row) = @_;
		while (my $row = $next_row->()) { $merged++ }
		return $merge_mode;
	};

	my $c = bless {}, 'FakeC';
	my $params = {
		remote_signatorial => $peer,
		plan => { $table => 0 },
		default_cut => 0,
		remote_digest => { $table => { count => 20, sum => 20, max => 5 } },
		gimme => 0,
		database => 'sandbox.db',
	};
	my $remote = {
		manager => 'https://192.0.2.1:3000',
		manager_verified => 1,
		signatorial => $peer,
		deletions => '[]',
		data => { manager_colour => 'blue', device => 'computer' },
	};
	my $status = Manager::sync_rows_pull($c, $params, $sync, 'job-1', $remote, 'auuid');
	return ($status, $sync, $band_calls, $merged, $seen_map);
}

my ($status, $sync, $band_calls, $merged) = run_pull('routers', 1);
is($status, 'done', 'a short band read on a carry table does not fail the pull');
is($sync->{state}, 'done', 'the sync job finishes');
ok($band_calls >= 2, 'the pull still walked the carry table\'s bands');
is($merged, 6, 'every row that arrived was merged');

($status, $sync, $band_calls, $merged) = run_pull('routers', 1, 5, 1);
is($status, 'done', 'a refused row on a carry table does not fail the pull either');
is($sync->{state}, 'done', 'the job still finishes as done');
is($merged, 10, 'the rows that could merge did');

($status, $sync, $band_calls, $merged) = run_pull('appointments', 0);
is($status, 'failed', 'a short band read on a planned table still fails');
like($sync->{note}, qr/^appointments: short band read: 6 of 10/,
	'and names the table and the count it fell short of');

($status, $sync, $band_calls, $merged) = run_pull('appointments', 0, 5, 1);
is($status, 'failed', 'a refused row on a planned table still fails');
like($sync->{note}, qr/^appointments: short read$/,
	'and the note names the table');

done_testing();
