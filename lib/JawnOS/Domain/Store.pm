package subs;

# Store: the till behind the Store's Register. A walk-in customer is an order
# with no account - the sale is written against the app "Customer" - so the
# register never depends on a person existing in the customer table.
#
# Open orders are rows, keyed by their own id: several customers can stand at
# the counter at once, each tab independent, and giving one up (Cancel order /
# Void) is a delete, not a sale. They are rows rather than this worker's memory
# because the manager is a prefork pool - a tap may reach any worker and a
# worker is recycled after 500 connections - so an order kept in a hash vanished
# between one tap and the next. Finalising an order builds the sale document the
# printer and the customer journal already understand (data -> numbers,
# payments, register.items).
#
# The floorplan is the same idea for a room: a picture with named seats placed
# on it, and a seat is where an open order sits. A waiter taps a table, the
# order opens at the till, and the next tap is against the same order.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;

use POSIX ();
use Mojo::JSON qw(decode_json encode_json);

# The single seating plan row: a house has one room for now, and a later plan
# (an upstairs, a patio) is another row with its own uuid.
my $FLOORPLAN_UUID = 'store:floorplan';

# When this worker last ran the archive sweep, so a read does not write a row on
# every poll. It is a per-worker clock; two workers sweeping once a minute is
# harmless because the update matches only rows still open.
my $ORDER_SWEPT_AT = 0;

# A stored order and a stored seat are JSON; these read them back into the shape
# the routes, the printer and the browser already use. Code refs rather than
# named subs because they are this file's plumbing, not domain helpers another
# module calls by name.
my $order_items_decode = sub {
	my ($raw) = @_;
	my $items = eval { decode_json($raw // '') };
	$items = [] unless ref $items eq 'ARRAY';
	my @lines;
	foreach my $line ( @{$items} ) {
		next unless ref $line eq 'HASH';
		push @lines, {
			line => $line->{'line'} // '',
			item => $line->{'item'} // '',
			name => $line->{'name'} // '',
			price => &store_register_number($line->{'price'}),
			quantity => &store_register_number($line->{'quantity'}),
			tax_codes => &tax_codes_value($line->{'tax_codes'}),
		};
	}
	return \@lines;
};

my $order_row_read = sub {
	my ($row) = @_;
	return undef unless ref $row eq 'HASH';
	my $exemption = eval { decode_json($row->{'tax_exemption'} // '') };
	$exemption = { exempt => 0, id => '', country => '', codes => [] }
		unless ref $exemption eq 'HASH';
	my $app = $row->{'customer_app'} // '';
	my $name = $row->{'customer_name'} // '';
	return {
		id => $row->{'uuid'} // '',
		label => $row->{'label'} // '',
		created => 0 + ($row->{'created'} // 0),
		seat => $row->{'seat'} // '',
		# A row from before status existed has no value and is still open.
		status => length($row->{'status'} // '') ? $row->{'status'} : 'open',
		archived_at => $row->{'archived_at'} // '',
		customer => {
			cx => $row->{'customer_uuid'} // '',
			app => length($app) ? $app : 'Customer',
			name => length($name) ? $name : &lang('common.customer'),
		},
		tax_exemption => $exemption,
		items => $order_items_decode->($row->{'items'}),
	};
};

# Saving is always the whole order: the row is small, and a partial write is how
# a line and its quantity come to disagree.
my $order_row_write = sub {
	my ($order) = @_;
	return 0 unless ref $order eq 'HASH' && length($order->{'id'} // '');
	my $customer = ref $order->{'customer'} eq 'HASH' ? $order->{'customer'} : {};
	my $written = eval {
		&db_update('store_order', {
			label => $order->{'label'} // '',
			customer_uuid => $customer->{'cx'} // '',
			customer_app => $customer->{'app'} // '',
			customer_name => $customer->{'name'} // '',
			tax_exemption => encode_json($order->{'tax_exemption'} || {}),
			items => encode_json($order->{'items'} || []),
			seat => $order->{'seat'} // '',
			server_time => &rightNow(),
		}, { uuid => $order->{'id'} });
	};
	return $written ? 1 : 0;
};

my $floor_seats_clean = sub {
	my ($raw) = @_;
	my $list = ref $raw eq 'ARRAY' ? $raw : eval { decode_json($raw // '') };
	$list = [] unless ref $list eq 'ARRAY';
	my (@seats, %seen);
	foreach my $seat ( @{$list} ) {
		next unless ref $seat eq 'HASH';
		my $id = $seat->{'id'} // '';
		next unless length $id && !$seen{$id}++;
		my $x = &store_register_number($seat->{'x'});
		my $y = &store_register_number($seat->{'y'});
		$x = 0 if $x < 0 || $x > 100;
		$y = 0 if $y < 0 || $y > 100;
		my $covers = int(&store_register_number($seat->{'seats'}));
		$covers = 1 if $covers < 1;
		$covers = 99 if $covers > 99;
		my $kind = $seat->{'kind'} // '';
		$kind = 'table' unless $kind =~ /^(?:table|seat|booth|bar|stage)$/;
		push @seats, {
			id => $id,
			name => substr(($seat->{'name'} // ''), 0, 60),
			x => $x,
			y => $y,
			seats => $covers,
			kind => $kind,
		};
	}
	return \@seats;
};

# What the house may be paid with. These are stored values, never labels; the
# label is chosen with store_register_payment_label so a screen can translate
# it without the stored record changing language.
my @PAYMENT_METHODS = qw(cash credit interac bitcoin cheque);

# Cash offered in one physical note or coin at the counter.
my @DENOMINATIONS = (5, 10, 20, 50, 100);

# The change given back, largest first. Canada has no cent coin, so the smallest
# is five cents; the arithmetic rounds to that step when it names the pieces.
my @CHANGE_DENOMINATIONS = (100, 50, 20, 10, 5, 2, 1, 0.25, 0.10, 0.05, 0.01);

sub store_register_payment_methods {
	return [ @PAYMENT_METHODS ];
}

sub store_register_payment_valid {
	my ($method) = @_;
	$method = lc(defined $method ? $method : '');
	$method =~ s/^\s+|\s+$//g;
	return (grep { $_ eq $method } @PAYMENT_METHODS) ? $method : '';
}

sub store_register_payment_label {
	my ($method) = @_;
	$method = &store_register_payment_valid($method);
	return '' unless length $method;
	return &lang('common.cash') if $method eq 'cash';
	return &lang('store.' . $method);
}

sub store_register_denominations {
	return [ @DENOMINATIONS ];
}

# Money is a number to two places everywhere in this module; a stray symbol or
# a comma from a typed price must not turn into a different amount.
sub store_register_number {
	my ($value) = @_;
	return 0 unless defined $value && length $value;
	$value = "$value";
	$value =~ s/[^0-9.\-]//g;
	return 0 unless $value =~ /^-?\d*(?:\.\d*)?$/ && length $value;
	return 0 + sprintf('%.2f', $value);
}

sub store_register_totals {
	my ($items, $tax_settings) = @_;
	$items = [] unless ref $items eq 'ARRAY';
	# A hash is the catalog settings (each line's own codes, the Store default
	# for a line that names none); a plain number is the old single multiplier,
	# kept for callers that have no settings to pass.
	return &store_tax_totals($items, $tax_settings) if ref $tax_settings eq 'HASH';
	my $subtotal = 0;
	my $quantity = 0;
	foreach my $item ( @{$items} ) {
		next unless ref $item eq 'HASH';
		my $price = &store_register_number($item->{'price'});
		my $qty = &store_register_number($item->{'quantity'});
		$qty = 1 if $qty <= 0;
		$subtotal += $price * $qty;
		$quantity += $qty;
	}
	my $rate = &store_register_number($tax_settings);
	$rate = 1 if $rate <= 0;
	$subtotal = 0 + sprintf('%.2f', $subtotal);
	my $total = 0 + sprintf('%.2f', $subtotal * $rate);
	my $tax = 0 + sprintf('%.2f', $total - $subtotal);
	return {
		subtotal => $subtotal,
		tax => $tax,
		total => $total,
		quantity => $quantity,
		count => scalar @{$items},
		tax_rate => $rate,
	};
}

# The change to hand back. Received less the total, kept in cents so 20 - 19.99
# is a cent and not 0.009999. A short payment is reported, never silently
# rounded up into a completed sale.
sub store_register_change {
	my ($total, $received) = @_;
	$total = &store_register_number($total);
	$received = &store_register_number($received);
	my $cents = int($received * 100 + 0.5) - int($total * 100 + 0.5);
	my $change = 0 + sprintf('%.2f', $cents / 100);
	return {
		total => $total,
		received => $received,
		change => $change,
		short => $cents < 0 ? 1 : 0,
		exact => $cents == 0 ? 1 : 0,
		overpaid => $cents > 0 ? 1 : 0,
	};
}

# How to make that change with the notes and coins that exist. Cents in, a list
# of { amount, count } out; a non-positive change makes nothing.
sub store_register_change_breakdown {
	my ($change) = @_;
	my $cents = int(&store_register_number($change) * 100 + 0.5);
	$cents = 0 if $cents < 0;
	my @parts;
	foreach my $denomination ( @CHANGE_DENOMINATIONS ) {
		my $unit = int($denomination * 100 + 0.5);
		next unless $unit > 0;
		my $count = int($cents / $unit);
		next unless $count > 0;
		push @parts, { amount => $denomination + 0, count => $count };
		$cents -= $count * $unit;
	}
	return \@parts;
}

# How long an untouched open order stays on the counter. Configure - Store sets
# it per device; an empty or unreadable value is half a day, and the archive
# sweep never accepts a zero (a zero would archive an order the moment it was
# opened, which is not a setting a shop means).
sub store_order_hours {
	my $raw = &setting_grabber({ app => 'me', setting => 'open_order_hours' });
	my $hours = int(&store_register_number($raw));
	$hours = 12 unless $hours > 0;
	$hours = 720 if $hours > 720;
	return $hours;
}

# Archive the orders left untouched for longer than the house allows. Archive,
# not delete: the row keeps who the customer was and what was on the order, and
# the seat is freed so the table is free again. Returns the rows archived.
sub store_order_archive_stale {
	my ($hours, $device) = @_;
	$hours = &store_order_hours() unless defined $hours && $hours =~ /^\d+$/ && $hours > 0;
	$device = &device_setter() unless defined $device && length $device;
	my $now = &rightNow();
	my $cutoff = $now - ($hours * 3600 * 1000);
	my $rows = eval { &db_select('store_order', undef, { device => $device })->hashes } || [];
	my @stale = grep {
		(ref $_ eq 'HASH')
		&& (($_->{'status'} // '') ne 'archived')
		&& (0 + ($_->{'created'} // 0)) > 0
		&& (0 + ($_->{'created'} // 0)) < $cutoff
	} @{$rows};
	return 0 unless scalar @stale;
	eval {
		&db_query("update store_order set status = 'archived', archived_at = ?, seat = '', server_time = ? where device = ? and (status is null or status = '' or status = 'open') and cast(created as integer) > 0 and cast(created as integer) < ?", $now, $now, $device, $cutoff);
	};
	return scalar @stale;
}

sub store_register_orders {
	my ($params) = @_;
	$params = {} unless ref $params eq 'HASH';
	my $device = (defined $params->{'device'} && length $params->{'device'})
		? $params->{'device'} : &device_setter();
	# The sweep runs on the read every window already makes, at most once a
	# minute per worker: no timer of its own, and no write on every poll.
	my $now = &rightNow();
	if (!$params->{'no_sweep'} && (!$ORDER_SWEPT_AT || ($now - $ORDER_SWEPT_AT) > 60_000)) {
		$ORDER_SWEPT_AT = $now;
		&store_order_archive_stale(undef, $device);
	}
	my $rows = eval { &db_select('store_order', undef, { device => $device })->hashes } || [];
	my @orders = grep {
		(ref $_ eq 'HASH') && length($_->{'id'} // '') && (($_->{'status'} // 'open') ne 'archived')
	} map { $order_row_read->($_) } @{$rows};
	return [ sort { $a->{'created'} <=> $b->{'created'} || $a->{'id'} cmp $b->{'id'} } @orders ];
}

# A live order by id. An archived order is invisible to the till: a tab that was
# cleared off the counter must not come back by a stale browser tap. The second
# argument reads it anyway, for a report or a test.
sub store_register_order {
	my ($id, $include_archived) = @_;
	return undef unless defined $id && length $id;
	my $row = eval { &db_select('store_order', undef, { uuid => $id })->hashes->[0] };
	my $order = $order_row_read->($row);
	return undef unless $order;
	return undef if !$include_archived && (($order->{'status'} // 'open') eq 'archived');
	return $order;
}

sub store_register_order_open {
	my ($params) = @_;
	$params = {} unless ref $params eq 'HASH';
	my $device = (defined $params->{'device'} && length $params->{'device'})
		? $params->{'device'} : &device_setter();
	my $id = &random_string_creator(24);
	my $label = $params->{'label'};
	unless (defined $label && length $label) {
		# A fresh label per open order, so two tabs are told apart by name. The
		# count is read from the rows, not a worker's counter, which is the point;
		# archived rows are history and do not push the number up forever.
		my $count = eval { &db_query("select count(*) as n from store_order where device = ? and (status is null or status = '' or status = 'open')", $device)->hash->{'n'} } || 0;
		$label = &lang('common.customer') . ' ' . ($count + 1);
	}
	my $tax_exemption = (ref $params->{'tax_exemption'} eq 'HASH')
		? $params->{'tax_exemption'}
		: { exempt => 0, id => '', country => '', codes => [] };
	my $app = ($params->{'app'} && length $params->{'app'}) ? $params->{'app'} : 'Customer';
	my $name = ($params->{'name'} && length $params->{'name'}) ? $params->{'name'} : &lang('common.customer');
	my $now = &rightNow();
	my $written = eval {
		&db_insert('store_order', {
			uuid => $id,
			device => $device,
			label => $label,
			customer_uuid => $params->{'cx'} || '',
			customer_app => $app,
			customer_name => $name,
			tax_exemption => encode_json($tax_exemption),
			items => '[]',
			seat => $params->{'seat'} || '',
			status => 'open',
			created => $now,
			server_time => $now,
			ost => $now,
		});
	};
	return undef unless $written;
	return {
		id => $id,
		label => $label,
		created => 0 + $now,
		seat => $params->{'seat'} || '',
		status => 'open',
		customer => { cx => $params->{'cx'} || '', app => $app, name => $name },
		tax_exemption => $tax_exemption,
		items => [],
	};
}

sub store_register_order_line {
	my ($order, $line_id) = @_;
	return undef unless ref $order eq 'HASH' && ref $order->{'items'} eq 'ARRAY';
	return undef unless defined $line_id && length $line_id;
	foreach my $line ( @{$order->{'items'}} ) {
		return $line if ($line->{'line'} || '') eq $line_id;
	}
	return undef;
}

# A customer of their own, written onto the order. The caller names the app (a
# person, a corporation, a vendor, ...); an empty app means the walk-in again.
sub store_register_order_customer {
	my ($id, $params) = @_;
	my $order = &store_register_order($id);
	return undef unless $order;
	$params = {} unless ref $params eq 'HASH';
	my $app = ($params->{'app'} && length $params->{'app'}) ? $params->{'app'} : 'Customer';
	$order->{'customer'} = {
		cx => $params->{'cx'} || '',
		app => $app,
		name => ($params->{'name'} && length $params->{'name'}) ? $params->{'name'} : &format_name($app),
	};
	$order->{'tax_exemption'} = $params->{'tax_exemption'}
		if ref $params->{'tax_exemption'} eq 'HASH';
	$order->{'label'} = $params->{'label'} if defined $params->{'label'} && length $params->{'label'};
	return $order_row_write->($order) ? $order : undef;
}

# The seat an order is sitting at. An empty seat puts it back on the counter
# (the tab stays); the order is never deleted by a seat change.
sub store_register_order_seat {
	my ($id, $seat) = @_;
	my $order = &store_register_order($id);
	return undef unless $order;
	$order->{'seat'} = defined $seat ? "$seat" : '';
	return $order_row_write->($order) ? $order : undef;
}

sub store_register_order_add {
	my ($id, $item) = @_;
	my $order = &store_register_order($id);
	return undef unless $order;
	$item = {} unless ref $item eq 'HASH';
	my $price = &store_register_number($item->{'price'});
	my $quantity = &store_register_number($item->{'quantity'});
	$quantity = 1 if $quantity <= 0;
	my $name = $item->{'name'};
	$name = $item->{'item'} unless defined $name && length $name;
	$name = &format_name($name) if defined $name && length $name;
	$name = &lang('common.item') unless defined $name && length $name;
	my $app = $item->{'item'};
	$app = '' unless defined $app;
	# The same item at the same price is one line with more units; a different
	# price stays its own line, so a discount on one unit is not smeared over all.
	foreach my $line ( @{$order->{'items'}} ) {
		if (($line->{'item'} || '') eq $app && $line->{'price'} == $price) {
			$line->{'quantity'} += $quantity;
			return $order_row_write->($order) ? $order : undef;
		}
	}
	push @{$order->{'items'}}, {
		line => &random_string_creator(12),
		item => $app,
		name => $name,
		price => $price,
		quantity => $quantity,
		tax_codes => &tax_codes_value($item->{'tax_codes'}),
	};
	return $order_row_write->($order) ? $order : undef;
}

sub store_register_order_quantity {
	my ($id, $line_id, $quantity) = @_;
	my $order = &store_register_order($id);
	return undef unless $order;
	my $line = &store_register_order_line($order, $line_id);
	return undef unless $line;
	my $qty = &store_register_number($quantity);
	if ($qty <= 0) {
		@{$order->{'items'}} = grep { ($_->{'line'} || '') ne $line_id } @{$order->{'items'}};
	}
	else {
		$line->{'quantity'} = $qty;
	}
	return $order_row_write->($order) ? $order : undef;
}

sub store_register_order_remove {
	my ($id, $line_id) = @_;
	my $order = &store_register_order($id);
	return undef unless $order;
	@{$order->{'items'}} = grep { ($_->{'line'} || '') ne ($line_id || '') } @{$order->{'items'}};
	return $order_row_write->($order) ? $order : undef;
}

# Giving up an order records nothing: no appointment, no stock movement. This
# is the customer who walked out.
sub store_register_order_cancel {
	my ($id) = @_;
	return 0 unless defined $id && length $id;
	my $row = eval { &db_select('store_order', undef, { uuid => $id })->hashes->[0] };
	return 0 unless $row;
	eval { &db_delete('store_order', { uuid => $id }) };
	return 1;
}

# Drop this device's open orders. A shop that closes the register expecting a
# clean counter asks for it; a test uses it for that same clean counter.
sub store_register_order_reset {
	my ($params) = @_;
	$params = {} unless ref $params eq 'HASH';
	my $device = (defined $params->{'device'} && length $params->{'device'})
		? $params->{'device'} : &device_setter();
	eval { &db_delete('store_order', { device => $device }) };
	return 1;
}

# ---- the floor plan ---------------------------------------------------------
# One picture of the room and the seats placed on it, in percentages of the
# picture so the plan fits any screen. The plan is one JSON value on one row:
# placing a seat is a gesture on the same screen that shows the plan, and a
# half-written seat list is worse than a whole saved one.
# The pictures the house has tagged Floorplan in an appointment's details. The
# tag is written by the image function selector, which keeps this list beside
# the map, background, diagram, receipt and signatorial lists.
sub store_floorplan_images {
	my $raw = &setting_grabber({ app => 'store', setting => 'floorplans' });
	my $list = eval { decode_json($raw // '') } || [];
	$list = [] unless ref $list eq 'ARRAY';
	my @out;
	foreach my $entry ( @{$list} ) {
		next unless ref $entry eq 'HASH';
		my $file = $entry->{'f'} // '';
		next unless length $file && -e $file;
		(my $name = $file) =~ s{.*/}{};
		push @out, {
			file => $file,
			uuid => $entry->{'uuid'} // '',
			name => $entry->{'name'} || $name,
			app => $entry->{'app'} // '',
		};
	}
	return \@out;
}

sub store_floorplan {
	my $row = eval { &db_select('store_floorplan', undef, { uuid => $FLOORPLAN_UUID })->hashes->[0] };
	return {
		uuid => $FLOORPLAN_UUID,
		name => $row ? ($row->{'name'} // '') : '',
		image => $row ? ($row->{'image'} // '') : '',
		seats => $floor_seats_clean->($row ? $row->{'seats'} : '[]'),
	};
}

# Save the picture and the seats. A seat list is replaced whole; leaving the
# `seats` key out keeps what is stored, so changing the picture does not erase
# the tables on it.
sub store_floorplan_save {
	my ($params) = @_;
	$params = {} unless ref $params eq 'HASH';
	my $plan = &store_floorplan();
	$plan->{'name'} = substr("$params->{'name'}", 0, 120) if exists $params->{'name'};
	$plan->{'image'} = "$params->{'image'}" if exists $params->{'image'};
	$plan->{'seats'} = $floor_seats_clean->($params->{'seats'}) if exists $params->{'seats'};
	my $now = &rightNow();
	my $row = {
		name => $plan->{'name'},
		image => $plan->{'image'},
		seats => encode_json($plan->{'seats'}),
		server_time => $now,
	};
	my $existing = eval { &db_select('store_floorplan', undef, { uuid => $FLOORPLAN_UUID })->hashes->[0] };
	my $written = $existing
		? eval { &db_update('store_floorplan', { %{$row} }, { uuid => $FLOORPLAN_UUID }) }
		: eval { &db_insert('store_floorplan', { %{$row}, uuid => $FLOORPLAN_UUID, ost => $now }) };
	return undef unless $written;
	return &store_floorplan();
}

# The sale document. It is deliberately shaped like a quote/invoice data blob:
# existing printer rows, the customer journal and any report that reads
# data->numbers keep working, and data->register.items is the extra the receipt
# uses to print more than one line.
sub store_register_sale_data {
	my ($order, $method, $received, $app, $id, $tax_settings, $exemption) = @_;
	return { ok => 0, error => 'no order' } unless ref $order eq 'HASH';
	return { ok => 0, error => 'no items' } unless ref $order->{'items'} eq 'ARRAY' && scalar @{$order->{'items'}};
	# A hash is the catalog settings, a number is the legacy single multiplier,
	# and nothing means read the Store's own switch and catalog now. An exempt
	# sale charges no tax at all, whatever the catalog says.
	$tax_settings = &store_tax_settings()
		unless ref $tax_settings eq 'HASH' || (defined $tax_settings && length $tax_settings);
	my $exempt = ref $exemption eq 'HASH' ? $exemption : {};
	my $exempt_on = $exempt->{'exempt'} ? 1 : 0;
	my $exemption_id = $exempt_on ? ($exempt->{'id'} // '') : '';
	my $totals_settings = $tax_settings;
	$totals_settings = ref $tax_settings eq 'HASH' ? { %{$tax_settings}, enabled => 0 } : 1
		if $exempt_on;
	my $payment = &store_register_payment_valid($method);
	$payment = 'cash' unless length $payment;
	my $totals = &store_register_totals($order->{'items'}, $totals_settings);
	# Canada has no penny: a cash sale is rounded to the nearest five cents (the
	# house setting), while a card sale keeps the exact total. The rounding is
	# recorded beside the exact subtotal and tax so the receipt can show it.
	my $cash_rounding = { exact => $totals->{'total'}, step => 0, rounded => $totals->{'total'}, rounding => 0 };
	if ($payment eq 'cash') {
		$cash_rounding = &cash_rounding_apply($totals->{'total'}, &cash_rounding_home_currency());
		$totals->{'rounding'} = $cash_rounding->{'rounding'};
		$totals->{'cash_total'} = $cash_rounding->{'rounded'};
		$totals->{'total'} = $cash_rounding->{'rounded'};
	}
	my $cash = &store_register_change($totals->{'total'}, $received);
	# A cash payment must cover the sale; card and the rest are charged the total.
	$received = $totals->{'total'} if $payment ne 'cash';
	$cash = &store_register_change($totals->{'total'}, $received);
	my @lines;
	foreach my $item ( @{$order->{'items'}} ) {
		my $price = &store_register_number($item->{'price'});
		my $quantity = &store_register_number($item->{'quantity'});
		my $line_total = 0 + sprintf('%.2f', $price * $quantity);
		my $codes = &tax_codes_value($item->{'tax_codes'});
		# What this line charged, so a later catalog change never rewrites an
		# old bill. An exempt sale has no tax on any line.
		my $line_taxes = [];
		if (!$exempt_on && ref $tax_settings eq 'HASH' && $tax_settings->{'enabled'}) {
			$line_taxes = &store_tax_line_snapshot($line_total, $codes, $tax_settings);
		}
		push @lines, {
			item => $item->{'item'} || '',
			name => $item->{'name'} || '',
			price => $price,
			quantity => $quantity,
			total => $line_total,
			tax_codes => $codes,
			taxes => $line_taxes,
		};
	}
	my $first = $lines[0] || { name => '', price => 0, quantity => 1 };
	my $label = &store_register_payment_label($payment);
	my $timestamp = &rightNow();
	my $data = {
		id => $id || '',
		item => join(', ', map { $_->{'name'} } @lines),
		model => {
			uuid => '',
			name => $first->{'name'},
			price => $first->{'price'},
			quantity => $first->{'quantity'},
			discount => 0,
			tax => 0,
			tax_rate => $totals->{'tax_rate'},
			description => '',
		},
		options => {},
		register => {
			items => \@lines,
			payment => $payment,
			customer => $app || 'Customer',
			tax_exemption => $exemption_id,
		},
		numbers => {
			subtotal => $totals->{'subtotal'},
			discount => 0,
			tax => $totals->{'tax'},
			taxes => $totals->{'taxes'} || [],
			rounding => $totals->{'rounding'} || 0,
			cash_total => $totals->{'cash_total'} || $totals->{'total'},
			aux => 0,
			total => $totals->{'total'},
			balance => 0,
		},
		tax_exemption => $exemption_id,
		payments => [{
			method => $payment,
			label => $label,
			amount => $totals->{'total'},
			tendered => $cash->{'received'},
			change => $cash->{'change'},
			timestamp => $timestamp,
			account => $label,
		}],
	};
	return {
		ok => 1,
		data => $data,
		totals => $totals,
		change => $cash,
		payment => {
			method => $payment,
			label => $label,
			amount => $totals->{'total'},
			tendered => $cash->{'received'},
			change => $cash->{'change'},
		},
	};
}

# ---- document numbering -----------------------------------------------------
# A document's id is a human label, not its identity: the appointment uuid is
# what refers to it. Invoices and sales share one series (a sale is an invoice
# at the till); quotes have their own, so an invoice number is never spent on a
# quote that was never accepted. Both start at 1001.
my %NUMBERING_SERIES = (
	invoice => { start => 1001, prefix => '' },
	quote   => { start => 1001, prefix => 'Q-' },
);

sub store_numbering_series {
	my ($series) = @_;
	$series = lc(defined $series ? $series : '');
	return exists $NUMBERING_SERIES{$series} ? $series : 'invoice';
}

sub store_numbering_format {
	my ($series, $number) = @_;
	my $key = &store_numbering_series($series);
	return '' unless defined $number && $number =~ /^\d+$/;
	return $NUMBERING_SERIES{$key}->{'prefix'} . ($number + 0);
}

sub store_numbering_row {
	my ($series) = @_;
	my $key = &store_numbering_series($series);
	my $q = &db_select('numbering', undef, { series => $key });
	my $row = $q ? $q->hashes->[0] : undef;
	unless ($row) {
		my $now = &rightNow();
		&db_insert('numbering', {
			uuid => 'numbering:' . $key,
			series => $key,
			next_number => $NUMBERING_SERIES{$key}->{'start'},
			block_size => 100,
			timestamp => $now,
			server_time => $now,
		});
		my $again = &db_select('numbering', undef, { series => $key });
		$row = $again ? $again->hashes->[0] : undef;
		$row ||= { series => $key, next_number => $NUMBERING_SERIES{$key}->{'start'} };
	}
	return $row;
}

# The machine that owns the counter. A server mints locally; every other machine
# asks its server over the relay. A house with no server row has no authority:
# it falls back to whatever block it already holds.
sub store_numbering_hub {
	return undef if (&device_setter() // '') eq 'server';
	my $q = &db_select('remote_machines', undef, { device => 'server' });
	my @rows = $q ? @{ $q->hashes || [] } : ();
	return undef unless scalar @rows;
	my ($active) = grep { ($_->{'connection'} // '') eq 'active' } @rows;
	return $active || $rows[0];
}

sub store_numbering_relay {
	my ($path, $params) = @_;
	my $hub = &store_numbering_hub();
	return undef unless $hub;
	$params = {} unless ref $params eq 'HASH';
	$params->{'signatorial'} = &signatorial_designer();
	my $body = eval {
		return &relay_headless({
			path => $path,
			method => 'POST',
			remote_uuid => $hub->{'uuid'},
			params => $params,
			expect_json => 1,
		});
	};
	return undef unless defined $body && $body =~ /^\s*\{/;
	my $json = eval { decode_json $body } || {};
	return ref $json eq 'HASH' ? $json : undef;
}

sub store_numbering_mint_local {
	my ($series) = @_;
	my $key = &store_numbering_series($series);
	&store_numbering_row($key);
	my $now = &rightNow();
	my $q = &db_query('update numbering set next_number = next_number + 1, server_time = ?, timestamp = ? where series = ? returning next_number as after_next', $now, $now, $key);
	my $row = $q ? $q->hash : undef;
	return undef unless $row && defined $row->{'after_next'};
	my $number = $row->{'after_next'} + 0 - 1;
	return { series => $key, number => $number, id => &store_numbering_format($key, $number) };
}

sub store_numbering_block_reserve_local {
	my ($series, $device, $size) = @_;
	my $key = &store_numbering_series($series);
	$size = 100 unless defined $size && $size =~ /^\d+$/ && $size > 0;
	$size = 1000 if $size > 1000;
	&store_numbering_row($key);
	my $now = &rightNow();
	my $q = &db_query('update numbering set next_number = next_number + ?, server_time = ?, timestamp = ? where series = ? returning next_number as after_next', $size, $now, $now, $key);
	my $row = $q ? $q->hash : undef;
	return undef unless $row && defined $row->{'after_next'};
	my $after = $row->{'after_next'} + 0;
	return {
		series => $key,
		device => defined $device ? $device : '',
		from => $after - $size,
		to => $after - 1,
		size => $size,
	};
}

sub store_numbering_block_rows {
	my ($series) = @_;
	my $key = &store_numbering_series($series);
	my $sig = &signatorial_designer();
	my $q = &db_query('select * from number_blocks where series = ? and device = ? order by from_number asc', $key, $sig);
	return $q ? ( $q->hashes || [] ) : [];
}

sub store_numbering_block_remaining {
	my ($series) = @_;
	my $key = &store_numbering_series($series);
	my $sig = &signatorial_designer();
	my $q = &db_query('select coalesce(sum(case when used <= to_number then to_number - used + 1 else 0 end),0) as left from number_blocks where series = ? and device = ?', $key, $sig);
	my $row = $q ? $q->hash : undef;
	return ($row && defined $row->{'left'}) ? $row->{'left'} + 0 : 0;
}

sub store_numbering_block_take {
	my ($series) = @_;
	my $key = &store_numbering_series($series);
	my $sig = &signatorial_designer();
	my $now = &rightNow();
	my $q = &db_query('update number_blocks set used = used + 1, server_time = ?, timestamp = ? where uuid = (select uuid from number_blocks where series = ? and device = ? and used <= to_number order by used asc limit 1) and used <= to_number returning used as after_used', $now, $now, $key, $sig);
	my $row = $q ? $q->hash : undef;
	return undef unless $row && defined $row->{'after_used'};
	my $number = $row->{'after_used'} + 0 - 1;
	return { series => $key, number => $number, id => &store_numbering_format($key, $number), offline => 1 };
}

sub store_numbering_block_ensure {
	my ($series) = @_;
	my $key = &store_numbering_series($series);
	return undef if (&device_setter() // '') eq 'server';
	my ($open) = grep { ($_->{'used'} // 0) + 0 <= ($_->{'to_number'} // 0) + 0 } @{ &store_numbering_block_rows($key) };
	return 1 if $open;
	my $sig = &signatorial_designer();
	my $answer = &store_numbering_relay('/manager/store/number_block', { series => $key, device => $sig, size => 100 });
	return 0 unless $answer && $answer->{'ok'} && defined $answer->{'from'} && defined $answer->{'to'};
	my $now = &rightNow();
	&db_insert('number_blocks', {
		uuid => &random_string_creator(25),
		series => $key,
		device => $sig,
		from_number => $answer->{'from'} + 0,
		to_number => $answer->{'to'} + 0,
		used => $answer->{'from'} + 0,
		timestamp => $now,
		server_time => $now,
	});
	return 1;
}

# Mint one document number. The hub is asked first; a device that cannot reach
# it takes from its reserved block. The block is reserved after a successful
# online mint, so a machine that has written an invoice online carries 100
# numbers into a place with no network. If the hub is away and no block is left,
# the caller must not write a document: a duplicate is worse than a retry.
sub store_numbering_mint {
	my ($series) = @_;
	my $key = &store_numbering_series($series);
	if ((&device_setter() // '') eq 'server') {
		return &store_numbering_mint_local($key);
	}
	my $answer = &store_numbering_relay('/manager/store/number_mint', { series => $key });
	if ($answer && $answer->{'ok'} && defined $answer->{'number'}) {
		&store_numbering_block_ensure($key);
		my $number = $answer->{'number'} + 0;
		return { series => $key, number => $number, id => $answer->{'id'} || &store_numbering_format($key, $number) };
	}
	my $offline = &store_numbering_block_take($key);
	return $offline if $offline;
	return { series => $key, error => 'the numbering authority could not be reached and no reserved block is left' };
}

# What Configure -> Store's numbering card shows: the next number in each
# series and how many numbers this device can still mint with no network. The
# counter is the last value the house synced; the block is exact because only
# this device writes its `used`.
sub store_numbering_status {
	my $authority = ((&device_setter() // '') eq 'server') ? 1 : 0;
	my $hub = $authority ? undef : &store_numbering_hub();
	my %series;
	my $sig = &signatorial_designer();
	foreach my $key ( sort keys %NUMBERING_SERIES ) {
		my $row = eval { &store_numbering_row($key) } || {};
		my $next = (defined $row->{'next_number'} && $row->{'next_number'} =~ /^\d+$/)
			? $row->{'next_number'} + 0
			: $NUMBERING_SERIES{$key}->{'start'};
		my $q = eval { &db_query('select * from number_blocks where series = ? and device = ? and used <= to_number order by used asc', $key, $sig) };
		my @blocks = $q ? @{ $q->hashes || [] } : ();
		my $remaining = 0;
		my ($from, $to, $used);
		foreach my $block ( @blocks ) {
			my $left = ($block->{'to_number'} // 0) + 0 - ($block->{'used'} // 0) + 0 + 1;
			next unless $left > 0;
			$remaining += $left;
			($from, $to, $used) = (($block->{'from_number'} // 0) + 0, ($block->{'to_number'} // 0) + 0, ($block->{'used'} // 0) + 0)
				unless defined $from;
		}
		$series{$key} = {
			series => $key,
			next => $next,
			next_id => &store_numbering_format($key, $next),
			remaining => $remaining,
			block_from => $from,
			block_to => $to,
			block_used => $used,
			authority => $authority,
		};
	}
	return {
		authority => $authority,
		hub => ($hub ? ($hub->{'hostname'} || $hub->{'fqdn'} || '') : ''),
		series => \%series,
	};
}

# A document's lines. A quote/invoice built before multi-line support has one
# model and its options; a register sale has register.items. Everything that
# reads a document asks here, so the old shapes keep working while new
# documents write lines.
sub store_document_lines {
	my ($data) = @_;
	return [] unless ref $data eq 'HASH';
	if (ref $data->{'lines'} eq 'ARRAY' && scalar @{$data->{'lines'}}) {
		return [ grep { ref $_ eq 'HASH' } @{$data->{'lines'}} ];
	}
	my $register = ref $data->{'register'} eq 'HASH' ? $data->{'register'} : undef;
	if ($register && ref $register->{'items'} eq 'ARRAY' && scalar @{$register->{'items'}}) {
		return [ map {
			{
				item => $_->{'item'} || '',
				model => {
					name => $_->{'name'} || '',
					price => $_->{'price'} || 0,
					quantity => $_->{'quantity'} || 1,
					total => $_->{'total'} || 0,
				},
				options => {},
			}
		} grep { ref $_ eq 'HASH' } @{$register->{'items'}} ];
	}
	my $model = ref $data->{'model'} eq 'HASH' ? $data->{'model'} : {};
	my $options = ref $data->{'options'} eq 'HASH' ? $data->{'options'} : {};
	return [ { item => $data->{'item'} || '', model => $model, options => $options } ];
}

# The item and quantity a document's stock movement should carry, one per line.
# For a register sale the line's `item` is the store app; for a quote it is the
# line's own item. A line with no item cannot move stock.
sub store_document_stock_lines {
	my ($data) = @_;
	my @out;
	foreach my $line ( @{ &store_document_lines($data) } ) {
		my $item = $line->{'item'} || '';
		next unless defined $item && length $item;
		my $model = ref $line->{'model'} eq 'HASH' ? $line->{'model'} : {};
		my $quantity = &store_register_number($model->{'quantity'});
		$quantity = 1 if $quantity <= 0;
		push @out, {
			item => $item,
			quantity => $quantity,
			unit => $model->{'unit'} || '',
			model => $model->{'uuid'} || '',
		};
	}
	return \@out;
}

sub store_document_item_label {
	my ($data) = @_;
	my @names;
	foreach my $line ( @{ &store_document_lines($data) } ) {
		my $name = ref $line->{'model'} eq 'HASH' ? ($line->{'model'}->{'name'} || '') : '';
		push @names, $name if length $name;
	}
	return join(' · ', @names);
}

1;
