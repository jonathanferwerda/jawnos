package JawnOS::Platform::Shell;

# The small desktop surfaces, in one seam: the clipboard, opening a URL or a
# path, a desktop notification, and the terminal list.
#
# Linux keeps today's tools and arguments exactly. The clipboard reads and
# writes through xclip, then xsel, then wl-paste/wl-copy; a URL or a file opens
# with the system xdg-open; a notification is notify-send; and the terminal
# list is the same X11/Wayland list the desktop app holds in
# desktop/jawnos_desktop/core_shell.py (its _TERMINALS). That file is the twin
# of this one: change both together until the macOS and Windows branches
# (docs/platform-roadmap.md P2/P3) move the list into one place.
#
# A machine with none of the tools answers ''/undef/0 and does nothing, which
# is what every caller did before: a paste is typed instead of copied, and an
# open that has nowhere to go is reported as not opened.
#
# Nothing here reads the database, opens a socket or logs. open_url, open_path
# and notify fork and exec a detached opener (the child owns its own session
# and loses the inherited stdio), so a caller never waits on a browser.
#
# macOS (pbcopy/pbpaste, open, osascript) and Windows (clip.exe, ShellExecute,
# a toast) are deliberately left to P2/P3: this module gives the empty answers
# above on a platform where the Linux tools are not installed.

use strict;
use warnings;

use POSIX ();

use Exporter 'import';
our @EXPORT_OK = qw(
	clipboard_get clipboard_set open_url open_path notify
	terminal_argv terminals
);

our $VERSION = '0.01';

# Test hooks. TOOL_LOOKUP answers "where is this tool" instead of reading
# PATH; RUN records or answers a capture/feed instead of starting the tool;
# SPAWN records a detached launch; OPEN_COMMAND replaces the /usr/bin probe.
# Nothing in a running house sets them.
our $TOOL_LOOKUP;
our $RUN;
our $SPAWN;
our $OPEN_COMMAND;

# The terminal list, in preference order, with the flag that makes each one
# run a command. This is _TERMINALS in core_shell.py.
my @TERMINALS = (
	[ 'x-terminal-emulator', ['-e'] ],
	[ 'kgx',                 ['-e'] ],
	[ 'gnome-terminal',      ['--'] ],
	[ 'konsole',             ['-e'] ],
	[ 'alacritty',           ['-e'] ],
	[ 'kitty',               [] ],
	[ 'wezterm',             [ 'start', '--' ] ],
	[ 'xterm',               ['-e'] ],
);

sub _tool {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	return $TOOL_LOOKUP->($name) if $TOOL_LOOKUP;
	require JawnOS::Platform;
	return JawnOS::Platform::tool_path($name);
}

# The system opener, and only the system one: both call sites checked
# /usr/bin/xdg-open before this seam existed, so that is still the answer.
sub _opener {
	return $OPEN_COMMAND if defined $OPEN_COMMAND;
	return -x '/usr/bin/xdg-open' ? '/usr/bin/xdg-open' : undef;
}

# Read a tool's stdout. The clipboard tools hang when no selection owner is
# alive, which is why every read is wrapped in timeout 2; stderr is dropped
# because a headless session prints an X11 warning that is not an error here.
sub _capture {
	my (@argv) = @_;
	return $RUN->([@argv], undef) if $RUN;
	my $pid = open(my $fh, '-|');
	return '' unless defined $pid;
	unless ($pid) {
		open(STDERR, '>', '/dev/null');
		{ no warnings 'exec'; exec @argv; }
		POSIX::_exit(127);
	}
	my $out = do { local $/; <$fh> } // '';
	close $fh;
	return $out;
}

# Feed bytes to a tool's stdin. A tool that cannot be started is a failed
# write, which is what the old list-form pipe open returned.
sub _feed {
	my ($bytes, @argv) = @_;
	return $RUN->([@argv], $bytes) ? 1 : 0 if $RUN;
	open(my $fh, '|-', @argv) or return 0;
	print {$fh} $bytes;
	close $fh;
	return 1;
}

# Fork the opener off and let it go. A double fork keeps the manager from
# holding a zombie: the middle child exits at once (the parent reaps it) and
# the grandchild, reparented to init, sets its own session, drops the
# inherited stdio and execs. The caller is told the launch happened; the
# opener's own exit status is nobody's to read.
sub _spawn {
	my (@argv) = @_;
	return $SPAWN->([@argv]) ? 1 : 0 if $SPAWN;
	my $pid = fork();
	return 0 unless defined $pid;
	if ($pid) {
		waitpid($pid, 0);
		return 1;
	}
	my $grandchild = fork();
	POSIX::_exit(0) unless defined $grandchild && $grandchild == 0;
	eval {
		POSIX::setsid();
		open(STDIN, '<', '/dev/null');
		open(STDOUT, '>', '/dev/null');
		open(STDERR, '>', '/dev/null');
		{ no warnings 'exec'; exec @argv; }
	};
	POSIX::_exit(127);
}

# ------------------------------------------------------------ the clipboard

sub clipboard_get {
	my $out = '';
	if (_tool('xclip')) {
		$out = _capture('timeout', '2', 'xclip', '-selection', 'clipboard', '-o');
	}
	elsif (_tool('xsel')) {
		$out = _capture('timeout', '2', 'xsel', '--clipboard', '--output');
	}
	elsif (_tool('wl-paste')) {
		$out = _capture('timeout', '2', 'wl-paste', '--no-newline');
	}
	utf8::decode($out) if defined $out && length $out && !utf8::is_utf8($out);
	return $out;
}

# The bytes go to the tool, not the characters: xclip and its siblings take
# whatever encoding the locale names, and a decoded Perl string would be
# written as Latin-1.
sub clipboard_set {
	my ($text) = @_;
	my $bytes = defined $text ? $text : '';
	utf8::encode($bytes) if utf8::is_utf8($bytes);
	if (_tool('xclip')) {
		return _feed($bytes, 'xclip', '-selection', 'clipboard');
	}
	if (_tool('xsel')) {
		return _feed($bytes, 'xsel', '--clipboard', '--input');
	}
	if (_tool('wl-copy')) {
		return _feed($bytes, 'wl-copy');
	}
	return 0;
}

# ------------------------------------------------------------ opening things

sub open_url {
	my ($url) = @_;
	return 0 unless defined $url && length $url;
	my $opener = _opener();
	return 0 unless defined $opener && length $opener;
	return _spawn($opener, $url);
}

# A file and a URL take the same opener; the caller keeps the distinction so a
# future macOS/Windows branch can treat them differently.
sub open_path {
	my ($path) = @_;
	return 0 unless defined $path && length $path;
	my $opener = _opener();
	return 0 unless defined $opener && length $opener;
	return _spawn($opener, $path);
}

# ------------------------------------------------------------ notifications

sub notify {
	my ($title, $body) = @_;
	my $tool = _tool('notify-send');
	return 0 unless defined $tool && length $tool;
	return _spawn($tool, defined $title ? $title : '', defined $body ? $body : '') ? 1 : 0;
}

# ------------------------------------------------------------ terminals

# The list as name and run-flag pairs, so a caller can show what this machine
# would use without starting anything.
sub terminals {
	return map { [ $_->[0], [ @{$_->[1]} ] ] } @TERMINALS;
}

# The argv that runs @cmd in the first installed terminal, or an empty list
# when none is. The first element is the tool's path, as core_shell.py's
# shutil.which would give.
sub terminal_argv {
	my (@cmd) = @_;
	foreach my $terminal (@TERMINALS) {
		my $path = _tool($terminal->[0]);
		next unless defined $path && length $path;
		return ($path, @{$terminal->[1]}, @cmd);
	}
	return ();
}

1;
