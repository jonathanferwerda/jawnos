package JawnOS::Platform::TLS;

# A fresh install has no certificate, and every serving listener is https. The
# house CA issues the real one later (scripts/house_ca.pl, scripts/tls_issue.pl);
# until then a self-signed pair is what lets the TLS listeners bind at all. Issue
# it beside the schema so the existing $certs lookup finds it unchanged.

use strict;
use warnings;

use JawnOS::Platform ();

# OpenSSL is a Strawberry tool in C:\Strawberry\c\bin, which is not always on
# PATH; fall back to the copy beside the interpreter.
sub openssl {
	my $path = JawnOS::Platform::tool_path('openssl');
	return $path if $path;
	my $perl = $^X;
	if ($perl =~ m{^(.*?)[/\\]perl[/\\]bin[/\\]perl(?:\.exe)?$}i) {
		my $candidate = "$1/c/bin/openssl.exe";
		return $candidate if -f $candidate;
	}
	return undef;
}

sub ensure_local_cert {
	my (%opt) = @_;
	my $dir  = $opt{'dir'}  || './server';
	my $cert = $opt{'cert'} || "$dir/fullchain.pem";
	my $key  = $opt{'key'}  || "$dir/privkey.pem";
	return { cert => $cert, key => $key, created => 0 }
		if -e $cert && -s $cert > 100 && -e $key && -s $key > 100;

	my $openssl = $opt{'openssl'} || &openssl();
	return { cert => $cert, key => $key, created => 0, error => 'openssl is not available' }
		unless $openssl;

	require File::Path;
	File::Path::make_path($dir) unless -d $dir;

	my $days = $opt{'days'} || 3650;
	my $cn   = $opt{'common_name'} || 'jawnos-local';
	my @base = (
		$openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
		'-keyout', $key, '-out', $cert, '-days', $days, '-subj', "/CN=$cn",
	);
	# -addext is OpenSSL 1.1.1+; an older tool still gets a working pair from CN.
	my $rc = system(@base, '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1');
	$rc = system(@base) if $rc != 0;

	return { cert => $cert, key => $key, created => 0, error => "openssl failed ($rc)" }
		if $rc != 0 || !-e $cert || !-s $cert || !-e $key || !-s $key;
	eval { chmod 0600, $key };
	return { cert => $cert, key => $key, created => 1 };
}

1;
