package subs;

# Printer2: the CUPS side of printing. The Printer module reads a printer's
# ink and discovers it on the network; this module turns a queue into a real
# print, discovers a printer that is not queued yet, and remembers which queue
# this machine should use by default.
#
# Manjaro no longer packages cups-browsed, so discovery is ippfind (or the
# mDNS records Printer::mdns_printers already reads) and the queue is added
# with `lpadmin -m everywhere`. Printing is `lp`; the PDF is made with the
# same weasyprint the mail attachment uses.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use File::Spec;
use File::Temp ();

our $device;
our $log;

# ---- locating a command -----------------------------------------------------
# The manager's PATH is not the login shell's, so try the usual homes too. The
# name is a fixed identifier, never caller text.
sub printer_command_path($name) {
	return '' unless defined $name && $name =~ /^[A-Za-z0-9_.\-]+$/;
	my $found = `command -v $name 2>/dev/null`;
	chomp $found;
	return $found if length $found && -x $found;
	foreach my $dir (qw(/usr/bin /usr/local/bin /bin /usr/sbin /sbin)) {
		my $path = "$dir/$name";
		return $path if -x $path;
	}
	return '';
}

sub printer_queue_clean($name) {
	$name = '' unless defined $name;
	$name =~ s/[^A-Za-z0-9_.-]+/-/g;
	$name =~ s/^-+//;
	$name =~ s/-+$//;
	$name = lc $name;
	$name = 'printer' unless length $name;
	return substr($name, 0, 60);
}

sub printer_uri_ok($uri) {
	return 0 unless defined $uri && length $uri;
	return $uri =~ m{^(?:ipp|ipps)://[A-Za-z0-9._:\-\[\]]+(?:/[^\s]*)?$} ? 1 : 0;
}

# ---- the queues this machine already has ------------------------------------
# Bound the read: lpstat talks to cupsd, and a CUPS server that is down (or a
# stale client.conf pointing at a host nobody answers for) waits out its own
# connect timeout - with no bound it held the whole Dev panel behind it. A
# listing that cannot be read in three seconds is drawn as no queues, which is
# what a person sees anyway when CUPS is not answering.
#
# Keep the answer for a while as well. CUPS builds the printer list through
# cupsd, and on a machine with a network queue that is slow even when it works: a
# laptop whose printer is on Wi-Fi took ~1s for every lpstat option and ~2s for
# the whole read, and the Dev panel draws whenever it is opened. Queues change
# only when someone adds or removes one, and Find printers clears this.
our $cups_printers_memo;
our $cups_printers_memo_ttl = 300;
sub cups_printers {
	my $now = time;
	if ($cups_printers_memo && $now - $cups_printers_memo->{'at'} < $cups_printers_memo_ttl) {
		return [ map { { %{$_} } } @{$cups_printers_memo->{'list'}} ];
	}
	my $lpstat = &printer_command_path('lpstat');
	return [] unless length $lpstat;
	my $out = `timeout 3 $lpstat -p -d -v -a 2>/dev/null`;
	my $timed_out = (($? >> 8) == 124) ? 1 : 0;
	my (%printer, $default);
	foreach my $line (split /\n/, $out) {
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
	# A timed-out read is not evidence that the machine has no queues: leave it
	# uncached so the next draw tries again rather than showing an empty card for
	# five minutes.
	$cups_printers_memo = { at => $now, list => [ map { { %{$_} } } @list ] } unless $timed_out;
	return \@list;
}

# ---- printers on the network that CUPS does not know yet --------------------
sub cups_discovered_printers {
	my %found;
	my $ippfind = &printer_command_path('ippfind');
	if (length $ippfind) {
		my $out = `$ippfind -T 5 2>/dev/null`;
		foreach my $line (split /\n/, $out) {
			next unless &printer_uri_ok($line);
			$found{$line} = { uri => $line, host => $line, name => $line };
		}
	}
	if (!scalar keys %found) {
		my $mdns = eval { &mdns_printers() } || {};
		foreach my $ip (keys %{ $mdns->{'by_ip'} || {} }) {
			my $r = $mdns->{'by_ip'}->{$ip} || {};
			my $port = $r->{'port'} || 631;
			my $rp = ($r->{'fields'} && $r->{'fields'}->{'rp'}) ? $r->{'fields'}->{'rp'} : 'ipp/print';
			$rp =~ s{^/+}{};
			$rp = '' unless $rp =~ /^[A-Za-z0-9._\-\/]+$/;
			my $uri = 'ipp://' . $ip . ':' . $port . ($rp ne '' ? '/' . $rp : '');
			next unless &printer_uri_ok($uri);
			$found{$uri} = {
				uri => $uri,
				host => $ip,
				name => $r->{'name'} || $r->{'hostname'} || $ip,
			};
		}
	}
	my %queued = map { ($_->{'uri'} || '') => 1 } @{ &cups_printers() };
	my @out = grep { !$queued{$_->{'uri'}} } values %found;
	return [ sort { $a->{'uri'} cmp $b->{'uri'} } @out ];
}

# ---- add the discovered printers as queues ---------------------------------
sub cups_sync_printers {
	my $lpadmin = &printer_command_path('lpadmin');
	return { ok => 0, error => 'lpadmin is not installed' } unless length $lpadmin;
	my $known = &cups_printers();
	my %known_uri = map { ($_->{'uri'} || '') => 1 } @{$known};
	my %taken = map { $_->{'name'} => 1 } @{$known};
	my (@added, @errors);
	foreach my $d (@{ &cups_discovered_printers() }) {
		next if $known_uri{$d->{'uri'}};
		my $name = &printer_queue_clean($d->{'name'} || $d->{'host'} || 'printer');
		my $base = $name;
		my $n = 2;
		while ($taken{$name}) { $name = $base . '-' . $n++; }
		my @cmd = ($lpadmin, '-p', $name, '-E', '-v', $d->{'uri'}, '-m', 'everywhere', '-D', $name);
		my $rc = system(@cmd);
		$rc = system('sudo', '-n', @cmd) if $rc != 0;
		if ($rc == 0) {
			push @added, { name => $name, uri => $d->{'uri'} };
			$known_uri{$d->{'uri'}} = 1;
			$taken{$name} = 1;
		}
		else {
			push @errors, { name => $name, uri => $d->{'uri'}, error => 'lpadmin failed' };
		}
	}
	$cups_printers_memo = undef if @added;
	return { ok => 1, added => \@added, errors => \@errors, printers => &cups_printers() };
}

# ---- the default queue on this machine -------------------------------------
# The customer a receipt belongs to. The register's print button may know only
# the sale's uuid; this is the same fallback /manager/store/register/receipt uses.
sub printer_customer_app($uuid, $type) {
	return '' unless defined $uuid && length $uuid;
	my $row = &db_select('appointments', undef, { uuid => $uuid, type => $type })->hashes->[0];
	return $row ? ($row->{'app'} || '') : '';
}

sub printer_default_saved {
	# The saved queue name without asking CUPS whether it still exists. The Dev
	# panel draws its card with this at once; the queue list arrives after, and
	# the async list is what validates the choice. A settings read is cheap; the
	# lpstat behind the list is not.
	my $sig = &signatorial_designer();
	my $value = eval { &setting_grabber({ app => 'misc', setting => 'default_printer', device => $sig }) };
	$value = eval { &setting_grabber({ app => 'misc', setting => 'default_printer', device => &device_setter() }) }
		if !defined $value || !length $value;
	return defined $value ? $value : '';
}

sub printer_default_get {
	# The Dev panel already read the queues for this draw; take that list rather
	# than asking lpstat a second time for the same answer.
	my ($queues) = @_;
	$queues = &cups_printers() unless ref $queues eq 'ARRAY';
	my $value = &printer_default_saved();
	my @known = map { $_->{'name'} } @{$queues};
	$value = '' if length $value && !grep { $_ eq $value } @known;
	return $value;
}

sub printer_default_set($name) {
	$name = '' unless defined $name;
	if (length $name) {
		my @known = map { $_->{'name'} } @{ &cups_printers() };
		return { ok => 0, error => 'that printer is not a CUPS queue' } unless grep { $_ eq $name } @known;
	}
	&setting_setter({
		app => 'misc',
		setting => 'default_printer',
		value => $name,
		device => &signatorial_designer(),
		timestamp => &rightNow(),
	});
	return { ok => 1, default => $name };
}

# ---- paper ----------------------------------------------------------------
sub printer_pdf_from_html($html) {
	return (undef, 'no paper to print') unless defined $html && length $html;
	my $weasyprint = &printer_command_path('weasyprint');
	return (undef, 'weasyprint is not installed') unless length $weasyprint;
	my ($fh, $html_path) = File::Temp::tempfile('jawn_print_XXXXXX', SUFFIX => '.html', DIR => File::Spec->tmpdir, UNLINK => 0);
	return (undef, 'could not write the print file') unless $fh;
	print $fh $html;
	close $fh;
	(my $pdf_path = $html_path) =~ s/\.html$/.pdf/;
	my $timeout = &printer_command_path('timeout');
	my $rc = length $timeout
		? system($timeout, '45', $weasyprint, $html_path, $pdf_path)
		: system($weasyprint, $html_path, $pdf_path);
	unlink $html_path;
	return (undef, 'weasyprint failed') unless $rc == 0 && -s $pdf_path;
	return ($pdf_path, undef);
}

sub printer_cups_send($name, $pdf_path) {
	return { ok => 0, error => 'no printer' } unless defined $name && length $name;
	my @known = map { $_->{'name'} } @{ &cups_printers() };
	return { ok => 0, error => 'that printer is not a CUPS queue' } unless grep { $_ eq $name } @known;
	my $lp = &printer_command_path('lp');
	return { ok => 0, error => 'lp is not installed' } unless length $lp;
	my $rc = system($lp, '-d', $name, $pdf_path);
	$rc = system('sudo', '-n', $lp, '-d', $name, $pdf_path) if $rc != 0;
	return $rc == 0
		? { ok => 1, printer => $name }
		: { ok => 0, error => 'lp failed for ' . $name };
}

1;
