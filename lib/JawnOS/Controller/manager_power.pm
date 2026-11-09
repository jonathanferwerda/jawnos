package Manager;

# manager_power: the Power app and the taskbar's battery read.
#
# The status route is deliberately outside the /manager/power prefix: it is
# read-only, and the taskbar widget must work for a resident session too. The
# window and the three writes live under /manager/power, which the tier table
# keeps at citizen - the same desk the Leave menu's power choices use.
use strict;
use warnings;
use utf8;

# GET /manager/power
sub action_53010 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = $c->render_to_string(
		template => 'apps/power',
		status => eval { &subs::power_status() },
	);
	my $window = &window_maker({
		user_agent => $c->param('user_agent'),
		app => 'power',
		contents => $contents,
	}, $timestamp);
	$c->render(json => { window => $window });
}

# GET /manager/power_status
sub action_53011 {
	my $c = shift;
	$c->render(json => eval { &subs::power_status() } || { ok => 0, error => 'the power reading failed' });
}

# POST /manager/power/plan
#
# Saving a source's plan is also the moment to use it, when that source is the
# one the machine is on. The other source's plan is simply stored for the day
# the cable changes.
sub action_53012 {
	my $c = shift;
	my $result = eval {
		&subs::power_plan_set(
			$c->param('source'),
			$c->param('plan'),
			$c->param('limit'),
		);
	};
	$c->render(json => $result || { ok => 0, error => 'the plan could not be saved' });
}

# POST /manager/power/auto
sub action_53013 {
	my $c = shift;
	my $on = ($c->param('auto') || '') =~ /^(?:1|yes|on|true)$/i ? 1 : 0;
	$c->render(json => eval { &subs::power_auto_set($on) } || { ok => 0, error => 'the setting could not be saved' });
}

# POST /manager/power/apply
sub action_53014 {
	my $c = shift;
	$c->render(json => eval { &subs::power_apply_current() } || { ok => 0, error => 'the plan could not be applied' });
}

1;
