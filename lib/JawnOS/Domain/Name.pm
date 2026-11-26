package subs;

# Name: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $config;
our $database;
our $device;
our $gb;
our $log;
our %setting_memo;
our $setting_memo_on;

# Which of two matched rows survives: the explicit end, then notes, then the
# length closest to that side's configured duration, then the newer write. A
# true tie keeps the existing record (the target) rather than the renamed one.
sub name_change_history_prefer {
	my ($ra, $rb, $a_duration, $b_duration) = @_;
	my $a_explicit = defined $ra->{'stop'} ? 1 : 0;
	my $b_explicit = defined $rb->{'stop'} ? 1 : 0;
	return ($ra, $rb) if $a_explicit && !$b_explicit;
	return ($rb, $ra) if $b_explicit && !$a_explicit;
	return ($ra, $rb) if $ra->{'has_notes'} && !$rb->{'has_notes'};
	return ($rb, $ra) if $rb->{'has_notes'} && !$ra->{'has_notes'};
	if (defined $a_duration || defined $b_duration) {
		my $ad = defined $a_duration ? abs($ra->{'span'} - $a_duration) : 1e18;
		my $bd = defined $b_duration ? abs($rb->{'span'} - $b_duration) : 1e18;
		return ($ra, $rb) if $ad < $bd;
		return ($rb, $ra) if $bd < $ad;
	}
	my $at = 0 + ($ra->{'server_time'} || 0);
	my $bt = 0 + ($rb->{'server_time'} || 0);
	return ($ra, $rb) if $at > $bt;
	return ($rb, $ra) if $bt > $at;
	return ($rb, $ra);
}

sub name_change_history_row {
	my ($r) = @_;
	return undef unless $r;
	return {
		app => $r->{'app'}, rowid => $r->{'rowid'}, uuid => $r->{'uuid'}, type => $r->{'type'},
		start => $r->{'start'}, end => $r->{'end'}, span => $r->{'span'},
		start_label => &subs::iso_local($r->{'start'}),
		end_label => (defined $r->{'end'} ? &subs::iso_local($r->{'end'}) : 'open'),
	};
}

sub name_change_history {
	my ($app, $new_app) = @_;
	my $old_sessions = &subs::name_change_history_sessions($app);
	my $new_sessions = &subs::name_change_history_sessions($new_app);
	my $old = &subs::name_change_history_summary($app, $old_sessions);
	my $new = &subs::name_change_history_summary($new_app, $new_sessions);
	my $tol = 120000;   # two minutes: the same event recorded on two machines
	my $matches = &subs::name_change_history_greedy($old_sessions, $new_sessions, $tol);
	my @exact = grep { $_->{'category'} eq 'exact' } @{ $matches->{'pairs'} };
	my @near = grep { $_->{'category'} eq 'near' } @{ $matches->{'pairs'} };
	my $shared = &subs::name_change_history_cross_shared($old_sessions, $new_sessions, $tol);
	my $start_only = &subs::name_change_history_start_only($old_sessions, $new_sessions, $tol);
	my $total = $old->{'sessions'} + $new->{'sessions'};
	my $exact_n = scalar @exact;
	my $near_n = scalar @near;
	my $shared_n = scalar @{$shared};
	my $start_only_n = scalar @{$start_only};
	my $default = 'keep_all';
	$default = 'dedupe_exact' if $exact_n && !$near_n && !$shared_n && !$start_only_n;
	$default = 'flag' if $near_n || $shared_n || $start_only_n;
	my @options = (
		{ policy => 'keep_all', label => 'Keep both', sessions => $total, dropped => 0, flagged => $near_n + $shared_n + $start_only_n,
		  note => 'Nothing is removed; every row from both names survives under the new name.' },
		{ policy => 'dedupe_exact', label => 'Keep both, remove exact duplicates', sessions => $total - $exact_n, dropped => $exact_n, flagged => $near_n + $shared_n + $start_only_n,
		  note => 'Rows with the same start and end (within 1s) are removed; near matches are left for review.' },
		{ policy => 'intelligent', label => 'Merge duplicates (keep all unique)', sessions => $total - $exact_n - $near_n, dropped => $exact_n + $near_n, flagged => $shared_n + $start_only_n,
		  note => 'Exact and near duplicates are collapsed; shared-stop and start-only pairs are flagged, never dropped.' },
		{ policy => 'flag', label => 'Keep both, flag duplicates', sessions => $total, dropped => 0, flagged => $near_n + $shared_n + $start_only_n,
		  note => 'Nothing is removed; the panel lists the candidates for you to review later.' },
		{ policy => 'keep_old', label => 'Keep only ' . &subs::format_name($app), sessions => $old->{'sessions'}, dropped => $new->{'rows'}, flagged => 0, destructive => 1,
		  note => 'Keep the history of the app being renamed; drop the existing name\'s history. Settings still merge normally.' },
		{ policy => 'keep_new', label => 'Keep only ' . &subs::format_name($new_app), sessions => $new->{'sessions'}, dropped => $old->{'rows'}, flagged => 0, destructive => 1,
		  note => 'Keep the existing name\'s history; drop the renamed app\'s history. Settings still merge normally.' },
	);
	my @proposed;
	my $max = 30;
	my $add = sub {
		my ($kind, $keep, $drop, $other, $reason, $dstart, $dend) = @_;
		return if scalar @proposed >= $max;
		my $item = {
			kind => $kind, reason => $reason,
			keep => &subs::name_change_history_row($keep),
			drop => &subs::name_change_history_row($drop),
			other => &subs::name_change_history_row($other),
			dstart => $dstart, dend => $dend,
		};
		push @proposed, $item;
	};
	foreach my $pair ( @exact, @near ) {
		my ($keep, $drop) = &subs::name_change_history_prefer($pair->{'a'}, $pair->{'b'}, $old->{'configured_ms'}, $new->{'configured_ms'});
		$add->($pair->{'category'}, $keep, $drop, undef,
			($pair->{'category'} eq 'exact' ? 'same start and end' : 'start and end within 2m'),
			$pair->{'dstart'}, $pair->{'dend'});
	}
	foreach my $pair ( @{$shared} ) {
		$add->('shared-stop', $pair->{'a'}, undef, $pair->{'b'}, 'one stop closed both sessions; review', $pair->{'dstart'}, $pair->{'dstop'});
	}
	foreach my $pair ( @{$start_only} ) {
		$add->('start-only', $pair->{'a'}, undef, $pair->{'b'}, 'starts agree, ends do not; review', $pair->{'dstart'}, $pair->{'dend'});
	}
	return {
		old => $old,
		new => $new,
		options => \@options,
		default_policy => $default,
		pairs => { exact => $exact_n, near => $near_n, shared => $shared_n, start_only => $start_only_n },
		proposed => \@proposed,
		proposed_total => $exact_n + $near_n + $shared_n + $start_only_n,
	};
}

# Plan the rows a policy would drop, BEFORE the rename. The uuids are applied
# after the rename, under the unified name, so a peer that held the row under
# either old name receives a tombstone it can match.
sub name_change_history_plan {
	my ($app, $new_app, $policy) = @_;
	return { policy => $policy, drops => [], count => 0 } unless $policy && $policy ne 'keep_all' && $policy ne 'flag';
	my @drops;
	if ($policy eq 'keep_old' || $policy eq 'keep_new') {
		my $loser = $policy eq 'keep_old' ? $new_app : $app;
		my $rows = &subs::db_query('select rowid, uuid, type, timestamp, server_time from appointments where app = ?', $loser)->hashes || [];
		foreach my $r ( @{$rows} ) {
			next unless $r->{'uuid'};
			push @drops, { uuid => $r->{'uuid'}, server_time => $r->{'server_time'}, reason => 'keep one side' };
		}
	}
	elsif ($policy eq 'dedupe_exact' || $policy eq 'intelligent') {
		my $old_sessions = &subs::name_change_history_sessions($app);
		my $new_sessions = &subs::name_change_history_sessions($new_app);
		# both policies read the same 2m match set the summary used, so the count
		# the panel shows and the rows the plan drops always agree
		my $matches = &subs::name_change_history_greedy($old_sessions, $new_sessions, 120000);
		my $old_dur = &subs::name_change_history_duration($app);
		my $new_dur = &subs::name_change_history_duration($new_app);
		foreach my $pair ( @{ $matches->{'pairs'} } ) {
			next if $policy eq 'dedupe_exact' && $pair->{'category'} ne 'exact';
			my ($keep, $drop) = &subs::name_change_history_prefer($pair->{'a'}, $pair->{'b'}, $old_dur, $new_dur);
			next unless $drop && $drop->{'uuid'};
			push @drops, { uuid => $drop->{'uuid'}, server_time => $drop->{'server_time'}, reason => $pair->{'category'} };
		}
	}
	return { policy => $policy, drops => \@drops, count => scalar @drops };
}

sub name_change_history_apply_plan {
	my ($new_app, $plan) = @_;
	return 0 unless $new_app && $plan && $plan->{'drops'} && scalar @{ $plan->{'drops'} };
	my $dropped = 0;
	foreach my $row ( @{ $plan->{'drops'} } ) {
		next unless $row->{'uuid'};
		my $full = &subs::db_query('select file, source_uuid, server_time from appointments where app = ? and uuid = ?', $new_app, $row->{'uuid'})->hash;
		next unless $full;
		if (($full->{'file'} && length $full->{'file'}) || ($full->{'source_uuid'} && length $full->{'source_uuid'})) {
			if (defined &Manager::delete_app) {
				&Manager::delete_app($new_app, $row->{'uuid'}, ($full->{'server_time'} || $row->{'server_time'}), 'name merge');
			}
			else {
				&subs::records_tombstone($new_app, $row->{'uuid'});
			}
		}
		else {
			&subs::records_tombstone($new_app, $row->{'uuid'});
		}
		$dropped++;
	}
	&subs::log_writer('name merge ' . $new_app . ': policy=' . ($plan->{'policy'} || '') . ' dropped=' . $dropped) if $dropped;
	return $dropped;
}

sub toggle_event_is_older {
	# Whether this toggle event names an earlier moment than the state already
	# stored. A panel press, a slow HTTP relay and a queued appointment all reach
	# the settings layer at their own pace; the event's own timestamp, not its
	# arrival, is the last word. Compared on the row setting_setter replaces, so
	# a device-specific row is judged against itself. A seconds stamp is read as
	# seconds (an older board or caller), and an unstamped call is "now", never
	# older.
	my ($app, $timestamp, $dev, $subsetting) = @_;
	return 0 unless defined $app && defined $timestamp;
	return 0 unless $timestamp =~ /^\s*\d+(?:\.\d+)?\s*$/;
	my $event = $timestamp + 0;
	$event *= 1000 if $event > 0 && $event < 100000000000;
	return 0 unless $event > 0;
	$dev = &device_setter() unless defined $dev;
	my $prior = eval {
		&db_query('select timestamp from settings where app is ? and setting = ? and device is ? and subsetting is ? order by server_time desc limit 1', $app, 'toggle', $dev, $subsetting)->hashes->[0]
	};
	return 0 unless $prior && defined $prior->{'timestamp'};
	return 0 unless $prior->{'timestamp'} =~ /^\s*\d+(?:\.\d+)?\s*$/;
	my $stored = $prior->{'timestamp'} + 0;
	$stored *= 1000 if $stored > 0 && $stored < 100000000000;
	return $event < $stored ? 1 : 0;
}

sub event_time_ms {
	# A device's event stamp in milliseconds, or undef when it is not a moment.
	# A clockless board used to send " 0" (the Arduino String(double) pads to
	# width 2): a truthy string that survived every `||` fallback and wrote
	# appointments at 1970. Anything that is not a positive epoch is not a time;
	# the caller decides what "now" means. A seconds stamp is read as seconds,
	# like toggle_event_is_older.
	my ($value) = @_;
	return undef unless defined $value && $value =~ /^\s*\d+(?:\.\d+)?\s*$/;
	my $event = $value + 0;
	$event *= 1000 if $event > 0 && $event < 100000000000;
	return undef unless $event > 0;
	return $event;
}

# Settings that belong to the machine, not to its device class. A laptop and a
# table are both 'computer'; what Music last showed, searched for, shuffled or
# repeated is the machine's own view, as is whether it can see the archive
# drive. The signatorial is the identity that tells two computers apart, and it
# survives a restore of the database. Rows written before this rule, and rows
# from a peer that has not been taught it yet, stay keyed by the device class:
# they are the fallback when the machine has no row of its own.
sub setting_app_is_machine($app) {
	return 0 unless defined $app && length $app;
	return scalar grep { $_ eq $app } @gb::machine_setting_apps;
}

sub setting_machine_device() {
	my $signatorial = &signatorial_designer();
	return (defined $signatorial && length $signatorial) ? $signatorial : &device_setter();
}

# Whether a settings row's `device` names one machine rather than a device
# class. The merge used to relabel every peer row with the local class; a row
# carrying a signatorial is one machine's own and keeps its key across the wire.
sub setting_device_is_signatorial($device) {
	return 0 unless defined $device && length $device;
	return 0 if grep { $_ eq $device } @gb::device_types;
	return ($device =~ /^[0-9a-f]{16,64}$/i) ? 1 : 0;
}

# A person's own name is the key their own records are filed under: step_ingest
# and every self measure name the app unformat_name(my_name). A new spelling is
# therefore a rename of that app, not a new person. Walk the rows over with the
# same name_change the panel's rename uses, so the pedometer's steps and the rest
# of the history stay one set; a peer learns it from the name_change row this
# writes. The app the name was on keeps its uuid when it holds the history - the
# spelling the change gave birth to has a seeded uuid of its own, and two identity
# rows would let the newer shadow the one relationships point at. A built-in app
# is never moved.
sub person_name_rename {
	my ($from_name, $to_name, $opts) = @_;
	$opts ||= {};
	my $from_app = &subs::unformat_name($from_name);
	my $to_app = &subs::unformat_name($to_name);
	my %protected = map { $_ => 1 } @gb::protected;
	return 0 unless length $from_app && length $to_app && $from_app ne $to_app
		&& !$protected{$from_app} && !$protected{$to_app}
		&& (&subs::db_query('select 1 from appointments where app = ? limit 1', $from_app)->hashes->[0]
			|| &subs::db_query('select 1 from settings where app = ? limit 1', $from_app)->hashes->[0]);
	my $from_rows = &subs::db_query('select count(*) as n from appointments where app = ?', $from_app)->hash->{'n'} || 0;
	my $to_rows = &subs::db_query('select count(*) as n from appointments where app = ?', $to_app)->hash->{'n'} || 0;
	&subs::db_query('delete from settings where app = ? and setting = ?', $from_rows >= $to_rows ? $to_app : $from_app, 'uuid');
	my $pairs = &name_change_pairs($from_app, $to_app);
	my %choices;
	foreach my $pair ( @{$pairs} ) {
		$choices{ $pair->{'setting'} } = $pair->{'natural'} ? 'merge' : ($pair->{'prefer'} || 'new');
	}
	&name_change_apply($from_app, $to_app, \%choices) if scalar keys %choices;
	&setting_setter({ app => $from_app, setting => 'name_change', value => $to_app,
		timestamp => $opts->{'timestamp'}, source => $opts->{'source'} || 'panel' });
	return 1;
}

# The Studio's saved pedalboard library is one library for the house: a board
# saved on one machine should appear on every machine. `studio` is otherwise a
# protected, machine-local app, so only this one setting is shared; `pedal_zoom`
# and every other studio row stay local.
sub studio_shared_setting($app, $setting) {
	return 0 unless defined $app && defined $setting;
	return ($app eq 'studio' && $setting eq 'pedalboards') ? 1 : 0;
}

# One library from two: a board is its name, and the copy with the later `used`
# stamp wins. The Studio page saves the whole list, so a machine that has not yet
# seen a board saved elsewhere must never drop it; the same merge is what a peer
# row goes through. Boards are newest-used first, the order the page draws.
sub studio_pedalboards_merge($left, $right) {
	my @lists = grep { ref $_ eq 'ARRAY' } ($left, $right);
	return undef unless @lists;
	my %board;
	foreach my $list (@lists) {
		foreach my $entry ( @{$list} ) {
			next unless ref $entry eq 'HASH';
			my $name = (defined $entry->{'name'} && !ref $entry->{'name'}) ? $entry->{'name'} : '';
			next unless length $name;
			my $used = (defined $entry->{'used'} && !ref $entry->{'used'}
				&& $entry->{'used'} =~ /^\s*\d+(?:\.\d+)?\s*$/)
				? $entry->{'used'} + 0 : 0;
			my $copy = { %{$entry}, name => $name, used => $used };
			if (!$board{$name} || $used > $board{$name}->{'used'}) { $board{$name} = $copy; }
		}
	}
	return [ sort { ($b->{'used'} <=> $a->{'used'}) || ($a->{'name'} cmp $b->{'name'}) } values %board ];
}

sub setting_setter {
	%setting_memo = ();
	my $settings = shift;
	# a visibility or relationship change is read back by the same request
	&visibility_cache_clear() if (($settings->{'setting'} // '') =~ /^(?:visible|app_measures)$/);
	# a language change must be seen by the next page in this same worker
	&language_reset() if (($settings->{'setting'} // '') eq 'language');
	# A name reaches this gate from a form, a sync batch or the database, and a
	# caller behind a pre-unicode SQLite handle or an old worker can hand it as a
	# byte string. SQLite then reads those UTF-8 bytes as Latin-1 characters and
	# re-encodes them, so one three-byte mark becomes six bytes: the key doubled
	# on every save and a peer's row came back one layer longer on each merge
	# (the cascade that reached 1.5 MB). Decode once, here, where every settings
	# write meets. Only a defined value is touched: a window-state row with no
	# app must stay NULL, because the NULL-safe delete below keys on that.
	my $app = defined $settings->{'app'} ? &subs::text_chars($settings->{'app'}) : undef;
	my $original_app = $app;
	my $setting = $settings->{'setting'};
	my $subsetting = defined $settings->{'subsetting'} ? &subs::text_chars($settings->{'subsetting'}) : undef;
	my $value = $settings->{'value'};
	# A settings key is a name, not a payload: five indexes copy it, and one row
	# whose `app` was a whole document (6.3 MB, found 2026-11) grew the table's
	# indexes to ~800 MB and turned every setting_grabber into a flash read.
	# Refuse a key that long here, where every settings write meets, and say what
	# was refused so the caller can be found.
	if ((defined $app && length($app) > 100) || (defined $setting && length($setting) > 100)) {
		&subs::log_writer('setting_setter refused a name over 100 characters: app='
			. (defined $app ? length($app) : 'undef')
			. ' setting=' . (defined $setting ? substr($setting, 0, 40) : 'undef')
			. ' value=' . (defined $value ? length($value) : 'undef'));
		return;
	}
	my $timestamp = $settings->{'timestamp'} || &rightNow();
	my $browser_tab_id = $settings->{'browser_tab_id'};
	# A row arriving from a peer's snapshot is a mirror of a change that already
	# happened somewhere else. It must be written, but its side effects - a
	# websocket reload, a BLE toggle push, a task re-registration, a name-change
	# broadcast that opens the app window - belong to the machine where the
	# person made the change. Replaying them here is what opened Libro Chequing
	# on every machine and flipped jobs off during a merge.
	my $sync = $settings->{'sync'} ? 1 : 0;
	# A local write lands on this machine's own row. A peer replay keeps the
	# device it arrived with, so a peer's saved Music state is never relabelled
	# as ours.
	my $dev = $settings->{'device'};
	unless (defined $dev && length $dev) {
		$dev = (!$sync && &setting_app_is_machine($app)) ? &setting_machine_device() : &device_setter();
	}
	# A warranty is one value for the house (warranty_device), so a local write
	# lands on the house row every machine reads. A peer replay keeps the device
	# it arrived with, so an older build's per-device row cannot take the house
	# value over.
	$dev = &warranty_device() if !$sync && (($setting // '') eq 'warranty');
	# The Studio's pedalboard library is one library for the house, so a local
	# save lands on the house row every machine reads. A peer replay keeps the
	# device it arrived with, so an older build's per-device row cannot take the
	# shared library over.
	$dev = &warranty_device() if !$sync && &studio_shared_setting($app, $setting);
	# The library is a set of boards, not one opaque value. Merge this write into
	# the house row by board name and its own `used` stamp, so a stale page or an
	# older peer cannot replace a board saved on another machine with the list it
	# happened to be holding. A write that adds nothing is not repeated, which
	# keeps the sync digest quiet.
	if (&studio_shared_setting($app, $setting) && defined $value && !ref $value) {
		my $old = eval { &db_raw('select value from settings where app=? and device=? and setting=? order by cast(server_time as integer) desc limit 1', $app, &warranty_device(), $setting) };
		my $old_raw = ($old && ref $old eq 'ARRAY' && scalar @{$old}) ? $old->[0]->{'value'} : undef;
		my $old_list = defined $old_raw ? eval { decode_json($old_raw) } : undef;
		my $new_list = eval { decode_json($value) };
		my $merged = &studio_pedalboards_merge(
			(ref $old_list eq 'ARRAY' ? $old_list : undef),
			(ref $new_list eq 'ARRAY' ? $new_list : undef)
		);
		if ($merged) {
			my $encoded = encode_json($merged);
			my $old_encoded = (ref $old_list eq 'ARRAY') ? encode_json($old_list) : undef;
			if (defined $old_encoded && $old_encoded eq $encoded) {
				return { app => $app, timestamp => $timestamp, setting => $setting, value => $old_raw,
					device => $dev, browser_tab_id => $browser_tab_id };
			}
			$value = $encoded;
			$settings->{'server_time'} = &rightNow();
		}
		elsif (defined $old_raw && ref $new_list ne 'ARRAY') {
			# A malformed library never wipes a good one.
			return { app => $app, timestamp => $timestamp, setting => $setting, value => $old_raw,
				device => $dev, browser_tab_id => $browser_tab_id };
		}
	}
	my ($db,$database) = &database_grabber();
	my $server_time = $settings->{'server_time'} || &rightNow();

	# A person's own name is the key their own records are filed under:
	# step_ingest (and every self measure) names the app unformat_name(my_name),
	# so retyping the name would start a second app and a second history. Read the
	# name on record before the write below replaces it, then carry the app over.
	my $my_name_before;
	if (!$sync && ($app // '') eq 'me' && ($setting // '') eq 'my_name') {
		$my_name_before = &setting_grabber({ app => 'me', setting => 'my_name', device => $dev });
	}
	if (($setting // '') eq 'toggle') {
		# Store the event on the manager's clock so the next comparison is honest;
		# a seconds stamp from an older caller is not a 1970 event.
		if ($timestamp =~ /^\s*\d+(?:\.\d+)?\s*$/ && $timestamp > 0 && $timestamp < 100000000000) {
			$timestamp = $timestamp * 1000;
		}
		# The newest event wins. Writers reach this gate late (a slow HTTP relay,
		# a queued appointment, an older peer snapshot), and applying an older one
		# flips the panel and the relay back to a state the person already left.
		# An equal stamp is allowed, so one movement's pre-press and its final
		# write both land. A peer replay ($sync) is left to the sync layer, which
		# already orders rows by server_time.
		if (!$sync && defined $settings->{'timestamp'} && &toggle_event_is_older($app, $timestamp, $dev, $subsetting)) {
			&subs::log_writer('toggle write refused as older: ' . $app . ' ' . $value . ' @' . $timestamp);
			return { app => $app, timestamp => $timestamp, setting => $setting, value => $value,
				device => $dev, browser_tab_id => $browser_tab_id, refused => 1 };
		}
	}
	if ($setting eq 'name_change') {
		$value = &subs::unformat_name($value);
		&db_update('appointments', { account => $value, server_time => $server_time }, { account => $app });
		&db_update('appointments', { project => $value, server_time => $server_time }, { project => $app });
		&db_update('appointments', { manufacturer => $value, server_time => $server_time }, { manufacturer => $app });
		&db_update('appointments', { app => $value, server_time => $server_time }, { app => $app });
		&db_update('settings', { app => $value, server_time => $server_time }, { app => $app });

		foreach my $ex ( qw/model option subcategory option_category/ ) {
			&db_update($ex, { name => $value }, { name => $app });
		}


		my ($db,$database,$sql) = &database_grabber();
		my $tables_command = 'sqlite3 ' . &subs::shell_quote($database) . ' .tables';
		my $tables = `$tables_command`;
		my @u = sort split ' ', $tables;
		foreach my $t ( @u ) {
			# a rename is a fact about the app, not about history: the sync log is
			# the record of deletions already made and must keep its own names
			next if $t eq 'sync_log';
			if (eval { $db->query('select app from ' . $t . ' limit 1') } ) {
				&db_update($t, { app => $value, server_time => $server_time }, { app => $app });
			}
			else {

			}
		}
		unless ($sync) {
			&Websocket::send('server', { console => &Websocket::console_command('closeButton', &subs::html_name($app)), timestamp => $timestamp });
			&Websocket::send('server', { console => &Websocket::console_command('appointmentGrabber', $value, $timestamp, 'ws')});
		}
		$app = $value;
	}
	if ($setting eq 'pos') {
		&subs::manufacturer_grabber();
		my $old_settings = &subs::settings_grabber({ app => $app });
		my $own_uuid = $old_settings->{'uuid'} || '';
		my $old_sc = &subs::db_query('select * from settings where app=? and setting like ? escape ?', $app, 'sc\_%', '\\')->hashes;

		foreach my $os ( @{$old_sc} ) {

			my $osc = eval { return decode_json $os->{'value'} } || [];
			foreach my $sc ( @{ &sc_list_clean($osc, undef, undef) } ) {
				my $set = &subs::settings_grabber({ uuid => $sc });
				next unless $set && $set->{'app'} && $set->{'app'} ne $app;
				# the member's own uuid never belongs in its own list, and a list
				# must not carry the same uuid twice - an unguarded push in this
				# hook is how a stale list grew by one copy per pos change
				my $raw = eval { return decode_json $set->{'sc_' . $old_settings->{'pos'}} } || [];
				my $otsc = &sc_list_clean($raw, $set->{'uuid'}, undef);
				my @without = grep { $_ ne $own_uuid } @{$otsc};
				if (scalar @without != scalar @{$raw}) {
					&subs::setting_setter({ app => $set->{'app'}, setting => 'sc_' . $old_settings->{'pos'}, value => encode_json \@without });
				}
				my $ntsc = &sc_list_clean(eval { return decode_json $set->{'sc_' . $value} } || [], $set->{'uuid'}, undef);
				if (length $own_uuid && !grep { $_ eq $own_uuid } @{$ntsc}) {
					push @{$ntsc}, $own_uuid;
					&subs::setting_setter({ app => $set->{'app'}, setting => 'sc_' . $value, value => encode_json $ntsc });
				}
			}
		}
	}
	if (($setting eq 'pos' || $setting eq 'mab') && !$sync) {
		&Websocket::send('tab', { console => &Websocket::console_command('configurationReloader', $app)});
	}
	if ($setting eq 'phone') {
		$value =~ s/\D+//gi;
	}
	if ($setting eq 'web' && !$sync) {
		if ($value =~ /[0-9A-Za-z]/) {
			&Websocket::send('server', { console => &Websocket::console_command('setAppAct', $app, $value)});
		}
		else {
			&Websocket::send('server', { console => &Websocket::console_command('setAppAct', $app, '')});
		}
	}
	if ($setting eq 'colour' || $setting eq 'name_change' || $setting eq 'mab') {
		# The Relational board reads the settings rows directly; there is no
		# rendered bucket to drop here any more.
	}
	if ($setting eq 'toggle' && ($settings->{'source'} || '') eq 'panel' && !$sync) {
		# The panel has already written the new value. Pass it through: with no
		# state, embedded_toggle treats each output as a fresh toggle, reads the
		# value back and inverts it, so one click flipped the app (and every
		# relay/LED wired to it) once per output instead of setting them all to
		# the state the person just chose.
		&intelligent_automation_toggle({ app => $app, 'state' => $value, timestamp => $timestamp });

	}
	if ($setting eq 'toggle' && !$sync) {
		# The wrapper draws this enabler through icon_path, so the pushed update has
		# to as well: the /images/decipherable on/off pictures are only the fallback,
		# and pushing them here dropped a started or stopped appointment back to the
		# hand-drawn glyphs whatever set was showing.
		my $toggle_src = &icon_path($value, '/images/decipherable/' . $value . '.png');
		my $toggle_style = ($value eq 'on')
			? 'background-color:green;border-color:green;box-shadow:0 0 8px 2px green;'
			: 'background-color:#555555;border-color:#555555;opacity:0.45;filter:grayscale(1);';
		&Websocket::send('tab', { console => &Websocket::console_command('setToggle', $app, $value, $toggle_src, $toggle_style)});
		&subs::watch_toggle_pusher({ app => $app, value => $value, exclude_chip => $settings->{'source_chip_id'}, timestamp => $timestamp });
	}
	if ($setting eq 'site_type') {
		&subs::db_delete('cache', { context => 'navigation_information' });
	}

	if ($setting eq 'uuid') {
		my $s_old = &db_select('settings', undef, { app => $app, setting => $setting, device => $dev })->hashes->[0];
		if ($s_old->{'value'}) {
			return { app => $app, timestamp => $timestamp, setting => $setting, value => $s_old->{'value'}, device => $dev, browser_tab_id => $browser_tab_id };
		}
	}

	# A row is keyed by (app, setting, device, subsetting). The delete that clears the
	# previous row used '=', so an undef in ANY key column matched nothing (SQL
	# 'x = NULL' is never true): every write left its predecessor behind and cost/…
	# piled up duplicate rows (342 groups on one machine), and a window-state save
	# whose app was missing (the 'tab' frames push scrollTop/jopen with no app) kept
	# adding a fresh app-null row. 'is' is NULL-safe - two NULLs compare equal,
	# anything else as '=' - so every key column clears properly.
	my $old_set = eval { &db_query('delete from settings where app is ? and setting is ? and device is ? and subsetting is ?', $app, $setting, $dev, $subsetting) };
	# A row a panel writes is a choice, even when the value equals a born
	# default (navigation 'none' is the one that matters): mark it 'no' so the
	# merge lets it replace another machine's value. A born default is 'yes';
	# a row from an older build carries no mark and is judged by its value.
	my $seed = $settings->{'seed'};
	$seed = 'no' if !defined $seed && (($settings->{'source'} // '') eq 'panel');
	my $row = {
		app => $app,
		timestamp => $timestamp,
		setting => $setting,
		value => $value,
		server_time => $server_time,
		device => $dev,
		browser_tab_id => $browser_tab_id,
		uuid => $settings->{'uuid'} || &random_string_creator(25),
		subsetting => $subsetting
	};
	$row->{'seed'} = $seed if defined $seed;
	&db_insert('settings', $row);

	# A new spelling of the person's own name is a rename of the app their
	# records live under, not a second person.
	&person_name_rename($my_name_before, $value, { timestamp => $timestamp, source => 'panel' })
		if defined $my_name_before;
	if ($setting eq 'colour') {
		# the dark-theme face follows the colour it belongs to; a peer replay keeps
		# whatever dark_colour row arrives with its own snapshot instead
		my $dark_colour = &dark_colour_for($value);
		if (!$sync && defined $dark_colour && length $dark_colour) {
			my $old_dark = &setting_grabber({ app => $app, setting => 'dark_colour', device => $dev });
			unless (defined $old_dark && lc($dark_colour) eq lc($old_dark)) {
				&setting_setter({ app => $app, setting => 'dark_colour', value => $dark_colour, device => $dev, silent => 'yes', sync => $sync });
			}
		}
		unless ($settings->{'silent'} eq 'yes') {
			&Websocket::send('server', { console => &Websocket::console_command('jawnosApptColourSet', $app, $value, $dark_colour)}) unless $sync;
			# refresh the stored clothesline so the manager view picks up the new colour
			&hang_to_dry();
		}
	}
	elsif ($setting eq 'dark_colour') {
		unless ($settings->{'silent'} eq 'yes') {
			&Websocket::send('server', { console => &Websocket::console_command('jawnosApptDarkColourSet', $app, $value)}) unless $sync;
			&hang_to_dry();
		}
	}
	elsif ($setting eq 'icon_set') {
		# invalidate the shared caches across all workers
		&icon_set_forget();
		&cache_delete({ app => '__president', context => 'config' });
		&cache_delete({ app => 'me', context => 'pseudonyms' });
		&cache_delete({ context => 'template' });
		&cache_delete({ context => 'header' });
		&Websocket::send('server', { console => &Websocket::console_command('jawnosReloadIcons')}) unless $sync;
	}
	elsif ($setting eq 'manager_background_colour') {
		# the desktop's dark/light line moved, and with it which cut of the icon
		# set every render should ask for
		&icon_set_forget();
		&cache_delete({ app => '__president', context => 'config' });
		&cache_delete({ context => 'template' });
		&cache_delete({ context => 'header' });
		# every open manager on every machine repaints: the same bundle push a
		# theme change uses, so the paint, the icon cut and the surfaces cross
		# the line together instead of only the window that made the change
		&appointment_theme_push() unless $sync;
	}
	elsif ($setting eq 'appearance_theme') {
		# the whole dressing changed: paint, glyphs, cursor, material and face. Every
		# worker must forget its memo, and every open manager re-paints now.
		&icon_set_forget();
		&cache_delete({ app => '__president', context => 'config' });
		&cache_delete({ context => 'template' });
		&cache_delete({ context => 'header' });
		# A named theme carries its own corner. Picking one hands the corner back
		# to the theme: an explicit Misc override chosen under the last theme would
		# otherwise mask every theme's radius, so the gallery would look as if the
		# radii were all the same. The slider is free again, and Follow theme stops
		# being the only way back to the theme's own corner.
		if (!$sync && defined $value && length $value) {
			my %cleared;
			foreach my $corner_device ( $dev, &signatorial_designer() ) {
				next unless defined $corner_device && length $corner_device && !$cleared{$corner_device}++;
				my $stale = &setting_grabber({ app => 'misc', setting => 'corner_override', device => $corner_device });
				next unless defined $stale && length $stale;
				# sync marks this as a follow-on write: the push below carries the
				# effective corner once, not once per cleared row
				&setting_setter({
					app => 'misc', setting => 'corner_override', value => '',
					device => $corner_device, timestamp => $timestamp, sync => 1
				});
			}
		}
		&appointment_theme_push() unless $sync;
	}
	elsif ($setting eq 'icon_set_override' || $setting eq 'texture_override' || $setting eq 'corner_override' || $setting eq 'cursor_set_override' || $setting eq 'cursor_set' || $setting eq 'cursor_size') {
		# an explicit choice on top of the active theme: the effective icon set,
		# material, corner or cursor moved, so the memo, the rendered pages and
		# every open manager follow. The push carries the effective values, not
		# the theme's defaults. cursor_set is the same push for a desk with no
		# theme in charge, where the Misc choice is the effective one.
		&icon_set_forget();
		&cache_delete({ app => '__president', context => 'config' });
		&cache_delete({ context => 'template' });
		&cache_delete({ context => 'header' });
		&appointment_theme_push() unless $sync;
	}
	elsif ($setting eq 'ci') {
		# The panel's open circumstance is rendered into the centre view. The
		# template cache kept the closed panel (an empty ci) for its ten-day
		# warranty, so reopening a window never saw that the light was left open.
		&cache_delete({ app => $app, context => 'template' });
		&cache_delete({ app => $app, context => 'header' });
	}
	elsif ($setting eq 'tasks' && !$sync) {
		&subs::task_checker($app);
	}
	# these run after the new value is the one on record: the schedule is built
	# from what the settings say, not from what they said
	if (($setting eq 'nightly_evaluation_days' || $setting eq 'evaluation_cadence') && !$sync) {
		# the cadence or the days changed under a standing wish: the schedule follows
		&subs::evaluation_schedule_arrange($app) if $app;
	}
	if ($setting eq 'evaluation_machine' && !$sync) {
		# the machine changed: this queue follows right away, the other machines
		# when boot or their next settings sync brings them the change
		&subs::nightly_evaluation_reconcile();
	}
	if ($setting eq 'alarm' && !$sync && $app) {
		# the appointment panel's Alarm box: turning it on (or off) moves the app's
		# single automatic Clock alarm right away, without waiting for the next
		# appointment write
		eval { &clock_appointment_sync({ app => $app }); };
	}
	# A device's time zone is its own: the taskbar, the handheld and an evaluation
	# running on that machine read that device's row. Only the current machine's
	# row sets the operating system's clock, so picking the server's zone on a
	# laptop never moves the laptop. A peer replay is not a local pick; a refusal
	# (no root, no sudo -n) rides back to the caller so a page can say the box did
	# not change.
	my $zone_os;
	if (!$sync && ($setting // '') eq 'clock_timezone' && defined $value && length $value && $value ne 'local'
		&& (($dev // '') eq (&device_setter() // ''))) {
		$zone_os = eval { &subs::clock_zone_apply($value) };
	}
	return { app => $app, timestamp => $timestamp, setting => $setting, value => $value, device => $dev,
		browser_tab_id => $browser_tab_id, ($zone_os ? (timezone_os => $zone_os) : ()) };
}

sub setting_grabber {
	my $settings = shift;
	if ($settings->{'uuid'}) {
		my $s = &subs::db_select_simple('settings', undef, { value => $settings->{'uuid'}, setting => 'uuid', subsetting => $settings->{'subsetting'} })->hashes->[0];
		$settings->{'app'} = $s->{'app'};
	}

	# decode a byte-string name once, exactly as the write gate does: a caller
	# that hands the row back as bytes must find the character-keyed row, or its
	# read looks like a missing app and the automatic uuid below forks the app
	my $app = defined $settings->{'app'} ? &subs::text_chars($settings->{'app'}) : undef;
	# the query below is built from this hash, so carry the decoded form into it
	$settings->{'app'} = $app;
	my $device_defined = 0;
	$device_defined = 1 if $settings->{'device'};
	# A warranty is one value for the house, so ask the house row first. A legacy
	# per-device row is only the fallback, so a machine that has not been migrated
	# still answers with what it used to hold.
	my $warranty_house = (($settings->{'setting'} // '') eq 'warranty' && !$device_defined);
	# The Studio's pedalboard library is one library for the house, like a
	# warranty, so a read with no device of its own asks the house row.
	my $studio_house = (&studio_shared_setting($app, $settings->{'setting'}) && !$device_defined);
	my $machine = (!$device_defined && !$warranty_house && !$studio_house && &setting_app_is_machine($app));
	$settings->{'device'} = $settings->{'device'} || ($machine ? &setting_machine_device() : &device_setter());
	$settings->{'device'} = &warranty_device() if $warranty_house || $studio_house;
	my $returner;
	# benign and settings are parameters of this sub, not columns of the settings
	# table; riding into the where clause they made the select die with 'no such
	# column: "benign"', and the eval below swallowed the answer with it
	my $params = { %{$settings} };
	delete @{$params}{qw/benign settings/};
	# The first read after the upgrade has no machine row yet. Fall back to the
	# device-class row until one is written, so the window keeps what it showed
	# rather than snapping to an empty default. A row that exists with a blank
	# value is a real answer (an empty search), so only a missing row falls back.
	if ($machine && (($settings->{'device'} // '') ne (&device_setter() // ''))) {
		my $probe = eval { &db_select_simple('settings', ['value'], $params) };
		my $rows = $probe ? $probe->hashes : [];
		unless (scalar @{$rows}) {
			$settings->{'device'} = &device_setter();
			$params->{'device'} = &device_setter();
		}
	}

	# request-scoped memo: the same scalar answer is recomputed zero times per
	# request. A worker handles one request at a time, so this is private to it.
	# colour is excluded (a blank one is filled from the theme) and any settings
	# write flushes the whole memo.
	my $memo_key;
	if ($setting_memo_on && (($params->{'setting'} // '') ne 'colour')) {
		$memo_key = join "\x1f", $app // '', map { "$_=" . ($params->{$_} // '') } sort keys %{$params};
		return $setting_memo{$memo_key} if exists $setting_memo{$memo_key};
	}

	if (my $q = eval { return &db_select_simple('settings', ['value'], $params) }) {
		my $list = $q->hashes;

		if (scalar @{$list} > 1) {
			$returner = $list->[-1]->{'value'};
		}
		else {
			$returner = $list->[0]->{'value'};
		}
	}
	if (($warranty_house || $studio_house) && !(defined $returner && length $returner)) {
		# an older build stored these per device; read this device's row until
		# the house one has been written
		my $legacy_setting = $warranty_house ? 'warranty' : $settings->{'setting'};
		my $legacy = eval { &db_select_simple('settings', ['value'], { app => $app, setting => $legacy_setting, device => &device_setter() }) };
		if ($legacy) {
			my $rows = $legacy->hashes;
			$returner = $rows->[-1]->{'value'} if scalar @{$rows};
		}
	}
	if (defined $settings->{'setting'} && $settings->{'setting'} eq 'colour' && !$settings->{'benign'}) {
		# Only fill in a colour that was never set. Re-picking one that is already
		# there is what repainted every appointment whenever the theme changed;
		# the button in configure/misc_setting_list does that on purpose instead.
		$returner = &theme_colour_for_app($app, $returner, $settings->{'device'}) unless (length $returner);
	}
	$setting_memo{$memo_key} = $returner if defined $memo_key;
	return $returner;
}

# The tarot draw lists are one list for the house, stored on the settings row
# with device 'all'. A house from before that has only per-device rows: read this
# device's row until a draw writes the house one, so the old list carries over
# instead of disappearing. Names an early build escaped with terminal_name are
# unescaped here, where every reader meets them.
sub cards_list {
	my ($setting) = @_;
	return [] unless defined $setting && length $setting;
	my $raw = &setting_grabber({ app => 'cards', setting => $setting, device => &warranty_device() });
	if (!defined $raw || !length $raw) {
		$raw = &setting_grabber({ app => 'cards', setting => $setting });
	}
	return [] unless defined $raw && length $raw;
	my $list = eval { return decode_json $raw } || [];
	return [] unless ref $list eq 'ARRAY';
	foreach my $entry ( @{$list} ) {
		next unless ref $entry eq 'HASH';
		next unless ref $entry->{'cards'} eq 'ARRAY';
		$entry->{'cards'} = [ map { (my $name = $_) =~ s/\\(.)/$1/g; $name } @{$entry->{'cards'}} ];
	}
	return $list;
}

# A draw list is a house fact, so the write lands on the row every machine reads.
# The first write of a house that still has per-device rows seeds the house row
# from all of them, so no device's draws are lost when the list becomes one.
sub cards_list_write {
	my ($setting, $list) = @_;
	return unless defined $setting && length $setting && ref $list eq 'ARRAY';
	my $house_raw = &setting_grabber({ app => 'cards', setting => $setting, device => &warranty_device() });
	unless (defined $house_raw && length $house_raw) {
		$list = &cards_list_merge($setting, $list);
	}
	my $json = eval { return encode_json $list } || '[]';
	&setting_setter({ app => 'cards', setting => $setting, device => &warranty_device(), value => $json });
	return 1;
}

# One list from every device row for a setting: newest first, one copy of a
# draw, capped at the forty the app keeps.
sub cards_list_merge {
	my ($setting, $list) = @_;
	my @all = @{ ref $list eq 'ARRAY' ? $list : [] };
	my $rows = eval { return &db_select_simple('settings', ['value'], { app => 'cards', setting => $setting }) };
	if ($rows) {
		foreach my $row ( @{ $rows->hashes } ) {
			my $decoded = eval { return decode_json($row->{'value'}) } || [];
			push @all, @{$decoded} if ref $decoded eq 'ARRAY';
		}
	}
	my (%seen, @merged);
	foreach my $entry ( @all ) {
		next unless ref $entry eq 'HASH';
		if (ref $entry->{'cards'} eq 'ARRAY') {
			$entry->{'cards'} = [ map { (my $name = $_) =~ s/\\(.)/$1/g; $name } @{$entry->{'cards'}} ];
		}
		my $key = join '|', ($entry->{'timestamp'} // ''), ($entry->{'title'} // ''),
			join(',', @{ ref $entry->{'cards'} eq 'ARRAY' ? $entry->{'cards'} : [] });
		next if $seen{$key}++;
		push @merged, $entry;
	}
	@merged = sort { ($b->{'timestamp'} || 0) <=> ($a->{'timestamp'} || 0) } @merged;
	splice @merged, 40;
	return \@merged;
}

# A misc setting as this device should read it: this device's own row when it has
# one, then the person's own ("Me"), then nothing - the caller names the
# fallback. The configure panel's per-device blocks write the tab's row, so a
# value chosen under Me used to be invisible to the manager, which read the
# device's row alone and fell back to its defaults on every load. An explicit
# device may be named, for the panel asking after a tab that is not this one.
sub misc_setting {
	my $setting = shift;
	my $device = shift || &device_setter();
	my $value = &setting_grabber({ app => 'misc', setting => $setting, device => $device });
	unless (defined $value && length $value) {
		my $signatorial = &signatorial_designer();
		$value = &setting_grabber({ app => 'misc', setting => $setting, device => $signatorial }) if ($signatorial && $signatorial ne $device);
	}
	return $value;
}

# A misc setting that names a folder on this machine. The configure panel's Me
# tab writes the signatorial row, but the class row is shared by machines that
# are not alike - a laptop and a tablet are both 'computer' - and a recording,
# upload or studio take read from the class used to land in another machine's
# /sdcard path. Read this machine first, then the class it inherited.
sub misc_machine_setting {
	my $setting = shift;
	return undef unless defined $setting && length $setting;
	my $class = &device_setter();
	my $machine = &signatorial_designer();
	if (defined $machine && length $machine && $machine ne $class) {
		my $value = &setting_grabber({ app => 'misc', setting => $setting, device => $machine });
		return $value if defined $value && length $value;
	}
	return &setting_grabber({ app => 'misc', setting => $setting, device => $class });
}

# The desk's material as the layout and universal.css name it. 'plain' was the
# solid rounded pill's old internal value; it reads as 'round' now that Plain
# means the clothesline as it looked before the materials (internal 'classic').
sub texture_name {
	my $value = shift;
	unless (defined $value) {
		# A theme carries its own material. An explicit override chosen from the
		# Misc panel while the theme is active wins over it; the Misc Texture is
		# what a desk with no theme in charge wears.
		my $bundle = &active_theme_bundle();
		if ($bundle->{'slug'}) {
			my $override = &misc_setting('texture_override');
			if (defined $override && length $override && grep { $_ eq $override } @gb::textures) {
				$value = $override;
			}
			elsif (defined $bundle->{'texture'} && length $bundle->{'texture'}) {
				$value = $bundle->{'texture'};
			}
		}
		$value = &misc_setting('texture') unless defined $value && length $value;
	}
	$value = 'round' if defined $value && $value eq 'plain';
	$value = 'soft' unless defined $value && length $value;
	return $value;
}

# The desk's corner radius, in pixels. A theme carries its own corner; an
# explicit choice made from Misc while that theme is active (corner_override)
# wins over it, and with no theme in charge the Misc slider (corner_radius) is
# the value. It is held between 0 (square) and the 28px the theme editor allows,
# so no surface is rounded past its own middle. The layout seeds it as
# --corner_radius, which --jawnos-corner falls back to; every window, control
# and panel rounds by that property.
sub corner_radius {
	my $value;
	my $bundle = &active_theme_bundle();
	if ($bundle->{'slug'}) {
		my $override = &misc_setting('corner_override');
		if (defined $override && $override =~ /^\s*(\d{1,2})\s*(?:px)?\s*$/) {
			$value = $1 + 0;
		}
		elsif (defined $bundle->{'corner'} && $bundle->{'corner'} =~ /^\s*(\d{1,2})\s*(?:px)?\s*$/) {
			$value = $1 + 0;
		}
	}
	unless (defined $value) {
		my $misc = &misc_setting('corner_radius');
		if (defined $misc && $misc =~ /^\s*(\d{1,2})\s*(?:px)?\s*$/) {
			$value = $1 + 0;
		}
	}
	$value = 12 unless defined $value;
	$value = 0 if $value < 0;
	$value = 28 if $value > 28;
	return $value;
}

sub settings_grabber {
	my $settings = shift;
#	return {};

	if ($settings->{'uuid'}) {
		my $s = &subs::db_select_simple('settings', undef, { value => $settings->{'uuid'}, setting => 'uuid', subsetting => $settings->{'subsetting'} })->hashes->[0];
		$settings->{'app'} = $s->{'app'};
	}


	my $app = defined $settings->{'app'} ? &subs::text_chars($settings->{'app'}) : undef;
	my $device_defined = 0;
	$device_defined = 1 if $settings->{'device'};
	my $machine = (!$device_defined && &setting_app_is_machine($app));
	$settings->{'device'} = $settings->{'device'} || ($machine ? &setting_machine_device() : &device_setter());
#	$settings->{'device'} = $device unless $settings->{'device'} ne '';
	my $returner = { app => $app };

	my $fetch = sub {
		my ($device) = @_;
		my $query = 'select * from settings where app=? and device=?';
		my @args = ($app, $device);
		if ($settings->{'settings'}) {
			my @wanted = @{$settings->{'settings'}};
			return [] unless scalar @wanted;
			$query .= ' and ( ' . join(' or ', ('setting = ?') x scalar @wanted) . ' )';
			push @args, @wanted;
		}
		my $rows = &db_raw($query, @args) || [];
		if ($settings->{'subsetting'}) {
			@{$rows} = grep { (($_->{'subsetting'} // '') eq $settings->{'subsetting'}) } @{$rows};
		}
		return $rows;
	};
	my $list = $fetch->($settings->{'device'});
	# The machine's own row is the answer; the device-class row is what the
	# machine had before this rule and what an app born earlier still holds, so
	# it fills only the keys the machine has not written yet. A key the machine
	# does hold is never taken from the class - a peer's synced value must not
	# win here just because it is newer.
	if ($machine) {
		my $class = &device_setter();
		if (($settings->{'device'} // '') ne ($class // '')) {
			my %have = map { ($_->{'setting'} // '') => 1 } @{$list};
			foreach my $row ( @{ $fetch->($class) } ) {
				next if $have{$row->{'setting'} // ''}++;
				push @{$list}, $row;
			}
		}
	}
	foreach my $s ( @{$list } ) {
		next unless defined $s->{'setting'};
		$returner->{$s->{'setting'}} = $s->{'value'};
	}
	# The Studio's saved pedalboard library is one library for the house, stored
	# on the house row (device 'all'). However this machine's class row was read
	# above, the house row wins for this one key, so settings_grabber({app=>
	# 'studio'}) shows the same boards on every machine.
	if (!$device_defined && ($app // '') eq 'studio'
		&& (!$settings->{'settings'} || grep { $_ eq 'pedalboards' } @{$settings->{'settings'}})) {
		my $house = eval { &db_raw('select value from settings where app=? and device=? and setting=?', 'studio', &warranty_device(), 'pedalboards') };
		$returner->{'pedalboards'} = $house->[-1]->{'value'} if $house && scalar @{$house};
	}
	# A warranty is one value for the house (warranty_device): the house row wins
	# over this device's legacy one, so the Configure panel shows what every
	# machine will use.
	if (!$device_defined && (!$settings->{'settings'} || grep { $_ eq 'warranty' } @{$settings->{'settings'}})) {
		my $house = eval { &db_raw('select value from settings where app=? and device=? and setting=?', $app, &warranty_device(), 'warranty') };
		$returner->{'warranty'} = $house->[-1]->{'value'} if $house && scalar @{$house};
	}
	# (the old fallback here re-called $q->hashes, which is exhausted by then and
	# always empty - dead code; the loop above already set every fetched setting)
	unless ($returner->{'uuid'}) {
		if (($settings->{'benign'} || 0) != 1) {
			my $uuid = &random_string_creator(25);
			$returner->{'uuid'} = $uuid;
			&setting_setter({ app => $app, setting => 'uuid', subsetting => $settings->{'subsetting'}, value => $uuid });
		}
	}
	if (exists $returner->{'colour'} && !$settings->{'benign'}) {
		# a blank colour gets one; an existing colour is left alone so a theme
		# change does not repaint the appointments behind the user's back
		$returner->{'colour'} = &theme_colour_for_app($app, $returner->{'colour'}, $settings->{'device'}) unless (length $returner->{'colour'});
	}
	if (!$settings->{'benign'} && length($returner->{'colour'} || '')) {
		# colour is the light face and dark_colour the dark one. An app born on a
		# dark desktop stored that cut as its colour, so restore the pair here: a
		# light desk then paints the light step instead of a near-black plate.
		($returner->{'colour'}, $returner->{'dark_colour'}) = &appointment_colours($returner->{'colour'}, $returner->{'dark_colour'});
	}
	return $returner;
}

# Pinned window places in one read, for the press-time preview. A window with
# place=lock keeps the box saved in dimensions; windowPlaceRestore rescales it
# from the screen it was saved on (vw/vh). This reads the same row preference
# the window does: this machine's own row for a machine app, then its device
# class, then the person's own (Me/signatorial), then a house-wide ('all') row,
# then the newest row any device holds. The map is
# app -> { left, top, width, height, vw, vh }.
sub app_window_places {
	my $dev = &device_setter();
	my $sig = &signatorial_designer();
	my $machine = &setting_machine_device();
	# settings_grabber asks a machine app's own row first, then fills the keys
	# it has not written from the device class. The preview has to rank the
	# same way, or a Music place on one and its box on the other reads as two
	# unrelated rows and the press predicts a cascade while the window opens
	# at its anchor.
	my %rank_cache;
	my $rank_for = sub {
		my ($app) = @_;
		return $rank_cache{$app} if $rank_cache{$app};
		my %rank = ( 'all' => 2 );
		if (&setting_app_is_machine($app)) {
			$rank{$machine} = 4 if defined $machine && length $machine;
			$rank{$dev} = 3 if defined $dev && length $dev && $dev ne $machine;
		}
		else {
			$rank{$dev} = 4 if defined $dev && length $dev;
			$rank{$sig} = 3 if defined $sig && length $sig && $sig ne $dev;
		}
		$rank_cache{$app} = \%rank;
		return \%rank;
	};
	my %pick;
	my $rows = eval {
		&db_query("select app, device, setting, value, server_time from settings where setting in (?, ?) and value is not null and value != ''", 'place', 'dimensions')->hashes
	} || [];
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'};
		my $setting = $row->{'setting'};
		my $value = $row->{'value'};
		next unless defined $app && length $app && defined $value && length $value;
		next unless $setting eq 'place' || $setting eq 'dimensions';
		my $key = $app . "\0" . $setting;
		my $r = $rank_for->($app)->{ $row->{'device'} // '' } || 1;
		my $time = 0 + ($row->{'server_time'} // 0);
		my $seen = $pick{$key};
		if (!$seen || $r > $seen->{'rank'} || ($r == $seen->{'rank'} && $time >= $seen->{'time'})) {
			$pick{$key} = { rank => $r, time => $time, value => $value, device => ($row->{'device'} // '') };
		}
	}
	my %map;
	foreach my $key ( keys %pick ) {
		my ($app, $setting) = split /\0/, $key, 2;
		next unless $setting eq 'place';
		my $place = $pick{ $app . "\0" . 'place' };
		next unless $place && ($place->{'value'} // '') eq 'lock';
		my $dims = $pick{ $app . "\0" . 'dimensions' };
		next unless $dims && defined $dims->{'value'} && length $dims->{'value'};
		# A place and a box are one window's saved place when they name the
		# same device, or - for a machine app - when they are the machine's
		# row and the device-class row settings_grabber fills it with.
		my $place_dev = $place->{'device'} // '';
		my $dims_dev = $dims->{'device'} // '';
		my $paired = ($place_dev eq $dims_dev);
		if (!$paired && &setting_app_is_machine($app)) {
			my %pair;
			$pair{$machine} = 1 if defined $machine && length $machine;
			$pair{$dev} = 1 if defined $dev && length $dev;
			$paired = 1 if $pair{$place_dev} && $pair{$dims_dev};
		}
		next unless $paired;
		my $d = eval { &decode_json($dims->{'value'}) } || {};
		next unless ref $d eq 'HASH';
		my %box = ( left => 0, top => 0 );
		foreach my $k ( qw(left top width height vw vh) ) {
			next unless defined $d->{$k} && $d->{$k} =~ /^-?\d+(?:\.\d+)?$/;
			$box{$k} = 0 + $d->{$k};
		}
		next unless $box{'width'} > 0 && $box{'height'} > 0 && $box{'vw'} > 0 && $box{'vh'} > 0;
		$map{$app} = \%box;
	}
	return \%map;
}

sub setting_deleter {
	%setting_memo = ();
	my $setting = shift;
	# the same decode the write gate applies, so a byte-string caller deletes
	# the row its character string names instead of leaving it behind
	$setting->{'app'} = defined $setting->{'app'} ? &subs::text_chars($setting->{'app'}) : undef;
	$setting->{'setting'} = &subs::text_chars($setting->{'setting'}) if defined $setting->{'setting'};
	$setting->{'subsetting'} = &subs::text_chars($setting->{'subsetting'}) if defined $setting->{'subsetting'};
	$setting->{'device'} = $setting->{'device'} || &device_setter();
	$setting->{'device'} = &subs::text_chars($setting->{'device'}) if defined $setting->{'device'};
	# A settings row has no uuid, so a peer that still holds it can hand it back
	# on the next pull. Name the key in a tombstone. The moment is the delete,
	# not the row's own timestamp: a later write is a deliberate re-add and must
	# be allowed to land. Only a row that was really here gets a tombstone, or
	# applying a peer's tombstone would write a fresh one on every pass.
	my $server_time = $setting->{'server_time'} || &subs::rightNow();
	my $named = defined $setting->{'app'} && defined $setting->{'setting'};
	if ($setting->{'subsetting'}) {
		my %key = (app => $setting->{'app'}, setting => $setting->{'setting'}, subsetting => $setting->{'subsetting'}, device => $setting->{'device'});
		my $existed = eval { scalar @{ &db_select('settings', ['uuid'], \%key)->hashes || [] } } || 0;
		&db_delete('settings', \%key);
		&subs::deletion_registration({ table => 'settings', %key, server_time => $server_time }) if $named && $existed;
	}
	else {
		my %key = (app => $setting->{'app'}, setting => $setting->{'setting'}, device => $setting->{'device'});
		my $existed = eval { scalar @{ &db_select('settings', ['uuid'], \%key)->hashes || [] } } || 0;
		&db_delete('settings', \%key);
		&subs::deletion_registration({ table => 'settings', %key, server_time => $server_time }) if $named && $existed;
	}
	return $setting;
}

# The house's mark is stored as a whole data: URI in settings (the upload writes
# the URI, not a file). Pages used to inline that value into a <link rel=icon>,
# so every manager document carried the image before any markup - 195 KB of a
# 265 KB page, and base64 of a PNG compresses poorly. The favicon route is now
# the one reader; a page only names its URL.
sub logo_data_uri {
	my $q = eval { &db_query("select value from settings where app = 'me' and setting = 'logo' and value is not null and value != '' order by server_time desc limit 1") };
	return undef unless $q;
	my $row = $q->hashes->[0];
	return (ref $row eq 'HASH' && defined $row->{'value'} && length $row->{'value'}) ? $row->{'value'} : undef;
}

# A data: URI split into its media type and bytes. The stored logo is written
# with the prefix, so the route answers with both the content type and the file.
sub data_uri_parts {
	my ($uri) = @_;
	return undef unless defined $uri && $uri =~ /^data:([A-Za-z0-9.+\/-]+);base64,(.*)$/s;
	my ($mime, $b64) = ($1, $2);
	$b64 =~ s/\s+//g;
	my $bytes = eval { decode_base64($b64) };
	return undef unless defined $bytes && length $bytes;
	return { mime => $mime, bytes => $bytes };
}

# Apps whose stored name is a repetition or a mojibake cascade are not names a
# person can use: the keys reach hundreds of kilobytes and every settings index
# carries them. Hiding one under a short __orphan_ key keeps the rows (and the
# app's uuid/values) and is an ordinary update the sync rail carries, unlike a
# delete which a peer could hand back. The start menu already hides every app
# whose key starts with two underscores, so no page has to learn a new rule.
sub settings_orphan_plan {
	my ($apps) = @_;
	my @apps = grep { defined } @{ $apps || [] };
	my %taken = map { $_ => 1 } @apps;
	my @rename;
	for my $app (@apps) {
		next if $app =~ /^__orphan_/;
		my $corrupt = &name_overlong($app);
		unless ($corrupt) {
			# A byte string's mojibake shows as C3 83/C3 82/C3 A2 (the second
			# encoding of the mark); a character string shows as the visible
			# letters. A clean typographic apostrophe is E2 80 99 and is not
			# caught by either test.
			$corrupt = utf8::is_utf8($app)
				? ($app =~ /[\x{00C3}\x{00C2}\x{00E2}]/ ? 1 : 0)
				: ($app =~ /\xC3[\x83\x82\xA2]/ ? 1 : 0);
		}
		next unless $corrupt;
		my $base = '__orphan_' . substr(sha256_hex($app), 0, 12);
		my $new = $base;
		my $n = 2;
		$new = $base . '_' . $n++ while $taken{$new};
		$taken{$new} = 1;
		push @rename, { from => $app, to => $new, length => length($app) };
	}
	return { rename => \@rename, count => scalar @rename };
}

# A relational membership array (sc_<construct>) names other apps by their uuid
# rows. It is a set, not a log: the relational window resolves each uuid back to
# an app, so a uuid that names nothing - or the app's own uuid - draws nothing.
# Two write paths used to push without a guard, and a list that already held a
# uuid grew by one copy on every construct change; one coffee row carried 8,192
# copies of its own uuid. Keep the first appearance of each drawable uuid.
#
# $known is a uuid => app map from the caller's own view of the house. It is
# optional: the runtime write paths pass none (an unknown uuid may be a peer's
# app not yet seen here), while the migration passes it to drop dangling names.
sub sc_list_clean {
	my ($list, $self_uuid, $known) = @_;
	$list = [] unless ref $list eq 'ARRAY';
	my (@out, %seen);
	foreach my $uuid ( @{$list} ) {
		next unless defined $uuid && length $uuid;
		next if $uuid eq 'all';
		next if defined $self_uuid && length $self_uuid && $uuid eq $self_uuid;
		next if $seen{$uuid}++;
		next if $known && !$known->{$uuid};
		push @out, $uuid;
	}
	return \@out;
}

# The machine's own hostname, from the platform seam: one memoised read of the
# kernel nodename, no process per page. Kept as a domain name because the manager
# and every app already ask for it here.
sub machine_hostname {
	require JawnOS::Platform::Net;
	return JawnOS::Platform::Net::hostname();
}

1;
