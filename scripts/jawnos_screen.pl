#!/usr/bin/perl
# Dark idle for the handheld, not a powered-down panel.
#
# The ODROID Go Ultra's panel is driven by the bootloader's simple-framebuffer:
# there is no /sys/class/backlight, no PWM and no DRM connector, and fb0/blank
# rejects FB_BLANK. The only dark a controller can give is to stop the painters,
# black the framebuffer and drop the CPU to powersave. The panel rail stays on,
# so this is a dark idle, not a powered-down panel.
#
#   perl scripts/jawnos_screen.pl off|on|status [--dry-run]
#
# off:  stop kiosk/rotate/X, black /dev/fb0, powersave at 1.0 GHz
# on:   restore the CPU values saved by off, start X/rotate/kiosk
#
# On a machine without the Gou units it does nothing and exits 3, so the
# generic xset/backlight paths in Misc.pm still run. It is root-only for the
# two changes (systemctl and /dev/fb0); Misc.pm retries through `sudo -n`.
use strict;
use warnings;
use JSON::PP ();
use File::Path qw(make_path);

my $ROOT = $ENV{'JAWNOS_SCREEN_ROOT'} || '';
my $STATE = $ENV{'JAWNOS_SCREEN_STATE'} || '/run/jawnos-screen';
my $DRY = 0;
my $ACTION = 'status';
for my $arg (@ARGV) {
	if ($arg eq '--dry-run') { $DRY = 1; }
	elsif ($arg =~ /^(?:off|on|status)$/) { $ACTION = $arg; }
}
my $MARKER = "$STATE/off";
my $CPU_FILE = "$STATE/cpu.tsv";

sub path {
	my ($p) = @_;
	return $p if length $ROOT && index($p, $ROOT) == 0;
	return $ROOT . $p;
}
sub slurp {
	my ($p) = @_;
	open my $fh, '<', path($p) or return '';
	local $/;
	my $s = <$fh> // '';
	$s =~ s/\s+\z//;
	return $s;
}
sub spit {
	my ($p, $v) = @_;
	open my $fh, '>', path($p) or return 0;
	print $fh $v;
	close $fh;
	return 1;
}
sub sys_run {
	my (@cmd) = @_;
	return 0 if $DRY;
	system(@cmd);
	return $? == 0 ? 0 : 1;
}
sub say_json {
	my ($h) = @_;
	print JSON::PP->new->canonical->encode($h), "\n";
}
sub is_gou {
	return 1 if $ENV{'JAWNOS_SCREEN_FORCE'};
	return (-e path('/usr/local/sbin/gou_rotate') && -e path('/dev/fb0')) ? 1 : 0;
}
sub policies {
	my @p = grep { -d } glob(path('/sys/devices/system/cpu/policy[0-9]*'));
	@p = grep { -d } glob(path('/sys/devices/system/cpu/cpu[0-9]*/cpufreq')) unless @p;
	return @p;
}
sub fb_bytes {
	my $stride = slurp('/sys/class/graphics/fb0/stride');
	my $vsize = slurp('/sys/class/graphics/fb0/virtual_size');
	return 0 unless $stride =~ /^\d+$/ && $vsize =~ /^\d+,\s*(\d+)$/;
	return $stride * $1;
}
sub black_fb {
	my $bytes = fb_bytes();
	return 0 unless $bytes > 0;
	return 1 if $DRY;
	open my $fh, '>', path('/dev/fb0') or return 0;
	my $zero = "\0" x 65536;
	my $left = $bytes;
	while ($left > 0) {
		my $n = $left < length($zero) ? $left : length($zero);
		my $wrote = syswrite($fh, $zero, $n);
		last unless defined $wrote && $wrote > 0;
		$left -= $wrote;
	}
	close $fh;
	return 1;
}

if (!is_gou()) {
	say_json({ ok => 0, error => 'not a controller' });
	exit 3;
}
if (!$DRY && $ACTION ne 'status' && $< != 0) {
	say_json({ ok => 0, error => 'root required' });
	exit 4;
}

if ($ACTION eq 'status') {
	say_json({ ok => 1, off => (-e path($MARKER) ? 1 : 0), state => $STATE });
	exit 0;
}

if ($ACTION eq 'off') {
	if ($DRY) {
		print "stop jawnos-kiosk\nstop gou-rotate\nstop gou-x\n";
		printf "black /dev/fb0 %d\n", fb_bytes();
		for my $dir (policies()) {
			print "governor powersave $dir\nmax_freq 1000000 $dir\n";
		}
		print "marker $MARKER\n";
		exit 0;
	}
	make_path($STATE);
	if (!-e path($MARKER)) {
		open my $cpu, '>', path($CPU_FILE) or die "cpu state: $!\n";
		for my $dir (policies()) {
			my $gov = slurp("$dir/scaling_governor");
			my $max = slurp("$dir/scaling_max_freq");
			print $cpu join("\t", $dir, $gov, $max), "\n";
		}
		close $cpu;
	}
	sys_run('systemctl', 'stop', 'jawnos-kiosk');
	sys_run('systemctl', 'stop', 'gou-rotate');
	sys_run('systemctl', 'stop', 'gou-x');
	black_fb();
	for my $dir (policies()) {
		spit("$dir/scaling_governor", "powersave\n");
		spit("$dir/scaling_max_freq", "1000000\n");
	}
	spit($MARKER, "off\n");
	say_json({ ok => 1, action => 'off', marker => $MARKER });
	exit 0;
}

if ($ACTION eq 'on') {
	if ($DRY) {
		print "start gou-x\nstart gou-rotate\nstart jawnos-kiosk\nrestore cpu\nunlink $MARKER\n";
		exit 0;
	}
	sys_run('systemctl', 'start', 'gou-x');
	for (1 .. 50) { last if -S '/tmp/.X11-unix/X0'; select(undef, undef, undef, 0.2); }
	sys_run('systemctl', 'start', 'gou-rotate');
	sys_run('systemctl', 'start', 'jawnos-kiosk');
	if (-e path($CPU_FILE)) {
		open my $cpu, '<', path($CPU_FILE);
		while (my $line = <$cpu>) {
			chomp $line;
			my ($dir, $gov, $max) = split /\t/, $line;
			spit("$dir/scaling_max_freq", "$max\n") if defined $max && length $max;
			spit("$dir/scaling_governor", "$gov\n") if defined $gov && length $gov;
		}
		close $cpu;
	}
	unlink path($MARKER);
	say_json({ ok => 1, action => 'on' });
	exit 0;
}

say_json({ ok => 0, error => 'unknown action' });
exit 2;
