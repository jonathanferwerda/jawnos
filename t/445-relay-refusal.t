# tests-for: lib/JawnOS/Domain/Remote.pm lib/JawnOS/Domain/Loader.pm
# covers:    a relayed request the peer answered with a gate, denial or login
#            page is a refusal, not a delivery - the page is named, the manual
#            relay tries the next route, and the request relay logs the miss
#            instead of counting a 200 page as a success.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

my $root = repo_root();
require "$root/lib/JawnOS/Domain/Remote.pm";

# A response as the relay's UA hands it back: a status and a body.
{ package RelayRes;
  sub new { my ($class, %args) = @_; return bless { %args }, $class }
  sub is_success { return $_[0]->{'success'} // 1 }
  sub code { return $_[0]->{'code'} }
  sub body { return $_[0]->{'body'} }
}

sub refused { return subs::relay_refused(RelayRes->new(@_)) }

ok(subs::provides('relay_refused'), 'the refusal test is a domain function the loader maps');

# --------------------------------------------------------------- the answer
is(subs::relay_refused(undef), '', 'no response is not a refusal');
is(subs::relay_refused(RelayRes->new(body => '{"ok":1}')), '', 'a JSON answer is a delivery');
is(subs::relay_refused(RelayRes->new(body => '')), '', 'an empty answer is a delivery (close, ping)');
is(refused(success => 0, code => 403, body => '{"error":"no"}'),
	'HTTP 403', 'a non-success status is a refusal');
is(refused(body => '<html><head><title>x</title></head><body><div id="app_required">open in the app</div></body></html>'),
	'the app-required page', 'the app gate is named');
is(refused(body => '<img class="denial_image" src="data:png;base64,AA"><style>html{background:#123}</style>'),
	'the denial page', 'the scope denial is named even as a fragment');
is(refused(body => "<!DOCTYPE html>\n<html><body>the gate</body></html>"),
	'the login gate', 'the login gate is named');
is(refused(body => '{"ok":1}'), '', 'and a normal JSON answer stays a delivery');

# ------------------------------------------------------------- the callers
my $source = read_file("$root/lib/JawnOS/Domain/Remote.pm");
my @uses = ($source =~ /&relay_refused\(/g);
cmp_ok(scalar @uses, '>=', 3, 'the manual relay, the POST relay and the GET relay all ask');

# The manual relay must not mark a refused route answered; it records the page
# as the failure and tries the next address.
my $manual_at = index($source, "my \$refused = &relay_refused(\$response);");
my $manual_answered = index($source, "\$answered = \$route;", $manual_at);
ok($manual_at >= 0 && $manual_answered > $manual_at,
	'the manual relay records the refusal before it would mark the route answered');
like($source, qr/\$failure = \$refused;/, 'and carries the page as the failure reason');

# A broadcast has no per-target retry, so a refusal must at least be logged:
# the normal channel has no other way to say the peer did not take the change.
like($source, qr/refused the request \(' \. \$refused \. '\)/,
	'the request relay names the refusing peer and the page');

done_testing();
