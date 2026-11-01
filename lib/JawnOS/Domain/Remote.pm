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
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Util qw(url_escape b64_decode b64_encode);

# File-scope state owned by subroutines.pl, in this same package.
our $config;
our $device;
our $log;
our $logfile;

sub remote_relay_request($c, $extra_params = {}) {
	unless ($c->param('remoted') eq 'yes') {
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
				if ($extra_params->{'override'} eq 'manual') {
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
						$params .= '&' . $ep . '=' . $extra_params->{$ep};
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
						$params .= '&' . $ep . '=' . $extra_params->{$ep};
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

sub remote_useragent_maker($data) {
	my $ip = $data->{'ip'};
	my $signatorial = $data->{'signatorial'};
	my $rm = $data->{'rm'};
	my $uuid = $data->{'uuid'};
	my $auth_test = $data->{'auth_test'};
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
	my $port_dock = $rm->{'port_dock'} || 3000;
	my $port = $rm->{'port'};

	my $manager = $rm->{'manager'};
	# A retired tunnel leaves 127.0.0.1 behind, and a name is the only route
	# left. Resolve it before the cookie is scoped and every url is built.
	my $live_manager = &subs::peer_live_manager($rm);
	if (($manager || '') ne $live_manager) {
		$manager = $live_manager;
		$rm->{'manager'} = $manager;
	}
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
		$rm->{'ua'}->insecure(1);
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
			my $res = eval { return $rm->{'ua'}->insecure(1)->get($url => {Accept => '*/*'} => 'Content!')->result };
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
		$rm->{'ua'}->insecure(1);
		$rm->{'ua'}->inactivity_timeout(60);
	}
	$rm->{'data'} = eval { return decode_json $rm->{'data'} };

	return $rm;
}

1;
