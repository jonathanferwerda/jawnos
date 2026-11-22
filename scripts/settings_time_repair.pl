#!/usr/bin/env perl
# settings_time_repair.pl - put back the settings write times a bad backfill stamped.
#
#   perl scripts/settings_time_repair.pl [--backup <path>] [--window-start <ms>]
#                                        [--apply] [--json] [--limit N]
#
# A settings backfill updated by the always-null `id` column, so the write
# matched every row and stamped server_time = now across the table. The v3 sync
# localises by weekly server_time bands, so one stamp collapses the whole table
# into a single band and every change reads all 60k rows. This compares an older
# sealed snapshot with the live table and restores ONLY server_time, for rows the
# snapshot still holds an older write time for. value is never touched, and a row
# whose value changed since the snapshot is left alone: that is a genuine later
# write, not a re-stamp, and giving it the old time would make it look older.
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
require Mojo::JSON;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $SAMPLE_LIMIT = 20;

# The body is a function, not the file's top level, so a test can call it with
# the domain subs stubbed: this tool writes settings times back, and the refusals
# it must never skip (no explicit older snapshot, no fresh safety snapshot) are
# worth pinning without touching a live database.
sub main {
	my (@argv) = @_;
	my ($opt_backup, $explicit_backup, $opt_window, $apply, $json, $limit);
	$limit = $SAMPLE_LIMIT;
	for (my $i = 0; $i < @argv; $i++) {
		my $a = $argv[$i];
		if ($a eq '--backup' && defined $argv[$i + 1]) {
			$opt_backup = $argv[$i + 1];
			$explicit_backup = 1;
		}
		elsif ($a eq '--window-start' && defined $argv[$i + 1]) { $opt_window = $argv[$i + 1]; }
		elsif ($a eq '--apply') { $apply = 1; }
		elsif ($a eq '--json') { $json = 1; }
		elsif ($a eq '--limit' && defined $argv[$i + 1] && $argv[$i + 1] =~ /^\d+$/) { $limit = $argv[$i + 1]; }
	}

	# An apply without a named older snapshot could re-stamp rows with the
	# incident's own time; refuse before reading the database at all.
	if ($apply && !$explicit_backup) {
		print "settings time repair: --apply requires an explicit --backup <path> older than the incident window; refusing to write.\n";
		return 1;
	}
	if (defined $opt_window) {
		unless ($opt_window =~ /^\d+$/) {
			print "settings time repair: --window-start must be milliseconds since the epoch\n";
			return 1;
		}
		$opt_window = 0 + $opt_window;
	}

	my $live = _live_rows();
	unless ($live) {
		print "settings time repair: could not read the live settings\n";
		return 1;
	}

	my $window = defined $opt_window ? $opt_window : _burst_window_start($live);
	unless (defined $window) {
		print "settings time repair: could not find a dense recent burst (or the live settings have no numeric server_time); pass --window-start <ms>\n";
		return 1;
	}

	my $backup;
	if ($explicit_backup) {
		$backup = $opt_backup;
		unless (defined $backup && -e $backup) {
			print "settings time repair: --backup does not exist: " . (defined $backup ? $backup : '') . "\n";
			return 1;
		}
	}
	else {
		$backup = _newest_backup_before($window);
		unless ($backup) {
			print "settings time repair: no snapshot in " . &subs::backups_dir()
				. " is older than the window start (" . $window . "); pass --backup <path>\n";
			return 1;
		}
	}

	my $snap_ms = _snapshot_time($backup);
	unless (defined $snap_ms) {
		print "settings time repair: cannot tell when $backup was taken; name a snapshot jawnos_<ms>.enc\n";
		return 1;
	}
	if ($snap_ms >= $window) {
		print "settings time repair: refusing - the snapshot $backup was taken at "
			. &subs::iso_local($snap_ms) . ", not before the window start "
			. &subs::iso_local($window) . " (" . $window . "); name an older --backup\n";
		return 1;
	}

	my $old_db = &subs::records_backup_decrypt($backup);
	unless ($old_db) {
		print "settings time repair: could not unseal $backup (key or format)\n";
		return 1;
	}
	my ($backup_rows, $read_error);
	{
		my $db = eval { Mojo::SQLite->new('sqlite:' . $old_db)->db };
		$backup_rows = $db ? eval { $db->query('select app,setting,subsetting,device,value,server_time,uuid from settings')->hashes } : undef;
		$read_error = $@;
	}
	unlink $old_db;
	unlink $old_db . '-wal';
	unlink $old_db . '-shm';
	unless ($backup_rows) {
		print "settings time repair: could not read the snapshot's settings"
			. (defined $read_error && length $read_error ? " ($read_error)" : '') . "\n";
		return 1;
	}

	my $plan = settings_time_plan($backup_rows, $live, { window_start => $window });
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
		printf "settings time repair - snapshot %s (%s), window start %s (%d)\n\n",
			$backup, &subs::iso_local($snap_ms), &subs::iso_local($window), $window;
		printf "live %d, snapshot %d; matched %d by uuid, %d by key; %d ambiguous key(s), %d no counterpart, %d value changed, %d no uuid, %d already equal, %d before window; %d planned\n\n",
			$summary->{'live_rows'}, $summary->{'snapshot_rows'},
			$summary->{'matched_uuid'}, $summary->{'matched_key'},
			$summary->{'ambiguous_keys'}, $summary->{'no_counterpart'},
			$summary->{'value_changed'}, $summary->{'no_uuid'},
			$summary->{'equal_already'}, $summary->{'before_window'}, $summary->{'planned'};
		_print_sample($plan->{'plan'}, $limit);
	}

	if (!$apply) {
		print "\ndone - nothing written. Re-run with --apply --backup <the same snapshot> to restore only server_time.\n" unless $json;
		return 0;
	}

	my $fresh = &subs::records_backup_ensure_fresh(600000);
	unless ($fresh->{'fresh'}) {
		print "settings time repair: refusing to apply - no snapshot younger than ten minutes could be taken\n";
		return 1;
	}
	print "safety snapshot: " . ($fresh->{'made'} ? 'taken now - ' : 'using ') . $fresh->{'path'} . "\n" unless $json;

	# The person may have saved settings between the first read and the safety
	# snapshot; re-read and re-plan, so the transaction writes only what is still
	# re-stamped right now.
	my $live_now = _live_rows();
	unless ($live_now) {
		print "settings time repair: could not re-read the live settings; nothing written\n";
		return 1;
	}
	my $replan = settings_time_plan($backup_rows, $live_now, { window_start => $window });

	my ($applied, $error) = (0, undef);
	eval {
		my $begun = &subs::db_query('begin');
		die "could not begin a transaction\n" unless $begun;
		foreach my $item ( @{ $replan->{'plan'} } ) {
			my $ok = &subs::db_update('settings', { server_time => $item->{'to'} }, { uuid => $item->{'uuid'} });
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
		print "settings time repair: rolled back after $applied row(s): $error";
		print "\n" unless $error =~ /\n\z/;
		return 1;
	}

	&subs::log_writer("settings time repair: restored server_time on $applied settings row(s) from $backup (window start $window)");

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
		printf "settings time repair APPLIED: %d row(s) restored\n", $applied;
	}
	return 0;
}

# The plan is pure: it reads two arrays of row hashes and returns the rows whose
# server_time should go back to the snapshot's value. A test calls it directly.
sub settings_time_plan {
	my ($backup_rows, $live_rows, $opts) = @_;
	$backup_rows ||= [];
	$live_rows ||= [];
	$opts ||= {};

	my $window = _number($opts->{'window_start'});
	$window = _min_server_time($live_rows) unless defined $window;
	$window = 0 unless defined $window;

	# A snapshot row can be found by its uuid, or - when the uuid is gone - by
	# the logical settings key. The key is only trustworthy when exactly one
	# snapshot row carries it; two leave the choice ambiguous, so the row is left
	# for a person rather than guessed.
	my (%by_uuid, %by_key);
	foreach my $r ( @{$backup_rows} ) {
		$by_uuid{ $r->{'uuid'} } = $r if defined $r->{'uuid'} && length $r->{'uuid'};
		push @{ $by_key{ _settings_key($r) } }, $r;
	}

	my %ambiguous_seen;
	my %summary = (
		live_rows => scalar @{$live_rows},
		snapshot_rows => scalar @{$backup_rows},
		matched_uuid => 0,
		matched_key => 0,
		ambiguous_keys => 0,
		no_counterpart => 0,
		no_uuid => 0,
		value_changed => 0,
		equal_already => 0,
		before_window => 0,
		planned => 0,
	);
	my @plan;

	foreach my $live ( @{$live_rows} ) {
		my ($match, $how);
		if (defined $live->{'uuid'} && length $live->{'uuid'} && $by_uuid{ $live->{'uuid'} }) {
			$match = $by_uuid{ $live->{'uuid'} };
			$how = 'uuid';
			$summary{'matched_uuid'}++;
		}
		else {
			my $key = _settings_key($live);
			my $candidates = $by_key{$key};
			my $count = $candidates ? scalar @{$candidates} : 0;
			if ($count == 1) {
				$match = $candidates->[0];
				$how = 'key';
				$summary{'matched_key'}++;
			}
			elsif ($count > 1) {
				$summary{'ambiguous_keys'}++ unless $ambiguous_seen{$key}++;
			}
			else {
				$summary{'no_counterpart'}++;
			}
		}
		next unless $match;

		my $live_time = _number($live->{'server_time'});
		my $old_time = _number($match->{'server_time'});
		next unless defined $live_time && defined $old_time;

		# Rows older than the incident were never re-stamped; equal times have
		# nothing to put back.
		if ($live_time < $window) { $summary{'before_window'}++; next; }
		if ($live_time == $old_time) { $summary{'equal_already'}++; next; }
		# A settings row is written back by uuid; a row with none cannot be
		# repaired safely, so leave it for a person.
		if (!defined $live->{'uuid'} || $live->{'uuid'} eq '') { $summary{'no_uuid'}++; next; }
		# Only a pure re-stamp is safe to undo. A different value means the row was
		# genuinely written after the snapshot (or a recovery chose another value),
		# and the current time is the honest one for it.
		if (_defined($live->{'value'}) ne _defined($match->{'value'})) {
			$summary{'value_changed'}++;
			next;
		}

		push @plan, {
			uuid => $live->{'uuid'},
			app => $live->{'app'},
			setting => $live->{'setting'},
			subsetting => $live->{'subsetting'},
			device => $live->{'device'},
			from => $live->{'server_time'},
			to => $match->{'server_time'},
			match => $how,
		};
		$summary{'planned'}++;
	}

	@plan = sort {
		_defined($a->{'app'}) cmp _defined($b->{'app'})
			|| _defined($a->{'setting'}) cmp _defined($b->{'setting'})
			|| _defined($a->{'device'}) cmp _defined($b->{'device'})
			|| _defined($a->{'subsetting'}) cmp _defined($b->{'subsetting'})
			|| _defined($a->{'uuid'}) cmp _defined($b->{'uuid'})
	} @plan;

	return { window_start => $window, summary => \%summary, plan => \@plan };
}

sub _live_rows {
	my $rows = eval { &subs::db_query('select app,setting,subsetting,device,value,server_time,uuid from settings')->hashes };
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
# of thousands of settings while ordinary settings carry old, legitimate write
# times. Its writes may still take hours - a per-row loop is slow - so cluster
# the times by gaps: a gap of more than an hour starts a new cluster. The start
# of the largest cluster is the incident's own start, and it is newer than the
# snapshot taken just before it. Refuse to guess when that cluster holds less than
# fifty rows or less than a tenth of the table - a real incident is not a handful
# of writes.
sub _burst_window_start {
	my ($rows) = @_;
	my @times = sort { $a <=> $b } grep { defined } map { _number($_->{'server_time'}) } @{$rows};
	return undef unless @times;
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
	return undef unless $best && $best->[1] >= 50 && $best->[1] >= @times * 0.10;
	return $best->[0];
}

# The logical settings key, with the NULL-safe empty string the sync uses.
sub _settings_key {
	my ($r) = @_;
	return join "\x1f", map { defined $_ ? $_ : '' } ($r->{'app'}, $r->{'setting'}, $r->{'subsetting'}, $r->{'device'});
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
		my $sub = (defined $item->{'subsetting'} && length $item->{'subsetting'}) ? '[' . $item->{'subsetting'} . ']' : '';
		my $dev = (defined $item->{'device'} && length $item->{'device'}) ? ' @' . $item->{'device'} : '';
		printf "  %s/%s%s%s  %s  %s -> %s  (%s)\n",
			_defined($item->{'app'}), _defined($item->{'setting'}), $sub, $dev,
			_defined($item->{'uuid'}),
			&subs::iso_local($item->{'from'}), &subs::iso_local($item->{'to'}),
			_defined($item->{'match'});
	}
	printf "  ... %d more row(s); raise --limit\n", scalar(@{$plan}) - $shown if $shown < scalar @{$plan};
}

exit(main(@ARGV)) unless caller;
1;
