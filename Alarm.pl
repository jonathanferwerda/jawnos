#!/usr/bin/perl

use strict;
no warnings;

package Alarm;

use Mojolicious::Lite;
use List::Util qw(shuffle);
use Mojo::Util qw/html_unescape term_escape/;
use Time::Duration;
use Date::Parse;
use Time::Piece;
use Crypt::Simple;
use File::Slurp;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::IOLoop;
use Data::Dumper;
use Time::HiRes qw(gettimeofday time);
use IO::Socket::UNIX;
require "./gb.pl";
require "./subroutines.pl";
require "./Manager.pl"; 
require "./Websocket.pl";
no warnings 'uninitialized';
my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
my $device = &subs::device_setter();
my $last_moment = &subs::rightNow();
my $last_paper_moment = &subs::rightNow();
our ($next_run,$alarm_id,$alarm_server);

sub alarm_clock() {
	my ($dber,$dot,$sql) = &subs::database_grabber('new');
	my ($alarm_count,$current_alarm);
	if ( $dber ) {
		my $timestamp = &subs::rightNow();
		$last_moment = &subs::rightNow();
		my $next_moment = $last_moment + (2 * 1000);
		my $query = &subs::db_query('select * from appointments where (timestamp <= ? and seen is null) or ((type = ? or type = ? or type = ? or type=? or type = ?) and stop_timestamp is not null and stop_timestamp <= ? and stop_seen is null ) order by timestamp',
			$next_moment, 'start','record','video','audio','screen',$next_moment);

		my $alarm = $query->hashes;
		my $duty_watch = &subs::db_query('select * from appointments where duties is not null and next_duty <= ? and next_duty is not null', $next_moment)->hashes;
		foreach my $dw ( @{$duty_watch} ) {

			my $duties = eval { return decode_json $dw->{'duties'} } || [];
			my @seen_duties;
			foreach my $duty ( @{$duties} ) {
				my $jduty = encode_json $duty;
				if ($duty->{'timestamp'} <= $next_moment) {
					push @{$alarm}, {
						app => $dw->{'app'},
						type => $duty->{'duty'},
						uuid => $dw->{'uuid'},
						data => $jduty,
						timestamp => $duty->{'timestamp'}
					};
					if ($duty->{'timestamp'} <= $timestamp) {
						push @seen_duties, $duty->{'duuid'};
					}
					&subs::appt_toggle_checker($dw->{'app'});
				}
			}
			if (scalar @seen_duties > 0) {
				foreach my $sd ( @seen_duties ) {
					@{$duties} = grep { $_->{'duuid'} && $_->{'duuid'} ne $sd } @{$duties};
				}
				my $next_duty = $duties->[0]->{'timestamp'};
				@{$duties} = grep { $_->{'duuid'} } @{$duties};
				@{$duties} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$duties};

				my $jduties = encode_json $duties;
				if (scalar @{$duties} == 0) {
					$jduties = undef;
				}
				&subs::db_update('appointments', { duties => $jduties, next_duty => $next_duty }, { app => $dw->{'app'}, uuid => $dw->{'uuid'} });
			}
		}
		$alarm_count = scalar @{$alarm};
		$current_alarm = scalar @{$alarm};
		if ($alarm_count > 0) {
			@{$alarm} = grep {
				my $a = $_; 
				(( $_->{'timestamp'} <= $timestamp && $_->{'seen'} ne 'yes' ) ||
				( $_->{'stop_timestamp'} && $_->{'stop_timestamp'} <= $timestamp && $_->{'stop_seen'} ne 'yes' &&  grep { $a->{'type'} eq $_ } qw/start video audio screen record/) )
			} @{$alarm};
			$current_alarm = scalar @{$alarm};
			my $interval = 'second';
			my $default_warranty = &subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d';

			my $warranty = &subs::ago_calc($default_warranty, $timestamp);
			my $t = &subs::time_span($interval, $timestamp);
			my $t1 = ($timestamp - $t);
			foreach my $a ( @{$alarm} ) {
#				&subs::db_query('update appointments set seen = ? where uuid=?', 'yes',$a->{'uuid'});
				&subs::db_update('appointments', { seen => 'yes' }, { app => $a->{'app'}, uuid => $a->{'uuid'} });
			#	&subs::cache_delete({ app => $a->{'app'}, context => 'template' });
				my $type = $a->{'type'};

				if ($a->{'stop_timestamp'} && $a->{'stop_timestamp'} <= $timestamp && grep { $a->{'type'} eq $_ } qw/start video audio screen record/) {

					if ($a->{'type'} eq 'start' || $a->{'type'} eq 'record') {
						if ($a->{'type'} eq 'record') {
							my $data = eval { return decode_json $a->{'data'} } || {};
							my $recording_type = &subs::setting_grabber({ app => $a->{'app'}, setting => 'record' }) || 'system';
							if ($data->{'recorder'} eq 'security') {
								&Manager::record_video_stop({ app => $a->{'app'}, uuid => $a->{'uuid'}, timestamp => $a->{'timestamp'} });
							}
							elsif ($data->{'recorder'} eq 'system') {
								&Manager::record_audio_stop({ app => $a->{'app'}, uuid => $a->{'uuid'}, timestamp => $a->{'timestamp'} });
							}
							else {
								&Websocket::send('music', { console => 'jpStop(\'' . $a->{'app'} . '\',\'' . $data->{'recorder'} . '\',\'' . $a->{'uuid'} . '\');' });
							}
						}
						else {
#							&subs::db_query('update appointments set seen = ?,type=?, stop_seen=? where uuid=?', 'yes','stop', 'yes',$a->{'uuid'});
							&subs::db_update('appointments', { seen => 'yes', type => 'stop', stop_seen => 'yes' }, { uuid => $a->{'uuid'}, app => $a->{'app'} });
						}
						&subs::intelligent_automation_toggle({ app => $a->{'app'}, 'state' => 'off', timestamp => $timestamp });
						$type = 'stop';

						my $sources = &subs::db_select('appointments', undef, { source_uuid => $a->{'uuid'} })->hashes;

						foreach my $so ( @{$sources} ) {
							push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
							if ( $so->{'type'} eq 'start' && (!$so->{'stop_timestamp'} || $so->{'stop_timestamp'} <= $timestamp) ) {
								my $dur = $so->{'timestamp'} - $timestamp;
								&subs::db_update('appointments', { stop_seen => 'yes', type => 'stop', duration => $dur }, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'}, app => $so->{'app'} });
								&Manager::budget_runner($so->{'app'});
								&subs::intelligent_automation_toggle({ appt_uuid => $so->{'uuid'}, app => $so->{'app'}, 'state' => 'off', timestamp => $timestamp });
								&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
							}
						}
						
					}
					else {
#						&subs::db_query('update appointments set seen = ?, stop_seen=? where uuid=?', 'yes', 'yes',$a->{'uuid'});
						&subs::db_update('appointments', { seen => 'yes', stop_seen => 'yes' }, { app => $a->{'app'}, uuid => $a->{'uuid'} });
					}
					&Websocket::send('tab', { console => 'appointmentDetailGrabber("' . $a->{'app'} . '","' . $a->{'uuid'} .'");' });

				}
				elsif ($a->{'type'} eq 'start' || $a->{'type'} eq 'record') {
					&subs::intelligent_automation_toggle({ app => $a->{'app'}, 'state' => 'on', timestamp => $a->{'timestamp'} });

					my $sources = &subs::db_select('appointments', undef, { source_uuid => $a->{'uuid'} })->hashes;

					foreach my $so ( @{$sources} ) {
						push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
						if ( $so->{'type'} eq 'start' && (!$so->{'stop_timestamp'} || $so->{'stop_timestamp'} <= $timestamp) ) {
							&subs::db_update('appointments', { seen => 'yes' }, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'}, app => $so->{'app'} });
							&budget_runner($so->{'app'});
							&subs::intelligent_automation_toggle({ appt_uuid => $so->{'uuid'}, app => $so->{'app'}, 'state' => 'on', timestamp => $timestamp });
							&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $so->{'app'} . '\',\'' . $so->{'uuid'} .'\');'});
						}
					}	
					if ($a->{'type'} eq 'record') {
						my $recording_type = &subs::setting_grabber({ app => $a->{'app'}, setting => 'record' }) || 'system';
						my $data = eval { return decode_json $a->{'data'} } || {};
						if ($data->{'recorder'} eq 'security') {
							&Manager::record_video({ app => $a->{'app'}, uuid => $a->{'uuid'}, timestamp => $a->{'timestamp'} });
						} elsif ($data->{'recorder'} eq 'system') {
							&Manager::record_audio({ app => $a->{'app'}, uuid => $a->{'uuid'}, timestamp => $a->{'timestamp'} });
						}
						elsif ($data->{'recorder'} eq 'screen') {
							&Websocket::send('music', { console => 'jpScreen(\'' . $a->{'app'} . '\',\'' . $a->{'uuid'} . '\');' });
						}
						else {
							&Websocket::send('music', { console => 'jpStart(\'' . $a->{'app'} . '\',\'' . $data->{'recorder'} . '\',\'' . $a->{'uuid'} . '\');' });
						}
					}



				}
				elsif ($a->{'type'} eq 'stop' || $a->{'type'} eq 'cancel') {
					&subs::intelligent_automation_toggle({ app => $a->{'app'}, 'state' => 'off', timestamp => $timestamp });		
				}
				elsif ($a->{'type'} eq 'image') {
					my $data = decode_json $a->{'data'};
					my $c = &subs::controller_builder();
					$c->stash('app' => $a->{'app'});
					$c->session('timestamp' => $timestamp);
					my ($file,$ocr) = &Manager::take_picture($c,{ app => $a->{'app'}, timestamp => $timestamp, camera => $data->{'camera'}, uuid => $a->{'uuid'} });
				}
				elsif ($a->{'type'} eq 'scan') {
					my $scandata = decode_json $a->{'data'};
					my $c = &subs::controller_builder();
					$c->stash('app' => $a->{'app'});
					$c->stash('timestamp' => $a->{'timestamp'});
					my $file = &Manager::scan($c, $scandata);
				}


				my $cv = &Manager::centre_view_grabber({ app => $a->{'app'}, cached => 'no' });
				my $settings = &subs::settings_grabber({ app => $a->{'app'} }) || {};
				my $name = &subs::format_name($a->{'app'});
				my $app = &subs::unformat_name($a->{'app'});
				my $account = &subs::format_name($a->{'account'});
				if ($settings->{'notification'} && $settings->{'notification'} eq 'on') {
					&Manager::notification_sender({ 
						app => $app, 
						role => 'all', 
						uuid => $a->{'uuid'}, 
						type => $type,
						message => $settings->{'notification_text'},
						settings => $settings, 
						sound => 'crystal.mp3', 
						title => $name, 
					},$dot);
				}
				if ($a->{'type'} =~ /command|kill|record/) {
					my $command = $settings->{$a->{'type'}};
					my $resulter = &subs::run_command($app,$command);
					if ($a->{'type'} eq 'command') {
						&subs::setting_setter({ app => $app, setting => 'toggle', value => 'on' });
					}
					elsif ($a->{'type'} eq 'kill') {
						&subs::setting_setter({ app => $app, setting => 'toggle', value => 'off' });
					}
				}
				&subs::appt_toggle_checker($app);
			}
		}

		my $next_data = &subs::next_appointment_time({ now => $last_moment });
		my $next_time = $next_data->{'next_time'};
		$next_run = $next_data->{'next_run'};
		return { next_run => $next_run, next_time => $next_time };
	}

}


sub alarm_haircut() {
	my ($dber,$dot,$sql) = &subs::database_grabber();

	return unless $dber;
	my $timestamp = &subs::rightNow();
	$last_moment = &subs::rightNow();
	my $ticket_query = &subs::db_query('select count(*) from tickets where status = ? and warranty < ?', 'active', $timestamp);
	my $t_count = $ticket_query->text;
	if ($t_count > 0) {
		my $ticket_update_query = &subs::db_query('update tickets set status = ? where status = ? and warranty < ?', 'expired', 'active', $timestamp);
		my $msg = { app => 'box_office', console => 'ticket_list()' };
		my $server_time = &subs::rightNow();
		&Websocket::send('server', $msg);
	}

	my $warranty_query = &subs::db_query('select * from appointments where warranty < ?',$timestamp);
	my $haircut = $warranty_query->hashes;

	foreach my $h ( @{$haircut} ) {
		foreach my $t ( qw/appointments/ ) {
			&Manager::delete_app($h->{'app'}, $h->{'uuid'},$h->{'server_time'},'alarm runner');		
			#&subs::db_delete($t, { app => $h->{'app'}, uuid => $h->{'uuid'} });
		}
		if (grep { $_ ne $h->{'app'} } qw/misc customs music __president me/) {
			&subs::vacuum($h->{'app'});
		}
	}

	my $backups = [];#&subs::db_query('select * from backups where warranty < ?', $timestamp)->hashes;
	foreach my $b ( @{$backups} ) {
		if (-e $b->{'destination'}) {
			my $commander = 'shred -u ' . $b->{'destination'};
		#	`$commander`;
		}
		#&subs::db_delete('backups', { uuid => $b->{'uuid'} });
	}

	my $paper_q = &subs::db_query('select * from magazine where status=? and timestamp >= ? and timestamp <= ? and warranty >=?', 'publish',$last_paper_moment, $timestamp,$timestamp);
	my $papers = $paper_q->hashes;
	foreach my $paper ( @{$papers} ) {
		my $c = &subs::controller_builder();
		$paper->{'art'} = $c->render_to_string(template => 'article', art => $paper);
		&Manager::paperRoute($paper);
	}
	$last_paper_moment = &subs::rightNow();
	&subs::db_query('delete from magazine where warranty < ?', $timestamp);
	&subs::db_query('delete from continent where warranty < ?', $timestamp);
	&subs::db_query('delete from websites where warranty < ?', $timestamp);
	&subs::db_query('delete from cache where warranty < ?', $timestamp);

	my $websocks = &subs::db_query('select * from websockets where warranty < ?', $timestamp);
	foreach my $webs (@{$websocks->hashes}) {
		my $art_query = &subs::db_query('delete from drawings where browser_tab_id = ?', $webs->{'browser_tab_id'});
		my $del_query = &subs::db_query('delete from websockets where browser_tab_id = ?', $webs->{'browser_tab_id'});
	}

	# Keep the planner's statistics honest. optimize only re-runs ANALYZE for tables
	# whose stats are stale or missing, and analysis_limit keeps each run bounded,
	# so this stays cheap even though it rides along with every haircut. Both on the
	# one handle on purpose: analysis_limit is a connection setting.
	eval { $dber->query('PRAGMA analysis_limit=400;'); };
	eval { $dber->query('PRAGMA optimize;'); };
}

sub budget_watcher() {
	my ($db,$database,$sql) = &subs::database_grabber('memory');
	unless (&subs::setting_grabber({ app => 'me', setting => 'budget_alarm', device => $device }) eq 'on') { return 0; }
	my $w_time = &subs::rightNow() + &subs::time_abbrev_translator('1m',&subs::rightNow());

	my $budgets = &subs::db_query('select distinct(app) as app,* from settings where setting = ? and device = ? and value is not null','budget', $device)->hashes;
	my $settings;
	foreach my $b ( @{$budgets} ) {
		my $app = $b->{'app'};
		my @buds = split /,/, $b->{'value'};
		my $scope;
		$settings->{$app} = &subs::settings_grabber({ app => $app }) unless $settings->{$app};
		foreach my $circumstance ( keys %{$gb::budget_modes} ) {
			my $cache_budget = &subs::cache_get({ app => $app, context => 'budget', subcontext => $circumstance });
			if ($cache_budget->{'scope'}) {
				$scope = $cache_budget->{'scope'};
			}
			foreach my $bud ( @buds ) {
				my @bt = split '/', $bud;
				$scope = $bt[-1];
				if (1) {
					my $budget = &Manager::budget_calculator({
						app => $app,
						circumstance => $circumstance,
						scope => $scope,
						budget => $bud,
						settings => $settings->{$app}
					});
					if ($budget->{'is_scope'} && $circumstance eq $budget->{'circumstance'}) {
						my $server_time = &subs::rightNow();
						$budget->{'timestamp'} = &subs::rightNow();

						&subs::cache_delete({ app => $app, context => 'template' });
						&subs::cache_set({ app => $app, context => 'budget', subcontext => $circumstance }, $budget);

						if ($cache_budget->{'status'} ne $budget->{'status'}) {
							my $websockets = &subs::db_query('select * from websockets where app = ? and windows like ? and server_time > ? and windows is not null order by timestamp DESC',
								'tab', '%app":"' . $app . '%', $server_time - 5000)->hashes;
							if (scalar @{$websockets} > 0) {
								my $msg = { 
									app => $app, 
									type => 'budget', 
									budget => {
										colour => $budget->{'colour'},
										circumstance => $budget->{'circumstance'},
									}
								};
								&Websocket::send('tab', $msg);
								&Manager::centre_view_grabber({ app => &subs::unformat_name($app), timestamp => &subs::rightNow(), cached => 'no' });
							}

							my $message = &subs::format_name($app) . ' is ' . $budget->{'status'} . ' for ' . $circumstance . ': ' . $budget->{'formatted_value'} . '/' . $budget->{'formatted_budgeted'};
							if (&subs::setting_grabber({ app => $app, setting => 'notification', device => $device }) eq 'on') {
								&Manager::notification_sender({ 
									app => $app, 
									role => 'all', 
									title => &subs::format_name($app), 
									synth => $budget->{'synth'}, 
									words => $app, 
									message => $message, 
									image => "/images/decipherable/chart.png",
									type => 'budget'
								},$database);
							}
							#&Manager::budget_autocalc({ 
							#	app => $app, 
							#	circumstance => $circumstance,
							#});
						}
					}

				}
			}
		}
	}

	return 0;
}

sub housekeeping() {

	my ($db,$database,$sql) = &subs::database_grabber();
	my $server_time = &subs::rightNow();
	my $settings = &subs::settings_grabber({ app => '__president', device => $device });
	my @cache_folders = split /\n/, $settings->{'cache_folders'};
	foreach my $cf (@cache_folders) {
		if ($cf ne '/' && $cf ne &subs::home('~/') && $cf =~ /[a-z0-9A-Z]/) {
			my $folder = &subs::home($cf);
			my $doomed = `ls -a $cf`;

			my @doomed = split /\n/, $doomed;
			foreach my $doom ( @doomed ) {
				my $rip = $folder . '/' . $doom;
				unless ($doom eq '.' || $doom eq '..') {
				#	my $success = `shred -u $rip`;				
				}
			}	
		}
	}
	my $expiration = &subs::ago_calc('-1h', $server_time);
	my $websockets = &subs::db_query('delete from websockets where server_time < ? and room is not null', $expiration);

	

	return 0;
}


sub alarm_server() {
	my $file = $gb::tmp_dir . '/alarm';

	my %buffers;
	$alarm_server = Mojo::IOLoop->server({ path => $file } => sub () {
		my ($loop,$stream,$id) = @_;
		$stream->handle->autoflush(1); 
	  $buffers{$id} = '';

	  $stream->on(read => sub () {
			my ($stream, $bytes) = @_;
			$buffers{$id} .= $bytes;
			while ($buffers{$id} =~ s/^(.*?)\n//) {
	      my $line = $1;
	      next unless $line =~ /\S/;
	      my $appt = eval { decode_json($line) };
	      if ($@) {
	          warn "Worker $$: Failed to parse JSON: $@";
	          next;
	      }
				#$log->info(Dumper $appt);
				$log->info($appt->{'timestamp'} . ' ' . $next_run);
				my @times = sort { $a <=> $b } (
					$appt->{'timestamp'},
					$appt->{'stop_timestamp'},
					$appt->{'next_duty'}
				);
				@times = grep { $_ >= &subs::rightNow() } @times;
				if (grep { $_ < $next_run } @times) {
					Mojo::IOLoop->remove($alarm_id);
					$alarm_id = undef;
					my $next_time = ($times[0] - &subs::rightNow()) / 1000;
					&alarm_timer($next_time);
				}
				$stream->write($appt->{'uuid'}) if defined $appt->{'uuid'} && $appt->{'uuid'};
			}
	  });
		$stream->on(close => sub {
				delete $buffers{$id};
		});
	});
	return $alarm_server;
}


sub alarm_timer() {
	my ($next_time) = @_;
	$next_time = 2 unless $next_time;
	$log->info($next_time .  ' for alarm');
	$alarm_id = Mojo::IOLoop->timer($next_time => sub() {
		my $alarm = &alarm_clock();

		&alarm_timer($alarm->{'next_time'});
	});
	return $alarm_id;
}

if ($ENV{PURPOSE} eq "alarm") {
	app->sessions->samesite('lax');
	$ENV{MOJO_MAX_MESSAGE_SIZE} = 1023423423473741824;
	app->renderer->cache->max_keys(0);
#	app->sessions->encrypted(1);
	app->secrets($gb::secret_maker);
	app->sessions->cookie_name($ENV{'cookie_name'});
	if ($config->{'environment'} eq 'production') {
		app->log->level('error'); 
	} else {
		app->log->level('debug'); 
	}
	
	$alarm_id = &alarm_timer();
	$alarm_server = &alarm_server();
	$log->info($alarm_server);
	Mojo::IOLoop->recurring(5 => sub {
    my $is_running = defined Mojo::IOLoop->acceptor($alarm_server) ? 1 : 0;
		if (!$is_running) {
			$alarm_server = &alarm_server();
		}
		my $timer_running = Mojo::IOLoop->is_running($alarm_id);
		if (!$timer_running) {
			$alarm_id = &alarm_timer();
		}
	});
	
	app->start;

}
else {
	1;
}