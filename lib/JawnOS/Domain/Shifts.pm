package subs;

# Till shifts: the drawer a Store register is worked out of. A shift is opened
# with a float and an associate, every cash sale made while it is open is tied to
# it, and End of day counts the drawer, records over or short, and locks it.
#
# The arithmetic lives here rather than in the route so the till, a report and a
# test all read the same numbers. Locked is the ordinary closed status: a shift
# that is closed is never reopened, so the next cash sale needs a new one.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;

use Mojo::JSON qw(decode_json);

sub shift_open {
	my ($params) = @_;
	$params = {} unless ref $params eq 'HASH';
	my $device = (defined $params->{'device'} && length $params->{'device'})
		? $params->{'device'}
		: &device_setter();
	return { ok => 0, error => 'a till is already open on this device' }
		if &shift_current($device);
	my $associate = defined $params->{'associate'} ? "$params->{'associate'}" : '';
	$associate =~ s/^\s+|\s+$//g;
	# Cash in the drawer cannot be negative; a typed minus is a zero float.
	my $float = &tax_number($params->{'float'});
	$float = 0 if $float < 0;
	my $now = &rightNow();
	my $row = {
		uuid => &random_string_creator(15),
		device => $device,
		associate => $associate,
		associate_uuid => ($params->{'associate_uuid'} // ''),
		opened_at => $now,
		closed_at => '',
		float => $float,
		expected => '',
		counted => '',
		over_short => '',
		cash_sales => 0,
		refunds => 0,
		status => 'open',
		notes => '',
		server_time => $now,
		ost => $now,
	};
	my $written = eval { &db_insert('store_shift', { %{$row} }) };
	return { ok => 0, error => 'the shift could not be recorded' } unless $written;
	return { ok => 1, shift => $row };
}

# The shift this device is working out of, or undef. A device has one at a time;
# a closed row is history and is never returned as current.
sub shift_current {
	my ($device) = @_;
	$device = &device_setter() unless defined $device && length $device;
	my $rows = eval { &db_select('store_shift', undef, { device => $device, status => 'open' })->hashes } || [];
	my ($open) = sort { ($b->{'opened_at'} || 0) <=> ($a->{'opened_at'} || 0) } grep {
		ref $_ eq 'HASH' && (($_->{'status'} // '') eq 'open')
	} @{$rows};
	return $open;
}

# The sales that belong to a shift. The shift's uuid rides in the sale's data
# blob (data.register.shift_uuid), which is LONGTEXT, so the match is decoded in
# Perl and bounded by the shift's own opened and closed times.
sub shift_sales {
	my ($shift) = @_;
	return () unless ref $shift eq 'HASH';
	my $uuid = $shift->{'uuid'} // '';
	return () unless length $uuid;
	my $opened = &tax_number($shift->{'opened_at'});
	my $closed = &tax_number($shift->{'closed_at'});
	my $rows = eval { &db_select('appointments', undef, { type => 'sale' })->hashes } || [];
	my @sales;
	foreach my $row ( @{$rows} ) {
		next unless ref $row eq 'HASH';
		my $when = &tax_number($row->{'timestamp'});
		next if $opened && $when < $opened;
		next if $closed && $when > $closed;
		my $data = eval { decode_json($row->{'data'}) } || {};
		next unless ref $data eq 'HASH';
		my $register = ref $data->{'register'} eq 'HASH' ? $data->{'register'} : {};
		next unless ($register->{'shift_uuid'} // '') eq $uuid;
		push @sales, { %{$row}, data => $data };
	}
	return @sales;
}

# What the drawer should hold: the float, plus the cash taken, less the cash
# handed back. Only a cash payment counts; a negative amount is a refund, not a
# sale. Card and the rest never touch the drawer figure.
sub shift_expected {
	my ($shift) = @_;
	my $float = &tax_number(($shift || {})->{'float'});
	my ($cash, $refunds) = (0, 0);
	foreach my $sale ( &shift_sales($shift) ) {
		my $data = $sale->{'data'} || {};
		my $register = ref $data->{'register'} eq 'HASH' ? $data->{'register'} : {};
		my $payments = ref $data->{'payments'} eq 'ARRAY' ? $data->{'payments'} : [];
		my $numbers = ref $data->{'numbers'} eq 'HASH' ? $data->{'numbers'} : {};
		my $first = ref $payments->[0] eq 'HASH' ? $payments->[0] : {};
		my $method = lc($register->{'payment'} // $first->{'method'} // '');
		next unless $method eq 'cash';
		my $amount = &tax_number($first->{'amount'});
		$amount = &tax_number($numbers->{'total'}) unless $amount;
		if ($amount < 0) { $refunds += -$amount; }
		else { $cash += $amount; }
	}
	$cash = 0 + sprintf('%.2f', $cash);
	$refunds = 0 + sprintf('%.2f', $refunds);
	return {
		float => $float,
		cash_sales => $cash,
		refunds => $refunds,
		expected => 0 + sprintf('%.2f', $float + $cash - $refunds),
	};
}

# Count the drawer and lock the shift. A closed shift is refused, so a second
# End of day cannot rewrite the over or short that was signed off.
sub shift_close {
	my ($uuid, $counted, $notes) = @_;
	return { ok => 0, error => 'no shift' } unless defined $uuid && length $uuid;
	my $row = eval { &db_select('store_shift', undef, { uuid => $uuid })->hashes->[0] };
	return { ok => 0, error => 'no shift' } unless ref $row eq 'HASH';
	return { ok => 0, error => 'the shift is already closed' }
		unless (($row->{'status'} // '') eq 'open');
	my $expected = &shift_expected($row);
	my $counted_n = &tax_number($counted);
	my $now = &rightNow();
	my $update = {
		status => 'closed',
		closed_at => $now,
		counted => $counted_n,
		expected => $expected->{'expected'},
		cash_sales => $expected->{'cash_sales'},
		refunds => $expected->{'refunds'},
		over_short => 0 + sprintf('%.2f', $counted_n - $expected->{'expected'}),
		notes => (defined $notes ? "$notes" : ''),
		server_time => $now,
	};
	eval { &db_update('store_shift', { %{$update} }, { uuid => $uuid }) };
	my $closed = { %{$row}, %{$update} };
	return { ok => 1, shift => $closed, report => &shift_report($closed) };
}

# The Z-report: one hash with the shift's own figures, so a screen and a printed
# summary read the same numbers.
sub shift_report {
	my ($shift) = @_;
	return undef unless ref $shift eq 'HASH';
	my $expected = &shift_expected($shift);
	my $sales = [ &shift_sales($shift) ];
	return {
		uuid => $shift->{'uuid'} // '',
		associate => $shift->{'associate'} // '',
		associate_uuid => $shift->{'associate_uuid'} // '',
		opened_at => $shift->{'opened_at'} // '',
		closed_at => $shift->{'closed_at'} // '',
		status => $shift->{'status'} // '',
		notes => $shift->{'notes'} // '',
		float => $expected->{'float'},
		cash_sales => $expected->{'cash_sales'},
		refunds => $expected->{'refunds'},
		expected => $expected->{'expected'},
		counted => (defined $shift->{'counted'} && length $shift->{'counted'}) ? &tax_number($shift->{'counted'}) : undef,
		over_short => (defined $shift->{'over_short'} && length $shift->{'over_short'}) ? &tax_number($shift->{'over_short'}) : undef,
		sales => scalar @{$sales},
	};
}

# A house switch for shops that will not take cash without a drawer open. It is
# off by default so a register that never opened a till keeps working.
sub store_shift_required {
	my $raw = &setting_grabber({ app => 'me', setting => 'store_shift_required', device => &warranty_device() });
	return 0 unless defined $raw && length $raw;
	return ($raw eq 'on' || $raw eq '1' || $raw eq 'yes') ? 1 : 0;
}

1;
