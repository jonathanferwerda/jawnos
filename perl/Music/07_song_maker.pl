package Manager;
use strict;
use warnings;
no warnings 'uninitialized';
use feature 'signatures';

use List::Util qw(shuffle);
use File::Find;

our ($music_thumb_files);

# How many cards one render draws. The window is a view of the queue, not the
# queue itself: song_maker describes every queued file in the manifest but
# probes (ffprobe, folder scans) and draws only this many. The client asks for
# the next window as it scrolls.
our $music_window_limit = 60;

# Local files first, then archived tracks in the slots that remain. An
# archived row whose copy is on this disk has already been left out of
# $files by music_search, so this only decides how many of each to show.
sub music_budget_files($files, $archive, $max_files) {
	my @all = @{ $files || [] };
	$max_files = 30 unless defined $max_files && $max_files =~ /^\d+$/;
	my (@local, @archived);
	foreach my $path ( @all ) {
		if ($archive && ref $archive eq 'HASH' && $archive->{$path}) { push @archived, $path; }
		else { push @local, $path; }
	}
	splice @local, $max_files if scalar @local > $max_files;
	my $remaining = $max_files - scalar @local;
	$remaining = 0 if $remaining < 0;
	splice @archived, $remaining if scalar @archived > $remaining;
	return (@local, @archived);
}

# Which slice of the ordered queue this render draws. The queue is the capped,
# ordered list; offset 0 is its first row. A request asking for a window past
# the end simply gets no rows (the total in the reply tells the client so).
sub music_window_window($data) {
	my $win = (ref $data->{'window'} eq 'HASH') ? $data->{'window'} : {};
	my $offset = $win->{'offset'};
	$offset = 0 unless defined $offset && $offset =~ /^\d+$/;
	my $limit = $win->{'limit'};
	$limit = $music_window_limit unless defined $limit && $limit =~ /^\d+$/ && $limit > 0;
	# a scroll asks for at most a few screens; refuse a request that would turn
	# the window back into the whole list
	$limit = 500 if $limit > 500;
	return ($offset, $limit);
}

sub music_song_key($f) {
	return '' unless ref $f eq 'HASH';
	return $f->{'file_uuid'} || $f->{'filename'} || $f->{'file'} || '';
}

# The picture a card and the theatre draw, as a URL the client can put in src.
# Audio uses the album's cover; a video uses its own poster frame.
sub music_song_thumb($f, $remote_uuid) {
	my $remote = defined $remote_uuid ? $remote_uuid : ($f->{'remote_uuid'} // '');
	my $suffix = length $remote ? '&remote_uuid=' . &subs::url_escape_utf8($remote) : '';
	if (($f->{'type'} // '') eq 'audio') {
		my $thumb = (ref $f->{'thumbs'} eq 'ARRAY' && scalar @{$f->{'thumbs'}}) ? $f->{'thumbs'}->[0] : '';
		return '' unless length $thumb;
		return '/file_open?file=' . &subs::url_escape_utf8($thumb) . $suffix;
	}
	my $info = ref $f->{'info'} eq 'HASH' ? $f->{'info'} : {};
	if (($f->{'type'} // '') eq 'video' && $info->{'duration'} && $info->{'height'}) {
		return '/file_open?file=' . &subs::url_escape_utf8($f->{'filename'})
			. '&thumb=ya&duration=' . &subs::url_escape_utf8($info->{'duration'}) . $suffix;
	}
	return '';
}

# The compact description of one track. The queue is made of these, not of the
# rendered cards: a scroll can replace every card without changing this list,
# and the player's next/previous/restore all read it. Only the fields a card
# and the player need are carried, so 5,000 rows stay small.
sub music_manifest_entry($f, $remote_uuid) {
	my $info = ref $f->{'info'} eq 'HASH' ? $f->{'info'} : {};
	my $entry = {
		key => &music_song_key($f),
		file => $f->{'filename'} || '',
		file_uuid => $f->{'file_uuid'} || '',
		type => $f->{'type'} || '',
		app => $f->{'app'} || '',
		remote_uuid => (defined $f->{'remote_uuid'} && length $f->{'remote_uuid'}) ? $f->{'remote_uuid'} : ($remote_uuid // ''),
		computer_name => $f->{'computer_name'} || '',
		colour => $f->{'colour'} || '',
		dark_colour => $f->{'dark_colour'} || '',
		artist_name => $f->{'artist_name'} || '',
		album_name => $f->{'album_name'} || '',
		artist_folder => $f->{'artist_folder'} || '',
		album_folder => $f->{'album_folder'} || '',
		song => $f->{'song'} || '',
		full_title => $f->{'full_title'} || '',
		formatted_name => $f->{'formatted_name'} || '',
		display_artist => $f->{'display_artist'} || '',
		display_album => $f->{'display_album'} || '',
		display_track => $f->{'display_track'} || '',
		display_code => $f->{'display_code'} || '',
		display_meta => $f->{'display_meta'} || '',
		duration => defined $info->{'duration'} ? $info->{'duration'} : '',
		thumb => &music_song_thumb($f, $remote_uuid),
		chapters => (ref $info->{'chapters'} eq 'ARRAY') ? $info->{'chapters'} : [],
		archive => $f->{'archive'} ? 1 : 0,
		probed => $f->{'probed'} ? 1 : 0,
	};
	# Only a probed or archived row carries its facts. An unprobed row is
	# described from its path; the window that draws it fills the rest in.
	$entry->{'info'} = $info if $f->{'probed'} || $f->{'archive'};
	$entry->{'noise'} = $f->{'noise'} if ref $f->{'noise'} eq 'HASH' && scalar keys %{$f->{'noise'}};
	return $entry;
}

sub music_probe_context {
	return { file_information => {}, thumb_cache => {}, archive => {} };
}

# The one write back to the ffprobe cache: only folders this render actually
# probed are touched, so walking a window never rewrites the whole library.
sub music_flush_information($ctx) {
	foreach my $finfo ( keys %{ $ctx->{'file_information'} || {} } ) {
		&subs::cache_set({ app => 'music', context => 'file_information', subcontext => $finfo, warranty => '-6M' }, $ctx->{'file_information'}->{$finfo});
	}
}

# The cheap half: everything the path and the archive manifest already say.
# No ffprobe, no folder scan. This is what makes a 5,000-track manifest cheap
# enough to build on every render.
sub music_row_new($path, $ctx, $archive_row, $noise) {
	my @t = split '/', $path;
	my $base = $t[-1];
	my $stem = $base;
	# do not let a capture from an earlier match become the extension: in this
	# loop no match used to leave $1 holding the caller's directory capture,
	# which then made every video look like audio
	my $extension = '';
	if ($stem =~ s/(\.mp3$|\.m4a$|\.wav$|\.flac$)//gi) { $extension = $1; }
	my $type;
	if ($archive_row) { $type = ($archive_row->{'type'} eq 'video') ? 'video' : 'audio'; }
	elsif ($extension) { $type = 'audio'; }
	else { $type = 'video'; }

	my $tree = $ctx->{'tree'} || {};
	# The inventory description the search and the shelves have always kept.
	$tree->{lc $stem} = $t[-3];
	$tree->{lc $stem} .= "\n" . $t[-2] if $t[-2];
	$tree->{lc $stem} .= "\n" . $tree->{lc $stem};
	$ctx->{'tree'} = $tree;

	my @ancestors = @t;
	pop @ancestors;
	my $album_folder = join '/', @ancestors;
	pop @ancestors;
	my $artist_folder = join '/', @ancestors;

	my $app = &subs::unformat_name($t[-2]);
	$app = $t[-2] if $base =~ /\.enc$/gi;

	my $f = {
		filename => $path,
		file => $path,
		type => $type,
		track => $stem,
		extension => $extension,
		artist => $t[-3],
		artist_name => $t[-3],
		artist_folder => $artist_folder,
		album => $t[-2],
		album_name => $t[-2],
		app => $app,
		album_folder => $album_folder,
		folder_artist_key => $t[-3],
		folder_album_key => $t[-2],
		thumbs => [],
		info => {},
		song => $t[-1],
		full_title => $stem,
		formatted_name => &subs::format_name(join '.', $stem),
		track_number => 0,
		file_uuid => &subs::random_string_creator(21),
		description => $tree->{lc $stem},
		computer_name => $ctx->{'computer_name'} || '',
		colour => $ctx->{'background_colour'} || '',
		dark_colour => $ctx->{'dark_background_colour'} || '',
		noise => $noise || {},
		archive => $archive_row ? 1 : 0,
		probed => 0,
	};
	if ($archive_row) {
		# nothing here to probe: the manifest carried the facts, and the tags
		# keep the shape the rest of the code and the template expect
		$f->{'info'} = $archive_row->{'info'} || {};
		$f->{'info'}->{'tags'} = {} unless ref $f->{'info'}->{'tags'};
		$f->{'remote_uuid'} = $archive_row->{'remote_uuid'};
		$f->{'archive_host'} = $archive_row->{'remote_hostname'};
	}
	&music_row_labels($f);
	return $f;
}

# Settle the three words a card draws. Called once from the path and again
# after a probe, because a tag may name the track better than the path does.
sub music_row_labels($f) {
	my $labels = &music_media_labels($f, $f->{'noise'} || {});
	$f->{'display_artist'} = $labels->{'artist'};
	$f->{'display_album'} = $labels->{'album'};
	$f->{'display_track'} = $labels->{'track'};
	$f->{'display_code'} = $labels->{'code'};
	$f->{'display_meta'} = $labels->{'meta'};
	$f->{'formatted_name'} = $labels->{'track'} if length $labels->{'track'};
	return $f;
}

# The expensive half: the folder's cover, ffprobe, and the tags. Only the
# window that is drawn (and the track that is playing) pays for this.
sub music_song_probe($ctx, $f) {
	return $f if $f->{'archive'};
	my $filename = $f->{'filename'};
	# a stale manifest can name a file the library no longer holds; do not
	# spend an ffprobe on a ghost
	return $f unless $filename && -e $filename;

	if (($f->{'type'} // '') eq 'audio') {
		my $folder = $f->{'album_folder'} || '';
		unless (exists $ctx->{'thumb_cache'}->{$folder}) {
			$music_thumb_files = [];
			find(\&process_thumbfile, $folder) if length $folder && -d $folder;
			$ctx->{'thumb_cache'}->{$folder} = [ @{ $music_thumb_files || [] } ];
		}
		$f->{'thumbs'} = [ @{ $ctx->{'thumb_cache'}->{$folder} } ];
	}

	if ($filename !~ /\.enc$/gi) {
		my $folder = $f->{'artist_folder'} || '';
		unless (exists $ctx->{'file_information'}->{$folder}) {
			$ctx->{'file_information'}->{$folder} = &subs::cache_get({ app => 'music', context => 'file_information', subcontext => $folder }) || {};
		}
		my $file_information = $ctx->{'file_information'}->{$folder};
		# A cached answer is only reused when it carries the facts a card draws.
		# Entries written by a failed probe ({ chapters => undef }) were truthy
		# and stayed for ever, hiding every thumbnail in the folder.
		if (&subs::music_info_usable($file_information->{$filename})) {
			$f->{'info'} = $file_information->{$filename};
		}
		else {
			# The raw path: file_media_information quotes it for ffprobe itself.
			# Passing terminal_name's backslash-escaped path made the two quoting
			# layers fight (a space became \\ inside ffprobe's own quotes), so
			# every re-probe failed on a name with a space, a bracket or an
			# apostrophe.
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
	$f->{'probed'} = 1;
	&music_row_labels($f);
	return $f;
}

# Rebuild one track from its manifest entry. The client hands entries back for
# a scroll, so the server never re-walks the library to draw the next slice.
sub music_row_from_entry($entry) {
	my $file = $entry->{'file'} || $entry->{'filename'} || '';
	return {
		filename => $file,
		file => $file,
		file_uuid => $entry->{'file_uuid'} || '',
		type => $entry->{'type'} || '',
		app => $entry->{'app'} || '',
		remote_uuid => $entry->{'remote_uuid'} || '',
		computer_name => $entry->{'computer_name'} || '',
		colour => $entry->{'colour'} || '',
		dark_colour => $entry->{'dark_colour'} || '',
		artist_name => $entry->{'artist_name'} || '',
		album_name => $entry->{'album_name'} || '',
		artist_folder => $entry->{'artist_folder'} || '',
		album_folder => $entry->{'album_folder'} || '',
		song => $entry->{'song'} || '',
		full_title => $entry->{'full_title'} || '',
		formatted_name => $entry->{'formatted_name'} || '',
		display_artist => $entry->{'display_artist'} || '',
		display_album => $entry->{'display_album'} || '',
		display_track => $entry->{'display_track'} || '',
		display_code => $entry->{'display_code'} || '',
		display_meta => $entry->{'display_meta'} || '',
		info => (ref $entry->{'info'} eq 'HASH' ? $entry->{'info'} : {}),
		thumbs => [],
		noise => (ref $entry->{'noise'} eq 'HASH' ? $entry->{'noise'} : {}),
		archive => $entry->{'archive'} ? 1 : 0,
		probed => $entry->{'probed'} ? 1 : 0,
	};
}

# The rows a scroll asks for: the client hands back the manifest entries it
# already holds, so the server renders only that slice and returns the enriched
# entries (labels, duration, thumb, chapters) for the client's queue.
sub music_window_songs($rows, $data) {
	my $ctx = $data->{'context'} || &music_probe_context();
	my $now_playing = $data->{'now_playing'} || {};
	my $remote_uuid = $data->{'remote_uuid'};
	# a window is a few screens; do not let one request turn into a whole
	# library of probes
	my @wanted = @{ (ref $rows eq 'ARRAY') ? $rows : [] };
	@wanted = @wanted[0 .. 999] if scalar @wanted > 1000;
	my (@songs, @out);
	foreach my $entry ( @wanted ) {
		next unless ref $entry eq 'HASH';
		my $file = $entry->{'file'} || $entry->{'filename'} || '';
		next unless length $file;
		# never probe a path the queue would not have listed
		next unless &music_queue_file_visible($file, $data->{'permissive'} ? 1 : 0);
		my $f = &music_row_from_entry($entry);
		$f = &music_song_probe($ctx, $f);
		$f->{'playing'} = 'yes' if $now_playing->{'file'} && $now_playing->{'file'} eq $f->{'filename'};
		push @songs, $f;
		push @out, &music_manifest_entry($f, $remote_uuid);
	}
	&music_flush_information($ctx);
	return { songs => \@songs, rows => \@out };
}

sub song_maker($data) {
	my $files = $data->{'files'};
	my $settings = $data->{'settings'};
	my $now_playing = $data->{'now_playing'} || {};
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
	my $max_files = &subs::setting_grabber({ app => 'misc', setting => 'max_files' }) || 30;
	my $remote_uuid = $c ? $c->param('remote_uuid') : undef;
	my $ctx = &music_probe_context();
	$ctx->{'tree'} = &subs::inventory_grabber();
	$ctx->{'computer_name'} = $computer_name;
	$ctx->{'background_colour'} = $background_colour;
	$ctx->{'dark_background_colour'} = $dark_background_colour;
	my $artists = {};
	my $albums = {};
	my $songs = [];
	my @manifest;
	my @queue;
	my $current_track;

	# Which slice this render draws, and (for that slice plus the playing
	# track) which rows are worth probing.
	my ($window_offset, $window_limit) = &music_window_window($data);

	# A local copy is the one the person wants; the archive is the fallback for
	# what is not on this disk. Spend the budget on local files first, in the
	# order the window chose, then fill whatever is left with archived tracks.
	@local_files = &music_budget_files(\@local_files, $archive, $max_files);
	if ($now_playing->{'file'}) {
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
		my $path = $local_files[$n];
		last unless defined $path;
		# an archived track is not on this disk: the manifest already said what
		# it is, and its machine is where the player fetches the bytes from
		my $archive_row = $archive->{$path};
		unless ($archive_row || -e $path) {
			next;
		}
		my ($dir) = $path =~ m{^(.*)/[^/]*$};
		$dir = '' unless defined $dir;
		my $f = &music_row_new($path, $ctx, $archive_row, $noise_by_folder{$dir} || {});

		my $q = scalar @manifest;
		my $in_window = ($q >= $window_offset && $q < $window_offset + $window_limit) ? 1 : 0;
		my $is_now = ($now_playing->{'file'} && $now_playing->{'file'} eq $f->{'filename'}) ? 1 : 0;
		$f = &music_song_probe($ctx, $f) if ($in_window || $is_now);
		if ($is_now) {
			$current_track = $q;
			$f->{'playing'} = 'yes';
		}

		push @queue, $f->{'filename'};
		push @manifest, &music_manifest_entry($f, $remote_uuid);
		push @{$songs}, $f if $in_window;

		my $artist_key = $f->{'folder_artist_key'};
		my $album_key = $f->{'folder_album_key'};
		$artists->{$artist_key}->{'path'} = $f->{'artist_folder'};
		push @{$artists->{$artist_key}->{'tracks'}}, $f;
		$albums->{$album_key}->{'path'} = $f->{'album_folder'};
		push @{$albums->{$artist_key}->{'tracks'}}, $f;

		if ($data->{'settings'}->{'all_artists'} eq 'yes') {
			$cache_artists->{lc $f->{'artist'}} = { path => $f->{'artist_folder'}, artist => $f->{'artist'} };
		}
		if ($data->{'settings'}->{'all_albums'} eq 'yes') {
			$cache_albums->{lc $f->{'album'}} = { path => $f->{'album_folder'}, album => $f->{'album'} };
		}
	}
	&music_flush_information($ctx);
	if ($data->{'settings'}->{'all_artists'} eq 'yes') {
		&subs::cache_set({ app => 'music', context => 'artists' }, $cache_artists);
		$artists = $cache_artists;
	}
	if ($data->{'settings'}->{'all_albums'} eq 'yes') {
		&subs::cache_set({ app => 'music', context => 'albums' }, $cache_albums);
		$albums = $cache_albums;
	}

	# A token over the ordered queue: the client uses it to tell a real list
	# change from a scroll that merely swapped the rendered slice.
	my $queue_join = join("\x01", @queue);
	my ($queue_sum, $queue_len) = (0, 0);
	foreach my $ch ( split //, $queue_join ) {
		$queue_sum = ($queue_sum * 31 + ord($ch)) % 4294967296;
		$queue_len++;
	}

	my $crate = {
		config => $config,
		remote_uuid => $remote_uuid,
		library_name => &music_library_label($settings, $c),
		current_track => $current_track,
		artist => $settings->{'artist'},
		album => $settings->{'album'},
		artists => $artists,
		albums => $albums,
		# songs is the drawn slice; manifest is the whole ordered queue. The
		# player and the queue saver read the manifest, never the slice.
		songs => $songs,
		manifest => \@manifest,
		queue => \@queue,
		queue_total => scalar @manifest,
		queue_token => sprintf('%08x%08x', $queue_len % 4294967296, $queue_sum),
		window_offset => $window_offset,
		window_limit => $window_limit,
		settings => $settings,
	};
	return $crate;
}

1;
