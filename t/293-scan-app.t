# tests-for: lib/JawnOS/Domain/Scan.pm lib/JawnOS/Domain/Printer2.pm lib/JawnOS/Controller/manager_scan.pm lib/JawnOS/Routes/manager_scan.pm lib/JawnOS/Manager/Part06.pm lib/JawnOS/Manager/Part02.pm lib/JawnOS/Controller/manager_misc.pm templates/apps/scan.html.ep public/js/manager/scan.js public/js/manager/websocket/00_console_router.js templates/start_menu/start_menu.html.ep lib/JawnOS/Manager/Core1_tables_hooks.pm perl/help/topics_web.pl perl/help/topics_functions.pl
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
require "$root/lib/JawnOS/Domain/Printer2.pm";
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
	local *Manager::scan_feeds = sub { return [ 'adf', 'flatbed' ] };
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
	my $escl = eval { Manager::scanner_escl_pages('adf', $dir . '/receipt_test') };
	ok(!$@, 'the eSCL receipt path does not die on a bare scanner entry');
	is(ref $escl, 'HASH', 'it still answers a hash');
	is($escl->{'error'}, 'the scanner did not answer', 'with the printer\'s own error');
}
{
	# A machine that left the printer's network keeps a stale address in its
	# config. The readiness and scan paths must find the printer answering eSCL
	# on the network the machine is on now, instead of trusting that address.
	no warnings 'redefine';
	local *subs::printer_live_ip = sub { return '192.168.0.74' };
	local *JawnOS::Platform::Print::scan_capabilities = sub {
		my ($ip) = @_;
		return $ip eq '192.168.1.109' ? { adf => { width => 2550, height => 4200 } } : {};
	};
	local *subs::adf_scanner = sub { return { name => 'Officejet LivingRoom' } };
	local *subs::cache_get = sub { return 0 };
	local *subs::cache_set = sub { return 1 };
	local *subs::rightNow = sub { return 1_800_000_000_000 };
	local *subs::printer_discover_escl = sub { return '192.168.1.109' };
	my ($ip, $caps) = subs::scanner_live_capabilities();
	is($ip, '192.168.1.109', 'a stale saved address is replaced by the live printer');
	ok($caps->{'adf'}, 'and the live capabilities come with it');
}
{
	# A phone cannot read the ARP table, so it borrows the address a computer
	# already found and published in the house's readiness ledger.
	no warnings 'redefine';
	local *subs::printer_live_ip = sub { return '192.168.0.74' };
	local *JawnOS::Platform::Print::scan_capabilities = sub {
		my ($ip) = @_;
		return $ip eq '192.168.1.109' ? { adf => { width => 2550, height => 4200 } } : {};
	};
	local *subs::adf_scanner = sub { return { name => 'Officejet LivingRoom' } };
	local *subs::scan_house_printer_ip = sub { return '192.168.1.109' };
	local *subs::network_interface_reporter = sub {
		return { tun1 => { ip => '100.64.0.9' }, wlan0 => { ip => '192.168.1.106' } };
	};
	local *subs::ip_is_private = sub { return 1 };
	local *subs::same_net_test = sub {
		my ($mine, $peer) = @_;
		return $mine =~ /^192\.168\./ ? 'yes' : 'no';
	};
	local *subs::cache_set = sub { return 1 };
	local *subs::rightNow = sub { return 1_800_000_000_000 };
	my ($ip, $caps) = subs::scanner_live_capabilities();
	is($ip, '192.168.1.109', 'the house ledger lends the phone the printer address');
	ok($caps->{'adf'}, 'with the capabilities that answered');
}
{
	# The feed list follows the live printer, so a phone beside it is a scanner
	# even though the static capability table has no scan entry for a phone.
	no warnings 'redefine';
	local $gb::capabilities = { mobile => { camera => [ 0 ], printer => [ 'house' ] } };
	local *subs::device_setter = sub { return 'mobile' };
	local *subs::scanner_live_capabilities = sub {
		return ( '192.168.1.109', { adf => { width => 2550, height => 4200 }, platen => { width => 2550, height => 3508 } } );
	};
	is_deeply(Manager::scan_feeds(), [ 'adf', 'flatbed' ], 'a phone gets the printer\'s own feeds');
	local *subs::scanner_live_capabilities = sub { return ( '', {} ) };
	is_deeply(Manager::scan_feeds(), [], 'and no feeds when no printer answers');
}

# --- the automatic service's per-scanner rule -----------------------------
# The ADF watcher and the app read the same house-wide rule; on and Market are
# the defaults, and a saved choice is visible from another machine.
{
	no warnings 'redefine';
	local *subs::path_name = sub { my $n = shift; $n =~ s/\s+/_/g; return $n; };
	local *subs::warranty_device = sub { return 'all'; };
	my $stored;
	local *subs::setting_grabber = sub { return $stored };
	local *subs::setting_setter = sub { my ($s) = @_; $stored = $s->{'value'}; return 1 };

	is(subs::scan_scanner_key({ name => 'Officejet LivingRoom' }), 'Officejet_LivingRoom',
		'a scanner is keyed by its name');
	is(subs::scan_scanner_key({}), 'scanner', 'and an unnamed one by a stable default');
	is(subs::scan_auto_enabled('Officejet_LivingRoom'), 1, 'the service watches a scanner by default');
	is(subs::scan_auto_target('Officejet_LivingRoom'), 'market', 'and sends paper to Market by default');
	ok(subs::scan_scanner_rule_save('Officejet_LivingRoom', 'Officejet LivingRoom', 0, 'scan'),
		'a rule is saved');
	is(subs::scan_auto_enabled('Officejet_LivingRoom'), 0, 'Auto-scan can be turned off');
	is(subs::scan_auto_target('Officejet_LivingRoom'), 'scan', 'and the paper sent to Scan');
	is(subs::scan_scanner_rule('Officejet_LivingRoom')->{'name'}, 'Officejet LivingRoom',
		'the display name travels with the rule');
	is(subs::scan_auto_enabled('another'), 1, 'a scanner with no rule keeps the default');
}
{
	# The readiness ledger is the phone's fallback; a peer's row may be a little
	# old in its copy, and one that is not ready is never borrowed from.
	no warnings 'redefine';
	local *subs::rightNow = sub { return 1_800_000_000_000 };
	local *subs::db_select = sub {
		return FakeRows->new([
			{ hostname => 'table', printer => '192.168.1.109', scan_ready => 1, seen => 1_800_000_000_000 - 20 * 60 * 1000 },
		]);
	};
	is(subs::scan_house_printer_ip(), '192.168.1.109', 'a peer sighting half an hour old still names the printer');
	local *subs::db_select = sub {
		return FakeRows->new([
			{ hostname => 'phone', printer => '192.168.1.109', scan_ready => 0, seen => 1_800_000_000_000 },
		]);
	};
	is(subs::scan_house_printer_ip(), '', 'a machine that is not ready is not borrowed from');
}

# --- an automatic edge is taken once ---------------------------------------
# The watcher's job carries a scan id; the window that claims it first writes
# the holding row under that id, and a second window is told to stand down.
{
	no warnings 'redefine';
	my (@scanned, $claimed);
	local *Manager::appointment_writer = sub { return 1 };
	local *Manager::scan_feeds = sub { return [ 'adf' ] };
	local *Manager::scan = sub { my ($c, $data) = @_; push @scanned, { %{$data} }; return 'ok' };
	local *Manager::scan_claim_once = sub { return $claimed };
	local *subs::scan_house_me = sub { return 'this-machine' };
	local *subs::scan_dispatcher = sub { return 'this-machine' };
	local *subs::scan_job_state = sub { return 1 };
	local *subs::random_string_creator = sub { return 'rand' };
	local *subs::rightNow = sub { return 1_800_000_000_000 };

	$claimed = 1;
	my $c = FakeController->new(feed => 'adf', scan_id => 'scan123');
	Manager::action_52328($c);
	is(scalar @scanned, 1, 'the claiming window runs the scan');
	is($scanned[0]{'scan_id'}, 'scan123', 'under the job id');
	is($scanned[0]{'uuid'}, 'scan123', 'and the holding row carries it too');
	is($c->{'rendered'}{'json'}{'ok'}, 1, 'and answers ok');

	$claimed = 0;
	my $second = FakeController->new(feed => 'adf', scan_id => 'scan123');
	Manager::action_52328($second);
	is(scalar @scanned, 1, 'a second window does not pull the paper again');
	is($second->{'rendered'}{'json'}{'claimed'}, 0, 'it is told the edge is already taken');
}

# --- the app's wiring -------------------------------------------------------
my $scan_routes = read_file("$root/lib/JawnOS/Routes/manager_scan.pm");
like($scan_routes, qr{'/manager/scan'}, 'the page has a route');
like($scan_routes, qr{'/manager/scan/pool'}, 'the pool has one');
like($scan_routes, qr{'/manager/scan/capture'}, 'and taking a page has one');
like($scan_routes, qr{'/manager/scan/discard'}, 'and throwing one away has one');
like($scan_routes, qr{'/manager/scan/scanner'}, 'and a scanner rule has one');
like(read_file("$root/lib/JawnOS/Routes.pm"), qr/\bmanager_scan\b/, 'the route group is registered');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_scan.pm");
like($controller, qr/source => 'unclaimed'/, 'a scan is held as unclaimed');
like($controller, qr/7 \* 24 \* 60 \* 60 \* 1000/, 'for a week');
like($controller, qr/type => 'scan'/, 'as a scan appointment');
like($controller, qr/&delete_file\b/, 'discarding one page unlinks it');
like($controller, qr/&delete_app\b/, 'discarding the last page removes the holder');
like($controller, qr/sub action_52330\b/, 'the scanner rule has its action');
like($controller, qr/scan_claim_once/, 'an automatic edge is claimed once');
like($controller, qr/scan_scanner_rule_save/, 'and the choice is saved house-wide');
like($controller, qr/scanners => &scan_scanner_rows/, 'the pool lists the scanners');
like($controller, qr/pending => &scan_pending_job/, 'with the edge waiting to be taken');
like($controller, qr/&scan_feeds\(\)/, 'and follows the live printer\'s feeds');

my $template = read_file("$root/templates/apps/scan.html.ep");
like($template, qr/id="scan_app"/, 'the page has its own panel');
like($template, qr/class="scan_feed" feed="adf"/, 'the feeder is a press');
like($template, qr/class="scan_feed" feed="flatbed"/, 'so is the flatbed');
like($template, qr/class="scan_pool"/, 'and the pool is drawn');
like($template, qr/class="scan_scanner_list"/, 'the scanners have their own list');

my $js = read_file("$root/public/js/manager/scan.js");
like($js, qr/url: '\/manager\/scan\/capture'/, 'the buttons take a page');
like($js, qr/holder: 'scan'/, 'filing names the Scan holder');
like($js, qr/\.notification\[app="scan"\]/, 'the notice opens the app');
like($js, qr/url: '\/manager\/scan\/discard'/, 'a card can be thrown away');
like($js, qr/url: '\/manager\/scan\/scanner'/, 'a scanner rule can be saved');
like($js, qr/scan_scanner_auto/, 'Auto-scan is a switch');
like($js, qr/scan_scanner_target/, 'and Paper goes to is a choice');
like($js, qr/window\.scanAutomatic\s*=/, 'an open window takes the physical edge');
like(read_file("$root/public/js/manager/websocket/00_console_router.js"), qr/scanAutomatic/,
	'and the console router reaches it');

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
like($scan, qr/&scanner_escl_pages\(\$feed/, 'a scan tries the printer\'s eSCL service first');
like($scan, qr/&scan_feeds\(\)/, 'and accepts a feed the live printer offers');
unlike($scan, qr/&log_writer\(/, 'the scan subprocessor logs through the domain helper');
my $printer2 = read_file("$root/lib/JawnOS/Domain/Printer2.pm");
like($printer2, qr/scan_auto_enabled/, 'the ADF watcher obeys the per-scanner switch');
like($printer2, qr/scan_auto_target/, 'and sends the edge where the rule says');
like($printer2, qr/scanAutomatic/, 'the Scan app hears the physical edge');
like($printer2, qr/scan_house_printer_ip/, 'a phone borrows the printer the house found');
like(read_file("$root/lib/JawnOS/Domain/Scan.pm"), qr/sub scan_scanner_rules\b/,
	'the rules live with the scan readiness ledger');

# --- the help topic ---------------------------------------------------------
my $help = read_file("$root/perl/help/topics_web.pl");
like($help, qr/app => 'scan'/, 'the Scan page has its own topic');
like($help, qr/Auto-scan/, 'the topic explains the auto-scan switch');
like($help, qr/Paper goes to/, 'and the destination choice');
like(read_file("$root/perl/help/topics_functions.pl"), qr/'scan',/,
	'and scanning names it');

done_testing();
