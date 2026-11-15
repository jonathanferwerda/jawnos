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

# ---- status ----------------------------------------------------------------

my $version_runner = sub {
	my @argv = @_;
	return { status => 0, output => "apt 2.9.14 (amd64)\n" } if grep { $_ eq '--version' } @argv;
	return { status => 0, output => '' };
};
my $status = subs::packages_status(action_opts(\%APT, $version_runner));
is($status->{'manager_version'}, '2.9.14', 'the status reports the manager version');
is($status->{'kind'}, 'apt', 'and its kind');

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
is(scalar @routes, 10, 'the app registers ten routes');
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
like(read_file("$root/perl/help/topics_apps.pl"), qr/app => 'packages'/, 'the help topic names the app');

done_testing();
