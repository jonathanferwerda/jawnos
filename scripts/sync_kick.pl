#!/usr/bin/env perl
# sync_kick.pl - clear what has stalled this machine's sync and nudge a pass.
#
#   perl scripts/sync_kick.pl
#
# It clears the three brakes and drops an inactive hub, then nudges the ordinary
# remote_machine_sync pass; the running manager runs that pass on its next
# utility tick. The utility controller runs the same subs::sync_kick as the
# "Sync kick" job, so a stuck box can be recovered from a shell too.
use strict;
use warnings;
use FindBin;

# A shell that never sourced ~/.zshrc has only the system @INC, and the first
# Crypt/Mojo require dies. Find the same local::lib tree ./jawn exports so this
# script runs from a plain SSH shell as well as from a sourced one.
BEGIN {
	# Windows has no getpwuid - the call dies rather than answering - and a
	# service or a scheduled task has no HOME, so the home is resolved in the
	# same order as scripts/restart.pl: HOME, USERPROFILE, the older
	# HOMEDRIVE+HOMEPATH pair, then a guarded getpwuid. The unguarded getpwuid
	# this script used to call aborted it on Windows.
	my $home = $ENV{HOME};
	$home = $ENV{USERPROFILE} if !defined $home || !length $home;
	if (!defined $home || !length $home) {
		my $drive = $ENV{HOMEDRIVE} || '';
		my $path  = $ENV{HOMEPATH} || '';
		$home = $drive . $path if length $drive || length $path;
	}
	$home = eval { (getpwuid $<)[7] } if !defined $home || !length $home;
	$home = '' unless defined $home;
	my $base = $home . '/perl5/lib/perl5';
	if ($base =~ m{/} && -d $base) {
		my @dirs = ($base);
		# The local::lib subdirectory names differ per platform. Linux keeps
		# exactly the test it has always had, so its seeded @INC cannot move;
		# Windows names its own flavour directory instead.
		my $flavour = $^O eq 'MSWin32'
			? qr/-(?:MSWin32|cygwin)-|^(?:MSWin32|x86_64|i[3-9]86)\b/i
			: qr/-linux-/;
		if (opendir(my $dh, $base)) {
			for my $name (sort readdir $dh) {
				my $dir = "$base/$name";
				push @dirs, $dir
					if $name ne '.' && $name ne '..' && -d $dir
					&& ($name =~ $flavour || $name =~ /^[0-9]+\.[0-9]+/);
			}
			closedir $dh;
		}
		my %in_inc = map { $_ => 1 } @INC;
		unshift @INC, grep { !$in_inc{$_} } @dirs;
		# PERL5LIB is ';'-separated on Windows and ':' elsewhere.
		my $sep = $^O eq 'MSWin32' ? ';' : ':';
		my $lib = join $sep, @dirs;
		$ENV{PERL5LIB} = $ENV{PERL5LIB} ? "$lib$sep$ENV{PERL5LIB}" : $lib;
	}
}

chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $note = &subs::sync_kick();
print $note, "\n";
print "sync pass nudged\n";
