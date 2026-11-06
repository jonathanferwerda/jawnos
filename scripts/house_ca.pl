#!/usr/bin/env perl
# house_ca.pl - the house's own certificate authority for the peer rail.
#
#   perl scripts/house_ca.pl init
#   perl scripts/house_ca.pl issue --name house --ip 10.20.0.20 --ip 100.64.0.20 \
#        --dns house.jonathanferwerda.com
#   perl scripts/house_ca.pl verify --cert server/peer-fullchain.pem
#   perl scripts/house_ca.pl show
#
# Why a second certificate: the manager's main listener keeps the public
# wildcard, because a browser or the app reaches it by name and must not be told
# to trust a private CA. Peers, however, dial a literal IP on purpose - the
# peer's name is only usable while the tailnet's DNS answers - and a public
# wildcard covers no IP address. So the peer listener (President.pl, main port +
# 6) carries a leaf issued here, with every address the peer may be dialled by
# in its SAN, and every enrolled machine trusts `server/house-ca.pem`.
#
# The CA key never leaves the house and is written 0600. A leaf is issued for a
# named machine and installed as server/peer-fullchain.pem and
# server/peer-privkey.pem on that machine; a machine with no leaf simply keeps
# the old insecure rail, and the probe in subs::peer_tls_port() leaves it alone.
#
# No new dependency: openssl is the same tool the peer signing already uses.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);

my $root = abs_path("$FindBin::Bin/..");
chdir $root or die "house_ca: cannot find the jawnos root: $!\n";

my $SERVER    = 'server';
my $CA_KEY    = "$SERVER/house-ca.key";
my $CA_CERT   = "$SERVER/house-ca.pem";
my $LEAF_CERT = "$SERVER/peer-fullchain.pem";
my $LEAF_KEY  = "$SERVER/peer-privkey.pem";
my $CA_DAYS   = 3650;
my $LEAF_DAYS = 825;

$| = 1;

sub usage {
	print STDERR <<'TEXT';
usage: perl scripts/house_ca.pl <command>

  init                      create the house CA (server/house-ca.{key,pem})
  issue --name NAME         issue a peer leaf (server/peer-{fullchain,privkey}.pem)
        --ip ADDR             an address the peer may be dialled by (repeatable)
        --dns NAME            a name the peer may be dialled by (repeatable)
        --out DIR             where to write the leaf (default: server)
        --force               replace an existing leaf
  verify --cert FILE        check a leaf against the house CA and show its SANs
  show                      print the CA and the installed leaf

The CA key is never copied anywhere. A peer only needs server/house-ca.pem (the
public certificate) to trust the others, and its own leaf to be trusted.
TEXT
	exit 2;
}

sub fail {
	my ($message) = @_;
	print STDERR "house_ca: $message\n";
	exit 1;
}

sub sh {
	my (@cmd) = @_;
	my $rc = system(@cmd);
	return $rc == 0 ? 1 : 0;
}

sub capture {
	my (@cmd) = @_;
	open(my $fh, '-|', @cmd) or return '';
	local $/;
	my $out = <$fh> // '';
	close $fh;
	return $out;
}

sub valid_ip {
	my ($ip) = @_;
	return 0 unless defined $ip && length $ip;
	if ($ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {
		return 0 if grep { $_ > 255 } split /\./, $ip;
		return 1;
	}
	return 1 if $ip =~ /^[0-9a-fA-F:]+$/ && $ip =~ /:/;
	return 0;
}

sub valid_dns {
	my ($name) = @_;
	return 0 unless defined $name && length $name && length($name) <= 253;
	return $name =~ /^(?:\*\.)?[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/ ? 1 : 0;
}

# The key is what lets a machine sign; every other machine only needs the
# certificate to verify the leaves. Keep the two apart: a client must be able to
# run verify and show without holding the house's signing key.
sub ca_ready {
	return -s $CA_KEY && -s $CA_CERT;
}

sub ca_cert_ready {
	return -s $CA_CERT;
}

sub ca_fingerprint {
	return '' unless -s $CA_CERT;
	my $out = capture('openssl', 'x509', '-in', $CA_CERT, '-noout', '-fingerprint', '-sha256');
	$out =~ s/^.*=//;
	$out =~ s/\s+$//;
	return $out;
}

sub cmd_init {
	my $force = grep { $_ eq '--force' } @ARGV;
	make_path($SERVER);
	# A client holds only the certificate; init there must not quietly mint a
	# second CA and overwrite the one the house signs with.
	if ((-s $CA_CERT || -s $CA_KEY) && !$force) {
		print "house_ca: a CA already exists at $CA_CERT (use --force to replace it)\n";
		return 0;
	}
	my $tmp = tempdir(CLEANUP => 1);
	my $key = "$tmp/ca.key";
	my $crt = "$tmp/ca.pem";
	sh('openssl', 'req', '-x509', '-newkey', 'ec',
		'-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
		'-keyout', $key, '-out', $crt,
		'-days', $CA_DAYS,
		'-subj', '/CN=JawnOS House CA/O=JawnOS',
		'-addext', 'basicConstraints=critical,CA:TRUE,pathlen:0',
		'-addext', 'keyUsage=critical,keyCertSign,cRLSign',
		'-addext', 'subjectKeyIdentifier=hash')
		or fail('openssl could not create the CA');
	copy($key, $CA_KEY) or fail("cannot write $CA_KEY: $!");
	copy($crt, $CA_CERT) or fail("cannot write $CA_CERT: $!");
	chmod 0600, $CA_KEY;
	chmod 0644, $CA_CERT;
	print "created $CA_CERT\n";
	print '  sha256 ', ca_fingerprint(), "\n";
	print "Keep $CA_KEY on the house; hand only $CA_CERT to the other machines.\n";
	return 0;
}

sub cmd_issue {
	my @ip = ();
	my @dns = ();
	my $name = '';
	my $out = $SERVER;
	my $force = 0;
	my @argv = @ARGV;
	while (my $arg = shift @argv) {
		if ($arg eq '--name') { $name = shift @argv // ''; next }
		if ($arg =~ /^--name=(.*)$/) { $name = $1; next }
		if ($arg eq '--ip') { push @ip, shift @argv // ''; next }
		if ($arg =~ /^--ip=(.*)$/) { push @ip, $1; next }
		if ($arg eq '--dns') { push @dns, shift @argv // ''; next }
		if ($arg =~ /^--dns=(.*)$/) { push @dns, $1; next }
		if ($arg eq '--out') { $out = shift @argv // $SERVER; next }
		if ($arg =~ /^--out=(.*)$/) { $out = $1; next }
		if ($arg eq '--force') { $force = 1; next }
	}
	fail('--name is required') unless length $name;
	fail("'$name' is not a usable name") unless $name =~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/;
	fail('the CA is not initialised; run init first') unless ca_ready();
	fail('give at least one --ip or --dns') unless @ip || @dns;
	for my $ip ( @ip ) { fail("'$ip' is not an IP address") unless valid_ip($ip) }
	for my $dns ( @dns ) { fail("'$dns' is not a DNS name") unless valid_dns($dns) }

	my $cert_out = "$out/peer-fullchain.pem";
	my $key_out  = "$out/peer-privkey.pem";
	if ((-e $cert_out || -e $key_out) && !$force) {
		fail("a peer leaf already exists in $out (use --force to replace it)");
	}
	make_path($out);

	my @sans = ('DNS:' . $name);
	push @sans, map { 'IP:' . $_ } @ip;
	push @sans, map { 'DNS:' . $_ } @dns;
	my $tmp = tempdir(CLEANUP => 1);
	my $key = "$tmp/leaf.key";
	my $csr = "$tmp/leaf.csr";
	my $ext = "$tmp/leaf.ext";
	my $leaf = "$tmp/leaf.pem";
	open(my $ef, '>', $ext) or fail("cannot write $ext: $!");
	print {$ef} "basicConstraints=critical,CA:FALSE\n";
	print {$ef} "keyUsage=critical,digitalSignature,keyEncipherment\n";
	print {$ef} "extendedKeyUsage=serverAuth,clientAuth\n";
	print {$ef} 'subjectAltName=' . join(',', @sans) . "\n";
	print {$ef} "subjectKeyIdentifier=hash\n";
	print {$ef} "authorityKeyIdentifier=keyid,issuer\n";
	close $ef;

	sh('openssl', 'req', '-new', '-newkey', 'ec',
		'-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
		'-keyout', $key, '-out', $csr, '-subj', "/CN=$name")
		or fail('openssl could not create the leaf request');
	sh('openssl', 'x509', '-req', '-in', $csr,
		'-CA', $CA_CERT, '-CAkey', $CA_KEY, '-CAcreateserial',
		'-days', $LEAF_DAYS, '-sha256', '-extfile', $ext, '-out', $leaf)
		or fail('openssl could not sign the leaf');

	open(my $of, '>', "$tmp/fullchain.pem") or fail("cannot write the chain: $!");
	for my $file ( $leaf, $CA_CERT ) {
		open(my $in, '<', $file) or fail("cannot read $file: $!");
		print {$of} $_ while <$in>;
		close $in;
	}
	close $of;
	copy("$tmp/fullchain.pem", $cert_out) or fail("cannot write $cert_out: $!");
	copy($key, $key_out) or fail("cannot write $key_out: $!");
	chmod 0644, $cert_out;
	chmod 0600, $key_out;

	my $serial = capture('openssl', 'x509', '-in', $leaf, '-noout', '-serial');
	$serial =~ s/^serial=//;
	$serial =~ s/\s+$//;
	print "issued $cert_out for $name\n";
	print '  sans   ', join(' ', @sans), "\n";
	print "  serial $serial\n";
	print "  install $key_out beside it, mode 0600, then restart the tree\n";
	return 0;
}

sub cmd_verify {
	my $file = $LEAF_CERT;
	my @argv = @ARGV;
	while (my $arg = shift @argv) {
		if ($arg eq '--cert') { $file = shift @argv // ''; next }
		if ($arg =~ /^--cert=(.*)$/) { $file = $1; next }
	}
	return 1 unless -s $file;
	fail("the CA certificate is missing at $CA_CERT") unless ca_cert_ready();
	my $text = do { local $/; open(my $fh, '<', $file) or fail("cannot read $file: $!"); <$fh> };
	my ($first) = $text =~ /(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)/s;
	fail("$file holds no certificate") unless $first;
	my $tmp = tempdir(CLEANUP => 1);
	open(my $lf, '>', "$tmp/leaf.pem") or fail("cannot write the leaf: $!");
	print {$lf} $first;
	close $lf;
	my $ok = sh('openssl', 'verify', '-CAfile', $CA_CERT, "$tmp/leaf.pem");
	my $subject = capture('openssl', 'x509', '-in', "$tmp/leaf.pem", '-noout', '-subject');
	my $issuer  = capture('openssl', 'x509', '-in', "$tmp/leaf.pem", '-noout', '-issuer');
	my $sans    = capture('openssl', 'x509', '-in', "$tmp/leaf.pem", '-noout', '-ext', 'subjectAltName');
	my $notafter = capture('openssl', 'x509', '-in', "$tmp/leaf.pem", '-noout', '-enddate');
	for ($subject, $issuer, $notafter) { s/\s+$// }
	$sans =~ s/^\s+|\s+$//g;
	$sans =~ s/\n+/, /g;
	print $ok ? "ok: the chain verifies against $CA_CERT\n" : "FAILED: the chain does not verify against $CA_CERT\n";
	print "  $subject\n  $issuer\n  $notafter\n  $sans\n";
	return $ok ? 0 : 1;
}

sub cmd_show {
	unless (ca_cert_ready()) {
		print "house_ca: no CA certificate yet ($CA_CERT)\n";
		return 1;
	}
	print "CA   $CA_CERT\n";
	print '     sha256 ', ca_fingerprint(), "\n";
	print 'key  ', (-s $CA_KEY ? 'present (this machine can issue)' : 'absent (this machine is a client)'), "\n";
	for my $file ( $LEAF_CERT, $LEAF_KEY ) {
		my $state = -e $file ? 'present' : 'missing';
		printf "leaf %-30s %s%s\n", $file, $state,
			(-e $file && $file =~ /privkey/) ? sprintf(' (mode %04o)', (stat($file))[2] & 07777) : '';
	}
	return 0;
}

my $command = shift @ARGV // '';
if ($command eq 'init')   { exit cmd_init() }
if ($command eq 'issue')  { exit cmd_issue() }
if ($command eq 'verify') { exit cmd_verify() }
if ($command eq 'show')   { exit cmd_show() }
usage();
