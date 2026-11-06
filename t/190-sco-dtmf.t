# tests-for: perl/sco/
# covers:    The helper's keypad reader: a DTMF press on the caller's downlink
#            is reported once, a held key is one digit, and speech is not one.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);

use RepoSource qw(repo_root);

my $repo = repo_root();
my $helper = "$repo/perl/sco/sco_helper";
my $dir = tempdir(CLEANUP => 1);

my $rate = 8000;
my $amp = 6000;

# A raw 8 kHz mono s16le call, the shape the eSCO downlink has: the caller's
# keypad arrives as the two tones the phone forwards, and between presses the
# line is digital silence.
my $pair = sub {
	my ($ms, $row, $col) = @_;
	my $n = int($rate * $ms / 1000);
	my $out = '';
	for my $i (0 .. $n - 1) {
		my $t = $i / $rate;
		my $v = $amp * sin(2 * 3.14159265358979 * $row * $t)
			+ $amp * sin(2 * 3.14159265358979 * $col * $t);
		$out .= pack('s<', int($v));
	}
	return $out;
};
my $tone = sub {
	my ($ms, $hz) = @_;
	my $n = int($rate * $ms / 1000);
	return join '', map { pack('s<', int($amp * sin(2 * 3.14159265358979 * $hz * $_ / $rate))) }
		0 .. $n - 1;
};
my $quiet = sub { "\0" x (16 * $_[0]) };   # 16 bytes per ms: 8 samples of s16le

# Drive the real helper the way the gateway does: a file is the caller, and
# the helper announces what it heard on its stdout. The file ends the call, so
# no command channel is needed.
my $events = sub {
	my ($name, $audio) = @_;
	my $raw = "$dir/$name.raw";
	open(my $w, '>', $raw) or die "$raw: $!";
	binmode $w;
	print {$w} $audio;
	close $w;
	open(my $ph, '-|', $helper, '--loopback', $raw, '--fast') or die "helper: $!";
	binmode $ph;
	local $/;
	my $said = <$ph> // '';
	close $ph;
	return $said;
};

SKIP: {
	skip 'the SCO helper is not built on this machine', 5 unless -x $helper;

	# A 60 ms press of 5, the interdigit pause, then 60 ms of 1. Both have to
	# be reported, in the order they were pressed, once each.
	my $menu = $events->('menu',
		$pair->(60, 770, 1336) . $quiet->(100) . $pair->(60, 697, 1209) . $quiet->(100));
	my @menu = ($menu =~ /"digit":"(.)"/g);
	is_deeply(\@menu, [ '5', '1' ],
		'a press of 5 then 1 is reported as two digits, in order, once each');

	# A key held down for 300 ms is still one press: without the release rule
	# every fresh window would report the same digit again.
	my $held = $events->('held', $pair->(300, 770, 1336) . $quiet->(100));
	my @held = ($held =~ /"digit":"(.)"/g);
	is_deeply(\@held, ['5'], 'a key held for 300 ms is one digit, not one per window');

	# The caller speaking is the everyday case a menu sits in. A single voice
	# tone carries no row/column pair, so it must never read as a press.
	my $speech = $events->('speech', $tone->(700, 440) . $quiet->(100));
	unlike($speech, qr/"event":"digit"/, '700 ms of a speech-like tone is not a digit');

	# One DTMF row on its own is a tone, not a keypad: the pair needs both its
	# halves at comparable strength.
	my $lone = $events->('lone', $tone->(200, 770) . $quiet->(100));
	unlike($lone, qr/"event":"digit"/, 'a lone 770 Hz tone is not a press');

	# A keypad's own oscillator is not exact. Half a window of pair energy is
	# the floor, so a pair half a percent off nominal (0.82 of the window,
	# measured) still reads, and the reader is not tuned to these exact numbers.
	my $off = $events->('detuned', $pair->(60, 770 * 1.005, 1336 * 1.005) . $quiet->(100));
	my @off = ($off =~ /"digit":"(.)"/g);
	is_deeply(\@off, ['5'], 'a keypad 0.5% off the nominal pair is still read');
}

done_testing();
