#!/usr/bin/perl
# Run one emulated game on the panel and bring the JawnOS view back.
#
#   perl scripts/jawnos_game_launch.pl <game id>
#
# The manager resolves the id against the library first, so this helper only
# has to re-find the same file. It runs as root (the manager calls it through
# `sudo -n`), drops to the person for the emulator itself, and:
#
#   * touches the games marker, so gou_inputd creates the virtual gamepad and
#     hands A/B/X/Y, both sticks and the D-pad to it;
#   * stops the kiosk, so the emulator has the panel and no browser competes;
#   * runs RetroArch (or the standalone emulator) on DISPLAY=:0;
#   * watches the controls for the Home button, so one press ends the game;
#   * starts the kiosk again and removes the marker on the way out.
#
# Every step has a fixed argument list; the game id is checked against the
# library, never used as a path.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Path qw(make_path);
use JSON::PP ();
use POSIX ();
use JawnOS::Games ();

my $ID = shift @ARGV // '';
my $ROMS = '/home/jawn/roms';
my $PERSON = 'jawn';
my $MARKER = '/home/jawn/.presence/gou-games';
my $STATE = '/run/jawnos-games';
my $FILE = "$STATE/launch.json";
my $JSON = JSON::PP->new->canonical(1);
my $HOME_KEY = 102;   # KEY_HOME, which gou_inputd sends for the Home button

my %STATUS = (state => 'starting', at => time, game => '');
my ($child, $interrupted);

sub write_status {
	make_path($STATE);
	open my $fh, '>', "$FILE.tmp" or return;
	print $fh $JSON->encode(\%STATUS);
	close $fh;
	rename "$FILE.tmp", $FILE;
	chmod 0644, $FILE;
}

sub kiosk_active {
	return system('systemctl', 'is-active', '--quiet', 'jawnos-kiosk') == 0;
}

my $kiosk_window;      # the kiosk's window, remembered across the game
my $kiosk_hidden = 0;  # whether this run hid it

# The kiosk is one window on the panel's X server, and hiding it for the length
# of a game is what makes the way back instant. Stopping the unit costs its own
# ExecStartPre sleep plus a cold Qt WebEngine start - six seconds on this box,
# before the page has drawn anything. Shown again it is already running and has
# kept its session, so one map request brings the launcher back.
#
# xdotool runs as the person, whose X authority reaches the server; this helper
# is root. A window that cannot be found or shown falls back to the restart
# below, which is also what gou-kiosk-guard.timer does if this helper dies.
sub xdotool {
	my (@args) = @_;
	my $pid = open(my $out, '-|');
	return '' unless defined $pid;
	if (!$pid) {
		exec('/usr/bin/setpriv', '--reuid=' . $PERSON, '--regid=' . $PERSON,
			'--init-groups', '--', '/usr/bin/env', 'DISPLAY=:0',
			'/usr/bin/xdotool', @args);
		POSIX::_exit(127);
	}
	my $text = do { local $/; <$out> } // '';
	close $out;
	return $text;
}

# The window's class is the one the desktop app sets, so it is found by what it
# is rather than by an id that moves between launches.
sub kiosk_window {
	my ($id) = grep { /^\d+$/ }
		split ' ', xdotool('search', '--onlyvisible', '--class', 'JawnOS');
	return $id;
}

sub hide_kiosk {
	$kiosk_window = kiosk_window();
	if (!defined $kiosk_window) {
		# nothing to hide: the unit itself has to go, as it always did
		system('systemctl', 'stop', 'jawnos-kiosk');
		$kiosk_hidden = 1;
		return;
	}
	xdotool('windowunmap', $kiosk_window);
	# Hidden is not idle enough. The page keeps its timers, and a browser that
	# paints in software takes the CPU the emulator wants; frozen, the whole
	# unit's cgroup spends nothing and the page is still there to resume.
	system('systemctl', 'kill', '--signal=SIGSTOP', 'jawnos-kiosk');
	$kiosk_hidden = 1;
}

sub restore {
	unlink $MARKER;
	return unless $kiosk_hidden;
	$kiosk_hidden = 0;
	# woken before it is shown: a stopped window would draw nothing
	system('systemctl', 'kill', '--signal=SIGCONT', 'jawnos-kiosk');
	if (defined $kiosk_window) {
		xdotool('windowmap', $kiosk_window);
		xdotool('windowraise', $kiosk_window);
		xdotool('windowactivate', $kiosk_window);
		# the server is the one that knows: only a mapped window answers
		return if defined kiosk_window();
	}
	# Starting the kiosk once is not enough: it can lose the race with the
	# display the emulator has just released, and a start that fails leaves the
	# panel on the bare X cursor. Restart it, wait for it, then try once more.
	system('systemctl', 'restart', 'jawnos-kiosk');
	for (1 .. 20) {
		select(undef, undef, undef, 0.5);
		return if kiosk_active();
	}
	system('systemctl', 'restart', 'jawnos-kiosk');
}

sub fail {
	my ($message) = @_;
	$STATUS{'state'} = 'failed';
	$STATUS{'error'} = $message;
	$STATUS{'finished'} = time;
	write_status();
	restore();
	exit 1;
}

# The daemon's own uinput node, so the Home button still reaches us while an
# emulator holds the panel. The event number moves between boots, so it is read
# from the device table by name each time.
sub mouse_device {
	open my $fh, '<', '/proc/bus/input/devices' or return undef;
	my ($name, $handlers) = ('', '');
	while (my $line = <$fh>) {
		if ($line =~ /^N: Name="(.*)"\s*$/) { $name = $1; }
		if ($line =~ /^H: Handlers=(.*)$/ && $name eq 'jawnos-gou mouse') {
			my ($event) = $1 =~ /\b(event\d+)\b/;
			return "/dev/input/$event" if defined $event;
		}
		if ($line =~ /^\s*$/) { $name = ''; }
	}
	close $fh;
	return undef;
}

$STATUS{'game'} = $ID;
write_status();

fail('That game is not in the library.') unless $ID =~ /^[0-9a-f]{40}$/;
my $game = JawnOS::Games::find($ROMS, $ID);
fail('That game is not in the library.') unless ref $game eq 'HASH';
$STATUS{'title'} = $game->{'title'};
write_status();

my $runner = JawnOS::Games::runner_for($game->{'system'});
fail('There is no emulator for ' . $game->{'system_label'} . '.') unless ref $runner eq 'HASH';
fail('The emulator is not installed.') if $runner->{'missing'};
my $retroarch = JawnOS::Games::retroarch_binary();
fail('The RetroArch binary is missing.') unless $runner->{'kind'} ne 'retroarch' || defined $retroarch;

my (undef, undef, $uid, $gid) = getpwnam($PERSON);
fail('The person this panel belongs to is missing.') unless defined $uid && defined $gid;


make_path('/home/jawn/.presence');
open my $marker, '>', $MARKER or fail('The games marker could not be written.');
close $marker;

my $evdev = mouse_device();

hide_kiosk();
# The daemon polls its marker four times a second; give the gamepad a beat to
# exist before the emulator scans its controls.
select(undef, undef, undef, 0.6);

my @command;
if ($runner->{'kind'} eq 'standalone') {
	@command = ($runner->{'command'}, '-b', '-e', $game->{'file'});
}
else {
	@command = ($retroarch, '-f', '-L', $runner->{'core'});
	# RetroArch's default audio device is one this image never configured. The
	# append config pins ALSA to the panel's card, so a game has sound without a
	# visit to the settings menu.
	push @command, '--appendconfig', '/home/jawn/.config/retroarch/gou.cfg'
		if -f '/home/jawn/.config/retroarch/gou.cfg';
	push @command, $game->{'file'};
}

$child = fork();
if (!defined $child) {
	fail('The emulator could not be started.');
}
if (!$child) {
	POSIX::setsid();
	$ENV{'DISPLAY'} = ':0';
	$ENV{'XDG_RUNTIME_DIR'} = '/run/user/' . $uid;
	$ENV{'HOME'} = '/home/jawn';
	$ENV{'SDL_AUDIODRIVER'} = 'alsa';
	no warnings 'exec';
	# A bare setuid keeps root's supplementary groups, and the person's audio,
	# input and video groups are what open the sound card and the gamepad. A
	# login initialises them from /etc/group; setpriv does the same here.
	if (-x '/usr/bin/setpriv') {
		exec('/usr/bin/setpriv', '--reuid=' . $PERSON, '--regid=' . $PERSON,
			'--init-groups', '--', @command);
	}
	if (-x '/usr/bin/runuser') {
		exec('/usr/bin/runuser', '-u', $PERSON, '--', @command);
	}
	POSIX::setgid($gid);
	POSIX::setuid($uid);
	exec @command;
	POSIX::_exit(127);
}

$SIG{'TERM'} = sub {
	kill 'TERM', -$child if $child;
	$interrupted = 1;
};
$SIG{'INT'} = $SIG{'TERM'};

if (defined $evdev && open(my $ev, '<', $evdev)) {
	my $readable = '';
	vec($readable, fileno($ev), 1) = 1;
	while (!$interrupted && waitpid($child, POSIX::WNOHANG()) == 0) {
		my $ready = $readable;
		next unless select($ready, undef, undef, 0.25);
		my $buffer = '';
		my $got = sysread($ev, $buffer, 24 * 32);
		next unless $got;
		for (my $at = 0; $at + 24 <= $got; $at += 24) {
			my (undef, undef, $type, $code, $value) = unpack('q<q<S<S<l<', substr($buffer, $at, 24));
			if ($type == 1 && $code == $HOME_KEY && $value == 1) {
				kill 'TERM', -$child;
			}
		}
	}
	close $ev;
}
else {
	waitpid($child, 0);
}

# A term, then a firm kill if the emulator is slow to let go.
for (1 .. 20) {
	last if waitpid($child, POSIX::WNOHANG()) != 0;
	select(undef, undef, undef, 0.25);
}
if (waitpid($child, POSIX::WNOHANG()) == 0) {
	kill 'KILL', -$child;
	waitpid($child, 0);
}

$STATUS{'state'} = 'done';
$STATUS{'finished'} = time;
write_status();
restore();
exit 0;

1;
