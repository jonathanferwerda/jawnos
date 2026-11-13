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

# POST /manager/power/sleep
#
# The sleep and display block saves as one row because the four choices are
# written together: one logind drop-in and one screen timer.
sub action_53015 {
	my $c = shift;
	my %params;
	for my $key (qw(screen_timeout sleep_timeout lid_action sleep_type)) {
		my $value = $c->param($key);
		$params{$key} = $value if defined $value && length $value;
	}
	# A plan names the profile whose block is being edited; without it the
	# save is the shared fallback block, exactly as before.
	my $plan = $c->param('plan');
	$params{'plan'} = $plan if defined $plan && length $plan;
	my $result = eval { &subs::power_sleep_set(\%params) };
	$c->render(json => $result || { ok => 0, error => 'the sleep settings could not be saved' });
}

# POST /manager/power/sleep_now
sub action_53016 {
	my $c = shift;
	my $result = eval { &subs::power_sleep_now($c->param('type')) };
	$c->render(json => $result || { ok => 0, error => 'the machine could not be put to sleep' });
}

# POST /manager/power/charge
#
# The battery's charge ceiling. A pack without the attribute answers
# supported = 0, and the app hides the row rather than offering a dead control.
sub action_53017 {
	my $c = shift;
	my $result = eval { &subs::power_charge_set($c->param('end')) };
	$c->render(json => $result || { ok => 0, error => 'the charge limit could not be saved' });
}

# POST /manager/power/manage
#
# The master switch beside the management line. On applies the saved plan at
# once; off only stores the setting, and the tick leaves the kernel alone.
sub action_53018 {
	my $c = shift;
	my $on = ($c->param('manage') || '') =~ /^(?:1|yes|on|true)$/i ? 1 : 0;
	my $result = eval { &subs::power_manage_set($on) };
	$c->render(json => $result || { ok => 0, error => 'the setting could not be saved' });
}

1;
