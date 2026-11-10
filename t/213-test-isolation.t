# tests-for: t/lib/JawnOSTest.pm
# covers:    The regression suite's sandbox. subroutines.pl resolves the
#            database from its own real path, and the sandbox links perl/ to
#            the checkout, so without an override every test opened the live
#            house database - and a test that saved a setting changed the
#            house (phone/ivr_routes was wiped by a nightly). The harness now
#            snapshots the house and points install_dir at the snapshot, and
#            the fork runner gives each child its own copy.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Cwd qw(abs_path);
use File::Spec;
use JSON::PP ();
use Test::More;
use JawnOSTest;

my $live = root() . '/database/jawnos.db';
my $test_db = &subs::database_path();

isnt($test_db, $live, 'the suite does not name the live house database');
isnt(abs_path(&subs::install_dir()), abs_path(root()),
	'the install dir is the sandbox, not the checkout');
# A Windows sandbox is C:\WINDOWS\TEMP\jaw..., so the system-temp forms are not
# the Unix ones alone; either way the file is outside the checkout.
like($test_db, qr{\A(?:/tmp|/var/tmp|/private/var/tmp|/dev/shm|[A-Za-z]:[\\/])},
	'and the database lives outside the checkout');

SKIP: {
	skip 'this checkout has no house database to snapshot', 2 unless -f $live;
	ok(-f $test_db, 'the sandbox holds a snapshot of it');
	my $tables = &subs::db_query(
		"select count(*) as n from sqlite_master where type = 'table'")->hash;
	cmp_ok($tables->{'n'}, '>', 10, 'and the snapshot carries the schema');
}

# Windows does not implement POSIX::tzset - the call dies rather than refreshing
# the cache - and every test that loaded this harness aborted there. TZ is still
# pinned; the refresh has to stay inside the eval and nothing else may call it.
my $harness = do {
	open(my $fh, '<', "$FindBin::Bin/lib/JawnOSTest.pm") or die $!;
	local $/;
	<$fh>;
};
like($harness, qr/\$ENV\{TZ\} = 'UTC'/, 'the harness still pins TZ to UTC');
like($harness, qr/eval \{ POSIX::tzset\(\) \}/,
	'and refreshes the zone inside an eval (Windows has no tzset)');
(my $hcode = $harness) =~ s/^\s*#.*$//mg;
$hcode =~ s/eval \{ POSIX::tzset\(\) \}/eval/;
unlike($hcode, qr/POSIX::tzset/, 'no unguarded POSIX::tzset call is left');

# The sandbox config.json is encoded, not concatenated: Windows wrote
# `C:\Users\...\Temp\jaw...` straight into a JSON string, a raw backslash is an
# illegal escape, and Mojo::JSON died at boot - which the guard reported as every
# test file failing. Build it for a Windows-shaped path on any platform and read
# it back with the decoder that failed.
my $win = 'C:\\Users\\jawn\\AppData\\Local\\Temp\\jaw_test';
my $json = JawnOSTest::config_json($win);
my $cfg = eval { JSON::PP->new->decode($json) };
is($@, '', 'the sandbox config decodes') or diag($@);
is($cfg->{'logfile'}, File::Spec->catfile($win, 'manager.log'),
	'and a Windows path round-trips unchanged');
is($cfg->{'device'}, 'computer', 'the boot values are the ones the harness used');
is($cfg->{'port'}, '3000', 'the ports stay strings');
is($cfg->{'working_port'}, '3001', 'every one of them');
is($cfg->{'ws_port'}, '3001', 'including the websocket');
SKIP: {
	skip 'Mojo::JSON is not installed here', 1 unless eval { require Mojo::JSON; 1 };
	my $mojo = eval { Mojo::JSON::decode_json($json) };
	is($@, '', 'and Mojo::JSON - the decoder that died on the unescaped path - reads it');
}

done_testing();
