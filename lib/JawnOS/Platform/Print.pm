package JawnOS::Platform::Print;

# Printing behind one interface. Linux runs the CUPS client the domain code
# did - lpstat to list queues, lpadmin to add one, lp to send, weasyprint for
# the PDF, ipptool for an ink read - and scanimage for the two feeders the
# house uses. The argv, the bounds (3s lpstat, 5s ippfind, 45s PDF, 6s ink)
# and the `sudo -n` retry are the ones the domain code built, so a Linux house
# prints exactly as it did. macOS speaks the same CUPS commands; the Windows
# spooler backend is P3. A machine with no print stack answers empty results
# or an error hash instead of dying.
#
# The parsers are exported so a fixture can pin the shapes: parse_lpstat reads
# `lpstat -p -d -v -a`, and scan_argv builds the scanimage argv.

use strict;
use warnings;

use File::Spec;
use File::Temp ();

use Exporter 'import';
our @EXPORT_OK = qw(
	available unsupported tool
	printers discover probe add_queue send pdf_from_html ink scan_argv
	adf_state
	parse_lpstat
);

BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../.." if $dir && -d "$dir/../..";
}
use JawnOS::Platform ();

# The manager's PATH is not the login shell's, so try the PATH answer and then
# the usual homes, in the order the domain code tried them. The name is a
# fixed identifier, never caller text. A CUPS tool lives in the same places
# lpstat did; ipptool passes its own (shorter) list.
my @CUPS_DIRS = qw(/usr/bin /usr/local/bin /bin /usr/sbin /sbin);
sub tool {
	my ($name, @dirs) = @_;
	return undef unless defined $name && $name =~ /^[A-Za-z0-9_.\-]+$/;
	my $path = JawnOS::Platform::tool_path($name);
	return $path if defined $path && length $path;
	@dirs = @CUPS_DIRS unless @dirs;
	foreach my $dir (@dirs) {
		my $candidate = "$dir/$name";
		return $candidate if -f $candidate && -x $candidate;
	}
	return undef;
}

# Is there a print stack at all? The CUPS client is the stack: listing,
# sending or adding a queue needs one of these. available() answers for a
# caller that wants to draw a hint; unsupported() is its negation.
sub available {
	foreach my $name (qw(lpstat lp lpadmin)) {
		my $path = tool($name);
		return 1 if defined $path && length $path;
	}
	return 0;
}

sub unsupported { return available() ? 0 : 1 }

# Run a bounded read and keep stdout. A failed or timed-out read answers empty
# text; the exit status is read from close() so the 124 that timeout(1) uses is
# visible to the caller. stderr is dropped here because lpstat and ippfind
# print their connection complaints there and the domain code silenced them.
sub _run {
	my (@command) = @_;
	return ('', 0) unless @command;
	my $pid = open(my $fh, '-|');
	return ('', 0) unless defined $pid;
	if (!$pid) {
		open(STDERR, '>', File::Spec->devnull());
		exec { $command[0] } @command;
		exit 127;
	}
	my $out = do { local $/; <$fh> };
	close $fh;
	my $timed_out = (($? >> 8) == 124) ? 1 : 0;
	return (defined $out ? $out : '', $timed_out);
}

# Prefix a command with timeout(1) when the machine has it, the way the domain
# code did. The seconds are a literal, never caller text.
sub _bounded {
	my ($seconds, @command) = @_;
	return @command unless @command;
	my $timeout = tool('timeout');
	return @command unless defined $timeout && length $timeout;
	return ($timeout, $seconds, @command);
}

# `lpstat -p -d -v -a`, parsed. Each queue is a row {name,state,enabled,
# accepting,detail,uri,default}; a queue named by `system default destination`
# is marked default. The caller decides what to do with the status.
sub parse_lpstat {
	my ($text) = @_;
	my (%printer, $default);
	return [] unless defined $text && length $text;
	foreach my $line (split /\n/, $text) {
		if ($line =~ /^printer\s+(\S+)\s+(.*)$/) {
			my ($name, $rest) = ($1, $2);
			$printer{$name} ||= { name => $name, enabled => 1, accepting => 0 };
			$printer{$name}{'state'} = $1 if $rest =~ /^(?:is|now)\s+(\w+)/;
			$printer{$name}{'state'} = 'disabled' if $rest =~ /disabled/;
			$printer{$name}{'enabled'} = 0 if $rest =~ /disabled/;
			$printer{$name}{'detail'} = $rest;
		}
		elsif ($line =~ /^system default destination:\s*(\S+)/) {
			$default = $1;
		}
		elsif ($line =~ /^device for\s+(\S+):\s*(.+)$/) {
			$printer{$1} ||= { name => $1, enabled => 1, accepting => 0 };
			$printer{$1}{'uri'} = $2;
		}
		elsif ($line =~ /^(\S+)\s+accepting requests/) {
			$printer{$1} ||= { name => $1, enabled => 1, accepting => 0 };
			$printer{$1}{'accepting'} = 1;
		}
	}
	my @list = map { $printer{$_} } sort keys %printer;
	foreach my $p (@list) {
		$p->{'default'} = (defined $default && $p->{'name'} eq $default) ? 1 : 0;
		$p->{'state'} ||= 'idle';
		$p->{'uri'} ||= '';
	}
	return \@list;
}

# The queues this machine has. The read is bounded because lpstat talks to
# cupsd, and a CUPS server that is down holds its own connect timeout out.
# Answers ($list, $complete): $complete is false when the tool was missing or
# the read timed out, so a caller can decline to cache a failed answer. A
# timed-out read may still carry the rows printed before the signal.
sub printers {
	my $lpstat = tool('lpstat');
	return ([], 0) unless defined $lpstat && length $lpstat;
	my ($out, $timed_out) = _run(_bounded(3, $lpstat, '-p', '-d', '-v', '-a'));
	return (parse_lpstat($out), $timed_out ? 0 : 1);
}

sub _uri_ok {
	my ($uri) = @_;
	return 0 unless defined $uri && length $uri;
	return $uri =~ m{^(?:ipp|ipps)://[A-Za-z0-9._:\-\[\]]+(?:/[^\s]*)?$} ? 1 : 0;
}

# Printers advertised on the network that CUPS does not know yet, as a sorted
# list of IPP URIs. ippfind is the fast walk when the machine has it, but it
# lives in cups-ipp-utils, which a desktop often does not install; `lpinfo -v`
# is the CUPS client's own enumeration and is there wherever lpstat is, so
# Find printers still finds a Wi-Fi printer without ippfind. Both walks are
# bounded. An empty list sends the caller to its own mDNS/sweep fallback.
sub discover {
	my @uris = _discover_ippfind();
	@uris = _discover_lpinfo() unless @uris;
	my %found;
	foreach my $line (@uris) {
		next unless _uri_ok($line);
		$found{$line} = 1;
	}
	return [ sort keys %found ];
}

sub _discover_ippfind {
	my $ippfind = tool('ippfind');
	return () unless defined $ippfind && length $ippfind;
	my ($out) = _run($ippfind, '-T', '5');
	return split /\n/, $out;
}

# `lpinfo -v` prints one "<class> <uri>" row per device, e.g.
#   network ipp://192.168.1.50:631/ipp/print
#   network dnssd://Officejet%20Pro._ipp._tcp.local/%3F...
# A dnssd URI is CUPS' own name rather than an ipp:// URI with a resolved
# host, so discover() keeps only the ipp/ipps rows (`_uri_ok`). A raw
# socket:// or lpd:// printer is left out for the same reason a raw mDNS
# service is: the Store sends PDFs, and -m everywhere needs IPP.
sub _discover_lpinfo {
	my $lpinfo = tool('lpinfo');
	return () unless defined $lpinfo && length $lpinfo;
	my ($out) = _run(_bounded(5, $lpinfo, '-v'));
	my @uris;
	foreach my $line (split /\n/, $out) {
		next unless $line =~ /^\s*(?:network|direct|file)\s+(\S+)\s*$/;
		push @uris, $1;
	}
	return @uris;
}

# Is something answering IPP on this host? A printer with Bonjour off is still
# in the neighbour table after a subnet sweep, and its IPP port is what tells
# it from the other appliances on the LAN. A plain TCP connect is enough for
# discovery: lpadmin -m everywhere is the real validation when the candidate
# is added, so a host that answers but refuses IPP lands in the caller's error
# list instead of becoming a queue. One second per host keeps a /24 with a few
# silent addresses from holding the press.
sub probe {
	my ($ip, $port) = @_;
	return 0 unless defined $ip && $ip =~ /^(?:\d{1,3}\.){3}\d{1,3}$/;
	$port = 631 unless defined $port && $port =~ /^\d+$/;
	require IO::Socket::INET;
	my $sock = IO::Socket::INET->new(
		PeerAddr => $ip,
		PeerPort => $port,
		Proto    => 'tcp',
		Timeout  => 1,
	);
	return 0 unless $sock;
	close $sock;
	return 1;
}

# What the printer's document feeder says right now. eSCL (the AirScan status
# endpoint every modern printer answers) reports ScannerAdfLoaded for a page
# waiting and ScannerAdfEmpty when the tray is clear; the older /Scan/Status
# path is tried when the eSCL one is silent. `unknown` covers a printer that is
# off, asleep, or raw-only, so a caller can stay quiet instead of guessing.
sub adf_state {
	my ($ip) = @_;
	return 'unknown' unless defined $ip && $ip =~ /^(?:\d{1,3}\.){3}\d{1,3}$/;
	my $curl = tool('curl');
	return 'unknown' unless defined $curl && length $curl;
	foreach my $path ('/eSCL/ScannerStatus', '/Scan/Status') {
		my ($out) = _run(_bounded(3, $curl, '-s', '--max-time', '3', 'http://' . $ip . $path));
		next unless defined $out && length $out;
		my ($state) = $out =~ m{<[^>]*AdfState[^>]*>\s*([^<\s]+)}s;
		next unless defined $state && length $state;
		return 'loaded' if $state eq 'ScannerAdfLoaded';
		return 'empty'  if $state eq 'ScannerAdfEmpty' || $state eq 'ScannerAdfNoDocument';
		return 'unknown';
	}
	return 'unknown';
}

# Add one queue with `lpadmin -m everywhere`, retried through `sudo -n` when
# the direct call fails (a house whose cupsd needs a privileged client).
# Answers the system() status, or undef when lpadmin is not installed.
sub add_queue {
	my ($name, $uri) = @_;
	my $lpadmin = tool('lpadmin');
	return undef unless defined $lpadmin && length $lpadmin;
	my @cmd = ($lpadmin, '-p', $name, '-E', '-v', $uri, '-m', 'everywhere', '-D', $name);
	my $rc = system(@cmd);
	$rc = system('sudo', '-n', @cmd) if $rc != 0;
	return $rc;
}

# Send a PDF to a queue with `lp -d`, retried through `sudo -n`. Answers the
# system() status, or undef when lp is not installed.
sub send {
	my ($name, $pdf_path) = @_;
	my $lp = tool('lp');
	return undef unless defined $lp && length $lp;
	my $rc = system($lp, '-d', $name, $pdf_path);
	$rc = system('sudo', '-n', $lp, '-d', $name, $pdf_path) if $rc != 0;
	return $rc;
}

# Turn HTML into a PDF with weasyprint under a 45-second bound. Answers
# ($pdf_path, undef) or (undef, $error); the caller removes the file.
sub pdf_from_html {
	my ($html) = @_;
	return (undef, 'no paper to print') unless defined $html && length $html;
	my $weasyprint = tool('weasyprint');
	return (undef, 'weasyprint is not installed') unless defined $weasyprint && length $weasyprint;
	my ($fh, $html_path) = File::Temp::tempfile('jawn_print_XXXXXX', SUFFIX => '.html', DIR => File::Spec->tmpdir, UNLINK => 0);
	return (undef, 'could not write the print file') unless $fh;
	print $fh $html;
	close $fh;
	(my $pdf_path = $html_path) =~ s/\.html$/.pdf/;
	my $timeout = tool('timeout');
	my $rc = (defined $timeout && length $timeout)
		? system($timeout, '45', $weasyprint, $html_path, $pdf_path)
		: system($weasyprint, $html_path, $pdf_path);
	unlink $html_path;
	return (undef, 'weasyprint failed') unless $rc == 0 && -s $pdf_path;
	return ($pdf_path, undef);
}

# What a printer says about its own consumables, read over IPP with ipptool
# under a six-second bound per resource path. Answers { markers => [...],
# state, reasons, make, ip } or { error => ... }; a printer that is off leaves
# its row saying why. ipp/print is the resource path almost every printer
# advertises; ipp/printer covers one that names it differently.
sub ink {
	my ($ip) = @_;
	return { error => 'no address' } unless $ip && $ip =~ /^\d{1,3}(\.\d{1,3}){3}$/;
	my $ipptool = tool('ipptool', qw(/usr/bin /usr/local/bin /bin));
	return { error => 'ipptool not installed' } unless defined $ipptool && length $ipptool;
	# ask only for what an ink readout needs, so a chatty printer's reply stays small
	my $test = <<'IPP';
{
	OPERATION get-printer-attributes
	VERSION 2.0
	GROUP operation
	ATTR charset attributes-charset utf-8
	ATTR language attributes-natural-language en
	ATTR uri printer-uri $uri
	ATTR keyword requested-attributes printer-make-and-model,printer-state,printer-state-reasons,marker-names,marker-colors,marker-types,marker-levels
	STATUS successful-ok
	DISPLAY printer-make-and-model
	DISPLAY printer-state
	DISPLAY printer-state-reasons
	DISPLAY marker-names
	DISPLAY marker-colors
	DISPLAY marker-types
	DISPLAY marker-levels
}
IPP
	my ($fh, $path) = File::Temp::tempfile('jawn_ipp_XXXXXX', SUFFIX => '.test', DIR => File::Spec->tmpdir, UNLINK => 1);
	print $fh $test;
	close $fh;
	my (%attr, $answered);
	foreach my $rp ('ipp/print', 'ipp/printer') {
		my ($out) = _run(_bounded(6, $ipptool, '-tv', "ipp://$ip:631/$rp", $path));
		foreach my $line (split /\n/, $out) {
			next unless $line =~ /^\s*([a-z0-9-]+)\s*(?:\([^)]*\))?\s*=\s*(.*)$/;
			$attr{$1} = $2;
		}
		$answered = 1 if %attr;
		last if $attr{'marker-levels'} || $attr{'printer-make-and-model'};
	}
	return { error => 'no answer from the printer' } unless $answered;
	# each attribute is a 1setOf, printed comma-separated and parallel across the
	# lists, so index i is the same cartridge in every one
	my @names  = split /\s*,\s*/, ($attr{'marker-names'}  || '');
	my @colors = split /\s*,\s*/, ($attr{'marker-colors'} || '');
	my @types  = split /\s*,\s*/, ($attr{'marker-types'}  || '');
	my @levels = split /\s*,\s*/, ($attr{'marker-levels'} || '');
	my @markers;
	foreach my $i (0 .. $#levels) {
		my $level = $levels[$i];
		next unless defined $level && $level =~ /^-?\d+$/;
		# marker-levels is already a percentage of capacity; a negative value is
		# the printer saying it does not know, so leave the percentage out and let
		# the row show a question mark instead of a wrong number
		my $pct;
		if ($level >= 0) {
			$pct = $level + 0;
			$pct = 100 if $pct > 100;
		}
		push @markers, {
			name    => ($names[$i] || ('marker ' . ($i + 1))),
			type    => $types[$i],
			# marker-colors is #rrggbb (or several, run together, for a
			# tri-colour cartridge): keep each as its own swatch
			colors  => [ map { '#' . $_ } grep { length } split /#/, ($colors[$i] || '') ],
			level   => $level + 0,
			percent => $pct,
		};
	}
	my @reasons = grep { $_ ne 'none' } split /\s*,\s*/, ($attr{'printer-state-reasons'} || '');
	return {
		ip      => $ip,
		make    => $attr{'printer-make-and-model'},
		state   => $attr{'printer-state'},
		reasons => \@reasons,
		markers => \@markers,
	};
}

# The scanimage argv for a feeder. Flatbed writes one page to $file.tiff; ADF
# writes numbered pages to $file_%d.tiff. An unknown feeder answers [] so the
# caller can refuse it. The caller supplies the device URI and resolution.
sub scan_argv {
	my ($feed, $file, $dev, $res) = @_;
	return [] unless defined $file && length $file;
	$feed = lc(defined $feed ? $feed : '');
	my @common = ('scanimage', '--format', 'tiff');
	if ($feed eq 'flatbed') {
		return [ @common, '--source', 'Flatbed', '--batch', "$file.tiff",
			'--mode', 'Color', '-d', $dev, '--resolution=' . (defined $res ? $res : ''), '--progress' ];
	}
	if ($feed eq 'adf') {
		return [ @common, '--source', 'ADF', '--batch', $file . '_%d.tiff',
			'--mode', 'Color', '-d', $dev, '--resolution=' . (defined $res ? $res : ''), '--progress' ];
	}
	return [];
}

1;
