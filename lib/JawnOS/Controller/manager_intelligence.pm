package Manager;

# GET /manager/intelligence
#
# The Intelligence app: the AI token ledger, the daily rollup, the house's daily
# purse, the cached provider balances and the evaluation schedule. It reads the
# panels and writes only the evaluation cadence a person changes here; the
# cadence route is the only POST and it calls the same schedule arranger the
# app's own controls use, so the setting and the queue cannot drift. The
# window draws all five pills at once - the browser swaps panels - so one
# request answers the whole window, and the History ranges are each drawn
# server-side rather than asked for again per pill.
use strict;
use warnings;
use utf8;

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
	my $days = $c->param('days');
	if (defined $days) {
		my %seen;
		my @keep = grep { !$seen{$_}++ } grep { /^[0-6]$/ } split /,/, $days;
		my $value = @keep ? join(',', @keep) : 'none';
		eval { &subs::setting_setter({ app => $app, setting => 'nightly_evaluation_days', value => $value }) };
	}
	my $schedule = &subs::evaluation_cadence_apply($app, $cadence);
	$c->render(json => {
		ok       => 'yes',
		app      => $app,
		cadence  => &subs::evaluation_cadence($app),
		next_run => $schedule ? $schedule->{'next_run'} : undef,
	});
}

1;
