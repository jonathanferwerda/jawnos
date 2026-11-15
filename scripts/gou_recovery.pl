#!/usr/bin/perl
#
# gou_recovery.pl - ask this ODROID Go Ultra to come back up in recovery.
#
# The eMMC's boot.ini carries a recovery entry: when the BOOT partition holds a
# file called RECOVERY, the bootloader starts the recovery BIOS instead of
# JawnOS. That BIOS exports the eMMC over USB, so the board can be flashed
# again from the Controllers page with no microSD in the slot.
#
#   gou_recovery.pl               arm recovery and restart
#   gou_recovery.pl --no-reboot   arm recovery, stay running
#   gou_recovery.pl --clear       disarm
#   gou_recovery.pl --status      exit 0 when armed, 1 when not
#
# The marker lives on the mounted BOOT partition (/boot/oem per /etc/fstab);
# --mount names it instead. A reflash rewrites the BOOT partition, which clears
# it, so recovery is not sticky.

use strict;
use warnings;

use Getopt::Long ();

my $MARKER = 'RECOVERY';

my %opt;
Getopt::Long::Configure('no_ignore_case');
Getopt::Long::GetOptions(
	'no-reboot' => \$opt{'no_reboot'},
	'clear'     => \$opt{'clear'},
	'status'    => \$opt{'status'},
	'mount=s'   => \$opt{'mount'},
	'help|h'    => \$opt{'help'},
) or _die('bad options');

if ($opt{'help'}) {
	print <<'USAGE';
gou_recovery.pl [--no-reboot] [--clear] [--status] [--mount PATH]
  arm the eMMC recovery entry and restart the board.
USAGE
	exit 0;
}

my $dir = defined $opt{'mount'} && length $opt{'mount'} ? $opt{'mount'} : '/boot/oem';
my $path = "$dir/$MARKER";

if ($opt{'status'}) {
	exit(-f $path ? 0 : 1);
}

if ($opt{'clear'}) {
	unlink $path;
	print(-f $path ? "could not remove $path\n" : "recovery is not armed\n");
	exit(-f $path ? 1 : 0);
}

unless (-d $dir) {
	_die("no BOOT partition at $dir; name it with --mount");
}

open my $fh, '>:raw', $path or _die("could not write $path: $!");
my $printed = print {$fh} "recovery\n";
my $closed = close $fh;
unless ($printed && $closed) {
	unlink $path;
	_die("could not write $path");
}
system('sync');
print "recovery is armed; the board comes back in recovery mode\n";

if ($opt{'no_reboot'}) {
	print "not restarting (--no-reboot)\n";
	exit 0;
}

print "restarting...\n";
exec('reboot') or _die("could not restart: $!");

sub _die {
	my ($message) = @_;
	print STDERR "gou_recovery: $message\n";
	exit 1;
}
