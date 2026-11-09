package subs;

# Boardpins: what a board says about its own wiring, and what the house does
# with that answer. A board reports one JSON object on its USB CDC console (a
# "JAWNPINS {...}" line) or at GET /pins over the network:
#
#   {t, chip, version, purpose, components:[{pin,component,app,inverted}],
#    free:[...], probe:[{pin,kind,analog}]}
#
# The manager can adopt that report - repairing an operator_door that has drifted
# (stale keys the board no longer has) without inventing apps - and can attach a
# newly discovered pin to an existing appointment in one call, writing both the
# board's door and the appointment's wiring map (ia).
#
# The USB reader mirrors the technique in Controller/manager_embedded.pm
# action_43737 (stty raw, then an IO::Select loop with a deadline) rather than
# sharing code with it: that action sends a different payload on a different
# protocol, so factoring only the "open the same port and read" part would have
# meant editing a working provisioning path. The port validation and the read
# loop stay deliberately identical so the two cannot disagree about a port.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json);

# The component vocabulary is the house's, not the board's: an unknown name is
# refused rather than written into a door where nothing would drive it.
my %DIRECTION = (
	relay  => 'output',
	led    => 'output',
	servo  => 'output',
	button => 'input',
	switch => 'input',
	pot    => 'input',
);

# A door key is the component name (or its one-letter shorthand on a device
# class that uses one) followed by the pin: relay28, led16, button14. A key that
# does not have both parts is not a wiring entry.
sub _component_prefixes($edt) {
	my %prefix;
	if (($edt // '') eq 'microcontroller') {
		%prefix = map { $_ => 1 } keys %DIRECTION;
	}
	else {
		%prefix = map { substr($_, 0, 1) => 1 } keys %DIRECTION;
	}
	return join '|', map { quotemeta } sort { length($b) <=> length($a) } keys %prefix;
}

# Find and decode either a bare JSON object or the console's "JAWNPINS <json>"
# line. Nothing is trusted until components and probe are arrays of objects, so
# a half-written line or a different JSON object is simply not a pins report.
sub board_pins_parse($text) {
	return undef unless defined $text && length $text;

	my @candidates;
	(my $trimmed = $text) =~ s/^\s+//;
	$trimmed =~ s/\s+$//;
	push @candidates, $trimmed if $trimmed =~ /^\{.*\}$/s;
	# The USB console prints the report on one line, possibly after boot noise.
	while ($text =~ /^[^\n]*?\bJAWNPINS\s+(\{.*\})\s*$/mg) {
		push @candidates, $1;
	}
	# A bare object on a line of its own.
	while ($text =~ /^\s*(\{.*\})\s*$/mg) {
		push @candidates, $1;
	}

	foreach my $candidate (@candidates) {
		my $report = eval { decode_json($candidate) };
		next unless ref $report eq 'HASH';
		next unless ref $report->{'components'} eq 'ARRAY';
		next unless ref $report->{'probe'} eq 'ARRAY';
		next if grep { ref $_ ne 'HASH' } @{$report->{'components'}};
		next if grep { ref $_ ne 'HASH' } @{$report->{'probe'}};
		$report->{'free'} = [] unless ref $report->{'free'} eq 'ARRAY';
		$report->{'chip'} = '' unless defined $report->{'chip'};
		$report->{'version'} = '' unless defined $report->{'version'};
		return $report;
	}
	return undef;
}

# Ask a board sitting on a USB CDC port for its pins. The caller has already
# chosen the port; this opens it, writes the question and waits up to 8s for the
# answer. The return value is shaped like the HTTP reader's so a caller can adopt
# either without a branch.
sub board_pins_usb_read($port) {
	return { ok => 0, error => 'need a port' } unless defined $port && length $port;
	return { ok => 0, error => 'that port does not look right' } unless $port =~ m{^/dev/tty(?:ACM|USB)\d+$};
	require IO::Select;
	require IO::Handle;

	system('stty', '-F', $port, 'raw', '115200', '-echo') == 0
		or return { ok => 0, error => 'could not prepare ' . $port };
	open(my $fh, '+<', $port)
		or return { ok => 0, error => 'could not open ' . $port . ': ' . $! };
	$fh->autoflush(1);
	print {$fh} "JAWNPINS?\n";

	my $sel = IO::Select->new($fh);
	my $buf = '';
	my $deadline = time() + 8;
	while (time() < $deadline) {
		my @ready = $sel->can_read(0.25);
		next unless @ready;
		my $chunk = '';
		my $n = sysread($fh, $chunk, 4096);
		last unless defined $n && $n > 0;
		$buf .= $chunk;
		last if $buf =~ /JAWNPINS\s*\{/;
	}
	close $fh;

	my $report = board_pins_parse($buf);
	return { ok => 0, port => $port, error => 'no pins report from the board', reply => $buf }
		unless $report;
	return { ok => 1, port => $port, report => $report };
}

# The network path to the same report. The timeouts are short because a board
# that does not answer right now is not worth a request that hangs.
sub board_pins_http_read($ip, $port) {
	return { ok => 0, error => 'need an ip' } unless defined $ip && length $ip;
	$port = 80 unless defined $port && length $port;
	my $ua = Mojo::UserAgent->new(connect_timeout => 2, inactivity_timeout => 3);
	my $res = eval { $ua->get('http://' . $ip . ':' . $port . '/pins')->result };
	return { ok => 0, error => 'no reply from ' . $ip . ':' . $port } unless $res;
	return { ok => 0, error => 'HTTP ' . $res->code . ' from ' . $ip . ':' . $port }
		unless $res->is_success;

	my $report = board_pins_parse($res->body);
	return { ok => 0, ip => $ip, error => 'the board did not report its pins' } unless $report;
	return { ok => 1, ip => $ip, report => $report };
}

# Reconcile the house's door record against the board's own report. The board is
# authoritative about which pins exist; the house is authoritative about which
# appointment each one drives. So a key the board cannot have is dropped, every
# surviving entry is left exactly as it was (no app is invented), and the live
# report is kept beside it as `board_pins` so the truth is never lost.
sub board_pins_adopt($report, $opts) {
	$opts ||= {};
	return { ok => 0, error => 'need a pins report' } unless ref $report eq 'HASH';
	my $edt = $opts->{'edt'} || 'microcontroller';
	my $chip_id = defined $opts->{'chip_id'} ? $opts->{'chip_id'} : $report->{'chip'};
	return { ok => 0, error => 'need a chip_id' } unless defined $chip_id && length $chip_id;

	my $raw = &setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $door = (defined $raw && length $raw) ? (eval { decode_json($raw) } || {}) : {};
	$door = {} unless ref $door eq 'HASH';

	my %keep = map { $_ => 1 } qw(__specs __shutup);
	my $prefix_re = _component_prefixes($edt);
	my @dropped;
	foreach my $key (keys %{$door}) {
		next if $keep{$key};
		next if $key =~ /^(?:$prefix_re)\d+$/;
		push @dropped, $key;
		delete $door->{$key};
	}

	# Repair only when the record held something the board does not have. An
	# untouched door is left untouched, so adopting twice is not a write.
	if (@dropped) {
		&setting_setter({
			app => $edt, setting => 'operator_door', subsetting => $chip_id,
			value => encode_json($door),
		});
	}
	&setting_setter({
		app => $edt, setting => 'board_pins', subsetting => $chip_id,
		value => encode_json($report),
	});

	return {
		ok => 1,
		chip => $report->{'chip'} // '',
		version => $report->{'version'} // '',
		components => scalar @{ $report->{'components'} || [] },
		dropped => [ sort @dropped ],
		free => scalar @{ $report->{'free'} || [] },
		probed => scalar @{ $report->{'probe'} || [] },
	};
}

# Make a discovered pin drive an appointment. The door entry is the board's view
# (what this pin is wired to); the ia entry is the appointment's view (which pins
# its automation reaches), keyed chip => pin. Both are written so the panel and
# the automation pass see the same wiring in the same request.
sub board_pins_attach($data) {
	$data = {} unless ref $data eq 'HASH';
	my $edt = $data->{'edt'} || 'microcontroller';
	my $chip_id = $data->{'chip_id'};
	my $pin = $data->{'pin'};
	my $component = $data->{'component'} // '';
	my $app = $data->{'app'} // '';

	return { ok => 0, error => 'need a chip_id' } unless defined $chip_id && length $chip_id;
	return { ok => 0, error => 'the pin must be a number from 0 to 29' }
		unless defined $pin && $pin =~ /^\d+$/ && $pin >= 0 && $pin <= 29;
	return { ok => 0, error => 'unknown component: ' . $component } unless $DIRECTION{$component};
	return { ok => 0, error => 'need an app' } unless length $app;

	# An unknown app must not be given a fresh uuid as a side effect of asking
	# whether it exists: read the stored uuid first, then ask the settings row
	# without letting it create one.
	my $uuid = eval { &setting_grabber({ app => $app, setting => 'uuid' }) };
	if (!(defined $uuid && length $uuid)) {
		my $aset = eval { &settings_grabber({ app => $app, benign => 1 }) };
		$uuid = (ref $aset eq 'HASH') ? $aset->{'uuid'} : undef;
	}
	return { ok => 0, error => 'no such appointment: ' . $app } unless defined $uuid && length $uuid;

	my $prefix = $edt eq 'microcontroller' ? $component : substr($component, 0, 1);
	my $key = $prefix . $pin;

	my $raw = &setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $door = (defined $raw && length $raw) ? (eval { decode_json($raw) } || {}) : {};
	$door = {} unless ref $door eq 'HASH';
	my $entry = $door->{$key};
	$entry = {} unless ref $entry eq 'HASH';

	$entry->{'app'} = $app;
	$entry->{'direction'} = $DIRECTION{$component};
	$entry->{'edt'} = $edt;
	$entry->{'pin'} = "$pin";
	$entry->{'inverted'} = $data->{'inverted'} ? 1 : 0;
	$entry->{'movement'} = $data->{'movement'} || 'start';
	$door->{$key} = $entry;
	&setting_setter({
		app => $edt, setting => 'operator_door', subsetting => $chip_id,
		value => encode_json($door),
	});

	my $raw_ia = &setting_grabber({ app => $app, setting => 'ia' });
	my $ia = (defined $raw_ia && length $raw_ia) ? (eval { decode_json($raw_ia) } || {}) : {};
	$ia = {} unless ref $ia eq 'HASH';
	$ia->{$chip_id} = {} unless ref $ia->{$chip_id} eq 'HASH';
	$ia->{$chip_id}->{$pin} = { %{$entry} };
	&setting_setter({ app => $app, setting => 'ia', value => encode_json($ia) });

	return { ok => 1, attached => { %{$entry}, chip_id => $chip_id, key => $key } };
}

1;
