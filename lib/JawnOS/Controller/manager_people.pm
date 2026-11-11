package Manager;

# manager_people: route actions moved out of Manager.pl, one sub per route so a
# route can be read and changed without opening the whole file. The package
# is still Manager, so unqualified calls to its helpers and its package
# state work exactly as they did in the single file.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use strict;
use warnings ;#'uninitialized';
use Mojo::Promise;
use Mojo::UserAgent;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Clone qw(clone);
use Mojolicious::Static;
use Mojo::Log;
use Mojo::Transaction::WebSocket;
use Mojo::Parameters;
use Mojo::DOM;
use Mojo::URL;
use Mojo::JSON qw(decode_json encode_json);
use URI::Encode qw(uri_encode uri_decode);
use List::Util qw(shuffle);
use Data::Dumper;
use Mojo::Util qw/md5_sum html_unescape xml_escape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use File::Find;
use File::Slurp;
use File::Type;
use File::Copy;
use POSIX ();
use Fcntl qw(:flock O_CREAT O_EXCL O_WRONLY);
use Number::Format qw/:subs/;
use SQL::Abstract;
use Mojo::SQLite;
use Mojo::IOLoop;

use Mojolicious::Sessions;
use Mojo::Server::Daemon;
use Mojolicious::Renderer;
use Crypt::Simple;
use CryptX;
use HTML::Strip;
use HTML::Parser;
use Data::UUID;
use Storable;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use MIME::Base64;
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
use Minion;

use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

# GET /manager/people
sub action_23753 {
	my $c = shift;
	unless (&people_citizen($c)) { $c->render(text => ''); return; }
	&subs::crest_image_sync_seed($c);
	&subs::crest_image_materialize($c);
	my $crest = &subs::crest_record_read();
	my $has_image = ($crest->{'uuid'} && &subs::crest_image_file($crest, 'image')) ? 1 : 0;
	my $peer_list = &subs::crest_peer_list_read();
	my @peers;
	foreach my $entry ( @{$peer_list} ) {
		next unless ref $entry eq 'HASH' && ref $entry->{'crest'} eq 'HASH';
		my $incoming = $entry->{'crest'};
		next unless ($incoming->{'uuid'} || '') ne '';
		my $view = {
			uuid => $incoming->{'uuid'},
			crest => $incoming,
			name => $incoming->{'name'} || '',
			fingerprint => $incoming->{'fingerprint'} || '',
			has_image => ((defined $entry->{'image_data'} && length $entry->{'image_data'}) || &subs::crest_peer_image_file($entry)) ? 1 : 0,
			image_src => (defined $entry->{'image_data'} && length $entry->{'image_data'}) ? $entry->{'image_data'} : (&subs::crest_peer_image_file($entry) ? '/manager/people/crest_image?peer=' . $incoming->{'uuid'} . '&stamp=' . &subs::rightNow() : ''),
			met => 0,
			met_at => '',
			introduced_by => '',
		};
		if (ref $entry->{'vouch'} eq 'HASH'
			&& &subs::crest_vouch_verify($entry->{'vouch'})
			&& ($entry->{'vouch'}->{'from_uuid'} || '') eq ($crest->{'uuid'} || '')
			&& ($entry->{'vouch'}->{'to_uuid'} || '') eq $incoming->{'uuid'}
			&& ($entry->{'vouch'}->{'to_pubkey'} || '') eq ($incoming->{'pubkey'} || '')) {
			$view->{'met'} = 1;
			$view->{'met_at'} = $entry->{'vouch'}->{'at'} || $entry->{'met_at'} || '';
		}
		foreach my $vouch ( @{ $entry->{'vouches'} || [] } ) {
			next unless ref $vouch eq 'HASH';
			next unless ($vouch->{'to_uuid'} || '') eq $incoming->{'uuid'};
			next unless ($vouch->{'to_pubkey'} || '') eq ($incoming->{'pubkey'} || '');
			my $issuer = &subs::crest_vouch_introducer($vouch, $crest, $peer_list);
			next unless $issuer;
			next if ($issuer->{'uuid'} || '') eq ($crest->{'uuid'} || '');
			$view->{'introduced_by'} = $issuer->{'name'} || '';
			last;
		}
		push @peers, $view;
	}
	@peers = sort { lc($a->{'name'} || '') cmp lc($b->{'name'} || '') } @peers;
	my $crest_introduced_by = '';
	foreach my $vouch ( @{ &subs::crest_incoming_vouch_list_read() } ) {
		next unless ref $vouch eq 'HASH';
		next unless ($vouch->{'to_uuid'} || '') eq ($crest->{'uuid'} || '');
		next unless ($vouch->{'to_pubkey'} || '') eq ($crest->{'pubkey'} || '');
		my $issuer = &subs::crest_vouch_introducer($vouch, $crest, $peer_list);
		next unless $issuer;
		next if ($issuer->{'uuid'} || '') eq ($crest->{'uuid'} || '');
		$crest_introduced_by = $issuer->{'name'} || '';
		last;
	}
	my $index = &people_link_sync();
	my $backers = &subs::crest_member_cosig_list($crest);
	my %person_app = map { $_ => 1 } @{ $index->{'person_apps'} };
	my $people_rows = eval { &subs::db_select('people', undef, { status => 'active' })->hashes } || [];
	my @people;
	my %seen_person_app;
	foreach my $person ( @{$people_rows} ) {
		my $app = $person->{'app'} // '';
		next unless length $app;
		next unless $person_app{$app};
		# two machines can mint a row for the same construct before they sync;
		# the window shows the person once
		next if $seen_person_app{$app}++;
		$person->{'chips'} = &people_chips($index, $app);
		$person->{'image'} = &people_crest_image($app);
		$person->{'formatted_name'} = &subs::format_name($app);
		$person->{'relationship'} = &subs::person_relationship_value($app);
		$person->{'relationship_rating'} = &subs::relationship_rating($person->{'relationship'});
		push @people, $person;
	}
	@people = sort { lc($a->{'name'} || '') cmp lc($b->{'name'} || '') } @people;
	my %people_by_app = map { ($_->{'app'} || '') => ($_->{'uuid'} || '') } @people;
	# the words the Guide already knows this construct by, shown as chips on its
	# row; a foreign construct's names are its own house's, so it gets none
	my $aka_by_app = &guide_aka_read();
	foreach my $construct ( @{ $index->{'constructs'} } ) {
		foreach my $row ( @{ $construct->{'rows'} } ) {
			$row->{'aka'} = $row->{'foreign'} ? [] : [ @{ $aka_by_app->{ $row->{'app'} } || [] } ];
			$row->{'image'} = &people_crest_image($row->{'app'});
			$row->{'public'} = $row->{'foreign'} ? 0 : &people_construct_public($row->{'app'});
			$row->{'crest_uuid'} = '';
			$row->{'crest_image'} = '';
			unless ($row->{'foreign'}) {
				my $construct_crest = &subs::construct_crest_record_read($row->{'app'});
				if ($construct_crest->{'uuid'}) {
					&subs::construct_crest_image_materialize($c, $row->{'app'});
					$row->{'crest_uuid'} = $construct_crest->{'uuid'};
					$row->{'crest_image'} = &subs::construct_crest_image_src($row->{'app'});
				}
			}
			foreach my $member ( @{ $row->{'members'} } ) {
				$member->{'image'} = &people_crest_image($member->{'app'});
				$member->{'uuid'} = $people_by_app{$member->{'app'}} || '';
			}
		}
	}
	my $feeds = &market_scan_feeds();
	my $scanner = (grep { $_ eq 'flatbed' } @{ $feeds || [] }) ? 1 : 0;
	my $camera = 0;
	if (&subs::device_setter() eq 'mobile' && grep { defined $_ && $_ =~ /^[01]$/ } @{ $gb::capabilities->{'mobile'}->{'camera'} || [] }) {
		$camera = 1;
	}
	my $nfc = (&subs::device_setter() eq 'mobile') ? 1 : 0;
	my $content = $c->render_to_string(
		template => 'apps/people',
		crest => $crest,
		has_image => $has_image,
		introduced_by => $crest_introduced_by,
		peers => \@peers,
		people => \@people,
		backers => $backers,
		constructs => $index->{'constructs'},
		scanner => $scanner,
		camera => $camera,
		nfc => $nfc,
		device => &subs::device_setter(),
	);
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'people', title => &subs::lang('people'), contents => $content }, $c->param('timestamp'));
	$c->render(text => $contents);
}

# GET /manager/people/crest/detail
sub action_23879 {
	my $c = shift;
	unless (&people_citizen($c)) { return $c->render(json => { ok => 0, error => 'citizen only' }); }
	my $uuid = $c->param('uuid') || '';
	my $entry = &subs::crest_peer_find($uuid);
	return $c->render(json => { ok => 0, error => 'no such crest' }) unless $entry;
	my $incoming = $entry->{'crest'} || {};
	my $own = &subs::crest_record_read();
	my $peer_list = &subs::crest_peer_list_read();
	my $met = 0;
	my $met_at = '';
	if (ref $entry->{'vouch'} eq 'HASH'
		&& &subs::crest_vouch_verify($entry->{'vouch'})
		&& ($entry->{'vouch'}->{'from_uuid'} || '') eq ($own->{'uuid'} || '')
		&& ($entry->{'vouch'}->{'to_uuid'} || '') eq ($incoming->{'uuid'} || '')
		&& ($entry->{'vouch'}->{'to_pubkey'} || '') eq ($incoming->{'pubkey'} || '')) {
		$met = 1;
		$met_at = $entry->{'vouch'}->{'at'} || $entry->{'met_at'} || '';
	}
	my $introduced_by = '';
	foreach my $vouch ( @{ $entry->{'vouches'} || [] } ) {
		next unless ref $vouch eq 'HASH';
		next unless ($vouch->{'to_uuid'} || '') eq ($incoming->{'uuid'} || '');
		next unless ($vouch->{'to_pubkey'} || '') eq ($incoming->{'pubkey'} || '');
		my $issuer = &subs::crest_vouch_introducer($vouch, $own, $peer_list);
		next unless $issuer;
		next if ($issuer->{'uuid'} || '') eq ($own->{'uuid'} || '');
		$introduced_by = $issuer->{'name'} || '';
		last;
	}
	my $endpoints = ref $entry->{'endpoints'} eq 'HASH' ? $entry->{'endpoints'} : {};
	my $linked_app = &subs::crest_contact_app_for_uuid($uuid);
	my %apps;
	foreach my $kind ( qw/phone email/ ) {
		my $lines = eval { &subs::contact_lines($kind) } || {};
		foreach my $app ( keys %{$lines} ) {
			my @lines = @{ $lines->{$app} || [] };
			$apps{$app} ||= { app => $app, name => &subs::format_name($app), phone => '', email => '' };
			$apps{$app}->{'phone'} = $lines[0]->{'value'} || '' if $kind eq 'phone' && @lines;
			$apps{$app}->{'email'} = $lines[0]->{'value'} || '' if $kind eq 'email' && @lines;
		}
	}
	my @contacts = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } values %apps;
	my $tickets = eval { &subs::db_query('select name from tickets')->hashes } || [];
	foreach my $ticket ( @{$tickets} ) {
		my $app = &subs::unformat_name($ticket->{'name'} || '');
		next unless length $app;
		$apps{$app} ||= { app => $app, name => &subs::format_name($app), phone => '', email => '' };
	}
	@contacts = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } values %apps;
	if ($linked_app && !$apps{$linked_app}) {
		foreach my $key ( keys %apps ) {
			if (lc($key) eq lc($linked_app)) { $linked_app = $key; last; }
		}
	}
	my $contact = ($linked_app && $apps{$linked_app}) ? $apps{$linked_app} : undef;
	my $has_image = ((defined $entry->{'image_data'} && length $entry->{'image_data'}) || &subs::crest_peer_image_file($entry)) ? 1 : 0;
	my $image_src = (defined $entry->{'image_data'} && length $entry->{'image_data'})
		? $entry->{'image_data'}
		: ($has_image ? '/manager/people/crest_image?peer=' . $uuid . '&stamp=' . &subs::rightNow() : '');
	# A stored row may predate the import check; the panel opens these in a tab,
	# so answer only with an http(s) URL.
	my $endpoint_url = sub {
		my ($url) = @_;
		(my $clean = defined $url ? $url : '') =~ s/^\s+|\s+$//g;
		return $clean =~ m{^https?://}i ? $clean : '';
	};
	return $c->render(json => {
		ok => 1,
		uuid => $uuid,
		name => $incoming->{'name'} || '',
		fingerprint => $incoming->{'fingerprint'} || '',
		met => $met ? 1 : 0,
		met_at => $met_at,
		introduced_by => $introduced_by,
		status => $met ? 'Met in person' : ($introduced_by ? 'Introduced by ' . $introduced_by : 'Imported, not met'),
		image => $image_src,
		origin => &subs::crest_entry_origin($entry),
		profile => (ref $entry->{'profile'} eq 'HASH' ? $entry->{'profile'} : undef),
		home => $endpoint_url->($endpoints->{'home'}),
		store => $endpoint_url->($endpoints->{'store'}),
		manager => $endpoints->{'manager'} || '',
		linked_app => $linked_app,
		contact => $contact,
		contacts => \@contacts,
	});
}

# POST /manager/people/crest/lookup
sub action_23959 {
	my $c = shift;
	unless (&people_citizen($c)) { return $c->render(json => { ok => 0, error => 'citizen only' }); }
	my $uuid = $c->param('uuid') || '';
	unless ($uuid =~ /^[A-Za-z0-9_-]{8,64}$/) { return $c->render(json => { ok => 0, error => 'no such crest' }); }
	my $entry = &subs::crest_peer_find($uuid);
	return $c->render(json => { ok => 0, error => 'no such crest' }) unless $entry;
	my $origin = &subs::crest_entry_origin($entry);
	unless (length $origin) {
		return $c->render(json => { ok => 0, error => 'this crest does not say where its house can be reached' });
	}
	my $own = &subs::crest_record_read();
	my $suds = &subs::session_suds($c);
	my $priv = $suds ? &subs::crest_key_read($suds) : undef;
	unless ($own->{'uuid'} && defined $priv && length $priv == 32) {
		return $c->render(json => { ok => 0, error => 'this house has no crest to present' });
	}
	my $code = &subs::crest_code_build($own, $priv);
	unless ($code) { return $c->render(json => { ok => 0, error => 'the crest code could not be made' }); }
	my $url = $origin . '/crest/' . $uuid . '/profile';
	my $ua = Mojo::UserAgent->new(connect_timeout => 5, inactivity_timeout => 10, request_timeout => 15);
	$ua->insecure(1);
	my $res = eval { $ua->get($url => form => { code => $code })->result };
	unless ($res) { return $c->render(json => { ok => 0, error => 'the other house did not answer' }); }
	unless ($res->is_success) {
		return $c->render(json => { ok => 0, error => 'the other house refused the lookup (' . $res->code . ')' });
	}
	my $body = eval { decode_json($res->body) } || {};
	my $profile = $body->{'profile'};
	unless (ref $profile eq 'HASH') {
		return $c->render(json => { ok => 0, error => 'the answer was not a crest profile' });
	}
	# The answer must be the crest we hold: same id, same key, and a signature
	# that checks. A host that merely answers the address is not enough.
	my $incoming = ref $entry->{'crest'} eq 'HASH' ? $entry->{'crest'} : {};
	unless (($profile->{'uuid'} || '') eq $uuid
		&& ($profile->{'pubkey'} || '') eq ($incoming->{'pubkey'} || '')
		&& &subs::crest_verify_record($profile)) {
		return $c->render(json => { ok => 0, error => 'the answer was not signed by that crest' });
	}
	my @constructs;
	foreach my $construct ( @{ ref $profile->{'constructs'} eq 'ARRAY' ? $profile->{'constructs'} : [] } ) {
		next unless ref $construct eq 'HASH' && length($construct->{'name'} || '');
		push @constructs, {
			type => $construct->{'type'} || '',
			name => $construct->{'name'} || '',
			members => [ map { defined $_ ? "$_" : '' } @{ ref $construct->{'members'} eq 'ARRAY' ? $construct->{'members'} : [] } ],
		};
	}
	my $store = {
		uuid => $profile->{'uuid'},
		name => $profile->{'name'} || '',
		origin => $profile->{'origin'} || $origin,
		issued => $profile->{'issued'} || '',
		at => &subs::rightNow(),
		constructs => \@constructs,
	};
	&subs::crest_peer_update($uuid, { profile => $store, profile_at => &subs::rightNow() });
	return $c->render(json => { ok => 1, profile => $store });
}

# Publishing a construct to other houses is the same per-app public toggle the
# appointment carries, so it is written for this device: the appointment and
# People then agree on the machine the person is using. People reads every
# device's row and consolidates them (newest wins) when it shows the row or
# answers a lookup.
# POST /manager/people/construct/public
sub action_24024 {
	my $c = shift;
	unless (&people_citizen($c)) { return $c->render(json => { ok => 0, error => 'citizen only' }); }
	my $app = $c->param('app') || '';
	my $value = (($c->param('value') || '') eq 'on') ? 'on' : '';
	unless (length $app && &people_construct_kind($app)) {
		return $c->render(json => { ok => 0, error => 'no such construct' });
	}
	&subs::setting_setter({ app => $app, setting => 'public', device => &subs::device_setter(), value => $value });
	return $c->render(json => { ok => 1, app => $app, public => ($value eq 'on' ? 1 : 0) });
}

# GET /manager/people/person
sub action_24073 {
	my $c = shift;
	unless (&people_citizen($c)) { return $c->render(json => { ok => 0, error => 'citizen only' }); }
	my $uuid = $c->param('uuid') || '';
	my $person = eval { &subs::db_select('people', undef, { uuid => $uuid, status => 'active' })->hash };
	return $c->render(json => { ok => 0, error => 'no such person' }) unless $person && length($person->{'app'} || '');
	my $index = &people_link_sync();
	my $app = $person->{'app'};
	my $chips = &people_chips($index, $app);
	my $entry = &subs::crest_contact_entry($app);
	my $crest = {};
	my $crest_uuid = '';
	my $image = '';
	my $home = '';
	my $store = '';
	my $met = 0;
	my $met_at = '';
	my $introduced_by = '';
	if ($entry && ref $entry->{'crest'} eq 'HASH') {
		my $incoming = $entry->{'crest'};
		$crest_uuid = $incoming->{'uuid'} || '';
		$crest = { name => $incoming->{'name'} || '', fingerprint => $incoming->{'fingerprint'} || '' };
		$image = &people_crest_image($app);
		my $endpoints = ref $entry->{'endpoints'} eq 'HASH' ? $entry->{'endpoints'} : {};
		my $endpoint_url = sub {
			my ($url) = @_;
			(my $clean = defined $url ? $url : '') =~ s/^\s+|\s+$//g;
			return $clean =~ m{^https?://}i ? $clean : '';
		};
		$home = $endpoint_url->($endpoints->{'home'});
		$store = $endpoint_url->($endpoints->{'store'});
		my $state = &people_crest_state($entry);
		$met = $state->{'met'};
		$met_at = $state->{'met_at'};
		$introduced_by = $state->{'introduced_by'};
	}
	my ($phone, $email) = ('', '');
	foreach my $kind ( qw/phone email/ ) {
		my $lines = eval { &subs::contact_lines($kind) } || {};
		my $line = $lines->{$app} || $lines->{lc($app)} || [];
		next unless ref $line eq 'ARRAY' && scalar @{$line};
		if ($kind eq 'phone') { $phone = $line->[0]->{'value'} || ''; }
		else { $email = $line->[0]->{'value'} || ''; }
	}
	my @peer_choices;
	foreach my $peer ( @{ &subs::crest_peer_list_read() } ) {
		next unless ref $peer eq 'HASH' && ref $peer->{'crest'} eq 'HASH';
		next unless length($peer->{'crest'}->{'uuid'} || '');
		push @peer_choices, { uuid => $peer->{'crest'}->{'uuid'}, name => $peer->{'crest'}->{'name'} || '' };
	}
	@peer_choices = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @peer_choices;
	my $html = $c->render_to_string(
		template => 'apps/people_person',
		person => $person,
		app => $app,
		relationship => &subs::person_relationship_value($app),
		chips => $chips,
		crest => $crest,
		crest_uuid => $crest_uuid,
		image => $image,
		home => $home,
		store => $store,
		met => $met,
		met_at => $met_at,
		introduced_by => $introduced_by,
		phone => $phone,
		email => $email,
		main_image => &people_main_image($app),
		peer_choices => \@peer_choices,
	);
	$c->render(json => { ok => 1, html => $html });
}

# POST /manager/people/crest/link
sub action_24140 {
	my $c = shift;
	unless (&people_citizen($c)) { return $c->render(json => { ok => 0, error => 'citizen only' }); }
	my $uuid = $c->param('uuid') || '';
	my $app = $c->param('app') // '';
	my $entry = &subs::crest_peer_find($uuid);
	return $c->render(json => { ok => 0, error => 'no such crest' }) unless $entry;
	&subs::crest_contact_link_set($app, $uuid);
	return $c->render(json => { ok => 1 });
}

# GET /manager/people/crest/qr
sub action_24150 {
	my $c = shift;
	unless (&people_citizen($c)) { $c->rendered(403); return; }
	my $suds = &subs::session_suds($c);
	my $app = $c->param('app') || '';
	my $crest = length $app ? &subs::construct_crest_record_read($app) : &subs::crest_record_read();
	unless ($crest->{'uuid'} && $suds) { $c->rendered(404); return; }
	my $priv = &subs::crest_key_read($suds);
	unless ($priv) { return $c->render(json => { ok => 0, error => 'the crest key is not available' }); }
	my $code = &subs::crest_code_build($crest, $priv);
	unless ($code) { return $c->render(json => { ok => 0, error => 'the crest code could not be made' }); }
	my $png = &subs::crest_qr_png($code);
	if (($c->param('format') || '') eq 'json') {
		return $c->render(json => { ok => 1, code => $code, qr => ($png ? 'data:image/png;base64,' . encode_base64($png, '') : '') });
	}
	unless ($png) { $c->rendered(500); return; }
	$c->res->headers->content_type('image/png');
	$c->res->headers->cache_control('private, max-age=60');
	$c->render(data => $png);
}

# GET /manager/people/crest/card
sub action_24224 {
	my $c = shift;
	unless (&people_citizen($c)) { $c->rendered(403); return; }
	my $card = &people_crest_card($c, $c->param('app') || '');
	unless ($card) { $c->rendered(404); return; }
	my $name = $card->{'crest'}->{'name'} || 'crest';
	$name =~ s/[^\w.\-]+/_/g;
	$c->res->headers->content_type('application/json');
	$c->res->headers->content_disposition('attachment; filename="crest-' . $name . '.json"');
	$c->render(data => encode_json($card));
}

# POST /manager/people/crest/card/save
sub action_24235 {
	my $c = shift;
	unless (&people_citizen($c)) { return $c->render(json => { ok => 0, error => 'citizen only' }); }
	my $card = &people_crest_card($c, $c->param('app') || '');
	unless ($card) { return $c->render(json => { ok => 0, error => 'no crest yet' }); }
	my $dir = &subs::home('~/Downloads');
	$dir = &subs::home('~/Documents') unless -d $dir;
	$dir = &subs::home('~') unless -d $dir;
	my $name = $card->{'crest'}->{'name'} || 'crest';
	$name =~ s/[^\w.\-]+/_/g;
	my $path = "$dir/crest-$name.json";
	$path = "$dir/crest-$name-" . &subs::rightNow() . '.json' if -e $path;
	my $ok = eval { write_file($path, encode_json($card)); 1 };
	unless ($ok && -e $path) { return $c->render(json => { ok => 0, error => 'the card could not be written' }); }
	return $c->render(json => { ok => 1, path => $path });
}

# POST /manager/people/crest/scan
sub action_24307 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'citizen only' }) unless &people_citizen($c);
	my $feeds = &market_scan_feeds();
	unless (grep { $_ eq 'flatbed' } @{ $feeds || [] }) {
		return $c->render(json => { ok => 0, error => 'this device has no flatbed scanner' });
	}
	my $base = &people_crest_scan_dir() . '/crest_' . &subs::rightNow();
	my $command = &scanner_scan_command('flatbed', $base);
	unless ($command) {
		return $c->render(json => { ok => 0, error => 'the scanner does not offer the flatbed' });
	}
	`timeout 60 $command 2> $base.log`;
	my @pages = &scanner_page_list($base);
	unless (@pages) {
		my $why = &scanner_log_reason($base . '.log');
		unlink glob("$base*");
		return $c->render(json => { ok => 0, error => 'the scanner produced no page' . ($why ne '' ? ': ' . $why : '') });
	}
	my $result = &people_crest_install($c, $pages[0]);
	unlink @pages;
	unlink $base . '.log';
	return $c->render(json => $result);
}

# POST /manager/people/crest/capture
sub action_24331 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'citizen only' }) unless &people_citizen($c);
	my $camera = $c->param('camera') // '0';
	$camera = '0' unless $camera =~ /^[01]$/;
	my ($file, $ocr) = &take_picture($c, {
		app => 'people',
		camera => $camera,
		timestamp => &subs::rightNow(),
		capture_only => 1,
		no_ocr => 1,
	});
	unless (defined $file && $file ne 'denial' && -e $file) {
		return $c->render(json => { ok => 0, error => (($file || '') eq 'denial') ? 'this device has no camera' : 'the camera did not return a picture' });
	}
	my $result = &people_crest_install($c, $file);
	unlink $file;
	return $c->render(json => $result);
}

# POST /manager/people/crest/upload
sub action_24350 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'citizen only' }) unless &people_citizen($c);
	my ($path, $error) = &people_crest_upload_file($c);
	return $c->render(json => { ok => 0, error => $error }) unless $path;
	my $result = &people_crest_install($c, $path);
	unlink $path;
	return $c->render(json => $result);
}

# POST /manager/people/construct/crest/upload
sub action_24359 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'citizen only' }) unless &people_citizen($c);
	my $app = $c->param('app') || '';
	return $c->render(json => { ok => 0, error => 'no such construct' }) unless &people_construct_kind($app);
	my ($path, $error) = &people_crest_upload_file($c);
	return $c->render(json => { ok => 0, error => $error }) unless $path;
	my $result = &construct_crest_install($c, $path, $app);
	unlink $path;
	return $c->render(json => $result);
}

# POST /manager/people/crest/verify
sub action_24370 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'citizen only' }) unless &people_citizen($c);
	my $record = &subs::crest_record_read();
	return $c->render(json => { ok => 0, error => 'no crest yet' }) unless $record->{'uuid'};
	my ($path, $error) = &people_crest_upload_file($c);
	return $c->render(json => { ok => 0, error => $error }) unless $path;
	my $ref = $path . '.ref.png';
	unless (&subs::crest_normalize_image($path, $ref)) {
		unlink $path; unlink $ref;
		return $c->render(json => { ok => 0, error => 'the picture could not be read' });
	}
	my $dhash = &subs::crest_dhash($ref);
	my $distance = &subs::crest_hamming($record->{'dhash'}, $dhash);
	unlink $path; unlink $ref;
	unless (defined $distance) {
		return $c->render(json => { ok => 0, error => 'the picture could not be compared' });
	}
	return $c->render(json => { ok => 1, distance => $distance, likely => ($distance <= 12 ? 1 : 0), threshold => 12 });
}

# POST /manager/people/crest/import
sub action_24390 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'citizen only' }) unless &people_citizen($c);
	my $fail = sub { return $c->render(json => { ok => 0, error => $_[0] }); };
	my $raw = $c->param('card') // '';
	unless (length $raw) {
		my @uploads = @{ $c->req->uploads || [] };
		$raw = $uploads[0]->asset->slurp if @uploads;
	}
	return $fail->('no card was supplied') unless length $raw;
	return $fail->('that card is too large') if length $raw > 5_000_000;
	if ($raw =~ /^\s*CREST1Z?:/i) {
		return $c->render(json => &people_crest_import_code($c, $raw));
	}
	my $card = eval { decode_json($raw) };
	return $fail->('that card is not readable') unless ref $card eq 'HASH';
	return $fail->('that is not a JawnOS crest card') unless (($card->{'format'} || '') eq 'jawnos-crest-card');
	my $incoming = $card->{'crest'};
	return $fail->('the card has no crest record') unless ref $incoming eq 'HASH';
	return $fail->('the crest record does not verify') unless &subs::crest_verify_record($incoming);
	if (length($incoming->{'construct'} || '')) {
		# A construct card: find this house's own copy first, otherwise import it
		# as another house's construct (which the signed record names).
		my $local = &construct_crest_find_by_uuid($incoming->{'uuid'});
		if ($local) {
			return $c->render(json => {
				ok => 1, crest => $incoming, construct_app => $local->{'app'},
				construct_name => $incoming->{'name'} || $local->{'crest'}->{'name'} || '',
				known => 1,
			});
		}
		my $imported = &foreign_construct_import($incoming);
		unless ($imported->{'ok'}) { return $fail->($imported->{'error'}); }
		return $c->render(json => {
			ok => 1, crest => $incoming, construct_app => $imported->{'app'},
			construct_name => $imported->{'name'}, house_name => $imported->{'house_name'},
			foreign => 1,
		});
	}
	my $own = &subs::crest_record_read();
	return $fail->('that is this house\'s own crest') if $own->{'uuid'} && $incoming->{'uuid'} && $own->{'uuid'} eq $incoming->{'uuid'};
	my $safe_uuid = $incoming->{'uuid'} || '';
	$safe_uuid =~ s/[^A-Za-z0-9_-]//g;
	return $fail->('the crest record has no usable id') unless length $safe_uuid;
	my $suds = &subs::session_suds($c);
	return $fail->('the house key is not available') unless $suds;
	my $device = &subs::device_setter();
	my $folder = &subs::setting_grabber({ app => 'misc', setting => 'photo_location', device => $device }) || 'Pictures';
	my $dir = &subs::home($folder) . '/me';
	unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) }; }
	my $image_name;
	if (defined $card->{'image'} && length $card->{'image'}) {
		my $bytes = &subs::crest_data_uri_bytes($card->{'image'});
		return $fail->('the card picture is not readable') unless $bytes;
		require File::Temp;
		my ($fh, $tmp) = File::Temp::tempfile('jawnos-crest-import-XXXXXX', TMPDIR => 1, UNLINK => 0);
		return $fail->('no temporary file') unless $fh && $tmp;
		binmode $fh;
		print $fh $bytes;
		close $fh;
		my $ref = $tmp . '.ref.png';
		unless (&subs::crest_normalize_image($tmp, $ref)) {
			unlink $tmp; unlink $ref;
			return $fail->('the card picture could not be read');
		}
		my $dhash = &subs::crest_dhash($ref);
		my $distance = &subs::crest_hamming($incoming->{'dhash'}, $dhash);
		unless (defined $distance && $distance <= 16) {
			unlink $tmp; unlink $ref;
			return $fail->('the card picture does not match its signed hash');
		}
		my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard', device => $device }) || 'aes-256-ctr';
		$image_name = 'peer-crest.' . $safe_uuid . '.jpg.enc';
		my $enc = "$dir/$image_name";
		unless (&subs::openssl_file_crypt('e', $standard, $suds, $tmp, $enc, 0, 1)) {
			unlink $tmp; unlink $ref;
			return $fail->('the card picture could not be sealed');
		}
		unlink $tmp; unlink $ref;
	}
	my $existing = &subs::crest_peer_find($incoming->{'uuid'});
	my $entry = {
		crest => $incoming,
		device => $device,
		imported_at => &subs::rightNow(),
		status => 'imported',
		vouches => [],
	};
	$entry->{'endpoints'} = $card->{'endpoints'} if ref $card->{'endpoints'} eq 'HASH';
	$entry->{'image_data'} = $card->{'image'} if defined $card->{'image'} && length $card->{'image'};
	if ($existing) {
		$entry->{'imported_at'} = $existing->{'imported_at'} || $entry->{'imported_at'};
		$entry->{'vouch'} = $existing->{'vouch'} if ref $existing->{'vouch'} eq 'HASH';
		$entry->{'met_at'} = $existing->{'met_at'} if defined $existing->{'met_at'};
		$entry->{'status'} = $existing->{'status'} if (($existing->{'status'} || '') eq 'met');
		$entry->{'image_file'} = $existing->{'image_file'} if !$image_name && $existing->{'image_file'};
		$entry->{'image_data'} = $existing->{'image_data'} if !$entry->{'image_data'} && defined $existing->{'image_data'};
		$entry->{'endpoints'} = $existing->{'endpoints'} if !$entry->{'endpoints'} && ref $existing->{'endpoints'} eq 'HASH';
	}
	# The card's house advertises where it can be reached. The panel opens
	# home/store in a new tab, so only an http(s) URL is stored; anything else
	# is dropped rather than kept for a later window.open.
	if (ref $entry->{'endpoints'} eq 'HASH') {
		foreach my $kind (qw(home store)) {
			my $url = $entry->{'endpoints'}->{$kind};
			(my $clean = defined $url ? $url : '') =~ s/^\s+|\s+$//g;
			$entry->{'endpoints'}->{$kind} = $clean =~ m{^https?://}i ? $clean : '';
		}
	}
	$entry->{'image_file'} = $image_name if $image_name;
	my %seen_vouch;
	foreach my $vouch ( @{ $card->{'vouches'} || [] } ) {
		next unless ref $vouch eq 'HASH';
		next unless &subs::crest_vouch_verify($vouch);
		my $sig = $vouch->{'sig'} || '';
		next unless length $sig;
		if (($vouch->{'to_uuid'} || '') eq ($incoming->{'uuid'} || '')
			&& ($vouch->{'to_pubkey'} || '') eq ($incoming->{'pubkey'} || '')) {
			next if $seen_vouch{$sig}++;
			push @{$entry->{'vouches'}}, $vouch if scalar @{$entry->{'vouches'}} < 100;
		}
		if ($own->{'uuid'}
			&& ($vouch->{'from_uuid'} || '') eq ($incoming->{'uuid'} || '')
			&& ($vouch->{'to_uuid'} || '') eq ($own->{'uuid'} || '')
			&& ($vouch->{'to_pubkey'} || '') eq ($own->{'pubkey'} || '')) {
			&subs::crest_incoming_vouch_add($vouch);
		}
	}
	return $fail->('the card could not be stored') unless &subs::crest_peer_upsert($entry);
	return $c->render(json => { ok => 1, crest => $incoming, entry => $entry });
}

1;
