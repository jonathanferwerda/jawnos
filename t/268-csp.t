# tests-for: lib/JawnOS.pm perl/hooks.pl
# covers:    Every HTML page carries one conservative Content-Security-Policy,
#           set centrally after dispatch: the exact directive list, that a page
#           response gets it, that JSON and media do not, that a route's own
#           policy is never overwritten, and that inline script is still
#           executable by design (the nonce migration is the follow-up). Also
#           HSTS: one max-age value, sent only on a secure request, never over
#           plain http and never over a value a route set itself.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
require JawnOS;
require Mojo::Headers;

sub source { return read_file(root() . '/' . $_[0]) }

my $EXPECTED = join('; ',
	"default-src 'self'",
	"script-src 'self' 'unsafe-inline' 'unsafe-eval'",
	"style-src 'self' 'unsafe-inline'",
	"img-src 'self' data: blob: https:",
	"media-src 'self' data: blob: https:",
	"connect-src 'self' ws: wss: https:",
	"font-src 'self' data:",
	"frame-src 'self' https:",
	"object-src 'none'",
	"base-uri 'self'",
	"form-action 'self'",
	"frame-ancestors 'self'",
);

# --- the policy is exactly the reviewed list --------------------------------
is(JawnOS::content_security_policy(), $EXPECTED,
	'the policy is the reviewed directive list, in order');
is(JawnOS::content_security_policy(), JawnOS::content_security_policy(),
	'and does not change between calls');

# --- a page gets it, other responses do not ---------------------------------
my $page = Mojo::Headers->new;
$page->content_type('text/html;charset=UTF-8');
is(JawnOS::apply_csp($page, '/manager'), 1, 'an HTML page response takes the policy');
is($page->header('Content-Security-Policy'), $EXPECTED,
	'and carries the exact header value');

my $json = Mojo::Headers->new;
$json->content_type('application/json;charset=UTF-8');
is(JawnOS::apply_csp($json, '/manager/window_maker'), 0, 'JSON is left alone');
is($json->header('Content-Security-Policy'), undef, 'with no CSP header added');

my $asset = Mojo::Headers->new;
$asset->content_type('application/javascript');
is(JawnOS::apply_csp($asset, '/js/manager.js'), 0, 'a script asset is left alone');

my $image = Mojo::Headers->new;
$image->content_type('image/png');
is(JawnOS::apply_csp($image, '/file_open'), 0, 'a media response is left alone');

my $pdf = Mojo::Headers->new;
$pdf->content_type('application/pdf');
is(JawnOS::apply_csp($pdf, '/file_open'), 0, 'a PDF document is left alone');

# /file_open can serve a file's raw bytes under the default text/html: that body
# is data, not one of the app's pages, so it keeps no policy.
my $raw = Mojo::Headers->new;
$raw->content_type('text/html');
is(JawnOS::apply_csp($raw, '/file_open'), 0,
	'/file_open text/html bytes are data, not a page');

# --- a route's own policy wins ----------------------------------------------
my $own = Mojo::Headers->new;
$own->content_type('text/html');
$own->header('Content-Security-Policy' => "default-src 'none'");
is(JawnOS::apply_csp($own, '/manager/embedded'), 0,
	'a route that set its own policy keeps it');
is($own->header('Content-Security-Policy'), "default-src 'none'",
	'and the route value is unchanged');

# --- HSTS: secure requests only ---------------------------------------------
is(JawnOS::strict_transport_security(), 'max-age=31536000',
	'HSTS is one reviewed max-age value');

my $secure = Mojo::Headers->new;
$secure->content_type('text/html');
is(JawnOS::apply_hsts($secure, 1), 1, 'a secure response takes HSTS');
is($secure->header('Strict-Transport-Security'), 'max-age=31536000',
	'with the exact header value');

my $plain = Mojo::Headers->new;
$plain->content_type('text/html');
is(JawnOS::apply_hsts($plain, 0), 0, 'a plain-http response does not');
is($plain->header('Strict-Transport-Security'), undef, 'and gets no HSTS header');

my $own_hsts = Mojo::Headers->new;
$own_hsts->header('Strict-Transport-Security' => 'max-age=60');
is(JawnOS::apply_hsts($own_hsts, 1), 0, 'a route that set its own value keeps it');
is($own_hsts->header('Strict-Transport-Security'), 'max-age=60',
	'and the route value is unchanged');

# --- the policy is installed in one central place ---------------------------
my $hooks = source('perl/hooks.pl');
like($hooks,
	qr/Manager::app->hook\(after_dispatch => sub \{\n\s+my \(\$c\) = \@_;\n\s+JawnOS::apply_csp\(\$c->res->headers, \$c->req->url->path->to_string \/\/ ''\);/,
	'the after_dispatch hook calls the one helper with the response headers and path');
like($hooks, qr/JawnOS::apply_hsts\(\$c->res->headers, \$c->req->is_secure\);/,
	'and asks for HSTS with the request secure flag');
is(scalar(() = $hooks =~ /Content-Security-Policy/g), 1,
	'and no other place in hooks.pl writes the header');

my @controller = sort glob(root() . '/lib/JawnOS/Controller/*.pm');
my @writers = grep {
	my $text = read_file($_);
	$text =~ /header\(\s*'Content-Security-Policy'/
} @controller;
is(scalar @writers, 0, 'no route sets the header by hand');

# --- the honesty the comment promises ---------------------------------------
like($hooks, qr/unsafe-inline/, 'the hook comment names the inline weakness');
my $app = source('lib/JawnOS.pm');
like($app, qr/'unsafe-inline' also\s*\n#\s*leaves an injected inline script executable/,
	'the policy comment says unsafe-inline still leaves injected script executable');
like($app, qr/nonce/, 'and names the nonce migration as the follow-up');
unlike($app, qr/script-src[^"]*'nonce-/, 'no nonce is enforced yet');

done_testing();
