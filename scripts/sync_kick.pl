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
	my $base = (($ENV{HOME} || (getpwuid $<)[7] || '') . '/perl5/lib/perl5');
	if ($base =~ m{/} && -d $base) {
		my @dirs = ($base);
		if (opendir(my $dh, $base)) {
			for my $name (sort readdir $dh) {
				my $dir = "$base/$name";
				push @dirs, $dir
					if $name ne '.' && $name ne '..' && -d $dir
					&& ($name =~ /-linux-/ || $name =~ /^[0-9]+\.[0-9]+/);
			}
			closedir $dh;
		}
		my %in_inc = map { $_ => 1 } @INC;
		unshift @INC, grep { !$in_inc{$_} } @dirs;
		my $lib = join ':', @dirs;
		$ENV{PERL5LIB} = $ENV{PERL5LIB} ? "$lib:$ENV{PERL5LIB}" : $lib;
	}
}

chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $note = &subs::sync_kick();
print $note, "\n";
print "sync pass nudged\n";
