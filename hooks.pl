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
	$c->inactivity_timeout(300); 
	my $path = $c->req->url->path;
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
	if ($c->session('authentication') eq 'denial') {
		my $denial = $c->render(template => 'guest_layouts/denial', message => '... and fuck you too!');
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
		if ($total_upload > 10000000 || $c->session('authentication') eq 'fuck you') {
			$c->stash('no' => 1);
			my $denial = $c->render(template => 'guest_layouts/denial', message => '... and fuck you too!');
			$c->session('authentication' => 'fuck you');
			&subs::say_it('fuck you! time consumer');
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

	unless ($c->param('browser_tab_id') || $c->session('browser_tab_id')) {
		my $ug    = Data::UUID->new;
		my $uuid = $ug->create_str();
		$c->stash('browser_tab_id' => $uuid );
		$c->session('browser_tab_id' => $uuid );
		$c->stash('website' => '');
	}
	else {
		my $ug    = Data::UUID->new;
		my $uuid = $ug->create_str();
		$c->stash('browser_tab_id' => $c->session('browser_tab_id'));
		$c->session('browser_tab_id' => $uuid);
	}

	unless ($c->param('browser_tab')) {
		my $ug    = Data::UUID->new;
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
		$path =~ '^/images/jbuttons' ||
		$path eq '/sesh_check' || 
		$path eq '/gate' ||
		$path eq '/js/gate.js' ||
		$path eq '/js/jquery.js' ||
		$path eq '/js/numeral.min.js' ||
		$path eq '/js/universal.js' ||
		$path eq '/manifest.json' ||
		$path eq '/css/universal.css' ||
		$path eq '/css/store.css' ||
		$path eq '/js/homepage.js' ||
		$path eq '/teletype/information' ||
		$path =~ '^/box_office' ||
		$path eq '/denial' ||
		$path eq '/js/jquery.ui.touch-punch.min.js' ||
		$path eq '/play' || $path eq '/file_open' ||
		$path eq '/payment' ||
		$path eq '/box_office/ticket_request' ||
		$path =~ '^/public_view' ||
		$path eq '/', ) {

		my $device = &subs::device_setter();
		$Manager::random_caching_string = &subs::newest_folder_checker();
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

hook after_dispatch => sub {
	my ($c) = @_;
	if ($c->res->code == 500) {

		foreach my $h (reverse sort @{$c->stash('mojo.log')->{'parent'}->{'history'}} ) {
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