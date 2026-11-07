# tests-for: lib/JawnOS/Domain/Pay2.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Ble2.pm lib/JawnOS/Domain/Remote.pm lib/JawnOS/Controller/manager_misc13.pm lib/JawnOS/Routes/manager_misc13.pm perl/watch.pl jp/alarmclock/alarmclock_01_globals_clock_ble.ino jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino jp/alarmclock/alarmclock_04_jobs_clock_config_net.ino jw/jw_10_playback.ino jw/jw_05_loop2.ino
# covers:    A Vol+/- tap that reaches a Pico (the watch out of its homebase's
#            range) is carried to the manager over WiFi; the manager applies the
#            house volume locally, forwards it to every active peer or the named
#            one, and answers with a small result the Pico hands back to the
#            watch. The message id makes a bounded retry a no-op, and the Pico
#            never blocks its BLE/loop path on the HTTP call.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::SQLite;
use RepoSource;
use JawnOSTest;

# --- a stand-in peer agent ---------------------------------------------------
# Only the chain volume_relay uses: connect_timeout(...)->inactivity_timeout(...)
# then insecure(1)->post(url => form => {...})->result.
{
	package FakeUA;
	sub new {
		my ($class, %arg) = @_;
		return bless { posted => [], ok => exists $arg{'ok'} ? $arg{'ok'} : 1 }, $class;
	}
	sub connect_timeout    { return $_[0] }
	sub inactivity_timeout { return $_[0] }
	sub insecure           { return $_[0] }
	sub post {
		my ($self, $url, $how, $form) = @_;
		push @{$self->{'posted'}}, { url => $url, form => { %{$form || {}} } };
		return FakeTx->new($self->{'ok'});
	}
}
{
	package FakeTx;
	sub new { return bless { ok => $_[1] }, $_[0] }
	sub result { return FakeRes->new($_[0]->{'ok'}) }
}
{
	package FakeRes;
	sub new { return bless { ok => $_[1] }, $_[0] }
	sub is_success { return $_[0]->{'ok'} ? 1 : 0 }
}

# --- a throwaway cache table for the id claim --------------------------------
my ($fh, $dbfile) = tempfile('jawnos-volume-relay-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table cache (uuid text unique, context text, app text, '
	. 'server_time text, timestamp text, device text)');
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

# Load the real module before shadowing its primitives, so a stub is never the
# thing the loader compiles over.
subs::preload('volume_relay');

my @set;
my @lister_calls;
my @roster;
my @ua_args;
my $ua;
my $get_level = 40;
my $set_ok = 1;

{
	no warnings 'redefine';
	local *subs::clock_system_volume_get = sub { return $get_level };
	local *subs::clock_system_volume_set = sub { push @set, $_[0]; return $set_ok };
	local *subs::signatorial_designer = sub { return 'me-sig' };
	local *subs::remote_machine_lister = sub {
		my $args = shift || {};
		push @lister_calls, { %{$args} };
		my @rows = @roster;
		@rows = grep { ($_->{'connection'} || '') eq $args->{'connection'} } @rows if $args->{'connection'};
		@rows = grep { ($_->{'signatorial'} || '') eq $args->{'signatorial'} } @rows if $args->{'signatorial'};
		return [ @rows ];
	};
	local *subs::remote_useragent_maker = sub {
		my ($a) = @_;
		push @ua_args, { %{$a} };
		return { ua => $ua, manager => 'https://192.168.1.123:45545' };
	};
	# The real subprocessor forks; run the fan-out inline so the test can read
	# what each peer was told.
	local *subs::subprocessor = sub {
		my ($sub) = @_;
		$sub->() if $sub;
		return 1;
	};

	# --- an absolute level for this machine ---------------------------------
	@set = ();
	@lister_calls = ();
	@roster = ();
	my $r = subs::volume_relay({ id => 'abs-1', to => 'self', data => { volume => 55 } }, {});
	is($r->{'ok'}, 1, 'an absolute level on this machine is applied');
	is_deeply(\@set, [55], 'clock_system_volume_set received the level');
	is($r->{'volume'}, 55, 'the result carries the level the watch will show');
	is(scalar @lister_calls, 0, 'self never looks for peers');

	# --- a delta for every machine: local first, then every active peer ------
	@set = ();
	@roster = (
		{ signatorial => 'peer-a', hostname => 'Laptop', connection => 'active',
		  ip => '192.168.1.123', manager => 'https://192.168.1.123:45545' },
		{ signatorial => 'peer-b', hostname => 'Table', connection => 'active',
		  ip => '192.168.1.147', manager => 'https://192.168.1.147:45545' },
		{ signatorial => 'me-sig', hostname => 'Phone', connection => 'active',
		  ip => '192.168.1.200', manager => 'https://192.168.1.200:45545' },
	);
	$ua = FakeUA->new(ok => 1);
	@lister_calls = ();
	@ua_args = ();
	$get_level = 40;
	$r = subs::volume_relay({ id => 'all-1', to => 'all', data => { delta => 10 } }, {});
	ok(@ua_args && !grep({ !$_->{'no_probe'} } @ua_args),
		'a volume fan-out asks for the probe-free peer agent (one slow peer cannot hold the mixer)');
	is_deeply(\@set, [50], 'a delta is read against the level the room is on now');
	is($r->{'ok'}, 1, 'the local apply counts as success');
	is_deeply($r->{'forwarded'}, [ 'peer-a', 'peer-b' ], 'every active peer is named; this machine is not');
	is(scalar @{$ua->{'posted'}}, 2, 'both peers were dialled');
	is($ua->{'posted'}[0]->{'url'}, 'https://192.168.1.123:45545/manager/volume',
		'the peer rail is the manager volume route');
	is($ua->{'posted'}[0]->{'form'}{'volume'}, 50, 'the peer is told the resolved level');
	is($ua->{'posted'}[0]->{'form'}{'target'}, 'all', 'and the target');
	is($ua->{'posted'}[0]->{'form'}{'relayed'}, 'yes', 'a forwarded copy is marked relayed');
	is($ua->{'posted'}[0]->{'form'}{'signatorial'}, 'me-sig', 'and names the machine it came from');

	# --- a named machine: no local apply, one dial ---------------------------
	@set = ();
	$ua = FakeUA->new(ok => 1);
	$r = subs::volume_relay({ id => 'named-1', to => 'peer-b', data => { volume => 30 } }, {});
	is_deeply(\@set, [], 'a named peer does not move this machine');
	is_deeply($r->{'forwarded'}, ['peer-b'], 'only the named peer is dialled');
	is(scalar @{$ua->{'posted'}}, 1, 'one request');
	is($ua->{'posted'}[0]->{'url'}, 'https://192.168.1.123:45545/manager/volume',
		'and it is the volume route');
	is($r->{'ok'}, 1, 'a handed-over tap reports success');

	# --- a relayed copy is the end of the line -------------------------------
	@set = ();
	$ua = FakeUA->new(ok => 1);
	@lister_calls = ();
	$r = subs::volume_relay({ id => 'peer-1', to => 'all', data => { volume => 60 } }, { relayed => 1 });
	is_deeply(\@set, [60], 'the peer applies the tap locally');
	is(scalar @{$ua->{'posted'}}, 0, 'and does not fan it out again');
	is(scalar @lister_calls, 0, 'a relayed copy never asks the roster');

	# --- clamping -----------------------------------------------------------
	@set = ();
	$r = subs::volume_relay({ id => 'clamp-1', to => 'self', data => { volume => 250 } }, {});
	is_deeply(\@set, [100], 'an absolute over 100 is clamped');
	$get_level = 98;
	@set = ();
	$r = subs::volume_relay({ id => 'clamp-2', to => 'self', data => { delta => 20 } }, {});
	is_deeply(\@set, [100], 'a delta is clamped at the top');
	$get_level = 40;

	# --- the retry of one tap is a no-op ------------------------------------
	@set = ();
	$r = subs::volume_relay({ id => 'same-tap', to => 'self', data => { delta => 5 } }, {});
	is($r->{'ok'}, 1, 'the first copy applies');
	my $again = subs::volume_relay({ id => 'same-tap', to => 'self', data => { delta => 5 } }, {});
	is($again->{'duplicate'}, 1, 'the same id is reported as a duplicate');
	is_deeply(\@set, [45], 'the sink moved only once');

	# --- a machine with no mixer --------------------------------------------
	$get_level = undef;
	$set_ok = 0;
	@set = ();
	$r = subs::volume_relay({ id => 'nomixer-1', to => 'self', data => { delta => 5 } }, {});
	is($r->{'ok'}, 0, 'a delta with no mixer fails');
	is($r->{'error'}, 'no mixer', 'and says why');
	is_deeply(\@set, [], 'nothing is set');

	# A homebase with no mixer still forwards the delta to the machines that
	# have one: the phone is the watch's homebase, the laptop has the sink.
	@set = ();
	@roster = (
		{ signatorial => 'peer-a', hostname => 'Laptop', connection => 'active',
		  ip => '192.168.1.123', manager => 'https://192.168.1.123:45545' },
	);
	$ua = FakeUA->new(ok => 1);
	$get_level = undef;
	$set_ok = 0;
	$r = subs::volume_relay({ id => 'nomixer-all', to => 'all', data => { delta => 5 } }, {});
	is($r->{'ok'}, 1, 'a no-mixer homebase still forwards the tap');
	is_deeply($r->{'forwarded'}, ['peer-a'], 'to the machine with a sink');
	is_deeply(\@set, [], 'and does not touch a sink it does not have');
	is($ua->{'posted'}[0]->{'form'}{'delta'}, 5, 'the peer gets the delta, not a guessed level');
	ok(!exists $ua->{'posted'}[0]->{'form'}{'volume'}, 'and no absolute level');
	$get_level = 40;
	$set_ok = 1;

	# --- a message without a level ------------------------------------------
	$r = subs::volume_relay({ id => 'empty-1', to => 'self', data => {} }, {});
	is($r->{'ok'}, 0, 'a message with no delta and no level fails');
	is($r->{'error'}, 'no volume', 'and says why');
}

# --- the routes and the firmware wiring --------------------------------------
my $root = repo_root();
my $watch = read_file("$root/perl/watch.pl");
my $ble2 = read_file("$root/lib/JawnOS/Domain/Ble2.pm");
my $pay2 = read_file("$root/lib/JawnOS/Domain/Pay2.pm");
my $remote = read_file("$root/lib/JawnOS/Domain/Remote.pm");
my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc13.pm");
my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc13.pm");
my $pico_ble = read_file("$root/jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino");
my $pico_jobs = read_file("$root/jp/alarmclock/alarmclock_04_jobs_clock_config_net.ino");
my $pico_globals = read_file("$root/jp/alarmclock/alarmclock_01_globals_clock_ble.ino");
my $jw_play = read_file("$root/jw/jw_10_playback.ino");
my $jw_loop2 = read_file("$root/jw/jw_05_loop2.ino");

like($watch, qr/post '\/watch\/volume'/, 'watch.pl serves the device volume route');
like($watch, qr/post '\/watch\/ble_relay'/, 'watch.pl serves the relay envelope route');
like($watch, qr/post '\/watch\/volume' => sub\(\$c\) \{.*?embeddedAuthorizer.*?volume_relay/s,
	'the volume route authenticates the device and hands the message to volume_relay');
like($watch, qr/ble_relay_route\(\$relay, \{\}\)/, 'the relay route reuses the existing relay router');
like($routes, qr/\[45410, 'post', '\/manager\/volume', 'action_45410'\]/,
	'the peer volume route is registered');
like($controller, qr/sub action_45410 \{.*?peer_verify.*?volume_relay/s,
	'the peer route verifies the caller before applying the tap');
like($controller, qr/relayed => 1/, 'a peer copy is applied without another fan-out');
like($ble2, qr/eq 'volume'.*?volume_relay.*?volume_result/s,
	'the bridge path applies a volume tap and answers the device');
like($ble2, qr/vol_app.*?volume_relay.*?volume_result/s,
	'a Vol+/Vol- button flushed from the queue is routed as a volume tap');
like($pay2, qr/\$form\{'delta'\} = \$delta/,
	'a no-mixer homebase forwards the delta to a peer with a sink');
like($remote, qr/\$data->\{'no_probe'\}.*?peer_live_manager/s,
	'the peer agent can skip its live/secure probe for a timed fan-out');

like($pico_ble, qr/type == "volume"\).*?relay_out_forward\(msg, json, "\/watch\/volume"/s,
	'the Pico forwards a volume tap the manager can act on');
like($pico_ble, qr/to != "" && to != mine\).*?relay_out_forward\(msg, json, "\/watch\/ble_relay"/s,
	'the Pico forwards a message addressed to another chip');
like($pico_globals, qr/RELAY_OUT_MAX/, 'the Pico relay queue is bounded');
like($pico_globals, qr/relay_out_enqueue/, 'and every forward goes through it');
like($pico_jobs, qr/== "relay_post".*?https_post\(path, body, answer\)/s,
	'the blocking POST runs on core 1, never in the BLE handler');
like($pico_jobs, qr/tries >= 3/, 'the retry is bounded');
like($pico_jobs, qr/volume_result/, 'the manager result is handed back to the watch');
like($jw_play, qr/static bool house_volume_tap\(int delta, const char \*target\)/,
	'the watch can send a house volume tap over BLE');
like($jw_play, qr/tapped == "vol_\+".*?house_volume_tap\(house_delta, "all"\)/s,
	'a Vol+ face sends the house message instead of a local button press');
like($jw_loop2, qr/"volume_result"/, 'the watch reads the manager result back');

# A BLE button tap carries its own press id in the url; the bridge path must
# hand it to edt_button_presser so two homebases hearing one tap run it once.
like($ble2, qr/\(\$press_id\) = \$msg->\{'url'\} =~ \/\[\?&\]id=\(\[\^&\]\+\)\//,
	'the bridge reads the press id from the button tap\'s url');
like($ble2, qr/command_id => \$press_id/,
	'and hands it to the press as the command id');


done_testing();
