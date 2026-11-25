package subs;

# Usual: the profile an app's usual button replays. Extracted from the live
# stop rows and task checklist of one app, loaded on demand by
# lib/JawnOS/Domain/Loader.pm. The write side lives in UsualWrite.pm.
#
# A session is a `stop` row: `timestamp` is its start, `stop_timestamp` its end
# and `duration` the negative length (start - stop). A task is a `usual` row
# with `source = 'task'` in the task app's own table. The profile never assumes
# a task finishes inside the session: the live medians run past 100%, up to
# 192% of the session length, and clamping them would move every late task back
# onto the stop. Fractions above 1 are the point.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Fcntl qw(:flock);
use Mojo::JSON qw(decode_json encode_json);

# A session longer than this is a clock skew or a bad merge, not a length.
my $CAP = 30 * 86400 * 1000;
# A task row may sit this long after the session's own end and still belong to
# it; the next session's start is the harder edge.
my $TASK_TAIL = 15 * 60 * 1000;

# A row's data column is JSON when present. A caller may already hold the hash.
my $data_hash = sub {
	my ($raw) = @_;
	return {} unless defined $raw;
	return $raw if ref $raw eq 'HASH';
	return {} unless length "$raw";
	my $decoded = eval { decode_json($raw) };
	return (ref $decoded eq 'HASH') ? $decoded : {};
};

# Weighted median of [{ value => ..., weight => ... }, ...]. The value whose
# running weight first reaches half the total is the median; an empty list has
# none.
my $weighted_median = sub {
	my ($pairs) = @_;
	return undef unless $pairs && @{$pairs};
	my @sorted = sort { $a->{'value'} <=> $b->{'value'} } grep { defined $_->{'value'} } @{$pairs};
	return undef unless @sorted;
	my $total = 0;
	$total += ($_->{'weight'} // 0) for @sorted;
	return undef unless $total > 0;
	my $half = $total / 2;
	my $cumulative = 0;
	foreach my $pair ( @sorted ) {
		$cumulative += ($pair->{'weight'} // 0);
		return $pair->{'value'} if $cumulative >= $half;
	}
	return $sorted[-1]{'value'};
};

# Weighted mode of [{ value => ..., weight => ... }, ...]; the first value seen
# breaks a tie (then the string, so the answer is stable across runs).
my $weighted_mode = sub {
	my ($pairs) = @_;
	return undef unless $pairs && @{$pairs};
	my (%tally, %first);
	my $seen = 0;
	foreach my $pair ( @{$pairs} ) {
		next unless defined $pair->{'value'};
		$tally{ $pair->{'value'} } += ($pair->{'weight'} // 0);
		$first{ $pair->{'value'} } //= $seen;
		$seen++;
	}
	my @values = keys %tally;
	return undef unless @values;
	my ($best) = sort { $tally{$b} <=> $tally{$a} || $first{$a} <=> $first{$b} || $a cmp $b } @values;
	return $best;
};

# The camera word the summary prints. The app's capture rows store 0/1 today;
# a name is kept as it is.
my $camera_word = sub {
	my ($value) = @_;
	return '' unless defined $value && length "$value";
	my %index = ( '0' => 'back', '1' => 'front' );
	my $word = $index{"$value"} // "$value";
	return $word if $word =~ /camera/i;
	return $word . ' ' . lc(&subs::ui('camera'));
};

# The app's recent sessions, newest first, with their recency weights, and the
# weighted-median length. Stops are the measurement; a `usual` row is the
# fallback only for an app that has not accumulated min_sessions stops yet.
my $sessions_for = sub {
	my ($app, %opt) = @_;
	my $limit = defined $opt{'limit'} ? $opt{'limit'} : 60;
	my $half_life = defined $opt{'half_life'} && $opt{'half_life'} > 0 ? $opt{'half_life'} : 6;
	my $min_sessions = defined $opt{'min_sessions'} ? $opt{'min_sessions'} : 3;

	my $stop_rows = &subs::db_query(
		q{select * from appointments where app = ? and type = ? order by cast(timestamp as integer) desc limit ?},
		$app, 'stop', $limit
	)->hashes || [];
	my $rows = $stop_rows;
	my $fallback = 0;
	if (scalar(@{$stop_rows}) < $min_sessions) {
		$rows = &subs::db_query(
			q{select * from appointments where app = ? and type = ? and coalesce(source, '') not in ('task','default','guide') and coalesce(source_uuid, '') = '' order by cast(timestamp as integer) desc limit ?},
			$app, 'usual', $limit
		)->hashes || [];
		$fallback = 1;
	}

	my @sessions;
	my $index = 0;
	foreach my $row ( @{$rows} ) {
		# A fallback usual row from a task/default/guide child is not a session
		# the person ran; the SQL already drops it, and this keeps a stubbed
		# reader honest.
		next if $fallback && ((($row->{'source'} // '') =~ /^(?:task|default|guide)$/)
			|| (($row->{'source_uuid'} // '') ne ''));
		my $stamp = 0 + ($row->{'timestamp'} // 0);
		next unless $stamp > 0;
		my ($start, $end);
		if (defined $row->{'stop_timestamp'} && length "$row->{'stop_timestamp'}") {
			# A real stop names both ends: timestamp is the start.
			$start = $stamp;
			$end = 0 + $row->{'stop_timestamp'};
		}
		else {
			# A usual row keeps the press it was written at and a signed
			# length: positive means the press was the end, negative the start.
			my $signed = 0 + ($row->{'duration'} // 0);
			if ($signed < 0) {
				$start = $stamp;
				$end = $stamp + abs($signed);
			}
			else {
				$end = $stamp;
				$start = $stamp - abs($signed);
			}
		}
		my $length = $end - $start;
		next unless $length > 0 && $length <= $CAP;
		push @sessions, {
			start => $start,
			end => $end,
			length => $length,
			timestamp => $start,
			weight => 0.5 ** ($index / $half_life),
		};
		$index++;
	}

	my @pairs = map { { value => $_->{'length'}, weight => $_->{'weight'} } } @sessions;
	my $median = @pairs ? $weighted_median->(\@pairs) : 0;
	my $outliers = 0;
	if (defined $median && $median > 0) {
		my @kept = grep { $_->{'value'} <= 3 * $median } @pairs;
		$outliers = scalar(@pairs) - scalar(@kept);
		$median = @kept ? $weighted_median->(\@kept) : 0;
	}
	return {
		sessions => \@sessions,
		duration => ($median // 0),
		outliers => $outliers,
	};
};

# The task rows for a window. A row's provenance, when present, is the exact
# association; a row without it is still matched by the task app's name, which
# is all the rows written before provenance existed can offer.
my $task_rows_for = sub {
	my ($app, $configured, $from, $to) = @_;
	return [] unless $configured && @{$configured};
	my @apps = map { $_->{'task'} } @{$configured};
	my $placeholders = join ',', ('?') x scalar(@apps);
	my $sql = "select * from appointments where app in ($placeholders) and coalesce(source, '') in (?, ?)"
		. " and cast(timestamp as integer) >= ? and cast(timestamp as integer) < ?"
		. " order by cast(timestamp as integer) asc";
	# A task row written before `source` was kept has no source either; it is
	# still the person's completion when its app is in the checklist and the
	# moment falls in the session window. Provenance, when present, still wins
	# in $row_matches_task.
	my $rows = &subs::db_query($sql, @apps, 'task', '', $from, $to)->hashes || [];
	return $rows;
};

my $row_matches_task = sub {
	my ($row, $app, $configured) = @_;
	return 0 unless ($row->{'app'} // '') eq ($configured->{'task'} // '');
	my $data = $data_hash->($row->{'data'});
	my $has_provenance = exists $data->{'task_list'} || exists $data->{'task'} || exists $data->{'task_uuid'};
	return 1 unless $has_provenance;
	return 0 if exists $data->{'task_list'} && defined $data->{'task_list'} && $data->{'task_list'} ne $app;
	return 0 if exists $data->{'task'} && defined $data->{'task'} && $data->{'task'} ne ($configured->{'task'} // '');
	return 0 if exists $data->{'task_uuid'} && defined $data->{'task_uuid'}
		&& defined $configured->{'uuid'} && $data->{'task_uuid'} ne $configured->{'uuid'};
	return 1;
};

# The direct tasks of the app, with the median fraction of the session length at
# which each was completed and the weighted share of sessions it appeared in. A
# task present in the newest session is kept even when its share is low: the
# person just did it, and a profile that drops it would drop the ritual's
# freshest step.
my $tasks_for = sub {
	my ($app, $sessions, %opt) = @_;
	my @sessions = @{ $sessions->{'sessions'} || [] };
	my $tasks_json = &subs::setting_grabber({ app => $app, setting => 'tasks' }) || '[]';
	my $all = eval { decode_json($tasks_json) };
	$all = [] unless ref $all eq 'ARRAY';

	my (@configured, %seen);
	my $order = 0;
	foreach my $entry ( @{$all} ) {
		next unless ref $entry eq 'HASH';
		next unless defined $entry->{'task'} && length "$entry->{'task'}";
		my $name = &subs::unformat_name($entry->{'task'});
		next if $seen{$name}++;
		push @configured, { %{$entry}, task => $name, order => $order++ };
	}
	return [] unless @configured && @sessions;

	my $task_frequency = defined $opt{'task_frequency'} ? $opt{'task_frequency'} : 0.5;
	my $total_weight = 0;
	$total_weight += $_->{'weight'} for @sessions;

	my (%fractions, %present, %newest_present);
	for (my $i = 0; $i < @sessions; $i++) {
		my $session = $sessions[$i];
		my $window_end = $session->{'end'} + $TASK_TAIL;
		my $next_start = $i > 0 ? $sessions[$i - 1]{'start'} : undef;
		$window_end = $next_start if defined $next_start && $next_start < $window_end;
		my $rows = $task_rows_for->($app, \@configured, $session->{'start'}, $window_end);

		# Duplicate completions in one session are one completion: keep the
		# first after the start, as the checklist itself would.
		my %first;
		foreach my $row ( @{$rows} ) {
			foreach my $configured ( @configured ) {
				next unless $row_matches_task->($row, $app, $configured);
				my $ts = 0 + ($row->{'timestamp'} // 0);
				next if $ts < $session->{'start'};
				next if exists $first{ $configured->{'task'} };
				$first{ $configured->{'task'} } = $ts;
				last;
			}
		}

		foreach my $configured ( @configured ) {
			my $name = $configured->{'task'};
			next unless defined $first{$name};
			next unless $session->{'length'} > 0;
			my $fraction = ($first{$name} - $session->{'start'}) / $session->{'length'};
			push @{ $fractions{$name} }, { value => $fraction, weight => $session->{'weight'} };
			$present{$name} += $session->{'weight'};
			$newest_present{$name} = 1 if $i == 0;
		}
	}

	my @tasks;
	foreach my $configured ( @configured ) {
		my $name = $configured->{'task'};
		my $frequency = $total_weight > 0 ? ($present{$name} // 0) / $total_weight : 0;
		next unless $frequency >= $task_frequency || $newest_present{$name};
		my @pairs = grep { $_->{'value'} >= -0.05 } @{ $fractions{$name} || [] };
		next unless @pairs;
		my $median = $weighted_median->(\@pairs);
		next unless defined $median;
		push @tasks, {
			task => $name,
			fraction => $median,
			median => $median,
			frequency => $frequency,
			count => scalar @pairs,
			uuid => $configured->{'uuid'},
			colour => $configured->{'colour'},
			project => $configured->{'project'},
			account => $configured->{'account'},
			movement => $configured->{'movement'},
			order => $configured->{'order'},
		};
	}
	@tasks = sort { $a->{'median'} <=> $b->{'median'} || $a->{'order'} <=> $b->{'order'} } @tasks;
	return \@tasks;
};

# The signature a row would be stored as: the kind of row its usual button
# writes, with the choices that distinguish one shape from another. Stable
# across machines because every field is a column or a data key, never a uuid.
sub usual_kind_signature {
	my ($app, $row) = @_;
	$app = &subs::unformat_name($app) if defined $app;
	return '' unless ref $row eq 'HASH';
	my $type = $row->{'type'} // '';
	my $data = $data_hash->($row->{'data'});
	if ($type eq 'stop') {
		my $mode = &subs::setting_grabber({ app => $app, setting => 'stock_movement' }) || 'off';
		return ($mode eq 'consume' || $mode eq 'produce') ? 'stop:stock' : 'stop';
	}
	if ($type eq 'record') {
		my $recorder = $data->{'recorder'};
		$recorder = &subs::setting_grabber({ app => $app, setting => 'record' })
			if !defined $recorder || !length "$recorder";
		return 'record:' . ($recorder // '') . ':' . ($data->{'camera'} // '') . ':' . ($data->{'machine'} // '');
	}
	if ($type eq 'image' || $type eq 'camera') {
		return 'image:' . ($data->{'camera'} // '') . ':' . ($data->{'machine'} // '');
	}
	if ($type eq 'scan') {
		return 'scan:' . ($data->{'feed'} // '') . ':' . ($data->{'machine'} // '');
	}
	if ($type eq 'transaction' || $type eq 'purchase') {
		return join ':', $type, ($row->{'movement'} // ''), ($row->{'vendor'} // ''), ($row->{'item'} // '');
	}
	return $type;
}

# The fields a usual row of this signature is written with. Numeric columns are
# weighted medians, categorical ones weighted modes; the capture/selector keys
# ride in a `data` hash for the writer and, for a transaction, the newest raw
# data is kept whole because its shape is the register's, not ours. Notes, file,
# uuid, server_time and warranty are never copied: each is about one old row.
sub usual_template_fields {
	my ($app, $signature, $rows, %opt) = @_;
	$app = &subs::unformat_name($app) if defined $app;
	$rows ||= [];
	my $half_life = defined $opt{'half_life'} && $opt{'half_life'} > 0 ? $opt{'half_life'} : 6;

	my @weighted;
	my $index = 0;
	foreach my $row ( @{$rows} ) {
		push @weighted, { row => $row, weight => 0.5 ** ($index / $half_life) };
		$index++;
	}

	my ($type) = split /:/, ($signature // ''), 2;
	my $template = { app => $app, type => ($type // '') };

	foreach my $key (qw(amount tax total quantity duration)) {
		my @pairs;
		foreach my $weighted ( @weighted ) {
			my $data = $data_hash->($weighted->{'row'}{'data'});
			my $value = $weighted->{'row'}{$key};
			$value = $data->{$key} unless defined $value && length "$value";
			next unless defined $value && "$value" =~ /^-?[0-9]+(?:\.[0-9]+)?$/;
			$value = abs($value) if $key eq 'duration';
			push @pairs, { value => 0 + $value, weight => $weighted->{'weight'} };
		}
		my $median = $weighted_median->(\@pairs);
		$template->{$key} = $median if defined $median;
	}

	foreach my $key (qw(item vendor account unit movement state currency camera recorder machine feed screen)) {
		my @pairs;
		foreach my $weighted ( @weighted ) {
			my $data = $data_hash->($weighted->{'row'}{'data'});
			my $value = $weighted->{'row'}{$key};
			$value = $data->{$key} unless defined $value && length "$value";
			next unless defined $value && length "$value";
			push @pairs, { value => "$value", weight => $weighted->{'weight'} };
		}
		my $mode = $weighted_mode->(\@pairs);
		$template->{$key} = $mode if defined $mode;
	}

	my %data;
	foreach my $key (qw(camera recorder machine screen screen_name feed source)) {
		my @pairs;
		foreach my $weighted ( @weighted ) {
			my $row_data = $data_hash->($weighted->{'row'}{'data'});
			next unless exists $row_data->{$key} && defined $row_data->{$key};
			push @pairs, { value => "$row_data->{$key}", weight => $weighted->{'weight'} };
		}
		my $mode = $weighted_mode->(\@pairs);
		$data{$key} = $mode if defined $mode;
	}
	$template->{'data'} = \%data if keys %data;

	if (($template->{'type'} // '') eq 'transaction' || ($template->{'type'} // '') eq 'purchase') {
		my ($raw) = grep { defined $_->{'data'} && length "$_->{'data'}" } @{$rows};
		$template->{'data_template'} = $raw->{'data'} if $raw;
	}
	return $template;
}

# One candidate: its signature, how often the app wrote it, and the template a
# press of its usual button would fill.
sub usual_template_build {
	my ($app, $signature, $rows, %opt) = @_;
	my $count = scalar @{ $rows || [] };
	my $total = defined $opt{'total'} && $opt{'total'} > 0 ? $opt{'total'} : $count;
	my ($type) = split /:/, ($signature // ''), 2;
	return {
		signature => $signature,
		count => $count,
		share => $total > 0 ? $count / $total : 0,
		type => ($type // ''),
		template => usual_template_fields($app, $signature, $rows, %opt),
	};
}

# The stored usual choice, if the person has made one.
sub usual_kind_get {
	my ($app) = @_;
	$app = &subs::unformat_name($app) if defined $app;
	return undef unless defined $app && length $app;
	my $value = &subs::setting_grabber({ app => $app, setting => 'usual_kind' });
	return (defined $value && length "$value") ? $value : undef;
}

# Record the choice the profile should stop asking about. The moment it was
# made is kept next to it so a profile can tell a fresh choice from an old one.
sub usual_kind_set {
	my ($app, $signature, $server_time) = @_;
	$app = &subs::unformat_name($app) if defined $app;
	return undef unless defined $app && length $app;
	my $at = $server_time || &subs::rightNow();
	&subs::setting_setter({ app => $app, setting => 'usual_kind', value => $signature, server_time => $at });
	&subs::setting_setter({ app => $app, setting => 'usual_kind_at', value => $at, server_time => $at });
	return $signature;
}

# The task part alone: what the app's checklist did, relative to its sessions.
sub usual_task_profile {
	my ($app, %opt) = @_;
	$app = &subs::unformat_name($app) if defined $app;
	$app = '' unless defined $app;
	$opt{'now'} ||= &subs::rightNow();
	my $sessions = $sessions_for->($app, %opt);
	my $tasks = $tasks_for->($app, $sessions, %opt);
	return {
		app => $app,
		sessions => scalar @{ $sessions->{'sessions'} },
		duration => $sessions->{'duration'},
		outliers => $sessions->{'outliers'},
		tasks => $tasks,
	};
}

# What this app's usual button should write: the sessions it has run, the tasks
# that followed them, and the kinds of row it has written lately. `chosen` is
# the stored choice while it is still one of the candidates; `ambiguous` tells
# the UI to ask instead of guessing.
sub usual_profile {
	my ($app, %opt) = @_;
	$app = &subs::unformat_name($app) if defined $app;
	$app = '' unless defined $app;
	my $now = $opt{'now'} || &subs::rightNow();
	$opt{'now'} = $now;

	my $sessions = $sessions_for->($app, %opt);
	my $tasks = $tasks_for->($app, $sessions, %opt);

	my $floor = $now - 365 * 86400 * 1000;
	# Our own usual presses are not evidence of what the person does with the
	# app: a task/default/guide usual row would make `usual` a candidate for
	# every app and drown a rarer real kind. The exclusion is SQL-side and
	# repeated below so a stubbed reader cannot smuggle one in.
	my $exclusion = q{type != 'usual' and coalesce(source, '') not in ('task','default','guide')};
	my $types = &subs::db_query(
		"select distinct type from appointments where app = ? and cast(timestamp as integer) >= ? and $exclusion order by type",
		$app, $floor
	)->hashes || [];

	# A flat tail of forty hides a rare kind behind a chatty one (vape's two
	# transactions sit older than its last forty stops), so read each type on
	# its own and give it up to twenty rows to build a template from.
	my @recent;
	my %real_count;
	foreach my $type_row ( @{$types} ) {
		my $type = defined $type_row->{'type'} ? "$type_row->{'type'}" : '';
		# The twenty rows are the template's evidence; the count decides whether
		# the kind is real at all, so it is asked over the whole window.
		my $count_row = &subs::db_query(
			"select count(*) as n from appointments where app = ? and type = ? and cast(timestamp as integer) >= ? and $exclusion",
			$app, $type, $floor
		)->hashes->[0];
		$real_count{$type} = 0 + ($count_row->{'n'} // 0);
		my $rows = &subs::db_query(
			"select * from appointments where app = ? and type = ? and cast(timestamp as integer) >= ? and $exclusion order by cast(timestamp as integer) desc limit 20",
			$app, $type, $floor
		)->hashes || [];
		foreach my $row ( @{$rows} ) {
			next if ($row->{'type'} // '') eq 'usual';
			push @recent, $row;
		}
	}

	my (%groups, %order);
	my $seen = 0;
	foreach my $row ( @recent ) {
		my $signature = usual_kind_signature($app, $row);
		push @{ $groups{$signature} }, $row;
		$order{$signature} //= $seen;
		$seen++;
	}
	my $total = scalar @recent;
	my @candidates;
	foreach my $signature ( keys %groups ) {
		my ($type) = split /:/, $signature, 2;
		$type = '' unless defined $type;
		my $count = defined $real_count{$type} ? $real_count{$type} : scalar @{ $groups{$signature} };
		my $is_stop = ($signature eq 'stop' || $signature eq 'stop:stock');
		# A rare variant of a common type (one camera-1 recording among twenty
		# camera-0 ones) has the type's count but not the evidence to be a
		# kind of its own.
		next unless ($count >= 2 && scalar @{ $groups{$signature} } >= 2) || ($is_stop && $count >= 1);
		my $candidate = usual_template_build($app, $signature, $groups{$signature}, %opt, total => $total);
		$candidate->{'count'} = $count;
		push @candidates, $candidate;
	}
	@candidates = sort { $b->{'count'} <=> $a->{'count'} || $a->{'signature'} cmp $b->{'signature'} } @candidates;

	# A stored choice that no longer matches a candidate is not a choice: treat
	# it as absent so the only-candidate rule or the ambiguity flag takes over
	# instead of leaving a chosen=undef / ambiguous=0 dead end.
	my $stored = usual_kind_get($app);
	my ($match) = defined $stored ? grep { $_->{'signature'} eq $stored } @candidates : ();
	my $valid_stored = $match ? $stored : undef;
	my $chosen = $valid_stored;
	$chosen = $candidates[0]{'signature'} if !defined $chosen && scalar @candidates == 1;
	my $ambiguous = (!defined $valid_stored && scalar @candidates > 1) ? 1 : 0;

	my $profile = {
		app => $app,
		sessions => scalar @{ $sessions->{'sessions'} },
		duration => $sessions->{'duration'},
		outliers => $sessions->{'outliers'},
		tasks => $tasks,
		candidates => \@candidates,
		chosen => $chosen,
		ambiguous => $ambiguous,
	};
	$profile->{'line'} = usual_summary_line($profile, $chosen);
	return $profile;
}

# One short line for the rail: the chosen kind in the person's words. Fixed
# words go through ui() so they translate; names (a vendor, an item) do not.
sub usual_summary_line {
	my ($profile, $signature) = @_;
	$profile ||= {};
	my $candidates = $profile->{'candidates'} || [];
	$signature = $profile->{'chosen'} unless defined $signature;
	$signature = $candidates->[0]{'signature'} if !defined $signature && @{$candidates};
	return '' unless defined $signature && length "$signature";

	my ($candidate) = grep { defined $_->{'signature'} && $_->{'signature'} eq $signature } @{$candidates};
	my $template = $candidate ? ($candidate->{'template'} || {}) : {};
	my @parts = split /:/, $signature, -1;
	my $type = $parts[0] // '';
	my $line;

	if ($type eq 'stop') {
		my @bits;
		push @bits, &subs::ui('inventory') if @parts > 1 && ($parts[1] // '') eq 'stock';
		my $duration = $profile->{'duration'} // 0;
		push @bits, &subs::ui('about') . ' ' . &subs::duration_sayer($duration / 1000) if $duration > 0;
		my $count = scalar @{ $profile->{'tasks'} || [] };
		push @bits, $count . ' ' . ($count == 1 ? &subs::ui('task') : &subs::ui('tasks')) if $count > 0;
		$line = join ', ', &subs::ui('Stop'), @bits;
	}
	elsif ($type eq 'transaction' || $type eq 'purchase') {
		my @bits = (&subs::format_name($type));
		push @bits, $template->{'vendor'} if defined $template->{'vendor'} && length "$template->{'vendor'}";
		push @bits, $template->{'item'} if defined $template->{'item'} && length "$template->{'item'}";
		push @bits, &subs::price_formatter(abs($template->{'total'}))
			if defined $template->{'total'} && "$template->{'total'}" =~ /[0-9]/;
		$line = join ', ', @bits;
	}
	elsif ($type eq 'image' || $type eq 'camera') {
		my $camera = $camera_word->($parts[1] // '');
		$line = &subs::ui('Image');
		$line .= ', ' . $camera if length $camera;
	}
	elsif ($type eq 'record') {
		my $recorder = $parts[1] // '';
		$line = length $recorder ? &subs::format_name($recorder) : &subs::ui('Record');
		my $camera = $camera_word->($parts[2] // '');
		$line .= ', ' . $camera if length $camera;
	}
	elsif ($type eq 'scan') {
		my $feed = $parts[1] // '';
		$line = &subs::ui('Scan');
		$line .= ', ' . &subs::format_name($feed) if length $feed;
	}
	else {
		$line = &subs::format_name($type);
	}
	$line = substr($line, 0, 77) . '...' if length($line) > 80;
	return $line;
}

# Replay the task part of a usual press: one appointment row per task at its
# learned fraction of the length, the checklist marked now (at the press) while
# each row sits at its future moment. One per-app lock serializes the read-
# modify-write of the tasks JSON exactly as the task route does, and each task
# row is written quiet so a dozen completions do not fork a dozen layouts.
sub usual_task_replay {
	my ($c, $app, $parent_uuid, $start_ms, $duration_ms, $tasks, %opt) = @_;
	$app = &subs::unformat_name($app) if defined $app;
	return { rows => [], apps => [] } unless defined $app && length $app;
	$start_ms = 0 + ($start_ms // 0);
	$duration_ms = 0 + ($duration_ms // 0);
	my $server_time = $opt{'server_time'} || &subs::rightNow();
	my $press_ms = defined $opt{'press_ms'} ? $opt{'press_ms'} : $server_time;
	my @tasks = grep { ref $_ eq 'HASH' && defined $_->{'task'} && length "$_->{'task'}" } @{ $tasks || [] };

	my $lock = &subs::home('~/.president/.task_lock_' . &subs::shorthand_name($app || 'app', 20));
	my $lock_fh;
	open($lock_fh, '>>', $lock);
	flock($lock_fh, LOCK_EX) if $lock_fh;

	my $base_json = &subs::setting_grabber({ app => $app, setting => 'tasks' }) || '[]';
	my $list = eval { decode_json($base_json) };
	$list = [] unless ref $list eq 'ARRAY';

	my (%merged, %apps, @rows);
	foreach my $task ( @tasks ) {
		my $fraction = defined $task->{'fraction'} ? $task->{'fraction'} : $task->{'median'};
		next unless defined $fraction;
		my $timestamp = $start_ms + int(0.5 + $fraction * $duration_ms);
		# The list owner is the app whose checklist holds this task. For a
		# top-level task that is the pressed app; the task's own name is what
		# the row records as its app, which task_writer takes from the entry.
		my $updated = &subs::task_writer($c, {
			papp => $app,
			app => $app,
			timestamp => $timestamp,
			uuid => $task->{'uuid'},
			name => 'completed',
			value => 'on',
			colour => $task->{'colour'},
			project => $task->{'project'},
			account => $task->{'account'},
			movement => $task->{'movement'},
			server_time => $server_time,
			completed_at => $press_ms,
			parent_uuid => $parent_uuid,
			quiet_child => 1,
		});
		next unless ref $updated eq 'ARRAY';
		# task_writer re-reads the list on every call, so only this task's own
		# entry is authoritative in the list it returns; merging the whole list
		# would put an earlier completion back to untouched.
		my ($row) = grep { ref $_ eq 'HASH' && ($_->{'uuid'} // '') eq ($task->{'uuid'} // '') } @{$updated};
		if ($row) {
			$merged{ $row->{'uuid'} } = $row;
			push @rows, $row;
		}
		$apps{ &subs::unformat_name($task->{'task'}) } = 1;
	}

	my @final = map { (ref $_ eq 'HASH' && defined $_->{'uuid'} && $merged{ $_->{'uuid'} }) ? $merged{ $_->{'uuid'} } : $_ } @{$list};
	&subs::setting_setter({ app => $app, setting => 'tasks', value => encode_json(\@final), server_time => $server_time });

	flock($lock_fh, LOCK_UN) if $lock_fh;
	close($lock_fh) if $lock_fh;

	return { rows => \@rows, apps => [ sort keys %apps ] };
}
