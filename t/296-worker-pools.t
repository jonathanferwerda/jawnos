# tests-for: lib/JawnOS/Domain/Workers.pm perl/President.pl perl/President/prefork_autoscale.pl lib/JawnOS/Domain/Calendar.pm perl/hooks.pl lib/JawnOS/Controller/manager_configure4.pm templates/configure/system_setting_list.html.ep public/js/manager/configure/03_platform_misc.js lib/JawnOS/Domain/Loader.pm
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
like( $ctl, qr/worker_pool_setting_save/, 'the sys_setting route sends a worker range through the domain helper' );

my $js = read_file("$root/public/js/manager/configure/03_platform_misc.js");
like( $js, qr/\.worker_setting\[pool=/, 'the panel writes back both sides of the range' );
like( $js, qr/\.worker_mode\[pool=/, 'and refreshes the mode it shows' );

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
