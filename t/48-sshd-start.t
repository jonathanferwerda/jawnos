# tests-for: lib/JawnOS/Domain/House.pm lib/JawnOS/Domain/Process.pm perl/President.pl perl/jobs.pl scripts/manager_killer.pl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use RepoSource;
use JawnOSTest;

# A bare `sshd` on Android is not a working sshd: Termux's sshd_config comments
# out every HostKey line, and the login user's home in the passwd entry is the
# old Termux prefix, so AuthorizedKeysFile resolved to a path this app cannot
# read. The port answered and every key was refused - the phone, 2026-10-31.
#
# The second lockout was the invocation itself: sshd was handed a literal
# '$PREFIX' (not expanded) and a home under files/usr/home. Both tests below are
# about the string that reaches exec, which is why they read ssd_command and not
# the running daemon.

# A prefix shaped like the app's, so sshd_paths can find it.
my $root = tempdir(CLEANUP => 1);
my $prefix = "$root/files/usr";
my $home = "$root/files/home";
make_path("$prefix/etc/ssh", "$prefix/tmp", "$home/.ssh");
open(my $cfg, '>', "$prefix/etc/ssh/sshd_config") or die $!;
close $cfg;
foreach my $kind (qw(ed25519 ecdsa)) {
	open($cfg, '>', "$prefix/etc/ssh/ssh_host_$kind\_key") or die $!;
	close $cfg;
}

local $ENV{'PREFIX'} = $prefix;
local $ENV{'HOME'} = $home;

my @cmd = subs::sshd_command();
my %opt;
my $config_file;
my @host_keys;
for my $i ( 0 .. $#cmd ) {
	my $arg = $cmd[$i];
	next unless defined $cmd[$i + 1];
	if ($arg eq '-o') {
		my ($k, $v) = split /=/, $cmd[$i + 1], 2;
		$opt{$k} = $v if defined $k && defined $v;
	}
	elsif ($arg eq '-f') { $config_file = $cmd[$i + 1]; }
	elsif ($arg eq '-h') { push @host_keys, $cmd[$i + 1]; }
}

is($cmd[0], "$prefix/bin/sshd", 'the daemon is named by its absolute prefix path');
like($cmd[0], qr{^/}, 'the daemon path is absolute, so exec never searches PATH');
unlike($cmd[0], qr{^(?:sshd|\$)} , 'the daemon path is neither a bare name nor an unexpanded variable');
is($config_file, "$prefix/etc/ssh/sshd_config", 'the prefix config is named');
is($opt{'PidFile'}, "$prefix/tmp/sshd.pid", 'the pid file lives in the prefix tmp');
# sshd will not create the pid file's directory, and a prefix without one (the
# tablet had none) makes the daemon exit before it binds.
{
	my $bare_root = tempdir(CLEANUP => 1);
	my $bare_prefix = "$bare_root/files/usr";
	make_path("$bare_prefix/etc/ssh");
	open(my $c, '>', "$bare_prefix/etc/ssh/sshd_config") or die $!;
	close $c;
	local $ENV{'ANDROID_ROOT'} = '/system';
	local $ENV{'PREFIX'} = $bare_prefix;
	ok(!-d "$bare_prefix/tmp", 'the fixture starts without a prefix tmp');
	subs::sshd_start();
	ok(-d "$bare_prefix/tmp", 'sshd_start creates the pid file directory');
}
is($opt{'AuthorizedKeysFile'}, "$home/.ssh/authorized_keys",
	'authorized_keys is under the app home, not the passwd home');
is($opt{'StrictModes'}, 'no', 'StrictModes is off over /data/user/0');
is($opt{'SetEnv'}, "HOME=$home", 'the session gets the app home back');
is_deeply(\@host_keys, [ "$prefix/etc/ssh/ssh_host_ed25519_key", "$prefix/etc/ssh/ssh_host_ecdsa_key" ],
	'the prefix host keys that exist are named');

# The $PREFIX lockout: nothing in the argv may be a shell variable, a tilde or a
# relative path. Every option value is a plain absolute path built in Perl.
my $line = subs::sshd_command_line(@cmd);
unlike($line, qr/\$[A-Za-z{_]/, 'the command carries no literal $VAR');
unlike($line, qr{/usr/home}, 'the home is not files/usr/home');
unlike($line, qr/(^|\s)~/, 'the command carries no tilde');
	foreach my $arg (@cmd) {
	next if $arg eq "$prefix/bin/sshd" || $arg eq '-o' || $arg eq '-f' || $arg eq '-h';
	# an -o value is Key=value; the keys whose value IS a path must be absolute
	my ($key, $value) = $arg =~ /^([A-Za-z]+)=(.+)$/ ? ($1, $2) : ('', $arg);
	next unless $key eq '' || $key =~ /^(?:PidFile|AuthorizedKeysFile)$/;
	like($value, qr{^/}, "argument '$arg' is an absolute path");
}
like($line, qr{^\Q$prefix/bin/sshd\E }, 'the command line renders for the log');

# An AUTHORIZEDKEYS home that is not under the app (the passwd one, the old
# Termux prefix) is replaced by the app home, and never becomes files/usr/home.
{
	local $ENV{'HOME'} = '/data/data/com.termux/files/home';
	my %alt;
	my @alt = subs::sshd_command();
	for my $i ( 0 .. $#alt ) {
		next unless $alt[$i] eq '-o' && defined $alt[$i + 1];
		my ($k, $v) = split /=/, $alt[$i + 1], 2;
		$alt{$k} = $v;
	}
	is($alt{'AuthorizedKeysFile'}, "$root/files/home/.ssh/authorized_keys",
		'a foreign HOME still resolves authorized_keys into the app home');
	unlike($alt{'AuthorizedKeysFile'}, qr{/usr/home/}, 'never files/usr/home');
}

# A prefix with no sshd_config is not this app: no command, so no bare fallback.
{
	local $ENV{'PREFIX'} = "$root/nothing-here";
	is_deeply([ subs::sshd_command() ], [], 'a prefix without sshd_config produces no command');
	is_deeply([ subs::sshd_command('', "$home") ], [], 'an empty prefix produces no command');
}

# Android vs Linux. The suite runs on the Linux box, so the default answer must
# be "not Android", and each of the app's signals must be enough on its own.
is(subs::sshd_platform(), 0, 'a Linux box is not the Android app');
{
	local $ENV{'ANDROID_ROOT'} = '/system';
	is(subs::sshd_platform(), 1, 'ANDROID_ROOT marks the Android app');
}
{
	local $ENV{'JAWNOS_APP_PACKAGE'} = 'com.jawnos';
	is(subs::sshd_platform(), 1, 'the app package marks the Android app');
}

# Idempotence on this box: sshd_running is a live probe (this suite starts no
# daemon), so a start here is a no-op that never reaches exec.
ok(!subs::sshd_running($prefix), 'nothing is listening; the probe answers, not a pid file');
my $started = subs::sshd_start();
is($started, 0, 'sshd_start is a no-op on Linux even with a prefix to point at');

# The source must keep the ownership straight: President owns the start, Manager
# does not start one per worker, and the recovery script has no bare `sshd`.
my $president = do { local $/; open(my $fh, '<', "$FindBin::Bin/../perl/President.pl") or die $!; <$fh> };
my $jobs = do { local $/; open(my $fh, '<', "$FindBin::Bin/../perl/jobs.pl") or die $!; <$fh> };
my $manager = manager_source();
my $killer = do { local $/; open(my $fh, '<', "$FindBin::Bin/../scripts/manager_killer.pl") or die $!; <$fh> };
like($jobs, qr/&subs::sshd_start\(\)/, 'President starts sshd once per tree, now through the jobs table');
like($president, qr/name => 'sshd watcher'/, 'and keeps it up from a supervised loop');
unlike($manager, qr/subs::sshd_start\(\)/, 'Manager.pl does not start a daemon in every worker');
unlike($president, qr/^\s*`sshd`;/m, 'President.pl does not start a bare sshd at boot');
unlike($killer, qr/^\s*system\('sshd'\);/m, 'the recovery script has no bare sshd fallback');
like($killer, qr/&subs::sshd_start\(\)/, 'the recovery script uses the shared builder');

# The launcher itself, on this box, with a command that is not sshd. Two paths:
# setsid when the app ships it, a detached fork when it does not. A missing
# launcher used to be a silent no-start, so both are asserted here.
{
	my $dir = tempdir(CLEANUP => 1);
	my $out = "$dir/ran";
	my @cmd = ($^X, '-e', "open(my \$f, '>', '$out'); print \$f 'x'; close \$f");

	# (a) no setsid on PATH: the fork path must still run the command.
	my $bare = tempdir(CLEANUP => 1);
	local $ENV{'PATH'} = $bare;
	ok(!-x "$bare/setsid", 'the empty PATH has no setsid, so the fallback is what runs');
	is(subs::sshd_launch(@cmd), 1, 'the fork fallback reports a launch');
	my $deadline = time + 10;
	1 until (-e $out || time > $deadline);
	ok(-e $out, 'the fallback ran the command');

	# (b) setsid on PATH: it is preferred and still runs the command.
	unlink $out;
	my $with = tempdir(CLEANUP => 1);
	my $real = do { my $p; foreach my $d (split /:/, $ENV{'ORIGINAL_PATH'} || '/usr/bin:/bin') { if (-x "$d/setsid") { $p = "$d/setsid"; last } } $p };
	SKIP: {
		skip 'no setsid on this box to prefer', 2 unless defined $real;
		symlink($real, "$with/setsid") or skip "cannot stage setsid: $!", 2;
		local $ENV{'PATH'} = $with;
		is(subs::sshd_launch(@cmd), 1, 'setsid is used when it is there');
		my $until = time + 10;
		1 until (-e $out || time > $until);
		ok(-e $out, 'and it runs the command');
	}

	is(subs::sshd_launch(), 0, 'no command is not a launch');
}

# A daemon the launcher cannot exec must report 0, not a launch. The tablet spent
# hours believing sshd was starting every 60s because the fork path returned 1
# whatever the child did (2026-11-03).
{
	my $dir = tempdir(CLEANUP => 1);
	local $ENV{'PATH'} = $dir;
	is(subs::sshd_launch("$dir/no-such-daemon"), 0,
		'an exec that cannot find the daemon is not a launch');
	is(subs::sshd_launch('no-such-daemon-in-path'), 0,
		'a bare name that is not on PATH is not a launch');
}

# The watched loop has a warranty and a lease, or the manager reaps a healthy one.
is(subs::subprocessor_warranty_for('sshd watcher'), 'forever', 'the sshd watcher has a forever warranty');
is(subs::subprocessor_heartbeat_for('sshd watcher'), '5m', 'and a heartbeat lease longer than its turn');

done_testing();
