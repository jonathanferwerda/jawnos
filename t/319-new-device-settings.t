# tests-for: lib/JawnOS/Domain/Render.pm lib/JawnOS/Domain/Embedded2.pm lib/JawnOS/Manager/Part17.pm
# covers:    a device that joins the house before its first settings sync writes
#            setting_initializer's born defaults (navigation 'none', the me
#            duration, a fresh colour). Those rows are newer than the values the
#            house already holds, so the merge used to treat them as the latest
#            word and reset every appointment app. The merge now keeps a chosen
#            value over a born default, lets a real value heal a local default
#            even when the default is newer, and setting_initializer adopts a
#            value the house already knows instead of seeding one.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use Mojo::SQLite;

# The merge and the initializer are driven on a throwaway SQLite file installed
# as the holder, so the live database is never touched.

my ($fh, $dbfile) = tempfile('jawnos-new-device-settings-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text, seed text)');
$db->query('create table cache (app text, context text, subcontext text, data text, '
	. 'device text, timestamp text, server_time text, uuid text, ost text)');
$db->query('create table remote_machines (uuid text, signatorial text, deletions text, server_time text, ost text)');
$db->query('create table sync_log (id integer primary key autoincrement, '
	. 'server_time text, signatorial text, tbl text, app text, uuid text, '
	. 'scope text, additional text, ost text)');
$db->query('create table notes (uuid text, app text, text text, timestamp text, '
	. 'server_time text, ost text)');
$db->query('create table appointments (uuid text, app text, timestamp text, '
	. 'server_time text, ost text)');
$db->query('create table continent (uuid text, app text, timestamp text, '
	. 'server_time text, ost text)');
my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $dbfile,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};
$subs::say_quiet = 1;
$subs::sync_table_cache = undef;

# The initializer, the default-value rule and the merge are the three pieces
# this test drives; load them before any local override below.
require JawnOS::Domain::Render;
require JawnOS::Domain::Embedded2;
require JawnOS::Manager::Part17;

# A fixed identity keeps the tombstone rows deterministic, and the merge's
# "kept ... over a peer default" line stays out of the live manager log.
local *subs::signatorial_designer = sub { 'test-signatorial' };
local *subs::log_writer = sub { };

my $device = &subs::device_setter();

# One peer table's row, driven through the same merge the sync uses.
sub merge_settings_row {
	my ($row) = @_;
	my $served = 0;
	my $next = sub { return $served++ ? undef : $row; };
	my $ctx = {
		configuration      => {},
		misc_settings      => {},
		device             => $device,
		deletions          => [],
		universal_settings => {},
		updateables        => [],
		sync_job           => undef,
		auuid              => 'test-auuid',
		colour             => '#000000',
	};
	return Manager::merge_table_rows($ctx, 'settings', $next, 1, 1, 1);
}

sub setting_rows {
	my ($app, $setting, $on) = @_;
	$on = $device unless defined $on;
	return &subs::db_query(
		'select * from settings where app = ? and setting = ? and device = ? order by cast(server_time as integer) desc',
		$app, $setting, $on
	)->hashes || [];
}

# ---------------------------------------------------------- born defaults
# The rule the merge applies: a default is "nothing anybody chose", so it can
# never replace a real value. The name-derived appointment type is part of it.
%subs::setting_defaults_memo = ();
ok(&subs::setting_is_default('navigation', 'walk', 'none'), 'navigation none is a born default');
ok(!&subs::setting_is_default('navigation', 'walk', '2m'), 'a chosen interval is not a default');
ok(&subs::setting_is_default('pos', 'grocery_place', 'place'),
	'a type the name itself names is a born default');
ok(!&subs::setting_is_default('pos', 'grocery_place', 'thing'),
	'another type on the same app is a choice');

# ---------------------------------------- a born default never wins here
&subs::setting_setter({ app => 'walk', setting => 'navigation', value => '2m',
	device => $device, server_time => '2000', sync => 1 });
&merge_settings_row({
	app => 'walk', setting => 'navigation', value => 'none', device => $device,
	server_time => '3000', timestamp => '3000', uuid => 'peer-default', seed => 'yes',
});
my $walk = setting_rows('walk', 'navigation');
is(scalar @{$walk}, 1, 'the peer default did not add a second row');
is($walk->[0]->{'value'}, '2m', "a newer born default did not replace walk's chosen interval");
is($walk->[0]->{'server_time'} + 0, 2000, 'and the chosen row kept its own stamp');

# The me-derived defaults are seeded too, and the me rows may not have synced,
# so the seed can be blank. A blank is a born default, not a choice.
&subs::setting_setter({ app => 'walk', setting => 'duration', value => '20m',
	device => $device, server_time => '2000', sync => 1 });
&merge_settings_row({
	app => 'walk', setting => 'duration', value => '', device => $device,
	server_time => '3000', timestamp => '3000', uuid => 'peer-blank', seed => 'yes',
});
is(setting_rows('walk', 'duration')->[0]->{'value'}, '20m',
	'a blank born duration did not replace the chosen one');

# ------------------------------------------------ a real value heals a default
&subs::setting_setter({ app => 'drive', setting => 'navigation', value => 'none',
	device => $device, server_time => '5000', seed => 'yes', sync => 1 });
&merge_settings_row({
	app => 'drive', setting => 'navigation', value => '2m', device => $device,
	server_time => '4000', timestamp => '4000', uuid => 'peer-real',
});
my $drive = setting_rows('drive', 'navigation');
is(scalar @{$drive}, 1, 'the healing row replaced the default rather than joining it');
is($drive->[0]->{'value'}, '2m', 'a real interval replaced a newer local default');
is($drive->[0]->{'server_time'} + 0, 4000, "and carries the peer's own stamp");

# ------------------------------------------- a real change still syncs
&subs::setting_setter({ app => 'run', setting => 'navigation', value => '2m',
	device => $device, server_time => '6000', sync => 1 });
&merge_settings_row({
	app => 'run', setting => 'navigation', value => '5m', device => $device,
	server_time => '7000', timestamp => '7000', uuid => 'peer-change',
});
is(setting_rows('run', 'navigation')->[0]->{'value'}, '5m',
	'a newer chosen value still lands over an older chosen value');
&merge_settings_row({
	app => 'run', setting => 'navigation', value => '1m', device => $device,
	server_time => '6500', timestamp => '6500', uuid => 'peer-stale',
});
is(setting_rows('run', 'navigation')->[0]->{'value'}, '5m',
	'an older chosen value does not walk the newer one back');

# ------------------------------------- a chosen default still propagates
# Turning driving off writes navigation 'none'. That value is the born default,
# but it is a choice, so the merge must not mistake it for a new device's seed.
# The panel marks the row 'no'.
&subs::setting_setter({ app => 'errand', setting => 'navigation', value => 'none',
	device => $device, server_time => '9000', source => 'panel', sync => 0 });
is(setting_rows('errand', 'navigation')->[0]->{'seed'}, 'no',
	'a panel write is marked as a choice');

# A machine holding a real interval takes that chosen none.
&subs::setting_setter({ app => 'errand2', setting => 'navigation', value => '2m',
	device => $device, server_time => '8000', sync => 1 });
&merge_settings_row({
	app => 'errand2', setting => 'navigation', value => 'none', device => $device,
	server_time => '9000', timestamp => '9000', uuid => 'peer-choice', seed => 'no',
});
is(setting_rows('errand2', 'navigation')->[0]->{'value'}, 'none',
	"a chosen 'none' lands on a machine holding a real interval");

# And the older real interval must not undo it: a real value only heals a seed.
&merge_settings_row({
	app => 'errand2', setting => 'navigation', value => '2m', device => $device,
	server_time => '8000', timestamp => '8000', uuid => 'peer-older-real',
});
is(setting_rows('errand2', 'navigation')->[0]->{'value'}, 'none',
	"an older real interval did not undo the chosen 'none'");

# ------------------------------- a new device adopts instead of seeding
# walk holds a real navigation interval on this device. A device in another
# class that opens walk has no row yet; the initializer must use the house value
# (and put it on its own row) rather than write navigation 'none'.
{
	local $subs::device = 'mobile';
	local *subs::device_setter = sub { 'mobile' };
	my $init = &subs::setting_initializer('walk', &subs::rightNow());
	is($init->{'navigation'}, '2m', 'the new device is handed the house navigation');
	my $mobile = setting_rows('walk', 'navigation', 'mobile');
	is(scalar @{$mobile}, 1, 'and the value is written on its own class');
	is($mobile->[0]->{'value'}, '2m', 'instead of the born navigation default');
	ok(!(grep { $_->{'value'} eq 'none' } @{$mobile}), 'no none row was left behind');
}

# A genuinely new app has no house value to adopt, so it keeps its born defaults.
{
	local $subs::device = 'mobile';
	local *subs::device_setter = sub { 'mobile' };
	my $fresh = &subs::setting_initializer('zz_new_device_probe', &subs::rightNow());
	is($fresh->{'navigation'}, 'none', 'a genuinely new app is still born navigation none');
	my $mobile = setting_rows('zz_new_device_probe', 'navigation', 'mobile');
	is(scalar @{$mobile}, 1, 'and that default is persisted');
	is($mobile->[0]->{'value'}, 'none', 'with the born value');
	is($mobile->[0]->{'seed'}, 'yes', 'and marked as a born default, not a choice');
}

# The clothesline's house rows pass the protected `__president` gate: the rail
# and the head are one line every machine reads. Every other __president row
# stays local.
&subs::setting_setter({ app => '__president', setting => 'clothesline_anticipatory', value => 'local',
	device => 'all', server_time => '1000', sync => 1 });
&merge_settings_row({
	app => '__president', setting => 'clothesline_anticipatory', value => '{"on":1}', device => 'all',
	server_time => '2000', timestamp => '2000', uuid => 'peer-clothes-head',
});
is(setting_rows('__president', 'clothesline_anticipatory', 'all')->[0]->{'value'}, '{"on":1}',
	'a house-wide clothesline head lands on a protected app');
&subs::setting_setter({ app => '__president', setting => 'clothesline', value => 'local-rail',
	device => 'all', server_time => '1000', sync => 1 });
&merge_settings_row({
	app => '__president', setting => 'clothesline', value => 'peer-rail', device => 'all',
	server_time => '2000', timestamp => '2000', uuid => 'peer-clothes-rail',
});
is(setting_rows('__president', 'clothesline', 'all')->[0]->{'value'}, 'peer-rail',
	'and so does the rail');
&subs::setting_setter({ app => '__president', setting => 'agent_registry', value => 'local',
	device => 'all', server_time => '1000', sync => 1 });
&merge_settings_row({
	app => '__president', setting => 'agent_registry', value => 'peer', device => 'all',
	server_time => '2000', timestamp => '2000', uuid => 'peer-agent',
});
is(setting_rows('__president', 'agent_registry', 'all')->[0]->{'value'}, 'local',
	'the other protected __president rows stay local');

done_testing();
