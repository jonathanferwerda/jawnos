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

sub restore {
	unlink $MARKER;
	system('systemctl', 'start', 'jawnos-kiosk');
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
fail('The RetroArch binary is missing.') unless $runner->{'kind'} ne 'retroarch' || -x '/usr/bin/retroarch';

my (undef, undef, $uid, $gid) = getpwnam($PERSON);
fail('The person this panel belongs to is missing.') unless defined $uid && defined $gid;


make_path('/home/jawn/.presence');
open my $marker, '>', $MARKER or fail('The games marker could not be written.');
close $marker;

my $evdev = mouse_device();

system('systemctl', 'stop', 'jawnos-kiosk');
# The daemon polls its marker four times a second; give the gamepad a beat to
# exist before the emulator scans its controls.
select(undef, undef, undef, 0.6);

my @command;
if ($runner->{'kind'} eq 'standalone') {
	@command = ($runner->{'command'}, '-b', '-e', $game->{'file'});
}
else {
	@command = ('/usr/bin/retroarch', '-f', '-L', $runner->{'core'});
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
