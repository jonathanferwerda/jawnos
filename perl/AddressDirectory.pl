#!/usr/bin/env perl
#
# AddressDirectory -- the house's server-authoritative address book.
#
# Every machine keeps a local view of the addresses its peers last reported in
# `remote_machines`. A peer that has just joined a network reports its signed
# presence notice to a server when it can reach one. When the server is not
# reachable (a phone whose tailnet is down, a laptop on a LAN that cannot see
# the cloud), a peer relays the same signed notice to a server on the phone's
# behalf: the relay's own request is authenticated by the signed peer rail, and
# the notice inside it is verified against the *subject's* stored pubkey. A
# relay therefore never gets to assert an address for somebody else -- it can
# only carry a blob that signatorial already signed.
#
# The server merges accepted notices into `remote_machines`, bumps a generation
# and pushes the address-only directory back out. Machines that are not the
# server answer from their local rows immediately, then forward the signed
# notice to one server so the authoritative copy catches up. Lookups fall back
# to the server when the local row is missing or points at a tailnet address
# this machine cannot reach.
#
# Only `remote_machines` and the existing `cache` table are used; there is no
# new schema. Route bodies carry address fields only and are deliberately small.

package AddressDirectory;

use strict;
use warnings;

use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;
use Mojo::Util qw(md5_sum url_escape b64_decode);

my $APP = '__president';

# Our own helper is named push() to match the advertised interface. Declaring it
# here makes the name a user sub for the whole file, so every ordinary array
# push below is spelled CORE::push.
sub push;

my $_IS_SERVER;
# In-process throttle for LAN presence relays: a beacon arrives every few
# seconds, and a server that cannot be reached must not make each one wait on a
# socket timeout. The cache throttle is the cross-process one; this is the cheap
# front door.
our %relay_memo;

# ---------------------------------------------------------------------------
# Small shared helpers
# ---------------------------------------------------------------------------

sub _now {
	my $n = eval { &subs::rightNow() };
	return (defined $n && $n =~ /^\d+$/) ? $n : int(time()) * 1000;
}

sub _me {
	my $sig = eval { &subs::signatorial_designer() };
	return defined $sig ? $sig : '';
}

sub _is_server_here {
	return $_IS_SERVER if defined $_IS_SERVER;
	my $device = eval { &subs::device_setter() };
	$_IS_SERVER = ((defined $device ? $device : '') eq 'server') ? 1 : 0;
	return $_IS_SERVER;
}

# Timestamps are epoch milliseconds everywhere in this app. Old or hand-written
# rows can hold an empty value; those compare as zero rather than warning.
sub _time_value {
	my ($v) = @_;
	return 0 unless defined $v && $v ne '';
	return $v =~ /^\d+(?:\.\d+)?$/ ? $v + 0 : 0;
}

sub _is_tailnet {
	my ($ip) = @_;
	return 0 unless defined $ip;
	return $ip =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./ ? 1 : 0;
}

# A LAN address is private but not the tailnet (which is tracked separately) and
# not loopback.
sub _is_lan {
	my ($ip) = @_;
	return 0 unless defined $ip && $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	return 0 if $ip =~ /^127\./;
	return 0 if _is_tailnet($ip);
	return 1 if $ip =~ /^10\./;
	return 1 if $ip =~ /^192\.168\./;
	return 1 if $ip =~ /^169\.254\./;
	return 1 if $ip =~ /^172\.(?:1[6-9]|2\d|3[01])\./;
	return 0;
}

sub _parse_network {
	my ($value) = @_;
	return $value if ref $value eq 'HASH';
	my $decoded = eval { decode_json($value // '') };
	return (ref $decoded eq 'HASH') ? $decoded : {};
}

# Keep only the fields that describe where a machine is. `remote_machines`
# network maps also carry netmask/broadcast/gateway details that would only make
# every directory body bigger.
sub _address_network {
	my ($net) = @_;
	$net = _parse_network($net);
	my @fields = qw(nic ip port ws_port mac manager timestamp hostname device version);
	my %out;
	foreach my $key (keys %{$net}) {
		my $entry = $net->{$key};
		next unless ref $entry eq 'HASH';
		my %keep;
		foreach my $field (@fields) {
			next unless defined $entry->{$field} && $entry->{$field} ne '';
			$keep{$field} = $entry->{$field};
		}
		$out{$key} = \%keep if %keep;
	}
	return \%out;
}

# Merge a fresh address map over the stored one. Per-nic entries merge (so a
# pruned directory record does not drop a gateway or netmask the row already
# knew) and an old `lan` entry survives a record that carries no LAN at all.
sub _merge_network {
	my ($old, $new) = @_;
	my $base = _parse_network($old);
	my $fresh = _parse_network($new);
	my %out = %{$base};
	foreach my $key (keys %{$fresh}) {
		my $entry = $fresh->{$key};
		next unless ref $entry eq 'HASH';
		my $was = (ref $out{$key} eq 'HASH') ? $out{$key} : {};
		$out{$key} = { %{$was}, %{$entry} };
	}
	return \%out;
}

# A roster row normally stores the base origin, but a row filled from the
# network reporter can carry a trailing `/manager`. Normalise both shapes.
sub _base_manager {
	my ($manager) = @_;
	return '' unless defined $manager && length $manager;
	my $base = $manager;
	$base =~ s{/+$}{};
	$base =~ s{/manager$}{};
	return $base;
}

sub _all_rows {
	my $result = eval { &subs::db_query('select * from remote_machines') };
	return [] unless $result;
	my $rows = eval { $result->hashes->to_array };
	return (ref $rows eq 'ARRAY') ? $rows : [];
}

sub _row_for_sig {
	my ($sig) = @_;
	return undef unless defined $sig && length $sig;
	my $result = eval { &subs::db_select('remote_machines', undef, { signatorial => $sig }) };
	return undef unless $result;
	my $rows = eval { $result->hashes->to_array };
	return undef unless ref $rows eq 'ARRAY' && scalar @{$rows};
	return $rows->[-1];
}

sub _generation {
	my ($bump) = @_;
	my $value = eval {
		&subs::cache_get({ app => $APP, context => 'address_directory', subcontext => 'generation' });
	};
	$value = 0 unless defined $value && $value =~ /^\d+$/;
	if ($bump) {
		$value++;
		eval {
			&subs::cache_set({
				app        => $APP,
				context    => 'address_directory',
				subcontext => 'generation',
				warranty   => '-1d',
			}, $value);
		};
	}
	return $value;
}

# A tiny throttle in the existing cache. cache_get does not expire rows on read,
# so the stored `at` is compared here; the warranty only lets the cache sweeper
# forget it later.
sub _recently {
	my ($context, $subcontext, $target, $seconds) = @_;
	my $last = eval {
		&subs::cache_get({ app => $APP, context => $context, subcontext => $subcontext });
	};
	return 0 unless ref $last eq 'HASH';
	return 0 if defined $target && ($last->{'target'} // '') ne $target;
	my $at = _time_value($last->{'at'});
	return $at > _now() - ($seconds * 1000) ? 1 : 0;
}

sub _stamp {
	my ($context, $subcontext, $target, $seconds) = @_;
	eval {
		&subs::cache_set({
			app        => $APP,
			context    => $context,
			subcontext => $subcontext,
			warranty   => '-' . $seconds . 's',
		}, { at => _now(), target => ($target // '') });
	};
}

# ---------------------------------------------------------------------------
# Records
# ---------------------------------------------------------------------------

# One small address record for a `remote_machines` row. `at`/`seen` are epoch
# milliseconds so a merge can refuse an older claim.
sub record_for {
	my ($rm) = @_;
	return {} unless ref $rm eq 'HASH';

	my $net = _parse_network($rm->{'network'});
	my (@lan, $tailnet, $row_at, $lan_at);
	my %seen_ip;

	my $add_lan = sub {
		my ($ip, $port) = @_;
		return unless defined $ip && length $ip;
		return if $seen_ip{$ip};
		$seen_ip{$ip} = 1;
		my %entry = (ip => $ip);
		$entry{'port'} = $port if defined $port && $port ne '';
		CORE::push @lan, \%entry;
	};

	foreach my $nic (sort keys %{$net}) {
		my $entry = $net->{$nic};
		next unless ref $entry eq 'HASH';
		my $ip = $entry->{'ip'} // '';
		next unless length $ip;
		$lan_at = _time_value($entry->{'timestamp'}) if _time_value($entry->{'timestamp'}) > ($lan_at // 0);
		if (_is_tailnet($ip)) {
			$tailnet ||= $ip;
			next;
		}
		if (_is_lan($ip)) {
			$add_lan->($ip, $entry->{'port'});
		}
	}

	$row_at = _time_value($rm->{'server_time'});
	my $at = ($row_at > ($lan_at // 0)) ? $row_at : ($lan_at // 0);

	my $tailnet_address = eval { &subs::tailnet_address($rm) } || '';
	$tailnet ||= $tailnet_address;

	my $ip = $rm->{'ip'} // '';
	$ip = $lan[0]->{'ip'} if !length $ip && scalar @lan;
	$ip = $tailnet if !length $ip && $tailnet;

	my $port = $rm->{'port'} // '';
	$port = $lan[0]->{'port'} if !length $port && scalar @lan;

	# A manager that resolves into the tailnet is unusable when that node is
	# offline. When the peer also advertised a LAN address, publish the LAN
	# manager in the record so a consumer does not have to rediscover it.
	my $manager = $rm->{'manager'} // '';
	if (scalar @lan && _manager_is_tailnet($manager)) {
		my $lan_port = $lan[0]->{'port'} || $port || 45545;
		$manager = 'https://' . $lan[0]->{'ip'} . ':' . $lan_port;
	}

	return {
		signatorial => $rm->{'signatorial'} // '',
		hostname    => $rm->{'hostname'} // '',
		device      => $rm->{'device'} // '',
		manager     => $manager,
		ip          => $ip,
		port        => $port,
		ws_port     => $rm->{'ws_port'} // '',
		fqdn        => $rm->{'fqdn'} // '',
		tailnet     => $tailnet,
		lan         => \@lan,
		network     => _address_network($net),
		version     => $rm->{'version'} // '',
		seen        => $row_at,
		at          => $at,
	};
}

# This machine's own record, built from the same signed payload its beacon uses.
sub local_record {
	my ($reason) = @_;
	$reason = '' unless defined $reason;

	my $presence = eval { &subs::lan_presence_payload() } || {};
	my $report   = eval { &subs::network_interface_reporter() } || {};
	my $config   = eval { &subs::config_reader() } || {};

	my $me       = $presence->{'signatorial'} || _me();
	my $hostname = $presence->{'hostname'} // '';
	my $device   = $presence->{'device'} // '';
	my $version  = $presence->{'version'} // '';
	my $port     = $presence->{'port'} || $ENV{'PORT_AHOY'} || $config->{'working_port'} || 45545;
	my $ws_port  = $presence->{'ws_port'} || $ENV{'PORT_MSG'} || '';
	my $now      = _now();

	my (%network, @lan, $first_lan, $first_any, $tailnet);

	foreach my $nic (sort keys %{$report}) {
		my $entry = $report->{$nic};
		next unless ref $entry eq 'HASH';
		my $ip = $entry->{'ip'} // '';
		next unless $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
		next if $ip =~ /^127\./;

		my $nic_port = $entry->{'port'} || $port;
		my %address = (
			nic       => $nic,
			ip        => $ip,
			port      => $nic_port,
			manager   => 'https://' . $ip . ':' . $nic_port,
			timestamp => $now,
		);
		$address{'ws_port'} = $entry->{'ws_port'} if $entry->{'ws_port'};
		$address{'mac'}     = $entry->{'mac'}     if $entry->{'mac'};
		$address{'hostname'} = $hostname if length $hostname;
		$address{'device'}   = $device   if length $device;
		$address{'version'}  = $version  if length $version;
		$network{$nic} = \%address;

		$first_any ||= $ip;
		if (_is_tailnet($ip)) {
			$tailnet ||= $ip;
		}
		elsif (_is_lan($ip)) {
			$first_lan ||= $ip;
			CORE::push @lan, { ip => $ip, port => $nic_port };
		}
	}

	my $ip = $first_lan || $tailnet || $first_any || '';
	my $manager = '';
	if (length $ip) {
		$manager = 'https://' . $ip . ':' . $port;
	}
	# Mirror lan_presence_accept's shape so a peer reading the map finds the
	# direct address in the same place, whichever path taught it. A tailnet-only
	# machine (the cloud) has no LAN entry to add.
	if ($first_lan) {
		$network{'lan'} = {
			nic       => 'lan',
			ip        => $first_lan,
			port      => $port,
			manager   => 'https://' . $first_lan . ':' . $port,
			hostname  => $hostname,
			device    => $device,
			version   => $version,
			timestamp => $now,
		};
	}

	my $fqdn = ($hostname =~ /\./) ? $hostname : '';

	return {
		signatorial => $me,
		hostname    => $hostname,
		device      => $device,
		manager     => $manager,
		ip          => $ip,
		port        => $port,
		ws_port     => $ws_port,
		fqdn        => $fqdn,
		tailnet     => $tailnet || '',
		lan         => \@lan,
		network     => \%network,
		version     => $version,
		seen        => $now,
		at          => $now,
		reason      => $reason,
	};
}

# Every known peer except this machine, keyed by signatorial. This is what the
# server pushes and what the routes hand back.
sub directory_records {
	my $me = _me();
	my %directory;
	foreach my $row (@{ _all_rows() }) {
		my $sig = $row->{'signatorial'} // '';
		next unless length $sig;
		next if $sig eq $me;
		$directory{$sig} = record_for($row);
	}
	return \%directory;
}

sub server_rows {
	my $me = _me();
	my @rows = grep {
		(($_->{'device'} // '') eq 'server') && (($_->{'signatorial'} // '') ne $me)
	} @{ _all_rows() };

	@rows = sort {
		my $a_active = (($a->{'connection'} // '') eq 'active') ? 0 : 1;
		my $b_active = (($b->{'connection'} // '') eq 'active') ? 0 : 1;
		$a_active <=> $b_active
			|| _time_value($b->{'server_time'}) <=> _time_value($a->{'server_time'})
	} @rows;
	return \@rows;
}

# Peers that can carry a notice for somebody else: recently seen or connected,
# never the subject and never this machine.
sub relay_rows {
	my ($subject) = @_;
	my $me = _me();
	my $cutoff = _now() - (15 * 60 * 1000);

	my @rows = grep {
		my $sig = $_->{'signatorial'} // '';
		(($_->{'device'} // '') ne 'server')
			&& $sig ne $me
			&& (!defined $subject || $sig ne $subject)
			&& ((($_->{'connection'} // '') eq 'active')
				|| _time_value($_->{'server_time'}) >= $cutoff)
	} @{ _all_rows() };

	@rows = sort {
		my $a_active = (($a->{'connection'} // '') eq 'active') ? 0 : 1;
		my $b_active = (($b->{'connection'} // '') eq 'active') ? 0 : 1;
		$a_active <=> $b_active
			|| _time_value($b->{'server_time'}) <=> _time_value($a->{'server_time'})
	} @rows;
	return \@rows;
}

# ---------------------------------------------------------------------------
# Applying records
# ---------------------------------------------------------------------------

# Merge a sig => record map into remote_machines. Rotating the address fields is
# safe; connection state, cookies and pinned keys are owned by the peer rail and
# are never touched here. An older record is ignored, and a record without a LAN
# cannot erase a LAN entry the row already holds.
sub apply {
	my ($records) = @_;
	return 0 unless ref $records eq 'HASH';

	my %by_sig;
	foreach my $row (@{ _all_rows() }) {
		my $sig = $row->{'signatorial'} // '';
		next unless length $sig;
		$by_sig{$sig} = $row;
	}

	my $count = 0;
	foreach my $sig (sort keys %{$records}) {
		my $record = $records->{$sig};
		next unless ref $record eq 'HASH';
		my $row = $by_sig{$sig};
		next unless $row;

		my $at = _time_value($record->{'at'});
		$at = _time_value($record->{'seen'}) if !$at;
		my $row_at = _time_value($row->{'server_time'});
		next if $at < $row_at;

		my %update;

		my $network = $record->{'network'};
		if (ref $network eq 'HASH' && %{$network}) {
			my $merged = _merge_network($row->{'network'}, $network);
			$update{'network'} = encode_json($merged) if %{$merged};
		}

		foreach my $field (qw(ip port ws_port manager fqdn hostname version device)) {
			my $value = $record->{$field};
			next unless defined $value && length $value;
			next if (($row->{$field} // '') eq $value);
			$update{$field} = $value;
		}

		my $stamp = ($at > $row_at) ? $at : $row_at;
		$update{'server_time'} = $stamp if $stamp;
		next unless %update;

		my $ok = eval { &subs::db_update('remote_machines', \%update, { signatorial => $sig }) };
		$count++ if $ok;
	}
	return $count;
}

# ---------------------------------------------------------------------------
# Outbound reporting
# ---------------------------------------------------------------------------

# Tell the house where we are. A server is preferred; when none is reachable a
# fresh relay peer carries the same signed notice. Throttled per reason+target.
# Never dies.
sub report {
	my ($reason) = @_;
	$reason = 'manual' unless defined $reason && length $reason;

	my $summary = eval {
		my $me = _me();
		return 'address report: no signatorial' unless length $me;

		my $notice = &subs::lan_presence_payload();
		my $record = local_record($reason);

		return 'address report: this is the server' if _is_server_here();

		# Try a server first; a phone whose tailnet is down still has a LAN peer
		# that can relay the signed notice, so keep the relays as fallbacks.
		my @targets = (@{ server_rows() }, @{ relay_rows() });
		return 'address report: no peer to tell' unless scalar @targets;

		my %tried;
		foreach my $row (@targets) {
			my $sig = $row->{'signatorial'} // '';
			next unless length $sig;
			next if $sig eq $me;
			next if $tried{$sig}++;
			next if _recently('address_report', 'address_report:' . $reason, $sig, 30);

			my ($ua, $remote) = eval { &subs::peer_useragent($row) };
			next unless $ua && $remote && $remote->{'manager'};

			my $url = _base_manager($remote->{'manager'}) . '/manager/address_report?signatorial=' . url_escape($me);
			my $tx = eval {
				$ua->connect_timeout(2)->inactivity_timeout(4)->post($url => json => {
					notice  => $notice,
					reason  => $reason,
					network => $record->{'network'},
				});
			};
			next unless $tx && !$tx->error;
			my $res = $tx->res;
			next unless $res && $res->is_success;

			my $body = eval { decode_json($res->body) } || {};
			my $updated = 0;
			$updated = apply($body->{'directory'}) if ref $body->{'directory'} eq 'HASH';

			_stamp('address_report', 'address_report:' . $reason, $sig, 30);
			&subs::log_writer('address directory: reported ' . $reason . ' to ' . $sig . ' (' . $updated . ' refreshed)');
			return 'address report: told ' . $sig . ' (' . $updated . ' refreshed)';
		}
		return 'address report: no peer answered';
	};

	return $summary ? $summary : 'address report: failed';
}

# Ask the house server (or a peer that can reach it) where a machine is now.
# Used by the sync rail before a pull when the stored manager is a dead tailnet
# name, and as the fallback when a batch gets no answer. A one-minute cache keeps
# a busy pull from asking on every table.
sub lookup {
	my ($sig) = @_;
	return undef unless defined $sig && length $sig;

	my $cached = eval {
		&subs::cache_get({ app => $APP, context => 'address_lookup_cache', subcontext => $sig });
	};
	if (ref $cached eq 'HASH' && _time_value($cached->{'at'}) > _now() - 60000) {
		return $cached;
	}

	my $record;
	my ($server) = @{ server_rows() };
	if ($server) {
		my ($ua, $remote) = eval { &subs::peer_useragent($server) };
		if ($ua && $remote && $remote->{'manager'}) {
			my $url = _base_manager($remote->{'manager'}) . '/manager/address_lookup?signatorial=' . url_escape($sig)
				. '&caller=' . url_escape(_me());
			my $tx = eval { $ua->connect_timeout(2)->inactivity_timeout(4)->get($url) };
			if ($tx && !$tx->error && $tx->res->is_success) {
				my $answer = eval { decode_json($tx->res->body) } || {};
				$record = $answer->{'record'} if ref $answer->{'record'} eq 'HASH';
				eval { apply({ $sig => $record }) } if $record;
			}
		}
	}

	$record ||= record_for(_row_for_sig($sig));
	return undef unless ref $record eq 'HASH' && %{$record};
	$record->{'at'} = _now();
	eval {
		&subs::cache_set({
			app        => $APP,
			context    => 'address_lookup_cache',
			subcontext => $sig,
			warranty   => '-1m',
		}, $record);
	};
	return $record;
}

# Best-effort fan-out used by the server after it accepts a report. The reply to
# the caller already carries the directory, so this only refreshes other peers;
# a handful of short attempts keeps the route responsive.
sub push {
	my ($directory) = @_;
	return 0 unless ref $directory eq 'HASH' && %{$directory};

	my $me = _me();
	my $sent = 0;
	my @rows = grep {
		(($_->{'connection'} // '') eq 'active') && (($_->{'signatorial'} // '') ne $me)
	} @{ _all_rows() };

	foreach my $row (@rows) {
		last if $sent >= 8;
		my $sig = $row->{'signatorial'} // '';
		next unless length $sig;

		my ($ua, $remote) = eval { &subs::peer_useragent($row) };
		next unless $ua && $remote && $remote->{'manager'};

		my $url = _base_manager($remote->{'manager'}) . '/manager/address_directory?caller=' . url_escape($me);
		my $tx = eval {
			$ua->connect_timeout(1)->inactivity_timeout(2)->post($url => json => {
				records     => $directory,
				signatorial => $me,
			});
		};
		next unless $tx && !$tx->error && $tx->res->is_success;
		$sent++;
	}

	&subs::log_writer('address directory: pushed to ' . $sent . ' peer(s)') if $sent;
	return $sent;
}

# Forward a relayed signed notice to one server. Only notices are forwarded: an
# unsigned claim about another signatorial cannot be given a signature here, so
# it stays local rather than becoming a forged server claim.
sub _forward_report {
	my ($notice, $reason) = @_;
	return 0 unless ref $notice eq 'HASH' && %{$notice};

	my $me = _me();
	my ($server) = @{ server_rows() };
	return 0 unless $server;

	my ($ua, $remote) = eval { &subs::peer_useragent($server) };
	return 0 unless $ua && $remote && $remote->{'manager'};

	my $url = _base_manager($remote->{'manager'}) . '/manager/address_report?signatorial=' . url_escape($me);
	my $tx = eval {
		$ua->connect_timeout(2)->inactivity_timeout(4)->post($url => json => {
			notice => $notice,
			reason => $reason,
			relay  => 1,
		});
	};
	return ($tx && !$tx->error && $tx->res->is_success) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Route helpers
# ---------------------------------------------------------------------------

sub _loopback {
	my ($c) = @_;
	my $remote = eval { $c->tx->remote_address } // '';
	my $local  = eval { $c->tx->local_address } // '';
	return 1 if $remote eq '127.0.0.1' || $remote eq '::1' || $remote eq '::ffff:127.0.0.1';
	return 1 if length $local && $remote eq $local;
	return 0;
}

# Find the caller's row from the names that route can spare (a query parameter
# or, when the query is already carrying the subject, the signed key header).
sub _caller_row {
	my ($c, @names) = @_;

	foreach my $name (@names) {
		my $sig = eval { $c->param($name) } // '';
		next unless length $sig;
		my $row = _row_for_sig($sig);
		return $row if $row;
	}

	my $encoded_key = eval { $c->req->headers->header('X-Peer-Key') } // '';
	if (length $encoded_key) {
		my $pem = eval { b64_decode($encoded_key) };
		if (defined $pem && length $pem) {
			foreach my $row (@{ _all_rows() }) {
				return $row if (($row->{'pubkey'} // '') eq $pem);
			}
		}
	}
	return undef;
}

sub _caller_ok {
	my ($c, $row) = @_;
	return 1 if _loopback($c);
	return 0 unless $row;
	my $ok = eval { &subs::peer_verify($c, $row) };
	return $ok ? 1 : 0;
}

sub _manager_is_tailnet {
	my ($manager) = @_;
	return 0 unless defined $manager && length $manager;
	my ($host) = $manager =~ m{^https?://([^/:]+)};
	return 0 unless defined $host && length $host;
	return 1 if _is_tailnet($host);
	if ($host =~ /[a-zA-Z]/) {
		require Socket;
		my $packed = gethostbyname($host);
		if ($packed) {
			return 1 if _is_tailnet(Socket::inet_ntoa($packed));
		}
	}
	return 0;
}

# Public form for the sync rail: the stored manager is a tailnet name whose node
# may be offline, so a directory lookup is worth asking for.
sub manager_is_tailnet {
	return _manager_is_tailnet($_[0]);
}

# Turn a verified notice into a network map + chosen address. A relay's source
# address must not be used as the subject's address: only a direct report may
# fall back to it.
sub _network_from_notice {
	my ($notice, $hint, $peer_ip, $now, $direct) = @_;

	my $port = $notice->{'port'} || 0;
	my $ws_port = $notice->{'ws_port'};
	my (%network, @ips);

	foreach my $item (split /;/, ($notice->{'nics'} // '')) {
		my ($nic, $ip, $mac) = split /\|/, $item, 3;
		next unless defined $nic && defined $ip && $nic ne '';
		next unless $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
		my $nic_port = $port || 45545;
		my %entry = (
			nic       => $nic,
			ip        => $ip,
			port      => $nic_port,
			manager   => 'https://' . $ip . ':' . $nic_port,
			timestamp => $now,
		);
		$entry{'ws_port'} = $ws_port if $ws_port;
		$entry{'mac'} = $mac if defined $mac && $mac ne '';
		$network{$nic} = \%entry;
		CORE::push @ips, $ip;
	}

	# The unsigned body may supplement a notice only when the caller is also the
	# subject; on a relay it is somebody else's claim and is ignored.
	if (ref $hint eq 'HASH') {
		foreach my $key (keys %{$hint}) {
			my $entry = $hint->{$key};
			next unless ref $entry eq 'HASH';
			my $was = (ref $network{$key} eq 'HASH') ? $network{$key} : {};
			$network{$key} = { %{$was}, %{$entry} };
		}
	}

	my ($direct_ip) = grep { $_ eq $peer_ip } @ips;
	my ($private_ip) = grep { _is_lan($_) } @ips;
	my $chosen = $direct_ip || $private_ip || $ips[0];
	$chosen = $peer_ip if !$chosen && $direct && $peer_ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;

	my $chosen_port = $port || 45545;
	if (defined $chosen && length $chosen) {
		$network{'lan'} = {
			%{ (ref $network{'lan'} eq 'HASH') ? $network{'lan'} : {} },
			nic       => 'lan',
			ip        => $chosen,
			port      => $chosen_port,
			manager   => 'https://' . $chosen . ':' . $chosen_port,
			hostname  => ($notice->{'hostname'} // ''),
			device    => ($notice->{'device'} // ''),
			version   => ($notice->{'version'} // ''),
			timestamp => $now,
		};
	}

	return (\%network, $chosen, $chosen_port, $ws_port);
}

# A report with no notice: the caller is the subject, so its body and source
# address are its own claim.
sub _network_from_report {
	my ($body, $peer_ip, $row, $now) = @_;

	my $network = (ref $body->{'network'} eq 'HASH') ? { %{ $body->{'network'} } } : {};
	my $port = $body->{'port'} || $row->{'port'} || 45545;
	my $ip = $body->{'ip'} // '';
	if (!length $ip && defined $peer_ip && $peer_ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/ && $peer_ip !~ /^127\./) {
		$ip = $peer_ip;
	}

	if (length $ip) {
		$network->{'lan'} = {
			%{ (ref $network->{'lan'} eq 'HASH') ? $network->{'lan'} : {} },
			nic       => 'lan',
			ip        => $ip,
			port      => $port,
			manager   => 'https://' . $ip . ':' . $port,
			timestamp => $now,
		};
	}

	my $ws_port = $body->{'ws_port'} || $row->{'ws_port'};
	return ($network, $ip, $port, $ws_port);
}

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

# POST /manager/address_report
# Body: { notice => <signed presence>, reason => '...', network => {...} }
sub route_report {
	my ($c) = @_;

	my $body = eval { $c->req->json };
	$body = {} unless ref $body eq 'HASH';

	my $caller_param = eval { $c->param('signatorial') } // '';
	my $caller_row = _caller_row($c, 'signatorial', 'caller');
	unless (_caller_ok($c, $caller_row)) {
		return $c->render(status => 403, json => { ok => 0, error => 'not a known peer' });
	}

	my $caller_sig = $caller_param;
	$caller_sig = ($caller_row->{'signatorial'} // '') if !length $caller_sig && $caller_row;
	$caller_sig = _me() if !length $caller_sig && _loopback($c);
	unless (length $caller_sig) {
		return $c->render(status => 400, json => { ok => 0, error => 'no caller' });
	}

	my $notice = $body->{'notice'};
	my $peer_ip = eval { $c->tx->remote_address } // '';
	my $now = _now();
	my $reason = $body->{'reason'} // '';

	my ($subject_sig, $subject_row, $network, $ip, $port, $ws_port);

	if (ref $notice eq 'HASH' && %{$notice}) {
		$subject_sig = $notice->{'signatorial'} // '';
		unless (length $subject_sig) {
			return $c->render(status => 400, json => { ok => 0, error => 'notice has no signatorial' });
		}
		$subject_row = _row_for_sig($subject_sig);
		unless ($subject_row) {
			return $c->render(status => 403, json => { ok => 0, error => 'the subject is not in the directory' });
		}
		unless (eval { &subs::lan_presence_verify($subject_row, $notice) }) {
			return $c->render(status => 403, json => { ok => 0, error => 'the notice is not signed by the subject' });
		}
		my $ts = $notice->{'ts'} // 0;
		unless ($ts =~ /^\d+$/ && abs(time() - $ts) <= 600) {
			return $c->render(status => 403, json => { ok => 0, error => 'the notice is stale' });
		}

		my $is_relay = ($subject_sig ne $caller_sig);
		my $hint = $is_relay ? undef : $body->{'network'};
		($network, $ip, $port, $ws_port) =
			_network_from_notice($notice, $hint, $peer_ip, $now, ($is_relay ? 0 : 1));
	}
	else {
		$subject_sig = $body->{'signatorial'} // $body->{'subject'} // $caller_sig;
		unless ($subject_sig eq $caller_sig) {
			return $c->render(status => 403, json => { ok => 0, error => 'an unsigned claim about another machine' });
		}
		$subject_row = _row_for_sig($subject_sig);
		unless ($subject_row) {
			return $c->render(status => 404, json => { ok => 0, error => 'not in the directory' });
		}
		($network, $ip, $port, $ws_port) = _network_from_report($body, $peer_ip, $subject_row, $now);
	}

	my $source = (ref $notice eq 'HASH' && %{$notice}) ? $notice : $body;
	my %update = (
		server_time => $now,
		connection  => 'active',
		status      => 'connected',
	);
	$update{'ip'} = $ip if defined $ip && length $ip;
	$update{'port'} = $port if defined $port && length $port;
	$update{'ws_port'} = $ws_port if defined $ws_port && length $ws_port;
	$update{'hostname'} = $source->{'hostname'} if defined $source->{'hostname'} && length $source->{'hostname'};
	$update{'version'} = $source->{'version'} if defined $source->{'version'} && length $source->{'version'};
	$update{'device'} = $source->{'device'} if defined $source->{'device'} && length $source->{'device'};
	$update{'fqdn'} = $source->{'fqdn'} if defined $source->{'fqdn'} && length $source->{'fqdn'};

	if (ref $network eq 'HASH' && %{$network}) {
		$update{'network'} = encode_json(_merge_network($subject_row->{'network'}, $network));
	}

	# The cloud's advertised name is what peers reach it by even when a beacon
	# arrives over a LAN-looking source. Keep it; only fill in a missing manager.
	# The same caution applies to a peer's domain or tunnel manager: only a raw
	# ip-literal manager is rewritten, because a name follows the machine and a
	# hub tunnel belongs to the hub (this is lan_presence_accept's rule too).
	if (defined $ip && length $ip && defined $port && length $port) {
		my $existing = $subject_row->{'manager'} // '';
		my ($host) = $existing =~ m{^https?://([^/:]+)};
		my $host_is_ip = (defined $host && $host =~ /^\d{1,3}(?:\.\d{1,3}){3}$/);
		if (!length $existing) {
			$update{'manager'} = 'https://' . $ip . ':' . $port;
		}
		elsif (($subject_row->{'device'} // '') ne 'server'
			&& $host_is_ip && $host !~ /^127\./) {
			$update{'manager'} = 'https://' . $ip . ':' . $port;
		}
	}

	eval { &subs::db_update('remote_machines', \%update, { signatorial => $subject_sig }) };

	my $generation = _generation(0);
	my $directory = directory_records();

	if (_is_server_here()) {
		$generation = _generation(1);
		eval { &push($directory) };
	}
	else {
		eval { _forward_report($notice, $reason) } if ref $notice eq 'HASH' && %{$notice};
		$generation = _generation(0);
	}

	&subs::log_writer('address directory: report from ' . $caller_sig . ' about ' . $subject_sig
		. ((ref $notice eq 'HASH' && %{$notice}) ? ' (relayed)' : ''));

	return $c->render(json => {
		ok         => 1,
		generation => $generation,
		directory  => $directory,
	});
}

# POST /manager/address_directory
# Body: { records => { <signatorial> => <record>, ... } }
sub route_directory {
	my ($c) = @_;

	my $body = eval { $c->req->json };
	$body = {} unless ref $body eq 'HASH';

	my $caller_row = _caller_row($c, 'caller', 'signatorial');
	unless (_caller_ok($c, $caller_row)) {
		return $c->render(status => 403, json => { ok => 0, error => 'not a known peer' });
	}

	my $caller_sig = $caller_row ? ($caller_row->{'signatorial'} // '') : '';
	$caller_sig = eval { $c->param('caller') } // '' unless length $caller_sig;
	$caller_sig = eval { $c->param('signatorial') } // '' unless length $caller_sig;

	my $is_server = $caller_row && (($caller_row->{'device'} // '') eq 'server');
	if (!$is_server && length $caller_sig) {
		foreach my $row (@{ _all_rows() }) {
			next unless (($row->{'signatorial'} // '') eq $caller_sig);
			next unless (($row->{'device'} // '') eq 'server');
			$is_server = 1;
			last;
		}
	}
	unless ($is_server || _loopback($c)) {
		return $c->render(status => 403, json => { ok => 0, error => 'only the server publishes the directory' });
	}

	my $applied = apply($body->{'records'});
	my $generation = _generation(0);
	&subs::log_writer('address directory: applied ' . $applied . ' record(s) from ' . $caller_sig) if $applied;

	return $c->render(json => {
		ok         => 1,
		generation => $generation,
		applied    => $applied,
	});
}

# GET /manager/address_lookup?signatorial=<subject>&caller=<asker>
sub route_lookup {
	my ($c) = @_;

	my $sig = eval { $c->param('signatorial') } // '';
	unless (length $sig) {
		return $c->render(status => 400, json => { ok => 0, error => 'no signatorial' });
	}

	my $caller_row = _caller_row($c, 'caller', 'me');
	unless (_caller_ok($c, $caller_row)) {
		return $c->render(status => 403, json => { ok => 0, error => 'not a known peer' });
	}

	my $cached = eval {
		&subs::cache_get({ app => $APP, context => 'address_lookup', subcontext => $sig });
	};
	if (ref $cached eq 'HASH') {
		return $c->render(json => { ok => 1, record => $cached });
	}

	my $row = _row_for_sig($sig);
	my $record;
	my $need_server = 0;
	if (!$row) {
		$need_server = 1;
	}
	elsif (_manager_is_tailnet($row->{'manager'})) {
		$need_server = 1;
	}
	else {
		$record = record_for($row);
	}

	if ($need_server && !_is_server_here()) {
		my ($server) = @{ server_rows() };
		if ($server) {
			my ($ua, $remote) = eval { &subs::peer_useragent($server) };
			if ($ua && $remote && $remote->{'manager'}) {
				my $url = _base_manager($remote->{'manager'}) . '/manager/address_lookup?signatorial=' . url_escape($sig)
					. '&caller=' . url_escape(_me());
				my $tx = eval {
					$ua->connect_timeout(2)->inactivity_timeout(4)->get($url);
				};
				if ($tx && !$tx->error && $tx->res->is_success) {
					my $answer = eval { decode_json($tx->res->body) } || {};
					if (ref $answer->{'record'} eq 'HASH') {
						$record = $answer->{'record'};
						eval { apply({ $sig => $record }) };
					}
				}
			}
		}
	}

	# The server could not be reached; a local row still gives the asker the
	# addresses this machine already knows rather than nothing at all.
	$record = record_for($row) if !$record && $row;

	# A machine can always answer for itself even when no roster row exists.
	if (!$record && $sig eq _me()) {
		$record = local_record('lookup');
	}

	if (ref $record eq 'HASH' && %{$record}) {
		eval {
			&subs::cache_set({
				app        => $APP,
				context    => 'address_lookup',
				subcontext => $sig,
				warranty   => '-1m',
			}, $record);
		};
		return $c->render(json => { ok => 1, record => $record });
	}

	return $c->render(json => { ok => 0, error => 'not in the directory' });
}

# Called by &subs::lan_presence_accept after it has already verified the notice.
# A peer that can see a server but cannot be seen by it (or cannot reach it when
# the tailnet is down) carries the signed blob along. Never dies.
sub relay_presence {
	my ($msg, $peer_ip) = @_;
	return 0 unless ref $msg eq 'HASH';

	my $sig = $msg->{'signatorial'} // '';
	return 0 unless length $sig;
	return 0 if $sig eq _me();

	my $ok = eval {
		return 0 if _is_server_here();

		my $subject_row = _row_for_sig($sig);
		return 0 unless $subject_row;
		return 0 if (($subject_row->{'device'} // '') eq 'server');

		return 0 if _recently('address_relay', 'relay:' . $sig, undef, 60);
		return 0 if ($relay_memo{$sig} || 0) > time() - 60;
		$relay_memo{$sig} = time();

		my ($server) = @{ server_rows() };
		return 0 unless $server;
		my $server_sig = $server->{'signatorial'} // '';
		return 0 if $server_sig eq $sig;

		my ($ua, $remote) = eval { &subs::peer_useragent($server) };
		return 0 unless $ua && $remote && $remote->{'manager'};

		my $url = _base_manager($remote->{'manager'}) . '/manager/address_report?signatorial=' . url_escape(_me());
		my $tx = eval {
			$ua->connect_timeout(2)->inactivity_timeout(4)->post($url => json => {
				notice => $msg,
				relay  => 1,
			});
		};
		return 0 unless $tx && !$tx->error && $tx->res->is_success;

		_stamp('address_relay', 'relay:' . $sig, undef, 60);
		&subs::log_writer('address directory: relayed ' . $sig . ' to ' . $server_sig);
		return 1;
	};

	return $ok ? 1 : 0;
}

# Stable digest of this machine's interfaces, for a network-change watcher.
sub fingerprint {
	my $network = eval { &subs::network_interface_reporter() } || {};
	my @parts;
	foreach my $nic (sort keys %{$network}) {
		my $entry = $network->{$nic};
		next unless ref $entry eq 'HASH';
		CORE::push @parts, join('|', $nic, ($entry->{'ip'} // ''), ($entry->{'port'} // ''));
	}
	return md5_sum(join(';', @parts));
}

1;
