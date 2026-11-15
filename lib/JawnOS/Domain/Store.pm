package subs;

# Store: the till behind the Store's Register. A walk-in customer is an order
# with no account - the sale is written against the app "Customer" - so the
# register never depends on a person existing in the customer table.
#
# Open orders live in this worker's memory, keyed by their own id: several
# customers can stand at the counter at once, each tab independent, and giving
# one up (Cancel order / Void) is a delete here, not a sale. Finalising an
# order builds the sale document the printer and the customer journal already
# understand (data -> numbers, payments, register.items).
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;

use POSIX ();

our %REGISTER_ORDERS;
our $REGISTER_ORDER_SEQ = 0;

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

sub store_register_orders {
	return [ sort { $a->{'created'} <=> $b->{'created'} || $a->{'id'} cmp $b->{'id'} }
		values %REGISTER_ORDERS ];
}

sub store_register_order {
	my ($id) = @_;
	return undef unless defined $id && length $id;
	return $REGISTER_ORDERS{$id};
}

sub store_register_order_open {
	my ($params) = @_;
	$params = {} unless ref $params eq 'HASH';
	$REGISTER_ORDER_SEQ++;
	my $id = &random_string_creator(24);
	my $label = $params->{'label'};
	unless (defined $label && length $label) {
		$label = &lang('common.customer') . ' ' . $REGISTER_ORDER_SEQ;
	}
	my $tax_exemption = (ref $params->{'tax_exemption'} eq 'HASH')
		? $params->{'tax_exemption'}
		: { exempt => 0, id => '', country => '', codes => [] };
	my $order = {
		id => $id,
		label => $label,
		created => &rightNow(),
		customer => {
			cx => $params->{'cx'} || '',
			app => ($params->{'app'} && length $params->{'app'}) ? $params->{'app'} : 'Customer',
			name => ($params->{'name'} && length $params->{'name'}) ? $params->{'name'} : &lang('common.customer'),
		},
		tax_exemption => $tax_exemption,
		items => [],
	};
	$REGISTER_ORDERS{$id} = $order;
	return $order;
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
			return $order;
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
	return $order;
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
		return $order;
	}
	$line->{'quantity'} = $qty;
	return $order;
}

sub store_register_order_remove {
	my ($id, $line_id) = @_;
	my $order = &store_register_order($id);
	return undef unless $order;
	@{$order->{'items'}} = grep { ($_->{'line'} || '') ne ($line_id || '') } @{$order->{'items'}};
	return $order;
}

# Giving up an order records nothing: no appointment, no stock movement. This
# is the customer who walked out.
sub store_register_order_cancel {
	my ($id) = @_;
	return 0 unless defined $id && length $id && exists $REGISTER_ORDERS{$id};
	delete $REGISTER_ORDERS{$id};
	return 1;
}

sub store_register_order_reset {
	%REGISTER_ORDERS = ();
	$REGISTER_ORDER_SEQ = 0;
	return 1;
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

1;
