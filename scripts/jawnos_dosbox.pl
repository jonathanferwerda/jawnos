#!/usr/bin/perl
# Run one DOS game through DOSBox for the emulated shelf.
#
#   jawnos-dosbox -b -e <game file>
#
# The launch helper runs a standalone emulator as `<command> -b -e <file>`,
# the shape Dolphin used. DOSBox ignores the two switches and takes the file
# positionally: it mounts that file's folder as C: and starts it, which it
# already knows how to do for exe/com/bat, img/ima and iso/cue. A .conf is the
# one thing it cannot take positionally (it would try to run it as a
# programme), so this wrapper turns a .conf into `-conf` and passes everything
# else straight through. It also pins the person's settings and asks for the
# whole panel.
#
# A .conf is the clean entry point: a DOSBox config whose `[autoexec]` holds
# the game's mount/run lines (and an `exit` line for a loose programme).
use strict;
use warnings;

my $DOSBOX = '/usr/bin/dosbox';
my $CONFIG = '/home/jawn/.config/dosbox/gou.conf';

my ($file, $stripped, @rest);
my @arguments = @ARGV;
while (defined(my $argument = shift @arguments)) {
	next if $argument eq '-b';
	if ($argument eq '-e') {
		$file = shift @arguments;
		$stripped = 1;
		next;
	}
	push @rest, $argument;
}
my @positional = $stripped ? ((defined $file ? ($file) : ()), @rest) : @rest;
$file = $positional[-1] if !$stripped && @positional;

my @command = ($DOSBOX, '-fullscreen', '-exit');
push @command, '-conf', $CONFIG if -f $CONFIG;
if (defined $file && $file =~ /\.conf$/i) {
	push @command, '-conf', $file;
}
else {
	push @command, @positional;
}
exec @command;
