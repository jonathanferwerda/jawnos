# tests-for: lib/JawnOS/Domain/Workers.pm lib/JawnOS/Domain/Render.pm perl/President.pl perl/President/prefork_autoscale.pl lib/JawnOS/Domain/Calendar.pm perl/hooks.pl lib/JawnOS/Controller/manager_configure4.pm lib/JawnOS/Routes/manager_configure4.pm templates/configure/system_setting_list.html.ep templates/configure/utility_controller.html.ep templates/configure/utility_pools.html.ep templates/configure/utility_chip.html.ep public/js/manager/configure/03_platform_misc.js lib/JawnOS/Domain/Loader.pm
# covers:    the worker pools behind Configure -> Sys -> Workers: the device
#           defaults, the min/max range read from the settings table (with
#           config.json and the old main_workers keys as fallbacks), the save
#           path that keeps min <= max, and the single call each server makes.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json encode_json);
use RepoSource;

my $root = repo_root();
require "$root/lib/JawnOS/Domain/Workers.pm";

# ---- defaults ---------------------------------------------------------------
is_deeply( [ subs::worker_pool_defaults('main', 'computer') ], [ 3, 5 ], 'a computer rests at three and may grow by two' );
is_deeply( [ subs::worker_pool_defaults('main', 'server') ],   [ 4, 6 ], 'a server rests at four and may grow by two' );
is_deeply( [ subs::worker_pool_defaults('main', 'mobile') ],   [ 2, 2 ], 'a phone rests at two and never grows' );
is_deeply( [ subs::worker_pool_defaults('main', 'controller') ], [ 2, 2 ], 'a controller rests at two and never grows' );
is_deeply( [ subs::worker_pool_defaults('watch', 'computer') ], [ 1, 3 ], 'the watch server is dynamic' );
is_deeply( [ subs::worker_pool_defaults('teletype', 'server') ], [ 3, 5 ], 'the teletype server is dynamic' );
is_deeply( [ subs::worker_pool_defaults('teletype_ws', 'server') ], [ 1, 1 ], 'the terminal socket channel stays at one' );
is_deeply( [ subs::worker_pool_defaults('websocket', 'computer') ], [ 1, 1 ], 'the WebSocket server stays at one' );
is_deeply( [ subs::worker_pool_defaults('alarm', 'computer') ], [ 1, 1 ], 'the alarm server stays at one' );
is_deeply( [ subs::worker_pool_defaults('locker', 'computer') ], [ 1, 1 ], 'the ticket server is one worker' );

# ---- clamping ---------------------------------------------------------------
is( subs::worker_pool_clamp(' 4 '), 4, 'a padded number is accepted' );
is( subs::worker_pool_clamp('0'),  1, 'zero is held at one, never a dead pool' );
is( subs::worker_pool_clamp('999'), 64, 'an absurd count is held at the ceiling' );
is( subs::worker_pool_clamp('abc'), undef, 'a word is not a worker count' );
is( subs::worker_pool_clamp(''),    undef, 'an empty count is not a worker count' );

# ---- limits: DB, then config.json, then the device default ------------------
my (%DB, @SETTER);
{
	no warnings 'redefine';
	*subs::setting_grabber = sub {
		my ($arg) = @_;
		return $DB{ $arg->{'setting'} };
	};
	*subs::setting_setter = sub {
		my ($arg) = @_;
		push @SETTER, $arg;
		$DB{ $arg->{'setting'} } = $arg->{'value'};
		return 1;
	};
}

%DB = ();
my $limits = subs::worker_pool_limits('main', device => 'computer', config => {});
is_deeply( [ $limits->{'min'}, $limits->{'max'} ], [ 3, 5 ], 'nothing stored keeps the computer default' );

%DB = ( worker_main_min => '6', worker_main_max => '8' );
$limits = subs::worker_pool_limits('main', device => 'computer', config => {});
is_deeply( [ $limits->{'min'}, $limits->{'max'} ], [ 6, 8 ], 'the settings table wins' );

%DB = ();
$limits = subs::worker_pool_limits('main', device => 'computer', config => { main_workers => 5, main_workers_max => 9 });
is_deeply( [ $limits->{'min'}, $limits->{'max'} ], [ 5, 9 ], 'the old config.json keys still set the main pool' );

$limits = subs::worker_pool_limits('main', device => 'computer', config => { main_workers => 0, main_workers_max => 0 });
is_deeply( [ $limits->{'min'}, $limits->{'max'} ], [ 3, 5 ], 'config.json zero keeps meaning the device default' );

%DB = ( worker_main_min => '7', worker_main_max => '4' );
$limits = subs::worker_pool_limits('main', device => 'computer', config => {});
is_deeply( [ $limits->{'min'}, $limits->{'max'} ], [ 7, 7 ], 'a stored range is repaired to min <= max' );

%DB = ( worker_locker_min => '3' );
$limits = subs::worker_pool_limits('locker', device => 'computer', config => {});
is_deeply( [ $limits->{'min'}, $limits->{'max'} ], [ 3, 3 ], 'a fixed pool follows its stored minimum' );

# a pool the map does not know is not invented
is( subs::worker_pool_limits('not_a_server', device => 'computer', config => {}), undef, 'an unknown pool has no range' );

# ---- saving a range ---------------------------------------------------------
%DB = (); @SETTER = ();
my $saved = subs::worker_pool_setting_save(pool => 'main', kind => 'min', value => '6', device => 'computer');
is( $saved->{'ok'}, 1, 'a minimum saves' );
is_deeply( [ $saved->{'min'}, $saved->{'max'} ], [ 6, 6 ], 'raising the minimum raises the ceiling with it' );
is( scalar @SETTER, 2, 'both sides are written so a restart sees the same range' );

%DB = ( worker_main_min => '3', worker_main_max => '5' ); @SETTER = ();
$saved = subs::worker_pool_setting_save(pool => 'main', kind => 'max', value => '2', device => 'computer');
is_deeply( [ $saved->{'min'}, $saved->{'max'} ], [ 2, 2 ], 'lowering the ceiling lowers the resting count with it' );

%DB = (); @SETTER = ();
$saved = subs::worker_pool_setting_save(pool => 'main', kind => 'min', value => 'x', device => 'computer');
is( $saved->{'ok'}, 0, 'a word is refused' );
is( scalar @SETTER, 0, 'and nothing is written' );

$saved = subs::worker_pool_setting_save(pool => 'nope', kind => 'min', value => '2', device => 'computer');
is( $saved->{'ok'}, 0, 'an unknown pool is refused' );

# ---- the shape the panel actually posts ------------------------------------
# Configure -> Sys hands the helper one hashref. Reading that hashref as a list
# leaves every named argument undefined, so the pool read as an unknown one and
# the route answered ok with nothing written - the panel showed the new count
# until the next repaint, then the old one came back.
%DB = (); @SETTER = ();
$saved = subs::worker_pool_setting_save({ pool => 'main', kind => 'min', value => '5', device => 'computer' });
is( $saved->{'ok'}, 1, 'the panel hashref form saves a range' );
is_deeply( [ $saved->{'min'}, $saved->{'max'} ], [ 5, 5 ], 'and reports the range it stored' );
is( $DB{'worker_main_min'}, 5, 'the minimum reached the settings table' );
is( $DB{'worker_main_max'}, 5, 'and so did the ceiling' );
is( $SETTER[-1]->{'device'}, 'computer', 'the write is keyed to this machine' );
is( scalar @SETTER, 2, 'a hashref save still writes both sides' );

# A write that dies is not a save: reporting ok here is what made a stored 5
# come back as 3 after a restart with no sign that anything was refused.
{
	no warnings 'redefine';
	my $ok_setter = \&subs::setting_setter;
	*subs::setting_setter = sub { die "the settings table is busy\n" };
	my $refused = subs::worker_pool_setting_save({ pool => 'main', kind => 'max', value => '8', device => 'computer' });
	is( $refused->{'ok'}, 0, 'a failed write is reported as not saved' );
	is( $refused->{'error'}, 'the range could not be stored', 'and names the failure' );
	*subs::setting_setter = $ok_setter;
}

# ---- the sources the panel and the launcher share ---------------------------
my $src = read_file("$root/perl/President.pl");
for my $pool (qw(main websocket locker alarm watch teletype teletype_ws)) {
	like( $src, qr/&worker_pool_options\('\Q$pool\E'\)/, "$pool takes its range from the worker-pool helper" );
}
like( $src, qr/\$ENV\{'JAWNOS_WORKER_POOL'\} = \$pool;/, 'run_server names the pool for its workers' );
like( $src, qr/\$ENV\{'JAWNOS_WORKER_AUTOSCALE'\} = \$max > \$min \? 1 : 0;/, 'only a wider range asks for busy markers' );
like( $src, qr/&prefork_autoscale\(\$prefork,/, 'the supervisor is still started through one call' );
like( $src, qr/pool => \$pool,/, 'and is told which pool it watches' );

my $autoscale = read_file("$root/perl/President/prefork_autoscale.pl");
like( $autoscale, qr/my \$dir = &subs::home\('~\/\.president\/busy\/' \. \$pool\);/, 'each pool has its own busy-marker folder' );
like( $autoscale, qr/\$0 = 'jawn autoscale ' \. \$pool;/, 'the supervisor names its pool in the process list' );

my $calendar = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
like( $calendar, qr/my \$dir = &home\('~\/\.president\/busy\/' \. \$pool\);/, 'the worker marker follows the same pool folder' );
like( $calendar, qr/return unless \$ENV\{'JAWNOS_WORKER_AUTOSCALE'\};/, 'a fixed pool writes no marker' );

my $hooks = read_file("$root/perl/hooks.pl");
like( $hooks, qr/if \(\$ENV\{'JAWNOS_WORKER_AUTOSCALE'\}/, 'the request hook asks only a dynamic pool' );

my $panel = read_file("$root/templates/configure/system_setting_list.html.ep");
like( $panel, qr/data-acc="sys-workers"/, 'Sys carries a Workers section' );
like( $panel, qr/class="sys_setting worker_setting"/, 'each pool has an editable count' );
like( $panel, qr/worker_mode/, 'and a mode cell the save response updates' );

my $ctl = read_file("$root/lib/JawnOS/Controller/manager_configure4.pm");
like( $ctl, qr/worker_pool_setting_save\(\{/, 'the sys_setting route hands the worker helper a hashref' );

my $js = read_file("$root/public/js/manager/configure/03_platform_misc.js");
like( $js, qr/\.worker_setting\[pool=/, 'the panel writes back both sides of the range' );
like( $js, qr/\.worker_mode\[pool=/, 'and refreshes the mode it shows' );
like( $js, qr/response\.ok === 0/, 'and puts a refused range back to the drawn value' );

# ---- the utility controller's device bar ----------------------------------
# The section used to be every machine's card in one long scroll. A bar now
# names the house, the name shown is the machine's own, and one card is on
# screen at a time.
my $utility_panel = read_file("$root/templates/configure/utility_controller.html.ep");
like( $utility_panel, qr/id="utility_device_bar"/, 'the utility controller opens with a device bar' );
like( $utility_panel, qr/overflow-x:scroll/, 'the bar scrolls sideways rather than wrapping' );
like( $utility_panel, qr/remote_machine_lister/, 'the bar lists the house roster' );
like( $utility_panel, qr/class="utility_device_chip".*html_text\(\$d->\{'name'\}\)/, 'a chip shows the machine name, not its signatorial' );
like( $utility_panel, qr/data-utility-device=/, 'each chip and card carries its machine key' );
like( $utility_panel, qr/id="utility_device_views"/, 'and the cards sit in one switchable stack' );
like( $js, qr/jawnos_utility_device/, 'the chosen device is remembered per browser' );
like( $js, qr/function utilityDeviceApply/, 'and re-applied after every repaint' );

# ---- a peer's card is the same editor as this machine's ---------------------
# The remote machine's card used to be a flat list of rows; it now includes the
# same pool editor, one include for each card, and the editor names the machine
# so the one save route writes that machine's row.
my $editors = () = $utility_panel =~ /include 'configure\/utility_pools'/g;
is( $editors, 2, 'both this machine and a peer include the pool editor' );
my $pool_part = read_file("$root/templates/configure/utility_pools.html.ep");
like( $pool_part, qr/class="utility_pool_editor" data-utility-device=/, 'the editor carries the machine it edits' );
like( $pool_part, qr/device => \$device/, 'and keys every tile on it' );
like( $pool_part, qr/utility_pool_add_button/, 'a peer can add a pool too' );
unlike( $pool_part, qr/utility_pool_static/, 'nothing is read-only about a peer\'s buckets now' );

like( $js, qr/device: editor\.attr\('data-utility-device'\)/, 'a pool save names the card it came from' );
like( $js, qr/'\.utility_pool_editor \.utility_chip'/, 'the drag handlers are scoped to one card\'s editor' );
like( $js, qr/'\.utility_pool_editor \.utility_pool_members'/, 'and so are the drop zones' );

# ---- the change is sent to that machine at once ----------------------------
# The blob is keyed by signatorial, and the sync pass carries it only when some
# other change pulls the settings table, so a pool set for a peer would sit in
# this machine's copy. The route relays it and the peer door applies it.
like( $ctl, qr{/manager/configure/utility_controller/peer}, 'the pool save relays to a peer door' );
like( $ctl, qr/&subs::remote_relay_request\(\$c,/, 'over the signed peer rail' );
like( $ctl, qr/change_time => \$change_time/, 'carrying the stamp it wrote' );
like( $ctl, qr/unless \(length \$relay_id/, 'and only the origin forwards it' );
like( $ctl, qr/peer_verify\(\$c, \$rm\) && &subs::peer_allows\(\$c, \$rm, 'trusted'\)/, 'the door verifies the sender as a trusted peer' );

# A switch and an interval take the same road: the panel route stores through
# utility_control_apply and relays the same peer door, which applies either shape.
like( $ctl, qr/my \$saved = \(defined \$target && length \$target\)\s*\n\s*\? &subs::utility_control_apply/, 'the save route stores a job change through the one applier' );
like( $ctl, qr/name => 'utility control relay'/, 'and relays a switch or an interval too' );
like( $ctl, qr/if \(length \$control \|\| length \$setting\) \{/, 'the door applies a single job change as well as a pool set' );

my $routes = read_file("$root/lib/JawnOS/Routes/manager_configure4.pm");
like( $routes, qr{\[19422, 'post', '/manager/configure/utility_controller/peer', 'action_19422'\]}, 'the peer door has its route row' );

my $gate_hooks = read_file("$root/perl/hooks.pl");
like( $gate_hooks, qr{\$path eq '/manager/configure/utility_controller/peer'}, 'and the gate steps aside so a peer with no session reaches it' );

# ---- storing one machine's pools -------------------------------------------
# utility_pools_apply is the one path the editor and the peer door share, so a
# pool set for a peer is written exactly as that machine's own page writes it.
require "$root/lib/JawnOS/Domain/Render.pm";

# ---- the headless relay heals out of the Fast pool -------------------------
# Its own interval is a minute; the old default cloned it into the Fast pool,
# whose fifteen minutes became its pace. Only the untouched shape is healed; a
# relay a person later moved to another pool, or gave a different pace, keeps it.
{
	my $stale = { remote_relay => { group => 'fast', interval => 60 } };
	is(subs::utility_relay_ungroup($stale), 1, 'the old default relay leaves the Fast pool');
	is($stale->{'remote_relay'}->{'group'}, '', 'and returns to the regular bin at its own minute');
	my $moved = { remote_relay => { group => 'fast_2', interval => 60 } };
	is(subs::utility_relay_ungroup($moved), 0, 'a relay moved to another pool is kept');
	is($moved->{'remote_relay'}->{'group'}, 'fast_2', 'with the pool it was given');
	my $paced = { remote_relay => { group => 'fast', interval => 120 } };
	is(subs::utility_relay_ungroup($paced), 0, 'a relay given a different pace is kept');
	is(subs::utility_relay_ungroup({}), 0, 'a row with no relay is left alone');
}

{
	no warnings 'redefine';
	my %STORED;
	*subs::setting_grabber = sub { return $STORED{'utility_controller'} };
	*subs::setting_setter  = sub { my ($arg) = @_; $STORED{'utility_controller'} = $arg->{'value'}; return 1 };
	*subs::rightNow        = sub { 1700000000000 };
	*subs::time_abbrev_translator = sub { my ($v) = @_; return ($v =~ /^(\d+)m$/i) ? $1 * 60000 : undef };
	$gb::timeouts = { backups => { toggle => 'on', interval => 600 }, sms => { toggle => 'off', interval => 600 } };
	$gb::batch_groups = { fast => { label => 'Fast', seconds => 900 } };

	my $peer = 'e397332d658f988006abc0dbc57e6f9b';
	my $saved = subs::utility_pools_apply({
		device => $peer,
		pools => [ { id => 'fast', label => 'Fast jobs', seconds => 600 }, { id => 'fast', label => 'dup' } ],
		members => { backups => 'fast', sms => 'gone' },
		change_time => 1700000000123,
	});
	is( $saved->{'ok'}, 1, 'a pool save is accepted' );
	is_deeply( [ map { $_->{'id'} } @{ $saved->{'pools'} } ], ['fast'], 'a repeated pool id is kept once' );
	my $blob = decode_json($STORED{'utility_controller'});
	is( $blob->{$peer}->{'__settings'}->{'last_change'}, 1700000000123, 'the sender\'s clock is the stamp every copy keeps' );
	is( $blob->{$peer}->{'backups'}->{'group'}, 'fast', 'a job keeps the pool it was dropped in' );
	is( $blob->{$peer}->{'sms'}->{'group'}, '', 'a pool that is gone returns its job to the regular list' );

	my $bad = subs::utility_pools_apply({ device => 'not-a-key', pools => [] });
	is( $bad->{'ok'}, 0, 'a device key the blob cannot hold is refused' );

	# ---- a switch and an interval take the same road ----------------------
	# The peer door and the panel's own route both store a single job change
	# through utility_control_apply, so a switch flipped on a peer's card is
	# written exactly as that machine's own page writes it.
	my $toggle = subs::utility_control_apply({ device => $peer, control => 'sms', setting => 'toggle', value => 'on', change_time => 1700000000200 });
	is( $toggle->{'ok'}, 1, 'a switch is accepted' );
	$blob = decode_json($STORED{'utility_controller'});
	is( $blob->{$peer}->{'sms'}->{'toggle'}, 'on', 'and stored as on' );
	is( $blob->{$peer}->{'__settings'}->{'last_change'}, 1700000000200, 'with the sender\'s clock' );

	my $pace = subs::utility_control_apply({ device => $peer, control => 'backups', setting => 'interval', value => '2m', change_time => 1700000000300 });
	is( $pace->{'ok'}, 1, 'a pace is accepted' );
	is( $pace->{'value'}, 120, '2m is stored as 120 seconds' );
	$blob = decode_json($STORED{'utility_controller'});
	is( $blob->{$peer}->{'backups'}->{'interval'}, 120, 'and lands on the row' );

	is( subs::utility_control_apply({ device => $peer, control => 'backups', setting => 'interval', value => 'soon' })->{'ok'}, 0,
		'a pace that does not parse is refused rather than stored as zero' );
	is( subs::utility_control_apply({ device => $peer, control => '__settings', setting => 'toggle', value => 'on' })->{'ok'}, 0,
		'the blob\'s own bookkeeping is not a job' );
	is( subs::utility_control_apply({ device => $peer, control => 'sms', setting => 'group', value => 'fast' })->{'ok'}, 0,
		'only a switch and a pace are accepted' );
}

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like( $loader, qr/'JawnOS::Domain::Workers' for qw\([^)]*\bworker_pool_limits\b/, 'the domain loader maps the worker helpers' );
like( $loader, qr/'JawnOS::Domain::Workers' for qw\([^)]*\bworker_pool_setting_save\b/, 'including the save path' );

# ---- a screen device still reaches the Manager page -------------------------
# The worker range must never leave the main server unstartable, and the
# landing route must not send a phone, tablet, laptop or table to the
# controller page. The route redirects only a controller, and only when it was
# not asked for the desk or an app (`open`/`desk`).
my $landing = read_file("$root/lib/JawnOS/Controller/manager_misc4.pm");
like( $landing, qr/return \$c->redirect_to\('\/manager\/controller'\)/, 'the controller page is the only landing redirect' );
like( $landing, qr/&subs::device_setter\(\) eq 'controller'/, 'and only a controller takes it' );
like( $landing, qr/!\$c->param\('open'\) && !\$c->param\('desk'\)/, 'a request for the desk or an app still gets the Manager page' );

%DB = ();
for my $device (qw(mobile tablet laptop table computer)) {
	my $main = subs::worker_pool_limits('main', device => $device, config => {});
	cmp_ok( $main->{'min'}, '>=', 1, "$device starts at least one main worker" );
	cmp_ok( $main->{'max'}, '>=', $main->{'min'}, "$device has a valid main range" );
	cmp_ok( $main->{'max'}, '<=', 64, "the $device main range is inside the clamp" );
}

done_testing();
