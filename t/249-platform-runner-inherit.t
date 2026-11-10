# tests-for: lib/JawnOS/Platform/Runner/Windows.pm
# covers:    the Windows runner clears HANDLE_FLAG_INHERIT on the master's own
#            standard handles before CreateProcess, so a master whose output was
#            redirected to a log file cannot hand that file to a child and leave
#            it open past the master's exit. The enumeration is a pure helper,
#            so it runs here on every platform.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Slurp qw(read_file);

require JawnOS::Platform::Runner::Windows;

# --- the pure part ----------------------------------------------------------
my @cleared;
my $clear = sub { push @cleared, $_[0]; return 1 };

my $visited = JawnOS::Platform::Runner::Windows::_clear_std_inherit(
	[ 0, 1, 2 ],
	sub { $_[0] + 1000 },
	$clear,
);
is_deeply($visited, [ 1000, 1001, 1002 ], 'all three standard handles are visited');
is_deeply(\@cleared, [ 1000, 1001, 1002 ], 'and each one is cleared');

# A service has no console, and a redirected descriptor can be closed. Those
# answer undef/0 from the OS and must be skipped, not crash the spawn.
@cleared = ();
$visited = JawnOS::Platform::Runner::Windows::_clear_std_inherit(
	[ 0, undef, 2 ],
	sub {
		return undef unless defined $_[0];
		return $_[0] == 0 ? 0 : 1002;
	},
	$clear,
);
is_deeply($visited, [ 1002 ], 'a closed descriptor and an invalid handle are skipped');
is_deeply(\@cleared, [ 1002 ], 'while the usable one is still cleared');

is_deeply(
	JawnOS::Platform::Runner::Windows::_clear_std_inherit(undef, sub { 1 }, $clear),
	[],
	'no descriptors at all is an empty answer, not a crash',
);

# --- the wiring -------------------------------------------------------------
my $src = read_file("$FindBin::Bin/../lib/JawnOS/Platform/Runner/Windows.pm");
like($src, qr/SetHandleInformation\(\$handle, 1, 1\)/,
	'the child socket is still the one handle made inheritable');
like($src, qr/&_clear_std_inherit\(/, 'start clears the master standard handles');
like($src, qr/SetHandleInformation\(\$_\[0\], 1, 0\)/,
	'and the clear turns HANDLE_FLAG_INHERIT off, not on');
like($src, qr/main::STDIN.*main::STDOUT.*main::STDERR/s,
	'STDIN, STDOUT and STDERR are the handles it names');

my $clear_at = index($src, '&_clear_std_inherit(');
my $create_at = index($src, "&_api('CreateProcessA')->Call");
ok($clear_at >= 0, 'the clearing call exists');
ok($create_at > $clear_at,
	'and it runs before CreateProcess, or the child is created with the handles already inherited');

done_testing();
