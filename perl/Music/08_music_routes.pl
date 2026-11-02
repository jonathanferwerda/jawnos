package Manager;
use strict;
use warnings;
no warnings 'uninitialized';
use feature 'signatures';

use Mojo::JSON qw(decode_json encode_json);

our ($music_device, $music_config, $music_permissive);

Manager::app->routes->post('/music/search' => sub ($c) {
	my $title = 'music';
	my $search = lc $c->param('search');
	my $unlock = $c->param('unlock');
	my $window_maker = $c->param('window_maker');
	# the window's own unlock token, not the secret in settings: a fresh open
	# has none and lists no sealed track; the refresh after a phone signs does
	my $unlocked = &Manager::media_unlock_open($c, 'music') ? 1 : 0;
	my $content_cache = &subs::jawn_version() . ($unlocked ? '-unlocked' : '-locked');
	# the lit folder buttons from the window, by location name, so the machine
	# that walks the folders looks in the ones the panel shows as on. No param
	# at all means the stored toggles still decide; an empty list means nothing
	# is lit and nothing is walked.
	my $folders = $c->param('folders');
	$folders = defined $folders ? (eval { return decode_json $folders } || []) : undef;
	my $new_settings = eval { return decode_json $c->param('new_settings') } || {};
	my $resizes = $c->param('resizes');
	my $misses = eval { return decode_json $c->param('misses') } || {};
	if (!$misses->{'video'}) {
		$misses->{'video'} = &subs::random_string_creator(25,"Aa");
	}
	foreach my $ns ( keys %{$new_settings} ) {
		&subs::setting_setter({ app => 'music', setting => $ns, value => $new_settings->{$ns} });
	}


	my $port = $c->req->url->base->port;
	my $list = eval { return decode_json $c->param('list') } || [];
	my $now_playing = eval { return decode_json $c->param('now_playing') } || {};
	my $same_order = $c->param('same_order');
	&subs::cache_delete({ app => 'music', context => 'content' });
	my $artist = $c->param('artist');
	my $album = $c->param('album');
	my $misc_settings = &Manager::misc_setting_list();
	$music_permissive = $unlocked;

	
	&subs::setting_setter({ app => 'music', setting => 'resizes', value => $resizes });
	&subs::setting_setter({ app => 'music', setting => 'album', value => $album });
	&subs::setting_setter({ app => 'music', setting => 'artist', value => $artist });
	&subs::setting_setter({ app => 'music', setting => 'search', value => $search });
	# the library choice rides in with the search: written as its own request it
	# raced the search, and whenever the search won it relayed to the old
	# machine again, which looked like being stuck on a remote library. It is a
	# local-machine choice, so it is not forwarded as new_settings.
	if (my $library = $c->param('library')) {
		&subs::setting_setter({ app => 'music', setting => 'library', value => $library });
	}
	my $settings = &subs::settings_grabber({ app => 'music' });

	if ($settings->{'library'} ne 'local' && $c->param('remoted') ne 'yes') {
		$c->param('resizes' => undef);
		my $rm = &subs::db_query('select * from remote_machines where uuid=? and connection=?', $settings->{'library'}, 'active')->hashes->[0];
		if ($rm->{'uuid'}) {
			$c->param('remote_uuid' => $rm->{'uuid'});
			$c->param('library_name' => &music_remote_label($rm));
			$c->param('subprocess' => 'yes');
			my $result = &Manager::remote_relay_request($c);
			if ($result =~ /music/gi) {
				# the relay hands the remote's reply back as a plain string; the
				# browser's search handler expects JSON, so put the content type
				# back or the response arrives as text and the list never reloads
				my $reply = eval { return decode_json $result };
				if ($reply && ref $reply eq 'HASH') {
					$c->render(json => $reply);
				}
				else {
					$c->render(text => $result);
				}
				return;
			}
		}
		else { &subs::setting_setter({ app => 'music', setting => 'library', value => 'local' }); $settings->{'library'} = 'local'; }
	}

	$settings->{'artist'} = eval { return decode_json $settings->{'artist'} } || [];
	$settings->{'album'} = eval { return decode_json $settings->{'album'} } || [];
	my $crate;
	if (scalar @{$list} > 0) {
		$crate = &song_maker({ c => $c, config => $music_config, port => $port, files => $list, settings => $settings, now_playing => $now_playing, same_order => $same_order, misc_settings => $misc_settings });
	}
	else {
		$crate = &music_search({ c => $c, search => $search, now_playing => $now_playing, settings => $settings, port => $port, misc_settings => $misc_settings, folders => $folders, permissive => $unlocked });
	}
	$crate->{'unlock'} = $unlocked ? $unlock : '';
	$crate->{'unlocked'} = $unlocked;
	# a search, a folder pick and a layout change all land here, and each of them
	# leaves a queue on the screen that a reopen should come back to
	my $queue_key = &music_queue_remember($crate, $settings, $unlocked);
	
	my @interface_color= qw/yellow green blue orange black fuschia pink navy purple brown/;
	my $random_number = rand(0..8);
	my $timestamp = &subs::rightNow();
	my $jmao = &subs::setting_grabber({ app => 'music', setting => 'mao' });
	$artist = eval { return decode_json $artist } || [];
	$album = eval { return decode_json $album } || [];
	$resizes = eval { return decode_json $resizes } || {};
	my $contents;
	if ($c->param('window_maker')) {
		$contents = $c->render_to_string(
			crate => $crate,
			interface_colour => $interface_color[$random_number],
			template => 'apps/music/music',
			window_maker => 'yes',
			folders => $misc_settings,
			device => &subs::device_setter(),
			mao => eval { return decode_json $jmao } || {},
			jmao => $jmao,
			search => $search,
			resizes => $resizes,
			misses => $misses
		);
		my $website = &Manager::window_maker({ app => 'music', title => $title, contents => $contents }, $timestamp);
		$c->render(json => { artist => $artist, album => $album, search => $search, html => $website });
	}
	else {
		$contents = $c->render_to_string(
			template => 'apps/music/files',
			crate => $crate,
			search => $search,
			# the phone's own list (see apps/music/music.html.ep): this bare
			# fragment draws whatever the window would have
			phone => (($music_device // '') eq 'mobile') ? 1 : 0,
		);
		$c->render(text => $contents);
	}
	&subs::cache_set({ app => 'music', context => 'content', subcontext => ($content_cache . ($queue_key ? '-q' . $queue_key : '')) }, { contents => $contents });
});

Manager::app->routes->post('/music/folder_toggle' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $location = $c->param('location');
	my $status = $c->param('status');
	&subs::setting_setter({ app => 'music_folder_toggle', setting => $location, value => $status, timestamp => $timestamp });
	# the toggle flips the local button and also steers the scanning of the
	# machine whose library is loaded, so a remote library gets the same click
	my $settings = &subs::settings_grabber({ app => 'music' });
	if ($settings->{'library'} ne 'local' && $c->param('remoted') ne 'yes') {
		my $rm = &subs::db_query('select * from remote_machines where uuid=? and connection=?', $settings->{'library'}, 'active')->hashes->[0];
		if ($rm->{'uuid'}) {
			$c->param('remote_uuid' => $rm->{'uuid'});
			$c->param('subprocess' => 'yes');
			my $result = &Manager::remote_relay_request($c);
			if ($result && $result =~ /^\s*(on|off)\s*$/) {
				$c->render(text => $result);
				return;
			}
		}
	}
	my $setting = &subs::setting_grabber({ app => 'music_folder_toggle', setting => $location, device => $music_device });
	$c->render(text => $setting);
});

# Whether a listing also carries what the archives hold. Like the folder
# toggles, it steers the machine whose library is loaded, so a remote library
# gets the same choice.
Manager::app->routes->post('/music/archive_toggle' => sub($c) {
	my $status = $c->param('status');
	&subs::setting_setter({ app => 'music', setting => 'archive', value => $status, timestamp => $c->param('timestamp') });
	my $settings = &subs::settings_grabber({ app => 'music' });
	if ($settings->{'library'} ne 'local' && $c->param('remoted') ne 'yes') {
		my $rm = &subs::db_query('select * from remote_machines where uuid=? and connection=?', $settings->{'library'}, 'active')->hashes->[0];
		if ($rm->{'uuid'}) {
			$c->param('remote_uuid' => $rm->{'uuid'});
			$c->param('subprocess' => 'yes');
			my $result = &Manager::remote_relay_request($c);
			if ($result && $result =~ /^\s*(on|off)\s*$/) {
				$c->render(text => $result);
				return;
			}
		}
	}
	$c->render(text => &subs::setting_grabber({ app => 'music', setting => 'archive' }));
});

Manager::app->routes->post('/music/audio_output_select' => sub ($c) {
	my $output = $c->param('output');
	my $state = $c->param('state') // 'off';
	$state = 'off' unless $state =~ /^(?:off|on|stereo|left|right)$/;
	my $mao = eval { return decode_json &subs::setting_grabber({ app => 'music', setting => 'mao' }) } || {};
	$mao->{$output} = $state;
	my $jmao = encode_json $mao;
	&subs::setting_setter({ app => 'music', setting => 'mao', value => $jmao });
	$c->render(json => $mao);
});

# The Audio drawer belongs to this machine even when the library is remote: it
# is rendered from this machine's settings and output list, so a remote render of
# the Music window (which would carry the remote's mao) never supplies it.
Manager::app->routes->get('/music/video/outputs' => sub ($c) {
	unless ($c->session('authentication') eq 'approved') { $c->rendered(403); return; }
	my $video = eval { return decode_json(&subs::setting_grabber({ app => 'music', setting => 'video' }) // '') } || {};
	$c->render(json => { machines => &music_video_machines(), settings => $video, me => &music_video_local_enabled() });
});

Manager::app->routes->get('/music/audio' => sub ($c) {
	my $settings = &subs::settings_grabber({ app => 'music' });
	my $jmao = $settings->{'mao'};
	my $mao = eval { return decode_json $jmao } || {};
	my $eq = eval { return decode_json($settings->{'equalizer'} // '') } || {};
	my $video = eval { return decode_json($settings->{'video'} // '') } || {};
	my $mvo = eval { return decode_json($settings->{'mvo'} // '') } || {};
	my $html = $c->render_to_string(
		template => 'apps/music/audio',
		folders => &Manager::misc_setting_list(),
		device => &subs::device_setter(),
		mao => $mao,
		jmao => $jmao,
		settings => $settings,
		video_machines => &music_video_machines(),
		mvo => $mvo,
		crate => { settings => $settings }
	);
	$c->render(json => { html => $html, equalizer => $eq, video => $video, mvo => $mvo, mao => $mao, video_machines => &music_video_machines(), video_me => &music_video_local_enabled() });
});

Manager::app->routes->get('/music/configuration' => sub ($c) {
	my $returner = {};
	my $settings = &subs::settings_grabber({ app => 'music' });
	my $jmao = $settings->{'mao'};
	# the panel belongs to this machine even when the library does not: it is
	# rendered from the local settings, and the loaded remote is shown by name
	# rather than as a bare uuid
	my $remote_uuid = $c->param('remote_uuid');
	my $remote_hostname;
	if ($remote_uuid) {
		my $rm = &subs::db_query('select * from remote_machines where uuid=?', $remote_uuid)->hashes->[0];
		$remote_hostname = $rm->{'hostname'} if $rm;
	}
	$returner->{'html'} = $c->render_to_string(
		template => 'apps/music/configuration',
		folders => &Manager::misc_setting_list(),
		device => &subs::device_setter(),
		mao => eval { return decode_json $jmao } || {},
		jmao => $jmao,
		settings => $settings,
		crate => { remote_uuid => $remote_uuid, remote_hostname => $remote_hostname, settings => $settings }
	);
	$c->render(json => $returner);
});

1;
