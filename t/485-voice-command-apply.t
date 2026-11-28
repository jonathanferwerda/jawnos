# tests-for: lib/JawnOS/Domain/Ai.pm lib/JawnOS/Domain/Loader.pm
# covers:    A spoken start/stop writes the toggle at the moment the person
#            asked (a watch RTC that lags the house used to make the settings
#            layer refuse the write as "older than the stored toggle"), reads
#            the row that write landed on rather than whichever peer row a
#            device-less read answers with, and never reports a refused write
#            as the requested state.

use strict;
use warnings;
no warnings 'once';
no warnings 'redefine';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

require(root() . '/lib/JawnOS/Domain/Ai.pm') unless defined &subs::voice_command_apply;

my $NOW = 1_700_000_500_000;
my $STALE = 1_700_000_330_000;   # the watch's clip stamp, ~3 minutes behind

sub run_apply {
	my ($write_result) = @_;
	my @sets;
	my @reads;
	my @appts;
	local *subs::rightNow = sub { return $NOW };
	# 'off' is the stale row another device synced in; a device-scoped read is
	# the only one that answers with what this write left behind.
	local *subs::settings_grabber = sub { return {} };
	local *subs::setting_grabber = sub {
		my $q = shift;
		push @reads, $q;
		return 'off' if ($q->{'setting'} || '') eq 'toggle' && !$q->{'device'} && !$q->{'app'};
		return 'on' if ($q->{'setting'} || '') eq 'toggle' && $q->{'device'};
		return undef;
	};
	local *subs::setting_setter = sub {
		my $q = shift;
		push @sets, $q;
		return $write_result ? $write_result->($q) : { %{$q}, device => 'laptop', refused => 0 };
	};
	local *subs::controller_builder = sub { return bless {}, 'FakeController' };
	local *subs::random_string_creator = sub { return 'uuid-0000000000000001' };
	local *subs::time_abbrev_translator = sub { return '30 minutes' };
	local *subs::ago_calc = sub { return 'created just now' };
	local *Manager::appointment_writer = sub { push @appts, $_[1] };
	local *Websocket::send = sub { return 1 };
	local *Websocket::console_command = sub { return '{}' };
	my $out = &subs::voice_command_apply('email test', 'on', { ts => $STALE, chip_id => 'watch-chip' });
	return ($out, \@sets, \@reads, \@appts);
}

# --- the write is NOW, not the clip's stale stamp --------------------------
{
	my ($out, $sets, $reads, $appts) = run_apply();
	is(scalar(@{$sets}), 1, 'a spoken command writes the app toggle once');
	is($sets->[0]{'value'}, 'on', 'with the asked-for value');
	is($sets->[0]{'timestamp'}, $NOW, 'stamped now, not with the clip\'s lagging RTC time');
	is($appts->[0]{'timestamp'}, $NOW, 'the appointment starts now too, so its outputs are not skipped as stale');
	is($out->{'state'}, 'on', 'the reply reports the state the write left behind');
	my ($toggle_read) = grep { ($_->{'setting'} || '') eq 'toggle' } @{$reads};
	ok($toggle_read && $toggle_read->{'device'}, 'and the read names the device the write landed on');
}

# --- a refused write is never reported as the asked-for state --------------
{
	my ($out) = run_apply(sub { return { app => 'email test', setting => 'toggle', value => 'on', device => 'laptop', refused => 1 } });
	is($out->{'state'}, 'off', 'a write the settings layer refused says the app is still off');
}

# --- a synced row with the other value cannot flip the reply ---------------
{
	my $reads;
	my @all;
	local *subs::rightNow = sub { return $NOW };
	local *subs::settings_grabber = sub { return {} };
	local *subs::setting_grabber = sub {
		my $q = shift;
		push @all, $q;
		# the device-less read answers with another machine's stale "off";
		# only the scoped read sees this write's "on".
		return 'on' if $q->{'device'};
		return 'off' if ($q->{'setting'} || '') eq 'toggle';
		return undef;
	};
	local *subs::setting_setter = sub { my $q = shift; return { %{$q}, device => 'laptop' } };
	local *subs::controller_builder = sub { return bless {}, 'FakeController' };
	local *subs::random_string_creator = sub { return 'uuid' };
	local *subs::time_abbrev_translator = sub { return '30 minutes' };
	local *subs::ago_calc = sub { return 'now' };
	local *Manager::appointment_writer = sub { };
	local *Websocket::send = sub { return 1 };
	local *Websocket::console_command = sub { return '{}' };
	my $out = &subs::voice_command_apply('email test', 'on', { ts => $STALE });
	is($out->{'state'}, 'on', 'the row this device just wrote decides the reply, not a peer\'s stale row');
	$reads = scalar(grep { ($_->{'setting'} || '') eq 'toggle' && $_->{'device'} } @all);
	is($reads, 1, 'and that is the only toggle read');
}

done_testing();
