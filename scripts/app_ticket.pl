#!/usr/bin/perl
# The apps' forever ticket. Minted once per client (desktop, phone, tablet, ...)
# on a machine that holds the house: the printed URL logs that client in, and
# with the "forever" warranty the ticket never expires. The desktop installer
# stores it for the embedded view; the phone and tablet open it once, which is
# what puts the session on the fqdn origin their installed PWA (service worker,
# full screen) lives on. The URL's host is config.json's domain, which the
# house's DNS points at this machine itself - 127.0.0.1 in the laptop's hosts
# file, its own LAN address from the router, its own tailnet address from
# Headscale - so the link carries the wildcard certificate while reaching this
# machine without a VPN. 127.0.0.1 is the fallback when there is no domain.
#
# Idempotent: an active forever ticket for the same client is reused, never
# re-minted (the URL is rebuilt from the row, so a host change is picked up).
# --rotate mints a fresh one, retires the old, and refreshes .shots/ticket.txt
# (0600) when that file names the same client: leaving a retired URL there is
# what makes the desktop's embedded view meet the denial page on its next
# launch, while a phone's rotation must not edit the desktop's fallback.
# --save writes the file regardless, and covers a reused ticket. It is the file
# the desktop's view already reads as its fallback, and an app on this device
# (the Android fork's dashboard) can open the ticket from there without running
# anything.
#
#   perl scripts/app_ticket.pl desktop          # print the URL (mint if needed)
#   perl scripts/app_ticket.pl phone --rotate   # mint a fresh one anyway
#   perl scripts/app_ticket.pl phone --save     # and leave it in .shots/ticket.txt
use strict;
use warnings;

use FindBin qw($RealBin);
chdir "$RealBin/.." or die "no jawnos dir at $RealBin/..\n";

$ENV{PURPOSE} = '';
eval { require './perl/Manager.pl'; 1 } or die "app_ticket: no house here (config.json?)\n";

my $client = shift @ARGV // '';
$client =~ s/[^A-Za-z0-9_-]//g;
die "usage: app_ticket.pl <client> [--rotate] [--save]\n" unless $client;
my $rotate = grep { $_ eq '--rotate' } @ARGV;
my $save = grep { $_ eq '--save' } @ARGV;

my $config = eval { &subs::config_reader() } || {};
my $domain = $config->{'domain'} || '';
my $host = $domain || '127.0.0.1';
# the live workers get these from the master; a bare script must name them
$ENV{PORT_DOCK} = $ENV{PORT_DOCK} || $config->{'port'} || 3000;
$ENV{PORT_AHOY} = $ENV{PORT_AHOY} || $config->{'working_port'} || 45545;

# The fallback file the desktop reads. A rotation only refreshes it when it
# holds a ticket of the same client; rotating the phone must not put the
# phone's ticket where the desktop looks.
sub fallback_uuid {
	my $path = '.shots/ticket.txt';
	return '' unless -f $path;
	my $body = '';
	if (open(my $fh, '<', $path)) { local $/; $body = <$fh> // ''; close $fh; }
	return $1 if $body =~ m{/box_office/([A-Za-z0-9]+)};
	return '';
}

my $fallback_uuid = &fallback_uuid();
my $fallback_client = '';
if ($fallback_uuid ne '') {
	my $fallback_row = &subs::db_select('tickets', ['name'], { uuid => $fallback_uuid })->hashes->[0];
	$fallback_client = $fallback_row ? ($fallback_row->{'name'} // '') : '';
}

my $row = &subs::db_select('tickets', undef, { project => 'app-ticket', name => $client, status => 'active' })->hashes->[0];
my $url;
my $minted = 0;
if ($row && !$rotate && ($row->{'warranty'} || 0) == &subs::forever_warranty() && $row->{'secret'}) {
	# the URL is rebuilt, not read back: the host is whatever this machine is
	# called today, and only uuid and secret tie the link to the row
	$url = 'https://' . $host . ':' . $ENV{PORT_DOCK} . '/box_office/' . $row->{'uuid'} . '?s=' . $row->{'secret'};
}
else {
	my $data = &Manager::qrcode_generator({
		timestamp => &subs::rightNow(),
		app => 'box_office',
		name => $client,
		privilege => 'citizen',
		project => 'app-ticket',
		# nic names the host when it is the configured domain; without a domain
		# the mint falls back to 127.0.0.1 for this house's own view
		nic => ($domain || undef),
		db => ($domain ? 0 : 1),
		warranty => 'forever',
		keep_warranty => 1,
	});
	&subs::db_insert('tickets', $data);
	$url = $data->{'url'};
	$minted = 1;
	if ($row) {
		&subs::db_update('tickets', { status => 'rotated' }, { uuid => $row->{'uuid'} });
	}
}
print $url, "\n";

# A rotation refreshes the fallback only when that file names the same client;
# --save still covers a reused ticket and writes it unconditionally.
my $write = $save || ($rotate && $minted && $fallback_client ne '' && lc($fallback_client) eq lc($client));
if ($write) {
	mkdir '.shots' unless -d '.shots';
	my $path = '.shots/ticket.txt';
	if (open(my $fh, '>', $path)) {
		chmod 0600, $path;
		print $fh $url, "\n";
		close $fh;
		print STDERR "saved $path\n";
	}
	else {
		print STDERR "could not write $path: $!\n";
	}
}
