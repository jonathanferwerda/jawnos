package subs;

# Printer2: the CUPS side of printing. The Printer module reads a printer's
# ink and discovers it on the network; this module turns a queue into a real
# print, discovers a printer that is not queued yet, and remembers which queue
# this machine should use by default.
#
# The commands and their parsing live in JawnOS::Platform::Print now: lpstat,
# lpadmin, lp, weasyprint and ippfind keep the same argv, bounds and `sudo -n`
# retry there, so Linux prints exactly as it did. This module keeps the house's
# policy - the queue list memo, the mDNS fallback, the saved default - and the
# JSON shapes its routes answer.
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
use JawnOS::Platform::Print ();

our $device;
our $log;

# ---- locating a command -----------------------------------------------------
# Kept for the Loader map and any caller that still asks by name; the seam
# owns the path. The name is a fixed identifier, never caller text.
sub printer_command_path($name) {
	return '' unless defined $name && $name =~ /^[A-Za-z0-9_.\-]+$/;
	my $path = JawnOS::Platform::Print::tool($name);
	return (defined $path && length $path) ? $path : '';
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
# CUPS builds the printer list through cupsd, and on a machine with a network
# queue that is slow even when it works: a laptop whose printer is on Wi-Fi
# took ~1s for every lpstat option and ~2s for the whole read, and the Dev
# panel draws whenever it is opened. Queues change only when someone adds or
# removes one, and Find printers clears this.
#
# A read that timed out is not evidence that the machine has no queues: it is
# left uncached so the next draw tries again rather than showing an empty card
# for five minutes.
our $cups_printers_memo;
our $cups_printers_memo_ttl = 300;
sub cups_printers {
	my $now = time;
	if ($cups_printers_memo && $now - $cups_printers_memo->{'at'} < $cups_printers_memo_ttl) {
		return [ map { { %{$_} } } @{$cups_printers_memo->{'list'}} ];
	}
	my ($list, $complete) = JawnOS::Platform::Print::printers();
	$list ||= [];
	$cups_printers_memo = { at => $now, list => [ map { { %{$_} } } @{$list} ] } if $complete;
	return [ map { { %{$_} } } @{$list} ];
}

# ---- printers on the network that CUPS does not know yet --------------------
# $deep is the person's own press: it may browse mDNS even when ippfind
# answered, and when nothing advertises at all it sweeps this machine's
# subnets. The cheap calls (the Store card, the Dev fill) pass nothing and stay
# on the stored queues plus ippfind.
sub cups_discovered_printers($deep = 0) {
	my %found;
	foreach my $uri (@{ JawnOS::Platform::Print::discover() }) {
		$found{$uri} = { uri => $uri, host => $uri, name => $uri };
	}
	# mDNS names a printer without CUPS or ippfind being installed, and it is
	# the only source that knows the printer's own name. A plain fill asks it
	# only when ippfind found nothing, so the Store page does not pay for the
	# browse; the explicit press always asks.
	if ($deep || !scalar keys %found) {
		my $mdns = eval { &mdns_printers() } || {};
		foreach my $ip (keys %{ $mdns->{'by_ip'} || {} }) {
			my $r = $mdns->{'by_ip'}->{$ip} || {};
			my $uri = &printer_mdns_uri($r);
			next unless $uri && &printer_uri_ok($uri) && !$found{$uri};
			$found{$uri} = {
				uri => $uri,
				host => $ip,
				name => $r->{'name'} || $r->{'hostname'} || $ip,
			};
		}
	}
	# Nothing advertised: a printer with Bonjour off is still on the wireless,
	# so an explicit Find printers sweeps the house's own subnets and asks each
	# live host for IPP. Only that press pays for it.
	if ($deep && !scalar keys %found) {
		foreach my $uri (@{ &printer_subnet_candidates() }) {
			next if $found{$uri};
			$found{$uri} = { uri => $uri, host => $uri, name => $uri };
		}
	}
	# One row per printer: ippfind and mDNS, or _ipp and _ipps, can name the
	# same host twice, and two queues for one printer is not a choice a person
	# wants to make. The plain ipp:// URI sorts before ipps://, so it wins.
	my %by_host;
	foreach my $uri (sort keys %found) {
		my ($host) = $uri =~ m{^ipps?://(\[[^\]]+\]|[^/:]+)}i;
		next unless defined $host && length $host;
		$by_host{lc $host} ||= $uri;
	}
	my %queued = map { ($_->{'uri'} || '') => 1 } @{ &cups_printers() };
	my @out = grep { !$queued{$_->{'uri'}} } map { $found{$_} } values %by_host;
	return [ sort { $a->{'uri'} cmp $b->{'uri'} } @out ];
}

# The IPP URI a printer advertises, from its mDNS record. _ipp._tcp is plain
# IPP and _ipps._tcp is IPP over TLS; both carry the resource path in the `rp`
# TXT field (ipp/print when the printer does not say). The raw services
# (_printer._tcp, _pdl-datastream._tcp) are printers the Store cannot send a
# PDF to without a driver, so they stay in the Devices list and out of the
# queue list.
sub printer_mdns_uri($r) {
	return '' unless ref $r eq 'HASH';
	my $service = $r->{'service'} || '_ipp._tcp';
	return '' unless $service eq '_ipp._tcp' || $service eq '_ipps._tcp';
	my $ip = $r->{'ip'} || '';
	return '' unless $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	my $port = $r->{'port'} || 631;
	return '' unless $port =~ /^\d+$/;
	my $rp = ($r->{'fields'} && $r->{'fields'}->{'rp'}) ? $r->{'fields'}->{'rp'} : 'ipp/print';
	$rp =~ s{^/+}{};
	$rp = '' unless $rp =~ m{^[A-Za-z0-9._\-/]+$};
	my $scheme = $service eq '_ipps._tcp' ? 'ipps' : 'ipp';
	return $scheme . '://' . $ip . ':' . $port . ($rp ne '' ? '/' . $rp : '');
}

# Live hosts on this machine's own subnets that answer IPP on 631, as ipp://
# URIs. A sweep puts the printer in the neighbour table even when it advertises
# nothing; the port probe then says which row is the printer. Only private NICs
# with a real LAN mask are swept, so a tailnet (/32) or a container network
# never turns Find printers into a wide scan. The sweep itself is bounded by
# subnet_sweep, and the press is the only caller.
sub printer_subnet_candidates() {
	require JawnOS::Platform::Net;
	my $address = &network_interface_reporter();
	return [] unless ref $address eq 'HASH' && %{$address};
	my (%seen, @out);
	foreach my $nic (sort keys %{$address}) {
		my $entry = $address->{$nic} || {};
		my $ip = $entry->{'ip'} || '';
		my $netmask = $entry->{'netmask'} || '';
		next unless $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
		next if $ip =~ /^127\./;
		next unless &ip_is_private($ip);
		# A point-to-point tunnel reports 255.255.255.255 (or /31); a real
		# house LAN has a multi-address mask.
		next unless $netmask =~ /^255\.\d{1,3}\.\d{1,3}\.\d{1,3}$/;
		next if $netmask eq '255.255.255.255' || $netmask eq '255.255.255.254';
		&subnet_sweep($nic, $ip, $netmask);
		foreach my $line (@{ JawnOS::Platform::Net::neighbour_lines($nic) }) {
			next if $line =~ /\b(?:FAILED|INCOMPLETE|PROBE)\b/;
			my ($host) = split /\s+/, $line;
			next unless defined $host && $host =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
			next if $host eq $ip || $host =~ /^127\./;
			next if $seen{$host}++;
			next unless JawnOS::Platform::Print::probe($host, 631);
			push @out, 'ipp://' . $host . ':631/ipp/print';
		}
	}
	return [ sort @out ];
}

# ---- add the discovered printers as queues ---------------------------------
sub cups_sync_printers {
	my $lpadmin = JawnOS::Platform::Print::tool('lpadmin');
	return { ok => 0, error => 'lpadmin is not installed' } unless defined $lpadmin && length $lpadmin;
	my $known = &cups_printers();
	my %known_uri = map { ($_->{'uri'} || '') => 1 } @{$known};
	my %taken = map { $_->{'name'} => 1 } @{$known};
	my (@added, @errors);
	foreach my $d (@{ &cups_discovered_printers(1) }) {
		next if $known_uri{$d->{'uri'}};
		my $name = &printer_queue_clean($d->{'name'} || $d->{'host'} || 'printer');
		my $base = $name;
		my $n = 2;
		while ($taken{$name}) { $name = $base . '-' . $n++; }
		my $rc = JawnOS::Platform::Print::add_queue($name, $d->{'uri'});
		if (defined $rc && $rc == 0) {
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
	return JawnOS::Platform::Print::pdf_from_html($html);
}

sub printer_cups_send($name, $pdf_path) {
	return { ok => 0, error => 'no printer' } unless defined $name && length $name;
	my @known = map { $_->{'name'} } @{ &cups_printers() };
	return { ok => 0, error => 'that printer is not a CUPS queue' } unless grep { $_ eq $name } @known;
	my $rc = JawnOS::Platform::Print::send($name, $pdf_path);
	return { ok => 0, error => 'lp is not installed' } unless defined $rc;
	return $rc == 0
		? { ok => 1, printer => $name }
		: { ok => 0, error => 'lp failed for ' . $name };
}

1;
