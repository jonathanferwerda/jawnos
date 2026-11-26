package Manager;

# Manager helpers, part 9 of 37. Moved out of Manager.pl so a
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

# Pull a peer's rows as encrypted batches and merge them with the same per-row
# rules the snapshot path uses. Only the local watermark and `sync_seen` move, and
# only after every table finished: a short batch leaves the next tick to retry.
sub sync_rows_pull {
	my ($c, $params, $sync, $job, $remote_machine, $auuid) = @_;
	# A peer on newer code may carry a table this database has not been migrated for
	# yet; the snapshot path got this through merge_database. Run it here too, then
	# drop the cached table list so the new table is actually requested.
	&update_database($c);
	$subs::sync_table_cache = undef;
	my $remote = $remote_machine || &remote_useragent_maker({ signatorial => $params->{'remote_signatorial'} });
	# A tailnet name whose node is offline blackholes every request until the
	# timeout, while the peer advertises a LAN manager that answers instantly.
	# Prefer that manager when it differs - unless the caller already proved a
	# manager with the signed presence probe; the LAN address it advertises may
	# be the one that just failed.
	my $lan = $remote->{'manager_verified'} ? undef : &subs::peer_lan_address($remote, 1);
	$remote->{'manager'} = $lan->{'manager'}
		if $lan && $lan->{'manager'} && $lan->{'manager'} ne ($remote->{'manager'} || '');
	# When the stored name is a tailnet address and no LAN route answered, ask the
	# house server where the peer is now. The server is the authority for a machine
	# that woke on a different network; its record carries the address the peer
	# advertised, so the pull does not have to wait out a socket timeout.
	if (!$lan && !$remote->{'manager_verified'} && &AddressDirectory::manager_is_tailnet($remote->{'manager'})) {
		my $resolved = eval { &AddressDirectory::lookup($remote->{'signatorial'}) };
		if (ref $resolved eq 'HASH' && ($resolved->{'manager'} // '') ne '') {
			$remote->{'manager'} = $resolved->{'manager'};
		}
	}
	# The yellow panel names the job's phase, and this path has no export to wait
	# on: it is reading and merging rows. Say so instead of leaving it at the
	# snapshot phase the job was created with.
	&subs::db_query("update sync_jobs set phase = 'merge' where uuid = ?", $job);
	my $remote_signatorial = $params->{'remote_signatorial'} || $remote->{'signatorial'};
	# One id ties this pull's decision lines to its merge summary in `sync.log`.
	my $trace_id = 'P' . &subs::rightNow() . '-' . &subs::random_string_creator(4);
	my $signatorial = &subs::signatorial_designer();
	my $suds = &subs::session_suds($c) || &subs::suds_grabber();
	my $security = &subs::db_select('security', ['credential'], { level => 1 })->hash || {};
	my $secret = &subs::decrypter($suds, $security->{'credential'} || '');
	unless (defined $secret && length $secret) {
		$sync->done('failed', 'no shared credential for the row stream');
		return 'failed';
	}
	my $colour = $remote->{'data'}->{'manager_colour'};
	my $deletions = eval { return decode_json($remote->{'deletions'} || '[]') } || [];
	my $rdel = &subs::db_select('remote_machines', ['deletions'], {})->hashes;
	foreach my $rd (@{$rdel}) {
		my $all = eval { return decode_json($rd->{'deletions'} || '[]') } || [];
		push @{$deletions}, @{$all};
	}
	my $configuration = {
		signatorial => $remote_signatorial,
		remote => $remote,
		sync_job => $job,
		colour => $colour,
	};
	my @updateables;
	my $ctx = {
		configuration => $configuration,
		misc_settings => &misc_setting_list(),
		device => &subs::device_setter(),
		deletions => $deletions,
		universal_settings => {},
		updateables => \@updateables,
		sync_job => $job,
		sync_trace => $trace_id,
		auuid => $auuid,
		colour => $colour,
	};
	my $plan = (ref $params->{'plan'} eq 'HASH') ? $params->{'plan'} : {};
	&subs::sync_trace('pull-start', {
		trace => $trace_id,
		peer => substr($remote_signatorial // '', 0, 8),
		plan => join(',', map { $_ . '=' . (defined $plan->{$_} ? $plan->{$_} : '') } sort keys %{$plan}),
		default_cut => $params->{'default_cut'},
		gimme => $params->{'gimme'} ? 1 : 0,
	});
	my $default_cut = (defined $params->{'default_cut'} && $params->{'default_cut'} =~ /^[0-9]+$/) ? $params->{'default_cut'} : 0;
	my @tables = @{ &subs::sync_table_list() };
	# With a plan (the digest says what differs), fetch only the tables that moved
	# plus the carry-only streams. Without one, this is a first/cold pull: every
	# table from the window, as the snapshot path did. The carry-only tables have
	# no digest trigger by design (continent is a location stream), so they must
	# always ride along or a device's travel map stops learning where the others
	# are - and the bookkeeping tables would never travel at all once the planner
	# stopped letting them start a pull.
	my $have_plan = (ref $params->{'plan'} eq 'HASH' && scalar keys %{$params->{'plan'}}) ? 1 : 0;
	my %carry = map { $_ => 1 } @{ &subs::sync_carry_tables() };
	my %fetch;
	if (!$have_plan) {
		$fetch{$_} = 1 for @tables;
	}
	else {
		$fetch{$_} = 1 for grep { exists $plan->{$_} || $carry{$_} } @tables;
		# An appointment carries no app configuration of its own. If an appointment
		# is being pulled, carry the settings delta too, or its window opens with an
		# empty app until a later tick notices the settings on their own.
		$fetch{'settings'} = 1 if $fetch{'appointments'};
	}
	# Settings first: the window that an appointment opens reads its app's settings,
	# so they must already be merged when the appointment's header is refreshed.
	my %rank = (settings => 0, appointments => 1);
	my @ordered = sort { ($rank{$a} // 2) <=> ($rank{$b} // 2) || $a cmp $b } grep { $fetch{$_} } @tables;
	my $settings_count = -1;
	my $table_total = scalar @ordered;
	my $count = 0;
	my $watermark = 0;
	my $wire = 0;
	my $failed;
	# The peer picture we last reconciled: the baseline the band diff is measured
	# against. Each table's fresh map, when one is fetched, rides along below.
	my $prior_seen = &subs::sync_seen_get($remote_signatorial) || {};
	my $bucket_maps = {};
	foreach my $table (@ordered) {
		my $cut = (exists $plan->{$table} && defined $plan->{$table}) ? $plan->{$table} : $default_cut;
		$cut = 0 unless defined $cut && $cut =~ /^[0-9]+$/;
		if ($table eq 'settings') {
			# A machine with no settings at all (a fresh install, a restored empty
			# database) has no watermark to delta against: send the whole table once.
			$settings_count = &subs::db_query('select count(*) as c from settings')->hashes->[0]->{'c'} || 0 if $settings_count < 0;
			$cut = 0 unless $settings_count;
		}
		# A whole-table read is the only expensive plan. When the peer's last
		# reconciled band map is on hand, ask which bands moved and read only
		# those; the whole-table digest was the cheap gate that got us here.
		# Settings are judged by the durable map (`settings_durable`) but read
		# through the ordinary settings stream, which is a superset of it - the
		# same rows a full settings read already carries. An older peer or a
		# failed map falls through to the plain read.
		my $bands;
		my $map_table = ($table eq 'settings') ? 'settings_durable' : $table;
		my $table_band = &subs::sync_bucket_band_for($table);
		my $base = (ref $prior_seen->{$map_table} eq 'HASH') ? $prior_seen->{$map_table} : undef;
		my $settings_empty = ($table eq 'settings' && !$settings_count) ? 1 : 0;
		# A baseline that already equals the peer's current picture cannot be the
		# picture we reconciled: if we had, our table would match and the planner
		# would not have asked. It is the stale baseline of a short pull, so read
		# against our own table instead of re-confirming it.
		my $peer_pic = (ref $params->{'remote_digest'} eq 'HASH') ? $params->{'remote_digest'}->{$map_table} : undef;
		my $base_is_peer = ($table ne 'settings' && ref $base eq 'HASH' && ref $peer_pic eq 'HASH'
			&& (($base->{'count'} || 0) + 0) == (($peer_pic->{'count'} || 0) + 0)
			&& (($base->{'sum'} || 0) + 0) == (($peer_pic->{'sum'} || 0) + 0)
			&& (($base->{'max'} || 0) + 0) == (($peer_pic->{'max'} || 0) + 0)) ? 1 : 0;
		# The last reconciled map is the exact baseline: it names the blocks this
		# peer changed. With no baseline yet (the first divergence after this code,
		# or after a whole-table read), this machine's own picture is the reference
		# instead - it localises just as well, and the same request learns the
		# peer's map for every later tick.
		my $have_base = (ref $base eq 'HASH' && $base->{'full'}
			&& ref $base->{'buckets'} eq 'HASH' && scalar keys %{ $base->{'buckets'} }
			&& !$base_is_peer) ? 1 : 0;
		# A baseline measured at a different band names different buckets, so it
		# cannot be diffed against this map: fall back to the gapless compare
		# against our own table and learn the current band's map below. Without
		# this, a settings baseline stored at the old weekly band kept the first
		# hourly pull reading against it (or forced the bootstrap path forever).
		$have_base = 0 if $have_base && (($base->{'band'} || 0) + 0) != $table_band;
		if ($cut == 0 && !$settings_empty) {
			my $band = &subs::sync_bucket_normalize($table_band);
			my ($bmap, $berr) = &sync_buckets_batch($remote, $signatorial, $secret, $map_table, $band);
			if (ref $bmap eq 'HASH' && ref $bmap->{'buckets'} eq 'HASH') {
				$bucket_maps->{$table} = { band => $bmap->{'band'}, buckets => $bmap->{'buckets'} };
				# The map carries the peer's clock, the way a first batch does: even
				# a repair that reads no rows must still advance the watermark so
				# the new picture is recorded below and the plan moves on.
				$watermark = $bmap->{'server_time'} if $bmap->{'server_time'} && $bmap->{'server_time'} > $watermark;
				my $moved;
				if ($have_base) {
					# A peer change can be this machine's own write coming back through
					# the peer's merge. Read only the changed bands our own table does
					# not already hold - a band where we have at least the peer's rows,
					# newest row and sum has nothing to fetch. Without this the current
					# week's 42k-row block was read back every few minutes, because the
					# peer could never catch up to the writes it had just relayed.
					my $changed = &subs::sync_bucket_diff($base->{'buckets'}, $bmap->{'buckets'});
					$moved = $changed;
					if (scalar @{$changed}) {
						my $local = &subs::sync_table_buckets($map_table, $bmap->{'band'});
						$moved = &subs::sync_bucket_gaps($local->{'buckets'}, $bmap->{'buckets'}, $changed);
						my $settled = scalar(@{$changed}) - scalar(@{$moved});
						&subs::log_writer('sync bucket covered ' . $table . ': settled=' . $settled . '/' . scalar(@{$changed}) . ' band=' . $bmap->{'band'}) if $settled;
					}
				}
				else {
					# No reconciled peer picture yet: compare the peer's map with this
					# machine's own. Only a band the peer holds and we do not is read;
					# a band we already cover has nothing to fetch even when the two
					# pictures differ in their newer copies.
					my $local = &subs::sync_table_buckets($map_table, $bmap->{'band'});
					$moved = &subs::sync_bucket_gaps($local->{'buckets'}, $bmap->{'buckets'});
					&subs::log_writer('sync bucket bootstrap ' . $table . ': moved=' . scalar(@{$moved}) . ' band=' . $bmap->{'band'});
				}
				my $moved_n = scalar @{$moved};
				my $bands_total = scalar keys %{ $bmap->{'buckets'} };
				# A table changed across most of its bands is cheaper read whole: a
				# walk is a request per band on top of the same rows.
				$bands = $moved if ($moved_n && $moved_n <= 100 && $moved_n <= ($bands_total * 0.5));
				if ($bands) {
					&subs::log_writer('sync bucket repair ' . $table . ': moved=' . $moved_n . '/' . $bands_total . ' band=' . $bmap->{'band'});
				}
				elsif ($moved_n) {
					&subs::log_writer('sync bucket repair skipped for ' . $table . ': moved=' . $moved_n . '/' . $bands_total . '; reading the whole table');
				}
				&subs::sync_trace('table', {
					trace => $trace_id, table => $table, cut => $cut,
					band => $bmap->{'band'}, base_band => ($base->{'band'} || 0) + 0,
					have_base => $have_base ? 1 : 0, base_is_peer => $base_is_peer ? 1 : 0,
					total_bands => $bands_total, moved => $moved_n,
					path => $bands ? 'band-walk' : ($moved_n ? 'whole-table' : 'quiet'),
				});
				if ($moved_n == 0) {
					# Every band matches the baseline: nothing to read. Record the
					# new picture and move on instead of re-reading the table.
					$count++;
					&subs::sync_job_step($job, 'merge:' . $table, { label => 'merge ' . $table, state => 'done', current => 1, total => 1 });
					next;
				}
			}
			else {
				# A map that did not arrive must not turn a small divergence into a
				# whole-table read: on a phone that scan runs a core hot for minutes and
				# the rows it finds are almost always the few above the watermark. Read
				# from the caller's watermark window instead. The digest gate keeps the
				# table in the plan, so a later pass with a working map still localises
				# an old row the window could not name.
				&subs::sync_trace('map-failed', { trace => $trace_id, table => $table, error => ($berr || 'no map'), cut => $cut, default_cut => $default_cut });
				if ($default_cut && $default_cut > 0) {
					$cut = $default_cut;
					&subs::log_writer('sync bucket map failed for ' . $table . ': ' . ($berr || 'no map') . '; reading from the watermark instead of the whole table');
				}
				else {
					&subs::log_writer('sync bucket map failed for ' . $table . ': ' . ($berr || 'no map') . '; reading the whole table');
				}
			}
		}
		if (ref $bands eq 'ARRAY') {
			my @queue = ();
			my @pending = @{$bands};
			my ($cur_from, $cur_to);
			my $cursor = '';
			my $batch_done = 0;
			my $in_band = 0;
			my $fetched = 0;
			my $fetch_error;
			my $expected = 0;
			foreach my $b (@pending) {
				my $bn = $bucket_maps->{$table}->{'buckets'}->{$b};
				$expected += ($bn->{'count'} || 0) if ref $bn eq 'HASH';
			}
			$count++;
			&subs::sync_job_step($job, 'merge:' . $table, { label => 'merge ' . $table, state => 'running', current => 0, total => $expected });
			my $next_row = sub {
				while (1) {
					if (scalar @queue) {
						my $row = shift @queue;
						delete $row->{'__sync_rowid'} if ref $row eq 'HASH';
						$watermark = $row->{'server_time'} if ref $row eq 'HASH' && defined $row->{'server_time'} && $row->{'server_time'} > $watermark;
						return $row;
					}
					return undef if $fetch_error;
					if ($in_band) {
						if ($batch_done) { $in_band = 0; $cursor = ''; $cur_from = $cur_to = undef; next; }
					}
					else {
						my $b = shift @pending;
						unless (defined $b) {
							# Every band was walked. Fewer rows than the map promised is a
							# short read (a band changed under us), not a reconciled table:
							# name it so the pull retries instead of reporting success.
							# A carry-only stream (routers, window_events, the where
							# tables, paired_devices...) is written while it is read, so
							# its map is a picture that moves under the walk. Fewer rows
							# than the map named is the stream changing, not a lost read:
							# the next pull carries it again. Failing here made every
							# laptop pull stop on "routers: short read" and no table
							# behind it ever merged.
							$fetch_error = 'short band read: ' . $fetched . ' of ' . $expected
								if $expected && $fetched < $expected && !$carry{$table};
							return undef;
						}
						($cur_from, $cur_to) = &subs::sync_bucket_range($bucket_maps->{$table}->{'band'}, $b);
						$in_band = 1;
						$cursor = '';
						$batch_done = 0;
					}
					my ($batch, $why) = &sync_rows_batch($remote, $signatorial, $secret, $table, 0, $cursor,
						(defined $cur_from ? { from => $cur_from, to => $cur_to } : undef));
					unless ($batch) { $fetch_error = $why || 'a band failed'; return undef; }
					@queue = @{ $batch->{'rows'} || [] };
					$cursor = $batch->{'next'} || '';
					$batch_done = (($batch->{'done'} || $cursor eq '') ? 1 : 0);
					$wire += $batch->{'wire_bytes'} || 0;
					$fetched += scalar @queue;
					&subs::sync_job_step($job, 'merge:' . $table, { current => $fetched, total => ($expected || $fetched) });
				}
			};
			# `0` leaves the merge unbounded: a band can grow between the map and the
			# read, and bounding by the map's count would drop the extra rows. The
			# closure below names a short read instead (fetched < expected).
			my $short = &merge_table_rows($ctx, $table, $next_row, 0, $count, $table_total, $expected);
			if ($short || $fetch_error) {
				if ($carry{$table}) {
					# A carry stream is best effort: a row the local schema refuses
					# (two peers see the same router under different uuids) or a band
					# that moved under the map must not fail the whole pull and hold
					# every table behind it. Leave it for the next pass.
					&subs::log_writer('sync carry skipped ' . $table . ': ' . ($fetch_error || 'refused rows'));
					next;
				}
				$failed = $table . ': ' . ($fetch_error || 'short read');
				last;
			}
			next;
		}
		# A whole-table read can outlast a restart. The batch cursor is the rowid
		# of the last row the peer sent, and the row stream is ordered by rowid, so
		# the cursor names exactly the rows already merged. Continue after it when
		# this peer is read again with the same cut; a different cut, a different
		# peer, or an old marker starts from the top. Without this, the board never
		# finished its first 122k-row reconciliation: every update restarted it
		# mid-read and the next pass began at row one (2026-11-25).
		my $resume = &subs::sync_resume_get($remote_signatorial, $table, $cut);
		my $resume_after = $resume ? ($resume->{'after'} || '') : '';
		&subs::sync_resume_clear($remote_signatorial, $table) unless $resume;
		my ($first, $err, $skip) = &sync_rows_batch($remote, $signatorial, $secret, $table, $cut, $resume_after);
		&subs::sync_trace('read', { trace => $trace_id, table => $table, mode => ($cut ? 'watermark' : 'whole'), cut => $cut, resume => ($resume_after ne '' ? $resume_after : '-') });
		if ($skip) {
			&subs::sync_resume_clear($remote_signatorial, $table);
			next;
		}
		unless ($first) {
			$failed = $table . ': ' . ($err || 'no answer');
			last;
		}
		$watermark = $first->{'server_time'} || $watermark if !$watermark;
		$wire += $first->{'wire_bytes'} || 0;
		# A resumed read carries no count: the server only counts the first batch
		# of a whole-table read. Use the count saved with the cursor so the bar and
		# the `unless $total` guard still work.
		my $total = $first->{'total'} || ($resume ? ($resume->{'total'} || 0) : 0) || 0;
		if ($resume) {
			$watermark = $resume->{'watermark'}
				if ($resume->{'watermark'} || 0) > $watermark;
			&subs::log_writer('sync resume ' . $table . ': continuing after rowid ' . $resume_after . ' of ' . $total);
		}
		# Settings learn their band map on the first successful pull, even when a
		# window holds no rows: an install reconciled before this code has no map,
		# and without one every later divergence would fall back to a blind window.
		if ($table eq 'settings' && $settings_count && !$bucket_maps->{$table}
			&& !(ref $base eq 'HASH' && ref $base->{'buckets'} eq 'HASH' && scalar keys %{ $base->{'buckets'} })) {
			my ($bmap) = &sync_buckets_batch($remote, $signatorial, $secret, 'settings_durable', $table_band);
			if (ref $bmap eq 'HASH' && ref $bmap->{'buckets'} eq 'HASH') {
				$bucket_maps->{$table} = { band => $bmap->{'band'}, buckets => $bmap->{'buckets'} };
			}
		}
		next unless $total;
		$count++;
		my @queue = @{ $first->{'rows'} || [] };
		my $cursor = $first->{'next'} || '';
		my $done = $first->{'done'} ? 1 : 0;
		my $fetched = scalar @queue;
		my $fetch_error;
		&subs::sync_job_step($job, 'merge:' . $table, { label => 'merge ' . $table, state => 'running', current => $fetched, total => $total });
		my $next_row = sub {
			while (!scalar @queue) {
				return undef if $done || $fetch_error || $cursor eq '';
				# Everything up to $cursor is merged, so this is the safe place to
				# remember the resume point: writing it after the next fetch would
				# skip the rows that fetch returns if the process died mid-batch.
				&subs::sync_resume_put($remote_signatorial, $table, {
					cut => $cut, after => $cursor, total => $total, watermark => $watermark,
				});
				my ($batch, $why) = &sync_rows_batch($remote, $signatorial, $secret, $table, $cut, $cursor);
				unless ($batch) { $fetch_error = $why || 'a batch failed'; return undef; }
				@queue = @{ $batch->{'rows'} || [] };
				$cursor = $batch->{'next'} || '';
				$done = $batch->{'done'} ? 1 : 0;
				$wire += $batch->{'wire_bytes'} || 0;
				$fetched += scalar @queue;
				&subs::sync_job_step($job, 'merge:' . $table, { current => $fetched, total => $total });
			}
			my $row = shift @queue;
			delete $row->{'__sync_rowid'} if ref $row eq 'HASH';
			$watermark = $row->{'server_time'} if ref $row eq 'HASH' && defined $row->{'server_time'} && $row->{'server_time'} > $watermark;
			return $row;
		};
		# `$total` is the first batch's own count: it keeps the panel's bar honest
		# while a streamed read (no snapshot size) is merging.
		my $short = &merge_table_rows($ctx, $table, $next_row, 0, $count, $table_total, $total);
		if ($short || $fetch_error) {
			if ($carry{$table}) {
				# A carry stream is best effort: the rows that arrived are merged,
				# a refused one is left for the next pass, and the pull carries on
				# rather than reporting a failure that stops every later table.
				&subs::log_writer('sync carry skipped ' . $table . ': ' . ($fetch_error || 'refused rows'));
				next;
			}
			# Leave the marker at the last fully merged batch: the next pass picks
			# the table up there instead of at row one.
			$failed = $table . ': ' . ($fetch_error || 'short read');
			last;
		}
		&subs::sync_resume_clear($remote_signatorial, $table);
		# A full read is the moment to learn the peer's band map, so the next
		# divergence can be repaired band by band instead of read whole again.
		# Settings reach here when they had only a partial baseline map and the
		# full read just replaced it.
		if ($cut == 0 && !$bucket_maps->{$table} && ($table ne 'settings' || $settings_count)) {
			my ($bmap) = &sync_buckets_batch($remote, $signatorial, $secret, $map_table, $table_band);
			if (ref $bmap eq 'HASH' && ref $bmap->{'buckets'} eq 'HASH') {
				$bucket_maps->{$table} = { band => $bmap->{'band'}, buckets => $bmap->{'buckets'} };
			}
		}
	}
	&merge_finish($ctx);
	if ($failed) {
		&subs::sync_job_step($job, 'merge', { state => 'failed', note => $failed });
		$sync->done('failed', $failed);
		return 'failed';
	}
	# Settle deletions too. A machine that pulls rows but never handshakes this
	# donor (out of its hub's range) used to keep rows the donor had deleted; ask
	# for the durable log above our confirmed cursor and apply it now.
	{
		my $turl = $remote->{'manager'} . '/manager/sync_tombstones?signatorial=' . $signatorial . '&cursor=' . int($remote->{'sync_cursor'} || 0);
		my $tres = $remote->{'ua'} ? eval { $remote->{'ua'}->inactivity_timeout(20)->request_timeout(30)->get($turl)->result } : undef;
		if ($tres && $tres->is_success) {
			my $tj = eval { decode_json $tres->body } || {};
			&apply_peer_tombstones($tj, $remote_signatorial);
		}
	}
	# The puller's own watermark: what the reconnector hands the peer as `since`
	# next tick. Written only after every table finished, so a short pull retries.
	if (!$params->{'gimme'} && $watermark) {
		&subs::db_query('delete from backups where ost < ? and recipient = ? and signatorial = ? and reason = ?', $watermark, $signatorial, $remote_signatorial, 'remote_upgraded');
		&subs::db_update('backups', { server_time => $watermark, reason => 'remote_upgraded', size => $wire }, {
			recipient => $signatorial,
			signatorial => $remote_signatorial,
		});
		my $seen = &subs::db_query('select count(*) as c from backups where reason = ? and recipient = ? and signatorial = ?', 'remote_upgraded', $signatorial, $remote_signatorial)->hashes->[0] || {};
		unless ($seen->{'c'}) {
			&subs::db_insert('backups', {
				timestamp => &subs::rightNow(),
				server_time => $watermark,
				reason => 'remote_upgraded',
				recipient => $signatorial,
				signatorial => $remote_signatorial,
				destination => $params->{'database'},
				warranty => &subs::ago_calc('-20m', &subs::rightNow()),
				uuid => &subs::random_string_creator(25)
			});
		}
		if (ref $params->{'remote_digest'} eq 'HASH') {
			my $prior = $prior_seen;
			my %seen_map;
			# Only the tables this pull examined may move their picture forward. A
			# table the plan did not include was not read; recording the peer's
			# digest for it is how a divergence stayed invisible (2026-11-05).
			my $has_plan = (scalar keys %{$plan}) ? 1 : 0;
			foreach my $t ( keys %{$params->{'remote_digest'}} ) {
				my $d = $params->{'remote_digest'}->{$t};
				next unless ref $d eq 'HASH';
				my $pk = ($t eq 'settings_durable') ? 'settings' : $t;
				next if $has_plan && !exists $plan->{$pk};
				my $cut = $plan->{$pk};
				my $full = (defined $cut && $cut == 0) ? 1 : ((ref $prior->{$t} eq 'HASH' && $prior->{$t}->{'full'}) ? 1 : 0);
				# A settings pull records its map under the durable key, which is the
				# one the planner compares.
				my $bm = $bucket_maps->{$pk};
				# A whole/banded read is reconciled only when we hold every row the
				# peer's map names. Leave `full` false otherwise: the planner asks
				# again and the next pull localises against our own table, not a
				# stale map. Settings are exempt (their durable count differs by
				# device class on purpose).
				if ($full && defined $cut && $cut == 0 && $t ne 'settings_durable') {
					if (ref $bm eq 'HASH' && ref $bm->{'buckets'} eq 'HASH') {
						$full = 0 unless &subs::sync_bands_complete($t, $bm);
					}
					else {
						$full = 0 unless &subs::sync_table_complete($t, $d);
					}
				}
				$seen_map{$t} = { %{$d}, full => $full };
				if ($full && ref $bm eq 'HASH' && ref $bm->{'buckets'} eq 'HASH') {
					$seen_map{$t}->{'band'} = $bm->{'band'};
					$seen_map{$t}->{'buckets'} = $bm->{'buckets'};
				}
				elsif ($full && ref $prior->{$t} eq 'HASH' && ref $prior->{$t}->{'buckets'} eq 'HASH') {
					# Keep the map we already held: it is an older picture of this peer,
					# so a later diff may re-read a band a delta already covered, but it
					# never misses one.
					$seen_map{$t}->{'band'} = $prior->{$t}->{'band'};
					$seen_map{$t}->{'buckets'} = $prior->{$t}->{'buckets'};
				}
			}
			&subs::sync_seen_set($remote_signatorial, \%seen_map);
		}
		&subs::sync_backoff_clear($remote_signatorial);
	}
	&subs::sync_job_step($job, 'merge', { state => 'done', current => 1, total => 1 });
	$sync->done('done', 'rows merged ' . &subs::data_size($wire));
	return 'done';
}

1;
