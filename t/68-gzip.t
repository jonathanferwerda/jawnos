# tests-for: lib/JawnOS.pm
# covers:    Dynamic responses are compressed in one after_dispatch hook.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

# Dynamic responses are compressed in one after_dispatch hook. The decision is
# a pure function, so it is exercised here without booting the app: requiring
# JawnOS.pm only defines the class (`startup` is what boots it).
require JawnOS;

my $html = '<html><body>' . ('word ' x 900) . '</body></html>';
ok(length($html) >= 1024, 'the sample body is over the threshold');

sub inflated {
	my ($bytes) = @_;
	return undef unless defined $bytes && length $bytes;
	my $out = '';
	return undef unless gunzip \$bytes => \$out;
	return $out;
}

sub gz {
	my ($encoding, $status, $type, $existing, $body, $method) = @_;
	return JawnOS::gzip_body_for($encoding, $status, $type, $existing, $body, $method);
}

# --- what is compressed -------------------------------------------------------
my $packed = gz('gzip', 200, 'text/html; charset=utf-8', undef, $html);
ok(defined $packed, 'compressible HTML is gzipped');
is(inflated($packed), $html, 'the gzip bytes inflate back to the input');
ok(length($packed) < length($html), 'the compressed body is smaller');

ok(defined gz('br, gzip;q=0.5', 200, 'text/html', undef, $html),
	'a gzip token with a positive q-value is accepted');

ok(defined gz('gzip', 200, 'application/json; charset=utf-8', undef, $html),
	'application/json with a charset is compressed');
ok(defined gz('gzip', 200, 'image/svg+xml', undef, $html),
	'image/svg+xml is compressed');
ok(defined gz('gzip', 200, 'text/css', undef, $html), 'text/css is compressed');

# --- what is refused ----------------------------------------------------------
ok(!defined gz('gzip;q=0', 200, 'text/html', undef, $html),
	'gzip;q=0 is a refusal, not a match');
ok(!defined gz('gzip; q=0.000', 200, 'text/html', undef, $html),
	'a spaced q-value of zero is a refusal');
ok(!defined gz('', 200, 'text/html', undef, $html),
	'an empty Accept-Encoding is refused');
ok(!defined gz(undef, 200, 'text/html', undef, $html),
	'a missing Accept-Encoding is refused');
ok(!defined gz('br', 200, 'text/html', undef, $html),
	'br alone is refused (no gzip token)');
ok(!defined gz('gzip', 200, 'text/html', undef, 'too small'),
	'a body under 1024 bytes is refused');
ok(!defined gz('gzip', 200, 'text/html', 'br', $html),
	'a body already encoded as br is refused');
ok(!defined gz('gzip', 200, 'image/png', undef, $html),
	'image/png is refused');
ok(!defined gz('gzip', 200, 'application/octet-stream', undef, $html),
	'application/octet-stream is refused');
ok(!defined gz('gzip', 304, 'text/html', undef, $html),
	'a 304 is refused');
ok(!defined gz('gzip', 200, 'text/html', undef, $html, 'HEAD'),
	'HEAD is refused (it has no body to compress)');

done_testing();
