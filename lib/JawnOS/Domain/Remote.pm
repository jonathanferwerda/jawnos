package subs;

# Remote half of the domain layer: functions subroutines.pl calls that used
# to live in Manager.pl. Same package (subs) so every call site and the
# Manager:: aliases keep working; the Loader in lib/JawnOS/Domain/Loader.pm
# requires this file on the first call that needs it.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';

use Mojo::JSON qw(decode_json encode_json);
use Mojo::IOLoop;
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Util qw(url_escape b64_decode b64_encode);

# File-scope state owned by subroutines.pl, in this same package.
our $config;
our $device;
our $log;
our $logfile;

sub remote_relay_request($c, $extra_params = {}) {
	unless (($c->param('remoted') || '') eq 'yes') {
		my $remote_uuid = $c->param('remote_uuid') || $extra_params->{'remote_uuid'};
		my $signatorial = &subs::signatorial_designer();
		if (1 == 1) {
			$c->param('subprocess' => undef);

			my $path = $c->req->url->path;
			my $uuid = $c->param('uuid');
			# a caller that already stamped the request (the task checkbox does)
			# hands its server_time in, so every machine applies and records the
			# change under one clock instead of each guessing its own
			my $server_time = $extra_params->{'server_time'} || &subs::rightNow();
			my $source_signatorial = $c->param('source_signatorial');
			# Gossip id + the machine that handed us this request (never echoed
			# back to it). A broadcast mints the id here (origin); a machine that
			# received one carries it forward. Single-target proxies are neither.
			my $relay_id = $c->param('relay_id');
			my $relay_from = $c->param('relay_from') || $source_signatorial;
			unless ($remote_uuid) {
				if ($relay_id) {
					# receiver: before_dispatch already claimed the id
				}
				else {
					$relay_id = &subs::random_string_creator(30);
					&subs::relay_fresh($relay_id);
				}
			}
			my $remote_machines;
			if ($remote_uuid) {
				$remote_machines = &subs::remote_machine_lister({ connection => 'active', uuid => $remote_uuid });
			}
			else {
				# Flood: hand it to every machine we can currently reach, bar
				# ourselves and whoever handed it to us. The hub is just one peer
				# here, so the fleet still converges while the hub is down;
				# relay_id makes each machine handle the request only once.
				$remote_machines = &subs::db_query('select * from remote_machines where connection=?', 'active')->hashes;
				$remote_machines = [ grep {
						($_->{'signatorial'} || '') ne $signatorial
						&& ($_->{'signatorial'} || '') ne ($relay_from || '')
						&& ($_->{'signatorial'} || '') ne ($source_signatorial || '')
					} @{$remote_machines} ];
			}


			foreach my $rm ( @{$remote_machines} ) {
				$rm = &remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
				my $method = lc $c->req->method;
				my $res;
				if (($extra_params->{'override'} || '') eq 'manual') {
	#				&remote_relay_request($c, { dissemination => 'yes', url => $url, params => $app, type => 'post', override => 'manual' });
					my $params = $extra_params->{'params'};
					if ($extra_params->{'dissemination'} || &subs::device_setter() eq 'server') {
						$params->{'dissemination'} = 'yes';
						$params->{'source_signatorial'} = $signatorial;
					} else {
						$params->{'remoted'} = 'yes';

					}
					if ($extra_params->{'type'} eq 'post') {
						my $url = $rm->{'manager'} . $extra_params->{'url'};
						my $res = $rm->{'ua'}->post($url => form => $params)->result;
					} else {
						my $params = Mojo::Parameters->new(%{$params});
						$params = $params->to_string;
						my $url = $rm->{'manager'} . $extra_params->{'url'} . '?' . $params;
						$res = $rm->{'ua'}->get($url);# => { Accept => '*/*' } => 'Content!');
					}




				}
				elsif ($method eq 'post') {
					my $params = $c->req->body_params->to_hash;
					if (scalar keys %{$params} == 0) {
						$params = $c->req->body_params->{'string'};
					}
					my $all_params = $c->req->query_params;
					my $sp = {};

					for (my $n = 0; $n < scalar @{$all_params->{'pairs'}} - 1; $n++) {
						if ($all_params->{'pairs'}->[$n] eq 'file' || $all_params->{'pairs'}->[$n] eq 'track') {
							$all_params->{'pairs'}->[$n + 1] = url_escape $all_params->{'pairs'}->[$n + 1];
						}
						$params .= '&' . $all_params->{'pairs'}->[$n] . '=' . $all_params->{'pairs'}->[$n + 1];
						$extra_params->{$all_params->{'pairs'}->[$n]} = $all_params->{'pairs'}->[$n + 1];
						$n++;
					}
					foreach my $p ( keys %{$params} ) {
						$extra_params->{$p} = $params->{$p};
					}
					if ($remote_uuid) {
						$extra_params->{'remoted'} = 'yes';
					} else {
						$extra_params->{'dissemination'} = 'yes';
						$extra_params->{'source_signatorial'} = $signatorial;
						$extra_params->{'relay_from'} = $signatorial;
						$extra_params->{'relay_id'} = $relay_id if $relay_id;
					}
					$extra_params->{'server_time'} = $server_time;
					$extra_params->{'uuid'} = $uuid;
					$extra_params->{'remote_uuid'} = $remote_uuid unless $path eq '/file_open' ;
					foreach my $ep ( keys %{$extra_params} ) {
						$params .= '&' . $ep . '=' . ($extra_params->{$ep} || '');
					}


#					my $form_data = {
#					};
#					$rm->{'ua'}->inactivity_timeout(3);
					my $url = $rm->{'manager'} . $path;
					my $body;
					eval {
						my $res = $rm->{'ua'}->post($url => form => $extra_params)->result;
						$body = $res->body;
					};




#					$res = $rm->{'ua'}->post($url)->result;
					return $body if $remote_uuid;

				}
				else {
					my $all_params = $c->req->query_params;
					my $params;
					for (my $n = 0; $n < scalar @{$all_params->{'pairs'}} - 1; $n++) {
						if ($all_params->{'pairs'}->[$n] eq 'file' || $all_params->{'pairs'}->[$n] eq 'track') {
							$all_params->{'pairs'}->[$n + 1] = url_escape $all_params->{'pairs'}->[$n + 1];
						}
						$params .= '&' . $all_params->{'pairs'}->[$n] . '=' . $all_params->{'pairs'}->[$n + 1];
						$n++;
					}
					if ($remote_uuid) {
						$extra_params->{'remoted'} = 'yes';
					} else {
						$extra_params->{'dissemination'} = 'yes';
						$extra_params->{'source_signatorial'} = $signatorial;
						$extra_params->{'relay_from'} = $signatorial;
						$extra_params->{'relay_id'} = $relay_id if $relay_id;
					}
					$extra_params->{'server_time'} = $server_time;
					$extra_params->{'uuid'} = $uuid;
					$extra_params->{'remote_uuid'} = $remote_uuid unless $path eq '/file_open' ;
					foreach my $ep ( keys %{$extra_params} ) {
						$params .= '&' . $ep . '=' . ($extra_params->{$ep} || '');
					}

					my $url = $rm->{'manager'} . $path . '?' . $params;
      			$rm->{'ua'} = $rm->{'ua'}->max_response_size(0);
					# A picture relay is a bounded errand. The peer agent's timeout is
					# generous because a snapshot pull may legitimately take minutes;
					# inheriting that for a cover meant one unreachable peer could hold a
					# worker for fifty minutes, and a grid of covers held every worker.
					my $file_fetch = ($remote_uuid && ($path eq '/file_open' || $path eq '/play')) ? 1 : 0;
					my ($old_inactive, $old_request, $old_connect);
					if ($file_fetch) {
						$old_inactive = $rm->{'ua'}->inactivity_timeout;
						$old_request = $rm->{'ua'}->request_timeout;
						$old_connect = $rm->{'ua'}->connect_timeout;
						$rm->{'ua'}->inactivity_timeout(6);
						# A picture is a bounded body; a track may legitimately be large, so
						# only the picture path gets a total-time cap.
						$rm->{'ua'}->request_timeout(20) if $path eq '/file_open';
						$rm->{'ua'}->connect_timeout(4);
					}
					$res = eval { $rm->{'ua'}->get($url) };# => { Accept => '*/*' } => 'Content!');
					if ($file_fetch) {
						$rm->{'ua'}->inactivity_timeout($old_inactive) if defined $old_inactive;
						$rm->{'ua'}->request_timeout($old_request) if defined $old_request;
						$rm->{'ua'}->connect_timeout($old_connect) if defined $old_connect;
					}
					# Told apart from an empty file: rock_and_roll uses this to stop
					# asking the same dead peer for every other picture on screen.
					unless ($res) { $c->stash('remote_relay_error' => 1); return undef; }
					if ($res->error) { $c->stash('remote_relay_error' => 1); }

					if ($path eq '/file_open' || $path eq '/play') {
						my $asset = $res->res ? $res->res->content->asset : undef;
						my $data = $asset ? $asset->slurp : undef;
						return $data if $remote_uuid && defined $data;
					}
					else {
						my $body = eval { $res->result->body };
						return $body if $remote_uuid && defined $body;
					}
				}

				my $additions = eval { return decode_json $rm->{'additions'} } || [];

		#		push @{$additions}, { app => $app, uuid => $uuid, scope => 'single', initialization => &subs::rightNow() };
				my $jadditions = encode_json $additions;
		#		&subs::db_update('remote_machines', { additions => $jadditions }, { uuid => $rm->{'uuid'}, signatorial => $rm->{'signatorial'} });


			}
		}

	}
}

# The agent the ticket retry uses. It carries the caller's transport policy:
# when the peer rail verifies against the house CA, the fresh agent verifies
# too, because dropping the cookie must never also drop the certificate check.
# Only a rail with no CA (a peer that has not been issued a leaf yet) keeps the
# old lenient call, so an unenrolled fleet still mints tickets.
sub peer_retry_useragent {
	my ($ua) = @_;
	my $fresh = Mojo::UserAgent->new;
	$fresh->on(start => sub { my ($fresh_ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
	my $tls = (ref $ua && $ua->tls_options) ? $ua->tls_options : {};
	if ($tls->{'SSL_ca_file'}) {
		$fresh->tls_options({ %{$tls} });
	}
	else {
		$fresh->insecure(1);
	}
	return $fresh;
}

# Fetch a peer ticket. The stored peer session cookie can be stale (the peer
# then answers its Gate's denial with 403), while the same request freshly
# signed needs no cookie: the peer's ticket desk verifies the pinned key. Try
# the stored session first, then retry once without it.
sub peer_ticket_fetch {
	my ($url, $ua) = @_;
	return undef unless $url && ref $ua;
	my $res = eval { $ua->inactivity_timeout(15)->get($url)->result };
	return $res if $res && $res->is_success;
	my $fresh = &peer_retry_useragent($ua);
	return eval { $fresh->inactivity_timeout(15)->get($url)->result };
}

# ---------------------------------------------------------------------------
# The house CA and the peer listener
# ---------------------------------------------------------------------------
# The main listener keeps the public wildcard, because a browser or the app
# reaches it by name and must not be asked to trust a private CA. Peers dial a
# literal IP on purpose (a peer's name is only usable while the tailnet's DNS
# answers), and no public wildcard covers an IP. President.pl therefore also
# listens on a free offset beside the main port (+6: +1 is ws, +2 watch, +3 tty,
# +4 tty ws and +5 alarm) with a leaf issued by scripts/house_ca.pl; every
# enrolled machine trusts server/house-ca.pem.
#
# A machine with no CA file, or a peer with no leaf yet, keeps the old insecure
# rail: the signed requests still authenticate the caller, and the probe below
# is what stops a half-rolled-out fleet from breaking.

sub peer_port_offset { return 6 }

sub peer_port_for {
	my ($rm) = @_;
	my $port = ref $rm eq 'HASH' ? ($rm->{'port'} // '') : ($rm // '');
	$port = 45545 unless defined $port && $port =~ /^\d+$/ && $port > 0;
	my $peer = $port + &peer_port_offset();
	$peer -= 2 * &peer_port_offset() if $peer > 65535;
	return $peer;
}

sub peer_ca_file {
	for my $candidate (
		(&subs::server_dir() . '/house-ca.pem'),
		($ENV{'JAWNOS_ROOT'} ? $ENV{'JAWNOS_ROOT'} . '/server/house-ca.pem' : ()),
		'server/house-ca.pem',
		'./server/house-ca.pem',
	) {
		return $candidate if -s $candidate;
	}
	return '';
}

# Point a user agent at the house CA. Returns 1 when the CA is present, so the
# caller must not also call insecure(1): that would switch verification back off.
sub peer_tls_verify {
	my ($ua, $opts) = @_;
	return 0 unless $ua;
	my $ca = ($opts && $opts->{'ca'}) || &peer_ca_file();
	return 0 unless length $ca;
	$ua->tls_options({ SSL_ca_file => $ca });
	return 1;
}

my %peer_tls_probe;

# The peer listener's port when the peer answers there and this machine holds
# the CA; 0 otherwise. A short TCP probe, cached for five minutes per host, is
# cheaper than a TLS failure on every clock hop, and it is what lets an enrolled
# house talk to a peer that has not been issued a leaf yet.
sub peer_tls_port {
	my ($rm, $opts) = @_;
	$opts ||= {};
	my $ca = &peer_ca_file();
	return 0 unless length $ca;
	my $host = $opts->{'host'} // ($rm->{'ip'} // '');
	return 0 unless defined $host && length $host;
	my $port = &peer_port_for($rm);
	my $key = $host . ':' . $port;
	my $now = time;
	if (my $cached = $peer_tls_probe{$key}) {
		return $cached->[1] if $now - $cached->[0] < 300;
	}
	# The listener is worth dialling only when its leaf proves this address. A
	# LAN address that moved (DHCP) leaves the leaf naming the old one, and then
	# every verified request to the listener died with "hostname verification
	# failed" and no response at all: the peer looked like it "answered no
	# status" while it was up and answering, and CloudSync to it silently found
	# no device. A TCP probe cannot see that; a handshake against the house CA
	# can. A peer whose leaf does not match keeps the stored route, which the
	# peer signature alone proves - exactly what a peer with no leaf does.
	require IO::Socket::SSL;
	my $sock = IO::Socket::SSL->new(
		PeerHost         => $host,
		PeerPort         => $port,
		SSL_ca_file      => $ca,
		SSL_verify_mode  => IO::Socket::SSL::SSL_VERIFY_PEER(),
		SSL_verifycn_name => $host,
		SSL_hostname     => $host,
		Timeout          => 2,
	);
	my $ok = $sock ? 1 : 0;
	close $sock if $sock;
	$peer_tls_probe{$key} = [ $now, $ok ? $port : 0 ];
	return $ok ? $port : 0;
}

# Rewrite a peer url to the peer listener when that peer answers there and this
# machine holds the CA. Returns ($url, $verified). A tunnel row is a loopback
# route and is left exactly as it is.
# Does anything answer on the peer listener at all? This is the fallback route:
# a listener whose leaf names another address (a machine whose LAN address moved
# under DHCP) still serves the signed rail, and that is better than leaving the
# peer unreachable because the certificate lags an address change.
my %peer_listener_probe;

sub peer_listener_port {
	my ($rm, $opts) = @_;
	$opts ||= {};
	my $host = $opts->{'host'} // ($rm->{'ip'} // '');
	return 0 unless defined $host && length $host;
	my $port = &peer_port_for($rm);
	my $key = 'tcp:' . $host . ':' . $port;
	my $now = time;
	if (my $cached = $peer_listener_probe{$key}) {
		return $cached->[1] if $now - $cached->[0] < 300;
	}
	require IO::Socket::INET;
	my $sock = IO::Socket::INET->new(
		PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Timeout => 1);
	my $ok = $sock ? 1 : 0;
	close $sock if $sock;
	$peer_listener_probe{$key} = [ $now, $ok ? $port : 0 ];
	return $ok ? $port : 0;
}

sub peer_secure_url {
	my ($rm, $url) = @_;
	return ($url, 0) unless ref $rm eq 'HASH' && defined $url && length $url;
	my ($scheme, $host);
	if ($url =~ m{^(https?)://(\[[^\]]+\]|[^/:]+)}) { ($scheme, $host) = ($1, $2) }
	elsif ($url =~ m{^(wss?)://(\[[^\]]+\]|[^/:]+)}) { ($scheme, $host) = ($1, $2) }
	return ($url, 0) unless defined $host;
	# A tunnel row is a loopback route and is left exactly as it is. The flag can
	# outlive the tunnel, though: the hub's rows for the machines that used to dial
	# out to it kept tunnel 'yes' after peer_live_manager moved them to the tailnet,
	# and the old blanket return answered "unverified" for a direct address whose
	# leaf proves it - so every login to that peer was refused, which is the
	# session every relay needs. Only a loopback route belongs to the tunnel; any
	# other address is verified like any peer's.
	return ($url, 0) if ($rm->{'tunnel'} || '') eq 'yes' && &subs::peer_host_is_loopback($host);
	# A row is the peer, not one address. The stored ip is only where it was
	# last reached, the fqdn can be loopback (a hand-entered row), and
	# peer_live_manager resolves a dead name or a departed LAN literal to the
	# tailnet. Every literal the row advertises is the same peer, so the host
	# check has to accept any of them: a tailnet address that the row itself
	# publishes was refused here, which made remote_device_connect call a
	# working peer listener "not verified" and refuse the peer login - leaving
	# every relay without the session cookie it needs to pass the gate.
	my %known;
	my %raw;
	for my $candidate ($rm->{'ip'}, $rm->{'fqdn'}, &peer_resolve_addresses($rm), (&peer_manager_host($rm))[0]) {
		next unless defined $candidate && length $candidate;
		my $original = $candidate;
		$candidate =~ s/^\[|\]$//g;
		$known{lc $candidate} = 1;
		$raw{lc $candidate} = $original;
	}
	my $host_key = lc $host;
	$host_key =~ s/^\[|\]$//g;
	return ($url, 0) unless $known{$host_key};
	# The listener is the route worth trying: the manager port is often bound to
	# loopback and published by the tunnel, while the peer listener answers on
	# the machine's own addresses. A leaf that proves this address lets the
	# request be verified against the house CA; a listener that cannot prove it
	# is still used, unverified, because the peer signature alone proves the
	# caller - the same rail a machine with no leaf has always had.
	my $verified_port = &peer_tls_port($rm, { host => $host });
	my $verified_key = $host_key;
	if (!$verified_port) {
		# The stored route may be a LAN address whose leaf predates it (the
		# DHCP move). Another address the same row advertises - its tailnet,
		# its network map - can still prove itself, and a verified login over
		# that route is exactly what the house key requires.
		for my $candidate ( sort keys %known ) {
			next if $candidate eq $host_key;
			my $port = &peer_tls_port($rm, { host => $raw{$candidate} });
			if ($port) { $verified_port = $port; $verified_key = $candidate; last; }
		}
	}
	my $peer = $verified_port || &peer_listener_port($rm, { host => $host });
	return ($url, 0) unless $peer;
	my $base = ($scheme eq 'http' || $scheme eq 'https') ? 'https' : 'wss';
	my $secure = $url;
	if ($verified_port && $verified_key ne $host_key) {
		$secure =~ s{^(?:https?|wss?)://(\[[^\]]+\]|[^/:]+)(?::\d+)?}{$base . '://' . $raw{$verified_key} . ':' . $peer}e;
	}
	else {
		$secure =~ s{^(?:https?|wss?)://(\[[^\]]+\]|[^/:]+)(?::\d+)?}{$base . '://' . $1 . ':' . $peer}e;
	}
	return ($secure, $verified_port ? 1 : 0);
}

sub remote_useragent_maker($data) {
	my $ip = $data->{'ip'};
	my $signatorial = $data->{'signatorial'};
	my $rm = $data->{'rm'};
	my $uuid = $data->{'uuid'};
	my $auth_test = $data->{'auth_test'} || '';
	my $ua = Mojo::UserAgent->new();
	$ua = $ua->max_response_size(0);
	# every request on the peer rail names this machine and carries a signature
	$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
	unless ($rm) {
		if ($uuid) {
			$rm = &subs::remote_machine_lister({ uuid => $uuid, limit => 1 });
		} elsif ( $ip && $signatorial ) {
			$rm = &subs::remote_machine_lister({ signatorial => $signatorial, limit => 1 });
		} else {
			$rm = &subs::remote_machine_lister({ signatorial => $signatorial, limit => 1 });
		}
	}
	else {
		$rm = &subs::remote_machine_tunnel_processor($rm);
	}
	my $remote_address = $rm->{'ip'};
	my $port = $rm->{'port'};

	my $manager = $rm->{'manager'};
	# A retired tunnel leaves 127.0.0.1 behind, and a name is the only route
	# left. Resolve it before the cookie is scoped and every url is built.
	# A time-critical fan-out (a volume tap) must not spend its short warranty
	# probing every peer's live and secure URL before it writes; the stored
	# manager is the signed rail's normal address, and the signature still proves
	# the caller. Callers that can wait keep the probes.
	my $live_manager = $data->{'no_probe'}
		? $manager
		: &subs::peer_live_manager($rm);
	if (($manager || '') ne $live_manager) {
		$manager = $live_manager;
		$rm->{'manager'} = $manager;
		# The stale route was resolved to one this machine can reach (the tailnet
		# after the peer's LAN changed, or a name after a retired tunnel). Persist
		# it so the next caller does not start from the old address again. A
		# time-critical fan-out must not write while it is racing its warranty.
		&subs::peer_manager_remember($rm, $manager) unless $data->{'no_probe'};
	}
	# The peer listener (main port + 6) is where the house-CA leaf lives. Only
	# switch to it when the peer answers there; the signed rail still carries
	# the caller's proof either way.
	my ($secure_manager, $manager_verified) = $data->{'no_probe'}
		? ($manager, 0)
		: &subs::peer_secure_url($rm, $manager);
	if ($manager_verified) {
		$manager = $secure_manager;
		$rm->{'manager'} = $manager;
		&subs::peer_tls_verify($ua);
	}
	# The TLS decision is made here and handed to the caller in `ua`: a verified
	# peer keeps the house CA, an unverified one is marked insecure below. Callers
	# must not call insecure(1) on this agent - that override downgrades a peer
	# this function already proved.
	if ($rm->{'cookie'}) {
		my $cookie_jar = decode_json $rm->{'cookie'};
		# The cookie was stored with the address the peer was reached on (often a
		# LAN ip), but the manager url is usually its fqdn: a cookie scoped to the
		# ip is never sent to the fqdn host. Scope it to whatever host we are about
		# to call, so the stored session actually rides along.
		my $host = eval { Mojo::URL->new($manager)->host };
		foreach my $cookie ( @{$cookie_jar} ) {
			$ua->cookie_jar->add(
				Mojo::Cookie::Response->new(
					name => $cookie->{'name'},
					value => $cookie->{'value'},
					domain => ($host || $cookie->{'domain'}),
					path => $cookie->{'path'}
				)
			);
		}
		$rm->{'ua'} = $ua;
		$rm->{'ua'}->inactivity_timeout(3000);
		$rm->{'ua'}->insecure(1) unless $manager_verified;
		my $domain = $config->{'domain'} || $ip;
		if ($auth_test eq 'yes' || $data->{'chip_chyea'}) {
			my $url = $rm->{'manager'} . '/manager/remote_auth_test?signatorial=' . &subs::signatorial_designer() . '&auth_test=' . $auth_test;
			if ($data->{'chip_chyea'}) {
				$rm->{'ua'}->inactivity_timeout(2);
				$url .= '&chip_chyea=' . $data->{'chip_chyea'};
			}
			$url .= '&domain=' . $config->{'domain'};
			if ($auth_test eq 'yes' && defined $data->{'since'}) {
				$url .= '&since=' . int($data->{'since'});
			}
			if ($auth_test eq 'yes' && ref $data->{'digest'} eq 'HASH') {
				my %cuts = map { $_ => ($data->{'digest'}->{$_}->{'max'} || 0) } keys %{$data->{'digest'}};
				$url .= '&cuts=' . Mojo::Util::url_escape(&subs::sync_map_encode(\%cuts));
			}
			$url .= '&tombstone_cursor=' . int($data->{'tombstone_cursor'} || 0) if $auth_test eq 'yes';
			# The handshake is a cheap route that must answer quickly. The UA's other
			# timeout (3000s) exists so a snapshot pull can wait on a peer building a
			# large export; inheriting it here meant one stuck peer froze the whole
			# reconnector for fifty minutes, and every later peer in the roster waited
			# behind it. Bound this one request and put the long timeout back for the
			# requests that need it.
			my $long_timeout = $rm->{'ua'}->inactivity_timeout;
			$rm->{'ua'}->inactivity_timeout(15);
			my $res = eval { return $rm->{'ua'}->get($url => {Accept => '*/*'} => 'Content!')->result };
			$rm->{'ua'}->inactivity_timeout($long_timeout);
			if (eval { $res->is_success }) {
				$rm->{'res'} = $res;
			} else {
				$rm->{'ua'} = undef;
			}
		}
	}
	else {
		# No stored session. The signed rail is what authenticates a peer request
		# (peer_sign_request rides every request this agent makes), so the agent is
		# usable anyway. Leaving it undef made every caller that checks for one -
		# the destination relay among them - treat the peer as unreachable and
		# silently do the work here instead of there.
		$rm->{'ua'} = $ua;
		$rm->{'ua'}->insecure(1) unless $manager_verified;
		$rm->{'ua'}->inactivity_timeout(60);
	}
	# A reconnector pass is a probe, not a pull: one silent peer must not hold
	# the utility slot with the pull-sized inactivity bound. The snapshot pull
	# forks and builds its own agent, so the long bound stays for it.
	if ($data->{'pass'} && $rm->{'ua'}) {
		$rm->{'ua'}->inactivity_timeout(15);
		$rm->{'ua'}->connect_timeout(5);
		$rm->{'ua'}->request_timeout(20);
	}
	$rm->{'data'} = eval { return decode_json $rm->{'data'} };

	return $rm;
}

# ---------------------------------------------------------------------------
# QA nightly target
# ---------------------------------------------------------------------------
# Configure -> Plat -> QA names the one machine that runs the nightly suite.
# The choice is a house setting (`__president/qa_nightly_device`, device 'all'):
# the signatorial of a computer or server, or '' for the local fallback. The
# nightly's systemd unit reads the same rows through qa/device_target.pl, so the
# panel and the timer can never disagree about which machine runs.

# Where a tool is, without shelling out: PATH first, then the directory perl
# itself installs its scripts in. Arch and Manjaro put prove (with the other
# core scripts) under /usr/bin/core_perl, which their default PATH omits, so a
# machine whose suite runs fine still looked unready for a missing prove. A
# name is never passed to a shell. `installscript` is a test seam; production
# callers pass only the name.
sub qa_which {
	my ($name, $opts) = @_;
	$opts ||= {};
	return '' unless defined $name && length $name;
	return $name if $name =~ m{/} && -x $name;
	my @dirs = split /:/, ($ENV{'PATH'} || '/usr/local/bin:/usr/bin:/bin');
	my $script = exists $opts->{'installscript'} ? $opts->{'installscript'}
		: (eval { require Config; $Config::Config{'installscript'} } || '');
	if (length $script && $script =~ m{^/} && -d $script && !grep { $_ eq $script } @dirs) {
		push @dirs, $script;
	}
	foreach my $dir (@dirs) {
		next unless length $dir;
		my $candidate = "$dir/$name";
		return $candidate if -x $candidate;
	}
	return '';
}

# A phone or tablet can hold the roster and answer the panel, but it is never
# the machine a QA suite runs on: the suite needs a repo, perl and a fence, and
# the owner asked for computer/server only.
sub qa_device_kind_eligible {
	my ($kind) = @_;
	return 0 unless defined $kind && length $kind;
	return $kind =~ /^(?:computer|server)$/ ? 1 : 0;
}

# The eligible remote rows, self excluded. `rows` lets a caller (a test, or a
# caller that already holds the roster) answer without another database read.
sub qa_target_machines {
	my $opts = shift || {};
	my $rows = $opts->{'rows'};
	$rows = &subs::remote_machine_lister({ self => 'no', mirrors => 'none' }) unless ref $rows eq 'ARRAY';
	my $self = exists $opts->{'self'} ? $opts->{'self'} : &subs::signatorial_designer();
	my @out;
	foreach my $rm ( @{$rows} ) {
		next unless ref $rm eq 'HASH';
		next unless defined $rm->{'signatorial'} && length $rm->{'signatorial'};
		next if $self && $rm->{'signatorial'} eq $self;
		next unless &qa_device_kind_eligible($rm->{'device'});
		push @out, $rm;
	}
	return \@out;
}

# Resolve the setting's value to a target. '' and this machine's own
# signatorial are the local fallback; any other value must name an eligible
# row. An ineligible or unknown value resolves to undef, and every caller
# treats that as a refusal rather than quietly running here.
sub qa_target_lookup {
	my ($signatorial, $opts) = @_;
	$opts ||= {};
	my $self = exists $opts->{'self'} ? $opts->{'self'} : &subs::signatorial_designer();
	$signatorial = '' unless defined $signatorial;
	if (!length $signatorial || ($self && $signatorial eq $self)) {
		return { local => 1, signatorial => ($self || ''), device => 'local', hostname => 'me' };
	}
	foreach my $rm ( @{ &qa_target_machines({ %{$opts}, self => $self }) } ) {
		next unless $rm->{'signatorial'} eq $signatorial;
		return { %{$rm}, local => 0 };
	}
	return undef;
}

# The guard every mutating action runs first: saving the choice and installing
# on it both refuse a device that is not computer/server.
sub qa_install_guard {
	my ($signatorial, $opts) = @_;
	return { ok => 0, error => 'the nightly system is off; choose a machine to turn it on' }
		if &qa_nightly_is_off($signatorial);
	my $target = &qa_target_lookup($signatorial, $opts);
	return { ok => 0, error => 'not an eligible device (computer or server only)' } unless $target;
	return { ok => 1, target => $target };
}

# The stored value `none` is a deliberate choice, not a machine: every nightly
# timer skips (qa/device_target.pl exits 1), the readiness and schedule cards
# answer off, and nothing can be installed, retimed or started until a machine
# is chosen again. It is a real value because the empty setting is the local
# fallback, which must keep meaning "this machine runs its own suite".
sub qa_nightly_is_off {
	my ($value) = @_;
	return (defined $value && lc($value) =~ /^\s*none\s*$/) ? 1 : 0;
}

# A stored choice is a signatorial (hex), the literal 'none' (the whole nightly
# system is off), or '' for the local fallback. Anything else is treated as no
# choice at all, never handed to a path or a query.
sub qa_nightly_clean {
	my ($value) = @_;
	return '' unless defined $value;
	$value =~ s/^\s+//;
	$value =~ s/\s+$//;
	return 'none' if lc($value) eq 'none';
	return '' unless $value =~ /^[0-9a-f]{16,64}$/i;
	return lc $value;
}

sub qa_nightly_device {
	my $opts = shift || {};
	my $grab = $opts->{'grabber'};
	unless ($grab) {
		$grab = sub {
			my $v = &subs::setting_grabber({ app => '__president', setting => 'qa_nightly_device', device => 'all' });
			$v = &subs::setting_grabber({ app => '__president', setting => 'qa_nightly_device' }) unless defined $v && length $v;
			return $v;
		};
	}
	return &qa_nightly_clean( $grab->() );
}

# Save the choice. The value is written as a house setting (device 'all') so
# every machine's timer reads the same answer; a test may inject the setter.
sub qa_nightly_save {
	my ($signatorial, $opts) = @_;
	$opts ||= {};
	# Turning the whole system off is a house decision any signed-in machine may
	# make, including a phone: it does not name a device to run on.
	if (&qa_nightly_is_off($signatorial)) {
		my $set = $opts->{'setter'};
		unless ($set) {
			$set = sub {
				&subs::setting_setter({ app => '__president', setting => 'qa_nightly_device', device => 'all', value => $_[0] });
			};
		}
		$set->('none');
		return { ok => 1, signatorial => 'none', local => 0, off => 1, device => 'none' };
	}
	my $guard = &qa_install_guard($signatorial, $opts);
	return $guard unless $guard->{'ok'};
	my $target = $guard->{'target'};
	# The local fallback is only a computer's or a server's: a phone can open
	# Configure but cannot run the suite, so it must not pin itself.
	if ($target->{'local'}) {
		my $kind = exists $opts->{'device_kind'} ? $opts->{'device_kind'} : &subs::device_setter();
		return { ok => 0, error => 'not an eligible device (computer or server only)' }
			unless &qa_device_kind_eligible($kind);
	}
	my $value = $target->{'local'} ? '' : $target->{'signatorial'};
	my $set = $opts->{'setter'};
	unless ($set) {
		$set = sub {
			&subs::setting_setter({ app => '__president', setting => 'qa_nightly_device', device => 'all', value => $_[0] });
		};
	}
	$set->($value);
	return { ok => 1, signatorial => $value, local => ($target->{'local'} ? 1 : 0), device => $target->{'device'} };
}

# ---------------------------------------------------------------------------
# Notes per night
# ---------------------------------------------------------------------------
# The second QA picker: how many of the open JawnOS notes the 06:00 coding
# night (and the UX loop) work through. `__president/qa_note_limit`, device
# 'all', so every machine reads the same answer. The clamp is the contract -
# 1..25, default 3 - and the runner applies the identical rule in
# qa/lib/QaSetting.pm, so a hand-made POST cannot ask for a thousand notes.

sub qa_note_limit_default { return 3 }
sub qa_note_limit_bounds { return (1, 25) }

sub qa_note_limit_clamp {
	my ($value) = @_;
	return &qa_note_limit_default()
		unless defined $value && $value =~ /^\s*[+-]?\d+\s*$/;
	my ($min, $max) = &qa_note_limit_bounds();
	my $n = int($value);
	return $min if $n < $min;
	return $max if $n > $max;
	return $n;
}

sub qa_note_limit {
	my $opts = shift || {};
	my $grab = $opts->{'grabber'};
	unless ($grab) {
		$grab = sub {
			my $v = &subs::setting_grabber({ app => '__president', setting => 'qa_note_limit', device => 'all' });
			$v = &subs::setting_grabber({ app => '__president', setting => 'qa_note_limit' }) unless defined $v && length $v;
			return $v;
		};
	}
	return &qa_note_limit_clamp( $grab->() );
}

# Save the number. Invalid input is the default and out-of-range input is
# clamped; the response carries what was actually stored, so the panel can put
# the select back to the truth. A test may inject the setter.
sub qa_note_limit_save {
	my ($value, $opts) = @_;
	$opts ||= {};
	my ($min, $max) = &qa_note_limit_bounds();
	my $n = &qa_note_limit_clamp($value);
	my $numeric = (defined $value && $value =~ /^\s*[+-]?\d+\s*$/) ? 1 : 0;
	my $set = $opts->{'setter'};
	unless ($set) {
		$set = sub {
			&subs::setting_setter({ app => '__president', setting => 'qa_note_limit', device => 'all', value => $_[0] });
		};
	}
	$set->($n);
	return {
		ok => 1,
		note_limit => $n,
		min => $min,
		max => $max,
		clamped => (!$numeric || int($value) != $n) ? 1 : 0,
	};
}

# ---------------------------------------------------------------------------
# The UX judgement model
# ---------------------------------------------------------------------------
# `__president/qa_ux_model`, device 'all': the model the 05:30 UX loop asks for
# its easy/help/works verdicts. Empty means no model - the loop skips, never
# passes. The coding night has its own role (mail/coding_assistant), so this
# choice cannot move it or the Guide's evaluation role. The allowed shape is a
# model id, never a sentence or a shell fragment.

sub qa_ux_model_clean {
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/^\s+|\s+$//g;
	return '' unless length $value;
	return undef unless length($value) <= 120
		&& $value =~ /\A[\@A-Za-z0-9][A-Za-z0-9\@.:_+\/-]*\z/;
	return $value;
}

sub qa_ux_model {
	my $opts = shift || {};
	my $grab = $opts->{'grabber'};
	unless ($grab) {
		$grab = sub {
			my $v = &subs::setting_grabber({ app => '__president', setting => 'qa_ux_model', device => 'all' });
			$v = &subs::setting_grabber({ app => '__president', setting => 'qa_ux_model' }) unless defined $v && length $v;
			return $v;
		};
	}
	my $value = &qa_ux_model_clean( $grab->() );
	return defined $value ? $value : '';
}

sub qa_ux_model_save {
	my ($value, $opts) = @_;
	$opts ||= {};
	my $clean = &qa_ux_model_clean($value);
	return { ok => 0, error => 'That does not look like a model name.' } unless defined $clean;
	my $set = $opts->{'setter'};
	unless ($set) {
		$set = sub {
			&subs::setting_setter({ app => '__president', setting => 'qa_ux_model', device => 'all', value => $_[0] });
		};
	}
	$set->($clean);
	return { ok => 1, model => $clean };
}

# The eligible chat models for the QA dropdown, grouped the way the Platform
# role pickers group them: a provider that can answer (a key, or a running
# Ollama), a peer's cached Ollama, and a model whose billing bucket is not
# stood down. The Plat template already builds the catalogue and both answers,
# so it hands them in; a direct call reads them itself.
sub qa_ux_model_choices {
	my $opts = shift || {};
	my $catalogue = $opts->{'catalogue'};
	$catalogue = &subs::ai_model_catalogue('chat') unless ref $catalogue eq 'ARRAY';
	my $ready = $opts->{'ready'} || sub { &subs::ai_provider_ready($_[0]) ? 1 : 0 };
	my $available = $opts->{'available'} || sub { &subs::ai_bucket_available($_[0]) ? 1 : 0 };
	my @groups;
	foreach my $provider ( @{$catalogue} ) {
		next unless ref $provider eq 'HASH';
		next unless $ready->($provider->{'id'});
		my @models = grep {
			my $m = $_;
			ref $m eq 'HASH'
				&& scalar( grep { $_ eq 'chat' } @{ $m->{'caps'} || [] } )
				&& (!$m->{'paid'} || $available->($m->{'bucket'}))
		} @{ $provider->{'models'} || [] };
		next unless @models;
		push @groups, {
			id     => $provider->{'id'},
			label  => ($provider->{'label'} || $provider->{'id'}),
			models => [ map {
				{ value => $_->{'value'}, name => ($_->{'name'} || $_->{'value'}), paid => ($_->{'paid'} ? 1 : 0) }
			} @models ],
		};
	}
	return \@groups;
}

# ---------------------------------------------------------------------------
# What the coding night works on
# ---------------------------------------------------------------------------
# `__president/qa_coding_lanes`, device 'all': the sources the 06:00 night draws
# work from. `notes` is the original queue; `security` takes the new high
# findings from the nightly security audit and `installers` takes the packages
# the installer check reports missing. qa/lib/QaSetting.pm holds the identical
# rule for the fenced runner, and t/88 asks both. An empty choice is refused:
# a night with no source would silently do nothing.

sub qa_coding_lanes_known { return qw(notes security installers) }
sub qa_coding_lanes_default { return 'notes' }

sub qa_coding_lanes_clamp {
	my ($value) = @_;
	my @asked = ref $value eq 'ARRAY'
		? @{$value}
		: split /[\s,]+/, (defined $value ? $value : '');
	my %on = map { $_ => 1 } @asked;
	my @out = grep { $on{$_} } &qa_coding_lanes_known();
	return @out ? @out : (&qa_coding_lanes_default());
}

sub qa_coding_lanes {
	my $opts = shift || {};
	my $grab = $opts->{'grabber'};
	unless ($grab) {
		$grab = sub {
			my $v = &subs::setting_grabber({ app => '__president', setting => 'qa_coding_lanes', device => 'all' });
			$v = &subs::setting_grabber({ app => '__president', setting => 'qa_coding_lanes' }) unless defined $v && length $v;
			return $v;
		};
	}
	return &qa_coding_lanes_clamp( $grab->() );
}

sub qa_coding_lanes_save {
	my ($value, $opts) = @_;
	$opts ||= {};
	my @asked = ref $value eq 'ARRAY'
		? @{$value}
		: split /[\s,]+/, (defined $value ? $value : '');
	unless (grep { length } @asked) {
		return { ok => 0, error => 'Choose at least one thing the coding night works on.' };
	}
	my @lanes = &qa_coding_lanes_clamp($value);
	my $set = $opts->{'setter'};
	unless ($set) {
		$set = sub {
			&subs::setting_setter({ app => '__president', setting => 'qa_coding_lanes', device => 'all', value => $_[0] });
		};
	}
	$set->(join ',', @lanes);
	return { ok => 1, lanes => \@lanes };
}

# The tools the suite and its artefact layers need. `required` is the nightly
# (l0-l2 plus the fence); the rest are the build/device layers, named so the
# panel can say what is missing without calling them failures of tonight's run.
sub qa_readiness_checks {
	return (
		{ key => 'repo',    label => 'JawnOS checkout',  required => 1, kind => 'file' },
		{ key => 'perl',    label => 'perl',             required => 1, kind => 'tool' },
		{ key => 'prove',   label => 'prove',            required => 1, kind => 'tool' },
		{ key => 'sqlite3', label => 'sqlite3',          required => 1, kind => 'tool' },
		{ key => 'unshare', label => 'unshare',          required => 1, kind => 'tool' },
		{ key => 'mkosi',   label => 'mkosi',            required => 0, kind => 'tool' },
		{ key => 'qemu',    label => 'qemu-system-x86_64', required => 0, kind => 'tool' },
		{ key => 'java',    label => 'java',             required => 0, kind => 'tool' },
		{ key => 'javac',   label => 'javac',            required => 0, kind => 'tool' },
		{ key => 'jlink',   label => 'jlink',            required => 0, kind => 'tool' },
		{ key => 'adb',     label => 'adb',              required => 0, kind => 'tool' },
		{ key => 'avd',     label => 'Android AVD',      required => 0, kind => 'avd' },
	);
}

# Is this machine ready to run the nightly? Injected `which`, `file_exists`,
# `home` and `repo` keep the answer testable without pretending a tool exists.
sub qa_readiness {
	my $opts = shift || {};
	my $which = $opts->{'which'} || sub { &qa_which($_[0]) };
	my $exists = $opts->{'file_exists'} || sub { -e $_[0] };
	my $home = defined $opts->{'home'} ? $opts->{'home'} : &subs::home('~');
	my $repo = defined $opts->{'repo'} ? $opts->{'repo'} : &subs::home('~/jawnos');
	my @checks;
	foreach my $def ( &qa_readiness_checks() ) {
		my %row = ( %{$def}, ok => 0 );
		if ($def->{'kind'} eq 'file') {
			$row{'path'} = $repo . '/qa/run.pl';
			$row{'ok'} = $exists->( $row{'path'} ) ? 1 : 0;
		}
		elsif ($def->{'kind'} eq 'avd') {
			my $dir = $ENV{'ANDROID_AVD_HOME'} || "$home/.android/avd";
			my @avd = $exists->($dir) ? glob("$dir/*.avd") : ();
			$row{'path'} = $dir;
			$row{'ok'} = scalar(@avd) ? 1 : 0;
		}
		else {
			my $found = $which->( $def->{'key'} );
			$row{'path'} = $found if defined $found && length $found;
			$row{'ok'} = (defined $found && length $found) ? 1 : 0;
		}
		push @checks, \%row;
	}
	my @missing = map { $_->{'key'} } grep { !$_->{'ok'} } @checks;
	my @missing_required = map { $_->{'key'} } grep { !$_->{'ok'} && $_->{'required'} } @checks;
	my $install = exists $opts->{'install'} ? $opts->{'install'} : &qa_install_status();
	return {
		ok => 1,
		ready => scalar(@missing_required) ? 0 : 1,
		missing => \@missing,
		missing_required => \@missing_required,
		checks => \@checks,
		hostname => &subs::machine_name(),
		install => $install,
	};
}

# Ask the chosen machine. The local fallback answers here; a remote row is
# asked over the signed peer rail, which is how every other peer call in the
# app authenticates - there is no unauthenticated path for it.
# --- QA reports --------------------------------------------------------------
# A nightly job leaves one finished run per directory under $QA_ROOT (report.json
# and status.txt beside its log). The panel shows those, from any machine: a
# laptop asks the machine that ran the job over the same signed hop readiness
# uses, so no report has to be synced into this database and a run that failed
# to write one still appears with the status it managed.
sub qa_reports_root {
	return &subs::home('~/jawnos-qa') . '/reports';
}

# Every kind a job can leave: the installer check, the security audit and the
# full suite (nightly), the weekly build and the emulator run (manual). The
# order is the card's order when two runs share a stamp.
sub qa_report_kinds {
	return qw(installers security build emulator);
}

sub qa_reports_list {
	my ($opts) = @_;
	$opts ||= {};
	my $root = (defined $opts->{'root'} && length $opts->{'root'}) ? $opts->{'root'} : &qa_reports_root();
	my $limit = defined $opts->{'limit'} ? $opts->{'limit'} + 0 : 20;
	my @reports;
	for my $kind ( &qa_report_kinds() ) {
		my $kind_dir = "$root/$kind";
		opendir(my $dh, $kind_dir) or next;
		my @stamps = grep { /^\d{8}T\d{6}Z$/ && -d "$kind_dir/$_" } readdir $dh;
		closedir $dh;
		for my $stamp (@stamps) {
			my $dir = "$kind_dir/$stamp";
			my $status = '';
			if (open(my $sh, '<', "$dir/status.txt")) {
				$status = <$sh> // '';
				close $sh;
				$status =~ s/\s+//g;
			}
			my $report;
			if (open(my $fh, '<', "$dir/report.json")) {
				local $/;
				my $text = <$fh>;
				close $fh;
				my $decoded = undef;
				if (defined $text && length $text) {
					$decoded = eval { decode_json($text) };
				}
				$report = $decoded if ref $decoded eq 'HASH';
			}
			if (!length $status) {
				$status = !$report ? 'unknown' : ($report->{'ok'} ? 'ok' : 'failed');
			}
			push @reports, {
				kind => $kind,
				stamp => $stamp,
				status => $status,
				report => $report,
			};
		}
	}
	# Newest first, and the kind breaks a tie so the order is stable.
	my @order = (&qa_report_kinds());
	my %rank;
	$rank{ $order[$_] } = $_ for 0 .. $#order;
	my @sorted = sort {
		($b->{'stamp'} cmp $a->{'stamp'})
			|| ($rank{ $a->{'kind'} } <=> $rank{ $b->{'kind'} })
	} @reports;
	return [ @sorted[0 .. (@sorted < $limit ? $#sorted : $limit - 1)] ] if @sorted;
	return [];
}

sub qa_hop_answer {
	my ($res, $fallback, $target) = @_;
	# A peer that is not signed in answers JSON (403); a peer the gate does not
	# know answers the Gate page (HTML 200). Both are refusals, and calling them
	# "did not answer" hides the fix - the caller has to be paired. A real
	# no-answer (timeout, no route) keeps the caller's own wording.
	my $body = $res ? eval { decode_json $res->body } : undef;
	return $body if ref $body eq 'HASH';
	return { ok => 0, error => $fallback, target => $target } unless $res;
	return {
		ok => 0,
		error => &subs::ui('that machine refused the request: this machine is not paired with it as a peer'),
		target => $target,
	};
}

sub qa_reports_for {
	my ($signatorial, $opts) = @_;
	$opts ||= {};
	return { ok => 1, off => 1, reports => [] } if &qa_nightly_is_off($signatorial);
	my $guard = &qa_install_guard($signatorial, $opts);
	return { ok => 0, error => $guard->{'error'} } unless $guard->{'ok'};
	my $target = $guard->{'target'};
	if ($target->{'local'}) {
		return {
			ok => 1,
			local => 1,
			target => $target->{'signatorial'} || '',
			reports => &qa_reports_list($opts),
		};
	}
	# The peer hop readiness takes, for the same reason: the report lives on the
	# machine that ran the job, and only that machine can list its own files.
	my $hop_row = { %{$target} };
	delete $hop_row->{'cookie'};
	my $hop = eval { &remote_useragent_maker({ signatorial => $target->{'signatorial'}, rm => $hop_row }) };
	return { ok => 0, error => 'no route to that machine', target => $target->{'signatorial'} }
		unless $hop && $hop->{'ua'} && $hop->{'manager'};
	my $url = $hop->{'manager'} . '/manager/configure/qa_reports?signatorial=' . &subs::signatorial_designer();
	my $res = eval { $hop->{'ua'}->inactivity_timeout(30)->get($url)->result };
	return &qa_hop_answer($res, 'that machine did not answer the report request', $target->{'signatorial'});
}

sub qa_readiness_for {
	my ($signatorial, $opts) = @_;
	$opts ||= {};
	return {
		ok => 1, off => 1, ready => 0,
		missing => [], missing_required => [], checks => [],
		hostname => '', install => {}, target => 'none', local => 0,
	} if &qa_nightly_is_off($signatorial);
	my $guard = &qa_install_guard($signatorial, $opts);
	return { ok => 0, error => $guard->{'error'} } unless $guard->{'ok'};
	my $target = $guard->{'target'};
	if ($target->{'local'}) {
		my $here = &qa_readiness($opts);
		$here->{'target'} = $target->{'signatorial'} || '';
		$here->{'local'} = 1;
		return $here;
	}
	my $hop_row = { %{$target} };
	# Ask on the signed rail alone: a stored session cookie could carry a lower
	# privilege and the Configure tier check would refuse the read before the
	# peer signature was ever examined.
	delete $hop_row->{'cookie'};
	my $hop = eval { &remote_useragent_maker({ signatorial => $target->{'signatorial'}, rm => $hop_row }) };
	return { ok => 0, error => 'no route to that machine', target => $target->{'signatorial'} } unless $hop && $hop->{'ua'} && $hop->{'manager'};
	my $url = $hop->{'manager'} . '/manager/configure/qa_device_ready?signatorial=' . &subs::signatorial_designer();
	my $res = eval { $hop->{'ua'}->inactivity_timeout(25)->get($url)->result };
	return &qa_hop_answer($res, 'that machine did not answer the readiness check', $target->{'signatorial'});
}

# --- install -----------------------------------------------------------------
# The setup is a short list of package installs; the AVD and the checkout are
# manual steps and say so. Only a missing tool is touched - a ready machine has
# no steps at all.
sub qa_install_status_file {
	return &subs::home('~/.president/qa_install.json');
}

sub qa_install_status {
	my ($file) = @_;
	$file ||= &qa_install_status_file();
	return {} unless $file && -e $file;
	my $raw = do {
		local $/;
		open my $fh, '<', $file or return {};
		<$fh>;
	};
	my $data = eval { decode_json $raw };
	return ref $data eq 'HASH' ? $data : {};
}

sub qa_install_status_write {
	my ($data) = @_;
	return unless ref $data eq 'HASH';
	my $file = &qa_install_status_file();
	(my $dir = $file) =~ s{/[^/]+$}{};
	mkdir $dir unless -d $dir;
	open my $fh, '>', $file or return;
	print $fh encode_json($data);
	close $fh;
	return $data;
}

# The package set for each missing tool, deduplicated across steps so a JDK
# installed for java/javac/jlink is one command, not three.
sub qa_install_plan {
	my ($missing) = @_;
	my %want = map { $_ => 1 } @{ $missing || [] };
	my %pkgs = (
		perl    => [ 'perl', 'libtest-simple-perl' ],
		prove   => [ 'perl', 'libtest-simple-perl' ],
		sqlite3 => [ 'sqlite3' ],
		unshare => [ 'util-linux' ],
		mkosi   => [ 'mkosi' ],
		qemu    => [ 'qemu-system-x86', 'qemu-utils' ],
		java    => [ 'openjdk-17-jdk' ],
		javac   => [ 'openjdk-17-jdk' ],
		jlink   => [ 'openjdk-17-jdk' ],
		adb     => [ 'android-tools-adb' ],
	);
	my @steps;
	my %seen;
	foreach my $key ( qw(repo perl prove sqlite3 unshare mkosi qemu java javac jlink adb avd) ) {
		next unless $want{$key};
		if ($key eq 'repo') {
			push @steps, { key => 'repo', manual => 1, note => 'Put a JawnOS checkout at ~/jawnos (the suite and its systemd unit both read it).' };
			next;
		}
		if ($key eq 'avd') {
			push @steps, { key => 'avd', manual => 1, note => 'Create an Android AVD with sdkmanager/avdmanager; it is only used by the l4 layer.' };
			next;
		}
		my @want_pkgs = grep { !$seen{$_}++ } @{ $pkgs{$key} || [] };
		next unless @want_pkgs;
		push @steps, { key => $key, manual => 0, packages => \@want_pkgs };
	}
	return \@steps;
}

sub qa_package_manager {
	return 'apt-get' if &qa_which('apt-get');
	return 'dnf'     if &qa_which('dnf');
	return 'yum'     if &qa_which('yum');
	return 'zypper'  if &qa_which('zypper');
	return 'pacman'  if &qa_which('pacman');
	return '';
}

sub qa_install_command {
	my ($packages) = @_;
	my $pm = &qa_package_manager();
	return () unless $pm;
	my @sudo = ( 'sudo', '-n' );
	return (@sudo, 'env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', @{$packages}) if $pm eq 'apt-get';
	return (@sudo, $pm, 'install', '-y', @{$packages}) if $pm eq 'dnf' || $pm eq 'yum' || $pm eq 'zypper';
	return (@sudo, 'pacman', '-S', '--noconfirm', @{$packages}) if $pm eq 'pacman';
	return ();
}

# Run the planned commands one at a time, recording each one's result so the
# panel's poll sees progress and the last failure names the tool that held it
# up. Only ever called on the machine that owns the QA environment.
sub qa_install_execute {
	my ($steps) = @_;
	my $status = &qa_install_status();
	my @state = @{ $status->{'steps'} || [] };
	my $log = $status->{'log'} || '';
	my $failed = 0;
	for my $i ( 0 .. $#{$steps || []} ) {
		my $step = $steps->[$i];
		$state[$i] = { key => $step->{'key'}, state => 'running' };
		&qa_install_status_write({ %{$status}, state => 'running', step => $i + 1, steps => \@state, log => $log });
		if ($step->{'manual'}) {
			$log .= $step->{'key'} . ": " . ($step->{'note'} || 'manual step') . "\n";
			$state[$i]->{'state'} = 'manual';
			next;
		}
		my @cmd = &qa_install_command( $step->{'packages'} );
		unless (@cmd) {
			$log .= $step->{'key'} . ": no package manager found\n";
			$state[$i]->{'state'} = 'failed';
			$failed = 1;
			last;
		}
		my $rc = system(@cmd);
		$rc = ($rc == 0) ? 0 : ($rc >> 8 || 1);
		$state[$i]->{'state'} = $rc ? 'failed' : 'done';
		$log .= $step->{'key'} . ': ' . ($rc ? "failed ($rc)" : 'installed') . "\n";
		if ($rc) { $failed = 1; last; }
	}
	my $done = &qa_readiness({ install => {} });
	&qa_install_status_write({
		%{$status},
		state => $failed ? 'failed' : 'done',
		step => scalar(@state),
		steps => \@state,
		log => $log,
		missing => $done->{'missing'},
		updated => &subs::rightNow(),
	});
	return { state => $failed ? 'failed' : 'done', log => $log, steps => \@state };
}

# ---------------------------------------------------------------------------
# Nightly schedule: the three times, and the timer that holds each one
# ---------------------------------------------------------------------------
# Configure -> Plat -> QA owns three times - the 05:00 suite, the 05:30 UX run
# and the 06:00 coding night. Each is a house setting (device 'all') in HH:MM,
# and each is pushed to the chosen machine's systemd timer as a drop-in beside
# the unit (`<unit>.timer.d/50-jawn-schedule.conf`, an OnCalendar line). The
# panel shows the OnCalendar the timer actually holds, so a field and the unit
# can never quietly disagree.
#
# The drop-in is a change to /etc and a `systemctl restart`, so it is privileged
# work: locally through the same `sudo -n` path the QA install already uses,
# remotely over the signed remote-command rail (the target runs the identical
# helper on itself). Neither writes outside those two files and one reload.

# The three runs. `delay` is the only one that carries a randomized delay: the
# suite is 20 minutes of route and database work and a jitter keeps two machines
# from starting it in the same second. The UX and coding runs are left alone.
sub qa_runs {
	return (
		{ key => 'suite',  setting => 'qa_night_time',  unit => 'jawnos-qa',        default => '05:00', delay => '5m' },
		{ key => 'ux',     setting => 'qa_ux_time',     unit => 'jawnos-qa-ux',     default => '05:30', delay => '' },
		{ key => 'coding', setting => 'qa_coding_time', unit => 'jawnos-qa-coding', default => '06:00', delay => '' },
	);
}

sub qa_run_lookup {
	my ($key) = @_;
	return undef unless defined $key && length $key;
	foreach my $run ( &qa_runs() ) {
		return $run if $run->{'key'} eq $key;
	}
	return undef;
}

# A time the panel, the setting and the unit can all agree on: `HH:MM`, 00:00 to
# 23:59. Anything else - 24:00, 9:5, `five`, a blank - is '' and is rejected,
# never guessed or clamped into a valid-looking hour.
sub qa_time_clean {
	my ($value) = @_;
	return '' unless defined $value;
	$value =~ s/^\s+//;
	$value =~ s/\s+$//;
	return '' unless $value =~ /^(\d{1,2}):(\d{2})$/;
	my ($hour, $minute) = ( $1 + 0, $2 + 0 );
	return '' if $hour > 23 || $minute > 59;
	return sprintf('%02d:%02d', $hour, $minute);
}

# A stored value that is not a time falls back to the run's own default, so a
# bad row can never hand the panel (or the timer) an unreadable schedule.
sub qa_times_read {
	my $opts = shift || {};
	my $grab = $opts->{'grabber'};
	my %out;
	foreach my $run ( &qa_runs() ) {
		my $raw;
		if ($grab) {
			$raw = $grab->( $run->{'setting'} );
		}
		else {
			$raw = &subs::setting_grabber({ app => '__president', setting => $run->{'setting'}, device => 'all' });
			$raw = &subs::setting_grabber({ app => '__president', setting => $run->{'setting'} })
				unless defined $raw && length $raw;
		}
		my $clean = &qa_time_clean($raw);
		$out{ $run->{'key'} } = length $clean ? $clean : $run->{'default'};
	}
	return \%out;
}

# Save one time. The setter is handed ($value, $setting_name) so a test can keep
# the three apart without reaching the database.
sub qa_time_save {
	my ($key, $value, $opts) = @_;
	$opts ||= {};
	my $run = &qa_run_lookup($key);
	return { ok => 0, error => 'unknown run', field => ($key // '') } unless $run;
	my $clean = &qa_time_clean($value);
	return { ok => 0, error => 'time must be HH:MM between 00:00 and 23:59', field => $key }
		unless length $clean;
	my $set = $opts->{'setter'};
	unless ($set) {
		$set = sub {
			&subs::setting_setter({ app => '__president', setting => $_[1], device => 'all', value => $_[0] });
		};
	}
	$set->( $clean, $run->{'setting'} );
	return { ok => 1, key => $key, time => $clean, setting => $run->{'setting'} };
}

# The guard a save and a Run now share: the target must be a computer or a
# server, and it must be the machine the house chose. A phone that opens
# Configure cannot retime or start a run on itself or anywhere else.
sub qa_run_guard {
	my ($signatorial, $opts) = @_;
	$opts ||= {};
	my $guard = &qa_install_guard($signatorial, $opts);
	return $guard unless $guard->{'ok'};
	my $target = $guard->{'target'};
	my $chosen = exists $opts->{'chosen'} ? &qa_nightly_clean( $opts->{'chosen'} ) : &qa_nightly_device($opts);
	return { ok => 0, error => 'the nightly system is off; choose a machine to turn it on' }
		if &qa_nightly_is_off($chosen);
	my $self = exists $opts->{'self'} ? $opts->{'self'} : &subs::signatorial_designer();
	if ($target->{'local'}) {
		my $kind = exists $opts->{'device_kind'} ? $opts->{'device_kind'} : &subs::device_setter();
		return { ok => 0, error => 'not an eligible device (computer or server only)' }
			unless &qa_device_kind_eligible($kind);
		return { ok => 0, error => 'the nightly belongs to another machine, so it cannot be run or retimed here' }
			if length $chosen && (!$self || $chosen ne $self);
		return { ok => 1, target => $target };
	}
	return { ok => 0, error => 'that machine is not the chosen nightly device' }
		if $chosen ne $target->{'signatorial'};
	return { ok => 1, target => $target };
}

# Save all three times. Every field is validated before anything is written, and
# the target is guarded first, so a refused save changes neither the settings nor
# a timer.
sub qa_times_save {
	my ($times, $opts) = @_;
	$opts ||= {};
	my ( %clean, @bad );
	foreach my $run ( &qa_runs() ) {
		my $raw = ref $times eq 'HASH' ? $times->{ $run->{'key'} } : undef;
		my $time = &qa_time_clean($raw);
		if (length $time) { $clean{ $run->{'key'} } = $time }
		else { push @bad, $run->{'key'} }
	}
	return { ok => 0, error => 'time must be HH:MM between 00:00 and 23:59', fields => \@bad }
		if @bad;
	my $target_sig;
	if (exists $opts->{'signatorial'}) { $target_sig = $opts->{'signatorial'} }
	elsif (exists $opts->{'chosen'}) { $target_sig = &qa_nightly_clean( $opts->{'chosen'} ) }
	else { $target_sig = &qa_nightly_device($opts) }
	my $guard = &qa_run_guard( $target_sig, $opts );
	return { ok => 0, error => $guard->{'error'} } unless $guard->{'ok'};
	foreach my $run ( &qa_runs() ) {
		&qa_time_save( $run->{'key'}, $clean{ $run->{'key'} }, $opts );
	}
	return {
		ok => 1,
		saved => 1,
		times => \%clean,
		target => $guard->{'target'},
		local => ( $guard->{'target'}->{'local'} ? 1 : 0 ),
	};
}

sub qa_dropin_file {
	my ($run) = @_;
	$run = &qa_run_lookup($run) unless ref $run eq 'HASH';
	return '' unless $run;
	return '/etc/systemd/system/' . $run->{'unit'} . '.timer.d/50-jawn-schedule.conf';
}

# The drop-in is deliberately only the line the panel owns. Persistent, the
# service and the fence stay in the shipped unit file.
sub qa_dropin_body {
	my ($run, $time) = @_;
	$run = &qa_run_lookup($run) unless ref $run eq 'HASH';
	return '' unless $run;
	my $clean = &qa_time_clean($time);
	return '' unless length $clean;
	my $body = "# Written by JawnOS Configure -> Plat -> QA. The panel rewrites this\n"
		. "# file when the time is changed there; edit the time in the panel.\n"
		. "[Timer]\n"
		. "OnCalendar=*-*-* $clean:00\n";
	$body .= "RandomizedDelaySec=" . $run->{'delay'} . "\n" if $run->{'delay'};
	return $body;
}

# Run one command without a shell and hand back its status and text. Only the
# QA schedule path uses this; the output is a line or two of systemctl text.
sub qa_command {
	my (@cmd) = @_;
	require IPC::Open3;
	require Symbol;
	my $err = Symbol::gensym();
	my ( $in, $out );
	my $pid = eval { IPC::Open3::open3( $in, $out, $err, @cmd ) };
	return ( 127, 'could not run ' . join(' ', @cmd) ) unless $pid;
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	close $out;
	close $err;
	waitpid($pid, 0);
	my $rc = $? >> 8;
	my $text = $stdout . $stderr;
	$text =~ s/^\s+|\s+$//g;
	return ( $rc, $text );
}

sub qa_systemd_missing {
	my ($text) = @_;
	return 0 unless defined $text && length $text;
	return $text =~ /not found|No such file|does not exist/i ? 1 : 0;
}

# Write the three drop-ins, reload systemd once, and restart each timer. Every
# unit is reported separately: a timer that is not installed on the machine is
# named as such, and a real failure is a failure - the panel never shows a
# silent success. `dry_run` returns the file and its content and changes
# nothing, which is what the tests use.
sub qa_retime_local {
	my $opts = shift || {};
	my $dry = $opts->{'dry_run'} ? 1 : 0;
	my $run_cmd = $opts->{'runner'} || sub { &qa_command(@_) };
	my $times = ref $opts->{'times'} eq 'HASH' ? $opts->{'times'} : &qa_times_read($opts);
	my ( @rows, @written );
	foreach my $run ( &qa_runs() ) {
		my $time = &qa_time_clean( $times->{ $run->{'key'} } );
		my $row = {
			key => $run->{'key'}, unit => $run->{'unit'}, setting => $run->{'setting'},
			path => &qa_dropin_file($run),
		};
		unless (length $time) {
			$row->{'ok'} = 0;
			$row->{'state'} = 'invalid';
			$row->{'error'} = 'time must be HH:MM between 00:00 and 23:59';
			push @rows, $row;
			next;
		}
		$row->{'time'} = $time;
		$row->{'body'} = &qa_dropin_body( $run, $time );
		if ($dry) {
			$row->{'ok'} = 1;
			$row->{'state'} = 'planned';
			$row->{'command'} = [ 'sudo', '-n', 'install', '-D', '-m', '0644', '<drop-in>', $row->{'path'} ];
			push @rows, $row;
			next;
		}
		my ( $fh, $tmp );
		{
			require File::Temp;
			( $fh, $tmp ) = File::Temp::tempfile( 'jawn-qa-schedule-XXXXXX', TMPDIR => 1, UNLINK => 1 );
			print {$fh} $row->{'body'};
			close $fh;
		}
		my ( $rc, $out ) = $run_cmd->( 'sudo', '-n', 'install', '-D', '-m', '0644', $tmp, $row->{'path'} );
		unless ($rc == 0) {
			$row->{'ok'} = 0;
			$row->{'state'} = 'failed';
			$row->{'error'} = length $out ? $out : 'the drop-in could not be written (needs root on that machine)';
			push @rows, $row;
			next;
		}
		push @written, $row;
		push @rows, $row;
	}
	if (!$dry && @written) {
		my ( $rc, $out ) = $run_cmd->( 'sudo', '-n', 'systemctl', 'daemon-reload' );
		foreach my $row (@written) {
			if ($rc != 0) {
				$row->{'ok'} = 0;
				$row->{'state'} = 'failed';
				$row->{'error'} = 'systemd daemon-reload failed' . (length $out ? ": $out" : '');
				next;
			}
			my ( $rrc, $rout ) = $run_cmd->( 'sudo', '-n', 'systemctl', 'restart', $row->{'unit'} . '.timer' );
			if ($rrc == 0) {
				$row->{'ok'} = 1;
				$row->{'state'} = 'retimed';
				next;
			}
			if ( &qa_systemd_missing($rout) ) {
				$row->{'ok'} = 1;
				$row->{'state'} = 'not-installed';
				$row->{'note'} = 'the timer is not installed on that machine';
				next;
			}
			$row->{'ok'} = 0;
			$row->{'state'} = 'failed';
			$row->{'error'} = length $rout ? $rout : 'systemctl restart exited ' . $rrc;
		}
	}
	my $failed = scalar( grep { !$_->{'ok'} } @rows );
	return {
		ok => $failed ? 0 : 1,
		dry_run => $dry,
		rows => \@rows,
		error => $failed ? 'some timers were not retimed' : '',
	};
}

# ---------------------------------------------------------------------------
# Release schedule: when the land promotion runs
# ---------------------------------------------------------------------------
# The promoter is the authority's job, and its timer ships weekly. Configure ->
# Plat -> QA rewrites that schedule through a drop-in (`OnCalendar=` reset plus
# the chosen line), so a release can be hourly, daily, weekly, monthly, a fixed
# date, or a phrase like "every third friday of the month". The phrase becomes
# the one OnCalendar line systemd understands; anything else is refused rather
# than guessed. The drop-in is privileged, like the QA times: `sudo -n` here.

my %RELEASE_DOW = (
	sun => 'Sun', mon => 'Mon', tue => 'Tue', wed => 'Wed',
	thu => 'Thu', fri => 'Fri', sat => 'Sat',
);
my %RELEASE_ORDINAL = (
	first => 1, '1st' => 1, second => 2, '2nd' => 2, third => 3, '3rd' => 3,
	fourth => 4, '4th' => 4, fifth => 5, '5th' => 5,
);

sub release_schedule_default { return 'Mon 04:00:00' }

# One OnCalendar expression out of systemd's one-line report, a unit file or a
# drop-in. The report ends the value at `;`; a file ends it at the newline.
sub qa_oncalendar_text {
	my ($text) = @_;
	return '' unless defined $text && length $text;
	while ($text =~ /OnCalendar=([^;\n]*)/g) {
		my $value = $1;
		$value =~ s/^\s+|\s+$//g;
		return $value if length $value;
	}
	return '';
}

sub release_schedule_parse {
	my ($text) = @_;
	return { ok => 0, error => 'say when to release' }
		unless defined $text && $text =~ /\S/;
	my $phrase = $text;
	$phrase =~ s/^\s+|\s+$//g;
	$phrase =~ s/\s+/ /g;
	my $spoken = $phrase;

	my ($hour, $minute) = (4, 0);
	my $has_time = 0;
	if ($phrase =~ s/\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b//i
		|| $phrase =~ s/\b(\d{1,2}):(\d{2})\b//) {
		my ($h, $m, $ap) = ($1 + 0, (defined $2 ? $2 : 0) + 0, lc(defined $3 ? $3 : ''));
		$h += 12 if $ap eq 'pm' && $h < 12;
		$h = 0 if $ap eq 'am' && $h == 12;
		return { ok => 0, error => 'the time must be between 00:00 and 23:59' }
			if $h > 23 || $m > 59;
		($hour, $minute) = ($h, $m);
		$has_time = 1;
	}
	$phrase =~ s/\s+/ /g;
	$phrase =~ s/^\s+|\s+$//g;
	my $lower = lc $phrase;
	my $clock = sprintf('%02d:%02d:00', $hour, $minute);
	my $done = sub {
		return { ok => 1, oncalendar => $_[0], phrase => $spoken };
	};

	return $done->(sprintf('*-*-* *:%02d:00', $minute))
		if $lower =~ /^(?:hourly|every hour|each hour)$/;
	return $done->("*-*-* $clock")
		if $lower =~ /^(?:daily|nightly|every day|each day)$/;
	return $done->("Mon *-*-* $clock")
		if $lower =~ /^(?:weekly|every week|each week)$/;
	return $done->("*-*-01 $clock")
		if $lower =~ /^(?:monthly|every month|each month)$/;
	if ($lower =~ /^(?:monthly|every month) on the (\d{1,2})(?:st|nd|rd|th)?$/) {
		my $day = $1 + 0;
		return { ok => 0, error => 'the day of the month must be 1 to 31' }
			if $day < 1 || $day > 31;
		return $done->(sprintf('*-*-%02d %s', $day, $clock));
	}
	if ($lower =~ /^(?:every|each) (sun|mon|tue|wed|thu|fri|sat)(?:day)?$/) {
		return $done->("$RELEASE_DOW{$1} *-*-* $clock");
	}
	if ($lower =~ /^(?:every|each|the) (first|second|third|fourth|fifth|1st|2nd|3rd|4th|5th) (sun|mon|tue|wed|thu|fri|sat)(?:day)?(?: of the month)?$/) {
		my $nth = $RELEASE_ORDINAL{$1};
		my $from = ($nth - 1) * 7 + 1;
		my $to = $nth * 7;
		$to = 31 if $to > 31;
		return $done->("$RELEASE_DOW{$2} *-*-$from..$to $clock");
	}
	if ($lower =~ /^every (\d+) days?$/) {
		my $n = $1 + 0;
		return { ok => 0, error => 'every N days needs N between 1 and 31' }
			if $n < 1 || $n > 31;
		return $done->(sprintf('*-*-01/%d %s', $n, $clock));
	}
	if ($lower =~ /^every (\d+) hours?$/) {
		my $n = $1 + 0;
		return { ok => 0, error => 'every N hours needs N between 1 and 23' }
			if $n < 1 || $n > 23;
		return $done->(sprintf('*-*-* 00/%d:%02d:00', $n, $minute));
	}
	if ($lower =~ /^(\d{4}-\d{2}-\d{2})$/) {
		return { ok => 0, error => 'a fixed date needs a time, like 2026-12-25 04:00' }
			unless $has_time;
		return $done->("$1 $clock");
	}
	return {
		ok => 0,
		error => 'say hourly, daily, weekly, monthly, every friday, every third friday of the month, '
			. 'every 3 days, every 2 hours, or a date like 2026-12-25 04:00',
	};
}

sub release_schedule_read {
	my $opts = shift || {};
	my $raw;
	if ($opts->{'grabber'}) { $raw = $opts->{'grabber'}->('release_schedule') }
	else {
		$raw = &subs::setting_grabber({ app => '__president', setting => 'release_schedule', device => 'all' });
		$raw = &subs::setting_grabber({ app => '__president', setting => 'release_schedule' })
			unless defined $raw && length $raw;
	}
	$raw = '' unless defined $raw;
	$raw =~ s/^\s+|\s+$//g;
	$raw =~ s/\s+/ /g;
	return &release_schedule_default()
		unless $raw =~ /^[A-Za-z*0-9][A-Za-z0-9*.,\/:~ -]*$/ && $raw =~ /\S+ \S+/;
	return $raw;
}

sub release_schedule_dropin_file {
	return '/etc/systemd/system/jawnos-land-promote.timer.d/50-jawn-schedule.conf';
}

sub release_schedule_dropin_body {
	my ($oncalendar) = @_;
	$oncalendar = &release_schedule_read() unless defined $oncalendar && length $oncalendar;
	return "# Written by JawnOS Configure -> Plat -> QA. The panel rewrites this\n"
		. "# file when the release schedule is changed there; set it in the panel.\n"
		. "[Timer]\n"
		. "OnCalendar=\n"
		. "OnCalendar=$oncalendar\n";
}

sub release_schedule_apply {
	my $opts = shift || {};
	my $dry = $opts->{'dry_run'} ? 1 : 0;
	my $run_cmd = $opts->{'runner'} || sub { &qa_command(@_) };
	my $cal = $opts->{'oncalendar'} || &release_schedule_read($opts);
	my $row = {
		unit => 'jawnos-land-promote',
		path => &release_schedule_dropin_file(),
		oncalendar => $cal,
		body => &release_schedule_dropin_body($cal),
	};
	if ($dry) {
		$row->{'ok'} = 1;
		$row->{'state'} = 'planned';
		$row->{'command'} = [ 'sudo', '-n', 'install', '-D', '-m', '0644', '<drop-in>', $row->{'path'} ];
		return { ok => 1, dry_run => 1, rows => [$row] };
	}
	my ( $fh, $tmp );
	{
		require File::Temp;
		( $fh, $tmp ) = File::Temp::tempfile( 'jawn-release-schedule-XXXXXX', TMPDIR => 1, UNLINK => 1 );
		print {$fh} $row->{'body'};
		close $fh;
	}
	my ( $rc, $out ) = $run_cmd->( 'sudo', '-n', 'install', '-D', '-m', '0644', $tmp, $row->{'path'} );
	if ($rc != 0) {
		$row->{'ok'} = 0;
		$row->{'state'} = 'failed';
		$row->{'error'} = length $out ? $out : 'the drop-in could not be written (needs root on that machine)';
		return { ok => 0, rows => [$row], error => $row->{'error'} };
	}
	my ( $drc, $dout ) = $run_cmd->( 'sudo', '-n', 'systemctl', 'daemon-reload' );
	if ($drc != 0) {
		$row->{'ok'} = 0;
		$row->{'state'} = 'failed';
		$row->{'error'} = 'systemd daemon-reload failed' . (length $dout ? ": $dout" : '');
		return { ok => 0, rows => [$row], error => $row->{'error'} };
	}
	my ( $rrc, $rout ) = $run_cmd->( 'sudo', '-n', 'systemctl', 'restart', $row->{'unit'} . '.timer' );
	if ($rrc == 0) {
		$row->{'ok'} = 1;
		$row->{'state'} = 'retimed';
		return { ok => 1, rows => [$row] };
	}
	if ( &qa_systemd_missing($rout) ) {
		$row->{'ok'} = 1;
		$row->{'state'} = 'not-installed';
		$row->{'note'} = 'the release timer is not installed on that machine';
		return { ok => 1, rows => [$row] };
	}
	$row->{'ok'} = 0;
	$row->{'state'} = 'failed';
	$row->{'error'} = length $rout ? $rout : 'systemctl restart exited ' . $rrc;
	return { ok => 0, rows => [$row], error => $row->{'error'} };
}

sub release_schedule_save {
	my ($text, $opts) = @_;
	$opts ||= {};
	my $parsed = &release_schedule_parse($text);
	return { ok => 0, error => $parsed->{'error'} } unless $parsed->{'ok'};
	my $set = $opts->{'setter'} || sub {
		&subs::setting_setter({ app => '__president', setting => 'release_schedule', device => 'all', value => $_[0] });
	};
	$set->( $parsed->{'oncalendar'} );
	my $applied = &release_schedule_apply({ %$opts, oncalendar => $parsed->{'oncalendar'} });
	my $row = $applied->{'rows'}[0] || {};
	return {
		ok => 1,
		saved => 1,
		oncalendar => $parsed->{'oncalendar'},
		phrase => $parsed->{'phrase'},
		state => $row->{'state'},
		retime_ok => $row->{'ok'} ? 1 : 0,
		error => $row->{'ok'} ? '' : ($row->{'error'} || $applied->{'error'} || 'the timer was not retimed'),
	};
}

sub release_schedule_state {
	my $opts = shift || {};
	my $run_cmd = $opts->{'runner'} || sub { &qa_command(@_) };
	my $repo = defined $opts->{'repo'} ? $opts->{'repo'} : &subs::home('~/jawnos');
	my $unit = 'jawnos-land-promote';
	my $row = {
		unit => $unit,
		dropin => $opts->{'dropin'} || &release_schedule_dropin_file(),
		setting => &release_schedule_read($opts),
		oncalendar => '',
		source => '',
	};
	my ( $rc, $out ) = $run_cmd->( 'systemctl', 'show', '-p', 'TimersCalendar', "$unit.timer" );
	my $cal = $rc == 0 ? &qa_oncalendar_text($out) : '';
	if (length $cal) { $row->{'oncalendar'} = $cal; $row->{'source'} = 'systemd' }
	else {
		foreach my $pair (
			[ $row->{'dropin'}, 'drop-in' ],
			[ "$repo/scripts/systemd/$unit.timer", 'unit' ],
		) {
			my $path = $pair->[0];
			next unless defined $path && length $path && -e $path;
			open( my $fh, '<', $path ) or next;
			my $body = do { local $/; <$fh> } // '';
			close $fh;
			my $found = &qa_oncalendar_text($body);
			next unless length $found;
			$row->{'oncalendar'} = $found;
			$row->{'source'} = $pair->[1];
			last;
		}
	}
	return $row;
}

# Whether this machine has the promotion oneshot, and what it is doing. A peer
# asks this before a release is handed over, so a machine with no service is
# skipped instead of being asked to run one that is not there.
sub release_service_check {
	my $opts = shift || {};
	my $run_cmd = $opts->{'runner'} || sub { &qa_command(@_) };
	my $unit = 'jawnos-land-promote';
	my ( $rc, $out ) = $run_cmd->( 'systemctl', 'show', '-p', 'LoadState', '-p', 'ActiveState', '-p', 'SubState', "$unit.service" );
	my $text = defined $out ? $out : '';
	my $installed = ( $rc == 0 && $text =~ /^LoadState=loaded$/m ) ? 1 : 0;
	my ($active) = $text =~ /^ActiveState=(\w+)/m;
	my ($sub) = $text =~ /^SubState=(\w+)/m;
	$active = '' unless defined $active;
	$sub = '' unless defined $sub;
	my $busy = $active =~ /^(?:active|activating|reloading|deactivating)$/ ? 1 : 0;
	return {
		ok => 1,
		unit => $unit,
		installed => $installed,
		active => $busy,
		state => !$installed ? 'not-installed' : ($busy ? 'running' : ($active eq 'failed' ? 'failed' : 'idle')),
		substate => $sub,
	};
}

# Start the release promotion now: the same oneshot the weekly timer runs.
# `systemctl show` is the guard (no service is a refusal the caller can hand to
# another machine, and one already running is a refusal too), and `--no-block`
# hands the panel its answer before the suite, the push and the restart take
# the app away. No person or agent walks the release; the service does it, and
# a red suite or a diverged main is a refusal it logs.
sub release_now_local {
	my $opts = shift || {};
	my $run_cmd = $opts->{'runner'} || sub { &qa_command(@_) };
	my $unit = 'jawnos-land-promote';
	my $check = ref $opts->{'check'} eq 'HASH' ? $opts->{'check'} : &release_service_check($opts);
	unless ($check->{'installed'}) {
		return {
			ok => 0, unit => $unit, state => 'not-installed',
			error => 'the release service is not installed on this machine',
		};
	}
	if ($check->{'active'}) {
		return {
			ok => 0, unit => $unit, state => 'running',
			error => 'a release is already running',
		};
	}
	return {
		ok => 1, unit => $unit, state => 'planned', dry_run => 1,
		command => [ 'sudo', '-n', 'systemctl', 'start', '--no-block', "$unit.service" ],
	} if $opts->{'dry_run'};
	my ( $rc, $out ) = $run_cmd->( 'sudo', '-n', 'systemctl', 'start', '--no-block', "$unit.service" );
	unless ($rc == 0) {
		my $missing = &qa_systemd_missing($out);
		return {
			ok => 0, unit => $unit,
			state => $missing ? 'not-installed' : 'failed',
			error => $missing
				? 'the release service is not installed on this machine'
				: ( length $out ? $out : 'systemctl could not start the release (needs root on this machine)' ),
		};
	}
	return {
		ok => 1, unit => $unit, state => 'running',
		started => exists $opts->{'now'} ? $opts->{'now'} : &subs::rightNow(),
	};
}

# Release here when this machine holds the service; otherwise ask the other
# computers and servers over the signed peer rail which one does, and hand the
# request to the first that answers. The probe is a read-only check, so a
# machine with no unit is skipped without being asked to start one.
sub release_now_anywhere {
	my $opts = shift || {};
	my $here = ref $opts->{'check'} eq 'HASH' ? $opts->{'check'} : &release_service_check($opts);
	if ($here->{'installed'}) {
		my $run = &release_now_local({ %{$opts}, check => $here });
		$run->{'where'} = 'local';
		return $run;
	}
	my $machines = ref $opts->{'machines'} eq 'ARRAY' ? $opts->{'machines'} : &qa_target_machines($opts);
	my $send = $opts->{'sender'} || sub { &Manager::remote_command_send($_[0]) };
	my @tried;
	foreach my $rm (@{$machines}) {
		next unless ref $rm eq 'HASH' && defined $rm->{'uuid'} && length $rm->{'uuid'};
		my $name = '';
		foreach my $key (qw(hostname fqdn ip signatorial uuid)) {
			my $value = $rm->{$key};
			if (defined $value && length $value) { $name = $value; last; }
		}
		my $probe = eval {
			$send->({
				uuid => $rm->{'uuid'},
				verb => 'release_probe',
				args => {},
				inactivity_timeout => 5,
				request_timeout => 8,
			});
		};
		my $seen = &release_observation($probe);
		unless ($seen && $seen->{'installed'}) {
			push @tried, $name;
			next;
		}
		my $answer = eval {
			$send->({
				uuid => $rm->{'uuid'},
				verb => 'release_now',
				args => { dry_run => ($opts->{'dry_run'} ? 1 : 0) },
			});
		};
		my $run = &release_observation($answer);
		unless (ref $run eq 'HASH') {
			push @tried, $name;
			next;
		}
		$run->{'where'} = 'remote';
		$run->{'machine'} = $name;
		$run->{'machine_uuid'} = $rm->{'uuid'};
		return $run;
	}
	return {
		ok => 0, state => 'not-installed', where => 'none',
		error => @tried
			? 'no machine the house can reach has the release service'
			: 'no machine in the house has the release service',
		tried => \@tried,
	};
}

# The peer rail wraps a verb's result in an observation; a caller that already
# speaks to a stub (the tests) may hand back the result itself.
sub release_observation {
	my ($res) = @_;
	return undef unless ref $res eq 'HASH';
	return $res->{'observation'} if ref $res->{'observation'} eq 'HASH';
	return $res if exists $res->{'ok'};
	return undef;
}

# The HH:MM a unit's timer really fires at. `systemctl show -p TimersCalendar`
# answers for an installed timer; a machine with no timer falls back to the
# drop-in, and then to the unit file shipped in the repo. `source` says which.
sub qa_oncalendar_time {
	my ($text) = @_;
	return '' unless defined $text && length $text;
	# One OnCalendar line, whether it came from systemd's one-line report (with
	# the `; next_elapse=...` tail) or from a unit or drop-in file.
	return '' unless $text =~ /OnCalendar=[^\n;}]*?(\d{1,2}):(\d{2}):\d{2}/;
	my ( $hour, $minute ) = ( $1 + 0, $2 + 0 );
	return '' if $hour > 23 || $minute > 59;
	return sprintf('%02d:%02d', $hour, $minute);
}

sub qa_file_oncalendar {
	my ($path) = @_;
	return '' unless defined $path && length $path && -e $path;
	open( my $fh, '<', $path ) or return '';
	my $body = do { local $/; <$fh> } // '';
	close $fh;
	return &qa_oncalendar_time($body);
}

sub qa_run_state_file {
	my $opts = shift || {};
	return $opts->{'state_file'} if defined $opts->{'state_file'};
	return &subs::home('~/.president/qa_runs.json');
}

sub qa_run_state_read {
	my $opts = shift || {};
	my $file = &qa_run_state_file($opts);
	return {} unless $file && -e $file;
	open( my $fh, '<', $file ) or return {};
	my $raw = do { local $/; <$fh> } // '';
	close $fh;
	my $data = eval { decode_json($raw) };
	return ref $data eq 'HASH' ? $data : {};
}

sub qa_run_state_write {
	my ($data, $opts) = @_;
	return unless ref $data eq 'HASH';
	my $file = &qa_run_state_file( $opts || {} );
	return unless $file && length $file;
	(my $dir = $file) =~ s{/[^/]+$}{};
	mkdir $dir unless -d $dir;
	open( my $fh, '>', $file ) or return;
	print {$fh} encode_json($data);
	close $fh;
	return $data;
}

# What the panel shows per run: the setting, the schedule the unit actually
# holds, and whether the run is going. A `drift` is a field that no longer
# matches the timer, which is exactly what the panel must make visible.
sub qa_schedule_local {
	my $opts = shift || {};
	my $run_cmd = $opts->{'runner'} || sub { &qa_command(@_) };
	my $times = &qa_times_read($opts);
	my $repo = defined $opts->{'repo'} ? $opts->{'repo'} : &subs::home('~/jawnos');
	my $state = &qa_run_state_read($opts);
	my @runs;
	foreach my $run ( &qa_runs() ) {
		my $unit = $run->{'unit'};
		my $row = {
			key => $run->{'key'}, unit => $unit, setting => $run->{'setting'},
			time => $times->{ $run->{'key'} },
			dropin => &qa_dropin_file($run),
			oncalendar => '', source => '', state => 'unknown', active => 0,
		};
		my ( $crc, $cout ) = $run_cmd->( 'systemctl', 'show', '-p', 'TimersCalendar', "$unit.timer" );
		my $cal = $crc == 0 ? &qa_oncalendar_time($cout) : '';
		if (length $cal) { $row->{'oncalendar'} = $cal; $row->{'source'} = 'systemd' }
		else {
			my $drop = &qa_file_oncalendar( $row->{'dropin'} );
			if (length $drop) { $row->{'oncalendar'} = $drop; $row->{'source'} = 'drop-in' }
			else {
				my $unit_file = &qa_file_oncalendar( "$repo/qa/systemd/$unit.timer" );
				$row->{'oncalendar'} = $unit_file;
				$row->{'source'} = length $unit_file ? 'unit-file' : '';
			}
		}
		my ( $arc, $aout ) = $run_cmd->( 'systemctl', 'show', '-p', 'ActiveState', '-p', 'SubState', "$unit.service" );
		if ($arc == 0 && defined $aout) {
			my ($act) = $aout =~ /ActiveState=(\w+)/;
			my ($sub) = $aout =~ /SubState=(\w+)/;
			$row->{'active'} = ( ($act // '') =~ /^(?:active|activating|reloading)$/ ) ? 1 : 0;
			$row->{'state'} = $row->{'active'} ? 'running' : ( ($act // '') eq 'failed' ? 'failed' : 'idle' );
			$row->{'substate'} = $sub // '';
		}
		my $last = $state->{ $run->{'key'} };
		$row->{'last_started'} = $last->{'started'} if ref $last eq 'HASH' && $last->{'started'};
		$row->{'drift'} = (length $row->{'oncalendar'} && $row->{'oncalendar'} ne $row->{'time'}) ? 1 : 0;
		push @runs, $row;
	}
	return {
		ok => 1, local => 1,
		hostname => &subs::machine_name(),
		runs => \@runs,
	};
}

# Ask the chosen machine for its schedule over the signed peer rail, exactly as
# the readiness card does. No unauthenticated route is added for it.
sub qa_schedule_for {
	my ($signatorial, $opts) = @_;
	$opts ||= {};
	return { ok => 1, off => 1, runs => [], target => 'none' }
		if &qa_nightly_is_off($signatorial);
	my $guard = &qa_install_guard( $signatorial, $opts );
	return { ok => 0, error => $guard->{'error'} } unless $guard->{'ok'};
	my $target = $guard->{'target'};
	if ( $target->{'local'} ) {
		my $here = &qa_schedule_local($opts);
		$here->{'target'} = $target->{'signatorial'} || '';
		return $here;
	}
	my $hop_row = { %{$target} };
	delete $hop_row->{'cookie'};
	my $hop = eval { &remote_useragent_maker({ signatorial => $target->{'signatorial'}, rm => $hop_row }) };
	return { ok => 0, error => 'no route to that machine', target => $target->{'signatorial'} }
		unless $hop && $hop->{'ua'} && $hop->{'manager'};
	my $url = $hop->{'manager'} . '/manager/configure/qa_schedule?signatorial=' . &subs::signatorial_designer();
	my $res = eval { $hop->{'ua'}->inactivity_timeout(25)->get($url)->result };
	return &qa_hop_answer($res, 'that machine did not answer the schedule check', $target->{'signatorial'});
}

# Start one run on this machine now. `systemctl is-active` is the first guard
# (a run already going is a refusal), and a short cooldown in the state file is
# the second: a oneshot can finish in under a second, so a double press would
# otherwise start it twice before the first answer reached the panel.
sub qa_run_now_local {
	my ($key, $opts) = @_;
	$opts ||= {};
	my $run = &qa_run_lookup($key);
	return { ok => 0, error => 'unknown run', run => ($key // '') } unless $run;
	my $unit = $run->{'unit'};
	my $now = exists $opts->{'now'} ? $opts->{'now'} : &subs::rightNow();
	my $cooldown = exists $opts->{'cooldown'} ? $opts->{'cooldown'} : 30;
	my $run_cmd = $opts->{'runner'} || sub { &qa_command(@_) };
	my $state = &qa_run_state_read($opts);
	my $last = $state->{$key};
	if ( ref $last eq 'HASH' && $last->{'started'} && $cooldown > 0
		&& ( $now - $last->{'started'} ) < $cooldown * 1000 )
	{
		return {
			ok => 0, run => $key, unit => $unit, state => 'running',
			error => 'that run has just been started; give it a moment',
			started => $last->{'started'},
		};
	}
	my ( $src, $sout ) = $run_cmd->( 'systemctl', 'is-active', $unit . '.service' );
	# The word decides, not the exit code: `is-active` answers 0 for active and
	# for activating on some systemd versions, and a run that is still starting is
	# just as much a run in progress.
	my $word = defined $sout ? $sout : '';
	$word =~ s/\s+$//;
	my $active = ( $word =~ /^(?:active|activating|reloading|deactivating)$/ ) ? 1 : 0;
	if ($active) {
		return { ok => 0, run => $key, unit => $unit, state => 'running', error => 'that run is already running' };
	}
	return {
		ok => 1, run => $key, unit => $unit, state => 'planned', dry_run => 1,
		command => [ 'sudo', '-n', 'systemctl', 'start', '--no-block', $unit . '.service' ],
	}
		if $opts->{'dry_run'};
	my ( $rc, $out ) = $run_cmd->( 'sudo', '-n', 'systemctl', 'start', '--no-block', $unit . '.service' );
	unless ($rc == 0) {
		return {
			ok => 0, run => $key, unit => $unit, state => 'failed',
			error => length $out ? $out : 'systemctl could not start the run (needs root on that machine)',
		};
	}
	$state->{$key} = { started => $now, state => 'running', unit => $unit };
	&qa_run_state_write( $state, $opts );
	return { ok => 1, run => $key, unit => $unit, state => 'running', started => $now };
}

# The install action's one entry point. `dry_run` (the tests, and a preview)
# returns the plan and changes nothing; a real run starts the steps in a
# background job so the panel can poll the status the readiness payload carries.
sub qa_install_local {
	my $opts = shift || {};
	my $dry = $opts->{'dry_run'} ? 1 : 0;
	my $ready = &qa_readiness($opts);
	my $missing = $ready->{'missing'} || [];
	my $steps = &qa_install_plan($missing);
	if (!@{$missing}) {
		return { ok => 1, ready => 1, missing => [], steps => [], state => 'ready', dry_run => $dry };
	}
	if ($dry) {
		return { ok => 1, ready => 0, missing => $missing, steps => $steps, state => 'planned', dry_run => 1 };
	}
	my $running = &qa_install_status();
	if (($running->{'state'} || '') eq 'running') {
		return { ok => 0, error => 'an install is already running', install => $running, missing => $missing };
	}
	my $started = &subs::rightNow();
	&qa_install_status_write({
		state => 'running',
		started => $started,
		updated => $started,
		missing => $missing,
		steps => [ map { { key => $_->{'key'}, state => 'waiting' } } @{$steps} ],
		log => '',
	});
	my @copy = map { { %{$_} } } @{$steps};
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		&qa_install_execute(\@copy);
	}, { name => 'qa install', fork => 1 });
	return { ok => 1, ready => 0, missing => $missing, steps => $steps, state => 'running', dry_run => 0 };
}

1;
