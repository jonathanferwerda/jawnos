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
use File::Spec ();
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
use IPC::Open3 qw(open3);

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
	# A shell command is the trusted rung of the peer ladder: a resident peer
	# session reaches /manager but may not run one here.
	unless (&peer_action_gate($c, 'command')) {
		$c->rendered(403);
		return;
	}
	my $timestamp = $c->param('timestamp');
	$c->render(text => 'ok');

	if ($c->param('command') eq 'telephone') {
		&subs::telephone_contacts_check();
		&subs::telephone_call_log_check();
	}
	else {
		my $return = &subs::run_command('terminal',$c->param('command'),$timestamp,{ terminal => 1 });
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
		$file->{'ocr'} = &subs::html_text($file->{'ocr'});
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

	# The mode bar sends the mode it just chose, so the reply does not depend on
	# that choice's setting write having landed first; the Deal button and a
	# touch on the card pass no mode and read the stored one.
	my $mode = $c->param('mode');
	$mode = &subs::setting_grabber({ app => 'cards', setting => 'mode' })
		unless defined $mode && length $mode;


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
	my $information = eval { return decode_json $c->param('information') } || {};
	$information = {} unless ref $information eq 'HASH';

	# An input's picker also offers this machine's capture sources, so a take
	# can name the microphone it means instead of taking the default. The plan
	# is the truth: the source the channel's input number already names is the
	# one the picker opens on.
	my $sources = [];
	my $input_node = '';
	my $input = $information->{'input'};
	$input = 0 unless defined $input && !ref $input && $input =~ /\A\d+\z/;
	if (defined $direction && $direction eq 'input') {
		$sources = eval { &subs::audio_capture_sources() } || [];
		my $plan = eval { &subs::audio_plan_read() } || { sources => [] };
		# A source is this machine's when it names no machine, or names this
		# one: Sound's form and the engine both write the hostname.
		require JawnOS::Audio::Plan;
		my ($source) = grep {
			($_->{'kind'} || '') eq 'input'
				&& JawnOS::Audio::Plan::audio_plan_on_this_machine($_->{'machine'})
				&& ($_->{'channel'} || 0) == $input
		} @{ $plan->{'sources'} || [] };
		$input_node = $source ? ($source->{'node'} || '') : '';
	}

	my $html = $c->render_to_string(
		template => 'studio/plug_selection',
		constraints => $constraints,
		channel => $channel,
		screen_share => $screen_share,
		apps => $apps,
		direction => $direction,
		sources => $sources,
		input => $input,
		input_node => $input_node,
	);
	$c->render(json => {
		constraints => $constraints,
		channel => $channel,
		apps => $apps,
		screen_share => $screen_share,
		html => $html,
	});
}

# POST /manager/studio/input/node
# The input picker's save: the plan's input source on this device channel now
# captures the named PipeWire/Pulse source (or the machine's default, when the
# name is empty). The answer is the saved plan, so the page never guesses.
sub action_28458 {
	my $c = shift;
	my $answer = eval {
		&subs::audio_plan_source_node_write($c->param('channel'), $c->param('node'))
	};
	$answer = { ok => 0, error => ($@ ? "$@" : 'the input source could not be saved') }
		unless ref $answer eq 'HASH';
	$c->render(json => $answer);
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
		my $filename = $location . '/' . &subs::path_name($u->filename);
		system('mkdir', '-p', $location) unless -e $location;
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
	unless (&subs::path_is_under($folder, &subs::home('~'), '/sdcard', '/storage')) {
		return $c->render(json => { html => '' }, status => 403);
	}
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
		sound_status => eval { &subs::sound_status() } || {},
		clock_zone => (&subs::misc_setting('clock_timezone') || 'America/New_York')
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
# A second launcher, one press in from the Controller's Games tile. The house's
# own games run inside it and are listed most recently played first, from the
# play ledger; the emulated shelf is the same page with ?view=emulated, which
# draws the ROMs found under ~/roms and the two install buttons. The scan is
# cheap (one directory walk) and every card carries the id the launch route
# checks against it.
sub action_44004 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $view = ($c->param('view') // '') eq 'emulated' ? 'emulated' : 'launcher';
	my $library = eval { &subs::game_library() } || { ok => 0, games => [], systems => [] };
	# One tile per house game, the card games sharing the recency of the table
	# played last. rank is the fixed tie-break, so a shelf nobody has touched
	# still reads Cards, Twirl, Pipedream, Minesweeper.
	my @jawnos_games = (
		{ key => 'cards', title => 'Cards', note => 'The card room: solitaire, spider, mahjong and blackjack',
			icon => '/images/decipherable/cards.png', rank => 0,
			projects => [ 'Solitaire', 'Spider Solitaire', 'Mahjong', 'Blackjack' ] },
		{ key => 'twirl', title => 'Twirl', note => 'The falling-block puzzle: A turns one way and B the other',
			icon => '/images/decipherable/tetris.png', rank => 1, projects => [ 'Twirl' ] },
		{ key => 'pipedream', title => 'Pipedream', note => 'Place the pipes before the liquid spills',
			icon => '/images/decipherable/tunnel.png', rank => 2, projects => [ 'Pipedream' ] },
		{ key => 'minesweeper', title => 'Minesweeper', note => 'Clear the field without hitting a mine',
			icon => '/images/decipherable/marker.png', rank => 3, projects => [ 'Minesweeper' ] },
	);
	if ($view eq 'launcher') {
		# The play ledger writes a games appointment per game, its project the
		# name the game reports. A game with no row is simply unplayed (0).
		my $played = {};
		my $rows = eval {
			&subs::db_query(
				"select project, max(cast(timestamp as integer)) as last_at from appointments"
					. " where app = 'games' and project is not null and project != '' group by project"
			)->hashes;
		} || [];
		$played->{ $_->{'project'} } = $_->{'last_at'} // 0 for grep { ref $_ eq 'HASH' && defined $_->{'project'} } @{ $rows };
		for my $game (@jawnos_games) {
			$game->{'last_at'} = 0;
			for my $project (@{ $game->{'projects'} }) {
				my $at = $played->{$project} // 0;
				$game->{'last_at'} = $at if $at > $game->{'last_at'};
			}
		}
		@jawnos_games = sort {
			($b->{'last_at'} <=> $a->{'last_at'}) || ($a->{'rank'} <=> $b->{'rank'})
		} @jawnos_games;
	}
	for my $game (@jawnos_games) {
		delete $game->{'projects'};
		delete $game->{'rank'};
	}
	my $contents = $c->render_to_string(
		template => 'apps/games',
		view => $view,
		library => $library,
		emulators => &subs::game_emulator_present(),
		jawnos_games => \@jawnos_games,
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
# scan's index, never from the request: the id is the only thing a browser sends.
# The index is what keeps a page of cards from pinning the request loop: a scan
# behind every image is a tree walk per card.
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
	# A cover changes only when it is fetched again, so a revisit draws it from
	# the browser's own cache instead of asking this route for every card.
	$c->res->headers->cache_control('private, max-age=300');
	# reply->file finishes the response. Setting the content asset alone left
	# the request open, so every card waited five minutes for a cover that had
	# already been found.
	$c->reply->file($path);
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
	# The runner id travels with the launch so the helper runs the same emulator
	# the route checked, not merely the system's default one.
	my $started = eval { &game_helper_start($script, $game->{'id'}, $runner->{'id'}) };
	$c->render(json => $started ? { ok => 1, title => $game->{'title'} } : { ok => 0, error => 'The emulator could not start.' });
}

# POST /manager/games/emulator
# The Systems picker saves one emulator per system. The choice is a house
# setting on this device, and the domain refuses any runner this machine cannot
# actually run, so a crafted request cannot store a broken pick.
sub action_44015 {
	my $c = shift;
	my $body = eval { $c->req->json } || {};
	$body = {} unless ref $body eq 'HASH';
	my $system = defined $body->{'system'} ? $body->{'system'} : $c->param('system');
	my $runner = defined $body->{'runner'} ? $body->{'runner'} : $c->param('runner');
	my $answer = eval { &subs::game_runner_choose($system // '', $runner // '') };
	$answer = { ok => 0, error => 'The emulator could not be saved.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# POST /manager/games/covers
# One detached helper looks up covers for the whole shelf. This request only
# starts it: the shelf's scan and the downloads belong to the helper, so a press
# never holds the manager's one request loop while a cover is fetched. A helper
# already running is not started twice: the page is told to keep polling its row.
sub action_44016 {
	my $c = shift;
	my $path = '/run/jawnos-games/covers.json';
	if (-f $path) {
		my $raw = '';
		if (open(my $fh, '<', $path)) { local $/; $raw = <$fh> // ''; close $fh; }
		my $status = eval { Mojo::JSON->new->decode($raw) };
		if (ref $status eq 'HASH' && ($status->{'state'} // '') eq 'running') {
			$c->render(json => { ok => 1, state => 'running' });
			return;
		}
	}
	my $script = Cwd::abs_path('scripts/rom_covers.pl');
	my $started = eval { &game_helper_start($script) };
	$c->render(json => $started ? { ok => 1 } : { ok => 0, error => 'The cover lookup could not start.' });
}

# GET /manager/games/covers/status
# The helper writes one JSON row in /run; a missing or unreadable row is
# 'idle', exactly as the install row behaves.
sub action_44017 {
	my $c = shift;
	my $status = { state => 'idle' };
	my $path = '/run/jawnos-games/covers.json';
	if (-f $path) {
		my $raw = '';
		if (open(my $fh, '<', $path)) { local $/; $raw = <$fh> // ''; close $fh; }
		my $parsed = eval { Mojo::JSON->new->decode($raw) };
		$status = $parsed if ref $parsed eq 'HASH';
	}
	$c->render(json => $status);
}

# GET /manager/games/launch_status
# The launch helper writes one row in /run before it hides the kiosk. The page
# reads it back, so a helper that failed on the way to the emulator says why
# instead of leaving "Starting..." on screen. A missing row is 'idle'.
sub action_44018 {
	my $c = shift;
	my $status = { state => 'idle' };
	my $path = '/run/jawnos-games/launch.json';
	if (-f $path) {
		my $raw = '';
		if (open(my $fh, '<', $path)) { local $/; $raw = <$fh> // ''; close $fh; }
		my $parsed = eval { Mojo::JSON->new->decode($raw) };
		$status = $parsed if ref $parsed eq 'HASH';
	}
	$c->render(json => $status);
}

# POST /manager/game_play
# A browser game reports its own touch, pause and stop. The domain keeps the
# same appointment shape the Gou's tick uses, so play time from the desk, the
# phone and the handheld all sit in one ledger.
sub action_44019 {
	my $c = shift;
	my $body = eval { $c->req->json } || {};
	$body = {} unless ref $body eq 'HASH';
	my $game = defined $body->{'game'} ? $body->{'game'} : $c->param('game');
	my $state = defined $body->{'state'} ? $body->{'state'} : $c->param('state');
	my $at = defined $body->{'at'} ? $body->{'at'} : $c->param('at');
	my $answer = eval { &subs::browser_game_play({ game => $game // '', state => $state // 'play', at => $at // 0 }) };
	$answer = { ok => 0, error => 'The play session could not be saved.' } unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# GET /manager/games/play
# A desk or a phone has no DOSBox of its own, so a DOS card opens the same game
# in js-dos: DOSBox compiled for the browser. The page is a window of its own,
# and only the card's id travels; the bundle route re-finds that id in the
# library. The native shelf remains the handheld's way in, so this is offered
# on the two devices that do not have one.
sub action_44024 {
	my $c = shift;
	my $game = eval { &subs::game_by_id($c->param('id') // '') };
	my $timestamp = $c->param('timestamp');
	unless (ref $game eq 'HASH' && &subs::game_browser_runnable($game)) {
		my $contents = '<div style="padding:22px;line-height:1.5;max-width:640px;">'
			. &subs::ui('That game cannot run in this browser.')
			. '</div>';
		my $website = &Manager::window_maker({
			user_agent => $c->param('user_agent'), app => 'dos',
			window_name => 'DOS', title => 'DOS', contents => $contents,
		}, $timestamp);
		$c->render(text => $website);
		return;
	}
	my $contents = $c->render_to_string(template => 'apps/games/player', game => $game);
	my $website = &Manager::window_maker({
		user_agent => $c->param('user_agent'), app => 'dos',
		window_name => $game->{'title'}, title => $game->{'title'}, contents => $contents,
	}, $timestamp);
	$c->render(text => $website);
}

# GET /manager/games/dos_bundle
# The game's own folder as a js-dos bundle: a zip whose .jsdos/dosbox.conf
# mounts C: and runs the card. The id is the only request value, and it is
# re-found in the library before any path is used; the bundle itself is built
# under the person's cache and served from there.
sub action_44025 {
	my $c = shift;
	my $bundle = eval { &subs::game_browser_bundle($c->param('id') // '') };
	unless (ref $bundle eq 'HASH' && $bundle->{'ok'}
		&& defined $bundle->{'path'} && length $bundle->{'path'} && -f $bundle->{'path'}) {
		my $error = (ref $bundle eq 'HASH' && defined $bundle->{'error'} && length $bundle->{'error'})
			? $bundle->{'error'} : 'The game bundle could not be made.';
		$c->render(text => $error, status => 404);
		return;
	}
	$c->res->headers->content_type('application/zip');
	$c->res->headers->cache_control('private, max-age=0');
	$c->reply->file($bundle->{'path'});
}

# GET /manager/controller/config
# The Configuration tile used to open the house's Configure app, which is a desk
# of settings a handheld cannot comfortably use. It opens this sublauncher
# instead: four machine settings and the emulator's own knobs, one press each.
sub action_44010 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = $c->render_to_string(template => 'controller/config');
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'controller', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# GET /manager/controller/time
# Time settings for the handheld: the zone the launcher and the taskbar read,
# and what the machine's own clock is doing. The zone is a house setting, and
# saving it also writes it into the operating system (through timedatectl, or
# the /etc/localtime link when that is absent), so the box and every surface
# agree on the person's time.
sub action_44011 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $zone = &subs::misc_setting('clock_timezone');
	$zone = 'America/New_York' unless defined $zone && length $zone;
	my $system_zone = '';
	if (open(my $fh, '<', '/etc/timezone')) { $system_zone = <$fh> // ''; close $fh; $system_zone =~ s/\s+$//; }
	unless (length $system_zone) {
		my $link = readlink('/etc/localtime');
		($system_zone) = ($link // '') =~ m{zoneinfo/(.+)$};
		$system_zone = '' unless defined $system_zone;
	}
	my @zones = (
		'America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles',
		'America/Anchorage', 'Pacific/Honolulu', 'America/Toronto', 'America/Phoenix',
		'Europe/London', 'Europe/Paris', 'Europe/Berlin', 'Asia/Tokyo', 'Australia/Sydney', 'UTC',
	);
	unshift @zones, $zone unless grep { $_ eq $zone } @zones;
	my $contents = $c->render_to_string(
		template => 'controller/time',
		zone => $zone,
		zones => \@zones,
		system_zone => $system_zone,
		synchronized => (-e '/run/systemd/timesync/synchronized' ? 1 : 0),
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'controller', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# POST /manager/controller/time
sub action_44012 {
	my $c = shift;
	my $zone = $c->param('timezone') // '';
	my $ok = ($zone eq 'local')
		|| ($zone =~ m{^[A-Za-z0-9_+\-/]+$} && $zone !~ m{\.\.} && -e "/usr/share/zoneinfo/$zone");
	unless ($ok) {
		$c->render(json => { ok => 0, error => 'That is not a time zone this machine knows.' });
		return;
	}
	my $saved = &subs::setting_setter({ app => 'misc', setting => 'clock_timezone', value => $zone });
	my $zone_os = ref $saved eq 'HASH' ? $saved->{'timezone_os'} : undef;
	$c->render(json => { ok => 1, timezone => $zone, ($zone_os ? (timezone_os => $zone_os) : ()) });
}

# GET /manager/controller/retroarch
# The emulator's knobs, read from and written back to the same files RetroArch
# loads. Audio and video are here because a rebuilt frontend can pitch-shift or
# stutter on the handheld's single sound card; the two 3D cores carry the frame
# skip and threading that decide whether a game is playable.
sub action_44013 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $settings = eval { &subs::retroarch_settings() } || { ok => 0, error => 'The RetroArch settings could not be read.' };
	my $contents = $c->render_to_string(template => 'controller/retroarch', settings => $settings);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'controller', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# POST /manager/controller/panel
#
# The idle timeout's dark, and the press that brings it back. A word from the
# page, never a path: blank or unblank, nothing else.
sub action_44020 {
	my $c = shift;
	my $on = ($c->param('action') || '') eq 'unblank' ? 1 : 0;
	my $result = eval { &subs::panel_blank($on) } || { ok => 0, error => 'the panel could not be changed' };
	$c->render(json => $result);
}

# GET /manager/controller/power
#
# The desk's Power page, rendered inside a controller window. The CPU plan and
# the two timeouts are the same controls, reading and writing the same rows.
# The controller wrapper is what hides the desk's title bar (whose app glyph
# is drawn at its natural size on a page without the desk's stylesheet) and
# carries the way back; without it the page arrived as a giant power logo over
# a control set with nothing to drive it.
sub action_44021 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $status = eval { &subs::power_status() } || {};
	my $power = $c->render_to_string(template => 'apps/power', status => $status);
	my $contents = $c->render_to_string(template => 'controller/power', contents => $power);
	my $website = &Manager::window_maker({
		user_agent => $c->param('user_agent'), app => 'power', contents => $contents,
	}, $timestamp);
	$c->render(text => $website);
}

# POST /manager/controller/retroarch
sub action_44014 {
	my $c = shift;
	my $answer;
	if (my $preset = $c->param('preset')) {
		$answer = eval { &subs::retroarch_preset($preset) };
	}
	else {
		$answer = eval { &subs::retroarch_set($c->param('key'), $c->param('value'), $c->param('core')) };
	}
	$answer = { ok => 0, error => 'The setting could not be changed.' } unless ref $answer eq 'HASH';
	$answer->{'settings'} = eval { &subs::retroarch_settings() } || { ok => 0 };
	$c->render(json => $answer);
}

# POST /manager/studio/latency
#
# The backend picker beside Studio's round-trip meter. `javascript` is the
# browser's own probe and is deliberately refused here (400): the page calls
# studioLatencyMeter() for it, so this route must never start a process for a
# path the browser already measures. The native names run the staged engine
# once, with a fixed argv and a hard timeout.
sub action_44022 {
	my $c = shift;
	my ($status, $data) = &studio_latency_engine($c->param('backend'));
	$c->render(json => $data, status => $status);
}

my %studio_latency_backend = map { $_ => 1 } qw(alsa pipewire jack javascript);

# POST /manager/studio/take
#
# Studio's transport for the engine's control socket: start a take, ask how it
# is going, move one strip knob, or stop it. A take's name is the server's, not
# the browser's: the request carries a length and a start position only, so no
# parameter can name a path, reach a shell or reach an argv. `status`, `stop` and
# `param` relay whatever the engine says, including "not running" and "no take
# is running", because either is a usable answer. A `param`'s name must have the
# contract's shape (`<insert>.<control>`, or `gain`/`pan`); whether that insert
# is armed and that control exists is the engine's answer, relayed unchanged.
sub action_44023 {
	my $c = shift;
	require JawnOS::Audio::Engine;

	my $action = $c->param('action');
	$action = '' unless defined $action;

	if ($action eq 'status') {
		my $status = &JawnOS::Audio::Engine::audio_engine_status();
		$status = {} unless ref $status eq 'HASH';
		# `installed` is the machine's engine, not this take: a staged binary
		# that is not running is still the capture path the page must use
		# instead of the browser microphone. `available` is the live socket.
		my $binary = &JawnOS::Audio::Engine::audio_engine_binary();
		$status->{'installed'} = (defined $binary && length $binary && -x $binary) ? 1 : 0;
		$status->{'available'} = &JawnOS::Audio::Engine::audio_engine_available() ? 1 : 0;
		$c->render(json => $status);
		return;
	}
	if ($action eq 'stop') {
		$c->render(json => &JawnOS::Audio::Engine::audio_engine_stop());
		return;
	}
	if ($action eq 'param') {
		my $target = $c->param('target');
		if (defined $target && $target eq 'listen') {
			my ($error, $name, $value) = &studio_listen_param(
				$c->param('name'), $c->param('value'),
			);
			if (defined $error) {
				$c->render(json => { ok => 0, error => $error }, status => 400);
				return;
			}
			$c->render(json => &JawnOS::Audio::Engine::audio_engine_param(
				undef, $name, $value, 'listen',
			));
			return;
		}
		if (defined $target && $target eq 'master') {
			my ($error, $name, $value) = &studio_master_param(
				$c->param('name'), $c->param('value'),
			);
			if (defined $error) {
				$c->render(json => { ok => 0, error => $error }, status => 400);
				return;
			}
			$c->render(json => &JawnOS::Audio::Engine::audio_engine_param(
				undef, $name, $value, 'master',
			));
			return;
		}
		if (defined $target && $target eq 'input') {
			my ($error, $name, $value) = &studio_input_param(
				$c->param('name'), $c->param('value'),
			);
			if (defined $error) {
				$c->render(json => { ok => 0, error => $error }, status => 400);
				return;
			}
			$c->render(json => &JawnOS::Audio::Engine::audio_engine_param(
				undef, $name, $value, 'input',
			));
			return;
		}
		my ($error, $track, $name, $value) = &studio_take_param(
			$c->param('track'), $c->param('name'), $c->param('value'),
		);
		if (defined $error) {
			$c->render(json => { ok => 0, error => $error }, status => 400);
			return;
		}
		$c->render(json => &JawnOS::Audio::Engine::audio_engine_param($track, $name, $value));
		return;
	}
	if ($action eq 'listen_start') {
		my ($status, $answer) = &studio_listen_start(
			$c->param('channel'),
			$c->param('gain'),
			$c->param('pan'),
			$c->param('inserts'),
		);
		$c->render(json => $answer, status => $status);
		return;
	}
	if ($action eq 'listen_stop') {
		$c->render(json => &JawnOS::Audio::Engine::audio_engine_stop());
		return;
	}
	unless ($action eq 'start') {
		$c->render(json => { ok => 0, error => 'choose an action: start, stop or status, listen_start or listen_stop, or param' }, status => 400);
		return;
	}

	my ($status, $answer) = &studio_take_start(
		$c->param('seconds'),
		$c->param('start_at'),
		$c->param('tracks'),
		$c->param('inputs'),
		$c->param('inserts'),
		$c->param('tracks_json'),
		$c->param('master_json'),
		$c->param('monitor_input'),
		$c->param('monitor_gain'),
	);
	$c->render(json => $answer, status => $status);
	return;
}

our $studio_take_seconds_default = 10;
our $studio_take_seconds_min     = 1;
our $studio_take_seconds_max     = 3600;

# A malformed length is the default rather than a refusal: the engine's own
# default is ten seconds, and a page that sends "10s" means ten. The clamp is
# the whole validation the engine needs.
sub studio_take_seconds {
	my ($value) = @_;
	$value = $studio_take_seconds_default
		unless defined $value && $value =~ /\A\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)\s*\z/;
	$value += 0;
	return $studio_take_seconds_min if $value < $studio_take_seconds_min;
	return $studio_take_seconds_max if $value > $studio_take_seconds_max;
	return $value;
}

# A start position is a whole, non-negative sample count. The engine holds it
# in a u64; a Perl NV is exact to 2^53, and a larger claim cannot be a real
# position on any house device, so it falls back to zero like a malformed one.
sub studio_take_start_at {
	my ($value) = @_;
	return 0 unless defined $value && $value =~ /\A\s*\+?(\d+)\s*\z/;
	$value = $1 + 0;
	return 0 if $value <= 0;
	return 0 if $value > 9_007_199_254_740_991;
	return int($value);
}

# The machine's recording folder, resolved the way every other recording path
# is (misc/rec_location, then `~`), and made absolute because the engine refuses
# a relative `out`. An unset or unusable setting is the empty string, which the
# route turns into one clear refusal.
sub studio_take_folder {
	my $folder = eval { &subs::setting_grabber({ app => 'misc', setting => 'rec_location' }) };
	return '' unless defined $folder && !ref $folder && length $folder;
	my $dir = eval { &subs::home($folder) };
	$dir = $folder unless defined $dir && length $dir;
	unless (File::Spec->file_name_is_absolute($dir)) {
		require JawnOS::Platform::Paths;
		my $home = JawnOS::Platform::Paths::home();
		$dir = File::Spec->catdir($home, $dir) if defined $home && length $home;
	}
	return $dir;
}

# `studio-take-<epoch>-<n>.wav`, with n the first free number in that second.
# The engine writes the file, so the name is settled before the command and
# never comes from the request.
sub studio_take_path {
	my ($folder, $epoch) = @_;
	$epoch = time() unless defined $epoch;
	my $take = 1;
	$take++ while -e File::Spec->catfile($folder, "studio-take-$epoch-$take.wav");
	return File::Spec->catfile($folder, "studio-take-$epoch-$take.wav");
}

# The inserts the engine can build. `reverb2` is the web's alias for reverb and
# is not a second name; the page sends the engine's spelling. The engine's
# `InsertKind` is still the authority: this list only refuses a chain the socket
# could never build, before the engine is dialled.
our %studio_take_inserts = map { $_ => 1 } qw(
	tone distortion delay compressor reverb flanger fuzz amp limiter
	autotune equalizer maximizer
);
# The five effects the native master rack can build, in the contract's order.
# A take names the ones it wants; the engine builds them in this order whatever
# order the page sent.
our %studio_take_master_inserts = map { $_ => 1 } qw(
	master_comp master_eq master_reverb master_maximizer master_limiter
);
our $studio_take_tracks_max = 32;
our $studio_take_input_max  = 31;

# The documented parameter shape (`docs/studio-effects.md`, "The control
# path"): `<insert>.<control>` in lowercase, plus the strip's own `gain` and
# `pan`. The engine is the authority on whether that insert is in the armed
# chain and that control belongs to it; checking the shape here still turns a
# mistyped key into this route's 400 instead of a line the engine has to refuse.
sub studio_param_shape {
	my ($name) = @_;
	$name = '' unless defined $name;
	return 1 if $name eq 'gain' || $name eq 'pan';
	return $name =~ /\A[a-z0-9_]+\.[a-z0-9_]+\z/ ? 1 : 0;
}

# Validate one `param` request and return (error, track, name, value). An
# undefined error means the values are ready for the engine. The name must have
# the contract's shape, the track is 0-based and inside the engine's track
# bound, and the value is a finite decimal: the exponent form is accepted, a
# NaN or an infinity is not (the engine's own rule). Nothing here can name a
# path.
sub studio_take_param {
	my ($track, $name, $value) = @_;

	return ('track must be a whole number, 0 or more')
		unless defined $track && $track =~ /\A\s*\+?(\d+)\s*\z/;
	$track = $1 + 0;
	return ('track must be a whole number, 0 or more')
		unless $track < $studio_take_tracks_max;

	$name = '' unless defined $name;
	return ("no such parameter: $name") unless &studio_param_shape($name);

	return ('value must be a finite number')
		unless defined $value
			&& $value =~ /\A\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?\s*\z/;
	$value += 0;
	# NaN fails the first test and an infinity the second (x - x is NaN).
	return ('value must be a finite number')
		unless $value == $value && ($value - $value) == 0;

	return (undef, $track, $name, $value);
}

# --- live listening ----------------------------------------------------------
# A listen is not a take: it names an input number (0 microphone, 1 instrument),
# a gain and pan, and the same five inserts a take can build. The browser never
# names a device or a file; the engine is already pointed at the box's inputs.

our $studio_listen_gain_default = 0.8;
our $studio_listen_gain_max     = 4;
our $studio_listen_pan_max      = 1;

# A finite decimal in the engine's own spelling; undef means it is not one.
sub studio_listen_number {
	my ($value) = @_;
	return undef
		unless defined $value
			&& $value =~ /\A\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?\s*\z/;
	$value += 0;
	return undef unless $value == $value && ($value - $value) == 0;
	return $value;
}

sub studio_listen_clamp {
	my ($value, $low, $high) = @_;
	return $low if $value < $low;
	return $high if $value > $high;
	return $value;
}

# Validate one `listen` request and return [status, engine answer]. A missing
# gain takes the page's own default; a non-number is refused here so nothing bad
# reaches the socket. Extra gain is clamped rather than refused.
sub studio_listen_start {
	my ($channel, $gain, $pan, $inserts) = @_;

	$channel = '' unless defined $channel;
	return (400, { ok => 0, error => 'channel must be 0 (microphone) or 1 (instrument)' })
		unless $channel =~ /\A\s*[01]\s*\z/;
	$channel += 0;

	my $gain_value = $studio_listen_gain_default;
	if (defined $gain && length $gain) {
		$gain_value = &studio_listen_number($gain);
		return (400, { ok => 0, error => 'gain must be a finite number' })
			unless defined $gain_value;
	}
	$gain_value = &studio_listen_clamp($gain_value, 0, $studio_listen_gain_max);

	my $pan_value = 0;
	if (defined $pan && length $pan) {
		$pan_value = &studio_listen_number($pan);
		return (400, { ok => 0, error => 'pan must be a finite number' })
			unless defined $pan_value;
		$pan_value = &studio_listen_clamp($pan_value, -$studio_listen_pan_max, $studio_listen_pan_max);
	}

	my @list;
	if (defined $inserts && length $inserts) {
		for my $part (split /,/, $inserts) {
			$part =~ s/\A\s+|\s+\z//g;
			next unless length $part;
			return (400, { ok => 0, error => "no such insert: $part" })
				unless $studio_take_inserts{$part};
			push @list, $part;
		}
	}

	require JawnOS::Audio::Engine;
	my $answer = &JawnOS::Audio::Engine::audio_engine_listen(
		$channel, $gain_value, $pan_value, \@list,
	);
	$answer = { ok => 0, error => 'the audio engine did not answer' }
		unless ref $answer eq 'HASH';
	return (200, $answer);
}

# One listen knob: gain, pan or any `<insert>.<control>` the engine's armed
# listen strip can name. The shape is checked here; the engine refuses a control
# the effect does not have.
sub studio_listen_param {
	my ($name, $value) = @_;
	$name = '' unless defined $name;
	return ("no such parameter: $name") unless &studio_param_shape($name);
	my $number = &studio_listen_number($value);
	return ('value must be a finite number') unless defined $number;
	return (undef, $name, $number);
}

# One master-rack knob. The rack is not a track, so there is no track to check;
# the contract's master names are `master_comp`, `master_eq`, `master_reverb`,
# `master_maximizer` and `master_limiter`, and the engine refuses a prefix the
# rack does not hold. The shape check still keeps a typo off the socket.
sub studio_master_param {
	my ($name, $value) = @_;
	$name = '' unless defined $name;
	return ("no such parameter: $name")
		unless &studio_param_shape($name) && $name =~ /\Amaster_[a-z0-9_]+\./;
	my $number = &studio_listen_number($value);
	return ('value must be a finite number') unless defined $number;
	return (undef, $name, $number);
}

# One live-input knob. The monitor bus carries a single control, `gain`; the
# value is a finite decimal clamped to the engine's own range. Any other name
# is a refusal, not a silent no-op.
sub studio_input_param {
	my ($name, $value) = @_;
	$name = '' unless defined $name;
	return ('target "input" only carries "gain"') unless $name eq 'gain';
	my $number = &studio_listen_number($value);
	return ('value must be a finite number') unless defined $number;
	return (undef, 'gain', &studio_listen_clamp($number, 0, $studio_listen_gain_max));
}

# The page's per-track plan, as a JSON array of `{ input, channels, inserts }`. The
# engine accepts that shape directly, so this only refuses what it could not
# build: an input outside 0..31, an insert the engine does not have, a duplicate
# input, or more tracks than the engine takes. When this field is present it
# wins: the scalar `tracks`/`inputs`/`inserts` fields describe the older page's
# one global chain and are ignored here.
sub studio_take_json_plan {
	my ($tracks_json) = @_;
	my $decoded = eval { decode_json($tracks_json) };
	return ('tracks_json must be a JSON array of tracks', undef)
		unless ref $decoded eq 'ARRAY';
	return ('tracks_json must name between 1 and 32 tracks', undef)
		unless @$decoded >= 1 && @$decoded <= $studio_take_tracks_max;

	my (@plan, %seen_input, %claimed);
	for my $index (0 .. $#$decoded) {
		my $entry = $decoded->[$index];
		my $label = 'tracks_json track ' . ($index + 1);
		return ("$label must be an object", undef) unless ref $entry eq 'HASH';

		my $input = $entry->{'input'};
		return ("$label needs an input between 0 and 31", undef)
			unless defined $input && !ref $input && $input =~ /\A\+?\d+\z/
				&& $input <= $studio_take_input_max;
		$input += 0;
		return ("$label names input $input twice", undef) if $seen_input{$input}++;

		# `channels` is whole 1 or 2 and defaults to mono. A pair claims
		# both device channels, so uniqueness is by claimed channel and the
		# last one cannot pass the input bound.
		my $channels = 1;
		if (defined $entry->{'channels'}) {
			my $raw = $entry->{'channels'};
			return ("$label channels must be 1 (mono) or 2 (stereo)", undef)
				unless !ref $raw && $raw =~ /\A\+?[12]\z/;
			$channels = $raw + 0;
		}
		my $last = $input + $channels - 1;
		return ("$label needs an input between 0 and 30 for a stereo pair", undef)
			if $last > $studio_take_input_max;
		for my $channel ($input .. $last) {
			next unless exists $claimed{$channel};
			my $other = $claimed{$channel};
			my $other_channels = $plan[$other]{'channels'} // 1;
			my $pair = $other_channels == 2
				? 'stereo pair ' . $plan[$other]{'input'} . '-' . ($plan[$other]{'input'} + 1)
				: 'input ' . $plan[$other]{'input'};
			return ("$label input $input overlaps track " . ($other + 1) . "'s $pair", undef);
		}
		$claimed{$_} = $index for $input .. $last;

		my $inserts = $entry->{'inserts'};
		$inserts = [] unless defined $inserts;
		return ("$label inserts must be an array", undef)
			unless ref $inserts eq 'ARRAY';
		my @chain;
		for my $name (@$inserts) {
			return ("$label inserts must hold insert names", undef)
				unless defined $name && !ref $name;
			return ("no such insert: $name", undef)
				unless $studio_take_inserts{$name};
			push @chain, $name;
		}
		my %track = (input => $input, inserts => \@chain);
		$track{'channels'} = 2 if $channels == 2;
		push @plan, \%track;
	}
	return (undef, \@plan);
}

# The take's master rack: a JSON array of the master effects the page switched
# on. The engine builds them in the contract's order. A name outside the five,
# a duplicate or a non-array is refused here; the engine refuses the same
# shapes, but this keeps the sentence a 400 rather than a socket line.
sub studio_master_plan {
	my ($master_json) = @_;
	return (undef, []) unless defined $master_json && length $master_json;
	my $decoded = eval { decode_json($master_json) };
	return ('master_json must be a JSON array of master insert names', undef)
		unless ref $decoded eq 'ARRAY';
	my (@names, %seen);
	for my $name (@$decoded) {
		return ('master_json must hold master insert names', undef)
			unless defined $name && !ref $name;
		return ("no such master insert: $name", undef)
			unless $studio_take_master_inserts{$name};
		return ("duplicate master insert: $name", undef) if $seen{$name}++;
		push @names, $name;
	}
	return (undef, \@names);
}

# Validate the request's optional plan fields and answer with the engine's
# per-track array, or with the sentence that refuses them. A `tracks_json`
# plan wins; otherwise the older scalar fields are used unchanged, so a page
# that has not learned the per-track shape still works. Nothing here names a
# path.
sub studio_take_plan {
	my ($tracks, $inputs, $inserts, $tracks_json) = @_;

	return &studio_take_json_plan($tracks_json)
		if defined $tracks_json && length $tracks_json;

	my $count;
	if (defined $tracks && length $tracks) {
		return ('tracks must be a whole number between 1 and 32', undef)
			unless $tracks =~ /\A\s*\+?(\d+)\s*\z/;
		$count = $1 + 0;
		return ('tracks must be a whole number between 1 and 32', undef)
			unless $count >= 1 && $count <= $studio_take_tracks_max;
	}

	my @inputs;
	if (defined $inputs && length $inputs) {
		for my $part (split /,/, $inputs, -1) {
			$part =~ s/\A\s+|\s+\z//g;
			return ('inputs must be channel numbers separated by commas', undef)
				unless $part =~ /\A\+?\d+\z/;
			return ('inputs must be whole channel numbers between 0 and 31', undef)
				unless $part <= $studio_take_input_max;
			push @inputs, $part + 0;
		}
		return ('inputs must name at least one channel', undef) unless @inputs;
		return ('tracks must be a whole number between 1 and 32', undef)
			if @inputs > $studio_take_tracks_max;
	}

	my @inserts;
	if (defined $inserts && length $inserts) {
		for my $part (split /,/, $inserts) {
			$part =~ s/\A\s+|\s+\z//g;
			next unless length $part;
			return ("no such insert: $part", undef) unless $studio_take_inserts{$part};
			push @inserts, $part;
		}
	}

	# Nothing to plan: the engine's own one-track wire is the take.
	return (undef, undef) unless defined $count || @inputs || @inserts;

	$count = @inputs if !defined $count && @inputs;
	$count = 1 unless defined $count;
	if (@inputs && @inputs != $count) {
		return ('inputs must name one channel per track', undef);
	}
	@inputs = (0 .. $count - 1) unless @inputs;

	my @plan = map { { input => $inputs[$_], inserts => [@inserts] } } 0 .. $count - 1;
	return (undef, \@plan);
}

# The live-monitor switch and its trim are validated before anything is
# created. Absent or a word of refusal is off, a word of assent is on, and
# anything else is refused rather than guessed. The gain is a finite decimal
# clamped to the engine's range and defaulting to unity.
our $studio_monitor_gain_default = 1.0;

sub studio_monitor_start {
	my ($monitor_input, $monitor_gain) = @_;

	my $on = 0;
	if (defined $monitor_input) {
		(my $word = lc $monitor_input) =~ s/\A\s+|\s+\z//g;
		$on = 1 if $word eq 'true' || $word eq '1' || $word eq 'yes';
		return ('monitor_input must be on or off', undef, undef)
			unless $on || $word eq '' || $word eq 'false' || $word eq 'no';
	}

	my $gain = $studio_monitor_gain_default;
	if (defined $monitor_gain && length $monitor_gain) {
		$gain = &studio_listen_number($monitor_gain);
		return ('monitor_gain must be a finite number', undef, undef)
			unless defined $gain;
	}
	$gain = &studio_listen_clamp($gain, 0, $studio_listen_gain_max);

	return (undef, $on, $gain);
}

# Resolve, arm and send one take. The folder is made server-side because the
# disk writer does not create parents; the engine is checked first so a machine
# without one does not leave an empty directory behind.
sub studio_take_start {
	my ($seconds, $start_at, $tracks, $inputs, $inserts, $tracks_json, $master_json,
		$monitor_input, $monitor_gain) = @_;
	$seconds  = &studio_take_seconds($seconds);
	$start_at = &studio_take_start_at($start_at);

	my ($plan_error, $plan) = &studio_take_plan($tracks, $inputs, $inserts, $tracks_json);
	return (400, { ok => 0, error => $plan_error }) if defined $plan_error;
	my ($master_error, $master) = &studio_master_plan($master_json);
	return (400, { ok => 0, error => $master_error }) if defined $master_error;
	my ($monitor_error, $monitor_on, $monitor_level) =
		&studio_monitor_start($monitor_input, $monitor_gain);
	return (400, { ok => 0, error => $monitor_error }) if defined $monitor_error;

	my $folder = &studio_take_folder();
	return (503, { ok => 0, error => 'no recording folder is set on this machine' })
		unless length $folder;

	require JawnOS::Audio::Engine;
	return (503, { ok => 0, error => $JawnOS::Audio::Engine::audio_engine_not_running })
		unless &JawnOS::Audio::Engine::audio_engine_available();

	require File::Path;
	my $ready = eval { File::Path::make_path($folder); 1 };
	return (503, { ok => 0, error => 'the recording folder could not be created' })
		unless $ready && -d $folder;

	my $path = &studio_take_path($folder);
	my $extra;
	$extra->{'tracks'} = $plan if $plan;
	$extra->{'master'} = $master if @$master;
	if ($monitor_on) {
		$extra->{'monitor_input'} = 1;
		$extra->{'monitor_gain'} = $monitor_level;
	}
	my $answer = &JawnOS::Audio::Engine::audio_engine_record(
		$path, $seconds, $start_at, $extra,
	);
	$answer = { ok => 0, error => 'the audio engine did not answer' }
		unless ref $answer eq 'HASH';

	# The probe above can race an engine that exits between the two connections.
	# The client says the same sentence when a connect fails, so the route still
	# answers "not running" rather than a 200 carrying a server fault.
	return (503, $answer)
		if !$answer->{'ok'} && ($answer->{'error'} // '') eq $JawnOS::Audio::Engine::audio_engine_not_running;

	$answer->{'path'} = $path if $answer->{'ok'} && !exists $answer->{'path'};
	return (200, $answer);
}

# Run the engine for one validated backend and return [status, payload]. Only
# the backend name reaches argv, and it is checked against the four-name list
# first; nothing else from the request is passed and no shell is involved.
sub studio_latency_engine {
	my ($backend) = @_;
	$backend = '' unless defined $backend;
	return (400, { ok => 0, error => 'choose a backend: alsa, pipewire or jack' })
		unless $studio_latency_backend{$backend};
	return (400, { ok => 0, error => 'javascript is measured in the browser' })
		if $backend eq 'javascript';

	my $engine = $ENV{JAWNOS_AUDIO_ENGINE} || 'perl/audio/jawn-audio';
	return (503, { ok => 0, error => 'the audio engine is not built on this machine' })
		unless -f $engine && -x $engine;

	my @argv = ($engine, '--loopback', '--backend', $backend, '--json');
	my ($in, $out, $pid);
	open(my $devnull, '>', '/dev/null') or
		return (502, { ok => 0, error => 'the audio engine did not start' });
	$pid = eval { open3($in, $out, $devnull, @argv) };
	close $devnull;
	return (502, { ok => 0, error => 'the audio engine did not start' }) unless $pid;
	close $in if defined $in;

	my $json = '';
	my $timed_out = 0;
	my $read = eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		alarm 10;
		local $/;
		$json = <$out>;
		alarm 0;
		1;
	};
	alarm 0;
	unless ($read) {
		$timed_out = 1 if $@ && $@ =~ /^timeout/;
		kill 'KILL', $pid;
		waitpid($pid, 0);
		close $out;
		return (504, { ok => 0, error => 'the audio engine took too long' }) if $timed_out;
		return (502, { ok => 0, error => 'the audio engine did not answer' });
	}
	close $out;
	waitpid($pid, 0);

	# One JSON object is the whole contract; anything else is a failure, never
	# a number the page could display as a measurement.
	my $data = eval { decode_json($json // '') };
	return (502, { ok => 0, error => 'the audio engine did not return a measurement' })
		unless ref $data eq 'HASH';

	return (200, $data);
}

# GET /manager/games/peer_library
# The catalogue a peer reads: this machine's own shelf, with the covers inline so
# a card on the asking machine is never blank. The peer signature is the proof;
# a browser cookie never satisfies it, and a machine that is not in the house
# gets nothing.
sub action_44026 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted')) {
		$c->rendered(403);
		return;
	}
	$c->render(json => eval { &subs::game_peer_catalogue() } || { ok => 0, games => [] });
}

# GET /manager/games/serve
# One game, packed, for a peer that asked for it. The id is the only thing the
# request carries; the members come from this machine's scan. The pack is a file
# beside the response and is removed when the response finishes, so a pull does
# not leave a tar behind on the board.
sub action_44027 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted')) {
		$c->rendered(403);
		return;
	}
	my $tmp = ($gb::tmp_dir || '/tmp') . '/game-serve-' . $$ . '-' . &subs::random_string_creator(8) . '.tgz';
	my $packed = eval { &subs::game_serve_tar($c->param('id') // '', $tmp) } || {};
	unless ($packed->{'ok'}) {
		unlink $tmp;
		$c->render(json => { ok => 0, error => ($packed->{'error'} // 'the game could not be packed') });
		return;
	}
	my $size = -s $tmp || 0;
	$c->on(finish => sub { unlink $tmp });
	$c->res->headers->content_type('application/x-gtar');
	$c->res->headers->content_length($size);
	$c->res->content->asset(Mojo::Asset::File->new(path => $tmp));
	$c->rendered(200);
}

# GET /manager/games/house
# The catalogue every reachable machine offers, server first, for the Games page.
# The peers are asked in parallel and each one has a short leash: a board whose
# Wi-Fi is down must still start a local game, and a page load that waits on a
# sleeping peer would hold a request worker while the launch waits behind it.
# The section fills in when the answers arrive, and a peer that never answers is
# simply absent.
sub action_44028 {
	my $c = shift;
	my $requests = eval { &subs::game_house_requests() } || [];
	my (@promises, @uas, %answer);
	for my $index (0 .. $#{ $requests }) {
		my $request = $requests->[$index];
		my $ua = $request->{'ua'};
		next unless $ua;
		push @uas, $ua;
		my $promise = eval { $ua->get_p($request->{'url'}) };
		next unless $promise;
		push @promises, $promise->then(sub {
			my ($tx) = @_;
			my $res = $tx->result;
			return unless $res && $res->is_success;
			my $parsed = eval { decode_json($res->body) };
			return unless ref $parsed eq 'HASH' && ref $parsed->{'games'} eq 'ARRAY';
			$answer{$index} = {
				row => $request->{'row'},
				hostname => $parsed->{'hostname'},
				games => $parsed->{'games'},
			};
		})->catch(sub { undef });
	}
	unless (@promises) {
		$c->render(json => { ok => 1, hosts => [], games => [] });
		return;
	}
	my $collect = sub {
		my @ordered = map { $answer{$_} } grep { defined $answer{$_} } 0 .. $#{ $requests };
		return &subs::game_house_merge(\@ordered);
	};
	Mojo::Promise->all(@promises)->then(sub {
		$c->render(json => $collect->());
	})->catch(sub {
		$c->render(json => $collect->());
	});
	$c->render_later;
	&subs::request_busy_release($c);
}

# POST /manager/games/pull
# Copy one game from one machine into this machine's own shelf. The peer answers
# the pack; nothing is asked of the record sync.
sub action_44029 {
	my $c = shift;
	my $said = eval { &subs::game_pull($c->param('signatorial') // '', $c->param('id') // '') }
		|| { ok => 0, error => &subs::ui('That did not work.') };
	$c->render(json => $said);
}

# POST /manager/studio/export
#
# Studio renders each track in the browser through its own output chain and
# sends the WAV here. This route names the file after the track, transcodes it
# with ffmpeg, and files it on the song's appointment the way a capture is
# filed: one record in the appointment's `file` JSON, typed `audio`. The song
# must already exist; an export joins a record, it never makes one.
#
# Nothing from the request becomes a path, an option or a shell word. The name
# is one filesystem component through subs::path_name(), the format is one of
# three words, and the bit rate is a clamped integer. The encoder command is a
# list for system(), never a shell string.
sub action_44032 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $name = $c->param('name');
	my $format = &studio_export_format($c->param('format'));
	my $bitrate = &studio_export_bitrate($c->param('bitrate'));
	# The mastering rack is the browser's: its state is already printed into the
	# upload. Reading the flag keeps the request's shape complete.
	my $master = $c->param('master');
	my $upload = $c->req->upload('audio');

	unless (defined $uuid && length $uuid) {
		$c->render(json => { ok => 0, error => 'save the song before exporting its tracks' }, status => 400);
		return;
	}
	unless (defined $format) {
		$c->render(json => { ok => 0, error => 'choose wav, mp3 or flac' }, status => 400);
		return;
	}
	unless ($upload) {
		$c->render(json => { ok => 0, error => 'no audio was sent' }, status => 400);
		return;
	}

	my $song = &subs::db_select('appointments', undef, { uuid => $uuid, type => 'studio' })->hashes->[0];
	unless ($song) {
		$c->render(json => { ok => 0, error => 'that song is not saved' }, status => 404);
		return;
	}

	my $encoder = &studio_export_ffmpeg();
	unless (length $encoder) {
		$c->render(json => { ok => 0, error => 'the audio encoder is not installed' }, status => 503);
		return;
	}

	my $location = eval {
		&subs::home(&subs::setting_grabber({
			app => 'misc', setting => 'rec_location', device => $device,
		}));
	};
	unless (defined $location && !ref $location && length $location) {
		$c->render(json => { ok => 0, error => 'no recording folder is set on this machine' }, status => 503);
		return;
	}
	my $folder = File::Spec->catdir($location, 'studio');
	require File::Path;
	my $ready = eval { File::Path::make_path($folder); 1 };
	unless ($ready && -d $folder) {
		$c->render(json => { ok => 0, error => 'the studio folder could not be created' }, status => 503);
		return;
	}

	my $track = (defined $name && length $name) ? $name : 'Track';
	my $path = &studio_export_path($folder, $track, $format);
	# path_name() already turns a separator into a percent escape. Keeping the
	# assertion makes the containment explicit, so a future change to the
	# encoder path cannot quietly write outside the studio folder.
	unless (index($path, $folder . '/') == 0) {
		$c->render(json => { ok => 0, error => 'that name cannot be a file' }, status => 400);
		return;
	}

	# The browser sends WAV; ffmpeg normalises it and writes the chosen format.
	# The temp file lives beside the destination so the move is on one volume.
	require File::Temp;
	my ($temp_fh, $temp) = File::Temp::tempfile(
		'studio-export-XXXXXX', DIR => $folder, SUFFIX => '.wav', UNLINK => 0,
	);
	unless ($temp_fh) {
		$c->render(json => { ok => 0, error => 'the upload could not be saved' }, status => 503);
		return;
	}
	close $temp_fh;
	unlink $temp;
	eval { $upload->move_to($temp) };
	unless (-e $temp && (-s $temp) > 0) {
		unlink $temp;
		$c->render(json => { ok => 0, error => 'the upload could not be saved' }, status => 400);
		return;
	}

	my @command = &studio_export_command($temp, $path, $format, $bitrate);
	# Run the binary the availability check found, not a fresh PATH lookup.
	$command[0] = $encoder if @command;
	my $ran = @command ? system(@command) : -1;
	unlink $temp;
	unless ($ran == 0 && -e $path && (-s $path) > 0) {
		unlink $path if -e $path && !-s $path;
		$c->render(json => { ok => 0, error => 'the audio encoder could not make that file' }, status => 500);
		return;
	}

	my $files = (defined $song->{'file'} && length $song->{'file'})
		? (eval { decode_json $song->{'file'} } || [])
		: [];
	$files = [] unless ref $files eq 'ARRAY';
	&studio_export_append($files, $path, &subs::random_string_creator(16));
	# The exported track is an appointment file like a capture, so it takes the
	# same sealing path: the fresh server_time puts the row inside the window
	# file_encrypter scans, and the call then seals what this route wrote. The
	# response keeps the plain destination because it only reports the file.
	&subs::db_update(
		'appointments',
		{ file => encode_json($files), server_time => &subs::rightNow() },
		{ uuid => $uuid, type => 'studio' },
	);
	&subs::file_encrypter({ app => 'studio' });

	$c->render(json => { ok => 1, file => $path, name => $track, format => $format });
}

# The three formats the exporter writes. A word outside the map is not a
# format, and the route refuses it rather than guessing.
our %studio_export_formats = map { $_ => 1 } qw(wav mp3 flac);
our $studio_export_bitrate_default = 192;

sub studio_export_format {
	my ($value) = @_;
	return undef unless defined $value && !ref $value;
	(my $word = lc $value) =~ s/\A\s+|\s+\z//g;
	return undef unless $studio_export_formats{$word};
	return $word;
}

# A bit rate the encoder can take: a malformed value falls back to the default,
# and a number is clamped to 64..320 kbps.
sub studio_export_bitrate {
	my ($value) = @_;
	$value = $studio_export_bitrate_default
		unless defined $value && !ref $value
			&& $value =~ /\A\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)\s*\z/;
	$value += 0;
	return 64 if $value < 64;
	return 320 if $value > 320;
	return int($value + 0.5);
}

# The encoder command as a list for system(): the two paths are separate argv
# entries, so a space or a quote in one can neither split the command nor reach
# a shell. WAV is plain PCM and ignores the bit rate; MP3 and FLAC take it.
sub studio_export_command {
	my ($in, $out, $format, $kbps) = @_;
	return () unless defined $in && defined $out;
	$format = 'wav' unless defined $format && $studio_export_formats{$format};
	$kbps = $studio_export_bitrate_default unless defined $kbps && $kbps =~ /\A\d+\z/;
	my @command = ('ffmpeg', '-nostdin', '-loglevel', 'error', '-y', '-i', $in);
	if ($format eq 'mp3') {
		push @command, '-vn', '-codec:a', 'libmp3lame', '-b:a', $kbps . 'k', '-f', 'mp3', $out;
	}
	elsif ($format eq 'flac') {
		push @command, '-vn', '-codec:a', 'flac', '-b:a', $kbps . 'k', '-f', 'flac', $out;
	}
	else {
		push @command, '-vn', '-codec:a', 'pcm_s16le', '-f', 'wav', $out;
	}
	return @command;
}

# Is there an encoder to run? system() with a list still raises ENOENT through
# a warning and a non-zero status when nothing matches, but the route can say
# "ffmpeg is not installed" before it writes a temp file. JAWNOS_FFMPEG lets a
# staged build be named; otherwise PATH is searched.
sub studio_export_ffmpeg {
	my $staged = $ENV{'JAWNOS_FFMPEG'};
	return $staged if defined $staged && length $staged && -x $staged;
	foreach my $dir (split /:/, ($ENV{'PATH'} // '')) {
		next unless length $dir;
		my $path = File::Spec->catfile($dir, 'ffmpeg');
		return $path if -x $path;
	}
	return '';
}

# <studio folder>/<track>.<format>, with a numeric suffix when that name is
# already on disk so a second export never overwrites the first. `name` is a
# track title, so it becomes one component through subs::path_name().
sub studio_export_path {
	my ($folder, $name, $format) = @_;
	$format = 'wav' unless defined $format && $studio_export_formats{$format};
	my $base = &subs::path_name((defined $name && length $name) ? $name : 'Track');
	$base = 'Track' unless defined $base && length $base;
	my $path = File::Spec->catfile($folder, $base . '.' . $format);
	my $n = 1;
	while (-e $path) {
		$n++;
		$path = File::Spec->catfile($folder, $base . '-' . $n . '.' . $format);
	}
	return $path;
}

# The house's appointment file: one record in the song's `file` JSON, named by
# the path the encoder wrote and typed `audio`, the way a capture is typed
# `recording`. Kept separate so its shape is asserted without a database.
sub studio_export_append {
	my ($files, $path, $uuid) = @_;
	$files = [] unless ref $files eq 'ARRAY';
	push @{$files}, { f => $path, uuid => $uuid, type => 'audio' };
	return $files;
}

1;
