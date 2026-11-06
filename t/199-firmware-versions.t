# tests-for: scripts/fw_version.py scripts/fw_bump.pl scripts/stage_firmware.pl lib/JawnOS/Domain/Firmware.pm lib/JawnOS/Domain/Loader.pm
# covers:    Each board carries its own firmware version. The deck, the watch and
#            the Pico each keep a VERSION in their own project, the build stamps
#            that one, and the staged sidecar names it - so the panel can say one
#            board is behind without every board's number moving when the house
#            version does. A build that changes without a bump is reported,
#            because the device would otherwise report the new image under the
#            old number and read as up to date for ever.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use JSON::PP ();
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use RepoSource;

my $root   = repo_root();
my $stage  = "$root/scripts/stage_firmware.pl";
my $bump   = "$root/scripts/fw_bump.pl";

my %BOARD = (
	alarmclock => {
		project => 'jp/alarmclock',
		build   => 'jp/alarmclock/.pio/build/pico2w/firmware.bin',
		staged  => 'jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin',
	},
	deck => {
		project => 'jt',
		build   => 'jt/.pio/build/deck/firmware.bin',
		staged  => 'jt/build/deck/firmware.bin',
	},
	watch => {
		project => 'jw',
		build   => 'jw/.pio/build/watch/firmware.bin',
		staged  => 'jw/build/watch/firmware.bin',
	},
);

my $semver = qr/^\d+\.\d+\.\d+$/;

sub run {
	my ($script, @args) = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $script, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

# --- every board has a version of its own ------------------------------------
foreach my $board (sort keys %BOARD) {
	my $file = "$root/$BOARD{$board}->{'project'}/VERSION";
	ok(-f $file, "$board keeps its own VERSION");
	my $version = -f $file ? read_file($file) : '';
	$version =~ s/\s+//g;
	like($version, $semver, "...and it is a version ($version)");
}

# --- the build stamps the nearest one ----------------------------------------
my $stamp = read_file("$root/scripts/fw_version.py");
like($stamp, qr/def build_version\(project_dir\)/, 'the build asks for a version');
like($stamp, qr/here = os\.path\.abspath\(project_dir\)/, 'starting at the project directory');
like($stamp, qr/candidate = os\.path\.join\(here, "VERSION"\)/, 'looking for a VERSION at each level');
like($stamp, qr/here = os\.path\.dirname\(here\)/, 'and climbing to the checkout when the project has none');

# --- staging names each image by its own board's version ---------------------
my $tree = tempdir(CLEANUP => 1);
foreach my $board (sort keys %BOARD) {
	make_path("$tree/" . $BOARD{$board}->{'project'});
	make_path("$tree/" . ($BOARD{$board}->{'build'} =~ s{/[^/]+$}{}r));
	write_file("$tree/$BOARD{$board}->{'build'}", "$board bytes\n");
}
write_file("$tree/VERSION", "9.9.9\n");
write_file("$tree/jt/VERSION", "2.0.0\n");
write_file("$tree/jw/VERSION", "3.0.0\n");
write_file("$tree/jp/alarmclock/VERSION", "1.0.0\n");
my ($rc, $out, $err) = run($stage, '--root', $tree);
is($rc, 0, 'the tree stages');
like($out, qr/alarmclock .*v1\.0\.0/, 'the Pico is staged as its own version');
like($out, qr/deck .*v2\.0\.0/, 'the deck as its own');
like($out, qr/watch .*v3\.0\.0/, 'and the watch as its own');

foreach my $board (sort keys %BOARD) {
	my $side = "$tree/$BOARD{$board}->{'staged'}.json";
	ok(-f $side, "$board has a sidecar");
	my $meta = JSON::PP->new->decode(scalar read_file($side));
	is($meta->{'version'}, { alarmclock => '1.0.0', deck => '2.0.0', watch => '3.0.0' }->{$board},
		"...naming the $board build, not the house version");
}

# --- a board with no VERSION falls back to the checkout's --------------------
unlink "$tree/jt/VERSION";
run($stage, '--root', $tree);
my $deck_meta = JSON::PP->new->decode(scalar read_file("$tree/jt/build/deck/firmware.bin.json"));
is($deck_meta->{'version'}, '9.9.9', 'a project with no VERSION still stages, under the checkout version');

# --- a firmware change without a bump is reported ---------------------------
write_file("$tree/jt/VERSION", "2.0.0\n");
run($stage, '--root', $tree);
write_file("$tree/jt/jt_99_extra.ino", "// one more line of deck firmware\n");
write_file("$tree/jt/.pio/build/deck/firmware.bin", "deck rebuilt\n");
my (undef, $warn_out) = run($stage, '--root', $tree);
like($warn_out, qr/WARN\s+deck.*bump jt\/VERSION \(perl scripts\/fw_bump\.pl deck\)/,
	'a new build that kept its number is named');

# A bump in the same change silences it: the image really is a new version.
write_file("$tree/jt/VERSION", "2.0.1\n");
write_file("$tree/jt/.pio/build/deck/firmware.bin", "deck rebuilt, bumped\n");
my (undef, $quiet_out) = run($stage, '--root', $tree);
unlike($quiet_out, qr/WARN/, 'and a bumped build stages quietly');
is(JSON::PP->new->decode(scalar read_file("$tree/jt/build/deck/firmware.bin.json"))->{'version'},
	'2.0.1', 'with the new version in its sidecar');

# --- the stamping script alone is not a firmware change ---------------------
# scripts/fw_version.py is part of the source digest, so editing it moves every
# board's digest. No image byte changed, so no board's number has to.
make_path("$tree/scripts");
write_file("$tree/scripts/fw_version.py", "# stamp, first cut\n");
run($stage, '--root', $tree);
write_file("$tree/scripts/fw_version.py", "# stamp, second cut\n");
my (undef, $stamp_out) = run($stage, '--root', $tree);
unlike($stamp_out, qr/WARN/, 'a change to the stamping script alone needs no version bump');

# --- the bumper moves one board and no other --------------------------------
my ($lrc, $lout) = run($bump, '--root', $tree, '--list');
is($lrc, 0, '--list runs');
like($lout, qr/^deck\s+2\.0\.1$/m, 'and shows the deck');
like($lout, qr/^watch\s+3\.0\.0$/m, 'and the watch');

my ($brc, $bout) = run($bump, '--root', $tree, 'watch');
is($brc, 0, 'a bump runs');
like($bout, qr/watch 3\.0\.0 -> 3\.0\.1 \(jw\/VERSION\)/, 'and says what moved');
is(read_file("$tree/jw/VERSION"), "3.0.1\n", 'the named board moved');
is(read_file("$tree/jt/VERSION"), "2.0.1\n", 'the others did not');
is(read_file("$tree/VERSION"), "9.9.9\n", 'nor the house');

my ($urc, undef, $uerr) = run($bump, '--root', $tree, 'toaster');
isnt($urc, 0, 'an unknown board is refused');
like($uerr, qr/unknown board 'toaster'/, 'and named');

my ($nrc, undef, $nerr) = run($bump, '--root', $tree);
isnt($nrc, 0, 'no board is refused');
like($nerr, qr/usage: perl scripts\/fw_bump\.pl/, 'with the usage line');

# --- the manager names a board by its own version ---------------------------
my $firmware = read_file("$root/lib/JawnOS/Domain/Firmware.pm");
like($firmware, qr/sub firmware_target_version\(\$target\)/, 'the manager reads a board\'s own version');
like($firmware, qr/version => \(\$target \? firmware_target_version\(\$target\) : firmware_house_version\(\)\)/,
	'and falls back to the checkout\'s for one it does not know');
like(read_file("$root/lib/JawnOS/Domain/Loader.pm"), qr/\bfirmware_target_version\b/,
	'and the domain loader maps it');

{
	my $cwd = getcwd();
	my $probe = tempdir(CLEANUP => 1);
	write_file("$probe/VERSION", "9.9.9\n");
	make_path("$probe/jt");
	write_file("$probe/jt/VERSION", "4.5.6\n");
	require JawnOS::Domain::Loader;
	subs::preload('firmware_target_version');
	chdir $probe or die "cannot chdir to $probe: $!";
	is(eval { subs::firmware_target_version({ project => 'jt' }) }, '4.5.6',
		'the manager reads the board\'s own file');
	is(eval { subs::firmware_target_version({ project => 'jw' }) }, '9.9.9',
		'and the checkout\'s when the board has none');
	chdir $cwd or die "cannot chdir back to $cwd: $!";
}

done_testing();
