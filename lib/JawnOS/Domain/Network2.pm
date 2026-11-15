package subs;

# Network2: the Network app's management switch.
#
# Network.pm reads the topology (interfaces, peers, BLE); this module owns the
# one thing that writes: a saved addressing profile per network, applied through
# scripts/jawnos_network.pl. The switch is the same shape as Power's: a setting
# in the cache table, an applied row that makes the minute tick idempotent, and
# a takeover ledger for the daemons JawnOS stopped, so an uncheck, a quit or a
# crash puts the system's own manager back.
#
# The helper is the only writer. No SSID, interface name or address from a
# request reaches a shell: the profile is validated here and then handed to the
# helper as an argument list.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use Cwd ();
use File::Slurp qw(read_file write_file);
use Mojo::JSON qw(decode_json encode_json);
use Socket qw(AF_INET AF_INET6 inet_pton);

# A DNS list arrives from a form (comma or space separated) or from a saved
# row (an array). Both become the same array of address strings.
my $network_dns_list = sub {
	my ($dns) = @_;
	my @list;
	if (ref $dns eq 'ARRAY') {
		@list = map { defined $_ ? $_ : '' } @{$dns};
	}
	elsif (defined $dns) {
		@list = split /[,\s]+/, $dns;
	}
	@list = grep { length } @list;
	return \@list;
};

# The two families the helper accepts. inet_pton rejects a hostname, so a name
# can never become part of a networkd unit or an nmcli setting.
my $network_ip_family = sub {
	my ($ip) = @_;
	return 0 unless defined $ip && length $ip && length($ip) <= 45;
	return 4 if eval { inet_pton(AF_INET, $ip) };
	return 6 if eval { inet_pton(AF_INET6, $ip) };
	return 0;
};

# The interface and SSID rules the helper uses. Kept here so a bad profile is
# refused before the helper is asked, rather than becoming an error later.
my $network_interface_ok = sub {
	my ($name) = @_;
	return 0 unless defined $name;
	return $name =~ /\A[A-Za-z0-9_.:-]{1,32}\z/ ? 1 : 0;
};

my $network_ssid_ok = sub {
	my ($ssid) = @_;
	return 0 unless defined $ssid;
	return 0 if length($ssid) < 1 || length($ssid) > 32;
	return 0 if $ssid =~ /[\x00-\x1f\x7f]/;
	return 1;
};

# The connected target the tick works on: a wifi interface with an SSID wins,
# otherwise a wired interface whose link is up.
my $network_watch_target = sub {
	my ($interfaces) = @_;
	my @list = grep { ref $_ eq 'HASH' } (ref $interfaces eq 'ARRAY' ? @{$interfaces} : ());
	for my $entry (@list) {
		my $kind = lc($entry->{'kind'} // '');
		$kind = 'wifi' if !$kind && $entry->{'wireless'};
		next unless $kind eq 'wifi';
		my $ssid = $entry->{'ssid'} // '';
		next unless length $ssid;
		return { %{$entry}, kind => 'wifi' };
	}
	for my $entry (@list) {
		my $kind = lc($entry->{'kind'} // '');
		$kind = 'ethernet' if !$kind && !$entry->{'wireless'};
		next unless $kind eq 'ethernet';
		next unless ($entry->{'state'} // '') eq 'up';
		return { %{$entry}, kind => 'ethernet' };
	}
	return undef;
};

# The profile that governs a live target: the one saved for its key, otherwise
# the default addressing block. The returned block always has a method and a
# DNS list, so applying it is one shape.
my $network_effective_profile = sub {
	my ($config, $kind, $key, $interface) = @_;
	my $profile = &network_profile_for($config, $kind, $key);
	return $profile if $profile;
	my $default = ref $config->{'default'} eq 'HASH' ? $config->{'default'} : {};
	my $candidate = &network_profile_clean({
		%{$default},
		kind => $kind,
		key => $key,
		interface => $interface,
	});
	return $candidate if $candidate;
	return {
		kind => $kind,
		key => $key,
		ssid => $kind eq 'wifi' ? ($key =~ /^wifi:(.*)$/s ? $1 : '') : '',
		interface => $interface // '',
		method => 'dhcp',
		address => '',
		prefix => 0,
		gateway => '',
		dns => [],
	};
};

sub network_default_config {
	return {
		manage => 0,
		auto => 1,
		takeover => 1,
		profiles => {},
		default => { method => 'dhcp', dns => [] },
	};
}

# One saved network, or undef when it would not be safe to hand to the helper.
# The key is authoritative: it is rebuilt from the kind and the SSID/interface,
# so a caller cannot store two names for the same network.
sub network_profile_clean {
	my ($profile) = @_;
	return undef unless ref $profile eq 'HASH';
	my $kind = lc($profile->{'kind'} // '');
	my $key = defined $profile->{'key'} ? '' . $profile->{'key'} : '';
	my $ssid = $profile->{'ssid'};
	my $interface = $profile->{'interface'};
	$kind = $1 if !$kind && $key =~ /^(wifi|ethernet):/;
	$kind = 'wifi' if !$kind && defined $ssid;
	$kind = 'ethernet' if !$kind && defined $interface;
	return undef unless $kind eq 'wifi' || $kind eq 'ethernet';

	if ($kind eq 'wifi') {
		$ssid = $1 if !defined $ssid && $key =~ /^wifi:(.*)$/s;
		# A caller may hand the bare SSID as the key; the stored key is always
		# rebuilt with the kind prefix below.
		$ssid = $key if !defined $ssid && length $key;
		return undef unless $network_ssid_ok->($ssid);
		return undef if defined $interface && length $interface && !$network_interface_ok->($interface);
		$interface = '' unless defined $interface;
		$key = "wifi:$ssid";
	}
	else {
		$interface = $1 if !defined $interface && $key =~ /^ethernet:(.*)$/;
		$interface = $key if !defined $interface && length $key;
		return undef unless $network_interface_ok->($interface);
		$ssid = '';
		$key = "ethernet:$interface";
	}

	my $method = lc(defined $profile->{'method'} ? $profile->{'method'} : '');
	$method = 'dhcp' unless length $method;
	return undef unless $method eq 'dhcp' || $method eq 'static';

	my $dns = $network_dns_list->($profile->{'dns'});
	return undef if @{$dns} > 4;
	for my $server (@{$dns}) {
		return undef unless $network_ip_family->($server);
	}

	my $clean = {
		kind => $kind,
		key => $key,
		ssid => $ssid,
		interface => $interface,
		method => $method,
		address => '',
		prefix => 0,
		gateway => '',
		dns => $dns,
	};
	if ($method eq 'static') {
		my $address = defined $profile->{'address'} ? '' . $profile->{'address'} : '';
		my $prefix = defined $profile->{'prefix'} ? '' . $profile->{'prefix'} : '';
		my $gateway = defined $profile->{'gateway'} ? '' . $profile->{'gateway'} : '';
		$address =~ s/^\s+|\s+$//g;
		$prefix =~ s/^\s+|\s+$//g;
		$gateway =~ s/^\s+|\s+$//g;
		return undef unless $network_ip_family->($address) == 4;
		return undef unless $prefix =~ /\A\d{1,2}\z/ && $prefix >= 1 && $prefix <= 32;
		return undef if length($gateway) && $network_ip_family->($gateway) != 4;
		$clean->{'address'} = $address;
		$clean->{'prefix'} = $prefix + 0;
		$clean->{'gateway'} = $gateway;
	}
	return $clean;
}

sub network_profile_valid {
	return ref &network_profile_clean($_[0]) eq 'HASH' ? 1 : 0;
}

sub network_config_clean {
	my ($config) = @_;
	my $clean = &network_default_config();
	return $clean unless ref $config eq 'HASH';
	$clean->{'manage'} = $config->{'manage'} ? 1 : 0 if exists $config->{'manage'};
	$clean->{'auto'} = $config->{'auto'} ? 1 : 0 if exists $config->{'auto'};
	$clean->{'takeover'} = $config->{'takeover'} ? 1 : 0 if exists $config->{'takeover'};

	# The default is addressing only, not a named network. It is cleaned through
	# the same rules by giving it a placeholder wired name.
	my $default = $config->{'default'};
	if (ref $default eq 'HASH') {
		my $probe = &network_profile_clean({
			%{$default},
			kind => 'ethernet',
			key => 'ethernet:default',
			interface => 'default',
		});
		if ($probe) {
			$clean->{'default'} = {
				method => $probe->{'method'},
				dns => $probe->{'dns'},
			};
			if ($probe->{'method'} eq 'static') {
				$clean->{'default'}->{'address'} = $probe->{'address'};
				$clean->{'default'}->{'prefix'} = $probe->{'prefix'};
				$clean->{'default'}->{'gateway'} = $probe->{'gateway'};
			}
		}
	}

	my $profiles = $config->{'profiles'};
	if (ref $profiles eq 'HASH') {
		for my $key (keys %{$profiles}) {
			my $entry = $profiles->{$key};
			next unless ref $entry eq 'HASH';
			my $stored = &network_profile_clean({ %{$entry}, key => $key });
			next unless $stored;
			$clean->{'profiles'}{ $stored->{'key'} } = $stored;
		}
	}
	return $clean;
}

sub network_config {
	my $file = $ENV{'JAWNOS_NETWORK_CONFIG_FILE'};
	if (defined $file && length $file) {
		my $text = eval { read_file($file) };
		my $stored = $text ? eval { decode_json($text) } : undef;
		return &network_config_clean($stored);
	}
	my $stored = &subs::cache_get({ app => 'network', context => 'config' });
	return &network_config_clean($stored);
}

sub network_config_save {
	my ($config) = @_;
	my $clean = &network_config_clean($config);
	my $file = $ENV{'JAWNOS_NETWORK_CONFIG_FILE'};
	if (defined $file && length $file) {
		eval { write_file($file, encode_json($clean)) };
		return $clean;
	}
	&subs::cache_set({ app => 'network', context => 'config', warranty => '-1y' }, $clean);
	return $clean;
}

sub network_last_applied {
	my $file = $ENV{'JAWNOS_NETWORK_STATE_FILE'};
	if (defined $file && length $file) {
		my $text = eval { read_file($file) };
		my $stored = $text ? eval { decode_json($text) } : undef;
		return ref $stored eq 'HASH' ? $stored : {};
	}
	my $stored = &subs::cache_get({ app => 'network', context => 'applied' });
	return ref $stored eq 'HASH' ? $stored : {};
}

sub network_last_applied_save {
	my ($state) = @_;
	my $file = $ENV{'JAWNOS_NETWORK_STATE_FILE'};
	if (defined $file && length $file) {
		eval { write_file($file, encode_json($state)) };
		return $state;
	}
	&subs::cache_set({ app => 'network', context => 'applied', warranty => '-1y' }, $state);
	return $state;
}

# Only dhcpcd and connman can race this app's address writes; a record for any
# other unit is ignored so a helper change cannot make us stop a stranger.
sub network_takeover_state {
	my $file = $ENV{'JAWNOS_NETWORK_TAKEOVER_FILE'};
	if (defined $file && length $file) {
		my $text = eval { read_file($file) };
		my $stored = $text ? eval { decode_json($text) } : undef;
		return ref $stored eq 'ARRAY' ? $stored : [];
	}
	my $stored = eval { &subs::cache_get({ app => 'network', context => 'takeover' }) };
	return ref $stored eq 'ARRAY' ? $stored : [];
}

sub network_takeover_state_save {
	my ($records) = @_;
	my @clean;
	my %seen;
	for my $record (ref $records eq 'ARRAY' ? @{$records} : ()) {
		next unless ref $record eq 'HASH';
		my $unit = $record->{'unit'} // '';
		next unless $unit =~ /^[A-Za-z0-9@._-]+$/ && !$seen{$unit};
		next unless $unit =~ /^(?:dhcpcd|connman)(?:[.@_-]|$)/;
		$seen{$unit} = 1;
		push @clean, { unit => $unit, enabled => $record->{'enabled'} ? 1 : 0 };
	}
	my $file = $ENV{'JAWNOS_NETWORK_TAKEOVER_FILE'};
	if (defined $file && length $file) {
		eval { write_file($file, encode_json(\@clean)) };
		return \@clean;
	}
	&subs::cache_set({ app => 'network', context => 'takeover', warranty => '-1y' }, \@clean);
	return \@clean;
}

sub network_boot_id {
	return $ENV{'JAWNOS_NETWORK_BOOT_ID'} if defined $ENV{'JAWNOS_NETWORK_BOOT_ID'};
	my $value = '';
	if (open(my $fh, '<', '/proc/sys/kernel/random/boot_id')) {
		$value = <$fh> // '';
		close $fh;
		$value =~ s/\s+$//;
	}
	return $value;
}

sub network_profile_for {
	my ($config, $kind, $key) = @_;
	$config = &network_config() unless ref $config eq 'HASH';
	my $profiles = ref $config->{'profiles'} eq 'HASH' ? $config->{'profiles'} : {};
	my $profile = $profiles->{$key};
	return &network_profile_clean($profile) if ref $profile eq 'HASH';
	return undef;
}

# Whether an applied row already holds the wanted addressing. Boot is compared
# separately by the tick: a row from an earlier kernel is stale no matter what
# it says.
sub network_applied_matches {
	my ($applied, $wanted, $interface) = @_;
	return 0 unless ref $applied eq 'HASH' && ref $wanted eq 'HASH';
	return 0 unless $applied->{'ok'};
	my $want_interface = defined $interface ? $interface : $wanted->{'interface'};
	if (defined $want_interface && length $want_interface) {
		return 0 unless (($applied->{'interface'} // '') eq $want_interface);
	}
	for my $field (qw(kind key method address gateway)) {
		next unless defined $wanted->{$field};
		return 0 unless (($applied->{$field} // '') eq ($wanted->{$field} // ''));
	}
	return 0 unless (($applied->{'prefix'} // 0) + 0) == (($wanted->{'prefix'} // 0) + 0);
	my $want_dns = $network_dns_list->($wanted->{'dns'});
	my $have_dns = $network_dns_list->($applied->{'dns'});
	return 0 unless join(',', @{$want_dns}) eq join(',', @{$have_dns});
	return 1;
}

# The helper is the only writer. A relative default resolves to an absolute
# path because a scoped sudoers rule can only name one.
sub network_command {
	my (@args) = @_;
	my $stdin;
	if (@args && ref $args[-1] eq 'HASH') {
		my $options = pop @args;
		$stdin = $options->{'stdin'};
	}
	my $script = $ENV{'JAWNOS_NETWORK_HELPER'} || 'scripts/jawnos_network.pl';
	return { ok => 0, error => 'the network helper is missing' } unless -e $script;
	$script = Cwd::abs_path($script) || $script;
	my @command = ($^X, $script, @args);
	if ($ENV{'JAWNOS_NETWORK_DRY_RUN'}) {
		return { ok => 1, dry_run => 1, command => \@command };
	}
	return &network_command_run(\@command, $stdin);
}

sub network_command_run {
	my ($command, $stdin) = @_;
	my $params = {
		name => 'network helper',
		stdin => $stdin,
		stdout => 'capture',
		stderr => 'inherit',
		warranty => '20s',
	};
	my $run = eval { &subs::subprocessor_command($command, $params) };
	return { ok => 0, error => 'the network helper could not start' }
		unless ref $run eq 'HASH' && $run->{'pid'};
	my $answer = eval { decode_json($run->{'output'} // '') };
	return $answer if ref $answer eq 'HASH';
	return { ok => 0, error => 'the network helper did not return a readable answer' };
}

# One write: apply the addressing block to a live interface and remember what
# was applied. The record is written even on failure so the tick can retry and
# the panel can say what went wrong.
sub network_apply_profile {
	my ($kind, $key, $interface, $profile) = @_;
	$kind = lc(defined $kind ? $kind : '');
	return { ok => 0, error => 'the network kind is not known' }
		unless $kind eq 'wifi' || $kind eq 'ethernet';
	my $candidate = {
		%{ ref $profile eq 'HASH' ? $profile : {} },
		kind => $kind,
		key => $key,
		interface => $interface,
	};
	$candidate->{'ssid'} = $1 if $kind eq 'wifi' && defined $key && $key =~ /^wifi:(.*)$/s;
	my $clean = &network_profile_clean($candidate);
	return { ok => 0, error => 'the network profile is not valid' } unless $clean;
	my $dns = join(',', @{ $clean->{'dns'} });
	my $helper_key = $kind eq 'wifi' ? $clean->{'ssid'} : $clean->{'interface'};
	my $answer = &network_command(
		'profile_apply', $kind, $helper_key, $clean->{'interface'},
		$clean->{'method'}, $clean->{'address'}, $clean->{'prefix'},
		$clean->{'gateway'}, $dns,
	);
	$answer = { ok => 0, error => 'the network helper did not answer' } unless ref $answer eq 'HASH';
	my $state = {
		at => &subs::rightNow(),
		boot => &network_boot_id(),
		kind => $kind,
		key => $clean->{'key'},
		interface => $clean->{'interface'},
		method => $clean->{'method'},
		address => $clean->{'address'},
		prefix => $clean->{'prefix'},
		gateway => $clean->{'gateway'},
		dns => $clean->{'dns'},
		ok => $answer->{'ok'} ? 1 : 0,
		error => $answer->{'error'} // '',
		stack => $answer->{'stack'} // '',
		changed => $answer->{'changed'} ? 1 : 0,
	};
	&network_last_applied_save($state);
	my $result = {
		%{$answer},
		kind => $kind,
		key => $clean->{'key'},
		interface => $clean->{'interface'},
		method => $clean->{'method'},
		address => $clean->{'address'},
		prefix => $clean->{'prefix'},
		gateway => $clean->{'gateway'},
		dns => $clean->{'dns'},
		applied => $state,
	};
	# A static address is the case a competing DHCP manager can overwrite, so
	# only then does JawnOS take the daemon over as well.
	$result->{'takeover'} = &network_takeover()
		if $clean->{'method'} eq 'static' && &network_config()->{'takeover'};
	return $result;
}

sub network_apply_current {
	my $config = &network_config();
	my $watch = &network_command('watch');
	return { ok => 0, error => $watch->{'error'} || 'the network could not be read' }
		unless ref $watch eq 'HASH' && $watch->{'ok'};
	my $target = $network_watch_target->($watch->{'interfaces'});
	return { ok => 1, skipped => 'no network' } unless $target;
	my $kind = $target->{'kind'};
	my $interface = $target->{'name'} // '';
	my $key = $kind eq 'wifi'
		? 'wifi:' . ($target->{'ssid'} // '')
		: 'ethernet:' . $interface;
	my $profile = $network_effective_profile->($config, $kind, $key, $interface);
	return &network_apply_profile($kind, $key, $interface, $profile);
}

# Apply one saved profile by name, whether or not its network is the live
# target. The panel's Apply button uses this; the tick still works from the
# effective profile of whatever is connected.
sub network_apply_saved {
	my ($kind, $key) = @_;
	$kind = lc(defined $kind ? $kind : '');
	$kind = $1 if !$kind && defined $key && $key =~ /^(wifi|ethernet):/;
	return { ok => 0, error => 'the network kind is not known' }
		unless $kind eq 'wifi' || $kind eq 'ethernet';
	my $profile = &network_profile_clean({ kind => $kind, key => $key });
	return { ok => 0, error => 'the network profile is not valid' } unless $profile;
	my $config = &network_config();
	my $stored = ref $config->{'profiles'} eq 'HASH' ? $config->{'profiles'}{ $profile->{'key'} } : undef;
	return { ok => 0, error => 'the network profile was not found' } unless ref $stored eq 'HASH';
	return &network_apply_profile(
		$stored->{'kind'} // $kind,
		$stored->{'key'} // $profile->{'key'},
		$stored->{'interface'} // '',
		$stored,
	);
}

# The minute turn. A boot change is applied even with automatic switching off;
# a competing daemon only makes a static profile re-apply; otherwise a changed
# network is automatic switching's job.
sub network_watch_tick {
	my $config = &network_config();
	return { ok => 1, skipped => 'system managed' } unless $config->{'manage'};
	my $watch = &network_command('watch');
	return { ok => 0, error => $watch->{'error'} || 'the network could not be read' }
		unless ref $watch eq 'HASH' && $watch->{'ok'};
	my $interfaces = ref $watch->{'interfaces'} eq 'ARRAY' ? $watch->{'interfaces'} : [];
	my $applied = &network_last_applied();
	my $boot = &network_boot_id();
	my $target = $network_watch_target->($interfaces);

	if ($target) {
		my $kind = $target->{'kind'};
		my $interface = $target->{'name'} // '';
		my $key = $kind eq 'wifi'
			? 'wifi:' . ($target->{'ssid'} // '')
			: 'ethernet:' . $interface;
		my $profile = $network_effective_profile->($config, $kind, $key, $interface);

		# A row from an earlier kernel is not evidence this boot holds anything.
		return &network_apply_profile($kind, $key, $interface, $profile)
			if length $boot && (($applied->{'boot'} // '') ne $boot);

		my $manager = &network_manager();
		my $competitors = ref $manager eq 'HASH' && ref $manager->{'competitors'} eq 'ARRAY'
			? $manager->{'competitors'} : [];
		return &network_apply_profile($kind, $key, $interface, $profile)
			if @{$competitors} && $profile->{'method'} eq 'static';

		my $live = {
			kind => $kind,
			key => $key,
			interface => $interface,
			method => $target->{'method'} // 'dhcp',
			address => $target->{'address'} // '',
			prefix => $target->{'prefix'} // 0,
			gateway => $target->{'gateway'} // '',
			dns => $target->{'dns'} // [],
		};
		my $live_matches = &network_applied_matches($applied, $live, $interface);
		my $profile_matches = &network_applied_matches($applied, $profile, $interface);
		unless ($config->{'auto'}) {
			return { ok => 1, skipped => 'already applied' }
				if $live_matches && $profile_matches;
			return { ok => 1, skipped => 'auto is off' };
		}
		return { ok => 1, skipped => 'already applied' }
			if $live_matches && $profile_matches;
		return &network_apply_profile($kind, $key, $interface, $profile);
	}

	# No live target. After a boot the wifi is usually disconnected while the
	# saved profile and its secret are still here; reconnect with that secret.
	my ($wireless) = grep {
		ref $_ eq 'HASH' && (($_->{'kind'} // '') eq 'wifi' || $_->{'wireless'})
	} @{$interfaces};
	my $profiles = ref $config->{'profiles'} eq 'HASH' ? $config->{'profiles'} : {};
	my @wifi_keys = sort grep { /^wifi:/ } keys %{$profiles};
	# Prefer the network last applied, not the alphabetically first one, when a
	# boot left the radio disconnected.
	if (($applied->{'kind'} // '') eq 'wifi' && ($applied->{'key'} // '') =~ /^wifi:/
		&& grep { $_ eq $applied->{'key'} } @wifi_keys) {
		@wifi_keys = ($applied->{'key'}, grep { $_ ne $applied->{'key'} } @wifi_keys);
	}
	if ($wireless && @wifi_keys) {
		return { ok => 1, skipped => 'auto is off' } unless $config->{'auto'};
		my $secrets = &network_command('secret_status');
		if (ref $secrets eq 'HASH' && $secrets->{'available'}) {
			my $key = $wifi_keys[0];
			my $profile = $network_effective_profile->($config, 'wifi', $key, $wireless->{'name'} // '');
			(my $ssid = $key) =~ s/^wifi://;
			my $joined = &network_command(
				'wifi_connect', $wireless->{'name'} // '', $ssid,
				$profile->{'method'}, $profile->{'address'}, $profile->{'prefix'},
				$profile->{'gateway'}, join(',', @{ $profile->{'dns'} }), 'use',
				{ stdin => '' },
			);
			return { %{$joined}, ok => 0, error => $joined->{'error'} || 'the wifi could not be rejoined' }
				unless ref $joined eq 'HASH' && $joined->{'ok'};
			return &network_apply_profile('wifi', $key, $wireless->{'name'} // '', $profile);
		}
	}
	return { ok => 1, skipped => 'no network' };
}

# The master switch. Turning it on applies the saved profile to the live
# network. Turning it off puts the system's credentials and auto-connect back;
# JawnOS address drop-ins are deliberately left alone - removing one is an
# explicit profile delete, so the person can see what was changed.
sub network_manage_set {
	my ($on) = @_;
	my $config = &network_config();
	$config->{'manage'} = $on ? 1 : 0;
	$config = &network_config_save($config);
	my $applied;
	my $release;
	if ($config->{'manage'}) {
		$applied = &network_apply_current();
	}
	else {
		$release = &network_release_takeover();
		my $secrets = &network_command('secrets_release');
		$release = {} unless ref $release eq 'HASH';
		$release->{'secrets'} = $secrets;
	}
	return { ok => 1, config => $config, applied => $applied, release => $release };
}

sub network_profile_set {
	my ($kind, $key, $interface, $method, $address, $prefix, $gateway, $dns) = @_;
	my $profile = &network_profile_clean({
		kind => $kind,
		key => $key,
		interface => $interface,
		method => $method,
		address => $address,
		prefix => $prefix,
		gateway => $gateway,
		dns => $dns,
	});
	return { ok => 0, error => 'the network profile is not valid' } unless $profile;
	my $config = &network_config();
	$config->{'profiles'} = {} unless ref $config->{'profiles'} eq 'HASH';
	$config->{'profiles'}{ $profile->{'key'} } = $profile;
	$config = &network_config_save($config);
	my $applied;
	if ($config->{'manage'}) {
		my $watch = &network_command('watch');
		if (ref $watch eq 'HASH' && $watch->{'ok'}) {
			my $target = $network_watch_target->($watch->{'interfaces'});
			if ($target) {
				my $live_key = $target->{'kind'} eq 'wifi'
					? 'wifi:' . ($target->{'ssid'} // '')
					: 'ethernet:' . ($target->{'name'} // '');
				$applied = &network_apply_profile($target->{'kind'}, $live_key, $target->{'name'} // '', $profile)
					if $live_key eq $profile->{'key'};
			}
		}
	}
	return { ok => 1, config => $config, profile => $profile, applied => $applied };
}

# The default block: the addressing and DNS a network gets when it has no saved
# profile of its own. It lives beside the profiles, not in them, because it is
# not a named network; the panel shows it as one row for "any network".
sub network_default_set {
	my ($method, $address, $prefix, $gateway, $dns) = @_;
	my $probe = &network_profile_clean({
		kind => 'ethernet',
		key => 'ethernet:default',
		interface => 'default',
		method => $method,
		address => $address,
		prefix => $prefix,
		gateway => $gateway,
		dns => $dns,
	});
	return { ok => 0, error => 'the default profile is not valid' } unless $probe;
	my $block = { method => $probe->{'method'}, dns => $probe->{'dns'} };
	if ($probe->{'method'} eq 'static') {
		$block->{'address'} = $probe->{'address'};
		$block->{'prefix'} = $probe->{'prefix'};
		$block->{'gateway'} = $probe->{'gateway'};
	}
	my $config = &network_config();
	$config->{'default'} = $block;
	$config = &network_config_save($config);
	my $applied;
	if ($config->{'manage'}) {
		my $watch = &network_command('watch');
		if (ref $watch eq 'HASH' && $watch->{'ok'}) {
			my $target = $network_watch_target->($watch->{'interfaces'});
			if ($target) {
				my $live_key = $target->{'kind'} eq 'wifi'
					? 'wifi:' . ($target->{'ssid'} // '')
					: 'ethernet:' . ($target->{'name'} // '');
				my $profiles = ref $config->{'profiles'} eq 'HASH' ? $config->{'profiles'} : {};
				$applied = &network_apply_profile($target->{'kind'}, $live_key, $target->{'name'} // '', $block)
					unless $profiles->{$live_key};
			}
		}
	}
	return { ok => 1, config => $config, default => $block, applied => $applied };
}

sub network_profile_delete {
	my ($kind, $key) = @_;
	my $config = &network_config();
	my $profiles = ref $config->{'profiles'} eq 'HASH' ? $config->{'profiles'} : {};
	my $profile = $profiles->{$key};
	return { ok => 0, error => 'the network profile was not found' } unless ref $profile eq 'HASH';
	delete $profiles->{$key};
	$config = &network_config_save($config);
	my $profile_kind = $kind || $profile->{'kind'};
	my $helper_key = $profile_kind eq 'wifi' ? $profile->{'ssid'} : $profile->{'interface'};
	my @args = ('profile_remove', $profile_kind, $helper_key);
	push @args, $profile->{'interface'}
		if defined $profile->{'interface'} && length $profile->{'interface'};
	my $removed = &network_command(@args);
	return { ok => 1, config => $config, removed => $removed };
}

# A takeover is a plain stop recorded with the enabled state each daemon had,
# so a release or the next start puts it back exactly as it was.
sub network_takeover {
	my $answer = &network_command('takeover');
	my $records = ref $answer eq 'HASH' && ref $answer->{'records'} eq 'ARRAY'
		? $answer->{'records'} : [];
	if (@{$records}) {
		my $ledger = &network_takeover_state();
		my %seen = map { ($_->{'unit'} // '') => 1 } grep { ref $_ eq 'HASH' } @{$ledger};
		for my $record (@{$records}) {
			next unless ref $record eq 'HASH';
			my $unit = $record->{'unit'} // '';
			next unless $unit =~ /^[A-Za-z0-9@._-]+$/ && !$seen{$unit};
			next unless $unit =~ /^(?:dhcpcd|connman)(?:[.@_-]|$)/;
			push @{$ledger}, { unit => $unit, enabled => $record->{'enabled'} ? 1 : 0 };
			$seen{$unit} = 1;
		}
		&network_takeover_state_save($ledger);
	}
	return $answer;
}

sub network_release_takeover {
	my $ledger = &network_takeover_state();
	return { ok => 1, released => 0, units => [], restored => [] } unless @{$ledger};
	my $answer = &network_command('restore', encode_json($ledger));
	&network_takeover_state_save([]) if ref $answer eq 'HASH' && $answer->{'ok'};
	return {
		%{ ref $answer eq 'HASH' ? $answer : { ok => 0, error => 'the network daemons could not be restored' } },
		released => scalar @{$ledger},
		units => [ map { $_->{'unit'} } @{$ledger} ],
	};
}

# Who owns the address writes. The reading is cached for half a minute so a
# status poll does not start one helper per view.
sub network_manager {
	my $cached = eval { &subs::cache_get({ app => 'network', context => 'manager' }) };
	my $now = &subs::rightNow();
	if (ref $cached eq 'HASH' && ref $cached->{'manager'} eq 'HASH' && defined $cached->{'at'}) {
		my $age = $now - ($cached->{'at'} + 0);
		return $cached->{'manager'} if $age >= 0 && $age < 30_000;
	}
	my $answer = &network_command('manager');
	$answer = { ok => 0, error => 'the network manager could not be read' } unless ref $answer eq 'HASH';
	eval {
		&subs::cache_set(
			{ app => 'network', context => 'manager', warranty => '30s' },
			{ at => $now, manager => $answer },
		);
	};
	return $answer;
}

sub network_status {
	my $answer = &network_command('status');
	$answer = { ok => 0, error => 'the network status could not be read' } unless ref $answer eq 'HASH';
	my $secrets = &network_command('secret_status');
	$secrets = { ok => 0, error => 'the network secret status could not be read' }
		unless ref $secrets eq 'HASH';
	return {
		%{$answer},
		config => &network_config(),
		applied => &network_last_applied(),
		takeover => &network_takeover_state(),
		manager => &network_manager(),
		secrets => $secrets,
	};
}

1;
