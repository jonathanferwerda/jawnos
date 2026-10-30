use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use JawnOSTest;

# M0 contracts (docs/leaving-termux.md): every Android device command goes
# through subs::device_cmd / device_run / device_bin, and the three functions
# keep the shell command and its arguments exactly as the call site spelled
# them. M1 replaces those three bodies, so this file is the behaviour the call
# sites are allowed to rely on.
#
# The second half is the ratchet: scripts/termux_ledger.pl --check fails when a
# raw termux-* call site, a new command, tool or module appears beyond the M0
# baseline. A migration decrements the baseline in the same commit.

is(subs::device_cmd('battery-status'), 'termux-battery-status',
	'a bare name becomes the termux command');
is(subs::device_cmd('termux-open'), 'termux-open',
	'a name already carrying the prefix is not doubled');
is(subs::device_cmd('open', ''), 'termux-open',
	'an empty argument string adds no trailing space');
is(subs::device_cmd('sms-send', '-n 555 "hello"'), 'termux-sms-send -n 555 "hello"',
	'the argument string is passed through unchanged, quoting included');
is(subs::device_bin('location'), '/data/data/com.termux/files/usr/bin/termux-location',
	'the capability probe names the same binary the call would run');

# device_run executes through the shell with the optional prefix in front. A
# fake command on PATH proves it without a phone.
my $dir = tempdir(CLEANUP => 1);
open(my $fh, '>', "$dir/termux-toast") or die $!;
print $fh qq{#!/bin/sh\nprintf '%s\\n' "\$*"\n};
close $fh;
chmod 0755, "$dir/termux-toast" or die $!;

{
	local $ENV{PATH} = "$dir:$ENV{PATH}";
	is(subs::device_run('toast', 'hello there'), "hello there\n",
		'device_run runs the wrapped command and returns its output');
	is(subs::device_run('toast', 'world', 'echo prefix; '), "prefix\nworld\n",
		'a prefix runs before the command (timeout, a pipe)');
}

# The ratchet.
my $ledger = "$FindBin::Bin/../scripts/termux_ledger.pl";
my $out = qx{"$^X" "$ledger" --check 2>&1};
my $rc = $? >> 8;
is($rc, 0, 'termux_ledger --check passes: no new termux dependency') or diag($out);
like($out, qr/termux_ledger: ok/, 'the ledger reports its baseline counts');

# M1 exit (docs/leaving-termux.md): the app's bridge answers a command or the
# shell fallback is gone. This is the exact set still allowed to fall back, so
# a command that silently regains a termux call fails here as well as in the
# ledger, and the list reads as the to-do for the next device proof.
my $held = join ' ', qw(
	termux-call-log termux-open termux-sms-list termux-sms-send
	termux-telephony-call termux-telephony-deviceinfo
);
my $record = qx{"$^X" "$ledger" --record 2>&1};
my ($listed) = $record =~ /'command_list'\s*=>\s*'([^']*)'/;
is(($listed // ''), $held, 'only the awaited commands still fall back to termux');

# The one raw call site M0 deliberately leaves: the first-run wizard, which
# loads no runtime module and goes away in M3.
my $setup = do {
	open(my $sf, '<', "$FindBin::Bin/../scripts/jawnos_setup.pl") or die $!;
	local $/;
	<$sf>;
};
like($setup, qr/system\("termux-open /, 'the wizard still opens the browser the old way (exempt)');

# M2 (docs/leaving-termux.md): the master names the interpreter it is running
# under instead of letting the shell resolve President.pl's "#!" line, which on
# a device only works through termux-exec's LD_PRELOAD. The app's supervisor
# runs the tree without termux-exec, so this is what keeps it launching.
my $master = do {
	open(my $jf, '<', "$FindBin::Bin/../jawn") or die $!;
	local $/;
	<$jf>;
};
like($master, qr/sub president_command/, 'the master builds the tree command itself');
like($master, qr/exec '\$interp' \.\/President\.pl/, 'and it execs the interpreter by path');
unlike($master, qr/'program'\s*=>\s*'\.\/President\.pl'/, 'nothing relies on the shebang');

done_testing();
