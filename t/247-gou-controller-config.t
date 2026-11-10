# tests-for: templates/controller/config.html.ep templates/controller/time.html.ep templates/controller/retroarch.html.ep lib/JawnOS/Domain/Retroarch.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm perl/help/topics_people.pl templates/apps/controller.html.ep
# covers:    The handheld's Configuration sublauncher: its five tiles and routes,
#            the time-zone setting the launcher clock reads, and the RetroArch
#            writer that edits the emulator's INI files without losing comments.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Mojo::Template;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use RepoSource;

my $root = repo_root();

# --- the four pages and their routes -----------------------------------------
my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc9.pm");
my %route = (
	44010 => ['get', '/manager/controller/config'],
	44011 => ['get', '/manager/controller/time'],
	44012 => ['post', '/manager/controller/time'],
	44013 => ['get', '/manager/controller/retroarch'],
	44014 => ['post', '/manager/controller/retroarch'],
);
for my $n (sort keys %route) {
	my ($method, $path) = @{ $route{$n} };
	like($routes, qr/\[\s*$n\s*,\s*'$method'\s*,\s*'\Q$path\E'\s*,\s*'action_$n'\s*\]/,
		"$method $path is registered as action_$n");
}

my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
for my $n (sort keys %route) {
	like($controller, qr/^sub action_$n\b/m, "action_$n exists");
}
like($controller, qr/template => 'controller\/config'/, 'the config action renders the sublauncher');
like($controller, qr/template => 'controller\/time'/, 'the time action renders the time page');
like($controller, qr/template => 'controller\/retroarch'/, 'the RetroArch action renders the tuning page');
like($controller, qr/clock_timezone/, 'the time page reads the house clock zone');
like($controller, qr/setting_setter\(\{ app => 'misc', setting => 'clock_timezone'/, 'the time page saves the zone as a house setting');

# --- the launcher's Configuration tile and clock -----------------------------
my $launcher = read_file("$root/templates/apps/controller.html.ep");
like($launcher, qr/href="\/manager\/controller\/config"/, 'Configuration leaves the launcher for the sublauncher');
unlike($launcher, qr/href="\/manager\?open=configure&amp;full=1"/, 'the old Configure app link is gone');
like($launcher, qr/id="controller_clock"/, 'the clock is on the bar');
like($launcher, qr/controller_manager_button[^>]*><%= &subs::ui\('Manager'\) %><\/a>\s*<span id="controller_clock"/,
	'the clock sits to the right of Manager');
like($launcher, qr/width:80%/, 'tile icons fill 80% of their tile');

# --- the sublauncher's five surfaces -----------------------------------------
my $config = read_file("$root/templates/controller/config.html.ep");
for my $pair (
	['network', 'Wi-Fi', '/manager?open=network&amp;full=1'],
	['power', 'Power', '/manager?open=power&amp;full=1'],
	['time', 'Time', '/manager/controller/time'],
	['sound', 'Sound', '/manager?open=sound&amp;full=1'],
	['retroarch', 'RetroArch', '/manager/controller/retroarch'],
) {
	like($config, qr|href="\Q$pair->[2]\E"|, "$pair->[1] opens $pair->[2]");
	like($config, qr/<%= &subs::ui\('\Q$pair->[1]\E'\) %>/, "$pair->[1] is named in the on-screen words");
}
like($config, qr|href="/manager/controller"|, 'the sublauncher has a way back to the Launcher');

# --- the time page ------------------------------------------------------------
my $time = read_file("$root/templates/controller/time.html.ep");
like($time, qr/id="controller_time_zone"/, 'the time page has a zone picker');
like($time, qr/id="controller_time_now"/, 'the time page shows the time');
like($time, qr|fetch\('/manager/controller/time'|, 'the page posts the chosen zone');
like($time, qr/Network time/, 'the page says whether network time is synchronized');
like($time, qr/Machine time zone/, 'the page names the machine zone separately');

# --- the RetroArch page -------------------------------------------------------
my $ra = read_file("$root/templates/controller/retroarch.html.ep");
like($ra, qr/data-ra-key=/, 'the page draws a control per setting');
like($ra, qr/data-ra-core=/, 'the page draws the per-core controls');
like($ra, qr/data-ra-preset=/, 'the page offers the presets');
like($ra, qr|fetch\('/manager/controller/retroarch'|, 'the page posts a change');
like($ra, qr/Audio and video/, 'the audio and video section is named');

# A template has none of the controller's imports. `encode_json` without this
# line is a 500 at render time, which is exactly how the page reached the panel
# as "this page cannot be displayed".
for my $page (qw(time retroarch)) {
	my $text = read_file("$root/templates/controller/$page.html.ep");
	like($text, qr/<%\s*use Mojo::JSON[^%]*\bencode_json\b/, "$page imports encode_json it uses");
}

# Render all three pages the way the app does (vars => 1 puts the stash keys in
# scope). This is the check that would have caught the missing import before the
# page reached the panel.
{
	no warnings 'redefine';
	*subs::ui = sub { $_[0] };
	*subs::icon_for = sub { $_[0] };
	my $mt = Mojo::Template->new({ vars => 1 });
	my $ra_out = eval {
		$mt->render_file("$root/templates/controller/retroarch.html.ep", {
			settings => {
				ok => 1, path => '/tmp/retroarch.cfg', values => { audio_latency => '128' },
				settings => [ { key => 'audio_latency', label => 'Audio latency', type => 'number', min => 0, max => 255, step => 1 } ],
				cores => [], presets => [],
			},
		});
	};
	ok(defined $ra_out && $ra_out =~ /data-ra-key=/, 'the RetroArch page renders');
	my $time_out = eval {
		$mt->render_file("$root/templates/controller/time.html.ep", {
			zone => 'America/New_York', zones => [ 'America/New_York', 'UTC' ], system_zone => 'UTC', synchronized => 1,
		});
	};
	ok(defined $time_out && $time_out =~ /controller_time_zone/, 'the Time page renders');
	my $config_out = eval { $mt->render_file("$root/templates/controller/config.html.ep", {}) };
	ok(defined $config_out && $config_out =~ /controller_config_grid/, 'the config sublauncher renders');
}

# --- the writer itself --------------------------------------------------------
use lib "$root/lib";
require "$root/lib/JawnOS/Domain/Retroarch.pm";

my $tmp = tempdir(CLEANUP => 1);
my $cfg = "$tmp/retroarch.cfg";
$ENV{'JAWNOS_RETROARCH_CONFIG'} = $cfg;
write_file($cfg, <<'CFG');
# the frontend's own file
audio_out_rate = "48000"
video_driver = "gl"
CFG

my ($read) = subs::retroarch_config_read($cfg);
is($read->{'audio_out_rate'}, '48000', 'the reader finds an existing value');
is($read->{'video_driver'}, 'gl', 'and a second one');

my $write = subs::retroarch_set('audio_latency', '128');
ok($write->{'ok'}, 'a known top-level setting is written');
my $after = read_file($cfg);
like($after, qr/^audio_latency = "128"$/m, 'the key lands as an INI line');
like($after, qr/^# the frontend's own file$/m, 'the comment is preserved');
like($after, qr/^audio_out_rate = "48000"$/m, 'the untouched key is preserved');
ok(-f "$cfg.jawnos-bak", 'the original is kept once as a backup');

my $bad = subs::retroarch_set('not_a_retroarch_key', 'x');
ok(!$bad->{'ok'}, 'an unknown key is refused');

my $psx = subs::retroarch_core_file('pcsx_rearmed');
ok(defined $psx && $psx =~ m{PCSX-ReARMed/PCSX-ReARMed\.opt$}, 'the PSX option file is found by core id');
make_path($tmp . '/config/PCSX-ReARMed');
write_file($psx, "pcsx_rearmed_frameskip = \"disabled\"\n");
my $core_write = subs::retroarch_set('pcsx_rearmed_frameskip', 'auto', 'pcsx_rearmed');
ok($core_write->{'ok'}, 'a known core setting is written');
like(read_file($psx), qr/^pcsx_rearmed_frameskip = "auto"$/m, 'the core option file carries the change');
my $wrong_core = subs::retroarch_set('pcsx_rearmed_frameskip', 'auto', 'mupen64plus_next');
ok(!$wrong_core->{'ok'}, 'a core setting is not accepted for another core');

my $mupen = subs::retroarch_core_file('mupen64plus_next');
ok(defined $mupen && $mupen =~ m{Mupen64Plus-Next/Mupen64Plus-Next\.opt$}, 'the N64 option file is found by core id');
make_path($tmp . '/config/Mupen64Plus-Next');
write_file($mupen, "mupen64plus-ThreadedRenderer = \"False\"\n");
my $hyphen = subs::retroarch_set('mupen64plus-ThreadedRenderer', 'True', 'mupen64plus_next');
ok($hyphen->{'ok'}, 'a hyphenated core key is writable');
like(read_file($mupen), qr/^mupen64plus-ThreadedRenderer = "True"$/m,
	'the hyphenated key lands as an INI line');
my ($mupen_read) = subs::retroarch_config_read($mupen);
is($mupen_read->{'mupen64plus-ThreadedRenderer'}, 'True', 'a hyphenated core key is readable');

my $preset = subs::retroarch_preset('audio_compatible');
ok($preset->{'ok'}, 'the audio-compatibility preset applies');
my $preset_cfg = read_file($cfg);
like($preset_cfg, qr/^audio_latency = "128"$/m, 'the preset raises the audio latency');
like($preset_cfg, qr/^audio_resampler = "cc"$/m, 'the preset picks the cheap resampler');
like(read_file($psx), qr/^pcsx_rearmed_spu_interpolation = "simple"$/m,
	'the preset also sets the PSX interpolation');

my $settings = subs::retroarch_settings();
ok($settings->{'ok'}, 'the page reading succeeds');
ok(ref $settings->{'settings'} eq 'ARRAY' && scalar @{ $settings->{'settings'} } >= 10,
	'it carries the top-level controls');
ok(ref $settings->{'cores'} eq 'ARRAY' && scalar @{ $settings->{'cores'} } == 2,
	'it carries both 3D cores');
ok(ref $settings->{'presets'} eq 'ARRAY' && scalar @{ $settings->{'presets'} } == 2,
	'it carries both presets');

# --- the Guide stays with the page --------------------------------------------
my $help = read_file("$root/perl/help/topics_people.pl");
like($help, qr/Configuration opens the handheld\\'s own sublauncher/, 'the Guide describes the sublauncher');
like($help, qr/templates\/controller\/retroarch\.html\.ep/, 'the Guide names the RetroArch page');

done_testing();
