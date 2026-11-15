package subs;

# Packages: the software a machine runs, seen and changed through one app.
#
# The app asks the machine what it is instead of assuming: a Debian or Ubuntu
# box answers apt + dpkg, an Arch box answers pacman (and yay or paru for the
# AUR), and a phone's prebuilt runtime answers neither - it ships binaries but
# no package manager, and the app lists them read-only rather than pretending
# to install.
#
# Every command is an argv list. Nothing here is interpolated into a shell, a
# package name is checked against a closed pattern first, and every mutating
# run is one `sudo -n` command with a bounded timeout. A refused password prompt
# is reported, never waited on. One operation at a time is the lock file under
# the runtime directory, taken with O_EXCL.
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

# Which managers exist and which one the app will use. apt wins when both answer
# because a Debian box whose user installed pacman for a chroot still has apt as
# its own manager; the other one is reported, never guessed at.
sub packages_detect {
	my ($opts) = @_;
	$opts ||= {};
	my $tool = $opts->{'tool'} || \&packages_tool;
	my $runtime = &packages_runtime_kind($opts);

	my @names = qw(apt apt-get dpkg dpkg-query apt-cache pacman yay paru);
	my %path;
	foreach my $name (@names) {
		my $found = $tool->($name);
		$path{$name} = $found if defined $found && length $found;
	}

	my ($kind, $manager, $aur) = ('none', '', '');
	if ($path{'apt-get'} && $path{'dpkg'}) {
		($kind, $manager) = ('apt', 'apt');
	}
	elsif ($path{'pacman'}) {
		($kind, $manager) = ('pacman', 'pacman');
		$aur = 'yay' if $path{'yay'};
		$aur = 'paru' if !$aur && $path{'paru'};
	}
	# A phone's runtime ships a bin/ prefix and no manager; saying 'runtime' is
	# the honest answer even when a busybox-looking binary happens to match.
	$kind = 'runtime' if $runtime eq 'mobile';

	return {
		ok      => 1,
		runtime => $runtime,
		kind    => $kind,
		manager => $manager,
		aur     => $aur,
		tools   => \%path,
	};
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
	my $out = {
		ok      => 1,
		runtime => $det->{'runtime'},
		kind    => $det->{'kind'},
		manager => $det->{'manager'},
		aur     => $det->{'aur'},
		managers => [],
	};
	if ($det->{'kind'} eq 'apt' || $det->{'kind'} eq 'pacman') {
		my $version = &packages_version($det->{'kind'}, { %$opts, detect => $det });
		my $name = $det->{'kind'};
		my $path = $det->{'tools'}->{ $name eq 'pacman' ? 'pacman' : 'apt-get' };
		$out->{'manager_version'} = $version;
		$out->{'manager_path'} = $path;
		push @{ $out->{'managers'} }, {
			name    => $name,
			path    => $path,
			version => $version,
		};
		$out->{'aur_helper'} = $det->{'aur'} if length $det->{'aur'};
	}
	elsif ($det->{'kind'} eq 'runtime') {
		my $listing = &packages_runtime_listing($opts);
		$out->{'read_only'} = 1;
		$out->{'runtime_prefix'} = $listing->{'prefix'} || '';
		$out->{'runtime_binaries'} = scalar @{ $listing->{'packages'} || [] };
	}
	else {
		$out->{'read_only'} = 1;
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
	return { ok => 0, error => 'no package manager was found on this machine', kind => 'none' }
		if $det->{'kind'} ne 'apt' && $det->{'kind'} ne 'pacman';

	my ($argv, $res);
	if ($det->{'kind'} eq 'apt') {
		my $query = $det->{'tools'}->{'dpkg-query'} || $det->{'tools'}->{'dpkg'};
		return { ok => 0, error => 'dpkg-query is not available' } unless $query;
		$argv = &packages_command({ %$opts, elevated => 0 },
			$query, '-W', '-f=${binary:Package}\t${Version}\t${Installed-Size}\n');
	}
	else {
		$argv = &packages_command({ %$opts, elevated => 0 }, $det->{'tools'}->{'pacman'}, '-Q');
	}
	$res = &packages_run({ %$opts, quiet => 1, argv => $argv, max_lines => 0 });
	return { ok => 0, error => $res->{'output'} || 'the package list could not be read', output => $res->{'output'} }
		unless $res->{'ok'};

	my @rows;
	my $capped = 0;
	foreach my $line (@{ $res->{'lines'} || [] }) {
		next unless defined $line && length $line;
		my ($name, $version, $kb);
		if ($det->{'kind'} eq 'apt') {
			($name, $version, $kb) = split /\t/, $line;
		}
		else {
			($name, $version) = split /\s+/, $line, 2;
		}
		next unless defined $name && length $name;
		push @rows, {
			name    => $name,
			version => defined $version ? $version : '',
			size_kb => (defined $kb && $kb =~ /^\d+$/) ? $kb + 0 : undef,
		};
		if (@rows >= $packages_list_cap) { $capped = 1; last; }
	}
	return {
		ok      => 1,
		kind    => $det->{'kind'},
		manager => $det->{'manager'},
		packages => \@rows,
		capped  => $capped,
	};
}

sub packages_outdated {
	my ($opts) = @_;
	$opts ||= {};
	my $det = &packages_detect($opts);
	return { ok => 0, error => 'no package manager was found on this machine' }
		if $det->{'kind'} ne 'apt' && $det->{'kind'} ne 'pacman';
	return { ok => 1, kind => 'runtime', read_only => 1, packages => [], note => 'the runtime has no package manager' }
		if $det->{'kind'} eq 'runtime';

	my $argv;
	if ($det->{'kind'} eq 'apt') {
		my $apt = $det->{'tools'}->{'apt'};
		$argv = $apt
			? &packages_command({ %$opts, elevated => 0 }, $apt, 'list', '--upgradable')
			: &packages_command({ %$opts, elevated => 0 }, $det->{'tools'}->{'apt-get'}, '--just-print', 'upgrade');
	}
	else {
		$argv = &packages_command({ %$opts, elevated => 0 }, $det->{'tools'}->{'pacman'}, '-Qu');
	}
	my $res = &packages_run({ %$opts, quiet => 1, argv => $argv, max_lines => 0 });
	# pacman exits 1 when nothing is outdated; that is an empty list, not a fault.
	my $expected = $det->{'kind'} eq 'pacman' && !@{$res->{'lines'} || []};
	return { ok => 0, error => $res->{'output'} || 'the outdated list could not be read' }
		if !$res->{'ok'} && !$expected;

	my @rows;
	foreach my $line (@{ $res->{'lines'} || [] }) {
		next unless defined $line && length $line;
		if ($det->{'kind'} eq 'apt') {
			my ($name, $version, $old) = $line =~ /^(\S+?)\/\S+\s+(\S+)\s+\S+(?:.*?\[upgradable from:\s*([^\]]+)\])?/;
			next unless defined $name && length $name;
			push @rows, { name => $name, version => ($version // ''), from => ($old // '') };
		}
		else {
			my ($name, $old, $new) = $line =~ /^(\S+)\s+(\S+)\s+->\s+(\S+)/;
			next unless defined $name && length $name;
			push @rows, { name => $name, from => $old, version => $new };
		}
	}
	return { ok => 1, kind => $det->{'kind'}, packages => \@rows, count => scalar @rows };
}

sub packages_search {
	my ($term, $opts) = @_;
	$opts ||= {};
	my ($good, $why) = &packages_validate_name($term);
	return { ok => 0, error => $why } unless $good;
	my $det = &packages_detect($opts);
	return { ok => 0, error => 'no package manager was found on this machine', kind => 'none' }
		if $det->{'kind'} ne 'apt' && $det->{'kind'} ne 'pacman';
	return { ok => 1, kind => 'runtime', read_only => 1, packages => [], note => 'the runtime has no package manager' }
		if $det->{'kind'} eq 'runtime';

	my $argv;
	if ($det->{'kind'} eq 'apt') {
		return { ok => 0, error => 'apt-cache is not available' } unless $det->{'tools'}->{'apt-cache'};
		$argv = &packages_command({ %$opts, elevated => 0 }, $det->{'tools'}->{'apt-cache'}, 'search', $term);
	}
	else {
		$argv = &packages_command({ %$opts, elevated => 0 }, $det->{'tools'}->{'pacman'}, '-Ss', $term);
	}
	my $res = &packages_run({ %$opts, quiet => 1, argv => $argv, max_lines => 0 });
	return { ok => 0, error => $res->{'output'} || 'the search failed' } unless $res->{'ok'};

	my @rows;
	my $capped = 0;
	if ($det->{'kind'} eq 'apt') {
		foreach my $line (@{ $res->{'lines'} || [] }) {
			my ($name, $description) = $line =~ /^(\S+)\s+-\s+(.*)$/;
			next unless defined $name && length $name;
			push @rows, { name => $name, version => '', description => ($description // '') };
			if (@rows >= $packages_search_cap) { $capped = 1; last; }
		}
	}
	else {
		my $row;
		foreach my $line (@{ $res->{'lines'} || [] }) {
			if ($line =~ /^\S+\/(\S+)\s+(\S+)/) {
				$row = [ $1, $2, '' ];
				push @rows, { name => $1, version => $2, description => '' };
				if (@rows >= $packages_search_cap) { $capped = 1; last; }
			}
			elsif ($row && $line =~ /^\s+(\S.*)$/) {
				$rows[-1]->{'description'} = $1 unless length $rows[-1]->{'description'};
				$row = undef;
			}
		}
	}
	return { ok => 1, kind => $det->{'kind'}, term => $term, packages => \@rows, capped => $capped };
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
		$out->{'note'} = 'this runtime ships no package manager and names no bin directory';
		return $out;
	}
	opendir(my $dh, $dir) or do {
		$out->{'note'} = "could not read $dir";
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
	$out->{'note'} = 'the runtime ships these binaries and no package manager; nothing can be installed from here';
	return $out;
}

# ---- validation and errors --------------------------------------------------

sub packages_validate_name {
	my ($name) = @_;
	return (0, 'no package name was given') unless defined $name && length $name;
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

# ---- writes -----------------------------------------------------------------

sub packages_update {
	my ($opts) = @_;
	$opts ||= {};
	return &packages_operation({
		%$opts,
		work => sub {
			my $det = &packages_detect($opts);
			return { ok => 0, error => 'no package manager was found on this machine' }
				if $det->{'kind'} ne 'apt' && $det->{'kind'} ne 'pacman';
			return { ok => 0, error => 'the runtime has no package manager' } if $det->{'kind'} eq 'runtime';
			my $argv = $det->{'kind'} eq 'apt'
				? &packages_command({ %$opts, elevated => 1 }, $det->{'tools'}->{'apt-get'}, 'update')
				: &packages_command({ %$opts, elevated => 1 }, $det->{'tools'}->{'pacman'}, '-Sy');
			return &packages_finish($opts, &packages_run({ %$opts, argv => $argv }), 0);
		},
	});
}

sub packages_upgrade {
	my ($opts) = @_;
	$opts ||= {};
	return &packages_operation({
		%$opts,
		work => sub {
			my $det = &packages_detect($opts);
			return { ok => 0, error => 'no package manager was found on this machine' }
				if $det->{'kind'} ne 'apt' && $det->{'kind'} ne 'pacman';
			return { ok => 0, error => 'the runtime has no package manager' } if $det->{'kind'} eq 'runtime';
			my $argv = $det->{'kind'} eq 'apt'
				? &packages_command({ %$opts, elevated => 1 }, $det->{'tools'}->{'apt-get'}, '-y', 'upgrade')
				: &packages_command({ %$opts, elevated => 1 }, $det->{'tools'}->{'pacman'}, '-Syu', '--noconfirm');
			return &packages_finish($opts, &packages_run({ %$opts, argv => $argv }), 1);
		},
	});
}

sub packages_install {
	my ($name, $opts) = @_;
	$opts ||= {};
	my ($good, $why) = &packages_validate_name($name);
	return { ok => 0, error => $why } unless $good;
	return &packages_operation({
		%$opts,
		work => sub {
			my $det = &packages_detect($opts);
			return { ok => 0, error => 'no package manager was found on this machine' }
				if $det->{'kind'} ne 'apt' && $det->{'kind'} ne 'pacman';
			return { ok => 0, error => 'the runtime has no package manager' } if $det->{'kind'} eq 'runtime';
			my $argv = $det->{'kind'} eq 'apt'
				? &packages_command({ %$opts, elevated => 1 }, $det->{'tools'}->{'apt-get'}, 'install', '-y', $name)
				: &packages_command({ %$opts, elevated => 1 }, $det->{'tools'}->{'pacman'}, '-S', '--noconfirm', $name);
			return &packages_finish($opts, &packages_run({ %$opts, argv => $argv }), 1, $name);
		},
	});
}

sub packages_remove {
	my ($name, $opts) = @_;
	$opts ||= {};
	my ($good, $why) = &packages_validate_name($name);
	return { ok => 0, error => $why } unless $good;
	return &packages_operation({
		%$opts,
		work => sub {
			my $det = &packages_detect($opts);
			return { ok => 0, error => 'no package manager was found on this machine' }
				if $det->{'kind'} ne 'apt' && $det->{'kind'} ne 'pacman';
			return { ok => 0, error => 'the runtime has no package manager' } if $det->{'kind'} eq 'runtime';
			my $argv = $det->{'kind'} eq 'apt'
				? &packages_command({ %$opts, elevated => 1 }, $det->{'tools'}->{'apt-get'}, 'remove', '-y', $name)
				: &packages_command({ %$opts, elevated => 1 }, $det->{'tools'}->{'pacman'}, '-R', '--noconfirm', $name);
			return &packages_finish($opts, &packages_run({ %$opts, argv => $argv }), 1, $name);
		},
	});
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
			return { ok => 0, error => 'no package manager was found on this machine' }
				if $kind ne 'apt' && $kind ne 'pacman';
			return { ok => 0, error => 'the runtime has no package manager' } if $kind eq 'runtime';

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
	my ($opts, $res, $changed, $what) = @_;
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
	return {
		ok        => $res->{'ok'} ? 1 : 0,
		changed   => $res->{'ok'} && $changed ? 1 : 0,
		what      => $what // '',
		status    => $res->{'status'},
		output    => $output,
		error     => $res->{'ok'} ? undef : ($output || 'the package manager failed'),
		restart_needed => &packages_restart_needed($opts) ? 1 : 0,
	};
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
