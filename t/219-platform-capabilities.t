# tests-for: lib/JawnOS/Platform.pm
# covers:    the portability flags P0 asks about: what the OS can do, what the
#            current mode asks for, the transport choice, and the explicit
#            tree/data directory overrides.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use JawnOS::Platform ();

is(JawnOS::Platform::os(), $^O, 'os is the running perl platform');
ok(length JawnOS::Platform::arch(), 'arch is reported');

my $required = JawnOS::Platform::required_modules();
is(ref $required, 'ARRAY', 'required_modules returns a list');
ok((grep { $_ eq 'Mojolicious' } @$required), 'Mojolicious is required');
ok((grep { $_ eq 'Minion' } @$required), 'Minion is required');
ok((grep { $_ eq 'DBD::SQLite' } @$required), 'DBD::SQLite is required');

ok(defined JawnOS::Platform::module_version('Test::More'), 'a loaded module reports a version');
is(JawnOS::Platform::module_version('JawnOS::NoSuchModuleForTheProbe'), undef,
	'a module that is not installed is undef');

{
	local $ENV{'JAWNOS_PORTABLE'} = '1';
	local $ENV{'JAWNOS_NO_FORK'} = '';
	ok(JawnOS::Platform::portable(), 'JAWNOS_PORTABLE=1 is portable mode');
	ok(!JawnOS::Platform::strict(), 'plain portable mode is not strict');
	is(JawnOS::Platform::use_fork(), 0, 'portable mode does not use fork');
	is(JawnOS::Platform::use_pty(), 0, 'portable mode does not use a pty');
	is(JawnOS::Platform::preferred_transport(), 'tcp', 'portable mode prefers TCP transport');
}

{
	local $ENV{'JAWNOS_PORTABLE'} = 'strict';
	ok(JawnOS::Platform::portable(), 'strict is a portable mode');
	ok(JawnOS::Platform::strict(), 'strict mode is reported');
}

{
	local $ENV{'JAWNOS_PORTABLE'} = '';
	local $ENV{'JAWNOS_NO_FORK'} = '1';
	ok(JawnOS::Platform::strict(), 'JAWNOS_NO_FORK is strict mode');
}

{
	local $ENV{'JAWNOS_TRANSPORT'} = 'tcp';
	is(JawnOS::Platform::transport(), 'tcp', 'an explicit TCP transport wins');
	is(JawnOS::Platform::use_unix_socket(), 0, 'TCP transport does not use a UNIX socket');
}

{
	local $ENV{'JAWNOS_TRANSPORT'} = 'unix';
	is(JawnOS::Platform::transport(), 'unix', 'an explicit UNIX transport wins');
	is(JawnOS::Platform::use_unix_socket(), JawnOS::Platform::unix_socket_available(),
		'UNIX transport follows the platform capability');
}

{
	local $ENV{'JAWNOS_DIR'} = '/tmp/jawnos-tree';
	local $ENV{'JAWNOS_DATA_DIR'} = '/tmp/jawnos-data';
	is(JawnOS::Platform::tree_dir(), '/tmp/jawnos-tree', 'JAWNOS_DIR overrides the tree');
	is(JawnOS::Platform::data_dir(), '/tmp/jawnos-data', 'JAWNOS_DATA_DIR overrides the data dir');
}

my $caps = JawnOS::Platform::capabilities();
is(ref $caps, 'HASH', 'capabilities is a hash');
ok(exists $caps->{'modules'}, 'capabilities carries module state');
ok(exists $caps->{'tools'}, 'capabilities carries tool state');
is(ref $caps->{'serial_devices'}, 'ARRAY', 'serial devices are a list');
ok(defined $caps->{'mode'}, 'capabilities names the mode');

SKIP: {
	skip 'POSIX-only capability', 2 if $^O eq 'MSWin32';
	ok(JawnOS::Platform::fork_available(), 'a POSIX box reports fork available');
	ok(JawnOS::Platform::unix_socket_available(), 'a POSIX box reports UNIX sockets available');
}

# Windows has no getppid; the runner exports the parent pid for the child it
# spawns. On POSIX the real parent wins, so a stale hint cannot mislead.
is(JawnOS::Platform::parent_pid(), getppid(), 'parent_pid is the real parent');
{
	local $ENV{'JAWNOS_PARENT_PID'} = '4242';
	is(JawnOS::Platform::parent_pid(), getppid(),
		'a POSIX parent is never overridden by the hint');
}

done_testing();
