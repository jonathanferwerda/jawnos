# tests-for: lib/JawnOS/Manager/Part30.pm perl/hooks.pl lib/JawnOS/Controller/manager_misc3.pm
# covers:    The Crew's peer routes (/manager/crew/state and /manager/crew/job)
#            ride the bare signed rail: a machine reads a peer's abilities and
#            dispatches a job with no session on the receiver. Neither route was
#            on the app gate's public list or the session gate's exemption list,
#            so a signed peer call was answered with the app-required page or the
#            Gate page. advert_sync reads that as an advert that never came, and
#            every machine logged "crew: advert sync answered for 0 peer(s)"
#            (the whole fleet, found 2026-11-19). The state route also has to
#            verify the caller itself now that the gates step aside for it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $src  = scalar read_file("$root/lib/JawnOS/Manager/Part30.pm");
my $hooks = scalar read_file("$root/perl/hooks.pl");
my $controller = scalar read_file("$root/lib/JawnOS/Controller/manager_misc3.pm");

# --- the app gate: a public path turns app_mode off for the request ----------
my ($body) = $src =~ /(sub app_public_path \{.*?\n\})/s;
ok($body, 'Part30 defines app_public_path');
{
	no warnings 'redefine';
	eval $body;
	is($@, '', 'the function compiles') or diag($@);
}

SKIP: {
	skip 'app_public_path did not compile', 4 unless defined &app_public_path;
	ok(app_public_path('/manager/crew/state'), 'the Crew state read is exempt from the app gate');
	ok(app_public_path('/manager/crew/job'),   'the Crew job dispatch is exempt from the app gate');
	ok(!app_public_path('/manager/crew/advertise'),
		'the browser Advertise Now button stays behind the session gate');
	ok(!app_public_path('/manager/crew/anything_else'),
		'only the peer routes are carved out');
}

# --- the session gate has its own exemption list -----------------------------
# app_public_path only turns off the APP gate; the second list in hooks.pl
# decides whether authentication_passer (which renders the Gate page) runs at
# all. Both are required, or a peer carrying no cookie still gets the Gate page.
like($hooks, qr/\$path eq '\/manager\/crew\/state'/, 'the session gate exempts the Crew state read');
like($hooks, qr/\$path eq '\/manager\/crew\/job'/,   'the session gate exempts the Crew job dispatch');
unlike($hooks, qr/\$path eq '\/manager\/crew\/advertise'/,
	'the browser Advertise Now button is not exempt from the session gate');

# --- the route proves the caller itself --------------------------------------
# The signatorial is public, so it is not a credential. Now that the gates step
# aside, the state route has to verify the pinned signature, like the APK rail
# next door (action_10311).
my ($state) = $controller =~ /(sub action_10408 \{.*?\n\})/s;
ok($state, 'manager_misc3 defines action_10408');
like($state, qr/peer_verify\(\$c, \$rm\)/, 'the state route verifies the caller signature');
like($state, qr/peer_allows\(\$c, \$rm, 'member'\)/, 'and requires a member grant');

done_testing();
