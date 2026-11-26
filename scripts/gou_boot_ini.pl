#!/usr/bin/perl
#
# gou_boot_ini.pl - keep the eMMC's boot.ini from booting a card in the slot.
#
# The stock ODROID Go Ultra boot.ini starts with
#
#   if load mmc 1:1 0x1F000000 boot.ini; then source 0x1F000000; fi
#
# On the eMMC's u-boot mmc 0 is the eMMC and mmc 1 is the microSD. With a card
# in the slot that line runs the card's own boot.ini, so the board boots the
# card - or stops at the HardKernel logo when the card cannot start - instead
# of JawnOS on the eMMC. A card here is data: the first-boot pass adopts it and
# /etc/fstab mounts it, so the bootloader must not treat it as a boot medium.
#
# This script comments that one line out. Everything else in the file stays
# byte for byte, and a second run says "already" rather than touching it.
#
#   gou_boot_ini.pl --no-sd-chainload FILE
#       Print "removed" when the line was there, "already" when it was not.
#       A missing or unreadable file is an error (exit 2).
#
# The image builder, the provisioner and the board's first-boot pass all call
# this, so the pattern is in one place.

use strict;
use warnings;

use Getopt::Long ();

# The marker is the first comment line this script writes. Its presence makes
# the pass idempotent even when an earlier run's commented copy was rewritten.
my $MARKER = 'JawnOS: no microSD chainload';

sub disable_sd_chainload {
	my ($path) = @_;
	return { ok => 0, error => 'no boot.ini was named' }
		unless defined $path && length $path;
	return { ok => 0, error => "no such boot.ini: $path" } unless -f $path;
	my $text = _slurp($path);
	return { ok => 0, error => "could not read $path" } unless defined $text;
	return { ok => 1, state => 'already' } if index($text, $MARKER) >= 0;

	# The address differs by build, so the device number and the file name are
	# what the line is recognised by. The recovery entry loads RECOVERY, not a
	# boot.ini, so it cannot match.
	my $pattern = qr/^([ \t]*)(if load mmc [0-9]+:1 [^ \t]+ boot\.ini; then source [^ \t]+; fi)[ \t]*(\r?)$/m;
	my $changed = 0;
	$text =~ s{$pattern}{
		$changed = 1;
		my $eol = defined $3 ? $3 : '';
		"# $MARKER. A card in the slot is data; the eMMC boots.$eol\n"
			. "$1# $2$eol"
	}ge;
	return { ok => 1, state => 'already' } unless $changed;
	return { ok => 0, error => "could not write $path" } unless _write_file($path, $text);
	return { ok => 1, state => 'removed' };
}

sub _slurp {
	my ($path) = @_;
	open my $fh, '<:raw', $path or return undef;
	local $/;
	my $bytes = <$fh>;
	close $fh;
	return $bytes;
}

sub _write_file {
	my ($path, $bytes) = @_;
	open my $fh, '>:raw', $path or return 0;
	my $printed = print {$fh} $bytes;
	my $closed = close $fh;
	return ($printed && $closed) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# main

unless (caller) {
	my $file;
	my $help = 0;
	Getopt::Long::Configure('no_ignore_case');
	Getopt::Long::GetOptions(
		'no-sd-chainload=s' => \$file,
		'help|h'            => \$help,
	) or _die('bad options');

	if ($help || !defined $file) {
		print <<'USAGE';
gou_boot_ini.pl --no-sd-chainload FILE
USAGE
		exit($help ? 0 : 2);
	}

	my $result = disable_sd_chainload($file);
	_die($result->{'error'}) unless $result->{'ok'};
	print "$result->{'state'}\n";
	exit 0;
}

sub _die {
	my ($message) = @_;
	print STDERR "gou_boot_ini: $message\n";
	exit 2;
}
