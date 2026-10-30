use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest ();

# The suite's own smoke test: the core module loaded, the pieces the other
# tests call exist, and the install examples are still well-formed.

ok defined &subs::format_name,    'core module loaded (subs::format_name)';
ok defined &subs::duration_sayer, 'duration helpers loaded';
ok defined &language::translate,  'language catalog loaded';
ok defined &language::valid,      'language::valid loaded';

my $root = JawnOSTest::root();
ok defined $root && -d $root, 'repo root resolved';

# VERSION is what scripts/version_bump.pl rewrites and what the finish routine
# prefixes a commit with; a malformed one would break both.
open(my $vf, '<', "$root/VERSION") or die "VERSION: $!";
my $version = do { local $/; <$vf> };
close $vf;
like($version, qr/^\d+\.\d+\.\d+\s*$/, 'VERSION is a plain x.y.z');

# config.json.example is the tracked template; the live config.json is install
# local and gitignored. The example must still decode and carry the keys boot
# depends on.
require Mojo::JSON;
my $example = do {
	local $/;
	open(my $fh, '<', "$root/config.json.example") or die "config.json.example: $!";
	<$fh>;
};
my $config = eval { Mojo::JSON::decode_json($example) };
ok(ref $config eq 'HASH', 'config.json.example is a JSON object')
	or diag($@);
for my $key (qw(device language logfile port ws_port folders)) {
	ok(exists $config->{$key}, "config.json.example has $key");
}
is(ref $config->{folders}, 'ARRAY', 'config.json.example folders is a list');

# The help registry and the source templates it names are checked in 11-help.t;
# this only proves the registry file compiles and loads its package.
require "$root/help.pl";
ok defined &help::get, 'help registry loaded (help::get)';
ok scalar(keys %help::topic) > 0, 'help registry has topics';

done_testing();
