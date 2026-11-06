# tests-for: lib/JawnOS/Domain/Firmware.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Ble.pm lib/JawnOS/Domain/Ble2.pm lib/JawnOS/Manager/Part34.pm lib/JawnOS/Controller/manager_embedded.pm templates/embedded/body.html.ep public/js/manager/embedded/01_ota_nowme.js perl/gb/01_state_and_defaults.pl perl/President.pl scripts/fw_version.py scripts/stage_firmware.pl jp/alarmclock/alarmclock_01_globals_clock_ble.ino jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino jt/jt_01_globals_ble_house.ino jt/jt_03_setup.ino jt/jt_05_loop.ino jw/jw_01_globals.ino jw/jw_05_loop2.ino
# covers:    Every embedded device knows (and says) which build it is running,
#            and the house knows which build it would send. The version is
#            compiled in from VERSION, reported in state_request and
#            /device_query, and recorded beside the device. A staged image only
#            counts when a sidecar proves it is this version, the OTA route
#            refuses one that is not, and the Auto OTA checkbox lets the
#            firmware sweep push the difference.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use Cwd ();
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use JSON::PP ();
use RepoSource;

my $root = repo_root();
# Absolute, because the staged-image block chdirs into a temp tree.
unshift @INC, "$root/lib";
my $read = sub { scalar read_file("$root/$_[0]") };

# --- the version is compiled into every firmware build ----------------------
my $script = $read->('scripts/fw_version.py');
like($script, qr/JAWN_FW_VERSION/, 'the build script injects JAWN_FW_VERSION');
like($script, qr/VERSION/, 'from the checkout\'s VERSION');
like($script, qr/os\.path\.join\(\$?here, "VERSION"\)|"VERSION"/, 'walking up to find it');

foreach my $ini (qw(jp/alarmclock/platformio.ini jt/platformio.ini jw/platformio.ini)) {
	my $src = $read->($ini);
	like($src, qr/^\s*extra_scripts\s*=\s*pre:.*scripts\/fw_version\.py/m, "$ini runs it before compiling");
}

# --- and every sketch can fall back when built elsewhere -------------------
foreach my $globals (qw(
	jp/alarmclock/alarmclock_01_globals_clock_ble.ino
	jt/jt_01_globals_ble_house.ino
	jw/jw_01_globals.ino
)) {
	my $src = $read->($globals);
	like($src, qr/#ifndef\s+JAWN_FW_VERSION/, "$globals has a fallback");
	like($src, qr/#define\s+JAWN_FW_VERSION\s+"unknown"/, "$globals falls back to unknown");
}

# --- each device reports it on the paths the house already reads -----------
my %reports = (
	'jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino' => [ qr/req\["version"\]\s*=\s*JAWN_FW_VERSION/,
		qr/jonfig\["version"\]\s*=\s*JAWN_FW_VERSION|config\["version"\]\s*=\s*JAWN_FW_VERSION/ ],
	'jt/jt_05_loop.ino' => [ qr/req\["version"\]\s*=\s*JAWN_FW_VERSION/ ],
	'jt/jt_03_setup.ino' => [ qr/g\["version"\]\s*=\s*JAWN_FW_VERSION/ ],
	'jw/jw_05_loop2.ino' => [ qr/req\["version"\]\s*=\s*JAWN_FW_VERSION/ ],
);
foreach my $file (sort keys %reports) {
	my $src = $read->($file);
	my $n = 0;
	foreach my $want ( @{$reports{$file}} ) {
		like($src, $want, "$file reports the version ($n)");
		$n++;
	}
}

# --- the bridge keeps what the device said ---------------------------------
my $ble2 = $read->('lib/JawnOS/Domain/Ble2.pm');
like($ble2, qr/version\s*=>\s*\$msg->\{'version'\}/, 'the bridge passes the reported version to the sighting');

my $ble = $read->('lib/JawnOS/Domain/Ble.pm');
like($ble, qr/\$found->\{'version'\}\s*=\s*\$data->\{'version'\}/, 'the sighting stores the version');
like($ble, qr/\$found->\{'version_seen'\}/, 'and when it was seen');
like($ble, qr/version\s*=>\s*\(\$chip->\{'version'\}\s*\|\|/, 'a device row carries it');
like($ble2, qr/&subs::firmware_version_note\(\{/, 'the bridge also records it where the panel reads it');

# --- the manager records a version learned over HTTP -----------------------
my $part34 = $read->('lib/JawnOS/Manager/Part34.pm');
like($part34, qr/&subs::firmware_version_note\(/, 'a device query records the build it answered with');
like($part34, qr/my \$firmware = &subs::firmware_status\(\$edt, \$chip_id, \$embedded\)/, 'the panel is given the firmware status, with the live row');
like($part34, qr/firmware => \$firmware/, 'and renders with it');

# --- the staged image is only trusted with a sidecar -----------------------
my $firmware = $read->('lib/JawnOS/Domain/Firmware.pm');
like($firmware, qr/microcontroller\s*=>\s*\{\s*name\s*=>\s*'alarmclock'/, 'the pico has a firmware target');
like($firmware, qr/teletype\s*=>\s*\{\s*name\s*=>\s*'deck'/, 'so does the deck');
like($firmware, qr/watch\s*=>\s*\{\s*name\s*=>\s*'watch'/, 'and the watch');
like($firmware, qr/sub firmware_staged/, 'firmware_staged answers what would be sent');
like($firmware, qr/no sidecar/, 'an image with no sidecar is refused');
like($firmware, qr/does not match its sidecar/, 'an image whose bytes moved is refused');
like($firmware, qr/firmware sources changed since this image was staged/, 'an image whose sources moved is refused');
like($firmware, qr/\$row->\{'version'\}/, 'the panel falls back to the live device row');
like($part34, qr/&subs::firmware_status\(\$edt, \$chip_id, \$embedded\)/, 'and passes that row to the status');

my $loader = $read->('lib/JawnOS/Domain/Loader.pm');
like($loader, qr/JawnOS::Domain::Firmware' for qw\([^)]*\bfirmware_staged\b/, 'the loader maps the firmware helpers');
like($loader, qr/JawnOS::Domain::Firmware' for qw\([^)]*\bfirmware_auto_ota\b/, 'including the sweep');

# --- the OTA button cannot roll a board back ------------------------------
my $controller = $read->('lib/JawnOS/Controller/manager_embedded.pm');
my ($ota) = $controller =~ /(sub action_43561 \{.*?\n\})/s;
ok($ota, 'the pico OTA route is still one action');
like($ota, qr/&subs::firmware_staged\('microcontroller'\)/, 'the route asks what is staged');
like($ota, qr/unless \(\$staged->\{'current'\} \|\| \$c->param\('force'\)\)/, 'and refuses an image that is not current');
like($ota, qr/&subs::firmware_push\(/, 'sending goes through the one push path');
like($firmware, qr/sub firmware_push/, 'which lives with the firmware helpers');
like($firmware, qr/&ble_may_serve\(\$edt, \$chip_id\)/, 'and only the machine that may serve the device pushes');

# --- the panel shows it and lets the person opt in -------------------------
my $body = $read->('templates/embedded/body.html.ep');
like($body, qr/id="embedded_firmware_version"/, 'the panel shows the firmware line');
like($body, qr/id="embedded_firmware_device"/, 'with the build the device reports');
like($body, qr/id="embedded_firmware_latest"/, 'and the build this machine holds');
like($body, qr/setting="auto_ota"/, 'and an Auto OTA switch');
my $ota_at  = index($body, 'embedded_ota_uploader');
my $auto_at = index($body, 'setting="auto_ota"');
ok($ota_at >= 0 && $auto_at > $ota_at, 'the switch sits beside the OTA button');

my $js = $read->('public/js/manager/embedded/01_ota_nowme.js');
like($js, qr/\$\('#embedded_firmware_device'\)\.text\('v' \+ response\.query\.version\)/,
	'a Query refreshes the reported build');

# --- the sweep is on the utility schedule ---------------------------------
my $defaults = $read->('perl/gb/01_state_and_defaults.pl');
like($defaults, qr/'firmware_auto_ota' => \{ interval =>/, 'the sweep has a utility slot');
my $president = $read->('perl/President.pl');
like($president, qr/\$gb::timeouts->\{'firmware_auto_ota'\}->\{'subroutine'\}/, 'and a subroutine attached to it');

# --- the sweep's own rules -------------------------------------------------
like($firmware, qr/'auto_ota'.*?eq 'on'/s, 'it only touches a device that opted in');
like($firmware, qr/eq \$latest/, 'it compares the reported build with the staged one');
like($firmware, qr/fw_attempt_version/, 'and stamps an attempt so a failing board is not hammered');
like($firmware, qr/my \$latest = \$staged->\{'staged_version'\}/, 'the latest build is the one inside the image, not the house counter');

# --- runtime: firmware_staged tells current from stale --------------------
my $cwd = Cwd::getcwd();
my $tree = tempdir(CLEANUP => 1);
eval {
	chdir $tree or die "chdir: $!\n";
	make_path('jp/alarmclock/build/rp2040.rp2040.rpipico2w');
	write_file('VERSION', "7.7.7\n");
	my $img = 'jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin';
	write_file($img, "image bytes\n");

	require JawnOS::Domain::Firmware;
	my $staged = subs::firmware_target_for('microcontroller');
	my $target;
	is($staged->{'name'}, 'alarmclock', 'the microcontroller target is the pico build');
	is(subs::firmware_target_for('nonesuch'), undef, 'an unknown purpose has no target');

	my $s = subs::firmware_staged('microcontroller');
	is($s->{'current'}, 0, 'no sidecar is not current');
	like($s->{'reason'}, qr/no sidecar/, 'and says why');

	$target = subs::firmware_target_for('microcontroller');
	write_file("$img.json", JSON::PP->new->encode({
		version => '7.7.7',
		sha256 => sha256_hex(scalar read_file($img, binmode => ':raw')),
		size => -s $img,
		sources => subs::firmware_source_digest($target),
		staged_at => time,
	}));
	$s = subs::firmware_staged('microcontroller');
	is($s->{'current'}, 1, 'a matching sidecar is current');
	is($s->{'staged_version'}, '7.7.7', 'and names the build it holds');

	write_file('VERSION', "7.7.8\n");
	$s = subs::firmware_staged('microcontroller');
	is($s->{'current'}, 1, 'a house version bump alone leaves the image current');

	write_file('jp/alarmclock/alarmclock_extra.ino', "// one more line\n");
	$s = subs::firmware_staged('microcontroller');
	is($s->{'current'}, 0, 'a changed firmware source makes it stale');
	like($s->{'reason'}, qr/firmware sources changed/, 'and says the sources moved');
	unlink 'jp/alarmclock/alarmclock_extra.ino';
	write_file('VERSION', "7.7.7\n");

	write_file($img, "different bytes\n");
	$s = subs::firmware_staged('microcontroller');
	is($s->{'current'}, 0, 'bytes that moved are stale');
	like($s->{'reason'}, qr/does not match its sidecar/, 'and says the bytes moved');
};
my $error = $@;
chdir $cwd;
is($error, '', 'the staged-image checks ran without error') or diag($error);

# --- the stager and the manager must compute the same source digest --------
{
	my $tree = tempdir(CLEANUP => 1);
	make_path("$tree/jp/alarmclock/.pio/build/pico2w");
	make_path("$tree/scripts");
	write_file("$tree/VERSION", "5.0.0\n");
	write_file("$tree/jp/alarmclock/platformio.ini", "[env:pico2w]\n");
	write_file("$tree/jp/alarmclock/alarmclock_01.ino", "// firmware\n");
	write_file("$tree/scripts/fw_version.py", "# stamps the version\n");
	write_file("$tree/jp/alarmclock/.pio/build/pico2w/firmware.bin", "built\n");
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, "$root/scripts/stage_firmware.pl", '--root', $tree);
	close $in;
	local $/;
	my $out_text = <$out>;
	close $out;
	close $err;
	waitpid($pid, 0);
	my $ota = "$tree/jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin";
	ok(-f "$ota.json", 'the stager wrote a sidecar');
	chdir $tree or die "chdir: $!\n";
	my $seen = subs::firmware_staged('microcontroller');
	chdir $cwd;
	is($seen->{'current'}, 1, 'and the manager computes the same source digest')
		or diag($seen->{'reason'});
}

done_testing();
