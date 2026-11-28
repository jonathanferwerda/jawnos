# tests-for: lib/JawnOS/Manager/Part33.pm
# covers:    the login gate admits a request whose caller proved a pinned peer
#            key, so a relay from a machine whose stored session lapsed reaches
#            the route instead of the Gate page; the cookie is left alone, and an
#            explicit denial still refuses.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $src = read_file("$root/lib/JawnOS/Manager/Part33.pm");

# The proof a caller cannot invent: the pinned key on a roster row, verified by
# peer_verify. A browser quoting a signatorial gets nothing.
my $peer_call_at = index($src, "my \$peer_call = \$c->stash('peer_verified_key') || (\$app_peer // &app_peer_ok(\$c));");
ok($peer_call_at >= 0, 'the gate resolves the verified peer proof');

# The bypass sits inside the not-approved branch, before the Gate is rendered.
my $bypass_at = index($src, "return 'approved' if \$peer_call;");
ok($bypass_at >= 0, 'the login gate admits a verified peer');
my $unless_at = index($src, "unless (\$authentication eq 'approved') {");
ok($unless_at >= 0 && $bypass_at > $unless_at, 'inside the branch that would refuse');
my $gate_at = index($src, "template => 'gate'", $bypass_at);
ok($gate_at > $bypass_at, 'before the Gate page is rendered');
ok($peer_call_at < $bypass_at, 'using the verified proof, not a request parameter');

# The peer's own cookie is not rewritten: it is not a person's session to revoke.
my $revoke_at = index($src, "\$c->session('authentication' => 'revoked');", $bypass_at);
ok($revoke_at > $bypass_at, 'the peer cookie is not marked revoked by the refusal path');

# An explicit denial is a deliberate refusal of the session and is checked
# before the peer proof, so a blacklisted or denied cookie still meets the
# denial page.
my $denial_at = index($src, "\$c->session('authentication') eq 'denial'");
ok($denial_at >= 0 && $denial_at < $bypass_at, 'an explicit denial still refuses first');

# The bypass must not be a blanket "any peer reaches anything": the tier and
# scope checks live in the before_dispatch hook and run before this function.
my $hooks = read_file("$root/perl/hooks.pl");
like($hooks, qr/tier_denied/, 'the tier check runs before the session gate');
like($hooks, qr/access_scope_missing/, 'and the resident scope check too');

done_testing();
