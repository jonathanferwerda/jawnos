package Manager;

# Manager helpers, part 1 of 37. Moved out of Manager.pl so a
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

sub record_source_param($source) {
	$source = '' unless defined $source;
	return '' unless $source =~ /^(?:video|video_front|audio|screen|security|system)$/;
	return $source;
}

sub record_video($data) {
	return if $device eq 'mobile';
	my $app = $data->{'app'};
	my $app_path = &subs::path_name($app);
	my $uuid = $data->{'uuid'};
	my $timestamp = $data->{'timestamp'};
	my $folder = &subs::home(&subs::setting_grabber( { app => 'misc', setting => 'video_location', device => $device } ));

	my $filename = $folder . '/' . $app_path;
	`mkdir -p $filename` unless -e $filename;
	$filename = $filename . '/' . $app_path . '_' . $timestamp . '.webm';

	&subs::subprocessor(sub {
		`ffmpeg -nostdin -i /dev/video0 $filename`;
	}, { name => "Video file converter" });

	return [];
}

sub record_audio($data) {
	my $app = $data->{'app'};
	my $app_path = &subs::path_name($app);
	my $uuid = $data->{'uuid'};
	my $timestamp = $data->{'timestamp'};
	my $folder = &subs::home(&subs::setting_grabber( { app => 'misc', setting => 'rec_location', device => $device } ));
	my $filename = $folder . '/' . $app_path;
	`mkdir -p $filename` unless -e $filename;
	if ($device eq 'mobile') {
		$filename = $filename . '/' . $app_path . '_' . $timestamp . '.mp3';
	}
	else {
		$filename = $filename . '/' . $app_path . '_' . $timestamp . '.wav';
	}

	if ($device eq 'mobile') {
		&subs::subprocessor(sub {
			&subs::device_call('media.record', { action => 'start', path => $filename });
		}, { name => "Audio file converter" });
	}
	elsif ($device eq 'computer') {
		&subs::subprocessor(sub {
			`rec $filename`;
		}, { name => "Audio file converter" });
	}
	return [];
};

sub record_video_stop($data) {
	return if $device eq 'mobile';
	my $app = $data->{'app'};
	my $app_path = &subs::path_name($app);
	my $uuid = $data->{'uuid'};
	my $timestamp = $data->{'timestamp'};


	my $folder = &subs::home(&subs::setting_grabber( { app => 'misc', setting => 'video_location', device => $device } ));

	my $filename = $folder . '/' . $app_path;
	`mkdir -p $filename` unless -e $filename;

	`pkill ffmpeg`;
	my $stopped = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
	if ($stopped->{'uuid'} && $stopped->{'type'} eq 'record') {

		my $files = eval { return decode_json $stopped->{'file'} } || [];
		$filename = $filename . '/' . $app_path . '_' . $timestamp . '.webm';
		my $duration = $timestamp - $stopped->{'timestamp'};
		my $data = { server_time => &subs::rightNow(), f => $filename, uuid => &subs::random_string_creator(16), type => 'video' };
		$data = &thumbnail_creator($data);
		push @{$files}, $data;
		my $jdata = encode_json $files;
		&subs::db_update('appointments', {
			server_time => &subs::rightNow(),
			duration => $duration,
			encryption_standard => undef,
			file => $jdata,
			type => 'video',
			stop_timestamp => &subs::rightNow(),
			stop_seen => 'yes',
			seen => 'yes'
		},
		{
			app => $app,
			uuid => $uuid
		});
		sleep 2;
		&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
		&subs::file_encrypter({ app => $app });
	}
	return $filename;
}

sub record_audio_stop($data) {
	my $c = $data->{'c'};
	my $app = $data->{'app'};
	my $app_path = &subs::path_name($app);
	my $timestamp = $data->{'timestamp'};
	my $uuid = $data->{'uuid'};
	my $filename;

	if ($device eq 'mobile') {
		&subs::device_call('media.record', { action => 'stop' });
	}
	elsif ($device eq 'computer') {
		`pkill rec`;
	}
	my $folder = &subs::home(&subs::setting_grabber( { app => 'misc', setting => 'rec_location', device => $device } ));
	my ($db) = &subs::database_grabber();
	my $stopped = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
	if ($stopped->{'uuid'} && $stopped->{'type'} eq 'record') {
		$filename = $folder . '/' . $app_path;
		`mkdir -p $filename` unless -e $filename;
		if ($device eq 'mobile') {
			$filename = $filename . '/' . $app_path . '_' . $timestamp . '.mp3';
		}
		else {
			$filename = $filename . '/' . $app_path . '_' . $timestamp . '.wav';
		}
		my $duration = $timestamp - $stopped->{'timestamp'};

		my $files = eval { return decode_json $stopped->{'file'} } || [];

		my $data = { server_time => &subs::rightNow(), f => $filename, uuid => &subs::random_string_creator(16), type => 'audio' };
		push @{$files}, $data;
		my $jdata = encode_json $files;
		&subs::db_update('appointments', {
			server_time => &subs::rightNow(),
			duration => $duration,
			encryption_standard => undef,
			file => $jdata,
			type => 'audio',
			stop_timestamp => &subs::rightNow(),
			stop_seen => 'yes',
			seen => 'yes'
		},
		{
			app => $app,
			uuid => $uuid
		});
		&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});
		&subs::file_encrypter({ app => $app });
	}
	return $filename;
}

sub time_machine_read {
	my ($spec, $timestamp, $deep) = @_;
	return undef unless defined $spec && $spec =~ /\S/;
	$timestamp = &subs::rightNow() unless defined $timestamp;
	my $ms = &subs::resolve_when($spec, $timestamp);
	# a date with a name still attached ("sept 11 attacks") is an event, not that
	# date: the guide reads it, and the plain date is kept only if it has nothing
	if (defined $ms && &subs::date_leftover($subs::resolve_when_residual) && $deep) {
		my $guide = &guide_time_machine($spec, $timestamp);
		$ms = $guide if defined $guide;
	}
	if (!defined $ms) {
		# a length written in words or a compact unit ("five days ago", "5m ago",
		# "in two hours", "6 months"): a bare length points into the past, "in"
		# into the future and "ago" into the past, the same reading the time
		# machine's Guide makes
		my $words = &subs::number_words_to_digits($spec);
		if ($words =~ /^\s*(in\s+)?(\d+(?:\.\d+)?)\s*(milliseconds?|seconds?|minutes?|hours?|days?|weeks?|months?|years?|mins?|secs?|hrs?|mos?|wks?|yrs?|ms|s|m|h|d|w|M|y)(?:\s+ago)?\s*$/i) {
			my ($ahead, $count, $unit) = ($1, $2, $3);
			my %unit_key = (s => 's', m => 'm', h => 'h', d => 'd', w => 'w', y => 'y', ms => 'ms', M => 'M');
			my $lower = lc($unit);
			my $key = $unit_key{$unit}
				|| ($lower =~ /^month/ ? 'M'
				: $lower =~ /^year/ ? 'y'
				: $lower =~ /^minute/ ? 'm'
				: $lower =~ /^min/ ? 'm'
				: $lower =~ /^second/ ? 's'
				: $lower =~ /^sec/ ? 's'
				: $lower =~ /^hour/ ? 'h'
				: $lower =~ /^hr/ ? 'h'
				: $lower =~ /^day/ ? 'd'
				: $lower =~ /^week/ ? 'w'
				: $lower =~ /^wk/ ? 'w'
				: $lower =~ /^mo/ ? 'M'
				: $lower =~ /^yr/ ? 'y'
				: substr($lower, 0, 1));
			my $length = &subs::time_abbrev_translator($count . $key, $timestamp);
			$ms = $ahead ? $timestamp + abs($length) : $timestamp - abs($length) if defined $length && $length;
		}
	}
	if (!defined $ms) {
		my $relative = 0;
		if ($spec =~ /^\s*(?:now|today|tomorrow|yesterday|tonight|tom|yes|mon|tue|wed|thu|fri|sat|sun)\s*$/i) { $relative = 1; }
		# a compact offset that is not a single length ("-3h", "3d 4h", "in 2h");
		# a spelled-out unit ("6 months") was read above
		elsif ($spec =~ /^\s*(?:in\s+)?[+-]?\d/ && $spec !~ /\b(?:second|minute|hour|day|week|month|year|decade|century)s?\b/i) { $relative = 1; }
		$ms = &subs::ago_calc($spec, $timestamp) if $relative;
	}
	if (!defined $ms) {
		# a time of day that is a habit ("breakfast", "next coffee time"): the hour
		# the person usually does it, from their own records, else a plain hour
		$ms = &subs::usual_ritual_time($spec, $timestamp);
	}
	if (!defined $ms) {
		# "<person>'s [Nth] birthday": a saved birthday first, then the guide, with
		# the years counted here
		$ms = &person_birthday_of($spec, $timestamp);
	}
	# ago_calc's old string surgery can land on the epoch for a phrase it did not
	# really read; that is not a moment the person named
	$ms = undef if defined $ms && $ms == 0 && $spec !~ /\b(?:1970|epoch|unix)\b/i;
	if (!defined $ms && $deep) {
		my $guide = &guide_time_machine($spec, $timestamp);
		$ms = $guide if defined $guide;
	}
	return $ms;
}

sub time_machine_resolve {
	my ($spec, $timestamp) = @_;
	$timestamp = &subs::rightNow() unless defined $timestamp;
	return $timestamp unless defined $spec && $spec =~ /\S/;
	my $ms = &time_machine_read($spec, $timestamp, 1);
	$ms = $timestamp unless defined $ms;
	return $ms;
}

sub warranty_resolve {
	my ($spec, $anchor, $deep) = @_;
	return undef unless defined $spec && $spec =~ /\S/;
	return $spec + 0 if $spec =~ /^\s*\d{12,}\s*$/;
	$anchor = &subs::rightNow() unless defined $anchor;
	my $ms = &subs::resolve_when($spec, $anchor);
	return $ms if defined $ms;
	my $past_words = $spec =~ /\b(?:ago|last|before|past|yesterday)\b/i;
	my $length = &guide_duration_ms($spec, '', $anchor);
	return $anchor + abs($length) if defined $length && $length && !$past_words;
	return undef unless $deep;
	my $read = &time_machine_read($spec, $anchor, 1);
	return undef unless defined $read;
	# a bare length the guide read as past points forward for a warranty
	$read = $anchor + ($anchor - $read) if $read < $anchor && !$past_words;
	return $read;
}

sub duration_read {
	my ($spec) = @_;
	return undef unless defined $spec && $spec =~ /\S/;
	return $spec + 0 if $spec =~ /^\s*\d{12,}\s*$/;
	my $ms = &guide_duration_ms($spec, '');
	return $ms if defined $ms;
	my $compact = &subs::time_abbrev_translator($spec);
	return $compact if defined $compact && $compact =~ /^-?[0-9.]+$/ && $compact != 0;
	return undef;
}

sub time_preview_date {
	my ($ms) = @_;
	return &subs::ui('not read') unless defined $ms;
	return localtime(int($ms / 1000))->strftime('%m/%d/%y %H:%M:%S');
}

sub time_preview_schedule {
	my ($result) = @_;
	return { text => &subs::ui('Once'), read => 1 } unless $result;
	if ($result->{'ask'}) {
		return { text => &subs::ui('Needs a question when saved'), ask => $result->{'ask'}, read => 1 };
	}
	my $dates = $result->{'dates'} || [];
	return { text => &subs::ui('Once'), read => 1 } unless scalar @{$dates};
	my @say = map { localtime(int($_ / 1000))->strftime('%a %b %d') } @{$dates};
	return { text => &subs::ui('Next') . ': ' . join(', ', @say), dates => \@say, read => 1 };
}

sub guide_when_ms {
	my ($when) = @_;
	my $now = &subs::rightNow();
	return $now unless defined $when && $when =~ /\S/;
	return $when + 0 if $when =~ /^\s*\d{12,}\s*$/;
	return &time_machine_resolve($when, $now);
}

sub guide_duration_ms {
	my ($phrase, $type, $anchor) = @_;
	return undef unless defined $phrase && $phrase =~ /\S/;
	$phrase = &subs::number_words_to_digits($phrase);
	my %mult = (
		ms => 1, millisecond => 1, milliseconds => 1,
		s => 1000, sec => 1000, secs => 1000, second => 1000, seconds => 1000,
		m => 60000, min => 60000, mins => 60000, minute => 60000, minutes => 60000,
		h => 3600000, hr => 3600000, hrs => 3600000, hour => 3600000, hours => 3600000,
		d => 86400000, day => 86400000, days => 86400000,
		w => 604800000, week => 604800000, weeks => 604800000,
	);
	my $total = 0;
	my $seen = 0;
	while ($phrase =~ /(\d+(?:\.\d+)?)\s*([a-zA-Z]*)/g) {
		my $n = $1;
		my $u = $2 || '';
		my $lower = lc($u);
		$lower = 'm' if $lower eq '';   # a bare number is minutes, as the app's own input reads it
		# an upper-case M is months; a lower-case m is minutes
		my $m = ($u eq 'M') ? undef : $mult{$lower};
		if (!defined $m) {
			# months and years are calendar lengths, so the app's own parser reads
			# them; pass it the compact unit, or a plural word loses its last 's'
			# to the seconds branch
			my $unit = $u eq 'M' ? 'M'
				: $lower =~ /^month/ ? 'M'
				: $lower =~ /^year/ ? 'y'
				: $lower =~ /^decade/ ? 'D'
				: $lower =~ /^centur/ ? 'c'
				: $lower;
			my $ms = eval { &subs::time_abbrev_translator($n . $unit, $anchor || &subs::rightNow()) };
			next unless defined $ms && $ms =~ /^-?[0-9.]+$/;
			$m = int($ms) / $n;
		}
		$total += $n * $m;
		$seen = 1;
	}
	return undef unless $seen && $total > 0;
	# Time is an accrual: a start/record is stored as a NEGATIVE offset, so a
	# start/stop pair writes start - stop and a five-minute office visit is -300000ms.
	# Other types keep the plain length. Mirrors the appointment's own duration input,
	# whose start/record rule negates what the person typed.
	return (($type || '') =~ /^(?:start|record)$/) ? -int($total) : int($total);
}

sub guide_time_keywords {
	my ($spec) = @_;
	$spec = lc($spec // '');
	$spec =~ s/['\x{2019}]\w+//g;   # drop contractions: "i'll" leaves "i"
	my %stop = map { $_ => 1 } qw(
		the a an of to in on at by for with about from into over after before
		my your their his her our its this that these those
		last first next previous following time times day date when
		was were is are am be been being
		did do does have had has i me you it we they he she them us
		and or but if then than so as
		saw see seen meet met went go got get
		what whats how who whom whose which please tell give show find
		will would shall should can could may might must
	);
	my @w = grep { length($_) > 1 && $_ =~ /^[a-z0-9_]+$/ && !$stop{$_} } split /\s+/, $spec;
	@w = @w[0 .. 4] if @w > 5;
	return @w;
}

sub help_search_summary {
	my ($f) = @_;
	my @bits;
	push @bits, 'apps: ' . join(', ', map { $_->{'app'} } @{ $f->{'apps'} || [] }) if @{ $f->{'apps'} || [] };
	push @bits, 'names: ' . join(', ', @{ $f->{'named'} || [] }) if @{ $f->{'named'} || [] };
	push @bits, 'oldest match: ' . $f->{'first'}->{'when'} . ' (' . $f->{'first'}->{'app'} . ')' if $f->{'first'};
	push @bits, 'newest match: ' . $f->{'last'}->{'when'} . ' (' . $f->{'last'}->{'app'} . ')' if $f->{'last'};
	push @bits, 'next match from now: ' . $f->{'next'}->{'when'} . ' (' . $f->{'next'}->{'app'} . ')' if $f->{'next'};
	return @bits ? join('; ', @bits) : 'nothing found';
}

sub help_search($q, $device = undef) {
	$q = '' unless defined $q;
	my $like = '%' . join('%', split /\s+/, $q) . '%';
	my $now = &subs::rightNow();
	my (%apps, %files, %named, $first, $last, $next);
	my $visible_count = 0;
	my $fpat = join('.*', map { quotemeta } split /\s+/, lc $q);
	if (length $q) {
		my $rows = &subs::db_query('select app, uuid, file, notes, timestamp, project, club, account, vendor from appointments where (app like ? or file like ? or notes like ?) limit 80', $like, $like, $like)->hashes;
		my $private_open = &subs::private_reachable_now() && &subs::private_revealed($device);
		foreach my $r ( @{$rows} ) {
			next unless help_app_visible($r->{'app'}, $device);
			# A record filed under a private construct is not named by the Guide
			# outside a private place, or without this screen's fingerprint grant.
			next if &subs::appointment_private_now($r) && !$private_open;
			$visible_count++;
			$apps{ $r->{'app'} }++ if $r->{'app'};
			my $fl = eval { decode_json $r->{'file'} } || [];
			foreach my $f ( @{$fl} ) {
				my $n = $f->{'name'} || $f->{'f'};
				next unless $n && lc($n) =~ /$fpat/i;
				$n =~ s{.*/}{};
				$files{ $n } = 1;
			}
			my $ts = $r->{'timestamp'};
			next unless defined $ts && $ts =~ /^\d+$/;
			$ts += 0;
			my $when = eval { localtime($ts / 1000)->strftime('%A %B %d, %Y') };
			next unless $when;
			my $hit = { app => $r->{'app'}, ts => $ts, when => $when };
			$first = $hit if !$first || $ts < $first->{'ts'};
			$last  = $hit if !$last  || $ts > $last->{'ts'};
			$next  = $hit if $ts >= $now && (!$next || $ts < $next->{'ts'});
		}
		foreach my $table ( sort keys %help_search_tables ) {
			my @cols = @{ $help_search_tables{$table} };
			my $where = join(' or ', map { "$_ like ?" } @cols);
			my $rs = eval { &subs::db_query("select " . join(', ', @cols) . " from $table where $where limit 20", (map { $like } @cols)) };
			next unless $rs;
			foreach my $r ( @{ $rs->hashes } ) {
				foreach my $col ( @cols ) {
					next unless defined $r->{$col} && $r->{$col} =~ /\S/ && $r->{$col} !~ /^\d+$/;
					$named{ $r->{$col} } = 1;
				}
			}
		}
	}
	my @apps = map { { app => $_, count => $apps{$_} } } sort { $apps{$b} <=> $apps{$a} } keys %apps;
	my @all = sort keys %files;
	@all = @all[0 .. 7] if @all > 8;
	my @named = sort keys %named;
	@named = @named[0 .. 15] if @named > 16;
	return { query => $q, count => $visible_count, apps => \@apps, files => \@all, named => \@named, first => $first, last => $last, next => $next };
}

sub person_birthday_of {
	my ($spec, $timestamp) = @_;
	my ($name, $n, $mod, $tense) = ('', undef, '', '');
	my $annual = 0;
	if    ($spec =~ /^\s*(?:when\s+)?(?:was|is)\s+(.+?)\s+born\s*$/i)                 { ($name) = ($1); }
	elsif ($spec =~ /^\s*(?:the\s+)?(?:day|date)\s+(.+?)\s+(?:was|is)\s+born\s*$/i)   { ($name) = ($1); }
	elsif ($spec =~ /^\s*(?:what|which)\s+(?:day|date)\s+(?:was|is)\s+(.+?)\s+born\s*$/i) { ($name) = ($1); }
	elsif ($spec =~ /^\s*(?:when\s+(is|was)\s+|when['\x{2019}]s\s+)?(.+?)[\x{2019}']?s\s+(?:(next|last)\s+)?(?:(\d{1,3})\s*(?:st|nd|rd|th)\s+)?birthday\s*$/i) {
		($tense, $name, $mod, $n) = (lc($1 // ''), $2, lc($3 // ''), $4);
		$annual = 1;
	}
	else { return undef; }
	$name =~ s/^\s+|\s+$//g;
	return undef unless length $name;
	my $birth = &subs::saved_birthday_ms($name, $timestamp);
	$birth = &guide_time_machine($name . "'s birthday", $timestamp) unless defined $birth;
	return undef unless defined $birth;
	# "when was <name> born" / "the day <name> was born" name the actual date
	return $birth unless $annual;
	my @b = localtime($birth / 1000);
	# the occasion in a given year, at the birthday's own time of day
	my $in_year = sub {
		my ($year) = @_;
		return &subs::resolve_when(sprintf('%04d-%02d-%02d %02d:%02d:%02d', $year, $b[4] + 1, $b[3], $b[2], $b[1], $b[0]), $timestamp);
	};
	# "the Nth birthday" is the year they turn N
	return $in_year->($b[5] + 1900 + $n) if defined $n;
	# the occasion falls each year: the next one to come, or the last one that passed
	my @now = localtime($timestamp / 1000);
	my $this = $in_year->($now[5] + 1900);
	my $past = ($tense eq 'was') || ($mod eq 'last');
	if ($past) {
		return (defined $this && $this <= $timestamp) ? $this : $in_year->($now[5] + 1899);
	}
	return (defined $this && $this >= $timestamp) ? $this : $in_year->($now[5] + 1901);
}

sub guide_time_machine {
	my ($spec, $timestamp) = @_;
	my $key = lc $spec;
	return $time_machine_guide_cache{$key} if exists $time_machine_guide_cache{$key};
	my $ms;
	my $model = &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
	if ($model) {
		my $now_text = localtime(&subs::rightNow() / 1000)->strftime('%A, %B %d %Y, %I:%M%P');
		my @words = &guide_time_keywords($spec);
		my $dossier = '';
		if (@words) {
			my $found = &help_search(join(' ', @words));
			$dossier = 'Here is what their records show for "' . join(' ', @words) . '": ' . &help_search_summary($found) . '. ';
		}
		my $birthday = ($config->{'birthday'} ? ('Their birthday is ' . $config->{'birthday'} . '. ') : '');
		my $system = 'You are the time machine inside JawnOS. The person typed a phrase that names a moment, or asks you to start or log something. '
			. 'Right now it is ' . $now_text . ' in local time. ' . $birthday . $dossier
			. 'If the phrase names a person or an event, past or future ("Abraham Lincoln\'s birthday", "the day the Berlin Wall fell", "when the first world war ended"), use what you know of history and give the moment it names - including the hour and minute when history records one (the moment JFK was shot, the hour the armistice took effect). For a period or an era that has no single day (the American Revolution, the Renaissance), give the moment it began. '
			. 'If the phrase names no time of day, keep the present time of day. A bare amount of time with no direction ("6 months", "2 hours") points into the past; a leading minus points ahead. '
			. 'Reply with ONE JSON action and nothing else: '
			. '{"action":"time","when":"YYYY-MM-DD HH:MM:SS"} naming the moment the phrase means in local time, to travel there; '
			. 'or {"action":"create","app":"lunch","title":"Lunch","when":"in 20 minutes","type":"start","duration":"20 minutes"} to make an appointment, when they ask you to start, begin or log something ("type" is start, record or command for something the alarm fires; "duration" is how long it lasts, only when they say it - give a plain positive length, the tree stores it as the negative accrual itself). '
			. 'If the phrase names no moment and asks for nothing, reply {"action":"time","when":"unknown"}';
		my ($text, $err) = &subs::evaluation_model_call_role('help_assistant', $system, $spec, &subs::ai_role_thinking_effective('help_assistant'));
		if ($text) {
			my $action = &subs::json_from_model($text);
			$action = { action => 'time', when => $text } unless $action && $action->{'action'};
			my $act = $action->{'action'};
			if ($act eq 'create' && $spec =~ /\b(?:start|begin|log|record|add|create|schedule|make|new|remind)\b/i) {
				my $when_ms = &guide_when_ms($action->{'when'});
				my $app = &subs::unformat_name($action->{'app'} || $action->{'title'} || 'appointment');
				my $title = $action->{'title'} || '';
				my $type = $action->{'type'} || 'start';
				my $duration = &guide_duration_ms($action->{'duration'}, $type);
				# the Confirmation Requirement: unticked, the appointment is written at
				# once (through appointment_writer, so its alarm and any embedded relay
				# fire); ticked, it is staged for the person to confirm instead
				my $confirm = (&subs::setting_grabber({ app => '__president', setting => 'guide_confirm', device => 'all' }) // 'on');
				if ($confirm eq 'off') {
					my $appt = {
						uuid => &subs::random_string_creator(40),
						app => $app,
						type => $type,
						timestamp => $when_ms,
						server_time => &subs::rightNow(),
						notes => $title,
						source => 'guide',
						device => &subs::device_setter(),
					};
					$appt->{'duration'} = $duration if defined $duration;
					&appointment_writer(undef, $appt);
				}
				else {
					&guide_stage_appointment(undef, { app => $app, type => $type, timestamp => $when_ms, title => $title, duration => $action->{'duration'}, source => 'guide' });
				}
				$ms = $when_ms;
			}
			elsif ($act eq 'time') {
				my $w = $action->{'when'};
				if (defined $w && $w !~ /unknown/i) {
					# read the answer with the same resolver, so a year-1 or B.C. answer
					# ("0001-12-25", "-0044-03-15") lands right - str2time reads year 1
					# as 2001 and refuses a negative year
					my $r = &subs::resolve_when($w, $timestamp);
					if (!defined $r) {
						$w =~ s/\bat\b/ /gi;
						my $t = eval { str2time($w) };
						$r = $t * 1000 if $t;
					}
					$ms = $r if defined $r;
				}
			}
		}
	}
	$time_machine_guide_cache{$key} = $ms;
	return $ms;
}

sub timestamp_adjuster($c) {
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $time_machine = $c->param('time_machine');
	my $timeshift = $c->param('timeshift');
	my $ago = $c->param('ago');
	if ($time_machine) {
		$timestamp = &time_machine_resolve($time_machine,$timestamp);
	}
	if ($timeshift) {
		if ($timeshift =~ /[0-9]/gi) {
			$timestamp = &subs::ago_calc($timeshift,$timestamp);
		}
	}
	if ($ago) {
		$timestamp = &time_machine_resolve($ago,$timestamp);
	}
	return $timestamp;
}

sub native_capture_dir() {
	# `home()` only expands a leading ~; a bare relative path stayed relative, so
	# the app's always-absolute staged path could never match it (the capture was
	# refused and looked lost).
	return &subs::home('~/.jawn/captures');
}

# The app is installed as com.jawnos and reports getFilesDir() paths, which on
# newer Android is /data/user/<n>/com.jawnos/...; the manager's HOME is
# /data/data/com.jawnos/.... They are the same files, and realpath does not
# unify them (data/data is a bind mount), so the two spellings are normalised
# to one before the claim is checked.
sub native_capture_spelling($path) {
	return $path unless defined $path && length $path;
	$path =~ s{^/data/user/[0-9]+/}{/data/data/};
	return $path;
}

sub native_capture_claim($path) {
	return undef unless defined $path && length $path;
	my $name = $path;
	$name =~ s{.*/}{};
	return undef unless $name =~ /^[A-Za-z0-9._-]+$/ && $name !~ /^\.\.?$/;
	my $want = &native_capture_dir() . '/' . $name;
	return undef unless &native_capture_spelling($path) eq &native_capture_spelling($want);
	return undef if -l $path;
	return undef unless -f $path;
	# Hand back the path as given: the claim is a reference to a file that exists,
	# not a recipe for where it should have been.
	return $path;
}

1;
