#!/usr/bin/perl
# The apps' forever ticket. Minted once per client (desktop, phone, tablet, ...)
# on a machine that holds the house: the printed URL logs that client in, and
# with the "forever" warranty the ticket never expires. The desktop installer
# stores it for the embedded view; the phone and tablet open it once, which is
# what puts the session on the fqdn origin their installed PWA (service worker,
# full screen) lives on. The URL's host is config.json's domain when set, else
# 127.0.0.1 - the desktop view trusts the house's certificate there.
#
# Idempotent: an active forever ticket for the same client is reused, never
# re-minted (the URL is rebuilt from the row, so a host change is picked up).
# --rotate mints a fresh one and retires the old. --save writes the URL to
# .shots/ticket.txt (0600) as well: that is the file the desktop's embedded
# view already reads as its fallback, and an app on this device (the Android
# fork's dashboard) can open the ticket from there without running anything.
#
#   perl scripts/app_ticket.pl desktop          # print the URL (mint if needed)
#   perl scripts/app_ticket.pl phone --rotate   # mint a fresh one anyway
#   perl scripts/app_ticket.pl phone --save     # and leave it in .shots/ticket.txt
use strict;
use warnings;

use FindBin qw($RealBin);
chdir "$RealBin/.." or die "no jawnos dir at $RealBin/..\n";

$ENV{PURPOSE} = '';
eval { require './Manager.pl'; 1 } or die "app_ticket: no house here (config.json?)\n";

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

my $row = &subs::db_select('tickets', undef, { project => 'app-ticket', name => $client, status => 'active' })->hashes->[0];
my $url;
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
	if ($row) {
		&subs::db_update('tickets', { status => 'rotated' }, { uuid => $row->{'uuid'} });
	}
}
print $url, "\n";

if ($save) {
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
