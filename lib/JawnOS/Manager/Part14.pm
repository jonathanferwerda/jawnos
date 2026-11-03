package Manager;

# Manager helpers, part 14 of 37. Moved out of Manager.pl so a
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
use Mojo::IOLoop::ReadWriteFork;
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
use IO::Socket::UNIX;
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

sub manager_reset($c) {

	if (($c->param('account') eq 'gallery' && &subs::setting_grabber({ app => 'me', setting => 'gallery_appts' }) eq 'off' )) {
		return { 'cv' => 'inapplicable' };
	}
	my $timestamp = &timestamp_adjuster($c);

	my $app = &subs::unformat_name($c->param('app'));
#	&subs::cache_delete({ app => $app, context => 'template' });
	my $browser_tab_id = $c->param('browser_tab_id');
	my $locking_status = $c->param('lockingStatus');
	my $server_time = $c->param('server_time') || &subs::rightNow() || $timestamp;
	$c->param('server_time' => $server_time);
	my $type = $c->param('type');
	# the type the request named, before the branches below rewrite $type: a
	# start/stop moves which appointment owns the desktop theme, and the push at
	# the foot of this sub repaints every open manager at once
	my $theme_movement = $type || '';
	# The Add press reads the redrawn window out of the reply (`cv`); a start or
	# stop does not, and only needs its header at once. A start's header is rendered
	# in its own process, so a busy render cannot hold the toggle and the default
	# model/option sessions behind it.
	my $wants_cv = ($c->param('cv') // '') eq 'yes' ? 1 : 0;
	my $defer_header = $wants_cv ? 0 : 1;
	my $seg_t0 = &subs::rightNow();
	my @seg_times;
	my $seg = sub { my $now = &subs::rightNow(); push @seg_times, ($_[0] . '=' . ($now - $seg_t0)); $seg_t0 = $now; };
#	($app,undef,$type) = &subs::typesetter($app);
	$type = $type || $c->param('type');
	my $init = &subs::setting_initializer($app,$timestamp);
	$app = $init->{'app'};
	$seg->('init');
	$c->param('app' => $app);
	# A stop names the session it closes: managerReset sends the open session's uuid
	# (read off the appointment header), so the same stop closes that same row on
	# every machine instead of each resolving "the open session" against its own -
	# possibly different - copy of the database. A start still mints its own uuid
	# and carries it through the relay below.
	my $target_uuid = $c->param('uuid') || '';
	my $uuid = $c->param('uuid') || &subs::random_string_creator(40);
	$c->param('uuid' => $uuid);
	# A resume reopens the row its last stop/cancel left. Resolve that row now,
	# before the relay, the way a stop names the session it closes: every machine
	# then reopens one and the same row instead of each reading "the newest
	# stop" from its own - possibly different - copy of the database.
	if ($type eq 'resume' && !$target_uuid) {
		my $last = &subs::db_query('select uuid from appointments where app = ? and (type = ? or type = ?) order by timestamp DESC LIMIT 1', $app, 'stop','cancel')->hashes->[0];
		if ($last && $last->{'uuid'}) {
			$target_uuid = $last->{'uuid'};
			$uuid = $target_uuid;
			$c->param('uuid' => $uuid);
		}
	}
	my $returner = { app => $app, timestamp => $timestamp, server_time => $server_time, init => $init, uuid => $uuid };
	# A media press names the machine that does the work (the camera, scan and
	# record dropdowns carry its signatorial). The request is relayed to that
	# machine, which reads its own signatorial back and captures; this one only
	# writes the row. Without the guard both ends capture - the duplicate
	# pictures the old "any camera in the house" path produced.
	my $capture_machine = $c->param('remote_signatorial') || '';
	my $capture_here = ($capture_machine eq '' || $capture_machine eq &subs::signatorial_designer()) ? 1 : 0;
	my $source = $c->param('source');
	my $measure_is_open = $c->param('measure_is_open');
	my $usual_duration = $init->{'duration'};
	if ($locking_status eq 'on') {
		$c->param('duration', $usual_duration)
	}
	my ($appt_header, $header_appts);
	&subs::subprocessor(sub {
	  Mojo::IOLoop->reset;
		&remote_relay_request($c, { dissemination => 'yes' });
	}, { name => 'reset remote relay' });
	my $duration = &duration_read($c->param('duration'));
	$duration = &duration_read($usual_duration) unless defined $duration;
	$duration = 0 unless defined $duration;
	$c->param('uuid' => $uuid);
	#&subs::setting_setter({ app => $app, setting => 'duration', value => $c->param('duration'), timestamp => $timestamp }) unless $usual_duration;

	my $unit = $c->param('unit');

	my $quantity = $c->param('quantity');
	if (defined $quantity && $quantity =~ /[a-zA-Z]/) {
		# a hybrid quantity carries its own unit ("355 mL", "355ml"); the shared
		# splitter canonicalises the case, so a typed unit reaches the warehouse as
		# the measure it names instead of the app's default
		my ($typed_quantity, $typed_unit) = &subs::quantity_unit_split($quantity);
		$quantity = $typed_quantity;
		$unit = $typed_unit if defined $typed_unit && length $typed_unit;
	}

	my $manufacturer = $c->param('manufacturer');
	my $project = $c->param('project');
	my $camera = $c->param('camera') || 0;
	my $feed = $c->param('feed');
	my $notes = $c->param('notes');
	$notes =~ s/\$/\\\$/gi;
	my $digits = $c->param('digits');
	my $mirror = $c->param('mirror');
	my $file = $c->param('file');
	# A press that reopens or re-times an existing session (resume, pause,
	# delay) writes that row in place, and the browser sends no `file` with it.
	# Carrying the absent parameter into the update set the column to NULL and
	# dropped the files already attached to the session, so only a caller that
	# really sends a file list may replace it.
	my $file_update = (defined $file && $file ne '') ? { file => $file } : {};
	# The same rule for the text: an empty editor on a resume/pause/delay press
	# carries no note, so the row keeps the one it already has.
	my $notes_update = (defined $notes && $notes ne '') ? { notes => $notes } : {};
	my $end_notes_update = (defined $notes && $notes ne '') ? { end_notes => $notes } : {};
	my $mute = $c->param('mute');
	my $words = $c->param('words');


	my $time_definition = &subs::rightNow();
	my $appointments;
	my $results = &subs::db_query("select max(timestamp) as file,timestamp,notes,app,duration,type,status,amount,unit,account from appointments where app=? and timestamp <=? and type != 'note' order by timestamp", $app,$time_definition);
	$appointments = $results->hashes;
	$results = &subs::db_query("select min(timestamp) as file,timestamp,notes,app,duration,type,status,amount,unit,account from appointments where app=? and timestamp >=? and type != 'note' order by timestamp", $app,$time_definition);
	push @{$appointments}, @{$results->hashes};
	$seg->('read');
	# An app with nothing logged yet is created by whatever the person logged, but a
	# stop/cancel/resume/pause/delay has no session to act on and must not mint one -
	# on a peer that had not yet synced this app, coercing a stop to "add" wrote a
	# spurious appointment that then rode the mesh back as a duplicate.
	if (scalar @{$appointments} == 0 && $type !~ /^(?:stop|cancel|resume|pause|delay)$/) { $type = "add" };
	my $pos = &subs::setting_grabber({ app => $app, setting => 'pos' } ) || 'idea';
	$notes = &subs::note_encrypter(&subs::session_suds($c),$notes) if $notes;

	my ($status,$announced_time);

	my $warranty_holder = $timestamp;
	$warranty_holder = $server_time if $server_time > $timestamp;
	my $warranty_spec = $c->param('warranty');
	$warranty_spec = &subs::setting_grabber({ app => $app, setting => 'warranty' }) unless defined $warranty_spec && $warranty_spec =~ /\S/;
	$warranty_spec = '-10y' unless defined $warranty_spec && $warranty_spec =~ /\S/;
	my $warranty = &warranty_resolve($warranty_spec, $warranty_holder, 1);
	$warranty = &subs::ago_calc($warranty_spec, $warranty_holder) unless defined $warranty;
	$returner->{'warranty'} = $warranty;
	my $usual_schedule = &subs::setting_grabber({ app => $app, setting => 'schedule' });
	# Not expanded here. A usual schedule can name hundreds of future repeats, and
	# each one is an existence check and a write; expanding it before the header is
	# what made a press wait. It runs after the branch, behind the header below.
	my $seen = 'yes';
	if ($timestamp > &subs::rightNow() + 1000) {
		$seen = undef;
	}

	if ($type eq 'start' || $type eq 'record') {
		my $jdata;
		if ($type eq 'record') {
			# A media button names its source on the press itself (video, audio,
			# screen); a plain record press follows the app's own setting. Only a
			# source this build knows is written, so a stray parameter cannot put
			# an unknown recorder in the row the Alarm loop later reads.
			my $recording_type = &record_source_param($c->param('recorder'))
				|| &subs::setting_grabber({ app => $app, setting => 'record' })
				|| 'system';
			my $machine = $c->param('remote_signatorial') || '';
			my $here = $capture_here;
			my $dat = { recorder => $recording_type, machine => $machine };
			if ($recording_type eq 'video') {
				$seen = undef;
				$dat->{'camera'} = $camera;
			}
			elsif ($recording_type eq 'audio') {
				$seen = undef;
			}
			elsif ($recording_type eq 'screen') {
				$seen = undef;
			}
			elsif ($recording_type eq 'video_front') {
				$dat->{'camera'} = $camera;
			}
			elsif ($recording_type eq 'security') {
				&record_video({ app => $app, uuid => $uuid, timestamp => $timestamp }) if $seen eq 'yes' && $here;
			}
			else {
				&record_audio({ app => $app, uuid => $uuid, timestamp => $timestamp }) if $seen eq 'yes' && $here;
			}
			$jdata = encode_json $dat;
		}

		my $source_uuid;
		foreach my $qo ( qw/model option/ ) {
			my $mo = &subs::db_select($qo, undef, { name => $app })->hashes;
			foreach my $ao ( @{$mo} ) {
				my $began = &subs::db_query('select * from appointments where app=? and (type=? or type=?) and timestamp <= ? order by timestamp desc limit 1',$ao->{'app'},'record','start',$timestamp)->hashes;
				$source_uuid = $began->[0]->{'uuid'};
			}
		}

		my $stop_timestamp = $c->param('duration') =~ /[a-zA-Z0-9]/ ? $timestamp - ((abs $duration) * -1) : undef;
		# A live start that is already here (a replay delivered twice) is the same
		# press, not a second session: reuse the open row and refresh it instead of
		# minting a twin uuid the stop will never name. Only a live start is deduped;
		# a scheduled one waits for its own time and the stop paths settle it.
		my $twin = $seen eq 'yes' && $type eq 'start'
			? (&subs::session_open_near($app, $type, $timestamp, 2000))->[0]
			: undef;
		if ($twin && $twin->{'uuid'}) {
			$uuid = $twin->{'uuid'};
			$c->param('uuid' => $uuid);
			&subs::db_update('appointments', { server_time => $server_time, seen => $seen }, { uuid => $uuid, app => $app });
		}
		else {
		&subs::db_insert('appointments', {
			app => $app,
			timestamp => $timestamp,
			unit => $unit,
			quantity => $quantity,
			project => $project,
			type => $type,
			status => $status,
			duration => (abs $duration) * -1,
			start_notes => $notes,
			server_time => $server_time,
			file => $file,
			data => $jdata,
			'pos' => $pos,
			warranty => $warranty + (abs $duration),
			source => $source,
			uuid => $uuid,
			seen => $seen,
			source_uuid => $source_uuid,
			stop_timestamp => $stop_timestamp,
			browser_tab_id => $browser_tab_id
		});
		}
		# The header goes out the instant the row is written, before the toggle, the
		# automation and the default model/option sessions: those can wait, the
		# person watching the header cannot.
		($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $timestamp, skip_toggle => ($seen eq 'yes' ? 1 : 0), defer => $defer_header }); 
		$seg->('hdr');
		# The row and its header are out. The default model/option sessions can start
		# (or stop) a chain of child appointments and take seconds; they run in their
		# own process so the reply and this worker are free.
		my $fork_c = $c;
		my $fork_app = $app;
		my $fork_uuid = $uuid;
		my $fork_timestamp = $timestamp;
		my $fork_duration = $duration;
		my $fork_type = $type;
		my $fork_project = $project;
		my $fork_init = $init;
		my $fork_unit = $unit;
		my $fork_quantity = $quantity;
		my $fork_manufacturer = $manufacturer;
		my $fork_stop_timestamp = $stop_timestamp;
		my $fork_seen = $seen;
		&subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			&subs::setting_setter({ app => $fork_app, setting => 'toggle', value => 'on' }) if $fork_seen eq 'yes';
			&subs::intelligent_automation_toggle({ appt_uuid => $fork_uuid, app => $fork_app, 'state' => 'on', timestamp => $fork_timestamp });
			my ($model,$options,$jmodel,$joptions) = &subs::usual_appointment_maker({
				app => $fork_app,
				uuid => $fork_uuid,
				timestamp => $fork_timestamp,
				$fork_duration => (abs $fork_duration) * -1,
				type => $fork_type
			},{
				project => $fork_project
			});
			if (!$fork_unit && $model->{'unit'}) {
				$fork_unit = $model->{'unit'};
			}
			elsif (!$fork_unit && $fork_init->{'unit'}) {
				$fork_unit = $fork_init->{'unit'};
			}
			if (!$fork_quantity && $model->{'quantity'}) {
				$fork_quantity = $model->{'quantity'};
			}
			elsif (!$fork_quantity && $fork_init->{'quantity'}) {
				$fork_quantity = $fork_init->{'quantity'};
			}
			if (!$fork_manufacturer && $model->{'manufacturer'}) {
				$fork_manufacturer = $model->{'manufacturer'};
			}
			elsif ($fork_init->{'manufacturer'}) {
				$fork_manufacturer = $fork_init->{'manufacturer'};
			}
			&subs::db_update('appointments', { server_time => &subs::rightNow(), model => $jmodel, options => $joptions, unit => $fork_unit, quantity => $fork_quantity, manufacturer => $fork_manufacturer }, { uuid => $fork_uuid, app => $fork_app });
			&appointment_stock_movement($fork_c, $fork_app, $fork_type, $fork_quantity, $fork_unit, $fork_timestamp, $fork_uuid) if $fork_type eq 'record';
			if ($fork_stop_timestamp) {
				&subs::intelligent_automation_toggle({ appt_uuid => $fork_uuid, app => $fork_app, 'state' => 'off', timestamp => $fork_stop_timestamp });
			}
		}, { name => 'appointment models' });
		$seg->('models');

	}
	elsif ($type eq 'stop') {
		my $recording_type = &subs::setting_grabber({ app => $app, setting => 'record' });
		# The session named by the client (a stop carries its uuid) is closed and only
		# it; a stop that names none - or one this machine has not synced - closes the
		# oldest open session. Both manager_reset and appointment_writer resolve this
		# through subs::stop_target_row, so a stop lands on one and the same row.
		my $stop_row = &subs::stop_target_row($app, $target_uuid, $timestamp);
		my $old_appts = $stop_row ? [ $stop_row ] : [];

		foreach my $o ( @{$old_appts} ) {
		#	next;
			my $timestamp1 = $o->{'timestamp'};
			$uuid = $o->{'uuid'};
			$c->param('uuid' => $uuid);
			if ($o->{'type'} eq 'record') {
				my $data = eval { return decode_json $o->{'data'} } || {};
				if ($data->{'recorder'} eq 'security') {
					if ($seen eq 'yes') {
						&record_video_stop({ app => $app, timestamp => $timestamp1, uuid => $o->{'uuid'} }) if $o->{'uuid'};
						next;
					}
					else { $type = 'record'; };
				}
				elsif ($data->{'recorder'} eq 'system') {
					if ($seen eq 'yes') {
						&record_audio_stop({ app => $app, timestamp => $timestamp1, uuid => $o->{'uuid'} }) if $o->{'uuid'};
						next;
					}
					else { $type = 'record'; };
				}
				elsif ($seen eq 'yes') {
					&Websocket::send('music', { console => 'jpStop(\'' . $o->{'app'} . '\',\'' . $data->{'recorder'} . '\',\'' . $o->{'uuid'} . '\');' });
				}
			}
			unless ($c->param('duration')) {
				$duration = $timestamp1 - $timestamp;
				my $all_durations = &subs::db_query('select * from appointments where app=? and type=? order by server_time DESC LIMIT 40',$app,'stop')->hashes;
				my $total_durations = abs $duration;
				if ($o->{'end_notes'}) {
					my $n = &subs::note_decrypter(&subs::session_suds($c), $o->{'end_notes'}, $o->{'ost'});
					$n .= "\n" . &subs::note_decrypter(&subs::session_suds($c), $notes);
					$notes = &subs::note_encrypter(&subs::session_suds($c), $n);
				}
				foreach my $ad ( @{$all_durations} ) {
					$total_durations += abs $ad->{'duration'};
				}
				my $new_duration = $total_durations / ( scalar @{$all_durations} + 1);

				&subs::setting_setter({ app => $app, setting => 'duration', value => &subs::duration_sayer($new_duration / 1000 ) });
			}
			else {
				$duration = (abs $duration) * -1;
				$timestamp = $timestamp1 - $duration;
			}
			if ($o->{'type'} eq 'start' || $o->{'type'} eq 'record') {
				$type = 'stop';
			}
			else {
				$type = $o->{'type'};
			}
			if ($seen eq 'yes') {

				&subs::db_update('appointments', {
					project => $project,
					type => $type,
					duration => $duration,
			#		timestamp => $timestamp,
					end_notes => $notes,
					server_time => $server_time,
					app => $app,
					'pos' => $pos,
					warranty => $warranty,
					source => $source,
					stop_seen => $timestamp <= &subs::rightNow() + 1000 ? 'yes' : undef,
					stop_timestamp => $timestamp,
				}, {
					app => $app,
					uuid => $o->{'uuid'}
				});
			}
			else {
				&subs::db_update('appointments', {
					project => $project,
					duration => $duration,
			#		timestamp => $timestamp,
					end_notes => $notes,
					server_time => $server_time,
					app => $app,
					'pos' => $pos,
					warranty => $warranty,
					source => $source,
					stop_seen => $timestamp <= &subs::rightNow() + 1000 ? 'yes' : undef,
					stop_timestamp => $timestamp >= &subs::rightNow() + 1000 ? $timestamp : undef,
				}, {
					app => $app,
					uuid => $o->{'uuid'}
				});
			}
			($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $timestamp, skip_toggle => ($seen eq 'yes' ? 1 : 0) });
			$seg->('stop_hdr');
			&subs::setting_setter({ app => $app, setting => 'toggle', value => 'off' }) if $seen eq 'yes';
			# a start carries the amount; this stop is when the session is finished,
			# so it is the one movement the session makes. A record moved at creation
			# and is not moved again here.
			if (($o->{'type'} || '') eq 'start') {
				my $stock_qty = (defined $quantity && $quantity =~ /[0-9]/) ? $quantity : $o->{'quantity'};
				my $stock_unit = (defined $unit && $unit ne '') ? $unit : $o->{'unit'};
				&appointment_stock_movement($c, $app, 'stop', $stock_qty, $stock_unit, $timestamp, $uuid);
			}
			&subs::intelligent_automation_toggle({ appt_uuid => $o->{'uuid'}, app => $app, 'state' => 'off', timestamp => $timestamp });
			my $sources = &subs::db_select('appointments', undef, { source_uuid => $o->{'uuid'} })->hashes;
			my $options = eval { return decode_json $o->{'options'} } || [];
			my $model = eval { return decode_json $o->{'model'} } || {};
			push @{$options}, $model if $model->{'uuid'};
			my %so_seen;
			my %child_apps;
			foreach my $so ( @{$sources} ) {
				next if $so_seen{ $so->{'uuid'} }++;
				push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
				if ( $so->{'type'} eq 'start' ) {
					my @current_option = grep { $_->{'name'} eq $so->{'app'} } @{$options};
					my $co = $current_option[0];
					my $dur = $so->{'timestamp'} - $timestamp;
					my $ts = $timestamp;
					if ($co->{'delay_stop'}) {
						my $t = &subs::time_abbrev_translator($co->{'delay_stop'});
						$ts = $ts + $t;
						$dur = $dur + $t;
					}
					my $so_data = { stop_timestamp => $ts, duration => $dur, server_time => $server_time };
					if ($ts <= &subs::rightNow()) {
						$so_data->{'type'} = $type;
						$so_data->{'stop_seen'} = 'yes';
					}
					&subs::db_update('appointments', $so_data, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'}, app => $so->{'app'} });
					$child_apps{ $so->{'app'} } = 1;
					&budget_runner($so->{'app'});

					&subs::intelligent_automation_toggle({ appt_uuid => $so->{'uuid'}, app => $so->{'app'}, 'state' => 'off', timestamp => $ts });
					&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
				}
			}
			&subs::source_header_printer([ keys %child_apps ], $timestamp);

			&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $o->{'uuid'} . '\');' });
		}

		# A stop names one row, but a replayed start may have left an open twin
		# beside it (same press, different uuid). One press means one session, so
		# retire the twins too; otherwise a machine that received only the twin
		# keeps showing the appointment as running long after it was stopped.
		if ($seen eq 'yes' && $stop_row && $stop_row->{'uuid'}) {
			my $stop_at = $timestamp;
			my %twin_apps;
			foreach my $tw ( @{ &subs::session_twin_rows($app, $stop_row->{'uuid'}, $stop_row->{'timestamp'}, 2000) } ) {
				next unless $tw->{'uuid'};
				my $dur = (0 + $tw->{'timestamp'}) - $stop_at;
				&subs::db_update('appointments', {
					type => 'stop',
					stop_timestamp => $stop_at,
					duration => $dur,
					stop_seen => $stop_at <= &subs::rightNow() + 1000 ? 'yes' : undef,
					seen => 'yes',
					server_time => $server_time
				}, { uuid => $tw->{'uuid'}, app => $app });
				# The twin's own model/option children are sessions of their own
				# apps; close them too or the twin's child keeps running.
				foreach my $so ( @{ &subs::db_query('select uuid,timestamp,app from appointments where source_uuid=? and (type=? or type=?) and stop_seen is null', $tw->{'uuid'}, 'start', 'record')->hashes || [] } ) {
					my $sdur = (0 + $so->{'timestamp'}) - $stop_at;
					&subs::db_update('appointments', {
						type => 'stop',
						stop_timestamp => $stop_at,
						duration => $sdur,
						stop_seen => $stop_at <= &subs::rightNow() + 1000 ? 'yes' : undef,
						seen => 'yes',
						server_time => $server_time
					}, { uuid => $so->{'uuid'} });
					$twin_apps{ $so->{'app'} } = 1;
				}
			}
			&subs::source_header_printer([ keys %twin_apps ], $timestamp);
		}

	}
	elsif ($type eq 'cancel') {
		my $timestamp1 = &subs::db_select('appointments', ['uuid','timestamp'], { app => $app, type => 'start' })->hash;
		$uuid = $timestamp1->{'uuid'};
		$duration = $timestamp - $timestamp1->{'timestamp'};
		&subs::intelligent_automation_toggle({ appt_uuid => $uuid, app => $app, 'state' => 'off', timestamp => $timestamp1->{'timestamp'} });
		&subs::db_update('appointments', {
			type => 'cancel',
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			server_time => $server_time
		},
		{
			app => $app,
			uuid => $uuid,
		});
		($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $timestamp }); 
		my $sources = &subs::db_select('appointments', undef, { source_uuid => $uuid })->hashes;

		my %so_seen;
		my %child_apps;
		foreach my $so ( @{$sources} ) {
			next if $so_seen{ $so->{'uuid'} }++;
			push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
			if ( $so->{'type'} eq 'start' ) {
				&subs::db_update('appointments', { type => $type, duration => $duration, server_time => $server_time }, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'}, app => $so->{'app'} });
				$child_apps{ $so->{'app'} } = 1;
				&budget_runner($so->{'app'});
				&subs::intelligent_automation_toggle({ appt_uuid => $so->{'uuid'}, app => $so->{'app'}, 'state' => 'off', timestamp => $so->{'timestamp'} });
				&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
			}
		}
		&subs::source_header_printer([ keys %child_apps ], $timestamp);
	}

	elsif ($type =~ 'reset' || $type =~ 'usual') {
		unless ($c->param('duration')) {
			my $udur = &subs::db_query('select duration from appointments where app=? and type=? order by timestamp DESC LIMIT 20',$app,'stop')->hashes;
			my $ucount = scalar @{$udur};
			my $utotal = 0;
			if ($ucount > 1) {
				foreach my $u ( @{$udur} ) {
					$utotal += $u->{'duration'};
				}
				$duration = $utotal / $ucount;
			}
			else {
				my $sduration = eval { return &subs::db_select('settings', ['value'], {app => $app, setting => 'duration', device => $device })->hash->{value} };
				if ($sduration && $duration == undef) {
					$sduration = &subs::time_abbrev_translator($sduration);
					$duration = $sduration;
				}
			}
		}
		if ($duration < 0) {
			$duration = $duration * -1;
		}

		&subs::db_insert('appointments', {
			app => $app,
			timestamp => $timestamp,
			project => $project,
			type => $type,
			status => 'usual',
			duration => $duration,
			start_notes => $notes,
			server_time => $server_time,
			file => $file,
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			uuid => $uuid,
			seen => $seen,
			browser_tab_id => $browser_tab_id
		});
		($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $timestamp }); 


		my ($model,$options,$jmodel,$joptions) = &subs::usual_appointment_maker({
			app => $app,
			uuid => $uuid,
			timestamp => $timestamp,
			$duration => (abs $duration),
			type => $type
		}, {
			project => $project
		});
		if (!$unit && $model->{'unit'}) {
			$unit = $model->{'unit'};
		}
		elsif (!$unit && $init->{'unit'}) {
			$unit = $init->{'unit'};
		}
		if (!$quantity && $model->{'quantity'}) {
			$quantity = $model->{'quantity'};
		}
		elsif (!$quantity && $init->{'quantity'}) {
			$quantity = $init->{'quantity'};
		}
		if (!$manufacturer && $model->{'manufacturer'}) {
			$manufacturer = $model->{'manufacturer'};
		}
		elsif ($init->{'manufacturer'}) {
			$manufacturer = $init->{'manufacturer'};
		}
		&subs::db_update('appointments', { server_time => &subs::rightNow(), model => $jmodel, options => $joptions, unit => $unit, quantity => $quantity, manufacturer => $manufacturer }, { uuid => $uuid, app => $app });
	}
	elsif ($type =~ 'sms' && $device eq 'mobile') {
		my $data = {};
		$digits = &subs::setting_grabber({ app => $app, setting => 'phone' });
		($data->{'digits'},$data->{'message'}) = &sms_message_send($digits,$c->param('notes'));

		$data = &subs::note_encrypter($c->{'suds'}, encode_json $data);
		&subs::db_insert('appointments', {
			app => $app,
			timestamp => $timestamp,
			unit => $unit,
			project => $project,
			type => 'sms',
			status => 'sms',
			duration => '500',
			data => $data,
			start_notes => $notes,
			server_time => $server_time,
			file => $file,
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			uuid => $uuid,
			seen => $seen,
			browser_tab_id => $browser_tab_id
		});

	}
	elsif ($type eq 'renew') {

		# Renew re-anchors every record's warranty to the one just chosen: the value
		# typed in the card, or the app's setting when the field was blank, resolved
		# once above. The old branch re-read the stored setting and ignored the typed
		# value, so a renewal silently restored the old warranty to every record - and
		# it read a bare length the opposite way from warranty_resolve, which could
		# put a whole app's history in the past. A renewal that resolves behind now
		# would be swept by alarm_haircut, so nothing is written in that case.
		my $renew_ok = &subs::warranty_renewal_ok($warranty, &subs::rightNow());
		$log->info('renew for ' . $app . ' refused: warranty ' . ($warranty // '') . ' is not ahead of now') unless $renew_ok;
		if ($renew_ok) {
			my $appt_db = &subs::db_query('select * from appointments where app = ?',$app);
			my $sames = $appt_db->hashes;
			foreach my $same (@{$sames}) {
				my $new_warranty = &subs::warranty_renewed($warranty, $warranty_holder, $same->{'timestamp'});
				&subs::db_update('appointments', {
					warranty => $new_warranty,
					server_time => &subs::rightNow()
				},
				{
					app => $same->{'app'},
					uuid => $same->{'uuid'}
				});
			my $websockets = &subs::db_query('select * from websockets where windows like ? and server_time > ? and windows is not null order by timestamp DESC',
				'%app":"' . $app . '%', $server_time - 5000)->hashes;
			if (scalar @{$websockets} > 0) {
				&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $same->{'uuid'} .'\');'});
			}
		}
	}
}
elsif ($type eq 'delay') {
		my $appt = &subs::db_select('appointments', undef, {app => $app, type => ['record','start'] }, { -desc => 'timestamp' })->hashes->[0];
		my $timestamp1 = $appt->{'timestamp'};
		$duration = $appt->{'duration'} ? $appt->{'duration'} : $timestamp - $appt->{'timestamp'};
		my $delay = &duration_read($c->param('duration'));
		my $stop_timestamp = defined $delay ? $timestamp + abs($delay) : $appt->{'stop_timestamp'} ? $timestamp + (abs $duration): undef;
		$uuid = $appt->{'uuid'};
		&subs::db_update('appointments', {
			unit => $unit,
			project => $project,
			type => 'start',
			status => 'start',
			timestamp => $timestamp,
			%{$notes_update},
			server_time => $server_time,
			%{$file_update},
			duration => $duration,
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			seen => $seen,
			stop_timestamp => $stop_timestamp,
			stop_seen => $stop_timestamp && $stop_timestamp <= $server_time + 1000 ? 'yes' : undef
		}, {
			app => $app,
			uuid => $uuid
		});
		($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $timestamp }); 
		my $sources = &subs::db_select('appointments', undef, { source_uuid => $uuid })->hashes;

		my %so_seen;
		my %child_apps;
		foreach my $so ( @{$sources} ) {
			next if $so_seen{ $so->{'uuid'} }++;
			push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
			if ( $so->{'type'} eq 'start' ) {
				&subs::db_update('appointments', { type => 'start', timestamp => $timestamp, duration => $duration, server_time => $server_time }, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'}, app => $so->{'app'} });
				$child_apps{ $so->{'app'} } = 1;
				&budget_runner($so->{'app'});
				&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
			}
		}
		&subs::source_header_printer([ keys %child_apps ], $timestamp);
	}
	elsif ($type eq 'pause') {
		my $last = &subs::db_select('appointments', undef, {app => $app, type => 'start' })->hashes->[0];
		my $timestamp1 = $last->{'timestamp'};
		$uuid = $last->{'uuid'};
		$duration = $timestamp - $timestamp1;
		&subs::db_update('appointments', {
			unit => $unit,
			project => $project,
			type => 'pause',
			status => 'paused',
			duration => $duration,
			timestamp => $timestamp,
			%{$end_notes_update},
			server_time => $server_time,
			%{$file_update},
			warranty => $warranty,
			source => $source,
			seen => $seen
		}, {
			app => $app,
			uuid => $uuid
		});
		my $sources = &subs::db_select('appointments', undef, { source_uuid => $uuid })->hashes;

		my %so_seen;
		my %child_apps;
		foreach my $so ( @{$sources} ) {
			next if $so_seen{ $so->{'uuid'} }++;
			push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
			&subs::db_update('appointments', { type => 'pause', status => 'paused', timestamp => $timestamp, duration => $duration, server_time => $server_time }, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'}, app => $so->{'app'} });
			$child_apps{ $so->{'app'} } = 1;
			&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
		}
		&subs::source_header_printer([ keys %child_apps ], $timestamp);
	}
	elsif ($type eq 'resume') {
		# The row is named by the pre-relay resolution above. A resume that names
		# none (an older caller) still reopens the newest stop/cancel.
		my $old = [];
		if ($target_uuid) {
			$old = &subs::db_query('select * from appointments where app = ? and uuid = ? and (type = ? or type = ?) order by timestamp DESC LIMIT 1', $app, $target_uuid, 'stop','cancel')->hashes;
		}
		else {
			$old = &subs::db_query('select * from appointments where app = ? and (type = ? or type = ?) order by timestamp DESC LIMIT 1', $app, 'stop','cancel')->hashes;
		}
		# A named row this machine has not synced yet is left alone: the row's
		# own newer copy will arrive by sync. Guessing "the newest" here could
		# reopen a different session.
		if ($old->[0]) {
			$duration = $c->param('duration') =~ /[a-z0-9A-Z]/ ? (abs($duration) * -1) : $timestamp - $old->[0]->{'timestamp'};
			$uuid = $old->[0]->{'uuid'};
			&subs::intelligent_automation_toggle({ appt_uuid => $uuid, app => $old->[0]->{'app'}, 'state' => 'on', timestamp => $old->[0]->{'timestamp'} });
			&subs::db_update('appointments', {
					type => 'start',
					status => 'start',
					%{$notes_update},
					unit => $unit,
					project => $project,
					server_time => $server_time,
					%{$file_update},
					'pos' => $pos,
					warranty => $warranty,
					source => $source,
					seen => $seen,
					duration => ((abs $duration) * -1),
					stop_timestamp => $c->param('duration') =~ /[a-zA-Z0-9]/ ? $old->[0]->{'timestamp'} + abs(&duration_read($c->param('duration')) // 0) : undef,
					stop_seen => undef
				}, {
					app => $app,
					uuid => $old->[0]->{'uuid'}
				}
			);
			($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $timestamp }); 
			my $sources = &subs::db_select('appointments', undef, { source_uuid => $uuid })->hashes;

			my %so_seen;
			my %child_apps;
			foreach my $so ( @{$sources} ) {
				next if $so_seen{ $so->{'uuid'} }++;
				push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
				if ( $so->{'type'} eq 'stop' || $so->{'type'} eq 'cancel' ) {
					&subs::db_update('appointments', { type => 'start', server_time => $server_time }, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'}, app => $so->{'app'} });
					$child_apps{ $so->{'app'} } = 1;
					&budget_runner($so->{'app'});
					&subs::intelligent_automation_toggle({ appt_uuid => $so->{'uuid'}, app => $so->{'app'}, 'state' => 'on', timestamp => $so->{'timestamp'} });
					&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
				}
			}
			&subs::source_header_printer([ keys %child_apps ], $timestamp);
		}
	}
	elsif ($type eq 'add') {
		$project = eval { return &subs::db_select('settings', ['app'], { setting => 'pos', value => 'project' },{-desc => 'timestamp'})->hash->{app} } || 'project';
		my $counter = &subs::db_query('select count(*) from appointments where app=?', $app);
		my $count = $counter->hash->{'count(*)'};
		if ($count == 0 && 1 == 0) {
			&subs::db_insert('appointments', {
				app => $app,
				timestamp => $timestamp,
				unit => $unit,
				project => $project,
				type => 'config',
				status => $status,
				duration => $duration,
				start_notes => $notes,
				server_time => $server_time,
				file => $file,
				'pos' => $pos,
				warranty => $warranty,
				source => $source,
				uuid => $uuid,
				seen => $seen,
				browser_tab_id => $browser_tab_id
			});
			$returner->{'added'} = 'yes';
		}
	}
	elsif ($type eq 'camera') {
		my $jdata = encode_json { camera => $camera };

		my $data = {
			app => $app,
			timestamp => $timestamp,
			project => $project,
			unit => $unit,
			type => 'image',
			data => $jdata,
			notes => $notes,
			server_time => $server_time,
			file => '[]',
			duration => '5000',
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			uuid => $uuid,
			seen => $seen,
			browser_tab_id => $browser_tab_id
		};
		&subs::db_insert('appointments', $data);
		($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $timestamp }); 
		if ($seen eq 'yes' && $capture_here) {
			my ($file,$ocr) = &take_picture($c,{ timestamp => $timestamp, camera => $camera, uuid => $uuid });
		}
	}
	elsif ($type eq 'scan') {
		my $scandata = {
			timestamp => $timestamp,
			feed => $feed,
			uuid => $uuid,
			app => $app,
			source => $source
		};
		my $jdata = encode_json $scandata;
		&subs::db_insert('appointments', {
			app => $app,
			timestamp => $timestamp,
			project => $project,
			unit => $unit,
			type => 'scan',
			start_notes => $notes,
			server_time => $server_time,
			file => '[]',
			data => $jdata,
			duration => '-10s',
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			uuid => $uuid,
			seen => $seen,
			browser_tab_id => $browser_tab_id
		});
		($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $timestamp }); 
		if ($seen eq 'yes' && $capture_here) {
			my $file = &scan($c, $scandata);
		}
	}
	elsif ($type eq 'telephone') {
		&subs::db_insert('appointments', {
			app => $app,
			timestamp => $timestamp,
			project => $project,
			unit => $unit,
			type => 'telephone',
			start_notes => $notes,
			server_time => $server_time,
			file => $file,
			duration => '5000',
			'pos' => $pos,
			warranty => $warranty,
			source => $source,
			uuid => $uuid,
			seen => $seen,
			browser_tab_id => $browser_tab_id
		});
		my $send_telephone = &send_telephone($app,$c->param('notes'));
	}
	else {
		my $already_running = 0;
		if ($type eq 'note') {
			my $began = &subs::db_query('select * from appointments where app=? and (type=? or type=?) and timestamp <= ? and timestamp < ? order by timestamp desc limit 1',$app,'record','start',$timestamp,&subs::rightNow());
			my $old_appts = $began->hashes;
			foreach my $o ( @{$old_appts} ) {
				my $n = &subs::note_decrypter(&subs::session_suds($c), $o->{'notes'}, $o->{'ost'});
				$n .= "\n" if $n =~ /[a-zA-Z0-9.,]/gi;
				$n .= &subs::note_decrypter(&subs::session_suds($c), $notes);
				$notes = &subs::note_encrypter(&subs::session_suds($c), $n);
				$already_running = $o->{'uuid'};
			}
		}
		if ($type eq 'video' || $type eq 'audio' || $type eq 'screen') { $seen = undef; }
		my $stop_timestamp = $c->param('duration') =~ /[a-zA-Z0-9]/ ? $timestamp - ((abs $duration) * -1) : undef;

		if ($type eq 'command' || $type eq 'kill') {
			my $settings = &subs::settings_grabber({ app => $app });
			if ($type eq 'command') {
				&subs::run_command($app, $settings->{'command'});
			}
			elsif ($type eq 'kill') {
				&subs::run_command($app, $settings->{'kill'});
			}
		}

		if ($already_running eq 0) {
			my $db_data = {
				app => $app,
				timestamp => $timestamp,
				project => $project,
				unit => $unit,
				type => $type,
				start_notes => $notes,
				server_time => $server_time,
				file => $file,
				duration => '5000',
				'pos' => $pos,
				warranty => $warranty,
				source => $source,
				uuid => $uuid,
				seen => $seen,
				stop_timestamp => $stop_timestamp,
				browser_tab_id => $browser_tab_id
			};
			&subs::db_insert('appointments', $db_data);
		}
		else {
			&subs::db_update('appointments', { notes => $notes, server_time => &subs::rightNow() }, { app => $app, uuid => $already_running });
			$uuid = $already_running;
		}

	}
	undef @appointments;


	if ($measure_is_open eq 'true' && ($type eq 'start' || $type eq 'usual')) {
		&appt_measure_writer($c,{ app => $app, uuid => $uuid, timestamp => $timestamp });
	}
	&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $uuid .'\');'});

	# The header is already on the wire. A schedule the press typed itself answers
	# in the reply (it may need a clarifying question); the app's usual schedule
	# only writes future repeats, so it runs in its own process.
	if ($c->param('schedule')) {
		my $schedule = &schedule_maker($c, $c->param('schedule'), $timestamp);
		$returner->{'schedule'} = $schedule if $schedule;
		$returner->{'schedule_ask'} = $schedule->{'question'} if $schedule && $schedule->{'ask'};
	}
	elsif ($usual_schedule) {
		my $fork_c = $c;
		my $fork_ts = $timestamp;
		my $fork_schedule = $usual_schedule;
		&subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			&schedule_maker($fork_c, $fork_schedule, $fork_ts);
		}, { name => 'schedule repeats' });
	}

	my $todays_date = localtime()->strftime('%A %B %d %Y');
	my $todays_time = localtime()->strftime('%I:%M%P');

#	$appts->{'__stash'}->{'header'} = 'no';
	my $commander;
#	$commander = &subs::run_command($app,$appts->{$app}->{'setting'}->{'record'}) if $appts->{$app}->{'setting'}->{'record'} && $type =~ /record/;
#	&Websocket::send('server', { app => $app, console => &subs::setting_grabber({ app => $app, setting => 'record' }), device => $device, timestamp => $timestamp }) unless $type eq 'stop';
#	&Websocket::send('server', { app => $app, console => &subs::setting_grabber({ app => $app, setting => 'kill' }), device => $device, timestamp => $timestamp }) unless $type eq 'stop';
#	&Websocket::send('server', { app => $app, console => &subs::setting_grabber({ app => $app, setting => 'command' }), device => $device, timestamp => $timestamp }) if $type eq 'command';
#	$commander = &subs::run_command($appts->{$app}->{'setting'}->{'command'}) if $appts->{$app}->{'setting'}->{'command'} && $type =~ /command/;
#	&subs::cache_delete({ app => $app, context => 'template' });

	# The header is already rendered, cached and pushed. The window render is the
	# slow half: a caller that does not read `cv` gets it as a fork that draws and
	# caches the window in the background, so the press no longer waits for it (nor
	# for the default model and option sessions below it).
	my $cv;
	$seg->('branch');
	if ($wants_cv) {
		$cv = &centre_view_grabber({ c => $c, app => $app, timestamp => $timestamp, header => $appt_header, appts => $header_appts, cached => 'no' });
		$returner->{'cv'} = $cv;
	}
	else {
		my $fork_app = $app;
		my $fork_header = $appt_header;
		my $fork_appts = $header_appts;
		&subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			&centre_view_grabber({ c => $c, app => $fork_app, timestamp => &subs::rightNow(), header => $fork_header, appts => $fork_appts, cached => 'no' });
		}, { name => 'centre view' });
	}
	&budget_runner($app);
	&padlock_time_extender($c);
	$returner->{'uuid'} = $uuid;
	# The header the press just changed, so the page that pressed it can show the
	# new state even when the live socket is the thing that was asleep.
	$returner->{'header'} = $appt_header if defined $appt_header && length $appt_header;
	unless ($c->param('account') && $c->param('account') eq 'gallery' && &subs::setting_grabber({ app => 'me', setting => 'gallery_appts' }) eq 'off' ) {
	#	&Websocket::send('tab', { app => $app, window => $cv, timestamp => $timestamp });
	}
	# Sealing an app's attached media walks its files, and the reply carries none
	# of them: it is work for a fork, not for the press's wait. Skipped outright
	# when the app does not seal its media (file_encrypter's own no-op), so the
	# common press does not pay for a fork it would never use.
	if (&subs::setting_grabber({ app => $app, setting => 'enc' }) eq 'on') {
		my $suds = &subs::session_suds($c);
		&subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			&subs::file_encrypter({ app => $app, suds => $suds });
		}, { name => 'reset file encrypt' });
	}
	&subs::appointment_theme_push() if ($theme_movement =~ /^(?:start|stop|record|cancel|resume|pause|delay)$/);
	$seg->('tail');
	$log->info('reset segments ' . ($type // '?') . ' ' . $app . ': ' . join(' ', @seg_times));
	return $returner;
}

1;
