package Manager;

# Manager helpers, part 12 of 37. Moved out of Manager.pl so a
# helper can be read and changed without opening 24k lines. The package is
# still Manager, and lib/JawnOS/Manager/Index.pm maps every sub name here to
# this file; Manager.pm loads it on the first call.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

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
use Mojo::IOLoop::ReadWriteFork;
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
use IO::Socket::UNIX;
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

sub pseudonym_maker($context,$app) {
	my $icon_set = &subs::icon_set();
	my $set_key = $context . '.' . $icon_set;
	if (my $ps = &subs::cache_get({ app => 'me', context => 'pseudonyms', subcontext => $set_key })) {
		# the console panel is now called sessions - migrate older cached lists
		my $renamed = 0;
		# names this build no longer ships (the beacon went away), dropped from
		# any list cached before the change
		my %retired = map { $_ => 1 } qw/beacon/;
		my @kept = grep { !$_->{'name'} || !$retired{$_->{'name'}} } @{$ps};
		if (scalar @kept != scalar @{$ps}) { $ps = \@kept; $renamed = 1; }
		# The ledger's own type glyphs (invoice, quote, encrypt, assign, reset,
		# software) are icons for appointment types, not dock faces: they have
		# no panel to open. Older cached lists carried them as 'on', which put
		# six dead icons in the dock; take them out but keep them in the
		# viewer's list, where the ledger reads them by name.
		my %dockless = map { $_ => 1 } qw/invoice quote encrypt assign reset software/;
		foreach my $p ( @{$ps} ) {
			if ($p->{'name'} && $p->{'name'} eq 'console') {
				$p->{'name'} = 'sessions';
				$renamed = 1;
			}
			if ($p->{'name'} && $dockless{$p->{'name'}} && ($p->{'status'} || '') eq 'on') {
				$p->{'status'} = 'off';
				$renamed = 1;
			}
		}
		if ($renamed) { &subs::cache_set({ app => 'me', context => 'pseudonyms', subcontext => $set_key }, $ps); }
		return $ps;
	}
	my $pseudonyms = [
		{ status => 'on', name => "remote_control", icon => "Froggoli", speech => 'Ribbit' },
		{ status => 'on', name => "delorean", icon => "Mr. Sun", speech => 'Run for it Marty!' },
		{ status => 'on', name => "walkboy", icon => "headphones", speech => 'av room' },
		{ status => 'on', name => "keyboard", icon => "keyboard", speech => 'typewriter' },
		{ status => 'on', name => "calculator", icon => "calculator", speech => 'calculator' },
		{ status => 'on', name => "notifications", icon => "bell", speech => 'where are your friends now?' },
		{ status => 'on', name => "sessions", icon => "windows", speech => 'i watch the baytch' },
		{ status => 'on', name => "controller", icon => "heart", speech => 'Run for it Marty!' },
		# The ledger's own types wear the set's glyphs of the same name: a quote,
		# an invoice, the encrypt stamp and the rest of the appointment types that
		# had no pseudonym (they showed no icon in the details and the timeline
		# until now). They are glyphs, not dock faces: viewer context keeps every
		# status, so the ledger still reads them by name, while 'off' keeps them out
		# of the dock (Configure -> Pseud reads on and off, so their glyph is still
		# theirs to change).
		{ status => 'off', name => "invoice", icon => "invoice" },
		{ status => 'off', name => "quote", icon => "quote" },
		{ status => 'off', name => "encrypt", icon => "encrypt" },
		{ status => 'off', name => "assign", icon => "assign" },
		{ status => 'off', name => "reset", icon => "reset" },
		{ status => 'off', name => "software", icon => "software" },
		{ status => 'button', name => 'record', icon => 'record', classmates => "medium_thumb save_appointment", colour => '', place => 'top' },
		{ status => 'button', name => 'text', icon => 'love letter', colour => '', place => 'top' },
		{ status => 'button', name => 'start', icon => 'play', classmates => "medium_thumb save_appointment", colour => '', place => 'top' },
		{ status => 'button', name => 'prev', icon => 'prev', classmates => "medium_thumb time_jump", colour => '', place => 'top' },
		{ status => 'button', name => 'next', icon => 'next', classmates => "medium_thumb time_jump", colour => '', place => 'top' },
		{ status => 'button', name => 'stop', icon => 'stop', classmates => "medium_thumb save_appointment", click => "", colour => '', place => 'top' },
		{ status => 'button', name => 'note', icon => 'Mr. President', classmates => "br medium_thumb save_appointment", colour => '', place => 'top' },
		{ status => 'button', name => 'msg', icon => 'mailbox', colour => '', place => 'top' },
		# the appointment's own buttons live behind three group buttons now: the
		# media clapper, the extra ellipsis and the linked pair. The group key says
		# which door a button sits behind, and the wrapper renders each row from it
		{ status => 'button', name => 'video', icon => 'camera', classmates => "little_thumb multimedia save_appointment", click => "", colour => '#bdd6c5', place => 'mid', group => 'media' },
		{ status => 'button', name => 'audio', icon => 'microphone', classmates => "little_thumb save_appointment", click => "", colour => '#bdd6c5', place => 'mid', group => 'media' },
		{ status => 'button', name => 'screen', icon => 'monitor', classmates => "little_thumb multimedia save_appointment", click => "", colour => '#bdd6c5', place => 'mid', group => 'media' },
		{ status => 'button', name => 'usual', icon => 'usual_button', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid', group => 'extra' },
		{ status => 'button', name => 'cancel', icon => 'cancel_button', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid', group => 'extra' },
		{ status => 'button', name => 'resume', icon => 'detour', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid', group => 'extra' },
		{ status => 'button', name => 'renew', icon => 'renew', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid', group => 'extra' },
		{ status => 'button', name => 'pause', icon => 'pause', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid', group => 'extra' },
		{ status => 'button', name => 'complete', icon => 'cake', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid', group => 'extra' },
		{ status => 'button', name => 'delay', icon => 'delay_button', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'mid', group => 'extra' },
		{ status => 'button', name => 'telephone', icon => 'telephone line', classmates => 'little_thumb save_appointment', colour => '#ffec1f', place => 'mid', group => 'connect' },
		# the rest wait on their names being configured into classmates, and on a
		# group to sit behind
		{ status => 'button', name => 'camera', icon => 'eye', colour => '#bdd6c5', place => 'mid', group => 'media' },
		{ status => 'button', name => 'marker', icon => 'marker', colour => '#ff0000', place => 'mid', group => 'media' },
		{ status => 'button', name => 'transaction', icon => 'register', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'inventory', icon => 'inventory', classmates => "little_thumb", colour => '#bdd6c5' },
		{ status => 'button', name => 'upload', icon => 'upload', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'entry', icon => 'eye', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'dingaling', icon => 'badge', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'id', icon => 'key', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'backup', icon => 'diskette', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'image', icon => 'gallery', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'leave', icon => 'exit', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'snapshot', icon => 'gallery', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'studio', icon => 'mixer', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'purchase', icon => 'cash', colour => '#bdd6c5', place => 'mid' },
		{ status => 'button', name => 'command', icon => 'code', classmates => "little_thumb save_appointment", colour => '#ff007b', place => 'bottom' },
		{ status => 'button', name => 'sms', icon => 'phone_sms', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'bottom' },
		{ status => 'button', name => 'email', icon => 'envelope', classmates => "", colour => '#bdd6c5',  },
		{ status => 'button', name => 'scan', icon => 'flatbed', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'bottom' },
		{ status => 'button', name => 'feeder', icon => 'feeder', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'bottom' },
		{ status => 'button', name => 'scraper', icon => 'scraper', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'none' },
		{ status => 'button', name => 'config', icon => 'wrench', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'none' },
		{ status => 'button', name => 'web', icon => 'web_button', classmates => "little_thumb save_appointment", colour => '#bdd6c5', place => 'bottom' },
		{ status => 'cursor', name => 'pointer', icon => 'pointer', classmates => "little_thumb", colour => '#ffec1f', place => 'bottom' },
		{	status => 'cursor', name => 'eyepointer', icon => 'eyepointer', classmates => "little_thumb", colour => "#ffec1f", place => 'bottom' },
		{	status => 'cursor', name => 'measure', icon => 'measures', classmates => "little_thumb", colour => "#ffec1f", place => 'bottom' },
	];

	my $custom_pseudonyms = eval { return decode_json &subs::setting_grabber({ 'app' => 'config', setting => 'pseudonyms' }) } || {};


	if ($context eq 'manager') {
		@{$pseudonyms} = grep { $_->{'status'} eq 'on' } @{$pseudonyms};
	}
	elsif ($context eq 'config') {
		@{$pseudonyms} = grep { $_->{'status'} eq 'on' || $_->{'status'} eq 'off' } @{$pseudonyms};
	}
	elsif ($context eq 'viewer') {
		#@{$pseudonyms} = grep { $_->{'status'} eq 'button' } @{$pseudonyms};
	}
	elsif ($context eq 'store') {
		@{$pseudonyms} = grep { $_->{'classmates'} !~ /save_appointment/ } @{$pseudonyms};
	}
	elsif ($context eq 'teletype') {
		@{$pseudonyms} = grep { $_->{'status'} eq 'cursor' } @{$pseudonyms};
	}
	foreach my $p ( @{$pseudonyms} ) {
		foreach my $k ( keys %{$custom_pseudonyms->{$p->{'name'}}} ) {

			$p->{$k} = $custom_pseudonyms->{$p->{'name'}}->{$k} if $custom_pseudonyms->{$p->{'name'}}->{$k};
		}
		unless ( $custom_pseudonyms->{$p->{'name'}}->{'icon'} ) {
			my $i = $p->{'icon'};
			my @candidates = (
				($icon_set ? "/icons/sets/" . $icon_set . "/" . $i . ".svg" : ()),
				"/images/decipherable/" . $i . ".png",
				"/images/studio/" . $i . ".png",
				"/images/make believe/" . $i . ".png",
				"/icons/" . $i . ".png",
				"/icons/" . $i . ".jpg",
				"/images/icons/" . $i . ".png",
				"/images/jonathans/" . $i . ".png",
			);
			$p->{'icon'} = $candidates[-1];
			foreach my $candidate ( @candidates ) {
				if (-e "public" . $candidate) {
					$p->{'icon'} = $candidate;
					last;
				}
			}
			$p->{'icon'} = &subs::icon_original($p->{'icon'});
		}
	}

	&subs::cache_set({ app => 'me', context => 'pseudonyms', subcontext => $set_key }, $pseudonyms);
	return $pseudonyms;
};

sub ticket_desk_allowed($c) {
	return 1 if $c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen';
	# The Dev panel's Go rides a stored peer session (resident, not citizen). That
	# session already passed the peer gate; let it mint the ticket, and the
	# signatorial below is what makes the ticket a vouch. A guest-level ticket
	# minted by a peer is still a guest, so the peer flag alone is not the desk.
	return 1 if ($c->session('peer') || '') eq '1'
		&& &subs::privilege_is_house($c->session('privilege'));
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	return 1 if $rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm);
	return 0;
}

sub ticket_policy() {
	my $row = &subs::db_query('select value from settings where app=? and setting=? order by server_time desc limit 1', 'box_office', 'request_policy')->hashes->[0];
	my $policy = eval { return decode_json $row->{'value'} } || {};
	$policy->{'guest_warranty'} = '-1d' unless defined $policy->{'guest_warranty'} && length $policy->{'guest_warranty'};
	$policy->{'issue_guest_on_request'} = 0 unless defined $policy->{'issue_guest_on_request'};
	return $policy;
}

sub ticket_policy_set($policy) {
	&subs::setting_setter({ app => 'box_office', setting => 'request_policy', value => encode_json $policy });
}

sub ticket_blacklist() {
	my $row = &subs::db_query('select value from settings where app=? and setting=? order by server_time desc limit 1', 'box_office', 'blacklist')->hashes->[0];
	return eval { return decode_json $row->{'value'} } || [];
}

sub ticket_blacklist_save($list) {
	&subs::setting_setter({ app => 'box_office', setting => 'blacklist', value => encode_json $list });
}

sub ticket_blacklist_numbers() {
	my @numbers;
	foreach my $b ( @{&ticket_blacklist()} ) {
		next unless ref $b eq 'HASH';
		my $number = &ticket_contact_clean('phone', $b->{'phone'});
		push @numbers, $number if $number;
	}
	my %seen;
	return [ grep { !$seen{$_}++ } @numbers ];
}

sub ticket_blacklist_block($number,$label,$note) {
	my $clean = &ticket_contact_clean('phone', $number);
	return '' unless $clean;
	my $list = &ticket_blacklist();
	foreach my $b ( @{$list} ) {
		next unless ref $b eq 'HASH';
		return $clean if &ticket_contact_clean('phone', $b->{'phone'}) eq $clean;
	}
	push @{$list}, {
		name => defined $label && length $label ? &subs::format_name($label) : '',
		email => '',
		phone => $clean,
		note => defined $note && length $note ? $note : 'blocked call',
		timestamp => &subs::rightNow()
	};
	&ticket_blacklist_save($list);
	return $clean;
}

sub phone_names() {
	my $rows = &subs::db_query('select app, value from settings where setting=? and value != ?', 'phone', '')->hashes;
	my %names;
	foreach my $r ( @{$rows} ) {
		my $number = &ticket_contact_clean('phone', $r->{'value'});
		next unless $number;
		$names{$number} = $r->{'app'};
	}
	# every extra line a person keeps - their home, their work - names a call too,
	# so the in-call screen shows the person rather than a bare number
	my $lists = &subs::db_query('select app, value from settings where setting=? and value != ?', 'phones', '')->hashes;
	foreach my $r ( @{$lists} ) {
		my $list = eval { return decode_json $r->{'value'} } || [];
		$list = [ $list ] if ref $list eq 'HASH';
		next unless ref $list eq 'ARRAY';
		foreach my $c ( @{$list} ) {
			next unless ref $c eq 'HASH';
			my $number = &ticket_contact_clean('phone', $c->{'value'});
			next unless $number;
			$names{$number} ||= $r->{'app'};
		}
	}
	return \%names;
}

sub phone_directory() {
	my $lines = &subs::contact_lines('phone');
	my (@known, @numbers);
	foreach my $app ( keys %{$lines} ) {
		my @l = @{ $lines->{$app} };
		next unless scalar @l;
		my $row = { app => $app, value => $l[0]->{'value'}, numbers => \@l };
		if ( $app =~ /^\d+$/ ) { push @numbers, $row; }
		else { push @known, $row; }
	}
	@known = sort { lc $a->{'app'} cmp lc $b->{'app'} } @known;
	@numbers = sort { $a->{'app'} cmp $b->{'app'} } @numbers;
	return { known => \@known, numbers => \@numbers };
}

sub phone_blocked() {
	my @blocked;
	foreach my $b ( @{&ticket_blacklist()} ) {
		next unless ref $b eq 'HASH';
		my $number = &ticket_contact_clean('phone', $b->{'phone'});
		next unless $number;
		push @blocked, {
			number => $number,
			name => $b->{'name'} || '',
			note => $b->{'note'} || '',
			stamp => $b->{'timestamp'} || '',
		};
	}
	return \@blocked;
}

# Recent is the calls worth seeing: a blocked number is turned away before it
# rings, so its cancelled appointment is the house's record of the refusal, not a
# call to read. Drop it from the pane, matching on the same last-ten-digits form
# the blacklist uses (ticket_contact_clean), so a stored country code or dashes
# cannot let it back in.
sub phone_recent_unblocked($calls, $numbers) {
	my %blocked;
	foreach my $n ( @{ $numbers || [] } ) {
		my $clean = &ticket_contact_clean('phone', $n);
		$blocked{$clean} = 1 if $clean;
	}
	return [ grep {
		my $account = &ticket_contact_clean('phone', $_->{'account'});
		!$account || !$blocked{$account};
	} @{ $calls || [] } ];
}

# The reception settings the Phone app's IVR pane reads and writes. They are
# ordinary phone settings, so the phone that carries the SIM is the one that
# owns them; the selected machine is a remote_machines signatorial (or its IP
# when it has no signatorial yet).
sub phone_ivr_defaults {
	return &subs::phone_ivr_defaults();
}

# The six call-flow buckets. `route` is the older three-way knob; when a phone
# has no saved matrix, the matrix is derived from it so an existing phone keeps
# behaving the same way.
# A route for one number, set by tapping it in the Phone app. The value is the
# same five words the bucket flows use (ring, ivr, voicemail, reject), and an
# empty one means "let the person's relationship decide". Numbers are keyed by
# the cleaned ten digits the rest of the phone code matches on.
sub phone_routes_read {
	my $raw = &subs::setting_grabber({ app => 'phone', setting => 'ivr_routes', device => 'all', benign => 1 });
	my $stored = (defined $raw && length $raw) ? eval { decode_json($raw) } : undef;
	return {} unless ref $stored eq 'HASH';
	my %clean;
	foreach my $number ( keys %{$stored} ) {
		my $key = &ticket_contact_clean('phone', $number);
		next unless $key;
		my $flow = $stored->{$number};
		$flow = $flow->{'flow'} if ref $flow eq 'HASH';
		next unless defined $flow && $flow =~ /^(?:ring|ivr|voicemail|reject)$/;
		$clean{$key} = $flow;
	}
	return \%clean;
}

sub phone_routes_save {
	my ($routes) = @_;
	my %clean;
	my $given = ref $routes eq 'HASH' ? $routes : {};
	foreach my $number ( keys %{$given} ) {
		my $key = &ticket_contact_clean('phone', $number);
		next unless $key;
		my $flow = $given->{$number};
		$flow = $flow->{'flow'} if ref $flow eq 'HASH';
		next unless defined $flow && $flow =~ /^(?:ring|ivr|voicemail|reject)$/;
		$clean{$key} = $flow;
	}
	&subs::setting_setter({
		app => 'phone',
		setting => 'ivr_routes',
		value => encode_json(\%clean),
		device => 'all',
		timestamp => &subs::rightNow(),
	});
	return \%clean;
}

# Set or clear one number's route. 'default' (or '') removes the entry, so the
# person's relationship decides again.
sub phone_route_set {
	my ($number, $flow) = @_;
	my $key = &ticket_contact_clean('phone', $number);
	return { ok => 0, error => 'no number' } unless $key;
	my $routes = &phone_routes_read();
	my $want = defined $flow ? $flow : '';
	if (!length $want || $want eq 'default') {
		delete $routes->{$key};
	}
	elsif ($want =~ /^(?:ring|ivr|voicemail|reject)$/) {
		$routes->{$key} = $want;
	}
	else {
		return { ok => 0, error => 'unknown route' };
	}
	&phone_routes_save($routes);
	return { ok => 1, number => $key, flow => $routes->{$key} || '', routes => $routes };
}

# How a call from this number is handled: the number's own route first, then the
# relationship it belongs to, then 'unknown' for a number the house cannot name.
sub phone_route_for {
	my ($number) = @_;
	my $key = &ticket_contact_clean('phone', $number);
	my $routes = &phone_routes_read();
	if ($key && $routes->{$key}) {
		return { flow => $routes->{$key}, source => 'number', number => $key };
	}
	my $ivr = &phone_ivr_settings();
	unless (($ivr->{'enabled'} || 'no') eq 'yes') {
		return { flow => 'ring', source => 'off', number => $key };
	}
	my $bucket = 'unknown';
	if ($key) {
		my $relations = &phone_relationships();
		my $row = $relations->{$key};
		if ($row && $row->{'value'}) {
			$bucket = $row->{'value'};
		}
		elsif (&phone_names()->{$key}) {
			$bucket = 'stranger';
		}
	}
	my $flow = $ivr->{'flows'}->{$bucket} || 'ring';
	return { flow => $flow, source => $bucket, number => $key };
}

sub phone_ivr_flow_defaults($route) {
	return &subs::phone_ivr_flow_defaults($route);
}

sub phone_ivr_flow_clean($flows, $route) {
	return &subs::phone_ivr_flow_clean($flows, $route);
}

sub phone_ivr_settings {
	return &subs::phone_ivr_settings();
}

sub phone_ivr_save($params) {
	my $next = &phone_ivr_settings();
	foreach my $key (qw(enabled machine route voice greeting prompt voicemail thanks)) {
		next unless exists $params->{$key};
		my $value = defined $params->{$key} ? $params->{$key} : '';
		$value =~ s/^\s+|\s+$//g;
		$next->{$key} = $value;
	}
	if (exists $params->{'flows'}) {
		my $flows = $params->{'flows'};
		$flows = eval { decode_json($flows) } if defined $flows && !ref $flows;
		$next->{'flows'} = &phone_ivr_flow_clean($flows, $next->{'route'});
	}
	$next->{'enabled'} = ($next->{'enabled'} eq 'yes' || $next->{'enabled'} eq '1' || $next->{'enabled'} eq 'on') ? 'yes' : 'no';
	$next->{'route'} = 'unknown' unless $next->{'route'} =~ /^(?:unknown|all|off)$/;
	my %voices = map { $_->{'value'} => 1 } &subs::say_voices();
	$next->{'voice'} = &subs::say_default_voice() unless $voices{ $next->{'voice'} };
	if (defined $next->{'machine'} && length $next->{'machine'}) {
		# a gateway may be a peer, this machine (which has no remote_machines row
		# for itself), or a peer another machine knows by its own key - the pane
		# only offers real ones, so the shape is enough to keep it
		my $machine = $next->{'machine'};
		my $self = (-x './perl/sco/sco_helper') ? &phone_self_signatorial() : '';
		my $known = ($self && $machine eq $self)
			|| &subs::db_select('remote_machines', undef, { signatorial => $machine })->hashes->[0]
			|| &subs::db_select('remote_machines', undef, { ip => $machine })->hashes->[0]
			|| $machine =~ /^[0-9a-f]{32}$/
			|| $machine =~ /^[0-9a-fA-F.:]+$/;
		$next->{'machine'} = $known ? $machine : '';
	}
	foreach my $key (qw(greeting prompt voicemail thanks)) {
		$next->{$key} = substr($next->{$key}, 0, 1000);
	}
	# the reception is the house's, not the device's: the phone turns it on and
	# the gateway machine plays it, so both read the same row
	foreach my $key (qw(enabled machine route voice greeting prompt voicemail thanks)) {
		&subs::setting_setter({ app => 'phone', setting => 'ivr_' . $key, value => $next->{$key}, device => 'all' });
	}
	&subs::setting_setter({ app => 'phone', setting => 'ivr_flows', value => encode_json($next->{'flows'}), device => 'all' });
	return $next;
}

# The machines the IVR pane can offer, online first. A machine is available when
# the mesh's own remote_machines row says it is connected; the pane shows the
# difference rather than hiding an offline choice the person may still want.
# This machine's own signatorial, read from the mirror beside the database. A
# gateway is usually the machine in front of you - the one with the adapter - and
# that machine has no remote_machines row for itself, so the pane would never
# offer it.
sub phone_self_signatorial {
	return $gb::phone_self_signatorial if defined $gb::phone_self_signatorial;
	my $sig = '';
	my $file = &subs::signatorial_identity_mirror();
	if ($file && -e $file) {
		if (open(my $fh, '<', $file)) {
			local $/;
			$sig = <$fh> // '';
			close $fh;
			$sig =~ s/\s+//g;
		}
	}
	$gb::phone_self_signatorial = ($sig =~ /^[0-9a-f]{32}$/) ? $sig : '';
	return $gb::phone_self_signatorial;
}

sub phone_ivr_machines {
	my @machines;
	# only a machine that can run the helper can be a gateway
	my $self = (-x './perl/sco/sco_helper') ? &phone_self_signatorial() : '';
	if ($self) {
		push @machines, {
			key         => $self,
			hostname    => &subs::machine_hostname() . ' (this machine)',
			ip          => '',
			connection  => 'active',
			available   => 1,
			device      => &subs::device_setter(),
			manager     => '',
			port        => '',
			signatorial => $self,
			server_time => '',
			local       => 1,
		};
	}
	foreach my $rm ( @{ &subs::db_select('remote_machines')->hashes } ) {
		next if $self && (($rm->{'signatorial'} || '') eq $self);
		next unless ref $rm eq 'HASH';
		my $key = $rm->{'signatorial'} || $rm->{'ip'} || '';
		next unless length $key;
		push @machines, {
			key         => $key,
			hostname    => $rm->{'hostname'} || $rm->{'ip'} || $key,
			ip          => $rm->{'ip'} || '',
			connection  => $rm->{'connection'} || 'inactive',
			available   => (($rm->{'connection'} || '') eq 'active') ? 1 : 0,
			device      => $rm->{'device'} || '',
			manager     => $rm->{'manager'} || '',
			port        => $rm->{'port'} || '',
			signatorial => $rm->{'signatorial'} || '',
			server_time => $rm->{'server_time'} || '',
		};
	}
	@machines = sort {
		($b->{'available'} <=> $a->{'available'})
			|| (lc($a->{'hostname'}) cmp lc($b->{'hostname'}))
	} @machines;
	return \@machines;
}

sub phone_ivr_machine($key) {
	return undef unless defined $key && length $key;
	my $self = (-x './perl/sco/sco_helper') ? &phone_self_signatorial() : '';
	if ($self && $key eq $self) {
		return {
			signatorial => $self,
			hostname => &subs::machine_hostname(),
			ip => '',
			connection => 'active',
			device => &subs::device_setter(),
			manager => '',
		};
	}
	return &subs::db_select('remote_machines', undef, { signatorial => $key })->hashes->[0]
		|| &subs::db_select('remote_machines', undef, { ip => $key })->hashes->[0];
}

# The caller's relationship by number, for the app's call screening. The house's
# phone names give the app; person_relationships gives the configuration word.
sub phone_relationships {
	my $names = &phone_names();
	my $relations = &subs::person_relationships();
	my %out;
	foreach my $number ( keys %{$names} ) {
		my $app = $names->{$number};
		my $rel = $relations->{$app} or next;
		$out{$number} = {
			app    => $app,
			value  => $rel->{'value'},
			rating => $rel->{'rating'},
		};
	}
	return \%out;
}

sub phone_avatar_thumb($file) {
	return '' unless $file && -e $file;
	my $dir = &subs::database_dir() . '/.thumbs';
	mkdir $dir unless -d $dir;
	my @stat = stat($file);
	my $base = $file;
	$base =~ s{.*/}{};
	$base =~ s/[^A-Za-z0-9._-]+/-/g;
	my $thumb = $dir . '/' . $base . '-' . ($stat[7] || 0) . '-' . ($stat[9] || 0) . '.jpg';
	return $thumb if -e $thumb && -s $thumb > 0;
	my $covered = &subs::image_bridge_cover($file, 160, $thumb, 82);
	`magick "$file" -resize 160x160^ -gravity center -extent 160x160 -quality 82 "$thumb" 2>/dev/null` unless $covered;
	return (-e $thumb && -s $thumb > 0) ? $thumb : '';
}

sub phone_avatar_data($app) {
	my $settings = &subs::settings_grabber({ app => $app }) || {};
	return '' unless $settings->{'main_image'};
	my ($destination,$asset) = &subs::file_device_renamer({ file => $settings->{'main_image'}, app => $app, type => 'image' });
	my $thumb = &phone_avatar_thumb($destination . $asset);
	return '' unless $thumb;
	open(my $fh, '<', $thumb) or return '';
	binmode $fh;
	local $/;
	my $bytes = <$fh>;
	close $fh;
	return '' unless defined $bytes && length $bytes;
	return 'data:image/jpeg;base64,' . encode_base64($bytes, '');
}

sub ticket_contact_clean($kind,$value) {
	return '' unless defined $value && length $value;
	if ($kind eq 'email') {
		$value = lc $value;
	}
	elsif ($kind eq 'phone') {
		$value =~ s/\D+//g;
		$value =~ s/^1//;
	}
	else {
		$value = &subs::unformat_name($value);
	}
	return $value;
}

sub ticket_blacklist_match($info) {
	my $name = &ticket_contact_clean('name', $info->{'name'});
	my $email = &ticket_contact_clean('email', $info->{'email'});
	my $phone = &ticket_contact_clean('phone', $info->{'phone'});
	foreach my $b ( @{&ticket_blacklist()} ) {
		next unless ref $b eq 'HASH';
		return 1 if $name && $name eq &ticket_contact_clean('name', $b->{'name'});
		return 1 if $email && $email eq &ticket_contact_clean('email', $b->{'email'});
		return 1 if $phone && $phone eq &ticket_contact_clean('phone', $b->{'phone'});
	}
	return 0;
}

sub ticket_request_known($info) {
	my @known;
	my $email = &ticket_contact_clean('email', $info->{'email'});
	push @known, &subs::contact_apps('email', $email) if $email;
	my $phone = &ticket_contact_clean('phone', $info->{'phone'});
	push @known, &subs::contact_apps('phone', $phone) if $phone;
	@known = grep { defined $_ && length $_ } @known;
	my %seen;
	@known = grep { !$seen{$_}++ } @known;
	return \@known;
}

sub ticket_request_allowed($c) {
	my $browser_tab_id = $c->param('browser_tab_id') || '';
	if ($browser_tab_id) {
		my $open = &subs::db_query('select uuid from tickets where browser_tab_id=? and status=? and server_time > ? order by server_time desc limit 1', $browser_tab_id, 'request', &subs::rightNow() - 3600000)->hashes->[0];
		return 0 if $open && $open->{'uuid'};
	}
	my ($db) = &subs::database_grabber();
	return 1 unless $db;
	my $ip = $c->tx->remote_address;
	my $now = &subs::rightNow();
	my $seen = &subs::db_query('select server_time from cache where context=? and uuid=? order by server_time desc limit 1', 'ticket_request', $ip)->hashes->[0];
	return 0 if $seen->{'server_time'} && $seen->{'server_time'} > $now - 600000;
	&subs::db_query('delete from cache where context=? and uuid=?', 'ticket_request', $ip);
	&subs::db_query('insert into cache (uuid, context, app, server_time, timestamp) values (?,?,?,?,?)', $ip, 'ticket_request', 'box_office', $now, $now);
	return 1;
}

sub ticket_request_pending_html() {
	return '<h3>' . &subs::lang('home.request_received') . '</h3><p>' . &subs::lang('home.request_pending') . '</p>';
}

sub ticket_request_mint($c, $request, $privilege, $warranty) {
	my $info = eval { return decode_json $request->{'information'} } || {};
	my $host = $c->req->url->base->host;
	my $local = &subs::local_domain();
	my $addresses = eval { &subs::device_lister(&subs::rightNow(), '')->[0]->{'address'} } || {};
	my $nic;
	foreach my $key ( sort keys %{$addresses} ) {
		next unless $addresses->{$key}->{'ip'};
		if ($addresses->{$key}->{'ip'} eq $host || $key eq $host) { $nic = $key; last; }
	}
	my $domain = &subs::config_reader()->{'domain'};
	$nic = $domain if !$nic && $domain && $addresses->{$domain};
	$nic = ( grep { $addresses->{$_}->{'ip'} } sort keys %{$addresses} )[0] unless $nic;
	my $suds = &subs::session_suds($c) || &subs::suds_grabber();
	return undef unless $nic && $suds;
	my $data = &qrcode_generator({
		timestamp => &subs::rightNow(),
		app => 'box_office',
		name => $request->{'name'},
		privilege => $privilege,
		project => $info->{'project'},
		host => (($local ne '' && ($host eq $local || $host eq '127.0.0.1')) ? $local : undef),
		nic => $nic,
		warranty => $warranty,
		keep_warranty => 1
	});
	$data->{'browser_tab_id'} = $request->{'browser_tab_id'};
	$data->{'information'} = $request->{'information'};
	$data->{'crest_uuid'} = $request->{'crest_uuid'} if $request->{'crest_uuid'};
	return $data;
}

sub ticket_request_notify($c, $request, $info) {
	my $who = $info->{'name'} || $info->{'email'} || 'Someone';
	my $awaiting = scalar @{ &subs::db_query('select uuid from tickets where status=?', 'request')->hashes };
	my (undef,$database) = &subs::database_grabber();
	&Websocket::send('tab', { type => 'ticket_request_arrival', count => $awaiting, message => $who . ' asks for a pass' });
	# an open box office refreshes itself; the visible test keeps a hidden window
	# from rebuilding under the user
	&Websocket::send('server', { console => '$("#box_office").is(":visible") && typeof boxOffice == "function" ? boxOffice() : 0;' });
	&notification_sender({ app => 'box_office', role => 'citizen', title => 'Pass Request', message => $who . ' asks for a pass', image => $gb::known_appts->{'box_office'}->{'icon'} }, $database);
}

sub ticket_peer_signatorial($c) {
	# The remote Go normally rides the stored peer session (a cookie) rather than
	# a fresh signature. That session already passed the peer gate; its
	# signatorial is the vouch. A freshly signed request is the fallback.
	if (($c->session('peer') || '') eq '1') {
		my $ssig = $c->session('peer_signatorial') || '';
		return $ssig if length $ssig;
	}
	my $sig = $c->param('signatorial') || '';
	return '' unless length $sig;
	my $rm = &subs::db_select('remote_machines', undef, { signatorial => $sig })->hashes->[0];
	return '' unless $rm && $rm->{'pubkey'};
	# Only a request that proves the pinned peer key may mint a peer ticket.
	# peer_verify memoises, so ticket_desk_allowed's check already covers this.
	return &subs::peer_verify($c, $rm) ? $sig : '';
}

sub qrcode_generator($params) {
	my $timestamp = $params->{'timestamp'} || &subs::rightNow();
	my $app = $params->{'app'};
	my $name = $params->{'name'};
	my $project = $params->{'project'};
	my $debriefer = $params->{'debriefer'};
	my $nic = $params->{'nic'};
	my $suds = $params->{'suds'};
	my $warranty = $params->{'warranty'};
	my $privilege = $params->{'privilege'};
	my $peer_signatorial = $params->{'peer_signatorial'} || '';
	my $db = $params->{'db'};
	my $database = $params->{'database'};
	my $sql = $params->{'sql'};


	my $server_time = &subs::rightNow();
	unless ($db) {
		($db,$database,$sql) = &subs::database_grabber('new');
	}
	my $random_password = &subs::random_string_creator(40);
	my $sj = { ts => $timestamp, p => &subs::random_string_creator(25), uuid => &subs::random_string_creator(10) };

	my $secret_json = encode_json $sj;
	$suds = &subs::note_encrypter($sj->{'p'}, $suds);
	my $secret = &subs::note_encrypter($random_password, $secret_json);
	$secret = url_escape `echo "$secret" | base64 -w 0`;

	my $uuid = $sj->{'uuid'};

	my $domain;
	if ($params->{'host'}) {
		# an app or self ticket names the local alias, which resolves to this
		# machine's loopback but keeps the wildcard certificate
		$domain = $params->{'host'};
	}
	elsif ($params->{'db'}) {
		$domain = '127.0.0.1';
	}
	else {
		if ($nic eq &subs::config_reader()->{'domain'}) {
			$domain = $nic;
		}
		else {
			my $x = &subs::device_lister($timestamp, '')->[0]->{'address'};
			$domain = $x->{$nic}->{'ip'};
		}
	}
	my $port = $ENV{PORT_AHOY};
	if ($device eq 'server') {
		$port = 443;
	}
	my $url = 'https://' . $domain . ':' . $ENV{'PORT_DOCK'} . '/box_office/' . $sj->{'uuid'} . '?s=' . $secret;
	$warranty = $warranty || &subs::setting_grabber({ app => 'box_office', setting => 'warranty' });
	# the issue form's warranty box is a choice about this ticket, not a new
	# house default; a request minted in the background must not move it
	unless ($params->{'db'} || $params->{'keep_warranty'}) {
		&subs::setting_setter({ app => 'box_office', setting => 'warranty', value => $warranty });
	}
	# "forever" is the apps' warranty: a far-future epoch no expiry check or
	# sweep will ever pass, so a ticket baked into an app never expires
	$warranty = (($warranty || '') =~ /^\s*forever\s*$/i) ? &subs::forever_warranty() : &subs::ago_calc($warranty,$timestamp);
	my $duration = $warranty - $timestamp;

	# The pass's url column is the ticket; the QR is a convenience drawn from it.
	# A phone runtime without qrencode used to write 'data:image/png;base64,' +
	# an empty body (a 22-byte "image") and the desk showed a blank thumbnail.
	# Now a failed encode stores '' and the pass still mints - see
	# markup.html.ep's <% if ($t->{'image'}) %> guard.
	# $url is handed over as a list: backticks would re-parse the shell-quoted
	# secret, and a ';' or '$' in it would run there.
	my $image = '';
	{
		my $qr = qx/qrencode -o - "\$url"/;
		$image = 'data:image/png;base64,' . encode_base64($qr, '')
			if defined $qr && length $qr && substr($qr, 0, 4) eq "\x89PNG";
	}
	unless (length $image) {
		print STDERR "box_office: qrencode produced no PNG (is qrencode installed?); "
			. "pass " . $sj->{'uuid'} . " minted without a QR image\n";
	}
	my $data = {
		timestamp => $timestamp,
		uuid => $sj->{'uuid'},
		warranty => $warranty,
		url => $url,
		server_time => $server_time,
		name => $name,
		image => $image,
		privilege => $privilege,
		verification => $secret,
		status => 'active',
		duration => $duration,
		app => $app,
		password => $random_password,
		port => $ENV{PORT_AHOY},
		ip => $domain,
		secret => $secret,
		nic => $nic,
		project => $project,
		suds => $suds,
		debriefer => $debriefer
	};
	$data->{'peer_signatorial'} = $peer_signatorial if length $peer_signatorial;
	return $data;
}

# Does a ticket row's stored image hold a real PNG? The updater repairs a row
# only when it does not - a good QR is never rewritten. File-private: a `sub` at
# column 0 is a Manager helper by contract (and the name index must list it), and
# this is reachable only from the updater below, so it is a lexical.
my $ticket_image_is_png = sub ($image) {
	return 0 unless defined $image && length $image;
	return 0 unless $image =~ m{^data:image/png;base64,([A-Za-z0-9+/=]+)$};
	my $head = decode_base64(substr($1, 0, 8));
	return (length $head >= 4 && substr($head, 0, 4) eq "\x89PNG") ? 1 : 0;
};

sub qrcode_updater($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = $c->param('timestamp');
	my $q = &subs::db_query('select * from tickets');
	my $tickets = $q->hashes;
	my $level_one_q = &subs::db_query('select timestamp from security where level=1 order by timestamp DESC limit 1');
	my $level_one = $level_one_q->hashes;

	foreach my $t ( @{$tickets} ) {
		# a request (or anything else that was never minted) has no secret to
		# re-encrypt; decoding its empty one used to die and take the whole
		# box office down with it
		next unless $t->{'secret'} && $t->{'password'};
		my $secretive = $t->{'secret'};
		my $ver = url_unescape `echo "$secretive" | base64 --decode`;
		my $ts = &subs::note_decrypter($t->{'password'},$ver);

		my $sj = decode_json $ts;
		my $secret_json = encode_json $sj;
		my $secret = &subs::note_encrypter($t->{'password'}, $secret_json);
		$secret = url_escape `echo "$secret" | base64 -w 0`;
		my $x = &subs::device_lister($timestamp, '')->[0]->{'address'};
		# A pass minted where qrencode was missing holds a blank image; its link is
		# the credential and the QR is how it is shown, so repair it here, on the
		# visit that reads the desk, rather than only when the row's port or key
		# age happens to ask for a re-encrypt. A good QR is never rewritten.
		if (defined $t->{'uuid'} && !$ticket_image_is_png->($t->{'image'})) {
			my $ip = (ref $x eq 'HASH' && $t->{'nic'} && $x->{$t->{'nic'}}) ? $x->{$t->{'nic'}}->{'ip'} : '';
			my $url = 'https://' . $ip . ':' . $ENV{'PORT_DOCK'} . '/box_office/' . $t->{'uuid'} . '?s=' . $secret;
			my $qr = qx/qrencode -o - "\$url"/;
			if (defined $qr && length $qr && substr($qr, 0, 4) eq "\x89PNG") {
				&subs::db_update('tickets', {
					image => 'data:image/png;base64,' . encode_base64($qr, ''),
					server_time => &subs::rightNow()
				}, { uuid => $t->{'uuid'} });
			}
		}
		if ( $t->{'port'} ne $ENV{PORT_AHOY} || $level_one->[0]->{'timestamp'} >= $t->{'server_time'}) {
		#	$sj->{'ts'} = &subs::rightNow();
			&subs::db_update('tickets', {
				ip => $x->{$t->{'nic'}}->{'ip'},
				# the repair above owns the image; this write never touches it
				port => $ENV{PORT_AHOY},
				server_time => &subs::rightNow(),
			#	secret => $secret,
			},
			{ uuid => $t->{'uuid'} });
		}
	}
}

sub random_word_grabber($times) {
	$times = $times || 2;
	my ($db,$database,$sql) = &subs::database_grabber();

	my $sentence;
	for (my $t = 0; $t < $times; $t++) {
		my $labour = '%';
		foreach my $n ( 0..3 ) {
			my $r1 = &subs::random_string_creator(100);
			$r1 =~ s/[^0-9]//gi;

			my @r2 = split "", $r1;

			$labour .= $r2[0] . '%';
		}
		$labour .= '%';
		my $query = &subs::db_query('select app from appointments order by random() LIMIT 50');
		my $apps = $query->hashes;
		my @words;
		foreach my $a ( @{$apps} ) {

			my @split = shuffle split '_', $a->{'app'};
			foreach my $sp ( @split ) {
				push @words,$sp if $sp !~ /[^a-zA-z]/;
			}
		}
		@words = shuffle @words;
		$sentence .= $words[rand(50)];
		$sentence .= ' ' if $times > 1;
	}
	return $sentence;
};

# A ticket's stored image is a PNG data URI or it is nothing: a phone runtime
# without qrencode stored 'data:image/png;base64,' with an empty body, so a
# length test is not enough. qrcode_updater uses this to decide whether a row
1;
