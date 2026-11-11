package Manager;

# mail_ws: route actions moved out of Manager.pl, one sub per route so a
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

# WEBSOCKET /mail/ws
sub action_45571 {
	my $c = shift;
	&ws_plain_auth($c);
	my $me = &manager_file_maker($c->session('name'));
	my $browser_tab_id = $c->param('browser_tab_id');

	my $picker = eval { return decode_json $c->param('picker') } || {};
	# One entry per browser tab, carrying the address it is watching: a phone
	# number, an email address, a contact, a guest's ticket, or the social
	# construct tuple a dial or list tab picked. The old registry nested the
	# constructs as hash levels - people->projects->teams->clubs->communities -
	# which left a sender no way to tell one shape from another; the address
	# keeps that nest as plain data instead.
	$gb::mailws->{$browser_tab_id} = {
		tx => $c->tx,
		address => &mailws_address($c, $picker)
	};
	my $name = $c->session('name');
	$c->on(message => sub ($mws, $msg) {
		my $m = decode_json $msg;
		$m->{'uuid'} = &subs::random_string_creator(35);

		if ($m->{'type'} eq 'heartbeat') {
			if ($c->session('privilege') eq 'citizen') {
				my ($db,$database,$sql) = &subs::database_grabber();
				&mail_depublicizer($c);
			}
			if ($c->session('privilege') eq 'guest') {
				# a tune is re-checked for as long as it is held: the house may
				# have taken the advertised dial back, and a guest then slides
				# home to their ticket rather than keeping the channel
				my $entry = $gb::mailws->{$browser_tab_id};
				if ($entry && $entry->{'address'}->{'picker'} && !&mail_public_channel_allows($entry->{'address'}->{'picker'})) {
					$entry->{'address'} = { ticket => $c->session('ticket_uuid') };
				}
			}
			if (scalar @{$m->{'decrypteds'}} > 0) {

				foreach my $d ( @{$m->{'decrypteds'}} ) {
					my $dm = &subs::db_query('select * from mailbox where uuid = ?', $d)->hashes->[0];
					$dm->{'body'} = &mail_text_chars(&subs::note_decrypter(&subs::session_suds($c),$dm->{'body'},$dm->{'ost'}));

					$dm->{'decrypted'} = 'yes';
					my $content = $c->render_to_string(
						template => 'mail/message',
						'm' => $dm,
						me => $me
					);
					&Websocket::send('mailbox', {  type => 'mailbox_message', selector => '.mailbox_message[uuid="' . $dm->{'uuid'} . '"]', content => $content, browser_tab_id => $c->param('browser_tab_id') });
				}
			}
			$mws->send($msg);
		}
		elsif ($m->{'type'} eq 'delete') {
			# only a trusted session may unsend: a visitor's browser can drop
			# what it is showing, but not the house's record of it
			if (&mailws_trusted($c) && $m->{'msg'}->{'uuid'}) {
				&subs::db_delete('mailbox', { uuid => $m->{'msg'}->{'uuid'} });
				my $message = &subs::db_select('mailbox', undef, { uuid => $m->{'msg'}->{'uuid'} })->hashes->[0];
				&deletion_registration({ table => 'mailbox', uuid => $message->{'uuid'}, scope => 'single', server_time => $message->{'server_time'} });
				my $gone = $m->{'msg'}->{'uuid'};
				&Websocket::send('tab', { console => &Websocket::console_command('removeEmail', $gone)});
			}
		}
		elsif ($m->{'type'} eq 'message') {
			$m->{'decrypted'} = 'yes';
			foreach my $strip ( qw/msg manager_file/ ) {
				my $hs = HTML::Strip->new();
				$m->{$strip} = $hs->parse( $m->{$strip} );
				$hs->eof;
			}
			my $manager_file = &manager_file_maker($name);
			$m->{'manager_file'} = $manager_file;
			if ($c->session('privilege') eq 'guest') {
				# a guest may write to a dial the house advertises; any other
				# address falls back to the ticket - the one thread the house
				# opened for them. A guest speaks through the box, never through
				# a phone number, a mailbox server or the Pen.
				my $dialled = eval { return decode_json $m->{'picker'} } || {};
				if (&mail_public_channel_allows($dialled)) {
					$m->{'picker'} = encode_json $dialled;
					$m->{'mail_contact'} = undef;
				}
				else {
					$m->{'mail_contact'} = $c->session('ticket_uuid');
					delete $m->{'picker'};
				}
				$m->{'phone'} = undef;
				$m->{'email'} = undef;
			}
			my $trusted = &mailws_trusted($c);
			# the one thread a guest was invited into - their ticket - is filed
			# like correspondence, while the rooms stay heard-not-kept (below)
			my $filed = $trusted || ($c->session('privilege') eq 'guest' && $m->{'mail_contact'} && $m->{'mail_contact'} eq $c->session('ticket_uuid'));
			if (!$trusted) {
				# a guest's words are not filed, so they are bounded: a length
				# cap and a per-ticket pace that a flood cannot pass
				$m->{'msg'} = substr($m->{'msg'} || '', 0, 4000);
				unless (&mailws_untrusted_throttle($c->session('ticket_uuid') || $browser_tab_id)) {
					$log->info('mail throttle: dropped a guest message on ' . ($browser_tab_id || '?'));
					return;
				}
			}
			$m->{'body'} = $m->{'msg'};
			$m->{'msg'} =~ s/\n/<br>/gi;
			my $e_msg = &subs::note_encrypter(&subs::suds_grabber(),$m->{'msg'});

			my $picker = eval { return decode_json $m->{'picker'} } || {};
			# a phone is stored and read bare (digits only, no leading country
			# code), whatever road wore it - the reader strips the same way, so the
			# thread a message is filed on is the thread that reads it back
			if ($m->{'phone'}) {
				$m->{'phone'} =~ s/\D+//g;
				$m->{'phone'} =~ s/^1//;
			}
			# the social constructs are defaulted the way the mailbox reads them,
			# so a message sent from a tab with its pickers hidden still lands on
			# the thread the reader will open; a message addressed to a phone, an
			# email or a contact keeps its construct columns empty
			my $constructs = &mailws_constructs($picker);
			if ($m->{'mail_contact'} || $m->{'phone'} || $m->{'email'}) { $constructs = {}; }
			# the row's construct columns, named from the same registry the
			# reader queries with, so a new construct lands in its own column
			my %construct_columns;
			foreach my $k ( keys %{$gb::social_constructs} ) {
				$construct_columns{ $gb::social_constructs->{$k}->{'sing'} } = $constructs->{$k};
			}
			my ($db,$database,$sql) = &subs::database_grabber();
			# the house encrypts files at rest and renames them, so the paths the
			# page sent are stale by the time the message files: each attachment's
			# current paths are read from the upload's filing (by file uuid)
			my $m_attachments = undef;
			if (ref $m->{'attachments'} eq 'ARRAY' && scalar @{$m->{'attachments'}} > 0) {
				my @atts;
				foreach my $att ( @{$m->{'attachments'}} ) {
					my ($f, $thumb, undef) = &attachment_resolve($att);
					$att->{'f'} = $f if $f;
					$att->{'thumb'} = $thumb if $thumb;
					push @atts, $att;
				}
				$m_attachments = encode_json \@atts;
			}
			my $msg = {
				uuid => $m->{'uuid'},
				timestamp => $m->{'timestamp'},
				server_time => &subs::rightNow(),
				body => $e_msg,
				%construct_columns,
				manager_file => $m->{'manager_file'},
				status => 'sent',
				contact => $m->{'mail_contact'},
				phone => $m->{'phone'},
				email => $m->{'email'},
				conversation_uuid => $m->{'conversation_uuid'},
				attachments => $m_attachments
			};
			# filed words are stored; a visitor's room words are only ever heard
			# live by whoever is tuned in, so they are never written down
			&subs::db_insert('mailbox', $msg) if $filed;
			$m->{'ephemeral'} = 'yes' unless $filed;
			$m->{'envelope'} = $c->render_to_string(
				template => 'mail/message',
				'm' => $m,
				'me' => $me
			);
			# one sender carries the message to every address shape the registry
			# can hold: a phone number, an email address, a contact (a ticket or
			# the pen), a guest's ticket, or the nested social construct chain a
			# dial or list tab is watching
			&mailws_sender($m);
			if ($trusted && $m->{'phone'}) {
				# the phone wants the words, not the display copy: msg wears <br>
				# for the thread, body (set above, before that) is the raw text,
				# minus the trailing newline Enter left in the composer
				my $sms_msg = $m->{'body'} || $m->{'msg'};
				$sms_msg =~ s/\n+$//;
				# A picture is one message, not two: the words ride the mms as its
				# text part instead of also going out as a separate text (the
				# system thread showed a text bubble and a picture bubble for the
				# one thing the person sent).
				my $rides_mms = (ref $m->{'attachments'} eq 'ARRAY' && scalar @{$m->{'attachments'}} > 0);
				&sms_message_send($m->{'phone'}, $sms_msg) unless $rides_mms;
				if ($rides_mms) {
					my $mms = &sms_mms_relay($m->{'phone'}, $sms_msg, $m->{'attachments'}, $m->{'uuid'});
					$log->info('mms relay: ' . ($mms->{'via'} || $mms->{'error'} || '?'));
					if ($mms->{'mms_id'}) {
						&subs::db_update('mailbox', &sms_mms_row_link($mms->{'mms_id'}, $mms->{'mms_date'}), { uuid => $m->{'uuid'} });
						$log->info('mms system id ' . $mms->{'mms_id'} . ' linked to ' . $m->{'uuid'});
					}
				}
			}
			elsif ($trusted && ($m->{'transport'} // '') eq 'lora') {
				# the LoRaWAN uplink can take a few seconds (join, duty cycle, the
				# receive windows), so it leaves the socket's turn to a worker
				my $lora_msg = $m->{'body'} || $m->{'msg'} || '';
				$lora_msg =~ s/\n+$//;
				if (length $lora_msg) {
					&subs::subprocessor(sub {
						Mojo::IOLoop->reset;
						my $res = &lorawan_send_text($lora_msg);
						$log->info('lorawan send: ' . encode_json($res));
					}, { name => 'lorawan send' });
				}
			}
			if ($m->{'mail_contact'} && $m->{'mail_contact'} eq 'pen') {
				my $mesg = {
					uuid => &subs::random_string_creator(25),
					conversation_uuid => $m->{'conversation_uuid'},
					timestamp => &subs::rightNow(),
					server_time => &subs::rightNow(),
					manager_file => &subs::manager_file_maker('pen'),
					status => 'public',
					contact => 'pen'
				};
				&subs::db_query('delete from mailbox where contact = ? and conversation_uuid is null', 'pen');
				&subs::db_insert('mailbox', $mesg);
				&subs::subprocessor(sub {
					$m->{'msg_data'} = $mesg;
					$m->{'uuid'} = $mesg->{'uuid'};
					my ($response_text,$attachments) = &subs::pen_message($m);
					&subs::db_update('mailbox', {
						body => $response_text,
						status => 'public',
						server_time => &subs::rightNow(),
						attachments => encode_json $attachments
					}, { uuid => $mesg->{'uuid'} });
					# the envelope delivered now must wear the reply: the template reads
					# $mesg (not the row just written), so without this the live reply
					# is blank and only the depublicizer's later pass carries the text
					$mesg->{'body'} = $response_text;
					$mesg->{'decrypted'} = 'yes';
					$log->info('mail reply for ' . ($mesg->{'uuid'} // 'unknown'));
					my $returner = encode_json $mesg;
					print $returner;
					$mesg->{'envelope'} = $c->render_to_string(
						template => 'mail/message',
						'm' => $mesg,
						'me' => $me
					);
					$mesg->{'type'} = 'message';
					&Websocket::mail_send($mesg);

					&subs::db_query('delete from mailbox where contact = ? and conversation_uuid is null', 'pen');

				}, { name => 'Mail Assistant' });
				$mesg->{'envelope'} = $c->render_to_string(
					template => 'mail/message',
					'm' => $mesg,
					'me' => $me
				);
				$mesg->{'type'} = 'message';
				# the placeholder wears the pen's own contact address; the reply
				# comes back from the forked worker over the mail socket
				&mailws_sender($mesg);
			}
			elsif (!$m->{'phone'} && !$m->{'email'} && !$m->{'mail_contact'}) {
				my $mail_msg = {
					uuid => $m->{'uuid'},
					timestamp => $m->{'timestamp'},
					server_time => &subs::rightNow(),
					body => $m->{'msg'},
					%construct_columns,
					manager_file => $m->{'manager_file'},
					status => 'public',
					contact => $m->{'mail_contact'},
					phone => $m->{'phone'},
					email => $m->{'email'},
					# an unfiled letter travels the mesh marked ephemeral: the
					# machines that catch it deliver it live and keep nothing
					ephemeral => ($trusted ? undef : 'yes')
				};
				my $remote_machines = &subs::db_select('remote_machines', undef, { connection => 'active' })->hashes;
				my $form_data = {
					signatorial => &subs::signatorial_designer(),
					msg => encode_json $mail_msg
				};
				foreach my $rm ( @{$remote_machines} ) {
					&subs::subprocessor(sub {
				    Mojo::IOLoop->reset;

						$rm = &remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
						my $url = $rm->{'manager'} . '/mail/msg';
						my $res = $rm->{'ua'}->post($url => form => $form_data)->result;
						if ($res->is_success) {

						}
					}, { name => 'embedded mail msg' });
					if ($trusted && &subs::setting_grabber({ app => 'mail', setting => 'lora_toggle' }) eq 'on') {
						foreach my $device_type ( qw/watch teletype microcontroller/ ) {
							my $chips = &subs::device_lister(&subs::rightNow(), $device_type, undef, 'all');
							foreach my $watch ( @{$chips} ) {
								if (eval {$watch->{'ip'} }) {
									my $watch_port = $ENV{PORT_ARM};
									my $ws_port = $ENV{PORT_MSG};
									my $od = &subs::setting_grabber({ app => 'watch', setting => 'operator_door' });
									my $op_d = eval { decode_json $od } || {};
									my $secret = &subs::note_encrypter($op_d->{'__shutup'}->{'patience'}, &subs::session_suds($c));
									$secret = encode_base64($secret // '', '');
									my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/chat_received?s=' . $secret . '&timestamp=' . $m->{'timestamp'} . '&uuid=' . $m->{'uuid'};

									my $ping_ip = $watch->{'ip'};
									my $ping_test = '';
									if (&subs::peer_host_is_literal($ping_ip) && open(my $ping_fh, '-|', 'timeout', '.2', 'ping', '-c', '1', $ping_ip)) {
										local $/;
										$ping_test = <$ping_fh> // '';
										close $ping_fh;
									}
									if ($ping_test =~ /ttl/gi) {
										&subs::subprocessor(sub {
									    Mojo::IOLoop->reset;

											my $ua = Mojo::UserAgent->new();
											my $res = $ua->insecure(1)->get($watch_home)->result;
										}, { name => 'lora embedded sender' });
									}
								}
							}
						}
					}
				}

			}
			&mail_depublicizer($c) if $trusted;
		}
		elsif ($m->{'type'} eq 'refresher') {
			my ($db,$database,$sql) = &subs::database_grabber();
			# the tab's own address is the thread to catch up on - the client
			# sends nothing but the timestamp of the last message it saw
			my $address = $gb::mailws->{$browser_tab_id}->{'address'} || {};
			my $picker = $address->{'picker'} || {};
			my $last_message = $m->{'last_message'} || 0;
			my $q;
			if ($address->{'phone'}) {
				$q = &subs::db_fresh('select * from mailbox where timestamp > ? and phone = ? and coalesce(status, \'\') != \'ignored\' order by timestamp desc LIMIT 20', $last_message, $address->{'phone'});
			}
			elsif ($address->{'email'}) {
				$q = &subs::db_fresh('select * from mailbox where timestamp > ? and email = ? order by timestamp desc LIMIT 20', $last_message, $address->{'email'});
			}
			elsif ($address->{'contact'} || $address->{'ticket'}) {
				my $contact = $address->{'contact'} || $address->{'ticket'};
				$q = &subs::db_fresh('select * from mailbox where timestamp > ? and contact = ? and coalesce(status, \'\') != \'ignored\' order by timestamp desc LIMIT 20', $last_message, $contact);
			}
			else {
				my @cols = &mail_construct_columns();
				my $where = join ' and ', map { "$_ = ?" } @cols;
				my $constructs = &mailws_constructs($picker);
				$q = &subs::db_fresh("select * from mailbox where timestamp > ? and coalesce(status, '') != 'ignored' and $where order by timestamp desc LIMIT 20",
					$last_message, map { $constructs->{$_} } sort keys %{$gb::social_constructs}
				);
			}
			my $messaging = ref($q) eq 'ARRAY' ? $q : $q->hashes;
			foreach my $mess ( @{$messaging} ) {
				if ($mess->{'status'} eq 'public' && $c->session('privilege') eq 'citizen') {
					&subs::db_query('update mailbox set status=?, body =? where uuid =?', 'sent', &subs::note_encrypter(&subs::session_suds($c), $mess->{'body'}, $mess->{'timestamp'}), $mess->{'uuid'});
				}
				else {
					$mess->{'body'} = &mail_text_chars(&subs::note_decrypter(&subs::suds_grabber(), $mess->{'body'}, $mess->{'ost'}));
				}
				if ($mess->{'subject'}) {
					$mess->{'subject'} = &mail_text_chars(&subs::note_decrypter(&subs::session_suds($c), $mess->{'subject'}, $mess->{'ost'}));
				}
				$mess->{'decrypted'} = 'yes';
				$mess->{'envelope'} = $c->render_to_string(
					template => 'mail/message',
					'm' => $mess,
					'me' => $me
				);
			}
			$mws->send({ json => { messages => $messaging, 'type' => 'refresher' } });
		}
	});
	$c->on(finish => sub ($c, $code, $reason) {
		# a reconnect - a wake, a new section - registers the new connection
		# before this older one is noticed to be gone: only the connection
		# still on duty may take the tab's entry away
		my $entry = $gb::mailws->{$browser_tab_id};
		if ($entry && $entry->{'tx'} && $entry->{'tx'} == $c->tx) {
			delete $gb::mailws->{$browser_tab_id};
		}
	});
}

1;
