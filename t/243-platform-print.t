# tests-for: lib/JawnOS/Platform/Print.pm lib/JawnOS/Domain/Printer2.pm lib/JawnOS/Domain/Printer.pm lib/JawnOS/Manager/Part02.pm
# covers:    the print seam: the lpstat/ippfind/lpinfo/scanimage argv and bounds
#            against fixtures, the IPP port probe, the ink reply, the safe
#            answers for a machine with no print stack, and the domain call
#            sites that now ask the seam.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);

use JawnOS::Platform::Print qw(
	available unsupported printers discover probe add_queue send pdf_from_html ink
	adf_state scan_argv parse_lpstat
);

my $root = "$FindBin::Bin/..";
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

sub recorded {
	my ($path) = @_;
	return [] unless -e $path;
	my @lines = split /\n/, read_file($path);
	return \@lines;
}

# --- the lpstat parse -------------------------------------------------------
my $lpstat_out = <<'LPS';
printer Officejet disabled since Thu 06 Nov 2026 10:00:00 AM EST -
	reason unknown
device for Officejet: ipp://192.168.1.50:631/ipp/print
Officejet accepting requests since Thu 06 Nov 2026 09:00:00 AM EST
printer PDF is idle. enabled since Thu 06 Nov 2026 09:00:00 AM EST
system default destination: PDF
LPS
my $lpstat_fixture = "$dir/lpstat.out";
write_file($lpstat_fixture, $lpstat_out);

my $queues = parse_lpstat($lpstat_out);
is(scalar @{$queues}, 2, 'lpstat parses two queues');
is_deeply([ map { $_->{'name'} } @{$queues} ], [qw(Officejet PDF)], 'queues are sorted by name');
my ($office) = grep { $_->{'name'} eq 'Officejet' } @{$queues};
is($office->{'enabled'}, 0, 'a disabled queue is marked disabled');
is($office->{'state'}, 'disabled', 'with its state');
is($office->{'uri'}, 'ipp://192.168.1.50:631/ipp/print', 'its device URI is read');
is($office->{'accepting'}, 1, 'its accepting state is read');
is($office->{'detail'}, 'disabled since Thu 06 Nov 2026 10:00:00 AM EST -', 'its detail line is kept');
is($office->{'default'}, 0, 'it is not the default');
my ($pdf) = grep { $_->{'name'} eq 'PDF' } @{$queues};
is($pdf->{'default'}, 1, 'the system default is marked');
is_deeply(parse_lpstat(''), [], 'no lpstat output is an empty list');

# --- the scanimage argv -----------------------------------------------------
my $dev = 'hpaio:/net/officejet_3830_series?ip=192.168.1.50';
is_deeply(scan_argv('flatbed', '/tmp/page', $dev, '300'),
	[ 'scanimage', '--format', 'tiff', '--source', 'Flatbed', '--batch', '/tmp/page.tiff',
	  '--mode', 'Color', '-d', $dev, '--resolution=300', '--progress' ],
	'the flatbed argv is the one scanimage ran');
is_deeply(scan_argv('adf', '/tmp/page', $dev, '200dpi'),
	[ 'scanimage', '--format', 'tiff', '--source', 'ADF', '--batch', '/tmp/page_%d.tiff',
	  '--mode', 'Color', '-d', $dev, '--resolution=200dpi', '--progress' ],
	'the ADF argv writes numbered pages');
is_deeply(scan_argv('duplex', '/tmp/page', $dev, '300'), [], 'an unknown feeder has no argv');
is_deeply(scan_argv('flatbed', '', $dev, '300'), [], 'no file has no argv');

# --- available / unsupported ------------------------------------------------
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return ''; };
	ok(!available(), 'no CUPS tool means no print stack');
	ok(unsupported(), 'and the machine is unsupported');
}
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return $_[0] eq 'lpstat' ? '/usr/bin/lpstat' : ''; };
	ok(available(), 'lpstat alone is a print stack');
	ok(!unsupported(), 'so it is supported');
}

# --- the bounded lpstat read ------------------------------------------------
my $timeout_log = "$dir/timeout.log";
my $timeout = fake_script('timeout', <<"SH");
printf '%s\\n' "\$@" >> '$timeout_log'
shift
exec "\$@"
SH
my $lpstat_log = "$dir/lpstat.log";
my $lpstat = fake_script('lpstat', <<"SH");
printf '%s\\n' "\$@" >> '$lpstat_log'
cat '$lpstat_fixture'
SH
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub {
		return $timeout if $_[0] eq 'timeout';
		return $lpstat if $_[0] eq 'lpstat';
		return '';
	};
	my ($list, $complete) = printers();
	is($complete, 1, 'a finished read is complete');
	is(scalar @{$list}, 2, 'and answers the two queues');
	is_deeply(recorded($timeout_log), [ '3', $lpstat, '-p', '-d', '-v', '-a' ],
		'lpstat runs under a 3-second timeout with the same argv');
	is_deeply(recorded($lpstat_log), [ '-p', '-d', '-v', '-a' ], 'with the same options');
}

# --- ippfind ----------------------------------------------------------------
my $ippfind_log = "$dir/ippfind.log";
my $ippfind = fake_script('ippfind', <<"SH");
printf '%s\\n' "\$@" >> '$ippfind_log'
cat <<'OUT'
ipp://192.168.1.60:631/ipp/print
ipp://192.168.1.50:631/ipp/print
file:///etc/passwd
ipp://host/print;rm -rf /
OUT
SH
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return $_[0] eq 'ippfind' ? $ippfind : ''; };
	my $found = discover();
	is_deeply($found,
		[ 'ipp://192.168.1.50:631/ipp/print', 'ipp://192.168.1.60:631/ipp/print' ],
		'ippfind answers the IPP URIs, sorted, and drops the rest');
	is_deeply(recorded($ippfind_log), [ '-T', '5' ], 'ippfind keeps its five-second walk');
}

# --- lpinfo ---------------------------------------------------------------
# ippfind lives in cups-ipp-utils and a desktop often does not install it; the
# CUPS client's own enumeration is the fallback that makes Find printers work
# there. Only the IPP/CUPS-spooler rows are kept: a dnssd:// or raw URI cannot
# be added with -m everywhere.
my $lpinfo_log = "$dir/lpinfo.log";
my $lpinfo = fake_script('lpinfo', <<"SH");
printf '%s\\n' "\$@" >> '$lpinfo_log'
cat <<'OUT'
network ipp://192.168.1.50:631/ipp/print
network dnssd://Officejet%20Pro._ipp._tcp.local/%3F
network socket://192.168.1.50:9100
direct hp:/usb/HP_LaserJet?serial=X
file cups-brf:/
OUT
SH
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return $_[0] eq 'lpinfo' ? $lpinfo : ''; };
	my $found = discover();
	is_deeply($found, [ 'ipp://192.168.1.50:631/ipp/print' ],
		'lpinfo answers the IPP URI ippfind did not, and the raw rows are dropped');
	is_deeply(recorded($lpinfo_log), [ '-v' ], 'lpinfo runs with -v');
}

# --- the IPP port probe ----------------------------------------------------
# A printer with Bonjour off is found by asking each live neighbour for IPP; a
# plain TCP connect is the cheap filter before lpadmin validates the URI.
{
	require IO::Socket::INET;
	my $server = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
		Listen => 1, ReuseAddr => 1,
	);
	ok($server, 'a listening socket is made for the probe fixture');
	my $open_port = $server->sockport;
	is(probe('127.0.0.1', $open_port), 1, 'a host answering on the port is a candidate');
	close $server;
	my $closer = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
		Listen => 1, ReuseAddr => 1,
	);
	my $closed_port = $closer->sockport;
	close $closer;
	is(probe('127.0.0.1', $closed_port), 0, 'a closed port is not');
	is(probe('not-an-address'), 0, 'a non-address is refused');
}

# --- the ADF status ---------------------------------------------------------
# A receipt waiting in the feeder is what the Market watcher looks for. eSCL
# reports it at /eSCL/ScannerStatus; the status word is read without caring
# which XML namespace the printer used, and a jam or an off printer stays
# unknown so the watcher does not announce paper it cannot pull.
my $adf_log = "$dir/adf.log";
my $adf_loaded = fake_script('curl_loaded', <<"SH");
printf '%s\\n' "\$@" >> '$adf_log'
cat <<'XML'
<?xml version="1.0"?><scan:ScannerStatus><pwg:AdfState>ScannerAdfLoaded</pwg:AdfState></scan:ScannerStatus>
XML
SH
my $adf_empty = fake_script('curl_empty', <<'SH');
cat <<'XML'
<?xml version="1.0"?><pwg:ScannerStatus><pwg:AdfState>ScannerAdfEmpty</pwg:AdfState></pwg:ScannerStatus>
XML
SH
my $adf_jam = fake_script('curl_jam', <<'SH');
cat <<'XML'
<?xml version="1.0"?><pwg:ScannerStatus><pwg:AdfState>ScannerAdfJam</pwg:AdfState></pwg:ScannerStatus>
XML
SH
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return $_[0] eq 'curl' ? $adf_loaded : ''; };
	is(adf_state('192.168.1.50'), 'loaded', 'a page waiting in the ADF is loaded');
	is_deeply(recorded($adf_log), [ '-s', '--max-time', '3', 'http://192.168.1.50/eSCL/ScannerStatus' ],
		'the eSCL status endpoint is asked with a three-second bound');
}
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return $_[0] eq 'curl' ? $adf_empty : ''; };
	is(adf_state('192.168.1.50'), 'empty', 'an empty feeder is empty');
}
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return $_[0] eq 'curl' ? $adf_jam : ''; };
	is(adf_state('192.168.1.50'), 'unknown', 'a jam is not announced as paper');
	is(adf_state('not-an-address'), 'unknown', 'a non-address has no feeder');
}

# --- lpadmin ----------------------------------------------------------------
my $lpadmin_log = "$dir/lpadmin.log";
my $lpadmin = fake_script('lpadmin', "printf '%s\\n' \"\$@\" >> '$lpadmin_log'\nexit 0");
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return $_[0] eq 'lpadmin' ? $lpadmin : ''; };
	my $rc = add_queue('jaws', 'ipp://192.168.1.50:631/ipp/print');
	is($rc, 0, 'lpadmin succeeds');
	is_deeply(recorded($lpadmin_log),
		[ '-p', 'jaws', '-E', '-v', 'ipp://192.168.1.50:631/ipp/print', '-m', 'everywhere', '-D', 'jaws' ],
		'add_queue builds the same argv');
}

# --- lp and the sudo retry --------------------------------------------------
my $lp_log = "$dir/lp.log";
my $lp = fake_script('lp', "printf '%s\\n' \"\$@\" >> '$lp_log'\nexit 0");
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return $_[0] eq 'lp' ? $lp : ''; };
	my $rc = send('jaws', '/tmp/job.pdf');
	is($rc, 0, 'lp succeeds');
	is_deeply(recorded($lp_log), [ '-d', 'jaws', '/tmp/job.pdf' ], 'send builds the same argv');
}

my $lp_fail_log = "$dir/lp_fail.log";
my $lp_fail = fake_script('lp_fail', "printf '%s\\n' \"\$@\" >> '$lp_fail_log'\nexit 1");
my $sudo_log = "$dir/sudo.log";
my $sudo = fake_script('sudo', "printf '%s\\n' \"\$@\" >> '$sudo_log'\nexit 0");
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return $_[0] eq 'lp' ? $lp_fail : ''; };
	local $ENV{PATH} = "$dir:$ENV{PATH}";
	my $rc = send('jaws', '/tmp/job.pdf');
	is($rc, 0, 'a refused direct send is retried through sudo -n');
	is_deeply(recorded($sudo_log), [ '-n', $lp_fail, '-d', 'jaws', '/tmp/job.pdf' ],
		'with the same command under sudo -n');
}

# --- the PDF path -----------------------------------------------------------
my $weasy_log = "$dir/weasy.log";
my $weasy = fake_script('weasyprint', "printf '%s\\n' \"\$@\" >> '$weasy_log'\nprintf '%%PDF-1.4\\n' > \"\$2\"");
my $pdf_timeout_log = "$dir/pdf_timeout.log";
my $pdf_timeout = fake_script('pdf_timeout', <<"SH");
printf '%s\\n' "\$@" >> '$pdf_timeout_log'
shift
exec "\$@"
SH
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub {
		return $pdf_timeout if $_[0] eq 'timeout';
		return $weasy if $_[0] eq 'weasyprint';
		return '';
	};
	my ($pdf, $error) = pdf_from_html('<html><body>x</body></html>');
	ok(defined $pdf, 'a PDF is produced');
	is($error, undef, 'with no error');
	ok(-s $pdf, 'and the file has bytes');
	my $argv = recorded($pdf_timeout_log);
	is(scalar @{$argv}, 4, 'weasyprint runs under a bound');
	is($argv->[0], '45', 'of 45 seconds');
	is($argv->[1], $weasy, 'with weasyprint');
	like($argv->[2], qr/\.html$/, 'and the HTML file');
	like($argv->[3], qr/\.pdf$/, 'writing the PDF file');
	unlink $pdf if defined $pdf;
}
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return ''; };
	my ($pdf, $error) = pdf_from_html('<html><body>x</body></html>');
	ok(!defined $pdf, 'no PDF without weasyprint');
	like($error, qr/weasyprint/, 'and the error names it');
}

# --- ink ------------------------------------------------------------------
is_deeply(ink('not-an-ip'), { error => 'no address' }, 'an invalid address has no ink read');
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub { return ''; };
	is_deeply(ink('10.0.0.5'), { error => 'ipptool not installed' }, 'no ipptool is named');
}
my $ipptool_log = "$dir/ipptool.log";
my $ipptool = fake_script('ipptool', <<"SH");
printf '%s\\n' "\$@" >> '$ipptool_log'
cat <<'IPP'
  printer-make-and-model (text) = Test Printer
  printer-state (enum) = idle
  printer-state-reasons (1setOf keyword) = none
  marker-names (1setOf nameWithoutLanguage) = Black,Cyan
  marker-colors (1setOf color) = #000000,#00ffff
  marker-types (1setOf keyword) = toner,toner
  marker-levels (1setOf integer) = 80,30
IPP
SH
my $ink_timeout_log = "$dir/ink_timeout.log";
my $ink_timeout = fake_script('ink_timeout', <<"SH");
printf '%s\\n' "\$@" >> '$ink_timeout_log'
shift
exec "\$@"
SH
{
	no warnings 'redefine';
	local *JawnOS::Platform::Print::tool = sub {
		return $ink_timeout if $_[0] eq 'timeout';
		return $ipptool if $_[0] eq 'ipptool';
		return '';
	};
	my $ink = ink('10.0.0.5');
	is($ink->{'make'}, 'Test Printer', 'the make and model are read');
	is($ink->{'state'}, 'idle', 'the printer state is read');
	is_deeply($ink->{'reasons'}, [], 'a "none" reason is dropped');
	is(scalar @{ $ink->{'markers'} }, 2, 'both cartridges are read');
	is($ink->{'markers'}[0]{'name'}, 'Black', 'a marker keeps its name');
	is_deeply($ink->{'markers'}[0]{'colors'}, ['#000000'], 'and its colour');
	is($ink->{'markers'}[0]{'percent'}, 80, 'and its percentage');
	is($ink->{'markers'}[1]{'percent'}, 30, 'the second cartridge too');
	my $argv = recorded($ink_timeout_log);
	is($argv->[0], '6', 'the ink read is bounded at six seconds');
	my $tool_argv = recorded($ipptool_log);
	is($tool_argv->[0], '-tv', 'ipptool runs with -tv');
	is($tool_argv->[1], 'ipp://10.0.0.5:631/ipp/print', 'against ipp/print');
	ok(defined $tool_argv->[2] && length $tool_argv->[2], 'with a test file');
}

# --- the call sites ---------------------------------------------------------
my $print2 = read_file("$root/lib/JawnOS/Domain/Printer2.pm");
like($print2, qr/JawnOS::Platform::Print::printers\b/, 'Printer2 lists queues through the seam');
like($print2, qr/JawnOS::Platform::Print::discover\b/, 'Printer2 discovers through the seam');
like($print2, qr/JawnOS::Platform::Print::add_queue\b/, 'Printer2 adds a queue through the seam');
like($print2, qr/JawnOS::Platform::Print::send\b/, 'Printer2 sends through the seam');
like($print2, qr/JawnOS::Platform::Print::pdf_from_html\b/, 'Printer2 makes the PDF through the seam');
like($print2, qr/sub printer_command_path.*?JawnOS::Platform::Print::tool/s,
	'the old path helper delegates to the seam');
unlike($print2, qr/`[^`\n]*\$lpstat/, 'Printer2 runs no lpstat of its own');

my $printer = read_file("$root/lib/JawnOS/Domain/Printer.pm");
like($printer, qr/JawnOS::Platform::Print::ink\b/, 'the ink read goes through the seam');
unlike($printer, qr/\bipptool\b/, 'Printer no longer builds the ipptool read');

my $part02 = read_file("$root/lib/JawnOS/Manager/Part02.pm");
like($part02, qr/JawnOS::Platform::Print::scan_argv\b/, 'the scan command comes from the seam');
unlike($part02, qr/scanimage --format/, 'Part02 no longer builds the scanimage string');

done_testing();
