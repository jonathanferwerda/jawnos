# tests-for: scripts/jawnos_screen.pl lib/JawnOS/Domain/Misc.pm lib/JawnOS/Domain/Power.pm
# covers:    The handheld's dark idle: stop the painters, black the framebuffer,
#            switch the panel backlight off when the boot tree carries the node,
#            drop the CPU, and restore all of it from the wake chord.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use RepoSource;

my $root = repo_root();
my $helper = "$root/scripts/jawnos_screen.pl";
ok(-x $helper, 'the screen helper is executable');

# a fake backlight class device, so the dry run finds the node this box lacks
my $blroot = tempdir(CLEANUP => 1);
mkdir "$blroot/panel" or die "$blroot/panel: $!";
write_file("$blroot/panel/brightness", "200\n");
write_file("$blroot/panel/bl_power", "0\n");

my $off = `JAWNOS_SCREEN_FORCE=1 JAWNOS_SCREEN_BACKLIGHT=$blroot $^X $helper off --dry-run 2>&1`;
like($off, qr/^stop jawnos-kiosk$/m, 'off stops the kiosk');
like($off, qr/^stop gou-rotate$/m, 'off stops the rotating painter');
like($off, qr/^stop gou-x$/m, 'off stops X');
like($off, qr/^black \/dev\/fb0 \d+$/m, 'off blacks the framebuffer');
like($off, qr/^governor powersave /m, 'off drops the governor to powersave');
like($off, qr/^max_freq 1000000 /m, 'off pins 1.0 GHz');
like($off, qr/^backlight off$/m, 'off switches the panel backlight off');
like($off, qr/^marker /m, 'off leaves a marker for the wake chord');

my $on = `JAWNOS_SCREEN_FORCE=1 JAWNOS_SCREEN_BACKLIGHT=$blroot $^X $helper on --dry-run 2>&1`;
like($on, qr/^start gou-x$/m, 'on starts X');
like($on, qr/^start gou-rotate$/m, 'on starts the painter');
like($on, qr/^start jawnos-kiosk$/m, 'on starts the kiosk');
like($on, qr/^restore cpu$/m, 'on restores the CPU values');
like($on, qr/^restore backlight$/m, 'on puts the panel backlight back');
like($on, qr/^unlink /m, 'on removes the marker');

my $misc = read_file("$root/lib/JawnOS/Domain/Misc.pm");
like($misc, qr/scripts\/jawnos_screen\.pl/, 'screen_off uses the helper');
like($misc, qr/push \@actions, 'sleep' unless \$machine eq 'controller'/,
	'a controller is not offered a system suspend');
like($misc, qr/Cwd::abs_path/, 'the helper path is absolute for the sudoers rule');

my $power = read_file("$root/lib/JawnOS/Domain/Power.pm");
like($power, qr/Cwd::abs_path\(\$script\)/, 'the power helper path is absolute too');

done_testing();
