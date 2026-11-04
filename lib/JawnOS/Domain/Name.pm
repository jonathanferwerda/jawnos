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

sub setting_setter {
	%setting_memo = ();
	my $settings = shift;
	# a visibility or relationship change is read back by the same request
	&visibility_cache_clear() if (($settings->{'setting'} // '') =~ /^(?:visible|app_measures)$/);
	# a language change must be seen by the next page in this same worker
	&language_reset() if (($settings->{'setting'} // '') eq 'language');
	my $app = $settings->{'app'};
	my $original_app = $app;
	my $setting = $settings->{'setting'};
	my $subsetting = $settings->{'subsetting'};
	my $value = $settings->{'value'};
	my $timestamp = $settings->{'timestamp'} || &rightNow();
	my $browser_tab_id = $settings->{'browser_tab_id'};
	my $dev = $settings->{'device'} || &device_setter();
	# A row arriving from a peer's snapshot is a mirror of a change that already
	# happened somewhere else. It must be written, but its side effects - a
	# websocket reload, a BLE toggle push, a task re-registration, a name-change
	# broadcast that opens the app window - belong to the machine where the
	# person made the change. Replaying them here is what opened Libro Chequing
	# on every machine and flipped jobs off during a merge.
	my $sync = $settings->{'sync'} ? 1 : 0;
	# A warranty is one value for the house (warranty_device), so a local write
	# lands on the house row every machine reads. A peer replay keeps the device
	# it arrived with, so an older build's per-device row cannot take the house
	# value over.
	$dev = &warranty_device() if !$sync && (($setting // '') eq 'warranty');
	my ($db,$database) = &database_grabber();
	my $server_time = $settings->{'server_time'} || &rightNow();
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
		my $tables = `sqlite3 $database .tables`;
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
			&Websocket::send('server', { console => '$(".' . &subs::html_name($app) . '_close_button").trigger("click");', timestamp => $timestamp });
			&Websocket::send('server', { console => 'appointmentGrabber(\'' . $value . '\',\'' . $timestamp .'\',\'ws\');'});
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
		&Websocket::send('tab', { console => 'configurationReloader(\'' . $app . '\');' });
	}
	if ($setting eq 'phone') {
		$value =~ s/\D+//gi;
	}
	if ($setting eq 'web' && !$sync) {
		if ($value =~ /[0-9A-Za-z]/) {
			&Websocket::send('server', { console => '$(\'.app_act[app="' . $app . '"][type="web"]\').attr(\'web\', \'' . $value . '\').show();' });
		}
		else {
			&Websocket::send('server', { console => '$(\'.app_act[app="' . $app . '"][type="web"]\').attr(\'web\', \'\').hide();' });
		}
	}
	if ($setting eq 'colour' || $setting eq 'name_change' || $setting eq 'mab') {
		# The Relational board reads the settings rows directly; there is no
		# rendered bucket to drop here any more.
	}
	if ($setting eq 'toggle' && $settings->{'source'} eq 'panel' && !$sync) {
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
		&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.enabler[type="toggle"\').attr(\'status\',\'' . $value . '\').attr(\'src\', \'' . $toggle_src . '\').attr(\'style\', \'' . $toggle_style . '\');' });
		&subs::watch_toggle_pusher({ app => $app, value => $value, exclude_chip => $settings->{'source_chip_id'} });
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
	&db_insert('settings', {
		app => $app,
		timestamp => $timestamp,
		setting => $setting,
		value => $value,
		server_time => $server_time,
		device => $dev,
		browser_tab_id => $browser_tab_id,
		uuid => $settings->{'uuid'} || &random_string_creator(25),
		subsetting => $subsetting
	});
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
			&Websocket::send('server', { console => 'jawnosApptColourSet(' . encode_json($app) . ',' . encode_json($value) . ',' . encode_json($dark_colour) . ');' }) unless $sync;
			# refresh the stored clothesline so the manager view picks up the new colour
			&hang_to_dry();
		}
	}
	elsif ($setting eq 'dark_colour') {
		unless ($settings->{'silent'} eq 'yes') {
			&Websocket::send('server', { console => 'jawnosApptDarkColourSet(' . encode_json($app) . ',' . encode_json($value) . ');' }) unless $sync;
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
		&Websocket::send('server', { console => 'jawnosReloadIcons();' }) unless $sync;
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
		# the whole dressing changed: paint, glyphs, material and face. Every
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
	elsif ($setting eq 'icon_set_override' || $setting eq 'texture_override' || $setting eq 'corner_override') {
		# an explicit choice on top of the active theme: the effective set,
		# material or corner moved, so the memo, the rendered pages and every open
		# manager follow. The push carries the effective values, not the theme's
		# defaults.
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
	return { app => $app, timestamp => $timestamp, setting => $setting, value => $value, device => $dev, browser_tab_id => $browser_tab_id };
}

sub setting_grabber {
	my $settings = shift;
	if ($settings->{'uuid'}) {
		my $s = &subs::db_select_simple('settings', undef, { value => $settings->{'uuid'}, setting => 'uuid', subsetting => $settings->{'subsetting'} })->hashes->[0];
		$settings->{'app'} = $s->{'app'};
	}

	my $app = $settings->{'app'};
	my $device_defined = 0;
	$device_defined = 1 if $settings->{'device'};
	$settings->{'device'} = $settings->{'device'} || &device_setter();
	# A warranty is one value for the house, so ask the house row first. A legacy
	# per-device row is only the fallback, so a machine that has not been migrated
	# still answers with what it used to hold.
	my $warranty_house = (($settings->{'setting'} // '') eq 'warranty' && !$device_defined);
	$settings->{'device'} = &warranty_device() if $warranty_house;
	my $returner;
	# benign and settings are parameters of this sub, not columns of the settings
	# table; riding into the where clause they made the select die with 'no such
	# column: "benign"', and the eval below swallowed the answer with it
	my $params = { %{$settings} };
	delete @{$params}{qw/benign settings/};

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
	if ($warranty_house && !(defined $returner && length $returner)) {
		# an older build stored a warranty per device; read this device's row
		# until the backfill has written the house one
		my $legacy = eval { &db_select_simple('settings', ['value'], { app => $app, setting => 'warranty', device => &device_setter() }) };
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


	my $app = $settings->{'app'};
	my $device_defined = 0;
	$device_defined = 1 if $settings->{'device'};
	$settings->{'device'} = $settings->{'device'} || &device_setter();
#	$settings->{'device'} = $device unless $settings->{'device'} ne '';
	my $returner = { app => $app };

	my $query = 'select * from settings where app=? and device=?';
	my $q;
	if ($settings->{'settings'}) {
		if (scalar @{$settings->{'settings'}}) {

			my $query = 'select * from settings where app=? and device=? and ( ';
			for (my $n = 0; $n <= scalar @{$settings->{'settings'}}; $n++) {
				if ($n == scalar @{$settings->{'settings'}}) {
					$query .= ' setting = ? ';
				} else {
					$query .= ' setting = ? or ';
				}

			}
			$query .= ')';
			$q = &db_raw($query, $app,$settings->{'device'}, @{$settings->{'settings'}});
		}
	}
	else {
		$q = &db_raw($query, $app,$settings->{'device'});
	}
	my $list = $q;
	if ($settings->{'subsetting'}) {
		@{$list} = grep { $_->{'subsetting'} eq $settings->{'subsetting'} } @{$list};
	}
	foreach my $s ( @{$list } ) {
		$returner->{$s->{'setting'}} = $s->{'value'};
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

sub setting_deleter {
	%setting_memo = ();
	my $setting = shift;
	$setting->{'device'} = $setting->{'device'} || &device_setter();
	if ($setting->{'subsetting'}) {
	#	&subs::deletion_registration({ table => 'settings', app => $setting->{'app'}, setting => $setting->{'setting'}, server_time => $setting->{'server_time'}, subsetting => $setting->{'subsetting'} });
		&db_delete('settings', { app => $setting->{'app'}, setting => $setting->{'setting'}, subsetting => $setting->{'subsetting'}, device => $setting->{'device'} });
	}
	else {
	#	&subs::deletion_registration({ table => 'settings', app => $setting->{'app'}, setting => $setting->{'setting'} });
		&db_delete('settings',{ app => $setting->{'app'}, setting => $setting->{'setting'}, device => $setting->{'device'} });
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
		my $corrupt = length($app) > 100 ? 1 : 0;
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

# The machine's own hostname without spawning `hostname` for every page. The
# value cannot change while the process lives, and the manager page asks for it
# on each render (here and in its own action).
our $hostname_memo;
sub machine_hostname {
	return $hostname_memo if defined $hostname_memo;
	require Sys::Hostname;
	$hostname_memo = eval { Sys::Hostname::hostname() };
	$hostname_memo = '' unless defined $hostname_memo;
	return $hostname_memo;
}

1;
