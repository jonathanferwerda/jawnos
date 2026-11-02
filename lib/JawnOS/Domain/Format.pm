package subs;

# Format: extracted from subroutines.pl (package subs). Loaded on
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
use Sereal::Decoder qw(decode_sereal);
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our %M;
our %Y;
our $device;
our %m;
our %time_abbrev_ms;

sub format_name {
	my $name = shift || "";
	# Work on characters, not bytes: a name in Chinese, Arabic or French must
	# keep its letters. The DB and JSON layers hand us decoded strings; NFC makes
	# a composed and a decomposed spelling read the same.
	$name = NFC($name);
	my $fname = lc $name;
	# the one misspelling the code has carried since the start: the stored key is
	# 'occurences', the name a person reads is spelled right
	$fname = 'occurrences' if $fname eq 'occurences';
	$fname =~ s/_/ /g;
	my @fname = grep { length } split /\s+/, $fname;
	foreach my $f (@fname) {
		my @f = split //, $f;
		$f[0] = uc $f[0] if scalar @f;
		$f = join '', @f;
	}
	return join ' ', @fname;
}

sub models_by_name {
	return sort { &format_name($a->{'name'}) cmp &format_name($b->{'name'}) } @_;
}

sub unformat_name {
	my $name = shift;
	$name = '' unless defined $name;
	# Every printable character is allowed in a name. Only invisible control
	# characters are dropped; spaces and runs of underscores become one
	# underscore so the key has a stable shape. The key is stored exactly this
	# way, and subs::path_name() makes a filesystem-safe component from it.
	$name = NFC($name);
	$name =~ s/[\x00-\x1f\x7f]+//g;
	# A straight apostrophe is the one character that would also terminate a
	# JavaScript string or a SQL literal in the hundreds of hand-built snippets
	# that name an app. Keep the mark but use the typographic form: it looks the
	# same, is safe everywhere, and still sorts and matches as itself.
	$name =~ s/'/’/g;
	$name =~ s/"/”/g;
	my $fname = lc $name;
	my $double_start = 0;
	if ($fname =~ /^__/) {
		$double_start = 1;
	}
	$fname =~ s/\s+/_/g;
	$fname =~ s/_+/_/g;
	$fname =~ s/^_+|_+$//g;
	$fname = '__' . $fname if $double_start;
	return $fname;
}

sub path_name {
	my $name = shift;
	$name = '' unless defined $name;
	$name = NFC($name);
	my $out = $name;
	$out =~ s/([^A-Za-z0-9\p{L}\p{M}\p{N}._-])/
		join('', map { sprintf('%%%02X', $_) } unpack('C*', encode_utf8($1)))
	/gex;
	$out = '%2E' if $out eq '.';
	$out = '%2E%2E' if $out eq '..';
	$out = '%2D' . substr($out, 1) if $out =~ /^-/;
	if ( length( encode_utf8($out) ) > 200 ) {
		# Cap by bytes, not characters: a long name in Chinese or Arabic stays
		# under the filesystem's component limit, and never ends mid-way through
		# a percent-encoded byte.
		my $prefix = '';
		foreach my $ch ( split //, $out ) {
			last if length( encode_utf8( $prefix . $ch ) ) > 179;
			$prefix .= $ch;
		}
		$out = $prefix . '-' . substr( md5_sum( encode_utf8($name) ), 0, 16 );
	}
	return $out;
}

sub language {
	my $value = eval { &setting_grabber({ app => 'misc', setting => 'language', device => 'all' }) };
	my $signatorial;
	unless (defined $value && length $value) {
		$signatorial = eval { &signatorial_designer() };
		if ($signatorial) {
			$value = eval { &setting_grabber({ app => 'misc', setting => 'language', device => $signatorial }) };
		}
	}
	unless (defined $value && length $value) {
		$value = eval { &setting_grabber({ app => 'misc', setting => 'language' }) };
	}
	unless (defined $value && length $value) {
		$value = eval { my $cfg = &config_reader(); $cfg->{'language'} };
	}
	return &language::valid($value);
}

sub language_reset {
	return;
}

sub language_dir {
	return &language::dir_for(&language());
}

sub language_list {
	return @language::languages;
}

sub language_label {
	my $code = shift || &language();
	return &language::label($code);
}

sub lang {
	my $key = shift;
	return &language::translate(&language(), $key, @_);
}

sub lang_js {
	# encode_json hands back UTF-8 bytes; a template is a character string, so
	# decode it here the same way json_chars does or every non-ASCII label is
	# double-encoded on the page.
	return &json_chars(&language::for_javascript(&language()));
}

sub ui {
	my $string = shift;
	return &language::ui_translate(&language(), $string);
}

sub translation_languages {
	return &language::translation_languages();
}

sub translation_language {
	return &language::translation_language(@_);
}

sub translate_engine {
	my ($params) = @_;
	$params ||= {};
	my $target = &translation_language( $params->{'to'} );
	unless ($target) {
		return { ok => 0, error => 'Unknown language: ' . ( $params->{'to'} // '' ) . '. Ask for the language list.' };
	}
	my $from = $params->{'from'} ? &translation_language( $params->{'from'} ) : undef;
	my $model = $params->{'model'};
	my $fallback = &setting_grabber({ app => 'mail', setting => 'help_assistant_fallback' });
	unless (defined $model && length $model) {
		$model = &setting_grabber({ app => 'mail', setting => 'help_assistant' });
	}
	unless (defined $model && length $model) {
		return { ok => 0, error => 'No translation model is set. Choose a model under Configure -> Plat (the Guide model).' };
	}

	my @raw;
	push @raw, $params->{'text'} if defined $params->{'text'} && length $params->{'text'};
	if ( ref $params->{'strings'} eq 'ARRAY' ) {
		push @raw, @{ $params->{'strings'} };
	}
	my ( %seen, @items );
	foreach my $s (@raw) {
		next unless defined $s;
		$s = "$s";
		$s =~ s/^\s+|\s+$//g;
		next unless length $s;
		next if $seen{$s}++;
		push @items, $s;
	}
	return { ok => 0, error => 'nothing to translate' } unless @items;
	my $chars = 0;
	$chars += length($_) for @items;
	return { ok => 0, error => 'that is too much to translate at once' } if $chars > 40000 || @items > 400;

	# English is the source language; translating it into itself is a no-op.
	if ( $target->{'code'} eq 'en' || ( $from && $from->{'code'} eq $target->{'code'} ) ) {
		my %same = map { $_ => $_ } @items;
		my $res = {
			ok => 1, to => $target, from => ( $from || $target ), model => $model,
			translations => \%same, cached => scalar(@items), translated => 0,
		};
		$res->{'translation'} = $same{ $params->{'text'} } if defined $params->{'text'} && length $params->{'text'};
		return $res;
	}

	my ( %out, @missing );
	my $cached = 0;
	foreach my $s (@items) {
		my $hash = &translation_cache_hash( $target->{'code'}, $model, $s );
		my $row = eval { &db_query('select data from cache where app = ? and context = ? and subcontext = ? order by server_time desc limit 1', 'translation', $target->{'code'}, $hash)->hash };
		my $hit = ( $row && $row->{'data'} ) ? eval { decode_sereal( $row->{'data'} ) } : undef;
		if ( defined $hit && length $hit ) {
			$out{$s} = $hit;
			$cached++;
		}
		else {
			push @missing, [ $s, $hash ];
		}
	}

	my $translated = 0;
	my @queue = @missing;
	while (@queue) {
		my ( @batch, $batch_chars );
		$batch_chars = 0;
		while (@queue) {
			my $it = $queue[0];
			last if @batch && ( @batch >= 35 || $batch_chars + length( $it->[0] ) > 6000 );
			push @batch, shift @queue;
			$batch_chars += length( $it->[0] );
			last if $batch_chars >= 6000;
		}
		my @texts = map { $_->[0] } @batch;
		my $got = &translation_model_batch( $model, $fallback, $target, $from, \@texts );
		my @missed;
		foreach my $it (@batch) {
			my ( $s, $hash ) = @{$it};
			my $t = $got->{$s};
			if ( !defined $t || !length $t ) {
				# tolerate a key the model normalized (whitespace, a curly quote)
				my $nk = $s;
				$nk =~ s/\s+/ /g;
				$nk =~ s/^\s+|\s+$//g;
				foreach my $k ( keys %{$got} ) {
					my $kk = $k;
					$kk =~ s/\s+/ /g;
					$kk =~ s/^\s+|\s+$//g;
					if ( $kk eq $nk && defined $got->{$k} && length $got->{$k} ) { $t = $got->{$k}; last; }
				}
			}
			if ( defined $t && length $t ) {
				$out{$s} = $t;
				$translated++;
				&cache_set({ app => 'translation', context => $target->{'code'}, subcontext => $hash, warranty => '-1y' }, $t);
			}
			else {
				push @missed, $it;
			}
		}
		if ( @missed && scalar(@batch) > 1 ) {
			my $mid = int( @missed / 2 );
			my @halves = ( [ @missed[ 0 .. $mid - 1 ] ], [ @missed[ $mid .. $#missed ] ] );
			foreach my $half (@halves) {
				next unless @{$half};
				my @ht = map { $_->[0] } @{$half};
				my $more = &translation_model_batch( $model, $fallback, $target, $from, \@ht );
				foreach my $it ( @{$half} ) {
					my ( $s, $hash ) = @{$it};
					my $t = $more->{$s};
					next unless defined $t && length $t;
					$out{$s} = $t;
					$translated++;
					&cache_set({ app => 'translation', context => $target->{'code'}, subcontext => $hash, warranty => '-1y' }, $t);
				}
			}
			@missed = grep { !defined $out{ $_->[0] } } @missed;
		}
		if (@missed) {
			foreach my $it (@missed) {
				my ( $s, $hash ) = @{$it};
				my $one = &translation_model_batch( $model, $fallback, $target, $from, [$s] );
				my $t = $one->{$s};
				next unless defined $t && length $t;
				$out{$s} = $t;
				$translated++;
				&cache_set({ app => 'translation', context => $target->{'code'}, subcontext => $hash, warranty => '-1y' }, $t);
			}
		}
	}

	my $result = {
		ok => 1,
		to => $target,
		from => ( $from || { code => 'auto', native => 'Auto-detect', name => 'Auto-detect' } ),
		model => $model,
		translations => \%out,
		cached => $cached,
		translated => $translated,
	};
	$result->{'translation'} = $out{ $params->{'text'} } if defined $params->{'text'} && length $params->{'text'};
	return $result;
}

sub translation_cache_hash {
	my ( $code, $model, $text ) = @_;
	return substr( sha256_hex( 'v1' . "\x1f" . $code . "\x1f" . ( $model // '' ) . "\x1f" . $text ), 0, 20 );
}

sub translation_model_batch {
	my ( $model, $fallback, $target, $from, $texts ) = @_;
	my $source = $from ? ( $from->{'native'} . ' (' . $from->{'code'} . ')' ) : 'the source language (detect it)';
	my $system = 'You are the JawnOS translation engine. Translate every string into '
		. $target->{'native'} . ' (' . $target->{'code'} . ') from ' . $source . ".\n"
		. "Return ONLY a JSON object whose keys are the exact input strings and whose values are the translations.\n"
		. "Do not add, omit, merge or split keys. Preserve placeholders such as {0} and {1}, HTML tags and entities, punctuation, file paths, code identifiers, and product names (JawnOS, Jawn, Ollama, Piper, Linux, Windows, Android) exactly.\n"
		. "These are interface labels and help text: translate naturally, keep help text complete, and do not summarize.\n"
		. 'If a string is only a product name or code token, keep it unchanged.';
	my $user = "Input JSON array:\n" . JSON::PP->new->utf8(0)->encode($texts);
	my ( $out, $err ) = &evaluation_model_call_with_fallback( $model, $fallback, $system, $user, &ai_role_thinking('help_assistant') );
	return {} if $err || !defined $out || !length $out;
	my $parsed = &json_from_model($out);
	return {} unless ref $parsed eq 'HASH';
	my %got;
	foreach my $s ( @{$texts} ) {
		my $t = $parsed->{$s};
		$got{$s} = $t if defined $t && length $t;
	}
	return \%got;
}

sub apostrophe_escape {
	my $string = shift || "";
	$string =~ s/\'/\\\'/gi;
	$string =~ s/\?/\\\?/gi;
	return $string;
}

sub shorthand_name {
	my $name = shift || "";
	my $shorten = shift || 5;
	my $name1 = substr($name, 0, $shorten);
	return $name1;
}

sub initialize_name {
	my $name = shift || "";
	my $returner;
	my $count = 0;
	foreach my $n ( split ' ', $name ) {
		if ($count <= 2) {
			$returner .= &shorthand_name($n, 1);
		}
		$count++;
	}
	return $returner;
}

sub teaser_name {
	my $name = shift || "";
	my $name1 = substr($name, 0, 50);
	return $name1;
}

sub abbreviate_name {
	my $name = shift || "";
	$name =~ s/[^a-zA-Z 0-9]//g;
	my @words = split ' ', $name;

	my $abbrev = '';

	foreach my $word (@words) {
		my @letters = split '', $word;
		$abbrev = $abbrev . $letters[0] if scalar @letters > 0;
	}
	return $abbrev;
}

sub terminal_name {
	my $name = shift || "";

	foreach my $split ( (' ', '(', ')', '{', '}', '&', '\'', '"', '+' )) {
		#my @words = split $split, $name;
		#$name = join '\\' . $split, @words;

		$name =~ s/\Q$split/\\$split/gi;
	}


	return $name;
}

sub url_escape_utf8 {
	my $name = shift // '';
	utf8::encode($name) if utf8::is_utf8($name);
	return url_escape($name);
}

sub json_chars {
	my $json = encode_json shift;
	utf8::decode($json) unless utf8::is_utf8($json);
	return $json;
}

sub html_name {
	my $name = shift || "";
	# DOM ids and class names still have to be ASCII tokens, but a name in
	# Chinese, Arabic or French must not collapse to an empty string. Transliterate
	# what Latin letters it can, keep the plain punctuation a CSS identifier can
	# take, and add a stable digest whenever the name had to change at all, so two
	# distinct app names never share a window class.
	my $original = NFC($name);
	my $ascii = Text::Unidecode::unidecode($original);
	$ascii =~ s/[^a-zA-Z0-9_-]+//g;
	if ( !length $ascii || $ascii ne $original ) {
		$ascii = ( length $ascii ? $ascii : 'app' ) . '-' . substr( md5_sum( encode_utf8($original) ), 0, 8 );
	}
	return $ascii;
}

sub html_text {
	my $string = shift;
	return '' unless defined $string;
	return xml_escape($string);
}

sub http_name {
	my $name = shift || "";
	my $ascii = Text::Unidecode::unidecode($name);
	$ascii =~ s/ /_/gi;
	$ascii =~ s/[^a-zA-_Z0-9]+//g;
	$ascii = html_unescape $ascii;
	return $ascii;
}

sub wiki_name {
	my $name = shift;
	my @name = split '_', $name;

	$name[0] = ucfirst $name[0];
	$name = join '_', @name;
	return $name;
}

sub formatted_time {
	my $time = shift;
	return localtime($time / 1000 )->strftime('%a %b %d %Y - %I:%M:%S%P');
}

sub price_formatter {
	my $price = shift;
	$price = '' unless defined $price;
	# A price without a sign left $1 undef (and it could hold an earlier match).
	my $point = '';
	$point = $1 if $price =~ s/^([\-])//;
	if ($price =~ /[0-9.]/gi) {
		$price = $point . sprintf( "\$%.2f", $price);
	} else { $price = $point . '0.00'; }
	return $price;
}

sub percent_formatter {
	my $percent = shift;
	$percent = $percent * 100;
	$percent = sprintf("%.3f", $percent) . '%';
	return $percent;
}

sub numeric_formatter {
	my $number = shift;
	$number = '' unless defined $number;
	# A number typed in another script (Arabic-Indic, Devanagari, full-width)
	# is still a number. Transliterate it to ASCII digits before the filter
	# below, which would otherwise erase every digit of it.
	$number = Text::Unidecode::unidecode($number) if $number =~ /[^\x00-\x7F]/;
	# Strip currency symbols, spaces, thousands separators, etc. -- everything
	# that isn't part of the number itself. The old pattern stripped the first
	# *digit*, turning 70 into 0 and 4700 into 700.
	$number =~ s/[^0-9.\-]//gi;
	$number = '' if $number eq '' || $number eq '-' || $number eq '.' || $number eq '-.';
	if (!$number) { $number = 0; }
	return $number
}

sub number_words_to_digits {
	my ($text) = @_;
	return $text unless defined $text && $text =~ /[a-z]/i;
	my $original = $text;
	$text =~ s/([a-z])-([a-z])/$1 $2/gi;   # twenty-one -> twenty one
	my %small = (
		zero => 0, one => 1, two => 2, three => 3, four => 4, five => 5,
		six => 6, seven => 7, eight => 8, nine => 9, ten => 10,
		eleven => 11, twelve => 12, thirteen => 13, fourteen => 14,
		fifteen => 15, sixteen => 16, seventeen => 17, eighteen => 18,
		nineteen => 19, twenty => 20, thirty => 30, forty => 40, fifty => 50,
		sixty => 60, seventy => 70, eighty => 80, ninety => 90,
	);
	my %scale = (hundred => 100, thousand => 1000, million => 1000000);
	my (@out, $current, $total, $in_number, $changed);
	$current = $total = $in_number = $changed = 0;
	foreach my $word ( split /\s+/, $text ) {
		my $clean = lc($word);
		$clean =~ s/[^a-z]//g;
		if ($clean eq 'a' || $clean eq 'an') {
			$current += 1; $in_number = 1; $changed = 1; next;
		}
		if (defined $small{$clean}) {
			$current += $small{$clean}; $in_number = 1; $changed = 1; next;
		}
		if (defined $scale{$clean}) {
			$current = ($current || 1) * $scale{$clean};
			if ($clean eq 'thousand' || $clean eq 'million') {
				$total += $current; $current = 0;
			}
			$in_number = 1; $changed = 1; next;
		}
		if ($clean eq 'and' && $in_number) { next; }
		if ($in_number) {
			push @out, $total + $current;
			$current = $total = $in_number = 0;
		}
		push @out, $word;
	}
	push @out, $total + $current if $in_number;
	return $original unless $changed;
	return join(' ', @out);
}

sub duration_sayer {
	my $durational = shift;
	my $timestamp = &subs::rightNow();

	# A negative duration is a difference read the other way - a budget's
	# shortfall, a moment that has passed - and Time::Duration itself formats the
	# size and drops the sign. Without holding the sign out here the sub-second
	# branch below would catch every negative (all of them are < 1) and print a
	# whole shortfall as "-1800000.00 ms".
	my $sign = (defined $durational && $durational < 0) ? '-' : '';
	$durational = abs($durational || 0);

	my $leap_year =  &subs::time_abbrev_translator('4y') / 1000;
	if ($durational > $leap_year) {
		my $leaps = (( $durational) / ($leap_year));
		$durational = $durational - (&subs::time_abbrev_translator($leaps . 'd' ) / 1000);
	}

	my $duration = duration($durational);
	if ($durational < 1) {
		$duration = $durational == 0 ? '0s' : sprintf("%.2f", $durational * 1000) . ' milliseconds';
	}


	$duration =~ s/ hours?/h/gi;
	$duration =~ s/ minutes?/m/gi;
	$duration =~ s/ days?/d/gi;
	$duration =~ s/ months?/M/gi;
	$duration =~ s/ weeks?/w/gi;
	$duration =~ s/ seconds?/s/gi;
	$duration =~ s/ milliseconds?/ms/gi;
	$duration =~ s/ years?/y/gi;
	$duration =~ s/ and / /gi;
	$duration =~ s/just now/0s/gi;
	return $sign . $duration;
}

sub duration_readout {
	my ($milliseconds, %option) = @_;
	return '' unless defined $milliseconds && $milliseconds =~ /^-?[0-9]+(?:\.[0-9]+)?$/;
	my $negative = $milliseconds < 0 ? 1 : 0;
	my $absolute = $negative ? -$milliseconds : $milliseconds;
	my $class = 'jawnos_duration';
	$class .= ' ' . $option{'class'} if defined $option{'class'} && length $option{'class'};
	my $attributes = '';
	$attributes .= ' style="' . $option{'style'} . '"' if defined $option{'style'} && length $option{'style'};
	$attributes .= ' hint="' . $option{'hint'} . '"' if defined $option{'hint'} && length $option{'hint'};
	return '<span class="' . $class . '" duration="' . $absolute . '"'
		. ($negative ? ' sign="-"' : '') . $attributes . '>'
		. &duration_sayer($milliseconds / 1000) . '</span>';
}

sub time_abbrev_unit {
	my $token = shift;
	return undef unless defined $token && length $token;
	return 'month'  if $token eq 'M';
	return 'decade' if $token eq 'D';
	my $t = lc $token;
	return 'month'       if $t =~ /^(?:mo|mon|mos|month|months)$/;
	return 'millisecond' if $t =~ /^(?:ms|msec|msecs|millisecond|milliseconds)$/;
	return 'second'      if $t =~ /^(?:s|sec|secs|second|seconds)$/;
	return 'minute'      if $t =~ /^(?:m|mi|min|mins|minute|minutes)$/;
	return 'hour'        if $t =~ /^(?:h|hr|hrs|hour|hours)$/;
	return 'day'         if $t =~ /^(?:d|day|days)$/;
	return 'week'        if $t =~ /^(?:w|wk|wks|week|weeks)$/;
	return 'year'        if $t =~ /^(?:y|yr|yrs|year|years)$/;
	return 'decade'      if $t =~ /^(?:decade|decades)$/;
	return 'century'     if $t =~ /^(?:c|century|centuries)$/;
	return undef;
}

sub time_abbrev_translator {
	my ($timing, $timestamp) = @_;
	return '1' if defined $timing && $timing =~ /Infinity|NaN/i;
	return unless defined $timing && $timing =~ /\S/;

	my $text = $timing;
	$text =~ s/^\s+|\s+$//g;
	# "in 2 days" is a length read the other way; the old reader carried the
	# sign separately and ago_calc still relies on it.
	my $negative = ($text =~ s/^in\s+//i) ? 1 : 0;

	# Split a compact form into number/unit tokens: 1h30m -> 1 h 30 m,
	# 2days -> 2 days, 1.5d -> 1.5 d. A sign stays with its number.
	$text =~ s/([0-9.])([A-Za-z])/$1 $2/g;
	$text =~ s/([A-Za-z])([0-9])/$1 $2/g;

	my $at = (defined $timestamp && $timestamp) ? $timestamp : &rightNow();
	my ($total, $number, $have_number) = (0, undef, 0);

	my $add = sub {
		my ($value, $unit) = @_;
		return unless defined $value;
		$value = -$value if $negative && $value > 0;
		if (!defined $unit) {
			# a bare number keeps the old contract: minutes
			$total += $value * 60 * 1000;
		}
		elsif ($unit eq 'month' || $unit eq 'year') {
			# a calendar step, so February and 29 February are real lengths
			$total += &calendar_shift($at, int($value), $unit) - $at;
		}
		else {
			$total += $value * $time_abbrev_ms{$unit};
		}
	};

	foreach my $token (split /\s+/, $text) {
		next unless length $token;
		# a comma or full stop belongs to the sentence, not the unit
		my $word = $token;
		$word =~ s/^[^A-Za-z0-9.+-]+//;
		$word =~ s/[^A-Za-z0-9]+$//;
		next unless length $word;

		if ($word =~ /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/) {
			$add->($number, undef) if $have_number;
			$number = $word + 0;
			$have_number = 1;
			next;
		}
		if ($word =~ /^(?:a|an)$/i) {
			$add->($number, undef) if $have_number;
			$number = 1;
			$have_number = 1;
			next;
		}
		next if $word =~ /^(?:and|ago|from|now)$/i;

		my $unit = &time_abbrev_unit($word);
		if (defined $unit && $have_number) {
			$add->($number, $unit);
			$number = undef;
			$have_number = 0;
		}
		# a unit with no number ("next week") is not a length this reader can
		# bill; leave the phrase to the caller's other handlers
		# an unknown word is skipped, as the old reader did
	}
	$add->($number, undef) if $have_number;
	return $total;
}

sub is_leap_year {
	my $timestamp = shift;
	my $year = localtime( $timestamp / 1000 )->strftime( "%Y");
	if ($timestamp < 10000) {
		$year = $timestamp;
	}
	return 0 if $year % 4;
	return 1 if $year % 100;
	return 0 if $year % 400;
	return 1;

}

sub days_in_month {
	my ($year, $month) = @_;
	$month = ($month || 0) + 0;
	return 0 unless $month >= 1 && $month <= 12;
	return 31 if $month == 1 || $month == 3 || $month == 5 || $month == 7 || $month == 8 || $month == 10 || $month == 12;
	return 30 if $month == 4 || $month == 6 || $month == 9 || $month == 11;
	return &is_leap_year(($year || 0) + 0) ? 29 : 28;
}

# A large browser script is a short index plus a folder of ordered parts, the
# same shape a big template page uses (a page plus a folder of its own name).
# The index keeps its old path so a help topic, a source-grep test or a direct
# <script> tag still names a real file; the parts are picked up in name order,
# which is why they carry a numeric prefix. This is the one definition of the
# convention - the bundle route, the help inventory and the test helper all
# follow it.
sub js_part_files {
	my $rel = shift // '';
	$rel =~ s{^/+}{};
	$rel = 'public/' . $rel unless $rel =~ m{^public/};
	return () unless -f $rel;
	my @files = ($rel);
	(my $dir = $rel) =~ s{\.js$}{};
	push @files, sort grep { -f } glob("$dir/*.js") if -d $dir;
	return @files;
}

# The same list as browser paths, for a template that loads a script directly
# (the manager bundle uses js_part_files itself).
sub js_script_urls {
	my @urls;
	foreach my $file (&js_part_files(@_)) {
		(my $url = $file) =~ s{^public}{};
		push @urls, $url;
	}
	return @urls;
}

1;
