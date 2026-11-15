# tests-for: lib/JawnOS/PDF.pm lib/JawnOS/PDF/Store.pm lib/JawnOS/Manager/Part08.pm
# covers:    the dependency-free PDF writer (xref/trailer, page count, stream
#           /Length, wrapping, table column x, stamp, repeating header, JPEG
#           passthrough), the store receipt/invoice layout drawn from the same
#           appointment data as the HTML sheet, the WinAnsi fallback warning,
#           and the wiring that gives both store documents to the engine.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use Test::More;

use JawnOS::PDF ();
use JawnOS::PDF::Store ();

# The store's paper is drawn here on every machine, the phone included. These
# are the facts that make the output a PDF a viewer accepts and the receipt the
# paper the template prints: structure, page count, a known word in a stream
# whose /Length is true, wrapping, a column's x, the PAID stamp, the receipt's
# balance/message, and the Part08 wiring that gives it both store documents.

sub bytes_of {
	my (@pages) = @_;
	my $pdf = JawnOS::PDF->new(size => 'letter');
	$pdf->text($_, 72, 100 + $_ * 14, size => 10) for @pages;
	return ($pdf, $pdf->bytes);
}

# --- the file is a PDF a viewer can open -------------------------------------
{
	my ($pdf, $bytes) = bytes_of('HELLO RECEIPT');
	like($bytes, qr/^%PDF-1\.4\n/, 'starts with the PDF header');
	like($bytes, qr/%%EOF\n\z/, 'ends with EOF');
	like($bytes, qr/\nxref\n0 \d+\n/, 'has an xref table');
	like($bytes, qr/\nstartxref\n\d+\n%%EOF/, 'has startxref');
	like($bytes, qr{/Type /Catalog}, 'has a catalog');
	like($bytes, qr{\(HELLO RECEIPT\) Tj}, 'the text is in the content stream');

	# /Length is the stream's byte count, not an estimate.
	my ($declared, $stream) = $bytes =~ m{/Length (\d+) >>\nstream\n(.*?)\nendstream}s;
	ok(defined $declared, 'a content stream carries /Length');
	is($declared, length($stream), 'and it is the stream length');

	my $box = JawnOS::PDF->new(size => 'letter');
	$box->rect(72, 100, 100, 20, fill => '#eeeeee');
	like($box->bytes, qr/0\.93 0\.93 0\.93 rg 72\.00 [0-9.]+ 100\.00 20\.00 re f/,
		'a filled rectangle is drawn where it was asked for');
}

# --- page count --------------------------------------------------------------
{
	my $pdf = JawnOS::PDF->new(size => 'a4');
	$pdf->text('page one', 72, 100);
	$pdf->new_page;
	$pdf->text('page two', 72, 100);
	is($pdf->page_count, 2, 'two pages were asked for');
	my $bytes = $pdf->bytes;
	my @pages = $bytes =~ /\/Type \/Page\b/g;
	is(scalar @pages, 2, 'and two page objects were written');
	like($bytes, qr{/Count 2}, 'the page tree counts them');
	is($pdf->width, 595.28, 'A4 is A4');
	is(JawnOS::PDF->new(size => '80mm')->width, 226.77, 'the receipt roll is 80mm');
	is(JawnOS::PDF->new(size => 'letter')->height, 792, 'Letter is Letter');
}

# --- wrapping ----------------------------------------------------------------
{
	my $pdf = JawnOS::PDF->new(size => 'letter');
	my $long = $pdf->wrap(
		'The quick brown fox jumps over the lazy dog and keeps going until this sentence must occupy more than one line.',
		'Helvetica', 10, 150,
	);
	cmp_ok(scalar @{$long}, '>=', 2, 'a narrow column breaks the paragraph into lines');
	my $short = $pdf->wrap('Short.', 'Helvetica', 10, 150);
	is(scalar @{$short}, 1, 'a short line stays one line');
	my $forced = $pdf->wrap("one\ntwo", 'Helvetica', 10, 500);
	is(scalar @{$forced}, 2, 'an explicit newline is a line break even when it fits');
}

# --- a table column lands where its width says -------------------------------
{
	my $pdf = JawnOS::PDF->new(size => 'letter', margin => 72);
	$pdf->table(
		x => 72, y => 120,
		widths => [200, 200],
		padding => 4,
		size => 9,
		header => ['A', 'B'],
		rows => [['left cell', 'right cell']],
	);
	my $bytes = $pdf->bytes;
	# second column x = 72 + 200 + padding (4)
	like($bytes, qr/1 0 0 1 276\.00 [0-9.]+ Tm \/F\d+ [0-9.]+ Tf \(B\) Tj/,
		'the second header cell is drawn at x = 72 + 200 + 4');
	like($bytes, qr/1 0 0 1 76\.00 [0-9.]+ Tm \/F\d+ [0-9.]+ Tf \(left cell\) Tj/,
		'the first cell is drawn at its own column x');
}

# --- stamp, page break and repeated header -----------------------------------
{
	my $pdf = JawnOS::PDF->new(size => '80mm');
	$pdf->stamp('PAID', x => 100, y => 200, size => 40);
	$pdf->table(
		widths => [0.6, 0.4],
		size => 8,
		header => ['ITEM', 'AMOUNT'],
		rows => [ map { [ "line $_", '$1.00' ] } 1 .. 60 ],
	);
	my $bytes = $pdf->bytes;
	like($bytes, qr{\(PAID\) Tj}, 'the stamp word is drawn');
	cmp_ok($pdf->page_count, '>', 1, 'sixty rows break the roll into pages');
	my @headers = $bytes =~ /\(ITEM\) Tj/g;
	cmp_ok(scalar @headers, '>=', 2, 'the table header repeats after the break');
}

# --- a JPEG is passed through, not decoded -----------------------------------
{
	my $jpeg = "\xFF\xD8"
		. "\xFF\xC0" . pack('n', 11) . "\x08" . pack('n', 10) . pack('n', 20) . "\x03"
		. "\x01\x11\x00\x02\x11\x01\x03\x11\x01"
		. "\xFF\xD9";
	my $pdf = JawnOS::PDF->new(size => 'letter');
	my ($w, $h) = $pdf->image_jpeg($jpeg, 72, 100, 100, 50);
	is($w, 100, 'the image is placed at the requested width');
	my $bytes = $pdf->bytes;
	like($bytes, qr{/Filter /DCTDecode}, 'DCTDecode is the only image filter');
	like($bytes, qr{/Width 20 /Height 10}, 'the JPEG dimensions are read from SOF');
}

# --- the store's paper -------------------------------------------------------
my $store = {
	store_name => 'Corner Shop',
	address => '1 Main Street',
	phone => '555-0100',
	tax_number => 'TAX-9',
	doc_notes => 'Net 30',
	receipt_message => 'Thanks for shopping with us today!',
};

sub paper {
	my (%opt) = @_;
	my $balance = exists $opt{'balance'} ? $opt{'balance'} : 20;
	my $type = $opt{'type'} || 'invoice';
	my $data = {
		id => 'A1042',
		numbers => {
			subtotal => 40, discount => 0, tax => 3.20, aux => 0,
			total => 43.20, balance => $balance,
		},
		model => { name => 'blue_widget', quantity => 2, price => 20,
			description => '<b>A widget</b> that is blue' },
		options => {},
		payments => [
			{ timestamp => 1763222400000, amount => 23.20, method => 'cash',
				label => 'Cash' },
		],
	};
	if ($opt{'payment'}) {
		$data->{'payment'} = { amount => $opt{'payment'}, timestamp => 1763222400000 };
		$data->{'invoice'} = { id => 'A1042' };
	}
	$data->{'customer_app'} = $opt{'customer_app'} if $opt{'customer_app'};
	return {
		type => $type,
		id => 'A1042',
		print_date => 'Nov 15 2026',
		due_date => 'Nov 30 2026',
		cx => { app => $opt{'customer_app'} || 'Jane_Doe', address => '12 Elm St' },
		registers => [ { timestamp => 1763222400000, data => $data } ],
	};
}

{
	my ($bytes, $error) = JawnOS::PDF::Store::paper_bytes(
		paper(type => 'receipt', payment => 23.20, balance => 20), store => $store
	);
	ok(defined $bytes, 'the receipt is drawn by the engine') or diag $error;
	like($bytes, qr/\(REMAINING BALANCE\) Tj/, 'the receipt names the remaining balance');
	like($bytes, qr/\(THIS PAYMENT\) Tj/, 'and the payment it receipts');
	like($bytes, qr/Thanks for shopping with us today!/, 'the house receipt message is the footer');
	unlike($bytes, qr/\(PAID\) Tj/, 'an open balance is not stamped PAID');
	is(JawnOS::PDF::Store::model(paper(type => 'receipt', payment => 23.2, balance => 20),
		store => $store)->{'balance'}, 20, 'the model keeps the post-payment balance');
}

{
	my ($bytes, $error) = JawnOS::PDF::Store::paper_bytes(
		paper(type => 'invoice', balance => 0), store => $store
	);
	ok(defined $bytes, 'the invoice is drawn') or diag $error;
	like($bytes, qr/\(PAID\) Tj/, 'a settled invoice is stamped PAID');
	like($bytes, qr/\(INVOICE\) Tj/, 'and says INVOICE');
	is(JawnOS::PDF::Store::model(paper(type => 'invoice', balance => 0),
		store => $store)->{'paid'}, 1, 'the model agrees the balance is settled');

	my ($open) = JawnOS::PDF::Store::paper_bytes(paper(type => 'invoice', balance => 5), store => $store);
	unlike($open, qr/\(PAID\) Tj/, 'an invoice still owed is not stamped');
}

{
	my $path_dir = tempdir(CLEANUP => 1);
	my $paper = paper(type => 'invoice', balance => 3);
	my ($path, $error) = JawnOS::PDF::Store::paper_pdf($paper, store => $store);
	ok(defined $path && -s $path, 'paper_pdf answers a PDF path') or diag $error;
	like(read_file($path, binmode => ':raw'), qr/^%PDF-/, 'and the path holds a PDF');
	unlink $path if defined $path;
}

# --- a name in another script: TTF embed, or a logged WinAnsi substitution ---
{
	my @warnings;
	my $paper = paper(type => 'invoice', balance => 0, customer_app => "\x{0418}\x{0432}\x{0430}\x{043D}");
	my ($bytes, $error) = JawnOS::PDF::Store::paper_bytes($paper,
		store => $store, logger => sub { push @warnings, $_[0] });
	ok(defined $bytes, 'a Cyrillic name makes a paper') or diag $error;
	if ($bytes =~ m{/Subtype /Type0} && $bytes =~ m{/Identity-H}) {
		pass('the name is drawn through an embedded TrueType CID font');
	}
	else {
		like(join(' ', @warnings), qr/became "\?"/, 'without a font the name is sanitised and logged');
	}
}

# --- Part08 draws both store documents with the engine only ------------------
{
	my $source = read_file("$FindBin::Bin/../lib/JawnOS/Manager/Part08.pm");
	like($source, qr/use JawnOS::PDF::Store \(\);/, 'Part08 loads the document layer');
	unlike($source, qr/printer_pdf_from_html/, 'and never falls back to an HTML renderer');
	unlike($source, qr/weasyprint/, 'and names no HTML tool');
	my @calls = $source =~ /JawnOS::PDF::Store::paper_pdf/g;
	is(scalar @calls, 2, 'both the invoice paper and the receipt call it');
}

done_testing();
