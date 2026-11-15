package subs;

# Packages: the software a machine runs, seen and changed through one app.
#
# The app asks the machine what it is instead of assuming: a Debian or Ubuntu
# box answers apt + dpkg, an Arch box answers pacman (and yay or paru for the
# AUR), and other machines may answer flatpak, snap, pip3 or npm. A phone's
# prebuilt runtime answers none - it ships binaries but no package manager, and
# the app lists them read-only rather than pretending to install.
#
# Every command is an argv list. Nothing here is interpolated into a shell, a
# package name is checked against a closed pattern first, and every mutating
# run that needs root is one `sudo -n` command with a bounded timeout. A refused
# password prompt is reported, never waited on. One operation at a time is the
# lock file under the runtime directory, taken with O_EXCL. AUR helpers (yay,
# paru) and the per-user managers (flatpak, pip, npm) are never wrapped in sudo:
# they do their own privilege handling, and running them as root would be worse.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.

use strict;
use warnings;
use utf8;

use File::Basename ();
use File::Spec ();
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);

# A package operation may take 300 seconds (a kernel upgrade on a small machine
# can), and the panel only ever shows the tail of what it said.
our $packages_timeout_seconds = 300;
our $packages_output_lines    = 200;
our $packages_list_cap        = 2000;
our $packages_search_cap      = 100;
our $packages_lock_stale      = 1800;
our $packages_memory_cap      = 4_000_000;

# One package name, one search term. The pattern is deliberately narrow: a
# leading letter or digit, then letters, digits and the separators real package
# names use. A colon is an Arch repo/package split; a hyphen and a dot are
# ordinary; anything else (a space, a slash, a semicolon) is refused.
our $packages_name_pattern = qr/^[A-Za-z0-9][A-Za-z0-9+._:-]{0,80}$/;

# The usual homes, tried when PATH does not answer. The manager's PATH is not
# a login shell's, and a worker started by the master has the same problem the
# print seam fixed for CUPS.
my @PACKAGE_DIRS = qw(/usr/bin /usr/sbin /usr/local/bin /bin /sbin);

# ---- detection -------------------------------------------------------------

# A fixed tool name, looked up. The name is never caller text, and a shell is
# never built from it.
sub packages_tool {
	my ($name) = @_;
	return undef unless defined $name && $name =~ /^[A-Za-z0-9][A-Za-z0-9_.+-]*$/;
	my $path = eval {
		require JawnOS::Platform;
		JawnOS::Platform::tool_path($name);
	};
	return $path if defined $path && length $path;
	foreach my $dir (@PACKAGE_DIRS) {
		my $candidate = "$dir/$name";
		return $candidate if -f $candidate && -x $candidate;
	}
	return undef;
}

# What kind of machine this is. device_setter() has the same mobile test, but a
# domain module may be loaded before Say.pm, and a test must be able to say.
sub packages_runtime_kind {
	my ($opts) = @_;
	$opts ||= {};
	return $opts->{'runtime'} if defined $opts->{'runtime'} && length $opts->{'runtime'};
	return 'mobile' if -e '/system/bin/init' || $ENV{'ANDROID_ROOT'} || $ENV{'TERMUX_VERSION'};
	return 'mobile' if -d '/data/data/com.termux/files/usr';
	return 'computer';
}

# The fixed tool names the app looks for. The name is never caller text.
my @PACKAGE_TOOL_NAMES = qw(
	apt apt-get dpkg dpkg-query apt-cache pacman yay paru
	flatpak snap pip3 npm
);

# The label a backend carries on screen. The controller and the template use
# this instead of matching backend names themselves.
my %PACKAGE_BACKEND_LABEL = (
	apt     => 'Debian or Ubuntu packages',
	pacman  => 'Arch packages',
	aur     => 'AUR packages',
	flatpak => 'Flatpak apps',
	snap    => 'Snap packages',
	pip     => 'Python packages (pip)',
	npm     => 'Node packages (npm)',
);

sub packages_backend_label {
	my ($name) = @_;
	return defined $name && length $name ? ($PACKAGE_BACKEND_LABEL{$name} // $name) : '';
}

# Which managers exist and which one the app will use. apt wins when both answer
# because a Debian box whose user installed pacman for a chroot still has apt as
# its own manager; the other one is reported, never guessed at. Every backend is
# returned in preference order: the machine's own manager, the AUR helper, then
# the system and language managers that coexist with it.
sub packages_detect {
	my ($opts) = @_;
	$opts ||= {};
	my $tool = $opts->{'tool'} || \&packages_tool;
	my $runtime = &packages_runtime_kind($opts);

	my %path;
	foreach my $name (@PACKAGE_TOOL_NAMES) {
		my $found = $tool->($name);
		$path{$name} = $found if defined $found && length $found;
	}

	my @backends;
	my $aur = '';
	if ($runtime ne 'mobile') {
		if ($path{'apt-get'} && $path{'dpkg'}) {
			push @backends, { name => 'apt', kind => 'apt', tool => $path{'apt-get'}, tools => \%path, elevated => 1 };
		}
		if ($path{'pacman'}) {
			push @backends, { name => 'pacman', kind => 'pacman', tool => $path{'pacman'}, tools => \%path, elevated => 1 };
			# An AUR helper must run as the person, not under sudo: yay and paru
			# escalate for the package step themselves.
			$aur = $path{'yay'} ? 'yay' : ($path{'paru'} ? 'paru' : '');
			push @backends, { name => 'aur', kind => 'aur', tool => $path{$aur}, helper => $aur, tools => \%path, elevated => 0 }
				if length $aur;
		}
		push @backends, { name => 'flatpak', kind => 'flatpak', tool => $path{'flatpak'}, tools => \%path, elevated => 0 }
			if $path{'flatpak'};
		push @backends, { name => 'snap', kind => 'snap', tool => $path{'snap'}, tools => \%path, elevated => 1 }
			if $path{'snap'};
		push @backends, { name => 'pip', kind => 'pip', tool => $path{'pip3'}, tools => \%path, elevated => 0 }
			if $path{'pip3'};
		push @backends, { name => 'npm', kind => 'npm', tool => $path{'npm'}, tools => \%path, elevated => 0 }
			if $path{'npm'};
	}

	# A phone's runtime ships a bin/ prefix and no manager; saying 'runtime' is
	# the honest answer even when a busybox-looking binary happens to match.
	my $kind = $runtime eq 'mobile' ? 'runtime' : (@backends ? $backends[0]->{'kind'} : 'none');
	my $manager = @backends ? $backends[0]->{'name'} : '';

	return {
		ok       => 1,
		runtime  => $runtime,
		kind     => $kind,
		manager  => $manager,
		aur      => $aur,
		tools    => \%path,
		backends => \@backends,
	};
}

# The backend a request names, or the machine's first choice. A name that is
# not in the detected list is refused rather than silently mapped to the first.
sub packages_backend {
	my ($name, $opts) = @_;
	$opts ||= {};
	my $det = $opts->{'detect'} || &packages_detect($opts);
	my $list = $det->{'backends'} || [];
	return $list->[0] unless defined $name && length $name;
	foreach my $backend (@$list) {
		return $backend if $backend->{'name'} eq $name || $backend->{'kind'} eq $name;
	}
	return undef;
}

# The argv one backend runs for one action, before the timeout and sudo wrapper.
# Every list is literal: the package name or search term is the only caller text
# and it has already passed packages_validate_name. undef means the backend has
# no such action (snap, pip and npm keep no separate index to refresh).
sub packages_backend_argv {
	my ($backend, $action, $arg) = @_;
	return undef unless ref $backend eq 'HASH' && defined $action && length $action;
	my $name = $backend->{'name'} || '';
	my $tool = $backend->{'tool'} || '';
	my $tools = $backend->{'tools'} || {};
	return undef unless length $tool;

	if ($name eq 'apt') {
		my $query = $tools->{'dpkg-query'} || $tools->{'dpkg'} || '';
		return [ $query, '-W', '-f=${binary:Package}\t${Version}\t${Installed-Size}\n' ] if $action eq 'list';
		if ($action eq 'outdated') {
			my $apt = $tools->{'apt'};
			return [ $apt, 'list', '--upgradable' ] if $apt;
			return [ $tool, '--just-print', 'upgrade' ];
		}
		return undef unless $tools->{'apt-cache'};
		return [ $tools->{'apt-cache'}, 'search', $arg ] if $action eq 'search';
		return [ $tool, 'install', '-y', $arg ] if $action eq 'install';
		return [ $tool, 'remove', '-y', $arg ] if $action eq 'remove';
		return [ $tool, 'purge', '-y', $arg ] if $action eq 'purge';
		return [ $tool, 'update' ] if $action eq 'update';
		return [ $tool, '-y', 'upgrade' ] if $action eq 'upgrade';
		return undef;
	}
	if ($name eq 'pacman' || $name eq 'aur') {
		return [ $tool, '-Qm' ] if $name eq 'aur' && $action eq 'list';
		return [ $tool, '-Q' ] if $action eq 'list';
		return [ $tool, $name eq 'aur' ? '-Qua' : '-Qu' ] if $action eq 'outdated';
		return [ $tool, '-Ss', $arg ] if $action eq 'search';
		return [ $tool, '-S', '--noconfirm', $arg ] if $action eq 'install';
		return [ $tool, '-R', '--noconfirm', $arg ] if $action eq 'remove';
		return [ $tool, '-Rns', '--noconfirm', $arg ] if $action eq 'purge';
		return [ $tool, '-Sy' ] if $action eq 'update';
		return [ $tool, '-Syu', '--noconfirm' ] if $action eq 'upgrade';
		return undef;
	}
	if ($name eq 'flatpak') {
		return [ $tool, 'list', '--app', '--columns=application,version' ] if $action eq 'list';
		return [ $tool, 'remote-ls', '--updates', '--columns=application,version' ] if $action eq 'outdated';
		return [ $tool, 'search', '--columns=name,application,version,description', $arg ] if $action eq 'search';
		return [ $tool, 'install', '-y', '--noninteractive', $arg ] if $action eq 'install';
		return [ $tool, 'uninstall', '-y', $arg ] if $action eq 'remove';
		return [ $tool, 'uninstall', '-y', '--delete-data', $arg ] if $action eq 'purge';
		return [ $tool, 'update', '--appstream' ] if $action eq 'update';
		return [ $tool, 'update', '-y' ] if $action eq 'upgrade';
		return undef;
	}
	if ($name eq 'snap') {
		return [ $tool, 'list' ] if $action eq 'list';
		return [ $tool, 'refresh', '--list' ] if $action eq 'outdated';
		return [ $tool, 'find', $arg ] if $action eq 'search';
		return [ $tool, 'install', $arg ] if $action eq 'install';
		return [ $tool, 'remove', $arg ] if $action eq 'remove';
		return [ $tool, 'remove', '--purge', $arg ] if $action eq 'purge';
		return [ $tool, 'refresh' ] if $action eq 'upgrade';
		return undef;
	}
	if ($name eq 'pip') {
		return [ $tool, 'list', '--format=freeze', '--disable-pip-version-check' ] if $action eq 'list';
		return [ $tool, 'list', '--outdated', '--format=json', '--disable-pip-version-check' ] if $action eq 'outdated';
		return [ $tool, 'index', 'versions', $arg ] if $action eq 'search';
		return [ $tool, 'install', '--user', $arg ] if $action eq 'install';
		return [ $tool, 'uninstall', '-y', $arg ] if $action eq 'remove' || $action eq 'purge';
		return [ $tool, 'install', '--user', '--upgrade', $arg ] if $action eq 'upgrade_one';
		return undef;
	}
	if ($name eq 'npm') {
		return [ $tool, 'ls', '-g', '--depth=0', '--json' ] if $action eq 'list';
		return [ $tool, 'outdated', '-g', '--json' ] if $action eq 'outdated';
		return [ $tool, 'search', '--json', $arg ] if $action eq 'search';
		return [ $tool, 'install', '-g', $arg ] if $action eq 'install';
		return [ $tool, 'uninstall', '-g', $arg ] if $action eq 'remove' || $action eq 'purge';
		return [ $tool, 'update', '-g' ] if $action eq 'upgrade';
		return undef;
	}
	return undef;
}

# The manager's own version, from its fixed --version switch. A machine where
# the read fails says so with an empty version rather than a made-up one.
sub packages_version {
	my ($kind, $opts) = @_;
	$opts ||= {};
	my $det = $opts->{'detect'} || &packages_detect($opts);
	my $name = $kind eq 'pacman' ? 'pacman' : 'apt-get';
	my $path = $det->{'tools'}->{$name};
	return '' unless defined $path && length $path;
	my $res = &packages_run({
		%$opts,
		quiet => 1,
		argv  => &packages_command({ %$opts, elevated => 0 }, $path, '--version'),
		max_lines => 2,
	});
	my ($version) = ($res->{'output'} // '') =~ /(\d+(?:\.\d+)+)/;
	return defined $version ? $version : '';
}

sub packages_status {
	my ($opts) = @_;
	$opts ||= {};
	my $det = &packages_detect($opts);
	my $backends = $det->{'backends'} || [];
	my $primary = $backends->[0];
	my $out = {
		ok       => 1,
		runtime  => $det->{'runtime'},
		kind     => $det->{'kind'},
		manager  => $det->{'manager'},
		aur      => $det->{'aur'},
		managers => [],
		backends => [],
	};

	if ($det->{'kind'} eq 'runtime') {
		my $listing = &packages_runtime_listing($opts);
		$out->{'read_only'} = 1;
		$out->{'runtime_prefix'} = $listing->{'prefix'} || '';
		$out->{'runtime_binaries'} = scalar @{ $listing->{'packages'} || [] };
		$out->{'runtime_note'} = 'This device runs a prebuilt runtime, not a package manager: the software it ships is updated with the app, not from this window.';
		$out->{'runtime_can'} = [
			'read the list of binaries this runtime ships',
			"add developer tools in a terminal on this device, with the package tool that terminal provides",
		];
	}
	elsif (!@$backends) {
		$out->{'read_only'} = 1;
		$out->{'runtime_note'} = 'No package manager was found on this machine, so this window can only show what it can read.';
	}
	else {
		my $version = '';
		if ($det->{'kind'} eq 'apt' || $det->{'kind'} eq 'pacman') {
			$version = &packages_version($det->{'kind'}, { %$opts, detect => $det });
			$out->{'manager_version'} = $version;
			$out->{'manager_path'} = $primary->{'tool'};
		}
		foreach my $backend (@$backends) {
			my $is_primary = $primary && $backend->{'name'} eq $primary->{'name'};
			push @{ $out->{'managers'} }, {
				name    => $backend->{'name'},
				path    => $backend->{'tool'},
				version => $is_primary ? $version : '',
			};
			push @{ $out->{'backends'} }, {
				name    => $backend->{'name'},
				kind    => $backend->{'kind'},
				label   => &packages_backend_label($backend->{'name'}),
				tool    => $backend->{'tool'},
				version => $is_primary ? $version : '',
			};
		}
		$out->{'aur_helper'} = $det->{'aur'} if length $det->{'aur'};
	}

	$out->{'restart_needed'} = &packages_restart_needed($opts) ? 1 : 0;
	return $out;
}

# ---- argv ------------------------------------------------------------------

# Build the command a package action runs. A read is trusted with its own
# timeout only; a write adds `sudo -n`, and the timeout goes inside sudo so the
# whole privileged tree is bounded.
sub packages_command {
	my ($opts, @argv) = @_;
	$opts ||= {};
	return [] unless @argv;
	my $tool = $opts->{'tool'} || \&packages_tool;
	my @cmd = @argv;

	my $timeout = $opts->{'timeout_bin'};
	$timeout = $tool->('timeout') unless defined $timeout;
	my $seconds = $opts->{'timeout'} || $packages_timeout_seconds;
	if (defined $timeout && length $timeout) {
		@cmd = ($timeout, $seconds, @cmd);
	}

	if ($opts->{'elevated'}) {
		my $root = defined $opts->{'root'} ? $opts->{'root'} : ($> == 0 ? 1 : 0);
		unless ($root) {
			my $sudo = $opts->{'sudo_bin'};
			$sudo = $tool->('sudo') unless defined $sudo;
			$sudo = 'sudo' unless defined $sudo && length $sudo;
			@cmd = ($sudo, '-n', @cmd);
		}
	}
	return \@cmd;
}

# Run one argv list without a shell. The fake runner is how a test reads the
# argv each action builds without touching apt or pacman on the machine.
sub packages_run {
	my ($opts) = @_;
	$opts ||= {};
	my $argv = $opts->{'argv'} || [];
	my $seconds = $opts->{'timeout'} || $packages_timeout_seconds;

	my $res;
	if (my $fake = $opts->{'runner'}) {
		$res = $fake->(@$argv);
		$res = { output => $res } unless ref $res eq 'HASH';
		$res->{'status'} = 0 unless defined $res->{'status'};
	}
	else {
		$res = &packages_capture($argv, $seconds);
	}
	$res->{'ok'} = ($res->{'status'} // 1) == 0 ? 1 : 0;

	my $output = defined $res->{'output'} ? $res->{'output'} : '';
	$output =~ s/\r\n/\n/g;
	my @lines = split /\n/, $output;
	$res->{'lines'} = \@lines;
	my $limit = defined $opts->{'max_lines'} ? $opts->{'max_lines'} : $packages_output_lines;
	if ($limit && @lines > $limit) {
		$res->{'output'} = join("\n", @lines[-$limit .. -1]);
	}
	else {
		$res->{'output'} = join("\n", @lines);
	}
	$res->{'argv'} = $argv;
	&packages_log($opts, 'packages: ' . join(' ', @$argv) . ' -> ' . $res->{'status'})
		unless $opts->{'quiet'};
	return $res;
}

# One child, both pipes read at once so neither fills and deadlocks, and a
# deadline that kills a manager which ignores the timeout wrapper.
sub packages_capture {
	my ($argv, $seconds) = @_;
	require IPC::Open3;
	require IO::Select;
	require Symbol;
	my $err = Symbol::gensym();
	my ($in, $out);
	my $pid = eval { IPC::Open3::open3($in, $out, $err, @$argv) };
	return { status => 127, output => 'could not start ' . ($argv->[0] // 'the package manager') }
		unless $pid;
	close $in;

	my $select = IO::Select->new($out, $err);
	my $text = '';
	my $deadline = time + ($seconds || $packages_timeout_seconds) + 5;
	while ($select->count) {
		my $left = $deadline - time;
		last if $left <= 0;
		my @ready = $select->can_read($left > 1 ? 1 : $left);
		foreach my $fh (@ready) {
			my $buffer;
			my $read = sysread($fh, $buffer, 65536);
			if (!defined $read || !$read) { $select->remove($fh); next; }
			$text .= $buffer;
			$text = substr($text, -$packages_memory_cap) if length $text > $packages_memory_cap * 2;
		}
	}
	if ($select->count) {
		kill 'TERM', $pid;
		kill 'KILL', $pid;
	}
	close $out;
	close $err;
	waitpid($pid, 0);
	my $status = $? == -1 ? 127 : ($? & 127 ? 128 + ($? & 127) : ($? >> 8));
	return { status => $status, output => $text };
}

# Every action is written down, including the ones that fail. A test passes a
# logger so nothing reaches the terminal's log or the house's websocket.
sub packages_log {
	my ($opts, $text) = @_;
	return 0 unless defined $text && length $text;
	if (my $logger = $opts->{'logger'}) {
		$logger->($text);
		return 1;
	}
	return 0 unless defined &subs::log_writer;
	eval { &subs::log_writer($text) };
	return 1;
}

# ---- the lock ---------------------------------------------------------------

sub packages_lock_dir {
	my ($opts) = @_;
	$opts ||= {};
	my $dir = $opts->{'dir'};
	unless (defined $dir && length $dir) {
		$dir = eval { &subs::runtime_dir() };
	}
	unless (defined $dir && length $dir && -d $dir && -w $dir) {
		$dir = File::Spec->tmpdir();
	}
	return $dir;
}

sub packages_lock_path {
	my ($opts) = @_;
	$opts ||= {};
	return $opts->{'path'} if defined $opts->{'path'} && length $opts->{'path'};
	return File::Spec->catfile(&packages_lock_dir($opts), 'packages.lock');
}

# O_EXCL is the whole guarantee: two workers racing to change the same machine
# cannot both win. A lock left by a crashed run is cleared only after it is old
# enough that no real operation could still be running.
sub packages_lock_take {
	my ($opts) = @_;
	$opts ||= {};
	my $path = &packages_lock_path($opts);
	my $now = time;
	foreach my $attempt (1, 2) {
		my $fh;
		if (sysopen($fh, $path, O_CREAT | O_EXCL | O_WRONLY, 0600)) {
			print {$fh} "pid=$$ at=$now\n";
			close $fh;
			return { ok => 1, path => $path };
		}
		my $failed = $!;
		last unless $attempt == 1;
		my $mtime = (stat $path)[9];
		last unless defined $mtime && ($now - $mtime) > $packages_lock_stale;
		unlink $path;
	}
	return { ok => 0, path => $path, busy => 1, error => 'another package operation is already running' };
}

sub packages_lock_drop {
	my ($opts) = @_;
	my $path = ref $opts eq 'HASH' ? $opts->{'path'} : $opts;
	return 0 unless defined $path && length $path;
	return unlink($path) ? 1 : 0;
}

# Every mutating action goes through here, so the lock cannot be forgotten.
sub packages_operation {
	my ($opts) = @_;
	$opts ||= {};
	my $lock = &packages_lock_take($opts);
	return { ok => 0, busy => 1, error => $lock->{'error'} } unless $lock->{'ok'};
	my $result = eval { $opts->{'work'}->($opts) };
	my $error = $@;
	&packages_lock_drop($lock);
	return { ok => 0, error => "the package operation failed: $error" } if $error;
	return $result if ref $result eq 'HASH';
	return { ok => 0, error => 'the package operation gave no answer' };
}

# ---- reads ------------------------------------------------------------------

sub packages_list {
	my ($opts) = @_;
	$opts ||= {};
	my $det = &packages_detect($opts);
	return &packages_runtime_listing($opts) if $det->{'kind'} eq 'runtime';
	my $backend = &packages_backend($opts->{'backend'}, { %$opts, detect => $det });
	return { ok => 0, error => 'no package manager was found on this machine', kind => 'none' }
		unless $backend;

	my $raw = &packages_backend_argv($backend, 'list');
	return { ok => 0, error => 'this package manager cannot list installed packages' }
		unless defined $raw;
	my $argv = &packages_command({ %$opts, elevated => 0 }, @$raw);
	my $res = &packages_run({ %$opts, quiet => 1, argv => $argv, max_lines => 0 });
	return { ok => 0, error => $res->{'output'} || 'the package list could not be read', output => $res->{'output'} }
		unless $res->{'ok'};

	my ($rows, $capped) = &packages_parse_installed($backend, $res->{'lines'});
	return {
		ok       => 1,
		kind     => $backend->{'kind'},
		backend  => $backend->{'name'},
		manager  => $backend->{'name'},
		packages => $rows,
		capped   => $capped,
	};
}

sub packages_outdated {
	my ($opts) = @_;
	$opts ||= {};
	my $det = &packages_detect($opts);
	return { ok => 1, kind => 'runtime', read_only => 1, packages => [], note => 'the runtime has no package manager' }
		if $det->{'kind'} eq 'runtime';
	my $backend = &packages_backend($opts->{'backend'}, { %$opts, detect => $det });
	return { ok => 0, error => 'no package manager was found on this machine' }
		unless $backend;

	my $raw = &packages_backend_argv($backend, 'outdated');
	return { ok => 0, error => 'this package manager cannot list outdated packages' }
		unless defined $raw;
	my $argv = &packages_command({ %$opts, elevated => 0 }, @$raw);
	my $res = &packages_run({ %$opts, quiet => 1, argv => $argv, max_lines => 0 });
	my $output = $res->{'output'} // '';
	# pacman exits 1 when nothing is outdated; npm exits 1 when something is.
	# Both are answers, not faults.
	my $expected = (($backend->{'name'} eq 'pacman' || $backend->{'name'} eq 'aur')
			&& !@{ $res->{'lines'} || [] })
		|| ($backend->{'name'} eq 'npm' && $output =~ /^\s*[\{\[]/);
	return { ok => 0, error => $output || 'the outdated list could not be read' }
		if !$res->{'ok'} && !$expected;

	my $rows = &packages_parse_outdated($backend, $res->{'lines'}, $output);
	return {
		ok      => 1,
		kind    => $backend->{'kind'},
		backend => $backend->{'name'},
		packages => $rows,
		count   => scalar @$rows,
	};
}

sub packages_search {
	my ($term, $opts) = @_;
	$opts ||= {};
	my $det = &packages_detect($opts);
	return { ok => 1, kind => 'runtime', read_only => 1, packages => [], note => 'the runtime has no package manager' }
		if $det->{'kind'} eq 'runtime';
	my $backend = &packages_backend($opts->{'backend'}, { %$opts, detect => $det });
	return { ok => 0, error => 'no package manager was found on this machine', kind => 'none' }
		unless $backend;
	my ($good, $why) = &packages_validate_name($term, $backend->{'name'});
	return { ok => 0, error => $why } unless $good;

	my $raw = &packages_backend_argv($backend, 'search', $term);
	return { ok => 0, error => 'this package manager cannot search' } unless defined $raw;
	my $argv = &packages_command({ %$opts, elevated => 0 }, @$raw);
	my $res = &packages_run({ %$opts, quiet => 1, argv => $argv, max_lines => 0 });
	return { ok => 0, error => $res->{'output'} || 'the search failed' } unless $res->{'ok'};

	my $rows = &packages_parse_search($backend, $res->{'lines'}, $res->{'output'}, $term);
	return {
		ok      => 1,
		kind    => $backend->{'kind'},
		backend => $backend->{'name'},
		term    => $term,
		packages => $rows,
		capped  => @$rows >= $packages_search_cap ? 1 : 0,
	};
}

# ---- reading a backend's answer --------------------------------------------

# Decode a backend's JSON answer without trusting anything about it. A tool
# may print a warning before the document; decode from the first bracket as a
# fallback so one stderr line does not turn a list into an error.
sub packages_json {
	my ($text) = @_;
	return undef unless defined $text && length $text;
	require JSON::PP;
	my $json = JSON::PP->new->utf8;
	my $data = eval { $json->decode($text) };
	return $data if ref $data;
	my $from = index($text, '{');
	my $array = index($text, '[');
	$from = $array if $from < 0 || ($array >= 0 && $array < $from);
	return undef if $from < 0;
	$data = eval { $json->decode(substr($text, $from)) };
	return ref $data ? $data : undef;
}

sub packages_parse_installed {
	my ($backend, $lines) = @_;
	$lines ||= [];
	my $name = $backend->{'name'} || '';
	my @rows;

	if ($name eq 'npm') {
		my $data = &packages_json(join("\n", @$lines));
		my $deps = ref $data eq 'HASH' ? ($data->{'dependencies'} || {}) : {};
		foreach my $pkg (sort keys %$deps) {
			my $row = $deps->{$pkg};
			push @rows, {
				name    => $pkg,
				version => ref $row eq 'HASH' ? ($row->{'version'} // '') : '',
				size_kb => undef,
			};
			last if @rows >= $packages_list_cap;
		}
		return (\@rows, @rows >= $packages_list_cap ? 1 : 0);
	}

	foreach my $line (@$lines) {
		next unless defined $line && length $line;
		my ($pkg, $version, $kb);
		if ($name eq 'apt') {
			($pkg, $version, $kb) = split /\t/, $line;
		}
		elsif ($name eq 'flatpak') {
			($pkg, $version) = split /\t/, $line, 2;
		}
		elsif ($name eq 'snap') {
			next if $line =~ /^Name\s+Version\s+/i;
			($pkg, $version) = split /\s+/, $line, 3;
		}
		elsif ($name eq 'pip') {
			($pkg, $version) = $line =~ /^([^=<>!\s]+)==(\S+)/;
		}
		else {
			($pkg, $version) = split /\s+/, $line, 2;
		}
		next unless defined $pkg && length $pkg;
		push @rows, {
			name    => $pkg,
			version => defined $version ? $version : '',
			size_kb => (defined $kb && $kb =~ /^\d+$/) ? $kb + 0 : undef,
		};
		last if @rows >= $packages_list_cap;
	}
	return (\@rows, @rows >= $packages_list_cap ? 1 : 0);
}

sub packages_parse_outdated {
	my ($backend, $lines, $text) = @_;
	$lines ||= [];
	my $name = $backend->{'name'} || '';
	my @rows;

	if ($name eq 'apt') {
		foreach my $line (@$lines) {
			my ($pkg, $version, $old) = $line =~ /^(\S+?)\/\S+\s+(\S+)\s+\S+(?:.*?\[upgradable from:\s*([^\]]+)\])?/;
			next unless defined $pkg && length $pkg;
			push @rows, { name => $pkg, version => ($version // ''), from => ($old // '') };
		}
		return \@rows;
	}
	if ($name eq 'pacman' || $name eq 'aur') {
		foreach my $line (@$lines) {
			my ($pkg, $old, $new) = $line =~ /^(\S+)\s+(\S+)\s+->\s+(\S+)/;
			next unless defined $pkg && length $pkg;
			push @rows, { name => $pkg, from => $old, version => $new };
		}
		return \@rows;
	}
	if ($name eq 'flatpak') {
		foreach my $line (@$lines) {
			my ($pkg, $version) = split /\t/, $line, 2;
			next unless defined $pkg && length $pkg;
			push @rows, { name => $pkg, version => ($version // ''), from => '' };
		}
		return \@rows;
	}
	if ($name eq 'snap') {
		my $seen_header = 0;
		foreach my $line (@$lines) {
			next unless defined $line && length $line;
			if (!$seen_header) {
				$seen_header = 1 if $line =~ /^Name\s+Version/i;
				next;
			}
			my ($pkg, $version) = split /\s+/, $line, 3;
			next unless defined $pkg && length $pkg;
			push @rows, { name => $pkg, version => ($version // ''), from => '' };
		}
		return \@rows;
	}
	if ($name eq 'pip' || $name eq 'npm') {
		my $data = &packages_json($text);
		if (ref $data eq 'ARRAY') {
			foreach my $row (@$data) {
				next unless ref $row eq 'HASH' && defined $row->{'name'} && length $row->{'name'};
				push @rows, {
					name    => $row->{'name'},
					version => ($row->{'latest_version'} // $row->{'latest'} // ''),
					from    => ($row->{'version'} // $row->{'current'} // ''),
				};
			}
		}
		elsif (ref $data eq 'HASH') {
			foreach my $pkg (sort keys %$data) {
				my $row = $data->{$pkg};
				next unless ref $row eq 'HASH';
				push @rows, {
					name    => $pkg,
					version => ($row->{'latest'} // ''),
					from    => ($row->{'current'} // ''),
				};
			}
		}
		return \@rows;
	}
	return \@rows;
}

sub packages_parse_search {
	my ($backend, $lines, $text, $term) = @_;
	$lines ||= [];
	my $name = $backend->{'name'} || '';
	my @rows;

	if ($name eq 'apt') {
		foreach my $line (@$lines) {
			my ($pkg, $description) = $line =~ /^(\S+)\s+-\s+(.*)$/;
			next unless defined $pkg && length $pkg;
			push @rows, { name => $pkg, version => '', description => ($description // '') };
			last if @rows >= $packages_search_cap;
		}
		return \@rows;
	}
	if ($name eq 'pacman' || $name eq 'aur') {
		my $is_row = 0;
		foreach my $line (@$lines) {
			if ($line =~ /^\S+\/(\S+)\s+(\S+)/) {
				$is_row = 1;
				push @rows, { name => $1, version => $2, description => '' };
				last if @rows >= $packages_search_cap;
			}
			elsif ($is_row && $line =~ /^\s+(\S.*)$/) {
				$rows[-1]->{'description'} = $1 unless length $rows[-1]->{'description'};
				$is_row = 0;
			}
		}
		return \@rows;
	}
	if ($name eq 'flatpak') {
		foreach my $line (@$lines) {
			my ($label, $pkg, $version, $description) = split /\t/, $line, 4;
			next unless defined $pkg && length $pkg;
			push @rows, {
				name => $pkg,
				version => ($version // ''),
				description => ($label // $description // ''),
			};
			last if @rows >= $packages_search_cap;
		}
		return \@rows;
	}
	if ($name eq 'snap') {
		foreach my $line (@$lines) {
			next if $line =~ /^(?:Name|Command)\s/i;
			next if $line =~ /^-+\s*$/;
			my ($pkg, $version, $publisher, $notes, $summary) = split /\s{2,}/, $line;
			next unless defined $pkg && length $pkg;
			push @rows, { name => $pkg, version => ($version // ''), description => ($summary // '') };
			last if @rows >= $packages_search_cap;
		}
		return \@rows;
	}
	if ($name eq 'pip') {
		foreach my $line (@$lines) {
			my ($pkg, $versions) = $line =~ /^(\S+)\s+\(([^)]+)\)/;
			next unless defined $pkg && length $pkg;
			my @v = split /,/, $versions;
			my ($latest) = $v[0] =~ /(\S+)/;
			push @rows, { name => $pkg, version => ($latest // ''), description => '' };
			last;
		}
		return \@rows;
	}
	if ($name eq 'npm') {
		my $data = &packages_json($text);
		if (ref $data eq 'ARRAY') {
			foreach my $row (@$data) {
				next unless ref $row eq 'HASH' && defined $row->{'name'} && length $row->{'name'};
				push @rows, {
					name => $row->{'name'},
					version => ($row->{'version'} // ''),
					description => ($row->{'description'} // ''),
				};
				last if @rows >= $packages_search_cap;
			}
		}
		return \@rows;
	}
	return \@rows;
}

# The runtime a phone ships is a prebuilt prefix: list what is there, read-only.
sub packages_runtime_bin_dir {
	my ($opts) = @_;
	$opts ||= {};
	my @candidates;
	push @candidates, $opts->{'bin_dir'} if defined $opts->{'bin_dir'} && length $opts->{'bin_dir'};
	push @candidates, "$ENV{'PREFIX'}/bin" if defined $ENV{'PREFIX'} && length $ENV{'PREFIX'};
	push @candidates, '/data/data/com.termux/files/usr/bin';
	foreach my $dir (@candidates) {
		return $dir if defined $dir && length $dir && -d $dir && -r $dir;
	}
	return undef;
}

sub packages_runtime_listing {
	my ($opts) = @_;
	$opts ||= {};
	my $dir = &packages_runtime_bin_dir($opts);
	my $out = {
		ok        => 1,
		kind      => 'runtime',
		read_only => 1,
		manager   => '',
		packages  => [],
	};
	unless (defined $dir) {
		$out->{'note'} = 'this device ships no package manager and names no bin directory; the software it runs is part of the app';
		return $out;
	};
	opendir(my $dh, $dir) or do {
		$out->{'note'} = "could not read the runtime's bin directory ($dir)";
		return $out;
	};
	my @names;
	while (defined(my $entry = readdir($dh))) {
		next if $entry eq '.' || $entry eq '..';
		my $path = "$dir/$entry";
		next unless -f $path && -x $path;
		push @names, $entry;
	}
	closedir($dh);
	@names = sort @names;
	my $capped = @names > $packages_list_cap ? 1 : 0;
	@names = @names[0 .. $packages_list_cap - 1] if $capped;
	$out->{'prefix'} = $dir;
	$out->{'packages'} = [ map { { name => $_, version => '', size_kb => undef } } @names ];
	$out->{'capped'} = $capped;
	$out->{'note'} = 'this device runs a prebuilt runtime with no package manager: these are the binaries it ships, and this window cannot install, upgrade or remove any of them';
	return $out;
}

# ---- validation and errors --------------------------------------------------

# npm's scoped names are the one grammar the bare rule cannot express. The
# pattern still refuses a path, a flag or a shell metacharacter: it is a name,
# an @, a scope, and one slash.
our $packages_npm_scope_pattern = qr/^@[A-Za-z0-9][A-Za-z0-9._-]{0,63}\/[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

sub packages_validate_name {
	my ($name, $backend) = @_;
	return (0, 'no package name was given') unless defined $name && length $name;
	return (1, $name) if defined $backend && $backend eq 'npm' && $name =~ $packages_npm_scope_pattern;
	return (0, 'a package name must be one word: letters, digits and + . _ : - only')
		unless $name =~ $packages_name_pattern;
	return (1, $name);
}

# sudo -n never asks for a password; when that is what stopped us, say so in
# words a person can act on instead of showing the manager's wall of text.
sub packages_sudo_refused {
	my ($text) = @_;
	return 0 unless defined $text && length $text;
	return $text =~ /a (?:terminal|password) is required|sudo:.*(?:password|no tty)|no tty present|not in the sudoers|incorrect password|Permission denied/i
		? 1 : 0;
}

# A phone's runtime is a whole answer, not a missing manager: say what it is,
# why nothing can change, and where the person can go instead.
sub packages_runtime_refusal {
	return {
		ok        => 0,
		read_only => 1,
		kind      => 'runtime',
		error     => 'this device runs a prebuilt runtime with no package manager, so software is not installed, removed or upgraded from here',
		note      => 'the runtime and the app are updated together; for developer tools, open a terminal on this device and use the package tool that terminal provides',
	};
}

# ---- writes -----------------------------------------------------------------

sub packages_update {
	my ($opts) = @_;
	$opts ||= {};
	my $det = &packages_detect($opts);
	return &packages_runtime_refusal() if $det->{'kind'} eq 'runtime';
	my $backend = &packages_backend($opts->{'backend'}, { %$opts, detect => $det });
	return { ok => 0, error => 'no package manager was found on this machine' } unless $backend;

	my $raw = &packages_backend_argv($backend, 'update');
	unless (defined $raw) {
		return {
			ok      => 1,
			changed => 0,
			noop    => 1,
			backend => $backend->{'name'},
			note    => 'this package manager keeps its own index, so there is nothing to refresh',
		};
	}
	return &packages_operation({
		%$opts,
		work => sub {
			my $argv = &packages_command({ %$opts, elevated => $backend->{'elevated'} }, @$raw);
			return &packages_finish($opts, &packages_run({ %$opts, argv => $argv }), 0);
		},
	});
}

sub packages_upgrade {
	my ($opts) = @_;
	$opts ||= {};
	my $det = &packages_detect($opts);
	return &packages_runtime_refusal() if $det->{'kind'} eq 'runtime';
	my $backend = &packages_backend($opts->{'backend'}, { %$opts, detect => $det });
	return { ok => 0, error => 'no package manager was found on this machine' } unless $backend;

	# pip upgrades one package at a time; the outdated list is the work queue.
	if ($backend->{'name'} eq 'pip') {
		return &packages_operation({
			%$opts,
			work => sub {
				my $outdated = &packages_outdated({ %$opts, backend => 'pip', detect => $det });
				my @names = map { $_->{'name'} } @{ $outdated->{'packages'} || [] };
				return { ok => 1, changed => 0, noop => 1, note => 'every pip package is already up to date' }
					unless @names;
				my (@text, $failed);
				foreach my $pkg (@names) {
					my $raw = &packages_backend_argv($backend, 'upgrade_one', $pkg);
					next unless defined $raw;
					my $res = &packages_run({
						%$opts,
						argv => &packages_command({ %$opts, elevated => 0 }, @$raw),
					});
					$failed = 1 unless $res->{'ok'};
					push @text, $res->{'output'} if defined $res->{'output'} && length $res->{'output'};
				}
				return &packages_finish($opts, { status => $failed ? 1 : 0, output => join("\n", @text) }, 1);
			},
		});
	}

	my $raw = &packages_backend_argv($backend, 'upgrade');
	return { ok => 0, error => 'this package manager cannot upgrade' } unless defined $raw;
	return &packages_operation({
		%$opts,
		work => sub {
			my $argv = &packages_command({ %$opts, elevated => $backend->{'elevated'} }, @$raw);
			return &packages_finish($opts, &packages_run({ %$opts, argv => $argv }), 1);
		},
	});
}

# One name, one backend, one action. The name is checked against the backend's
# own grammar before any argv is built.
sub packages_single_action {
	my ($action, $name, $opts, $note) = @_;
	$opts ||= {};
	my $det = &packages_detect($opts);
	return &packages_runtime_refusal() if $det->{'kind'} eq 'runtime';
	my $backend = &packages_backend($opts->{'backend'}, { %$opts, detect => $det });
	return { ok => 0, error => 'no package manager was found on this machine' } unless $backend;
	# pip and npm own no separate configuration to delete; say so rather than
	# pretending their purge differs from a remove.
	$note = 'this package manager keeps no separate configuration to delete'
		if $action eq 'purge' && ($backend->{'name'} eq 'pip' || $backend->{'name'} eq 'npm');
	my ($good, $why) = &packages_validate_name($name, $backend->{'name'});
	return { ok => 0, error => $why } unless $good;
	my $raw = &packages_backend_argv($backend, $action, $name);
	return { ok => 0, error => 'this package manager cannot ' . $action . ' by name' } unless defined $raw;
	return &packages_operation({
		%$opts,
		work => sub {
			my $argv = &packages_command({ %$opts, elevated => $backend->{'elevated'} }, @$raw);
			return &packages_finish($opts, &packages_run({ %$opts, argv => $argv }), 1, $name, $note);
		},
	});
}

sub packages_install {
	my ($name, $opts) = @_;
	return &packages_single_action('install', $name, $opts);
}

sub packages_remove {
	my ($name, $opts) = @_;
	return &packages_single_action('remove', $name, $opts);
}

sub packages_purge {
	my ($name, $opts) = @_;
	return &packages_single_action('purge', $name, $opts);
}

# Install a package file the person uploaded. The path must be inside the
# upload directory this app made; a path from anywhere else is refused before
# any argv is built.
sub packages_install_file {
	my ($path, $opts) = @_;
	$opts ||= {};
	my $dir = $opts->{'upload_dir'} || &packages_upload_dir($opts);
	my $checked = &packages_upload_path($path, $dir);
	unless ($checked->{'ok'}) {
		return { ok => 0, error => $checked->{'error'} };
	}
	my $file = $checked->{'path'};
	return &packages_operation({
		%$opts,
		work => sub {
			my $det = &packages_detect($opts);
			my $kind = $det->{'kind'};
			return &packages_runtime_refusal() if $kind eq 'runtime';
			return { ok => 0, error => 'this package manager cannot install a package file' }
				unless $kind eq 'apt' || $kind eq 'pacman';

			my $lower = $file;
			$lower =~ s/.*\///;
			my $is_deb = $lower =~ /\.deb$/i;
			my $is_arch = $lower =~ /\.pkg\.tar\.(?:zst|xz|gz|bz2)$/i;
			if ($kind eq 'apt' && !$is_deb) {
				return { ok => 0, error => 'apt installs a .deb file; this upload is not one' };
			}
			if ($kind eq 'pacman' && !$is_arch) {
				return { ok => 0, error => 'pacman installs an Arch package (.pkg.tar.zst or .xz); this upload is not one' };
			}

			my $first;
			if ($kind eq 'apt') {
				my $dpkg = $det->{'tools'}->{'dpkg'} || 'dpkg';
				$first = &packages_run({
					%$opts,
					argv => &packages_command({ %$opts, elevated => 1 }, $dpkg, '-i', $file),
				});
				if (!$first->{'ok'} && ($first->{'output'} // '') =~ /dependency problems|unmet dependencies|depends; however/i) {
					my $fix = &packages_run({
						%$opts,
						argv => &packages_command({ %$opts, elevated => 1 }, $det->{'tools'}->{'apt-get'}, '-y', '-f', 'install'),
					});
					return &packages_finish($opts, $fix, 1, $file);
				}
				return &packages_finish($opts, $first, 1, $file);
			}
			my $pacman = $det->{'tools'}->{'pacman'};
			$first = &packages_run({
				%$opts,
				argv => &packages_command({ %$opts, elevated => 1 }, $pacman, '-U', '--noconfirm', $file),
			});
			return &packages_finish($opts, $first, 1, $file);
		},
	});
}

# The one place a mutating result becomes the app's answer: a sudo refusal is
# named as such, a success records that the running system changed, and the
# manager's own tail is carried back for the log.
sub packages_finish {
	my ($opts, $res, $changed, $what, $note) = @_;
	my $output = $res->{'output'} // '';
	if (!$res->{'ok'} && &packages_sudo_refused($output)) {
		return {
			ok        => 0,
			needs_root => 1,
			error     => 'this needs root, and sudo -n was refused (no password prompt is shown)',
			output    => $output,
		};
	}
	if ($res->{'ok'} && $changed) {
		eval { &packages_restart_mark($opts) };
	}
	my $answer = {
		ok        => $res->{'ok'} ? 1 : 0,
		changed   => $res->{'ok'} && $changed ? 1 : 0,
		what      => $what // '',
		status    => $res->{'status'},
		output    => $output,
		error     => $res->{'ok'} ? undef : ($output || 'the package manager failed'),
		restart_needed => &packages_restart_needed($opts) ? 1 : 0,
	};
	$answer->{'note'} = $note if defined $note && length $note;
	return $answer;
}

# ---- the upload path --------------------------------------------------------

# Uploads land in a directory this app owns under the runtime's temp dir. The
# controller saves the file there; the domain checks that the path it is handed
# still resolves inside it.
sub packages_upload_dir {
	my ($opts) = @_;
	$opts ||= {};
	my $dir = File::Spec->catdir(&packages_lock_dir($opts), 'packages-upload');
	unless (-d $dir) {
		require File::Path;
		eval { File::Path::make_path($dir) };
	}
	return $dir;
}

sub packages_upload_path {
	my ($path, $dir) = @_;
	return { ok => 0, error => 'no file was uploaded' } unless defined $path && length $path;
	return { ok => 0, error => 'no upload directory is available' } unless defined $dir && length $dir;
	my $base = eval { require Cwd; Cwd::abs_path($dir) };
	return { ok => 0, error => 'the upload directory is not readable' } unless defined $base && length $base;
	my $full = eval { require Cwd; Cwd::abs_path($path) };
	return { ok => 0, error => 'the uploaded file could not be resolved' } unless defined $full && length $full;
	my $prefix = $base;
	$prefix .= '/' unless $prefix =~ m{/$};
	return { ok => 0, error => 'that file is outside the upload' }
		unless $full eq $base || index($full, $prefix) == 0;
	return { ok => 0, error => 'the uploaded file is gone' } unless -f $full;
	return { ok => 1, path => $full };
}

# ---- restart ----------------------------------------------------------------

sub packages_restart_marker {
	my ($opts) = @_;
	$opts ||= {};
	return $opts->{'marker'} if defined $opts->{'marker'} && length $opts->{'marker'};
	return File::Spec->catfile(&packages_lock_dir($opts), 'packages.restart');
}

sub packages_restart_needed {
	my ($opts) = @_;
	$opts ||= {};
	return 1 if -e '/var/run/reboot-required';
	my $marker = &packages_restart_marker($opts);
	return -e $marker ? 1 : 0;
}

sub packages_restart_mark {
	my ($opts) = @_;
	$opts ||= {};
	my $marker = &packages_restart_marker($opts);
	open(my $fh, '>', $marker) or return 0;
	print {$fh} time, "\n";
	close $fh;
	return 1;
}

sub packages_restart_clear {
	my ($opts) = @_;
	$opts ||= {};
	my $marker = &packages_restart_marker($opts);
	return -e $marker ? (unlink($marker) ? 1 : 0) : 0;
}

1;
