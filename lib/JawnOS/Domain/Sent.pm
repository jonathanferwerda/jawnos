package subs;

# Sent: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use JawnOS::PDF::Store ();
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $database;
our $device;
our $gb;
our $log;
our %m;

# A letter that leaves is filed like one that arrives: an appointment on the
# app of the address it went to, so that app's details show both sides of the
# conversation. The attachments are copied into that app's own folders and
# written into the row's file column, and the mailbox row's uuid rides in the
# data so the envelope in the details can open the very message.
sub sent_mail_filer {
	my $data = shift;
	return unless $data->{'to'};
	my $c = $data->{'c'} || &subs::c_maker();
	my $device = &subs::device_setter();
	my $app_row = &subs::db_query('select app from settings where setting = ? and value = ? and device = ? order by app limit 1', 'email', $data->{'to'}, $device)->hashes->[0];
	return unless $app_row && $app_row->{'app'};
	my $app = $app_row->{'app'};
	my $files = [];
	foreach my $f ( @{$data->{'files'} || []} ) {
		next unless $f->{'src'} && -e $f->{'src'};
		my ($destination,$asset,$type) = &subs::file_device_renamer({ file => ($f->{'name'} || $f->{'src'}), app => $app, is_thumb => 0 });
		system('mkdir', '-p', $destination) unless -e $destination;
		copy($f->{'src'}, $destination . $asset);
		push @{$files}, {
			server_time => &subs::rightNow(),
			f => $destination . $asset,
			uuid => &subs::random_string_creator(28),
			type => $f->{'type'} || $type,
			name => $f->{'name'},
			mail_uuid => $data->{'mail_uuid'}
		};
	}
	my $jfile = scalar @{$files} > 0 ? encode_json $files : undef;
	my $appt = &Manager::appointment_writer($c, {
		app => $app,
		type => 'email',
		timestamp => $data->{'timestamp'} || &subs::rightNow(),
		notes => &subs::note_encrypter(&subs::suds_grabber(), $data->{'body'}),
		file => $jfile,
		data => encode_json({ mail_uuid => $data->{'mail_uuid'}, email => $data->{'to'} })
	});
	&file_encrypter({ app => $app, timestamp => $appt->{'timestamp'}, suds => &subs::suds_grabber() }) if $appt && $appt->{'uuid'};
	return $appt;
}

sub email_send {
	my $data = shift;

	my $c = $data->{'c'} ? $data->{'c'} : &subs::c_maker();
	my $suds = &subs::session_suds($c);
	$data->{'attachments'} = [] unless $data->{'attachments'};
	my $email_server = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	return { result => 'no server' } if scalar @{$email_server} == 0;
	@{$email_server} = grep { $_->{'uuid'} eq $data->{'from'} } @{$email_server};
	return { result => 'server no longer exists' } if scalar @{$email_server} == 0;
	my $es = $email_server->[0];
	require Email::Stuffer;
	require Email::Sender::Transport::SMTP;
	require Authen::SASL;
	my $smtp_data = {
		host          => $es->{'smtp_server'},
		port          => $es->{'smtp_port'},
		ssl           => $es->{'smtp_encryption'} eq 'SSL' ? 1 : 0,
	};
	# an oauth2 account authenticates with a bearer token (XOAUTH2); a plain one
	# with its password, exactly as before
	if (($es->{'auth'} || '') eq 'oauth2') {
		my $token = &subs::email_oauth_token($es, $suds);
		return { result => 'no oauth token' } unless length $token;
		$smtp_data->{'sasl_authenticator'} = Authen::SASL->new(mechanism => 'XOAUTH2', callback => { user => $es->{'email'}, pass => $token });
	}
	else {
		$smtp_data->{'sasl_username'} = $es->{'email'};
		$smtp_data->{'sasl_password'} = &subs::note_decrypter($suds, $es->{'password'});
	}
	my $transport = Email::Sender::Transport::SMTP->new($smtp_data);
	my $stuffer = Email::Stuffer
		->from(&subs::format_name($es->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'my_name' })) . ' <' . $es->{'email'} . '>')
		->to($data->{'email'})
		->subject(&subs::note_decrypter($suds, $data->{'subject'}))
		->transport($transport);
	# carbon copies: cc is visible to everyone, bcc only reaches the smtp envelope
	# (Email::Stuffer keeps it out of the headers). Both are plain addresses.
	$stuffer->cc($data->{'cc'}) if $data->{'cc'};
	$stuffer->bcc($data->{'bcc'}) if $data->{'bcc'};
	# the thread headers: our own Message-ID (the mailbox row's uuid, so every letter
	# can be named and matched) and, for a reply, what it answers and the chain so far
	$stuffer->header('Message-ID' => $data->{'message_id'}) if $data->{'message_id'};
	$stuffer->header('In-Reply-To' => $data->{'in_reply_to'}) if $data->{'in_reply_to'};
	$stuffer->header('References' => $data->{'references'}) if $data->{'references'};

	my $dom = Mojo::DOM->new(&subs::note_decrypter($suds, $data->{'body'}));

	if ($dom->find('*')->size > 0) {
		$stuffer->html_body(&subs::note_decrypter($suds, $data->{'body'}));
	}
	else {
		$stuffer->text_body(&subs::note_decrypter($suds, $data->{'body'}));
	}
	$data->{'attachments'} = eval { return decode_json $data->{'attachments'} } || [];
	my @locations;
	# the files ride along twice: once for the letter itself, and once to be
	# filed into the recipient's app once the send lands
	my @mail_files;
	foreach my $att ( @{$data->{'attachments'}} ) {
		if ($att->{'type'} eq 'printer') {
			my $loc_name = &subs::format_name($att->{'printer'}->{'type'}) . ' ' . $att->{'printer'}->{'id'} . '.pdf';
			my $loc = $gb::tmp_dir . '/' . $loc_name;
			push @locations, $loc;
			# The store's own engine draws the paper from the attachment's data,
			# with no network and no second renderer to install.
			my ($bytes, $error) = JawnOS::PDF::Store::paper_bytes($att->{'printer'} || {});
			if (defined $bytes && length $bytes) {
				write_file($loc, $bytes);
			}
			&subs::log_writer('mail paper ' . $loc_name . ' drawn: ' . (-s $loc) . ' bytes');
			if (-s $loc) {
				$stuffer->attach_file($loc);
				push @mail_files, { src => $loc, name => $loc_name, type => 'document' };
			}
			else {
				&subs::log_writer('mail paper ' . $loc_name . ' not drawn: ' . ($error || 'no PDF was made'));
			}
		}
		else {

			my $file = $att->{'file'};
			my $app = $att->{'app'};
			my ($destination,$asset,$type,$fapp) = &subs::file_device_renamer({ file => $file->{'f'}, app => $app, type => $file->{'type'} });

			$c->param('file' => $destination . $asset);
			$c->param('duty' => 'collection');
			my $job = &Manager::rock_and_roll($c);

			$stuffer->attach($job->{'data'}, filename => $file->{'of'} || $asset, content_type => $job->{'fd'});
			push @mail_files, { src => $destination . $asset, name => ($file->{'of'} || $asset), type => ($file->{'type'} || $type) };
		}
	}

	my $result = $stuffer->send;

	if ($result->message =~ /2.0.0 OK/gi) {
		$result = 'success';
		&subs::db_delete('mailbox', { status => 'draft', uuid => $data->{'uuid'} });
		&subs::db_update('mailbox', { status => 'sent', timestamp => &subs::rightNow(), server_time => &subs::rightNow() }, { uuid => $data->{'uuid'} });
		# the letter leaves a record like the received ones: an appointment on
		# the address's own app, the attachments saved in its folders, and the
		# mailbox row's uuid in the data for an envelope to open
		&subs::sent_mail_filer({
			c => $c,
			to => $data->{'email'},
			manager_file => $es->{'email'},
			body => &subs::note_decrypter($suds, $data->{'body'}),
			mail_uuid => $data->{'uuid'},
			files => \@mail_files,
			timestamp => &subs::rightNow()
		});
	} else {
		$result = 'fail';
	}
	foreach my $loc ( @locations ) {
		system('shred', '-u', $loc);
	}
	return $result;
}

# The instruction that tells a chat model how to ask for media, appended to the
# system message so the trigger does not depend on a magic marker the model may
# or may not emit: any model that can follow a JSON shape works. Empty when no
# generation agent is configured.
sub ai_generation_instruction {
	my ($settings) = @_;
	my @kinds;
	push @kinds, 'image' if $settings->{'text_to_image_assistant'};
	push @kinds, 'audio' if $settings->{'text_to_audio_assistant'};
	push @kinds, 'video' if $settings->{'text_to_video_assistant'};
	return '' unless @kinds;
	my $list = join ', ', map { '"' . $_ . '"' } @kinds;
	return "\n\nYou can create media for the person through these agents: $list. "
		. 'When the person asks for an image, a sound, or a video, reply with ONLY one JSON object and nothing else, '
		. 'in exactly this shape: {"action":"generate","kind":"image","prompt":"a full, self-contained description for the agent"}. '
		. 'Set "kind" to one of the agents above, and put everything the agent needs in "prompt" - do not rely on the conversation. '
		. 'Never wrap it in prose or code fences, and never invent a different shape.';
}

# The first balanced {...} object in a string, respecting quoted strings, or
# undef. Lets a reply that mixes prose with the action still be read.
sub ai_first_json_object {
	my ($text) = @_;
	return undef unless defined $text;
	my $start = index($text, '{');
	return undef if $start < 0;
	my $depth = 0;
	my $in_str = 0;
	my $esc = 0;
	my $len = length($text);
	for (my $i = $start; $i < $len; $i++) {
		my $ch = substr($text, $i, 1);
		if ($in_str) {
			if ($esc) { $esc = 0; }
			elsif ($ch eq '\\') { $esc = 1; }
			elsif ($ch eq '"') { $in_str = 0; }
		}
		elsif ($ch eq '"') { $in_str = 1; }
		elsif ($ch eq '{') { $depth++; }
		elsif ($ch eq '}') {
			$depth--;
			return substr($text, $start, $i - $start + 1) if $depth <= 0;
		}
	}
	return undef;
}

# Read a chat model's reply for a media request. Prefers the explicit JSON action
# the instruction above asks for ({"action":"generate","kind":...,"prompt":...}),
# and falls back to the legacy markers (dalle.text2 and kin) so a conversation
# configured the old way keeps working. Returns (kind, prompt) or ().
sub ai_extract_generation_action {
	my ($text) = @_;
	return () unless defined $text && length $text;
	my $clean = $text;
	$clean =~ s/<br>//gi;
	my $json = &ai_first_json_object($clean);
	if ($json) {
		my $action = eval { return decode_json $json };
		if ($action && ref $action eq 'HASH' && ($action->{'action'} || '') =~ /^generate/i) {
			my $kind = lc($action->{'kind'} || '');
			my $label = lc($action->{'action'} || '');
			$kind = 'image' if !$kind && $label =~ /image|dall/;
			$kind = 'audio' if !$kind && $label =~ /audio|sound|speech|music/;
			$kind = 'video' if !$kind && $label =~ /video|movie|clip/;
			$kind =~ s/_gen$//;
			my $prompt = $action->{'prompt'} || '';
			if (!$prompt && $action->{'action_input'}) {
				my $inner = eval { return decode_json $action->{'action_input'} };
				$prompt = ($inner && ref $inner eq 'HASH') ? ($inner->{'prompt'} || '') : $action->{'action_input'};
			}
			return ($kind, $prompt) if $prompt && grep { $_ eq $kind } qw/image audio video/;
		}
	}
	# the legacy markers, so an older conversation still generates
	my %legacy = ('dalle.text2' => 'image', 'audio.text2' => 'audio', 'video.text2' => 'video');
	foreach my $marker ( sort keys %legacy ) {
		next unless $clean =~ /\Q$marker\E/;
		my $outer = eval { return decode_json($json || '') } || {};
		my $inner = eval { return decode_json($outer->{'action_input'} || '') } || {};
		my $prompt = $inner->{'prompt'} || $outer->{'prompt'} || '';
		return ($legacy{$marker}, $prompt) if $prompt && ref $outer eq 'HASH';
	}
	return ();
}

sub pen_message {
	my $data = shift;
	my $msg = $data->{'msg'};
	my $msg_data = $data->{'msg_data'};
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'cloudflare_account', 'cloudflare_token', 'ollama_key', 'visual_assistant', 'chatbot_conversation', 'chatbot_conversations', 'chatbot_model', 'chatbot_model_fallback', 'chatbot_system_message' ] });
	my $conversations = eval { return decode_json $settings->{'chatbot_conversations'} } || {};
	my $mail_contact = $data->{'mail_contact'};
	my $conversation_uuid = $data->{'conversation_uuid'} || $settings->{'chatbot_conversation'};
	my $conversation = $conversations->{$conversation_uuid};
	my $model = $conversation->{'chatbot_model'} || $settings->{'chatbot_model'};
	my ($db,$database,$sql) = &subs::database_grabber();
	my $suds = &subs::suds_grabber();
	&subs::unix_socket_sender('memory', {
		duty => 'ai',
		message => $msg,
		model => $model
	});

	my $tally;

	my $history = [];
	unless ($data->{'type'} eq 'assistant') {
		$tally  = eval { return decode_json &subs::note_decrypter($suds,read_file(&subs::home('~/.president/pen'))) } || { '__lexicon' => [], '__statement' => [] };
		my $statements = &subs::db_query('select * from mailbox where contact=? and conversation_uuid=? limit 500', 'pen', $conversation_uuid)->hashes;
		foreach my $st ( @{$statements} ) {
			my $old_message = &subs::note_decrypter($suds, $st->{'body'});
			next unless $old_message =~ /[A-Z0-9\[\]().!?,a-z]/gi;
			if ( $data->{'contextual'} eq 'yes' ) {
				$tally = &statement_preparer($old_message,$tally);
				push @{$tally->{'__statements'}}, $old_message;
			}
			my $role = $st->{'manager_file'} eq &subs::manager_file_maker('pen') ? 'assistant' : 'user';
			push @{$history}, {role => $role, content => $old_message };
		}
	}
	else {
		push @{$history}, {role => 'user', content => $msg, images => $data->{'images'} };
		if ($data->{'images'} && $settings->{'visual_assistant'}) {
			$model = $settings->{'visual_assistant'};
		}
	}

	#$tally = &statement_preparer($msg, $tally);

	sub statement_preparer() {
		my $msg = shift;
		my $tally = shift;
		my @msg = split ' ', $msg;
		my @lexicon = @{$tally->{'__lexicon'}};
		for (my $w = 0; $w <= scalar @msg; $w++) {
			my $ms = $msg[$w];
			$tally = &word_reader($ms, $tally);

			for (my $n = 0; $n <= scalar @msg; $n++ ) {
				my $word;
				foreach my $wor ( $n .. scalar @msg ) {
					$word .= '_' . $msg[$wor];
					unless ( grep { $_ eq $word } @lexicon ) {
						push @lexicon, $word;
						&word_reader($word, $tally);
					}
				}
			}
		}
		@{$tally->{'__lexicon'}} = @lexicon;
		return $tally;
	}

	sub word_reader() {
		my $m = shift;
		my $tally = shift;
		$m =~ s/^_//gi;
		$m =~ s/_$//gi;
		$m = &subs::unformat_name($m);
		my $ms = &subs::settings_grabber({ app => $m, benign => 1 });
		if (scalar keys %{$ms} > 0 ) { #$log->info('settings for ' . $m . ' ' . scalar keys %{$ms} );
	}
		$tally->{$ms->{'app'}}->{'setting'} = $ms if scalar keys %{$ms} > 2;
		foreach my $mk ( keys %{$ms} ) {
			if ($mk =~ /^sc_/gi) {
				my $mak = $mk;
				$mak =~ s/^sc_//gi;
				$tally->{$ms->{'app'}}->{'sc'}->{$mak} = decode_json $ms->{$mk};
			}
		}
		foreach my $mo ( qw/model option option_category subcategory/ ) {
		#	my $mos = &subs::db_select($mo, undef, { name => $mo })->hashes;
		#	$tally->{$ms->{'app'}}->{$mo} = $mos if scalar @{$mos} > 0;
		}
		return $tally;
	}

	push @{$tally->{'__statements'}}, $data->{'msg'};

	my $jtally = encode_json $tally;
	write_file(&subs::home('~/.president/pen'),&subs::note_encrypter($suds,$jtally));


	my $return_msg = join ' ', grep { $_ !~ /^__/gi } keys %{$tally};
	my $SYSTEM_PROMPT = {
		role    => 'system',
		content => 'be philosophical'
	};
	my $response_text = '';


	my $ua = Mojo::UserAgent->new;
	# Tell the model, in code, how to ask for media: an explicit JSON action,
	# rather than a magic marker it may or may not emit. Only added when a
	# generation agent is configured.
	my $system_message = $data->{'system_msg'} || $conversation->{'chatbot_system_message'} || '';
	if (my $gen_hint = &ai_generation_instruction($settings)) {
		$system_message .= $gen_hint;
	}

	# The wire is the shared AI layer, so a conversation may name any model the
	# house can reach - a bare Ollama id, @cf/..., @device/model, or
	# provider:model - and the ledger records the call there, not here.
	my $role = ($data->{'images'} && $settings->{'visual_assistant'}) ? 'visual_assistant' : 'chatbot_model';
	my $thinking = &subs::ai_role_thinking_effective($role);
	my $messages = [ { role => 'system', content => $system_message }, @{$history} ];
	my $accumulated_text = '';
	my $streamed = 0;
	# Every delta is the same visible update the old direct-Ollama loop sent:
	# escaped for the mail window, newlines as <br>, appended to the reply. The
	# raw text is kept beside it, because the media action is read from what the
	# model actually wrote, not from its HTML. Reasoning is not shown here, the
	# same as the old loop, which read only message.content.
	my $sink = sub {
		my ($kind, $piece) = @_;
		return unless defined $piece && length $piece;
		return unless $kind eq 'text';
		$streamed = 1;
		my $text = unidecode($piece);
		$accumulated_text .= $text;
		unless ($data->{'type'} eq 'assistant') {
			# The reply is HTML in the mail window: escape it there too, or a model answer carrying a tag runs it in WebEngine.
			$text = &subs::html_text($text);
			$text =~ s/\n/<br>/gi;
			$response_text .= $text;
			&Websocket::mail_send({
				type => 'writing',
				uuid => $msg_data->{'uuid'} || $data->{'uuid'},
				new_text => $text,
				all_text => $response_text,
				mail_contact => 'pen'
			});
		}
		else {
			$text = &subs::html_text($text);
			$text =~ s/\n/<br>/gi;
			$response_text .= $text;
			&Websocket::send('tab', {
				console => &Websocket::console_command('setHtml', $data->{'uuid'}, $response_text)
			});
		}
		*STDOUT->flush;
	};
	# The helper already tries the conversation's model and then the configured
	# fallback, so an outage costs one answer, not a hand-rolled retry loop.
	# count_unmetered is the contract with the ledger: a provider that reports no
	# usage still records the call (and the app that made it).
	my ($parts, $wire_error) = &subs::ai_chat_parts_with_fallback(
		$model,
		$settings->{'chatbot_model_fallback'},
		$messages,
		$thinking,
		$role,
		{ on_delta => $sink, app => 'pen', count_unmetered => 1 }
	);
	if ($wire_error) {
		# Both the conversation's model and its fallback were tried inside the
		# helper; there is no third model to guess at, so the window keeps what it
		# already showed and the caller gets that.
		$log->info('Pen: ' . $model . ' and its fallback failed: ' . $wire_error);
	}
	elsif (!$streamed) {
		# Cloudflare and a peer's Ollama answer whole, and a provider that ignores
		# the stream flag sends one JSON body; the reply is sent once instead.
		my $wire_text = join '', map { $_->{'text'} } grep { ($_->{'type'} || '') eq 'text' } @{$parts || []};
		if (length $wire_text) {
			$accumulated_text = unidecode($wire_text);
			$response_text = &subs::html_text($accumulated_text);
			$response_text =~ s/\n/<br>/gi;
			if ($data->{'type'} eq 'assistant') {
				&Websocket::send('tab', {
					console => &Websocket::console_command('setHtml', $data->{'uuid'}, $response_text)
				});
			}
			else {
				&Websocket::mail_send({
					type => 'writing',
					uuid => $msg_data->{'uuid'} || $data->{'uuid'},
					new_text => $response_text,
					all_text => $response_text,
					mail_contact => 'pen'
				});
			}
		}
	}
	my $attachments = [];
	# Read the reply for a media request: the explicit JSON action the system
	# message asks for, or the legacy markers so older conversations still work.
	my ($generating_kind, $extracted_prompt) = &ai_extract_generation_action($accumulated_text);
	if ($generating_kind) {
		if ($extracted_prompt) {
			# name who is doing the work, before the (slow) generation call, as a
			# visible working note with a spinner (the client shows all_text)
			my $gen_model = ($generating_kind eq 'image') ? ($settings->{'text_to_image_assistant'} || $model)
				: ($generating_kind eq 'audio') ? ($settings->{'text_to_audio_assistant'} || '')
				: ($settings->{'text_to_video_assistant'} || '');
			my $gen_note = '<span class="ai_generating" style="display:inline-flex;align-items:center;gap:7px;opacity:.85;">'
				. '<span style="width:12px;height:12px;border:2px solid currentColor;border-top-color:transparent;border-radius:50%;display:inline-block;animation:ai_generating_spin .8s linear infinite;"></span>'
				. 'Generating ' . $generating_kind . ' with ' . ($gen_model || 'the ' . $generating_kind . ' agent') . "\x{2026}"
				. '<style>@keyframes ai_generating_spin{to{transform:rotate(360deg)}}</style>'
				. '</span>';
			if ($data->{'type'} eq 'assistant') {
				&Websocket::send('tab', { console => &Websocket::console_command('setHtml', $data->{'uuid'}, $gen_note) });
			}
			else {
				&Websocket::mail_send({
					type => 'writing',
					uuid => $msg_data->{'uuid'} || $data->{'uuid'},
					all_text => $gen_note,
					mail_contact => 'pen'
				});
			}

	    my ($media_url,$attachment) = &generate_ai_media({
				ua => $ua,
				kind => $generating_kind,
				prompt => $extracted_prompt,
				msg_uuid => $data->{'uuid'},
				settings => $settings,
				model => $gen_model,
				conversation => $conversation,
				mail_contact => $mail_contact,
				unclaimed => ($conversation->{'chatbot_conversation_name'} ? 0 : 1)
			});
	    $attachments = $attachment if $attachment;
	    if ($media_url) {
        my $safe_url = &subs::html_text($media_url);
        my $html = ($generating_kind eq 'image')
					? '<img src="' . $safe_url . '" class="chat-generated-img" style="width:100%;"/><br>'
					: '<a href="' . $safe_url . '" class="chat-generated-file">' . &subs::html_text($generating_kind) . '</a><br>';
        $accumulated_text = $html;
				$response_text = $html;
				unless ($data->{'type'} eq 'assistant') {
					&Websocket::mail_send({
						type => 'writing',
						uuid => $msg_data->{'uuid'} || $data->{'uuid'},
						all_text => $accumulated_text,
						mail_contact => 'pen'
					});
				} else {
					&Websocket::send('tab', {
						console => &Websocket::console_command('setHtml', $data->{'uuid'}, $accumulated_text)
					});
				}
	    }
		}
	}
	return ($response_text,$attachments);

}

# Pen's picker rows, from the shared catalogue: every chat-capable model from
# every configured provider, peer Ollamas included. The catalogue is grouped by
# provider, and each row keeps that group's label so a picker can draw the
# provider header and list the model under it. The value is the id the wire reads
# back - a bare Ollama name, @cf/..., @device/model, or provider:model - left
# exactly as the catalogue stamped it; the first of a repeated id wins, so a
# model both a provider list and a peer advertises appears once. `name` is the
# full "provider · model" label (a flat select keeps its context), `short` the
# model alone (a grouped one takes the provider from the header).
sub pen_model_choices {
	my ($catalogue) = @_;
	return [] unless ref $catalogue eq 'ARRAY';
	my (@choices, %seen);
	foreach my $group ( @{$catalogue} ) {
		next unless ref $group eq 'HASH' && ref $group->{'models'} eq 'ARRAY';
		my $label = $group->{'label'} || $group->{'id'} || '';
		# Ai2 writes a peer's label with the middle dot as a literal \x{00b7}
		# escape; a picker row shows the character, not the escape.
		$label =~ s/\\x\{00b7\}/\x{00b7}/g;
		foreach my $m ( @{ $group->{'models'} } ) {
			next unless ref $m eq 'HASH';
			my $value = $m->{'value'};
			next unless defined $value && length $value;
			next if $seen{$value}++;
			my $name = $m->{'name'};
			$name = $value unless defined $name && length $name;
			my $full = ($label && $label ne $name) ? $label . " \x{00b7} " . $name : $name;
			push @choices, { model => $value, name => $full, short => $name, group => $label, trial => ($m->{'trial'} ? 1 : 0) };
		}
	}
	return \@choices;
}

sub pen_model_list {
	# A provider probe must not hold a worker open: the old client had no bound,
	# so a host that accepted the connection and stalled could miss the prefork
	# heartbeat. A refused connection (no Ollama) still answers at once.
	my $ua = Mojo::UserAgent->new(connect_timeout => 2, inactivity_timeout => 5, request_timeout => 8);
	my $url = 'http://localhost:11434/api/tags';

	# Fetch the list of models from Ollama synchronously. A machine with no Ollama
	# daemon (the server, for one) is a normal state: a refused connection must
	# leave an empty list and a note in the log, never take the Plat page down.
	my $tx = eval { $ua->get($url) };

	my $models_list = [];
	my $res = $tx ? eval { $tx->result } : undef;
	if ($res) {
		if ($res->is_success) {
			# Parse the JSON response safely
			my $data = eval { decode_json($res->body) };
			if (!$@ && $data && ref $data->{'models'} eq 'ARRAY') {
				foreach my $model_info (@{$data->{'models'}}) {
					# Push just the model string identifier (e.g., 'qwen2.5-coder:7b')
					push @{$models_list}, $model_info;
				}
			}
		} else {
			$log->error('Ollama connection failed with status: ' . $res->code);
		}
	} else {
		my $err = $tx ? eval { $tx->error } : undef;
		$log->error('Ollama API request failed: ' . (($err && $err->{'message'}) || $@ || 'no response'));
	}
	$log->info(Dumper $models_list);
	return $models_list;
}

sub cloudflare_model_list {

	# A model-list poll is a background nicety, not a reason for a worker to
	# miss the 200 s prefork heartbeat: bound the connect and the whole request.
	my $ua = Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 8, request_timeout => 12);
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'cloudflare_token', 'cloudflare_account'] });
  my $cloudflare_account = $settings->{'cloudflare_account'};
  my $cloudflare_token = &subs::note_decrypter(&subs::suds_grabber(), $settings->{'cloudflare_token'}); # or cf_token
	$log->info('doing the cloudflare model list');
	if ($cloudflare_account && $cloudflare_token) {
		$log->info('got the account and token');
		my $url = 'https://api.cloudflare.com/client/v4/accounts/'. $cloudflare_account . '/ai/models/search?page=1&per_page=1000';


		# Fetch the list of Cloudflare models synchronously. The same rule as the
		# Ollama probe: an unreachable API leaves an empty list, not a dead page.
		my $tx = eval { $ua->get($url => {
		    'Authorization' => "Bearer $cloudflare_token",
		    'Content-Type'  => 'application/json'
		}) };

		my $models_list = [];
		$log->info($url);
		my $res = $tx ? eval { $tx->result } : undef;
		if ($res) {
			if ($res->is_success) {
				# Parse the JSON response safely
				my $data = eval { decode_json($res->body) };
				if (!$@ && $data && ref $data->{'result'} eq 'ARRAY') {
					foreach my $model_info (@{$data->{'result'}}) {
						$model_info->{'model'} = $model_info->{'name'};
						foreach my $p ( @{$model_info->{'properties'}} ) {
							if ($p->{'property_id'} eq 'price') {
								$model_info->{'price'} = $p->{'value'}->[0]->{'price'};
							}
						}



						push @{$models_list}, $model_info;
					}
				}
			} else {
				$log->error('Cloudflare connection failed with status: ' . $res->code);
			}
		} else {
			my $err = $tx ? eval { $tx->error } : undef;
			$log->error('Cloudflare API request failed: ' . (($err && $err->{'message'}) || $@ || 'no response'));
		}
		$log->info(Dumper $models_list);
		return $models_list;
	}
	else { return []; }
}

# The Help window's model dropdown is house-wide and normally changes only when
# a provider adds or removes a model. It offers every chat model from every
# provider that can answer here (a key entered, or the models the local Ollama
# reported), grouped by provider. The probe is cached, keyed by the provider
# set, so adding a provider shows at once and an unchanged list opens instantly.
sub help_model_list {
	my $sig = &subs::ai_catalogue_signature();
	my $context = 'help_models_' . $sig;
	my $cached = &subs::cache_get({ app => 'mail', context => $context });
	return $cached if ref $cached eq 'ARRAY';
	my $catalogue = &subs::ai_model_catalogue('chat');
	my @ready = grep {
		my $id = $_->{'id'} || '';
		($id eq 'ollama' || $id =~ /^ollama:/)
			? scalar @{ $_->{'models'} || [] }
			: &subs::ai_provider_ready($id)
	} @{ ref $catalogue eq 'ARRAY' ? $catalogue : [] };
	my $choices = &pen_model_choices(\@ready);
	&subs::cache_set({ app => 'mail', context => $context, warranty => '-10m' }, $choices);
	return $choices;
}

1;
