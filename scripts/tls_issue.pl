#!/usr/bin/env perl
# tls_issue.pl - obtain or renew the house certificate through DNS-01.
#
#   perl scripts/tls_issue.pl            # issue, or renew if due
#   perl scripts/tls_issue.pl --renew    # the timer's run (same thing, quieter)
#   perl scripts/tls_issue.pl --domain example.com --email me@example.com
#   perl scripts/tls_issue.pl --client <uuid>    # pick a DNS entry explicitly
#   perl scripts/tls_issue.pl hook auth|cleanup # certbot's manual hook (internal)
#
# Why DNS-01: a wildcard certificate can only be validated that way, and the
# challenge is a TXT record rather than an inbound connection, so a machine
# behind NAT can renew. certbot owns the ACME exchange; this script only writes
# and removes the record, through the provider configured under
# Configure -> Plat -> DNS, and installs the result where jawn can read it.
#
# No root is needed: certbot keeps its account, certs and logs under
# ~/.jawnos_tls, and the copy into server/ is owned by the same user.
#
# The certificate goes to server/fullchain.pem and server/privkey.pem, the two
# paths President.pl already passes to every listener. A changed certificate
# asks for a restart, which is what makes the new one live.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use Fcntl qw(:flock);
use POSIX qw(strftime);

my $root = abs_path("$FindBin::Bin/..");
chdir $root or die "cannot find the jawnos root: $!\n";
require './subroutines.pl';
require './tls.pl';

$| = 1;

my $self = abs_path($0);
my $base = ($ENV{'HOME'} || '.') . '/.jawnos_tls';
my $certbot = 'certbot';

sub say_status {
	my ($ok, $message) = @_;
	&tls::tls_status_write({
		at      => strftime('%Y-%m-%d %H:%M', localtime),
		ok      => ($ok ? 1 : 0),
		message => $message,
	});
	print(($ok ? 'ok: ' : 'failed: ') . $message . "\n");
}

# ---- certbot's manual hook -------------------------------------------------
# CERTBOT_DOMAIN is the base name even for a wildcard, so the record is the same
# _acme-challenge.<domain> for the apex and for *.
if (($ARGV[0] || '') eq 'hook') {
	my $action = $ARGV[1] || 'auth';
	my $domain = $ENV{'CERTBOT_DOMAIN'} || '';
	my $value = $ENV{'CERTBOT_VALIDATION'} || '';
	if (!length $domain || !length $value) {
		print STDERR "tls hook: CERTBOT_DOMAIN/CERTBOT_VALIDATION missing\n";
		exit 1;
	}
	my $client = &tls::dns_client_for($domain);
	if (!$client) {
		print STDERR "tls hook: no DNS credential covers $domain\n";
		exit 1;
	}
	my ($ok, $message) = &tls::dns_write($client, $domain, $value, ($action eq 'cleanup' ? 1 : 0));
	if (!$ok) {
		print STDERR "tls hook: $message\n";
		exit 1;
	}
	print "tls hook: $action " . &tls::dns_record_name($domain) . ($message ? " ($message)" : '') . "\n";
	if ($action ne 'cleanup') {
		# The record has to be visible before the CA looks. A per-client hint is
		# allowed because a slow provider (GoDaddy especially) is the usual cause
		# of a validation failure.
		my $wait = $client->{'wait'} || 15;
		$wait = 15 unless $wait =~ /^[0-9]{1,3}$/;
		sleep $wait;
	}
	exit 0;
}

# ---- the issuer ------------------------------------------------------------
my $domain = '';
my $email = '';
my $client_uuid = '';
my $manual_ok = 0;
for (my $i = 0; $i < @ARGV; $i++) {
	$domain = $ARGV[$i + 1] if $ARGV[$i] eq '--domain' && defined $ARGV[$i + 1];
	$email = $ARGV[$i + 1] if $ARGV[$i] eq '--email' && defined $ARGV[$i + 1];
	$client_uuid = $ARGV[$i + 1] if $ARGV[$i] eq '--client' && defined $ARGV[$i + 1];
	$manual_ok = 1 if $ARGV[$i] eq '--manual';
}

my $config = eval { &subs::config_reader() } || {};
$config = {} unless ref $config eq 'HASH';
$domain = $config->{'domain'} || '' unless length $domain;
$email = $config->{'email'} || '' unless length $email;

if (!length $domain || $domain =~ /^(?:127\.|localhost$|\[|::)/i) {
	&say_status(0, 'config.json has no real domain (it reads "' . ($domain || '') . '")');
	exit 1;
}
if (!length $email || $email !~ /\@/) {
	&say_status(0, 'config.json has no email for the Let\'s Encrypt account');
	exit 1;
}

my $client = &tls::dns_client_for($domain, $client_uuid);
if (!$client) {
	&say_status(0, 'no DNS credential covers ' . $domain . ' - add one under Configure -> Plat -> DNS');
	exit 1;
}
if (($client->{'provider'} || '') eq 'manual' && !$manual_ok) {
	&say_status(0, 'the ' . $domain . ' credential is manual: run with --manual in a terminal to add the record by hand');
	exit 1;
}

# One run at a time: two certbots writing the same record would fight.
make_path($base);
open my $lock, '>', "$base/lock" or die "cannot open the lock: $!\n";
flock($lock, LOCK_EX | LOCK_NB) or do {
	&say_status(0, 'another issue run is already in progress');
	exit 1;
};

make_path("$base/certbot", "$base/work", "$base/log");
&say_status(0, 'issuing for ' . $domain . ' via ' . ($client->{'provider'} || '?'));

my @cmd = (
	$certbot, 'certonly',
	'--config-dir', "$base/certbot",
	'--work-dir',   "$base/work",
	'--logs-dir',   "$base/log",
	'--cert-name',  'jawnos',
	'-d', $domain,
	'-d', '*.' . $domain,
	'--email', $email,
	'--agree-tos',
	'--non-interactive',
	'--keep-until-expiring',
);

if (($client->{'provider'} || '') eq 'manual') {
	# certbot prompts for the record itself; this path is for a person at a
	# terminal, never for the timer.
	push @cmd, '--manual', '--preferred-challenges', 'dns';
}
else {
	my $hook = "'$^X' '$self' hook";
	push @cmd,
		'--manual',
		'--preferred-challenges', 'dns',
		'--manual-auth-hook', $hook . ' auth',
		'--manual-cleanup-hook', $hook . ' cleanup';
}

my $rc = system(@cmd);
if ($rc != 0) {
	&say_status(0, 'certbot failed (exit ' . ($rc >> 8) . '); see ' . $base . '/log/letsencrypt.log');
	exit 1;
}

# Install the pair where jawn reads it. Copy rather than link: the live/
# symlinks point into an archive that a future renewal will rotate.
my $live = "$base/certbot/live/jawnos";
my $full = "$live/fullchain.pem";
my $priv = "$live/privkey.pem";
if (!-e $full || !-e $priv) {
	&say_status(0, 'certbot finished but ' . $full . ' is missing');
	exit 1;
}

make_path('server');
my $before = '';
if (-e 'server/fullchain.pem') {
	open my $bf, '<', 'server/fullchain.pem';
	local $/;
	$before = <$bf> // '';
	close $bf;
}
copy($full, 'server/fullchain.pem') or do { &say_status(0, "cannot copy fullchain: $!"); exit 1; };
copy($priv, 'server/privkey.pem')  or do { &say_status(0, "cannot copy privkey: $!"); exit 1; };
chmod 0600, 'server/fullchain.pem', 'server/privkey.pem';

# A mismatched pair would take every listener down on the next start, so check
# before asking for the restart.
my $pub_cert = `openssl x509 -in server/fullchain.pem -noout -pubkey 2>/dev/null`;
my $pub_key  = `openssl pkey -in server/privkey.pem -pubout 2>/dev/null`;
if (!length $pub_cert || $pub_cert ne $pub_key) {
	&say_status(0, 'the installed certificate and key do not match; the old pair is still on disk');
	exit 1;
}

open my $af, '<', 'server/fullchain.pem';
local $/;
my $after = <$af> // '';
close $af;

if ($after ne $before) {
	my $status = "$ENV{'HOME'}/.president/status";
	if (open my $sf, '>', $status) {
		print $sf 'restart';
		close $sf;
		&say_status(1, 'installed a new certificate for ' . $domain . '; restart requested');
	}
	else {
		&say_status(1, 'installed a new certificate for ' . $domain . '; restart the house to load it');
	}
}
else {
	&say_status(1, 'certificate for ' . $domain . ' is current (nothing to install)');
}
exit 0;
