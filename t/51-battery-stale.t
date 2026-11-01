use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

# The phone's battery card sometimes went blank ("no battery") and came back a
# little later. The cause is a timing stack, not a missing reading:
#
#   * device_call waits 2 seconds for the app's bridge, then declares a
#     transport failure;
#   * a transport failure memoises every call for 30 seconds, so the bridge is
#     not even asked again;
#   * battery_sample memoises its answer for 10 seconds and, on a miss, reports
#     source 'none' with no cache fallback.
#
# One slow reply therefore blanked the card for half a minute. This pins the
# three parts of the fix: a five second wait, a five second cooldown, and the
# last good reading served as stale instead of "none".

# device_call and battery_sample live in subroutines.pl (the domain loader in
# this tree does not carry them).
my $pph = read_file("$FindBin::Bin/../subroutines.pl");
my $say = $pph;

# 1. the cooldown is short and used consistently
my ($device_call) = $say =~ /^sub device_call \{(.*?)\n\}/ms;
ok(defined $device_call, 'device_call is found');
like($device_call // '', qr/my \$cooldown = 5;/, 'the bridge cooldown is five seconds');
my @cooldowns = ($device_call // '') =~ /\$device_bridge_memo = \{ until => \$now \+ \$cooldown \};/g;
is(scalar @cooldowns, 4, 'all four transport failures use the short cooldown');
unlike($device_call // '', qr/\$device_bridge_memo = \{ until => \$now \+ 30 \};/,
	'no transport failure keeps the old thirty second blackout');

# 2. the battery read waits long enough for a busy app
like($pph, qr/&subs::device_call\('battery\.status', \{\}, 5\)/,
	'the battery read waits five seconds');

# 3. a missed read serves the last good sample, marked stale, and only then
like($pph, qr/\(\$b->\{'source'\} \/\/ ''\) eq 'none'\s*\n\s*&& ref \$cached eq 'HASH'\s*\n\s*&& \(\$cached->\{'source'\} \/\/ ''\) ne 'none'/,
	'a miss falls back to a cached reading that was real');
like($pph, qr/\$held\{'stale'\} = 1;/, 'the held reading is marked stale');
like($pph, qr/\$held\{'stale_age'\} = int\(/, 'the held reading carries its age');
like($pph, qr/\$now - \(\$cached->\{'sampled'\} \|\| 0\) <= 600000/,
	'a reading older than ten minutes is not held');
like($pph, qr/return \$battery_sample_memo = \\%held;/,
	'the held reading is memoised like a fresh one');

# 4. the Monitor keeps the value on screen and says how old it is
my $monitor = read_file("$FindBin::Bin/../public/js/manager/monitor.js");
like($monitor, qr/if \(b\.stale\) \{/, 'the Monitor notices a stale sample');
like($monitor, qr/b\.stale_age/, 'the Monitor reads the sample age');
like($monitor, qr/jawnosT\('Last good reading'\)/, 'the stale hint is translatable');

done_testing();
