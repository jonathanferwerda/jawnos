package gb;
use strict;
use warnings;
no warnings 'once';

# System and app actions voice was missing. Same shape as the entries in
# perl/gb/03_engines_and_tools.pl: an app whose help topic names it, a "do" the
# model may pick, a real route that answers JSON, the exact parameters that
# route reads, and a speech sub that reads only that JSON. A write carries a
# confirm, because the bridge proposes it before anything runs.
#
# Every route here returns JSON today. An app whose route is HTML, or whose
# help topic is not app-scoped, is deliberately absent.

push @gb::app_actions, (

	# ---- Power -----------------------------------------------------------
	{
		app => 'power', do => 'status', kind => 'read',
		method => 'get', route => '/manager/power_status',
		params => {},
		desc => 'read the battery, the power plan in use and the charge ceiling',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			my $b = (ref $d->{'battery'} eq 'HASH') ? $d->{'battery'} : {};
			unless ($b->{'present'}) {
				return 'This machine has no battery and is running on mains power.';
			}
			my $say = defined $b->{'percentage'}
				? 'The battery is at ' . int($b->{'percentage'}) . ' percent'
				: 'The battery is present';
			my $state = $b->{'status'} // '';
			$say .= ', ' . $state if length $state;
			my $charge = (ref $d->{'charge'} eq 'HASH') ? $d->{'charge'} : {};
			my $ceiling = $charge->{'saved'} // 0;
			$say .= '; the charge ceiling is ' . int($ceiling) . ' percent'
				if $charge->{'supported'} && $ceiling;
			return ucfirst($say) . '.';
		},
	},
	{
		app => 'power', do => 'plan', kind => 'write',
		method => 'post', route => '/manager/power/plan',
		params => {
			source => 'ac or battery (the source the plan is for)',
			plan => 'auto, powersaver, balanced or performance',
			limit => 'the CPU speed limit, 25 to 100 percent',
		},
		required => { plan => 'the power plan to save' },
		confirm => 'I can save that power plan. Confirm it and I will.',
		desc => 'save the power plan and CPU limit for one power source',
		speech => sub {
			my ($d, $p) = @_;
			$d = (ref $d eq 'HASH') ? $d : {};
			$p = (ref $p eq 'HASH') ? $p : {};
			my $source = ($p->{'source'} // '') ne '' ? $p->{'source'} : 'this source';
			my $plan = ($p->{'plan'} // '') ne '' ? $p->{'plan'} : 'the selected';
			return 'I saved the ' . $plan . ' plan for ' . $source . '.';
		},
	},
	{
		app => 'power', do => 'charge', kind => 'write',
		method => 'post', route => '/manager/power/charge',
		params => { end => 'the charge ceiling, 50 to 100 percent' },
		required => { end => 'the charge ceiling percentage' },
		confirm => 'I can set that charge ceiling. Confirm it and I will.',
		desc => 'set the battery charge ceiling',
		speech => sub {
			my ($d, $p) = @_;
			$d = (ref $d eq 'HASH') ? $d : {};
			$p = (ref $p eq 'HASH') ? $p : {};
			my $end = $d->{'end'} // $p->{'end'} // '';
			return length $end
				? 'The charge ceiling is set to ' . int($end) . ' percent.'
				: 'I set the charge ceiling.';
		},
	},
	{
		app => 'power', do => 'sleep', kind => 'write',
		method => 'post', route => '/manager/power/sleep',
		params => {
			plan => 'the power profile the block belongs to, optional',
			screen_timeout => 'minutes before the screen turns off',
			sleep_timeout => 'minutes before the machine sleeps',
			lid_action => 'what closing the lid does',
			sleep_type => 'suspend, hibernate or hybrid',
		},
		confirm => 'I can save those sleep and display settings. Confirm it and I will.',
		desc => 'save the screen, sleep and lid settings',
		speech => sub {
			my ($d, $p) = @_;
			$p = (ref $p eq 'HASH') ? $p : {};
			my $profile = ($p->{'plan'} // '') ne '' ? ' for the ' . $p->{'plan'} . ' profile' : '';
			return 'I saved the sleep and display settings' . $profile . '.';
		},
	},

	# ---- Notifications ---------------------------------------------------
	{
		app => 'notifications', do => 'list', kind => 'read',
		method => 'get', route => '/manager/notifications/status',
		params => {},
		desc => 'read the newest notices and how many are unread',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			my $rows = (ref $d->{'notifications'} eq 'ARRAY') ? $d->{'notifications'} : [];
			my $total = defined $d->{'total'} ? 0 + $d->{'total'} : scalar @{$rows};
			return 'There are no notices.' unless $total;
			my $seen = 0 + ($d->{'seen'} // 0);
			my $new = scalar grep { (($_->{'timestamp'} // 0) + 0) > $seen } @{$rows};
			return $total . ' notice' . ($total == 1 ? '' : 's')
				. ($new ? ', ' . $new . ' new.' : '.');
		},
	},
	{
		app => 'notifications', do => 'clear', kind => 'write',
		method => 'post', route => '/manager/notifications/remove',
		params => {
			scope => 'all to clear every notice, or one to remove a single notice',
			uuid => 'the notice to remove when scope is not all',
			timestamp => 'the notice timestamp, for a single notice',
			title => 'the notice title, for a single notice',
			app => 'the app the notice came from',
			server_time => 'the notice server time',
			tag => 'the phone notification tag',
		},
		required => { scope => 'whether to clear all or one notice' },
		confirm => 'I can clear those notices. Confirm it and I will.',
		desc => 'clear every notice, or remove one',
		speech => sub {
			my $d = $_[0];
			if (ref $d eq 'ARRAY') {
				my $n = scalar @{$d};
				return 'There was nothing to remove.' unless $n;
				return 'Removed ' . $n . ' notice' . ($n == 1 ? '' : 's') . '.';
			}
			return 'I removed the notice.';
		},
	},
	{
		app => 'notifications', do => 'seen', kind => 'write',
		method => 'post', route => '/manager/notifications/seen',
		params => { seen => 'the moment the notices were read, in milliseconds' },
		confirm => 'I can mark the notices as seen. Confirm it and I will.',
		desc => 'mark the house notices as read',
		speech => sub {
			return 'I marked the notices as seen.';
		},
	},

	# ---- Packages --------------------------------------------------------
	{
		app => 'packages', do => 'outdated', kind => 'read',
		method => 'get', route => '/manager/packages/outdated',
		params => { backend => 'the package manager to ask, optional' },
		desc => 'list the packages that are out of date',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			my $n = defined $d->{'count'} ? 0 + $d->{'count'}
				: scalar @{ (ref $d->{'packages'} eq 'ARRAY') ? $d->{'packages'} : [] };
			return 'Every package is up to date.' unless $n;
			return $n . ' package' . ($n == 1 ? ' is' : 's are') . ' out of date.';
		},
	},
	{
		app => 'packages', do => 'upgrade', kind => 'write',
		method => 'post', route => '/manager/packages/upgrade',
		params => { backend => 'the package manager to use, optional' },
		confirm => 'I can upgrade the outdated packages. Confirm it and I will.',
		desc => 'upgrade the outdated packages',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			return 'Nothing needed upgrading.' if exists $d->{'changed'} && !$d->{'changed'};
			return 'The upgrade finished.';
		},
	},
	{
		app => 'packages', do => 'install', kind => 'write',
		method => 'post', route => '/manager/packages/install',
		params => {
			name => 'the package to install',
			backend => 'the package manager to use, optional',
		},
		required => { name => 'the package to install' },
		confirm => 'I can install that package. Confirm it and I will.',
		desc => 'install one package by name',
		speech => sub {
			my ($d, $p) = @_;
			$p = (ref $p eq 'HASH') ? $p : {};
			my $name = ($p->{'name'} // '') ne '' ? $p->{'name'} : 'the package';
			return 'The install of ' . $name . ' finished.';
		},
	},

	# ---- Network ---------------------------------------------------------
	{
		app => 'network', do => 'status', kind => 'read',
		method => 'get', route => '/manager/network/status',
		params => {},
		desc => 'read the interfaces, Wi-Fi and VPN state',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			my $wifi = (ref $d->{'wifi'} eq 'HASH') ? $d->{'wifi'} : {};
			my $list = (ref $wifi->{'interfaces'} eq 'ARRAY') ? $wifi->{'interfaces'} : [];
			my ($ssid) = map { $_->{'ssid'} }
				grep { ref $_ eq 'HASH'
					&& lc($_->{'state'} // '') eq 'connected'
					&& ($_->{'ssid'} // '') ne '' } @{$list};
			return 'Wi-Fi is connected to ' . $ssid . '.' if defined $ssid && length $ssid;
			return 'The Wi-Fi radio is off.' if exists $wifi->{'radio_powered'} && !$wifi->{'radio_powered'};
			return 'The network is up.';
		},
	},
	{
		app => 'network', do => 'wifi_scan', kind => 'write',
		method => 'post', route => '/manager/network/wifi_scan',
		params => { interface => 'the Wi-Fi interface to scan, optional' },
		confirm => 'I can scan for Wi-Fi networks. Confirm it and I will.',
		desc => 'scan for nearby Wi-Fi networks',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			my $nets = (ref $d->{'networks'} eq 'ARRAY') ? $d->{'networks'} : [];
			my $n = scalar @{$nets};
			return 'No Wi-Fi networks were found.' unless $n;
			return 'I found ' . $n . ' Wi-Fi network' . ($n == 1 ? '' : 's') . '.';
		},
	},
	{
		app => 'network', do => 'wifi_connect', kind => 'write',
		method => 'post', route => '/manager/network/wifi_connect',
		params => {
			interface => 'the Wi-Fi interface to use',
			ssid => 'the network name',
			passphrase => 'the Wi-Fi password',
			method => 'dhcp or static, optional',
			address => 'the static IPv4 address, when static',
			prefix => 'the IPv4 prefix length, when static',
			gateway => 'the IPv4 gateway, optional',
			dns => 'the DNS servers, optional',
			secure => '1 for a secured network, 0 for an open one',
		},
		required => { interface => 'the Wi-Fi interface', ssid => 'the network name' },
		confirm => 'I can join that Wi-Fi network. Confirm it and I will.',
		desc => 'join a Wi-Fi network',
		speech => sub {
			my ($d, $p) = @_;
			$p = (ref $p eq 'HASH') ? $p : {};
			my $ssid = ($p->{'ssid'} // '') ne '' ? $p->{'ssid'} : 'the network';
			return 'I tried to join ' . $ssid . '.';
		},
	},
	{
		app => 'network', do => 'radio', kind => 'write',
		method => 'post', route => '/manager/network/radio',
		params => { state => 'on or off' },
		required => { state => 'on or off' },
		confirm => 'I can turn the Wi-Fi radio. Confirm it and I will.',
		desc => 'turn the Wi-Fi radio on or off',
		speech => sub {
			my ($d, $p) = @_;
			$p = (ref $p eq 'HASH') ? $p : {};
			my $state = ($p->{'state'} // '') ne '' ? $p->{'state'} : 'changed';
			return 'The Wi-Fi radio is now ' . $state . '.';
		},
	},
	{
		app => 'network', do => 'vpn', kind => 'write',
		method => 'post', route => '/manager/network/vpn',
		params => {
			action => 'tailscale_up, tailscale_down, vpn_start or vpn_stop',
			kind => 'wg or openvpn, for a start or stop',
			name => 'the VPN configuration name, for a start or stop',
		},
		required => { action => 'the VPN action' },
		confirm => 'I can send that VPN action. Confirm it and I will.',
		desc => 'start or stop a VPN or Tailscale',
		speech => sub {
			my ($d, $p) = @_;
			$p = (ref $p eq 'HASH') ? $p : {};
			my $action = ($p->{'action'} // '') ne '' ? $p->{'action'} : 'the VPN action';
			return 'I sent ' . $action . ' to the network helper.';
		},
	},

	# ---- Security --------------------------------------------------------
	{
		app => 'security', do => 'lock', kind => 'write',
		method => 'post', route => '/manager/lock_session',
		params => {
			scope => 'all to lock the whole house, or one to lock this screen',
			device_uuid => 'the screen to lock, optional',
		},
		required => { scope => 'whether to lock the whole house or this screen' },
		confirm => 'I can lock the screen. Confirm it and I will.',
		desc => 'lock this screen or the whole house',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			return 'The house is locked.' if ($d->{'target'} // '') eq '';
			return 'This screen is locked.';
		},
	},

	# ---- Handbook --------------------------------------------------------
	{
		app => 'handbook', do => 'journal', kind => 'write',
		method => 'post', route => '/manager/handbook/journal',
		params => {
			text => 'the journal entry',
			day => 'the day it belongs to, optional',
		},
		required => { text => 'the journal entry' },
		confirm => 'I can write that journal entry. Confirm it and I will.',
		desc => 'write a journal entry for the day',
		speech => sub {
			return 'I saved the journal entry.';
		},
	},
	{
		app => 'handbook', do => 'plant', kind => 'write',
		method => 'post', route => '/manager/handbook/plant',
		params => {
			text => 'an entry to read along with the journal, optional',
			day => 'the day to read, optional',
		},
		confirm => 'I can read the journal and plant what points forward. Confirm it and I will.',
		desc => 'read the journal and plant the ideas, plans and dreams',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			my $n = scalar @{ (ref $d->{'planted'} eq 'ARRAY') ? $d->{'planted'} : [] };
			return 'Nothing new was planted.' unless $n;
			return 'I planted ' . $n . ' entr' . ($n == 1 ? 'y' : 'ies') . '.';
		},
	},

	# ---- Scan ------------------------------------------------------------
	{
		app => 'scan', do => 'capture', kind => 'write',
		method => 'post', route => '/manager/scan/capture',
		params => { feed => 'adf for the feeder, or flatbed' },
		required => { feed => 'the feeder or the flatbed' },
		confirm => 'I can take a page from the scanner. Confirm it and I will.',
		desc => 'capture a page from the feeder or the flatbed',
		speech => sub {
			my ($d, $p) = @_;
			$p = (ref $p eq 'HASH') ? $p : {};
			my $feed = lc($p->{'feed'} // '');
			my $where = $feed eq 'flatbed' ? 'the flatbed' : 'the feeder';
			return 'I started a scan from ' . $where . '.';
		},
	},

	# ---- Studio ----------------------------------------------------------
	{
		app => 'studio', do => 'transport', kind => 'write',
		method => 'post', route => '/manager/studio/transport',
		params => {
			action => 'status, start, stop, seek or update',
			position => 'seconds on the song timeline, for a seek',
			bpm => 'the tempo in beats per minute, optional',
			beats_per_bar => 'the time signature numerator, optional',
			gain => 'the transport gain, 0 to 1, optional',
		},
		required => { action => 'the transport action' },
		confirm => 'I can change the Studio transport. Confirm it and I will.',
		desc => 'read or change the Studio transport',
		speech => sub {
			my ($d, $p) = @_;
			$p = (ref $p eq 'HASH') ? $p : {};
			my $action = ($p->{'action'} // '') ne '' ? $p->{'action'} : 'the transport action';
			return 'I sent ' . $action . ' to the Studio transport.';
		},
	},

	# ---- Notes -----------------------------------------------------------
	{
		app => 'notes', do => 'save', kind => 'write',
		method => 'post', route => '/manager/note_save',
		params => {
			text => 'the note text',
			uuid => 'an existing note to update, optional',
			category => 'the note category, optional',
			status => 'open or done, optional',
		},
		required => { text => 'the note text' },
		confirm => 'I can save that note. Confirm it and I will.',
		desc => 'save a note',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			return $d->{'created'} ? 'I added the note.' : 'I saved the note.';
		},
	},

	# ---- Search ----------------------------------------------------------
	{
		app => 'search', do => 'web', kind => 'read',
		method => 'get', route => '/manager/search/web',
		params => { q => 'what to search the web for' },
		required => { q => 'what to search the web for' },
		desc => 'search the web through the enabled engines',
		speech => sub {
			my ($d, $p) = @_;
			$d = (ref $d eq 'HASH') ? $d : {};
			$p = (ref $p eq 'HASH') ? $p : {};
			my $q = $p->{'q'} // '';
			my $engines = (ref $d->{'engines'} eq 'ARRAY') ? $d->{'engines'} : [];
			my $hits = 0;
			my $first = '';
			foreach my $e ( @{$engines} ) {
				next unless ref $e eq 'HASH' && ref $e->{'results'} eq 'ARRAY';
				$hits += scalar @{ $e->{'results'} };
				$first = $e->{'results'}->[0]->{'title'}
					if !length($first) && ref $e->{'results'}->[0] eq 'HASH';
			}
			unless ($hits) {
				return length $q ? 'I found no web results for "' . $q . '".' : 'I found no web results.';
			}
			my $say = 'I found ' . $hits . ' web result' . ($hits == 1 ? '' : 's');
			$say .= ' for "' . $q . '"' if length $q;
			$say .= ', starting with ' . $first if length $first;
			return $say . '.';
		},
	},

	# ---- IDE -------------------------------------------------------------
	{
		app => 'ide', do => 'save', kind => 'write',
		method => 'post', route => '/manager/ide/save',
		params => {
			file => 'the file path to save',
			content => 'the whole file content',
			timestamp => 'the editor timestamp, optional',
		},
		required => { file => 'the file to save', content => 'the file content' },
		confirm => 'I can save that file in the IDE. Confirm it and I will.',
		desc => 'save a file from the IDE',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			return 'The IDE saved the file.' if ($d->{'status'} // '') eq 'success';
			return 'The IDE did not save the file.';
		},
	},

	# ---- Process Monitor -------------------------------------------------
	{
		app => 'process_monitor', do => 'read', kind => 'read',
		method => 'get', route => '/manager/process_monitor/data',
		params => {},
		desc => 'read this machine\'s processes, load and memory',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			my $health = (ref $d->{'health'} eq 'HASH') ? $d->{'health'} : {};
			my $procs = $health->{'processes'} // 0;
			my $load = ref $health->{'load'} eq 'ARRAY' ? $health->{'load'}->[0] : undef;
			my $say = 'Jawn is running ' . (0 + $procs) . ' process' . ($procs == 1 ? '' : 'es');
			$say .= ', with a load average of ' . $load if defined $load;
			return ucfirst($say) . '.';
		},
	},

);
