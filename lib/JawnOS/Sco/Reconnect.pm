package JawnOS::Sco::Reconnect;

# The phone walked out of range and came back with its Bluetooth link gone.
#
# Nothing retries that on a quiet table: the ACL was dropped, so the next call
# finds no Hands-Free audio at all and the caller hears nothing. While the
# gateway waits for the next call this asks the phone to connect again - only
# when the link is really down, and on a backoff so a phone that is still away
# is not asked every few seconds.
#
# The runner is a parameter so the decision can be tested without a radio.
use strict;
use warnings;

sub new {
	my ($class, %args) = @_;
	return bless {
		peer => $args{'peer'} || '',
		run => $args{'run'} || \&bluetoothctl,
		wait => $args{'wait'} || 30,
		max_wait => $args{'max_wait'} || 300,
		last => 0,
		backoff => 0,
		tries => 0,
	}, $class;
}

# `bluetoothctl info|connect <addr>`. A timeout bounds it: a radio that is
# there but not answering must not wedge the worker that keeps the gateway
# armed.
sub bluetoothctl {
	my ($cmd, $peer) = @_;
	my $out = `timeout 10 bluetoothctl $cmd $peer 2>&1`;
	return defined $out ? $out : '';
}

sub peer { return $_[0]->{'peer'} }

# One look. '' when there is no address to ask about; 'too soon' while the
# backoff runs; 'connected' when the link is already up; 'reconnected' when
# asking brought it back; 'unreachable' when it did not.
sub tick {
	my ($self, $now) = @_;
	$now = time unless defined $now;
	return '' unless $self->{'peer'} =~ /^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$/;
	return 'too soon' if $self->{'last'} && $now - $self->{'last'} < $self->{'backoff'};
	$self->{'last'} = $now;
	my $info = $self->{'run'}->('info', $self->{'peer'});
	if (defined $info && $info =~ /Connected:\s+yes/i) {
		$self->{'backoff'} = 0;
		$self->{'tries'} = 0;
		return 'connected';
	}
	my $out = $self->{'run'}->('connect', $self->{'peer'});
	if (defined $out && $out =~ /Connection successful|Connected:\s+yes/i) {
		$self->{'backoff'} = 0;
		$self->{'tries'} = 0;
		return 'reconnected';
	}
	$self->{'tries'}++;
	my $wait = $self->{'wait'} * (2 ** ($self->{'tries'} - 1));
	$self->{'backoff'} = $wait > $self->{'max_wait'} ? $self->{'max_wait'} : $wait;
	return 'unreachable';
}

1;
