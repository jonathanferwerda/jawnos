use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# A bare `sshd` on Android is not a working sshd: Termux's sshd_config comments
# out every HostKey line, and the login user's home in the passwd entry is the
# old Termux prefix, so AuthorizedKeysFile resolved to a path this app cannot
# read. The port answered and every key was refused - the phone, 2026-10-31.
# One builder produces the argv so the options can be checked without a daemon.

my @cmd = subs::sshd_command('/data/user/0/com.jawnos/files/usr',
	'/data/user/0/com.jawnos/files/home');
my %opt;
my $config_file;
for my $i ( 0 .. $#cmd ) {
	my $arg = $cmd[$i];
	next unless defined $cmd[$i + 1];
	if ($arg eq '-o') {
		my ($k, $v) = split /=/, $cmd[$i + 1], 2;
		$opt{$k} = $v if defined $k && defined $v;
	}
	elsif ($arg eq '-f') { $config_file = $cmd[$i + 1]; }
}
is($cmd[0], 'sshd', 'the daemon is still sshd');
is($opt{'AuthorizedKeysFile'}, '/data/user/0/com.jawnos/files/home/.ssh/authorized_keys',
	'authorized_keys is absolute, not the passwd home');
is($opt{'StrictModes'}, 'no', 'StrictModes is off over /data/user/0');
is($opt{'PidFile'}, '/data/user/0/com.jawnos/files/usr/tmp/sshd.pid',
	'the pid file lives in the prefix tmp');
is($opt{'SetEnv'}, 'HOME=/data/user/0/com.jawnos/files/home',
	'the session gets the app home back');
is($config_file, '/data/user/0/com.jawnos/files/usr/etc/ssh/sshd_config',
	'the prefix config is named');

# No prefix means no daemon to start: never fall back to a bare `sshd`.
is_deeply([ subs::sshd_command('', '/tmp/home') ], [],
	'an empty prefix produces no command');

# The source must keep the ownership straight: Manager starts it, President does
# not, and the recovery script does not fall back to a bare `sshd` either.
my $subs = do { local $/; open(my $fh, '<', "$FindBin::Bin/../subroutines.pl") or die $!; <$fh> };
my $manager = do { local $/; open(my $fh, '<', "$FindBin::Bin/../Manager.pl") or die $!; <$fh> };
my $president = do { local $/; open(my $fh, '<', "$FindBin::Bin/../President.pl") or die $!; <$fh> };
like($manager, qr/sshd_running\(\)/,
	'the manager checks whether sshd is already running');
like($manager, qr/subs::sshd_start\(\)/,
	'the manager starts sshd through the shared builder');
unlike($president, qr/^\s*`sshd`;/m,
	'President.pl does not start a bare sshd at boot');

done_testing();
