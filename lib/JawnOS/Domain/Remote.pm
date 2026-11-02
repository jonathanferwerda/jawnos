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

# ---------------------------------------------------------------------------
# QA nightly target
# ---------------------------------------------------------------------------
# Configure -> Plat -> QA names the one machine that runs the nightly suite.
# The choice is a house setting (`__president/qa_nightly_device`, device 'all'):
# the signatorial of a computer or server, or '' for the local fallback. The
# nightly's systemd unit reads the same rows through qa/device_target.pl, so the
# panel and the timer can never disagree about which machine runs.

# Where a tool is, without shelling out: PATH is enough, and a name is never
# passed to a shell.
sub qa_which {
	my ($name) = @_;
	return '' unless defined $name && length $name;
	return $name if $name =~ m{/} && -x $name;
	foreach my $dir ( split /:/, ($ENV{'PATH'} || '/usr/local/bin:/usr/bin:/bin') ) {
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
	my $target = &qa_target_lookup($signatorial, $opts);
	return { ok => 0, error => 'not an eligible device (computer or server only)' } unless $target;
	return { ok => 1, target => $target };
}

# A stored choice is a signatorial (hex) or '' for the local fallback. Anything
# else is treated as no choice at all, never handed to a path or a query.
sub qa_nightly_clean {
	my ($value) = @_;
	return '' unless defined $value;
	$value =~ s/^\s+//;
	$value =~ s/\s+$//;
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
sub qa_readiness_for {
	my ($signatorial, $opts) = @_;
	$opts ||= {};
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
	my $body = ($res && $res->is_success) ? eval { decode_json $res->body } : undef;
	return $body if ref $body eq 'HASH';
	return { ok => 0, error => 'that machine did not answer the readiness check', target => $target->{'signatorial'} };
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
