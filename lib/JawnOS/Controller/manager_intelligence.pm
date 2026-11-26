package Manager;

# GET /manager/intelligence
#
# The Intelligence app: a read-only view of the AI token ledger, the daily
# rollup, the house's daily purse, the cached provider balances and the
# evaluation schedule. It reads; it has no write route and writes no row. The
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

	my $content = $c->render_to_string(template => 'apps/intelligence', data => $data);
	my $contents = &window_maker({
		user_agent => $c->param('user_agent'),
		app => 'intelligence',
		title => 'Intelligence',
		contents => $content,
	}, $c->param('timestamp'));
	$c->render(json => { window => $contents });
}

1;
