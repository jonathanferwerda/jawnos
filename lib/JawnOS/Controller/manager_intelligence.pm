package Manager;

# GET /manager/intelligence
#
# The Intelligence app: the AI token ledger, the daily rollup, the house's daily
# purse, the cached provider balances, the evaluation schedule, and the Guide's
# rules and runtime commands. It reads the panels and writes only the evaluation
# cadence a person changes here; the cadence route is the only POST and it calls
# the same schedule arranger the app's own controls use, so the setting and the
# queue cannot drift. The window draws all six pills at once - the browser swaps
# panels - so one request answers the whole window, and the History ranges are
# each drawn server-side rather than asked for again per pill. The Rules pill's
# lists are read here as-is; the browser writes them back through the shared
# setting setter, so an entry the panel does not understand rides along.
use strict;
use warnings;
use utf8;
use Mojo::JSON qw(decode_json);

sub action_92001 {
	my $c = shift;

	my %history;
	foreach my $range (qw(24h 7d 30d 90d 1y all)) {
		$history{$range} = eval { &subs::intelligence_history($range) }
			|| { range => $range, days => [], totals => { tokens => 0, calls => 0 } };
	}

	# Read the panels once. The Overview's short agent/evaluation/recent lists
	# are cut from the same reads the dedicated pills use, so one window does
	# not ask the ledger and Minion twice.
	my $agents      = eval { &subs::intelligence_agents() } || [];
	my $evaluations = eval { &subs::intelligence_evaluations() } || [];
	my $recent      = eval { &subs::intelligence_recent(25) } || [];
	my $data = {
		summary     => eval { &subs::intelligence_summary($agents, $evaluations, $recent) } || {},
		agents      => $agents,
		evaluations => $evaluations,
		providers   => eval { &subs::intelligence_providers() } || { rows => [], total => {}, external => undef },
		history     => \%history,
		recent      => $recent,
	};

	# The Guide's two editable lists are house settings. They are read raw so
	# the Rules pill can draw every entry as a readable row; the array is passed
	# through as-is, because an entry the panel does not understand must survive
	# an edit or a delete somewhere else.
	my $rules_raw = eval { &subs::setting_grabber({ app => '__president', setting => 'guide_rules', device => 'all' }) } || '';
	my $rules = eval { decode_json($rules_raw) } || [];
	$rules = [] unless ref $rules eq 'ARRAY';
	my $verbs_raw = eval { &subs::setting_grabber({ app => '__president', setting => 'guide_verbs', device => 'all' }) } || '';
	my $verbs = eval { decode_json($verbs_raw) } || [];
	$verbs = [] unless ref $verbs eq 'ARRAY';
	$data->{'rules'} = $rules;
	$data->{'verbs'} = $verbs;

	my $content = $c->render_to_string(template => 'apps/intelligence', intel => $data);
	my $contents = &window_maker({
		user_agent => $c->param('user_agent'),
		app => 'intelligence',
		title => 'Intelligence',
		contents => $content,
	}, $c->param('timestamp'));
	$c->render(json => { window => $contents });
}

# POST /manager/intelligence/cadence
#
# Change one scope's frequency from the Evaluations table. The setting is the
# wish and the schedule is the mechanism, so this saves the weekdays (when the
# request carries them), applies the cadence and answers with what now exists
# rather than what was asked for. One request means a weekday change cannot be
# saved without the cron being rebuilt from it.
sub action_92002 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app')) || '__president';
	my $cadence = $c->param('cadence');
	$cadence = 'off' unless defined $cadence && length $cadence;
	my $days_param = $c->param('days');
	my $write_error;
	my $write_value;
	if (defined $days_param) {
		my %seen;
		my @keep = sort { $a <=> $b } grep { !$seen{$_}++ } grep { /^[0-6]$/ } split /,/, $days_param;
		$write_value = @keep ? join(',', @keep) : 'none';
		# Read the setting back before arranging the schedule. A failed write must
		# stop here: applying the cadence against the old days is exactly the drift
		# the single request exists to prevent.
		my $saved = eval {
			&subs::setting_setter({ app => $app, setting => 'nightly_evaluation_days', value => $write_value });
			&subs::setting_grabber({ app => $app, setting => 'nightly_evaluation_days' });
		};
		if ($@ || !defined $saved) { $write_error = 'Could not save the evaluation days.'; }
		else {
			my @saved = sort { $a <=> $b } grep { /^[0-6]$/ } split /,/, $saved;
			my $saved_value = @saved ? join(',', @saved) : 'none';
			$write_error = 'Could not save the evaluation days.' unless $saved_value eq $write_value;
		}
	}
	# The days answer is the normalised wish the row should show: a blank legacy
	# value is every day, and the literal none is no day at all.
	my $current_days = eval { &subs::setting_grabber({ app => $app, setting => 'nightly_evaluation_days' }) };
	my $none = (defined $current_days && $current_days =~ /^\s*none\s*$/i) ? 1 : 0;
	my @shown = $none ? () : sort { $a <=> $b } grep { /^[0-6]$/ } split /,/, (defined $current_days ? $current_days : '');
	@shown = ( 0 .. 6 ) unless $none || @shown;
	my $days_answer = @shown ? join(',', @shown) : 'none';
	if ($write_error) {
		$c->render(json => {
			ok      => 0,
			error   => $write_error,
			app     => $app,
			cadence => &subs::evaluation_cadence($app),
			days    => $days_answer,
		});
		return;
	}
	my $schedule = &subs::evaluation_cadence_apply($app, $cadence);
	# After applying, the stored days are the ones the fresh schedule read.
	my $after = eval { &subs::setting_grabber({ app => $app, setting => 'nightly_evaluation_days' }) };
	my $after_none = (defined $after && $after =~ /^\s*none\s*$/i) ? 1 : 0;
	my @after_days = $after_none ? () : sort { $a <=> $b } grep { /^[0-6]$/ } split /,/, (defined $after ? $after : '');
	@after_days = ( 0 .. 6 ) unless $after_none || @after_days;
	$c->render(json => {
		ok       => 'yes',
		app      => $app,
		cadence  => &subs::evaluation_cadence($app),
		days     => (@after_days ? join(',', @after_days) : 'none'),
		next_run => $schedule ? $schedule->{'next_run'} : undef,
	});
}

# POST /manager/intelligence/spread
#
# The Evaluations panel's Spread button: give every timed scope its own slot
# across the week, the month and the quiet window. The domain writes the
# settings and rebuilds each scope's Minion schedule, so the answer is a count
# rather than a second read: the window the button runs in refreshes itself.
sub action_92003 {
	my $c = shift;
	my $result = eval { &subs::intelligence_spread() };
	if ($@) {
		$c->render(json => { ok => 0, error => &subs::ui('Could not spread the evaluations.') });
		return;
	}
	my $n = (ref $result eq 'HASH' && defined $result->{'spread'}) ? $result->{'spread'} : 0;
	$c->render(json => {
		ok      => 'yes',
		spread  => $n,
		summary => &subs::ui('Spread') . ' ' . $n . ' ' . &subs::ui('evaluations'),
	});
}

1;
