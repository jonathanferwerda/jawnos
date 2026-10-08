#!/usr/bin/perl




use Mojolicious::Lite -signatures;
use Mojolicious::Static;
use Mojo::Log;
use Mojo::File;
use Mojo::JSON qw(decode_json encode_json);
use Encode qw(encode decode);
use List::Util qw(shuffle);
use Data::Dumper;
use Data::UUID;
use Mojo::Util qw/term_escape html_unescape url_unescape url_escape/;
use File::Find;
use File::Slurp;
plugin 'RenderFile';
use LWP::UserAgent;
use Mojolicious::Sessions;
use URI::Encode qw(uri_encode uri_decode);
use MIME::Base64;
use strict;
use warnings;
no warnings 'uninitialized';
my $com = 'echo $HOME';
my $cwd = `$com`;
chomp $cwd;

require "./subroutines.pl";
my $device = &subs::device_setter();
my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
my $environment = $config->{'environment'};
my @folders = @{$config->{'folders'}};
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
my (@results);
my $files = [];
my $thumb_files = [];
my $permissive = 0;
sub process_file() {
	my $name = $File::Find::name;
	if ($name =~ m/mp3$|m4a$|wav$|flac$|mp4$|mkv$|mov$|webm$|weba$|wmv$/i) {
		$name =~ s/^\.\///g;
		push @{$files}, $name;
	}
	if ($permissive == 1) {
		if ($name =~ m/mp3\.enc$|m4a\.enc$|wav\.enc$|mkv\.enc$|flac\.enc$|mp4\.enc$|mov\.enc$|webm\.enc$|weba\.enc$|wmv\.enc$/i) {
			$name =~ s/^\.\///g;
			push @{$files}, $name;
		}
	}
}

sub process_thumbfile() {
	my $name = $File::Find::name;
	if ($name =~ m/jpg$|png$/i) {
		$name =~ s/^\.\///g;
		push @{$thumb_files}, $name;
	}
}

get '/manager/music' => sub ($c) {
	my $search = $c->param('search') || &subs::setting_grabber({ app => 'music', 'setting' => 'search' });
	my $window_maker = $c->param('window_maker');
	my $unlock = &subs::setting_grabber({ app => 'music', setting => 'combo_unlock' });
	my $port = $c->req->url->base->port;
	my $misses = eval { return decode_json $c->param('misses') } || {};
	if (!$misses->{'video'}) {
		$misses->{'video'} = &subs::random_string_creator(25,"Aa");
	}
	$files = eval { return decode_json $c->param('files') } || undef;
	my $settings = &subs::settings_grabber({ app => 'music' });
	$settings->{'artist'} = eval { return decode_json $settings->{'artist'} } || [];
	$settings->{'album'} = eval { return decode_json $settings->{'album'} } || [];
	if ($settings->{'library'} ne 'local' && $c->param('remoted') ne 'yes') {
		my $rm = &subs::db_query('select * from remote_machines where uuid=? and connection=?', $settings->{'library'}, 'active')->hashes->[0];
		if ($rm->{'uuid'}) {
			$c->param('remote_uuid' => $rm->{'uuid'});
			$c->param('subprocess' => 'yes');
			my $result = &Manager::remote_relay_request($c);
			if ($result =~ /music/gi) {
				$c->render(text => $result);
				return;
			}
		}
		else { &subs::setting_setter({ app => 'music', setting => 'library', value => 'local' }); $settings->{'library'} = 'local'; }
	}
	my $misc_settings = &Manager::misc_setting_list();
	unless ($files) {
		if (my $cache = &subs::cache_get({ app => 'music', context => 'content' })) {
			if ($cache->{'contents'}) {
				if ($c->param('window_maker')) {
					my $website = &Manager::window_maker({ app => 'music', title => 'music', contents => $cache->{'contents'} }, &subs::rightNow());
					$c->render(text => $website);
				}
				else {
					$c->render(text => $cache->{'contents'});
				}
				return;
			}
		}
	}
	if ($unlock) {
		if (secure_compare(&subs::note_decrypter($c->session('suds'), $unlock), &subs::note_decrypter($c->session('suds'), &subs::setting_grabber({ app => 'music', setting => 'combo_unlock' })) ) ) {
			my $padlock_sighting = eval { return decode_json &subs::setting_grabber({app => '__president', setting => 'padlock_contexts' }) } || [];
			if (grep { $_ eq 'music' } @{$padlock_sighting}) {
				$permissive = 1;
			}
		}
	}
	my $crate = &music_search({ settings => $settings, c => $c, search => $search, now_playing => {}, port => $port, misc_settings => $misc_settings, files => $files });
	my $timestamp = &subs::rightNow();
	my $jmao = &subs::setting_grabber({ app => 'music', setting => 'mao' });
	my $player = &subs::cache_get({ app => 'music', context => 'player' });
	my $resizes = eval { return decode_json $settings->{'resizes'} } || {};
	my $contents;
	if ($c->param('window_maker')) {
		$contents = $c->render_to_string(
			crate => $crate,
			interface_colour => &subs::random_colour_grabber(),
			template => 'apps/music/music',
			window_maker => 'yes',
			folders => $misc_settings,
			device => &subs::device_setter(),
			mao => eval { return decode_json $jmao } || {},
			jmao => $jmao,
			search => $search,
			resizes => $resizes,
			misses => $misses,
		);
		my $website = &Manager::window_maker({ app => 'music', title => 'music', contents => $contents }, $timestamp);
		$c->render(text => $website);
	}
	else {
		$contents = $c->render_to_string(
			crate => $crate,
			interface_colour => &subs::random_colour_grabber(),
			template => 'apps/music/music',
			layout => 'music',
			window_maker => 'no',
			folders => $misc_settings,
			device => &subs::device_setter(),
			mao => eval { return decode_json $jmao } || {},
			jmao => $jmao,
			search => $search,
			resizes => $resizes,
			misses => $misses
		);
		$c->render(text => $contents);
	}
	&subs::cache_set({ app => 'music', context => 'content' }, { contents => $contents });
};


get '/play' => sub($c) {
	my $mao = eval { return decode_json &subs::setting_grabber({ app => 'music', setting => 'mao' }) } || {};
	my $track = &subs::terminal_name(uri_decode $c->param('track'));
	my $data;

	&Manager::rock_and_roll($c);

	if ($mao->{'srv'} eq 'on') {
		&subs::subprocessor(sub {

			if ($device eq 'computer') {
				my $t = term_escape $track;
				`vlc $track`;
			}
			elsif ($device eq 'mobile') {
				`play $track`;
			}
		}, { name => 'music play' });
		$c->render(text => 'play');
	}

};

any '/music/receiver' => sub($c) {
	my $file = $c->param('file');
	my $remote_address = $c->tx->remote_address;
	my $domain = $c->param('domain');
	my $remote_uuid = $c->param('remote_uuid');
	my $toggle = $c->param('toggle');
	my $seek = $c->param('seek');
	my $volume = $c->param('volume');
	my $music_data = &subs::decrypter($c->session('suds'), decode_base64 $c->param('music_data'));
	my $piped = &subs::home('~/.president/pipe');
	my $timestamp = $c->param('timestamp');
	my $latency = $c->param('latency');
	my $queuing = $c->param('queuing');
	my $server_time = &subs::rightNow();
	my $pipe = $piped;
	my @file = split /\./, $file;
	my $ext = $file[-1];
	if ($ext eq 'enc') {
		$ext = $file[-2];
	}
	$pipe = $pipe . '.' . $ext;

	my $ws_watcher = &subs::home('~/.president/ws_watcher');
	my $pre_md = eval { return decode_json read_file($ws_watcher) } || {};

	write_file($ws_watcher, $music_data) unless $queuing == 1;
	my $md = eval { return decode_json $music_data } || {};
	if ($toggle eq 'off') {
		`pkill play`;
		`shred -u $piped*`;
		`shred -u $ws_watcher`;
	}
	elsif ($toggle eq 'seek') {
		`pkill play`;
		$seek = $seek + ((&subs::rightNow() - $server_time) / 1000) + $latency;
		threads->create(sub() { 
			`play $pipe trim $seek 60000000000`;
		});
	}
	else {
		my $rm = &subs::db_query('select * from remote_machines where (ip=? or fqdn=?) and connection=?', $remote_address,$domain,'active')->hashes->[0];
		if ($rm->{'uuid'}) {
			if ($md->{'file'} ne $pre_md->{'file'} || $queuing == 1) {
				my $signatorial = &subs::signatorial_designer();
				$rm = &Manager::remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $signatorial, rm => $rm });

				my $url = $rm->{'manager'} . '/file_open?&file=' . uri_encode $file;
				$rm->{'ua'} = $rm->{'ua'}->max_response_size(0);
				my $res = $rm->{'ua'}->get($url);# => { Accept => '*/*' } => 'Content!');
				my $data = $res->res->content->asset->slurp;

				unless (-e $pipe) {
					`touch $pipe`;
				}
				write_file($pipe, $data);
				if ($queuing != 1) {
					`pkill play`;
					$seek = $seek + ((&subs::rightNow() - $server_time) / 1000) + $latency;
					threads->create(sub() {
						`play $pipe trim $seek 60000000000`;
					});
				}
			}
			else {
				`pkill play`;
				$seek = $seek + ((&subs::rightNow() - $server_time) / 1000) + $latency;
				threads->create(sub() {
					`play $pipe trim $seek 60000000000`;
				});
			}
		}
	}
	$c->render(json => { timestamp => $timestamp, 'seek' => $seek, file => $file, toggle => $toggle, volume => $volume, type => 'transmitter' });
};



sub music_folder_grabber() {
	my ($db,$database,$sql) = &subs::database_grabber();
	my @folders = ();
	my $settings = &Manager::misc_setting_list();
	foreach my $s ( keys %{$settings->{$device}} ) {
		if ($s =~ /_location$/gi) {
			my $status = &subs::setting_grabber({ app => 'music_folder_toggle', setting => $s, device => $device });
			push @folders, $settings->{$device}->{$s} if $status eq 'on';
		}
	}
	return @folders;
}

sub music_search($data) {
	my $search = $data->{'search'};
	my $now_playing = $data->{'now_playing'};
	my $settings = $data->{'settings'};
	my $c = $data->{'c'};
	my $misc_settings = $data->{'misc_settings'};
	my $port = $data->{'port'};
	my $misses = $data->{'misses'};
	$files = [];
	unless ($settings->{'uuid'}) {
		$settings = &subs::settings_grabber({ app => 'music' });
		$settings->{'artist'} = eval { return decode_json $settings->{'artist'} } || [];
		$settings->{'album'} = eval { return decode_json $settings->{'album'} } || [];
	}
	my $padlock_sighting = eval { return decode_json &subs::setting_grabber({app => '__president', setting => 'padlock_contexts' }) } || [];
	if (grep { $_ eq 'music' } @{$padlock_sighting}) {
		$permissive = 1 if $settings->{'combo_unlock'};
	}

	my @folders;
	if ($data->{'files'}) {
		$files = $data->{'files'};
	}
	else {
		if (scalar @{$settings->{'album'}} > 0) { 
			push @folders, map { $_->{'path'} } @{$settings->{'album'}};
		}
		elsif (scalar @{$settings->{'artist'}} > 0) {
			push @folders, map { $_->{'path'} } @{$settings->{'artist'}};
		}
		else {
			@folders = &music_folder_grabber();
		}
		foreach my $folder (@folders) {
			$folder = &subs::home($folder);
			if (-d $folder) {
				find(\&process_file,$folder);
			}
		}
	}
	my @local_files = @{$files};
	if ($search && !$data->{'files'}) {	
		@local_files = grep { lc $_ =~ /($search)/gi } @{$files};
	}
	my $crate = &song_maker({ c => $c, port => $port, files => \@local_files, settings => $settings, now_playing => $now_playing });
	$permissive = 0;
	return $crate;
}

sub song_maker($data) {
	my $files = $data->{'files'};
	my $settings = $data->{'settings'};
	my $now_playing = $data->{'now_playing'};
	my $c = $data->{'c'};
	my $misc_settings = $data->{'misc_settings'};
	my $port = $data->{'port'};
	my $config = $data->{'config'};
	my @local_files;
	my $background_colour = &subs::config_reader()->{'manager'}->{'background_colour'} || &subs::setting_grabber({ app => 'misc', setting => 'manager_background_colour'});
	my $computer_name = &subs::config_reader()->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'computer_name' });
	my $file_informations = {};
	my ($cache_artists,$cache_albums);
	if ($data->{'settings'}-{'all_albums'} eq 'yes') {
		$cache_albums = &subs::cache_get({ app => 'music', context => 'albums' }) || {};
	}
	if ($data->{'settings'}->{'all_artists'} eq 'yes') {
		$cache_artists = &subs::cache_get({ app => 'music', context => 'artists' }) || {};
	}

	if ($data->{'same_order'} != 1) {
		if ($settings->{'shuffle'} eq 'on') {
			@local_files = shuffle(@{$files});
		}
		else {
			@local_files = sort @{$files};
		}
	}
	else {
		@local_files = @{$files};
	}
	my @lf;
	my $track_number = 0;
	my $max_files = &subs::setting_grabber({ app => 'misc', setting => 'max_files' }) || 30;
	my $tree = &subs::inventory_grabber();
	my $artists = {};
	my $albums = {};
	my $songs = [];
	my $pushed_now_playing = 0;
	my $current_track;

	splice @local_files, $max_files;
	if ($now_playing->{'file'}) {
		my @is = grep { $_ eq $now_playing->{'file'} } @local_files;
		unshift @local_files, $now_playing->{'file'} unless grep { $_ eq $now_playing->{'file'} } @local_files;
	}

	for (my $n = 0; $n <= $max_files; $n++) {
		my $f = $local_files[$n];
		unless (-e $f) {
			next;
		}
		$track_number = $track_number + 1;
		my @t = split '/', $f;
		my @temp_path = @t;
		my $t = $t[-1];
		my $track_number = 0;
		$t =~ s/(\.mp3$|\.m4a$|\.wav$|\.flac$)//gi;
		my $extension = $1;
		my ($info,$type,@thumbs);
		if ($extension) {
			$type = 'audio';
		}
		else {
			$type = 'video';
		}
		my $filename = $f;
		my $full_title = $t;
		$tree->{lc $t} = $t[-3];
		$tree->{lc $t} .= "\n" . $t[-2] if $t[-2];
		$tree->{lc $t} .="\n" . $tree->{lc $t};
		pop @temp_path;
		my $album_folder = join '/', @temp_path;
		if ($type eq 'audio') {
			$thumb_files = [];
			find(\&process_thumbfile,$album_folder);
			@thumbs = @{$thumb_files};
		}
		my $app;
		if ($filename =~ /\.enc$/gi) {
			$app = $t[-2];
		}
		my $formatted_name = &subs::format_name(join '.', $full_title);

		pop @temp_path;
		my $artist_folder = join '/', @temp_path;

		$f = { 
			filename => $filename,
			type => $type,
			track => $t,
			extension => $extension,
			artist => $t[-3],
			artist_folder => $artist_folder,
			album => $t[-2],
			app => &subs::unformat_name($t[-2]),
			album_folder => $album_folder,
			thumbs => \@thumbs,
			info => $info,
			song => $t[-1],
			full_title => $full_title,
			formatted_name => $formatted_name,
			track_number => $track_number,
			file_uuid => &subs::random_string_creator(21),
			description => $tree->{lc $t},
			computer_name => $computer_name,
			colour => $background_colour
		};

		if ($filename && $filename !~ /\.enc$/gi) {
			if (!$file_informations->{$artist_folder}) {
				$file_informations->{$artist_folder} = &subs::cache_get({ app => 'music', context => 'file_information', subcontext => $artist_folder }) || {};
			}


			my $file_information = $file_informations->{$artist_folder};
			if ($file_information->{$filename}) {
				$f->{'info'} = $file_information->{$filename};
			}
			else {
				$f = &subs::file_media_information($f, &subs::terminal_name($filename));
				$file_information->{$filename} = $f->{'info'};
			}
			foreach my $i ( qw/artist album track genre title date composer publisher lyrics lyrics-eng/ ) {
				if ($i =~ /lyrics/ && $f->{'info'}->{'tags'}->{$i}) {
					$f->{'lyrics'} = $f->{'info'}->{'tags'}->{$i};
					$f->{'lyrics'} =~ s/\\\n|\\\r/<br>/gi;
				}
				else {
					$f->{$i} = $f->{'info'}->{'tags'}->{$i} if $f->{'info'}->{'tags'}->{$i};
				}
			}
		}
		if ($now_playing->{'file'} eq $filename) {
			$current_track = $n;
			$f->{'playing'} = 'yes';
		}
		else {

		}
	#	$artists->{$t[-3]}->{'full_title'} => $t[-3];
		$artists->{$t[-3]}->{'path'} = $artist_folder;
		push @{$artists->{$t[-3]}->{'tracks'}}, $f;
	#	$albums->{$t[-2]}->{'full_title'} => $t[-3];
		$albums->{$t[-2]}->{'path'} = $album_folder;
		push @{$albums->{$t[-3]}->{'tracks'}}, $f;

		push @{$songs}, $f;
		if ($data->{'settings'}->{'all_artists'} eq 'yes') {
			$cache_artists->{lc $f->{'artist'}} = { path => $artist_folder, artist => $f->{'artist'} };
		}
		if ($data->{'settings'}->{'all_albums'} eq 'yes') {
			$cache_albums->{lc $f->{'album'}} = { path => $album_folder, album => $f->{'album'} };
		}
	}
	foreach my $finfo ( keys %{$file_informations} ) {
		&subs::cache_set({ app => 'music', context => 'file_information', subcontext => $finfo, warranty => '-6M' }, $file_informations->{$finfo});
	}
	if ($data->{'settings'}->{'all_artists'} eq 'yes') {
		&subs::cache_set({ app => 'music', context => 'artists' }, $cache_artists);
		$artists = $cache_artists;
	}
	if ($data->{'settings'}->{'all_albums'} eq 'yes') {
		&subs::cache_set({ app => 'music', context => 'albums' }, $cache_albums);
		$albums = $cache_albums;
	}

	my $crate = { 
		config => $config, 
		remote_uuid => $c->param('remote_uuid'), 
		current_track => $current_track, 
		artist => $settings->{'artist'}, 
		album => $settings->{'album'}, 
		artists => $artists, 
		albums => $albums, 
		songs => $songs, 
		settings => $settings,
	};
	return $crate;
}

post '/music/search' => sub ($c) {
	my $title = 'music';
	my $search = lc $c->param('search');
	my $unlock = $c->param('unlock');
	my $window_maker = $c->param('window_maker');
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

	if ($unlock) {
		if (secure_compare(&subs::note_decrypter($c->session('suds'), $unlock), &subs::note_decrypter($c->session('suds'), &subs::setting_grabber({ app => 'gallery', setting => 'combo_unlock' })) ) ) {
			my $padlock_sighting = eval { return decode_json &subs::setting_grabber({app => '__president', setting => 'padlock_contexts' }) } || [];
			if (grep { $_ eq 'music' } @{$padlock_sighting}) {
				$permissive = 1;
			}
		}
	}

	
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
		my $permissive = 0;
		my $padlock_sighting = eval { return decode_json &subs::setting_grabber({app => '__president', setting => 'padlock_contexts' }) } || [];
		if (grep { $_ eq 'music' } @{$padlock_sighting}) {
			$permissive = 1 if $settings->{'combo_unlock'};
		}
		$crate = &song_maker({ c => $c, config => $config, port => $port, files => $list, settings => $settings, now_playing => $now_playing, same_order => $same_order, misc_settings => $misc_settings });
	}
	else {
		$crate = &music_search({ c => $c, search => $search, now_playing => $now_playing, settings => $settings, port => $port, misc_settings => $misc_settings });
	}
	
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
		);
		$c->render(text => $contents);
	}
	&subs::cache_set({ app => 'music', context => 'content' }, { contents => $contents });
};

post '/music/folder_toggle' => sub($c) {
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
	my $setting = &subs::setting_grabber({ app => 'music_folder_toggle', setting => $location, device => $device });
	$c->render(text => $setting);
};

post '/music/audio_output_select' => sub ($c) {
	my $output = $c->param('output');
	my $state = $c->param('state');
	my $mao = eval { return decode_json &subs::setting_grabber({ app => 'music', setting => 'mao' }) } || {};
	$mao->{$output} = $state;
	my $jmao = encode_json $mao;
	&subs::setting_setter({ app => 'music', setting => 'mao', value => $jmao });
	$c->render(json => $mao);
};

get '/music/configuration' => sub($c) {
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
};

1;
