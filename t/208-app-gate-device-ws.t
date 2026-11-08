# tests-for: lib/JawnOS/Manager/Part30.pm perl/hooks.pl
# covers:    /device/ws is the embedded output bus, authenticated by the rotated
#            Now Me pair exactly like /watch. It was missing from the app gate's
#            public paths, so the gate answered the Pico's upgrade with the
#            "app required" HTML at 200 and the socket never attached (the Pico
#            reported last=2: a refused upgrade, not a connect failure).

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

my ($body) = $src =~ /(sub app_public_path \{.*?\n\})/s;
ok($body, 'Part30 defines app_public_path');
{
	no warnings 'redefine';
	eval $body;
	is($@, '', 'the function compiles') or diag($@);
}

SKIP: {
	skip 'app_public_path did not compile', 4 unless defined &app_public_path;
	ok(app_public_path('/device/ws'), '/device/ws is exempt from the app gate');
	ok(app_public_path('/watch/alive'), '/watch stays exempt');
	ok(app_public_path('/teletype/ws'), '/teletype stays exempt');
	ok(!app_public_path('/manager/configure'), 'a private manager page is not exempt');
}

# --- the session gate has its own exemption list ---------------------------
# app_public_path only turns off the APP gate; a second list in hooks.pl decides
# whether authentication_passer (which renders the Gate page) runs at all.
like($hooks, qr/\$path eq '\/device\/ws'/, 'the session gate exempts /device/ws');

done_testing();
