package Manager;

# Manager helpers, part 5 of 37. Moved out of Manager.pl so a
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

sub appointment_writer($c,$app) {
	my ($appt_header,$db_written);
	$c = &subs::controller_builder() unless $c;
	# remembered before the stop/record branches rewrite type: only a start or a
	# stop can change which appointment (if any) owns the desktop theme
	my $theme_movement = $app->{'type'};
#	&subs::cache_delete({ app => $app->{'app'}, context => 'template' });
	$app->{'server_time'} = $app->{'server_time'} || $c->param('server_time') || &subs::rightNow();
	$app->{'timestamp'} = $app->{'server_time'} unless $app->{'timestamp'};
	$app->{'browser_tab_id'} = $c->param('browser_tab_id') if $c->param('browser_tab_id') && !$app->{'browser_tab_id'};
	my $remote_address = $app->{'remote_address'};
	delete $app->{'remote_address'};
	# The board that produced a switch/button event already drove its own
	# outputs locally; this tells intelligent_automation_toggle not to echo the
	# command back to that same chip. It is not a column, so keep it out of the
	# insert/update below.
	my $source_chip_id = $app->{'source_chip_id'};
	delete $app->{'source_chip_id'};
	# A default model/option session is a child write: the press that started it
	# already forked the centre view and ran the house bookkeeping, so the child
	# only writes its row. Without this the window render forks once per child and
	# each fork re-reads and re-renders the whole app window in a 200-380 MB
	# process, which pins the phone's CPU. A flag, not a column - keep it out of
	# the insert/update below, like remote_address and source_chip_id above.
	my $quiet_child = $app->{'quiet_child'};
	delete $app->{'quiet_child'};
	my $timestamp = $app->{'timestamp'};
	my $server_time = $app->{'server_time'};
	$app->{'device'} = $device;
	# A media press names the source and the machine that captures on the press
	# itself. They are not appointment columns: keep them out of the insert and
	# update below (like remote_address and source_chip_id) and let the record
	# branch write them into the row's data JSON, where the Alarm loop reads them.
	my $pressed_recorder = delete $app->{'recorder'};
	my $pressed_machine = delete $app->{'machine'};
	my $pressed_camera = delete $app->{'camera'};
	# a stop that names its session (managerReset sends the open session's uuid) is
	# remembered before the uuid is minted, so the stop closes exactly that row
	my $stop_target = $app->{'uuid'};
	$app->{'uuid'} = $app->{'uuid'} || &subs::random_string_creator(90);
	my ($db,$database,$sql) = &subs::database_grabber();
	my $init = &subs::setting_initializer($app->{'app'},$app->{'timestamp'});
	$app->{'app'} = $init->{'app'};
	($app->{'app'},undef) = &subs::typesetter($app->{'app'});
	my $settings = &subs::settings_grabber({ app => $app->{'app'} });
	# A capture row belongs to the Alarm loop: the machine named in its data claims
	# it and starts the recorder. Stamped seen here it would never be claimed, so
	# video/audio/screen rows stay unseen; a press that names system audio stays
	# unseen too, so the chosen machine's Alarm runs record_audio there. A plain
	# record press that merely follows the app's setting keeps the inline start.
	my $named_source = &record_source_param($pressed_recorder);
	my $capture_source = (($app->{'type'} || '') eq 'record')
		? ($named_source || $settings->{'record'} || '')
		: '';
	if ($capture_source =~ /^(?:video|video_front|audio|screen)$/
		|| ($named_source && $named_source eq 'system')) {
		$app->{'seen'} = undef;
	}
	elsif ($app->{'timestamp'} <= $app->{'server_time'} + 1000) {
		$app->{'seen'} = 'yes';
	}
	# Write the row complete. A media row that syncs before its data is set would
	# reach another machine with no machine/recorder in it, and that machine's
	# Alarm would claim the capture too. The press's own source and machine go on
	# the row before the insert; the record branch below writes the same value.
	if (($app->{'type'} || '') eq 'record' && $named_source) {
		my $preset = { recorder => $named_source, machine => ($pressed_machine || '') };
		$preset->{'camera'} = $pressed_camera if defined $pressed_camera && $named_source =~ /^video/;
		$app->{'data'} = encode_json $preset;
	}
	if ($app->{'type'} eq 'usual' || $app->{'type'} eq 'start' || $app->{'type'} eq 'record') {
		&subs::db_insert('appointments', $app);
		$appt_header = &subs::appt_header_printer({ app => $app->{'app'}, timestamp => $app->{'timestamp'} });
		$db_written = 1;
		my ($model,$options);
		($model,$options,$app->{'model'},$app->{'options'}) = &subs::usual_appointment_maker($app,$settings);
		if ($model->{'unit'} && !$app->{'unit'}) {
			$app->{'unit'} = $model->{'unit'};
		}
		if ($model->{'quantity'} && !$app->{'quantity'}) {
			$app->{'quantity'} = $model->{'quantity'};
		}
	}

	my $warranty_holder = $app->{'timestamp'} > $app->{'server_time'} ? $app->{'timestamp'} : $app->{'server_time'};
	$app->{'warranty'} = $app->{'warranty'} || &warranty_resolve(($init->{'warranty'} || '-10y'), $warranty_holder, 1) || &subs::ago_calc(($init->{'warranty'} || '-10y'), $warranty_holder);
	$app->{'project'} = $settings->{'t_project'} unless $app->{'project'};
	$app->{'pos'} = $settings->{'pos'} unless $app->{'pos'};


	if ($app->{'type'} eq 'record') {
		# a press may name the source on the row itself (see manager_reset); a
		# scheduled or synced record keeps the app's setting
		my $recording_type = &record_source_param($pressed_recorder)
			|| &subs::setting_grabber({ app => $app->{'app'}, setting => 'record' })
			|| 'system';
		my $dat = { recorder => $recording_type, machine => ($pressed_machine || '') };

		if ($recording_type eq 'video') {
			$app->{'seen'} = undef;
			$dat->{'camera'} = $pressed_camera if defined $pressed_camera;
		}
		elsif ($recording_type eq 'audio') {
			$app->{'seen'} = undef;
		}
		elsif ($recording_type eq 'screen') {
			$app->{'seen'} = undef;
		}
		elsif ($recording_type eq 'video_front') {
			$app->{'seen'} = undef;
			$dat->{'camera'} = defined $pressed_camera ? $pressed_camera : 1;
		}
		elsif ($recording_type eq 'security') {
			&record_video({ app => $app->{'app'}, uuid => $app->{'uuid'}, timestamp => $app->{'timestamp'} }) if $app->{'seen'} eq 'yes';
		}
		else {
			&record_audio({ app => $app->{'app'}, uuid => $app->{'uuid'}, timestamp => $app->{'timestamp'} }) if $app->{'seen'} eq 'yes';
		}
		$app->{'data'} = encode_json $dat;
	}



	if ($app->{'uuid'} && 0) {
		my $pa = &subs::db_query('select * from appointments where uuid=?', $app->{'uuid'});
		my $prev = $pa->hashes->[0];
		if ($prev->{'app'}) {
			my $duration = ($prev->{'duration'} + (&subs::rightNow() - $prev->{'timestamp'}));
#			&subs::db_query('update appointments set duration=?, timestamp=? where uuid=?', $duration, $app->{'timestamp'}, $app->{'uuid'});
			&subs::db_update('appointments', { duration => $duration, timestamp => $app->{'timestamp'} }, { uuid => $app->{'uuid'}, app => $app->{'app'} });
		}
		else {
			&subs::db_insert('appointments', $app);
			$db_written = 1;
		}
	}
	if ($app->{'type'} eq 'stop') {
		# A stop's own timestamp is the moment it was pressed. One that is hours old
		# is not a press - it is a machine coming back and flushing actions it queued
		# while it was away, and applying it re-closes sessions the person stopped
		# long ago (their rows get a fresh server_time and read as just-stopped, and
		# the catch-up sweep below can close several of them at once). Those replays
		# are dropped: the session simply stays open for a live stop, which is the
		# harmless failure.
		# A stop that names its session is safe to apply however late it arrives: it
		# closes that one row and nothing else. The replay guard stays for a stop that
		# names none, where a late copy could still sweep up sessions it should not.
		my $ages_ms = &subs::rightNow() - (0 + ($app->{'timestamp'} || 0));
		if (!$stop_target && $app->{'timestamp'} && $ages_ms > &subs::stale_action_ms()) {
			$log->info('stale stop ignored for ' . $app->{'app'} . ': pressed ' . int($ages_ms / 60000) . ' minutes ago (a replayed action)')
				if $log;
				return {};
		}
		# Close the session the stop names and only it; a stop that names none - or one
		# this machine has not synced - closes the oldest open session. Resolved by the
		# same helper manager_reset uses, so both writers stop one and the same row
		# instead of each sweeping up every open session for the app.
		my $stop_row = &subs::stop_target_row($app->{'app'}, $stop_target, $app->{'timestamp'});
		return {} unless $stop_row;
		my $appts = [ $stop_row ];
		foreach my $appt ( @{$appts} ) {
			$app->{'type'} = 'stop';
			$app->{'duration'} = $appt->{'timestamp'} - $app->{'timestamp'};
			$app->{'uuid'} = $appt->{'uuid'};
			# A capture that ran on another machine is stopped there, not here. The
			# stop is relayed before the row is closed below, so the named machine
			# still finds its own copy open and sends its own stop. The row's data
			# names both the recorder and the machine (see the record branch above).
			my $stop_data = ($appt->{'type'} || '') eq 'record'
				? (eval { return decode_json $appt->{'data'} } || {})
				: {};
			my $capture_machine = $stop_data->{'machine'} || '';
			my $stop_remote = ($capture_machine ne '' && $capture_machine ne &subs::signatorial_designer()) ? 1 : 0;
			if ($stop_remote) {
				&subs::destination_relay({
					destination => $capture_machine,
					app => $app->{'app'},
					movement => 'stop',
					timestamp => $app->{'timestamp'},
					uuid => $appt->{'uuid'},
					recorder => $stop_data->{'recorder'} || '',
					camera => $stop_data->{'camera'},
					machine => $capture_machine
				});
			}
			&subs::db_update('appointments', { stop_timestamp => $app->{'timestamp'}, stop_seen => 'yes', duration => $app->{'duration'}, type => $app->{'type'}, server_time => &subs::rightNow() }, { uuid => $appt->{'uuid'}, app => $app->{'app'} });
			$db_written = 1;
			# The start armed a scheduled stop job on the boards for this
			# session. An early stop - or a stop followed by a renewal that
			# starts a new session - must cancel it, or the abandoned job turns
			# the board off at a time the person no longer meant. The deleter
			# matches a board's jobs by the session uuid. It runs before the
			# record branches, which may `next`.
			&embedded_app_deleter({ appt_uuid => $appt->{'uuid'} });
			$appt_header = &subs::appt_header_printer({ app => $app->{'app'}, timestamp => $app->{'timestamp'} });
			my $recording_type = &subs::setting_grabber({ app => $app->{'app'}, setting => 'record' }) || 'system';
			if ($appt->{'type'} eq 'record') {
				my $dat = $stop_data;

				if ($dat->{'recorder'} eq 'security') {
					if ($app->{'seen'} eq 'yes') {
						&record_video_stop({ app => $app->{'app'}, timestamp => $appt->{'timestamp'}, uuid => $appt->{'uuid'} }) if $appt->{'uuid'} && !$stop_remote;
						next;
					}
					else { $app->{'type'} = 'record'; };
				}
				elsif ($dat->{'recorder'} eq 'system') {
					if ($app->{'seen'} eq 'yes') {
						&record_audio_stop({ app => $appt->{'app'}, timestamp => $appt->{'timestamp'}, uuid => $appt->{'uuid'} }) if $appt->{'uuid'} && !$stop_remote;
						next;
					}
					else { $a->{'type'} = 'record'; };
				}
				elsif (!$stop_remote) {
					&Websocket::send('music', { console => 'jpStop(\'' . $appt->{'app'} . '\',\'' . $dat->{'recorder'} . '\',\'' . $appt->{'uuid'} . '\');' });
				}
			}



			&subs::intelligent_automation_toggle({ appt_uuid => $app->{'uuid'}, app => $app->{'app'}, 'state' => 'off', timestamp => $app->{'timestamp'}, remote_address => $remote_address, source_chip_id => $source_chip_id });
			my $sources = &subs::db_select('appointments', undef, { source_uuid => $app->{'uuid'} })->hashes;
			my $options = eval { return decode_json $appt->{'options'} } || [];
			my $model = eval { return decode_json $appt->{'model'} } || {};
			push @{$options}, $model if $model->{'uuid'};

			my %so_seen;
			my %child_apps;
			foreach my $so ( @{$sources} ) {
				next if $so_seen{ $so->{'uuid'} }++;
				push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
				if ( $so->{'type'} eq 'start' ) {
					my $dur = $so->{'timestamp'} - $timestamp;


					my @current_option = grep { $_->{'name'} eq $so->{'app'} } @{$options};
					my $co = $current_option[0];
					my $so_data = {
						duration => $dur,
						server_time => $server_time,
					};
					my $ts = $timestamp;
					if ($co->{'delay_stop'}) {
						my $t = &subs::time_abbrev_translator($co->{'delay_stop'});
						$ts = $ts + $t;
						$dur = $dur + $t;
						$so_data->{'duration'} = $dur;
						$so_data->{'stop_timestamp'} = $ts;
					}
					$so_data = { stop_timestamp => $ts, duration => $dur, server_time => $server_time };
					if ($ts <= &subs::rightNow()) {
						$so_data->{'type'} = $app->{'type'};
						$so_data->{'stop_seen'} = 'yes';
						$so_data->{'stop_timestamp'} = $app->{'timestamp'}
					}

					&subs::db_update('appointments', $so_data, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'}, app => $so->{'app'} });
					$child_apps{ $so->{'app'} } = 1;
					&budget_runner($so->{'app'});
					&subs::intelligent_automation_toggle({ appt_uuid => $so->{'uuid'}, app => $so->{'app'}, 'state' => 'off', timestamp => $ts, remote_address => $remote_address, source_chip_id => $source_chip_id });
					&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
				}
			}
			&subs::source_header_printer([ keys %child_apps ], $timestamp);
			&subs::db_update('appointments', { stop_timestamp => $app->{'timestamp'}, stop_seen => 'yes', duration => $app->{'duration'}, type => $app->{'type'}, server_time => &subs::rightNow() }, { uuid => $appt->{'uuid'}, app => $app->{'app'} });
		}
	}
	elsif ($app->{'type'} eq 'image' || $app->{'type'} eq 'video') {
		my $appt = &subs::db_query('select type,file,timestamp,uuid from appointments where app = ? and timestamp <= ? and (type=? or type=?)', $app->{'app'}, $app->{'timestamp'}, 'start', 'record')->hashes->[0];
		my $uuid = $appt->{'uuid'};
		if ($uuid) {
			$app->{'type'} = $appt->{'type'};
			$app->{'timestamp'} = $appt->{'timestamp'};
			$app->{'uuid'} = $uuid;
			my $file = eval { return decode_json $appt->{'file'} } || [];
			my $new_file = eval { return decode_json $app->{'file'} } || [];
			push @{$file}, @{$new_file};
			$app->{'file'} = encode_json $file;
			&subs::db_update('appointments', $app,
			{
				uuid => $uuid,
				app => $app->{'app'}
			});
		} else {
			&subs::db_insert('appointments', $app);
		}
	}
	else {
		if ($app->{'type'} eq 'start' || $app->{'type'} eq 'record') {
			&subs::intelligent_automation_toggle({ appt_uuid => $app->{'uuid'}, app => $app->{'app'}, 'state' => 'on', timestamp => $app->{'timestamp'}, remote_address => $remote_address, source_chip_id => $source_chip_id });
			if ($app->{'stop_timestamp'}) {
				&subs::intelligent_automation_toggle({ appt_uuid => $app->{'uuid'}, app => $app->{'app'}, 'state' => 'off', timestamp => $app->{'stop_timestamp'}, remote_address => $remote_address, source_chip_id => $source_chip_id });
			}

			if ($app->{'type'} eq 'record') {
				my $jdata;

				my $recording_type = &record_source_param($pressed_recorder)
					|| &subs::setting_grabber({ app => $app->{'app'}, setting => 'record' })
					|| 'system';
				my $dat = { recorder => $recording_type, machine => ($pressed_machine || '') };
				if ($recording_type eq 'video') {
					$app->{'seen'} = undef;
					$dat->{'camera'} = $pressed_camera if defined $pressed_camera;
				}
				elsif ($recording_type eq 'audio') {
					$app->{'seen'} = undef;
				}
				elsif ($recording_type eq 'screen') {
					$app->{'seen'} = undef;
				}
				elsif ($recording_type eq 'video_front') {
					$app->{'seen'} = undef;
					$dat->{'camera'} = defined $pressed_camera ? $pressed_camera : 1;
				}
				elsif ($recording_type eq 'security') {
					&record_video({ app => $app->{'app'}, uuid => $app->{'uuid'}, timestamp => $app->{'timestamp'} }) if $app->{'seen'} eq 'yes';
				}
				else {
					&record_audio({ app => $app->{'app'}, uuid => $app->{'uuid'}, timestamp => $app->{'timestamp'} }) if $app->{'seen'} eq 'yes';
				}
				$app->{'data'} = encode_json $dat;

			}
		}
		if ($db_written == 1) {
			# The row was written at the top. Only the fields this maker and the
			# record branch produce are ours to update: rewriting the whole row here
			# put `type` and `stop_timestamp` back from a start (or record) that a
			# stop had closed while the default model/option chain was still running,
			# leaving the child session visibly open forever.
			my %maker_fields = map { $_ => $app->{$_} } grep { defined $app->{$_} } qw/data model options unit quantity manufacturer seen/;
			&subs::db_update('appointments', { %maker_fields, app => $app->{'app'}, server_time => &subs::rightNow() }, { app => $app->{'app'}, uuid => $app->{'uuid'} });
		} else {
			&subs::db_insert('appointments', $app);
		}
	}
	# An invoice gets its own receive address as soon as it is written, so a
	# print or a public page already names it. Idempotent: a re-save keeps the
	# address the invoice already owns.
	if (($app->{'type'} || '') eq 'invoice' && ($app->{'uuid'} || '') ne '') {
		my $wallet = &subs::crypto_invoice_wallet('BTC');
		&subs::crypto_invoice_address({ app => $wallet->{'app'}, invoice => $app->{'uuid'} }) if $wallet;
	}
	# a transaction with an account is a money move, so it is written to the
	# warehouse ledger too; the budget and the warehouse then read one store
	&warehouse_money_mirror($app);
	# The row, the hardware toggle and the theme push are the child's; the window
	# render is the press's to do once. The three tab pushes below are socket
	# writes, not renders, and they are what makes the new child appear on the
	# screen at once - they stay for a quiet child too. A press then forks the
	# window once, not once per child, and still shows every child immediately.
	&Websocket::send('tab', { console => 'calculator();' });
	&Websocket::send('tab', { console => 'appointmentDetailGrabber(' . encode_json($app->{'app'}) . ',' . encode_json($app->{'uuid'}) . ');' });
	&Websocket::send('tab', { console => 'continent_record({"uuid":' . encode_json($app->{'uuid'}) . ',"app":' . encode_json($app->{'app'}) . ',"purpose":"app","timestamp":' . encode_json($app->{'timestamp'}) . ',"navigation":"once"});' });
	# The header went out as soon as the row was written. The window render is the
	# slow half; fork it so the writer - and the default model and option sessions
	# it starts - does not wait for a full redraw.
	my $centre_app = &subs::unformat_name($app->{'app'});
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		&centre_view_grabber({ c => $c, app => $centre_app, timestamp => &subs::rightNow(), cached => 'no' });
	}, { name => 'centre view' }) unless $quiet_child;
	&budget_runner($app->{'app'}) unless $quiet_child;
	# every run: a scope on the each_run cadence queues an evaluation as soon as it
	# has run, throttled by a Minion lock so a burst is one run, not many
	&subs::evaluation_run_trigger($app->{'app'}, $app) unless $quiet_child;

	if (1 == 1 && $app->{'app'}) {
		my $params = Mojo::Parameters->new(%{$app});
		$params = $params->to_string;
		my $url = '/manager/appointment/writer';# . $params;
		#&subs::subprocessor(sub {
		#	&remote_relay_request($c, { dissemination => 'yes', url => $url, params => $app, type => 'post', override => 'manual' });
		#});
	}

	&subs::appointment_theme_push() if (($theme_movement // '') =~ /^(?:start|stop|record)$/);

	# A future appointment in an app whose notification panel has Alarm on belongs
	# in the Clock. The hook is here rather than in the header render so a written
	# appointment creates (or moves) its one Clock alarm immediately, and an ordinary
	# past action costs nothing.
	if (($app->{'timestamp'} || 0) > &subs::rightNow() + 1000 && ($app->{'app'} || '') ne '') {
		eval { &subs::clock_appointment_sync($app); };
	}

	# A start or stop can change who is present. If that begins or ends a
	# lockdown, close the windows the rule no longer allows at once rather than
	# waiting for the next poll.
	eval { &subs::visibility_cache_clear(); &subs::lockdown_sweep({ force => 1 }) } if (($app->{'type'} || '') =~ /^(?:start|stop)$/);

	return $app;
}

sub homepage_maker($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	unless ($database) {
		$c->render(template => 'guest_layouts/denial');
	}
	my $articulation;
	my $port = $c->req->url->base->port;
	my $server_time = &subs::rightNow();
	my $name = &subs::setting_grabber({ app => 'me', setting => 'my_name' }) || 'Home';
	$articulation = &subs::db_query('select * from magazine where status=? and timestamp <= ? and cast(warranty as integer) >= cast(? as integer) order by timestamp DESC','publish', $server_time, $server_time);
	my $magazine_categories = [];# = $mag_cat->hashes;
	my $articles = $articulation->hashes;
	foreach my $mc ( @{$articles} ) {
		unless ( grep { $_->{'app'} eq $mc->{'category'} } @{$magazine_categories}) {
			push @{$magazine_categories}, { app => $mc->{'category'} };
		}
	}
	if ($c->param('category')) {
		$articulation = &subs::db_query('select * from magazine where status=? and category=? and timestamp <= ? and cast(warranty as integer) >= cast(? as integer) order by timestamp DESC','publish',$c->param('category'), $server_time, $server_time);
	}
	else {
		$articulation = &subs::db_query('select * from magazine where status=? and timestamp <= ? and cast(warranty as integer) >= cast(? as integer) order by timestamp DESC','publish', $server_time, $server_time);
	}
	$articles = $articulation->hashes;
	foreach my $mc ( @{$articles} ) {
		$mc->{'public'} = &subs::setting_grabber({ app => &subs::unformat_name($mc->{'title'}), setting => 'public' });
		# the homepage draws an article's markup raw, and articles sync between
		# machines: nothing reaches the public page without the allowlist
		$mc->{'content'} = &subs::article_html_clean($mc->{'content'});
	}
	my $ws_url = &ws_url_for($c, '/manager/ws');
	my $mail_ws_url = &ws_url_for($c, '/mail/ws');
	my $paperboy_url = &ws_url_for($c, '/observer/ws');
	my ($website,$header) = &website_preloader($c);
	my $my_name = $c->param('name') || &subs::setting_grabber({ app => 'me', setting => 'my_name' });
	my %data = (
		template => 'homepage',
		title => $name,
		articles => $articles,
		mail_ws_url => $mail_ws_url,
		paperboy_url => $paperboy_url,
		website => $website,
		header => $header,
		my_name => $my_name,
		magazine_categories => $magazine_categories,
		config => &subs::config_reader(),
		device => &subs::device_setter(),
		string => $random_caching_string,
		pseudonyms => &pseudonym_maker('manager',''),
		ws_url => $ws_url,
		advertise_watching => &subs::setting_grabber({ app => 'me', setting => 'advertise_watching' })
	);
	unless ($c->param('window_maker')) {
		$data{'layout'} = 'homepage';
	}
	my $homepage = $c->render_to_string(
		%data
	);
	return $homepage;
}

sub register_grabber($app) {
	my $timestamp = &subs::rightNow();
	my $returner = { timestamp => $timestamp };
	my $c = &subs::controller_builder();
	foreach my $att ( qw/model option option_category subcategory/ ) {
		$returner->{'html'} .= $c->render_to_string(
			template => 'pos/attributes',
			att => $att,
			app => $app
		);
	}
	return $returner
}

sub market_vendors {
	my $rows = &subs::db_query("select distinct(app) from settings where setting in ('pos','mab') and value = ? order by app", 'vendor')->hashes;
	return [ map { $_->{'app'} } @{$rows} ];
}

sub market_lists {
	my $raw = &subs::setting_grabber({ app => 'market', setting => 'market_lists' });
	my $lists = eval { return decode_json $raw } || {};
	return ref $lists eq 'HASH' ? $lists : {};
}

sub market_lists_for_menu {
	my $learned = &market_lists();
	my %menu = map { $_ => { name => ($learned->{$_}->{'name'} || &subs::format_name($_)) } } keys %{$learned};
	my $cats = &subs::db_query("select distinct(app) from settings where setting in ('pos','mab') and value = ?", 'category')->hashes;
	foreach my $c ( @{$cats} ) {
		my $app = $c->{'app'};
		$menu{$app} ||= { name => &subs::format_name($app) };
	}
	return \%menu;
}

sub market_list_key {
	my ($name) = @_;
	return '' unless defined $name && $name ne '';
	return &subs::unformat_name($name);
}

sub market_lists_touch_vendor {
	my ($key, $name, $vendor) = @_;
	return unless $key && $vendor;
	my $lists = &market_lists();
	$lists->{$key} ||= { name => ($name || $key), vendors => {} };
	$lists->{$key}->{'name'} = $name if $name;
	$lists->{$key}->{'vendors'} ||= {};
	$lists->{$key}->{'vendors'}->{$vendor} = 1;
	&subs::setting_setter({ app => 'market', setting => 'market_lists', value => encode_json($lists) });
}

sub market_barcodes {
	my $raw = &subs::setting_grabber({ app => 'market', setting => 'barcodes' });
	my $c = eval { return decode_json $raw } || {};
	return ref $c eq 'HASH' ? $c : {};
}

sub market_barcode_remember {
	my ($code, $map) = @_;
	return unless $code && ref $map eq 'HASH';
	my $c = &market_barcodes();
	$map->{'at'} = &subs::rightNow();
	$c->{$code} = $map;
	&subs::setting_setter({ app => 'market', setting => 'barcodes', value => encode_json($c) });
}

sub market_barcode_house {
	my ($code) = @_;
	my $row = &subs::db_query("select app from settings where setting in ('barcode','product_code') and value = ? limit 1", $code)->hashes->[0];
	return $row ? $row->{'app'} : undef;
}

sub market_barcode_lookup {
	my ($code) = @_;
	return undef unless $code =~ /^[0-9]{8,14}$/;
	my $ua = Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 6, request_timeout => 8);
	my $url = ($code =~ /^97[89][0-9]{10}$/) ? 'https://openlibrary.org/isbn/' . $code . '.json'
		: 'https://api.upcitemdb.com/prod/trial/lookup?upc=' . $code;
	my $res = eval { $ua->get($url)->result };
	return undef unless $res && $res->is_success;
	my $d = eval { return decode_json $res->body } || {};
	return ($code =~ /^97[89]/) ? $d->{'title'} : $d->{'items'}->[0]->{'title'};
}

sub market_barcode_consolidate {
	my ($raw) = @_;
	return { item => &subs::unformat_name($raw || ''), category => '', unit => '' } unless defined $raw && $raw ne '';
	my $cats = &subs::db_query("select distinct(app) from settings where setting in ('pos','mab') and value = ?", 'category')->hashes;
	my @cats = map { $_->{'app'} } @{$cats};
	my ($text) = &subs::ai_chat_role('chatbot_model', [
		{ role => 'system', content => 'You fold a shop product into JawnOS\'s own naming. Answer with strict JSON only.' },
		{ role => 'user', content => 'Product: "' . $raw . '"\nCategories we keep: ' . join(', ', @cats)
			. '\nReturn ONLY JSON: {"item":"a short house name, one or two words","category":"one of the categories above, or empty","unit":"the unit it is sold in: each, kg, g, L, mL, m, or empty"}.' },
	]);
	my ($json) = ($text || '') =~ /(\{.*\})/s;
	my $out = eval { return decode_json $json } || {};
	my $name = &subs::unformat_name($out->{'item'} || $raw);
	return { item => $name, category => ($out->{'category'} || ''), unit => ($out->{'unit'} || '') };
}

sub market_barcode_resolve {
	my ($code) = @_;
	return undef unless defined $code && $code =~ /\S/;
	my $cache = &market_barcodes();
	return $cache->{$code} if $cache->{$code} && $cache->{$code}->{'item'};
	my $house = &market_barcode_house($code);
	my $map;
	if ($house) {
		$map = { item => $house, category => '', unit => '', raw => $house };
	}
	else {
		my $raw = &market_barcode_lookup($code);
		$map = &market_barcode_consolidate($raw);
		$map->{'raw'} = $raw if defined $raw && $raw ne '';
	}
	&market_barcode_remember($code, $map);
	return $map;
}

sub market_here {
	my $row = &subs::db_query("select latitude, longitude from continent where latitude is not null and latitude != '' order by cast(timestamp as integer) desc limit 1")->hashes->[0];
	return ($row && $row->{'latitude'} && $row->{'longitude'}) ? { latitude => $row->{'latitude'} + 0, longitude => $row->{'longitude'} + 0 } : undef;
}

sub market_vendor_place {
	my ($vendor) = @_;
	return undef unless $vendor;
	my $hp = eval { return decode_json &subs::setting_grabber({ app => $vendor, setting => 'home_plate' }) } || {};
	return ($hp->{'latitude'} && $hp->{'longitude'}) ? { latitude => $hp->{'latitude'} + 0, longitude => $hp->{'longitude'} + 0 } : undef;
}

sub market_nearby_lists {
	my $here = &market_here();
	return [] unless $here;
	my $lists = &market_lists();
	my @near;
	foreach my $key ( sort keys %{$lists} ) {
		my $vendors = $lists->{$key}->{'vendors'} || {};
		foreach my $v ( sort keys %{$vendors} ) {
			my $place = &market_vendor_place($v);
			next unless $place;
			my $km = &help_distance_km($here->{'latitude'}, $here->{'longitude'}, $place->{'latitude'}, $place->{'longitude'});
			next unless defined $km && $km <= 0.3;
			push @near, { key => $key, name => ($lists->{$key}->{'name'} || $key), vendor => $v, distance_km => sprintf('%.3f', $km) };
			last;
		}
	}
	return \@near;
}

sub market_list {
	my $raw = &subs::setting_grabber({ app => 'market', setting => 'shopping_list' });
	my $list = eval { return decode_json $raw } || [];
	return [ grep { ref $_ eq 'HASH' && ($_->{'text'} || '') ne '' } @{$list} ];
}

sub market_save_list {
	my ($list) = @_;
	&subs::setting_setter({ app => 'market', setting => 'shopping_list', value => encode_json($list) });
	&Websocket::send('tab', { console => 'marketReload();' });
}

sub market_upgrade_need {
	my ($text) = @_;
	return 0 unless defined $text && $text ne '';
	my $want = &subs::unformat_name($text);
	my $key = lc $text;
	my $list = &market_list();
	my $upgraded = 0;
	foreach my $it ( @{$list} ) {
		next unless lc($it->{'text'} || '') eq $key || &subs::unformat_name($it->{'text'} || '') eq $want;
		if (($it->{'kind'} || '') ne 'need') { $it->{'kind'} = 'need'; $upgraded++; }
	}
	&market_save_list($list) if $upgraded;
	return $upgraded;
}

sub market_item_due {
	my ($text) = @_;
	return 0 unless defined $text && $text ne '';
	my $item = &subs::unformat_name($text);
	my $b = eval { &Manager::budget_calculator({ app => $item, circumstance => 'quantity' }) };
	return 0 unless $b && $b->{'fixed'} && ($b->{'circumstance'} || '') eq 'quantity' && defined $b->{'budgeted'} && $b->{'budgeted'} ne '';
	return (($b->{'value'} || 0) < ($b->{'budgeted'} || 0)) ? 1 : 0;
}

sub market_sweep_needs {
	my $list = &market_list();
	my $upgraded = 0;
	foreach my $it ( @{$list} ) {
		next unless &market_item_due($it->{'text'});
		if (($it->{'kind'} || '') ne 'need') { $it->{'kind'} = 'need'; $upgraded++; }
	}
	&market_save_list($list) if $upgraded;
	return $upgraded;
}

sub market_maker {
	my ($c) = @_;
	my $vendor = &subs::unformat_name($c->param('vendor')) || '';
	my $list = &market_list();
	foreach my $it ( @{$list} ) {
		$it->{'due'} = &market_item_due($it->{'text'});
	}
	my $nearby = &market_nearby_lists();
	return $c->render_to_string(
		template => 'market/market',
		list => $list,
		vendors => &market_vendors(),
		vendor => $vendor,
		lists => &market_lists_for_menu(),
		nearby => $nearby,
		receipts => &market_receipts_prepared(),
		scan_feeds => &market_scan_feeds()
	);
}

sub market_accounts {
	my $rows = &subs::db_query("select distinct(app) from settings where setting in ('pos','mab') and value = ? order by app", 'account')->hashes;
	return [ map { { app => $_->{'app'}, name => &subs::format_name($_->{'app'}) } } @{$rows} ];
}

sub measures_all {
	my $stored = eval { return decode_json &subs::setting_grabber({ app => 'measures', setting => 'measures' }) } || {};
	my %all = (%{$gb::measures}, %{$stored});
	# The house keeps its own copy of the built-in units, so a formula seeded
	# with a typo shadowed every later correction in gb.pl (one litre was a
	# hundred millilitres, one gram a ten-thousandth of a kilogram). Repair only
	# the exact old strings, and lift the misspelled `fomulas` list, so a formula
	# a person has edited is left alone.
	my %fix = (
		'm' => { 'x * .0001km' => 'x * .001km' },
		'mi' => { 'x * 1689.344m' => 'x * 1609.344m' },
		'L' => { 'x * 100mL' => 'x * 1000mL' },
		'g' => { 'x * .0001kg' => 'x * .001kg' },
		'mg' => { 'x * .0001g' => 'x * .001g' },
		'tsp' => { 'x * .667oz' => 'x * .16667oz', 'x * .0625cup' => 'x * .02083333cup' },
		'oz' => {},
	);
	foreach my $k ( keys %fix ) {
		next unless ref $all{$k} eq 'HASH';
		if ( ref $all{$k}->{'fomulas'} eq 'ARRAY' && ref $all{$k}->{'formulas'} ne 'ARRAY' ) {
			$all{$k}->{'formulas'} = delete $all{$k}->{'fomulas'};
		}
		my $fs = $all{$k}->{'formulas'};
		next unless ref $fs eq 'ARRAY' && scalar keys %{ $fix{$k} };
		$all{$k}->{'formulas'} = [ map { defined $fix{$k}->{$_} ? $fix{$k}->{$_} : $_ } @{$fs} ];
	}
	foreach my $k ( keys %all ) {
		next unless ref $all{$k} eq 'HASH';
		$all{$k}->{'name'} = $k unless defined $all{$k}->{'name'} && $all{$k}->{'name'} ne '';
	}
	return \%all;
}

1;
