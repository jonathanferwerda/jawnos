package subs;

# Calendar: extracted from subroutines.pl (package subs). Loaded on
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
use IO::Select;
BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../.." if $dir && -d "$dir/../..";
}
use JawnOS::Transport;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Socket qw(MSG_PEEK MSG_DONTWAIT);
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our %M;
our $cached_sockets;
our $config;
our $database;
our $decoder;
our $deferred_children;
our @deferred_jobs;
our $encoder;
our $gb;
our %interval_words;
our $log;
our %m;
our $random_seeded_for;
our $request_busy_depth;
our $say_quiet;
our $socket_retry;
our $time_odd_spans;
our %time_span_table;
our $time_units;

# Move a moment by whole calendar units. Months and years keep the day of the
# month, shortening to the month's last day when it is shorter (31 January ->
# 28 or 29 February) and returning to $anchor_day on later months when one is
# given (28 February -> 31 March). Days and weeks step through the local
# calendar, so daylight saving neither drifts the hour nor shortens a day.
sub calendar_shift {
	my ($timestamp, $count, $unit, $anchor_day) = @_;
	$timestamp = 0 unless defined $timestamp;
	$count = 0 unless defined $count;
	$unit = lc($unit || 'day');
	return $timestamp unless $count;
	my @lt = localtime(int($timestamp / 1000));
	my ($sec, $min, $hour, $mday, $mon, $year) = @lt[0 .. 5];
	if ($unit eq 'month' || $unit eq 'year') {
		$mday = $anchor_day + 0 if defined $anchor_day && $anchor_day;
		my $months = $unit eq 'year' ? $count * 12 : $count;
		$months = int($months);
		return $timestamp unless $months;
		my $index = ($year + 1900) * 12 + $mon + $months;
		my $nyear = int($index / 12);
		my $nmon = $index % 12;
		if ($nmon < 0) { $nmon += 12; $nyear--; }
		my $last = &days_in_month($nyear, $nmon + 1);
		$mday = $last if $mday > $last;
		# Give Time::Local the whole year, never the years-since-1900 offset: it
		# reads an offset of 0..99 as a rolling two-digit year around today, so
		# 1951 (51) came back as 2051 and a seventy-five year shift fell on the
		# wrong century. A four-figure year is taken literally.
		return timelocal($sec, $min, $hour, $mday, $nmon, $nyear) * 1000;
	}
	my $days = $unit eq 'week' ? $count * 7 : ($unit eq 'day' ? $count : 0);
	if ($days) {
		my $whole = int($days);
		my $fraction = $days - $whole;
		my @date = gmtime(timegm(0, 0, 0, $mday, $mon, $year + 1900) + $whole * 86400);
		return timelocal($sec, $min, $hour, @date[3, 4], $date[5] + 1900) * 1000 + $fraction * 86400000;
	}
	my $seconds = $count * ($unit eq 'hour' ? 3600 : $unit eq 'minute' ? 60 : 1);
	return $timestamp + $seconds * 1000;
}

sub timespan_widener {
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

sub appt_alarm_setter {
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
	# An appointment built by a caller that omitted a time (the model rows a
	# tick builds) reached this comparison undefined: every call warned twice and
	# wrote both lines to the log, which on a phone was a steady stream of I/O to
	# decide nothing. A missing or non-numeric time is simply not due yet.
	if (grep { defined $_ && $_ =~ /^\d+$/ && $_ >= &subs::rightNow() - 5000 } @times) {
		my $file = $gb::tmp_dir . '/alarm';
		eval {
			my $socket = JawnOS::Transport::client_socket('alarm', path => $file)
				or die "Socket connection failed: $!";
			$socket->autoflush(1);

			my %payload = ref $appt eq 'HASH' ? %{$appt} : ();
			$payload{'__transport_token'} = JawnOS::Transport::token()
				if JawnOS::Transport::tcp();
			my $jwsm = encode_json \%payload;
			print $socket $jwsm . "\n";
		};
	}
};

sub next_appointment_time {
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
		push @{$next_values}, { app => $next_appt->{'app'}, uuid => $next_appt->{'uuid'}, timestamp => $next_appt->{'timestamp'} } if defined $next_appt->{'timestamp'} && $next_appt->{'timestamp'} >= $last_moment;
		push @{$next_values}, { app => $next_appt->{'app'}, uuid => $next_appt->{'uuid'}, timestamp => $next_appt->{'stop_timestamp'} } if defined $next_appt->{'stop_timestamp'} && $next_appt->{'stop_timestamp'} >= $last_moment;
		push @{$next_values}, { app => $next_appt->{'app'}, uuid => $next_appt->{'uuid'}, timestamp => $next_appt->{'next_duty'} } if defined $next_appt->{'next_duty'} && $next_appt->{'next_duty'} >= $last_moment;
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

# The session a stop should close: the OLDEST open start/record for the app - the
# one that has been running longest. The appointment header carries this so a stop
# names its own session, and every machine in the mesh closes that same row instead
# of each resolving "the open session" against its own, possibly lagging, copy of
# the database. Oldest, not newest: when a stop went missing and left a row open,
# a fresh press must clear that backlog rather than leapfrog it and leave the stale
# session running forever.
sub open_session_uuid {
	my $app = shift;
	return '' unless $app;
	my $row = &db_query('select uuid from appointments where app=? and (type=? or type=?) and stop_seen is null and timestamp <= ? order by timestamp asc limit 1', $app, 'start', 'record', &rightNow())->hashes->[0];
	return ($row && $row->{'uuid'}) ? $row->{'uuid'} : '';
}

# The row a stop closes, resolved the same way wherever the stop runs (manager_reset
# and appointment_writer both call this): the session the client named, carried
# through the relay so every machine closes the same one. A stop that names an open
# session closes that row and only it.
#
# A named session that is already closed is not a no-op any more: the header a stop
# button read can be one render behind (the person pressed start, the reply and its
# header had not reached the panel yet, and the stop named the session before it),
# and the session actually running was left open. That is still a person pressing
# stop on the session in front of them, so it falls back to the OLDEST open
# start/record at or before the press - the session that has been running longest,
# and the one a missing stop left behind. The press time is what keeps a late
# duplicate honest: a session started after that moment is not the one it meant, so
# a duplicate stop can never close a session the person started afterwards.
# One row per press; a repeated stop clears the next one rather than sweeping the
# whole backlog.
sub stop_target_row {
	my ($app, $target_uuid, $timestamp) = @_;
	return undef unless $app;
	$timestamp ||= &rightNow();
	if ($target_uuid) {
		my $named = &db_query('select * from appointments where app=? and uuid=? and (type=? or type=?) and stop_seen is null limit 1',
			$app, $target_uuid, 'start', 'record')->hashes->[0];
		return $named if $named && $named->{'uuid'};
	}
	my $row = &db_query('select * from appointments where app=? and (type=? or type=?) and timestamp <= ? and stop_seen is null order by timestamp asc limit 1',
		$app, 'start', 'record', $timestamp)->hashes->[0];
	return ($row && $row->{'uuid'}) ? $row : undef;
}

# A queued replay can deliver the same start twice a fraction of a second apart
# (a toggle replayed after a sleep, say). The start branch used to mint a fresh
# uuid every time, so the stop closed the row it named and the twin stayed open
# on whichever machine had received the other write - visibly "still running"
# long after the person stopped it. These two selectors make one press mean one
# session: an open row already close to this start is reused instead of a twin
# being written, and a stop retires any twin beside the row it closed.
sub session_open_near {
	my ($app, $type, $timestamp, $tolerance) = @_;
	return [] unless $app && defined $timestamp;
	$type ||= 'start';
	$tolerance = 2000 unless defined $tolerance && $tolerance =~ /^\d+$/;
	return &db_query('select uuid,timestamp from appointments where app=? and type=? and stop_seen is null and timestamp <= ? and abs(cast(timestamp as integer) - ?) <= ? order by timestamp asc',
		$app, $type, &rightNow(), $timestamp, $tolerance)->hashes || [];
}

sub session_twin_rows {
	my ($app, $uuid, $timestamp, $tolerance) = @_;
	return [] unless $app && $uuid && defined $timestamp;
	$tolerance = 2000 unless defined $tolerance && $tolerance =~ /^\d+$/;
	return &db_query('select uuid,timestamp from appointments where app=? and (type=? or type=?) and stop_seen is null and uuid != ? and abs(cast(timestamp as integer) - ?) <= ? order by timestamp asc',
		$app, 'start', 'record', $uuid, $timestamp, $tolerance)->hashes || [];
}

# The average the app's own closed sessions give it: the last forty stop lengths,
# plus the session being closed when there is one. Stored stop lengths are
# negative (start - stop), and a row a repair left without one is not a length at
# all. Neither is a zero, or a "session" longer than thirty days: those are a
# clock skew, a 1970 start or a row a bad merge left behind, and one of them
# would carry a lifetime into the app's usual length forever.
sub session_duration_average {
	my ($app, $duration) = @_;
	return undef unless $app;
	my $rows = &db_query('select duration from appointments where app=? and type=? order by server_time DESC LIMIT 40', $app, 'stop')->hashes || [];
	my $cap = 30 * 86400 * 1000;
	my ($total, $count) = (0, 0);
	if (defined $duration && length $duration && abs($duration) > 0 && abs($duration) <= $cap) {
		$total += abs($duration);
		$count++;
	}
	foreach my $row ( @{$rows} ) {
		next unless defined $row->{'duration'} && length $row->{'duration'};
		next unless abs($row->{'duration'}) > 0 && abs($row->{'duration'}) <= $cap;
		$total += abs($row->{'duration'});
		$count++;
	}
	return undef unless $count;
	return $total / $count;
}

# The app's usual length is the average of the sessions it has closed. Every
# writer that ends a session - manager_reset for a press, appointment_writer for
# a plate, a timer, a weather rule or a relayed stop - must teach it the same
# way, or a session the person never pressed stop on (autostop at a plate) would
# never count toward what the app is expected to run for. The caller passes the
# length of the session it is closing: this row must not be in the table yet, or
# it would be counted twice.
sub session_duration_learn {
	my ($app, $duration) = @_;
	return undef unless $app && defined $duration;
	my $average = &session_duration_average($app, $duration);
	return undef unless defined $average;
	&setting_setter({ app => $app, setting => 'duration', value => &duration_sayer($average / 1000) });
	return $average;
}

# One deliberate pass over the house: every app whose stops already say how long
# it usually runs is taught that average now, instead of waiting for its next
# stopped session. Writes the setting only when $apply; otherwise the report is
# the dry run. The script that runs this is scripts/duration_backfill.pl.
sub session_duration_backfill {
	my ($apply) = @_;
	my $rows = &db_query('select distinct app from appointments where type=? and duration is not null and app is not null and app != ?', 'stop', '')->hashes || [];
	my @out;
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'};
		next unless defined $app && length $app;
		my $average = &session_duration_average($app);
		next unless defined $average;
		my $before = &setting_grabber({ app => $app, setting => 'duration' });
		my $value = &duration_sayer($average / 1000);
		&setting_setter({ app => $app, setting => 'duration', value => $value }) if $apply;
		push @out, { app => $app, was => ($before // ''), value => $value, average => $average, changed => (($before // '') ne $value ? 1 : 0) };
	}
	return [ sort { $a->{'app'} cmp $b->{'app'} } @out ];
}

sub appt_header_printer {
	my $data = shift;
	my $app = $data->{'app'};

	# The header is the fast half: read its two rows, render it, push it. The
	# window render is the slow half, and it belongs to the caller - a start or
	# stop forks centre_view_grabber after this so the new header is on screen
	# before the default models and options have been started or stopped.
	#
	# Never a fork of its own. For one release (v0.1.1964) this ran in a forked
	# child so that a busy render could not hold the default model/option
	# sessions behind it; a start then answered in ~110ms but its header reached
	# the screen several hundred ms later, and a press that names no session of
	# its own read the open one off a header that had not been pushed yet.
	# Rendering here costs a few ms on the common press and keeps the order the
	# person sees: row, header, toggle, defaults.
	my $appts = $data->{'appts'} || &subs::log_reader({ app => $app, view => 'centre_view', header => 1 });
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my $c = &subs::controller_builder();
	my $header = $c->render_to_string(template => 'apps/appointment_header', timestamp => $server_time, appts => $appts, appointments => [ $app ], a => $app, running_uuid => &open_session_uuid($app) );

	# Push before any write. The header is what the person is watching, and the
	# two writes that follow (the toggle reconcile and the cache) can wait on
	# another writer's lock; that wait must not hold the header back.
	# A source=ws open is a headless/automation read (and the watch's own path):
	# it must not wake every other tab with a header, matching the route's own
	# source=ws guard. Other callers still broadcast.
	unless (($data->{'broadcast'} // '') eq 'no' || ($data->{'source'} // '') eq 'ws') {
		&Websocket::send('tab', { type => 'header', app => $app, timestamp => $server_time, header => $header });
	}
	&appt_toggle_checker($app) unless $data->{'skip_toggle'};
	eval { &subs::cache_set({ app => $app, context => 'header', timestamp => $server_time, warranty => '-1d' }, { timestamp => $timestamp, header => $header, signature => &subs::render_signature() }) };
	# Re-arming the alarms on the rows this header draws is a socket write each,
	# not a render, so it stays here. A caller that only wants the HTML (a
	# reconnect's resync) skips it.
	unless ($data->{'header_only'}) {
		foreach my $a ( @{ ($appts->{$app} || {})->{'list'} || [] } ) {
			&appt_alarm_setter($a);
		}
	}

	# the caller that also renders the centre view can reuse this fetch instead
	# of asking log_reader for the same rows again
	return wantarray ? ($header, $appts) : $header;
}

# A stop - and its cancel/pause/resume/delay kin - rewrites the rows seeded from
# the session it names: the default model/option sessions whose source_uuid is
# that session's uuid. Those children live in their own apps, so rendering the
# stopped app's header leaves every child app drawing the header it made while
# its session was still running - the child window reads "running" after the
# stop. Render one header per app that changed, once each, after its rows are
# written.
sub source_header_printer {
	my ($apps, $timestamp) = @_;
	my %seen;
	foreach my $app ( @{ $apps || [] } ) {
		next unless defined $app && length $app;
		next if $seen{$app}++;
		&appt_header_printer({ app => $app, timestamp => $timestamp });
	}
	return;
}

# The domain layer was written while Mojolicious::Lite was imported into package
# subs, so its controller builder says `app->...`; that import is gone (it built a
# second app and re-pointed app() in Manager). There is one application object,
# Manager's, and a background render is built from it.
sub app { return $Manager::APP }

sub controller_builder {
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

sub socket_retry_note {
	my ($key) = @_;
	my $state = $socket_retry->{$key} ||= { count => 0, next => 0, logged => 0 };
	$state->{'count'}++;
	# 1, 2, 4, 8, then one attempt every 10 seconds while it stays down
	my $wait = $state->{'count'} >= 5 ? 10 : (2 ** ($state->{'count'} - 1));
	$state->{'next'} = time + $wait;
	return $state;
}

# Drain what a push got written back, then report whether the peer is gone.
#
# recv() returns the *sender's address*, not a byte count. On a unix socket that
# is a packed sockaddr_un ("\x01\0/tmp/ws/server\0"), so comparing it to 0 warns
# on every push - and a flood of those warnings fills the pty and blocks the
# worker that wrote them (v0.1.1850). The bytes live in the buffer recv filled;
# the call itself only says whether it succeeded.
#
# 1 means the peek found EOF and the caller should drop the cached socket.
sub socket_drain_peek {
	my ($socket, $drain) = @_;
	if ($drain) {
		while (1) {
			my $junk = '';
			my $got = recv($socket, $junk, 65536, MSG_DONTWAIT);
			last unless defined $got && length($junk) > 0;
		}
	}
	my $peek = '';
	my $peeked = recv($socket, $peek, 1, MSG_PEEK | MSG_DONTWAIT);
	return 0 unless defined $peeked;
	return length($peek) == 0 ? 1 : 0;
}

sub unix_socket_sender {
	my ($file,$data,$rcv,$retried) = @_;
	$rcv = 0 unless defined $rcv;
	$retried = 0 unless defined $retried;

	my $is_watch = ($file eq 'process' || $file eq &subs::home('~/.process_watch')) ? 1 : 0;
	if ($file eq 'memory') {
		$file = &subs::home('~/.president/memory');
	}
	elsif ($is_watch) {
		$file = &subs::home('~/.process_watch');
	}
	# The worker surfaces keep their paths (one per app under ws/), so the kind
	# is read back from the path instead of guessed from the payload.
	my $kind = JawnOS::Transport::kind_for_path($file);
	my $tcp = ($kind && JawnOS::Transport::tcp()) ? 1 : 0;
	my $cache_key = ($tcp ? 'tcp:' . $kind : $file) . '_' . $$;
	my $response_data;
	my $retry = $socket_retry->{$cache_key};
	return if $retry && $retry->{'next'} > time;
	my $bytes_written = 0;
	my $had_cached = defined $cached_sockets->{$cache_key} ? 1 : 0;
	my $ok = eval {
		return 0 unless $tcp || -e $file;


		my $socket = $cached_sockets->{$cache_key};
    if ($socket) {
        # A cached unix socket can outlive its peer: the websocket worker
        # restarts, or ws_bind_all rebinds the path. connected() and a
        # zero-byte write both still say "open" on a socket whose peer is gone,
        # so the honest test is a non-blocking peek - 0 bytes is EOF. A push
        # also gets its uuid written back by the receiver; drain that first so
        # the peek can see the EOF and the buffer cannot grow.
        if (&socket_drain_peek($socket, $rcv ? 0 : 1)) {
            $socket->close;
            undef $socket;
            delete $cached_sockets->{$cache_key};
        }
    }
		if (!$socket) {
			if ($tcp) {
				$socket = JawnOS::Transport::client_socket($kind, timeout => 5, path => $file);
			}
			else {
				$socket = JawnOS::Transport::client_unix_socket($file);
			}
			die "Socket connection failed: $!" unless $socket;
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

		my $payload = $data;
		if ($tcp && ref $data eq 'HASH') {
			$payload = { %$data, token => JawnOS::Transport::token() };
		}
		my $jwsm           = $encoder->encode($payload);
		my $payload_length = length($jwsm);
		my $packet         = pack('N', $payload_length) . $jwsm;
    my $bytes_to_write = length($packet);
    $bytes_written = 0;
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
};
unless ($ok) {
	my $err = $@ || '';
	delete $cached_sockets->{$cache_key};
	# A write that failed on a reused socket before any byte left wrote
	# nothing, so the same message can go once on a fresh connection. This is
	# the restart case: the peer died between the peek and the write, and a
	# start or stop push must not be swallowed because of it.
	if (!$retried && !$rcv && $had_cached && $bytes_written == 0 && $err =~ /Write error|Broken pipe|Connection reset/) {
		return &unix_socket_sender($file, $data, $rcv, 1);
	}
	my $state = &socket_retry_note($cache_key);
	my $now = time;
	# one line a second at most, and no payload dump
	if (defined $log && length $err && (!$state->{'logged'} || $now - $state->{'logged'} >= 1)) {
		$state->{'logged'} = $now;
		# a refused connect to a watch socket that exists is the master
		# between boots: the sender repeats its report on the next tick, so
		# it is not an error - a write or protocol failure still is
		if ($err =~ /Socket connection failed|Connection refused/) {
			$log->info("Socket sender: $err (the master is between boots)");
		}
		else {
			$log->error("Socket sender error: $err");
		}
	}
}
else {
	delete $socket_retry->{$cache_key};
}

	# A fire-and-forget push (rcv 0) has no reply to return, so its caller used
	# to get undef whether the frame went or the socket refused it - and a device
	# command that read that as success skipped its HTTP fallback and never
	# reached the board. Say which happened.
	return $rcv ? $response_data : ($ok ? 1 : 0);
}

sub request_busy_change {
	my ($delta) = @_;
	return unless (($ENV{PURPOSE} || '') eq 'main');
	$request_busy_depth += $delta;
	$request_busy_depth = 0 if $request_busy_depth < 0;
	my $dir = &home('~/.president/busy');
	my $file = $dir . '/' . $$;
	# `start` while the request runs, `end` when it finishes. The marker stays
	# for a few seconds after the end so the autoscaler can see a burst of short
	# loads; it removes a stale one itself (see prefork_autoscale).
	eval {
		mkdir $dir unless -d $dir;
		open(my $fh, '>', $file) or die "busy marker: $!";
		print $fh ($request_busy_depth > 0 ? 'start ' : 'end ') . &rightNow() . "\n";
		close $fh;
	};
}

sub request_busy_release {
	my ($c) = @_;
	return unless $c && $c->stash('request_busy');
	$c->stash('request_busy' => 0);
	&request_busy_change(-1);
}

sub render_in_subprocess {
	my ($c, $work, $render) = @_;
	$c->render_later;
	&request_busy_release($c);
	push @deferred_jobs, [ $c, $work, $render ];
	&_deferred_pump();
	return;
}

sub _deferred_pump {
	my $limit = 3;
	while ($deferred_children < $limit && @deferred_jobs) {
		my ($c, $work, $render) = @{ shift @deferred_jobs };
		$deferred_children++;
		my $p = Mojo::IOLoop->subprocess->run_p(sub {
			# A forked child cannot speak (its ioloop is frozen); silence the
			# best-effort announcements rather than schedule work that never runs.
			local $subs::say_quiet = 1;
			return $work->();
		});
		$p->then(sub {
			my @results = @_;
			eval { $render->($c, @results); 1 } or do {
				my $err = $@ || 'the answer could not be rendered';
				eval { $c->render(json => { error => $err }) };
			};
		})->catch(sub {
			my $err = shift;
			$err = (defined $err && length $err) ? "$err" : 'the work did not finish';
			eval { $c->render(json => { error => $err }) };
		})->finally(sub {
			$deferred_children--;
			&_deferred_pump();
		});
	}
}

sub subprocessor {
	my ($subroutine,$params) = @_;
	# sync => 1 runs the work in this process and returns once it is done, without
	# the subprocess wrapper's loop reset. Use it when the caller needs the result
	# before it can build its response - the mail batch decrypts its rows and
	# renders them, and a forked child left the page to show its envelopes empty.
	if ($params->{'sync'}) {
		my $result = eval { $subroutine->() };
		my $error = $@;
		if ($error) {
			eval { $log->error('subprocessor ' . ($params->{'name'} || '?') . ' sync failed: ' . ($error =~ s/\s+/ /gr)) } if $log;
		}
		return $result;
	}
	my $parent_pid = $$;
	# The warranty belongs to the job's name, not to each call site: one seed map
	# (Domain::Process) gives a tunnel holder 'forever' and a header render five
	# seconds, and a caller may still override it with warranty =>. A name that is
	# not listed is 'forever', so a new job is never killed on its first slow run.
	my $name = $params->{'name'};
	my $warranty_spec = defined $params->{'warranty'}
		? $params->{'warranty'}
		: &subs::subprocessor_warranty_for($name);
	my $started = &subs::rightNow();
	my $warranty = &subs::subprocessor_warranty_at($warranty_spec, $started);
	# A job asked for from inside another job must be its own process. Run inline
	# it sends its record with this pid, which renames the outer job and gives it
	# the inner job's (shorter) warranty - the reaper then kills the whole group at
	# the inner deadline. Measured on the phone: `appointment models` was killed at
	# 35s under the name `embedded toggle push` (30s), so a start's sugar and cream
	# never arrived. The outer job's own child handle (subprocessor_uuid) is the
	# signal that we are already inside one.
	my $nested = (defined $gb::subprocessor_uuid && length $gb::subprocessor_uuid) ? 1 : 0;
	$params->{'fork'} = 1 if $nested;
	# run_p forks on the next tick, not at this call, so the child's own clock
	# starts when it runs (see subprocessor_reap): the ask asks, the process is
	# judged. 'forever' and an absolute moment are the same either way.
	my $forked = $gb::subprocessed > 1 && !$params->{'fork'} ? 0 : 1;
	my $runs_later = $forked && !(defined $warranty_spec && $warranty_spec =~ /^\s*(?:forever|\d{12,})\s*$/i);
	# A resident loop is 'forever', but it still has to prove it is working. The
	# lease is the longest quiet gap the loop is allowed; the loop calls
	# subs::subprocessor_heartbeat() each turn.
	my $heartbeat_spec = &subs::subprocessor_heartbeat_for($name);
	my $heartbeat_lease = defined $heartbeat_spec
		? &subs::subprocessor_warranty_at($heartbeat_spec, 0)
		: undef;
	my $wrapped_subroutine = sub {
		Mojo::IOLoop->reset({ freeze => 1 });
		$gb::subprocessed++;
		$subs::heartbeat_sent_at = undef;
		my $file = &subs::home('~/.process_watch');
#		my $file = $tmp_dir . '/process_watch';
		my $pid = $$;
		# The wrapper owns its process group, so the reaper can signal the whole
		# tree it starts (a command's own children) instead of orphaning them. Only
		# a real fork: the inline path is the caller's own process, and moving a
		# request worker into its own group would be a surprise.
		my $pgid = 0;
		if ($pid != $parent_pid) {
			eval {
				setpgrp(0, 0);
				my $group = getpgrp();
				$pgid = $group if $group == $pid;
			};
		}
		# The kernel's start time for this pid, so a reaper can tell a live record
		# from a number the OS has since given to another process.
		my $start_ticks = '';
		if (open(my $stat_fh, '<', '/proc/self/stat')) {
			my $stat_line = <$stat_fh>;
			close $stat_fh;
			if (defined $stat_line && (my $close = rindex($stat_line, ')')) >= 0) {
				my @stat_field = split ' ', substr($stat_line, $close + 2);
				$start_ticks = $stat_field[19] // '';
			}
		}

		my $subprocess = {
			parent    => $parent_pid,
			pid       => $pid,
			timestamp => $started,
			start_timestamp => $started,
			name      => $name,
			uuid      => &subs::random_string_creator(10),
			status    => 'start',
			warranty  => $warranty,
			warranty_spec => (defined $warranty_spec && length $warranty_spec) ? $warranty_spec : 'forever',
			heartbeat_at => $started,
			heartbeat_lease => $heartbeat_lease,
			heartbeat_spec => $heartbeat_spec,
			start_ticks => $start_ticks,
			pgid => $pgid,
			($runs_later ? (deferred_warranty_spec => $warranty_spec) : ()),
		};
		&subs::unix_socket_sender($file,$subprocess);

		if ($@) { warn "Worker $$: Failed to send 'start' state: $@" }
		# The helper the loop calls reads these from the child's own package.
		my $previous_uuid = $gb::subprocessor_uuid;
		my $previous_name = $gb::subprocessor_name;
		$gb::subprocessor_uuid = $subprocess->{'uuid'};
		$gb::subprocessor_name = $name;
		eval {
			$subroutine->();
		};
		my $sub_error = $@; # Capture error if the main task fails
		$gb::subprocessor_uuid = $previous_uuid;
		$gb::subprocessor_name = $previous_name;
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
		# run_p forks on the next tick and reports a failed pipe or fork only
		# through its promise. Nothing used to read it, so a job that never
		# started - and the pull claim its caller had already written - failed
		# in silence. Name it.
		# The job object, not only its promise: when the child is killed before it
		# writes its result (the OOM killer's SIGKILL, the reaper's TERM) the pipe
		# closes empty and the promise rejects with decode_json('')'s error, which
		# blamed a JSON bug for a process that never ran to the end.
		my $job = Mojo::IOLoop->subprocess;
		my $promise = $job->run_p($wrapped_subroutine);
		eval {
			$promise->catch(sub {
				my $why = join ' ', grep { defined } @_;
				$why =~ s/\s+/ /g;
				eval { $log->error(&subs::subprocessor_failure_message($name, $why, $job)) } if $log;
			});
		};
	}

}

sub random_string_creator {

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

sub inventory_grabber {
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

sub time_spans {
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

sub time_span_length {
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

sub time_span {
	my ($span, $timestamp, $multiplier) = @_;
	my $length = &time_span_length($span) or die "unknown time span: $span";
	return $timestamp - $length * ($multiplier || 1);
}

sub interval_parse {
	my $text = shift;
	$text = '' unless defined $text;
	my $raw = $text;
	$text =~ s/^\s+|\s+$//g;
	return unless length $text;
	$text = lc $text;
	$text =~ s/^(?:every|each)\s+//;
	return (0, 'once') if $text eq 'once';
	return @{$interval_words{$text}} if $interval_words{$text};
	# "1M" is a month, while a lower-case "1m" is a minute, as everywhere else
	return ($1 + 0, 'month') if $raw =~ /^\s*([0-9]+(?:\.[0-9]+)?)\s*M\s*$/;
	my ($count, $word) = $text =~ /^([0-9]+(?:\.[0-9]+)?)\s*([a-z]+)$/;
	return unless defined $count;
	my $unit =
		$word =~ /^(?:s|sec|secs|second|seconds)$/ ? 'second' :
		$word =~ /^(?:m|mi|min|mins|minute|minutes)$/ ? 'minute' :
		$word =~ /^(?:h|hr|hrs|hour|hours)$/ ? 'hour' :
		$word =~ /^(?:d|day|days)$/ ? 'day' :
		$word =~ /^(?:w|wk|wks|week|weeks)$/ ? 'week' :
		$word =~ /^(?:mo|mon|month|months)$/ ? 'month' :
		$word =~ /^(?:y|yr|yrs|year|years)$/ ? 'year' : undef;
	return unless $unit;
	return ($count + 0, $unit);
}

# Read a schedule the appointment input and the payable scheduler share:
# "<interval> for <horizon>". "1d for -2w" is every day for two weeks;
# "monthly for 1y" is the first of each month for a year. "-2w" and "2w"
# both mean two weeks ahead, because a horizon runs forward from the first
# occurrence. Either part may be left out and "once" means no repeat.
sub schedule_parse {
	my $spec = shift;
	$spec = '' unless defined $spec;
	my $raw = $spec;
	$spec =~ s/^\s+|\s+$//g;
	return { once => 1, every => 'once', raw => $raw } if !length($spec) || $spec =~ /^once$/i;
	my ($every, $horizon);
	if ($spec =~ /^(.*?)\s*(?:\bfor\b|\buntil\b|\bthrough\b|\bto\b|\/)\s*(.+)$/i) {
		($every, $horizon) = ($1, $2);
	}
	else { $every = $spec }
	my ($count, $unit) = &interval_parse($every);
	unless (defined $count && defined $unit) {
		return { error => 1, raw => $raw, every => $every, horizon => $horizon };
	}
	return {
		once => $unit eq 'once' ? 1 : 0,
		every => $every,
		count => $count,
		unit => $unit,
		horizon => $horizon,
		raw => $raw
	};
}

# The moment a schedule's horizon names, counted forward from its first
# occurrence. A written date ("dec 31") is read as a date; anything else is a
# length and runs ahead whichever sign it was typed with.
sub schedule_until {
	my ($horizon, $from) = @_;
	return undef unless defined $horizon && length $horizon;
	$from = &rightNow() unless defined $from;
	my $text = $horizon;
	$text =~ s/^\s+|\s+$//g;
	return undef unless length $text;
	my $resolved = &resolve_when($text, $from);
	return $resolved if defined $resolved;
	$text =~ s/^[+-]\s*//;
	# a horizon written as an interval (1y, 2 months, 30d) steps the calendar,
	# so a year across a leap February is 366 days and a month is the month
	my ($count, $unit) = &interval_parse($text);
	return &calendar_shift($from, $count, $unit) if defined $count && defined $unit && $unit ne 'once' && $count > 0;
	my $ms = &time_abbrev_translator($text, $from);
	return undef unless defined $ms && $ms;
	return $from + abs($ms);
}

1;
