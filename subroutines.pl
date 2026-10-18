#!/usr/bin/env perl
package subs;

use strict;
use warnings;

use Mojolicious::Lite;
use List::Util qw(shuffle);
use Mojo::Util qw/md5_sum html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use Text::Unidecode;

use MIME::Base64;
use Time::Duration;
use Date::Parse;
use Time::Piece;
use Time::Local;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Crypt::Simple;
use File::Slurp;
use File::Find;
use File::Copy;
use File::Path;
use File::Type;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::IOLoop::ReadWriteFork;
use Mojo::SQLite;
use Minion;
use Data::Dumper;
use Time::HiRes qw(gettimeofday time);
use Mojo::IOLoop;
use Clone qw(clone);
use MIME::Base64;
# The mail stack is heavy and used by exactly two routines (email_receiver and
# email_send). Loading it per worker at boot is pure waste on a box that never
# touches IMAP/SMTP, so each routine requires what it needs the first time it
# runs. All five are used only as class methods, so there is no import to keep.
use IO::Socket::UNIX;
use IO::Select;
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
use IPC::Open2;
my $encoder = Sereal::Encoder->new({ compress => SRL_ZSTD, compress_level => 3 });
my $decoder = Sereal::Decoder->new();
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
no warnings 'uninitialized';
no warnings 'once';
require "./gb.pl";
require "./Websocket.pl";

my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
our $logfile = &subs::home($config->{'logfile'});
our $resolve_when_residual = '';   # what resolve_when could not read as a date (see date_leftover)
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
my $universal_splitter = $gb::universal_splitter;

our $device = &device_setter();

# Request-scoped settings read-through memo (see setting_grabber). Cleared at
# each request boundary by hooks.pl; off outside requests so long-lived
# utility processes never serve stale settings.
our %setting_memo;
our $setting_memo_on = 0;
sub format_name() {
	my $name = shift || "";
	my $fname = lc $name;
	# the one misspelling the code has carried since the start: the stored key is
	# 'occurences', the name a person reads is spelled right
	$fname = 'occurrences' if $fname eq 'occurences';
	$fname =~ s/_/ /gi;
	my @fname = split ' ',$fname;
	foreach my $f (@fname) {
		my @f = split '',$f;
		$f[0] = uc $f[0];
		$f = join '', @f;
	}
	$fname = join ' ', @fname;
	return $fname;
}

# Model rows in the order a chooser should read them: alphabetical by the name the
# user sees. Kept as a routine rather than a `sort { $a->{'name'} }` in a template
# because Mojo extracts a template's stash keys into lexicals, so a template whose
# stash holds `a` (the app name) would sort the app name instead of the rows
# (the same trap written up in templates/configure/packaging.html.ep).
sub models_by_name {
	return sort { &format_name($a->{'name'}) cmp &format_name($b->{'name'}) } @_;
}

sub unformat_name() {
	my $name = shift || "";
	my $fname = lc $name;
	my $double_start = 0;
	if ($fname =~ /^__/) {
		$double_start = 1;
	}
	$fname =~ s/\'//gi;
	$fname =~ s/ /_/gi;
	my @fname = split '_',$fname;
	if ($fname[0] eq '') {
		shift @fname;
	}
	if ($fname[-1] eq '') {
		pop @fname;
	}
	$fname = join '_', @fname;
	$fname = '_' . $fname if $double_start == 1;
	return lc $fname;
}

sub apostrophe_escape() {
	my $string = shift || "";
	$string =~ s/\'/\\\'/gi;
	$string =~ s/\?/\\\?/gi;
	return $string;
}

sub shorthand_name() {
	my $name = shift || "";
	my $shorten = shift || 5;
	my $name1 = substr($name, 0, $shorten);
	return $name1;
}

sub initialize_name() {
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

sub teaser_name() {
	my $name = shift || "";
	my $name1 = substr($name, 0, 50);
	return $name1;
}

sub abbreviate_name() {
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

sub terminal_name() {
	my $name = shift || "";

	foreach my $split ( (' ', '(', ')', '{', '}', '&', '\'', '"', '+' )) {
		#my @words = split $split, $name;
		#$name = join '\\' . $split, @words;

		$name =~ s/\Q$split/\\$split/gi;
	}


	return $name;
}

# Percent-encode a filesystem name for a URL. Names that come from a directory
# walk are decoded to characters (see Music::process_file), and a Mojolicious
# template is a character string, so encode back to UTF-8 bytes first: url_escape
# would otherwise escape a multi-byte character's codepoint (Æ -> %C6) instead of
# its UTF-8 bytes (%C3%86). Plain ASCII and already-byte strings pass through.
sub url_escape_utf8() {
	my $name = shift // '';
	utf8::encode($name) if utf8::is_utf8($name);
	return url_escape($name);
}

# encode_json returns UTF-8 bytes, but a Mojolicious template is a character
# string: interpolating those bytes upgrades them as Latin-1 and mangles every
# non-ASCII value in the data (an "Ænima" tag renders as "Ãnima"). Decode back to
# characters for the template, the same reason process_file decodes the names it
# hands the window.
sub json_chars() {
	my $json = encode_json shift;
	utf8::decode($json) unless utf8::is_utf8($json);
	return $json;
}

sub html_name() {
	my $name = shift || "";
	$name =~ s/[^a-zA-Z0-9\?]+//g;
	#$name = html_unescape $name;

	return $name;
}

sub http_name() {
	my $name = shift || "";
	$name =~ s/ /_/gi;
	$name =~ s/[^a-zA-_Z0-9]+//g;
	$name = html_unescape $name;

	return $name;
}

sub wiki_name() {
	my $name = shift;
	my @name = split '_', $name;

	$name[0] = ucfirst $name[0];
	$name = join '_', @name;
	return $name;
}

sub formatted_time() {
	my $time = shift;
	return localtime($time / 1000 )->strftime('%a %b %d %Y - %I:%M:%S%P');
}

sub price_formatter() {
	my $price = shift;
	$price =~ s/^([\-])//gi;
	my $point = $1;
	if ($price =~ /[0-9.]/gi) {
		$price = $point . sprintf( "\$%.2f", $price);
	} else { $price = $point . '0.00'; }
	return $price;
}

sub percent_formatter() {
	my $percent = shift;
	$percent = $percent * 100;
	$percent = sprintf("%.3f", $percent) . '%';
	return $percent;
}

sub numeric_formatter() {
	my $number = shift;
	$number = '' unless defined $number;
	# Strip currency symbols, spaces, thousands separators, etc. -- everything
	# that isn't part of the number itself. The old pattern stripped the first
	# *digit*, turning 70 into 0 and 4700 into 700.
	$number =~ s/[^0-9.\-]//gi;
	$number = '' if $number eq '' || $number eq '-' || $number eq '.' || $number eq '-.';
	if (!$number) { $number = 0; }
	return $number
}

sub duration_sayer() {
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

sub time_abbrev_translator() {
	my $timing = shift;
	my $timestamp = shift;
	my $total_duration = 0;
	my $negative = '+';
	my @times;
	my $fulltime = $timing;
	return '1' if $timing =~ /Infinity|NaN/gi;
	return unless $timing;
	if ($timing =~ / /) {
		@times = split ' ', $timing;
	}
	else {
		push @times, $timing;
	}

	foreach my $time ( @times ) {
		next unless $time =~ /[0-9a-zA-Z]/gi;
		my $measure;
		$fulltime =~ s/[\-.,0-9]//gi;
		if ($fulltime eq 'year') {
			$measure = 'y';
		}
		elsif ($fulltime eq 'millisecond') {
			$measure = 'ms';
		}
		elsif ($fulltime eq 'second') {
			$measure = 's';
		}
		elsif ($fulltime eq 'decade') {
			$measure = 'D';
		}
		elsif ($fulltime eq 'minute') {
			$measure = 'm';
		}
		elsif ($fulltime eq 'hour') {
			$measure = 'h';
		}
		elsif ($fulltime eq 'day') {
			$measure = 'd';
		}
		elsif ($fulltime eq 'week') {
			$measure = 'w';
		}
		elsif ($fulltime eq 'month') {
			$measure = 'M';
		}
		$time =~ s/([smhdwmycDM]$)//gi;
		if ($time eq 'in') {
			$negative = '-';
			next;
		}
		$measure = $measure || $1 || 'm';
		$time =~ s/[a-zA-Z]//gi;
		# what is left is a number, or what a word left behind - "in" leaves
		# nothing, a lone "-" keeps its sign - and neither is a number to compare,
		# multiply or count months with
		$time = 0 unless $time =~ /\d/;
		next if $times[0] =~ /\s/;
		if ($times[0]) {
			# the first word may be "in" or a bare "-" too: only a token holding a
			# number can be negative
			my $leads_negative = ($times[0] =~ /^-/ && $times[0] =~ /\d/) ? 1 : 0;
			if ($leads_negative || $negative eq '-') { $time = $time * -1 unless $time < 0; }
		}
		my $duration;
		if ($time && $time ne '-' && $time ne '') {
			$duration = 1000 * $time;
		}
		$total_duration = $total_duration + ($duration / 1000) if $measure eq 'ms' || $measure =~ /millisecond/gi;
		$total_duration = $total_duration + $duration if $measure eq 's' || ($measure =~ /second/gi && $measure !~ /millisecond/gi);
		$total_duration = $total_duration + ($duration * 60) if $measure eq 'm' || $measure =~ /minute/gi;
		$total_duration = $total_duration + ($duration * 60 * 60) if $measure eq 'h' || $measure =~ /hour/gi;
		$total_duration = $total_duration + ($duration * 60 * 60 * 24) if $measure eq 'd' || $measure =~ /day/gi;
		$total_duration = $total_duration + ($duration * 60 * 60 * 24 * 7) if $measure eq 'w' || $measure =~ /week/gi;

		if ($measure eq 'M' || $measure eq 'mos' || $measure =~ /month/gi) {
			my $total_days = 0;
			my $month = localtime( $timestamp / 1000 )->strftime( "%m");
			if ($time < 0 || $negative eq '-') {
				if ($time < -12) {
					my $years = $time / 12;
					push @times, $years . 'y';
					until ($time > -12) {
						$time = $time + 12;
					}
				}
				for (my $n = -1; $n >= $time; $n-- ) {
					my $month = localtime( $timestamp / 1000 )->strftime( "%m");
					$month = $month - $n - 1;

					if ($month > 12) { $month = $month - 12; }
					$total_days -= $gb::months->[$month - 1]->{'days'};
				}
			} else {
				if ($time > 12) {
					my $years = $time / 12;
					push @times, $years . 'y';
					until ($time < 12) {
						$time = $time - 12;
					}
				}
				for (my $n = 1; $n <= $time; $n++ ) {
					my $month = localtime( $timestamp / 1000 )->strftime( "%m");
					my $year = localtime( $timestamp / 1000 )->strftime( "%m");
					$month = $month - $n;

					if ($month <= 0) { $month = 12 + $month; }
					$total_days += $gb::months->[$month - 1]->{'days'};
				}
			}
			$duration = 1000;
			$total_duration = $total_duration + ($duration * 60 * 60 * 24 * $total_days);
		}
	 	if ($measure eq 'y' || $measure =~ /year/gi) {
			$total_duration = $total_duration + ($duration * 60 * 60 * 24 * 365);
		}
		$total_duration = $total_duration + ($duration * 60 * 60 * 24 * 365 * 10) if $measure eq 'D' || $measure =~ /decade/gi;
		$total_duration = $total_duration + ($duration * 60 * 60 * 24 * 365 * 100) if $measure eq 'c' || $measure =~ /century/gi;
	}
	return $total_duration;
}

sub is_leap_year() {
	my $timestamp = shift;
	my $month = localtime( $timestamp / 1000 )->strftime( "%m");
	my $year = localtime( $timestamp / 1000 )->strftime( "%Y");
	if ($timestamp < 10000) {
		$year = $timestamp;
	}
	return 0 if $year % 4;
	return 1 if $year % 100;
	return 0 if $year % 400;
	return 1;

}

sub timespan_widener() {
	my $fulltime = shift;
	$fulltime =~ s/[0-9,.]//gi;
	my $measure = $fulltime;
	if ($fulltime eq 'y') {
		$measure = 'year';
	}
	elsif ($fulltime eq 's') {
		$measure = 'second';
	}
	elsif ($fulltime eq 'D') {
		$measure = 'decade';
	}
	elsif ($fulltime eq 'm') {
		$measure = 'minute';
	}
	elsif ($fulltime eq 'h') {
		$measure = 'hour';
	}
	elsif ($fulltime eq 'd') {
		$measure = 'day';
	}
	elsif ($fulltime eq 'w') {
		$measure = 'week';
	}
	elsif ($fulltime eq 'M') {
		$measure = 'month';
	}
	return $measure;

}

sub appt_alarm_setter() {
	my ($appt) = @_;
	my @times = (
		$appt->{'timestamp'},
		$appt->{'stop_timestamp'},
		$appt->{'next_duty'}
	);
	# a moment that has just gone by still counts: the record button's
	# appointment is due the instant it is written, and the poke is what wakes
	# the alarm clock in time to start the recording - without the small grace
	# the start was filtered away and the clock only woke at the stop, taking
	# a take of nothing
	if (grep { $_ && $_ >= &subs::rightNow() - 5000 } @times) {
		my $file = $gb::tmp_dir . '/alarm';
		eval {
			my $socket = IO::Socket::UNIX->new(
				Peer => $file,
				Type => SOCK_STREAM,
			) or die "Socket connection failed: $!";
			$socket->autoflush(1);

			my $jwsm = encode_json $appt;
			print $socket $jwsm . "\n";
		};
	}
};

sub next_appointment_time() {
	my ($data) = @_;
	my $last_moment = $data->{'now'};
	my $limit = $data->{'limit'} || 10;
	$last_moment = &subs::rightNow() unless $last_moment;
	my $next_moment = $last_moment + (7 * 24 * 60 * 60 * 1000);
	my $next_values = [];
	my $next_appts = &subs::db_query('select app,uuid,timestamp,stop_timestamp,next_duty from appointments where (timestamp >= ? and seen is null) or ((type = ? or type = ? or type = ? or type=? or type = ?) and stop_timestamp is not null and stop_timestamp >= ? and stop_seen is null ) order by timestamp limit ?',
		$last_moment, 'start','record','video','audio','screen',$last_moment,$limit)->hashes;
	push @{$next_appts}, @{&subs::db_query('select app,uuid,next_duty,timestamp,stop_timestamp from appointments where duties is not null and next_duty >= ? and next_duty is not null limit ?', $last_moment,$limit)->hashes};
	my @seen_uuids;
	foreach my $next_appt ( @{$next_appts} ) {

		push @seen_uuids, $next_appt->{'uuid'};
		push @{$next_values}, { app => $next_appt->{'app'}, uuid => $next_appt->{'uuid'}, timestamp => $next_appt->{'timestamp'} } if $next_appt->{'timestamp'} >= $last_moment;
		push @{$next_values}, { app => $next_appt->{'app'}, uuid => $next_appt->{'uuid'}, timestamp => $next_appt->{'stop_timestamp'} } if $next_appt->{'stop_timestamp'} >= $last_moment;
		push @{$next_values}, { app => $next_appt->{'app'}, uuid => $next_appt->{'uuid'}, timestamp => $next_appt->{'next_duty'} } if $next_appt->{'next_duty'} >= $last_moment;
	}

	@{$next_values} = grep { $_->{'timestamp'} >= $last_moment } @{$next_values};
	@{$next_values} =  sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$next_values};
	my $next_run = scalar @{$next_values} > 0 ? $next_values->[0]->{'timestamp'} : $next_moment;
	my $next_time = (($next_run - &subs::rightNow()) / 1000);
	my $uuid = $next_values->[0]->{'uuid'};
	my $next_appointments = [];
	foreach my $nd ( @{$next_values} ) {
		my $n_run = $nd->{'timestamp'};
		my $n_time = (($n_run - &subs::rightNow()) / 1000);
		my $n_uuid = $nd->{'uuid'};
		push @{$next_appointments}, {
			next_run => $n_run,
			next_time => $n_time,
			uuid => $n_uuid,
			app => $nd->{'app'},
			timestamp => $nd->{'timestamp'}
		};
	}



	return { next_run => $next_run, next_time => $next_time, uuid => $uuid, list => $next_appointments };
}

# The session a stop should close: the NEWEST open start/record for the app - the one
# the person is running now. The appointment header carries this so a stop names its
# own session, and every machine in the mesh closes that same row instead of each
# resolving "the open session" against its own, possibly lagging, copy of the
# database. The newest, not the oldest: a session left open by a stop that never
# landed is the oldest, and naming it would make every fresh stop close the stale one.
sub open_session_uuid {
	my $app = shift;
	return '' unless $app;
	my $row = &db_query('select uuid from appointments where app=? and (type=? or type=?) and stop_seen is null and timestamp <= ? order by timestamp desc limit 1', $app, 'start', 'record', &rightNow())->hashes->[0];
	return ($row && $row->{'uuid'}) ? $row->{'uuid'} : '';
}

# The row a stop closes, resolved the same way wherever the stop runs (manager_reset
# and appointment_writer both call this): the session the client named, carried
# through the relay so every machine closes the same one. A stop that names a session
# closes that row and only it - a session already closed (a stop delivered twice, or
# one this machine has not synced) matches nothing and the stop does nothing, so a
# duplicate can never reach another session. Only a stop that names none falls back to
# the NEWEST open start/record for the app at or before the press. One row, never the
# backlog, and never a stale open session swept up by a nameless or repeated stop.
sub stop_target_row {
	my ($app, $target_uuid, $timestamp) = @_;
	return undef unless $app;
	$timestamp ||= &rightNow();
	if ($target_uuid) {
		my $named = &db_query('select * from appointments where app=? and uuid=? and (type=? or type=?) and stop_seen is null limit 1',
			$app, $target_uuid, 'start', 'record')->hashes->[0];
		return ($named && $named->{'uuid'}) ? $named : undef;
	}
	my $row = &db_query('select * from appointments where app=? and (type=? or type=?) and timestamp <= ? and stop_seen is null order by timestamp desc limit 1',
		$app, 'start', 'record', $timestamp)->hashes->[0];
	return ($row && $row->{'uuid'}) ? $row : undef;
}

sub appt_header_printer() {
	my $data = shift;
	my $app = $data->{'app'};

	# The header draws only the app's newest/oldest rows; the wrapper's details
	# form is the thing that needs __accounts/__projects. Skip the marker read
	# here and let the centre view build them when it renders the wrapper.
	my $appts = $data->{'appts'} || &Manager::log_reader({ app => $app, view => 'centre_view', header => 1 });
	&appt_toggle_checker($app);
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my $c = &subs::controller_builder();
	my $header = $c->render_to_string(template => 'apps/appointment_header', timestamp => $server_time, appts => $appts, appointments => [ $app ], a => $app, running_uuid => &open_session_uuid($app) );

	eval { &subs::cache_set({ app => $app, context => 'header', timestamp => $server_time, warranty => '-1d' }, { timestamp => $timestamp, header => $header, signature => &subs::render_signature() }) };
	&Websocket::send('tab', { type => 'header', app => $app, timestamp => $server_time, header => $header });
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		foreach my $a ( @{$appts->{$app}->{'list'}} ) {
			&appt_alarm_setter($a);
		}
		unless ($data->{'source'} eq 'centre_view_grabber') {
			# hand the appointments we already loaded to the worker: the render below
			# would otherwise fetch the same set from the database again
			&Manager::centre_view_grabber({ app => &subs::unformat_name($app), appts => $appts, header => $header, timestamp => &subs::rightNow(), cached => 'no' });
		}
	}, { name => 'header worker' });

	# the caller that also renders the centre view can reuse this fetch instead
	# of asking log_reader for the same rows again
	return wantarray ? ($header, $appts) : $header;
}

sub controller_builder() {
	my ($c,$params) = @_;
	unless ($c) {
		$c = app->build_controller;
	} else {
		app->sessions->samesite('lax');
		$ENV{MOJO_MAX_MESSAGE_SIZE} = 1023423423473741824;
		app->renderer->cache->max_keys(0) unless $params->{'cache'} eq 'no';
		app->sessions->encrypted(1);
		app->secrets($gb::secret_maker);
		app->sessions->cookie_name($ENV{'cookie_name'});

	}
	if ($config->{'environment'} eq 'production') {
		app->log->level('error');
	} else {
		app->log->level('debug');
	}
	return $c;
}

our $cached_sockets = {};
sub unix_socket_sender() {
	my ($file,$data,$rcv) = @_;

	if ($file eq 'memory') {
		$file = &subs::home('~/.president/memory');
	}
	elsif ($file eq 'process') {
		$file = &subs::home('~/.process_watch');
	}
	my $cache_key = $file . '_' . $$;
	my $response_data;
	eval {
		return unless -e $file;


		my $socket = $cached_sockets->{$cache_key};
    if ($socket) {
        # connected() checks if the local handle thinks it's open;
        # syswrite with 0 bytes checks if the OS kernel dropped the pipe.
        if (!$socket->connected || !defined syswrite($socket, '', 0)) {
            $socket->close;
            undef $socket;
            delete $cached_sockets->{$cache_key};
        }
    }
		if (!$socket) {
			$socket = IO::Socket::UNIX->new(
				Peer => $file,
				Type => SOCK_STREAM,
			) or die "Socket connection failed: $!";
			$socket->autoflush(1);
			$cached_sockets->{$cache_key} = $socket;
		}
		my $select = IO::Select->new($socket);

		# Anything left unread from a previous transaction would desync the
		# length-prefixed reply we are about to ask for, so drain the pipe first.
		if ($rcv == 1) {
			while ($select->can_read(0)) {
				my $stale = '';
				my $got = sysread($socket, $stale, 65536);
				last unless $got;
			}
		}

		my $jwsm           = $encoder->encode($data);
		my $payload_length = length($jwsm);
		my $packet         = pack('N', $payload_length) . $jwsm;
    my $bytes_to_write = length($packet);
    my $bytes_written = 0;
    while ($bytes_written < $bytes_to_write) {
        my $written = syswrite($socket, $packet, $bytes_to_write - $bytes_written, $bytes_written);
        die "Write error: $!" unless defined $written;
        $bytes_written += $written;
    }
	#	print $socket $packet;

    if ($rcv == 1) {
      my $timeout = 5; # seconds to wait for any single chunk of the reply

      # 1. Read header (4 bytes) safely, but never block forever
      my $response_header = '';
      while (length($response_header) < 4) {
          die "Timed out reading reply header" unless $select->can_read($timeout);
          my $bytes_read = sysread($socket, $response_header, 4 - length($response_header), length($response_header));
					die "Connection closed by remote side while reading header" if !$bytes_read;

      }
      my $incoming_length = unpack('N', $response_header);
      die "Reply unreasonably large" if $incoming_length > 64 * 1024 * 1024;

      # 2. Read the payload sequentially safely
      my $response_payload = '';
      while (length($response_payload) < $incoming_length) {
          die "Timed out reading reply payload" unless $select->can_read($timeout);
          my $bytes_read = sysread($socket, $response_payload, $incoming_length - length($response_payload), length($response_payload));
					die "Connection dropped mid-payload reading" if !$bytes_read;

      }

      # 3. Decode response using fast decoder
      $response_data = $decoder->decode($response_payload);
    }
		1;
	} or do {
		my $err = $@ || 'Unknown transaction failure';
		$log->info(Dumper $data);
		# a refused connect to a watch socket that exists is the master between
		# boots: the sender repeats its report on the next tick, so it is not an
		# error - a write or protocol failure still is
		if (defined $log) {
			if ($err =~ /Socket connection failed|Connection refused/) {
				$log->info("Socket sender: $err (the master is between boots)");
			}
			else {
				$log->error("Socket sender error: $err");
			}
		}

		# Log the state of the socket when it crashed to see if it's bloated
		if (defined $cached_sockets->{$cache_key}) {
			$log->debug("Cleaning up socket cache for $file due to error.");
		}
		delete $cached_sockets->{$cache_key};
  };

	return $response_data;
}

sub subprocessor() {
	my ($subroutine,$params) = @_;
	my $parent_pid = $$;
	my $wrapped_subroutine = sub {
		Mojo::IOLoop->reset({ freeze => 1 });
		$gb::subprocessed++;
		my $file = &subs::home('~/.process_watch');
#		my $file = $tmp_dir . '/process_watch';
		my $pid = $$;

		my $subprocess = {
			parent    => $parent_pid,
			pid       => $pid,
			timestamp => &subs::rightNow(),
			start_timestamp => &subs::rightNow(),
			name      => $params->{'name'},
			uuid      => &subs::random_string_creator(10),
			status    => 'start',
		};
		&subs::unix_socket_sender($file,$subprocess);

		if ($@) { warn "Worker $$: Failed to send 'start' state: $@" }
		eval {
			$subroutine->();
		};
		my $sub_error = $@; # Capture error if the main task fails
		eval {
			# Update payload state to stop
			$subprocess->{'status'} = 'stop';
			$subprocess->{'stop_timestamp'} = &subs::rightNow();
			&subs::unix_socket_sender($file,$subprocess);
		};
		if ($@) { warn "Worker $$: Failed to send 'stop' state: $@" }

		# If the core subroutine crashed, re-throw its error now so Mojolicious knows it failed
		if ($sub_error) {
			# A sync that dies mid-merge used to leave only a job stuck in
			# "running" and no reason anywhere. Name the sub and the die.
			eval { $log->error('subprocessor ' . ($params->{'name'} || '?') . ' pid ' . $$ . ' failed: ' . ($sub_error =~ s/\s+/ /gr)) } if $log;
			eval { &subs::log_writer('subprocessor ' . ($params->{'name'} || '?') . ' failed: ' . ($sub_error =~ s/\s+/ /gr)) };
		}
		die $sub_error if $sub_error;
	};
	# A job that may outlive the prefork heartbeat (a remote export or merge
	# over a large table) must always be a real child. Running it inline still
	# looks like a quiet worker to the prefork manager, which restarts it after
	# 200 seconds and leaves the sync's lock behind - the "crashing while
	# working on settings" loop. Callers that cannot tolerate that pass
	# fork => 1.
	if ($gb::subprocessed > 1 && !$params->{'fork'}) {
		$wrapped_subroutine->();
	} else {
		Mojo::IOLoop->subprocess->run_p($wrapped_subroutine)
	}

}



our $random_seeded_for;

sub random_string_creator() {

	# A forked worker inherits its parent's PRNG, so two children handed the same
	# sequence mint identical "random" strings - which is how the cache's unique
	# uuid collided between workers (a UNIQUE constraint failure on every racing
	# write). Seed once per process: the flag is keyed by pid because a child also
	# inherits the flag itself, and the pid and clock differ between children.
	unless (defined $random_seeded_for && $random_seeded_for == $$) {
		my ($sec, $usec) = gettimeofday();
		srand( ($$ << 16) ^ $usec ^ $sec );
		$random_seeded_for = $$;
	}

  my ($string,$count);
	$count = shift || 8;
	my $chars = shift;
  my @chars;
	if ($chars) {
		if ($chars =~ /[A-Z]/) {
			push @chars, ("A".."Z");
		}
		if ($chars =~ /[a-z]/) {
			push @chars, ("a" .. "z");
		}
		if ($chars =~ /[0-9]/) {
			push @chars, ("0".."9");
		}
	}
	else {
		@chars = ("A".."Z", "a".."z", "0".."9");
	}

  $string .= $chars[rand @chars] for 1..$count;
  return $string;
}

sub inventory_grabber() {
	my $inventory = `cat ./server/inventory.jawn`;
	my $tree;
	my @description = split "\n", $inventory;
	my $file;
	foreach my $d (@description) {
		if ($d =~ /^\//g) {
			$file = lc $d;
			$file =~ s/^\///g;
		}
		else { $tree->{lc $file}  .= $d . "\n"; }
	}
	foreach my $t ( keys %{$tree}) {
		my $temp;
		foreach my $l ( split "\n", $tree->{$t} ) {
			$temp = $l;
		}
	#	$tree->{$t} = $temp;
	}
	return $tree;
}

# Every span the app offers: a span is a count of a unit, so "2month" is two
# of the 30 day months, and the odd ones do not read that way.  time_span() is
# the one door into them, which is why a twenty two month can no longer mean
# twenty one, and time_span_list() is what the pickers are built from.
our $time_units = {
	second => 1000,
	minute => 60 * 1000,
	hour => 60 * 60 * 1000,
	day => 24 * 60 * 60 * 1000,
	week => 7 * 24 * 60 * 60 * 1000,
	month => 30 * 24 * 60 * 60 * 1000,
	year => 365 * 24 * 60 * 60 * 1000,
};

our $time_odd_spans = {
	'15second' => [ 15 * 1000, '15 Seconds' ],
	'30second' => [ 30 * 1000, '30 Seconds' ],
	'45second' => [ 45 * 1000, '45 Seconds' ],
	'fortyfiveminute' => [ 45 * 60 * 1000, '45 Minutes' ],
	moon => [ 28 * 24 * 60 * 60 * 1000, 'Moon' ],
	season => [ 90 * 60 * 60 * 1000, 'Season' ],
	quarter => [ (30.5 * 3) * 60 * 60 * 1000, 'Quarter' ],
	decade => [ 10 * 365 * 24 * 60 * 60 * 1000, 'Decade' ],
	century => [ 100 * 365 * 24 * 60 * 60 * 1000, 'Century' ],
	millenium => [ 1000 * 365 * 24 * 60 * 60 * 1000, 'Millenium' ],
	era => [ 10000 * 365 * 24 * 60 * 60 * 1000, 'Era' ],
};

my %time_span_table;
sub time_spans() {
	unless ( %time_span_table ) {
		%time_span_table = %{$time_odd_spans};
		foreach my $unit ( keys %{$time_units} ) {
			my $length = $time_units->{$unit};
			$time_span_table{$unit} = [ $length, '1 ' . ucfirst($unit) ];
			foreach my $count ( keys %{$gb::numerics} ) {
				next if $count == 1;
				$time_span_table{ $gb::numerics->{$count} . $unit } = [ $count * $length, $count . ' ' . ucfirst($unit) . 's' ];
			}
		}
	}
	return \%time_span_table;
}

sub time_span_length() {
	my $span = shift;
	my $spans = &time_spans();
	return $spans->{$span}->[0] if $spans->{$span};
	# the table spells out the counts the number words run to (forty); beyond
	# that a span is worked out from the number in its name, so 57day and
	# 57last resolve without needing a word of their own
	foreach my $unit ( sort { length($b) <=> length($a) } keys %{$time_units} ) {
		next unless $span =~ /^([0-9]+)$unit$/;
		return $1 * $time_units->{$unit};
	}
	return undef;
}

sub time_span() {
	my ($span, $timestamp, $multiplier) = @_;
	my $length = &time_span_length($span) or die "unknown time span: $span";
	return $timestamp - $length * ($multiplier || 1);
}

# The rows a page of periods walks: the periods around now first (the nexts,
# this one, the lasts), then the block of periods before or after it, so
# scrolling a graph sideways carries on along the timeline.  A row that names
# periods ahead counts from the request forward, so the part of this period
# already spent belongs to "this" and never shows in a row past it.
sub time_scope_page() {
	my $data = shift;
	my $count = $data->{'count'} || 30;
	my $page = $data->{'page'} || 0;
	return ( ( map { $_ . 'next' } reverse( 2 .. $count ) ), 'next', 'this', 'last', ( map { $_ . 'last' } 2 .. $count ) ) unless $page;
	return ( map { $_ . 'last' } ( $page * $count + 1 .. ( $page + 1 ) * $count ) ) if $page > 0;
	my $ahead = -$page;
	return ( map { $_ . 'next' } reverse( $ahead * $count + 1 .. ( $ahead + 1 ) * $count ) );
}

sub time_span_list() {
	return sort { &time_spans()->{$a}->[0] <=> &time_spans()->{$b}->[0] || $a cmp $b } keys %{&time_spans()};
}

# What a picker shows: the whole family is still readable by time_span(), but
# scrolling three hundred of them is not a picker, so this is the handful per
# unit that gets reached for, in size order.  Add or drop names here freely.
our $time_picker_spans = [ qw(
	second 15second 30second 45second
	minute fiveminute tenminute fifteenminute thirtyminute fortyfiveminute
	hour twohour threehour sixhour ninehour twelvehour fifteenhour eighteenhour twentyonehour twentyfourhour
	day twoday threeday fourday fiveday sixday sevenday
	week twoweek threeweek fourweek
	moon month twomonth threemonth sixmonth ninemonth twelvemonth
	season quarter
	year twoyear fiveyear tenyear
	decade century millenium era
) ];

sub time_span_picker() {
	my $spans = &time_spans();
	foreach my $span ( @{$time_picker_spans} ) {
		die "unknown time span in the picker: $span" unless $spans->{$span};
	}
	return sort { $spans->{$a}->[0] <=> $spans->{$b}->[0] || $a cmp $b } @{$time_picker_spans};
}

sub time_span_label() {
	my $span = shift;
	my $found = &time_spans()->{$span};
	return $found ? $found->[1] : undef;
}

# A warranty that never expires, in the epoch milliseconds every warranty here
# is compared in. Year 3000 is a constant on purpose: no expiry check or sweep
# will ever reach it, and two machines comparing the same ticket agree. The app
# tickets carry it, so the desktop and mobile apps never ask for a login again.
sub forever_warranty {
	return 32503680000000;    # 3000-01-01T00:00:00Z in ms
}

# The age a phrase names, if it names one: "when I'm 60", "when I am 60", "60yo",
# "60 years old", "my 35th birthday". The caller matches the lowercased phrase
# with its apostrophes already dropped, so "I'm" reads as "im".
sub age_phrase_target {
	my ($t) = @_;
	return $1 if $t =~ /\bwhen\s+i\s+(?:am|turn)\s+(\d{1,3})\b/;
	return $1 if $t =~ /\bwhen\s+im\s+(\d{1,3})\b/;
	return $1 if $t =~ /\b(\d{1,3})\s*yo\b/;
	return $1 if $t =~ /\b(\d{1,3})\s*years?\s*old\b/;
	return $1 if $t =~ /\bmy\s+(\d{1,3})(?:st|nd|rd|th)?\s+birthday\b/;
	return undef;
}

# The moment the person is a given age: the present time of day, in the year they
# reach it ("today, but when I'm 60"). Reads the birthday the way every other
# date is read, so a written birthday works. undef when none is set or the sum
# will not make a date, so the caller falls through.
sub birthday_moment_for_age {
	my ($target, $now) = @_;
	return undef unless $config->{'birthday'};
	my $born = &resolve_when($config->{'birthday'}, $now);
	return undef unless defined $born;
	my @n = localtime($now / 1000);
	my @b = localtime($born / 1000);
	my $age = ($n[5] + 1900) - ($b[5] + 1900);
	$age-- if $n[4] < $b[4] || ($n[4] == $b[4] && $n[3] < $b[3]);
	my $year = $n[5] + 1900 + ($target - $age);
	my $epoch = eval { int(POSIX::mktime($n[0], $n[1], $n[2], $n[3], $n[4], $year - 1900)) };
	return undef unless defined $epoch;
	return $epoch * 1000;
}

# Read a typed time the way a person writes one. A relative offset ("-3h", "in 2
# days", "3d 4h") belongs to ago_calc's own arithmetic and is left to it; a
# calendar date is read here, so a bare "jul 16", an ordinal "16th 2", a "last
# dec 25" and a full "dec 25 2025 at 7:04pm" all land where they say. A date with
# no time of day keeps the present time of day; a date with no year is this year,
# and a leading "last"/"next" moves it by one. A bare ordinal day with no month
# rolls to the next month once it is already behind. Returns undef when the text
# is not a calendar date, so ago_calc keeps its old path untouched.
sub resolve_when {
	my ($text,$now) = @_;
	$now = &rightNow() unless $now;
	$resolve_when_residual = '';
	my $t = lc($text // '');
	$t =~ s/['\x{2019}]//g;       # "when I'm 60" reads as "when im 60", "new year's" as "new years"
	$t =~ s/[.,]/ /g;             # "Jan.", "dec 25, 2025"
	$t =~ s/\s+/ /g;
	$t =~ s/^\s+|\s+$//g;
	return undef unless length $t;
	return $now + 0 if $t eq 'now';
	# the day-words, whole days from the present at the same time of day, read
	# here so ago_calc's string surgery (which mangles "yesterday") is not used
	my %day_word = (today => 0, tonight => 0, tomorrow => 1, tom => 1, yesterday => -1, yes => -1);
	return $now + $day_word{$t} * 86400000 if defined $day_word{$t};
	# a leading modifier moves the whole date a year: "last dec 25", "next jul 16";
	# "this christmas" pins it to this year
	my $year_shift = 0;
	if ($t =~ s/^last\s+//) { $year_shift = -1; }
	elsif ($t =~ s/^next\s+//) { $year_shift = 1; }
	elsif ($t =~ s/^this\s+//) { $year_shift = 0; }
	$t =~ s/^\s+|\s+$//g;
	return undef unless length $t;

	# a named holiday, at this year's date, moved by the modifier above: "this
	# christmas" is December 25 of this year, "next christmas" next year's. Read
	# here, before the offset words below, or "new year" would be taken for an
	# amount of time. Only the fixed dates - a movable feast (Thanksgiving, Easter)
	# is left to the guide, which counts the days.
	my %holiday = (
		christmas => [12,25], xmas => [12,25],
		'new year' => [1,1], 'new years' => [1,1], 'new years day' => [1,1],
		'new years eve' => [12,31],
		halloween => [10,31],
		'valentines day' => [2,14], valentines => [2,14],
		'independence day' => [7,4],
	);
	if (my $h = $holiday{$t}) {
		my @n = localtime($now / 1000);
		my $yr = $n[5] + 1900 + $year_shift;
		my $e = eval { int(POSIX::mktime($n[0], $n[1], $n[2], $h->[1], $h->[0] - 1, $yr - 1900)) };
		return $e * 1000 if defined $e;
	}

	# an age, read against the person's birthday: the present time of day in the
	# year they reach that age ("today, but when I'm 60")
	if (my $age_target = &age_phrase_target($t)) {
		my $aged = &birthday_moment_for_age($age_target, $now);
		return $aged if defined $aged;
	}
	# any other "birthday" phrase names an age or a person, not a day of the month:
	# "<name>'s 35th birthday" would otherwise read as "the 35th" and overflow into
	# the next month. Leave it to the guide, which looks the person up.
	return undef if $t =~ /\bbirthday\b/;
	# a spelled-out or joined offset ("2 hours", "3d 4h") is arithmetic, not a date
	return undef if $t =~ /\b(?:milliseconds?|seconds?|minutes?|hours?|days?|weeks?|months?|years?|decades?|centur(?:y|ies))\b/;

	# a year written in words: "44 bc" is the year -44, the negative year the app
	# shows B.C. as; "ad"/"ce" leaves the year as written
	my $bc = 0;
	if ($t =~ s/\b(\d{1,4})\s*(?:bc|bce)\b//i) { $bc = $1 + 0; }
	else { $t =~ s/\b(\d{1,4})\s*(?:ad|ce)\b//i; }
	$t =~ s/^\s+|\s+$//g;

	my %month = (
		january=>1, february=>2, march=>3, april=>4, may=>5, june=>6, july=>7,
		august=>8, september=>9, october=>10, november=>11, december=>12,
		sept=>9, jan=>1, feb=>2, mar=>3, apr=>4, jun=>6, jul=>7,
		aug=>8, sep=>9, oct=>10, nov=>11, dec=>12
	);
	my @now = localtime($now / 1000);

	# the time of day, when one is written
	my ($hour, $min, $sec) = ($now[2], $now[1], $now[0]);
	my $has_time = 0;
	my $scan = $t;
	if ($scan =~ /\b(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?\b/) {
		($hour, $min, $sec) = ($1 + 0, $2 + 0, ($3 // 0) + 0);
		my $ap = $4;
		$hour += 12 if defined $ap && $ap eq 'pm' && $hour < 12;
		$hour = 0   if defined $ap && $ap eq 'am' && $hour == 12;
		$has_time = 1;
	}
	elsif ($scan =~ /\b(\d{1,2})\s*(am|pm)\b/) {
		($hour, $min, $sec) = ($1 + 0, 0, 0);
		$hour += 12 if $2 eq 'pm' && $hour < 12;
		$hour = 0   if $2 eq 'am' && $hour == 12;
		$has_time = 1;
	}
	# drop the time so the day and the year are not read out of it
	$scan =~ s/\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm)?\b/ /g;
	$scan =~ s/\b\d{1,2}\s*(?:am|pm)\b/ /g;

	my ($mon, $day, $year);
	my $date_like = 0;
	my $year_given = 0;
	if ($scan =~ /(?:^|[^\d-])(-?\d{1,4})-(\d{1,2})-(\d{1,2})(?![\d-])/) {
		($year, $mon, $day) = ($1 + 0, $2 + 0, $3 + 0);
		$date_like = $year_given = 1;
	}
	elsif ($scan =~ /\b(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?\b/) {
		($mon, $day) = ($1 + 0, $2 + 0);
		$date_like = 1;
		if (defined $3) { $year = $3 < 100 ? ($3 < 69 ? 2000 + $3 : 1900 + $3) : $3 + 0; $year_given = 1; }
	}
	elsif ($bc) { $year = -$bc; $date_like = $year_given = 1; }
	# any four-figure year, including "0001" and the hundreds ("first christmas"
	# is year 1); a lone four-figure number is read as a year
	if (!$date_like && $scan =~ /\b(\d{4})\b/) { $year = $1 + 0; $date_like = $year_given = 1; }
	if (!$mon && $scan =~ /\b(january|february|march|april|may|june|july|august|september|october|november|december|sept|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)\b/) {
		$mon = $month{$1};
		$date_like = 1;
	}
	my $month_named = $mon ? 1 : 0;
	my $ordinal = 0;
	if ($scan =~ /\b(\d{1,2})(?:st|nd|rd|th)\b/ && $1 >= 1 && $1 <= 31) { $day = $1 + 0; $date_like = 1; $ordinal = 1; }
	return undef unless $date_like;

	# what is left once the month, year and any date form are removed: the day, if
	# a month was named but no ordinal, and then a lone small number is the hour
	my $residual = ' ' . $scan . ' ';
	$residual =~ s/\b(?:january|february|march|april|may|june|july|august|september|october|november|december|sept|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)\b/ /g;
	$residual =~ s{-?\d{1,4}-\d{1,2}-\d{1,2}}{ }g;
	$residual =~ s{\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b}{ }g;
	if (defined $year) { $residual =~ s/\b\Q$year\E\b/ /g; }
	if (defined $day) {
		$residual =~ s/\b0*\Q$day\E(?:st|nd|rd|th)?\b/ /g;
	}
	elsif ($residual =~ /\b(\d{1,2})\b/) {
		$day = $1 + 0;
		$residual =~ s/\b0*\Q$day\E\b/ /g;
	}
	# a lone small number left over is the hour ("16th 2"); a two-figure number
	# too big for an hour is a short year ("oct 12 96" is October 12 1996)
	if ($residual =~ /\b(\d{1,2})\b/) {
		my $n = $1 + 0;
		if (!$has_time && $n <= 24) {
			$hour = $n; $min = 0; $sec = 0; $has_time = 1;
		}
		elsif (!defined $year && $n >= 25) {
			$year = $n < 69 ? 2000 + $n : 1900 + $n;
			$year_given = 1;
		}
	}
	$resolve_when_residual = $residual;

	$year = $now[5] + 1900 unless defined $year;
	$year += $year_shift;
	$mon = $now[4] + 1 unless defined $mon;
	$day = $now[3] unless defined $day;
	my $epoch = eval { int(POSIX::mktime($sec, $min, $hour, $day, $mon - 1, $year - 1900)) };
	return undef unless defined $epoch;
	my $ms = $epoch * 1000;
	# a bare ordinal day ("16th 2") with no month or year rolls to the next month
	# once the moment it names is behind
	if ($ordinal && !$month_named && !$year_given) {
		for (my $i = 0; $i < 24 && $ms < $now; $i++) {
			$mon++;
			if ($mon > 12) { $mon = 1; $year++; }
			my $e = eval { int(POSIX::mktime($sec, $min, $hour, $day, $mon - 1, $year - 1900)) };
			last unless defined $e;
			$ms = $e * 1000;
		}
	}
	return $ms;
}

# Whether the last resolve_when read only a date, or left words it could not read.
# "dec 25 at 7pm" leaves only connective words, but "sept 11 attacks" leaves a
# name - which the guide should read instead of the bare date (so the phrase means
# the 2001 attacks, not this year's September 11).
sub date_leftover {
	my ($r) = @_;
	$r = lc($r // '');
	$r =~ s/\b(?:at|on|in|of|the|a|an|and|am|pm|o|clock|oclock)\b/ /g;
	return $r =~ /[a-z]/ ? 1 : 0;
}

# A local time as an unambiguous ISO string, its year signed so B.C. reads as a
# negative year ("-0044-03-15 00:00:00"). resolve_when reads this back exactly,
# which is what the walkman's jump buttons hand the time machine.
sub iso_local {
	my ($ms) = @_;
	return '' unless defined $ms;
	# the same idiom every other printer uses, so this agrees with the screens;
	# strftime %Y already writes a negative year as "-44" and year 1 as "1", and
	# resolve_when reads both back
	my $t = localtime($ms / 1000);
	return '' unless ref $t;
	return $t->strftime('%Y-%m-%d %H:%M:%S');
}

# The birthdays the person keeps (Configure -> App -> Birthdays), one to a line as
# "Name = date" ("Abraham Lincoln = February 12 1809"). Read across devices - the
# newest value wins - so a save on any machine is seen everywhere.
sub saved_birthdays() {
	my $row = &db_query('select value from settings where app = ? and setting = ? order by server_time desc limit 1', 'me', 'birthdays')->hashes->[0];
	my %bday;
	foreach my $line ( split /\n/, ($row->{'value'} // '') ) {
		next unless $line =~ /\S/;
		my ($name, $when) = split /\s*=\s*/, $line, 2;
		if (!defined $when) { ($name, $when) = split /\s*:\s*/, $line, 2; }
		next unless defined $when && $when =~ /\S/ && $name =~ /\S/;
		$name = lc $name;
		$name =~ s/['\x{2019}]//g;
		$name =~ s/\s+/ /g; $name =~ s/^\s+|\s+$//g;
		$bday{$name} = $when;
	}
	return \%bday;
}

# The saved birthday for a named person, in ms, or undef. A thing named for the
# person (its app) carries its own Birthday setting, and that is read first; then
# the list; failing both, a name whose words all sit inside the other's, so
# "Lincoln" finds "Abraham Lincoln".
sub saved_birthday_ms() {
	my ($name, $now) = @_;
	return undef unless defined $name && $name =~ /\S/;
	$now = &rightNow() unless $now;
	my $own = &setting_grabber({ app => &unformat_name($name), setting => 'birthday' });
	return &resolve_when($own, $now) if defined $own && $own =~ /\S/;
	my $clean = lc $name;
	$clean =~ s/['\x{2019}]//g;
	$clean =~ s/\s+/ /g; $clean =~ s/^\s+|\s+$//g;
	my $all = &saved_birthdays();
	my $hit = $all->{$clean};
	unless (defined $hit) {
		my %q = map { $_ => 1 } split ' ', $clean;
		foreach my $k ( sort keys %{$all} ) {
			my %kw = map { $_ => 1 } split ' ', $k;
			my ($all_in, $all_out) = (1, 1);
			$all_in = 0 foreach grep { !$kw{$_} } keys %q;
			$all_out = 0 foreach grep { !$q{$_} } keys %kw;
			if ($all_in || $all_out) { $hit = $all->{$k}; last; }
		}
	}
	return undef unless defined $hit;
	return &resolve_when($hit, $now);
}

# The times of day an app's records cluster around: the busiest hours (a habit can
# fall more than once a day - coffee mid-morning and again mid-afternoon), each
# with the minute that clusters within it. Empty with no records, so a caller
# falls back to a plain clock time.
sub usual_times_for() {
	my ($app) = @_;
	return unless $app;
	my $rows = &db_query('select timestamp from appointments where app = ? order by timestamp desc limit 500', $app)->hashes;
	my (%hour, %min);
	foreach my $r (@{$rows}) {
		next unless defined $r->{'timestamp'} && $r->{'timestamp'} =~ /^-?\d+$/;
		my @t = localtime($r->{'timestamp'} / 1000);
		$hour{$t[2]}++;
		push @{ $min{$t[2]} }, $t[1];
	}
	return unless scalar keys %hour;
	# the peaks: take the busiest hour, drop the hours beside it, and take the next
	# busiest that is left - so a two-a-day habit yields two times. A walk-off peak
	# below a quarter of the top is a tail, not a second habit.
	my $top = (sort { $b <=> $a } values %hour)[0] || 1;
	my (%taken, @peaks);
	foreach my $h ( sort { $hour{$b} <=> $hour{$a} || $a <=> $b } keys %hour ) {
		next if $taken{$h};
		last if $hour{$h} < $top * 0.25;
		last if scalar @peaks >= 5;
		push @peaks, $h;
		my $x = $h - 2;
		$taken{$x++} = 1 for 1 .. 5;
	}
	my @times;
	foreach my $h ( sort { $a <=> $b } @peaks ) {
		my %m;
		$m{$_}++ foreach @{ $min{$h} };
		my ($bm) = sort { $m{$b} <=> $m{$a} || $a <=> $b } keys %m;
		push @times, [ $h + 0, ($bm // 0) + 0 ];
	}
	return @times;
}

# A time of day that is a habit rather than a date ("breakfast", "tea time", "next
# coffee time"): the times the person usually does it, read from that app's own
# records, and a plain hour when there is nothing to read. "next" is the next of
# those times after now (today, else tomorrow); otherwise it is the one nearest
# now, today. undef when the phrase names no such habit.
sub usual_ritual_time() {
	my ($spec, $now) = @_;
	$now = &rightNow() unless $now;
	my $t = lc($spec // '');
	$t =~ s/['\x{2019}]//g;
	$t =~ s/[.,]/ /g; $t =~ s/\s+/ /g; $t =~ s/^\s+|\s+$//g;
	return undef unless length $t;
	my $next = 0;
	if ($t =~ s/^next\s+//) { $next = 1; }
	my %ritual = (
		'breakfast'   => [ 'breakfast', 8, 0 ],
		'brekkie'     => [ 'breakfast', 8, 0 ],
		'lunch'       => [ 'lunch', 12, 0 ],
		'brunch'      => [ 'brunch', 11, 0 ],
		'dinner'      => [ 'dinner', 18, 0 ],
		'supper'      => [ 'dinner', 18, 0 ],
		'tea'         => [ 'tea', 16, 0 ],
		'tea time'    => [ 'tea', 16, 0 ],
		'coffee'      => [ 'coffee', 10, 0 ],
		'coffee time' => [ 'coffee', 10, 0 ],
		'bed'         => [ 'bed', 22, 0 ],
		'bed time'    => [ 'bed', 22, 0 ],
		'bedtime'     => [ 'bed', 22, 0 ],
	);
	my $r = $ritual{$t};
	return undef unless $r;
	my ($app, $hour, $min) = @{$r};
	my @times = &usual_times_for($app);
	@times = ( [ $hour, $min ] ) unless @times;
	my @n = localtime($now / 1000);
	my $today = sub {
		my ($tm) = @_;
		my $e = eval { int(POSIX::mktime(0, $tm->[1], $tm->[0], $n[3], $n[4], $n[5])) };
		return defined $e ? $e * 1000 : undef;
	};
	my $ms;
	if ($next) {
		foreach my $tm ( @times ) {
			my $c = $today->($tm);
			next unless defined $c;
			if ($c > $now) { $ms = $c; last; }
		}
		unless (defined $ms) {
			my $e = eval { int(POSIX::mktime(0, $times[0]->[1], $times[0]->[0], $n[3] + 1, $n[4], $n[5])) };
			$ms = $e * 1000 if defined $e;
		}
	}
	else {
		my $best;
		foreach my $tm ( @times ) {
			my $c = $today->($tm);
			next unless defined $c;
			my $d = abs($c - $now);
			$best = [ $d, $c ] if !$best || $d < $best->[0];
		}
		$ms = $best->[1] if $best;
	}
	return $ms;
}

# The times an app is expected to happen, for the ghost appointments a clock draws
# ahead of now. The record's own habit comes first (the hours its appointments
# cluster around); with too little to read, the app's saved clothesline hours; and
# with none, the hours of its own 'usual' occurrences. Memoized briefly, so the
# viewer's poll does not re-read the history on every tick.
our %ghost_times_memo;
sub ghost_times_for() {
	my ($app) = @_;
	return [] unless defined $app && length $app;
	my $cache = $ghost_times_memo{$app};
	return $cache->{'times'} if $cache && &rightNow() - $cache->{'at'} < 300000;
	my @out = &usual_times_for($app);
	if (!@out) {
		my $cl = eval { return decode_json &setting_grabber({ app => $app, setting => 'clothesline' }) } || {};
		foreach my $h ( @{ $cl->{'time_plinko'}->{'hour'} || [] } ) {
			my $hh = &hour_from_words($h);
			push @out, [ $hh, 0 ] if defined $hh;
		}
	}
	if (!@out) {
		my $rows = &db_query(q{select timestamp from appointments where app = ? and type = 'usual' order by timestamp desc limit 200}, $app)->hashes;
		my (%h, %m);
		foreach my $r (@{$rows}) {
			next unless defined $r->{'timestamp'} && $r->{'timestamp'} =~ /^-?\d+$/;
			my @t = localtime($r->{'timestamp'} / 1000);
			$h{$t[2]}++;
			push @{ $m{$t[2]} }, $t[1];
		}
		foreach my $hh ( sort { $a <=> $b } keys %h ) {
			my %mm; $mm{$_}++ foreach @{ $m{$hh} };
			my ($bm) = sort { $mm{$b} <=> $mm{$a} || $a <=> $b } keys %mm;
			push @out, [ $hh + 0, ($bm // 0) + 0 ];
		}
	}
	$ghost_times_memo{$app} = { at => &rightNow(), times => \@out };
	return \@out;
}

# An hour written the clothesline's way ("9am", "10pm", "12am") as a number 0-23.
sub hour_from_words() {
	my ($h) = @_;
	my $s = lc($h // '');
	return undef unless $s =~ /^(\d{1,2})\s*(am|pm)?$/;
	my ($n, $ap) = ($1 + 0, $2);
	if (defined $ap) {
		return 0 if $ap eq 'am' && $n == 12;
		return 12 if $ap eq 'pm' && $n == 12;
		return $n + 12 if $ap eq 'pm';
		return $n;
	}
	return $n <= 23 ? $n : undef;
}

# The span a ghost should wear: the app's own recent average, its duration setting,
# else nothing.
sub usual_duration_for() {
	my ($app) = @_;
	my $rows = &db_query(q{select duration from appointments where app = ? and type = 'stop' order by timestamp desc limit 20}, $app)->hashes;
	my @d = map { (defined $_->{'duration'} && $_->{'duration'} =~ /^-?\d+$/) ? abs($_->{'duration'}) + 0 : () } @{$rows};
	if (@d) {
		my $t = 0; $t += $_ for @d;
		return int($t / scalar @d);
	}
	my $s = &setting_grabber({ app => $app, setting => 'duration' });
	return &time_abbrev_translator($s) if defined $s && $s =~ /\S/;
	return 0;
}

# The real appointments an app has near now, cached briefly, for matching an
# expected time to the occurrence a real one belongs to. Only called for apps that
# have a habit, so the range stays small.
our %ghost_done_memo;
sub ghost_done_times_for() {
	my ($app) = @_;
	my $cache = $ghost_done_memo{$app};
	return $cache->{'reals'} if $cache && &rightNow() - $cache->{'at'} < 60000;
	my $now = &rightNow();
	my $rows = &db_query('select timestamp from appointments where app = ? and cast(timestamp as integer) between ? and ? order by timestamp', $app, $now - 86400000, $now + 8 * 86400000)->hashes;
	my @reals = map { $_->{'timestamp'} + 0 } grep { defined $_->{'timestamp'} && $_->{'timestamp'} =~ /^-?\d+$/ } @{$rows};
	$ghost_done_memo{$app} = { at => $now, reals => \@reals };
	return \@reals;
}

# The ghost rows for one app: its expected times that have not been met and are not
# already scheduled. An expected time is dropped once a real appointment sits
# nearest to it (a started or scheduled occurrence - the coffee that just began
# stops being a ghost until tomorrow's comes round). The next expected time beyond
# the view is kept too, so a clock shows it clamped at the edge rather than
# nothing.
sub ghost_rows_for() {
	my ($app, $now, $view_end) = @_;
	my $times = &ghost_times_for($app);
	return [] unless @{$times};
	my @n = localtime($now / 1000);
	# the expected times from yesterday to a week out, so a real appointment can be
	# matched to the occurrence it belongs to
	my @cand;
	for my $d (-1 .. 7) {
		foreach my $tm ( @{$times} ) {
			my $e = eval { int(POSIX::mktime(0, $tm->[1], $tm->[0], $n[3] + $d, $n[4], $n[5])) };
			push @cand, $e * 1000 if defined $e;
		}
	}
	my %done;
	foreach my $r ( @{ &ghost_done_times_for($app) } ) {
		my ($bi, $bd);
		for my $i (0 .. $#cand) {
			my $d = abs($cand[$i] - $r);
			if (!defined $bd || $d < $bd) { $bd = $d; $bi = $i; }
		}
		$done{$cand[$bi]} = 1 if defined $bi && $bd <= 3 * 3600000;
	}
	my @in;
	my $beyond;
	foreach my $ts (@cand) {
		next unless $ts > $now;
		next if $done{$ts};
		if (defined $view_end && $ts <= $view_end) { push @in, $ts; }
		elsif (!defined $beyond || $ts < $beyond) { $beyond = $ts; }
	}
	@in = sort { $a <=> $b } @in;
	@in = @in[0 .. 5] if @in > 6;
	push @in, $beyond if !@in && defined $beyond;
	my $duration = &usual_duration_for($app);
	return [ map { { ghost => 1, app => $app, type => 'usual', timestamp => $_, duration => $duration, formatted_name => &format_name($app) } } @in ];
}

# Work claims: who is sorting out what, so two agents - or two machines - do not
# take the same job. They live as settings on the 'claims' app, which is NOT one of
# @gb::protected, so the mesh merge carries each claim to every machine; the
# protected __president settings (the agent registry among them) stay local.
sub work_claims() {
	my $rows = &db_query(q{select setting, value from settings where app = 'claims' order by cast(server_time as integer) desc})->hashes;
	my %claims;
	foreach my $r (@{$rows}) {
		next unless ($r->{'setting'} || '') =~ /^claim_(.+)$/;
		my $task = $1;
		next if $claims{$task};   # newest first, so the first row for a task wins
		my $c = eval { decode_json $r->{'value'} } || {};
		next unless ref $c eq 'HASH' && $c->{'by'};
		$claims{$task} = $c;
	}
	return \%claims;
}

sub work_claim() {
	my ($task) = @_;
	return undef unless defined $task && $task =~ /\S/;
	return (&work_claims())->{$task};
}

sub claim_work() {
	my ($task, $note) = @_;
	return undef unless defined $task && $task =~ /\S/;
	my $value = encode_json({ by => &signatorial_designer(), machine => &machine_name(), at => &rightNow(), note => ($note // '') });
	&setting_setter({ app => 'claims', setting => 'claim_' . $task, value => $value });
	return &work_claim($task);
}

# The machine's own name, for a claim a person has to read. The signatorial is the
# mesh identity; this is what to show beside it.
sub machine_name() {
	my $name = &setting_grabber({ app => 'me', setting => 'computer_name' }) || &setting_grabber({ app => 'me', setting => 'my_name' });
	return $name if defined $name && $name =~ /\S/;
	my $h = `hostname`;
	chomp $h;
	return $h;
}

# Released by writing it empty rather than deleting it, so the release rides the
# same mesh merge the claim does.
sub release_work() {
	my ($task) = @_;
	return unless defined $task && $task =~ /\S/;
	&setting_setter({ app => 'claims', setting => 'claim_' . $task, value => '' });
}

sub ago_calc() {
	my ($ago,$timestamp) = @_;
	$timestamp = &rightNow() unless $timestamp;
	# a written calendar date is read whole here; a relative offset ("-3h") and
	# everything else falls through to the arithmetic below, unchanged
	my $resolved = &resolve_when($ago, $timestamp);
	return $resolved if defined $resolved;
	my $server_time = &subs::rightNow();
	my $server_dow = localtime($timestamp / 1000)->[6];
	my $time_dow = localtime($timestamp / 1000)->[6];
	my @days = qw/sun mon tue wed thu fri sat/;
	my @ago = split ' ', $ago;
	my $announced_time;
	my $difference = 0;
	if ($ago =~ /(yo)/) {
		my $birthday = &subs::duration_sayer( ($timestamp / 1000 ) - &ago_calc( $config->{'birthday'},$timestamp) / 1000) || (($timestamp / 1000 ) - (&original_timestamp() / 1000 ) );
		my $birthday_timestamp = &ago_calc( $config->{'birthday'},$timestamp);
		my @years_ago = grep { $_ =~ 'yo' } @ago;
		my $years_ago = $years_ago[0];
		my @birthday = split ' ', $birthday;
		my $bday = $birthday[0];
		if ($bday != $years_ago) {
			my $tims = $years_ago - $bday;
			my $diff = &subs::time_abbrev_translator('1y',$timestamp);
			$timestamp = ($diff * $tims) + $timestamp;
		}
		@ago = grep { $_ !~ 'yo' } @ago;
		$ago = join ' ', @ago;
	}
	if ($ago) {
		if ($ago =~ /(tom)/) {
			$difference = &time_span('day', 0);
			$ago =~ s/$1//gi;
		}
		if ($ago =~ /(yes)/) {
			$difference = -1 * &time_span('day', 0);
			$ago =~ s/$1//gi;
		}

		my $is_dow = 0;
		if ($ago =~ /(mon)/) {
			$difference = (1 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(tue)/) {
			$difference = (2 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(wed)/) {
			$difference = (3 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(thu)/) {
			$difference = (4 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(fri)/) {
			$difference = (5 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(sat)/) {
			$difference = (6 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(sun)/) {
			$difference = (7 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		if ($ago =~ /[:\/APap]/) {
			$timestamp = str2time($ago) * 1000;
			$announced_time = ago(($server_time - $timestamp ) / 1000) if $server_time != $timestamp;
		}
		else {
			my $subtractable = &subs::time_abbrev_translator($ago,$timestamp);
			$timestamp = $timestamp - $subtractable;
			my $time = localtime($timestamp / 1000 )->strftime('%I:%M%P');
			my $date = localtime($timestamp / 1000 )->strftime('%A %B %d %Y');
			my $todays_date = localtime()->strftime('%A %B %d %Y');
			my $todays_time = localtime()->strftime('%I:%M%P');
			$announced_time = $time if $server_time != $timestamp;
			$announced_time = $date . ' at ' . $time if $todays_date ne $date;
		}
		$timestamp = $timestamp - $difference;

	}
	return $timestamp;
}

# The voices say_it can speak with. A friendly name carries the engine and what
# that engine needs; the Speech setting in Configure picks one by name, so the
# list here is the single source of truth for both the taker and the picker.
# The piper models live under voices/ (carried as blobs like the APKs, see
# app_release_sync); espeak voices are the fallback when piper is not staged.
# Only cleanly-permissive voices belong here: LJSpeech is public domain,
# LibriTTS-R and Alba are CC BY 4.0. A model dropped from this list is pruned
# from every device by voice_sync, so a licence problem is fixed everywhere.
sub say_voices() {
	return (
		{ value => 'piper-ljspeech', label => 'LJSpeech - US female', engine => 'piper', model => 'en_US-ljspeech-medium'   },
		{ value => 'piper-libritts', label => 'LibriTTS-R - US',     engine => 'piper', model => 'en_US-libritts_r-medium'  },
		{ value => 'piper-alba',     label => 'Alba - UK female',    engine => 'piper', model => 'en_GB-alba-medium'        },
		# John is public domain (LibriVox), like LJSpeech.
		{ value => 'piper-john',     label => 'John - US male',      engine => 'piper', model => 'en_US-john-medium'        },
		# Jonathan is this house's own fine-tune: the same public-domain John base,
		# trained on Jonathan's recordings (see .shots/voice_train/ and docs).
		{ value => 'piper-jonathan', label => 'Jonathan - US male',  engine => 'piper', model => 'en_US-jonathan-medium'    },
		{ value => 'espeak-us',      label => 'eSpeak - US',         engine => 'espeak', voice => 'en-us'                    },
		{ value => 'espeak-gb',      label => 'eSpeak - UK',         engine => 'espeak', voice => 'en-gb'                    },
		{ value => 'espeak-nyc',     label => 'eSpeak - NYC',        engine => 'espeak', voice => 'gmw/en-US-nyc'            },
	);
}

sub say_default_voice() { return 'piper-ljspeech'; }

sub say_voice_spec() {
	my $pick = shift;
	foreach my $v ( &subs::say_voices() ) {
		return $v if $v->{'value'} eq $pick;
	}
	return undef;
}

# Where the piper binary is on this device. It is arch-specific, so the voice
# sync never carries it - only the models (which are arch-independent). The
# dependency step's copy wins, then a piper on PATH; the repo's own bundle is the
# desktop last resort (on the phone it is the wrong architecture).
sub say_piper_binary() {
	# installed by the dependency step (scripts/jawnos_deps.pl --extras); a glibc
	# build, which on Android is run through glibc-runner (see say_piper_argv)
	my $installed = &subs::home('~/.local/share/jawnos/piper/piper');
	return $installed if -x $installed;
	# a piper on PATH (a distribution package, or a Termux install)
	my $onpath = `command -v piper 2>/dev/null`;
	chomp $onpath;
	return $onpath if $onpath && -x $onpath;
	# the copy staged in the repo's blob store (fine on a desktop)
	return '' if $device eq 'mobile';
	my $bundled = &subs::home('~/jawnos/voices/piper/piper');
	return $bundled if -x $bundled;
	return '';
}

# The command that runs piper here, engine only (say_it appends the model and
# output args). A glibc-built bundle needs the glibc launcher on Android; a
# Termux build runs directly.
sub say_piper_argv() {
	my $piper = &subs::say_piper_binary();
	return () unless $piper;
	if ($device eq 'mobile' && $piper eq &subs::home('~/.local/share/jawnos/piper/piper')) {
		my $runner = `command -v glibc-runner 2>/dev/null`;
		chomp $runner;
		return ($runner, $piper) if $runner && -x $runner;
	}
	return ($piper);
}

# How to play a finished wav here. Android has no sox audio backend, so its
# clips go through termux-media-player; everywhere else, the sox player.
sub say_player_command() {
	return 'termux-media-player play' if $device eq 'mobile';
	return 'play -q';
}

our $say_quiet;

# The piper invocation shared by the local player and the streaming reply:
# (argv, extra args, model path, the model's own sample rate). '' when no piper
# render is possible on this machine.
sub say_piper_parts() {
	my ($pick_hint) = @_;
	my $pick = $pick_hint || &subs::misc_setting('say_voice') || &subs::say_default_voice();
	my $spec = &subs::say_voice_spec($pick) || &subs::say_voice_spec(&subs::say_default_voice());
	return () unless $spec && (($spec->{'engine'} || '') eq 'piper');
	my @argv = &subs::say_piper_argv();
	my $model = &subs::home('~/jawnos/voices') . '/' . $spec->{'model'} . '.onnx';
	return () unless scalar @argv && -e $model;
	# a bundle carries its own espeak-ng data; point piper at it (the glibc
	# launcher, unlike a native run, does not find it on its own)
	my $piper_bin = $argv[-1] || '';
	(my $piper_dir = $piper_bin) =~ s{/[^/]+$}{};
	my @espeak = ($piper_dir && -d "$piper_dir/espeak-ng-data") ? ('--espeak_data', "$piper_dir/espeak-ng-data") : ();
	# the model's own rate: piper writes raw PCM at it, and ffmpeg needs to know
	my $rate = 22050;
	if (open(my $jf, '<', $model . '.json')) {
		local $/;
		my $cfg = eval { decode_json(<$jf> // '') };
		close $jf;
		$rate = $cfg->{'audio'}->{'sample_rate'} if $cfg && $cfg->{'audio'}->{'sample_rate'};
	}
	return (\@argv, \@espeak, $model, $rate);
}

# Shell-quote one command of a pipeline ("arg with space" -> 'arg with space'),
# so the paths the voice settings name survive the sh -c that runs piper | ffmpeg.
sub pipeline_quote {
	return join ' ', map {
		my $a = defined $_ ? $_ : '';
		$a =~ s/'/'\\''/g;
		"'" . $a . "'";
	} @_;
}

# Piper render to a file (the local player's path). Returns the path of a fresh
# WAV, or '' when no piper render is possible. The caller owns (and unlinks) it.
sub say_render_wav() {
	my ($text, $pick_hint) = @_;
	return '' unless defined $text && length $text;
	my ($argv, $espeak, $model) = &subs::say_piper_parts($pick_hint);
	return '' unless $argv && $model;
	my $tmp_dir = $gb::tmp_dir || '/tmp';
	my $wav = $tmp_dir . '/jawn_say_' . &subs::random_string_creator(10) . '.wav';
	my $made = 0;
	# the words go to piper on stdin, so nothing has to be quoted for a shell.
	# no -q: the flag exists in the 1.2.0 build but not in the newer CLI, and
	# an unknown flag is a hard argparse error there.
	if (my $pid = open(my $piper_in, '|-', @{$argv}, @{$espeak}, '-m', $model, '-f', $wav)) {
		print {$piper_in} $text;
		close $piper_in;
		$made = 1 if -s $wav;
	}
	unlink $wav if -e $wav && !$made;
	return $made ? $wav : '';
}

sub say_it() {
	my $text = shift;
	my $voice_override = shift;
	return unless defined $text && length $text;
	# the error watch's propose runs are headless: a stand-down notice must not
	# speak (or block on audio) inside a background fork
	return if $say_quiet;
  &subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		my $pick = $voice_override || &subs::misc_setting('say_voice') || &subs::say_default_voice();
		my $spec = &subs::say_voice_spec($pick) || &subs::say_voice_spec(&subs::say_default_voice());
		# Piper first, on every device, so the voice is uniform wherever it can
		# run: the models are shared (voice_sync), only the binary is per-device.
		if (($spec->{'engine'} || '') eq 'piper') {
			my $wav = &subs::say_render_wav($text, $pick);
			if ($wav) {
				my $player = &subs::say_player_command();
				# a headless server has no sink; a failed play is not our problem
				`$player "$wav" 2>/dev/null`;
				unlink $wav;
				return;
			}
		}
		# Fallbacks: Android's own engine where piper cannot run; espeak elsewhere.
		if ($device eq 'mobile') {
			`termux-tts-speak "$text"`;
			return;
		}
		# espeak: the chosen espeak voice, or the fallback when piper is missing.
		# Its own quotes are escaped so the words cannot break out of the shell.
		my $safe = $text;
		$safe =~ s/"/\\"/g;
		my $voice = $spec->{'voice'} || 'en-us';
		`espeak -a70 -v $voice "$safe" 2>/dev/null`;
	}, { name => 'say it' });
}

# Is the device on WiFi and reachable? Its own web server on port 3000 is the
# test: an off-LAN or powered-down device fails the connect at once, which is
# what lets the reply go to Bluetooth without waiting for a timeout. Returns
# the address the reply route is served from, or undef.
sub device_wifi_reply() {
	my ($meta) = @_;
	return undef unless $meta && $meta->{'chip_id'};
	my $edt = $meta->{'edt'} || 'watch';
	my $dev = &subs::device_lister(&subs::rightNow(), $edt, undef, $meta->{'chip_id'});
	my $dev_ip = $dev->{'ip'};
	return undef unless $dev_ip && $dev_ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	require IO::Socket::INET;
	my $sock = IO::Socket::INET->new(PeerAddr => $dev_ip, PeerPort => 3000, Proto => 'tcp', Timeout => 0.7);
	return undef unless $sock;
	close $sock;
	# the server's own address on the device's subnet: a fallback machine may
	# differ from the homebase the device still has stored
	my $addrs = &subs::network_interface_reporter();
	my $net = $dev_ip;
	$net =~ s/\.\d+$//;
	my $server_ip;
	foreach my $nic ( keys %{$addrs} ) {
		my $ip = $addrs->{$nic}->{'ip'};
		next unless $ip;
		my $n = $ip;
		$n =~ s/\.\d+$//;
		if ($n eq $net) { $server_ip = $ip; last; }
	}
	if (!$server_ip && %{$addrs}) {
		my ($first) = values %{$addrs};
		$server_ip = $first->{'ip'};
	}
	return undef unless $server_ip;
	my $od = eval { decode_json(&subs::embedded_operator_door($edt, $meta->{'chip_id'})) } || {};
	my $auth = $od->{'__specs'}->{'authorization'};
	return undef unless $auth;
	return {
		ip => $dev_ip,
		edt => $edt,
		auth => $auth,
		base => 'https://' . $server_ip . ':' . ($ENV{'PORT_ARM'} || ''),
	};
}

# Render the answer once as a WAV, so a WiFi device can fetch it in one
# streamed GET instead of receiving hundreds of BLE notifications. Returns the
# id (the file is ~/.president/reply_<id>.wav) or undef when piper/ffmpeg
# cannot produce one; the caller then keeps the BLE stream.
sub device_reply_wav() {
	my ($text) = @_;
	my ($argv, $espeak, $model, $rate) = &subs::say_piper_parts();
	return undef unless $argv && $model;
	require IPC::Open3;
	require Symbol;
	my $dir = &subs::home('~/.president');
	foreach my $old ( glob("$dir/reply_*.wav") ) {
		unlink $old if $old && time - (stat($old))[9] > 600;
	}
	my $id = &subs::random_string_creator(32);
	$id =~ s/[^A-Za-z0-9]//g;
	$id = substr($id, 0, 24);
	return undef unless length $id >= 16;
	my $path = "$dir/reply_$id.wav";
	my @piper = (@{$argv}, @{$espeak}, '--output_raw', '-m', $model);
	my $pipeline = join(' | ', &subs::pipeline_quote(@piper),
		"ffmpeg -loglevel error -f s16le -ar $rate -ac 1 -i - -ar 8000 -ac 1 -f wav -");
	my $err = Symbol::gensym();
	my ($pin, $pout);
	my $pid = eval { IPC::Open3::open3($pin, $pout, $err, 'sh', '-c', $pipeline) };
	return undef unless $pid;
	print {$pin} $text;
	close $pin;
	binmode($pout);
	open(my $out, '>', $path) or return undef;
	binmode($out);
	my $bytes = 0;
	while (1) {
		my $buf = '';
		my $n = read($pout, $buf, 8192);
		last unless defined $n && $n > 0;
		print {$out} $buf;
		$bytes += $n;
	}
	close $pout;
	waitpid($pid, 0);
	close $out;
	if ($bytes < 100) {
		unlink $path;
		return undef;
	}
	return $id;
}

# A spoken answer to a voice command that came from the watch: push the reply
# text (the watch shows it on screen) and the spoken answer (a short piper clip
# the watch plays) over the bridge, so the answer lands on the wrist. No local
# say_it: the machine holding the bridge would double-talk with the watch.
sub watch_reply() {
	my ($meta, $text) = @_;
	return unless $meta && $meta->{'chip_id'} && defined $text && length $text;
	my $edt = $meta->{'edt'} || 'watch';
	&subs::bluetooth_sender({
		intent => 'com.jawn.president.bt.connect',
		chip_id => $meta->{'chip_id'},
		edt => $edt,
		message => { type => 'say', data => { text => $text } }
	});
	# The spoken half is optional: the Embedded panel's Audio replies toggle, on
	# by default, writes audio_replies into the device's operator_door specs.
	my $op = eval { decode_json &subs::embedded_operator_door($edt, $meta->{'chip_id'}) } || {};
	my $want = $op->{'__specs'}->{'audio_replies'};
	return if defined $want && $want eq 'off';
	# A device on WiFi pulls one WAV instead of receiving hundreds of BLE parts;
	# an off-WiFi device gets the BLE stream immediately. The text above is the
	# small, immediate half either way.
	my $wifi = &subs::device_wifi_reply($meta);
	if ($wifi) {
		&subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			my $id = &subs::device_reply_wav($text);
			if ($id) {
				&subs::bluetooth_sender({
					intent => 'com.jawn.president.bt.connect',
					chip_id => $meta->{'chip_id'},
					edt => $edt,
					message => { type => 'say_audio_ready', data => { id => $id, base => $wifi->{'base'} } }
				});
			}
			else {
				# piper/ffmpeg failed: the BLE stream still gets the sound there
				&subs::watch_reply_stream($meta, $text);
			}
		}, { name => 'watch reply wifi' });
		return;
	}
	# Piper synthesizes far faster than the answer is spoken, and the WiFi path
	# runs voice_ingest inline in the request: do all of this off the request. The
	# child re-dials the database itself (bluetooth_sender reads it), so forking
	# here is safe.
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		&subs::watch_reply_stream($meta, $text);
	}, { name => 'watch reply audio' });
}

# Stream the spoken answer to the watch as PCM parts. Piper writes raw samples as
# it makes them; ffmpeg resamples them to 8 kHz mono (16 KB/s, which the BLE link
# carries comfortably) as it goes, so parts leave while the sentence is still
# being synthesized - the watch starts talking back almost at once instead of
# after the whole clip has been rendered and pushed. Each part is its own bridge
# message (all over one connection, see bluetooth_stream_open), so a long answer
# is no longer capped by the 64 KB message limit.
sub watch_reply_stream() {
	my ($meta, $text) = @_;
	my ($argv, $espeak, $model, $rate) = &subs::say_piper_parts();
	return 0 unless $argv && $model;
	require MIME::Base64;
	require IPC::Open3;
	require Symbol;
	# the words go first as their own message; the sound rides this one connection
	my $bt = &subs::bluetooth_stream_open({
		intent => 'com.jawn.president.bt.connect',
		chip_id => $meta->{'chip_id'},
		edt => $meta->{'edt'} || 'watch'
	});
	# A bridge that can carry the words does not always expose the streaming
	# client (the Android bridge falls back to a broadcast send and has no
	# jawn-bt script). Do not throw the sound away there: send the same parts
	# through bluetooth_sender, one message at a time, which is the path the
	# text already takes. Slower, but the deck buffers to the last part anyway.
	unless ($bt) {
		$log->info('voice: no stream client; sending reply audio part by part');
	}
	my $send = sub {
		my ($data) = @_;
		if ($bt) {
			print {$bt} encode_json($data) . "\n";
		}
		else {
			&subs::bluetooth_sender({
				intent => 'com.jawn.president.bt.connect',
				chip_id => $meta->{'chip_id'},
				edt => $meta->{'edt'} || 'watch',
				message => $data
			});
		}
	};
	my @piper = (@{$argv}, @{$espeak}, '--output_raw', '-m', $model);
	# How much audio there will be, near enough: ~14 characters a second of
	# speech, 8 kHz mono s16 is 16000 bytes a second. The watch uses it to decide
	# how much to hold back before speaking (half of it, clamped), so playback
	# starts with a cushion against the link's jitter without a short answer
	# waiting for a cushion longer than itself.
	my $est_total = int((length($text) / 14) * 16000);
	# Resample to 8 kHz when ffmpeg is here (the whisper path uses it, so it is on
	# every machine that can already hear). Otherwise piper's own rate rides along
	# in the messages and the watch opens the codec at it.
	my $pipeline = join(' | ', &subs::pipeline_quote(@piper),
		"ffmpeg -loglevel error -f s16le -ar $rate -ac 1 -i - -ar 8000 -ac 1 -f s16le -");
	my $done = 0;
	for my $attempt ( [ $pipeline, 8000 ], [ &subs::pipeline_quote(@piper), $rate ] ) {
		my ($pipe, $out_rate) = @{$attempt};
		my $err = Symbol::gensym();
		my ($pin, $pout);
		my $pid = eval { IPC::Open3::open3($pin, $pout, $err, 'sh', '-c', $pipe) };
		next unless $pid;
		print {$pin} $text;
		close $pin;
		binmode($pout);
		my ($seq, $sent) = (0, 0);
		while (1) {
			my $chunk = '';
			# 4 KB of PCM per part: the base64 JSON is then ~5.5 KB, which the
			# deck's ~15 KB internal heap can reassemble (16 KB raw parts made a
			# ~22 KB line and were silently dropped by the BLE reassembler).
			my $n = read($pout, $chunk, 4096);
			last unless defined $n && $n > 0;
			my $b64 = MIME::Base64::encode_base64($chunk, '');
			$send->({ type => 'say_audio', data => { seq => $seq, last => 0, rate => $out_rate, total => $est_total, audio => $b64 } });
			$seq++;
			$sent += $n;
		}
		close $pout;
		waitpid($pid, 0);
		if ($sent) {
			$send->({ type => 'say_audio', data => { seq => $seq, last => 1, rate => $out_rate, total => $est_total, audio => '' } });
			$done = 1;
			last;
		}
		# nothing came out (ffmpeg missing, say): try piper alone at its own rate
	}
	close $bt if $bt;
	$log->info('voice: no reply audio rendered for the watch (text only)') unless $done;
	return $done;
}

sub main_icon_maker() {
	my $data = shift;
	my $unformatted_name = $data->{'app'};
	my $timestamp = $data->{'timestamp'};
	my $settings = $data->{'settings'};
	my $size = $data->{'size'} || 'tiny';
	my $onclick;
	if (!$data->{'onclick'}) {
		$onclick = 'onclick="windowRestorer(' . $timestamp . ',\'' . $unformatted_name . '\')"';
	}
	$settings = &subs::settings_grabber({ app => $unformatted_name }) unless $settings;
	my $main_image = '<span id="window_icon_' . $timestamp . '" style="display:none;" class="window_icon ' . $size . '_thumb" app="' . $unformatted_name . '" hint="' . &subs::format_name($unformatted_name) . '" ' . $onclick . '>' . &subs::initialize_name(&subs::format_name($unformatted_name)) . '</span>';
	my ($destination,$asset);
	if ($settings->{'main_image'}) {
		($destination,$asset) = &subs::file_device_renamer({ file => $settings->{'main_image'}, app => $unformatted_name, type => 'image' });
		if (-e ($destination . $asset)) {
			$main_image = '<img id="window_icon_' . $timestamp . '" class="window_icon ' . $size . '_thumb" app="' . $unformatted_name . '" hint="' . &subs::format_name($unformatted_name) . '" src="/file_open?file=' . $destination . $asset . '" class="little_thumb" ' . $onclick . '>';
		}
	}
	unless (-e $destination . $asset) {
		if ($gb::known_appts->{$unformatted_name}) {
			$main_image = '<img id="window_icon_' . $timestamp . '" class="window_icon ' . $size . '_thumb" app="' . $unformatted_name . '" hint="' . &subs::format_name($unformatted_name) . '" src="' . &icon_for($gb::known_appts->{$unformatted_name}->{'icon'}) . '" class="little_thumb" ' . $onclick . '>';
		}
		elsif (-e 'public/icons/pos/' . $settings->{'pos'} . '.png') {
			$main_image = '<img id="window_icon_' . $timestamp . '" class="window_icon ' . $size . '_thumb" app="' . $unformatted_name . '" hint="' . &subs::format_name($unformatted_name) . '" src="' . &icon_for('/icons/pos/' . $settings->{'pos'} . '.png') . '" class="little_thumb" ' . $onclick . '>';
		}
	}
	return $main_image
}

sub device_setter() {
	my $device = 'computer';
	if ($config->{'device'}) {
		$device = $config->{'device'};
	}
	else {
		my $uname = `uname -a`;
		if ($uname =~ /Android/gi) {
			$device = 'mobile';
		}
		elsif ($uname =~ /Debian/gi) {
			$device = 'server';
		}
	}
	return $device;
}

sub restore_list() {
	my $returner = [];
	my @backups;
	# One database, one backup directory: it no longer varies by caller (start_dir
	# is gone from this path), so the install's own backups dir is the list.
	my $directory = &subs::backups_dir() . '/';
	if ($directory && $directory =~ /\/$/) {
		my $backup_ls = `ls -t $directory`;
		@backups = split "\n", $backup_ls;
		foreach my $b (@backups) {
			$b = $directory . $b;
		}
	}

	foreach my $b (@backups) {
		my @stat = stat $b ;
		# one fixed database: the decrypted copy no longer sits beside its backup,
		# so "open" marks the current snapshot (initial.enc), not a sibling .db
		my $archive = $b =~ /_\d+\.enc$/ ? 'archive' : 'current';
		my $status = $archive eq 'current' ? 'open' : 'closed';

		my $size = sprintf('%.2f', ( $stat[7] / 1024 )) . 'kb';
		my $created = localtime($stat[9] )->strftime('%A %B %d %Y - %I:%M:%S%P %Z');
		(my $name = $b) =~ s{.*/}{};
		push @{$returner}, { archive => $archive, status => $status, directory => $directory, filename => $b, name => $name, size => $size, created => $created, blocks => $stat[12] };
	}

	return $returner;
}


sub edt_button_presser() {
	my $data = shift;
	my $remote_address = $data->{'remote_address'};
	my $timestamp = $data->{'timestamp'};
	my $room = $data->{'room'};
	my $watch_settings = $data->{'watch_settings'};
	my $button = $data->{'button'};
	my $edt = $data->{'edt'};
	my $toggler = $data->{'toggle'};
	my $state = $data->{'state'};
	my $chip_id = $data->{'chip_id'};
	my $room_count = $watch_settings->{'__specs'}->{'room_count'};
	my $room_max = $watch_settings->{'__specs'}->{'room_max'};
	my $component = $data->{'component'} || 'button';
	$button = (($room -1 ) * $room_max) + $button unless $edt eq 'microcontroller';
	my $server_time = &subs::rightNow();
	my $measure = $data->{'measure'};
	my $uuid = &subs::random_string_creator(21);
	my ($db,$database) = &subs::database_grabber();
	my $syl_count = 10;
	$syl_count = 1 unless $edt eq 'microcontroller';
	my $b = $watch_settings->{&subs::shorthand_name($component, $syl_count) . $button} || {};
	my $app = $b->{'app'};
	my $movement = $b->{'movement'};
	my $settings = &subs::settings_grabber({ app => $app });
	my $saved_toggle = $settings->{'toggle'};
	my $toggle;
	my $duration = &subs::time_abbrev_translator($settings->{'duration'});

	if (($movement eq 'start' || $movement eq 'record') && ($saved_toggle eq 'on' || $toggler eq 'on' || $saved_toggle == 1)) {
		$movement = 'stop';
		$toggle = 'off';
	}
	my $db_data = {
		app => $app,
		server_time => $server_time,
		timestamp => $timestamp,
		type => $movement,
		toggle => $b->{'toggle'},
		uuid => $uuid,
		duration => $duration,
		warranty => &subs::ago_calc(&subs::setting_grabber({ app => $app, setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $server_time),
		project => $settings->{'t_project'},
		pos => $settings->{'pos'},
		remote_address => $remote_address
	};
	if ($saved_toggle eq 'on') {
		$b->{'toggle'} = 0;
		$toggle = 'off';
	}
	else {
		$b->{'toggle'} = 1;
		$toggle = 'on';
	}

	if ($movement eq 'command' || $movement eq 'kill') {
		if ($settings->{'command'} && $settings->{'kill'}) {

		}
		elsif ($settings->{'command'} && !$settings->{'kill'}) {
			$toggle = $saved_toggle;
			$b->{'toggle'} = $saved_toggle eq 'on' ? 1 : 0;
		}
		# The button can name the machine the command belongs to (a signatorial
		# from the remote machine list); blank means every machine runs its own
		# copy, and an unreachable destination falls back to running here.
		my $destination = $b->{'destination'} || '';
		my $me = &subs::signatorial_designer();
		my $ran_away = 0;
		if (!$destination) {
			&subs::destination_relay({ destination => 'all', app => $app, movement => $movement, timestamp => $server_time });
			$db_data->{'data'} = 'every machine';
		}
		elsif ($destination ne $me) {
			my $to = &subs::destination_relay({ destination => $destination, app => $app, movement => $movement, timestamp => $server_time });
			if ($to) {
				$ran_away = 1;
				$db_data->{'data'} = $to;
			}
		}
		unless ($ran_away) {
			# no destination set, it is this machine, or the destination could
			# not be reached: run here
			my $resulter = &subs::run_command($app,$settings->{$movement});
			$db_data->{'data'} = &subs::runner_label() unless $db_data->{'data'};
		}

	}
	&subs::setting_setter({ app => $app, setting => 'toggle', value => $toggle });
	$db_data->{'seen'} = 'yes';
	my $c = &subs::controller_builder();
	my $returner;
	if ($measure) {

		$c->param('measure', $b->{'measure'});
		$c->param('value', $measure);

		&Manager::appt_measure_writer($c,{ app => $app, measure => $b->{'measure'}, value => $measure, timestamp => $timestamp, remote_address => $remote_address });
		&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.app_measure[measure="' . $b->{'measure'} . '"]\').val(\'' . $measure . '\');' });
		&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.app_measure_display[measure="' . $b->{'measure'} . '"]\').text(\'' . $measure . '\');' });
	}
	else {
		$returner = {
			app => $app,
			numero => $b->{'numero'},
			shorthand_name => &subs::shorthand_name($b->{'shorthand_name'}),
			movement => $b->{'movement'},
			toggle => $b->{'toggle'},
			button => $button,
			colour => $b->{'colour'},
			rgb => $b->{'rgb'},
		};

		my $insert = &Manager::appointment_writer($c,$db_data);
	}
	&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid . '\');' });
	# embeddedAuthorizer hands the settings over with __shutup (the patience
	# half of the authorization pair) deliberately blanked, and this write-back
	# used to store that blanked copy: it destroyed the device's patience with
	# the first accepted request, so every later request failed auth and fell
	# into the wigi queue. Put the stored key back before saving the buttons.
	my $stored = eval { decode_json &subs::embedded_operator_door($edt, $chip_id) } || {};
	$watch_settings->{'__shutup'} = $stored->{'__shutup'} if $stored->{'__shutup'};
	my $od = encode_json $watch_settings;
	&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $od, subsetting => $chip_id });
	return $returner;
}

our ($network_report_memo, $network_report_memo_at);

sub network_interface_reporter() {
	my $c = shift;
	# Reading the interfaces shells out to ifconfig/arp for every NIC (about
	# 100ms). Callers ask several times in one pass - a BLE device walk asks once
	# per chip - and nothing changes second to second, so keep the report for a
	# few seconds. Return a copy: callers add ports and other per-call fields.
	my $now = &rightNow();
	if ($network_report_memo && $now - ($network_report_memo_at || 0) < 5000) {
		return { map { $_ => { %{$network_report_memo->{$_}} } } keys %{$network_report_memo} };
	}
	my $device = &subs::device_setter();
	my $tmp_file = $gb::tmp_dir . '/ifconfig';
	my $ifc = $device eq 'server' ? '/usr/sbin/ifconfig' : 'ifconfig 2>&1 | grep -v "Permission denied"';

	my @ifconfig = split "\n\n", `$ifc`;
	unlink $tmp_file;
	my @ifconfig_link;
	my @ifconfig_inet;
	my $address = {};
	my $count = {};
	my $home_ip;
	foreach my $if (@ifconfig) {
		#print $if . "\n";
		my @ifconfig_list = split "\n", $if;

		@ifconfig_inet = grep { $_ =~ /inet/ } @ifconfig_list;

		my $nic = (split ' ', $ifconfig_list[0])[0];
		$nic =~ s/://;
		$address->{$nic}->{'nic'} = $nic;
		my $gw = '$(ip route show 0.0.0.0/0 dev ' . $address->{$nic}->{'nic'} . ' | cut -d\  -f3)';
		$address->{$nic}->{'gw'} = `echo $gw`;
		chomp $address->{$nic}->{'gw'};
		if ($device eq 'computer' || $device eq 'server') {
			my $gw_mac = '/usr/sbin/arp -a ' . $gw . '  | grep ' . $address->{$nic}->{'nic'};
			$gw_mac = `$gw_mac`;
			$address->{$nic}->{'gw_mac'} = (split ' ', $gw_mac)[3] if $gw && $device eq 'computer';
		}
		foreach my $i (@ifconfig_inet) {
			my @inet = split " ", $i;
			if ($i =~ /inet /) {
				$address->{$nic}->{'ip'} = $inet[1];
				$address->{$nic}->{'port'} = $ENV{PORT_AHOY};
				$address->{$nic}->{'ws_port'} = $ENV{PORT_MSG};
				$address->{$nic}->{'alarm_port'} = $ENV{PORT_BELL};
				# The ports an embedded device dials. They used to be derived from
				# `port` (+2, +3, +4), but a peer's row should carry them so a
				# fallback machine can be named exactly even if the offsets move.
				$address->{$nic}->{'arm_port'} = $ENV{PORT_ARM};
				$address->{$nic}->{'bestow_port'} = $ENV{PORT_BESTOW};
				$address->{$nic}->{'coms_port'} = $ENV{PORT_COMS};
				$address->{$nic}->{'dock_port'} = $ENV{PORT_DOCK};
				$address->{$nic}->{'manager'} = 'https://' . $inet[1] . ':' . $ENV{PORT_DOCK} .  '/manager';
				$address->{$nic}->{'netmask'} = $inet[3];
				$address->{$nic}->{'broadcast'} = $inet[5];
				$address->{$nic}->{'timestamp'} = &subs::rightNow();
			}
		}
	}

	$network_report_memo = $address;
	$network_report_memo_at = $now;
	return $address;
}

sub same_net_test() {
	my ($home_ip,$ip,$localhost_override) = @_;
	my $same_net = 'no';
	my $localhost = '127.0.0.1';
	return $same_net if ($ip eq $localhost || $home_ip eq $localhost) && !$localhost_override;
	if ($ip ne $localhost && $home_ip ne $localhost && $ip ne $localhost_override) {
		my @ip = split /\./, $ip;
		my @home_ip = split /\./, $home_ip;
		my $test = 'no';
		for ( my $i = 0; $i < scalar @home_ip - 1; $i++ ) {
			if ($home_ip[$i] == $ip[$i]) {
				$test = 'yes';
			}
			else { 	$test = 'no'; last; }
		}
		if ($test eq 'yes') { $same_net = 'yes'; }
	}
	return $same_net;
}

# Only a private or link-local network is ours to probe: a public address is not.
sub ip_is_private() {
	my $ip = shift || '';
	return 1 if $ip =~ /^10\./;
	return 1 if $ip =~ /^192\.168\./;
	return 1 if $ip =~ /^169\.254\./;
	return 1 if $ip =~ /^172\.(?:1[6-9]|2\d|3[01])\./;
	return 1 if $ip =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./;  # carrier-grade NAT
	return 0;
}

# Resolve mDNS/DNS-SD services of one type on the local network, as a list of
# records (avahi is the responder this house already has). Parsable output, one
# `=` line per resolved instance:
#   =;iface;proto;name;type;domain;host;address;port;txt
sub mdns_browse() {
	my ($type) = @_;
	return [] unless $type;
	my $avahi = `command -v avahi-browse 2>/dev/null`;
	chomp $avahi;
	$avahi ||= '/usr/bin/avahi-browse' if -x '/usr/bin/avahi-browse';
	return [] unless $avahi;
	my $out = `timeout 8 $avahi -rtp $type 2>/dev/null`;
	my @records;
	foreach my $line (split "\n", $out) {
		next unless $line =~ /^=;/;
		my @f = split /;/, $line, 10;
		my (undef, undef, undef, $name, $stype, undef, $host, $addr, $port, $txt) = @f;
		next unless $addr && $addr =~ /^\d{1,3}(\.\d{1,3}){3}$/;
		my %fields;
		foreach my $kv ($txt ? $txt =~ /"([^"]*)"/g : ()) {
			my ($k, $v) = split /=/, $kv, 2;
			$fields{$k} = $v if defined $v;
		}
		my $mac = ($fields{'mac'} && $fields{'mac'} =~ /^[0-9a-fA-F:]{17}$/) ? lc $fields{'mac'} : undef;
		my ($ty) = $txt ? $txt =~ /\bty=([^"]+?)\s*"/ : ();
		my ($pr) = $txt ? $txt =~ /\bproduct=\(([^)]+)\)/ : ();
		push @records, {
			service => $stype,
			hostname => $host,
			ip => $addr,
			port => $port,
			mac => $mac,
			name => $fields{'name'} || $ty || $pr || $name,
			model => $fields{'model'} || $pr || $ty,
			txt => $txt,
			fields => \%fields,
		};
	}
	return \@records;
}

# The printers the local network advertises, keyed by address and by MAC so a
# scanned device can be recognised either way. _ipp._tcp is the Internet
# Printing service every modern printer answers; _pdl-datastream (port 9100) is
# the fallback for one that only speaks raw.
sub mdns_printers() {
	my $records = &mdns_browse('_ipp._tcp');
	$records = &mdns_browse('_pdl-datastream._tcp') unless @{$records};
	my (%by_ip, %by_mac);
	foreach my $r (@{$records}) {
		$by_ip{$r->{'ip'}} ||= $r;
		$by_mac{$r->{'mac'}} ||= $r if $r->{'mac'};
	}
	return { by_ip => \%by_ip, by_mac => \%by_mac };
}

# What a printer says about its own consumables, read over IPP. A printer that
# advertises _ipp._tcp answers Get-Printer-Attributes: marker-levels is the ink or
# toner left in each cartridge, with marker-names, marker-colors (one #rrggbb, or
# several for a tri-colour cartridge) and marker-types labelling each one, and
# printer-state / printer-state-reasons saying whether it needs attention.
# Returns a hashref of the markers and the state, or { error => ... } when nothing
# answers - so a printer that is off leaves its row saying so, not blank.
sub printer_ink_levels() {
	my ($ip) = @_;
	return { error => 'no address' } unless $ip && $ip =~ /^\d{1,3}(\.\d{1,3}){3}$/;
	my $ipptool = `command -v ipptool 2>/dev/null`;
	chomp $ipptool;
	# the manager's PATH is not the login shell's, so try the usual homes too
	for my $p (qw(/usr/bin/ipptool /usr/local/bin/ipptool /bin/ipptool)) {
		$ipptool ||= $p if -x $p;
	}
	return { error => 'ipptool not installed' } unless $ipptool && -x $ipptool;
	# ask only for what an ink readout needs, so a chatty printer's reply stays small
	my $test = <<'IPP';
{
	OPERATION get-printer-attributes
	VERSION 2.0
	GROUP operation
	ATTR charset attributes-charset utf-8
	ATTR language attributes-natural-language en
	ATTR uri printer-uri $uri
	ATTR keyword requested-attributes printer-make-and-model,printer-state,printer-state-reasons,marker-names,marker-colors,marker-types,marker-levels
	STATUS successful-ok
	DISPLAY printer-make-and-model
	DISPLAY printer-state
	DISPLAY printer-state-reasons
	DISPLAY marker-names
	DISPLAY marker-colors
	DISPLAY marker-types
	DISPLAY marker-levels
}
IPP
	require File::Temp;
	my ($fh, $path) = File::Temp::tempfile('jawn_ipp_XXXXXX', SUFFIX => '.test', DIR => File::Spec->tmpdir, UNLINK => 1);
	print $fh $test;
	close $fh;
	# ipp/print is the resource path (_ipp._tcp advertises rp=ipp/print on almost
	# every printer); fall back to ipp/printer for one that names it differently
	my (%attr, $answered);
	foreach my $rp ('ipp/print', 'ipp/printer') {
		my $out = `timeout 6 $ipptool -tv ipp://$ip:631/$rp $path 2>/dev/null`;
		foreach my $line (split "\n", $out) {
			next unless $line =~ /^\s*([a-z0-9-]+)\s*(?:\([^)]*\))?\s*=\s*(.*)$/;
			$attr{$1} = $2;
		}
		$answered = 1 if %attr;
		last if $attr{'marker-levels'} || $attr{'printer-make-and-model'};
	}
	return { error => 'no answer from the printer' } unless $answered;
	# each attribute is a 1setOf, printed comma-separated and parallel across the
	# lists, so index i is the same cartridge in every one
	my @names  = split /\s*,\s*/, ($attr{'marker-names'}  || '');
	my @colors = split /\s*,\s*/, ($attr{'marker-colors'} || '');
	my @types  = split /\s*,\s*/, ($attr{'marker-types'}  || '');
	my @levels = split /\s*,\s*/, ($attr{'marker-levels'} || '');
	my @markers;
	foreach my $i (0 .. $#levels) {
		my $level = $levels[$i];
		next unless defined $level && $level =~ /^-?\d+$/;
		# marker-levels is already a percentage of capacity; a negative value is
		# the printer saying it does not know, so leave the percentage out and let
		# the row show a question mark instead of a wrong number
		my $pct;
		if ($level >= 0) {
			$pct = $level + 0;
			$pct = 100 if $pct > 100;
		}
		push @markers, {
			name    => ($names[$i] || ('marker ' . ($i + 1))),
			type    => $types[$i],
			# marker-colors is #rrggbb (or several, run together, for a
			# tri-colour cartridge): keep each as its own swatch
			colors  => [ map { '#' . $_ } grep { length } split /#/, ($colors[$i] || '') ],
			level   => $level + 0,
			percent => $pct,
		};
	}
	my @reasons = grep { $_ ne 'none' } split /\s*,\s*/, ($attr{'printer-state-reasons'} || '');
	return {
		ip      => $ip,
		make    => $attr{'printer-make-and-model'},
		state   => $attr{'printer-state'},
		reasons => \@reasons,
		markers => \@markers,
	};
}

# The JawnOS devices the local network advertises on _jawnos._tcp, keyed by
# address, MAC and chip_id so a scanned device is recognised however it is known.
# The firmware puts purpose/model/caps in the TXT records (see jw/jt/alarmclock).
sub mdns_devices() {
	# What the fleet advertises on _jawnos._tcp: purpose, model, abilities and the
	# radio address. The responder is the ESP-IDF one, back after a spell without it:
	# its log is off in the firmware and the console lock that log path needs is
	# primed at boot, which were the two halves of the panic it used to cause.
	my $records = &mdns_browse('_jawnos._tcp');
	my (%by_ip, %by_mac, %by_chip);
	foreach my $r (@{$records}) {
		my $f = $r->{'fields'} || {};
		my $dev = {
			ip => $r->{'ip'},
			port => $f->{'port'} || $r->{'port'},
			chip_id => $f->{'chip_id'},
			name => $f->{'name'} || $r->{'name'},
			purpose => $f->{'purpose'},
			model => $f->{'model'} || $r->{'model'},
			mac => ($f->{'mac'} && $f->{'mac'} =~ /^[0-9a-fA-F:]{17}$/) ? lc $f->{'mac'} : $r->{'mac'},
			capabilities => $f->{'caps'},
			hostname => $r->{'hostname'},
		};
		$by_ip{$dev->{'ip'}} ||= $dev;
		$by_mac{$dev->{'mac'}} ||= $dev if $dev->{'mac'};
		$by_chip{$dev->{'chip_id'}} ||= $dev if $dev->{'chip_id'};
	}
	return { by_ip => \%by_ip, by_mac => \%by_mac, by_chip => \%by_chip };
}

# Fold what mDNS knows into an address map in place: name the JawnOS devices and
# the printers on each network, and add any the neighbour read missed, so a
# device answers what it is the moment it appears. Returns 1 if anything changed.
sub mdns_merge_address() {
	my ($address) = @_;
	return 0 unless ref $address eq 'HASH';
	my $devices = &mdns_devices();
	my $printers = &mdns_printers();
	# never list this machine among the devices it found
	my %self_ip = map { $_->{'ip'} => 1 } grep { $_->{'ip'} } values %{$address};
	my $changed = 0;
	foreach my $nic (keys %{$address}) {
		my $nic_ip = $address->{$nic}->{'ip'};
		next unless $nic_ip && $nic_ip !~ /^127\./;
		$address->{$nic}->{'neigh'} ||= [];
		my $neigh = $address->{$nic}->{'neigh'};
		foreach my $n (@{$neigh}) {
			my $d = $devices->{'by_ip'}->{$n->{'ip'}}
				|| ($n->{'mac'} ? $devices->{'by_mac'}->{$n->{'mac'}} : undef)
				|| ($n->{'chip_id'} ? $devices->{'by_chip'}->{$n->{'chip_id'}} : undef);
			my $p = $d ? undef : ($printers->{'by_ip'}->{$n->{'ip'}} || ($n->{'mac'} ? $printers->{'by_mac'}->{$n->{'mac'}} : undef));
			my $src = $d || $p;
			next unless $src;
			if (!$n->{'purpose'} || $n->{'purpose'} eq 'hmmm') {
				my $want = $d ? $src->{'purpose'} : 'printer';
				if ($want) { $n->{'purpose'} = $want; $changed = 1; }
			}
			foreach my $f (qw/name model chip_id capabilities/) {
				next unless $src->{$f} && !$n->{$f};
				$n->{$f} = $src->{$f}; $changed = 1;
			}
			if ($src->{'mac'} && (!$n->{'mac'} || $n->{'mac'} !~ /^[0-9a-f:]{17}$/i)) {
				$n->{'mac'} = $src->{'mac'}; $changed = 1;
			}
			if ($d && $d->{'port'} && !$n->{'PORT_DOCK'}) { $n->{'PORT_DOCK'} = $d->{'port'}; $changed = 1; }
			# a device that named its radio in the TXT: keep the Bluetooth address
			# where the bridge looks for it (bluetooth_sender reads this field)
			if ($d && $d->{'mac'}) {
				my $ma = $n->{'mac_addresses'};
				$ma = eval { decode_json $ma } if $ma && !ref $ma;
				$ma = {} unless ref $ma eq 'HASH';
				if (!$ma->{'bluetooth'}) { $ma->{'bluetooth'} = uc $d->{'mac'}; $n->{'mac_addresses'} = $ma; $changed = 1; }
			}
		}
		foreach my $d (values %{$devices->{'by_ip'}}) {
			next if $self_ip{$d->{'ip'}};
			next unless &same_net_test($d->{'ip'}, $nic_ip) eq 'yes';
			next if grep { $_->{'ip'} eq $d->{'ip'} } @{$neigh};
			push @{$neigh}, {
				ip => $d->{'ip'}, mac => $d->{'mac'} || &subs::random_string_creator(10),
				uuid => &subs::random_string_creator(25), purpose => $d->{'purpose'},
				name => $d->{'name'}, model => $d->{'model'}, chip_id => $d->{'chip_id'},
				capabilities => $d->{'capabilities'}, PORT_DOCK => $d->{'port'},
				mac_addresses => ($d->{'mac'} ? { bluetooth => uc $d->{'mac'} } : undef),
			};
			$changed = 1;
		}
		foreach my $p (values %{$printers->{'by_ip'}}) {
			next if $self_ip{$p->{'ip'}};
			next unless &same_net_test($p->{'ip'}, $nic_ip) eq 'yes';
			next if grep { $_->{'ip'} eq $p->{'ip'} } @{$neigh};
			push @{$neigh}, {
				ip => $p->{'ip'}, mac => $p->{'mac'} || &subs::random_string_creator(10),
				uuid => &subs::random_string_creator(25), purpose => 'printer',
				name => $p->{'name'}, model => $p->{'model'},
			};
			$changed = 1;
		}
	}
	return $changed;
}

# The light half of a scan, on a timer: fold what mDNS knows into this machine's
# own device row, so a device plugged in is named within seconds without running
# the whole interface scan. Writes only when something changed.
sub device_mdns_sync() {
	my $hostname = `hostname`;
	chomp $hostname;
	my $row = &subs::db_select('devices', undef, { hostname => $hostname })->hashes->[0];
	return unless $row && $row->{'address'};
	my $address = eval { decode_json $row->{'address'} } || {};
	return unless ref $address eq 'HASH' && %{$address};
	return unless &mdns_merge_address($address);
	my $now = &rightNow();
	&subs::db_update('devices', { address => encode_json $address, timestamp => $now, server_time => $now }, { hostname => $hostname });
}

# An address and its netmask as a CIDR: 192.168.2.3 + 255.255.255.0 ->
# 192.168.2.0/24. Returns undef for anything that is not a plain IPv4 address,
# and reads a hex netmask (0xffffff00) the way some ifconfig builds print it.
sub subnet_cidr() {
	my ($ip, $netmask) = @_;
	return undef unless defined $ip && $ip =~ /^\d{1,3}(\.\d{1,3}){3}$/;
	my $mask = $netmask;
	if (!defined $mask || $mask !~ /^\d{1,3}(\.\d{1,3}){3}$/) {
		if (defined $mask && $mask =~ /^0x([0-9a-fA-F]{1,8})$/) {
			my $h = ('0' x (8 - length $1)) . $1;
			$mask = join '.', map { hex } ($h =~ /(..)(..)(..)(..)/);
		}
		else {
			$mask = '255.255.255.0';
		}
	}
	my @i = map { $_ + 0 } split /\./, $ip;
	my @m = map { $_ + 0 } split /\./, $mask;
	my (@net, $bits);
	$bits = 0;
	for my $k (0..3) {
		push @net, $i[$k] & $m[$k];
		my $o = $m[$k];
		while ($o) { $bits += ($o & 1); $o >>= 1; }
	}
	return join('.', @net) . '/' . $bits;
}

# `ip neigh` is only the ARP cache: a device this machine has never spoken to -
# a printer, a fresh appliance - is simply absent from it until something pings
# the network once. On an explicit scan, sweep the NIC's own subnet so those
# hosts answer and land in the cache the neighbour read then relies on. The
# sweep keeps its own bound so a slow or filtered network cannot stall a scan.
sub subnet_sweep() {
	my ($nic, $ip, $netmask) = @_;
	return if !$ip || $ip !~ /^\d{1,3}(\.\d{1,3}){3}$/;
	return if $ip =~ /^127\./;
	return unless &ip_is_private($ip);
	my $cidr = &subnet_cidr($ip, $netmask);
	return unless $cidr;
	my $nmap = `command -v nmap 2>/dev/null`;
	chomp $nmap;
	# the manager's PATH is not the login shell's, so try the usual homes too
	for my $p (qw(/usr/bin/nmap /usr/local/bin/nmap /bin/nmap /usr/sbin/nmap)) {
		$nmap ||= $p if -x $p;
	}
	if ($nmap) {
		# -sn: host discovery only (ARP on-link), no port scan.
		`timeout 30 $nmap -sn -n -T4 --max-retries 1 $cidr 2>/dev/null`;
		return;
	}
	# No nmap: ping the network (a /24 at most) in parallel so the ARP cache
	# fills. A wider subnet is left to the neighbour table alone.
	my ($prefix) = $cidr =~ m{/(\d+)\z};
	return unless $prefix && $prefix >= 24;
	my ($net) = split m{/}, $cidr;
	my @o = split /\./, $net;
	my @hosts;
	for my $h (1 .. 254) {
		my @hh = @o;
		$hh[3] = $h;
		push @hosts, join('.', @hh);
	}
	open(my $ping, '|-', 'timeout 20 xargs -P 48 -n 1 ping -c 1 -W 1 >/dev/null 2>&1') or return;
	print $ping join("\n", @hosts), "\n";
	close $ping;
}

sub device_scan() {
	my ($timestamp, $load_type, $ip_range) = @_;
	my (undef, $database) = &subs::database_grabber();
	my ($dev,$devices,@domains);
	my $user_agent = $gb::user_agent;
	my $server_time = &subs::rightNow();
	my $my_name = &subs::setting_grabber({ app => 'me', setting => 'my_name' });
	my $signatorial = &subs::signatorial_designer();
	my $chip_ids = [];
	$dev = &subs::db_select('devices');
	$devices = $dev->hashes;
	# A machine in the mesh is a device we know even when it is away right now,
	# so a scan keeps its last sighting rather than pruning it with the rest. The
	# address may be its own name, or any LAN address it last reported.
	my %known_machine_ip;
	foreach my $rm (@{ &subs::db_select('remote_machines')->hashes }) {
		$known_machine_ip{$rm->{'ip'}} = 1 if $rm->{'ip'};
		my $net = eval { decode_json $rm->{'network'} } || {};
		foreach my $rnic (keys %{$net}) {
			my $rip = $net->{$rnic}->{'ip'};
			$known_machine_ip{$rip} = 1 if $rip && $rip !~ /^127\./;
		}
	}
	my $ug    = Data::UUID->new;
	my $uuid = $ug->create_str();
	foreach my $d (@{$devices}) {
		if (scalar @{$devices} > 0) {
			$d->{'address'} = eval { return decode_json $d->{'address'} };
			if ($d->{'domain'} ne '') {
				push @domains, { 'domain' => $d->{'domain'} . ' lladdr ' . 'mac_ave', hostname => $d->{'hostname'} };
			}
		}
	}
	my $hostname = `hostname`;
	my @me_device = grep { $_->{'hostname'} eq $hostname } @{$devices};
	chomp $hostname;
	my $uname = `uname -a`;
	chomp $uname;
	my $username = 'jawn';#`whoami`;
	chomp $username;

	my $name = &subs::setting_grabber({ app => 'me', setting => 'my_name' }) || $hostname;
	my $cpuinfo = `cat /proc/cpuinfo`;
	chomp $cpuinfo;
	my $ifc = &subs::device_setter() eq 'server' ? '/usr/sbin/ifconfig' : 'ifconfig 2>/dev/null | grep -v "Permission denied"';
	my @ifconfig = split "\n\n", `$ifc`;
	my @ifconfig_link;
	my @ifconfig_inet;
	my $address = {};
	my $count = {};
	my $home_ip;
	foreach my $if (@ifconfig) {
		my @ifconfig_list = split "\n", $if;

		@ifconfig_inet = grep { $_ =~ /inet/ } @ifconfig_list;

		my $nic = (split ' ', $ifconfig_list[0])[0];
		$nic =~ s/://;
		$address->{$nic}->{'nic'} = $nic;
		my $gw = '$(ip route show 0.0.0.0/0 dev ' . $address->{$nic}->{'nic'} . ' | cut -d\  -f3)';
		$address->{$nic}->{'gw'} = `echo $gw`;
		chomp $address->{$nic}->{'gw'};
		if ($device eq 'computer' || $device eq 'server') {
			my $gw_mac = '/usr/sbin/arp -a ' . $gw . '  | grep ' . $address->{$nic}->{'nic'};
			$gw_mac = `$gw_mac`;
			$address->{$nic}->{'gw_mac'} = (split ' ', $gw_mac)[3] if $gw && $device eq 'computer';
		}
		foreach my $i (@ifconfig_inet) {
			my @inet = split " ", $i;
			if ($i =~ /inet /) {
				$address->{$nic}->{'ip'} = $inet[1];
				$address->{$nic}->{'port'} = $ENV{PORT_AHOY};
				$address->{$nic}->{'ws_port'} = $ENV{PORT_MSG};
				$address->{$nic}->{'alarm_port'} = $ENV{PORT_BELL};
				$address->{$nic}->{'arm_port'} = $ENV{PORT_ARM};
				$address->{$nic}->{'bestow_port'} = $ENV{PORT_BESTOW};
				$address->{$nic}->{'coms_port'} = $ENV{PORT_COMS};
				$address->{$nic}->{'dock_port'} = $ENV{PORT_DOCK};
				$address->{$nic}->{'manager'} = 'https://' . $inet[1] . ':' . $ENV{PORT_DOCK} .  '/manager';
				$address->{$nic}->{'netmask'} = $inet[3];
				$address->{$nic}->{'broadcast'} = $inet[5];

				# A device nobody here has talked to is missing from the ARP cache
				# the read below depends on, so on an explicit scan sweep this
				# network first and let the answers fill it in.
				&subnet_sweep($nic, $address->{$nic}->{'ip'}, $address->{$nic}->{'netmask'}) if $load_type eq 'scan';

				my @neighbours;
				my $neighbour_check = `ip neigh show dev $nic`;
				my @neighbourinos;
				if ($load_type ne 'ping_scan') {
					@neighbourinos = (split "\n", $neighbour_check);
				}
				if ($ip_range) {
					# a host or range typed into the box is honoured even when the
					# neighbour table has entries: the device that pings but sleeps
					# its wifi (an esp32) is exactly the one missing from the table
					my $sip = $ip_range;
					$sip =~ s/[0-9]//gi;
					$home_ip = $address->{$nic}->{'ip'};
					my @home_ip = split '\.', $home_ip;
					my @csv = split ',', $ip_range;
					my @ip = split '\.', $ip_range;
					if (scalar @ip == 4) {
						if (&same_net_test($ip_range,$home_ip)) {
							push @neighbourinos, $ip_range . ' ' . &subs::random_string_creator(5);
						}
					}
					else {
						if (scalar @csv > 1) {
							foreach my $csv (@csv) {
								pop @home_ip;
								push @home_ip, $csv;
								push @neighbourinos, (join '.', @home_ip) . ' ' . &subs::random_string_creator(5);
							}
						}
						elsif ($sip eq '..' ) {
							my @sips = split '\.\.', $ip_range;

							foreach my $csv ( $sips[0] .. $sips[1] ) {
								pop @home_ip;
								push @home_ip, $csv;
								push @neighbourinos, (join '.', @home_ip ). ' ' . &subs::random_string_creator(5);
							}
						}
					}
				}
				foreach my $do ( @domains ) {
					push @neighbourinos, $do->{'domain'} if $do->{'hostname'} eq $hostname;
				}
				# `ip neigh` never lists the loopback interface's own address, and the
				# tunnels this server holds hang off exactly that 127.0.0.1 row below -
				# so on cloud no tunnelled machine ever showed at all. Put the row in:
				# it marks this machine, and every active tunnel becomes one of its
				# neighbours, reached on the hub-side port the tunnel reserved.
				if (&subs::device_setter() eq 'server'
					&& ($address->{$nic}->{'ip'} || '') eq '127.0.0.1'
					&& !grep { (split ' ', $_)[0] eq '127.0.0.1' } @neighbourinos) {
					push @neighbourinos, '127.0.0.1 ' . &subs::random_string_creator(5);
				}
				foreach my $m ( @neighbourinos ) {
					# `ip neigh show dev X` prints only `IP [lladdr MAC] STATE`, and a host
					# the sweep half-resolved reads INCOMPLETE (or FAILED/PROBE): it never
					# answered, so it is no device. Keep the resolved rows and the typed
					# host and self row, which carry no state word at all.
					next if $m =~ /\b(?:FAILED|INCOMPLETE|PROBE)\b/;
					my @l = (split " ", $m);
					# the sweep reports this machine among its own neighbours; the
					# loopback row below is the exception, it marks this machine on
					# purpose (and carries the tunnels)
					next if $l[0] && $l[0] ne '127.0.0.1' && $l[0] eq ($address->{$nic}->{'ip'} || '');
					my $n = {
						ip => $l[0],
						mac => $l[2] || &subs::random_string_creator(10),
						uuid => &subs::random_string_creator(25)
					};
					my $ping_ip = $n->{'ip'};
					# a sleeping esp32 can take a second to answer the first packet
					my $alive = `timeout 1.2 ping -c 1 -W 1 $ping_ip`;
					my $ip_addresses = [ ];
					if ($n->{'ip'} eq '127.0.0.1') {
						push @{$ip_addresses}, $n;
						if (&subs::device_setter() eq 'server') {
							my $tunnels = &subs::db_select('tunnels', undef, { status => 'active' })->hashes;
							my @batches;
							foreach my $tun ( @{$tunnels} ) {
								next unless $tun->{'name'} eq 'PORT_DOCK';
								next if grep { $_ eq $tun->{'batch_uuid'} } @batches;
								push @batches, $tun->{'batch_uuid'};
								push @{$ip_addresses}, {
									# the peer, not this hub: a hub-side row carries the peer's own
									# domain in `host` and this hub's in `domain`, so naming the
									# neighbour by `domain` listed the hub itself, once per
									# tunnelled machine, and every row collapsed together
									ip => ($tun->{'host'} || $tun->{'ip'} || $tun->{'domain'}),
									domain => ($tun->{'host'} || $tun->{'ip'} || $tun->{'domain'}),
									PORT_DOCK => $tun->{'in_port'},
									tunnel => 'yes',
									mac => &subs::random_string_creator(10),
									signatorial => $tun->{'signatorial'},
									uuid => &subs::random_string_creator(25)
								};


							}


						}
					}
					elsif ($n->{'ip'} =~ /127\.0\.0/) { next; }
					else { push @{$ip_addresses}, $n; }
					foreach my $n ( @{$ip_addresses} ) {
						if ( $n->{'ip'} && ($n->{'tunnel'} eq 'yes' || $alive =~ /ttl/gi )) { #&& $n->{'ip'} ne $address->{$nic}->{'ip'}) {
							my $ua = Mojo::UserAgent->new();
							# A neighbour that is not JawnOS (a printer, an appliance the sweep
							# found) must not hold the scan for the full timeout: a LAN answer
							# is milliseconds, so a couple of seconds to connect and a short
							# inactivity window keep a sweep over a busy subnet quick, while a
							# real but busy peer still has room to answer.
							$ua->connect_timeout(2);
							$ua->inactivity_timeout(5);
							my $manager = $n->{'tunnel'} eq 'yes' ? 'https://127.0.0.1:' . ($n->{'PORT_DOCK'} || $ENV{PORT_DOCK}) .  '/manager'
								: 'https://' . $n->{'ip'} . ':' . ($n->{'PORT_DOCK'} || $ENV{PORT_DOCK}) .  '/manager';
							my $res = eval { $ua->insecure(1)->get($manager . '/gate?restore_list=' . $config->{'start_dir'} . '&neighbour=' . $hostname . '&my_name=' . $my_name . '&signatorial=' . $signatorial => {user_agent => $user_agent})->result };
							if (eval { $res->is_success }){
								if (eval { decode_json $res->body }) {
									my $rb = decode_json $res->body;
									$n->{'purpose'} = $rb->{'purpose'};
									$n->{'restore_list'} = encode_json $rb->{'restore_list'};
									$n->{'signatorial'} = $rb->{'signatorial'};
									$n->{'name'} = $rb->{'name'};
								}
								$n->{'manager'} = $manager;
							}
							else {
								my $manager = 'http://' . $n->{'ip'} . ':' . ($n->{'PORT_DOCK'} || $ENV{PORT_DOCK}) .  '/device_query';
								my $res = eval { $ua->insecure(1)->get($manager) };
								if (eval { $res->result->body }) {
									if (eval { decode_json $res->result->body }) {
										my $rb = decode_json $res->result->body;
										$n->{'purpose'} = $rb->{'purpose'};
										$n->{'model'} = $rb->{'model'};
										$n->{'pins'} = $rb->{'pins'} if $rb->{'pins'};
										$n->{'name'} = $rb->{'name'} if $rb->{'name'};
										$n->{'chip_id'} = $rb->{'chip_id'};
										$n->{'mac_addresses'} = $rb->{'mac_addresses'};
										$n->{'mac'} = $rb->{'mac_addresses'}->{'base'};
										$n->{'service_uuid'} = $rb->{'SERVICE_UUID'} if $rb->{'SERVICE_UUID'};
										$n->{'characteristic_uuid_rx'} = $rb->{'CHARACTERISTIC_UUID_RX'} if $rb->{'CHARACTERISTIC_UUID_RX'};
										$n->{'characteristic_uuid_tx'} = $rb->{'CHARACTERISTIC_UUID_TX'} if $rb->{'CHARACTERISTIC_UUID_TX'};
										push @{$chip_ids}, { id => $n->{'chip_id'}, name => $n->{'name'}, purpose => $n->{'purpose'}, server_time => &subs::rightNow() };
									}
								}
								else {
									$n->{'purpose'} = 'hmmm';
								}
							}
						}
						foreach my $d (@{$devices}) {
							foreach my $a (keys %{$d->{'address'}} ) {
								foreach my $g (grep { $_->{'ip'} eq $n->{'ip'} || $_->{'ip_address'} eq $n->{'ip'} } @{$d->{'address'}->{$a}->{'neigh'}} ) {
									$g->{'ip'} =~ /([0-9]+)$/gi;
									my $last_d = $1;
									$n->{'ip'} =~ /([0-9]+)$/gi;
									my $last_n = $1;
									$n->{'fqdn'} = $g->{'fqdn'};
									$n->{'mac'} = $g->{'mac'} || $n->{'mac'};
									$n->{'ip_address'} = $g->{'ip_address'};
									# a device that does not answer the query is marked
									# 'hmmm'; a purpose a person set earlier beats that
									# placeholder, so a printer stays the printer
									if ($g->{'purpose'} && (!$n->{'purpose'} || $n->{'purpose'} eq 'hmmm')) {
										$n->{'purpose'} = $g->{'purpose'};
									}
									if ($g->{'locked'} eq 'yes') {
										$g->{'uuid'} = $n->{'uuid'} unless $g->{'uuid'};
										$n = $g;
									}
								}
							}
						}
						push @neighbours, $n;
					}


				}
				foreach my $n ( @neighbours ) {
					@{$address->{$nic}->{'neigh'}} = grep { $_->{'ip'} ne $n->{'ip'} } @{$address->{$nic}->{'neigh'}};
					push @{$address->{$nic}->{'neigh'}}, $n;
				}
				# One row per address: the typed host and the neighbour table can name
				# the same device, and the scan rendered it twice (2026-10-09). The
				# richer row wins -- the one the device itself answered.
				my %neigh_seen;
				my @neigh_deduped;
				foreach my $n ( @neighbours ) {
					my $neigh_ip = $n->{'ip'};
					if (my $had = $neigh_seen{$neigh_ip}) {
						foreach my $f ( qw/chip_id purpose name model mac mac_addresses uuid fqdn/ ) {
							$had->{$f} = $n->{$f} if $n->{$f} && !$had->{$f};
						}
						next;
					}
					$neigh_seen{$neigh_ip} = $n;
					push @neigh_deduped, $n;
				}
				@neighbours = @neigh_deduped;
				@{$address->{$nic}->{'neigh'}} = @neighbours;

			}
			if ($i =~ /inet6 /) {
				$address->{$nic}->{'ip6'} = $inet[1];
			}
		}
		@ifconfig_link = grep { $_ =~ /ether/ } @ifconfig_list;
		foreach my $m (@ifconfig_link) {
			my @mac = split " ", $m;
			if ($m =~ /ether/) {
				$address->{$nic}->{'mac'} = $mac[1];
			}
		}
		#here

		foreach my $d (@{$devices}) {
			foreach my $a (keys %{$d->{'address'}} ) {
				if ($d->{'address'}->{$nic}->{'neigh'} && $a eq $nic) {
					foreach my $rd ( @{$d->{'address'}->{$nic}->{'neigh'}} ) {
						# A device we have a reason to keep stays on the list even when this
						# scan did not see it: one the person locked, a machine in the mesh
						# (a remote_machine, or anything that named itself with a signatorial),
						# or one the person gave a real purpose. Everything else is a passing
						# sighting and is pruned.
						my $known = (($rd->{'locked'} || '') eq 'yes')
							|| $rd->{'signatorial'}
							|| $known_machine_ip{$rd->{'ip'}}
							|| ((($rd->{'purpose'} || '') ne '') && $rd->{'purpose'} ne 'hmmm');
						next unless $known;
						if (($rd->{'locked'} || '') eq 'yes') {
							# a locked device: its stored row wins outright
							@{$address->{$nic}->{'neigh'}} = grep { $_->{'ip'} ne $rd->{'ip'} } @{$address->{$nic}->{'neigh'}};
							push @{$address->{$nic}->{'neigh'}}, $rd;
						}
						elsif (!grep { $_->{'ip'} eq $rd->{'ip'} } @{$address->{$nic}->{'neigh'}}) {
							# a known device that is away just now: keep its last sighting
							push @{$address->{$nic}->{'neigh'}}, $rd;
						}
						push @{$chip_ids}, { id => $rd->{'chip_id'}, name => $rd->{'name'}, purpose => $rd->{'purpose'}, server_time => &subs::rightNow() } if $rd->{'chip_id'};
					}
				}
			}
		}
	}

	# mDNS names what the neighbour read cannot: a JawnOS device on _jawnos._tcp
	# says its purpose, model and abilities, and a printer says it is a printer,
	# so the devices answer for themselves the moment they join the network.
	&mdns_merge_address($address) if $load_type eq 'scan';

	my $json_address = encode_json $address;

	my @my_device = grep { ($_->{'hostname'} && $_->{'hostname'} eq $hostname) } @{$devices};
	my $president = $database;


	my $oldjchips = $my_device[0]->{'chip_ids'};
	my $oldchips = eval { return decode_json $oldjchips } || [];
	if (scalar @{$oldchips} > 0) {
		foreach my $ci ( @{$oldchips} ) {
			push @{$chip_ids}, $ci unless grep { $_->{'id'} eq $ci->{'id'} } @{$chip_ids};
		}
	}
	my $jchips = encode_json $chip_ids;
	my $me = {
		timestamp => $timestamp,
		hostname => $hostname,
		uname => $uname,
		address => $json_address,
		protocol => 'https',
		port => $ENV{PORT_AHOY},
		server_time => $server_time,
		president => $president,
		uuid => $uuid,
		chip_ids => $jchips
	};
	if (scalar @my_device == 0 || scalar @{$devices} == 0) {
		&subs::db_insert('devices', $me);
	}
	else {
		&subs::db_update('devices', { chip_ids => $jchips, address => $json_address, timestamp => $timestamp }, { hostname => $hostname });
	}
}

# This machine's own row in `devices`, created without a browser. The one Scan
# that used to build it runs in Configure -> Dev, so a headless server never had
# a self row - and with no row this hub has no `address` map at all, so the
# tunnels it holds can never be listed as its own neighbours (tunnel_checker
# hangs them off that row; device_scan is otherwise the only writer). Built from
# the same interface report device_scan writes, so the two agree on shape. Cheap
# when the row already exists (one select), so a per-tick caller is fine.
sub ensure_self_device() {
	my $hostname = `hostname`;
	chomp $hostname;
	# A blank or loopback hostname is no name to file a machine under (and would
	# make a second, shadow self row on a phone); leave those alone.
	return undef if !$hostname || $hostname eq 'localhost';
	my $existing = &subs::db_select('devices', undef, { hostname => $hostname })->hashes->[0];
	return $existing if $existing;
	my $address = &subs::network_interface_reporter();
	return undef unless $address && scalar keys %{$address};
	my $uname = `uname -a`;
	chomp $uname;
	my (undef, $database) = &subs::database_grabber();
	&subs::db_insert('devices', {
		timestamp => &subs::rightNow(),
		hostname => $hostname,
		uname => $uname,
		address => encode_json $address,
		protocol => 'https',
		port => $ENV{PORT_AHOY},
		server_time => &subs::rightNow(),
		president => $database,
		uuid => &subs::random_string_creator(25),
		chip_ids => '[]',
	});
	&subs::log_writer('self device row created for ' . $hostname);
	return &subs::db_select('devices', undef, { hostname => $hostname })->hashes->[0];
}

sub device_lister() {
	my ($timestamp,$load_type,$ip_range,$chip_id) = @_;
	my ($dev,$devices);
	my $remote_machines = &subs::db_query('select * from remote_machines')->hashes;
	if ($load_type eq 'scan' || $load_type eq 'ping_scan') {
		&device_scan($timestamp, $load_type, $ip_range);
	}
	$dev = &subs::db_select('devices');
	$devices = $dev->hashes;
	# One row per address across the whole listing: a device can sit in several
	# machines' neighbour tables (and in more than one NIC of one -- the T-Deck
	# showed three times on 2026-10-09, twice on wlo1 and once under lo). The
	# richest entry wins -- the one the device itself answered -- and every
	# other copy is dropped before the tables render. 127.0.0.1 is left alone:
	# it is how each machine marks itself.
	{
		my %best;
		my $richness = sub {
			my ($n, $nic) = @_;
			my $r = 0;
			$r += 4 if $n->{'chip_id'};
			$r += 2 if $n->{'model'} || $n->{'mac_addresses'};
			$r += 2 if ($n->{'purpose'} || '') ne '' && $n->{'purpose'} ne 'hmmm';
			$r += 1 if $n->{'name'} || $n->{'fqdn'};
			$r -= 2 if $nic eq 'lo';
			return $r;
		};
		foreach my $d (@{$devices}) {
			$d->{'address'} = eval { return decode_json $d->{'address'} } if $d->{'address'} && !ref $d->{'address'};
			my @self_ips = map { $d->{'address'}->{$_}->{'ip'} } keys %{$d->{'address'} || {}};
			foreach my $a ( keys %{$d->{'address'} || {}} ) {
				foreach my $n ( @{$d->{'address'}->{$a}->{'neigh'} || []} ) {
					my $ip = $n->{'ip'} || $n->{'ip_address'};
					next unless $ip;
					next if $ip eq '127.0.0.1' || grep { $_ && $_ eq $ip } @self_ips;
					my $r = $richness->($n, $a);
					if (!$best{$ip}) {
						$best{$ip} = [ $r, $n ];
					}
					elsif ($r > $best{$ip}->[0]) {
						foreach my $f ( keys %{$best{$ip}->[1]} ) {
							$n->{$f} = $best{$ip}->[1]->{$f} if !$n->{$f};
						}
						$best{$ip} = [ $r, $n ];
					}
					else {
						foreach my $f ( keys %{$n} ) {
							$best{$ip}->[1]->{$f} = $n->{$f} if !$best{$ip}->[1]->{$f};
						}
					}
				}
			}
		}
		foreach my $d (@{$devices}) {
			foreach my $a ( keys %{$d->{'address'} || {}} ) {
				next unless $d->{'address'}->{$a}->{'neigh'};
				@{$d->{'address'}->{$a}->{'neigh'}} = grep {
					my $ip = $_->{'ip'} || $_->{'ip_address'};
					!$ip || !$best{$ip} || $best{$ip}->[1] eq $_;
				} @{$d->{'address'}->{$a}->{'neigh'}};
			}
		}
	}
	my $all_chips = [];
	foreach my $d (@{$devices}) {
		$d->{'address'} = decode_json $d->{'address'} if $d->{'address'} && !ref $d->{'address'};
		$d->{'formatted_time'} = &subs::formatted_time($d->{'timestamp'});
		foreach my $a ( keys %{$d->{'address'}} ) {
			foreach my $n ( @{$d->{'address'}->{$a}->{'neigh'}} ) {
				if (my @pool = grep { $d->{'address'}->{$_}->{'ip'} eq $n->{'ip'} } keys %{$d->{'address'}} ) {
					$n->{'me'} = 'me';
				}
				if ($load_type eq 'watch' && $n->{'purpose'} eq 'watch') {
					if ($chip_id) {
						if ($chip_id eq 'all') {
							push @{$all_chips}, $n;
						}
						elsif ($chip_id eq $n->{'chip_id'}) {
							$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
							return $n;
						}
					}
					else {
						$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
						return $n;
					}
				}
				if ($load_type eq 'microcontroller' && $n->{'purpose'} eq 'microcontroller') {
					if ($chip_id) {
						if ($chip_id eq 'all') {
							push @{$all_chips}, $n;
						}
						elsif ($chip_id eq $n->{'chip_id'}) {
							$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
							return $n;
						}
					}
					else {
						$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
						return $n;
					}
				}
				if ($load_type eq 'printer' && $n->{'purpose'} eq 'printer') {
					return $n;
				}
				if ($load_type eq 'teletype' && $n->{'purpose'} eq 'teletype') {
					if ($chip_id) {
						if ($chip_id eq 'all') {
							push @{$all_chips}, $n;
						}
						elsif ($chip_id eq $n->{'chip_id'}) {
							$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
							return $n;
						}
					}
					else {
						$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
						return $n;
					}
				}
				if ($load_type eq 'computer' && $n->{'purpose'} eq 'computer') {
					$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
					return $n;
				}
				if ($load_type eq 'mobile' && $n->{'purpose'} eq 'mobile') {
					$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
					return $n;
				}
				if ($gb::remote->{$n->{'ip'}} ) {
					my @rem = grep { $_->{'ip'} eq $n->{'ip'} } @{$remote_machines};
					$n->{'button'} = $rem[0]->{'buttons'};
				}
			}
		}
	}
	# Off its access point, an embedded device bridged over Bluetooth is not in
	# any machine's neighbour table, so the loops above never see it - yet it is
	# still reachable and told us so when it last spoke over the bridge
	# (ble_device_record keeps that sighting in the machine's chip_ids). Fall
	# back to it, but only while the sighting is fresh: a device away longer
	# than the window is treated like any other gone device.
	my %ble_types = map { $_ => 1 } qw/watch teletype microcontroller/;
	if ($ble_types{$load_type} && $chip_id) {
		my $window = &ble_presence_window();
		my $now = &subs::rightNow();
		# One entry per chip, the freshest sighting. The same watch is recorded in
		# every machine's synced `devices` row, so iterating them all listed - and
		# later pushed to - the same radio many times over: a single toggle became a
		# burst of identical sends.
		my %ble_by_id;
		foreach my $d ( @{$devices} ) {
			next unless $d->{'chip_ids'};
			my $chips = eval { decode_json $d->{'chip_ids'} } || [];
			foreach my $c ( @{$chips} ) {
				next unless $c->{'id'} && ($c->{'ble'} || $c->{'bluetooth'});
				next unless $window > $now - ($c->{'ble_seen'} || 0);
				my $id = $c->{'id'};
				$ble_by_id{$id} = $c
					if !$ble_by_id{$id} || ($c->{'ble_seen'} || 0) > ($ble_by_id{$id}->{'ble_seen'} || 0);
			}
		}
		my @ble = values %ble_by_id;
		if ($chip_id eq 'all') {
			push @{$all_chips}, map { &ble_device_from_chip($_, $load_type) } @ble;
		}
		else {
			foreach my $c ( @ble ) {
				next unless $c->{'id'} eq $chip_id;
				return &ble_device_from_chip($c, $load_type);
			}
		}
	}
	if (scalar @{$all_chips} > 0) {
		return $all_chips;
	}
	return $devices;
}

# The device rows as the lister shows them, grouped by the network each
# neighbour sits on: one group per subnet, its members (the interfaces that
# reach it, each on a machine), and the devices found there. device_lister has
# already left each address once, so a device is listed under a single network.
sub network_groups() {
	my ($devices) = @_;
	return [] unless ref $devices;
	# device_lister hands back a Mojo::Collection (a blessed array), not a plain
	# one, so dereference it rather than testing for 'ARRAY'.
	my @rows = eval { @{$devices} };
	return [] unless @rows;
	my (%groups, @order);
	foreach my $d (@rows) {
		next unless ref $d eq 'HASH';
		$d->{'address'} = eval { return decode_json $d->{'address'} } if $d->{'address'} && !ref $d->{'address'};
		foreach my $nic (keys %{$d->{'address'} || {}}) {
			my $a = $d->{'address'}->{$nic};
			next unless ref $a eq 'HASH';
			my $cidr = &subnet_cidr($a->{'ip'}, $a->{'netmask'}) || ($a->{'ip'} ? $a->{'ip'} : 'unknown');
			unless ($groups{$cidr}) {
				$groups{$cidr} = { cidr => $cidr, members => [] };
				push @order, $cidr;
			}
			push @{$groups{$cidr}->{'members'}}, {
				%{$a},
				uuid => $d->{'uuid'},
				hostname => $d->{'hostname'},
				domain => $d->{'domain'},
				machine_timestamp => $d->{'timestamp'},
				formatted_time => $d->{'formatted_time'},
			};
		}
	}
	# the real networks first, the loopback (this machine, and its tunnels) last
	my @sorted = sort {
		my $al = index($a, '127.') == 0 ? 1 : 0;
		my $bl = index($b, '127.') == 0 ? 1 : 0;
		$al <=> $bl
			|| join('.', map { sprintf '%03d', $_ } split /[.\/]/, $a) cmp join('.', map { sprintf '%03d', $_ } split /[.\/]/, $b);
	} @order;
	return [ map { $groups{$_} } @sorted ];
}

# --- JawnOS BLE bridge (replaces the am broadcast + Tasker + BLE plugin chain) ---

sub ble_bridge_enabled() {
	# On by default now that the phone's Tasker bridge is retired. Set
	# ble_bridge to 0 in config.json to fall back to the old broadcast path.
	return 1 unless $config && defined $config->{'ble_bridge'};
	return $config->{'ble_bridge'} ? 1 : 0;
}

sub ble_bridge_capable() {
	# Can this machine drive the wrist/board bridge? It is the mobile hub when
	# config says so (the original rule), or any machine that actually runs the
	# bridge daemon on its own loopback (the Linux/desktop port). The gate used
	# to be `device_setter() eq 'mobile'` alone, which left a desktop with a
	# live daemon unable to answer a watch's room_request or push a toggle.
	return 1 if &subs::device_setter() eq 'mobile';
	return 0 unless &subs::ble_bridge_enabled();
	require IO::Socket::INET;
	my $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => 45999, Proto => 'tcp', Timeout => 1);
	return 0 unless $sock;
	close $sock;
	return 1;
}

sub ble_bridge_client() {
	# jawn-bt client of the JawnOS BLE bridge daemon (JawnBleService in the
	# JawnOS API app). Prefer the copy that ships with the repo.
	foreach my $c ( "$ENV{HOME}/jawnos/scripts/jawn-bt", "$ENV{HOME}/jawn-bt", './scripts/jawn-bt' ) {
		return $c if -e $c;
	}
	return undef;
}

# ---- multi-link bridge state (protocol v2) --------------------------------
# A desktop or phone bridge can hold several radios at once. Every link event
# names its MAC; keep the same map here so a send, a yield and a sighting can
# name the right radio instead of guessing at "the" link. A v1 daemon still
# works: its status has no links[], so the top-level fields become the one link.
sub ble_link_key {
	my ($mac) = @_;
	return '' unless defined $mac && length $mac;
	$mac = uc $mac;
	$mac =~ s/[^0-9A-F]//g;
	return $mac;
}

sub ble_links() {
	$gb::ble_links ||= {};
	return $gb::ble_links;
}

sub ble_link_apply_event {
	my ($event) = @_;
	return unless $event && ref $event eq 'HASH';
	my $name = $event->{'event'} || '';
	my $links = &ble_links();
	if ($name eq 'status') {
		my %next;
		foreach my $l ( @{ $event->{'links'} || [] } ) {
			next unless ref $l eq 'HASH';
			my $mac = &ble_link_key($l->{'mac'});
			next unless $mac;
			$next{$mac} = { %{$l}, mac => $mac };
		}
		if (!@{ $event->{'links'} || [] }) {
			my $mac = &ble_link_key($event->{'mac'});
			if ($mac && $event->{'connected'}) {
				$next{$mac} = { mac => $mac, connected => 1, mtu => $event->{'mtu'}, state => 'connected' };
			}
		}
		$gb::ble_links = \%next;
		my $p = &ble_link_key($event->{'mac'});
		$gb::ble_primary_mac = ($p && $next{$p} && $next{$p}->{'connected'}) ? $p : undef;
	}
	elsif ($name eq 'connected') {
		my $mac = &ble_link_key($event->{'mac'}) or return;
		$links->{$mac} = { %{ $links->{$mac} || {} }, %{$event}, mac => $mac, connected => 1, state => 'connected' };
		$links->{$mac}->{'since'} ||= time();
		$gb::ble_primary_mac = $mac;
	}
	elsif ($name eq 'disconnected') {
		my $mac = &ble_link_key($event->{'mac'}) or return;
		if ($links->{$mac}) {
			$links->{$mac}->{'connected'} = 0;
			$links->{$mac}->{'state'} = $event->{'next_retry_ms'} ? 'reconnecting' : 'idle';
		}
	}
	my $primary = $gb::ble_primary_mac;
	unless ($primary && $links->{$primary} && $links->{$primary}->{'connected'}) {
		my @up = sort { ($b->{'since'} || 0) <=> ($a->{'since'} || 0) }
			grep { $_->{'connected'} } values %{$links};
		$gb::ble_primary_mac = @up ? $up[0]->{'mac'} : undef;
	}
	# The old scalar still means "the primary link" for the few callers that
	# have not been taught to name a MAC (and for a v1 daemon).
	$gb::ble_link_mac = $gb::ble_primary_mac;
	return $gb::ble_primary_mac;
}

sub ble_mac_for_chip {
	my ($chip_id) = @_;
	return undef unless $chip_id;
	foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
		next unless $d->{'chip_ids'};
		foreach my $c ( @{ (eval { decode_json $d->{'chip_ids'} } || []) } ) {
			next unless $c->{'id'} && $c->{'id'} eq $chip_id && $c->{'bluetooth'};
			return $c->{'bluetooth'};
		}
	}
	return undef;
}

	# How long a Bluetooth sighting keeps an embedded device listed in the Embedded
	# app after its last bridge message. A watch's radio sleeps and re-links on the
	# next advert, and even awake it only talks when something changes, so this must
	# outlast a quiet spell - not merely a nap. Two hours, so a watch that speaks
	# rarely (a connected one says nothing for a long time) stays on the list even
	# across a spell where its jawn was down; a device genuinely gone still drops.
	sub ble_presence_window() { return 7200000; }

sub embedded_operator_door() {
	# The operator_door row that carries a device's current Now Me pair. It is
	# written by whichever House machine ran Now Me, with that machine's device
	# class in `device`; a computer and a phone can both serve the same watch, so
	# never filter this lookup by this machine's class - a fallback of a
	# different class would otherwise read an empty record and deny the device.
	# Rows rotate on every Now Me, so the newest is the current pair.
	my ($edt, $chip_id) = @_;
	return undef unless $edt && $chip_id;
	my $row = &subs::db_query(
		'select value from settings where app = ? and setting = ? and subsetting = ? order by server_time desc limit 1',
		$edt, 'operator_door', $chip_id
	)->hashes->[0];
	return $row ? $row->{'value'} : undef;
}

sub ble_device_specs() {
	# A device's __specs from its operator_door (which syncs): the durable id of
	# the machine it was paired to, and the address that machine last handed it.
	# Cached briefly, as it is asked on every send.
	my ($edt, $chip_id) = @_;
	return {} unless $chip_id;
	my $key = ($edt || 'watch') . '|' . $chip_id;
	my $now = time();
	my $c = $gb::ble_specs->{$key};
	return $c->[1] if $c && $now - $c->[0] <= 5;
	my $od = &subs::embedded_operator_door($edt || 'watch', $chip_id);
	my $op_d = eval { decode_json $od } || {};
	my $specs = $op_d->{'__specs'} || {};
	$gb::ble_specs->{$key} = [ $now, $specs ];
	return $specs;
}

sub house_nodes_list() {
	# The House machines an embedded device may fall back to: this machine and
	# every peer with a LAN address, each with the manager ports a device dials.
	# It rides in Now Me, so a device holds a usable list even when mDNS does not
	# answer (and on a board that cannot browse mDNS at all).
	#
	# A device only reaches its own LAN, so when a device address is given only
	# machines on that subnet are offered.
	my ($device_ip) = @_;
	my $want_net;
	if ($device_ip && $device_ip =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$/) {
		$want_net = $1;
	}
	my (%seen, @nodes);
	my $add = sub {
		my ($ip, $port, $arm, $coms, $bestow, $name, $computer) = @_;
		return unless $ip && $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
		return if $ip =~ /^127\./ || $seen{$ip}++;
		if ($want_net) {
			my $net = $ip;
			$net =~ s/\.\d+$//;
			return unless $net eq $want_net;
		}
		# The offsets are this tree's convention (main +2/+3/+4); they answer
		# for a peer whose stored network row predates the explicit fields.
		$arm ||= ($port ? $port + 2 : undef);
		$bestow ||= ($port ? $port + 3 : undef);
		$coms ||= ($port ? $port + 4 : undef);
		return unless $arm && $arm > 0;
		push @nodes, {
			ip => $ip,
			arm => $arm + 0,
			coms => ($coms || 0) + 0,
			bestow => ($bestow || 0) + 0,
			name => $name || '',
			computer => $computer || '',
		};
	};
	my $config = &subs::config_reader();
	my $local_name = $config->{'name'} || '';
	my $addrs = &subs::network_interface_reporter();
	foreach my $nic ( keys %{$addrs} ) {
		my $a = $addrs->{$nic} || {};
		$add->($a->{'ip'}, $a->{'port'}, $a->{'arm_port'}, $a->{'coms_port'}, $a->{'bestow_port'}, $local_name, &ble_manager_file());
	}
	foreach my $rm ( @{ &subs::db_select('remote_machines')->hashes } ) {
		my $net = eval { decode_json $rm->{'network'} } || {};
		foreach my $nic ( keys %{$net} ) {
			my $a = $net->{$nic} || {};
			$add->($a->{'ip'}, $a->{'port'}, $a->{'arm_port'}, $a->{'coms_port'}, $a->{'bestow_port'}, $rm->{'manager_file'}, $rm->{'manager_file'});
		}
	}
	return \@nodes;
}

sub house_advertise_command() {
	# The argv that publishes this machine on _jawnos-house._tcp. The embedded
	# devices browse that service when their stored homebase goes quiet; the
	# service carries the ports they dial, because the offsets are not something
	# a device should have to guess from the main port.
	my $avahi = `command -v avahi-publish-service 2>/dev/null`;
	chomp $avahi;
	$avahi ||= '/usr/bin/avahi-publish-service' if -x '/usr/bin/avahi-publish-service';
	return () unless $avahi;
	my $config = &subs::config_reader();
	my $name = $config->{'name'} || 'JawnOS';
	my $hostname = `hostname`;
	chomp $hostname;
	my $purpose = &subs::device_setter();
	my $port = $ENV{PORT_AHOY} || $config->{'working_port'} || 45545;
	my $mesh = '';
	my ($db, $database) = &subs::database_grabber();
	$mesh = $database if $database;
	$mesh =~ s{.*/}{};
	$mesh =~ s/\.db$//i;
	my @txt = (
		'purpose=' . $purpose,
		'name=' . $name,
		'hostname=' . $hostname,
		'version=1',
		'mesh=' . $mesh,
	);
	push @txt, 'arm=' . $ENV{PORT_ARM} if $ENV{PORT_ARM};
	push @txt, 'coms=' . $ENV{PORT_COMS} if $ENV{PORT_COMS};
	push @txt, 'bestow=' . $ENV{PORT_BESTOW} if $ENV{PORT_BESTOW};
	push @txt, 'dock=' . $ENV{PORT_DOCK} if $ENV{PORT_DOCK};
	my $computer = eval { &Manager::manager_file_maker() };
	push @txt, 'computer=' . $computer if $computer;
	# The instance name is what a person sees in an mDNS browser; Avahi adds a
	# #2 itself if two machines share a name.
	return ($avahi, '--no-reverse', '-s', 'JawnOS ' . $name . ' (' . $hostname . ')', '_jawnos-house._tcp', $port, @txt);
}

sub house_advertise_supervise() {
	# Keep the publisher up for as long as this tree lives. A nested fork/exec is
	# used rather than a shell background job so the avahi child dies with the
	# supervisor (and the supervisor with President).
	my $ppid = getppid();
	while ( getppid() == $ppid ) {
		my @cmd = &house_advertise_command();
		return unless @cmd;
		my $pid = fork();
		if (!defined $pid) { sleep 10; next; }
		if (!$pid) { exec @cmd; exit 1; }
		local $SIG{TERM} = sub { kill 'TERM', $pid; exit 0; };
		waitpid($pid, 0);
		sleep 15;
	}
}

sub ble_manager_file() {
	# This machine's durable id, the same string a device's record names as its
	# "computer". Cached: manager_file_maker reads the database.
	my $now = time();
	return $gb::ble_mf->[1] if $gb::ble_mf && $now - $gb::ble_mf->[0] <= 10;
	my $mf = eval { &Manager::manager_file_maker() } || '';
	$gb::ble_mf = [ $now, $mf ];
	return $mf;
}

sub ble_machine_match() {
	# A machine's durable id is '<who>@<mesh>.<computer>' (manager_file_maker).
	# The <mesh> segment is the database's base name, so renaming the database
	# (initial -> jawnos) silently retires every stored id: a device's record then
	# names a machine no row holds, ble_owns stops recognizing its own homebase, and
	# ble_homebase_alive treats the phantom as alive forever - so the real homebase
	# yields the device and nobody ever bridges it. Match on the parts that survive
	# a rename (the person and the computer name), so a rename does not strand a
	# device on a machine that is sitting right next to it.
	my ($a, $b) = @_;
	return 0 unless defined $a && defined $b && length $a && length $b;
	return 1 if $a eq $b;
	my ($aw, $amesh) = split /\@/, $a, 2;
	my ($bw, $bmesh) = split /\@/, $b, 2;
	return 0 unless defined $amesh && defined $bmesh;
	$amesh =~ s/^.*\.//;
	$bmesh =~ s/^.*\.//;
	return ($aw eq $bw && $amesh eq $bmesh) ? 1 : 0;
}

sub ble_owns() {
	# Is this machine the device's homebase - the machine the person paired it
	# to? A watch is a one-link peripheral, so only the homebase should hold its
	# link. The pairing is recorded by the machine's durable id, not by an address,
	# so it survives that machine changing network - the address form is only a
	# fallback for older records. A device nobody has placed is ours.
	my ($edt, $chip_id) = @_;
	my $specs = &ble_device_specs($edt, $chip_id);
	my $who = $specs->{'computer'};
	if ($who) {
		my $mine = &ble_manager_file();
		return 0 unless $mine;
		# compare past a database rename, or a stale id makes the device look
		# like it belongs to a machine that no longer exists
		return &ble_machine_match($who, $mine) ? 1 : 0;
	}
	my $home = $specs->{'homebase'};
	return 1 unless $home;
	$home =~ s/:\d+$//;
	# Cache this machine's addresses for a moment: this runs on every send, and a
	# toggle fan-out asks once per watch.
	my $now = time();
	unless ($gb::ble_mine_ips && $now - ($gb::ble_mine_ips_at || 0) <= 5) {
		my $addrs = &subs::network_interface_reporter();
		$gb::ble_mine_ips = { map { ($addrs->{$_}->{'ip'} || '') => 1 } keys %{$addrs} };
		$gb::ble_mine_ips_at = $now;
	}
	return $gb::ble_mine_ips->{$home} ? 1 : 0;
}

sub ble_fallback_grace() {
	# How long a device's homebase may be off the mesh before another machine
	# takes its watch over. The person wants the watch to stay on the machine it
	# was paired to, so the takeover must outlast a homebase that merely left the
	# LAN - a phone on cellular, a wifi roam, a machine that syncs in bursts. The
	# old ten-minute window grabbed the watch on every blink, which was the
	# tug-of-war the person saw between the phone and the laptop/tablet. Long
	# enough that only a homebase genuinely gone hands it over.
	return 900000;
}

sub ble_fallback_stop_grace() {
	# A homebase that stopped on purpose - it marked itself, or the mesh marked it,
	# inactive - is gone now, not merely off the LAN: its jawn is down, so waiting
	# the full grace just strands the watch. A restart flips the row back to active
	# within seconds, so this short wait rides that out without handing the watch
	# over on a blip.
	return 180000;
}

sub ble_homebase_sighting() {
	# The device's homebase as the mesh last knew it: the newest of its peer rows
	# (server_time) and whether that row was active. Held as a high-water mark per
	# (homebase, chip): the row flickers - a sync gap briefly serves a stale copy -
	# and a single stale read must not make a live homebase look gone, because that
	# flip is what let a second machine connect and steal the link. Keyed by the
	# homebase id, so a re-home to a fresh machine starts from its own row. undef
	# means no row names the machine, which the caller reads as alive.
	my ($edt, $chip_id) = @_;
	my $who = &ble_device_specs($edt, $chip_id)->{'computer'};
	return undef unless $who;
	my $key = $who . '|' . ($edt || 'watch') . '|' . $chip_id;
	my ($seen, $active);
	foreach my $rm ( @{ &subs::db_select('remote_machines')->hashes } ) {
		next unless &ble_machine_match($rm->{'manager_file'}, $who);
		my $t = ($rm->{'server_time'} || 0) + 0;
		next unless $t;
		if (!defined $seen || $t > $seen) {
			$seen = $t;
			$active = (($rm->{'connection'} || '') eq 'active') ? 1 : 0;
		}
	}
	return undef unless defined $seen;
	my $c = $gb::ble_hb_seen->{$key};
	$gb::ble_hb_seen->{$key} = [ $seen, $active ] if !$c || $seen > $c->[0];
	return $gb::ble_hb_seen->{$key};
}

sub ble_homebase_alive() {
	# Has the machine the device was paired to been gone long enough to stop
	# waiting for it? Its own peer row is the authority - not a ping of the address
	# it last had, which was wrong the moment that machine left the LAN (a phone on
	# cellular). A sighting counts until it is older than the grace: a deliberate
	# stop waits the short one, a homebase merely off the LAN (still marked active)
	# the long one. A record that names no machine, or names one we hold no
	# sighting for, is assumed alive, so we never usurp a homebase we cannot judge.
	my ($edt, $chip_id) = @_;
	return 1 unless &ble_device_specs($edt, $chip_id)->{'computer'};
	my $seen = &ble_homebase_sighting($edt, $chip_id);
	return 1 unless defined $seen;
	my $grace = $seen->[1] ? &ble_fallback_grace() : &ble_fallback_stop_grace();
	return ((&subs::rightNow() - $seen->[0]) < $grace) ? 1 : 0;
}

sub ble_may_serve() {
	# May this machine hold/serve the device's link right now? Its homebase may,
	# always: the watch stays on the machine it was paired to for as long as that
	# machine is on the mesh, which is what the person asked for. Only when the
	# homebase has dropped off the mesh may another machine take the watch over,
	# so a dead phone does not strand it. That machine serves WITHOUT re-homing,
	# so the stored pairing is untouched and the phone reclaims the watch the
	# moment its row comes back.
	my ($edt, $chip_id) = @_;
	return 1 if &ble_owns($edt, $chip_id);
	return 0 if &ble_homebase_alive($edt, $chip_id);
	return 1;
}

sub ble_chip_by_mac() {
	# The chip a radio address belongs to, from the sightings every machine
	# keeps; used to name the device the bridge just linked to.
	my ($mac) = @_;
	return undef unless $mac;
	foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
		next unless $d->{'chip_ids'};
		foreach my $c ( @{ (eval { decode_json $d->{'chip_ids'} } || []) } ) {
			return $c if $c->{'bluetooth'} && &ble_link_key($c->{'bluetooth'}) eq &ble_link_key($mac);
		}
	}
	return undef;
}

sub ble_chip_record() {
	# A chip id -> its fleet record (purpose, radio address, name), from any
	# machine's devices row. The relay router needs the purpose to apply the
	# same homebase rule as an ordinary send.
	my ($chip_id) = @_;
	return undef unless $chip_id;
	foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
		next unless $d->{'chip_ids'};
		foreach my $c ( @{ (eval { decode_json $d->{'chip_ids'} } || []) } ) {
			next unless $c->{'id'} && $c->{'id'} eq $chip_id;
			return { %{$c}, hostname => $d->{'hostname'} };
		}
	}
	return undef;
}

sub ble_relay_route {
	# Carry one device's message to another device (star-of-stars mesh).
	#
	# A watch on a phone's bridge can reach a board on the desktop's bridge: the
	# machine that heard the relay looks up the target, sends it over its own
	# bridge when it may serve that chip, and otherwise hands the same envelope to
	# every active peer. Only the machine allowed to serve the target sends it, so
	# the broadcast needs no homebase lookup and no reply.
	#
	# Envelope: {type:"relay", to:"<chip>", from:"<chip>", id:"<unique>",
	#            hops:N, message:{...}}
	# Loop protection is the message id plus a small hop budget.
	my ($relay, $opts) = @_;
	$opts ||= {};
	return 0 unless ref $relay eq 'HASH' && ($relay->{'type'} || '') eq 'relay';
	my $to = $relay->{'to'};
	my $inner = $relay->{'message'};
	return 0 unless $to && ref $inner eq 'HASH';
	my $hops = 0 + ($relay->{'hops'} || 0);
	return 0 if $hops > 6;
	my $id = $relay->{'id'} || &random_string_creator(18);
	my $now = time();
	foreach my $seen ( keys %{ $gb::ble_relay_seen || {} } ) {
		delete $gb::ble_relay_seen->{$seen} if $now - $gb::ble_relay_seen->{$seen} > 300;
	}
	return 0 if $gb::ble_relay_seen->{$id};
	$gb::ble_relay_seen->{$id} = $now;
	my $from = $relay->{'from'} || '';
	# addressed back to the sender: a loop, not a delivery
	return 0 if $from && $to eq $from;
	my $chip = &ble_chip_record($to);
	return 0 unless $chip && $chip->{'id'};
	my $edt = $chip->{'purpose'} || 'watch';
	my $envelope = {
		type => 'relay',
		from => $from,
		id => $id,
		hops => $hops + 1,
		message => $inner
	};
	if (&ble_may_serve($edt, $to) && $chip->{'bluetooth'}) {
		$log->info('BLE relay ' . ($from || '?') . ' -> ' . $to . ' (' . $edt . '), hop ' . ($hops + 1));
		&bluetooth_sender({
			intent => 'com.jawn.president.bt.connect',
			chip_id => $to,
			edt => $edt,
			message => $envelope
		});
		return 1;
	}
	return 0 if $opts->{'from_mesh'};
	my $me = &signatorial_designer();
	my $payload = encode_json({ %{$envelope}, to => $to });
	my $sent = 0;
	foreach my $rm ( @{ &remote_machine_lister({ connection => 'active' }) || [] } ) {
		next unless ref $rm eq 'HASH';
		my $sig = $rm->{'signatorial'} || '';
		next if !$sig || $sig eq $me;
		next unless $rm->{'ip'};
		my $hop = &Manager::remote_useragent_maker({ rm => $rm, signatorial => $sig });
		next unless $hop && $hop->{'ua'} && $hop->{'manager'};
		my $res = eval {
			$hop->{'ua'}->insecure(1)->inactivity_timeout(10)->post(
				$hop->{'manager'} . '/manager/ble/relay' => form => { payload => $payload }
			)->result;
		};
		$sent++ if $res && eval { $res->is_success };
	}
	$log->info('BLE relay ' . ($from || '?') . ' -> ' . $to . ': offered to ' . $sent . ' peer(s)') if $sent;
	return $sent ? 1 : 0;
}

sub ble_yield() {
	# Hand a device that calls another machine home back to it: drop that
	# device's link so the homebase's bridge can take it. With several links in
	# one bridge the yield must name the radio - disconnecting the whole bridge
	# would drop a deck or board this machine is allowed to serve. Rate-limited
	# per chip, and run off the read loop so a flapping bridge cannot stall the
	# listener.
	my ($chip_id, $mac) = @_;
	return unless $chip_id;
	$mac ||= &ble_mac_for_chip($chip_id);
	my $now = &subs::rightNow();
	return if $gb::ble_yield_at->{$chip_id} && $now - $gb::ble_yield_at->{$chip_id} < 30000;
	$gb::ble_yield_at->{$chip_id} = $now;
	my $client = &ble_bridge_client();
	return unless $client;
	# If a MAC is named, make sure it really is this chip's radio before
	# releasing it; an unknown address must not take another link down.
	if ($mac) {
		my $linked = &ble_chip_by_mac($mac);
		return if $linked && $linked->{'id'} && $linked->{'id'} ne $chip_id;
	}
	$log->info('BLE yield ' . $chip_id . ($mac ? ' (' . $mac . ')' : '') . ': not its homebase, releasing that link');
	&subs::subprocessor(sub {
		if ($mac) { system($client, 'disconnect', $mac); }
		else { system($client, 'disconnect', '--all'); }
	}, { name => 'ble yield' });
}

sub ble_enforce_hosts() {
	# Keep every machine on the right side of every link. The bridge daemons now
	# hold several radios at once (v2), so this pass is per device: connect the
	# ones this machine may serve, release the ones it may not, and leave a link
	# the daemon is already chasing alone. A v1 daemon still works - it accepts
	# the first connect and ignores the rest; its status reports one link.
	#   may serve  -> make sure that radio's link is up (connect; a no-op if it is)
	#   may not    -> release that radio and stop chasing it
	return unless &ble_bridge_capable() && &ble_bridge_enabled();
	my $client = &ble_bridge_client() || return;
	my $links = &ble_links();
	my %done;
	foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
		next unless $d->{'chip_ids'};
		foreach my $c ( @{ (eval { decode_json $d->{'chip_ids'} } || []) } ) {
			next unless $c->{'id'} && $c->{'bluetooth'};
			next if $done{ $c->{'id'} }++;
			my $mac = &ble_link_key($c->{'bluetooth'});
			my $edt = $c->{'purpose'} || 'watch';
			my $link = $links->{$mac};
			if (&ble_may_serve($edt, $c->{'id'})) {
				next if $link && $link->{'connected'};
				# the daemon is already reconnecting this radio; do not issue a
				# second connect every minute and reset its backoff
				next if $link && ($link->{'state'} || '') =~ /^(?:connecting|reconnecting)$/;
				my $now = time();
				next if $gb::ble_connect_at->{$mac} && $now - $gb::ble_connect_at->{$mac} < 60;
				$gb::ble_connect_at->{$mac} = $now;
				my $u = &ble_nus_uuids();
				# Always name the service and characteristics. A bare connect
				# overwrites the daemon's stored target, and the Android bridge keeps
				# only mac+mtu from it: with no uuids saved it can no longer find the
				# watch's characteristics and the link fails forever (this is what
				# made the phone bounce). So never connect without them.
				# A board's role payload is plain JSON; only the watch/deck get the
				# compressed room pushes.
				my $compress = ($edt eq 'microcontroller') ? '0' : '1';
				&subs::subprocessor(sub {
					system($client, 'connect', $mac,
						'--service', $u->{'service_uuid'},
						'--rx', $u->{'characteristic_uuid_rx'},
						'--tx', $u->{'characteristic_uuid_tx'},
						'--mtu', '512',
						'--compress', $compress);
				}, { name => 'ble host connect' });
			}
			elsif ($link && $link->{'connected'}) {
				&ble_yield($c->{'id'}, $mac);
			}
		}
	}
	# A radio linked right now is present, whatever its last payload said: a
	# watch speaks only on connect and on steps, so its own messages can be hours
	# apart and its sighting would age out of the Embedded list while it sits
	# connected. Refresh every link this machine may serve.
	foreach my $mac ( keys %{$links} ) {
		next unless $links->{$mac} && $links->{$mac}->{'connected'};
		my $linked = &ble_chip_by_mac($mac);
		next unless $linked && $linked->{'id'};
		next unless &ble_may_serve($linked->{'purpose'} || 'watch', $linked->{'id'});
		&ble_device_record({
			chip_id => $linked->{'id'},
			edt => $linked->{'purpose'} || 'watch',
			name => $linked->{'name'},
			mac => $mac
		});
	}
}

sub ble_adopt_scan() {
	# A device that has never been on WiFi cannot be named by mDNS and the tree
	# holds no address for it, so nothing ever connects and it can never introduce
	# itself - a fresh deck is invisible however long it sits on the desk. Find it
	# by radio instead. A JawnOS device carries a "JW" manufacturer-data payload
	# (company 0xFFFF) with its chip id and purpose, so it is recognized even when
	# it advertises a custom service; older firmware is still met by its Nordic
	# UART service uuid. Connect to it and its own state_request records it
	# (ble_message_processor -> ble_device_record), after which the ordinary host
	# rule bridges it - the "plug it in and it is known" path, with no wifi at all.
	# With the multi-link bridge, every unknown JawnOS device in the room is met,
	# not just the first; the daemon's MAX_LINKS cap is the limit.
	return unless &ble_bridge_capable() && &ble_bridge_enabled();
	my $client = &ble_bridge_client() or return;
	my $nus = lc &ble_nus_uuids()->{'service_uuid'};
	# every Bluetooth address we already hold, so only the unknown is chased
	my %known;
	foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
		next unless $d->{'chip_ids'};
		foreach my $c ( @{ (eval { decode_json $d->{'chip_ids'} } || []) } ) {
			$known{ &ble_link_key($c->{'bluetooth'}) } = 1 if $c->{'bluetooth'};
		}
	}
	my $out = `timeout 25 $client scan 8 2>/dev/null`;
	my @found;
	my %seen;
	foreach my $line (split "\n", $out) {
		my $e = eval { decode_json $line };
		next unless $e && ref $e eq 'HASH' && ($e->{'event'} || '') eq 'scan';
		my $mac = &ble_link_key($e->{'mac'});
		next unless $mac =~ /^(?:[0-9A-F]{2}){6}$/;
		# The device names itself in the scan response: record the sighting now,
		# even before a link exists, and note the radio address it currently uses
		# (a board that was re-flashed may come back on a new address).
		my ($mf_chip, $mf_purpose) = &ble_manufacturer_identity($e->{'manufacturer_data'});
		if ($mf_chip) {
			next if $seen{$mac}++;
			# Only write the sighting when the radio address is new (a re-flashed
			# board may come back on a different one). Otherwise this scan would
			# rewrite every known device's row every 30 seconds and churn the mesh
			# sync for nothing.
			my $recorded = &ble_chip_record($mf_chip);
			my $same_mac = $recorded && $recorded->{'bluetooth'} &&
				&ble_link_key($recorded->{'bluetooth'}) eq $mac;
			&ble_device_record({ chip_id => $mf_chip, edt => $mf_purpose, mac => $mac }) unless $same_mac;
			# Meet it only when this machine may hold its link. A device whose
			# homebase is another machine is left for that homebase (adopting it
			# here would steal the link, which is the tug-of-war the homebase rule
			# exists to prevent).
			my $edt = $mf_purpose || ($recorded && $recorded->{'purpose'}) || 'watch';
			push @found, { mac => $mac, chip_id => $mf_chip, purpose => $edt } if &ble_may_serve($edt, $mf_chip);
			next;
		}
		next if $known{$mac} || $seen{$mac}++;
		next unless grep { lc($_) eq $nus } @{ $e->{'uuids'} || [] };
		push @found, { mac => $mac };
	}
	return unless @found;
	my $now = time();
	my $u = &ble_nus_uuids();
	foreach my $f ( @found ) {
		my $mac = ref $f eq 'HASH' ? $f->{'mac'} : $f;
		# already linked, or we tried it recently and it stayed silent (a device
		# that speaks NUS but is not ours): leave that radio alone
		next if $gb::ble_links->{$mac} && $gb::ble_links->{$mac}->{'connected'};
		next if $gb::ble_adopt_tried->{$mac} && $now - $gb::ble_adopt_tried->{$mac} < 600;
		$gb::ble_adopt_tried->{$mac} = $now;
		$log->info('BLE adopt: a JawnOS device at ' . $mac . ' is not yet known; connecting so it can name itself');
		&subs::subprocessor(sub {
			system($client, 'connect', $mac,
				'--service', $u->{'service_uuid'},
				'--rx', $u->{'characteristic_uuid_rx'},
				'--tx', $u->{'characteristic_uuid_tx'},
				'--mtu', '512');
		}, { name => 'ble adopt connect' });
	}
}

sub ble_manufacturer_identity {
	# Read the JawnOS manufacturer-data payload from a scan event.
	#
	# Layout (after the 2-byte company id, 0xFFFF):
	#   "JW"  version  flags  purpose  chip_id-as-ASCII
	# purpose: 1 watch, 2 teletype, 3 microcontroller, 4 music, 0 unknown.
	# flags bit0 marks a device that can relay for the mesh.
	# Returns (chip_id, purpose) or () when this is not one of ours.
	my ($mfd) = @_;
	return () unless ref $mfd eq 'HASH';
	my %purpose = (1 => 'watch', 2 => 'teletype', 3 => 'microcontroller', 4 => 'music');
	foreach my $company ( keys %{$mfd} ) {
		my $hex = $mfd->{$company};
		next unless defined $hex;
		$hex =~ s/[^0-9a-fA-F]//g;
		next unless length($hex) >= 12;   # magic+version+flags+purpose + 1 byte chip
		my $raw = pack('H*', substr($hex, 0, length($hex) - (length($hex) % 2)));
		next unless substr($raw, 0, 2) eq 'JW';
		next unless ord(substr($raw, 2, 1)) == 1;
		my $code = ord(substr($raw, 4, 1));
		my $chip = substr($raw, 5);
		$chip =~ s/[^A-Za-z0-9._-]//g;
		next unless length $chip;
		return ($chip, $purpose{$code} || 'watch');
	}
	return ();
}

sub ble_nus_uuids() {
	# The Nordic UART service the watch and boards advertise (see jw/jw.ino). A
	# device recorded only over Bluetooth never answered a /device_query with its
	# own constants, so its bridge link is opened with these fixed defaults.
	return {
		service_uuid           => '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
		characteristic_uuid_rx => '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
		characteristic_uuid_tx => '6e400003-b5a3-f393-e0a9-e50e24dcca9e'
	};
}

sub ble_device_record() {
	# Remember an embedded device seen over the Bluetooth bridge, so it can be
	# listed in the Embedded app while it is off its access point. The sighting
	# lives in this machine's own `devices` row - the chip_ids blob device_scan
	# already keeps and syncs - so an entry added here outlives the next scan
	# (its oldchips merge keeps it) and reaches the other machines with the row.
	my $data = shift;
	my $chip_id = $data->{'chip_id'} || return;
	my $edt = $data->{'edt'} || 'watch';
	my $now = &subs::rightNow();
	my $hostname = $gb::ble_hostname;
	unless ($hostname) {
		$hostname = `hostname`;
		chomp $hostname;
		$gb::ble_hostname = $hostname;
	}
	my $row;
	foreach my $r ( @{ &subs::db_select('devices')->hashes } ) {
		my $h = $r->{'hostname'} || '';
		$h =~ s/\s+$//;
		if ($h eq $hostname) { $row = $r; last; }
	}
	my $chips = ($row && $row->{'chip_ids'}) ? (eval { decode_json $row->{'chip_ids'} } || []) : [];
	my $found;
	foreach my $c ( @{$chips} ) {
		next unless $c->{'id'} && $c->{'id'} eq $chip_id;
		$found = $c;
		last;
	}
	unless ($found) {
		$found = { id => $chip_id };
		push @{$chips}, $found;
	}
	my $name = $data->{'name'};
	if (!$name && !($found && $found->{'name'})) {
		my $od = &subs::embedded_operator_door($edt, $chip_id);
		my $op_d = eval { decode_json $od } || {};
		$name = $op_d->{'__specs'}->{'name'};
	}
	$found->{'name'} = $name if $name;
	$found->{'purpose'} = $edt;
	$found->{'bluetooth'} = $data->{'mac'} if $data->{'mac'};
	$found->{'ble'} = 1;
	$found->{'ble_seen'} = $now;
	$found->{'server_time'} = $now;
	my $json = encode_json $chips;
	if ($row) {
		&subs::db_update('devices', { chip_ids => $json }, { hostname => $row->{'hostname'} });
	}
	else {
		# A machine that never ran a scan still has to carry the sighting, or a
		# Bluetooth-only fleet could not be listed at all.
		&subs::db_insert('devices', {
			hostname => $hostname,
			address => '{}',
			chip_ids => $json,
			server_time => $now,
			timestamp => $now,
			uuid => &subs::random_string_creator(25)
		});
	}
	return $found;
}

sub ble_device_from_chip() {
	# Build the device row device_lister hands its callers, from a chip the
	# bridge saw. It carries what the Embedded panel and a Now Me need: the
	# Bluetooth address to reach it, the link's fixed service uuids, and this
	# machine as the homebase (the watch has no address of its own off its LAN).
	my ($chip, $load_type) = @_;
	my $addrs = &subs::network_interface_reporter();
	my ($my_ip) = map { $addrs->{$_}->{'ip'} }
		grep { $addrs->{$_}->{'ip'} && $addrs->{$_}->{'ip'} !~ /^127\./ } keys %{$addrs};
	$my_ip ||= '127.0.0.1';
	my $dev = {
		chip_id => $chip->{'id'},
		name => $chip->{'name'},
		purpose => $chip->{'purpose'} || $load_type,
		edt => $chip->{'purpose'} || $load_type,
		ble => 1,
		# no address of its own: a Bluetooth-only device has none, and leaving ip
		# empty is also what makes now_me skip the LAN ping and take the bridge
		# (homebase still names this machine, where the bridge lives).
		homebase => $my_ip,
		mac => $chip->{'bluetooth'},
		mac_addresses => { bluetooth => $chip->{'bluetooth'} },
		%{ &ble_nus_uuids() }
	};
	return $dev;
}

# The Bluetooth devices the bridge has seen, for the Dev panel. A BLE-only device
# off its access point is in no machine's neighbour table, so the network listing
# never shows it; the bridge records each sighting in a machine's `chip_ids`
# (ble_device_record), which device_lister already falls back to for the Embedded
# app. Same source here: one row per chip, the freshest sighting, and only while
# the presence window still holds - so a headless hub (or any machine with no
# browser scan) still lists the fleet's radios.
sub ble_device_listing() {
	my $window = &ble_presence_window();
	my $now = &subs::rightNow();
	my %seen;
	foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
		next unless $d->{'chip_ids'};
		my $chips = eval { decode_json $d->{'chip_ids'} } || [];
		foreach my $c ( @{$chips} ) {
			next unless $c->{'id'} && ($c->{'ble'} || $c->{'bluetooth'});
			next unless $window > $now - ($c->{'ble_seen'} || 0);
			my $id = $c->{'id'};
			next if $seen{$id} && ($seen{$id}->{'ble_seen'} || 0) >= ($c->{'ble_seen'} || 0);
			$seen{$id} = { %{$c}, hostname => $d->{'hostname'} };
		}
	}
	my @rows = map {
		my $c = $seen{$_};
		$c->{'seen_display'} = &subs::formatted_time($c->{'ble_seen'}) if $c->{'ble_seen'};
		$c;
	} keys %seen;
	return [ sort { ($a->{'name'} || $a->{'id'}) cmp ($b->{'name'} || $b->{'id'}) } @rows ];
}

sub bluetooth_sender() {
	my $data = shift;
	return unless $data->{'intent'} && $data->{'chip_id'} && $data->{'edt'} && &subs::ble_bridge_capable();
	# Only the device's homebase may drive the bridge - or, once the homebase has
	# gone quiet past the grace, a machine taking it over. Another machine
	# connecting would steal the single link (and the person's taps with it). This
	# is also what stops every machine answering a toggle-changed broadcast with
	# its own connect.
	return unless &ble_may_serve($data->{'edt'}, $data->{'chip_id'});
	my $intent = $data->{'intent'};
	my $message = $data->{'message'};
	my $embedded = &subs::device_lister(&subs::rightNow(),$data->{'edt'},undef,$data->{'chip_id'});
	# The link's service and characteristics: use what the device record carries,
	# but fall back to the Nordic UART uuids the watch and boards advertise, so a
	# connect is never issued without them (a bare one clears the daemon's saved
	# target, and then its link can never be found again).
	my $ble_uuids = &ble_nus_uuids();
	my $service_uuid = $embedded->{'service_uuid'} || $ble_uuids->{'service_uuid'};
	my $characteristic_uuid_rx = $embedded->{'characteristic_uuid_rx'} || $ble_uuids->{'characteristic_uuid_rx'};
	my $characteristic_uuid_tx = $embedded->{'characteristic_uuid_tx'} || $ble_uuids->{'characteristic_uuid_tx'};
	if ($embedded->{'mac_addresses'}->{'bluetooth'}) {
		my $bt_mac = $embedded->{'mac_addresses'}->{'bluetooth'};
		my $name = $embedded->{'name'};
		my $json = encode_json $message;
		my $client = &ble_bridge_client();
		if (&ble_bridge_enabled() && $client) {
			# Ask for this MAC's link, not "the" link. The daemons hold several now;
			# the connect is a no-op when that radio is already up and only that
			# radio is retargeted otherwise. A board's role payload is plain JSON
			# (compress 0); the watch and deck keep the compressed room pushes.
			my $link = $gb::ble_links->{ &ble_link_key($bt_mac) };
			my $compress = (($data->{'edt'} || '') eq 'microcontroller') ? '0' : '1';
			unless ($link && $link->{'connected'}) {
				system($client, 'connect', $bt_mac, '--service', $service_uuid, '--rx', $characteristic_uuid_rx, '--tx', $characteristic_uuid_tx, '--mtu', '512', '--compress', $compress);
			}
			# The client hands the JSON to the daemon as-is and the daemon writes
			# it to the selected radio. Base64 is only for the old broadcast path;
			# the client used to receive the encoded copy and the watch got a
			# base64 blob it could not parse.
			open(my $bt_fh, '|-', $client, 'send', '--mac', $bt_mac) or return;
			print {$bt_fh} $json;
			return close $bt_fh;
		}
		my $b64 = encode_base64 $json;
		my $cmd = "am broadcast --user 0 -a $intent -e mac_address '$bt_mac' -e message '$b64' -e name '$name' -e service_uuid '$service_uuid' -e characteristic_uuid_rx '$characteristic_uuid_rx' -e characteristic_uuid_tx '$characteristic_uuid_tx'";
		return `$cmd`;
	}
}

# One bridge connection for a run of messages, for a streamed reply: the daemon
# reads command lines per connection, so a dozen parts ride one client process
# instead of starting one per part (a perl start each time, on a phone, costs
# more than the audio). Returns a filehandle to print message JSON lines to, or
# undef when this machine may not drive the bridge. The caller closes it.
sub bluetooth_stream_open() {
	my $data = shift;
	return undef unless $data->{'intent'} && $data->{'chip_id'} && $data->{'edt'} && &subs::ble_bridge_capable();
	# the same homebase-only rule as bluetooth_sender: one link, and it must not
	# be stolen by a machine the watch merely passed by
	return undef unless &ble_may_serve($data->{'edt'}, $data->{'chip_id'});
	my $embedded = &subs::device_lister(&subs::rightNow(), $data->{'edt'}, undef, $data->{'chip_id'});
	my $bt_mac = $embedded->{'mac_addresses'}->{'bluetooth'} or return undef;
	my $ble_uuids = &ble_nus_uuids();
	my $service_uuid = $embedded->{'service_uuid'} || $ble_uuids->{'service_uuid'};
	my $rx = $embedded->{'characteristic_uuid_rx'} || $ble_uuids->{'characteristic_uuid_rx'};
	my $tx = $embedded->{'characteristic_uuid_tx'} || $ble_uuids->{'characteristic_uuid_tx'};
	my $client = &ble_bridge_client() or return undef;
	return undef unless &ble_bridge_enabled() && $client;
	my $link = $gb::ble_links->{ &ble_link_key($bt_mac) };
	unless ($link && $link->{'connected'}) {
		system($client, 'connect', $bt_mac, '--service', $service_uuid, '--rx', $rx, '--tx', $tx, '--mtu', '512', '--compress', '1');
	}
	my $fh;
	open($fh, '|-', $client, 'sendloop', '--mac', $bt_mac) or return undef;
	return $fh;
}

sub board_config_payload() {
	# The compact role payload a board needs over Bluetooth or USB. It is the
	# room payload without the parts only a watch/deck uses (the chat lists and
	# the pairing patience), so it stays small enough to send uncompressed and
	# carries everything call_the_president() rebuilds: the component map and
	# __specs.internal_jobs. Top-level keys for a microcontroller are the full
	# component names (led0, relay28, switch15, ...).
	my $payload = &watch_room_payload(shift) or return undef;
	delete $payload->{'__shutup'};
	delete $payload->{'__specs'}->{'chat'};
	return $payload;
}

sub watch_room_payload() {
	# The same picture watch.pl's /watch route renders, built in-process so the
	# bridge can push it over BLE (the route itself needs an HTTP request).
	my $data = shift;
	my $edt = $data->{'edt'} || 'watch';
	my $chip_id = $data->{'chip_id'};
	my $od = &subs::embedded_operator_door($edt, $chip_id);
	my $watch_settings = eval { decode_json $od } || {};
	return undef unless $watch_settings->{'__specs'};
	foreach my $k ( keys %{$watch_settings} ) {
		next unless $watch_settings->{$k}->{'app'};
		$watch_settings->{$k}->{'toggle'} = &subs::setting_grabber({ app => $watch_settings->{$k}->{'app'}, setting => 'toggle' }) eq 'on' ? 1 : 0;
	}
	$watch_settings = &subs::embedded_internal_jobs($watch_settings);
	return $watch_settings;
}

sub watch_toggle_pusher() {
	# A toggle changed somewhere. While the watch is awake and connected this
	# lights its button up right away; a watch that slept through it asks for
	# the whole picture on its next state_request.
	my $data = shift;
	# the capability probe connects to the bridge's loopback; leave it to the
	# worker with the rest of the discovery
	return unless &subs::ble_bridge_enabled();
	my $app = $data->{'app'} || return;
	my $state = ($data->{'value'} || '') eq 'on' ? 'on' : 'off';
	# The device walk is the expensive half (it reads every sighting and, for a
	# BLE-only device, asks for this machine's address), so it belongs in the
	# worker: the request that changed the toggle must not wait on the bridge.
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		return unless &subs::ble_bridge_capable();
		# A toggle change reaches every embedded device that draws an app button:
		# the watch/deck light their button, and a board applies the app's new
		# state to the relays/LEDs wired to it. The bridge can carry several links
		# now, so this used to stop at the first device; keep one target per
		# (edt, chip).
		my @targets;
		my %seen;
		foreach my $edt ( qw/watch teletype microcontroller/ ) {
			my $devices = &subs::device_lister(&subs::rightNow(), $edt, undef, 'all');
			next unless ref $devices eq 'ARRAY';
			foreach my $w ( @{$devices} ) {
				next unless ref $w eq 'HASH' && $w->{'chip_id'};
				next if $seen{ $edt . '|' . $w->{'chip_id'} }++;
				push @targets, { chip_id => $w->{'chip_id'}, edt => $edt };
			}
		}
		return unless scalar @targets;
		foreach my $t ( @targets ) {
			&subs::bluetooth_sender({
				intent => 'com.jawn.president.bt.connect',
				chip_id => $t->{'chip_id'},
				edt => $t->{'edt'},
				message => { type => 'toggle', data => { app => $app, state => $state } }
			});
		}
	}, { name => 'embedded toggle push' });
}

sub ble_rehome_check() {
	# A watch that has bridged to a machine that is not its homebase must not be
	# kept there while the homebase is up: it is a one-link peripheral, so holding
	# it steals it from the machine the person paired it to. Yield it. A machine
	# serving as the FALLBACK (the homebase has gone quiet) serves on, but never
	# re-homes - the person wants the watch to come back to the phone, so the
	# stored homebase must stay the phone. Only when this machine IS the homebase
	# is there anything to fix: a watch whose own idea of its homebase has drifted
	# from the record. Re-home it to itself by pushing now_me over the link, which
	# rewrites the watch's homebase, rotates the authorization its tap urls carry,
	# and carries the screen timeout (so an idle watch stops dropping the link).
	my ($edt, $chip_id, $reported) = @_;
	return unless $edt && $chip_id && &subs::ble_bridge_capable();
	unless (&ble_may_serve($edt, $chip_id)) {
		&ble_yield($chip_id);
		return;
	}
	return unless &ble_owns($edt, $chip_id);
	# The watch's *own* homebase, as it reports it: the stored operator_door
	# specs can already name this machine while the watch still points
	# elsewhere (a push that never landed left them out of step), so the compare
	# must trust the watch, not the record.
	my $stored = $reported;
	my $stored_host = $stored;
	$stored_host =~ s/:\d+$// if defined $stored_host;
	# "this machine" cannot be device_lister(): on a shared LAN several machines
	# list the watch as a neighbour and it returns whichever it scans first. So
	# use our own interfaces and take the one on the watch's subnet (the stored
	# homebase names that subnet). The address is handed to now_me explicitly,
	# because now_me's own choice trusts the watch's LAN, where every machine
	# here shares a /24 and cannot be told apart.
	my $addrs = &subs::network_interface_reporter();
	my @ips = grep { $_ && $_ !~ /^127\./ } map { $addrs->{$_}->{'ip'} } keys %{$addrs};
	return unless scalar @ips;
	my ($mine_ip) = grep { $stored_host && &subs::same_net_test($_, $stored_host, '127.0.0.1') eq 'yes' } @ips;
	$mine_ip ||= $ips[0];
	return if defined $stored_host && $stored_host eq $mine_ip;
	my $now = &subs::rightNow();
	$gb::ble_rehome_at ||= {};
	return if $gb::ble_rehome_at->{$chip_id} && $now - $gb::ble_rehome_at->{$chip_id} < 60000;
	$gb::ble_rehome_at->{$chip_id} = $now;
	$log->info('BLE re-home ' . $chip_id . ' from ' . ($stored || '?') . ' to ' . $mine_ip . ':' . ($ENV{'PORT_ARM'} || '?'));
	# never let a re-home abort the listener's read loop: a throw here used to
	# take the whole fork (and with it the watch -> jawn path) down
	eval {
		&Manager::now_me({
			edt => $edt,
			chip_id => $chip_id,
			method => 'bluetooth',
			timestamp => $now,
			homebase => $mine_ip,
			ip => $mine_ip
		});
		1;
	} or $log->error('BLE re-home failed: ' . $@);
}

# Speech -> text through a cloud model. The transcription model (Configure -> Plat)
# is either Cloudflare's @cf/openai/whisper or an OpenAI-compatible /audio/
# transcriptions endpoint (Groq whisper-large-v3*, OpenAI whisper-1). '' on any
# failure, so the caller falls back to the local whisper.cpp pipeline.
sub ai_transcribe_cloud {
	my ($model, $raw) = @_;
	return '' unless $model && defined $raw && length $raw;
	my @key_settings = &subs::ai_key_settings();
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'cloudflare_account', 'cloudflare_token', @key_settings ] });
	my $suds = &subs::suds_grabber();
	my $secret = sub {
		my $v = shift;
		return '' unless defined $v && length $v;
		my $d = eval { &subs::note_decrypter($suds, $v) };
		return ($d && length $d) ? $d : $v;
	};
	my $ua = Mojo::UserAgent->new(connect_timeout => 6, inactivity_timeout => 30, request_timeout => 45);
	if ($model =~ /^\@cf/) {
		my $account = $settings->{'cloudflare_account'};
		my $token = $secret->($settings->{'cloudflare_token'});
		return '' unless $account && $token;
		my $tx = $ua->post('https://api.cloudflare.com/client/v4/accounts/' . $account . '/ai/run/' . $model => {
			'Authorization' => 'Bearer ' . $token,
			'Content-Type' => 'application/json'
		} => json => { audio => encode_base64($raw, '') });
		return '' if $tx->error || !$tx->res->is_success;
		my $d = eval { $tx->res->json } || {};
		my $text = $d->{'result'}->{'text'} || $d->{'result'}->{'transcription'} || $d->{'result'};
		$text = '' if ref $text;
		return ($text || '');
	}
	# openai-compatible transcription: groq, openai, mistral (any provider whose
	# /audio/transcriptions speaks the same multipart shape)
	my ($provider, $real) = ('groq', $model);
	if ($model =~ /^([a-z]+):(.+)$/) { ($provider, $real) = ($1, $2); }
	my %ep = ( openai => 'https://api.openai.com/v1/audio/transcriptions', groq => 'https://api.groq.com/openai/v1/audio/transcriptions' );
	my $url = $ep{$provider} or return '';
	my %key = ( openai => 'openai_key', groq => 'groq_key' );
	my $key = $secret->($settings->{ $key{$provider} });
	return '' unless $key;
	my $tx = $ua->post($url => {
		'Authorization' => 'Bearer ' . $key
	} => form => {
		model => $real,
		file => { content => $raw, filename => 'clip.webm', 'Content-Type' => 'audio/webm' },
		response_format => 'json'
	});
	return '' if $tx->error || !$tx->res->is_success;
	my $d = eval { $tx->res->json } || {};
	return ($d->{'text'} || '');
}

sub voice_silence_hallucination() {
	# Both transcribers invent a stock phrase when a clip said nothing: whisper.cpp
	# writes "Thank you." and the cloud models "Thanks for watching!" - the well
	# known silence hallucinations. Near-empty clips do happen (a wake phrase that
	# no command followed, and whatever the phone's listener sends), and a
	# transcript that is nothing but one of these is silence, not speech. Without
	# saying so, the guide associate answers a sentence nobody spoke - which is
	# exactly the "it always thinks I said thank you" reply.
	#
	# Only a transcript that is *entirely* one of them counts. A lone word can never
	# be acted on anyway - voice_command_parse needs a verb and a target, and
	# voice_note_store wants three words - so trimming these costs nothing.
	my ($text) = @_;
	return 0 unless defined $text && length $text;
	my $bare = lc $text;
	$bare =~ s/[\[\(][^\]\)]*[\]\)]//g;   # [BLANK_AUDIO], (music), [ Silence ]
	$bare =~ s/[^a-z0-9' ]+/ /g;
	$bare =~ s/\s+/ /g;
	$bare =~ s/^\s+|\s+$//g;
	return 1 unless length $bare;
	my %stock = map { $_ => 1 } (
		'thank you', 'thanks', 'thank you very much', 'thanks very much',
		'thank you so much', 'thanks a lot', 'many thanks', 'thank you thank you',
		'thank you for watching', 'thanks for watching',
		'thank you for watching everyone', 'thanks for watching everyone',
		'thank you for watching this video', 'thanks for watching this video',
		'thank you so much for watching', 'thanks for watching and see you next time',
		'please subscribe', 'please like and subscribe', 'like and subscribe',
		'subscribe to my channel', 'please subscribe to my channel',
		'you', 'yeah', 'yep', 'okay', 'ok', 'hmm', 'mm hmm', 'uh huh',
		'bye', 'bye bye', 'goodbye', 'the end', 'that is it', 'so', 'oh',
	);
	return $stock{$bare} ? 1 : 0;
}

sub whisper_transcribe() {
	# Speech -> text. A cloud transcription model (Configure -> Plat) answers
	# first, so the phone's slow whisper.cpp is the fallback rather than the
	# whole path. Raw audio bytes in (any container ffmpeg reads), the transcript
	# out. '' on any failure, so a caller only has to check for text.
	my ($raw) = @_;
	return '' unless $raw;
	my ($primary, $fallback) = &ai_role_models('transcription_assistant');
	foreach my $m ( grep { $_ } ($primary, $fallback) ) {
		my $text = &ai_transcribe_cloud($m, $raw);
		next if $text && &subs::voice_silence_hallucination($text);
		return $text if $text;
	}
	require IPC::Open3;
	require Symbol;
	my $bin   = &subs::home('~/whisper.cpp/build/bin/whisper-cli');
	# A command is a handful of words against a tiny vocabulary, so the fast tiny
	# model is plenty and a clip gets through much sooner, especially on the
	# phone; base is the fallback when tiny is not installed.
	my $model = &subs::home('~/whisper.cpp/models/ggml-tiny.bin');
	unless (-e $model) {
		$model = &subs::home('~/whisper.cpp/models/ggml-base.bin');
	}
	return '' unless -e $bin && -e $model;
	my $cmd = sprintf(
		'ffmpeg -loglevel error -i - -blocksize 4096 -f wav -ar 16000 -ac 1 -acodec pcm_s16le - | %s -m %s --output-txt --file - 2>/dev/null',
		$bin, $model
	);
	my ($in, $out, $err);
	$err = Symbol::gensym();
	my $pid = IPC::Open3::open3($in, $out, $err, 'sh', '-c', $cmd);
	return '' unless $pid;
	binmode($in);
	print {$in} $raw;
	close($in);
	my $text = do { local $/; <$out> // '' };
	close($out);
	close($err);
	waitpid($pid, 0);
	$text =~ s/\r//g;
	$text =~ s/^\s+|\s+$//g;
	$text =~ s/\n+/ /g;
	if (&subs::voice_silence_hallucination($text)) {
		$log->info('voice: dropping a stock silence transcript ("' . $text . '")');
		return '';
	}
	return $text;
}

sub voice_command_parse() {
	# The words after the wake phrase, split into a verb and a target app. Only a
	# command that actually follows "hey jawn" counts, so a stray "start" in
	# conversation does nothing.
	#
	# $wake_optional is set for a clip that came from a wake-word capture: the
	# phrase was already consumed by the on-device trigger, so the transcript IS
	# the command and no "hey jawn" appears in it to match.
	my ($transcript, $wake_optional) = @_;
	my $low = lc($transcript || '');
	$low =~ s/[^a-z0-9 ]+/ /g;
	$low =~ s/\s+/ /g;
	my @w = split ' ', $low;
	my @rest;
	my $woke = 0;
	# The wake phrase is "hey jawn", matched as a pair: whisper mangles both
	# halves of it (hey -> hay/a/ay, jawn -> john/dawn/yawn), and requiring the two
	# together is what stops a lone "john"/"dawn" in stray speech from running a
	# command. The command is whatever follows the pair.
	my %hey  = map { $_ => 1 } qw/hey hay a ay eh hei hej heya/;
	my %jawn = map { $_ => 1 } qw/jawn jaun jauns jawns john johns jon dawn dawns down downs don dons dun yawn yawns yon/;
	for (my $i = 1; $i < @w; $i++) {
		next unless $jawn{$w[$i]} && $hey{$w[$i-1]};
		$woke = 1;
		@rest = @w[ $i + 1 .. $#w ];
		last;
	}
	if (!$woke && $wake_optional) {
		# a wake-word capture: the phrase was consumed on the watch, so treat the
		# whole transcript as the command
		$woke = 1;
		@rest = @w;
	}
	return { status => 'no_wake', said => $transcript } unless $woke && scalar @rest;
	my $verb = shift @rest;
	my %on  = map { $_ => 1 } qw/start begin open launch play run resume/;
	my %off = map { $_ => 1 } qw/stop end close finish pause halt quit/;
	my $want = $on{$verb} ? 'on' : $off{$verb} ? 'off' : undef;
	return { status => 'no_verb', verb => $verb, said => $transcript } unless $want;
	my $target = join ' ', @rest;
	$target =~ s/^\s+|\s+$//g;
	return { status => 'no_target', said => $transcript } unless length $target;
	return { status => 'ok', want => $want, target => $target, said => $transcript };
}

sub voice_command_apply() {
	# Act on a command by the same writes a watch button makes - a toggle and a
	# start/stop appointment - but without touching the watch's own operator_door,
	# because voice is not a button press.
	my ($app, $want, $meta) = @_;
	my $now = &subs::rightNow();
	my $settings = &subs::settings_grabber({ app => $app }) || {};
	&subs::setting_setter({ app => $app, setting => 'toggle', value => $want });
	my $db_data = {
		app => $app,
		server_time => $now,
		# the clip's own time (when the utterance began), not our processing time:
		# voice_ingest carries it as 'ts'
		timestamp => $meta->{'ts'} || $now,
		type => ($want eq 'on' ? 'start' : 'stop'),
		toggle => ($want eq 'on' ? 1 : 0),
		uuid => &subs::random_string_creator(21),
		duration => &subs::time_abbrev_translator($settings->{'duration'}),
		warranty => &subs::ago_calc(&subs::setting_grabber({ app => $app, setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $now),
		project => $settings->{'t_project'},
		pos => $settings->{'pos'},
		seen => 'yes'
	};
	&Manager::appointment_writer(&subs::controller_builder(), $db_data);
	&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $db_data->{'uuid'} . '\');' });
	return $db_data;
}

sub voice_note_store() {
	# A spoken clip with no wake word is not a failed command, it is a note: keep
	# the transcript so it turns up in the Notes app, to be sorted out later. This
	# is the whole 'audio that did not match the command word' path - the clip
	# already reached us (over BLE or WiFi), so nothing extra has to be collected.
	#
	# $at is the clip's own time (when the utterance began); the note is stamped
	# there, not at our processing time, so a note sorts where it was said.
	my ($text, $at) = @_;
	return unless defined $text;
	my $clean = $text;
	$clean =~ s/\s+/ /g;
	$clean =~ s/^\s+|\s+$//g;
	# whisper annotates non-speech as [BLANK_AUDIO] / (music) / [ Silence ]; with
	# those removed, a clip that actually said nothing is not a note
	my $spoken = $clean;
	$spoken =~ s/[\[\(][^\]\)]*[\]\)]//g;
	$spoken =~ s/\s+/ /g;
	$spoken =~ s/^\s+|\s+$//g;
	return unless length $spoken;
	# a single word, a clipped fragment, or a two-word noise is not a note: the
	# wake word already filters ", the room"; this keeps the rest of the mumbles out.
	my @words = split ' ', $spoken;
	return unless scalar @words >= 3;
	my $now = &subs::rightNow();
	# A plain note row, not an appointment: the Notes app reads this table, and the
	# server_time column rides the generic peer sync so the note still reaches
	# every machine.
	&subs::db_insert('notes', {
		app => 'notes',
		timestamp => $at || $now,
		server_time => $now,
		text => $clean,
		uuid => &subs::random_string_creator(21)
	});
	$log->info('voice: note stored (' . $clean . ')');
	return $clean;
}

sub voice_clip_fresh() {
	# One clip, one transcription. The watch streams a clip while it is being spoken
	# and still keeps the file as a fallback, so the same clip can legitimately
	# arrive twice (an ack lost, a link that died mid-stream); a second pass would
	# run the person's command twice. Keyed by the watch's own clip stamp.
	my ($chip_id, $ts) = @_;
	return 1 unless $chip_id && $ts;
	my $key = $chip_id . '|' . $ts;
	my $now = time();
	delete $gb::voice_seen->{$_} for grep { $now - $gb::voice_seen->{$_} > 300 } keys %{ $gb::voice_seen || {} };
	if ($gb::voice_seen->{$key}) {
		$log->info('voice: clip ' . $key . ' already handled; ignoring the duplicate');
		return 0;
	}
	$gb::voice_seen->{$key} = $now;
	return 1;
}

sub adpcm_wav_wrap() {
	# The 60-byte header the watch's voice_compress_clip writes around these same
	# blocks, rebuilt here because a streamed clip arrives without it: IMA ADPCM,
	# 8 kHz mono, 1024-byte blocks of 2041 samples. ffmpeg reads it natively, so
	# the streamed and whole-clip paths meet at the very same file.
	my ($data) = @_;
	my ($block, $spb, $rate) = (1024, 2041, 8000);
	my $blocks = int(length($data) / $block);
	my $samples = $blocks * $spb;
	my $abps = int($rate * $block / $spb);
	my $head = 'RIFF' . pack('V', 52 + length($data)) . 'WAVE'
		. 'fmt ' . pack('V', 20) . pack('v', 0x11) . pack('v', 1)
		. pack('V', $rate) . pack('V', $abps) . pack('v', $block) . pack('v', 4)
		. pack('v', 2) . pack('v', $spb)
		. 'fact' . pack('V', 4) . pack('V', $samples)
		. 'data' . pack('V', length($data));
	return $head . $data;
}

sub voice_clip_ack() {
	# The clip was transcribed and filed, so the watch no longer needs its local
	# copy: tell it over the bridge to drop the file (/voice.wav). Keyed by the
	# clip's own timestamp so an ack that arrives after the watch has started a
	# new capture cannot delete the newer clip.
	my ($meta) = @_;
	return unless $meta && $meta->{'chip_id'};
	&subs::bluetooth_sender({
		intent => 'com.jawn.president.bt.connect',
		chip_id => $meta->{'chip_id'},
		edt => $meta->{'edt'} || 'watch',
		# echo the watch's own clock (seconds), which voice_ingest parks in ts_watch
		# while ts carries the normalized ms everything else reads
		message => { type => 'voice_done', ts => (0 + ($meta->{'ts_watch'} || $meta->{'ts'} || 0)) }
	});
}

sub guide_set_message() {
	# Set a message to the Guide: a transcript the house heard addressed to it (a
	# wake-word capture, or a clip that opened with the phrase) is put into the
	# Guide's chat, so the spoken message is there to read and the Guide answers it
	# in the conversation - alongside the spoken answer voice_brain sends back to
	# the device. The Guide's window may not be open; the push is a no-op then.
	# A plain command ('start email test') never comes through here: that is a
	# movement, not a message for the Guide.
	my ($text, $meta) = @_;
	return unless defined $text && length $text;
	&Websocket::send('tab', {
		console => 'if (window.helpChatIngest) { helpChatIngest(' . encode_json($text) . '); }',
	});
	return 1;
}

sub json_from_model() {
	# A model's reply parsed as JSON. A model call hands back Perl characters
	# (already UTF-8 decoded), but Mojo::JSON::decode_json wants UTF-8 bytes: one
	# em dash or curly apostrophe makes the decode die, and callers that wrap it
	# in eval read that as "nothing". Encode to bytes first; fall back to a
	# braced substring when the model wrapped the object in prose.
	my ($out) = @_;
	return undef unless defined $out && length $out;
	my $decode = sub {
		my ($s) = @_;
		return undef unless defined $s && length $s;
		my $bytes = $s;
		utf8::encode($bytes) if utf8::is_utf8($bytes);
		return eval { decode_json $bytes };
	};
	my $parsed = $decode->($out);
	$parsed = $decode->($1) if !$parsed && $out =~ /(\{.*\})/s;
	return $parsed;
}

sub voice_brain() {
	# The voice assistant's brain: an utterance addressed to us that is not a
	# plain start/stop command goes to the guide's action vocabulary, so a spoken
	# request can act (make an appointment, play something), answer aloud, or ask
	# back. The guide's own model reads it; the verbs offered are only the ones a
	# voice turn can carry out (there is no screen and no follow-up turn).
	#
	#   $text  the transcript. For a wake-word capture the phrase was already
	#          consumed on the watch; for a VAD capture it opens with the phrase.
	#   $meta  { edt, chip_id, ts, voice } - ts is when the utterance began (the
	#          wake word), voice is the capture mode ('vad' or a wake phrase).
	#
	# Return a hashref { handled => 1, ... } to claim the utterance: the caller
	# then acks the clip and stops. Return undef and the caller files it as a
	# note. Must keep the database handle it was given: no forking here beyond
	# say_it's own child, which touches no database.
	my ($text, $meta) = @_;
	$meta ||= {};
	return undef unless defined $text && length $text;
	# A reply to a watch-addressed utterance lands on the watch (text on screen,
	# the spoken answer over its speaker); any other utterance speaks locally.
	my $reply = sub {
		my ($speech) = @_;
		return unless defined $speech && length $speech;
		if (($meta->{'chip_id'} || '') ne '') {
			&subs::watch_reply($meta, $speech);
		}
		else {
			&subs::say_it($speech);
		}
	};
	# The guide's own model (Configure -> Plat); without one the caller keeps the
	# note fallback. A voice turn has to answer in seconds, and the guide's chat
	# model can be a large cloud one (gemma4:cloud measured 147 s for one turn),
	# so the role's fast fallback is tried first - or a voice_assistant model when
	# one is set - with the guide's model as that call's own fallback.
	my ($model, $fallback) = &subs::ai_role_models('help_assistant');
	return undef unless $model;
	my $fast = &subs::setting_grabber({ app => 'mail', setting => 'voice_assistant' });
	$fast = ($fallback && $fallback ne $model) ? $fallback : '' unless defined $fast && length $fast;
	my %voice_verbs = map { $_ => 1 } qw/say ask done measure where_when create play_music open_app/;
	my $system = &help::actions_prompt(\%voice_verbs) . "\n\n";
	$system .= "This came in as a spoken command to the person's watch, transcribed on-device: "
		. "words may be misheard, and there is no follow-up turn - when the intent is clear, act "
		. "or answer; do not reply with a question. Keep spoken answers to one or two short sentences.\n";
	$system .= 'Right now it is ' . localtime(&subs::rightNow() / 1000)->strftime('%A, %B %d %Y, %I:%M%P') . ".\n";
	my ($out) = $fast
		? &subs::evaluation_model_call_with_fallback($fast, $model, $system, 'USER: ' . $text . "\n\nReply with the single JSON action.", &subs::ai_role_thinking('help_assistant'))
		: &subs::evaluation_model_call_role('help_assistant', $system, 'USER: ' . $text . "\n\nReply with the single JSON action.", &subs::ai_role_thinking('help_assistant'));
	$log->info('voice: brain model ' . ($fast || $model) . ' raw ' . (defined $out ? substr($out, 0, 240) : 'undef'));
	my $action = &json_from_model($out);
	if ($action && ref $action eq 'HASH' && $action->{'action'}) {
		$log->info('voice: brain action ' . $action->{'action'});
	}
	else {
		$log->info('voice: brain found no action in that reply');
	}
	return undef unless $action && ref $action eq 'HASH' && $action->{'action'};
	my $a = $action->{'action'};
	# A make/create is the Guide's write path: stage a proposal, and the
	# Confirmation Requirement decides whether the same breath saves it (the
	# Confirm tick in the Guide's associate; off = save without asking).
	if ($a eq 'create') {
		my $when = $action->{'when'};
		# no time named: the clip's own onset, so the appointment sits where the
		# person said it, not where whisper finished
		my $timestamp = (defined $when && length $when)
			? &Manager::guide_resolve_when($when)
			: ($meta->{'ts'} || &subs::rightNow());
		my $staged = eval { &Manager::guide_stage_appointment(&subs::controller_builder(), {
			app => $action->{'app'}, type => $action->{'type'}, timestamp => $timestamp,
			title => $action->{'title'}, notes => $action->{'notes'},
		}) };
		return undef unless $staged && $staged->{'staged'};
		my $what = $staged->{'title'} || &subs::format_name($staged->{'app'}) || 'it';
		my $confirm = &subs::setting_grabber({ app => '__president', setting => 'guide_confirm', device => 'all' });
		if (defined $confirm && $confirm eq 'off') {
			my $promoted = eval { &Manager::guide_promote_staged(&subs::controller_builder(), $staged->{'staged'}) };
			if ($promoted && !$promoted->{'error'}) {
				my $speech = 'Saved ' . $what . '.';
				$reply->($speech);
				$log->info('voice: brain saved "' . $what . '"');
				return { handled => 1, action => 'create', saved => 1, said => $speech };
			}
		}
		my $speech = 'I staged ' . $what . '. Promote it in the Guide and it is saved.';
		$reply->($speech);
		$log->info('voice: brain staged "' . $what . '"');
		return { handled => 1, action => 'create', staged => $staged->{'staged'}, said => $speech };
	}
	# speaking verbs: answer out loud, nothing else to run
	if ($a eq 'say' || $a eq 'ask' || $a eq 'done') {
		my $speech = $action->{'text'} || '';
		return undef unless length $speech;
		$reply->($speech);
		$log->info('voice: brain said "' . $speech . '"');
		return { handled => 1, action => $a, said => $speech };
	}
	# the acting verbs the server can run itself: measure/where read our own
	# records, play_music/open_app reach the open JawnOS tabs over the socket
	if ($a eq 'measure' || $a eq 'where_when' || $a eq 'play_music' || $a eq 'open_app') {
		my $obs = eval { &Manager::remote_command_execute(&subs::controller_builder(), $action) };
		return undef unless defined $obs && length $obs;
		$reply->($obs);
		$log->info('voice: brain ' . $a . ' (' . $obs . ')');
		return { handled => 1, action => $a, observation => $obs };
	}
	# anything else: undef lets the note fallback keep the transcript
	return undef;
}

sub voice_ingest() {
	# Audio -> text -> action. The single entry both the WiFi route and the BLE
	# bridge funnel into, so the two transports behave identically.
	my ($raw, $meta) = @_;
	$meta ||= {};
	# The watch stamps the clip with its own clock in epoch SECONDS
	# (timestamp_maker in jw.ino). Everything downstream - appointment_writer,
	# notes, guide_when_ms - wants epoch ms, so a bare seconds stamp filed the
	# appointment at the start of the epoch (a 'start email test' landed in 1970).
	# Normalize once here. The raw seconds ride along as ts_watch: the voice_done
	# ack must echo the watch's own clock, because the watch compares the echo
	# against voice_clip_ts - ms would never match and its clip would never delete.
	if (($meta->{'ts'} || 0) && (0 + $meta->{'ts'}) < 100000000000) {
		$meta->{'ts_watch'} = 0 + $meta->{'ts'};
		$meta->{'ts'} = $meta->{'ts_watch'} * 1000;
	}
	my $text = &subs::whisper_transcribe($raw);
	return { status => 'silence' } unless $text;
	$log->info('voice: heard "' . $text . '"');
	# A wake-word capture already consumed the phrase on the watch, so its
	# transcript is the command itself; a VAD capture must still open with the
	# phrase, so a stray "start" in the room does nothing. If what we heard is not
	# a command we can run, keep it as a note rather than throw the clip away.
	my $mode = $meta->{'voice'} || '';
	my $wake_optional = ($mode ne '' && $mode ne 'vad');
	my $cmd = &subs::voice_command_parse($text, $wake_optional);
	if (($cmd->{'status'} || '') ne 'ok') {
		$log->info('voice: ' . ($cmd->{'status'} || '?') . ' (' . $text . ')');
		# Keep it as a note only when it was addressed to us: a wake-word capture
		# (the phrase was consumed on the watch) or a clip that opened with the
		# phrase. A VAD clip of the room, or a clipped fragment, is not a note.
		my $addressed = $wake_optional || (($cmd->{'status'} || '') ne 'no_wake');
		# addressed, but not a plain command: hand it to the voice brain before
		# settling for a note (see voice_brain). If no brain claims it, fall through
		if ($addressed) {
			# the message is set to the Guide as well as answered: it lands in the
			# Guide's chat (if one is open) so a spoken message is visible there
			&subs::guide_set_message($text, $meta);
			my $brain = eval { &subs::voice_brain($text, $meta) };
			if ($brain && ref $brain eq 'HASH' && $brain->{'handled'}) {
				$log->info('voice: brain handled "' . $text . '"');
				&subs::voice_clip_ack($meta);
				return { status => 'brain', said => $text, %{$brain} };
			}
		}
		if ($addressed && &subs::voice_note_store($text, $meta->{'ts'})) {
			# a note landed: refresh any open Notes window at once, and let the
			# watch drop its local copy of the clip
			&Websocket::send('tab', { console => 'notesReload();' });
			&subs::voice_clip_ack($meta);
		}
		return $cmd;
	}
	# Match the target against the apps the system actually knows (the settings
	# table), not the static known_appts list - the user's apps (breakfast,
	# music, ...) live in the database. Match the plain key first, then the
	# spelled-out name, so "Mr. Sun" and "mr sun" agree.
	my $app = &subs::unformat_name($cmd->{'target'});
	my $row = &subs::db_select('settings', undef, { app => $app })->hashes->[0];
	unless ($row) {
		foreach my $r ( @{ &subs::db_select('settings', undef, { setting => 'toggle' })->hashes } ) {
			next unless $r->{'app'};
			if (&subs::unformat_name($r->{'app'}) eq $app) { $app = $r->{'app'}; $row = $r; last; }
		}
	}
	unless ($row) {
		$log->info('voice: no app for "' . $cmd->{'target'} . '" (' . $text . ')');
		return { status => 'no_app', said => $text, target => $cmd->{'target'} };
	}
	my $did = eval { &subs::voice_command_apply($app, $cmd->{'want'}, $meta); 1 };
	unless ($did) {
		$log->error('voice: apply failed for ' . $app . ': ' . ($@ || 'unknown'));
		return { status => 'apply_failed', app => $app, said => $text };
	}
	$log->info('voice: ' . $app . ' -> ' . $cmd->{'want'} . ' (' . $text . ')');
	return { status => 'done', app => $app, want => $cmd->{'want'}, said => $text };
}

sub ble_message_processor() {
	my ($data, $mac) = @_;
	$mac = &ble_link_key($mac);
	# Frames from several radios can interleave now, so the reassembly buffer is
	# per link. Keying it by MAC (and falling back to a single bucket when a v1
	# daemon sends no MAC) keeps a watch's half-message from being joined to a
	# board's half-message. The desktop daemon reassembles before emitting; the
	# Android daemon may not, so this stays here too.
	my $rxkey = length($mac) ? $mac : '?';
	if ($data =~ /^(\d+)\/(\d+):(.*)\z/s) {
		my ($index, $total, $body) = (int($1), int($2), $3);
		if ($total > 0 && $total <= 5000 && $index >= 0 && $index < $total) {
			my $now = time();
			my $parts = $gb::ble_rx_parts->{$rxkey};
			my $ptotal = $gb::ble_rx_total->{$rxkey} || 0;
			my $pat = $gb::ble_rx_at->{$rxkey} || 0;
			# fill by index: parts can arrive out of order or twice, and one lost
			# part must not wipe the parts already in hand
			if ($index == 0 || !$parts || $ptotal != $total || $now - $pat > 5) {
				if ($parts && grep { !defined } @{$parts}) {
					my $missing = scalar grep { !defined } @{$parts};
					$log->info("$missing part(s) of a framed BLE message from " . ($rxkey eq '?' ? 'an unnamed link' : $rxkey) . " never arrived; dropped");
				}
				$parts = [ (undef) x $total ];
				$gb::ble_rx_parts->{$rxkey} = $parts;
				$gb::ble_rx_total->{$rxkey} = $total;
			}
			$parts->[$index] = $body;
			$gb::ble_rx_at->{$rxkey} = $now;
			return if grep { !defined } @{$parts};
			$data = join('', @{$parts});
			delete $gb::ble_rx_parts->{$rxkey};
			$gb::ble_rx_total->{$rxkey} = 0;
		}
	}
	# A BLE notification as JSON text from the watch/board. The payload carries
	# the url the old Tasker "rcv bt" task used to fetch, so all existing
	# server-side handling stays untouched.
	my $msg = eval { decode_json $data };
	if ($@ || !$msg || ref $msg ne 'HASH') {
		$log->error('BLE message could not be decoded: ' . ($@ || 'not an object'));
		return;
	}
	my $type = $msg->{'type'};
	# Every embedded device that speaks over the bridge is remembered here, so it
	# can still be listed in the Embedded app while it is off its access point
	# (see device_lister's Bluetooth fallback). The message names the chip, not
	# the radio, so the link's address comes from the bridge events the listener
	# tracks in $gb::ble_link_mac. A tap names its chip only in the url it carries,
	# so read that too - otherwise a connected watch that only ever taps would age
	# out of the list.
	my ($seen_chip, $seen_edt) = ($msg->{'chip_id'}, $msg->{'edt'});
	if (!$seen_chip && ($msg->{'url'} || '') =~ /[?&]chip_id=([^&]+)/) {
		$seen_chip = $1;
	}
	if (!$seen_edt && ($msg->{'url'} || '') =~ /[?&]edt=([^&]+)/) {
		$seen_edt = $1;
	}
	if ($seen_chip) {
		&subs::ble_device_record({
			chip_id => $seen_chip,
			edt => $seen_edt || 'watch',
			name => $msg->{'name'},
			mac => $mac || $gb::ble_primary_mac
		});
	}
	# the newer bridge messages are dispatches, not url fetches
	if ($type && $type eq 'relay') {
		# A device addressing another device through the house. Route it by chip
		# id: locally if this machine holds that link, otherwise through the
		# active peers (each applies the same homebase rule).
		&subs::ble_relay_route($msg, {});
		return;
	}
	if ($type && $type eq 'state_request') {
		my $chip_id = $msg->{'chip_id'};
		my $edt = $msg->{'edt'} || 'watch';
		# bridged to a machine that is not the watch's homebase? re-home it
		&subs::ble_rehome_check($edt, $chip_id, $msg->{'homebase'});
		my $toggles = {};
		my $rows = &subs::db_select('settings', undef, { setting => 'toggle' })->hashes;
		foreach my $row ( @{$rows} ) {
			next unless $row->{'app'};
			$toggles->{$row->{'app'}} = $row->{'value'} eq 'on' ? 'on' : 'off';
		}
		if ($edt eq 'microcontroller') {
			# A board only needs the apps its own components name; the house can
			# carry a thousand toggles, and sending them all would overflow a
			# board's small receive queue for no benefit.
			my $od = eval { decode_json &subs::embedded_operator_door($edt, $chip_id) } || {};
			my %wanted;
			foreach my $k ( keys %{$od} ) {
				next if $k =~ /^__/;
				$wanted{ $od->{$k}->{'app'} } = 1 if $od->{$k}->{'app'};
			}
			$toggles = { map { $_ => $toggles->{$_} } grep { $wanted{$_} } keys %{$toggles} };
		}
		$log->info('BLE state_request for ' . $chip_id . ': ' . scalar(keys %{$toggles}) . ' toggles');
		&subs::bluetooth_sender({
			intent => 'com.jawn.president.bt.connect',
			chip_id => $chip_id,
			edt => $edt,
			message => { type => 'toggles', data => $toggles }
		});
		return;
	}
	if ($type && $type eq 'room_request') {
		my $chip_id = $msg->{'chip_id'};
		my $edt = $msg->{'edt'} || 'watch';
		my $room = $msg->{'room'} || 1;
		if ($edt eq 'microcontroller') {
			# A board cannot inflate a compressed room push and has no use for the
			# chat lists, so it gets the compact role payload instead.
			my $board = &subs::board_config_payload({ edt => $edt, chip_id => $chip_id });
			if ($board) {
				$log->info('BLE board_request for ' . $chip_id);
				&subs::bluetooth_sender({
					intent => 'com.jawn.president.bt.connect',
					chip_id => $chip_id,
					edt => $edt,
					message => { type => 'board_config', data => $board }
				});
			}
		}
		else {
			my $payload = &subs::watch_room_payload({ edt => $edt, chip_id => $chip_id });
			if ($payload) {
				$log->info('BLE room_request for ' . $chip_id . ', room ' . $room);
				&subs::bluetooth_sender({
					intent => 'com.jawn.president.bt.connect',
					chip_id => $chip_id,
					edt => $edt,
					message => { type => 'room', data => { room => $room, payload => $payload } }
				});
			}
		}
		return;
	}
	if ($type && $type eq 'steps') {
		# the watch hands its pedometer over the BLE link instead of its own
		# access point; the same ingest the /wigi collection uses
		my $samples = $msg->{'data'};
		&subs::step_ingest($samples, $msg->{'base'});
		my $count = ref $samples eq 'ARRAY' ? scalar @{$samples} : 0;
		$log->info('BLE steps for ' . ($msg->{'chip_id'} || '?') . ': ' . $count . ' samples');
		return;
	}
	if ($type && $type eq 'voice') {
		# a clip the watch shipped over the bridge; base64 so it rides the JSON
		# wire. The same ingest the WiFi route runs, so both transports agree.
		my $b64 = $msg->{'data'};
		my $raw = $b64 ? eval { decode_base64 $b64 } : undef;
		if ($raw && &subs::voice_clip_fresh($msg->{'chip_id'}, $msg->{'ts'})) {
			# Tell the watch the clip arrived whole, at once: the watch holds the file
			# and retries it until this lands, so the ack must come off the reassembly
			# and not wait on whisper (seconds). voice_done follows after the file is
			# transcribed, and it is what deletes the watch's copy.
			&subs::bluetooth_sender({
				intent => 'com.jawn.president.bt.connect',
				chip_id => $msg->{'chip_id'},
				edt => $msg->{'edt'} || 'watch',
				message => { type => 'voice_recv', ts => (0 + ($msg->{'ts'} || 0)) }
			});
			# Off the listener: whisper takes seconds, and while it ran inline the
			# listener stopped taking the next clip's parts, which the phone then
			# dropped ("276 part(s) never arrived"). The forked worker re-dials the
			# database itself (see database_grabber).
			my ($edt, $chip_id, $ts) = ($msg->{'edt'} || 'watch', $msg->{'chip_id'}, $msg->{'ts'});
			&subs::subprocessor(sub {
				&subs::voice_ingest($raw, { edt => $edt, chip_id => $chip_id, ts => $ts, voice => $msg->{'voice'} });
			}, { name => 'voice ingest' });
		}
		return;
	}
	if ($type && $type eq 'voice_stream') {
		# A clip arriving while it is still being spoken: the watch encodes IMA
		# ADPCM as it records and sends it in parts (seq, last). Reassembled here
		# and wrapped in the same 60-byte WAV header the whole-clip path's file
		# carries, so the ingest does not know the difference. Nothing happens
		# until the last part: a half-clip must never be transcribed as if it were
		# the whole command.
		my $chip_id = $msg->{'chip_id'} || '?';
		my $ts = 0 + ($msg->{'ts'} || 0);
		my $seq = 0 + ($msg->{'seq'} || 0);
		my $key = $chip_id . '|' . $ts;
		my $now = time();
		# a clip nobody finished (the link went away) must not linger
		foreach my $k ( keys %{ $gb::voice_rx || {} } ) {
			delete $gb::voice_rx->{$k} if $now - ($gb::voice_rx->{$k}->{'at'} || 0) > 60;
		}
		if ($seq == 0) {
			$gb::voice_rx->{$key} = { data => '', at => $now, edt => $msg->{'edt'} || 'watch', chip_id => $chip_id, ts => $ts, voice => $msg->{'voice'} };
		}
		my $rec = $gb::voice_rx->{$key};
		if ($rec) {
			$rec->{'at'} = $now;
			my $raw = $msg->{'audio'} ? eval { decode_base64 $msg->{'audio'} } : '';
			$rec->{'data'} .= ($raw // '');
			if ($msg->{'last'}) {
				my $data = $rec->{'data'};
				delete $gb::voice_rx->{$key};
				if (length($data) > 100 && &subs::voice_clip_fresh($chip_id, $ts)) {
					my $wav = &subs::adpcm_wav_wrap($data);
					$log->info('BLE streamed clip for ' . $chip_id . ': ' . length($data) . ' encoded bytes');
					&subs::bluetooth_sender({
						intent => 'com.jawn.president.bt.connect',
						chip_id => $chip_id,
						edt => $rec->{'edt'},
						message => { type => 'voice_recv', ts => $ts }
					});
					my ($edt, $voice) = ($rec->{'edt'}, $rec->{'voice'});
					&subs::subprocessor(sub {
						&subs::voice_ingest($wav, { edt => $edt, chip_id => $chip_id, ts => $ts, voice => $voice });
					}, { name => 'voice ingest' });
				}
			}
		}
		return;
	}
	if ($type && $type eq 'button') {
		# A button tap the watch sent over the link. Apply it HERE, on the machine
		# holding the bridge, instead of fetching the url the tap carries: that url
		# names the watch's homebase, which is the wrong machine whenever this one
		# is serving as the fallback, and a machine fetching that url from itself
		# is a needless round trip (it timed out in practice, losing the tap). Runs
		# the same worker /watch/button runs, then pushes the resulting state back.
		my $payload = $msg->{'payload'} || {};
		my $edt = $msg->{'edt'} || 'watch';
		my $chip_id = $msg->{'chip_id'};
		if ((!$chip_id || !$msg->{'edt'}) && $msg->{'url'}) {
			my ($c) = $msg->{'url'} =~ /[?&]chip_id=([^&]+)/;
			my ($e) = $msg->{'url'} =~ /[?&]edt=([^&]+)/;
			$chip_id ||= $c;
			$edt = $e if $e && !$msg->{'edt'};
		}
		# Say so on arrival: the tap is otherwise applied silently, so a tap that
		# never lands (or lands with no chip) is invisible in the log. This is the
		# one line that tells the two apart.
		$log->info('BLE button for ' . ($chip_id || '?') . ': room ' . ($payload->{'room'} || '?') . ', button ' . ($payload->{'button'} || '?'));
		my $ws = eval { decode_json &subs::embedded_operator_door($edt, $chip_id) } || {};
		if (!$ws->{'__specs'}) {
			$log->info('BLE button for ' . ($chip_id || '?') . ': no placed settings, dropped');
			return;
		}
		my $tog = (($payload->{'toggle'} || 0) == 1) ? 'off' : 'on';
		my $returner = eval {
			&subs::edt_button_presser({
				timestamp => (($payload->{'timestamp'} || 0) * 1000) || &subs::rightNow(),
				room => $payload->{'room'},
				watch_settings => $ws,
				button => $payload->{'button'},
				edt => $edt,
				chip_id => $chip_id,
				remote_address => 'bluetooth',
				toggle => $tog
			});
		};
		$log->error('BLE button press failed: ' . $@) if $@;
		if ($returner && ref $returner eq 'HASH') {
			&subs::bluetooth_sender({
				intent => 'com.jawn.president.bt.connect',
				chip_id => $chip_id,
				edt => $edt,
				message => { type => 'button', data => $returner }
			});
		}
		return;
	}
	if ($type && $type eq 'switch') {
		# A board's physical switch changed. Apply the same work /watch/switch
		# does, on the machine holding the bridge: flip the app toggle and let
		# edt_button_presser run the movement. A switch has no display ack of its
		# own, so there is nothing to push back.
		my $payload = $msg->{'data'} || $msg->{'payload'} || {};
		my $edt = $msg->{'edt'} || 'microcontroller';
		my $chip_id = $msg->{'chip_id'};
		my $button = $payload->{'switch'} || $payload->{'button'};
		my $state = $payload->{'state'} || '';
		my $ws = eval { decode_json &subs::embedded_operator_door($edt, $chip_id) } || {};
		if (!$ws->{'__specs'} || !defined $button) {
			$log->info('BLE switch for ' . ($chip_id || '?') . ': no placed settings, dropped');
			return;
		}
		my $syl_count = ($edt eq 'microcontroller') ? 10 : 1;
		my $b = $ws->{ &subs::shorthand_name('switch', $syl_count) . $button } || {};
		my $toggle = ($state eq 'on') ? 'off' : 'on';
		&subs::setting_setter({ app => $b->{'app'}, setting => 'toggle', value => $toggle }) if $b->{'app'};
		$log->info('BLE switch for ' . ($chip_id || '?') . ': switch ' . $button . ' -> ' . $toggle);
		eval {
			&subs::edt_button_presser({
				timestamp => (($payload->{'timestamp'} || 0) * 1000) || &subs::rightNow(),
				room => $payload->{'room'},
				watch_settings => $ws,
				button => $button,
				component => 'switch',
				edt => $edt,
				chip_id => $chip_id,
				remote_address => 'bluetooth'
			});
		};
		$log->error('BLE switch press failed: ' . $@) if $@;
		return;
	}
	if ($type && $type eq 'measure') {
		# A pot on a board, over the bridge. Mirror /watch/measure: scale the raw
		# reading through the app's app_measures and hand it to the same worker.
		my $payload = $msg->{'data'} || $msg->{'payload'} || {};
		my $edt = $msg->{'edt'} || 'microcontroller';
		my $chip_id = $msg->{'chip_id'};
		my $component = $payload->{'component'} || 'pot';
		my $button = $payload->{'button'} || $payload->{'pin'};
		my $measure = $payload->{'measure'};
		my $ws = eval { decode_json &subs::embedded_operator_door($edt, $chip_id) } || {};
		if (!$ws->{'__specs'} || !defined $button) {
			$log->info('BLE measure for ' . ($chip_id || '?') . ': no placed settings, dropped');
			return;
		}
		my $syl_count = ($edt eq 'microcontroller') ? 10 : 1;
		my $b = $ws->{ &subs::shorthand_name($component, $syl_count) . $button } || {};
		my $emin = $payload->{'min'} || 0;
		my $emax = $payload->{'max'} || 1024;
		my $settings = &subs::settings_grabber({ app => $b->{'app'}, settings => ['app_measures'] });
		my $app_measures = eval { decode_json $settings->{'app_measures'} } || {};
		if (exists $app_measures->{$b->{'measure'}}->{'max'} && exists $app_measures->{$b->{'measure'}}->{'min'}) {
			my $etotal = $emax - $emin;
			my $estate = $measure - $emin;
			my $eratio = $etotal ? ($estate / $etotal) : 0;
			my $total = $app_measures->{$b->{'measure'}}->{'max'} - $app_measures->{$b->{'measure'}}->{'min'};
			my $state_total = $eratio * $total;
			$measure = sprintf("%.3f", $state_total + $app_measures->{$b->{'measure'}}->{'min'});
		}
		eval {
			&subs::edt_button_presser({
				timestamp => &subs::rightNow(),
				room => $payload->{'room'},
				watch_settings => $ws,
				button => $button,
				edt => $edt,
				chip_id => $chip_id,
				measure => $measure,
				component => $component,
				remote_address => 'bluetooth'
			});
		};
		$log->error('BLE measure failed: ' . $@) if $@;
		return;
	}
	if ($type && $type eq 'state') {
		# A board confirming what it applied. The manager already stored the
		# intent; log it so a board that clamps a servo is visible, and leave the
		# record alone.
		my $payload = $msg->{'data'} || {};
		$log->info('BLE state ack from ' . ($msg->{'chip_id'} || '?') . ': ' . ($payload->{'component'} || '?') . ' ' . ($payload->{'pin'} || '?') . ' -> ' . ($payload->{'state'} || '?'));
		return;
	}
	my $url = $msg->{'url'};
	if (!$url) {
		$log->info('BLE message without url: ' . $data);
		return;
	}
	# The old check looked at the response before the asynchronous request had
	# any chance to complete, so a dead homebase and a good fetch looked alike.
	# One kept-alive user agent plus the completion callback log what happened.
	eval {
		$gb::ble_ua ||= Mojo::UserAgent->new(connect_timeout => 5, inactivity_timeout => 10);
		$gb::ble_ua->insecure(1)->get($url, sub {
			my ($ua, $tx) = @_;
			if ($tx->error) {
				$log->error('BLE message fetch failed: ' . $tx->error->{message} . ' for ' . $url);
			}
			else {
				$log->info('BLE message fetched: ' . $tx->res->code . ' ' . $url);
			}
		});
	};
	$log->error('BLE message fetch dispatch failed: ' . $@) if $@;
}

sub ble_listener_start() {
	# One long-lived 'jawn-bt listen' child: every BLE message the daemon
	# receives ends up in ble_message_processor(). Restarted if it dies.
	return if $gb::ble_listener;
	my $client = &ble_bridge_client();
	return unless &ble_bridge_enabled() && $client;
	# Before the listener starts taking messages: put every bridge on the right
	# side of its link (drop a chase that is not ours, start one we must serve).
	# Best-effort: a failure here must not stop the listener from coming up.
	eval { &ble_enforce_hosts(); };
	# And keep it that way: the homebase may go quiet (a dead phone), when this
	# machine has to take the watch over, and come back, when it must hand it
	# back. One timer per process.
	unless ($gb::ble_enforce_timer) {
		$gb::ble_enforce_timer = 1;
		Mojo::IOLoop->recurring(60 => sub { eval { &ble_enforce_hosts(); }; });
	}
	$gb::ble_listener_buffer = '';
	$gb::ble_listener = Mojo::IOLoop::ReadWriteFork->new;
	$gb::ble_listener->on(read => sub() {
		my ($fork, $bytes) = @_;
		# Reads are arbitrary chunks: a JSON line longer than one chunk used to
		# be decoded in halves and silently dropped. Buffer until the newline.
		$gb::ble_listener_buffer .= $bytes;
		if (length($gb::ble_listener_buffer) > 1048576) {
			$log->error('BLE listener buffer overflow; dropping partial data');
			$gb::ble_listener_buffer = '';
		}
		while ($gb::ble_listener_buffer =~ s/^(.*?)\n//) {
			my $event = eval { decode_json $1 };
			next unless $event && ref $event eq 'HASH';
			my $name = $event->{'event'} || '';
			# Keep the per-MAC link map current. Every link-scoped event names its
			# radio now, so a sighting, a send and a yield can all name the right
			# one instead of "the" link.
			if ($name eq 'connected' || $name eq 'disconnected' || $name eq 'status') {
				&ble_link_apply_event($event);
			}
			if ($name eq 'connected') {
				# Linked to a device this machine may not serve? Release that
				# radio at once, before it even speaks, so the homebase keeps it.
				my $chip = &ble_chip_by_mac($event->{'mac'});
				&ble_yield($chip->{'id'}, $event->{'mac'}) if $chip && !&ble_may_serve($chip->{'purpose'} || 'watch', $chip->{'id'});
			}
			elsif ($name eq 'status') {
				# The links can already be up when the listener attaches: release
				# any of them that is not ours to hold.
				foreach my $l ( @{ $event->{'links'} || [] } ) {
					next unless ref $l eq 'HASH' && $l->{'connected'};
					my $chip = &ble_chip_by_mac($l->{'mac'});
					&ble_yield($chip->{'id'}, $l->{'mac'}) if $chip && !&ble_may_serve($chip->{'purpose'} || 'watch', $chip->{'id'});
				}
				# A v1 daemon has no links[]; keep the top-level fallback.
				if (!@{ $event->{'links'} || [] } && $event->{'connected'}) {
					my $chip = &ble_chip_by_mac($event->{'mac'});
					&ble_yield($chip->{'id'}, $event->{'mac'}) if $chip && !&ble_may_serve($chip->{'purpose'} || 'watch', $chip->{'id'});
				}
			}
			elsif ($name eq 'message') {
				&ble_message_processor($event->{'data'}, $event->{'mac'});
			}
		}
	});
	$gb::ble_listener->on(close => sub() {
		$gb::ble_listener = undef;
		Mojo::IOLoop->timer(30 => sub() { &ble_listener_start(); });
	});
	print "Starting BLE bridge listener\n";
	$gb::ble_listener->start({ program => $client, program_args => [ 'listen' ] });
	return 1;
}



# The backups registry is merged across the mesh, so rows pile up for every
# machine's old archives - and the file-based prune in backup_now can only ever
# match this machine's own files, which is why a peer's rows (a phone's
# /data/data/... paths, say) were never cleaned and the table ran to thousands.
# Bound it: keep only the newest few rows per (reason, machine, recipient,
# destination) and delete the rest, with a tombstone so the deletion reaches the
# other machines too. Keeping the newest is what makes it safe: the newest
# remote_upgraded row of a group is the sync watermark (remote_machine's
# reconnector and remote_upgrade read it), and merge_database reads the newest
# one or two rows overall. Capped so one pass never floods the tombstone log;
# successive backups finish the job.
sub backup_registry_prune() {
	my $keep = shift || 5;
	my ($db,$database,$sql) = &subs::database_grabber();
	return 0 unless $db;
	my $cap = 500;
	my $groups = &subs::db_query(
		"select ifnull(reason,'') reason, ifnull(signatorial,'') signatorial, ifnull(recipient,'') recipient, ifnull(destination,'') destination, count(*) c from backups group by reason, signatorial, recipient, destination having count(*) > ?",
		$keep
	)->hashes || [];
	my $deleted = 0;
	foreach my $g ( @{$groups} ) {
		last if $deleted >= $cap;
		my $rows = &subs::db_query(
			"select uuid, server_time from backups where ifnull(reason,'') = ? and ifnull(signatorial,'') = ? and ifnull(recipient,'') = ? and ifnull(destination,'') = ? order by cast(server_time as integer) desc",
			$g->{'reason'}, $g->{'signatorial'}, $g->{'recipient'}, $g->{'destination'}
		)->hashes || [];
		for (my $i = $keep; $i < scalar @{$rows}; $i++) {
			last if $deleted >= $cap;
			my $r = $rows->[$i];
			next unless $r->{'uuid'};
			&Manager::deletion_registration({ table => 'backups', uuid => $r->{'uuid'}, scope => 'single', server_time => $r->{'server_time'} });
			&subs::db_delete('backups', { uuid => $r->{'uuid'} });
			$deleted++;
		}
	}
	return $deleted;
}

# Held for the life of a remote export. Releasing in DESTROY means the lock is
# cleared even when backup_now dies part-way, not only on its normal return.
{
	package Jawn::BackupLock;
	sub new { my ($class,$val) = @_; return bless { val => $val }, $class; }
	sub release {
		my $self = shift;
		return unless $self->{'val'};
		my $val = $self->{'val'};
		$self->{'val'} = undef;
		eval {
			my $row = &subs::db_query('select value from settings where app = ? and setting = ?', '__president', 'remote_backup_lock')->hashes->[0];
			&subs::setting_setter({ app => '__president', setting => 'remote_backup_lock', value => '' }) if (($row->{'value'} || '') eq $val);
		};
	}
	sub DESTROY { my $self = shift; $self->release; }
}

# The encrypted SQLite snapshot is the archive / migration / v2 path now. A normal
# delta between peers runs the v3 row stream (`Manager::sync_rows_pull` and the
# `/manager/sync_rows` route), which shares merge_table_rows/merge_finish and never
# builds this temporary database.
sub backup_now() {
	my $c = shift;
	my $start_time = &subs::rightNow();
	my $uuid = &subs::random_string_creator(25);
	my $auuid = &subs::random_string_creator(12);
	my $reason = $c->param('reason') || 'unknown';
	unless ($reason eq 'remote_update') {
		my $html = '<h2>Doing backup</h2>';
		&Websocket::send('tab', { yellow => $html, uuid => $auuid });
	}
	return unless $reason ne 'unknown';
	# A puller that can wait for a slow build asks for it asynchronously (async=1).
	# The request returns as soon as the snapshot row exists, and the puller polls
	# backup_status while the build runs. Older pullers never send the flag and
	# keep the synchronous reply, so a mixed house still syncs.
	my $async = ($reason eq 'remote_update' && ($c->param('async') || '') eq '1') ? 1 : 0;
	my $async_child = $gb::backup_async_child ? 1 : 0;
	if ($async && !$async_child) {
		my $snapshot = &subs::random_string_creator(24);
		my $now = &subs::rightNow();
		&subs::db_query('delete from sync_snapshots where cast(updated as integer) < ?', $now - (6 * 60 * 60 * 1000));
		&subs::db_insert('sync_snapshots', {
			uuid => $snapshot,
			caller => ($c->param('signatorial') || ''),
			state => 'building',
			timestamp => $now,
			server_time => $now,
			updated => $now
		}) or return { status => 'failed', error => 'could not record the snapshot' };
		&subs::subprocessor(sub {
			$gb::backup_async_child = 1;
			$gb::backup_async_snapshot = $snapshot;
			my $result = eval { &subs::backup_now($c) };
			my $err = $@;
			if ($err) {
				$err =~ s/\s+/ /g;
				eval { &subs::db_update('sync_snapshots', { state => 'failed', error => substr($err, 0, 500), updated => &subs::rightNow() }, { uuid => $snapshot }) };
				return;
			}
			if (ref $result eq 'HASH' && ($result->{'status'} || '') eq 'busy') {
				eval { &subs::db_update('sync_snapshots', { state => 'busy', error => 'peer was already exporting', updated => &subs::rightNow() }, { uuid => $snapshot }) };
				return;
			}
			if (ref $result eq 'HASH' && $result->{'archive_path'}) {
				# The puller fetches the file, so the inline copy is not needed - and
				# binary bytes through JSON do not survive the trip.
				delete $result->{'raw_data'};
				my $sha = eval { require Digest::SHA; Digest::SHA->new(256)->addfile($result->{'archive_path'})->hexdigest };
				eval { &subs::db_update('sync_snapshots', {
					state => 'ready',
					job => ($result->{'sync_job'} || ''),
					archive_path => $result->{'archive_path'},
					size => $result->{'size'},
					sha256 => $sha,
					result => encode_json($result),
					updated => &subs::rightNow()
				}, { uuid => $snapshot }) };
				return;
			}
			eval { &subs::db_update('sync_snapshots', { state => 'failed', error => 'no snapshot', updated => &subs::rightNow() }, { uuid => $snapshot }) };
		}, { name => 'remote snapshot', fork => 1 });
		return { status => 'building', job => $snapshot, signatorial => ($c->param('signatorial') || '') };
	}
	# A nightly reconciliation makes every peer ask this machine for its last few
	# days at the same moment; each request builds a windowed copy of every table
	# in memory and vacuums it, so a phone gets several of those at once and the
	# OOM killer takes the tree. One remote export at a time, here on the target:
	# a second caller is told to come back on its next tick instead.
	my $backup_lock;
	my $backup_lock_guard;
	if ($reason eq 'remote_update') {
		my $held = &subs::db_query('select value,server_time from settings where app = ? and setting = ?', '__president', 'remote_backup_lock')->hashes->[0];
		# The lock value carries the holding worker's pid. This tree restarts every
		# few minutes under memory pressure, so an export's worker is often gone
		# before the export finishes; a lock whose owner is dead is recovered at
		# once instead of wedging every peer's sync for the full age bound. The age
		# bound stays as the fallback for an owner that is alive but hung.
		my ($held_uuid, $held_pid) = split /:/, ($held->{'value'} || ''), 2;
		my $owner_dead = 0;
		$owner_dead = 1 if ($held_pid && $held_pid =~ /^\d+$/ && $held_pid > 1 && !kill(0, $held_pid));
		my $stale = !$held->{'server_time'} || $held->{'server_time'} + (10 * 60 * 1000) < &subs::rightNow() || $owner_dead;
		if (($held->{'value'} || '') ne '' && ($held->{'value'} || '') ne '0' && !$stale) {
			$log->info('remote backup busy; told ' . $c->tx->remote_address . ' to retry') if $log;
			return { status => 'busy', reason => $reason };
		}
		$backup_lock = $auuid . ':' . $$;
		&subs::setting_setter({ app => '__president', setting => 'remote_backup_lock', value => $backup_lock });
		# two workers can pass the check above in the same instant; the last writer
		# keeps the lock and the loser steps aside rather than run a second export
		my $confirm = &subs::db_query('select value from settings where app = ? and setting = ?', '__president', 'remote_backup_lock')->hashes->[0];
		if (($confirm->{'value'} || '') ne $backup_lock) {
			$log->info('remote backup claim lost to another worker; told ' . $c->tx->remote_address . ' to retry') if $log;
			return { status => 'busy', reason => $reason };
		}
		$backup_lock_guard = Jawn::BackupLock->new($backup_lock);
	}
	# The peer's yellow dot watches this export from the other side, but this
	# machine's own dot should say what it is doing too: a serve job and one step
	# per table.
	my ($sync, $job);
	if ($reason eq 'remote_update') {
		$job = &subs::sync_job_start({
			direction => 'serve',
			peer => $c->tx->remote_address,
			phase => 'export',
			note => 'building a snapshot for a peer'
		});
		$sync = Jawn::SyncJob->new($job);
		&subs::sync_job_step($job, 'export', { label => 'export', state => 'running' });
	}
	# Per-table cuts: a table the caller already holds up to a point is exported
	# only above it. No cuts (an older caller) falls back to the legacy window.
	my $cuts = &subs::sync_map_decode($c->param('cuts'));
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my ($db,$database,$sql) = &subs::database_grabber();
	my $t = localtime;
	my $databaser = $database;
	$databaser =~ s/.db$//gi;
	my $filename = &subs::unformat_name( $databaser );
	$databaser =~ s/_\d+$//;
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
	my $suds = &subs::session_suds($c) || &subs::suds_grabber();
	# Bridge for peers still on the old fixed-key Crypt::Simple: the appended
	# encryption-standard must be readable by their decrypter, which only uses the
	# legacy key (md5 of an empty passphrase). Our decrypter falls back to the same
	# key, so this stays readable by updated peers too. Remove once every device runs
	# the per-secret code.
	my $appendage = $gb::universal_splitter . &subs::encrypter(undef,$encryption_standard);
	my $path = &subs::backups_dir() . '/' . (do { my $n = $databaser; $n =~ s{.*/}{}; $n });
	my $temporary_path = &subs::home('~/.president/') . &subs::random_string_creator() . '.sql';
	my $enc_file = $path . '.enc';
	my $signatorial = &subs::signatorial_designer();
	my $initializer = 1;

	my $size = -s $database;

	my $duration = &subs::rightNow() - $start_time;
#	&appointment_writer($c,{
#		app => 'customs',
#		type => 'backup',
#		timestamp => $timestamp,
#		duration => $duration,
#		file => $path
#	});
	my $warranty = $reason eq 'remote_update' ? &subs::ago_calc('-20m', $timestamp) : &subs::ago_calc(&subs::setting_grabber({ app => 'customs', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', $timestamp);

	my $secret = &subs::decrypter($suds,&subs::db_select('security', ['credential'], { level => 1 })->hash->{credential});

	my $ld_server_time = 0;
	my ($rm,$colour);

	if ($reason eq 'remote_update') {
		$path = &subs::home('~/.president/') . &subs::random_string_creator(21);
		$enc_file = $path . '.enc';

		$rm = &subs::db_select('remote_machines', undef, { signatorial => $c->param('signatorial') })->hashes->[0];
		$rm = &Manager::remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
		$colour = $rm->{'data'}->{'manager_colour'};
		my $html = '<h2>Being synced by ' . $rm->{'ip'} || $c->tx->remote_address . '</h2>';
		&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
		# The completed watermark is `remote_upgraded` (remote_update is the
		# in-flight row), and `server_time` is a millisecond stamp: order it as a
		# number. The old string ordering plus the wrong reason left the window at
		# the 20 s fallback, so a peer that had been away re-pulled a tiny slice
		# while one that was up to date looked behind.
		my $last_updated = &subs::db_query('select * from backups where reason=? and recipient = ? and signatorial = ? order by cast(server_time as integer) DESC limit 1', 'remote_upgraded',$c->param('signatorial'), $signatorial)->hashes->[0];
		my $last_update = 10;
		if (($c->param('full') || '') eq '1') {
			# A migration: read the whole table, not a window. Unlike a gimme this
			# is a real reconciliation, so the caller confirms and advances the
			# watermark (remote_upgrade keeps gimme false for full).
			$last_update = 0;
			$ld_server_time = 0;
		}
		elsif (($c->param('gimme') || '') =~ /^\d{10,}$/) {
			# gimme is a millisecond stamp by the time remote_upgrade sends it
			# (ago_calc on this side). A duration string here is a caller bug, and
			# treating it as a timestamp exported the whole table once; ignore it
			# and let the watermark/cold branch decide.
			$last_update = $c->param('gimme');
			$ld_server_time = $last_update;
		}
		elsif ($last_updated->{'server_time'}) {
			$last_update = $last_updated->{'server_time'};
			$ld_server_time = $last_update;
		}
		else {
			# A peer with no watermark is cold. Exporting every table in full is
			# what let one slow tablet hold this machine's single export lock for
			# minutes at a time (appointments and continent are ~110k rows each),
			# while every other peer was told "already exporting". Bound the first
			# pull to the last day: the nightly three-day reconciliation and a
			# manual gimme are how older rows are reached. Every machine already
			# holds the older history; the rows it is missing are recent.
			$last_update = &subs::rightNow() - (24 * 60 * 60 * 1000);
			$ld_server_time = $last_update;
		}
		$ld_server_time = $ld_server_time - 20000;
		my $tables = `sqlite3 $database .tables`;
		my @tables = sort split ' ', $tables;
		my $schema_file = $temporary_path . '.schema.sql';
		# the statistics and sequence tables are internal: replaying their CREATE is
		# a parse error ("object name reserved for internal use: sqlite_sequence"),
		# and SQLite builds them again where they are wanted
		`sqlite3 $database .schema | grep -vE 'sqlite_stat|sqlite_sequence' > $schema_file`;
		my $command = `sqlite3 $temporary_path < $schema_file`;
		`shred -u $schema_file`;
#		my $backup = `sqlite3 $database .schema $temporary_path`;
		my $tsql = Mojo::SQLite->new('sqlite:' . $temporary_path);
		my $tdb = $tsql->db;

		foreach my $t ( @{$gb::forbidden->{'tables'}} ) {
			@tables = grep { $_ ne $t } @tables;
			$tdb->query('DROP TABLE ' . $t);
		}
		# The snapshot is read once, in bounded rowid batches. Its indexes are
		# pure weight: leaving them on made a few hundred changed rows download
		# as megabytes of B-tree pages.
		my $snapshot_indexes = eval { $tdb->query("select name from sqlite_master where type='index' and name not like 'sqlite_autoindex%'")->hashes } || [];
		foreach my $si ( @{$snapshot_indexes} ) {
			eval { $tdb->query('DROP INDEX ' . $si->{'name'}) };
		}

		my $table_total = scalar @tables;
		my $table_n = 0;
		# One transaction for the whole snapshot. Each row used to commit on its
		# own, so a table the size of settings cost tens of thousands of fsyncs;
		# on a phone that ran past the prefork heartbeat and the worker was
		# restarted in the middle of settings, leaving the export and its lock
		# behind. One commit makes the same copy a fraction of the time.
		my $export_tx = $tdb->begin;
		foreach my $d ( @tables ) {
			next if grep { $_ eq $d } @{$gb::forbidden->{'tables'}};
			$table_n++;
			# A table without a server_time column cannot be windowed, and the query
			# below would die -- which killed the export, left its lock held, and
			# wedged every peer's sync until the ten-minute stale re-claim, over and
			# over. sync_cursors is such a table; guard generically rather than trust
			# every CREATE to carry the column.
			my $has_server_time = &subs::db_query('select name from pragma_table_info(?) where name = ?', $d, 'server_time')->hashes->[0];
			unless ($has_server_time) {
				$tdb->query('DROP TABLE ' . $d);
				next;
			}
			# An explicit cut is the caller's own newest row, so `>` is exact; the
			# legacy window keeps its inclusive 20 s overlap.
			my $has_cut = exists $cuts->{$d};
			my $cut = $has_cut ? $cuts->{$d} : $ld_server_time;
			my $op = $has_cut ? '>' : '>=';
			# Count cheaply, then stream the rows: a full pull of appointments or
			# continent used to materialise the whole table with ->hashes, and the
			# worker died under that allocation (the export then restarted every
			# tick and never finished). One row at a time keeps the memory flat.
			# Window/tab state belongs to the machine that drew it. Carrying it in a
			# snapshot made one machine's Libro Chequing window open on every other
			# machine; the digest already ignores these settings, and the export must
			# too. Everything durable still rides along.
			my $window_state = ($d eq 'settings') ? " and (setting is null or setting not in ('open_tabs','scrollTop','jopen','dimensions'))" : '';
			my $row_total = (&subs::db_query('select count(*) as c from ' . $d . ' where server_time ' . $op . ' ?' . $window_state, $cut)->hashes->[0]->{'c'} || 0) + 0;
			if ($job) {
				&subs::sync_job_step($job, 'export:' . $d, {
					label => 'export ' . $d, state => 'running', current => 0, total => $row_total,
					note => $row_total . ' row' . ($row_total == 1 ? '' : 's')
				});
			}
			if ($row_total > 0) {
	#			$tdb->query('delete from ' . $d . ' where server_time < ?', $ld_server_time);
				my $cursor = &subs::db_query('select * from ' . $d . ' where server_time ' . $op . ' ?' . $window_state, $cut);
				my $copied = 0;
				while (my $nd = $cursor->hash) {
					$tdb->insert($d, $nd);
					$copied++;
					# Keep the job's liveness stamp fresh, but do not go back through
					# database_grabber: its abandoned-statement sweep visits every open
					# handle and finishes THIS still-reading cursor, which ended the copy
					# at exactly 2000 rows no matter how many were left.
					if ($job && ($copied % 2000) == 0) {
						eval { $db->query('update sync_jobs set updated = ? where uuid = ?', &subs::rightNow(), $job) };
						# Keep the export lease young too: a very large table on a slow
						# machine can outlive the ten-minute stale bound, and the lock
						# must not be re-claimed while this worker is still copying.
						eval { $db->query('update settings set server_time = ? where app = ? and setting = ? and value = ?', &subs::rightNow(), '__president', 'remote_backup_lock', $backup_lock) } if $backup_lock;
					}
				}
				$cursor->finish if $cursor && $cursor->can('finish');
			} else {
				$tdb->query('DROP TABLE ' . $d);
			}
			&subs::sync_job_step($job, 'export:' . $d, {
				state => 'done', current => $row_total, total => $row_total
			}) if $job;
			&Websocket::send('tab', {
				yellow => '<h2>Being synced by ' . ($rm->{'ip'} || $c->tx->remote_address) . '</h2>',
				uuid => $auuid, colour => $colour,
				progress => ($table_total > 0 ? int($table_n / $table_total * 100) : 0),
				state => 'running'
			}) if $job;
		}
		$export_tx->commit if $export_tx;
		$tdb->query('VACUUM');

	}
	else {


		&subs::db_query('VACUUM');
		my $backup = `sqlite3 $database ".backup '$temporary_path'"`;
		my $tsql = Mojo::SQLite->new('sqlite:' . $temporary_path);
		my $tdb = $tsql->db;
		my $indexes = $tdb->query('select * from sqlite_master where name not like ? and type=?', '%autoindex%', 'index')->hashes;
		foreach my $index ( @{$indexes} ) {
			$tdb->query('DROP INDEX ' .  $index->{'name'});
		}
		$tdb->delete('cache', { context => 'template' });
		$tdb->delete('cache', { context => 'header' });
		$tdb->query('VACUUM');
		my $max_backups = &Manager::misc_setting_list()->{$signatorial}->{'max_backups'} || 3;
		my $backup_list_command = 'ls -t ' . $path . '_*.enc';
		my $backups = `$backup_list_command`;

		my @backups = split "\n", $backups;
		@backups = grep { $_ ne $enc_file } @backups;
		if (scalar @backups > $max_backups) {
			for (my $n = $max_backups; $n < scalar @backups; $n++) {

				my $shredder = 'shred -u ' . $backups[$n];
				my $backs = &subs::db_select('backups', undef, { enc_file => $backups[$n] })->hashes;
				foreach my $ba ( @{$backs} ) {
					&Manager::deletion_registration({ table => 'backups', uuid => $ba->{'uuid'}, scope => 'single', server_time => $ba->{'server_time'} });
				}
				&subs::db_delete('backups', { enc_file => $backups[$n] });
				`$shredder`;
			}
		}

	}

	# drop this machine's dead references and anyone's stale ones (see
	# backup_registry_prune); the file prune above only knew local paths
	&subs::backup_registry_prune();

	my $archive_path = $path . '_' . $timestamp;
	my $encrypt = &openssl_file_crypt('e', $encryption_standard, $secret, $temporary_path, $archive_path . '.enc', 0, 1);
	my $stat_path = `stat $temporary_path`;
	`echo "$appendage" >> $archive_path.enc`;

	unless ($reason eq 'remote_update') {
		my $archive_encrypt = `cp -v $archive_path.enc $enc_file`;
	}
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		`shred -u $temporary_path*`;
	}, { name => 'backup shredder' });


	&Websocket::send('tab', { type => 'event', timestamp => $timestamp });
	my @folder = split '/', $archive_path;
	my $archive_name = pop @folder;
	my $folder = join '/', @folder;
	@folder = split '/', $path;
	my $current_name = pop @folder;
	my $backup_data = {
		timestamp => $timestamp,
		server_time => $server_time,
		size => $size,
		signatorial => $signatorial,
		destination => $database,
		reason => $reason,
		enc_file => $archive_path . ".enc",
		recipient => $c->param('signatorial'),
		warranty => $warranty,
		uuid => $uuid
	};
	&subs::db_insert('backups',$backup_data) unless $reason eq 'remote_update';
	# The number the person sees is the bytes of the snapshot that actually moved,
	# not this machine's whole database. The row was built before the archive
	# existed and used to record `-s $database` (~180 MB) for every sync, windowed
	# or not; write the encrypted archive's size over it once it is known.
	$size = -s $archive_path . '.enc';
	$backup_data->{'size'} = $size;
	unless ($reason eq 'remote_update') {
		&subs::db_update('backups', { size => $size }, { uuid => $uuid });
	}
	my $raw_data;
	if ($size < 2000000) {
		$raw_data = read_file($archive_path . ".enc");
	}
	# A small remote snapshot rides back inside the JSON body itself, so the file
	# under ~/.president is already redundant: sweep it here rather than leave it
	# for the next boot's ~/.president wipe. A large one is pulled over http, and
	# backup_serve deletes it once it has been served.
	if ($reason eq 'remote_update' && defined $raw_data && $archive_path =~ m{/\.president/} && !$gb::backup_async_child) {
		my $sweep = $archive_path . '.enc';
		`shred -u "$sweep"`;
	}


	my $returner = {
		database => $database,
		signatorial => $signatorial,
		folder => $folder,
		current => $current_name . ".enc",
		archive => $archive_name . ".enc",
		archive_path => $archive_path . ".enc",
		path => $enc_file,
		backup_data => $backup_data,
		misc_settings => &Manager::misc_setting_list(),
		home => &subs::home('~/'),
		device => $device,
		server_time => $server_time,
		uuid => $uuid,
		size => $size,
		ld_server_time => $ld_server_time,
		raw_data => $raw_data,
		sync_job => ($job || ''),
	};
	if ($reason eq 'remote_update') {
		$returner->{'update_commands'} = &Manager::update_database({ duty => 'list' });
	}
	if ($backup_lock) {
		my $lock_row = &subs::db_query('select value from settings where app = ? and setting = ?', '__president', 'remote_backup_lock')->hashes->[0];
		&subs::setting_setter({ app => '__president', setting => 'remote_backup_lock', value => '' }) if ($lock_row->{'value'} || '') eq $backup_lock;
	}
	&subs::sync_job_step($job, 'export', { state => 'done', current => 1, total => 1 }) if $job;
	$sync->done('done', 'snapshot served') if $sync;
	&Websocket::send('tab', { yellow => 'close', 'close' => 'yes', uuid => $auuid, colour => $colour, state => 'done', progress => 100 });
	return $returner;
}

# A cheap, truthful picture of what this machine's appointments hold, so a peer
# can tell whether it already has everything instead of pulling the window every
# tick. Appointments are only inserted or re-stamped, so if the count and the
# newest server_time are both unchanged there is nothing new to send.
sub appointment_watermark() {
	my $row = &db_query('select count(*) as c, coalesce(max(server_time),0) as m from appointments')->hashes->[0];
	return { count => ($row->{'c'} || 0) + 0, max_server_time => ($row->{'m'} || 0) + 0 };
}

# What this machine holds above the watermark a peer already has (its ?since=):
# appointments with a newer server_time. A count, not the rows, so the check
# stays cheap on the two-minute tick; the reconciliation is what moves data.
sub appointments_since() {
	my $since = shift;
	return undef unless defined $since && $since =~ /^[0-9]+$/;
	# A NULL or empty status is the common case for a freshly written appointment,
	# and `status != 'deleting'` is NULL (not true) for those rows - so the count
	# came back 0 while the peer plainly held newer appointments, and the caller
	# then skipped the pull and never synced. Include them explicitly.
	my $row = &db_query('select count(*) as c, coalesce(max(server_time),0) as m from appointments where server_time > ? and (status is null or status != ?)', $since, 'deleting')->hashes->[0];
	return { count => ($row->{'c'} || 0) + 0, max_server_time => ($row->{'m'} || 0) + 0, since => $since + 0 };
}

# --- the House digest -------------------------------------------------------
# `server_time` is the write time of every replicated row, so a per-table
# {count, sum(server_time), max} is a cheap fingerprint of the whole table. Two
# machines that hold the same rows have the same fingerprint even when the rows
# arrived by different paths; a machine that was offline and is missing an old
# row has a different count (or sum) and is caught. /remote_auth_test exchanges
# this map, and the caller plans a per-table pull from the difference.
sub durable_settings_where {
	# Settings churn constantly (window geometry, open tabs, timers, remote_*
	# state). Only app configuration may trigger a sync; the export still carries
	# every settings row when a pull happens.
	#
	# `@gb::protected` is the same list merge_database refuses to merge (me, misc,
	# terminal, config, security, ...). Those rows are deliberately local, so a
	# digest over them could never match a peer's: every tick would look like a
	# change and pull the whole settings table forever. Leave them out of the
	# trigger; they still ride along in a snapshot.
	my @apps = ('__president', 'cache', 'websocket_messages', 'ai_budget', 'ai_jobs', 'staged_fixes', 'staged_records', 'staged_appointments', 'sync_log', 'backups', 'sync_jobs', @gb::protected);
	my %seen;
	@apps = grep { !$seen{$_}++ } @apps;
	my $app_list = join ',', map { "'$_'" } @apps;
	# `operator_door` is a trigger on purpose. It carries the embedded device's
	# rotated Now Me pair, and a device that has to fall back to another House
	# machine probes it with that pair. Excluding the row left the fallback
	# holding the previous rotation (or none) until some unrelated setting moved
	# the digest, so a deck whose pair had just been re-issued was denied by a
	# peer that was otherwise live. Including it makes every Now Me rotate the
	# digest and the peers pull the new row on the next tick.
	return "app not in ($app_list)"
		. " and setting not in ('open_tabs','scrollTop','jopen','dimensions','utility_controller','remote_connect_timer','remote_upgrade','remote_backup_lock','remote_auth_probe_timer','ws_pa','chip_chyea','settings_sync_timer','remote_sync_state','log','schema_version','toggle','ci','errors','email_config')"
		. " and setting not like 'remote\\_%' escape '\\'";
}

our $sync_table_cache;
sub sync_table_list {
	return $sync_table_cache if $sync_table_cache;
	my @tables;
	my %forbidden = map { $_ => 1 } @{ $gb::forbidden->{'tables'} || [] };
	foreach my $row ( @{ &db_query('select name from sqlite_master where type = ?', 'table')->hashes || [] } ) {
		my $t = $row->{'name'} || '';
		next if $t eq '' || $t =~ /^sqlite_/ || $forbidden{$t} || $t eq 'sync_jobs';
		my $has = &db_query('select name from pragma_table_info(?) where name = ?', $t, 'server_time')->hashes->[0];
		push @tables, $t if $has;
	}
	$sync_table_cache = \@tables;
	return $sync_table_cache;
}

sub sync_table_digest {
	my ($table, $durable) = @_;
	my $sql_table = $table eq 'settings_durable' ? 'settings' : $table;
	my $where = '';
	if ($sql_table eq 'appointments') { $where = " where (status is null or status != 'deleting')"; }
	elsif ($table eq 'settings_durable') { $where = ' where ' . &durable_settings_where(); }
	my $row = &db_query("select count(*) as c, coalesce(sum(cast(server_time as integer)),0) as s, coalesce(max(server_time),0) as m from $sql_table$where")->hashes->[0] || {};
	return { count => ($row->{'c'} || 0) + 0, sum => ($row->{'s'} || 0) + 0, max => ($row->{'m'} || 0) + 0 };
}

our $sync_digest_cache;
sub sync_digest_map {
	my ($force) = @_;
	# The digest is a count/sum/max scan per table, and the reconnector asks for
	# it every tick. A short process cache keeps that from becoming a full scan
	# of appointments on every handshake; 30s is well inside one sync window, so
	# a change still starts a pull on the next tick after it lands.
	my $now = &rightNow();
	return $sync_digest_cache->{'map'}
		if (!$force && $sync_digest_cache && ($now - $sync_digest_cache->{'at'}) < 30000);
	# Not every column of every table is a reason to sync. `backups` is the sync's
	# own bookkeeping (a pull writes a row on both sides, so including it would
	# trigger the next pull forever), the AI ledger is internal churn, and the
	# location/notification streams move constantly without being a person's
	# change. Those still ride along inside any snapshot; they just cannot start
	# one by themselves. Appointments and durable settings are the triggers.
	my %skip = map { $_ => 1 } qw(backups ai_budget ai_jobs ai_house continent notifications);
	my %map;
	foreach my $t ( @{ &sync_table_list() } ) {
		next if $t eq 'settings' || $skip{$t};
		$map{$t} = &sync_table_digest($t);
	}
	$map{'settings_durable'} = &sync_table_digest('settings_durable');
	$sync_digest_cache = { at => $now, map => \%map };
	return \%map;
}

sub sync_table_above {
	my ($table, $cut) = @_;
	return undef unless defined $cut && $cut =~ /^[0-9]+$/;
	my $sql_table = $table eq 'settings_durable' ? 'settings' : $table;
	my $where = ' where server_time > ?';
	if ($sql_table eq 'appointments') { $where .= " and (status is null or status != 'deleting')"; }
	elsif ($table eq 'settings_durable') { $where .= ' and ' . &durable_settings_where(); }
	my $row = &db_query("select count(*) as c, coalesce(sum(cast(server_time as integer)),0) as s, coalesce(max(server_time),0) as m from $sql_table$where", $cut)->hashes->[0] || {};
	return { count => ($row->{'c'} || 0) + 0, sum => ($row->{'s'} || 0) + 0, max => ($row->{'m'} || 0) + 0 };
}

# The caller's plan: table => since. `0` means a full table; a timestamp means
# pull only what is newer. Watermark first: rows above our newest are always a
# delta, and the full read is for a table we have not reconciled in full yet
# (`seen->{full}` records that one full read). A peer that is behind and was
# already read in full is skipped rather than copied again on every write.
sub sync_plan {
	my ($mine, $theirs, $above, $seen) = @_;
	return undef unless ref $mine eq 'HASH' && ref $theirs eq 'HASH';
	$seen ||= {};
	my %plan;
	foreach my $t ( keys %{$theirs} ) {
		my $a = $mine->{$t} || {};
		my $b = $theirs->{$t} || {};
		my ($ac, $bc) = (($a->{'count'} || 0) + 0, ($b->{'count'} || 0) + 0);
		my ($as, $bs) = (($a->{'sum'} || 0) + 0, ($b->{'sum'} || 0) + 0);
		my ($am, $bm) = (($a->{'max'} || 0) + 0, ($b->{'max'} || 0) + 0);
		next if $ac == $bc && $as == $bs && $am == $bm;
		# The picture we last reconciled with this peer. An unchanged picture is
		# skipped outright; when it has moved, the *change* is measured against
		# this baseline, not against our own table. Comparing with our table made
		# a peer that holds fewer rows (the union already landed here) look
		# divergent on every write forever: the count difference never matched
		# the rows above our newest, so every appointment asked for the whole
		# 110k-row table again.
		my $s = $seen->{$t};
		my $seen_count = (ref $s eq 'HASH') ? ($s->{'count'} || 0) : 0;
		my $seen_sum = (ref $s eq 'HASH') ? ($s->{'sum'} || 0) : 0;
		my $seen_max = (ref $s eq 'HASH') ? ($s->{'max'} || 0) : 0;
		my $seen_full = (ref $s eq 'HASH' && $s->{'full'}) ? 1 : 0;
		next if ref $s eq 'HASH' && $seen_full
			&& $seen_count == $bc
			&& $seen_sum == $bs
			&& $seen_max == $bm;
		my $since;
		# A small divergence is not worth copying a whole table: the watermark
		# catches new rows, and a migration (full=1) or the nightly pass can
		# reconcile the few old ones later. 500 rows is a guard, not a rule.
		my $small = 500;
		# Watermark first: anything newer than our newest row is a forward delta,
		# whatever the handshake's above-count says. The count is advisory and can
		# be zero while the peer plainly holds a newer row.
		if ($bm > $am) {
			$since = $am;
		}
		# The peer is behind or level and holds no more rows than we do: there
		# is nothing the watermark can name. Do not rebuild the table for it.
		elsif ($bm <= $am && $bc <= $ac) {
			next;
		}
		# The peer holds a few more rows, but the gap is small. A full copy of
		# 110k rows to find a handful is what ran the CPU hot every few minutes.
		elsif ($bm <= $am && ($bc - $ac) <= $small) {
			next;
		}
		# A real gap we have never read whole: read it once. The flag then
		# makes the cheap paths above the rule.
		elsif (!$seen_full) {
			$since = 0;
		}
		# Its newest is recent: a bounded window covers rows written a few seconds
		# below our max by a concurrent writer, without the full table.
		elsif ($bm >= $am - 600000) {
			$since = $am - 600000;
		}
		elsif ($t eq 'settings_durable') {
			# The settings table carries a row per device class, and the merge stores
			# a peer's values under the local class, so the durable count can differ
			# permanently. Never turn that into a whole-table read on every tick: a
			# window covers recent settings, and the nightly/deep pull reconciles an
			# old row.
			$since = $am - 600000;
		}
		else {
			$since = 0;
		}
		my $key = ($t eq 'settings_durable') ? 'settings' : $t;
		$plan{$key} = $since;
	}
	return \%plan;
}

# Compact table=>integer maps on the peer rail (?cuts=, and the plan handed to
# backup_now). Table names are SQL identifiers; anything else is dropped rather
# than interpolated.
sub sync_map_encode {
	my ($map) = @_;
	return '' unless ref $map eq 'HASH';
	return join ',', map { $_ . ':' . int($map->{$_} || 0) }
		sort grep { /^[A-Za-z0-9_]+$/ } keys %{$map};
}
sub sync_map_decode {
	my ($text) = @_;
	my %map;
	return \%map unless defined $text && length $text;
	foreach my $pair ( split /,/, $text ) {
		my ($t, $v) = split /:/, $pair, 2;
		next unless defined $t && $t =~ /^[A-Za-z0-9_]+$/;
		next unless defined $v && $v =~ /^[0-9]+$/;
		$map{$t} = $v + 0;
	}
	return \%map;
}

# --- one sync job, for the yellow dot's progress ---------------------------
sub sync_job_start {
	my ($data) = @_;
	$data ||= {};
	my $uuid = $data->{'uuid'} || &random_string_creator(24);
	my $now = &rightNow();
	&db_query('delete from sync_jobs where cast(updated as integer) < ?', $now - 86400000);
	&db_query('insert or replace into sync_jobs (uuid,direction,peer,phase,current,total,state,note,steps,started,updated) values (?,?,?,?,?,?,?,?,?,?,?)',
		$uuid, ($data->{'direction'} || ''), ($data->{'peer'} || ''), ($data->{'phase'} || 'starting'),
		($data->{'current'} || 0), ($data->{'total'} || 0), ($data->{'state'} || 'running'),
		($data->{'note'} || ''), '[]', $now, $now);
	return $uuid;
}

# The individual bars across the top of the panel: one entry per phase/table, in
# the order it was first seen. A sync job is short-lived and only its owner writes
# it, so a read-modify-write of the small JSON array is safe.
sub sync_job_step {
	my ($uuid, $key, $data) = @_;
	return unless $uuid && defined $key && $key ne '';
	$data ||= {};
	my $row = &db_query('select steps from sync_jobs where uuid = ?', $uuid)->hashes->[0] || {};
	my $steps = eval { decode_json($row->{'steps'} || '[]') } || [];
	my ($step) = grep { ref $_ eq 'HASH' && ($_->{'key'} || '') eq $key } @{$steps};
	unless ($step) {
		$step = { key => $key, label => $key, current => 0, total => 0, state => 'running', note => '' };
		push @{$steps}, $step;
	}
	foreach my $k ( qw/label current total state note/ ) {
		$step->{$k} = $data->{$k} if exists $data->{$k};
	}
	&db_query('update sync_jobs set steps = ?, phase = ?, updated = ? where uuid = ?',
		encode_json($steps), ($data->{'label'} || $step->{'label'} || $key), &rightNow(), $uuid);
	return $step;
}
sub sync_job_update {
	my ($uuid, $data) = @_;
	return unless $uuid && ref $data eq 'HASH';
	my (@sets, @vals);
	foreach my $k ( qw/phase current total state note peer direction/ ) {
		next unless exists $data->{$k};
		push @sets, "$k = ?";
		push @vals, $data->{$k};
	}
	return unless scalar @sets;
	push @vals, &rightNow(), $uuid;
	&db_query('update sync_jobs set ' . join(', ', @sets) . ', updated = ? where uuid = ?', @vals);
}
sub sync_job_finish {
	my ($uuid, $state, $note) = @_;
	return unless $uuid;
	$state ||= 'done';
	my $now = &rightNow();
	# Settle any bar still open, so a failed job does not leave a table reading
	# "running" in the panel after the dot has already shown a red cross.
	my $row = &db_query('select steps from sync_jobs where uuid = ?', $uuid)->hashes->[0] || {};
	my $steps = eval { decode_json($row->{'steps'} || '[]') } || [];
	foreach my $step ( @{$steps} ) {
		next unless ref $step eq 'HASH';
		if (($step->{'state'} || '') eq 'running') {
			$step->{'state'} = $state;
			$step->{'current'} = $step->{'total'} if $state eq 'done';
		}
	}
	&db_query('update sync_jobs set state = ?, phase = ?, note = ?, steps = ?, current = total, updated = ? where uuid = ?',
		$state, $state, ($note || ''), encode_json($steps), $now, $uuid);
}
sub sync_job_list {
	my ($limit) = @_;
	$limit ||= 10;
	# A worker that died mid-sync leaves its row 'running'; after ten minutes
	# nobody is coming back for it, so show it as interrupted rather than a dot
	# that rings forever.
	&db_query(q{update sync_jobs set state = 'failed', phase = 'failed', note = 'interrupted' where state = 'running' and cast(updated as integer) < ?}, &rightNow() - 1800000);
	my $rows = [ @{ &db_query('select * from sync_jobs order by cast(updated as integer) desc limit ?', $limit)->hashes || [] } ];
	foreach my $r ( @{$rows} ) {
		$r->{'steps'} = eval { decode_json($r->{'steps'} || '[]') } || [];
		if (($r->{'total'} || 0) > 0) {
			$r->{'percent'} = int(($r->{'current'} || 0) / $r->{'total'} * 100);
		}
		elsif (scalar @{ $r->{'steps'} }) {
			# A serve job counts progress in its steps (one per table) rather
			# than in current/total, which belongs to the pull's table count.
			my $done = grep { ($_->{'state'} || '') eq 'done' } @{ $r->{'steps'} };
			$r->{'percent'} = int(($done / scalar(@{ $r->{'steps'} })) * 100);
		}
		else {
			$r->{'percent'} = (($r->{'state'} || '') eq 'done') ? 100 : 0;
		}
		$r->{'percent'} = 100 if $r->{'percent'} > 100;
	}
	return $rows;
}
sub sync_job_active {
	my ($limit) = @_;
	return [ grep { ($_->{'state'} || '') eq 'running' } @{ &sync_job_list($limit || 4) } ];
}
{
	package Jawn::SyncJob;
	sub new { my ($class, $uuid) = @_; return bless { uuid => $uuid, done => 0 }, $class; }
	sub done { my ($self, $state, $note) = @_; $state ||= 'done'; $self->{'state'} = $state; &subs::sync_job_finish($self->{'uuid'}, $state, $note); $self->{'done'} = 1; }
	sub DESTROY { my $self = shift; &subs::sync_job_finish($self->{'uuid'}, 'failed', 'sync ended without a result') unless $self->{'done'}; }
}

# The peer picture we have already reconciled, per table. Storing it after a
# successful pull turns "this table diverges" into "this exact picture has
# already been read", so a peer that is merely behind us is not full-read every
# tick while a peer that changed (the offline row) is read once more.
sub sync_seen_get {
	my ($peer) = @_;
	return {} unless $peer;
	my $row = &db_query('select data from cache where context = ? and subcontext = ? order by cast(server_time as integer) desc limit 1', 'sync_seen', $peer)->hashes->[0];
	return {} unless $row && $row->{'data'};
	# New rows are JSON: it has no NULs, so an older DBD cannot truncate it at the
	# first NUL the way it does a Sereal blob. Fall back to Sereal for rows written
	# before this change (a newer DBD stored those whole).
	my $d = eval { decode_json($row->{'data'}) };
	return $d if ref $d eq 'HASH';
	my $old = eval { decode_sereal($row->{'data'}) };
	return (ref $old eq 'HASH') ? $old : {};
}
sub sync_seen_set {
	my ($peer, $digest) = @_;
	return unless $peer && ref $digest eq 'HASH';
	my $dev = &device_setter();
	# JSON, not Sereal: `cache_set` would encode a Sereal blob whose header has a
	# NUL at byte 5, and the older DBD on this box binds that at the NUL - the map
	# arrived as a 5-byte header and the planner lost its baseline every tick.
	&db_query('delete from cache where app = ? and context = ? and subcontext = ? and device = ?', '__president', 'sync_seen', $peer, $dev);
	&db_insert('cache', {
		app => '__president',
		context => 'sync_seen',
		subcontext => $peer,
		data => encode_json($digest),
		timestamp => &rightNow(),
		server_time => &rightNow(),
		warranty => &ago_calc('-10d', &rightNow()),
		device => $dev,
		uuid => &random_string_creator(25)
	});
}

# A peer that told us it was busy gets a short rest instead of being asked again
# on every tick. The cache is machine-local (and forbidden from the export).
sub sync_backoff_active {
	my ($peer) = @_;
	return 0 unless $peer;
	my $row = &db_query('select server_time from cache where context = ? and uuid = ? order by cast(server_time as integer) desc limit 1', 'sync_backoff', $peer)->hashes->[0];
	return ($row && $row->{'server_time'} > &rightNow()) ? 1 : 0;
}
sub sync_backoff_set {
	my ($peer, $seconds) = @_;
	return unless $peer;
	&db_query('delete from cache where context = ? and uuid = ?', 'sync_backoff', $peer);
	&db_query('insert into cache (uuid, context, app, server_time, timestamp) values (?,?,?,?,?)', $peer, 'sync_backoff', '__president', &rightNow() + ($seconds || 120) * 1000, &rightNow());
}
sub sync_backoff_clear {
	my ($peer) = @_;
	return unless $peer;
	&db_query('delete from cache where context = ? and uuid = ?', 'sync_backoff', $peer);
}


# --- durable deletion tombstones -------------------------------------------
# A deletion is permanent for any machine that has not yet seen it. Each
# tombstone carries a monotonic id; a machine only drops a tombstone once every
# remote machine has *confirmed* reading past it (sync_cursors), so a desktop
# left off for weeks still receives the whole backlog when it reconnects. The
# owner advances a reader's cursor only from the cursor that reader sends on its
# next request, so a lost response can never purge a deletion early.
sub tombstone_writer() {
	my $data = shift;
	&db_insert('sync_log', {
		server_time => &subs::rightNow(),
		signatorial => &subs::signatorial_designer(),
		tbl => $data->{'table'},
		app => $data->{'app'},
		uuid => $data->{'uuid'},
		scope => $data->{'scope'},
		additional => (ref $data->{'additional'} ? encode_json($data->{'additional'}) : $data->{'additional'}),
	});
	return &tombstone_max();
}

sub tombstones_since() {
	my $cursor = shift;
	$cursor = 0 unless defined $cursor && $cursor =~ /^[0-9]+$/;
	return &db_query('select * from sync_log where id > ? order by id asc', $cursor)->hashes || [];
}

sub tombstone_max() {
	my $row = &db_query('select coalesce(max(id),0) as m from sync_log')->hashes->[0];
	return ($row->{'m'} || 0) + 0;
}

# Drop tombstones every known machine has confirmed reading. With no remote
# machines there is nothing to sync, so the log clears wholesale; if any machine
# has never confirmed (no cursor yet) the whole backlog is kept.
sub tombstone_purge() {
	my $rms = &db_select('remote_machines', ['signatorial'])->hashes || [];
	if (!scalar @{$rms}) { &db_query('delete from sync_log'); return; }
	my $floor;
	foreach my $rm ( @{$rms} ) {
		my $row = &db_query('select cursor from sync_cursors where signatorial = ?', $rm->{'signatorial'})->hashes->[0];
		my $c = $row && $row->{'cursor'};
		return unless defined $c && $c =~ /^[0-9]+$/;
		$floor = $c if !defined $floor || $c < $floor;
	}
	&db_query('delete from sync_log where id <= ?', $floor) if defined $floor && $floor > 0;
}




sub sms_list_check() {
my $returner = '';
	if ($device eq 'mobile') {
		my $timestamp = &subs::rightNow();
		my $c = &subs::controller_builder();
		my $suds = &suds_grabber();
		my $json_list = `termux-sms-list -l 10 --message-sort-order="date DESC"` || '[]';
		my $list = decode_json $json_list;
		foreach my $l (grep { $_->{'type'} eq 'draft' || $_->{'type'} eq 'sent' || $_->{'type'} eq 'inbox' } @{$list}) {
			my $time = &subs::ago_calc($l->{'received'},$timestamp);
			my $phone = $l->{'number'};
			$phone =~ s/\D+//gi;
			$phone =~ s/^1//;
			next unless $phone;
			$returner .= "Phone is " . $phone . "\n";
			# the person the number belongs to; a stranger's number becomes an app
			# of its own, so their texts land somewhere and naming the app later
			# turns the stranger into a person
			my $app = &subs::phone_number_app($phone);
			next unless $app;
			my $chats = &subs::db_select('mailbox', undef, { phone => $phone, timestamp => $time })->hashes;
			if ( scalar @{$chats} == 0) {
				$l->{'body'} =~ s/[^\x00-\x7F]+//gi;
				my $message = &subs::note_encrypter($suds,$l->{'body'});
				my $sender = &subs::format_name($app);
				my $suuid = &subs::random_string_creator(44);
				&subs::db_insert('mailbox', {
					uuid => $suuid,
					timestamp => $time,
					server_time => &subs::rightNow(),
					body => $l->{'body'}, #$message,
					manager_file => $sender,
					status => 'public', #$l->{'type'},
					phone => $phone,
				});
				# the telephone accepted a message: the browsers hear about it
				&subs::mail_arrival({
					c => $c,
					uuid => $suuid,
					phone => $phone,
					manager_file => $sender,
					body => $l->{'body'},
					status => 'public'
				});
			}

			my $q = &subs::db_query('select * from appointments where app = ? and type = ? and timestamp = ?', $app,'sms',$time);
			my $qu = $q->hashes;
			if ( scalar @{$qu} == 0 ) {
				$l->{'body'} =~ s/[^\x00-\x7F]+//gi;
				$returner .= "Phone: " . $phone . " - " . $app . "\n";
				&Manager::appointment_writer($c,{
					app => &subs::unformat_name($app),
					timestamp => $time || $timestamp,
					type => 'sms',
					notes => &subs::note_encrypter($suds,&subs::format_name($l->{'type'}) . ": " . $l->{'body'}),
					duration => 5000
				});
			}
			else {
				$returner .= "Seen " . $phone . " at " . $l->{'received'} . " from " . $app . " already\n";
			}
		}
	}
	return $returner;
}

sub encrypter() {
	my ($secret,$content) = @_;
	local *encrypt;
	local *decrypt;
	Crypt::Simple->import(passphrase => $secret);
	my $notes = eval { encrypt($content) };
	return $notes;
}
sub decrypter() {
	my ($secret,$content) = @_;
	my ($notes,$ok);
	{
		local *encrypt;
		local *decrypt;
		Crypt::Simple->import(passphrase => $secret);
		$ok = eval { $notes = decrypt($content); 1 };
	}
	unless ($ok) {
		# Legacy data was written by an older `use Crypt::Simple passphrase => $undef`,
		# which keyed everything off an empty passphrase. Fall back so it stays readable.
		local *encrypt;
		local *decrypt;
		Crypt::Simple->import(passphrase => undef);
		$notes = eval { decrypt($content) };
	}
	return $notes;
}

# ---- note encryption ---------------------------------------------------------
#
# A note is sealed in two layers: an inner cipher - an openssl `enc` container
# ("Salted__" + an 8-byte salt + the ciphertext), keyed by PBKDF2-HMAC-SHA256 of
# the secret - and an outer Crypt::Simple layer keyed by the same secret. The
# standard travels inside the payload, so a note written under any standard still
# reads back.
#
# The inner cipher runs in-process for the AES family (through CryptX) and falls
# back to the openssl binary for the rest; both produce the identical container,
# so notes are interchangeable either way. The old pipeline forked base64 and
# openssl for every single note - tens of milliseconds each, which is why a page
# of mail took seconds - this one costs microseconds.

# The standards the Encryption Standard setting offers. Everything here is
# filtered by what this machine can actually run (see note_standard_supported),
# so the Configure list never offers a cipher that would write letters nobody can
# read back. A standard not listed can still be read: the openssl fallback accepts
# any cipher that binary knows.
sub note_encryption_standards {
	my @offered = (
		'aes-256-ctr', 'aes-192-ctr', 'aes-128-ctr',
		'aes-256-cbc', 'aes-192-cbc', 'aes-128-cbc',
		'camellia-256-ctr', 'camellia-192-ctr', 'camellia-128-ctr',
		'camellia-256-cbc', 'camellia-192-cbc', 'camellia-128-cbc',
		'des-ede3-cbc', 'sm4-cbc',
		'chacha20', 'aria-256-cbc',
	);
	return [ grep { &note_standard_supported($_) } @offered ];
}

# Whether one standard can be sealed and opened again on this machine. The
# in-process families answer from the table; the openssl-only ones are probed
# once (a tiny round trip) and memoised for the life of the worker.
our %note_standard_supported;
sub note_standard_supported {
	my ($standard) = @_;
	return undef unless defined $standard && length $standard;
	return $note_standard_supported{$standard} if exists $note_standard_supported{$standard};
	my $spec = &note_cipher_spec($standard);
	my $ok = eval {
		if ($spec) {
			# the cipher is in-process: prove this build can construct it
			$spec->{'family'} eq 'ctr' ? &note_ctr_mode($spec) : &note_cbc_mode($spec);
			return 1;
		}
		my $probe = &note_seal_container('jawnos', 'jawnos', $standard);
		return 0 unless defined $probe && length $probe;
		my $plain = &note_open_container($probe, 'jawnos', $standard);
		return (defined $plain && $plain eq 'jawnos') ? 1 : 0;
	};
	$note_standard_supported{$standard} = $ok ? 1 : 0;
	return $note_standard_supported{$standard};
}

# The in-process cipher for a standard, or undef when only openssl can run it.
# aes/camellia-NNN-ctr/cbc map onto the named cipher with the key length the
# number names; CTR keeps a big-endian, full-block counter, which is what
# openssl's EVP uses. des-ede3-cbc is 3DES (8-byte block); sm4 is a 16-byte-block
# cipher. keylen is the key, ivlen is both the IV and the block. Everything listed
# here is also readable through openssl, so a peer that still shells out can open
# the same file.
our %note_cipher_specs = (
	'aes-128-ctr' => [ 'ctr', 'AES', 16, 16 ], 'aes-192-ctr' => [ 'ctr', 'AES', 24, 16 ], 'aes-256-ctr' => [ 'ctr', 'AES', 32, 16 ],
	'aes-128-cbc' => [ 'cbc', 'AES', 16, 16 ], 'aes-192-cbc' => [ 'cbc', 'AES', 24, 16 ], 'aes-256-cbc' => [ 'cbc', 'AES', 32, 16 ],
	'camellia-128-ctr' => [ 'ctr', 'Camellia', 16, 16 ], 'camellia-192-ctr' => [ 'ctr', 'Camellia', 24, 16 ], 'camellia-256-ctr' => [ 'ctr', 'Camellia', 32, 16 ],
	'camellia-128-cbc' => [ 'cbc', 'Camellia', 16, 16 ], 'camellia-192-cbc' => [ 'cbc', 'Camellia', 24, 16 ], 'camellia-256-cbc' => [ 'cbc', 'Camellia', 32, 16 ],
	'des-ede3-cbc' => [ 'cbc', 'DES_EDE', 24, 8 ],
	'sm4-cbc' => [ 'cbc', 'SM4', 16, 16 ],
);
sub note_cipher_spec {
	my ($standard) = @_;
	my $f = $note_cipher_specs{$standard} or return undef;
	return { family => $f->[0], cipher => $f->[1], keylen => $f->[2], ivlen => $f->[3] };
}

# The standard to seal a new note with: the setting when it names a cipher this
# machine can actually run, otherwise the default. The setting used to be filled
# from every cipher `openssl enc -ciphers` lists, most of which this scheme cannot
# use - choosing one wrote letters that could never be read back. Validating here
# means a bad setting degrades to the default instead of losing data.
sub note_encryption_standard {
	my $standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
	return $standard if grep { $_ eq $standard } @{ &note_encryption_standards() };
	return $standard if &note_cipher_spec($standard);
	return 'aes-256-ctr';
}

# PBKDF2-HMAC-SHA256, 10000 rounds - openssl enc -pbkdf2 with its default digest.
sub note_kdf {
	my ($secret, $salt, $len) = @_;
	require Crypt::KeyDerivation;
	return Crypt::KeyDerivation::pbkdf2($secret, $salt, 10000, 'SHA256', $len);
}

sub note_ctr_mode { my ($spec) = @_; require Crypt::Mode::CTR; return Crypt::Mode::CTR->new($spec->{'cipher'}, 1, $spec->{'ivlen'}); }
sub note_cbc_mode { my ($spec, $nopad) = @_; require Crypt::Mode::CBC; return Crypt::Mode::CBC->new($spec->{'cipher'}, $nopad ? 0 : 1); }

# Key and IV for one container, memoised per process. PBKDF2 costs about 6 ms and
# a file is opened again and again (a thumbnail, a video range, a gallery reload),
# so the same secret and salt must not pay for it twice. Bounded and never
# written anywhere: a cache is a convenience, not storage.
our %note_key_material;
sub note_key_material {
	my ($secret, $salt, $spec) = @_;
	return undef unless defined $secret && defined $salt;
	my $memo_key = join "\x1f", $spec->{'cipher'}, $spec->{'keylen'}, $spec->{'ivlen'}, &md5_sum($secret), $salt;
	return $note_key_material{$memo_key} if $note_key_material{$memo_key};
	my $len = $spec->{'keylen'} + $spec->{'ivlen'};
	my $kiv = eval { &note_kdf($secret, $salt, $len) };
	return undef unless defined $kiv && length $kiv == $len;
	my $key = substr($kiv, 0, $spec->{'keylen'});
	my $iv = substr($kiv, $spec->{'keylen'}, $spec->{'ivlen'});
	%note_key_material = () if scalar(keys %note_key_material) >= 512;
	$note_key_material{$memo_key} = { key => $key, iv => $iv };
	return $note_key_material{$memo_key};
}

sub note_random_salt {
	return Crypt::PRNG::random_bytes(8) if eval { require Crypt::PRNG; 1 };
	open(my $fh, '<', '/dev/urandom') or return undef;
	my $bytes; read($fh, $bytes, 8); close $fh;
	return $bytes;
}

# Run openssl over bytes held in memory. The input goes through a temp file, not
# a pipe pair: with two pipes the parent writes the container into the child's
# stdin while the child writes the answer back, and once either buffer fills
# both sides wait forever. (This only bit the openssl fallback; AES and the other
# in-process ciphers never spawn a process.)
sub note_openssl_run {
	my ($args, $input, $secret) = @_;
	return undef unless defined $secret && length $secret;
	require File::Temp;
	require File::Spec;
	# The passphrase goes in a 0600 temp file, never in argv: a `-k` leaves the
	# house key visible in `ps` for the life of the child.
	my ($pfh, $ppath) = eval { File::Temp::tempfile('jawnos-pass-XXXXXX', DIR => File::Spec->tmpdir, UNLINK => 0) };
	return undef unless $pfh && defined $ppath;
	binmode $pfh;
	print $pfh $secret;
	close $pfh;
	my ($fh, $path) = eval { File::Temp::tempfile('jawnos-enc-XXXXXX', DIR => File::Spec->tmpdir, UNLINK => 0) };
	if (!$fh || !defined $path) { unlink $ppath; return undef }
	binmode $fh;
	print $fh $input;
	close $fh;
	my @cmd = (@{$args}, '-pass', 'file:' . $ppath, '-in', $path);
	my $result;
	if (open(my $out, '-|', @cmd)) {
		binmode $out;
		$result = do { local $/; <$out> };
		close $out;
	}
	my $ok = $? == 0;
	unlink $path, $ppath;
	return undef unless $ok;
	return $result;
}

# openssl enc over files, with the passphrase in a 0600 temp file. Returns 1 on
# success and 0 on failure. $quiet keeps a wrong-password "bad decrypt" out of
# the log when a caller is walking a credential history.
sub openssl_file_crypt {
	my ($mode, $standard, $secret, $in_path, $out_path, $nopad, $quiet) = @_;
	return 0 unless defined $secret && length $secret && defined $in_path && defined $out_path;
	require File::Temp;
	require File::Spec;
	my ($pfh, $ppath) = eval { File::Temp::tempfile('jawnos-pass-XXXXXX', DIR => File::Spec->tmpdir, UNLINK => 0) };
	return 0 unless $pfh && defined $ppath;
	binmode $pfh;
	print $pfh $secret;
	close $pfh;
	my @args = ('openssl', 'enc', $mode eq 'd' ? '-d' : '-e', '-pass', 'file:' . $ppath, '-' . $standard, '-pbkdf2');
	push @args, '-nopad' if $nopad;
	push @args, '-in', $in_path, '-out', $out_path;
	my $rc = $quiet ? &system_quiet(@args) : system(@args);
	unlink $ppath;
	return $rc == 0 ? 1 : 0;
}

# The same, but returning the plaintext instead of writing it to a path.
sub openssl_file_read {
	my ($standard, $secret, $in_path, $nopad, $quiet) = @_;
	return undef unless defined $secret && length $secret && defined $in_path;
	require File::Temp;
	require File::Spec;
	my ($pfh, $ppath) = eval { File::Temp::tempfile('jawnos-pass-XXXXXX', DIR => File::Spec->tmpdir, UNLINK => 0) };
	return undef unless $pfh && defined $ppath;
	binmode $pfh;
	print $pfh $secret;
	close $pfh;
	my @args = ('openssl', 'enc', '-d', '-pass', 'file:' . $ppath, '-' . $standard, '-pbkdf2');
	push @args, '-nopad' if $nopad;
	push @args, '-in', $in_path;
	my $data;
	my $saved;
	if ($quiet) {
		open($saved, '>&', \*STDERR) or do { unlink $ppath; return undef };
		open(STDERR, '>', '/dev/null') or do { close $saved; unlink $ppath; return undef };
	}
	if (open(my $out, '-|', @args)) {
		binmode $out;
		$data = do { local $/; <$out> };
		close $out;
		$data = undef if $?;
	}
	if ($saved) {
		open(STDERR, '>&', $saved);
		close $saved;
	}
	unlink $ppath;
	return $data;
}

# Seal $content with the inner cipher, returning the openssl container (or undef).
sub note_seal_container {
	my ($content, $secret, $standard) = @_;
	my $spec = &note_cipher_spec($standard);
	if ($spec) {
		my $salt = &note_random_salt();
		return undef unless defined $salt && length $salt == 8;
		my $klen = $spec->{'keylen'} + $spec->{'ivlen'};
		my $kiv = eval { &note_kdf($secret, $salt, $klen) };
		return undef unless defined $kiv && length $kiv == $klen;
		my $key = substr($kiv, 0, $spec->{'keylen'});
		my $iv = substr($kiv, $spec->{'keylen'}, $spec->{'ivlen'});
		my $ct = eval {
			$spec->{'family'} eq 'ctr' ? &note_ctr_mode($spec)->encrypt($content, $key, $iv)
			                           : &note_cbc_mode($spec)->encrypt($content, $key, $iv)
		};
		return undef unless defined $ct;
		return 'Salted__' . $salt . $ct;
	}
	# not a cipher we can run in-process: let openssl do it. The bytes are raw -
	# base64 here only bought a 33% copy on each side.
	my $container = &note_openssl_run(['openssl', 'enc', '-e', '-' . $standard, '-pbkdf2'], $content, $secret);
	return undef unless defined $container && length $container;
	return $container;
}

sub note_encrypter() {
	my ($secret, $content) = @_;
	return undef unless defined $content && length $content;
	$content =~ s/\r?\n$//;
	my $md5 = &shorthand_name(md5_sum($content), 5);
	my $standard = &note_encryption_standard();
	my $container = &note_seal_container($content, $secret, $standard);
	# never hand back a letter that cannot be read again
	return undef unless defined $container && length $container;
	my $almost_ready = encode_base64($container, '') . ':::---:::' . $standard . ':::---:::' . $md5;
	my $returner = &subs::encrypter($secret, $almost_ready);
	return $returner;
}


# Open an openssl container with the inner cipher; undef when it will not open.
# $nopad leaves the PKCS#7 padding on (the file path sniffs the plaintext by its
# own nose, so it asks for the bytes untouched). $limit decrypts only that many
# leading ciphertext bytes - enough to sniff a key without paying for the whole
# file. A limit is only meaningful with $nopad: a note needs its last block to
# strip PKCS#7, so a limited open returns the raw prefix instead.
sub note_open_container {
	my ($container, $secret, $standard, $nopad, $limit) = @_;
	my $spec = &note_cipher_spec($standard);
	if ($spec) {
		# The in-process families run with no openssl fallback: a wrong key then
		# costs nothing but a failed padding check, instead of two forked openssl
		# processes per attempt while the credential history is walked.
		return undef unless substr($container, 0, 8) eq 'Salted__' && length($container) > 16;
		my $salt = substr($container, 8, 8);
		my $ct = substr($container, 16);
		my $take = length $ct;
		if (defined $limit) {
			return undef unless $nopad;
			$take = $limit if $limit < $take;
			if ($spec->{'family'} eq 'cbc') {
				$take = int($take / $spec->{'ivlen'}) * $spec->{'ivlen'};
				$take = $spec->{'ivlen'} if $take == 0 && length($ct) >= $spec->{'ivlen'};
			}
		}
		my $chunk = $take == length($ct) ? $ct : substr($ct, 0, $take);
		my $material = &note_key_material($secret, $salt, $spec);
		return undef unless $material;
		return eval {
			$spec->{'family'} eq 'ctr' ? &note_ctr_mode($spec)->decrypt($chunk, $material->{'key'}, $material->{'iv'})
			                           : &note_cbc_mode($spec, $nopad)->decrypt($chunk, $material->{'key'}, $material->{'iv'})
		};
	}
	# a cipher we cannot run in-process: openssl, and a second try through the
	# legacy provider for the older ciphers
	my $plain = &note_openssl_open($container, $secret, $standard, 0, $nopad);
	return $plain if defined $plain && length $plain;
	return &note_openssl_open($container, $secret, $standard, 1, $nopad);
}

sub note_openssl_open {
	my ($container, $secret, $standard, $legacy, $nopad) = @_;
	my @args = ('openssl', 'enc', '-d', '-' . $standard, '-pbkdf2');
	push @args, '-provider', 'default', '-provider', 'legacy' if $legacy;
	push @args, '-nopad' if $nopad;
	return &note_openssl_run(\@args, $container, $secret);
}

# The file sealing is the very same container, read from and written to a path.
sub note_seal_bytes { my ($plain, $secret, $standard) = @_; return &note_seal_container($plain, $secret, $standard); }
sub note_open_bytes { my ($container, $secret, $standard, $nopad) = @_; return &note_open_container($container, $secret, $standard, $nopad); }

sub seal_file {
	my ($in_path, $out_path, $secret, $standard) = @_;
	my $plain = eval { &read_file($in_path) };
	return 0 unless defined $plain && length $plain;
	my $container = &note_seal_bytes($plain, $secret, $standard);
	return 0 unless defined $container && length $container;
	eval { &write_file($out_path, $container) };
	return(-e $out_path ? 1 : 0);
}

sub open_file {
	my ($in_path, $secret, $standard, $nopad) = @_;
	my $container = eval { &read_file($in_path) };
	return undef unless defined $container && length $container;
	return &note_open_bytes($container, $secret, $standard, $nopad);
}

# ---- fast sealed-file opens --------------------------------------------------
#
# Rock and roll used to read the whole file, derive a key and decrypt every byte
# once per credential in the rotation history. Two facts make that unnecessary:
# a key can be tested on a short prefix (File::Type never looks past byte 5122),
# and a file that opened once will open with the same secret and standard next
# time. The helpers below read the container once, test keys on 16 KB, and remember
# the winner for as long as the file is unchanged. Nothing here changes the
# container: the bytes on disk stay exactly what openssl writes.

our $SEALED_PROBE_BYTES = 16384;

# The identity of a sealed file: any change to it (a reseal) makes a different
# key. inode covers a replace, size and mtime cover an in-place rewrite.
sub sealed_file_identity {
	my ($path) = @_;
	my @st = stat($path);
	return undef unless @st;
	return join "\x1f", $path, $st[1], $st[7], $st[9];
}

# Try candidate secrets and standards in order, decrypting only the prefix for
# each. $inspect receives the prefix and returns a true value (the verdict) when
# it looks like the file wanted. Returns the winner without the body bytes.
sub sealed_file_probe {
	my ($container, $secrets, $standards, $inspect) = @_;
	foreach my $secret (@{$secrets || []}) {
		next unless defined $secret && length $secret;
		foreach my $standard (@{$standards || []}) {
			next unless defined $standard && length $standard;
			my $probe = &note_open_container($container, $secret, $standard, 1, $SEALED_PROBE_BYTES);
			next unless defined $probe && length $probe;
			my $verdict = $inspect ? eval { $inspect->($probe) } : 1;
			next unless $verdict;
			# An openssl-only standard has no prefix mode, so the "probe" above
			# already decrypted the whole stream. Hand it back rather than making
			# the caller decrypt it a second time.
			my $full = &note_cipher_spec($standard) ? undef : $probe;
			return { secret => $secret, standard => $standard, verdict => $verdict, full => $full };
		}
	}
	return undef;
}

# Advance a CTR IV by whole blocks (big-endian, which is what openssl's EVP
# counter is), so a range can start anywhere without decrypting what precedes it.
sub note_iv_advance {
	my ($iv, $blocks) = @_;
	return $iv unless $blocks;
	my $out = $iv;
	my $carry = $blocks;
	for (my $i = length($out) - 1; $i >= 0 && $carry; $i--) {
		my $v = ord(substr($out, $i, 1)) + $carry;
		substr($out, $i, 1) = chr($v & 0xff);
		$carry = int($v / 256);
	}
	return $out;
}

# Decrypt one byte range of a container. CTR is seekable by advancing the IV;
# CBC starts at the requested block using the previous ciphertext block as its IV.
# The caller passes nopad-style files (no padding block to strip from the tail),
# which is exactly the stream rock_and_roll serves today.
sub note_open_slice {
	my ($container, $secret, $standard, $start, $len) = @_;
	my $spec = &note_cipher_spec($standard) or return undef;
	return undef unless substr($container, 0, 8) eq 'Salted__' && length($container) > 16;
	my $salt = substr($container, 8, 8);
	my $ct = substr($container, 16);
	my $total = length $ct;
	$start = 0 if !defined $start || $start < 0;
	return undef if $start > $total;
	$len = $total - $start if !defined $len || $start + $len > $total;
	$len = 0 if $len < 0;
	return '' if $len == 0;
	my $block = $spec->{'ivlen'};
	my $first = int($start / $block);
	my $skip = $start - $first * $block;
	my $take = $skip + $len;
	if ($spec->{'family'} eq 'cbc') {
		$take = int(($take + $block - 1) / $block) * $block;
	}
	my $avail = $total - $first * $block;
	$take = $avail if $take > $avail;
	return undef if $take <= 0;
	my $ct_slice = substr($ct, $first * $block, $take);
	my $material = &note_key_material($secret, $salt, $spec);
	return undef unless $material;
	my $iv = $material->{'iv'};
	if ($spec->{'family'} eq 'ctr') {
		$iv = &note_iv_advance($iv, $first);
	} elsif ($first > 0) {
		$iv = substr($ct, ($first - 1) * $block, $block);
	}
	my $plain = eval {
		$spec->{'family'} eq 'ctr' ? &note_ctr_mode($spec)->decrypt($ct_slice, $material->{'key'}, $iv)
		                           : &note_cbc_mode($spec, 1)->decrypt($ct_slice, $material->{'key'}, $iv)
	};
	return undef unless defined $plain;
	return substr($plain, $skip, $len);
}

# Open a sealed file, remembering the secret/standard that opened it. $range is
# an optional [ start, length ] (length undef means to the end). Returns a hash:
# data, secret, standard, verdict, total, start, length; or { unsatisfiable }.
# With $stream set (and no range, nopad, an in-process cipher and a non-PDF
# verdict) it returns { stream => 1, ct, spec, key, iv, total, ... } instead of
# the body, so the caller can pump the plaintext out a chunk at a time.
our %sealed_file_memo;
sub sealed_file_open {
	my ($in_path, $secrets, $standards, $nopad, $inspect, $range, $stream) = @_;
	my $id = &sealed_file_identity($in_path);
	my $container = eval { &read_file($in_path) };
	return undef unless defined $container && length $container;
	my $cand;
	if ($id && (my $memo = $sealed_file_memo{$id})) {
		$cand = &sealed_file_probe($container, [ $memo->{'secret'} ], [ $memo->{'standard'} ], $inspect);
		delete $sealed_file_memo{$id} unless $cand;
	}
	$cand ||= &sealed_file_probe($container, $secrets, $standards, $inspect);
	return undef unless $cand;
	if ($id) {
		%sealed_file_memo = () if scalar(keys %sealed_file_memo) >= 256;
		$sealed_file_memo{$id} = { secret => $cand->{'secret'}, standard => $cand->{'standard'} };
	}
	my $spec = &note_cipher_spec($cand->{'standard'});
	if ($stream && !$range && $nopad && $spec && ($cand->{'verdict'} // '') !~ /pdf/) {
		return undef unless substr($container, 0, 8) eq 'Salted__' && length($container) > 16;
		my $salt = substr($container, 8, 8);
		my $material = &note_key_material($cand->{'secret'}, $salt, $spec);
		return undef unless $material;
		return {
			stream => 1,
			container => $container,
			secret => $cand->{'secret'},
			standard => $cand->{'standard'},
			verdict => $cand->{'verdict'},
			spec => $spec,
			key => $material->{'key'},
			iv => $material->{'iv'},
			total => length($container) - 16,
		};
	}
	my $result = { secret => $cand->{'secret'}, standard => $cand->{'standard'}, verdict => $cand->{'verdict'} };
	if ($range && $spec && $nopad) {
		my $total = length($container) - 16;
		my ($start, $len) = @{$range};
		$start = 0 if !defined $start || $start < 0;
		return { unsatisfiable => 1, total => $total } if $start >= $total && $total > 0;
		$len = $total - $start if !defined $len || $start + $len > $total;
		my $slice = &note_open_slice($container, $cand->{'secret'}, $cand->{'standard'}, $start, $len);
		return undef unless defined $slice;
		$result->{'data'} = $slice;
		$result->{'total'} = $total;
		$result->{'start'} = $start;
		$result->{'length'} = $len;
		return $result;
	}
	my $data;
	if ($nopad && defined $cand->{'full'}) {
		$data = $cand->{'full'};
	}
	else {
		$data = &note_open_container($container, $cand->{'secret'}, $cand->{'standard'}, $nopad);
	}
	return undef unless defined $data && length $data;
	my $total = length $data;
	if ($range) {
		my ($start, $len) = @{$range};
		$start = 0 if !defined $start || $start < 0;
		return { unsatisfiable => 1, total => $total } if $start >= $total && $total > 0;
		$len = $total - $start if !defined $len || $start + $len > $total;
		$data = substr($data, $start, $len);
		$result->{'start'} = $start;
		$result->{'length'} = $len;
	}
	$result->{'data'} = $data;
	$result->{'total'} = $total;
	return $result;
}

# The security credentials a note of a given moment could have been sealed under,
# newest first. The rows are the same for every note on a page, so they are held
# for a few seconds rather than fetched for each note.
our $note_security_memo;
sub note_security_rows {
	my ($timestamp) = @_;
	my $now = time;
	if (!$note_security_memo || $now - $note_security_memo->{'at'} > 3) {
		my $q = &db_query('select * from security where level != ? and level != ? order by ost desc', 'padlock', 'door');
		$note_security_memo = { at => $now, rows => ($q ? $q->hashes : []) };
	}
	my @rows = @{ $note_security_memo->{'rows'} };
	@rows = grep { ($_->{'ost'} || 0) <= $timestamp } @rows if $timestamp;
	return \@rows;
}

# Unseal one note with one key: the outer Crypt::Simple layer, then the inner
# cipher, then the md5 in the payload to prove the plaintext is the right one.
# Returns undef when the key does not open it, so the caller can try the next.
sub note_unseal {
	my ($key, $contented) = @_;
	my $payload = &subs::decrypter($key, $contented);
	return undef unless defined $payload && length $payload;
	my ($b64, $standard, $md5) = split ':::---:::', $payload, 3;
	return undef unless defined $b64 && length $b64;
	$standard = 'aes-256-ctr' unless defined $standard && length $standard;
	my $container = decode_base64($b64);
	return undef unless defined $container && length $container;
	my $plain = &note_open_container($container, $key, $standard);
	return undef unless defined $plain && length $plain;
	if (defined $md5 && length $md5) {
		# the md5 names the plaintext: when it matches, the key was the right one.
		# (The old check compared a full digest against the short marker and so
		# never actually verified anything.)
		my $mark = lc substr($md5, 0, 5);
		return $plain if &shorthand_name(md5_sum($plain), 5) eq $mark;
		my $chopped = $plain; chomp $chopped;
		return $chopped if &shorthand_name(md5_sum($chopped), 5) eq $mark;
		# the marker does not name it and the bytes are not text: the wrong key
		return undef if $plain =~ /[^\x00-\x7F]/;
	}
	return $plain;
}

# A note's plaintext never changes for a given key and ciphertext, and the same
# notes are read again and again (a page reload, a second window, the socket),
# so the results are held for the life of the worker. Key derivation is the price
# of the scheme - PBKDF2 at 10000 rounds is around twenty milliseconds - and this
# is what keeps the second read of a letter from paying it again. Bounded by
# total size, oldest first, so a long-lived worker cannot grow without limit.
our (%note_memo, @note_memo_order);
our $note_memo_bytes = 0;
my $NOTE_MEMO_MAX = 8 * 1024 * 1024;
sub note_memo_put {
	my ($key, $value) = @_;
	return if exists $note_memo{$key};
	$note_memo{$key} = $value;
	$note_memo_bytes += length($value) + 40;
	push @note_memo_order, $key;
	while ($note_memo_bytes > $NOTE_MEMO_MAX && @note_memo_order) {
		my $old = shift @note_memo_order;
		next unless exists $note_memo{$old};
		$note_memo_bytes -= length($note_memo{$old}) + 40;
		delete $note_memo{$old};
	}
}

sub note_decrypter() {
	my ($secret, $contented, $timestamp, $tries) = @_;
	$tries ||= 0;
	return '' unless defined $contented && length $contented;

	# a plain note is memoised on (key, ciphertext); '' there means a known miss
	my $memo_key;
	if (!$timestamp) {
		$memo_key = md5_sum($secret) . ':' . md5_sum($contented);
		return $note_memo{$memo_key} if defined $note_memo{$memo_key};
	}

	# the key in use now opens almost every note, and one in-process try costs
	# nothing, so it is tried alone first
	my $plain = &note_unseal($secret, $contented);

	# it did not: the note was written before the key rotated, under one of the
	# credentials that were current at $timestamp (or, given none, the whole
	# history), newest first. Working those keys out is not free, so it only
	# happens for the notes that need them.
	unless (defined $plain) {
		foreach my $row ( @{ &note_security_rows($timestamp) } ) {
			my $old = &decrypter($secret, $row->{'credential'});
			next unless defined $old && length $old;
			$plain = &note_unseal($old, $contented);
			last if defined $plain;
		}
	}

	# nothing opened it: the note may predate the oldest credential we hold, so ask
	# again from a moment further back, twice at most
	if (!defined $plain && !$timestamp && $tries < 2) {
		my $deep = &note_decrypter($secret, $contented, &subs::rightNow() * 10000, $tries + 1);
		$plain = $deep if defined $deep && length $deep;
	}

	$plain = '' unless defined $plain;
	&note_memo_put($memo_key, $plain) if defined $memo_key;
	return $plain;
}


sub manufacturer_grabber() {
	my $manufacturers = &subs::db_query('select * from settings where (setting = ? or setting = ?) and value = ? and device = ?', 'pos', 'mab','manufacturer',$device)->hashes;
	my $mans = [];
	foreach my $m ( @{$manufacturers} ) {
		push @{$mans}, $m->{'app'};
	}
	$gb::abilities->{'manufacturer'}->{'options'} = $mans;
}

sub step_ingest() {
	# Turn a batch of the pedometer's cumulative samples into measure
	# appointments - the shape the AP's /wigi collection has always produced.
	# Each sample's `steps` is the watch's running count; what gets recorded is
	# the difference from the sample before it, and `$base` is the cumulative
	# value just before the batch. The AP path sends the whole array with base
	# zero; a BLE push sends one small message carrying its own base, so both
	# delta the same way. A count that went backwards means the pedometer was
	# reset under us (the AP path does that): that sample then stands on its
	# own rather than losing the steps.
	my ($steps, $base) = @_;
	return unless ref $steps eq 'ARRAY' && scalar @{$steps};
	my $last_step = $base || 0;
	my (@measures,$first_step);
	foreach my $step ( @{$steps} ) {
		next unless ref $step eq 'HASH' && defined $step->{'steps'};
		my $ls = $step->{'steps'};
		$step->{'steps'} = $step->{'steps'} - $last_step;
		if ($step->{'steps'} < 0) {
			$step->{'steps'} = $ls;
		}
		$last_step = $ls;
		$step->{'timestamp'} = $step->{'timestamp'} * 1000;
		if ($step->{'steps'} > 0 && !$first_step) {
			$first_step = $step->{'timestamp'};
		}
		if ($step->{'timestamp'} && $step->{'steps'} > 0) {
			$step->{'uuid'} = &subs::random_string_creator(19);
			push @measures, $step;
		}
	}
	return unless scalar @measures > 0;
	my $jstep = encode_json \@measures;
	&Manager::appointment_writer(&subs::controller_builder(), {
		app => &subs::unformat_name(&subs::setting_grabber({ app => 'me', setting => 'my_name' })),
		type => 'measure',
		measures => $jstep,
		timestamp => &subs::rightNow(),
		seen => 'yes',
		duration => $first_step ? &subs::rightNow() - $first_step : 1
	});
}

sub embedded_wigi() {
	my $data = shift;
	my $ip = $data->{'ip'};
	my $timestamp = $data->{'timestamp'};
	my $edt = $data->{'edt'};
	my $chip_id = $data->{'chip_id'};

	my $watch = &subs::device_lister($timestamp, $edt, undef, $chip_id);
	if ($watch->{'ip'}) {
		my $wat_set = &subs::embedded_operator_door($edt, $chip_id);
		my $watch_settings = eval { return decode_json $wat_set } || {};
		my $auth = $watch_settings->{'__specs'}->{'authorization'};
		my $author = `echo $auth | base64 --decode`;
		my $authorization = &subs::note_decrypter($watch_settings->{'__shutup'}->{'patience'}, $author);


		my $wigi_url = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/wigi?timestamp=' . $timestamp . '&authorization=' . $auth;
		my $ua = Mojo::UserAgent->new();
		my $res = $ua->insecure(1)->get($wigi_url)->result;

		my $wigi = eval { return decode_json $res->body } || {};
		my $rauth = $wigi->{'authorization'};
		my $rauthorization = `echo $rauth | base64 --decode`;
		my $remote_auth = &subs::note_decrypter($watch_settings->{'__shutup'}->{'patience'}, $rauthorization);

		if (secure_compare($remote_auth, $authorization)) {
			my $buttons = $wigi->{'buttons'};
			my $measures = $wigi->{'measures'};
			my $steps = $measures->{'steps'};
			my $files = $wigi->{'files'};

			foreach my $button ( @{$buttons}) {
				if ($button->{'room'} && $button->{'button'}) {
					my $returner = &subs::edt_button_presser({
						timestamp => ($button->{'timestamp'} * 1000),
						room => $button->{'room'},
						watch_settings => $watch_settings,
						button => $button->{'button'},
						toggle => $button->{'toggle'},
						edt => $edt,
						chip_id => $chip_id
					});
				}
			}
			&subs::step_ingest($steps);
		}

	}
}

sub embedded_location_grabber() {
	my $returner = shift;
	$returner->{'signatorial'} = &subs::signatorial_designer() unless $returner->{'signatorial'};
	my $watch = &subs::device_lister($returner->{'timestamp'} || &subs::rightNow(),'teletype') || {};
	if (eval { $watch->{'ip'} }) {
		my $ping = 'timeout .2 ping -c 1 ' . $watch->{'ip'};

		my $ping_test = `$ping`;
		if ($ping_test =~ /ttl/gi) {
			my $ua = Mojo::UserAgent->new();
			$ua->connect_timeout(1);
			my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/my_position';
			my $res = eval { return $ua->insecure(1)->get($watch_home)->result };
			if (eval { return decode_json $res->body }) {
				my $co = eval { return decode_json $res->body };
				$returner->{'latitude'} = $co->{'lat'};
				$returner->{'longitude'} = $co->{'lng'};
				$returner->{'accuracy'} = $co->{'accuracy'} if $co->{'accuracy'};
			}
		}
	}
	return $returner;
}

sub embedded_internal_jobs() {
	my $op_d = shift;
	foreach my $k ( keys %{$op_d} ) {
		if ($gb::embedded_components->{$op_d->{$k}->{'component'}}->{'direction'} eq 'input') {
			foreach my $ko ( keys %{$op_d} ) {
				if ($op_d->{$ko}->{'app'} eq $op_d->{$k}->{'app'} && $gb::embedded_components->{$op_d->{$ko}->{'component'}}->{'direction'} eq 'output') {
					$op_d->{'__specs'}->{'internal_jobs'}->{$k} = [] if !$op_d->{'__specs'}->{'internal_jobs'}->{$k};
					push @{$op_d->{'__specs'}->{'internal_jobs'}->{$k}}, $op_d->{$ko};
				}
			}
		}
	}
	return $op_d;
}

sub intelligent_automation_toggle() {
	my $data = shift;
	my $app = $data->{'app'};
	my $state = $data->{'state'};
	my $appt_uuid = $data->{'appt_uuid'};
	my $uuid = $data->{'uuid'};
	my $value = $data->{'value'};
	my $type = $data->{'type'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $remote_address = $data->{'remote_address'};
	my $now = &subs::rightNow();
	my $measure = $data->{'measure'};
	my $asets = &subs::settings_grabber({ app => $app, settings => ['ia','toggle'] });
	my $jia = $asets->{'ia'};
	my $ia = eval { return decode_json $jia } || {};
	my $counted = 0;
	foreach my $chip ( keys %{$ia} ) {
		foreach my $i ( keys %{$ia->{$chip}} ) {
			next if $remote_address && $ia->{$chip}->{$i}->{'ip'} eq $remote_address;
			if ($ia->{$chip}->{$i}->{'direction'} eq 'output') {
				my $when = 'later';
				if ($timestamp <= $now + 1000) {
					$when = 'now';
				}

				if ($data->{'measure'} && $measure ne $ia->{$chip}->{$i}->{'measure'}) {
				#	return;
				}
				if ($ia->{$chip}->{$i}->{'movement'} eq 'start') {
					my $returner = &Manager::embedded_toggle({
						app => $app,
						pin => $ia->{$chip}->{$i}->{'pin'},
						ip => $ia->{$chip}->{$i}->{'ip'},
						edt => $ia->{$chip}->{$i}->{'edt'},
						component => $ia->{$chip}->{$i}->{'component'},
						timestamp => $timestamp,
						'state' => $state,
						measure => $measure,
						chip_id => $chip,
						'when' => $when,
						uuid => $uuid,
						appt_uuid => $appt_uuid,
						value => $data->{'value'},
						counted => $counted
					});
				}
				elsif ($ia->{$chip}->{$i}->{'movement'} eq 'measure') {
					my $edt_data = {
						app => $app,
						pin => $ia->{$chip}->{$i}->{'pin'},
						ip => $ia->{$chip}->{$i}->{'ip'},
						edt => $ia->{$chip}->{$i}->{'edt'},
						component => $ia->{$chip}->{$i}->{'component'},
						timestamp => $timestamp,
						'state' => $state,
						measure => $measure,
						chip_id => $chip,
						'when' => $when,
						uuid => $uuid,
						appt_uuid => $appt_uuid,
						value => $data->{'value'},
						counted => $counted
					};
					if ($type eq 'text') {
						if ($data->{'measurement'} && $ia->{$chip}->{$i}->{'named_measure'}) {
							if ($data->{'measurement'} eq $ia->{$chip}->{$i}->{'named_measure'}) {
								$edt_data->{'state'} = 'on';
							}
							else {
								$edt_data->{'state'} = 'off';
							}
						}
					}
					else {
						if ($data->{'measurement'} && $ia->{$chip}->{$i}->{'threshold'}) {
							if ($ia->{$chip}->{$i}->{'comparison'} eq '>') {
								if ($data->{'measurement'} > $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							} elsif ($ia->{$chip}->{$i}->{'comparison'} eq '>=') {
								if ($data->{'measurement'} >= $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							} elsif ($ia->{$chip}->{$i}->{'comparison'} eq '<=') {
								if ($data->{'measurement'} <= $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							} elsif ($ia->{$chip}->{$i}->{'comparison'} eq '<') {
								if ($data->{'measurement'} < $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							}
							else {
								if ($data->{'measurement'} == $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							}
							&Manager::embedded_toggle($edt_data);
							$counted++;
						}
					}
				}
			}

		}
	}

}

# A rename into a name the house already knows is a merge, and the settings the
# two apps share meet on one row each: this lists those rows so the panel can
# pick which value keeps the name per setting - and which ones merge naturally
# (nfc tags concatenate, measures union their keys, contact lists join).
sub name_change_pairs {
	my ($app, $new_app) = @_;
	my @pairs;
	my %seen;
	my %natural = map { $_ => 1 } qw/nfc app_measures phones emails/;
	# window and view state, not a choice: the uuid names the app, scrollTop and
	# jopen are where its window was left, dimensions is how big it was - nobody
	# merging two records wants to choose between two scroll positions.
	my %transient = map { $_ => 1 } qw/uuid scrollTop jopen dimensions/;
	# who a person is, rather than how their app is set up: a contact either side
	# holds joins the record, so it is always on the panel - a number filed under
	# the number itself, renamed to a real person, must not quietly vanish.
	my %identity = map { $_ => 1 } qw/phone email phones emails/;
	my $olds = &subs::db_query('select setting, value from settings where app = ?', $app)->hashes;
	my $news = &subs::db_query('select setting, value from settings where app = ?', $new_app)->hashes;
	my (%new_by, %old_by);
	$new_by{$_->{'setting'}} ||= $_->{'value'} for @{$news};
	$old_by{$_->{'setting'}} ||= $_->{'value'} for @{$olds};
	my %settings = map { $_ => 1 } (keys %new_by, keys %old_by);
	foreach my $setting ( sort keys %settings ) {
		next if $seen{$setting}++;
		next if $transient{$setting};
		my $old_present = exists $old_by{$setting} ? 1 : 0;
		my $new_present = exists $new_by{$setting} ? 1 : 0;
		next unless $old_present || $new_present;
		# a setting only one side holds is carried over silently by the rename,
		# so it is only worth a row when it says who the person is
		next unless ($old_present && $new_present) || $identity{$setting};
		my $old_value = $old_by{$setting};
		my $new_value = $new_by{$setting};
		# nothing to choose when both sides already say the same thing: a row per
		# shared setting buried the handful that actually differ
		next if ($old_present && $new_present && defined $old_value && defined $new_value && $old_value eq $new_value);
		my $only = '';
		$only = 'old' if $old_present && !$new_present;
		$only = 'new' if $new_present && !$old_present;
		# A value that is still what a brand-new app would be born with is nothing
		# anybody chose, so between it and a value somebody set, the set one is the
		# one to keep: the panel pre-selects it rather than making every row be
		# decided by hand.
		my $old_default = $old_present ? (&subs::setting_is_default($setting, $app, $old_value) ? 1 : 0) : 0;
		my $new_default = $new_present ? (&subs::setting_is_default($setting, $new_app, $new_value) ? 1 : 0) : 0;
		# a list either side holds is a merge the moment both sides have one; a
		# one-sided row is just keep-or-drop, so it wears no merge option
		my $natural = ($natural{$setting} && !$only) ? 'merge' : '';
		my $prefer = '';
		if ($only eq 'old') {
			# the renaming app alone holds it: keeping it is the default, dropping
			# it the deliberate escape
			$prefer = 'new';
		}
		elsif ($only eq 'new') {
			# the record being renamed into alone holds it: it survives unless
			# somebody says to drop it
			$prefer = 'old';
		}
		else {
			$prefer = 'old' if $old_default && !$new_default;
			$prefer = 'new' if $new_default && !$old_default;
		}
		push @pairs, {
			setting => $setting,
			old_value => $old_value,
			new_value => $new_value,
			old_present => $old_present,
			new_present => $new_present,
			old_default => $old_default,
			new_default => $new_default,
			only => $only,
			prefer => $prefer,
			natural => $natural
		};
	}
	return \@pairs;
}

# Is this value just what a brand-new app would be born with (setting_initializer)?
# True for the fixed ones (visible, permanent, cost, enc, public, schedule,
# navigation), for the me app's worth, duration, currency, unit and warranty - on
# any device, since a default made on the phone is still the default here, and the
# me rows are per device - and for the app's own name as its notification line.
# Anything else is a value somebody chose for this app.
my %setting_defaults_memo;
sub setting_is_default {
	my ($setting, $app, $value) = @_;
	return 0 unless defined $value && length $value;
	my %fixed = (
		visible => 'checked', permanent => 'checked', cost => '0', enc => 'on',
		public => 'off', schedule => 'once', navigation => 'none',
	);
	return 1 if exists $fixed{$setting} && $value eq $fixed{$setting};
	return 1 if $setting eq 'notification_text' && $value eq &subs::format_name($app || '');
	return 0 unless grep { $_ eq $setting } qw/worth duration currency unit warranty/;
	unless (scalar keys %setting_defaults_memo) {
		foreach my $k ( qw/worth duration currency unit warranty/ ) {
			my $rows = &subs::db_query('select value from settings where app = ? and setting = ?', 'me', $k)->hashes;
			foreach my $r ( @{$rows} ) {
				next unless defined $r->{'value'} && length $r->{'value'};
				$setting_defaults_memo{$k}->{ $r->{'value'} } = 1;
			}
		}
	}
	return 1 if $setting_defaults_memo{$setting} && $setting_defaults_memo{$setting}->{$value};
	return 0;
}

# How two values of a setting join: nfc, measures and the typed contact lists are
# lists at heart, so a natural merge keeps both sides; anything else keeps the
# renaming app's value. Merging with an empty side simply keeps the side that has
# a value - which is what a one-sided contact row does.
sub merge_setting_values {
	my ($setting, $old, $new) = @_;
	my $old_has = (defined $old && length $old) ? 1 : 0;
	my $new_has = (defined $new && length $new) ? 1 : 0;
	return $new if !$old_has;
	return $old if !$new_has;
	if ($setting eq 'nfc') {
		my $a = eval { return decode_json $old } || [];
		my $b = eval { return decode_json $new } || [];
		$a = [ $a ] if ref $a eq 'HASH';
		$b = [ $b ] if ref $b eq 'HASH';
		my %seen;
		my @merged = grep { !$seen{$_->{'uuid'} || $_}++ } (@{$b}, @{$a});
		return encode_json \@merged;
	}
	if ($setting eq 'app_measures') {
		my $a = eval { return decode_json $old } || {};
		my $b = eval { return decode_json $new } || {};
		my %merged = (%{$a}, %{$b});
		return encode_json \%merged;
	}
	if ($setting eq 'phones' || $setting eq 'emails') {
		# the typed contact lists join the same way: both sides' entries stay, and
		# an entry the same number or address already covers is not written twice
		my $kind = ($setting eq 'phones') ? 'phone' : 'email';
		my $a = eval { return decode_json $old } || [];
		my $b = eval { return decode_json $new } || [];
		$a = [ $a ] if ref $a eq 'HASH';
		$b = [ $b ] if ref $b eq 'HASH';
		my %seen;
		my @merged = grep {
			next unless ref $_ eq 'HASH';
			my $key = &subs::contact_normalizer($kind, $_->{'value'});
			$key ||= $_->{'uuid'};
			!$seen{$key}++;
		} (@{$b}, @{$a});
		return encode_json \@merged;
	}
	return $new;
}

# Applies the panel's choices and leaves only the rows the rename will carry:
# 'new' drops the target's row (the renaming app's value takes the name), 'old'
# drops the renaming app's row (the existing value stays), and 'merge' writes
# the joined value under the target name and drops both.
sub name_change_apply {
	my ($app, $new_app, $choices) = @_;
	foreach my $setting ( keys %{$choices} ) {
		my $pick = $choices->{$setting} || '';
		if ($pick eq 'new') {
			&subs::db_query('delete from settings where app = ? and setting = ?', $new_app, $setting);
		}
		elsif ($pick eq 'old') {
			&subs::db_query('delete from settings where app = ? and setting = ?', $app, $setting);
		}
		elsif ($pick eq 'merge') {
			# either side may be absent (a one-sided contact row), so read the row
			# rather than dereferencing a missing one
			my $old_row = &subs::db_query('select value from settings where app = ? and setting = ?', $app, $setting)->hashes->[0];
			my $new_row = &subs::db_query('select value from settings where app = ? and setting = ?', $new_app, $setting)->hashes->[0];
			my $oldv = ref $old_row ? $old_row->{'value'} : '';
			my $newv = ref $new_row ? $new_row->{'value'} : '';
			my $merged = &subs::merge_setting_values($setting, $oldv, $newv);
			&subs::db_query('delete from settings where app = ? and setting = ?', $app, $setting);
			&subs::db_query('delete from settings where app = ? and setting = ?', $new_app, $setting);
			&subs::setting_setter({ app => $new_app, setting => $setting, value => $merged })
				if defined $merged && length $merged;
		}
	}
}

sub setting_setter() {
	%setting_memo = ();
	my $settings = shift;
	my $app = $settings->{'app'};
	my $original_app = $app;
	my $setting = $settings->{'setting'};
	my $subsetting = $settings->{'subsetting'};
	my $value = $settings->{'value'};
	my $timestamp = $settings->{'timestamp'} || &rightNow();
	my $browser_tab_id = $settings->{'browser_tab_id'};
	my $dev = $settings->{'device'} || &device_setter();
	# A row arriving from a peer's snapshot is a mirror of a change that already
	# happened somewhere else. It must be written, but its side effects - a
	# websocket reload, a BLE toggle push, a task re-registration, a name-change
	# broadcast that opens the app window - belong to the machine where the
	# person made the change. Replaying them here is what opened Libro Chequing
	# on every machine and flipped jobs off during a merge.
	my $sync = $settings->{'sync'} ? 1 : 0;
	my ($db,$database) = &database_grabber();
	my $server_time = $settings->{'server_time'} || &rightNow();
	if ($setting eq 'name_change') {
		$value = &subs::unformat_name($value);
		&db_update('appointments', { account => $value, server_time => $server_time }, { account => $app });
		&db_update('appointments', { project => $value, server_time => $server_time }, { project => $app });
		&db_update('appointments', { manufacturer => $value, server_time => $server_time }, { manufacturer => $app });
		&db_update('appointments', { app => $value, server_time => $server_time }, { app => $app });
		&db_update('settings', { app => $value, server_time => $server_time }, { app => $app });

		foreach my $ex ( qw/model option subcategory option_category/ ) {
			&db_update($ex, { name => $value }, { name => $app });
		}


		my ($db,$database,$sql) = &database_grabber();
		my $tables = `sqlite3 $database .tables`;
		my @u = sort split ' ', $tables;
		foreach my $t ( @u ) {
			if (eval { $db->query('select app from ' . $t . ' limit 1') } ) {
				&db_update($t, { app => $value, server_time => $server_time }, { app => $app });
			}
			else {

			}
		}
		unless ($sync) {
			&Websocket::send('server', { console => '$(".' . $app . '_close_button").trigger("click");', timestamp => $timestamp });
			&Websocket::send('server', { console => 'appointmentGrabber(\'' . $value . '\',\'' . $timestamp .'\',\'ws\');'});
		}
		$app = $value;
	}
	if ($setting eq 'pos') {
		&subs::manufacturer_grabber();
		my $old_settings = &subs::settings_grabber({ app => $app });
		my $old_sc = &subs::db_query('select * from settings where app=? and setting like ? escape ?', $app, 'sc\_%', '\\')->hashes;
		my $buc = &subs::cache_get({ app => 'relational', context => 'buckets' });
		my $bub = &subs::cache_get({ app => 'relational', context => 'bubbles' });

		foreach my $os ( @{$old_sc} ) {

			my $osc = eval { return decode_json $os->{'value'} } || [];
			foreach my $sc ( @{$osc} ) {
				my $set = &subs::settings_grabber({ uuid => $sc });
				delete $buc->{$set->{'app'}};
				delete $bub->{$set->{'app'}};
				my $otsc = eval { return decode_json $set->{'sc_' . $old_settings->{'pos'}} } || [];
				if (scalar @{$otsc} > 0) {
					@{$otsc} = grep { $_ ne $old_settings->{'uuid'} } @{$otsc};
					my $jotsc = encode_json $otsc;

					&subs::setting_setter({ app => $set->{'app'}, setting => 'sc_' . $old_settings->{'pos'}, value => $jotsc });
				}
				my $ntsc = eval { return decode_json $set->{'sc_' . $value} } || [];
				push @{$ntsc}, $old_settings->{'uuid'};
				my $jntsc = encode_json $ntsc;
				&subs::setting_setter({ app => $set->{'app'}, setting => 'sc_' . $value, value => $jntsc });

			}
			delete $buc->{$original_app};
			delete $bub->{$original_app};
			&subs::cache_set({ app => 'relational', context => 'buckets', warranty => '-5y'}, $buc);
			&subs::cache_set({ app => 'relational', context => 'bubbles', warranty => '-5y'}, $bub);
		}
	}
	if (($setting eq 'pos' || $setting eq 'mab') && !$sync) {
		&Websocket::send('tab', { console => 'configurationReloader(\'' . $app . '\');' });
	}
	if ($setting eq 'phone') {
		$value =~ s/\D+//gi;
	}
	if ($setting eq 'web' && !$sync) {
		if ($value =~ /[0-9A-Za-z]/) {
			&Websocket::send('server', { console => '$(\'.app_act[app="' . $app . '"][type="web"]\').attr(\'web\', \'' . $value . '\').show();' });
		}
		else {
			&Websocket::send('server', { console => '$(\'.app_act[app="' . $app . '"][type="web"]\').attr(\'web\', \'\').hide();' });
		}
	}
	if ($setting eq 'colour' || $setting eq 'name_change' || $setting eq 'mab') {
		my $buc = &subs::cache_get({ app => 'relational', context => 'buckets' });
		my $bub = &subs::cache_get({ app => 'relational', context => 'bubbles' });
		delete $buc->{$original_app};
		delete $bub->{$original_app};
		&subs::cache_set({ app => 'relational', context => 'buckets', warranty => '-5y'}, $buc);
		&subs::cache_set({ app => 'relational', context => 'bubbles', warranty => '-5y'}, $bub);
	}
	if ($setting eq 'toggle' && $settings->{'source'} eq 'panel' && !$sync) {
		&intelligent_automation_toggle({ app => $app });

	}
	if ($setting eq 'toggle' && !$sync) {
		# The wrapper draws this enabler through icon_path, so the pushed update has
		# to as well: the /images/decipherable on/off pictures are only the fallback,
		# and pushing them here dropped a started or stopped appointment back to the
		# hand-drawn glyphs whatever set was showing.
		my $toggle_src = &icon_path($value, '/images/decipherable/' . $value . '.png');
		my $toggle_style = ($value eq 'on')
			? 'background-color:green;border-color:green;box-shadow:0 0 8px 2px green;'
			: 'background-color:#555555;border-color:#555555;opacity:0.45;filter:grayscale(1);';
		&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.enabler[type="toggle"\').attr(\'status\',\'' . $value . '\').attr(\'src\', \'' . $toggle_src . '\').attr(\'style\', \'' . $toggle_style . '\');' });
		&subs::watch_toggle_pusher({ app => $app, value => $value });
	}
	if ($setting eq 'site_type') {
		&subs::db_delete('cache', { context => 'navigation_information' });
	}

	if ($setting eq 'uuid') {
		my $s_old = &db_select('settings', undef, { app => $app, setting => $setting, device => $dev })->hashes->[0];
		if ($s_old->{'value'}) {
			return { app => $app, timestamp => $timestamp, setting => $setting, value => $s_old->{'value'}, device => $dev, browser_tab_id => $browser_tab_id };
		}
	}

	# A row is keyed by (app, setting, device, subsetting). The delete that clears the
	# previous row used '=', so an undef in ANY key column matched nothing (SQL
	# 'x = NULL' is never true): every write left its predecessor behind and cost/…
	# piled up duplicate rows (342 groups on one machine), and a window-state save
	# whose app was missing (the 'tab' frames push scrollTop/jopen with no app) kept
	# adding a fresh app-null row. 'is' is NULL-safe - two NULLs compare equal,
	# anything else as '=' - so every key column clears properly.
	my $old_set = eval { &db_query('delete from settings where app is ? and setting is ? and device is ? and subsetting is ?', $app, $setting, $dev, $subsetting) };
	&db_insert('settings', {
		app => $app,
		timestamp => $timestamp,
		setting => $setting,
		value => $value,
		server_time => $server_time,
		device => $dev,
		browser_tab_id => $browser_tab_id,
		uuid => $settings->{'uuid'} || &random_string_creator(25),
		subsetting => $subsetting
	});
	if ($setting eq 'colour') {
		unless ($settings->{'silent'} eq 'yes') {
			&Websocket::send('server', { console => '$(\'.top_navbar[app="' . $app . '"]\').css({\'background-color\':\'' . $value . '\'});' }) unless $sync;
			# refresh the stored clothesline so the manager view picks up the new colour
			&hang_to_dry();
		}
	}
	elsif ($setting eq 'icon_set') {
		# invalidate the shared caches across all workers
		&icon_set_forget();
		&cache_delete({ app => '__president', context => 'config' });
		&cache_delete({ app => 'me', context => 'pseudonyms' });
		&cache_delete({ context => 'template' });
		&cache_delete({ context => 'header' });
		&Websocket::send('server', { console => 'jawnosReloadIcons();' }) unless $sync;
	}
	elsif ($setting eq 'tasks' && !$sync) {
		&subs::task_checker($app);
	}
	# these run after the new value is the one on record: the schedule is built
	# from what the settings say, not from what they said
	if (($setting eq 'nightly_evaluation_days' || $setting eq 'evaluation_cadence') && !$sync) {
		# the cadence or the days changed under a standing wish: the schedule follows
		&subs::evaluation_schedule_arrange($app) if $app;
	}
	if ($setting eq 'evaluation_machine' && !$sync) {
		# the machine changed: this queue follows right away, the other machines
		# when boot or their next settings sync brings them the change
		&subs::nightly_evaluation_reconcile();
	}
	return { app => $app, timestamp => $timestamp, setting => $setting, value => $value, device => $dev, browser_tab_id => $browser_tab_id };
}

sub setting_grabber() {
	my $settings = shift;
	if ($settings->{'uuid'}) {
		my $s = &subs::db_select_simple('settings', undef, { value => $settings->{'uuid'}, setting => 'uuid', subsetting => $settings->{'subsetting'} })->hashes->[0];
		$settings->{'app'} = $s->{'app'};
	}

	my $app = $settings->{'app'};
	my $device_defined = 0;
	$device_defined = 1 if $settings->{'device'};
	$settings->{'device'} = $settings->{'device'} || &device_setter();
	my $returner;
	# benign and settings are parameters of this sub, not columns of the settings
	# table; riding into the where clause they made the select die with 'no such
	# column: "benign"', and the eval below swallowed the answer with it
	my $params = { %{$settings} };
	delete @{$params}{qw/benign settings/};

	# request-scoped memo: the same scalar answer is recomputed zero times per
	# request. A worker handles one request at a time, so this is private to it.
	# colour is excluded (a blank one is filled from the theme) and any settings
	# write flushes the whole memo.
	my $memo_key;
	if ($setting_memo_on && (($params->{'setting'} // '') ne 'colour')) {
		$memo_key = join "\x1f", $app // '', map { "$_=" . ($params->{$_} // '') } sort keys %{$params};
		return $setting_memo{$memo_key} if exists $setting_memo{$memo_key};
	}

	if (my $q = eval { return &db_select_simple('settings', ['value'], $params) }) {
		my $list = $q->hashes;

		if (scalar @{$list} > 1) {
			$returner = $list->[-1]->{'value'};
		}
		else {
			$returner = $list->[0]->{'value'};
		}
	}
	if (defined $settings->{'setting'} && $settings->{'setting'} eq 'colour' && !$settings->{'benign'}) {
		# Only fill in a colour that was never set. Re-picking one that is already
		# there is what repainted every appointment whenever the theme changed;
		# the button in configure/misc_setting_list does that on purpose instead.
		$returner = &theme_colour_for_app($app, $returner, $settings->{'device'}) unless (length $returner);
	}
	$setting_memo{$memo_key} = $returner if defined $memo_key;
	return $returner;
}

# A misc setting as this device should read it: this device's own row when it has
# one, then the person's own ("Me"), then nothing - the caller names the
# fallback. The configure panel's per-device blocks write the tab's row, so a
# value chosen under Me used to be invisible to the manager, which read the
# device's row alone and fell back to its defaults on every load. An explicit
# device may be named, for the panel asking after a tab that is not this one.
sub misc_setting() {
	my $setting = shift;
	my $device = shift || &device_setter();
	my $value = &setting_grabber({ app => 'misc', setting => $setting, device => $device });
	unless (defined $value && length $value) {
		my $signatorial = &signatorial_designer();
		$value = &setting_grabber({ app => 'misc', setting => $setting, device => $signatorial }) if ($signatorial && $signatorial ne $device);
	}
	return $value;
}

sub settings_grabber() {
	my $settings = shift;
#	return {};

	if ($settings->{'uuid'}) {
		my $s = &subs::db_select_simple('settings', undef, { value => $settings->{'uuid'}, setting => 'uuid', subsetting => $settings->{'subsetting'} })->hashes->[0];
		$settings->{'app'} = $s->{'app'};
	}


	my $app = $settings->{'app'};
	my $device_defined = 0;
	$device_defined = 1 if $settings->{'device'};
	$settings->{'device'} = $settings->{'device'} || &device_setter();
#	$settings->{'device'} = $device unless $settings->{'device'} ne '';
	my $returner = { app => $app };

	my $query = 'select * from settings where app=? and device=?';
	my $q;
	if ($settings->{'settings'}) {
		if (scalar @{$settings->{'settings'}}) {

			my $query = 'select * from settings where app=? and device=? and ( ';
			for (my $n = 0; $n <= scalar @{$settings->{'settings'}}; $n++) {
				if ($n == scalar @{$settings->{'settings'}}) {
					$query .= ' setting = ? ';
				} else {
					$query .= ' setting = ? or ';
				}

			}
			$query .= ')';
			$q = &db_raw($query, $app,$settings->{'device'}, @{$settings->{'settings'}});
		}
	}
	else {
		$q = &db_raw($query, $app,$settings->{'device'});
	}
	my $list = $q;
	if ($settings->{'subsetting'}) {
		@{$list} = grep { $_->{'subsetting'} eq $settings->{'subsetting'} } @{$list};
	}
	foreach my $s ( @{$list } ) {
		$returner->{$s->{'setting'}} = $s->{'value'};
	}
	# (the old fallback here re-called $q->hashes, which is exhausted by then and
	# always empty - dead code; the loop above already set every fetched setting)
	unless ($returner->{'uuid'}) {
		if (($settings->{'benign'} || 0) != 1) {
			my $uuid = &random_string_creator(25);
			$returner->{'uuid'} = $uuid;
			&setting_setter({ app => $app, setting => 'uuid', subsetting => $settings->{'subsetting'}, value => $uuid });
		}
	}
	if (exists $returner->{'colour'} && !$settings->{'benign'}) {
		# a blank colour gets one; an existing colour is left alone so a theme
		# change does not repaint the appointments behind the user's back
		$returner->{'colour'} = &theme_colour_for_app($app, $returner->{'colour'}, $settings->{'device'}) unless (length $returner->{'colour'});
	}
	return $returner;
}

sub setting_deleter() {
	%setting_memo = ();
	my $setting = shift;
	$setting->{'device'} = $setting->{'device'} || &device_setter();
	if ($setting->{'subsetting'}) {
	#	&Manager::deletion_registration({ table => 'settings', app => $setting->{'app'}, setting => $setting->{'setting'}, server_time => $setting->{'server_time'}, subsetting => $setting->{'subsetting'} });
		&db_delete('settings', { app => $setting->{'app'}, setting => $setting->{'setting'}, subsetting => $setting->{'subsetting'}, device => $setting->{'device'} });
	}
	else {
	#	&Manager::deletion_registration({ table => 'settings', app => $setting->{'app'}, setting => $setting->{'setting'} });
		&db_delete('settings',{ app => $setting->{'app'}, setting => $setting->{'setting'}, device => $setting->{'device'} });
	}
	return $setting;
}


sub file_encrypter() {
	my $data = shift;

	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $suds = $data->{'suds'} || &subs::suds_grabber();
	my $pre_server_time = &subs::ago_calc('1h', &subs::rightNow());
	my $file_db = &subs::db_query('select * from appointments where app=? and file != ? and (encryption_standard is null or server_time >= ?)', $app,'',$pre_server_time);
	my $filings = $file_db->hashes;
	my $server_time = &subs::rightNow();
	return unless &subs::setting_grabber({ app => $app, setting => 'enc' } ) eq 'on';
	my $success = 0;
	my $file_join;
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";

	foreach my $filing ( @{$filings} ) {
		my $files = eval { return decode_json $filing->{'file'} } || [];
		if (eval { $files->{'f'} }) {
			$files = [ $files ];
		}
		foreach my $fi ( @{$files} ) {
			foreach my $file_type ( qw/f thumb/ ) {
				my $f = $fi->{$file_type};

				if (-e $f && $f !~ /\.enc/gi) {

					my $path = &subs::terminal_name($f);
					my $enc_path = $path;
					my @enc_path = split '/', $enc_path;
					my @ext = split /\./, $enc_path[-1];
					my $ext = $ext[-1];
					my $original_filename = pop @enc_path;
					$enc_path = ( join '/', @enc_path ) . '/' . &subs::random_string_creator(20) . '.' . $ext . '.enc';
					my $secret = $suds;
					# first, store the encryption standard.

					&seal_file($path, $enc_path, $secret, $encryption_standard);
					`shred -u $path`;
					$f = $enc_path;
					$fi->{$file_type} = $f;
					$fi->{'server_time'} = &subs::rightNow();
					$fi->{'uuid'} = &subs::random_string_creator(17) unless $fi->{'uuid'};
					if ($file_type eq 'f') {
						$fi->{'of'} = $original_filename;

						if ($fi->{'att'}) {
							my $att_file = &subs::db_select($fi->{'att'}, undef, { uuid => $fi->{'att_uuid'}, app => $app })->hashes->[0];

							my $atf = eval { return decode_json $att_file->{'file'} } || [];
							foreach my $af ( @{$atf} ) {
								if ($af->{'uuid'} eq $fi->{'uuid'}) {
									$af->{'f'} = $f;
									$af->{'server_time'} = &subs::rightNow();
									$af->{'of'} = $original_filename;
								}
							}
							my $jaf = encode_json $atf;
							&subs::db_update($fi->{'att'}, { file => $jaf, server_time => &subs::rightNow() }, { uuid => $att_file->{'uuid'}, app => $att_file->{'app'} });
						}
					}
					$success = 1;
				}
			}
		}
		$file_join = encode_json $files;
		if ($success == 1) {
			#&subs::db_query('update appointments set server_time = ?, file = ?, encryption_standard = ? where app= ? and uuid = ?',
			#	&subs::rightNow(), $file_join, $encryption_standard, $app, $filing->{'uuid'});
			&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $file_join, encryption_standard => $encryption_standard }, { app => $app, uuid => $filing->{'uuid'} });
			&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $filing->{'uuid'} .'\');'});
		}

	}
}


sub file_decrypter() {
	my $data = shift;
	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'};
	my $suds = $data->{'suds'};
	my $file_db = &subs::db_query('select * from appointments where app=? and file is not null', $app);
	my $filings = $file_db->hashes;
	my $success = 0;
	my $file_join;
	my $server_time = &subs::rightNow();
	# One credential list and one sniffer for the whole job, not a DB query and a
	# fresh File::Type per file.
	my @secrets;
	my $passwords = &subs::db_query('select * from security where level != ? and level != ? order by server_time DESC','padlock','door');
	foreach my $p ( @{ $passwords->hashes } ) {
		my $secret = &subs::decrypter($suds, $p->{'credential'});
		push @secrets, $secret if defined $secret && length $secret;
	}
	my $ft = File::Type->new();
	my $inspect = sub {
		my $fd = $ft->checktype_contents($_[0]);
		return ($fd ne 'application/octet-stream' || ($_[0] =~ /webm/)) ? $fd : undef;
	};
	foreach my $filing ( @{$filings} ) {
		my $files = eval { return decode_json $filing->{'file'} } || [];
		foreach my $fi ( @{$files} ) {
			foreach my $file_type ( qw/f thumb/ ) {
				my $f = $fi->{$file_type};
				if (-e $f && $f =~ /\.enc/gi) {
					my $encryption_standard = $filing->{'encryption_standard'} || &setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
					my $enc_path = &subs::terminal_name($f);


					my $path = $enc_path;
					if ($fi->{'of'}) {
						my @f = split '/', $path;
						pop @f;
						push @f, $fi->{'of'};
						$path = join '/', @f;
					}
					$path =~ s/\.enc$//gi;
					my $opened = &sealed_file_open($enc_path, \@secrets, [ $encryption_standard ], 0, $inspect);
					if ($opened) {
						&write_file($path, $opened->{'data'});
						$f = $path;
						`shred -u $enc_path`;
						$success = 1;
					}



					$fi->{$file_type} = $f;
					$fi->{'server_time'} = &subs::rightNow();
					$fi->{'uuid'} = &subs::random_string_creator(7) unless $fi->{'uuid'};

					if ($fi->{'att'} && $file_type eq 'f') {
						my $att_file = &subs::db_select($fi->{'att'}, undef, { uuid => $fi->{'att_uuid'}, app => $app })->hashes->[0];
						my $atf = eval { return decode_json $att_file->{'file'} } || [];
						foreach my $af ( @{$atf} ) {
							if ($af->{'uuid'} eq $fi->{'uuid'}) {
								$af->{'f'} = $f;
								$af->{'server_time'} = &subs::rightNow();
							}
						}
						my $jaf = encode_json $atf;
						&subs::db_update($fi->{'att'}, { file => $jaf, server_time => &subs::rightNow() }, { uuid => $att_file->{'uuid'}, app => $att_file->{'app'} });
					}

				}
			}

		}
		$file_join = encode_json $files;
		if ($success == 1) {
			&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $file_join, encryption_standard => undef }, { app => $app, uuid => $filing->{'uuid'} });
		}
#		&subs::db_query('update appointments set server_time = ?, file = ?, encryption_standard = ? where app= ? and uuid = ?',
#			&subs::rightNow(), $file_join, undef, $app, $filing->{'uuid'}) if $success == 1;
		&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $filing->{'uuid'} .'\');'});
	}
}

sub window_closer() {
	my $app = shift;
	my $browser_tab_id = shift;
	my $timestamp = &subs::rightNow();

	&Websocket::send('server', { browser_tab_id => $browser_tab_id, not_me => 1, console => '$(".' . $app . '_close_button").trigger("click");', timestamp => $timestamp });
	undef $gb::ws->{$app}->{$browser_tab_id};
}

sub config_reader() {
	my $cache = &subs::cache_get({ app => '__president', context => 'config' });
	if ($cache) {
		return $cache;
	}

	my $signatorial = &subs::signatorial_designer();
	my $device = &subs::device_setter();
	foreach my $dt ( ( @gb::device_types, $signatorial )  ) {
		foreach my $k ( @gb::misc_settings ) {
			my $s = $k . "_background_colour";
			my $req = &db_query('select value from settings where setting = ? and app = ? and device = ?',$s,'misc',$dt);
			my $qu = $req->hashes;

			foreach my $q ( @{$qu } ) {
				$config->{$dt}->{$k}->{'background_colour'} = $q->{'value'} || $config->{$k}->{'background_colour'};
			}
			if ($dt eq $signatorial && !$config->{$dt}->{$k}->{'background_colour'}) {
				$config->{$dt}->{$k}->{'background_colour'} = $config->{$device}->{$k}->{'background_colour'};
			}
		}
	}
	$config->{'device'} = &device_setter();
	# the selected icon set for the current device; stored in the shared config
	# cache (invalidated on configure changes) so every prefork worker agrees
	my $is = &db_query('select value from settings where setting = ? and app = ? and device = ?', 'icon_set', 'misc', $device)->hashes;
	$config->{'icon_set'} = $is->[0]->{'value'} if scalar @{$is};
	my $environment = $config->{'environment'};
	if ($environment =~ /^dev/) {
		$config->{'environment'} = 'development';
	}
	elsif ($environment =~ /^pro/) {
		$config->{'environment'} = 'production';
	}

	&subs::cache_set({ app => '__president', context => 'config', warranty => '-10m' }, $config);
	return $config;
}


sub cache_set() {
	my ($params,$data) = @_;
	my $app = &subs::unformat_name($params->{'app'});
	my $context = $params->{'context'};
	my $subcontext = $params->{'subcontext'} || undef;
	my $timestamp = $params->{'timestamp'} || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my $json_data = encode_sereal $data;
	my ($db,$database,$sql) = &subs::database_grabber();
	&cache_delete({ app => $app, context => $context, subcontext => $subcontext });
	my $warranty;
	if ($params->{'warranty'}) {
		$warranty = &subs::ago_calc($params->{'warranty'}, &subs::rightNow());
	}
	else {
		$warranty = &subs::ago_calc(&subs::setting_grabber({ app => $app, setting => 'warranty' }), &subs::rightNow()) || &subs::ago_calc(&subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', &subs::rightNow());
	}
	my $lid = undef;
	my $count = 0;

		my $success = eval { return &db_insert('cache', {
			app => $app,
			context => $context,
			subcontext => $subcontext,
			data => $json_data,
			timestamp => $timestamp,
			server_time => $server_time,
			warranty => $warranty,
			device => $device,
			uuid => &random_string_creator(25)
		});
	};
}

sub cache_delete() {
	my ($params) = @_;
	$params->{'device'} = $device;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $result = &db_delete('cache', $params);
}

sub cache_get() {
	my ($params) = @_;
	$params->{'device'} = $device;
	my $returner;
	my $results = &subs::db_select_simple('cache', ['data'], $params)->hashes;
	my $result = $results->[0];
	my $json_data = $result->{'data'};
	if ($result->{'data'}) {
		$returner = eval { return decode_sereal $json_data };
		return $returner if $returner;
	}
}

# Gossip dedupe for relayed requests. A relay carries a relay_id, minted once by
# the machine that first sent it, and every machine that handles it claims the
# id here. INSERT OR IGNORE makes claim-and-check atomic, so of two copies that
# race in exactly one is "fresh" and the rest are dropped. cache is local (never
# synced), and the rows are pruned by age, so a machine forgets a relay only
# long after it has stopped circulating.
sub stale_action_ms() {
	# How old a user action may be before it is treated as a replay rather than a
	# press: a machine that comes back after being away flushes the actions it
	# queued, and applying those minutes or hours later re-closes sessions the
	# person already stopped. Fifteen minutes is longer than any live press takes
	# to arrive over the mesh and far shorter than an offline spell.
	return 15 * 60 * 1000;
}

sub relay_fresh() {
	my ($id) = @_;
	return 1 unless $id;
	my $now = &subs::rightNow();
	my $q = &subs::db_query('insert or ignore into cache (uuid, context, app, device, server_time, timestamp) values (?,?,?,?,?,?)',
		$id, 'relay', '__president', &subs::device_setter(), $now, $now);
	my $fresh = ($q && $q->rows) ? 1 : 0;
	&subs::db_query('delete from cache where context=? and server_time < ?', 'relay', $now - 600000) if $fresh;
	return $fresh;
}

sub file_device_renamer() {
	my $data = shift;
	my $file = $data->{'file'};
	my $app = $data->{'app'};
	my $is_thumb = $data->{'is_thumb'} || 0;
	undef $data->{'is_thumb'};
	my $misc_settings = $data->{'misc_settings'};
	my $type = $data->{'type'};

	my @f = split '/', $file;
	my $destination;
	my $asset = $f[-1];

	if ($f[-2] eq 'thumbs') {
		$is_thumb = 1;
	}
	if (!$app) {
		if ($f[-2] eq 'thumbs') {
			$app = $f[-3];
		}
		else {
			$app = $f[-2];
		}
	}
	my @asset = split /\./, $asset;
	my $assetual = $asset;
	$assetual =~ s/\.enc$//gi;
	my $ext = $asset[-1];
	if ($asset[-1] eq 'enc') {
		$ext = $asset[-2];
	}

	if ($type) {
		if ($type eq 'recording') {
			$type = 'rec';
		}
		elsif ($type eq 'image') {
			$type = 'photo';
		}
		elsif ($type eq 'audio') {
			$type = 'music';
		}
		if (my $location = &subs::setting_grabber({ app => 'misc', setting => $type . '_location', device => $device})) {
			$destination = &subs::home($location . '/' . $app . '/');
		}
	}


	unless ($destination) {
		$misc_settings = &Manager::misc_setting_list() unless $misc_settings;
		if ($assetual =~ /\.mp3$|\.m4a$|\.flac$|\.aiff$|\.weba$|\.wav$/gi) {
			$destination = &subs::home($misc_settings->{$device}->{'music_location'} . '/' . $app . '/');
			$type = 'audio';
		}
		elsif ($assetual =~ /\.jpg$|\.xcf$|\.png$|\.bmp$/gi) {
			$destination = &subs::home($misc_settings->{$device}->{'photo_location'} . '/' . $app . '/');
			$type = 'image';
		}
		elsif ($assetual =~ /\.mov$|\.avi|\.webm$|\.mp4$|\.mkv$/gi) {
			$destination = &subs::home($misc_settings->{$device}->{'video_location'} . '/' . $app . '/');
			$type = 'video';
		}
		elsif ($assetual =~ /\.pdf$/gi) {
			$destination = &subs::home($misc_settings->{$device}->{'document_location'} . '/' . $app . '/');
			$type = 'document';
		}
		else {
			$destination = &subs::home($misc_settings->{$device}->{'download_location'} . '/' . $app . '/');
			$type = 'software';
		}
	}
	if ($is_thumb == 1) {
		$destination = $destination . 'thumbs/';
	}
	return ($destination,$asset,$type,$app);
}

sub file_media_information() {
	my $file_data = shift;
	my $file = shift || $file_data->{'f'};



	if ($file_data->{'type'} eq 'image') {
		my $command = 'ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 ' . $file;
		my $res = `$command`;
		chomp $res;
		my @res = split ',', $res;
		$file_data->{'info'} = { width => $res[0], height => $res[1] };
	}
	elsif ($file_data->{'type'} eq 'audio') {

		my $command = 'ffprobe -print_format json -show_entries stream=codec_name:format -select_streams a:0 -v quiet ' . $file;

		my $jres = `$command`;
		my $res = eval { return decode_json $jres } || {};
		my $format = $res->{'format'};
		if ($format->{'duration'}) {
			$file_data->{'info'} = $format;
		}
		else {
			my $command = 'ffprobe -v error -select_streams a:0 -show_entries stream=duration -of csv=p=0 ' . $file;
			my $res = `$command`;
			chomp $res;
			my @res = split ',', $res;
			my $duration = $res[0];
			$file_data->{'info'} = { duration => $duration };
		}
	}
	elsif ($file_data->{'type'} eq 'video') {
		my $command = 'ffprobe -print_format json -show_chapters -show_entries stream=height,width,duration,codec_name:format -select_streams v:0 -v quiet ' . $file;
		my $jres = `$command`;
		my $res = eval { return decode_json $jres } || {};
		my $format = $res->{'format'};
		my $chapters = $res->{'chapters'};

		$file_data->{'info'} = $format;
		$file_data->{'info'}->{'chapters'} = $chapters;
		foreach my $d ( @{$res->{'streams'}} ) {
			foreach my $dr ( keys %{$d} ) {
				$file_data->{'info'}->{$dr} = $d->{$dr};
			}
		}
	}
	return $file_data;
}


sub music_transmitter() {
	my $c = shift;
	my $data = shift;
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		my $file = $data->{'file'};
		my $domain = $data->{'domain'};
		my $mao = eval { return decode_json &subs::setting_grabber({ app => 'music', setting => 'mao' }) } || {};
		my $remote_machines = &subs::db_query('select * from remote_machines where connection=?','active')->hashes;
		my $signatorial = &subs::signatorial_designer();
		my $toggle = $data->{'toggle'};
		my $seek = $data->{'seek'} || 0;
		my $volume = $data->{'volume'};
		my $timestamp = $data->{'timestamp'};
		my $music_data = $data->{'music_data'};
		my $queuing = $data->{'queuing'};
		foreach my $rm ( @{$remote_machines} ) {
			if ($domain eq $rm->{'fqdn'} || $domain eq $rm->{'ip'}) {
				my $address = $rm->{'fqdn'};
				my $ping = `timeout .5 ping -c 1 $address`;
				if ($ping =~ /ttl/gi) {
					$rm = &Manager::remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $signatorial, rm => $rm });
					my $server_time = &subs::rightNow();
					$seek = $seek + (($server_time - $timestamp) / 1000);
					$music_data = encode_json $music_data;

					$music_data = encode_base64 &subs::encrypter(&subs::session_suds($c), $music_data);
					my $latency = ($server_time - $timestamp) / 1000;
					my $url = $rm->{'manager'} . '/music/receiver?timestamp=' . $timestamp . '&latency=' . $latency . '&queuing=' . $queuing . '&file=' . $file . '&domain=' . $config->{'domain'} . '&volume=' . $volume . '&toggle=' . $toggle . '&seek=' . $seek . '&music_data=' . $music_data;
					my $res = $rm->{'ua'}->post($url)->result;
					if ($res->is_success) {
						my $bod = eval { return decode_json $res->body } || {};
						$bod->{'browser_tab_id'} = $data->{'browser_tab_id'};
						&Websocket::send('music', $bod);
					}
				}
			}
		}
	}, { name => 'music transmitter' });
};

sub vacuum() {
	my $app = shift;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = rightNow();
	my $app_q = &db_query('select * from appointments where app=?',$app);
	my $appts = $app_q->hashes;
	if (scalar @{$appts} == 0 && &setting_grabber({ app => $app, setting => 'permanent' }) ne 'checked') {
		&Websocket::send('server', { console => '$(".' . $app . '_close_button").trigger("click");', timestamp => $timestamp });

		foreach my $t ( qw/appointments tickets settings continent websites tickets cache subcategory option model option_category mailbox websockets/) {
			&db_query('delete from ' . $t . ' where app=?',$app);
		}
	}
}
sub vacuum_app() {
	my $app = shift;
	my $timestamp = rightNow();
	my ($db,$database,$sql) = &subs::database_grabber();
	my $app_q = &db_query('select * from appointments where app=?',$app);
	my $appts = $app_q->hashes;
	foreach my $app ( @{$appts} ) {
		if ($app->{'file'}) {
			my @files = split ',', $app->{'file'};
			foreach my $f ( @files ) {
				if (-e $f) {
					`shred -u $f`;
				}
			}
		}
	}
	&Websocket::send('server', { console => '$(".' . $app . '_close_button").trigger("click");', timestamp => $timestamp });
	sleep 1;
	foreach my $t ( qw/appointments tickets settings continent websites tickets cache subcategory option model option_category mailbox websockets/) {
		&db_query('delete from ' . $t . ' where app=?',$app);
	}

}

# The location types a device can point at a folder and archive to: one per
# <location>_location / <location>_archive setting pair, and one folder each
# under the archive root.
sub location_types {
	return qw/music download photo document video scan rec/;
}

# The archive root of this machine: the configure panel's pick first — it is a
# misc setting, so the root can be chosen without editing config.json — then
# config.json's archive_dir. Tidied: ~ resolved, no trailing slash. Undef when
# this machine is not an archive.
sub archive_root {
	# the panel's pick wants the settings table, which the very first boot may
	# not have open yet; config.json is the fallback either way
	my $dir = eval { return &setting_grabber({ app => 'misc', setting => 'archive_dir' }) };
	$dir = $config->{'archive_dir'} unless (defined $dir && length $dir && lc($dir) ne 'null');
	return undef unless (defined $dir && length $dir);
	my $root = &home($dir);
	$root =~ s{/+$}{};
	return $root;
}

# Where an item lands inside an archive: <root>/<location>/<path inside the
# location folder>. The location has to be one we know, and the relative path
# cannot climb out of it, since the sending machine chooses both. `folder` is
# the location's folder, `parent` the folder the item's own file goes in.
sub archive_destination {
	my $data = shift;
	my $location = $data->{'location'};
	return { error => 'unknown location' } unless grep { $_ eq $location } &location_types();
	my $root = $data->{'root'} || &archive_root();
	return { error => 'no archive_dir on this machine' } unless $root;
	# the root is usually a mounted drive, so a drive that has not come up has
	# to fail the transfer rather than have its folders invented on the disk
	# below it
	return { error => 'archive root is not there' } unless -d $root;
	my $relative = defined $data->{'path'} ? $data->{'path'} : '';
	$relative =~ s{\\}{/}g;
	my @parts;
	foreach my $part (split m{/+}, $relative) {
		next if $part eq '' || $part eq '.';
		# .. resolves against what came before it, and cannot climb above the
		# location folder because there is nothing above it to pop
		if ($part eq '..') { pop @parts; next; }
		push @parts, $part;
	}
	my $inside = join '/', @parts;
	my $folder = $root . '/' . $location;
	my @upper = @parts;
	pop @upper if scalar @upper;
	return {
		root => $root,
		location => $location,
		folder => $folder,
		parent => $folder . (scalar @upper ? '/' . join('/', @upper) : ''),
		relative => $inside,
		path => $folder . (length $inside ? '/' . $inside : '')
	};
}

# A selected path's archive plan. The location whose folder holds the path,
# the machine that location archives to, and where the item lands inside the
# archive. The longest matching location folder wins, so a scans folder inside
# documents resolves to scans; a tie, which is two names for one folder, goes
# to the earlier location type, so document beats scan. A path under no
# location, or in one with no archive machine, is refused by name rather than
# guessed at, and every path appears once however many selections repeat it.
sub archive_plan {
	my $data = shift;
	my $items = $data->{'items'} || [];
	my $settings = $data->{'settings'} || {};
	my $machines = $data->{'machines'} || [];
	my %machine_for;
	foreach my $rm ( @{$machines} ) {
		$machine_for{$rm->{'signatorial'}} = $rm if $rm->{'signatorial'};
		$machine_for{$rm->{'uuid'}} = $rm if $rm->{'uuid'};
	}
	# the folders to match against, longest first; within one length the
	# location type order decides, so a tie is not hash order
	my @roots;
	my $order = 0;
	foreach my $location ( &location_types() ) {
		$order++;
		my $base = $settings->{$location . '_location'};
		next unless (defined $base && length $base);
		$base = &home($base);
		$base =~ s{/+$}{};
		push @roots, { location => $location, base => $base, order => $order };
	}
	@roots = sort { length($b->{'base'}) <=> length($a->{'base'}) || $a->{'order'} <=> $b->{'order'} } @roots;

	my (@jobs, @refused, %seen);
	foreach my $item ( @{$items} ) {
		my $path = $item->{'path'};
		next unless (defined $path && length $path);
		$path = &home($path);
		$path =~ s{/+$}{};
		next if $seen{$path}++;
		my $match;
		foreach my $root ( @roots ) {
			next unless ($path eq $root->{'base'} || $path =~ m{^\Q$root->{'base'}\E/});
			$match = $root;
			last;
		}
		unless ($match) {
			push @refused, { path => $path, reason => 'no location folder holds it' };
			next;
		}
		my $archive = $settings->{$match->{'location'} . '_archive'};
		my $rm = $archive ? $machine_for{$archive} : undef;
		unless ($rm) {
			push @refused, { path => $path, location => $match->{'location'}, reason => 'its location has no archive machine' };
			next;
		}
		# the item may be the location folder itself, which lands at its top
		my $relative = ($path eq $match->{'base'}) ? '' : substr($path, length($match->{'base'}) + 1);
		push @jobs, {
			path => $path,
			location => $match->{'location'},
			relative => $relative,
			folder => (($item->{'type'} || '') eq 'folder' || -d $path) ? 1 : 0,
			remote_uuid => $rm->{'uuid'},
			remote_hostname => $rm->{'hostname'}
		};
	}
	return { jobs => \@jobs, refused => \@refused };
}

# Make sure the archive root (config.json's archive_dir) has one folder per
# location type. A blank archive_dir — the default — means this machine is not
# an archive, so nothing is touched; an archive_dir that is not there yet is
# left alone rather than invented, since it may be a mount that has not come up.
# Folders that already exist are left exactly as they are, so this is safe to
# run at any time. Pass a path to check a specific root.
sub archive_scaffolder {
	my $dir = shift;
	my $root = (defined $dir && length $dir) ? &home($dir) : &archive_root();
	return { enabled => 0, reason => 'no archive_dir set' } unless $root;
	$root =~ s{/+$}{};
	return { enabled => 0, dir => $root, reason => 'archive_dir does not exist' } unless -d $root;
	my (@created, @existing, @failed);
	foreach my $location (&location_types()) {
		my $path = $root . '/' . $location;
		if (-d $path) { push @existing, $location; next; }
		if (mkdir $path) { push @created, $location; }
		else { push @failed, $location; }
	}
	return { enabled => 1, dir => $root, created => \@created, existing => \@existing, failed => \@failed };
}

# The queue for work that has to outlive the request that asked for it: its own
# SQLite file under ~/.president. The web process enqueues, the worker in
# President.pl runs, and the folders app lists the same rows, so there is one
# place that says what is waiting, running or failed.
my $minion;
sub minion_grabber {
	unless ($minion) {
		my $dir = &home('~/.president');
		mkdir $dir unless -d $dir;
		$minion = Minion->new(SQLite => $dir . '/minion.db');
		# every process registers the same list, so a job can only be enqueued
		# under a name the worker also knows
		my $tasks = &minion_task_list();
		foreach my $task ( keys %{$tasks} ) {
			$minion->add_task($task => $tasks->{$task});
		}
	}
	return $minion;
}

# A manager-to-manager agent for a job to use. The worker runs under
# President.pl and cannot see Manager.pl, so this is the small twin of
# Manager::remote_useragent_maker: the cookie jar stored on the
# remote_machines row is the whole of the authentication, and the tunnel-aware
# manager url is the whole of the addressing.
sub remote_agent_for {
	my $remote_uuid = shift;
	my $rm = &remote_machine_lister({ uuid => $remote_uuid, limit => 1 });
	return { error => 'no machine is registered for ' . ($remote_uuid || '(nothing)') } unless (ref $rm && $rm->{'manager'});
	$rm = &remote_machine_tunnel_processor($rm);
	my $ua = Mojo::UserAgent->new;
	$ua->max_response_size(0);
	$ua->insecure(1);
	$ua->inactivity_timeout(3000);
	if ($rm->{'cookie'}) {
		my $cookies = eval { return decode_json $rm->{'cookie'} } || [];
		foreach my $cookie ( @{$cookies} ) {
			$ua->cookie_jar->add(
				Mojo::Cookie::Response->new(
					name => $cookie->{'name'},
					value => $cookie->{'value'},
					domain => $cookie->{'domain'},
					path => $cookie->{'path'}
				)
			);
		}
	}
	return { ua => $ua, manager => $rm->{'manager'}, hostname => $rm->{'hostname'}, rm => $rm };
}

# The worker half of archiving: deliver one queued item. The far machine is
# asked first whether it already has the file at that size and time, because a
# retry after a failed folder re-runs the whole folder and everything already
# sent should cost one small request each instead of the file itself. Errors
# are collected rather than thrown on the first bad file, so one unreadable
# file does not hide the rest; a job with any of them fails at the end, and
# Minion's retry skips what did land.
sub archive_transfer_job {
	my ($job, $data) = @_;
	my $agent = &remote_agent_for($data->{'remote_uuid'});
	if ($agent->{'error'}) { $job->fail($agent->{'error'}); return; }
	my $ua = $agent->{'ua'};
	my $manager = $agent->{'manager'};

	my @files;
	if ($data->{'folder'}) {
		@files = &dir_listing([$data->{'path'}], 1);
		@files = sort @files;
	}
	else { @files = ( $data->{'path'} ) }

	my ($sent, $skipped, $bytes, $count) = (0, 0, 0, 0);
	my @errors;
	my @rows;
	foreach my $file ( @files ) {
		$count++;
		my $relative = $data->{'relative'};
		if ($data->{'folder'}) {
			my $tail = substr($file, length($data->{'path'}));
			$tail =~ s{^/+}{};
			$relative = length $relative ? $relative . '/' . $tail : $tail;
		}
		my $size = -s $file;
		my $mtime = (stat($file))[9];

		my $probe = eval {
			return $ua->post($manager . '/manager/folders/archive/probe' => form => {
				location => $data->{'location'},
				path => $relative
			})->result->json;
		};
		if (!$probe || $probe->{'status'} ne 'ok') {
			push @errors, ($relative || $file) . ': ' . (($probe && $probe->{'error'}) || 'the archive machine did not answer');
			next;
		}
		if ($probe->{'exists'} && defined $probe->{'size'} && defined $size && $probe->{'size'} == $size
			&& (!defined $probe->{'mtime'} || !defined $mtime || $probe->{'mtime'} == $mtime)) {
			$skipped++;
			next;
		}

		my $res = eval {
			return $ua->post($manager . '/manager/folders/archive/receive' => form => {
				location => $data->{'location'},
				path => $relative,
				mtime => $mtime,
				file => { file => $file }
			})->result->json;
		};
		if (!$res || $res->{'status'} ne 'ok') {
			push @errors, ($relative || $file) . ': ' . (($res && $res->{'error'}) || 'the upload did not land');
			next;
		}
		$sent++;
		$bytes += ($res->{'size'} || $size || 0);
		push @rows, &archive_manifest_row({ path => $file, relative => $relative });
		if ($count % 5 == 0) {
			$job->note(progress => "sent $sent, skipped $skipped, $bytes bytes");
			# a cancel asked for from the folders app cannot kill this process
			# from there, so the job stops itself at the next file
			if (($job->info->{'notes'} || {})->{'cancel'}) {
				$job->note(progress => "stopped after $count files");
				$job->finish({ sent => $sent, skipped => $skipped, bytes => $bytes, files => scalar @files, cancelled => 1 });
				return;
			}
		}
	}

	my $result = {
		sent => $sent,
		skipped => $skipped,
		bytes => $bytes,
		files => scalar @files,
		manifest_rows => scalar @rows,
		archive_host => $agent->{'hostname'},
		location => $data->{'location'}
	};

	# what was just delivered goes into the archive's manifest, in one request
	# per job rather than one per file: the far machine appends a line and only
	# rewrites the listing itself when the journal has piled up
	if (scalar @rows) {
		my $batch_size = 500;
		for (my $n = 0; $n < scalar @rows; $n += $batch_size) {
			my $last = ($n + $batch_size - 1 > $#rows) ? $#rows : $n + $batch_size - 1;
			my @batch = @rows[$n .. $last];
			my $res = eval {
				return $ua->post($manager . '/manager/folders/archive/manifest/append' => form => {
					location => $data->{'location'},
					rows => encode_json \@batch
				})->result->json;
			};
			if (!$res || $res->{'status'} ne 'ok') {
				push @errors, 'manifest: ' . (($res && $res->{'error'}) || 'the listing could not be updated');
				last;
			}
		}
	}
	if (scalar @errors) {
		$result->{'errors'} = \@errors;
		$job->fail($result);
		return;
	}
	$job->note(progress => "sent $sent, skipped $skipped, $bytes bytes");
	$job->finish($result);
}

# The type an archive row carries, in the same words the folders app uses for a
# file, so a listing built from a manifest reads like a local one.
sub archive_media_type {
	my $path = shift || '';
	return 'image' if $path =~ /\.(jpe?g|png|bmp|tiff?|xcf|webp|gif|heic)$/i;
	return 'audio' if $path =~ /\.(wav|mp3|aiff|weba|m4a|flac|aac|ogg|opus)$/i;
	return 'video' if $path =~ /\.(mp4|avi|mov|webm|mkv|m4v|wmv)$/i;
	return 'pdf' if $path =~ /\.pdf$/i;
	return 'document' if $path =~ /\.(docx?|xlsx?|pptx?|txt|rtf|odt)$/i;
	return 'subtitles' if $path =~ /\.(vtt|srt)$/i;
	return 'other';
}

# One manifest row for a file: what it is and where it sits inside its location
# folder, with the media facts worked out once, so the apps reading a manifest
# never have to open the file. `relative` is what makes a row portable - it
# means the same thing on whichever machine is holding the drive.
sub archive_manifest_row {
	my $data = shift;
	my $path = $data->{'path'};
	my $type = &archive_media_type($path);
	my $row = {
		relative => $data->{'relative'},
		size => -s $path,
		mtime => (stat($path))[9],
		type => $type
	};
	if ($type eq 'image' || $type eq 'audio' || $type eq 'video') {
		my $file_data = &file_media_information({ f => $path, type => $type });
		$row->{'info'} = $file_data->{'info'} if $file_data->{'info'};
	}
	return $row;
}

# What an archive holds for a location: the compacted manifest with the journal
# read over the top of it. An append is one line, so a transfer never rewrites
# the listing; a read is one file plus whatever has piled up since. A line that
# does not parse - a write caught mid-flight - is skipped rather than fatal,
# and the last row for a path wins.
sub archive_manifest_read {
	my $data = shift;
	my $dir = $data->{'dir'};
	my %rows;
	my $json = $dir . '/manifest.json';
	if (-e $json) {
		my $compacted = eval { return decode_json scalar read_file($json) } || [];
		foreach my $row ( @{$compacted} ) {
			next unless (ref $row && defined $row->{'relative'} && length $row->{'relative'});
			$rows{$row->{'relative'}} = $row;
		}
	}
	my ($lines, $skipped) = (0, 0);
	my $journal = $dir . '/manifest.jsonl';
	if (-e $journal) {
		foreach my $line ( read_file($journal) ) {
			chomp $line;
			next unless (defined $line && length $line);
			$lines++;
			my $batch = eval { return decode_json $line };
			unless (ref $batch eq 'ARRAY') { $skipped++; next }
			foreach my $row ( @{$batch} ) {
				next unless (ref $row && defined $row->{'relative'} && length $row->{'relative'});
				$rows{$row->{'relative'}} = $row;
			}
		}
	}
	return { rows => [ map { $rows{$_} } sort keys %rows ], journal_lines => $lines, journal_skipped => $skipped };
}

# Write the listing a reader sees. Rewriting the whole thing is the one
# expensive write there is, so it happens when the journal has piled up or a
# rescan asks for it, never per received file. A temporary file is renamed into
# place, so a reader can never catch half of one, and the journal is dropped
# once it is folded in.
sub archive_manifest_write {
	my $data = shift;
	my $dir = $data->{'dir'};
	my @rows = @{$data->{'rows'} || []};
	my $json = $dir . '/manifest.json';
	my $temp = $json . '.tmp';
	write_file($temp, encode_json [ map {
		{
			relative => $_->{'relative'},
			size => $_->{'size'},
			mtime => $_->{'mtime'},
			type => $_->{'type'},
			($_->{'info'} ? (info => $_->{'info'}) : ())
		}
	} @rows ]);
	rename $temp, $json;
	my $journal = $dir . '/manifest.jsonl';
	unlink $journal if -e $journal;
	return { rows => scalar @rows, path => $json };
}

# Read an archive location again from the drive itself and write the manifest
# from what is really there, for a drive filled by hand or shuffled outside the
# queue. It opens every media file it finds, so it runs as a job and says where
# it is in its notes.
sub archive_manifest_rescan_job {
	my ($job, $data) = @_;
	my $dest = &archive_destination({ location => $data->{'location'}, path => '' });
	if ($dest->{'error'}) { $job->fail($dest->{'error'}); return }
	unless (-d $dest->{'folder'}) {
		&archive_manifest_write({ dir => $dest->{'folder'}, rows => [] });
		$job->finish({ location => $data->{'location'}, rows => 0, files => 0 });
		return;
	}
	my @files = &dir_listing([$dest->{'folder'}], 1);
	my @rows;
	my $count = 0;
	foreach my $file ( sort @files ) {
		$count++;
		$job->note(progress => "read $count of " . scalar(@files)) if $count % 25 == 0;
		my $relative = substr($file, length($dest->{'folder'}) + 1);
		next unless (defined $relative && length $relative);
		# the listing is not part of the listing
		next if $relative =~ m{^manifest\.jsonl?$};
		push @rows, &archive_manifest_row({ path => $file, relative => $relative });
	}
	my $written = &archive_manifest_write({ dir => $dest->{'folder'}, rows => \@rows });
	$job->note(progress => 'read ' . scalar(@files) . ' files');
	$job->finish({ location => $data->{'location'}, rows => $written->{'rows'}, files => scalar @files });
}

# What an archive machine holds for a location, asked for by uuid, with the
# absolute folder those rows sit in - so a caller can address the files on that
# machine without ever mounting it. An unreachable machine is an answer too:
# the caller carries on without the archive instead of failing the whole
# listing.
sub archive_manifest_fetch {
	my $data = shift;
	my $agent = &remote_agent_for($data->{'remote_uuid'});
	return { error => $agent->{'error'} } if $agent->{'error'};
	my $res = eval {
		return $agent->{'ua'}->post($agent->{'manager'} . '/manager/folders/archive/manifest' => form => {
			location => $data->{'location'}
		})->result->json;
	};
	return { error => 'the archive machine did not answer' } unless ($res && $res->{'status'} eq 'ok');
	return { %{$res}, hostname => $agent->{'hostname'} };
}

# Where a photo that has left this disk can still be found. The archive machine
# holding photo_location is asked for its manifest once, and `locate` then
# answers for one path at a time, by the path's place inside the location. Only
# missing files are ever asked about, so a listing of live files never waits on
# a machine, and a machine that cannot be reached answers with nothing rather
# than failing the listing.
sub archive_image_lookup {
	my $data = shift;
	my $misc = $data->{'misc_settings'} || &Manager::misc_setting_list();
	my $device = &subs::device_setter();
	my $here = $misc->{$device}->{'photo_location'};
	my $archive = $misc->{$device}->{'photo_archive'};
	return {} unless ($here && $archive);
	my $machines = &subs::remote_machine_lister({ self => 'no' });
	my %machine_for;
	foreach my $rm ( @{$machines} ) {
		$machine_for{$rm->{'signatorial'}} = $rm if $rm->{'signatorial'};
	}
	my $rm = $machine_for{$archive};
	return {} unless ($rm && $rm->{'uuid'});
	my $manifest = &archive_manifest_fetch({ remote_uuid => $rm->{'uuid'}, location => 'photo' });
	return {} if $manifest->{'error'};
	my $folder = $manifest->{'folder'} || '';
	my $base = &home($here);
	$base =~ s{/+$}{};
	my %rows = map { $_->{'relative'} => $_ } @{$manifest->{'rows'} || []};
	my $locate = sub {
		my $path = shift;
		return undef unless (defined $path && length $path);
		return undef unless $path =~ m{^\Q$base\E/};
		my $relative = substr($path, length($base) + 1);
		my $row = $rows{$relative};
		return undef unless ($row && ($row->{'type'} || '') eq 'image');
		return {
			path => (length $folder ? $folder . '/' . $relative : $relative),
			relative => $relative,
			remote_uuid => $rm->{'uuid'},
			remote_hostname => $manifest->{'hostname'} || ''
		};
	};
	return { locate => $locate, folder => $folder, remote_uuid => $rm->{'uuid'}, hostname => $manifest->{'hostname'} || '' };
}

# Where a fetched item lands here: the same place inside this machine's own
# folder for that location. The inverse of the archive plan, and the only path
# a fetch writes to; the relative path is resolved so it cannot climb out.
sub archive_local_destination {
	my $data = shift;
	my $location = $data->{'location'};
	my $relative = $data->{'relative'} || '';
	return { error => 'unknown location' } unless grep { $_ eq $location } &location_types();
	my $base = &setting_grabber({ app => 'misc', setting => $location . '_location' });
	return { error => 'this machine has no folder for ' . $location } unless (defined $base && length $base);
	$base = &home($base);
	$base =~ s{/+$}{};
	my @parts;
	foreach my $part ( split m{/+}, $relative ) {
		next if $part eq '' || $part eq '.';
		return { error => 'the path climbs out of the location' } if $part eq '..';
		push @parts, $part;
	}
	my $inside = join '/', @parts;
	my @upper = @parts;
	pop @upper if scalar @upper;
	return {
		base => $base,
		relative => $inside,
		parent => $base . (scalar @upper ? '/' . join('/', @upper) : ''),
		path => $base . (length $inside ? '/' . $inside : '')
	};
}

# Bring something the archive holds back to this machine, into the place it came
# from: a whole folder - a series, an album - or one file. A folder is read out
# of the archive's manifest, so nothing walks the far disk over the tunnel, and
# each file is streamed down rather than pulled into memory, since a fetched
# video is a video. Anything already here, at the same size, is left alone.
sub archive_fetch_home_job {
	my ($job, $data) = @_;
	my $agent = &remote_agent_for($data->{'remote_uuid'});
	if ($agent->{'error'}) { $job->fail($agent->{'error'}); return }
	my $ua = $agent->{'ua'};
	my $manager = $agent->{'manager'};
	my $dest = &archive_local_destination({ location => $data->{'location'}, relative => $data->{'relative'} });
	if ($dest->{'error'}) { $job->fail($dest->{'error'}); return }

	my @files;
	if ($data->{'folder'}) {
		my $manifest = &archive_manifest_fetch({ remote_uuid => $data->{'remote_uuid'}, location => $data->{'location'} });
		if ($manifest->{'error'}) { $job->fail($manifest->{'error'}); return }
		my $folder = $manifest->{'folder'} || '';
		my $prefix = length $dest->{'relative'} ? $dest->{'relative'} . '/' : '';
		foreach my $row ( @{$manifest->{'rows'} || []} ) {
			my $relative = $row->{'relative'} || '';
			next unless length $relative;
			next if (length $prefix && index($relative, $prefix) != 0);
			push @files, { relative => $relative, size => $row->{'size'}, mtime => $row->{'mtime'}, path => (length $folder ? $folder . '/' . $relative : $relative) };
		}
	}
	else {
		push @files, { relative => $dest->{'relative'}, path => $data->{'archive_path'}, mtime => $data->{'mtime'} };
	}

	my ($fetched, $skipped, $bytes, $count) = (0, 0, 0, 0);
	my @errors;
	foreach my $file ( @files ) {
		$count++;
		my $into = &archive_local_destination({ location => $data->{'location'}, relative => $file->{'relative'} });
		if ($into->{'error'}) { push @errors, $file->{'relative'} . ': ' . $into->{'error'}; next }
		next unless (defined $file->{'path'} && length $file->{'path'});
		if (-e $into->{'path'}) {
			my $size = -s $into->{'path'};
			if (defined $file->{'size'} && defined $size && $size == $file->{'size'}) { $skipped++; next }
		}
		Mojo::File->new($into->{'parent'})->make_path;
		my $url = $manager . '/file_open?file=' . url_escape $file->{'path'};
		# streamed to the file, draining what has arrived each time so a long
		# video never lands in memory whole
		my $fh;
		my $write_error;
		my $last_tx;
		my $done;
		$ua->get($url => sub {
			my ($ua, $tx) = @_;
			$last_tx = $tx;
			my $res = $tx->res;
			my $chunk = $res->body;
			if (defined $chunk && length $chunk) {
				unless ($fh) {
					open my $open, '>', $into->{'path'} or do { $write_error = 'cannot write ' . $into->{'path'}; return };
					$fh = $open;
				}
				print {$fh} $chunk;
				$res->body('');
			}
			$done = 1 if ($res->is_finished || $res->error);
		});
		# the callback form is the non-blocking one, so the loop has to be
		# driven until the response is in hand
		Mojo::IOLoop->one_tick until $done;
		close $fh if $fh;
		if ($write_error) { push @errors, $file->{'relative'} . ': ' . $write_error; next }
		# a callback form of get returns the transaction's id, not the
		# transaction, so the outcome is taken from the last one it handed back
		unless ($last_tx && $last_tx->res->is_success && -e $into->{'path'}) {
			my $why = ($last_tx && $last_tx->res->error) ? $last_tx->res->error->{'message'} : 'the download failed';
			push @errors, $file->{'relative'} . ': ' . $why;
			next;
		}
		utime $file->{'mtime'}, $file->{'mtime'}, $into->{'path'} if ($file->{'mtime'} && $file->{'mtime'} =~ /^\d+$/);
		$fetched++;
		$bytes += (-s $into->{'path'}) || 0;
		$job->note(progress => "fetched $fetched, skipped $skipped, $bytes bytes") if $count % 5 == 0;
	}

	my $result = {
		fetched => $fetched,
		skipped => $skipped,
		bytes => $bytes,
		files => scalar @files,
		location => $data->{'location'},
		relative => $data->{'relative'},
		archive_host => $agent->{'hostname'}
	};
	if (scalar @errors) {
		$result->{'errors'} = \@errors;
		$job->fail($result);
		return;
	}
	$job->note(progress => "fetched $fetched, skipped $skipped, $bytes bytes");
	$job->finish($result);
}

# Ask the machine holding a path what it is: which location it belongs to and
# where it sits inside it. Only the machine that owns the drive can answer,
# because only it knows its own archive root.
sub archive_remote_locate {
	my $data = shift;
	my $agent = &remote_agent_for($data->{'remote_uuid'});
	return { error => $agent->{'error'} } if $agent->{'error'};
	my $res = eval {
		return $agent->{'ua'}->post($agent->{'manager'} . '/manager/folders/archive/locate' => form => {
			path => $data->{'path'}
		})->result->json;
	};
	return { error => 'the archive machine did not answer' } unless ($res && $res->{'status'} eq 'ok');
	return $res;
}

# The files a folders selection names: every file, with folders walked, so a
# job can take a selection straight from the menu and a folder added to since
# the menu was drawn is still covered.
sub folders_job_files {
	my $items = shift || [];
	my @files;
	foreach my $item ( @{$items} ) {
		my $path = $item->{'path'};
		next unless (defined $path && length $path && -e $path);
		if (-d $path) {
			push @files, &dir_listing([$path], 1);
		}
		else { push @files, $path; }
	}
	return sort @files;
}

# Take something off the disk for good, folders with everything in them.
# Returns nothing when it went, and a line saying why not when it did not.
sub folders_job_take_away {
	my $path = shift;
	return 'no path' unless (defined $path && length $path);
	return $path . ': it is not there' unless -e $path;
	return undef if (!-d $path && unlink $path);
	my $errors;
	File::Path::remove_tree($path, { error => \$errors });
	return $path . ': it could not be taken away' if (ref $errors && scalar @{$errors});
	return undef;
}

# Shred something: every file is overwritten where it lies and the folders they
# sat in go with them. Shredding is for files that should not be readable
# again, which is why the encryption turns to it too.
sub folders_job_shred {
	my $path = shift;
	return 'no path' unless (defined $path && length $path);
	return $path . ': it is not there' unless -e $path;
	if (!-d $path) {
		my $status = system('shred', '-u', $path);
		return $path . ': it could not be shredded' if $status != 0;
		return undef;
	}
	foreach my $file ( &folders_job_files([ { path => $path } ]) ) {
		my $status = system('shred', '-u', $file);
		return $file . ': it could not be shredded' if $status != 0;
	}
	return &folders_job_take_away($path);
}

# The appointment entries that name a path, or a file under it when the path is
# a folder, so the folders app can hand a file an appointment has attached to
# the app's own file deletion - which lets the appointment go of it, takes the
# thumb with it, and tells the other machines - rather than pulling it out from
# under the row. Each answer is an appointment and the entry in it to delete.
sub folders_appt_entries {
	my $path = shift;
	return [] unless (defined $path && length $path);
	my @names = (-d $path) ? &folders_job_files([ { path => $path } ]) : ( $path );
	my %wanted = map { $_ => 1 } @names;
	my $appts = eval { &db_query('select app, uuid, file from appointments where file is not null and file != ?', '')->hashes } || [];
	my @found;
	foreach my $appt ( @{$appts} ) {
		my $entries = eval { return decode_json $appt->{'file'} };
		next unless ref $entries;
		$entries = [ $entries ] if (ref $entries eq 'HASH');
		foreach my $entry ( @{$entries} ) {
			next unless ref $entry;
			next unless (defined $entry->{'uuid'} && length $entry->{'uuid'});
			my $named = (defined $entry->{'f'} && $wanted{ $entry->{'f'} })
				|| (defined $entry->{'thumb'} && $wanted{ $entry->{'thumb'} });
			next unless $named;
			push @found, { app => $appt->{'app'}, app_uuid => $appt->{'uuid'}, file_uuid => $entry->{'uuid'} };
		}
	}
	return \@found;
}

# Whether a decoded thing names a path, anywhere inside it: an entry's f or
# thumb, an attachment wrapped around an entry, or a bare path in a list.
sub folders_entry_names {
	my ($blob, $wanted) = @_;
	return 0 unless ref $blob;
	if (ref $blob eq 'ARRAY') {
		foreach my $item ( @{$blob} ) {
			return 1 if &folders_entry_names($item, $wanted);
		}
	}
	elsif (ref $blob eq 'HASH') {
		foreach my $kind ( qw/f thumb/ ) {
			return 1 if (defined $blob->{$kind} && $wanted->{ $blob->{$kind} });
		}
		foreach my $key ( keys %{$blob} ) {
			next unless ref $blob->{$key};
			return 1 if &folders_entry_names($blob->{$key}, $wanted);
		}
	}
	return 0;
}

# Take the entries naming a path out of one decoded blob: an entry goes whole,
# a bare path in a list goes alone, and an attachment wrapped around an entry
# goes with it. Returns how many were dropped.
sub folders_entry_trim_in {
	my ($blob, $wanted) = @_;
	my $dropped = 0;
	if (ref $blob eq 'ARRAY') {
		my @kept;
		foreach my $item ( @{$blob} ) {
			if (ref $item) {
				if (&folders_entry_names($item, $wanted)) { $dropped++; next }
				$dropped += &folders_entry_trim_in($item, $wanted);
			}
			elsif (defined $item && $wanted->{$item}) {
				$dropped++;
				next;
			}
			push @kept, $item;
		}
		@{$blob} = @kept;
	}
	elsif (ref $blob eq 'HASH') {
		foreach my $key ( keys %{$blob} ) {
			next unless ref $blob->{$key};
			$dropped += &folders_entry_trim_in($blob->{$key}, $wanted);
		}
	}
	return $dropped;
}

# Take a path out of the rows besides an appointment that write one down - a
# mailbox's attachments, the store's rows - so a file that is taken away is not
# still named by them. A folder covers the files under it, and a row that
# changed is stamped with the time so the other machines hear about it.
# Returns how many entries were taken out.
sub folders_entry_trim {
	my $path = shift;
	return 0 unless (defined $path && length $path);
	my @names = (-d $path) ? &folders_job_files([ { path => $path } ]) : ( $path );
	my %wanted = map { $_ => 1 } @names;
	my $trimmed = 0;
	foreach my $place ( &file_reference_places() ) {
		next unless ($place->{'shape'} eq 'entries');
		next if ($place->{'table'} eq 'appointments');
		my $table = $place->{'table'};
		my $column = $place->{'column'};
		my $rows = eval { &db_query("select rowid, $column from $table where $column is not null and $column != ''")->hashes } || [];
		foreach my $row ( @{$rows} ) {
			my $blob = eval { return decode_json $row->{$column} };
			next unless ref $blob;
			my $touched = 0;
			if (ref $blob eq 'HASH' && &folders_entry_names($blob, \%wanted)) {
				$touched = 1;
				$blob = [];
			}
			else {
				$touched = &folders_entry_trim_in($blob, \%wanted);
			}
			next unless $touched;
			&db_update($table, { $column => encode_json $blob, server_time => &rightNow() }, { rowid => $row->{'rowid'} });
			$trimmed += $touched;
		}
	}
	return $trimmed;
}

# Every place a path is written down, so that sealing a file or opening one
# keeps whatever points at it pointing at it: an appointment's file array, a
# mailbox's attachments (each one wrapped around a file entry), and the store's
# rows, which carry the same kind of entries as an appointment does. A backup
# remembers its sealed file as a bare path, so it is here too.
sub file_reference_places {
	return (
		{ table => 'appointments', column => 'file', shape => 'entries', standard => 1 },
		{ table => 'mailbox', column => 'attachments', shape => 'entries' },
		{ table => 'model', column => 'file', shape => 'entries' },
		{ table => 'model', column => 'files', shape => 'entries' },
		{ table => 'option', column => 'file', shape => 'entries' },
		{ table => 'option', column => 'files', shape => 'entries' },
		{ table => 'option_category', column => 'file', shape => 'entries' },
		{ table => 'subcategory', column => 'file', shape => 'entries' },
		{ table => 'backups', column => 'enc_file', shape => 'path' }
	);
}

# Walk a decoded blob and hang every path in it off the map, so a path can be
# found again by what it names: an entry's f or thumb, an attachment wrapped
# around an entry, or a bare path in a list. What was found is kept with the
# blob it sits in, so the spot can be written back to.
sub file_reference_index {
	my ($blob, $info, $paths) = @_;
	return unless ref $blob;
	if (ref $blob eq 'ARRAY') {
		for (my $spot = 0; $spot < scalar @{$blob}; $spot++) {
			my $item = $blob->[$spot];
			if (ref $item) { &file_reference_index($item, $info, $paths); next }
			next unless (defined $item && length $item);
			push @{ $paths->{$item} }, { info => $info, kind => 'list', blob => $blob, spot => $spot };
		}
	}
	elsif (ref $blob eq 'HASH') {
		foreach my $kind ( qw/f thumb/ ) {
			next unless (defined $blob->{$kind} && length $blob->{$kind});
			push @{ $paths->{ $blob->{$kind} } }, { info => $info, kind => $kind, blob => $blob };
		}
		foreach my $key ( keys %{$blob} ) {
			next unless ref $blob->{$key};
			&file_reference_index($blob->{$key}, $info, $paths);
		}
	}
}

# Every path the rows write down, read once, as a map from each path to where
# it was found, so a job sealing or opening a whole folder can look a selection
# up without dialing the database file by file. The looking is done on decoded
# values: the JSON written by this house escapes the slashes, so the stored
# text is no way to find a path in.
sub file_reference_read {
	my $read = { paths => {} };
	foreach my $place ( &file_reference_places() ) {
		my $table = $place->{'table'};
		my $column = $place->{'column'};
		my $select = "rowid, $column" . ($place->{'standard'} ? ', encryption_standard' : '');
		my $found = eval { &db_query("select $select from $table where $column is not null and $column != ''")->hashes } || [];
		foreach my $row ( @{$found} ) {
			my $info = {
				table => $table,
				column => $column,
				shape => $place->{'shape'},
				flagged => $place->{'standard'} ? 1 : 0,
				rowid => $row->{'rowid'},
				row_standard => $row->{'encryption_standard'}
			};
			if ($place->{'shape'} eq 'entries') {
				my $blob = eval { return decode_json $row->{$column} };
				next unless ref $blob;
				$info->{'blob'} = $blob;
				&file_reference_index($blob, $info, $read->{'paths'});
			}
			else {
				$info->{'value'} = $row->{$column};
				push @{ $read->{'paths'}->{ $row->{$column} } }, { info => $info, kind => 'path' };
			}
		}
	}
	return $read;
}

# What the rows remember about a path, from a set already read: the name the
# file went in under, and the encryption standard the row carries, the two
# things opening a seal again needs to hand the file back the way it was.
# Undefined when nothing points at the path.
sub file_reference_remembered {
	my ($read, $path) = @_;
	return undef unless (defined $path && length $path && ref $read);
	my $spots = $read->{'paths'}->{$path};
	return undef unless $spots;
	foreach my $spot ( @{$spots} ) {
		next unless ($spot->{'kind'} eq 'f');
		return { of => $spot->{'blob'}->{'of'}, standard => $spot->{'info'}->{'row_standard'} };
	}
	return undef;
}

# Put the new paths where the old ones were written down, in a set already
# read, and write back only the rows that changed. Each pair is named by the
# path it was, and carries where it went and the name it went in under; a
# moved folder hands its prefixes over instead, and every path under them gets
# its pair worked out from them. A row that changed is stamped with the time
# so the other machines hear about it, and an appointment that had a file
# sealed or opened says which encryption standard it is under now, the way
# file_encrypter and file_decrypter say it.
sub file_reference_apply {
	my ($read, $pairs, $folders) = @_;
	return 0 unless (ref $read && ref $pairs);
	# a folder that moved takes everything under it along
	foreach my $from ( keys %{$folders || {}} ) {
		my $to = $folders->{$from};
		next unless (defined $to && length $to);
		my $stem = $from;
		$stem =~ s{/+$}{};
		my $to_stem = $to;
		$to_stem =~ s{/+$}{};
		my $under = $stem . '/';
		$pairs->{$stem} = { to => $to_stem } if ($read->{'paths'}->{$stem});
		foreach my $path ( keys %{ $read->{'paths'} } ) {
			next unless (substr($path, 0, length $under) eq $under);
			$pairs->{$path} = { to => $to_stem . substr($path, length $stem) };
		}
	}
	return 0 unless (scalar keys %{$pairs});
	my $standard;
	my $clear = 0;
	foreach my $pair ( values %{$pairs} ) {
		$standard = $pair->{'standard'} if (defined $pair->{'standard'} && length $pair->{'standard'});
		$clear = 1 if $pair->{'clear_standard'};
	}
	my %dirty;
	foreach my $from ( keys %{$pairs} ) {
		my $pair = $pairs->{$from};
		my $spots = $read->{'paths'}->{$from};
		next unless $spots;
		foreach my $spot ( @{$spots} ) {
			my $info = $spot->{'info'};
			if ($spot->{'kind'} eq 'path') {
				next unless (defined $info->{'value'} && $info->{'value'} eq $from);
				$info->{'value'} = $pair->{'to'};
			}
			elsif ($spot->{'kind'} eq 'list') {
				next unless ($spot->{'blob'}->[ $spot->{'spot'} ] eq $from);
				$spot->{'blob'}->[ $spot->{'spot'} ] = $pair->{'to'};
			}
			else {
				next unless (defined $spot->{'blob'}->{ $spot->{'kind'} } && $spot->{'blob'}->{ $spot->{'kind'} } eq $from);
				$spot->{'blob'}->{ $spot->{'kind'} } = $pair->{'to'};
				$spot->{'blob'}->{'server_time'} = &rightNow();
				$spot->{'blob'}->{'of'} = $pair->{'of'} if ($pair->{'of'} && $spot->{'kind'} eq 'f' && !$spot->{'blob'}->{'of'});
			}
			$dirty{$info} = $info;
		}
	}
	foreach my $info ( values %dirty ) {
		my $set = { server_time => &rightNow() };
		$set->{ $info->{'column'} } = ($info->{'shape'} eq 'entries') ? encode_json $info->{'blob'} : $info->{'value'};
		if ($info->{'flagged'}) {
			$set->{'encryption_standard'} = $standard if defined $standard;
			$set->{'encryption_standard'} = undef if $clear;
		}
		&db_update($info->{'table'}, $set, { rowid => $info->{'rowid'} });
	}
	return scalar keys %dirty;
}

# The worker half of paste: put what was cut or copied into the folder being
# looked at. A move on one disk is a rename; anything else is copied file by
# file and the source taken away once it has landed, so a selection can cross
# disks, and a folder goes with everything in it. A move also hands the rows
# that pointed at a file its new path, once the old one has gone; a copy
# leaves what points at the original pointing at it. Errors are collected
# rather than thrown on the first bad file, and the job stops itself when the
# dialog asks it to.
sub folders_copy_job {
	my ($job, $data) = @_;
	my $to = $data->{'to'};
	unless (defined $to && length $to && -d $to) { $job->fail('the folder to paste into is not there'); return }
	my $move = $data->{'move'} ? 1 : 0;
	my @items = @{$data->{'items'} || []};
	my $total = 0;
	foreach my $item ( @items ) {
		$total += scalar &folders_job_files([ $item ]);
	}
	my @errors;
	my ($copied, $moved, $bytes, $count) = (0, 0, 0, 0);
	# a move is what sends the rows to new paths - a copy leaves what points at
	# the original pointing at it
	my $references = $move ? &file_reference_read() : undef;
	my %moved_files;
	my %moved_folders;
	my $since_apply = 0;
	foreach my $item ( @items ) {
		my $path = $item->{'path'};
		unless (defined $path && length $path && -e $path) {
			push @errors, ($path || '?') . ': it is not there';
			next;
		}
		my @parts = split '/', $path;
		my $name = pop @parts;
		my $dest = $to . '/' . $name;
		if (-e $dest) {
			push @errors, $name . ': something with that name is already there';
			next;
		}
		my $source_is_folder = -d $path;
		# the whole of a move on one disk, and the cheap way round the rest
		if ($move && rename($path, $dest)) {
			$moved++;
			$since_apply++;
			if ($source_is_folder) { $moved_folders{$path} = $dest; }
			else { $moved_files{$path} = { to => $dest }; }
			next;
		}
		my @mine = $source_is_folder ? &folders_job_files([ $item ]) : ( $path );
		my $landed = 1;
		foreach my $file ( @mine ) {
			$count++;
			if ($count % 10 == 0) {
				$job->note(progress => ($move ? 'moved' : 'copied') . " $copied of $total files, $bytes bytes");
				if (($job->info->{'notes'} || {})->{'cancel'}) {
					&file_reference_apply($references, \%moved_files, \%moved_folders);
					$job->note(progress => "stopped after $copied files");
					$job->finish({ copied => $copied, moved => $moved, bytes => $bytes, files => $total, cancelled => 1 });
					return;
				}
			}
			my $relative = $name;
			if ($source_is_folder) {
				my $tail = substr($file, length($path));
				$tail =~ s{^/+}{};
				$relative = $name . '/' . $tail;
			}
			my $target = $to . '/' . $relative;
			my @upper = split '/', $target;
			pop @upper;
			my $parent = join '/', @upper;
			File::Path::make_path($parent) unless -d $parent;
			unless (-d $parent && File::Copy::copy($file, $target)) {
				push @errors, $relative . ': it could not be copied';
				$landed = 0;
				next;
			}
			my @stat = stat($file);
			utime $stat[9], $stat[9], $target if $stat[9];
			$bytes += (-s $target) || 0;
			$copied++;
		}
		if ($move && $landed) {
			my $error = &folders_job_take_away($path);
			push @errors, $error if $error;
			unless ($error) {
				# the old paths have gone, so the rows go to the new ones
				$moved++;
				$since_apply++;
				if ($source_is_folder) { $moved_folders{$path} = $dest; }
				else { $moved_files{$path} = { to => $dest }; }
			}
		}
		# the moved paths are handed over in stretches, so a long paste is not
		# left pointing at places its files have left
		if ($since_apply >= 100) {
			&file_reference_apply($references, \%moved_files, \%moved_folders);
			$since_apply = 0;
		}
	}
	# whatever moved is pointed at where it moved to
	&file_reference_apply($references, \%moved_files, \%moved_folders);
	my $result = { copied => $copied, moved => $moved, bytes => $bytes, files => $total };
	if (scalar @errors) {
		$result->{'errors'} = \@errors;
		$job->fail($result);
		return;
	}
	$job->note(progress => ($move ? "moved $moved" : "copied $copied of $total") . ", $bytes bytes");
	$job->finish($result);
}

# The worker half of encrypting: every file the selection names is sealed the
# way an app's files are sealed - openssl with the encryption standard and the
# suds as the password, a name of its own, and the plaintext shredded behind
# it - so the folder gives nothing away by its names. Whatever row pointed at
# the plaintext is pointed at the seal instead, and remembers the name the file
# went in under, so decrypting can hand it back the way it was. Files already
# sealed are left alone.
sub folders_encrypt_job {
	my ($job, $data) = @_;
	my $suds = $data->{'suds'};
	unless (defined $suds && length $suds) { $job->fail('there is no suds to seal with'); return }
	my $standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || "aes-256-ctr";
	my @files = grep { $_ !~ /\.enc$/i } &folders_job_files($data->{'items'});
	my @errors;
	my ($sealed, $bytes, $count) = (0, 0, 0);
	# everything that points at a path, read once, so a whole folder does not
	# dial the database file by file
	my $references = &file_reference_read();
	my %moved;
	foreach my $file ( @files ) {
		$count++;
		$job->note(progress => "sealed $sealed of " . scalar(@files) . " files, $bytes bytes") if $count % 5 == 0;
		if (($job->info->{'notes'} || {})->{'cancel'}) {
			&file_reference_apply($references, \%moved);
			$job->note(progress => "stopped after $sealed files");
			$job->finish({ sealed => $sealed, bytes => $bytes, files => scalar(@files), cancelled => 1 });
			return;
		}
		my @parts = split '/', $file;
		my $name = pop @parts;
		my $base = join '/', @parts;
		my @ext = split /\./, $name;
		my $ext = pop @ext;
		my $sealed_path = (length $base ? $base . '/' : '') . &random_string_creator(20) . '.' . $ext . '.enc';
		my $status = system('openssl', 'enc', '-e', '-k', $suds, "-$standard", '-pbkdf2', '-in', $file, '-out', $sealed_path);
		unless ($status == 0 && -e $sealed_path && (-s $sealed_path) > 0) {
			unlink $sealed_path;
			push @errors, $name . ': it could not be sealed';
			next;
		}
		system('shred', '-u', $file);
		$moved{$file} = { to => $sealed_path, of => $name, standard => $standard };
		$sealed++;
		$bytes += (-s $sealed_path) || 0;
		# hand the rows their new paths in stretches, so a job taken down in the
		# middle leaves at most a stretch unpointed
		&file_reference_apply($references, \%moved) if ($sealed % 100 == 0);
	}
	# whatever points at the plaintext points at the seal instead, and remembers
	# the name it went in under
	&file_reference_apply($references, \%moved);
	my $result = { sealed => $sealed, bytes => $bytes, files => scalar @files };
	if (scalar @errors) {
		$result->{'errors'} = \@errors;
		$job->fail($result);
		return;
	}
	$job->note(progress => "sealed $sealed of " . scalar(@files) . " files, $bytes bytes");
	$job->finish($result);
}

# Whether the start of a file reads as text. Plain text has no type File::Type
# knows, so it is the one thing a content check misses, and a password that
# does not fit never comes out as words: a stream of random bytes is printable
# about two fifths of the time, so a head that is printable throughout is not
# something a wrong password produces.
sub folders_reads_as_text {
	my $head = shift;
	return 0 unless (defined $head && length $head);
	return 0 if $head =~ /\0/;
	my $printable = ($head =~ tr/\t\n\r\x20-\x7e//);
	return (($printable / length($head)) > .95) ? 1 : 0;
}

# The worker half of decrypting: every sealed file the selection names is
# opened with the first password that works - the suds the request handed
# over, since that is what the folders app seals with, then the padlock
# secrets the way file_decrypter tries them - under the standard the row it
# belongs to carries, falling back to the setting. It lands under the name the
# rows that point at it remember it by, and whatever pointed at the seal is
# pointed at the plaintext. The seal is only shredded once its plaintext is
# safely out, so a file no password opens is left exactly as it was.
sub folders_decrypt_job {
	my ($job, $data) = @_;
	my $suds = $data->{'suds'};
	my $standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || "aes-256-ctr";
	my @passwords = ( $suds );
	my $secrets = &db_query('select * from security where level != ? and level != ? order by server_time DESC','padlock','door');
	foreach my $p ( @{$secrets->hashes} ) {
		my $secret = &decrypter($suds, $p->{'credential'});
		push @passwords, $secret if (defined $secret && length $secret);
	}
	my @files = grep { /\.enc$/i } &folders_job_files($data->{'items'});
	my @errors;
	my ($opened, $bytes, $count) = (0, 0, 0);
	# everything that points at a path, read once, so a whole folder does not
	# dial the database file by file
	my $references = &file_reference_read();
	my %moved;
	foreach my $file ( @files ) {
		$count++;
		$job->note(progress => "opened $opened of " . scalar(@files) . " files, $bytes bytes") if $count % 5 == 0;
		if (($job->info->{'notes'} || {})->{'cancel'}) {
			&file_reference_apply($references, \%moved);
			$job->note(progress => "stopped after $opened files");
			$job->finish({ opened => $opened, bytes => $bytes, files => scalar(@files), cancelled => 1 });
			return;
		}
		my @parts = split '/', $file;
		my $name = pop @parts;
		# what the rows that point at the seal remember: the name the file went
		# in under, so it can come back as itself, and the standard it was
		# sealed with, which beats the setting when the two disagree
		my $remembered = &file_reference_remembered($references, $file) || {};
		my $path = $file;
		$path =~ s/\.enc$//i;
		if (defined $remembered->{'of'} && $remembered->{'of'} =~ /\S/) {
			my $original = $remembered->{'of'};
			$original =~ s{.*/}{};
			my @folder = split '/', $file;
			pop @folder;
			my $folder = join '/', @folder;
			$path = (length $folder ? $folder . '/' : '') . $original;
		}
		if (-e $path) {
			push @errors, $name . ': something with that name is already there';
			next;
		}
		my @standards = ( $remembered->{'standard'}, $standard );
		my %seen_standard;
		@standards = grep { defined $_ && length $_ && !$seen_standard{$_}++ } @standards;
		my $temp = $file . '.opening';
		my $opened_it = 0;
		foreach my $which ( @standards ) {
			foreach my $secret ( @passwords ) {
				next unless (defined $secret && length $secret);
				unlink $temp if -e $temp;
				my $status = system('openssl', 'enc', '-d', '-k', $secret, "-$which", '-pbkdf2', '-in', $file, '-out', $temp);
				next unless ($status == 0 && -e $temp);
				# nothing in the stream says which password is the one, so the
				# opening is read as a file the way file_decrypter reads one: a
				# password that gives back a type - or words - is the password
				my $head = '';
				if (open my $fh, '<', $temp) { binmode $fh; read $fh, $head, 1024; close $fh; }
				my $type = File::Type->new()->mime_type($head);
				if ($type ne 'application/octet-stream' || $head =~ /webm/ || &folders_reads_as_text($head)) { $opened_it = 1; last }
				# a file that was empty seals to a block or two, and opens to nothing
				if ((-s $temp) == 0 && (-s $file) <= 48) { $opened_it = 1; last }
			}
			last if $opened_it;
		}
		unless ($opened_it) {
			unlink $temp if -e $temp;
			push @errors, $name . ': no password opened it';
			next;
		}
		rename $temp, $path;
		system('shred', '-u', $file);
		$moved{$file} = { to => $path, clear_standard => 1 };
		$opened++;
		$bytes += (-s $path) || 0;
		# hand the rows their new paths in stretches, so a job taken down in the
		# middle leaves at most a stretch unpointed
		&file_reference_apply($references, \%moved) if ($opened % 100 == 0);
	}
	# whatever points at the seal points at what came out of it
	&file_reference_apply($references, \%moved);
	my $result = { opened => $opened, bytes => $bytes, files => scalar @files };
	if (scalar @errors) {
		$result->{'errors'} = \@errors;
		$job->fail($result);
		return;
	}
	$job->note(progress => "opened $opened of " . scalar(@files) . " files, $bytes bytes");
	$job->finish($result);
}

# The sealed files under the given roots: dir_listing's find(1), with the name
# filter left to the child, so a home with a hundred thousand files costs one
# process to ask.
sub sealed_files_under {
	my ($roots) = @_;
	my @roots = grep { defined $_ && length $_ && -d $_ } @{ $roots || [] };
	return () unless @roots;
	my @out;
	my $listed = 0;
	my $find = &find_program();
	if ($find) {
		if (open(my $fh, '-|', $find, @roots, '-type', 'f', '-iname', '*.enc', '-print0')) {
			$listed = 1;
			local $/ = "\0";
			while (defined(my $path = <$fh>)) {
				chop $path;
				push @out, $path if length $path;
			}
			close $fh;
		}
	}
	unless ($listed) {
		find({ no_chdir => 1, wanted => sub { push @out, $File::Find::name if -f $_ && /\.enc$/i } }, @roots);
	}
	return sort @out;
}

# system() with the child's stderr sent to /dev/null: openssl enc -d chatters
# "bad decrypt" on every wrong password, and a reseal pass tries many.
sub system_quiet {
	my @command = @_;
	open my $saved, '>&', \*STDERR or return system(@command);
	open STDERR, '>', '/dev/null' or do { close $saved; return system(@command) };
	my $status = system(@command);
	open STDERR, '>&', $saved;
	close $saved;
	return $status;
}

# A database backup is not a folder seal: backup_now appends its standard
# after the ciphertext, marked with the universal splitter (the restore path
# splits on it), so the tail tells the two apart without opening anything. The
# marker is 31 characters, which random ciphertext does not spell by accident.
sub reads_as_backup {
	my ($file) = @_;
	my $size = -s $file or return 0;
	my $take = $size > 512 ? 512 : $size;
	open my $fh, '<', $file or return 0;
	binmode $fh;
	seek $fh, $size - $take, 0;
	my $tail = '';
	read $fh, $tail, $take;
	close $fh;
	my $splitter = $gb::universal_splitter;
	return (defined $tail && defined $splitter && length $splitter && index($tail, $splitter) >= 0) ? 1 : 0;
}

# The rotation's tail on disk: walk the sealed files and put every one that
# opens under an old key back under the current one. The passwords are the ones
# a rotation leaves reachable - the current suds first, so an already re-sealed
# file is recognised and left alone, then every secret the security rows derive
# (the wrapped old keys among them, which is what finds the old seals). Nothing
# is ever lost to a guess: the original seal is replaced only once the new one
# is written and opens back to the identical bytes, a file no password opens is
# counted and left exactly as it was, database backups (recognised by the
# standard they append after the ciphertext) are left whole, and a file written
# since the rotation
# (mtime past `before`) is skipped without opening, since it is already under
# the new key. Batched by a time budget; when the budget runs out the job
# queues its own follow-up carrying a cursor - the walk is sorted, so the next
# run starts where this one stopped instead of re-walking the whole home.
# Where the sealed files live: the home plus every media location the misc
# settings name (music, download, photo, document, video, scan, rec). On a phone
# those point at /sdcard/... rather than the Termux home, so walking only ~ would
# leave a rotation's tail of /sdcard seals untouched.
sub folders_reseal_roots {
	my @roots = ( &home('~/') );
	foreach my $l ( &location_types() ) {
		my $loc = &setting_grabber({ app => 'misc', setting => $l . '_location' });
		push @roots, &home($loc) if (defined $loc && length $loc);
	}
	my %seen;
	return [ grep { !$seen{$_}++ } @roots ];
}

sub folders_reseal_job {
	my ($job, $data) = @_;
	my $suds = eval { &suds_grabber() };
	unless ($suds) { $job->fail('there is no key on this machine'); return }
	my $standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
	my @passwords = ( $suds );
	my $secrets = &db_query('select * from security where level != ? and level != ? order by server_time DESC', 'padlock', 'door');
	foreach my $p ( @{$secrets->hashes} ) {
		my $secret = &decrypter($suds, $p->{'credential'});
		push @passwords, $secret if (defined $secret && length $secret);
	}
	my %seen;
	@passwords = grep { !$seen{$_}++ } @passwords;
	my $before = $data->{'before'} || 0;
	my $budget = $data->{'budget'} || 600;
	my $after = defined $data->{'after'} ? $data->{'after'} : '';
	my $roots = (ref $data->{'roots'} && scalar @{$data->{'roots'}}) ? $data->{'roots'} : &folders_reseal_roots();
	my $references = &file_reference_read();
	my $started = time();
	my @files = &sealed_files_under($roots);
	my ($resealed, $current, $unopened, $skipped, $backups, $passed, $count) = (0, 0, 0, 0, 0, 0, 0);
	my (@errors, $out_of_time, $cancelled);
	my $last = $after;
	foreach my $file ( @files ) {
		$count++;
		$job->note(progress => "re-sealed $resealed, current $current of " . scalar(@files) . " sealed files") if $count % 10 == 0;
		# a run that ran out of time left its cursor: everything at or before it
		# is already walked (the list is sorted, so this stays stable)
		if (length $after && $file le $after) { $passed++; next; }
		if (($job->info->{'notes'} || {})->{'cancel'}) { $cancelled = 1; last; }
		if (time() - $started > $budget) { $out_of_time = 1; last; }
		$last = $file;
		$job->note(cursor => $last) if $count % 25 == 0;
		# written since the rotation: already under the new key (stat is in
		# seconds, the stamps in milliseconds)
		if ($before && ((stat($file))[9] || 0) * 1000 > $before) { $skipped++; next; }
		# a database backup carries its standard appended after the ciphertext
		# (backup_now), so it is not a folder seal at all: leave it whole
		if (&reads_as_backup($file)) { $backups++; next; }
		my $remembered = &file_reference_remembered($references, $file) || {};
		my @standards = ( $remembered->{'standard'}, $standard );
		my %seen_standard;
		@standards = grep { defined $_ && length $_ && !$seen_standard{$_}++ } @standards;
		my $clear = $file . '.opening';
		my ($opened_with, $opened_standard);
		foreach my $which ( @standards ) {
			foreach my $password ( @passwords ) {
				next unless (defined $password && length $password);
				unlink $clear if -e $clear;
				my $status = &system_quiet('openssl', 'enc', '-d', '-k', $password, "-$which", '-pbkdf2', '-in', $file, '-out', $clear);
				next unless ($status == 0 && -e $clear);
				# nothing in the stream says which password is the one, so the
				# opening is read as a file the way the decrypt job reads one
				my $head = '';
				if (open my $fh, '<', $clear) { binmode $fh; read $fh, $head, 1024; close $fh; }
				my $type = File::Type->new()->checktype_contents($head);
				if ($type ne 'application/octet-stream' || $head =~ /webm/ || &folders_reads_as_text($head) || ((-s $clear) == 0 && (-s $file) <= 48)) {
					$opened_with = $password;
					$opened_standard = $which;
					last;
				}
			}
			last if defined $opened_with;
		}
		unless (defined $opened_with) {
			system('shred', '-u', $clear) if -e $clear;
			$unopened++;
			next;
		}
		if ($opened_with eq $suds) {
			system('shred', '-u', $clear) if -e $clear;
			$current++;
			next;
		}
		# an old seal: put it back under the current key. The original file is
		# only replaced once the new seal exists and opens to the same bytes.
		my $seal = $file . '.resealing';
		my $verify = $file . '.verifying';
		unlink $seal if -e $seal;
		my $status = system('openssl', 'enc', '-e', '-k', $suds, "-$opened_standard", '-pbkdf2', '-in', $clear, '-out', $seal);
		if ($status != 0 || !-e $seal || (-s $seal) == 0) {
			push @errors, $file . ': it could not be sealed again';
			system('shred', '-u', $clear) if -e $clear;
			unlink $seal if -e $seal;
			next;
		}
		unlink $verify if -e $verify;
		$status = system('openssl', 'enc', '-d', '-k', $suds, "-$opened_standard", '-pbkdf2', '-in', $seal, '-out', $verify);
		my $same = ($status == 0 && -e $verify) ? (system('cmp', '-s', $clear, $verify) == 0 ? 1 : 0) : 0;
		if (!$same) {
			push @errors, $file . ': the new seal did not open back to the same bytes';
			system('shred', '-u', $clear) if -e $clear;
			system('shred', '-u', $verify) if -e $verify;
			unlink $seal if -e $seal;
			next;
		}
		unless (rename $seal, $file) {
			push @errors, $file . ': the new seal could not take its place';
			system('shred', '-u', $clear) if -e $clear;
			system('shred', '-u', $verify) if -e $verify;
			unlink $seal if -e $seal;
			next;
		}
		system('shred', '-u', $clear) if -e $clear;
		system('shred', '-u', $verify) if -e $verify;
		$resealed++;
	}
	my $result = { resealed => $resealed, current => $current, unopened => $unopened, skipped => $skipped, backups => $backups, passed => $passed, cursor => $last, files => scalar @files };
	if (scalar @errors) { $result->{'errors'} = \@errors; $job->fail($result); return; }
	$result->{'cancelled'} = 1 if $cancelled;
	$job->note(progress => "re-sealed $resealed, current $current, unopened $unopened of " . scalar(@files));
	$job->finish($result);
	# out of time, not out of files: hand the next stretch to a fresh job (a
	# driver that carries the cursor itself passes nofollow)
	if ($out_of_time && length $last && !$data->{'nofollow'}) {
		my $run = ($data->{'run'} || 1) + 1;
		eval { &minion_grabber()->enqueue('folders_reseal' => [ { before => $before, budget => $budget, run => $run, roots => $data->{'roots'}, after => $last } ] => { attempts => 2 }) } if $run <= 20;
	}
	return;
}

# --- key propagation -----------------------------------------------------------
# A rotation has to reach the rest of the house, or the machines drift apart:
# each one ends up holding a different key, and only the machine that rotated
# can read what it sealed. So a rotation queues a push: the new key is handed
# to every linked machine over the signed peer rail, wrapped under the key it
# replaced. Only a machine still on that key can open it, and a machine on a
# different lineage fails the unwrap and keeps its own - divergence is not
# healed by adopting a stranger's key. A machine that is away needs no push: the
# canary syncs with the database, its next key resolution finds a vault that no
# longer validates and pulls the new key the way a keyless machine does.
sub key_push_envelope {
	my $Knew = &suds_grabber();
	return unless $Knew;
	my $rows = &db_query('select credential from security where level = ? order by server_time desc', 'oldkey')->hashes;
	foreach my $row ( @{$rows} ) {
		my $Kold = &crypt_simple_unwrap($Knew, $row->{'credential'});
		next unless defined $Kold && length $Kold;
		my $proved = &encrypter($Kold, $Knew);
		next unless defined $proved && length $proved;
		return { proved => $proved, from => &suds_id($Kold) };
	}
	return;
}

sub key_push_one {
	my ($rm, $proved) = @_;
	return unless $rm && $rm->{'signatorial'} && defined $proved && length $proved;
	my $manager = $rm->{'manager'};
	$manager = 'https://' . $rm->{'ip'} . ':' . ($rm->{'port'} || '45545') unless $manager;
	return unless $manager;
	my $ua = Mojo::UserAgent->new();
	$ua->max_response_size(0);
	$ua->insecure(1);
	$ua->on(start => sub { my ($ua, $tx) = @_; &peer_sign_request($tx->req); });
	my $url = $manager . '/manager/key_push';
	my $res = eval { $ua->inactivity_timeout(20)->post($url => form => { signatorial => &signatorial_designer(), proved => $proved })->result };
	return unless $res && $res->is_success;
	my $json = eval { decode_json $res->body };
	return unless $json;
	return { ok => $json->{'ok'} ? 1 : 0, already => $json->{'already'} ? 1 : 0, error => $json->{'error'} };
}

# The queue's half: push the envelope to every machine with a pinned key. The
# result names what happened; machines that do not answer ride the pull path
# instead, the next time their database syncs the new canary in.
sub key_push_job {
	my ($job, $data) = @_;
	my $env = &key_push_envelope();
	unless ($env) { $job->fail('nothing to push: no wrapped old key on this machine'); return }
	my $me = &signatorial_designer();
	# the route pushes to everyone; a driver may name the peers it wants (so a
	# probe never hands a probe key to the real machines)
	my %only = map { $_ => 1 } @{ (ref $data->{'only'} eq 'ARRAY') ? $data->{'only'} : [] };
	my $rms = &db_select('remote_machines')->hashes || [];
	my $summary = { asked => 0, ok => 0, refused => 0, unreachable => 0 };
	foreach my $rm ( @{$rms} ) {
		my $rsig = $rm->{'signatorial'};
		next unless $rsig && $rsig ne $me;
		next if (scalar keys %only) && !$only{$rsig};
		next unless $rm->{'pubkey'};
		next unless $rm->{'manager'} || $rm->{'ip'};
		$summary->{asked}++;
		my $got = eval { &key_push_one($rm, $env->{'proved'}) };
		if ($got && ($got->{'ok'} || $got->{'already'})) { $summary->{ok}++; }
		elsif ($got) { $summary->{refused}++; }
		else { $summary->{unreachable}++; }
	}
	$job->note(progress => 'key pushed: ' . $summary->{ok} . ' took it, ' . $summary->{refused} . ' on another key, ' . $summary->{unreachable} . ' not answering');
	$job->finish($summary);
}

# Every job the queue can run, in one place. The worker and the code that
# enqueues register the same list, so a name can never drift between them.
sub minion_task_list {
	return {
		archive_transfer => \&archive_transfer_job,
		archive_manifest_rescan => \&archive_manifest_rescan_job,
		archive_fetch_home => \&archive_fetch_home_job,
		folders_copy => \&folders_copy_job,
		folders_encrypt => \&folders_encrypt_job,
		folders_decrypt => \&folders_decrypt_job,
		folders_reseal => \&folders_reseal_job,
		key_push => \&key_push_job,
		appointment_evaluation => \&appointment_evaluation_job
	};
}

# Resolve ~ once; this used to shell out to `echo $HOME` on every call. That
# helper is hit constantly (every settings/cache/db path), so caching it avoids
# a fork+exec per call.
my $home_dir;
sub home() {
	my ($inhabitant) = @_;
	unless (defined $home_dir) {
		$home_dir = $ENV{HOME};
		if (!defined $home_dir || $home_dir eq '') {
			$home_dir = (getpwuid($<))[7] || '';
		}
	}
	$inhabitant =~ s/~/$home_dir/;
	return $inhabitant;
}

# The newest mtime the app cares about, for the homepage "Last Update" label.
# This used to reuse ide_files(), which walks and stats the whole tree - about
# 9,400 files, most of them .pio/build artifacts and the public/icons set. It now
# walks only the project's own files, pruning the generated and bulk-media
# directories before descending: a few hundred stats instead of thousands.
sub newest_folder_checker() {
	my $newest = 0;
	my %skip = map { $_ => 1 } qw(.git .pio build node_modules .shots icons);
	find({
		preprocess => sub { return grep { !$skip{$_} } @_ },
		wanted     => sub {
			return unless -f $_;
			my $m = (stat($_))[9] || 0;
			$newest = $m if $m > $newest;
		},
	}, './');
	return $newest * 1000;
}

# Paths under the given directories, for the walkers that need the whole tree
# (the ide's file list, the folders app's copy/delete, the archive, the music
# search). find(1) walks in C and streams NUL-separated names, so a large tree -
# a project, a home folder - costs one process instead of a Perl callback and an
# lstat per entry: measured about 5x faster for the music media search and 2x for
# a full listing that then stats each name. The directories go in as argv, not
# shell words, so nothing needs quoting, and NUL separation keeps awkward names
# whole. Falls back to File::Find where find(1) is not on PATH.
sub dir_listing {
	my ($dirs, $files_only) = @_;
	my @dirs = grep { defined $_ && length $_ } @{ $dirs || [] };
	return () unless @dirs;
	my @out;
	my $listed = 0;
	my $find = &find_program();
	if ($find) {
		# find(1)'s -type f skips symlinks, so ask for links too and let the -f
		# test below follow them, the way File::Find's wanted did
		my @sel = $files_only ? ('(', '-type', 'f', '-o', '-type', 'l', ')') : ();
		if (open(my $fh, '-|', $find, @dirs, @sel, '-print0')) {
			$listed = 1;
			local $/ = "\0";
			while (defined(my $path = <$fh>)) {
				chop $path;
				push @out, $path if length $path;
			}
			close $fh;
		}
	}
	unless ($listed) {
		find({ no_chdir => 1, wanted => sub { push @out, $File::Find::name } }, @dirs);
	}
	return $files_only ? (grep { -f $_ } @out) : @out;
}

my $find_program;
sub find_program {
	return $find_program if defined $find_program;
	for my $dir (split /:/, ($ENV{'PATH'} // '/usr/bin:/bin')) {
		my $candidate = "$dir/find";
		if (-x $candidate) { $find_program = $candidate; last }
	}
	$find_program = '' unless defined $find_program;
	return $find_program || undef;
}

# One level of the ide's tree. The editor opens with only the selected root's
# own children and asks for a folder's children when it unfolds, so a project is
# not walked and stat'd end to end (~9,400 files) before the window appears.
# Paths come back exactly as given, relative to the selected root, which is what
# the rows' file= and location= attributes key on.
sub ide_folder_listing {
	my ($folder) = @_;
	$folder = './' unless defined $folder && length $folder;
	my $dir = $folder;
	$dir =~ s{/+$}{};
	$dir = '.' if $dir eq '' || $dir eq '.';
	my $prefix = ($dir eq '.') ? '' : $dir . '/';
	opendir(my $dh, $dir) or return [];
	my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
	closedir $dh;
	my $tree = [];
	foreach my $name ( sort { lc $a cmp lc $b } @entries ) {
		my $path = $prefix . $name;
		my $temp = { file => $path, type => 'file' };
		my @stat = stat($path);
		my @temp_split = split '/', $path;
		$temp->{'short_name'} = $temp_split[-1];
		pop @temp_split;
		$temp->{'root_count'} = @temp_split;
		$temp->{'location'} = join '/', @temp_split;
		$temp->{'size'} = $stat[7];
		$temp->{'modified'} = $stat[9];
		$temp->{'created'} = $stat[10];
		$temp->{'accessed'} = $stat[8];
		$temp->{'type'} = 'folder' if -d $path;
		push @{$tree}, $temp;
	}
	return $tree;
}

my $ide_files = [];
sub ide_files() {
	my $folder = shift;
	$ide_files = [];
	foreach my $name ( &dir_listing([$folder]) ) { $name =~ s/^\.\///g; push @{$ide_files}, $name }
	my $tree = [];
	foreach my $f (@{$ide_files}) {
		my $temp = { file => $f, type => 'file' };
		my @stat = stat($f);
		my @folder_split = split '/', $f;
		my @temp_split = @folder_split;
		$temp->{'short_name'} = $temp_split[-1];
		pop @temp_split;
		$temp->{'root_count'} = @temp_split;
		$temp->{'location'} = join '/', @temp_split;
		$temp->{'size'} = $stat[7];
		$temp->{'modified'} = $stat[9];
		$temp->{'created'} = $stat[10];
		$temp->{'accessed'} = $stat[8];
		if ( -d $f) {
			$temp->{'type'} = 'folder';
		}
		push @{$tree}, $temp;
	}
	return $tree;
}



our $database_holder;
our $database;

# One machine, one database, at a fixed path inside the install: database/jawnos.db,
# beside schema.sql. A machine never picks or moves it - the old "newest .db in
# start_dir" scan let any stray file silently become the database, and start_dir is
# gone from this path. Backups (.enc) live in database/backups/, out of ~/. The
# install dir is this file's own real directory, resolved once, so a probe started
# from a throwaway tree of symlinks still names the real install.
our $install_dir;
BEGIN {
	require Cwd;
	require File::Basename;
	my $real = eval { Cwd::abs_path(__FILE__) };
	$install_dir = File::Basename::dirname(($real && -e $real) ? $real : Cwd::getcwd());
}
sub install_dir { return $install_dir }
sub database_dir {
	my $dir = &subs::install_dir() . '/database';
	unless (-d $dir) { require File::Path; eval { File::Path::make_path($dir) }; }
	return $dir;
}
sub database_path { return &subs::database_dir() . '/jawnos.db' }
sub backups_dir {
	my $dir = &subs::database_dir() . '/backups';
	unless (-d $dir) { require File::Path; eval { File::Path::make_path($dir) }; }
	return $dir;
}

# One machine, one database: anything else under database/ is an older
# database's leftover (server.enc, laptop_*.enc, a stray .db) and is discarded.
# The working set is the jawnos database and its sidecars, the factory seed, the
# schema, and the jawnos backups - everything else is shredded. Directories are
# never touched, so the backups/ dir itself is safe.
sub database_tidy {
	my $dir = &subs::database_dir();
	my $backups = &subs::backups_dir();
	my @gone;
	foreach my $f ( glob("$dir/*") ) {
		next if $f =~ m{/(?:jawnos\.db(?:-shm|-wal)?|schema\.sql|initial\.enc|backups)$};
		push @gone, $f;
	}
	foreach my $f ( glob("$backups/*") ) {
		next if $f =~ m{/jawnos(?:_\d+)?\.enc$};
		push @gone, $f;
	}
	@gone = grep { !-d $_ } @gone;
	foreach my $f ( @gone ) {
		`shred -u "$f" 2>/dev/null`;
		unlink $f;
	}
	&subs::log_writer('database tidy: discarded ' . scalar(@gone) . ' leftover file(s)') if scalar @gone;
	return scalar @gone;
}

# Adopt a pre-fixed-path install: move the database the old scan would have
# chosen, and the .enc backups beside it, into database/. Runs once, and only
# when the fixed database is missing, so pulling this build onto an existing
# machine needs no hand - the first database_grabber migrates it in place.
sub database_adopt_legacy {
	# A name change needs its own step first: a machine that already migrated into
	# the install still has database/initial.db (and initial*.enc backups) from
	# before the house took its own name, so rename those to jawnos.db /
	# jawnos*.enc. Without this the fixed path simply does not exist and the
	# machine is left with no database at all.
	my $dir_db = &subs::database_dir();
	if (-e "$dir_db/initial.db" && !-e "$dir_db/jawnos.db") {
		for my $ext ('', '-shm', '-wal') {
			rename "$dir_db/initial.db$ext", "$dir_db/jawnos.db$ext" if -e "$dir_db/initial.db$ext";
		}
	}
	my $bdir = &subs::backups_dir();
	foreach my $enc ( glob("$bdir/initial*.enc") ) {
		my $leaf = $enc;
		$leaf =~ s{.*/}{};
		$leaf =~ s/^initial/jawnos/;
		rename $enc, "$bdir/$leaf" if !-e "$bdir/$leaf";
	}

	my $dir = &subs::home($config->{'start_dir'} || '~/');
	$dir =~ s{/+$}{};
	my @dbs = grep { -s $_ > 5000 && $_ !~ /-(?:shm|wal)$/ } glob("$dir/*.db");
	return unless scalar @dbs;
	my ($legacy) = sort { (-M $b) <=> (-M $a) } @dbs;
	my $target = &subs::database_path();
	my $base = $legacy;
	$base =~ s{.*/}{};
	$base =~ s/\.db$//i;
	`mv -f "$legacy" "$target" 2>/dev/null`;
	`mv -f "$legacy-shm" "$target-shm" 2>/dev/null`;
	`mv -f "$legacy-wal" "$target-wal" 2>/dev/null`;
	my $backups = &subs::backups_dir();
	# the working database is jawnos.db now, so the legacy backups are renamed as
	# they move in (initial_<ts>.enc -> jawnos_<ts>.enc)
	foreach my $enc ( glob("$dir/$base*.enc") ) {
		my $leaf = $enc;
		$leaf =~ s{.*/}{};
		$leaf =~ s/^\Q$base\E/jawnos/;
		`mv -f "$enc" "$backups/$leaf" 2>/dev/null`;
	}
	&subs::log_writer('database adopted into the install: ' . $target);
	return $target;
}

sub database_grabber() {
	my $connection = shift || '';
	# A forked child inherits the parent's handle. Detach it so our exit cannot
	# close a connection the parent is still using, then dial our own below.
	if (defined $gb::database_holder->{'pid'} && $gb::database_holder->{'pid'} != $$ && defined $gb::database_holder->{'sql'} ) {
		$gb::database_holder->{'sql'}->db->dbh->{InactiveDestroy} = 1;
		$gb::database_holder = {};
	}
	# One connection per process, not per call: opening the file costs about two
	# milliseconds, which every database touch of every request used to pay, while
	# a kept handle costs microseconds. Three rules keep it safe. It is only reused
	# by the process that opened it (pid). It is only reused while the same file is
	# still in place (dev+ino) - the database is shredded and replaced on leave, and
	# a handle on the old inode would quietly serve a dead file. And before it is
	# handed on, whatever the previous caller left unfinished is finished: a results
	# object that was never fetched from pins the connection's read snapshot, and
	# that is what stopped the WAL checkpointing and grew it to the size of the
	# database once. The callers here fetch their rows before making the next
	# database call, so nothing live is cut short.
	my $holder = $gb::database_holder;
	if ($holder->{'pid'} && $holder->{'pid'} == $$ && $holder->{'db'} && $holder->{'dbh'} && $holder->{'dev'}) {
		my @stat = stat($holder->{'database'});
		if (@stat && $stat[0] == $holder->{'dev'} && $stat[1] == $holder->{'ino'}) {
			# Only when a statement is actually abandoned: ActiveKids is a cheap
			# DBI counter, zero once every result has been fetched, while
			# visit_child_handles walks every child handle ever made on the
			# connection. The callers fetch their rows before the next call, so
			# on the common path there is nothing here to finish.
			eval { $holder->{'dbh'}->visit_child_handles(sub { my $sth = shift; $sth->finish }) }
				if $holder->{'dbh'}->{ActiveKids};
			return ($holder->{'db'}, $holder->{'database'}, $holder->{'sql'});
		}
	}
	# One machine, one database, at its fixed install path - no scan for the
	# newest .db, so a stray file can never become the database. An older build
	# kept it under start_dir, so the first run after this one adopts that.
	my $database = &subs::database_path();
	unless (-e $database) { &subs::database_adopt_legacy(); }

	if ($database && -e $database && -s $database > 5000) {

		my $sql = Mojo::SQLite->new('sqlite:' . $database, sqlite_use_immediate_transaction => 0);
		$sql->options({AutoCommit => 1 });
		my $db = $sql->db;
		my @stat = stat($database);
		# The handle and its dbh are kept on the holder: the pid so a forked child
		# knows to detach rather than share it, the dbh so the reuse guard above can
		# finish its abandoned statements, and dev+ino so a replaced file is noticed.
		# hooks.pl also looks here to tell that a database is up.
		$gb::database_holder = {
			server_time => &subs::rightNow(),
			database => $database,
			db => $db,
			dbh => $db->dbh,
			sql => $sql,
			pid => $$,
			dev => $stat[0],
			ino => $stat[1]
		};
		# Wait for other writers before anything else. SQLite's default is not to
		# wait at all, so any contention surfaced as an immediate "database is locked",
		# and even reading the journal mode below can meet a writer. Each is eval'd
		# because a transient lock must not take the request down with it.
		eval { $db->query('PRAGMA busy_timeout=15000;'); };
		eval { $db->query('PRAGMA synchronous=NORMAL;'); };
		# WAL is a property of the file rather than of the connection, so it only has
		# to be set once - it is already on for an existing database, and re-issuing
		# it every dial just took a write lock for nothing.
		eval {
			my $row = $db->query('PRAGMA journal_mode;')->hashes->[0] || {};
			$db->query('PRAGMA journal_mode=WAL;') if (($row->{'journal_mode'} || '') ne 'wal');
		};
		# The rest of the tuning only makes sense on a handle that lives past one
		# call: a page cache, sorts in memory, a read-only mapping of the file, and
		# a cap on the WAL. A handheld runs a score of these handles at once, so it
		# gets a smaller cache and mapping than a server: the 8MB/128MB pair cost a
		# tablet ~150MB of page cache across its workers that it never warms.
		my $mobile = &device_setter() eq 'mobile';
		eval { $db->query('PRAGMA cache_size=' . ($mobile ? -2000 : -8000) . ';'); };
		eval { $db->query('PRAGMA temp_store=MEMORY;'); };
		eval { $db->query('PRAGMA mmap_size=' . ($mobile ? 33554432 : 134217728) . ';'); };
		# Keep the write-ahead log small. A checkpoint that resets the WAL truncates
		# the file to this many bytes, so the cap IS the steady-state size - at 32MB
		# every machine carried a 32MB -wal beside its database (the health read
		# reports it now). 4MB matches the ~1000-page autocheckpoint, so the file is
		# reclaimed often without being truncated to nothing on every write.
		eval { $db->query('PRAGMA journal_size_limit=4194304;'); };
		return ($db,$database,$sql);
	}
	$gb::database_holder = {};
	return (undef,undef,undef);
}

sub dbs_insert {
  # Legacy name kept for the device scripts: inserts used to be posted through
  # the memory mirror's socket, and now they go straight to the database.
  my $success = &db_insert(@_);
  return $success ? $success->last_insert_id : undef;
}

sub db_insert() {
	my $table = shift;
	my $data = shift;
	%setting_memo = () if ($table // '') eq 'settings';
	$data->{'ost'} = $data->{'ost'} || &rightNow();
	$data->{'server_time'} = $data->{'server_time'} ? $data->{'server_time'} : $data->{'ost'};
	$data->{'uuid'} = &random_string_creator(15) unless $data->{'uuid'};
	my ($db,$database,$sql) = &database_grabber();
	return unless $db;
	my $success;
	my $count = 0;
	# Whether the insert landed is the insert's own row count, not
	# last_insert_id: a refused write answers zero rows while last_insert_id
	# is either zero on a fresh connection or, worse, the *previous* insert's
	# id - which is how a refused write came back looking like a success and
	# was retried until the driver had complained twenty-five times. A retry
	# is for a statement that would not run at all, and it stays bounded.
	until ($success || $count >= 25) {
		my $results = eval { return $db->insert($table, $data); };
		if ($@) {
			# A refused insert used to vanish here: the caller's eval caught the
			# die, the row simply did not arrive, and a merge reported a table as
			# complete. Name the table and the reason instead.
			&log_writer('db_insert ' . $table . ' failed: ' . ($@ =~ s/\s+/ /gr));
		}
		if ($results && $results->rows) {
			$success = $results;
		}
		elsif ($results) {
			# the statement ran and was refused; asking again will not help
			last;
		}
		$count++;
	}
	&db_cache_updater($table, $data);
	return $success;
}

sub db_query() {
	my $query = shift;
	my @params = @_;
	my ($db,$database,$sql) = &database_grabber();

	return eval { return $db->query($query, @params)  } if $db;
}

# The rows from a query as a plain arrayref of hashes - what db_query's
# ->hashes gives back, but over the shared handle with a statement cache and
# without the Mojo::SQLite::Results object and its per-call finalize. The hot
# readers (log_reader's per-poll selects) only ever ask for ->hashes, and that
# wrapper was a measurable slice of the poll. Anything needing more of the
# Results API still goes through db_query.
sub db_raw() {
	my $query = shift;
	my @params = @_;
	my ($db) = &database_grabber();
	return [] unless $db;
	my $sth = eval { $db->dbh->prepare_cached($query) };
	return [] unless $sth;
	# Mojo::SQLite tolerated a bind count that did not match the placeholders
	# (some call sites interpolate a value into the SQL and then pass it as a bind
	# too, and one builds one clause too many); a direct execute fails on either
	# mismatch. Trim extras and NULL-fill any shortfall so the result matches what
	# the same SQL returned through db_query.
	my $n = $sth->{NUM_OF_PARAMS};
	if (defined $n) {
		splice(@params, $n) if @params > $n;
		push @params, undef while @params < $n;
	}
	return [] unless eval { $sth->execute(@params); 1 };
	my $rows = eval { $sth->fetchall_arrayref({}) };
	# finish it: a statement left active pins the connection's read snapshot in
	# SQLite, so later reads would see the world as it was here, not as it is
	eval { $sth->finish };
	return $rows || [];
}

# db_raw's fresh twin: the same read, but on a freshly prepared statement, so it
# cannot inherit a cached handle that a dead request left executed-but-unfetched
# - such a handle answers 0 rows to every later read of the same SQL, and the
# mailbox threads hit exactly that. A fresh prepare costs microseconds, which
# the once-per-render readers can spare; the per-poll hot paths stay on db_raw.
sub db_fresh() {
	my $query = shift;
	my @params = @_;
	my ($db) = &database_grabber();
	return [] unless $db;
	my $sth = eval { $db->dbh->prepare($query) };
	return [] unless $sth;
	my $n = $sth->{NUM_OF_PARAMS};
	if (defined $n) {
		splice(@params, $n) if @params > $n;
		push @params, undef while @params < $n;
	}
	return [] unless eval { $sth->execute(@params); 1 };
	my $rows = eval { $sth->fetchall_arrayref({}) };
	eval { $sth->finish };
	return $rows || [];
}


sub db_update() {
	my $table = shift;
	my $data = shift;
	my $params = shift;
	%setting_memo = () if ($table // '') eq 'settings';
	my ($db,$database,$sql) = &database_grabber();
	$data->{'server_time'} = &subs::rightNow() unless $data->{'server_time'};
	&db_cache_updater($table, $params);
	return $db->update($table, $data, $params) if $db;
}

sub dbs_update {
  # Straight to the database now; the memory mirror is retired.
  return &db_update(@_);
}


sub dbs_delete {
  # Straight to the database now; the memory mirror is retired.
  return &db_delete(@_);
}

sub db_delete() {
	my $table = shift;
	my $params = shift;
	%setting_memo = () if ($table // '') eq 'settings';

	my ($db,$database,$sql) = &database_grabber();
	my ($lid,$success);
	if ($db) {
		if ($table && ref $params eq ref {}) {
			$success = $db->delete($table, $params);
		}
		else {
		}
	}
	&db_cache_updater($table, $params);
	return $success;
}

sub db_select() {
	my $table = shift;
	my $columns = shift;
	my $params = shift;
	my $filters = shift;
	my ($db,$database,$sql) = &database_grabber();

	return $db->select($table,$columns,$params,$filters) if $db;
}

# A raw-SQL fast path for the common db_select shape: one table, equality
# filters, and IS NULL for an undef value. SQL::Abstract was a measurable slice
# of a settings read (it re-derives the same WHERE every call). Anything richer
# - a ref filter value, or a $filters argument - falls back to db_select, so
# behaviour is unchanged.
sub db_select_simple() {
	my ($table, $columns, $params, $filters) = @_;
	return &db_select($table, $columns, $params, $filters)
		if $filters || !$params || ref($params) ne 'HASH' || grep { ref $params->{$_} } keys %{$params};
	my (@w, @v);
	foreach my $k (sort keys %{$params}) {
		if (defined $params->{$k}) { push @w, "$k = ?"; push @v, $params->{$k}; }
		else { push @w, "$k is null"; }
	}
	my $cols = ref($columns) eq 'ARRAY' ? join(', ', @{$columns}) : (defined $columns ? $columns : '*');
	my $sql = 'select ' . $cols . ' from ' . $table;
	$sql .= ' where ' . join(' and ', @w) if @w;
	return &db_query($sql, @v);
}

sub db_close() {

}

sub db_cache_updater() {
	return;
	my ($table,$data) = @_;
	if ($table eq 'appointments') {
		if ($data->{'app'} && $data->{'uuid'}) {
			&subs::subprocessor(sub {
				Mojo::IOLoop->reset;
				&subs::db_delete('cache', { app => $data->{'app'} });
				&Manager::centre_view_grabber({ c => &subs::controller_builder(), app => $data->{'app'}, timestamp => &subs::rightNow(), resetting => 'yes' });
			}, { name => 'db cache updater' });
		}
	}
}

# ---- theme surfaces -----------------------------------------------------------
# Windows and panels should read as a step away from the page background, in a
# grey that still carries a hint of the theme's hue. These helpers turn a theme
# background colour into the --panel/--panel-2/--ink values the CSS uses.
sub _rgb_to_hsl {
	my ($r, $g, $b) = map { $_ / 255 } @_;
	my $max = $r > $g ? ( $r > $b ? $r : $b ) : ( $g > $b ? $g : $b );
	my $min = $r < $g ? ( $r < $b ? $r : $b ) : ( $g < $b ? $g : $b );
	my $l = ($max + $min) / 2;
	my ($h, $s) = (0, 0);
	if ($max != $min) {
		my $d = $max - $min;
		$s = $l > 0.5 ? $d / (2 - $max - $min) : $d / ($max + $min);
		if ($max == $r) { $h = ($g - $b) / $d + ($g < $b ? 6 : 0); }
		elsif ($max == $g) { $h = ($b - $r) / $d + 2; }
		else { $h = ($r - $g) / $d + 4; }
		$h *= 60;
	}
	return ($h, $s, $l);
}

sub _hsl_to_hex {
	my ($h, $s, $l) = @_;
	# Perl's % truncates its operands to integers: (($h/60) % 2) would throw the
	# hue's fraction away, collapse the interpolation and turn a blue into a cyan
	# (the JS mirror jawnosHslToHex uses a float %, so server and client panels
	# disagreed). Do the fractional wrap by hand.
	$h -= 360 * int($h / 360);
	$h += 360 if $h < 0;
	my $c = (1 - abs(2 * $l - 1)) * $s;
	my $seg = $h / 60;
	$seg -= 2 * int($seg / 2);
	my $x = $c * (1 - abs($seg - 1));
	my $m = $l - $c / 2;
	my ($r, $g, $b);
	if ($h < 60) { ($r, $g, $b) = ($c, $x, 0); }
	elsif ($h < 120) { ($r, $g, $b) = ($x, $c, 0); }
	elsif ($h < 180) { ($r, $g, $b) = (0, $c, $x); }
	elsif ($h < 240) { ($r, $g, $b) = (0, $x, $c); }
	elsif ($h < 300) { ($r, $g, $b) = ($x, 0, $c); }
	else { ($r, $g, $b) = ($c, 0, $x); }
	return sprintf('#%02X%02X%02X', map { int(($_ + $m) * 255 + 0.5) } ($r, $g, $b));
}

# Pick black or white ink to sit on top of an arbitrary background colour, so
# appointment/name labels stay readable whatever colour the theme gives them.
# The inks are weighed the WCAG way - each channel linearised and weighted
# before the sum - because that is how the eye reads them: the two tie at a
# luminance of about 0.179, not half way, so a hot pink like #ea43b8 takes
# black where a flat average of the channels inked it white.
sub contrast_ink {
	my ($bg) = @_;
	return '#000000' unless defined $bg && $bg =~ /^\#?([0-9a-fA-F]{6})$/;
	my @channel = map { hex } ($1 =~ /(..)(..)(..)/);
	my @weight = ( 0.2126, 0.7152, 0.0722 );
	my $lum = 0;
	foreach my $i ( 0 .. 2 ) {
		my $c = $channel[$i] / 255;
		$c = $c <= 0.04045 ? $c / 12.92 : ((($c + 0.055) / 1.055) ** 2.4);
		$lum += $c * $weight[$i];
	}
	return $lum < 0.179 ? '#ffffff' : '#000000';
}

# The mark a budget light wears, as inner SVG for a 24x24 viewBox. The four
# built-in budget modes each get something that reads at chip size - a repeat
# for a count of times, a clock for a duration, a price tag for a money total,
# a hash for a quantity. A user's special budget has no mark and falls back to
# its initial. Paths only: the caller owns the <svg> element and its fill.
sub budget_icon {
	my ($circumstance) = @_;
	return '' unless defined $circumstance;
	my %glyph = (
		occurences => '<path d="M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z"/>',
		duration   => '<path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/>',
		total      => '<path d="M21.41 11.58l-9-9C12.05 2.22 11.55 2 11 2H4c-1.1 0-2 .9-2 2v7c0 .55.22 1.05.59 1.42l9 9c.36.36.86.58 1.41.58s1.05-.22 1.41-.59l7-7c.37-.36.59-.86.59-1.41s-.23-1.06-.59-1.42zM5.5 7C4.67 7 4 6.33 4 5.5S4.67 4 5.5 4 7 4.67 7 5.5 6.33 7 5.5 7z"/>',
		quantity   => '<path d="M15.5 3l-.86 5H10.4l.86-5H9.2l-.86 5H5v2.1h3.1l-.7 4H4v2.1h3.17L6.5 21h2.06l.86-5h4.24l-.86 5h2.06l.86-5H20v-2.1h-4.1l.7-4H20V7.9h-3.2l.86-5zM13.05 10.1l-.7 4H8.1l.7-4z"/>',
	);
	return $glyph{$circumstance} || '';
}

# Render the CSS custom properties for a theme, given its background colour.
# Light themes get a light grey, dark themes a dark grey; both keep a whisper of
# the theme's hue. Returned as a declaration string so a layout can fold it into
# an inline style attribute.
sub theme_panel_css {
	my ($bg) = @_;
	my ($r, $g, $b);
	if (defined $bg && $bg =~ /^\#?([0-9a-fA-F]{6})$/) {
		($r, $g, $b) = map { hex } ($1 =~ /(..)(..)(..)/);
	}
	unless (defined $r) {
		my @palette = &theme_palette();
		if (scalar @palette && $palette[0] =~ /^\#([0-9a-fA-F]{6})$/) {
			($r, $g, $b) = map { hex } ($1 =~ /(..)(..)(..)/);
		}
	}
	unless (defined $r) {
		return '--ink:#000000;--ink-muted:#333333;--panel:#ffffff;--panel-2:#f0f0f0;--line:#c9c9c9;';
	}
	my $lum = (0.2126 * $r + 0.7152 * $g + 0.0722 * $b) / 255;
	my ($h, $s, $l) = &_rgb_to_hsl($r, $g, $b);
	my $tint = $s < 0.18 ? $s : 0.18;
	# --line is the chrome border colour, kept a shade off --panel so frames and
	# seams read as an edge rather than a bright white outline. --ink is the text;
	# it was #f2f2f2 (near white) which glares on a dark panel, and it used to be
	# the border colour too (borders with no colour inherit currentColor), which
	# is why every dark window wore a white outline.
	if ($lum < 0.5) {
		my $panel = &_hsl_to_hex($h, $tint, 0.16);
		my $panel2 = &_hsl_to_hex($h, $tint, 0.23);
		my $line = &_hsl_to_hex($h, $tint, 0.32);
		return "--ink:#d4d4d4;--ink-muted:#8f8f8f;--panel:$panel;--panel-2:$panel2;--line:$line;";
	}
	my $panel = &_hsl_to_hex($h, $tint, 0.88);
	my $panel2 = &_hsl_to_hex($h, $tint, 0.80);
	my $line = &_hsl_to_hex($h, $tint, 0.66);
	return "--ink:#000000;--ink-muted:#333333;--panel:$panel;--panel-2:$panel2;--line:$line;";
}

# The colours the current theme is built from: the distinct *_background_colour
# swatches for a device (falling back through the other devices if unset).
sub theme_palette() {
	my $device = shift || &subs::device_setter();
	my $config = &subs::config_reader();
	my @devices = ( $device, @gb::device_types, &subs::signatorial_designer() );
	my %tried;
	foreach my $dt ( @devices ) {
		next if $tried{$dt}++;
		next unless $config->{$dt};
		my %seen;
		my @palette;
		foreach my $k ( @gb::misc_settings ) {
			my $c = $config->{$dt}->{$k}->{'background_colour'};
			next unless $c;
			$c = '#' . $c unless $c =~ /^#/;
			next unless $c =~ /^#[0-9a-fA-F]{6}$/;
			$c = lc $c;
			push @palette, $c unless $seen{$c}++;
		}
		return @palette if scalar @palette;
	}
	return ();
}

sub random_colour_grabber() {
	my @palette = &theme_palette();
	if (scalar @palette > 0) {
		my $pick = $palette[ int(rand(scalar @palette)) ];
		$pick =~ s/^#//;
		return $pick;
	}

	my $col = [ 0, 0, 0 ];
	foreach my $co ( @{$col} ) {
		until ($co > 130) {
			$co = rand(255);
		}
	}
	return join "", map { sprintf "%02x", $col->[$_] } (0..2);
}

# Snap an app's colour into the theme. If the existing colour is already one of
# the theme's colours it is left alone; otherwise a stable theme colour is chosen
# for that app and saved. With no theme colours configured, the value is returned
# unchanged.
sub theme_colour_grabber() {
	my $data = ( ref $_[0] eq 'HASH' ) ? $_[0] : { app => $_[0] };
	my $app = $data->{'app'};
	return $data->{'existing'} unless $app;
	my $device = $data->{'device'} || &subs::device_setter();

	my $existing = $data->{'existing'};
	unless (defined $existing) {
		my $q = &db_select('settings', ['value'], { app => $app, setting => 'colour', device => $device })->hashes;
		$q = &db_select('settings', ['value'], { app => $app, setting => 'colour' })->hashes unless scalar @{$q};
		$existing = $q->[-1]->{'value'} if scalar @{$q};
	}

	my @palette = &theme_palette($device);
	return $existing unless scalar @palette;

	my $normalized = defined $existing ? lc $existing : '';
	$normalized = '#' . $normalized if $normalized =~ /^[0-9a-f]{6}$/;
	if (grep { $_ eq $normalized } @palette) {
		return $existing;
	}

	my $sum = 1;
	$sum += ord for split //, $app;
	my $colour = $palette[ $sum % scalar @palette ];

	&setting_setter({ app => $app, setting => 'colour', value => $colour, device => $device, silent => 'yes' });
	return $colour;
}

# Wrapper used by the getters: skips the built-in apps and blank names.
sub theme_colour_for_app() {
	my ($app, $existing, $device) = @_;
	return $existing unless $app;
	foreach my $p ( @gb::protected ) {
		return $existing if lc($p) eq lc($app);
	}
	return &theme_colour_grabber({ app => $app, existing => $existing, device => $device });
}

# The currently selected pseudonym icon set ('' for the modern default). Memoised
# per process with a short TTL: icon_for() runs once per icon on every render and
# each miss costs a config read (a DB query plus Sereal decode).
my $icon_set_memo;
my $icon_set_memo_time = 0;
sub icon_set() {
	my $now = &rightNow();
	return $icon_set_memo if defined $icon_set_memo && $now - $icon_set_memo_time < 1000;
	my $config = &config_reader();
	$icon_set_memo = $config->{'icon_set'} || '';
	$icon_set_memo_time = $now;
	return $icon_set_memo;
}
# Called when the icon set is changed, so the very next render already uses it
# instead of waiting out the memo above.
sub icon_set_forget {
	$icon_set_memo = undef;
	$icon_set_memo_time = 0;
}

# When the hand-drawn set is active, swap a public icon path for its original
# hand-drawn PNG (kept in public/icons/original/) if one exists.
sub icon_original() {
	my $path = shift;
	return $path unless defined $path && $path =~ m{^/};
	return $path unless &icon_set() eq 'handdrawn';
	my $candidate = "/icons/original" . $path;
	return -e "public" . $candidate ? $candidate : $path;
}

# The hand-drawn picture behind a public icon path, whatever icon set is
# selected - the gate's splash and the denial page wear it always. build.js
# renders generated tiles in at the old public paths, so the plain path no
# longer shows the hand.
sub icon_drawn() {
	my $path = shift;
	return $path unless defined $path && $path =~ m{^/};
	my $candidate = "/icons/original" . $path;
	return -e "public" . $candidate ? $candidate : $path;
}

# Resolve a button icon through the selected set, falling back to the given path.
sub icon_path() {
	my ($name, $fallback) = @_;
	my $set = &icon_set();
	if ($set eq 'handdrawn') {
		return &icon_original($fallback);
	}
	if ($set) {
		my $path = "/icons/sets/" . $set . "/" . $name . ".svg";
		return $path if -e "public" . $path;
	}
	return $fallback;
}

# Resolve an app icon given its normal public path: hand-drawn originals for the
# hand-drawn set, or the matching /icons/sets/<set>/<basename>.svg when present.
sub icon_for() {
	my ($path, $set) = @_;
	return $path unless defined $path && $path =~ m{^/};
	$set = &icon_set() unless defined $set;
	return &icon_original($path) if $set eq 'handdrawn';
	return $path unless $set;
	my ($base) = $path =~ m{([^/]+)$};
	$base =~ s/\.[A-Za-z0-9]+$//;
	my $candidate = "/icons/sets/$set/$base.svg";
	return $candidate if -e "public" . $candidate;
	return $path;
}

# The colours a text control wears to sit beside the icon set's tiles: every
# generated tile is filled from hsl() values (the loud sets build their
# gradients from the same ones, so the first hsl() in the file is still the
# tile's colour) and the lightness says whether dark or light ink reads on it.
# The tile is named for the state the control is about - the page button wears
# the "now" tile at home and the back/forward tiles once it has walked. Memoised
# per set and tile: the files only change when build.js runs, while the manager
# re-renders constantly.
my %icon_plate_memo;
sub icon_plate_colours() {
	my $icon = shift || 'now';
	my $set = &icon_set() || '';
	my $memo_key = $set . '/' . $icon;
	return $icon_plate_memo{$memo_key} if exists $icon_plate_memo{$memo_key};
	my $colours = { plate => '', ink => '' };
	if ($set && $set ne 'handdrawn') {
		my $file = 'public/icons/sets/' . $set . '/' . $icon . '.svg';
		my $svg = -e $file ? read_file($file) : undef;
		if (defined $svg && $svg =~ /(hsl\(\s*\d+\s*,\s*\d+%\s*,\s*(\d+)%\s*\))/) {
			$colours = { plate => $1, ink => ($2 > 65 ? '#111111' : '#ffffff') };
		}
	}
	return $icon_plate_memo{$memo_key} = $colours;
}

# A fingerprint of everything that gets baked into cached window/header HTML:
# the icon set and the device's theme colours. Cached renders whose signature no
# longer matches are discarded, so closed windows don't come back looking stale.
sub render_signature() {
	my $device = &device_setter();
	my $config = &config_reader();
	# the version is part of the signature so every release (each push bumps it)
	# discards cached appointment renders - without it a template change to an
	# appointment window would sit behind a cache row that matched forever
	my @parts = ( &icon_set() || '', &jawn_version() );
	foreach my $k ( @gb::misc_settings ) {
		push @parts, $k . '=' . ($config->{$device}->{$k}->{'background_colour'} || '');
	}
	return join '|', @parts;
}


sub typesetter() {
	my $app = shift;
	my $save = shift;
	my $type = 'idea';
	my $movement = '';
	my $last_word = (split '_', $app)[-1];
	my $first_word = (split '_', $app)[0];
	my $type_saved = 0;
	$last_word =~ s/[0-9]$//gi;
	$first_word =~ s/[0-9]$//gi;
	if ($last_word !~ /^!/ && grep { lc $last_word eq $_ } keys %{$gb::pos}) {
		my @app = split '_', $app;
		pop @app unless scalar @app == 1;
		$app = join '_', @app;
		$type = $last_word;
		$type_saved = 1;
	}
	elsif ($last_word =~ /^!/) {
		my @app = split '_', $app;
		$last_word = pop @app;
		$last_word =~ s/^!//gi;
		push @app, $last_word;
		$app = join '_', @app;
	}
	elsif ( my $default_pos = &subs::setting_grabber({ app => 'me', setting => 'pos' }) ) {
		$type = $default_pos;
	}
	if ($first_word !~ /^!/ && grep { lc $first_word eq $_ } @gb::movements) {
		my @app = split '_', $app;
		shift @app unless scalar @app == 1;
		$app = join '_', @app;
		$movement = $first_word;
	}
	elsif ($first_word =~ /^!/) {
		my @app = split '_', $app;
		$first_word = shift @app;
		$first_word =~ s/^!//gi;
		unshift @app, $first_word;
		$app = join '_', @app;
	}
	if ($type_saved == 1 && $save ne 'no') {
		&subs::setting_setter({ app => $app, setting => 'pos', value => $type });
	}
	return ($app,$type,$movement);
}

sub setting_initializer() {
	my ($app,$timestamp) = @_;
	my $returner;
	$app = &unformat_name($app);
	my ($db,$database) = &database_grabber();
	my $server_time = &rightNow();
	my $type;
	($app,$type) = &typesetter($app);
	my $counter = &subs::db_query('select count(*) from appointments where app=?', $app);
	my $count = $counter->hash->{'count(*)'};
	my $res = &db_query('select * from settings where app=? and device = ? order by server_time desc',$app,$device);
	my $re = $res->hashes;

	my $aka = &db_query('select * from settings where setting = ? and value like ?', 'aka', '%' . $app . '%')->hashes;

	if ( $count == 0 && scalar @{$aka} > 0 ) {
		foreach my $ak ( @{$aka} ) {
			if (exists $ak->{'value'}) {
				my @a = split ',', $ak->{'value'};
				foreach my $o ( @a ) {
					$o = &subs::unformat_name($o);
					if ($o eq $app) {
						$app = &subs::unformat_name($ak->{'app'});
						$res = &db_query('select * from settings where app=?',$app);
						$re = $res->hashes;
						last;
					}
				}
			}
		}
	}
	my $me_settings = &subs::settings_grabber({ app => 'me' });

	my $colour = &random_colour_grabber();

	$returner->{'app'} = $app;
	my $settings = {
		'colour' => ('#' . $colour || 'white'),
		'worth' => $me_settings->{'worth'},
		'visible' => 'checked',
		'permanent' => 'checked',
		'pos' => $type,
		'duration' => $me_settings->{'duration'},
		'currency' => $me_settings->{'currency'},
		'unit' => $me_settings->{'unit'},
		'cost' => 0,
		'enc' => 'on',
		'public' => 'off',
		'warranty' => $me_settings->{'warranty'},
		'notification_text' => &subs::format_name($app),
		'schedule' => 'once',
		'uuid' => &random_string_creator(25),
		'navigation' => 'none'
	};

	foreach my $s (keys %{$settings}) {
		my @seen = grep { $_->{'setting'} eq $s } @{$re};

		unless ( scalar @seen > 0 ) {
			my $pen = {
				app => $app,
				timestamp => &subs::rightNow(),
				setting => $s,
				value => $settings->{$s},
				server_time => &subs::rightNow(),
				device => $device,
				uuid => &random_string_creator(20)
			};
			&db_insert('settings', $pen);
			$returner->{$s} = $settings->{$s};
		}
		else {
			my $set = $seen[0];
			$returner->{$s} = $set->{'value'};
			if (scalar @seen > 1) {
				#unshift @seen;
				foreach my $s ( @seen ) {
					&subs::db_delete('settings', { app => $app, uuid => $s->{'uuid'} });
					&Manager::deletion_registration({ table => 'settings', app => $app, uuid => $s->{'uuid'}, scope => 'single', server_time => $s->{'server_time'} });
				}
			}
		}
	}
	return $returner;
};

&signatorial_establisher();

sub signatorial_establisher {
	my $context = shift;
	# Pin the session secret even when the signatorial image is missing. Left
	# unpinned, each Mojolicious worker signs sessions with its own random key, so
	# a session the dock mints (a ticket) will not verify at the manager - the
	# Gate a client lands on holding a perfectly good ticket. The fallback is
	# deterministic (the configured path), so the tree's workers share it.
	$gb::secret_maker ||= [ md5_sum('signatorial:' . ($config->{'signatorial'} || 'jawnos')) ];
	if ($config->{'signatorial'} && -e $config->{'signatorial'}) {

		my $j = &subs::terminal_name(&subs::home($config->{'signatorial'}));
		my $checksum = `base64 $j`;
		my $md5 = md5_sum $checksum;
		$gb::secret_maker = [ $md5 ];
		return $md5;
	}
	elsif ($context ne 'designer') {
		return &random_string_creator(12);
	}
}

sub signatorial_identity_file() {
	return &home('~/.jawnos_signatorial_id');
}

sub signatorial_identity_write {
	my $id = shift;
	my $file = &signatorial_identity_file();
	if (open my $fh, '>', $file) {
		chmod 0600, $file;
		print $fh $id, "\n";
		close $fh;
	}
	return $id;
}

sub signatorial_designer() {
	my $designation = shift;
	if (!$designation && $gb::signatorial) {
		return $gb::signatorial;
	}

	# A persisted identity is the point: it must not change when a picture is
	# added or removed, and every container or clone must have its own. The
	# file is written once - by setup for a new install, or by the legacy
	# migration below for a machine that predates it - and is never recomputed.
	my $file = &signatorial_identity_file();
	if (-e $file) {
		my $id = `cat $file`;
		chomp $id;
		if ($id =~ /^[0-9a-f]{16,64}$/i) {
			$gb::signatorial = lc $id;
			return $gb::signatorial;
		}
	}

	# A machine that predates the identity file: its current signatorial is
	# already the key on its settings, continent and sync rows. Take the most
	# used long device value that is not a peer's signatorial, and pin that -
	# never recompute it, since the picture folder may have drifted since.
	my $stored = eval {
		my $row = &db_query(
			"select device from settings"
			. " where device is not null and length(device) >= 16"
			. " and device not in (select signatorial from remote_machines where signatorial is not null)"
			. " group by device order by count(*) desc limit 1"
		)->hash;
		( $row && $row->{'device'} && $row->{'device'} =~ /^[0-9a-f]{16,64}$/i ) ? lc $row->{'device'} : undef;
	};
	if ($stored) {
		&signatorial_identity_write($stored);
		$gb::signatorial = $stored;
		return $gb::signatorial;
	}

	# Legacy migration: compute exactly what this machine announced before the
	# identity was persisted, then pin it. Every remote_machines.signatorial,
	# settings.device and JSON reference keeps pointing at the same value.
	my $folder = './public/images/jonathans';
	my $jonathans = `ls $folder`;
	my @jonathans = split /\n/, $jonathans;
	my $checksum = $database;
	foreach my $j ( @jonathans ) {
		$j = &terminal_name($folder . '/' . $j);
		$checksum .= encode_base64 `cat $j`;
	}
	my $md5 = md5_sum &signatorial_establisher('designer') . $checksum;
	&signatorial_identity_write($md5);
	$gb::signatorial = $md5;

	return $gb::signatorial;
}

sub runner_label() {
	# the machine a command ran on, for the appointment details
	my $hostname = `hostname`;
	chomp $hostname;
	return $hostname;
}

sub destination_relay() {
	# Run an app's command on other machines: a POST to the machine's
	# /manager/reset, which runs that machine's own command for the app and
	# records its own appointment (exactly what a press there does). The
	# destination is a signatorial from the remote machine list; 'all' fans out
	# to every active machine. Returns a label for the machine that took it, or
	# undef when nobody did.
	my $data = shift;
	my $destination = $data->{'destination'};
	my $app = $data->{'app'};
	my $movement = $data->{'movement'} || 'command';
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $me = &subs::signatorial_designer();
	my $rms;
	if (!$destination || $destination eq 'all') {
		$rms = &subs::remote_machine_lister({ connection => 'active' });
	}
	else {
		$rms = &subs::remote_machine_lister({ signatorial => $destination, connection => 'active' });
	}
	$rms = [] unless ref $rms eq 'ARRAY';
	my $sent = 0;
	my $label;
	foreach my $rm ( @{$rms} ) {
		next unless ref $rm eq 'HASH';
		my $sig = $rm->{'signatorial'};
		next unless $sig && $sig ne $me;   # this machine's own copy is run by the caller
		next unless $rm->{'ip'};
		my $hop = &Manager::remote_useragent_maker({ rm => $rm, signatorial => $sig });
		next unless $hop && $hop->{'ua'} && $hop->{'manager'};
		my $res = eval {
			$hop->{'ua'}->insecure(1)->post($hop->{'manager'} . '/manager/reset' => form => {
				app => $app,
				type => $movement,
				timestamp => $timestamp,
				notes => 'sent from ' . $me
			})->result;
		};
		if ($res && eval { $res->is_success }) {
			$sent++;
			$label = $rm->{'hostname'} . ' (' . $rm->{'ip'} . ')' unless $label;
		}
		else {
			$log->error('destination relay to ' . ($sig || '?') . ' failed: ' . ($@ || 'no answer'));
		}
	}
	if (!$destination || $destination eq 'all') {
		return $sent ? 'every machine (' . $sent . ')' : undef;
	}
	return $label;
}

sub run_command() {
	my $app = shift;
	my $command = shift;
	my $timestamp = shift;
	my $exec = 'none';
	my $whoami = `whoami`;
	chomp $whoami;
	my $hostname = `hostname`;
	chomp $hostname;
  &subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		if ($command =~ /^&/) {
			$exec = eval { $command };
			my $json = { type => 'command', whoami => 'President', hostname => $hostname, uuid => &subs::random_string_creator(), command => $command, 'return' => $exec, timestamp => $timestamp };

			&Websocket::send('server', $json);
		}
		else {
			$exec = eval { return `$command` };
			my $json = { type => 'command', whoami => $whoami, hostname => $hostname, uuid => &subs::random_string_creator(), command => $command, 'return' => $exec, timestamp => $timestamp };

			&Websocket::send('server', $json);
			sleep(.3);
			my $msg = { app => $app, whoami => $whoami, hostname => $hostname, uuid => &subs::random_string_creator(25), console => $command };
			&Websocket::send('server', $msg);
		}
		return 'done';
	}, { name => 'run command' });
}

sub rightNow() {
	my $precision = shift;
	my $time = time() * 1000;

	unless ($precision) {
		$time = sprintf("%.0f",$time);
	}

	return $time;
}

sub headless_navigation() {
	my $signatorial = &subs::signatorial_designer();
	my $now = &subs::rightNow();
	my $navigation_due = [];
	my $note;
	my $running_appts = &subs::db_query('select app,uuid,type,warranty from appointments where (type = ? or type = ?) and timestamp < ?', 'start', 'record', $now)->hashes;
	foreach my $appt ( @{$running_appts} ) {
		my $navigation = &subs::setting_grabber({ app => $appt->{'app'}, setting => 'navigation' });
		if ($navigation eq 'once' || $navigation eq 'none') {
			next;
		}
		else {
			my $last_appt_location = &subs::db_query('select * from continent where app=? and uuid like ? order by server_time desc', $appt->{'app'}, $appt->{'uuid'} . '%')->hashes->[0];
			my $increment = &subs::time_abbrev_translator($navigation);
			if ($now >= $last_appt_location->{'timestamp'} + $increment ) {
				push @{$navigation_due}, { app => $appt->{'app'}, uuid => $appt->{'uuid'} };
			}
		}
	}

	if ($now - $gb::timeouts->{'navigation'}->{'lasted_run'} >= $gb::timeouts->{'navigation'}->{'interval'} * 1000) {
		$gb::timeouts->{'navigation'}->{'lasted_run'} = $now;
		my $returner = {
			uuid => &subs::random_string_creator(103),
			type => 'temporary',
			app => '__president',
			timestamp => $now,
			signatorial => $signatorial,
			server_time => &subs::rightNow(),
			warranty => &subs::ago_calc('-' . &subs::duration_sayer($gb::timeouts->{'navigation'}->{'interval'} * 1000 * 3),$now),
		};
		my $written = 0;
		# The capture runs on the navigation interval alone (the gate above). It
		# used to also wait until the machine's newest location row was older than
		# the interval - but the browser writes those rows too (continent_record),
		# so an open app reset the clock and this autonomous capture starved. It now
		# records on its own cadence whether or not the browser just did.
		if (&subs::device_setter() eq 'mobile') {
			my $jloc = `termux-location`;
			my $loc = eval { return decode_json $jloc } || {};
			# A walk gives plenty of perfectly usable fixes that are a couple of
			# seconds old or a little loose. The old 1s / 100m gates threw them
			# away silently, so the location stopped moving with the person; keep
			# the good ones and say when a fix was dropped.
			my $usable = $loc->{'latitude'} && ($loc->{'elapsedMs'} || 0) < 30000 && ($loc->{'accuracy'} || 0) < 500;
			# With the screen off the phone often cannot get a fresh GPS fix at all,
			# so termux-location answers with a last-known one minutes old and the
			# point was dropped - the position stopped moving and the home plate
			# never fired. When the GPS fix is stale or loose, ask the network
			# provider (a fresh, coarser fix) rather than throw the point away.
			unless ($usable) {
				my $nloc = eval { return decode_json `termux-location -p network` } || {};
				if ($nloc->{'latitude'} && ($nloc->{'elapsedMs'} || 1e9) < 60000 && ($nloc->{'accuracy'} || 0) < 2000) {
					$loc = $nloc;
					$usable = 1;
				}
			}
			if ($usable) {
				$returner->{'latitude'} = $loc->{'latitude'};
				$returner->{'longitude'} = $loc->{'longitude'};
				$returner->{'accuracy'} = sprintf("%.2F", $loc->{'accuracy'});
				&subs::db_delete('continent', { type => 'temporary', signatorial => $signatorial });
				my $treturner = clone $returner;
				$treturner->{'uuid'} = &subs::random_string_creator(31);
				&subs::db_insert('continent', $treturner);
				$written = 1;
				$note = 'fix ' . ($loc->{'provider'} || 'gps') . ' ' . ($returner->{'accuracy'} || '?') . 'm';
			}
			else {
				$log->info('navigation: termux-location gave no usable fix (' . ($loc->{'latitude'} ? 'elapsed ' . ($loc->{'elapsedMs'} || '?') . 'ms accuracy ' . ($loc->{'accuracy'} || '?') . 'm' : ($jloc || 'empty output')) . ')');
				$note = 'no usable fix';
			}
		}
		else {
			$returner = &subs::embedded_location_grabber($returner);
			if ($returner->{'latitude'}) {
				&subs::db_delete('continent', { type => 'temporary', signatorial => $signatorial });
				my $treturner = clone $returner;
				$treturner->{'uuid'} = &subs::random_string_creator(31);
				&subs::db_insert('continent', $treturner);
				$written = 1;
				$note = 'fix ' . ($returner->{'accuracy'} || '?') . 'm';
			}
		}
		if ($returner->{'latitude'} && $written == 1) {

		#	&subs::db_insert('continent', $returner);
			foreach my $nd ( @{$navigation_due} ) {
				$returner->{'uuid'} = $nd->{'uuid'} . '-' . &subs::random_string_creator(9);
				$returner->{'app'} = $nd->{'app'};
				$returner->{'warranty'} = $nd->{'warranty'};
				$returner->{'type'} = 'app';
				&subs::db_insert('continent', $returner);
			}
			&subs::navigation_automation($returner);

		}
	}
	return $note;
}

sub navigation_information() {
	my $data = shift;
	my $current_locations;
	if ($data->{'signatorial'}) {
		$current_locations = &subs::db_query('select * from continent where type=? and signatorial =? and warranty > ?','temporary',$data->{'signatorial'},&subs::rightNow())->hashes;
	} else {
		$current_locations = &subs::db_query('select * from continent where type=? and warranty > ?','temporary',&subs::rightNow())->hashes;
	}
	my $navigation_information = {};
	my $runs = 0;
	my $count = 0;
	foreach my $cl ( @{$current_locations} ) {
		$count++;
		my $cache = &subs::cache_get({ app => 'travel', context => 'navigation_information', subcontext => $cl->{'signatorial'} });
		next if $cache->{'timestamp'} + 5000 >= &subs::rightNow();
		$navigation_information->{$cl->{'signatorial'}}->{'__location'} = $cl;
		if (!$cache->{'__location'}) { $runs++; $runs++; next; }
		if (!$cache->{'__location'}->{'warranty'} || $cache->{'__location'}->{'warranty'} < &subs::rightNow()) { $runs++; $runs++; next; }
		my @old_location = (deg2rad($cache->{'__location'}->{'longitude'}), deg2rad(90 - $cache->{'__location'}->{'latitude'}));
		my @new_location = (deg2rad($cl->{'longitude'}), deg2rad(90 - $cl->{'latitude'}));
		my $distance = sprintf("%.3f", great_circle_distance(@old_location, @new_location, $gb::planet_radius));

		if ($distance < .020 || ($data->{'cache'} eq 'yes' && $cache->{'__location'}->{'latitude'}) ) {
			$navigation_information->{$cl->{'signatorial'}} = $cache;
			next;
		}
		elsif (!$cache->{'__location'}->{'latitude'}) {
#			&subs::headless_navigation();
			$runs++;$runs++;
		}
		$runs++;
	}

	if ($runs < $count && scalar @{$current_locations} > 0) {
		return $navigation_information;
	}
	elsif (scalar @{$current_locations} == 0 && $data->{'signatorial'}) {
		my $pset = &subs::settings_grabber({ app => '__president', settings => [ $data->{'signatorial'} . '_site_type', $data->{'signatorial'} . '_site_rating' ] });
		if ($pset->{$data->{'signatorial'} . '_site_type'}) {
			$navigation_information->{$data->{'signatorial'}}->{'site_type'} = $pset->{$data->{'signatorial'} . '_site_type'};
			$navigation_information->{$data->{'signatorial'}}->{'site_rating'} = $pset->{$data->{'signatorial'} . '_site_rating'};
			$navigation_information->{$data->{'signatorial'}}->{'site_source'} = 'manual';
		} else {
			$navigation_information->{$data->{'signatorial'}}->{'site_type'} = 'public';
			$navigation_information->{$data->{'signatorial'}}->{'site_rating'} = $gb::site_types->{'public'}->{'rating'};
			$navigation_information->{$data->{'signatorial'}}->{'site_source'} = 'lost';
		}
		return $navigation_information;
	}
	else {
		my $pset = {};
		my $hpds = &subs::db_query('select * from settings where setting=? and value is not null and value != ?', 'home_plate_duties', '[]')->hashes;
		foreach my $hpder ( @{$hpds} ) {
			my $home_plate = eval { return decode_json &subs::setting_grabber({ app => $hpder->{'app'}, setting => 'home_plate' }) || &subs::setting_grabber({ app => 'me', setting => 'home_plate' }) } || {};
			if ($home_plate->{'latitude'}) {
				my $hpd = eval { return decode_json $hpder->{'value'} } || [];
				foreach my $hp ( @{$hpd} ) {
					my $parent_app = $hpder->{'app'};
					my $app = $hp->{'self'} eq 'on' ? $hpder->{'app'} : $hp->{'app'};
					if (!$app && ($hp->{'self'} eq 'off' && !$hp->{'app'})) {
						next;
					}
					my @home_plate = (deg2rad($home_plate->{'longitude'}), deg2rad(90 - $home_plate->{'latitude'}));
					foreach my $returner ( @{$current_locations} ) {
						next if grep { $_ eq $returner->{'signatorial'}} @{$hp->{'signatorials'}};
						push @{$hp->{'signatorials'}}, $returner->{'signatorial'};

						$pset->{$returner->{'signatorial'}} = &subs::settings_grabber({ app => '__president', settings => [ $returner->{'signatorial'} . '_site_type', $returner->{'signatorial'} . '_site_rating' ] })
							unless $pset->{$returner->{'signatorial'}};

						my @visitor = (deg2rad($returner->{'longitude'}), deg2rad(90 - $returner->{'latitude'}));
						my $distance = sprintf("%.3f", great_circle_distance(@home_plate, @visitor, $gb::planet_radius));

						my $hset = &subs::settings_grabber({ app => $app, settings => [ 'warranty', 'toggle', 'site_type'] });
						my $tog = $hset->{'toggle'};
						my $ndata = {
							app => $app,
							distance => $distance,
							parent_app => $parent_app
					#		current_location => $returner,
					#		coordinates => $home_plate
						};
						if ($hp->{'placement'} eq 'within') {
							if ($distance <= $hp->{'distance'}) {
								push @{$navigation_information->{$returner->{'signatorial'}}->{'within'}}, $ndata;
								push @{$navigation_information->{$returner->{'signatorial'}}->{'site_types'}}, $hset->{'site_type'} || 'public';
							} else {
								push @{$navigation_information->{$returner->{'signatorial'}}->{'other'}}, $ndata;
							}
						}
						elsif ($hp->{'placement'} eq 'without') {
							if ($distance > $hp->{'distance'}) {
								push @{$navigation_information->{$returner->{'signatorial'}}->{'without'}}, $ndata;
							} else {
								push @{$navigation_information->{$returner->{'signatorial'}}->{'other'}}, $ndata;
							}
						}
						else {

							push @{$navigation_information->{$returner->{'signatorial'}}->{'other'}}, $ndata;

						}
						my $site_type = $navigation_information->{$returner->{'signatorial'}}->{'site_type'} || $gb::site_types->{'public'}->{'name'};
						my $site_rating = $navigation_information->{$returner->{'signatorial'}}->{'site_rating'} || $gb::site_types->{'public'}->{'rating'};
						my $types = $navigation_information->{$returner->{'signatorial'}}->{'site_types'};
						foreach my $t ( reverse sort { $gb::site_types->{$a}->{'rating'} <=> $gb::site_types->{$b}->{'rating'} } keys %{$gb::site_types} ) {
							if ( grep { $_ eq $t } @{$types} ) {
								$site_type = $t;
								$site_rating = $gb::site_types->{$t}->{'rating'};
								if ($site_rating >= 3) {
									last;
								}
							}
						}
						if ($pset->{$returner->{'signatorial'}}->{$returner->{'signatorial'} . '_site_type'}) {
							$navigation_information->{$returner->{'signatorial'}}->{'site_type'} = $pset->{$returner->{'signatorial'}}->{$returner->{'signatorial'} . '_site_type'};
							$navigation_information->{$returner->{'signatorial'}}->{'site_rating'} = $pset->{$returner->{'signatorial'}}->{$returner->{'signatorial'} . '_site_rating'};
							$navigation_information->{$returner->{'signatorial'}}->{'site_source'} = 'manual';
						} else {
							$navigation_information->{$returner->{'signatorial'}}->{'site_type'} = $site_type || 'public';
							$navigation_information->{$returner->{'signatorial'}}->{'site_rating'} = $site_rating || 0;
							$navigation_information->{$returner->{'signatorial'}}->{'site_source'} = 'navigation';
						}
					}
				}
			}
		}
		foreach my $sig ( keys %{$navigation_information} ) {
			$navigation_information->{'timestamp'} = &subs::rightNow();
			&subs::cache_set({ app => 'travel', context => 'navigation_information', subcontext => $sig, warranty => '-10m' }, $navigation_information->{$sig});
		}
		return $navigation_information;
	}
}

sub navigation_automation() {
	my $returner = shift;
	$returner->{'signatorial'} = &subs::signatorial_designer() unless $returner->{'signatorial'};
	my $signatorial = $returner->{'signatorial'};

	my $cache = &subs::cache_get({ app => '__president', context => 'navigation_automation', subcontext => $signatorial });
	return if $cache->{'timestamp'} + 5000 > &subs::rightNow();
	&subs::cache_set({ app => '__president', context => 'navigation_automation', subcontext => $signatorial }, { timestamp => &subs::rightNow() });


	my $device = &subs::device_setter();
	my $hpds = &subs::db_query('select * from settings where setting=? and value is not null and value != ?', 'home_plate_duties', '[]')->hashes;
	foreach my $hpder ( @{$hpds} ) {
		my $home_plate = eval { return decode_json &subs::setting_grabber({ app => $hpder->{'app'}, setting => 'home_plate' }) || &subs::setting_grabber({ app => 'me', setting => 'home_plate' }) } || {};
		if ($home_plate->{'latitude'}) {
			my $hpd = eval { return decode_json $hpder->{'value'} } || [];
			foreach my $hp ( @{$hpd} ) {
				if ($hp->{'device'} eq $signatorial || $hp->{'device'} eq $device) {
					my $app = $hp->{'self'} eq 'on' ? $hpder->{'app'} : $hp->{'app'};
					if (!$app && ($hp->{'self'} eq 'off' && !$hp->{'app'})) {
						next;
					}
					my @home_plate = (deg2rad($home_plate->{'longitude'}), deg2rad(90 - $home_plate->{'latitude'}));
					my @visitor = (deg2rad($returner->{'longitude'}), deg2rad(90 - $returner->{'latitude'}));
					my $distance = sprintf("%.3f", great_circle_distance(@home_plate, @visitor, $gb::planet_radius));
					my $actable = 0;
					my $cactable = 0;

					my $hset = &subs::settings_grabber({ app => $app, settings => [ 'warranty', 'toggle', 'site_type'] });
					my $tog = &subs::appt_toggle_checker($app) || $hset->{'toggle'};
					my $hpdata = {
						app => $app,
						timestamp => &subs::rightNow(),
						type => $hp->{'action'},
						subtype => 'navigation',
						uuid => &subs::random_string_creator(22)
					};
					if ($hp->{'placement'} eq 'within') {
						if ($distance <= $hp->{'distance'}) {
							if ($hset->{'site_type'} eq 'dangerous') {
							#	&Manager::leave();
							}
							elsif ($tog ne 'on') {
								my $lappts = &subs::db_query('select * from appointments where app = ? and subtype = ? and type = ? and stop_timestamp >= ?', $app, 'navigation', 'stop', &subs::rightNow() - 2000 * 60)->hashes;
								if (scalar @{$lappts} > 0) {
									foreach my $lapp ( @{$lappts} ) {
										$hpdata->{'uuid'} = $lapp->{'uuid'};
										# reopen the session it closed when the plate was left. stop_seen
										# must be cleared too: the stop resolvers (stop_target_row /
										# open_session_uuid) define the open session as one with stop_seen
										# null, so leaving it set left the row open but invisible - the
										# plate's own next leave and return then had nothing to close or
										# reopen (a "returning home" that never logged).
										&subs::db_update('appointments', {
											type => $hp->{'action'},
											stop_timestamp => undef,
											stop_seen => undef,
											server_time => &subs::rightNow(),
											duration => undef
										}, { app => $app, uuid => $lapp->{'uuid'} });
									}
									$actable = 0;
									$cactable = 1;
								} else {
									$actable = 1;
									$cactable = 1;
								}
							}
						}
						else {
							if ($tog eq 'on') {
								my $stoppable = 0;
								my $lappts = &subs::db_query('select uuid,app,type,subtype,timestamp,server_time from appointments where app=? and (type = ? or type =?) and timestamp < ?', $app, 'start','record',$returner->{'timestamp'})->hashes;
								foreach my $lappt ( @{$lappts} ) {
									# an appointment the navigation itself started was started
									# here, so leaving the plate closes it; a hand-started one
									# still needs a recorded in-plate fix before it is touched
									if ($lappt->{'subtype'} eq 'navigation') {
										$stoppable = 1;
										next;
									}
									my $locals = &subs::db_query('select * from continent where app=? and uuid like ? and signatorial=?', $app, $lappt->{'uuid'} . '%',$signatorial)->hashes;
									foreach my $local ( @{$locals} ) {
										my @visitor = (deg2rad($local->{'longitude'}), deg2rad(90 - $local->{'latitude'}));
										my $distance = sprintf("%.3f", great_circle_distance(@home_plate, @visitor, $gb::planet_radius));
										if ($distance <= $hp->{'distance'}) {
											$stoppable = 1;
										}
									}
								}
								if ($stoppable == 1) {
									$hpdata->{'type'} = 'stop';
									undef $hpdata->{'uuid'};
									$actable = 1;
									$cactable = 1;
								}
							}
						}
					}
					if ($hp->{'placement'} eq 'without') {
						if ($distance >= $hp->{'distance'}) {
							if ($tog ne 'on') {
								$actable = 1;
								$cactable = 1;
							}
						}
						else {
							if ($tog eq 'on') {
								my $stoppable = 0;
								my $lappts = &subs::db_query('select uuid,app,type,subtype,timestamp,server_time from appointments where app=? and (type = ? or type =?) and timestamp < ?', $app, 'start','record',$returner->{'timestamp'})->hashes;
								foreach my $lappt ( @{$lappts} ) {
									# an appointment the navigation itself started was started
									# here, so leaving the plate closes it; a hand-started one
									# still needs a recorded in-plate fix before it is touched
									if ($lappt->{'subtype'} eq 'navigation') {
										$stoppable = 1;
										next;
									}
									my $locals = &subs::db_query('select * from continent where app=? and uuid like ? and signatorial=?', $app, $lappt->{'uuid'} . '%',$signatorial)->hashes;
									foreach my $local ( @{$locals} ) {
										my @visitor = (deg2rad($local->{'longitude'}), deg2rad(90 - $local->{'latitude'}));
										my $distance = sprintf("%.3f", great_circle_distance(@home_plate, @visitor, $gb::planet_radius));
										if ($distance >= $hp->{'distance'}) {
											$stoppable = 1;
										}
									}
								}
								if ($stoppable == 1) {
									$hpdata->{'type'} = 'stop';
									undef $hpdata->{'uuid'};
									$actable = 1;
									$cactable = 1;
								}
							}
						}
					}

					if ($actable == 1) {
						&Manager::appointment_writer(undef, $hpdata);

					}
					if ($cactable == 1) {
						my $cdata = {
							timestamp => $returner->{'timestamp'},
							latitude => $returner->{'latitude'},
							longitude => $returner->{'longitude'},
							accuracy => sprintf("%.2F", $returner->{'accuracy'}),
							server_time => &subs::rightNow(),
							uuid => $hpdata->{'uuid'} . '-' . &subs::random_string_creator(8),
							type => 'app',
							app => $app,
							warranty => &subs::ago_calc($hset->{'warranty'}, &subs::rightNow()),
							signatorial => $signatorial
						};
						&subs::db_insert('continent', $cdata);
					}
				}
			}
		}
	}

	&subs::navigation_information();
}


# The hour of the day each app most often happens at, over the recent past, in
# one query for every app. The clothesline reads in the order the day does, so
# this gives it that order; it also names the apps whose routine is regular
# enough to hang themselves, and the hour to hang them at. `hour_days` is how
# many of the days the anchor hour was seen on, `days` how many days the app was
# seen at all.
sub clothesline_daily_hours() {
	my $days = 14;
	my $now = &rightNow();
	my $since = $now - ($days * 86400 * 1000);
	my $rows = &db_query('select app, timestamp from appointments where timestamp >= ? and timestamp <= ? and type in (?, ?)', $since, $now, 'usual', 'stop')->hashes;
	my (%hour_days, %app_days);
	foreach my $r ( @{$rows} ) {
		next unless $r->{'timestamp'};
		my $time = localtime($r->{'timestamp'} / 1000);
		my ($hour, $yday) = ($time->[2], $time->[7]);
		$hour_days{$r->{'app'}}->{$hour}->{$yday} = 1;
		$app_days{$r->{'app'}}->{$yday} = 1;
	}
	my $out = {};
	foreach my $app ( keys %hour_days ) {
		my ($best, $bestc) = (undef, -1);
		foreach my $h ( keys %{$hour_days{$app}} ) {
			my $c = scalar keys %{$hour_days{$app}->{$h}};
			if ($c > $bestc) { ($best, $bestc) = ($h, $c); }
		}
		$out->{$app} = { hour => $best, hour_days => $bestc, days => scalar keys %{$app_days{$app}} };
	}
	return $out;
}

sub hang_to_dry() {
	my $server_time = &rightNow();
	my $returner = [];

	my $time_plinkos = clone $gb::time_plinkos;
	my $cls = &db_query('select * from settings where setting = ? and device = ? and app!= ? and value is not null', 'clothesline', $device,'__president')->hashes;

	foreach my $clr ( @{$cls} ) {

		my $cl = eval { return decode_json $clr->{'value'} } || {};
		my $time = localtime($server_time / 1000);
		my $app = &unformat_name($clr->{'app'});
		my $settings = &settings_grabber({ app => $app });
		my $app_data = { name => $app, app => $app, formatted_name => &shorthand_name(&format_name($app),10), colour => $settings->{'colour'} };
		my $time_plinko = $cl->{'time_plinko'} || {};
		my @schedule = split ',', $cl->{'schedule'};
		foreach my $schedule ( @schedule ) {

		}
		my $count = scalar keys %{$cl->{'time_plinko'}};
		my $cl_count = 0;

		for (my $n = 0; $n <= 8; $n++) {
			my $ft = $time->[$n];
			if ($n == 2) {
				if ($ft == 0) {
					$ft = '12am';
				}
				elsif ($ft >= 12) {
					if ($ft == 12) { $ft = 24; }
					$ft = ($ft - 12) . 'pm';
				}
				elsif ($time->[$n] > 0 && $time->[$n] < 13) {
					$ft .= 'am';
				}
			}
			if ($n == 4) { $ft = $time->monname; }
			if ($n == 5) { $ft += 1900; }
			if ($n == 6) { $ft = $time->wdayname; }

			if ($time_plinko->{$time_plinkos->[$n]->{'name'}}) {

				if (grep { $_ eq $ft || $_ eq 'all' } @{$time_plinko->{$time_plinkos->[$n]->{'name'}}}) {
					$cl_count++;
					if ($cl_count == $count) {
						if ($settings->{'visible'} eq 'checked') {
							push @{$returner}, $app_data;
						}

					}
				}
			}
		}
		unless (grep { $_->{'app'} eq $app } @{$returner}) {
			my $running_appts = &db_query('select * from appointments where app = ? and (type = ? or type = ?)',$app, 'start','record')->hashes;
			if (scalar @{$running_appts} > 0) {
				push @{$returner}, $app_data;
			}
			foreach my $circumstance( keys %{$gb::budget_modes} ) {
				if ($cl->{$circumstance . '_budget'}) {
					my $budget = &subs::cache_get({ app => $app, context => 'budget', subcontext => $circumstance });
					if (grep { $budget->{'status'} eq $_ } @{$cl->{$circumstance . '_budget'}}) {
						push @{$returner}, $app_data unless grep { $_->{'app'} eq $app } @{$returner};
					}
				}
			}
		}



	}
	# The day's order, and the apps regular enough to hang themselves. An app the
	# user has never given a clothesline setting is offered at the hour its own
	# history keeps it, when that hour holds on most of the last fortnight and the
	# app is in its visible state. A setting of `off` in `clothesline_daily_auto`
	# turns the automatic hanging off; it is on when unset.
	my $daily = &clothesline_daily_hours();
	my $cur_time = localtime($server_time / 1000);
	my $cur_hour = $cur_time->[2];
	my %configured = map { &unformat_name($_->{'app'}) => 1 } @{$cls};
	# an app another app adds on its own - a default option, or a default model -
	# is not a thing the user clicks, so it never hangs itself (the coffee behind
	# the cream, the lunch behind its eggs). Their parent carries the routine.
	my $autos = &db_query(q{select distinct name from option where name is not null and name != app and lower(coalesce(def,'')) not in ('','off','false','0')
		union
		select distinct name from model where name is not null and name != app and lower(coalesce(def,'')) not in ('','off','false','0')})->hashes;
	my %auto_hung = map { $_->{'name'} => 1 } @{$autos};
	# the tasks an app carries: starting it records them as well, so they are not
	# clicks of the user's either (the flush and wash hands behind a pee or dump)
	my $task_rows = &db_query('select value from settings where setting = ? and value is not null', 'tasks')->hashes;
	foreach my $tr ( @{$task_rows} ) {
		my $list = eval { return decode_json $tr->{'value'} } || [];
		foreach my $t ( @{$list} ) {
			next unless $t->{'task'};
			$auto_hung{&unformat_name($t->{'task'})} = 1;
		}
	}
	# ...but a task or default the user also runs on their own is still theirs to
	# hang: a meaningful share of an app's own appointments carry no source (they
	# were not spawned by a parent). wash_hands is run by hand about half the time
	# and must stay; a flush that mostly follows a pee does not.
	my $auto_since = $server_time - (14 * 86400 * 1000);
	my $run_rows = &db_query(q{select app, count(*) total, sum(case when source_uuid is null or source_uuid = '' then 1 else 0 end) direct from appointments where type in ('usual','stop') and timestamp >= ? group by app}, $auto_since)->hashes;
	my %user_run;
	foreach my $r ( @{$run_rows} ) {
		next unless $r->{'total'};
		$user_run{$r->{'app'}} = 1 if ($r->{'direct'} / $r->{'total'}) >= 0.25;
	}
	my $auto = &setting_grabber({ app => '__president', setting => 'clothesline_daily_auto' });
	unless (defined $auto && lc($auto) eq 'off') {
		foreach my $app ( sort keys %{$daily} ) {
			next if $configured{$app};
			next if $auto_hung{$app} && !$user_run{$app};
			my $routine = $daily->{$app};
			next unless $routine->{'hour_days'} >= 7;
			next unless $routine->{'hour'} == $cur_hour;
			my $aset = &settings_grabber({ app => $app });
			next unless (($aset->{'visible'} || '') eq 'checked');
			push @{$returner}, { name => $app, app => $app, formatted_name => &shorthand_name(&format_name($app),10), colour => $aset->{'colour'} };
		}
	}
	# left to right, the order the day happens in; apps with no time of their own
	# (no history yet) fall to the end rather than shuffling those that have one
	@{$returner} = sort {
		my $ha = (defined $daily->{$a->{'app'}} && defined $daily->{$a->{'app'}}->{'hour'}) ? $daily->{$a->{'app'}}->{'hour'} : 24;
		my $hb = (defined $daily->{$b->{'app'}} && defined $daily->{$b->{'app'}}->{'hour'}) ? $daily->{$b->{'app'}}->{'hour'} : 24;
		$ha <=> $hb || $a->{'app'} cmp $b->{'app'};
	} @{$returner};
	&subs::subprocessor(sub {
		foreach my $clothes ( @{$returner} ) {
			&Manager::centre_view_grabber({ app => &subs::unformat_name($clothes->{'app'}), timestamp => &subs::rightNow() });
		}
	}, { name => 'clothesline centreview cacher' });
	my $jreturner = encode_json $returner;
	&setting_setter({ app => '__president', setting => 'clothesline', value => $jreturner });
	return 0;

}

# ---- web measures ----------------------------------------------------------
# A web measure used to be a CSS selector plus a count, applied to whatever the
# last fetch stored. That works until a page reorders, and it cannot say where
# a JSON value lives. One spec now covers both worlds:
#
#   JSON:  { "path": "properties.currentConditions.temperature.value.en" }
#   HTML:  { "selector": "#price", "count": 0, "attribute": "text" }
#          { "row": "tr", "match": "Gold", "within": "td" }
#
# with optional regex, fallback, number/unit/scale and the old prev/next
# context. The old selector/count specs keep working unchanged; a JSON id from
# the prettyfier is mapped back to its path, so weather's old selectors start
# reading the decoded JSON instead of the rendered DOM.
sub web_measure_clean_text {
	my ($s) = @_;
	return '' unless defined $s;
	$s =~ s/\x{00A0}/ /g;
	$s =~ s/\s+/ /g;
	$s =~ s/^\s+|\s+$//g;
	return $s;
}

sub web_measure_json_path {
	my ($json, $path) = @_;
	return undef unless defined $path && length $path;
	my $p = $path;
	$p =~ s/^\$//;
	$p =~ s/\[(\d+)\]/.$1/g;
	my @t = grep { length } split /\./, $p;
	my $node = $json;
	for my $t (@t) {
		if (ref $node eq 'HASH') {
			return undef unless exists $node->{$t};
			$node = $node->{$t};
		}
		elsif (ref $node eq 'ARRAY') {
			return undef unless $t =~ /^\d+$/ && $t < scalar @{$node};
			$node = $node->[$t];
		}
		else {
			return undef;
		}
	}
	return $node;
}

# The JSON prettyfier writes <span id="propertiescurrentConditions..."> by
# concatenating the keys (arrays become 1arr, 2arr...). Recover the real path
# from that id, so an old JSON selector keeps working and can be read as a
# path instead of through the rendered page.
sub web_measure_json_id_path {
	my ($json, $id) = @_;
	return undef unless defined $id && length $id;
	my $flat = sub { my $s = shift; $s =~ s/[^A-Za-z0-9]//g; return $s; };
	my $want = $flat->($id);
	my $walk;
	$walk = sub {
		my ($node, $parts, $idparts) = @_;
		if (ref $node eq 'HASH') {
			foreach my $k ( sort keys %{$node} ) {
				my $r = $walk->($node->{$k}, [@{$parts}, $k], [@{$idparts}, $k]);
				return $r if defined $r;
			}
		}
		elsif (ref $node eq 'ARRAY') {
			for my $i ( 0 .. $#{$node} ) {
				my $r = $walk->($node->[$i], [@{$parts}, $i], [@{$idparts}, ($i + 1) . 'arr']);
				return $r if defined $r;
			}
		}
		else {
			return join('.', @{$parts}) if $flat->(join '', @{$idparts}) eq $want;
		}
		return undef;
	};
	return $walk->($json, [], []);
}

# Every scalar path a JSON response offers, for the picker and the audit tool.
sub web_measure_json_paths {
	my ($json, $prefix, $out, $limit) = @_;
	$prefix = '' unless defined $prefix;
	$out = [] unless ref $out eq 'ARRAY';
	$limit ||= 4000;
	return $out if scalar @{$out} >= $limit;
	if (ref $json eq 'HASH') {
		foreach my $k ( sort keys %{$json} ) {
			my $p = length $prefix ? $prefix . '.' . $k : $k;
			&web_measure_json_paths($json->{$k}, $p, $out, $limit);
		}
	}
	elsif (ref $json eq 'ARRAY') {
		for my $i ( 0 .. $#{$json} ) {
			my $p = (length $prefix ? $prefix : '') . '[' . $i . ']';
			&web_measure_json_paths($json->[$i], $p, $out, $limit);
		}
	}
	else {
		push @{$out}, { path => $prefix, value => $json };
	}
	return $out;
}

# One number parser for every source. Currency, percent, a degree sign and a
# unit suffix are stripped; a comma decimal and a thousands separator are read
# by position; a leading minus (or parentheses) is kept. appt_measure_writer
# used to strip everything but digits and dots, which quietly turned -0.5 into
# 0.5.
sub web_measure_number {
	my ($raw, $spec) = @_;
	$spec ||= {};
	return undef unless defined $raw;
	my $s = &web_measure_clean_text($raw);
	return undef unless length $s;
	my $neg = 0;
	if ($s =~ /^\((.*)\)\s*$/) { $neg = 1; $s = $1; }
	my ($token) = $s =~ /([+\-]?(?:\d[\d.,']*|\.\d+)(?:[eE][+\-]?\d+)?)/;
	return undef unless defined $token;
	$token =~ s/['\s]//g;
	my $sign = 1;
	if ($token =~ s/^-//) { $sign = -1; }
	$token =~ s/^\+//;
	my $dec = $spec->{'decimal'};
	my $thou = $spec->{'thousands'};
	if (!defined $dec || !length $dec) {
		my $last_comma = rindex($token, ',');
		my $last_dot = rindex($token, '.');
		if ($last_comma >= 0 && $last_dot >= 0) {
			if ($last_comma > $last_dot) { $dec = ','; $thou = '.'; }
			else { $dec = '.'; $thou = ','; }
		}
		elsif ($last_comma >= 0) {
			my @c = split /,/, $token;
			if (scalar @c == 2 && length($c[1]) && length($c[1]) <= 2) { $dec = ','; $thou = ''; }
			else { $dec = '.'; $thou = ','; }
		}
		else { $dec = '.'; $thou = ''; }
	}
	if ($thou) { $token =~ s/\Q$thou\E//g; }
	if ($dec ne '.') { $token =~ s/\Q$dec\E/./g; }
	return undef unless $token =~ /^\d*(?:\.\d*)?$/ && $token =~ /\d/;
	my $n = $token + 0;
	$n = -$n if $neg || $sign < 0;
	my $scale = $spec->{'scale'};
	$n *= $scale if defined $scale && $scale =~ /^-?\d+(?:\.\d+)?$/;
	if (defined $spec->{'decimals'} && $spec->{'decimals'} =~ /^\d+$/) {
		return sprintf('%.' . $spec->{'decimals'} . 'f', $n);
	}
	# Keep the precision the page wrote. A fixed %.10f rounds 149,095,031.14
	# through a float and prints 149095031.1399999857.
	my $dp = ($token =~ /\.(\d+)$/) ? length($1) : 0;
	$dp = 10 if $dp > 10;
	my $out = sprintf('%.' . $dp . 'f', $n);
	$out =~ s/0+$// if $out =~ /\./;
	$out =~ s/\.$//;
	return $out;
}

# Some pages write a label as bare text, with the value in the next element:
#   Phase: <span>Waxing Crescent</span><br>
# Mojo::DOM drops text nodes from children(), so match the label in the
# container's own markup and return the first element that follows it.
sub web_measure_after_text_label {
	my ($dom, $container, $label, $skip) = @_;
	return undef unless $dom && defined $container && length $container && defined $label && length $label;
	my $box = $dom->at($container) or return undef;
	my $html = $box->to_string;
	my $needle = lc $label;
	my $pos = -1;
	for (my $i = 0; $i <= ($skip || 0); $i++) {
		$pos = index(lc($html), $needle, $pos + 1);
		return undef if $pos < 0;
	}
	my $cursor = 0;
	foreach my $child ( @{$box->children} ) {
		next unless $child->type eq 'tag';
		my $markup = $child->to_string;
		my $at = index($html, $markup, $cursor);
		next unless $at >= 0;
		$cursor = $at + length $markup;
		next unless $at > $pos;
		my $tag = lc($child->tag || '');
		next if $tag eq 'br' || $tag eq 'hr' || $tag eq 'wbr';
		return $child;
	}
	return undef;
}

# Extract one value from a fetched page. $ctx is { format, json, dom, raw }.
sub web_measure_extract {
	my ($spec, $ctx) = @_;
	$spec ||= {};
	$ctx ||= {};
	require Mojo::DOM;
	require Mojo::Collection;
	my $result = { ok => 0, value => undef, raw => undef, used => '', error => '' };
	my $json = $ctx->{'json'};
	my $dom = $ctx->{'dom'};
	my $raw_value;
	my $used = '';
	my $attr = $spec->{'attribute'} || 'text';

	# 1. an explicit JSON path
	if (ref $json && defined $spec->{'path'} && length $spec->{'path'}) {
		my $v = &web_measure_json_path($json, $spec->{'path'});
		if (defined $v && !ref $v) { $raw_value = $v; $used = 'path'; }
		else { $result->{'error'} = 'JSON path not found'; }
	}

	# 2. an old JSON id selector, mapped back to a path
	if (!defined $raw_value && ref $json && defined $spec->{'selector'} && $spec->{'selector'} =~ /^\s*\[id\s*=\s*["']?([^"'\]]+)["']?\]\s*$/i) {
		my $id = $1;
		my $path = &web_measure_json_id_path($json, $id);
		if (defined $path) {
			my $v = &web_measure_json_path($json, $path);
			if (defined $v && !ref $v) {
				$raw_value = $v;
				$used = 'path (from id)';
				$result->{'path'} = $path;
			}
		}
	}

	# 3. label then value: the label's own next cell/sibling, or a selector
	# inside the label's row. This survives a reordered page where a global
	# count does not.
	if (!defined $raw_value && $dom && defined $spec->{'label'} && length $spec->{'label'}) {
		my $want = $spec->{'label'};
		my $match_label = sub {
			my $t = &web_measure_clean_text(shift);
			return 0 unless length $t && length $t <= 200;
			if ($want =~ m{^/(.*)/([i]?)$}) { return $t =~ /$1/i ? 1 : 0; }
			return index(lc($t), lc($want)) >= 0 ? 1 : 0;
		};
		my $scope = $dom;
		if (defined $spec->{'container'} && length $spec->{'container'}) {
			my $box = $dom->at($spec->{'container'});
			$scope = $box if $box;
		}
		# all_text, not text: text only returns an element's own text, so a
		# <td><a>Silver</a></td> or <dd><span>2.4</span></dd> would look empty.
		my @labels = $scope->find('td, th, dt, dd, b, strong, span, div, label, h1, h2, h3, h4, h5, h6, p')->each;
		my @picked = grep { $match_label->($_->all_text) } @labels;
		# the tightest match wins: a <dt>Condition:</dt> is the label, not the
		# <dl> that contains it and its value
		@picked = sort { length($a->all_text) <=> length($b->all_text) } @picked;
		my $label_node = $picked[ $spec->{'label_count'} || 0 ];
		my $node;
		if ($label_node) {
			my $value = $spec->{'value'};
			if (defined $value && $value eq 'parent_next') {
				my $p = $label_node->parent;
				$node = $p ? $p->next : undef;
			}
			elsif (defined $value && $value eq 'next') {
				$node = $label_node->next;
			}
			elsif (defined $spec->{'value_selector'} && length $spec->{'value_selector'}) {
				my $scope = $label_node->parent;
				if (defined $spec->{'row'} && length $spec->{'row'}) {
					my $r = $label_node->ancestors($spec->{'row'})->[0];
					$scope = $r if $r;
				}
				my $nodes = $scope ? $scope->find($spec->{'value_selector'}) : Mojo::Collection->new;
				$node = $nodes->[ $spec->{'count'} || 0 ];
			}
			else {
				# a bare label means "the cell or sibling beside it"
				$node = $label_node->next;
			}
		}
		elsif (defined $spec->{'container'} && length $spec->{'container'}) {
			# a label written as bare text (moongiant: "Moon Angle: <span>0.49</span>")
			# has no element to match; walk the container's children instead.
			$node = &web_measure_after_text_label($dom, $spec->{'container'}, $want, $spec->{'label_count'} || 0);
		}
		if ($node) {
			$raw_value = ($attr ne 'text') ? $node->attr($attr) : $node->all_text;
			$used = 'label';
		}
	}

	# 4. HTML row + label + cell (the stable way to read a table)
	if (!defined $raw_value && $dom && defined $spec->{'row'} && length $spec->{'row'}) {
		my @rows = $dom->find($spec->{'row'})->each;
		my @cand;
		my $match = $spec->{'match'};
		foreach my $row (@rows) {
			my $t = &web_measure_clean_text($row->all_text);
			if (defined $match && length $match) {
				if ($match =~ m{^/(.*)/([i]?)$}) { next unless $t =~ /$1/i; }
				else { next unless index(lc($t), lc($match)) >= 0; }
			}
			if (defined $spec->{'contains'} && length $spec->{'contains'}) {
				next unless index(lc($t), lc($spec->{'contains'})) >= 0;
			}
			push @cand, $row;
		}
		my $row = $cand[ $spec->{'row_count'} || 0 ];
		if ($row) {
			my $nodes = (defined $spec->{'within'} && length $spec->{'within'})
				? $row->find($spec->{'within'})
				: Mojo::Collection->new($row);
			my $node = $nodes->[ $spec->{'count'} || 0 ];
			if ($node) {
				$raw_value = ($attr ne 'text') ? $node->attr($attr) : $node->all_text;
				$used = 'row';
			}
		}
	}

	# 5. the classic CSS selector + count. An [id="…"] selector is a JSON id
	# only when there is JSON to read; on an HTML page it is a real selector
	# (tradingeconomics puts prices in <td id="p">).
	if (!defined $raw_value && $dom && defined $spec->{'selector'} && length $spec->{'selector'} && ($spec->{'selector'} !~ /^\s*\[id\s*=/i || !ref $json)) {
		my @nodes = $dom->find($spec->{'selector'})->each;
		if (defined $spec->{'contains'} && length $spec->{'contains'}) {
			@nodes = grep { index(lc(&web_measure_clean_text($_->all_text)), lc($spec->{'contains'})) >= 0 } @nodes;
		}
		my $node;
		if ((defined $spec->{'prev'} && length $spec->{'prev'}) || (defined $spec->{'next'} && length $spec->{'next'})) {
			foreach my $n ( @nodes ) {
				my $p = $n->previous;
				my $q = $n->next;
				my $okp = !defined $spec->{'prev'} || !length $spec->{'prev'} || ($p && index(lc(&web_measure_clean_text($p->all_text)), lc($spec->{'prev'})) >= 0);
				my $okq = !defined $spec->{'next'} || !length $spec->{'next'} || ($q && index(lc(&web_measure_clean_text($q->all_text)), lc($spec->{'next'})) >= 0);
				if ($okp && $okq) { $node = $n; last; }
			}
		}
		$node ||= $nodes[ $spec->{'count'} || 0 ];
		if ($node) {
			$raw_value = ($attr ne 'text') ? $node->attr($attr) : $node->all_text;
			$used = 'selector';
		}
	}

	# 6. named fallbacks
	if (!defined $raw_value && ref $spec->{'fallback'} eq 'ARRAY') {
		foreach my $f ( @{$spec->{'fallback'}} ) {
			next unless ref $f eq 'HASH';
			my $r = &web_measure_extract($f, $ctx);
			return $r if $r->{'ok'};
		}
	}

	unless (defined $raw_value) {
		$result->{'error'} ||= 'no element matched';
		return $result;
	}

	if (defined $spec->{'regex'} && length $spec->{'regex'}) {
		my $re = $spec->{'regex'};
		if ($re =~ m{^/(.*)/([i]?)$}) { $re = $1; }
		if ($raw_value =~ /$re/) { $raw_value = defined $1 ? $1 : $&; }
		else { $result->{'error'} = 'regex did not match'; return $result; }
	}

	$raw_value = &web_measure_clean_text($raw_value);
	if ($spec->{'number'}) {
		my $n = &web_measure_number($raw_value, $spec);
		return { %{$result}, error => 'not a number' } unless defined $n;
		$raw_value = $n;
	}
	return { ok => 1, value => $raw_value, raw => $raw_value, used => $used, error => '', path => $result->{'path'} };
}

# Suggest working specs for a label on this page. The useful shape for a table
# is "the row that contains Gold, cell N", where N is the first cell *after*
# the label. Every candidate is tested against the page before it is offered,
# so a suggestion is a value the extractor will really read.
sub web_measure_suggest {
	my ($ctx, $label) = @_;
	my $dom = $ctx->{'dom'};
	return [] unless $dom && defined $label && length $label;
	my @out;
	my $seen;
	my $add = sub {
		my ($spec, $value) = @_;
		my $key = join '|', map { $_ . '=' . (defined $spec->{$_} ? $spec->{$_} : '') } sort keys %{$spec};
		return if $seen->{$key}++;
		push @out, { spec => $spec, value => $value };
	};
	my $test = sub {
		my ($spec) = @_;
		my $r = &web_measure_extract($spec, $ctx);
		return undef unless $r->{'ok'} && defined $r->{'value'} && length $r->{'value'};
		return &web_measure_clean_text($r->{'value'});
	};

	# the row that holds the label, then the cells after the label's own cell
	my @rows = grep {
		index(lc(&web_measure_clean_text($_->all_text)), lc($label)) >= 0
	} $dom->find('tr')->each;
	foreach my $row ( @rows ) {
		my @cells = $row->find('td, th')->each;
		my $label_idx = -1;
		for my $i ( 0 .. $#cells ) {
			if (index(lc(&web_measure_clean_text($cells[$i]->all_text)), lc($label)) >= 0) { $label_idx = $i; last; }
		}
		next if $label_idx < 0;
		for my $j ( $label_idx + 1 .. $#cells ) {
			my $txt = &web_measure_clean_text($cells[$j]->all_text);
			next unless length $txt;
			my $spec = { row => 'tr', match => $label, within => 'td, th', count => $j };
			my $v = $test->($spec);
			$add->($spec, $v) if defined $v;
		}
		foreach my $sel ( '[data-testid="change"]', '.price', '.value', 'span', 'b', 'strong' ) {
			my $spec = { row => 'tr', match => $label, within => $sel, count => 0 };
			my $v = $test->($spec);
			$add->($spec, $v) if defined $v;
		}
		last if scalar @out >= 4;
	}

	# definition-list / label-and-next shapes
	foreach my $spec ( { label => $label, value => 'next' }, { label => $label, value => 'parent_next' } ) {
		my $v = $test->($spec);
		$add->($spec, $v) if defined $v;
	}

	# a label written as bare text inside a container that has an id
	# (moongiant: "Moon Angle: <span>0.49</span>")
	my $scanned = 0;
	foreach my $box ( $dom->find('[id]')->each ) {
		last if scalar @out >= 4 || $scanned++ >= 200;
		my $kids = $box->children;
		next if scalar @{$kids} > 100;
		my $html = $box->to_string;
		foreach my $child ( @{$kids} ) {
			next unless $child->type eq 'tag';
			next if ($child->tag || '') =~ /^(?:br|hr|wbr)$/i;
			my $markup = $child->to_string;
			my $at = index($html, $markup);
			next if $at <= 0;
			my ($tail) = substr($html, 0, $at) =~ /([^<>]*)$/;
			$tail = &web_measure_clean_text($tail);
			next unless $tail =~ /([A-Za-z][A-Za-z0-9 .\/#%()+_-]{0,40}:)\s*$/;
			my $near = $1;
			next unless index(lc($near), lc($label)) >= 0;
			my $spec = { container => '#' . $box->attr('id'), label => $near };
			my $v = $test->($spec);
			$add->($spec, $v) if defined $v;
			last if scalar @out >= 4;
		}
	}
	return \@out;
}

# Build the specs a person can choose after clicking a value in the web view:
# a JSON path, a table row, a label/value pair, or - last - the old CSS
# selector + count. Every candidate is run through the extractor, so the list
# only contains shapes that really read this page.
sub web_measure_candidates {
	my ($dom, $json, $selector, $index) = @_;
	return [] unless $dom;
	$index = 0 unless defined $index && $index =~ /^\d+$/;
	my $ctx = { dom => $dom, json => $json, format => (ref $json ? 'json' : 'html') };
	my @out;
	my %seen;
	my $add = sub {
		my ($kind, $spec) = @_;
		return unless ref $spec eq 'HASH';
		my $r = &web_measure_extract($spec, $ctx);
		return unless $r->{'ok'} && defined $r->{'value'} && length $r->{'value'};
		my $key = encode_json($spec);
		return if $seen{$key}++;
		push @out, { kind => $kind, spec => $spec, value => &web_measure_clean_text($r->{'value'}) };
	};

	my @found;
	if (defined $selector && length $selector) {
		my $nodes = eval { $dom->find($selector) };
		@found = $nodes ? $nodes->each : ();
	}
	my $el = $found[$index] || $found[0];

	# 1. the JSON prettyfier puts the concatenated keys in the value span's id
	if (ref $json && $el) {
		my $id = $el->attr('id');
		unless (defined $id && length $id) {
			my $span = $el->ancestors('span[id]')->[0];
			$id = $span->attr('id') if $span;
		}
		if (defined $id && length $id) {
			my $path = &web_measure_json_id_path($json, $id);
			$add->('JSON path', { path => $path }) if defined $path && length $path;
		}
	}

	# 2. the table row and the cell inside it
	my $row = $el ? ($el->tag eq 'tr' ? $el : $el->ancestors('tr')->[0]) : undef;
	my $cell = $el;
	while ($cell && ($cell->tag || '') !~ /^(?:td|th)$/i) { $cell = $cell->parent; }
	if ($row && $cell) {
		my @cells = $row->find('td, th')->each;
		my $cell_index = 0;
		my $s = $cell->previous;
		while ($s) {
			$cell_index++ if $s->type eq 'tag' && ($s->tag || '') =~ /^(?:td|th)$/i;
			$s = $s->previous;
		}
		my $label = @cells ? &web_measure_clean_text($cells[0]->all_text) : '';
		$label = substr($label, 0, 80);
		if (length $label && $label !~ /^[\d.,+\-%\s]+$/) {
			my $row_count = 0;
			foreach my $r ( $dom->find($row->tag)->each ) {
				last if $r->to_string eq $row->to_string;
				$row_count++ if index(lc(&web_measure_clean_text($r->all_text)), lc($label)) >= 0;
			}
			my $tag = $cell->tag;
			my $within = $tag;
			my $count = 0;
			if (my $testid = $cell->attr('data-testid-cell')) {
				$within = $tag . '[data-testid-cell="' . $testid . '"]';
			}
			elsif (my $cid = $cell->attr('id')) {
				$within = $tag . '[id="' . $cid . '"]';
			}
			else {
				$within = 'td, th';
				$count = $cell_index;
			}
			my $spec = { row => $row->tag, match => $label, within => $within, count => $count };
			$spec->{'row_count'} = $row_count if $row_count;
			$add->('table row', $spec);
			$add->('table row', { row => $row->tag, match => $label, within => 'td, th', count => $cell_index }) if $within ne 'td, th';
		}
	}

	# 3. a definition list: <dt>Label:</dt><dd>value</dd>
	if ($el) {
		my $dd = $el;
		while ($dd && ($dd->tag || '') ne 'dd') { $dd = $dd->parent; }
		if ($dd) {
			my $dt = $dd->previous;
			if ($dt && ($dt->tag || '') eq 'dt') {
				my $label = &web_measure_clean_text($dt->all_text);
				$add->('label', { label => $label, value => 'next' }) if length $label;
			}
		}
	}

	# 4. a label written as bare text in a container that has an id
	if ($el && $el->parent) {
		my $parent = $el->parent;
		my $cid = $parent->attr('id');
		if (defined $cid && length $cid) {
			my $html = $parent->to_string;
			my $markup = $el->to_string;
			my $at = index($html, $markup);
			if ($at > 0) {
				my $before = substr($html, 0, $at);
				my ($tail) = $before =~ /([^<>]*)$/;
				$tail = &web_measure_clean_text($tail);
				if ($tail =~ /([A-Za-z][A-Za-z0-9 .\/#%()+_-]{0,40}:?)\s*$/) {
					my $label = $1;
					$add->('label', { container => '#' . $cid, label => $label });
				}
			}
		}
	}

	# 5. the old selector + count, always available as a fallback
	if (defined $selector && length $selector) {
		$add->('selector', { selector => $selector, count => $index });
	}

	return \@out;
}

# app/setting rows, with the local device preferred but a row stored on another
# device still visible. A web measure is an app fact, not a device fact: the
# phone can be the headless browser and still use the selectors configured on
# the computer. Dedupe by $by when a setting has one row per subsetting.
sub setting_rows_for {
	my ($app, $setting, $by) = @_;
	my $dev = &device_setter();
	my $sig = &signatorial_designer();
	my $rows = &db_query(q{
		select * from settings
		where app = ? and setting = ?
		order by case when device = ? or device = ? or device = 'all' or device is null then 0 else 1 end,
		         cast(server_time as integer) desc
	}, $app, $setting, $dev, $sig)->hashes || [];
	if ($by) {
		my %seen;
		@{$rows} = grep { !$seen{ defined $_->{$by} ? $_->{$by} : '' }++ } @{$rows};
	}
	return $rows;
}

sub setting_value_for {
	my ($app, $setting) = @_;
	my $rows = &setting_rows_for($app, $setting);
	return $rows->[0] ? $rows->[0]->{'value'} : undef;
}

sub headless_browser() {
	my $changes = 0;
	my $signatorial = &subs::signatorial_designer();
	# A web measure is an app fact, not a device fact. Read the recurrence and
	# URL regardless of the device that configured them; the local row wins when
	# there is more than one. This is what lets the phone be the headless browser
	# while the selectors remain on the computer.
	my $apps = &subs::db_query(q{select distinct app from settings where setting = ? and app is not null and value is not null and value != ?}, 'web_recurring', '')->hashes || [];
	foreach my $a ( @{$apps} ) {
		my $app = $a->{'app'};
		next unless defined $app && length $app;
		my $rw = &subs::setting_rows_for($app, 'web_recurring')->[0] or next;
		my $able_devices = [ grep {
			my $v = defined $_->{'value'} ? $_->{'value'} : '';
			$v eq $device || $v eq $signatorial || $v eq 'all';
		} @{ &subs::setting_rows_for($app, 'web_headless_device') } ];
		next unless scalar @{$able_devices};
		my %seen_url;
		foreach my $w ( @{ &subs::setting_rows_for($app, 'web') } ) {
			my $url = $w->{'value'};
			next unless defined $url && length $url;
			next if $seen_url{$url}++;
			my $history = &subs::db_query('select * from websites where app=? and url=? order by timestamp desc', $app, $url)->hashes;
			my $last_run = $history->[0] ? $history->[0]->{'timestamp'} : 0;
			my $recurrence = &time_abbrev_translator($rw->{'value'}) || '1M';
			next unless &subs::rightNow() - $last_run > $recurrence;
			my ($window,$internal_url,$uuid,$timestamp) = &Manager::website_grabber({
				app => $app,
				website => $url,
				timestamp => &subs::rightNow(),
				user_agent => $gb::user_agent,
			});
			$changes = 1;
		}
	}
	if ($changes == 1) {
		my $c = &subs::controller_builder();
		my $update = $c->render_to_string(
			template => 'web',
			app => ''
		);
		&Websocket::send('tab', { type => 'replaceWith', selector => '#web', content => $update });


	}
}

sub telephone_contacts_check() {

	return 0 unless $device eq 'mobile';

	my $n = 0;
	my $jcontacts = `termux-contact-list`;
	my $contacts = eval { return decode_json $jcontacts } || [];
	foreach my $contact ( @{$contacts} ) {
		my $name = &subs::unformat_name($contact->{'name'});
		my $number = $contact->{'number'};
		$number =~ s/\D+//gi;

		next unless $number;

		my $phones = &subs::settings_grabber({ app => $name, settings => ['phone', 'phones', 'uuid' ] });

		# only a person the house already knows: a contact never mints an app
		next unless $phones->{'uuid'};
		next if &subs::contact_matches('phone', $phones->{'phone'}, $number);

		# another number for somebody whose line is already set is another line on
		# them, not a replacement: the phone row keeps what call and text route on,
		# and the typed list holds the rest (mobile, home, work, a custom label).
		if (!$phones->{'phone'}) {
			&subs::setting_setter({ app => $name, setting => 'phone', value => $number });
			$n++;
			next;
		}
		my $list = eval { return decode_json $phones->{'phones'} } || [];
		$list = [ $list ] if ref $list eq 'HASH';
		$list = [] unless ref $list eq 'ARRAY';
		next if grep { ref $_ eq 'HASH' && &subs::contact_matches('phone', $_->{'value'}, $number) } @{$list};
		push @{$list}, {
			uuid => &subs::random_string_creator(20),
			type => 'mobile',
			label => '',
			value => $number
		};
		&subs::setting_setter({ app => $name, setting => 'phones', value => encode_json $list });
		$n++;
	}
	return $n;
}

# The contacts of one kind a person keeps: the plain setting (phone/email) and
# the typed list beside it (phones/emails, rows of {type,label,value}). Comparison
# tidies the way the rest of the code does - a phone to its digits (a leading 1
# dropped) so a country code or spacing never hides a match, an email lowered.
sub contact_normalizer {
	my ($kind, $value) = @_;
	return '' unless defined $value && length $value;
	if ($kind eq 'phone') {
		my $n = $value;
		$n =~ s/\D+//g;
		$n =~ s/^1//;
		return $n;
	}
	my $e = lc $value;
	$e =~ s/^\s+//;
	$e =~ s/\s+$//;
	return $e;
}

sub contact_matches {
	my ($kind, $a, $b) = @_;
	my $x = &subs::contact_normalizer($kind, $a);
	my $y = &subs::contact_normalizer($kind, $b);
	return 0 unless length $x && length $y;
	if ($kind eq 'phone') {
		$x = substr $x, -10 if length $x >= 10;
		$y = substr $y, -10 if length $y >= 10;
	}
	return $x eq $y ? 1 : 0;
}

# Every app whose records hold this phone or email: the plain setting first
# (phone/email), then the typed list (phones/emails). A match is the address, so
# the two are scanned the same way - a number kept as somebody's work line names
# them as surely as the one on the app.
sub contact_apps {
	my ($kind, $value) = @_;
	return () unless defined $value && length $value;
	my (%seen, @apps);
	my $plain = &subs::db_query('select app, value from settings where setting=? and value != ?', $kind, '')->hashes;
	foreach my $r ( @{$plain} ) {
		next unless &subs::contact_matches($kind, $r->{'value'}, $value);
		push @apps, $r->{'app'} unless $seen{ $r->{'app'} }++;
	}
	my $rows = &subs::db_query('select app, value from settings where setting=? and value != ?', $kind . 's', '')->hashes;
	foreach my $r ( @{$rows} ) {
		my $list = eval { return decode_json $r->{'value'} } || [];
		$list = [ $list ] if ref $list eq 'HASH';
		next unless ref $list eq 'ARRAY';
		foreach my $c ( @{$list} ) {
			next unless ref $c eq 'HASH';
			next unless &subs::contact_matches($kind, $c->{'value'}, $value);
			push @apps, $r->{'app'} unless $seen{ $r->{'app'} }++;
		}
	}
	return @apps;
}

# Every line the house holds of one kind, one app's under it: the plain setting
# (phone/email) first and marked primary, then the typed list (phones/emails) with
# its type and label. A person with a home and a work line is one entry with all
# of them, not one per number - which is what the Phone app's directory and
# Chat's friends both want. Pass $only_app to read just one person's lines.
sub contact_lines {
	my ($kind, $only_app) = @_;
	my $mine = (defined $only_app && length $only_app) ? $only_app : undef;
	my %lines;
	my $plain = &subs::db_query('select app, value, server_time from settings where setting=? and value != ? order by server_time desc', $kind, '')->hashes;
	foreach my $r ( @{$plain} ) {
		my $app = $r->{'app'};
		next if $mine && $app ne $mine;
		next if exists $lines{$app};
		my $v = $r->{'value'};
		next unless defined $v && length $v;
		$lines{$app} = [ { value => $v, type => '', label => '', primary => 1 } ];
	}
	my $lists = &subs::db_query('select app, value from settings where setting=? and value != ?', $kind . 's', '')->hashes;
	foreach my $r ( @{$lists} ) {
		my $app = $r->{'app'};
		next if $mine && $app ne $mine;
		my $list = eval { return decode_json $r->{'value'} } || [];
		$list = [ $list ] if ref $list eq 'HASH';
		next unless ref $list eq 'ARRAY';
		$lines{$app} ||= [];
		my %seen = map { &subs::contact_normalizer($kind, $_->{'value'}) => 1 } @{ $lines{$app} };
		foreach my $c ( @{$list} ) {
			next unless ref $c eq 'HASH';
			my $v = $c->{'value'};
			next unless defined $v && length $v;
			my $key = &subs::contact_normalizer($kind, $v);
			next if $key && $seen{$key}++;
			push @{ $lines{$app} }, { value => $v, type => ($c->{'type'} || ''), label => ($c->{'label'} || ''), primary => 0 };
		}
	}
	return \%lines;
}

# How one line reads in a list: the number or address, and - for a line beyond
# the first - its type in front of it (a custom entry wears its own label). A
# blocked line says so.
sub contact_line_label {
	my $l = shift;
	my $text = $l->{'value'};
	my $type = $l->{'type'} || '';
	my $label = $l->{'label'} || '';
	my $name = ($type eq 'custom' && length $label) ? $label : $type;
	$text = $name . ' ' . $text if length $name && !$l->{'primary'};
	$text .= ' (blocked)' if $l->{'blocked'};
	return $text;
}

# The app a number belongs to: the person who saved it, or - when the house
# does not know the number - the number itself, filed as an app of its own so
# a stranger's calls and texts still land somewhere, and naming that app later
# turns the stranger into a person. The phone row is made at the same time, so
# the next call or text from the same number resolves the same way. Matching is
# on the last ten digits of both sides, the way the call-log check learned to,
# and covers the typed list as well as the plain phone row.
sub phone_number_app {
	my $number = shift;
	$number =~ s/\D+//g;
	$number =~ s/^1//;
	return '' unless $number;
	my @known = &subs::contact_apps('phone', $number);
	return $known[0] if scalar @known;
	# unknown: the number becomes the app, and the row makes it known
	&subs::setting_setter({ app => $number, setting => 'phone', value => $number });
	return $number;
}

sub telephone_call_log_check() {

	return 0 unless $device eq 'mobile';

	my $n = 0;
	my $call_logs = `termux-call-log -l 30`;
	my $calls = eval { return decode_json $call_logs } || [];

	foreach my $call ( grep { $_->{'phone_number'} =~ /\d/ } @{$calls} ) {
		my $name = &subs::unformat_name($call->{'name'});
		my $number = $call->{'phone_number'};
		$number =~ s/\D+//gi;
		my $timestamp = &subs::ago_calc($call->{'date'},&subs::rightNow());

		my @duration = split /:/, $call->{'duration'};


		my $duration = '';
		if (scalar @duration == 3) {
			$duration .= $duration[0] . 'h ';
			$duration .= $duration[1] . 'm ';
			$duration .= $duration[2] . 's';
		}
		else {
			$duration .= $duration[0] . 'm ';
			$duration .= $duration[1] . 's';
		}
		$duration = &subs::time_abbrev_translator($duration);


		# the log carries the number in whatever shape the carrier sent it (+1…,
		# bare digits, sometimes with the country code) while the house keeps its
		# contacts as they were typed (519-849-5604, 2263493283, the odd +1…).
		# Match on the last ten digits of both: a raw substring test meant a
		# contact stored without the country code (or with dashes) never met its
		# own call - which is why a working termux-call-log still filed nothing.
		# (the matching itself lives in phone_number_app)
		# an unknown caller is still a call: file it on the number's own app
		# (the number becomes the app), rather than dropping it on the floor
		my $app = &subs::phone_number_app($number) || 'phone';

		# the live phone app may already have written this call as it happened
		# (window.JawnPhoneEvent): skip it so a live call and its call-log trail
		# are one appointment, not two
		my $live = &subs::db_query('select uuid from appointments where subtype=? and timestamp between ? and ? limit 1', 'phone', $timestamp - 180000, $timestamp + 180000)->hashes;
		next if scalar @{$live} > 0;

		my $appts = &subs::db_query('select * from appointments where app=? and timestamp = ?', $app, $timestamp)->hashes;
		unless (scalar @{$appts} > 0) {
			my $data = {
				app => $app,
				type => 'start',
				duration => '-' . $duration,
				timestamp => $timestamp,
				stop_timestamp => ($timestamp + $duration),
				seen => 'yes',
				subtype => 'phone'
			};

			my $c = &subs::controller_builder();
			&Manager::appointment_writer($c,$data);
			$n++;
		}
	}
	return $n;
}

sub appt_toggle_checker() {
	my $app = shift;
	return unless $app;
	my $server_time = &subs::rightNow();
	my $toggle = 'off';
	# An open row is a running session, however long it has run. The configured
	# duration is only a guess - a real session can be much longer - so elapsed
	# time must never turn an appointment off by itself. Doing that made a place
	# whose session outlived its estimate look stopped: navigation then started a
	# fresh session on every tick while the old one was still open.
	my $open = &subs::db_query('select timestamp from appointments where app=? and (type=? or type=?) and stop_seen is null and timestamp <= ? order by timestamp desc limit 1', $app, 'start', 'record', $server_time)->hashes->[0];
	$toggle = 'on' if $open;
	# rewriting an unchanged toggle cost two writes and a websocket message on
	# every header render
	my $current = &subs::setting_grabber({ app => $app, setting => 'toggle' });
	&subs::setting_setter({ app => $app, setting => 'toggle', value => $toggle }) unless defined $current && $current eq $toggle;
	return $toggle;
}

# ---- warehouse / inventory helpers -----------------------------------------

# Where are we right now? navigation_automation starts a place when GPS says we
# are in it, which shows up as its 'toggle' being on. A device without GPS
# (laptop/desktop) can't do that, so we fall back to whichever running place is
# flagged with inventory ability.
sub current_place() {
	my $q = &db_query('select app from settings where setting=? and value=?', 'toggle', 'on');
	my $toggled = $q ? $q->hashes : [];
	my ($inventory, $fallback);
	foreach my $t ( @{$toggled} ) {
		my $app = $t->{'app'};
		my $pin = &db_query('select app from settings where app=? and (setting=? or setting=?) and value=? limit 1', $app, 'pos', 'mab', 'place');
		next unless ($pin && $pin->hashes->[0]);
		$fallback = $app unless $fallback;
		my $inv = &setting_grabber({ app => $app, setting => 'inventory_ability' });
		$inventory = $app if $inv && $inv eq 'on';
	}
	return $inventory || $fallback || '';
}

# What an item has on hand right now: its signed stock rows summed per unit, the
# same figure the warehouse Levels view shows. A money row (it names an account)
# and a balance anchor (kind inventory) are not stock and are left out, the way
# warehouse_grabber reads them.
sub warehouse_stock_for {
	my ($item) = @_;
	return {} unless $item && $item ne '';
	my $rows = &db_query('select quantity, unit, kind, type, account from warehouse where item = ?', $item);
	my %stock;
	foreach my $r ( @{ $rows ? $rows->hashes : [] } ) {
		my $kind = $r->{'kind'};
		$kind = ($r->{'type'} eq 'inventory' ? 'inventory' : (($r->{'account'} && $r->{'account'} ne '') ? 'money' : 'stock')) if !defined $kind || $kind eq '';
		next unless $kind eq 'stock';
		my $unit = $r->{'unit'} || 'each';
		$stock{$unit} += &numeric_formatter($r->{'quantity'}) + 0;
	}
	return \%stock;
}

# What an item has on hand, in the unit its own app names (its `unit` setting),
# else its sole unit - what a fixed-level quantity budget reads. Zero when nothing
# of it is stocked.
sub warehouse_on_hand {
	my ($item, $settings) = @_;
	my $stock = &warehouse_stock_for($item);
	my $unit = $settings && $settings->{'unit'};
	return $stock->{$unit} + 0 if $unit && defined $stock->{$unit};
	my @units = grep { defined $stock->{$_} } keys %{$stock};
	return 0 unless scalar @units == 1;
	return $stock->{$units[0]} + 0;
}

# How to reach a stock target from what is on hand now, in whole packages where
# the item names them: a shortfall of four covered by a six-pack reads "buy one
# six-pack". The smallest pack that covers the shortfall is bought once; when no
# pack covers it the biggest is repeated; with no packaging at all the bare
# shortfall is the answer.
sub warehouse_restock_for {
	my ($item, $target) = @_;
	my $settings = &settings_grabber({ app => $item });
	my $on_hand = &warehouse_on_hand($item, $settings);
	my $short = ($target || 0) - $on_hand;
	my $plan = { item => $item, on_hand => $on_hand, target => ($target || 0), short => ($short > 0 ? $short : 0), buy => undef };
	return $plan unless $short > 0;
	my $packaging = eval { return decode_json &setting_grabber({ app => $item, setting => 'app_packaging' }) }
		|| eval { return decode_json &setting_grabber({ app => $item, setting => 'packaging' }) }
		|| {};
	my @packs = sort { $a->{'quantity'} <=> $b->{'quantity'} }
		map { { name => $packaging->{$_}->{'name'}, quantity => ($packaging->{$_}->{'quantity'} + 0) } }
		grep { ref $packaging->{$_} eq 'HASH' && ($packaging->{$_}->{'quantity'} || '') =~ /[0-9]/ }
		keys %{$packaging};
	my ($covers) = grep { $_->{'quantity'} >= $short } @packs;
	if ($covers) {
		$plan->{'buy'} = { %{$covers}, count => 1, units => $covers->{'quantity'} };
	}
	elsif (scalar @packs) {
		my $pack = $packs[-1];
		my $count = int(( $short + $pack->{'quantity'} - 1 ) / $pack->{'quantity'});
		$plan->{'buy'} = { %{$pack}, count => $count, units => $count * $pack->{'quantity'} };
	}
	else {
		$plan->{'buy'} = { name => 'each', quantity => 1, count => $short, units => $short };
	}
	return $plan;
}

# The shelf life (e.g. '3w') declared on an item's packaging, if any.
sub warehouse_item_expires {
	my $item = shift;
	my $packaging = eval { return decode_json &setting_grabber({ app => $item, setting => 'packaging' }) } || {};
	foreach my $p ( values %{$packaging} ) {
		next unless ref $p eq 'HASH';
		my $exp = $p->{'expires'};
		return $exp if $exp && $exp ne '';
	}
	return '';
}

# Where does an item live? Most specific first: an explicit 'place' setting on
# the item, a 'default_place' on the item's packaging, a 'place' setting on the
# app, the app itself when it is a place (pos=place), and finally wherever we
# currently are. Returns '' when nothing resolves, and callers treat that as
# "do not touch stock".
sub warehouse_place_for {
	my ($app,$item) = @_;
	foreach my $subject ( $item, $app ) {
		next unless $subject;
		my $q = &db_query('select value from settings where app=? and setting=? limit 1', $subject, 'place');
		my $s = $q ? $q->hashes->[0] : undef;
		return $s->{'value'} if $s->{'value'} && $s->{'value'} ne '';
	}
	if ($item) {
		my $packaging = eval { return decode_json &setting_grabber({ app => $item, setting => 'packaging' }) } || {};
		foreach my $p ( values %{$packaging} ) {
			next unless ref $p eq 'HASH';
			return $p->{'default_place'} if $p->{'default_place'} && $p->{'default_place'} ne '';
		}
	}
	if ($app) {
		my $q = &db_query('select value from settings where app=? and setting=? and value=? limit 1', $app, 'pos', 'place');
		return $app if ($q && $q->hashes->[0]);
	}
	return &current_place();
}

# The journal metadata stored in a warehouse row's data column: why the stock
# moved, what app it came from, and the uuid of the document that caused it.
sub warehouse_journal_entry {
	my $d = shift;
	return encode_json {
		reason => $d->{'reason'},
		source => $d->{'source'},
		source_uuid => $d->{'source_uuid'}
	};
}

# Record a stock movement. Positive quantity puts stock in, negative takes it
# out. Only called once a place is known, so stock never lands unplaced.
sub warehouse_movement {
	my $d = shift;
	my $item = $d->{'item'};
	my $quantity = &numeric_formatter($d->{'quantity'}) + 0;
	return unless $item && $quantity != 0;
	my $wdata = {
		timestamp => $d->{'timestamp'} || &rightNow(),
		server_time => &rightNow(),
		item => $item,
		model => $d->{'model'},
		options => $d->{'options'},
		uuid => &random_string_creator(40),
		quantity => $quantity,
		unit => $d->{'unit'} || 'each',
		place => $d->{'place'},
		# the warehouse has three faces now; this writer only ever moves stock
		kind => $d->{'kind'} || 'stock',
		type => $d->{'type'} || 'stock',
		account => $d->{'account'},
		project => $d->{'project'},
		warranty => $d->{'warranty'},
		app_uuid => $d->{'app_uuid'},
		data => &warehouse_journal_entry($d)
	};
	&db_insert('warehouse', $wdata);
	return $wdata;
}

# FIFO-walk the stock and write off whatever has outlived its packaging shelf
# life. Runs on a timer (see President.pl). Each write-off references the lot it
# expired via app_uuid, and since the write-off is itself a negative movement,
# the next pass consumes that lot and won't expire it twice.
sub warehouse_expiry_sweep() {
	my $now = &rightNow();
	my $q = &db_query('select * from warehouse where item is not null and item != ? and place is not null and place != ? order by timestamp asc', '', '');
	my $rows = $q ? $q->hashes : [];
	my %lots;
	foreach my $r ( @{$rows} ) {
		my $unit = $r->{'unit'} || 'each';
		my $types = $gb::measures->{$unit}->{'types'} || [];
		next if ($r->{'account'} && $r->{'account'} ne '') || (grep { $_ eq 'currency' } @{$types});
		my $qty = &numeric_formatter($r->{'quantity'}) + 0;
		next if $qty == 0;
		my $key = $r->{'place'} . "\0" . $r->{'item'};
		my $queue = $lots{$key} ||= [];
		if ($qty > 0) {
			push @{$queue}, { uuid => $r->{'uuid'}, ts => &numeric_formatter($r->{'timestamp'}) + 0, remaining => $qty, row => $r };
		}
		else {
			my $need = -$qty;
			foreach my $lot ( @{$queue} ) {
				last if $need <= 0;
				next if $lot->{'remaining'} <= 0;
				my $take = $lot->{'remaining'} < $need ? $lot->{'remaining'} : $need;
				$lot->{'remaining'} -= $take;
				$need -= $take;
			}
		}
	}
	my $written = 0;
	foreach my $key ( keys %lots ) {
		my ($place,$item) = split /\0/, $key;
		my $expires = &warehouse_item_expires($item);
		next unless $expires;
		foreach my $lot ( @{$lots{$key}} ) {
			next unless $lot->{'remaining'} > 0;
			my $expiry = eval { &ago_calc('-' . $expires, $lot->{'ts'}) } || 0;
			next unless $expiry && $now > $expiry;
			my $src = $lot->{'row'};
			&warehouse_movement({
				item => $item,
				quantity => $lot->{'remaining'} * -1,
				unit => $src->{'unit'},
				place => $place,
				model => $src->{'model'},
				account => $src->{'account'},
				project => $src->{'project'},
				warranty => $src->{'warranty'},
				timestamp => $now,
				app_uuid => $lot->{'uuid'},
				type => 'expiry',
				reason => 'expired',
				source => $place,
				source_uuid => $lot->{'uuid'}
			});
			$lot->{'remaining'} = 0;
			$written++;
		}
	}
	return $written;
}

sub task_checker() {
	my $one_app = shift;
	my $server_time = &subs::rightNow();
	my $tasks = $one_app ? [{ app => &subs::unformat_name($one_app) }] : &subs::db_query('select app from settings where setting = ? and value is not null','tasks')->hashes;
	foreach my $task ( @{$tasks} ) {
		my $app = $task->{'app'};
		my $taskskis = &subs::task_grabber($app);
	#	my $websockets = &subs::db_query('select * from websockets where app = ? and windows like ? and server_time > ? and windows is not null order by timestamp DESC',
	#	'tab', '%app":"' . $app . '%', $server_time - 5000)->hashes;
	#	if (scalar @{$websockets} > 0) {

			my $msg = {
				app => $app,
				type => 'html',
				selector => '.re_tasks[app="' . $app . '"]',
				content => $taskskis->{'html'}
			};
			&Websocket::send('server', $msg);

	#	}
	}

	return 0;
}

sub task_grabber() {
	my $app = shift;
	my $parent = shift || 0;
	my $settings = &subs::settings_grabber({ app => $app });
	my $tasks_json = &subs::setting_grabber({ app => $app, setting => 'tasks' }) || '[]';
	my $tasks = decode_json $tasks_json;
	@{$tasks} = grep { $_->{'uuid'} } @{$tasks};
	@{$tasks} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$tasks};
	my $totals = {};
	foreach my $t ( @{$tasks} ) {
		my $tsettings = &subs::settings_grabber({ app => &unformat_name($t->{'task'}) });
		$t->{'colour'} = $tsettings->{'colour'} if $tsettings->{'colour'};
		foreach my $bm ( keys %{$gb::budget_modes} ) {
			if ($bm eq 'duration') {
				$totals->{$bm} += &subs::time_abbrev_translator($t->{$bm});
				$t->{$bm} = &subs::duration_sayer(&subs::time_abbrev_translator($t->{$bm}) / 1000);
			}
			elsif ($bm eq 'occurences') {
				$totals->{$bm} += $t->{$bm};
			}
		}
		if ($t->{'renew_freq'} + $t->{'last_completed'} < &subs::rightNow() && $t->{'renew_freq'} > 0) {
			$t->{'completed'} = 'off';
		#	$t->{'duration'} = abs $settings->{'duration'};
		}
		$t->{'renew_freq'} = &subs::duration_sayer($t->{'renew_freq'} / 1000);


		if (my $jt = eval { return decode_json $tsettings->{'tasks'} }) {
			if (scalar @{$jt} > 0) {

				$t->{'subsidiaries'} = &task_grabber(&unformat_name($t->{'task'}), $parent + 1);
				if (scalar @{$t->{'subsidiaries'}->{'tasks'}} == 0) {
					&subs::setting_deleter({ app => &subs::unformat_name($t->{'task'}), setting => 'tasks' });
					$t->{'subsidiaries'} = undef;
				}
			}

		}
	}
	$totals->{'duration'} = &subs::duration_sayer($totals->{'duration'} / 1000);

	if ($settings->{'tasks_sort'} eq 'new') {
		@{$tasks} = sort { $b->{'timestamp'} <=> $a->{'timestamp'} } @{$tasks};
	}
	elsif ($settings->{'tasks_sort'} eq 'high') {
		@{$tasks} = sort { $b->{'priority'} <=> $a->{'priority'} } @{$tasks};
	}
	elsif ($settings->{'tasks_sort'} eq 'low') {
		@{$tasks} = sort { $a->{'priority'} <=> $b->{'priority'} } @{$tasks};
	}
	elsif ($settings->{'tasks_sort'} eq 'az') {
		@{$tasks} = sort { $a->{'task'} cmp $b->{'task'} } @{$tasks};
	}
	elsif ($settings->{'tasks_sort'} eq 'za') {
		@{$tasks} = sort { $b->{'task'} cmp $a->{'task'} } @{$tasks};
	}
	elsif ($settings->{'tasks_sort'} eq 'chk') {
		@{$tasks} = sort { $a->{'last_completed'} <=> $b->{'last_completed'} } @{$tasks};
	}
	elsif ($settings->{'tasks_sort'} eq 'rchk') {
		@{$tasks} = sort { $b->{'last_completed'} <=> $a->{'last_completed'} } @{$tasks};
	}
	else {
		@{$tasks} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$tasks};
	}

	if ($settings->{'tasks_filter'} eq 'done') {
		@{$tasks} = grep { $_->{'completed'} eq 'on' } @{$tasks};
	}
	elsif ($settings->{'tasks_filter'} eq 'open') {
		@{$tasks} = grep { $_->{'completed'} eq 'off' } @{$tasks};
	}

	push @{$tasks}, { uuid => 'new', lock => 'locked', colour => '#' . &subs::random_colour_grabber() } unless $parent > 0;
	my $c = &subs::controller_builder();
	my $html = $c->render_to_string(
		template => 'apps/tasks',
		tasks => $tasks,
		app => $app,
		totals => $totals,
		settings => $settings,
		parent => $parent
	);
	return { html => $html, tasks => $tasks, totals => $totals };
}

sub task_writer() {
	my $c = shift;
	my $data = shift;
	my $papp = &subs::unformat_name($data->{'papp'});
	my $app = &subs::unformat_name($data->{'app'});
	my $server_time = $c->param('server_time') || &subs::rightNow();
	my $timestamp = $data->{'timestamp'};
	my $uuid = $data->{'uuid'};
	my $name = $data->{'name'};
	my $value = $data->{'value'};
	my $colour = $data->{'colour'};
	my $tasks = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'tasks' }) } || [];

	if ($name eq 'duration') {
		$value = &subs::time_abbrev_translator($value);
	}
	elsif ($name eq 'occurences') {
		$value =~ s/[^0-9.]//gi;
		$value = abs $value;
	}
	elsif ($name eq 'renew_freq') {
		$value = &subs::time_abbrev_translator($value);
	}
	elsif ($name eq 'task') {
		$value = &subs::unformat_name($value);
	}
	if ($uuid eq 'new') {
		my $settings = &subs::settings_grabber({ app => $value });
		$settings->{'worth'} =~ s/[^0-9.]//gi;
		push @{$tasks}, {
			uuid => &subs::random_string_creator(),
			$name => $value,
			timestamp => $timestamp,
			colour => $settings->{'colour'} || $colour,
			duration => &subs::duration_sayer(abs &subs::time_abbrev_translator($settings->{'duration'}) / 1000),
			occurences => 1,
			priority => 0,
			completed => 'off',
		};
	}
	else {
		my @task = grep { $_->{'uuid'} eq $uuid } @{$tasks};


		my $task = $task[0];
		$task->{$name} = $value;
		my @tasks = grep { $_->{'uuid'} ne $uuid } @{$tasks};
		push @tasks, $task;
		@{$tasks} = @tasks;
		my $parent_task = eval { return decode_json &subs::setting_grabber({ app => $task->{'task'}, setting => 'tasks' }) } || [];
		foreach my $pt ( @{$parent_task} ) {
			my $tasks = &subs::task_writer($c,{
				papp => $papp,
				app => $pt->{'task'},
				timestamp => $timestamp,
				uuid => $pt->{'uuid'},
				name => $name,
				value => $value,
				colour => $pt->{'colour'},
			});
		}
		if ($name eq 'completed' && $value eq 'on') {

			my $running_appt = &subs::db_query('select * from appointments where app = ? and (type = ? or type = ?) and timestamp <= ? order by timestamp', $papp, 'start', 'record', $timestamp)->hashes->[0];
			$task->{'last_completed'} = &subs::rightNow();
			if ($task->{'appt'} eq 'on') {
				my $settings = &subs::settings_grabber({ app => $task->{'task'} });
				my $duration;
				if ($task->{'duration'} && $task->{'duration'} =~ /[0-9]/gi) {
					$duration = abs &subs::time_abbrev_translator($settings->{'duration'});
				}
				elsif ($settings->{'duration'} && $settings->{'duration'} =~ /[0-9]/gi) {
					$duration = abs &subs::time_abbrev_translator($settings->{'duration'});
				}
				else {
					$duration = abs &subs::time_abbrev_translator(&subs::setting_grabber({ 'app' => 'me', setting => 'duration'}) || '5m');
				}

				# keyed on the request alone (the timestamp is already in the uuid's prefix),
				# never on $running_appt: that is the earliest open session on THIS machine, so
				# hashing it in gave the same completion a different uuid on every machine and
				# the mesh kept each machine's copy as its own row
				my $md5_uuid = md5_sum $papp . '-' . $timestamp . '-' . $task->{'task'} . $data->{'project'} . $data->{'account'} . $data->{'movement'};
				my $data = {
					app => $task->{'task'},
					timestamp => $timestamp,
					type => 'usual',
					quantity => $task->{'occurences'},
					duration => (abs $duration),
					source_uuid => $running_appt->{'uuid'},
					project => $data->{'project'},
					account => $data->{'account'},
					movement => $data->{'movement'},
					uuid => $timestamp . '-' . $md5_uuid,
					server_time => $server_time
				};
				my $app = &Manager::appointment_writer($c,$data);
				$task->{'last_appt_uuid'} = $app->{'uuid'};
				$task->{'last_server_time'} = $app->{'server_time'};

			}

		}
		elsif ($name eq 'completed' && $task->{'appt'} eq 'on' && $value eq 'off') {
			&Manager::delete_app($task->{'task'},$task->{'last_appt_uuid'},$task->{'server_time'},'task');
		}
	}
	return $tasks;
}

sub note_retriever() {
	my ($app,$uuid) = @_;
	my $noters = &subs::db_select('appointments', ['start_notes','notes','end_notes','server_time'], { app => $app, uuid => $uuid });
	my $noteskis = $noters->hashes;
	my $cred = &subs::db_select('security');
	my $creds = $cred->hashes;
	my $s = &subs::suds_grabber();
	my $notekeeper;
	foreach my $note ( @{$noteskis} ) {
		my $start_notes = &subs::note_decrypter($s, $note->{'start_notes'},$note->{'ost'}) if eval { &subs::note_decrypter($s, $note->{'start_notes'},$note->{'ost'}) };
		my $notes = &subs::note_decrypter($s, $note->{'notes'},$note->{'ost'}) if eval { &subs::note_decrypter($s, $note->{'notes'},$note->{'ost'}) };
		my $end_notes = &subs::note_decrypter($s, $note->{'end_notes'},$note->{'ost'}) if eval { &subs::note_decrypter($s, $note->{'end_notes'},$note->{'ost'}) };
		$notekeeper = "<br>" . $start_notes . "<br>" . $notes . "<br>" . $end_notes;
		$notekeeper =~ s/\n/<br>/gi;
	}
	return $notekeeper;
}

sub log_reader_file_preparer() {
	my $file = shift;
	my $f = $file->{'f'};

	#	my ($destination,$asset) = &subs::file_device_renamer($f,$a->{'app'},$misc_settings);
	#	if ($f ne $destination . $asset) {
	#		$f = $destination . $asset;
	#	}
	my $tf = {
		file => $f,
		uuid => $file->{'uuid'},
		server_time => $file->{'server_time'},
		function => $file->{'function'},
		type => $file->{'type'},
		name => $file->{'name'},
		app => $a->{'app'}
	};
	$tf->{'file_type'} = 'img' if $f =~ /jpg|png|bmp|tiff|xcf/;
	$tf->{'file_type'} = 'snd' if $f =~ /wav|mp3|aiff|weba|m4a|flac/;
	$tf->{'file_type'} = 'vid' if $f =~ /mp4|avi|mov|webm|mkv/;
	$tf->{'file_type'} = 'pdf' if $f =~ /pdf/;
	$tf->{'file_type'} = 'doc' if $f =~ /doc|docx|xls|xlsx|pub|pubx|txt|rtf/;
	return $tf;
}


sub remote_machine_lister() {
	my $data = shift;
	my $remote_machines = &subs::db_select('remote_machines')->hashes || [];

	# A machine must never carry itself as a remote. A self row is poison: the
	# reconnecter keeps a turn for it, and because the hub's own sesh_check hands
	# out every remote row (with its own data blob) as `mirrors`, each self-touch
	# nests the previous blob - the row grows without bound and the turn the real
	# peers needed is spent decoding it. Drop the row here so a hub that grew one
	# heals, and keep the current call clean too.
	my $self_signatorial = &signatorial_designer();
	if ($self_signatorial) {
		my @self = grep { ($_->{'signatorial'} || '') eq $self_signatorial } @{$remote_machines};
		if (scalar @self) {
			&subs::db_delete('remote_machines', { signatorial => $self_signatorial });
			@{$remote_machines} = grep { ($_->{'signatorial'} || '') ne $self_signatorial } @{$remote_machines};
		}
	}

	# a mirror entry is how a machine the source knows about is reached through
	# it; when that machine already has a row of its own the list would show the
	# same machine twice (once, three times, with overlapping mirror sources),
	# so a mirror is only added when it is not otherwise present. One identity
	# per machine - uuid beats signatorial beats ip, so a tunnelled machine's
	# 127.0.0.1 can never collide with another entry. Our own signatorial counts
	# as present so a mirror that is this machine is never appended either.
	my %already;
	$already{$self_signatorial} = 1 if $self_signatorial;
	foreach my $rm ( @{$remote_machines} ) {
		my $key = $rm->{'uuid'} || $rm->{'signatorial'} || $rm->{'ip'};
		$already{$key} = 1 if $key;
	}
	foreach my $rm ( @{$remote_machines} ) {
		$rm->{'mirror'} = 'no';
		if ($rm->{'mirrors'} && $data->{'mirrors'} ne 'none') {
			my $mirrors = eval { return decode_json $rm->{'mirrors'} } || [];
			foreach my $mirror ( @{$mirrors} ) {
				my $key = $mirror->{'uuid'} || $mirror->{'signatorial'} || $mirror->{'ip'};
				next if $key && $already{$key};
				$already{$key} = 1 if $key;
				$mirror->{'hostname'} .= ' (mirror)';
				$mirror->{'source_ip'} = $rm->{'ip'};
				$mirror->{'source_domain'} = $rm->{'domain'};
				$mirror->{'source_fqdn'} = $rm->{'fqdn'};
				$mirror->{'mirror'} = 'yes';
			# When the mirror is on our own network, reach it directly rather than
			# through the source's tunnel: same-wifi peers talk on the LAN.
				my $lan = &subs::peer_lan_address($mirror, 1);
				if ($lan) {
					$mirror->{'ip'} = $lan->{'ip'};
					$mirror->{'manager'} = $lan->{'manager'};
					$mirror->{'port'} = $lan->{'port'} || $mirror->{'port'};
					$mirror->{'vip'} = $lan->{'ip'};
					$mirror->{'lan'} = 'yes';
				}
				push @{$remote_machines}, $mirror;
			}
		}
		$rm->{'vip'} = $rm->{'ip'};
		$rm = &subs::remote_machine_tunnel_processor($rm);
	}
	unless ( $data->{'self'} eq 'no' ) {
		unshift @{$remote_machines}, { hostname => 'me', signatorial => &subs::signatorial_designer(), ip => '127.0.0.1', uuid => &subs::random_string_creator(25) };
	}
	foreach my $t ( qw/signatorial uuid connection ip device tunnel mirror archive/ ) {
		if ($data->{$t}) {
			if ($data->{$t} eq 'yes') {
				@{$remote_machines} = grep { defined $_->{$t} && $_->{$t} ne '' && $_->{$t} ne 'null' && $_->{$t} ne 'NULL'	} @{$remote_machines};
			} else {
				@{$remote_machines} = grep { $_->{$t} eq $data->{$t} } @{$remote_machines};
			}
		}
	}
	if ($data->{'limit'}) {
		if ($data->{'limit'} == 1) {
			$remote_machines = $remote_machines->[0];
		} else {
			splice @{$remote_machines}, $data->{'limit'};
		}
	}
	return $remote_machines;



}


sub remote_machine_tunnel_processor() {
	my $rm = shift;
	if ($rm->{'tunnel'} eq 'yes' && !$rm->{'tuns'}) {
		my $tun = &subs::tunnel_port_mapper({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}  });
		$rm->{'tuns'} = $tun;

		# A tunnel flag can outlive its rows (the peer redialled, the hub retired
		# the batch, or the failure counter dropped them). Rewriting the manager
		# from an empty map writes a portless 'https://127.0.0.1:' that then
		# replaces the peer's real address until its next redial, so only rewrite
		# when the tunnel actually reserved a port; otherwise leave the advertised
		# manager (and the LAN fallback below) to reach the peer.
		if ($tun->{'PORT_AHOY'}) {
			$rm->{'ip'} = '127.0.0.1';
			$rm->{'port_dock'} = $tun->{'PORT_DOCK'};
			my $man = $rm->{'manager'};
			$rm->{'manager'} = 'https://' . $rm->{'ip'} . ':' . $tun->{'PORT_AHOY'};
			if ($man ne $rm->{'manager'}) {
				&subs::db_update('remote_machines', {
					manager => $rm->{'manager'},
				}, { uuid => $rm->{'uuid'} });
			}
		}
	}
	# If reaching the peer by its stored manager would loop back home (its name
	# resolves to 127.0.0.1 on this box, or the hub tunnel points at 127.0.0.1
	# while we are not the hub), use the LAN address it advertised instead.
	my $lan = &subs::peer_lan_address($rm);
	if ($lan) {
		$rm->{'ip'} = $lan->{'ip'};
		$rm->{'manager'} = $lan->{'manager'};
		$rm->{'port'} = $lan->{'port'} || $rm->{'port'};
		$rm->{'vip'} = $lan->{'ip'};
	}
	return $rm;
}

# A peer advertises its own name as its manager. On a machine whose dnsmasq or
# hosts map that name back to itself - or when a hub-tunnel manager sits at
# 127.0.0.1 while we are a peer, not the hub - reaching it that way loops home.
# When the manager host resolves to loopback, fall back to the LAN address the
# peer reported in its network map, so same-net peers talk directly.
sub peer_lan_address() {
	my ($rm, $force) = @_;
	return undef unless $rm && $rm->{'manager'};
	# The hub's 127.0.0.1 tunnel managers are correct there, and it is not on the
	# peers' LAN - this fallback is only for a peer reaching another peer.
	return undef if &subs::device_setter() eq 'server';
	return undef unless $rm->{'network'};
	my ($host) = $rm->{'manager'} =~ m{^https?://([^:/]+)};
	return undef unless $host;
	# Normally only a manager that loops home (resolves to 127.0.0.1) is swapped
	# for the LAN address. $force skips that: a mirror is reached through the
	# source's public tunnel name, yet when the peer shares our own network the
	# direct LAN address is still the better route.
	unless ($force) {
		my $loopback = 0;
		if ($host =~ /^127\./) { $loopback = 1; }
		elsif ($host =~ /[a-zA-Z]/) {
			require Socket;
			my $packed = gethostbyname($host);
			$loopback = 1 if $packed && Socket::inet_ntoa($packed) =~ /^127\./;
		}
		return undef unless $loopback;
	}
	# a mirror arrives already decoded; a normal row is a JSON string
	my $you = ref $rm->{'network'} eq 'HASH' ? $rm->{'network'} : (eval { decode_json $rm->{'network'} } || {});
	# our own interfaces rarely change; don't run ifconfig per peer per call
	our ($_ME_NETWORK, $_ME_NETWORK_AT);
	unless ($_ME_NETWORK && $_ME_NETWORK_AT > &subs::rightNow() - 60000) {
		$_ME_NETWORK = &subs::network_interface_reporter();
		$_ME_NETWORK_AT = &subs::rightNow();
	}
	my $me = $_ME_NETWORK;
	foreach my $nic ( sort keys %{$you} ) {
		next if $nic eq 'public_address' || !$you->{$nic}->{'ip'};
		my $you_ip = $you->{$nic}->{'ip'};
		next if $you_ip =~ /^127\./;
		foreach my $nicc ( sort keys %{$me} ) {
			next if $nicc eq 'public_address' || !$me->{$nicc}->{'ip'};
			next unless &subs::same_net_test($you_ip, $me->{$nicc}->{'ip'}) eq 'yes';
			my $port = $you->{$nic}->{'port'} || $rm->{'port'} || 45545;
			return { ip => $you_ip, port => $port, manager => 'https://' . $you_ip . ':' . $port };
		}
	}
	return undef;
}

sub remote_machine_negotiator() {
	my $data = shift;
	$gb::suds = &suds_grabber();
	my $c = &subs::controller_builder();
	$c->session('gimme' => $data->{'gimme'});


	my $remote_upgrade = &subs::setting_grabber({ app => '__president', setting => 'remote_upgrade' });
	my $remote_connect_timer =  &subs::setting_grabber({ app => '__president', setting => 'remote_connect_timer' }) || 0;
	# A sync that dies mid-run leaves "running" behind. The old clear keyed off a
	# different timer (remote_connect_timer) and waited a blind seven minutes -
	# on a machine whose servers restart every few minutes that is most of the
	# time, so the sync rarely got to run. Bound the lock by its own age instead,
	# and read the pid the marker carries: a bare 'running' from an older build
	# still trusts the age, but a dead owner is cleared at once.
	my ($up_flag, $up_pid) = split /:/, ($remote_upgrade || ''), 2;
	$up_flag ||= '';
	if ($up_flag eq 'running') {
		my $lock = &subs::db_query('select server_time from settings where app = ? and setting = ? order by cast(server_time as integer) desc limit 1', '__president', 'remote_upgrade')->hashes->[0];
		my $owner_dead = ($up_pid && $up_pid =~ /^\d+$/ && $up_pid > 1 && !kill(0, $up_pid)) ? 1 : 0;
		my $bound = (($gb::timeouts->{'remote_machine_sync'}->{'interval'} || 120) * 1000) * 2;
		if ($owner_dead || !$lock->{'server_time'} || $lock->{'server_time'} + $bound < &subs::rightNow()) {
			&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
			$remote_upgrade = '';
		}
	}
	if (($remote_upgrade || '') ne 'running' && $remote_connect_timer + 10000 < &subs::rightNow()) {
		&Manager::remote_machine_reconnector($c);
	}
	#&system_monitor({
	#	timeout => 'remote_machine_sync',
	#});
}


# Relay a request with no browser behind it. remote_relay_request reads the
# caller's request - its path, method and params - which a headless machine (the
# cloud, a utility job, a CLI) does not have; build a bare controller and hand it
# a synthesized request instead, so a server with no page can still hand a change
# on to its peers over exactly the rail the browser uses. $data:
#   path        => '/manager/...'           (required)
#   method      => 'post' | 'get'            (default post)
#   params      => { ... }                    (request params)
#   remote_uuid => a single target, else a flood to every reachable peer
#   extra       => extra_params for remote_relay_request (e.g. dissemination)
sub operator_door_push {
	# Hand a device's rotated Now Me row to the other House machines on this LAN.
	# A device that falls back probes them with this pair, so they must hold it
	# now; the durable digest is only a backstop for a machine that was away.
	# Each peer verifies the signed request (`/manager/operator_door`), so no
	# session cookie is needed. Bounded and synchronous: two LAN peers cost a
	# couple of seconds, and Now Me is a deliberate action.
	my ($edt, $chip_id, $value, $server_time, $device) = @_;
	return 0 unless $edt && $chip_id && defined $value && length $value;
	$server_time ||= &subs::rightNow();
	$device ||= &subs::device_setter();
	require Mojo::UserAgent;
	my $n = 0;
	foreach my $rm ( @{ &subs::db_select('remote_machines')->hashes } ) {
		next unless (($rm->{'connection'} // '') eq 'active');
		next unless $rm->{'pubkey'};
		# only a machine sharing this network can be a LAN fallback
		my $lan = &subs::peer_lan_address($rm, 1);
		next unless $lan && $lan->{'manager'};
		my $ua = Mojo::UserAgent->new(connect_timeout => 2, inactivity_timeout => 3);
		$ua = $ua->insecure(1);
		$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
		my $res = eval {
			$ua->post($lan->{'manager'} . '/manager/operator_door' => form => {
				signatorial => &subs::signatorial_designer(),
				edt => $edt,
				chip_id => $chip_id,
				device => $device,
				server_time => $server_time,
				value => $value,
			})->result;
		};
		$n++ if $res && $res->is_success;
	}
	return $n;
}

sub relay_headless {
	my ($data) = @_;
	$data ||= {};
	my $path = $data->{'path'} || return;
	my $c = &subs::controller_builder();
	my $req = $c->req;
	$req->url->path($path);
	$req->method(uc($data->{'method'} || 'POST'));
	my $params = { %{ $data->{'params'} || {} } };
	$params->{'remote_uuid'} = $data->{'remote_uuid'} if $data->{'remote_uuid'};
	# Mojo::Message::body_params is a getter here: passing a Mojo::Parameters to
	# it does nothing, so every headless relay POST carried an empty body. Encode
	# the form into the request body so remote_relay_request parses it.
	$req->headers->content_type('application/x-www-form-urlencoded');
	$req->body(Mojo::Parameters->new(%{$params})->to_string);
	return &Manager::remote_relay_request($c, $data->{'extra'} || {});
}

# Drain the headless relay queue: a JSON list of relay_headless calls left by a
# job or a CLI with no browser to drive. Each entry is relayed once and the queue
# is cleared, so a machine that has been away does not replay a stale backlog on
# every tick.
sub remote_relay_queue_run {
	my $raw = &subs::setting_grabber({ app => '__president', setting => 'remote_relay_queue' });
	my $queue = eval { decode_json $raw } || [];
	return 0 unless ref $queue eq 'ARRAY' && scalar @{$queue};
	&subs::setting_setter({ app => '__president', setting => 'remote_relay_queue', value => '[]' });
	my $n = 0;
	foreach my $item ( @{$queue} ) {
		next unless ref $item eq 'HASH' && $item->{'path'};
		eval { &subs::relay_headless($item); $n++; };
	}
	return $n;
}

# The hub websocket endpoint a NAT'd peer dials out to. Preferred source is the
# hub's OWN manager URL from the handshake (e.g. https://thejunderground.com:45545),
# rewritten to wss -- so the peer dials the right host AND port instead of
# guessing from its own domain. config tunnel_hub overrides; the last resort is
# this machine's domain. The peer names itself with its own signatorial.
sub tunnel_hub_url() {
	my ($manager, $ws_port) = @_;
	my $sig = &subs::signatorial_designer();
	my $hub;
	if ($config->{'tunnel_hub'}) {
		$hub = $config->{'tunnel_hub'};
	}
	elsif ($manager && $manager =~ m{^https?://}) {
		$hub = $manager;
		$hub =~ s{^http://}{ws://};
		$hub =~ s{^https://}{wss://};
		# the manager URL is only the base (e.g. wss://host:port), so drop a
		# trailing /manager if one is present and always point at the ws route.
		$hub =~ s{/manager/?$}{};
		$hub =~ s{/+$}{};
		# Bind the tunnel listeners on the hub's websocket server, not its main
		# server. The main server runs several prefork workers, and the hub's
		# listener table is per process: a redial could land in a worker that does
		# not know the peer's existing listeners and try to bind ports still held
		# by a sibling (EADDRINUSE). The websocket server runs a single worker, so
		# every session for a peer is retired and rebound in the same process.
		if (defined $ws_port && $ws_port =~ /^[0-9]+$/) {
			if (!($hub =~ s{:([0-9]+)$}{:$ws_port})) {
				$hub .= ':' . $ws_port;
			}
		}
	}
	else {
		$hub = 'wss://' . $config->{'domain'} . ($ws_port && $ws_port =~ /^[0-9]+$/ ? ':' . $ws_port : '');
	}
	# The data plane lives at a path, not at the bare host: a wss://host:port
	# dial with no path asks for `/`, where no websocket route exists, and the
	# holder just retries forever (the tunnels never stick). Normalise the path
	# last, so a config tunnel_hub that already names it is not doubled.
	$hub =~ s{/manager/tunnel/ws$}{};
	$hub =~ s{/+$}{};
	$hub .= '/manager/tunnel/ws';
	return $hub . (index($hub, '?') >= 0 ? '&' : '?') . 'signatorial=' . Mojo::Util::url_escape($sig);
}

# Run the peer half of the wss tunnel: dial the hub's manager and serve its
# `open` frames. $manager is the hub's manager URL from the handshake.
sub tunnel_wss_peer() {
	my ($manager, $ws_port) = @_;
	my $sig = &subs::signatorial_designer();
	&Tunnel::peer_session(&subs::tunnel_hub_url($manager, $ws_port), { signatorial => $sig, sign => \&subs::peer_sign_request });
	# peer_session is async and reconnects itself, so the loop has to run HERE or
	# the forked tunnel holder returns at once and the tunnel dies with it.
	Mojo::IOLoop->start;
}

sub tunnel_starter() {
	my $data = shift;
	my $ip = $data->{'ip'};
	my $signatorial = $data->{'signatorial'};
	# A fresh batch supersedes any half-built one: a batch whose holder never came
	# up leaves 'connecting' rows that nothing reaps (tunnel_stopper only removes
	# active rows), so drop them here rather than let them pile up across dials.
	&subs::db_delete('tunnels', { signatorial => $signatorial, status => 'connecting' });
	my $rm = &Manager::remote_useragent_maker({ signatorial => $signatorial });
	my $domain = $data->{'domain'} || $rm->{'domain'} || $rm->{'ip'};
	my $status = 'active';
	my $batch_uuid = &subs::random_string_creator(25);
	my $ports = {};
	foreach my $p ( @gb::ports ) {
		$ports->{$p} = $ENV{$p};
	}
	my $jports = encode_json $ports;
	my $url = $rm->{'manager'} . '/manager/configure/remote_machine/tunnel/request';
	my $form_data = {
		signatorial => &subs::signatorial_designer(),
		ports => $jports,
		status => $status,
		batch_uuid => $batch_uuid,
		domain => $domain
	};
#	&subs::tunnel_stopper({ signatorial => $signatorial });
	my $res = $rm->{'ua'}->post($url => form => $form_data)->result;

	my $port = $config->{'ssh_port'};
	if ($res->is_success) {
		if (eval { decode_json $res->body }) {
			my $rb = decode_json $res->body;
			# The tunnel data plane is the password-less websocket (tunnel.pl):
			# this device is the peer and dials the hub, which listens on the
			# reserved ports. One websocket carries every channel.
			my @batch_uuids;
			foreach my $r (@gb::ports ) {
				my $uuid = $rb->{$r}->{'reservation_uuid'} || &subs::random_string_creator(26);
				my $tunnel = {
					server_time => &subs::rightNow(),
					device => &subs::device_setter(),
					host => $config->{'domain'},
					timestamp => &subs::rightNow(),
					ip => $ip || $rm->{'ip'},
					domain => $domain,
					in_port => $rb->{$r}->{'source'},
					out_port => $rb->{$r}->{'dest'},
					name => $r,
					warranty => &subs::ago_calc('-1d', &subs::rightNow()),
					status => 'connecting',
					signatorial => $signatorial || $rm->{'signatorial'},
					uuid => $uuid,
					direction => 'in',
					batch_uuid => $batch_uuid
				};
				&subs::db_insert('tunnels', $tunnel);
				push @batch_uuids, $uuid;
				$tunnel->{'ip'} = $config->{'domain'};
				my $url = $rm->{'manager'} . '/manager/configure/remote_machine/tunnel/confirm';
				my $jtunnel = encode_json $tunnel;
				my $form_data = {
					signatorial => &subs::signatorial_designer(),
					tunnel => $jtunnel,
					status => $status,
					uuid => $uuid
				};
				$rm->{'ua'}->post($url => form => $form_data)->result;
			}
			# One holder holds the whole batch: hub_session reads this peer's
			# tunnels rows once, when the websocket arrives, and binds a listener
			# per row, so the peer dials a single connection after every port is
			# reserved and confirmed - one connection, all channels.
			my @uuids = @batch_uuids;
			my $pid;
			&subs::subprocessor(sub {
				$pid = $$;
				&subs::db_update('tunnels', { process_id => $pid, server_time => &subs::rightNow(), status => 'active' }, { uuid => $_ }) for @uuids;
				&subs::tunnel_wss_peer($rm->{'manager'}, $rm->{'ws_port'});
			}, { name => 'tunnel holder wss ' . scalar(@uuids) . ' ports' });


		}
	}
	sleep 1;
	&Websocket::send('server', { console => 'tunnelLister()' });
}


sub tunnel_stopper() {
	my $data = shift;
	my $ip = $data->{'ip'};
	my $signatorial = $data->{'signatorial'};
	my $domain = $data->{'domain'};
	my $tunnels = &subs::db_select('tunnels', undef, { signatorial => $signatorial, status => 'active' })->hashes;
	my $rm = &Manager::remote_useragent_maker({ signatorial => $signatorial });
	foreach my $tun ( @{$tunnels} ) {
		my $pid = $tun->{'process_id'};
		if ($pid) {
			my $process = `ps -e | grep $pid`;
			chomp $process;
			if ($process) {
				kill('INT', $tun->{'process_id'});
				waitpid($tun->{'process_id'}, 0);
			}
			my $url = $rm->{'manager'} . '/manager/configure/remote_machine/tunnel/close';
			$tun->{'status'} = 'closed';

			my $jtunnel = encode_json $tun;
			my $form_data = {
				signatorial => &subs::signatorial_designer(),
				tunnel => $jtunnel,
				status => $tun->{'status'}
			};
			my $res = $rm->{'ua'}->post($url => form => $form_data)->result;
			&subs::db_delete('tunnels', { uuid => $tun->{'uuid'}, signatorial => $tun->{'signatorial'} });
		} else {

		}
		&subs::db_delete('tunnels', { uuid => $tun->{'uuid'}, signatorial => $tun->{'signatorial'} });
	}
	my $c = &subs::controller_builder();
	my $tl = $c->render_to_string(template => 'configure/tunnel_list');
	&Websocket::send('server', { console => 'tunnelLister()' });
}


sub tunnel_checker() {
	my $data = shift;
	my $devices = &subs::device_lister(&subs::rightNow(),'list');
	my @seen_signatorials;
	my $batches = [];
	my $device = &subs::device_setter();

	# A headless server has no browser to press Scan, so make sure this machine
	# names itself first: the hub's own device row is where its tunnels become
	# addresses, and without it the block below has nothing to hang them off.
	&subs::ensure_self_device() if $device eq 'server';

	if ($device eq 'server') {
		my $tunnels = &subs::db_select('tunnels', undef, { status => 'active', direction => 'out' })->hashes;
		my $tunnel_duties = eval { return decode_json &subs::setting_grabber({ app => '__president', setting => 'tunnel_duties' }) } || [];
		my $tunnel_duty_count = scalar @{$tunnel_duties};
		my $ss = `ss -tan`;
		my @ss = split /\n/, $ss;
		my $ss_check = [{}];
		foreach my $s ( @ss ) {
			my @fields = split(/\s+/, $s);
			$s = $fields[3];
		}
		foreach my $tun ( @{$tunnels} ) {
			$tun->{'failures'} = 0 unless $tun->{'failures'};
			if ($tun->{'direction'} eq 'out') {
				my $port = $tun->{'in_port'};
				my @active_port = grep { $_ =~ /:\Q$port/ } @ss;
				if (scalar @active_port > 0) {
					$tun->{'failures'} = 0;
					&subs::db_update('tunnels', { server_time => &subs::rightNow() }, { uuid => $tun->{'uuid'} });
				}
				else {
					if ($tun->{'failures'} >= 3) {
						&subs::db_delete('tunnels', { uuid => $tun->{'uuid'} });
					} else {
						$tun->{'failures'}++;
					}
				}
				&subs::db_update('tunnels', { failures => $tun->{'failures'}, server_time => &subs::rightNow() }, { uuid => $tun->{'uuid'}, signatorial => $tun->{'signatorial'} });
			}
		}
		# A headless hub names a peer only through a roster row, and the tunnel
		# websocket will not even serve a signatorial it cannot already name - so
		# a hub whose roster was wiped (a reseed, a restore) can never name the
		# peers whose tunnels it still holds, and the duty below, which needs the
		# row, deadlocks. Rebuild the row from the tunnel itself: the port is
		# live, and remote_device_connect writes the row - its buttons, the
		# tunnel flag and the hub-side manager included - the moment the peer
		# approves. It runs only for a signatorial with no row at all, so it is a
		# one-time repair after a wipe, never a per-tick call on a healthy hub.
		my %tunnel_enrolled;
		foreach my $tun ( @{$tunnels} ) {
			next unless $tun->{'signatorial'} && !$tunnel_enrolled{$tun->{'signatorial'}};
			next if &subs::db_select('remote_machines', undef, { signatorial => $tun->{'signatorial'} })->hashes->[0];
			$tunnel_enrolled{$tun->{'signatorial'}} = 1;
			my $enrollee = eval { &Manager::remote_device_connect({
				manager => 'https://127.0.0.1:' . ($tun->{'in_port'} || '') . '/manager',
				ip => ($tun->{'host'} || '127.0.0.1'),
				password => &subs::suds_grabber(),
				name => &subs::setting_grabber({ app => 'me', setting => 'my_name' }),
				timestamp => &subs::rightNow(),
				browser_tab_id => &subs::random_string_creator(22),
				browser_tab => &subs::random_string_creator(21),
				signatorial => $tun->{'signatorial'},
				tunnel => 'yes'
			}) };
			if ($enrollee && $enrollee->{'body'} && $enrollee->{'body'}->{'signatorial'}) {
				&subs::log_writer('tunnel enrolled ' . substr($tun->{'signatorial'}, 0, 8) . ' from its active tunnel');
			}
		}
		# and name each tunnelled peer in this hub's own device row, so Configure ->
		# Devices and anything that reads the address map sees a tunnel that came up
		# since the last scan, and remote_upgrade can target it without a scan. This
		# mirrors the scan path in device_lister (one PORT_DOCK row per batch, hung
		# off the loopback NIC that marks this hub), so the two agree on shape. The
		# write is skipped when nothing changed, so a healthy hub does not churn.
		{
			my $hostname = `hostname`; chomp $hostname;
			my $me = &subs::db_select('devices', undef, { hostname => $hostname })->hashes->[0];
			if ($me) {
				my $address = eval { decode_json $me->{'address'} } || {};
				my $before = encode_json $address;
				my $nic;
				foreach my $k (keys %{$address}) { $nic = $k if ($address->{$k}->{'ip'} || '') eq '127.0.0.1'; }
				$nic ||= (grep { $_ eq 'lo' } keys %{$address})[0] || (keys %{$address})[0] || 'lo';
				$address->{$nic}->{'ip'} ||= '127.0.0.1';
				my $neigh = $address->{$nic}->{'neigh'} || [];

				my @seen_batches;
				my %active_signatorial;
				my $dock_tunnels = &subs::db_select('tunnels', undef, { status => 'active' })->hashes;
				foreach my $tun ( @{$dock_tunnels} ) {
					next unless $tun->{'name'} && $tun->{'name'} eq 'PORT_DOCK';
					next unless $tun->{'signatorial'};
					next if grep { $_ eq $tun->{'batch_uuid'} } @seen_batches;
					push @seen_batches, $tun->{'batch_uuid'};
					$active_signatorial{$tun->{'signatorial'}} = 1;
					my ($entry) = grep { ($_->{'signatorial'} || '') eq $tun->{'signatorial'} } @{$neigh};
					my $ip = ($tun->{'host'} || $tun->{'ip'} || $tun->{'domain'} || '127.0.0.1');
					my %vals = (
						ip => $ip,
						domain => $ip,
						PORT_DOCK => $tun->{'in_port'},
						tunnel => 'yes',
						signatorial => $tun->{'signatorial'},
						mac => ($entry && $entry->{'mac'} ? $entry->{'mac'} : &subs::random_string_creator(10)),
						uuid => ($entry && $entry->{'uuid'} ? $entry->{'uuid'} : &subs::random_string_creator(25)),
					);
					if ($entry) { $entry->{$_} = $vals{$_} for keys %vals; }
					else { push @{$neigh}, { %vals }; }
				}
				# a tunnel neighbour whose signatorial no longer has an active tunnel
				# is dropped, so a peer that stops dialling does not linger on the map
				@{$neigh} = grep { !($_->{'tunnel'} && $_->{'tunnel'} eq 'yes') || $active_signatorial{$_->{'signatorial'}} } @{$neigh};

				$address->{$nic}->{'neigh'} = $neigh;
				my $after = encode_json $address;
				&subs::db_update('devices', { address => $after }, { uuid => $me->{'uuid'} }) if ($after ne $before);
			}
		}
		# Enrol each tunnelled peer with no browser behind it: the peer's own /gate
		# gives its name and its jawnos.enc backups, and remote_device_connect files
		# the roster row with its buttons - exactly what pressing Connect does.
		# tunnel_peer_enrol is idempotent: it skips the probe once the row shows its
		# backup and the connect once the roster reads active, so this is quiet when
		# healthy.
		my %enrolled;
		foreach my $tun ( @{$tunnels} ) {
			next unless $tun->{'signatorial'} && $tun->{'name'} && $tun->{'name'} eq 'PORT_AHOY';
			next if $enrolled{ $tun->{'signatorial'} }++;
			&subs::tunnel_peer_enrol($tun->{'signatorial'});
		}
		# A peer whose tunnels are gone is disconnected: mark its roster row so
		# nothing keeps dialling a dead hub-side port (remote_upgrade and the relay
		# target that manager). Only rows reached through 127.0.0.1 are the hub's
		# tunnels; a row with a real host manager may still answer directly, so it is
		# left to the reconnector to judge. The Dev list drops the neighbour on its
		# own (the naming pass above prunes it); this keeps the roster honest too and
		# refreshes the panel live.
		my %has_tunnel;
		$has_tunnel{ $_->{'signatorial'} } = 1 for grep { $_->{'signatorial'} } @{$tunnels};
		foreach my $rm ( @{ &subs::db_select('remote_machines', undef, { tunnel => 'yes' })->hashes } ) {
			next unless $rm->{'signatorial'} && ($rm->{'manager'} || '') =~ m{127\.0\.0\.1};
			next if $has_tunnel{ $rm->{'signatorial'} };
			next unless ($rm->{'connection'} || '') eq 'active';
			&subs::db_update('remote_machines', { connection => 'inactive', server_time => &subs::rightNow() }, { signatorial => $rm->{'signatorial'} });
			&Websocket::send('server', { console => 'deviceLister()' });
		}
		foreach my $td ( @{$tunnel_duties} ) {
			my $tun = &subs::tunnel_port_mapper({ signatorial => $td->{'signatorial'}  });
			my $rm = &subs::remote_machine_lister({ signatorial => $td->{'signatorial'}, limit => 1 });
			if ($rm->{'signatorial'}) {
				$rm = &Manager::remote_useragent_maker({ rm => $rm, signatorial => $td->{'signatorial'} });
				my $rdc = {
					manager => $rm->{'manager'},
					filename => $rm->{'data'}->{'database'},
					timestamp => &subs::rightNow(),
					ip => $rm->{'ip'},
					password => &subs::suds_grabber(),
					name => &subs::setting_grabber({ app => 'me', setting => 'my_name' }),
					browser_tab_id => &subs::random_string_creator(22),
					browser_tab => &subs::random_string_creator(21),
					port => $tun->{'PORT_AHOY'},
					dock_port => $tun->{'PORT_DOCK'},
					signatorial => $rm->{'signatorial'},
					nic => $rm->{'nic'},
					tunnel => $rm->{'tunnel'}
				};
				$rm->{'cookie'} = undef;
				my $returner = &Manager::remote_device_connect($rdc);
			}



			@{$tunnel_duties} = grep { $_->{'uuid'} ne $td->{'uuid'} } @{$tunnel_duties};
		}
		if (scalar @{$tunnel_duties} != $tunnel_duty_count) {
			my $jtd = encode_json $tunnel_duties;
			&subs::setting_setter({ app => '__president', setting => 'tunnel_duties', value => $jtd });
		}
	} else {
		foreach my $d ( reverse @{$devices} ) {
			foreach my $ad ( keys %{$d->{'address'}} ) {
				foreach my $n ( grep { $_->{'mac'} && $_->{'purpose'} eq 'server' && $_->{'tunnel'} eq 'active' } @{$d->{'address'}->{$ad}->{'neigh'}} ) {
					next if grep { $_ eq $n->{'signatorial'} } @seen_signatorials;
					push @seen_signatorials, $n->{'signatorial'};
					my $tunnels = &subs::db_select('tunnels', undef, { status => 'active', signatorial => $n->{'signatorial'} })->hashes;

					my $active_tunnel = 0;
					my $domain = $n->{'ip'};

					&subs::tunnel_starter({ ip => $n->{'ip'}, signatorial => $n->{'signatorial'}, domain => $n->{'ip'} }) if scalar @{$tunnels} == 0;
					foreach my $tun ( @{$tunnels} ) {


						if ($tun->{'direction'} eq 'in') {
							my $ps = $tun->{'process_id'};
							my $ps_check = ($ps && $ps =~ /^[0-9]+$/) ? `ps -p $ps -o cmd= 2>/dev/null` : '';
							my $holder_alive = ($ps_check =~ /President\.pl|Manager\.pl/) ? 1 : 0;
							next if grep { $tun->{'signatorial'} eq $_ || $tun->{'batch_uuid'} eq $_  } @{$batches};
							push @{$batches}, $tun->{'signatorial'};
							# A tree restart kills the holder but leaves its rows saying active.
							# Without this the checker waits three hollow-session failures (six
							# minutes) before re-requesting, so the tunnels look like they never
							# stick. Re-request on the first pass when the owner is gone.
							if (!$holder_alive) {
								&subs::tunnel_stopper($tun);
								&subs::tunnel_starter($tun);
								push @{$batches}, $tun->{'batch_uuid'};
								next;
							}
							my $signatorial = $tun->{'signatorial'};
							my $rm = &Manager::remote_useragent_maker({ signatorial => $signatorial });
							my $url = $rm->{'manager'} . '/manager/tunnel/alive';
							my @batch = grep { $_->{'batch_uuid'} eq $tun->{'batch_uuid'} } @{$tunnels};
							# The POST is only the mirror/network sync now. Liveness is the
							# holder's own websocket heartbeat: peer_session pings the hub and
							# stamps a per-hub freshness file on every pong, so the checker reads
							# the data plane directly instead of round-tripping a chip_chyea
							# through the hub (a path that needed a session, the gate and the hub
							# reaching a NAT'd peer all to line up).
							my $form_data = {
								signatorial => &subs::signatorial_designer(),
								network => encode_json &subs::network_interface_reporter(),
								interval => $data->{'interval'},
								tunnel => encode_json \@batch
							};
							$rm->{'ua'}->inactivity_timeout(23);
							my $res = $rm->{'ua'}->post($url => form => $form_data)->result;
							my $age = &Tunnel::alive_age($rm->{'manager'});
							# Connected only if the hub is really listening for us: a fresh pong that
							# reports zero listeners is a hollow session (the hub lost our tunnels
							# rows and bound nothing), and re-requesting is what repairs it.
							my $ports = &Tunnel::alive_ports($rm->{'manager'});
							my $status = (defined $age && $age < 45000 && (!defined $ports || $ports >= 1)) ? 'connected' : 'unknown';
							if ($res && $res->is_success) {
								my $response = eval { decode_json $res->body } || {};
								if ($response->{'mirrors'}) {
									foreach my $mirror ( @{$response->{'mirrors'}} ) {
										my $ip = $rm->{'ip'};
										$mirror->{'manager'} =~ s/127\.0\.0\.1/$ip/gi;
										$mirror->{'mirror'} = 'yes';
										if ($mirror->{'network'}) {
											$mirror->{'network'} = decode_json $mirror->{'network'};
										}

									}

									my $jmirror = encode_json $response->{'mirrors'};
									&subs::db_update('remote_machines', { mirrors => $jmirror, server_time => &subs::rightNow() }, { signatorial => $rm->{'signatorial'} });
								}
							}
							if ($status ne 'connected') {
								$tun->{'failures'} += 1;
								$tun->{'server_time'} = &subs::rightNow();
								if ($tun->{'failures'} >= 3 || $data->{'duty'} eq 'restart') {
									&subs::tunnel_stopper($tun);
									&subs::tunnel_starter($tun);
								}
							}
							else {
								$active_tunnel = 1;
								$tun->{'failures'} = 0;
							}
							&subs::db_update('tunnels', { failures => $tun->{'failures'}, server_time => &subs::rightNow() }, { batch_uuid => $tun->{'batch_uuid'}, signatorial => $tun->{'signatorial'} });
							push @{$batches}, $tun->{'batch_uuid'};
						}
					}
				}
			}
		}
	}
	&Websocket::send('server', { console => 'tunnelLister()' });
}

sub tunnel_port_mapper() {
	my $data = shift;
	my $ip = $data->{'ip'} || $data->{'domain'};
	my $direction = $data->{'direction'};
	my $host = $data->{'host'};
	my $signatorial = $data->{'signatorial'};
	my $tuns = {};

	my $tunnels = [];
	if ($signatorial) {
		$tunnels = &subs::db_select('tunnels', undef, { signatorial => $signatorial, status => 'active' })->hashes;
	}
	elsif ($host && $ip) {
		$tunnels = &subs::db_select('tunnels', undef, { host => $host, domain => $ip, status => 'active' })->hashes;
	}
	elsif ($host) {
		$tunnels = &subs::db_select('tunnels', undef, { host => $host, status => 'active' })->hashes;
	}
	else {
		$tunnels = &subs::db_select('tunnels', undef, { domain => $ip, status => 'active' })->hashes;
	}
	@{$tunnels} = grep { $_->{'direction'} eq $direction } @{$tunnels} if $direction;
	foreach my $t ( @{$tunnels} ) {
		$tuns->{$t->{'name'}} = $t->{'in_port'};
		$tuns->{'host'} = $t->{'host'};
		$tuns->{'last_updated'} = $tuns->{'server_time'} if $tuns->{'server_time'} > $tuns->{'last_updated'};
	}


	return $tuns;
}

sub tunnel_peer_connect() {
	my ($signatorial, $filename) = @_;
	return unless $signatorial;
	# The hub reaches a tunnelled peer through the hub-side port the tunnel
	# reserved (remote_device_connect rewrites the manager to that 127.0.0.1
	# port); the peer's own address still rides in the tunnel's host, so the
	# roster row keeps a name it can show. This is the "dialled in -> enrolled"
	# step: the data plane is up by the time this is called, so the peer answers
	# and remote_device_connect files (or refreshes) the roster row - the buttons,
	# the tunnel flag and the hub-side manager that remote_upgrade targets.
	#
	# The peer's /sesh_check only authenticates when it is handed a database to
	# open (a backup path, exactly what the Dev panel's Connect button sends), so
	# a filename is required - the caller gets one from the peer's own /gate
	# restore list. Without it the handshake answers unapproved and no row is filed.
	my $tuns = &subs::tunnel_port_mapper({ signatorial => $signatorial });
	my $ip = $tuns->{'host'} || '127.0.0.1';
	unless ($filename) {
		my $row = &subs::remote_machine_lister({ signatorial => $signatorial, limit => 1 });
		my $data = ref $row->{'data'} eq 'HASH' ? $row->{'data'} : (eval { decode_json($row->{'data'} || '{}') } || {});
		$filename = $data->{'database'};
	}
	my $enrollee = eval { &Manager::remote_device_connect({
		manager => 'https://127.0.0.1:' . ($tuns->{'PORT_AHOY'} || $ENV{PORT_AHOY}) . '/manager',
		filename => $filename,
		ip => $ip,
		port => $tuns->{'PORT_AHOY'},
		port_dock => $tuns->{'PORT_DOCK'},
		password => &subs::suds_grabber(),
		name => &subs::setting_grabber({ app => 'me', setting => 'my_name' }),
		timestamp => &subs::rightNow(),
		browser_tab_id => &subs::random_string_creator(22),
		browser_tab => &subs::random_string_creator(21),
		signatorial => $signatorial,
		tunnel => 'yes'
	}) };
	if ($enrollee && $enrollee->{'body'} && $enrollee->{'body'}->{'signatorial'}) {
		&subs::log_writer('tunnel peer connected ' . substr($signatorial, 0, 8));
	}
	return $enrollee;
}


# What device_scan does for a neighbour it finds on the LAN, done headlessly for a
# peer the hub holds a tunnel to: ask the peer's own /gate for its name, purpose,
# signatorial and restore list (its jawnos.enc backups), write them onto the
# neighbour row in this machine's own device address, then run the same handshake
# the Dev panel's Connect button does (remote_device_connect) so the roster row
# carries the buttons and hub-side manager. Without a browser nothing else does
# this for a tunnel, so the peer appeared in Dev with no name and no backup to
# restore from.
sub tunnel_peer_enrol {
	my ($signatorial) = @_;
	return unless $signatorial;
	my $tuns = &subs::tunnel_port_mapper({ signatorial => $signatorial });
	my $dock = $tuns->{'PORT_DOCK'};
	return unless $dock;
	my $hostname = `hostname`;
	chomp $hostname;
	my $me = &subs::db_select('devices', undef, { hostname => $hostname })->hashes->[0];
	return unless $me;
	# the neighbour row for this peer, if the naming pass has made one yet
	my $address = eval { decode_json $me->{'address'} } || {};
	my $entry;
	foreach my $nic ( keys %{$address} ) {
		foreach my $n ( @{$address->{$nic}->{'neigh'} || []} ) {
			if (($n->{'signatorial'} || '') eq $signatorial) { $entry = $n; last; }
		}
		last if $entry;
	}
	my $row = &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0];
	my $need_list = !($entry && $entry->{'restore_list'});
	my $need_connect = !($row && ($row->{'connection'} || '') eq 'active');
	return unless $need_list || $need_connect;
	my $filename;
	my $changed = 0;
	if ($need_list) {
		my $my_name = &subs::setting_grabber({ app => 'me', setting => 'my_name' });
		my $ua = Mojo::UserAgent->new();
		my $url = 'https://127.0.0.1:' . $dock . '/manager/gate?restore_list=' . ($config->{'start_dir'} || '')
			. '&neighbour=' . $hostname . '&my_name=' . $my_name . '&signatorial=' . &subs::signatorial_designer();
		my $res = eval { $ua->insecure(1)->get($url)->result };
		my $body = ($res && $res->is_success) ? eval { decode_json $res->body } : undef;
		if ($body && $body->{'signatorial'} && $entry) {
			$entry->{'name'} = $body->{'name'} if $body->{'name'};
			$entry->{'purpose'} = $body->{'purpose'} if $body->{'purpose'};
			$entry->{'signatorial'} = $body->{'signatorial'};
			$entry->{'restore_list'} = encode_json $body->{'restore_list'} if $body->{'restore_list'};
			&subs::db_update('devices', { address => encode_json $address }, { uuid => $me->{'uuid'} });
			$changed = 1;
		}
		# the backup path the peer's /sesh_check must be handed to open (prefer the
		# current snapshot) - the same file the Dev panel's Connect button sends
		if ($body && ref $body->{'restore_list'} eq 'ARRAY') {
			foreach my $b ( @{ $body->{'restore_list'} } ) {
				if (($b->{'archive'} || '') eq 'current') { $filename = $b->{'filename'}; last; }
			}
			$filename ||= $body->{'restore_list'}->[0]->{'filename'};
		}
	}
	my $enrollee;
	$enrollee = &subs::tunnel_peer_connect($signatorial, $filename) if $need_connect;
	$changed = 1 if $enrollee;
	# let the Dev panel show the peer appear (or its row fill in) live
	&Websocket::send('server', { console => 'deviceLister()' }) if $changed;
	return $enrollee;
}

sub system_monitor() {
	my $data = shift;
	my $device = &device_setter();
	$data->{'device'} = $device;
	$data->{'timestamp'} = &subs::rightNow();

	&subs::cache_set({ app => '__president', context => $data->{'timeout'} }, $data);
	my $remote_machines = &subs::db_query('select * from remote_machines where connection=?', 'active')->hashes;
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;

		foreach my $rm ( @{$remote_machines} ) {
			$rm = &Manager::remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
			my $params;

			foreach my $p ( keys %{$data} ) {
				$params .= $p . '=' . url_escape $data->{$p} . '&';
			}

			my $url = $rm->{'manager'} . '/manager/configure/system_monitor?' . $params;
			my $res = $rm->{'ua'}->post($url)->result;
		}
	}, { name => 'system monitor' });
}


# --- the vault ---------------------------------------------------------------
# The suds at rest, sealed to this machine's own key file (~/.house.key, which
# never rides the database, a backup, or a code sync). One row per machine, so
# a merged database still opens on every machine; a database that leaves this
# machine carries only sealed rows, worthless without the key file.
sub house_key {
	my $path = &home('~/.house.key');
	my $key = '';
	$key = read_file($path) if -e $path;
	$key =~ s/\s+//g if $key;
	unless ($key) {
		my $raw = '';
		if (open my $fh, '<', '/dev/urandom') {
			binmode $fh;
			read($fh, $raw, 32);
			close $fh;
		}
		$key = encode_base64($raw, '');
		write_file($path, $key . "\n");
		chmod 0600, $path;
	}
	return $key;
}

sub vault_read {
	my $device = &signatorial_designer();
	my $q = &db_query('select value, server_time from settings where app = ? and setting = ? and device = ? order by server_time desc limit 1', '__president', 'vault', $device);
	my $row = $q ? $q->hashes->[0] : undef;
	return unless $row && $row->{'value'};
	my $suds = &note_decrypter(&house_key(), $row->{'value'});
	return unless $suds;
	$suds =~ s/\s+$//;
	return ($suds, $row->{'server_time'});
}

sub vault_seed {
	my ($suds, $force) = @_;
	return unless $suds;
	$suds =~ s/\s+$//;
	return unless length $suds;
	my $device = &signatorial_designer();
	my $q = &db_query('select uuid from settings where app = ? and setting = ? and device = ? limit 1', '__president', 'vault', $device);
	my $row = $q ? $q->hashes->[0] : undef;
	return if $row && !$force;
	my $sealed = &note_encrypter(&house_key(), $suds);
	return unless $sealed;
	my $now = &rightNow();
	if ($row) {
		&db_update('settings', { value => $sealed, server_time => $now }, { uuid => $row->{'uuid'} });
	}
	else {
		&db_insert('settings', { app => '__president', setting => 'vault', device => $device, value => $sealed, timestamp => $now, server_time => $now });
	}
	return 1;
}

# A fingerprint of the suds, for the session: a session proves it was minted
# under the current key without ever carrying the key.
sub suds_id {
	my ($suds) = @_;
	return '' unless $suds;
	$suds =~ s/\s+$//;
	return &shorthand_name(md5_sum('suds:' . $suds), 12);
}

# Does this candidate unwrap the level-1 canary (the current password encrypted
# with itself)? That is the check authentication_passer always made, now usable
# on any candidate key.
sub suds_current {
	my ($suds) = @_;
	return 0 unless $suds;
	my $q = &db_select('security', ['credential'], { level => 1 });
	my $row = $q ? $q->hash : undef;
	my $credential = $row && $row->{'credential'};
	return 0 unless $credential;
	my $check = &subs::decrypter($suds, $credential);
	return 0 unless $check;
	return $check eq $suds ? 1 : 0;
}

# --- the door and the key -----------------------------------------------------
# The login password gets its own row (sealed with itself), apart from the level-1
# key canary, so a password change never re-keys the house: the key lives in the
# vault, the password only opens the door. On a machine that predates the door
# the two are still one thing; login_gate migrates it the first time it is used.
sub door_row {
	my $q = &db_select('security', ['uuid','credential'], { level => 'door' });
	return $q ? $q->hash : undef;
}

sub door_check {
	my ($typed) = @_;
	return 0 unless defined $typed && length $typed;
	my $row = &door_row();
	return 0 unless $row && $row->{'credential'};
	my $stored = &decrypter($typed, $row->{'credential'});
	return ($stored && !ref $stored && $stored eq $typed) ? 1 : 0;
}

sub door_set {
	my ($password) = @_;
	return 0 unless defined $password && length $password;
	my $sealed = &encrypter($password, $password);
	return 0 unless $sealed;
	my ($db,$database) = &database_grabber();
	my $now = &rightNow();
	&db_query('delete from security where level = ?', 'door');
	&db_insert('security', {
		level => 'door',
		credential => $sealed,
		database => $database,
		timestamp => $now,
		server_time => $now,
		uuid => &random_string_creator(30)
	});
	return 1;
}

# The login gate: (authorized, key). The key comes from this machine's vault;
# the password only has to open the door row. The house key itself is the root
# credential and opens the house in every state: with a door present it
# authorizes without touching the door, with no door it becomes the password,
# and a machine whose vault was lost heals its vault here. Neither password nor
# key ever travel in a session.
sub login_gate {
	my ($typed) = @_;
	return (0, undef) unless defined $typed && length $typed;
	my @vault = &vault_read();
	my $vault = $vault[0];
	if ($vault && &suds_current($vault)) {
		my $door = &door_row();
		if ($door) {
			return (1, $vault) if &door_check($typed);
			# the typed house key is stronger than any password: let it in and
			# leave the door exactly as it was
			return (&secure_compare($typed, $vault) ? (1, $vault) : (0, $vault));
		}
		if (&secure_compare($typed, $vault)) {
			&door_set($typed);
			return (1, $vault);
		}
		return (0, $vault);
	}
	if (&suds_current($typed)) {
		&vault_seed($typed, 1);
		&door_set($typed) unless &door_row();
		return (1, $typed);
	}
	return (0, undef);
}

# The pre-vault derivation: the newest active ticket carries a copy of the suds,
# wrapped with the ticket's own one-time key. Kept as the migration path.
sub legacy_suds {
	my $q = &db_query('select secret,password,suds,server_time from tickets where status = ? order by server_time desc limit 1', 'active');
	my $ticket = $q ? $q->hashes->[0] : undef;
	return unless $ticket && $ticket->{'suds'};
	my $secret = $ticket->{'secret'};
	my $ver = url_unescape `echo "$secret" | base64 --decode`;
	my $verification = &note_decrypter($ticket->{'password'}, $ver);
	my $vrai = eval { return decode_json $verification } || {};
	return unless $vrai->{'p'};
	my $suds = &note_decrypter($vrai->{'p'}, $ticket->{'suds'});
	return unless $suds;
	$suds =~ s/\s+$//;
	return ($suds, $ticket->{'server_time'});
}

# The suds, resolved server-side. Sessions carry only suds_id now; nothing a
# client holds can produce the key.
sub session_suds {
	my ($c) = @_;
	return $gb::suds if $gb::suds;
	return eval { &suds_grabber() };
}

# A machine whose vault is gone can ask a linked machine for the house key
# over the signed peer rail. The asker supplies a one-time secret; the donor
# seals the key to it (see /manager/vault_share), so the key never travels
# naked and a replayed answer is useless. Only a key the local canary accepts
# is handed back: machines holding different keys are a different problem.
sub vault_pull_one {
	my ($rm, $seal) = @_;
	my $manager = $rm->{'manager'};
	$manager = 'https://' . $rm->{'ip'} . ':' . ($rm->{'port'} || '45545') unless $manager;
	return unless $manager;
	my $ua = Mojo::UserAgent->new();
	$ua->max_response_size(0);
	$ua->insecure(1);
	# every request on the peer rail names this machine and carries a signature
	$ua->on(start => sub { my ($ua, $tx) = @_; &peer_sign_request($tx->req); });
	my $url = $manager . '/manager/vault_share?signatorial=' . &signatorial_designer() . '&seal=' . url_escape($seal);
	my $res = eval { $ua->inactivity_timeout(15)->get($url)->result };
	return unless $res && $res->is_success;
	my $json = eval { decode_json $res->body } || {};
	return unless $json->{'ok'} && $json->{'sealed'};
	my $suds = &note_decrypter($seal, $json->{'sealed'});
	$suds =~ s/\s+$// if $suds;
	return $suds;
}

sub vault_pull_from_peer {
	# once per five minutes per process; a keyless machine calls this on every
	# resolution, so it must not hammer the mesh
	my $opts = shift || {};
	my $now = &rightNow();
	return if $gb::vault_pull_last && $now - $gb::vault_pull_last < 300000;
	$gb::vault_pull_last = $now;
	my ($db) = &database_grabber();
	return unless $db;
	# a driver may name the peers it wants, so a probe never pulls a key from a
	# real machine (or counts a real machine's answer as the fixture's)
	my %only = map { $_ => 1 } @{ (ref $opts->{'only'} eq 'ARRAY') ? $opts->{'only'} : [] };
	my @peers = grep { ($_->{'signatorial'} || '') && ($_->{'manager'} || $_->{'ip'}) }
		grep { !(scalar keys %only) || $only{ $_->{'signatorial'} } }
		@{ &db_select('remote_machines')->hashes || [] };
	my @active = grep { ($_->{'connection'} || '') eq 'active' } @peers;
	my @rest = grep { ($_->{'connection'} || '') ne 'active' } @peers;
	@peers = (@active, @rest);
	splice @peers, 3;
	return unless scalar @peers;
	my $seal = &code_chars_make(40);
	foreach my $rm ( @peers ) {
		my $suds = eval { &vault_pull_one($rm, $seal) };
		return $suds if $suds;
	}
	return;
}

# --- rotation -----------------------------------------------------------------
# Replace the house key with a fresh random one. Everything the database seals is
# re-sealed in place: the vault, the level-1 canary, the security history (earlier
# oldkey wraps included), note-shaped and binary-shaped settings values, and the
# neighbour-link credentials. The old key is wrapped under the new one as an
# 'oldkey' security row, which the file and note paths consult when deriving
# candidate secrets - so content sealed before the rotation still opens. The
# recovery code sealed the old key and is set aside (recovery_stale). Sessions do
# not survive: every suds_id changes, so browsers re-admit themselves through
# their device keys. $target lets a caller supply the key instead of generating
# one: probes rotate back with it, and /manager/key_push adopts a peer's new
# key with it; the local rotation route never passes it.
# One stored value, re-sealed from one house key to another. Returns undef when
# the value is sealed with neither the current key nor the legacy empty
# passphrase; the new sealed value otherwise. The unwrap is exact - Crypt::Simple
# checks its own digest and refuses a key that did not seal the value - so a
# value's bytes are proven, not guessed (its output is base64, so a shape test
# would say nothing). A note carries ':::---:::' inside that outer layer, and its
# own openssl layer is keyed to the real secret: it is remade whole, since
# re-wrapping only the outer layer would not open later. Values from the era when
# encrypter sealed under the empty passphrase are upgraded too - that key is
# public knowledge, so leaving them is leaving them readable to anyone holding a
# copy of the database.
sub crypt_simple_unwrap {
	my ($secret, $v) = @_;
	local *encrypt;
	local *decrypt;
	Crypt::Simple->import(passphrase => $secret);
	my $plain = eval { decrypt($v) };
	return $plain;
}

sub rotation_reseal_value {
	my ($v, $K, $Knew) = @_;
	return unless defined $v && length $v && $K && $Knew;
	my $inner = &crypt_simple_unwrap($K, $v);
	$inner = &crypt_simple_unwrap('', $v) unless defined $inner;
	return unless defined $inner;
	return &reseal_unwrapped_value($inner, $v, $K, $Knew);
}

# The half both re-seal sweeps share: the outer layer is already unwrapped, so
# this decides note or plain blob and hands back the value sealed under $Knew.
# A note carries ':::---:::' inside that outer layer, and its own openssl layer
# is keyed to the real secret ($K reaches a legacy note's inner layer through
# note_decrypter's own fallback), so it is remade whole - re-wrapping only the
# outer layer would not open later.
sub reseal_unwrapped_value {
	my ($inner, $v, $K, $Knew) = @_;
	if (index($inner, ':::---:::') >= 0) {
		my $plain = &note_decrypter($K, $v);
		return unless defined $plain && length $plain;
		my $re = &note_encrypter($Knew, $plain);
		return unless $re && &note_decrypter($Knew, $re) eq $plain;
		return $re;
	}
	my $re = &encrypter($Knew, $inner);
	return unless $re && &decrypter($Knew, $re) eq $inner;
	return $re;
}

# The standalone form of the rotation's legacy side effect: re-seal one value
# still locked by the empty-passphrase era and leave everything else exactly
# alone (a value already under $K reports back as undefined, so nothing is ever
# rewritten for nothing).
sub legacy_reseal_value {
	my ($v, $K) = @_;
	return unless defined $v && length $v && $K;
	return if defined &crypt_simple_unwrap($K, $v);
	my $inner = &crypt_simple_unwrap('', $v);
	return unless defined $inner;
	return &reseal_unwrapped_value($inner, $v, $K, $K);
}

sub rotate_house_key {
	my ($target) = @_;
	my $K = &suds_grabber();
	return { ok => 0, error => 'no key on this machine' } unless $K;
	my $Knew = $target || &code_chars_make(40);
	return { ok => 0, error => 'the new key is the old key' } if $Knew eq $K;
	my $canary = &encrypter($Knew, $Knew);
	my $wrapped = &encrypter($Knew, $K);
	my $sealed = &note_encrypter(&house_key(), $Knew);
	return { ok => 0, error => 'the new key would not seal' } unless $canary && $wrapped && $sealed;
	my ($db,$database) = &database_grabber();
	return { ok => 0, error => 'no database' } unless $db;
	my $now = &rightNow();
	my $counts = { settings => 0, security => 0, links => 0 };

	# The key material moves first, and remote_duty with it: every worker
	# re-resolves on its next settings write, so a write during the sweep below
	# seals under the new key instead of landing in the old one. The old key is
	# wrapped under the new one before anything is swept, so even a sweep cut
	# short leaves every pre-rotation value one way or another reachable.
	&vault_seed($Knew, 1);
	&db_query('update security set credential = ? where level = 1', $canary);
	&db_insert('security', { level => 'oldkey', credential => $wrapped, database => $database, timestamp => $now, server_time => $now });
	$gb::suds = $Knew;
	&setting_setter({ app => '__president', setting => 'remote_duty', value => $now });

	# settings: every value that proves its seal is re-sealed (see
	# rotation_reseal_value); a handful of API keys and blobs usually pass, but
	# the sweep must find them all
	my $settings = &db_select('settings', ['rowid','setting','value'], {})->hashes;
	foreach my $row ( @{$settings} ) {
		my $re = &rotation_reseal_value($row->{'value'}, $K, $Knew);
		next unless defined $re;
		&db_update('settings', { value => $re }, { rowid => $row->{'rowid'} });
		$counts->{settings}++;
	}

	# security: apart from the canary and the door, every credential that
	# proves its seal is re-sealed; the history keeps each layer one decrypt
	# away from the live key. Padlock and door hold no key material.
	my $secs = &db_select('security', ['rowid','level','credential'], {})->hashes;
	foreach my $row ( @{$secs} ) {
		next if $row->{'level'} eq 'padlock' || $row->{'level'} eq 'door' || $row->{'level'} eq '1';
		my $re = &rotation_reseal_value($row->{'credential'}, $K, $Knew);
		next unless defined $re;
		&db_update('security', { credential => $re }, { rowid => $row->{'rowid'} });
		$counts->{security}++;
	}

	# neighbour-link credentials (the mesh's stored secrets)
	my $links = &db_select('neighbour_link', ['rowid','credential'], {})->hashes;
	foreach my $row ( @{$links} ) {
		my $re = &rotation_reseal_value($row->{'credential'}, $K, $Knew);
		next unless defined $re;
		&db_update('neighbour_link', { credential => $re }, { rowid => $row->{'rowid'} });
		$counts->{links}++;
	}

	# the recovery code sealed the old key; it is set aside with the note to
	# write down a new one
	my $recovery = &db_select('settings', ['rowid'], { app => '__president', setting => 'recovery' })->hashes;
	if (scalar @{$recovery}) {
		&db_delete('settings', { app => '__president', setting => 'recovery' });
		&db_delete('settings', { app => '__president', setting => 'recovery_stale' });
		&db_insert('settings', { app => '__president', setting => 'recovery_stale', device => 'all', value => 'key_rotation', timestamp => $now, server_time => $now });
	}
	return { ok => 1, at => $now, key_id => &suds_id($Knew), old_key_id => &suds_id($K), settings => $counts->{settings}, security => $counts->{security}, links => $counts->{links} };
}

# --- legacy seals -------------------------------------------------------------
# A sweep for values left from the era when encrypter sealed the outer layer
# under the empty passphrase (md5(''), public knowledge): out in the open to
# anyone holding a copy of the database. Unlike rotation this changes no key -
# each value is upgraded to the key this machine already holds - so it is safe
# on any machine at any time, idempotent, and cheap where none are left. The
# mesh form asks every linked machine to run its own, over the signed peer
# rail: nothing secret crosses, only signatures.
sub legacy_reseal {
	my $K = &suds_grabber();
	return { ok => 0, error => 'no key on this machine' } unless $K;
	my $counts = { settings => 0, security => 0, links => 0 };
	my $settings = &db_select('settings', ['rowid','setting','value'], {})->hashes;
	foreach my $row ( @{$settings} ) {
		my $re = &legacy_reseal_value($row->{'value'}, $K);
		next unless defined $re;
		&db_update('settings', { value => $re }, { rowid => $row->{'rowid'} });
		$counts->{settings}++;
	}
	# padlock and door hold no key material (upgrading the door would break it:
	# it must keep opening with the typed password alone); level 1 is the canary,
	# which has its own reseal - the same filter rotation uses
	my $secs = &db_select('security', ['rowid','level','credential'], {})->hashes;
	foreach my $row ( @{$secs} ) {
		next if $row->{'level'} eq 'padlock' || $row->{'level'} eq 'door' || $row->{'level'} eq '1';
		my $re = &legacy_reseal_value($row->{'credential'}, $K);
		next unless defined $re;
		&db_update('security', { credential => $re }, { rowid => $row->{'rowid'} });
		$counts->{security}++;
	}
	my $links = &db_select('neighbour_link', ['rowid','credential'], {})->hashes;
	foreach my $row ( @{$links} ) {
		my $re = &legacy_reseal_value($row->{'credential'}, $K);
		next unless defined $re;
		&db_update('neighbour_link', { credential => $re }, { rowid => $row->{'rowid'} });
		$counts->{links}++;
	}
	return { ok => 1, settings => $counts->{settings}, security => $counts->{security}, links => $counts->{links} };
}

# Ask one linked machine to upgrade its own legacy values (its route runs the
# same local sweep) and hand back the counts. A machine that has not caught up
# with this code yet simply fails to answer.
sub legacy_reseal_peer_one {
	my ($rm) = @_;
	return unless $rm && $rm->{'signatorial'};
	my $manager = $rm->{'manager'};
	$manager = 'https://' . $rm->{'ip'} . ':' . ($rm->{'port'} || '45545') unless $manager;
	return unless $manager;
	my $ua = Mojo::UserAgent->new();
	$ua->max_response_size(0);
	$ua->insecure(1);
	$ua->on(start => sub { my ($ua, $tx) = @_; &peer_sign_request($tx->req); });
	my $url = $manager . '/manager/legacy_reseal?signatorial=' . &signatorial_designer();
	my $res = eval { $ua->inactivity_timeout(15)->get($url)->result };
	return unless $res && $res->is_success;
	my $json = eval { decode_json $res->body };
	return unless $json && $json->{'ok'};
	return $json;
}

sub legacy_reseal_mesh {
	my $me = &signatorial_designer();
	my $rms = &db_select('remote_machines')->hashes || [];
	my $summary = { asked => 0, ok => 0, failed => 0, upgraded => 0 };
	foreach my $rm ( @{$rms} ) {
		my $rsig = $rm->{'signatorial'};
		next unless $rsig && $rsig ne $me;
		next unless $rm->{'manager'} || $rm->{'ip'};
		$summary->{asked}++;
		my $got = eval { &legacy_reseal_peer_one($rm) };
		if ($got) {
			$summary->{ok}++;
			$summary->{upgraded} += ($got->{'settings'} || 0) + ($got->{'security'} || 0) + ($got->{'links'} || 0);
		}
		else { $summary->{failed}++; }
	}
	return $summary;
}

sub suds_grabber {
	my $duty_time = &subs::setting_grabber({ app => '__president', setting => 'remote_duty' });
	if (( !$gb::suds || $duty_time eq '' || !$duty_time || $duty_time != $gb::duty_time || !$gb::duty_time)) {
		my ($vault) = &vault_read();
		my ($legacy) = &legacy_suds();
		my $suds;
		if ($vault && &suds_current($vault)) {
			# the steady state: this machine's vault holds the current key
			$suds = $vault;
		}
		elsif ($legacy && &suds_current($legacy)) {
			# the first boot, or a key change made elsewhere: a ticket minted
			# under the current password wins and the vault is resealed to it
			$suds = $legacy;
			&vault_seed($suds, 1);
		}
		else {
			# nothing local validates: a linked machine can hand the key over
			# (sealed to a one-time secret, over the signed peer rail)
			my $pulled = eval { &vault_pull_from_peer() };
			if ($pulled && &suds_current($pulled)) {
				$suds = $pulled;
				&vault_seed($suds, 1);
			}
			elsif ($vault || $legacy) {
				# no canary to judge by: keep the best thing this machine has
				$suds = $vault || $legacy;
				&vault_seed($suds, 1) unless $vault;
			}
		}
		if ($suds) {
			&subs::setting_setter({ app => '__president', setting => 'remote_duty', value => $gb::duty_time });
			$gb::suds = $suds;
			return $suds;
		}
		return $gb::suds;
	}
	return $gb::suds;
}

# --- peer keys ---------------------------------------------------------------
# Every machine gets an Ed25519 keypair at first use (~/.peer.key, 0600, never
# in the database or a code sync). Requests between machines carry a timestamp,
# a nonce and a signature over method and path; once a peer's key is on file an
# unsigned request is refused, so a leaked address, cookie or signatorial is no
# longer enough to pull a backup or push code. The first verified contact pins
# the offered key to the peer's row (trust on first use).
sub peer_key_paths {
	my $key = &home('~/.peer.key');
	my $pub = &home('~/.peer.pub');
	unless (-e $key && -s $key > 0) {
		`openssl genpkey -algorithm ED25519 -out "$key" 2>/dev/null`;
		chmod 0600, $key;
	}
	unless (-e $pub && -s $pub > 0) {
		`openssl pkey -in "$key" -pubout -out "$pub" 2>/dev/null`;
	}
	return ($key, $pub);
}

sub peer_pubkey {
	my ($key, $pub) = &peer_key_paths();
	return unless -e $pub;
	return read_file($pub);
}

sub peer_sign_message {
	my ($method, $path_query, $ts, $nonce) = @_;
	return join "\n", ($method // ''), ($path_query // ''), ($ts // ''), ($nonce // '');
}

# Name this machine and sign the request it is about to make. Attached to a
# peer user agent's start event, so every request on that rail is signed.
# The signing dance writes throwaway files (a message, a signature, a public
# key). They live in the app's own state dir on fresh File::Temp names, not on
# /tmp under a pseudo-random name: a phone without shred leaves /tmp names
# behind, and a leftover file the process cannot truncate turned every signed
# request into a 500 (Fe, found over the mesh), while a world-writable /tmp
# also lets a local name be pre-made as a symlink to clobber.
sub peer_temp_file {
	my ($tag) = @_;
	my $dir = &home('~/.president');
	unless (-d $dir) {
		eval { File::Path::make_path($dir) };
	}
	$dir = '/tmp' unless -d $dir;
	require File::Temp;
	my ($fh, $path) = File::Temp::tempfile('peer_' . ($tag || 'tmp') . '_XXXXXXXX', DIR => $dir, UNLINK => 0);
	close $fh if $fh;
	return $path;
}

sub peer_sign_request {
	my ($req) = @_;
	my ($key) = &peer_key_paths();
	return unless -e $key && -s $key > 0;
	# Time::HiRes overrides time() here, so whole seconds must be asked for:
	# the verifier reads the header back with /^\d+$/ and a fractional stamp
	# (1791953166.531) was refused on every hook-signed request.
	my $ts = int(time());
	my $nonce = &random_string_creator(24);
	my $msg_file = &peer_temp_file('sign_msg');
	my $sig_file = &peer_temp_file('sign_sig');
	write_file($msg_file, &peer_sign_message($req->method, $req->url->path_query, $ts, $nonce));
	`openssl pkeyutl -sign -inkey "$key" -rawin -in "$msg_file" -out "$sig_file" 2>/dev/null`;
	my $sig = (-s $sig_file) ? read_file($sig_file) : '';
	my $pub = &peer_pubkey();
	if ($sig && $pub) {
		$req->headers->header('X-Peer-Timestamp', $ts);
		$req->headers->header('X-Peer-Nonce', $nonce);
		$req->headers->header('X-Peer-Signature', encode_base64($sig, ''));
		$req->headers->header('X-Peer-Key', encode_base64($pub, ''));
	}
	unlink $msg_file, $sig_file;
	return 1;
}

# The server half: is this request really from the peer it claims, and has it
# not been seen before? Unsigned requests pass only while the peer has no key on
# file yet, so machines upgrade without a flag day; once pinned, only a fresh
# valid signature from the holder of the private key gets through.
sub peer_verify {
	my ($c, $rm) = @_;
	return 0 unless $rm && $rm->{'signatorial'};
	my $stored = $rm->{'pubkey'} // '';
	my $ts = $c->req->headers->header('X-Peer-Timestamp');
	my $nonce = $c->req->headers->header('X-Peer-Nonce');
	my $b64sig = $c->req->headers->header('X-Peer-Signature');
	my $b64key = $c->req->headers->header('X-Peer-Key');
	# unsigned: fine only while this peer has no key on file yet
	return ($stored ? 0 : 1) unless $ts || $nonce || $b64sig;
	return 0 unless $ts && $ts =~ /^\d+$/ && abs(time() - $ts) <= 600;
	return 0 unless $nonce && $nonce =~ /^[A-Za-z0-9]{8,64}$/;
	my $pubkey = $stored;
	$pubkey = eval { decode_base64 $b64key } if (!$pubkey && $b64key);
	return 0 unless $pubkey && index($pubkey, '-----BEGIN PUBLIC KEY-----') == 0;
	my $sig = eval { decode_base64 $b64sig } || '';
	return 0 unless length $sig;
	my $stamp = $rm->{'signatorial'} . ':' . $nonce;
	my $q = &db_query('select server_time from cache where context = ? and uuid = ? limit 1', 'peer_nonce', $stamp);
	my $seen = $q ? $q->hashes->[0] : undef;
	return 0 if $seen && $seen->{'server_time'};
	my $msg_file = &peer_temp_file('verify_msg');
	my $sig_file = &peer_temp_file('verify_sig');
	my $key_file = &peer_temp_file('verify_pub');
	write_file($msg_file, &peer_sign_message($c->req->method, $c->req->url->path_query, $ts, $nonce));
	write_file($sig_file, $sig);
	write_file($key_file, $pubkey);
	my $ok = system("openssl pkeyutl -verify -pubin -inkey \"$key_file\" -rawin -in \"$msg_file\" -sigfile \"$sig_file\" >/dev/null 2>&1") == 0;
	unlink $msg_file, $sig_file, $key_file;
	return 0 unless $ok;
	# the nonce is spent; the first verified contact pins the offered key
	&db_query('delete from cache where context = ? and uuid = ?', 'peer_nonce', $stamp);
	&db_query('insert into cache (uuid, context, app, server_time, timestamp) values (?,?,?,?,?)', $stamp, 'peer_nonce', '__president', &rightNow(), &rightNow());
	unless ($stored) {
		&db_update('remote_machines', { pubkey => $pubkey }, { uuid => $rm->{'uuid'} });
	}
	return 1;
}

# Verify an Ed25519 signature (base64) over a message against a PEM public key.
# The shared primitive behind peer_verify and the paired-device challenge.
sub signature_verify {
	my ($pubkey, $msg, $b64sig) = @_;
	return 0 unless $pubkey && index($pubkey, '-----BEGIN PUBLIC KEY-----') == 0;
	my $sig = eval { decode_base64 $b64sig } || '';
	return 0 unless length $sig;
	my $msg_file = &peer_temp_file('device_msg');
	my $sig_file = &peer_temp_file('device_sig');
	my $key_file = &peer_temp_file('device_pub');
	write_file($msg_file, $msg);
	write_file($sig_file, $sig);
	write_file($key_file, $pubkey);
	my $ok = system("openssl pkeyutl -verify -pubin -inkey \"$key_file\" -rawin -in \"$msg_file\" -sigfile \"$sig_file\" >/dev/null 2>&1") == 0;
	unlink $msg_file, $sig_file, $key_file;
	return $ok ? 1 : 0;
}

# --- the recovery code --------------------------------------------------------
# The paper code: eight groups of five from Crockford's alphabet (no I, L, O or
# U to mistype). Verification is the decryption itself - the code unwraps a copy
# of the suds sealed to it - so the house keeps no hash, only the sealed blob.
# n characters from Crockford's alphabet, straight from /dev/urandom: the house
# key material of the recovery code, and the short codes humans compare. Perl's
# rand (predictable, and inherited by forked workers) is not good enough. Each
# byte mod 32 is uniform: 256 divides by 32.
sub code_chars_make {
	my ($n) = @_;
	my $chars = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
	my $raw = '';
	if (open my $fh, '<', '/dev/urandom') {
		binmode $fh;
		my $bytes = '';
		read($fh, $bytes, $n);
		close $fh;
		$raw = join '', map { substr($chars, ord($_) % 32, 1) } split '', $bytes if length($bytes) == $n;
	}
	unless (length($raw) == $n) {
		# a last resort only: stretch everything weak we have through md5
		my $seed = join '|', ($$, time, &random_string_creator($n));
		my $hex = '';
		$hex .= md5_sum($seed . $hex) for (1 .. int($n / 8) + 1);
		$raw = join '', map { substr($chars, hex($_), 1) } split '', substr($hex, 0, $n);
	}
	return $raw;
}

sub recovery_code_make {
	my $raw = &code_chars_make(40);
	my @groups = $raw =~ /.{5}/g;
	return join '-', @groups;
}

# the approval code: short enough to compare across two screens
sub device_request_code {
	my $raw = &code_chars_make(6);
	return substr($raw, 0, 3) . '-' . substr($raw, 3, 3);
}

sub recovery_code_clean {
	my ($code) = @_;
	return '' unless defined $code;
	$code = uc $code;
	$code =~ s/[^0-9A-Z]+//gi;
	$code =~ tr/ILO/110/;
	return $code;
}

sub c_maker() {
	my $c = &subs::controller_builder();
	&subs::suds_grabber();

	$c->session('server_time' => &subs::rightNow());
	$c->session('authentication' => 'approved');

	return $c;
}

# ---- OAuth2 for mail accounts ------------------------------------------------
# Outlook and Gmail no longer accept a plain password over IMAP or SMTP. An
# account can be marked auth=oauth2 instead: the house runs the OAuth 2.0 device
# authorization grant - it shows a short code, the person approves it at the
# provider, and the refresh token is kept (sealed) to mint access tokens after.
# The access token rides XOAUTH2 for both IMAP and SMTP. A plain-password account
# is untouched: every branch below only fires when auth is exactly 'oauth2'.

# The OAuth2 clients the house can sign in with: one entry per app registration
# (a name, a provider, a client id and secret, a tenant and scopes), kept as a
# setting so it syncs and so several accounts can share the one registration. The
# secret is sealed like a mail password.
sub oauth_clients {
	my $raw = &setting_grabber({ app => 'mail', setting => 'oauth_clients' });
	my $list = eval { &decode_json($raw) } || [];
	return [ grep { ref $_ eq 'HASH' } @{$list} ];
}
sub oauth_clients_store {
	my ($list) = @_;
	&setting_setter({ app => 'mail', setting => 'oauth_clients', value => encode_json($list) });
}
sub oauth_client {
	my ($uuid) = @_;
	return {} unless length($uuid || '');
	my ($cli) = grep { ($_->{'uuid'} || '') eq $uuid } @{ &oauth_clients() };
	return $cli || {};
}

# An account may name a registered client instead of carrying its own id/secret/
# tenant; this lays the client's fields over the account's, so every caller goes
# on reading the same keys.
sub email_oauth_overlay {
	my ($es) = @_;
	my $cli = &oauth_client($es->{'oauth_client'});
	return $es unless %{$cli};
	my %x = %{$es};
	$x{'oauth_provider'} = $cli->{'provider'} if length($cli->{'provider'} || '');
	$x{'oauth_client_id'} = $cli->{'client_id'} if length($cli->{'client_id'} || '');
	$x{'oauth_client_secret'} = $cli->{'client_secret'} if length($cli->{'client_secret'} || '');
	$x{'oauth_tenant'} = $cli->{'tenant'} if length($cli->{'tenant'} || '');
	$x{'oauth_scope'} = $cli->{'scope'} if length($cli->{'scope'} || '');
	return \%x;
}

sub email_oauth_endpoints {
	my ($es) = @_;
	my $provider = $es->{'oauth_provider'} || 'microsoft';
	my $tenant = $es->{'oauth_tenant'} || 'common';
	if ($provider eq 'google') {
		return {
			device => 'https://oauth2.googleapis.com/device/code',
			token  => 'https://oauth2.googleapis.com/token',
			scope  => ($es->{'oauth_scope'} || 'https://mail.google.com/'),
			secret => 1,
		};
	}
	return {
		device => "https://login.microsoftonline.com/$tenant/oauth2/v2.0/devicecode",
		token  => "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token",
		scope  => ($es->{'oauth_scope'} || 'offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send'),
		secret => 0,
	};
}

sub email_oauth_plain {
	my ($es, $key, $suds) = @_;
	return '' unless length($es->{$key} || '');
	return &note_decrypter($suds || &suds_grabber(), $es->{$key});
}

sub email_oauth_http {
	my ($url, $form) = @_;
	require HTTP::Tiny;
	my $ua = HTTP::Tiny->new(timeout => 30);
	my $res = eval { $ua->post_form($url, $form) };
	return { error => 'http', error_description => 'request failed: ' . ($@ || '') } unless $res;
	my $json = eval { decode_json $res->{'content'} };
	return $json if ref $json eq 'HASH';
	return { error => 'http', error_description => ($res->{'status'} || '') . ' ' . ($res->{'reason'} || '') };
}

# Write fields back onto one account in the email_config setting.
sub email_server_update {
	my ($uuid, $fields) = @_;
	my $servers = eval { &decode_json(&setting_grabber({ app => 'mailbox', setting => 'email_config' })) } || [];
	foreach my $es ( @{$servers} ) {
		next unless ($es->{'uuid'} || '') eq $uuid;
		$es->{$_} = $fields->{$_} for keys %{$fields};
	}
	&setting_setter({ app => 'mailbox', setting => 'email_config', value => encode_json($servers) });
	return $servers;
}

sub email_oauth_store {
	my ($es, $r, $suds) = @_;
	return unless $es->{'uuid'};
	my %up = ( oauth_expires => time() + (($r->{'expires_in'} || 3600) - 30) );
	$up{'oauth_access_token'} = &note_encrypter($suds, $r->{'access_token'}) if length($r->{'access_token'} || '');
	$up{'oauth_refresh_token'} = &note_encrypter($suds, $r->{'refresh_token'}) if length($r->{'refresh_token'} || '');
	&email_server_update($es->{'uuid'}, \%up);
	$es->{$_} = $up{$_} for keys %up;
	return 1;
}

# A live access token for the account: the one held if it is still good, else a
# fresh one minted from the refresh token.
sub email_oauth_token {
	my ($es, $suds) = @_;
	$es = &email_oauth_overlay($es);
	$suds = &suds_grabber() unless $suds;
	my $end = &email_oauth_endpoints($es);
	my $access = &note_decrypter($suds, $es->{'oauth_access_token'} || '');
	return $access if length $access && ($es->{'oauth_expires'} || 0) > time() + 60;
	my $refresh = &note_decrypter($suds, $es->{'oauth_refresh_token'} || '');
	return '' unless length $refresh;
	my %form = ( grant_type => 'refresh_token', refresh_token => $refresh, client_id => ($es->{'oauth_client_id'} || '') );
	my $secret = &email_oauth_plain($es, 'oauth_client_secret', $suds);
	$form{'client_secret'} = $secret if length $secret;
	my $r = &email_oauth_http($end->{'token'}, \%form);
	return '' unless length($r->{'access_token'} || '');
	&email_oauth_store($es, $r, $suds);
	return $r->{'access_token'};
}

# Log an IMAP connection in, by XOAUTH2 for an oauth2 account or by password
# otherwise. The SASL initial response rides as an IMAP literal, which is what the
# continuation the server answers is for.
sub email_imap_login {
	my ($imap, $es, $token) = @_;
	if (($es->{'auth'} || '') eq 'oauth2') {
		my $ir = 'user=' . $es->{'email'} . "\x01auth=Bearer $token\x01\x01";
		my ($ok) = $imap->_tell_imap('AUTHENTICATE', [ 'XOAUTH2 ', \$ir ]);
		return $ok ? 1 : 0;
	}
	return $imap->login;
}

sub email_receiver() {
	my $receive_type = shift;
	if ($receive_type eq 'auto') {
		my $signatorial = &subs::signatorial_designer();
		my $auto_receive = &subs::setting_grabber({ app => 'mailbox', setting => 'email_auto_receive' });
		if ($auto_receive ne &subs::device_setter() && $auto_receive ne $signatorial) {
			return;
		}
	}

	require Net::IMAP::Client;
	require MIME::Parser;
	require Authen::SASL;

	my $c = &subs::controller_builder();
	my $email_servers = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	@{$email_servers} = grep { $_->{'active'} eq 'on' } @{$email_servers};

	foreach my $es ( @{$email_servers} ) {

		my $oauth2 = (($es->{'auth'} || '') eq 'oauth2') ? 1 : 0;
		my $password = $oauth2 ? '' : &subs::note_decrypter(&subs::suds_grabber(), $es->{'password'});
		$es->{'status'} = 'failed';
		my $imap = Net::IMAP::Client->new(
			server => $es->{'imap_server'},
			user   => $es->{'email'},
			pass   => $password,
			ssl    => $es->{'imap_encryption'} eq 'SSL' ? 1 : 0,
			tls    => 0,
			ssl_verify_peer => 1,                     # (use ca to verify server, default yes)
#		  ssl_ca_file => '/etc/ssl/certs/certa.pm', # (CA file used for verify server) or
			ssl_ca_path => '/etc/ssl/certs/',         # (CA path used for SSL)
			port   => $es->{'imap_port'}                             # (but defaults are sane)
		) or next;
		if ($oauth2) {
			my $token = &subs::email_oauth_token($es);
			next unless length $token;
			&subs::email_imap_login($imap, $es, $token) or next;
		}
		else {
			$imap->login or next;
		}

		$es->{'status'} = 'success';
		$es->{'last_login'} = &subs::rightNow();
		my @folders = $imap->folders;
		$es->{'folders'} = {} unless $es->{'folders'};
		foreach my $f ( @folders ) {
			next if $es->{'folders'}->{$f};
			$es->{'folders'}->{$f} = {};
		}
		foreach my $f ( keys %{$es->{'folders'}} ) {
			delete $es->{'folders'}->{$f} unless grep { $f eq $_ } @folders;
			if ($es->{'folders'}->{$f}->{'retrieve'} eq 'on') {
				$imap->select($f);
				my $status = $imap->status($f); # hash ref!

				my $sep = $imap->separator;
				my $messages = $imap->search('ALL');
				my $summaries = $imap->get_summaries([ @{$messages} ]);
				foreach my $sum (@$summaries) {

					my $from = $sum->from->[-1];
					my @ea1 = split ' ', $from;
					$from = $ea1[-1];
					$from =~ /<([^>]+)>/;
					$from = $1;
					my $to = $sum->to->[-1];
					my @ea = split ' ', $to;
					$to = $ea[-1];
					$to =~ /<([^>]+)>/;
					$to = $1;
					# carbon copies, so a letter that was copied to others can show it
					my @cc;
					if ($sum->can('cc')) {
						foreach my $c ( @{ $sum->cc || [] } ) {
							my $addr = $c;
							$addr = $1 if $addr =~ /<([^>]+)>/;
							push @cc, $addr if $addr;
						}
					}
					my $cc = join(', ', @cc);
					my $subject = $sum->subject;
					my $checked_addresses = &subs::db_query('select * from settings where setting=? and (value=? or value=? and value != ?) and device=?', 'email', $from, $to, $es->{'email'}, $device)->hashes;
					# an address a person keeps in the typed list (their work mailbox, say)
					# names them too: fold those apps in before the loop, once each
					my %known_recipient = map { $_->{'app'} => 1 } @{$checked_addresses};
					foreach my $address ( $from, $to ) {
						next unless $address;
						foreach my $ca_app ( &subs::contact_apps('email', $address) ) {
							next if $known_recipient{$ca_app}++;
							push @{$checked_addresses}, { app => $ca_app };
						}
					}
					# Nobody the house knows sent this: the letter still comes in, and its
					# attachments wait in the unclaimed pool (a month to claim) rather than
					# being dropped with the parse.
					if (!scalar @{$checked_addresses} && $to eq $es->{'email'} && lc $f ne 'drafts') {
						push @{$checked_addresses}, { app => 'camera', unclaimed => 1 };
					}
					foreach my $ca ( @{$checked_addresses} ) {
						# check for appointments
						my $timestamp = &subs::ago_calc($sum->date,&subs::rightNow());
						my $appts = &subs::db_query('select * from appointments where app=? and timestamp=? and type=?', $ca->{'app'}, $timestamp, 'email')->hashes;
						next if scalar @{$appts} > 0;


						my $body;
						my $part_ref = $imap->get_part_body($sum->uid, '1.3');
						my $parts = $imap->get_parts_bodies($sum->uid, [ '1.1', '1.2', '2.1' ]);
						my $msg_string = $imap->get_rfc822_body($sum->uid);

						my $parser = MIME::Parser->new;
						$parser->output_dir($gb::tmp_dir);
						my $entity = $parser->parse_data($msg_string);
						my $bodyfile = $entity->bodyhandle;
						# the message headers a real thread is built from
						my $hdr = sub { my $v = $entity->head->get($_[0]); $v = '' unless defined $v; $v =~ s/^\s+|\s+$//g; return $v; };
						my $h_message_id = $hdr->('Message-ID');
						my $h_in_reply_to = $hdr->('In-Reply-To');
						my $h_references = $hdr->('References');
						# the chain's root id names the thread: the first id it references, else
						# what it answers, else its own id
						my $h_thread = '';
						my @chain = ($h_references =~ /(<[^>]+>)/g);
						$h_thread = $chain[0] if @chain;
						$h_thread = $h_in_reply_to unless length $h_thread;
						$h_thread = $h_message_id unless length $h_thread;

						my ($plain_text,$html_text) = ("","");
						foreach my $part ($entity->parts_DFS) {
							# Get the MIME type (e.g., 'text/plain', 'text/html')
							my $content_type = $part->effective_type;

							# Check if a body exists for this part
							if (my $body_handle = $part->bodyhandle) {
								if ($content_type eq 'text/plain') {
									$plain_text .= $body_handle->as_string;
								}
								elsif ($content_type eq 'text/html') {
									$html_text .= $body_handle->as_string;
									my $hs = HTML::Strip->new(
										striptags   => [ 'iframe','script' ],
										emit_spaces => 0
									);
									$body = $hs->parse( $html_text );

								}
							}
						}

						$body = $html_text ne "" ? $html_text : $plain_text;


						my $files = [];
						# the uuid the mailbox row will wear, so the appointment and its
						# files can point back at the very message
						my $mailbox_uuid = &subs::random_string_creator(44);
						foreach my $part ($entity->parts) {

							my $filename = $part->head->recommended_filename;
							if ($filename) {


								my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $filename, app => $ca->{'app'}, is_thumb => 0 });
								copy($gb::tmp_dir . '/' . $filename, $destination . $asset);
								my $u_data = { server_time => &subs::rightNow(), f => $destination . $asset, uuid => &subs::random_string_creator(28), type => $type, mail_uuid => $mailbox_uuid };
								my $thumb = $destination . '/thumbs';
								if ($type eq 'image') {
									`mkdir -p $thumb` unless -e $thumb;
									$u_data->{'thumb'} = $thumb . '/' . $asset;

								}
								push @{$files}, $u_data;

							}
						}
						my $status = 'inbox';
						my $email = $from;
						if ($to ne $es->{'email'}) {
							$status = 'sent';
							$email = $to;
						} elsif (lc $f eq 'drafts') {
							$status = 'draft';
						}
						my $app_uuid = &subs::random_string_creator(31);
						my $jfile = scalar @{$files} > 0 ? encode_json $files : undef;
						# the appointment wears the mailbox row's uuid and the address the
						# conversation is with, so the envelope in the details can open the
						# very message
						my $appt_data = {
							app => $ca->{'app'},
							type => 'email',
							timestamp => $timestamp,
							notes => &subs::note_encrypter(&subs::suds_grabber(), $body),
							file => $jfile,
							data => encode_json({ mail_uuid => $mailbox_uuid, email => $email })
						};
						# an unknown sender's letter lands in the unclaimed pool, which expires
						# after a month if nobody claims it onto an appointment
						if ($ca->{'unclaimed'}) {
							$appt_data->{'source'} = 'unclaimed';
							$appt_data->{'warranty'} = &subs::rightNow() + (30 * 24 * 60 * 60 * 1000);
						}
						&Manager::appointment_writer($c,$appt_data);

						my $email_data = {
							uuid => $mailbox_uuid,
							timestamp => $timestamp,
							server_time => &subs::rightNow(),
							body => &subs::note_encrypter(&subs::suds_grabber(), $body),
							manager_file => $es->{'email'},
							subject => &subs::note_encrypter(&subs::suds_grabber(), $subject),
							status => $status,
							email => $email,
							cc => $cc,
							thread => ($h_thread || $h_message_id || undef),
							message_id => $h_message_id,
							in_reply_to => $h_in_reply_to,
							thread_refs => $h_references,
							email_server => $es->{'uuid'},
							attachments => $jfile
						};
						&subs::db_insert('mailbox', $email_data);
						# a letter the server accepted goes out to the browsers at once;
						# only what lands in the inbox is news
						if ($status eq 'inbox') {
							&subs::mail_arrival({
								c => $c,
								uuid => $email_data->{'uuid'},
								email => $email,
								manager_file => $from,
								subject => $subject,
								status => 'inbox',
								body => $body
							});
						}
						foreach my $u_data ( @{$files} ) {
							$u_data->{'app_uuid'} = $app_uuid;
							$u_data = &thumbnail_creator($u_data);
						}
						&subs::file_encrypter({ app => $ca->{'app'}, timestamp => $timestamp, suds => &subs::suds_grabber() });
						&subs::appt_header_printer({ app => $ca->{'app'} });
						&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $ca->{'app'} . '\',\'' . $app_uuid .'\');'});
						$entity->purge;

					}
				}
			}
		}

	}
#	});
	my $jemail_servers = encode_json $email_servers;
	&subs::setting_setter({ app => 'mailbox', setting => 'email_config', value => $jemail_servers });

	my $html = $c->render_to_string(
		template => 'mail/email_configure'
	);
	return { email_servers => $email_servers, html => $html };
}

# Send what waits in the outbox. A uuid picks one letter and sends it on the
# spot - the compose side calls it the moment a letter is written, so nothing
# waits for the sweep. The uuid-less form is the utility's, and it keeps the
# old manners: only this device's letters, and never ahead of their timestamp.
sub email_sender {
	my ($uuid, $c) = @_;
	my $query;
	if ($uuid) {
		$query = &subs::db_query('select * from mailbox where status = ? and uuid = ?', 'outbox', $uuid);
	}
	else {
		$query = &subs::db_query('select * from mailbox where status = ? and timestamp <= ? and sender = ?', 'outbox', &subs::rightNow(), &subs::device_setter());
	}
	# hashes hands back one collection, so the rows are taken off it by hand:
	# assigning it straight to an array wrapped it in a single-element list
	my $waiting = $query ? $query->hashes : [];
	my $returner;
	foreach my $o ( @{$waiting} ) {
		&subs::db_update('mailbox', { status => 'sending', server_time => &subs::rightNow() }, { uuid => $o->{'uuid'} });
		my $result = eval {
			&email_send({
				c => $c,
				from => $o->{'from_email'},
				email => $o->{'email'},
				subject => $o->{'subject'},
				body => $o->{'body'},
				attachments => $o->{'attachments'},
				uuid => $o->{'uuid'},
			});
		};
		if ($@) {
			# an smtp server that refuses the connection dies inside the transport:
			# the letter goes back to the outbox like any other failure
			warn "email_sender: send failed for $o->{'uuid'}: $@";
			$result = { result => 'fail' };
		}
		$returner = ref $result eq 'HASH' ? $result->{'result'} : $result;
		if ($returner ne 'success') {
			# a letter that failed goes back to the outbox: it stays visible and
			# the sweep retries it, instead of sitting in 'sending' forever
			&subs::db_update('mailbox', { status => 'outbox', server_time => &subs::rightNow() }, { uuid => $o->{'uuid'} });
		}
	}
	return $returner;
}

# Letters the server accepts all come through here: the imap reader, the
# telephone's sms list, a watch, a neighbour posting one over. The message
# travels to the websocket daemon over the mail socket, which matches it to
# open mailboxes, dots the start menus' mail icons, and lets the regular
# notification speak when no mailbox is watching the thread. The envelope is
# rendered here because a controller is what reads the words back out.
sub mail_arrival {
	my $m = shift;
	my $c = delete $m->{'c'} || &subs::c_maker();
	$m->{'uuid'} ||= &subs::random_string_creator(44);
	$m->{'type'} ||= 'message';
	if (!$m->{'picker'}) {
		# a row that carries the social constructs as columns is addressed to
		# that thread; one with none is addressed by phone, email or contact
		if (grep { defined $m->{$_} && length $m->{$_} } qw/project account community club team person/ ) {
			$m->{'picker'} = {
				projects => $m->{'project'},
				accounts => $m->{'account'},
				communities => $m->{'community'},
				clubs => $m->{'club'},
				teams => $m->{'team'},
				people => $m->{'person'}
			};
		}
	}
	$m->{'decrypted'} = 'yes' unless exists $m->{'decrypted'};
	unless ($m->{'envelope'}) {
		$m->{'envelope'} = $c->render_to_string(
			template => 'mail/message',
			'm' => $m,
			'me' => ''
		);
	}
	unless ($m->{'arrival_message'}) {
		my $who = $m->{'manager_file'} || $m->{'email'} || $m->{'phone'} || 'someone';
		my $what = $m->{'arrival_subject'} || $m->{'subject'} || '';
		$m->{'arrival_message'} = 'Mail from ' . $who . ($what ? ': ' . $what : '');
	}
	$m->{'arrival'} = 'yes';
	&Websocket::mail_send($m);
	return $m;
}


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
		`mkdir -p "$destination"` unless -e $destination;
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

sub email_send() {
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
			my $att_url = $att->{'printer'}->{'qr_code'};
			my $loc_name = &subs::format_name($att->{'printer'}->{'type'}) . ' ' . $att->{'printer'}->{'id'} . '.pdf';
			my $loc = $gb::tmp_dir . '/' . $loc_name;
			push @locations, $loc;
			# the paper draws itself from the very html the compose carried - it was
			# rendered by the house the document was made on, it needs no network
			# (the logo and the qr are data uris), and no theme or cache can reach
			# it. The urls stand in should that html be absent.
			my $local_url = $att->{'printer'}->{'pdf_url'} || $att_url;
			if ($att->{'html'}) {
				my $page = $gb::tmp_dir . '/paper_' . &subs::random_string_creator(12) . '.html';
				write_file($page, '<!DOCTYPE html><html><head><meta charset="utf-8"><base href="' . $att_url . '"></head><body>' . $att->{'html'} . '</body></html>');
				`weasyprint "$page" "$loc"`;
				unlink $page;
			}
			unless (-s $loc) {
				`weasyprint "$local_url" "$loc"`;
			}
			unless (-s $loc) {
				`weasyprint "$att_url" "$loc"`;
			}
			&subs::log_writer('mail paper ' . $loc_name . ' drawn: ' . (-s $loc) . ' bytes');
			$stuffer->attach_file($loc);
			push @mail_files, { src => $loc, name => $loc_name, type => 'document' };
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
		`shred -u "$loc"`;
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

sub pen_message() {
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
	# Define your model and messages (including system prompt)
	my $nproc = 4; # Safe fallback default
	if (open(my $fh, "-|", "nproc")) {
		  $nproc = <$fh>;
		  chomp($nproc);
		  close($fh);
	}
	# Tell the model, in code, how to ask for media: an explicit JSON action,
	# rather than a magic marker it may or may not emit. Only added when a
	# generation agent is configured.
	my $system_message = $data->{'system_msg'} || $conversation->{'chatbot_system_message'} || '';
	if (my $gen_hint = &ai_generation_instruction($settings)) {
		$system_message .= $gen_hint;
	}
	my %chat_seen;
	my @chat_candidates = grep { !$chat_seen{$_}++ } grep { defined $_ && length $_ } ($model, $settings->{'chatbot_model_fallback'});
	my $buffer = '';
	my $accumulated_text = '';
	my $tx;
	foreach my $try_model ( @chat_candidates ) {
		$buffer = '';
		$accumulated_text = '';
		$response_text = '';
		my $payload = {
			  model    => $try_model, # Replace with your installed model
			  messages => [
			      { role => 'system', content => $system_message },
			     	@{$history}
			  ],
			  stream   => \1 # Tells Ollama to stream the response (JSON true)
		};
		# Ollama Chat API Endpoint
		my ($key,$url);
		if ($try_model =~ /^\@cf/ && $settings->{'cloudflare_account'} && $settings->{'cloudflare_token'}) {
			$url = 'https://api.cloudflare.com/client/v4/accounts/'. $settings->{'cloudflare_account'} . '/ai/run/' . $try_model;
			$key = &subs::note_decrypter(&subs::suds_grabber(), $settings->{'cloudflare_token'});
		} else {
			$url = 'http://localhost:11434/api/chat';
			$key = &subs::note_decrypter(&subs::suds_grabber(), $settings->{'ollama_key'});
			$payload->{'options'} = {
				num_thread => $nproc - 2,
				num_ctx    => 32768
			},
			# thinking, where the chat model is a local one that reasons (Ollama's own
			# think field); Cloudflare's endpoint takes none
			my $lvl = &subs::ai_thinking_level(&subs::ai_role_thinking(($data->{'images'} && $settings->{'visual_assistant'}) ? 'visual_assistant' : 'chatbot_model'));
			$payload->{'think'} = ($lvl eq 'max' ? 'high' : $lvl) if length $lvl && &subs::ai_model_thinks($try_model);
		}

		$log->info($url);
		$tx = $ua->build_tx(POST => $url => {
				'Authorization' => "Bearer $key",
				'Content-Type'  => 'application/json'
			} => json => $payload);

		# 2. Maintain a tiny string buffer for incomplete stream chunks
		# 3. UNSUBSCRIBE the default parser, then attach your custom reader
		$tx->res->content->unsubscribe('read')->on(read => sub {
			  my ($content, $bytes) = @_;

			  $buffer .= $bytes;

			  # Process full lines out of our buffer
			  while ($buffer =~ s/^([^\n]*)\n//) {
			      my $line = $1;
			      next unless $line;

			      my $adata = eval { decode_json($line) };
			      next if $@;
	    			if (my $text = unidecode($adata->{message}{content})) {
						$accumulated_text .= $text;


							unless ($data->{'type'} eq 'assistant') {
								$text =~ s/\n/<br>/gi;
								$response_text .= $text;
								&Websocket::mail_send({
									type => 'writing',
									uuid => $msg_data->{'uuid'} || $data->{'uuid'},
									new_text => $text,
									all_text => $response_text,
									mail_contact => 'pen'
								});
							} else {
								$text =~ s/\n/<br>/gi;
								$text =~ s/'/\\'/gi;
								$response_text .= $text;
								&Websocket::send('tab', {
									console => '$(\'.assistant_content[uuid="' . $data->{'uuid'} . '"]\').html(\'' . $response_text . '\');'
								});
							}
		          *STDOUT->flush;
			      }
			  }
		});

		# 3. Perform the transaction synchronously
		$ua->start($tx);

		# a call that never answered falls through to the next model; one that
		# streamed anything is kept, so a retry never doubles the reply
		last unless $tx && $tx->error;
		last if length $response_text;
		next if $try_model eq $chat_candidates[-1];
		&subs::say_it('AI: ' . $try_model . ' failed (' . (($tx->error && $tx->error->{'message'}) || 'no answer') . '); trying the fallback');
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
				my $js = '$(' . encode_json('.assistant_content[uuid="' . $data->{'uuid'} . '"]') . ').html(' . encode_json($gen_note) . ');';
				&Websocket::send('tab', { console => $js });
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
        my $html = ($generating_kind eq 'image')
					? '<img src="' . $media_url . '" class="chat-generated-img" style="width:100%;"/><br>'
					: '<a href="' . $media_url . '" class="chat-generated-file">' . $generating_kind . '</a><br>';
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
					$accumulated_text =~ s/'/\\'/gi;

					&Websocket::send('tab', {
						console => '$(\.assistant_content[uuid="' . $data->{'uuid'} . '"]\)\.html(\'' . $accumulated_text . '\');'
					});
				}
	    }
		}
	}
	return ($response_text,$attachments);

}
sub pen_model_list() {
	my $ua = Mojo::UserAgent->new;
	my $url = 'http://localhost:11434/api/tags';

	# Fetch the list of models from Ollama synchronously
	my $tx = $ua->get($url);

	my $models_list = [];
	if (my $res = $tx->result) {
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
		my $err = $tx->error;
		$log->error('Ollama API request failed: ' . $err->{'message'});
	}
	$log->info(Dumper $models_list);
	return $models_list;
}

sub cloudflare_model_list() {

	my $ua = Mojo::UserAgent->new;
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'cloudflare_token', 'cloudflare_account'] });
  my $cloudflare_account = $settings->{'cloudflare_account'};
  my $cloudflare_token = &subs::note_decrypter(&subs::suds_grabber(), $settings->{'cloudflare_token'}); # or cf_token
	$log->info('doing the cloudflare model list');
	if ($cloudflare_account && $cloudflare_token) {
		$log->info('got the account and token');
		my $url = 'https://api.cloudflare.com/client/v4/accounts/'. $cloudflare_account . '/ai/models/search?page=1&per_page=1000';


		# Fetch the list of models from Ollama synchronously
		my $tx = $ua->get($url => {
		    'Authorization' => "Bearer $cloudflare_token",
		    'Content-Type'  => 'application/json'
		});

		my $models_list = [];
		$log->info($url);
		if (my $res = $tx->result) {
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
			my $err = $tx->error;
			$log->error('Cloudflare API request failed: ' . $err->{'message'});
		}
		$log->info(Dumper $models_list);
		return $models_list;
	}
	else { return []; }
}
# --- the evaluation agent -------------------------------------------------------
# The evaluate buttons hand an app - or the whole house - to this. The raw
# appointment numbers are rolled up first: counts, durations, an hourly and a
# weekday profile, and one count per calendar day. The relational window's
# links (the sc_ lists, one per construct) are walked to find the apps tied to
# it, and each tied app's daily series is lined up against the app's own and
# correlated - Pearson, tried at a small spread of lags, so a thing that
# follows another can say so. Only then does a model speak: its job is the
# words - trends, correlations, predictions - never the arithmetic, which the
# numbers below it have already done.

sub appointment_rollup() {
	my ($app, $since) = @_;
	my $global = ($app eq '__president');
	# one where-clause for every roll-up: the app (unless whole house) and the
	# window the evaluation may read. A shorter window is fewer numbers, and the
	# numbers are the token bill
	my @where;
	my @args;
	unless ($global) { push @where, 'app = ?'; push @args, $app; }
	if ($since) { push @where, 'cast(timestamp as integer) >= ?'; push @args, $since; }
	my $filter = scalar @where ? ' where ' . join(' and ', @where) : '';
	my $roll = { activity => {}, hours => {}, weekdays => {}, daily => {} };
	my $owner_of = sub { $global ? ($_[0]->{'app'} || 'other') : $app };
	# every roll-up is asked of the database in its own grouped form - a life of
	# appointments is far too much to hold in memory just to count it
	my $activity = &subs::db_query(
		'select app, count(*) as count, sum(case when abs(duration) < 604800000 then abs(duration) else 0 end) as duration, min(cast(timestamp as integer)) as first, max(cast(timestamp as integer)) as last from appointments' . $filter . ' group by app',
		@args)->hashes;
	foreach my $row ( @{$activity} ) {
		$roll->{'activity'}->{$owner_of->($row)} = {
			count => $row->{'count'} + 0,
			duration => $row->{'duration'} + 0,
			first => $row->{'first'} + 0,
			last => $row->{'last'} + 0,
		};
	}
	my $bucket_rows = sub {
		my ($rows) = @_;
		my %out;
		foreach my $row ( @{$rows} ) {
			next unless defined $row->{'bucket'} && $row->{'bucket'} ne '';
			$out{$owner_of->($row)}->{$row->{'bucket'}} = $row->{'count'} + 0;
		}
		return \%out;
	};
	$roll->{'hours'} = $bucket_rows->(&subs::db_query(
		"select app, cast(strftime('%H', cast(timestamp as integer) / 1000, 'unixepoch', 'localtime') as integer) as bucket, count(*) as count from appointments" . $filter . ' group by app, bucket',
		@args)->hashes);
	$roll->{'weekdays'} = $bucket_rows->(&subs::db_query(
		"select app, cast(strftime('%w', cast(timestamp as integer) / 1000, 'unixepoch', 'localtime') as integer) as bucket, count(*) as count from appointments" . $filter . ' group by app, bucket',
		@args)->hashes);
	$roll->{'daily'} = $bucket_rows->(&subs::db_query(
		"select app, date(cast(timestamp as integer) / 1000, 'unixepoch', 'localtime') as bucket, count(*) as count from appointments" . $filter . ' group by app, bucket',
		@args)->hashes);
	# what kind of thing ran, not just how often: the categorical columns the
	# appointments carry - type, subtype, project, and the model and option names
	# (those two often hold JSON with a name inside). The database does the
	# counting, so a window that spans a whole life still returns only the
	# distinct combinations instead of every row in it.
	my $categorical = &subs::db_query(
		"select app, type, subtype, project, model, option, count(*) as count from appointments" . $filter . ' group by app, type, subtype, project, model, option',
		@args)->hashes;
	foreach my $row ( @{$categorical} ) {
		my $owner = $owner_of->($row);
		my $count = ($row->{'count'} || 0) + 0;
		foreach my $column ( qw/type subtype project/ ) {
			my $value = $row->{$column};
			next unless defined $value && $value ne '';
			$roll->{'kinds'}->{$owner}->{$column}->{$value} += $count;
		}
		foreach my $column ( qw/model option/ ) {
			my $value = $row->{$column};
			next unless defined $value && $value ne '';
			my $name;
			if ($value =~ /^\s*\{/) {
				my $data = eval { return decode_json($value) } || {};
				$name = ref $data eq 'HASH' ? $data->{'name'} : undef;
			}
			else { $name = $value; }
			next unless defined $name && $name ne '';
			$roll->{'kinds'}->{$owner}->{$column}->{substr($name, 0, 40)} += $count;
		}
	}
	# how much, not just how often: the quantity column is the amount logged (10 oz
	# of coffee, 0.8 tsp of soap). The database sums it per owner and unit, and the
	# busiest unit wins, so a stray label cannot skew the amount.
	my $qconj = length($filter) ? ' and ' : ' where ';
	my $quantities = &subs::db_query(
		"select app, unit, count(*) as n, sum(cast(quantity as real)) as total, avg(cast(quantity as real)) as avg from appointments" . $filter . $qconj . "quantity is not null and quantity != '' group by app, unit",
		@args)->hashes;
	foreach my $row ( @{$quantities} ) {
		my $n = ($row->{'n'} || 0) + 0;
		next unless $n;
		my $owner = $owner_of->($row);
		my $cur = $roll->{'quantity'}->{$owner};
		next if $cur && $cur->{'count'} >= $n;
		$roll->{'quantity'}->{$owner} = {
			count => $n,
			total => ($row->{'total'} || 0) + 0,
			average => ($row->{'avg'} || 0) + 0,
			unit => (defined $row->{'unit'} ? $row->{'unit'} : ''),
		};
	}
	return $roll;
}

# the busiest few values of each kind, so a window says what the activity was
# made of without opening the whole catalogue
sub evaluation_kinds {
	my ($kinds, $cap) = @_;
	$cap ||= 4;
	my $out = {};
	foreach my $column ( sort keys %{ $kinds || {} } ) {
		my $counts = $kinds->{$column};
		my @values = sort { $counts->{$b} <=> $counts->{$a} || $a cmp $b } keys %{$counts};
		splice(@values, $cap) if scalar @values > $cap;
		$out->{$column} = { map { $_ => $counts->{$_} } @values } if scalar @values;
	}
	return $out;
}

# Every appointment the house knows, by its unformatted name. Membership is a
# pos setting (every app carries one), which is broader than the built-in
# known_appts and so catches a project that is really an appointment too.
sub appointment_names {
	my $rows = &subs::db_query("select distinct app from settings where setting = ? and app is not null and app != ''", 'pos')->hashes;
	my %names;
	foreach my $r ( @{$rows} ) { $names{ $r->{'app'} } = 1; }
	return \%names;
}

# What one of a unit is in millilitres (or grams, near enough), when the unit is
# a measure the house uses; undef for a bare count ('each', '', an app name),
# which is a number of things, not an amount.
sub quantity_unit_ml {
	my ($unit) = @_;
	$unit = lc($unit // '');
	my %to_ml = (
		ml => 1, millilitre => 1, cc => 1, l => 1000, litre => 1000, liter => 1000,
		oz => 29.5735, floz => 29.5735, cup => 236.588, glass => 250, tbsp => 14.7868, tsp => 4.92892,
		g => 1, gram => 1, kg => 1000,
	);
	return $to_ml{$unit};
}

# What one logged unit of an appointment is: the app's quantity setting, read as
# an amount and a unit (coffee logs '10oz' a cup, soap '0.25'). A bare number is
# read as millilitres, the house's habit. Undef when the app records no serving.
sub quantity_serving {
	my ($str) = @_;
	return undef unless defined $str && $str =~ /\S/;
	my ($amount, $unit) = $str =~ /^\s*(-?[0-9]*\.?[0-9]+)\s*([A-Za-z]*)\s*$/;
	return undef unless defined $amount;
	$amount = $amount + 0;
	$unit = lc($unit || '');
	my $factor = length($unit) ? &subs::quantity_unit_ml($unit) : 1;
	return {
		raw => $str,
		amount => $amount,
		unit => ($unit || 'ml'),
		(defined $factor ? (ml => $amount * $factor) : ()),
	};
}

# The amount an app's window adds up to, spoken in one unit. A logged quantity is
# already an amount when its own unit is a measure; the app's serving is the
# default for the appointments that logged none, so every one is counted. All of
# it is put in millilitres and then back into the unit the app speaks.
sub evaluation_amount {
	my ($q, $occ, $serving, $days) = @_;
	# the window's quantity counts its entries under 'times' (how many carried a
	# quantity); 'count' is the raw rollup's own key, taken too so either shape works
	my $count = $q ? ($q->{'times'} // $q->{'count'}) : undef;
	return undef unless $count;
	$days = 1 unless $days && $days > 0;
	my $unit = $q->{'unit'} // '';
	my $q_factor = &subs::quantity_unit_ml($unit);
	my $has_serving = $serving && $serving->{'amount'} > 0 && defined $serving->{'ml'};
	my $logged = $q->{'total'};
	# appointments that carried no quantity of their own take the served default
	my $missing = ($occ && $occ > $count) ? $occ - $count : 0;
	my $ml;
	my $filled = 0;
	if (defined $q_factor) {
		$ml = $logged * $q_factor;
		if ($has_serving && $missing) { $ml += $missing * $serving->{'ml'}; $filled = 1; }
	}
	elsif ($has_serving) {
		$ml = ($logged + $missing) * $serving->{'ml'};
		$filled = 1 if $missing;
	}
	else {
		# a bare count with nothing to size it
		return { unit => 'units', total => &subs::briefing_number($logged), per_day => &subs::briefing_number($logged / $days), filled => 0 };
	}
	my ($out_unit, $out_factor);
	if (defined $q_factor) { $out_unit = $unit; $out_factor = $q_factor; }
	else { $out_unit = $serving->{'unit'}; $out_factor = $serving->{'ml'} / $serving->{'amount'}; }
	my $total = $out_factor ? $ml / $out_factor : $ml;
	return {
		unit => $out_unit,
		total => &subs::briefing_number($total),
		per_day => &subs::briefing_number($total / $days),
		ml_total => int($ml),
		ml_day => int($ml / $days),
		filled => $filled,
	};
}

# every app the relational window has tied to this one: the sc_ settings are
# uuid links, one list per construct, and 'all' means every app of it
sub relational_family() {
	my ($app) = @_;
	my $settings = &subs::settings_grabber({ app => $app });
	my (@links, %seen);
	foreach my $key ( sort keys %{$settings} ) {
		next unless $key =~ /^sc_/;
		my $construct = $key;
		$construct =~ s/^sc_//;
		my $list = eval { return decode_json $settings->{$key} } || [];
		foreach my $entry ( @{$list} ) {
			my $linked;
			if ($entry eq 'all') {
				$linked = [ map { $_->{'app'} } @{ &subs::db_select('settings', undef, { setting => 'pos', value => $construct, device => &subs::device_setter() })->hashes } ];
			}
			else {
				my $ts = &subs::settings_grabber({ uuid => $entry, benign => 1 });
				$linked = $ts->{'app'} ? [ $ts->{'app'} ] : [];
			}
			foreach my $la ( @{$linked} ) {
				next if !$la || $la eq $app || $seen{$la}++;
				push @links, { app => $la, link => $construct };
			}
		}
	}
	return \@links;
}

# two apps' day counts, lined up over the union of their days
sub day_pair_series() {
	my ($da, $db) = @_;
	my %seen;
	my @keys = sort grep { !$seen{$_}++ } ( keys %{$da}, keys %{$db} );
	my @xs = map { $da->{$_} || 0 } @keys;
	my @ys = map { $db->{$_} || 0 } @keys;
	return (\@xs, \@ys, \@keys);
}

# Pearson's r at a small spread of lags; the best fit wins, so a follower can
# be told from a leader. Positive lag means the second series trails the first
# by that many days. Undef when there is too little shared history, when the
# pair is almost all zero days, or when either line never moves
sub series_correlation() {
	my ($xs, $ys) = @_;
	my $n = scalar @{$xs};
	return undef if $n < 14;
	my $active = grep { ($xs->[$_] || 0) + ($ys->[$_] || 0) > 0 } ( 0 .. $n - 1 );
	return undef if $active < 7;
	my $corr = sub {
		my ($xa, $ya) = @_;
		my $m = scalar @{$xa};
		return undef if $m < 14;
		my ($sx,$sy,$sxx,$syy,$sxy) = (0,0,0,0,0);
		foreach my $i ( 0 .. $m - 1 ) {
			$sx += $xa->[$i]; $sy += $ya->[$i];
			$sxx += $xa->[$i] ** 2; $syy += $ya->[$i] ** 2; $sxy += $xa->[$i] * $ya->[$i];
		}
		my $den = sqrt(($m * $sxx - $sx ** 2) * ($m * $syy - $sy ** 2));
		return undef unless $den;
		return ($m * $sxy - $sx * $sy) / $den;
	};
	my ($best, $best_lag);
	foreach my $lag ( -2 .. 2 ) {
		my ($xa, $ya) = ([], []);
		foreach my $i ( 0 .. $n - 1 ) {
			my $j = $i + $lag;
			next if $j < 0 || $j > $n - 1;
			push @{$xa}, $xs->[$i];
			push @{$ya}, $ys->[$j];
		}
		my $r = $corr->($xa, $ya);
		next unless defined $r;
		if (!defined $best || abs($r) > abs($best)) { $best = $r; $best_lag = $lag; }
	}
	return undef unless defined $best;
	return { r => sprintf('%.2f', $best), lag_days => $best_lag };
}

# every numeric measure the window's appointments logged, averaged per day:
# { app => { measure => { day => average } } }. A condition word is skipped;
# the measure's own reading time wins over the appointment's, so a humidity
# log lands on the day it was read
sub measure_series {
	my ($since) = @_;
	my $rows = &subs::db_query(
		"select app, timestamp, measures from appointments where measures is not null and measures != '' and cast(timestamp as integer) >= ?",
		$since);
	my $sth = $rows->sth;
	my %sum;
	while (my $row = $sth->fetchrow_arrayref) {
		my ($app, $ts, $jmeasures) = @{$row};
		my $list = eval { return decode_json($jmeasures) } || next;
		foreach my $entry ( @{$list} ) {
			next unless ref $entry eq 'HASH';
			my $when = $entry->{'ts'} || $ts;
			my @lt = localtime($when / 1000);
			my $day = sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
			foreach my $name ( keys %{$entry} ) {
				next if $name eq 'ts' || $name eq 'uuid';
				my $value = $entry->{$name};
				next unless defined $value && !ref $value && $value =~ /^-?[0-9]+(\.[0-9]+)?$/;
				$sum{$app}->{$name}->{$day}->{'sum'} += $value;
				$sum{$app}->{$name}->{$day}->{'n'}++;
			}
		}
	}
	$rows->finish;
	my %out;
	foreach my $app ( keys %sum ) {
		foreach my $name ( keys %{$sum{$app}} ) {
			foreach my $day ( keys %{$sum{$app}->{$name}} ) {
				my $cell = $sum{$app}->{$name}->{$day};
				$out{$app}->{$name}->{$day} = $cell->{'sum'} / $cell->{'n'};
			}
		}
	}
	return \%out;
}

# A number as a person writes it: two decimals at most, trailing zeros dropped,
# so a rate reads "3" not "3.00" and "0.03" stays "0.03". The briefing hands
# the model plain figures, and it should not parrot "3.00" back.
sub briefing_number {
	my ($n) = @_;
	return $n unless defined $n && $n =~ /^-?[0-9.]+$/;
	my $s = sprintf('%.2f', $n + 0);
	if ($s =~ /\./) { $s =~ s/0+$//; $s =~ s/\.$//; }
	$s = '' if $s eq '-0';
	return $s;
}

# The readings an app logged against its appointments, so the report can speak
# the numbers themselves and not only the correlations they make. A logged entry
# is a snapshot of every measure the app carried at that moment ({weight => 180,
# pressure => 120, ts, uuid}); the app's own app_measures setting names the unit
# and the range the reading is set to expect. Numeric readings are summarised
# (readings, average, min, max, the latest and when it was read); a text or
# select reading keeps its latest value and the spread of values seen.
# An app's appointments gathered into episodes: walked in order and merged
# wherever the gap from one to the next is small, each an { ts, stop }. A night
# broken by a waking is one episode; a single cup is one. The split gap is read
# from the app itself - a coffee (minutes long) splits from the next by a few
# minutes, a night (hours long) only by a long gap.
sub evaluation_episode_list {
	my ($app, $since) = @_;
	$since ||= &subs::rightNow() - 30 * 86400000;
	my $rows = &subs::db_query('select timestamp, stop_timestamp, duration, quantity, unit from appointments where app = ? and cast(timestamp as integer) >= ? order by timestamp', $app, $since)->hashes;
	my @ev;
	foreach my $r ( @{$rows} ) {
		my $ts = $r->{'timestamp'} + 0;
		my $stop = ($r->{'stop_timestamp'} && $r->{'stop_timestamp'} > $ts) ? $r->{'stop_timestamp'} + 0 : $ts + abs($r->{'duration'} || 0);
		push @ev, { ts => $ts, stop => $stop, q => ($r->{'quantity'} || 0) + 0, unit => $r->{'unit'} };
	}
	return { episodes => [], gap => 60000 } unless scalar @ev;
	my @durs = sort { $a <=> $b } map { $_->{'stop'} - $_->{'ts'} } @ev;
	my $gap = ($durs[int(@durs/2)] || 0) / 2;
	$gap = 60000 if $gap < 60000;
	$gap = 1800000 if $gap > 1800000;
	my @ep;
	foreach my $e ( @ev ) {
		if (@ep && $e->{'ts'} - $ep[-1]{'stop'} <= $gap) {
			$ep[-1]{'stop'} = $e->{'stop'} if $e->{'stop'} > $ep[-1]{'stop'};
			$ep[-1]{'q'} += $e->{'q'};
			$ep[-1]{'unit'} ||= $e->{'unit'};
		}
		else {
			push @ep, { ts => $e->{'ts'}, stop => $e->{'stop'}, q => $e->{'q'}, unit => $e->{'unit'} };
		}
	}
	return { episodes => \@ep, gap => $gap };
}

# An app's natural unit rather than a count per calendar day: a night, a cup, a
# session, a walk. Reports how many episodes there were and how many an active
# day, the median and longest, the hour each began at (so a sleep reads as a
# bedtime, a coffee as a time of day) and, where the app logs a quantity, the
# amount an episode, a day and in all.
sub evaluation_episodes {
	my ($app, $since) = @_;
	return {} unless $app && $app ne '__president';
	my $list = &subs::evaluation_episode_list($app, $since);
	my @ep = @{ $list->{'episodes'} };
	return {} unless scalar @ep;
	my $gap = $list->{'gap'};
	my @edur = sort { $a <=> $b } map { $_->{'stop'} - $_->{'ts'} } @ep;
	my (%onset, %active);
	foreach my $ep ( @ep ) {
		my @lt = localtime($ep->{'ts'} / 1000);
		$onset{$lt[2]}++;
		$active{ sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]) } = 1;
	}
	my $days = scalar keys %active;
	my $qtotal = 0; $qtotal += $_->{'q'} for @ep;
	my ($unit) = map { $_->{'unit'} } grep { $_->{'unit'} } @ep;
	return {
		episodes => scalar @ep,
		days => $days,
		per_day => $days ? sprintf('%.2f', scalar(@ep) / $days) : 0,
		gap_minutes => int($gap / 60000),
		median_duration => &subs::duration_sayer(($edur[int(@edur/2)] || 0) / 1000),
		longest_duration => &subs::duration_sayer(($edur[-1] || 0) / 1000),
		onset_hours => { map { $_ => $onset{$_} } sort { $a <=> $b } keys %onset },
		($qtotal ? (
			quantity_total => sprintf('%.1f', $qtotal),
			quantity_per_episode => sprintf('%.1f', $qtotal / scalar @ep),
			quantity_per_day => $days ? sprintf('%.1f', $qtotal / $days) : 0,
			($unit ? (unit => $unit) : ()),
		) : ()),
	};
}

# The typical gap from an episode of one app to the nearest episode of another -
# the last coffee before a night's sleep, the walk before a meal - so a
# relationship carries a time. Works on episode onsets, so a night is one onset
# and not each record, and the median is signed (negative when the other tends
# to come first).
sub evaluation_episode_lag {
	my ($app, $other, $since) = @_;
	return {} unless $app && $other && $other ne $app;
	my $mine = &subs::evaluation_episode_list($app, $since);
	my $theirs = &subs::evaluation_episode_list($other, $since);
	my @A = map { $_->{'ts'} } @{ $mine->{'episodes'} };
	my @B = sort { $a <=> $b } map { $_->{'ts'} } @{ $theirs->{'episodes'} };
	return {} unless @A && @B;
	my (@gaps, $before, $after);
	foreach my $t ( @A ) {
		my ($bestd);
		foreach my $u ( @B ) {
			my $d = $u - $t;
			$bestd = $d if !defined $bestd || abs($d) < abs($bestd);
		}
		push @gaps, $bestd;
		if ($bestd < 0) { $before++ } else { $after++ }
	}
	my @s = sort { $a <=> $b } @gaps;
	return {
		app => $other,
		n => scalar @A,
		median_minutes => sprintf('%.0f', $s[int(@s/2)] / 60000),
		before => $before || 0,
		after => $after || 0,
	};
}

# What conditions the app runs under: every numeric measure any app logged is
# read against the app's own episodes. Two contrasts are weighed - the reading in
# the windows around the episodes against its value everywhere else (around), and
# its mean on the days the app ran against the days it did not (day) - and both
# are handed over, with confidence saying which stand (both, day or around),
# because a daily thing like weather is honest at the day while a
# moment-to-moment thing is honest around the event, and a condition that only
# leans around may just be the hour of the clock. A walk in the cold, an eczema
# day in the damp, steps that climb with a walk: the measure's app is what
# carries the condition, so a weather app's temperature stands beside the apps.
sub evaluation_conditions {
	my ($app, $since, $cap) = @_;
	return [] unless $app && $app ne '__president';
	$since ||= &subs::rightNow() - 60 * 86400000;
	$cap ||= 8;
	my $list = &subs::evaluation_episode_list($app, $since);
	my @ep = @{ $list->{'episodes'} };
	return [] unless scalar @ep >= 3;
	my $delta = 2 * 3600000;
	my %active;
	foreach my $ep ( @ep ) {
		my @lt = localtime($ep->{'ts'} / 1000);
		$active{ sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]) } = 1;
	}
	my $rows = &subs::db_query("select app, timestamp, measures from appointments where measures is not null and measures != '' and cast(timestamp as integer) >= ?", $since);
	my $sth = $rows->sth;
	my %series;
	while (my $row = $sth->fetchrow_arrayref) {
		my ($mapp, $ts, $j) = @{$row};
		next unless $j;
		my $ms = eval { decode_json $j } || next;
		my @lt = localtime($ts / 1000);
		my $day = sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
		foreach my $m ( @{$ms} ) {
			foreach my $k ( keys %{$m} ) {
				next if $k eq 'uuid' || $k eq 'ts';
				my $v = $m->{$k};
				next unless defined $v && $v =~ /^-?[0-9]+(?:\.[0-9]+)?$/;
				my $s = ($series{$mapp . "\t" . $k} ||= { app => $mapp, name => $k, pts => [], days => {} });
				push @{$s->{'pts'}}, [ $ts + 0, $v + 0 ];
				push @{$s->{'days'}->{$day}}, $v + 0;
			}
		}
	}
	my @out;
	# a two-group z: the two means over the standard error of their difference, so
	# a real shift stands out from the day-to-day spread rather than being drowned
	# by it
	my $two_z = sub {
		my ($on, $off) = @_;
		my $n1 = scalar @{$on}; my $n2 = scalar @{$off};
		return undef if $n1 < 4 || $n2 < 4;
		my ($m1, $m2) = (0, 0);
		$m1 += $_ for @{$on}; $m1 /= $n1;
		$m2 += $_ for @{$off}; $m2 /= $n2;
		my ($s1, $s2) = (0, 0);
		$s1 += ($_ - $m1) ** 2 for @{$on};
		$s2 += ($_ - $m2) ** 2 for @{$off};
		$s1 = sqrt($s1 / $n1); $s2 = sqrt($s2 / $n2);
		my $se = sqrt(($s1 ** 2) / $n1 + ($s2 ** 2) / $n2);
		return undef unless $se > 0;
		return { on => $m1, off => $m2, z => ($m1 - $m2) / $se, n => $n1, ratio => ($m2 ? $m1 / $m2 : undef) };
	};
	foreach my $key ( keys %series ) {
		my $s = $series{$key};
		my @pts = sort { $a->[0] <=> $b->[0] } @{ $s->{'pts'} };
		my (@near, @far);
		my $pi = 0;
		foreach my $p ( @pts ) {
			while ($pi < @ep && $ep[$pi]{'stop'} + $delta < $p->[0]) { $pi++ }
			if ($pi < @ep && $p->[0] >= $ep[$pi]{'ts'} - $delta) { push @near, $p->[1] } else { push @far, $p->[1] }
		}
		my (@on_day, @off_day);
		foreach my $d ( keys %{ $s->{'days'} } ) {
			my @v = @{ $s->{'days'}->{$d} };
			my $m = 0; $m += $_ for @v; $m /= @v;
			push @{ $active{$d} ? \@on_day : \@off_day }, $m;
		}
		my $around = $two_z->(\@near, \@far);
		my $day = $two_z->(\@on_day, \@off_day);
		# a contrast stands on its own only if it is both sure (z) and material (the
		# ratio actually moved): a large series makes a 1% shift look certain, so a
		# ratio that truly moved is asked as well
		my $stands = sub {
			my ($c) = @_;
			return 0 unless $c && defined $c->{'ratio'};
			return abs($c->{'z'}) >= 2 && abs($c->{'ratio'} - 1) >= 0.15 ? 1 : 0;
		};
		my $a_ok = $stands->($around);
		my $d_ok = $stands->($day);
		next unless $a_ok || $d_ok;
		my ($best) = sort { abs($b->{'z'}) <=> abs($a->{'z'}) } grep { $stands->($_) } ($around, $day);
		my $dir = sub { $_[0]->{'on'} > $_[0]->{'off'} ? 'higher' : 'lower' };
		# The day contrast weighs whole days against whole days, so the hour of the
		# clock cancels; the around contrast weighs the windows around the app, so a
		# thing that only varies with the hour - weather does - can show there and
		# nowhere else. Both readings ride along and the label says which stand: both
		# agreeing is the honest condition, a day that stands alone is the same, an
		# around that stands alone may be the time of day wearing the app's name.
		my $confidence = ($a_ok && $d_ok && $dir->($around) eq $dir->($day)) ? 'both'
			: $d_ok ? 'day' : 'around';
		push @out, {
			app => $s->{'app'},
			measure => $s->{'name'},
			kind => $best->{'kind'},
			on => sprintf('%.2f', $best->{'on'}),
			off => sprintf('%.2f', $best->{'off'}),
			(defined $best->{'ratio'} ? (ratio => sprintf('%.2f', $best->{'ratio'})) : ()),
			z => sprintf('%.1f', $best->{'z'}),
			n => $best->{'n'},
			direction => $dir->($best),
			confidence => $confidence,
			(defined $around ? (around => {
				(defined $around->{'ratio'} ? (ratio => sprintf('%.2f', $around->{'ratio'})) : ()),
				z => sprintf('%.1f', $around->{'z'}),
				n => $around->{'n'},
				direction => $dir->($around),
			}) : ()),
			(defined $day ? (day => {
				(defined $day->{'ratio'} ? (ratio => sprintf('%.2f', $day->{'ratio'})) : ()),
				z => sprintf('%.1f', $day->{'z'}),
				n => $day->{'n'},
				direction => $dir->($day),
			}) : ()),
		};
	}
	@out = sort { abs($b->{'z'}) <=> abs($a->{'z'}) || $b->{'n'} <=> $a->{'n'} } @out;
	splice(@out, $cap) if scalar @out > $cap;
	return \@out;
}

sub evaluation_measures {
	my ($app, $since, $defs) = @_;
	return {} unless $app && $app ne '__president';
	$defs ||= eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};
	my $rows = &subs::db_query(
		"select measures from appointments where app = ? and measures is not null and measures != '' and cast(timestamp as integer) >= ?",
		$app, ($since || 0));
	my $sth = $rows->sth;
	my (%num, %txt);
	while (my $row = $sth->fetchrow_arrayref) {
		my ($jmeasures) = @{$row};
		my $list = eval { return decode_json($jmeasures) } || next;
		foreach my $entry ( @{$list} ) {
			next unless ref $entry eq 'HASH';
			my $when = 0 + ($entry->{'ts'} || 0);
			foreach my $name ( keys %{$entry} ) {
				next if $name eq 'ts' || $name eq 'uuid';
				my $value = $entry->{$name};
				next unless defined $value && !ref $value && $value =~ /\S/;
				if ($value =~ /^-?[0-9]+(?:\.[0-9]+)?$/) {
					my $a = $num{$name} ||= { count => 0, sum => 0, min => undef, max => undef, latest => undef, latest_at => 0 };
					$a->{'count'}++;
					$a->{'sum'} += $value;
					$a->{'min'} = $value if !defined $a->{'min'} || $value < $a->{'min'};
					$a->{'max'} = $value if !defined $a->{'max'} || $value > $a->{'max'};
					if (!defined $a->{'latest'} || $when >= $a->{'latest_at'}) {
						$a->{'latest'} = $value + 0;
						$a->{'latest_at'} = $when;
					}
				}
				else {
					my $t = $txt{$name} ||= { count => 0, latest => undef, latest_at => 0, values => {} };
					$t->{'count'}++;
					$t->{'values'}->{$value}++;
					if (!defined $t->{'latest'} || $when >= $t->{'latest_at'}) {
						$t->{'latest'} = $value;
						$t->{'latest_at'} = $when;
					}
				}
			}
		}
	}
	$rows->finish;
	my $out = {};
	foreach my $name ( sort keys %num ) {
		my $a = $num{$name};
		my $e = {
			readings => $a->{'count'},
			average => &subs::briefing_number($a->{'sum'} / $a->{'count'}),
			min => &subs::briefing_number($a->{'min'}),
			max => &subs::briefing_number($a->{'max'}),
			latest => &subs::briefing_number($a->{'latest'}),
		};
		if ($a->{'latest_at'}) {
			my @lt = localtime($a->{'latest_at'} / 1000);
			$e->{'latest_at'} = sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
		}
		my $def = $defs->{$name};
		if (ref $def eq 'HASH') {
			$e->{'unit'} = $def->{'unit'} if defined $def->{'unit'} && $def->{'unit'} =~ /\S/;
			$e->{'range'} = ($def->{'min'} // '') . ' to ' . ($def->{'max'} // '') if defined $def->{'min'} || defined $def->{'max'};
		}
		$out->{$name} = $e;
	}
	foreach my $name ( sort keys %txt ) {
		my $t = $txt{$name};
		my @vals = sort { $t->{'values'}->{$b} <=> $t->{'values'}->{$a} || $a cmp $b } keys %{ $t->{'values'} };
		splice(@vals, 5) if scalar @vals > 5;
		$out->{$name} = {
			readings => $t->{'count'},
			latest => &subs::format_name($t->{'latest'}),
			values => { map { &subs::format_name($_) => $t->{'values'}->{$_} } @vals },
		};
	}
	return $out;
}

# The places an app went, read from the continent table the GPS fills. A walk's
# track is a run of latitude/longitude rows tied to the appointment; summed here
# into what a report can use: how many places, how far (km), for how long, the
# box they fall in, where it started and ended, and the speed in km/h - from the
# speed the readings carried (the fix gives m/s), or the average worked out from
# the distance and the time when the readings carried no speed of their own.
sub evaluation_continent {
	my ($app, $since) = @_;
	return {} unless $app && $app ne '__president';
	my $rows = &subs::db_query(
		"select latitude, longitude, speed, timestamp from continent where app = ? and latitude is not null and latitude != '' and cast(timestamp as integer) >= ? order by cast(timestamp as integer)",
		$app, ($since || 0));
	return {} unless $rows;
	my ($points, $distance, $first, $last) = (0, 0, undef, undef);
	my ($north, $south, $east, $west);
	my ($sp_sum, $sp_n, $sp_max);
	my ($prev_lat, $prev_lon, $from, $to);
	foreach my $r ( @{ $rows->hashes } ) {
		next unless defined $r->{'latitude'} && $r->{'latitude'} =~ /^-?[0-9]/ && defined $r->{'longitude'} && $r->{'longitude'} =~ /^-?[0-9]/;
		my ($lat, $lon) = ($r->{'latitude'} + 0, $r->{'longitude'} + 0);
		my $ts = 0 + ($r->{'timestamp'} || 0);
		$points++;
		$first = $ts if !defined $first || $ts < $first;
		$last = $ts if !defined $last || $ts > $last;
		$north = $lat if !defined $north || $lat > $north;
		$south = $lat if !defined $south || $lat < $south;
		$east = $lon if !defined $east || $lon > $east;
		$west = $lon if !defined $west || $lon < $west;
		$from ||= [ $lat, $lon ];
		$to = [ $lat, $lon ];
		$distance += great_circle_distance(deg2rad($prev_lon), deg2rad(90 - $prev_lat), deg2rad($lon), deg2rad(90 - $lat), $gb::planet_radius) if defined $prev_lat;
		($prev_lat, $prev_lon) = ($lat, $lon);
		if (defined $r->{'speed'} && $r->{'speed'} =~ /^-?[0-9.]+$/) {
			$sp_sum += $r->{'speed'};
			$sp_n++;
			$sp_max = $r->{'speed'} if !defined $sp_max || $r->{'speed'} > $sp_max;
		}
	}
	return {} unless $points;
	my $out = {
		points => $points,
		distance_km => &subs::briefing_number($distance),
		bounds => { north => sprintf('%.4f', $north), south => sprintf('%.4f', $south), east => sprintf('%.4f', $east), west => sprintf('%.4f', $west) },
		from => { latitude => sprintf('%.4f', $from->[0]), longitude => sprintf('%.4f', $from->[1]) },
		to => { latitude => sprintf('%.4f', $to->[0]), longitude => sprintf('%.4f', $to->[1]) },
	};
	if ($last && $first && $last > $first) {
		$out->{'duration_minutes'} = &subs::briefing_number(($last - $first) / 60000);
	}
	if ($sp_n) {
		# the fix carries m/s; the house reads km/h
		$out->{'speed'} = { readings => $sp_n, average => &subs::briefing_number(($sp_sum / $sp_n) * 3.6), max => &subs::briefing_number($sp_max * 3.6), unit => 'km/h' };
	}
	elsif ($last && $first && $last > $first) {
		my $hours = ($last - $first) / 3600000;
		$out->{'speed'} = { average => &subs::briefing_number($distance / $hours), unit => 'km/h' } if $hours > 0;
	}
	return $out;
}

# The speed a GPS fix carried, saved where the evaluator's measurements live: an
# entry on the appointment's own measures ({speed => 5.0, ts => ...}), so every
# reading counts in the readings, averages and trends the same way a typed-in
# measure does. The house reads speed in km/h (the fix carries m/s). The app's
# measure table gets a name for it the first time, so it is a measure the house
# knows rather than a stray key. A fix with no speed (the device gave none) is
# left alone.
#
# Volume is the worry on a walk: a fix every few seconds would pile hundreds of
# readings on one appointment. So a reading is kept at most once a gap, and a
# long track keeps its most recent readings, not all of them. Both knobs are here.
my $SPEED_MEASURE_GAP_MS = 60000;   # one reading a minute
my $SPEED_MEASURE_CAP = 500;        # a single appointment keeps this many at most
sub continent_speed_measure {
	my ($app, $uuid, $speed, $timestamp) = @_;
	return unless $app && $app ne '' && $uuid;
	return unless defined $speed && $speed =~ /^-?[0-9]+(?:\.[0-9]+)?$/;
	my $row = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
	return unless $row->{'uuid'};
	my $measures = eval { return decode_json $row->{'measures'} } || [];
	my $when = defined $timestamp ? $timestamp : &subs::rightNow();
	# the throttle: the last reading wins a gap, and an out-of-order fix is skipped
	my $last;
	foreach my $entry ( @{$measures} ) {
		next unless defined $entry->{'speed'} && defined $entry->{'ts'};
		$last = $entry->{'ts'} if !defined $last || $entry->{'ts'} > $last;
	}
	return if defined $last && ($when - $last) < $SPEED_MEASURE_GAP_MS;
	push @{$measures}, { speed => sprintf('%.2f', $speed * 3.6), ts => $when };
	# the cap: drop the oldest speed readings once there are too many
	my @speed_idx = grep { defined $measures->[$_]->{'speed'} } 0 .. $#{$measures};
	if (scalar @speed_idx > $SPEED_MEASURE_CAP) {
		my %drop;
		$drop{$_} = 1 for @speed_idx[0 .. (scalar(@speed_idx) - $SPEED_MEASURE_CAP - 1)];
		$measures = [ map { $drop{$_} ? () : $measures->[$_] } 0 .. $#{$measures} ];
	}
	&subs::db_update('appointments', { measures => encode_json($measures), server_time => &subs::rightNow() }, { uuid => $uuid, app => $app });
	my $defs = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};
	unless (ref $defs eq 'HASH' && $defs->{'speed'}) {
		$defs->{'speed'} = { type => 'number', unit => 'km/h' };
		&subs::setting_setter({ app => $app, setting => 'app_measures', value => encode_json $defs });
	}
	return 1;
}

# The clocks a trend is read from, the same scopes the inventory graphs. Each is
# summarised for the last few periods (oldest first) rather than one span's
# total, so a week that fell away or a month that doubled shows in the shape.
# A period with nothing is kept, because a gap is a trend too.
my %PERIOD_TREND = (
	minute => { seconds => 60,      cap => 60, bucket => "strftime('%Y-%m-%dT%H:%M', cast(timestamp as integer) / 1000, 'unixepoch', 'localtime')" },
	hour   => { seconds => 3600,    cap => 24, bucket => "strftime('%Y-%m-%dT%H', cast(timestamp as integer) / 1000, 'unixepoch', 'localtime')" },
	day    => { seconds => 86400,   cap => 31, bucket => "date(cast(timestamp as integer) / 1000, 'unixepoch', 'localtime')" },
	week   => { seconds => 604800,  cap => 26, bucket => "date(cast(timestamp as integer) / 1000, 'unixepoch', 'localtime', 'weekday 0', '-6 days')" },
	month  => { seconds => 2678400, cap => 24, bucket => "strftime('%Y-%m', cast(timestamp as integer) / 1000, 'unixepoch', 'localtime')" },
	year   => { seconds => 31622400, cap => 12, bucket => "strftime('%Y', cast(timestamp as integer) / 1000, 'unixepoch', 'localtime')" },
);

# Where the moment sits in the calendar period it is in: the start, the start of
# the next period, and the fraction between them (0 at the opening instant, 1 as
# the next period begins). The periods come off the calendar - a month is however
# many days it holds, and daylight saving is honoured - the same way father_time
# builds a locked window, so a pace read here and a window drawn there agree.
# $week_start is the weekday a week begins on (0 Sunday, 1 Monday): the budget's
# locked window and the trend buckets start their weeks on different days, so
# each caller says which. This is what lets a part-run period be read as a pace
# rather than a fall.
sub period_bounds {
	my ($unit, $now, $week_start) = @_;
	$now = &rightNow() unless defined $now;
	$week_start = 0 unless defined $week_start;
	my $at = localtime($now / 1000);
	my $start = sub {
		my $offset = shift;
		if ($unit eq 'minute') {
			return timelocal(0, $at->min, $at->hour, $at->mday, $at->mon - 1, $at->year) * 1000 + $offset * 60000;
		}
		if ($unit eq 'hour') {
			return timelocal(0, 0, $at->hour, $at->mday, $at->mon - 1, $at->year) * 1000 + $offset * 3600000;
		}
		if ($unit eq 'year') {
			return timelocal(0, 0, 0, 1, 0, $at->year + $offset) * 1000;
		}
		if ($unit eq 'month') {
			my $index = $at->year * 12 + ($at->mon - 1) + $offset;
			return timelocal(0, 0, 0, 1, $index % 12, int($index / 12)) * 1000;
		}
		if ($unit eq 'week') {
			my $back = ($at->strftime('%w') - $week_start + 7) % 7;
			my $opens = timegm(0, 0, 0, $at->mday, $at->mon - 1, $at->year) - $back * 86400;
			my @date = gmtime($opens + 7 * $offset * 86400);
			return timelocal(0, 0, 0, $date[3], $date[4], $date[5]) * 1000;
		}
		my @date = gmtime(timegm(0, 0, 0, $at->mday, $at->mon - 1, $at->year) + $offset * 86400);
		return timelocal(0, 0, 0, $date[3], $date[4], $date[5]) * 1000;
	};
	my $begin = $start->(0);
	my $end = $start->(1);
	my $fraction = ($end > $begin) ? ($now - $begin) / ($end - $begin) : 1;
	$fraction = 0 if $fraction < 0;
	$fraction = 1 if $fraction > 1;
	return ($begin, $end, $fraction);
}

# the label of each of the last $n periods of a scope, oldest first, in the same
# form the SQL bucket produces
sub period_trend_labels {
	my ($unit, $n, $now) = @_;
	my @labels;
	if ($unit eq 'minute') {
		for (my $i = $n - 1; $i >= 0; $i--) {
			my @lt = localtime(($now - $i * 60000) / 1000);
			push @labels, sprintf('%04d-%02d-%02dT%02d:%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1]);
		}
	}
	elsif ($unit eq 'hour') {
		for (my $i = $n - 1; $i >= 0; $i--) {
			my @lt = localtime(($now - $i * 3600000) / 1000);
			push @labels, sprintf('%04d-%02d-%02dT%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2]);
		}
	}
	elsif ($unit eq 'day') {
		for (my $i = $n - 1; $i >= 0; $i--) {
			my @lt = localtime(($now - $i * 86400000) / 1000);
			push @labels, sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
		}
	}
	elsif ($unit eq 'week') {
		my $dow = (localtime($now / 1000))[6];
		my $monday = $now - (($dow + 6) % 7) * 86400000;
		for (my $i = $n - 1; $i >= 0; $i--) {
			my @m = localtime(($monday - $i * 7 * 86400000) / 1000);
			push @labels, sprintf('%04d-%02d-%02d', $m[5] + 1900, $m[4] + 1, $m[3]);
		}
	}
	elsif ($unit eq 'month') {
		my @lt = localtime($now / 1000);
		my ($y, $mo) = ($lt[5] + 1900, $lt[4]);
		my @rev;
		for (my $i = 0; $i < $n; $i++) {
			my $mm = $mo - $i;
			my $yy = $y;
			while ($mm < 0) { $mm += 12; $yy--; }
			push @rev, sprintf('%04d-%02d', $yy, $mm + 1);
		}
		@labels = reverse @rev;
	}
	elsif ($unit eq 'year') {
		my $y = (localtime($now / 1000))[5] + 1900;
		for (my $i = $n - 1; $i >= 0; $i--) { push @labels, sprintf('%04d', $y - $i); }
	}
	return @labels;
}

# The last few periods of every scope, oldest first, as "label=count ..." - the
# same compact shape as a window's daily_counts, but for month, week, day, hour
# and minute as well, so the model reads the pace period by period. $count is the
# app's own scope count (how many periods its graph walks), capped per scope so
# the short clocks do not swamp the prompt.
sub evaluation_period_trends {
	my ($app, $count) = @_;
	return {} unless $app && $app ne '__president';
	$count = 30 unless $count && $count =~ /^[0-9]+$/ && $count > 0;
	my $now = &subs::rightNow();
	my $out = {};
	foreach my $unit ( qw/minute hour day week month year/ ) {
		my $spec = $PERIOD_TREND{$unit};
		my $n = $count < $spec->{'cap'} ? $count : $spec->{'cap'};
		my @labels = &subs::period_trend_labels($unit, $n, $now);
		next unless scalar @labels;
		# a period ahead of the oldest label can still start within a week/month
		# of it, so the scan reaches back one period further than the labels
		my $since = $now - ($n + 1) * $spec->{'seconds'} * 1000;
		my $rows = &subs::db_query(
			'select ' . $spec->{'bucket'} . ' as bucket, count(*) as c from appointments where app = ? and cast(timestamp as integer) >= ? group by bucket',
			$app, $since)->hashes;
		my %c = map { $_->{'bucket'} => ($_->{'c'} + 0) } @{$rows};
		# a scope with nothing at all in its window says nothing a trend can use - an
		# hourly app is quiet across the last thirty minutes by design - so it is left
		# out rather than handed over as a row of zeros the model might remark on
		next unless grep { $c{$_} } @labels;
		# the newest period is the one still running, so its count is a part of a
		# period, not a whole one. It is handed over as label=count/percent, the
		# percent saying how far through that period the run happened, so a low count
		# early in the period reads as a period in progress rather than a pace falling
		# away. The label buckets start their weeks on Monday, so the fraction is read
		# from the same Monday.
		my $newest = $labels[-1];
		my (undef, undef, $elapsed) = &period_bounds($unit, $now, 1);
		my $percent = int($elapsed * 100 + 0.5);
		$out->{$unit} = join ' ', map {
			$_ eq $newest ? $_ . '=' . ($c{$_} || 0) . '/' . $percent . '%' : $_ . '=' . ($c{$_} || 0)
		} @labels;
	}
	return $out;
}

# every day of the window, so a lag stays a lag in calendar days even when a
# series has holes in it
sub evaluation_window_days {
	my ($since) = @_;
	my $now = &subs::rightNow();
	my @days;
	for (my $t = $since; $t <= $now + 86400000; $t += 86400000) {
		my @lt = localtime($t / 1000);
		push @days, sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
	}
	my %seen;
	return [ grep { !$seen{$_}++ } @days ];
}

# Pearson over day maps that may have holes - a day without a reading is not a
# zero reading - joined on the window's days, so the best lag is in days
sub day_map_correlation {
	my ($da, $db, $days) = @_;
	my $n = scalar @{$days};
	my ($best, $best_lag);
	foreach my $lag ( -2 .. 2 ) {
		my ($sx,$sy,$sxx,$syy,$sxy,$m) = (0,0,0,0,0,0);
		foreach my $i ( 0 .. $n - 1 ) {
			my $j = $i + $lag;
			next if $j < 0 || $j > $n - 1;
			my $xa = $da->{ $days->[$i] };
			my $yb = $db->{ $days->[$j] };
			next unless defined $xa && defined $yb;
			$sx += $xa; $sy += $yb; $sxx += $xa ** 2; $syy += $yb ** 2; $sxy += $xa * $yb; $m++;
		}
		next if $m < 14;
		my $den = sqrt(($m * $sxx - $sx ** 2) * ($m * $syy - $sy ** 2));
		next unless $den;
		my $r = ($m * $sxy - $sx * $sy) / $den;
		if (!defined $best || abs($r) > abs($best)) { $best = $r; $best_lag = $lag; }
	}
	return undef unless defined $best;
	return { r => sprintf('%.2f', $best), lag_days => $best_lag };
}

# Two series that both run on nearly every day of the window correlate by
# construction - the calendar, not a cause. The maps that can have holes
# (measured readings) count a day by being defined, the others by being non-zero.
sub daily_habit {
	my ($da, $db, $days, $da_holes, $db_holes) = @_;
	my $n = scalar @{$days};
	return 0 unless $n;
	my $a = $da_holes ? (grep { defined $da->{$_} } @{$days}) : (grep { ($da->{$_} || 0) != 0 } @{$days});
	my $b = $db_holes ? (grep { defined $db->{$_} } @{$days}) : (grep { ($db->{$_} || 0) != 0 } @{$days});
	return 0 unless $a >= 0.8 * $n && $b >= 0.8 * $n;
	return 1;
}

# what else was happening: every app's daily counts and every numeric measure
# any app logged, correlated against the targets. The relational window only
# knows the apps it was shown, so a headache never gets to blame the humidity
# unless it is asked to look at the whole house.
sub context_correlations {
	my ($targets, $days, $counts, $measures) = @_;
	my @candidates;
	foreach my $capp ( sort keys %{$counts} ) {
		push @candidates, { app => $capp, measure => undef, day_map => $counts->{$capp} };
	}
	foreach my $capp ( sort keys %{$measures} ) {
		foreach my $name ( sort keys %{$measures->{$capp}} ) {
			push @candidates, { app => $capp, measure => $name, day_map => $measures->{$capp}->{$name} };
		}
	}
	# a source that shows up on nearly every day is a schedule, not a signal: a
	# metal price, a weather reading or a currency quote fetched every day
	# correlates with everything by construction. Its presence is filtered out
	# before it can be offered as a finding; a reading that actually comes and
	# goes (fewer days, real movement) still gets its chance.
	my $n_days = scalar @{$days};
	foreach my $cand ( @candidates ) {
		my $holes = defined $cand->{'measure'};
		my $present = $holes ? (grep { defined $cand->{'day_map'}->{$_} } @{$days}) : (grep { ($cand->{'day_map'}->{$_} || 0) != 0 } @{$days});
		$cand->{'presence'} = $n_days ? $present / $n_days : 1;
	}
	my @out;
	foreach my $target ( @{$targets} ) {
		my $tseries = $target->{'measure'} ? ($measures->{ $target->{'app'} }->{ $target->{'measure'} } || {}) : ($counts->{ $target->{'app'} } || {});
		next unless scalar keys %{$tseries};
		my @tx = $target->{'measure'} ? () : map { $tseries->{$_} || 0 } @{$days};
		# a target that barely ran cannot carry a count correlation - the pair
		# would be the target's one day wearing the candidate's habits. Sparse
		# days are the different list's business instead.
		my $target_active = grep { ($tseries->{$_} || 0) > 0 } @{$days};
		foreach my $cand ( @candidates ) {
			# a series is not a story against itself
			next if $cand->{'app'} eq $target->{'app'} && !defined $cand->{'measure'} && !defined $target->{'measure'};
			next if $cand->{'app'} eq $target->{'app'} && defined $cand->{'measure'} && defined $target->{'measure'} && $cand->{'measure'} eq $target->{'measure'};
			next if $cand->{'presence'} >= 0.8;
			my $c;
			if (!defined $cand->{'measure'} && !defined $target->{'measure'}) {
				my @cx = map { $cand->{'day_map'}->{$_} || 0 } @{$days};
				$c = ($target_active >= 7) ? &subs::series_correlation(\@cx, \@tx) : undef;
			}
			else {
				# a count of nothing on a day is zero, but a missing reading is a hole
				my $cmap = defined $cand->{'measure'} ? $cand->{'day_map'} : { map { $_ => ($cand->{'day_map'}->{$_} || 0) } @{$days} };
				my $tmap = defined $target->{'measure'} ? $tseries : { map { $_ => ($tseries->{$_} || 0) } @{$days} };
				$c = &subs::day_map_correlation($cmap, $tmap, $days);
			}
			next unless $c && abs($c->{'r'}) >= 0.6;
			my $entry = { app => $cand->{'app'}, vs_app => $target->{'app'}, r => $c->{'r'}, lag_days => $c->{'lag_days'} };
			$entry->{'measure'} = $cand->{'measure'} if defined $cand->{'measure'};
			$entry->{'vs_measure'} = $target->{'measure'} if defined $target->{'measure'};
			$entry->{'habit'} = 1 if &subs::daily_habit($cand->{'day_map'}, $tseries, $days, defined $cand->{'measure'}, defined $target->{'measure'});
			push @out, $entry;
		}
	}
	# the arms-length list leads with the pairs that are not just two daily
	# habits; the habits still trail it, flagged, so the report can name them
	@out = sort { ($a->{'habit'} || 0) <=> ($b->{'habit'} || 0) || abs($b->{'r'}) <=> abs($a->{'r'}) } @out;
	splice(@out, 10) if scalar @out > 10;
	return \@out;
}

# What ran around this app's own occurrences: for each occurrence, the other
# apps whose occurrences fall within a window either side of it, so a thing that
# consistently happens at the same time of day - the coffee after waking, the
# walk after lunch, the code right after the coffee - stands out. A correlation
# of daily totals drowns that in the calendar (two daily routines move together
# by construction); an event read asks instead how often the thing was actually
# there when this one happened, against how often chance would put it there.
# Returns the apps that co-occur more than chance, each with how many of this
# app's occurrences had it nearby (hits), how many were scanned (of), the lift
# over chance, and the average offset in minutes (negative when it tends to come
# before this app, positive after).
sub evaluation_context_scan {
	my ($app, $since, $delta, $cap) = @_;
	return [] unless $app && $app ne '__president';
	$since = &subs::rightNow() - 60 * 86400000 unless $since;
	$delta = 30 * 60000 unless $delta && $delta > 0;
	$cap ||= 8;
	my $rows = &subs::db_query('select app, cast(timestamp as integer) as ts from appointments where cast(timestamp as integer) >= ? order by ts', $since)->hashes;
	my @all = map { { ts => $_->{'ts'} + 0, app => $_->{'app'} } } @{$rows};
	return [] unless scalar @all;
	my $span = &subs::rightNow() - $since;
	$span = 1 unless $span > 0;
	my (%total, @targets);
	foreach my $e ( @all ) {
		$total{ $e->{'app'} }++;
		push @targets, $e->{'ts'} if $e->{'app'} eq $app;
	}
	return [] unless scalar @targets >= 3;
	# a sliding window over the sorted events: as the occurrence walks forward,
	# events enter at the far edge and leave at the near one, so one pass counts
	# the co-occurrences and their signed offsets
	my (%hits, %offset, %count, %tsum);
	my ($lo, $hi) = (0, 0);
	my $N = scalar @all;
	foreach my $t ( @targets ) {
		while ($hi < $N && $all[$hi]{'ts'} <= $t + $delta) { my $a = $all[$hi]{'app'}; $count{$a}++; $tsum{$a} += $all[$hi]{'ts'}; $hi++; }
		while ($lo < $hi && $all[$lo]{'ts'} < $t - $delta) { my $a = $all[$lo]{'app'}; $count{$a}--; $tsum{$a} -= $all[$lo]{'ts'}; $lo++; }
		foreach my $y ( keys %count ) {
			next if $y eq $app || !$count{$y};
			$hits{$y} += $count{$y};
			$offset{$y} += $tsum{$y} - $t * $count{$y};
		}
	}
	my $nX = scalar @targets;
	my @out;
	foreach my $y ( keys %hits ) {
		next unless $total{$y};
		my $expect = $nX * $total{$y} * (2 * $delta) / $span;
		next if $expect <= 0;
		my $lift = $hits{$y} / $expect;
		next if $hits{$y} < 4 || $lift < 1.5;
		push @out, {
			app => $y,
			hits => $hits{$y},
			of => $nX,
			lift => sprintf('%.1f', $lift),
			offset_minutes => sprintf('%.0f', $offset{$y} / $hits{$y} / 60000),
		};
	}
	@out = sort { $b->{'lift'} <=> $a->{'lift'} || $b->{'hits'} <=> $a->{'hits'} } @out;
	splice(@out, $cap) if scalar @out > $cap;
	return \@out;
}

# what was out of the ordinary on the days this app ran: every measure's
# average on those days against its average on the window's other days, scaled
# by how spread the measure is. A sparse app can still point at a reading this
# way, which a correlation needs too many days to do.
sub measure_contrasts {
	my ($app, $days, $counts, $measures) = @_;
	my %active = map { $_ => 1 } keys %{ $counts->{$app} || {} };
	my @out;
	foreach my $capp ( sort keys %{$measures} ) {
		foreach my $name ( sort keys %{$measures->{$capp}} ) {
			my (@on, @off);
			foreach my $day ( @{$days} ) {
				my $v = $measures->{$capp}->{$name}->{$day};
				next unless defined $v;
				if ($active{$day}) { push @on, $v; } else { push @off, $v; }
			}
			# one day with the app is the case this list exists for - a single
			# headache against the rest of the month - so only the other side
			# needs some width to it
			next if scalar @on < 1 || scalar @off < 3;
			my ($sum_all, $sum_on, $n_all) = (0, 0, 0);
			foreach my $v ( @on ) { $sum_on += $v; $sum_all += $v; $n_all++; }
			foreach my $v ( @off ) { $sum_all += $v; $n_all++; }
			my $mean_on = $sum_on / scalar @on;
			my $mean_off = ($sum_all - $sum_on) / scalar @off;
			my $mean = $sum_all / $n_all;
			my $var = 0;
			$var += ($_ - $mean) ** 2 foreach ( @on, @off );
			my $sd = sqrt($var / $n_all);
			next unless $sd;
			# a measure that barely moves (a currency quote) turns a cent into a
			# large z: the list is for readings that actually vary
			next unless $sd >= 0.03 * abs($mean);
			my $z = ($mean_on - $mean_off) / $sd;
			next unless abs($z) >= 0.8;
			push @out, {
				app => $capp, measure => $name,
				on_days => &subs::briefing_number($mean_on),
				off_days => &subs::briefing_number($mean_off),
				z => &subs::briefing_number($z),
				days_on => scalar @on, days_off => scalar @off,
			};
		}
	}
	@out = sort { abs($b->{'z'}) <=> abs($a->{'z'}) } @out;
	splice(@out, 8) if scalar @out > 8;
	return \@out;
}

# Every AI provider the Platform panel can point a model at, and the models each
# offers. A model is chosen by id: a bare name goes to the local Ollama,
# @cf/... to Cloudflare, and everything else is "provider:model".
sub ai_providers() {
	return [
		{ id => 'ollama',     label => 'Ollama (local)',        keys => [ [ 'ollama_key', 'API key (optional)' ] ] },
		{ id => 'cloudflare', label => 'Cloudflare Workers AI', keys => [ [ 'cloudflare_account', 'Account ID' ], [ 'cloudflare_token', 'API token' ] ] },
		{ id => 'openai',     label => 'OpenAI',                keys => [ [ 'openai_key', 'API key' ] ],
			models => [ qw/gpt-4o gpt-4o-mini gpt-4.1 gpt-4.1-mini o3-mini o1/ ] },
		{ id => 'anthropic',  label => 'Anthropic (Claude)',    keys => [ [ 'anthropic_key', 'API key' ] ],
			models => [ qw/claude-sonnet-4-20250514 claude-opus-4-20250514 claude-3-7-sonnet-latest claude-3-5-sonnet-latest claude-3-5-haiku-latest/ ] },
		{ id => 'google',     label => 'Google (Gemini)',       keys => [ [ 'google_key', 'API key' ] ],
			models => [ qw/gemini-2.5-pro gemini-2.5-flash gemini-2.0-flash veo-3.0-generate-preview veo-3.1-generate-preview/ ] },
		{ id => 'xai',        label => 'xAI (Grok)',            keys => [ [ 'xai_key', 'API key' ] ],
			models => [ qw/grok-3 grok-3-mini grok-2-1212/ ] },
		{ id => 'deepseek',   label => 'DeepSeek',              keys => [ [ 'deepseek_key', 'API key' ] ],
			# The ids must match DeepSeek's API exactly; its /models lists these two
			# (deepseek-flash is V4.1 Flash, deepseek-v4-pro the pro).
			models => [ qw/deepseek-flash deepseek-v4-pro/ ] },
		{ id => 'mistral',    label => 'Mistral',               keys => [ [ 'mistral_key', 'API key' ] ],
			models => [ qw/mistral-large-latest mistral-small-latest codestral-latest/ ] },
		{ id => 'groq',       label => 'Groq',                  keys => [ [ 'groq_key', 'API key' ] ],
			models => [ qw/llama-3.3-70b-versatile llama-3.1-8b-instant mixtral-8x7b-32768 whisper-large-v3-turbo playai-tts/ ] },
		{ id => 'openrouter', label => 'OpenRouter',            keys => [ [ 'openrouter_key', 'API key' ] ],
			models => [ qw{openai/gpt-4o anthropic/claude-3.5-sonnet meta-llama/llama-3.3-70b-instruct google/gemini-2.0-flash-001} ] },
	];
}

# Every setting name that holds a secret, so a panel can tell a key from a value.
sub ai_key_settings() {
	return map { $_->[0] } map { @{ $_->{'keys'} } } @{ &subs::ai_providers() };
}

# Whether a provider can answer here at all: the key (or account) it needs is
# entered, and for the local Ollama the daemon is actually running. "Valid"
# beyond that is only knowable by calling it - the bucket tracker already stands
# down an account that answered with no credit, and the Plat panel hides those
# paid models. The model lists only offer providers that pass this.
sub ai_provider_ready {
	my ($id) = @_;
	return 0 unless defined $id && length $id;
	# a peer's own Ollama we hold a cached model list for is offered by its device
	return 1 if $id =~ /^ollama:/;
	my ($p) = grep { ($_->{'id'} || '') eq $id } @{ &subs::ai_providers() };
	return 0 unless $p;
	if ($id eq 'ollama') {
		my $ua = Mojo::UserAgent->new(connect_timeout => 2, inactivity_timeout => 3, request_timeout => 4);
		my $res = eval { $ua->get('http://localhost:11434/api/tags')->result };
		return ($res && $res->is_success) ? 1 : 0;
	}
	my $values = &subs::settings_grabber({ app => 'mail', settings => [ map { $_->[0] } @{ $p->{'keys'} || [] } ] });
	foreach my $k ( @{ $p->{'keys'} || [] } ) {
		my $v = $values->{ $k->[0] };
		return 0 unless defined $v && length $v;
	}
	return 1;
}

# The model choices, grouped by provider, for the dropdowns. Ollama and
# Cloudflare are read live; the rest are the fixed lists above.
#
# Which of chat / vision / image / audio a model can serve, so a role only offers
# models that fit it: a text chatbot is not offered a vision-only model, and the
# Vision role is not offered a plain text one. A name is the only signal for most
# providers, so this is a heuristic and errs toward 'chat'.
sub ai_model_caps_by_name {
	my ($name) = @_;
	my $n = lc($name || '');
	return ('image') if $n =~ /(dall-e|gpt-image|stable-?diffusion|sdxl|sd3|flux|imagen|playground-v2|kandinsky|dreamshaper|lucid|phoenix|text-to-image|text2image)/;
	return ('video-gen') if $n =~ /(veo|runway|sora|video-?gen|text-?to-?video|image-?to-?video|stable-?video|kling|luma|mochi|pika|wan-?video|haiper|flux-?video)/;
	return ('audio-gen') if $n =~ /(musicgen|audio-?gen|music-?gen|audio-?lm|suno|riffusion|stable-?audio|bark|elevenlabs|melod|melotts|aura-|\btts\b|speech-?synth)/;
	return ('audio') if $n =~ /(whisper|asr|transcri|speech-to-text|\bstt\b|deepgram|nova-?2|parakeet)/;
	return ('other') if $n =~ /(embed|rerank|\bbge\b|resnet|distilbert|sst-2|translat|m2m100|indictrans|guard|smart-turn|moderation)/;
	return ('vision') if $n =~ /(llava|bakllava|moondream|minicpm-?v|cogvlm|pixtral|qwen2-?vl|qwen2\.5-?vl|qwen2\.5vl|internvl|llama-?3\.2-vision|vision)/;
	return ('chat', 'vision') if $n =~ /(gpt-4o|gpt-4\.1|claude|gemini|gemma3|gemma4|grok-2-vision|grok-vision)/;
	return ('chat');
}

sub ai_model_caps_by_task {
	my ($task) = @_;
	my $t = lc($task || '');
	return ('image') if $t =~ /text-to-image|image generation|image-to-image|inpaint|image editing/;
	return ('video-gen') if $t =~ /text-to-video|video generation|image-to-video/;
	return ('audio-gen') if $t =~ /audio generation|text-to-audio|music/;
	return ('vision') if $t =~ /image-to-text|visual question|image classification|object detection|vision/;
	return ('audio') if $t =~ /speech|audio|asr|text-to-speech|tts/;
	return ('chat') if $t =~ /text generation|conversational|summariz|chat/;
	return ('other');
}

sub ai_model_caps {
	my ($provider, $name, $meta) = @_;
	my $task = '';
	if (ref $meta eq 'HASH' && defined $meta->{'task'}) {
		# Cloudflare's search returns task as an object { id, name } in some versions
		$task = ref $meta->{'task'} eq 'HASH' ? ($meta->{'task'}->{'name'} || $meta->{'task'}->{'id'} || '') : $meta->{'task'};
		$task = '' if ref $task;
	}
	if ($provider eq 'cloudflare' && $task) {
		return &ai_model_caps_by_task($task);
	}
	my $family = (ref $meta eq 'HASH' && ref $meta->{'details'} eq 'HASH') ? ($meta->{'details'}->{'family'} || '') : '';
	return &ai_model_caps_by_name($family ? ($name . ' ' . $family) : $name);
}

# Which provider a model id points at. A bare name (and a :cloud one) goes to
# Ollama; @cf/... to Cloudflare; the rest are "provider:model".
sub ai_model_provider {
	my ($model) = @_;
	return 'cloudflare' if $model =~ /^\@cf/;
	# a peer's own Ollama: @<device>/<model>, so a model can be picked by the
	# machine that runs it
	return 'ollama_remote' if $model =~ /^\@[^\/]+\/.+$/;
	return $1 if $model =~ /^([a-z]+):/ && grep { $_ eq $1 } qw/openai anthropic google xai mistral groq openrouter deepseek/;
	return 'ollama';
}

# The machine a @<device>/<model> names, or ''.
sub ai_model_device {
	my ($model) = @_;
	return $1 if $model =~ /^\@([^\/]+)\/.+$/;
	return '';
}

# The billing bucket a model draws on. Local Ollama and Cloudflare (its plan is
# included) are free; an Ollama :cloud model and every third-party provider cost.
sub ai_model_bucket {
	my ($model) = @_;
	my $provider = &ai_model_provider($model);
	return 'ollama_cloud' if ($provider eq 'ollama' || $provider eq 'ollama_remote') && $model =~ /:cloud\b/i;
	return $provider;
}

sub ai_model_paid {
	my ($model) = @_;
	my $bucket = &ai_model_bucket($model);
	return 0 if $bucket eq 'cloudflare' || $bucket eq 'ollama' || $bucket eq 'ollama_remote';
	return 1;
}

# A provider that has answered "no credit" is stood down for a while, so the panel
# can hide its paid models and chat can step down to a free one.
my $AI_UNAVAILABLE_FOR = 30 * 60 * 1000;
# the model that actually answered the last ai_chat (a paid one may stand down)
our $ai_last_model;
# what model calls have cost, running (calls, in, out tokens): the error watch
# reads it around a proposal to log the spend and to stop at its day's budget
our $ai_tokens = { calls => 0, in => 0, out => 0, unmetered => 0 };
sub ai_bucket_available {
	my ($bucket) = @_;
	return 1 unless $bucket;
	my $until = &subs::setting_grabber({ app => '__president', setting => 'ai_' . $bucket . '_unavailable' });
	return 1 unless $until && $until > &subs::rightNow();
	return 0;
}
sub ai_bucket_mark_unavailable {
	my ($bucket, $reason) = @_;
	return unless $bucket;
	&subs::setting_setter({ app => '__president', setting => 'ai_' . $bucket . '_unavailable', value => &subs::rightNow() + $AI_UNAVAILABLE_FOR });
	&subs::say_it('AI: ' . $bucket . ' looks out of credit; standing it down for a while (' . substr($reason || '', 0, 80) . ')');
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

sub ai_chat_raw {
	my ($model, $messages, $thinking) = @_;
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
		if (grep { $_ eq $1 } qw/openai anthropic google xai mistral groq openrouter deepseek/) { ($provider, $real) = ($1, $2); }
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
		return ($rbody, undef) if $rbody->{'message'} || $rbody->{'response'};
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
			groq => 'https://api.groq.com/openai/v1/chat/completions',
			openrouter => 'https://openrouter.ai/api/v1/chat/completions',
			deepseek => 'https://api.deepseek.com/chat/completions',
		);
		my %key = ( openai => 'openai_key', xai => 'xai_key', mistral => 'mistral_key', groq => 'groq_key', openrouter => 'openrouter_key', deepseek => 'deepseek_key' );
		$url = $ep{$provider};
		$headers = { 'Authorization' => 'Bearer ' . $secret->($settings->{ $key{$provider} }), 'Content-Type' => 'application/json' };
		$payload = { model => $real, messages => [ { role => 'system', content => $system }, @wire ], stream => \0 };
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
		return (undef, 'the model answered ' . $res->code . ': ' . substr($res->body || '', 0, 200));
	}
	my $body = eval { return $res->json } || {};
	# Account what the call cost, so the error watch can log its spend and stop
	# when the day's purse is empty. Providers differ in shape (an OpenAI-style
	# usage, Cloudflare's own), so take whatever is there.
	my $usage = $body->{'usage'} || $body->{'result'}->{'usage'} || {};
	my $in = $usage->{'prompt_tokens'};
	$in = $usage->{'input_tokens'} unless defined $in;
	my $out = $usage->{'completion_tokens'};
	$out = $usage->{'output_tokens'} unless defined $out;
	$ai_tokens->{'calls'}++;
	$ai_tokens->{'in'} += ($in // 0);
	$ai_tokens->{'out'} += ($out // 0);
	$ai_tokens->{'unmetered'}++ unless defined $in || defined $out;
	return ($body, undef);
}

# The reply as parts, so a caller can take more than the words (an image a
# multimodal model returns, and the shape to grow into audio/video later). A paid
# model whose bucket is stood down steps down to a free one here, so every caller
# gets the fallback.
sub ai_chat_parts {
	my ($model, $messages, $thinking) = @_;
	if (&ai_model_paid($model) && !&ai_bucket_available(&ai_model_bucket($model))) {
		my $free = &ai_free_model();
		if ($free) { &subs::say_it('AI: ' . $model . ' is stood down (no credit); using the free model ' . $free); $model = $free; }
	}
	my ($body, $err) = &ai_chat_raw($model, $messages, $thinking);
	$ai_last_model = $model;
	# a fresh credit failure (marked down inside the call) also falls back, once
	if ($err && &ai_model_paid($model)) {
		my $free = &ai_free_model();
		if ($free && $free ne $model) {
			my ($body2, $err2) = &ai_chat_raw($free, $messages, $thinking);
			if (!$err2) { ($body, $err) = ($body2, undef); $model = $free; $ai_last_model = $model; &subs::say_it('AI: answered with the free model ' . $free); }
		}
	}
	return (undef, $err) if $err;
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
	my ($model, $messages, $thinking) = @_;
	my ($parts, $err) = &ai_chat_parts($model, $messages, $thinking);
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

# One role's chat call, retried on the role's fallback model when the primary
# errors (an outage). The fallback is the same catalogue minus the primary, set
# in Configure -> Plat beside the model.
sub ai_chat_parts_role {
	my ($role, $messages, $thinking) = @_;
	my ($primary, $fallback) = &ai_role_models($role);
	return (undef, "no $role model is set") unless $primary;
	my ($parts, $err) = &ai_chat_parts($primary, $messages, $thinking);
	return ($parts, undef) unless $err;
	if ($fallback && $fallback ne $primary) {
		&subs::say_it('AI: ' . $role . ' failed (' . $err . '); trying the fallback ' . $fallback);
		return &ai_chat_parts($fallback, $messages, $thinking);
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
	my ($primary, $fallback, $messages, $thinking) = @_;
	return (undef, 'no model given') unless $primary;
	my ($parts, $err) = &ai_chat_parts($primary, $messages, $thinking);
	return ($parts, undef) unless $err;
	if ($fallback && $fallback ne $primary) {
		&subs::say_it('AI: ' . $primary . ' failed (' . $err . '); trying the fallback ' . $fallback);
		return &ai_chat_parts($fallback, $messages, $thinking);
	}
	return (undef, $err);
}

sub evaluation_model_call_with_fallback {
	my ($primary, $fallback, $system, $user, $thinking) = @_;
	return &ai_chat_with_fallback($primary, $fallback, [ { role => 'system', content => $system }, { role => 'user', content => $user } ], $thinking);
}

sub ai_chat_with_fallback {
	my ($primary, $fallback, $messages, $thinking) = @_;
	my ($parts, $err) = &ai_chat_parts_with_fallback($primary, $fallback, $messages, $thinking);
	return (undef, $err) if $err;
	my $text = join '', map { $_->{'text'} } grep { ($_->{'type'} || '') eq 'text' } @{$parts || []};
	return ($text, ($text && length $text) ? undef : 'the model returned nothing readable');
}

sub evaluation_model_call() {
	my ($model, $system, $user, $thinking) = @_;
	return &subs::ai_chat($model, [ { role => 'system', content => $system }, { role => 'user', content => $user } ], $thinking);
}

# Whether this machine can actually run the evaluation right now. The wish to
# evaluate is shared but the queue is per-machine, so a machine with no ollama
# or not carrying the chosen model would otherwise run the night and answer
# with a connection error. A blank model is never available.
sub evaluation_model_available {
	my ($model) = @_;
	return 0 unless $model;
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'cloudflare_account', 'cloudflare_token', @{ &subs::ai_key_settings() } ] });
	if ($model =~ /^\@cf/) {
		return ($settings->{'cloudflare_account'} && $settings->{'cloudflare_token'}) ? 1 : 0;
	}
	if ($model =~ /^([a-z]+):/) {
		my %key = ( openai => 'openai_key', anthropic => 'anthropic_key', google => 'google_key', xai => 'xai_key', mistral => 'mistral_key', groq => 'groq_key', openrouter => 'openrouter_key', deepseek => 'deepseek_key' );
		return $settings->{ $key{$1} } ? 1 : 0 if $key{$1};
	}
	# ollama: the daemon has to answer and the model has to be one it knows
	my $ua = Mojo::UserAgent->new(connect_timeout => 3, inactivity_timeout => 5, request_timeout => 8);
	my $res = eval { $ua->get('http://localhost:11434/api/tags')->result };
	return 0 unless $res && $res->is_success;
	my $body = eval { $res->json } || {};
	foreach my $m ( @{ $body->{'models'} || [] } ) {
		return 1 if ($m->{'name'} || '') eq $model || ($m->{'model'} || '') eq $model;
	}
	return 0;
}

sub evaluation_period_span {
	my ($period) = @_;
	return 7 * 86400000 if ($period || '') eq 'week';
	return 30 * 86400000 if ($period || '') eq 'month';
	return 86400000;
}

# The app's own budget, held against the window the evaluation rolled up. The
# setting is a comma list of <amount>/<scope> entries - 17h/week, 7.0/w,
# $50/M - and each is scaled to the window before it meets its actual, so a
# month of readings of a weekly budget is still the same budget. Before this,
# the report could see how long an app ran but never whether running that
# long was over the line.
sub budget_holding {
	my ($app, $since, $act, $budget) = @_;
	$budget = &subs::setting_grabber({ app => $app, setting => 'budget' }) unless defined $budget;
	return [] unless $budget;
	my $window = &subs::rightNow() - $since;
	return [] unless $window > 0;
	$act = {} unless $act;
	my @out;
	my $money;
	foreach my $entry ( split ',', $budget ) {
		# an entry with no scope says nothing a window can be held against
		my ($amount, $scope) = split '/', $entry;
		next unless defined $amount && defined $scope && $scope =~ /\w/;
		$scope = '1' . $scope unless $scope =~ /[0-9]/;
		my $scope_ms = &subs::time_abbrev_translator($scope);
		next unless $scope_ms && $scope_ms > 0;
		my $scale = $window / $scope_ms;
		if ($amount =~ /^\s*\$/) {
			my $expected = ($amount =~ s/[^0-9.]//gr) * $scale;
			next unless $expected > 0;
			unless (defined $money) {
				$money = &subs::db_query('select sum(abs(coalesce(total,0))) as total from appointments where app = ? and cast(timestamp as integer) >= ?', $app, $since)->hash->{'total'};
				$money = 0 unless defined $money;
			}
			push @out, {
				of => 'total', budget => $entry,
				expected => &subs::price_formatter($expected),
				actual => &subs::price_formatter($money),
				percentage => int(100 * $money / $expected + 0.5),
				over => $money > $expected ? 1 : 0,
			};
		}
		elsif ($amount =~ /[a-zA-Z]/) {
			my $expected = &subs::time_abbrev_translator($amount) * $scale;
			next unless $expected > 0;
			my $actual = $act->{'duration'} || 0;
			push @out, {
				of => 'duration', budget => $entry,
				expected => &subs::duration_sayer($expected / 1000),
				actual => &subs::duration_sayer($actual / 1000),
				percentage => int(100 * $actual / $expected + 0.5),
				over => $actual > $expected ? 1 : 0,
			};
		}
		else {
			my $expected = $amount * $scale;
			next unless $expected > 0;
			my $actual = $act->{'count'} || 0;
			push @out, {
				of => 'occurences', budget => $entry,
				expected => int($expected + 0.5),
				actual => $actual + 0,
				percentage => int(100 * $actual / $expected + 0.5),
				over => $actual > $expected ? 1 : 0,
			};
		}
	}
	return \@out;
}

sub evaluation_agent() {
	my ($app, $period) = @_;
	$app = '__president' unless $app && $app ne '';
	my $global = ($app eq '__president');
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'eval_assistant' ] });
	my $model = $settings->{'eval_assistant'};
	my $now = &subs::rightNow();
	my $machine = &subs::setting_grabber({ app => 'me', setting => 'my_name' }) || '';
	# The windows the report reads, shortest first. A change of pace only shows
	# against a longer one, so every run weighs them all rather than one: the
	# per-day rate over a day against the week against the year against all time
	# is what a trend is.
	my @window_defs = (
		{ name => 'day',   span => 86400000,       label => 'the last 24 hours' },
		{ name => 'week',  span => 7 * 86400000,   label => 'the last 7 days' },
		{ name => 'month', span => 30 * 86400000,  label => 'the last 30 days' },
		{ name => 'year',  span => 365 * 86400000, label => 'the last 365 days' },
		{ name => 'all',   span => 0,              label => 'all time' },
	);
	my %roll;
	my %snapshot;
	my $windows = {};
	# the app's own measure definitions carry each reading's unit and the range it
	# is set to expect; read once, so every window speaks its readings the same way
	my $measure_defs = $global ? {} : (eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {});
	# the last few periods of every clock the inventory graphs - month by month,
	# week by week, day by day, hour by hour, minute by minute - so a trend is read
	# from the shape of the pace, not one span's total. The count is the app's own
	# scope count (how many periods its graph walks).
	my $trends = $global ? {} : &subs::evaluation_period_trends($app, &subs::setting_grabber({ app => $app, setting => 's_scope_count' }));
	# the app's own unit of activity - nights, cups, sessions, walks - read for the
	# report so a day's count does not hide the shape of a single episode
	my $episodes = $global ? {} : &subs::evaluation_episodes($app, $now - 90 * 86400000);
	# the schedule this scope is on, so the report knows how often it is asked for
	# on its own and when the next run is due - the configuration the controls show
	my $schedule;
	{
		my $cadence = &subs::evaluation_cadence($app);
		if ($cadence && $cadence ne 'off') {
			my @day_names = qw/sunday monday tuesday wednesday thursday friday saturday/;
			my @days = map { $day_names[$_] } @{ &subs::nightly_evaluation_days($app) };
			my $sch = &subs::nightly_evaluation_schedule($app);
			$schedule = {
				cadence => $cadence,
				(@days ? (days => \@days) : ()),
				($sch && $sch->{'next_run'} ? (next_run => $sch->{'next_run'}) : ()),
			};
		}
	}
	foreach my $wd ( @window_defs ) {
		my $since = $wd->{'span'} ? ($now - $wd->{'span'}) : 0;
		my $r = &appointment_rollup($app, $since);
		$roll{ $wd->{'name'} } = $r;
		my $span_days = $wd->{'span'} ? ($wd->{'span'} / 86400000) : 0;
		# all time has no fixed span, so its days are the app's own history
		my $use_days = sub {
			my ($act) = @_;
			my $d = $span_days;
			$d = ($act->{'first'} && $act->{'first'} > 0) ? ($now - $act->{'first'}) / 86400000 : 1 unless $d;
			return $d < 1 ? 1 : $d;
		};
		if ($global) {
			my @owners = sort { ($r->{'activity'}->{$b}->{'count'} || 0) <=> ($r->{'activity'}->{$a}->{'count'} || 0) } keys %{$r->{'activity'}};
			splice(@owners, 12) if scalar @owners > 12;
			my %apps;
			foreach my $o ( @owners ) {
				my $act = $r->{'activity'}->{$o} || {};
				my @ad = sort keys %{ $r->{'daily'}->{$o} || {} };
				$apps{$o} = {
					occurrences => $act->{'count'} || 0,
					days_active => scalar @ad,
					per_day => &subs::briefing_number(($act->{'count'} || 0) / $use_days->($act)),
					total_duration => &subs::duration_sayer(($act->{'duration'} || 0) / 1000),
				};
				my $quant = $r->{'quantity'}->{$o};
				$apps{$o}->{'quantity_total'} = &subs::briefing_number($quant->{'total'}) if $quant && $quant->{'count'};
			}
			$windows->{ $wd->{'name'} } = { label => $wd->{'label'}, apps => \%apps };
		}
		else {
			my $act = $r->{'activity'}->{$app} || {};
			my @ad = sort keys %{ $r->{'daily'}->{$app} || {} };
			my $days = $use_days->($act);
			my $entry = {
				label => $wd->{'label'},
				window_days => int($days),
				occurrences => $act->{'count'} || 0,
				days_active => scalar @ad,
				per_day => &subs::briefing_number(($act->{'count'} || 0) / $days),
				total_duration => &subs::duration_sayer(($act->{'duration'} || 0) / 1000),
				average_duration => &subs::duration_sayer(($act->{'count'} ? int(($act->{'duration'} || 0) / $act->{'count'}) : 0) / 1000),
				kinds => &subs::evaluation_kinds($r->{'kinds'}->{$app}, 4),
			};
			my $quant = $r->{'quantity'}->{$app};
			$entry->{'quantity'} = {
				times => $quant->{'count'},
				total => &subs::briefing_number($quant->{'total'}),
				average => &subs::briefing_number($quant->{'average'}),
				unit => $quant->{'unit'},
			} if $quant && $quant->{'count'};
			if ($wd->{'name'} eq 'week' || $wd->{'name'} eq 'month') {
				$entry->{'daily_counts'} = join ' ', map { $_ . ':' . $r->{'daily'}->{$app}->{$_} } @ad;
			}
			if ($wd->{'name'} eq 'month') {
				$entry->{'hour_profile'} = $r->{'hours'}->{$app} || {};
				$entry->{'weekday_profile'} = $r->{'weekdays'}->{$app} || {};
			}
			# the app's own readings and their values over this window, so the report
			# can speak the numbers (a weight climbing, a pressure falling) and not
			# only the correlations they happen to make
			my $measurements = &subs::evaluation_measures($app, $since, $measure_defs);
			$entry->{'measurements'} = $measurements if scalar keys %{$measurements};
			# where the app went, from the GPS track the continent table holds: how
			# far and how fast, so a walk reads as a movement, not only a count
			my $continent = &subs::evaluation_continent($app, $since);
			$entry->{'continent'} = $continent if scalar keys %{$continent};
			$windows->{ $wd->{'name'} } = $entry;
			# the raw numbers, kept so the next run can be handed the change
			$snapshot{ $wd->{'name'} } = {
				occurrences => $act->{'count'} || 0,
				per_day => sprintf('%.2f', ($act->{'count'} || 0) / $days),
				total_duration => int(($act->{'duration'} || 0) / 1000),
				($quant && $quant->{'count'} ? (quantity_total => sprintf('%.1f', $quant->{'total'})) : ()),
				(scalar keys %{$measurements} ? (measurements => { map { $_ => $measurements->{$_}->{'latest'} } sort keys %{$measurements} }) : ()),
			};
		}
	}
	# Correlations need weeks, not hours, so they are read over the month: the
	# shorter windows hold too few days to say anything about a relationship
	my $corr_since = $now - 30 * 86400000;
	my $corr_days = &subs::evaluation_window_days($corr_since);
	my $mroll = $roll{'month'};
	my $app_summary = sub {
		my ($from, $owner) = @_;
		my $act = $from->{'activity'}->{$owner} || {};
		return {
			occurrences => $act->{'count'} || 0,
			days_active => scalar keys %{ $from->{'daily'}->{$owner} || {} },
			total_duration => &subs::duration_sayer(($act->{'duration'} || 0) / 1000),
		};
	};
	# what the app already is: the constructs it carries, so a relationship the
	# model names can be filed under the right one
	my $app_settings = &subs::settings_grabber({ app => $app, benign => 1 });
	my %lives;
	$lives{'pos'} = $app_settings->{'pos'} if $app_settings->{'pos'};
	$lives{'mab'} = $app_settings->{'mab'} if $app_settings->{'mab'};
	# The app's own configuration, so the model reads what the thing is and what it
	# is set to expect - its aliases, category and subcategory, budget, default
	# duration, cost and worth, warranty, schedule and movement - not just how
	# often it ran. The internal and bulky keys are left out and values are
	# shortened: on a free tier or a local model the prompt is the bill.
	my %skip_setting = map { $_ => 1 } qw(uuid model pos mab ci colour dimensions scrollTop main_image nfc clothesline jopen ia operator_door evaluation_report evaluation_headlines chatbot_conversations special_budgets header);
	my $settings_brief = {};
	foreach my $sk ( sort keys %{$app_settings} ) {
		next if $skip_setting{$sk};
		next if $sk =~ /^(?:sc_|s_)/;
		my $sv = $app_settings->{$sk};
		next unless defined $sv && $sv =~ /\S/;
		$sv =~ s/\s+/ /g;
		$sv = substr($sv, 0, 120) . '...' if length($sv) > 120;
		$settings_brief->{$sk} = $sv;
	}
	# Where the app keeps a budget locked to the calendar, the budget is read
	# against a period still running, so the report is handed the pace and not only
	# the whole-period target: how far through the period it is, whether the value
	# has kept its share of it, and what the pace projects by the period's end.
	# Without this a young period is read as a shortfall.
	my $budget_pace;
	if (!$global && ($app_settings->{'budget'} || '') =~ /\S/ && ($app_settings->{'s_lock'} || '') eq 'on') {
		foreach my $mode ( sort keys %{$gb::budget_modes} ) {
			my $bp = &Manager::budget_calculator({
				app => $app,
				budget => $app_settings->{'budget'},
				circumstance => $mode,
				settings => $app_settings,
			});
			next unless ($bp->{'is_scope'} || '') eq 'yes' && ($bp->{'circumstance'} || '') eq $mode;
			next unless defined $bp->{'elapsed'} && $bp->{'elapsed'} > 0 && $bp->{'elapsed'} < 1;
			$budget_pace->{$mode} = {
				period => $bp->{'scope_name'},
				progress_percent => $bp->{'progress'},
				on_track => $bp->{'on_track'},
				value => $bp->{'formatted_value'},
				budgeted => $bp->{'formatted_budgeted'},
				due_by_now => $bp->{'formatted_on_target'},
				projected => $bp->{'formatted_projected'},
			};
		}
	}
	# what one logged unit is: a logged quantity is already an amount when its own
	# unit is a measure (coffee logs 10 oz, not ten coffees), and the app's serving
	# is the default for the appointments that logged none
	my $serving = $global ? undef : &subs::quantity_serving($app_settings->{'quantity'});
	unless ($global) {
		foreach my $wname ( keys %{$windows} ) {
			my $e = $windows->{$wname};
			my $q = $e->{'quantity'} or next;
			my $amount = &subs::evaluation_amount($q, $e->{'occurrences'}, $serving, $e->{'window_days'});
			next unless $amount;
			$q->{'unit'} = $amount->{'unit'};
			$q->{'amount_total'} = $amount->{'total'} . ' ' . $amount->{'unit'};
			$q->{'amount_per_day'} = $amount->{'per_day'} . ' ' . $amount->{'unit'} . '/day';
			$q->{'amount_per_entry'} = &subs::briefing_number($amount->{'total'} / ($e->{'occurrences'} || 1)) . ' ' . $amount->{'unit'};
			$q->{'volume_ml_total'} = $amount->{'ml_total'} if defined $amount->{'ml_total'};
			$q->{'volume_ml_per_day'} = $amount->{'ml_day'} if defined $amount->{'ml_day'};
			$q->{'defaulted_from_serving'} = 1 if $amount->{'filled'};
			# the raw unitless sum and average only invite the model to divide them
			delete @{$q}{qw/total average/};
		}
	}
	my @related;
	unless ($global) {
		foreach my $link ( @{ &relational_family($app) } ) {
			my $lroll = &appointment_rollup($link->{'app'}, $corr_since);
			my ($xs, $ys) = &day_pair_series($mroll->{'daily'}->{$app} || {}, $lroll->{'daily'}->{$link->{'app'}} || {});
			my $c = &series_correlation($xs, $ys);
			$c->{'habit'} = 1 if $c && &subs::daily_habit($mroll->{'daily'}->{$app} || {}, $lroll->{'daily'}->{$link->{'app'}} || {}, $corr_days);
			push @related, { app => $link->{'app'}, link => $link->{'link'}, correlation => $c, activity => $app_summary->($lroll, $link->{'app'}) };
		}
	}
	# what else was happening: every app's day counts and every numeric measure
	# logged, lined up against this app (or the top apps) at the best lag. A
	# source that runs nearly every day is filtered out inside, so a daily fetch
	# (a metal price, the weather, a currency quote) cannot pass as a finding.
	my $all_counts = $global ? $mroll->{'daily'} : &subs::appointment_rollup('__president', $corr_since)->{'daily'};
	my $measures = &subs::measure_series($corr_since);
	my @targets;
	if ($global) {
		my @owners = sort { ($mroll->{'activity'}->{$b}->{'count'} || 0) <=> ($mroll->{'activity'}->{$a}->{'count'} || 0) } keys %{$mroll->{'activity'}};
		splice(@owners, 12) if scalar @owners > 12;
		@targets = map { { app => $_ } } @owners;
	}
	else {
		push @targets, { app => $app };
		foreach my $name ( sort keys %{ $measures->{$app} || {} } ) {
			push @targets, { app => $app, measure => $name };
		}
	}
	my $around;
	if ($global) {
		$around = &subs::context_correlations(\@targets, $corr_days, $all_counts, $measures);
	}
	else {
		# for one app, read what ran at the same time of day rather than how its
		# daily totals rose and fell: the event read the daily correlation missed
		$around = &subs::evaluation_context_scan($app, &subs::rightNow() - 60 * 86400000, 30 * 60000, 8);
		# and the time each neighbour keeps - the median gap to the nearest episode
		# of this app - so the relationship carries a lag, not only a co-occurrence
		foreach my $entry ( @{$around} ) {
			my $lag = &subs::evaluation_episode_lag($app, $entry->{'app'}, &subs::rightNow() - 90 * 86400000);
			$entry->{'lag_minutes'} = $lag->{'median_minutes'} if defined $lag->{'median_minutes'};
		}
	}
	# the conditions the app runs under: any app's numeric measures read around
	# this app's episodes (walk in the cold, a flare in the damp)
	my $conditions = $global ? [] : &subs::evaluation_conditions($app, &subs::rightNow() - 60 * 86400000, 8);
	my ($different, @open);
	unless ($global) {
		$different = &subs::measure_contrasts($app, $corr_days, $all_counts, $measures);
		# the app's own task list: what is still open says what the app is for
		my $tasks = eval { return decode_json(&subs::setting_grabber({ app => $app, setting => 'tasks' }) || '') } || [];
		@open = map { { task => substr($_->{'task'}, 0, 60), priority => ($_->{'priority'} || 0) + 0 } }
			grep { ($_->{'completed'} || '') ne 'on' && $_->{'task'} } @{$tasks};
		@open = sort { $b->{'priority'} <=> $a->{'priority'} } @open;
		splice(@open, 8) if scalar @open > 8;
	}
	# The last report this scope produced, so the model can say what changed
	# instead of describing the same numbers again. Trimmed hard: on a free tier
	# or a local model the prompt is the bill.
	my $prior = &subs::evaluation_report_for($app);
	my $last_report;
	if (($prior->{'text'} || '') =~ /\S/) {
		$last_report = {
			timestamp => $prior->{'timestamp'},
			model => $prior->{'model'},
			text => substr($prior->{'text'}, 0, 1200),
		};
	}
	# A rolling list of the headlines the house has already seen for this scope:
	# long-range continuity for a few tokens each, so the model can tell a new
	# turn from a standing one.
	my @recent = @{ (&subs::evaluation_headline_list($app)) };
	@recent = @recent[0 .. 9] if scalar @recent > 10;
	# The same windows as the last run left them, so even a small model is handed
	# the change rather than left to infer it from prose
	my $since_last;
	if (!$global && $prior->{'snapshot'}) {
		my %delta;
		foreach my $wname ( sort keys %{$windows} ) {
			my $was = $prior->{'snapshot'}->{$wname} or next;
			my $now = $snapshot{$wname} or next;
			$delta{$wname} = { was => $was, now => $now };
		}
		$since_last = { previous_at => $prior->{'timestamp'}, windows => \%delta } if scalar keys %delta;
	}
	# How much the answer should carry: brief is a headline only (cheap, for a
	# daily run), full is the whole report
	my $depth = (&subs::setting_grabber({ app => $app, setting => 'evaluation_depth' }) || '') eq 'brief' ? 'brief' : 'full';
	my $briefing = {
		scope => $global ? 'the whole house' : $app,
		constructs => [ sort keys %{$gb::relationals} ],
		windows => $windows,
		($schedule ? (schedule => $schedule) : ()),
		($serving ? (serving => $serving) : ()),
		(scalar keys %{$settings_brief} ? (settings => $settings_brief) : ()),
		($budget_pace && scalar keys %{$budget_pace} ? (budget_pace => $budget_pace) : ()),
		depth => $depth,
		%lives,
		(!$global ? (related => \@related) : ()),
		around => $around,
		(!$global && scalar keys %{$trends} ? (trends => $trends) : ()),
		(!$global && scalar keys %{$episodes} ? (episodes => $episodes) : ()),
		(!$global && scalar @{$conditions} ? (conditions => $conditions) : ()),
		(!$global && $different && scalar @{$different} ? (different => $different) : ()),
		(!$global && scalar @open ? (tasks => \@open) : ()),
		($last_report ? (previous => $last_report) : ()),
		(scalar @recent ? (headlines => \@recent) : ()),
		($since_last ? (since_last => $since_last) : ()),
	};
	my $system = 'You are the evaluation agent of JawnOS, a house that logs its life as timed appointments. A briefing follows for one app (or the whole house). Its windows map measures the same activity over five spans - day (24 hours), week, month, year and all time - each with occurrences, days_active, per_day (occurrences divided by the span in days, so spans can be compared), total_duration and average_duration, and, for a single app, kinds (the appointment types, subtypes and projects that ran and the model or option names they carried, each counted). The week and month windows also carry daily_counts (one count per day as date:count); the month window also carries an hourly profile (hours 0-23) and a weekday profile (0 is Sunday). These five are what a trend is read from: a per_day that climbs from year to month to week is a pace that is rising. For a single app the briefing also says what it is (its pos and mab constructs) and may carry related (the apps the relational window ties to it, each with a Pearson correlation of the daily series over the last 30 days at the best lag; a positive lag_days means the related app trails this one), around (the apps whose occurrences fell within a half hour either side of this app\'s own occurrences more than chance would place them - each with hits (how many of this app\'s occurrences had it nearby), of (how many occurrences were scanned), lift (the multiple over chance) and offset_minutes (negative when it tends to come before this app, positive after) and, when the episode lists allow, lag_minutes (the median gap from this app\'s episodes to that app\'s nearest episode - negative when it usually comes first) - so a thing that consistently happens at the same time stands out where a correlation of daily totals would drown it in the calendar), different (the measures that stood out on the days this app ran, its mean on those days (on_days) against its mean on the other days (off_days), scaled by z) and tasks (what is still open). A pair or entry marked habit runs on nearly every day and its correlation is the calendar, not a cause. A thing need not be linked to be a cause. A previous report may ride along as previous - the text the last run left, with its date and model - headlines is the last ten headlines the house has seen for this scope, and since_last hands you each window as it was (was) and as it is now (now); together they say what has changed. depth says how much to write - brief means one line, full means the whole report. schedule, when it rides along, says how often this report is asked for on its own: cadence is one of hourly, daily, weekly, monthly, yearly or each_run (evaluated whenever the appointment itself runs), with days (the weekdays it runs on, for daily or weekly) and next_run (when a run is queued) when they apply. Each window also carries quantity where entries logged one - times (how many carried a quantity). serving, where the app records one, is the default size of a single unit (coffee logs \'10oz\' a cup) and fills the appointments that logged no quantity of their own; each window\'s quantity carries unit where the appointments logged one and amount_total / amount_per_day in that unit (and volume_ml), with defaulted_from_serving set when that filling happened - so a logged quantity is read as the amount it already is. Where an app logs its own readings (a measure typed in against an appointment), each window may also carry measurements: one entry per measure with readings (how many were logged) and, for a numeric reading, average, min, max, the latest value and latest_at; a text or select reading keeps its latest and the values seen; a measure the app defines also carries its unit and range. These are the numbers themselves, so a measure that drifts - a weight climbing, a pressure falling - is read from its latest against its average and its min and max, not only from the correlations it makes. Where an app recorded a place track (the continent table the GPS fills), each window may also carry continent: points (how many fixes), distance_km, duration_minutes, the bounds (north, south, east, west) and from/to (the first and last fix), and speed (average and max, in km/h; the average is derived from the distance and the time when the fixes carried no speed of their own) - so a walk is read as the movement it was. A run for one app may also carry episodes: the app\'s own activity gathered into the natural unit rather than a count per day - a night, a cup, a session, a walk - with gap_minutes (the gap that split one episode from the next), episodes, days, per_day, median_duration and longest_duration, onset_hours (how many episodes began in each hour of the clock, 0-23) and, where the app logs a quantity, quantity_total, quantity_per_episode, quantity_per_day and unit. Read them where a day\'s count hides the shape: a sleep is a night with an onset hour and a length, a coffee a cup at a time of day - give the typical onset and duration, not only the tally. A run for one app may also carry conditions: for each numeric measure any app logged - a weather app\'s temperature or humidity, a pollen count, a reading of your own - how its value sits against this app\'s activity, read two ways and both given. around weighs the windows around this app\'s episodes against its value everywhere else; day weighs the measure\'s mean on the days the app ran against the days it did not. Each reading carries its ratio, z (how far the shift stands out from the spread), n and direction (higher or lower), and the entry\'s own kind, on, off, ratio, z, n and direction are the stronger of the two. confidence says which readings stand as a condition - both (the two agree), day (only the whole-day reading does) or around (only the window reading does). Weigh them honestly: the day reading sets whole days against whole days, so the hour of the clock cancels and it is the one to trust where the measure follows the sun - a temperature, a humidity, a wind or a pollen count shifts with the hour, so an around that stands alone may be the time of day wearing the app\'s name, while a reading that stands at both is the surest and one that stands at day alone is sound; the measure\'s app is the condition\'s home. A run for one app may also carry trends: for each clock the inventory graphs - minute, hour, day, week, month and year - the counts of the last several periods as label=count pairs, oldest first, so the pace is read period by period (a week that fell away, a month that doubled). The newest pair is the period still running, so its count is written label=count/<percent>%, the percent saying how far through that period the run happened: a small count at a small percent is a period in progress, not a fall, so weigh it against its percent before calling the pace down. A period with nothing rides along as 0, but a scope whose whole window is empty is left out - never read its absence as a fall to nothing. Each scope also carries settings, the app\'s own configuration as it stands - its aliases (aka), its category and subcategory, its budget (what it is meant to run to), its default duration, cost and worth, its warranty, schedule and movement - so what the thing is, and what it expects of itself, is read from how it is set up. Where the app keeps a budget on its own period, budget_pace rides along: one entry per budgeted measure (occurences, duration, total) with the period, progress_percent (how far through it the run is), on_track (whether the value has kept its share of the period so far), value, budgeted (the whole period\'s budget), due_by_now (that share of it) and projected (what the current pace carries to the period\'s end) - so a part-run period is read as a pace, and on track or behind is called from on_track, not from the plain share. Use only the numbers given.';
	my $instructions = $depth eq 'brief'
		? 'Write one line only - a headline, at most twenty words, no label and no headings - that states what changed in the pace, or that it held if nothing did. Nothing else.'
		: 'Begin with a single headline line - at most twenty words, no label - that names what the numbers showed, then a blank line. Use previous, headlines and since_last to say what changed since the last run - what the numbers now show that they did not - and leave out what has not changed, since the report is read against the last one. Then answer under exactly three headings: Trends, Correlations, Predictions. Under Trends compare the windows to say how the pace is changing - is per_day rising or falling from all time and year to month and week? - and whether sessions are getting longer or shorter, naming the kinds, models and projects the activity was made of and the tasks it serves, and giving the durations. Say first what this appointment is for - what the activity is - reading it from its name, its constructs and its kinds. Where the appointment measures something consumed or done (water drunk, teeth brushed, cigarettes), the windows\' quantity and its amount_per_day (and volume_ml when the unit converts) are how much actually happened: give the generally recommended or typical daily figure for a person (for water, several glasses to a few litres a day; for coffee, a few cups), then say where the logged amount sits against it - a plain guide, not medical advice. This is where a real change of pace lives, so say it plainly and do not dress a steady habit as a trend. Where the app logs measurements, say where each reading is going - the latest reading against the average and the min and max for that window - and hold the range the app is set to expect against it. Where a window carries continent, say how far the app went and how fast, and whether that is rising or falling across the windows. Read trends too: say whether the recent periods are rising or falling, not only what the aggregate windows show, and name the period a turn began at. Where episodes ride along, give the typical onset hour and the median and longest episode, and say whether the episodes are getting longer, shorter, earlier or later. The newest period is still running - its count carries the percent elapsed - so do not read a part-run period as a fall: call it in progress and judge its pace against the percent. Where budget_pace rides along, say plainly whether the app is on track for its budget - read on_track and progress_percent against value and due_by_now, and give the projected figure - and never call a young period behind. Under Correlations weigh related (a Pearson r of the daily series) and around (things that happened at the same time of day, by lift) together: say what r means here and whether the lag suggests one follows the other, say what around says - what consistently runs beside this app and which way, reading offset_minutes - and treat a measure in different as a suspect even when no pair clears the bar; name what was out of the ordinary on the app\'s own days, and call a habit pair what it is - two daily routines, not a finding. If nothing stands out, say so. Under Predictions give two or three concrete, falsifiable predictions for the coming weeks, ones the windows\' pattern actually carries - never a rule invented from a single day. If, and only if, the Correlations make one relationship certain - a non-habit pair with |r| >= 0.8 - end the answer with one line "Link: <app>" naming the app this one should be related to; otherwise end with "Link: none". A wrong link mislabels what an app is, so name one only when the numbers leave no doubt. Plain text.';
	my $user = $instructions . "\n\n" . encode_json($briefing);
	my ($text, $error);
	if ($model) {
		($text, $error) = &evaluation_model_call_role('eval_assistant', $system, $user, &subs::ai_role_thinking('eval_assistant'));
	}
	else {
		$error = 'no evaluation model is chosen - pick one in the mailbox configuration';
	}
	my %mentions;
	$mentions{$app} = 1 unless $global;
	if ($global) {
		foreach my $o ( keys %{ $roll{'month'}->{'activity'} } ) { $mentions{$o} = 1 if $o; }
	}
	foreach my $entry ( @related ) { $mentions{ $entry->{'app'} } = 1 if $entry->{'app'}; }
	foreach my $entry ( @{ $around || [] } ) {
		$mentions{ $entry->{'app'} } = 1 if $entry->{'app'};
		$mentions{ $entry->{'vs_app'} } = 1 if $entry->{'vs_app'};
	}
	foreach my $entry ( @{ $different || [] } ) { $mentions{ $entry->{'app'} } = 1 if $entry->{'app'}; }
	# every appointment the report names should be clickable and formatted, even
	# when the briefing did not hand it over: a project or model name can itself be
	# an appointment (vibe_coding), so the text is scanned against the house's apps
	# and any that appear are added to the names the page links
	if ($text) {
		foreach my $name ( keys %{ &subs::appointment_names() } ) {
			next if $mentions{$name};
			my $spaced = $name; $spaced =~ s/_/ /g;
			my $q = quotemeta $name;
			my $qs = quotemeta $spaced;
			$mentions{$name} = 1 if $text =~ /(?<![\w])$q(?![\w])/i || ($spaced ne $name && $text =~ /(?<![\w])$qs(?![\w])/i);
		}
	}
	# the model may name one relationship it is certain of; the naming is checked
	# against the briefing before anything is written
	my $linked;
	if (!$global && $text) {
		my ($named) = $text =~ /^\s*Link:\s*([A-Za-z0-9_\-\.]+)\s*$/mi;
		if ($named && lc($named) ne 'none') {
			$linked = &subs::evaluation_linker($app, lc($named), $briefing);
		}
	}
	# File the relationships the house is sure of, so they are assembled for the
	# user rather than drawn one at a time; the relational window still takes the
	# rest by hand. The bar is high, so this only ever adds a pair.
	my ($autolinked, $pruned);
	unless ($global) {
		$autolinked = &subs::evaluation_autolink($app, &subs::rightNow() - 60 * 86400000, 8, $around);
		# a condition the app is strongly tied to is a relationship too, but only
		# when the tie stands at the day as well - a thing that merely leans around
		# may be the hour of the clock, not the app
		foreach my $c ( @{$conditions} ) {
			next if (($c->{'confidence'} // '') eq 'around');
			next unless abs($c->{'z'}) >= 2 && defined $c->{'ratio'} && abs($c->{'ratio'} - 1) >= 0.25 && $c->{'n'} >= 8;
			my $rel = &subs::evaluation_relate($app, $c->{'app'});
			push @{$autolinked}, $rel if $rel && !$rel->{'skipped'};
		}
		# and take back the relationships that no longer hold up, the house's own
		# and the ones drawn by hand alike
		$pruned = &subs::evaluation_prune($app, &subs::rightNow() - 60 * 86400000, 4);
	}
	my $report = {
		text => $text || ('The evaluation could not run: ' . $error),
		model => $model,
		machine => $machine,
		depth => $depth,
		windows => [ map { $_->{'name'} } @window_defs ],
		error => $error,
		apps => [ sort keys %mentions ],
		mentions => [ sort keys %mentions ],
		($global ? () : (snapshot => \%snapshot)),
		$linked ? (linked => $linked) : (),
		($autolinked && scalar @{$autolinked} ? (autolinked => [ map { $_->{'app'} } @{$autolinked} ]) : ()),
		($pruned && scalar @{$pruned} ? (pruned => $pruned) : ()),
		timestamp => &subs::rightNow(),
	};
	# a run that could not reach the model must not erase the last report that
	# did: the failed text is still returned to whoever asked, but the house
	# keeps the good report until a run actually answers
	my $previous = &subs::evaluation_report_for($app);
	if (!$error || $previous->{'error'} || !(($previous->{'text'} || '') =~ /\S/)) {
		&subs::cache_set({ app => $app, context => 'evaluation_report', warranty => '-1M' }, $report);
		# the cache lives on the machine that ran the evaluation; a setting is what
		# the rest of the house reads, so the report is written both places
		&subs::setting_setter({ app => $app, setting => 'evaluation_report', value => encode_json($report) });
		# a rolling list of the headlines the house has seen for this scope: a
		# couple of tokens each, and the next run reads it back as continuity
		my $headline = (&subs::evaluation_report_pieces($report))->{'headline'};
		if (($headline || '') =~ /\S/) {
			my @heads = @{ (&subs::evaluation_headline_list($app)) };
			unshift @heads, { timestamp => $report->{'timestamp'}, headline => $headline };
			splice(@heads, 40) if scalar @heads > 40;
			&subs::setting_setter({ app => $app, setting => 'evaluation_headlines', value => encode_json(\@heads) });
		}
	}
	return $report;
}

# the report a scope last produced: the setting is what the whole house can
# read, the cache is where it lived before it travelled
sub evaluation_report_for {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	my $report = eval { return decode_json(&subs::setting_grabber({ app => $app, setting => 'evaluation_report' }) || '') } || &subs::cache_get({ app => $app, context => 'evaluation_report' }) || {};
	# a run that could not reach the model is not a report, so it is not shown
	# as one: the page reads "no report yet" until a run actually answers (the
	# button still states the error it got live when one is asked for)
	return {} if $report->{'error'};
	return $report;
}

# the rolling headlines a scope has seen, newest first
sub evaluation_headline_list {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	my $heads = eval { return decode_json(&subs::setting_grabber({ app => $app, setting => 'evaluation_headlines' }) || '') };
	return ref $heads eq 'ARRAY' ? $heads : [];
}

# the report's text, split so that each app name inside it comes back as its
# own piece: the page renders those as links, and format_name drops the
# underscores on the way. The model may write an app the way it is spelled
# (chips_and_granola) or the way it reads (chips and granola), so both forms
# are offered to the match.
sub evaluation_text_chunks {
	my ($report) = @_;
	my $text = ($report->{'text'} || '') . '';
	my @names = grep { $_ && $_ =~ /\w/ } @{ $report->{'mentions'} || [] };
	return [ { text => $text } ] unless scalar @names;
	my %lookup;
	foreach my $name ( @names ) {
		$lookup{ lc $name } = $name;
		my $spaced = $name;
		$spaced =~ s/_/ /g;
		$lookup{ lc $spaced } = $name if $spaced ne $name;
	}
	my $pattern = join '|', map { quotemeta } sort { length($b) <=> length($a) } keys %lookup;
	my @chunks;
	foreach my $piece ( split /(\b(?:$pattern)\b)/i, $text ) {
		next if !defined $piece || $piece eq '';
		if (my $app = $lookup{ lc $piece }) {
			push @chunks, { app => $app, text => &subs::format_name($app) };
		}
		else {
			push @chunks, { text => $piece };
		}
	}
	return \@chunks;
}

# the report as the page wants to show it: a headline first, then the rest -
# split into chunks - that waits behind it. A report told to begin with a
# headline has one on its first line; an older one that opens straight into a
# heading falls back to the first line of that section, shortened.
sub evaluation_report_pieces {
	my ($report) = @_;
	my $text = ($report->{'text'} || '') . '';
	my @lines = split /\n/, $text, -1;
	my ($head_i, $start);
	for my $i (0 .. $#lines) { next if $lines[$i] !~ /\S/; $head_i = $i; last; }
	return { headline => '', chunks => [ { text => $text } ] } unless defined $head_i;
	my $headline = $lines[$head_i];
	$start = $head_i + 1;
	# if the line is nothing but a section heading, a headline was never written
	if ($headline =~ /^\s*(?:trends|correlations|predictions)\s*:?\s*$/i) {
		for my $i ($head_i + 1 .. $#lines) {
			next if $lines[$i] !~ /\S/;
			$headline = $lines[$i];
			$start = $i + 1;
			last;
		}
	}
	# the headline is one glance: hold it to twenty words even when the model
	# writes past the instruction
	my @head_words = split /\s+/, $headline;
	if (scalar @head_words > 20) {
		$headline = join(' ', @head_words[0 .. 19]) . '...';
	}
	if (length($headline) > 200) {
		$headline = substr($headline, 0, 200);
		$headline =~ s/\s+\S*$//;
		$headline .= '...';
	}
	my $body = join "\n", @lines[ $start .. $#lines ];
	return { headline => $headline, chunks => &subs::evaluation_text_chunks({ %{$report}, text => $body }) };
}

# The evaluation may name one relationship it is sure of. This checks the
# naming against what the briefing actually showed - the pair must be there,
# strong and not a daily habit - and then writes it the way the relational app
# itself does: the uuid goes into both apps' sc_ lists, filed under what the
# other app is (its pos, or its mab). A wrong link mislabels an app, so every
# check here is a gate, not a suggestion.
sub evaluation_linker {
	my ($app, $other, $briefing) = @_;
	return undef if !$other || $other eq $app;
	my $evidence;
	foreach my $entry ( @{ $briefing->{'related'} || [] } ) {
		next unless $entry->{'app'} eq $other;
		my $c = $entry->{'correlation'} || {};
		next if $c->{'habit'};
		next unless defined $c->{'r'} && abs($c->{'r'}) >= 0.8;
		$evidence = { r => $c->{'r'} };
		last;
	}
	unless ($evidence) {
		foreach my $entry ( @{ $briefing->{'around'} || [] } ) {
			next unless $entry->{'app'} eq $other || $entry->{'vs_app'} eq $other;
			next if $entry->{'habit'};
			next unless defined $entry->{'r'} && abs($entry->{'r'}) >= 0.8;
			$evidence = { r => $entry->{'r'} };
			last;
		}
	}
	return { app => $other, skipped => 'the pair was not certain in the briefing' } unless $evidence;
	my $rel = &evaluation_relate($app, $other);
	$rel->{'r'} = $evidence->{'r'} if $rel && !$rel->{'skipped'};
	return $rel;
}

# File one relationship, by hand or by the house's own notice: the two apps are
# joined under each other's construct (sc_), which is what the relational window
# shows and what the evaluation reads back as a link. Idempotent, and it drops
# the two buckets from the relational cache so the window redraws them.
sub evaluation_relate {
	my ($app, $other) = @_;
	return undef if !$other || $other eq $app;
	my $mine = &subs::settings_grabber({ app => $app, benign => 1 });
	my $theirs = &subs::settings_grabber({ app => $other, benign => 1 });
	my $my_construct = $mine->{'pos'} || $mine->{'mab'};
	my $their_construct = $theirs->{'pos'} || $theirs->{'mab'};
	return { app => $other, skipped => 'one of them has no construct to file under' }
		unless $my_construct && $their_construct && $mine->{'uuid'} && $theirs->{'uuid'};
	my $sc = eval { return decode_json($mine->{ 'sc_' . $their_construct }) } || [];
	return { app => $other, skipped => 'already related' }
		if grep { $_ eq $theirs->{'uuid'} } @{$sc};
	push @{$sc}, $theirs->{'uuid'};
	@{$sc} = grep { $_ ne 'all' } @{$sc};
	my $bc = eval { return decode_json($theirs->{ 'sc_' . $my_construct }) } || [];
	push @{$bc}, $mine->{'uuid'} unless grep { $_ eq $mine->{'uuid'} } @{$bc};
	@{$bc} = grep { $_ ne 'all' } @{$bc};
	&subs::setting_setter({ app => $app, setting => 'sc_' . $their_construct, value => encode_json($sc) });
	&subs::setting_setter({ app => $other, setting => 'sc_' . $my_construct, value => encode_json($bc) });
	&evaluation_relationships_changed($app, $other);
	return { app => $other, construct => $their_construct, their_construct => $my_construct };
}

# Assemble the relationships the house is sure enough of, without a hand on each:
# the event scan's strongest neighbours of one app are filed straight away, so
# drawing them is the exception rather than the rule. The bar is high (a strong
# lift over chance, seen often) and an already-related pair is skipped, so a run
# only ever adds and never churns.
sub evaluation_autolink {
	my ($app, $since, $cap, $candidates) = @_;
	return [] unless $app && $app ne '__president';
	$cap ||= 8;
	$since ||= &subs::rightNow() - 60 * 86400000;
	$candidates ||= &subs::evaluation_context_scan($app, $since, 30 * 60000, 16);
	my @filed;
	foreach my $entry ( @{$candidates} ) {
		last if scalar @filed >= $cap;
		next unless ($entry->{'lift'} + 0) >= 3 && ($entry->{'hits'} + 0) >= 5;
		my $rel = &evaluation_relate($app, $entry->{'app'});
		next if !$rel || $rel->{'skipped'};
		$rel->{'lift'} = $entry->{'lift'};
		$rel->{'hits'} = $entry->{'hits'};
		push @filed, $rel;
	}
	return \@filed;
}

# The relational window draws each bucket from a cache; a change to either end
# of a relationship drops both, so the window redraws them fresh.
sub evaluation_relationships_changed {
	my ($app, $other) = @_;
	my $buckets = &subs::cache_get({ app => 'relational', context => 'buckets' }) || {};
	delete $buckets->{$app};
	delete $buckets->{$other};
	&subs::cache_set({ app => 'relational', context => 'buckets', warranty => '-5y' }, $buckets);
	return 1;
}

# Undo a relationship, both ways, whoever made it. Symmetric with
# evaluation_relate so a link the house filed and one drawn by hand are taken
# apart the same way.
sub evaluation_unrelate {
	my ($app, $other) = @_;
	return { app => $other, skipped => 'nothing to undo' } if !$other || $other eq $app;
	my $mine = &subs::settings_grabber({ app => $app, benign => 1 });
	my $theirs = &subs::settings_grabber({ app => $other, benign => 1 });
	my $my_construct = $mine->{'pos'} || $mine->{'mab'};
	my $their_construct = $theirs->{'pos'} || $theirs->{'mab'};
	return { app => $other, skipped => 'one of them has no construct' }
		unless $my_construct && $their_construct && $mine->{'uuid'} && $theirs->{'uuid'};
	my $sc = eval { return decode_json($mine->{ 'sc_' . $their_construct }) } || [];
	my $bc = eval { return decode_json($theirs->{ 'sc_' . $my_construct }) } || [];
	return { app => $other, skipped => 'not related' }
		unless grep { $_ eq $theirs->{'uuid'} } @{$sc} or grep { $_ eq $mine->{'uuid'} } @{$bc};
	@{$sc} = grep { $_ ne $theirs->{'uuid'} } @{$sc};
	@{$bc} = grep { $_ ne $mine->{'uuid'} } @{$bc};
	&subs::setting_setter({ app => $app, setting => 'sc_' . $their_construct, value => encode_json($sc) });
	&subs::setting_setter({ app => $other, setting => 'sc_' . $my_construct, value => encode_json($bc) });
	&evaluation_relationships_changed($app, $other);
	return { app => $other, removed => 1 };
}

# Take the relationships back that no longer hold up, whoever drew them: for
# each app this one is related to, keep it only if the house can still see why -
# the event scan still puts it nearby, or a condition it runs under is still
# tied to the app - and drop the rest. Nothing is judged until the app has run
# enough to be read, and only a few go in a run, so a link is removed when it
# has truly gone quiet and not on a single thin night.
sub evaluation_prune {
	my ($app, $since, $cap) = @_;
	return [] unless $app && $app ne '__president';
	$cap ||= 4;
	$since ||= &subs::rightNow() - 60 * 86400000;
	my $count = &subs::db_query('select count(*) as n from appointments where app = ? and cast(timestamp as integer) >= ?', $app, $since)->hashes->[0]->{'n'} + 0;
	return [] if $count < 10;
	my $mine = &subs::settings_grabber({ app => $app, benign => 1 });
	my @related;
	foreach my $key ( grep { /^sc_/ } keys %{$mine} ) {
		my $uuids = eval { return decode_json $mine->{$key} } || [];
		foreach my $u ( @{$uuids} ) {
			next if !$u || $u eq 'all';
			my $s = &subs::settings_grabber({ uuid => $u });
			push @related, $s->{'app'} if $s->{'app'};
		}
	}
	return [] unless scalar @related;
	my %lift = map { $_->{'app'} => ($_->{'lift'} + 0) } @{ &subs::evaluation_context_scan($app, $since, 30 * 60000, 24) };
	my %cond = map { $_->{'app'} => 1 } grep { abs($_->{'z'}) >= 1.5 && (($_->{'confidence'} // '') ne 'around') } @{ &subs::evaluation_conditions($app, $since, 24) };
	my @removed;
	foreach my $other ( @related ) {
		last if scalar @removed >= $cap;
		next if ($lift{$other} // 0) >= 1.5;
		next if $cond{$other};
		my $r = &evaluation_unrelate($app, $other);
		push @removed, $other if $r && $r->{'removed'};
	}
	return \@removed;
}

# the machine whose worker runs the nightly evaluations; blank means every
# machine that reconciles keeps its own queue
sub evaluation_machine {
	return &subs::setting_grabber({ app => '__president', setting => 'evaluation_machine' }) || '';
}

# The nightly evaluation is one Minion schedule per scope, named for the scope.
# The schedule is the mechanism, but it does not survive the launcher: jawn
# clears ~/.president at startup. So the wish lives in a setting too, and the
# worker restores the schedules from the settings at boot - see
# nightly_evaluation_reconcile. Minion reads cron expressions in UTC, and
# 0 7 * * * is the small hours of the house: 3am EDT, 2am EST.
sub nightly_evaluation_name {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	return 'nightly_evaluation_' . $app;
}

# The schedule a scope now has, as Minion lists it. The configure page asks per
# app, so the answer is memoised for a few seconds: one query serves a page of
# apps instead of one per app. arrange() calls this right after a write, so the
# memo is short enough that a just-made change is seen on the next repaint.
my %schedule_memo;
sub nightly_evaluation_schedule {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	my $now = time;
	return $schedule_memo{$app}->{'schedule'} if exists $schedule_memo{$app} && $schedule_memo{$app}->{'at'} > $now - 3;
	my $listed = eval { return &subs::minion_grabber()->list_schedules(0, 1, { names => [ &subs::nightly_evaluation_name($app) ] }) } || {};
	my $schedule = ($listed->{'schedules'} || [])->[0];
	$schedule_memo{$app} = { at => $now, schedule => $schedule };
	return $schedule;
}

# the days the nightly runs, as a comma list of cron weekdays (0 is Sunday);
# nothing picked means every night
sub nightly_evaluation_days {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	my $days = &subs::setting_grabber({ app => $app, setting => 'nightly_evaluation_days' });
	# '0' is Sunday and is a value, not nothing: "|| ''" would drop it
	$days = '' unless defined $days;
	return [ grep { /^[0-6]$/ } split /\s*,\s*/, $days ];
}

# The cadence a scope runs on its own: off, hourly, daily, weekly, monthly,
# yearly, or each_run (evaluated whenever the appointment itself runs). The old
# nightly checkbox is read as daily, so a house that has not been reconfigured
# keeps its nights. The timed cadences become a cron the worker carries out;
# each_run has no schedule and rides the appointment writer instead.
sub evaluation_cadence {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	my $c = &subs::setting_grabber({ app => $app, setting => 'evaluation_cadence' });
	return $c if defined $c && grep { $_ eq $c } qw/off hourly daily weekly monthly yearly each_run/;
	return 'daily' if (&subs::setting_grabber({ app => $app, setting => 'nightly_evaluation' }) || '') eq 'on';
	return 'off';
}

# Minion reads cron in UTC, and 0 7 * * ... is the small hours of the house
# (3am EDT, 2am EST). The days select narrows daily and weekly; nothing picked
# means every night for daily and Sunday for weekly.
sub evaluation_schedule_cron {
	my ($app, $cadence) = @_;
	$cadence = &subs::evaluation_cadence($app) unless defined $cadence;
	return undef unless defined $cadence && $cadence ne 'off' && $cadence ne 'each_run';
	my @days = @{ &subs::nightly_evaluation_days($app) };
	return '0 * * * *' if $cadence eq 'hourly';
	return '0 7 * * ' . (scalar @days ? join(',', @days) : '*') if $cadence eq 'daily';
	return '0 7 * * ' . (scalar @days ? join(',', @days) : '0') if $cadence eq 'weekly';
	return '0 7 1 * *' if $cadence eq 'monthly';
	return '0 7 1 1 *' if $cadence eq 'yearly';
	return undef;
}

# carry out one scope's cadence: schedule its cron, or clear it (off, each_run)
sub evaluation_schedule_arrange {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	my $minion = &subs::minion_grabber();
	my $name = &subs::nightly_evaluation_name($app);
	my $cron = &subs::evaluation_schedule_cron($app);
	if ($cron) {
		# one retry, in case the model was only briefly unreachable
		$minion->schedule($name, $cron, 'appointment_evaluation', [ { app => $app } ], { attempts => 2 });
	}
	else {
		$minion->unschedule($name);
	}
	# a change here is a change the next read should see, not the memo
	delete $schedule_memo{$app};
}

# the controls write both halves: the setting remembers the wish, the schedule
# carries it out, and the answer reports the schedule that now exists
sub evaluation_cadence_apply {
	my ($app, $cadence) = @_;
	$app = '__president' unless $app && $app ne '';
	$cadence = 'off' unless defined $cadence && grep { $_ eq $cadence } qw/off hourly daily weekly monthly yearly each_run/;
	&subs::setting_setter({ app => $app, setting => 'evaluation_cadence', value => $cadence });
	&subs::evaluation_schedule_arrange($app);
	return &subs::nightly_evaluation_schedule($app);
}

# the old on/off checkbox, kept for anything that still speaks it
sub nightly_evaluation_apply {
	my ($app, $on) = @_;
	return &subs::evaluation_cadence_apply($app, $on ? 'daily' : 'off');
}

# Every run fires the evaluation when the scope's cadence is each_run. A Minion
# lock throttles a burst of runs to one evaluation per window (300s), so a
# morning of records does not queue a morning of model calls. Only a completed
# run counts - a one-shot ('usual') or the end of a start/stop pair ('stop') -
# and never a spawned child.
sub evaluation_run_trigger {
	my ($app, $appt) = @_;
	return unless $app && $app ne '__president';
	return unless ref $appt eq 'HASH';
	my $type = $appt->{'type'} || '';
	return unless $type eq 'usual' || $type eq 'stop';
	return if $appt->{'source_uuid'};
	return unless &subs::evaluation_cadence($app) eq 'each_run';
	my $minion = &subs::minion_grabber();
	return unless $minion->lock('evaluation_each_run_' . $app, 300);
	$minion->enqueue('appointment_evaluation' => [ { app => $app } ] => { attempts => 2 });
	return 1;
}

# The queue under ~/.president does not outlive the launcher, but the settings
# do. At boot this reads the wishes back, puts the schedules that are wanted
# back, and drops any nightly schedule the settings no longer ask for. Held in
# an eval because a boot that cannot reach the queue or the settings must not
# take the worker down with it.
sub nightly_evaluation_reconcile {
	eval {
		# a named machine keeps the nights to itself; blank keeps the old
		# habit of every queue carrying whatever wish its settings show
		my $chosen = &subs::evaluation_machine();
		my $mine = !$chosen || $chosen eq &subs::signatorial_designer();
		# every scope ever given a cadence, or the old nightly checkbox: the
		# effective cadence decides which of them wants a schedule
		my %scope;
		foreach my $setting ( qw/evaluation_cadence nightly_evaluation/ ) {
			my $rows = &subs::db_select('settings', undef, { setting => $setting, device => &subs::device_setter() })->hashes || [];
			foreach my $row ( @{$rows} ) {
				$scope{ ($row->{'app'} && $row->{'app'} ne '') ? $row->{'app'} : '__president' } = 1;
			}
		}
		my %wanted;
		foreach my $app ( keys %scope ) {
			my $cadence = &subs::evaluation_cadence($app);
			$wanted{$app} = 1 if $cadence ne 'off' && $cadence ne 'each_run';
		}
		my $listed = &subs::minion_grabber()->list_schedules(0, 1000) || {};
		my %present;
		foreach my $sch ( @{ $listed->{'schedules'} || [] } ) {
			next unless $sch->{'name'} =~ /^nightly_evaluation_/;
			$present{$sch->{'name'}} = 1;
		}
		foreach my $app ( keys %wanted ) {
			next unless $mine;
			# schedule() is an upsert by name (and keeping the same expression
			# keeps the firing time), so asking for every wanted scope also
			# retunes one whose cadence changed while nobody was looking
			&subs::evaluation_schedule_arrange($app);
		}
		foreach my $name ( keys %present ) {
			my ($app) = $name =~ /^nightly_evaluation_(.*)$/;
			next if $mine && $wanted{$app};
			&subs::minion_grabber()->unschedule($name);
		}
	};
	return;
}

# The worker half of the nightly checkbox: the same agent the evaluate button
# runs, so a fresh report is in the cache before the house wakes.
sub appointment_evaluation_job {
	my ($job, $data) = @_;
	my $app = $data->{'app'} || '__president';
	# the queue is per-machine and the settings are shared, so this is what keeps
	# one wish from running on every machine's queue at once. A machine named by
	# hand always runs it; with none named, the house ledger picks the runner, and
	# because the house holds only machines seen recently a home that goes quiet
	# hands the evaluation to the next machine.
	my $named = &subs::evaluation_machine();
	my $here = &subs::setting_grabber({ app => 'me', setting => 'my_name' }) || '';
	if ($named) {
		if ($named ne &subs::signatorial_designer()) {
			$job->finish({ app => $app, skipped => 'not the evaluation machine' });
			return;
		}
	}
	elsif (!&ai_job_may_run('eval:' . $app, 3600 * 1000)) {
		$job->finish({ app => $app, skipped => 'another machine runs this evaluation' });
		return;
	}
	# the wish is shared and the queue is per-machine: a machine that cannot
	# reach the model would run the night and answer with an error, so it steps
	# aside and lets a machine that can carry the wish instead. Either way the
	# night leaves a durable note, so an empty morning has a witness.
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'eval_assistant' ] });
	my $model = $settings->{'eval_assistant'};
	unless (&subs::evaluation_model_available($model)) {
		&subs::evaluation_run_record($app, { timestamp => &subs::rightNow(), machine => $here, model => $model, outcome => 'skipped', note => 'no model reachable here' });
		$job->finish({ app => $app, skipped => 'no evaluation model reachable here' });
		return;
	}
	&ai_job_note('eval:' . $app);
	my $report = &subs::evaluation_agent($app);
	if ($report->{'error'}) {
		&subs::evaluation_run_record($app, { timestamp => &subs::rightNow(), machine => $here, model => $model, outcome => 'failed', note => substr($report->{'error'}, 0, 120) });
		$job->fail($report->{'error'});
		return;
	}
	&subs::evaluation_run_record($app, { timestamp => &subs::rightNow(), machine => $here, model => $model, outcome => 'ran' });
	$job->finish({ app => $app, timestamp => $report->{'timestamp'} });
}

# A durable note of what each night did, per scope: which machine ran it, when,
# with which model, and - when the run stepped aside - why. The queue is
# per-machine and the wish is shared, so without it the only witness to a night
# that did nothing was the absence of a report.
sub evaluation_run_record {
	my ($app, $entry) = @_;
	$app = '__president' unless $app && $app ne '';
	my $log = eval { return decode_json(&subs::setting_grabber({ app => $app, setting => 'evaluation_runs' }) || '') } || [];
	unshift @{$log}, $entry;
	splice(@{$log}, 30) if scalar @{$log} > 30;
	&subs::setting_setter({ app => $app, setting => 'evaluation_runs', value => encode_json($log) });
	return $log;
}

# Text to an image: the Plat Image-generation model, and the bytes it answered
# with. Cloudflare's @cf text-to-image models run at the run/{model} endpoint and
# answer with the picture itself; any other model goes through the chat layer,
# whose image parts are collected here. Returns ($bytes, $mime, $error).
sub ai_text_to_image {
	my ($data) = @_;
	my $prompt = $data->{'prompt'} || '';
	return (undef, undef, 'no prompt') unless length $prompt;
	my @key_settings = &subs::ai_key_settings();
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'text_to_image_assistant', 'cloudflare_account', 'cloudflare_token', @key_settings ] });
	my $model = $data->{'model'} || $settings->{'text_to_image_assistant'};
	return (undef, undef, 'no image model is set (Configure, Plat, Image generation)') unless $model;
	my $ua = Mojo::UserAgent->new(connect_timeout => 10, inactivity_timeout => 300, request_timeout => 600);
	if ($model =~ /^\@cf/) {
		my $account = $settings->{'cloudflare_account'};
		my $token = eval { &subs::note_decrypter(&subs::suds_grabber(), $settings->{'cloudflare_token'}) } || $settings->{'cloudflare_token'};
		return (undef, undef, 'no Cloudflare account is set (Configure, Plat, Provider access)') unless $account;
		return (undef, undef, 'no Cloudflare token is set (Configure, Plat, Provider access)') unless $token;
		my $url = 'https://api.cloudflare.com/client/v4/accounts/' . $account . '/ai/run/' . $model;
		my $payload = { prompt => $prompt };
		$payload->{'negative_prompt'} = $data->{'negative_prompt'} if $data->{'negative_prompt'};
		$payload->{'width'} = int($data->{'width'}) if $data->{'width'};
		$payload->{'height'} = int($data->{'height'}) if $data->{'height'};
		my $tx = $ua->post($url => {
			'Authorization' => 'Bearer ' . $token,
			'Content-Type'  => 'application/json'
		} => json => $payload);
		if ($tx->error) {
			my $detail = '';
			if (my $res = $tx->res) { $detail = ' ' . substr(($res->body || ''), 0, 300); }
			return (undef, undef, 'could not reach Cloudflare: ' . $tx->error->{'message'} . $detail);
		}
		my $res = $tx->res;
		unless ($res->is_success) {
			my $body = $res->body || '';
			if ($res->code == 402 || $body =~ /(insufficient|credit|billing|payment|balance|quota)/i) {
				&ai_bucket_mark_unavailable(&ai_model_bucket($model), $res->code . ' ' . $body);
			}
			return (undef, undef, 'the image model answered ' . $res->code . ': ' . substr($body, 0, 200));
		}
		my $binary = $res->body;
		return (undef, undef, 'the image model returned nothing') unless defined $binary && length $binary;
		return ($binary, 'image/png', undef);
	}
	# any other model: whatever the chat layer hands back as an image part (a
	# multimodal model that draws, or a URL to fetch). The chat layer has no size
	# field, so a canvas is asked for in the prompt - a model that draws listens to
	# it or ignores it, and a locally hosted one is where this path is headed
	my $ask = $prompt;
	if ($data->{'width'} && $data->{'height'}) {
		$ask .= ' Produce the image at ' . int($data->{'width'}) . ' by ' . int($data->{'height'}) . ' pixels.';
	}
	my ($parts, $err) = &ai_chat_parts($model, [ { role => 'user', content => $ask } ]);
	return (undef, undef, $err || 'the model returned nothing readable') if $err;
	foreach my $part ( @{$parts || []} ) {
		next unless ($part->{'type'} || '') eq 'image';
		if ($part->{'data'}) {
			my $bytes = MIME::Base64::decode_base64($part->{'data'});
			return ($bytes, $part->{'mime'} || 'image/png', undef) if $bytes && length $bytes;
		}
		elsif ($part->{'url'}) {
			my $fetch = $ua->get($part->{'url'});
			my $bytes = $fetch->res->body;
			return ($bytes, $fetch->res->headers->content_type || 'image/png', undef) if $bytes && length $bytes;
		}
	}
	return (undef, undef, 'the model answered without an image');
}

# The audio/video twin of ai_text_to_image's generic path: the chosen generation
# model is asked for the media and the first part of the right kind it returns is
# the answer. Pen uses this so a described audio/video prompt is filed by the
# agent that takes care of that kind.
sub ai_text_to_media {
	my ($kind, $data) = @_;
	my $prompt = $data->{'prompt'} || '';
	return (undef, undef, 'no prompt') unless length $prompt;
	my $setting = ($kind eq 'audio' ? 'text_to_audio_assistant' : 'text_to_video_assistant');
	my $label = ($kind eq 'audio' ? 'Audio' : 'Video');
	my $model = $data->{'model'} || &subs::setting_grabber({ app => 'mail', setting => $setting });
	return (undef, undef, "no $kind model is set (Configure, Plat, $label generation)") unless $model;
	# a dedicated video provider (Google Veo) runs a job on its side and is polled,
	# not asked as a chat turn; the chat layer is the fallback for everything else
	return &ai_text_to_video_veo($model, $prompt, $data) if $kind eq 'video' && $model =~ /^(?:google:)?veo/i;
	my $ua = Mojo::UserAgent->new(connect_timeout => 10, inactivity_timeout => 300, request_timeout => 600);
	my $ask = $prompt;
	if ($kind eq 'video' && $data->{'width'} && $data->{'height'}) {
		$ask .= ' Produce the video at ' . int($data->{'width'}) . ' by ' . int($data->{'height'}) . ' pixels.';
	}
	my ($parts, $err) = &ai_chat_parts($model, [ { role => 'user', content => $ask } ]);
	return (undef, undef, $err || 'the model returned nothing readable') if $err;
	foreach my $part ( @{$parts || []} ) {
		next unless ($part->{'type'} || '') eq $kind;
		if ($part->{'data'}) {
			my $bytes = MIME::Base64::decode_base64($part->{'data'});
			return ($bytes, $part->{'mime'}, undef) if $bytes && length $bytes;
		}
		elsif ($part->{'url'}) {
			my $fetch = $ua->get($part->{'url'});
			my $bytes = $fetch->res->body;
			return ($bytes, $fetch->res->headers->content_type || '', undef) if $bytes && length $bytes;
		}
	}
	return (undef, undef, "the model answered without $kind");
}

# Google Veo, the video-generation job: submit a prompt, poll the long-running
# operation until it is done, then fetch the file it names. Returns
# ($bytes, $mime, $error), the same shape as the other generators.
sub ai_text_to_video_veo {
	my ($model, $prompt, $data) = @_;
	my @key_settings = &subs::ai_key_settings();
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ @key_settings ] });
	my $key = eval { &subs::note_decrypter(&subs::suds_grabber(), $settings->{'google_key'}) } || $settings->{'google_key'};
	return (undef, undef, 'no Google key is set (Configure, Plat, Provider access)') unless $key;
	my $name = $model; $name =~ s/^google://;
	my $ua = Mojo::UserAgent->new(connect_timeout => 10, inactivity_timeout => 120, request_timeout => 600);
	my $base = 'https://generativelanguage.googleapis.com/v1beta';
	my $payload = { instances => [ { prompt => $prompt } ] };
	$payload->{'parameters'}->{'aspectRatio'} = $data->{'aspect_ratio'} if $data->{'aspect_ratio'};
	my $submit = $ua->post($base . '/models/' . $name . ':predictLongRunning?key=' . url_escape($key) => json => $payload);
	return (undef, undef, 'could not reach the video model: ' . $submit->error->{'message'}) if $submit->error;
	my $body = eval { return $submit->res->json } || {};
	my $op = $body->{'name'};
	return (undef, undef, 'the video model did not start a job: ' . substr($submit->res->body || '', 0, 200)) unless $op;
	# poll the operation; a Veo render is minutes, so give it a long leash
	my $video_uri;
	for (my $i = 0; $i < 90; $i++) {
		sleep 5 if $i;
		my $poll = $ua->get($base . '/' . $op . '?key=' . url_escape($key));
		next if $poll->error;
		my $pb = eval { return $poll->res->json } || {};
		next unless $pb->{'done'};
		if ($pb->{'error'}) { return (undef, undef, 'the video model failed: ' . ($pb->{'error'}->{'message'} || 'unknown')); }
		$video_uri = $pb->{'response'}->{'generateVideoResponse'}->{'generatedSamples'}->[0]->{'video'}->{'uri'}
			|| $pb->{'response'}->{'generatedVideos'}->[0]->{'video'}->{'uri'};
		last;
	}
	return (undef, undef, 'the video model did not finish in time') unless $video_uri;
	my $sep = (index($video_uri, '?') >= 0) ? '&' : '?';
	my $fetch = $ua->get($video_uri . $sep . 'key=' . url_escape($key));
	return (undef, undef, 'could not download the video: ' . $fetch->error->{'message'}) if $fetch->error;
	my $bytes = $fetch->res->body;
	return (undef, undef, 'the video model returned nothing') unless defined $bytes && length $bytes;
	return ($bytes, $fetch->res->headers->content_type || 'video/mp4', undef);
}

sub generate_ai_media {
  my ($data) = @_;
	my $kind = $data->{'kind'} || 'image';
	my $c = &subs::controller_builder();
	my $msg_uuid = $data->{'msg_uuid'};
  my $ua       = $data->{'ua'};
  my $prompt   = $data->{'prompt'};
  my $settings = $data->{'settings'};
	my $conversation = $data->{'conversation'};
	my $mail_contact = $data->{'mail_contact'};
	my $start_timestamp = &subs::rightNow();
	# Unclaimed media (a Guide associate, or Pen with no name for the chat) lands
	# on the Camera app, where it waits a week to be claimed onto an appointment.
	my $unclaimed = ($data->{'unclaimed'}) ? 1 : 0;
	my $app = $unclaimed ? 'camera' : $mail_contact;
	if (!$unclaimed && $conversation->{'chatbot_conversation_name'}) {
		$app = $conversation->{'chatbot_conversation_name'};
	}
	$app = &subs::unformat_name($app);

  $log->info(Dumper $data);
	# the media comes through the Plat generation model for this kind; the
	# storing, the appointment and the reply are this routine's own work. The
	# agent's fallback is tried when the primary fails (an outage, no credit).
	my $role = $kind eq 'image' ? 'text_to_image_assistant' : $kind eq 'audio' ? 'text_to_audio_assistant' : 'text_to_video_assistant';
	my ($primary, $fallback) = &subs::ai_role_models($role);
	my %gen_seen;
	my @gen_candidates = grep { !$gen_seen{$_}++ } grep { defined $_ && length $_ } ($data->{'model'}, $primary, $fallback);
	my ($binary, $mime, $gen_err);
	foreach my $candidate ( @gen_candidates ) {
		($binary, $mime, $gen_err) = ($kind eq 'image')
			? &subs::ai_text_to_image({ prompt => $prompt, model => $candidate })
			: &subs::ai_text_to_media($kind, { prompt => $prompt, model => $candidate });
		last if defined $binary && length $binary;
		&subs::say_it('AI: ' . $kind . ' with ' . $candidate . ' failed (' . ($gen_err || 'nothing returned') . ')') if @gen_candidates > 1;
	}
	if ($gen_err || !defined $binary || !length $binary) {
		$log->error(ucfirst($kind) . ' generation failed: ' . ($gen_err || 'nothing returned'));
		return undef;
	}
	my $upload_type = $kind;
	my $filename = $kind . '_' . &subs::rightNow() . ($kind eq 'image' ? '.png' : $kind eq 'audio' ? '.mp3' : '.mp4');
	my $setting = ($kind eq 'image' ? 'photo_location' : $kind eq 'audio' ? 'music_location' : 'video_location');
	my $folder = &subs::setting_grabber({ app => 'misc', setting => $setting, device => $device });
	my $location = $folder ? (&subs::home($folder) . '/' . $app) : '';
	my $public_dir = $location || &subs::home('~/Public/generated_' . $kind);
	`mkdir $public_dir` unless -d $public_dir;

	my $file_path = $public_dir . '/' . $filename;
	write_file($file_path, $binary);
	my $ocr;
	if ($kind eq 'image') {
		my $resolution = &subs::setting_grabber({ app => 'misc', setting => 'photo_size' } ) || '1920x1080';
		`magick $file_path -resize $resolution $file_path` unless lc $resolution eq 'raw';
		$ocr = &Manager::ocr_reader($c,$file_path);
	}
	# a still thumbnail for image and video, made up front so the unclaimed
	# pool can show it at once instead of waiting on the full file
	my $thumb;
	if ($upload_type eq 'image' || $upload_type eq 'video') {
		my $thumb_dir = $public_dir . '/thumbs';
		`mkdir -p $thumb_dir` unless -d $thumb_dir;
		my $t = $thumb_dir . '/' . $filename;
		$t =~ s/\.[^.]+$/.png/;
		my $thumbnail_size = &subs::setting_grabber({ app => 'misc', setting => 'thumbnail_size' }) || 'none';
		if ($thumbnail_size ne 'none') {
			my $cmd = ($upload_type eq 'video')
				? 'ffmpeg -ss 00:00:00.010 -i ' . $file_path . ' -vframes 1 -c:v png -f image2pipe - | magick - -resize ' . $thumbnail_size . ' ' . $t
				: 'magick ' . $file_path . ' -resize ' . $thumbnail_size . ' ' . $t;
			`$cmd`;
			$thumb = $t if -e $t;
		}
	}
	my $appt_uuid = &subs::random_string_creator(33);
	my $file_uuid = &subs::random_string_creator(21);
	my $u_data = [{ server_time => &subs::rightNow(), appt_uuid => $appt_uuid, mail_uuid => $msg_uuid, ocr => $ocr, f => $file_path, uuid => $file_uuid, type => $upload_type }];
	$u_data->[0]->{'thumb'} = $thumb if $thumb;
	$log->info(Dumper $u_data);
	my $jfile = encode_json $u_data;

	my $write = {
		timestamp => &subs::rightNow(),
		app => &subs::unformat_name($app),
		notes => &subs::note_encrypter(&subs::suds_grabber(),$prompt),
		type => $upload_type,
		file => $jfile,
		uuid => $appt_uuid,
		duration => &subs::rightNow() - $start_timestamp,
	};
	$write->{'source'} = 'unclaimed' if $unclaimed;
	$write->{'warranty'} = &subs::rightNow() + (7 * 24 * 60 * 60 * 1000) if $unclaimed;
	&Manager::appointment_writer($c,$write);
	&subs::file_encrypter({ app => &subs::unformat_name($app) });
	&Manager::centre_view_grabber({ c => $c, app => &subs::unformat_name($app), timestamp => &subs::rightNow(), cached => 'no' });

	return ('/file_open?appt_uuid=' . $appt_uuid . '&file_uuid=' . $file_uuid . '&app=' . $app,$u_data);
}

sub generate_ai_image {
	my ($data) = @_;
	$data->{'kind'} = 'image';
	return &generate_ai_media($data);
}


sub manager_file_maker() {
	my $session_name = shift;
	my ($my_name,$computer_name,$hostname,$hostnamer,$database_name);
	my ($db,$database) = &subs::database_grabber();
	$hostname = `hostname`;
	chomp $hostname;
	$hostnamer = eval { return &subs::db_select('devices', ['name'], { hostname => $hostname } )->hash->{name} };
	$my_name = $session_name || &subs::setting_grabber({ app => 'me', setting => 'my_name' });
	$computer_name = &subs::config_reader()->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'computer_name' });
	$database_name = $database;
	$database_name =~ s/^database\///;
	$database_name =~ s/.db$//gi;
	my @database_name = split '/', $database_name;
	$database_name = $database_name[-1];

	return ($my_name || $hostnamer || $hostname) . '@' . $database_name . '.' . ($computer_name || $hostname);

};

sub data_size() {
	my $data = shift;
	my $data_size = $data;
	if ($data >= 1024000000) {
		$data_size = sprintf("%.2f", $data / 1000000000) . 'GB';
	}
	elsif ($data > 1024000) {
		$data_size = sprintf("%.2f", $data / 1000000) . 'MB';
	}

	elsif ($data > 1024) {
		$data_size = sprintf("%.2f", $data / 1000) . 'KB';
	}
	return $data_size;
}




sub usual_appointment_maker() {
	my $data = shift;
	my $settings = shift;
	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $uuid = $data->{'uuid'};
	my $type = $data->{'type'};
	my $duration = $data->{'duration'};
	if ($settings->{'project'}) {
		$data->{'project'} = $settings->{'project'};
	}
	my $m = &subs::db_select('model', undef, { app => $app, def => 'on' })->hashes->[0];
	my ($model,$jmodel,$joptions);
	if ($m->{'uuid'} && $m->{'def'} eq 'on' && &default_attribute_time_checker($m,$timestamp) eq 'yes') {
		$model = {
			uuid => $m->{'uuid'},
			name => $m->{'name'},
			timestamp => $timestamp,
			quantity => ($data->{'quantity'} || $m->{'quantity'}),
			unit => $data->{'unit'} || $m->{'unit'},
			delay_start => $m->{'delay_start'},
			delay_stop => $m->{'delay_stop'}
		};
		$jmodel = encode_json $model;
	}

	if ($m->{'save_app'} eq 'on' && $model->{'uuid'}) {
		$data->{'seen'} = 'yes';
		&source_appt_writer($m,$data,'model');
	}

	my $def_options = &subs::db_select('option', undef, { app => $app, def => 'on' })->hashes;
	my $options = [];
	foreach my $do ( @{$def_options} ) {
		next unless &default_attribute_time_checker($do,$timestamp) eq 'yes';
		my $quantity = $do->{'quantity'};
		$quantity = ($data->{'quantity'} || $do->{'quantity'});
		push @{$options}, {
			uuid => $do->{'uuid'},
			timestamp => $timestamp,
			quantity => $quantity,
			unit => $do->{'unit'},
			name => $do->{'name'},
			delay_start => $do->{'delay_start'},
			delay_stop => $do->{'delay_stop'}
		};
		if ($do->{'save_app'} eq 'on') {
			$data->{'seen'} = 'yes';
			&source_appt_writer($do,$data,'option');
		}
	}
	if (scalar @{$options}) {
		$joptions = encode_json $options;
	}
	else { $options = undef; $joptions = undef; }

	return ($model,$options,$jmodel,$joptions);
}

sub default_attribute_time_checker() {
	my $d = shift;
	my $timestamp = shift;
	my @ts = localtime($timestamp / 1000);
	my $allowed_count = 0;

	my $def_month = eval { return decode_json $d->{'def_month'} } || [];
	my $allowed_month = scalar @{$def_month} == 0 ? 1 : 0;
	foreach my $dm ( @{$def_month} ) {
		if ($dm eq 'all') {
			$allowed_month = 1; last;
		} elsif ($dm eq 'none') {
			$allowed_month = 0; last;
		}
		else {
			my ($mon) = grep { $_->{'abbrev'} eq $dm } @{$gb::months};
			if ($mon->{'number'} == $ts[4]) {
				$allowed_month++;
			}
		}
	}
	if ($allowed_month > 0) {
		$allowed_count++;
	}

	my $def_day = eval { return decode_json $d->{'def_day'} } || [];
	my $allowed_day = scalar @{$def_day} == 0 ? 1 : 0;
	foreach my $dd ( @{$def_day} ) {
		if ($dd eq 'all') {
			$allowed_day = 1; last;
		} elsif ($dd eq 'none') {
			$allowed_day = 0; last;
		}	else {
			if ($dd == $ts[3]) {
				$allowed_day++;
			}
		}
	}
	if ($allowed_day > 0) {
		$allowed_count++;
	}

	my $def_wday = eval { return decode_json $d->{'def_wday'} } || [];
	my $allowed_wday = scalar @{$def_wday} == 0 ? 1 : 0;
	foreach my $dw ( @{$def_wday} ) {
		if ($dw eq 'all') {
			$allowed_wday = 1; last;
		} elsif ($dw eq 'none') {
			$allowed_wday = 0; last;
		} else {
			my ($wday) = grep { $_->{'abbrev'} eq $dw } @{$gb::wdays};
			if ($wday->{'number'} == $ts[6]) {
				$allowed_wday++;
			}
		}
	}
	if ($allowed_wday > 0) {
		$allowed_count++;
	}

	my $def_hour = eval { return decode_json $d->{'def_hour'} } || [];
	my $allowed_hour = scalar @{$def_hour} == 0 ? 1 : 0;
	foreach my $dh ( @{$def_hour} ) {
		if ($dh eq 'all') {
			$allowed_hour = 1; last;
		} elsif ($dh eq 'none') {
			$allowed_hour = 0; last;
		} else {
			my ($hour) = grep { $_->{'abbrev'} eq $dh } @{$gb::hours};
			if ($hour->{'number'} == $ts[2]) {
				$allowed_hour++;
			}
		}
	}
	if ($allowed_hour > 0) {
		$allowed_count++;
	}


	return $allowed_count == 4 ? 'yes' : 'no';
}

sub source_appt_writer() {
	my $m = shift;
	my $data = shift;
	my $table = shift;
	my $returner = {};
	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $uuid = $data->{'uuid'};
	my $type = $data->{'type'};
	my $duration = $data->{'duration'};
	my $char = eval { return decode_json $m->{'characteristics'} } || [];
	my $measures = { uuid => &subs::random_string_creator(19) };
	my $unit =  ($app eq $m->{'unit'}) ? $data->{'unit'} : $m->{'unit'};

	my $quantity = $data->{'quantity'} || $m->{'quantity'};

	my $recursion_check = &subs::db_select('appointments', undef, { app => $m->{'name'}, source_uuid => $uuid })->hashes;
	my $datas = {
		app => $m->{'name'},
		timestamp => $timestamp,
		type => $type,
		duration => $duration || 1000,
		source_uuid => $uuid,
		unit => $data->{'unit'} || $m->{'unit'},
		quantity => ($data->{'quantity'} || $m->{'quantity'}),
		project => $data->{'project'} || $m->{'project'},
		manufacturer => $data->{'manufacturer'} || $m->{'manufacturer'}
	};

	if ($type eq 'start' && $m->{'delay_start'}) {
		my $t = &subs::time_abbrev_translator($m->{'delay_start'});
		$timestamp = $timestamp + $t;
		$datas->{'timestamp'} = $timestamp;
	}
	elsif ($type eq 'stop' && $data->{'delay_stop'}) {
		my $t = &subs::time_abbrev_translator($m->{'delay_stop'});
		$timestamp = $timestamp + $t;
		$datas->{'timestamp'} = $timestamp;
	}


	unless (scalar @{$recursion_check} > 0) {


		if ($table eq 'model') {

		}
		elsif ($table eq 'option') {

		}
		my $md5 = md5_sum $datas->{'source_uuid'} . '-' . $app . '-' . $timestamp . '-' . $datas->{'app'};
		$datas->{'uuid'} = $datas->{'source_uuid'} . '-' . $md5;# || &subs::random_string_creator(92);
		my $c = &subs::controller_builder();
		$returner = &Manager::appointment_writer($c,$datas);
	}

	foreach my $ch ( @{$char} ) {
		if ($ch->{'save_appt'} eq 'on') {
			$datas->{'app'} = &subs::unformat_name($ch->{'name'});
			$datas->{'source_uuid'} = $returner->{'uuid'};
			$datas->{'quantity'} = $ch->{'value'};
			$datas->{'unit'} = $ch->{'unit'};
			my $md5 = md5_sum $datas->{'source_uuid'} . '-' . $app . '-' . $timestamp . '-' . $ch->{'name'};
			$datas->{'uuid'} = $datas->{'source_uuid'} . '-' . $md5,# || &subs::random_string_creator(92);
			my $c = &subs::controller_builder();
			&Manager::appointment_writer($c, $datas);
		}
	}

}

sub log_writer() {
	my $data = shift;
	my $log_data;
	my $timestamp = &subs::rightNow();
	if ( eval { @{$data} } ) {
		$log_data = Dumper $data;
	}
	elsif ( eval { %{$data} } ) {
		$log_data = Dumper $data;
	}
	else {
		$log_data = $data;
	}
	my $settings = &subs::settings_grabber({ app => 'terminal' });

	$settings->{'log'} = eval { return decode_json $settings->{'log'} } || [];
	splice @{$settings->{'log'}}, 30;
	my $uuid = &subs::random_string_creator(10);
	my $logg = { timestamp => $timestamp, 'msg' => $log_data, uuid => $uuid };
	push @{$settings->{'log'}}, $logg;

	my $sl = encode_json $settings->{'log'};
	&subs::setting_setter({ app => 'terminal', setting => 'log', value => $sl });
	&Websocket::send('server', { view => 'log', console => $logg, error => $uuid });
	return $data;
}

# A fingerprint of the code this machine is actually running. There is no
# .git on the remote machines (remote_rsync excludes it), so the source files
# themselves are hashed; when a .git is present the commit is reported too.
# Computed once per process and memoised - the app only re-reads its code on a
# restart, so the values cannot change under it.
our $code_revision_cache;
my $jawn_version_cache;

# The human version shown in the System view (and available to the peer
# handshake). Bumped per commit by scripts/version_bump.pl; stored in ./VERSION.
sub jawn_version() {
	return $jawn_version_cache if $jawn_version_cache;
	my $v = eval { read_file('./VERSION') } || '';
	$v =~ s/\s+$//;
	$v = '0.0.0' unless $v =~ /\d/;
	return $jawn_version_cache = $v;
}

# A bump rewrites ./VERSION under a live process; whatever cached the old number
# (the Coding agent's commit subject reads it) must be told to forget it.
sub jawn_version_forget { undef $jawn_version_cache; }

sub code_revision() {
	return $code_revision_cache if $code_revision_cache;
	my @files;
	# The fingerprint is grouped as well as whole: a connected browser reads the
	# parts and asks what changed - a script (it must reload), a stylesheet (it
	# can point the link at the new build live), a template (re-render the open
	# windows), the shell or the server (reload / nothing) - before deciding how
	# to update itself. (See jawnosRevisionArrived in websocket.js.)
	my %part_canon = ( js => '', css => '', views => '', shell => '', server => '' );
	find({ no_chdir => 1, wanted => sub {
		my $n = $File::Find::name;
		return unless -f $n;
		return if $n =~ m{(^|/)\.git/} || $n =~ m{node_modules};
		push @files, $n if $n =~ /\.(pl|pm|ep|js|css)$/ || $n =~ m{(^|/)jawn$};
	} }, '.');
	@files = sort @files;
	my $canon = '';
	foreach my $f ( @files ) {
		my $c = eval { read_file($f) };
		my $line = $f . ':' . md5_sum(defined $c ? $c : '') . "\n";
		$canon .= $line;
		my $part = 'server';
		$part = 'js' if $f =~ /\.js$/;
		$part = 'css' if $f =~ /\.css$/;
		$part = 'views' if $f =~ /\.ep$/;
		# the shell frames every page at once: it cannot be rebuilt under a live tab
		$part = 'shell' if $f =~ m{(^|/)manager\.html\.ep$} || $f =~ m{(^|/)templates/layouts/};
		$part_canon{$part} .= $line;
	}
	my $fingerprint = md5_sum($canon);
	my ($commit,$branch,$dirty) = ('','',0);
	if (-e '.git') {
		$commit = `git rev-parse HEAD 2>/dev/null`; chomp $commit;
		$branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`; chomp $branch;
		# untracked files are not what the app runs (and the auto-update watcher
		# ignores them too), so `dirty` means tracked files were modified
		$dirty = 1 if (`git status --porcelain --untracked-files=no 2>/dev/null` =~ /\S/);
	}
	my $hostname = `hostname`; chomp $hostname;
	$code_revision_cache = {
		fingerprint => $fingerprint,
		commit => $commit,
		branch => $branch,
		dirty => $dirty,
		files => scalar @files,
		hostname => $hostname,
		signatorial => &subs::signatorial_designer(),
		parts => { map { $_ => md5_sum($part_canon{$_}) } sort keys %part_canon },
	};
	return $code_revision_cache;
}

# A money move is a warehouse row. Every transaction with an account is written
# to the warehouse as it is recorded - the same fields under the same names, so
# the budget can read the ledger without knowing it moved - and the row is keyed
# by the source transaction's uuid, so a re-write or a backfill cannot double it.
# kind='money' marks it; type and movement keep what the transaction was.
# (Lives here, not in Manager.pl, so the boot process can run backfills.)
sub warehouse_money_mirror {
	my $row = shift;
	return unless $row && $row->{'uuid'};
	my $type = $row->{'type'} || '';
	return unless ($type eq 'transaction' || $type eq 'purchase');
	return unless $row->{'account'} && $row->{'account'} ne '';
	# an inventory row is a balance anchor, not a move; it already has its own
	# warehouse row (kind inventory)
	return if ($row->{'movement'} || '') eq 'inventory';
	my $exists = &subs::db_query('select uuid from warehouse where kind=? and uuid=? limit 1', 'money', $row->{'uuid'})->hashes->[0];
	return if $exists;
	my $movement = $row->{'movement'};
	$movement = 'expense' if (!defined $movement || $movement eq '') && $type eq 'purchase';
	&subs::db_insert('warehouse', {
		kind => 'money',
		type => $type,
		movement => $movement,
		app => $row->{'app'},
		account => $row->{'account'},
		project => $row->{'project'},
		item => $row->{'item'},
		model => $row->{'model'},
		quantity => $row->{'quantity'},
		unit => $row->{'unit'},
		amount => $row->{'amount'},
		tax => $row->{'tax'},
		aux => $row->{'aux'},
		total => $row->{'total'},
		duration => $row->{'duration'},
		vendor => $row->{'vendor'},
		manufacturer => $row->{'manufacturer'},
		currency => $row->{'currency'},
		notes => $row->{'notes'},
		state => $row->{'state'},
		warranty => $row->{'warranty'},
		place => $row->{'place'},
		data => $row->{'data'},
		uuid => $row->{'uuid'},
		app_uuid => $row->{'uuid'},
		source_uuid => $row->{'source_uuid'},
		timestamp => $row->{'timestamp'},
		server_time => &subs::rightNow(),
	});
}

# ---------------------------------------------------------------------------
# Data backfills. Schema migrations can be detected by inspecting the schema
# (Manager::migration_already_applied); a data backfill cannot, so it is named
# here and recorded in the `backfills` table once it has run. A machine that
# receives this code runs any names it has not recorded - from the boot process
# (President) and from update_database (login / remote auth / merge) - so a
# code sync followed by the usual restart heals the data without a manual step.
#
# An entry returns true when it has run (recorded), false when its
# prerequisites are not ready yet (left for the next pass, e.g. the column the
# schema migration adds is not there), and dies on a real error (logged).
# ---------------------------------------------------------------------------

# The warranty a guide message expires on: the appointment's own when the thread
# is scoped to an app (its conversation name is app_<name>), otherwise the house
# default. It lives here - not in Manager - so the backfill below can stamp old
# turns from the boot process too, before the Manager worker is loaded.
sub guide_message_warranty() {
	my ($name) = @_;
	my $now = &subs::rightNow();
	my $default = &subs::ago_calc(&subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', $now);
	if ($name && $name =~ /^app_(.+)$/) {
		my $app = $1;
		my $rows = &subs::db_query('select warranty from appointments where app = ? order by timestamp desc limit 1', $app)->hashes;
		if (scalar @{$rows} && defined $rows->[0]->{'warranty'} && ($rows->[0]->{'warranty'} + 0) > 0) {
			return $rows->[0]->{'warranty'} + 0;
		}
	}
	return $default;
}

sub backfills() {
	return {
		'door_seed' => sub {
			# the login password gets its own row so the key can stay put when
			# the password changes; on an existing machine the password and the
			# key are one thing, so the key itself is the door password
			return 0 if &door_row();
			my @vault = &vault_read();
			my $vault = $vault[0];
			return 0 unless $vault && &suds_current($vault);
			return &door_set($vault) ? 1 : 0;
		},
		'suds_canary_reseal' => sub {
			# the level-1 canary on older databases can be data written with
			# the empty passphrase, in which case a db copy decrypts to the key
			# for free. Re-seal it to the key itself - and only once the door
			# row exists, because the resealed canary no longer leaks the way in.
			return 0 unless &door_row();
			my @vault = &vault_read();
			my $vault = $vault[0];
			return 0 unless $vault && &suds_current($vault);
			my $q = &db_select('security', ['uuid','credential'], { level => 1 });
			my $row = $q ? $q->hash : undef;
			return 0 unless $row;
			my $leak = &decrypter(undef, $row->{'credential'});
			return 1 unless defined $leak && length $leak && $leak eq $vault;
			my $sealed = &encrypter($vault, $vault);
			return 0 unless $sealed && &decrypter($vault, $sealed) eq $vault;
			&db_update('security', { credential => $sealed }, { uuid => $row->{'uuid'} });
			return &suds_current($vault) ? 1 : 0;
		},
		'ticket_suds_retire' => sub {
			# tickets no longer carry a copy of the house key: the vault is the
			# only place it lives. Only scrub where the vault validates, so a
			# machine that still needs the legacy chain keeps it.
			my @vault = &vault_read();
			my $vault = $vault[0];
			return 0 unless $vault && &suds_current($vault);
			&db_query("update tickets set suds = '' where suds is not null and suds != ''");
			return 1;
		},
		'warehouse_money_ledger' => sub {
			# needs the ledger column; defer until the schema migration has run
			my $has = &subs::db_query('select 1 from pragma_table_info(?) where name=?', 'warehouse', 'kind')->hashes->[0];
			return 0 unless $has;
			&subs::db_query("update warehouse set kind = 'inventory' where (kind is null or kind = '') and type = 'inventory'");
			&subs::db_query("update warehouse set kind = 'stock' where (kind is null or kind = '')");
			&subs::db_query("update warehouse set movement = 'inventory' where kind = 'inventory' and (movement is null or movement = '')");
			my $rows = &subs::db_query("select * from appointments where type in ('transaction','purchase') and account is not null and account != '' and (movement is null or movement != 'inventory')")->hashes;
			my $n = 0;
			foreach my $row ( @{$rows} ) {
				next if &subs::db_query('select uuid from warehouse where kind=? and uuid=? limit 1', 'money', $row->{'uuid'})->hashes->[0];
				&subs::warehouse_money_mirror($row);
				$n++;
			}
			&subs::say_it("backfill warehouse_money_ledger: mirrored $n money transactions");
			return 1;
		},
		'mugshot_to_file' => sub {
			# The mugshot was a multi-megabyte data URI in settings, which every
			# load and every sync paid for. Hold it as a sealed picture under the
			# photo location's `me` folder instead. Only the owning device converts
			# its own row: the sealed file lives on this machine's disk and is not
			# synced, so a machine that converted another device's row would leave
			# that device pointing at a file only this one has.
			my $dev = &subs::device_setter();
			my $folder = &subs::setting_grabber({ app => 'misc', setting => 'photo_location', device => $dev });
			return 0 unless $folder;
			my $location = &subs::home($folder) . '/me';
			my $rows = &subs::db_query("select device,value from settings where app='me' and setting='mugshot' and device=?", $dev)->hashes;
			foreach my $row ( @{$rows} ) {
				my $val = $row->{'value'} // '';
				next unless $val =~ /^data:image\/\w+;base64,(.*)$/s;
				my $img = MIME::Base64::decode_base64($1);
				next unless $img && length $img;
				`mkdir -p "$location"` unless -e $location;
				my $raw = "$location/mugshot.$dev.png";
				write_file($raw, $img);
				my $secret = &subs::suds_grabber();
				my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
				&openssl_file_crypt('e', $standard, $secret, $raw, "$location/mugshot.$dev.png.enc", 0, 1);
				`shred -u "$raw"`;
				&subs::setting_setter({ app => 'me', setting => 'mugshot', device => $dev, value => "mugshot.$dev.png.enc" });
			}
			return 1;
		},
		'guess_to_me_folder' => sub {
			# A guessed map's picture was a loose png in the travel folder; it is
			# held sealed under the photo location's `me` folder now - the place the
			# mugshot lives - which is where the atlas and the delete path read it
			# from. Only the owning device converts its own rows: the sealed file
			# lives on this machine's disk and is not synced.
			my $dev = &subs::device_setter();
			my $folder = &subs::setting_grabber({ app => 'misc', setting => 'photo_location', device => $dev });
			return 0 unless $folder;
			my $row = &subs::db_select('settings', undef, { app => 'travel', setting => 'maps', device => $dev })->hashes->[0];
			return 1 unless $row;
			my $maps = eval { return decode_json $row->{'value'} } || [];
			my $location = &subs::home($folder) . '/me';
			my $secret = &subs::suds_grabber();
			my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
			my (@converted, $failed);
			foreach my $map ( @{$maps} ) {
				next unless $map->{'guessed'} && $map->{'f'};
				next if $map->{'f'} =~ /\.enc$/;
				next unless -e $map->{'f'};
				my $bytes = eval { read_file($map->{'f'}) };
				next unless $bytes && length $bytes;
				`mkdir -p "$location"` unless -e $location;
				my $raw = $location . '/guess_' . $map->{'uuid'} . '.png';
				my $sealed = $location . '/guess_' . $map->{'uuid'} . '.png.enc';
				write_file($raw, $bytes);
				&openssl_file_crypt('e', $standard, $secret, $raw, $sealed, 0, 1);
				unless (-e $sealed && -s $sealed) { unlink $raw; $failed++; next; }
				`shred -u "$raw"`;
				push @converted, [ $map->{'uuid'}, $map->{'f'}, $sealed ];
				$map->{'f'} = $sealed;
			}
			if (@converted) {
				&subs::setting_setter({ app => 'travel', setting => 'maps', device => $dev, value => encode_json $maps });
				# the record has to name the sealed copy before the loose one is let
				# go, so a setter that did not land leaves a working picture behind
				my $now = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps', device => $dev }) } || [];
				my %sealed_for = map { $_->{'uuid'} => $_->{'f'} } @{$now};
				my $n = 0;
				foreach my $c ( @converted ) {
					my ($uuid, $old, $sealed) = @{$c};
					next unless ($sealed_for{$uuid} || '') eq $sealed;
					unlink $old if $old =~ m{/guess_[^/]+\.png$};
					$n++;
				}
				&subs::say_it("backfill guess_to_me_folder: sealed $n guess picture(s) into $location");
			}
			return $failed ? 0 : 1;
		},
		'guide_message_warranty' => sub {
			# Guide turns were saved before each message carried its own warranty;
			# stamp the ones missing it so they age out the way everything else does.
			my $rows = &subs::db_query("select setting, value from settings where app = ? and setting like ?", '__president', 'guide_conversation_%')->hashes;
			my $n = 0;
			foreach my $row ( @{$rows} ) {
				my $setting = $row->{'setting'} // '';
				next unless $setting =~ /^guide_conversation_(.+)$/;
				my $name = $1;
				my $transcript = eval { decode_json $row->{'value'} } || [];
				$transcript = [] unless ref $transcript eq 'ARRAY';
				my $warranty = &guide_message_warranty($name);
				my $changed = 0;
				foreach my $m ( @{$transcript} ) {
					next if defined $m->{'warranty'};
					$m->{'warranty'} = $warranty;
					$changed++;
				}
				next unless $changed;
				&subs::setting_setter({ app => '__president', setting => 'guide_conversation_' . $name, value => encode_json $transcript });
				$n += $changed;
			}
			&subs::say_it("backfill guide_message_warranty: stamped $n guide message(s)");
			return 1;
		},
		'settings_dedupe_null_keys' => sub {
			# A settings row is keyed by (app, setting, device, subsetting), but the
			# setter's delete used '=', so an undef in any key column (a missing
			# subsetting, or a window-state save with no app) matched nothing and every
			# write left its predecessor behind: thousands of invisible same-value
			# duplicates (342 groups, 1640 rows on one machine) that grew the table and
			# every sync - the 'Now merging N settings' that looked stuck. The setter is
			# fixed now; this collapses what is already there, and runs again (under this
			# new name) so a machine that had already run the first pass, and kept
			# accumulating the app-null rows it could not prevent, is cleaned too. Keep
			# the row the reader returns - settings_grabber assigns in row order, so the
			# last write (highest rowid) is the visible value - and drop the rest. A peer
			# that still carries a duplicate cannot bring it back: a merge skips a row it
			# already holds at >= server_time. Group by the column itself, not
			# coalesce(subsetting,''): SQLite groups NULLs together but apart from '', and
			# those are two keys, so a non-null subsetting row is never mistaken for a
			# duplicate of a null one.
			my $sth = eval { &subs::db_query(
				q{delete from settings
				   where rowid not in (
				     select max(rowid) from settings
				     group by app, setting, device, subsetting)}) };
			return 0 unless $sth;   # a locked database: retry on the next pass
			&subs::say_it('backfill settings_dedupe_null_keys: collapsed ' . $sth->rows . ' duplicate settings row(s)');
			return 1;
		},
	};
}

our $backfills_running;
sub run_backfills() {
	return if $backfills_running;
	$backfills_running = 1;
	my $ok = eval {
		&subs::db_query('create table if not exists backfills (name VARCHAR(255), server_time VARCHAR(255))');
		my $registry = &subs::backfills();
		my %done = map { $_->{'name'} => 1 } @{ &subs::db_query('select name from backfills')->hashes || [] };
		foreach my $name ( sort keys %{$registry} ) {
			next if $done{$name};
			my $status = eval { $registry->{$name}->() };
			if ($@) { &subs::say_it("backfill '$name' failed: $@"); next; }
			next unless $status;
			&subs::db_query('insert into backfills (name, server_time) values (?,?)', $name, &subs::rightNow());
			&subs::say_it("backfill '$name' recorded");
		}
		1;
	};
	&subs::say_it("run_backfills error: $@") if !$ok && $@;
	$backfills_running = 0;
	return $ok;
}

# ---------------------------------------------------------------------------
# Auto-update. A machine that receives code by git can keep itself current: the
# watcher fetches origin and fast-forwards when the tree is clean and strictly
# behind (never clobbers local commits or a dirty tree), then asks jawn to
# restart. When the tree is clean but diverged because origin's history was
# rewritten (every local commit still exists upstream under a new hash), it
# resets hard to origin/main so the machine rejoins the update track; a tree
# with genuinely local commits is left alone. Open browsers reload on their own:
# the websocket hands out the revision and the client reloads when it changes.
# ---------------------------------------------------------------------------
# Push the current code to a neighbour over ssh, using the credentials the
# remote_machines table already holds. Every device can also pull on its own
# (git_watcher_check), so this is the "force it now" lever: fast-forward the
# repo, reinstall the desktop app where one is installed, and ask jawn to
# restart. Returns { ok, message, output }.
sub remote_deploy {
	my ($rm, %opts) = @_;
	# Deploy over http: ask the peer to pull, reinstall its desktop app and
	# restart - the same work the old ssh command did, minus ssh and the stored
	# password. remote_useragent_maker hands back the peer's tunnel-aware
	# manager url and the session cookie we already hold for it.
	my $r = eval { &Manager::remote_useragent_maker({ signatorial => $rm->{'signatorial'}, rm => $rm, ip => $rm->{'ip'} }) };
	my $manager = ($r && $r->{'manager'}) || $rm->{'manager'};
	unless ($manager && $r && $r->{'ua'}) {
		return { ok => 0, message => 'no route to peer' };
	}
	my $url = $manager . '/manager/self_deploy?signatorial=' . &subs::signatorial_designer() . ($opts{'force'} ? '&force=1' : '');
	my $res = eval { $r->{'ua'}->inactivity_timeout(60)->post($url)->result };
	my $ok = ($res && $res->is_success) ? 1 : 0;
	if ($subs::logfile) {
		open(my $fh, '>>', $subs::logfile);
		print $fh &subs::rightNow() . " remote deploy " . ($rm->{'hostname'} || $rm->{'ip'}) . ": " . ($ok ? 'ok' : 'fail') . "\n";
		close $fh;
	}
	return { ok => $ok, message => $ok ? 'deployed' : 'http deploy failed', output => ($res ? $res->body : '') };
}

sub git_binary {
	return $ENV{'GIT_BINARY'} if $ENV{'GIT_BINARY'} && -x $ENV{'GIT_BINARY'};
	# the cloud runs git from a user-space install (no root)
	my $local = ($ENV{'HOME'} || '') . '/opt-git/git';
	return $local if -x $local;
	return 'git';
}

# Fast-forward a checkout to origin/main. Returns (status, output):
#   current   already up to date
#   updated   fast-forwarded to origin/main
#   ahead     has commits origin/main does not; left alone
#   reset     diverged, but every local commit already exists upstream under a
#             rewritten hash, so reset hard to origin/main (nothing unique lost)
#   diverged  has local commits that are not upstream; left alone (use force)
#   dirty     tracked files are modified; never touched (use force)
#   error     the fetch failed (no route, bad credentials) or the checkout
#             could not be read; nothing was moved
#   no-repo   not a git checkout
# A clean tree only, unless force, which skips the dirty guard and hard-resets.
# Which of two dotted versions is newer - numerically, so 0.1.112 beats 0.1.79
sub version_cmp {
	my ($left, $right) = @_;
	my @l = split /\./, ($left || '');
	my @r = split /\./, ($right || '');
	for my $i (0 .. 2) {
		my $x = ($l[$i] // 0) + 0;
		my $y = ($r[$i] // 0) + 0;
		return $x <=> $y if $x != $y;
	}
	return 0;
}
sub version_newer {
	my ($candidate, $mine) = @_;
	return 0 unless ($candidate || '') =~ /\d/;
	return 0 unless grep { /\d/ } split /\./, ($mine || '');
	return &subs::version_cmp($candidate, $mine) > 0 ? 1 : 0;
}

# The tree the working files would commit as, without touching the worktree or
# the index. A code sync writes a peer's files over a checkout, so this is what
# a commit would carry - and what can be compared with the commits origin knows.
sub git_worktree_tree {
	my ($repo) = @_;
	my $git = &subs::git_binary();
	my $stash = `cd "$repo" && "$git" -c user.name=jawnos -c user.email=jawnos\@localhost stash create 2>/dev/null`;
	chomp $stash;
	return undef unless $stash =~ /^[0-9a-f]{7,40}$/;
	my $tree = `cd "$repo" && "$git" rev-parse "$stash^{tree}" 2>/dev/null`;
	chomp $tree;
	return ($tree =~ /^[0-9a-f]{40}$/) ? $tree : undef;
}

# Whether origin/main's history already carries this exact tree.
sub git_origin_has_tree {
	my ($repo, $tree) = @_;
	my $git = &subs::git_binary();
	my $trees = `cd "$repo" && "$git" log --format=%T origin/main 2>/dev/null`;
	return scalar grep { $_ eq $tree } split /\n/, $trees;
}

# A code sync writes a peer's tree over a checkout (the pack excludes .git), so
# every synced file reads as modified against a stale HEAD. Put the checkout back
# in a state git can move: if the synced tree is a shipped commit, reset to
# origin/main; otherwise preserve it as a local commit, so the work is not lost
# and the tree is clean for the next pull. No git, nothing to do.
sub git_checkout_normalize {
	my ($opts) = @_;
	my $repo  = $opts->{'repo'} || &subs::home('~/jawnos');
	my $label = $opts->{'label'} || 'sync';
	my $git   = &subs::git_binary();
	return ('no-repo', '') unless -d "$repo/.git";
	my $dirty = `cd "$repo" && "$git" status --porcelain --untracked-files=no 2>/dev/null`;
	return ('clean', '') unless $dirty =~ /\S/;
	# best effort: with no route the synced tree is still worth preserving
	`cd "$repo" && "$git" fetch origin --quiet 2>/dev/null`;
	my $fetched = ($? == 0);
	my $tree = &subs::git_worktree_tree($repo);
	if ($fetched && $tree && &subs::git_origin_has_tree($repo, $tree)) {
		my $out = `cd "$repo" && "$git" reset --hard origin/main 2>&1`;
		return ('reset', $out);
	}
	my $version = &subs::jawn_version();
	my $out = `cd "$repo" && "$git" add -A 2>&1`;
	$out .= `cd "$repo" && "$git" -c user.name=JawnOS -c user.email=jawnos\@localhost commit --no-verify -m "code sync: $label ($version)" 2>&1`;
	return (($? == 0) ? 'committed' : 'dirty', $out);
}

sub git_repo_update {
	my ($opts) = @_;
	my $repo  = $opts->{'repo'} || &subs::home('~/jawnos');
	my $force = $opts->{'force'} ? 1 : 0;
	my $git   = &subs::git_binary();
	return ('no-repo', '') unless -d "$repo/.git";
	my $run = sub { my $cmd = shift; return `cd "$repo" && $cmd 2>&1`; };
	my $dirty = '';
	unless ($force) {
		# never touch a tree with local modifications to tracked files, but see
		# below: a tree whose content is already a shipped commit is not work
		$dirty = $run->("\"$git\" status --porcelain --untracked-files=no");
	}
	my $out = $run->("\"$git\" fetch origin --quiet");
	# a failed fetch must never be acted on: the remote-tracking ref may be
	# stale, so comparing HEAD against it could read as current (or worse, a
	# force could reset to the stale ref). error sends the watcher to its peer
	# fallback instead.
	my $fetch_ok = $? ? 0 : 1;
	if (!$force && $dirty =~ /\S/) {
		# A code sync leaves a checkout dirty with files that are part of a
		# commit origin already has (the pack excludes .git). That is not local
		# work to protect: reset to the authority instead of sitting behind.
		if ($fetch_ok) {
			my $tree = &subs::git_worktree_tree($repo);
			if ($tree && &subs::git_origin_has_tree($repo, $tree)) {
				my $reset = $run->("\"$git\" reset --hard origin/main");
				return ('reset', $dirty . $reset);
			}
		}
		return ('dirty', $dirty);
	}
	my $head   = `cd "$repo" && "$git" rev-parse HEAD 2>/dev/null`; chomp $head;
	my $origin = `cd "$repo" && "$git" rev-parse origin/main 2>/dev/null`; chomp $origin;
	return ('error', $out) unless $fetch_ok && $head && $origin;
	return ('current', $out) if $head eq $origin;
	# force makes the checkout exactly origin/main, whatever the local state
	if ($force) {
		$out .= $run->("\"$git\" reset --hard origin/main");
		return ('reset', $out);
	}
	my $behind = (system("cd \"$repo\" && \"$git\" merge-base --is-ancestor HEAD origin/main >/dev/null 2>&1") == 0);
	return ('ahead', $out) if system("cd \"$repo\" && \"$git\" merge-base --is-ancestor origin/main HEAD >/dev/null 2>&1") == 0;
	if ($behind) {
		$out .= $run->("\"$git\" merge --ff-only origin/main");
		return ('updated', $out);
	}
	# diverged and not ahead: accept it when every local commit is already
	# upstream under a rewritten hash (git cherry marks those with '-')
	my $cherry = $run->("\"$git\" cherry origin/main HEAD");
	return ('diverged', $out . $cherry) if grep { /^\+/ } split /\n/, $cherry;
	$out .= $run->("\"$git\" reset --hard origin/main");
	return ('reset', $out);
}

# Pull the code from a peer: it hands back a git bundle of its own HEAD (a
# delta since ours when it can), we fetch it and fast-forward or reset by the
# same rules as a pull from origin. This is the watcher's fallback for a machine
# with no route to GitHub. ff_only also refuses the reset case: the fallback
# must never move a tree anywhere a fast-forward cannot reach, or a peer whose
# advertised version outran its actual tree can drag a machine backward (the
# rewritten-history reset once did, under "whoever has the newest is it").
sub git_peer_update {
	my ($opts) = @_;
	my $repo = $opts->{'repo'} || &subs::home('~/jawnos');
	my $rm = $opts->{'rm'};
	my $git = &subs::git_binary();
	return ('no-repo', '') unless -d "$repo/.git";
	return ('no-peer', '') unless $rm;
	# never touch a tree with local modifications to tracked files
	my $dirty = `cd "$repo" && "$git" status --porcelain --untracked-files=no 2>&1`;
	return ('dirty', $dirty) if $dirty =~ /\S/;
	my $head = `cd "$repo" && "$git" rev-parse HEAD 2>/dev/null`; chomp $head;
	my ($ua, $p) = &subs::peer_useragent($rm);
	return ('no-peer', '') unless $ua;
	my $url = $p->{'manager'} . '/manager/code_bundle?signatorial=' . &subs::signatorial_designer() . '&base=' . ($head || '');
	my $res = eval { $ua->inactivity_timeout(60)->get($url)->result };
	return ('peer-error', '') unless $res && $res->is_success && length($res->body || '');
	require File::Temp;
	my ($fh, $path) = File::Temp::tempfile(SUFFIX => '.bundle', UNLINK => 1);
	binmode $fh;
	print $fh $res->body;
	close $fh;
	my $fetch = `cd "$repo" && "$git" fetch "$path" HEAD 2>&1`;
	my $target = `cd "$repo" && "$git" rev-parse FETCH_HEAD 2>/dev/null`; chomp $target;
	unlink $path;
	return ('fetch-error', $fetch) unless $target;
	my $current = `cd "$repo" && "$git" rev-parse HEAD 2>/dev/null`; chomp $current;
	return ('current', '') if $current eq $target;
	if (system("cd \"$repo\" && \"$git\" merge-base --is-ancestor HEAD $target >/dev/null 2>&1") == 0) {
		my $out = `cd "$repo" && "$git" merge --ff-only $target 2>&1`;
		return ('updated', $out);
	}
	# a rewritten history landing on the same work (git cherry marks every local
	# commit '-') is a reset, not a conflict
	my $cherry = `cd "$repo" && "$git" cherry $target HEAD 2>&1`;
	return ('diverged', $cherry) if $opts->{'ff_only'} || grep { /^\+/ } split /\n/, $cherry;
	my $out = `cd "$repo" && "$git" reset --hard $target 2>&1`;
	return ('reset', $out);
}

# Best-effort, idempotent install of the optional applications the tree names
# (scripts/jawnos_deps.pl's extras: Piper today). Called after a code update so a
# new version's new apps land without a hand; a device that cannot install one
# simply keeps the fallback.
sub install_extras {
	my $script = &subs::home('~/jawnos/scripts/jawnos_deps.pl');
	return unless -e $script;
	my $repo = &subs::home('~/jawnos');
	my $out = `cd "$repo" && perl scripts/jawnos_deps.pl --extras-only --install 2>&1`;
	if ($subs::logfile && defined $out && $out =~ /\S/) {
		open(my $fh, '>>', $subs::logfile);
		print $fh &subs::rightNow() . " extras: " . join(' ', grep { /\S/ } split "\n", $out) . "\n";
		close $fh;
	}
}

# ---- the error watch: the Coding agent's ears -------------------------
# The running tree prints its warnings and errors to the pty that the master
# (`./jawn`) reads, and jawn tees that stream into ~/pty.log. This watcher tails
# it (and ~/manager.log, for the $log lines that never reach the pty) and records
# each new error signature once in staged_fixes. When a Coding model is set, the
# agent reads the error and stages a proposed fix - whole files, not applied yet
# - for a person to review and apply from the IDE's coding chatbox. President
# runs the tick, so there is exactly one watcher per machine.

my %error_watch_state;    # source => bytes already read (for this watcher's life)
my %error_watch_partial;  # source => an unterminated tail line
my $error_watch_state_loaded = 0;

sub error_watch_offsets_file { return &subs::home('~/.president/error_watch_offsets'); }

# The offsets live in a little file so a President restart (which happens on
# every code change) does not re-read the whole pty log and count every fault
# again; ~/.president is wiped when the master starts, so they never outlive the
# pty log they describe.
sub error_watch_state_load {
	my $file = &error_watch_offsets_file();
	return unless -f $file;
	my $saved = eval { decode_json scalar read_file($file) } || {};
	foreach my $source ( keys %{$saved} ) {
		next unless defined $saved->{$source} && $saved->{$source} =~ /^[0-9]+$/;
		$error_watch_state{$source} = $saved->{$source} + 0;
	}
}

sub error_watch_state_save {
	return unless %error_watch_state;
	write_file(&error_watch_offsets_file(), encode_json(\%error_watch_state));
}

# The watch's purse: what today's proposals have cost, kept in the local cache
# (cache is never synced or backed up), so the day's budget can stop it before
# a runaway spend. The ceiling is the error_watch_budget setting (tokens/day;
# unset means a 1,000,000-a-day default, and 0 means no ceiling).
sub watch_tokens_day { return localtime()->strftime('%Y-%m-%d'); }

sub watch_tokens_spent {
	# the purse is the house's: this machine's spend plus every peer's, which ride in
	# with the ordinary settings/database sync. The local cache stays as the floor,
	# so a machine with no ledger row yet never reads itself as having spent nothing.
	my $house = eval { &ai_house_budget_spent() } || 0;
	my $row = &subs::cache_get({ app => '__president', context => 'watch_tokens', subcontext => &watch_tokens_day() });
	my $local = (ref $row eq 'HASH') ? ($row->{'total'} || 0) : 0;
	return $house > $local ? $house : $local;
}

sub watch_tokens_add {
	my ($tokens) = @_;
	return unless $tokens;
	my $row = &subs::cache_get({ app => '__president', context => 'watch_tokens', subcontext => &watch_tokens_day() }) || {};
	&subs::cache_set(
		{ app => '__president', context => 'watch_tokens', subcontext => &watch_tokens_day(), warranty => '-2d' },
		{ total => ($row->{'total'} || 0) + $tokens, proposals => ($row->{'proposals'} || 0) + 1 }
	);
	# and add it to the shared purse, so every machine's ceiling sees the whole
	# house's spend and the day's budget is one pot, not one per machine
	eval { &ai_house_budget_add($tokens) };
}

# ---- the house AI ledger -----------------------------------------------------
# One machine runs each AI job, and the day's purse is shared. A "job" is a unit
# of work with a name: an error's fix, an app's evaluation. Ownership is
# deterministic - a stable hash ranks the house and the job's home is the member
# ranked first - so every machine computes the same home with no lock service and
# no shared write to race. Only the home's own watcher proposes a given fix or
# runs a given evaluation.
#
# Eligibility rides the same synced tables: each machine publishes its own row
# (does it have an AI model, when it was last seen) and its own day's spend. The
# house is the members whose row says they have a model and were seen recently;
# a machine with nothing synced yet sees only itself, so it still works alone.

sub ai_house_today { return localtime()->strftime('%Y-%m-%d'); }

sub ai_house_have_model {
	return ( &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant' })
		|| &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' })
		|| &subs::setting_grabber({ app => 'mail', setting => 'eval_assistant' }) ) ? 1 : 0;
}

sub ai_house_me { return eval { &subs::signatorial_designer() } || ''; }

# Publish this machine's capability and heartbeat, throttled: a row every couple
# of minutes is enough to keep it counted, and the peers see it when next synced.
sub ai_house_publish {
	my $me = &ai_house_me();
	return unless length $me;
	my $now = &subs::rightNow();
	my $have = &ai_house_have_model();
	my $row = eval { &subs::db_select('ai_house', undef, { machine => $me })->hashes->[0] };
	return if $row && ($row->{'seen'} + 0) > ($now - 120000) && (($row->{'has_model'} || 0) ? 1 : 0) == $have;
	&subs::db_delete('ai_house', { machine => $me });
	&subs::db_insert('ai_house', { machine => $me, has_model => $have, seen => $now, server_time => $now });
}

# Publish this machine's capability and heartbeat, and make sure the ledger tables
# exist (so it works from the first boot after an update, before anyone logs in
# and migrates). Called at the top of the watch tick, before the watch toggles
# are consulted: the ledger gates evaluations and the shared budget too, so a
# machine must announce itself whatever the watches are set to.
our $ai_ledger_ready;
sub ai_house_heartbeat {
	# create the ledger once per process (the tables, their index, and the columns
	# db_insert always writes - uuid and ost - added to any table built before
	# they existed, so the ledger's own writes land)
	unless ($ai_ledger_ready) {
		foreach my $sql (
			'create table if not exists ai_house (uuid VARCHAR(255), machine VARCHAR(255) unique, has_model INT, seen VARCHAR(25), ost VARCHAR(255), server_time VARCHAR(255))',
			'create table if not exists ai_jobs (uuid VARCHAR(255), job VARCHAR(255) unique, owner VARCHAR(255), at VARCHAR(25), state VARCHAR(25), ost VARCHAR(255), server_time VARCHAR(255))',
			'create table if not exists ai_budget (uuid VARCHAR(255), machine VARCHAR(255), day VARCHAR(25), tokens INT, ost VARCHAR(255), server_time VARCHAR(255))',
			'create unique index if not exists idx_ai_budget on ai_budget (machine, day)',
			'alter table ai_house add column uuid VARCHAR(255)',
			'alter table ai_house add column ost VARCHAR(255)',
			'alter table ai_jobs add column uuid VARCHAR(255)',
			'alter table ai_jobs add column ost VARCHAR(255)',
			'alter table ai_budget add column uuid VARCHAR(255)',
			'alter table ai_budget add column ost VARCHAR(255)'
		) { eval { &subs::db_query($sql) } }
		$ai_ledger_ready = 1;
	}
	&ai_house_publish();
}

# The machines that can take AI work: those that published a model and were seen
# in the last ten minutes, plus this machine (so a lone or not-yet-synced machine
# is never left with nobody). Sorted, so every machine ranks the same house.
sub ai_house_members {
	my $me = &ai_house_me();
	my $now = &subs::rightNow();
	my %member;
	$member{$me} = 1 if length $me && &ai_house_have_model();
	my $rows = eval { &subs::db_select('ai_house')->hashes } || [];
	foreach my $r ( @{$rows} ) {
		next unless $r->{'machine'} && $r->{'has_model'};
		next unless ($r->{'seen'} + 0) > ($now - 600000);
		$member{ $r->{'machine'} } = 1;
	}
	$member{$me} = 1 if length $me && !%member;   # alone: this machine is the house
	return sort keys %member;
}

sub ai_job_rank {
	my ($job, $member) = @_;
	my $h = 5381;
	foreach my $c ( split //, ($job // '') . '|' . ($member // '') ) { $h = ( ($h * 33) + ord($c) ) % 2147483647; }
	return $h;
}

# The machine that runs $job now. The present house - the machines whose model
# heartbeat is fresh - is ranked by the job's own order, and if nobody has run
# the job within $ttl the highest-ranked member takes it. Because the house holds
# only machines seen recently, a home that goes quiet drops out and the job falls
# to the next machine (the failover); a job already run within the ttl is left
# alone by everyone, so a machine that runs it and then goes quiet does not cause
# a second run.
sub ai_job_runner {
	my ($job, $ttl) = @_;
	my @house = &ai_house_members();
	return &ai_house_me() unless @house;
	$ttl = 6 * 3600 * 1000 unless $ttl && $ttl > 0;
	my $now = &subs::rightNow();
	my $rows = eval { &subs::db_select('ai_jobs', undef, { job => $job })->hashes } || [];
	foreach my $r ( @{$rows} ) {
		my $at = ($r->{'at'} || 0) + 0;
		return undef if $at && ($now - $at) <= $ttl;   # someone ran it: covered
	}
	my @ranked = sort { &ai_job_rank($job, $a) <=> &ai_job_rank($job, $b) } @house;
	return $ranked[0];
}

# May this machine run $job? Only when it is the job's runner. The ledger row in
# ai_jobs is the note of who ran what and when (the review list, and the cover
# that keeps the rest of the house off).
sub ai_job_may_run {
	my ($job, $ttl) = @_;
	return 1 unless length($job // '');
	my $runner = &ai_job_runner($job, $ttl);
	return 0 unless defined $runner;
	return ($runner eq &ai_house_me()) ? 1 : 0;
}

sub ai_job_note {
	my ($job) = @_;
	return unless length($job // '');
	my $now = &subs::rightNow();
	eval { &subs::db_delete('ai_jobs', { job => $job }) };
	eval { &subs::db_insert('ai_jobs', { job => $job, owner => &ai_house_me(), at => $now, state => 'ran', server_time => $now }) };
}

# the shared purse: what the whole house has spent today
sub ai_house_budget_spent {
	my $row = eval { &subs::db_query('select sum(tokens) as total from ai_budget where day = ?', &ai_house_today())->hashes->[0] };
	return ($row && defined $row->{'total'}) ? ($row->{'total'} + 0) : 0;
}

sub ai_house_budget_add {
	my ($n) = @_;
	return unless $n;
	my $me = &ai_house_me() || 'me';
	my $day = &ai_house_today();
	# one row per machine per day, so two machines' writes never clobber each other
	# and the sync just adds them up
	my $row = eval { &subs::db_select('ai_budget', undef, { machine => $me, day => $day })->hashes->[0] };
	my $total = (($row && $row->{'tokens'}) ? $row->{'tokens'} : 0) + $n;
	&subs::db_delete('ai_budget', { machine => $me, day => $day });
	&subs::db_insert('ai_budget', { machine => $me, day => $day, tokens => $total, server_time => &subs::rightNow() });
	return $total;
}

# The house at a glance for Configure → Sys: every machine that has published
# itself (does it hold a model, when it was last seen) with its spend today, and
# the day's house total against the shared ceiling. Read-only, straight from the
# synced ledger tables, so every machine shows the same picture.
sub ai_house_report {
	my $now = &subs::rightNow();
	my $day = &ai_house_today();
	my %spend;
	my $brows = eval { &subs::db_query('select machine, sum(tokens) as tokens from ai_budget where day = ? group by machine', $day)->hashes } || [];
	foreach my $b ( @{$brows} ) { $spend{ $b->{'machine'} // '' } = ($b->{'tokens'} || 0) + 0; }
	my $me = &ai_house_me();
	my %seen;
	my @rows;
	my $hrows = eval { &subs::db_select('ai_house')->hashes } || [];
	foreach my $r ( @{$hrows} ) {
		my $m = $r->{'machine'} // '';
		next unless length $m;
		$seen{$m} = 1;
		push @rows, {
			machine   => $m,
			self      => ($m eq $me) ? 1 : 0,
			has_model => ($r->{'has_model'} ? 1 : 0),
			seen      => ($r->{'seen'} || 0) + 0,
			online    => ((($r->{'seen'} || 0) + 0) > ($now - 600000)) ? 1 : 0,
			tokens    => $spend{$m} || 0,
		};
	}
	# this machine itself, even before anything has synced back to it
	if (length $me && !$seen{$me}) {
		push @rows, { machine => $me, self => 1, has_model => &ai_house_have_model(), seen => $now, online => 1, tokens => $spend{$me} || 0 };
		$seen{$me} = 1;
	}
	# spend from a machine whose ai_house row is gone (stale, but it did spend)
	foreach my $m ( keys %spend ) {
		next if $seen{$m} || !length $m;
		push @rows, { machine => $m, self => 0, has_model => 0, seen => 0, online => 0, tokens => $spend{$m} };
	}
	@rows = sort {
		($b->{'online'} <=> $a->{'online'})
			|| (($b->{'tokens'} || 0) <=> ($a->{'tokens'} || 0))
			|| ($a->{'machine'} cmp $b->{'machine'})
	} @rows;
	my $budget = &subs::setting_grabber({ app => 'mail', setting => 'error_watch_budget' });
	$budget = (defined $budget && $budget =~ /^\d+$/) ? ($budget + 0) : 1000000;
	return {
		day     => $day,
		rows    => \@rows,
		spent   => &ai_house_budget_spent(),
		budget  => $budget,
		members => scalar( grep { $_->{'has_model'} && $_->{'online'} } @rows ),
		machine => $me,
	};
}

# The money left on each provider account, where the provider will say. There is
# no common balance API: OpenRouter publishes its credits and DeepSeek its account
# balance, and the rest (OpenAI, Anthropic, Google, xAI, Mistral, Groq,
# Cloudflare) have none, so they read "—". The read itself is done off the page
# by President.pl's ai balance loop; this only ever reads the cached result, so a
# page load never waits on a provider.
sub ai_balance_report {
	my $cache = &subs::cache_get({ app => '__president', context => 'ai_balance' });
	return (ref $cache eq 'HASH' && $cache->{'rows'}) ? $cache : { at => 0, rows => [] };
}

sub ai_balance_refresh {
	my @key_settings = &subs::ai_key_settings();
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ @key_settings ] });
	my $suds = &subs::suds_grabber();
	my $secret = sub {
		my $v = shift;
		return '' unless defined $v && length $v;
		my $d = eval { &subs::note_decrypter($suds, $v) };
		return ($d && length $d) ? $d : $v;
	};
	# short timeouts: a balance read must never become a stall, and it is only a
	# convenience on a settings page
	my $ua = Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 8, request_timeout => 12);
	my %money;
	# OpenRouter: granted credits less what has been used
	{
		my $key = $secret->($settings->{'openrouter_key'});
		my $row = { available => undef, currency => 'USD', note => 'no key' };
		if (length $key) {
			my $tx = eval { $ua->get('https://openrouter.ai/api/v1/credits' => { 'Authorization' => "Bearer $key" }) };
			my $d = ($tx && !$tx->error && $tx->res->is_success) ? eval { decode_json($tx->res->body) } : undef;
			if ($d && ref $d->{'data'} eq 'HASH' && defined $d->{'data'}->{'total_credits'}) {
				$row = { available => (($d->{'data'}->{'total_credits'} || 0) - ($d->{'data'}->{'total_usage'} || 0)), currency => 'USD' };
			}
			else { $row = { available => undef, currency => 'USD', note => 'could not read credits' }; }
		}
		$money{'openrouter'} = $row;
	}
	# DeepSeek: the account balance
	{
		my $key = $secret->($settings->{'deepseek_key'});
		my $row = { available => undef, currency => 'USD', note => 'no key' };
		if (length $key) {
			my $tx = eval { $ua->get('https://api.deepseek.com/user/balance' => { 'Authorization' => "Bearer $key" }) };
			my $d = ($tx && !$tx->error && $tx->res->is_success) ? eval { decode_json($tx->res->body) } : undef;
			my $info = ($d && ref $d->{'balance_infos'} eq 'ARRAY') ? $d->{'balance_infos'}->[0] : undef;
			if ($info && defined $info->{'total_balance'}) {
				$row = { available => ($info->{'total_balance'} + 0), currency => ($info->{'currency'} || 'USD') };
			}
			else { $row = { available => undef, currency => 'USD', note => 'could not read balance' }; }
		}
		$money{'deepseek'} = $row;
	}
	# every provider, in the panel's own order, with a balance where there is one
	my @rows;
	foreach my $p ( @{ &subs::ai_providers() } ) {
		my $m = $money{ $p->{'id'} };
		push @rows, {
			provider  => $p->{'id'},
			label     => $p->{'label'},
			available => $m ? $m->{'available'} : undef,
			currency  => $m ? $m->{'currency'} : undef,
			note      => $m ? $m->{'note'} : 'no balance API',
		};
	}
	my $report = { at => &subs::rightNow(), rows => \@rows };
	&subs::cache_set({ app => '__president', context => 'ai_balance', warranty => '-1d' }, $report);
	return $report;
}

# Auto-approve, kept on a leash: at most 8 auto-applies a day (each one is a
# commit and a push; a bad day must not become a hundred). Past that the
# proposals simply wait for a person, as they always did.
sub watch_auto_allowed {
	my $row = &subs::cache_get({ app => '__president', context => 'watch_auto', subcontext => &watch_tokens_day() });
	return ((ref $row eq 'HASH' ? ($row->{'count'} || 0) : 0) < 8) ? 1 : 0;
}

sub watch_auto_count {
	my $row = &subs::cache_get({ app => '__president', context => 'watch_auto', subcontext => &watch_tokens_day() }) || {};
	&subs::cache_set(
		{ app => '__president', context => 'watch_auto', subcontext => &watch_tokens_day(), warranty => '-2d' },
		{ count => ($row->{'count'} || 0) + 1 }
	);
}

# An auto-applied fix writes whole files; if any of them has uncommitted work in
# the tree, writing would swallow it, so auto-approve stands down and leaves the
# proposal for a person (the log says why).
sub auto_apply_clean {
	my ($row) = @_;
	my $files = eval { decode_json $row->{'files'} } || {};
	my @names = sort grep { &error_watch_path($_) } keys %{$files};
	return 0 unless @names;
	my $repo = &error_watch_repo();
	my @q = map { '"' . $_ . '"' } @names;
	my $dirty = `cd "$repo" && git status --porcelain -- @q 2>&1`;
	return 0 if defined $dirty && $dirty =~ /\S/;
	return 1;
}

# Apply one staged fix: write its files, check the Perl, then the finishing
# routine - bump, commit only what was written (plus VERSION), push. A failure
# at the check puts every file back and nothing is committed. Both the panel's
# Apply and the watch's auto-approve come through here.
sub staged_fix_apply {
	my ($uuid) = @_;
	my $row = &subs::db_select('staged_fixes', undef, { uuid => $uuid })->hash;
	return { error => 'no such caught error' } unless $row;
	return { error => 'nothing is staged on that row yet' } unless (($row->{'status'} // '') eq 'proposed');
	my $files = eval { decode_json $row->{'files'} } || {};
	my @names = sort keys %{$files};
	return { error => 'that proposal stages no files' } unless @names;
	my $repo = &error_watch_repo();
	my (%backup, %touched);
	foreach my $rel ( @names ) {
		my $abs = &error_watch_path($rel);
		return { error => 'refused: ' . $rel . ' is outside the repo' } unless $abs;
		$backup{$abs} = -f $abs ? scalar read_file($abs) : undef;
		my $content = $files->{$rel};
		$content = '' unless defined $content;
		require File::Basename;
		my $dir = File::Basename::dirname($abs);
		if (!-d $dir) { require File::Path; File::Path::make_path($dir); }
		eval { write_file($abs, $content) };
		if ($@) {
			foreach my $done ( keys %backup ) {
				if (defined $backup{$done}) { eval { write_file($done, $backup{$done}) }; }
				else { unlink $done; }
			}
			return { error => 'could not write ' . $rel };
		}
		$touched{$rel} = 1;
	}
	# the whole change must pass the verifier before it ships: Perl compiles,
	# JavaScript parses, templates compile, and no file was truncated - the checks
	# a person would run by hand, run for them. On failure every file goes back
	# and nothing is committed. (A proposal that reaches here has already been
	# checked once, as it was staged; this is the check on what is truly on disk.)
	my ($verify, $vcode) = ('', 0);
	my $filelist = join(' ', map { '"' . $_ . '"' } sort keys %touched);
	if ($filelist && -f "$repo/scripts/verify_change.pl") {
		$verify = `cd "$repo" && perl scripts/verify_change.pl $filelist 2>&1`;
		$vcode = $? >> 8;
	}
	if ($vcode != 0) {
		foreach my $abs ( keys %backup ) {
			if (defined $backup{$abs}) { eval { write_file($abs, $backup{$abs}) }; }
			else { unlink $abs; }
		}
		# the IDE panel renders checks as a list of { path, output }; keep that shape
		my (@entries, $cur);
		foreach my $line (split /\n/, ($verify // '')) {
			if ($line =~ /^FAIL\s+(\S+)/) { $cur = { path => $1, output => '' }; push @entries, $cur; }
			elsif ($cur && $line =~ /^\s+(\S.*)$/) { $cur->{'output'} .= ($cur->{'output'} ? '; ' : '') . $1; }
		}
		push @entries, { path => 'verifier', output => substr(($verify // ''), 0, 1000) } unless @entries;
		return { error => 'the change did not pass verification; nothing was applied', checks => \@entries };
	}
	# the finishing routine: bump, then commit only what was written (plus
	# VERSION - never someone else's work in progress), then push
	my $bump = `cd "$repo" && perl scripts/version_bump.pl 2>&1`;
	$bump = '' unless defined $bump;
	$bump =~ s/\s+$//;
	return { error => 'the version bump failed: ' . ($bump || 'no output'), written => [ sort keys %touched ] } unless $bump =~ /^\d+\.\d+\.\d+$/;
	my $version = eval { read_file("$repo/VERSION") } || '';
	$version =~ s/\s+$//;
	my $msg = $row->{'summary'} || $row->{'signature'} || 'error watch fix';
	$msg =~ s/["`\$\\]/ /g;
	$msg =~ s/\s+/ /g;
	$msg =~ s/^\s+|\s+$//g;
	my @add = map { '"' . $_ . '"' } sort keys %touched;
	push @add, '"VERSION"';
	my $commit = `cd "$repo" && git add -- @add 2>&1 && git commit -m "v$version - $msg" 2>&1`;
	$commit = '' unless defined $commit;
	$commit = substr($commit, 0, 1200);
	my $push = `cd "$repo" && git push 2>&1`;
	$push = '' unless defined $push;
	$push = substr($push, 0, 800);
	# the note is also the fixed list's record: when it shipped, and as what - the
	# review list under Configure's auto-heal tick reads it back
	&subs::db_update('staged_fixes', { status => 'applied', note => 'applied ' . &subs::rightNow() . ' as v' . $version }, { uuid => $uuid });
	return { applied => $uuid, version => $version, bump => $bump, commit => $commit, push => $push };
}

# Lines that are normal noise rather than errors. jawn() already suppresses the
# same ones from its own console, and the master prints the shutdown line on
# every restart.
my $error_watch_noise = qr/Permission denied|cannot open \/proc\/net|Cannot bind netlink|error watch:|President stopping on SIGINT; cleaning up|Broken pipe|UDTA parsing failed|source=model_show_cache|model recommendations refresh failed|Socket sender:|\{"event": "error", "message": "not connected"\}/;

sub error_watch_is_error {
	my $line = shift;
	$line = '' unless defined $line;
	return 0 if $line =~ $error_watch_noise;
	return 1 if $line =~ /\b(?:failed|failure|fatal|panic|abort(?:ed)?|died|denied|malformed|corrupt|not ok|couldn't|could not|can't|cannot|unable to|uninitialized|undefined|out of memory|segmentation|core dumped|database is locked|no such (?:file|table|column)|too many|refused|error)\b/i;
	return 0;
}

# One invariant name per distinct error: control codes, addresses and numbers
# (line numbers, pids, ports, counts) are blanked, so a flood of one fault
# collapses to a single staged row.
sub error_signature {
	my $text = shift;
	$text = '' unless defined $text;
	$text =~ s/\e\[[0-9;?]*[A-Za-z]//g;
	$text =~ s/\r//g;
	# a per-occurrence correlator ([GXJwplb_HcnT]) is not part of the fault: a
	# bracketed 8+ char token carrying an upper-case letter is blanked, so the
	# same fault logged twice does not stage twice
	$text =~ s/\[(?=[A-Za-z0-9_-]{8,}\])(?:[A-Za-z0-9_-]*[A-Z])[A-Za-z0-9_-]*\]/[ID]/g;
	$text =~ s/0x[0-9a-fA-F]+/0xADDR/g;
	$text =~ s/\b\d+\b/N/g;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return substr($text, 0, 300);
}

sub error_watch_read_new {
	my ($path, $source) = @_;
	return () unless defined $path && -f $path;
	unless ($error_watch_state_loaded) { &error_watch_state_load(); $error_watch_state_loaded = 1; }
	my $size = -s $path;
	unless (defined $error_watch_state{$source}) {
		# the pty log is truncated when the master starts, so read it whole;
		# manager.log is long-lived, so begin at its end - never replay history
		$error_watch_state{$source} = ($source eq 'log') ? $size : 0;
	}
	my $offset = $error_watch_state{$source};
	if (defined $size && $size < $offset) {
		# truncated out from under us: take the new file from its start
		$offset = $error_watch_state{$source} = 0;
		$error_watch_partial{$source} = '';
	}
	open(my $fh, '<', $path) or return ();
	seek($fh, $offset, 0) or do { close $fh; return (); };
	my $chunk = '';
	read($fh, $chunk, 262144);
	close $fh;
	return () unless defined $chunk && length $chunk;
	$error_watch_state{$source} = $offset + length $chunk;
	&error_watch_state_save();
	my $buffer = ($error_watch_partial{$source} // '') . $chunk;
	my @lines = split /\n/, $buffer, -1;
	$error_watch_partial{$source} = pop @lines;   # keep the unterminated tail
	return @lines;
}

# A Perl warning is two lines - the message, then " at ./file line N." - so a
# matched line swallows the source location that follows it before it is caught.
sub error_watch_catch {
	my @lines = @_;
	my (@caught, $pending);
	foreach my $line ( @lines ) {
		if (defined $pending && $line =~ /^\s*at\s+\S+\s+line\s+\d+\.?\s*$/) {
			$pending .= ' ' . $line;
			next;
		}
		if (defined $pending) { push @caught, $pending; undef $pending; }
		next unless &error_watch_is_error($line);
		$pending = $line;
	}
	push @caught, $pending if defined $pending;
	return @caught;
}

# Record one caught fault: a new row when its signature is new, a tally bump on
# the row already carrying it. Shared by the log watch and the browser's fatal
# JavaScript reporter (the signature may come from a shorter text than the
# sample - a JS fault's stack must not make every occurrence a new signature).
sub staged_fix_note {
	my ($params) = @_;
	my $sample = $params->{'sample'} // '';
	my $sig = &error_signature(defined $params->{'signature_text'} ? $params->{'signature_text'} : $sample);
	return {} unless length $sig;
	my $tally = (($params->{'tally'} || 1) + 0) || 1;
	my $existing = &subs::db_select('staged_fixes', [ 'uuid', 'tally' ], { signature => $sig })->hashes->[0];
	if ($existing) {
		&subs::db_update('staged_fixes', {
			tally => ($existing->{'tally'} || 0) + $tally,
			last_seen => &subs::rightNow(),
		}, { uuid => $existing->{'uuid'} });
		return { uuid => $existing->{'uuid'}, signature => $sig };
	}
	my $uuid = &subs::random_string_creator(40);
	&subs::db_insert('staged_fixes', {
		uuid => $uuid,
		source => ($params->{'source'} || 'pty'),
		signature => $sig,
		sample => substr($sample, 0, 2000),
		tally => $tally,
		status => 'new',
		last_seen => &subs::rightNow(),
	});
	return { uuid => $uuid, signature => $sig, status => 'new' };
}

# ---- the records watch ------------------------------------------------------
# The database's half of the self-heal, and the mirror of the error watch: a
# fixed, deterministic audit of the appointments table for the fault classes
# that corrupt the person's numbers. A stop press closes ONE session, but two
# bugs left rows ended by a press that was not their own (one stop applied to
# several open sessions) or wrote the same event once per machine. The judgement
# - which row to keep, what to repair - is the Coding agent's, staged and
# approved the way a code fix is (staged_records). Nothing here writes.
sub records_audit_prompt {
	return join "\n",
		'You are the Records Watch for JawnOS. You audit the appointments table for a fault class that has been corrupting the person\'s numbers, and you reconcile what you find. Nothing is written until a person approves it.',
		'',
		'A stop press closes ONE session. Two faults planted wrong rows: (1) one stop was applied to several open sessions, so an old session took its end from a press that was not its own; (2) the same event was written once per machine and the mesh kept every copy.',
		'',
		'You are handed a fixed report. For each entry:',
		'- SWEEP (rows share app + stop_timestamp): at most one row is the session that press closed. If the app sets a duration, the real row is the one whose |duration| is nearest it; otherwise the one whose start is nearest the press. Every other row was ended by a press that was not its own: repair each to its own end when the app sets a duration (start + duration), else tombstone it.',
		'- DUPES (identical app/type/timestamp/stop_timestamp): keep one, tombstone the rest.',
		'- ORPHAN (start/record, stop_seen null): do NOT stop it - it may be real and still running. Leave it unless the app sets a duration and it has run far past that, in which case repair it to start + duration.',
		'- IMPOSSIBLE (a stop before its own start): repair to a sane end or tombstone.',
		'- WRONG-END (an older session whose span contains a newer session\'s start of the same app): the older row was ended by a press that belonged to the newer one, so it ran on. Repair it to its own start + the app\'s length when the app sets one; leave it alone when it has no length or the person says it is real.',
		'',
		'Rules that must not be broken:',
		'- Do NOT judge by duration length alone: home is legitimately a full day, a walk an hour. Compare against the app\'s own history and its configured duration, never a fixed threshold.',
		'- Do NOT trust one machine over another. The correct end is whichever press actually stopped that session; where machines disagree, prefer the value that matches the app\'s configured duration.',
		'- Leave alone anything started in the last ten minutes, anything a person corrected by hand (a note, an edited time), and any row that is still running.',
		'- Writes ride the app\'s own routes: delete_app tombstones a duplicate so the whole mesh agrees, and the appointment\'s own stop path repairs an end.',
		'',
		'Answer with a JSON list of proposed actions, one per row: {"action":"keep"|"tombstone"|"repair","app":..,"uuid":..,"stop_timestamp":..,"duration":..,"why":".."}. Say which row you keep per group and why, and list what you leave alone and why. Write nothing else.';
}

# An app the person has said is genuinely, surprisingly long-lived (a home stay, an
# eight-month ailment). Length alone can never tell a real session from a swept one,
# so the audit must be able to be told to leave an app alone entirely. Stored per
# machine as a JSON list of app names (mail/records_exempt).
sub records_exempt {
	my $raw = &subs::setting_grabber({ app => 'mail', setting => 'records_exempt' }) // '';
	my $saved = length($raw) ? eval { decode_json $raw } : undef;
	$saved = [] unless ref $saved eq 'ARRAY';
	my %apps;
	foreach my $a ( @{$saved} ) { $apps{$a} = 1 if defined $a && length $a; }
	return \%apps;
}

sub records_exempt_add {
	my ($app) = @_;
	return 0 unless defined $app && length $app;
	my $exempt = &records_exempt();
	$exempt->{$app} = 1;
	&subs::setting_setter({ app => 'mail', setting => 'records_exempt', value => encode_json([ sort keys %{$exempt} ]) });
	return 1;
}

sub records_audit {
	my ($window_ms) = @_;
	# 0 means all time: the sweep predates the fix by weeks, so the default window is
	# only a convenience for a quick look
	$window_ms = 172800000 unless defined $window_ms && $window_ms =~ /^[0-9]+$/;
	my $now = &rightNow();
	my $since = $window_ms > 0 ? $now - $window_ms : 0;
	# apps the person has marked as legitimately long: never reported
	my $exempt = &records_exempt();
	my $report = {
		generated_at => $now, window_ms => $window_ms, since => $since,
		sweep => [], wrong_end => [], dupes => [], orphans => [], impossible => [],
		apps_with_duration => {}, summary => {},
	};

	# the app's configured session length: the yardstick the audit measures against
	my %app_duration;
	foreach my $s ( @{ &db_query('select app, value from settings where setting = ?', 'duration')->hashes } ) {
		next unless defined $s->{'value'} && $s->{'value'} =~ /[0-9]/;
		my $d = abs &time_abbrev_translator($s->{'value'});
		$app_duration{ $s->{'app'} } = $d if $d;
	}
	$report->{'apps_with_duration'} = { %app_duration };

	# SWEEP - a stop press that closed more than one session
	my $groups = &db_query('select app, stop_timestamp, count(*) c from appointments where stop_timestamp is not null and stop_timestamp != ? and server_time > ? group by app, stop_timestamp having c > 1 order by stop_timestamp desc', '', $since)->hashes;
	foreach my $g ( @{$groups} ) {
		next if $exempt->{ $g->{'app'} };
		my $rows = &db_query('select rowid, uuid, type, timestamp, stop_timestamp, duration, server_time from appointments where app = ? and stop_timestamp = ? order by timestamp asc', $g->{'app'}, $g->{'stop_timestamp'})->hashes;
		# rows that share a start as well are the same event written twice, not a
		# sweep: the DUPES pass owns those, so a repair here can never fight it
		my %starts;
		$starts{ $_->{'timestamp'} }++ for @{$rows};
		next if scalar(keys %starts) < 2;
		my $d = $app_duration{ $g->{'app'} };
		# the session this press belongs to: nearest the app duration, else nearest the press
		my $keep = 0;
		for (my $i = 0; $i < scalar @{$rows}; $i++) {
			my $dur = abs(0 + ($rows->[$i]->{'duration'} || 0));
			my $score = defined $d ? abs($dur - $d) : abs(0 + $rows->[$i]->{'timestamp'} - 0 + $g->{'stop_timestamp'});
			my $best = defined $d ? abs(abs(0 + ($rows->[$keep]->{'duration'} || 0)) - $d) : abs(0 + $rows->[$keep]->{'timestamp'} - 0 + $g->{'stop_timestamp'});
			$keep = $i if $score < $best;
		}
		my @out;
		for (my $i = 0; $i < scalar @{$rows}; $i++) {
			my $r = $rows->[$i];
			my %o = ( rowid => $r->{'rowid'}, uuid => $r->{'uuid'}, type => $r->{'type'}, timestamp => $r->{'timestamp'}, stop_timestamp => $r->{'stop_timestamp'}, duration => $r->{'duration'} );
			if ($i == $keep) { $o{'suggested'} = 'keep'; $o{'why'} = defined $d ? 'ends nearest the app duration' : 'start nearest the press'; }
			elsif (defined $d) { $o{'suggested'} = 'repair'; $o{'why'} = 'a session of this app runs ' . $d . ' ms'; $o{'repair_stop_timestamp'} = (0 + $r->{'timestamp'}) + $d; }
			else { $o{'suggested'} = 'remove'; $o{'why'} = 'ended by a press that was not its own'; }
			push @out, \%o;
		}
		push @{$report->{'sweep'}}, { app => $g->{'app'}, stop_timestamp => $g->{'stop_timestamp'}, expected_ms => $d, rows => \@out };
	}

	# WRONG-END - an older session of an app left open while a NEWER session of the
	# same app had already begun, so the press that closed the older one was not its
	# own (the header the client stopped named the wrong session, and the older row
	# ran on to a later press). The overlap is the signature: the older span contains
	# the newer session's start, and the older one was still open at that tick. The
	# SWEEP pass owns the case where both closed together, so this is the one-per-press
	# shape it cannot see. Judged only against the app's own configured length - a real
	# appointment can be surprisingly long, so nothing is reported without a yardstick,
	# and a person still reviews every row (it is never bulk-applied).
	my $wrong = &db_query('select a.app, a.rowid, a.uuid, a.type, a.timestamp, a.stop_timestamp, a.duration
		from appointments a join appointments b on a.app = b.app
		where a.stop_timestamp is not null and a.server_time > ? and a.stop_timestamp <= ?
		  and b.timestamp > a.timestamp and b.timestamp < a.stop_timestamp
		  and (b.stop_timestamp is null or b.stop_timestamp > a.stop_timestamp)
		group by a.rowid order by a.stop_timestamp desc', $since, $now)->hashes;
	foreach my $r ( @{$wrong} ) {
		next if $exempt->{ $r->{'app'} };
		my $d = $app_duration{ $r->{'app'} };
		next unless $d;
		my $span = (0 + $r->{'stop_timestamp'}) - (0 + $r->{'timestamp'});
		next unless $span > 2 * $d;
		push @{$report->{'wrong_end'}}, {
			app => $r->{'app'}, rowid => $r->{'rowid'}, uuid => $r->{'uuid'}, type => $r->{'type'},
			timestamp => $r->{'timestamp'}, stop_timestamp => $r->{'stop_timestamp'}, duration => $r->{'duration'},
			expected_ms => $d, suggested => 'repair',
			why => 'ended by a press that belonged to a newer session of the app',
			repair_stop_timestamp => (0 + $r->{'timestamp'}) + $d,
		};
	}

	# DUPES - the same event written more than once
	my $dupes = &db_query('select app, type, timestamp, stop_timestamp, count(*) c, group_concat(rowid) rowids from appointments where server_time > ? group by app, type, timestamp, stop_timestamp having c > 1 order by timestamp desc', $since)->hashes;
	foreach my $g ( @{$dupes} ) {
		next if $exempt->{ $g->{'app'} };
		my @ids = sort { $a <=> $b } split /,/, ($g->{'rowids'} || '');
		my $kept = shift @ids;
		push @{$report->{'dupes'}}, { app => $g->{'app'}, type => $g->{'type'}, timestamp => $g->{'timestamp'}, stop_timestamp => $g->{'stop_timestamp'}, keep_rowid => $kept, remove_rowids => \@ids };
	}

	# ORPHANS - an open session, flagged only when it has run far past the app's duration
	my $orphans = &db_query('select rowid, uuid, app, type, timestamp, server_time from appointments where type in (?,?) and stop_seen is null and timestamp <= ? order by timestamp asc', 'start', 'record', $now - 7200000)->hashes;
	foreach my $r ( @{$orphans} ) {
		next if $exempt->{ $r->{'app'} };
		my $age = $now - (0 + $r->{'timestamp'});
		my $d = $app_duration{ $r->{'app'} };
		my %o = ( %{$r}, age_ms => $age );
		if (defined $d && $age > $d * 2) { $o{'suggested'} = 'repair'; $o{'why'} = 'open far longer than the app duration'; $o{'repair_stop_timestamp'} = (0 + $r->{'timestamp'}) + $d; }
		else { $o{'suggested'} = 'left-alone'; $o{'why'} = 'still running'; }
		push @{$report->{'orphans'}}, \%o;
	}

	# IMPOSSIBLE - a stop before its own start
	my $imp = &db_query('select rowid, uuid, app, type, timestamp, stop_timestamp, duration from appointments where stop_timestamp is not null and cast(stop_timestamp as integer) < cast(timestamp as integer) and server_time > ?', $since)->hashes;
	$report->{'impossible'} = [ grep { !$exempt->{ $_->{'app'} } } @{$imp} ];

	my $extra = 0;
	foreach my $g ( @{$report->{'sweep'}} ) { $extra += scalar(grep { $_->{'suggested'} ne 'keep' } @{$g->{'rows'}}); }
	my $dupe_extra = 0;
	foreach my $g ( @{$report->{'dupes'}} ) { $dupe_extra += scalar @{$g->{'remove_rowids'}}; }
	$report->{'summary'} = {
		sweep_groups => scalar @{$report->{'sweep'}},
		sweep_spare_rows => $extra,
		wrong_end => scalar @{$report->{'wrong_end'}},
		dupe_groups => scalar @{$report->{'dupes'}},
		dupe_spare_rows => $dupe_extra,
		orphans => scalar @{$report->{'orphans'}},
		impossible => scalar @{$report->{'impossible'}},
	};
	return $report;
}

sub records_reconcile {
	my ($window_ms, $opts) = @_;
	$opts ||= {};
	my $apply = $opts->{'apply'} ? 1 : 0;
	my $report = &records_audit($window_ms);
	my $now = &rightNow();
	my @actions;

	# a helper: tombstone a row and drop it here, quietly. This is the bulk-admin
	# shape (as Alarm.pl writes appointments directly): Manager::delete_app also
	# pushes to every open window, which 800-odd rows must not do.
	my $remove = sub {
		my ($app, $uuid, $why) = @_;
		push @actions, { action => 'tombstone', app => $app, uuid => $uuid, why => $why };
		&records_tombstone($app, $uuid) if $apply;
	};

	# DUPLICATES - keep one of each, tombstone the rest
	foreach my $g ( @{ $report->{'dupes'} } ) {
		foreach my $rowid ( @{ $g->{'remove_rowids'} } ) {
			my $r = &db_query('select uuid, app from appointments where rowid = ?', $rowid)->hashes->[0];
			next unless $r && $r->{'uuid'};
			$remove->($r->{'app'}, $r->{'uuid'}, 'duplicate of row ' . $g->{'keep_rowid'});
		}
	}

	# SWEEP - the one press belongs to one row; the rest are repaired to the app's
	# own length or, when the app sets none, tombstoned
	foreach my $g ( @{ $report->{'sweep'} } ) {
		foreach my $r ( @{ $g->{'rows'} } ) {
			next if $r->{'suggested'} eq 'keep';
			if (($r->{'suggested'} // '') eq 'repair' && defined $r->{'repair_stop_timestamp'}) {
				my $stop = 0 + $r->{'repair_stop_timestamp'};
				my $dur = (0 + $r->{'timestamp'}) - $stop;
				push @actions, { action => 'repair', app => $g->{'app'}, uuid => $r->{'uuid'}, stop_timestamp => $stop, duration => $dur };
				&records_repair($g->{'app'}, $r->{'uuid'}, $r->{'timestamp'}, $stop) if $apply;
			}
			else {
				$remove->($g->{'app'}, $r->{'uuid'}, 'spare swept session');
			}
		}
	}

	return { applied => $apply, actions => scalar @actions, summary => $report->{'summary'}, list => \@actions };
}

# ---- the records watch: staging and apply --------------------------------
# The mirror of the error watch. A finding the fixed audit produces is staged as
# a row; a person reviews it and Applies, and the actions it carries are written
# through the same quiet paths the bulk pass uses. Machine-local (staged_records),
# so each machine repairs its own rows and the tombstones converge the mesh.

# drop one appointment row and tell the mesh (a tombstone, so no peer re-adds it).
# Quiet on purpose: Manager::delete_app also pushes to every open window, which a
# batch of hundreds must not do.
sub records_tombstone {
	my ($app, $uuid) = @_;
	return unless $app && $uuid;
	&tombstone_writer({ table => 'appointments', app => $app, uuid => $uuid, scope => 'single' });
	&db_delete('continent', { app => $app, uuid => $uuid });
	&db_query('delete from continent where app = ? and uuid like ?', $app, $uuid . '%');
	&db_delete('appointments', { uuid => $uuid, app => $app });
}

# set a session's real end (its own start + the app's length). A fresh server_time
# is what makes the repair win the peer merge.
sub records_repair {
	my ($app, $uuid, $start, $stop) = @_;
	return unless $app && $uuid && defined $stop;
	my $dur = (0 + $start) - (0 + $stop);
	&db_update('appointments', { stop_timestamp => $stop, duration => $dur, stop_seen => 'yes', type => 'stop', seen => 'yes', server_time => &rightNow() }, { uuid => $uuid, app => $app });
	return $dur;
}

# the table, created here too so the watch works from the first boot after an update
sub records_table_ready {
	my $table = &db_query('select name from pragma_table_info(?) where name = ?', 'staged_records', 'uuid')->hashes->[0];
	return 1 if $table;
	&db_query('create table if not exists staged_records (
		uuid VARCHAR(255) unique, server_time VARCHAR(255), ost VARCHAR(25), kind VARCHAR(25),
		app VARCHAR(500), signature VARCHAR(500), sample LONGTEXT, proposed LONGTEXT,
		status VARCHAR(25), model VARCHAR(255), note LONGTEXT, last_seen VARCHAR(255))');
	&db_query('create index if not exists idx1_staged_records on staged_records (signature)');
	&db_query('create index if not exists idx2_staged_records on staged_records (status)');
	return 1;
}

# stage one finding: an existing signature just bumps last_seen; a new one is inserted
sub records_stage {
	my ($f) = @_;
	return unless $f && $f->{'signature'};
	my $existing = &db_select('staged_records', ['uuid'], { signature => $f->{'signature'} })->hashes->[0];
	if ($existing) {
		&db_update('staged_records', { last_seen => &rightNow() }, { uuid => $existing->{'uuid'} });
		return $existing->{'uuid'};
	}
	my $uuid = &random_string_creator(40);
	&db_insert('staged_records', {
		uuid => $uuid,
		kind => $f->{'kind'},
		app => $f->{'app'},
		signature => $f->{'signature'},
		sample => $f->{'sample'},
		proposed => encode_json($f->{'proposed'}),
		status => 'proposed',
		last_seen => &rightNow(),
	});
	return $uuid;
}

# turn an audit report into staged findings
sub records_stage_scan {
	my ($window_ms) = @_;
	&records_table_ready();
	my $report = &records_audit($window_ms);
	my $staged = 0;
	foreach my $g ( @{$report->{'sweep'}} ) {
		my @acts;
		foreach my $r ( @{$g->{'rows'}} ) {
			next if $r->{'suggested'} eq 'keep';
			if (($r->{'suggested'} // '') eq 'repair' && defined $r->{'repair_stop_timestamp'}) {
				push @acts, { action => 'repair', uuid => $r->{'uuid'}, timestamp => $r->{'timestamp'}, stop_timestamp => $r->{'repair_stop_timestamp'}, why => $r->{'why'} };
			}
			else {
				push @acts, { action => 'tombstone', uuid => $r->{'uuid'}, why => $r->{'why'} };
			}
		}
		next unless scalar @acts;
		my @ctx = map { { uuid => $_->{'uuid'}, type => $_->{'type'}, timestamp => $_->{'timestamp'}, stop_timestamp => $_->{'stop_timestamp'}, duration => $_->{'duration'}, suggested => $_->{'suggested'} } } @{$g->{'rows'}};
		&records_stage({
			kind => 'sweep', app => $g->{'app'},
			signature => 'sweep:' . $g->{'app'} . ':' . $g->{'stop_timestamp'},
			sample => 'one press closed ' . scalar(@{$g->{'rows'}}) . ' sessions' . (defined $g->{'expected_ms'} ? ' (this app runs ' . $g->{'expected_ms'} . ' ms)' : ''),
			proposed => { app => $g->{'app'}, actions => \@acts, stop_timestamp => $g->{'stop_timestamp'}, expected_ms => $g->{'expected_ms'}, context => \@ctx },
		}); $staged++;
	}
	foreach my $g ( @{$report->{'dupes'}} ) {
		my @acts;
		foreach my $rowid ( @{$g->{'remove_rowids'}} ) {
			my $r = &db_query('select uuid from appointments where rowid = ?', $rowid)->hashes->[0];
			next unless $r && $r->{'uuid'};
			push @acts, { action => 'tombstone', uuid => $r->{'uuid'}, why => 'duplicate of row ' . $g->{'keep_rowid'} };
		}
		next unless scalar @acts;
		&records_stage({
			kind => 'dupe', app => $g->{'app'},
			signature => 'dupe:' . $g->{'app'} . ':' . $g->{'type'} . ':' . $g->{'timestamp'},
			sample => scalar(@acts) . ' duplicate row(s) of ' . $g->{'app'} . ' ' . $g->{'type'},
			proposed => { app => $g->{'app'}, actions => \@acts },
		}); $staged++;
	}
	foreach my $r ( @{$report->{'orphans'}} ) {
		next unless ($r->{'suggested'} // '') eq 'repair';
		&records_stage({
			kind => 'orphan', app => $r->{'app'},
			signature => 'orphan:' . $r->{'app'} . ':' . $r->{'timestamp'},
			sample => 'open ' . int($r->{'age_ms'} / 3600000) . 'h, far past the app length',
			proposed => { app => $r->{'app'}, actions => [ { action => 'repair', uuid => $r->{'uuid'}, timestamp => $r->{'timestamp'}, stop_timestamp => $r->{'repair_stop_timestamp'}, why => $r->{'why'} } ], context => [ { uuid => $r->{'uuid'}, type => $r->{'type'}, timestamp => $r->{'timestamp'}, duration => undef, age_ms => $r->{'age_ms'} } ] },
		}); $staged++;
	}
	foreach my $r ( @{$report->{'wrong_end'}} ) {
		&records_stage({
			kind => 'wrong_end', app => $r->{'app'},
			signature => 'wrong_end:' . $r->{'app'} . ':' . $r->{'timestamp'},
			sample => 'ended by a press meant for a newer session; ran ' . int(((0 + $r->{'stop_timestamp'}) - (0 + $r->{'timestamp'})) / 60000) . 'm, this app runs ' . int((0 + ($r->{'expected_ms'} || 0)) / 60000) . 'm',
			proposed => { app => $r->{'app'}, actions => [ { action => 'repair', uuid => $r->{'uuid'}, timestamp => $r->{'timestamp'}, stop_timestamp => $r->{'repair_stop_timestamp'}, why => $r->{'why'} } ], context => [ { uuid => $r->{'uuid'}, type => $r->{'type'}, timestamp => $r->{'timestamp'}, stop_timestamp => $r->{'stop_timestamp'}, duration => $r->{'duration'}, suggested => 'repair' } ] },
		}); $staged++;
	}
	return { staged => $staged, summary => $report->{'summary'} };
}

# Apply one staged row: carry out every action it holds, then mark it applied
sub records_fix_apply {
	my ($uuid) = @_;
	my $row = &db_select('staged_records', undef, { uuid => $uuid })->hash;
	return { error => 'no such finding' } unless $row;
	my $p = eval { decode_json $row->{'proposed'} } || {};
	my $app = $p->{'app'} || $row->{'app'};
	my @acts = @{ $p->{'actions'} || [] };
	return { error => 'that finding proposes nothing' } unless scalar @acts;
	my $done = 0;
	foreach my $a ( @acts ) {
		if (($a->{'action'} // '') eq 'tombstone' && $a->{'uuid'}) { &records_tombstone($app, $a->{'uuid'}); $done++; }
		elsif (($a->{'action'} // '') eq 'repair' && $a->{'uuid'} && defined $a->{'stop_timestamp'}) { &records_repair($app, $a->{'uuid'}, $a->{'timestamp'}, $a->{'stop_timestamp'}); $done++; }
	}
	&db_update('staged_records', { status => 'applied', note => 'applied ' . &rightNow() . ' (' . $done . ' row(s))' }, { uuid => $uuid });
	return { applied => $uuid, rows => $done };
}

# Put one staged finding to the Coding agent. The audit finds; the agent reads;
# the person decides. A real appointment can be surprisingly long (a home stay, an
# eight-month ailment) and a fixed rule can never know that, so the person can talk
# a finding through before pressing Apply - and the agent is free to answer "leave
# it alone". Nothing here writes.
sub records_ask {
	my ($uuid, $question, $history) = @_;
	my $row = &db_select('staged_records', undef, { uuid => $uuid })->hash;
	return 'I could not find that finding.' unless $row;
	my $model = &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant' })
		|| &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
	return 'Set a Coding model in Configure and I can read this finding with you.' unless $model;
	my $p = eval { decode_json($row->{'proposed'} // '') } || {};
	my $fmt = sub {
		my ($ms) = @_;
		return '(none)' unless defined $ms && $ms =~ /^[0-9-]+$/;
		my $t = localtime(($ms + 0) / 1000);
		return ref $t ? $t->strftime('%Y-%m-%d %H:%M') : $ms;
	};
	my @lines = (
		'Staged finding (' . ($row->{'kind'} // '?') . ') for the app "' . ($row->{'app'} // '?') . '"',
		'What the audit saw: ' . ($row->{'sample'} // ''),
	);
	if (defined $p->{'expected_ms'} && $p->{'expected_ms'} =~ /^[0-9.]+$/) {
		push @lines, 'This app\'s configured session length: ' . sprintf('%.1f', $p->{'expected_ms'} / 60000) . ' min';
	} else {
		push @lines, 'This app sets no session length of its own.';
	}
	my $context = $p->{'context'} || [];
	if (scalar @{$context}) {
		push @lines, 'The rows in question:';
		foreach my $c ( @{$context} ) {
			push @lines, '  - ' . substr($c->{'uuid'} // '?', 0, 8) . ' ' . ($c->{'type'} // '?')
				. ', start ' . $fmt->($c->{'timestamp'})
				. ', stop ' . $fmt->($c->{'stop_timestamp'})
				. (defined $c->{'duration'} && $c->{'duration'} =~ /^[0-9.-]+$/ ? ', ran ' . sprintf('%.1f', abs($c->{'duration'}) / 60000) . ' min' : '')
				. ' (audit: ' . ($c->{'suggested'} // '?') . ')';
		}
	}
	push @lines, 'The actions the audit proposes: ' . encode_json($p->{'actions'} || []);
	my $system = &records_audit_prompt()
		. "\n\n"
		. 'You are now looking at ONE staged finding and talking it through with the person who keeps the records. Answer as a careful colleague: what most likely happened, whether the proposed action is safe, and what you would do. Say plainly when the honest answer is "leave it alone - that one was real", and when long is normal for this app. Do not write anything; the person presses Apply.';
	my $user = join("\n", @lines);
	$user .= "\n\n" . $history if defined $history && length $history;
	$user .= "\nPERSON: " . (defined $question && length $question ? $question : 'What do you make of this?');
	my ($text, $err) = &subs::evaluation_model_call_with_fallback($model, &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant_fallback' }), $system, $user, &subs::ai_role_thinking('coding_assistant'));
	return $err && !$text ? ('I could not reach the model: ' . $err) : ($text || 'The model returned nothing readable.');
}

# ---- the records recovery: putting back what a repair shortened --------------
# A repair overwrites an end in place, so a genuinely long appointment that a
# sweep swept up can vanish from the live table with nothing left to compare to.
# The machine keeps hourly sealed snapshots, and the one taken before the repair
# still holds the old ends. These routines compare a snapshot to now and list the
# rows the repair shortened (or dropped), so a person - or the Coding agent - can
# put them back. Nothing is written by the scan; apply stamps a current
# server_time, so the recovered rows win the peer merge and reach every machine.

# the newest sealed snapshot, by the timestamp in its name
sub records_latest_backup {
	my $dir = &database_dir() . '/backups';
	my @files = grep { /jawnos_\d+\.enc$/ } glob("$dir/jawnos_*.enc");
	return undef unless scalar @files;
	@files = sort {
		my ($b1) = $b =~ /jawnos_(\d+)\.enc$/;
		my ($a1) = $a =~ /jawnos_(\d+)\.enc$/;
		($b1 || 0) <=> ($a1 || 0);
	} @files;
	return $files[0];
}

# take one now, with the app's own idiom (sqlite .backup, then openssl, then the
# splitter-and-standard appendage). Kept outside backups/ only as the plaintext,
# which is shredded; the sealed file is named jawnos_<ms>.enc so the tidy keeps it.
sub records_backup_now {
	require File::Temp;
	require File::Spec;
	my $dir = &database_dir() . '/backups';
	mkdir $dir unless -d $dir;
	my ($fh, $tmp) = File::Temp::tempfile('jawnos_recover_XXXXXX', SUFFIX => '.db', DIR => File::Spec->tmpdir, UNLINK => 0);
	return undef unless $fh && $tmp;
	close $fh;
	my $database = &database_path();
	my $secret = &suds_grabber();
	my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
	my $out = "$dir/jawnos_" . &rightNow() . '.enc';
	`sqlite3 "$database" ".backup '$tmp'"`;
	&openssl_file_crypt('e', $standard, $secret, $tmp, $out, 0, 1);
	my $appendage = $gb::universal_splitter . &encrypter($secret, $standard);
	if (open(my $af, '>>', $out)) { print $af $appendage . "\n"; close $af; }
	unlink $tmp;
	return undef unless -e $out && -s $out > 5000;
	return $out;
}

# the newest snapshot is younger than the window, or one is taken to make it so.
# The guard the person asked for: nothing is applied without a recent backup.
sub records_backup_ensure_fresh {
	my ($max_age_ms) = @_;
	$max_age_ms = 600000 unless defined $max_age_ms && $max_age_ms =~ /^[0-9]+$/;
	my $now = &rightNow();
	my $newest = &records_latest_backup();
	if ($newest) {
		my ($ms) = $newest =~ /jawnos_(\d+)\.enc$/;
		return { fresh => 1, path => $newest, age_ms => $now - $ms, made => 0 } if $ms && ($now - $ms) < $max_age_ms;
	}
	my $made = &records_backup_now();
	return { fresh => ($made ? 1 : 0), path => ($made || $newest), age_ms => 0, made => ($made ? 1 : 0) };
}

# unseal a snapshot to a scratch database outside backups/ (the tidy shreds
# anything there that is not jawnos*.enc). Returns the path, or undef.
sub records_backup_decrypt {
	my ($path) = @_;
	return undef unless $path && -e $path;
	require File::Temp;
	require File::Spec;
	my $tail = `tail -c 600 "$path"`;
	my @parts = split /\Q$gb::universal_splitter\E/, ($tail // '');
	return undef unless scalar @parts > 1;
	my $appendage = $parts[-1];
	$appendage =~ s/\s+\z//;
	my $secret = &suds_grabber();
	my $standard = &decrypter($secret, $appendage);
	$standard = 'aes-256-ctr' unless $standard && $standard =~ /^[a-z0-9-]+$/i;
	my ($fh, $tmp) = File::Temp::tempfile('jawnos_old_XXXXXX', SUFFIX => '.db', DIR => File::Spec->tmpdir, UNLINK => 0);
	return undef unless $fh && $tmp;
	close $fh;
	&openssl_file_crypt('d', $standard, $secret, $path, $tmp, 1, 1);
	return undef unless -e $tmp && -s $tmp > 5000;
	return $tmp;
}

# how long a row ran: its own stop when it has one, else as far as the reference
# time (the snapshot's moment for an old row, now for a live one)
sub records_span_ms {
	my ($row, $ref) = @_;
	my $start = 0 + ($row->{'timestamp'} || 0);
	return undef unless $start;
	my $stop = $row->{'stop_timestamp'};
	my $end = (defined $stop && $stop =~ /^[0-9]+$/ && $stop) ? (0 + $stop) : (0 + $ref);
	return abs($end - $start);
}

# Compare a snapshot to the live table and list the rows the live table made
# shorter (or dropped). A row is a candidate when its app is one the person named
# or when it ran longer than older_than_ms in the snapshot - the two signals a
# fixed rule cannot supply on its own.
sub records_recover_scan {
	my ($opts) = @_;
	$opts ||= {};
	my $min_ms = (defined $opts->{'older_than_ms'} && $opts->{'older_than_ms'} =~ /^[0-9]+$/) ? $opts->{'older_than_ms'} : 86400000;
	my @apps = @{ $opts->{'apps'} || [ 'home', 'alone', 'urbaniak', 'eczema', 'snow', 'winter', 'autumn' ] };
	my $backup = $opts->{'backup'} || &records_latest_backup();
	my $result = { backup => $backup, older_than_ms => $min_ms, apps => [ @apps ], candidates => [], summary => {}, error => '' };
	unless ($backup && -e $backup) { $result->{'error'} = 'there is no snapshot to compare against'; return $result; }
	my ($snap_ms) = $backup =~ /jawnos_(\d+)\.enc$/;
	$snap_ms = (stat($backup))[9] * 1000 unless $snap_ms;
	$result->{'snapshot_time'} = $snap_ms;
	my $old_db = &records_backup_decrypt($backup);
	unless ($old_db) { $result->{'error'} = 'could not unseal the snapshot (key or format)'; return $result; }
	my $rows = eval { Mojo::SQLite->new('sqlite:' . $old_db)->db->query('select * from appointments')->hashes } || [];
	$result->{'summary'}{'old_rows'} = scalar @{$rows};
	# the app's own session length: the yardstick that says whether a shorter live
	# value is a repair (live ~ duration) or a loss
	my %dur;
	foreach my $s ( @{ &db_query('select app, value from settings where setting = ?', 'duration')->hashes } ) {
		next unless defined $s->{'value'} && $s->{'value'} =~ /[0-9]/;
		my $d = abs &time_abbrev_translator($s->{'value'});
		$dur{ $s->{'app'} } = $d if $d;
	}
	my $matches = sub {
		my ($app) = @_;
		return 0 unless defined $app && length $app;
		foreach my $want ( @apps ) {
			my $w = $want; $w =~ s/\*//g;
			return 1 if length $w && index(lc($app), lc($w)) >= 0;
		}
		return 0;
	};
	my $now = &rightNow();
	foreach my $r ( @{$rows} ) {
		next unless $r->{'uuid'};
		my $old_ended = (defined $r->{'stop_timestamp'} && $r->{'stop_timestamp'} =~ /^[0-9]+$/ && $r->{'stop_timestamp'} > 0) ? 1 : 0;
		my $old_span = &records_span_ms($r, $snap_ms);
		next unless defined $old_span;
		my $named = $matches->($r->{'app'});
		next unless $named || $old_span > $min_ms;
		my $live = &subs::db_select('appointments', undef, { uuid => $r->{'uuid'} })->hash;
		# only an end that was written can be lost. An open row's span is just the
		# clock, so a pair where neither side is ended is never a candidate - without
		# this, every far-future row reads as "shortened" as the clock advances
		if (!$live) {
			next unless $old_ended;
			push @{$result->{'candidates'}}, {
				uuid => $r->{'uuid'}, app => $r->{'app'}, type => $r->{'type'},
				start => $r->{'timestamp'}, old_stop => $r->{'stop_timestamp'}, old_duration => $r->{'duration'},
				old_span_ms => $old_span, live_stop => undef, live_span_ms => undef,
				app_duration => $dur{ $r->{'app'} },
				status => 'missing', named => $named, action => 'reinstate', old_row => $r,
			};
			next;
		}
		my $live_ended = (defined $live->{'stop_timestamp'} && $live->{'stop_timestamp'} =~ /^[0-9]+$/ && $live->{'stop_timestamp'} > 0) ? 1 : 0;
		next unless $old_ended || $live_ended;
		my $live_span = &records_span_ms($live, $now);
		next unless !defined $live_span || $live_span < $old_span;
		push @{$result->{'candidates'}}, {
			uuid => $r->{'uuid'}, app => $r->{'app'}, type => $r->{'type'},
			start => $r->{'timestamp'}, old_stop => $r->{'stop_timestamp'}, old_duration => $r->{'duration'},
			old_span_ms => $old_span, live_stop => $live->{'stop_timestamp'},
			live_span_ms => $live_span, app_duration => $dur{ $r->{'app'} },
			status => 'shortened', named => $named, action => 'restore',
			old_row => $r,
		};
	}
	@{$result->{'candidates'}} = sort { ($b->{'old_span_ms'} || 0) <=> ($a->{'old_span_ms'} || 0) } @{$result->{'candidates'}};
	$result->{'summary'}{'candidates'} = scalar @{$result->{'candidates'}};
	$result->{'summary'}{'shortened'} = scalar grep { $_->{'status'} eq 'shortened' } @{$result->{'candidates'}};
	$result->{'summary'}{'missing'} = scalar grep { $_->{'status'} eq 'missing' } @{$result->{'candidates'}};
	unlink $old_db;
	return $result;
}

# Write the scan's candidates back: the old row's ended-ness onto the live row, or
# the whole old row when it was dropped. server_time is now, so every machine takes
# the recovered version on its next sync. The recovered apps are then left alone by
# the audit (they are, by definition, the ones that legitimately run long), so a
# sweep does not sweep them up a second time.
sub records_recover_apply {
	my ($scan, $opts) = @_;
	$scan ||= {};
	$opts ||= {};
	# A shorter live value is usually the correct repair (an app that runs three
	# minutes was ended at three minutes), so only the apps the person named are put
	# back unless "any" is asked for. A blanket restore would undo good fixes.
	my $any = $opts->{'any'} ? 1 : 0;
	my @cands = @{ $scan->{'candidates'} || [] };
	my $now = &rightNow();
	my ($restored, $reinstated, $failed, $skipped) = (0, 0, 0, 0);
	my @apps;
	foreach my $c ( @cands ) {
		if (!$any && !$c->{'named'}) { $skipped++; next; }
		my $old = $c->{'old_row'};
		if (!$old || !$old->{'uuid'}) { $skipped++; next; }
		my $ok = eval {
			my $live = &subs::db_select('appointments', undef, { uuid => $old->{'uuid'} })->hash;
			if ($live) {
				&db_update('appointments', {
					stop_timestamp => $old->{'stop_timestamp'},
					stop_seen => $old->{'stop_seen'},
					duration => $old->{'duration'},
					type => $old->{'type'},
					seen => $old->{'seen'},
					server_time => $now,
				}, { uuid => $old->{'uuid'} });
			}
			else {
				my %copy = %{$old};
				delete $copy{$_} for qw(rowid id);
				$copy{'server_time'} = $now;
				&db_insert('appointments', \%copy);
			}
			1;
		};
		if ($ok) {
			if ($c->{'status'} eq 'missing') { $reinstated++; } else { $restored++; }
			push @apps, $c->{'app'} if $c->{'app'};
		}
		else { $failed++; }
	}
	foreach my $a ( @apps ) { &records_exempt_add($a); }
	return { restored => $restored, reinstated => $reinstated, failed => $failed, skipped => $skipped, exempted => [ sort keys %{ &records_exempt() } ] };
}

# One pass of the watch: stage what the audit finds, and - when Apply automatically
# is ticked - write the oldest exact-duplicate finding. A sweep or an orphan waits
# for a person (a genuinely long appointment must never be repaired on its own).
# Off until Configure -> Plat ticks Records.
sub records_watch_tick {
	%setting_memo = ();
	return unless ((&subs::setting_grabber({ app => 'mail', setting => 'records_watch' }) // '') eq 'on');
	my $hours = &subs::setting_grabber({ app => 'mail', setting => 'records_watch_window' });
	my $window_ms = (defined $hours && $hours =~ /^[0-9]+$/) ? $hours * 3600000 : 172800000;
	my $scan = eval { &records_stage_scan($window_ms) } || { error => ($@ || 'scan failed') };
	$log->info('records watch: staged pass, ' . ($scan->{'staged'} // 0) . ' finding(s)') if defined $log && !$scan->{'error'};
	my $auto = ((&subs::setting_grabber({ app => 'mail', setting => 'records_watch_auto' }) // '') eq 'on');
	return unless $auto && &watch_auto_allowed();
	# Automatic apply is for the provably-safe class only: two rows that are the
	# same event written twice. A sweep or an orphan is a judgement call - a real
	# appointment can be surprisingly long - so those always wait for a person,
	# who can put the finding to the Coding agent first (records_ask).
	my $pending = &subs::db_query('select * from staged_records where status = ? and kind = ? order by ost asc limit 1', 'proposed', 'dupe')->hashes->[0];
	if ($pending) {
		my $applied = eval { &records_fix_apply($pending->{'uuid'}) } || { error => ($@ || 'no result') };
		&watch_auto_count();
		$log->info('records watch: auto-applied "' . substr($pending->{'signature'} || '?', 0, 60) . '": ' . ($applied->{'error'} // ($applied->{'rows'} . ' row(s)'))) if defined $log;
	}
}

# One pass: catch what is new, record it, and hand the oldest waiting error to
# the Coding agent to propose a fix for. Called from President's schedule.
sub error_watch_tick {
	# settings may have changed since this long-lived fork last read them (the
	# setting memo lasts the process), so each pass starts from a fresh read
	%setting_memo = ();
	# the house ledger heartbeat runs whatever the watches are set to: the ledger
	# gates evaluations and the shared budget as well as the watches, so this
	# machine must announce itself and its model even when both watches are off
	&ai_house_heartbeat();
	# either watch may want this pass: the error watch for its logs, the guide
	# watch for the Guide's conversations (its rows are proposed from here too,
	# so one proposer, one budget, one Apply)
	my $errors_on = ((&subs::setting_grabber({ app => 'mail', setting => 'error_watch' }) // '') eq 'on');
	my $guide_on = ((&subs::setting_grabber({ app => 'mail', setting => 'guide_watch' }) // '') eq 'on');
	return unless $errors_on || $guide_on;
	# the table normally arrives with the schema migration at a login; create it
	# here too (as run_backfills does for `backfills`) so the watch works from the
	# first boot after an update, before anyone has logged in
	my $table = &subs::db_query('select name from pragma_table_info(?) where name = ?', 'staged_fixes', 'uuid')->hashes->[0];
	unless ($table) {
		&subs::db_query('create table if not exists staged_fixes (
			uuid VARCHAR(255) unique,
			server_time VARCHAR(255),
			ost VARCHAR(25),
			source VARCHAR(25),
			signature VARCHAR(500),
			sample LONGTEXT,
			tally INT,
			status VARCHAR(25),
			model VARCHAR(255),
			summary LONGTEXT,
			files LONGTEXT,
			steps LONGTEXT,
			note LONGTEXT,
			last_seen VARCHAR(255)
		)');
		&subs::db_query('create index if not exists idx1_staged_fixes on staged_fixes (signature)');
		&subs::db_query('create index if not exists idx2_staged_fixes on staged_fixes (status)');
	}
	if ($errors_on) {
		my @caught;
		foreach my $source ( [ 'pty', &subs::home('~/pty.log') ], [ 'log', &subs::home('~/manager.log') ] ) {
			my ($kind, $path) = @{$source};
			push @caught, map { { source => $kind, line => $_ } } &error_watch_catch(&error_watch_read_new($path, $kind));
		}
		my %new;
		foreach my $c ( @caught ) {
			my $sig = &error_signature($c->{'line'});
			next unless length $sig;
			my $row = $new{$sig} //= { source => $c->{'source'}, sample => substr($c->{'line'}, 0, 2000), tally => 0 };
			$row->{'tally'}++;
		}
		foreach my $sig ( sort keys %new ) {
			my $row = $new{$sig};
			&staged_fix_note({ source => $row->{'source'}, sample => $row->{'sample'}, tally => $row->{'tally'} });
		}
	}
	# one proposal per tick keeps a model's cost and the tree's patience bounded
	my $model = &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant' })
		|| &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
	return unless $model;
	my $waiting = &subs::db_query('select * from staged_fixes where status = ? order by ost asc limit 1', 'new')->hashes->[0];
	if ($waiting) {
		# a propose run that dies inside the fork would otherwise vanish into the
		# outer eval; say so, or the row just sits 'new' forever with no trace
		my $ok = eval { &coding_propose_fix($waiting); 1 };
		$log->info('error watch: the proposal for "' . substr($waiting->{'signature'} || '?', 0, 60) . '" died: ' . $@) if !$ok && defined $log;
	}
	# the person's Confirm tick, for fixes: with auto-approve on, the oldest
	# waiting proposal is written, checked and shipped. A file with uncommitted
	# work stands down and is tried again on a later pass, the leash caps the
	# day, and the restart stays a word of its own.
	my $auto = ((&subs::setting_grabber({ app => 'mail', setting => 'error_watch_auto' }) // '') eq 'on');
	if ($auto && &watch_auto_allowed()) {
		my $pending = &subs::db_query('select * from staged_fixes where status = ? order by ost asc limit 1', 'proposed')->hashes->[0];
		if ($pending && &auto_apply_clean($pending)) {
			my $applied = eval { &staged_fix_apply($pending->{'uuid'}) } || { error => ($@ || 'no result') };
			&watch_auto_count();
			if (defined $log) {
				my $note = $applied->{'error'} // ('v' . ($applied->{'version'} // '?'));
				$note .= ' (push: ' . substr($applied->{'push'}, 0, 120) . ')' if $applied->{'push'} && $applied->{'push'} =~ /reject|fail|error/i;
				$log->info('error watch: auto-applied "' . substr($pending->{'signature'} || '?', 0, 60) . '": ' . $note);
			}
		}
		elsif ($pending && defined $log) {
			$log->info('error watch: auto-apply stood down for "' . substr($pending->{'signature'} || '?', 0, 60) . '" - a file it would write has uncommitted work');
		}
	}
	return 1;
}

# ---- the guide watch: the Coding agent's other ear --------------------------
# The Guide's conversations are saved as they go (guide_conversation_<name>,
# the rows the Agents list reads back), tool observations and all. This reads
# the ones that changed since last time and stages a turn that went nowhere -
# a thing not found, a command that could not run, a closing line that says so
# ("[object Object]" among them) - like an error, so the same propose/Apply
# loop adjusts the Guide's training: its rules in help.pl, its verbs in gb.pl.
# A signature dedupes repeats, and a small offset file keeps each conversation
# from being read twice. The first pass only takes a baseline, so switching the
# watch on does not stage the whole history at once.
sub guide_watch_state_file { return &subs::home('~/.president/guide_watch_seen'); }

sub guide_watch_state_load {
	my $file = &guide_watch_state_file();
	my $saved = -e $file ? eval { decode_json read_file($file) } : undef;
	return (ref $saved eq 'HASH') ? $saved : {};
}

# The words that read like the turn went nowhere. The Guide's phrasebook is
# small and its observations are its own client's strings, so this is the same
# text the person sees. "is hidden here" is left out on purpose: refusing a
# hidden thing is the rule working, not a miss.
sub guide_watch_trouble {
	my $text = shift;
	return 0 unless defined $text && length $text;
	return 1 if $text =~ /\[object /i;
	return 1 if $text =~ /could not|cannot|can'?t |unable to/i;
	return 1 if $text =~ /does not exist|doesn'?t exist|there is no |no such /i;
	return 1 if $text =~ /found nothing|nothing found|found 0 record/i;
	return 1 if $text =~ /did not run|no app named|not available here/i;
	return 0;
}

sub guide_watch_tick {
	%setting_memo = ();
	return unless ((&subs::setting_grabber({ app => 'mail', setting => 'guide_watch' }) // '') eq 'on');
	my $fresh = !-e &guide_watch_state_file();
	my $seen = &guide_watch_state_load();
	my $rows = &subs::db_query("select setting, device, value from settings where app = ? and setting like ?", '__president', 'guide_conversation_%')->hashes;
	return unless scalar @{$rows};
	my $noted = 0;
	my %live;
	foreach my $row ( @{$rows} ) {
		next unless length($row->{'setting'} // '');
		my $key = $row->{'setting'} . '|' . ($row->{'device'} // '');
		$live{$key} = 1;
		my $turns = eval { decode_json($row->{'value'} // '') } || [];
		next unless ref $turns eq 'ARRAY' && scalar @{$turns};
		my $from = $seen->{$key} || 0;
		# a thread that shrank was deleted and remade: read it from the top
		$from = 0 if $from > scalar @{$turns};
		$seen->{$key} = scalar @{$turns};
		next if $fresh || $from >= scalar @{$turns};
		# walk the new rows, carrying the turn as the client saved it: a user
		# line opens one, and it is judged where the Guide's own words end it -
		# a step that failed mid-turn and was recovered from is not staged
		my ($question, $trouble, @said);
		foreach my $t ( @{$turns}[$from .. $#{$turns}] ) {
			next unless ref $t eq 'HASH';
			my $role = $t->{'role'} || 'user';
			my $text = $t->{'content'} // '';
			if ($role eq 'user') { $question = $text; $trouble = undef; @said = (); next; }
			# the action line is not words to judge; the final wording is
			next if $role eq 'assistant' && $text =~ /^\s*\{/;
			push @said, (($role eq 'tool' ? '  observed: ' : '  said: ') . substr($text, 0, 300));
			shift @said while scalar @said > 12;
			$trouble //= $text if &guide_watch_trouble($text);
			next unless $role eq 'assistant' && defined $trouble;
			last if $noted >= 2;
			$noted++;
			my $sample = 'The person asked: ' . (defined $question && length $question ? $question : '(nothing said)') . "\n"
				. "The Guide's turn went:\n" . join("\n", @said) . "\n"
				. 'The line that reads like trouble: ' . substr($trouble, 0, 500);
			&staged_fix_note({
				source => 'guide',
				signature_text => 'guide: ' . ($question // '') . ' | ' . $trouble,
				sample => $sample,
			});
			$trouble = undef;
		}
	}
	# forget conversations that are gone
	foreach my $key ( keys %{$seen} ) { delete $seen->{$key} unless $live{$key}; }
	write_file(&guide_watch_state_file(), encode_json($seen));
	return 1;
}

# The propose loop runs in President, which never loads Manager.pl, so it carries
# its own copy of the repo-path guard (the same rules as Manager::coding_path).
# Nothing here can change the repo: every write is staged, so the guard only has
# to keep the agent's reading inside the tree.
sub error_watch_repo { return &subs::home('~/jawnos'); }

sub error_watch_rel {
	my $rel = shift;
	$rel = '' unless defined $rel;
	$rel =~ s{^\./+}{};
	$rel =~ s{^/+}{};
	return $rel;
}

sub error_watch_path {
	my $rel = &error_watch_rel(shift);
	return undef if $rel =~ /(^|\/)\.\.(\/|$)/;
	return undef if $rel =~ /[\x00-\x1f"`\\]/;
	return undef if $rel =~ m{^(?:\.git|\.president|releases|voices)(?:/|$)};
	return undef if $rel eq 'config.json';
	return &error_watch_repo() . ($rel eq '' ? '' : '/' . $rel);
}

# Check a staged file's text before it is even proposed, against a temp copy of
# the same basename (the tree is not written to here). The same verifier the
# Apply path runs, so the agent learns at once instead of staging a file that
# breaks the tree. Returns '' when it passes, else the reason.
sub coding_verify_text {
	my ($rel, $content) = @_;
	return '' unless defined $content && length $content;
	my $repo = &error_watch_repo();
	return '' unless -f "$repo/scripts/verify_change.pl";
	my $ext = ($rel =~ /\.([A-Za-z0-9]+)$/) ? lc $1 : '';
	return '' unless $ext =~ /^(?:pl|pm|t|js|mjs|cjs|ep|json)$/;
	require File::Temp;
	require File::Spec;
	my ($fh, $tmp) = File::Temp::tempfile('jawn_verify_XXXXXX', SUFFIX => '.' . $ext, DIR => File::Spec->tmpdir, UNLINK => 1);
	return '' unless $fh && $tmp;
	print $fh $content;
	close $fh;
	my $out = `cd "$repo" && perl scripts/verify_change.pl --allow-shrink "$tmp" 2>&1`;
	my $code = $? >> 8;
	$out = '' unless defined $out;
	unlink $tmp;
	return '' if $code == 0;
	my ($line) = grep { /FAIL|rror|shrank|Unexpected|syntax/ } split /\n/, $out;
	$line = $out unless defined $line;
	$line =~ s/^\s+|\s+$//g;
	return substr($line, 0, 300);
}

# The propose mode's tool loop: the same verbs' shape, but write only stages the
# whole file, so the agent can change nothing here.
sub coding_propose_execute {
	my ($action, $staged) = @_;
	my $a = $action->{'action'} // '';
	if ($a eq 'list') {
		my $abs = &error_watch_path($action->{'path'});
		return 'refused: that path is outside the repo or not allowed' unless $abs;
		return 'no such folder' unless -d $abs;
		opendir(my $dh, $abs) or return 'could not read that folder';
		my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
		closedir($dh);
		@names = map { -d "$abs/$_" ? "$_/" : $_ } @names;
		@names = @names[0 .. 199] if @names > 200;
		return join("\n", @names);
	}
	if ($a eq 'read') {
		my $abs = &error_watch_path($action->{'path'});
		return 'refused: that path is outside the repo or not allowed' unless $abs;
		return 'no such file' unless -f $abs;
		my $text = eval { read_file($abs) } // '';
		$text =~ s/\x00//g;
		if (length $text > 40000) { $text = substr($text, 0, 40000) . "\n... [trimmed]"; }
		return length($text) ? $text : '(empty file)';
	}
	if ($a eq 'write') {
		my $abs = &error_watch_path($action->{'path'});
		return 'refused: that path is outside the repo or not allowed' unless $abs;
		my $rel = &error_watch_rel($action->{'path'});
		my $content = $action->{'content'};
		$content = '' unless defined $content;
		return 'refused: a staged file is capped at 300000 bytes' if length($content) > 300000;
		return 'refused: at most 10 files in one proposal' if scalar(keys %{$staged}) >= 10 && !exists $staged->{$rel};
		$staged->{$rel} = $content;
		my $problem = &coding_verify_text($rel, $content);
		return 'staged ' . length($content) . ' bytes for ' . $rel . ' (not written; a person must apply it)'
			. ($problem ? ' - IT DOES NOT PASS THE VERIFIER: ' . $problem . '; write the file whole and correct it' : '');
	}
	if ($a eq 'run') {
		my $cmd = $action->{'command'} // '';
		$cmd =~ s/^\s+|\s+$//g;
		return 'refused: only perl -c, perl scripts/*, prove and read-only git are allowed here'
			unless $cmd =~ m{^(?:perl\s+-c\s+[\w./-]+|perl\s+scripts/[\w./-]+(?:\s+[^\n;|&]*)?|prove(?:\s+[^\n;|&]*)?|git\s+(?:status|diff|log|show|rev-parse|branch|remote)(?:\s+[^\n;|&]*)?)$};
		my $repo = &error_watch_repo();
		my $out = `cd "$repo" && $cmd 2>&1`;
		$out = '' unless defined $out;
		if (length $out > 8000) { $out = substr($out, 0, 8000) . "\n... [trimmed]"; }
		return $out =~ /\S/ ? $out : '(no output)';
	}
	if ($a eq 'say' || $a eq 'done') {
		return $action->{'text'} // '';
	}
	return 'unknown action: ' . $a;
}

our $coding_protocols_cache;
our $coding_protocols_mtime;

# The tracked protocol text the manager-side agent also follows (baked from the
# gitignored AGENTS.md into docs/coding_agent_protocols.md), so the watcher's
# proposals obey the same rules. Cached by mtime.
sub coding_protocols_text {
	my $repo = &error_watch_repo();
	my $path = -f "$repo/docs/coding_agent_protocols.md" ? "$repo/docs/coding_agent_protocols.md"
		: (-f "$repo/AGENTS.md" ? "$repo/AGENTS.md" : '');
	return '' unless length $path;
	my $mtime = (stat($path))[9] // 0;
	if (!defined $coding_protocols_cache || ($coding_protocols_mtime // 0) != $mtime) {
		my $text = eval { read_file($path) } // '';
		if (length $text > 20000) { $text = substr($text, 0, 20000) . "\n... [trimmed]"; }
		$coding_protocols_cache = $text;
		$coding_protocols_mtime = $mtime;
	}
	return $coding_protocols_cache // '';
}

# One bounded propose run for a staged error: the model picks the next action,
# write stages the file, repeat until done or the step cap. The proposal lands
# on the row as whole files, never as a change to the tree.
sub coding_propose_fix {
	my $row = shift;
	return unless ref $row eq 'HASH' && $row->{'uuid'};
	my $model = &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant' })
		|| &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
	unless ($model) {
		&subs::db_update('staged_fixes', { note => 'no Coding model is set (Configure -> Plat)' }, { uuid => $row->{'uuid'} });
		return;
	}
	# One machine proposes each fix: a stable hash over the house picks the fix's
	# home and only that machine spends on it, so two machines never pay to propose
	# the same repair. The cost is bounded below by the house-wide purse.
	my $job = 'fix:' . ($row->{'source'} || 'log') . ':' . ($row->{'signature'} || $row->{'uuid'});
	unless (&ai_job_may_run($job, 7 * 24 * 3600 * 1000)) {
		&subs::db_update('staged_fixes', { note => 'the house ledger has another machine on this one' }, { uuid => $row->{'uuid'} });
		return 'another machine';
	}
	&ai_job_note($job);
	# The purse: a proposal costs a handful of calls. The day's ceiling (a
	# setting, in tokens) stops the watch before a runaway spend, and one run
	# stops at its own cap below.
	my $budget = &subs::setting_grabber({ app => 'mail', setting => 'error_watch_budget' });
	$budget = (defined $budget && $budget =~ /^\d+$/) ? ($budget + 0) : 1000000;   # unset: a million a day; 0: no cap
	my $spent_today = &watch_tokens_spent();
	if ($budget && $spent_today >= $budget) {
		&subs::db_update('staged_fixes', { note => "the day's token budget is spent ($spent_today/$budget)" }, { uuid => $row->{'uuid'} });
		$log->info('error watch: proposal skipped for "' . substr($row->{'signature'} || '?', 0, 80) . "\" - day's token budget is spent ($spent_today/$budget)") if defined $log;
		return 'over-budget';
	}
	my $ai_start = { calls => $ai_tokens->{'calls'}, in => $ai_tokens->{'in'}, out => $ai_tokens->{'out'} };
	# the coding agent's thinking effort, set in Configure -> Plat beside its model
	my $thinking = &subs::ai_role_thinking('coding_assistant');
	# a fallback model's stand-down notice must not speak from this fork
	local $say_quiet = 1;
	require &error_watch_repo() . '/help.pl';
	my $system = &help::coding_propose_prompt();
	my $protocols = &coding_protocols_text();
	$system .= "\n\nCodebase protocols (follow these):\n" . $protocols . "\n" if length $protocols;
	$system .= "\nRight now it is " . localtime(&subs::rightNow() / 1000)->strftime('%A, %B %d %Y, %I:%M%P') . '.';
	my $where = (($row->{'source'} || '') eq 'js')
		? 'A FATAL JAVASCRIPT ERROR WAS REPORTED BY A BROWSER IN THE JAWNOS INTERFACE:'
		: (($row->{'source'} || '') eq 'guide')
		? "A GUIDE CONVERSATION DID NOT ACCOMPLISH WHAT THE PERSON ASKED. The transcript follows; adjust the Guide's training so this would land next time. Its rules live in help.pl (actions_prompt), its verbs and their descriptions in gb.pl (guide_tools), and the acting loop's resolvers in Manager.pl and public/js/manager/help.js. A rule or a verb's words usually beats code - change the code only when words cannot reach:"
		: 'AN ERROR WAS CAUGHT IN THE RUNNING SYSTEM (source: ' . ($row->{'source'} || '?') . ' log):';
	my @lines = (
		$where,
		'---',
		($row->{'sample'} || $row->{'signature'}),
		'---',
		'It has been seen ' . ($row->{'tally'} || 1) . ' time(s). Propose one small fix.',
		'Reply with the single next JSON action.'
	);
	my (%staged, @steps);
	my $final = '';
	my $tries = 0;
	while ($tries++ < 10) {
		my ($text, $err) = &subs::evaluation_model_call_with_fallback($model, &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant_fallback' }), $system, join("\n", @lines), $thinking);
		if ($err || !$text) {
			push @steps, { action => { action => 'error' }, observation => ($err || 'the model returned nothing') };
			$final = 'the model could not be reached: ' . ($err || 'no answer');
			last;
		}
		my $action = eval { decode_json $text };
		unless ($action && $action->{'action'}) {
			if ($text =~ /(\{.*\})/s) { $action = eval { decode_json $1 }; }
		}
		unless ($action && $action->{'action'}) { $final = $text; last; }
		my $obs = &coding_propose_execute($action, \%staged);
		push @steps, { action => $action, observation => $obs };
		push @lines, 'ACTION: ' . encode_json($action);
		push @lines, 'OBSERVATION: ' . $obs;
		if ($action->{'action'} eq 'done' || $action->{'action'} eq 'say') { $final = $action->{'text'} // ''; last; }
		if (($ai_tokens->{'in'} + $ai_tokens->{'out'}) - ($ai_start->{'in'} + $ai_start->{'out'}) > 80000) {
			$final = "stopped: this run's token cap";
			last;
		}
	}
	my $files = scalar(keys %staged) ? encode_json(\%staged) : '';
	&subs::db_update('staged_fixes', {
		status => ($files ? 'proposed' : 'failed'),
		model => $model,
		summary => substr($final // '', 0, 4000),
		files => $files,
		steps => encode_json(\@steps),
		note => ($files ? '' : 'no file change was proposed'),
	}, { uuid => $row->{'uuid'} });
	my $run_calls = $ai_tokens->{'calls'} - $ai_start->{'calls'};
	my $run_in = $ai_tokens->{'in'} - $ai_start->{'in'};
	my $run_out = $ai_tokens->{'out'} - $ai_start->{'out'};
	&watch_tokens_add($run_in + $run_out);
	if (defined $log) {
		$log->info('error watch: ' . ($files ? 'proposed' : 'no proposal') . ' for "' . substr($row->{'signature'} || '?', 0, 80) . '" - '
			. $run_calls . ' call(s), in ' . $run_in . ' out ' . $run_out . ' tokens, day ' . &watch_tokens_spent() . ($budget ? '/' . $budget : ' (no cap)'));
	}
	return $files ? 'proposed' : 'failed';
}

our $git_watcher_dirty_note;

sub git_watcher_check {
	return unless -d '.git';
	my $before = `git rev-parse HEAD 2>/dev/null`; chomp $before;
	# GitHub is the authority: the checkout follows origin/main first, and only a
	# machine origin cannot move forward - the fetch failed (the mesh answers while
	# the internet does not), or it holds commits origin/main lacks - consults a
	# peer as the fallback. A peer pull must be a true fast-forward: the old order
	# ("whoever has the newest is it") let a peer whose advertised version outran
	# its actual tree reset this machine backward through the rewritten-history
	# path, so the watcher never accepts a peer reset. A peer with rewritten
	# history, or with work the whole house should ride, pushes to GitHub and the
	# authority carries it everywhere.
	my ($status, $out) = &subs::git_repo_update({ repo => '.', force => 0 });
	if ($status eq 'dirty') {
		# a tree with tracked changes never moves; say so once an hour rather
		# than leaving the machine quietly stuck behind
		my $now = &subs::rightNow();
		if ((!$git_watcher_dirty_note || $now - $git_watcher_dirty_note > 3600000) && $subs::logfile) {
			$git_watcher_dirty_note = $now;
			open(my $fh, '>>', $subs::logfile);
			print $fh $now . " git watcher: tree is dirty, left alone\n";
			close $fh;
		}
		return;
	}
	unless ($status eq 'updated' || $status eq 'reset' || $status eq 'current') {
		my $mine = &subs::jawn_version();
		my $rms = eval { &subs::db_select('remote_machines')->hashes } || [];
		my @peers = sort { &subs::version_cmp($b->{'version'}, $a->{'version'}) }
			grep { $_->{'version'} && &subs::version_newer($_->{'version'}, $mine) } @{$rms};
		# only a few, so a run of dead peers cannot hold the watcher up
		@peers = @peers[0 .. 2] if scalar @peers > 3;
		foreach my $rm ( @peers ) {
			my ($st, $o) = &subs::git_peer_update({ repo => '.', rm => $rm, ff_only => 1 });
			if ($st eq 'updated') { $status = "peer/$st"; $out = $o; last; }
		}
	}
	return unless $status eq 'updated' || $status eq 'reset';
	if ($subs::logfile) {
		my $after = `git rev-parse HEAD 2>/dev/null`; chomp $after;
		# name the source in the log: origin is the authority, a peer the fallback
		my $label = ($status =~ m{^peer/}) ? $status : "origin/$status";
		open(my $fh, '>>', $subs::logfile);
		print $fh &subs::rightNow() . " git watcher: $label " . substr($before,0,10) . " -> " . substr($after,0,10) . ", restarting\n";
		close $fh;
	}
	# A desktop host keeps an installed copy of the app in
	# ~/.local/share/jawnos/desktop; the pulled code has to land there too, or the
	# old install keeps running. (An already-open GUI picks it up on next launch.)
	if (-d &subs::home('~/.local/share/jawnos/desktop') && -x './desktop/install.sh') {
		`./desktop/install.sh >/dev/null 2>&1`;
	}
	# a new version may name a new application to install (Piper, say)
	&subs::install_extras();
	write_file(&subs::home('~/.president/status'), 'restart');
}

# A Mojo::UserAgent that speaks to a peer the way remote_useragent_maker builds
# one - the tunnel-aware manager url plus the session cookie we already hold for
# it. Kept in subroutines so the boot-time loops, which run before Manager.pl is
# loaded, can reach a peer without pulling the whole app in.
sub peer_useragent {
	my $rm = shift;
	return (undef, $rm) unless $rm && $rm->{'cookie'} && $rm->{'manager'};
	$rm = &subs::remote_machine_tunnel_processor($rm);
	my $jar = eval { decode_json $rm->{'cookie'} };
	return (undef, $rm) unless $jar && ref $jar eq 'ARRAY';
	require Mojo::Cookie::Response;
	my $ua = Mojo::UserAgent->new;
	$ua = $ua->max_response_size(0);
	foreach my $c ( @{$jar} ) {
		next unless $c->{'name'};
		$ua->cookie_jar->add(Mojo::Cookie::Response->new(
			name   => $c->{'name'},
			value  => $c->{'value'},
			domain => $c->{'domain'} || '',
			path   => $c->{'path'} || '/',
		));
	}
	$ua->insecure(1);
	# ride the same signed rail every other peer call rides: once a key is
	# pinned, an unsigned request is refused, and this UA serves the git bundle,
	# the APK sync and the voice sync - all peer_verify routes. (Unsigned was
	# only ever accepted while the peer had no key on file.)
	$ua->on(start => sub { my ($ua, $tx) = @_; &peer_sign_request($tx->req); });
	return ($ua, $rm);
}

# Append one line to the app-release sync's own log (the manager log). Quiet
# when there is no logfile yet (an early boot).
sub app_release_log {
	my $line = shift;
	return unless $subs::logfile;
	open(my $fh, '>>', $subs::logfile) or return;
	print $fh &subs::rightNow() . " app release: $line\n";
	close $fh;
}

# Fetch a URL into a string. curl first, forced to IPv4: on a network whose IPv6
# path to GitHub's asset CDN stalls, Mojo::UserAgent (which does not pin the
# address family) hangs where curl -4 completes. Falls back to Mojo when curl is
# absent, then to curl without -4 for a host that has no A record.
sub github_fetch {
	my ($url, $timeout) = @_;
	$timeout ||= 60;
	my $curl = `command -v curl 2>/dev/null`;
	chomp $curl;
	if ($curl) {
		foreach my $args ( ['-4'], [] ) {
			my $tmp = "/tmp/jawn_gh_" . $$ . "_" . int(rand(1_000_000));
			my $rc = system($curl, @{$args}, '-sSL', '--max-time', "$timeout", '-o', $tmp, $url);
			if ($rc == 0 && -s $tmp) {
				my $body;
				if (open(my $fh, '<', $tmp)) { binmode $fh; local $/; $body = <$fh>; close $fh; }
				unlink $tmp;
				return $body if defined $body && length $body;
			}
			unlink $tmp;
		}
	}
	my $ua = Mojo::UserAgent->new(connect_timeout => 10, inactivity_timeout => $timeout);
	$ua->max_response_size(0);
	$ua->max_redirects(5);
	my $res = eval { $ua->get($url)->result };
	return ($res && $res->is_success) ? $res->body : undef;
}

# The public app-release manifest on GitHub - a source that needs no peer to
# answer, or to hold a valid cookie for us. The release carries app_release.json
# (product, versionCode, versionName, filename, sha256) beside the APK, under a
# fixed tag so the URL never moves; the download is a plain github.com asset,
# not the rate-limited API. Returns the manifest plus the asset base url, or
# undef when there is no release (or no network).
sub github_release_manifest {
	my ($repo, $tag, $file) = @_;
	return undef unless $repo && $repo =~ m{^[^/\s]+/[^/\s]+\z};
	$tag ||= 'releases';
	$file ||= 'app_release.json';
	return undef unless $file =~ /^[A-Za-z0-9_.-]+$/;
	my $base = "https://github.com/$repo/releases/download/$tag";
	my $body = &github_fetch("$base/$file", 30);
	unless (defined $body && length $body) {
		&app_release_log('github manifest fetch failed (' . $base . '/' . $file . ')');
		return undef;
	}
	my $man = eval { decode_json $body };
	return undef unless $man && ref $man eq 'HASH'
		&& $man->{'product'} && $man->{'versionCode'} && $man->{'filename'};
	$man->{'base'} = $base;
	return $man;
}

# Reconcile the staged app releases (the APKs under releases/) with the newest a
# reachable peer holds: a device that is behind pulls the APK in, so every
# device becomes a holder and a source. The APK is a blob (gitignored) carried
# over http, not through git - a ~35 MB binary per version in git history would
# be untenable. Pull, on the watcher's slow tick; the code watcher keeps the
# Perl tree current. GitHub's release manifest is consulted too, so a device
# with no reachable peer (or no valid peer cookie) still updates.
# Cache each reachable peer's Ollama model list, so Plat can offer models by the
# machine they run on without waiting on the network. Runs on a slow tick; a
# peer that goes quiet keeps its last list until it answers again.
sub ollama_models_sync {
	my $me = &subs::signatorial_designer();
	my $rms = &subs::db_select('remote_machines')->hashes || [];
	foreach my $rm ( @{$rms} ) {
		my $rsig = $rm->{'signatorial'};
		next unless $rsig && $rsig ne $me;
		my ($ua, $p) = &subs::peer_useragent($rm);
		next unless $ua;
		my $res = eval { $ua->inactivity_timeout(15)->get($p->{'manager'} . '/manager/ollama_models?signatorial=' . $me)->result };
		next unless $res && $res->is_success;
		my $body = eval { decode_json $res->body };
		next unless $body && ref $body eq 'HASH';
		my $models = $body->{'models'};
		next unless ref $models eq 'ARRAY';
		my $update = { ollama_models => encode_json($models) };
		$update->{'hostname'} = $body->{'hostname'} if $body->{'hostname'};
		&subs::db_update('remote_machines', $update, { signatorial => $rsig });
	}
}

sub app_release_sync {
	my $dir = &subs::home('~/jawnos/releases');
	mkdir $dir unless -d $dir;
	my $me = &subs::signatorial_designer();
	my (%local, %best);
	foreach my $f ( glob("$dir/jawnos-*.apk") ) {
		my ($product, $vc) = ( $f =~ m{/jawnos-(app|api)-(\d+)-} );
		next unless $product;
		$local{$product} = $vc if !$local{$product} || $vc > $local{$product};
	}
	# GitHub first: a public source that needs no peer, so a device with no
	# reachable peer (or a stale peer cookie) still updates. Each product has
	# its own manifest beside its APK; the app manifest keeps its historical
	# name, the api one is new. Failing that, the peer loop below still catches it.
	foreach my $manifest_file (qw(app_release.json api_release.json)) {
		my $gh = &github_release_manifest(
			$config->{'github_repo'} || 'jonathanferwerda/jawnos',
			$config->{'github_release_tag'} || 'releases',
			$manifest_file);
		next unless $gh && $gh->{'product'} && ($gh->{'versionCode'} || 0) > 0;
		my $gp = $gh->{'product'};
		my $gv = $gh->{'versionCode'} + 0;
		my $gf = $gh->{'filename'};
		next unless (!$local{$gp} || $gv > $local{$gp})
			&& $gf && $gf =~ /^jawnos-\Q$gp\E-\d+-[^\/]+\.apk$/;
		my $blob = &github_fetch($gh->{'base'} . '/' . $gf, 600);
		unless (defined $blob && length $blob) {
			&app_release_log('github ' . $gp . ' v' . $gv . ' did not download; falling back to peers');
		}
		my $sha = (defined $blob && length $blob) ? eval { require Digest::SHA; Digest::SHA::sha256_hex($blob) } : undef;
		if (defined $blob && length $blob && (!$gh->{'sha256'} || ($sha && $sha eq $gh->{'sha256'}))) {
			my $dest = "$dir/$gf";
			write_file("$dest.tmp", $blob);
			unlink $_ for grep { $_ ne "$dest.tmp" } glob("$dir/jawnos-$gp-*.apk");
			if (rename("$dest.tmp", $dest)) {
				$local{$gp} = $gv;
				&app_release_log('pulled ' . $gp . ' v' . $gv . ' (' . length($blob) . ' bytes) from github');
			}
		}
	}
	my $rms = &subs::db_select('remote_machines')->hashes || [];
	foreach my $rm ( @{$rms} ) {
		my $rsig = $rm->{'signatorial'};
		next unless $rsig && $rsig ne $me;
		my ($ua, $p) = &subs::peer_useragent($rm);
		next unless $ua;
		my $res = eval { $ua->inactivity_timeout(20)->get($p->{'manager'} . '/manager/app_release?signatorial=' . $me)->result };
		next unless $res && $res->is_success;
		my $body = eval { decode_json $res->body };
		unless ($body && ref $body eq 'HASH') {
			&app_release_log('peer ' . ($rm->{'hostname'} || $rsig) . ' did not answer app_release with JSON (stale session cookie?)');
			next;
		}
		my $phost = $body->{'hostname'} || $rm->{'hostname'} || $rsig;
		foreach my $rel ( @{ $body->{'releases'} || [] } ) {
			my ($product, $vc) = ($rel->{'product'}, ($rel->{'versionCode'} || 0) + 0);
			next unless $product && $vc;
			next if $local{$product} && $vc <= $local{$product};
			next if $best{$product} && $vc <= $best{$product}->{'versionCode'};
			$best{$product} = { %$rel, versionCode => $vc, manager => $p->{'manager'}, ua => $ua, host => $phost };
		}
	}
	foreach my $product ( sort keys %best ) {
		my $b = $best{$product};
		my $filename = $b->{'filename'};
		next unless $filename && $filename =~ /^jawnos-\Q$product\E-\d+-[^\/]+\.apk$/;
		my $url = $b->{'manager'} . '/manager/app_download?product=' . $product . '&versionCode=' . $b->{'versionCode'} . '&signatorial=' . $me;
		my $res = eval { $b->{'ua'}->inactivity_timeout(300)->get($url)->result };
		next unless $res && $res->is_success && defined $res->body && length $res->body;
		my $blob = $res->body;
		my $sha = eval { require Digest::SHA; Digest::SHA::sha256_hex($blob) };
		next if $b->{'sha256'} && $sha && $sha ne $b->{'sha256'};
		my $dest = "$dir/$filename";
		write_file("$dest.tmp", $blob);
		unlink $_ for grep { $_ ne "$dest.tmp" } glob("$dir/jawnos-$product-*.apk");
		rename("$dest.tmp", $dest) or next;
		&app_release_log('pulled ' . $product . ' v' . $b->{'versionCode'} . ' (' . length($blob) . ' bytes) from ' . $b->{'host'});
	}
}

# Reconcile the voice models (voices/*.onnx and their json) with a reachable peer.
# Models are arch-independent, so they travel the same way the APKs do - a device
# that lacks one pulls it in and can then serve it, so every device ends up with
# the same voices. The piper binary is per-arch and stays local, so it is never
# part of this list. The models are immutable, so presence is enough: no version
# to compare, unlike an APK.
sub voice_sync {
my $dir = &subs::home('~/jawnos/voices');
mkdir $dir unless -d $dir;
my $me = &subs::signatorial_designer();
	my %local;
	foreach my $f ( glob("$dir/*.onnx"), glob("$dir/*.onnx.json") ) {
		my ($base) = $f =~ m{/([^/]+)$};
		$local{$base} = 1 if $base;
	}
my $rms = &subs::db_select('remote_machines')->hashes || [];
foreach my $rm ( @{$rms} ) {
	my $rsig = $rm->{'signatorial'};
	next unless $rsig && $rsig ne $me;
	my ($ua, $p) = &subs::peer_useragent($rm);
	next unless $ua;
	my $res = eval { $ua->inactivity_timeout(20)->get($p->{'manager'} . '/manager/voice_release?signatorial=' . $me)->result };
	next unless $res && $res->is_success;
	my $body = eval { decode_json $res->body } || {};
	my $phost = $body->{'hostname'} || $rm->{'hostname'} || $rsig;
	foreach my $v ( @{ $body->{'voices'} || [] } ) {
		my $filename = $v->{'filename'};
		next unless $filename && $filename =~ /^[A-Za-z0-9_.-]+\.onnx(\.json)?$/;
		next if $local{$filename};
		my $url = $p->{'manager'} . '/manager/voice_download?file=' . $filename . '&signatorial=' . $me;
		my $vres = eval { $ua->inactivity_timeout(300)->get($url)->result };
		next unless $vres && $vres->is_success && defined $vres->body && length $vres->body;
		my $blob = $vres->body;
		my $sha = eval { require Digest::SHA; Digest::SHA::sha256_hex($blob) };
		next if $v->{'sha256'} && $sha && $sha ne $v->{'sha256'};
		my $dest = "$dir/$filename";
		write_file("$dest.tmp", $blob);
		rename("$dest.tmp", $dest) or next;
		$local{$filename} = 1;
		if ($subs::logfile) {
			open(my $fh, '>>', $subs::logfile);
			print $fh &subs::rightNow() . " voice: pulled $filename (" . length($blob) . " bytes) from " . $phost . "\n";
			close $fh;
		}
	}
}

	# Keep only the voices the running code names. A model dropped from
	# say_voices() (a licence problem, say) is removed here, so no device goes on
	# serving or speaking with it. Never touches the per-arch piper/ bundle.
	# Only prune once every sanctioned voice is present: a device that could not
	# reach a peer keeps its old models rather than being left with none.
	my (%wanted, $complete);
	$complete = 1;
	foreach my $v ( &subs::say_voices() ) {
		next unless ($v->{'engine'} || '') eq 'piper' && $v->{'model'};
		$wanted{ $v->{'model'} . '.onnx' } = 1;
		$wanted{ $v->{'model'} . '.onnx.json' } = 1;
		$complete = 0 unless -e "$dir/" . $v->{'model'} . '.onnx';
	}
	if ($complete) {
		foreach my $f ( glob("$dir/*.onnx"), glob("$dir/*.onnx.json") ) {
			my ($base) = $f =~ m{/([^/]+)$};
			unlink $f if $base && !$wanted{$base};
		}
	}
}

1;
