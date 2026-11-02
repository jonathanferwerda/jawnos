# tests-for: scripts/records_recover.pl
# covers:    the recovery CLI - the refusal it must never skip, and the options
#           that decide what may be written

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;

# records_recover puts appointment ends back after a repair shortened them. It is
# the one tool that writes sessions back, so the behaviour worth pinning is the
# refusal: --apply must not write unless a snapshot younger than ten minutes
# exists, and a scan error must write nothing either.
#
# The domain subs are stubbed, so this reads no database: what is under test is
# the CLI - the options it parses, the gate it applies and the exit code it
# reports - not the recovery itself (that is Records2.pm, exercised elsewhere).

my $root = "$FindBin::Bin/..";
require "$root/scripts/records_recover.pl";

my (@scan_opts, $applied, %stub);
$applied = 0;

{
	no warnings 'redefine';
	*subs::iso_local = sub { return '2026-11-02 10:00:00' };
	*subs::records_recover_scan = sub {
		my ($opts) = @_;
		push @scan_opts, $opts;
		return $stub{'scan'};
	};
	*subs::records_backup_ensure_fresh = sub { return $stub{'fresh'} };
	*subs::records_recover_apply = sub { $applied++; return $stub{'applied'} };
}

sub scan_for {
	my %a = @_;
	return {
		'backup'        => $a{'backup'} // 'snapshot-1.tar',
		'snapshot_time' => 1_700_000_000_000,
		'summary'       => {
			'old_rows'   => $a{'old_rows'}   // 2,
			'candidates' => $a{'candidates'} // 1,
			'shortened'  => $a{'shortened'}  // 1,
			'missing'    => $a{'missing'}    // 0,
		},
		'candidates' => [ {
			'action'         => 'RESTORE',
			'app'            => 'home',
			'start'          => 1_700_000_000_000,
			'old_span_ms'    => 3_600_000,
			'live_span_ms'   => 60_000,
			'app_duration'   => 60_000,
			'status'         => 'd',
			'named'          => 1,
		} ],
	};
}

# Run the CLI and capture what it printed.
sub run_cli {
	my @args = @_;
	my $buf = '';
	open my $fh, '>', \$buf or die "capture: $!";
	my $rc;
	{
		local *STDOUT = $fh;
		$rc = main(@args);
	}
	close $fh;
	return ($rc, $buf);
}

# --- a scan error writes nothing --------------------------------------------
{
	@scan_opts = ();
	$applied   = 0;
	$stub{'scan'} = { 'error' => 'no snapshot found' };
	my ($rc, $out) = run_cli('--apply');
	is($rc, 1, 'a scan error exits 1');
	like($out, qr/records recovery: no snapshot found/, 'and carries the reason');
	is($applied, 0, 'and nothing is applied');
}

# --- without --apply, nothing is written ------------------------------------
{
	$applied = 0;
	$stub{'scan'} = scan_for();
	my ($rc, $out) = run_cli();
	is($rc, 0, 'a dry run exits 0');
	like($out, qr/1 candidate\(s\): 1 shortened, 0 dropped/, 'and reports the candidates');
	like($out, qr/live matches the app length; the shorter value is the correct repair/,
		'flagging a live value that matches the app length');
	like($out, qr/nothing written/, 'and says so');
	is($applied, 0, 'with nothing applied');
}

# --- --json is the machine form, and still writes nothing -------------------
{
	$applied = 0;
	$stub{'scan'} = scan_for();
	my ($rc, $out) = run_cli('--json');
	is($rc, 0, '--json exits 0');
	like($out, qr/"backup":"snapshot-1\.tar"/, 'and carries the scan');
	is($applied, 0, 'still without writing');
}

# --- the gate: no fresh snapshot, no write ----------------------------------
{
	$applied = 0;
	$stub{'scan'}  = scan_for();
	$stub{'fresh'} = { 'fresh' => 0 };
	my ($rc, $out) = run_cli('--apply');
	is($rc, 1, '--apply without a fresh snapshot exits 1');
	like($out, qr/refusing to apply: no snapshot younger than ten minutes could be taken/,
		'and refuses by name');
	is($applied, 0, 'the refusenik writes nothing - this is the gate that matters');
}

# --- and with one, it applies -----------------------------------------------
{
	$applied = 0;
	$stub{'scan'}       = scan_for();
	$stub{'fresh'}      = { 'fresh' => 1, 'made' => 1, 'path' => '/tmp/snapshot.tar' };
	$stub{'applied'}    = { 'restored' => 1, 'reinstated' => 0, 'skipped' => 0, 'failed' => 0, 'exempted' => [] };
	my ($rc, $out) = run_cli('--apply');
	is($rc, 0, '--apply with a fresh snapshot exits 0');
	like($out, qr/safety snapshot: taken now - \/tmp\/snapshot\.tar/, 'the snapshot is reported');
	like($out, qr/recovery APPLIED: 1 restored/, 'and the result');
	is($applied, 1, 'applied exactly once');
}

# --- the options reach the scan ---------------------------------------------
{
	@scan_opts = ();
	$stub{'scan'} = scan_for();
	run_cli('--json', '--apps', 'store,home', '--older-than', '2h', '--backup', '/tmp/old.tar');
	is(scalar @scan_opts, 1, 'the scan is asked once');
	is_deeply($scan_opts[0]{'apps'}, [ 'store', 'home' ], '--apps is split on the comma');
	is($scan_opts[0]{'older_than_ms'}, 7_200_000, '--older-than 2h is milliseconds');
	is($scan_opts[0]{'backup'}, '/tmp/old.tar', '--backup names the snapshot');

	@scan_opts = ();
	run_cli('--json', '--older-than', '3d');
	is($scan_opts[0]{'older_than_ms'}, 259_200_000, '--older-than 3d is milliseconds');
}

done_testing();
