#!/usr/bin/env perl
# appointments_time_repair.pl - put back the appointment write times a bad
# backfill stamped.
#
#   perl scripts/appointments_time_repair.pl [--backup <path>] [--window-start <ms>]
#                                            [--apply] [--json] [--limit N]
#                                            [--sql] [--include-changed]
#
# The settings backfill that matched every row (an always-null `id` in the
# predicate) also re-stamped appointments: on 2026-11-21 it wrote two
# server_time values over 41k rows, collapsing about a month of history into one
# weekly sync band. The v3 sync localises by server_time bands, so every change
# in that band reads all 42k rows again. This compares an older sealed snapshot
# with the live table and restores ONLY server_time, for rows whose every other
# column still matches the snapshot. A row written since the snapshot is left
# alone: its current time is the honest one, and giving it the old time would
# make it look older.
#
# Run this on every machine in the house. A row repaired on one machine is
# overwritten by a peer that still carries the incident stamp (the merge keeps
# the newer server_time), so one machine alone cannot hold the repair.
#
# --include-changed is for an incident whose changed rows are themselves the
# reservoir: the pure rows are repaired, then a peer's changed row (still at the
# incident stamp) re-stamps them. It restores the snapshot time for those rows
# too; the changed data stays, only its write time goes back. Repair every
# machine in the same window before the sync settles.
#
# Dry run by default. --apply needs an explicit older --backup, takes a fresh
# safety snapshot, re-reads the live rows, and writes in one transaction. The
# snapshot's own time (its filename, else its mtime) must predate the window.
# The window starts at the beginning of the largest cluster of recent writes (a
# gap of more than an hour starts a new cluster) unless the person names
# --window-start.
use strict;
use warnings;
use FindBin;
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
require Mojo::JSON;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $SAMPLE_LIMIT = 20;

# Columns that are not part of the row's meaning for a re-stamp test: the sync
# time itself, the local delivery markers, and per-machine copy bookkeeping.
# Everything else must match the snapshot, or the row was genuinely written
# after it.
my %IGNORED_COLUMNS = map { $_ => 1 } qw(
	uuid server_time seen stop_seen ost warranty browser_tab_id position pos toggle
);

# The body is a function, not the file's top level, so a test can call it with
# the domain subs stubbed: this tool writes appointment times back, and the
# refusals it must never skip (no explicit older snapshot, no fresh safety
# snapshot) are worth pinning without touching a live database.
sub main {
	my (@argv) = @_;
	my ($opt_backup, $explicit_backup, $opt_window, $apply, $json, $limit, $sql, $dump_sql, $include_changed);
	$limit = $SAMPLE_LIMIT;
	for (my $i = 0; $i < @argv; $i++) {
		my $a = $argv[$i];
		if ($a eq '--backup' && defined $argv[$i + 1]) {
			$opt_backup = $argv[$i + 1];
			$explicit_backup = 1;
		}
		elsif ($a eq '--window-start' && defined $argv[$i + 1]) { $opt_window = $argv[$i + 1]; }
		elsif ($a eq '--apply') { $apply = 1; }
		elsif ($a eq '--sql') { $sql = 1; }
		elsif ($a eq '--dump-sql') { $dump_sql = 1; }
		elsif ($a eq '--include-changed') { $include_changed = 1; }
		elsif ($a eq '--json') { $json = 1; }
		elsif ($a eq '--limit' && defined $argv[$i + 1] && $argv[$i + 1] =~ /^\d+$/) { $limit = $argv[$i + 1]; }
	}

	# An apply without a named older snapshot could re-stamp rows with the
	# incident's own time; refuse before reading the database at all.
	if ($apply && !$explicit_backup) {
		print "appointments time repair: --apply requires an explicit --backup <path> older than the incident window; refusing to write.\n";
		return 1;
	}
	if (defined $opt_window) {
		unless ($opt_window =~ /^\d+$/) {
			print "appointments time repair: --window-start must be milliseconds since the epoch\n";
			return 1;
		}
		$opt_window = 0 + $opt_window;
	}

	my $live;
	if ($sql) {
		unless (defined $opt_window) {
			print "appointments time repair: --sql needs --window-start <ms> (the SQL path does not name a burst for you)\n";
			return 1;
		}
	}
	else {
		$live = _live_rows();
		unless ($live) {
			print "appointments time repair: could not read the live appointments\n";
			return 1;
		}
	}

	my $window = defined $opt_window ? $opt_window : _burst_window_start($live);
	unless (defined $window) {
		print "appointments time repair: could not find a dense recent burst (or the live appointments have no numeric server_time); pass --window-start <ms>\n";
		return 1;
	}

	my $backup;
	if ($explicit_backup) {
		$backup = $opt_backup;
		unless (defined $backup && -e $backup) {
			print "appointments time repair: --backup does not exist: " . (defined $backup ? $backup : '') . "\n";
			return 1;
		}
	}
	else {
		$backup = _newest_backup_before($window);
		unless ($backup) {
			print "appointments time repair: no snapshot in " . &subs::backups_dir()
				. " is older than the window start (" . $window . "); pass --backup <path>\n";
			return 1;
		}
	}

	my $snap_ms = _snapshot_time($backup);
	unless (defined $snap_ms) {
		print "appointments time repair: cannot tell when $backup was taken; name a snapshot jawnos_<ms>.enc\n";
		return 1;
	}
	if ($snap_ms >= $window) {
		print "appointments time repair: refusing - the snapshot $backup was taken at "
			. &subs::iso_local($snap_ms) . ", not before the window start "
			. &subs::iso_local($window) . " (" . $window . "); name an older --backup\n";
		return 1;
	}

	my $old_db = &subs::records_backup_decrypt($backup);
	unless ($old_db) {
		print "appointments time repair: could not unseal $backup (key or format)\n";
		return 1;
	}
	if ($sql) {
		my $rc = _sql_repair($old_db, $backup, $snap_ms, $window, { apply => $apply, json => $json, limit => $limit, dump_sql => $dump_sql, include_changed => $include_changed });
		unlink $old_db;
		unlink $old_db . '-wal';
		unlink $old_db . '-shm';
		return $rc;
	}
	my ($backup_rows, $read_error);
	{
		my $db = eval { Mojo::SQLite->new('sqlite:' . $old_db)->db };
		$backup_rows = $db ? eval { $db->query('select * from appointments')->hashes } : undef;
		$read_error = $@;
	}
	unlink $old_db;
	unlink $old_db . '-wal';
	unlink $old_db . '-shm';
	unless ($backup_rows) {
		print "appointments time repair: could not read the snapshot's appointments"
			. (defined $read_error && length $read_error ? " ($read_error)" : '') . "\n";
		return 1;
	}

	my $plan = appointments_time_plan($backup_rows, $live, { window_start => $window, include_changed => $include_changed });
	my $summary = $plan->{'summary'};

	if ($json && !$apply) {
		print Mojo::JSON::encode_json({
			backup => $backup,
			backup_time => $snap_ms,
			window_start => $window,
			summary => $summary,
			plan => $plan->{'plan'},
		}), "\n";
		return 0;
	}

	unless ($json) {
		printf "appointments time repair - snapshot %s (%s), window start %s (%d)\n\n",
			$backup, &subs::iso_local($snap_ms), &subs::iso_local($window), $window;
		printf "live %d, snapshot %d; matched %d by uuid, %d no counterpart, %d no uuid, %d changed since the snapshot, %d already equal, %d before window; %d planned\n\n",
			$summary->{'live_rows'}, $summary->{'snapshot_rows'},
			$summary->{'matched_uuid'}, $summary->{'no_counterpart'},
			$summary->{'no_uuid'}, $summary->{'changed_since'},
			$summary->{'equal_already'}, $summary->{'before_window'}, $summary->{'planned'};
		_print_sample($plan->{'plan'}, $limit);
	}

	if (!$apply) {
		print "\ndone - nothing written. Re-run with --apply --backup <the same snapshot> to restore only server_time.\n" unless $json;
		return 0;
	}

	my $fresh = &subs::records_backup_ensure_fresh(600000);
	unless ($fresh->{'fresh'}) {
		print "appointments time repair: refusing to apply - no snapshot younger than ten minutes could be taken\n";
		return 1;
	}
	print "safety snapshot: " . ($fresh->{'made'} ? 'taken now - ' : 'using ') . $fresh->{'path'} . "\n" unless $json;

	# The person may have saved an appointment between the first read and the
	# safety snapshot; re-read and re-plan, so the transaction writes only what
	# is still re-stamped right now.
	my $live_now = _live_rows();
	unless ($live_now) {
		print "appointments time repair: could not re-read the live appointments; nothing written\n";
		return 1;
	}
	my $replan = appointments_time_plan($backup_rows, $live_now, { window_start => $window, include_changed => $include_changed });

	my ($applied, $error) = (0, undef);
	eval {
		my $begun = &subs::db_query('begin');
		die "could not begin a transaction\n" unless $begun;
		foreach my $item ( @{ $replan->{'plan'} } ) {
			my $ok = &subs::db_update('appointments', { server_time => $item->{'to'} }, { uuid => $item->{'uuid'} });
			die "server_time update failed for uuid " . (defined $item->{'uuid'} ? $item->{'uuid'} : '(none)') . "\n" unless $ok;
			$applied++;
		}
		my $committed = &subs::db_query('commit');
		die "could not commit the transaction\n" unless $committed;
		1;
	} or do {
		$error = $@ || 'unknown error';
		eval { &subs::db_query('rollback') };
	};

	if ($error) {
		print "appointments time repair: rolled back after $applied row(s): $error";
		print "\n" unless $error =~ /\n\z/;
		return 1;
	}

	&subs::log_writer("appointments time repair: restored server_time on $applied appointment row(s) from $backup (window start $window)");

	if ($json) {
		print Mojo::JSON::encode_json({
			backup => $backup,
			backup_time => $snap_ms,
			window_start => $window,
			summary => $summary,
			plan => $plan->{'plan'},
			applied => $applied,
		}), "\n";
	}
	else {
		printf "appointments time repair APPLIED: %d row(s) restored\n", $applied;
	}
	return 0;
}

# The plan is pure: it reads two arrays of row hashes and returns the rows whose
# server_time should go back to the snapshot's value. A test calls it directly.
sub appointments_time_plan {
	my ($backup_rows, $live_rows, $opts) = @_;
	$backup_rows ||= [];
	$live_rows ||= [];
	$opts ||= {};

	my $window = _number($opts->{'window_start'});
	$window = _min_server_time($live_rows) unless defined $window;
	$window = 0 unless defined $window;

	# An appointment is named by its uuid and nothing else: unlike a settings
	# row, two appointments can share an app and a timestamp legitimately.
	my %by_uuid;
	foreach my $r ( @{$backup_rows} ) {
		$by_uuid{ $r->{'uuid'} } = $r if defined $r->{'uuid'} && length $r->{'uuid'};
	}

	# Every column the two rows share, except the sync time and local bookkeeping.
	my %columns;
	foreach my $r ( @{$backup_rows}, @{$live_rows} ) {
		$columns{$_} = 1 for keys %{$r};
	}

	my %summary = (
		live_rows => scalar @{$live_rows},
		snapshot_rows => scalar @{$backup_rows},
		matched_uuid => 0,
		no_counterpart => 0,
		no_uuid => 0,
		changed_since => 0,
		equal_already => 0,
		before_window => 0,
		planned => 0,
	);
	my @plan;

	foreach my $live ( @{$live_rows} ) {
		my $uuid = $live->{'uuid'};
		if (!defined $uuid || $uuid eq '') { $summary{'no_uuid'}++; next; }
		my $match = $by_uuid{$uuid};
		unless ($match) { $summary{'no_counterpart'}++; next; }
		$summary{'matched_uuid'}++;

		my $live_time = _number($live->{'server_time'});
		my $old_time = _number($match->{'server_time'});
		next unless defined $live_time && defined $old_time;

		# Rows older than the incident were never re-stamped; equal times have
		# nothing to put back.
		if ($live_time < $window) { $summary{'before_window'}++; next; }
		if ($live_time == $old_time) { $summary{'equal_already'}++; next; }

		# Only a pure re-stamp is safe to undo. Any other difference means the
		# row was genuinely written after the snapshot, and the current time is
		# the honest one for it. --include-changed is the escape hatch for an
		# incident whose changed rows are themselves the reservoir that keeps
		# re-stamping the repaired set.
		unless ($opts->{'include_changed'}) {
			my $changed = 0;
			foreach my $col ( keys %columns ) {
				next if $IGNORED_COLUMNS{$col};
				if (_defined($live->{$col}) ne _defined($match->{$col})) { $changed = 1; last; }
			}
			if ($changed) { $summary{'changed_since'}++; next; }
		}

		push @plan, {
			uuid => $uuid,
			app => $live->{'app'},
			type => $live->{'type'},
			from => $live->{'server_time'},
			to => $match->{'server_time'},
		};
		$summary{'planned'}++;
	}

	@plan = sort {
		_defined($a->{'app'}) cmp _defined($b->{'app'})
			|| _defined($a->{'type'}) cmp _defined($b->{'type'})
			|| _defined($a->{'uuid'}) cmp _defined($b->{'uuid'})
	} @plan;

	return { window_start => $window, summary => \%summary, plan => \@plan };
}

# The SQL path keeps the comparison where the rows already are. Loading 121k
# appointments as Perl hashes needs more memory than a phone has (the first
# house-wide run OOM'd on the phone), so --sql joins the sealed snapshot to the
# live table inside SQLite and writes the plan to a temp table. Same columns,
# same guards; only the loop moves.
sub appointments_time_sql {
	my ($snap_db, $window, $columns, $limit, $apply, $include_changed) = @_;
	$limit = 20 unless defined $limit && $limit =~ /^\d+$/;
	my $q = defined $snap_db ? $snap_db : '';
	$q =~ s/'/''/g;
	my @cols = grep { defined $_ && $_ =~ /^[A-Za-z0-9_]+$/ } @{ $columns || [] };
	my $match = $include_changed ? '1'
		: join(' AND ', map { "COALESCE(CAST(l.\"$_\" AS TEXT), '') = COALESCE(CAST(s.\"$_\" AS TEXT), '')" } @cols);
	$match = '1' unless length $match;
	my $sql = "ATTACH DATABASE '$q' AS snap;\n"
		. "CREATE TEMP TABLE appt_time_plan AS\n"
		. "  SELECT l.uuid AS uuid, s.server_time AS to_time\n"
		. "  FROM main.appointments l JOIN snap.appointments s ON s.uuid = l.uuid\n"
		. "  WHERE CAST(l.server_time AS INTEGER) >= " . (0 + $window) . "\n"
		. "    AND l.server_time != s.server_time\n"
		. "    AND ($match);\n"
		. "SELECT 'planned', count(*) FROM appt_time_plan;\n"
		. "SELECT 'sample', l.app, l.type, l.uuid, l.server_time, p.to_time\n"
		. "  FROM appt_time_plan p JOIN main.appointments l ON l.uuid = p.uuid\n"
		. "  ORDER BY l.app, l.type, l.uuid LIMIT $limit;\n";
	if ($apply) {
		$sql .= "BEGIN;\n"
			. "UPDATE main.appointments\n"
			. "  SET server_time = (SELECT p.to_time FROM appt_time_plan p WHERE p.uuid = appointments.uuid)\n"
			. "  WHERE uuid IN (SELECT uuid FROM appt_time_plan);\n"
			. "SELECT 'applied', changes();\n"
			. "COMMIT;\n";
	}
	return $sql;
}

sub _sql_repair {
	my ($snap_db, $backup, $snap_ms, $window, $opts) = @_;
	my ($apply, $json, $limit) = ($opts->{'apply'}, $opts->{'json'}, $opts->{'limit'});
	my $include_changed = $opts->{'include_changed'} ? 1 : 0;
	my @live_cols = map { $_->{'name'} } @{ &subs::db_query("select name from pragma_table_info('appointments')")->hashes || [] };
	my @snap_cols;
	{
		my ($lines, $err) = _sql_run($snap_db, "select name from pragma_table_info('appointments');");
		if ($err || !$lines || !scalar @{$lines}) {
			print "appointments time repair: could not read the snapshot's columns" . ($err ? " ($err)" : '') . "\n";
			return 1;
		}
		chomp @{$lines};
		@snap_cols = @{$lines};
	}
	my %snap = map { $_ => 1 } @snap_cols;
	my @cols = grep { $snap{$_} && !$IGNORED_COLUMNS{$_} } @live_cols;
	unless (@cols || $include_changed) {
		print "appointments time repair: the snapshot and live table share no comparable columns\n";
		return 1;
	}

	my $sql = appointments_time_sql($snap_db, $window, \@cols, $limit, 0, $include_changed);
	if ($opts->{'dump_sql'}) {
		print $sql;
		return 0;
	}
	my ($lines, $err) = _sql_run('database/jawnos.db', $sql);
	if ($err) {
		print "appointments time repair: the read-only SQL plan failed ($err)\n";
		return 1;
	}
	my ($planned, @samples) = (0);
	foreach my $line (@{$lines}) {
		chomp $line;
		my ($kind, @rest) = split /\t/, $line, -1;
		if ($kind eq 'planned') { $planned = 0 + ($rest[0] || 0); }
		elsif ($kind eq 'sample') { push @samples, \@rest; }
	}

	if ($json && !$apply) {
		print Mojo::JSON::encode_json({ backup => $backup, backup_time => $snap_ms, window_start => $window, planned => $planned, sample => \@samples }), "\n";
		return 0;
	}
	unless ($json) {
		printf "appointments time repair (sql) - snapshot %s (%s), window start %s (%d)\n\n",
			$backup, &subs::iso_local($snap_ms), &subs::iso_local($window), $window;
		printf "planned %d row(s); columns compared: %d\n\n", $planned, scalar @cols;
		foreach my $s (@samples) {
			printf "  %s/%s  %s  %s -> %s\n", map { defined $_ ? $_ : '' } @{$s};
		}
	}
	if (!$apply) {
		print "\ndone - nothing written. Re-run with --apply --backup <the same snapshot> to restore only server_time.\n" unless $json;
		return 0;
	}
	if (!$planned) {
		print "nothing to restore\n" unless $json;
		print Mojo::JSON::encode_json({ backup => $backup, backup_time => $snap_ms, window_start => $window, planned => 0, applied => 0 }), "\n" if $json;
		return 0;
	}

	my $fresh = &subs::records_backup_ensure_fresh(600000);
	unless ($fresh->{'fresh'}) {
		print "appointments time repair: refusing to apply - no snapshot younger than ten minutes could be taken\n";
		return 1;
	}
	print "safety snapshot: " . ($fresh->{'made'} ? 'taken now - ' : 'using ') . $fresh->{'path'} . "\n" unless $json;

	my $apply_sql = appointments_time_sql($snap_db, $window, \@cols, $limit, 1, $include_changed);
	my ($alines, $aerr) = _sql_run('database/jawnos.db', $apply_sql);
	if ($aerr) {
		print "appointments time repair: the apply failed ($aerr)\n";
		return 1;
	}
	my ($applied, $planned_now) = (0, 0);
	foreach my $line (@{$alines}) {
		chomp $line;
		my ($kind, @rest) = split /\t/, $line, -1;
		if ($kind eq 'planned') { $planned_now = 0 + ($rest[0] || 0); }
		elsif ($kind eq 'applied') { $applied = 0 + ($rest[0] || 0); }
	}
	&subs::log_writer("appointments time repair (sql): restored server_time on $applied appointment row(s) from $backup (window start $window)");
	if ($json) {
		print Mojo::JSON::encode_json({ backup => $backup, backup_time => $snap_ms, window_start => $window, planned => $planned_now, applied => $applied }), "\n";
	}
	else {
		printf "appointments time repair APPLIED (sql): %d row(s) restored\n", $applied;
	}
	return 0;
}

	sub _sql_run {
	my ($db, $sql) = @_;
	my ($out, $in);
	my $err = gensym;
	my $pid = eval { IPC::Open3::open3($in, $out, $err, 'sqlite3', '-batch', '-noheader', '-separator', "\t", $db) };
	return (undef, 'sqlite3 is not available') unless $pid;
	print $in $sql;
	close $in;
	my @lines = <$out>;
	my @errors = <$err>;
	close $out;
	close $err;
	waitpid($pid, 0);
	my $rc = $? >> 8;
	my $message = join('', @errors);
	$message =~ s/\s+/ /g;
	$message =~ s/^ //;
	return (\@lines, $rc ? ('sqlite3 exited ' . $rc . (length $message ? ": $message" : '')) : undef);
}

sub _live_rows {
	my $rows = eval { &subs::db_query('select * from appointments')->hashes };
	return $rows || undef;
}

# The newest sealed snapshot whose filename time predates the window. The list
# is newest-first, so the first one older than the window is the one that still
# holds the pre-incident times.
sub _newest_backup_before {
	my ($window) = @_;
	my @snapshots = sort {
		my ($b1) = $b =~ /jawnos_(\d+)\.enc$/;
		my ($a1) = $a =~ /jawnos_(\d+)\.enc$/;
		($b1 || 0) <=> ($a1 || 0);
	} glob(&subs::backups_dir() . '/jawnos_*.enc');
	foreach my $snapshot ( @snapshots ) {
		my ($ms) = $snapshot =~ /jawnos_(\d+)\.enc$/;
		next unless defined $ms;
		return $snapshot if $ms < $window;
	}
	return undef;
}

# A snapshot's own time: the milliseconds in its name, else its mtime.
sub _snapshot_time {
	my ($path) = @_;
	my ($ms) = $path =~ /jawnos_(\d+)\.enc$/;
	return 0 + $ms if defined $ms && $ms =~ /^\d+$/;
	my @stat = stat($path);
	return @stat ? $stat[9] * 1000 : undef;
}

sub _min_server_time {
	my ($rows) = @_;
	my $min;
	foreach my $r ( @{$rows} ) {
		my $n = _number($r->{'server_time'});
		next unless defined $n;
		$min = $n if !defined $min || $n < $min;
	}
	return $min;
}

# The incident is a burst, not the table's oldest row: the backfill stamped tens
# of thousands of appointments while ordinary appointments carry old, legitimate
# write times. Appointments are written continuously, so a simple gap cluster
# merges the incident with the day's ordinary writes. Look first for the shape
# the re-stamp actually has - one server_time repeated on tens of thousands of
# rows - then for the densest hour (a per-row loop), then fall back to the gap
# cluster the settings tool uses for a sparse table. Refuse to guess when the
# densest shape holds less than fifty rows or less than a tenth of the table.
sub _burst_window_start {
	my ($rows) = @_;
	my @times = sort { $a <=> $b } grep { defined } map { _number($_->{'server_time'}) } @{$rows};
	return undef unless @times;
	my $floor = @times * 0.10;
	my (%exact, %hour);
	$exact{$_}++ for @times;
	$hour{int($_ / 3600000)}++ for @times;
	# One timestamp written over and over is the clearest re-stamp.
	my ($best_exact) = sort { $exact{$b} <=> $exact{$a} || $a <=> $b } keys %exact;
	return $best_exact if defined $best_exact && $exact{$best_exact} >= 50 && $exact{$best_exact} >= $floor;
	# A per-row loop over minutes or hours still makes one hour stand out.
	my ($best_hour) = sort { $hour{$b} <=> $hour{$a} || $a <=> $b } keys %hour;
	if (defined $best_hour && $hour{$best_hour} >= 50 && $hour{$best_hour} >= $floor) {
		my ($first) = grep { int($_ / 3600000) == $best_hour } @times;
		return $first;
	}
	# A sparse table: cluster the times by gaps; a gap of more than an hour
	# starts a new cluster, and the start of the largest is the incident's start.
	my $gap = 3600000;
	my @clusters;
	my ($start, $prev, $n) = ($times[0], $times[0], 1);
	for (my $i = 1; $i < @times; $i++) {
		if ($times[$i] - $prev > $gap) {
			push @clusters, [ $start, $n ];
			$start = $times[$i];
			$n = 0;
		}
		$n++;
		$prev = $times[$i];
	}
	push @clusters, [ $start, $n ];
	my ($best) = sort { $b->[1] <=> $a->[1] || $a->[0] <=> $b->[0] } @clusters;
	return undef unless $best && $best->[1] >= 50 && $best->[1] >= $floor;
	return $best->[0];
}

sub _number {
	my ($v) = @_;
	return undef unless defined $v;
	return undef unless $v =~ /^-?\d+(?:\.\d+)?$/;
	return 0 + $v;
}

sub _defined {
	my ($v) = @_;
	return defined $v ? $v : '';
}

sub _print_sample {
	my ($plan, $limit) = @_;
	my $shown = 0;
	foreach my $item ( @{$plan} ) {
		last if $limit && $shown >= $limit;
		$shown++;
		printf "  %s/%s  %s  %s -> %s\n",
			_defined($item->{'app'}), _defined($item->{'type'}),
			_defined($item->{'uuid'}),
			&subs::iso_local($item->{'from'}), &subs::iso_local($item->{'to'});
	}
	printf "  ... %d more row(s); raise --limit\n", scalar(@{$plan}) - $shown if $shown < scalar @{$plan};
}

exit(main(@ARGV)) unless caller;
1;
