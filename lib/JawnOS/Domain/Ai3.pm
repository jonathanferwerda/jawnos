package subs;

# Ai3: extracted from subroutines.pl (package subs). Loaded on
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

our %M;
our $database;
# The line windows the balance chart offers, the span each covers, the size of
# one bar and the ledger granularity that fills it. One table, read by the
# chart, the template and the picker, so a window cannot be offered without an
# arithmetic that knows what it means. The month is not a fixed span: it is as
# long as the month the reading is in (see ai_window_span_ms).
our @BALANCE_WINDOWS = qw(1h 1d 1w 1m);
our %BALANCE_WINDOW_MS = (
	'1h' => 60 * 60 * 1000,
	'1d' => 24 * 60 * 60 * 1000,
	'1w' => 7 * 24 * 60 * 60 * 1000,
);
our %BALANCE_BUCKET_MS = (
	'1h' => 2 * 60 * 1000,
	'1d' => 60 * 60 * 1000,
	'1w' => 24 * 60 * 60 * 1000,
	'1m' => 24 * 60 * 60 * 1000,
);
our %BALANCE_BUCKET_COUNT = ( '1h' => 30, '1d' => 24, '1w' => 7 );
our %BALANCE_GRANULARITY = ( '1h' => '2m', '1d' => 'hour', '1w' => 'day', '1m' => 'day' );
# The role names the AI settings use, and the name the panel shows for each.
# They are app names (Guide, Coding), not ordinary words, so they are not
# translated; an unfamiliar role is tidied up instead of invented.
our %AI_ROLE_LABEL = (
	help_assistant   => 'Guide',
	eval_assistant   => 'Evaluation',
	coding_assistant => 'Coding',
	visual_assistant => 'Visual',
	chatbot_model    => 'Chat',
	music_assistant  => 'Music',
);
# Lines that are normal noise rather than errors. jawn() already suppresses the
# same ones from its own console, and the master prints the shutdown line on
# every restart.
our $error_watch_noise;
our %error_watch_partial;
# ---- the error watch: the Coding agent's ears -------------------------
# The running tree prints its warnings and errors to the pty that the master
# (`./jawn`) reads, and jawn keeps that stream in a bounded, sequenced ring and
# serves it at ~/.president/log. On a master restart the ring is seeded from the
# tail of the supervisor's jawn-stdout.log, so a crash that took the master down
# is still read. This watcher asks the bus for what it has not seen yet (and
# reads ~/manager.log, for the $log lines that never reach the pty) and records each new error signature once in staged_fixes. When a Coding
# model is set, the agent reads the error and stages a proposed fix - whole
# files, not applied yet - for a person to review and apply from the IDE's
# coding chatbox. President runs the tick, so there is exactly one watcher per
# machine.
our %error_watch_state;
our $error_watch_state_loaded;
our $log;
our %m;

# The house at a glance for Configure → Sys: every machine that has published
# itself (does it hold a model, when it was last seen) with its spend today, and
# the day's house total against the shared ceiling. Read-only, straight from the
# synced ledger tables, so every machine shows the same picture.
sub ai_house_report {
	my $now = &subs::rightNow();
	my $day = &ai_house_today();
	my %spend;
	my $brows = eval { &subs::db_query('select machine, sum(tokens) as tokens from ai_budget where day = ? group by machine', $day)->hashes } || [];
	foreach my $b ( @{$brows} ) { $spend{ $b->{'machine'} // '' } = ($b->{'tokens'} || 0) + 0; }
	my $me = &ai_house_me();
	my %seen;
	my @rows;
	my $hrows = eval { &subs::db_select('ai_house')->hashes } || [];
	foreach my $r ( @{$hrows} ) {
		my $m = $r->{'machine'} // '';
		next unless length $m;
		$seen{$m} = 1;
		push @rows, {
			machine   => $m,
			self      => ($m eq $me) ? 1 : 0,
			has_model => ($r->{'has_model'} ? 1 : 0),
			seen      => ($r->{'seen'} || 0) + 0,
			online    => ((($r->{'seen'} || 0) + 0) > ($now - 600000)) ? 1 : 0,
			tokens    => $spend{$m} || 0,
		};
	}
	# this machine itself, even before anything has synced back to it
	if (length $me && !$seen{$me}) {
		push @rows, { machine => $me, self => 1, has_model => &ai_house_have_model(), seen => $now, online => 1, tokens => $spend{$me} || 0 };
		$seen{$me} = 1;
	}
	# spend from a machine whose ai_house row is gone (stale, but it did spend)
	foreach my $m ( keys %spend ) {
		next if $seen{$m} || !length $m;
		push @rows, { machine => $m, self => 0, has_model => 0, seen => 0, online => 0, tokens => $spend{$m} };
	}
	@rows = sort {
		($b->{'online'} <=> $a->{'online'})
			|| (($b->{'tokens'} || 0) <=> ($a->{'tokens'} || 0))
			|| ($a->{'machine'} cmp $b->{'machine'})
	} @rows;
	my $budget = &subs::setting_grabber({ app => 'mail', setting => 'error_watch_budget' });
	$budget = (defined $budget && $budget =~ /^\d+$/) ? ($budget + 0) : 1000000;
	return {
		day     => $day,
		rows    => \@rows,
		spent   => &ai_house_budget_spent(),
		budget  => $budget,
		members => scalar( grep { $_->{'has_model'} && $_->{'online'} } @rows ),
		machine => $me,
	};
}

# The money left on each provider account, where the provider will say. There is
# no common balance API: OpenRouter publishes its credits and DeepSeek its account
# balance, and the rest (OpenAI, Anthropic, Google, xAI, Mistral, Groq,
# Cloudflare) have none, so they read "—". Only providers with an account on file
# are listed at all. The read itself is done off the page
# by President.pl's ai balance loop; this only ever reads the cached result, so a
# page load never waits on a provider.
sub ai_balance_report {
	my $cache = &subs::cache_get({ app => '__president', context => 'ai_balance' });
	return (ref $cache eq 'HASH' && $cache->{'rows'}) ? $cache : { at => 0, rows => [] };
}

sub ai_balance_refresh {
	my @key_settings = &subs::ai_key_settings();
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ @key_settings ] });
	my $suds = &subs::suds_grabber();
	my $secret = sub {
		my $v = shift;
		return '' unless defined $v && length $v;
		my $d = eval { &subs::note_decrypter($suds, $v) };
		return ($d && length $d) ? $d : $v;
	};
	# short timeouts: a balance read must never become a stall, and it is only a
	# convenience on a settings page
	my $ua = Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 8, request_timeout => 12);
	my %money;
	# OpenRouter: granted credits less what has been used
	{
		my $key = $secret->($settings->{'openrouter_key'});
		my $row = { available => undef, currency => 'USD', note => 'no key' };
		if (length $key) {
			my $tx = eval { $ua->get('https://openrouter.ai/api/v1/credits' => { 'Authorization' => "Bearer $key" }) };
			my $d = ($tx && !$tx->error && $tx->res->is_success) ? eval { decode_json($tx->res->body) } : undef;
			if ($d && ref $d->{'data'} eq 'HASH' && defined $d->{'data'}->{'total_credits'}) {
				$row = { available => (($d->{'data'}->{'total_credits'} || 0) - ($d->{'data'}->{'total_usage'} || 0)), currency => 'USD' };
			}
			else { $row = { available => undef, currency => 'USD', note => 'could not read credits' }; }
		}
		$money{'openrouter'} = $row;
	}
	# DeepSeek: the account balance
	{
		my $key = $secret->($settings->{'deepseek_key'});
		my $row = { available => undef, currency => 'USD', note => 'no key' };
		if (length $key) {
			my $tx = eval { $ua->get('https://api.deepseek.com/user/balance' => { 'Authorization' => "Bearer $key" }) };
			my $d = ($tx && !$tx->error && $tx->res->is_success) ? eval { decode_json($tx->res->body) } : undef;
			my $info = ($d && ref $d->{'balance_infos'} eq 'ARRAY') ? $d->{'balance_infos'}->[0] : undef;
			if ($info && defined $info->{'total_balance'}) {
				$row = { available => ($info->{'total_balance'} + 0), currency => ($info->{'currency'} || 'USD') };
			}
			else { $row = { available => undef, currency => 'USD', note => 'could not read balance' }; }
		}
		$money{'deepseek'} = $row;
	}
	# every registered provider, in the panel's own order, with a balance where
	# there is one; a provider with no account on file is not a row at all
	my @rows;
	foreach my $p ( @{ &subs::ai_providers() } ) {
		next unless &subs::ai_provider_registered($p, $settings);
		my $m = $money{ $p->{'id'} };
		push @rows, {
			provider  => $p->{'id'},
			label     => $p->{'label'},
			available => $m ? $m->{'available'} : undef,
			currency  => $m ? $m->{'currency'} : undef,
			note      => $m ? $m->{'note'} : 'no balance API',
		};
	}
	# Keep a rolling month of what each account held, thinned as it ages: every
	# ten-minute reading for the last day (that is the Last Hour and Last Day
	# bars' money), one per hour out to the week, and one per three hours out to
	# the month. A month at full resolution would be ten thousand points per
	# provider in one cache row; this is about six hundred. A failed read is
	# skipped rather than recorded as zero, and a provider that leaves the
	# settings loses its line. The warranty outlives the window so the hair
	# cutter does not take the row (and the month) out from under it.
	my $now = &subs::rightNow();
	my $previous = &subs::cache_get({ app => '__president', context => 'ai_balance' });
	my $history = (ref $previous eq 'HASH' && ref $previous->{'history'} eq 'HASH') ? $previous->{'history'} : {};
	my $floor = $now - 35 * 24 * 60 * 60 * 1000;
	my $day_ago = $now - 24 * 60 * 60 * 1000;
	my $week_ago = $now - 7 * 24 * 60 * 60 * 1000;
	my %listed = map { ($_->{'provider'} || '') => 1 } @rows;
	foreach my $provider ( keys %{$history} ) {
		delete $history->{$provider} unless $listed{$provider};
	}
	foreach my $row ( @rows ) {
		my $series = $history->{ $row->{'provider'} };
		$series = $history->{ $row->{'provider'} } = [] unless ref $series eq 'ARRAY';
		@{$series} = grep { ref $_ eq 'HASH' && defined $_->{'t'} && ($_->{'t'} || 0) >= $floor } @{$series};
		# thin the older points to one an hour, then one per three hours
		my (%slot, @kept);
		foreach my $point ( sort { $a->{'t'} <=> $b->{'t'} } @{$series} ) {
			my $t = $point->{'t'} || 0;
			if ($t >= $day_ago) { push @kept, $point; next; }
			my $key = ($t >= $week_ago) ? 'h' . int($t / 3600000) : 't' . int($t / 10800000);
			next if $slot{$key}++;
			push @kept, $point;
		}
		@{$series} = @kept;
		next unless defined $row->{'available'} && $row->{'available'} =~ /^-?\d+(?:\.\d+)?$/;
		my $last = $series->[-1];
		if ($last && $now - ($last->{'t'} || 0) < 300000) {
			# a manual or second read inside the job's own interval replaces the
			# point instead of drawing a second one at the same minute
			$last->{'v'} = $row->{'available'} + 0;
			$last->{'c'} = $row->{'currency'} || $last->{'c'};
		}
		else {
			push @{$series}, { t => $now, v => $row->{'available'} + 0, c => ($row->{'currency'} || '') };
		}
	}
	my $report = { at => $now, rows => \@rows, history => $history };
	&subs::cache_set({ app => '__president', context => 'ai_balance', warranty => '-40d' }, $report);
	return $report;
}

# One point of the balance history, at a known time. Pure so a test can pin
# both the series and the clock. The drawn points carry a synthetic point at
# the window's left edge, interpolated from the last sample before it, so a
# 24h line starts where the window does instead of at its first sample.
# `change` is positive when the balance fell; `per_day` is the pace in money.
# How far back a window reaches. A calendar month is as many days as the month
# the reading falls in (November has thirty, December thirty-one), which is what
# the panel's Last Month button promises.
sub ai_window_span_ms {
	my ($window, $now) = @_;
	$window = '1d' unless defined $window && $BALANCE_BUCKET_MS{$window};
	return $BALANCE_WINDOW_MS{$window} if $BALANCE_WINDOW_MS{$window};
	$now = &subs::rightNow() unless defined $now;
	my $t = localtime(int($now / 1000));
	return 30 * 24 * 60 * 60 * 1000 unless ref $t;
	my $days = &days_in_month($t->year, $t->mon);
	$days = 30 unless $days >= 28 && $days <= 31;
	return $days * 24 * 60 * 60 * 1000;
}

# How many bars a window draws: thirty two-minute bars for the hour, twenty-four
# hours for the day, seven days for the week, and the month's own day count.
sub ai_window_bucket_count {
	my ($window, $now) = @_;
	$window = '1d' unless defined $window && $BALANCE_BUCKET_MS{$window};
	return $BALANCE_BUCKET_COUNT{$window} if $BALANCE_BUCKET_COUNT{$window};
	$now = &subs::rightNow() unless defined $now;
	my $t = localtime(int($now / 1000));
	return 30 unless ref $t;
	my $days = &days_in_month($t->year, $t->mon);
	return ($days >= 28 && $days <= 31) ? $days : 30;
}

sub ai_balance_window {
	my ($points, $window, $now) = @_;
	$window = '1d' unless defined $window && $BALANCE_BUCKET_MS{$window};
	$now = &subs::rightNow() unless defined $now;
	my $span = &ai_window_span_ms($window, $now);
	# Start where the bars start, not at this instant minus the span: the two
	# drawings then cover exactly the same period and their totals agree.
	my $edges = &ai_balance_edges($window, $now);
	my $start = @{$edges} ? $edges->[0]->{'start'} : $now - $span;
	my @all = sort { $a->{'t'} <=> $b->{'t'} }
		grep { ref $_ eq 'HASH' && defined $_->{'t'} && defined $_->{'v'} && $_->{'t'} <= $now }
		@{ ref $points eq 'ARRAY' ? $points : [] };
	my @in = grep { $_->{'t'} >= $start } @all;
	my $window_data = { window => $window, span => $span, start => $start, now => $now, points => [] };
	return $window_data unless @in;
	my ($anchor) = reverse grep { $_->{'t'} < $start } @all;
	my @draw = @in;
	if ($anchor && $in[0]->{'t'} > $start) {
		my $dt = $in[0]->{'t'} - $anchor->{'t'};
		my $v = $anchor->{'v'};
		$v += ($in[0]->{'v'} - $anchor->{'v'}) * (($start - $anchor->{'t'}) / $dt) if $dt > 0;
		unshift @draw, { t => $start, v => $v };
	}
	my $first = $draw[0];
	my $last = $draw[-1];
	my $hours = ($last->{'t'} - $first->{'t'}) / 3600000;
	my $change = $first->{'v'} - $last->{'v'};
	# Consumption is the sum of the falls between consecutive samples, with
	# every rise clamped to zero. A top-up is a rise: it is money put in, not a
	# negative burn, so it must not read as "rise" and must not cancel the
	# spending either side of it. Keeping the elapsed hours across the whole
	# window means a window with a top-up reports the same drop rate as the
	# same window without one. The epsilon absorbs a provider's rounding - a
	# balance re-read a millionth of a unit lower is not a spend.
	my $epsilon = 0.000001;
	my $consumption = 0;
	for my $i ( 1 .. $#draw ) {
		my $fall = $draw[$i - 1]->{'v'} - $draw[$i]->{'v'};
		$consumption += $fall if $fall > $epsilon;
	}
	# A top-up is money put in, not a fall, and it is worth naming wherever it
	# happened in the window: a balance that jumps and then falls again reads as
	# an accident otherwise. The newest few are enough.
	my @topups;
	my $label_format = ($window eq '1w' || $window eq '1m') ? '%Y-%m-%d %H:%M' : '%H:%M';
	for my $i ( 1 .. $#draw ) {
		my $rise = $draw[$i]->{'v'} - $draw[$i - 1]->{'v'};
		next unless $rise > $epsilon;
		my $t = localtime($draw[$i]->{'t'} / 1000);
		push @topups, { t => $draw[$i]->{'t'}, amount => $rise, label => (ref $t ? $t->strftime($label_format) : '') };
	}
	@topups = reverse @topups;
	splice(@topups, 4) if @topups > 4;
	$window_data->{'topups'} = \@topups;
	my $per_hour = $hours > 0 ? $consumption / $hours : undef;
	my $per_day = defined $per_hour ? $per_hour * 24 : undef;
	$window_data->{'points'} = \@draw;
	$window_data->{'first'} = $first;
	$window_data->{'last'} = $last;
	$window_data->{'hours'} = $hours;
	$window_data->{'change'} = $change;
	$window_data->{'consumption'} = $consumption;
	$window_data->{'per_hour'} = $per_hour;
	$window_data->{'per_day'} = $per_day;
	# Runway: what is left now over what is burning. Undefined when nothing is
	# falling - a balance that holds steady never runs out - and absent for a
	# balance already spent, because there is no time left to report.
	my $balance = $last->{'v'};
	my $runway_hours = (defined $per_hour && $per_hour > 0 && $balance > 0) ? $balance / $per_hour : undef;
	$window_data->{'balance'} = $balance;
	$window_data->{'runway_hours'} = $runway_hours;
	$window_data->{'runway_days'} = defined $runway_hours ? $runway_hours / 24 : undef;
	# What that burn costs over the usual spans, in the chart's own currency.
	$window_data->{'expense_day'} = $per_day;
	$window_data->{'expense_week'} = defined $per_day ? $per_day * 7 : undef;
	$window_data->{'expense_month'} = defined $per_day ? $per_day * 30 : undef;
	return $window_data;
}

# The midnight that starts the local day a reading falls in, in epoch ms. The
# date is read from the local clock and the midnight rebuilt from it, so a
# daylight-saving change since midnight cannot shift the answer by an hour.
sub ai_local_midnight_ms {
	my ($ms) = @_;
	$ms = &subs::rightNow() unless defined $ms && $ms =~ /^-?\d+$/;
	my $t = localtime(int($ms / 1000));
	return int($ms) unless ref $t;
	my $epoch = POSIX::mktime(0, 0, 0, $t->mday, $t->mon - 1, $t->year - 1900);
	return (defined $epoch && $epoch >= 0) ? $epoch * 1000 : int($ms);
}

# Where each bar of a window starts and ends, in this machine's own clock. A
# bar is one whole unit of the clock - two minutes, an hour, a day - so its
# label reads on the clock and the ledger's minute keys line up with it. Days
# are taken from local midnights rather than by subtracting 86 400 000ms, so a
# clock change cannot slide them by an hour.
sub ai_balance_edges {
	my ($window, $now) = @_;
	$window = '1d' unless defined $window && $BALANCE_BUCKET_MS{$window};
	$now = &subs::rightNow() unless defined $now;
	my $bucket = $BALANCE_BUCKET_MS{$window};
	my $count = &ai_window_bucket_count($window, $now);
	my $granularity = $BALANCE_GRANULARITY{$window};
	my $t = localtime(int($now / 1000));
	return [] unless ref $t;
	my @edges;
	if ($granularity eq 'day') {
		# Walk the calendar back one date at a time: mktime normalises an
		# out-of-range day, so a clock change inside the span cannot skip or
		# repeat a midnight the way subtracting 86 400 000ms would. Build the
		# midnights first and make each bar end where the next begins.
		my @starts;
		for my $i ( 0 .. $count - 1 ) {
			my $epoch = POSIX::mktime(0, 0, 0, $t->mday - ($count - 1 - $i), $t->mon - 1, $t->year - 1900);
			push @starts, (defined $epoch && $epoch >= 0) ? $epoch * 1000 : &ai_local_midnight_ms($now);
		}
		push @starts, &ai_local_midnight_ms($starts[-1] + 36 * 3600000);
		for my $i ( 0 .. $count - 1 ) {
			my $lt = localtime($starts[$i] / 1000);
			my $key = $lt->strftime('%Y-%m-%d');
			push @edges, { start => $starts[$i], end => $starts[ $i + 1 ], key => $key, label => $key };
		}
		return \@edges;
	}
	# two minutes and an hour sit on whole clock units, so the local minute
	# (or the hour top) is where the last bar starts
	my $base = $granularity eq '2m'
		? $t->epoch - (($t->min % 2) * 60 + $t->sec)
		: $t->epoch - ($t->min * 60 + $t->sec);
	$base *= 1000;
	for my $i ( 0 .. $count - 1 ) {
		my $start = $base - ($count - 1 - $i) * $bucket;
		my $lt = localtime($start / 1000);
		push @edges, {
			start => $start,
			end   => $start + $bucket,
			key   => ($granularity eq '2m' ? $lt->strftime('%Y-%m-%d %H:%M') : $lt->strftime('%Y-%m-%d %H')),
			label => ($granularity eq '2m' ? $lt->strftime('%H:%M') : $lt->strftime('%H:00')),
		};
	}
	return \@edges;
}

# The bars for one window: what each clock unit spent and what traffic used it.
# Money is only the falls, exactly as in ai_balance_window, but here a fall
# between two readings is spread across the bars it covers in proportion to
# time, so the chart reads the same way at any resolution instead of dropping a
# whole ten-minute fall into whichever bar happened to hold its second reading.
# The tokens are the ledger's own count for the same clock unit. `$ledger_since`
# is when the ledger starts (epoch ms); a bar before it is untracked rather than
# a genuine zero.
sub ai_balance_buckets {
	my ($points, $window, $now, $spend, $ledger_since) = @_;
	$window = '1d' unless defined $window && $BALANCE_BUCKET_MS{$window};
	$now = &subs::rightNow() unless defined $now;
	my $edges = &ai_balance_edges($window, $now);
	my @buckets = map {
		{
			start => $_->{'start'}, end => $_->{'end'}, key => $_->{'key'}, label => $_->{'label'},
			spend => 0, tokens => 0, calls => 0, models => {}, share => 0,
			tracked => 0, top_model => '', models_text => '',
		}
	} @{$edges};
	my $first = @buckets ? $buckets[0]{'start'} : 0;
	my @all = sort { $a->{'t'} <=> $b->{'t'} }
		grep { ref $_ eq 'HASH' && defined $_->{'t'} && defined $_->{'v'} && $_->{'t'} <= $now }
		@{ ref $points eq 'ARRAY' ? $points : [] };
	my @in = grep { $_->{'t'} >= $first } @all;
	my @draw = @in;
	if (@in) {
		my ($anchor) = reverse grep { $_->{'t'} < $first } @all;
		if ($anchor && $in[0]->{'t'} > $first) {
			my $dt = $in[0]->{'t'} - $anchor->{'t'};
			my $v = $anchor->{'v'};
			$v += ($in[0]->{'v'} - $anchor->{'v'}) * (($first - $anchor->{'t'}) / $dt) if $dt > 0;
			unshift @draw, { t => $first, v => $v };
		}
	}
	my $epsilon = 0.000001;
	for my $i ( 1 .. $#draw ) {
		my $fall = $draw[ $i - 1 ]{'v'} - $draw[$i]{'v'};
		next unless $fall > $epsilon;
		my ($t0, $t1) = ($draw[ $i - 1 ]{'t'}, $draw[$i]{'t'});
		next unless $t1 > $t0;
		my $span = $t1 - $t0;
		foreach my $bucket ( @buckets ) {
			my $lo = $t0 > $bucket->{'start'} ? $t0 : $bucket->{'start'};
			my $hi = $t1 < $bucket->{'end'} ? $t1 : $bucket->{'end'};
			next unless $hi > $lo;
			$bucket->{'spend'} += $fall * (($hi - $lo) / $span);
		}
	}
	my $tokens = 0;
	my %attached;
	foreach my $bucket ( @buckets ) {
		$bucket->{'tracked'} = (defined $ledger_since && $ledger_since =~ /^\d+$/ && $bucket->{'end'} > $ledger_since) ? 1 : 0;
		next unless ref $spend eq 'HASH';
		# A clock change repeats a wall-clock hour (01:00 runs twice on a
		# fall-back night); the ledger keys on that wall clock, so only the
		# first bar of the pair banks the hour rather than counting it twice.
		next if $attached{ $bucket->{'key'} }++;
		my $slot = $spend->{ $bucket->{'key'} };
		next unless ref $slot eq 'HASH';
		$bucket->{'tokens'} = $slot->{'tokens'} || 0;
		$bucket->{'calls'}  = $slot->{'calls'}  || 0;
		$bucket->{'models'} = $slot->{'models'} || {};
		$tokens += $bucket->{'tokens'};
	}
	foreach my $bucket ( @buckets ) {
		my @names = sort { $bucket->{'models'}->{$b} <=> $bucket->{'models'}->{$a} } grep { length $_ } keys %{ $bucket->{'models'} };
		$bucket->{'top_model'} = @names ? $names[0] : '';
		$bucket->{'models_text'} = (@names > 1)
			? join(' · ', map { $_ . ' ' . $bucket->{'models'}->{$_} } @names[ 0 .. ($#names > 2 ? 2 : $#names) ])
			: '';
	}
	my ($total, $max, $peak) = (0, 0, undef);
	$total += $_->{'spend'} for @buckets;
	foreach my $bucket ( @buckets ) {
		$bucket->{'share'} = $total > 0 ? ($bucket->{'spend'} / $total) * 100 : 0;
		if ($bucket->{'spend'} > $max) { $max = $bucket->{'spend'}; $peak = $bucket; }
	}
	return {
		window => $window,
		bucket_ms => $BALANCE_BUCKET_MS{$window},
		granularity => $BALANCE_GRANULARITY{$window},
		count => scalar @buckets,
		start => $first,
		end => (@buckets ? $buckets[-1]{'end'} : 0),
		now => $now,
		buckets => \@buckets,
		samples => scalar @in,
		total => $total,
		max => $max,
		peak => $peak,
		tokens => $tokens,
		ledger_since => $ledger_since,
	};
}

# One bar per bucket, relative to the busiest, on the panel's accent. Heights
# are shares of `max` rather than money, so a currency change never redraws the
# drawing; the amount is built into the line under it, where the picker's rate
# applies. Each bar carries what its line needs, and a transparent full-height
# column over it takes the click - a day bar is a few pixels wide on a phone,
# and a bucket that spent nothing still has tokens worth reading.
sub ai_balance_bars {
	my ($bars, $width, $height, $templates) = @_;
	$width ||= 320;
	$height ||= 48;
	my $buckets = (ref $bars eq 'HASH' && ref $bars->{'buckets'} eq 'ARRAY') ? $bars->{'buckets'} : [];
	my $count = scalar @{$buckets};
	return '' unless $count;
	my $max = (ref $bars eq 'HASH') ? ($bars->{'max'} || 0) : 0;
	my $peak = (ref $bars eq 'HASH' && ref $bars->{'peak'} eq 'HASH') ? $bars->{'peak'} : undef;
	my $top = 3;
	my $bottom = $height - 1;
	my $plot = $width / $count;
	my $gap = $plot > 6 ? 1.5 : 0.5;
	my (@rects, @hits);
	for my $i ( 0 .. $count - 1 ) {
		my $bucket = $buckets->[$i];
		my $spend = $bucket->{'spend'} || 0;
		my $h = ($max > 0 && $spend > 0) ? ($spend / $max) * ($bottom - $top) : 0;
		$h = 0.8 if $spend > 0 && $h < 0.8;
		my $x = $i * $plot + $gap / 2;
		my $w = $plot - $gap;
		my $y = $bottom - $h;
		my $key = xml_escape($bucket->{'key'} // '');
		my $class = ($peak && $peak eq $bucket) ? ' class="peak"' : '';
		push @rects, sprintf(
			'<rect%s data-bk="%s" data-label="%s" data-amt="%.6f" data-share="%.1f%%" data-tokens="%d" data-calls="%d" data-model="%s" data-models="%s" data-tracked="%d" x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f"/>',
			$class, $key, xml_escape($bucket->{'label'} // ''), $spend, ($bucket->{'share'} || 0),
			($bucket->{'tokens'} || 0), ($bucket->{'calls'} || 0),
			xml_escape($bucket->{'top_model'} // ''), xml_escape($bucket->{'models_text'} // ''), ($bucket->{'tracked'} ? 1 : 0),
			$x, $y, $w, $h, ($w < 3 ? 0 : 1)
		);
		push @hits, sprintf('<rect class="hit" data-bk="%s" x="%.2f" y="0" width="%.2f" height="%d" fill="transparent"/>', $key, $x, $w, $height);
	}
	my $attrs = '';
	if (ref $templates eq 'HASH') {
		my @map = (
			[ 'detail',    'data-detail-template' ],
			[ 'untracked', 'data-untracked-template' ],
			[ 'model',     'data-model-template' ],
			[ 'models',    'data-models-template' ],
		);
		foreach my $pair ( @map ) {
			next unless defined $templates->{ $pair->[0] };
			$attrs .= ' ' . $pair->[1] . '="' . xml_escape($templates->{ $pair->[0] }) . '"';
		}
	}
	my $base = sprintf('<line x1="0" y1="%.1f" x2="%d" y2="%.1f" stroke="currentColor" stroke-opacity="0.18" stroke-width="1" vector-effect="non-scaling-stroke"/>', $bottom, $width, $bottom);
	return '<svg class="balance_bars"' . $attrs . ' viewBox="0 0 ' . $width . ' ' . $height . '" preserveAspectRatio="none" aria-hidden="true">'
		. $base . join('', @rects, @hits) . '</svg>';
}

# A line for one provider over one window. currentColor means it follows the
# theme, and a flat balance gets a little headroom so it does not sit on the
# floor. Only the caller's numbers reach the markup.
sub ai_balance_sparkline {
	my ($points, $start, $now, $width, $height) = @_;
	$width ||= 320;
	$height ||= 80;
	my @p = grep { ref $_ eq 'HASH' && defined $_->{'t'} && defined $_->{'v'} } @{ ref $points eq 'ARRAY' ? $points : [] };
	return '' unless @p;
	my $span = ($now // 0) - ($start // 0);
	$span = 1 if $span <= 0;
	my ($min, $max) = ($p[0]->{'v'}, $p[0]->{'v'});
	foreach my $pt ( @p ) {
		$min = $pt->{'v'} if $pt->{'v'} < $min;
		$max = $pt->{'v'} if $pt->{'v'} > $max;
	}
	my $pad = ($max - $min) * 0.12;
	$pad = 0.01 unless $pad > 0;
	$min -= $pad;
	$max += $pad;
	my $top = 6;
	my $bottom = $height - 6;
	my $range = $max - $min;
	$range = 1 unless $range > 0;
	# A few pixels of inset keep the end dot and its stroke off the edge.
	my $inset = 3;
	my $plot = $width - 2 * $inset;
	my @xy;
	foreach my $pt ( @p ) {
		my $x = $inset + (($pt->{'t'} - $start) / $span) * $plot;
		$x = $inset if $x < $inset;
		$x = $width - $inset if $x > $width - $inset;
		my $y = $bottom - (($pt->{'v'} - $min) / $range) * ($bottom - $top);
		push @xy, sprintf('%.1f,%.1f', $x, $y);
	}
	my ($fx) = split /,/, $xy[0];
	my ($lx, $ly) = split /,/, $xy[-1];
	my $area = 'M ' . join(' L ', @xy) . sprintf(' L %s,%.1f L %s,%.1f Z', $lx, $bottom, $fx, $bottom);
	my $grid = '';
	foreach my $f ( 0.25, 0.5, 0.75 ) {
		my $y = $top + ($bottom - $top) * $f;
		$grid .= sprintf('<line x1="0" y1="%.1f" x2="%d" y2="%.1f" stroke="currentColor" stroke-opacity="0.10" stroke-width="1" vector-effect="non-scaling-stroke"/>', $y, $width, $y);
	}
	return '<svg class="balance_spark" viewBox="0 0 ' . $width . ' ' . $height . '" preserveAspectRatio="none" aria-hidden="true">'
		. $grid
		. '<path d="' . $area . '" fill="currentColor" fill-opacity="0.12" stroke="none"/>'
		. '<polyline points="' . join(' ', @xy) . '" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/>'
		. '<circle cx="' . $lx . '" cy="' . $ly . '" r="2.2" fill="currentColor"/>'
		. '</svg>';
}

# The Sys panel's chart, assembled from the cached read. No provider call and no
# database write happen here: the route has already loaded the same report, and
# the only read is the spend ledger that puts tokens beside an hour's fall. The
# balances and the pace are shown in the house's reporting currency, converted
# at the rate snapshot the rest of the app uses; a provider whose rate is not
# loaded keeps its own currency rather than a wrong number.
sub ai_balance_chart {
	my ($report, $now) = @_;
	$report = &ai_balance_report() unless ref $report eq 'HASH';
	$now = &subs::rightNow() unless defined $now;
	my $history = (ref $report->{'history'} eq 'HASH') ? $report->{'history'} : {};
	my $base = &crypto_report_currency();
	# The spend ledger, read once per window for every provider at once. Its keys
	# are the same local clock units the bars use, and the earliest row is what
	# tells a bar before the ledger began apart from a bar that spent nothing. A
	# provider nobody has called yet is simply absent.
	my $ledger_since = &ai_spend_since();
	my (%spend_by_window, %roles_by_window);
	foreach my $window ( @BALANCE_WINDOWS ) {
		my $edges = &ai_balance_edges($window, $now);
		my $since_key = @{$edges} ? $edges->[0]->{'key'} : '';
		$spend_by_window{$window} = &ai_spend_buckets($BALANCE_GRANULARITY{$window}, $since_key);
		$roles_by_window{$window} = &ai_spend_roles($since_key);
	}
	# Everything the house spent in tokens, whichever account served it. A
	# balance can fall with no token count beside it - the traffic went to a
	# local or a peer's model, or came from a machine that has not recorded it
	# yet - and this is what tells a person the tokens were spent somewhere.
	my %house_tokens;
	foreach my $window ( @BALANCE_WINDOWS ) {
		my $sum = 0;
		foreach my $provider ( keys %{ $spend_by_window{$window} || {} } ) {
			foreach my $slot ( values %{ $spend_by_window{$window}->{$provider} } ) {
				$sum += $slot->{'tokens'} || 0;
			}
		}
		$house_tokens{$window} = $sum;
	}
	my $zone = localtime();
	my $tz = ref $zone ? $zone->strftime('%Z') : '';
	my (@series, @unconverted);
	my (%seen_unconverted, $converted_any);
	foreach my $row ( @{ $report->{'rows'} || [] } ) {
		my $provider = $row->{'provider'} || '';
		my $points = $history->{$provider};
		next unless ref $points eq 'ARRAY' && @{$points};
		my $last = $points->[-1];
		my $from = uc($row->{'currency'} || $last->{'c'} || 'USD');
		my $rate = ($from eq $base) ? 1 : &exchange_rate($from, $base);
		my $converted = ($from ne $base && defined $rate && $rate > 0) ? 1 : 0;
		my @scaled;
		if ($from eq $base) {
			@scaled = @{$points};
		}
		elsif ($converted) {
			@scaled = map { { t => $_->{'t'}, v => $_->{'v'} * $rate, c => $base } } @{$points};
			$converted_any = 1;
		}
		else {
			@scaled = @{$points};
			push @unconverted, $from unless $seen_unconverted{$from}++;
		}
		my %windows;
		foreach my $window ( @BALANCE_WINDOWS ) {
			my $line = &ai_balance_window(\@scaled, $window, $now);
			my $bars = &ai_balance_buckets(\@scaled, $window, $now, $spend_by_window{$window}->{$provider} || {}, $ledger_since);
			my $role_tokens = $roles_by_window{$window}->{$provider} || {};
			my $role_total = 0;
			$role_total += $_ for values %{$role_tokens};
			my @roles;
			if ($role_total > 0) {
				foreach my $role ( sort { $role_tokens->{$b} <=> $role_tokens->{$a} } keys %{$role_tokens} ) {
					push @roles, {
						role   => $role,
						label  => &ai_balance_role_label($role),
						tokens => $role_tokens->{$role},
						share  => ($role_tokens->{$role} / $role_total) * 100,
					};
				}
			}
			# The price per thousand tokens only means something when the ledger
			# covers the whole window: a fall it did not see divided by the tokens
			# it did would read as an inflated price.
			my $per_k = ($bars->{'tokens'} > 0 && @{ $bars->{'buckets'} } && $bars->{'buckets'}->[0]{'tracked'})
				? ($bars->{'total'} / $bars->{'tokens'}) * 1000
				: undef;
			$windows{$window} = { line => $line, bars => $bars, roles => \@roles, per_k => $per_k, house_tokens => $house_tokens{$window} };
		}
		push @series, {
			provider        => $provider,
			label           => ($row->{'label'} || $provider),
			currency        => ($converted ? $base : $from),
			source_currency => $from,
			source_available => $row->{'available'},
			converted       => $converted,
			rate            => ($converted ? $rate : undef),
			available       => ((defined $row->{'available'} && $converted) ? $row->{'available'} * $rate : $row->{'available'}),
			windows         => \%windows,
		};
	}
	# Each window's provider comparison: the pace of every account, so one glance
	# compares them without laying two different balances on one axis.
	foreach my $window ( @BALANCE_WINDOWS ) {
		my @compare;
		foreach my $series ( @series ) {
			push @compare, {
				provider => $series->{'provider'},
				label    => $series->{'label'},
				currency => $series->{'currency'},
				per_day  => $series->{'windows'}->{$window}->{'line'}->{'per_day'},
			};
		}
		foreach my $series ( @series ) {
			$series->{'windows'}->{$window}->{'compare'} = \@compare;
		}
	}
	return {
		at          => ($report->{'at'} || 0),
		base        => $base,
		tz          => $tz,
		converted   => ($converted_any ? 1 : 0),
		unconverted => \@unconverted,
		windows     => [ @BALANCE_WINDOWS ],
		series      => \@series,
	};
}

# The name the panel shows for an AI role: the app the role belongs to where
# the name is known, and a tidied-up role name otherwise. An empty role is a
# call that did not say who asked (a direct ai_chat_parts), kept visible rather
# than folded into another role.
sub ai_balance_role_label {
	my ($role) = @_;
	$role = '' unless defined $role;
	return &subs::lang('configure.role_other') unless length $role;
	return $AI_ROLE_LABEL{$role} if $AI_ROLE_LABEL{$role};
	my $clean = $role;
	$clean =~ s/_assistant$//;
	$clean =~ s/_model$//;
	$clean =~ s/_/ /g;
	return ucfirst $clean;
}

# The two thresholds a person sets under the chart. A blank or unreadable box
# is off, never a zero that would fire on every hour.
sub ai_alert_settings {
	my $hour = &subs::setting_grabber({ app => '__president', setting => 'ai_alert_hour' });
	my $runway = &subs::setting_grabber({ app => '__president', setting => 'ai_alert_runway' });
	$hour = (defined $hour && $hour =~ /^\d+(?:\.\d+)?$/ && $hour > 0) ? ($hour + 0) : undef;
	$runway = (defined $runway && $runway =~ /^\d+(?:\.\d+)?$/ && $runway > 0) ? ($runway + 0) : undef;
	return { hour => $hour, runway => $runway };
}

# What the thresholds would fire on right now, in the chart's own currency. The
# hour is the last complete clock hour of the Last Day window - the bar in
# progress is not judged, since a partial hour can only under-report - and the
# runway is that same window's projection.
sub ai_alert_check {
	my ($report, $now) = @_;
	$report = &ai_balance_report() unless ref $report eq 'HASH';
	$now = &subs::rightNow() unless defined $now;
	my $settings = &ai_alert_settings();
	my @fired;
	return { settings => $settings, fired => \@fired }
		unless defined $settings->{'hour'} || defined $settings->{'runway'};
	my $chart = &ai_balance_chart($report, $now);
	foreach my $series ( @{ $chart->{'series'} } ) {
		my $day = $series->{'windows'}->{'1d'} || {};
		my $buckets = (ref $day->{'bars'} eq 'HASH' && ref $day->{'bars'}->{'buckets'} eq 'ARRAY') ? $day->{'bars'}->{'buckets'} : [];
		my $complete = @{$buckets} >= 2 ? $buckets->[-2] : undef;
		if (defined $settings->{'hour'} && $complete && ($complete->{'spend'} || 0) > $settings->{'hour'}) {
			push @fired, {
				kind => 'hour', provider => $series->{'provider'}, label => $series->{'label'},
				currency => $series->{'currency'}, amount => $complete->{'spend'},
				limit => $settings->{'hour'}, period => $complete->{'key'},
			};
		}
		my $runway_days = $day->{'line'}->{'runway_days'};
		if (defined $settings->{'runway'} && defined $runway_days && $runway_days > 0 && $runway_days < $settings->{'runway'}) {
			my $t = localtime(int($now / 1000));
			push @fired, {
				kind => 'runway', provider => $series->{'provider'}, label => $series->{'label'},
				currency => $series->{'currency'}, days => $runway_days,
				limit => $settings->{'runway'}, period => (ref $t ? $t->strftime('%Y-%m-%d') : ''),
			};
		}
	}
	return { settings => $settings, fired => \@fired, base => $chart->{'base'} };
}

# The watch: one Handbook note per crossing, keyed by the provider and the
# period, so a standing condition does not write a note on every turn; the
# ledger is trimmed on the same turn, since it grows a row per model call.
sub ai_alert_tick {
	my ($report, $now) = @_;
	$now = &subs::rightNow() unless defined $now;
	my $check = &ai_alert_check($report, $now);
	my @written;
	# The conditions standing at the last turn. An hour that crosses is a new
	# event each hour (its key carries the hour), while a runway crosses once
	# and stays quiet until it clears - so a recovery and a later re-crossing
	# are two events, not one.
	my $state = &subs::cache_get({ app => '__president', context => 'ai_alert', subcontext => 'state' });
	my %standing = (ref $state eq 'HASH' && ref $state->{'keys'} eq 'ARRAY') ? map { $_ => 1 } @{ $state->{'keys'} } : ();
	my %current;
	foreach my $alert ( @{ $check->{'fired'} } ) {
		my $key = $alert->{'kind'} . '|' . $alert->{'provider'};
		$key .= '|' . $alert->{'period'} if $alert->{'kind'} eq 'hour';
		$current{$key} = 1;
		next if $standing{$key};
		my $money = sub { &subs::currency_money($_[0]) . ' ' . ($alert->{'currency'} || '') };
		my $text = $alert->{'kind'} eq 'hour'
			? &subs::ui(sprintf('AI balance: %s spent %s in %s, over the %s alert.',
				$alert->{'label'}, $money->($alert->{'amount'}), $alert->{'period'}, $money->($alert->{'limit'})))
			: &subs::ui(sprintf('AI balance: %s has about %s of runway left, under the %s alert.',
				$alert->{'label'}, &subs::ai_balance_span_label($alert->{'days'} * 24),
				&subs::ai_balance_span_label($alert->{'limit'} * 24)));
		&subs::db_insert('notes', {
			uuid => &subs::random_string_creator(21),
			app => 'handbook',
			text => $text,
			timestamp => $now,
			server_time => $now,
		});
		push @written, $key;
	}
	&subs::cache_set({ app => '__president', context => 'ai_alert', subcontext => 'state', warranty => '-2d' }, { keys => [ sort keys %current ] });
	eval { &subs::ai_spend_prune(40) };
	return { fired => scalar @{ $check->{'fired'} }, written => \@written };
}

# A span in the units that read best: minutes under an hour, hours under two
# days, then days. The chart's first hours are a short line, and "3 h" says
# more than "0 d".
sub ai_balance_span_label {
	my ($hours) = @_;
	$hours = 0 unless defined $hours && $hours > 0;
	return sprintf('%.0f min', $hours * 60) if $hours < 1;
	return sprintf('%.0f h', $hours) if $hours < 48;
	return sprintf('%.0f d', $hours / 24);
}

# Money in a label: two decimals are right for a balance, but a slow spend is
# often cents a day and would read as 0.00, so small values keep four.
sub currency_money {
	my ($value) = @_;
	return '' unless defined $value;
	my $abs = abs($value);
	return sprintf('%.4f', $value) if $abs > 0 && $abs < 0.1;
	return sprintf('%.2f', $value);
}

# Kept for the balance chart's existing callers. New displays use currency_money.
sub ai_balance_money {
	return &currency_money($_[0]);
}

# The fiat currencies a picker may offer, and what one unit of the house
# currency is worth in each. The order is deliberate: the house currency first,
# the amount's own currency second, then the rest of the fiat table in its own
# order. A code the rate snapshot does not carry is left out - offering it would
# be a promise the conversion cannot keep. `rate` is target units per one base.
sub currency_options {
	my ($from) = @_;
	$from = uc($from || '');
	my $base = &crypto_report_currency();
	my $r = &crypto_rates_read();
	my $table = $r->{'rates'} || {};
	my $base_v = $table->{$base};
	$base_v = 1 unless defined $base_v && $base_v > 0;
	my (@codes, %seen);
	my $add = sub {
		my ($code) = @_;
		$code = uc($code || '');
		return unless $code =~ /^[A-Z]{3}$/;
		return if $seen{$code}++;
		my $v = $table->{$code};
		my $rate;
		if ($code eq $base) { $rate = 1; }
		elsif (defined $v && $v > 0) { $rate = $base_v / $v; }
		else { return; }
		push @codes, { code => $code, rate => $rate };
	};
	$add->($base);
	$add->($from) if length $from;
	foreach my $f ( @{ &crypto_fiat_codes() } ) { $add->($f); }
	return ($base, \@codes);
}

# An amount in its own currency as the house currency. Returns undef when no
# rate is loaded, so a caller can show the original figure instead of a guess.
sub currency_amount_base {
	my ($amount, $from, $to) = @_;
	return undef unless defined $amount;
	$from = uc($from || '');
	$to = uc($to || &crypto_report_currency());
	$from = $to unless length $from;
	return $amount if $from eq $to;
	my $rate = &exchange_rate($from, $to);
	return (defined $rate && $rate > 0) ? $amount * $rate : undef;
}

# Auto-approve, kept on a leash: at most 8 auto-applies a day (each one is a
# commit and a push; a bad day must not become a hundred). Past that the
# proposals simply wait for a person, as they always did.
sub watch_auto_allowed {
	my $row = &subs::cache_get({ app => '__president', context => 'watch_auto', subcontext => &watch_tokens_day() });
	return ((ref $row eq 'HASH' ? ($row->{'count'} || 0) : 0) < 8) ? 1 : 0;
}

sub watch_auto_count {
	my $row = &subs::cache_get({ app => '__president', context => 'watch_auto', subcontext => &watch_tokens_day() }) || {};
	&subs::cache_set(
		{ app => '__president', context => 'watch_auto', subcontext => &watch_tokens_day(), warranty => '-2d' },
		{ count => ($row->{'count'} || 0) + 1 }
	);
}

# An auto-applied fix writes whole files; if any of them has uncommitted work in
# the tree, writing would swallow it, so auto-approve stands down and leaves the
# proposal for a person (the log says why).
sub auto_apply_clean {
	my ($row) = @_;
	my $files = eval { decode_json $row->{'files'} } || {};
	my @names = sort grep { &error_watch_path($_) } keys %{$files};
	return 0 unless @names;
	my $repo = &error_watch_repo();
	my @q = map { '"' . $_ . '"' } @names;
	my $dirty = `cd "$repo" && git status --porcelain -- @q 2>&1`;
	return 0 if defined $dirty && $dirty =~ /\S/;
	return 1;
}

# Apply one staged fix: write its files, check the Perl, then the finishing
# routine - bump, commit only what was written (plus VERSION), push. A failure
# at the check puts every file back and nothing is committed. Both the panel's
# Apply and the watch's auto-approve come through here.
sub staged_fix_apply {
	my ($uuid) = @_;
	my $row = &subs::db_select('staged_fixes', undef, { uuid => $uuid })->hash;
	return { error => 'no such caught error' } unless $row;
	return { error => 'nothing is staged on that row yet' } unless (($row->{'status'} // '') eq 'proposed');
	my $files = eval { decode_json $row->{'files'} } || {};
	my @names = sort keys %{$files};
	return { error => 'that proposal stages no files' } unless @names;
	my $repo = &error_watch_repo();
	my (%backup, %touched);
	foreach my $rel ( @names ) {
		my $abs = &error_watch_path($rel);
		return { error => 'refused: ' . $rel . ' is outside the repo' } unless $abs;
		$backup{$abs} = -f $abs ? scalar read_file($abs) : undef;
		my $content = $files->{$rel};
		$content = '' unless defined $content;
		require File::Basename;
		my $dir = File::Basename::dirname($abs);
		if (!-d $dir) { require File::Path; File::Path::make_path($dir); }
		eval { write_file($abs, $content) };
		if ($@) {
			foreach my $done ( keys %backup ) {
				if (defined $backup{$done}) { eval { write_file($done, $backup{$done}) }; }
				else { unlink $done; }
			}
			return { error => 'could not write ' . $rel };
		}
		$touched{$rel} = 1;
	}
	# the whole change must pass the verifier before it ships: Perl compiles,
	# JavaScript parses, templates compile, and no file was truncated - the checks
	# a person would run by hand, run for them. On failure every file goes back
	# and nothing is committed. (A proposal that reaches here has already been
	# checked once, as it was staged; this is the check on what is truly on disk.)
	my ($verify, $vcode) = ('', 0);
	my $filelist = join(' ', map { '"' . $_ . '"' } sort keys %touched);
	if ($filelist && -f "$repo/scripts/verify_change.pl") {
		$verify = `cd "$repo" && perl scripts/verify_change.pl $filelist 2>&1`;
		$vcode = $? >> 8;
	}
	if ($vcode != 0) {
		foreach my $abs ( keys %backup ) {
			if (defined $backup{$abs}) { eval { write_file($abs, $backup{$abs}) }; }
			else { unlink $abs; }
		}
		# the IDE panel renders checks as a list of { path, output }; keep that shape
		my (@entries, $cur);
		foreach my $line (split /\n/, ($verify // '')) {
			if ($line =~ /^FAIL\s+(\S+)/) { $cur = { path => $1, output => '' }; push @entries, $cur; }
			elsif ($cur && $line =~ /^\s+(\S.*)$/) { $cur->{'output'} .= ($cur->{'output'} ? '; ' : '') . $1; }
		}
		push @entries, { path => 'verifier', output => substr(($verify // ''), 0, 1000) } unless @entries;
		return { error => 'the change did not pass verification; nothing was applied', checks => \@entries };
	}
	# the finishing routine: bump, then commit only what was written (plus
	# VERSION - never someone else's work in progress), then push
	my $bump = `cd "$repo" && perl scripts/version_bump.pl 2>&1`;
	$bump = '' unless defined $bump;
	$bump =~ s/\s+$//;
	return { error => 'the version bump failed: ' . ($bump || 'no output'), written => [ sort keys %touched ] } unless $bump =~ /^\d+\.\d+\.\d+$/;
	my $version = eval { read_file("$repo/VERSION") } || '';
	$version =~ s/\s+$//;
	my $msg = $row->{'summary'} || $row->{'signature'} || 'error watch fix';
	$msg =~ s/["`\$\\]/ /g;
	$msg =~ s/\s+/ /g;
	$msg =~ s/^\s+|\s+$//g;
	my @add = map { '"' . $_ . '"' } sort keys %touched;
	push @add, '"VERSION"';
	my $commit = `cd "$repo" && git add -- @add 2>&1 && git commit -m "v$version - $msg" 2>&1`;
	$commit = '' unless defined $commit;
	$commit = substr($commit, 0, 1200);
	my $push = `cd "$repo" && git push 2>&1`;
	$push = '' unless defined $push;
	$push = substr($push, 0, 800);
	# the note is also the fixed list's record: when it shipped, and as what - the
	# review list under Configure's auto-heal tick reads it back
	&subs::db_update('staged_fixes', { status => 'applied', note => 'applied ' . &subs::rightNow() . ' as v' . $version }, { uuid => $uuid });
	return { applied => $uuid, version => $version, bump => $bump, commit => $commit, push => $push };
}

sub error_watch_is_error {
	my $line = shift;
	$line = '' unless defined $line;
	return 0 if $line =~ $error_watch_noise;
	# The master's report of a tree death is a fault even though its wording has
	# no error word in it. Deliberate restarts suppress 'See it's dead', and the
	# END line 'They dead' on a deliberate restart is not matched here.
	return 1 if $line =~ /tree exited on its own|See it's dead/;
	return 1 if $line =~ /\b(?:failed|failure|fatal|panic|abort(?:ed)?|died|denied|malformed|corrupt|not ok|couldn't|could not|can't|cannot|unable to|uninitialized|undefined|out of memory|segmentation|core dumped|database is locked|no such (?:file|table|column)|too many|refused|error)\b/i;
	return 0;
}

# One invariant name per distinct error: control codes, addresses and numbers
# (line numbers, pids, ports, counts) are blanked, so a flood of one fault
# collapses to a single staged row.
sub error_signature {
	my $text = shift;
	$text = '' unless defined $text;
	$text =~ s/\e\[[0-9;?]*[A-Za-z]//g;
	$text =~ s/\r//g;
	# a per-occurrence correlator ([GXJwplb_HcnT]) is not part of the fault: a
	# bracketed 8+ char token carrying an upper-case letter is blanked, so the
	# same fault logged twice does not stage twice
	$text =~ s/\[(?=[A-Za-z0-9_-]{8,}\])(?:[A-Za-z0-9_-]*[A-Z])[A-Za-z0-9_-]*\]/[ID]/g;
	$text =~ s/0x[0-9a-fA-F]+/0xADDR/g;
	$text =~ s/\b\d+\b/N/g;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return substr($text, 0, 300);
}

sub error_watch_read_new {
	my ($path, $source) = @_;
	return () unless defined $path && -f $path;
	unless ($error_watch_state_loaded) { &error_watch_state_load(); $error_watch_state_loaded = 1; }
	my $size = -s $path;
	unless (defined $error_watch_state{$source}) {
		# a fresh source starts at its beginning; the long-lived manager.log
		# starts at its end - never replay history
		$error_watch_state{$source} = ($source eq 'log') ? $size : 0;
	}
	my $offset = $error_watch_state{$source};
	if (defined $size && $size < $offset) {
		# truncated out from under us: take the new file from its start
		$offset = $error_watch_state{$source} = 0;
		$error_watch_partial{$source} = '';
	}
	open(my $fh, '<', $path) or return ();
	seek($fh, $offset, 0) or do { close $fh; return (); };
	my $chunk = '';
	read($fh, $chunk, 262144);
	close $fh;
	return () unless defined $chunk && length $chunk;
	$error_watch_state{$source} = $offset + length $chunk;
	&error_watch_state_save();
	my $buffer = ($error_watch_partial{$source} // '') . $chunk;
	my @lines = split /\n/, $buffer, -1;
	$error_watch_partial{$source} = pop @lines;   # keep the unterminated tail
	return @lines;
}

# The tree's console stream rides the master's log bus, not a file. The cursor
# is a byte sequence (`pty_seq`) kept in the same offsets file as the file
# readers: a tree restart resumes exactly where it left off, while a master
# restart wipes that file and the new sequence starts at 0. Its own key means a
# pre-bus byte offset can never be read as a sequence.
sub log_bus_read_new {
	require JawnOS::LogBus;
	unless ($error_watch_state_loaded) { &error_watch_state_load(); $error_watch_state_loaded = 1; }
	my $path = &subs::home('~/.president/log');
	my $since = $error_watch_state{'pty_seq'} // 0;
	my $reply = JawnOS::LogBus::client_read($path, $since, 262144);
	return () unless $reply;
	# Our cursor is ahead of this master (the offsets file outlived a master
	# boot): take the new stream from its beginning.
	if ($reply->{'reset'}) {
		$error_watch_state{'pty_seq'} = 0;
		&error_watch_state_save();
		$reply = JawnOS::LogBus::client_read($path, 0, 262144);
		return () unless $reply;
	}
	if ($reply->{'dropped'}) {
		# The ring overwrote bytes while the watcher was busy. Say so in
		# manager.log (which this same watch also reads) rather than pretend the
		# stream was complete.
		eval { $log->warn('log bus: ' . $reply->{'dropped'} . ' byte(s) dropped before sequence ' . $reply->{'earliest'}) } if defined $log;
	}
	$error_watch_state{'pty_seq'} = $reply->{'to'};
	&error_watch_state_save();
	my $bytes = $reply->{'bytes'} // '';
	return () unless length $bytes;
	my $buffer = ($error_watch_partial{'pty_seq'} // '') . $bytes;
	my @lines = split /\n/, $buffer, -1;
	$error_watch_partial{'pty_seq'} = pop @lines;
	return @lines;
}

# A Perl warning is two lines - the message, then " at ./file line N." - so a
# matched line swallows the source location that follows it before it is caught.
sub error_watch_catch {
	my @lines = @_;
	my (@caught, $pending);
	foreach my $line ( @lines ) {
		if (defined $pending && $line =~ /^\s*at\s+\S+\s+line\s+\d+\.?\s*$/) {
			$pending .= ' ' . $line;
			next;
		}
		if (defined $pending) { push @caught, $pending; undef $pending; }
		next unless &error_watch_is_error($line);
		$pending = $line;
	}
	push @caught, $pending if defined $pending;
	return @caught;
}

# Record one caught fault: a new row when its signature is new, a tally bump on
# the row already carrying it. Shared by the log watch and the browser's fatal
# JavaScript reporter (the signature may come from a shorter text than the
# sample - a JS fault's stack must not make every occurrence a new signature).
sub staged_fix_note {
	my ($params) = @_;
	my $sample = $params->{'sample'} // '';
	my $sig = &error_signature(defined $params->{'signature_text'} ? $params->{'signature_text'} : $sample);
	return {} unless length $sig;
	my $tally = (($params->{'tally'} || 1) + 0) || 1;
	my $existing = &subs::db_select('staged_fixes', [ 'uuid', 'tally' ], { signature => $sig })->hashes->[0];
	if ($existing) {
		&subs::db_update('staged_fixes', {
			tally => ($existing->{'tally'} || 0) + $tally,
			last_seen => &subs::rightNow(),
		}, { uuid => $existing->{'uuid'} });
		return { uuid => $existing->{'uuid'}, signature => $sig };
	}
	my $uuid = &subs::random_string_creator(40);
	&subs::db_insert('staged_fixes', {
		uuid => $uuid,
		source => ($params->{'source'} || 'pty'),
		signature => $sig,
		sample => substr($sample, 0, 2000),
		tally => $tally,
		status => 'new',
		last_seen => &subs::rightNow(),
	});
	return { uuid => $uuid, signature => $sig, status => 'new' };
}

# ---- the records watch ------------------------------------------------------
# The database's half of the self-heal, and the mirror of the error watch: a
# fixed, deterministic audit of the appointments table for the fault classes
# that corrupt the person's numbers. A stop press closes ONE session, but two
# bugs left rows ended by a press that was not their own (one stop applied to
# several open sessions) or wrote the same event once per machine. The judgement
# - which row to keep, what to repair - is the Coding agent's, staged and
# approved the way a code fix is (staged_records). Nothing here writes.
sub records_audit_prompt {
	return join "\n",
		'You are the Records Watch for JawnOS. You audit the appointments table for a fault class that has been corrupting the person\'s numbers, and you reconcile what you find. Nothing is written until a person approves it.',
		'',
		'A stop press closes ONE session. Two faults planted wrong rows: (1) one stop was applied to several open sessions, so an old session took its end from a press that was not its own; (2) the same event was written once per machine and the mesh kept every copy.',
		'',
		'You are handed a fixed report. For each entry:',
		'- SWEEP (rows share app + stop_timestamp): at most one row is the session that press closed. If the app sets a duration, the real row is the one whose |duration| is nearest it; otherwise the one whose start is nearest the press. Every other row was ended by a press that was not its own: repair each to its own end when the app sets a duration (start + duration), else tombstone it.',
		'- DUPES (identical app/type/timestamp/stop_timestamp): keep one, tombstone the rest.',
		'- ORPHAN (start/record, stop_seen null): do NOT stop it - it may be real and still running. Leave it unless the app sets a duration and it has run far past that, in which case repair it to start + duration.',
		'- IMPOSSIBLE (a stop before its own start): repair to a sane end or tombstone.',
		'- WRONG-END (an older session whose span contains a newer session\'s start of the same app): the older row was ended by a press that belonged to the newer one, so it ran on. Repair it to its own start + the app\'s length when the app sets one; leave it alone when it has no length or the person says it is real.',
		'',
		'Rules that must not be broken:',
		'- Do NOT judge by duration length alone: home is legitimately a full day, a walk an hour. Compare against the app\'s own history and its configured duration, never a fixed threshold.',
		'- Do NOT trust one machine over another. The correct end is whichever press actually stopped that session; where machines disagree, prefer the value that matches the app\'s configured duration.',
		'- Leave alone anything started in the last ten minutes, anything a person corrected by hand (a note, an edited time), and any row that is still running.',
		'- Writes ride the app\'s own routes: delete_app tombstones a duplicate so the whole mesh agrees, and the appointment\'s own stop path repairs an end.',
		'',
		'Answer with a JSON list of proposed actions, one per row: {"action":"keep"|"tombstone"|"repair","app":..,"uuid":..,"stop_timestamp":..,"duration":..,"why":".."}. Say which row you keep per group and why, and list what you leave alone and why. Write nothing else.';
}

# An app the person has said is genuinely, surprisingly long-lived (a home stay, an
# eight-month ailment). Length alone can never tell a real session from a swept one,
# so the audit must be able to be told to leave an app alone entirely. Stored per
# machine as a JSON list of app names (mail/records_exempt).
sub records_exempt {
	my $raw = &subs::setting_grabber({ app => 'mail', setting => 'records_exempt' }) // '';
	my $saved = length($raw) ? eval { decode_json $raw } : undef;
	$saved = [] unless ref $saved eq 'ARRAY';
	my %apps;
	foreach my $a ( @{$saved} ) { $apps{$a} = 1 if defined $a && length $a; }
	return \%apps;
}

sub records_exempt_add {
	my ($app) = @_;
	return 0 unless defined $app && length $app;
	my $exempt = &records_exempt();
	$exempt->{$app} = 1;
	&subs::setting_setter({ app => 'mail', setting => 'records_exempt', value => encode_json([ sort keys %{$exempt} ]) });
	return 1;
}

# A millisecond date that a bridge reader mistook for a span of minutes was
# subtracted from the writing moment, so the row landed millions of years in the
# past. The arithmetic inverts exactly: the original stamp is
# (ost - timestamp) / 60000. Only the unmistakable magnitude is touched, and
# only when the recovered value is a real date, so no other odd row is rewritten.
sub records_bad_date_fix {
	my ($row, $now) = @_;
	$now = &rightNow() unless $now;
	my $floor = 946684800000;    # 2000-01-01: nothing in the house is older
	my $bad = $row->{'timestamp'};
	return undef unless defined $bad && $bad =~ /^-?\d+$/ && $bad < -1000000000000000;
	my $anchor = (defined $row->{'ost'} && $row->{'ost'} =~ /^\d{10,}$/) ? $row->{'ost'} : $row->{'server_time'};
	return undef unless defined $anchor && $anchor =~ /^\d{10,}$/;
	my $real = int(($anchor - $bad) / 60000 + 0.5);
	return undef unless $real >= $floor && $real <= $now + 86400000;
	my $fix = { timestamp => $real };
	my $stop = $row->{'stop_timestamp'};
	if (defined $stop && $stop =~ /^-?\d+$/ && $stop < -1000000000000000) {
		my $real_stop = int(($anchor - $stop) / 60000 + 0.5);
		$fix->{'stop_timestamp'} = ($real_stop >= $floor && $real_stop <= $now + 86400000) ? $real_stop : $real;
	}
	return $fix;
}

# The bad-date rows and what to do with each. Most are not new records: the
# check re-read the same last ten messages and thirty calls on every pass, and a
# mangled stamp never matched the row it had already written, so it wrote the
# event again. Keep one row per event - the sane record when one exists, else the
# first bad row - and tombstone the re-writes instead of repairing a duplicate
# into view.
sub records_bad_dates_scan {
	my ($now, $exempt) = @_;
	$now = &rightNow() unless $now;
	$exempt ||= &records_exempt();
	my @out;
	my $bad = &db_query('select rowid, uuid, app, type, timestamp, stop_timestamp, ost, server_time from appointments
		where cast(timestamp as integer) < -1000000000000000
		   or (stop_timestamp is not null and cast(stop_timestamp as integer) < -1000000000000000)
		order by rowid asc')->hashes;
	my %kept_bad;
	foreach my $r ( @{$bad} ) {
		next if $exempt->{ $r->{'app'} };
		my $fix = &records_bad_date_fix($r, $now);
		next unless $fix;
		my $real = $fix->{'timestamp'};
		my $dup = &db_query('select uuid from appointments where app = ? and type = ? and cast(timestamp as integer) between ? and ? limit 1',
			$r->{'app'}, $r->{'type'}, $real - 1000, $real + 1000)->hashes->[0];
		if ($dup) {
			push @out, { %{$r}, fix => $fix, suggested => 'tombstone', why => 'a re-write of a record already stored' };
			next;
		}
		my $event = ($r->{'app'} || '') . '|' . ($r->{'type'} || '');
		if (grep { abs($_ - $real) <= 1000 } @{ $kept_bad{$event} || [] }) {
			push @out, { %{$r}, fix => $fix, suggested => 'tombstone', why => 'a re-write of the record kept from the same batch' };
			next;
		}
		push @{$kept_bad{$event}}, $real;
		push @out, { %{$r}, fix => $fix, suggested => 'repair', why => 'a millisecond date was read as a span of minutes' };
	}
	return \@out;
}

# The same bridge bug wrote the mailbox row beside the appointment: sms_list_check
# inserted both with the mangled stamp. Mailbox has no stop_timestamp, so only
# timestamp is inverted. A sealed body is encrypted with a random container, so
# two writes of one message never share the same bytes; an unreadable body is
# therefore matched on the event (phone, sender, status, the same second), while
# a readable body must agree.
sub records_mailbox_body_readable {
	my ($body) = @_;
	return 0 unless defined $body && length $body;
	# a sealed note is long, has no whitespace and is base64 (with the container
	# markers); anything else - an ordinary message, a short word - is readable
	return 0 if length($body) >= 60 && $body !~ /\s/ && $body =~ m{^[A-Za-z0-9+/=:_-]+$};
	return 1;
}

sub records_mailbox_same_event {
	my ($a, $b) = @_;
	return 0 unless ref $a eq 'HASH' && ref $b eq 'HASH';
	foreach my $f (qw(phone manager_file status)) {
		my $x = defined $a->{$f} ? $a->{$f} : '';
		my $y = defined $b->{$f} ? $b->{$f} : '';
		return 0 unless $x eq $y;
	}
	my $readable_a = &records_mailbox_body_readable($a->{'body'});
	my $readable_b = &records_mailbox_body_readable($b->{'body'});
	return 0 if $readable_a != $readable_b;
	return 1 unless $readable_a;    # both sealed: the ciphertext says nothing
	return (defined $a->{'body'} && defined $b->{'body'} && $a->{'body'} eq $b->{'body'}) ? 1 : 0;
}

1;
