#!/usr/bin/perl
#
# headscale_preauth.pl - mint one short-lived tailnet preauth key for a board.
#
#   perl scripts/headscale_preauth.pl
#
# The key is printed once, as JSON on stdout, and never logged:
#   {"ok":1,"key":"...","login_server":"https://headscale...","expires":"1h"}
# An error prints {"ok":0,"error":"..."} and exits 0, so a caller can decode
# either answer without treating an ordinary refusal as a crash.
#
# The control target is the same one the Crew's Headscale pane uses:
# "<ssh host> <lxc id>" in $ENV{JAWNOS_HEADSCALE_CTL} or
# .secrets/headscale-ctl. A machine without it cannot mint; the caller walks
# its roster until one can. The login server and user id are the house's:
# `house` is user 1 on the Headscale host.
#
# The key is short-lived and single-use. A caller that is handing it to a board
# must seal it to that board (or write it only into the board's 0600 join token)
# and must never put it on a command line or in a log.

use strict;
use warnings;

use JSON::PP ();

my $JSON = JSON::PP->new->canonical(1);
my $LOGIN = ($ENV{'JAWNOS_HEADSCALE_LOGIN'} // '') || 'https://headscale.jonferwerda.com';
my $USER = ($ENV{'JAWNOS_HEADSCALE_USER'} // '') || '1';
my $EXPIRES = ($ENV{'JAWNOS_HEADSCALE_EXPIRATION'} // '') || '1h';

sub fail {
	my ($why) = @_;
	$why = 'the tailnet key could not be minted' unless defined $why && length $why;
	print $JSON->encode({ ok => 0, error => $why }), "\n";
	exit 0;
}

# The control file is a host and an optional LXC id. Read it the way crew.pl
# does, so one file configures both the pane and this mint.
sub control_spec {
	my @paths = grep { defined $_ && length $_ } (
		$ENV{'JAWNOS_HEADSCALE_CTL'},
		(($ENV{'JAWNOS_ROOT'} // '') ne '' ? $ENV{'JAWNOS_ROOT'} . '/.secrets/headscale-ctl' : ()),
		(($ENV{'HOME'} // '') ne '' ? $ENV{'HOME'} . '/jawnos/.secrets/headscale-ctl' : ()),
		'.secrets/headscale-ctl',
	);
	foreach my $path (@paths) {
		next unless -f $path;
		open(my $fh, '<', $path) or next;
		my $line = <$fh>;
		close $fh;
		next unless defined $line;
		$line =~ s/^\s+|\s+$//g;
		my ($host, $lxc) = split /\s+/, $line;
		next unless defined $host && $host =~ /^[A-Za-z0-9._:\-\[\]]{1,255}$/;
		$lxc = '' unless defined $lxc && $lxc =~ /^\d{1,6}$/;
		return ($host, $lxc);
	}
	return ();
}

sub command {
	my ($host, $lxc) = @_;
	my @headscale = ('headscale', 'preauthkeys', 'create', '-u', $USER, '-e', $EXPIRES, '-o', 'json');
	my @remote = @headscale;
	@remote = ('sudo', '-n', 'pct', 'exec', $lxc, '--', @headscale) if length $lxc;
	my $command = join ' ', @remote;
	return (
		'ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new',
		'-o', 'ConnectTimeout=8',
		$host, $command,
	);
}

my ($host, $lxc) = control_spec();
fail('no headscale control on this machine') unless defined $host && length $host;

my @cmd = command($host, $lxc);
my ($out, $status) = ('', -1);
eval {
	open(my $fh, '-|', @cmd) or return;
	local $/;
	$out = <$fh> // '';
	close $fh;
	$status = $? >> 8;
};
fail('the headscale host did not answer') unless $status == 0 && length $out;

my $answer = eval { $JSON->decode($out) };
if (ref $answer eq 'ARRAY') { $answer = $answer->[0] }
fail('the headscale answer was not a preauth key') unless ref $answer eq 'HASH';
my $key = $answer->{'key'} // '';
fail('the headscale answer carried no key') unless length $key;

print $JSON->encode({
	ok => 1,
	key => $key,
	login_server => $LOGIN,
	expires => $EXPIRES,
}), "\n";
