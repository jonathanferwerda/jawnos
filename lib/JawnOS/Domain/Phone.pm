package subs;

# The phone's reception settings, read the same way everywhere.
#
# These live in the domain layer rather than on the Manager because a worker
# needs them without loading the whole panel: perl/Reception.pl arms the
# gateway from them with no request in flight. The IVR belongs to the house,
# not to the device that happened to save it - the phone turns it on, the
# gateway machine plays it - so the rows are read and written house-wide, with
# the older per-device rows still answering as a fallback.
use strict;
use warnings;
use Mojo::JSON qw(decode_json);

sub phone_ivr_defaults {
	return {
		enabled   => 'no',
		machine   => '',
		route     => 'unknown',
		voice     => &subs::say_default_voice(),
		# the adapter the phone must send call audio to, by Bluetooth name
		bluetooth => 'jawn-gateway',
		greeting  => &subs::ui('This automated system records calls.'),
		prompt    => &subs::ui('Please say your name after the tone.'),
		voicemail => &subs::ui('Please leave a message after the tone.'),
		thanks    => &subs::ui('Thank you.'),
		flows     => &subs::phone_ivr_flow_defaults('unknown'),
	};
}

# The six call-flow buckets. `route` is the older three-way knob; when a phone
# has no saved matrix, the matrix is derived from it so an existing phone keeps
# behaving the same way.
sub phone_ivr_flow_defaults {
	my ($route) = @_;
	my %flow = (
		unknown     => 'ivr',
		blacklisted => 'reject',
		enemy       => 'reject',
		stranger    => 'ivr',
		friend      => 'ring',
		self        => 'ring',
	);
	if (($route || '') eq 'off') {
		$flow{$_} = 'ring' for qw(unknown stranger friend self);
	}
	elsif (($route || '') eq 'all') {
		$flow{$_} = 'ivr' for qw(unknown stranger friend self);
	}
	return \%flow;
}

sub phone_ivr_flow_clean {
	my ($flows, $route) = @_;
	my $base = &subs::phone_ivr_flow_defaults($route);
	my %clean = %{$base};
	if (ref $flows eq 'HASH') {
		foreach my $bucket (qw(unknown blacklisted self friend stranger enemy)) {
			my $action = $flows->{$bucket};
			next unless defined $action && $action =~ /^(?:ring|ivr|voicemail|reject)$/;
			$clean{$bucket} = $action;
		}
	}
	return \%clean;
}

# One setting, the house row first and this device's older row second.
sub phone_ivr_grab {
	my ($setting) = @_;
	my $value = &subs::setting_grabber({ app => 'phone', setting => $setting, device => 'all', benign => 1 });
	if (!defined $value || !length $value) {
		$value = &subs::setting_grabber({ app => 'phone', setting => $setting, benign => 1 });
	}
	return defined $value ? $value : '';
}

sub phone_ivr_settings {
	my $settings = &subs::phone_ivr_defaults();
	foreach my $key ( keys %{$settings} ) {
		next if $key eq 'flows';
		my $value = &subs::phone_ivr_grab('ivr_' . $key);
		$settings->{$key} = $value if length $value;
	}
	$settings->{'enabled'} = ($settings->{'enabled'} eq 'yes') ? 'yes' : 'no';
	$settings->{'route'} = 'unknown' unless $settings->{'route'} =~ /^(?:unknown|all|off)$/;
	my %voices = map { $_->{'value'} => 1 } &subs::say_voices();
	$settings->{'voice'} = &subs::say_default_voice() unless $voices{ $settings->{'voice'} };
	my $stored_flows = &subs::phone_ivr_grab('ivr_flows');
	my $flows = eval { decode_json($stored_flows) } if length $stored_flows;
	$settings->{'flows'} = &subs::phone_ivr_flow_clean($flows, $settings->{'route'});
	return $settings;
}

1;
