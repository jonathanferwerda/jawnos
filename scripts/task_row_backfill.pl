#!/usr/bin/perl

# task_row_backfill.pl - put back the task appointments a dropped write lost.
#
#   perl scripts/task_row_backfill.pl                   # dry run
#   perl scripts/task_row_backfill.pl --apply           # write the rows
#   perl scripts/task_row_backfill.pl --app shower,dump # one list only
#
# v0.1.3810 made a task completion a stop row. appointment_writer reads a stop as
# the press that closes a session, so a completion whose deterministic uuid
# closed nothing was dropped while the checklist kept its completed mark. The
# tell is a checklist entry that is completed (and writes an appointment) but
# whose `last_appt_uuid` names no row: the write was lost, or the failed write
# cleared the pointer.
#
# This re-runs the one writer the checkbox uses, at the completion's own moment,
# so the row returns with its provenance, duration, warranty and checklist
# pointer. It takes the same per-app lock as the checkbox route, skips an entry
# whose row still exists under another name, writes nothing without --apply, and
# is safe to re-run: a written completion carries its pointer.
use strict;
use warnings;
use FindBin;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';
use Fcntl qw(:flock);
use Mojo::JSON qw(decode_json encode_json);

# The writer's neighbours: task_writer -> appointment_writer needs the warranty
# and money-mirror helpers, and record_source_param for a row with no recorder.
require './lib/JawnOS/Manager/Part01.pm';
require './lib/JawnOS/Manager/Part07.pm';
require './lib/JawnOS/Manager/Part05.pm';
# Load the header renderer before its stub: a later lazy load would put the
# real one back and reach for the running app.
require './lib/JawnOS/Domain/Calendar.pm';

# appointment_writer pushes a tab frame for the row. A repair has no server to
# push to; the row reaches the open windows on their ordinary detail pull.
{
	no warnings 'redefine';
	no warnings 'prototype';
	no warnings 'once';
	*Websocket::send = sub { return 1 };
	*Websocket::console_command = sub { return {} };
	# The writer's header render needs the running app; a repair has no screen,
	# and the row is what the pull and the checklist read.
	*subs::appt_header_printer = sub { return ('', []) };
	*subs::source_header_printer = sub { return 1 };
}

# task_writer asks its controller only for a fallback server_time; the repair
# supplies one, and appointment_writer takes every other answer from the row.
{
	package TaskBackfillCtx;
	sub new { return bless {}, shift }
	sub param { return undef }
}

sub _stamp {
	my ($ms) = @_;
	my @t = gmtime(int(($ms || 0) / 1000));
	return sprintf('%04d-%02d-%02d %02d:%02d:%02d UTC',
		$t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# One checklist entry that is completed, writes an appointment, and no longer
# names a row that exists.
sub _gap {
	my ($list, $entry) = @_;
	return unless ref $entry eq 'HASH';
	my $task = &subs::unformat_name($entry->{'task'} // '');
	my $uuid = $entry->{'uuid'} // '';
	return unless length $task && length $uuid;
	return unless ($entry->{'appt'} // '') eq 'on';
	return unless ($entry->{'completed'} // '') eq 'on';
	my $completed = $entry->{'last_completed'} // '';
	return unless $completed =~ /^\d{12,}$/;
	$completed = 0 + $completed;

	my $pointer = $entry->{'last_appt_uuid'} // '';
	if (length $pointer) {
		my $named = &subs::db_query('select uuid from appointments where uuid = ? limit 1', $pointer)->hash;
		return if $named && ($named->{'uuid'} // '') eq $pointer;
	}
	# The row can exist while its pointer was lost (a later update failed, not
	# the write), so a completed entry is not a gap if its own completion is
	# already on file within a few minutes of the press.
	my $present = &subs::db_query(
		"select uuid, server_time from appointments where source = 'task' and data like ?"
			. " and cast(timestamp as integer) between ? and ? limit 1",
		'%"task_uuid":"' . $uuid . '"%', $completed - 300_000, $completed + 300_000
	)->hash;

	return {
		list => $list,
		task => $task,
		uuid => $uuid,
		completed => $completed,
		entry => $entry,
		existing => (($present && ($present->{'uuid'} // '') =~ /\S/) ? $present->{'uuid'} : undef),
		existing_server_time => ($present ? $present->{'server_time'} : undef),
	};
}

# The session the completion was done in, if it was. A task ticked after the
# session closed had no open row to link, and the repair leaves it unlinked the
# same way. Task/default/guide children are not sessions and never match.
sub _session {
	my ($list, $at) = @_;
	my $rows = &subs::db_query(
		"select uuid, type, timestamp, stop_timestamp, duration, project, account, movement from appointments"
			. " where app = ? and type in ('start','record','stop')"
			. " and coalesce(source, '') in ('', 'press')"
			. " and coalesce(source_uuid, '') = ''"
			. " and cast(timestamp as integer) <= ?"
			. " order by cast(timestamp as integer) desc limit 20",
		$list, $at
	)->hashes || [];
	foreach my $row ( @{$rows} ) {
		my $start = 0 + ($row->{'timestamp'} // 0);
		my ($from, $to);
		if (defined $row->{'stop_timestamp'} && length $row->{'stop_timestamp'}) {
			$from = $start;
			$to = 0 + $row->{'stop_timestamp'};
		}
		elsif (($row->{'type'} || '') eq 'stop') {
			# A stop with no stop_timestamp names its span by the duration sign:
			# positive is end-anchored, negative start-anchored. It is never open.
			my $dur = 0 + ($row->{'duration'} // 0);
			$from = $dur < 0 ? $start : $start - abs($dur);
			$to = $dur < 0 ? $start + abs($dur) : $start;
		}
		else {
			$from = $start;
			$to = undef;
		}
		next if $at < $from;
		next if defined $to && $at > $to;
		return $row;
	}
	return undef;
}

sub _lock {
	my ($app) = @_;
	my $path = &subs::home('~/.president/.task_lock_' . &subs::shorthand_name($app || 'app', 20));
	open(my $fh, ">>", $path) or do { warn "task_row_backfill: cannot open $path: $!\n"; return undef };
	flock($fh, LOCK_EX) or do { warn "task_row_backfill: cannot lock $path: $!\n"; return undef };
	return $fh;
}

# Re-run the checkbox writer at the completion's own moment and keep its pointer.
sub _write {
	my ($gap, $now) = @_;
	my $entry = $gap->{'entry'};
	my $parent = _session($gap->{'list'}, $gap->{'completed'});
	my $updated = &subs::task_writer(TaskBackfillCtx->new, {
		papp => $gap->{'list'},
		app => $gap->{'list'},
		timestamp => $gap->{'completed'},
		uuid => $gap->{'uuid'},
		name => 'completed',
		value => 'on',
		colour => $entry->{'colour'},
		project => ($parent ? $parent->{'project'} : undef),
		account => ($parent ? $parent->{'account'} : undef),
		movement => ($parent ? $parent->{'movement'} : undef),
		server_time => $now,
		completed_at => $gap->{'completed'},
		parent_uuid => ($parent ? $parent->{'uuid'} : undef),
		quiet_child => 1,
	});
	return unless ref $updated eq 'ARRAY';
	&subs::setting_setter({
		app => $gap->{'list'},
		setting => 'tasks',
		value => encode_json($updated),
		server_time => $now,
		# The row and the list are the repair; the live checkbox route is the
		# one that re-renders the checklist for the open tabs.
		sync => 1,
	});
	my ($row) = grep { ref $_ eq 'HASH' && ($_->{'uuid'} // '') eq $gap->{'uuid'} } @{$updated};
	return ($row, $parent);
}

# The row is on file while the checklist lost its pointer (the write before the
# list save, or a later failed update). Point the entry at it; write no second row.
sub _stitch {
	my ($list, $m, $now) = @_;
	my $entries = eval { decode_json(&subs::setting_grabber({ app => $list, setting => 'tasks' }) // '') };
	return unless ref $entries eq 'ARRAY';
	my ($found);
	foreach my $entry ( @{$entries} ) {
		next unless ref $entry eq 'HASH' && ($entry->{'uuid'} // '') eq $m->{'uuid'};
		$entry->{'last_appt_uuid'} = $m->{'existing'};
		$entry->{'last_server_time'} = $m->{'existing_server_time'}
			if defined $m->{'existing_server_time'};
		$found = $entry;
	}
	return unless $found;
	&subs::setting_setter({
		app => $list,
		setting => 'tasks',
		value => encode_json($entries),
		server_time => $now,
		sync => 1,
	});
	return $found;
}

sub main {
	my (@argv) = @_;
	my $apply = 0;
	my @only;
	for (my $i = 0; $i < @argv; $i++) {
		$apply = 1 if $argv[$i] eq '--apply';
		if ($argv[$i] eq '--app' && defined $argv[$i + 1]) {
			push @only, split /,/, $argv[++$i];
		}
	}
	my %only = map { &subs::unformat_name($_) => 1 } grep { defined && length } @only;
	my $now = &subs::rightNow();

	my $settings = &subs::db_query('select app, value from settings where setting = ? order by app', 'tasks')->hashes || [];
	my @gaps;
	foreach my $set ( @{$settings} ) {
		my $list = &subs::unformat_name($set->{'app'});
		next if %only && !$only{$list};
		my $entries = eval { decode_json($set->{'value'} // '') };
		next unless ref $entries eq 'ARRAY';
		my @missing;
		foreach my $entry ( @{$entries} ) {
			my $gap = _gap($list, $entry);
			push @missing, $gap if $gap;
		}
		push @gaps, { list => $list, missing => \@missing } if @missing;
	}

	my $total = 0;
	$total += scalar @{$_->{'missing'}} for @gaps;
	if (!@gaps) {
		print "no dropped task completions found\n";
		return 0;
	}
	print "dropped task completions: $total across " . scalar(@gaps) . " list(s)\n";
	foreach my $gap ( @gaps ) {
		print '  ' . $gap->{'list'} . ' (' . scalar(@{$gap->{'missing'}}) . ")\n";
		foreach my $m ( @{$gap->{'missing'}} ) {
			my $parent = _session($gap->{'list'}, $m->{'completed'});
			my $where = ($m->{'existing'} // '') =~ /\S/
				? 'row exists, pointer lost'
				: ($parent ? 'in ' . substr($parent->{'uuid'}, 0, 8) : 'no open session');
			print '    ' . sprintf('%-24s %s  %s', $m->{'task'}, _stamp($m->{'completed'}),
				$where) . "\n";
		}
	}

	unless ($apply) {
		print "\ndry run - pass --apply to write these rows\n";
		return 0;
	}

	my ($written, $linked, $failed) = (0, 0, 0);
	foreach my $gap ( @gaps ) {
		my $lock = _lock($gap->{'list'});
		unless ($lock) {
			print 'could not lock ' . $gap->{'list'} . "\n";
			$failed += scalar @{$gap->{'missing'}};
			next;
		}
		foreach my $m ( @{$gap->{'missing'}} ) {
			if (($m->{'existing'} // '') =~ /\S/) {
				my $row = _stitch($gap->{'list'}, $m, $now);
				if ($row) {
					print 'linked ' . $m->{'task'} . ' at ' . _stamp($m->{'completed'})
						. ' -> ' . $m->{'existing'} . "\n";
					$linked++;
				}
				else {
					print 'FAILED to link ' . $m->{'task'} . ' at ' . _stamp($m->{'completed'}) . "\n";
					$failed++;
				}
				next;
			}
			my ($row) = eval { _write($m, $now) };
			if ($@) {
				$@ =~ s/\s+/ /g;
				print 'FAILED ' . $m->{'task'} . ' at ' . _stamp($m->{'completed'}) . " ($@)\n";
				$failed++;
				next;
			}
			if ($row && ($row->{'last_appt_uuid'} // '') =~ /\S/) {
				print 'wrote ' . $m->{'task'} . ' at ' . _stamp($m->{'completed'})
					. ' -> ' . $row->{'last_appt_uuid'} . "\n";
				$written++;
			}
			else {
				print 'FAILED ' . $m->{'task'} . ' at ' . _stamp($m->{'completed'}) . "\n";
				$failed++;
			}
		}
		flock($lock, LOCK_UN);
		close($lock);
	}
	print "\nbackfilled $written row(s)"
		. ($linked ? ", linked $linked pointer(s)" : '')
		. ($failed ? ", $failed failed" : '') . "\n";
	return $failed ? 1 : 0;
}

exit(main(@ARGV)) unless caller;
1;
