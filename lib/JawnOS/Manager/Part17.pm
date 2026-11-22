package Manager;

# Manager helpers, part 17 of 37. Moved out of Manager.pl so a
# helper can be read and changed without opening 24k lines. The package is
# still Manager, and lib/JawnOS/Manager/Index.pm maps every sub name here to
# this file; Manager.pm loads it on the first call.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use Mojo::Promise;
use Mojo::UserAgent;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Clone qw(clone);
use Mojolicious::Static;
use Mojo::Log;
use Mojo::Transaction::WebSocket;
use Mojo::Parameters;
use Mojo::DOM;
use Mojo::URL;
use Mojo::JSON qw(decode_json encode_json);
use URI::Encode qw(uri_encode uri_decode);
use List::Util qw(shuffle);
use Data::Dumper;
use Mojo::Util qw/md5_sum html_unescape xml_escape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use File::Find;
use File::Slurp;
use File::Type;
use File::Copy;
use POSIX ();
use Fcntl qw(:flock O_CREAT O_EXCL O_WRONLY);
use Number::Format qw/:subs/;
use SQL::Abstract;
use Mojo::SQLite;
use Mojo::IOLoop;

use Mojolicious::Sessions;
use Mojo::Server::Daemon;
use Mojolicious::Renderer;
use Crypt::Simple;
use CryptX;
use HTML::Strip;
use HTML::Parser;
use Data::UUID;
use Storable;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use MIME::Base64;
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
use Minion;
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

sub database_vacuum_bag() {
	# An app belongs in the bag when its settings are still here but no
	# appointment names it. The house apps and the built-in apps are not
	# orphans: they live on without an appointment, so their settings must not
	# be offered. A row with no app name is not an app; the settings prune
	# (scripts/settings_prune.pl) owns those.
	my %protected = map { $_ => 1 } @gb::protected;
	$protected{$_} = 1 for keys %{ $gb::known_appts || {} };
	my $settings = &subs::db_query('select distinct(app) from settings where setting != ?', 'uuid')->hashes || [];
	my $appts = &subs::db_query('select distinct(app) from appointments')->hashes || [];
	# Names are stored as the bytes the app was given; the browser and the JSON
	# round trip speak characters. Decode here, so an accented or apostrophised
	# name comes back from the checkbox as the row it names.
	my %has_appt = map {
		(defined $_->{'app'} && length $_->{'app'}) ? (&subs::text_chars($_->{'app'}) => 1) : ()
	} @{$appts};
	# A card ticked Permanent is a promise that its settings outlive the last
	# appointment, so it is not an orphan to offer here either.
	my %permanent = map {
		(defined $_->{'app'} && length $_->{'app'}) ? (&subs::text_chars($_->{'app'}) => 1) : ()
	} @{ &subs::db_query(q{select distinct app from settings where setting = 'permanent' and value = 'checked'})->hashes || [] };
	my (%seen, @unique_settings);
	foreach my $s ( @{$settings} ) {
		my $app = defined $s->{'app'} ? &subs::text_chars($s->{'app'}) : undef;
		next unless defined $app && length $app;
		next if $protected{$app} || $permanent{$app} || $has_appt{$app} || $seen{$app}++;
		push @unique_settings, $app;
	}
	return sort @unique_settings;
}

# Merge one table's rows into the live database. The row source is a closure so the
# encrypted-snapshot path (rowid batches from a temp SQLite) and the row-stream path
# share every table-specific rule: uuid upsert, protected settings, utility
# controller keys, window state, continent temporary rows, file mirrors, deletions.
# The body keeps its original `next` statements: a one-pass ROW label makes a row's
# `next` leave just that row, while a `next` inside a nested loop still binds to it.
sub merge_table_rows {
	my ($ctx, $q, $next_row, $results_size, $count, $table_total, $expected) = @_;
	my $configuration = $ctx->{'configuration'};
	my $misc_settings = $ctx->{'misc_settings'};
	my $device = $ctx->{'device'};
	my $deletions = $ctx->{'deletions'};
	# A row this machine deleted stays deleted even when a stale peer still
	# carries it. The peer's own list covers the first minute, but a machine
	# that only serves (and never pulls) keeps sending the old row forever; the
	# durable tombstone in sync_log is what makes the local deletion final. A
	# `single` tombstone drops the whole row; a `file` tombstone removes just
	# the named attachment, so an appointment with surviving photos stays.
	my (%tombstone_single, %tombstone_file);
	# Every uuid-keyed table honours a durable `single` tombstone, not only the two
	# that carry attachments. A catalogue row deleted by Configure used to be
	# handed back by whichever peer still held it, because the merge only read
	# tombstones for appointments and mailbox: the deleted model or option then
	# reappeared (and with it a second default). `file` tombstones still belong to
	# the tables that have attachments.
	foreach my $tomb ( @{ &subs::db_query('select uuid, scope, additional from sync_log where tbl = ?', $q)->hashes || [] } ) {
		my $scope = $tomb->{'scope'} || '';
		next unless defined $tomb->{'uuid'} && length $tomb->{'uuid'};
		if ($scope eq 'single') { $tombstone_single{$tomb->{'uuid'}} = 1; }
		elsif ($scope eq 'file' && ($q eq 'appointments' || $q eq 'mailbox')) {
			my $extra = eval { return decode_json $tomb->{'additional'} } || {};
			$tombstone_file{$tomb->{'uuid'}}->{$extra->{'file_uuid'}} = 1 if $extra->{'file_uuid'};
		}
	}
	# Settings have no uuid, so their tombstones are keyed by (app, setting,
	# subsetting, device). Take the durable local log and the queued deletions a
	# peer handed us; the index is built once for the whole table.
	my $settings_deletions = {};
	if ($q eq 'settings') {
		$settings_deletions = &subs::settings_deletion_index([
			@{ &subs::db_query('select tbl, app, additional, server_time from sync_log where tbl = ?', $q)->hashes || [] },
			@{ [ grep { ref $_ eq 'HASH' && (($_->{'table'} || '') eq 'settings') } @{$deletions} ] },
		]);
	}
	my $universal_settings = $ctx->{'universal_settings'};
	my $updateables = $ctx->{'updateables'};
	my $sync_job = $ctx->{'sync_job'};
	my $auuid = $ctx->{'auuid'};
	my $colour = $ctx->{'colour'};
	my $merge_short = 0;
	my %toggle_changed;
	# One line per app is enough to explain a kept setting; a machine that
	# joined with an empty settings table carries the whole born bundle.
	my %kept_default;
	# A peer on newer code can carry a column this database has not been migrated for.
	# The insert then fails ("table X has no column named Y") and the same batch is
	# pulled again on every tick - the column equivalent of the unknown-table skip in
	# sync_rows_pull. Drop the columns this table does not have; `uuid` always stays
	# because it names the row.
	my %local_columns = map { $_->{'name'} => 1 } @{ &subs::db_query('select name from pragma_table_info(?)', $q)->hashes || [] };
	my %skewed_columns;
						if ($sync_job) {
							my $shown = $expected || $results_size;
							my %step = (label => 'merge ' . $q, state => 'running', current => 0);
							$step{'total'} = $shown if $shown;
							$step{'note'} = $shown . ' row' . ($shown == 1 ? '' : 's') if $shown;
							&subs::sync_job_step($sync_job, 'merge:' . $q, \%step);
						}
						#&subs::say_it('Now merging ' . $results . ' ' .$q);
						my $progress = $count / $table_total * 100;
						my $html = '<h3>Now merging ' . ($expected || $results_size) . ' ' . $q . '</h3><br>';
						&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour,
							progress => int($count / (($table_total) || 1) * 100), state => 'running' });
						my $percentage = 0;
						my $last_percent = 0;
						my $last_alert = &subs::rightNow();
						my $job_alert = $last_alert;
						my $start_time = $last_alert;
						# Book-keeping for the audit trail: a table can report "N/N done"
						# while an insert silently failed inside the eval below. Count what
						# the snapshot held, what the cursor actually yielded, and what
						# landed, so a short merge names itself in the log instead of
						# looking complete.
						my $rows_read = 0;
						my $rows_inserted = 0;
						my $rows_updated = 0;
						my @insert_errors;
						# Read the snapshot in bounded batches instead of holding one cursor
						# across the loop. Every row does app-database work (select, insert,
						# sync_job writes); if any of those finishes the snapshot's statement
						# - which is what the log showed: every table read exactly one row,
						# the rest silently lost - a materialised batch is immune. It also
						# keeps a whole table's rows out of memory.
	my $merge_one = sub {
		my ($r, $n) = @_;
		ROW: for my $once (1) {
			if (%local_columns && ref $r eq 'HASH') {
				my @unknown = grep { $_ ne 'uuid' && !$local_columns{$_} } keys %{$r};
				if (@unknown) {
					delete @{$r}{@unknown};
					$skewed_columns{$_} = 1 for @unknown;
				}
			}
							my @resulters = @{&subs::db_select($q, undef, { uuid => $r->{'uuid'} })->hashes};
							my $h = $resulters[0];
							# A document number only ever moves forward. The hub is the only
							# writer of next_number, but a peer's copy can still be older than
							# ours (or arrive after a restore); taking the larger value means a
							# number the hub already issued is never issued again. A plain
							# newer-wins upsert would let 1005 overwrite 1012.
							if ($q eq 'numbering') {
								my $peer_next = ($r->{'next_number'} // 0) + 0;
								my $local_next = ($h && defined $h->{'next_number'}) ? $h->{'next_number'} + 0 : 0;
								if ($peer_next > $local_next) {
									my $now = &subs::rightNow();
									if ($h) {
										&subs::db_update('numbering', { next_number => $peer_next, server_time => $now, timestamp => $now }, { uuid => $r->{'uuid'} });
										$rows_updated++;
									}
									else {
										&subs::db_insert('numbering', $r);
										$rows_inserted++;
									}
								}
								next ROW;
							}
							next ROW if $tombstone_single{$r->{'uuid'} // ''};
							# A v3 row stream has no snapshot size (`$results_size` is 0), so
							# the map's expected count (or the first batch's total) is the
							# only honest denominator. Leaving the percentage at zero also
							# suppressed every progress frame: the yellow dot got one frame
							# per table and then hid after its 20 s while the merge ran on
							# for minutes (the start menu's polling card kept showing it).
							my $shown_total = $results_size || $expected || 0;
							$percentage = $shown_total ? sprintf("%.2f", $n / $shown_total * 100) : 0;
							if ($sync_job && &subs::rightNow() >= ($job_alert + 250)) {
								my %progress = (current => $n);
								# Keep the total the map or first batch named instead of
								# overwriting it with zero.
								$progress{'total'} = $shown_total if $shown_total;
								&subs::sync_job_step($sync_job, 'merge:' . $q, \%progress);
								$job_alert = &subs::rightNow();
							}
							# Not every synced table has a `timestamp` column: `people` does not,
							# and gating the whole write path on it read every people row, reported
							# the table merged and silently dropped them (2026-11-05). The sync
							# requires `server_time`, not `timestamp`, so merge unconditionally.
							if (1) {
								if ($percentage >= $last_percent && $shown_total > 1 && &subs::rightNow() >= ($last_alert + 250)) {
									my $speed = abs sprintf("%.2f", $n / ($start_time - &subs::rightNow()) * 1000);
									my $remaining = ($percentage > 0)
										? &subs::duration_sayer(((&subs::rightNow() - $start_time) / $percentage) * (100 - $percentage) / 1000)
										: '';
									my $html = '<b style="font-size:20px">' . $n . ' / ' . $shown_total . ' ' . &subs::format_name($q) . ' ' . $percentage . '% @ ' . $speed . '/sec ' . $remaining . '</b><br>' .
										'<progress style="width:70%;height:60px;" value="' . $n . '" max="' . $shown_total . '"></progress>';
									$last_percent = $percentage;
									$last_alert = &subs::rightNow();
									# The ring is the whole pull, not this table: without
									# this frame the dot would look stuck at the table's
									# start while the rows moved.
									my $overall = $table_total
										? int((($count - 1) + ($shown_total ? $n / $shown_total : 0)) / $table_total * 100)
										: -1;
									$overall = 100 if $overall > 100;
									&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour, progress => $overall, state => 'running' });
								}
								if ($q eq 'websites') {
									&web_history_deleter($r->{'app'});
								}
								if ($q eq 'continent') {
									if ($r->{'type'} eq 'temporary' && $r->{'app'} eq '__president') {
										# A local row AT LEAST this new wins. The sync copies server_time
										# verbatim, so a peer echoes our own temporary row back with the
										# very same stamp; the old strict `>` did not count that as newer,
										# so it deleted the fresh row and then the generic merge below
										# skipped the re-insert (its @resulters still held the deleted
										# row, and server_time was not greater). A phone's own fix then
										# vanished seconds after every navigation run and it borrowed a
										# peer's place instead - the public place that only a manual
										# fix corrected. `>=` keeps the row we hold.
										my $continents = &subs::db_query('select * from continent where app = ? and type = ? and signatorial = ? and cast(server_time as integer) >= cast(? as integer)', $r->{'app'}, $r->{'type'}, $r->{'signatorial'}, $r->{'server_time'})->hashes;
										if (scalar @{$continents} > 0) {
											next;
										}
										# The incoming row is genuinely newer: keep one temporary row per
										# signatorial by dropping our older copies, but never the row the
										# merge is about to write (its uuid is in @resulters above; only
										# the insert/update at the foot of this block can put it back).
										my $older = &subs::db_query('select uuid from continent where app = ? and type = ? and signatorial = ? and uuid != ?', $r->{'app'}, $r->{'type'}, $r->{'signatorial'}, ($r->{'uuid'} || ''))->hashes;
										foreach my $old ( @{$older} ) {
											&subs::db_delete('continent', { uuid => $old->{'uuid'} });
										}
									}
								}
								if ($q eq 'settings') {
									# A peer behind a pre-unicode SQLite handle sends the name as bytes.
									# The time check below must compare the same characters the row is
									# keyed by, or it never matches and a stale peer value is written
									# over the newer one we hold.
									$r->{'app'} = &subs::text_chars($r->{'app'}) if defined $r->{'app'};
									# The row names its identity by key, not uuid, so the uuid gate at
									# the bottom cannot see it. A tombstone at or after this row's own
									# server_time holds it back; a newer row is a deliberate re-add and
									# still lands.
									next if &subs::settings_deletion_blocks($r, $settings_deletions);
									# Window/tab state is the machine's own view, not a setting: a
									# peer's snapshot must never open or move a window here.
									if (($r->{'setting'} || '') =~ /^(?:open_tabs|scrollTop|jopen|dimensions)$/) { next; }
									# The utility controller keeps every machine's jobs in one blob keyed
									# by that machine's signatorial. The generic whole-row replace below
									# would let whichever peer synced last win outright, wiping the other
									# machines' keys (their runtimes then reseed to the built-in
									# defaults - the "jobs all turned off" that started this). Merge the
									# blob per key instead: union the keys, and for a key both sides
									# hold keep the one whose __settings.last_change is newer (ours is
									# always authoritative for our own signatorial).
									if (($r->{'setting'} || '') eq 'utility_controller' && ($r->{'app'} || '') eq '__president') {
										my $sig = &subs::signatorial_designer();
										my %device_key = map { $_ => 1 } @gb::device_types;
										my $local = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'utility_controller', benign => 1 }) } || {};
										my $theirs = eval { decode_json $r->{'value'} } || {};
										my $merged = {};
										foreach my $k ( keys %{$local} ) { $merged->{$k} = $local->{$k}; }
										foreach my $k ( keys %{$theirs} ) {
											# our own row and the vestigial device-type rows are never taken from
											# a peer: our row is authoritative (the runtime reads only it, keyed
											# by our signatorial), and a device-type row must not be resurrected
											# once pruned. Only other machines' rows merge by last_change.
											next if $k eq $sig || $device_key{$k};
											if (!$merged->{$k}) { $merged->{$k} = $theirs->{$k}; next; }
											my $la = $merged->{$k}->{'__settings'}->{'last_change'} || 0;
											my $lb = $theirs->{$k}->{'__settings'}->{'last_change'} || 0;
											$merged->{$k} = $theirs->{$k} if $lb > $la;
										}
										my $jmerged = encode_json $merged;
										my $jcur = encode_json $local;
										if ($jmerged ne $jcur) {
											# name any navigation toggle this merge is about to change, per row -
											# a third machine's stale copy must not read a job off unnoticed
											foreach my $k ( keys %{$merged} ) {
												my $was = $local->{$k}->{'navigation'}->{'toggle'} // '-';
												my $now = $merged->{$k}->{'navigation'}->{'toggle'} // '-';
												&subs::log_writer('utility merge: ' . substr($k, 0, 8) . ' navigation ' . $was . '->' . $now . ' from ' . substr($r->{'signatorial'} // '?', 0, 8)) if $was ne $now;
											}
											&subs::setting_setter({ app => '__president', setting => 'utility_controller', value => $jmerged, server_time => &subs::rightNow(), sync => 1 });
										}
										next;
									}
									$universal_settings->{$r->{'app'}} = &subs::settings_grabber({ app => $r->{'app'}, device => $device, benign => 1 }) unless $universal_settings->{$r->{'app'}};
									my $protected = 0;
									foreach my $pr ( @gb::protected ) {
										if ($r->{'app'} eq $pr) {
											$protected = 1;
										}
									}
									# `cards` is protected because its banks and file-browser state are
									# per-device, but the tarot mode/variant and the draw lists are house
									# facts the person expects on every device. Let only those named rows
									# through; every other cards setting stays local, as does every other
									# protected app (`__president` and `utility_controller` included).
									my $cards_setting = (($r->{'app'} // '') eq 'cards') ? ($r->{'setting'} // '') : '';
									my $cards_shared = $cards_setting =~ /^(?:mode|variant|day|week|month|year|free|cycle|spread|all)$/ ? 1 : 0;
									# The clothesline is one line for the House. Its rail, head switches
									# and every app's hang are written on the house row; let those
									# through even though `__president` is protected, while the rest of
									# `__president` stays local.
									my $clothesline_shared = ((($r->{'setting'} // '') eq 'clothesline'
										|| ($r->{'setting'} // '') eq 'clothesline_anticipatory')
										&& ($r->{'device'} // '') eq 'all') ? 1 : 0;
									# A draw list lives on the house row (`device = 'all'`); keep it one on
									# arrival so cards_list reads it. Mode and variant are per-device and
									# join this device's class as usual.
									my $house_wide = ($clothesline_shared || ($cards_shared && $cards_setting =~ /^(?:day|week|month|year|free|cycle|spread|all)$/
										&& ($r->{'device'} // '') eq 'all')) ? 1 : 0;
									#next if $protected == 1;
									unless ($universal_settings->{$r->{'app'}}->{'unique'} eq 'checked' || ($protected == 1 && !$cards_shared && !$clothesline_shared)) {
										# A machine that has just joined the house gives birth to
										# setting_initializer's defaults before its first settings sync -
										# navigation 'none', an empty duration, a fresh colour. Those rows
										# carry a fresh server_time, so newest-wins would let them replace
										# choices made on the machines that have been here all along. A
										# born default is not a choice: it never overwrites a value
										# somebody chose. The reverse still heals - a real value does
										# replace a default here even when the default is newer - so a
										# new machine catches up without losing anyone's setting.
										# A row keyed by a machine's signatorial belongs to that machine, not
										# to this one's device class. Flattening it onto our class is how
										# one computer's Music view became the other's; keep the key so the
										# two rows can stand side by side.
										my $peer_machine_row = (!$house_wide && &subs::setting_device_is_signatorial($r->{'device'})) ? 1 : 0;
										my $target_device = $house_wide ? 'all' : $peer_machine_row ? lc $r->{'device'} : $device;
										# 'yes' marks setting_initializer's born default; 'no' marks a
										# panel write, which is a choice even when it equals a default.
										# A row from an older build has no mark, so its value decides.
										my $incoming_seed = (($r->{'seed'} // '') eq 'yes') ? 1 : 0;
										my $incoming_chosen = (($r->{'seed'} // '') eq 'no') ? 1 : 0;
										my $incoming_default = $incoming_seed ? 1
											: $incoming_chosen ? 0
											: ((defined $r->{'setting'} && defined $r->{'value'})
												? &subs::setting_is_default($r->{'setting'}, $r->{'app'}, $r->{'value'}) : 0);
										my $local_row = defined $r->{'setting'}
											? &subs::db_query('select * from settings where app=? and setting=? and subsetting is ? and device = ? order by cast(server_time as integer) desc limit 1',
												$r->{'app'}, $r->{'setting'}, $r->{'subsetting'}, $target_device)->hashes->[0]
											: undef;
										# A row wearing one of the 2026-11-21 backfill stamps is not a live
										# write. Those stamps are newer than the true times, so trusting one
										# re-stamps a repaired machine and keeps the 25k-row hour moving.
										# Keep the row we hold; if we hold none, take the value at now.
										if (&subs::settings_time_backfilled($r->{'server_time'})) {
											next if ref $local_row eq 'HASH';
											$r->{'server_time'} = &subs::rightNow();
										}
										my $local_seed = (ref $local_row eq 'HASH' && ($local_row->{'seed'} // '') eq 'yes') ? 1 : 0;
										my $local_chosen = (ref $local_row eq 'HASH' && ($local_row->{'seed'} // '') eq 'no') ? 1 : 0;
										my $local_default = ref $local_row ne 'HASH' ? 1
											: $local_seed ? 1
											: $local_chosen ? 0
											: ((defined $local_row->{'value'} && length $local_row->{'value'})
												? &subs::setting_is_default($r->{'setting'}, $r->{'app'}, $local_row->{'value'}) : 1);
										if ($incoming_default && ref $local_row eq 'HASH' && !$local_default) {
											unless ($kept_default{$r->{'app'}}) {
												&subs::log_writer('settings merge: kept ' . $r->{'app'} . ' settings over a peer default from '
													. substr($r->{'device'} // '?', 0, 12));
												$kept_default{$r->{'app'}} = 1;
											}
											next;
										}
										# Heal only a born default. A row that merely looks like a default - an
										# older build's row, or a default value the person chose - is not
										# unborn, and letting an older peer value replace it is how a newer
										# setting came back older. `seed = 'yes'` is the only proof of birth;
										# a panel write carries 'no'.
										my $heal = (!$incoming_default && $local_seed && ref $local_row eq 'HASH') ? 1 : 0;
										# A row we already hold at the peer's own server_time counts as present:
										# the write below copies the peer's server_time verbatim, so with a strict
										# '>' the test was false again on the very next sync and every one of
										# the ~29k settings rows was deleted and reinserted, every sync, forever
										# (the 'Now merging N settings' that looked stuck). '>=' skips the row we
										# already hold, and still lets a genuinely newer peer value land.
										# A house-wide row is compared with the house row only: a per-device
										# copy of the same setting must not hide it.
										my $device_clause = $house_wide ? ' and device = ?' : '';
										my @device_args = $house_wide ? ('all') : ();
										my $time_check = $r->{'subsetting'} ? &subs::db_query('select app,setting,value from settings where app=? and setting=? and subsetting = ? and cast(server_time as integer) >= cast(? as integer)' . $device_clause,
												$r->{'app'}, $r->{'setting'}, $r->{'subsetting'}, $r->{'server_time'}, @device_args)->hashes :
											&subs::db_query('select app,setting,value from settings where app=? and setting=? and cast(server_time as integer) >= cast(? as integer)' . $device_clause,
												$r->{'app'}, $r->{'setting'}, $r->{'server_time'}, @device_args)->hashes;
										if (scalar @{$time_check} == 0 || $heal) {
											# A peer can carry an older copy under a device key this machine does
											# not compare with the time check. Name the write so a 72-hour watch
											# can see a newer value being covered by an older one.
											if (ref $local_row eq 'HASH'
												&& (($local_row->{'server_time'} || 0) + 0) > (($r->{'server_time'} || 0) + 0)) {
												&subs::sync_trace('settings-backward', {
													trace => $ctx->{'sync_trace'}, app => $r->{'app'}, setting => $r->{'setting'},
													device => $target_device, incoming => $r->{'server_time'}, held => $local_row->{'server_time'},
												});
											}
											eval {
												&subs::setting_setter({
													app => $r->{'app'},
													setting => $r->{'setting'},
													value => $r->{'value'},
													server_time => $r->{'server_time'},
													uuid => &subs::random_string_creator(20),
													device => $target_device,
													subsetting => $r->{'subsetting'},
													seed => $r->{'seed'},
													sync => 1
												});
											};
										}
										# Do not reload the app's whole settings map for every row: a
										# pull carries hundreds of changed settings, and each reload
										# copies every value of that app (some are multi-megabyte
										# blobs). One load per app is enough to answer `unique`.
										next;
									}
								#	&subs::setting_setter($r);
									next;
								}
								if ($q eq 'security') {
									if ($r->{'level'} == 1) {
										my $sec_uuid = &subs::db_select('security', ['uuid'], { level => 1 })->hash->{uuid};
										$r->{'level'} = 2 unless $sec_uuid eq $r->{'uuid'};
									}
								}

								if ($r->{'app'} && ($r->{'measures'} || $h->{'measures'})) {
									my $r_measures = eval { return decode_json $r->{'measures'} } || [];
									my $h_measures = eval { return decode_json $h->{'measures'} } || [];
									my $change = 0;
									foreach my $h_m ( @{$h_measures} ) {
										my @r_m = grep { $_->{'uuid'} eq $h_m->{'uuid'} } @{$r_measures};
										my $r_m = $r_m[0];
										$r_m->{'timestamp'} = $r_m->{'timestamp'} || $r_m->{'ts'} || $r_m->{'server_time'};
										if (scalar @r_m == 0) {
											push @{$r_measures}, $h_m;
											$change = 1;
										}
										elsif ($h_m->{'timestamp'} > $r_m->{'timestamp'}) {
											@{$r_measures} = grep { $_->{'uuid'} ne $h_m->{'uuid'} } @{$r_measures};
											push @{$r_measures}, $h_m;
											$change = 1;
										}
										$r->{'measures'} = encode_json $r_measures if $change == 1;
									}
								}

								if ($configuration->{'remote'}->{'manager'} && $r->{'app'} && ($r->{'file'} || $h->{'file'}) && $r->{'type'} ne 'snapshot' && $r->{'type'} ne 'backup' && $r->{'account'} ne 'gallery') {
									my $files = eval { return decode_json $r->{'file'} } || [];
									my $h_files = eval { return decode_json $h->{'file'} } || [];
									if (eval { $files->{'f'} }) { $files = [ $files ]; }
									if (eval { $h_files->{'f'} }) { $h_files = [ $h_files ]; }
									if ($q eq 'appointments') {
										$universal_settings->{$r->{'app'}}->{'enc'} = &subs::setting_grabber({ app => $r->{'app'}, device => $device, benign => 1 }) unless $universal_settings->{$r->{'app'}}->{'enc'};
										if ($universal_settings->{$r->{'app'}}->{'enc'} eq 'on' && !$r->{'encryption_standard'} && $r->{'server_time'} > &subs::ago_calc('10m', &subs::rightNow()) && scalar @{$files} > 0) {
											next;
										}
									}

									if (scalar @resulters > 0) {
										foreach my $home_file ( @{$h_files} ) {
											if ($home_file->{'server_time'} <= $r->{'server_time'} ) {
												unless ( grep { $home_file->{'uuid'} eq $_->{'uuid'} } @{$files}) {
												#	&delete_file({ app => $h->{'app'}, app_uuid => $h->{'uuid'}, file_uuid => $home_file->{'uuid'} });
													push @{$files}, $home_file;
													$r->{'server_time'} = &subs::rightNow();
												}
											}
											else {
												unless ( grep { $home_file->{'uuid'} eq $_->{'uuid'} } @{$files}) {
													push @{$files}, $home_file;
												}
											}
										}
									}
									if ($q eq 'appointments' && $tombstone_file{$r->{'uuid'}}) {
										my $strip = $tombstone_file{$r->{'uuid'}};
										my $before = scalar @{$files};
										@{$files} = grep { !$strip->{ $_->{'uuid'} } } @{$files};
										next ROW if $before > scalar @{$files} && scalar @{$files} == 0;
									}
									my $file_count = 0;
									foreach my $fi ( @{$files} ) {
										$file_count++;
										foreach my $file_type ( qw/f thumb/ ) {
											next unless $fi->{$file_type};
											my $file = $fi->{$file_type};
											my $size_key = &subs::media_entry_size_key($file_type);
											my $kept_path = '';
											my ($home_match) = grep { ($_->{'uuid'} // '') eq ($fi->{'uuid'} // '') } @{$h_files};
											# A peer can name a file it no longer has. The row's size says what the
											# file was; a smaller one is only believed when the manifest (or changed
											# dimensions) explains it. Keeping the local entry keeps its path, size
											# and history, not just the bytes.
											if ($home_match && &subs::file_entry_merge_verdict($home_match, $fi, $file_type) eq 'keep') {
												$fi->{$file_type} = $home_match->{$file_type};
												$fi->{$size_key} = $home_match->{$size_key} if defined $home_match->{$size_key};
												$fi->{'manifest'} = $home_match->{'manifest'} if ref $home_match->{'manifest'} eq 'ARRAY';
												next;
											}
											$last_percent = $percentage;
											# A row stream (the v3 pull) has no snapshot size to divide
											# by: `$results_size` is 0 there, and the file-carry progress
											# is display-only. Guard both divisors so a pulled row with an
											# attachment cannot kill the merge.
											$percentage = sprintf("%.2f", ($n + ($file_count / scalar @{$files})) / ($results_size || 1) * 100);


											if ($percentage >= $last_percent && $results_size > 0 && &subs::rightNow() >= ($last_alert + 250)) {
												my $speed = abs sprintf("%.2f", $n / ((($start_time - &subs::rightNow()) || 1)) * 1000);
												my $remaining = $percentage ? &subs::duration_sayer(((&subs::rightNow() - $start_time) / $percentage) * (100 - $percentage) / 1000) : 'unknown';
												my $html = '<b style="font-size:20px">' . sprintf("%.2f", ($n + ($file_count / scalar @{$files}))) . ' / ' . $results_size . ' ' . &subs::format_name($q) . ' ' . $percentage . '% @ ' . $speed . '/sec ' . $remaining .'</b><br>' .
													'<progress style="width:70%;height:60px;" value="' . $n . '" max="' . $results_size . '"></progress>';
												$last_percent = $percentage;
												$last_alert = &subs::rightNow();
												&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
											}
											my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $file, app => $r->{'app'}, misc_settings => $misc_settings, type => $fi->{'type'} });
											$fi->{'type'} = $type unless $fi->{'type'};
											my $dest = $destination . $asset;

											if ($home_match) {
												my $h_file = $home_match;

												my ($hdestination,$hasset) = &subs::file_device_renamer({ file => $h_file->{$file_type}, app => $h->{'app'}, misc_settings => $misc_settings, type => $h_file->{'type'} });
												unless ($asset eq $hasset) {
													if (-e $destination . $hasset) {
														my $hassethoff = $destination . $hasset;
														`shred -u $hassethoff`;
													}
												}
											}

											# A file that is only a sentinel stub (0, 1 or 3 bytes left by the
											# old unchecked decode) is not a local copy: fetch over it, so a
											# later merge can heal what the bug wrote.
											unless (-e $dest && !&subs::file_sentinel_stub($dest)) {
												# Files on demand: keep the reference and not the bytes. The
												# entry names the path on the machine that has it, so the
												# first open can fetch it (media_fetch_on_demand) and the
												# sweep can take it back when the disk fills.
												if (&subs::files_on_demand()) {
													$fi->{$file_type} = $dest;
													$fi->{'remote_f'} = $file;
													$fi->{'remote_peer'} = ($configuration->{'remote'}->{'signatorial'} // '');
													$fi->{'remote_at'} = &subs::rightNow();
													# The local path is the cache row, so a request that names
													# only the path (the Gallery's, the music shelf's) can still
													# find out which machine has the bytes.
													&subs::files_cache_note($dest, $file, $fi->{'remote_peer'});
													next;
												}
												`mkdir -p $destination`;
												$destination = $destination . $asset;
												if ($configuration->{'remote'}) {
													#$file = url_unescape $file;
													my $url = $configuration->{'remote'}->{'manager'} . '/file_open?timestamp=' . $r->{'server_time'} . '&as_is=yes&file=' . $file;
													# A peer file that cannot be fetched (a big gallery page, a closed
													# worker) used to kill the whole merge. The row is still
													# worth keeping; its file can be fetched by a later pass.
													my $file_data = eval { $configuration->{'remote'}->{'ua'}->get($url)->result };
													if ($file_data && $file_data->is_success) {
														# /file_open answers a refusal with the words "no", "none"
														# or "not found"; that is not base64, and decoding it is
														# what wrote the 1- and 3-byte stubs. synced_file_payload
														# refuses those and checks a sealed file's head.
														my $fd = &subs::synced_file_payload($file_data->body, $dest);
														# the destination can be unwritable (a logo row whose
														# app has no local media folder); keep the row anyway
														if (defined $fd && length $fd) {
															my $claimed = $fi->{$size_key};
															if (defined $claimed && length $claimed && length($fd) != $claimed) {
																# the body is not the size the row names: a truncated or empty
																# answer. Keep the local copy rather than write a smaller file
																# over a picture; with no local copy, keep the row but drop the
																# size claim a later pass checks.
																if ($home_match && -e $home_match->{$file_type}) {
																	$kept_path = $home_match->{$file_type};
																	$fi->{$file_type} = $kept_path;
																}
																delete $fi->{$size_key};
															}
															else {
																														eval { write_file($dest,$fd) };
															# a short write is not a copy: do not leave a truncated
															# file claiming to be the picture
															unlink $dest if (-e $dest && (-s $dest || 0) != length($fd));
															&subs::media_entry_measure($fi, $dest, 'sync', $file_type) if -e $dest;
															}
														}
													}
												}
											}
											$file = length $kept_path ? $kept_path : $dest;
											$fi->{$file_type} = $file;
											# A row written before sizes existed: learn the local size (never a
											# stub's) so the next merge can compare.
											if (-e $file && (!defined $fi->{$size_key} || !length $fi->{$size_key}) && !&subs::file_sentinel_stub($file)) {
												&subs::media_entry_measure($fi, $file, 'sync', $file_type);
											}
										}
									}
									$r->{'file'} = encode_json $files;
								}
								my $removed_row = grep { defined $_->{'uuid'} && defined $r->{'uuid'} && ($_->{'uuid'} eq $r->{'uuid'} ) && ($_->{'table'} || '') eq $q && ($_->{'scope'} || '') ne 'file' } @{$deletions};
								unless ($removed_row) {
									if (scalar @resulters == 0) {
										my $inserted = eval { &subs::db_insert($q,$r)};
										if ($@) { push @insert_errors, ($r->{'uuid'} || '?') . ': ' . ($@ =~ s/\s+/ /gr); }
										elsif ($inserted) { $rows_inserted++; }
										else { push @insert_errors, ($r->{'uuid'} || '?') . ': refused'; }
									}
									else {
										$rows_updated++ if $h->{'server_time'} < $r->{'server_time'};
										eval { &subs::db_update($q,$r, { uuid => $r->{'uuid'} } ) } unless $h->{'server_time'} >= $r->{'server_time'};
									}
									if ($q eq 'appointments' && (!$h->{'server_time'} || $r->{'server_time'} > $h->{'server_time'})) {
										push @{$updateables}, { app => $r->{'app'}, uuid => $r->{'uuid'} } unless grep { $_->{'app'} eq $r->{'app'} } @{$updateables};
									}
									# A toggle that arrived from a peer is a real state change for the
									# boards wired to that app. The merge writes rows quietly, so
									# without this a tablet-side toggle never reaches a board served
									# by another machine. Push it after the table is merged.
									if ($q eq 'settings' && ($r->{'setting'} // '') eq 'toggle' && ($r->{'app'} // '') !~ /^__/
										&& (scalar @resulters == 0 || !$h->{'server_time'} || $r->{'server_time'} > $h->{'server_time'})) {
										$toggle_changed{$r->{'app'}} = $r->{'value'};
									}
								}
								# A stop can reach this machine before the default session it must
								# close - or after it. The child is written on the machine that
								# started the app and the stop wherever it was pressed, so one
								# peer can hold an open child under a parent another peer has
								# already closed. Reconcile the pair here as well as on the press,
								# so a stopped parent never leaves a running model/option session.
								# Two states must not be undone: a stale stop replayed over a
								# parent that has since reopened, and a child reopened for a
								# pause/resume whose parent's reopen is still in flight. The
								# row's own server_time is the order both were written in.
								if ($q eq 'appointments' && !$removed_row) {
									my $is_closed = sub {
										my ($row) = @_;
										return 0 unless ref $row eq 'HASH';
										return 1 if (defined $row->{'stop_seen'} && length $row->{'stop_seen'});
										return (($row->{'type'} // '') =~ /^(?:stop|cancel)$/) ? 1 : 0;
									};
									my $is_open = sub {
										my ($row) = @_;
										return 0 unless ref $row eq 'HASH';
										return 0 unless (($row->{'type'} // '') =~ /^(?:start|record)$/);
										return (defined $row->{'stop_seen'} && length $row->{'stop_seen'}) ? 0 : 1;
									};
									my $stamp = sub {
										my ($row) = @_;
										return (ref $row eq 'HASH' && defined $row->{'server_time'}) ? (0 + $row->{'server_time'}) : 0;
									};
									my $parent;
									if ($is_closed->($r)) {
										# only a copy that actually moved the parent: a replayed
										# stop must not close a session a resume just reopened
										$parent = $r if !$h || $stamp->($r) >= $stamp->($h);
									}
									elsif ($is_open->($r) && defined $r->{'source_uuid'} && length $r->{'source_uuid'}) {
										my $parent_row = &subs::db_select('appointments', undef, { uuid => $r->{'source_uuid'} })->hashes->[0];
										if ($parent_row && $is_closed->($parent_row)) {
											my $resume = $h && $is_closed->($h) && $stamp->($r) > $stamp->($h);
											$parent = $parent_row unless $resume;
										}
									}
									if ($parent) {
										my $closed_children = &subs::default_children_close($parent);
										foreach my $child ( @{$closed_children} ) {
											push @{$updateables}, $child unless grep { ($_->{'uuid'} // '') eq ($child->{'uuid'} // '') } @{$updateables};
										}
									}
								}
							}
		}
	};
	for (my $n = 0; !$results_size || $n < $results_size; $n++) {
		my $r = $next_row->();
		last unless $r;
		$rows_read++;
		$merge_one->($r, $n);
	}
						my $short = ($results_size && $rows_read < $results_size) ? ' SHORT' : '';
						# An insert that failed is not a merged table, for the same reason a
						# short read is not: claiming success stores the peer's picture in
						# `sync_seen` and the missing rows are never asked for again. Report
						# both, and let the pull retry.
						my $merge_errors = scalar @insert_errors;
						$merge_short = 1 if $short || $merge_errors;
						my $errors = $merge_errors ? ' errors=' . join(' | ', @insert_errors[0 .. ($#insert_errors > 2 ? 2 : $#insert_errors)]) : '';
						my $skew = scalar keys %skewed_columns ? ' skipped-columns=' . join(',', sort keys %skewed_columns) : '';
						&subs::log_writer('merge ' . $q . ': snapshot=' . $results_size . ' read=' . $rows_read . ' inserted=' . $rows_inserted . ' updated=' . $rows_updated . $short . $errors . $skew);
						&subs::sync_trace('merged', {
							trace => $ctx->{'sync_trace'}, table => $q, snapshot => $results_size,
							read => $rows_read, inserted => $rows_inserted, updated => $rows_updated,
							short => $short ? 1 : 0, errors => $merge_errors, skew => join(',', sort keys %skewed_columns),
						});
						if ($sync_job) {
							&subs::sync_job_step($sync_job, 'merge:' . $q, { state => ($short || $merge_errors) ? 'failed' : 'done', current => ($results_size || $rows_read), total => ($results_size || $rows_read), note => $short ? 'read ' . $rows_read . ' of ' . $results_size : ($merge_errors ? $merge_errors . ' row errors' : '') });
						}
	foreach my $ta ( sort keys %toggle_changed ) {
		&subs::watch_toggle_pusher({ app => $ta, value => $toggle_changed{$ta} });
	}
	return $merge_short;
}

# The post-merge work shared by the snapshot path and the row-stream path: refresh
# the header/budget for appointments that moved, apply the deletions that came with
# the pull, and drop the relational caches an app's settings invalidate.
sub merge_finish {
	my ($ctx) = @_;
	my $configuration = $ctx->{'configuration'} || {};
	my $updateables = $ctx->{'updateables'} || [];
	my $auuid = $ctx->{'auuid'};
	my $colour = $ctx->{'colour'};
	my $percentage = 0;
	my $last_percent = 0;
	my $last_alert = &subs::rightNow();
	my $start_time = $last_alert;
	my $results_size = scalar @{$updateables};
	for (my $n = 0; $n < $results_size; $n++) {
		my $u = $updateables->[$n];
		next unless ref $u eq 'HASH' && $u->{'app'};
		&budget_runner($u->{'app'});
		&subs::appt_header_printer({ app => $u->{'app'}, timestamp => &subs::rightNow() });
		&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $u->{'app'}, $u->{'uuid'})});
		$percentage = sprintf("%.2f", $n / $results_size * 100);
		$percentage = .0000001 if $percentage == 0;
		if ($percentage >= $last_percent && $results_size > 1 && &subs::rightNow() >= ($last_alert + 250)) {
			my $speed = abs sprintf("%.2f", $n / ($start_time - &subs::rightNow()) * 1000);
			my $remaining = &subs::duration_sayer(((&subs::rightNow() - $start_time) / $percentage) * (100 - $percentage) / 1000);
			my $html = '<b style="font-size:20px">' . $n . ' / ' . $results_size . ' ' . &subs::format_name('informations') . ' ' . $percentage . '% @ ' . $speed . '/sec ' . $remaining . '</b><br>' .
				'<progress style="width:70%;height:60px;" value="' . $n . '" max="' . $results_size . '"></progress>';
			$last_percent = $percentage;
			$last_alert = &subs::rightNow();
			&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
		}
	}
	&deletion_performer($configuration->{'remote'}->{'deletions'}) if $configuration->{'remote'};
}

# Merge an encrypted snapshot: the full-migration / deep-gimme / v2 path. A normal
# v3 delta never gets here - `sync_rows_pull` feeds the same merge_table_rows and
# merge_finish directly from the row batches.
sub merge_database($c,$configuration) {
	&update_database($c);
	my $filename = $configuration->{'file'};
	my $remote_misc_settings = $configuration->{'misc_settings'};
	my $misc_settings = &misc_setting_list();
	my $device = &subs::device_setter();
	my $deletions = eval { return decode_json $configuration->{'remote'}->{'deletions'} } || [];

	my $rdel = &subs::db_select('remote_machines', [ 'deletions' ], {})->hashes;
	foreach my $rd ( @{$rdel} ) {
		my $all_deletions = eval { return decode_json $rd->{'deletions'} } || [];
		push @{$deletions}, @{$all_deletions};
	}


	my $port = $config->{'ssh_port'};
	my $auuid = &subs::random_string_creator(10);
	my $colour = $configuration->{'colour'};
	my $html = '<h3>Starting Merge ' . $filename . '</h3>';
	&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
	my ($db,$database) = &subs::database_grabber();
	my $disposition->{'status'} = 'fail';
	# A table the cursor could not finish is not a merge. `remote_upgrade` writes
	# the peer's picture into `sync_seen` after a successful merge, so reporting
	# succeed after a short read made a partial pull look like a full
	# reconciliation - the next tick then skipped the table and the rows stayed
	# missing. Keep the disposition honest so the pull retries.
	my $merge_short = 0;
	my $path = $filename;
	my $download_location = &subs::home('~/.president');
	my $temp_folder = &subs::home($download_location . '/' . &subs::random_string_creator(10));
	`mkdir -p $temp_folder` unless -e "$temp_folder";
	my $temporary_file = $temp_folder . '/tmpman.db';
	my $credentials = &subs::db_query('select level,credential from security where level != ? order by server_time DESC', 'padlock');
	my $creds = $credentials->hashes;
	my $signatorial = &subs::signatorial_designer();
	my $last_update_time = &subs::db_select('backups', undef, { recipient => $signatorial, signatorial => $configuration->{'signatorial'} })->hashes->[-1];
	$last_update_time = $last_update_time->{'server_time'} || 0;
	$last_update_time = $configuration->{'gimme'} if $configuration->{'gimme'};
	@{$creds} = grep { $_->{'level'} ne 'padlock' } @{$creds};
	@{$creds} = reverse @{$creds};
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
	my @updateables;
	my $suds = &subs::session_suds($c) || &subs::suds_grabber();
	my $merge_ctx;
	foreach my $cred ( @{$creds} ) {
		my $crud = &subs::decrypter($suds,$cred->{'credential'});
		my $html = '<h3>Testing Keys</h3>';

		&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
		if ($path =~ /\.enc\z/i) {
			my $tail_command = 'tail ' . &subs::shell_quote($path);
			my $data = `$tail_command`;

			my @split_data = split $universal_splitter, $data;

			unless ($data =~ /\Q$universal_splitter/gi) {
				# The marker is appended after the ciphertext. If it is not in the tail,
				# the file we downloaded is not the finished container (truncated, or
				# not the archive at all) - say so instead of silently skipping the key.
				$log->error('merge container: standard marker missing; tail=' . length($data) . ' bytes') if $log;
				next;
			}

			$encryption_standard = &subs::backup_standard($crud, $split_data[1]);
			&subs::openssl_file_crypt('d', $encryption_standard, $crud, $path, $temporary_file, 1, 1);

			my $tsql = Mojo::SQLite->new('sqlite:' . $temporary_file);
			my $decrypted_size = (-s $temporary_file) || 0;
			my $snapshot_db = eval { $tsql->db ? 1 : 0 };
			my $snapshot_ok = ($decrypted_size > 5000 && $snapshot_db && $tsql->dsn !~ /:$/) ? 1 : 0;
			# A merged table leaves a "merge <table>" line; a pull that never gets
			# there has failed at the container itself, and used to leave only "merge
			# did not finish" with no reason. Say which credential opened what.
			$log->error('merge snapshot: level=' . ($cred->{'level'} || '?') . ' archive=' . ((-s $path) || 0)
				. ' decrypted=' . $decrypted_size . ' db=' . ($snapshot_db ? 1 : 0) . ' dsn=' . $tsql->dsn) if $log && !$snapshot_ok;
			if ($snapshot_ok) {
				my $tdb = $tsql->db;

				my $backups = &subs::db_query('select * from backups order by server_time DESC' )->hashes;

				my $start_server_time = 0;
				if ( scalar @{$backups} > 1 ) {
					$start_server_time = $backups->[1]->{'server_time'};
				}

				my $html = '<h3>Now merging</h3>';
				&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
				$disposition->{'temporary_file'} = $temporary_file;
				my $stats = [];
				my $tables = `sqlite3 $temporary_file .tables`;

				my @u = sort split ' ', $tables;

				my $count = 0;
				my $universal_settings = {};
				my $sync_job = $configuration->{'sync_job'};
				&subs::sync_job_update($sync_job, { phase => 'merge', current => 0, total => scalar @u }) if $sync_job;
				$merge_ctx = {
					configuration => $configuration,
					misc_settings => $misc_settings,
					device => $device,
					deletions => $deletions,
					universal_settings => $universal_settings,
					updateables => \@updateables,
					sync_job => $sync_job,
					sync_trace => 'S' . &subs::rightNow() . '-' . &subs::random_string_creator(4),
					auuid => $auuid,
					colour => $colour,
				};
				foreach my $q ( @u ) {
					next if grep { $q eq $_ } @{$gb::forbidden->{'tables'}};
					# Count first, then read the snapshot's rows in bounded batches. A
					# full convergence carries a whole table (110k appointments), so
					# ->hashes on everything would hold it all in memory on top of the
					# merge; the batch reader below keeps one page at a time.
					my $results_size = ($tdb->query('select count(*) as c from ' . $q)->hash->{'c'} || 0) + 0;
					if ($results_size > 0) {
						$count++;
						&subs::sync_job_update($sync_job, { current => $count }) if $sync_job;
						my @merge_batch;
						my $merge_rowid = 0;
						my $merge_all;
						my $next_row = sub {
							unless (scalar @merge_batch) {
								return undef if $merge_all;
								my $rows = eval { $tdb->query('select rowid as __merge_rowid, * from ' . $q . ' where rowid > ? order by rowid limit 500', $merge_rowid)->hashes };
								if (!$rows) {
									# a table without a rowid (a view) is read whole, once
									$merge_all = 1;
									$rows = $tdb->query('select * from ' . $q)->hashes;
								}
								@merge_batch = @{$rows || []};
								return undef unless scalar @merge_batch;
							}
							my $row = shift @merge_batch;
							$merge_rowid = delete $row->{'__merge_rowid'} if exists $row->{'__merge_rowid'};
							return $row;
						};
						my $short = &merge_table_rows($merge_ctx, $q, $next_row, $results_size, $count, scalar @u);
						$merge_short = 1 if $short;
					}
					$disposition->{'disposition'} = $database;
					$disposition->{'status'} = $merge_short ? 'failed' : 'succeed';
					my $known_backup = &subs::db_select('backups', undef, { uuid => $backups->[0]->{'uuid'} })->hashes;
					if ($known_backup->[0]->{'reason'} =~ /remote/gi) {
						my $defunct_backups = &subs::db_query('delete from backups where recipient=? and signatorial=? and destination=? and server_time < ? and uuid != ?',
							$backups->[0]->{'recipient'}, $backups->[0]->{'signatorial'}, $backups->[0]->{'destination'}, $backups->[0]->{'server_time'}, $backups->[0]->{'uuid'});
						$disposition->{'backup_uuid'} = $backups->[0]->{'uuid'};
					}
				}
				last;
			}
		}
	}
	&merge_finish($merge_ctx) if $merge_ctx;
	&Websocket::send('tab', { yellow => 'close', 'close' => 'yes', uuid => $auuid, colour => $colour });
	&subs::say_it('fail') unless $disposition->{'status'} eq 'succeed';
	`shred -u $temporary_file` if -e $temporary_file;
	`shred -u $temporary_file-shm` if -e $temporary_file;
	`shred -u $temporary_file-wal` if -e $temporary_file;
	`rm -R $temp_folder`;
	return $disposition;
}

1;
