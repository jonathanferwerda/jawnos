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
			'create table if not exists scan_jobs (uuid VARCHAR(255), job VARCHAR(255) unique, owner VARCHAR(255), printer VARCHAR(255), scan_id VARCHAR(64), at VARCHAR(25), state VARCHAR(25), target VARCHAR(25), ost VARCHAR(255), server_time VARCHAR(255))',
			'create unique index if not exists idx_scan_house_machine on scan_house (machine)',
			'create unique index if not exists idx_scan_jobs_job on scan_jobs (job)',
		) {
			eval { &db_query($sql) };
		}
		# A table created before the rule named a destination has no column for
		# it; the add is a no-op on a table that already has one.
		eval { &db_query('alter table scan_jobs add column target VARCHAR(25)') };
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
	my $ip = '';
	my $ready = 0;
	my ($live_ip, $caps) = &scanner_live_capabilities();
	if ($live_ip) {
		$ip = $live_ip;
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
		my ($ip, $caps) = &scanner_live_capabilities();
		if ($ip && ($caps->{'adf'} || $caps->{'platen'})) {
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
	return @out;
}

# A computer in the House takes the paper, and a phone is the scanner of last
# resort: a computer has the vision model and the app's own tools, and the pages
# stay where the receipt reader can read them. A computer counts when its
# heartbeat is fresh, or when this machine can still reach it - a phone off the
# LAN reaches a computer over the VPN, and a phone that has been asleep carries
# an old heartbeat for a computer that is wide awake. The reachable answer is
# held for two minutes so a watcher pass does not ask the same peer again and
# again. Answers the computer's row, or undef when there is no computer at hand.
sub scan_computer_available {
	my $me = &scan_house_me();
	my $now = &rightNow();
	my $rows = eval { &db_select('scan_house')->hashes } || [];
	my @peers = grep {
		($_->{'machine'} || '') ne $me
			&& (($_->{'device'} || '') =~ /^(?:computer|server)$/)
			&& ($_->{'scan_ready'} || 0)
	} @{$rows || []};
	return undef unless @peers;
	my ($fresh) = grep { (($_->{'seen'} || 0) + 0) > $now - 5 * 60000 } @peers;
	return $fresh if $fresh;
	my $key = join ',', sort map { $_->{'machine'} } @peers;
	my $memo = eval { &cache_get({ app => 'scan', context => 'computer_available' }) } || {};
	if (ref $memo eq 'HASH' && ($memo->{'key'} || '') eq $key && (($memo->{'at'} || 0) + 0) > $now - 2 * 60000) {
		my ($row) = grep { ($_->{'machine'} || '') eq ($memo->{'machine'} || '') } @peers;
		return $row;
	}
	my $up;
	foreach my $row ( @peers ) {
		my $rm = eval { &db_select('remote_machines', undef, { signatorial => $row->{'machine'} })->hashes->[0] };
		next unless ref $rm eq 'HASH';
		my ($ua, $p) = &peer_useragent($rm);
		next unless $ua && ref $p eq 'HASH' && ($p->{'manager'} || '') ne '';
		# The health route is the House's own "are you there": it is gated to the
		# signed peer rail, so an answer also proves this machine may talk to it.
		my $res = eval {
			$ua->connect_timeout(2)->inactivity_timeout(3)
				->get($p->{'manager'} . '/manager/health?signatorial=' . $me)->result;
		};
		if ($res && $res->is_success) { $up = $row; last; }
	}
	&cache_set({ app => 'scan', context => 'computer_available', warranty => '-2m' },
		{ key => $key, at => $now, machine => ($up ? ($up->{'machine'} || '') : '') });
	return $up;
}

# One dispatcher: a computer (or a server, which is a computer on the LAN)
# before a phone or tablet, and the Table before another computer. The ranking
# is deterministic, so every machine elects the same one from the same rows.
# A phone never names itself while a computer can take the paper, even one it
# only knows from an old heartbeat: it asks that computer first.
sub scan_dispatcher {
	if ((&device_setter() || '') eq 'mobile') {
		my $computer = &scan_computer_available();
		return $computer->{'machine'} if ref $computer eq 'HASH' && ($computer->{'machine'} || '') ne '';
	}
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
	# the phone's fallback is no computer in the House and no VPN to one
	if ((&device_setter() || '') eq 'mobile' && &scan_computer_available()) { return 0; }
	return (&scan_dispatcher() eq $me) ? 1 : 0;
}

# The loaded edge becomes one job. The key is the printer and the minute the
# edge was seen, so a second watcher in the same minute writes nothing. The
# minute is not enough on its own: a machine whose ledger is a little stale
# elects itself too, and the two passes can land a minute apart. So any job for
# this printer still fresh - whoever owns it - is the same paper, and answers
# "already dispatched" instead of a second scan. The owner is the elected
# dispatcher, the destination is the scanner's own rule, and the notice carries
# both so a Market or Scan window on another machine does not take the paper.
sub scan_job_dispatch($ip, $name, $target = 'market') {
	my $me = &scan_house_me();
	return { ok => 0 } unless length $me;
	return { ok => 0 } unless defined $ip && $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	$target = ($target || '') eq 'scan' ? 'scan' : 'market';
	my $now = &rightNow();
	my $minute = int($now / 60000);
	my $job = 'scan:' . $ip . ':' . $minute;
	(my $flat = $ip) =~ s/\.//g;
	my $scan_id = 'scan' . $flat . $minute;
	my $existing = eval { &db_select('scan_jobs', undef, { job => $job })->hashes->[0] };
	return { ok => 0, existing => 1 } if $existing && ((($existing->{'at'} || 0) + 0) > ($now - 10 * 60000));
	# one paper, one scan: a job another machine wrote for the same printer a
	# moment ago is this same loaded edge. A failed one did not take the paper,
	# so it does not hold the edge against a retry.
	my $recent = eval { &db_select('scan_jobs', undef, { printer => $ip })->hashes } || [];
	foreach my $row ( @{$recent} ) {
		next unless (($row->{'at'} || 0) + 0) > ($now - 3 * 60000);
		next if (($row->{'state'} || '') eq 'failed');
		return { ok => 0, existing => 1, scan_id => $row->{'scan_id'}, target => $row->{'target'} };
	}
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
			target => $target,
			server_time => $now,
		});
	};
	return { ok => 0 } unless $wrote;
	return { ok => 1, job => $job, scan_id => $scan_id, owner => $me, target => $target };
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

# What a scan looks like from the text read off it. The printer cannot say what
# is on the paper, so the Scan app reads the OCR and offers a label; the person
# can still file it anywhere. A receipt is the one kind the house already files
# by itself (Market reads those from the feeder), so a kind is a suggestion, not
# a destination - nothing moves because of it.
sub scan_doc_kind {
	my ($text) = @_;
	$text = '' unless defined $text;
	my $t = lc $text;
	return 'blank' unless $t =~ /\S/;
	my $money = () = $t =~ /(?:\$|€|£|¥)\s?\d|\b\d+[.,]\d{2}\b/g;
	return 'invoice' if $t =~ /\b(?:invoice|due date|bill to|purchase order|order number)\b/;
	return 'receipt' if $money >= 2 && $t =~ /\b(?:total|subtotal|amount|balance|tax|change|tendered|card|cash)\b/;
	return 'letter'  if $t =~ /\b(?:dear|sincerely|regards|yours truly|to whom it may concern)\b/;
	return 'form'    if $t =~ /\b(?:please print|signature|date of birth)\b/;
	return 'document';
}

# ---- what the automatic scan service does ----------------------------------
# The ADF watcher and the Scan app share one rule per scanner, kept house-wide in
# the settings table (device 'all') so every machine reads the same choice. A
# rule names whether the service watches at all, and where a loaded edge goes:
# to Market (its receipt reader) or to the Scan app's holding pool.
sub scan_scanner_key {
	my ($scanner) = @_;
	my $name = ref $scanner eq 'HASH' ? ($scanner->{'name'} || $scanner->{'address'} || '') : '';
	$name = 'scanner' unless defined $name && length $name;
	return &path_name($name);
}

sub scan_scanner_rules {
	my $raw = &setting_grabber({ app => 'scan', setting => 'auto_scan', device => &warranty_device() });
	# A peer's copy (or an older write) may carry this device's own row where the
	# house row belongs; read it the way cards_list reads its list.
	if (!defined $raw || !length $raw) {
		$raw = &setting_grabber({ app => 'scan', setting => 'auto_scan' });
	}
	my $rules = eval { return decode_json($raw || '') } || {};
	return ref $rules eq 'HASH' ? $rules : {};
}

# One scanner's rule, with the service on and Market as the destination when the
# house has not chosen otherwise.
sub scan_scanner_rule {
	my ($key) = @_;
	my $rule = { auto => 1, target => 'market', name => '' };
	return $rule unless defined $key && length $key;
	my $saved = &scan_scanner_rules()->{$key};
	return $rule unless ref $saved eq 'HASH';
	$rule->{'auto'} = $saved->{'auto'} ? 1 : 0 if defined $saved->{'auto'};
	$rule->{'target'} = 'scan' if ($saved->{'target'} || '') eq 'scan';
	$rule->{'name'} = $saved->{'name'} || '';
	return $rule;
}

sub scan_scanner_rule_save {
	my ($key, $name, $auto, $target) = @_;
	return 0 unless defined $key && length $key && length $key <= 200;
	my $rules = &scan_scanner_rules();
	$rules->{$key} = {
		auto => ($auto ? 1 : 0),
		target => (($target || '') eq 'scan' ? 'scan' : 'market'),
		name => (defined $name ? $name : ''),
	};
	&setting_setter({
		app => 'scan', setting => 'auto_scan', device => &warranty_device(),
		value => encode_json($rules),
	});
	return 1;
}

sub scan_auto_enabled {
	my ($key) = @_;
	return &scan_scanner_rule($key)->{'auto'} ? 1 : 0;
}

sub scan_auto_target {
	my ($key) = @_;
	return &scan_scanner_rule($key)->{'target'};
}

# The printer address another machine in the house already found. The readiness
# ledger is house-wide, so a phone on the same network (whose ARP table is not
# readable) can use the address that answered for a computer instead of the
# saved one from a network it left. The row may be a little old on a peer still
# pulling it; the caller's same-network test is what keeps an offsite address
# out, so half an hour is still a useful sighting.
sub scan_house_printer_ip {
	my $now = &rightNow();
	my $rows = eval { &db_select('scan_house')->hashes } || [];
	my @ready = grep {
		$_->{'scan_ready'}
			&& (($_->{'seen'} || 0) + 0) > $now - 30 * 60 * 1000
			&& ($_->{'printer'} || '') =~ /^\d{1,3}(?:\.\d{1,3}){3}$/
	} @{$rows || []};
	my ($row) = sort { ($b->{'seen'} || 0) <=> ($a->{'seen'} || 0) } @ready;
	return $row ? $row->{'printer'} : '';
}

1;
