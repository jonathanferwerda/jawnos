package Manager;

# manager_misc9: route actions moved out of Manager.pl, one sub per route so a
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
use Mojo::JSON ();
use Mojo::Asset::File;
use Cwd ();
use POSIX ();
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

use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

# GET /manager/terminal
sub action_27642 {
	my $c = shift;

	my $timestamp = $c->param('timestamp');
	my $whoami = `whoami`;
	chomp $whoami;
	my $hostname = `hostname`;
	chomp $hostname;
	my $settings = &subs::settings_grabber({ app => 'terminal' });
	$settings->{'errors'} = eval { return decode_json $settings->{'errors'} } || [];
	$settings->{'log'} = eval { return decode_json $settings->{'log'} } || [];
	$settings->{'errors'} = [] unless ref $settings->{'errors'} eq 'ARRAY';
	$settings->{'log'} = [] unless ref $settings->{'log'} eq 'ARRAY';
	# The files can grow for months. A reader shows the newest page, not the whole
	# archive: hundreds of stale entries made the window slow to draw and hid the
	# one that matters. The counts stay truthful, and the stored arrays are
	# capped where they are written.
	my $errors_total = scalar(@{$settings->{'errors'}});
	my $logs_total = scalar(@{$settings->{'log'}});
	$settings->{'errors'} = [ @{$settings->{'errors'}}[-200 .. -1] ] if $errors_total > 200;
	$settings->{'log'} = [ @{$settings->{'log'}}[-150 .. -1] ] if $logs_total > 150;
	# A fresh terminal used to render every view hidden (the saved view was unset),
	# so the window opened completely blank. Default to the live shell.
	my $view = $settings->{'view'} || 'interactive_terminal';
	$view = 'interactive_terminal' unless grep { $_ eq $view } qw/interactive_terminal terminal errors log/;
	$settings->{'view'} = $view;
	my $font_size = $settings->{'font_size'};
	$font_size = 15 unless (defined $font_size && $font_size =~ /^\d+$/ && $font_size >= 10 && $font_size <= 32);
	# The machine list for the configuration panel. A remote's own stored user and
	# port win; otherwise this machine's login name and the sshd port JawnOS uses.
	my $remote_settings = eval { return decode_json($settings->{'remotes'} || '') } || {};
	my @remotes;
	my %seen_remote;
	foreach my $rm ( @{ &subs::remote_machine_lister({ self => 'no' }) } ) {
		my $host = $rm->{'lan_ip'} || $rm->{'ip'} || $rm->{'fqdn'} || $rm->{'hostname'} || '';
		next unless $host ne '';
		next if $host =~ /^(?:127\.0\.0\.1|localhost|::1)$/i;
		my $key = $rm->{'uuid'} || $rm->{'signatorial'} || $host;
		next if $seen_remote{$key}++;
		my $saved = $remote_settings->{$key} || {};
		push @remotes, {
			key => $key,
			host => $host,
			address => $rm->{'fqdn'} || $rm->{'lan_ip'} || $rm->{'ip'} || $host,
			name => $rm->{'hostname'} || $rm->{'fqdn'} || $host,
			device => $rm->{'device'} || '',
			connection => $rm->{'connection'} || '',
			user => (defined $saved->{'user'} && $saved->{'user'} =~ /^[A-Za-z0-9._@\-]+$/) ? $saved->{'user'} : $whoami,
			port => (defined $saved->{'port'} && $saved->{'port'} =~ /^\d+$/ && $saved->{'port'} > 0 && $saved->{'port'} < 65536) ? $saved->{'port'} : 8022
		};
	}
	@remotes = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @remotes;
	# One pty per window: the client names the session, the websocket worker keeps
	# it alive. The route only needs an id it can put on the window.
	my $terminal_id = $c->param('terminal_id') // '';
	$terminal_id =~ s/[^A-Za-z0-9_\-]//g;
	$terminal_id = substr($terminal_id, 0, 64);
	$terminal_id = 't' . &subs::random_string_creator(12) if length($terminal_id) < 4;
	my $window_name = $c->param('window_name') // '';
	$window_name =~ s/[<>\r\n]//g;
	$window_name = substr($window_name, 0, 80);
	$window_name = &subs::ui('Terminal') unless length $window_name;
	my $session_host = $c->param('session_host') // '';
	$session_host = '' unless $session_host =~ /^[A-Za-z0-9._:\-\[\]]{1,255}$/;
	my $session_user = $c->param('session_user') // '';
	$session_user = '' unless $session_user =~ /^[A-Za-z0-9._\-]{1,64}$/;
	my $session_port = $c->param('session_port') // '';
	$session_port = '' unless $session_port =~ /^\d+$/ && $session_port > 0 && $session_port < 65536;
	# Sessions the websocket worker started and has not seen end. Opening one makes
	# a window that attaches to the pty still running on the server.
	my $session_map = &subs::cache_get({ app => 'terminal', context => 'sessions' }) || {};
	my @open_sessions;
	if (ref $session_map eq 'HASH') {
		foreach my $sid ( keys %{$session_map} ) {
			my $s = $session_map->{$sid};
			next unless ref $s eq 'HASH';
			next unless $sid =~ /^[A-Za-z0-9_\-]{4,64}$/;
			push @open_sessions, {
				id => $sid,
				label => $s->{'label'} || $sid,
				host => $s->{'host'} || '',
				user => $s->{'user'} || '',
				port => $s->{'port'} || '',
				state => $s->{'state'} || 'open',
				at => $s->{'at'} || 0
			};
		}
	}
	@open_sessions = sort { $b->{'at'} <=> $a->{'at'} } @open_sessions;
	splice @open_sessions, 20;
	my $local = { user => $whoami, host => $hostname, label => $whoami . '@' . $hostname, local => 1 };
	my $current = $local;
	my $contents = $c->render_to_string(
		template => 'terminal/terminal',
		window_maker => 'yes',
		whoami => $whoami,
		hostname => $hostname,
		settings => $settings,
		view => $view,
		font_size => $font_size,
		remotes => \@remotes,
		local => $local,
		current => $current,
		errors_total => $errors_total,
		logs_total => $logs_total,
		terminal_id => $terminal_id,
		window_name => $window_name,
		session_host => $session_host,
		session_user => $session_user,
		session_port => $session_port,
		open_sessions => \@open_sessions
	);
	if ($c->param('window_maker') eq 'yes') {
		my $website = &Manager::window_maker({
			user_agent => $c->param('user_agent'),
			app => 'terminal',
			terminal_id => $terminal_id,
			window_name => $window_name,
			contents => $contents
		}, $timestamp);
		$c->render(text => $website);
	}
	else {
		$c->render(text => $contents);
	}
}

# POST /manager/terminal/error_report
sub action_27770 {
	my $c = shift;
	# The browser's own failures (a route that answered 500, a script that threw)
	# join the same log the server writes to. Keep it bounded and small: this is a
	# reader for a person, not an archive.
	my $errors = eval { return decode_json $c->param('errors') } || [];
	if (ref $errors eq 'ARRAY' && scalar @{$errors} > 0) {
		my $old_errors = eval { return decode_json &subs::setting_grabber({ app => 'terminal', setting => 'errors' }) } || [];
		foreach my $e ( @{$errors} ) {
			next unless ref $e eq 'HASH';
			push @{$old_errors}, {
				timestamp => &subs::rightNow(),
				code => substr($e->{'code'} // 'browser', 0, 40),
				msg => substr($e->{'msg'} // $e->{'message'} // 'unknown browser error', 0, 4000),
				uuid => &subs::random_string_creator(12)
			};
		}
		splice @{$old_errors}, 0, scalar(@{$old_errors}) - 200 if scalar @{$old_errors} > 200;
		&subs::setting_setter({ app => 'terminal', setting => 'errors', value => encode_json $old_errors });
	}
	$c->render(json => []);
}

# POST /manager/window_closer
sub action_27792 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	# Closing the app closes its padlock: the grant is dropped before the window
	# goes, so reopening it (or the app after a restart) opens locked.
	if (grep { $_ eq $app } @media_unlock_apps) {
		my $device = &media_unlock_device($c);
		&media_unlock_clear($device, $app) if length $device;
	}
	# Closing a private app relocks private at once: the device grant goes and
	# any other private window in this tab closes, so the next look needs a
	# fresh fingerprint (the same rule Gallery already follows).
	if (&subs::app_private_now($app) && &subs::private_revealed()) {
		&private_relock($c, $c->param('browser_tab_id'), { skip_app => $app, only_if_last => 1 });
	}
	&subs::window_closer($app, $c->param('browser_tab_id'));
	my $settings = &subs::settings_grabber({ app => &subs::unformat_name($app) });

	if ($settings->{'enc'} eq 'on') {
		&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => &subs::session_suds($c) });
	}
	else {
		&subs::file_decrypter({ app => $app, timestamp => $timestamp, suds => &subs::session_suds($c) });
	}
	$c->render('text' => 'ok');
}

# POST /manager/terminal
sub action_27819 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	$c->render(text => 'ok');

	if ($c->param('command') eq 'telephone') {
		&subs::telephone_contacts_check();
		&subs::telephone_call_log_check();
	}
	else {
		my $return = &subs::run_command('terminal',$c->param('command'),$timestamp);
	}
	$c->render('text' => 'ok');
}

# GET /manager/file/information
sub action_28093 {
	my $c = shift;
	my $file = $c->param('file');
	my $app = $c->param('app');
	my $file_uuid = $c->param('file_uuid');
	my $app_uuid = $c->param('app_uuid');
	my $mouse = eval { return decode_json $c->param('mouse') } || {};
	my $scope = $c->param('scope');
	my $timestamp = $c->param('timestamp');
	my $uuid = &subs::random_string_creator(12);
	my $appt = &subs::db_select('appointments', undef, { uuid => $app_uuid, app => $app })->hashes->[0];
	my $files = eval { return decode_json $appt->{'file'} } || [];
	@{$files} = grep { $_->{'uuid'} eq $file_uuid } @{$files};
	$file = $files->[0];
	if ($file->{'ocr'}) {
		$file->{'ocr'} = &subs::note_decrypter(&subs::session_suds($c), $file->{'ocr'}, $file->{'server_time'});
		$file->{'ocr'} =~ s/\n/<br>/gi;
	}


	my $returner = { app => $app, mouse => $mouse, uuid => $uuid, file => $file, appt => $appt };
	$returner->{'appts'} = &log_reader({ app => $app, timestamp => $appt->{'timestamp'}, filter => 'all', scope => $scope, view => 'appointment_details' });
	$c->param('duty' => 'information');
	my $job = &rock_and_roll($c);

	$returner->{'id'} = 'file_information_' . $uuid;
	$returner->{'html'} = $c->render_to_string(
		template => 'file_information',
		file => $file,
		app => $app,
		mouse => $mouse,
		uuid => $uuid,
		job => $job,
		appt => $appt,
		appts => $returner->{'appts'},
	);
	$c->render(json => $returner);
}

# POST /manager/file/information_updater
sub action_28131 {
	my $c = shift;
	my $attribute = $c->param('attribute');
	my $file_uuid = $c->param('file_uuid');
	my $app_uuid = $c->param('app_uuid');
	my $app = $c->param('app');
	my $value = $c->param('value');

	my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $app_uuid })->hashes->[0];
	my $files = eval { return decode_json $appt->{'file'} } || [];

	foreach my $f ( @{$files} ) {
		if ($file_uuid eq $f->{'uuid'}) {
			if ($attribute eq 'warranty') {
				$value = &subs::ago_calc($value, &subs::rightNow());
				$appt->{'warranty'} = $value;
			}
		}
	}
	my $jf = encode_json $files;
	&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $jf, warranty => $appt->{'warranty'} }, { uuid => $appt->{'uuid'}, app => $appt->{'app'} });

	$c->render(json => { value => $value, files => $files, appt => $appt });

}

# GET /manager/cards
sub action_28156 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $mode = &subs::setting_grabber({ app => 'cards', setting => 'mode' });
	my $history = &subs::cards_list($mode);
	my $variant = &subs::setting_grabber({ app => 'cards', setting => 'variant' });
	my $bank = &subs::setting_grabber({ app => 'cards', setting => 'solitaire_bank' });
	my $blackjack_bank = &subs::setting_grabber({ app => 'cards', setting => 'blackjack_bank' });
	my $contents = $c->render_to_string(
		template => 'cards',
		history => $history,
		mode => $mode,
		variant => $variant,
		bank => $bank,
		blackjack_bank => $blackjack_bank
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'cards', contents => $contents }, $timestamp);
	$c->render('text' => $website);
}

# GET /manager/card_picker
sub action_28170 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $new_card = $c->param('new_card');
	my $tree = &subs::inventory_grabber();

	my $mode = &subs::setting_grabber({ app => 'cards', setting => 'mode' });


	my $history = [];

	if ($mode && $mode ne 'all') {
		$history = &subs::cards_list($mode);
	}
	elsif ($mode eq 'all') {
		my $cards = `ls ./public/images/cards`;
		my @cards = split /\n/, $cards;
		foreach my $ca ( @cards ) {
			my @ca = split /\./, $ca;
			my @stat = stat './public/images/cards/' . $ca;
			push @{$history}, { title => $ca[0], timestamp => $stat[10] * 1000 };
		}
	}

	my ($card,$stream,$title,$spread_cards);
	if ($new_card eq 'new') {
		if ($mode eq 'day') {
			$card = &card_of_the_day();
			$title = $card;
			$title =~ s/.png$//gi;
		}
		elsif ($mode eq 'week') {
			$card = &card_of_the_week();
			$title = $card;
			$title =~ s/.png$//gi;
		}
		elsif ($mode eq 'month') {
			$card = &card_of_the_month();
			$title = $card;
			$title =~ s/.png$//gi;
		}
		elsif ($mode eq 'year') {
			$card = &card_of_the_year();
			$title = $card;
			$title =~ s/.png$//gi;
		}
		elsif ($mode eq 'spread') {
			my (@cards, @names, @labels);
			for (my $n = 0; $n <= 2; $n++) {
				my ($ca,$car);

				$ca = &random_card_picker();
				$car = './public/images/cards/' . $ca;
				while (grep { $car eq $_ } @cards) {

					$ca = &random_card_picker();
					$car = './public/images/cards/' . $ca;

				}

				$cards[$n] = $car;
				(my $name = $car) =~ s{^\./public/images/cards/}{};
				push @names, $name;
				(my $label = $ca) =~ s/.png$//gi;
				push @labels, &subs::format_name($label);
			}
			# The spread is three deck files side by side. The reply carries the
			# names and the browser draws three pictures; the old montage needed
			# an image tool and silently lost cards when it was missing.
			$title = join(' \x{b7} ', @labels);
			splice @{$history}, 10;
			$spread_cards = \@names;
		}
		else {
			$card = &random_card_picker();
			$title = $card;
			$title =~ s/.png$//gi;
		}
		# The day/week/month/year writers store the draw themselves, after the
		# history above was read. Read it again so this reply's rail carries the
		# new draw now, instead of showing it only on the next click.
		$history = &subs::cards_list($mode) if ($mode // '') =~ /^(?:day|week|month|year)$/;
	}
	else {
		my $latest = (ref $history->[0] eq 'HASH') ? $history->[0] : undef;
		if (!$latest) {
			# A first open has no history yet; show the deck's own cover.
			$card = 'title.png';
		}
		elsif ($latest->{'stream'}) {
			$stream = $latest->{'stream'};
			$title = $latest->{'title'};
		}
		elsif (ref $latest->{'cards'} eq 'ARRAY') {
			$spread_cards = $latest->{'cards'};
			$title = $latest->{'title'};
		}
		else {
			$card = $latest->{'title'} . '.png';
			$title = $latest->{'title'};
		}
	}

	if (($mode eq 'free' || $mode eq 'cycle' || $mode eq 'spread') && $new_card eq 'new') {
		splice @{$history}, 40;
		my %entry = ( title => $title, timestamp => $timestamp );
		if (ref $spread_cards eq 'ARRAY') { $entry{'cards'} = $spread_cards }
		else { $entry{'stream'} = $stream }
		unshift @{$history}, \%entry;
		&subs::cards_list_write($mode, $history);
	}

	foreach my $h ( @{$history} ) {
		$h->{'description'} = $tree->{$h->{'title'} . '.png'};

	}
	my $html = $c->render_to_string(
		template => 'cards',
		history => $history,
		mode => $mode,
		variant => &subs::setting_grabber({ app => 'cards', setting => 'variant' }),
		bank => &subs::setting_grabber({ app => 'cards', setting => 'solitaire_bank' }),
		blackjack_bank => &subs::setting_grabber({ app => 'cards', setting => 'blackjack_bank' })
	);
	$c->render(json => {
		html => $html,
		description => (defined $card ? $tree->{$card} : undef),
		title => &subs::format_name($title),
		filename => $card,
		history => $history,
		mode => $mode,
		stream => $stream,
		cards => $spread_cards
	});
}

# GET /manager/synth
sub action_28384 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $settings = &subs::settings_grabber({ app => 'synth' });
	my $piano = $gb::piano;
	my $ratio = $piano->[0]->{'__specs'}->{'ratio'};



	for (my $n = 2; $n <= 13; $n++) {
		$piano->[$n]->{'freq'} = $piano->[$n - 1]->{'freq'} * $ratio;
	}


	my $contents = $c->render_to_string(
		template => 'synth',
		window_maker => $c->param('window_maker'),
		piano => $piano,
		settings => $settings
	);
	my $website = &Manager::window_maker({ settings => $settings, user_agent => $c->param('user_agent'), app => 'synth', contents => $contents }, $timestamp);
	$c->render('text' => $website);
#	&appointment_writer($c, {
#		app => 'synth',
#		timestamp => $timestamp,
#		type => 'open',
#	});
}

# GET /manager/studio
sub action_28412 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $songs = &subs::db_select('appointments', undef, { type => 'studio' })->hashes;
	my $settings = &subs::settings_grabber({ app => 'studio' });
	my $data = eval { return decode_json $c->param('data') } || {};
	my $last_song;
	if ($data->{'settings'}) {
		foreach my $s ( @{$data->{'settings'}} ) {
			if ($s->{'setting'} && $s->{'value'}) {
				$settings->{$s->{'setting'}} = $s->{'value'};
				&subs::setting_setter({ app => 'studio', setting => $s->{'setting'}, value => $s->{'value'} });
			}
		}
	}


	if ($data->{'last_song'}) {
		$last_song = $data->{'last_song'};
		$settings->{'last_song'} = $data->{'last_song'};
		&subs::setting_setter({ app => 'studio', setting => 'last_song', value => $data->{'last_song'} });
	}

	foreach my $song ( @{$songs} ) {
		$song->{'data'} = eval { return decode_json $song->{'data'} } || {};
		if ($song->{'uuid'} eq $settings->{'last_song'}) {
			$last_song = $song;
			if (grep { $_->{'setting'} ne 'channel_count' } @{$data->{'settings'}} ) {
				$settings->{'channel_count'} = $last_song->{'data'}->{'admin'}->{'settings'}->{'channel_count'} || $settings->{'channel_count'};
			}
		}
	}
	my $contents = $c->render_to_string(
		template => 'studio/studio',
		window_maker => $c->param('window_maker'),
		songs => $songs,
		settings => $settings,
		last_song => $last_song
	);
	my $html = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'studio', contents => $contents }, $timestamp);
	$c->render(json => {
		html => $html,
		settings => $settings
	});
}

# GET /manager/studio/plug/select
sub action_28457 {
	my $c = shift;
	my $constraints = eval { return decode_json $c->param('constraints') } || {};
	my $apps = eval { return decode_json $c->param('apps') } || [];
	my $screen_share = $c->param('screenShare');
	my $channel = $c->param('channel');
	my $direction = $c->param('direction');
	my $html = $c->render_to_string(
		template => 'studio/plug_selection',
		constraints => $constraints,
		channel => $channel,
		screen_share => $screen_share,
		apps => $apps,
		direction => $direction
	);
	$c->render(json => {
		constraints => $constraints,
		channel => $channel,
		apps => $apps,
		screen_share => $screen_share,
		html => $html
	});
}

# POST /manager/studio/save
sub action_28480 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app')) || 'studio';
	my $app_path = &subs::path_name($app);
	my $timestamp = $c->param('timestamp');
	my $name = $c->param('name');
	my $init = &subs::setting_initializer($app,$timestamp);
	my $jdata = $c->param('studio');
	my $data = eval { decode_json $jdata };
	my $duration = $c->param('duration');
	my $notepad = $c->param('notepad');
	my $uuid = &subs::random_string_creator(20);
	my @files;
	foreach my $u ( @{$c->req->uploads} ) {
		my $folder = &subs::setting_grabber( { app => 'misc', setting => 'rec_location', device => $device } );
		my $location = &subs::home($folder) . '/' . $app_path;
		my $take_uuid = &subs::random_string_creator(17);
		my @filename = split '_', (split /\./, $u->filename)[0];
		my $channel = $filename[-2];
		my $take = $filename[-1];
		$data->{$channel}->{'mixer'}->{'out'}->[$take]->{'uuid'} = $take_uuid;
		my $filename = $location . '/' . $u->filename;
		`mkdir -p $location` unless -e $location;
		$u->move_to($filename);
		push @files, { f => $filename, uuid => $take_uuid, type => 'recording' };
	}
	my $jfile = encode_json \@files;

	$jdata = encode_json $data;
	my $write = {
		timestamp => $timestamp,
		app => &subs::unformat_name($app),
		data => $jdata,
		notes => &subs::note_encrypter(&subs::session_suds($c),$notepad),
		type => 'studio',
		file => $jfile,
		uuid => $uuid,
		duration => $duration || '1000',
		server_time => &subs::rightNow()
	};

#	&appointment_writer($c,$write);

	if ($c->param('uuid') && $c->param('uuid') ne 'undefined') {
		$uuid = $c->param('uuid');
		$write->{'uuid'} = $uuid;
		my $song_saved = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
		my $old_files = eval { return decode_json $song_saved->{'file'} } || [];
		push @files, @{$old_files};
	 	$write->{'file'} = encode_json \@files;
		&subs::db_update('appointments', $write, { uuid => $uuid, app => $app });
	}
	else {
		&appointment_writer($c,$write);
	}

	&subs::setting_setter({ app => 'studio', setting => 'last_song', value => $uuid });
	&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => &subs::session_suds($c) });
	my $songs = &subs::db_select('appointments', undef, { type => 'studio' })->hashes;
	my $song_select = $c->render_to_string(
		template => 'studio/song_select',
		songs => $songs,
		last_song => $uuid
	);
	$c->render(json => { app => $app, uuid => $uuid, studio => $data, songs => $songs, song_select => $song_select });
}

# GET /manager/studio/load
sub action_28546 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $song = &subs::db_select('appointments', undef, { type => 'studio', uuid => $uuid })->hashes->[0];
	my $data = decode_json $song->{'data'};
	my $misc_settings = &misc_setting_list();
	$data->{'admin'}->{'name'} = $song->{'app'};
	$data->{'admin'}->{'uuid'} = $song->{'uuid'};
	my $files = eval { return decode_json $song->{'file'} } || [];
	foreach my $d ( keys %{$data} ) {
		if ($data->{$d}->{'mixer'}) {
			if (eval { @{$data->{$d}->{'mixer'}->{'out'}} }) {
				my $out = $data->{$d}->{'mixer'}->{'out'};
				foreach my $o ( @{$out} ) {
					if ($o->{'uuid'}) {
						my @files = grep { $_->{'uuid'} eq $o->{'uuid'} } @{$files};
						my $file = $files[0];
						$o->{'src'} = '/file_open?file=' . uri_encode $file->{'f'} . '&app=' . $song->{'app'} . '&timestamp=' . $song->{'server_time'};

					}
				}
			}
		}
	}
	&subs::setting_setter({ app => 'studio', setting => 'last_song', value => $uuid });
	$c->render(json => { app => $song->{'app'}, uuid => $song->{'uuid'}, studio => $data, song => $song });
}

# POST /manager/studio/delete
sub action_28573 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $app = $c->param('app');
	my $studio = &subs::db_select('appointments', undef, { app => $app, uuid => $uuid, type => 'studio' })->hashes->[0];
	my $deleter = &delete_app($studio->{'app'},$studio->{'uuid'},$studio->{'server_time'},'studio delete');
	$c->render(json => { 'status' => 'ok' });
}

# GET /manager/twirl
sub action_29083 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = $c->render_to_string(
		settings => &subs::settings_grabber({ app => 'twirl' }),
		template => 'twirl',
		window_maker => $c->param('window_maker')
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'twirl', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# GET /manager/ide
sub action_30779 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');

	my $website = &ide_opener({ timestamp => $timestamp });
	$c->render(json => $website);
}

# POST /manager/ide/folder_selector
sub action_30859 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $folder = $c->param('folder');
	my $search = $c->param('search');
	my $previous = &subs::setting_grabber({ app => 'ide', setting => 'folder_selector' });
	# a chosen root that actually changed starts clean: folders remembered under the
	# old root have no rows here to unfold into. An empty folder is the start-menu
	# open, which keeps whatever the person had unfolded.
	if (defined $folder && length $folder && $folder ne ($previous // '')) {
		&subs::setting_setter({ app => 'ide', setting => 'open_folders', value => '[]' });
	}
	&subs::setting_setter({ app => 'ide', setting => 'folder_selector', value => $folder });
	my $website = &ide_opener({ timestamp => $timestamp, folder => $folder, search => $search });
	$c->render(json => $website);
}

# POST /manager/ide/folder_open
sub action_30875 {
	my $c = shift;
	my $folder = &subs::home($c->param('folder'));
	my $files = &subs::ide_folder_listing($folder);
	my $html = $c->render_to_string(template => 'apps/ide_files', files => $files);
	$c->render(json => { html => $html });
}

# GET /manager/controller
# The handheld's home: eight tiles for the apps it is allowed to reach, so the
# controller opens on a launcher instead of a desk full of windows.
sub action_44001 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = $c->render_to_string(
		template => 'apps/controller',
		window_maker => $c->param('window_maker'),
		power_actions => [ &subs::power_actions() ],
		power_status => eval { &subs::power_status() } || {},
		sound_status => eval { &subs::sound_status() } || {}
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'controller', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# GET /manager/controller/volume
# The launcher's volume panel: the master output this machine plays through and
# the three source channels the house mixes into it. A channel is a gain its
# player multiplies in, so it survives a machine with no card; master writes the
# machine's own mixer and says so when there is none.
sub action_44002 {
	my $c = shift;
	my $status = eval { &subs::sound_status() } || { ok => 0, error => 'the sound reading failed' };
	$status->{'channels'} = eval { &subs::sound_channels() } || {}
		unless ref $status->{'channels'} eq 'HASH';
	$c->render(json => $status);
}

# POST /manager/controller/volume
sub action_44003 {
	my $c = shift;
	my $channel = $c->param('channel') // '';
	my $volume = $c->param('volume');
	my $muted = $c->param('muted');
	my $answer;
	if ($channel eq 'master') {
		my $status = eval { &subs::sound_status() } || {};
		my $output = ref $status->{'output'} eq 'HASH' ? $status->{'output'} : undef;
		if (!$status->{'ok'} || !$output) {
			$c->render(json => { ok => 0, supported => 0, error => 'No sound card',
				channels => eval { &subs::sound_channels() } || {} });
			return;
		}
		if (defined $volume && length $volume) {
			$answer = eval { &subs::sound_set('output', $output->{'id'}, $volume) };
		}
		elsif (defined $muted && length $muted) {
			$answer = eval { &subs::sound_mute('output', $output->{'id'}, $muted eq '1' ? 1 : 0) };
		}
		else {
			$answer = { ok => 0, error => 'nothing to change' };
		}
	}
	else {
		$answer = eval { &subs::sound_channel_set($channel, $volume, $muted) };
		if (ref $answer eq 'HASH' && $answer->{'ok'}) {
			my $status = eval { &subs::sound_status() } || {};
			$answer = { %{$status}, %{$answer} };
		}
	}
	$answer = { ok => 0, error => 'The volume could not be set.' } unless ref $answer eq 'HASH';
	$answer->{'channels'} = eval { &subs::sound_channels() } || {}
		unless ref $answer->{'channels'} eq 'HASH';
	$c->render(json => $answer);
}

# GET /manager/games
# A second launcher, one press in from the Controller's Games tile. Cards and
# Twirl run inside the house; the emulated shelf is the same page with
# ?view=emulated, which draws the ROMs found under ~/roms and the two install
# buttons. The scan is cheap (one directory walk) and every card carries the id
# the launch route checks against it.
sub action_44004 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $view = ($c->param('view') // '') eq 'emulated' ? 'emulated' : 'launcher';
	my $library = eval { &subs::game_library() } || { ok => 0, games => [], systems => [] };
	my $contents = $c->render_to_string(
		template => 'apps/games',
		view => $view,
		library => $library,
		emulators => &subs::game_emulator_present(),
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'games', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# GET /manager/games/library
sub action_44005 {
	my $c = shift;
	$c->render(json => eval { &subs::game_library() } || { ok => 0, games => [], systems => [] });
}

# GET /manager/games/art
# The picture beside a title, if the ROM folder has one. The path comes from the
# scan, never from the request: the id is the only thing a browser sends.
sub action_44006 {
	my $c = shift;
	my $path = eval { &subs::game_art($c->param('id') // '') };
	unless (defined $path && length $path && -f $path) {
		$c->render(text => '', status => 404);
		return;
	}
	my ($suffix) = $path =~ /\.([^.]+)$/;
	my %type = (png => 'image/png', jpg => 'image/jpeg', jpeg => 'image/jpeg', webp => 'image/webp');
	$c->res->headers->content_type($type{lc($suffix // '')} // 'application/octet-stream');
	$c->res->content->asset(Mojo::Asset::File->new(path => $path));
}

# A game outlives the request that starts it: the kiosk has to stop, the
# emulator has to run, and the request is gone long before it ends. The
# subprocessor supervisor puts a warranty on a command and kills it when that
# expires, which left the kiosk stopped and the panel dark. A double fork under
# its own session hands the helper to init, where no request owns it.
sub game_helper_start {
	my ($script, @arguments) = @_;
	return 0 unless defined $script && length $script;
	my $pid = fork();
	return 0 unless defined $pid;
	if ($pid) {
		waitpid($pid, 0);
		return 1;
	}
	POSIX::setsid();
	my $child = fork();
	POSIX::_exit(0) if $child;
	open(STDIN, '<', '/dev/null');
	open(STDOUT, '>', '/dev/null');
	open(STDERR, '>', '/dev/null');
	no warnings 'exec';
	exec('sudo', '-n', $^X, $script, @arguments);
	POSIX::_exit(127);
}

# POST /manager/games/install
sub action_44007 {
	my $c = shift;
	my $what = $c->param('what') // '';
	unless ($what =~ /^(?:emulators|roms)$/) {
		$c->render(json => { ok => 0, error => 'The shelf offers only emulators and roms.' });
		return;
	}
	my $script = Cwd::abs_path('scripts/jawnos_game_install.pl');
	my $started = eval { &game_helper_start($script, $what) };
	$c->render(json => $started ? { ok => 1, what => $what } : { ok => 0, error => 'The installer could not start.' });
}

# GET /manager/games/install_status
# The helper runs detached, so it reports through one JSON row in /run. A row
# that is missing (or unreadable) is 'idle', not an error.
sub action_44008 {
	my $c = shift;
	my $status = { state => 'idle' };
	my $path = '/run/jawnos-games/install.json';
	if (-f $path) {
		my $raw = '';
		if (open(my $fh, '<', $path)) { local $/; $raw = <$fh> // ''; close $fh; }
		my $parsed = eval { Mojo::JSON->new->decode($raw) };
		$status = $parsed if ref $parsed eq 'HASH';
	}
	$status->{'installed'} = &subs::game_emulator_present() ? 1 : 0;
	$c->render(json => $status);
}

# POST /manager/games/launch
# The launcher is torn down when the kiosk stops, so the answer only says the
# helper started; if the library or the emulator is missing the page is told
# before anything is stopped.
sub action_44009 {
	my $c = shift;
	my $game = eval { &subs::game_by_id($c->param('id') // '') };
	unless (ref $game eq 'HASH') {
		$c->render(json => { ok => 0, error => 'That game is not in the library.' });
		return;
	}
	my $runner = &subs::game_runner($game->{'system'});
	unless (ref $runner eq 'HASH') {
		$c->render(json => { ok => 0, error => 'There is no emulator for this system.' });
		return;
	}
	if ($runner->{'missing'}) {
		$c->render(json => { ok => 0, error => 'Install the emulators first.' });
		return;
	}
	if ($runner->{'kind'} eq 'retroarch' && !&subs::game_emulator_present()) {
		$c->render(json => { ok => 0, error => 'Install the emulators first.' });
		return;
	}
	my $script = Cwd::abs_path('scripts/jawnos_game_launch.pl');
	my $started = eval { &game_helper_start($script, $game->{'id'}) };
	$c->render(json => $started ? { ok => 1, title => $game->{'title'} } : { ok => 0, error => 'The emulator could not start.' });
}

1;
