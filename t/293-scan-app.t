# tests-for: lib/JawnOS/Domain/Scan.pm lib/JawnOS/Controller/manager_scan.pm lib/JawnOS/Routes/manager_scan.pm lib/JawnOS/Manager/Part06.pm lib/JawnOS/Manager/Part02.pm lib/JawnOS/Controller/manager_misc.pm templates/apps/scan.html.ep public/js/manager/scan.js templates/start_menu/start_menu.html.ep lib/JawnOS/Manager/Core1_tables_hooks.pm perl/help/topics_web.pl perl/help/topics_functions.pl
# covers:    the Scan app's pool (unclaimed scans held for a week), the kind read
#            off a page's text, and the wiring that puts the app on the start
#            menu, in the rotation and in the claim route's holder list.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json);

my $root = "$FindBin::Bin/..";

require "$root/lib/JawnOS/Domain/Scan.pm";
require "$root/lib/JawnOS/Manager/Part06.pm";
# Part06's BEGIN puts lib/ on @INC, so Part02 and the controller load here too.
require "$root/lib/JawnOS/Manager/Part02.pm";
require "$root/lib/JawnOS/Controller/manager_scan.pm";

# --- what a page is, read from its own text --------------------------------
is(subs::scan_doc_kind(''), 'blank', 'no text at all is blank');
is(subs::scan_doc_kind("   \n\t "), 'blank', 'whitespace is not text');
is(subs::scan_doc_kind("ACME HARDWARE\nSubtotal 4.10\nTax 0.33\nTOTAL \$4.43\nCARD 4.43"),
	'receipt', 'a till slip with a total and a payment is a receipt');
is(subs::scan_doc_kind("INVOICE 2231\nBill to: Jane Doe\nDue date 2026-12-01\nTotal 120.00"),
	'invoice', 'an invoice wins over a receipt');
is(subs::scan_doc_kind("Dear Neighbour,\nSincerely,\nThe Smiths"), 'letter', 'a letter names its reader and its signer');
is(subs::scan_doc_kind("Please print your name\nSignature: ______\nDate of birth: __"), 'form', 'a form asks to be filled in');
is(subs::scan_doc_kind("Water lilies at dusk. 1920."), 'document', 'anything else is a document');
is(subs::scan_doc_kind("Total 4.43"), 'document', 'one money word alone is not enough to call it a receipt');

# --- the pool ---------------------------------------------------------------
{
	package FakeRows;
	sub new    { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
}

{
	no warnings 'redefine';
	my $rows = [
		{
			uuid => 'scan-old', server_time => 2000, warranty => 5000,
			file => '[]',
		},
		{
			uuid => 'scan-new', server_time => 3000, warranty => 9000,
			file => '[{"uuid":"f1","f":"/tmp/one.jpg","type":"document","ocr":"SEALED1","server_time":3000},'
				. '{"uuid":"f2","f":"/tmp/two.pdf","type":"document","ocr":"","server_time":2500}]',
		},
	];
	$rows->[0]{'file'} = '[{"uuid":"f0","f":"/tmp/old.jpg","type":"document","ocr":"SEALED0","server_time":2000}]';
	my $now = 1_800_000_000_000;
	local *subs::rightNow = sub { return $now };
	$rows->[1]{'warranty'} = $now + 86400_000;
	$rows->[0]{'warranty'} = $now + 2 * 86400_000;
	local *subs::db_select = sub { return FakeRows->new($rows) };
	local *subs::session_suds = sub { return 'suds' };
	local *subs::note_decrypter = sub {
		my ($secret, $sealed) = @_;
		return "ACME HARDWARE\nSubtotal 4.10\nTOTAL 4.43\nCARD 4.43" if $sealed eq 'SEALED1';
		return "Dear Neighbour,\nSincerely" if $sealed eq 'SEALED0';
		return '';
	};
	local *subs::media_file_type = sub {
		my ($f) = @_;
		return 'img' if $f =~ /\.jpg$/;
		return 'pdf' if $f =~ /\.pdf$/;
		return undef;
	};

	my $items = Manager::scan_pool_items({});
	is(scalar @{$items}, 3, 'every page of every held scan is listed');
	is($items->[0]{'file_uuid'}, 'f1', 'newest page first');
	is($items->[0]{'appt_uuid'}, 'scan-new', 'and it names its holder');
	is($items->[0]{'kind'}, 'receipt', 'the kind is read off the sealed OCR');
	is($items->[0]{'file_type'}, 'img', 'a JPEG page is an image');
	is($items->[0]{'warranty'}, $now + 86400_000, 'the holder\'s warranty travels with the page');
	is($items->[1]{'file_uuid'}, 'f2', 'the second page follows');
	is($items->[1]{'kind'}, 'blank', 'a page with no text stays unlabelled');
	is($items->[1]{'file_type'}, 'pdf', 'a PDF page is a pdf');
	is($items->[2]{'kind'}, 'letter', 'the older holder is read too');
	like($items->[0]{'text'}, qr/TOTAL 4\.43/, 'the text travels for the card\'s tooltip');
}

# --- the press runs the scanner --------------------------------------------
# The route writes the holding row and must then run the scan into it, the same
# press the appointment windows send; otherwise the row stays empty forever.
{
	package FakeController;
	sub new { my ($class, %p) = @_; return bless { params => \%p, rendered => undef }, $class }
	sub param { my ($s, $k, $v) = @_; $s->{'params'}{$k} = $v if @_ > 2; return $s->{'params'}{$k}; }
	sub render { my ($s, %a) = @_; $s->{'rendered'} = \%a; return 1; }
}

{
	no warnings 'redefine';
	my (%seen, $wrote);
	local *Manager::appointment_writer = sub { $wrote = 1; return 1; };
	local *Manager::market_scan_feeds = sub { return [ 'adf', 'flatbed' ] };
	local *Manager::scan = sub { my ($c, $data) = @_; $seen{'scan'} = { %{$data} }; return 'ok'; };
	local *subs::scan_house_me = sub { return 'this-machine'; };
	local *subs::scan_dispatcher = sub { return 'this-machine'; };
	local *subs::random_string_creator = sub { return 'held-uuid'; };
	local *subs::rightNow = sub { return 1_800_000_000_000; };

	my $c = FakeController->new(feed => 'adf');
	Manager::action_52328($c);
	ok($wrote, 'the press writes the holding row');
	is($seen{'scan'}{'feed'}, 'adf', 'and runs the scanner for that feeder');
	is($seen{'scan'}{'uuid'}, 'held-uuid', 'into the row it just wrote');
	is($seen{'scan'}{'app'}, 'scan', 'as a Scan-app scan');
	is($seen{'scan'}{'source'}, 'unclaimed', 'which the pool can hold');
	is($c->{'rendered'}{'json'}{'ok'}, 1, 'and the press still answers at once');
}

# --- a scanner entry the old way does not break the routes ------------------
# The scanner config is hand-edited; an older house keeps a bare address where
# the list of scanner hashes belongs. Reading it must answer "cannot scan", not
# die a 500 on the Market's Scan (ADF) or the appointment scan buttons.
{
	no warnings 'redefine';
	local *subs::rightNow = sub { return 1_800_000_000_000; };
	local *subs::device_lister = sub { return undef; };
	my @shapes = (
		[ 'a bare address string', { scanners => [ 'hpaio:/net/officejet_3830_series?ip=192.168.2.6' ] } ],
		[ 'a hash of scanners',    { scanners => { officejet => { address => 'x', feeds => [ 'ADF' ] } } } ],
		[ 'a bare feeds value',    { scanners => [ { address => 'x', feeds => 'ADF', resolution => '300' } ] } ],
		[ 'no scanners key',       {} ],
	);
	foreach my $shape (@shapes) {
		local $Manager::config = $shape->[1];
		my $command = eval { Manager::scanner_scan_command('adf', '/tmp/page') };
		ok(!$@, 'scanning does not die on ' . $shape->[0]);
		is($command, undef, 'and says that scanner cannot do that (' . $shape->[0] . ')');
	}
	local $Manager::config = { scanners => [ {
		address => 'hpaio:/net/officejet_3830_series?ip=192.168.2.6',
		resolution => '300',
		feeds => [ 'ADF', 'Flatbed' ],
	} ] };
	my $command = Manager::scanner_scan_command('adf', '/tmp/page');
	like($command, qr/^scanimage .*--source ADF/, 'the real scanner shape still builds the ADF command');
}
{
	require File::Temp;
	my $dir = File::Temp::tempdir(CLEANUP => 1);
	no warnings 'redefine';
	local *subs::printer_live_ip = sub { return '192.168.2.6'; };
	local *subs::config_reader = sub { return { scanners => [ 'hpaio:/net/officejet_3830_series?ip=192.168.2.6' ] } };
	local *JawnOS::Platform::Print::scan_capabilities = sub { return { adf => { width => 2550, height => 4200 } } };
	local *JawnOS::Platform::Print::scan_escl = sub { return ( 'the scanner did not answer', [] ); };
	my $escl = eval { Manager::market_receipt_scan_escl('adf', $dir . '/receipt_test') };
	ok(!$@, 'the eSCL receipt path does not die on a bare scanner entry');
	is(ref $escl, 'HASH', 'it still answers a hash');
	is($escl->{'error'}, 'the scanner did not answer', 'with the printer\'s own error');
}

# --- the app's wiring -------------------------------------------------------
my $scan_routes = read_file("$root/lib/JawnOS/Routes/manager_scan.pm");
like($scan_routes, qr{'/manager/scan'}, 'the page has a route');
like($scan_routes, qr{'/manager/scan/pool'}, 'the pool has one');
like($scan_routes, qr{'/manager/scan/capture'}, 'and taking a page has one');
like($scan_routes, qr{'/manager/scan/discard'}, 'and throwing one away has one');
like(read_file("$root/lib/JawnOS/Routes.pm"), qr/\bmanager_scan\b/, 'the route group is registered');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_scan.pm");
like($controller, qr/source => 'unclaimed'/, 'a scan is held as unclaimed');
like($controller, qr/7 \* 24 \* 60 \* 60 \* 1000/, 'for a week');
like($controller, qr/type => 'scan'/, 'as a scan appointment');
like($controller, qr/&delete_file\b/, 'discarding one page unlinks it');
like($controller, qr/&delete_app\b/, 'discarding the last page removes the holder');

my $template = read_file("$root/templates/apps/scan.html.ep");
like($template, qr/id="scan_app"/, 'the page has its own panel');
like($template, qr/class="scan_feed" feed="adf"/, 'the feeder is a press');
like($template, qr/class="scan_feed" feed="flatbed"/, 'so is the flatbed');
like($template, qr/class="scan_pool"/, 'and the pool is drawn');

my $js = read_file("$root/public/js/manager/scan.js");
like($js, qr/url: '\/manager\/scan\/capture'/, 'the buttons take a page');
like($js, qr/holder: 'scan'/, 'filing names the Scan holder');
like($js, qr/\.notification\[app="scan"\]/, 'the notice opens the app');
like($js, qr/url: '\/manager\/scan\/discard'/, 'a card can be thrown away');

my $menu = read_file("$root/templates/start_menu/start_menu.html.ep");
like($menu, qr/id="scan_toggle"/, 'the start menu offers Scan');
my $core = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");
like($core, qr{/js/manager/scan\.js}, 'the script is in the bundle list');
like($core, qr/scan\s*=> \[qw\(scanOpener\)\]/, 'its opener is a lazy entry');
like($core, qr/scan_toggle => 'scan'/, 'and the icon loads the chunk');

# --- the shared claim route learns about the holder ------------------------
my $claim = read_file("$root/lib/JawnOS/Controller/manager_misc.pm");
like($claim, qr/\$c->param\('holder'\)/, 'claim names which pool the rows came from');
like($claim, qr/\(\?:camera\|scan\)/, 'only a known pool is accepted');
like($claim, qr/delete_app\(\$holder_app,/, 'an emptied holder is the one deleted');
like($claim, qr{encode_json\(\\\@left\).*?\$holder_app}s, 'and it stops listing the moved pages first');

# --- the notice on a landed scan -------------------------------------------
my $scan = read_file("$root/lib/JawnOS/Manager/Part02.pm");
like($scan, qr/\$app eq 'scan' && \$source eq 'unclaimed'/, 'a landing scan is announced for the house');
like($scan, qr/waiting in Scan/, 'in words that point at the app');

# --- the help topic ---------------------------------------------------------
my $help = read_file("$root/perl/help/topics_web.pl");
like($help, qr/app => 'scan'/, 'the Scan page has its own topic');
like(read_file("$root/perl/help/topics_functions.pl"), qr/'scan',/,
	'and scanning names it');

done_testing();
