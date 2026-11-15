#!/usr/bin/perl
#
# gou_splash.pl - the mark on the Go Ultra's panel while the house starts.
#
#   perl scripts/gou_splash.pl [--watch|--once] [--dry-run]
#                              [--out PATH] [--status TEXT] [--percent N]
#                              [--display :0] [--width N] [--height N]
#
# The board's X root is 854x480 and gou-rotate presents it on the panel. The
# old unit painted desktop/icons/jawnos.png straight onto the root with
# `display -window root`; the icon is 358x526, so X tiled it three times across
# the screen. This script composes one full-screen frame instead: black, the
# mark centred with a soft halo of its own colour, a light-grey line saying
# what the boot is doing, and a progress bar under it.
#
# The face is composed with ImageMagick (the image already carries `convert`
# and `display`) and set as the X root. `display -window root` leaves its event
# loop running on some builds, so each frame is painted by a child that is
# reaped after it has had time to install the pixmap; the root keeps the frame
# after the child exits.
#
# --watch is what the unit runs: one frame at once, then one whenever the
# phase changes, until jawnos-kiosk is up. --once and --out are for a person or
# a test. --dry-run prints the plan and the ImageMagick argv and touches
# nothing.

use strict;
use warnings;

use Cwd ();
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Getopt::Long qw(GetOptions);
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);

my $TREE = Cwd::abs_path("$Bin/..") || "$Bin/..";
my $HOME = $ENV{'HOME'} || '';
my $TEXT = '#c9ced8';
my $TRACK = '#2a2e37';
my $FILL = '#b9c0cb';
my $BLACK = '#000000';
my $DEFAULT_WIDTH = 854;
my $DEFAULT_HEIGHT = 480;

my %opt = (
	display => ($ENV{'DISPLAY'} || ':0'),
	watch   => 1,
);
Getopt::Long::Configure('no_ignore_case');
Getopt::Long::GetOptions(
	'watch'    => \$opt{'watch'},
	'once'     => sub { $opt{'watch'} = 0 },
	'dry-run'  => \$opt{'dry_run'},
	'out=s'    => \$opt{'out'},
	'status=s' => \$opt{'status'},
	'percent=i'=> \$opt{'percent'},
	'display=s'=> \$opt{'display'},
	'width=i'  => \$opt{'width'},
	'height=i' => \$opt{'height'},
	'help|h'   => \$opt{'help'},
) or die "gou_splash: bad options\n";

if ($opt{'help'}) {
	print <<'USAGE';
gou_splash.pl [--watch|--once] [--dry-run] [--out PATH] [--status TEXT]
              [--percent N] [--display :0] [--width N] [--height N]
USAGE
	exit 0;
}

sub _which {
	my ($name) = @_;
	return $name if $name =~ m{^/} && -x $name;
	foreach my $dir ( split /:/, ($ENV{'PATH'} || '') ) {
		next unless length $dir;
		my $path = "$dir/$name";
		return $path if -x $path;
	}
	return '';
}

my $MAGICK = _which('magick') || _which('convert');
my $PAINTER = _which('display');
my @PAINTER_CMD = length $PAINTER ? ($PAINTER)
	: (length _which('magick') ? (_which('magick'), 'display') : ());
my $XSETROOT = _which('xsetroot');

sub _font {
	my @paths = (
		($HOME ? "$HOME/.local/share/fonts/DejaVuSans.ttf" : ()),
		'/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
		'/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf',
		'/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf',
		'/usr/share/fonts/TTF/DejaVuSans.ttf',
		'/usr/share/fonts/dejavu/DejaVuSans.ttf',
	);
	foreach my $path ( @paths ) {
		return $path if -f $path;
	}
	return '';
}

sub _logo {
	my @paths = (
		($HOME ? "$HOME/.local/share/jawnos/desktop/icons/jawnos.png" : ()),
		"$TREE/desktop/icons/jawnos.png",
		"$TREE/.shots/plymouth-logo.png",
	);
	foreach my $path ( @paths ) {
		return $path if -f $path;
	}
	return '';
}

# The X root the rotation presents. X is 854x480 landscape; a board that has
# not created the root yet answers nothing, so the default is that size.
sub _display_size {
	my ($dpy) = @_;
	foreach my $tool ( ['xdpyinfo'], ['xrandr'] ) {
		my $path = _which($tool->[0]);
		next unless length $path;
		my @args = $tool->[0] eq 'xrandr'
			? ($path, '--display', $dpy, '--query')
			: ($path, '-display', $dpy);
		my $out = '';
		if (open(my $fh, '-|', @args)) {
			local $/;
			$out = <$fh> // '';
			close $fh;
		}
		if ($tool->[0] eq 'xdpyinfo' && $out =~ /dimensions:\s+(\d+)x(\d+) pixels/) {
			return ($1, $2);
		}
		if ($tool->[0] eq 'xrandr' && $out =~ /current\s+(\d+)\s*x\s*(\d+)/) {
			return ($1, $2);
		}
	}
	return ($DEFAULT_WIDTH, $DEFAULT_HEIGHT);
}

sub _systemctl_active {
	my ($unit) = @_;
	my $path = _which('systemctl');
	return 'unknown' unless length $path;
	my $out = '';
	if (open(my $fh, '-|', $path, 'is-active', $unit)) {
		local $/;
		$out = <$fh> // '';
		close $fh;
	}
	$out =~ s/\s+$//;
	return length $out ? $out : 'unknown';
}

# Broad strokes, in the order the board reaches them. The first-boot pass is a
# oneshot that may still be running when X starts; its unit stays `active`
# afterwards, so `activating` is the only state that means the card is being
# looked at.
sub _phase {
	my $kiosk = _systemctl_active('jawnos-kiosk.service');
	return (100, 'Ready') if $kiosk eq 'active';
	my $first = _systemctl_active('jawnos-first-boot.service');
	return (30, 'The card needs a look') if $first eq 'failed';
	return (35, 'Checking the card') if $first eq 'activating';
	my $house = _systemctl_active('jawnos.service');
	return (55, 'Starting the house') unless $house eq 'active';
	return (85, 'Opening the panel');
}

sub _box {
	my ($w, $h) = @_;
	my $logo_h = int($h * 0.46);
	my $logo_w = int($logo_h * 0.68);
	my $lift = int($h * 0.115);
	my $border = int($h * 0.15);
	my $blur = int($h * 0.0625);
	my $point = int($h * 0.058);
	my $text = int($h * 0.246);
	my $bar_w = int($w * 0.585);
	my $bar_h = int($h * 0.021);
	$bar_h = 6 if $bar_h < 6;
	my $bar_x = int(($w - $bar_w) / 2);
	my $bar_y = int($h * 0.83);
	my $radius = int($bar_h / 2);
	return {
		logo_w => $logo_w, logo_h => $logo_h, lift => $lift,
		border => $border, blur => $blur, point => $point, text => $text,
		bar_w => $bar_w, bar_h => $bar_h, bar_x => $bar_x, bar_y => $bar_y,
		radius => $radius,
	};
}

# The ImageMagick argv. Two forms: the full face, and the same face without
# text so a board whose fontconfig has nothing still gets the mark and bar.
sub _convert_argv {
	my ($out, $w, $h, $status, $percent, $with_text) = @_;
	my $logo = _logo();
	return () unless length $MAGICK && length $logo;
	my $g = _box($w, $h);
	$percent = 0 unless defined $percent && $percent =~ /^-?\d+$/;
	$percent = 0 if $percent < 0;
	$percent = 100 if $percent > 100;
	my $fill_end = $g->{'bar_x'} + int($g->{'bar_w'} * $percent / 100);

	my @cmd = ($MAGICK, '-size', "${w}x${h}", "xc:$BLACK");
	# Halo: the mark blurred in its own colours, with a transparent border so
	# the blur has room to fade instead of ending on the resize box.
	push @cmd, '(', $logo,
		'-resize', "$g->{'logo_w'}x$g->{'logo_h'}",
		'-bordercolor', 'none', '-border', $g->{'border'},
		'-blur', '0x' . $g->{'blur'},
		'-channel', 'A', '-evaluate', 'multiply', '0.55', '+channel',
		')', '-geometry', '+0-' . $g->{'lift'}, '-gravity', 'center',
		'-compose', 'over', '-composite';
	push @cmd, '(', $logo, '-resize', "$g->{'logo_w'}x$g->{'logo_h'}", ')',
		'-geometry', '+0-' . $g->{'lift'}, '-gravity', 'center',
		'-compose', 'over', '-composite';
	if ($with_text && defined $status && length $status) {
		my $font = _font();
		push @cmd, '-fill', $TEXT, '-pointsize', $g->{'point'};
		push @cmd, '-font', $font if length $font;
		push @cmd, '-gravity', 'south', '-annotate', '+0+' . $g->{'text'}, $status;
	}
	push @cmd, '-fill', $TRACK, '-gravity', 'northwest',
		'-draw', sprintf('roundrectangle %d,%d %d,%d %d,%d',
			$g->{'bar_x'}, $g->{'bar_y'},
			$g->{'bar_x'} + $g->{'bar_w'}, $g->{'bar_y'} + $g->{'bar_h'},
			$g->{'radius'}, $g->{'radius'});
	if ($percent > 0) {
		push @cmd, '-fill', $FILL, '-draw', sprintf('roundrectangle %d,%d %d,%d %d,%d',
			$g->{'bar_x'}, $g->{'bar_y'},
			$fill_end, $g->{'bar_y'} + $g->{'bar_h'},
			$g->{'radius'}, $g->{'radius'});
	}
	push @cmd, $out;
	return @cmd;
}

sub _compose {
	my ($out, $w, $h, $status, $percent) = @_;
	return 0 unless length $MAGICK && length _logo();
	foreach my $with_text (1, 0) {
		my @cmd = _convert_argv($out, $w, $h, $status, $percent, $with_text);
		next unless @cmd;
		unlink $out if -e $out;
		return 1 if system(@cmd) == 0 && -s $out;
	}
	return 0;
}

my $ROOT_CLEARED = 0;

sub _paint {
	my ($image) = @_;
	return 0 unless @PAINTER_CMD && length $image && -s $image;
	# A root that was showing the kernel console goes black at once; the frame
	# follows when ImageMagick has it, so no old text is left behind. Only the
	# first frame clears the root: a later repaint must not flash black.
	if (!$ROOT_CLEARED && length $XSETROOT) {
		system($XSETROOT, '-solid', 'black');
		$ROOT_CLEARED = 1;
	}
	my $pid = fork();
	return 0 unless defined $pid;
	if ($pid == 0) {
		open(STDOUT, '>', '/dev/null');
		open(STDERR, '>', '/dev/null');
		exec(@PAINTER_CMD, '-window', 'root', $image) or POSIX::_exit(1);
	}
	my $deadline = time() + 2;
	my $exited = 0;
	while (time() < $deadline) {
		my $done = waitpid($pid, WNOHANG);
		if ($done == $pid) { $exited = 1; last }
		last if $done == -1;
		sleep(0.1);
	}
	unless ($exited) {
		kill('TERM', $pid);
		waitpid($pid, 0);
	}
	return 1;
}

if (!length $MAGICK) {
	print STDERR "gou_splash: ImageMagick is not on this board; leaving the root as it is\n";
	exit 0;
}
if (!length _logo()) {
	print STDERR "gou_splash: no JawnOS mark found; leaving the root as it is\n";
	exit 0;
}

my ($wide, $tall) = (0, 0);
if ($opt{'width'} && $opt{'height'}) {
	($wide, $tall) = ($opt{'width'}, $opt{'height'});
}
else {
	($wide, $tall) = _display_size($opt{'display'});
	$wide = $opt{'width'} if $opt{'width'};
	$tall = $opt{'height'} if $opt{'height'};
}

my $work = tempdir('gou-splash-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $frame = $opt{'out'} || "$work/frame.png";

if (!$opt{'watch'}) {
	my ($p, $s) = (defined $opt{'percent'} ? $opt{'percent'} : 15,
		defined $opt{'status'} ? $opt{'status'} : 'Starting the house');
	if ($opt{'dry_run'}) {
		print "size ${wide}x${tall}\n";
		print "phase $p $s\n";
		print join(' ', _convert_argv($frame, $wide, $tall, $s, $p, 1)), "\n";
		exit 0;
	}
	unless (_compose($frame, $wide, $tall, $s, $p)) {
		print STDERR "gou_splash: could not compose the frame\n";
		exit 1;
	}
	exit 0 if $opt{'out'};
	_paint($frame);
	exit 0;
}

# --watch: paint the first frame immediately, then only when the phase moves.
my ($percent, $status) = (15, 'Starting the house');
_compose($frame, $wide, $tall, $status, $percent);
_paint($frame);
my $last_percent = $percent;
my $last_status = $status;
while (1) {
	my ($next_percent, $next_status) = _phase();
	if ($next_percent != $last_percent || $next_status ne $last_status) {
		$last_percent = $next_percent;
		$last_status = $next_status;
		if (_compose($frame, $wide, $tall, $next_status, $next_percent)) {
			_paint($frame);
		}
	}
	last if $last_percent >= 100;
	sleep(1.5);
}
sleep(0.4);
exit 0;
