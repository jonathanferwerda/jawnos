#!/usr/bin/env perl;

use strict;
no warnings;
use IO::Compress::Gzip qw(gzip);
use Data::Dumper;

require "./subroutines.pl";
our $config_file = read_file('./config.json');
our $config = decode_json $config_file;
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);


hook before_dispatch => sub {
	my ($c) = @_;
	# a fresh settings memo for this request (see subroutines::setting_grabber)
	%subs::setting_memo = ();
	$subs::setting_memo_on = 1;
	$c->inactivity_timeout(300); 
	# A handheld's workers grow their Perl heap over uptime until Android's
	# low-memory killer reaps the tree. Log each worker's own RSS with its
	# PURPOSE (readable only from inside the process) once every few minutes,
	# so the worker that grows can be named rather than guessed.
	if (&subs::device_setter() eq 'mobile') {
		my $now = &subs::rightNow();
		if (!defined $subs::worker_mem_at || $now - $subs::worker_mem_at > 60000) {
			$subs::worker_mem_at = $now;
			my $pid = $$;
			my $status = eval { read_file("/proc/$pid/status") } || '';
			my ($rss) = $status =~ /VmRSS:\s+(\d+)/;
			$log->info('worker mem purpose=' . ($ENV{PURPOSE} || '?') . " pid=$pid rss=" . (defined $rss ? $rss : '?') . 'kB');
		}
	}
	my $path = $c->req->url->path;
	# A relayed request carries a relay_id. If this machine has already handled
	# that id, the copy arrived via another path through the mesh: acknowledge it
	# and stop here, before the route handler can apply the change a second time.
	if ($c->param('relay_id') && !&subs::relay_fresh($c->param('relay_id'))) {
		$c->render(text => 'ok');
		return;
	}
	my $port = $c->req->url->base->port;
	my $local_address = $c->tx->local_address;
	my $remote_address = $c->tx->remote_address;
	my $domain = $c->req->url->to_abs->host;

	if ($domain =~ /[a-zA-Z]/gi && $domain ne $config->{'domain'}) {
	}

	if ($local_address ne $remote_address) {

	}

	$c->session('reject_count', 0) unless $c->session('reject_count');
	if ($gb::database_holder->{'db'} && $local_address ne $remote_address) {
	#	my $nl = &subs::db_query('select * from neighbour_link where initiator=? and initiated=? order by server_time desc limit 1', $remote_address, $local_address)->hashes;
		if ($c->param('my_name') && $c->param('signatorial')) {
		#	my $nlrq = $c->render_to_string(
		#		template => 'configure/neighbour_link_request',
		#		local_address => $local_address,
		#		remote_address => $remote_address,
		#		my_name => $c->param('my_name'),
		#		signatorial => $c->param('signatorial')
		#	);
			#$c->render(template => 'guest_layouts/pending', message => '... hold on!');
			#$c->session('authentication' => 'pending');
			#$c->rendered;
			#}
	#		&Websocket::send('server', { alert => $nlrq });
		}

	}
	# A denial session - or one carrying a blacklisted privilege, however it was
	# minted - is refused every path, public pages and static assets included.
	if ($c->session('authentication') eq 'denial' || $c->session('privilege') eq 'blacklisted') {
		my $denial = $c->render(template => 'guest_layouts/denial', message => '... access denied.');
		$c->session('authentication' => 'denial');
		$c->rendered;
		return;
	#	$c->continue;		
	}
	if ($c->session('authentication') ne 'approved') {
		my $total_upload = 0;
		my @uploads = @{$c->req->uploads};
		foreach my $u ( @uploads ) {
			$total_upload += $u->size;
		}
		if ($total_upload > 10000000 || $c->session('authentication') eq 'denied') {
			$c->stash('no' => 1);
			my $denial = $c->render(template => 'guest_layouts/denial', message => '... access denied.');
			$c->session('authentication' => 'denied');
			&subs::say_it('Upload denied');
			$c->rendered;
		}
	}


#	&subs::log_writer($remote_address . ' ' . $path);


	my $allowances = {
		guest => [
			'/js/mailbox.js',
			'/',
			'/js/jquery-ui.js',
			'/js/jquery.ui.touch-punch.min.js',
			'/js/universal.js',
			'/js/homepage.js',
			'/js/jquery.js',
			'/js/numeral.min.js',
			'/mail/ws',
			'/mail/homepage_form'
		],
		resident => [
			'manager'
		],
		citizen => [
			'/configure',
			'/security',
			'/manager/magazine/publish',
		]
	};


	#if ($port eq $ENV{PORT_MAIN} && ($path ne '/') && $path !~ /^\/images\/jbuttons/ && $path ne '/css/store.css' && $path ne '/css/universal.css' && $path ne '/images/decipherable/envelope.png' && $path ne "/images/decipherable/gift.png" && $path ne '/payment' && $path ne '/play' && $path ne '/images/make%20believe/cancel_button.png'  && $path ne '/box_office/ticket_request') {
	#	$c->stash('no' => 1);
	#}
	if ($c->session('authentication') ne 'approved' && $ENV{PURPOSE} eq 'locker' && 
			$path ne '/css/store.css' && 
			$path ne '/public_view' && 
			$path ne '/css/universal.css' && 
			$path ne '/manifest.json' &&
			$path ne '/denial' && 
			$path !~ /^\/images\/jbuttons/ && 
			# the gate's own pictures resolve through the selected icon set (and the
			# hand-drawn originals for the handdrawn set); these are drawn icons, no
			# more personal than the gate's own frame
			$path !~ m{^/icons/(?:sets|original)/} &&
			$path ne '/manager/gate' && 
			$path ne '/manager/say_it' && 
			$path ne '/images/decipherable/envelope.png' && 
			$path ne "/images/decipherable/gift.png" && 
			$path ne '/images/make%20believe/cancel_button.png' && 
			$path ne '/payment' && 
			$path ne '/play' && 
			$path ne '/box_office/ticket_request') {
		$c->stash('no' => 1);
	}

	my $privilege = $c->session('privilege');
	my @a_loud_thing;
	if ($privilege) {
		if ((@a_loud_thing = grep { $path =~ $_ } @{$allowances->{'citizen'}}) && $privilege ne 'citizen') {
			if (scalar @a_loud_thing == 0) {
				$c->stash('no' => 1);
			}
		}
		elsif ((@a_loud_thing = grep { $path =~ $_ } @{$allowances->{'resident'}}) && ($privilege ne 'citizen' && $privilege ne 'resident')) {
			if (scalar @a_loud_thing == 0) {
				$c->stash('no' => 1);
			}
		}
		elsif ((@a_loud_thing = grep { $path eq $_ } @{$allowances->{'guest'}}) && ($privilege ne 'citizen' && $privilege ne 'resident' && $privilege eq 'guest')) {
			if (scalar @a_loud_thing == 0) {
				$c->stash('no' => 1);
			}
		}
	}

	my $ug = Data::UUID->new;
	unless ($c->param('browser_tab_id') || $c->session('browser_tab_id')) {
		my $uuid = $ug->create_str();
		$c->stash('browser_tab_id' => $uuid );
		$c->session('browser_tab_id' => $uuid );
		$c->stash('website' => '');
	}
	else {
		my $uuid = $ug->create_str();
		$c->stash('browser_tab_id' => $c->session('browser_tab_id'));
		$c->session('browser_tab_id' => $uuid);
	}

	unless ($c->param('browser_tab')) {
		my $uuid = $ug->create_str();
		$c->stash('browser_tab' => $uuid );
		$c->session('browser_tab' => $uuid );
	}
	else {
		$c->stash('browser_tab' => '2');
	}

	unless ($path eq '/icons/logos/WelcomeLogo.png' || 
		$path eq "/image/make%20believe/crown.png" ||
		$path eq "/images/make%20believe/lock.png" ||
		$path eq '/images/make%20believe/cancel_button.png' ||
		$path eq "/images/make%20believe/up.png" ||
		$path eq "/images/decipherable/gift.png" ||
		$path eq "/images/decipherable/envelope.png" ||
		# the gate wears the selected icon set's welcome picture and its upload arrow,
		# or the hand-drawn originals when that set is chosen
		$path =~ m{^/icons/(?:sets|original)/} ||
		$path =~ '^/images/jbuttons' ||
		$path eq '/sesh_check' || 
		$path eq '/gate' ||
		$path eq '/js/gate.js' ||
		$path eq '/js/jquery.js' ||
		$path eq '/js/numeral.min.js' ||
		$path eq '/js/universal.js' ||
		$path eq '/manifest.json' ||
		# the service worker script is fetched with no session cookie (the
		# register fetch is not a document request), so gating it would answer
		# with the gate AND revoke the session, logging the page straight out
		$path eq '/service_worker.js' ||
		$path eq '/css/universal.css' ||
		$path eq '/css/store.css' ||
		$path eq '/js/homepage.js' ||
		$path eq '/teletype/information' ||
		$path =~ '^/box_office' ||
		$path eq '/denial' ||
		$path eq '/js/jquery.ui.touch-punch.min.js' ||
		$path eq '/play' || $path eq '/file_open' ||
		# the tunnel websocket authorizes itself (signatorial vs remote_machines)
		# and a websocket upgrade cannot carry the gate's session or ws_auth
		$path eq '/manager/tunnel/ws' ||
		$path eq '/payment' ||
		$path eq '/box_office/ticket_request' ||
		# a machine logs itself in before it has a session, and the script that
		# does it must load on the gate (the routes check the roster themselves)
		$path =~ '^/manager/device' ||
		$path eq '/js/device.js' ||
		# a machine with no session and no key asks a linked machine for the house
		# key; the route authenticates by peer signature and pinned key itself
		$path eq '/manager/vault_share' ||
		# the same bare signed rail carries a rotated key push and the old-seal
		# sweep between linked machines, and neither of those has a session either
		# (key_push_one and legacy_reseal_peer_one send no cookie) - peer_verify is
		# the gate on both routes, exactly as it is on vault_share
		$path eq '/manager/key_push' ||
		$path eq '/manager/legacy_reseal' ||
		# the handshake at the head of the peer rail: it authenticates by signature
		# against the roster (peer_verify), so a peer whose session cookie has
		# lapsed can still handshake and reconnect
		$path eq '/manager/remote_auth_test' ||
		# the tunnel liveness ping rides the same bare signed rail, and the hub's
		# reply to it (the peer's remote_auth_test callback) is the same handshake -
		# so a tunnelled peer whose session lapsed must still reach it. The route
		# peer_verifies the sig against the roster itself (see Manager.pl).
		$path eq '/manager/tunnel/alive' ||
		# the sync rail: a peer asks this machine for a backup (backup_now), pulls
		# its archive (backup_serve) and confirms it (backup/confirm) over the same
		# bare signed rail. The session cookie these once relied on lapses, and a
		# gated reply - the Gate page, not JSON - silently stalled the merge (the
		# decode failed and the pull did nothing), which is how a machine fell
		# behind. The routes take a session OR a peer signature (see Manager.pl).
		$path eq '/manager/configure/backup_now' ||
		$path eq '/manager/backup_serve' ||
		$path eq '/manager/backup/confirm' ||
		# the ticket desk rides the same bare signed rail: a linked machine reads
		# the desk from, or answers a request held on, a neighbour's database, so
		# its routes take a session OR a peer signature. Each checks the roster and
		# the pinned key itself (Manager::ticket_desk_allowed), so the gate here is
		# skipped only to let a sessionless peer reach that check.
		$path eq '/manager/box_office' ||
		$path eq '/manager/box_office/approve' ||
		$path eq '/manager/box_office/decline' ||
		$path eq '/manager/box_office/blacklist' ||
		$path eq '/manager/box_office/blacklist/remove' ||
		$path eq '/manager/box_office/policy' ||
		$path eq '/manager/qrcode_generator' ||
		$path eq '/manager/ticket_privilege' ||
		$path eq '/manager/delete_ticket' ||
		$path eq '/manager/suspend_ticket' ||
		$path eq '/manager/renew_ticket' ||
		$path eq '/manager/reinstate_ticket' ||
		# the homepage shows the mugshot to visitors, so it is served without a login
		$path eq '/mugshot' ||
		$path =~ '^/public_view' ||
		$path eq '/', ) {

		my $device = &subs::device_setter();
		$Manager::random_caching_string = &subs::jawn_version();
		$c->stash('device' => $device);
		$c->stash('string' => $Manager::random_caching_string);
		if ($c->param('ws_auth') && $remote_address ne $local_address) {
			my $success = 0;
			my $wsa = $c->param('ws_auth');
			my $pa = &subs::setting_grabber({ app => '__president', setting => 'ws_pa' });
			my @ws_auth = split $gb::universal_splitter, &subs::decrypter($pa, $wsa);
			if ($remote_address eq $ws_auth[0] && $ws_auth[1] eq &subs::signatorial_designer()) {
					$c->session('authentication' => 'approved');
				#	$c->session('suds' => $c->param('suds'));
				#	$c->session('server_time' => &subs::rightNow());
					$success = 1;
			}
			if ($success == 0) {
				&authentication_passer($c)
			}

		}
		else {
			my $man = &authentication_passer($c);
		}

	}
};

hook before_render => sub {
	my ($c, $args) = @_;
	no warnings 'uninitialized';
};

hook after_render => sub  {
	my ($c, $output, $format) = @_;
  # Check if "gzip => 1" has been set in the stash
  return unless $c->stash->{gzip};

  # Check if user agent accepts gzip compression
  return unless ($c->req->headers->accept_encoding // '') =~ /gzip/i;
  $c->res->headers->append(Vary => 'Accept-Encoding');

  # Compress content with gzip
  $c->res->headers->content_encoding('gzip');

  gzip $output, \my $compressed;
  	$$output = $compressed;

  };

  # gzip text-ish responses on the way out. This is the one chokepoint that sees
  # both static assets (Mojolicious::Static calls $c->rendered, so after_dispatch
  # fires for them too) and dynamic responses. Binary hazards are avoided two ways:
  # an allowlist of compressible content types, and a skip for /file_open, where
  # rock_and_roll serves raw image/video/relay bytes under the default text/html.
  # A body already carrying a Content-Encoding (the after_render hook above) is
  # left alone, so the two never double-encode.
  hook after_dispatch => sub {
  	my ($c) = @_;
  	my $res = $c->res;

  	return unless ($res->code // 0) == 200;
  	return if $res->headers->content_encoding;
  	return if $c->req->headers->range;
  	return unless (($c->req->method // '') =~ /^(?:GET|HEAD)$/);
  	return unless (($c->req->headers->accept_encoding // '') =~ /\bgzip\b/i);

  	my $type = lc($res->headers->content_type // '');
  	return unless $type =~ m{^text/(?:html|css|plain|xml|javascript)|^application/(?:json|javascript|xml)|^image/svg\+xml};

  	return if ($c->req->url->path->to_string // '') eq '/file_open';

  	my $body = $res->body;
  	return unless defined $body && !ref $body && length($body) >= 512;

  	gzip \$body, \my $gz;
  	return unless defined $gz && length($gz) && length($gz) < length($body);

  	$res->headers->content_encoding('gzip');
  	$res->headers->append(Vary => 'Accept-Encoding');
  	$res->headers->remove('Accept-Ranges');
  	$res->body($gz);
  	$res->headers->content_length(length $gz);
  };

  # A static asset fetched without a session - WebKit fetches the service-worker
  # script cookielessly, and any cookieless <img>/<link> does it too - used to
  # make the session hooks mint a brand-new session and set it on the response,
  # overwriting the browser's authenticated cookie, so the page was logged out on
  # its very next request. Static assets never need a session, so drop the cookie
  # they would set. A request that did carry a session keeps its refresh. This
  # runs around the dispatch because Mojolicious stores the session cookie after
  # the after_dispatch hooks, so it cannot be undone from one of those.
  hook around_dispatch => sub {
  	my ($next, $c) = @_;
  	$next->();
  	my $path = $c->req->url->path->to_string // '';
  	return unless $path =~ m{^/(?:js|css|images|icons|sounds)/}
  		|| $path eq '/manifest.json'
  		|| $path eq '/service_worker.js';
  	return if $c->req->cookie($ENV{cookie_name} || 'president');
  	$c->res->headers->remove('Set-Cookie');
  };

  # The settings memo lives for one request only.
  hook after_dispatch => sub {
  	%subs::setting_memo = ();
  	$subs::setting_memo_on = 0;
  };

  hook after_dispatch => sub {
  	my ($c) = @_;
  	if ($c->res->code == 500) {

		# a request that died before any log line was recorded has no history to
		# walk: that is a missing record, not a reason to take the tree down with it
		my $history = eval { $c->stash('mojo.log')->{'parent'}->{'history'} } || [];
		foreach my $h (reverse sort @{$history} ) {
			if (eval { $h->[3]->{'message'} }) {
				my $errors = eval { decode_json &subs::setting_grabber({ app => 'terminal', setting => 'errors' }) } || [];
				my $uuid = &subs::random_string_creator(12);
				my $error = { timestamp => &subs::rightNow, code => $c->res->code, msg => $c->req->url->path . '<br>' . $h->[3]->{'message'}, uuid => $uuid };
				push @{$errors}, $error;
				my $jerror = encode_json $errors;

				&subs::setting_setter({ app => 'terminal', setting => 'errors', value => $jerror });
				&Websocket::send('server', { view => 'errors', console => $error, error => $uuid });
			}
		}
	}
};
1;