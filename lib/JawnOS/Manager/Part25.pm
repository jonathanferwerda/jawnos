package Manager;

# Manager helpers, part 25 of 37. Moved out of Manager.pl so a
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

sub mail_checker($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $incoming_data = eval { return decode_json $c->param('incoming_data') } || {};
	my $pre_settings = $incoming_data->{'settings'} || [];
	foreach my $ps ( @{$pre_settings} ) {
		$log->info('setting ' . $ps->{'setting'} . ' to ' . $ps->{'value'} );
		&subs::setting_setter({ app => 'mail', setting => $ps->{'setting'}, value => $ps->{'value'} });
	}

	# The Email app owns exactly one section and never shows the umbrella's
	# conversation, its dials, its friends list or the tickets. Building all of that
	# - the ticket scan, the social-construct walk and, above all, the conversation
	# rows (which decrypt thirty bodies and re-send each over the socket) - is waste
	# on every open, and it is what made the window take seconds to appear. Scope
	# email takes a short path that builds only what apps/email.html.ep reads.
	my $scope = $c->stash('mail_scope') || $c->param('scope');
	if ($scope && $scope eq 'email') {
		my $settings = &subs::settings_grabber({ app => 'mail' });
		$settings->{'subsection'} = 'email';
		my $contents = $c->render_to_string(
			template => 'apps/email',
			mail => [],
			sms_lines => [],
			window_maker => $c->param('window_maker'),
			settings => $settings,
			scope => 'email',
			scope_sections => [ 'email' ],
			mail_email => $c->param('email'),
			email_counts => &email_folder_counts(),
			email_extra_folders => &email_extra_folders(),
			email_sort => &email_sort(),
			incoming_data => $incoming_data,
		);
		return { contents => $contents, mail => [] };
	}



	my $bgc = &subs::setting_grabber({ app => 'misc', setting => 'mail_sidebar_container_background_colour', device => $device });
	my $contacters = &subs::db_query('select * from tickets order by server_time desc');
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $contacts = $contacters->hashes;
	my $picker = eval { return decode_json $c->param('picker') } || {};
	my $settings = &subs::settings_grabber({ app => 'mail' });
	my $privilege = $c->session('privilege');
	# Chat's LoRa mode: the non-secret settings plus the webhook address a
	# network server (TTN, ChirpStack, Helium) posts uplinks to. Kept out of the
	# Mailbox umbrella; only the Chat app renders the panel.
	my $lorawan = ($scope && $scope eq 'chat') ? &lorawan_public_settings($c) : undef;
	my $dialled = &mailws_picker_dialled($picker);
	my $channel_key = $dialled ? &mail_channel_key(&mailws_constructs($picker)) : '';
	my $channel_public = $dialled ? &mail_public_channel_allows($picker) : 0;
	my $me = &manager_file_maker($c->session('name'));
	$settings->{'mail_config'} = eval {return decode_json $settings->{'mail_config'} } || {};
	foreach my $contact ( @{$contacts} ) {
		# the person the ticket names, not the session that carries it: the friends
		# list joins a ticket to a friend by this, the tickets section shows it,
		# and the ticket thread's re-key looks the person's phone up by it (the
		# manager-file string these used to carry matched none of those)
		$contact->{'contact_name'} = &subs::format_name($contact->{'name'} || '');
		$contact->{'app'} = &subs::unformat_name($contact->{'name'} || '');
	}
	my $contact = $c->param('mail_contact');
	my $phone = $c->param('phone');
	my $email = $c->param('email');
	my $main_title;
	if ($privilege eq 'guest') {
		# a guest's dial is honoured only when the house advertises it; any
		# other dial puts them back on the ticket thread the house opened
		if ($dialled && $channel_public) {
			$contact = undef;
		}
		else {
			$dialled = 0;
			$channel_key = '';
			$contact = $c->session('ticket_uuid');
		}
		# a guest speaks through the box, not a phone or a mailbox server
		$phone = undef;
		$email = undef;
	}
	elsif ($privilege eq 'resident' && $dialled) {
		# a resident's dial is the thread they mean to read
		$contact = undef;
		$phone = undef;
		$email = undef;
	}
	if ($privilege ne 'citizen') {
		# a visitor has one dial, not the house's sections
		$settings->{'subsection'} = 'dial';
	}
	my $last_sc;
	my $chatbot_models;

	foreach my $scons ( sort { $a->{'order'} <=> $b->{'order'} } values %{$gb::social_constructs} ) {
		my $sc = $scons->{'name'};
		if (1 == 1 || $scons->{'order'} == 0 || scalar @{$gb::social_constructs->{$last_sc}->{'list'}} > 0) {
			my $construct = &subs::db_query('select * from settings where (setting=? or setting =?) and value=?', 'pos', 'mab', $gb::social_constructs->{$sc}->{'sing'});
			$gb::social_constructs->{$sc}->{'list'} = $construct->hashes;
			$gb::social_constructs->{$sc}->{'value'} = $picker->{$sc};
			$last_sc = $sc;
		}
	}
	my $list = [];
	my $q;
	my @selection = split '---', $settings->{'mail_list'};
	# An app that owns one section of the mailbox (email, messages, chat, lora,
	# pen) opens on its own section and hides the umbrella's switcher. The scope is
	# per request, so the shared 'mail' subsection setting is left alone and the
	# umbrella keeps working while the sections move out one at a time.
	my @scope_sections = ($scope && $privilege ne 'guest') ? &mail_scope_sections($scope) : ();
	unless (grep { $_ eq $settings->{'subsection'} } @scope_sections) {
		$settings->{'subsection'} = $scope_sections[0] if @scope_sections;
	}

	# Chat's friends: the people the house knows (each a named person with at least
	# one line), joined to a ticket when one is open in their name, so one row per
	# friend carries every road they can be reached on. The number is the thread
	# until they hold a ticket; then the ticket is. Every line the person keeps -
	# the plain phone row and the typed list beside it - rides the one row.
	my $friends = [];
	if ($scope && $scope eq 'chat' && $privilege eq 'citizen') {
		my %ticket_by_app;
		foreach my $t ( @{$contacts} ) { $ticket_by_app{lc($t->{'app'} || $t->{'name'} || '')} ||= $t->{'uuid'}; }
		my $lines = &subs::contact_lines('phone');
		foreach my $app ( keys %{$lines} ) {
			my @l = @{ $lines->{$app} };
			next unless scalar @l;
			push @{$friends}, {
				app => $app,
				contact_name => $app,
				phone => $l[0]->{'value'},
				numbers => \@l,
				uuid => ($ticket_by_app{lc($app)} || '')
			};
		}
	}

	# Chat's recent list: the conversations that have actually spoken lately,
	# newest first. It is built from the mailbox rather than the friends list so a
	# thread still shows after its person is renamed or its ticket closes; a
	# person's ticket thread and the sms filed under their number are one row
	# because the same friend row joins them. A phone row is labelled by the
	# number's own app (a stranger's digits until the house names them).
	my $recent_chats = [];
	if ($scope && $scope eq 'chat' && $privilege eq 'citizen') {
		my %ticket_by_app;
		my %ticket_by_uuid;
		foreach my $t ( @{$contacts || []} ) {
			$ticket_by_uuid{$t->{'uuid'}} = $t;
			my $key = lc($t->{'app'} || $t->{'contact_name'} || $t->{'name'} || '');
			$ticket_by_app{$key} ||= $t if length $key;
		}
		my $rows = &subs::db_query(
			"select uuid, timestamp, server_time, status, phone, contact, body, manager_file, ost
			 from mailbox
			 where coalesce(status,'') not in ('ignored','draft')
			   and coalesce(contact,'') != 'pen'
			   and ((phone is not null and phone != '') or (contact is not null and contact != ''))
			 order by rowid desc limit 2000"
		)->hashes;
		my %best;
		foreach my $r ( @{$rows} ) {
			my $contact = $r->{'contact'} || '';
			my $ph = $r->{'phone'} || '';
			next if $contact eq 'pen';
			my ($key, $kind, $section, $uuid, $name, $phone) = ('', '', '', '', '', '');
			if ($contact eq 'lora') {
				$key = 'lora';
				$kind = 'lora';
				$section = 'lora';
				$name = &subs::lang('chat.lora');
			}
			elsif (length $contact && $ticket_by_uuid{$contact}) {
				my $t = $ticket_by_uuid{$contact};
				$key = 'c:' . $t->{'uuid'};
				$uuid = $t->{'uuid'};
				$phone = $ph;
				$kind = 'chat';
				$section = 'tickets';
				$name = &subs::format_name($t->{'name'} || $t->{'contact_name'} || $t->{'app'} || '');
			}
			elsif (length $ph) {
				my @apps = &subs::contact_apps('phone', $ph);
				my ($named) = grep { $_ !~ /^\d+$/ } @apps;
				my $app = $named || $apps[0] || $ph;
				my $t = $ticket_by_app{lc($app)};
				if ($t) {
					$key = 'c:' . $t->{'uuid'};
					$uuid = $t->{'uuid'};
					$phone = $ph;
					$kind = 'chat';
					$section = 'tickets';
					$name = &subs::format_name($t->{'name'} || $t->{'contact_name'} || $t->{'app'} || '');
				}
				else {
					$key = 'p:' . $ph;
					$phone = $ph;
					$kind = 'sms';
					$section = 'sms';
					$name = &subs::format_name($app);
				}
			}
			next unless length $key;
			my $ts = $r->{'timestamp'};
			$ts = 0 unless defined $ts && $ts =~ /^\d+$/ && $ts > 0;
			my $sort = $ts || (($r->{'server_time'} || 0) + 0);
			next if $best{$key} && $best{$key}->{'sort'} >= $sort;
			$best{$key} = {
				key => $key, kind => $kind, section => $section,
				uuid => $uuid, phone => $phone, name => $name,
				sort => $sort, timestamp => $ts || $r->{'server_time'} || '',
				incoming => &subs::mail_message_incoming($r, $me) ? 1 : 0,
				row => $r,
			};
		}
		foreach my $b ( values %best ) {
			my $r = delete $b->{'row'};
			my $body = &mail_text_chars(&subs::note_decrypter(&subs::suds_grabber(), $r->{'body'}, $r->{'ost'}));
			$body =~ s/<br\s*\/?>/ /gi;
			$body =~ s/<[^>]+>//g;
			$body =~ s/\s+/ /g;
			$body =~ s/^\s+|\s+$//g;
			$body = substr($body, 0, 90) . (length($body) > 90 ? '…' : '');
			$b->{'preview'} = $body;
		}
		$recent_chats = [ sort { ($b->{'sort'} || 0) <=> ($a->{'sort'} || 0) } values %best ];
		splice(@{$recent_chats}, 12) if scalar @{$recent_chats} > 12;
	}

	if ($settings->{'subsection'} eq 'list') {
		# The list is every distinct address tuple the mailbox holds, built from
		# whatever $gb::social_constructs names today, so adding or retiring a
		# construct needs no change here.
		my @cols = &mail_construct_columns();
		my @groups = sort keys %{$gb::social_constructs};
		my $not_null = join ' and ', map { "$_ is not null" } @cols;
		my $listing = &subs::db_fresh("select * from mailbox where timestamp < ? and $not_null order by timestamp desc", $timestamp);
		foreach my $l ( @{$listing} ) {
			my $seen = 0;
			foreach my $sc ( @groups ) {
				my $sing = $gb::social_constructs->{$sc}->{'sing'};
				my @ls = grep { ($_->{$sing} // '') eq ($l->{$sing} // '') } @{$list};
				if (scalar @ls > 0) { $seen++; }
			}
			if ($seen < scalar @groups) {
				# the trailing separator is part of the key's shape; a list row's
				# uuid must match what mail_channel_key and the stored configs use
				my $uuid = join '', map { ($l->{$_} // '') . '---' } @cols;
				$l->{'uuid'} = $uuid;
				$l->{'config'} = $settings->{'mail_config'}->{$uuid};
				push @{$list}, $l;
			}
		}

		# a saved list written before this build carries the retired tuple; it
		# no longer names a row, so a count that does not match falls back to
		# the defaults rather than binding values into the wrong columns
		my %picked;
		@picked{@groups} = @selection if scalar @selection == scalar @groups;
		my $where = join ' and ', map { "$_ = ?" } @cols;
		my @values = map { $picked{$_} || $gb::social_constructs->{$_}->{'def'} } @groups;
		$q = &subs::db_fresh("select * from mailbox where timestamp < ? and $where and contact is null order by timestamp desc LIMIT 30",
			$timestamp,
			@values,
		);
		$main_title = join ' ', map { &subs::format_name(&subs::shorthand_name($_, 50)) }
			map { $picked{$_} || $gb::social_constructs->{$_}->{'def'} }
			map { $_->{'name'} } sort { $a->{'order'} <=> $b->{'order'} } values %{$gb::social_constructs};
	}
	elsif ($settings->{'subsection'} eq 'pen') {

	  $chatbot_models = &subs::pen_model_list();
		push @{$chatbot_models}, @{&subs::cloudflare_model_list()};
		$q = &subs::db_fresh('select * from mailbox where timestamp < ? and contact = ? and conversation_uuid = ? order by timestamp desc LIMIT 30', $timestamp, 'pen', $settings->{'chatbot_conversation'});
		&subs::db_query('delete from mailbox where contact = ? and conversation_uuid is null', 'pen');
		$main_title = 'Pen';
	}
	elsif ($settings->{'subsection'} eq 'lora') {
		$q = &subs::db_fresh('select * from mailbox where timestamp < ? and contact = ? order by timestamp desc LIMIT 30', $timestamp, 'lora');
		$main_title = 'LoRa';
	}
	elsif ($phone) {
		$phone =~ s/\D+//gi;
		$phone =~ s/^1//;
		$q = &subs::db_fresh('select * from mailbox where timestamp < ? and phone = ? and coalesce(status, \'\') != \'ignored\' order by timestamp desc LIMIT 30', $timestamp, $phone);
		$main_title = &subs::format_name(&subs::db_select('settings', undef, { setting => 'phone', value => $phone })->hashes->[0]->{'app'}) . ' ' . $phone;
	}
	elsif ($email) {
		$q = &subs::db_fresh('select * from mailbox where timestamp < ? and email = ? order by timestamp desc LIMIT 30', $timestamp, $email);
		$main_title = &subs::format_name(&subs::db_select('settings', undef, { setting => 'email', value => $email })->hashes->[0]->{'app'}) . ' ' . $email;
	}
	elsif ($contact) {
		my @cont = grep { $_->{'uuid'} eq $contact } @{$contacts};
		$main_title = &subs::format_name($cont[0]->{'name'});
		# history that was once filed under any of the person's lines joins their
		# one thread, so a conversation started over sms - on the plain number or an
		# extra one - continues in chat and back without splitting (rows the live
		# path files already carry both)
		my $c_app = $cont[0]->{'app'} || $cont[0]->{'contact_name'} || '';
		my $clines = &subs::contact_lines('phone', $c_app);
		foreach my $l ( @{ $clines->{$c_app} || [] } ) {
			my $pn = $l->{'value'};
			$pn =~ s/\D+//g;
			$pn =~ s/^1//;
			next unless $pn;
			&subs::db_query('update mailbox set contact = ? where contact is null and phone = ?', $contact, $pn);
		}
		$q = &subs::db_fresh('select * from mailbox where timestamp < ? and contact = ? and coalesce(status, \'\') != \'ignored\' order by timestamp desc LIMIT 30', $timestamp, $contact);
	}
	else {
		# the tuple is whatever the registry says now: a dial with a picker
		# hidden still reaches the default thread, and a new construct needs no
		# branch here
		my @cols = &mail_construct_columns();
		my $where = join ' and ', map { "$_ = ?" } @cols;
		my $constructs = &mailws_constructs($picker);
		$q = &subs::db_fresh("select * from mailbox where timestamp < ? and coalesce(status, '') != 'ignored' and $where order by timestamp desc LIMIT 30",
			$timestamp,
			map { $constructs->{$_} } sort keys %{$gb::social_constructs},
		);
		$main_title = join ' ', map { &subs::format_name($constructs->{$_->{'name'}}) }
			sort { $a->{'order'} <=> $b->{'order'} } values %{$gb::social_constructs};
	}
	my $mails = ref($q) eq 'ARRAY' ? $q : ($q ? $q->hashes : []);
	&subs::subprocessor(sub {
		foreach my $m ( @{$mails} ) {
			# A public row is a word the house heard and may file. For an sms the
			# phone wrote, the status is the direction: filing it as 'sent' (as the
			# depublicizer used to) drew both halves of the thread as the house's
			# own. Keep the incoming text incoming, and seal a plain body on the
			# way so the next read can open it.
			if ($m->{'status'} eq 'public' && $c->session('privilege') eq 'citizen') {
				if ($m->{'phone'}) {
					my $incoming = &subs::mail_message_incoming($m, $me);
					my $body = &mail_text_chars(&subs::note_decrypter(&subs::suds_grabber(),$m->{'body'},$m->{'ost'}));
					$body = $m->{'body'} unless length $body;
					$m->{'body'} = $body;
					$m->{'status'} = $incoming ? 'inbox' : 'sent';
					&subs::db_query('update mailbox set status=?, body =? where uuid =?', $m->{'status'}, &subs::note_encrypter(&subs::session_suds($c), $body, $m->{'timestamp'}), $m->{'uuid'});
				}
				else {
					&subs::db_query('update mailbox set status=?, body =? where uuid =?', 'sent', &subs::note_encrypter(&subs::session_suds($c), $m->{'body'}, $m->{'timestamp'}), $m->{'uuid'});
				}
			}
			else {
				$m->{'body'} = &mail_text_chars(&subs::note_decrypter(&subs::suds_grabber(),$m->{'body'},$m->{'ost'}));
			}
			if ($m->{'subject'}) {
				$m->{'subject'} = &mail_text_chars(&subs::note_decrypter(&subs::session_suds($c),$m->{'subject'},$m->{'ost'}));
			}

			if ($m->{'phone'} && $m->{'status'} eq 'sent') {
				$m->{'manager_file'} = $me;
			}
			# The body is decrypted for the person, not for the log.
			$log->info('mail view ' . ($m->{'uuid'} // '?') . ' ' . length($m->{'body'} // '') . ' bytes');
			$m->{'decrypted'} = 'yes';
			my $content = $c->render_to_string(
				template => 'mail/message',
				'm' => $m,
				me => $me
			);
			&Websocket::send('tab', {  type => 'mailbox_message', selector => '.mailbox_message[uuid="' . $m->{'uuid'} . '"]', content => $content, browser_tab_id => $c->param('browser_tab_id') });
		}
	}, { name => 'mail message processor', sync => 1 });
	# the advertised dials, each carrying its label and comparison key so the
	# template can list a house's public face without walking the tuples itself
	my $channel_list = [];
	foreach my $ch ( @{&mail_public_channels()} ) {
		push @{$channel_list}, { %{$ch}, label => &mail_channel_label($ch), key => &mail_channel_key($ch), picker => encode_json $ch };
	}
	# The person's lines, for the sms road in Chat: the conversation is theirs, so
	# the transport dropdown offers sms once per number they keep (their work line
	# as well as their mobile) and the next text goes to the chosen one. The ticket
	# names the person when the thread is a ticket; otherwise the number does.
	my @sms_lines;
	if ($scope && $scope eq 'chat') {
		my $person_app = '';
		if ($contact) {
			my ($cc) = grep { $_->{'uuid'} eq $contact } @{$contacts};
			$person_app = $cc ? ($cc->{'app'} || $cc->{'contact_name'} || '') : '';
		}
		elsif ($phone) {
			my @apps = &subs::contact_apps('phone', $phone);
			# a number both a stranger's own app and a named person hold is the person's:
			# the number-app is only the fallback for a number nobody has named
			my ($named) = grep { $_ !~ /^\d+$/ } @apps;
			$person_app = $named || $apps[0] || '';
		}
		if ($person_app) {
			my $clines = &subs::contact_lines('phone', $person_app);
			@sms_lines = map { { value => $_->{'value'}, display => &subs::contact_line_label($_) } } @{ $clines->{$person_app} || [] };
		}
	}
	my $combined_data = {
		template => ($scope && $scope eq 'email') ? 'apps/email' : ($scope && $scope eq 'chat') ? 'apps/chat' : ($scope && $scope eq 'pen') ? 'apps/pen' : 'mail/mailbox',
		mail => $mails,
		friends => $friends,
		recent_chats => $recent_chats,
		sms_lines => \@sms_lines,
		window_maker => $c->param('window_maker'),
		background_colour => $bgc,
		contacts => $contacts,
		sc => ($privilege eq 'citizen' ? $gb::social_constructs : {}),
		public_channels => $channel_list,
		channel_key => $channel_key,
		channel_public => $channel_public,
		mail_contact => $c->param('mail_contact'),
		mail_phone => $phone,
		mail_email => $email,
		config => &subs::config_reader(),
		device => $device,
		settings => $settings,
		scope => $scope,
		scope_sections => [@scope_sections],
		email_counts => (($scope && $scope eq 'email') ? &email_folder_counts() : {}),
		email_extra_folders => (($scope && $scope eq 'email') ? &email_extra_folders() : []),
		email_sort => (($scope && $scope eq 'email') ? &email_sort() : {}),
		list => $list,
		me => $me,
		incoming_data => $incoming_data,
		main_title => $main_title,
		lorawan => $lorawan,
		chatbot_models => $chatbot_models
	};

	my $contents = $c->render_to_string(
		%{$combined_data}
	);

	return { contents => $contents, mail => $mails };
}

sub travel_nearby_items {
	my (%p) = @_;
	my $lat = 0 + ($p{'lat'} || 0);
	my $lon = 0 + ($p{'lon'} || 0);
	return [] unless $lat || $lon;
	my $radius = 0 + ($p{'radius'} || 300);
	$radius = 50 if $radius < 10;
	$radius = 2000 if $radius > 2000;
	my $window = 0 + ($p{'window'} || 1800000); # 30 minutes either side
	my $limit = int($p{'limit'} || 1000);
	$limit = 1000 if $limit < 1 || $limit > 3000;

	# the ground the map is showing, when the caller names it: only pictures taken
	# inside that box are returned, so panning or zooming changes the set
	my ($nw_lat, $nw_lon, $se_lat, $se_lon) = @p{qw(nw_lat nw_lon se_lat se_lon)};
	my $boxed = (defined $nw_lat && defined $nw_lon && defined $se_lat && defined $se_lon)
		&& abs($nw_lat) <= 90 && abs($se_lat) <= 90 && abs($nw_lon) <= 180 && abs($se_lon) <= 180;
	my ($min_lat, $max_lat, $min_lon, $max_lon);
	if ($boxed) {
		($min_lat, $max_lat) = ($nw_lat < $se_lat) ? ($nw_lat, $se_lat) : ($se_lat, $nw_lat);
		($min_lon, $max_lon) = ($nw_lon < $se_lon) ? ($nw_lon, $se_lon) : ($se_lon, $nw_lon);
	}
	else {
		my $cos = cos($lat * 3.14159265358979 / 180);
		$cos = 0.000001 if abs($cos) < 0.000001;
		my $dlat = $radius / 111320;
		my $dlon = $radius / (111320 * $cos);
		$min_lat = $lat - $dlat; $max_lat = $lat + $dlat;
		$min_lon = $lon - $dlon; $max_lon = $lon + $dlon;
	}
	my $fixes = &subs::db_query('select timestamp, latitude, longitude from continent where cast(latitude as real) between ? and ? and cast(longitude as real) between ? and ?', $min_lat, $max_lat, $min_lon, $max_lon)->hashes;
	my @fix_times;
	foreach my $fix ( @{$fixes} ) {
		if (!$boxed) {
			my $cos = cos($lat * 3.14159265358979 / 180);
			my $dy = (0 + $fix->{'latitude'} - $lat) * 111320;
			my $dx = (0 + $fix->{'longitude'} - $lon) * 111320 * $cos;
			next if (($dx * $dx) + ($dy * $dy)) > ($radius * $radius);
		}
		push @fix_times, 0 + $fix->{'timestamp'};
	}
	return [] unless scalar @fix_times;
	@fix_times = sort { $a <=> $b } @fix_times;

	# the nearest fix in time, by binary search over the sorted list
	my $nearest_gap = sub {
		my ($t) = @_;
		my ($lo, $hi) = (0, scalar(@fix_times) - 1);
		my $pos = scalar(@fix_times);
		while ($lo <= $hi) {
			my $mid = int(($lo + $hi) / 2);
			if ($fix_times[$mid] < $t) { $lo = $mid + 1; }
			else { $pos = $mid; $hi = $mid - 1; }
		}
		my $best;
		foreach my $i ($pos - 1, $pos) {
			next if $i < 0 || $i > $#fix_times;
			my $gap = abs($fix_times[$i] - $t);
			$best = $gap if !defined($best) || $gap < $best;
		}
		return $best;
	};

	my $uenc = sub {
		my $v = shift;
		return '' unless defined $v;
		my $copy = "$v";
		utf8::encode($copy) if utf8::is_utf8($copy);
		return url_escape($copy, '^A-Za-z0-9\-._~/');
	};

	my $rows = &subs::db_query("select * from appointments where file is not null and (type = 'image' or type = 'video') order by cast(timestamp as integer) desc")->hashes;
	my @items;
	foreach my $appt ( @{$rows} ) {
		last if scalar @items >= $limit;
		my $t = 0 + ($appt->{'timestamp'} || 0);
		my $gap = $nearest_gap->($t);
		next unless defined $gap && $gap <= $window;
		my $app = $appt->{'app'} || '';
		next if &subs::app_private_now($app) && !&subs::private_reachable_now();
		# a hidden album is never listed here, and a private row (a private project,
		# club or account) needs the same grant the Gallery asks for
		next if &subs::app_hidden_now($app) || &subs::lockdown_active();
		next if &subs::appointment_private_now($appt) && (!&subs::private_reachable_now() || !&subs::private_revealed());
		my $files = eval { return decode_json $appt->{'file'} } || [];
		foreach my $f ( @{$files} ) {
			last if scalar @items >= $limit;
			my $type = $f->{'type'} || $appt->{'type'} || 'image';
			next unless $type eq 'image' || $type eq 'video';
			my $path = $f->{'f'} || '';
			next unless length $path;
			if (!-e $path) {
				my ($dir, $asset) = &subs::file_device_renamer({ file => $path, app => $app, type => $type });
				my $local = (defined $dir && defined $asset) ? $dir . $asset : '';
				$path = $local if length $local && -e $local;
			}
			next unless -e $path;
			my $thumb_path = $f->{'thumb'} || '';
			if (!length $thumb_path || !-e $thumb_path) {
				my ($tdir, $tasset) = &subs::file_device_renamer({ file => $thumb_path, app => $app, type => $type });
				my $tlocal = (defined $tdir && defined $tasset) ? $tdir . $tasset : '';
				$thumb_path = $tlocal if length $tlocal && -e $tlocal;
			}
			my $thumb_ok = (length $thumb_path && -e $thumb_path && (-s $thumb_path) > 100) ? 1 : 0;
			my $server_time = $f->{'server_time'} || $appt->{'server_time'} || 0;
			my $thumb = '/file_open?file=' . $uenc->($thumb_ok ? $thumb_path : $path)
				. '&app=' . $uenc->($app)
				. '&app_uuid=' . $uenc->($appt->{'uuid'} || '')
				. '&timestamp=' . $uenc->($server_time)
				. ($f->{'uuid'} ? '&file_uuid=' . $uenc->($f->{'uuid'}) : '')
				. ($thumb_ok ? '' : '&thumb=ya');
			push @items, {
				thumb_url => $thumb,
				label => &subs::format_name($f->{'label'} || $app),
				type => $type,
				timestamp => $t,
				f => $path,
				app => $app,
				app_uuid => $appt->{'uuid'} || '',
				uuid => $f->{'uuid'} || '',
				server_time => $server_time,
				info => $f->{'info'} || {},
			};
		}
	}
	return \@items;
}

sub travel_grabber($c) {
	my $timestamp = $c->param('timestamp');


	my $home_plate = &subs::setting_grabber({ app => 'me', setting => 'home_plate' });
	my $settings = &subs::settings_grabber({ app => 'travel' });

	my $home_plate_enabled = $settings->{'home_plate_enabled'};
	# the picker is for the maps we measured: a guessed gap is drawn, but it is not
	# one to select (and it never rides into the settings row of measured maps)
	my $measured = eval { return decode_json $settings->{'maps'} } || [];
	$settings->{'maps'} = [ grep { !$_->{'guessed'} } @{$measured} ];

	my $contents = $c->render_to_string(
		template => '/travel/travel',
		home_plate => $home_plate,
		home_plate_enabled => $home_plate_enabled,
		window_maker => $c->param('window_maker'),
		timestamp => $timestamp,
		settings => $settings
	);
	return $contents;
}

# A map's home plate is its anchor on the globe: a pixel at a latitude/longitude.
# Measuring can also leave it as a named legend instead ("lambton mall") - the
# home_plate setting of the app it names - so fold whichever exists into the
# map's home_plate, and the client has one shape to read. The map is modified in
# place; the resolved plate is returned.
sub travel_map_home_plate {
	my ($map) = @_;
	my $home_plate = $map->{'home_plate'} || {};
	if (!($home_plate->{'latitude'} && $home_plate->{'longitude'}) && $home_plate->{'legend'}) {
		my $plate = eval { return decode_json &subs::setting_grabber({ app => &subs::unformat_name($home_plate->{'legend'}), setting => 'home_plate' }) } || {};
		if ($plate->{'latitude'} && $plate->{'longitude'}) {
			$home_plate->{'latitude'} = $plate->{'latitude'};
			$home_plate->{'longitude'} = $plate->{'longitude'};
		}
	}
	$map->{'home_plate'} = $home_plate;
	return $home_plate;
}

# The ground bounds of a measured map: the latitude/longitude of its top-left and
# bottom-right image pixels, from its home plate and scale bar - the same
# arithmetic the client engine does (mapengine.js mapBounds), here so the server
# can reason about where the maps sit and what lies between them.
sub travel_map_bounds {
	my ($map) = @_;
	my $p = $map->{'home_plate'} || {};
	my $s = $map->{'scale'} || {};
	my $first = $s->{'first'} || {};
	my $last = $s->{'last'} || {};
	my $pi = 3.14159265358979;
	my $lat0 = 0 + ($p->{'latitude'} || 0);
	my $lon0 = 0 + ($p->{'longitude'} || 0);
	my $w = 0 + ($p->{'width'} || 0);
	my $h = 0 + ($p->{'height'} || 0);
	my $legend = 0 + ($s->{'legend'} || 0);
	return undef unless defined $p->{'latitude'} && defined $p->{'longitude'} && $w > 0 && $h > 0 && $legend > 0;
	# the scale bar was recorded in its own pixel space; bring it into the home
	# plate's before measuring (they usually match, but not always)
	my $sdx = (0 + ($s->{'width'} || 0)) > 0 ? $w / (0 + $s->{'width'}) : 1;
	my $sdy = (0 + ($s->{'height'} || 0)) > 0 ? $h / (0 + $s->{'height'}) : 1;
	my $dx = ((0 + ($last->{'x'} || 0)) - (0 + ($first->{'x'} || 0))) * $sdx;
	my $dy = ((0 + ($last->{'y'} || 0)) - (0 + ($first->{'y'} || 0))) * $sdy;
	my $bar = sqrt(($dx * $dx) + ($dy * $dy));
	return undef unless $bar > 0;
	my $ppm = $bar / $legend;
	my $mpd = 6372800 * $pi / 180;
	my $mpd_lon = $mpd * cos($lat0 * $pi / 180);
	my $at = sub {
		my ($px, $py) = @_;
		return {
			lat => $lat0 + ((($p->{'y'} || 0) - $py) / $ppm) / $mpd,
			lon => $lon0 + (($px - ($p->{'x'} || 0)) / $ppm) / $mpd_lon
		};
	};
	return { nw => $at->(0, 0), se => $at->($w, $h) };
}

# Whether the ground at a point is already known: inside any placed map's bounds -
# and, when $with_guesses, inside a guess already drawn, so a pocket is not
# guessed over twice.
sub travel_point_covered {
	my ($placed, $lat, $lon, $with_guesses) = @_;
	foreach my $p ( @{$placed} ) {
		next if !$with_guesses && $p->{'map'}->{'guessed'};
		my $b = $p->{'bounds'};
		return 1 if ($lat <= $b->{'nw'}->{'lat'} && $lat >= $b->{'se'}->{'lat'}
			&& $lon >= $b->{'nw'}->{'lon'} && $lon <= $b->{'se'}->{'lon'});
	}
	return 0;
}

# The largest pocket of unmapped ground inside the view: a coarse grid marks the
# cells whose centre no placed map (or existing guess) covers, and the largest
# all-empty rectangle in it becomes the pocket. A rectangle - not the bounding box
# of a connected region: empty ground that wraps around a map (the corridor beside
# it, the void above it) has a bounding box that swallows the map itself, and a
# guess there would lie under ground we already know. Undef when the view is all
# known ground, or only slivers of it are not.
sub travel_uncovered_pocket {
	my ($placed, $view) = @_;
	my $n = 32;
	my $lat_step = ($view->{'maxLat'} - $view->{'minLat'}) / $n;
	my $lon_step = ($view->{'maxLon'} - $view->{'minLon'}) / $n;
	return undef unless $lat_step > 0 && $lon_step > 0;
	my @empty;
	for my $iy ( 0 .. $n - 1 ) {
		for my $ix ( 0 .. $n - 1 ) {
			my $lat = $view->{'minLat'} + (($iy + 0.5) * $lat_step);
			my $lon = $view->{'minLon'} + (($ix + 0.5) * $lon_step);
			$empty[$iy][$ix] = &travel_point_covered($placed, $lat, $lon, 1) ? 0 : 1;
		}
	}
	# the largest all-empty rectangle: the usual histogram sweep over the rows
	my @height;
	my $best;
	for my $iy ( 0 .. $n - 1 ) {
		for my $ix ( 0 .. $n - 1 ) {
			$height[$ix] = $empty[$iy][$ix] ? (($height[$ix] || 0) + 1) : 0;
		}
		my @stack;   # [ start column, height of the run ], heights rising
		for my $ix ( 0 .. $n ) {
			my $cur = $ix < $n ? ($height[$ix] || 0) : 0;
			my $start = $ix;
			while ( @stack && $stack[-1]->[1] >= $cur ) {
				my ($sx, $sh) = @{ pop @stack };
				$start = $sx;
				my $area = $sh * ($ix - $sx);
				next unless $area >= 4;
				$best = { area => $area, minx => $sx, maxx => $ix - 1, miny => $iy - $sh + 1, maxy => $iy }
					if !$best || $area > $best->{'area'};
			}
			push @stack, [ $start, $cur ];
		}
	}
	# a cell or two of sliver is not worth an image
	return undef unless $best;
	return { %{$best}, n => $n, empty => \@empty };
}

# A grid pocket's cells as a ground box - the grid's own arithmetic, read back.
sub travel_grid_box {
	my ($view, $pocket) = @_;
	my $n = $pocket->{'n'};
	my $lat_step = ($view->{'maxLat'} - $view->{'minLat'}) / $n;
	my $lon_step = ($view->{'maxLon'} - $view->{'minLon'}) / $n;
	return {
		minLat => $view->{'minLat'} + ($pocket->{'miny'} * $lat_step),
		maxLat => $view->{'minLat'} + (($pocket->{'maxy'} + 1) * $lat_step),
		minLon => $view->{'minLon'} + ($pocket->{'minx'} * $lon_step),
		maxLon => $view->{'minLon'} + (($pocket->{'maxx'} + 1) * $lon_step),
	};
}

1;
