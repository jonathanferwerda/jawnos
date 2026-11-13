# tests-for: lib/JawnOS/Platform/Print.pm lib/JawnOS/Platform/Mdns.pm lib/JawnOS/Domain/Edt.pm lib/JawnOS/Domain/Printer2.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_configure.pm lib/JawnOS/Controller/store_misc.pm lib/JawnOS/Controller/manager_market2.pm lib/JawnOS/Routes/manager_configure.pm lib/JawnOS/Routes/store_misc.pm lib/JawnOS/Routes/manager_market2.pm templates/configure/device_lister/body.html.ep public/js/manager/configure/01_update_controls.js public/js/manager/configure/02_remote_devices.js public/js/manager/market/01_tabs_and_receipts.js public/js/manager/websocket/00_console_router.js public/js/store.js public/js/store/register.js public/css/store.css perl/jobs.pl perl/President.pl
# covers:    CUPS queue discovery (lpstat), network printer discovery (ippfind),
#            the ADF status read, adding a queue (lpadmin), the print/PDF path,
#            the Default printer's network choices, and the Dev/Market wiring.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use RepoSource;
use Mojo::JSON qw(encode_json);

# db_select returns a Mojo::Collection in the app, and the printer listing only
# asks it for ->hashes.
{
	package FakeRows;
	sub new    { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
}

my $root = repo_root();
require "$root/lib/JawnOS/Domain/Printer2.pm";
require JawnOS::Platform::Net;

# --- names and URIs ---------------------------------------------------------
is(subs::printer_queue_clean('HP OfficeJet 3830!'), 'hp-officejet-3830', 'a queue name is made safe');
is(subs::printer_queue_clean('---'), 'printer', 'an empty queue name has a fallback');
ok(subs::printer_uri_ok('ipp://192.168.1.50:631/ipp/print'), 'an IPP URI is accepted');
ok(subs::printer_uri_ok('ipps://printer.local/ipp/print'), 'an IPPS URI is accepted');
ok(!subs::printer_uri_ok('file:///etc/passwd'), 'a file URI is refused');
ok(!subs::printer_uri_ok('ipp://host/print;rm -rf /'), 'shell text in a path is refused');

# --- fake CUPS commands -----------------------------------------------------
my $dir = tempdir(CLEANUP => 1);
sub fake_script {
	my ($name, $body) = @_;
	my $path = "$dir/$name";
	open my $fh, '>', $path or die "$path: $!";
	print $fh "#!/bin/sh\n$body\n";
	close $fh;
	chmod 0755, $path;
	return $path;
}
my $lpstat = fake_script('lpstat', <<'OUT');
cat <<'LPS'
printer Officejet disabled since Thu 06 Nov 2026 10:00:00 AM EST -
	reason unknown
device for Officejet: ipp://192.168.1.50:631/ipp/print
Officejet accepting requests since Thu 06 Nov 2026 09:00:00 AM EST
printer PDF is idle. enabled since Thu 06 Nov 2026 09:00:00 AM EST
system default destination: PDF
LPS
OUT
my $ippfind = fake_script('ippfind', "echo ipp://192.168.1.60:631/ipp/print");
my $lpadmin = fake_script('lpadmin', 'exit 0');

{
	no warnings 'redefine';
	local $subs::cups_printers_memo = undef;
	local *JawnOS::Platform::Print::tool = sub {
		my ($name) = @_;
		return $lpstat if $name eq 'lpstat';
		return $ippfind if $name eq 'ippfind';
		return $lpadmin if $name eq 'lpadmin';
		return '';
	};
	# The explicit Find printers press always asks mDNS; this network has no
	# avahi fixture, so answer empty rather than run a real browse.
	local *subs::mdns_printers = sub { return { by_ip => {}, by_mac => {} } };
	my $queues = subs::cups_printers();
	is(scalar @{$queues}, 2, 'lpstat gives two queues');
	my ($office) = grep { $_->{'name'} eq 'Officejet' } @{$queues};
	ok($office, 'the disabled queue is read');
	is($office->{'enabled'}, 0, 'and marked disabled');
	is($office->{'uri'}, 'ipp://192.168.1.50:631/ipp/print', 'its device URI is read');
	is($office->{'accepting'}, 1, 'its accepting state is read');
	my ($pdf) = grep { $_->{'name'} eq 'PDF' } @{$queues};
	is($pdf->{'default'}, 1, 'the system default is marked');

	my $found = subs::cups_discovered_printers();
	is(scalar @{$found}, 1, 'ippfind finds a printer not in CUPS');
	is($found->[0]{'uri'}, 'ipp://192.168.1.60:631/ipp/print', 'the discovered URI is kept');

	my $sync = subs::cups_sync_printers();
	ok($sync->{'ok'}, 'the sync reports ok');
	is(scalar @{$sync->{'added'}}, 1, 'and adds the discovered printer');
	is($sync->{'added'}[0]{'uri'}, 'ipp://192.168.1.60:631/ipp/print', 'for the right URI');
}

# --- mDNS services ----------------------------------------------------------
# A printer advertises IPP, IPP over TLS, and often only a raw service. The two
# IPP services are what a queue can be built from; the URI carries the scheme,
# the advertised port and the rp path. The raw services stay out of the queue
# list but still label the device in the Devices list (mdns_merge_address).
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::discover = sub { return [] };
	local *subs::cups_printers = sub { return [] };
	local *subs::printer_subnet_candidates = sub { die 'no sweep when mDNS answered' };
	local *subs::mdns_printers = sub {
		return { by_ip => {
			'192.168.1.70' => { ip => '192.168.1.70', port => '631', service => '_ipp._tcp',
				name => 'Officejet', fields => { rp => 'ipp/print' } },
			'192.168.1.71' => { ip => '192.168.1.71', port => '631', service => '_ipps._tcp',
				name => 'Laser', fields => {} },
			'192.168.1.72' => { ip => '192.168.1.72', port => '9100', service => '_pdl-datastream._tcp',
				name => 'Raw', fields => {} },
		} };
	};
	my $found = subs::cups_discovered_printers(1);
	is_deeply([ map { $_->{'uri'} } @{$found} ],
		[ 'ipp://192.168.1.70:631/ipp/print', 'ipps://192.168.1.71:631/ipp/print' ],
		'the IPP and IPPS records become queues, the raw service does not');
}

# One printer, one queue: the same host advertised as _ipp and _ipps must not
# become two choices.
{
	no warnings 'redefine';
	local *subs::cups_printers = sub { return [] };
	local *subs::printer_subnet_candidates = sub { return [] };
	local *subs::mdns_printers = sub {
		return { by_ip => {
			'192.168.1.73' => { ip => '192.168.1.73', port => '631', service => '_ipps._tcp',
				name => 'Both', fields => { rp => 'ipp/print' } },
		} };
	};
	local *JawnOS::Platform::Print::discover = sub {
		return [ 'ipp://192.168.1.73:631/ipp/print' ];
	};
	my $found = subs::cups_discovered_printers(1);
	is(scalar @{$found}, 1, 'a host found twice is listed once');
	is($found->[0]{'uri'}, 'ipp://192.168.1.73:631/ipp/print', 'the plain IPP URI wins over IPPS');
}

# --- the deep press ---------------------------------------------------------
# A printer with Bonjour off advertises nothing, so the explicit press falls
# back to a subnet sweep. A plain fill (Store card, Dev fill) never pays for it.
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::discover = sub { return [] };
	local *subs::cups_printers = sub { return [] };
	local *subs::mdns_printers = sub { return { by_ip => {} } };
	local *subs::printer_subnet_candidates = sub {
		return [ 'ipp://192.168.1.80:631/ipp/print' ];
	};
	my $found = subs::cups_discovered_printers(1);
	is_deeply([ map { $_->{'uri'} } @{$found} ],
		[ 'ipp://192.168.1.80:631/ipp/print' ],
		'an explicit Find printers sweeps when nothing advertises');
	local *subs::printer_subnet_candidates = sub { die 'a plain fill must not sweep' };
	is_deeply(subs::cups_discovered_printers(), [], 'a plain fill never sweeps');
}

# --- the subnet candidates --------------------------------------------------
# Only a private NIC with a real LAN mask is swept; the tailnet /32 is not. A
# live row that answers IPP becomes the ipp:// URI the queue add needs, and a
# row that is incomplete, this machine itself, or silent on 631 is dropped.
{
	no warnings 'redefine';
	my @swept;
	local *subs::network_interface_reporter = sub {
		return {
			eth0       => { ip => '192.168.1.10', netmask => '255.255.255.0' },
			tailscale0 => { ip => '100.64.0.4',   netmask => '255.255.255.255' },
		};
	};
	local *subs::subnet_sweep = sub { push @swept, join('|', @_); return };
	local *subs::ip_is_private = sub { return 1 };
	local *JawnOS::Platform::Net::neighbour_lines = sub {
		return [
			'192.168.1.50 lladdr aa:bb:cc:dd:ee:01 REACHABLE',
			'192.168.1.60 INCOMPLETE',
			'192.168.1.10 lladdr aa:bb:cc:dd:ee:02 REACHABLE',
			'192.168.1.90 lladdr aa:bb:cc:dd:ee:03 REACHABLE',
		];
	};
	my @probed;
	local *JawnOS::Platform::Print::probe = sub {
		push @probed, $_[0];
		return $_[0] eq '192.168.1.50' ? 1 : 0;
	};
	my $uris = subs::printer_subnet_candidates();
	is_deeply($uris, [ 'ipp://192.168.1.50:631/ipp/print' ],
		'the live host answering IPP becomes a candidate');
	is_deeply(\@swept, [ 'eth0|192.168.1.10|255.255.255.0' ],
		'only the real LAN NIC is swept, not the tailnet');
	is_deeply(\@probed, [ '192.168.1.50', '192.168.1.90' ],
		'this machine and the incomplete row are not probed');
}

# --- the Default printer select ---------------------------------------------
# A printer the house can already see is choosable before CUPS has a queue for
# it. The listing comes from the stored device rows, one per address; choosing
# it adds the queue and stores it as the default.
{
	no warnings 'redefine';
	local *subs::db_select = sub {
		return FakeRows->new([
			{ address => encode_json({ wlo1 => {
				ip => '192.168.1.123',
				neigh => [
					{ ip => '192.168.1.50', purpose => 'printer', name => 'HP OfficeJet 3830' },
					{ ip => '192.168.1.50', purpose => 'printer', name => 'HP OfficeJet 3830' },
					{ ip => '192.168.1.60', purpose => 'printer', model => 'Laser' },
					{ ip => '192.168.1.70', purpose => 'hmmm',    name => 'not a printer' },
				],
			} }) },
		]);
	};
	my $nets = subs::printer_network_printers();
	is_deeply([ map { [ $_->{'ip'}, $_->{'name'} ] } @{$nets} ],
		[ [ '192.168.1.50', 'HP OfficeJet 3830' ], [ '192.168.1.60', 'Laser' ] ],
		'the stored printer rows are offered once per address');
}
{
	no warnings 'redefine';
	local $subs::cups_printers_memo = undef;
	local *subs::cups_printers = sub { return [ { name => 'PDF', uri => 'ipp://127.0.0.1/ipp/print' } ] };
	local *JawnOS::Platform::Print::tool = sub { return '/usr/bin/lpadmin' if $_[0] eq 'lpadmin'; return '' };
	my @added;
	local *JawnOS::Platform::Print::add_queue = sub { push @added, [ @_ ]; return 0 };
	my @stored;
	local *subs::setting_setter = sub { push @stored, $_[0]; return 1 };
	local *subs::signatorial_designer = sub { return 'sig' };
	local *subs::rightNow = sub { return 1234567890000 };
	my $done = subs::printer_default_network('192.168.1.50', 'HP OfficeJet 3830');
	ok($done->{'ok'}, 'a network printer is added and chosen');
	is($done->{'default'}, 'hp-officejet-3830', 'the queue is named after the printer');
	is_deeply($added[0], [ 'hp-officejet-3830', 'ipp://192.168.1.50:631/ipp/print' ],
		'the queue add uses the printer address');
	is($stored[-1]{'value'}, 'hp-officejet-3830', 'and the default is stored');
}
{
	no warnings 'redefine';
	local $subs::cups_printers_memo = undef;
	local *subs::cups_printers = sub {
		return [ { name => 'Officejet', uri => 'ipp://192.168.1.50:631/ipp/print' } ];
	};
	local *JawnOS::Platform::Print::add_queue = sub { die 'an existing queue must be reused' };
	local *subs::setting_setter = sub { return 1 };
	local *subs::signatorial_designer = sub { return 'sig' };
	local *subs::rightNow = sub { return 1234567890000 };
	my $reuse = subs::printer_default_network('192.168.1.50', 'HP');
	is($reuse->{'default'}, 'Officejet', 'an existing queue for the address is reused');
}

# --- the document feeder ----------------------------------------------------
# The machine with the scanner watches its printer's feeder. A loaded edge is
# one notice and one Market command; paper left in the tray is announced once,
# and removing it then loading the next is a new edge. A machine with no ADF
# feed, and a server, stay quiet.
{
	no warnings 'redefine';
	my $state = 'empty';
	my $last = '';
	my @notes;
	my @frames;
	local *subs::device_setter = sub { return 'computer' };
	local *subs::config_reader = sub {
		return { scanners => [ {
			address => 'hpaio:/net/officejet_3830_series?ip=192.168.1.50',
			feeds => [ 'adf', 'flatbed' ],
		} ] };
	};
	local *subs::device_lister = sub {
		return { ip => '192.168.1.50', name => 'HP OfficeJet 3830' };
	};
	local *JawnOS::Platform::Print::adf_state = sub { return $state };
	local *subs::cache_get = sub { return $last };
	local *subs::cache_set = sub { $last = $_[1]; return 1 };
	local *subs::random_string_creator = sub { return 'uuid' };
	local *subs::rightNow = sub { return 1234567890000 };
	local *subs::log_writer = sub { return 1 };
	local *subs::notification_sender = sub { push @notes, $_[0]; return 1 };
	local *Websocket::send = sub { push @frames, $_[1]; return 1 };
	local *Websocket::console_command = sub { return { cmd => $_[0], args => [ @_[1..$#_] ] } };

	is(subs::adf_receipt_watch(), 0, 'an empty feeder has nothing to announce');
	is($last, 'empty', 'and the state is remembered');
	$state = 'loaded';
	is(subs::adf_receipt_watch(), 1, 'a loaded feeder is the edge');
	is(scalar @notes, 1, 'one notice is sent');
	is($notes[0]{'app'}, 'market', 'for the Market app');
	is(scalar @frames, 1, 'and one command to the Market windows');
	is($frames[0]{'console'}{'cmd'}, 'marketReceiptAdf', 'asking a window to take the paper');
	is(subs::adf_receipt_watch(), 0, 'the same paper is not announced twice');
	is(scalar @notes, 1, 'with no second notice');
	$state = 'empty';
	is(subs::adf_receipt_watch(), 0, 'removing the paper is not an edge');
	$state = 'loaded';
	is(subs::adf_receipt_watch(), 1, 'loading the next one is');
	is(scalar @notes, 2, 'with a fresh notice');

	local *subs::device_setter = sub { return 'server' };
	is(subs::adf_receipt_watch(), 0, 'a server with no scanner stays quiet');

	local *subs::device_setter = sub { return 'computer' };
	local *subs::config_reader = sub {
		return { scanners => [ { address => 'hpaio:/net/x?ip=192.168.1.50', feeds => [ 'flatbed' ] } ] };
	};
	is(subs::adf_receipt_watch(), 0, 'a scanner with no ADF feed stays quiet');
}

# A CUPS server that does not answer must not hold the Dev panel open: lpstat
# talks to cupsd and waits out its own connect timeout when it cannot. The read
# is bounded, so the panel draws with no queues instead of stalling.
like(read_file("$root/lib/JawnOS/Platform/Print.pm"),
	qr/_bounded\(3,\s*\$lpstat/, 'the lpstat read is bounded');

# CUPS is slow enough on a machine with a network printer that the Dev panel
# must not pay for a fresh queue list every time it is drawn. One read serves a
# few minutes of draws; Find printers clears it when the queues really change.
{
	local $subs::cups_printers_memo = undef;
	my $count = "$dir/lpstat_calls";
	unlink $count;
	my $counted = fake_script('lpstat_counted',
		"echo x >> $count\nprintf 'printer PDF is idle.\\n'");
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return $_[0] eq 'lpstat' ? $counted : '' };
	my $first = subs::cups_printers();
	my $second = subs::cups_printers();
	is(scalar @{$first}, 1, 'a queue is read');
	is(scalar @{$second}, 1, 'and served while the memo holds');
	my $calls = (read_file($count) =~ tr/\n//);
	is($calls, 1, 'lpstat ran once for two draws');
}

# The Dev listing already read the queues for its draw, so the default is chosen
# from that list rather than asking lpstat a second time.
{
	my $calls = 0;
	no warnings 'redefine';
	local *subs::cups_printers = sub { $calls++; return [ { name => 'PDF' } ] };
	local *subs::setting_grabber = sub { return 'PDF' };
	local *subs::signatorial_designer = sub { return 'sig' };
	local *subs::device_setter = sub { return 'computer' };
	my $default = subs::printer_default_get([ { name => 'PDF' }, { name => 'Officejet' } ]);
	is($default, 'PDF', 'a passed queue list answers the default');
	is($calls, 0, 'without reading the queues again');
	$default = subs::printer_default_get();
	is($default, 'PDF', 'no list still reads the queues');
	is($calls, 1, 'once');
}

# The Dev draw must not wait on CUPS: it renders the saved queue name (a plain
# settings read) and lets the card fill itself after the panel is on screen.
{
	no warnings 'redefine';
	local *subs::setting_grabber = sub { return 'PDF' };
	local *subs::signatorial_designer = sub { return 'sig' };
	local *subs::device_setter = sub { return 'computer' };
	local *subs::cups_printers = sub { die 'printer_default_saved must not ask CUPS' };
	is(subs::printer_default_saved(), 'PDF', 'the saved default is read without CUPS');
}

# --- the PDF path -----------------------------------------------------------
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return ''; };
	my ($pdf, $error) = subs::printer_pdf_from_html('<html><body>x</body></html>');
	ok(!defined $pdf, 'no PDF without weasyprint');
	like($error, qr/weasyprint/, 'and the error names it');
}
{
	my $weasy = fake_script('weasyprint', 'printf "%%PDF-1.4\\n" > "$2"');
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return $weasy if $_[0] eq 'weasyprint'; return ''; };
	my ($pdf, $error) = subs::printer_pdf_from_html('<html><body>x</body></html>');
	ok(defined $pdf, 'a PDF is produced when weasyprint is there');
	is($error, undef, 'with no error');
	ok(-s $pdf, 'and the file has bytes');
	if (defined $pdf) {
		open my $fh, '<', $pdf;
		my $head = <$fh>;
		close $fh;
		like($head, qr/^%PDF/, 'and starts with the PDF signature');
		unlink $pdf;
	}
}

# --- the wiring -------------------------------------------------------------
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::Printer2' for qw\([^)]*cups_sync_printers/, 'Printer2 is mapped');
my $configure_routes = read_file("$root/lib/JawnOS/Routes/manager_configure.pm");
like($configure_routes, qr{/manager/configure/printer_sync}, 'the Dev panel sync route exists');
like($configure_routes, qr{/manager/configure/printer_default}, 'the default-printer route exists');
my $configure = read_file("$root/lib/JawnOS/Controller/manager_configure.pm");
like($configure, qr/sub action_52022\b/, 'the sync action exists');
like($configure, qr/printer_default_get/, 'the listing reads the default');
like($configure, qr/printer_default_network/, 'a network choice adds its queue');
my ($dev_action) = $configure =~ /(sub action_7789\b.*?\n\})/s;
ok($dev_action, 'the Dev action is found');
unlike($dev_action, qr/cups_printers|printer_default_get\b/,
	'the Dev draw does not wait on lpstat');
like($dev_action, qr/printer_default_saved/,
	'it draws the saved default at once');
my ($list_action) = $configure =~ /(sub action_52020\b.*?\n\})/s;
ok($list_action, 'the printer-list action is found');
like($list_action, qr/queues_only/,
	'the card filler can skip the network sweep');
like($list_action, qr/network_printers/,
	'and lists the printers the house can already see');
my $dev = read_file("$root/templates/configure/device_lister/body.html.ep");
like($dev, qr/id="default_printer_select"/, 'the Dev panel has the default printer select');
like($dev, qr/id="printer_queues_line"/, 'and a line the queue list fills');
like($dev, qr/data-none="/, 'the empty message is carried for the filler');
like($dev, qr/data-network="/, 'and the label for a printer on the network');
like($dev, qr/class="printer_sync"/, 'and a Find printers button');
my $dev_js = read_file("$root/public/js/manager/configure/01_update_controls.js");
like($dev_js, qr/function printerQueuesLoad\(scope\)/,
	'the printer card fills itself');
like($dev_js, qr/queues_only: 1/, 'without the network sweep');
like($dev_js, qr/network_printers/, 'the fill offers the printers the house can see');
like($dev_js, qr/net:/, 'as a net: address the change can add');
like($dev_js, qr/printerQueuesLoad\(\$\('#device_list'\)\)/,
	'the Dev draw starts the fill');
like($dev_js, qr/panel\.scrollTop \+= grew/,
	'growth above the reader is given back to the scroll');
my $dev_devices_js = read_file("$root/public/js/manager/configure/02_remote_devices.js");
like($dev_devices_js, qr/printer_ip/, 'choosing a network printer posts its address');
like($dev_devices_js, qr/printerQueuesLoad\(\$\('#device_list'\)\)/,
	'and redraws the queue list after adding it');

# The ADF watch runs on the machine with the scanner and tells an open Market
# window; one claim per edge keeps two windows from pulling the same paper.
like(read_file("$root/perl/jobs.pl"), qr/sub job_adf_receipt_watch\b/,
	'the feeder watch has a resident job');
like(read_file("$root/perl/President.pl"), qr/job_adf_receipt_watch/,
	'and the master starts it');
my $market2_routes = read_file("$root/lib/JawnOS/Routes/manager_market2.pm");
like($market2_routes, qr{/manager/market/receipt/adf/claim}, 'the ADF claim route exists');
my $market2 = read_file("$root/lib/JawnOS/Controller/manager_market2.pm");
like($market2, qr/sub action_52310\b/, 'with its action');
my $receipt_js = read_file("$root/public/js/manager/market/01_tabs_and_receipts.js");
like($receipt_js, qr/window\.marketReceiptAdf\s*=/, 'the Market window takes a feeder notice');
like($receipt_js, qr{/manager/market/receipt/adf/claim}, 'through the one-claim route');
like(read_file("$root/public/js/manager/websocket/00_console_router.js"), qr/marketReceiptAdf/,
	'the console router dispatches it');

my $store_routes = read_file("$root/lib/JawnOS/Routes/store_misc.pm");
like($store_routes, qr{/store/print/printers}, 'the Store printer list route exists');
like($store_routes, qr{/store/print/send}, 'the Store print route exists');
like($store_routes, qr{/store/print/pdf}, 'the Store PDF route exists');
my $store = read_file("$root/lib/JawnOS/Controller/store_misc.pm");
like($store, qr/sub action_52031\b/, 'the Store print action exists');
like($store, qr/printer_cups_send/, 'and it sends to CUPS');
my $js = read_file("$root/public/js/store.js");
like($js, qr/function storePrintPrepare/, 'the Store has the print bar');
like($js, qr{/store/print/send}, 'it posts the job');
like($js, qr{/store/print/pdf}, 'and can save the PDF');
my $register = read_file("$root/public/js/store/register.js");
like($register, qr/storePrintPrepare\(html/, 'the register receipt uses the same bar');
my $css = read_file("$root/public/css/store.css");
like($css, qr/#store_print_bar/, 'the print bar has its own styles');

done_testing();
