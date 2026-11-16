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
use Digest::SHA qw(sha256_hex);
use Mojo::Util qw(secure_compare);

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
	my ($uuid, $counted, $notes, $closer) = @_;
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
	if (ref $closer eq 'HASH' && length($closer->{'uuid'} // '')) {
		$update->{'closed_by'} = $closer->{'name'} // '';
		$update->{'closed_by_uuid'} = $closer->{'uuid'};
	}
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
		closed_by => $shift->{'closed_by'} // '',
		closed_by_uuid => $shift->{'closed_by_uuid'} // '',
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

# ---- who is at the till -----------------------------------------------------
# A person proves they are the one opening or closing the drawer. The PIN is the
# guaranteed path: four to eight digits, never stored, only a salted hash. A tag
# carries a minted token and the token's hash is what the people row keeps. A
# passkey is verified by perl/webauthn.pl, whose credentials already name the
# person they were enrolled for.
#
# The unlock is a fifteen-minute fact in the session, not a login: opening a till
# does not widen what the session may reach, and End of day cannot use it once it
# has lapsed.

my $TILL_UNLOCK_MS = 15 * 60 * 1000;
my $TILL_PIN_WINDOW = 5 * 60 * 1000;
my $TILL_PIN_MAX_FAILS = 5;

sub till_pin_valid {
	my ($pin) = @_;
	return 0 unless defined $pin;
	return "$pin" =~ /^[0-9]{4,8}$/ ? 1 : 0;
}

# A person named at the counter, by uuid, app or name. The same lookup opens a
# shift and finds the owner of the PIN, so the two cannot disagree.
sub till_person_find {
	my ($associate) = @_;
	$associate = defined $associate ? "$associate" : '';
	$associate =~ s/^\s+|\s+$//g;
	return undef unless length $associate;
	my $person = eval { &db_select('people', undef, { uuid => $associate, status => 'active' })->hash };
	return $person if ref $person eq 'HASH' && length($person->{'uuid'} // '');
	my $app = eval { &unformat_name($associate) } // '';
	if (length $app) {
		$person = eval { &db_select('people', undef, { app => $app, status => 'active' })->hash };
		return $person if ref $person eq 'HASH' && length($person->{'uuid'} // '');
	}
	$person = eval { &db_select('people', undef, { name => $associate, status => 'active' })->hash };
	return $person if ref $person eq 'HASH' && length($person->{'uuid'} // '');
	return undef;
}

# Store a new PIN. Only the salt and the hash are written; the PIN itself never
# reaches a row, a log or a reply.
sub till_pin_set {
	my ($person_uuid, $pin) = @_;
	return { ok => 0, error => 'no person' } unless defined $person_uuid && length $person_uuid;
	return { ok => 0, error => 'a PIN is 4 to 8 digits' } unless &till_pin_valid($pin);
	my $person = &till_person_find($person_uuid);
	return { ok => 0, error => 'no such person' } unless $person;
	my $salt = &random_string_creator(32, 'Aa0');
	my $hash = sha256_hex($salt . "\0" . $pin);
	my $now = &rightNow();
	my $written = eval {
		&db_update('people', {
			pin_hash => $hash,
			pin_salt => $salt,
			pin_set_at => $now,
			server_time => $now,
		}, { uuid => $person->{'uuid'} });
		1;
	};
	return { ok => 0, error => 'the PIN could not be saved' } unless $written;
	# A new PIN starts with a clean slate.
	eval { &db_query('delete from cache where context = ? and app = ?', 'till_pin_fail', $person->{'uuid'}) };
	return { ok => 1, person => { uuid => $person->{'uuid'}, name => $person->{'name'} // '' } };
}

# Failed PINs are counted per person in the cache. Five inside five minutes
# refuse further tries until the oldest failure ages out, which is the same
# rolling window a person reads as "wait five minutes".
sub till_pin_fail_count {
	my ($person_uuid, $now) = @_;
	$now = &rightNow() unless defined $now;
	my $count = eval {
		&db_query(
			'select count(*) as n from cache where context = ? and app = ? and server_time > ?',
			'till_pin_fail', $person_uuid, $now - $TILL_PIN_WINDOW
		)->hash->{'n'};
	};
	return $count ? int($count) : 0;
}

sub till_pin_check {
	my ($person_uuid, $pin) = @_;
	return { ok => 0, error => 'no person' } unless defined $person_uuid && length $person_uuid;
	return { ok => 0, error => 'a PIN is 4 to 8 digits' } unless &till_pin_valid($pin);
	my $now = &rightNow();
	eval { &db_query('delete from cache where context = ? and server_time < ?', 'till_pin_fail', $now - $TILL_PIN_WINDOW) };
	return { ok => 0, error => 'too many attempts - wait five minutes', rate_limited => 1 }
		if &till_pin_fail_count($person_uuid, $now) >= $TILL_PIN_MAX_FAILS;
	my $person = eval { &db_select('people', undef, { uuid => $person_uuid, status => 'active' })->hash };
	return { ok => 0, error => 'no such person' } unless ref $person eq 'HASH' && length($person->{'uuid'} // '');
	my $stored = $person->{'pin_hash'} // '';
	my $salt = $person->{'pin_salt'} // '';
	return { ok => 0, error => 'this person has no till PIN' } unless length $stored && length $salt;
	my $try = sha256_hex($salt . "\0" . $pin);
	if (secure_compare($stored, $try)) {
		eval { &db_query('delete from cache where context = ? and app = ?', 'till_pin_fail', $person_uuid) };
		return { ok => 1, person => { uuid => $person->{'uuid'}, name => $person->{'name'} // '' } };
	}
	eval {
		&db_insert('cache', {
			uuid => 'tillpin:' . $person_uuid . ':' . &random_string_creator(12),
			context => 'till_pin_fail',
			app => $person_uuid,
			server_time => $now,
			timestamp => $now,
		});
	};
	return { ok => 0, error => 'that PIN is not right' };
}

# A tag token is minted once, shown once and kept only as its hash. Minting a
# new one is what revokes the old tag.
sub till_token_mint {
	my ($person_uuid) = @_;
	return { ok => 0, error => 'no person' } unless defined $person_uuid && length $person_uuid;
	my $person = &till_person_find($person_uuid);
	return { ok => 0, error => 'no such person' } unless $person;
	my $token = &random_string_creator(48, 'Aa0');
	my $now = &rightNow();
	my $written = eval {
		&db_update('people', {
			till_token_hash => sha256_hex($token),
			till_token_at => $now,
			server_time => $now,
		}, { uuid => $person->{'uuid'} });
		1;
	};
	return { ok => 0, error => 'the tag token could not be saved' } unless $written;
	return { ok => 1, token => $token, person => { uuid => $person->{'uuid'}, name => $person->{'name'} // '' } };
}

sub till_token_check {
	my ($token) = @_;
	return { ok => 0, error => 'no tag token' } unless defined $token && length $token;
	my $person = eval {
		&db_select('people', undef, { till_token_hash => sha256_hex($token), status => 'active' })->hash;
	};
	return { ok => 0, error => 'that tag is not a till tag' }
		unless ref $person eq 'HASH' && length($person->{'uuid'} // '');
	return { ok => 1, person => { uuid => $person->{'uuid'}, name => $person->{'name'} // '' } };
}

# The session holds the person and the moment the proof stops counting. It is
# deliberately not an authentication session: it only answers "who is at the
# drawer" for the shift routes.
sub till_unlock_store {
	my ($c, $person) = @_;
	return undef unless ref $person eq 'HASH' && length($person->{'uuid'} // '');
	return undef unless ref $c && $c->can('session');
	my $unlock = {
		person_uuid => $person->{'uuid'},
		name => ($person->{'name'} // ''),
		expires => &rightNow() + $TILL_UNLOCK_MS,
	};
	eval { $c->session(till_unlock => $unlock) };
	return $unlock;
}

sub till_unlock_current {
	my ($c) = @_;
	return undef unless ref $c && $c->can('session');
	my $unlock = eval { $c->session('till_unlock') };
	return undef unless ref $unlock eq 'HASH';
	my $expires = &tax_number($unlock->{'expires'});
	if (!$expires || $expires <= &rightNow() || !length($unlock->{'person_uuid'} // '')) {
		eval { $c->session(till_unlock => undef) };
		return undef;
	}
	return $unlock;
}

1;
