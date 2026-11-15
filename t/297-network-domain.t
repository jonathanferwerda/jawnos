# tests-for: lib/JawnOS/Domain/Network2.pm lib/JawnOS/Domain/Loader.pm perl/jobs.pl perl/President.pl
# covers:    The Network app's management switch: the saved addressing profile,
#            the validated helper command, the idempotent minute tick, the
#            master switch and its takeover ledger, and the exit hooks.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::JSON qw(decode_json encode_json);
use Symbol qw(gensym);
use RepoSource;

my $root = repo_root();
my $scratch = tempdir(CLEANUP => 1);
my $fixtures = "$scratch/fixtures";
make_path($fixtures);

local $ENV{'JAWNOS_NETWORK_CONFIG_FILE'} = "$scratch/config.json";
local $ENV{'JAWNOS_NETWORK_STATE_FILE'} = "$scratch/state.json";
local $ENV{'JAWNOS_NETWORK_TAKEOVER_FILE'} = "$scratch/takeover.json";
local $ENV{'JAWNOS_NETWORK_BOOT_ID'} = 'boot-one';
local $ENV{'JAWNOS_NETWORK_DRY_RUN'} = '';
local $ENV{'FAKE_HELPER_DIR'} = $fixtures;

# A fake helper: each command answers from fixtures/<command>.json, with a
# small built-in default for the writes the tests only count. It reads the
# passphrase from stdin the way the real helper does.
my $fake = "$scratch/fake_network.pl";
write_file($fake, <<'PERL');
#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP ();

my $dir = $ENV{'FAKE_HELPER_DIR'} || '.';
my $command = shift @ARGV;
$command = '' unless defined $command;
my $stdin = '';
if ($command eq 'wifi_connect') {
	local $/;
	$stdin = <STDIN>;
	$stdin = '' unless defined $stdin;
}

sub load_fixture {
	my ($name) = @_;
	my $path = "$dir/$name.json";
	return undef unless -e $path;
	open(my $fh, '<', $path) or return undef;
	local $/;
	my $text = <$fh>;
	close $fh;
	my $data = eval { JSON::PP->new->utf8(1)->decode($text) };
	return $data;
}

my $data = load_fixture($command);
if (!defined $data) {
	if ($command eq 'profile_apply') {
		$data = { ok => 1, applied => 1, changed => 1, stack => 'networkd' };
	}
	elsif ($command eq 'profile_remove') {
		$data = { ok => 1, removed => 1, stack => 'networkd' };
	}
	elsif ($command eq 'restore') {
		$data = { ok => 1, restored => [], missing => [] };
	}
	elsif ($command eq 'secrets_release') {
		$data = { ok => 1, restored => [], missing => [] };
	}
	elsif ($command eq 'wifi_connect') {
		$data = { ok => 1, connected => 1 };
	}
	else {
		$data = { ok => 0, error => 'no fixture for ' . $command };
	}
}
$data->{'stdin'} = $stdin if $command eq 'wifi_connect';
print JSON::PP->new->utf8(1)->encode($data);
PERL
chmod 0755, $fake;
local $ENV{'JAWNOS_NETWORK_HELPER'} = $fake;

my $NOW = 1_790_000_000_000;
my %cache;
my @commands;

# Stand in for subs::subprocessor_command: run the fake helper for real and
# remember the argv and the stdin it was given.
sub fake_run {
	my ($command, $params) = @_;
	my $stdin_text = defined $params->{'stdin'} ? $params->{'stdin'} : '';
	push @commands, { command => [ @{$command} ], stdin => $stdin_text };
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, @{$command});
	print {$in} $stdin_text;
	close $in;
	local $/;
	my $output = <$out> // '';
	my $errors = <$err> // '';
	close $out;
	close $err;
	waitpid($pid, 0);
	return { pid => $pid, output => $output, stderr => $errors, exit => $? >> 8 };
}

sub fixture {
	my ($name, $data) = @_;
	write_file("$fixtures/$name.json", encode_json($data));
	return $data;
}

{
	no warnings 'redefine';
	*subs::rightNow = sub { $NOW };
	*subs::cache_get = sub {
		my ($params) = @_;
		my $key = ($params->{'app'} // '') . '/' . ($params->{'context'} // '');
		return $cache{$key};
	};
	*subs::cache_set = sub {
		my ($params, $data) = @_;
		my $key = ($params->{'app'} // '') . '/' . ($params->{'context'} // '');
		$cache{$key} = $data;
		return 1;
	};
	*subs::subprocessor_command = \&fake_run;
}

require "$root/lib/JawnOS/Domain/Network2.pm";

# --- the env hooks and the default shape ------------------------------------
subtest 'env hooks and defaults' => sub {
	write_file("$scratch/config.json", encode_json({
		manage => 1,
		auto => 0,
		takeover => 1,
		profiles => {
			'ethernet:eth0' => {
				kind => 'ethernet', interface => 'eth0', method => 'static',
				address => '10.0.0.2', prefix => 24, gateway => '10.0.0.1', dns => '1.1.1.1',
			},
		},
		default => { method => 'dhcp', dns => ['9.9.9.9'] },
	}));
	my $config = subs::network_config();
	is($config->{'manage'}, 1, 'the config file is read through the env hook');
	is($config->{'auto'}, 0, 'auto is read');
	is($config->{'takeover'}, 1, 'takeover is read');
	is($config->{'profiles'}{'ethernet:eth0'}{'method'}, 'static', 'the profile is read');
	is_deeply($config->{'profiles'}{'ethernet:eth0'}{'dns'}, ['1.1.1.1'],
		'a comma separated DNS answer becomes a list');
	is_deeply($config->{'default'}{'dns'}, ['9.9.9.9'], 'the default DNS list is read');

	my $default = subs::network_default_config();
	is($default->{'manage'}, 0, 'JawnOS does not manage the network by default');
	is($default->{'auto'}, 1, 'automatic switching is on by default');
	is($default->{'takeover'}, 1, 'a static profile takes over a legacy DHCP daemon by default');
	is_deeply($default->{'profiles'}, {}, 'there are no profiles by default');
	is($default->{'default'}{'method'}, 'dhcp', 'the default addressing is DHCP');
	is_deeply($default->{'default'}{'dns'}, [], 'with no DNS override');
	unlink "$scratch/config.json";
};

# --- clean and validate -----------------------------------------------------
subtest 'clean and validate' => sub {
	my $clean = subs::network_config_clean({
		manage => 2,
		profiles => {
			'wifi:House' => {
				kind => 'wifi', ssid => 'House', method => 'static',
				address => '192.168.1.50', prefix => 24, gateway => '192.168.1.1',
				dns => ['1.1.1.1', '2606:4700:4700::1111'],
			},
			'broken' => { kind => 'wifi', ssid => '' },
			'ethernet:eth0' => { kind => 'ethernet', interface => 'eth0', method => 'dhcp' },
		},
	});
	is($clean->{'manage'}, 1, 'a true value is stored as one');
	is(scalar keys %{ $clean->{'profiles'} }, 2, 'only valid profiles survive the clean');
	is($clean->{'profiles'}{'wifi:House'}{'ssid'}, 'House', 'the wifi profile is kept');
	is($clean->{'profiles'}{'wifi:House'}{'key'}, 'wifi:House', 'with its key rebuilt');
	ok(!exists $clean->{'profiles'}{'broken'}, 'an empty SSID is refused');

	ok(subs::network_profile_valid({ kind => 'wifi', ssid => 'House', method => 'dhcp' }),
		'a wifi profile needs an SSID');
	ok(!subs::network_profile_valid({ kind => 'wifi', ssid => 'H' x 40, method => 'dhcp' }),
		'an SSID over 32 characters is refused');
	ok(!subs::network_profile_valid({ kind => 'ethernet', interface => 'bad name', method => 'dhcp' }),
		'an interface with a space is refused');
	ok(!subs::network_profile_valid({ kind => 'wifi', ssid => 'H', method => 'nope' }),
		'an unknown method is refused');
	ok(!subs::network_profile_valid({ kind => 'wifi', ssid => 'H', method => 'static', address => '999.1.1.1', prefix => 24 }),
		'an invalid IPv4 address is refused');
	ok(!subs::network_profile_valid({ kind => 'wifi', ssid => 'H', method => 'static', address => '10.0.0.2', prefix => 33 }),
		'a prefix over 32 is refused');
	ok(!subs::network_profile_valid({ kind => 'wifi', ssid => 'H', method => 'static', address => '10.0.0.2', prefix => 24, dns => ['a.b.c.d'] }),
		'a DNS name is refused');
	ok(subs::network_profile_valid({
		kind => 'wifi', ssid => 'H', method => 'static', address => '10.0.0.2',
		prefix => 24, gateway => '10.0.0.1', dns => ['1.1.1.1', '2606:4700:4700::1111'],
	}), 'IPv4 and IPv6 DNS servers are accepted');
};

# --- profiles ---------------------------------------------------------------
subtest 'profiles are stored and removed' => sub {
	unlink "$scratch/config.json";
	@commands = ();
	my $set = subs::network_profile_set('wifi', 'wifi:House', 'wlan0', 'static',
		'192.168.1.50', 24, '192.168.1.1', '1.1.1.1');
	ok($set->{'ok'}, 'the profile is saved');
	is($set->{'config'}{'profiles'}{'wifi:House'}{'address'}, '192.168.1.50', 'with its address');
	is($set->{'config'}{'profiles'}{'wifi:House'}{'interface'}, 'wlan0', 'and its interface');
	ok(!defined $set->{'applied'}, 'saving while the system manages writes nothing');
	ok(-e "$scratch/config.json", 'the config file is written');

	my $bare = subs::network_profile_set('wifi', 'Bare', 'wlan0', 'dhcp', '', '', '', '');
	ok($bare->{'ok'}, 'a bare SSID key is accepted');
	is($bare->{'profile'}{'key'}, 'wifi:Bare', 'and stored with its kind prefix');
	subs::network_profile_delete('wifi', 'wifi:Bare');

	@commands = ();
	my $del = subs::network_profile_delete('wifi', 'wifi:House');
	ok($del->{'ok'}, 'the profile is removed');
	ok(!exists $del->{'config'}{'profiles'}{'wifi:House'}, 'and gone from the config');
	my $remove = $commands[-1]{'command'};
	is($remove->[2], 'profile_remove', 'the helper is asked to remove the drop-in');
	is($remove->[3], 'wifi', 'with the kind');
	is($remove->[4], 'House', 'and the SSID the helper expects');
	my $missing = subs::network_profile_delete('wifi', 'wifi:House');
	is($missing->{'ok'}, 0, 'deleting a missing profile is refused');
};

# --- the master switch ------------------------------------------------------
subtest 'manage on applies, off releases' => sub {
	unlink "$scratch/config.json";
	unlink "$scratch/state.json";
	unlink "$scratch/takeover.json";
	fixture('watch', {
		ok => 1, boot => 'boot-one', stack => 'networkd',
		interfaces => [ {
			name => 'wlan0', state => 'up', kind => 'wifi', ssid => 'House',
			method => 'static', address => '192.168.1.50', prefix => 24,
			gateway => '192.168.1.1', dns => ['1.1.1.1'], wireless => 1,
		} ],
	});
	fixture('manager', { ok => 1, supported => 1, stack => 'networkd', units => [], competitors => [] });
	fixture('secret_status', { ok => 1, available => 1, backend => 'file', tpm => 0, dir => '/x' });
	fixture('takeover', { ok => 1, supported => 1, records => [ { unit => 'dhcpcd.service', enabled => 1 } ] });
	delete $cache{'network/manager'};

	subs::network_profile_set('wifi', 'wifi:House', 'wlan0', 'static',
		'192.168.1.50', 24, '192.168.1.1', '1.1.1.1');
	@commands = ();
	my $on = subs::network_manage_set(1);
	ok($on->{'ok'}, 'management can be turned on');
	is($on->{'config'}{'manage'}, 1, 'the setting is stored');
	ok($on->{'applied'}{'ok'}, 'the live network is applied at once');

	my ($apply) = grep { ($_->{'command'}[2] // '') eq 'profile_apply' } @commands;
	ok($apply, 'the helper is asked to apply a profile');
	is($apply->{'command'}[3], 'wifi', 'the kind is the wifi');
	is($apply->{'command'}[4], 'House', 'the key names the SSID');
	is($apply->{'command'}[5], 'wlan0', 'the live interface is used');
	is($apply->{'command'}[6], 'static', 'the method is passed');
	is($apply->{'command'}[7], '192.168.1.50', 'the address is passed');
	is($apply->{'command'}[8], '24', 'the prefix is passed');
	is($apply->{'command'}[9], '192.168.1.1', 'the gateway is passed');
	is($apply->{'command'}[10], '1.1.1.1', 'the DNS list is passed');

	my $state = decode_json(read_file("$scratch/state.json"));
	is($state->{'at'}, $NOW, 'the applied record carries the time');
	is($state->{'boot'}, 'boot-one', 'and the boot');
	is($state->{'kind'}, 'wifi', 'and the kind');
	is($state->{'key'}, 'wifi:House', 'and the key');
	is($state->{'interface'}, 'wlan0', 'and the interface');
	is($state->{'method'}, 'static', 'and the method');
	is($state->{'address'}, '192.168.1.50', 'and the address');
	is($state->{'prefix'}, 24, 'and the prefix');
	is($state->{'gateway'}, '192.168.1.1', 'and the gateway');
	is_deeply($state->{'dns'}, ['1.1.1.1'], 'and the DNS list');
	is($state->{'ok'}, 1, 'and the verdict');
	is($state->{'error'}, '', 'and the error slot');
	is($state->{'stack'}, 'networkd', 'and the owning stack');
	is($state->{'changed'}, 1, 'and whether anything changed');
	for my $field (qw(at boot kind key interface method address prefix gateway dns ok error stack changed)) {
		ok(exists $state->{$field}, "the applied record carries $field");
	}

	my $ledger = subs::network_takeover_state();
	is(scalar @{$ledger}, 1, 'the static apply records the takeover');
	is($ledger->[0]{'unit'}, 'dhcpcd.service', 'with the daemon it stopped');
	is($ledger->[0]{'enabled'}, 1, 'and its enabled state');

	@commands = ();
	my $off = subs::network_manage_set(0);
	is($off->{'config'}{'manage'}, 0, 'management can be turned off');
	is($off->{'release'}{'released'}, 1, 'the recorded daemon is released');
	ok($off->{'release'}{'secrets'}{'ok'}, 'and the system credentials are restored');
	is(scalar @{subs::network_takeover_state()}, 0, 'the ledger is cleared');
	is($commands[-1]{'command'}[2], 'secrets_release', 'the helper releases the stored secrets');
	is($commands[-2]{'command'}[2], 'restore', 'after the daemons are put back');
};

# --- the minute tick --------------------------------------------------------
subtest 'the minute tick' => sub {
	unlink "$scratch/state.json";
	unlink "$scratch/takeover.json";
	write_file("$scratch/config.json", encode_json({
		manage => 1,
		auto => 0,
		profiles => {
			'wifi:House' => {
				kind => 'wifi', ssid => 'House', interface => 'wlan0', method => 'static',
				address => '192.168.1.50', prefix => 24, gateway => '192.168.1.1', dns => ['1.1.1.1'],
			},
		},
		default => { method => 'dhcp', dns => [] },
	}));
	fixture('manager', { ok => 1, supported => 1, stack => 'networkd', units => [], competitors => [] });
	fixture('takeover', { ok => 1, supported => 1, records => [] });
	fixture('watch', {
		ok => 1, boot => 'boot-one',
		interfaces => [ {
			name => 'wlan0', state => 'up', kind => 'wifi', ssid => 'House',
			method => 'static', address => '192.168.1.50', prefix => 24,
			gateway => '192.168.1.1', dns => ['1.1.1.1'], wireless => 1,
		} ],
	});
	delete $cache{'network/manager'};

	subtest 'a new boot applies even with automatic switching off' => sub {
		@commands = ();
		my $tick = subs::network_watch_tick();
		ok($tick->{'ok'}, 'the tick answers');
		is($tick->{'key'}, 'wifi:House', 'it picked the live wifi');
		my ($apply) = grep { ($_->{'command'}[2] // '') eq 'profile_apply' } @commands;
		ok($apply, 'the saved profile is applied');
		is((decode_json(read_file("$scratch/state.json")))->{'boot'}, 'boot-one',
			'and the new boot is recorded');
	};

	subtest 'the same boot and network are a no-op' => sub {
		is(subs::network_watch_tick()->{'skipped'}, 'already applied',
			'the second tick writes nothing');
	};

	subtest 'automatic switching off leaves a changed network alone' => sub {
		fixture('watch', {
			ok => 1, boot => 'boot-one',
			interfaces => [ {
				name => 'wlan0', state => 'up', kind => 'wifi', ssid => 'House',
				method => 'static', address => '192.168.1.51', prefix => 24,
				gateway => '192.168.1.1', dns => ['1.1.1.1'], wireless => 1,
			} ],
		});
		is(subs::network_watch_tick()->{'skipped'}, 'auto is off',
			'the changed address is not chased');
	};

	subtest 'automatic switching on follows the drift' => sub {
		my $config = subs::network_config();
		$config->{'auto'} = 1;
		subs::network_config_save($config);
		@commands = ();
		my $tick = subs::network_watch_tick();
		ok($tick->{'ok'}, 'the drift is applied');
		my ($apply) = grep { ($_->{'command'}[2] // '') eq 'profile_apply' } @commands;
		ok($apply, 'through the helper');
		# The helper has now put the saved address on the live link.
		fixture('watch', {
			ok => 1, boot => 'boot-one',
			interfaces => [ {
				name => 'wlan0', state => 'up', kind => 'wifi', ssid => 'House',
				method => 'static', address => '192.168.1.50', prefix => 24,
				gateway => '192.168.1.1', dns => ['1.1.1.1'], wireless => 1,
			} ],
		});
		is(subs::network_watch_tick()->{'skipped'}, 'already applied',
			'and the next tick is quiet');
	};

	subtest 'a competing manager with a static profile re-applies' => sub {
		fixture('manager', {
			ok => 1, supported => 1, stack => 'networkd',
			units => ['dhcpcd.service'], competitors => ['dhcpcd'],
		});
		delete $cache{'network/manager'};
		@commands = ();
		my $tick = subs::network_watch_tick();
		ok($tick->{'ok'}, 'the tick answers');
		my ($apply) = grep { ($_->{'command'}[2] // '') eq 'profile_apply' } @commands;
		ok($apply, 'the owning stack is asked to re-apply the static profile');
	};

	subtest 'no live network is skipped' => sub {
		fixture('watch', { ok => 1, boot => 'boot-one', interfaces => [] });
		is(subs::network_watch_tick()->{'skipped'}, 'no network',
			'with no target and no wireless interface there is nothing to do');
	};

	subtest 'management off is skipped' => sub {
		my $config = subs::network_config();
		$config->{'manage'} = 0;
		subs::network_config_save($config);
		is(subs::network_watch_tick()->{'skipped'}, 'system managed',
			'the tick leaves the system in charge');
	};
};

# --- a disconnected wifi rejoins with the stored secret ---------------------
subtest 'a disconnected wifi rejoins with the saved secret' => sub {
	write_file("$scratch/config.json", encode_json({
		manage => 1,
		auto => 1,
		profiles => {
			'wifi:House' => {
				kind => 'wifi', ssid => 'House', interface => 'wlan0', method => 'static',
				address => '192.168.1.50', prefix => 24, gateway => '192.168.1.1', dns => ['1.1.1.1'],
			},
		},
		default => { method => 'dhcp', dns => [] },
	}));
	unlink "$scratch/state.json";
	unlink "$scratch/takeover.json";
	fixture('watch', {
		ok => 1, boot => 'boot-one',
		interfaces => [ { name => 'wlan0', state => 'down', kind => 'wifi', ssid => '', wireless => 1 } ],
	});
	fixture('secret_status', { ok => 1, available => 1, backend => 'file', tpm => 0, dir => '/x' });
	fixture('takeover', { ok => 1, supported => 1, records => [] });
	@commands = ();
	my $tick = subs::network_watch_tick();
	ok($tick->{'ok'}, 'the tick answers');
	my ($join) = grep { ($_->{'command'}[2] // '') eq 'wifi_connect' } @commands;
	ok($join, 'the saved network is rejoined');
	is($join->{'command'}[3], 'wlan0', 'on the wireless interface');
	is($join->{'command'}[4], 'House', 'with the saved SSID');
	is($join->{'command'}[5], 'static', 'with the saved method');
	is($join->{'command'}[6], '192.168.1.50', 'with the saved address');
	is($join->{'command'}[7], '24', 'with the saved prefix');
	is($join->{'command'}[8], '192.168.1.1', 'with the saved gateway');
	is($join->{'command'}[9], '1.1.1.1', 'with the saved DNS');
	is($join->{'command'}[10], 'use', 'the helper is told to use the stored secret');
	is($join->{'stdin'}, '', 'no passphrase is put on the command line');
	my ($apply) = grep { ($_->{'command'}[2] // '') eq 'profile_apply' } @commands;
	ok($apply, 'and the address is applied after the rejoin');
};

# --- the status merge -------------------------------------------------------
subtest 'status keeps the helper fields and adds the management rows' => sub {
	fixture('status', {
		ok => 1,
		interfaces => [ { name => 'wlan0' } ],
		wifi => { ssid => 'House' },
		vpn => { ok => 1 },
	});
	fixture('manager', { ok => 1, supported => 1, stack => 'networkd', units => [], competitors => [] });
	fixture('secret_status', { ok => 1, available => 1, backend => 'file', tpm => 0, dir => '/x' });
	delete $cache{'network/manager'};
	my $status = subs::network_status();
	ok($status->{'interfaces'}, 'the helper interfaces are kept');
	is($status->{'wifi'}{'ssid'}, 'House', 'the wifi reading is kept');
	ok(exists $status->{'vpn'}, 'the vpn reading is kept');
	ok(exists $status->{'config'}, 'the config is added');
	ok(exists $status->{'applied'}, 'the applied row is added');
	ok(exists $status->{'takeover'}, 'the takeover ledger is added');
	ok(exists $status->{'manager'}, 'the manager reading is added');
	ok($status->{'secrets'}{'available'}, 'the secret status is added');
};

# --- the manager reading is cached ------------------------------------------
subtest 'the manager reading is cached for half a minute' => sub {
	delete $cache{'network/manager'};
	fixture('manager', { ok => 1, supported => 1, stack => 'networkd', units => ['connman'], competitors => [] });
	@commands = ();
	my $first = subs::network_manager();
	is_deeply($first->{'units'}, ['connman'], 'the first call reads the helper');
	is(scalar(grep { ($_->{'command'}[2] // '') eq 'manager' } @commands), 1, 'one helper call');
	@commands = ();
	my $second = subs::network_manager();
	is_deeply($second->{'units'}, ['connman'], 'the second call reads the cache');
	is(scalar @commands, 0, 'with no helper call inside the warranty');
};

# --- the takeover ledger ----------------------------------------------------
subtest 'the takeover ledger only holds dhcpcd and connman' => sub {
	unlink "$scratch/takeover.json";
	fixture('takeover', {
		ok => 1, supported => 1,
		records => [
			{ unit => 'dhcpcd.service', enabled => 1 },
			{ unit => 'connman.service', enabled => 0 },
			{ unit => 'NetworkManager.service', enabled => 1 },
		],
	});
	my $answer = subs::network_takeover();
	ok($answer->{'ok'}, 'the takeover answer is readable');
	my $ledger = subs::network_takeover_state();
	is(scalar @{$ledger}, 2, 'a stranger is not recorded');
	is_deeply([ map { $_->{'unit'} } @{$ledger} ],
		['dhcpcd.service', 'connman.service'], 'the two managers are kept in order');

	{
		local *subs::subprocessor_command = sub {
			return { pid => 1, output => encode_json({ ok => 0, error => 'permission' }) };
		};
		my $failed = subs::network_release_takeover();
		is($failed->{'ok'}, 0, 'a failed restore is reported');
		is(scalar @{subs::network_takeover_state()}, 2, 'and the ledger is kept');
	}
	my $restored = subs::network_release_takeover();
	ok($restored->{'ok'}, 'a later restore succeeds');
	is($restored->{'released'}, 2, 'both daemons are released');
	is(scalar @{subs::network_takeover_state()}, 0, 'and the ledger is cleared');
};

# --- a helper failure is an answer, not a die -------------------------------
subtest 'a broken helper is an answer' => sub {
	{
		local *subs::subprocessor_command = sub { return { pid => 1, output => 'not json' } };
		my $answer = subs::network_command_run([ $^X, $fake, 'watch' ]);
		is($answer->{'ok'}, 0, 'unreadable JSON is a failure');
		like($answer->{'error'}, qr/readable answer/, 'with a readable message');
	}
	local $ENV{'JAWNOS_NETWORK_HELPER'} = "$scratch/missing.pl";
	my $missing = subs::network_command('watch');
	is($missing->{'ok'}, 0, 'a missing helper is a failure');
	like($missing->{'error'}, qr/missing/, 'and says so');
};

# --- dry run ----------------------------------------------------------------
subtest 'dry run hands back the command without running it' => sub {
	local $ENV{'JAWNOS_NETWORK_DRY_RUN'} = 1;
	@commands = ();
	my $answer = subs::network_command('watch');
	ok($answer->{'dry_run'}, 'the dry run is marked');
	is($answer->{'command'}[2], 'watch', 'the argument list is returned');
	like($answer->{'command'}[1], qr/fake_network\.pl\z/, 'with the absolute helper path');
	is(scalar @commands, 0, 'and nothing was run');
};

# --- the loader, the slow loop and the exit hooks ---------------------------
subtest 'the loader maps every helper' => sub {
	require JawnOS::Domain::Loader;
	my $src = read_file("$root/lib/JawnOS/Domain/Network2.pm");
	my @names = ($src =~ /^sub\s+([A-Za-z_]\w*)/mg);
	ok(scalar @names >= 20, 'the module defines its helpers');
	my @missing = grep { !subs::provides($_) } @names;
	is_deeply(\@missing, [], 'every Network2 helper is in the domain loader')
		or diag('unmapped: ' . join(', ', @missing));
	ok(defined &subs::network_watch_tick, 'the module defines the tick');
	my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
	like($loader, qr/JawnOS::Domain::Network2' for qw\([^)]*\bnetwork_watch_tick\b/,
		'the tick is mapped to Network2');
	like($loader, qr/JawnOS::Domain::Network2' for qw\([^)]*\bnetwork_default_config\b/,
		'the config helper is mapped to Network2');
};

subtest 'the slow loop and the exit hooks carry the domain' => sub {
	my $jobs = read_file("$root/perl/jobs.pl");
	like($jobs, qr/name => 'network watch'/, 'the slow loop carries the network tick');
	like($jobs, qr/&subs::network_watch_tick\(\)/, 'and calls the domain helper');
	like($jobs, qr/first => 40, every => 60/, 'on the minute after the power watch');

	my $president = read_file("$root/perl/President.pl");
	my @restores = ($president =~ /&subs::network_release_takeover\(\)/g);
	cmp_ok(scalar @restores, '>=', 3, 'the stop, start and fatal-exit hooks restore the takeover');
	like($president, qr{JawnOS/Domain/Network2\.pm}, 'President loads the network module');
	like($president, qr/network_takeover_state\(\)/, 'the restore is guarded by a non-empty ledger');
};

done_testing();
