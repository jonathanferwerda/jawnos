#!/usr/bin/perl

# What this machine can do for JawnOS, in one command. P0's answer to "will
# this box run the house?" before anyone tries to install it.
#
#   perl scripts/platform_probe.pl            human-readable report
#   perl scripts/platform_probe.pl --json     the same facts as JSON
#   perl scripts/platform_probe.pl --check    exit 1 when a required module is absent
#
# It starts no server, opens no socket and touches no database, so it is safe
# on a CI runner, a fresh Windows box, or the machine already serving a house.

use strict;
use warnings;

# A machine's modules may live in the same local::lib tree ./jawn adds; a probe
# that saw only the system @INC would report a working house as missing its
# backend. Keep the platform names general so the same block serves macOS and
# Windows.
BEGIN {
	# Windows has no getpwuid - the call dies there - and its home is
	# USERPROFILE, with HOMEDRIVE+HOMEPATH as the older pair. Same order as
	# JawnOS::Platform::home, because a probe that guessed another tree would
	# report a working house as missing its backend.
	my $home = $ENV{'HOME'};
	$home = $ENV{'USERPROFILE'} if !defined $home || !length $home;
	if (!defined $home || !length $home) {
		my $drive = $ENV{'HOMEDRIVE'} || '';
		my $path = $ENV{'HOMEPATH'} || '';
		$home = $drive . $path if length $drive || length $path;
	}
	$home = eval { (getpwuid $<)[7] } if !defined $home || !length $home;
	$home = '' unless defined $home;
	my $base = "$home/perl5/lib/perl5";
	if ($base =~ m{/} && -d $base) {
		my @dirs = ($base);
		if (opendir(my $dh, $base)) {
			for my $name (sort readdir $dh) {
				my $dir = "$base/$name";
				push @dirs, $dir
					if $name ne '.' && $name ne '..' && -d $dir
					&& ($name =~ /-(?:linux|darwin|MSWin32|cygwin)-/i
						|| $name =~ /^(?:MSWin32|darwin|x86_64|i[3-9]86)\b/i
						|| $name =~ /^[0-9]+\.[0-9]+/);
			}
			closedir $dh;
		}
		my %in_inc = map { $_ => 1 } @INC;
		unshift @INC, grep { !$in_inc{$_} } @dirs;
	}
}

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Getopt::Long qw(GetOptions);
use JSON::PP ();
use JawnOS::Platform ();

sub usage {
	print <<'USAGE';
usage: perl scripts/platform_probe.pl [--json] [--check]

  --json    print the report as JSON
  --check   exit 1 if a required Perl module is missing
  --help    this text
USAGE
	return;
}

my ($json, $check, $help);
GetOptions(
	'json'  => \$json,
	'check' => \$check,
	'help|h' => \$help,
) or do { usage(); exit 2 };
if ($help) { usage(); exit 0; }

my $probe = JawnOS::Platform::capabilities();
my @missing = @{ $probe->{'missing_required'} || [] };

if ($json) {
	print JSON::PP->new->canonical->pretty->encode($probe);
}
else {
	print "JawnOS platform probe\n";
	print 'os: ', $probe->{'os'}, "\n";
	print 'arch: ', $probe->{'arch'}, "\n";
	print 'perl: ', $probe->{'perl_version'}, ' (ithreads ', ($probe->{'ithreads'} ? 'yes' : 'no'), ")\n";
	print 'mode: ', $probe->{'mode'},
		' (portable ', ($probe->{'portable'} ? 'yes' : 'no'),
		', strict ', ($probe->{'strict'} ? 'yes' : 'no'), ")\n";
	print 'available: fork ', ($probe->{'fork_available'} ? 'yes' : 'no'),
		($probe->{'fork_emulated'} ? ' (emulated)' : ''),
		', pty ', ($probe->{'pty_available'} ? 'yes' : 'no'),
		', unix-socket ', ($probe->{'unix_socket_available'} ? 'yes' : 'no'), "\n";
	print 'in use: fork ', ($probe->{'use_fork'} ? 'yes' : 'no'),
		', pty ', ($probe->{'use_pty'} ? 'yes' : 'no'),
		', unix-socket ', ($probe->{'use_unix_socket'} ? 'yes' : 'no'), "\n";
	print 'transport: ', $probe->{'transport'},
		' (preferred ', $probe->{'preferred_transport'}, ")\n";
	print 'tree: ', $probe->{'tree_dir'}, "\n";
	print 'data: ', $probe->{'data_dir'}, "\n";

	print "modules:\n";
	foreach my $name (sort keys %{ $probe->{'modules'} }) {
		my $version = $probe->{'modules'}{$name};
		my $state = !defined $version ? 'MISSING' : (length($version) ? $version : 'installed');
		printf "  %-32s %s\n", $name, $state;
	}

	print "tools:\n";
	foreach my $name (sort keys %{ $probe->{'tools'} }) {
		printf "  %-32s %s\n", $name, ($probe->{'tools'}{$name} ? 'yes' : 'no');
	}

	my @serial = @{ $probe->{'serial_devices'} || [] };
	print 'serial: ', (@serial ? join(', ', @serial) : '(none)'), "\n";
	print 'missing required: ', (@missing ? join(', ', @missing) : '(none)'), "\n";
}

if ($check && @missing) {
	print STDERR 'platform probe: missing required module(s): ', join(', ', @missing), "\n";
	exit 1;
}

exit 0;
