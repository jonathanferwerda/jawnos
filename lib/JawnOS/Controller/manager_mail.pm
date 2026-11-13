package Manager;

# manager_mail: route actions moved out of Manager.pl, one sub per route so a
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

# GET /manager/mail/picker
sub action_31173 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');

	my $contents = &mail_checker($c)->{'contents'};
	my $returner = { html => &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'mailbox', contents => $contents }, $timestamp) };
	$c->render(json => $returner);
}

# GET /manager/mail/contact
sub action_31181 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = &mail_checker($c)->{'contents'};
	my $returner = { html => &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'mailbox', contents => $contents }, $timestamp) };
	$c->render(json => $returner);
}

# GET /manager/mail/phone
sub action_31188 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');

	my $contents = &mail_checker($c)->{'contents'};
	my $returner = { html => &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'mailbox', contents => $contents }, $timestamp) };
	$c->render(json => $returner);
}

# GET /manager/mail/email
sub action_31196 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = &mail_checker($c)->{'contents'};
	my $returner = { html => &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'mailbox', contents => $contents }, $timestamp) };
	$c->render(json => $returner);
}

# GET /manager/mail/email/configure
sub action_31203 {
	my $c = shift;
	my $screen = $c->param('screen');
	my $template = $c->param('template');
	if ($template) { &subs::setting_setter({ app => 'mailbox', setting => 'email_template_config_select', value => $template }); }
	if ($screen) { &subs::setting_setter({ app => 'mailbox', setting => 'email_config_screen', value => $screen }); }
	my $content = $c->render_to_string(
		template => 'mail/email_configure',
	);
	my $returner = { html => $content };
	$c->render(json => $returner);
}

# Begin an OAuth 2.0 device-authorization grant for an account: the provider
# answers with a short code and a web address the person approves it at.
# POST /manager/mail/email/oauth/start
sub action_31217 {
	my $c = shift;
	my $uuid = $c->param('uuid') || '';
	my $servers = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	my ($es) = grep { ($_->{'uuid'} || '') eq $uuid } @{$servers};
	return $c->render(json => { result => 'error', message => 'save the account first' }) unless $es;
	$es = &subs::email_oauth_overlay($es);
	my $suds = &subs::session_suds($c);
	my $end = &subs::email_oauth_endpoints($es);
	my %form = ( client_id => ($es->{'oauth_client_id'} || ''), scope => $end->{'scope'} );
	my $secret = &subs::email_oauth_plain($es, 'oauth_client_secret', $suds);
	$form{'client_secret'} = $secret if $end->{'secret'} && length $secret;
	my $r = &subs::email_oauth_http($end->{'device'}, \%form);
	return $c->render(json => { result => 'error', message => ($r->{'error_description'} || $r->{'error'} || 'no device code') }) unless length($r->{'device_code'} || '');
	&subs::email_server_update($uuid, { oauth_device_code => $r->{'device_code'} });
	$c->render(json => {
		result => 'ok',
		user_code => $r->{'user_code'}, verification_uri => ($r->{'verification_uri'} || $r->{'verification_url'}),
		message => $r->{'message'}, interval => ($r->{'interval'} || 5), expires_in => $r->{'expires_in'},
	});
}

# Poll for the grant: pending until the person approves, then the tokens are
# stored (sealed) on the account.
# POST /manager/mail/email/oauth/poll
sub action_31240 {
	my $c = shift;
	my $uuid = $c->param('uuid') || '';
	my $suds = &subs::session_suds($c);
	my $servers = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	my ($es) = grep { ($_->{'uuid'} || '') eq $uuid } @{$servers};
	return $c->render(json => { result => 'error', message => 'no account' }) unless $es;
	$es = &subs::email_oauth_overlay($es);
	my $code = $es->{'oauth_device_code'} || '';
	return $c->render(json => { result => 'error', message => 'press Connect first' }) unless length $code;
	my $end = &subs::email_oauth_endpoints($es);
	my %form = ( grant_type => 'urn:ietf:params:oauth:grant-type:device_code', device_code => $code, client_id => ($es->{'oauth_client_id'} || '') );
	my $secret = &subs::email_oauth_plain($es, 'oauth_client_secret', $suds);
	$form{'client_secret'} = $secret if $end->{'secret'} && length $secret;
	my $r = &subs::email_oauth_http($end->{'token'}, \%form);
	my $err = $r->{'error'} || '';
	return $c->render(json => { result => 'pending' }) if $err eq 'authorization_pending' || $err eq 'slow_down';
	return $c->render(json => { result => 'error', message => ($r->{'error_description'} || $err || 'authorisation failed') }) unless length($r->{'access_token'} || '');
	&subs::email_oauth_store($es, $r, $suds);
	&subs::email_server_update($uuid, { oauth_device_code => '' });
	$c->render(json => { result => 'ok' });
}

# GET /manager/mail/email/receive
sub action_31262 {
	my $c = shift;
	# An IMAP round-trip can hold a worker for a long time while the server
	# thinks. It runs in a child; the button still gets the same result.
	&subs::render_in_subprocess($c, sub {
		return &subs::email_receiver();
	}, sub {
		my ($c, $s_and_r) = @_;
		$c->render(json => ($s_and_r || { result => 'failed' }));
	});
}

# POST /manager/mail/email/configure
sub action_31274 {
	my $c = shift;
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $uuid = $c->param('uuid') eq 'new' ? &subs::random_string_creator(25) : $c->param('uuid');
	my $subsetting = $c->param('subsetting');
	my $folder = $c->param('folder');


	my $esa = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	@{$esa} = grep { $_->{'uuid'} eq $uuid } @{$esa};
	my $es = $esa->[0] ? $esa->[0] : {};
	if ($setting eq 'folder') {
		$es->{'folders'}->{$folder}->{$subsetting} = $value;
	}
	elsif ($setting eq 'password' || $setting eq 'oauth_client_secret') {
		$value = &subs::note_encrypter(&subs::session_suds($c), $value);
		$es->{$setting} = $value;
	}
	else {
		$es->{$setting} = $value;
	}
	$es->{'uuid'} = $uuid;

	@{$esa} = grep { $_->{'uuid'} ne $uuid } @{$esa};
	push @{$esa}, $es;

	my $jesa = encode_json $esa;
	&subs::setting_setter({ app => 'mailbox', setting => 'email_config', value => $jesa });

	$c->render(json => $es);
}

# POST /manager/mail/email/server/add
sub action_31306 {
	my $c = shift;
	my $email_servers = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	push @{$email_servers}, { uuid => &subs::random_string_creator(21) };

	my $jemail_servers = encode_json $email_servers;
	&subs::setting_setter({ app => 'mailbox', setting => 'email_config', value => $jemail_servers });
	my $html = $c->render_to_string(
		template => 'mail/email_configure'
	);

	$c->render(json => { html => $html });
}

# POST /manager/mail/email/server/delete
sub action_31319 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $email_servers = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	@{$email_servers} = grep { $_->{'uuid'} ne $uuid } @{$email_servers};
	my $jemail_servers = encode_json $email_servers;
	&subs::setting_setter({ app => 'mailbox', setting => 'email_config', value => $jemail_servers });
	$c->render(json => $email_servers);
}

# POST /manager/mail/email/template/delete
sub action_31328 {
	my $c = shift;
	my $uuid = $c->param('uuid');

	my $email_templates = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_templates' }) } || [];
	@{$email_templates} = grep { $_->{'uuid'} ne $uuid } @{$email_templates};

	my $jemail_templates = encode_json $email_templates;

	&subs::setting_setter({ app => 'mailbox', setting => 'email_templates', value => $jemail_templates });
	my $html = $c->render_to_string(
		template => 'mail/email_configure'
	);

	$c->render(json => { templates => $email_templates, html => $html });
}

# GET /manager/mail/email/compose
sub action_31344 {
	my $c = shift;
	my $email = $c->param('email');
	my $app = $c->param('app');
	my $draft_selection = $c->param('draft_selection');
	my $mode = $c->param('mode');
	my $in_reply_to = $c->param('in_reply_to');

	if ($app) {
		my $setting_email = &subs::setting_grabber({ app => $app, setting => 'email' });
		$email = $setting_email ? $setting_email : $email;
	}

	# whoever the letter is to: an address that belongs to a customer makes
	# ${self} answer for them and the newest thing they were sent, wherever
	# the compose was asked for
	my $magic_vars = '';
	my $email_app = &subs::db_query('select app from settings where setting = ? and value = ?', 'email', $email)->hashes->[0];
	if ($email_app && $email_app->{'app'}) {
		my $cx_row = &subs::db_select('settings', undef, { setting => 'uuid', app => $email_app->{'app'} })->hashes->[0];
		$magic_vars = 'customer:' . $cx_row->{'value'} if $cx_row;
	}

	my $draft = {};
	my $drafts = [];
	if ($draft_selection) {
		$drafts = &subs::db_query('select * from mailbox where uuid=?', $draft_selection)->hashes;
		$draft = $drafts->[0];
		$email = $draft->{'email'};
		$draft->{'attachments'} = eval { return decode_json $draft->{'attachments'} } || [];
		if ($draft->{'status'} eq 'outbox') {
			&subs::db_update('mailbox', { status => 'draft' }, { uuid => $draft->{'uuid'} });
		}

	} else {
		$drafts = &subs::db_query('select * from mailbox where email=? and status=? order by server_time asc', $email, 'draft')->hashes;
		if (scalar @{$drafts} > 0) {

			$draft = $drafts->[-1];

		}
	}
	if ($draft) {
		foreach my $e ( qw/from_email email subject body uuid/ ) {
			$draft->{$e} = &subs::note_decrypter(&subs::session_suds($c), $draft->{$e});

		}
		$draft->{'attachments'} = eval { return decode_json $draft->{'attachments'} } || [];
	}

	# A reply, a reply-all or a forward starts from the letter it answers: the other
	# party becomes the To (empty for a forward), the subject wears Re:/Fwd: unless
	# it already does, and the original is quoted into the body. Reply-all carries
	# the original's Cc too. The address it goes from is the one the letter arrived
	# on. mode is reply | reply_all | forward; in_reply_to is that letter's uuid.
	if ($mode && $in_reply_to) {
		my $orig = &subs::db_select('mailbox', undef, { uuid => $in_reply_to })->hashes->[0];
		if ($orig) {
			my $suds = &subs::session_suds($c);
			my $o_subject = &subs::note_decrypter($suds, $orig->{'subject'} || '');
			my $o_body = &subs::note_decrypter($suds, $orig->{'body'} || '');
			my $servers = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
			# which of our addresses received (inbox) or sent (sent/outbox) it
			my $our_uuid = $orig->{'email_server'} || $orig->{'from_email'};
			my ($our_es) = grep { $_->{'uuid'} eq $our_uuid } @{$servers};
			my $our_addr = $our_es ? $our_es->{'email'} : '';
			my $other = $orig->{'email'} || '';
			my $prefix = $mode eq 'forward' ? 'Fwd: ' : 'Re: ';
			# a forward always wears Fwd: (even of a letter that already wears Re:);
			# a reply only adds Re: when it is not already there
			my $subject = $o_subject;
			if ($mode eq 'forward') {
				$subject = $prefix . $subject unless $subject =~ /^\s*fwd:/i;
			}
			else {
				$subject = $prefix . $subject unless $subject =~ /^\s*re:/i;
			}
			my $quote = '<br><br>On ' . &subs::iso_local($orig->{'timestamp'}) . ', ' . ($other || 'they') . ' wrote:'
				. '<blockquote style="border-left:2px solid var(--line);margin:8px 0;padding-left:12px;">' . $o_body . '</blockquote>';
			my $to = $mode eq 'forward' ? '' : $other;
			my $cc = '';
			if ($mode eq 'reply_all') {
				my %seen;
				my @cc = grep { length && $_ ne $to && $_ ne $our_addr && !$seen{$_}++ } split /\s*[,;]\s*/, ($orig->{'cc'} || '');
				$cc = join(', ', @cc);
			}
			$draft = {
				uuid => '',
				email => $to,
				cc => $cc,
				bcc => '',
				from_email => $our_addr,
				sender => &subs::device_setter(),
				subject => $subject,
				body => $quote,
				attachments => [],
				in_reply_to_uuid => $in_reply_to,
				timestamp => &subs::rightNow()
			};
			$email = $to;
		}
	}

	my $content = $c->render_to_string(
		template => 'mail/email_compose',
		email => $email,
		draft => $draft,
		drafts => $drafts,
		attachments => $draft->{'attachments'} || [],
		timestamp => $draft->{'timestamp'} || &subs::rightNow(),
		magic_vars => $magic_vars
	);
	$c->render(json => {
		email => $email,
		html => $content,
		draft => $drafts,
		drafts => $drafts
	});
}

# POST /manager/mail/email/draft
sub action_31463 {
	my $c = shift;
	my $m = $c->param('m');
	my $msg = eval { return decode_json $m } || {};
	my $message = $msg->{'msg'};

	if ($message->{'to'}) {
		$message->{'subject'} = &subs::note_encrypter(&subs::session_suds($c), $message->{'subject'});
		$message->{'body'} = &subs::note_encrypter(&subs::session_suds($c), $message->{'body'});
		if ($message->{'attachments'}) {
			$message->{'attachments'} = encode_json $message->{'attachments'};
		}

		if ($message->{'uuid'}) {
			&subs::db_update('mailbox', {
				email => $message->{'to'},
				cc => $message->{'cc'},
				bcc => $message->{'bcc'},
				subject => $message->{'subject'},
				body => $message->{'body'},
				status => 'draft',
				attachments => $message->{'attachments'},
				server_time => &subs::rightNow(),
				sender => $message->{'sender'},
				timestamp => $message->{'timestamp'}
			},
			{
				uuid => $message->{'uuid'}
			});
		}
		else {
			$message->{'uuid'} = &subs::random_string_creator(23);
			&subs::db_insert('mailbox', {
				email => $message->{'to'},
				cc => $message->{'cc'},
				bcc => $message->{'bcc'},
				subject => $message->{'subject'},
				body => $message->{'body'},
				uuid => $message->{'uuid'},
				attachments => $message->{'attachments'},
				timestamp => $message->{'timestamp'},
				sender => $message->{'sender'},
				status => 'draft'
			});

		}
		&Websocket::send('tab', { console => &Websocket::console_command('setEmailForm', $message->{'app'}, $message->{'uuid'})});
	}
	$c->render(json => $message);
}

# GET /manager/mail/email/read
sub action_31513 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $m = &subs::db_select('mailbox', undef, { uuid => $uuid })->hashes->[0];
	return $c->render(json => { html => '' }) unless $m;

	# the whole conversation: every letter sharing the thread key, oldest first. The
	# key is a header chain, set when each letter was written or received; a row
	# from before the column has none, so it stands alone rather than guessing at a
	# subject that two unrelated letters might share.
	my $key = $m->{'thread'};
	my $messages = ($key && length $key) ? &subs::db_select('mailbox', undef, { thread => $key })->hashes : [];
	@{$messages} = ($m) unless scalar @{$messages};
	@{$messages} = sort { ($a->{'timestamp'} || 0) <=> ($b->{'timestamp'} || 0) } @{$messages};

	# opening a thread reads it whole: every unread inbox letter in it is marked
	# seen, so a two-letter exchange does not stay bold once it has been read.
	# server_time rides along so the flag reaches every machine.
	foreach my $msg ( @{$messages} ) {
		if (($msg->{'status'} || '') eq 'inbox' && ($msg->{'seen'} || '') ne 'yes') {
			&subs::db_update('mailbox', { seen => 'yes', server_time => &subs::rightNow() }, { uuid => $msg->{'uuid'} });
			$msg->{'seen'} = 'yes';
		}
	}

	my $html = $c->render_to_string(
		template => 'mail/email',
		messages => $messages
	);
	$c->render(json => { html => $html });
}

# star a letter, or flag it unread again: the one place the list and the reading
# pane both write the flag
# POST /manager/mail/email/flag
sub action_31546 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $flag = $c->param('flag') || '';
	return $c->render(json => { result => 'bad flag' }) unless $uuid && ($flag eq 'starred' || $flag eq 'seen');
	my $value = ($c->param('value') || '') =~ /^(yes|1|on)$/ ? 'yes' : 'no';
	&subs::db_update('mailbox', { $flag => $value, server_time => &subs::rightNow() }, { uuid => $uuid });
	$c->render(json => { result => 'ok', flag => $flag, value => $value });
}

# move a letter between folders (a status change). Trash is a soft delete: the
# row keeps its letter and comes back with Restore, so nothing is lost by a
# stray press - only Delete (or Empty Trash) throws a row away for good.
# POST /manager/mail/email/move
sub action_31558 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $to = $c->param('to') || '';
	return $c->render(json => { result => 'no uuid' }) unless $uuid;
	my %ok = map { $_ => 1 } qw/inbox archive drafts sent outbox trash/;
	$ok{$to} = 1 if grep { $_ eq $to } @{ &email_extra_folders() };
	return $c->render(json => { result => 'bad folder' }) unless $ok{$to};
	&subs::db_update('mailbox', { status => $to, server_time => &subs::rightNow() }, { uuid => $uuid });
	$c->render(json => { result => 'ok', folder => $to });
}

# the real deletions: one letter, or every letter in Trash
# POST /manager/mail/email/delete
sub action_31570 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	return $c->render(json => { result => 'no uuid' }) unless $uuid;
	&subs::db_delete('mailbox', { uuid => $uuid });
	$c->render(json => { result => 'deleted' });
}

# POST /manager/mail/email/empty_trash
sub action_31577 {
	my $c = shift;
	my $count = scalar @{ &subs::db_query("select uuid from mailbox where status = 'trash'")->hashes };
	&subs::db_query("delete from mailbox where status = 'trash'");
	$c->render(json => { result => 'ok', count => $count });
}

# put a letter back in the inbox (the undo of a delete, and the way out of Trash)
# POST /manager/mail/email/restore
sub action_31584 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	return $c->render(json => { result => 'no uuid' }) unless $uuid;
	&subs::db_update('mailbox', { status => 'inbox', server_time => &subs::rightNow() }, { uuid => $uuid });
	$c->render(json => { result => 'ok' });
}

# mark every letter in a folder read (Inbox's Mark all read)
# POST /manager/mail/email/mark_read
sub action_31592 {
	my $c = shift;
	my $folder = $c->param('folder') || 'inbox';
	my $count = 0;
	foreach my $row ( @{ &email_folder_rows($folder) } ) {
		next if ($row->{'seen'} || '') eq 'yes';
		&subs::db_update('mailbox', { seen => 'yes', server_time => &subs::rightNow() }, { uuid => $row->{'uuid'} });
		$count++;
	}
	$c->render(json => { result => 'ok', count => $count });
}

# one action over a selection of letters (the checkboxes): move them to a folder
# (a built-in or one the person made), delete them to Trash, throw them away, or
# flip their read or star flag. The uuids arrive comma-separated.
# POST /manager/mail/email/bulk
sub action_31606 {
	my $c = shift;
	my $action = $c->param('action') || '';
	my @uuids = grep { length } split /\s*,\s*/, ($c->param('uuids') || '');
	return $c->render(json => { result => 'no uuid' }) unless @uuids;
	my $folder = $c->param('folder') || '';
	if ($action eq 'move') {
		my %ok = map { $_ => 1 } qw/inbox archive drafts sent outbox trash/;
		$ok{$folder} = 1 if grep { $_ eq $folder } @{ &email_extra_folders() };
		return $c->render(json => { result => 'bad folder' }) unless $ok{$folder};
	}
	my %plan = (
		move => { status => $folder }, delete => { status => 'trash' },
		read => { seen => 'yes' }, unread => { seen => 'no' },
		star => { starred => 'yes' }, unstar => { starred => 'no' },
	);
	my $n = 0;
	foreach my $uuid ( @uuids ) {
		if ($action eq 'delete_forever') { &subs::db_delete('mailbox', { uuid => $uuid }); $n++; next; }
		my $set = $plan{$action} or return $c->render(json => { result => 'bad action' });
		$set = { %{$set}, server_time => &subs::rightNow() };
		&subs::db_update('mailbox', $set, { uuid => $uuid });
		$n++;
	}
	$c->render(json => { result => 'ok', count => $n, action => $action });
}

# make a new folder. Its name is stored in one setting and used as the letters'
# status, so nothing else has to know about it.
# POST /manager/mail/email/folder/add
sub action_31634 {
	my $c = shift;
	my $name = $c->param('name') || '';
	$name =~ s/\s+/ /g;
	$name =~ s/^\s+|\s+$//g;
	$name = substr($name, 0, 40);
	return $c->render(json => { result => 'bad name' }) unless length $name;
	return $c->render(json => { result => 'reserved' }) if &email_folder_is_builtin($name) || lc($name) eq 'contacts';
	my $folders = &email_extra_folders();
	return $c->render(json => { result => 'exists', folders => $folders }) if grep { lc($_) eq lc($name) } @{$folders};
	push @{$folders}, $name;
	&subs::setting_setter({ app => 'mail', setting => 'email_folders', value => encode_json($folders) });
	$c->render(json => { result => 'ok', folders => $folders });
}

# remove a folder the person made; its letters go back to the inbox (a folder is
# a status, so deleting it cannot drop the mail with it)
# POST /manager/mail/email/folder/remove
sub action_31650 {
	my $c = shift;
	my $name = $c->param('name') || '';
	my $folders = &email_extra_folders();
	return $c->render(json => { result => 'no folder' }) unless grep { $_ eq $name } @{$folders};
	&subs::db_update('mailbox', { status => 'inbox', server_time => &subs::rightNow() }, { status => $name });
	@{$folders} = grep { $_ ne $name } @{$folders};
	&subs::setting_setter({ app => 'mail', setting => 'email_folders', value => encode_json($folders) });
	$c->render(json => { result => 'ok', folders => $folders });
}

# A letter from someone the house does not know: make them a person, so their mail
# and the attachments waiting in the unclaimed pool have somewhere to live. The
# pool's file rows that came in with this letter move onto a new appointment on
# the new app; the media itself stays where it was sealed.
# POST /manager/mail/email/sender_app
sub action_31664 {
	my $c = shift;
	my $email = $c->param('email') || '';
	my $mail_uuid = $c->param('uuid') || '';
	$email =~ s/^\s+|\s+$//g;
	return $c->render(json => { result => 'no email' }) unless length $email;
	my $known = &subs::db_query('select app from settings where setting = ? and value = ?', 'email', $email)->hashes->[0];
	my $app = $known ? $known->{'app'} : '';
	unless ($app) {
		my ($local) = split /\@/, $email;
		$local =~ s/[^A-Za-z0-9]+//g;
		$local = 'friend' unless length $local;
		$app = &subs::unformat_name($local);
		&subs::setting_initializer($app);
		&subs::setting_setter({ app => $app, setting => 'email', value => $email });
	}
	my $appt = &Manager::appointment_writer($c, {
		app => $app,
		type => 'email',
		timestamp => &subs::rightNow(),
		notes => &subs::note_encrypter(&subs::suds_grabber(), 'Mail from ' . $email),
	});
	my $moved = 0;
	foreach my $h ( @{ &subs::db_select('appointments', undef, { app => 'camera', source => 'unclaimed' })->hashes || [] } ) {
		my $of = eval { return decode_json $h->{'file'} } || [];
		my @move = grep { $mail_uuid && ($_->{'mail_uuid'} || '') eq $mail_uuid } @{$of};
		next unless @move;
		my @left = grep { !($mail_uuid && ($_->{'mail_uuid'} || '') eq $mail_uuid) } @{$of};
		my $tf = eval { return decode_json $appt->{'file'} } || [];
		foreach my $f ( @move ) { $f->{'appt_uuid'} = $appt->{'uuid'}; push @{$tf}, $f; $moved++; }
		&subs::db_update('appointments', { file => encode_json($tf), server_time => &subs::rightNow() }, { app => $app, uuid => $appt->{'uuid'} });
		if (@left) { &subs::db_update('appointments', { file => encode_json(\@left), server_time => &subs::rightNow() }, { app => 'camera', uuid => $h->{'uuid'} }); }
		else { &delete_app('camera', $h->{'uuid'}, $h->{'server_time'}, 'claimed'); }
	}
	$c->render(json => { result => 'ok', app => $app, moved => $moved });
}

# the folder rail, refetched after a folder is made or removed
# GET /manager/mail/email/rail
sub action_31701 {
	my $c = shift;
	my $settings = &subs::settings_grabber({ app => 'mail' });
	$c->render(json => { html => $c->render_to_string(
		template => 'mail/email_rail',
		settings => $settings,
		email_counts => &email_folder_counts(),
		extra_folders => &email_extra_folders(),
		mail_email => $c->param('email') || '',
	) });
}

# The list pane, a page at a time: a folder's threads from an offset on, in the
# chosen order, so a folder of thousands loads as it is scrolled rather than all
# in one go. The rows always come back ascending; the direction only says which
# end the first page is taken from (a descending list starts at its newest, its
# foot) and whether more wait above or below.
# GET /manager/mail/email/list
sub action_31717 {
	my $c = shift;
	my $folder = $c->param('folder') || 'inbox';
	my $offset = $c->param('offset') || 0;
	my $limit  = $c->param('limit')  || 50;
	my $stored = &email_sort();
	my $by  = ($c->param('sort') || '') =~ /^(date|sender|subject)$/ ? $c->param('sort') : $stored->{'by'};
	my $dir = ($c->param('dir')  || '') eq 'asc' ? 'asc' : 'desc';
	my $suds = &subs::suds_grabber();
	my $all = &email_sort_threads(&email_threads(&email_folder_rows($folder)), $suds, { by => $by });
	my $total = scalar @{$all};
	my (@slice, $more_up, $more_down);
	if ($dir eq 'asc') {
		my $last = $offset + $limit - 1;
		$last = $total - 1 if $last > $total - 1;
		@slice = ($offset <= $last) ? @{$all}[$offset .. $last] : ();
		$more_down = ($offset + $limit) < $total ? 1 : 0;
	}
	else {
		my $hi = $total - 1 - $offset;
		my $lo = $hi - $limit + 1;
		$lo = 0 if $lo < 0;
		@slice = ($hi >= 0) ? @{$all}[$lo .. $hi] : ();
		$more_up = ($offset + $limit) < $total ? 1 : 0;
	}
	&email_thread_annotate(\@slice, $suds);
	$c->render(json => {
		html => $c->render_to_string(template => 'mail/email_rows', threads => \@slice),
		offset => $offset + scalar @slice,
		more_up => $more_up || 0,
		more_down => $more_down || 0,
		total => $total,
		sort => $by,
		dir => $dir
	});
}

# Search the words themselves. Subject and body are sealed, so a LIKE over the
# ciphertext would match nothing: the rows are decrypted and matched here, over
# the party addresses, the Cc and Bcc, the subject and the body.
# GET /manager/mail/email/search
sub action_31756 {
	my $c = shift;
	my $q = $c->param('q') || '';
	my $folder = $c->param('folder') || '';
	$q =~ s/^\s+|\s+$//g;
	return $c->render(json => { html => '', more_up => 0, more_down => 0, count => 0 }) unless length $q;
	my $suds = &subs::suds_grabber();
	my $stored = &email_sort();
	my $by = ($c->param('sort') || '') =~ /^(date|sender|subject)$/ ? $c->param('sort') : $stored->{'by'};
	my $dir = ($c->param('dir') || '') eq 'asc' ? 'asc' : 'desc';
	my $needle = lc $q;
	my @rows;
	if (length $folder && ($folder =~ /^[A-Za-z0-9 _\-]+$/)) {
		@rows = @{ &email_folder_rows($folder) };
	}
	else {
		# no folder named: search everything that is not thrown away
		@rows = @{ &subs::db_query("select * from mailbox where status != 'trash' and coalesce(status, '') != 'ignored'")->hashes };
	}
	my @matched;
	foreach my $m ( @rows ) {
		my $hay = lc join ' ',
			&subs::note_decrypter($suds, $m->{'subject'} || ''),
			&subs::note_decrypter($suds, $m->{'body'} || ''),
			($m->{'email'} || ''), ($m->{'cc'} || ''), ($m->{'bcc'} || ''),
			($m->{'from_email'} || '');
		push @matched, $m if index($hay, $needle) >= 0;
	}
	my $threads = &email_sort_threads(&email_threads(\@matched), $suds, { by => $by });
	my $count = scalar @{$threads};
	my $cap = 200;
	my @slice = ($count > $cap) ? @{$threads}[0 .. $cap - 1] : @{$threads};
	@slice = reverse @slice if $dir eq 'desc';
	&email_thread_annotate(\@slice, $suds);
	$c->render(json => {
		html => $c->render_to_string(template => 'mail/email_rows', threads => \@slice),
		more_up => 0,
		more_down => 0,
		count => $count,
		sort => $by,
		dir => $dir
	});
}

1;
