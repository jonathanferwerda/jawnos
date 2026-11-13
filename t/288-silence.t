# tests-for: lib/JawnOS/Domain/Silence.pm lib/JawnOS/Controller/manager_silence.pm lib/JawnOS/Routes/manager_silence.pm lib/JawnOS/Routes.pm lib/JawnOS/Domain/Phone.pm lib/JawnOS/Manager/Part12.pm lib/JawnOS/Controller/manager_phone.pm lib/JawnOS/Manager/Part05.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Say.pm lib/JawnOS/Domain/Clock.pm lib/JawnOS/Domain/Clock2.pm lib/JawnOS/Manager/Part02.pm lib/JawnOS/Manager/Part30.pm lib/JawnOS/Manager/Core1_tables_hooks.pm lib/JawnOS/Domain/Log.pm lib/JawnOS/Controller/manager_configure4.pm perl/hooks.pl perl/Music.pl perl/help/topics_configure.pl templates/configure/appointment_list.html.ep public/js/manager/silence.js public/js/manager/websocket/00_console_router.js perl/Reception.pl public/js/manager/manager/02_web_nfc.js perl/Alarm.pl
# covers:    Silence: the house-wide state, the local mixer snapshot (with the IVR
#            sinks kept audible), the appointment start/stop hook, the phone's
#            forced receptionist route, the audio gates, and the browser guard.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use Mojo::JSON qw(decode_json encode_json);

my $root = "$FindBin::Bin/..";
sub source { my $text = read_file("$root/$_[0]"); return defined $text ? $text : ''; }

{ package Websocket;
	sub send { return 1; }
	sub console_command { return { cmd => $_[0], args => [ @_[1 .. $#_] ] }; }
}

# A controller with no request is what a navigation plate and the alarm pass
# hand the writer. The relay must still be able to send from one.
{ package FakeCtl;
	sub new { return bless { req => undef }, shift }
	sub req { my $self = shift; $self->{'req'} = shift if @_; return $self->{'req'} }
	sub param { return undef }
}
{ package FakeApp;
	sub build_controller { return FakeCtl->new }
}

require "$root/lib/JawnOS/Domain/Silence.pm";

no warnings 'redefine';
our (%STORE, @MUTE, @SET, @CHANNEL, @RELAY);
our $MUTE_FAIL = 0;
our (@QUERY_SETTINGS, @QUERY_APPOINTMENTS, @NATIVE);
our $NOW = 1000;
our $DEVICE = 'computer';

{ package FakeRows;
  sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
  sub hashes { return $_[0]->{'rows'}; }
}

sub key_of {
	my ($s) = @_;
	return join '|', ($s->{'app'} // ''), ($s->{'setting'} // ''), ($s->{'device'} // '');
}
sub reset_all {
	%STORE = ();
	@MUTE = ();
	@SET = ();
	@CHANNEL = ();
	@RELAY = ();
	@QUERY_SETTINGS = ();
	@QUERY_APPOINTMENTS = ();
	@NATIVE = ();
	$DEVICE = 'computer';
	$MUTE_FAIL = 0;
	$subs::silence_tick_at = 0;
	$subs::silence_native_off_at = 0;
	%subs::silence_owners_seen = ();
	$NOW = 1000;
	$subs::SILENCE_LOCAL_FILE = $main::SCRATCH . '/silence_local.json';
	unlink $subs::SILENCE_LOCAL_FILE;
	$subs::SILENCE_RELEASED_FILE = $main::SCRATCH . '/silence_released.json';
	unlink $subs::SILENCE_RELEASED_FILE;
}
sub state_row { return $STORE{'__president|silence_state|all'} }
sub state_hash { my $raw = state_row(); return (defined $raw && length $raw) ? eval { decode_json($raw) } : undef }

my $scratch = tempdir(CLEANUP => 1);
$main::SCRATCH = $scratch;

*subs::rightNow = sub { $NOW += 10; return $NOW };
*subs::signatorial_designer = sub { return 'me' };
*subs::setting_grabber = sub { my ($s) = @_; return $STORE{ key_of($s) } };
*subs::setting_setter = sub {
	my ($s) = @_;
	$STORE{ key_of($s) } = $s->{'value'};
	return { ok => 1, %{$s} };
};
*subs::app = sub { return bless {}, 'FakeApp' };
*subs::subprocessor = sub { my ($body) = @_; eval { $body->() }; return 1 };
*subs::remote_relay_request = sub { my ($c, $extra) = @_; push @RELAY, { c => $c, extra => $extra }; return 1 };
*subs::relay_fresh = sub { return 1 };
*subs::random_string_creator = sub { return 'relayid' };
*subs::device_setter = sub { return $DEVICE };
*subs::device_call = sub {
	my ($method, $args) = @_;
	push @NATIVE, { method => $method, args => $args || {} };
	return { ok => 1 };
};
*subs::db_query = sub {
	my ($sql, @args) = @_;
	if (defined $sql && $sql =~ /from settings/) {
		return FakeRows->new(\@QUERY_SETTINGS);
	}
	if (defined $sql && $sql =~ /from appointments/) {
		# The reconciler asks only for sessions whose own timestamp is due;
		# honour that so a scheduled row is not counted before its time.
		if ($sql =~ /timestamp <= \?/) {
			my $now = $args[-1];
			return FakeRows->new([ grep {
				ref $_ eq 'HASH' && (!defined $_->{'timestamp'} || $_->{'timestamp'} <= $now)
			} @QUERY_APPOINTMENTS ]);
		}
		return FakeRows->new(\@QUERY_APPOINTMENTS);
	}
	return FakeRows->new([]);
};
*subs::sound_android_streams = sub { return [] };
*subs::sound_devices = sub {
	return {
		ok => 1,
		backend => 'pactl',
		outputs => [
			{ id => 'alsa_output', name => 'Speaker', volume => 55, muted => 0 },
			{ id => 'jawn_prompt', name => 'Prompt', volume => 100, muted => 0 },
			{ id => 'bluez_output.AA', name => 'Headset', volume => 80, muted => 0 },
		],
	};
};
*subs::sound_mute = sub { my ($kind, $id, $mute) = @_; push @MUTE, "$kind|$id|$mute"; return { ok => ($MUTE_FAIL ? 0 : 1) } };
*subs::sound_set = sub { my ($kind, $id, $volume) = @_; push @SET, "$kind|$id|$volume"; return { ok => 1 } };
*subs::sound_channels = sub {
	return {
		music => { volume => 70, muted => 0 },
		phone => { volume => 100, muted => 0 },
		alarm => { volume => 100, muted => 0 },
	};
};
*subs::sound_channel_set = sub { my ($name, $volume, $muted) = @_; push @CHANNEL, "$name|" . (defined $volume ? $volume : '') . '|' . (defined $muted ? $muted : ''); return { ok => 1 } };

# ============================================================================
# the state and the appointment hook
# ============================================================================
reset_all();
is(subs::silence_active(), 0, 'a house with no row is not silent');
$STORE{'mirror|silence|all'} = 'checked';
is(subs::silence_app_setting('mirror'), 'checked', 'the app box is read from the house row');
ok(subs::silence_app_setting_on('mirror'), 'checked turns the box on');
$STORE{'mirror|silence|all'} = 'unchecked';
ok(!subs::silence_app_setting_on('mirror'), 'unchecked leaves it off');

reset_all();
$STORE{'mirror|silence|all'} = 'checked';
subs::silence_appointment_write('mirror', 'start', 'u1');
my $state = state_hash();
is($state->{active}, 1, 'a start engages silence');
is_deeply($state->{owners}, ['u1'], 'the start row is the owner');
is($state->{apps}->{u1}, 'mirror', 'the owner remembers its app');
is(scalar(grep { /\|1$/ } @MUTE), 1, 'the one speaker that is not the call link is muted');
is_deeply([ grep { /alsa_output/ } @MUTE ], ['output|alsa_output|1'], 'the ordinary sink is muted');
ok(!grep(/jawn_prompt/, @MUTE), 'the IVR prompt sink is left audible');
ok(!grep(/bluez/, @MUTE), 'the Bluetooth call sink is left audible');
is(scalar(grep { /^music\|/ } @CHANNEL), 1, 'the music channel is muted');
ok(-e $subs::SILENCE_LOCAL_FILE, 'the local snapshot is written');

my $mutes_after_first = scalar @MUTE;
subs::silence_appointment_write('mirror', 'start', 'u2');
is(scalar @MUTE, $mutes_after_first, 'a second owner does not mute the mixer twice');
is_deeply(state_hash()->{owners}, [ 'u1', 'u2' ], 'the second owner joins the state');

subs::silence_appointment_write('mirror', 'stop', 'u1');
is(state_hash()->{active}, 1, 'one owner leaving keeps silence on');
is_deeply(state_hash()->{owners}, ['u2'], 'and leaves the other owner');

subs::silence_appointment_write('mirror', 'stop', 'u2');
$state = state_hash();
is($state->{active}, 0, 'the last owner leaving ends silence');
is_deeply($state->{owners}, [], 'and clears the owners');
is_deeply([ grep { /alsa_output/ } @SET ], ['output|alsa_output|55'], 'the saved volume is put back');
is((grep { /^alarm\|/ } @CHANNEL)[-1], 'alarm|100|0', 'the alarm channel is restored');
ok(!-e $subs::SILENCE_LOCAL_FILE, 'the snapshot is cleared');
my ($stop_msg) = grep { ($_->{'extra'}->{'url'} // '') eq '/manager/silence/peer'
	&& !$_->{'extra'}->{'params'}->{'active'} } @RELAY;
my $stop_state = $stop_msg ? decode_json($stop_msg->{'extra'}->{'params'}->{'state'}) : {};
is_deeply($stop_state->{'released'}, ['u2'],
	'the stop names the owner it released, for a peer whose row lags');

# A peer that received that stop must not read its own lagging row as a fresh
# start: the note suppresses the owner until the row closes or the window ends.
reset_all();
@QUERY_SETTINGS = ({ app => 'mirror' });
@QUERY_APPOINTMENTS = ({ uuid => 'u-lag', app => 'mirror', timestamp => subs::rightNow() - 1000 });
subs::silence_release_note(['u-lag']);
$subs::silence_tick_at = 0;
subs::silence_tick();
is(state_hash(), undef, 'a lagging row a verified peer stopped does not re-engage silence');
my $notes = subs::silence_released_read();
$notes->{'u-lag'} = subs::rightNow() - 1;
subs::silence_released_write($notes);
$subs::silence_tick_at = 0;
subs::silence_tick();
is_deeply(state_hash()->{owners}, ['u-lag'],
	'and the row engages again once the note has expired');
reset_all();
subs::silence_release_note(['u-lag']);
subs::silence_release_clear(['u-lag']);
is(scalar(keys %{ subs::silence_released_read() }), 0,
	'a start from the peer lifts the suppression (a navigation reopen)');

# A mixer that refuses the restore must not lose the record of what to put
# back: the snapshot stays and the next alarm pass tries again.
reset_all();
subs::silence_local_write({ outputs => [ { id => 'alsa_output', volume => 55, muted => 0 } ], channels => {}, streams => [] });
$MUTE_FAIL = 1;
is(subs::silence_local_apply(0), 0, 'a refused restore reports failure');
ok(-e $subs::SILENCE_LOCAL_FILE, 'and keeps the snapshot for the next pass');
$MUTE_FAIL = 0;
is(subs::silence_local_apply(0), 1, 'the next pass restores it');
ok(!-e $subs::SILENCE_LOCAL_FILE, 'and clears the snapshot');

# A stop releases even when the box was unticked before the stop arrived.
reset_all();
$STORE{'mirror|silence|all'} = 'checked';
subs::silence_appointment_write('mirror', 'start', 'u9');
delete $STORE{'mirror|silence|all'};
subs::silence_appointment_write('mirror', 'stop', 'u9');
is(state_hash()->{active}, 0, 'a stop releases without the box still ticked');

# A start with the box unticked does nothing.
reset_all();
subs::silence_appointment_write('mirror', 'start', 'u10');
is(state_hash(), undef, 'an unticked appointment never writes a silence row');
is(scalar @MUTE, 0, 'and never touches the mixer');

# A start saved for later is not running yet: an appointment scheduled a few
# minutes ahead must not quiet the house the moment it is written.
reset_all();
$STORE{'mirror|silence|all'} = 'checked';
subs::silence_appointment_write('mirror', 'start', 'u11', undef, subs::rightNow() + 300000);
is(state_hash(), undef, 'a start written for later does not engage silence early');
is(scalar @MUTE, 0, 'and leaves the mixer alone');
subs::silence_appointment_write('mirror', 'start', 'u12', undef, subs::rightNow());
is(state_hash()->{active}, 1, 'a start due now engages silence');

# ============================================================================
# the alarm pass: start and stop without a Manager page
# ============================================================================
reset_all();
@QUERY_SETTINGS = ({ app => 'mirror' });
@QUERY_APPOINTMENTS = ({ uuid => 'u-open', app => 'mirror' });
$DEVICE = 'mobile';
$subs::silence_tick_at = 0;
subs::silence_tick();
my $tick_state = state_hash();
is($tick_state->{active}, 1, 'the alarm pass starts silence');
is_deeply($tick_state->{owners}, ['u-open'], 'and owns the open silent session');
my $on_pushed = grep { $_->{'method'} eq 'silence.set' && $_->{'args'}->{'on'} == 1 } @NATIVE;
ok($on_pushed, 'and tells the phone app directly');
my $start_relay = grep { ($_->{'extra'}->{'url'} // '') eq '/manager/silence/peer'
	&& $_->{'extra'}->{'params'}->{'active'} } @RELAY;
ok($start_relay, 'and hands the start to the peers with no request in hand');
@QUERY_APPOINTMENTS = ({ uuid => 'u2-open', app => 'mirror' });
$subs::silence_tick_at = 0;
subs::silence_tick();
is_deeply(state_hash()->{owners}, ['u2-open'], 'the owners follow the open session');

# The same holds for a row written ahead of its time: it owns the house only
# once its timestamp is due, which is what makes a scheduled appointment work.
reset_all();
@QUERY_SETTINGS = ({ app => 'mirror' });
$DEVICE = 'mobile';
@QUERY_APPOINTMENTS = ({ uuid => 'u-later', app => 'mirror', timestamp => subs::rightNow() + 300000 });
subs::silence_tick();
is(state_hash(), undef, 'a start in the future owns nothing yet');
@QUERY_APPOINTMENTS = ({ uuid => 'u-later', app => 'mirror', timestamp => subs::rightNow() - 1000 });
$subs::silence_tick_at = 0;
subs::silence_tick();
is_deeply(state_hash()->{owners}, ['u-later'], 'the same row starts owning silence when it is due');

# A machine that watched that session run stops it at once when its own row
# closes, and relays the stop - no sync window to wait out.
reset_all();
@QUERY_SETTINGS = ({ app => 'mirror' });
$DEVICE = 'mobile';
@QUERY_APPOINTMENTS = ({ uuid => 'u-own', app => 'mirror' });
subs::silence_tick();
is(state_hash()->{active}, 1, 'the machine engages its own session');
@QUERY_APPOINTMENTS = ();
$subs::silence_tick_at = 0;
subs::silence_tick();
is(state_hash()->{active}, 0, 'its own session closing releases at once');
my $own_off = grep { ($_->{'extra'}->{'url'} // '') eq '/manager/silence/peer'
	&& !$_->{'extra'}->{'params'}->{'active'} } @RELAY;
ok($own_off, 'and relays the stop to the peers');

# Now behave as a peer that received the state but not the appointment: it did
# not watch any of these owners, so a young state is held for the sync window.
reset_all();
@QUERY_SETTINGS = ({ app => 'mirror' });
$DEVICE = 'mobile';
@QUERY_APPOINTMENTS = ({ uuid => 'u-later', app => 'mirror', timestamp => subs::rightNow() - 1000 });
subs::silence_tick();
@QUERY_APPOINTMENTS = ();
$subs::silence_tick_at = 0;
%subs::silence_owners_seen = ();
my $recent = state_hash();
$recent->{'since'} = subs::rightNow() - 1000;
$STORE{'__president|silence_state|all'} = encode_json($recent);
$subs::silence_tick_at = 0;
subs::silence_tick();
is(state_hash()->{active}, 1, 'a fresh state is kept while a peer syncs');
# The ordinary sync pass runs about every ten minutes, so a relayed peer may
# not hold the appointment yet well after two minutes. It must still hold the
# state rather than drop it.
$recent = state_hash();
$recent->{'since'} = subs::rightNow() - 300000;
$STORE{'__president|silence_state|all'} = encode_json($recent);
$subs::silence_tick_at = 0;
subs::silence_tick();
is(state_hash()->{active}, 1, 'a relayed state is held long enough for the appointment row to sync');
$recent = state_hash();
$recent->{'since'} = subs::rightNow() - 1000000;
$STORE{'__president|silence_state|all'} = encode_json($recent);
@NATIVE = ();
@SET = ();
@CHANNEL = ();
@MUTE = ();
$subs::silence_tick_at = 0;
subs::silence_tick();
is(state_hash()->{active}, 0, 'the alarm pass clears silence when the appointment is gone');
my $off_pushed = grep { $_->{'method'} eq 'silence.set' && $_->{'args'}->{'on'} == 0 } @NATIVE;
ok($off_pushed, 'and tells the phone app off');
my $peer_stop_relay = grep { ($_->{'extra'}->{'url'} // '') eq '/manager/silence/peer'
	&& !$_->{'extra'}->{'params'}->{'active'} } @RELAY;
ok(!$peer_stop_relay, 'but a peer never relays a release it did not witness');

# A peer that never saw the owner must not tell the house the session ended:
# it only clears its own machine and leaves the relay to the machine that ran it.
reset_all();
@QUERY_SETTINGS = ({ app => 'mirror' });
$STORE{'__president|silence_state|all'} = encode_json({
	active => 1, owners => ['ghost'], apps => { ghost => 'mirror' },
	since => subs::rightNow() - 1000000,
});
@QUERY_APPOINTMENTS = ();
$subs::silence_tick_at = 0;
subs::silence_tick();
is(state_hash()->{active}, 0, 'a peer with an expired state still clears its own machine');
is(scalar @RELAY, 0, 'but never relays a release it did not witness');

# A machine whose manager missed the stop still has the mixer snapshot on
# disk. The next pass with no owner must put the mixer back even though the
# house row already reads inactive.
reset_all();
$STORE{'__president|silence_state|all'} = encode_json({ active => 0, owners => [], apps => {}, since => 0 });
subs::silence_local_write({ outputs => [ { id => 'alsa_output', volume => 55, muted => 0 } ], channels => {}, streams => [] });
subs::silence_tick();
ok(!-e $subs::SILENCE_LOCAL_FILE, 'an inactive house clears a stale local snapshot');
is_deeply(\@SET, ['output|alsa_output|55'], 'and restores the saved volume');

# The phone keeps its own copy of the switch. Even with no transition, a
# pass tells it off so a missed push or a cold start cannot leave it silent.
reset_all();
$DEVICE = 'mobile';
$STORE{'__president|silence_state|all'} = encode_json({ active => 0, owners => [], apps => {}, since => 0 });
subs::silence_tick();
my $heal_off = grep { $_->{'method'} eq 'silence.set' && $_->{'args'}->{'on'} == 0 } @NATIVE;
ok($heal_off, 'every quiet-free pass can tell the phone app off');
@NATIVE = ();
$subs::silence_tick_at = 0;
subs::silence_tick();
is(scalar @NATIVE, 0, 'but the off push is throttled, not one per pass');

# ============================================================================
# the phone
# ============================================================================
reset_all();
my $defs = {
	receptionist => { name => 'Receptionist', greeting => 'hello' },
	sales => { name => 'Sales' },
};
ok(!defined subs::silence_phone_flow($defs), 'no silence, no forced flow');
$STORE{'__president|silence_state|all'} = encode_json({ active => 1, owners => ['x'], apps => { x => 'mirror' }, since => 1 });
my $flow = subs::silence_phone_flow($defs);
is(ref $flow, 'HASH', 'silence returns a flow');
is($flow->{key}, 'receptionist', 'and it is the receptionist');
is($flow->{greeting}, 'hello', 'with the flow\'s own words');
ok(subs::silence_local_keep_sink('jawn_prompt', 'Prompt'), 'the prompt sink is kept');
ok(subs::silence_local_keep_sink('bluez_output.AA', 'Headset'), 'the Bluetooth call sink is kept');
ok(!subs::silence_local_keep_sink('alsa_output.pci', 'Speaker'), 'an ordinary sink is not kept');
ok(subs::silence_android_keep_stream('call'), 'the call stream is kept on Android');
ok(!subs::silence_android_keep_stream('alarm'), 'the alarm stream is muted on Android');

# ============================================================================
# the wires a reviewer cannot see from one hunk
# ============================================================================
my $routes = source('lib/JawnOS/Routes/manager_silence.pm');
like($routes, qr/\[\s*53041\s*,\s*'get'\s*,\s*'\/manager\/silence'\s*,\s*'action_53041'\s*\]/,
	'the state route is registered');
like($routes, qr/\[\s*53042\s*,\s*'post'\s*,\s*'\/manager\/silence\/peer'\s*,\s*'action_53042'\s*\]/,
	'the peer relay route is registered');
like(source('lib/JawnOS/Routes.pm'), qr/\bmanager_silence\b/, 'the route module is named in Routes.pm');
like(source('lib/JawnOS/Domain/Loader.pm'), qr/JawnOS::Domain::Silence.*silence_engage/s,
	'the domain helpers are mapped');
like(source('lib/JawnOS/Manager/Part05.pm'), qr/silence_appointment_write/,
	'the appointment writer calls the silence hook');
like(source('lib/JawnOS/Controller/manager_configure4.pm'), qr/\$setting eq 'silence'/,
	'the Silence box is saved house-wide');
like(source('lib/JawnOS/Domain/Log.pm'), qr/setting = \? and device = \?.*'silence', 'all'/s,
	'the App panel reads the house-wide Silence row');
like(source('templates/configure/appointment_list.html.ep'), qr/setting="silence"/,
	'the App panel offers the Silence checkbox');
like(source('templates/configure/appointment_list.html.ep'), qr/class="configure_checkbox"/,
	'and it saves through the existing checkbox handler');
like(source('lib/JawnOS/Domain/Phone.pm'), qr/silence_phone_flow/, 'the phone resolution asks silence first');
like(source('lib/JawnOS/Manager/Part12.pm'), qr/source => 'silence'/, 'the route sheet knows the silence answer');
like(source('lib/JawnOS/Controller/manager_phone.pm'), qr/silence => \$silenced/, 'the phone sync reports silence');
like(source('lib/JawnOS/Domain/Notify.pm'), qr/silence_active/, 'notifications are gated');
like(source('lib/JawnOS/Domain/Say.pm'), qr/silence_active/, 'speech is gated');
like(source('lib/JawnOS/Domain/Clock2.pm'), qr/silence_active.*clock_device_ring/s, 'alarms are gated');
like(source('lib/JawnOS/Domain/Clock.pm'), qr/sub clock_device_ring.*silence_active/s, 'the board ring is gated');
like(source('perl/Music.pl'), qr/silence_active/, 'the server-side music player is gated');
like(source('lib/JawnOS/Manager/Part02.pm'), qr/sub play_audio.*silence_active/s, 'the audio player is gated');
like(source('perl/hooks.pl'), qr{'/manager/silence/peer'}, 'the peer door passes the session gate');
like(source('lib/JawnOS/Manager/Part30.pm'), qr{'/manager/silence/peer'}, 'and the app gate');
like(source('public/js/manager/websocket/00_console_router.js'), qr/jawnosSilence:/, 'the console push is routed');
my $js = source('public/js/manager/silence.js');
like($js, qr/HTMLMediaElement\.prototype\.play/, 'the browser silences media at play');
like($js, qr/MutationObserver/, 'and media that arrives later');
like($js, qr{/manager/silence}, 'and follows the house state');
unlike($js, qr/\blocation\s*\.\s*(?:reload|assign|replace)\b/,
	'switching silence never reloads or navigates the page');
like(source('lib/JawnOS/Manager/Core1_tables_hooks.pm'), qr{/js/manager/silence\.js}, 'the guard rides the manager bundle');
like(source('perl/help/topics_configure.pl'), qr/Silence, beside Unique and Permanent/, 'the Configure help explains the box');
my $phone_js = source('public/js/manager/manager/02_web_nfc.js');
like($phone_js, qr/silence: \(response && response\.silence\)/, 'the phone facts carry the silence state');
like($phone_js, qr/setSilence/, 'and hand it to the native bridge');
like($js, qr/JawnPhone\.setSilence/, 'the browser pushes silence to the native half');
like($js, qr/jawnPhoneSync/, 'and refreshes the phone facts on a change');
like(source('perl/Reception.pl'), qr/silence_active.*enabled/s, 'the reception worker arms during silence');
like(source('lib/JawnOS/Domain/Silence.pm'), qr/type in \('start','record'\) and timestamp <= \?/,
	'the owner query counts only sessions whose start time is due');
like(source('lib/JawnOS/Manager/Part05.pm'), qr/silence_appointment_write\([^)]*\$app->\{'timestamp'\}/,
	'and the writer hands the start time to the hook');
like(source('perl/Alarm.pl'), qr/silence_tick/, 'the alarm loop starts and stops silence');
like(source('lib/JawnOS/Controller/manager_silence.pm'), qr/silence_release_note/,
	'a verified peer stop is remembered against a lagging row');
like(source('lib/JawnOS/Domain/Loader.pm'), qr/silence_tick/, 'the reconcile helper is mapped');

done_testing();
