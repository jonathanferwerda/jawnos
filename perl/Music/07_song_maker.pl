package Manager;
use strict;
use warnings;
no warnings 'uninitialized';
use feature 'signatures';

use List::Util qw(shuffle);
use File::Find;

our ($music_thumb_files);

sub song_maker($data) {
	my $files = $data->{'files'};
	my $settings = $data->{'settings'};
	my $now_playing = $data->{'now_playing'};
	my $c = $data->{'c'};
	my $misc_settings = $data->{'misc_settings'};
	my $port = $data->{'port'};
	my $config = $data->{'config'};
	my $archive = $data->{'archive'} || {};
	my @local_files;
	my $background_colour = &subs::config_reader()->{'manager'}->{'background_colour'} || &subs::setting_grabber({ app => 'misc', setting => 'manager_background_colour'});
	# the track cards wear the manager's colour; on a dark desk they wear its
	# dark counterpart, so a light manager colour does not glare through the music
	my $dark_background_colour = &subs::dark_colour_for($background_colour);
	my $computer_name = &subs::config_reader()->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'computer_name' });
	my $file_informations = {};
	my ($cache_artists,$cache_albums);
	if ($data->{'settings'}->{'all_albums'} eq 'yes') {
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
	# covers live in the album folder, so tracks that share one are listed once
	my %thumb_cache;

	# An archived track is not in the local walk's count, and its path lives on
	# another machine ('/mnt/...' sorts after this disk's '/home/...'), so
	# slicing the combined list outright dropped every archive row: a library
	# with more than max_files local tracks never showed what the archive held.
	# Spend the budget on local files and keep every archive row.
	if (%{$archive}) {
		my $local_budget = $max_files - scalar(keys %{$archive});
		$local_budget = 0 if $local_budget < 0;
		my (@kept, $locals);
		$locals = 0;
		foreach my $path ( @local_files ) {
			if ($archive->{$path}) { push @kept, $path; next; }
			next if $locals >= $local_budget;
			push @kept, $path;
			$locals++;
		}
		@local_files = @kept;
	}
	else {
		splice @local_files, $max_files;
	}
	if ($now_playing->{'file'}) {
		my @is = grep { $_ eq $now_playing->{'file'} } @local_files;
		unshift @local_files, $now_playing->{'file'} unless grep { $_ eq $now_playing->{'file'} } @local_files;
	}

	# A tag repeated through one folder is part of the release, not the track
	# (GalaxyTV, SAiNTS, 2CH). Work it out per folder, so one show's group tag
	# is never applied to a track from another show.
	my %noise_by_folder;
	my %files_by_folder;
	foreach my $path ( @local_files ) {
		my ($dir) = $path =~ m{^(.*)/[^/]*$};
		$dir = '' unless defined $dir;
		push @{$files_by_folder{$dir}}, $path;
	}
	foreach my $dir ( keys %files_by_folder ) {
		$noise_by_folder{$dir} = &music_common_noise($files_by_folder{$dir});
	}

	for (my $n = 0; $n <= $max_files; $n++) {
		my $f = $local_files[$n];
		# an archived track is not on this disk: the manifest already said what it
		# is, and its machine is where the player fetches the bytes from
		my $archive_row = $archive->{$f};
		unless ($archive_row || -e $f) {
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
		if ($archive_row) {
			$type = ($archive_row->{'type'} eq 'video') ? 'video' : 'audio';
		}
		elsif ($extension) {
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
		if ($type eq 'audio' && !$archive_row) {
			unless (exists $thumb_cache{$album_folder}) {
				$music_thumb_files = [];
				find(\&process_thumbfile,$album_folder);
				$thumb_cache{$album_folder} = [ @{$music_thumb_files} ];
			}
			@thumbs = @{ $thumb_cache{$album_folder} };
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
			artist_name => $t[-3],
			artist_folder => $artist_folder,
			album => $t[-2],
			album_name => $t[-2],
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
			colour => $background_colour,
			dark_colour => $dark_background_colour
		};

		if ($archive_row) {
			# nothing here to probe: the manifest carried the facts, and the tags
			# keep the shape the rest of this loop and the template expect
			$f->{'info'} = $archive_row->{'info'} || {};
			$f->{'info'}->{'tags'} = {} unless ref $f->{'info'}->{'tags'};
			$f->{'remote_uuid'} = $archive_row->{'remote_uuid'};
			$f->{'archive_host'} = $archive_row->{'remote_hostname'};
		}
		elsif ($filename && $filename !~ /\.enc$/gi) {
			if (!$file_informations->{$artist_folder}) {
				$file_informations->{$artist_folder} = &subs::cache_get({ app => 'music', context => 'file_information', subcontext => $artist_folder }) || {};
			}


			my $file_information = $file_informations->{$artist_folder};
			# A cached answer is only reused when it carries the facts a card
			# draws. Entries written by a failed probe ({ chapters => undef }) were
			# truthy and stayed for ever, hiding every thumbnail in the folder.
			if (&subs::music_info_usable($file_information->{$filename})) {
				$f->{'info'} = $file_information->{$filename};
			}
			else {
				# The raw path: file_media_information quotes it for ffprobe itself.
				# Passing terminal_name's backslash-escaped path made the two quoting
				# layers fight (a space became \\ inside ffprobe's own quotes), so
				# every re-probe failed on a name with a space, a bracket or an
				# apostrophe - and any cached answer from before the quoting change
				# was the only one a folder ever got.
				$f = &subs::file_media_information($f, $filename);
				if (&subs::music_info_usable($f->{'info'})) {
					$file_information->{$filename} = $f->{'info'};
				}
				else {
					# do not store a failed probe: the next render tries again
					delete $file_information->{$filename};
					$f->{'info'} = {};
				}
			}
			my $tags = (ref $f->{'info'} eq 'HASH' && ref $f->{'info'}->{'tags'} eq 'HASH') ? $f->{'info'}->{'tags'} : {};
			foreach my $i ( qw/artist album track genre title date composer publisher lyrics lyrics-eng/ ) {
				if ($i =~ /lyrics/ && $tags->{$i}) {
					$f->{'lyrics'} = $tags->{$i};
					$f->{'lyrics'} =~ s/\\\n|\\\r/<br>/gi;
				}
				else {
					$f->{$i} = $tags->{$i} if $tags->{$i};
				}
			}
		}
		# the three words every draw shows, settled once here
		my $labels = &music_media_labels($f, $noise_by_folder{$album_folder} || {});
		$f->{'display_artist'} = $labels->{'artist'};
		$f->{'display_album'} = $labels->{'album'};
		$f->{'display_track'} = $labels->{'track'};
		$f->{'display_code'} = $labels->{'code'};
		$f->{'display_meta'} = $labels->{'meta'};
		$f->{'formatted_name'} = $labels->{'track'} if length $labels->{'track'};
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
		library_name => &music_library_label($settings, $c), 
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

1;
