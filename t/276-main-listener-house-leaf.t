# tests-for: perl/President.pl lib/JawnOS/Platform/TLS.pm
# covers:    A machine that still carries the fresh-install self-signed pair on
#            its main listener while its house-CA leaf sits in the peer pair
#            presents the leaf on the main listener too. The app refuses the
#            placeholder (ERR_CERT_AUTHORITY_INVALID), so Go to the phone and
#            the tablet opened an error page while the hub and table worked.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);
use RepoSource;
use JawnOS::Platform::TLS;

my $root = repo_root();

SKIP: {
	skip 'openssl is not installed', 3 unless JawnOS::Platform::TLS::openssl();

	my $dir = tempdir(CLEANUP => 1);
	my $made = JawnOS::Platform::TLS::ensure_local_cert(dir => $dir);
	ok($made->{'created'}, 'the fresh-install pair is written');
	ok(JawnOS::Platform::TLS::is_bootstrap_cert("$dir/fullchain.pem"),
		'the placeholder is recognised by its self-signed CN=jawnos-local');

	# ensure_local_cert with another name still self-signs; the CN is what marks
	# the placeholder, so a machine-named pair must not be mistaken for it.
	my $named = JawnOS::Platform::TLS::ensure_local_cert(
		dir => "$dir/named", common_name => 'tablet.example.com');
	ok(!JawnOS::Platform::TLS::is_bootstrap_cert("$dir/named/fullchain.pem"),
		'a certificate that names a machine is not the placeholder');
}

# The decision is made at boot, where there is no listener to ask: the main
# listener must take the peer pair when fullchain.pem holds the placeholder.
my $president = read_file("$root/perl/President.pl");
like($president, qr/is_bootstrap_cert/, 'the boot consults the placeholder check');
like($president, qr/\$certs\s*=\s*\$peer_certs/, 'and hands the main listener the house-CA pair');

done_testing();
