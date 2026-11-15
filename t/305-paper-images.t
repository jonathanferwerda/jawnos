# tests-for: lib/JawnOS/Domain/PaperImage.pm lib/JawnOS/PDF/Store.pm lib/JawnOS/PDF.pm lib/JawnOS/Manager/Part08.pm lib/JawnOS/Controller/manager_misc13.pm lib/JawnOS/Manager/Part32.pm templates/configure/store_setting_list.html.ep perl/help/topics_business.pl
# covers:    the paper-picture setting (None, Invoice line, Single Product
#           Picture, Both), the colour/gray JPEG cache and its cleanup, the
#           invoice and receipt layouts, the table's picture column, and the
#           Configure select plus the main_image/file-delete hooks.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use JawnOSTest;
use JawnOS::PDF::Store ();

require './lib/JawnOS/Domain/PaperImage.pm';

sub source { return read_file(root() . '/' . $_[0]) }

# --- the setting: None is the default, three picture modes -------------------
for my $case (
	[ undef,   'none' ],
	[ '',      'none' ],
	[ 'line',  'line' ],
	[ 'single', 'single' ],
	[ 'both',  'both' ],
	[ 'on',    'none' ],
) {
	local *subs::setting_grabber = sub { $case->[0] };
	is(&subs::paper_image_mode(), $case->[1],
		'paper_image_mode reads ' . (defined $case->[0] ? "'$case->[0]'" : 'unset'));
}

# --- cache paths are stable, and forget removes both ------------------------
my $dir = tempdir(CLEANUP => 1);
my $source = "$dir/picture.bin";
write_file($source, "\xFF\xD8\xFF\xD9");
{
	local *subs::setting_grabber = sub { $dir };
	local *subs::home = sub { $_[0] };
	my $paths = &subs::paper_image_paths($source);
	ok(ref $paths eq 'HASH', 'a source has cache paths');
	like($paths->{'colour'}, qr/\.paper-images\/[0-9a-f]+\.jpg$/, 'the colour path is keyed by the source');
	like($paths->{'gray'}, qr/-gray\.jpg$/, 'the grayscale path is beside it');
	is(&subs::paper_image_key($source), &subs::paper_image_key($source), 'the key is stable');
	write_file($paths->{'colour'}, 'colour');
	write_file($paths->{'gray'}, 'gray');
	is(&subs::paper_image_forget($source), 2, 'both renditions are removed');
	ok(!-e $paths->{'colour'} && !-e $paths->{'gray'}, 'and are gone');
}

# --- the real conversion, when this machine has magick ----------------------
SKIP: {
	my $magick = `command -v magick 2>/dev/null`;
	chomp $magick if defined $magick;
	skip 'no magick on this machine', 4 unless defined $magick && length $magick;
	my $photo = "$dir/photo.jpg";
	system($magick, '-size', '20x20', 'xc:red', $photo);
	skip 'could not make a fixture', 4 unless -s $photo;
	local *subs::setting_grabber = sub { $dir };
	local *subs::home = sub { $_[0] };
	my $paths = &subs::paper_image_cache($photo);
	ok(ref $paths eq 'HASH', 'the cache is made on demand');
	ok(-s $paths->{'colour'}, 'a colour JPEG is written');
	ok(-s $paths->{'gray'}, 'a grayscale JPEG is written');
	is(&subs::paper_image_forget($photo), 2, 'and both leave with the source');
}

# --- the paper draws them in every mode -------------------------------------
SKIP: {
	my $magick = `command -v magick 2>/dev/null`;
	chomp $magick if defined $magick;
	skip 'no magick on this machine', 11 unless defined $magick && length $magick;
	my $jpeg = "$dir/paper.jpg";
	system($magick, '-size', '20x20', 'xc:blue', $jpeg);
	skip 'could not make a picture', 11 unless -s $jpeg;
	my $paper = {
		type => 'invoice',
		id => 'A1',
		print_date => 'Nov 15 2026',
		cx => { app => 'Cx', address => '12 Elm St' },
		registers => [ {
			timestamp => 1_763_222_400_000,
			data => {
				id => 'A1',
				numbers => { subtotal => 10, tax => 0, total => 10, balance => 10 },
				model => { uuid => 'model-1', name => 'Blue Widget', quantity => 1, price => 10 },
				options => {},
				payments => [],
			},
		} ],
	};
	local *subs::paper_image_for_model = sub { $jpeg };
	local *subs::paper_image_cache = sub { { colour => $jpeg, gray => $jpeg } };
	for my $mode (qw(single line both)) {
		local *subs::paper_image_mode = sub { $mode };
		my ($bytes, $error) = JawnOS::PDF::Store::paper_bytes($paper, store => { store_name => 'Shop' });
		ok(defined $bytes, "$mode draws the invoice") or diag $error;
		like($bytes, qr{/Subtype /Image}, "$mode embeds the picture");
		like($bytes, qr{/Filter /DCTDecode}, "$mode carries a JPEG");
	}
	{
		local *subs::paper_image_mode = sub { 'none' };
		my ($bytes) = JawnOS::PDF::Store::paper_bytes($paper, store => { store_name => 'Shop' });
		unlike($bytes, qr{/Subtype /Image}, 'None keeps the paper text-only');
	}
	{
		local *subs::paper_image_mode = sub { 'both' };
		my ($receipt) = JawnOS::PDF::Store::paper_bytes({ %$paper, type => 'receipt' },
			store => { store_name => 'Shop' });
		unlike($receipt, qr{/Subtype /Image}, 'the receipt carries no item pictures');
	}
	{
		local *subs::paper_image_mode = sub { 'single' };
		my $paid = {
			%$paper,
			registers => [ {
				timestamp => 1_763_222_400_000,
				data => {
					%{$paper->{'registers'}[0]{'data'}},
					numbers => { subtotal => 10, tax => 0, total => 10, balance => 0 },
				},
			} ],
		};
		my ($bytes) = JawnOS::PDF::Store::paper_bytes($paid, store => { store_name => 'Shop' });
		my $stamp_at = index($bytes, '(PAID) Tj');
		my $image_at = rindex($bytes, ' Do Q');
		cmp_ok($stamp_at, '>=', 0, 'a settled invoice carries the PAID stamp');
		cmp_ok($stamp_at, '>', $image_at, 'the stamp is painted above the picture');
	}
}

# --- the logo reuses the cache: colour invoice, grayscale receipt -----------
SKIP: {
	my $magick = `command -v magick 2>/dev/null`;
	chomp $magick if defined $magick;
	skip 'no magick on this machine', 2 unless defined $magick && length $magick;
	my $jpeg = "$dir/logo.jpg";
	system($magick, '-size', '60x30', 'xc:green', $jpeg);
	skip 'could not make a logo', 2 unless -s $jpeg;
	my $paper = {
		type => 'invoice', id => 'A2', print_date => 'Nov 15 2026',
		cx => { app => 'Cx' },
		registers => [ { timestamp => 1_763_222_400_000, data => {
			id => 'A2', numbers => { total => 1, balance => 1 }, options => {},
		} } ],
	};
	local *subs::paper_image_mode = sub { 'none' };
	local *subs::paper_image_source = sub { $jpeg };
	local *subs::paper_image_cache = sub { { colour => $jpeg, gray => $jpeg } };
	my $store = { store_name => 'Shop', logo => 'data:image/png;base64,AAAA' };
	my ($invoice) = JawnOS::PDF::Store::paper_bytes($paper, store => $store);
	like($invoice, qr{/Subtype /Image}, 'the invoice carries the colour logo');
	my ($receipt) = JawnOS::PDF::Store::paper_bytes({ %$paper, type => 'receipt' }, store => $store);
	like($receipt, qr{/Subtype /Image}, 'the receipt carries the grayscale logo');
}

# --- Configure, the hooks and the help --------------------------------------
like(source('lib/JawnOS/Manager/Part08.pm'), qr/invoice_images/,
	'the Store setting list carries invoice_images');
my $cfg = source('templates/configure/store_setting_list.html.ep');
like($cfg, qr/Include images in Invoice/, 'Configure names the setting');
like($cfg, qr/Invoice line/, 'and offers the invoice-line mode');
like($cfg, qr/Single Product Picture/, 'and the single picture mode');
like($cfg, qr/Both/, 'and both');
my $misc = source('lib/JawnOS/Controller/manager_misc13.pm');
like($misc, qr/paper_image_forget/, 'a main_image change forgets the old renditions');
like($misc, qr/paper_image_cache/, 'and warms the new one when the setting asks');
my $configure = source('lib/JawnOS/Controller/manager_configure.pm');
like($configure, qr/paper_image_forget/, 'uploading a new logo forgets the old renditions');
my $part32 = source('lib/JawnOS/Manager/Part32.pm');
like($part32, qr/paper_image_forget/, 'deleting the file forgets its renditions');
my $help = source('perl/help/topics_business.pl');
like($help, qr/Include images in Invoice/, 'the Store help names the setting');

done_testing();
