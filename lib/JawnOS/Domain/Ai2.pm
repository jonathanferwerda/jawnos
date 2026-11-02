package subs;

# Ai2: extracted from subroutines.pl (package subs). Loaded on
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
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $ai_last_model;
our $ai_tokens;
our $device;
# Whether this machine can actually carry an evaluation now. The configured
# model is only half the answer: the Crew may place the call on a peer's Ollama
# (or step down to a free model), and a local :cloud model is useless without
# the daemon that serves it. The heartbeat publishes this, and a job consults it
# before it claims a run, so only a working agent is ever asked.
our $evaluation_agent_ready_memo;
our $log;
our %m;

# A provider's own answer to "when may I call again". The stand-down above is
# for a bucket that has run dry; a rate limit is not that - it clears in
# seconds or at a stated clock time, and pausing the bucket for 30 minutes over
# a 20-second per-minute limit both loses the model and misstates the cause.
# Returns ($milliseconds, $why) when this response is a limit, () when it is
# not. Every duration is clamped to 5s..24h, so a malformed hint can neither
# lose a model for a week nor retry it in a hot loop.
sub ai_limit_pause {
	my ($code, $retry_after, $body, $now) = @_;
	$now = &subs::rightNow() unless defined $now;
	my $text = defined $body ? $body : '';
	my $limit = ($code == 429 || $code == 529) ? 1 : 0;
	$limit = 1 if !$limit && $text =~ /\b(?:rate.?limit|too many requests|try again in)\b/i;
	return () unless $limit;

	my ($ms, $why);
	$retry_after = '' unless defined $retry_after;

	# Retry-After: seconds, or an HTTP date (RFC 7231 allows both)
	if ($retry_after =~ /^\s*(\d+(?:\.\d+)?)\s*$/ && $1 > 0) {
		$ms = int($1 * 1000);
		$why = 'retry-after ' . $1 . 's';
	}
	elsif ($retry_after =~ /^\s*[A-Za-z]{3},\s*(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT\s*$/) {
		my %month = (jan => 0, feb => 1, mar => 2, apr => 3, may => 4, jun => 5,
			jul => 6, aug => 7, sep => 8, oct => 9, nov => 10, dec => 11);
		my $at = eval { Time::Local::timegm($6, $5, $4, $1, $month{lc $2}, $3) };
		if (defined $at && $at > 0) {
			$ms = $at * 1000 - $now;
			$why = 'retry-after ' . substr($retry_after, 0, 40);
		}
	}

	if (!defined $ms) {
		if ($text =~ /try again in\s+(\d+(?:\.\d+)?)\s*(ms|milliseconds?|s|secs?|seconds?|m|mins?|minutes?)?/i) {
			my ($n, $unit) = ($1, lc($2 || 's'));
			$ms = $unit =~ /^ms|^milli/ ? $n : $unit =~ /^m/ ? $n * 60000 : $n * 1000;
			$why = 'the provider asked to be retried in ' . $n . ' ' . ($2 || 's');
		}
		elsif ($text =~ /retry after\s+(\d+)\s*(ms|milliseconds?|s|secs?|seconds?|m|mins?|minutes?)?/i) {
			my ($n, $unit) = ($1, lc($2 || 's'));
			$ms = $unit =~ /^ms|^milli/ ? $n : $unit =~ /^m/ ? $n * 60000 : $n * 1000;
			$why = 'the provider asked to be retried after ' . $n . ' ' . ($2 || 's');
		}
		elsif ($text =~ /resets?\s+(?:at\s+)?(\d{1,2}):(\d{2})\s*(am|pm)?/i) {
			my ($hour, $minute, $meridiem) = (int($1), int($2), $3);
			$hour = 0 if $meridiem && $hour == 12;
			$hour += 12 if $meridiem && $meridiem =~ /^p/i;
			my @lt = localtime(int($now / 1000));
			my $at = eval { Time::Local::timelocal(0, $minute, $hour, $lt[3], $lt[4], $lt[5]) };
			if (defined $at && $at > 0) {
				# a clock time already past today is tomorrow's reset
				$at += 86400 if $at * 1000 <= $now;
				$ms = $at * 1000 - $now;
				$why = 'the limit resets at ' . sprintf('%02d:%02d', $hour, $minute);
			}
		}
	}

	$ms = 60000 unless defined $ms && $ms > 0;
	$why = 'the provider is rate limiting' unless $why;
	$ms = 5000 if $ms < 5000;
	$ms = 24 * 60 * 60 * 1000 if $ms > 24 * 60 * 60 * 1000;
	return ($ms, $why);
}

# The cheapest thing that still answers: a local Ollama chat model, else a
# Cloudflare text model (its plan is included).
sub ai_free_model {
	foreach my $m ( @{ &subs::pen_model_list() } ) {
		my $name = $m->{'model'} || $m->{'name'};
		next if $name =~ /:cloud\b/i;
		next unless grep { $_ eq 'chat' } &ai_model_caps('ollama', $name, $m);
		return $name;
	}
	foreach my $m ( @{ &subs::cloudflare_model_list() } ) {
		my $name = $m->{'model'} || $m->{'name'};
		next unless grep { $_ eq 'chat' } &ai_model_caps('cloudflare', $name, $m);
		return $name;
	}
	return '';
}

# Pass a capability (chat, vision, image, audio) to keep only models that serve it.
sub ai_model_catalogue {
	my ($cap) = @_;
	my @out;
	foreach my $p ( @{ &subs::ai_providers() } ) {
		my @models;
		if ($p->{'id'} eq 'ollama') {
			foreach my $mi ( @{ &subs::pen_model_list() } ) {
				my $name = $mi->{'model'} || $mi->{'name'};
				push @models, { value => $name, name => ($mi->{'name'} || $name), caps => [ &ai_model_caps('ollama', $name, $mi) ], paid => &ai_model_paid($name), bucket => &ai_model_bucket($name) };
			}
		}
		elsif ($p->{'id'} eq 'cloudflare') {
			foreach my $mi ( @{ &subs::cloudflare_model_list() } ) {
				my $name = $mi->{'model'} || $mi->{'name'};
				push @models, { value => $name, name => ($mi->{'name'} || $name), caps => [ &ai_model_caps('cloudflare', $name, $mi) ], paid => &ai_model_paid($name), bucket => &ai_model_bucket($name) };
			}
		}
		else {
			foreach my $m ( @{ $p->{'models'} || [] } ) {
				my $value = $p->{'id'} . ':' . $m;
				push @models, { value => $value, name => $m, caps => [ &ai_model_caps($p->{'id'}, $m, undef) ], paid => &ai_model_paid($value), bucket => &ai_model_bucket($value) };
			}
		}
		@models = grep { my $m = $_; scalar( grep { $_ eq $cap } @{ $m->{'caps'} } ) } @models if $cap;
		push @out, { id => $p->{'id'}, label => $p->{'label'}, models => \@models } if @models;
	}
	# a peer's own Ollama models, from the list cached by ollama_models_sync, each
	# offered under the machine that runs it
	foreach my $rm ( @{ &subs::db_select('remote_machines')->hashes || [] } ) {
		my $cached = eval { decode_json($rm->{'ollama_models'} || '') } || [];
		next unless ref $cached eq 'ARRAY' && @{$cached};
		my $device = $rm->{'hostname'} || $rm->{'name'} || '';
		next unless length $device;
		my @rm_models;
		foreach my $mi ( @{$cached} ) {
			my $name = $mi->{'model'} || $mi->{'name'};
			next unless defined $name && length $name;
			my $value = '@' . $device . '/' . $name;
			push @rm_models, { value => $value, name => $name, caps => [ &ai_model_caps('ollama', $name, $mi) ], paid => &ai_model_paid($value), bucket => &ai_model_bucket($value) };
		}
		@rm_models = grep { my $m = $_; scalar( grep { $_ eq $cap } @{ $m->{'caps'} } ) } @rm_models if $cap;
		push @out, { id => 'ollama:' . $device, label => 'Ollama \x{00b7} ' . $device, models => \@rm_models } if @rm_models;
	}
	return \@out;
}

# Talk to whichever provider a model id points at, and return the whole answer.
# The message list may carry a system message; Anthropic and Google want it
# apart from the turns, so it is lifted out and put back per provider.
# The media one message carries, flattened to one shape. A caller may hand images
# (and, for providers that take them, audio/video/files) as base64 strings, data:
# URLs, or { data => .., mime => .. } / { url => .. }. The per-provider builders
# below read this, so the parse lives in exactly one place.
sub ai_message_media {
	my ($m) = @_;
	my @out;
	foreach my $key ( qw/images image audio video files documents/ ) {
		my $v = $m->{$key};
		next unless defined $v;
		my @items = ref $v eq 'ARRAY' ? @{$v} : ($v);
		foreach my $it ( @items ) {
			next unless defined $it;
			my ($data, $mime, $url);
			if (ref $it eq 'HASH') {
				$url  = $it->{'url'};
				$data = $it->{'data'};
				$mime = $it->{'mime'} || $it->{'media_type'};
			}
			else { $data = $it; }
			if (!$url && defined $data && $data =~ m{^data:([^;,\s]+)[^,]*;base64,(.*)$}s) { ($mime, $data) = ($1, $2); }
			$data =~ s/\s+//g if defined $data;
			next unless $url || (defined $data && length $data);
			push @out, { kind => $key, data => $data, mime => ($mime || ''), url => $url };
		}
	}
	return @out;
}

# OpenAI-compatible content: a plain string with no media, else the multimodal
# array (text + image_url parts, and input_audio where the model takes it).
sub ai_content_openai {
	my ($m) = @_;
	my @media = &ai_message_media($m);
	return $m->{'content'} unless @media;
	my @parts = ( { type => 'text', text => ($m->{'content'} || '') } );
	foreach my $md ( @media ) {
		if ($md->{'kind'} =~ /audio/ && $md->{'mime'} =~ m{audio/}) {
			push @parts, { type => 'input_audio', input_audio => { data => $md->{'data'}, format => ($md->{'mime'} =~ /wav/ ? 'wav' : 'mp3') } };
		}
		else {
			my $u = $md->{'url'} || ('data:' . ($md->{'mime'} || 'image/png') . ';base64,' . $md->{'data'});
			push @parts, { type => 'image_url', image_url => { url => $u } };
		}
	}
	return \@parts;
}

# Anthropic content: text block + image (or document) blocks.
sub ai_content_anthropic {
	my ($m) = @_;
	my @media = &ai_message_media($m);
	return $m->{'content'} unless @media;
	my @parts = ( { type => 'text', text => ($m->{'content'} || '') } );
	foreach my $md ( @media ) {
		next unless defined $md->{'data'};
		my $t = ($md->{'mime'} =~ m{application/pdf}) ? 'document' : 'image';
		push @parts, { type => $t, source => { type => 'base64', media_type => ($md->{'mime'} || 'image/png'), data => $md->{'data'} } };
	}
	return \@parts;
}

# Gemini parts: an ordered list of text and inline_data parts.
sub ai_parts_google {
	my ($m) = @_;
	my @parts;
	push @parts, { text => $m->{'content'} } if defined $m->{'content'} && length $m->{'content'};
	foreach my $md ( &ai_message_media($m) ) {
		next unless defined $md->{'data'};
		push @parts, { inline_data => { mime_type => ($md->{'mime'} || 'image/png'), data => $md->{'data'} } };
	}
	return \@parts;
}

# The provider-specific wire message for one of our messages.
sub ai_wire_message {
	my ($provider, $m) = @_;
	if ($provider eq 'ollama') {
		my %c = ( role => $m->{'role'}, content => ($m->{'content'} || '') );
		my @im = map { $_->{'data'} } grep { defined $_->{'data'} } &ai_message_media($m);
		$c{'images'} = \@im if @im;
		return \%c;
	}
	elsif ($provider eq 'anthropic') {
		return { role => $m->{'role'}, content => &ai_content_anthropic($m) };
	}
	elsif ($provider eq 'google') {
		return { role => ($m->{'role'} eq 'assistant' ? 'model' : 'user'), parts => &ai_parts_google($m) };
	}
	else {
		# openai-compatible: openai, xai, mistral, groq, openrouter, deepseek, cloudflare
		return { role => $m->{'role'}, content => &ai_content_openai($m) };
	}
}

# The text out of any of the providers' reply shapes.
sub ai_response_text {
	my ($body) = @_;
	return $body->{'message'}->{'content'}
		|| $body->{'response'}
		|| $body->{'result'}->{'response'}
		|| $body->{'result'}->{'choices'}->[0]->{'message'}->{'content'}
		|| $body->{'choices'}->[0]->{'message'}->{'content'}
		|| $body->{'content'}->[0]->{'text'}
		|| $body->{'candidates'}->[0]->{'content'}->{'parts'}->[0]->{'text'};
}

# The token counts a reply reports, whatever shape it uses: an OpenAI-style
# usage object, Cloudflare's nested one, or the prompt_eval_count/eval_count
# pair an Ollama answers with - a local one or a peer's, which is how the house
# runs most of its Guide and evaluation work. Undefined when the reply carries
# neither, so an unmetered call is not banked as a free one.
sub ai_usage_tokens {
	my ($body) = @_;
	return (undef, undef) unless ref $body eq 'HASH';
	my $usage = $body->{'usage'} || $body->{'result'}->{'usage'} || {};
	my $in = $usage->{'prompt_tokens'};
	$in = $usage->{'input_tokens'} unless defined $in;
	$in = $body->{'prompt_eval_count'} unless defined $in;
	my $out = $usage->{'completion_tokens'};
	$out = $usage->{'output_tokens'} unless defined $out;
	$out = $body->{'eval_count'} unless defined $out;
	return ($in, $out);
}

sub ai_chat_raw {
	my ($model, $messages, $thinking, $role) = @_;
	my @key_settings = &subs::ai_key_settings();
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ @key_settings ] });
	my $suds = &subs::suds_grabber();
	my $secret = sub {
		my $v = shift;
		return '' unless defined $v && length $v;
		my $d = eval { &subs::note_decrypter($suds, $v) };
		return ($d && length $d) ? $d : $v;
	};
	my ($provider, $real) = ('ollama', $model);
	if ($model =~ /^\@cf/) { ($provider, $real) = ('cloudflare', $model); }
	elsif ($model =~ /^\@([^\/]+)\/(.+)$/) { ($provider, $real) = ('ollama_remote', $2); }
	elsif ($model =~ /^([a-z]+):(.+)$/) {
		if (grep { $_ eq $1 } qw/openai anthropic google xai mistral cohere groq openrouter deepseek/) { ($provider, $real) = ($1, $2); }
	}

	my $system = '';
	my @msgs;
	foreach my $m ( @{ $messages } ) {
		if (($m->{'role'} || '') eq 'system') { $system .= ($system ? "\n" : '') . $m->{'content'}; }
		else { push @msgs, $m; }
	}
	my @wire = map { &ai_wire_message($provider, $_) } @msgs;

	# a peer's own Ollama: carry the call to that machine's manager, which runs it
	# against its local daemon and hands the answer back over the same rail
	if ($provider eq 'ollama_remote') {
		my $device = &ai_model_device($model);
		my $me = &subs::signatorial_designer();
		my ($rm) = grep { ($_->{'hostname'} || '') eq $device || ($_->{'name'} || '') eq $device || ($_->{'signatorial'} || '') eq $device } @{ &subs::db_select('remote_machines')->hashes || [] };
		return (undef, 'no machine is known for ' . $model) unless $rm;
		my ($pua, $p) = &subs::peer_useragent($rm);
		return (undef, 'could not reach ' . $device) unless $pua;
		my $level = &ai_thinking_level($thinking);
		my $nproc = 4;
		if (open(my $fh, "-|", "nproc")) { $nproc = <$fh>; chomp($nproc); close($fh); }
		my $rp = { model => $real, messages => [ { role => 'system', content => $system }, @wire ], stream => \0, options => { num_thread => $nproc - 2, num_ctx => 32768 } };
		$rp->{'think'} = ($level eq 'max' ? 'high' : $level) if length $level && &ai_model_thinks($real);
		my $rres = eval { $pua->inactivity_timeout(600)->post($p->{'manager'} . '/manager/ollama_chat?signatorial=' . $me => json => $rp)->result };
		return (undef, 'could not reach ' . $device . ': ' . ($@ || 'no answer')) unless $rres && $rres->is_success;
		my $rbody = eval { $rres->json } || {};
		if ($rbody->{'message'} || $rbody->{'response'}) {
			# The peer's Ollama answers in its own shape: prompt_eval_count and
			# eval_count, not a usage object. Bank it here, where the role is known,
			# or the traffic that a shared model serves would have no token count
			# anywhere. The peer does not record this call itself, so it is not
			# counted twice.
			my ($in, $out) = &ai_usage_tokens($rbody);
			eval { &subs::ai_spend_note('ollama_remote', $in, $out, ($rbody->{'model'} || $real), $role) };
			return ($rbody, undef);
		}
		return (undef, 'the remote Ollama returned nothing');
	}

	my $ua = Mojo::UserAgent->new(connect_timeout => 10, inactivity_timeout => 300, request_timeout => 600);
	my ($url, $headers, $payload);

	if ($provider eq 'cloudflare') {
		$url = 'https://api.cloudflare.com/client/v4/accounts/' . $settings->{'cloudflare_account'} . '/ai/run/' . $model;
		$headers = { 'Authorization' => 'Bearer ' . $secret->($settings->{'cloudflare_token'}), 'Content-Type' => 'application/json' };
		$payload = { model => $model, messages => [ { role => 'system', content => $system }, @wire ], stream => \0 };
	}
	elsif ($provider eq 'anthropic') {
		$url = 'https://api.anthropic.com/v1/messages';
		$headers = { 'x-api-key' => $secret->($settings->{'anthropic_key'}), 'anthropic-version' => '2023-06-01', 'Content-Type' => 'application/json' };
		$payload = { model => $real, max_tokens => 2048, system => $system, messages => [ @wire ] };
	}
	elsif ($provider eq 'google') {
		$url = 'https://generativelanguage.googleapis.com/v1beta/models/' . $real . ':generateContent?key=' . url_escape($secret->($settings->{'google_key'}));
		$headers = { 'Content-Type' => 'application/json' };
		$payload = { contents => [ @wire ], systemInstruction => { parts => [ { text => $system } ] } };
	}
	elsif ($provider eq 'ollama') {
		$url = 'http://localhost:11434/api/chat';
		$headers = { 'Authorization' => 'Bearer ' . $secret->($settings->{'ollama_key'}), 'Content-Type' => 'application/json' };
		my $nproc = 4;
		if (open(my $fh, "-|", "nproc")) { $nproc = <$fh>; chomp($nproc); close($fh); }
		$payload = { model => $real, messages => [ { role => 'system', content => $system }, @wire ], stream => \0, options => { num_thread => $nproc - 2, num_ctx => 32768 } };
	}
	else {
		# the OpenAI-compatible crowd: openai, xai, mistral, groq, openrouter, deepseek
		my %ep = (
			openai => 'https://api.openai.com/v1/chat/completions',
			xai => 'https://api.x.ai/v1/chat/completions',
			mistral => 'https://api.mistral.ai/v1/chat/completions',
			cohere => 'https://api.cohere.ai/compatibility/v1/chat/completions',
			groq => 'https://api.groq.com/openai/v1/chat/completions',
			openrouter => 'https://openrouter.ai/api/v1/chat/completions',
			deepseek => 'https://api.deepseek.com/chat/completions',
		);
		my %key = ( openai => 'openai_key', xai => 'xai_key', mistral => 'mistral_key', cohere => 'cohere_key', groq => 'groq_key', openrouter => 'openrouter_key', deepseek => 'deepseek_key' );
		$url = $ep{$provider};
		$headers = { 'Authorization' => 'Bearer ' . $secret->($settings->{ $key{$provider} }), 'Content-Type' => 'application/json' };
		my $system_role = ($provider eq 'cohere') ? 'developer' : 'system';
		$payload = { model => $real, messages => [ { role => $system_role, content => $system }, @wire ], stream => \0 };
	}

	# Thinking effort (none/low/high/max): a hint each provider reads its own way.
	# none adds nothing, so a call with no level is byte-identical to the old one.
	my $level = &ai_thinking_level($thinking);
	my $payload_plain = { %{$payload} };
	if (length $level) {
		if ($provider eq 'anthropic') {
			# the budget must sit under max_tokens, and 1024 is the floor
			my $budget = ($level eq 'low' ? 1024 : $level eq 'high' ? 4096 : 8192);
			$payload->{'max_tokens'} = $budget + 2048;
			$payload->{'thinking'} = { type => 'enabled', budget_tokens => $budget };
		}
		elsif ($provider eq 'google') {
			$payload->{'generationConfig'} = { thinkingConfig => { thinkingBudget => ($level eq 'low' ? 1024 : $level eq 'high' ? 8192 : 24576) } };
		}
		elsif ($provider eq 'ollama') {
			$payload->{'think'} = ($level eq 'max' ? 'high' : $level);
		}
		elsif ($provider eq 'openrouter') {
			$payload->{'reasoning'} = { effort => ($level eq 'max' ? 'high' : $level) };
		}
		elsif ($provider eq 'cohere') {
			# the compatibility API knows only none and high; low is left off
			$payload->{'reasoning_effort'} = 'high' if $level eq 'high' || $level eq 'max';
		}
		else {
			# the OpenAI-compatible crowd reads reasoning_effort (high is every
			# list's top rung, so max lands there); one that does not is retried
			# without below
			$payload->{'reasoning_effort'} = ($level eq 'max' ? 'high' : $level);
		}
	}

	my $tx = $ua->build_tx(POST => $url => $headers => json => $payload);
	$ua->start($tx);
	return (undef, 'could not reach the model: ' . $tx->error->{'message'}) if $tx->error;
	my $res = $tx->res;
	# A model that does not understand the thinking knob (an older local model, a
	# provider that never adopted the field) must not cost the call: put the same
	# request on the wire again without it and carry on.
	if (length $level && !$res->is_success && $res->code == 400 && ($res->body || '') =~ /reason|think|unknown|unrecognized|unsupported|invalid/i) {
		my $tx2 = $ua->build_tx(POST => $url => $headers => json => $payload_plain);
		$ua->start($tx2);
		$res = $tx2->res unless $tx2->error;
		$log->info('AI: ' . $model . ' answered 400 to the thinking knob (' . $level . '); the call was retried without it') if defined $log;
	}
	unless ($res->is_success) {
		my $body = substr($res->body || '', 0, 500);
		# out of credit reads the same at every provider: stand the bucket down, so
		# the panel hides its paid models and chat steps down to a free one
		if ($res->code == 402 || $body =~ /(insufficient|credit|billing|payment|out of funds|no funds|balance|exceeded your current quota|exceeded your quota)/i) {
			&ai_bucket_mark_unavailable(&ai_model_bucket($model), $res->code . ' ' . $body);
		}
		else {
			# a rate limit clears on the provider's own clock: pause the bucket for
			# exactly that long, so the next call steps down instead of hammering it
			my $retry_after = $res->headers->header('retry-after');
			my ($pause, $why) = &ai_limit_pause($res->code, $retry_after, $body);
			&ai_bucket_mark_unavailable(&ai_model_bucket($model), $res->code . ' ' . ($why || ''), $pause) if defined $pause;
		}
		return (undef, 'the model answered ' . $res->code . ': ' . substr($res->body || '', 0, 200));
	}
	my $body = eval { return $res->json } || {};
	# Account what the call cost, so the error watch can log its spend and stop
	# when the day's purse is empty. Providers differ in shape - an OpenAI-style
	# usage, Cloudflare's own, a bare Ollama's counters - so the parse lives in
	# one place that knows all of them.
	my ($in, $out) = &ai_usage_tokens($body);
	$ai_tokens->{'calls'}++;
	$ai_tokens->{'in'} += ($in // 0);
	$ai_tokens->{'out'} += ($out // 0);
	$ai_tokens->{'unmetered'}++ unless defined $in || defined $out;
	# Bank the usage per call with its minute, model and role, so the balance chart
	# can put a token count against the minute an account fell in and say which
	# model and role spent it. A provider that reported no usage is skipped rather
	# than banked as zero, so "no tokens" stays distinguishable from "not metered".
	&subs::ai_spend_note($provider, $in, $out, $real, $role);
	return ($body, undef);
}

# The reply as parts, so a caller can take more than the words (an image a
# multimodal model returns, and the shape to grow into audio/video later). A paid
# model whose bucket is stood down steps down to a free one here, so every caller
# gets the fallback.
sub ai_chat_parts {
	my ($model, $messages, $thinking, $role) = @_;
	if (&ai_model_paid($model) && !&ai_bucket_available(&ai_model_bucket($model))) {
		my $free = &ai_free_model();
		if ($free) { &subs::say_it('AI: ' . $model . ' is stood down (no credit); using the free model ' . $free); $model = $free; }
	}
	my ($body, $err) = &ai_chat_raw($model, $messages, $thinking, $role);
	# The record moves only when a call answered. It used to be stamped before
	# the error check, so a failed call left "last model" naming a model that
	# never replied - one reason a device reported it had got an answer.
	# a fresh credit failure (marked down inside the call) also falls back, once
	if ($err && &ai_model_paid($model)) {
		my $free = &ai_free_model();
		if ($free && $free ne $model) {
			my ($body2, $err2) = &ai_chat_raw($free, $messages, $thinking, $role);
			if (!$err2) { ($body, $err) = ($body2, undef); $model = $free; $ai_last_model = $model; &subs::say_it('AI: answered with the free model ' . $free); }
		}
	}
	return (undef, $err) if $err;
	$ai_last_model = $model;
	my @parts;
	my $text = &ai_response_text($body);
	push @parts, { type => 'text', text => $text } if defined $text && length $text;
	# media the model drew or returned: OpenAI-style images/audio/video, Gemini
	# inline_data (any mime), Anthropic media blocks. The type is read off the
	# mime, so a caller can ask for the part it wants (image/audio/video).
	foreach my $u ( @{ $body->{'choices'}->[0]->{'message'}->{'images'} || [] } ) {
		my $url = (ref $u eq 'HASH') ? ($u->{'image_url'}->{'url'} || $u->{'url'}) : $u;
		push @parts, { type => 'image', url => $url } if $url;
	}
	my $msg = $body->{'choices'}->[0]->{'message'} || $body->{'result'}->{'choices'}->[0]->{'message'} || {};
	foreach my $field ( qw/audio video/ ) {
		my $m = $msg->{$field};
		next unless $m;
		if (ref $m eq 'HASH') {
			push @parts, { type => $field, url => $m->{'url'} } if $m->{'url'};
			push @parts, { type => $field, mime => $m->{'mime'} || $m->{'mime_type'}, data => $m->{'data'} } if $m->{'data'};
		}
		elsif (!ref $m && length $m) {
			push @parts, { type => $field, url => $m };
		}
	}
	foreach my $p ( @{ $body->{'candidates'}->[0]->{'content'}->{'parts'} || [] } ) {
		next unless $p->{'inline_data'};
		my $mime = $p->{'inline_data'}->{'mime_type'} || '';
		my $type = ($mime =~ m{^audio/}) ? 'audio' : ($mime =~ m{^video/}) ? 'video' : 'image';
		push @parts, { type => $type, mime => $mime, data => $p->{'inline_data'}->{'data'} };
	}
	if (ref $body->{'content'} eq 'ARRAY') {
		foreach my $b ( @{ $body->{'content'} } ) {
			my $bt = $b->{'type'} || '';
			next unless $b->{'source'} && ($bt eq 'image' || $bt eq 'audio' || $bt eq 'video');
			push @parts, { type => $bt, mime => $b->{'source'}->{'media_type'}, data => $b->{'source'}->{'data'} };
		}
	}
	return (\@parts, undef);
}

sub ai_chat {
	my ($model, $messages, $thinking, $role) = @_;
	my ($parts, $err) = &ai_chat_parts($model, $messages, $thinking, $role);
	return (undef, $err) if $err;
	my $text = join '', map { $_->{'text'} } grep { ($_->{'type'} || '') eq 'text' } @{$parts || []};
	return ($text, ($text && length $text) ? undef : 'the model returned nothing readable');
}

# the same wire pen_message uses, but the answer is read whole: the evaluation
# is a report, not a conversation
# The thinking levels the Plat panel stores: none means "let the model answer
# as it always has" (no field is added anywhere).
sub ai_thinking_level {
	my $v = shift;
	return '' unless defined $v && length $v;
	return $v if $v =~ /^(?:low|high|max)$/;
	return '';
}

# Whether a model reasons before it answers - whether the thinking knob (see
# ai_chat_raw) means anything to it. No provider publishes this, so it is read
# from the model id: the reasoning families by name. A model not named here
# simply never offers the choice, and a level sent to a model that ignores the
# knob is still caught (a 400) and the call retried without it, so a miss costs
# nothing. Names are given without their provider: prefix.
sub ai_model_thinks {
	my ($model) = @_;
	return 0 unless defined $model && length $model;
	my $v = lc $model;
	$v =~ s/^\@cf\///;   # Cloudflare's own @cf/... ids
	# strip a leading provider: only when it names a real provider, so an Ollama
	# tag (qwen3:8b) keeps the colon that carries its size
	foreach my $p ( @{ &subs::ai_providers() } ) {
		my $id = $p->{'id'};
		if ($v =~ /^\Q$id\E:(.*)$/) { $v = $1; last; }
	}
	return 1 if $v =~ /(?:^|[-_.\/])(?:o1|o3|o4|gpt-5|qwq|qwen3|magistral|gpt-oss|deepseek-(?:r1|reasoner|v4-pro|flash)|reason|thinking)(?:$|[-_.:\/])/;
	return 1 if $v =~ /^claude/ && $v =~ /(?:3[.-]7|[4-9])/;
	return 1 if $v =~ /^(?:gemini-(?:2\.5|3)|grok-(?:3|4))/;
	return 0;
}

# The thinking effort chosen in Configure -> Plat beside a role's model, '' when
# none is set. The Coding agent's own coding_thinking predates the per-role
# settings, so it is read as that one role's fallback.
sub ai_role_thinking {
	my ($role) = @_;
	return '' unless defined $role && length $role;
	my $v = &subs::setting_grabber({ app => 'mail', setting => $role . '_thinking' });
	$v = &subs::setting_grabber({ app => 'mail', setting => 'coding_thinking' }) if (!defined $v || !length $v) && $role eq 'coding_assistant';
	return defined $v ? $v : '';
}

# The primary and fallback models chosen for a role (the fallback list is the
# same catalogue minus the primary, set in Configure -> Plat). A caller retries
# the fallback when the primary is down. whisper.cpp is the transcription role's
# own final fallback, read in whisper_transcribe.
sub ai_role_models {
	my ($role) = @_;
	my $primary = &subs::setting_grabber({ app => 'mail', setting => $role });
	my $fallback = &subs::setting_grabber({ app => 'mail', setting => $role . '_fallback' });
	return (defined $primary ? $primary : '', defined $fallback ? $fallback : '');
}

# One role's chat call. Before it is made, the Crew places it (crew::choose_model):
# a role naming a peer that no longer holds the model, a paid bucket that is
# stood down, or a local model this device never pulled is answered by what the
# house can actually reach, and a peer's own Ollama carries the call. The call
# still retries the role's fallback (then the primary) when the placed model
# errors - an outage is not a placement mistake. A role with nothing viable is
# reported rather than sent to a model that cannot answer.
sub ai_chat_parts_role {
	my ($role, $messages, $thinking) = @_;
	my ($primary, $fallback) = &ai_role_models($role);
	return (undef, "no $role model is set") unless $primary;

	my ($placed, $placed_why, $placed_ok);
	if (defined &crew::choose_model) {
		my @chosen = eval { &crew::choose_model($role) };
		if ($@) {
			# A roster or advert read that failed is not a reason to stop calling:
			# fall back to the configured model, which is the old behaviour.
			$log->info('AI: role ' . $role . ' could not be placed: ' . ($@ =~ s/\s+/ /gr)) if $log;
		}
		else {
			$placed_ok = 1;
			($placed, $placed_why) = @chosen;
		}
	}
	if (!$placed_ok) { $placed = $primary; }
	elsif (!defined $placed || !length $placed) {
		return (undef, "no viable model for $role: " . ($placed_why || 'nothing is reachable'));
	}

	my $device = &ai_model_device($placed);
	$log->info('AI: role ' . $role . ' placed on ' . $placed . ' on ' . ($device || &device_setter())) if $log;
	if ($placed ne $primary && $placed_why) {
		$log->info('AI: role ' . $role . ' left ' . $primary . ': ' . $placed_why) if $log;
	}

	my ($parts, $err) = &ai_chat_parts($placed, $messages, $thinking, $role);
	return ($parts, undef) unless $err;
	foreach my $next ( grep { defined $_ && length $_ && $_ ne $placed } ($fallback, $primary) ) {
		&subs::say_it('AI: ' . $role . ' failed (' . $err . '); trying ' . $next);
		my ($next_parts, $next_err) = &ai_chat_parts($next, $messages, $thinking, $role);
		return ($next_parts, undef) unless $next_err;
		($parts, $err) = ($next_parts, $next_err);
	}
	return (undef, $err);
}

sub ai_chat_role {
	my ($role, $messages, $thinking) = @_;
	my ($parts, $err) = &ai_chat_parts_role($role, $messages, $thinking);
	return (undef, $err) if $err;
	my $text = join '', map { $_->{'text'} } grep { ($_->{'type'} || '') eq 'text' } @{$parts || []};
	return ($text, ($text && length $text) ? undef : 'the model returned nothing readable');
}

sub evaluation_model_call_role {
	my ($role, $system, $user, $thinking) = @_;
	return &ai_chat_role($role, [ { role => 'system', content => $system }, { role => 'user', content => $user } ], $thinking);
}

# The same retry, for a caller that already holds its primary (the Guide's
# per-session model, the Coding agent's own fallback): primary first, then the
# role's fallback setting.
sub ai_chat_parts_with_fallback {
	my ($primary, $fallback, $messages, $thinking, $role) = @_;
	return (undef, 'no model given') unless $primary;
	my ($parts, $err) = &ai_chat_parts($primary, $messages, $thinking, $role);
	return ($parts, undef) unless $err;
	if ($fallback && $fallback ne $primary) {
		&subs::say_it('AI: ' . $primary . ' failed (' . $err . '); trying the fallback ' . $fallback);
		return &ai_chat_parts($fallback, $messages, $thinking, $role);
	}
	return (undef, $err);
}

sub evaluation_model_call_with_fallback {
	my ($primary, $fallback, $system, $user, $thinking, $role) = @_;
	return &ai_chat_with_fallback($primary, $fallback, [ { role => 'system', content => $system }, { role => 'user', content => $user } ], $thinking, $role);
}

sub ai_chat_with_fallback {
	my ($primary, $fallback, $messages, $thinking, $role) = @_;
	my ($parts, $err) = &ai_chat_parts_with_fallback($primary, $fallback, $messages, $thinking, $role);
	return (undef, $err) if $err;
	my $text = join '', map { $_->{'text'} } grep { ($_->{'type'} || '') eq 'text' } @{$parts || []};
	return ($text, ($text && length $text) ? undef : 'the model returned nothing readable');
}

sub evaluation_model_call {
	my ($model, $system, $user, $thinking, $role) = @_;
	return &subs::ai_chat($model, [ { role => 'system', content => $system }, { role => 'user', content => $user } ], $thinking, $role);
}

# Whether this machine can actually run the evaluation right now. The wish to
# evaluate is shared but the queue is per-machine, so a machine with no ollama,
# no model, or no key would otherwise run the night and answer with a connection
# error. A blank model is never available.
sub evaluation_model_available {
	my ($model) = @_;
	return 0 unless $model;
	my $provider = &ai_model_provider($model);
	if ($provider eq 'cloudflare') {
		my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'cloudflare_account', 'cloudflare_token' ] });
		return ($settings->{'cloudflare_account'} && $settings->{'cloudflare_token'}) ? 1 : 0;
	}
	# A peer's own Ollama: the advert is the truth, so a model the peer no
	# longer lists is not called, however recently the role named it.
	if ($provider eq 'ollama_remote') {
		my ($device, $bare) = $model =~ /^\@([^\/]+)\/(.+)$/;
		return 0 unless defined $device && length $device && length $bare;
		my $advert = eval { defined &crew::advert_get ? &crew::advert_get($device) : undef };
		return 0 unless $advert && ref $advert->{'abilities'} eq 'HASH';
		foreach my $m ( @{ $advert->{'abilities'}->{'ollama_models'} || [] } ) {
			return 1 if $m eq $bare;
		}
		return 0;
	}
	if ($provider ne 'ollama') {
		my %key = ( openai => 'openai_key', anthropic => 'anthropic_key', google => 'google_key', xai => 'xai_key', mistral => 'mistral_key', cohere => 'cohere_key', groq => 'groq_key', openrouter => 'openrouter_key', deepseek => 'deepseek_key' );
		my $setting = $key{$provider};
		return 0 unless $setting;
		my $settings = &subs::settings_grabber({ app => 'mail', settings => [ $setting ] });
		return $settings->{$setting} ? 1 : 0;
	}
	# ollama: a :cloud model is billed through the same daemon and is only
	# callable from a machine whose daemon knows it, so the listing is checked
	# for every local model, cloud ones included.
	my $abilities = eval { &crew::abilities() } || {};
	foreach my $m ( @{ $abilities->{'ollama_models'} || [] } ) {
		return 1 if $m eq $model;
	}
	my $ua = Mojo::UserAgent->new(connect_timeout => 3, inactivity_timeout => 5, request_timeout => 8);
	my $res = eval { $ua->get('http://localhost:11434/api/tags')->result };
	return 0 unless $res && $res->is_success;
	my $body = eval { $res->json } || {};
	foreach my $m ( @{ $body->{'models'} || [] } ) {
		return 1 if ($m->{'name'} || '') eq $model || ($m->{'model'} || '') eq $model;
	}
	return 0;
}

sub evaluation_agent_ready {
	my $now = time;
	return $evaluation_agent_ready_memo->{'ready'} if $evaluation_agent_ready_memo && $evaluation_agent_ready_memo->{'at'} > $now - 60;
	my ($primary) = &ai_role_models('eval_assistant');
	my $ok = 0;
	if ($primary) {
		my $placed = $primary;
		if (defined &crew::choose_model) {
			my @chosen = eval { &crew::choose_model('eval_assistant') };
			if ($@) { $placed = $primary; }
			else { ($placed) = @chosen; }
		}
		$ok = (defined $placed && length $placed && &evaluation_model_available($placed)) ? 1 : 0;
	}
	$evaluation_agent_ready_memo = { at => $now, ready => $ok };
	return $ok;
}

sub evaluation_period_span {
	my ($period) = @_;
	return 7 * 86400000 if ($period || '') eq 'week';
	return 30 * 86400000 if ($period || '') eq 'month';
	return 86400000;
}

1;
