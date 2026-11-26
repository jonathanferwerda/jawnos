package subs;

# Intelligence: the token and spend view. It reads the per-call ledger
# (ai_spend), the long-lived daily rollup (ai_spend_daily), the house's daily
# purse (ai_budget) and the cached provider balances, and shapes them for the
# five panels of the start-menu app. It writes no ledger row; the cadence POST
# in the controller is the only write, and it goes through the existing
# evaluation schedule arranger.
#
# The ledger is newer than some databases: a column or a table may not exist
# yet, so every read is guarded and a missing thing answers zero or an empty
# list rather than taking the window down. The daily rollup is the long-lived
# source for History; older days fall back to the house's daily ai_budget total.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm. Only the six panel entry
# points are named subs; the shared helpers are anonymous so the loader map and
# t/91 stay a one-to-one list of things another module can call by name.

use strict;
use warnings;
use utf8;

use Mojo::JSON qw(decode_json);
use Time::Piece;

# The agent groups the Agents panel draws, and the roles each one owns. A role
# the map does not name lands in Other, so a new assistant is never lost.
my $ROLE_GROUP = {
	chatbot_model           => 'Pen',
	coding_assistant        => 'Coding agent',
	help_assistant          => 'Guide & associates',
	visual_assistant        => 'Guide & associates',
	transcription_assistant => 'Guide & associates',
	text_to_image_assistant => 'Guide & associates',
	text_to_audio_assistant => 'Guide & associates',
	text_to_video_assistant => 'Guide & associates',
	text_to_image           => 'Guide & associates',
	text_to_audio           => 'Guide & associates',
	text_to_video           => 'Guide & associates',
	eval_assistant          => 'Evaluations',
};
my @GROUP_ORDER = ('Pen', 'Coding agent', 'Guide & associates', 'Evaluations', 'Other');

# The provider rows the Providers panel always names, and the label each wears.
my @KNOWN_PROVIDERS = (
	[ 'cloudflare',    'Cloudflare' ],
	[ 'deepseek',      'DeepSeek' ],
	[ 'opencode',      'OpenCode' ],
	[ 'ollama',        'Ollama (local)' ],
	[ 'ollama_remote', 'Ollama (peer)' ],
);
my %KNOWN_PROVIDER_LABEL = map { $_->[0] => $_->[1] } @KNOWN_PROVIDERS;

# How far back each History range reaches, in days. "all" has no fixed span.
my $RANGE_DAYS = { '24h' => 2, '7d' => 7, '30d' => 30, '90d' => 90, '1y' => 365, 'all' => 0 };

# A number from a database row, or zero.
my $_num = sub {
	my ($v) = @_;
	return (defined $v && $v =~ /^-?\d+(?:\.\d+)?$/) ? ($v + 0) : 0;
};

# A local day key, 'YYYY-MM-DD', the same clock the ledger keys minutes on.
my $_day_key = sub {
	my ($ms) = @_;
	$ms = &subs::rightNow() unless defined $ms && $ms =~ /^-?\d+$/;
	my $t = localtime($ms / 1000);
	return ref $t ? $t->strftime('%Y-%m-%d') : '';
};

# A local minute key, 'YYYY-MM-DD HH:MM', comparable to ai_spend.minute.
my $_minute_key = sub {
	my ($ms) = @_;
	$ms = &subs::rightNow() unless defined $ms && $ms =~ /^-?\d+$/;
	my $t = localtime($ms / 1000);
	return ref $t ? $t->strftime('%Y-%m-%d %H:%M') : '';
};

# A local clock text for an epoch-millisecond stamp the ledger logged.
my $_time_text = sub {
	my ($ms) = @_;
	return '' unless defined $ms && $ms =~ /^-?\d+$/;
	my $t = localtime($ms / 1000);
	return ref $t ? $t->strftime('%Y-%m-%d %H:%M') : '';
};

# Rows from one query, or an empty list when the table or column is not there.
my $_rows = sub {
	my ($sql, @bind) = @_;
	my $results = eval { &subs::db_query($sql, @bind) };
	return [] unless $results;
	my $rows = eval { $results->hashes };
	return (ref $rows eq 'ARRAY') ? $rows : [];
};

# One provider row, with its share of the whole and the models it served.
my $_provider_row = sub {
	my ($provider, $label, $entry, $total) = @_;
	$entry = {} unless ref $entry eq 'HASH';
	my $tokens = $_num->($entry->{'tokens'});
	my $share = ($total->{'tokens'} > 0) ? ($tokens / $total->{'tokens'}) * 100 : 0;
	my @models = sort { ($entry->{'models'}->{$b} || 0) <=> ($entry->{'models'}->{$a} || 0) }
		grep { length } keys %{ $entry->{'models'} || {} };
	return {
		provider   => $provider,
		label      => $label,
		tokens_in  => $_num->($entry->{'tokens_in'}),
		tokens_out => $_num->($entry->{'tokens_out'}),
		tokens     => $tokens,
		calls      => $_num->($entry->{'calls'}),
		share      => $share,
		models     => \@models,
	};
};

# A provider id as something a person reads, for one the known list omits.
my $_pretty_provider = sub {
	my ($provider) = @_;
	return 'Unknown' unless defined $provider && length $provider;
	my $text = $provider;
	$text =~ s/_/ /g;
	return join ' ', map { ucfirst } split / /, $text;
};

# The Overview panel: the three token windows, the day's purse, the provider
# split, the loudest agents and evaluations, and the newest calls.
sub intelligence_summary {
	# The window's controller already reads the Agents and Evaluations panels
	# for their own pills; taking them in avoids asking the ledger and Minion a
	# second time for the Overview's short versions. A caller with no panels in
	# hand (a test, another surface) still gets the same answer.
	my ($agents, $evaluations, $recent) = @_;
	my $now = &subs::rightNow();
	my $today_key = $_day_key->($now) . ' 00:00';
	my $key7 = $_minute_key->($now - 7 * 86400000);
	my $key30 = $_minute_key->($now - 30 * 86400000);

	my $row = $_rows->(
		'select '
		. 'sum(case when minute >= ? then tokens_in + tokens_out else 0 end) as t_today, '
		. 'sum(case when minute >= ? then tokens_in + tokens_out else 0 end) as t_7, '
		. 'sum(case when minute >= ? then tokens_in + tokens_out else 0 end) as t_30, '
		. 'sum(case when minute >= ? then calls else 0 end) as c_today, '
		. 'sum(case when minute >= ? then calls else 0 end) as c_7, '
		. 'sum(case when minute >= ? then calls else 0 end) as c_30 '
		. 'from ai_spend',
		$today_key, $key7, $key30, $today_key, $key7, $key30,
	)->[0] || {};

	my %summary = (
		today => { tokens => $_num->($row->{'t_today'}), calls => $_num->($row->{'c_today'}) },
		week  => { tokens => $_num->($row->{'t_7'}),      calls => $_num->($row->{'c_7'}) },
		month => { tokens => $_num->($row->{'t_30'}),     calls => $_num->($row->{'c_30'}) },
	);

	# A database whose ledger is empty (or predates it) still has the house's
	# daily purse. The ledger wins where it has rows; budget fills the silence.
	if (!$summary{'today'}->{'tokens'} && !$summary{'week'}->{'tokens'} && !$summary{'month'}->{'tokens'}) {
		my $day = $_day_key->($now);
		my $weekday = $_day_key->($now - 6 * 86400000);
		my $monthday = $_day_key->($now - 29 * 86400000);
		my $budget_today = $_rows->('select sum(tokens) as tokens from ai_budget where day = ?', $day)->[0] || {};
		my $budget_week  = $_rows->('select sum(tokens) as tokens from ai_budget where day >= ?', $weekday)->[0] || {};
		my $budget_month = $_rows->('select sum(tokens) as tokens from ai_budget where day >= ?', $monthday)->[0] || {};
		$summary{'today'}->{'tokens'} = $_num->($budget_today->{'tokens'});
		$summary{'week'}->{'tokens'}  = $_num->($budget_week->{'tokens'});
		$summary{'month'}->{'tokens'} = $_num->($budget_month->{'tokens'});
	}

	my $spent = eval { &subs::ai_house_budget_spent() } || 0;
	my $cap = eval { &subs::setting_grabber({ app => 'mail', setting => 'error_watch_budget' }) };
	$cap = (defined $cap && $cap =~ /^\d+$/) ? ($cap + 0) : 1000000;
	my $percent = $cap > 0 ? ($spent / $cap) * 100 : 0;

	my $provider_rows = $_rows->(
		'select provider, sum(tokens_in + tokens_out) as tokens, sum(calls) as calls '
		. 'from ai_spend where minute >= ? group by provider order by tokens desc',
		$key30,
	);

	my $groups = (ref $agents eq 'ARRAY') ? $agents : &intelligence_agents();
	my @top_agents = grep { $_->{'tokens'} > 0 } @{$groups};
	@top_agents = @top_agents[0 .. 4] if @top_agents > 5;

	my $evals = (ref $evaluations eq 'ARRAY') ? $evaluations : &intelligence_evaluations();
	my @top_evaluations = sort { ($b->{'tokens_30d'} || 0) <=> ($a->{'tokens_30d'} || 0) }
		grep { ($_->{'tokens_30d'} || 0) > 0 } @{$evals};
	@top_evaluations = @top_evaluations[0 .. 4] if @top_evaluations > 5;

	return {
		%summary,
		calls_today => $summary{'today'}->{'calls'},
		budget      => { spent => $spent, cap => $cap, percent => $percent },
		providers   => [ map { { provider => ($_->{'provider'} // ''), label => ($KNOWN_PROVIDER_LABEL{ $_->{'provider'} // '' } || $_pretty_provider->($_->{'provider'})), tokens => $_num->($_->{'tokens'}), calls => $_num->($_->{'calls'}) } } @{$provider_rows} ],
		top_agents  => [ map { { name => $_->{'name'}, tokens => $_->{'tokens'}, calls => $_->{'calls'} } } @top_agents ],
		top_evaluations => [ map { { scope => $_->{'scope'}, label => $_->{'label'}, tokens => $_->{'tokens_30d'} } } @top_evaluations ],
		recent      => (ref $recent eq 'ARRAY') ? $recent : &intelligence_recent(20),
	};
}

# The Agents panel: one card per agent group, over the last thirty days, from
# the ledger's own role rows. Sessions are active clock-hours and active time
# is active clock-minutes, both summed over the providers that served the role.
sub intelligence_agents {
	my $now = &subs::rightNow();
	my $since = $_minute_key->($now - 30 * 86400000);
	my $rows = $_rows->(
		'select role, provider, '
		. 'sum(tokens_in) as ti, sum(tokens_out) as t_o, sum(calls) as calls, '
		. 'count(distinct minute) as active_minutes, '
		. 'max(minute) as last_used '
		. 'from ai_spend where minute >= ? group by role, provider',
		$since,
	);
	# The ledger's own session arithmetic counts a run of calls with no gap wider
	# than fifteen minutes, not an hour of the clock: a day of two chats an hour
	# apart is two sessions, not eight. Use it for the card's session figure and
	# keep the SQL's distinct minutes as the active-time reading.
	my $sessions = eval { &subs::ai_spend_sessions($since) } || {};
	my $sessions_for = $sessions->{'providers'} || {};

	my %group;
	foreach my $r ( @{$rows} ) {
		my $role = $r->{'role'} // '';
		my $name = $ROLE_GROUP->{$role} || 'Other';
		my $entry = $group{$name} ||= {
			name => $name, tokens_in => 0, tokens_out => 0, calls => 0,
			sessions => 0, active_minutes => 0, active_ms => 0, last_used => '',
			providers => {}, roles => {}, provider_labels => {},
		};
		my $in  = $_num->($r->{'ti'});
		my $out = $_num->($r->{'t_o'});
		$entry->{'tokens_in'}  += $in;
		$entry->{'tokens_out'} += $out;
		$entry->{'calls'}      += $_num->($r->{'calls'});
		$entry->{'active_minutes'} += $_num->($r->{'active_minutes'});
		my $provider = $r->{'provider'} // '';
		my $role_sessions = $sessions_for->{$provider}->{'roles'}->{$role} || {};
		$entry->{'sessions'} += $_num->($role_sessions->{'sessions'});
		$entry->{'active_ms'} += $_num->($role_sessions->{'active_ms'});
		$entry->{'providers'}->{$provider} = ($entry->{'providers'}->{$provider} || 0) + $in + $out;
		$entry->{'provider_labels'}->{$provider} = $KNOWN_PROVIDER_LABEL{$provider} || $_pretty_provider->($provider);
		$entry->{'roles'}->{$role} = ($entry->{'roles'}->{$role} || 0) + $in + $out;
		my $last = $r->{'last_used'} // '';
		$entry->{'last_used'} = $last if $last gt $entry->{'last_used'};
	}

	my @out;
	foreach my $name (@GROUP_ORDER) {
		my $entry = $group{$name} || {
			name => $name, tokens_in => 0, tokens_out => 0, calls => 0,
			sessions => 0, active_minutes => 0, active_ms => 0, last_used => '',
			providers => {}, roles => {}, provider_labels => {},
		};
		$entry->{'tokens'} = $entry->{'tokens_in'} + $entry->{'tokens_out'};
		$entry->{'roles'} = [ map { { role => $_, tokens => $entry->{'roles'}->{$_} } } sort keys %{ $entry->{'roles'} } ];
		push @out, $entry;
	}
	return \@out;
}

# The Evaluations panel: one row per scope the settings name, plus the whole
# house. It reads the schedules once for every scope rather than asking Minion
# once per app, and takes the last-run record from the scope's evaluation_runs.
sub intelligence_evaluations {
	my $now = &subs::rightNow();
	my $key7 = $_minute_key->($now - 7 * 86400000);
	my $key30 = $_minute_key->($now - 30 * 86400000);

	my $setting_rows = $_rows->(
		"select distinct app from settings where setting in "
		. "('evaluation_cadence', 'nightly_evaluation', 'evaluation_runs', 'evaluation_depth')"
	);
	my %scope = ( '__president' => 1 );
	foreach my $r ( @{$setting_rows} ) {
		my $app = $r->{'app'};
		$scope{$app} = 1 if defined $app && length $app;
	}

	# One Minion read for every schedule, keyed by name.
	my %next;
	my $listed = eval { &subs::minion_grabber()->list_schedules(0, 1000) } || {};
	my $schedules = (ref $listed eq 'HASH' && ref $listed->{'schedules'} eq 'ARRAY') ? $listed->{'schedules'} : [];
	foreach my $s ( @{$schedules} ) {
		next unless ref $s eq 'HASH';
		my $name = $s->{'name'} // '';
		$next{$name} = $s->{'next_run'} if defined $s->{'next_run'};
	}

	# Evaluation tokens by scope, where the ledger carries the app column.
	my %tokens;
	my $token_rows = $_rows->(
		'select app, '
		. 'sum(case when minute >= ? then tokens_in + tokens_out else 0 end) as t7, '
		. 'sum(case when minute >= ? then tokens_in + tokens_out else 0 end) as t30 '
		. 'from ai_spend where role = ? and app is not null and app != ? group by app',
		$key7, $key30, 'eval_assistant', '',
	);
	foreach my $r ( @{$token_rows} ) {
		my $app = $r->{'app'} // '';
		next unless length $app;
		# An app whose evaluation-assistant calls are in the ledger is a scope
		# even when the settings rows that name a cadence were lost or never
		# written: the spend itself says the scope exists.
		$scope{$app} = 1;
		$tokens{$app} = { t7 => $_num->($r->{'t7'}), t30 => $_num->($r->{'t30'}) };
	}
	# A ledger without the app column answers no per-scope split; the whole
	# house's evaluation traffic still has a home under the house row.
	if (!keys %tokens) {
		my $whole = $_rows->(
			'select '
			. 'sum(case when minute >= ? then tokens_in + tokens_out else 0 end) as t7, '
			. 'sum(case when minute >= ? then tokens_in + tokens_out else 0 end) as t30 '
			. 'from ai_spend where role = ?',
			$key7, $key30, 'eval_assistant',
		)->[0] || {};
		if ($_num->($whole->{'t7'}) || $_num->($whole->{'t30'})) {
			$tokens{'__president'} = { t7 => $_num->($whole->{'t7'}), t30 => $_num->($whole->{'t30'}) };
		}
	}

	my @out;
	foreach my $app ( sort keys %scope ) {
		my $cadence = eval { &subs::evaluation_cadence($app) } || 'off';
		my $days = eval { &subs::nightly_evaluation_days($app) } || [];

		my $runs = [];
		my $raw = eval { &subs::setting_grabber({ app => $app, setting => 'evaluation_runs' }) };
		if (defined $raw && length $raw) {
			my $decoded = eval { decode_json($raw) };
			$runs = (ref $decoded eq 'ARRAY') ? $decoded : [];
		}
		my $last = (ref $runs->[0] eq 'HASH') ? $runs->[0] : {};
		my $last_at = $last->{'timestamp'} // $last->{'at'};

		my $runs_30d = 0;
		foreach my $run ( @{$runs} ) {
			next unless ref $run eq 'HASH';
			my $at = $run->{'timestamp'} // $run->{'at'};
			next unless defined $at && $at =~ /^\d+$/ && $at >= $now - 30 * 86400000;
			$runs_30d++;
		}

		my $token = $tokens{$app} || { t7 => 0, t30 => 0 };
		my $last_tokens = defined $last->{'tokens'} ? $_num->($last->{'tokens'}) : 0;
		my $avg = $runs_30d > 0 ? $token->{'t30'} / $runs_30d : 0;

		# The primary state a row wears; at most one filter pill matches it.
		my %interval = ( hourly => 3600 * 1000, daily => 86400 * 1000, weekly => 7 * 86400000, monthly => 30 * 86400000, yearly => 365 * 86400000 );
		my $state = 'idle';
		if ($cadence eq 'each_run') {
			$state = 'on_demand';
		}
		elsif ($cadence ne 'off') {
			my $span = $interval{$cadence} || 0;
			if ($span > 0 && defined $last_at && $last_at =~ /^\d+$/ && $now - $last_at <= 2 * $span) {
				$state = 'active';
			}
			else {
				$state = 'scheduled';
			}
		}

		my $next_run = $next{ 'nightly_evaluation_' . $app };

		push @out, {
			scope          => $app,
			label          => ($app eq '__president') ? 'Whole house' : $app,
			cadence        => $cadence,
			days           => [ grep { /^[0-6]$/ } @{ ref $days eq 'ARRAY' ? $days : [] } ],
			next_run       => (defined $next_run && $next_run =~ /^\d+$/) ? $next_run + 0 : undef,
			next_run_text  => (defined $next_run && $next_run =~ /^\d+$/) ? $_time_text->($next_run * 1000) : '',
			last_run       => {
				at       => (defined $last_at && $last_at =~ /^\d+$/) ? $last_at + 0 : undef,
				at_text  => $_time_text->($last_at),
				outcome  => $last->{'outcome'} // '',
				machine  => $last->{'machine'} // '',
				model    => $last->{'model'} // '',
				note     => $last->{'note'} // '',
				tokens   => $last_tokens,
			},
			tokens_7d      => $token->{'t7'},
			tokens_30d     => $token->{'t30'},
			last_run_tokens => $last_tokens,
			avg_per_run    => $avg,
			runs_30d       => $runs_30d,
			state          => $state,
		};
	}

	@out = sort { ($b->{'tokens_30d'} || 0) <=> ($a->{'tokens_30d'} || 0) || $a->{'scope'} cmp $b->{'scope'} } @out;
	return \@out;
}

# The Providers panel: every provider the ledger names, the five known ones
# always shown (a quiet provider reads zero), the balance where the provider
# reports one, and the inferred outside-JawnOS line from the balance chart.
sub intelligence_providers {
	my $now = &subs::rightNow();
	my $since = $_minute_key->($now - 30 * 86400000);
	my $rows = $_rows->(
		'select provider, model, sum(tokens_in) as ti, sum(tokens_out) as t_o, sum(calls) as calls '
		. 'from ai_spend where minute >= ? group by provider, model',
		$since,
	);

	my %provider;
	my $total = { tokens_in => 0, tokens_out => 0, tokens => 0, calls => 0 };
	foreach my $r ( @{$rows} ) {
		my $id = $r->{'provider'} // '';
		my $entry = $provider{$id} ||= { tokens_in => 0, tokens_out => 0, tokens => 0, calls => 0, models => {} };
		my $in  = $_num->($r->{'ti'});
		my $out = $_num->($r->{'t_o'});
		$entry->{'tokens_in'}  += $in;
		$entry->{'tokens_out'} += $out;
		$entry->{'tokens'}     += $in + $out;
		$entry->{'calls'}      += $_num->($r->{'calls'});
		my $model = $r->{'model'} // '';
		$entry->{'models'}->{$model} = ($entry->{'models'}->{$model} || 0) + $in + $out if length $model;
		$total->{'tokens_in'}  += $in;
		$total->{'tokens_out'} += $out;
		$total->{'tokens'}     += $in + $out;
		$total->{'calls'}      += $_num->($r->{'calls'});
	}

	my %known = map { $_->[0] => 1 } @KNOWN_PROVIDERS;
	my @out;
	foreach my $known ( @KNOWN_PROVIDERS ) {
		my ( $id, $label ) = @{$known};
		push @out, $_provider_row->($id, $label, $provider{$id}, $total);
	}
	foreach my $id ( sort keys %provider ) {
		next if $known{$id};
		push @out, $_provider_row->($id, $_pretty_provider->($id), $provider{$id}, $total);
	}

	# Balances, where the provider reports one. The cached report is refreshed
	# off the page, so reading it never waits on a provider.
	my $report = eval { &subs::ai_balance_report() } || { rows => [] };
	my %balance;
	foreach my $b ( @{ (ref $report->{'rows'} eq 'ARRAY') ? $report->{'rows'} : [] } ) {
		next unless ref $b eq 'HASH';
		$balance{ lc($b->{'provider'} // '') } = $b;
		$balance{ lc($b->{'label'} // '') } = $b if defined $b->{'label'} && length $b->{'label'};
	}
	foreach my $row ( @out ) {
		my $b = $balance{ lc($row->{'provider'}) } || $balance{ lc($row->{'label'}) };
		next unless $b;
		$row->{'balance'} = {
			available => $b->{'available'},
			currency  => $b->{'currency'},
			note      => $b->{'note'},
		};
	}

	# The chart's inferred outside-JawnOS line: a balance that fell with no
	# ledger tokens beside it. The chart folds it into each provider's window as
	# an `external` total and a `__external` role; the panel shows one house
	# line, so the windows are summed. It is optional, so the panel says nothing
	# when the chart has no inference.
	my $external;
	my $chart = eval { &subs::ai_balance_chart($report) };
	if (ref $chart eq 'HASH' && ref $chart->{'series'} eq 'ARRAY') {
		my %by_window;
		my $currency = '';
		foreach my $series ( @{ $chart->{'series'} } ) {
			next unless ref $series eq 'HASH';
			$currency = $series->{'currency'} if !length $currency && length($series->{'currency'} // '');
			my $windows = (ref $series->{'windows'} eq 'HASH') ? $series->{'windows'} : {};
			foreach my $window ( keys %{$windows} ) {
				my $w = $windows->{$window};
				next unless ref $w eq 'HASH';
				my $amount = $w->{'external'};
				if (!(defined $amount && $amount =~ /^-?\d+(?:\.\d+)?$/)) {
					$amount = 0;
					foreach my $role ( @{ (ref $w->{'roles'} eq 'ARRAY') ? $w->{'roles'} : [] } ) {
						next unless ref $role eq 'HASH' && (($role->{'role'} // '') eq '__external');
						my $cost = $role->{'cost'};
						$amount += $cost if defined $cost && $cost =~ /^-?\d+(?:\.\d+)?$/;
					}
				}
				next unless $amount > 0;
				$by_window{$window} = ($by_window{$window} || 0) + $amount;
				$currency = $series->{'currency'} if !length $currency && length($series->{'currency'} // '');
			}
		}
		if (%by_window) {
			my $day = $by_window{'1d'} || 0;
			my $per_day = $by_window{'1w'} ? $by_window{'1w'} / 7 : $day;
			$external = {
				provider    => '__external',
				label       => 'Outside JawnOS (inferred)',
				currency    => $currency,
				consumption => $day,
				per_day     => $per_day,
				tokens      => 0,
			};
		}
	}

	push @out, {
		provider   => '__all',
		label      => 'All providers',
		tokens_in  => $total->{'tokens_in'},
		tokens_out => $total->{'tokens_out'},
		tokens     => $total->{'tokens'},
		calls      => $total->{'calls'},
		share      => ($total->{'tokens'} > 0 ? 100 : 0),
		models     => [],
		all        => 1,
	};

	return { rows => \@out, total => $total, external => $external };
}

# The History panel: one row per day. The daily rollup is the long-lived
# source; a day it does not cover falls back to the house's ai_budget total,
# which has the tokens but no calls or model.
sub intelligence_history {
	my ($range) = @_;
	$range = '7d' unless defined $range && exists $RANGE_DAYS->{$range};
	my $span = $RANGE_DAYS->{$range};
	my $now = &subs::rightNow();
	my $since_day = $span ? $_day_key->($now - ($span - 1) * 86400000) : '0000-00-00';

	my (%bucket, @order);
	my $_add_day = sub {
		my ($day) = @_;
		return $bucket{$day} if $bucket{$day};
		$bucket{$day} = { day => $day, tokens => 0, calls => 0, apps => {}, roles => {}, providers => {}, source => '' };
		push @order, $day;
		return $bucket{$day};
	};

	if ($span) {
		for (my $i = $span - 1; $i >= 0; $i--) {
			$_add_day->($_day_key->($now - $i * 86400000));
		}
	}

	# The rollup first.
	my $daily = $_rows->(
		'select day, app, role, provider, sum(tokens_in + tokens_out) as tokens, sum(calls) as calls '
		. 'from ai_spend_daily where day >= ? group by day, app, role, provider',
		$since_day,
	);
	foreach my $r ( @{$daily} ) {
		my $day = $r->{'day'} // '';
		next unless length $day;
		my $b = $_add_day->($day);
		my $tokens = $_num->($r->{'tokens'});
		$b->{'tokens'} += $tokens;
		$b->{'calls'}  += $_num->($r->{'calls'});
		my $app = $r->{'app'} // '';
		my $role = $r->{'role'} // '';
		my $provider = $r->{'provider'} // '';
		$b->{'apps'}->{$app} = ($b->{'apps'}->{$app} || 0) + $tokens if length $app;
		$b->{'roles'}->{$role} = ($b->{'roles'}->{$role} || 0) + $tokens if length $role;
		$b->{'providers'}->{$provider} = ($b->{'providers'}->{$provider} || 0) + $tokens if length $provider;
		$b->{'source'} = 'daily';
	}

	# No rollup yet: the ledger holds the same days, as far back as it is kept.
	if (!@{$daily}) {
		my $ledger = $_rows->(
			'select substr(minute, 1, 10) as day, app, role, provider, '
			. 'sum(tokens_in + tokens_out) as tokens, sum(calls) as calls '
			. 'from ai_spend where minute >= ? group by day, app, role, provider',
			$since_day,
		);
		if (!@{$ledger}) {
			$ledger = $_rows->(
				'select substr(minute, 1, 10) as day, provider, '
				. 'sum(tokens_in + tokens_out) as tokens, sum(calls) as calls '
				. 'from ai_spend where minute >= ? group by day, provider',
				$since_day,
			);
		}
		foreach my $r ( @{$ledger} ) {
			my $day = $r->{'day'} // '';
			next unless length $day;
			my $b = $_add_day->($day);
			my $tokens = $_num->($r->{'tokens'});
			$b->{'tokens'} += $tokens;
			$b->{'calls'}  += $_num->($r->{'calls'});
			my $app = $r->{'app'} // '';
			my $role = $r->{'role'} // '';
			my $provider = $r->{'provider'} // '';
			$b->{'apps'}->{$app} = ($b->{'apps'}->{$app} || 0) + $tokens if length $app;
			$b->{'roles'}->{$role} = ($b->{'roles'}->{$role} || 0) + $tokens if length $role;
			$b->{'providers'}->{$provider} = ($b->{'providers'}->{$provider} || 0) + $tokens if length $provider;
			$b->{'source'} = 'ledger';
		}
	}

	# The house's own daily total fills any day the rollup and ledger do not.
	my $budget = $_rows->(
		'select day, sum(tokens) as tokens from ai_budget where day >= ? group by day',
		$since_day,
	);
	foreach my $r ( @{$budget} ) {
		my $day = $r->{'day'} // '';
		next unless length $day;
		my $b = $_add_day->($day);
		next if $b->{'source'};
		$b->{'tokens'} = $_num->($r->{'tokens'});
		$b->{'source'} = 'budget';
	}

	# "All" has no pre-filled days, so only the days that actually happened.
	if (!$span) {
		@order = grep { $bucket{$_}->{'source'} } @order;
	}

	my @rows;
	my %totals = (tokens => 0, calls => 0);
	foreach my $day ( reverse @order ) {
		my $entry = $bucket{$day};
		my ($top_app) = sort { $entry->{'apps'}->{$b} <=> $entry->{'apps'}->{$a} } grep { length } keys %{ $entry->{'apps'} };
		my ($top_role) = sort { $entry->{'roles'}->{$b} <=> $entry->{'roles'}->{$a} } grep { length } keys %{ $entry->{'roles'} };
		my ($top_provider) = sort { $entry->{'providers'}->{$b} <=> $entry->{'providers'}->{$a} } grep { length } keys %{ $entry->{'providers'} };
		$totals{'tokens'} += $entry->{'tokens'};
		$totals{'calls'}  += $entry->{'calls'};
		push @rows, {
			day          => $day,
			tokens       => $entry->{'tokens'},
			calls        => $entry->{'calls'},
			top_agent    => (defined $top_role && length $top_role) ? ($ROLE_GROUP->{$top_role} || $top_role) : ($top_app // ''),
			top_provider => $top_provider // '',
			source       => $entry->{'source'},
		};
	}

	return { range => $range, days => \@rows, totals => \%totals };
}

# The newest calls, newest first, for the Overview's tail.
sub intelligence_recent {
	my ($limit) = @_;
	$limit = 20 unless defined $limit && $limit =~ /^\d+$/ && $limit > 0 && $limit <= 200;
	my $rows = $_rows->(
		'select provider, model, role, minute, tokens_in, tokens_out, calls '
		. 'from ai_spend order by minute desc limit ' . int($limit),
	);
	my @out;
	my %provider_label = map { $_->[0] => $_->[1] } @KNOWN_PROVIDERS;
	foreach my $r ( @{$rows} ) {
		my $provider = $r->{'provider'} // '';
		my $role = $r->{'role'} // '';
		push @out, {
			provider       => $provider,
			provider_label => ($provider_label{$provider} || $_pretty_provider->($provider)),
			model          => $r->{'model'} // '',
			role           => $role,
			role_label     => ($ROLE_GROUP->{$role} || $role),
			minute         => $r->{'minute'} // '',
			tokens_in      => $_num->($r->{'tokens_in'}),
			tokens_out     => $_num->($r->{'tokens_out'}),
			calls          => $_num->($r->{'calls'}),
		};
	}
	return \@out;
}

1;
