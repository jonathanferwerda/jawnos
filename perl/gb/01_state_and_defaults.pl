package gb;
use strict;
no warnings;

# $last_update / $last_updater are not read anywhere; they used to sweep the
# whole project tree at every process start for nothing. Fill them lazily from
# the cached version instead, so no boot pays for a filesystem walk.
our $last_update;
our $database_holder = {};
our $gallery_thumbnails = 75;
our $tmp_dir = &subs::home('~/.president');
our $dump_dir = $tmp_dir;
our $terminal_forker;
# 'device' is not a browser app: the websocket worker binds it so a manager or
# watch worker can hand an embedded output frame to the socket holder
# (/device/ws) through Websocket::send.
our $ws_apps = [ 'music', 'server', 'tab', 'device' ];
if (&subs::device_setter() ne 'mobile') {
	require JawnOS::Platform::Paths;
	$tmp_dir = JawnOS::Platform::Paths::tmp_dir(root => '/tmp');
}

our $planet_radius = 6372.8;
our $site_types = {

	'private' => { colour => 'yellow', icon => '/images/decipherable/home.png', name => 'private', rating => 1 },
	'public' => { colour => 'lightgreen', icon => '/images/make believe/crown.png', name => 'public', rating => 2 },
	'dangerous' => { colour => 'red', icon => '/images/make believe/explosion.png', name => 'dangerous', rating => 3 }
};

# A person's relationship is a configuration, like a place's visibility, not an
# app measure. Self and friend share the safest rating; a stranger is neutral; an
# enemy is the dangerous end that can lower a room's exposure.
our $relationship_types = {
	'self'     => { name => 'self',     rating => 1 },
	'friend'   => { name => 'friend',   rating => 1 },
	'stranger' => { name => 'stranger', rating => 2 },
	'enemy'    => { name => 'enemy',    rating => 3 },
};
our @relationship_order = qw/self friend stranger enemy/;

our $last_updater = sub {
	return $last_update ||= &subs::jawn_version();
};
our $forbidden = {
	tables => ['cache', 'magazine', 'devices', 'remote_machines', 'neighbour_link', 'websocket_messages', 'websockets', 'security', 'tickets', 'tunnels', 'backfills', 'sync_cursors', 'sync_log', 'sync_jobs', 'sync_snapshots', 'migrations', 'staged_fixes', 'staged_records', 'backups', 'journal', 'ledger_accounts' ]
};

our $capabilities = {
	mobile => {
		camera => [ 0, 1 ],
		printer => [ 'house' ]
	},
	computer => {
		camera => [ 'webcam' ],
		scan => [ 'adf', 'flatbed' ],
		printer => [ 'house' ]
	},
	server => {
		scan => [],
		printer => [ 'house' ]
	}
};


# The batch groups. Every utility names one; Configure -> Sys can set a group's
# pace once, which writes that interval to every job in it so they wake together
# and the device gets one longer nap instead of several short ones. Seconds.
# The order here is the order the default pools are listed in.
our @batch_order = qw/navigation fast slow daily/;
our $batch_groups = {
	'navigation' => { label => 'Navigation', seconds => 4 * 60, hint => 'GPS fixes (the house metronome)' },
	'fast'       => { label => 'Fast',       seconds => 15 * 60, hint => 'presence, health, mail, tunnels' },
	'slow'       => { label => 'Slow',       seconds => 60 * 60, hint => 'code sync, release, balances' },
	'daily'      => { label => 'Daily',      seconds => 24 * 60 * 60, hint => 'backups, housekeeping, expiry' },
};

our $timeouts = {
	'alarm_haircut' => { interval => 10 * 60, toggle => 'off', timeout => 30, group => 'slow' },
	'housekeeping' => { interval => 60 * 60, toggle => 'off', timeout => 30, group => 'daily' },
	'warehouse_expiry' => { interval => 6 * 60 * 60, toggle => 'on', timeout => 300, group => 'daily' },
	'budget' => { interval => 60 * 20, toggle => 'off', timeout => 180, group => 'fast' },
	'clothesline' => { interval => 5 * 60, toggle => 'off', timeout => 180, group => 'fast' },
	'tasks' => { interval => 5 * 60, toggle => 'off', timeout => 180, group => 'fast' },
	# On by default: a machine joins the house by syncing, and the LAN presence wake
	# only fires where a peer's broadcast can reach it. A headless or remote box (a
	# virtual machine, a LXC reached over the tailnet) never hears one, so with this
	# off it would only ever sync when someone started a pull by hand. Every machine
	# in a configured house runs it; the pass still starts at most one pull and is
	# held by the peer's marker, so the pace is the cheap handshake's, not a copy.
	'remote_machine_sync' => { interval => (2 * 60), interval_divider => 10, last_run => &subs::rightNow(), toggle => 'on', timeout => 1000, group => 'fast' },
	# A kick for a sync that has stalled: clear a pull marker nobody owns, reap
	# an orphaned pull job, drop an inactive hub and nudge the ordinary pass.
	# It is not another copy; the pass still stamps its own last_run.
	'sync_kick' => { interval => 5 * 60, toggle => 'on', timeout => 120, group => 'fast' },
	'navigation' => { interval => 4 * 60, interval_divider => 10, last_run => &subs::rightNow(), toggle => 'off', timeout => 90, group => 'navigation' },
	'sms' => { interval => 30 * 10, toggle => 'off', timeout => 90, group => 'fast' },
	'backups' => { interval => 1 * 60 * 60, toggle => 'on', timeout => 360, group => 'daily' },
	'headless_browser' => { interval => 10 * 60, toggle => 'off', timeout => 370, group => 'fast' },
	# The Weather app's automations need a condition even when nobody has the app
	# open. Its own interval (not a pool): the old page was hourly, and half an
	# hour is the shortest sensible ask of a public forecast service.
	'weather_observe' => { interval => 60 * 60, toggle => 'on', timeout => 240 },
	'telephone_check' => { interval => 1 * 60 * 5, toggle => 'off', timeout => 90, group => 'fast' },
	'email_sender' => { interval => 1 * 30, toggle => 'off', timeout => 90, group => 'fast' },
	'email_receiver' => { interval => 5 * 60, toggle => 'off', timeout => 390, group => 'fast' },
	'tunnels' => { interval => (2 * 60), interval_divider => 10, last_run => &subs::rightNow(), ip_addresses => [], network => {}, toggle => 'off', timeout => 390, group => 'fast' },
	'remote_relay' => { interval => 60, toggle => 'on', timeout => 120, group => 'fast' },
	'htop' => { interval => 40, toggle => 'off', timeout => 360, group => 'fast' },
	'git_sync' => { interval => 30 * 60, toggle => 'on', timeout => 180, group => 'slow' },
	# Agent worktrees are scratch once their work is on the trunk; nothing else
	# removes them. The sweep keeps anything unfinished (see worktree_gc.pl), so
	# it is safe on a machine where someone is mid-task.
	'worktree_gc' => { interval => 24 * 60 * 60, toggle => 'on', timeout => 120, group => 'daily' },
	'manager' => { interval => 15, last_run => &subs::rightNow(), toggle => 'off', timeout => 20, group => 'slow' },
	# The auto-OTA sweep: for every embedded device whose Auto OTA box is
	# ticked, compare the build it reports with the image this machine staged,
	# and push the difference. The per-device setting is the real switch; this
	# job being on just lets the house look.
	'firmware_auto_ota' => { interval => 10 * 60, toggle => 'on', timeout => 300, group => 'slow' }
};

$gb::alarm_running = 0;
$gb::budget_running = 0;
$gb::housekeeping_running = 0;
$gb::clothesline_running = 0;
$gb::alarm_haircut_running = 0;

our $whatevs = {};

our $chairs = {
	guest => { rank => 3 },
	resident => { rank => 2 },
	citizen => { rank => 1 },
	blacklisted => { rank => 0 },
};

our @device_types = qw/mobile computer server/;
our $settings;

our $piano = [
	{ '__specs' => { ratio => 1.05945454545 } },
	{ note => 'C', colour => 'white', freq => 261.64  },
	{ note => 'C#', colour => 'black', aka => 'Db', freq => 277.2 },
	{ note => 'D', colour => 'white', freq => 293.68 },
	{ note => 'D#', colour => 'black', aka => 'Eb', freq => 311.14 },
	{ note => 'E', colour => 'white', freq => 329.64 },
	{ note => 'F', colour => 'white', freq => 349.24 },
	{ note => 'F#', colour => 'black', aka => 'Gb', freq => 370 },
	{ note => 'G', colour => 'white', aka => 'G', freq => 392 },
	{ note => 'G#', colour => 'black', aka => 'Ab', freq => 415.308 },
	{ note => 'A', colour => 'white', freq => 440 },
	{ note => 'A#', colour => 'black', aka => 'Bb' },
	{ note => 'B', colour => 'white',  },
];

our @protected = qw/me misc __president music_folder_toggle __DEBRIEFING__ teletype budget ide config box_office studio synth cards terminal video gallery security/;

our @misc_settings = qw/homepage homepage_content manager start_menu gate configure store store_header soundroom_sidebar_container mail_sidebar_container ide_sidebar_container pseudonym pseudonym_home box_office notifications console keyboard calculator walkboy delorean controller remote_control /;

# selectable pseudonym icon sets; each maps to public/icons/sets/<key>/*.svg.
# Every generated set also ships a <key>_dark cut (build.js writes both), which
# icon_set() selects by itself while the active theme is dark.
# 'handdrawn' is special: it restores the original hand-drawn PNGs from public/icons/original/
our @icon_sets = qw/handdrawn windows mac gnome cartoon dark light outline neon pastel mono sunburst holographic sticker psychedelic kaleidoscope clown/;

# selectable cursor sets; each maps to public/cursors/sets/<key>/<role>.png.
# The empty value in a setting means the system cursors. Every set draws the
# same roles, so switching sets keeps an I-beam on text and a hand on a link.
our @cursor_sets = qw/bold white outline neon pastel mono contrast/;

# The sizes the pointer can wear. 32 is the base tile beside each SVG; the
# other cuts live in public/cursors/sets/<set>/<size>/ and are picked by the
# Misc slider. The values are the slider's stops, not every pixel between.
our @cursor_sizes = ( 16, 24, 32, 40, 48 );

# The roles a cursor set may name, and where each image's hotspot sits on the
# 32px tile. The server writes both into the CSS; the images only carry paint.
our @cursor_roles = qw/default pointer text vertical-text move grab grabbing not-allowed no-drop wait progress crosshair cell col-resize row-resize ns-resize ew-resize n-resize s-resize e-resize w-resize ne-resize sw-resize nw-resize se-resize nesw-resize nwse-resize/;
our %cursor_hotspots = (
	'default'      => '5 5',
	'pointer'      => '12 7',
	'text'         => '16 16',
	'vertical-text'=> '16 16',
	'move'         => '16 16',
	'grab'         => '16 16',
	'grabbing'     => '16 16',
	'not-allowed'  => '16 16',
	'no-drop'      => '16 16',
	'wait'         => '16 16',
	'progress'     => '16 16',
	'crosshair'    => '16 16',
	'cell'         => '16 16',
	'col-resize'   => '16 16',
	'row-resize'   => '16 16',
	'ns-resize'    => '16 16',
	'ew-resize'    => '16 16',
	'n-resize'     => '16 16',
	's-resize'     => '16 16',
	'e-resize'     => '16 16',
	'w-resize'     => '16 16',
	'ne-resize'    => '16 16',
	'sw-resize'    => '16 16',
	'nw-resize'    => '16 16',
	'se-resize'    => '16 16',
	'nesw-resize'  => '16 16',
	'nwse-resize'  => '16 16',
);
our @textures = qw/classic round soft sandglass glass paper fabric wood metal/;
