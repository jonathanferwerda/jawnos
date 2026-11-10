package Manager;

# manager_mail2: route actions moved out of Manager.pl, one sub per route so a
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

# POST /manager/mail/email/template/save
sub action_31987 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $name = &subs::unformat_name($c->param('name'));
	my $subject = $c->param('subject');
	my $body = $c->param('body');
	my $purpose = $c->param('purpose');
	my $templates = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_templates' }) } || [];
	my $data = {
		uuid => $uuid,
		name => $name,
		purpose => $purpose,
		subject => $subject,
		body => $body
	};
	if ($uuid eq 'new') {
		$data->{'uuid'} = &subs::random_string_creator(15);
		push @{$templates}, $data;
		&subs::setting_setter({ app => 'mailbox', setting => 'email_template_config_select', value => $data->{'uuid'} });
	}
	else {
		foreach my $t ( @{$templates} ) {
			if ($t->{'uuid'} eq $uuid) {
				$t = $data;
			}
		}
	}

	my $jtemplates = encode_json $templates;
	&subs::setting_setter({ app => 'mailbox', setting => 'email_templates', value => $jtemplates });
	my $html = $c->render_to_string(
		template => 'mail/email_configure'
	);

	$c->render(json => { data => $data, html => $html });

}

# GET /manager/mail/email/template
sub action_32024 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $email_templates = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_templates' }) } || [];
	@{$email_templates} = grep { $_->{'uuid'} eq $uuid } @{$email_templates};
	my $template = $email_templates->[0];

	$c->render(json => $template);
}

# POST /manager/mail/email/send
sub action_32033 {
	my $c = shift;
	my $from = $c->param('from');
	my $email = $c->param('to');
	my $cc = $c->param('cc');
	my $bcc = $c->param('bcc');
	my $subject = $c->param('subject');
	my $body = $c->param('body');
	my $uuid = $c->param('uuid');
	my $jattachments = $c->param('attachments');
	my $timestamp = $c->param('timestamp') ? $c->param('timestamp') : &subs::rightNow();
	my $sender = $c->param('sender') || &subs::device_setter();
	my $attachments = eval { return decode_json $jattachments } || [];
	my $magic_vars = $c->param('magic_vars');

	# the words are said before the letter leaves: the subject plainly (prose
	# has no illusions), the body keeping them for whoever reads it back
	if ($magic_vars) {
		my $context = &text_area_context($magic_vars);
		$subject = ( &text_area_magic($subject, $context, { plain => 1, self_only => 1 }) )[0];
		$body = ( &text_area_magic($body, $context) )[0];
	}

	&subs::db_delete('mailbox', { status => 'draft', uuid => $uuid });

	my $enc_subject = &subs::note_encrypter(&subs::session_suds($c), $subject);
	my $enc_body = &subs::note_encrypter(&subs::session_suds($c), $body);

	# the thread this letter belongs to: its own Message-ID names it, and a reply
	# inherits the chain it answers (In-Reply-To / References) rather than a guess
	my $message_id = '<' . $uuid . '@jawnos>';
	my $in_reply_to = '';
	my $references = '';
	# the thread this letter belongs to. A fresh letter names only itself, so it
	# stands alone; a reply inherits the chain it answers (In-Reply-To / References)
	# rather than a guess at the subject, which would fold unrelated letters that
	# happen to share one.
	my $thread = $message_id;
	my $reply_uuid = $c->param('in_reply_to_uuid');
	if ($reply_uuid) {
		my $orig = &subs::db_select('mailbox', undef, { uuid => $reply_uuid })->hashes->[0];
		if ($orig) {
			$in_reply_to = $orig->{'message_id'} || '';
			$references = join(' ', grep { length } ($orig->{'thread_refs'} || '', $orig->{'message_id'} || ''));
			$thread = $orig->{'thread'} || $orig->{'message_id'} || $message_id;
		}
	}

	&subs::db_insert('mailbox', {
		uuid => $uuid,
		email => $email,
		cc => $cc,
		bcc => $bcc,
		from_email => $from,
		sender => $sender,
		subject => $enc_subject,
		body => $enc_body,
		attachments => $jattachments,
		status => 'sending',
		thread => $thread,
		message_id => $message_id,
		in_reply_to => $in_reply_to,
		thread_refs => $references,
		timestamp => $timestamp
	});

	# A composed letter is sent now, inside this request - it is not a queue. The
	# periodic email_sender utility is left for email lists (a batch of sends); the
	# row is deliberately never left in 'outbox', so the utility cannot sweep up a
	# letter a person pressed Send on. A send that fails leaves the letter as a
	# draft, so it stays visible and can be reopened and retried by hand.
	my $result = &subs::email_send({
		c => $c,
		from => $from,
		email => $email,
		cc => $cc,
		bcc => $bcc,
		subject => $enc_subject,
		body => $enc_body,
		attachments => $jattachments,
		uuid => $uuid,
		message_id => $message_id,
		in_reply_to => $in_reply_to,
		references => $references,
	});
	$result = ref $result eq 'HASH' ? $result->{'result'} : $result;
	if ($result ne 'success') {
		&subs::db_update('mailbox', { status => 'draft', server_time => &subs::rightNow() }, { uuid => $uuid });
	}

	$c->render(json => $result);
}

# GET /manager/mail/email/attachment_preparer
sub action_32126 {
	my $c = shift;
	my $src = $c->param('src');
	my $app = $c->param('app');
	my $type = $c->param('type');
	my $app_data = [];
	my $url = Mojo::URL->new($src);
	my $params = $url->query->to_hash;
	my $edited_src = $params->{'file'} ? $params->{'file'} : $params->{'track'};

	my @file = split '/', $edited_src;
	$edited_src = $file[-1];
	if ($app && $app ne 'undefined') {

		$app_data = &subs::db_query('select * from appointments where app=? and file like ?', $app, '%' . $edited_src . '%')->hashes;
	} else {

		$app_data = &subs::db_query('select * from appointments where file like ?', '%' . $edited_src . '%')->hashes;
	}
	$app_data = $app_data->[0];
	$app_data->{'file'} = eval { return decode_json $app_data->{'file'} } || [];
	my ($file) = grep { $_->{'f'} =~ /\Q$edited_src/gi } @{$app_data->{'file'}};
	if ($file->{'uuid'}) {
		$type = $file->{'type'} ? $file->{'type'} : $type;
	}
	my $uuid = $file->{'uuid'} || &subs::random_string_creator(12);
	my $att = {
		uuid => $uuid,
		src => $src,
		file => $file
	};


	my $html = $c->render_to_string(
		template => 'mail/email_attachment_preparer',
		att => $att
	);


	$c->render(json => { html => $html, file => $file, type => $type, uuid => $uuid, app => $app });
}

# GET /manager/mail/scroll
sub action_32167 {
	my $c = shift;
	my $mc = &mail_checker($c);
	$c->render(json => $mc);
}

# Advertising is the house's half of the dial: a citizen opens the set of
# appointments they are currently tuned to, and guests may then tune the same
# set. Pressing it again closes the channel to guests. Only a citizen holds
# the dial's public face - a resident or guest may tune, not advertise.
# POST /manager/mail/public_channel
sub action_32176 {
	my $c = shift;
	unless ($c->session('privilege') eq 'citizen') {
		$c->render(json => { public => 0, error => 'denied' });
		return;
	}
	my $picker = eval { return decode_json $c->param('picker') } || {};
	unless (&mailws_picker_dialled($picker)) {
		$c->render(json => { public => 0, error => 'no dial' });
		return;
	}
	my $channels = eval { return decode_json &subs::setting_grabber({ app => 'mail', setting => 'public_channels' }) } || [];
	my $key = &mail_channel_key(&mailws_constructs($picker));
	my $found = 0;
	my @kept;
	foreach my $ch ( @{$channels} ) {
		next unless ref $ch eq 'HASH';
		if (&mail_channel_key(&mailws_constructs($ch)) eq $key) {
			$found = 1;
			next;
		}
		push @kept, $ch;
	}
	my $public = 0;
	if (!$found) {
		push @kept, &mailws_constructs($picker);
		$public = 1;
	}
	&subs::setting_setter({ app => 'mail', setting => 'public_channels', value => encode_json \@kept });
	$c->render(json => { public => $public, count => scalar @kept });
}

# GET /manager/mail/config
sub action_32554 {
	my $c = shift;
	my $uuid = $c->param('uuid');

	my $configure = eval { return decode_json &subs::setting_grabber({ app => 'mail', setting => 'mail_config' }) } || {};
	my $returner = { config => $configure->{$uuid} };
	if ($configure->{$uuid}->{'qr'}) {
		my $qr = $configure->{$uuid}->{'qr'};
		$qr = `qrencode -o - ` . &quote($qr);
		$configure->{$uuid}->{'qr_image'} = 'data:image/png;base64,' . encode_base64($qr);
	}
	$returner->{'html'} = $c->render_to_string(
		template => 'mail/config',
		configure => $configure->{$uuid},
		uuid => $uuid
	);
	$c->render(json => $returner);
}

# POST /manager/mail/config
sub action_32572 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $setting = $c->param('setting');
	my $value = $c->param('value');

	my $configure = eval { return decode_json &subs::setting_grabber({ app => 'mail', setting => 'mail_config' }) } || {};
	$configure->{$uuid}->{$setting} = $value;
	my $jset = encode_json $configure;

	&subs::setting_setter({ app => 'mail', setting => 'mail_config', value => $jset });
	$c->render(json => $configure);
}

# POST /manager/mail/delete_conversation
sub action_32585 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $conversation_uuid = $c->param('conversation_uuid');
	if ($conversation_uuid) {
		&subs::db_delete('mailbox', { conversation_uuid => $conversation_uuid });
		$c->render(json => { 'status' => 'ok' });
	} else {
		my @selection = split '---', $uuid;
		my @groups = sort keys %{$gb::social_constructs};
		# a uuid from before this build carries the retired tuple and names no
		# row; a count that does not match deletes nothing rather than binding
		# values into the wrong columns
		if (scalar @selection == scalar @groups) {
			my %picked;
			@picked{@groups} = @selection;
			my $where = join ' and ', map { "$_ = ?" } &mail_construct_columns();
			&subs::db_query("delete from mailbox where $where", map { $picked{$_} } @groups);
		}
		my $configure = eval { return decode_json &subs::setting_grabber({ app => 'mail', setting => 'mail_config' }) } || {};
		delete $configure->{$uuid};
		my $jset = encode_json $configure;
		&subs::setting_setter({ app => 'mail', setting => 'mail_config', value => $jset });
		$c->render(json => \@selection);
	}

}

# GET /manager/mail/qr_generator
sub action_32612 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $returner = {};
	my $configure = eval { return decode_json &subs::setting_grabber({ app => 'mail', setting => 'mail_config' }) } || {};
	my $rand = 0;
	until ($rand > 200) {
		$rand = rand(359);
	}

	$configure->{$uuid}->{'qr'} = $uuid . ' ' . &subs::random_string_creator($rand);

	my $jset = encode_json $configure;
	&subs::setting_setter({ app => 'mail', setting => 'mail_config', value => $jset });
	if ($configure->{$uuid}->{'qr'}) {
		my $qr = $configure->{$uuid}->{'qr'};
		$qr = `qrencode -o - ` . &quote($qr);
		$configure->{$uuid}->{'qr_image'} = 'data:image/png;base64,' . encode_base64($qr);
	}
	$c->render(json => $configure->{$uuid});
}

1;
