package subs;

# Silence: one switch for every sound a machine makes.
#
# An appointment carrying the Silence box takes the whole house quiet when it
# starts and gives it back when it stops. The state is one house-wide setting
# (app __president, setting silence_state, device all), so every machine reads
# the same answer. The
# physical mute is applied here at once and relayed to the peers on the signed
# rail; the settings sync is the slower second copy, not the only one.
#
# What to put back is a fact about this machine's mixer, never a house one, so
# the snapshot lives in ~/.president/silence_local.json. The two sinks the
# receptionist's virtual handset owns (jawn_call_in, jawn_prompt) and the
# Bluetooth sink that carries the call are deliberately left alone: a silenced
# house still has to let the IVR speak to its caller.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;

use Mojo::JSON qw(decode_json encode_json);
use Mojo::IOLoop;
use JawnOS::Platform::Paths ();

our $SILENCE_SETTING_APP = '__president';
our $SILENCE_SETTING = 'silence_state';
our $SILENCE_APP_BOX = 'silence';
# The four levels that replaced the Silence box. A profile is the answer one app
# gives; the house level is the base the Sound widget and the Sound app set. An
# app left at Passive inherits the house level.
our $SOUND_PROFILE_SETTING = 'sound_profile';
our $SOUND_HOUSE_SETTING = 'sound_level';
our @SOUND_LEVELS = qw( passive sound quiet mute silence );
our $SILENCE_LOCAL_FILE;
our $SILENCE_RELEASED_FILE;
our $silence_tick_at = 0;
our $silence_native_off_at = 0;
# Owners this process itself saw open. A release inferred from an owner in this
# set is this machine's own appointment closing, so it may be relayed; a peer
# that merely missed the appointment must not tell the house it is over.
our %silence_owners_seen;

# ---- the state ---------------------------------------------------------------
# One JSON row for the whole house. A malformed or missing row is an inactive
# house, never a crash: every reader of this file is a sound path that must keep
# working on a fresh machine or a pre-migration database.
sub silence_state {
	my $raw = eval {
		&subs::setting_grabber({
			app => $SILENCE_SETTING_APP,
			setting => $SILENCE_SETTING,
			device => 'all',
			benign => 1,
		});
	};
	my $state = (defined $raw && length $raw) ? eval { decode_json($raw) } : undef;
	$state = {} unless ref $state eq 'HASH';
	$state->{'active'} = $state->{'active'} ? 1 : 0;
	$state->{'owners'} = [] unless ref $state->{'owners'} eq 'ARRAY';
	$state->{'apps'} = {} unless ref $state->{'apps'} eq 'HASH';
	return $state;
}

sub silence_active {
	return &silence_state()->{'active'} ? 1 : 0;
}

sub silence_state_write {
	my ($state) = @_;
	$state = {} unless ref $state eq 'HASH';
	my $saved = eval {
		&subs::setting_setter({
			app => $SILENCE_SETTING_APP,
			setting => $SILENCE_SETTING,
			value => encode_json($state),
			device => 'all',
			timestamp => &subs::rightNow(),
		});
		1;
	};
	return $saved ? 1 : 0;
}

# The appointment's own box. It is stored on the house-wide row so a phone and a
# laptop agree about what that appointment does.
sub silence_app_setting {
	my ($app) = @_;
	return '' unless defined $app && length $app;
	my $value = eval {
		&subs::setting_grabber({
			app => $app,
			setting => $SILENCE_APP_BOX,
			device => 'all',
			benign => 1,
		});
	};
	if (!defined $value || !length $value) {
		$value = eval { &subs::setting_grabber({ app => $app, setting => $SILENCE_APP_BOX, benign => 1 }) };
	}
	return defined $value ? $value : '';
}

# ---- the four sound levels ---------------------------------------------------
# Passive inherits whatever the house is at; Sound is normal; Quiet softens the
# non-essential sounds; Mute keeps the alarms and a ringing call but silences the
# rest; Silence takes everything, alarms included, and sends every call to the
# receptionist. The old Silence box is a yes/no row, so a value written before
# the levels still reads: checked/on is Silence, anything else is Passive.
sub sound_profile_level {
	my ($value) = @_;
	return 'passive' unless defined $value;
	my $level = lc($value);
	$level =~ s/^\s+|\s+$//g;
	return 'silence' if $level =~ /^(?:checked|on|1|yes|true)$/;
	return 'passive' if $level =~ /^(?:unchecked|off|0|no|false|)$/;
	return $level if grep { $_ eq $level } @SOUND_LEVELS;
	return 'passive';
}

sub sound_level_label {
	my ($level) = @_;
	$level = &sound_profile_level($level);
	my %key = (
		passive => 'sound_passive',
		sound   => 'sound',
		quiet   => 'sound_quiet',
		mute    => 'sound_mute',
		silence => 'sound_silence',
	);
	return &subs::lang($key{$level});
}

# What one app asks for. The house-wide row is the shared answer (a phone and a
# laptop agree); the old Silence box is the fallback for a row written before
# the levels existed.
sub sound_app_level {
	my ($app) = @_;
	return 'passive' unless defined $app && length $app;
	my $value = eval {
		&subs::setting_grabber({
			app => $app,
			setting => $SOUND_PROFILE_SETTING,
			device => 'all',
			benign => 1,
		});
	};
	if (!defined $value || !length $value) {
		$value = eval { &subs::setting_grabber({ app => $app, setting => $SOUND_PROFILE_SETTING, benign => 1 }) };
	}
	if (!defined $value || !length $value) {
		$value = &silence_app_setting($app);
	}
	return &sound_profile_level($value);
}

# The base level the Sound widget and the Sound app set. Passive is not a house
# level - an unset or Passive row is simply ordinary sound.
sub sound_house_setting_level {
	my $value = eval {
		&subs::setting_grabber({
			app => $SILENCE_SETTING_APP,
			setting => $SOUND_HOUSE_SETTING,
			device => 'all',
			benign => 1,
		});
	};
	my $level = &sound_profile_level($value);
	return $level eq 'passive' ? 'sound' : $level;
}

# The level the house is actually at. An app's own non-Passive profile takes
# over while one of its appointments is running, and the most recently started
# one wins when several do; otherwise the house setting answers.
# Every app with a running appointment, and the level its profile asks for.
# One query, so the house level and the profiles list never disagree about
# which sessions are running.
sub sound_running_levels {
	my $now = eval { &subs::rightNow() } || (time * 1000);
	my $open = eval {
		&subs::db_query(
			"select app, timestamp from appointments where stop_seen is null "
			. "and type in ('start','record') and timestamp <= ? "
			. "order by timestamp desc",
			$now
		)->hashes;
	} || [];
	my (%level, @order);
	foreach my $row ( @{$open} ) {
		next unless ref $row eq 'HASH';
		my $app = $row->{'app'} // '';
		next unless length $app;
		next if exists $level{$app};
		$level{$app} = &sound_app_level($app);
		push @order, $app;
	}
	return { levels => \%level, order => \@order };
}

sub sound_house_level {
	my $running = &sound_running_levels();
	foreach my $app ( @{ $running->{'order'} } ) {
		my $level = $running->{'levels'}->{$app};
		return $level unless $level eq 'passive';
	}
	return &sound_house_setting_level();
}

# The Sound app's profiles list: every app that carries a profile, plus any app
# running right now, so the panel shows exactly what can be tuned.
sub sound_profiles_list {
	my $rows = eval {
		&subs::db_query(
			"select app, setting, value from settings where device = ? "
			. "and setting in ('sound_profile','silence') "
			. "and substr(app,1,2) <> '__'",
			'all'
		)->hashes;
	} || [];
	my (%profile, %legacy);
	foreach my $row ( @{$rows} ) {
		next unless ref $row eq 'HASH';
		my $app = $row->{'app'} // '';
		next unless length $app;
		next if $app =~ /^__/;
		my $setting = $row->{'setting'} // '';
		if ($setting eq 'sound_profile') { $profile{$app} = $row->{'value'}; }
		elsif ($setting eq 'silence') { $legacy{$app} = $row->{'value'}; }
	}
	my $running = &sound_running_levels();
	my %apps = ( %profile, %legacy, %{ $running->{'levels'} } );
	my @list;
	foreach my $app ( sort { lc($a) cmp lc($b) } keys %apps ) {
		my $level = defined $profile{$app}
			? &sound_profile_level($profile{$app})
			: &sound_profile_level($legacy{$app});
		my $is_running = exists $running->{'levels'}->{$app} ? 1 : 0;
		next if $level eq 'passive' && !$is_running;
		push @list, { app => $app, level => $level, running => $is_running };
	}
	return \@list;
}

# The apps an override may be added for. The house's own rows are not apps.
sub sound_app_choices {
	my $rows = eval {
		&subs::db_query(
			"select distinct app from settings "
			. "where substr(app,1,2) <> '__' order by app"
		)->hashes;
	} || [];
	return [ map { $_->{'app'} }
		grep { ref $_ eq 'HASH' && defined $_->{'app'} && length $_->{'app'} && $_->{'app'} !~ /^__/ } @{$rows} ];
}

# The house level is a setting; Passive is not one, so an unset or Passive
# answer is written as ordinary sound.
sub sound_house_level_write {
	my ($level) = @_;
	$level = &sound_profile_level($level);
	$level = 'sound' if $level eq 'passive';
	my $saved = eval {
		&subs::setting_setter({
			app => $SILENCE_SETTING_APP,
			setting => $SOUND_HOUSE_SETTING,
			value => $level,
			device => 'all',
			timestamp => &subs::rightNow(),
		});
		1;
	};
	return $saved ? $level : undef;
}

sub sound_app_level_write {
	my ($app, $level) = @_;
	return 0 unless defined $app && length $app;
	$level = &sound_profile_level($level);
	my $saved = eval {
		&subs::setting_setter({
			app => $app,
			setting => $SOUND_PROFILE_SETTING,
			value => $level,
			device => 'all',
			timestamp => &subs::rightNow(),
		});
		1;
	};
	return $saved ? 1 : 0;
}

sub silence_app_setting_on {
	my ($app) = @_;
	return (&sound_app_level($app) eq 'silence') ? 1 : 0;
}

# ---- the local snapshot ------------------------------------------------------
sub silence_local_file {
	return $SILENCE_LOCAL_FILE if defined $SILENCE_LOCAL_FILE && length $SILENCE_LOCAL_FILE;
	my $env = $ENV{'JAWNOS_SILENCE_LOCAL_FILE'};
	return $env if defined $env && length $env;
	my $dir = eval { &subs::home('~/.president') } || '';
	if (!length $dir || !-d $dir) {
		$dir = JawnOS::Platform::Paths::tmp_dir();
	}
	eval { require File::Path; File::Path::make_path($dir); } unless -d $dir;
	return $dir . '/silence_local.json';
}

sub silence_local_read {
	my $file = &silence_local_file();
	return undef unless -e $file;
	my $raw = eval {
		open(my $fh, '<', $file) or die "open: $!";
		local $/;
		my $bytes = <$fh>;
		close $fh;
		$bytes;
	};
	return undef unless defined $raw && length $raw;
	my $snap = eval { decode_json($raw) };
	return ref $snap eq 'HASH' ? $snap : undef;
}

sub silence_local_write {
	my ($snap) = @_;
	my $file = &silence_local_file();
	return 0 unless ref $snap eq 'HASH';
	my $ok = eval {
		open(my $fh, '>', $file) or die "open: $!";
		print {$fh} encode_json($snap);
		close $fh;
		1;
	};
	return $ok ? 1 : 0;
}

sub silence_local_clear {
	my $file = &silence_local_file();
	eval { unlink $file; };
	return 1;
}

# ---- the owners a verified peer has stopped -------------------------------
# A machine's copy of an appointment row can lag the stop. The peer that ran the
# stop names the owners it released; remember them here (this machine's own file,
# never a house row) so the alarm pass does not read the lagging row as a fresh
# start and re-silence the house. The note lives until the row itself closes or
# the sync window passes, whichever comes first.
our $SILENCE_RELEASED_HOLD = 900000;

sub silence_released_file {
	return $SILENCE_RELEASED_FILE if defined $SILENCE_RELEASED_FILE && length $SILENCE_RELEASED_FILE;
	my $env = $ENV{'JAWNOS_SILENCE_RELEASED_FILE'};
	return $env if defined $env && length $env;
	my $dir = eval { &subs::home('~/.president') } || '';
	if (!length $dir || !-d $dir) {
		$dir = JawnOS::Platform::Paths::tmp_dir();
	}
	eval { require File::Path; File::Path::make_path($dir); } unless -d $dir;
	return $dir . '/silence_released.json';
}

sub silence_released_read {
	my $file = &silence_released_file();
	return {} unless -e $file;
	my $raw = eval {
		open(my $fh, '<', $file) or die "open: $!";
		local $/;
		my $bytes = <$fh>;
		close $fh;
		$bytes;
	};
	return {} unless defined $raw && length $raw;
	my $notes = eval { decode_json($raw) };
	return ref $notes eq 'HASH' ? $notes : {};
}

sub silence_released_write {
	my ($notes) = @_;
	return 0 unless ref $notes eq 'HASH';
	my $file = &silence_released_file();
	if (!keys %{$notes}) {
		eval { unlink $file; };
		return 1;
	}
	my $ok = eval {
		open(my $fh, '>', $file) or die "open: $!";
		print {$fh} encode_json($notes);
		close $fh;
		1;
	};
	return $ok ? 1 : 0;
}

# A verified peer's stop names the owners it released. Record each for the
# sync window; a tick that finds the row still open skips it.
sub silence_release_note {
	my ($owners, $now) = @_;
	return 0 unless ref $owners eq 'ARRAY';
	$now = eval { &subs::rightNow() } || (time * 1000)
		unless defined $now && $now =~ /^\d+$/;
	my $notes = &silence_released_read();
	my $added = 0;
	foreach my $owner ( @{$owners} ) {
		next unless defined $owner && length $owner;
		$notes->{$owner} = $now + $SILENCE_RELEASED_HOLD;
		$added++;
	}
	return 0 unless $added;
	return &silence_released_write($notes);
}

sub silence_released_active {
	my ($owner, $now) = @_;
	return 0 unless defined $owner && length $owner;
	$now = eval { &subs::rightNow() } || (time * 1000)
		unless defined $now && $now =~ /^\d+$/;
	my $notes = &silence_released_read();
	return 0 unless defined $notes->{$owner};
	return $notes->{$owner} > $now ? 1 : 0;
}

# A verified peer that starts an owner again (a navigation reopen) lifts the
# suppression the earlier stop put on it.
sub silence_release_clear {
	my ($owners) = @_;
	return 0 unless ref $owners eq 'ARRAY';
	my $notes = &silence_released_read();
	my $changed = 0;
	foreach my $owner ( @{$owners} ) {
		next unless defined $owner && length $owner;
		$changed++ if delete $notes->{$owner};
	}
	return $changed ? &silence_released_write($notes) : 0;
}

# The receptionist's virtual handset owns these sinks. Muting one would mute the
# caller's own greeting, which is the one sound silence must not take away.
sub silence_local_keep_sink {
	my ($id, $name) = @_;
	my $text = lc(($id // '') . ' ' . ($name // ''));
	return 1 if $text =~ /\bjawn_(?:call_in|prompt|ivr_mic)\b/;
	return 1 if $text =~ /(?:bluez|handsfree|hfp)/;
	return 0;
}

# On a phone the call stream is the Hands-Free link to the gateway. Its ring,
# alarm, notification and media streams are muted; the call itself is not, or
# the IVR would be talking into a closed microphone.
sub silence_android_keep_stream {
	my ($stream) = @_;
	my $id = lc($stream // '');
	return 1 if $id =~ /^(?:call|voice_call|in_call)$/;
	return 0;
}

sub silence_local_apply_on {
	my $devices = eval { &subs::sound_devices() } || {};
	my $outputs = ref $devices->{'outputs'} eq 'ARRAY' ? $devices->{'outputs'} : [];
	my @saved;
	foreach my $device ( @{$outputs} ) {
		next unless ref $device eq 'HASH';
		my $id = $device->{'id'};
		next unless defined $id && length $id;
		next if &silence_local_keep_sink($id, $device->{'name'});
		push @saved, {
			id => $id,
			volume => $device->{'volume'},
			muted => ($device->{'muted'} ? 1 : 0),
		};
		eval { &subs::sound_mute('output', $id, 1) };
	}
	my $channels = eval { &subs::sound_channels() } || {};
	my %channel_saved;
	foreach my $name ( sort keys %{$channels} ) {
		my $row = $channels->{$name};
		next unless ref $row eq 'HASH';
		$channel_saved{$name} = {
			volume => $row->{'volume'},
			muted => ($row->{'muted'} ? 1 : 0),
		};
		eval { &subs::sound_channel_set($name, $row->{'volume'}, 1) };
	}
	my @streams;
	if (($devices->{'backend'} || '') eq 'android') {
		my $list = eval { &subs::sound_android_streams() } || [];
		foreach my $stream ( @{$list} ) {
			next unless ref $stream eq 'HASH';
			my $id = $stream->{'stream'};
			next unless defined $id && length $id;
			next if &silence_android_keep_stream($id);
			push @streams, { stream => $id, volume => ($stream->{'volume'} || 0) };
			eval { &subs::device_call('audio.volume', { stream => $id, volume => 0 }) };
		}
	}
	&silence_local_write({
		applied => 1,
		at => &subs::rightNow(),
		outputs => \@saved,
		channels => \%channel_saved,
		streams => \@streams,
	});
	return 1;
}

sub silence_local_apply_off {
	my $snap = &silence_local_read();
	return 0 unless ref $snap eq 'HASH';
	# A mixer that refuses a restore must not cost us the record of what to put
	# back: keep the snapshot and let the next alarm pass try again, rather than
	# leave the machine muted with nothing left to unmute it from.
	my $ok = 1;
	foreach my $device ( @{ $snap->{'outputs'} || [] } ) {
		next unless ref $device eq 'HASH';
		my $id = $device->{'id'};
		next unless defined $id && length $id;
		my $muted = eval { &subs::sound_mute('output', $id, $device->{'muted'} ? 1 : 0) };
		$ok = 0 if ref $muted eq 'HASH' && !$muted->{'ok'};
		if (defined $device->{'volume'}) {
			my $set = eval { &subs::sound_set('output', $id, $device->{'volume'}) };
			$ok = 0 if ref $set eq 'HASH' && !$set->{'ok'};
		}
	}
	foreach my $name ( sort keys %{ $snap->{'channels'} || {} } ) {
		my $row = $snap->{'channels'}->{$name};
		next unless ref $row eq 'HASH';
		my $channel = eval { &subs::sound_channel_set($name, $row->{'volume'}, $row->{'muted'}) };
		$ok = 0 if ref $channel eq 'HASH' && !$channel->{'ok'};
	}
	foreach my $stream ( @{ $snap->{'streams'} || [] } ) {
		next unless ref $stream eq 'HASH';
		my $id = $stream->{'stream'};
		next unless defined $id && length $id;
		my $answer = eval {
			&subs::device_call('audio.volume', {
				stream => $id,
				volume => int($stream->{'volume'} || 0),
			});
		};
		$ok = 0 unless ref $answer eq 'HASH';
	}
	&silence_local_clear() if $ok;
	return $ok ? 1 : 0;
}

sub silence_local_apply {
	my ($on) = @_;
	if ($on) {
		return 0 if &silence_local_read();
		return &silence_local_apply_on();
	}
	return &silence_local_apply_off();
}

# ---- the two moves -----------------------------------------------------------
sub silence_engage {
	my ($owner, $app, $c) = @_;
	$owner = '__manual' unless defined $owner && length $owner;
	my $state = &silence_state();
	my %seen = map { $_ => 1 } @{ $state->{'owners'} || [] };
	my $changed = (!$seen{$owner} || !$state->{'active'}) ? 1 : 0;
	push @{ $state->{'owners'} }, $owner unless $seen{$owner};
	$state->{'apps'}->{$owner} = $app if defined $app && length $app;
	$state->{'active'} = 1;
	$state->{'since'} ||= &subs::rightNow();
	$state->{'by'} ||= (eval { &subs::signatorial_designer() } || '');
	&silence_state_write($state) if $changed;
	&silence_local_apply(1);
	&silence_native_push(1);
	if ($changed) {
		&silence_push($state);
		&silence_broadcast($c, $state);
	}
	return $state;
}

sub silence_release {
	my ($owner, $app, $c) = @_;
	my $state = &silence_state();
	my $had = scalar @{ $state->{'owners'} || [] };
	my $was_active = $state->{'active'} ? 1 : 0;
	my (@keep, @released);
	foreach my $held ( @{ $state->{'owners'} || [] } ) {
		my $drop = 0;
		if (defined $owner && length $owner) {
			$drop = 1 if $held eq $owner;
		}
		elsif (defined $app && length $app) {
			$drop = 1 if ($state->{'apps'}->{$held} // '') eq $app;
		}
		if ($drop) { push @released, $held; next; }
		push @keep, $held;
	}
	return $state if $had == scalar @keep && !$state->{'active'};
	$state->{'owners'} = \@keep;
	delete $state->{'apps'}->{$owner} if defined $owner && length $owner;
	unless (@keep) {
		$state->{'active'} = 0;
		$state->{'since'} = 0;
	}
	my $changed = ($had != scalar @keep || ($was_active && !$state->{'active'})) ? 1 : 0;
	return $state unless $changed;
	&silence_state_write($state);
	unless ($state->{'active'}) {
		&silence_local_apply(0);
		&silence_native_push(0);
	}
	# Name the owners this stop released: a peer whose own row still reads open
	# uses the list to avoid re-engaging what someone else has finished.
	$state->{'released'} = \@released if @released;
	&silence_push($state);
	&silence_broadcast($c, $state);
	return $state;
}

# A second hold, from the alarm pass, that keeps the existing snapshot and
# only makes the mixer match it again. It never re-snapshots a raised stream.
sub silence_local_hold {
	my $snap = &silence_local_read();
	return &silence_local_apply_on() unless ref $snap eq 'HASH';
	foreach my $device ( @{ $snap->{'outputs'} || [] } ) {
		next unless ref $device eq 'HASH' && defined $device->{'id'};
		eval { &subs::sound_mute('output', $device->{'id'}, 1) };
	}
	my $channels = eval { &subs::sound_channels() } || {};
	foreach my $name ( sort keys %{ $snap->{'channels'} || {} } ) {
		my $row = $snap->{'channels'}->{$name};
		next unless ref $row eq 'HASH';
		my $now = $channels->{$name};
		next if ref $now eq 'HASH' && $now->{'muted'};
		eval { &subs::sound_channel_set($name, $row->{'volume'}, 1) };
	}
	foreach my $stream ( @{ $snap->{'streams'} || [] } ) {
		next unless ref $stream eq 'HASH' && defined $stream->{'stream'};
		eval { &subs::device_call('audio.volume', { stream => $stream->{'stream'}, volume => 0 }) };
	}
	return 1;
}

# Tell the phone's own app, through its bridge, with no page open. A
# desktop has no native half here, so this is a no-op there.
sub silence_native_push {
	my ($on) = @_;
	my $mobile = eval { (&subs::device_setter() || '') eq 'mobile' } ? 1 : 0;
	return 0 unless $mobile;
	my $answer = eval { &subs::device_call('silence.set', { on => $on ? 1 : 0 }) };
	return ref $answer eq 'HASH' ? 1 : 0;
}

# The house is no longer quiet: drop every owner, put this machine back,
# and tell this phone's app. Peers hear about it only when the caller says the
# transition is informed (a machine that saw the session open), never when a
# peer is only guessing from an appointment it has not received yet.
sub silence_release_all {
	my ($broadcast) = @_;
	my $state = &silence_state();
	return $state unless $state->{'active'} || scalar @{ $state->{'owners'} || [] };
	my @released = @{ $state->{'owners'} || [] };
	$state->{'active'} = 0;
	$state->{'owners'} = [];
	$state->{'apps'} = {};
	$state->{'since'} = 0;
	&silence_state_write($state);
	&silence_local_apply(0);
	&silence_native_push(0);
	$state->{'released'} = \@released if @released;
	&silence_push($state);
	&silence_broadcast(undef, $state) if $broadcast;
	return $state;
}

# The alarm worker's reconciliation. The open silent appointment is the
# authority: while one is open, silence is on and its uuid is the owner;
# when none is open, silence comes off. A peer whose database has not yet
# received a just-started session keeps a young state for fifteen minutes
# (longer than a sync pass) so it cannot clear another machine's fresh start.
sub silence_tick {
	my $now = eval { &subs::rightNow() } || (time * 1000);
	return 0 if $silence_tick_at && $now - $silence_tick_at < 2000;
	$silence_tick_at = $now;
	my $open = eval {
		&subs::db_query(
			"select uuid, app from appointments where stop_seen is null "
			. "and type in ('start','record') and timestamp <= ?",
			$now
		)->hashes;
	} || [];
	my (@owners, %apps, %seen, %level);
	my $released_notes = &silence_released_read();
	my %open_all;
	foreach my $row ( @{$open} ) {
		next unless ref $row eq 'HASH';
		my $uuid = $row->{'uuid'};
		next unless defined $uuid && length $uuid;
		$open_all{$uuid} = 1;
		next if $seen{$uuid}++;
		# A verified peer has already stopped this owner: the row here is the
		# lagging copy, so it must not read as a fresh start.
		next if ($released_notes->{$uuid} // 0) > $now;
		# Only Silence owns the house here. Mute and Quiet are applied by the
		# sound paths themselves, and a legacy Silence box reads as Silence.
		my $app = $row->{'app'} // '';
		$level{$app} = &sound_app_level($app) unless exists $level{$app};
		next unless $level{$app} eq 'silence';
		push @owners, $uuid;
		$apps{$uuid} = $app;
	}
	if (%{$released_notes}) {
		# Drop a note once the row is closed or the sync window has passed; a
		# row that is still open with a live note stays suppressed.
		my $changed = 0;
		foreach my $uuid ( keys %{$released_notes} ) {
			next if $open_all{$uuid} && ($released_notes->{$uuid} // 0) > $now;
			delete $released_notes->{$uuid};
			$changed = 1;
		}
		&silence_released_write($released_notes) if $changed;
	}
	my $state = &silence_state();
	if (@owners) {
		my %current = map { $_ => 1 } @{ $state->{'owners'} || [] };
		my $same = $state->{'active'} ? 1 : 0;
		$same = 0 unless scalar(@{ $state->{'owners'} || [] }) == scalar(@owners);
		foreach my $owner ( @owners ) { $same = 0 unless $current{$owner}; }
		unless ($same) {
			$state->{'active'} = 1;
			$state->{'owners'} = \@owners;
			$state->{'apps'} = \%apps;
			$state->{'since'} ||= $now;
			$state->{'by'} ||= (eval { &subs::signatorial_designer() } || '');
			&silence_state_write($state);
			&silence_push($state);
			# No page has to be open: the alarm pass itself hands the start to
			# the peers, exactly as the appointment route does.
			&silence_broadcast(undef, $state);
		}
		$silence_owners_seen{$_} = 1 for @owners;
		&silence_local_hold();
		&silence_native_push(1);
		return 1;
	}
	my $since = $state->{'since'} || 0;
	if ($state->{'active'} || scalar @{ $state->{'owners'} || [] }) {
		# Owners this machine watched open are closing here: that is a real stop,
		# so release at once. Relay it too - it is the appointment ending, not a
		# missing row.
		my $informed = 0;
		foreach my $owner ( @{ $state->{'owners'} || [] } ) {
			$informed = 1 if delete $silence_owners_seen{$owner};
		}
		# A peer can receive the state on the signed rail before its own copy of
		# the appointment (the ordinary sync pass runs about every ten minutes).
		# Hold a young state it never saw owned long enough for that row to
		# arrive, so a relayed silence is not dropped before it can see what
		# owns it.
		if (!$informed && $since && ($now - $since) < 900000) {
			return 0;
		}
		return 1 if &silence_release_all($informed);
	}
	# Nothing owns the house. Put this machine back even when the state changed
	# while this manager was down, and tell the phone's native half off: it keeps
	# its own copy of the switch, so a push that was missed must not leave the
	# phone silent forever. Both are no-ops on a machine that was never quiet.
	&silence_local_apply(0);
	if (!$silence_native_off_at || $now - $silence_native_off_at >= 60000) {
		$silence_native_off_at = $now;
		&silence_native_push(0);
	}
	return 0;
	}

# What an appointment write does. A stop always releases the owner it names,
# even when the app's box was unticked before the stop arrived; only a start
# consults the box.
sub silence_appointment_write {
	my ($app, $type, $owner, $c, $when) = @_;
	return 0 unless defined $app && length $app;
	my $movement = defined $type ? lc($type) : '';
	return 0 unless $movement eq 'start' || $movement eq 'stop';
	if ($movement eq 'stop') {
		&silence_release($owner, $app, $c);
		return 1;
	}
	return 0 unless &silence_app_setting_on($app);
	# A start written ahead of its time is not running yet: an appointment
	# scheduled for later must not quiet the house the moment it is saved. The
	# alarm pass engages it when its timestamp comes due (silence_tick).
	if (defined $when && $when =~ /^\s*\d+(?:\.\d+)?\s*$/ && $when + 0 > (&subs::rightNow() + 2000)) {
		return 0;
	}
	&silence_engage($owner, $app, $c);
	return 1;
}

# ---- the phone ---------------------------------------------------------------
# Silence answers every call with the receptionist. The flow is returned in the
# same shape a caller match uses, so the phone and the gateway read one answer.
sub silence_phone_flow {
	my ($defs) = @_;
	return undef unless &silence_active();
	$defs = eval { &subs::phone_ivr_flow_defs() } unless ref $defs eq 'HASH';
	return undef unless ref $defs eq 'HASH' && %{$defs};
	my $key = 'receptionist';
	$key = (sort keys %{$defs})[0] unless ref $defs->{'receptionist'} eq 'HASH';
	return undef unless defined $key && ref $defs->{$key} eq 'HASH';
	my %flow = %{ $defs->{$key} };
	$flow{'key'} = $key;
	return \%flow;
}

# ---- telling the screens and the peers --------------------------------------
sub silence_push {
	my ($state) = @_;
	$state = &silence_state() unless ref $state eq 'HASH';
	eval {
		&Websocket::send('tab', {
			console => &Websocket::console_command('jawnosSilence', {
				active => ($state->{'active'} ? 1 : 0),
				since => ($state->{'since'} || 0),
				by => ($state->{'by'} || ''),
				owners => $state->{'owners'},
				apps => $state->{'apps'},
			}),
		});
	};
	return 1;
}

# The peers get the same message at once over the signed rail; the shared
# setting is what a machine that was asleep finds when it wakes.
sub silence_broadcast {
	my ($c, $state) = @_;
	return 0 unless ref $state eq 'HASH';
	# A write with no request in hand - a navigation plate, the alarm pass -
	# still has to reach the peers. The relay reads only the shape of the rail
	# off the request, so hand it the one this message always uses.
	unless (eval { $c && defined $c->req }) {
		$c = eval { app()->build_controller } unless $c;
		if ($c) {
			eval {
				require Mojo::Message::Request;
				my $req = Mojo::Message::Request->new;
				$req->method('POST');
				$req->url->path('/manager/silence/peer');
				$c->req($req);
			};
		}
	}
	return 0 unless eval { $c && defined $c->req };
	return 0 if ($c->param('remoted') || '') eq 'yes';
	my $self = eval { &subs::signatorial_designer() } || '';
	my $relay_id = eval { &subs::random_string_creator(30) } || '';
	eval { &subs::relay_fresh($relay_id) } if length $relay_id;
	my $queued = eval { &subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		&subs::remote_relay_request($c, {
			override => 'manual',
			url => '/manager/silence/peer',
			type => 'post',
			dissemination => 'yes',
			params => {
				signatorial => $self,
				active => ($state->{'active'} ? 1 : 0),
				state => encode_json($state),
				dissemination => 'yes',
				source_signatorial => $self,
				relay_from => $self,
				relay_id => $relay_id,
			},
		});
	}, { name => 'silence relay' }); };
	return $queued ? 1 : 0;
}

1;
