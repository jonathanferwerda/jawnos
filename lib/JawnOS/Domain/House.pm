package subs;

# House: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $config;
our $device;
our %lan_reply_at;
our $lan_reply_beacon;
our %m;

# ---- public naming ---------------------------------------------------------
# config.json's `domain` is an address, not a name: it is the loopback the house
# calls itself on, so it is deliberately not a public name. The public side
# lives in two synced settings: the house domain (the wildcard's zone and the
# WebAuthn RP ID) and a per-device map, keyed by signatorial, of the name each
# machine answers on. The map is written once from any machine and read by each
# device for its own entry, so a name never has to be typed on the device
# itself.
sub house_domain {
	my $v = &setting_grabber({ app => '__president', setting => 'house_domain', device => 'all' });
	return '' unless defined $v && length $v;
	$v =~ s/^\s+|\s+$//g;
	$v =~ s{^https?://}{}i;
	$v =~ s{/.*$}{};
	$v =~ s{:\d+$}{};
	return lc $v;
}

sub device_hosts {
	my $raw = &setting_grabber({ app => '__president', setting => 'device_hosts', device => 'all' });
	my $map = eval { &decode_json($raw) } || {};
	return ref $map eq 'HASH' ? $map : {};
}

sub public_host {
	my $map = &device_hosts();
	my $sig = &signatorial_designer();
	my $host = (defined $sig && length $sig) ? ($map->{$sig} || '') : '';
	$host =~ s/^\s+|\s+$//g;
	return length $host ? lc $host : '';
}

sub public_origin_host {
	my $host = &public_host();
	return $host if length $host;
	my $config = eval { &config_reader() } || {};
	my $c = $config->{'public_host'} || '';
	$c =~ s/^\s+|\s+$//g;
	return lc $c if length $c && $c !~ /^(?:127\.|localhost$|\[?::1\]?)$/i;
	my $d = $config->{'domain'} || '';
	return '' if $d =~ /^(?:127\.|localhost$|\[?::1\]?)$/i;
	return lc $d;
}

sub tailnet_address {
	my ($rm) = @_;
	my $network = ref($rm->{'network'}) eq 'HASH' ? $rm->{'network'} : (eval { decode_json($rm->{'network'} || '{}') } || {});
	my $tailnet = sub {
		my $ip = shift;
		return $ip if defined $ip && $ip =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./;
		return '';
	};
	foreach my $nic ( keys %{$network} ) {
		my $entry = $network->{$nic};
		next unless ref $entry eq 'HASH';
		my $ip = $tailnet->($entry->{'ip'});
		return $ip if $ip;
	}
	return $tailnet->($rm->{'ip'});
}

# A peer advertises its own name as its manager. On a machine whose dnsmasq or
# hosts map that name back to itself - or when a hub-tunnel manager sits at
# 127.0.0.1 while we are a peer, not the hub - reaching it that way loops home.
# When the manager host resolves to loopback, or onto the tailnet, fall back to
# the LAN address the peer reported in its network map, so same-net peers talk
# directly. The tailnet counts because 100.64.0.0/10 is CGNAT: a node that is
# offline blackholes the connection until the timeout rather than refusing it.
sub peer_lan_address {
	my ($rm, $force) = @_;
	return undef unless $rm && $rm->{'manager'};
	# The hub's 127.0.0.1 tunnel managers are correct there, and it is not on the
	# peers' LAN - this fallback is only for a peer reaching another peer.
	return undef if &subs::device_setter() eq 'server';
	return undef unless $rm->{'network'};
	my ($host) = $rm->{'manager'} =~ m{^https?://([^:/]+)};
	return undef unless $host;
	# Normally only a manager that loops home (resolves to 127.0.0.1) is swapped
	# for the LAN address. $force skips that: a mirror is reached through the
	# source's public tunnel name, yet when the peer shares our own network the
	# direct LAN address is still the better route.
	unless ($force) {
		my $loopback = 0;
		my $resolved = 0;
		my $tailnet = 0;
		if ($host =~ /^127\./) { $loopback = 1; $resolved = 1; }
		elsif ($host =~ /[a-zA-Z]/) {
			require Socket;
			my $packed = gethostbyname($host);
			if ($packed) {
				$resolved = 1;
				my $addr = Socket::inet_ntoa($packed);
				$loopback = 1 if $addr =~ /^127\./;
				# 100.64.0.0/10 is the CGNAT range Tailscale hands out. A name that
				# resolves onto the tailnet is only reachable while that node is up;
				# when it is offline the request blackholes until the timeout. Treat
				# it like an unresolved name and fall through to the LAN address.
				$tailnet = 1 if $addr =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./;
			}
		}
		else {
			$resolved = 1;
			# A literal manager address in that range is the same dead route.
			$tailnet = 1 if $host =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./;
		}
		# A name that resolves somewhere else is the peer's real address; keep
		# it. A name that no longer resolves at all (the machine hopped to a
		# network where its old router or tailnet DNS is gone) falls through to
		# the LAN address it advertised, so the presence notice still finds it
		# instead of every call waiting on a dead lookup. The same applies to a
		# tailnet (CGNAT) address, which is only alive while that node is.
		return undef if $resolved && !$loopback && !$tailnet;
	}
	# a mirror arrives already decoded; a normal row is a JSON string
	my $you = ref $rm->{'network'} eq 'HASH' ? $rm->{'network'} : (eval { decode_json $rm->{'network'} } || {});
	# our own interfaces rarely change; don't run ifconfig per peer per call
	our ($_ME_NETWORK, $_ME_NETWORK_AT);
	unless ($_ME_NETWORK && $_ME_NETWORK_AT > &subs::rightNow() - 60000) {
		$_ME_NETWORK = &subs::network_interface_reporter();
		$_ME_NETWORK_AT = &subs::rightNow();
	}
	my $me = $_ME_NETWORK;
	foreach my $nic ( sort keys %{$you} ) {
		next if $nic eq 'public_address' || !$you->{$nic}->{'ip'};
		my $you_ip = $you->{$nic}->{'ip'};
		next if $you_ip =~ /^127\./;
		foreach my $nicc ( sort keys %{$me} ) {
			next if $nicc eq 'public_address' || !$me->{$nicc}->{'ip'};
			next unless &subs::same_net_test($you_ip, $me->{$nicc}->{'ip'}) eq 'yes';
			my $port = $you->{$nic}->{'port'} || $rm->{'port'} || 45545;
			return { ip => $you_ip, port => $port, manager => 'https://' . $you_ip . ':' . $port };
		}
	}
	return undef;
}

# The url to call for one candidate, in the order remote_machine_online probes
# them. A literal address is called directly. The peer's fqdn is called by
# name - unless the row is a tunnel, because a hub's hosts/dnsmasq can resolve
# the peer's name to loopback there and the stored tunnel manager is the only
# route that reaches it. Anything else uses the manager the row carries.
sub peer_manager_url {
	my ($rm, $candidate, $port) = @_;
	$rm ||= {};
	my $manager = $rm->{'manager'} || '';
	my $fqdn = $rm->{'fqdn'} || '';
	$port = undef unless defined $port && $port =~ /^[0-9]+$/;
	$port = $rm->{'port'} if (!defined $port || $port !~ /^[0-9]+$/);
	$port = $1 if ((!defined $port || $port !~ /^[0-9]+$/)
		&& $manager =~ m{:([0-9]{1,5})/?$});
	$port ||= 45545;
	if (defined $candidate && $candidate =~ /^\d+\.\d+\.\d+\.\d+$/) {
		return 'https://' . $candidate . ':' . $port;
	}
	if (($rm->{'tunnel'} || '') ne 'yes'
		&& $fqdn ne '' && defined $candidate && $candidate eq $fqdn) {
		return 'https://' . $fqdn . ':' . $port;
	}
	return $manager;
}

# ---------------------------------------------------------------------------
# Peer addressing without the tailnet
#
# The house names (*.jonathanferwerda.com) resolve through the tailnet's DNS.
# With the VPN off and no router entry for them, gethostbyname fails outright,
# so a row whose only address is its name cannot be dialled - even though the
# row still carries the LAN address the peer last advertised. The helpers below
# keep the literal addresses a row knows about ahead of the names, so the
# plain-wifi path is tried first and the tailnet name stays as the last resort.
# ---------------------------------------------------------------------------

# A literal address needs no resolver. (IPv6 literals are accepted so a row that
# already carries one is not skipped; the probe formats it as-is.)
sub peer_host_is_literal {
	my $host = shift;
	return 0 unless defined $host && length $host;
	return 1 if $host =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	return 1 if $host =~ /^[0-9a-fA-F:.]+$/ && $host =~ /:/;
	return 0;
}

sub peer_host_is_loopback {
	my $host = shift || '';
	return 1 if $host =~ /^127\./;
	return 1 if $host =~ /^(?:localhost|::1)$/i;
	return 0;
}

# 0 = a private LAN or link-local address, 1 = the tailnet's CGNAT range,
# 2 = anything else. Probing a same-wifi peer on its LAN first means a dead
# tailnet route cannot hold up the pass, while the tailnet is still tried.
sub peer_address_rank {
	my $host = shift || '';
	return 0 if $host =~ /^(?:10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|169\.254\.)/;
	return 1 if $host =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./;
	return 2;
}

# The host and port a stored manager url names.
sub peer_manager_host {
	my ($rm) = @_;
	my $manager = ($rm && $rm->{'manager'}) || '';
	my ($host) = $manager =~ m{^https?://(\[[^\]]+\]|[^/:]+)};
	return (undef, undef) unless defined $host && length $host;
	$host =~ s/^\[|\]$//g;
	my ($port) = $manager =~ m{:([0-9]{1,5})/?$};
	return ($host, $port);
}

# A manager url with no route path. The panel and the CLI hand over the address a
# person clicks (https://host:port/manager), while the peer rail appends
# /manager/... itself: keeping the suffix dials .../manager/manager/configure/...
# and the pull reads the Gate page as "the peer sent no snapshot" (the tablet,
# 2026-10-31). A tunnel's loopback route is still a base url; only the trailing
# route segment is dropped.
sub peer_manager_base {
	my $manager = shift || '';
	return '' unless length $manager;
	$manager =~ s{/+$}{};
	$manager =~ s{/manager$}{};
	return $manager;
}

# Which roster row a person or a script meant by a name. An exact uuid,
# signatorial, hostname, fqdn, ip or name wins over a longer value that merely
# contains the term; an ambiguous substring is refused rather than guessed at.
# Both Android machines report the hostname 'localhost' (Android has no hostname
# of its own), so a plain hostname is not unique in this house - the refusal
# names each candidate by hostname, ip and signatorial so the caller can pick.
#
# A row's `ip` is only the address it was last reached at, so every literal the
# row advertises is matched too: the LAN and tailnet addresses it remembers and
# the interfaces in its network map. Without that, a machine whose row had moved
# to its tailnet address could not be named by its LAN ip at all.
sub peer_resolve {
	my ($term, $rows) = @_;
	return (undef, 'no machine named') unless defined $term && length $term;
	my $t = lc $term;
	my @rows = grep { ref $_ eq 'HASH' } @{ $rows || [] };
	# An exact match wins outright, including an address that no name contains;
	# only when nothing matches exactly does a substring decide.
	my @match = grep {
		my $r = $_;
		grep { defined $_ && lc($_) eq $t } &peer_resolve_fields($r, 1);
	} @rows;
	unless (@match) {
		@match = grep {
			my $r = $_;
			grep { defined $_ && lc($_) =~ /\Q$t\E/ } &peer_resolve_fields($r);
		} @rows;
	}
	return (undef, 'no machine matches "' . $term . '"') unless @match;
	if (@match > 1) {
		my @named = map {
			my $label = $_->{'hostname'} || '';
			$label = ($label ne '' ? $label . ' ' : '')
				. ($_->{'ip'} || '?') . ' [' . ($_->{'signatorial'} || '?') . ']';
			$label;
		} @match;
		return (undef, 'that matches more than one machine: ' . join(', ', @named));
	}
	return ($match[0], '');
}

# The values a row can be named by. The names match on a substring; a literal
# address is added only for the exact pass, since half an ip would name half a
# house. `domain` is a substring-only value, as it always was.
sub peer_resolve_fields {
	my ($r, $with_addresses) = @_;
	my @named = map { $r->{$_} } qw/uuid signatorial hostname fqdn ip name/;
	push @named, $r->{'domain'} unless $with_addresses;
	push @named, &peer_resolve_addresses($r) if $with_addresses;
	my %seen;
	return grep { !$seen{$_}++ } grep { defined $_ && length $_ } @named;
}

# The literal addresses a roster row advertises, beyond its own `ip`.
sub peer_resolve_addresses {
	my ($r) = @_;
	my @out = grep { defined $_ && length $_ } map { $r->{$_} } qw/lan_ip vip tailnet_ip/;
	my $network = eval { decode_json($r->{'network'} || '{}') };
	if (ref $network eq 'HASH') {
		foreach my $nic ( sort keys %{$network} ) {
			my $entry = $network->{$nic};
			next unless ref $entry eq 'HASH';
			push @out, $entry->{'ip'} if defined $entry->{'ip'} && length $entry->{'ip'};
		}
	}
	return @out;
}

# --- Android sshd ----------------------------------------------------------
# Termux's sshd_config comments out every HostKey line, Android has no /etc/ssh,
# and the login user's home in the passwd entry is the old Termux prefix. A bare
# `sshd` therefore starts with no usable host key (or resolves keys and
# authorized_keys under a path this app cannot read), and key auth silently
# fails while the port still answers. Start it once, here, with the prefix's own
# keys and an absolute AuthorizedKeysFile. StrictModes is off because it walks
# /data/user/0, which is system-owned.
sub sshd_running {
	foreach my $proc ( glob('/proc/[0-9]*') ) {
		my $cmd = eval { read_file("$proc/cmdline") } || '';
		$cmd =~ s/\0.*//s;
		return 1 if $cmd =~ m{(?:^|/)sshd$};
	}
	return 0;
}

sub sshd_start {
	my @cmd = &sshd_command();
	return 0 unless @cmd;
	system(@cmd);
	return 1;
}

# The argv for the daemon, with no side effects, so the options can be checked.
sub sshd_command {
	my ($prefix, $home) = @_;
	$prefix = $ENV{'PREFIX'} || '' unless defined $prefix && length $prefix;
	return () unless length $prefix;
	$home = $ENV{'HOME'} || "$prefix/home" unless defined $home && length $home;
	my @host_keys = grep { -f $_ } map { "$prefix/etc/ssh/ssh_host_$_\_key" } qw/ed25519 ecdsa rsa/;
	my @sshd = (
		'sshd', '-f', "$prefix/etc/ssh/sshd_config",
		'-o', "PidFile=$prefix/tmp/sshd.pid",
		'-o', "AuthorizedKeysFile=$home/.ssh/authorized_keys",
		'-o', 'StrictModes=no',
		'-o', "SetEnv=HOME=$home",
	);
	push @sshd, ('-h', $_) foreach @host_keys;
	return @sshd;
}

# Every literal address a peer row can be dialled at, best first: the stored ip,
# the LAN address it advertised, the manager's literal host, the address map,
# a stored pseudonym and the tailnet address. Names are added by
# peer_probe_candidates; they need the resolver and are worth trying last.
sub peer_literal_addresses {
	my ($rm) = @_;
	$rm ||= {};
	my @out;
	my %seen;
	my $default_port = $rm->{'port'};
	$default_port = $1 if ((!defined $default_port || $default_port !~ /^[0-9]+$/) && (($rm->{'manager'} || '') =~ m{:([0-9]{1,5})/?$}));
	my $add = sub {
		my ($host, $port, $why) = @_;
		return unless defined $host && length $host;
		return unless &peer_host_is_literal($host);
		return if $host =~ /^(?:0\.0\.0\.0|255\.255\.255\.255)$/;
		# A loopback address is a real route only on the hub's tunnel row; on
		# any other row it is the leftover of a tunnel that is gone.
		return if &peer_host_is_loopback($host) && ($rm->{'tunnel'} || '') ne 'yes';
		$port = $default_port if (!defined $port || $port !~ /^[0-9]+$/);
		$port = 45545 unless defined $port && $port =~ /^[0-9]+$/;
		my $key = $host . ':' . $port;
		return if $seen{$key}++;
		push @out, { host => $host, port => $port + 0, why => ($why || ''), literal => 1 };
	};
	&$add($rm->{'ip'}, $default_port, 'ip');
	&$add($rm->{'lan_ip'}, $default_port, 'lan');
	&$add($rm->{'vip'}, $default_port, 'vip');
	my $lan = eval { &peer_lan_address($rm, 1) };
	&$add($lan->{'ip'}, $lan->{'port'}, 'advertised lan') if ref $lan eq 'HASH';
	my ($mhost, $mport) = &peer_manager_host($rm);
	&$add($mhost, $mport, 'manager') if defined $mhost && &peer_host_is_literal($mhost);
	# The address map is the peer's own view of its interfaces. On a machine
	# that is not the hub it is the only place a same-wifi address may live, so
	# try each private NIC even when the stored manager names something dead.
	if (&device_setter() ne 'server' && $rm->{'network'}) {
		my $you = ref $rm->{'network'} eq 'HASH' ? $rm->{'network'} : (eval { decode_json $rm->{'network'} } || {});
		foreach my $nic ( sort keys %{$you} ) {
			next if $nic eq 'public_address' || ref $you->{$nic} ne 'HASH';
			my $entry = $you->{$nic} || {};
			&$add($entry->{'ip'}, $entry->{'port'} || $default_port, 'advertised ' . $nic);
		}
	}
	if ($rm->{'pseudonyms'}) {
		my $pseu = eval { decode_json $rm->{'pseudonyms'} } || {};
		&$add($pseu->{'ip'}, $pseu->{'port'}, 'pseudonym') if ref $pseu eq 'HASH';
	}
	&$add($rm->{'tailnet_ip'} || &tailnet_address($rm), $default_port, 'tailnet');
	# Private LAN first, then the tailnet, then anything else; insertion order
	# breaks ties so the row's own ip keeps its precedence.
	my $i = 0;
	my %at = map { $_->{'host'} . ':' . $_->{'port'} => $i++ } @out;
	@out = sort {
		&peer_address_rank($a->{'host'}) <=> &peer_address_rank($b->{'host'})
			|| $at{$a->{'host'} . ':' . $a->{'port'}} <=> $at{$b->{'host'} . ':' . $b->{'port'}}
	} @out;
	return \@out;
}

# The literal addresses first, then the names (the peer's fqdn and any name in
# its stored manager). A name that does not resolve is skipped by the probe.
sub peer_probe_candidates {
	my ($rm, $port) = @_;
	$rm ||= {};
	my @out = @{ &peer_literal_addresses($rm) };
	my %seen = map { ($_->{'host'} . ':' . $_->{'port'}) => 1 } @out;
	$port = $rm->{'port'} if (!defined $port || $port !~ /^[0-9]+$/);
	$port = $1 if ((!defined $port || $port !~ /^[0-9]+$/) && (($rm->{'manager'} || '') =~ m{:([0-9]{1,5})/?$}));
	$port ||= 45545;
	my $add = sub {
		my ($host, $why) = @_;
		return unless defined $host && length $host;
		return if &peer_host_is_literal($host);
		return if $host =~ /^(?:localhost|::1)$/i;
		my $key = $host . ':' . $port;
		return if $seen{$key}++;
		push @out, { host => $host, port => $port + 0, why => ($why || ''), literal => 0 };
	};
	&$add($rm->{'fqdn'}, 'fqdn');
	my ($mhost) = &peer_manager_host($rm);
	&$add($mhost, 'manager name');
	return \@out;
}

# The one address a row carries without needing DNS, as a manager url. Used
# when a stored manager names a host that does not resolve on this network.
sub peer_literal_manager {
	my ($rm) = @_;
	my $addrs = &peer_literal_addresses($rm);
	my $best = $addrs->[0] || return undef;
	my $port = $best->{'port'} || ($rm && $rm->{'port'}) || 45545;
	return 'https://' . $best->{'host'} . ':' . $port;
}

# Ask a peer whether it is there, and which address answered. The caller's own
# candidate ($opts->{ip}, e.g. a same-net probe) is tried first; the rest come
# from the row. A name that does not resolve is skipped without shelling out
# `ping` (that is the 'unknown host' noise on a machine with no VPN), and a
# literal address is still dialled when ping gets no reply: ICMP is a hint for
# how long to wait, never the gate, because a peer may drop echo while its
# manager answers. Returns { ok => 1, manager, ip, port } or { ok => 0 }.
sub peer_presence_probe {
	my ($rm, $opts) = @_;
	$opts ||= {};
	$rm ||= {};
	my $remote_signatorial = $opts->{'signatorial'} || $rm->{'signatorial'} || '';
	return { ok => 0 } unless length $remote_signatorial;
	my @candidates = @{ &peer_probe_candidates($rm, $opts->{'port'}) };
	if (defined $opts->{'ip'} && length $opts->{'ip'}) {
		my $first = $opts->{'ip'};
		@candidates = grep { ($_->{'host'} || '') ne $first } @candidates;
		my $port = $opts->{'port'};
		$port = 45545 unless defined $port && $port =~ /^[0-9]+$/;
		unshift @candidates, { host => $first, port => $port + 0, why => 'caller', literal => &peer_host_is_literal($first) ? 1 : 0 };
	}
	my $fetch = $opts->{'fetch'};
	my $ping  = $opts->{'ping'};
	my $rs = &encrypter(&shorthand_name(&rightNow(), 5) . &shorthand_name($remote_signatorial, 5), $remote_signatorial);
	foreach my $c ( @candidates ) {
		my $host = $c->{'host'};
		next unless defined $host && length $host;
		my $literal = &peer_host_is_literal($host) ? 1 : 0;
		# A name with no DNS answer cannot be dialled. Say nothing and move on:
		# the literal candidates already ran, and the rest of the pass must not
		# be lost to a lookup failure.
		if (!$literal) {
			require Socket;
			next unless gethostbyname($host);
		}
		my $alive = 0;
		if ($literal) {
			if (ref $ping eq 'CODE') { $alive = $ping->($host) ? 1 : 0; }
			elsif (!$opts->{'no_ping'}) {
				my $reply = `timeout 1 ping -c 1 $host 2>/dev/null`;
				$alive = 1 if $reply =~ /ttl/;
			}
		}
		my $port = $c->{'port'};
		$port = $rm->{'port'} if (!defined $port || $port !~ /^[0-9]+$/);
		$port ||= 45545;
		my $base = &peer_manager_url($rm, $host, $port);
		my $url = $base . '/?signatorial=' . url_escape $rs;
		my $body = '';
		if (ref $fetch eq 'CODE') {
			$body = eval { $fetch->({ host => $host, port => $port, base => $base, url => $url, literal => $literal, alive => $alive, why => $c->{'why'} }) } || '';
		}
		else {
			my $ua = Mojo::UserAgent->new;
			$ua = $ua->max_response_size(0);
			$ua->insecure(1);
			$ua->connect_timeout($alive ? 5 : 3);
			$ua->inactivity_timeout($alive ? 15 : 6);
			$ua->request_timeout($alive ? 20 : 8);
			my $tx = eval { $ua->get($url => { user_agent => $remote_signatorial }) };
			$body = eval { $tx->result->body } || '';
		}
		if (defined $body && $body eq $remote_signatorial) {
			return { ok => 1, manager => $base, ip => $host, port => $port + 0, host => $host };
		}
	}
	return { ok => 0 };
}

# A loopback manager is the hub's own tunnel route. On any other row it is a
# leftover from a tunnel that no longer exists; a literal LAN address is the
# route that still works with the VPN off, and the peer's fqdn is the last
# resort (the name is only usable while the tailnet's DNS answers).
sub peer_live_manager {
	my ($rm) = @_;
	$rm ||= {};
	my $manager = $rm->{'manager'} || '';
	return $manager unless $manager =~ m{^https?://};
	my ($host) = &peer_manager_host($rm);
	return $manager unless defined $host && length $host;
	my $loopback = &peer_host_is_loopback($host) ? 1 : 0;
	# A name that no longer resolves is as dead as a retired loopback port. The
	# stored LAN address is the only route left on a plain-wifi network.
	my $resolves = 1;
	if (!$loopback && !&peer_host_is_literal($host)) {
		require Socket;
		$resolves = gethostbyname($host) ? 1 : 0;
	}
	if ($loopback) {
		return $manager if ($rm->{'tunnel'} || '') eq 'yes';
		my $literal = &peer_literal_manager($rm);
		return $literal if $literal;
		my $fqdn = $rm->{'fqdn'} || '';
		return $manager unless $fqdn ne '' && $fqdn !~ m{^127\.};
		return &peer_manager_url($rm, $fqdn, $rm->{'port'});
	}
	if (!$resolves) {
		my $literal = &peer_literal_manager($rm);
		return $literal if $literal;
	}
	return $manager;
}

# ---- LAN presence: a peer on whatever network we have just joined ----------
# Every House machine broadcasts a small signed UDP datagram on its LANs. mDNS
# is the other advertisement, and the embedded devices use it, but Termux has no
# avahi - so a broadcast is the one discovery path the phone and tablet share
# with the computers. A beacon can only refresh a peer that is already in
# remote_machines (matched by signatorial); it never introduces a stranger, and
# the signed peer rail still authenticates every real request. The payload is
# signed once and rebroadcast, so the phone is not running openssl every five
# seconds.
sub lan_presence_port { return 45552; }

sub lan_presence_canonical {
	my ($msg) = @_;
	return 'JAWNOS-LAN' . "\n" . join("\n",
		map { $_ . '=' . (defined $msg->{$_} ? $msg->{$_} : '') }
		grep { $_ ne 'sig' } sort keys %{$msg});
}

# The interfaces a beacon is sent on, or matched against: a real IPv4 LAN, not
# loopback and not the public address.
sub lan_presence_network {
	my $net = &network_interface_reporter();
	my @nics;
	foreach my $nic ( sort keys %{$net} ) {
		next if $nic eq 'lo';
		my $a = $net->{$nic} || {};
		next unless ($a->{'ip'} // '') =~ /^\d{1,3}(\.\d{1,3}){3}$/;
		next if $a->{'ip'} =~ /^127\./;
		next unless &ip_is_private($a->{'ip'});
		push @nics, { %{$a}, nic => $nic };
	}
	return \@nics;
}

sub lan_presence_payload {
	my $config = &config_reader();
	# The name a person reads, not the OS hostname: Termux answers 'localhost',
	# which every machine would then show for both handhelds.
	my $hostname = &machine_name();
	my @nics = @{ &lan_presence_network() };
	my $msg = {
		type         => 'jawnos-lan',
		signatorial  => &signatorial_designer(),
		hostname     => $hostname,
		name         => ($config->{'name'} || ''),
		device       => &device_setter(),
		version      => &jawn_version(),
		manager_file => (eval { &Manager::manager_file_maker() } || ''),
		port         => ($ENV{PORT_AHOY} || $config->{'working_port'} || 45545),
		ws_port      => ($ENV{PORT_MSG} || ''),
		dock_port    => ($ENV{PORT_DOCK} || 3000),
		alarm_port   => ($ENV{PORT_BELL} || ''),
		nics         => join(';', map { join('|', $_->{'nic'}, $_->{'ip'}, ($_->{'mac'} // '')) } @nics),
		ts           => int(time()),
		nonce        => &random_string_creator(16),
	};
	my $pub = &peer_pubkey();
	$msg->{'pubkey'} = $pub if $pub;
	my $sig = &peer_sign_blob(&lan_presence_canonical($msg));
	$msg->{'sig'} = $sig if $sig;
	return $msg;
}

sub lan_presence_verify {
	my ($rm, $msg) = @_;
	my $sig = $msg->{'sig'} // '';
	my $stored = $rm->{'pubkey'} // '';
	# Unsigned is the same first-contact rule the peer rail uses: fine only while
	# this peer has no key on file yet.
	return 1 unless $stored || $sig;
	my $pub = $stored || ($msg->{'pubkey'} // '');
	return 0 unless $pub && $sig && index($pub, '-----BEGIN PUBLIC KEY-----') == 0;
	my $ok = &signature_verify($pub, &lan_presence_canonical($msg), $sig);
	return 0 unless $ok;
	&db_update('remote_machines', { pubkey => $pub }, { uuid => $rm->{'uuid'} }) if !$stored;
	return 1;
}

# A beacon arrived from $peer_ip. Refresh the row only when it is one of ours and
# the address is on a network we are on, then wake the mesh so the sync starts
# now rather than on its next timer.
sub lan_presence_accept {
	my ($msg, $peer_ip) = @_;
	return unless ref $msg eq 'HASH';
	return unless ($msg->{'type'} // '') eq 'jawnos-lan';
	my $sig = $msg->{'signatorial'} // '';
	return unless $sig && $sig ne &signatorial_designer();
	my $ts = $msg->{'ts'} // 0;
	return unless $ts =~ /^\d+$/ && abs(time() - $ts) <= 600;
	return unless ($peer_ip // '') =~ /^\d{1,3}(\.\d{1,3}){3}$/;
	my $same = grep { &same_net_test($_->{'ip'}, $peer_ip) eq 'yes' } @{ &lan_presence_network() };
	return unless $same;
	my $rm = &db_select('remote_machines', undef, { signatorial => $sig })->hashes->[0];
	return unless $rm;
	return unless &lan_presence_verify($rm, $msg);
	my $now = &rightNow();
	my $net = eval { decode_json $rm->{'network'} } || {};
	$net = {} unless ref $net eq 'HASH';
	my $port = $msg->{'port'} || $rm->{'port'} || 45545;
	my $mac = '';
	foreach my $nic ( split /;/, ($msg->{'nics'} // '') ) {
		my ($n, $ip, $m) = split /\|/, $nic, 3;
		next unless $ip && $ip eq $peer_ip;
		$mac = $m if $m;
	}
	my $old_lan = $net->{'lan'} || {};
	my $changed = 0;
	$changed = 1 if (($old_lan->{'ip'} // '') ne $peer_ip);
	$changed = 1 if (($old_lan->{'port'} // '') ne $port);
	$changed = 1 if (($old_lan->{'mac'} // '') ne $mac);
	$changed = 1 if (($rm->{'ip'} // '') ne $peer_ip);
	$changed = 1 if (($rm->{'connection'} // '') ne 'active');
	$changed = 1 if (($rm->{'status'} // '') ne 'connected');
	my $version = $msg->{'version'} // '';
	$changed = 1 if ($version && ($rm->{'version'} // '') ne $version);
	$net->{'lan'} = {
		%{$old_lan},
		nic       => 'lan',
		ip        => $peer_ip,
		port      => $port,
		manager   => 'https://' . $peer_ip . ':' . $port,
		mac       => $mac,
		hostname  => ($msg->{'hostname'} // ''),
		device    => ($msg->{'device'} // ''),
		version   => ($msg->{'version'} // ''),
		timestamp => $now,
	};
	# The row shows the LAN address while the peer is here; peer_lan_address and
	# remote_machine_tunnel_processor still hold the fqdn/tunnel for when it
	# leaves, and remote_machine_online tries that fqdn when the LAN address has
	# gone quiet.
	my $buttons = $rm->{'buttons'} // '';
	my $old_ip = $rm->{'ip'} // '';
	$buttons =~ s/\bip="\Q$old_ip\E"/ip="$peer_ip"/g if $old_ip && $old_ip ne $peer_ip;
	# The Dev panel's version beside the peer comes from this stored button block;
	# refresh it whenever the beacon reports a different build.
	if ($version) {
		$buttons =~ s/(class="neighbour_version"[^>]*>)v[^<]*(<\/span>)/$1v$version$2/;
	}
	my $update = {
		ip          => $peer_ip,
		network     => encode_json $net,
		server_time => $now,
		status      => 'connected',
		connection  => 'active',
	};
	$update->{'version'} = $version if $version;
	$update->{'buttons'} = $buttons if $buttons ne ($rm->{'buttons'} // '');
	# A peer that advertises a bare address - Termux has no hostname to give -
	# has to keep that address current. After DHCP moved it, the stored manager
	# still pointed at the old subnet, so every pull and health call timed out
	# while its beacons (which carry the new source address) kept arriving. A
	# name is left alone because DNS follows the machine, and a tunnel manager
	# belongs to the hub; only an ip-literal manager is rewritten here.
	my ($row_host) = (($rm->{'manager'} || '') =~ m{^https?://([^/:]+)});
	if (($rm->{'tunnel'} // '') ne 'yes'
		&& defined $row_host && $row_host =~ /^\d{1,3}(?:\.\d{1,3}){3}$/
		&& $row_host !~ /^127\./
		&& $port =~ /^\d+$/) {
		my $scheme = (($rm->{'manager'} || '') =~ m{^http:}) ? 'http' : 'https';
		# Prefer the name the peer advertises when it resolves to the address
		# this beacon came from. A name follows the machine when it moves; an
		# ip is only true on the network it was learned on.
		my $host = $peer_ip;
		my $fqdn = $rm->{'fqdn'} || '';
		if ($fqdn ne '') {
			require Socket;
			my $packed = gethostbyname($fqdn);
			my $resolved = $packed ? Socket::inet_ntoa($packed) : '';
			$host = $fqdn if $resolved eq $peer_ip;
		}
		my $wanted = $scheme . '://' . $host . ':' . $port;
		if ($wanted ne ($rm->{'manager'} || '')) {
			$update->{'manager'} = $wanted;
			$update->{'port'} = $port;
			$changed = 1;
		}
	}
	# Heal a row still wearing a placeholder name. A device that reported
	# 'localhost' (Android has no hostname of its own) kept it forever, because
	# the beacon path never revisited the column; its fqdn names it, so use it.
	my $better = &device_hostname_better($msg->{'hostname'}, $rm->{'hostname'}, $rm->{'fqdn'});
	if ($better ne '' && $better ne ($rm->{'hostname'} // '')) {
		$update->{'hostname'} = $better;
		$changed = 1;
	}
	# Remember the peer's tailnet address while it has one. The live map drops the
	# interface when the VPN goes down, and then the row has no address off the
	# LAN left to probe.
	my $tailnet = &tailnet_address($rm);
	if ($tailnet ne '' && $tailnet ne ($rm->{'tailnet_ip'} // '')) {
		$update->{'tailnet_ip'} = $tailnet;
		$changed = 1;
	}
	&db_update('remote_machines', $update, { signatorial => $sig }) if $changed;
	# The Dev panel's neighbour table is this machine's devices row, not the
	# remote_machines row; put the new address and version there too and refresh
	# an open panel in place.
	my $dev_changed = &lan_presence_note_device($msg, $peer_ip, $mac, $port);
	eval { &Websocket::send('server', { console => 'deviceLister()' }) } if $changed || $dev_changed;
	# A unicast reply teaches the sender our address too. Android/Termux filters
	# broadcast reception on Wi-Fi, so the sender's sweep may be the only thing we
	# heard; the reply is the other half that lets both ends learn each other.
	&lan_presence_reply($peer_ip) if $changed;
	&lan_presence_wake() if $changed;
	# Carry the signed notice to the house server on this peer's behalf. A phone
	# whose tailnet is down still has a LAN peer that can reach the server, and the
	# server is where another machine asks when its stored name goes stale. The
	# call is self-throttled, so a failed forward retries on a later beacon.
	eval { &AddressDirectory::relay_presence($msg, $peer_ip) } if defined &AddressDirectory::relay_presence;
}

# Fold a peer's presence into this machine's own devices row, so the Dev panel's
# network cards show the peer at the address it is on now, with its purpose and
# the machine's own name. The entry is the same shape a scan writes, so the
# existing row actions and the tunnel/restore display keep working.
sub lan_presence_note_device {
	my ($msg, $peer_ip, $mac, $port) = @_;
	my $hostname = `hostname`;
	chomp $hostname;
	my $me = &db_select('devices', undef, { hostname => $hostname })->hashes->[0];
	return 0 unless $me && $me->{'address'};
	my $address = eval { decode_json $me->{'address'} } || {};
	return 0 unless ref $address eq 'HASH' && %{$address};
	my $nic;
	foreach my $n ( sort keys %{$address} ) {
		next if $n eq 'public_address' || !$address->{$n}->{'ip'};
		next unless &same_net_test($address->{$n}->{'ip'}, $peer_ip) eq 'yes';
		$nic = $n;
		last;
	}
	return 0 unless $nic;
	my $neigh = $address->{$nic}->{'neigh'};
	$neigh = [] unless ref $neigh eq 'ARRAY';
	my $entry;
	foreach my $n ( @{$neigh} ) {
		next unless ref $n eq 'HASH';
		next unless (($n->{'signatorial'} // '') eq ($msg->{'signatorial'} // '')) || (($n->{'ip'} // '') eq $peer_ip);
		$entry = $n;
		last;
	}
	my $is_new = 0;
	unless ($entry) {
		$entry = {};
		push @{$neigh}, $entry;
		$is_new = 1;
	}
	my $changed = $is_new;
	my %set = (
		ip          => $peer_ip,
		purpose     => ($msg->{'device'} // ''),
		signatorial => ($msg->{'signatorial'} // ''),
		name        => ($msg->{'name'} || $msg->{'hostname'} || ''),
		tunnel      => 'no',
		manager     => 'https://' . $peer_ip . ':' . $port . '/manager',
	);
	$set{'mac'} = $mac if $mac;
	foreach my $k ( sort keys %set ) {
		next if (($entry->{$k} // '') eq ($set{$k} // ''));
		$entry->{$k} = $set{$k};
		$changed = 1;
	}
	return 0 unless $changed;
	$address->{$nic}->{'neigh'} = $neigh;
	my $now = &rightNow();
	my $where = $me->{'uuid'} ? { uuid => $me->{'uuid'} } : { hostname => $hostname };
	&db_update('devices', { address => encode_json $address, timestamp => $now, server_time => $now }, $where);
	return 1;
}

# The mesh wake is a cache row so the listener never forks; President's wake
# loop picks it up within a couple of seconds and runs the reconnector.
sub lan_presence_wake {
	my $now = &rightNow();
	my $last = &cache_get({ app => '__president', context => 'lan', subcontext => 'wake' });
	return if $last && ref $last eq 'HASH' && ($last->{'at'} || 0) > $now - 10000;
	&cache_set({ app => '__president', context => 'lan', subcontext => 'wake', warranty => '+2m' }, { at => $now });
}

# One unicast beacon back to the peer that just told us where it is, so a machine
# that cannot receive broadcast (Termux on Android) still learns the peers that
# heard its sweep. Rate-limited per address.
sub lan_presence_reply {
	my ($ip) = @_;
	return unless ($ip // '') =~ /^\d{1,3}(\.\d{1,3}){3}$/;
	my $now = time();
	return if $lan_reply_at{$ip} && $now - $lan_reply_at{$ip} < 10;
	$lan_reply_at{$ip} = $now;
	if (!$lan_reply_beacon || $now - ($lan_reply_beacon->{'at'} || 0) > 60) {
		$lan_reply_beacon = { at => $now, json => encode_json(&lan_presence_payload()) };
	}
	require Socket;
	require IO::Socket::INET;
	my $sock = IO::Socket::INET->new(Proto => 'udp') or return;
	$sock->send($lan_reply_beacon->{'json'}, 0, Socket::pack_sockaddr_in(&lan_presence_port(), Socket::inet_aton($ip)));
	close $sock;
}

1;
