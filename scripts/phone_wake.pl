#!/usr/bin/perl
# Wake the JawnOS host on the phone from a peer, over adb.
#
# The app's HTTP server lives inside the app process, so a peer cannot reach it
# once Android has killed the app. The app now accepts an explicit wake
# broadcast (JawnWakeReceiver) and, on older builds, opening its dashboard also
# self-tests and starts jawn. Both need adb, so this script connects to the
# phone first.
#
# Usage:
#   perl scripts/phone_wake.pl                 # phone.jonathanferwerda.com:5555
#   perl scripts/phone_wake.pl --host 192.168.2.4 --port 5555
#   perl scripts/phone_wake.pl --dashboard     # open the dashboard instead
#
# Wireless debugging (Android 11+): pair once with `adb pair <ip>:<port>`, then
# pass the connect port (shown in Developer options -> Wireless debugging).
# A USB-connected phone is used as-is.
use strict;
use warnings;

my $host = 'phone.jonathanferwerda.com';
my $port = 5555;
my $dashboard = 0;
while (my $arg = shift @ARGV) {
	if ($arg eq '--host' && @ARGV)    { $host = shift @ARGV; next; }
	if ($arg eq '--port' && @ARGV)    { $port = shift @ARGV; next; }
	if ($arg eq '--dashboard')        { $dashboard = 1; next; }
	if ($arg eq '--help' || $arg eq '-h') {
		print "usage: $0 [--host HOST] [--port 5555] [--dashboard]\n";
		exit 0;
	}
	die "unknown argument: $arg\n";
}

my $adb = `command -v adb 2>/dev/null`;
chomp $adb;
die "adb not found (install android-tools; it ships with the SDK)\n" unless $adb;

# Use an already-connected phone first (USB or a previous adb connect).
my $serial;
foreach my $line ( split /\n/, `"$adb" devices 2>/dev/null` ) {
	next if $line =~ /^\s*List of devices/ || $line !~ /\S/;
	my ($id, $state) = split /\s+/, $line;
	next unless $id && $state && $state eq 'device';
	$serial = $id;
	last;
}

unless ($serial) {
	my $target = "$host:$port";
	my $connect = `"$adb" connect "$target" 2>&1`;
	chomp $connect;
	print "$connect\n";
	if ($connect =~ /connected to/i && $connect !~ /failed|cannot|unable/i) {
		$serial = $target;
	}
	else {
		die "no adb device. Enable Developer options -> Wireless debugging, pair once\n"
		  . "with: adb pair $host:<pair-port>\n"
		  . "then run this again with --port <connect-port>.\n";
	}
}

my $label = $dashboard ? 'dashboard' : 'wake broadcast';
# M4: the app is com.jawnos. The component follows the package, so try the new
# one and fall back to the old fork's for a device still on that build. The
# broadcast action is an app-private string and has not moved yet.
my $app = $ENV{'JAWNOS_APP_PACKAGE'} || 'com.jawnos';
my $wake_component = ".app.JawnWakeReceiver";
my $cmd = $dashboard
	? '"' . $adb . '" -s "' . $serial . '" shell am start -n ' . $app . '/.app.JawnDashboardActivity 2>&1'
	: '"' . $adb . '" -s "' . $serial . '" shell am broadcast -a com.termux.app.JAWN_WAKE -n ' . $app . '/' . $wake_component . ' 2>&1';
my $out = `$cmd`;
chomp $out;
if ($out =~ /does not exist|Unknown component|not found/i && $app eq 'com.jawnos') {
	$app = 'com.termux';
	$cmd = $dashboard
		? '"' . $adb . '" -s "' . $serial . '" shell am start -n ' . $app . '/.app.JawnDashboardActivity 2>&1'
		: '"' . $adb . '" -s "' . $serial . '" shell am broadcast -a com.termux.app.JAWN_WAKE -n ' . $app . '/' . $wake_component . ' 2>&1';
	$out = `$cmd`;
	chomp $out;
}
print "$label on $serial:\n$out\n";

# A build older than the wake receiver reports a missing component; opening the
# dashboard still runs its onResume self-test.
if (!$dashboard && $out =~ /does not exist|Error type|Unknown component|not found/i) {
	print "wake receiver not on this build; opening the dashboard instead\n";
	$out = `"$adb" -s "$serial" shell am start -n $app/.app.JawnDashboardActivity 2>&1`;
	chomp $out;
	print "$out\n";
}
