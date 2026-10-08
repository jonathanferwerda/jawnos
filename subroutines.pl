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
use Crypt::Simple;
use File::Slurp;
use File::Find;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::SQLite;
use Data::Dumper;
use Time::HiRes qw(gettimeofday time);
use Mojo::IOLoop;
use Clone qw(clone);
use MIME::Base64;
use Authen::SASL;
use Net::IMAP::Client;
use MIME::Parser;
use Email::Stuffer;
use Email::Sender::Transport::SMTP;
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
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
my $universal_splitter = $gb::universal_splitter;

our $device = &device_setter();
sub format_name() {
	my $name = shift || "";
	my $fname = lc $name;
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

	my $leap_year =  &subs::time_abbrev_translator('4y') / 1000;
	if ($durational > $leap_year) {
		my $leaps = (( $durational) / ($leap_year));
		$durational = $durational - (&subs::time_abbrev_translator($leaps . 'd' ) / 1000);
	}

	my $duration = duration($durational);
	if ($durational < 1) {
		$duration = sprintf("%.2f", $durational * 1000) . ' milliseconds';
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
	return $duration;
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
		next if $times[0] =~ /\s/;
		if ($times[0]) {
			if ($times[0] < 0 || $negative eq '-') { $time = $time * -1 unless $time < 0; }
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
	if (grep { $_ >= &subs::rightNow() } @times) {
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

sub appt_header_printer() {
	my $data = shift;
	my $app = $data->{'app'};

	my $appts = $data->{'appts'} || &Manager::log_reader({ app => $app, view => 'centre_view'  });
	&appt_toggle_checker($app);
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my $c = &subs::controller_builder();
	my $header = $c->render_to_string(template => 'apps/appointment_header', timestamp => $server_time, appts => $appts, appointments => [ $app ], a => $app );

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

	return $header;
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
		$log->error("Socket sender error: $err") if defined $log;

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
		my ($user, $system, $cuser, $csystem) = times;
		my $cpu = {
			timestamp => &subs::rightNow(),
			user => $user,
			'system' => $system,
			total => $user + $system
		};
		&subs::unix_socket_sender($file,$subprocess);

		if ($@) { warn "Worker $$: Failed to send 'start' state: $@" }
		my $pinger = Mojo::IOLoop->recurring(5 => sub {
			$subprocess->{'status'} = 'running';
			$subprocess->{'timestamp'} = &subs::rightNow();
			my ($user, $system, $cuser, $csystem) = times;
			my $cpu = {
				timestamp => &subs::rightNow(),
				user => $user,
				'system' => $system,
				total => $user + $system
			};
			$subprocess->{'htop'} = $cpu;
			&subs::unix_socket_sender($file,$subprocess);
		});
		eval {
			$subroutine->();
			Mojo::IOLoop->remove($pinger);
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
		die $sub_error if $sub_error;
	};
	if ($gb::subprocessed > 1) {
		$wrapped_subroutine->();
	} else {
		Mojo::IOLoop->subprocess->run_p($wrapped_subroutine)
	}

}


sub subprocess_tree_viewer() {
	my $tmp_dir = &subs::home('~/.process_watch');
	my $file = $tmp_dir;
	my $returner = { data => {}, html => '' };

	my $response_data = &subs::unix_socket_sender($file,{ 'query' => 'subprocesses' },1);

	# The process list lives in the launcher (jawn); if it is busy or the reply is
	# unreadable, fall back to an empty tree rather than breaking the whole
	# system settings page.
	return $returner unless ref $response_data eq 'HASH';

	my $c = &subs::controller_builder(undef,{ cache => 'no' });
	delete $response_data->{'status'};
	my $html = eval {
		$c->render_to_string(
			template => 'configure/process_tree',
			subprocesses => $response_data
		);
	} || '';

	$returner = { data => $response_data, html => $html };

	return $returner
}


sub random_string_creator() {

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

sub statement_grabber() {
	my $appts = shift;

	my $articles;

	foreach my $a (keys %{$appts}) {
		unless ($a =~ /^__/ ) {
			$articles .= &format_name($a) . "---";
		}
	}
	return $articles;
}


our $time_subs = {
	'second' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * ($multiplier || 1));
		return $re;
	},
	'15second' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 15 * ($multiplier || 1));
		return $re;
	},
	'30second' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 30 * ($multiplier || 1));
		return $re;
	},
	'45second' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 45 * ($multiplier || 1));
		return $re;
	},
	'minute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * ($multiplier || 1));
		return $re;
	},
	'twominute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 2 * ($multiplier || 1));
		return $re;
	},
	'threeminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 3 * ($multiplier || 1));
		return $re;
	},
	'fourminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 4 * ($multiplier || 1));
		return $re;
	},
	'fiveminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 5 * ($multiplier || 1));
		return $re;
	},
	'sixminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 6 * ($multiplier || 1));
		return $re;
	},
	'sevenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 7 * ($multiplier || 1));
		return $re;
	},
	'eightminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 8 * ($multiplier || 1));
		return $re;
	},
	'nineminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 9 * ($multiplier || 1));
		return $re;
	},
	'tenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 10 * ($multiplier || 1));
		return $re;
	},
	'elevenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 11 * ($multiplier || 1));
		return $re;
	},
	'twelveminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 12 * ($multiplier || 1));
		return $re;
	},
	'thirteenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 13 * ($multiplier || 1));
		return $re;
	},
	'fourteenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 14 * ($multiplier || 1));
		return $re;
	},
	'fifteenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 15 * ($multiplier || 1));
		return $re;
	},
	'sixteenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 16 * ($multiplier || 1));
		return $re;
	},
	'seventeenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 17 * ($multiplier || 1));
		return $re;
	},
	'eighteenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 18 * ($multiplier || 1));
		return $re;
	},
	'nineteenminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 19 * ($multiplier || 1));
		return $re;
	},
	'twentyminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 20 * ($multiplier || 1));
		return $re;
	},
	'twentyoneminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentytwominute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 22 * ($multiplier || 1));
		return $re;
	},
	'twentythreeminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 23 * ($multiplier || 1));
		return $re;
	},
	'twentyfourminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 24 * ($multiplier || 1));
		return $re;
	},
	'twentyfiveminute' => sub() {
		my $timestamp = shift;
		my $multiplier = shift || 1;
		my $re = $timestamp - (1000 * 60 * 25 * ($multiplier || 1));
		return $re;
	},
	'twentysixminute' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 26 * ($multiplier || 1));
		return $re;
	},
	'twentysevenminute' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 27 * ($multiplier || 1));
		return $re;
	},
	'twentyeightminute' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 28 * ($multiplier || 1));
		return $re;
	},
	'twentynineminute' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 29 * ($multiplier || 1));
		return $re;
	},
	'thirtyminute' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 30 * ($multiplier || 1));
		return $re;
	},
	'fortyfiveminute' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 45 * ($multiplier || 1));
		return $re;
	},
	'hour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = abs $timestamp - (1000 * 60 * 60 * ($multiplier || 1));
		return $re;
	},
	'twohour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = abs $timestamp - (1000 * 60 * 120 * ($multiplier || 1));
		return $re;
	},
	'threehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 3 * ($multiplier || 1));
		return $re;
	},
	'fourhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 4 * ($multiplier || 1));
		return $re;
	},
	'fivehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 5 * ($multiplier || 1));
		return $re;
	},
	'sixhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 6 * ($multiplier || 1));
		return $re;
	},
	'sevenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 7 * ($multiplier || 1));
		return $re;
	},
	'eighthour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 8 * ($multiplier || 1));
		return $re;
	},
	'ninehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 9 * ($multiplier || 1));
		return $re;
	},
	'tenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 10 * ($multiplier || 1));
		return $re;
	},
	'elevenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 11 * ($multiplier || 1));
		return $re;
	},
	'twelvehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 12 * ($multiplier || 1));
		return $re;
	},
	'thirteenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 13 * ($multiplier || 1));
		return $re;
	},
	'fourteenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 14 * ($multiplier || 1));
		return $re;
	},
	'fifteenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 15 * ($multiplier || 1));
		return $re;
	},
	'sixteenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 16 * ($multiplier || 1));
		return $re;
	},
	'seventeenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 17 * ($multiplier || 1));
		return $re;
	},
	'eighteenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 18 * ($multiplier || 1));
		return $re;
	},
	'nineteenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 19 * ($multiplier || 1));
		return $re;
	},
	'twentyhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 20 * ($multiplier || 1));
		return $re;
	},
	'twentyonehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentytwohour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 22 * ($multiplier || 1));
		return $re;
	},
	'twentythreehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 23 * ($multiplier || 1));
		return $re;
	},
	'twentyfourhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * ($multiplier || 1));
		return $re;
	},
	'twentyfivehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 25 * ($multiplier || 1));
		return $re;
	},
	'twentysixhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 26 * ($multiplier || 1));
		return $re;
	},
	'twentysevenhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 27 * ($multiplier || 1));
		return $re;
	},
	'twentyeighthour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 28 * ($multiplier || 1));
		return $re;
	},
	'twentyninehour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 29 * ($multiplier || 1));
		return $re;
	},
	'thirtyhour' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 30 * ($multiplier || 1));
		return $re;
	},
	'day' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * ($multiplier || 1));
		return $re;
	},
	'twoday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 48 * ($multiplier || 1));
		return $re;
	},
	'threeday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 72 * ($multiplier || 1));
		return $re;
	},
	'fourday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 4 * ($multiplier || 1));
		return $re;
	},
	'fiveday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 5 * ($multiplier || 1));
		return $re;
	},
	'sixday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 6 * ($multiplier || 1));
		return $re;
	},
	'sevenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * ($multiplier || 1));
		return $re;
	},
	'eightday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 8 * ($multiplier || 1));
		return $re;
	},
	'nineday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 9 * ($multiplier || 1));
		return $re;
	},
	'tenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 10 * ($multiplier || 1));
		return $re;
	},
	'elevenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 11 * ($multiplier || 1));
		return $re;
	},
	'twelveday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 12 * ($multiplier || 1));
		return $re;
	},
	'thirteenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 13 * ($multiplier || 1));
		return $re;
	},
	'fourteenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 14 * ($multiplier || 1));
		return $re;
	},
	'fifteenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 15 * ($multiplier || 1));
		return $re;
	},
	'sixteenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 16 * ($multiplier || 1));
		return $re;
	},
	'seventeenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 17 * ($multiplier || 1));
		return $re;
	},
	'eighteenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 18 * ($multiplier || 1));
		return $re;
	},
	'nineteenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 19 * ($multiplier || 1));
		return $re;
	},
	'twentyday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 20 * ($multiplier || 1));
		return $re;
	},
	'twentyoneday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentytwoday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 22 * ($multiplier || 1));
		return $re;
	},
	'twentythreeday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 23 * ($multiplier || 1));
		return $re;
	},
	'twentyfourday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 24 * ($multiplier || 1));
		return $re;
	},
	'twentyfiveday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 25 * ($multiplier || 1));
		return $re;
	},
	'twentysixday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 26 * ($multiplier || 1));
		return $re;
	},
	'twentysevenday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 27 * ($multiplier || 1));
		return $re;
	},
	'twentyeightday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 28 * ($multiplier || 1));
		return $re;
	},
	'twentynineday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 29 * ($multiplier || 1));
		return $re;
	},
	'thirtyday' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * ($multiplier || 1));
		return $re;
	},
	'week' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * ($multiplier || 1));
		return $re;
	},
	'twoweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 2 * ($multiplier || 1));
		return $re;
	},
	'threeweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 3 * ($multiplier || 1));
		return $re;
	},
	'fourweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 4 * ($multiplier || 1));
		return $re;
	},
	'fiveweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 5 * ($multiplier || 1));
		return $re;
	},
	'sixweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 6 * ($multiplier || 1));
		return $re;
	},
	'sevenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 7 * ($multiplier || 1));
		return $re;
	},
	'eightweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 8 * ($multiplier || 1));
		return $re;
	},
	'nineweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 9 * ($multiplier || 1));
		return $re;
	},
	'tenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 10 * ($multiplier || 1));
		return $re;
	},
	'elevenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 11 * ($multiplier || 1));
		return $re;
	},
	'twelveweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 12 * ($multiplier || 1));
		return $re;
	},
	'thirteenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 13 * ($multiplier || 1));
		return $re;
	},
	'fourteenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 14 * ($multiplier || 1));
		return $re;
	},
	'fifteenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 15 * ($multiplier || 1));
		return $re;
	},
	'sixteenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 16 * ($multiplier || 1));
		return $re;
	},
	'seventeenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 17 * ($multiplier || 1));
		return $re;
	},
	'eighteenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 18 * ($multiplier || 1));
		return $re;
	},
	'nineteenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 19 * ($multiplier || 1));
		return $re;
	},
	'twentyweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 20 * ($multiplier || 1));
		return $re;
	},
	'twentyoneweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentytwoweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 22 * ($multiplier || 1));
		return $re;
	},
	'twentythreeweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 23 * ($multiplier || 1));
		return $re;
	},
	'twentyfourweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 24 * ($multiplier || 1));
		return $re;
	},
	'twentyfiveweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 25 * ($multiplier || 1));
		return $re;
	},
	'twentysixweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 26 * ($multiplier || 1));
		return $re;
	},
	'twentysevenweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 27 * ($multiplier || 1));
		return $re;
	},
	'twentyeightweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 28 * ($multiplier || 1));
		return $re;
	},
	'twentynineweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 29 * ($multiplier || 1));
		return $re;
	},
	'thirtyweek' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 7 * 30 * ($multiplier || 1));
		return $re;
	},
	'moon' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 28 * ($multiplier || 1));
		return $re;
	},
	'month' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * ($multiplier || 1));
		return $re;
	},
	'twomonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 2 * ($multiplier || 1));
		return $re;
	},
	'threemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 3 * ($multiplier || 1));
		return $re;
	},
	'fourmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 4 * ($multiplier || 1));
		return $re;
	},
	'fivemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 5 * ($multiplier || 1));
		return $re;
	},
	'sixmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 6 * ($multiplier || 1));
		return $re;
	},
	'sevenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 7 * ($multiplier || 1));
		return $re;
	},
	'eightmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 8 * ($multiplier || 1));
		return $re;
	},
	'ninemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 9 * ($multiplier || 1));
		return $re;
	},
	'tenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 10 * ($multiplier || 1));
		return $re;
	},
	'elevenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 11 * ($multiplier || 1));
		return $re;
	},
	'twelvemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 12 * ($multiplier || 1));
		return $re;
	},
	'thirteenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 13 * ($multiplier || 1));
		return $re;
	},
	'fourteenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 14 * ($multiplier || 1));
		return $re;
	},
	'fifteenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 15 * ($multiplier || 1));
		return $re;
	},
	'sixteenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 16 * ($multiplier || 1));
		return $re;
	},
	'seventeenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 17 * ($multiplier || 1));
		return $re;
	},
	'eighteenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 18 * ($multiplier || 1));
		return $re;
	},
	'nineteenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 19 * ($multiplier || 1));
		return $re;
	},
	'twentymonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 20 * ($multiplier || 1));
		return $re;
	},
	'twentyonemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentytwomonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 22 * ($multiplier || 1));
		return $re;
	},
	'twentythreemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 23 * ($multiplier || 1));
		return $re;
	},
	'twentyfourmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 24 * ($multiplier || 1));
		return $re;
	},
	'twentyfivemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 25 * ($multiplier || 1));
		return $re;
	},
	'twentysixmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 26 * ($multiplier || 1));
		return $re;
	},
	'twentysevenmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 27 * ($multiplier || 1));
		return $re;
	},
	'twentyeightmonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 28 * ($multiplier || 1));
		return $re;
	},
	'twentyninemonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 29 * ($multiplier || 1));
		return $re;
	},
	'thirtymonth' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 30 * 30 * ($multiplier || 1));
		return $re;
	},
	'season' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 90 * ($multiplier || 1));
		return $re;
	},
	'quarter' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * (30.5 * 3) * ($multiplier || 1));
		return $re;
	},
	'year' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * ($multiplier || 1));
		return $re;
	},
	'twoyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 2 * ($multiplier || 1));
		return $re;
	},
	'threeyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 3 * ($multiplier || 1));
		return $re;
	},
	'fouryear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 4 * ($multiplier || 1));
		return $re;
	},
	'fiveyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 5 * ($multiplier || 1));
		return $re;
	},
	'sixyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 6 * ($multiplier || 1));
		return $re;
	},
	'sevenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 7 * ($multiplier || 1));
		return $re;
	},
	'eightyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 8 * ($multiplier || 1));
		return $re;
	},
	'nineyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 9 * ($multiplier || 1));
		return $re;
	},
	'tenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 10 * ($multiplier || 1));
		return $re;
	},
	'elevenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 11 * ($multiplier || 1));
		return $re;
	},
	'twelveyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 12 * ($multiplier || 1));
		return $re;
	},
	'thirteenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 13 * ($multiplier || 1));
		return $re;
	},
	'fourteenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 14 * ($multiplier || 1));
		return $re;
	},
	'fifteenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 15 * ($multiplier || 1));
		return $re;
	},
	'sixteenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 16 * ($multiplier || 1));
		return $re;
	},
	'seventeenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 17 * ($multiplier || 1));
		return $re;
	},
	'eighteenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 18 * ($multiplier || 1));
		return $re;
	},
	'nineteenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 19 * ($multiplier || 1));
		return $re;
	},
	'twentyyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 20 * ($multiplier || 1));
		return $re;
	},
	'twentyoneyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 21 * ($multiplier || 1));
		return $re;
	},
	'twentytwoyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 22 * ($multiplier || 1));
		return $re;
	},
	'twentythreeyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 23 * ($multiplier || 1));
		return $re;
	},
	'twentyfouryear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 24 * ($multiplier || 1));
		return $re;
	},
	'twentyfiveyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 25 * ($multiplier || 1));
		return $re;
	},
	'twentysixyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 26 * ($multiplier || 1));
		return $re;
	},
	'twentysevenyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 27 * ($multiplier || 1));
		return $re;
	},
	'twentyeightyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 28 * ($multiplier || 1));
		return $re;
	},
	'twentynineyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 29 * ($multiplier || 1));
		return $re;
	},
	'thirtyyear' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 30 * ($multiplier || 1));
		return $re;
	},
	'decade' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 10 * ($multiplier || 1));
		return $re;
	},
	'century' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 10 * 10 * ($multiplier || 1));
		return $re;
	},
	'millenium' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 10 * 10 * 10 * ($multiplier || 1));
		return $re;
	},
	'era' => sub() {
		my $timestamp = shift; my $multiplier = shift;
		my $re = $timestamp - (1000 * 60 * 60 * 24 * 365 * 10 * 10 * 10 * 10 * ($multiplier || 1));
		return $re;
	},
};

sub ago_calc() {
	my ($ago,$timestamp) = @_;
	$timestamp = &rightNow() unless $timestamp;
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
			$difference = &{$subs::time_subs->{'day'}}(0);
			$ago =~ s/$1//gi;
		}
		if ($ago =~ /(yes)/) {
			$difference = -1 * &{$subs::time_subs->{'day'}}(0);
			$ago =~ s/$1//gi;
		}

		my $is_dow = 0;
		if ($ago =~ /(mon)/) {
			$difference = (1 - $time_dow) * &{$subs::time_subs->{'day'}}(0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(tue)/) {
			$difference = (2 - $time_dow) * &{$subs::time_subs->{'day'}}(0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(wed)/) {
			$difference = (3 - $time_dow) * &{$subs::time_subs->{'day'}}(0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(thu)/) {
			$difference = (4 - $time_dow) * &{$subs::time_subs->{'day'}}(0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(fri)/) {
			$difference = (5 - $time_dow) * &{$subs::time_subs->{'day'}}(0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(sat)/) {
			$difference = (6 - $time_dow) * &{$subs::time_subs->{'day'}}(0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(sun)/) {
			$difference = (7 - $time_dow) * &{$subs::time_subs->{'day'}}(0);
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

sub say_it() {
	my $text = shift;
  &subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		if ($device eq 'mobile') {


			`termux-tts-speak "$text"`;
#			my $filename = &home("~/.president/espeaker.wav");

#			`espeak -w $filename "$text"`;
#			`termux-media-player play $filename`;
#			sleep 1;
#			`shred -u $filename`;
		}
		elsif ($device eq 'computer') {
			`espeak -a70 -v gmw/en-US-nyc "$text"`;
		}
	}, { name => 'say it' });
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
	my $directory = shift;
	my $returner = [];
	my @backups;
	$directory =~ s|[^/]+$||;
	if ($directory && $directory =~ /\/$/) {
		my $backup_ls = `ls -t $directory`;
		@backups = split "\n", $backup_ls;
		foreach my $b (@backups) {
			$b = $directory . $b;
		}
	}

	foreach my $b (@backups) {
		my $status = 'closed';
		my @stat = stat $b ;

		my $bees = $b;
		$bees =~ s/\.[^.]*$//;
		$bees = &home($bees);
		if (-e $bees . '.db') { $status = 'open'; }
		my $archive = $bees =~ /\d{10}$/ ? 'archive' : 'current';

		my $size = sprintf('%.2f', ( $stat[7] / 1024 )) . 'kb';
		my $created = localtime($stat[9] )->strftime('%A %B %d %Y - %I:%M:%S%P %Z');
		push @{$returner}, { archive => $archive, status => $status, directory => $directory, filename => $b, size => $size, created => $created, blocks => $stat[12] };
	}

	return $returner;
}

sub beacon_appt_writer() {
	my $beacon_appts = &subs::db_select('appointments', ['timestamp','uuid'], { app => '__president', type => 'beacon' })->hashes;
	my $beacon;
	if (scalar @{$beacon_appts} > 0) {
		$beacon = $beacon_appts->[0];
		$beacon->{'server_time'} = &subs::rightNow();
		$beacon->{'warranty'} = &subs::ago_calc('-100m', &subs::rightNow());
		&subs::db_update('appointments', $beacon, { uuid => $beacon->{'uuid'}, app => $beacon->{'app'} });
		if (@{$beacon_appts} > 12) {
			foreach my $beacon ( @{$beacon_appts} ) {
				&subs::db_delete('appointments', { app => $beacon->{'app'}, type => 'beacon', uuid => $beacon->{'uuid'} });
			}
		}
	}
	else {
		$beacon = {
			uuid => &subs::random_string_creator(12),
			type => 'beacon',
			app => '__president',
			warranty => &subs::ago_calc('-100m', &subs::rightNow()),
			timestamp => &subs::rightNow()
		};
		&subs::db_insert('appointments', $beacon);
	}
	return $beacon;

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
		my $resulter = &subs::run_command($app,$settings->{$movement});

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
	my $od = encode_json $watch_settings;
	&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $od, subsetting => $chip_id });
	return $returner;
}

sub network_interface_reporter() {
	my $c = shift;
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
				$address->{$nic}->{'manager'} = 'https://' . $inet[1] . ':' . $ENV{PORT_DOCK} .  '/manager';
				$address->{$nic}->{'netmask'} = $inet[3];
				$address->{$nic}->{'broadcast'} = $inet[5];
				$address->{$nic}->{'timestamp'} = &subs::rightNow();
			}
		}
	}

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

sub device_lister() {
	my ($timestamp,$load_type,$ip_range,$chip_id) = @_;
	my ($db,$database,$sql) = &subs::database_grabber();
	my ($dev,$devices,@domains);
	my $user_agent = $gb::user_agent;
	my $server_time = &subs::rightNow();
	my $remote_machinery = &subs::db_query('select * from remote_machines');
	my $my_name = &subs::setting_grabber({ app => 'me', setting => 'my_name' });
	my $signatorial = &subs::signatorial_designer();
	my $remote_machines = $remote_machinery->hashes;
	my $chip_ids = [];
	if ($load_type eq 'scan' || $load_type eq 'ping_scan') {
		$dev = &subs::db_select('devices');
		$devices = $dev->hashes;
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
					$address->{$nic}->{'manager'} = 'https://' . $inet[1] . ':' . $ENV{PORT_DOCK} .  '/manager';
					$address->{$nic}->{'netmask'} = $inet[3];
					$address->{$nic}->{'broadcast'} = $inet[5];

					my @neighbours;
					my $neighbour_check = `ip neigh show dev $nic`;
					my @neighbourinos;
					if ($load_type ne 'ping_scan') {
						@neighbourinos = (split "\n", $neighbour_check);
					}
					if ($neighbour_check eq '' && $ip_range) {
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
					foreach my $m ( @neighbourinos ) {
						next if $m =~ /FAILED/;
						my @l = (split " ", $m);
						my $n = {
							ip => $l[0],
							mac => $l[2] || &subs::random_string_creator(10),
							uuid => &subs::random_string_creator(25)
						};
						my $ping_ip = $n->{'ip'};
						my $alive = `timeout .4 ping -c 1 $ping_ip`;
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
										ip => $tun->{'domain'},
										domain => $tun->{'domain'},
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
								$ua->inactivity_timeout(15);
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
										if ($g->{'purpose'} && !$n->{'purpose'}){# && $last_d == $last_n) {
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
							if ($rd->{'locked'} eq 'yes') {
								@{$address->{$nic}->{'neigh'}} = grep { $_->{'ip'} ne $rd->{'ip'} } @{$address->{$nic}->{'neigh'}};
								push @{$address->{$nic}->{'neigh'}}, $rd;
								push @{$chip_ids}, { id => $rd->{'chip_id'}, name => $rd->{'name'}, purpose => $rd->{'purpose'}, server_time => &subs::rightNow() } if $rd->{'chip_id'};
							}
						}
					}
				}
			}
		}

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
	$dev = &subs::db_select('devices');
	$devices = $dev->hashes;
	my $all_chips = [];
	foreach my $d (@{$devices}) {
		$d->{'address'} = decode_json $d->{'address'} if $d->{'address'};
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
	if (scalar @{$all_chips} > 0) {
		return $all_chips;
	}
	return $devices;
}



sub bluetooth_sender() {
	my $data = shift;
	return unless $data->{'intent'} && $data->{'chip_id'} && $data->{'edt'} && &subs::device_setter() eq 'mobile';
	my $intent = $data->{'intent'};
	my $message = $data->{'message'};
	my $embedded = &subs::device_lister(&subs::rightNow(),$data->{'edt'},undef,$data->{'chip_id'});
	my $service_uuid = $embedded->{'service_uuid'};
	my $characteristic_uuid_rx = $embedded->{'characteristic_uuid_rx'};
	my $characteristic_uuid_tx = $embedded->{'characteristic_uuid_tx'};
	if ($embedded->{'mac_addresses'}->{'bluetooth'}) {
		my $bt_mac = $embedded->{'mac_addresses'}->{'bluetooth'};
		my $name = $embedded->{'name'};
		$message = encode_base64 encode_json $message;
		my $cmd = "am broadcast --user 0 -a $intent -e mac_address '$bt_mac' -e message '$message' -e name '$name' -e service_uuid '$service_uuid' -e characteristic_uuid_rx '$characteristic_uuid_rx' -e characteristic_uuid_tx '$characteristic_uuid_tx'";
		return `$cmd`;
	}
}


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
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my ($db,$database,$sql) = &subs::database_grabber();
	my $t = localtime;
	my $databaser = $database;
	$databaser =~ s/.db$//gi;
	my $filename = &subs::unformat_name( $databaser );
	$databaser =~ s/_\d+$//;
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
	my $suds = $c->session('suds') || &subs::suds_grabber();
	# Bridge for peers still on the old fixed-key Crypt::Simple: the appended
	# encryption-standard must be readable by their decrypter, which only uses the
	# legacy key (md5 of an empty passphrase). Our decrypter falls back to the same
	# key, so this stays readable by updated peers too. Remove once every device runs
	# the per-secret code.
	my $appendage = $gb::universal_splitter . &subs::encrypter(undef,$encryption_standard);
	my $path = $databaser;
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

	my $ld_server_time = &subs::rightNow();
	my ($rm,$colour);

	if ($reason eq 'remote_update') {
		$path = &subs::home('~/.president/') . &subs::random_string_creator(21);
		$enc_file = $path . '.enc';

		$rm = &subs::db_select('remote_machines', undef, { signatorial => $c->param('signatorial') })->hashes->[0];
		$rm = &Manager::remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
		$colour = $rm->{'data'}->{'manager_colour'};
		my $html = '<h2>Being synced by ' . $rm->{'ip'} || $c->tx->remote_address . '</h2>';
		&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
		my $last_updated = &subs::db_query('select * from backups where reason=? and recipient = ? and signatorial = ? order by server_time DESC', 'remote_update',$c->param('signatorial'), $signatorial)->hashes->[0];
		my $last_update = 10;
		if ($c->param('gimme') =~ /[0-9]/gi) {
			$last_update = $c->param('gimme');
			$ld_server_time = $last_update;
		}
		elsif ($last_updated->{'server_time'}) {
			$last_update = $last_updated->{'server_time'};
			$ld_server_time = $last_update;
		}
		$ld_server_time = $ld_server_time - 20000;
		my $tables = `sqlite3 $database .tables`;
		my @tables = sort split ' ', $tables;
		my $schema_file = $temporary_path . '.schema.sql';
		`sqlite3 $database .schema > $schema_file`;
		my $command = `sqlite3 $temporary_path < $schema_file`;
		`shred -u $schema_file`;
#		my $backup = `sqlite3 $database .schema $temporary_path`;
		my $tsql = Mojo::SQLite->new('sqlite:' . $temporary_path);
		my $tdb = $tsql->db;

		foreach my $t ( @{$gb::forbidden->{'tables'}} ) {
			@tables = grep { $_ ne $t } @tables;
			$tdb->query('DROP TABLE ' . $t);
		}

		foreach my $d ( @tables ) {
			next if grep { $_ eq $d } @{$gb::forbidden->{'tables'}};
			my $new_data = &subs::db_query('select * from ' . $d . ' where server_time >= ?', $ld_server_time)->hashes;
			if (scalar @{$new_data} > 0) {
	#			$tdb->query('delete from ' . $d . ' where server_time < ?', $ld_server_time);
				foreach my $nd ( @{$new_data} ) {
					$tdb->insert($d, $nd);
				}
			} else {
				$tdb->query('DROP TABLE ' . $d);
			}
		}
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

	my $archive_path = $path . '_' . $timestamp;
	my $encrypt =	`openssl enc -e -k "$secret" -$encryption_standard -pbkdf2 -in $temporary_path -out $archive_path.enc`;
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
	$size = -s $archive_path . '.enc';
	my $raw_data;
	if ($size < 2000000) {
		$raw_data = read_file($archive_path . ".enc");
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
		raw_data => $raw_data
	};
	if ($reason eq 'remote_update') {
		$returner->{'update_commands'} = &Manager::update_database({ duty => 'list' });
	}
	&Websocket::send('tab', { yellow => 'close', 'close' => 'yes', uuid => $auuid, colour => $colour });
	return $returner;
}




sub sms_list_check() {
my $returner = '';
	if ($device eq 'mobile') {
		my $timestamp = &subs::rightNow();
		my $c = &subs::controller_builder();
		my $suds = &suds_grabber();
		$c->session('suds' => $gb::suds);
		my $json_list = `termux-sms-list -l 10 --message-sort-order="date DESC"` || '[]';
		my $list = decode_json $json_list;
		foreach my $l (grep { $_->{'type'} eq 'draft' || $_->{'type'} eq 'sent' || $_->{'type'} eq 'inbox' } @{$list}) {
			my $time = &subs::ago_calc($l->{'received'},$timestamp);
			my $phone = $l->{'number'};
			$phone =~ s/\D+//gi;
			$phone =~ s/^1//;
			$returner .= "Phone is " . $phone . "\n";
			my $res = &subs::db_query('select app from settings where setting = ? and value like ? and device = ?', 'phone', '%' . $phone, &subs::device_setter())->hashes;
			foreach my $r ( @{$res} ) {
				my $chats = &subs::db_select('mailbox', undef, { phone => $phone, timestamp => $time })->hashes;
				if ( scalar @{$chats} == 0) {
					$l->{'body'} =~ s/[^\x00-\x7F]+//gi;
					my $message = &subs::note_encrypter($suds,$l->{'body'});
					my $sender = &subs::format_name($r->{'app'});
					&subs::db_insert('mailbox', {
						uuid => &subs::random_string_creator(44),
						timestamp => $time,
						server_time => &subs::rightNow(),
						body => $l->{'body'}, #$message,
						manager_file => $sender,
						status => 'public', #$l->{'type'},
						phone => $phone,
					});
				}

				my $q = &subs::db_query('select * from appointments where app = ? and type = ? and timestamp = ?', $r->{'app'},'sms',$time);
				my $qu = $q->hashes;
				if ( scalar @{$qu} == 0 ) {
					$l->{'body'} =~ s/[^\x00-\x7F]+//gi;
					$returner .= "Phone: " . $phone . " - " . $r->{'app'} . "\n";
					&Manager::appointment_writer($c,{
						app => &subs::unformat_name($r->{'app'}),
						timestamp => $time || $timestamp,
						type => 'sms',
						notes => &subs::note_encrypter($suds,&subs::format_name($l->{'type'}) . ": " . $l->{'body'}),
						duration => 5000
					});
				}
				else {
					$returner .= "Seen " . $phone . " at " . $l->{'received'} . " from " . $r->{'app'} . " already\n";
				}
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

sub note_encrypter() {
	my ($secret,$content) = @_;
	if ($content) {
		$content =~ s/\r?\n$//;
		# Removed shell-quote escaping line since we no longer pass text to a shell
		my $md5 = md5_sum $content;
		$md5 = &shorthand_name($md5, 5);
		my $encryption_standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";

		# --- SECURE PIPELINE START ---
		# Pipe $content directly into openssl, then pipe openssl output into base64
		my ($ssl_out, $ssl_in, $b64_out, $b64_in);

		my $pid1 = open2($ssl_out, $ssl_in, 'openssl', 'enc', '-e', '-k', $secret, "-$encryption_standard", '-pbkdf2');
		my $pid2 = open2($b64_out, $b64_in, 'base64', '-w', '0');

		# Stream content to openssl
		print $ssl_in $content;
		close $ssl_in;

		# Stream openssl output to base64
		while (<$ssl_out>) {
			print $b64_in $_;
		}
		close $ssl_out;
		close $b64_in;

		# Collect final base64 string
		my $encrypted = do { local $/; <$b64_out> };
		close $b64_out;

		waitpid($pid1, 0);
		waitpid($pid2, 0);
		# --- SECURE PIPELINE END ---

		my $almost_ready = $encrypted . ':::---:::' . $encryption_standard . ':::---:::' . $md5;
		my $returner = &subs::encrypter($secret, $almost_ready);
		return $returner;
	}
}


sub note_decrypter() {
	my ($secret,$contented, $timestamp,$tries) = @_;
	my $sc = [];
	if ($timestamp) {
		my $q = &db_query('select * from security where level != ? and ost <= ? order by ost desc', 'padlock', $timestamp);
		$sc = $q->hashes;
	}
	if ($contented) {
		if (scalar @{$sc} > 0) {
			foreach my $s ( @{$sc} ) {
				my $tsecret = &decrypter($secret, $s->{'credential'} );
				my $content = &subs::decrypter($tsecret, $contented);
				my @returns = split ':::---:::', $content;
				my $encryption_standard = $returns[1];
				$content = $returns[0];

				# --- SECURE PIPELINE START ---
				my ($b64_out, $b64_in, $ssl_out, $ssl_in);

				my $pid1 = open2($b64_out, $b64_in, 'base64', '--decode');
				my $pid2 = open2($ssl_out, $ssl_in, 'openssl', 'enc', '-d', '-k', $tsecret, "-$encryption_standard", '-pbkdf2');

				print $b64_in $content;
				close $b64_in;

				while (<$b64_out>) {
					print $ssl_in $_;
				}
				close $b64_out;
				close $ssl_in;

				my $returner = do { local $/; <$ssl_out> };
				close $ssl_out;

				waitpid($pid1, 0);
				waitpid($pid2, 0);
				# --- SECURE PIPELINE END ---

				chomp $returner;
				if ($returner =~ /[A-Za-z0-9]/gi) {
					my $md5 = md5_sum $returner;
					if ($returns[2] && &shorthand_name($md5, 5) eq &shorthand_name($returns[2],5)) {
						return $returner;
					}
					elsif ($returns[2]) {
						next;
					}
					elsif ($returner !~ /[^\x00-\x7F]+/) {
						return $returner;
					}
				}
			}
		}
		else {
			my $content = &subs::decrypter($secret, $contented);
			my @returns = split ':::---:::', $content;
			my $encryption_standard = $returns[1];
			$content = $returns[0];

			# --- SECURE PIPELINE START ---
			my ($b64_out, $b64_in, $ssl_out, $ssl_in);

			my $pid1 = open2($b64_out, $b64_in, 'base64', '--decode');
			my $pid2 = open2($ssl_out, $ssl_in, 'openssl', 'enc', '-d', '-k', $secret, "-$encryption_standard", '-pbkdf2');

			print $b64_in $content;
			close $b64_in;

			while (<$b64_out>) {
				print $ssl_in $_;
			}
			close $b64_out;
			close $ssl_in;

			my $returner = do { local $/; <$ssl_out> };
			close $ssl_out;

			waitpid($pid1, 0);
			waitpid($pid2, 0);
			# --- SECURE PIPELINE END ---

			if ($returns[2] && md5_sum $returner eq $returns[2]) {
				chomp $returner;
				return $returner;
			}
			elsif ($returns[2]) {
				# Note: 'next' here will trigger a warning or error if outside a loop.
				# If intended to skip to the recursive step below, consider changing this behavior.
				next;
			}
			elsif ($returner !~ /[^\x00-\x7F]+/) {
				chomp $returner;
				return $returner;
			}
			else {
				if ($tries <= 2) {
					return &note_decrypter($secret,$contented,&subs::rightNow() * 10000, $tries + 1);
				}
			}
		}
	}
	return '';
}


sub manufacturer_grabber() {
	my $manufacturers = &subs::db_query('select * from settings where (setting = ? or setting = ?) and value = ? and device = ?', 'pos', 'mab','manufacturer',$device)->hashes;
	my $mans = [];
	foreach my $m ( @{$manufacturers} ) {
		push @{$mans}, $m->{'app'};
	}
	$gb::abilities->{'manufacturer'}->{'options'} = $mans;
}

sub embedded_wigi() {
	my $data = shift;
	my $ip = $data->{'ip'};
	my $timestamp = $data->{'timestamp'};
	my $edt = $data->{'edt'};
	my $chip_id = $data->{'chip_id'};

	my $watch = &subs::device_lister($timestamp, $edt, undef, $chip_id);
	if ($watch->{'ip'}) {
		my $s_data = { app => $edt, setting => 'operator_door', device => &subs::device_setter(), subsetting => $chip_id };
		my $wat_set = &subs::setting_grabber($s_data);
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
			my $last_step = 0;
			my (@measures,$first_step);
			foreach my $step ( @{$steps} ) {

				my $ls = $step->{'steps'};
				$step->{'steps'} = $step->{'steps'} - $last_step;

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
			if (scalar @measures > 0) {
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

sub setting_setter() {
	my $settings = shift;
	my $app = $settings->{'app'};
	my $original_app = $app;
	my $setting = $settings->{'setting'};
	my $subsetting = $settings->{'subsetting'};
	my $value = $settings->{'value'};
	my $timestamp = $settings->{'timestamp'} || &rightNow();
	my $browser_tab_id = $settings->{'browser_tab_id'};
	my $dev = $settings->{'device'} || &device_setter();
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
		&Websocket::send('server', { console => '$(".' . $app . '_close_button").trigger("click");', timestamp => $timestamp });
		&Websocket::send('server', { console => 'appointmentGrabber(\'' . $value . '\',\'' . $timestamp .'\',\'ws\');'});
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
	if ($setting eq 'pos' || $setting eq 'mab') {
		&Websocket::send('tab', { console => 'configurationReloader(\'' . $app . '\');' });
	}
	if ($setting eq 'phone') {
		$value =~ s/\D+//gi;
	}
	if ($setting eq 'web') {
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
	if ($setting eq 'toggle' && $settings->{'source'} eq 'panel') {
		&intelligent_automation_toggle({ app => $app });

	}
	if ($setting eq 'toggle') {
		if ($value eq 'on') {
			&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.enabler[type="toggle"\').attr(\'status\',\'' . $value . '\').attr(\'src\', \'/images/decipherable/' . $value . '.png\').css({\'background-color\': \'yellow\' });' });
		}
		else {
			&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.enabler[type="toggle"\').attr(\'status\',\'' . $value . '\').attr(\'src\', \'/images/decipherable/' . $value . '.png\').css({\'background-color\': \'grey\' });' });
		}
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

	my $old_set = eval { return &db_delete('settings', { app => $app, setting => $setting, device => $dev, subsetting => $subsetting }) };
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
			&Websocket::send('server', { console => '$(\'.top_navbar[app="' . $app . '"]\').css({\'background-color\':\'' . $value . '\'});' });
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
		&Websocket::send('server', { console => 'jawnosReloadIcons();' });
	}
	elsif ($setting eq 'tasks') {
		&subs::task_checker($app);
	}
	return { app => $app, timestamp => $timestamp, setting => $setting, value => $value, device => $dev, browser_tab_id => $browser_tab_id };
}

sub setting_grabber() {
	my $settings = shift;
	if ($settings->{'uuid'}) {
		my $s = &subs::db_select('settings', undef, { value => $settings->{'uuid'}, setting => 'uuid', subsetting => $settings->{'subsetting'} })->hashes->[0];
		$settings->{'app'} = $s->{'app'};
	}

	my $app = $settings->{'app'};
	my $device_defined = 0;
	$device_defined = 1 if $settings->{'device'};
	$settings->{'device'} = $settings->{'device'} || &device_setter();
	my $returner;

	if (my $q = eval { return &db_select('settings', ['value'], $settings) }) {
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
	return $returner;
}

sub settings_grabber() {
	my $settings = shift;
#	return {};

	if ($settings->{'uuid'}) {
		my $s = &subs::db_select('settings', undef, { value => $settings->{'uuid'}, setting => 'uuid', subsetting => $settings->{'subsetting'} })->hashes->[0];
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
			$q = &db_query($query, $app,$settings->{'device'}, @{$settings->{'settings'}});
		}
	}
	else {
		$q = &db_query($query, $app,$settings->{'device'});
	}
	my $list = $q->hashes;
	if ($settings->{'subsetting'}) {
		@{$list} = grep { $_->{'subsetting'} eq $settings->{'subsetting'} } @{$list};
	}
	foreach my $s ( @{$list } ) {
		$returner->{$s->{'setting'}} = $s->{'value'};
	}
	unless ($device_defined == 1 && $returner->{$settings->{'setting'}}) {
		my $liste = $q->hashes;
		foreach my $s (@{$liste}) {
			unless ($returner->{$s->{'setting'}}) {
				$returner->{$s->{'setting'}} = $s->{'value'};
			}
		}
	}
	unless ($returner->{'uuid'}) {
		if ($settings->{'benign'} != 1) {
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

					my $encrypt =	`openssl enc -e -k "$secret" -$encryption_standard -pbkdf2 -in $path -out $enc_path`;
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
	foreach my $filing ( @{$filings} ) {
		my $files = eval { return decode_json $filing->{'file'} } || [];
		foreach my $fi ( @{$files} ) {
			foreach my $file_type ( qw/f thumb/ ) {
				my $f = $fi->{$file_type};
				if (-e $f && $f =~ /\.enc/gi) {
					my $encryption_standard = $filing->{'encryption_standard'};
					my $enc_path = &subs::terminal_name($f);


					my $path = $enc_path;
					if ($fi->{'of'}) {
						my @f = split '/', $path;
						pop @f;
						push @f, $fi->{'of'};
						$path = join '/', @f;
					}
					$path =~ s/\.enc$//gi;
					my $passwords = &subs::db_query('select * from security where level != ? order by server_time DESC','padlock');
					my $pwords = $passwords->hashes;

					foreach my $p ( @{$pwords} ) {
						my $secret = &subs::decrypter($suds, $p->{'credential'});

						my $data = `openssl enc -d -k "$secret" -$encryption_standard -pbkdf2 -in $enc_path`;
						my $ft = File::Type->new();
						my $type_from_data = $ft->mime_type($data);
						my $head = `echo "$data" | head`;

						if ($type_from_data ne 'application/octet-stream' || ($data =~ /webm/)) {

							my $o = `openssl enc -d -k "$secret" -$encryption_standard -pbkdf2 -in $enc_path -out $path`;
							$f = $path;
							`shred -u $enc_path`;
							$success = 1;
							last;
						}
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

#	&subs::socket_cache_set($params,$data);
#	my $result = &db_select('cache', undef, $params);
#	return $result->hashes;
}

sub cache_delete() {
	my ($params) = @_;
	$params->{'device'} = $device;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $result = &db_delete('cache', $params);
	&subs::socket_cache_delete($params);
}

sub cache_get() {
	my ($params) = @_;
	#if (my $s = &subs::socket_cache_get($params)) {
	#	return $s;
	#}
	$params->{'device'} = $device;
	my $returner;
	my $results = &subs::db_select('cache', ['data'], $params)->hashes;
	my $result = $results->[0];
	my $json_data = $result->{'data'};
	if ($result->{'data'}) {
		$returner = eval { return decode_sereal $json_data };
	#	&subs::socket_cache_set($params,$returner);
		return $returner if $returner;
	}
}

sub socket_cache_get() {
	my ($params) = @_;
	my $tmp_dir = &subs::home('~/.president/');
	my $file = $tmp_dir . '/memory';
	my $returner = &unix_socket_sender($file, { duty => 'cache_get', params => $params }, 1);
	return $returner;
}

sub socket_cache_set() {
	my ($params,$data) = @_;
	my $tmp_dir = &subs::home('~/.president/');
	my $file = $tmp_dir . '/memory';
	my $returner = &unix_socket_sender($file, { duty => 'cache_set', data => $data, params => $params }, 1);
	return $returner;
}

sub socket_cache_delete() {
	my ($params) = @_;
	my $tmp_dir = &subs::home('~/.president/');
	my $file = $tmp_dir . '/memory';
	my $returner = &unix_socket_sender($file, { duty => 'cache_delete', params => $params }, 1);
	return $returner;
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

					$music_data = encode_base64 &subs::encrypter($c->session('suds'), $music_data);
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

sub newest_folder_checker() {
	my $files = &ide_files('./');
	my $newest = 0;
	foreach my $l ( @{$files} ) {
		if ($l->{'modified'} > $newest) {
			$newest = $l->{'modified'};
		}
	}
	return $newest * 1000;
}

my $ide_files = [];
sub ide_files() {
	my $folder = shift;
	$ide_files = [];
	find(\&ide_process_file,$folder);
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

sub ide_process_file() {
	my $name = $File::Find::name;
	$name =~ s/^\.\///g;
	push @{$ide_files}, $name;
}


our $database_holder;
our $database;
sub database_grabber() {
	my $connection = shift || '';
	# One connection per call. A process-wide handle looked like a free win, but a
	# single results object left unexhausted keeps that process's read snapshot
	# open for the rest of its life: the WAL never gets checkpointed (it grew to
	# the size of the database here) and later requests read stale pages. Dialling
	# per call is what this file did for years, and it is what the other writers on
	# this file (the mirror server, pen.pl, the device scripts) expect.
	if (defined $gb::database_holder->{'pid'} && $gb::database_holder->{'pid'} != $$ && defined $gb::database_holder->{'sql'} ) {
		# we are a fork of the process that owns the newest handle: detach it, or our
		# exit would close a connection our parent is still using
		$gb::database_holder->{'sql'}->db->dbh->{InactiveDestroy} = 1;
	}
	my $dir = &subs::home($config->{'start_dir'});
	$dir =~ s{/+$}{};
	my @databases;
	if (opendir my $dh, $dir) {
		@databases = map { "$dir/$_" } grep { /\.db$/i } readdir $dh;
		closedir $dh;
	}
	# newest first, same order the old `ls -t` gave -- but with no child processes
	@databases = sort { (-M $b) <=> (-M $a) } @databases;
	@databases = grep { -s $_ > 5000 } @databases;
	my $database = $databases[0];

	if ($database) {

		my $sql = Mojo::SQLite->new('sqlite:' . $database, sqlite_use_immediate_transaction => 0);
		$sql->options({AutoCommit => 1 });
		my $db = $sql->db;
		# Keep the newest handle on the holder only so a forked child can detach from
		# it and hooks.pl can tell that a database is up.
		$gb::database_holder = {
			server_time => &subs::rightNow(),
			database => $database,
			db => $db,
			sql => $sql,
			pid => $$
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
		return ($db,$database,$sql);
	}
	$gb::database_holder = {};
	return (undef,undef,undef);
}

sub dbs_insert {
  my $table = shift;
  my $data = shift;

  $data->{'ost'} = $data->{'ost'} || &rightNow();
  $data->{'server_time'} = $data->{'server_time'} ? $data->{'server_time'} : $data->{'ost'};
  $data->{'uuid'} = &random_string_creator(15) unless $data->{'uuid'};
  my $res = &subs::unix_socket_sender('memory', {
      duty  => 'insert',
      table => $table,
      data  => $data,
			db => 'disk'
  }, 1);

  return $res->{data}->{last_insert_id};
}

sub db_insert() {
	my $table = shift;
	my $data = shift;
	$data->{'ost'} = $data->{'ost'} || &rightNow();
	$data->{'server_time'} = $data->{'server_time'} ? $data->{'server_time'} : $data->{'ost'};
	$data->{'uuid'} = &random_string_creator(15) unless $data->{'uuid'};
	my ($db,$database,$sql) = &database_grabber();
	return unless $db;
	my $lid = undef;
	my $success;
	my $count = 0;
	until ($lid || $count >= 25) {
		$success = eval { return $db->insert($table, $data); };
		$lid = eval { return $success->last_insert_id };
		unless ($lid) {  }
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


sub db_update() {
	my $table = shift;
	my $data = shift;
	my $params = shift;
	my ($db,$database,$sql) = &database_grabber();
	$data->{'server_time'} = &subs::rightNow() unless $data->{'server_time'};
	&db_cache_updater($table, $params);
	return $db->update($table, $data, $params) if $db;
}

sub dbs_update {
  my $table = shift;
  my $data = shift;
  my $params = shift;

  $data->{'server_time'} = &subs::rightNow() unless $data->{'server_time'};

  return &subs::unix_socket_sender('memory', {
    duty   => 'update',
    table  => $table,
    data   => $data,
    params => $params,
		db => 'disk'
  }, 1);
}


sub dbs_delete {
  my $table = shift;
  my $params = shift;
  return &subs::unix_socket_sender('memory', {
    duty   => 'delete',
    table  => $table,
    params => $params,
		db => 'disk'
  }, 1);
}

sub db_delete() {
	my $table = shift;
	my $params = shift;

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
	$h = (($h % 360) + 360) % 360;
	my $c = (1 - abs(2 * $l - 1)) * $s;
	my $x = $c * (1 - abs((($h / 60) % 2) - 1));
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
sub contrast_ink {
	my ($bg) = @_;
	return '#000000' unless defined $bg && $bg =~ /^\#?([0-9a-fA-F]{6})$/;
	my ($r, $g, $b) = map { hex } ($1 =~ /(..)(..)(..)/);
	my $lum = (0.2126 * $r + 0.7152 * $g + 0.0722 * $b) / 255;
	return $lum < 0.5 ? '#ffffff' : '#000000';
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
		return '--ink:#000000;--ink-muted:#333333;--panel:#ffffff;--panel-2:#f0f0f0;';
	}
	my $lum = (0.2126 * $r + 0.7152 * $g + 0.0722 * $b) / 255;
	my ($h, $s, $l) = &_rgb_to_hsl($r, $g, $b);
	my $tint = $s < 0.18 ? $s : 0.18;
	if ($lum < 0.5) {
		my $panel = &_hsl_to_hex($h, $tint, 0.16);
		my $panel2 = &_hsl_to_hex($h, $tint, 0.23);
		return "--ink:#f2f2f2;--ink-muted:#cccccc;--panel:$panel;--panel-2:$panel2;";
	}
	my $panel = &_hsl_to_hex($h, $tint, 0.88);
	my $panel2 = &_hsl_to_hex($h, $tint, 0.80);
	return "--ink:#000000;--ink-muted:#333333;--panel:$panel;--panel-2:$panel2;";
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

# A fingerprint of everything that gets baked into cached window/header HTML:
# the icon set and the device's theme colours. Cached renders whose signature no
# longer matches are discarded, so closed windows don't come back looking stale.
sub render_signature() {
	my $device = &device_setter();
	my $config = &config_reader();
	my @parts = ( &icon_set() || '' );
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

sub signatorial_establisher() {
	my $context = shift;
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

sub signatorial_designer() {
	my $designation = shift;
	if (!$designation && $gb::signatorial) {
		return $gb::signatorial;
	}
	my $folder = './public/images/jonathans';
	my $jonathans = `ls $folder`;
	my @jonathans = split /\n/, $jonathans;
	my $checksum = $database;
	if ($designation eq 'neighbour_link') {

	}
	foreach my $j ( @jonathans ) {
		$j = &terminal_name($folder . '/' . $j);
		$checksum .= encode_base64 `cat $j`;
	}
	my $md5 = md5_sum &signatorial_establisher('designer') . $checksum;
	$gb::signatorial = $md5;

	return $gb::signatorial;
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
	my $last_location = &subs::db_query('select * from continent order by server_time desc')->hashes->[0];
	my $now = &subs::rightNow();
	my $navigation_due = [];
	my $running_appts = &subs::db_query('select app,uuid,type,warranty from appointments where type = ? or type = ? and timestamp < ?', 'start', 'record', $now)->hashes;
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
		if ($now - $last_location->{'server_time'} > $gb::timeouts->{'navigation'}->{'interval'} * 1000) {
			if (&subs::device_setter() eq 'mobile') {
				my $jloc = `termux-location`;
				my $loc = eval { return decode_json $jloc } || {};
				if ($loc->{'latitude'} && $loc->{'elapsedMs'} < 1000 && $loc->{'accuracy'} < 100) {
					$returner->{'latitude'} = $loc->{'latitude'};
					$returner->{'longitude'} = $loc->{'longitude'};
					$returner->{'accuracy'} = sprintf("%.2F", $loc->{'accuracy'});
					&subs::db_delete('continent', { type => 'temporary', signatorial => $signatorial });
					my $treturner = clone $returner;
					$treturner->{'uuid'} = &subs::random_string_creator(31);
					&subs::db_insert('continent', $treturner);
					$written = 1;
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
	}
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
										&subs::db_update('appointments', {
											type => $hp->{'action'},
											stop_timestamp => undef,
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
								my $lappts = &subs::db_query('select uuid,app,timestamp,server_time from appointments where app=? and (type = ? or type =?) and timestamp < ?', $app, 'start','record',$returner->{'timestamp'})->hashes;
								foreach my $lappt ( @{$lappts} ) {
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
								my $lappts = &subs::db_query('select uuid,app,timestamp,server_time from appointments where app=? and (type = ? or type =?) and timestamp < ?', $app, 'start','record',$returner->{'timestamp'})->hashes;
								foreach my $lappt ( @{$lappts} ) {
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
	@{$returner} = sort { $a->{'app'} cmp $b->{'app'} } @{$returner};
	&subs::subprocessor(sub {
		foreach my $clothes ( @{$returner} ) {
			&Manager::centre_view_grabber({ app => &subs::unformat_name($clothes->{'app'}), timestamp => &subs::rightNow() });
		}
	}, { name => 'clothesline centreview cacher' });
	my $jreturner = encode_json $returner;
	&setting_setter({ app => '__president', setting => 'clothesline', value => $jreturner });
	return 0;

}

sub headless_browser() {
	my $changes = 0;
	my $signatorial = &subs::signatorial_designer();
	my $recurring_websites = &subs::db_query('select * from settings where setting=? and device=? and value is not null and value != ?', 'web_recurring', $device, '')->hashes;
	foreach my $rw ( @{$recurring_websites} ) {
		my $app = $rw->{'app'};
		my $able_devices = &subs::db_query('select * from settings where app=? and setting=? and (value=? or value = ? or value=?) and device=?', $app, 'web_headless_device', $device, $signatorial, 'all', $device)->hashes;
		if (scalar @{$able_devices} > 0) {
			my $websites = &subs::db_query('select * from settings where app=? and setting=? and device = ?', $app, 'web', $device)->hashes;

			foreach my $w ( @{$websites} ) {
				my $history = &subs::db_query('select * from websites where app=? and url=? order by timestamp desc',$app, $w->{'value'})->hashes;
				my $last_run = 0;
				if ($history->[0]) {
					$last_run = $history->[0]->{'timestamp'};
				}
				my $recurrence = &time_abbrev_translator($rw->{'value'}) || '1M';

				if (&subs::rightNow() - $last_run > $recurrence) {

					my ($window,$internal_url,$uuid,$timestamp) = &Manager::website_grabber({
						app => $app,
						website => $w->{'value'},
						timestamp => &subs::rightNow(),
						user_agent => $gb::user_agent,
					});
					$changes = 1;
				}
			}
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

	return unless $device eq 'mobile';

	my $jcontacts = `termux-contact-list`;
	my $contacts = eval { return decode_json $jcontacts } || [];
	foreach my $contact ( @{$contacts} ) {
		my $name = &subs::unformat_name($contact->{'name'});
		my $number = $contact->{'number'};
		$number =~ s/\D+//gi;

		my $phones = &subs::settings_grabber({ app => $name, settings => ['phone', 'uuid' ] });

		if ($phones->{'uuid'} && $phones->{'phone'} ne $number) {
			my $settings = &subs::setting_initializer($name,&subs::rightNow());
			my $data = { app => $settings->{'app'}, setting => 'phone', value => $number };

			&subs::setting_setter($data);
		}
	}
}

sub telephone_call_log_check() {

	return unless $device eq 'mobile';

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


		my $phone = &subs::db_query('select * from settings where setting=? and value like ?', 'phone', '%' . $number)->hashes->[0];

		if ($phone->{'app'}) {
			my $appts = &subs::db_query('select * from appointments where app=? and timestamp = ?', $phone->{'app'}, $timestamp)->hashes;
			unless (scalar @{$appts} > 0) {
				my $data = {
					app => $phone->{'app'},
					type => 'start',
					duration => '-' . $duration,
					timestamp => $timestamp,
					stop_timestamp => ($timestamp + $duration),
					seen => 'yes',
					subtype => 'phone'
				};

				my $c = &subs::controller_builder();
				&Manager::appointment_writer($c,$data);
			}
		}
	}
}

sub appt_toggle_checker() {
	my $app = shift;
	return unless $app;
	my $server_time = &subs::rightNow();
	my $toggle = 'off';
	# only the existence of an open start/record matters, so stop at the first one
	my $appts = &subs::db_query('select 1 as found from appointments where app=? and (type=? or type=?) and timestamp <= ? limit 1', $app, 'start','record',$server_time)->hashes;

	$toggle = 'on' if scalar @{$appts} > 0;
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

				my $md5_uuid = md5_sum $running_appt->{'uuid'} . '-' . $running_appt->{'timestamp'} . '-' . $timestamp . '-' . $task->{'task'} . $data->{'project'} . $data->{'account'} . $data->{'movement'};
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

	# a mirror entry is how a machine the source knows about is reached through
	# it; when that machine already has a row of its own the list would show the
	# same machine twice (once, three times, with overlapping mirror sources),
	# so a mirror is only added when it is not otherwise present. One identity
	# per machine - uuid beats signatorial beats ip, so a tunnelled machine's
	# 127.0.0.1 can never collide with another entry.
	my %already;
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
			#	$mirror = &rm_tunnel_processor($mirror);
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
	return $rm;
}

sub remote_machine_negotiator() {
	my $data = shift;
	$gb::suds = &suds_grabber();
	my $c = &subs::controller_builder();
	$c->session('suds' => $gb::suds);
	$c->session('gimme' => $data->{'gimme'});


	my $remote_upgrade = &subs::setting_grabber({ app => '__president', setting => 'remote_upgrade' });
	my $remote_connect_timer =  &subs::setting_grabber({ app => '__president', setting => 'remote_connect_timer' }) || 0;
	if ($remote_connect_timer + (60 * 7 * 1000) < &subs::rightNow()) {
		&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
	}
	if ($remote_upgrade ne 'running' && $remote_connect_timer + 10000 < &subs::rightNow()) {
		&Manager::remote_machine_reconnector($c);
	}
	#&system_monitor({
	#	timeout => 'remote_machine_sync',
	#});
}


sub tunnel_starter() {
	my $data = shift;
	my $ip = $data->{'ip'};
	my $signatorial = $data->{'signatorial'};
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
			my $password = &subs::decrypter(&subs::suds_grabber(), $rm->{'password'});
			foreach my $r (@gb::ports ) {
				my $command = 'sshpass -p "' . $password . '" ssh -o "ServerAliveInterval 9" -o "ServerAliveCountMax 1" -N -R ' . $rb->{$r}->{'source'} . ':localhost:' . $rb->{$r}->{'dest'} . ' ' . $rm->{'username'} . '@' . $rm->{'ip'} . ' -p ' . $port;

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
				$tunnel->{'ip'} = $config->{'domain'};
				my $url = $rm->{'manager'} . '/manager/configure/remote_machine/tunnel/confirm';
				my $jtunnel = encode_json $tunnel;
				my $form_data = {
					signatorial => &subs::signatorial_designer(),
					tunnel => $jtunnel,
					status => $status,
					uuid => $uuid
				};
				my $res = $rm->{'ua'}->post($url => form => $form_data)->result;
				if ($res->is_success) {
					my $pid;

					&subs::subprocessor(sub {

						$pid = $$;

						&subs::db_update('tunnels', { process_id => $pid, server_time => &subs::rightNow(), status => 'active' }, { uuid => $uuid });
						my $old_ps = `ps -e`;
						`$command`;

						my $new_ps = `ps -e`;
					}, { name => 'tunnel holder ' . $rb->{$r}->{'source'} . ':' . $rm->{'ip'} . ':' . $rb->{$r}->{'dest'} });

				}

			}


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
							my $ps_check = `ps -e | grep $ps`;
							next if grep { $tun->{'signatorial'} eq $_ || $tun->{'batch_uuid'} eq $_  } @{$batches};
							push @{$batches}, $tun->{'signatorial'};
							my $chip_chyea = &subs::random_string_creator(200);
							my $signatorial = $tun->{'signatorial'};
							my $rm = &Manager::remote_useragent_maker({ signatorial => $signatorial });
							my $url = $rm->{'manager'} . '/manager/tunnel/alive';
							my @batch = grep { $_->{'batch_uuid'} eq $tun->{'batch_uuid'} } @{$tunnels};
							my $form_data = {
								signatorial => &subs::signatorial_designer(),
								chip_chyea => $chip_chyea,
								network => encode_json &subs::network_interface_reporter(),
								interval => $data->{'interval'},
								tunnel => encode_json \@batch
							};
							$rm->{'ua'}->inactivity_timeout(23);
							my $res = $rm->{'ua'}->post($url => form => $form_data)->result;
							my $status = 'unknown';
							if ($res->is_success) {
								if (eval { return decode_json $res->body }) {
									my $chippity = &subs::setting_grabber({ app => '__president', subsetting => $tun->{'signatorial'}, setting => 'chip_chyea' });
									if ($chip_chyea eq $chippity) {
										$status = 'connected';
										my $response = decode_json $res->body;
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
										else {
										}
									}
								}
							}
							if ($status ne 'connected' || $data->{'duty'} eq 'restart') {
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


sub suds_grabber() {
	my $duty_time = &subs::setting_grabber({ app => '__president', setting => 'remote_duty' });
	if (( !$gb::suds || $duty_time eq '' || !$duty_time || $duty_time != $gb::duty_time || !$gb::duty_time)) {
		my ($db,$database,$sql) = &subs::database_grabber('new');

	#	my $duty_file = &subs::home('~/.president/on_duty');
	#	$gb::duty_time = read_file($duty_file);
		&subs::setting_setter({ app => '__president', setting => 'remote_duty', value => $gb::duty_time });
		my $tick = &subs::db_query('select verification,secret,password,suds from tickets where status=? order by server_time desc', 'active');
		my $ticke = $tick->hashes;
		my $ticket = $ticke->[0];
		my $v = $ticket->{'verification'};
		my $secret = $ticket->{'secret'};
		my $ver = url_unescape `echo "$secret" | base64 --decode`;
		my $verification = &subs::note_decrypter($ticket->{'password'}, $ver);
		my $vrai = eval { return decode_json $verification } || {};
		$secret = &subs::decrypter($vrai->{'p'},&subs::db_select('security', ['credential'], { level => 1 })->hash->{credential});
		my $suds = &subs::note_decrypter($vrai->{'p'}, $ticket->{'suds'});
		$gb::suds = $suds;
		return $suds;
	}
	return $gb::suds;
}

sub c_maker() {
	my $c = &subs::controller_builder();
	my $suds = &subs::suds_grabber();

	$c->session('suds' => $suds);
	$c->session('server_time' => &subs::rightNow());
	$c->session('authentication' => 'approved');

	return $c;
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

	my $c = &subs::controller_builder();
	my $email_servers = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	@{$email_servers} = grep { $_->{'active'} eq 'on' } @{$email_servers};

	foreach my $es ( @{$email_servers} ) {

		my $password = &subs::note_decrypter(&subs::suds_grabber(), $es->{'password'});
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
		$imap->login or next;

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
					my $subject = $sum->subject;
					my $checked_addresses = &subs::db_query('select * from settings where setting=? and (value=? or value=? and value != ?) and device=?', 'email', $from, $to, $es->{'email'}, $device)->hashes;
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
						foreach my $part ($entity->parts) {

							my $filename = $part->head->recommended_filename;
							if ($filename) {


								my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $filename, app => $ca->{'app'}, is_thumb => 0 });
								copy($gb::tmp_dir . '/' . $filename, $destination . $asset);
								my $u_data = { server_time => &subs::rightNow(), f => $destination . $asset, uuid => &subs::random_string_creator(28), type => $type };
								my $thumb = $destination . '/thumbs';
								if ($type eq 'image') {
									`mkdir -p $thumb` unless -e $thumb;
									$u_data->{'thumb'} = $thumb . '/' . $asset;

								}
								push @{$files}, $u_data;

							}
						}
						my $app_uuid = &subs::random_string_creator(31);
						my $jfile = scalar @{$files} > 0 ? encode_json $files : undef;
						my $appt_data = {
							app => $ca->{'app'},
							type => 'email',
							timestamp => $timestamp,
							notes => &subs::note_encrypter(&subs::suds_grabber(), $body),
							file => $jfile
						};
						&Manager::appointment_writer($c,$appt_data);

						my $status = 'inbox';
						my $email = $from;
						if ($to ne $es->{'email'}) {
							$status = 'sent';
							$email = $to;
						} elsif (lc $f eq 'drafts') {
							$status = 'draft';
						}
						my $email_data = {
							uuid => &subs::random_string_creator(44),
							timestamp => $timestamp,
							server_time => &subs::rightNow(),
							body => &subs::note_encrypter(&subs::suds_grabber(), $body),
							manager_file => $es->{'email'},
							subject => &subs::note_encrypter(&subs::suds_grabber(), $subject),
							status => $status,
							email => $email,
							email_server => $es->{'uuid'},
							attachments => $jfile
						};
						&subs::db_insert('mailbox', $email_data);
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

sub email_sender() {
	my $outbox = &subs::db_query('select * from mailbox where status=? and timestamp <= ? and sender = ?', 'outbox', &subs::rightNow(), &subs::device_setter())->hashes;
	foreach my $o ( @{$outbox} ) {
		&subs::db_update('mailbox', { status => 'sending', server_time => &subs::rightNow() }, { uuid => $o->{'uuid'} });
		my $result = &email_send({
			from => $o->{'from_email'},
			email => $o->{'email'},
			subject => $o->{'subject'},
			body => $o->{'body'},
			attachments => $o->{'attachments'},
			uuid => $o->{'uuid'},
		});
	}
}


sub email_send() {
	my $data = shift;

	my $c = $data->{'c'} ? $data->{'c'} : &subs::c_maker();
	my $suds = $c->session('suds');
	$data->{'attachments'} = [] unless $data->{'attachments'};
	my $email_server = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	return { result => 'no server' } if scalar @{$email_server} == 0;
	@{$email_server} = grep { $_->{'uuid'} eq $data->{'from'} } @{$email_server};
	return { result => 'server no longer exists' } if scalar @{$email_server} == 0;
	my $es = $email_server->[0];
	my $smtp_data = {
		host          => $es->{'smtp_server'},
		port          => $es->{'smtp_port'},
		ssl           => $es->{'smtp_encryption'} eq 'SSL' ? 1 : 0,
		sasl_username => $es->{'email'},
		sasl_password => &subs::note_decrypter($suds, $es->{'password'}),
	};
	my $transport = Email::Sender::Transport::SMTP->new($smtp_data);
	my $stuffer = Email::Stuffer
		->from(&subs::format_name($es->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'my_name' })) . ' <' . $es->{'email'} . '>')
		->to($data->{'email'})
		->subject(&subs::note_decrypter($suds, $data->{'subject'}))
		->transport($transport);

	my $dom = Mojo::DOM->new(&subs::note_decrypter($suds, $data->{'body'}));

	if ($dom->find('*')->size > 0) {
		$stuffer->html_body(&subs::note_decrypter($suds, $data->{'body'}));
	}
	else {
		$stuffer->text_body(&subs::note_decrypter($suds, $data->{'body'}));
	}
	$data->{'attachments'} = eval { return decode_json $data->{'attachments'} } || [];
	my @locations;
	foreach my $att ( @{$data->{'attachments'}} ) {
		if ($att->{'type'} eq 'printer') {
			my $att_url = $att->{'printer'}->{'qr_code'};
			my $loc = $gb::tmp_dir . '/' . &subs::format_name($att->{'printer'}->{'type'}) . ' ' . $att->{'printer'}->{'id'} . '.pdf';
			push @locations, $loc;
			my $command = 'weasyprint "' . $att_url . '" "' . $loc . '"';
			`$command`;
			$stuffer->attach_file($loc);
		}
		else {

			my $file = $att->{'file'};
			my $app = $att->{'app'};
			my ($destination,$asset,$type,$fapp) = &subs::file_device_renamer({ file => $file->{'f'}, app => $app, type => $file->{'type'} });

			$c->param('file' => $destination . $asset);
			$c->param('duty' => 'collection');
			my $job = &Manager::rock_and_roll($c);

			$stuffer->attach($job->{'data'}, filename => $file->{'of'} || $asset, content_type => $job->{'fd'});
		}
	}

	my $result = $stuffer->send;

	if ($result->message =~ /2.0.0 OK/gi) {
		$result = 'success';
		&subs::db_delete('mailbox', { status => 'draft', uuid => $data->{'uuid'} });
		&subs::db_update('mailbox', { status => 'sent', timestamp => &subs::rightNow(), server_time => &subs::rightNow() }, { uuid => $data->{'uuid'} });
	} else {
		$result = 'fail';
	}
	foreach my $loc ( @locations ) {
		`shred -u "$loc"`;
	}
	return $result;
}

sub pen_message() {
	my $data = shift;
	my $msg = $data->{'msg'};
	my $msg_data = $data->{'msg_data'};
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'cloudflare_account', 'cloudflare_token', 'ollama_key', 'visual_assistant', 'chatbot_conversation', 'chatbot_conversations', 'chatbot_model', 'chatbot_system_message' ] });
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
	my $payload = {
		  model    => $model, # Replace with your installed model
		  messages => [
		      { role => 'system', content => $data->{'system_msg'} || $conversation->{'chatbot_system_message'} },
		     	@{$history}
		  ],
		  stream   => \1 # Tells Ollama to stream the response (JSON true)
	};
	# Ollama Chat API Endpoint
	my ($key,$url);
	if ($model =~ /^\@cf/ && $settings->{'cloudflare_account'} && $settings->{'cloudflare_token'}) {
		$url = 'https://api.cloudflare.com/client/v4/accounts/'. $settings->{'cloudflare_account'} . '/ai/run/' . $model;
		$key = &subs::note_decrypter(&subs::suds_grabber(), $settings->{'cloudflare_token'});
	} else {
		$url = 'http://localhost:11434/api/chat';
		$key = &subs::note_decrypter(&subs::suds_grabber(), $settings->{'ollama_key'});
		$payload->{'options'} = {
			num_thread => $nproc - 2,
			num_ctx    => 32768
		},
	}

	$log->info($url);
	my $tx = $ua->build_tx(POST => $url => {
			'Authorization' => "Bearer $key",
			'Content-Type'  => 'application/json'
		} => json => $payload);

	# 2. Maintain a tiny string buffer for incomplete stream chunks
	my $buffer = '';
	my $is_generating_image = 0;
	my $image_prompt_buffer = '';
	my $accumulated_text = '';
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
	          if ($accumulated_text =~ /dalle\.text2/ || $is_generating_image) {

							if ($is_generating_image == 0) {
								$image_prompt_buffer = $accumulated_text;
							}
							else {
	              $image_prompt_buffer .= $text;
							}
            	$is_generating_image = 1;
          	}


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
	my $attachments = [];
	if ($is_generating_image == 1) {
		$image_prompt_buffer =~ s/<br>//gi;
		my $action = eval { return decode_json $image_prompt_buffer };
		my $action_input = eval { return decode_json $action->{'action_input'} };
		my $extracted_prompt = $action_input->{'prompt'};

		if ($extracted_prompt) {

	    my ($image_url,$attachment) = &generate_ai_image({
				ua => $ua,
				prompt => $extracted_prompt,
				msg_uuid => $data->{'uuid'},
				settings => $settings,
				model => $model,
				conversation => $conversation,
				mail_contact => $mail_contact
			});
	    $attachments = $attachment if $attachment;
	    if ($image_url) {
        my $html_img = '<img src="' . $image_url . '" class="chat-generated-img" style="width:100%;"/><br>';
        $accumulated_text = $html_img;
				$response_text = $html_img;
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
						console => '$(\'.assistant_content[uuid="' . $data->{'uuid'} . '"]\').html(\'' . $accumulated_text . '\');'
					});
				}
	    }
		}
		# Reset markers and clear buffer strings
		$is_generating_image = 0;
		$image_prompt_buffer = '';
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
sub generate_ai_image {
  my ($data) = @_;
	my $c = &subs::controller_builder();
	my $msg_uuid = $data->{'msg_uuid'};
  my $ua       = $data->{'ua'};
  my $prompt   = $data->{'prompt'};
  my $settings = $data->{'settings'};
	my $conversation = $data->{'conversation'};
	my $mail_contact = $data->{'mail_contact'};
	my $start_timestamp = &subs::rightNow();
	my $app = $mail_contact;
	if ($conversation->{'chatbot_conversation_name'}) {
		$app = $conversation->{'chatbot_conversation_name'};
	}
	$app = &subs::unformat_name($app);

  $log->info(Dumper $data);
  # Fetch your Cloudflare Account ID and Token out of your app settings
  my $cf_account_id = $settings->{'cloudflare_account'};
  my $cf_token      = &subs::note_decrypter(&subs::suds_grabber(), $settings->{'cloudflare_token'}); # or cf_token
	$log->info($cf_account_id . ' ' . $cf_token);
  if ($cf_account_id && $cf_token) {
		$log->info('got the account id and token');
		# Endpoint using Stable Diffusion XL Base
		my $model = $settings->{'text_to_image_assistant'} || '@cf/stabilityai/stable-diffusion-xl-base-1.0';
		my $url = 'https://api.cloudflare.com/client/v4/accounts/' . $cf_account_id . '/ai/run/' . $model;
		$log->info($url);
		my $payload = { prompt => $prompt };

		my $tx = $ua->post($url => {
		    'Authorization' => "Bearer $cf_token",
		    'Content-Type'  => 'application/json'
		} => json => $payload);
		$log->info('after call');
		if (!$tx->error) {
		  # Cloudflare responds directly with image/png or image/jpeg binary stream
		  my $binary = $tx->result->body;
			my $folder;
			my $location;
			my $filename = 'img_' . &subs::rightNow() . '.png';
			my $upload_type = 'image';
			my $ft = File::Type->new();
			my $fd = $ft->checktype_contents($binary);
			if ($fd =~ /image/) {
				$upload_type = 'image';
				$folder = &subs::setting_grabber( { app => 'misc', setting => 'photo_location', device => $device } );
				$location = &subs::home($folder) . '/' . $app;
				my $location = $folder . '/' . $app;
			}


		  my $public_dir = $location || &subs::home('~/Public/generated_images');
		  `mkdir $public_dir` unless -d $public_dir;

		  my $file_path = $public_dir . '/' . $filename;
		  write_file($file_path, $binary);
			my $ocr;
			if ($fd =~ /image/) {
				my $resolution = &subs::setting_grabber({ app => 'misc', setting => 'photo_size' } ) || '1920x1080';
				`magick $file_path -resize $resolution $file_path` unless lc $resolution eq 'raw';
				$ocr = &Manager::ocr_reader($c,$file_path);
			}
			my $appt_uuid = &subs::random_string_creator(33);
			my $file_uuid = &subs::random_string_creator(21);
			my $u_data = [{ server_time => &subs::rightNow(), appt_uuid => $appt_uuid, mail_uuid => $msg_uuid, ocr => $ocr, f => $file_path, uuid => $file_uuid, type => $upload_type }];
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
			&Manager::appointment_writer($c,$write);
			&subs::file_encrypter({ app => &subs::unformat_name($app) });
			&Manager::centre_view_grabber({ c => $c, app => &subs::unformat_name($app), timestamp => &subs::rightNow(), cached => 'no' });

		  return ('/file_open?appt_uuid=' . $appt_uuid . '&file_uuid=' . $file_uuid . '&app=' . $app,$u_data);
		} else {
		  $log->error("Cloudflare Generation Failed: " . $tx->error->{message});
		  return undef;
		}
	}
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

1;
