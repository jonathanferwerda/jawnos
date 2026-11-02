package subs;

# Records: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our %H;
our %M;
our %Y;
our $database;
our $gb;
our $log;
our %m;
our $universal_splitter;

# What to do with each mangled mailbox row: one row per event, preferring the
# sane copy already stored, then the first mangled row of a batch. Pure, so the
# scan can be tested and the caller owns the writes.
sub records_mailbox_date_decisions {
	my ($bad, $sane, $now) = @_;
	$now = &rightNow() unless $now;
	my (@out, %kept);
	foreach my $r ( @{$bad || []} ) {
		my $fix = &records_bad_date_fix($r, $now);
		next unless $fix;
		my $real = $fix->{'timestamp'};
		my $stored = 0;
		foreach my $s ( @{$sane || []} ) {
			next unless defined $s->{'timestamp'} && $s->{'timestamp'} =~ /^\d+$/;
			next unless abs((0 + $s->{'timestamp'}) - $real) <= 1000;
			next unless &records_mailbox_same_event($r, $s);
			$stored = 1;
			last;
		}
		if ($stored) {
			push @out, { %{$r}, table => 'mailbox', fix => $fix, suggested => 'tombstone', why => 'the message is already stored' };
			next;
		}
		my $event = join("\x1f", map { defined $r->{$_} ? $r->{$_} : '' } qw(phone manager_file status));
		if (grep { abs($_ - $real) <= 1000 } @{ $kept{$event} || [] }) {
			push @out, { %{$r}, table => 'mailbox', fix => $fix, suggested => 'tombstone', why => 'a re-write of the message kept from the same batch' };
			next;
		}
		push @{$kept{$event}}, $real;
		push @out, { %{$r}, table => 'mailbox', fix => $fix, suggested => 'repair', why => 'a millisecond date was read as a span of minutes' };
	}
	return \@out;
}

sub records_mailbox_bad_dates_scan {
	my ($now, $exempt) = @_;
	$now = &rightNow() unless $now;
	$exempt ||= &records_exempt();
	my $bad = &db_query('select rowid, uuid, app, phone, manager_file, status, body, timestamp, ost, server_time
		from mailbox
		where cast(timestamp as integer) < -1000000000000000
		order by rowid asc')->hashes;
	my @bad = grep {
		!defined($_->{'app'}) || !length($_->{'app'}) || !$exempt->{ $_->{'app'} }
	} @{$bad};
	return [] unless scalar @bad;
	# only the sane rows the batch could already be: same phone, within the span
	# its mangled stamps reconstruct to
	my ($lo, $hi) = (undef, undef);
	foreach my $r ( @bad ) {
		my $fix = &records_bad_date_fix($r, $now) or next;
		$lo = $fix->{'timestamp'} if !defined $lo || $fix->{'timestamp'} < $lo;
		$hi = $fix->{'timestamp'} if !defined $hi || $fix->{'timestamp'} > $hi;
	}
	return [] unless defined $lo;
	my %phones = map { defined $_->{'phone'} && length $_->{'phone'} ? ($_->{'phone'} => 1) : () } @bad;
	my @sane;
	foreach my $phone ( sort keys %phones ) {
		push @sane, @{ &db_query('select uuid, phone, manager_file, status, body, timestamp from mailbox
			where phone = ? and cast(timestamp as integer) >= -1000000000000000
			  and cast(timestamp as integer) between ? and ?
			order by rowid asc', $phone, $lo - 1000, $hi + 1000)->hashes };
	}
	my $out = &records_mailbox_date_decisions(\@bad, \@sane, $now);
	# the report is shown and synced: never carry a message body in it
	delete $_->{'body'} foreach @{$out};
	return $out;
}

sub records_mailbox_repair_date {
	my ($uuid, $fix) = @_;
	return unless $uuid && ref $fix eq 'HASH' && defined $fix->{'timestamp'};
	&db_update('mailbox', { timestamp => $fix->{'timestamp'}, server_time => &rightNow() }, { uuid => $uuid });
}

sub records_mailbox_tombstone {
	my ($row) = @_;
	my $uuid = ref $row eq 'HASH' ? $row->{'uuid'} : $row;
	return unless $uuid;
	my $app = ref $row eq 'HASH' ? ($row->{'app'} || $row->{'manager_file'} || '') : '';
	&tombstone_writer({ table => 'mailbox', app => $app, uuid => $uuid, scope => 'single' });
	&db_delete('mailbox', { uuid => $uuid });
}

# Run only the bad-date pass. A peer that holds the accurate copy can ask this
# machine to clear its own mangled dates over the signed records/repair rail;
# the pass touches only the unmistakable signature and is idempotent. The same
# bridge bug wrote the mailbox row beside the appointment, so both are cleared.
sub records_repair_bad_dates {
	my $now = &rightNow();
	my ($repaired, $tombstoned) = (0, 0);
	foreach my $r ( @{ &records_bad_dates_scan($now) } ) {
		my $fix = $r->{'fix'} or next;
		if (($r->{'suggested'} || '') eq 'tombstone') {
			&records_tombstone($r->{'app'}, $r->{'uuid'});
			$tombstoned++;
		}
		else {
			&records_repair_date($r->{'app'}, $r->{'uuid'}, $fix);
			$repaired++;
		}
	}
	my ($mail_repaired, $mail_tombstoned) = (0, 0);
	foreach my $r ( @{ &records_mailbox_bad_dates_scan($now) } ) {
		my $fix = $r->{'fix'} or next;
		if (($r->{'suggested'} || '') eq 'tombstone') {
			&records_mailbox_tombstone($r);
			$mail_tombstoned++;
		}
		else {
			&records_mailbox_repair_date($r->{'uuid'}, $fix);
			$mail_repaired++;
		}
	}
	return { repaired => $repaired, tombstoned => $tombstoned,
		mailbox_repaired => $mail_repaired, mailbox_tombstoned => $mail_tombstoned };
}

sub records_audit {
	my ($window_ms) = @_;
	# 0 means all time: the sweep predates the fix by weeks, so the default window is
	# only a convenience for a quick look
	$window_ms = 172800000 unless defined $window_ms && $window_ms =~ /^[0-9]+$/;
	my $now = &rightNow();
	my $since = $window_ms > 0 ? $now - $window_ms : 0;
	# apps the person has marked as legitimately long: never reported
	my $exempt = &records_exempt();
	my $report = {
		generated_at => $now, window_ms => $window_ms, since => $since,
		sweep => [], wrong_end => [], dupes => [], orphans => [], impossible => [], bad_dates => [], mailbox_bad_dates => [],
		apps_with_duration => {}, summary => {},
	};

	# the app's configured session length: the yardstick the audit measures against
	my %app_duration;
	foreach my $s ( @{ &db_query('select app, value from settings where setting = ?', 'duration')->hashes } ) {
		next unless defined $s->{'value'} && $s->{'value'} =~ /[0-9]/;
		my $d = abs &time_abbrev_translator($s->{'value'});
		$app_duration{ $s->{'app'} } = $d if $d;
	}
	$report->{'apps_with_duration'} = { %app_duration };

	# SWEEP - a stop press that closed more than one session
	my $groups = &db_query('select app, stop_timestamp, count(*) c from appointments where stop_timestamp is not null and stop_timestamp != ? and server_time > ? group by app, stop_timestamp having c > 1 order by stop_timestamp desc', '', $since)->hashes;
	foreach my $g ( @{$groups} ) {
		next if $exempt->{ $g->{'app'} };
		my $rows = &db_query('select rowid, uuid, type, timestamp, stop_timestamp, duration, server_time from appointments where app = ? and stop_timestamp = ? order by timestamp asc', $g->{'app'}, $g->{'stop_timestamp'})->hashes;
		# rows that share a start as well are the same event written twice, not a
		# sweep: the DUPES pass owns those, so a repair here can never fight it
		my %starts;
		$starts{ $_->{'timestamp'} }++ for @{$rows};
		next if scalar(keys %starts) < 2;
		my $d = $app_duration{ $g->{'app'} };
		# the session this press belongs to: nearest the app duration, else nearest the press
		my $keep = 0;
		for (my $i = 0; $i < scalar @{$rows}; $i++) {
			my $dur = abs(0 + ($rows->[$i]->{'duration'} || 0));
			my $score = defined $d ? abs($dur - $d) : abs(0 + $rows->[$i]->{'timestamp'} - 0 + $g->{'stop_timestamp'});
			my $best = defined $d ? abs(abs(0 + ($rows->[$keep]->{'duration'} || 0)) - $d) : abs(0 + $rows->[$keep]->{'timestamp'} - 0 + $g->{'stop_timestamp'});
			$keep = $i if $score < $best;
		}
		my @out;
		for (my $i = 0; $i < scalar @{$rows}; $i++) {
			my $r = $rows->[$i];
			my %o = ( rowid => $r->{'rowid'}, uuid => $r->{'uuid'}, type => $r->{'type'}, timestamp => $r->{'timestamp'}, stop_timestamp => $r->{'stop_timestamp'}, duration => $r->{'duration'} );
			if ($i == $keep) { $o{'suggested'} = 'keep'; $o{'why'} = defined $d ? 'ends nearest the app duration' : 'start nearest the press'; }
			elsif (defined $d) { $o{'suggested'} = 'repair'; $o{'why'} = 'a session of this app runs ' . $d . ' ms'; $o{'repair_stop_timestamp'} = (0 + $r->{'timestamp'}) + $d; }
			else { $o{'suggested'} = 'remove'; $o{'why'} = 'ended by a press that was not its own'; }
			push @out, \%o;
		}
		push @{$report->{'sweep'}}, { app => $g->{'app'}, stop_timestamp => $g->{'stop_timestamp'}, expected_ms => $d, rows => \@out };
	}

	# WRONG-END - an older session of an app left open while a NEWER session of the
	# same app had already begun, so the press that closed the older one was not its
	# own (the header the client stopped named the wrong session, and the older row
	# ran on to a later press). The overlap is the signature: the older span contains
	# the newer session's start, and the older one was still open at that tick. The
	# SWEEP pass owns the case where both closed together, so this is the one-per-press
	# shape it cannot see. Judged only against the app's own configured length - a real
	# appointment can be surprisingly long, so nothing is reported without a yardstick,
	# and a person still reviews every row (it is never bulk-applied).
	my $wrong = &db_query('select a.app, a.rowid, a.uuid, a.type, a.timestamp, a.stop_timestamp, a.duration
		from appointments a join appointments b on a.app = b.app
		where a.stop_timestamp is not null and a.server_time > ? and a.stop_timestamp <= ?
		  and b.timestamp > a.timestamp and b.timestamp < a.stop_timestamp
		  and (b.stop_timestamp is null or b.stop_timestamp > a.stop_timestamp)
		group by a.rowid order by a.stop_timestamp desc', $since, $now)->hashes;
	foreach my $r ( @{$wrong} ) {
		next if $exempt->{ $r->{'app'} };
		my $d = $app_duration{ $r->{'app'} };
		next unless $d;
		my $span = (0 + $r->{'stop_timestamp'}) - (0 + $r->{'timestamp'});
		next unless $span > 2 * $d;
		push @{$report->{'wrong_end'}}, {
			app => $r->{'app'}, rowid => $r->{'rowid'}, uuid => $r->{'uuid'}, type => $r->{'type'},
			timestamp => $r->{'timestamp'}, stop_timestamp => $r->{'stop_timestamp'}, duration => $r->{'duration'},
			expected_ms => $d, suggested => 'repair',
			why => 'ended by a press that belonged to a newer session of the app',
			repair_stop_timestamp => (0 + $r->{'timestamp'}) + $d,
		};
	}

	# DUPES - the same event written more than once. The source uuid is part of
	# the event's identity: one record fans out into child rows through model and
	# option characteristics, and two children can legitimately carry the same
	# app/type/time (fructis saved under both shampoo and conditioner) while
	# belonging to different parents. Grouping only by app/type/time called those
	# duplicates and would tombstone a real consumption; a repeated write copies
	# the source uuid too, so a true duplicate still groups.
	my $dupes = &db_query('select app, type, timestamp, stop_timestamp, coalesce(source_uuid, \'\') source_uuid, count(*) c, group_concat(rowid) rowids from appointments where server_time > ? group by app, type, timestamp, stop_timestamp, coalesce(source_uuid, \'\') having c > 1 order by timestamp desc', $since)->hashes;
	foreach my $g ( @{$dupes} ) {
		next if $exempt->{ $g->{'app'} };
		my @ids = sort { $a <=> $b } split /,/, ($g->{'rowids'} || '');
		my $kept = shift @ids;
		push @{$report->{'dupes'}}, { app => $g->{'app'}, type => $g->{'type'}, timestamp => $g->{'timestamp'}, stop_timestamp => $g->{'stop_timestamp'}, keep_rowid => $kept, remove_rowids => \@ids };
	}

	# ORPHANS - an open session, flagged only when it has run far past the app's duration
	my $orphans = &db_query('select rowid, uuid, app, type, timestamp, server_time from appointments where type in (?,?) and stop_seen is null and timestamp <= ? order by timestamp asc', 'start', 'record', $now - 7200000)->hashes;
	foreach my $r ( @{$orphans} ) {
		next if $exempt->{ $r->{'app'} };
		my $age = $now - (0 + $r->{'timestamp'});
		my $d = $app_duration{ $r->{'app'} };
		my %o = ( %{$r}, age_ms => $age );
		if (defined $d && $age > $d * 2) { $o{'suggested'} = 'repair'; $o{'why'} = 'open far longer than the app duration'; $o{'repair_stop_timestamp'} = (0 + $r->{'timestamp'}) + $d; }
		else { $o{'suggested'} = 'left-alone'; $o{'why'} = 'still running'; }
		push @{$report->{'orphans'}}, \%o;
	}

	# IMPOSSIBLE - a stop before its own start
	my $imp = &db_query('select rowid, uuid, app, type, timestamp, stop_timestamp, duration from appointments where stop_timestamp is not null and cast(stop_timestamp as integer) < cast(timestamp as integer) and server_time > ?', $since)->hashes;
	$report->{'impossible'} = [ grep { !$exempt->{ $_->{'app'} } } @{$imp} ];

	# BAD DATES - a millisecond date read as a span of minutes. The SMS and
	# call-log checks passed the bridge's epoch straight to ago_calc, which bills
	# a bare number as minutes; the record landed ~3.4 million years before now.
	# Unlike the other passes this looks at all time: the signature is
	# unmistakable and the bad rows are few.
	$report->{'bad_dates'} = &records_bad_dates_scan($now, $exempt);
	# The bridge wrote the mailbox row with the same stamp, so the same pass reads
	# it too; a sealed body is compared as an event, not byte for byte.
	$report->{'mailbox_bad_dates'} = &records_mailbox_bad_dates_scan($now, $exempt);

	my $extra = 0;
	foreach my $g ( @{$report->{'sweep'}} ) { $extra += scalar(grep { $_->{'suggested'} ne 'keep' } @{$g->{'rows'}}); }
	my $dupe_extra = 0;
	foreach my $g ( @{$report->{'dupes'}} ) { $dupe_extra += scalar @{$g->{'remove_rowids'}}; }
	$report->{'summary'} = {
		sweep_groups => scalar @{$report->{'sweep'}},
		sweep_spare_rows => $extra,
		wrong_end => scalar @{$report->{'wrong_end'}},
		dupe_groups => scalar @{$report->{'dupes'}},
		dupe_spare_rows => $dupe_extra,
		orphans => scalar @{$report->{'orphans'}},
		impossible => scalar @{$report->{'impossible'}},
		bad_dates => scalar @{$report->{'bad_dates'}},
		mailbox_bad_dates => scalar @{$report->{'mailbox_bad_dates'}},
	};
	return $report;
}

sub records_reconcile {
	my ($window_ms, $opts) = @_;
	$opts ||= {};
	my $apply = $opts->{'apply'} ? 1 : 0;
	my $report = &records_audit($window_ms);
	my $now = &rightNow();
	my @actions;

	# a helper: tombstone a row and drop it here, quietly. This is the bulk-admin
	# shape (as Alarm.pl writes appointments directly): Manager::delete_app also
	# pushes to every open window, which 800-odd rows must not do.
	my $remove = sub {
		my ($app, $uuid, $why) = @_;
		push @actions, { action => 'tombstone', app => $app, uuid => $uuid, why => $why };
		&records_tombstone($app, $uuid) if $apply;
	};

	# DUPLICATES - keep one of each, tombstone the rest
	foreach my $g ( @{ $report->{'dupes'} } ) {
		foreach my $rowid ( @{ $g->{'remove_rowids'} } ) {
			my $r = &db_query('select uuid, app from appointments where rowid = ?', $rowid)->hashes->[0];
			next unless $r && $r->{'uuid'};
			$remove->($r->{'app'}, $r->{'uuid'}, 'duplicate of row ' . $g->{'keep_rowid'});
		}
	}

	# SWEEP - the one press belongs to one row; the rest are repaired to the app's
	# own length or, when the app sets none, tombstoned
	foreach my $g ( @{ $report->{'sweep'} } ) {
		foreach my $r ( @{ $g->{'rows'} } ) {
			next if $r->{'suggested'} eq 'keep';
			if (($r->{'suggested'} // '') eq 'repair' && defined $r->{'repair_stop_timestamp'}) {
				my $stop = 0 + $r->{'repair_stop_timestamp'};
				my $dur = (0 + $r->{'timestamp'}) - $stop;
				push @actions, { action => 'repair', app => $g->{'app'}, uuid => $r->{'uuid'}, stop_timestamp => $stop, duration => $dur };
				&records_repair($g->{'app'}, $r->{'uuid'}, $r->{'timestamp'}, $stop) if $apply;
			}
			else {
				$remove->($g->{'app'}, $r->{'uuid'}, 'spare swept session');
			}
		}
	}

	# BAD DATES - put back the millisecond stamp the bridge reader mangled. A
	# fresh server_time is what makes the repair win the peer merge, so the phone
	# that wrote the row receives the corrected one instead of handing it back.
	foreach my $r ( @{ $report->{'bad_dates'} } ) {
		my $fix = $r->{'fix'} or next;
		if (($r->{'suggested'} // '') eq 'tombstone') {
			$remove->($r->{'app'}, $r->{'uuid'}, $r->{'why'} || 'a re-write of a stored record');
			next;
		}
		push @actions, { action => 'repair-date', app => $r->{'app'}, uuid => $r->{'uuid'}, timestamp => $fix->{'timestamp'}, stop_timestamp => $fix->{'stop_timestamp'}, why => $r->{'why'} };
		&records_repair_date($r->{'app'}, $r->{'uuid'}, $fix) if $apply;
	}

	# BAD DATES in the mailbox - the same reader wrote the message row. Keep the
	# sane copy when it is already stored; otherwise put the first mangled row
	# back and tombstone the re-writes.
	foreach my $r ( @{ $report->{'mailbox_bad_dates'} || [] } ) {
		my $fix = $r->{'fix'} or next;
		my $app = $r->{'app'} || $r->{'manager_file'};
		if (($r->{'suggested'} // '') eq 'tombstone') {
			push @actions, { action => 'tombstone', table => 'mailbox', app => $app, uuid => $r->{'uuid'}, why => $r->{'why'} || 'a re-write of a stored message' };
			&records_mailbox_tombstone($r) if $apply;
			next;
		}
		push @actions, { action => 'repair-date', table => 'mailbox', app => $app, uuid => $r->{'uuid'}, timestamp => $fix->{'timestamp'}, why => $r->{'why'} };
		&records_mailbox_repair_date($r->{'uuid'}, $fix) if $apply;
	}

	return { applied => $apply, actions => scalar @actions, summary => $report->{'summary'}, list => \@actions };
}

# ---- the records watch: staging and apply --------------------------------
# The mirror of the error watch. A finding the fixed audit produces is staged as
# a row; a person reviews it and Applies, and the actions it carries are written
# through the same quiet paths the bulk pass uses. Machine-local (staged_records),
# so each machine repairs its own rows and the tombstones converge the mesh.

# drop one appointment row and tell the mesh (a tombstone, so no peer re-adds it).
# Quiet on purpose: Manager::delete_app also pushes to every open window, which a
# batch of hundreds must not do.
sub records_tombstone {
	my ($app, $uuid) = @_;
	return unless $app && $uuid;
	&tombstone_writer({ table => 'appointments', app => $app, uuid => $uuid, scope => 'single' });
	&db_delete('continent', { app => $app, uuid => $uuid });
	&db_query('delete from continent where app = ? and uuid like ?', $app, $uuid . '%');
	&db_delete('appointments', { uuid => $uuid, app => $app });
}

# set a session's real end (its own start + the app's length). A fresh server_time
# is what makes the repair win the peer merge.
sub records_repair {
	my ($app, $uuid, $start, $stop) = @_;
	return unless $app && $uuid && defined $stop;
	my $dur = (0 + $start) - (0 + $stop);
	&db_update('appointments', { stop_timestamp => $stop, duration => $dur, stop_seen => 'yes', type => 'stop', seen => 'yes', server_time => &rightNow() }, { uuid => $uuid, app => $app });
	return $dur;
}

# Restore a mangled millisecond stamp in place, leaving the row's other fields
# alone. The row is a finished event (an SMS or a call), not an open session.
sub records_repair_date {
	my ($app, $uuid, $fix) = @_;
	return unless $app && $uuid && ref $fix eq 'HASH' && defined $fix->{'timestamp'};
	my $data = { timestamp => $fix->{'timestamp'}, server_time => &rightNow(), seen => 'yes' };
	if (defined $fix->{'stop_timestamp'}) {
		$data->{'stop_timestamp'} = $fix->{'stop_timestamp'};
		$data->{'stop_seen'} = 'yes';
	}
	&db_update('appointments', $data, { uuid => $uuid, app => $app });
}

# the table, created here too so the watch works from the first boot after an update
sub records_table_ready {
	my $table = &db_query('select name from pragma_table_info(?) where name = ?', 'staged_records', 'uuid')->hashes->[0];
	return 1 if $table;
	&db_query('create table if not exists staged_records (
		uuid VARCHAR(255) unique, server_time VARCHAR(255), ost VARCHAR(25), kind VARCHAR(25),
		app VARCHAR(500), signature VARCHAR(500), sample LONGTEXT, proposed LONGTEXT,
		status VARCHAR(25), model VARCHAR(255), note LONGTEXT, last_seen VARCHAR(255))');
	&db_query('create index if not exists idx1_staged_records on staged_records (signature)');
	&db_query('create index if not exists idx2_staged_records on staged_records (status)');
	return 1;
}

# stage one finding: an existing signature just bumps last_seen; a new one is inserted
sub records_stage {
	my ($f) = @_;
	return unless $f && $f->{'signature'};
	my $existing = &db_select('staged_records', ['uuid'], { signature => $f->{'signature'} })->hashes->[0];
	if ($existing) {
		&db_update('staged_records', { last_seen => &rightNow() }, { uuid => $existing->{'uuid'} });
		return $existing->{'uuid'};
	}
	my $uuid = &random_string_creator(40);
	&db_insert('staged_records', {
		uuid => $uuid,
		kind => $f->{'kind'},
		app => $f->{'app'},
		signature => $f->{'signature'},
		sample => $f->{'sample'},
		proposed => encode_json($f->{'proposed'}),
		status => 'proposed',
		last_seen => &rightNow(),
	});
	return $uuid;
}

# turn an audit report into staged findings
sub records_stage_scan {
	my ($window_ms) = @_;
	&records_table_ready();
	my $report = &records_audit($window_ms);
	my $staged = 0;
	foreach my $g ( @{$report->{'sweep'}} ) {
		my @acts;
		foreach my $r ( @{$g->{'rows'}} ) {
			next if $r->{'suggested'} eq 'keep';
			if (($r->{'suggested'} // '') eq 'repair' && defined $r->{'repair_stop_timestamp'}) {
				push @acts, { action => 'repair', uuid => $r->{'uuid'}, timestamp => $r->{'timestamp'}, stop_timestamp => $r->{'repair_stop_timestamp'}, why => $r->{'why'} };
			}
			else {
				push @acts, { action => 'tombstone', uuid => $r->{'uuid'}, why => $r->{'why'} };
			}
		}
		next unless scalar @acts;
		my @ctx = map { { uuid => $_->{'uuid'}, type => $_->{'type'}, timestamp => $_->{'timestamp'}, stop_timestamp => $_->{'stop_timestamp'}, duration => $_->{'duration'}, suggested => $_->{'suggested'} } } @{$g->{'rows'}};
		&records_stage({
			kind => 'sweep', app => $g->{'app'},
			signature => 'sweep:' . $g->{'app'} . ':' . $g->{'stop_timestamp'},
			sample => 'one press closed ' . scalar(@{$g->{'rows'}}) . ' sessions' . (defined $g->{'expected_ms'} ? ' (this app runs ' . $g->{'expected_ms'} . ' ms)' : ''),
			proposed => { app => $g->{'app'}, actions => \@acts, stop_timestamp => $g->{'stop_timestamp'}, expected_ms => $g->{'expected_ms'}, context => \@ctx },
		}); $staged++;
	}
	foreach my $g ( @{$report->{'dupes'}} ) {
		my @acts;
		foreach my $rowid ( @{$g->{'remove_rowids'}} ) {
			my $r = &db_query('select uuid from appointments where rowid = ?', $rowid)->hashes->[0];
			next unless $r && $r->{'uuid'};
			push @acts, { action => 'tombstone', uuid => $r->{'uuid'}, why => 'duplicate of row ' . $g->{'keep_rowid'} };
		}
		next unless scalar @acts;
		&records_stage({
			kind => 'dupe', app => $g->{'app'},
			signature => 'dupe:' . $g->{'app'} . ':' . $g->{'type'} . ':' . $g->{'timestamp'},
			sample => scalar(@acts) . ' duplicate row(s) of ' . $g->{'app'} . ' ' . $g->{'type'},
			proposed => { app => $g->{'app'}, actions => \@acts },
		}); $staged++;
	}
	foreach my $r ( @{$report->{'orphans'}} ) {
		next unless ($r->{'suggested'} // '') eq 'repair';
		&records_stage({
			kind => 'orphan', app => $r->{'app'},
			signature => 'orphan:' . $r->{'app'} . ':' . $r->{'timestamp'},
			sample => 'open ' . int($r->{'age_ms'} / 3600000) . 'h, far past the app length',
			proposed => { app => $r->{'app'}, actions => [ { action => 'repair', uuid => $r->{'uuid'}, timestamp => $r->{'timestamp'}, stop_timestamp => $r->{'repair_stop_timestamp'}, why => $r->{'why'} } ], context => [ { uuid => $r->{'uuid'}, type => $r->{'type'}, timestamp => $r->{'timestamp'}, duration => undef, age_ms => $r->{'age_ms'} } ] },
		}); $staged++;
	}
	foreach my $r ( @{$report->{'wrong_end'}} ) {
		&records_stage({
			kind => 'wrong_end', app => $r->{'app'},
			signature => 'wrong_end:' . $r->{'app'} . ':' . $r->{'timestamp'},
			sample => 'ended by a press meant for a newer session; ran ' . int(((0 + $r->{'stop_timestamp'}) - (0 + $r->{'timestamp'})) / 60000) . 'm, this app runs ' . int((0 + ($r->{'expected_ms'} || 0)) / 60000) . 'm',
			proposed => { app => $r->{'app'}, actions => [ { action => 'repair', uuid => $r->{'uuid'}, timestamp => $r->{'timestamp'}, stop_timestamp => $r->{'repair_stop_timestamp'}, why => $r->{'why'} } ], context => [ { uuid => $r->{'uuid'}, type => $r->{'type'}, timestamp => $r->{'timestamp'}, stop_timestamp => $r->{'stop_timestamp'}, duration => $r->{'duration'}, suggested => 'repair' } ] },
		}); $staged++;
	}
	return { staged => $staged, summary => $report->{'summary'} };
}

# Apply one staged row: carry out every action it holds, then mark it applied
sub records_fix_apply {
	my ($uuid) = @_;
	my $row = &db_select('staged_records', undef, { uuid => $uuid })->hash;
	return { error => 'no such finding' } unless $row;
	my $p = eval { decode_json $row->{'proposed'} } || {};
	my $app = $p->{'app'} || $row->{'app'};
	my @acts = @{ $p->{'actions'} || [] };
	return { error => 'that finding proposes nothing' } unless scalar @acts;
	my $done = 0;
	foreach my $a ( @acts ) {
		if (($a->{'action'} // '') eq 'tombstone' && $a->{'uuid'}) { &records_tombstone($app, $a->{'uuid'}); $done++; }
		elsif (($a->{'action'} // '') eq 'repair' && $a->{'uuid'} && defined $a->{'stop_timestamp'}) { &records_repair($app, $a->{'uuid'}, $a->{'timestamp'}, $a->{'stop_timestamp'}); $done++; }
	}
	&db_update('staged_records', { status => 'applied', note => 'applied ' . &rightNow() . ' (' . $done . ' row(s))' }, { uuid => $uuid });
	return { applied => $uuid, rows => $done };
}

# Put one staged finding to the Coding agent. The audit finds; the agent reads;
# the person decides. A real appointment can be surprisingly long (a home stay, an
# eight-month ailment) and a fixed rule can never know that, so the person can talk
# a finding through before pressing Apply - and the agent is free to answer "leave
# it alone". Nothing here writes.
sub records_ask {
	my ($uuid, $question, $history) = @_;
	my $row = &db_select('staged_records', undef, { uuid => $uuid })->hash;
	return 'I could not find that finding.' unless $row;
	my $model = &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant' })
		|| &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
	return 'Set a Coding model in Configure and I can read this finding with you.' unless $model;
	my $p = eval { decode_json($row->{'proposed'} // '') } || {};
	my $fmt = sub {
		my ($ms) = @_;
		return '(none)' unless defined $ms && $ms =~ /^[0-9-]+$/;
		my $t = localtime(($ms + 0) / 1000);
		return ref $t ? $t->strftime('%Y-%m-%d %H:%M') : $ms;
	};
	my @lines = (
		'Staged finding (' . ($row->{'kind'} // '?') . ') for the app "' . ($row->{'app'} // '?') . '"',
		'What the audit saw: ' . ($row->{'sample'} // ''),
	);
	if (defined $p->{'expected_ms'} && $p->{'expected_ms'} =~ /^[0-9.]+$/) {
		push @lines, 'This app\'s configured session length: ' . sprintf('%.1f', $p->{'expected_ms'} / 60000) . ' min';
	} else {
		push @lines, 'This app sets no session length of its own.';
	}
	my $context = $p->{'context'} || [];
	if (scalar @{$context}) {
		push @lines, 'The rows in question:';
		foreach my $c ( @{$context} ) {
			push @lines, '  - ' . substr($c->{'uuid'} // '?', 0, 8) . ' ' . ($c->{'type'} // '?')
				. ', start ' . $fmt->($c->{'timestamp'})
				. ', stop ' . $fmt->($c->{'stop_timestamp'})
				. (defined $c->{'duration'} && $c->{'duration'} =~ /^[0-9.-]+$/ ? ', ran ' . sprintf('%.1f', abs($c->{'duration'}) / 60000) . ' min' : '')
				. ' (audit: ' . ($c->{'suggested'} // '?') . ')';
		}
	}
	push @lines, 'The actions the audit proposes: ' . encode_json($p->{'actions'} || []);
	my $system = &records_audit_prompt()
		. "\n\n"
		. 'You are now looking at ONE staged finding and talking it through with the person who keeps the records. Answer as a careful colleague: what most likely happened, whether the proposed action is safe, and what you would do. Say plainly when the honest answer is "leave it alone - that one was real", and when long is normal for this app. Do not write anything; the person presses Apply.';
	my $user = join("\n", @lines);
	$user .= "\n\n" . $history if defined $history && length $history;
	$user .= "\nPERSON: " . (defined $question && length $question ? $question : 'What do you make of this?');
	my ($text, $err) = &subs::evaluation_model_call_with_fallback($model, &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant_fallback' }), $system, $user, &subs::ai_role_thinking('coding_assistant'));
	return $err && !$text ? ('I could not reach the model: ' . $err) : ($text || 'The model returned nothing readable.');
}

# ---- the records recovery: putting back what a repair shortened --------------
# A repair overwrites an end in place, so a genuinely long appointment that a
# sweep swept up can vanish from the live table with nothing left to compare to.
# The machine keeps hourly sealed snapshots, and the one taken before the repair
# still holds the old ends. These routines compare a snapshot to now and list the
# rows the repair shortened (or dropped), so a person - or the Coding agent - can
# put them back. Nothing is written by the scan; apply stamps a current
# server_time, so the recovered rows win the peer merge and reach every machine.

# the newest sealed snapshot, by the timestamp in its name
sub records_latest_backup {
	my $dir = &database_dir() . '/backups';
	my @files = grep { /jawnos_\d+\.enc$/ } glob("$dir/jawnos_*.enc");
	return undef unless scalar @files;
	@files = sort {
		my ($b1) = $b =~ /jawnos_(\d+)\.enc$/;
		my ($a1) = $a =~ /jawnos_(\d+)\.enc$/;
		($b1 || 0) <=> ($a1 || 0);
	} @files;
	return $files[0];
}

# take one now, with the app's own idiom (sqlite .backup, then openssl, then the
# splitter-and-standard appendage). Kept outside backups/ only as the plaintext,
# which is shredded; the sealed file is named jawnos_<ms>.enc so the tidy keeps it.
sub records_backup_now {
	require File::Temp;
	require File::Spec;
	my $dir = &database_dir() . '/backups';
	mkdir $dir unless -d $dir;
	my ($fh, $tmp) = File::Temp::tempfile('jawnos_recover_XXXXXX', SUFFIX => '.db', DIR => File::Spec->tmpdir, UNLINK => 0);
	return undef unless $fh && $tmp;
	close $fh;
	my $database = &database_path();
	my $secret = &suds_grabber();
	my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
	my $out = "$dir/jawnos_" . &rightNow() . '.enc';
	`sqlite3 "$database" ".backup '$tmp'"`;
	&openssl_file_crypt('e', $standard, $secret, $tmp, $out, 0, 1);
	chmod 0600, $out if -e $out;
	my $appendage = $gb::universal_splitter . &encrypter($secret, $standard);
	if (open(my $af, '>>', $out)) { print $af $appendage . "\n"; close $af; }
	unlink $tmp;
	return undef unless -e $out && -s $out > 5000;
	return $out;
}

# the newest snapshot is younger than the window, or one is taken to make it so.
# The guard the person asked for: nothing is applied without a recent backup.
sub records_backup_ensure_fresh {
	my ($max_age_ms) = @_;
	$max_age_ms = 600000 unless defined $max_age_ms && $max_age_ms =~ /^[0-9]+$/;
	my $now = &rightNow();
	my $newest = &records_latest_backup();
	if ($newest) {
		my ($ms) = $newest =~ /jawnos_(\d+)\.enc$/;
		return { fresh => 1, path => $newest, age_ms => $now - $ms, made => 0 } if $ms && ($now - $ms) < $max_age_ms;
	}
	my $made = &records_backup_now();
	return { fresh => ($made ? 1 : 0), path => ($made || $newest), age_ms => 0, made => ($made ? 1 : 0) };
}

# unseal a snapshot to a scratch database outside backups/ (the tidy shreds
# anything there that is not jawnos*.enc). Returns the path, or undef.
sub records_backup_decrypt {
	my ($path) = @_;
	return undef unless $path && -e $path;
	require File::Temp;
	require File::Spec;
	my $tail = `tail -c 600 "$path"`;
	my @parts = split /\Q$gb::universal_splitter\E/, ($tail // '');
	return undef unless scalar @parts > 1;
	my $appendage = $parts[-1];
	$appendage =~ s/\s+\z//;
	my $secret = &suds_grabber();
	my $standard = &decrypter($secret, $appendage);
	$standard = 'aes-256-ctr' unless $standard && $standard =~ /^[a-z0-9-]+$/i;
	my ($fh, $tmp) = File::Temp::tempfile('jawnos_old_XXXXXX', SUFFIX => '.db', DIR => File::Spec->tmpdir, UNLINK => 0);
	return undef unless $fh && $tmp;
	close $fh;
	&openssl_file_crypt('d', $standard, $secret, $path, $tmp, 1, 1);
	return undef unless -e $tmp && -s $tmp > 5000;
	return $tmp;
}

# how long a row ran: its own stop when it has one, else as far as the reference
# time (the snapshot's moment for an old row, now for a live one)
sub records_span_ms {
	my ($row, $ref) = @_;
	my $start = 0 + ($row->{'timestamp'} || 0);
	return undef unless $start;
	my $stop = $row->{'stop_timestamp'};
	my $end = (defined $stop && $stop =~ /^[0-9]+$/ && $stop) ? (0 + $stop) : (0 + $ref);
	return abs($end - $start);
}

1;
