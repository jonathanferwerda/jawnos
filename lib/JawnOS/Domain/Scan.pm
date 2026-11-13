package subs;

# Scan: the house's scan readiness ledger and the scan job delegation.
#
# The ADF watcher must not be run by every machine that can see the printer:
# two watchers mean two notices and two scans. This mirrors the AI evaluation
# ledger: each machine publishes whether it can reach an eSCL printer, the
# preferred one is elected as the dispatcher (a computer first, a phone only as
# the fallback), and the dispatcher writes one job row for the loaded edge. The
# job carries the scan id and the owner, so a notice that reaches another
# machine cannot start a second scan there.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.

use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Mojo::JSON qw(decode_json encode_json);
use JawnOS::Platform::Print ();

our $device;
our $log;

our $scan_ledger_ready;

# The ledger is created here rather than in database/schema.sql for the same
# reason as ai_house/ai_jobs: a machine that starts before the table exists
# creates it on its first pass, and the sync then carries the rows.
sub scan_house_heartbeat {
	unless ($scan_ledger_ready) {
		foreach my $sql (
			'create table if not exists scan_house (uuid VARCHAR(255), machine VARCHAR(255) unique, device VARCHAR(25), hostname VARCHAR(255), printer VARCHAR(255), scan_ready INT, seen VARCHAR(25), ost VARCHAR(255), server_time VARCHAR(255))',
			'create table if not exists scan_jobs (uuid VARCHAR(255), job VARCHAR(255) unique, owner VARCHAR(255), printer VARCHAR(255), scan_id VARCHAR(64), at VARCHAR(25), state VARCHAR(25), ost VARCHAR(255), server_time VARCHAR(255))',
			'create unique index if not exists idx_scan_house_machine on scan_house (machine)',
			'create unique index if not exists idx_scan_jobs_job on scan_jobs (job)',
		) {
			eval { &db_query($sql) };
		}
		$scan_ledger_ready = 1;
	}
	return &scan_house_publish();
}

sub scan_house_me {
	return eval { &signatorial_designer() } || '';
}

# What this machine can do right now: a computer or a phone that reaches an
# eSCL printer with an ADF or platen is ready to scan. The row is refreshed at
# most once a minute, and only when something changed, so the settings/sync
# churn stays out of it.
sub scan_house_publish {
	my $me = &scan_house_me();
	return 0 unless length $me;
	my $now = &rightNow();
	my $device = &device_setter() || '';
	my $host = &machine_hostname() || '';
	my $ip = &printer_live_ip() || '';
	my $ready = 0;
	if ($ip) {
		my $caps = eval { JawnOS::Platform::Print::scan_capabilities($ip) } || {};
		$ready = 1 if $caps->{'adf'} || $caps->{'platen'};
	}
	my $row = eval { &db_select('scan_house', undef, { machine => $me })->hashes->[0] };
	return 0 if $row
		&& (($row->{'seen'} || 0) + 0) > ($now - 60000)
		&& ((($row->{'scan_ready'} || 0) ? 1 : 0) == $ready)
		&& (($row->{'printer'} || '') eq $ip)
		&& (($row->{'device'} || '') eq $device)
		&& (($row->{'hostname'} || '') eq $host);
	eval { &db_delete('scan_house', { machine => $me }) };
	my $wrote = eval {
		&db_insert('scan_house', {
			uuid => 'scan-house-' . &path_name($me),
			machine => $me,
			device => $device,
			hostname => $host,
			printer => $ip,
			scan_ready => $ready,
			seen => $now,
			server_time => $now,
		});
	};
	return $wrote ? 1 : 0;
}

# The machines that can scan now. A peer counts only while its heartbeat is
# fresh; this machine is probed directly when its own row has not been written
# yet.
sub scan_house_members {
	my $now = &rightNow();
	my $me = &scan_house_me();
	my (@out, %seen);
	my $rows = eval { &db_select('scan_house')->hashes } || [];
	foreach my $r (@{ $rows || [] }) {
		next unless $r->{'machine'} && $r->{'scan_ready'};
		next unless (($r->{'seen'} || 0) + 0) > ($now - 5 * 60000);
		next if $seen{$r->{'machine'}}++;
		push @out, $r;
	}
	if (length $me && !$seen{$me}) {
		my $ip = &printer_live_ip() || '';
		if ($ip) {
			my $caps = eval { JawnOS::Platform::Print::scan_capabilities($ip) } || {};
			if ($caps->{'adf'} || $caps->{'platen'}) {
				push @out, {
					machine => $me,
					device => &device_setter() || '',
					hostname => &machine_hostname() || '',
					printer => $ip,
					scan_ready => 1,
					seen => $now,
				};
			}
		}
	}
	return @out;
}

# One dispatcher: a computer (or a server, which is a computer on the LAN)
# before a phone or tablet, and the Table before another computer. The ranking
# is deterministic, so every machine elects the same one from the same rows.
sub scan_dispatcher {
	my @rows = &scan_house_members();
	return '' unless @rows;
	my $rank = sub {
		my ($r) = @_;
		my $mobile = (($r->{'device'} || '') eq 'mobile') ? 1 : 0;
		my $table = (($r->{'hostname'} || '') =~ /table/i) ? 0 : 1;
		return ($mobile, $table);
	};
	my @sorted = sort {
		my @a = $rank->($a);
		my @b = $rank->($b);
		$a[0] <=> $b[0]
			|| $a[1] <=> $b[1]
			|| (($a->{'machine'} || '') cmp ($b->{'machine'} || ''))
	} @rows;
	return $sorted[0]{'machine'} // '';
}

sub scan_dispatcher_here {
	my $me = &scan_house_me();
	return 0 unless length $me;
	return (&scan_dispatcher() eq $me) ? 1 : 0;
}

# The loaded edge becomes one job. The key is the printer and the minute the
# edge was seen, so a second watcher in the same minute writes nothing; the
# owner is the elected dispatcher, and the notice carries that owner so a
# Market window on another machine does not pull the paper.
sub scan_job_dispatch($ip, $name) {
	my $me = &scan_house_me();
	return { ok => 0 } unless length $me;
	return { ok => 0 } unless defined $ip && $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	my $now = &rightNow();
	my $minute = int($now / 60000);
	my $job = 'scan:' . $ip . ':' . $minute;
	(my $flat = $ip) =~ s/\.//g;
	my $scan_id = 'scan' . $flat . $minute;
	my $existing = eval { &db_select('scan_jobs', undef, { job => $job })->hashes->[0] };
	return { ok => 0, existing => 1 } if $existing && ((($existing->{'at'} || 0) + 0) > ($now - 10 * 60000));
	eval { &db_delete('scan_jobs', { job => $job }) };
	# A job that did not land is not a job: the caller must not announce a scan
	# whose row the other machines cannot see.
	my $wrote = eval {
		&db_insert('scan_jobs', {
			uuid => 'scan-job-' . &path_name($job),
			job => $job,
			owner => $me,
			printer => $ip,
			scan_id => $scan_id,
			at => $now,
			state => 'dispatched',
			server_time => $now,
		});
	};
	return { ok => 0 } unless $wrote;
	return { ok => 1, job => $job, scan_id => $scan_id, owner => $me };
}

sub scan_job_state($scan_id, $state) {
	$scan_id = '' unless defined $scan_id;
	$state = '' unless defined $state;
	return 0 unless length $scan_id && $state =~ /^(?:dispatched|running|ran|failed)$/;
	my $row = eval { &db_select('scan_jobs', undef, { scan_id => $scan_id })->hashes->[0] };
	return 0 unless $row;
	eval { &db_update('scan_jobs', { state => $state, server_time => &rightNow() }, { job => $row->{'job'} }) };
	return 1;
}

sub scan_job_finish($scan_id) {
	return &scan_job_state($scan_id, 'ran');
}

1;
