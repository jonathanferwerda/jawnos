package subs;

# Remotes: the IR sequences a board has learned. A board captures a burst and
# POSTs it to /watch/ir; this layer keeps those captures as named entries on the
# board's own settings row and replays one on demand. The entry lives beside the
# board (settings: app => edt, setting => 'remotes', subsetting => chip_id) so
# it travels with the device record exactly like its operator_door, and a board
# that is not listening over /device/ws is still reached on its HTTP output
# route. Delivery reuses the same road the output commands use: the socket
# frame first, then the board's route.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;

# File-scope state owned by subroutines.pl, in this same package.
our $config;
our $log;

my $SETTING = 'remotes';
my $MAX_SEQ = 512;
my $MAX_NAME = 60;

sub remote_store_read {
	# The board's learned remotes, keyed by name. Absent, malformed or empty is
	# an empty hashref so every caller can index it without a guard.
	my ($edt, $chip_id) = @_;
	$edt = 'microcontroller' unless defined $edt && length $edt;
	return {} unless defined $chip_id && length $chip_id;
	my $raw = &subs::setting_grabber({ app => $edt, setting => $SETTING, subsetting => $chip_id });
	return {} unless defined $raw && length $raw;
	my $remotes = eval { decode_json($raw) };
	return (ref $remotes eq 'HASH') ? $remotes : {};
}

sub remote_store_save {
	# One write, so add and delete can never disagree about the key.
	my ($edt, $chip_id, $remotes) = @_;
	$edt = 'microcontroller' unless defined $edt && length $edt;
	return 0 unless defined $chip_id && length $chip_id && ref $remotes eq 'HASH';
	&subs::setting_setter({
		app        => $edt,
		setting    => $SETTING,
		subsetting => $chip_id,
		value      => encode_json($remotes),
	});
	return 1;
}

sub remote_pin_app {
	# Which app, if any, is already wired to this pin on this board. A capture
	# for an unwired pin is stored anyway; it just carries no app yet.
	my ($edt, $chip_id, $pin) = @_;
	return '' unless defined $pin && $pin =~ /^\d+$/;
	my $raw = eval { &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id }) };
	return '' unless defined $raw && length $raw;
	my $op_d = eval { decode_json($raw) };
	return '' unless ref $op_d eq 'HASH';
	foreach my $key (sort keys %{$op_d}) {
		next if $key =~ /^__/;
		my $entry = $op_d->{$key};
		next unless ref $entry eq 'HASH';
		next unless defined $entry->{'numero'} && $entry->{'numero'} eq $pin;
		return $entry->{'app'} // '';
	}
	# Older rows do not carry numero; the pin is the tail of the key.
	foreach my $key (sort keys %{$op_d}) {
		next if $key =~ /^__/;
		next unless $key =~ /\Q$pin\E$/;
		my $entry = $op_d->{$key};
		next unless ref $entry eq 'HASH';
		return $entry->{'app'} // '';
	}
	return '';
}

sub remote_store_add {
	# Accept a capture under a person's name. The name is the key, so it is
	# trimmed and must survive as something a person can say (not whitespace,
	# not a paragraph). The seq is the board's comma-separated duration list.
	my ($data) = @_;
	$data = {} unless ref $data eq 'HASH';
	my $edt = $data->{'edt'} || 'microcontroller';
	my $chip_id = $data->{'chip_id'} || '';
	return { ok => 0, error => 'no chip' } unless defined $chip_id && length $chip_id;

	my $name = defined $data->{'name'} ? $data->{'name'} : '';
	$name =~ s/^\s+//;
	$name =~ s/\s+$//;
	return { ok => 0, error => 'name required' } unless length $name;
	return { ok => 0, error => 'name too long' } if length($name) > $MAX_NAME;

	my $pin = $data->{'pin'};
	return { ok => 0, error => 'pin must be 0..29' }
		unless defined $pin && $pin =~ /^\d+$/ && $pin <= 29;

	my $seq = &remote_seq_clean($data->{'seq'});
	return { ok => 0, error => 'seq needs numbers' } unless defined $seq;

	my $remotes = &remote_store_read($edt, $chip_id);
	my $entry = {
		seq        => $seq,
		pin        => 0 + $pin,
		app        => &remote_pin_app($edt, $chip_id, $pin),
		learned_at => &subs::rightNow(),
	};
	$entry->{'pending'} = 1 if $data->{'pending'};
	$remotes->{$name} = $entry;
	&remote_store_save($edt, $chip_id, $remotes);
	return { ok => 1, name => $name, remotes => $remotes };
}

sub remote_store_delete {
	# Remove only the entry named; everything else on the board stays as it was.
	my ($data) = @_;
	$data = {} unless ref $data eq 'HASH';
	my $edt = $data->{'edt'} || 'microcontroller';
	my $chip_id = $data->{'chip_id'} || '';
	return { ok => 0, error => 'no chip' } unless defined $chip_id && length $chip_id;

	my $name = defined $data->{'name'} ? $data->{'name'} : '';
	$name =~ s/^\s+//;
	$name =~ s/\s+$//;
	return { ok => 0, error => 'name required' } unless length $name;

	my $remotes = &remote_store_read($edt, $chip_id);
	return { ok => 0, error => 'unknown remote' } unless exists $remotes->{$name};
	delete $remotes->{$name};
	&remote_store_save($edt, $chip_id, $remotes);
	return { ok => 1, remotes => $remotes };
}

sub remote_send {
	# Replay a learned sequence. The socket frame is built here rather than by
	# device_ws_command(), whose fixed field list would drop the code - the very
	# field an IR command is. device_ws_write_frame() still chooses the road
	# (this process, this machine's websocket worker), and HTTP covers a board
	# with no socket.
	my ($data) = @_;
	$data = {} unless ref $data eq 'HASH';
	my $edt = $data->{'edt'} || 'microcontroller';
	my $chip_id = $data->{'chip_id'} || '';
	return { ok => 0, error => 'no chip' } unless defined $chip_id && length $chip_id;

	my $name = defined $data->{'name'} ? $data->{'name'} : '';
	$name =~ s/^\s+//;
	$name =~ s/\s+$//;
	return { ok => 0, error => 'name required' } unless length $name;

	my $remotes = &remote_store_read($edt, $chip_id);
	my $entry = $remotes->{$name};
	return { ok => 0, error => 'unknown remote' } unless ref $entry eq 'HASH';
	my $pin = $entry->{'pin'};
	my $seq = $entry->{'seq'};
	return { ok => 0, error => 'remote has no seq' } unless defined $seq && length $seq;

	my $uuid = &subs::random_string_creator();
	my $timestamp = &subs::rightNow();
	my $appt_uuid = $data->{'appt_uuid'};
	my $frame = {
		t         => 'cmd',
		component => 'ir',
		pin       => $pin,
		code      => $seq,
		when      => 'now',
		uuid      => $uuid,
		timestamp => $timestamp,
	};
	$frame->{'appt_uuid'} = $appt_uuid if defined $appt_uuid && length $appt_uuid;

	my $sent = &subs::device_ws_write_frame($chip_id, $frame) ? 1 : 0;
	$sent = &remote_send_http({
		edt       => $edt,
		chip_id   => $chip_id,
		pin       => $pin,
		seq       => $seq,
		uuid      => $uuid,
		timestamp => $timestamp,
		appt_uuid => $appt_uuid,
	}) unless $sent;

	return { ok => 1, sent => $sent, pin => $pin, name => $name };
}

sub remote_send_http {
	# The board's own output route, with the code as an ordinary query field.
	# Same address lookup, per-chip command lock and 1 s connect timeout as
	# embedded_toggle(), so an IR replay queues behind a press exactly the way
	# another output command does.
	my ($data) = @_;
	$data = {} unless ref $data eq 'HASH';
	my $edt = $data->{'edt'} || 'microcontroller';
	my $chip_id = $data->{'chip_id'} || '';
	return 0 unless defined $chip_id && length $chip_id;

	my $od = eval { decode_json(&subs::embedded_operator_door($edt, $chip_id) || '') } || {};
	my $authorization = $od->{'__specs'}->{'authorization'} || '';

	my $watch = eval { &subs::device_lister($data->{'timestamp'}, $edt, undef, $chip_id) };
	my $ip = (ref $watch eq 'HASH' && $watch->{'ip'}) ? $watch->{'ip'} : '';
	return 0 unless length $ip;
	# The token rides the /relay query; never dial a public or named host.
	unless (&board_host_allowed($ip)) {
		$log->info('remote send refused: ' . $chip_id . ' at ' . $ip . ' (not a house address)') if $log;
		return 0;
	}

	my $lock = &subs::device_command_lock($chip_id);
	my $port = $config->{'port'} || 80;
	# Plain HTTP board WebServer: TLS/HMAC is firmware work (jp/, jt/, jw/).
	my $url = 'http://' . $ip . ':' . $port . '/relay'
		. '?appt_uuid=' . ($data->{'appt_uuid'} // '')
		. '&uuid=' . $data->{'uuid'}
		. '&when=now'
		. '&pin=' . $data->{'pin'}
		. '&code=' . $data->{'seq'}
		. '&component=ir'
		. '&authorization=' . $authorization
		. '&timestamp=' . $data->{'timestamp'};
	my $ua = Mojo::UserAgent->new(connect_timeout => 1, inactivity_timeout => 2);
	my $res = eval { $ua->insecure(1)->get($url)->result };
	return 0 unless $res && $res->is_success;
	my $body = eval { $res->body } || '';
	my $answer = $body ? eval { decode_json($body) } : undef;
	return ref $answer eq 'HASH' ? 1 : 0;
}

sub remote_learn_start {
	# Ask the board to listen on one pin. The board owns the capture and POSTs
	# it back to /watch/ir; this only starts the window.
	my ($data) = @_;
	$data = {} unless ref $data eq 'HASH';
	my $chip_id = $data->{'chip_id'} || '';
	return { ok => 0, error => 'no chip' } unless defined $chip_id && length $chip_id;

	my $pin = $data->{'pin'};
	return { ok => 0, error => 'pin must be 0..29' }
		unless defined $pin && $pin =~ /^\d+$/ && $pin <= 29;

	my $ms = (defined $data->{'ms'} && length $data->{'ms'}) ? $data->{'ms'} : 5000;
	return { ok => 0, error => 'ms must be 500..10000' }
		unless $ms =~ /^\d+$/ && $ms >= 500 && $ms <= 10000;

	my $sent = &subs::device_ws_write_frame($chip_id, { t => 'learn', pin => 0 + $pin, ms => 0 + $ms }) ? 1 : 0;
	return { ok => 1, sent => $sent };
}

sub remote_seq_clean {
	# A capture is comma-separated microsecond durations. Trim the whole string
	# and each token, then insist every token is a number; an empty list or a
	# list over the board's 512-duration ceiling is not a sequence.
	my ($raw) = @_;
	return undef unless defined $raw;
	$raw =~ s/^\s+//;
	$raw =~ s/\s+$//;
	return undef unless length $raw;
	my @parts = split /,/, $raw, -1;
	return undef unless scalar(@parts) && scalar(@parts) <= $MAX_SEQ;
	foreach my $part ( @parts ) {
		$part =~ s/^\s+//;
		$part =~ s/\s+$//;
		return undef unless length $part && $part =~ /^\d+$/;
	}
	return join(',', @parts);
}

1;
