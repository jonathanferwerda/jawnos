package Manager;

# manager_misc6: route actions moved out of Manager.pl, one sub per route so a
# route can be read and changed without opening the whole file. The package
# is still Manager, so unqualified calls to its helpers and its package
# state work exactly as they did in the single file.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use strict;
use warnings ;#'uninitialized';
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

# GET /manager/icons
sub action_18867 {
	my $c = shift;
	# the desktop's own buttons are rendered with whichever icon set was active at
	# the time, so when the set changes the browser asks what the new one calls
	# each of the paths it is already showing. A live theme change passes refresh,
	# because the worker handling this request may still hold the other cut in
	# its short memo.
	&subs::icon_set_forget() if $c->param('refresh');
	my $paths = eval { decode_json $c->param('paths') } || [];
	my %icons;
	foreach my $p ( @{$paths} ) {
		next unless defined $p && $p =~ m{^/};
		$icons{$p} = &subs::icon_for($p);
	}
	$c->render(json => { icons => \%icons });
}

# GET /manager/notifications/list
sub action_22696 {
	my $c = shift;
	my $content = &notification_grabber({});
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'notifications', title => 'Notifications', contents => $content },$c->param('timestamp'));
	$c->render(text => $contents);
}

# GET /manager/notes
sub action_22702 {
	my $c = shift;
	# Every note, newest first: the plain rows subs::voice_note_store and the app's
	# own input write. Notes are no longer appointments - a note is just its text.
	my $notes = &subs::db_query("select text, timestamp, uuid, app from notes where coalesce(text, '') != '' order by timestamp desc limit 300")->hashes;
	my $content = $c->render_to_string(
		template => 'notes/notes',
		notes => $notes
	);
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'notes', title => 'Notes', contents => $content }, $c->param('timestamp'));
	$c->render(text => $contents);
}

# GET /manager/camera
sub action_23193 {
	my $c = shift;
	# The Camera app: a panel whose buttons drive the app's own camera
	# (window.JawnCamera). In a browser there is no bridge, so the panel says so.
	my $content = $c->render_to_string(template => 'apps/camera');
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'camera', title => 'Camera', contents => $content }, $c->param('timestamp'));
	$c->render(text => $contents);
}

# A member machine hands the crest holder its cosignature. The request carries
# the peer's signature and the statement carries it again, so the roster row
# keeps a signature that still verifies after the request is gone. Only a
# machine on this house's roster can cosign, and only this house's crest.
# POST /manager/crest/cosign
sub action_24039 {
	my $c = shift;
	my $signatorial = $c->param('signatorial') || '';
	my $rm = $signatorial
		? &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]
		: undef;
	unless ($rm) { return $c->render(json => { ok => 0, error => 'no such machine' }); }
	# A keyless row must not let an unsigned caller in: the cosignature is a
	# signature, so the request has to carry one too, and the row's own key must
	# already be pinned. Without that precondition peer_verify(22456) would pin
	# whatever X-Peer-Key the first caller offered, and a keyless signatorial
	# could be claimed by whoever signs first.
	unless ($c->req->headers->header('X-Peer-Signature')) {
		return $c->render(json => { ok => 0, error => 'a signed request is required' });
	}
	unless ($rm->{'pubkey'} && &subs::peer_verify($c, $rm)) {
		return $c->render(json => { ok => 0, error => 'the signature is not that machine' });
	}
	my $body = eval { $c->req->json } || {};
	my $crest_uuid = $body->{'crest_uuid'} || $c->param('crest_uuid') || '';
	my $cosig = $body->{'cosig'};
	unless (ref $cosig eq 'HASH') {
		my $raw = $c->param('cosig') || '';
		$cosig = eval { decode_json($raw) };
	}
	unless (ref $cosig eq 'HASH') {
		return $c->render(json => { ok => 0, error => 'no cosignature' });
	}
	my $crest = &subs::crest_record_read();
	if ($crest_uuid && ($crest->{'uuid'} || '') ne $crest_uuid) {
		return $c->render(json => { ok => 0, error => 'this house holds another crest' });
	}
	return $c->render(json => &subs::crest_member_cosig_accept($rm, $crest, $cosig));
}

# GET /manager/app_draft
sub action_24861 {
	my $c = shift;
	my $app = $c->param('app') || '';
	$app =~ s/[^[:print:]]//g;
	my $field = ($c->param('field') || 'notes') =~ /^(notes|ago|duration)$/ ? $1 : 'notes';
	return $c->render(json => { ok => 0 }) unless length $app;
	my $row = &subs::db_select('notes', ['text', 'server_time', 'timestamp'], { uuid => &app_draft_uuid($app, $field) })->hash;
	$c->render(json => {
		ok => 1,
		text => ($row ? ($row->{'text'} || '') : ''),
		server_time => ($row ? ($row->{'server_time'} || '') : ''),
		timestamp => ($row ? ($row->{'timestamp'} || '') : ''),
	});
}

# POST /manager/app_draft
sub action_24875 {
	my $c = shift;
	my $app = $c->param('app') || '';
	$app =~ s/[^[:print:]]//g;
	$app = substr($app, 0, 200);
	my $field = ($c->param('field') || 'notes') =~ /^(notes|ago|duration)$/ ? $1 : 'notes';
	return $c->render(json => { ok => 0 }) unless length $app;
	my $text = $c->param('text');
	$text = '' unless defined $text;
	$text = substr($text, 0, 200000);
	my $uuid = &app_draft_uuid($app, $field);
	my $now = &subs::rightNow();
	my $row = &subs::db_select('notes', ['uuid', 'timestamp'], { uuid => $uuid })->hash;
	my $fresh = !($row && $row->{'uuid'});
	if ($text =~ /^\s*$/ || $text eq '<br>') {
		&subs::db_update('notes', { text => '', server_time => $now }, { uuid => $uuid }) if !$fresh;
		&Websocket::send('tab', { console => 'notesReload();' }) if !$fresh;
		return $c->render(json => { ok => 1, cleared => 1 });
	}
	if (!$fresh) {
		&subs::db_update('notes', { text => $text, server_time => $now }, { uuid => $uuid });
	}
	else {
		&subs::db_insert('notes', {
			uuid => $uuid,
			app => $app,
			text => $text,
			timestamp => $now,
			server_time => $now,
			device => &subs::device_setter()
		});
		&Websocket::send('tab', { console => 'notesReload();' });
	}
	$c->render(json => { ok => 1, uuid => $uuid, server_time => $now });
}

# A one-time sweep from the browsers: every manager page that still holds notes
# in its localStorage offers them up. The first browser to report an app wins and
# a draft that already exists is kept, so an old copy on a machine that was left
# off cannot overwrite newer words. The client clears its local copies once this
# answers, and the house becomes the authority.
# POST /manager/app_draft/backfill
sub action_24915 {
	my $c = shift;
	my $raw = $c->param('drafts');
	my $list = eval { decode_json($raw || '') } || [];
	$list = [] unless ref $list eq 'ARRAY';
	my ($added, $kept) = (0, 0);
	my $now = &subs::rightNow();
	my $seen = 0;
	foreach my $d ( @{$list} ) {
		last if ++$seen > 500;
		next unless ref $d eq 'HASH';
		my $app = $d->{'app'} || '';
		$app =~ s/[^[:print:]]//g;
		$app = substr($app, 0, 200);
		next unless length $app;
		my $text = $d->{'text'};
		$text = '' unless defined $text;
		$text = substr($text, 0, 200000);
		next if $text =~ /^\s*$/ || $text eq '<br>';
		my $uuid = &app_draft_uuid($app, 'notes');
		my $row = &subs::db_select('notes', ['uuid'], { uuid => $uuid })->hash;
		if ($row && $row->{'uuid'}) { $kept++; next; }
		&subs::db_insert('notes', {
			uuid => $uuid,
			app => $app,
			text => $text,
			timestamp => $now,
			server_time => $now,
			device => &subs::device_setter()
		});
		$added++;
	}
	&Websocket::send('tab', { console => 'notesReload();' }) if $added;
	$c->render(json => { ok => 1, added => $added, kept => $kept });
}

# POST /manager/note_save
sub action_24950 {
	my $c = shift;
	# Write a note by hand, or save one being edited: a uuid that is already a note
	# updates in place, anything else is a new note. Every open Notes window is
	# refreshed, so the list stays live.
	my $uuid = $c->param('uuid');
	my $text = $c->param('text');
	$text = '' unless defined $text;
	$text =~ s/\r\n/\n/g;
	$text =~ s/^\s+|\s+$//g;
	my $now = &subs::rightNow();
	my $exists = $uuid ? &subs::db_select('notes', ['uuid'], { uuid => $uuid })->hash : undef;
	my $created = 0;
	if ($exists && $exists->{'uuid'}) {
		&subs::db_update('notes', { text => $text, server_time => $now }, { uuid => $uuid });
	}
	else {
		$uuid = &subs::random_string_creator(21);
		&subs::db_insert('notes', {
			uuid => $uuid,
			app => 'notes',
			text => $text,
			timestamp => $now,
			server_time => $now
		});
		$created = 1;
	}
	&Websocket::send('tab', { console => 'notesReload();' });
	$c->render(json => { uuid => $uuid, text => $text, created => $created });
}

# POST /manager/note_delete
sub action_24980 {
	my $c = shift;
	# The Notes app's X (two-click: arm, then delete). Notes live in their own
	# table now, so this is scoped to it.
	my $uuid = $c->param('uuid');
	&subs::db_delete('notes', { uuid => $uuid });
	&Websocket::send('tab', { console => 'notesReload();' });
	$c->render(json => { uuid => $uuid });
}

# POST /manager/note_to_appt
sub action_24989 {
	my $c = shift;
	# A note dragged onto an appointment window. Dropped on one of the window's
	# appointment rows (an .appointment_detail, which carries its own uuid) the
	# note's text is appended to THAT appointment's notes; dropped anywhere else on
	# the window it becomes a new appointment for the app. Either way the notes are
	# encrypted exactly the way manager_reset encrypts a reset's notes.
	my $uuid = $c->param('uuid');
	my $app = &subs::unformat_name($c->param('app'));
	my $appt_uuid = $c->param('appt_uuid');
	my $note = &subs::db_select('notes', undef, { uuid => $uuid })->hash;
	return $c->render(json => { error => 'no such note' }) unless $note && defined $note->{'text'};
	my $text = $note->{'text'};
	my $suds = &subs::session_suds($c);
	my $now = &subs::rightNow();
	if ($appt_uuid) {
		my $appt = &subs::db_select('appointments', undef, { uuid => $appt_uuid })->hash;
		return $c->render(json => { error => 'no such appointment' }) unless $appt && $appt->{'uuid'};
		my $existing = $appt->{'notes'} ? &subs::note_decrypter($suds, $appt->{'notes'}, $appt->{'server_time'}) : '';
		$existing .= "\n" if $existing =~ /\S/;
		&subs::db_update('appointments', { notes => &subs::note_encrypter($suds, $existing . $text), server_time => $now }, { uuid => $appt->{'uuid'} });
		&Websocket::send('tab', { console => 'appointmentDetailGrabber("' . $app . '","' . $appt->{'uuid'} . '");' });
		return $c->render(json => { app => $app, uuid => $appt->{'uuid'}, created => 0 });
	}
	my $new_uuid = &subs::random_string_creator(21);
	&subs::db_insert('appointments', {
		app => $app,
		timestamp => $now,
		server_time => $now,
		type => 'note',
		pos => &subs::setting_grabber({ app => $app, setting => 'pos' }),
		notes => &subs::note_encrypter($suds, $text),
		uuid => $new_uuid,
		seen => 'yes'
	});
	&Websocket::send('tab', { console => 'appointmentDetailGrabber("' . $app . '","' . $new_uuid . '");' });
	$c->render(json => { app => $app, uuid => $new_uuid, created => 1 });
}

# POST /manager/notifications/remove
sub action_25102 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $tag = $c->param('tag');
	my $title = $c->param('title');
	my $uuid = $c->param('uuid');
	my $app = $c->param('app');
	my $server_time = $c->param('server_time');
	my $scope = $c->param('scope');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $deletions = [];
	if ($tag) {
		if ($device eq 'mobile') {
			&subs::device_call('notification.remove', { id => $tag });
		}
	}
	if ($scope eq 'all') {
		my $notifications = &notification_grabber({ delete => 'yes' });
		foreach my $n ( @{$notifications->{'list'}} ) {
			&subs::db_delete('notifications', { uuid => $n->{'uuid'} });
			push @{$deletions}, $n->{'uuid'};
			&deletion_registration({ table => 'notifications', uuid => $n->{'uuid'}, server_time => $n->{'server_time'} });
		}
	}
	else {
		&subs::db_delete('notifications', { timestamp => $timestamp, title => $title, uuid => $uuid });
		&deletion_registration({ table => 'notifications', uuid => $uuid, server_time => $server_time });
		push @{$deletions}, $uuid;
	}
	$c->render(json => $deletions );
}

# GET /manager/notifications/filter
sub action_25133 {
	my $c = shift;
	my $app = $c->param('app');
	&subs::setting_setter({ app => 'notifications', setting => 'filter', value => $app });
	my $returner = notification_grabber({});
	$c->render(json => $returner);
}

# GET /manager/notifications/search
sub action_25140 {
	my $c = shift;
	my $search = $c->param('search');
	&subs::setting_setter({ app => 'notifications', setting => 'search', value => $search });
	my $returner = &notification_grabber({});
	$c->render(json => $returner);
}

# GET /manager/notifications/scroll
sub action_25147 {
	my $c = shift;
	my $returner = &notification_grabber({ scroll => 'down', position => $c->param('position') });
	$c->render(json => $returner);
}

# GET /manager/appointment_viewer
sub action_25183 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $readable = $c->param('readable');
	my $timeshift = $c->param('timeshift');
	my $scope = $c->param('scope');
	my $sorts = $c->param('sorts');
	my $time_machine = $c->param('time_machine');
	my $filter = $c->param('filter');
	my $account = $c->param('account');
	my $project = $c->param('project');
	my $appt_view_toggle = $c->param('appt_view_toggle');
	my $layout = $c->param('layout');
	my $stats = eval { return decode_json $c->param('stats') } || {};
	my $timeshift_max;
	my $chosen_appts;
	if ($c->param('appts')) {
		$chosen_appts = decode_json $c->param('appts');
	}
	else { $chosen_appts = \@appointments; }
	if ($time_machine) {
		$timestamp = &time_machine_resolve($time_machine,$timestamp);
	}
	# The centre the time machine alone stands for. The timeline writes a slide back
	# into #time_machine as a relative string, and that string must anchor here -
	# anchoring it on the final centre would fold the separate timeshift into it,
	# and the server would apply the timeshift a second time on every poll, so the
	# view marched further back with every slide.
	my $time_machine_timestamp = $timestamp;
	if ($timeshift && $timeshift =~ /[0-9]/) {
		$timestamp = &subs::ago_calc($timeshift,$timestamp);
	#	$timestamp = $timestamp - ($timeshift);
	}
	my $period = eval { &subs::time_span($scope, $timestamp) };

	my $appts = &log_reader({
		appts => $chosen_appts,
		project => $project,
		account => $account,
		scope => $scope,
		sorts => $sorts,
		'timestamp' => $timestamp,
		filter => $filter,
		appt_view_toggle => $appt_view_toggle,
		view => 'appointment_viewer',
		stats => $stats
	});
	$appts->{'__specs'}->{'layout'} = $layout;
	$appts->{'__specs'}->{'time_machine_timestamp'} = $time_machine_timestamp;
	if ($appts->{'updateable'} eq 'no') {
		$c->render(json => { updateable => 'no', '__specs' => $appts->{'__specs'} });
		$c->rendered;
		return;
	}
	my @results;
	my @log_watch;
	foreach my $a (@{$chosen_appts}) {
		next if &subs::app_private_now($a) || &subs::app_hidden_now($a);



		foreach my $type (qw/list/) {
			last unless $appts->{$a}->{$type};
			if (@{$appts->{$a}->{$type}} && scalar @{$appts->{$a}->{$type}} > 0) {
				if (my @present = grep { $_->{'timestamp'} > $period && $_->{'timestamp'} < ($timestamp + ($timestamp - $period)) } @{$appts->{$a}->{$type}}) {
					$appts->{$a}->{$scope . '_occurrences'} = scalar @present;

					foreach my $p (@present) {

						$p->{'formatted_name'} = &subs::format_name($p->{'app'});

						my $point = $p->{'timestamp'} - $period;
						my $total = $timestamp - $period;
						my $percent = $point / $total;
						$appts->{$a}->{$scope . '_percent'} = $percent;
						if ($p->{'duration'}) {
							my $point = $p->{'timestamp'} - $p->{'duration'} - $period;
							my $total = $timestamp - $period;
							my $percent = $point / $total;
							$p->{$scope . '_start_percent'} = $percent;
						}


						$p->{$scope . '_percent'} = $percent;
						$p->{$scope . '_occurrences'} = $appts->{$a}->{$scope . '_occurrences'};
						$p->{'start_notes'} = undef;
						$p->{'end_notes'} = undef;

						if ($p->{'type'} eq 'transaction') {
							if ($p->{'amount'} && !$p->{'tax'} && $p->{'total'} > $p->{'amount'}) {
								$appts->{$a}->{$scope . '_tax' } += sprintf("%.2f",($p->{'amount'} * 1.13) - $p->{'amount'});
							}
							$appts->{$a}->{$scope . '_tax' } += sprintf("%.2f", ($p->{'tax'})) if $p->{'tax'};
							$appts->{$a}->{$scope . '_total' } += unformat_number($p->{'total'} || $p->{'amount'}) if $p->{'total'} || $p->{'amount'};
							$appts->{$a}->{$scope . '_amount' } += unformat_number($p->{'amount'}) if $p->{'amount'};
						}
						$appts->{$a}->{$scope . '_quantity' } += $p->{'quantity'} if $p->{'_occurrences'};
						$appts->{$a}->{'since'} = ($timestamp - $p->{'timestamp'}) / 1000;
						if ($p->{'type'} =~ 'start|pause|record' ) {
							$appts->{$a}->{'setting'}->{'status'} = $p->{'type'};
							$appts->{$a}->{$scope . '_duration'} += $timestamp - $p->{'timestamp'};
							$appts->{$a}->{'formatted_since'} = &subs::duration_sayer(($timestamp - $p->{'timestamp'}) / 1000);

						}
						else {
							$appts->{$a}->{$scope . '_duration'} += abs $p->{'duration'} || $appts->{$a}->{'setting'}->{$scope . '_duration'} if (abs $p->{'duration'} || $appts->{$a}->{'setting'}->{$scope . '_duration'});
							$appts->{$a}->{'formatted_since'} = &subs::duration_sayer(($timestamp - $appts->{$a}->{'last_reset'}) / 1000) if $appts->{$a}->{'last_reset'};
						}
						$appts->{$a}->{'formatted_since'} = 'in ' . $appts->{$a}->{'formatted_since'} if ($timestamp - $p->{'timestamp'}) < 0;

						$appts->{$a}->{$scope . '_timestamp'} = $p->{'timestamp'};

						if ($sorts eq 'log') {
							push @{$appts->{'__logwatch'}}, $p;
						}
						foreach my $ts ( &subs::time_span_list() ) {
							if ($type eq 'list') {
								$appts->{'__stash'}->{$ts . '_total_' . $sorts} += (unformat_number($p->{'total'} || $p->{'amount'})) if $p->{'total'} || $p->{'amount'};
							}
							else {
								$appts->{'__stash'}->{$ts . '_total_' . $sorts} += -(unformat_number($p->{'total'} || $p->{'amount'})) if $p->{'total'} || $p->{'amount'};
							}

						}
						$appts->{$a}->{$scope . '_duration_percent'} =  ($appts->{$a}->{$scope . '_duration'} / abs &subs::time_span($scope, 0)) * 100 if $appts->{$a}->{$scope . '_duration'};
						$appts->{$a}->{$scope . '_duration_percent'} = sprintf("%.2f",$appts->{$a}->{$scope . '_duration_percent'}) . "%" if ($appts->{$a}->{$scope . '_duration_percent'} );
					}
				}

			}
			$appts->{$a}->{$scope . '_formatted_duration'} = &subs::duration_sayer($appts->{$a}->{$scope . '_duration'} / 1000) if $appts->{$a}->{$scope . '_duration'};
		}
	};
	# Ghost appointments: the events an app's records say will probably happen, that
	# are not scheduled - drawn faded ahead of now. Gated on the delorean toggle,
	# and only within the view the clock is showing.
	if ((&subs::setting_grabber({ app => 'keyboard', setting => 'ghost_appointments' }) || '') eq 'checked') {
		my $ghost_now = &subs::rightNow();
		my $ghost_end = (defined $period && $period) ? ($timestamp + ($timestamp - $period)) : $timestamp;
		foreach my $a (@{$chosen_appts}) {
			next if &subs::app_private_now($a) || &subs::app_hidden_now($a);
			my $g = &subs::ghost_rows_for($a, $ghost_now, $ghost_end);
			$appts->{$a}->{'ghosts'} = $g if scalar @{$g};
		}
	}
	$appts->{'__specs'}->{'pseudonyms'} = &pseudonym_maker('viewer','');
	my $clothesline = eval { return decode_json &subs::setting_grabber({ app => '__president', setting => 'clothesline' }) } || [];
	if ($c->param('background_images') eq 'on') {
		$appts->{'__specs'}->{'backgrounds'} = eval { return decode_json &subs::setting_grabber({ app => 'marker', setting => 'backgrounds' }) } || [];
		$appts->{'__specs'}->{'background'} = $appts->{'__specs'}->{'backgrounds'}->[rand(scalar @{$appts->{'__specs'}->{'backgrounds'}})];
	}
	$c->render(
		json => {
			appts => $appts,
			timestamp => $timestamp,
			clothesline => $clothesline
		}
	);
}

# The desk's own rail. With the desk as the background there is no timeline or
# leaderboard to build, so desk.js asks this instead of appointment_viewer once a
# minute: the stored clothesline, and the picture when the background is on.
# GET /manager/clothesline_rail
sub action_25345 {
	my $c = shift;
	my $clothesline = eval { return decode_json &subs::setting_grabber({ app => '__president', setting => 'clothesline' }) } || [];
	my %payload = ( clothesline => $clothesline, timestamp => &subs::rightNow() );
	if (($c->param('background_images') || '') eq 'on') {
		my $backgrounds = eval { return decode_json &subs::setting_grabber({ app => 'marker', setting => 'backgrounds' }) } || [];
		$payload{'backgrounds'} = $backgrounds;
		$payload{'background'} = $backgrounds->[ int(rand(scalar @{$backgrounds})) ] if scalar @{$backgrounds};
	}
	$c->render(json => \%payload);
}

# GET /manager/tasks
sub action_25356 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $tasks = &subs::task_grabber($app);
	$c->render(json => $tasks);
}

# POST /manager/tasks
sub action_25364 {
	my $c = shift;
	my $server_time = $c->param('server_time') || &subs::rightNow();
	$c->param('server_time' => $server_time);
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		&remote_relay_request($c, { dissemination => 'yes', server_time => $server_time });
	}, { name => 'task remote relay' });
	my $papp = &subs::unformat_name($c->param('papp'));
	my $app = &subs::unformat_name($c->param('app'));
	# A checkbox change reads the whole tasks row, edits it and writes it back,
	# and the prefork workers can run two at once: one would read before the
	# other wrote and drop the other's check. A per-app lock serializes them on
	# this machine; the shared server_time does the same across machines.
	my $task_lock = &subs::home('~/.president/.task_lock_' . &subs::shorthand_name($app || 'app', 20));
	my $task_lock_fh;
	open($task_lock_fh, '>>', $task_lock);
	flock($task_lock_fh, LOCK_EX) if $task_lock_fh;

	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $name = $c->param('name');
	my $value = $c->param('value');
	my $colour = $c->param('colour');
	my $tasks = &subs::task_writer($c,{
		papp => $papp,
		app => $app,
		timestamp => $timestamp,
		uuid => $uuid,
		name => $name,
		value => $value,
		colour => $colour,
		project => $c->param('project'),
		account => $c->param('account'),
		movement => $c->param('movement'),
		server_time => $server_time
	});

	my $tasks_json = encode_json $tasks;
	# the row wears the same server_time every machine recorded the change under,
	# so a later database merge compares like with like and cannot let one
	# machine's older copy win a tie the clocks decided
	&subs::setting_setter({ app => $app, setting => 'tasks', value => $tasks_json, server_time => $server_time });
	flock($task_lock_fh, LOCK_UN) if $task_lock_fh;
	close($task_lock_fh) if $task_lock_fh;
	$c->render(json => &subs::task_grabber($papp));

}

# POST /manager/tasks/delete
sub action_25413 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $app = $c->param('app');
	my $papp = $c->param('papp');
	my $tasks_json = &subs::setting_grabber({ app => $app, setting => 'tasks' }) || '[]';
	my $tasks =  decode_json $tasks_json;
	@{$tasks} = grep { $_->{'uuid'} ne $uuid } @{$tasks};
	$tasks_json = encode_json $tasks;
	&subs::setting_setter({ app => $app, setting => 'tasks', value => $tasks_json });
	$c->render(json => &subs::task_grabber($papp));
}

# GET /manager/appointment_measures
sub action_25425 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $timestamp = $c->param('timestamp');

	my $appts = &log_reader({ app => $app, view => 'centre_view' });
	$appts->{$app}->{'settings'}->{'ia'} = eval { return decode_json $appts->{$app}->{'setting'}->{'ia'} } || {};




	$appts->{$app}->{'setting'}->{'app_measures'} = eval { return decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};
	$c->render(
		template => 'apps/app_measures',
		settings => $appts->{$app}->{'setting'},
		a => $app,
		appts => $appts
	);
}

1;
