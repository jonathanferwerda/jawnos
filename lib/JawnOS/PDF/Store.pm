package JawnOS::PDF::Store;

# The store's paper, drawn with JawnOS::PDF instead of weasyprint. The shop on
# a phone has no weasyprint (and no room for its 69 MiB), but a customer who
# pays is still owed a receipt, so the receipt and the invoice are laid out
# here from the same appointment data the HTML sheet uses. The HTML route is
# untouched: printer_pdf_from_html stays the way an arbitrary HTML sheet is
# rendered.
#
# What it answers is the same contract as the weasyprint path:
#   my ($pdf_path, undef) = paper_pdf($paper);     # a temp PDF to move or unlink
#   my (undef, $error)    = paper_pdf($paper);     # why no paper was made
# `$paper` is the hash store_printer returns (registers, totals, cx, type,
# print_date, due_date, id) with its template key ignored.
#
# The document layer reads one more thing the template reads itself: the house
# settings under app `me` (store name and address, tax number, doc notes, the
# receipt message). A caller that has them can pass `store => {...}` and
# `labels => {...}` and the module touches no database, which is how a test
# exercises it; otherwise it asks subs::setting_grabber and subs::lang/ui when
# those are loaded.
#
# Page: a receipt prints on the 80mm roll; an invoice, sale or quote prints on
# Letter. Pass `page => 'a4'` to choose A4 instead.

use strict;
use warnings;
use utf8;

BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../.." if $dir && -d "$dir/../..";
}

use JawnOS::PDF ();
use File::Temp ();

my @STORE_KEYS = qw(store_name address phone email slogan tax_number doc_notes receipt_message);

my %DEFAULT_LABEL = (
	invoice       => 'Invoice',
	receipt       => 'Receipt',
	sale          => 'Sale',
	quote         => 'Quote',
	order         => 'Order',
	item          => 'Item',
	qty           => 'Qty',
	price         => 'Price',
	discount      => 'Discount',
	subtotal      => 'Subtotal',
	tax           => 'Tax',
	aux           => 'Aux',
	total         => 'Total',
	balance       => 'Balance',
	paid          => 'Paid',
	payments      => 'Payments',
	date          => 'Date',
	due           => 'Due',
	amount        => 'Amount',
	change        => 'Change',
	method        => 'Method',
	customer      => 'Customer',
	this_payment  => 'This payment',
	remaining     => 'Remaining balance',
	for_invoice   => 'For invoice',
);

my %LANG_KEY = (
	invoice  => 'common.invoice',
	receipt  => 'common.receipt',
	sale     => 'common.sale',
	quote    => 'common.quote',
	order    => 'common.order',
	item     => 'common.item',
	qty      => 'common.quantity',
	price    => 'common.price',
	discount => 'store.discount',
	subtotal => 'store.subtotal',
	tax      => 'common.tax',
	aux      => 'store.aux',
	total    => 'common.total',
	balance  => 'store.balance',
	paid     => 'store.paid',
	payments => 'store.payments',
	date     => 'store.date',
	due      => 'store.due',
	amount   => 'store.amount',
	change   => 'store.change',
	method   => 'store.payment_method',
);

# ------------------------------------------------------------------ the call
sub paper_pdf {
	my ($paper, %opt) = @_;
	my ($bytes, $error) = paper_bytes($paper, %opt);
	return (undef, $error) unless defined $bytes && length $bytes;
	my ($fh, $path) = File::Temp::tempfile(
		'jawn_paper_XXXXXX', SUFFIX => '.pdf', TMPDIR => 1, UNLINK => 0
	);
	return (undef, 'could not create a print file') unless $fh && $path;
	binmode $fh;
	print $fh $bytes;
	close $fh;
	return (-s $path) ? ($path, undef) : (undef, 'nothing was written to the print file');
}

sub paper_bytes {
	my ($paper, %opt) = @_;
	my $doc = model($paper, %opt);
	my $pdf = JawnOS::PDF->new(
		size   => $opt{'page'} || ($doc->{'type'} eq 'receipt' ? '80mm' : 'letter'),
		logger => $opt{'logger'},
	);
	if ($doc->{'type'} eq 'receipt') {
		_receipt($pdf, $doc);
	}
	else {
		_invoice($pdf, $doc);
	}
	return ($pdf->bytes, undef);
}

# ------------------------------------------------------------------- the model
sub _plain {
	my ($html) = @_;
	return '' unless defined $html && length $html;
	my $text = $html;
	$text =~ s/<br\s*\/?>/ /gi;
	$text =~ s/<[^>]*>/ /g;
	$text =~ s/&nbsp;/ /g;
	$text =~ s/&amp;/&/g;
	$text =~ s/&lt;/</g;
	$text =~ s/&gt;/>/g;
	$text =~ s/&quot;/"/g;
	$text =~ s/&#39;/'/g;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+//;
	$text =~ s/\s+$//;
	return $text;
}

sub _call_sub {
	my ($name, @args) = @_;
	no strict 'refs';
	my $out = eval { &{$name}(@args) };
	return (defined $out && !ref $out && length "$out") ? "$out" : undef;
}

sub _store_settings {
	my (%opt) = @_;
	my $given = ref $opt{'store'} eq 'HASH' ? $opt{'store'} : {};
	my %out;
	for my $key (@STORE_KEYS) {
		if (exists $given->{$key}) {
			$out{$key} = $given->{$key};
		}
		else {
			$out{$key} = _call_sub('subs::setting_grabber', { app => 'me', setting => $key });
		}
	}
	return \%out;
}

sub _labels {
	my (%opt) = @_;
	my $given = ref $opt{'labels'} eq 'HASH' ? $opt{'labels'} : {};
	my %out = %DEFAULT_LABEL;
	for my $key (keys %LANG_KEY) {
		my $text = _call_sub('subs::lang', $LANG_KEY{$key});
		$out{$key} = $text if defined $text;
	}
	for my $key (qw(this_payment remaining for_invoice customer)) {
		my $text = _call_sub('subs::ui', $DEFAULT_LABEL{$key});
		$out{$key} = $text if defined $text;
	}
	$out{$_} = $given->{$_} for grep { defined $given->{$_} && length $given->{$_} } keys %{$given};
	return \%out;
}

sub _display_name {
	my ($raw) = @_;
	return '' unless defined $raw && length $raw;
	my $name = _call_sub('subs::format_name', $raw);
	return $name if defined $name;
	my $fallback = $raw;
	$fallback =~ s/_/ /g;
	return $fallback;
}

sub _money {
	my ($value) = @_;
	$value = 0 unless defined $value && $value =~ /^-?[0-9.]+$/;
	my $formatted = eval { &subs::price_formatter($value) };
	return $formatted if defined $formatted && length $formatted;
	return sprintf('$%.2f', $value);
}

my @MONTH = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

sub _date_time {
	my ($ms) = @_;
	return '' unless defined $ms && $ms;
	my @t = localtime($ms / 1000);
	my $hour = $t[2] % 12;
	$hour = 12 if $hour == 0;
	return sprintf('%s %02d %d %d:%02d %s', $MONTH[$t[4]], $t[3], $t[5] + 1900,
		$hour, $t[1], $t[2] < 12 ? 'AM' : 'PM');
}

sub _date_only {
	my ($ms) = @_;
	return '' unless defined $ms && $ms;
	my @t = localtime($ms / 1000);
	return sprintf('%s %02d %d', $MONTH[$t[4]], $t[3], $t[5] + 1900);
}

sub _num {
	my ($value, $default) = @_;
	return $default unless defined $value && $value =~ /^-?[0-9.]+$/;
	return $value;
}

sub _register_lines {
	my ($data) = @_;
	my @lines;
	my $register = ref $data->{'register'} eq 'HASH' ? $data->{'register'} : undef;
	if ($register && ref $register->{'items'} eq 'ARRAY' && scalar @{$register->{'items'}}) {
		for my $item (@{$register->{'items'}}) {
			my $qty = _num($item->{'quantity'}, 1);
			push @lines, {
				name  => _display_name($item->{'name'}),
				qty   => $qty,
				price => _num($item->{'price'}, 0),
				total => _num($item->{'total'}, _num($item->{'price'}, 0) * $qty),
			};
		}
		return @lines;
	}
	my $model = ref $data->{'model'} eq 'HASH' ? $data->{'model'} : {};
	my $qty = _num($model->{'quantity'}, 1);
	push @lines, {
		name        => _display_name($model->{'name'}),
		description => _plain($model->{'description'}),
		qty         => $qty,
		price       => _num($model->{'price'}, 0),
		discount    => _num($model->{'discount'}, 0) * $qty,
		total       => _num($model->{'price'}, 0) * $qty,
	};
	my $options = ref $data->{'options'} eq 'HASH' ? $data->{'options'} : {};
	for my $category (sort keys %{$options}) {
		next unless ref $options->{$category} eq 'ARRAY';
		for my $option (@{$options->{$category}}) {
			my $oqty = _num($option->{'quantity'}, 1);
			push @lines, {
				name        => _display_name($option->{'name'}),
				description => _plain($option->{'description'}),
				qty         => $oqty,
				price       => _num($option->{'price'}, 0),
				discount    => _num($option->{'discount'}, 0) * $oqty,
				total       => _num($option->{'price'}, 0) * $oqty,
			};
		}
	}
	return @lines;
}

sub model {
	my ($paper, %opt) = @_;
	$paper = {} unless ref $paper eq 'HASH';
	my $type = lc($paper->{'type'} || 'invoice');
	my $registers = ref $paper->{'registers'} eq 'ARRAY' ? $paper->{'registers'} : [];
	my @lines;
	my @payments;
	my %sum = (subtotal => 0, discount => 0, tax => 0, aux => 0, total => 0, balance => 0);
	my $stamp = 0;
	my $receipt;
	my $till = 0;
	for my $register (@{$registers}) {
		my $data = ref $register->{'data'} eq 'HASH' ? $register->{'data'} : {};
		$stamp = $register->{'timestamp'} if ($register->{'timestamp'} || 0) > $stamp;
		if (ref $data->{'numbers'} eq 'HASH') {
			$sum{$_} += _num($data->{'numbers'}{$_}, 0) for keys %sum;
		}
		$till = 1 if ref $data->{'register'} eq 'HASH';
		push @lines, _register_lines($data);
		push @payments, @{$data->{'payments'}} if ref $data->{'payments'} eq 'ARRAY';
		$receipt = $data if ref $data->{'payment'} eq 'HASH';
	}
	my $given = ref $paper->{'totals'} eq 'HASH' ? $paper->{'totals'} : {};
	my %totals;
	for my $key (keys %sum) {
		$totals{$key} = exists $given->{$key} && defined $given->{$key}
			? $given->{$key}
			: $sum{$key};
	}
	my $cx = ref $paper->{'cx'} eq 'HASH' ? $paper->{'cx'} : {};
	my $id = defined $paper->{'id'} ? $paper->{'id'} : '';
	$id = _plain($id);
	my $date = $stamp ? _date_time($stamp) : ($paper->{'print_date'} || '');
	my $page_type = $till && $type ne 'receipt' ? 'receipt' : $type;
	my $balance = $receipt && ref $receipt->{'numbers'} eq 'HASH'
		? _num($receipt->{'numbers'}{'balance'}, 0)
		: _num($totals{'balance'}, 0);
	my $this_payment = $receipt && ref $receipt->{'payment'} eq 'HASH'
		? $receipt->{'payment'}{'amount'}
		: undef;
	my $invoice_id = $receipt && ref $receipt->{'invoice'} eq 'HASH'
		? ($receipt->{'invoice'}{'id'} || '')
		: '';
	my $store = _store_settings(%opt);
	my $labels = _labels(%opt);
	my @payment_rows;
	for my $payment (@payments) {
		next unless ref $payment eq 'HASH';
		push @payment_rows, {
			date   => $payment->{'timestamp'} ? _date_only($payment->{'timestamp'}) : '',
			method => $payment->{'label'} || ($payment->{'method'} ? _display_name($payment->{'method'}) : ''),
			amount => _num($payment->{'amount'}, 0),
			change => _num($payment->{'change'}, 0),
		};
	}
	return {
		type         => $page_type,
		source_type  => $type,
		id           => $id,
		date         => $date,
		due          => $paper->{'due_date'} || '',
		customer     => {
			name    => _display_name($cx->{'app'}),
			address => $cx->{'address'} || '',
			phone   => $cx->{'phone'} || '',
			email   => $cx->{'email'} || '',
		},
		store        => $store,
		labels       => $labels,
		totals       => \%totals,
		lines        => \@lines,
		payments     => \@payment_rows,
		paid         => $balance <= 0.005,
		balance      => $balance,
		this_payment => $this_payment,
		invoice_id   => $invoice_id,
	};
}

# --------------------------------------------------------------- the receipt
sub _header {
	my ($pdf, $doc) = @_;
	my $store = $doc->{'store'};
	my $left = $pdf->margin;
	my $cw = $pdf->content_width;
	my $y = $pdf->margin;
	$y += 14;
	$pdf->text($store->{'store_name'} || 'JawnOS', $left, $y,
		font => 'Helvetica-Bold', size => 12, align => 'center', width => $cw);
	$y += 12;
	for my $key (qw(address phone email slogan)) {
		next unless defined $store->{$key} && length $store->{$key};
		$pdf->text($store->{$key}, $left, $y, size => 7.5, align => 'center',
			width => $cw, color => '#444444');
		$y += 9;
	}
	$y += 3;
	$pdf->rule($left, $y, $left + $cw, $y, width => 1, color => '#000000');
	$y += 12;
	my $right = $left + $cw;
	if (length $doc->{'id'}) {
		$pdf->text('#' . $doc->{'id'}, $left, $y, font => 'Helvetica-Bold', size => 8);
	}
	if (length $doc->{'date'}) {
		$pdf->text($doc->{'date'}, $right - 130, $y, size => 7.5, align => 'right', width => 130);
	}
	$y += 12;
	if (length $doc->{'customer'}{'name'}) {
		$pdf->text($doc->{'customer'}{'name'}, $left, $y, size => 8);
		$y += 10;
	}
	return $y;
}

sub _totals_block {
	my ($pdf, $doc, $x, $y, $width) = @_;
	my $labels = $doc->{'labels'};
	my $totals = $doc->{'totals'};
	my $tag = $doc->{'type'};
	my @rows;
	push @rows, [$labels->{'discount'}, $totals->{'discount'}, 0] if $totals->{'discount'};
	push @rows, [$labels->{'subtotal'}, $totals->{'subtotal'}, 0];
	push @rows, [$labels->{'tax'}, $totals->{'tax'}, 0] if $totals->{'tax'};
	push @rows, [$labels->{'aux'}, $totals->{'aux'}, 0] if $totals->{'aux'};
	push @rows, [$labels->{'total'}, $totals->{'total'}, 1];
	push @rows, [$labels->{'balance'}, $totals->{'balance'}, 0]
		unless $tag eq 'quote' || $tag eq 'order';
	my $label_width = $width * 0.6;
	my $value_width = $width - $label_width;
	for my $row (@rows) {
		my $font = $row->[2] ? 'Helvetica-Bold' : 'Helvetica';
		my $size = $row->[2] ? 10 : 8.5;
		$pdf->rule($x, $y - 11, $x + $width, $y - 11, width => 1, color => '#000000')
			if $row->[2];
		$pdf->text($row->[0], $x, $y, size => $size, font => $font,
			align => 'right', width => $label_width, color => $row->[2] ? '#000000' : '#444444');
		$pdf->text(_money($row->[1]), $x + $label_width, $y, size => $size, font => $font,
			align => 'right', width => $value_width);
		$y += $row->[2] ? 15 : 12;
	}
	return $y;
}

sub _receipt {
	my ($pdf, $doc) = @_;
	my $labels = $doc->{'labels'};
	my $left = $pdf->margin;
	my $cw = $pdf->content_width;
	my $right = $left + $cw;
	$pdf->stamp(uc($labels->{'paid'}), x => $pdf->width / 2, y => $pdf->height * 0.3,
		size => 54, color => '#e06666') if $doc->{'paid'};
	my $y = _header($pdf, $doc);
	$pdf->text(uc($labels->{$doc->{'type'}}), $left, $y, font => 'Helvetica-Bold',
		size => 10, align => 'center', width => $cw);
	$y += 14;
	my $items = $doc->{'lines'};
	if (@{$items}) {
		my @rows;
		for my $line (@{$items}) {
			my $name = $line->{'name'} || '';
			$name .= "\n" . $line->{'description'} if length($line->{'description'} || '');
			push @rows, [
				$name,
				$line->{'qty'},
				_money($line->{'total'}),
			];
		}
		$y = $pdf->table(
			x       => $left,
			y       => $y,
			widths  => [0.56, 0.12, 0.32],
			align   => ['left', 'right', 'right'],
			size    => 7.5,
			padding => 2.5,
			header  => [uc($labels->{'item'}), uc($labels->{'qty'}), uc($labels->{'amount'})],
			rows    => \@rows,
		);
	}
	$y += 10;
	$y = _totals_block($pdf, $doc, $left + $cw * 0.28, $y, $cw * 0.72);
	$y += 8;
	$pdf->rule($left, $y, $right, $y, width => 1, color => '#000000');
	$y += 14;
	if (defined $doc->{'this_payment'}) {
		$pdf->text(uc($labels->{'this_payment'}), $left, $y, font => 'Helvetica-Bold', size => 9);
		$pdf->text(_money($doc->{'this_payment'}), $right - 100, $y,
			font => 'Helvetica-Bold', size => 9, align => 'right', width => 100);
		$y += 15;
	}
	$pdf->text(uc($labels->{'remaining'}), $left, $y, font => 'Helvetica-Bold', size => 10);
	$pdf->text(_money($doc->{'balance'}), $right - 110, $y,
		font => 'Helvetica-Bold', size => 10, align => 'right', width => 110);
	$y += 18;
	if (length $doc->{'invoice_id'}) {
		$pdf->text($labels->{'for_invoice'} . ' ' . $doc->{'invoice_id'}, $right - 150, $y,
			size => 7.5, align => 'right', width => 150, color => '#444444');
		$y += 12;
	}
	my $payments = $doc->{'payments'};
	if (@{$payments}) {
		$y += 4;
		$pdf->text(uc($labels->{'payments'}), $left, $y, font => 'Helvetica-Bold', size => 8);
		$y += 10;
		my $with_method = grep { length($_->{'method'}) } @{$payments};
		my @rows = map {
			$with_method
				? [$_->{'date'}, $_->{'method'}, _money($_->{'amount'})]
				: [$_->{'date'}, _money($_->{'amount'})]
		} @{$payments};
		my $header = $with_method
			? [uc($labels->{'date'}), uc($labels->{'method'}), uc($labels->{'amount'})]
			: [uc($labels->{'date'}), uc($labels->{'amount'})];
		my $widths = $with_method ? [0.42, 0.33, 0.25] : [0.6, 0.4];
		my $align = $with_method ? ['left', 'left', 'right'] : ['left', 'right'];
		$y = $pdf->table(
			x       => $left,
			y       => $y,
			widths  => $widths,
			align   => $align,
			size    => 7,
			padding => 2,
			header  => $header,
			rows    => \@rows,
			rules   => 0,
		);
	}
	my $message = $doc->{'store'}{'receipt_message'};
	if (defined $message && length $message) {
		$y += 10;
		$pdf->rule($left, $y, $right, $y, width => 0.5, color => '#cccccc');
		$y += 14;
		$pdf->paragraph($message, $left, $y, $cw, size => 8.5, align => 'center', color => '#222222');
	}
	return;
}

# --------------------------------------------------------------- the invoice
sub _invoice {
	my ($pdf, $doc) = @_;
	my $labels = $doc->{'labels'};
	my $store = $doc->{'store'};
	my $left = $pdf->margin;
	my $cw = $pdf->content_width;
	my $right = $left + $cw;
	$pdf->stamp(uc($labels->{'paid'}), x => $pdf->width / 2, y => $pdf->height * 0.4,
		size => 96, color => '#e06666') if $doc->{'paid'};
	my $y = $pdf->margin;
	my $name_size = 20;
	$pdf->text($store->{'store_name'} || 'JawnOS', $left, $y + $name_size,
		font => 'Helvetica-Bold', size => $name_size);
	my $store_y = $y + $name_size + 12;
	for my $key (qw(address phone email slogan)) {
		next unless defined $store->{$key} && length $store->{$key};
		$pdf->text($store->{$key}, $left, $store_y, size => 8.5, color => '#444444');
		$store_y += 11;
	}
	my $right_y = $y + 12;
	if (length $doc->{'id'}) {
		$pdf->text('#' . $doc->{'id'}, $right - 180, $right_y, font => 'Helvetica-Bold',
			size => 11, align => 'right', width => 180);
		$right_y += 14;
	}
	for my $pair ([$labels->{'date'}, $doc->{'date'}], [$labels->{'due'}, $doc->{'due'}]) {
		next unless length $pair->[1];
		$pdf->text($pair->[0], $right - 240, $right_y, size => 8.5, align => 'right',
			width => 80, color => '#444444');
		$pdf->text($pair->[1], $right - 150, $right_y, size => 8.5, align => 'right', width => 150);
		$right_y += 11;
	}
	$y = ($store_y > $right_y ? $store_y : $right_y) + 8;
	$pdf->rule($left, $y, $right, $y, width => 1.5, color => '#000000');
	$y += 20;
	my $customer = $doc->{'customer'};
	if (length $customer->{'name'}) {
		$pdf->text($customer->{'name'}, $left, $y, font => 'Helvetica-Bold', size => 13);
		$y += 15;
		for my $key (qw(address phone email)) {
			next unless length $customer->{$key};
			$pdf->text($customer->{$key}, $left, $y, size => 8.5, color => '#444444');
			$y += 10;
		}
	}
	$y += 14;
	$pdf->text(uc($labels->{$doc->{'type'}}), $left, $y, font => 'Helvetica-Bold',
		size => 22, align => 'center', width => $cw);
	$y += 26;
	my $items = $doc->{'lines'};
	if (@{$items}) {
		my @rows;
		for my $line (@{$items}) {
			my $name = $line->{'name'} || '';
			$name .= "\n" . $line->{'description'} if length($line->{'description'} || '');
			push @rows, [
				$name,
				$line->{'qty'},
				_money($line->{'price'}),
				$line->{'discount'} ? _money($line->{'discount'}) : '',
				_money($line->{'total'}),
			];
		}
		$y = $pdf->table(
			x       => $left,
			y       => $y,
			widths  => [0.44, 0.10, 0.14, 0.14, 0.18],
			align   => ['left', 'right', 'right', 'right', 'right'],
			size    => 9,
			padding => 4,
			header  => [uc($labels->{'item'}), uc($labels->{'qty'}), uc($labels->{'price'}),
				uc($labels->{'discount'}), uc($labels->{'subtotal'})],
			rows    => \@rows,
		);
	}
	$y += 16;
	my $payments = $doc->{'payments'};
	if (@{$payments}) {
		$pdf->text(uc($labels->{'payments'}), $left, $y, font => 'Helvetica-Bold', size => 11);
		$y += 14;
		my $with_method = grep { length($_->{'method'}) } @{$payments};
		my $with_change = grep { $_->{'change'} } @{$payments};
		my @rows = map {
			my @row = ($_->{'date'});
			push @row, $_->{'method'} if $with_method;
			push @row, _money($_->{'amount'});
			push @row, _money($_->{'change'}) if $with_change;
			\@row;
		} @{$payments};
		my @header = ($labels->{'date'});
		push @header, $labels->{'method'} if $with_method;
		push @header, $labels->{'amount'};
		push @header, $labels->{'change'} if $with_change;
		my @widths = $with_method
			? ($with_change ? (0.30, 0.35, 0.20, 0.15) : (0.35, 0.40, 0.25))
			: ($with_change ? (0.50, 0.30, 0.20) : (0.65, 0.35));
		my @align = map { $_ eq $labels->{'amount'} || $_ eq $labels->{'change'} ? 'right' : 'left' } @header;
		$y = $pdf->table(
			x       => $left,
			y       => $y,
			widths  => \@widths,
			align   => \@align,
			size    => 9,
			padding => 4,
			header  => [map { uc($_) } @header],
			rows    => \@rows,
		);
		$y += 14;
	}
	$y += 4;
	my $totals_width = $cw * 0.42;
	$y = _totals_block($pdf, $doc, $right - $totals_width, $y, $totals_width);
	my @notes;
	push @notes, [$labels->{'tax'}, $store->{'tax_number'}]
		if defined $store->{'tax_number'} && length $store->{'tax_number'};
	push @notes, ['Note', $store->{'doc_notes'}]
		if defined $store->{'doc_notes'} && length $store->{'doc_notes'};
	my $note_y = $pdf->bottom - 12 * scalar(@notes);
	for my $note (@notes) {
		$pdf->text($note->[0] . ': ' . $note->[1], $left, $note_y, size => 8, color => '#444444');
		$note_y += 12;
	}
	return;
}

1;
