package subs;

# Tax: the house's tax catalog and the arithmetic every tax surface shares.
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
#
# A rate is stored as a percent: 13 is 13%, 5 is 5%. The catalog is one house
# list (`me`/`taxes`, device 'all'), because a tax registration belongs to the
# business, not to a handset. The old single multiplier (`sales_tax`) is read as
# a one-entry catalog when no list exists, so an install that has 1.13 keeps
# charging 13% until its owner edits the list.
#
# The transaction line keeps the old `tax` amount for every existing reader; the
# selected taxes ride beside it as a snapshot of { code, name, rate, amount }.
# A catalogue change therefore never rewrites what an old bill charged.
use strict;
use warnings;
use utf8;

use Mojo::JSON qw(decode_json encode_json);

sub tax_number {
	my ($value) = @_;
	return 0 unless defined $value && length $value;
	$value = "$value";
	$value =~ s/[^0-9.\-]//g;
	return 0 unless $value =~ /^-?\d*(?:\.\d*)?$/ && length $value;
	return 0 + sprintf('%.2f', $value);
}

sub tax_code_from_name {
	my ($name) = @_;
	my $code = uc($name // '');
	$code =~ s/[^A-Z0-9]+/_/g;
	$code =~ s/^_+|_+$//g;
	$code = 'TAX' unless length $code;
	return substr($code, 0, 40);
}

# The catalog editor accepts `13` or `13%`; both mean thirteen percent.
sub tax_percent {
	my ($value) = @_;
	return undef unless defined $value;
	$value = "$value";
	$value =~ s/\s+//g;
	$value =~ s/%$//;
	return undef unless $value =~ /^-?\d+(?:\.\d+)?$/;
	my $rate = 0 + $value;
	return undef if $rate < 0 || $rate > 100;
	return 0 + sprintf('%.4f', $rate);
}

sub tax_entry_normalize {
	my ($entry) = @_;
	return undef unless ref $entry eq 'HASH';
	my $name = $entry->{'name'} // $entry->{'label'} // '';
	$name =~ s/^\s+|\s+$//g;
	my $code = $entry->{'code'} // '';
	$code =~ s/^\s+|\s+$//g;
	$code = &tax_code_from_name($name) unless length $code;
	return undef unless length $name && length $code;
	my $rate = &tax_percent($entry->{'rate'});
	return undef unless defined $rate;
	my $country = uc($entry->{'country'} // '');
	$country = '' unless $country =~ /^[A-Z]{2}$/;
	return {
		code => $code,
		name => $name,
		rate => $rate,
		country => $country,
		($entry->{'default'} ? (default => 1) : ()),
	};
}

# One house list. A stored list that has been emptied is still a list: the
# caller asked for no taxes, so no legacy entry is invented over it. A house
# that never wrote a list is offered the suggested taxes of its home currency
# instead of an empty editor; the suggestions follow the currency until the
# list is saved. The legacy multiplier is used when it was written and does not
# match a suggestion; when it matches one (CAD 1.13 is HST 13), that entry is
# the default and keeps charging the same rate under its proper name.
sub tax_catalog {
	my $raw = &setting_grabber({ app => 'me', setting => 'taxes', device => &warranty_device() });
	my $list = eval { return decode_json($raw // '') };
	my $stored = (defined $raw && length $raw && ref $list eq 'ARRAY') ? 1 : 0;
	$list = [] unless ref $list eq 'ARRAY';
	my (@out, %seen);
	foreach my $entry ( @{$list} ) {
		my $e = &tax_entry_normalize($entry) or next;
		my $key = lc $e->{'code'};
		if ($seen{$key}) {
			my $n = 2;
			$n++ while $seen{ lc($e->{'code'} . '_' . $n) };
			$e->{'code'} .= '_' . $n;
			$key = lc $e->{'code'};
		}
		$seen{$key} = 1;
		push @out, $e;
	}
	unless (scalar @out || $stored) {
		my $seed = &tax_suggested_catalog(&cash_rounding_home_currency());
		my $legacy = &setting_grabber({ app => 'me', setting => 'sales_tax' });
		my $rate = (defined $legacy && length $legacy) ? 0 + sprintf('%.2f', (($legacy || 0) - 1) * 100) : 0;
		if ($rate > 0) {
			my ($match) = grep { abs(($_->{'rate'} || 0) - $rate) < 0.0001 } @{$seed};
			if ($match) {
				$_->{'default'} = 0 for @{$seed};
				$match->{'default'} = 1;
				return $seed;
			}
			$_->{'default'} = 0 for @{$seed};
			return [ { code => 'SALES', name => 'Sales tax', rate => $rate, country => '', default => 1 }, @{$seed} ];
		}
		return $seed;
	}
	return \@out;
}

# ---- suggested catalog -----------------------------------------------------
# A house that has never named a tax starts from the standard rates of the
# country its home currency belongs to, so the editor is useful on day one.
# These are standard rates only, current as of 2026-11 (Wikipedia, "Value-added
# tax", standard-rate table); a house edits or removes them in Me - Taxes, and
# nothing is stored until the list is saved. A reduced or zero rate is listed
# only where it is commonly charged on retail goods. Currencies with no
# national consumption tax (HKD) suggest nothing.
#
# Entry: [ code, name, rate, country, default ]
my %TAX_SUGGESTIONS = (
	CAD => [
		[ 'HST_ON',  'HST (ON)',       13,    'CA', 1 ],
		[ 'HST_NS',  'HST (NS)',       14,    'CA',   0 ],
		[ 'HST_ATL', 'HST (NB/NL/PE)', 15,    'CA',   0 ],
		[ 'GST',     'GST',             5,    'CA',   0 ],
		[ 'QST',     'QST (QC)',        9.975, 'CA',  0 ],
		[ 'GST_PST', 'GST+PST (BC)',   12,    'CA',   0 ],
	],
	USD => [
		[ 'US_SALES', 'Sales tax (set your state)', 0, 'US', 1 ],
	],
	GBP => [
		[ 'VAT',     'VAT',         20, 'GB', 1 ],
		[ 'VAT_RED', 'VAT reduced',  5, 'GB', 0 ],
		[ 'VAT_ZERO','VAT zero',     0, 'GB', 0 ],
	],
	EUR => [
		[ 'VAT_DE', 'VAT (DE)', 19,   'DE', 1 ],
		[ 'VAT_FR', 'VAT (FR)', 20,   'FR', 0 ],
		[ 'VAT_IT', 'VAT (IT)', 22,   'IT', 0 ],
		[ 'VAT_ES', 'VAT (ES)', 21,   'ES', 0 ],
		[ 'VAT_NL', 'VAT (NL)', 21,   'NL', 0 ],
		[ 'VAT_BE', 'VAT (BE)', 21,   'BE', 0 ],
		[ 'VAT_AT', 'VAT (AT)', 20,   'AT', 0 ],
		[ 'VAT_IE', 'VAT (IE)', 23,   'IE', 0 ],
		[ 'VAT_PT', 'VAT (PT)', 23,   'PT', 0 ],
		[ 'VAT_FI', 'VAT (FI)', 25.5, 'FI', 0 ],
	],
	AUD => [ [ 'GST', 'GST', 10, 'AU', 1 ] ],
	NZD => [ [ 'GST', 'GST', 15, 'NZ', 1 ] ],
	JPY => [
		[ 'CT',     'Consumption tax',         10, 'JP', 1 ],
		[ 'CT_RED', 'Consumption tax reduced',  8, 'JP', 0 ],
	],
	CHF => [
		[ 'VAT',     'VAT',          8.1, 'CH', 1 ],
		[ 'VAT_RED', 'VAT reduced',  2.6, 'CH', 0 ],
	],
	SEK => [
		[ 'VAT',     'VAT',         25, 'SE', 1 ],
		[ 'VAT_RED', 'VAT reduced', 12, 'SE', 0 ],
		[ 'VAT_RED2','VAT reduced 2', 6, 'SE', 0 ],
	],
	NOK => [ [ 'VAT', 'VAT', 25, 'NO', 1 ] ],
	DKK => [ [ 'VAT', 'VAT', 25, 'DK', 1 ] ],
	INR => [
		[ 'GST',     'GST',          18, 'IN', 1 ],
		[ 'GST_RED', 'GST reduced',   5, 'IN', 0 ],
	],
	MXN => [ [ 'IVA', 'IVA', 16, 'MX', 1 ] ],
	ZAR => [ [ 'VAT', 'VAT', 15, 'ZA', 1 ] ],
	SGD => [ [ 'GST', 'GST', 9, 'SG', 1 ] ],
	CNY => [ [ 'VAT', 'VAT', 13, 'CN', 1 ] ],
	KRW => [ [ 'VAT', 'VAT', 10, 'KR', 1 ] ],
	TWD => [ [ 'VAT', 'VAT', 5, 'TW', 1 ] ],
	PLN => [ [ 'VAT', 'VAT', 23, 'PL', 1 ] ],
	CZK => [ [ 'VAT', 'VAT', 21, 'CZ', 1 ] ],
	HUF => [ [ 'VAT', 'VAT', 27, 'HU', 1 ] ],
	RON => [ [ 'VAT', 'VAT', 21, 'RO', 1 ] ],
	BGN => [ [ 'VAT', 'VAT', 20, 'BG', 1 ] ],
	TRY => [ [ 'VAT', 'VAT', 20, 'TR', 1 ] ],
	ILS => [ [ 'VAT', 'VAT', 18, 'IL', 1 ] ],
	AED => [ [ 'VAT', 'VAT', 5, 'AE', 1 ] ],
	SAR => [ [ 'VAT', 'VAT', 15, 'SA', 1 ] ],
	THB => [ [ 'VAT', 'VAT', 7, 'TH', 1 ] ],
	IDR => [ [ 'VAT', 'VAT', 12, 'ID', 1 ] ],
	PHP => [ [ 'VAT', 'VAT', 12, 'PH', 1 ] ],
	VND => [ [ 'VAT', 'VAT', 10, 'VN', 1 ] ],
	MYR => [ [ 'SST', 'SST', 8, 'MY', 1 ] ],
	EGP => [ [ 'VAT', 'VAT', 14, 'EG', 1 ] ],
	NGN => [ [ 'VAT', 'VAT', 7.5, 'NG', 1 ] ],
	KES => [ [ 'VAT', 'VAT', 16, 'KE', 1 ] ],
	PKR => [ [ 'GST', 'GST', 18, 'PK', 1 ] ],
	BDT => [ [ 'VAT', 'VAT', 15, 'BD', 1 ] ],
	LKR => [ [ 'VAT', 'VAT', 18, 'LK', 1 ] ],
	NPR => [ [ 'VAT', 'VAT', 13, 'NP', 1 ] ],
	ARS => [ [ 'VAT', 'VAT', 21, 'AR', 1 ] ],
	CLP => [ [ 'VAT', 'VAT', 19, 'CL', 1 ] ],
	COP => [ [ 'VAT', 'VAT', 19, 'CO', 1 ] ],
	PEN => [ [ 'VAT', 'VAT', 18, 'PE', 1 ] ],
	CRC => [ [ 'VAT', 'VAT', 13, 'CR', 1 ] ],
	ISK => [ [ 'VAT', 'VAT', 24, 'IS', 1 ] ],
	RSD => [ [ 'VAT', 'VAT', 20, 'RS', 1 ] ],
	GEL => [ [ 'VAT', 'VAT', 18, 'GE', 1 ] ],
	KZT => [ [ 'VAT', 'VAT', 12, 'KZ', 1 ] ],
	UAH => [ [ 'VAT', 'VAT', 20, 'UA', 1 ] ],
);

sub tax_suggested_catalog {
	my ($currency) = @_;
	my $key = uc($currency // '');
	my $rows = $TAX_SUGGESTIONS{$key} or return [];
	return [ map {
		{
			code => $_->[0],
			name => $_->[1],
			rate => 0 + sprintf('%.4f', $_->[2]),
			country => $_->[3],
			($_->[4] ? ( default => 1 ) : ()),
		}
	} @{$rows} ];
}

sub tax_catalog_write {
	my ($list) = @_;
	$list = eval { return decode_json($list) } if defined $list && !ref $list;
	$list = [] unless ref $list eq 'ARRAY';
	my @out;
	foreach my $entry ( @{$list} ) {
		my $e = &tax_entry_normalize($entry) or next;
		push @out, $e;
	}
	&setting_setter({ app => 'me', setting => 'taxes', device => &warranty_device(), value => encode_json(\@out) });
	return \@out;
}

# Codes may arrive from a select (an array), a stored JSON list, or an old
# comma-separated field. A snapshot entry (a hash) is kept as a hash so a caller
# can still read a line saved before the catalog changed.
sub tax_codes_value {
	my ($value) = @_;
	return [] unless defined $value;
	if (ref $value eq 'ARRAY') {
		return [ grep { defined $_ && (ref $_ eq 'HASH' || length $_) } @{$value} ];
	}
	return [] if ref $value;
	my $decoded = eval { return decode_json($value) };
	if (ref $decoded eq 'ARRAY') {
		return [ grep { defined $_ && (ref $_ eq 'HASH' || length $_) } @{$decoded} ];
	}
	return [ grep { length } split /\s*,\s*/, $value ];
}

sub tax_entries_for_codes {
	my ($catalog, $codes) = @_;
	my %by = map { lc($_->{'code'}) => $_ } @{$catalog || []};
	my @out;
	foreach my $c ( @{ &tax_codes_value($codes) } ) {
		if (ref $c eq 'HASH') {
			my $e = &tax_entry_normalize($c);
			push @out, $e if $e;
			next;
		}
		my $e = $by{ lc $c } or next;
		push @out, $e;
	}
	return \@out;
}

sub tax_rate_multiplier {
	my ($entries) = @_;
	my $percent = 0;
	$percent += ($_->{'rate'} || 0) for @{$entries || []};
	return 1 + ($percent / 100);
}

# The amount is what the line carries: net when the price excludes tax, gross
# when it includes it. Each selected tax gets its share of the tax by its rate,
# and the last share absorbs the rounding so the parts always add to the whole.
sub tax_compute {
	my ($amount, $entries, $inclusive) = @_;
	$amount = 0 unless defined $amount && $amount =~ /^-?\d+(?:\.\d+)?$/;
	$entries = [] unless ref $entries eq 'ARRAY' && scalar @{$entries};
	my $percent = 0;
	$percent += ($_->{'rate'} || 0) for @{$entries};
	return { net => 0 + sprintf('%.2f', $amount), tax => 0, total => 0 + sprintf('%.2f', $amount), rate => 1, entries => [] }
		unless $percent > 0;
	my $rate = 1 + ($percent / 100);
	my ($net, $tax, $total);
	if ($inclusive) {
		$net = $amount / $rate;
		$tax = $amount - $net;
		$total = $amount;
	}
	else {
		$net = $amount;
		$tax = $amount * ($rate - 1);
		$total = $amount + $tax;
	}
	$net = 0 + sprintf('%.2f', $net);
	$tax = 0 + sprintf('%.2f', $tax);
	$total = 0 + sprintf('%.2f', $total);
	my (@parts, $left);
	$left = $tax;
	my $last = $#{$entries};
	for my $i ( 0 .. $last ) {
		my $part = ($i == $last)
			? $left
			: 0 + sprintf('%.2f', $tax * ($entries->[$i]->{'rate'} || 0) / $percent);
		$left -= $part;
		push @parts, {
			code => $entries->[$i]->{'code'},
			name => $entries->[$i]->{'name'},
			rate => $entries->[$i]->{'rate'},
			amount => 0 + sprintf('%.2f', $part),
		};
	}
	return { net => $net, tax => $tax, total => $total, rate => $rate, entries => \@parts };
}

sub tax_line_snapshot {
	my ($amount, $entries, $inclusive) = @_;
	my $calc = &tax_compute($amount, $entries, $inclusive);
	return $calc->{'entries'};
}

sub tax_snapshot_merge {
	my ($snapshots) = @_;
	my (%by, @order);
	foreach my $list ( @{$snapshots || []} ) {
		foreach my $e ( @{$list || []} ) {
			my $code = lc($e->{'code'} // '');
			next unless length $code;
			unless ($by{$code}) {
				$by{$code} = { code => $e->{'code'}, name => $e->{'name'}, rate => $e->{'rate'}, amount => 0 };
				push @order, $code;
			}
			$by{$code}->{'amount'} += $e->{'amount'} || 0;
		}
	}
	return [ map { my $e = $by{$_}; $e->{'amount'} = 0 + sprintf('%.2f', $e->{'amount'}); $e } @order ];
}

# The tax a merged snapshot accounts for. A receipt's printed tax is compared
# against this, not against the line `tax` fields: a line can carry a tax amount
# with no code selected, and that tax is not attributed to an item yet.
sub tax_snapshot_total {
	my ($snapshot) = @_;
	my $sum = 0;
	$sum += ($_->{'amount'} || 0) for grep { ref $_ eq 'HASH' } @{ ref $snapshot eq 'ARRAY' ? $snapshot : [] };
	return 0 + sprintf('%.2f', $sum);
}

# The printed tax a receipt carries minus what its lines account for. Positive
# means the paper charged tax no line explains; negative means the lines claim
# more tax than the paper shows.
sub tax_receipt_delta {
	my ($receipt_tax, $snapshot) = @_;
	return 0 + sprintf('%.2f', &tax_number($receipt_tax) - &tax_snapshot_total($snapshot));
}

# What the transaction's own `taxes` column should say: the selected taxes for
# every line, merged by code, with the amount each actually charged. The lines
# are the browser's own draft (each one carries the codes it selected); the
# totals fallback covers a form that sent one selection for the whole document.
sub tax_transaction_snapshot {
	my ($movement, $catalog) = @_;
	$catalog ||= &tax_catalog();
	my @snaps;
	foreach my $key ( keys %{$movement || {}} ) {
		next if $key eq 'totals' || $key eq 'crypto';
		my $line = $movement->{$key};
		next unless ref $line eq 'HASH';
		my $codes = &tax_codes_value($line->{'taxes'});
		next unless scalar @{$codes};
		my $entries = &tax_entries_for_codes($catalog, $codes);
		next unless scalar @{$entries};
		my $amount = abs(&tax_number($line->{'amount'}));
		my $inclusive = (($line->{'has_tax'} // '') eq 'on') ? 1 : 0;
		push @snaps, &tax_line_snapshot($amount, $entries, $inclusive);
	}
	unless (scalar @snaps) {
		my $codes = &tax_codes_value($movement->{'totals'}->{'taxes'});
		my $entries = &tax_entries_for_codes($catalog, $codes);
		if (scalar @{$entries}) {
			my $amount = abs(&tax_number($movement->{'totals'}->{'amount'}));
			my $inclusive = (($movement->{'totals'}->{'has_tax'} // '') eq 'on') ? 1 : 0;
			push @snaps, &tax_line_snapshot($amount, $entries, $inclusive);
		}
	}
	return &tax_snapshot_merge(\@snaps);
}

# A customer's exemption and their own default taxes. `tax_codes` is the
# customer's usual selection; a country with no selection picks the catalog's
# entries for that country, which is what makes a foreign buyer's VAT appear
# already chosen.
sub tax_exemption_for {
	my ($app, $catalog) = @_;
	$catalog ||= &tax_catalog();
	return { exempt => 0, id => '', country => '', codes => [] } unless defined $app && length $app;
	my $settings = eval { &settings_grabber({ app => $app, benign => 1 }) } || {};
	my $exempt = (($settings->{'tax_exempt'} // '') eq 'on') ? 1 : 0;
	my $id = $settings->{'tax_exemption_id'} // '';
	my $country = uc($settings->{'tax_country'} // '');
	$country = '' unless $country =~ /^[A-Z]{2}$/;
	my $codes = &tax_codes_value($settings->{'tax_codes'});
	my @codes = grep { !ref && length } @{$codes};
	if (!scalar @codes && length $country) {
		@codes = map { $_->{'code'} } grep { ($_->{'country'} // '') eq $country } @{$catalog};
	}
	return { exempt => $exempt, id => $id, country => $country, codes => \@codes };
}

sub tax_countries {
	my ($catalog) = @_;
	my %seen;
	$seen{$_->{'country'}} = 1 for grep { ($_->{'country'} // '') =~ /^[A-Z]{2}$/ } @{$catalog || []};
	return [ sort keys %seen ];
}

# The Store's own tax switch. The old multiplier is the fallback: a house that
# has 1.13 charges tax, and a house that has 1 or 0 does not. Once the switch is
# explicit, it wins - turning it off is a real zero on every invoice.
sub store_tax_enabled {
	my $raw = &setting_grabber({ app => 'me', setting => 'sales_tax_enabled', device => &warranty_device() });
	if (defined $raw && length $raw) {
		return ($raw eq 'on' || $raw eq '1' || $raw eq 'yes') ? 1 : 0;
	}
	my $legacy = &setting_grabber({ app => 'me', setting => 'sales_tax' }) || 1;
	return ($legacy > 1) ? 1 : 0;
}

sub store_tax_default_codes {
	my ($catalog) = @_;
	$catalog ||= &tax_catalog();
	my %known = map { lc($_->{'code'}) => $_->{'code'} } @{$catalog};
	my $raw = &setting_grabber({ app => 'me', setting => 'sales_tax_codes', device => &warranty_device() });
	my @out = map { $known{ lc $_ } } grep { !ref && length && $known{ lc $_ } } @{ &tax_codes_value($raw) };
	unless (scalar @out) {
		my $single = &setting_grabber({ app => 'me', setting => 'sales_tax_code', device => &warranty_device() });
		push @out, $known{ lc $single } if defined $single && length $single && $known{ lc $single };
	}
	unless (scalar @out) {
		my ($default) = grep { $_->{'default'} } @{$catalog};
		$default ||= $catalog->[0];
		push @out, $default->{'code'} if $default;
	}
	return \@out;
}

sub store_tax_settings {
	my $catalog = &tax_catalog();
	my $enabled = &store_tax_enabled();
	my $codes = $enabled ? &store_tax_default_codes($catalog) : [];
	return {
		enabled => $enabled ? 1 : 0,
		default_codes => $codes,
		catalog => $catalog,
		countries => &tax_countries($catalog),
	};
}

sub store_tax_line_snapshot {
	my ($amount, $codes, $settings) = @_;
	$settings ||= &store_tax_settings();
	return [] unless $settings->{'enabled'};
	my $use = &tax_codes_value($codes);
	$use = $settings->{'default_codes'} unless scalar @{$use};
	my $entries = &tax_entries_for_codes($settings->{'catalog'}, $use);
	return &tax_line_snapshot($amount, $entries, 0);
}

# Totals for the register and every other Store sale: each line's own tax codes,
# or the Store default when the item has none. A disabled Store or an exempt
# customer has no tax at all.
sub store_tax_totals {
	my ($items, $settings) = @_;
	$settings ||= &store_tax_settings();
	my ($subtotal, $quantity, $count, $tax) = (0, 0, 0, 0);
	my @snaps;
	foreach my $item ( @{$items || []} ) {
		next unless ref $item eq 'HASH';
		my $price = &tax_number($item->{'price'});
		my $qty = &tax_number($item->{'quantity'});
		$qty = 1 if $qty <= 0;
		my $line_total = $price * $qty;
		$subtotal += $line_total;
		$quantity += $qty;
		$count++;
		next unless $settings->{'enabled'};
		my $codes = &tax_codes_value($item->{'tax_codes'});
		my $snap = &store_tax_line_snapshot($line_total, $codes, $settings);
		next unless scalar @{$snap};
		push @snaps, $snap;
		$tax += ($_->{'amount'} || 0) for @{$snap};
	}
	my $merged = &tax_snapshot_merge(\@snaps);
	my $rate = 1;
	$rate = 1 + ($tax / $subtotal) if $settings->{'enabled'} && $subtotal > 0 && $tax;
	return {
		subtotal => 0 + sprintf('%.2f', $subtotal),
		tax => 0 + sprintf('%.2f', $tax),
		total => 0 + sprintf('%.2f', $subtotal + $tax),
		quantity => $quantity,
		count => $count,
		tax_rate => 0 + sprintf('%.6f', $rate),
		taxes => $merged,
	};
}

# ---- cash rounding ---------------------------------------------------------
# Canada has no penny, so a cash total is rounded to the nearest five cents.
# The rule is a house setting (`cash_rounding`, device 'all') and applies only
# when the payment's currency is the house's home currency: a transaction in
# USD or EUR is never rounded, so a trip does not inherit the Canadian rule.
# Auto means five cents when the home currency is CAD and the cent elsewhere.

sub cash_rounding_home_currency {
	my @candidates = (
		&setting_grabber({ app => 'me', setting => 'currency' }),
		&setting_grabber({ app => 'misc', setting => 'currency' }),
	);
	foreach my $raw ( @candidates ) {
		next unless defined $raw && length $raw;
		my $value = $raw;
		my $list = eval { decode_json($raw) };
		$value = $list->[0] if ref $list eq 'ARRAY' && scalar @{$list};
		next if ref $value || !defined $value || !length $value;
		$value = uc($value);
		return $value if $value =~ /^[A-Z]{3}$/;
	}
	return 'CAD';
}

sub cash_rounding_setting {
	my $raw = &setting_grabber({ app => 'me', setting => 'cash_rounding', device => &warranty_device() });
	$raw = 'auto' unless defined $raw && length $raw;
	$raw = lc $raw;
	$raw = 'auto' unless grep { $_ eq $raw } qw(auto off 0.05 0.10);
	my $home = &cash_rounding_home_currency();
	my $step = 0;
	if ($raw eq '0.05') { $step = 0.05; }
	elsif ($raw eq '0.10') { $step = 0.10; }
	elsif ($raw eq 'auto') { $step = ($home eq 'CAD') ? 0.05 : 0; }
	return { setting => $raw, home_currency => $home, step => $step };
}

sub cash_rounding_step {
	my ($currency) = @_;
	my $s = &cash_rounding_setting();
	return 0 unless $s->{'step'} > 0;
	return 0 unless defined $currency && length $currency;
	return 0 unless uc($currency) eq $s->{'home_currency'};
	return $s->{'step'};
}

# A negative amount (a refund) rounds away from zero symmetrically, so a
# -10.02 refund becomes -10.00 rather than -9.95.
sub cash_rounding_apply {
	my ($amount, $currency) = @_;
	my $exact = &tax_number($amount);
	my $step = &cash_rounding_step($currency);
	return { exact => $exact, step => 0, rounded => $exact, rounding => 0 } unless $step > 0;
	my $sign = $exact < 0 ? -1 : 1;
	my $abs = abs($exact);
	my $rounded = $sign * int(($abs / $step) + 0.5) * $step;
	$rounded = 0 + sprintf('%.2f', $rounded);
	return {
		exact => $exact,
		step => $step,
		rounded => $rounded,
		rounding => 0 + sprintf('%.2f', $rounded - $exact),
	};
}

1;
