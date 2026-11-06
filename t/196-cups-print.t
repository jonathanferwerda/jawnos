# tests-for: lib/JawnOS/Domain/Printer2.pm lib/JawnOS/Controller/manager_configure.pm lib/JawnOS/Controller/store_misc.pm lib/JawnOS/Routes/manager_configure.pm lib/JawnOS/Routes/store_misc.pm templates/configure/device_lister/body.html.ep public/js/manager/configure/02_remote_devices.js public/js/store.js public/js/store/register.js public/css/store.css
# covers:    CUPS queue discovery (lpstat), network printer discovery (ippfind),
#            adding a queue (lpadmin), the print/PDF path, and the Dev/Store wiring.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use RepoSource;

my $root = repo_root();
require "$root/lib/JawnOS/Domain/Printer2.pm";

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
	local *subs::printer_command_path = sub {
		my ($name) = @_;
		return $lpstat if $name eq 'lpstat';
		return $ippfind if $name eq 'ippfind';
		return $lpadmin if $name eq 'lpadmin';
		return '';
	};
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

# --- the PDF path -----------------------------------------------------------
{
	no warnings 'redefine';
	local *subs::printer_command_path = sub { return ''; };
	my ($pdf, $error) = subs::printer_pdf_from_html('<html><body>x</body></html>');
	ok(!defined $pdf, 'no PDF without weasyprint');
	like($error, qr/weasyprint/, 'and the error names it');
}
{
	my $weasy = fake_script('weasyprint', 'printf "%%PDF-1.4\\n" > "$2"');
	no warnings 'redefine';
	local *subs::printer_command_path = sub { return $weasy if $_[0] eq 'weasyprint'; return ''; };
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
my $dev = read_file("$root/templates/configure/device_lister/body.html.ep");
like($dev, qr/id="default_printer_select"/, 'the Dev panel has the default printer select');
like($dev, qr/class="printer_sync"/, 'and a Find printers button');

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
