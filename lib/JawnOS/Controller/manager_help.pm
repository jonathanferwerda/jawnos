package Manager;

# manager_help: route actions moved out of Manager.pl, one sub per route so a
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

# The Help app: a window into the topic registry (help.pl). /manager/help wraps
# the contents in a window like every other app; /manager/help/body returns just
# the contents, so a topic click or a search swaps the pane in place without
# rebuilding (and re-raising) the whole window.
# GET /manager/help
sub action_34641 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	# the model list the guide's dropdown is built from — the same agents the
	# mailbox's Pen offers, so the choice is made in one place
	my $models = &subs::help_model_list();
	my $selected_model = &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
	my $contents = $c->render_to_string(
		template => 'apps/help',
		topic => $c->param('topic'),
		search => $c->param('search'),
		models => $models,
		selected_model => $selected_model
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'help', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# GET /manager/help/body
sub action_34659 {
	my $c = shift;
	my $html = $c->render_to_string(
		template => 'apps/help',
		topic => $c->param('topic'),
		search => $c->param('search'),
		models => undef,
		selected_model => ''
	);
	$c->render(text => $html);
}

# Whether this install has met the welcome tour yet. The flag is a settings row
# (see help::welcome_seen), so it is per install rather than per browser; the
# Help window asks this on load and opens the tour once when it is absent.
# Marking it is a separate press so a page that never reaches the tour does not
# spend the first run.
# GET /manager/help/welcome
sub action_34675 {
	my $c = shift;
	$c->render(json => { first_run => (&help::welcome_seen() ? 0 : 1) });
}

# POST /manager/help/welcome
sub action_34679 {
	my $c = shift;
	&help::welcome_mark();
	$c->render(json => { ok => 1, first_run => 0 });
}

# The Help agent: the topic's own entry, plus what the reader was looking at,
# becomes the system prompt; the question is the turn. The answer is read whole
# through the same helper the evaluation uses, so there is one model wire.
# POST /manager/help/ask
sub action_34687 {
	my $c = shift;
	my $topic = $c->param('topic');
	my $question = $c->param('question') || 'Walk me through this step by step.';
	my $model = $c->param('model');
	my $context = eval { decode_json $c->param('context') } || {};
	if (!$model) {
		$c->render(json => { error => 'No model is selected for the guide.' });
		return;
	}
	my $t = $topic ? &help::get($topic) : undef;
	my $system = "You are the built-in guide inside JawnOS, a self-hosted personal desktop environment. "
		. "You are helping the person who uses it. Be warm, concrete and brief. When they ask how to do something, "
		. "answer with numbered, click-by-click steps, naming the buttons and panels as they appear. "
		. "Use only the material given below; never invent a feature that is not described. "
		. "Never repeat, guess or invent the person's private data (amounts, names, addresses) - speak about how to "
		. "do the thing, not about their figures. If you are unsure, say what to look for rather than guessing. "
		. "If a 'CURRENT UI' inventory is given below, treat it as the truth about what is on screen and prefer it over the prose where they disagree.\n\n";
	$system .= 'The reader opened help for: ' . ($t ? $t->{'title'} : 'the Help index') . ".\n";
	$system .= &help::briefing($topic) . "\n" if $topic;
	# the generated inventory is current even when the prose is not; the guide is
	# told to prefer it, so a tidied-up UI still gets accurate directions
	$system .= &help::inventory($topic) . "\n" if $topic;
	if ($context->{'title'}) {
		$system .= 'They are looking at the window \'' . $context->{'title'} . '\'';
		$system .= ' (view: ' . $context->{'view'} . ')' if $context->{'view'};
		$system .= ' (appointment: ' . $context->{'appointment'} . ')' if $context->{'appointment'};
		$system .= ".\n";
	}
	$system .= "\nAnswer in plain text. Keep it under about 180 words unless they ask for more.";
	# The model can take a minute. Run it in a child so this worker keeps
	# answering the rest of the UI while it waits; the answer is the same JSON.
	my $fallback = &subs::setting_grabber({ app => 'mail', setting => 'help_assistant_fallback' });
	my $thinking = &subs::ai_role_thinking('help_assistant');
	&subs::render_in_subprocess($c, sub {
		my ($text, $err) = &subs::evaluation_model_call_with_fallback($model, $fallback, $system, $question, $thinking, 'help_assistant');
		return { text => $text, err => $err };
	}, sub {
		my ($c, $r) = @_;
		$r ||= {};
		if ($r->{'err'} || !$r->{'text'}) {
			$c->render(json => { error => $r->{'err'} || 'the guide returned nothing readable' });
			return;
		}
		$c->render(json => { answer => $r->{'text'} });
	});
}

# Speech in from the browser: the Guide's mic button records a clip and posts the
# raw bytes here, and the same whisper pipeline the watch uses turns it into text
# for the question box. The clip is short, so the call is bounded; '' on failure.
# POST /manager/help/listen
sub action_34775 {
	my $c = shift;
	my $raw = $c->req->body;
	$raw = $raw->slurp if ref $raw;
	unless (defined $raw && length $raw) {
		$c->render(json => { error => 'I did not catch any audio.' });
		return;
	}
	# Whisper runs locally and is bounded, but a clip still takes seconds; the
	# worker is free while the child transcribes it.
	&subs::render_in_subprocess($c, sub {
		return &subs::whisper_transcribe($raw);
	}, sub {
		my ($c, $text) = @_;
		if (!defined $text || !length $text) {
			$c->render(json => { error => 'I could not make out any words.' });
			return;
		}
		$c->render(json => { text => $text });
	});
}

# The verdict on a guide answer - the person's "was that good?" signal. Kept in
# one setting as a bounded ring so a machine can read the recent run back without
# a table of its own.
# POST /manager/help/feedback
sub action_34799 {
	my $c = shift;
	my $rows = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'guide_feedback' }) } || [];
	$rows = [] unless ref $rows eq 'ARRAY';
	push @{$rows}, {
		ts => &subs::rightNow(),
		topic => substr($c->param('topic') || '', 0, 200),
		question => substr($c->param('question') || '', 0, 500),
		answer => substr($c->param('answer') || '', 0, 1000),
		good => ($c->param('good') ? 1 : 0),
		device => &subs::device_setter()
	};
	splice @{$rows}, 0, scalar(@{$rows}) - 200 if scalar @{$rows} > 200;
	&subs::setting_setter({ app => '__president', setting => 'guide_feedback', value => encode_json $rows });
	$c->render(json => { ok => 1 });
}

# One turn of the acting guide: the model picks the next action, the browser runs
# it. The vocabulary is closed - anything the model returns outside it becomes a
# plain reply, so a model can never reach past the client's fixed verbs.
# POST /manager/help/act
sub action_34818 {
	my $c = shift;
	my $model = $c->param('model');
	my $topic = $c->param('topic');
	# Mojo hands params back as character strings, but decode_json wants UTF-8
	# bytes: a single non-ASCII character (an em dash in the guide's own wording,
	# say) would make the decode fail, leaving an empty thread for every turn
	# after the first. Encode back to bytes before decoding.
	my $context_json = $c->param('context') // '';
	utf8::encode($context_json) if utf8::is_utf8($context_json);
	my $context = eval { decode_json $context_json } || {};
	my $transcript_json = $c->param('transcript') // '';
	utf8::encode($transcript_json) if utf8::is_utf8($transcript_json);
	my $transcript = eval { decode_json $transcript_json } || [];
	if (!$model) {
		$c->render(json => { error => 'No model is selected for the guide.' });
		return;
	}
	my $t = $topic ? &help::get($topic) : undef;
	# The page agent: a window the person attached the Guide to. Its visible form
	# is described below, keyed the way page_agent.js wrote it onto the elements, so
	# the model names a real field rather than guessing a selector. The page verb is
	# only offered on a turn that actually carries a page, so no other associate is
	# handed a form it cannot see.
	my $page_json = $c->param('page') // '';
	utf8::encode($page_json) if utf8::is_utf8($page_json);
	my $page = eval { decode_json $page_json } || {};
	my $page_on = (ref $page eq 'HASH' && length($page->{'title'} // $page->{'app'} // '')) ? 1 : 0;
	my $system = &help::actions_prompt(undef, $page_on) . "\n\n";
	# the guide is given the wall clock so it can turn "last year", "yesterday" and
	# "next Friday" into the absolute dates where_when and create need
	$system .= 'Right now it is ' . localtime(&subs::rightNow() / 1000)->strftime('%A, %B %d %Y, %I:%M%P') . ".\n";
	$system .= 'Their birthday is ' . $config->{'birthday'} . ".\n" if $config->{'birthday'};
	$system .= 'The reader opened help for: ' . ($t ? $t->{'title'} : 'the Help index') . ".\n";
	$system .= &help::briefing($topic) . "\n" if $topic;
	$system .= &help::inventory($topic) . "\n" if $topic;
	if ($context->{'title'}) {
		$system .= 'They are looking at the window \'' . $context->{'title'} . '\''
			. ($context->{'view'} ? ' (view: ' . $context->{'view'} . ')' : '')
			. ($context->{'appointment'} ? ' (appointment: ' . $context->{'appointment'} . ')' : '') . ".\n";
	}
	# The page agent: a window the person attached the Guide to. Its visible form
	# is described here, keyed the way page_agent.js wrote it onto the elements, so
	# the model names a real field rather than guessing a selector.
	if ($page_on) {
		my $clean = sub {
			my ($v, $max) = @_;
			$v = '' unless defined $v;
			$v = "$v";
			$v =~ s/[\r\n\t]+/ /g;
			$v =~ s/"/'/g;
			return substr($v, 0, $max || 120);
		};
		$system .= "\nPAGE ON SCREEN - the person added you to the window '" . $clean->($page->{'title'} || $page->{'app'}, 80) . "'. You may work with its form using the page action.\n";
		$system .= "Fields (use these exact keys in \"field\"):\n";
		my $seen = 0;
		foreach my $f ( @{ $page->{'fields'} || [] } ) {
			last if ++$seen > 60;
			next unless ref $f eq 'HASH';
			my $line = '- ' . $clean->($f->{'field'}, 20) . ': "' . $clean->($f->{'label'}, 80) . '" [' . $clean->($f->{'type'}, 20);
			$line .= ', id ' . $clean->($f->{'id'}, 60) if length($f->{'id'} // '');
			$line .= ', class ' . $clean->($f->{'class'}, 60) if length($f->{'class'} // '');
			$line .= ', read only' if $f->{'readonly'};
			$line .= ']';
			$line .= ' options: ' . join(' | ', map { $clean->($_, 40) } @{ $f->{'options'} }) if ref $f->{'options'} eq 'ARRAY' && @{ $f->{'options'} };
			$line .= ' now: "' . ($f->{'secret'} ? '(hidden)' : $clean->($f->{'value'}, 120)) . '"';
			$system .= $line . "\n";
		}
		$system .= "(no fields are visible on this page)\n" if !$seen;
		my @page_buttons;
		foreach my $b ( @{ $page->{'buttons'} || [] } ) {
			next unless ref $b eq 'HASH';
			my $label = $clean->($b->{'label'}, 50);
			my $hint = $clean->($b->{'hint'}, 60);
			push @page_buttons, $clean->($b->{'target'}, 20) . (length $label ? ' "' . $label . '"' : '') . (length $hint ? ' (' . $hint . ')' : '');
		}
		$system .= 'Buttons (use these exact keys in "target"): ' . join('; ', @page_buttons) . "\n" if @page_buttons;
		$system .= "Fill only from the person's words, this conversation or their records - never invent a value. Never fill a password, and never press a send, pay or delete button. After a fill, say what changed and stop unless they asked for it to be sent.\n";
	}
	my @lines;
	foreach my $m ( @{$transcript} ) {
		my $role = $m->{'role'} || 'user';
		my $content = $m->{'content'} || '';
		if ($role eq 'assistant') {
			# The guide's own turns say how the turn before them ended. A JSON action is
			# already told by the observation that follows, so it is left out; a plain
			# answer is carried as "ANSWERED:" so the model can see that question was
			# already dealt with, and turns to the newest one instead of answering the
			# whole backlog. Served back as an "ASSISTANT:" turn, the model flips into
			# chat mode and greets instead of acting.
			next if $content =~ /^\s*\{/;
			$content =~ s/\s+/ /g;
			push @lines, 'ANSWERED: ' . $content;
			next;
		}
		my $label = $role eq 'tool' ? 'OBSERVATION' : 'USER';
		push @lines, $label . ': ' . $content;
	}
	push @lines, '', 'Answer only the newest USER line - the USER lines before it are history you already answered. Reply with the single next JSON action.';
	# The model call can take a minute; the action it names is read here, after
	# the child returns, so every write (an alias, a staged appointment) still
	# happens in the request worker.
	my $fallback = &subs::setting_grabber({ app => 'mail', setting => 'help_assistant_fallback' });
	my $thinking = &subs::ai_role_thinking('help_assistant');
	&subs::render_in_subprocess($c, sub {
		# The reply arrives as parts so the model's reasoning is kept apart from its
		# answer: the answer is what the action parser reads, the reasoning is shown
		# beside it and never fed back into a later turn.
		my ($parts, $err) = &subs::ai_chat_parts_with_fallback(
			$model, $fallback,
			[ { role => 'system', content => $system },
			  { role => 'user', content => join("\n", @lines) } ],
			$thinking, 'help_assistant'
		);
		my $text = &subs::ai_parts_text($parts, 'text');
		my $reason = &subs::ai_parts_text($parts, 'reasoning');
		$reason = substr($reason, 0, 4000) . '…' if length $reason > 4000;
		return { text => $text, thinking => $reason, err => $err };
	}, sub {
		my ($c, $r) = @_;
		$r ||= {};
		my ($text, $err) = ($r->{'text'}, $r->{'err'});
		if ($err || !$text) {
			$c->render(json => { error => $err || 'the guide returned nothing readable' });
			return;
		}
		my $action = &subs::json_from_model($text);
		# the allow-list is the same registry the prompt is built from, plus the
		# runtime (learned) verbs, so the guide may pick either
		my $allowed = &help::live_verb_names();
		delete $allowed->{'page'} unless $page_on;
		if ($action && ref $action eq 'HASH') {
			# Teaching a word for a thing is a write on this machine, not a client
			# action: store it and answer in words.
			if (($action->{'action'} || '') eq 'alias') {
				my $r = &guide_alias_add($action->{'alias'}, $action->{'target'});
				$action = { action => $r->{'ok'} ? 'say' : 'ask', text => $r->{'text'} || '' };
			}
			elsif (($action->{'action'} || '') eq 'unalias') {
				my $r = &guide_alias_remove($action->{'alias'});
				$action = { action => $r->{'ok'} ? 'say' : 'ask', text => $r->{'text'} || '' };
			}
			else {
				$action = &guide_resolve_action($action);
			}
		}
		my $reason = $r->{'thinking'} // '';
		if ($action && $action->{'action'} && $allowed->{ $action->{'action'} }) {
			# translation tools run through the same model the Guide is using this turn
			$action->{'model'} = $model if ($action->{'action'} // '') =~ /^translate/;
			my $out = { action => $action, raw => $text };
			$out->{'thinking'} = $reason if length $reason;
			$c->render(json => $out);
		}
		else {
			my $out = { action => { action => 'say', text => $text } };
			$out->{'thinking'} = $reason if length $reason;
			$c->render(json => $out);
		}
	});
}

# What the guide's find action sees: appointments whose app, file or notes match,
# summarised as the apps involved and a few matching file names.
# GET /manager/help/find
sub action_35016 {
	my $c = shift;
	$c->render(json => help_search($c->param('q') // '', &media_unlock_device($c)));
}

# A value the person already keeps in this house, for the page agent to fill in:
# their own contact fields and notes from the appointments log, notes and mail.
# Only rows whose app the visibility rule shows here are read, and credentials,
# settings and device tables are never touched, so a lookup cannot hand a model
# a secret. The words searched are the person's own.
# GET /manager/help/lookup
sub action_35025 {
	my $c = shift;
	my $q = $c->param('q') // '';
	$q =~ s/^\s+|\s+$//g;
	if (length($q) < 2) {
		$c->render(json => { ok => 0, rows => [], error => 'Give me a word to look up.' });
		return;
	}
	my $device = &media_unlock_device($c);
	my $like = '%' . join('%', split /\s+/, $q) . '%';
	my $clean = sub {
		my ($v) = @_;
		return '' unless defined $v;
		$v = "$v";
		$v =~ s/\s+/ /g;
		$v =~ s/^\s+|\s+$//g;
		return substr($v, 0, 500);
	};
	my @rows;
	my $appts = eval { &subs::db_query("select app, notes, phone, email, timestamp from appointments where app like ? or notes like ? or phone like ? or email like ? order by timestamp desc limit 12", $like, $like, $like, $like)->hashes } || [];
	foreach my $r ( @{$appts} ) {
		next unless &help_app_visible($r->{'app'}, $device);
		next if &subs::appointment_private_now($r);
		my @bits;
		push @bits, 'phone ' . $clean->($r->{'phone'}) if length($r->{'phone'} // '');
		push @bits, 'email ' . $clean->($r->{'email'}) if length($r->{'email'} // '');
		push @bits, 'note ' . $clean->($r->{'notes'}) if length($r->{'notes'} // '');
		next unless @bits;
		push @rows, { source => 'appointment', app => $r->{'app'}, when => $r->{'timestamp'}, text => join('; ', @bits) };
	}
	# A tombstoned note is still a row for the sync's sake, but its words are gone
	# as far as the Guide is concerned, exactly as they are in the Notes app.
	my $notes = eval { &subs::db_query("select app, text, timestamp from notes where text like ? and coalesce(ost, '') != ? order by timestamp desc limit 10", $like, &subs::notes_delete_marker())->hashes } || [];
	foreach my $r ( @{$notes} ) {
		next unless &help_app_visible($r->{'app'}, $device);
		my $text = $clean->($r->{'text'});
		next unless length $text;
		push @rows, { source => 'note', app => $r->{'app'}, when => $r->{'timestamp'}, text => $text };
	}
	my $mail = eval { &subs::db_query("select app, subject, phone, email, body, timestamp from mailbox where subject like ? or body like ? order by timestamp desc limit 8", $like, $like)->hashes } || [];
	foreach my $r ( @{$mail} ) {
		next unless &help_app_visible($r->{'app'}, $device);
		my @bits;
		push @bits, 'subject ' . $clean->($r->{'subject'}) if length($r->{'subject'} // '');
		push @bits, 'phone ' . $clean->($r->{'phone'}) if length($r->{'phone'} // '');
		push @bits, 'email ' . $clean->($r->{'email'}) if length($r->{'email'} // '');
		push @bits, 'body ' . $clean->($r->{'body'}) if length($r->{'body'} // '');
		next unless @bits;
		push @rows, { source => 'mail', app => $r->{'app'}, when => $r->{'timestamp'}, text => join('; ', @bits) };
	}
	@rows = @rows[0 .. 15] if @rows > 16;
	$c->render(json => { ok => 1, rows => \@rows });
}

# GET /manager/help/where
sub action_35405 {
	my $c = shift;
	$c->render(json => help_where($c->param('when')));
}

# "show me a place" - resolve a name to coordinates we already hold: a home
# plate of something named for it (an exact app wins), else the middle of all of
# them (every "sarnia" pin, together, stands in for Sarnia). No geocoder.
# GET /manager/help/place
sub action_35412 {
	my $c = shift;
	my $q = $c->param('q') // '';
	$q =~ s/^\s+//; $q =~ s/\s+$//;
	if (!length $q) { $c->render(json => { error => 'no place named' }); return; }
	my $like = '%' . join('%', split /\s+/, $q) . '%';
	my $rows = &subs::db_query("select app, value from settings where setting = 'home_plate' and app like ? limit 300", $like)->hashes;
	my @pts;
	foreach my $r ( @{$rows} ) {
		my $hp = eval { decode_json $r->{'value'} } || {};
		next unless $hp->{'latitude'} && $hp->{'longitude'};
		push @pts, { app => $r->{'app'}, lat => $hp->{'latitude'} + 0, lon => $hp->{'longitude'} + 0 };
	}
	if (!@pts) {
		# a place that only exists as a tracked fix
		my $crows = &subs::db_query("select app, latitude, longitude from continent where app like ? and latitude is not null and latitude != '' limit 300", $like)->hashes;
		foreach my $r ( @{$crows} ) {
			next unless $r->{'latitude'} =~ /^-?[0-9.]+$/ && $r->{'longitude'} =~ /^-?[0-9.]+$/;
			push @pts, { app => $r->{'app'}, lat => $r->{'latitude'} + 0, lon => $r->{'longitude'} + 0 };
		}
	}
	if (!@pts) { $c->render(json => { place => $q, found => 0, error => 'I have no measured place by that name.' }); return; }
	my $exact = &subs::unformat_name($q);
	my ($sel) = grep { $_->{'app'} eq $exact } @pts;
	my ($lat, $lon, $label);
	if ($sel) { ($lat, $lon, $label) = ($sel->{'lat'}, $sel->{'lon'}, &subs::format_name($exact)); }
	else {
		my ($sx, $sy) = (0, 0);
		foreach my $p ( @pts ) { $sx += $p->{'lat'}; $sy += $p->{'lon'}; }
		$lat = $sx / scalar @pts; $lon = $sy / scalar @pts;
		$label = &subs::format_name($exact);
	}
	my ($near, $nd);
	foreach my $p ( @pts ) {
		next if $sel && $p->{'app'} eq $exact;
		my $d = help_distance_km($lat, $lon, $p->{'lat'}, $p->{'lon'});
		($near, $nd) = ($p, $d) if !defined $nd || $d < $nd;
	}
	$c->render(json => {
		place => $label, found => 1, latitude => $lat, longitude => $lon,
		count => scalar @pts, near => ($near ? &subs::format_name($near->{'app'}) : undef),
		near_km => (defined $nd ? sprintf('%.3f', $nd) : undef)
	});
}

# GET /manager/help/measure
sub action_35508 {
	my $c = shift;
	$c->render(json => help_measure($c->param('measure'), $c->param('period'), $c->param('target')));
}

# GET /manager/help/music
sub action_35573 {
	my $c = shift;
	my $q = $c->param('q') // '';
	if (!length $q) { $c->render(json => { error => 'no music named' }); return; }
	$c->render(json => help_music_file($c, $q, $c->param('shuffle')));
}

# GET /manager/help/permitted
sub action_35579 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app') || '');
	$c->render(json => { app => $app, permitted => (help_app_visible($app, &media_unlock_device($c)) ? 1 : 0) });
}

# POST /manager/help/schedule
sub action_36628 {
	my $c = shift;
	$c->render(json => guide_apply_schedule($c, $c->param('token'), $c->param('text')));
}

# POST /manager/help/stage
sub action_36632 {
	my $c = shift;
	# the id the resolver gave the client wins over the name, and a name that now
	# means more than one thing asks instead of staging onto the wrong one
	my $r = &guide_request_app($c->param('app'), $c->param('app_uuid'), { exact => 1 });
	return $c->render(json => { ask => $r->{'ask'} }) unless $r->{'ok'};
	$c->render(json => guide_stage_appointment($c, {
		app => $r->{'app'}, type => $c->param('type'), timestamp => $c->param('timestamp'),
		title => $c->param('title'), notes => $c->param('notes'), data => $c->param('data'),
		duration => $c->param('duration'), source => $c->param('source')
	}));
}

# POST /manager/help/promote
sub action_36644 {
	my $c = shift;
	$c->render(json => guide_promote_staged($c, $c->param('uuid')));
}

# POST /manager/help/discard
sub action_36648 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	&subs::db_update('staged_appointments', { status => 'discarded' }, { uuid => $uuid });
	$c->render(json => { discarded => $uuid });
}

# The Guide changes an appointment that already exists: stage the change as a
# proposal (promote applies it), the same shape a create uses.
# POST /manager/help/update
sub action_36656 {
	my $c = shift;
	my $r = &guide_request_app($c->param('app'), $c->param('app_uuid'));
	return $c->render(json => { ask => $r->{'ask'} }) unless $r->{'ok'};
	$c->render(json => guide_stage_update($c, {
		app => $r->{'app'}, app_uuid => $r->{'uuid'}, title => $c->param('title'), delay => $c->param('delay'),
		when => $c->param('when'), duration => $c->param('duration'), notes => $c->param('notes')
	}));
}

# Stop the app's running appointment (now, or at a named moment). Not staged - a stop
# acts at once, and the undo stack can put it back.
# POST /manager/help/stop
sub action_36667 {
	my $c = shift;
	my $r = &guide_request_app($c->param('app'), $c->param('app_uuid'));
	return $c->render(json => { ask => $r->{'ask'} }) unless $r->{'ok'};
	$c->render(json => guide_stop_appointment($c, { app => $r->{'app'}, app_uuid => $r->{'uuid'}, when => $c->param('when'), title => $c->param('title') }));
}

# Delete one of the app's appointments: stage the delete as a proposal a promote
# carries out.
# POST /manager/help/delete
sub action_36675 {
	my $c = shift;
	my $r = &guide_request_app($c->param('app'), $c->param('app_uuid'));
	return $c->render(json => { ask => $r->{'ask'} }) unless $r->{'ok'};
	$c->render(json => guide_stage_delete($c, {
		app => $r->{'app'}, app_uuid => $r->{'uuid'}, title => $c->param('title'), when => $c->param('when'), which => $c->param('which')
	}));
}

# Undo the Guide's last appointment change: put back the fields it set.
# POST /manager/help/undo
sub action_36684 {
	my $c = shift;
	my $rec = guide_undo_pop();
	return $c->render(json => { ok => 0, error => 'there is nothing to undo' }) unless $rec && $rec->{'uuid'};
	# undoing a delete puts the row back; undoing a change restores the fields it set
	if (($rec->{'kind'} || '') eq 'delete') {
		my $row = $rec->{'row'};
		return $c->render(json => { ok => 0, error => 'there is nothing to put back' }) unless ref $row eq 'HASH' && scalar keys %{$row};
		my %insert = %{$row};
		$insert{'server_time'} = &subs::rightNow();
		&subs::db_insert('appointments', \%insert);
		&subs::appt_toggle_checker($rec->{'app'});
		&guide_refresh_app($rec->{'app'}, $rec->{'uuid'});
		return $c->render(json => { ok => 1, app => $rec->{'app'}, summary => 'put back the "' . &subs::format_name($rec->{'app'}) . '" appointment' });
	}
	my $target = &subs::db_select('appointments', undef, { uuid => $rec->{'uuid'} })->hash;
	return $c->render(json => { ok => 0, error => 'that appointment is gone' }) unless $target;
	my %set = ( timestamp => $rec->{'timestamp'}, server_time => &subs::rightNow() );
	$set{'duration'} = $rec->{'duration'} if exists $rec->{'duration'};
	$set{'notes'} = $rec->{'notes'} if exists $rec->{'notes'};
	$set{'seen'} = $rec->{'seen'} if exists $rec->{'seen'};
	$set{'stop_seen'} = $rec->{'stop_seen'} if exists $rec->{'stop_seen'};
	$set{'type'} = $rec->{'type'} if exists $rec->{'type'};
	$set{'stop_timestamp'} = $rec->{'stop_timestamp'} if exists $rec->{'stop_timestamp'};
	&subs::db_update('appointments', \%set, { uuid => $target->{'uuid'}, app => $target->{'app'} });
	&subs::appt_toggle_checker($target->{'app'});
	&guide_refresh_app($target->{'app'}, $target->{'uuid'});
	$c->render(json => { ok => 1, app => $target->{'app'}, summary => ($rec->{'title'} || 'the last change was undone') });
}

# The Guide makes media: an image, a sound or a video through the matching agent,
# filed onto the appointment it is for when the Guide names one, else left in the
# Camera pool to be claimed. The generation itself is generate_ai_media's own work.
# POST /manager/help/generate
sub action_36716 {
	my $c = shift;
	my $kind = $c->param('kind') || 'image';
	$kind = 'image' unless grep { $_ eq $kind } qw/image audio video/;
	my $prompt = $c->param('prompt') || '';
	$prompt =~ s/^\s+|\s+$//g;
	return $c->render(json => { ok => 0, error => 'tell me what to make' }) unless length $prompt;
	my $app = &subs::unformat_name($c->param('app') || '');
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'text_to_image_assistant', 'text_to_audio_assistant', 'text_to_video_assistant' ] });
	my ($url, $att) = eval {
		&subs::generate_ai_media({
			kind => $kind,
			prompt => $prompt,
			settings => $settings,
			conversation => {},
			mail_contact => $app,
			unclaimed => ($app ? 0 : 1),
		});
	};
	my $model = $kind eq 'image' ? $settings->{'text_to_image_assistant'} : $kind eq 'audio' ? $settings->{'text_to_audio_assistant'} : $settings->{'text_to_video_assistant'};
	return $c->render(json => { ok => 0, error => 'the ' . $kind . ' agent could not make that (is a ' . $kind . ' model set?)' }) unless $url;
	$c->render(json => { ok => 1, kind => $kind, model => $model, app => ($app ? &subs::format_name($app) : ''), unclaimed => ($app ? 0 : 1) });
}

# GET /manager/help/staged
sub action_36739 {
	my $c = shift;
	my $rows = &subs::db_select('staged_appointments', undef, { status => 'pending' })->hashes;
	$c->render(json => { staged => $rows });
}

# The runtime verb list, and one verb run on its own (the client's fallback when
# the guide picks a verb it does not itself implement). The list is a setting, so
# it syncs to every machine - all of them learn the verb.
# GET /manager/help/verbs
sub action_36835 {
	my $c = shift;
	$c->render(json => { verbs => (&subs::setting_grabber({ app => '__president', setting => 'guide_verbs', device => 'all' }) || '[]'), list => &help::learned_verbs() });
}

# POST /manager/help/verbs
sub action_36839 {
	my $c = shift;
	my $raw = $c->param('verbs') // '';
	utf8::encode($raw) if utf8::is_utf8($raw);
	my $rows = eval { decode_json $raw };
	unless (ref $rows eq 'ARRAY') { $c->render(json => { ok => 0, error => 'that is not a JSON list of commands' }); return; }
	my @clean;
	foreach my $v ( @{$rows} ) {
		next unless ref $v eq 'HASH';
		next unless ($v->{'name'} // '') =~ /^[a-z][a-z0-9_]{1,40}$/;
		next unless ($v->{'primitive'} // '') =~ /^(?:say|open_app|set_setting|run_command|toggle|stage|find|play_music)$/;
		push @clean, $v;
	}
	# device 'all': one shared row every machine reads, whatever its device class
	&subs::setting_setter({ app => '__president', setting => 'guide_verbs', device => 'all', value => encode_json \@clean });
	$c->render(json => { ok => 1, count => scalar @clean });
}

# POST /manager/help/verb
sub action_36856 {
	my $c = shift;
	my $action = eval { decode_json($c->param('action') // '') } || {};
	unless (ref $action eq 'HASH' && ($action->{'action'} // '')) { $c->render(json => { ok => 0, error => 'no command given' }); return; }
	$c->render(json => { ok => 1, observation => guide_verb_execute($c, $action) });
}

# ---- the guide looks an appointment over when it opens --------------------
# If the app's name and description do not match its pos (part of speech) or
# mab, the guide sets the right ones. It marks each app it has looked at in a
# cache, so a machine with no model (or a second open) never asks twice.
# POST /manager/help/review
sub action_37610 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app') || '');
	my $description = $c->param('description') || '';
	unless ($app) { $c->render(json => { ok => 0, error => 'no app' }); return; }
	# a built-in app is code, not an appointment the guide should re-read
	if ($gb::known_appts->{$app}) {
		$c->render(json => { app => $app, reviewed => 0, reason => 'built-in app' });
		return;
	}
	# the marker is a setting, so it survives a restart and a machine with no model
	# keeps the same "already looked at" as everyone else
	my $reviewed = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'guide_reviewed' }) } || [];
	$reviewed = [] unless ref $reviewed eq 'ARRAY';
	if (grep { $_ eq $app } @{$reviewed}) {
		$c->render(json => { app => $app, reviewed => 1, changed => 0 });
		return;
	}
	my $mark = sub {
		push @{$reviewed}, $app;
		&subs::setting_setter({ app => '__president', setting => 'guide_reviewed', value => encode_json $reviewed });
	};
	my $settings = &subs::settings_grabber({ app => $app });
	my $pos = $settings->{'pos'} || '';
	my $mab = $settings->{'mab'} || '';
	my $model = &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
	if (!$model) {
		# no model on this machine: touch nothing and do not mark it, so a machine
		# that does carry one still gets the look
		$c->render(json => { app => $app, reviewed => 0, changed => 0, reason => 'no model' });
		return;
	}
	my @poses = sort keys %{$gb::pos};
	my $system = 'You check one JawnOS appointment\'s part of speech. An appointment logs one kind of activity; its "pos" (part of speech) is what sort of thing it is, and "mab" (might also be) names a second reading when the name is ambiguous. The valid pos values are: '
		. join(', ', @poses) . '. Given the app\'s name and any description, reply with EXACTLY ONE JSON object and nothing else: {"pos":"<a valid pos>"} to correct it, or {"pos":"' . $pos . '","keep":true} when the current one already fits. Add "mab":"<a valid pos>" only if a second reading clearly applies.';
	my $user = 'App: ' . $app . '\nCurrent pos: ' . $pos . '\nCurrent mab: ' . $mab . ($description ? ('\nDescription: ' . $description) : '');
	my ($text, $err) = &subs::evaluation_model_call_role('help_assistant', $system, $user, &subs::ai_role_thinking('help_assistant'));
	my $action;
	if ($text) { $action = eval { decode_json $text }; }
	if (!$action || ($action->{'keep'} && !$action->{'mab'})) {
		# the answer was unreadable or said it already fits: mark it and move on
		$mark->();
		$c->render(json => { app => $app, reviewed => 1, changed => 0 });
		return;
	}
	my $changed = 0;
	if ($action->{'pos'} && grep { $_ eq $action->{'pos'} } @poses && $action->{'pos'} ne $pos) {
		&subs::setting_setter({ app => $app, setting => 'pos', value => $action->{'pos'} });
		$changed = 1;
	}
	if ($action->{'mab'} && grep { $_ eq $action->{'mab'} } @poses && $action->{'mab'} ne $mab) {
		&subs::setting_setter({ app => $app, setting => 'mab', value => $action->{'mab'} });
		$changed = 1;
	}
	$mark->();
	$c->render(json => { app => $app, reviewed => 1, changed => $changed, pos => $action->{'pos'}, mab => $action->{'mab'} });
}

1;
