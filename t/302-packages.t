# tests-for: lib/JawnOS/Domain/Packages.pm lib/JawnOS/Routes/manager_packages.pm lib/JawnOS/Controller/manager_packages.pm public/js/manager/packages.js templates/apps/packages.html.ep lib/JawnOS/Routes.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Manager/Core1_tables_hooks.pm templates/start_menu/start_menu.html.ep perl/subroutines.pl qa/lib/Probe.pm perl/help/topics_apps.pl
# covers:    the package name rule, manager detection with a fake tool(), the
#            argv every action builds, the upload path guard, the sudo -n
#            refusal, the one-operation lock, the guest and confirm gates, and
#            the route/action table. Nothing here runs apt, dpkg or pacman.

use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use lib "$Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);

my $root = "$Bin/..";
require "$root/lib/JawnOS/Domain/Packages.pm";

# ---- the name rule ---------------------------------------------------------

foreach my $good (qw(vim libc6-dev g++ python3.12 foo:bar a zsh5), 'a' x 81) {
	my ($ok, $why) = subs::packages_validate_name($good);
	ok($ok, "name '$good' is accepted");
}
foreach my $bad ('', undef, 'two words', 'foo/bar', '-n', 'foo;rm -rf', 'foo`id`', "foo\nbar", 'a' x 82, ' foo') {
	my ($ok) = subs::packages_validate_name($bad);
	ok(!$ok, 'name ' . (defined $bad ? "'$bad'" : 'undef') . ' is refused');
}

# ---- detection -------------------------------------------------------------

my %APT = (
	'timeout' => '/usr/bin/timeout', 'sudo' => '/usr/bin/sudo',
	'apt' => '/usr/bin/apt', 'apt-get' => '/usr/bin/apt-get',
	'dpkg' => '/usr/bin/dpkg', 'dpkg-query' => '/usr/bin/dpkg-query',
	'apt-cache' => '/usr/bin/apt-cache',
);
my %ARCH = (
	'timeout' => '/usr/bin/timeout', 'sudo' => '/usr/bin/sudo',
	'pacman' => '/usr/bin/pacman', 'yay' => '/usr/bin/yay',
);

sub tool_for {
	my ($map) = @_;
	return sub { my ($name) = @_; return $map->{$name}; };
}

my $apt = subs::packages_detect({ tool => tool_for(\%APT), runtime => 'computer' });
is($apt->{'kind'}, 'apt', 'apt-get + dpkg is detected as apt');
is($apt->{'manager'}, 'apt', 'and apt is the manager');

my $arch = subs::packages_detect({ tool => tool_for(\%ARCH), runtime => 'computer' });
is($arch->{'kind'}, 'pacman', 'pacman is detected on Arch');
is($arch->{'aur'}, 'yay', 'a present AUR helper is named');

my $both = subs::packages_detect({
	tool => tool_for({ %ARCH, %APT }), runtime => 'computer',
});
is($both->{'kind'}, 'apt', 'when both answer, the Debian manager wins');

my $phone = subs::packages_detect({ tool => tool_for({}), runtime => 'mobile' });
is($phone->{'kind'}, 'runtime', 'a phone runtime is not a package manager');

my $none = subs::packages_detect({ tool => tool_for({}), runtime => 'computer' });
is($none->{'kind'}, 'none', 'a computer with no manager says so');

my $all = subs::packages_detect({
	tool => tool_for({ %ARCH, 'flatpak' => '/usr/bin/flatpak', 'snap' => '/usr/bin/snap',
		'pip3' => '/usr/bin/pip3', 'npm' => '/usr/bin/npm' }),
	runtime => 'computer',
});
is_deeply([ map { $_->{'name'} } @{ $all->{'backends'} } ],
	[qw(pacman aur flatpak snap pip npm)], 'every detected backend is reported in order');
is($all->{'kind'}, 'pacman', 'the machine manager stays first');

my $flat_only = subs::packages_detect({
	tool => tool_for({ 'timeout' => '/usr/bin/timeout', 'flatpak' => '/usr/bin/flatpak' }),
	runtime => 'computer',
});
is($flat_only->{'kind'}, 'flatpak', 'a machine with only flatpak still has a manager');
is($flat_only->{'manager'}, 'flatpak', 'and names it');

my $paru = subs::packages_detect({
	tool => tool_for({ 'pacman' => '/usr/bin/pacman', 'paru' => '/usr/bin/paru' }),
	runtime => 'computer',
});
is($paru->{'aur'}, 'paru', 'paru is the AUR helper when yay is absent');

# ---- the argv each action builds ------------------------------------------

my $tmp = tempdir(CLEANUP => 1);
my @calls;
my @log;

sub recording_runner {
	my ($response) = @_;
	@calls = ();
	return sub {
		push @calls, [@_];
		return $response ? $response->(@_) : { status => 0, output => '' };
	};
}

sub action_opts {
	my ($map, $runner) = @_;
	return {
		tool   => tool_for($map),
		runner => $runner,
		root   => 0,
		dir    => $tmp,
		logger => sub { push @log, $_[0] },
	};
}

my $update = subs::packages_update(action_opts(\%APT, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/apt-get update)],
	'apt update is sudo -n, bounded, and an argv list');
ok($update->{'ok'}, 'the update reports success');
like(join("\n", @log), qr{apt-get update}, 'the command is logged');

my $arch_update = subs::packages_update(action_opts(\%ARCH, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/pacman -Sy)],
	'pacman update refreshes the index only');

subs::packages_upgrade(action_opts(\%APT, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/apt-get -y upgrade)],
	'apt upgrade builds the -y upgrade command');
subs::packages_upgrade(action_opts(\%ARCH, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/pacman -Syu --noconfirm)],
	'pacman upgrade builds -Syu --noconfirm');

subs::packages_install('vim', action_opts(\%APT, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/apt-get install -y vim)],
	'install one validated name');
subs::packages_install('vim', action_opts(\%ARCH, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/pacman -S --noconfirm vim)],
	'pacman install is -S --noconfirm');

subs::packages_remove('vim', action_opts(\%APT, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/apt-get remove -y vim)],
	'remove is apt-get remove -y');
subs::packages_remove('vim', action_opts(\%ARCH, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/pacman -R --noconfirm vim)],
	'pacman remove is -R --noconfirm');

# ---- more backends ---------------------------------------------------------

my %FLATPAK = ('timeout' => '/usr/bin/timeout', 'flatpak' => '/usr/bin/flatpak');
my %SNAP = ('timeout' => '/usr/bin/timeout', 'sudo' => '/usr/bin/sudo', 'snap' => '/usr/bin/snap');
my %PIP = ('timeout' => '/usr/bin/timeout', 'pip3' => '/usr/bin/pip3');
my %NPM = ('timeout' => '/usr/bin/timeout', 'npm' => '/usr/bin/npm');

sub aur_opts {
	my ($runner) = @_;
	my $opts = action_opts(\%ARCH, $runner);
	$opts->{'backend'} = 'aur';
	return $opts;
}

subs::packages_install('thing', aur_opts(recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/yay -S --noconfirm thing)],
	'the AUR helper installs as the person, with no sudo');
unlike(join(' ', @{ $calls[0] }), qr/\bsudo\b/, 'yay is never wrapped in sudo');

subs::packages_purge('thing', aur_opts(recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/yay -Rns --noconfirm thing)],
	'the AUR helper purges with -Rns');

subs::packages_purge('vim', action_opts(\%APT, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/apt-get purge -y vim)],
	'apt purge is its own command');
subs::packages_purge('vim', action_opts(\%ARCH, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/pacman -Rns --noconfirm vim)],
	'pacman purge removes the configuration too');

subs::packages_install('org.example.App', action_opts(\%FLATPAK, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/flatpak install -y --noninteractive org.example.App)],
	'flatpak installs an app id without sudo');
subs::packages_purge('org.example.App', action_opts(\%FLATPAK, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/flatpak uninstall -y --delete-data org.example.App)],
	'flatpak purge deletes the app data');

subs::packages_install('firefox', action_opts(\%SNAP, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/snap install firefox)],
	'snap installs under sudo -n');
subs::packages_purge('firefox', action_opts(\%SNAP, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/snap remove --purge firefox)],
	'snap purge is remove --purge');

subs::packages_install('requests', action_opts(\%PIP, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/pip3 install --user requests)],
	'pip installs for the person');
subs::packages_remove('requests', action_opts(\%PIP, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/pip3 uninstall -y requests)],
	'pip removes without sudo');

subs::packages_install('left-pad', action_opts(\%NPM, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/npm install -g left-pad)],
	'npm installs globally');
subs::packages_install('@scope/pkg', action_opts(\%NPM, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/npm install -g @scope/pkg)],
	'a scoped npm name is accepted as one argv word');
my $npm_bad = subs::packages_install('../evil', action_opts(\%NPM, recording_runner()));
is($npm_bad->{'ok'}, 0, 'a path is not an npm package name');
is(scalar @calls, 0, 'and no argv was built for it');

my $snap_update = subs::packages_update(action_opts(\%SNAP, recording_runner()));
is($snap_update->{'ok'}, 1, 'snap update is an honest no-op');
is($snap_update->{'noop'}, 1, 'and says so');
is(scalar @calls, 0, 'without running a command');

my $bad = subs::packages_install('vim; rm -rf /', action_opts(\%APT, recording_runner()));
is($bad->{'ok'}, 0, 'an invalid name never reaches the manager');
is(scalar @calls, 0, 'and no argv was built for it');

# ---- reads -----------------------------------------------------------------

subs::packages_list(action_opts(\%APT, recording_runner()));
is_deeply($calls[0], ['/usr/bin/timeout', 300, '/usr/bin/dpkg-query', '-W',
	'-f=${binary:Package}\t${Version}\t${Installed-Size}\n'],
	'the installed list reads dpkg-query without sudo');
subs::packages_list(action_opts(\%ARCH, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/pacman -Q)],
	'the Arch installed list reads pacman -Q');

subs::packages_outdated(action_opts(\%APT, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/apt list --upgradable)],
	'apt reads the upgradable list');
subs::packages_outdated(action_opts(\%ARCH, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/pacman -Qu)],
	'pacman reads -Qu');

subs::packages_search('vim', action_opts(\%APT, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/apt-cache search vim)],
	'apt searches with apt-cache');
subs::packages_search('vim', action_opts(\%ARCH, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/timeout 300 /usr/bin/pacman -Ss vim)],
	'pacman searches with -Ss');

my $search_bad = subs::packages_search('vim apt-get update', action_opts(\%APT, recording_runner()));
is($search_bad->{'ok'}, 0, 'a search term is one word');

# ---- the installed-list parsing -------------------------------------------

my $list_runner = recording_runner(sub {
	return { status => 0, output => "vim\t9.1-1\t3200\nbash\t5.2\t7000\n" };
});
my $list = subs::packages_list(action_opts(\%APT, $list_runner));
is(scalar @{ $list->{'packages'} }, 2, 'two installed rows are parsed');
is($list->{'packages'}->[0]->{'name'}, 'vim', 'the first row names the package');
is($list->{'packages'}->[0]->{'size_kb'}, 3200, 'and carries its installed size in KB');

# ---- more backend parsers --------------------------------------------------

my $flat_list = subs::packages_list(action_opts(\%FLATPAK, recording_runner(sub {
	return { status => 0, output => "org.example.App\t1.4.2\n" };
})));
is($flat_list->{'packages'}->[0]->{'name'}, 'org.example.App', 'flatpak lists app ids');
is($flat_list->{'packages'}->[0]->{'version'}, '1.4.2', 'with their versions');

my $pip_list = subs::packages_list(action_opts(\%PIP, recording_runner(sub {
	return { status => 0, output => "requests==2.32.3\nclick==8.1.7\n" };
})));
is(scalar @{ $pip_list->{'packages'} }, 2, 'pip freeze rows are parsed');
is($pip_list->{'packages'}->[1]->{'name'}, 'click', 'the name is before ==');

my $npm_list = subs::packages_list(action_opts(\%NPM, recording_runner(sub {
	return { status => 0, output => '{"dependencies":{"left-pad":{"version":"1.3.0"}}}' };
})));
is($npm_list->{'packages'}->[0]->{'name'}, 'left-pad', 'npm JSON rows are parsed');
is($npm_list->{'packages'}->[0]->{'version'}, '1.3.0', 'with the installed version');

my $pip_out = subs::packages_outdated(action_opts(\%PIP, recording_runner(sub {
	return { status => 0, output => '[{"name":"requests","version":"2.31.0","latest_version":"2.32.3"}]' };
})));
is($pip_out->{'packages'}->[0]->{'from'}, '2.31.0', 'pip outdated carries the old version');
is($pip_out->{'packages'}->[0]->{'version'}, '2.32.3', 'and the new one');

my $npm_out = subs::packages_outdated(action_opts(\%NPM, recording_runner(sub {
	return { status => 1, output => '{"left-pad":{"current":"1.2.0","latest":"1.3.0"}}' };
})));
is($npm_out->{'ok'}, 1, 'npm exit 1 with a JSON body is an outdated list, not a fault');
is($npm_out->{'packages'}->[0]->{'name'}, 'left-pad', 'and the row is parsed');

my $flat_search = subs::packages_search('app', action_opts(\%FLATPAK, recording_runner(sub {
	return { status => 0, output => "Example\torg.example.App\t1.4.2\tan example\n" };
})));
is($flat_search->{'packages'}->[0]->{'name'}, 'org.example.App', 'flatpak search installs by app id');

# ---- the upload path -------------------------------------------------------

my $upload = "$tmp/packages-upload";
mkdir $upload or die $! unless -d $upload;
my $deb = "$upload/thing.deb";
write_file($deb, "not really a deb\n");

@calls = ();
subs::packages_install_file($deb, action_opts(\%APT, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/dpkg -i), $deb],
	'a .deb goes to dpkg -i');

my $archpkg = "$upload/thing.pkg.tar.zst";
write_file($archpkg, "not really a package\n");
@calls = ();
subs::packages_install_file($archpkg, action_opts(\%ARCH, recording_runner()));
is_deeply($calls[0], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/pacman -U --noconfirm), $archpkg],
	'an Arch package goes to pacman -U');

my $outside = subs::packages_install_file('/etc/passwd', action_opts(\%APT, recording_runner()));
is($outside->{'ok'}, 0, 'a path outside the upload is refused');
like($outside->{'error'}, qr/outside the upload/, 'and says why');

my $txt = "$upload/notes.txt";
write_file($txt, "hello\n");
my $wrong = subs::packages_install_file($txt, action_opts(\%APT, recording_runner()));
is($wrong->{'ok'}, 0, 'a file apt cannot install is refused');
like($wrong->{'error'}, qr/\.deb/, 'and names the kind it wants');

# dpkg -i failing on a missing dependency triggers the apt-get -f install fix.
my @fix_calls;
my $dependency_runner = sub {
	my @argv = @_;
	push @fix_calls, [@argv];
	return { status => 1, output => "dpkg: dependency problems prevent configuration of thing\n" }
		if grep { $_ eq '-i' } @argv;
	return { status => 0, output => "fixed\n" };
};
subs::packages_install_file($deb, action_opts(\%APT, $dependency_runner));
is(scalar @fix_calls, 2, 'a dependency failure runs a second command');
is_deeply($fix_calls[1], [qw(/usr/bin/sudo -n /usr/bin/timeout 300 /usr/bin/apt-get -y -f install)],
	'and the fix is apt-get -y -f install');

# ---- sudo refused ----------------------------------------------------------

# The real capture path, with a harmless child: no shell, both pipes read.
my $captured = subs::packages_run({ argv => ['/bin/echo', 'hello'], max_lines => 5 });
ok($captured->{'ok'}, 'the real capture runs a plain argv');
is($captured->{'output'}, 'hello', 'and reads its child\'s line');

my $refused = subs::packages_update(action_opts(\%APT, recording_runner(sub {
	return { status => 1, output => "sudo: a password is required\n" };
})));
is($refused->{'ok'}, 0, 'a refused sudo fails the action');
is($refused->{'needs_root'}, 1, 'and is reported as needing root');

# ---- one operation at a time ----------------------------------------------

my $lock_dir = tempdir(CLEANUP => 1);
my $first = subs::packages_lock_take({ dir => $lock_dir });
is($first->{'ok'}, 1, 'the first operation takes the lock');
my $second = subs::packages_lock_take({ dir => $lock_dir });
is($second->{'ok'}, 0, 'a second operation is refused while it is held');
is($second->{'busy'}, 1, 'and is told the lock is busy');
subs::packages_lock_drop($first);
my $third = subs::packages_lock_take({ dir => $lock_dir });
is($third->{'ok'}, 1, 'the lock is taken again once dropped');
subs::packages_lock_drop($third);

my $lock_path = "$lock_dir/packages.lock";
write_file($lock_path, "pid=1 at=0\n");
utime(time - 4000, time - 4000, $lock_path);
my $stale = subs::packages_lock_take({ dir => $lock_dir });
is($stale->{'ok'}, 1, 'an old lock left by a crash is cleared');
subs::packages_lock_drop($stale);

# Two real actions racing: the second gets the busy answer, not a command.
my $held = subs::packages_lock_take({ dir => $tmp });
my $busy = subs::packages_update(action_opts(\%APT, recording_runner()));
is($busy->{'ok'}, 0, 'an action cannot start while the lock is held');
is($busy->{'busy'}, 1, 'and says another operation is running');
subs::packages_lock_drop($held);

# ---- the runtime listing ---------------------------------------------------

my $bin = tempdir(CLEANUP => 1);
write_file("$bin/one", "#!/bin/sh\n");
chmod 0755, "$bin/one";
write_file("$bin/notes", "not a binary\n");
my $runtime = subs::packages_runtime_listing({ bin_dir => $bin });
is($runtime->{'read_only'}, 1, 'a runtime listing is read-only');
is_deeply([ map { $_->{'name'} } @{ $runtime->{'packages'} } ], ['one'],
	'only the executable the runtime ships is listed');
like($runtime->{'note'}, qr/no package manager/, 'and the note says there is no manager');

# ---- the phone's runtime ---------------------------------------------------

my $phone_status = subs::packages_status({
	%{ action_opts({}, recording_runner()) },
	runtime => 'mobile',
	bin_dir => $bin,
});
is($phone_status->{'read_only'}, 1, 'a phone runtime status is read-only');
like($phone_status->{'runtime_note'}, qr/prebuilt runtime/, 'and explains what the runtime is');
ok(scalar @{ $phone_status->{'runtime_can'} || [] } >= 2, 'and names what the person can do');

my $phone_install = subs::packages_install('vim', {
	%{ action_opts({}, recording_runner()) },
	runtime => 'mobile',
});
is($phone_install->{'ok'}, 0, 'a phone runtime refuses an install');
is($phone_install->{'read_only'}, 1, 'as a read-only answer');
like($phone_install->{'error'}, qr/prebuilt runtime/, 'and says why in words');
like($phone_install->{'note'}, qr/terminal/, 'and points at the terminal it does have');
is(scalar @calls, 0, 'without running a command');

# ---- status ----------------------------------------------------------------

my $version_runner = sub {
	my @argv = @_;
	return { status => 0, output => "apt 2.9.14 (amd64)\n" } if grep { $_ eq '--version' } @argv;
	return { status => 0, output => '' };
};
my $status = subs::packages_status(action_opts(\%APT, $version_runner));
is($status->{'manager_version'}, '2.9.14', 'the status reports the manager version');
is($status->{'kind'}, 'apt', 'and its kind');

# ---- the private OpenSSL layer --------------------------------------------
#
# The ODROID Go Ultra runs RetroArch built against OpenSSL 4 while the
# distribution packages 3.6. The installer stages libssl/libcrypto 4 under
# /opt/openssl4 with a manifest and an ld.so.conf, and the app has to see the
# layer, name it, and remove only what the manifest owns when an upgrade makes
# it redundant. Every path below is a temp directory and every binary a fake;
# no pacman, ldconfig or real /opt entry is touched.

my @COMPAT_ENV = qw(JAWNOS_OPENSSL_COMPAT_DIR JAWNOS_OPENSSL_COMPAT_ROOT
	JAWNOS_OPENSSL_LDCONF JAWNOS_OPENSSL_LDCONFIG JAWNOS_OPENSSL_PACMAN);

sub compat_env {
	my (%set) = @_;
	delete $ENV{$_} for @COMPAT_ENV;
	$ENV{$_} = $set{$_} for keys %set;
	return;
}

sub fake_binary {
	my ($path, $body) = @_;
	write_file($path, "#!/bin/sh\n$body\n");
	chmod 0755, $path;
	return $path;
}

sub make_compat_layer {
	my ($base) = @_;
	my $dir = "$base/openssl4";
	make_path("$dir/usr/lib");
	my $lib = "$dir/usr/lib";
	write_file("$lib/libssl.so.4", "ssl\n");
	write_file("$lib/libcrypto.so.4", "crypto\n");
	write_file("$lib/libssl.so.99", "not named by the manifest\n");
	write_file("$dir/jawnos-compat.json",
		'{"sonames":["libssl.so.4","libcrypto.so.4"],'
		. '"source":"openssl-4.1.0-1-aarch64.pkg.tar.xz",'
		. '"binary":"/usr/bin/retroarch","created":1790000000}');
	my $conf = "$base/openssl4.conf";
	write_file($conf, "$lib\n");
	return ($dir, $lib, $conf);
}

my $orig_path = $ENV{'PATH'};

# The manager user is not root, so the clear must go through sudo -n like the
# upgrade does. This tool map has no sudo entry, leaving the lookup to PATH,
# where each scenario puts a fake: one that logs its argv and runs it, or one
# that refuses the way sudo does without a password.
my %ARCH_NO_SUDO = %ARCH;
delete $ARCH_NO_SUDO{'sudo'};

sub fake_sudo {
	my ($base, $log) = @_;
	my $bin = "$base/bin";
	make_path($bin);
	fake_binary("$bin/sudo",
		"printf '%s\\n' \"\$*\" >> '$log'\nif [ \"\$1\" = \"-n\" ]; then shift; fi\nexec \"\$@\"");
	return $bin;
}

sub fake_sudo_refuse {
	my ($base, $log) = @_;
	my $bin = "$base/bin";
	make_path($bin);
	fake_binary("$bin/sudo",
		"printf '%s\\n' \"\$*\" >> '$log'\necho 'sudo: a password is required' >&2\nexit 1");
	return $bin;
}

{
	local %ENV = %ENV;

	# Absent: no manifest anywhere the convention would look.
	compat_env(JAWNOS_OPENSSL_COMPAT_ROOT => $tmp);
	my $absent = subs::packages_openssl_compat(action_opts(\%ARCH, recording_runner()));
	is($absent->{'present'}, 0, 'a directory without a manifest is not a layer');
	is_deeply($absent->{'layers'}, [], 'and no layer is reported');

	# Present: a temp /opt/openssl4 with the manifest the installer writes.
	my $base = tempdir(CLEANUP => 1);
	my ($dir, $lib, $conf) = make_compat_layer($base);
	compat_env(JAWNOS_OPENSSL_COMPAT_DIR => $dir);
	my $openssl_runner = sub {
		my @argv = @_;
		return { status => 0, output => "openssl 3.6.5-1\n" } if grep { $_ eq 'openssl' } @argv;
		return { status => 0, output => '' };
	};
	my $compat = subs::packages_openssl_compat(action_opts(\%ARCH, $openssl_runner));
	is($compat->{'present'}, 1, 'a manifest makes the layer visible');
	is(scalar @{ $compat->{'layers'} }, 1, 'one layer is reported');
	is_deeply($compat->{'layers'}->[0]->{'sonames'}, [qw(libssl.so.4 libcrypto.so.4)],
		'only the sonames the manifest owns are reported');
	is($compat->{'system_version'}, '3.6.5', 'the installed openssl version is read');
	like($compat->{'layers'}->[0]->{'note'}, qr/\Q$dir\E/, 'the note names the layer path');
	like($compat->{'layers'}->[0]->{'note'}, qr/3\.6\.5/, 'and the system openssl version');

	# The status route's JSON comes from packages_status, so the layer travels
	# with it without the controller adding anything.
	my $compat_status = subs::packages_status(action_opts(\%ARCH, $openssl_runner));
	is(ref $compat_status->{'openssl_compat'}, 'HASH', 'the status carries the layer read');
	is($compat_status->{'openssl_compat'}->{'present'}, 1, 'and the layer is present in it');

	# Clear: the manifest's sonames and conf go through sudo -n, and a file it
	# does not name stays.
	my $ldconfig_ran = "$base/ldconfig.ran";
	my $ldconfig = fake_binary("$base/ldconfig", "echo ran > '$ldconfig_ran'");
	my $pacman = fake_binary("$base/pacman", 'exit 1');
	my $sudo_log = "$base/sudo.log";
	my $sudo_bin = fake_sudo($base, $sudo_log);
	$ENV{'PATH'} = "$sudo_bin:$orig_path";
	compat_env(
		JAWNOS_OPENSSL_COMPAT_DIR => $dir,
		JAWNOS_OPENSSL_LDCONF    => $conf,
		JAWNOS_OPENSSL_LDCONFIG  => $ldconfig,
		JAWNOS_OPENSSL_PACMAN    => $pacman,
	);
	my $clear = subs::packages_openssl_compat_clear(action_opts(\%ARCH_NO_SUDO, recording_runner()));
	is($clear->{'ok'}, 1, 'a manifest-owned layer is cleared');
	ok(!-e "$lib/libssl.so.4", 'libssl.so.4 is removed');
	ok(!-e "$lib/libcrypto.so.4", 'libcrypto.so.4 is removed');
	ok(-e "$lib/libssl.so.99", 'a soname the manifest does not name is left alone');
	ok(!-e "$dir/jawnos-compat.json", 'the manifest is removed');
	ok(!-e $conf, 'the ld.so.conf the convention names is removed');
	ok(-e $lib, 'the directory stays while a file the manifest does not name is inside');
	ok(-e $ldconfig_ran, 'ldconfig is run after the removal');
	is($clear->{'ldconfig'}, 'ran', 'and its run is reported');
	my $elevated = read_file($sudo_log);
	like($elevated, qr{-f -- \Q$lib/libssl.so.4\E}, 'the soname removal is one elevated argv');
	like($elevated, qr{-f -- \Q$lib/libcrypto.so.4\E}, 'and so is the other soname');
	like($elevated, qr/\Q$ldconfig\E/, 'ldconfig runs through the same sudo -n path');
	like($elevated, qr{rmdir -- \Q$lib\E}, 'the empty directories are removed the same way');
	my $again = subs::packages_openssl_compat_clear(action_opts(\%ARCH_NO_SUDO, recording_runner()));
	is($again->{'ok'}, 1, 'a second clear is a no-op');
	is_deeply($again->{'removed'}, [], 'that removes nothing');

	# A file a package owns is never deleted; the whole clear is refused.
	my $owned_base = tempdir(CLEANUP => 1);
	my ($owned_dir, $owned_lib, $owned_conf) = make_compat_layer($owned_base);
	my $owned_list = "$owned_base/owned.txt";
	write_file($owned_list, "$owned_lib/libcrypto.so.4\n");
	my $owned_marker = "$owned_base/ldconfig.ran";
	my $owned_ldconfig = fake_binary("$owned_base/ldconfig", "echo ran > '$owned_marker'");
	my $owned_pacman = fake_binary("$owned_base/pacman",
		"grep -qxF \"\$2\" '$owned_list' 2>/dev/null");
	my $owned_sudo = fake_sudo_refuse($owned_base, "$owned_base/sudo.log");
	$ENV{'PATH'} = "$owned_sudo:$orig_path";
	compat_env(
		JAWNOS_OPENSSL_COMPAT_DIR => $owned_dir,
		JAWNOS_OPENSSL_LDCONF    => $owned_conf,
		JAWNOS_OPENSSL_LDCONFIG  => $owned_ldconfig,
		JAWNOS_OPENSSL_PACMAN    => $owned_pacman,
	);
	my $refused = subs::packages_openssl_compat_clear(action_opts(\%ARCH_NO_SUDO, recording_runner()));
	is($refused->{'ok'}, 0, 'a file a package owns refuses the clear');
	like($refused->{'error'}, qr/owned by a package/, 'and says why in words');
	ok(-e "$owned_lib/libssl.so.4" && -e "$owned_lib/libcrypto.so.4", 'nothing at all was removed');
	ok(-e "$owned_dir/jawnos-compat.json", 'the manifest is still there');
	ok(!-e $owned_marker, 'ldconfig did not run');

	# A refused sudo removes nothing and says so in the app's own words.
	my $root_base = tempdir(CLEANUP => 1);
	my ($root_dir, $root_lib, $root_conf) = make_compat_layer($root_base);
	my $root_marker = "$root_base/ldconfig.ran";
	my $root_log = "$root_base/sudo.log";
	my $root_sudo = fake_sudo_refuse($root_base, $root_log);
	$ENV{'PATH'} = "$root_sudo:$orig_path";
	compat_env(
		JAWNOS_OPENSSL_COMPAT_DIR => $root_dir,
		JAWNOS_OPENSSL_LDCONF    => $root_conf,
		JAWNOS_OPENSSL_LDCONFIG  => fake_binary("$root_base/ldconfig", "echo ran > '$root_marker'"),
		JAWNOS_OPENSSL_PACMAN    => fake_binary("$root_base/pacman", 'exit 1'),
	);
	my $no_root = subs::packages_openssl_compat_clear(action_opts(\%ARCH_NO_SUDO, recording_runner()));
	is($no_root->{'ok'}, 0, 'a refused sudo -n stops the clear');
	is($no_root->{'error'},
		'this needs root, and sudo -n was refused (no password prompt is shown)',
		'with the sudo wording every other write uses');
	ok(-e "$root_lib/libssl.so.4" && -e "$root_lib/libcrypto.so.4", 'nothing at all was removed');
	ok(-e "$root_dir/jawnos-compat.json", 'the manifest is still there');
	ok(!-e $root_marker, 'ldconfig did not run');
	my $root_tried = read_file($root_log);
	unlike($root_tried, qr/\brm\b|ldconfig|rmdir/, 'and no removal argv was built');

	# A successful upgrade replaces the layer; a failed one leaves it alone.
	my $up_base = tempdir(CLEANUP => 1);
	my ($up_dir, $up_lib, $up_conf) = make_compat_layer($up_base);
	my $up_ldconfig = fake_binary("$up_base/ldconfig", 'exit 0');
	my $up_pacman = fake_binary("$up_base/pacman", 'exit 1');
	my $up_log = "$up_base/sudo.log";
	my $up_sudo = fake_sudo($up_base, $up_log);
	$ENV{'PATH'} = "$up_sudo:$orig_path";
	compat_env(
		JAWNOS_OPENSSL_COMPAT_DIR => $up_dir,
		JAWNOS_OPENSSL_LDCONF    => $up_conf,
		JAWNOS_OPENSSL_LDCONFIG  => $up_ldconfig,
		JAWNOS_OPENSSL_PACMAN    => $up_pacman,
	);
	my $up_runner = sub {
		my @argv = @_;
		return { status => 0, output => "openssl 4.1.0-1\n" } if grep { $_ eq '-Q' } @argv;
		return { status => 0, output => '' };
	};
	my $upgrade = subs::packages_upgrade(action_opts(\%ARCH_NO_SUDO, $up_runner));
	is($upgrade->{'ok'}, 1, 'the upgrade succeeds');
	is(ref $upgrade->{'openssl_compat'}, 'HASH', 'its answer carries the layer result');
	is($upgrade->{'openssl_compat'}->{'ok'}, 1, 'and the now-redundant layer was cleared');
	ok(!-e "$up_dir/jawnos-compat.json", 'the manifest is gone with the layer');
	like(read_file($up_log), qr{-f -- \Q$up_lib/libssl.so.4\E}, 'the upgrade clear used the elevated argv');

	my $fail_base = tempdir(CLEANUP => 1);
	my ($fail_dir, $fail_lib, $fail_conf) = make_compat_layer($fail_base);
	my $fail_log = "$fail_base/sudo.log";
	my $fail_sudo = fake_sudo_refuse($fail_base, $fail_log);
	$ENV{'PATH'} = "$fail_sudo:$orig_path";
	compat_env(
		JAWNOS_OPENSSL_COMPAT_DIR => $fail_dir,
		JAWNOS_OPENSSL_LDCONF    => $fail_conf,
		JAWNOS_OPENSSL_LDCONFIG  => fake_binary("$fail_base/ldconfig", 'exit 0'),
		JAWNOS_OPENSSL_PACMAN    => fake_binary("$fail_base/pacman", 'exit 1'),
	);
	my $fail_runner = sub { return { status => 1, output => "error: failed to commit transaction\n" }; };
	my $failed = subs::packages_upgrade(action_opts(\%ARCH_NO_SUDO, $fail_runner));
	is($failed->{'ok'}, 0, 'a failed upgrade is reported as failed');
	ok(-e "$fail_dir/jawnos-compat.json", 'and the private layer is left exactly as it was');
	ok(!exists $failed->{'openssl_compat'}, 'with no clear attempted');
	ok(!-e $fail_log, 'and sudo was never asked');
}

# ---- the session gates -----------------------------------------------------
#
# The controller's gate helpers are the whole refusal path; a fake controller
# stands in for Mojo so no app is booted for one answer.
{
	no warnings 'redefine';
	package subs;
	our $guest_refuse = 0;
	our @logged;
	sub guest_browser_session { return $guest_refuse ? 1 : 0; }
	sub ui { return $_[0]; }
	sub log_writer { push @logged, $_[0]; return $_[0]; }
	package main;
}

require "$root/lib/JawnOS/Controller/manager_packages.pm";

package FakePackagesController;
sub new {
	my ($class, %args) = @_;
	return bless {
		session  => $args{'session'}  || {},
		param    => $args{'param'}    || {},
		rendered => [],
	}, $class;
}
sub session { my ($self, $key) = @_; return $self->{'session'}->{$key}; }
sub param   { my ($self, $key) = @_; return $self->{'param'}->{$key}; }
sub render  { my ($self, %args) = @_; push @{ $self->{'rendered'} }, \%args; return; }
package main;

my $guest = FakePackagesController->new(
	session => { authentication => 'approved', privilege => 'guest', source => 'browser' });
$subs::guest_refuse = 1;
is(Manager::packages_reading_gate($guest, 'test'), 0, 'a guest browser is refused');
is($guest->{'rendered'}->[0]->{'status'}, 403, 'with a 403');
$subs::guest_refuse = 0;

my $anon = FakePackagesController->new(session => {});
is(Manager::packages_reading_gate($anon, 'test'), 0, 'an unapproved session is refused');

my $house = FakePackagesController->new(
	session => { authentication => 'approved', privilege => 'resident', source => 'browser' });
is(Manager::packages_reading_gate($house, 'test'), 1, 'an approved house session may read');

my $unconfirmed = FakePackagesController->new(
	session => { authentication => 'approved', privilege => 'citizen', source => 'browser' },
	param   => {});
is(Manager::packages_write_gate($unconfirmed, 'install'), 0, 'a write without confirm=1 is refused');
is($unconfirmed->{'rendered'}->[0]->{'status'}, 400, 'with a 400');

my $confirmed = FakePackagesController->new(
	session => { authentication => 'approved', privilege => 'citizen', source => 'browser' },
	param   => { confirm => '1' });
is(Manager::packages_write_gate($confirmed, 'install'), 1, 'confirm=1 lets the write run');

# ---- the route and action table -------------------------------------------

require "$root/lib/JawnOS/Routes/manager_packages.pm";
my @routes = JawnOS::Routes::manager_packages->routes();
is(scalar @routes, 11, 'the app registers eleven routes');
my %expected = (
	54020 => ['get',  '/manager/packages'],
	54021 => ['get',  '/manager/packages/status'],
	54022 => ['get',  '/manager/packages/list'],
	54023 => ['get',  '/manager/packages/outdated'],
	54024 => ['get',  '/manager/packages/search'],
	54025 => ['post', '/manager/packages/update'],
	54026 => ['post', '/manager/packages/upgrade'],
	54027 => ['post', '/manager/packages/install'],
	54028 => ['post', '/manager/packages/remove'],
	54029 => ['post', '/manager/packages/file'],
	54030 => ['post', '/manager/packages/purge'],
);
for my $row (@routes) {
	my ($id, $method, $path, $action) = @$row;
	ok($expected{$id}, "route id $id is one the app declares");
	is_deeply([ $method, $path ], $expected{$id}, "route $id has the expected method and path");
	is($action, "action_$id", "route $id names action_$id");
	ok(defined &{"Manager::$action"}, "action_$id is defined in the controller");
}
my %ids = map { $_->[0] => 1 } @routes;
is_deeply([ sort { $a <=> $b } keys %ids ], [ sort { $a <=> $b } keys %expected ],
	'no route id is used twice');

my $routes_pm = read_file("$root/lib/JawnOS/Routes.pm");
like($routes_pm, qr/\bmanager_packages\b/, 'the route module is in @NAMES');
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/Domain::Packages' for qw\([^)]*\bpackages_install\b/, 'the domain subs are in the loader');
like(read_file("$root/perl/subroutines.pl"),
	qr{manager/\(\?:configure\|security\|magazine/publish\|packages\|power\)}, 'the tier table keeps packages at citizen');
like(read_file("$root/qa/lib/Probe.pm"),
	qr{configure\|security\|magazine/publish\|packages\|power}, 'and the probe mirror agrees');

# ---- the front end ---------------------------------------------------------

my $menu = read_file("$root/templates/start_menu/start_menu.html.ep");
like($menu, qr/id="packages_toggle"/, 'the start menu carries a Packages icon');
my $core = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");
like($core, qr/^\tpackages\s+=> \[qw\(\/js\/manager\/packages\.js\)\]/m, 'the lazy chunk names its file');
like($core, qr/^\tpackages\s+=> \[qw\(packagesOpener\)\]/m, 'the entry function is mapped');
like($core, qr/packages_toggle => 'packages'/, 'the toggle is mapped');
my $js = read_file("$root/public/js/manager/packages.js");
like($js, qr/function packagesOpener/, 'the chunk defines the opener');
like($js, qr#/manager/packages/list#, 'the chunk reads the installed list');
like($js, qr/confirm:\s*1/, 'every write sends confirm=1');
unlike($js, qr/'(?:apt-get|pacman|dpkg)\\b/, 'the browser never names a package command');
my $template = read_file("$root/templates/apps/packages.html.ep");
like($template, qr/hint="<%= &subs::ui\('Upgrade every outdated package'\) %>"/,
	'the upgrade button carries its hint');
like($js, qr#/manager/packages/purge#, 'the chunk has its own purge request');
like($js, qr/window\.JawnDesktop/, 'a write refuses outside the desktop window');
like($js, qr/packagesBackend/, 'the chunk sends the chosen backend');
like($template, qr/id="packages_backend"/, 'the page offers the backend selector');
like($template, qr/prebuilt runtime/, 'the runtime case explains itself');
like($loader, qr/\bpackages_purge\b/, 'the purge helper is in the domain loader');
like(read_file("$root/perl/help/topics_apps.pl"), qr/app => 'packages'/, 'the help topic names the app');

# The local OpenSSL layer is a note on the page, a read on the status route and
# a domain pair the loader maps; each has to stay wired to the others.
like($loader, qr/\bpackages_openssl_compat\b/, 'the domain loader maps the layer read');
like($loader, qr/\bpackages_openssl_compat_clear\b/, 'and the layer clear');
like(read_file("$root/lib/JawnOS/Controller/manager_packages.pm"), qr/subs::packages_status/,
	'the status route answers the domain status, which carries the layer');
like($template, qr/id="packages_openssl_note"/, 'the page carries the layer note');
like($js, qr/function packagesRenderCompat/, 'the chunk renders the layer note');
like($js, qr#/manager/packages/status#, 'and reads it from the status route');
like(read_file("$root/perl/help/topics_apps.pl"), qr/private library layer/,
	'the help topic explains the layer in the on-screen words');

done_testing();
