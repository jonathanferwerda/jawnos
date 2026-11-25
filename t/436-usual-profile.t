# tests-for: lib/JawnOS/Domain/Usual.pm
# covers:    the usual profile - the weighted session length, recency over an old
#           outlier, task fractions past 100% in order, the completion-frequency
#           threshold, exact provenance versus the app-name fallback, the
#           candidate signatures and ambiguity, the summary line, and the replay
#           that marks the checklist at the press while writing rows in the future

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use Mojo::JSON qw(decode_json encode_json);
use JawnOSTest;

# The profile reads only through db_query and the settings pair, so a fixture
# row set and three hashes are enough; no live database is touched.
{
	package UsualRows;
	sub new { my ($class, $rows) = @_; bless { rows => $rows }, $class }
	sub hashes { $_[0]->{'rows'} }
}

{
	package UsualCtx;
	sub new { bless {}, shift }
	sub param { return undef }
}

my (%stops, %usual, %candidates, %task_rows, %settings);

{
	no warnings 'redefine';
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		my $app = $args[0];
		my $strict = $sql =~ /type != 'usual'/ ? 1 : 0;
		my $excluded = sub {
			my $type = $_[0]->{'type'} // '';
			my $source = $_[0]->{'source'} // '';
			return 1 if $strict && $type eq 'usual';
			return 1 if $strict && $source =~ /^(?:task|default|guide)$/;
			return 1 if !$strict && $type eq 'usual' && $source =~ /^(?:task|default|guide)$/;
			return 0;
		};
		if ($sql =~ /select distinct type/) {
			my $floor = $args[1];
			my %type;
			foreach my $row ( @{ $candidates{$app} || [] } ) {
				next if $excluded->($row);
				next unless defined $row->{'timestamp'} && (0 + $row->{'timestamp'}) >= $floor;
				$type{ $row->{'type'} // '' } = 1;
			}
			return UsualRows->new([ map { { type => $_ } } sort keys %type ]);
		}
		if ($sql =~ /count\(\*\) as n/) {
			my ($type, $floor) = @args[1, 2];
			my $n = scalar grep {
				!$excluded->($_) && (($_->{'type'} // '') eq $type)
					&& (0 + $_->{'timestamp'}) >= $floor
			} @{ $candidates{$app} || [] };
			return UsualRows->new([ { n => $n } ]);
		}
		if ($sql =~ /limit 20/) {
			my ($type, $floor) = @args[1, 2];
			my @rows = grep {
				!$excluded->($_) && (($_->{'type'} // '') eq $type)
					&& (0 + $_->{'timestamp'}) >= $floor
			} @{ $candidates{$app} || [] };
			@rows = sort { (0 + $b->{'timestamp'}) <=> (0 + $a->{'timestamp'}) } @rows;
			splice(@rows, 20) if @rows > 20;
			return UsualRows->new(\@rows);
		}
		if ($sql =~ /app in \(/) {
			my %allowed = map { $_ => 1 } ($sql =~ /coalesce\(source, ''\) in \(\?, \?\)/ ? ('task', '') : ('task'));
			my ($from, $to) = @args[-2, -1];
			my @rows = grep {
				$allowed{ $_->{'source'} // '' }
					&& (0 + $_->{'timestamp'}) >= $from && (0 + $_->{'timestamp'}) < $to
			} @{ $task_rows{$app} || [] };
			return UsualRows->new(\@rows);
		}
		if (($args[1] // '') eq 'usual') {
			return UsualRows->new($usual{$app} || []);
		}
		return UsualRows->new($stops{$app} || []);
	};
	local *subs::setting_grabber = sub {
		my ($request) = @_;
		return $settings{ $request->{'app'} }{ $request->{'setting'} };
	};
	local *subs::setting_setter = sub { return 1; };

	# ---------------------------------------------------------------- durations
	# Three recent ten-minute sessions and one old hundred-minute one. The plain
	# average is 32m 30s; the recency weight keeps the median at ten minutes and
	# reports the old row as the outlier it is.
	sub stop_row {
		my ($start, $length, %extra) = @_;
		return {
			app => 'coffee', type => 'stop',
			timestamp => "$start", stop_timestamp => '' . ($start + $length),
			duration => "-$length", data => '', %extra,
		};
	}
	$stops{'coffee'} = [
		stop_row(4_000_000, 600_000),
		stop_row(3_000_000, 600_000),
		stop_row(2_000_000, 600_000),
		stop_row(1_000_000, 6_000_000),
	];
	my $duration = &subs::usual_task_profile('coffee');
	is($duration->{'duration'}, 600_000, 'the recent ten-minute sessions set the length, not the old hundred-minute one');
	is($duration->{'outliers'}, 1, 'the old row is reported as a duration outlier');
	is($duration->{'sessions'}, 4, 'all four sessions are measured before the outlier is dropped');

	# A `usual` row is the fallback when an app has too few stops to learn from.
	$stops{'tea'} = [ stop_row(4_000_000, 300_000) ];
	$usual{'tea'} = [
		{ app => 'tea', type => 'usual', timestamp => 3_000_000, duration => '600000', data => '' },
		{ app => 'tea', type => 'usual', timestamp => 2_000_000, duration => '600000', data => '' },
		{ app => 'tea', type => 'usual', timestamp => 1_000_000, duration => '600000', data => '' },
	];
	my $fallback = &subs::usual_task_profile('tea');
	is($fallback->{'sessions'}, 3, 'an app with fewer than three stops measures its usual rows instead');
	is($fallback->{'duration'}, 600_000, 'and learns the usual row length');

	# -------------------------------------------------------------------- tasks
	# Four ten-minute shower sessions, newest first. The task rows sit at the
	# fractions the live data shows: washing just before the stop, drying just
	# after it, deodorant well past it (192%), and one old task that is neither
	# frequent nor in the newest session.
	$stops{'shower'} = [
		stop_row(4_000_000, 600_000, app => 'shower'),
		stop_row(3_000_000, 600_000, app => 'shower'),
		stop_row(2_000_000, 600_000, app => 'shower'),
		stop_row(1_000_000, 600_000, app => 'shower'),
	];
	$settings{'shower'} = {
		tasks => encode_json([
			{ task => 'washing',       uuid => 'tw', colour => '#fff' },
			{ task => 'drying',        uuid => 'td', colour => '#eee' },
			{ task => 'deodorant',     uuid => 'tz' },
			{ task => 'wash_hands',    uuid => 'th' },
			{ task => 'mess_up_hair',  uuid => 'tm' },
			{ task => 'cleaning_ears', uuid => 'te' },
			{ task => 'brush_teeth',   uuid => 'tb' },
		]),
	};
	my @starts = (4_000_000, 3_000_000, 2_000_000, 1_000_000);
	my @task_fixture;
	foreach my $start (@starts) {
		push @task_fixture, { app => 'washing', type => 'usual', source => 'task', data => '',
			timestamp => '' . ($start + 596_400) };                     # 99.4%
		push @task_fixture, { app => 'drying', type => 'usual', source => 'task', data => '',
			timestamp => '' . ($start + 637_200) };                     # 106.2%
	}
	push @task_fixture, { app => 'deodorant', type => 'usual', source => 'task', data => '',
		timestamp => '' . (4_000_000 + 1_156_200) };                    # 192.7%, newest only
	push @task_fixture, { app => 'wash_hands', type => 'usual', source => 'task', data => '',
		timestamp => '' . (1_000_000 + 945_000) };                      # oldest only
	# The legacy row carries no provenance and is still matched by the task app's
	# name. The provenance row says it belongs to another app's checklist, so it
	# must not move this task's fraction.
	push @task_fixture, { app => 'mess_up_hair', type => 'usual', source => 'task', data => '',
		timestamp => '' . (4_000_000 + 832_200) };                      # 138.7%
	push @task_fixture, { app => 'mess_up_hair', type => 'usual', source => 'task',
		data => encode_json({ task_list => 'other_app', task => 'mess_up_hair', task_uuid => 'tm' }),
		timestamp => '' . (3_000_000 + 60_000) };
	# Exact provenance ties both rows to this app's checklist entry.
	push @task_fixture, { app => 'cleaning_ears', type => 'usual', source => 'task',
		data => encode_json({ task_list => 'shower', task => 'cleaning_ears', task_uuid => 'te' }),
		timestamp => '' . (4_000_000 + 300_000) };
	push @task_fixture, { app => 'cleaning_ears', type => 'usual', source => 'task',
		data => encode_json({ task_list => 'shower', task => 'cleaning_ears', task_uuid => 'te' }),
		timestamp => '' . (3_000_000 + 360_000) };
	# A completion written before `source` was kept has none at all; its app and
	# the session window still place it.
	push @task_fixture, { app => 'brush_teeth', type => 'usual', source => '', data => '',
		timestamp => '' . (4_000_000 + 480_000) };                     # 80%, newest only
	# The task query names the task apps, not the app whose checklist holds them;
	# the fixture is keyed by the first configured task app (washing).
	$task_rows{'washing'} = \@task_fixture;

	$candidates{'shower'} = [
		@{ $stops{'shower'} },
		{ app => 'shower', type => 'record', timestamp => 4_000_000,
			data => encode_json({ recorder => 'video', camera => 'front', machine => 'phone' }) },
		{ app => 'shower', type => 'record', timestamp => 3_000_000,
			data => encode_json({ recorder => 'video', camera => 'front', machine => 'phone' }) },
		{ app => 'shower', type => 'record', timestamp => 2_000_000,
			data => encode_json({ recorder => 'video', camera => 'front', machine => 'phone' }) },
		{ app => 'shower', type => 'image', timestamp => 1_500_000, data => encode_json({ camera => 0 }) },
	];

	my $profile = &subs::usual_profile('shower', now => 5_000_000);
	my @names = map { $_->{'task'} } @{ $profile->{'tasks'} };
	is_deeply(\@names, [qw(cleaning_ears brush_teeth washing drying mess_up_hair deodorant)],
		'tasks are ordered by their median fraction, including the ones past 100%');

	my %task = map { $_->{'task'} => $_ } @{ $profile->{'tasks'} };
	cmp_ok($task{'drying'}{'fraction'}, '>', 1, 'a task after the stop keeps a fraction above 100%');
	cmp_ok($task{'deodorant'}{'fraction'}, '>', 1.9, 'a task well after the stop is not clamped');
	ok(!exists $task{'wash_hands'}, 'a task outside the frequency threshold and the newest session is left out');
	is($task{'mess_up_hair'}{'count'}, 1, 'a row whose provenance names another checklist does not join this task');
	cmp_ok($task{'mess_up_hair'}{'fraction'}, '>', 1.38, 'the legacy row is still matched by the task app name');
	is($task{'cleaning_ears'}{'count'}, 2, 'rows whose provenance names this app and entry are an exact association');
	is($task{'brush_teeth'}{'count'}, 1, 'a blank-source task row is still the person\'s completion');
	is($profile->{'sessions'}, 4, 'the profile reports the sessions it measured');
	is($profile->{'duration'}, 600_000, 'and the weighted session length');

	# --------------------------------------------------------------- candidates
	my @signatures = map { $_->{'signature'} } @{ $profile->{'candidates'} };
	is_deeply(\@signatures, [ 'stop', 'record:video:front:phone' ],
		'the recent rows group by signature, ordered by count');
	is(scalar @{ $profile->{'candidates'} }, 2, 'a single image row is below the candidate floor');
	is($profile->{'ambiguous'}, 1, 'two candidates with no stored choice are ambiguous');
	is($profile->{'chosen'}, undef, 'and nothing is chosen for the person');

	$settings{'shower'}{'usual_kind'} = 'record:video:front:phone';
	my $chosen = &subs::usual_profile('shower', now => 5_000_000);
	is($chosen->{'chosen'}, 'record:video:front:phone', 'a stored choice that is still a candidate is chosen');
	is($chosen->{'ambiguous'}, 0, 'and the profile is no longer ambiguous');
	my ($record) = grep { $_->{'signature'} eq 'record:video:front:phone' } @{ $chosen->{'candidates'} };
	is($record->{'template'}{'camera'}, 'front', 'the record template keeps the camera the rows used');
	is($record->{'template'}{'recorder'}, 'video', 'and the recorder');

	# A stop is always a candidate, even when the app has only one.
	$candidates{'sparse'} = [ stop_row(2_000_000, 600_000, app => 'sparse') ];
	my $sparse = &subs::usual_profile('sparse', now => 5_000_000);
	my ($only) = @{ $sparse->{'candidates'} };
	is($only->{'signature'}, 'stop', 'a single stop is still offered');
	is($sparse->{'chosen'}, 'stop', 'and it is the only candidate, so it is chosen');

	# A consuming app's stop is its own signature.
	$settings{'coffee'}{'stock_movement'} = 'consume';
	$candidates{'coffee'} = [ @{ $stops{'coffee'} } ];
	my $stock = &subs::usual_profile('coffee', now => 5_000_000);
	my ($stock_candidate) = grep { $_->{'signature'} eq 'stop:stock' } @{ $stock->{'candidates'} };
	ok($stock_candidate, 'a stop on an app that consumes stock is the stop:stock signature');

	# A stored choice that no longer matches a candidate is ignored.
	$settings{'shower'}{'usual_kind'} = 'stale:kind';
	my $stale = &subs::usual_profile('shower', now => 5_000_000);
	is($stale->{'chosen'}, undef, 'a stored kind that is no longer a candidate is ignored');
	is($stale->{'ambiguous'}, 1, 'so the profile asks again instead of dead-ending');

	$settings{'coffee'}{'usual_kind'} = 'stale:kind';
	my $stale_one = &subs::usual_profile('coffee', now => 5_000_000);
	is($stale_one->{'chosen'}, 'stop:stock', 'a stale choice with one candidate falls back to it');
	is($stale_one->{'ambiguous'}, 0, 'and is not ambiguous');

	# A chatty type must not hide a rare one: thirty stops do not bury two
	# transactions, and our own usual rows are never a kind.
	my @vape_stops = map { stop_row(4_000_000 - $_ * 1_000, 600_000, app => 'vape') } (0 .. 29);
	my @vape_tx = map {
		{ app => 'vape', type => 'transaction', movement => 'consume', vendor => '77 Vape',
			item => 'Geek Bar', total => 57, timestamp => 2_000_000 - $_ * 1_000,
			data => encode_json({ app => 'vape' }) }
	} (0 .. 1);
	my @vape_usual = map {
		{ app => 'vape', type => 'usual', source => ($_ % 2 ? 'press' : 'guide'),
			timestamp => 4_500_000 - $_ * 1_000, data => '' }
	} (0 .. 4);
	$candidates{'vape'} = [ @vape_stops, @vape_tx, @vape_usual ];
	my $vape = &subs::usual_profile('vape', now => 5_000_000);
	my @vape_signatures = sort map { $_->{'signature'} } @{ $vape->{'candidates'} };
	is_deeply(\@vape_signatures, [ 'stop', 'transaction:consume:77 Vape:Geek Bar' ],
		'two old transactions are offered beside thirty newer stops');
	ok(!grep({ $_ eq 'usual' } @vape_signatures), 'our own usual rows never become a candidate');
	ok(!grep({ ($_->{'signature'} // '') eq 'usual' } @{ $vape->{'candidates'} }),
		'a usual row from a previous press is never a candidate');
	my ($vape_stop) = grep { $_->{'signature'} eq 'stop' } @{ $vape->{'candidates'} };
	is($vape_stop->{'count'}, 30, 'the count is the real per-type count, not the twenty-row sample');

	# One rare variant of a common type has the type's count but not the
	# evidence to be a kind of its own: 19 camera-0 recordings and one camera-1
	# recording leave the camera-1 signature off the list.
	my @camera_rows;
	push @camera_rows, { app => 'cameras', type => 'record', timestamp => 4_000_000 - $_ * 1_000,
		data => encode_json({ recorder => 'video', camera => 0, machine => 'phone' }) } for (0 .. 19);
	push @camera_rows, { app => 'cameras', type => 'record', timestamp => 4_000_500,
		data => encode_json({ recorder => 'video', camera => 1, machine => 'phone' }) };
	$candidates{'cameras'} = \@camera_rows;
	my $cameras = &subs::usual_profile('cameras', now => 5_000_000);
	my @camera_signatures = map { $_->{'signature'} } @{ $cameras->{'candidates'} };
	is_deeply(\@camera_signatures, ['record:video:0:phone'],
		'a one-row camera variant of a common type is not a candidate');

	# ------------------------------------------------------------------ summary
	{
		no warnings 'redefine';
		local *subs::ui = sub { return $_[0] };
		is(&subs::usual_summary_line({ duration => 520_000, tasks => [ ({}) x 6 ], candidates => [ { signature => 'stop' } ] }, 'stop'),
			'Stop, about 8m 40s, 6 tasks', 'the stop summary names the length and the task count');
		is(&subs::usual_summary_line({ duration => 520_000, tasks => [ ({}) x 6 ], candidates => [ { signature => 'stop:stock' } ] }, 'stop:stock'),
			'Stop, inventory, about 8m 40s, 6 tasks', 'the stop:stock summary names the inventory move');
		is(&subs::usual_summary_line({ candidates => [ {
				signature => 'transaction:consume:77 Vape:Geek Bar',
				template => { vendor => '77 Vape', item => 'Geek Bar', total => 57, type => 'transaction' },
			} ] }, 'transaction:consume:77 Vape:Geek Bar'),
			'Transaction, 77 Vape, Geek Bar, $57.00', 'the transaction summary names the vendor, item and total');
		is(&subs::usual_summary_line({ candidates => [ { signature => 'image:0:' } ] }, 'image:0:'),
			'Image, back camera', 'the image summary names the camera');
		is(&subs::usual_summary_line({ candidates => [ { signature => 'record:video:front:phone' } ] }, 'record:video:front:phone'),
			'Video, front camera', 'the record summary names the recorder and camera');
	}

	# ------------------------------------------------------------------- replay
	# A dozen task rows are written quiet behind the same per-app lock the task
	# route takes, the checklist is marked at the press, and the JSON is written
	# once with every completion merged.
	my $tmp = tempdir(CLEANUP => 1);
	my @writes;
	my @calls;
	my $list = [
		{ uuid => 'tw', task => 'washing', completed => 'off' },
		{ uuid => 'td', task => 'drying',  completed => 'off' },
	];
	{
		no warnings 'redefine';
		local *subs::home = sub { return $tmp . '/lock' };
		local *subs::setting_grabber = sub { return encode_json($list) if ($_[0]->{'setting'} // '') eq 'tasks'; return undef };
		local *subs::setting_setter = sub { push @writes, { %{ $_[0] } }; return 1 };
		local *subs::task_writer = sub {
			my ($c, $request) = @_;
			push @calls, { %{$request} };
			my @updated = map { { %$_ } } @{$list};
			foreach my $entry ( @updated ) {
				next unless $entry->{'uuid'} eq $request->{'uuid'};
				$entry->{'completed'} = 'on';
				$entry->{'last_completed'} = $request->{'completed_at'};
			}
			return \@updated;
		};
		my $replayed = &subs::usual_task_replay(
			UsualCtx->new, 'shower', 'parent-uuid',
			1_000_000, 600_000,
			[
				{ task => 'washing', uuid => 'tw', fraction => 0.5, colour => '#fff' },
				{ task => 'drying',  uuid => 'td', fraction => 1.25 },
			],
			server_time => 1_700_000_000_000, press_ms => 1_699_999_000_000,
		);
		is(scalar @calls, 2, 'one task row is written per task');
		is($calls[0]{'timestamp'}, 1_300_000, 'a task at half the length lands halfway through');
		is($calls[1]{'timestamp'}, 1_750_000, 'a task past the end lands past the end, not clamped');
		is($calls[0]{'app'}, 'shower', 'the list owner holds the checklist');
		is($calls[0]{'papp'}, 'shower', 'and is the parent the row names');
		is($calls[0]{'completed_at'}, 1_699_999_000_000, 'the checklist is marked at the press');
		is($calls[0]{'parent_uuid'}, 'parent-uuid', 'and each task links to the parent usual row');
		ok($calls[0]{'quiet_child'}, 'each task row is a quiet child');
		is(scalar @writes, 1, 'the tasks JSON is written once');
		my $written = decode_json($writes[0]{'value'});
		my %by_uuid = map { $_->{'uuid'} => $_ } @{$written};
		is($by_uuid{'tw'}{'completed'}, 'on', 'every completion is merged into the one write');
		is($by_uuid{'td'}{'completed'}, 'on', 'including the later task');
		is($by_uuid{'tw'}{'last_completed'}, 1_699_999_000_000, 'and the write carries the press time');
		is_deeply($replayed->{'apps'}, [qw(drying washing)], 'the affected task apps are returned');
	}
}

done_testing();
