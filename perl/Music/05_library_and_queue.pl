package Manager;
use strict;
use warnings;
no warnings 'uninitialized';
use feature 'signatures';

use Mojo::JSON qw(decode_json encode_json);

our ($music_device, $music_files, $music_permissive);

# This machine's own misc row, with the device class filling a key it has never
# written. The class is shared by machines that are not alike - a laptop and a
# tablet are both 'computer' - so reading it directly gave the laptop the
# tablet's /sdcard/Music paths and the walk found nothing. misc_setting_list
# already folds the class into the signatorial row for the music apps; this is
# the whole row for the callers that need more than one key (locations, archives).
sub music_machine_settings($misc_settings) {
	$misc_settings = &Manager::misc_setting_list() unless ref $misc_settings eq 'HASH';
	my %settings = %{ $misc_settings->{$music_device} || {} };
	my $machine = &subs::signatorial_designer();
	if (defined $machine && length $machine && ref $misc_settings->{$machine} eq 'HASH') {
		foreach my $key ( keys %{ $misc_settings->{$machine} } ) {
			my $value = $misc_settings->{$machine}->{$key};
			$settings{$key} = $value if defined $value && length $value;
		}
	}
	return \%settings;
}

# The local root each location type keeps its files in, as this machine sees
# it. A configured <location>_location wins; when the row is absent the house's
# folder list supplies the conventional folder (Videos, Music, ...), which is
# what the configure panel offers and what an archive folder is named after.
sub music_location_roots($misc_settings, $folders = undef) {
	my $settings = &music_machine_settings($misc_settings);
	my @folders = ref $folders eq 'ARRAY' ? @{$folders} : @{ &subs::config_reader()->{'folders'} || [] };
	my %roots;
	foreach my $location ( &subs::location_types() ) {
		my $root = $settings->{$location . '_location'};
		unless (defined $root && length $root) {
			my $name = lc &subs::archive_folder_name($location);
			foreach my $folder ( @folders ) {
				next unless defined $folder && length $folder;
				my $base = $folder;
				$base =~ s{/+$}{};
				my ($leaf) = $base =~ m{([^/]+)$};
				next unless defined $leaf && lc($leaf) eq $name;
				$root = $folder;
				last;
			}
		}
		next unless defined $root && length $root && lc($root) ne 'null';
		my $path = &subs::home($root);
		$path =~ s{/+$}{};
		$roots{$location} = $path if length $path;
	}
	return \%roots;
}

# The (location, relative path) a local file belongs to. The longest matching
# root wins, so a scans folder inside documents resolves to scans; a tie, which
# is two names for one folder, follows the location order, exactly as
# archive_plan does.
sub music_local_parts($path, $roots) {
	return undef unless defined $path && length $path;
	my $best;
	my $order = 0;
	foreach my $location ( &subs::location_types() ) {
		$order++;
		my $base = $roots->{$location};
		next unless defined $base && length $base;
		next unless ($path eq $base || $path =~ m{^\Q$base\E/});
		my $relative = ($path eq $base) ? '' : substr($path, length($base) + 1);
		next if $best && length($base) < length($best->{'base'});
		next if $best && length($base) == length($best->{'base'}) && $order >= $best->{'order'};
		$best = { location => $location, relative => $relative, base => $base, order => $order };
	}
	return $best;
}

# The (location, relative path) an archive path names. The machines advertise
# their drive, and both the readable folder name and the older lower-case one
# count, so a drive filled before the names moved still resolves. Undef when the
# path is not under any advertised archive.
sub music_archive_parts($path, $machines) {
	return undef unless defined $path && length $path;
	$path =~ s{\\}{/}g;
	$path =~ s{/+$}{};
	foreach my $rm ( @{ $machines || [] } ) {
		next unless ref $rm eq 'HASH';
		my $dir = $rm->{'archive_dir'};
		next unless defined $dir && length $dir && lc($dir) ne 'null';
		my $root = &subs::home($dir);
		$root =~ s{/+$}{};
		foreach my $location ( &subs::location_types() ) {
			foreach my $name ( &subs::archive_folder_name($location), $location ) {
				my $folder = $root . '/' . $name;
				next unless ($path eq $folder || $path =~ m{^\Q$folder\E/});
				my $relative = ($path eq $folder) ? '' : substr($path, length($folder) + 1);
				return { location => $location, relative => $relative };
			}
		}
	}
	return undef;
}

# Where a location's relative path lives on this machine. Undef when the
# location has no local root at all, which is not an error: the archive is the
# fallback.
sub music_local_path($location, $relative, $roots) {
	my $root = $roots->{$location};
	return undef unless defined $root && length $root;
	return length($relative // '') ? $root . '/' . $relative : $root;
}

# The local walk and the archive lookups one window's selection makes. An
# artist or album pick can name a local path or an archive path; both resolve to
# the same location and relative path, so the local copy is walked and the
# archive is asked for that folder. A pick under neither keeps the old
# archive_plan behaviour.
sub music_selection_plan($picks, $roots, $machines) {
	my (@walk, @archive, %seen);
	foreach my $pick ( @{ $picks || [] } ) {
		next unless ref $pick eq 'HASH';
		my $path = $pick->{'path'};
		next unless defined $path && length $path;
		$path = &subs::home($path);
		$path =~ s{/+$}{};
		next if $seen{$path}++;
		my ($location, $relative);
		if (defined $pick->{'location'} && length $pick->{'location'}) {
			$location = $pick->{'location'};
			$relative = $pick->{'relative'} // '';
		}
		else {
			my $local = &music_local_parts($path, $roots);
			my $archived = $local ? undef : &music_archive_parts($path, $machines);
			if ($local) {
				($location, $relative) = ($local->{'location'}, $local->{'relative'});
			}
			elsif ($archived) {
				($location, $relative) = ($archived->{'location'}, $archived->{'relative'});
			}
		}
		if (defined $location && length $location) {
			my $walk = &music_local_path($location, $relative, $roots);
			push @walk, $walk if defined $walk && length $walk;
			push @archive, { location => $location, relative => $relative, path => $path };
		}
		else {
			push @archive, { path => $path };
		}
	}
	return { walk => \@walk, archive => \@archive };
}

# Which folders this device is looking at, by location name as well as by path.
# The window sends the buttons it has lit and the names are the intent -
# documents, downloads, and so on - while the path behind each one is this
# machine's own, so a library on another machine is asked for the same locations
# by name instead of by this machine's paths. Without a selection the stored
# toggles decide, which is what the first window build has to go on. A lit button
# with no path behind it on this machine is nothing to walk, and is left out
# rather than guessed at.
sub music_folder_selection($selected) {
	my @picked = ();
	my $roots = &music_location_roots(&Manager::misc_setting_list());
	my %wanted;
	my $chosen = defined $selected;
	foreach my $s ( @{$selected || []} ) {
		next unless $s =~ /_location$/;
		$wanted{$s} = 1;
	}
	foreach my $location ( &subs::location_types() ) {
		my $s = $location . '_location';
		my $path = $roots->{$location};
		next unless defined $path && length $path;
		# the lit buttons are this machine's memory, so the signatorial is the
		# key; a class row from an older build is the fallback
		my $status = &subs::setting_grabber({ app => 'music_folder_toggle', setting => $s }) // '';
		if ($chosen) {
			next unless $wanted{$s};
		}
		elsif ($status ne 'on') {
			next;
		}
		push @picked, { location => $location, path => $path };
	}
	return \@picked;
}

sub music_folder_grabber($selected) {
	return map { $_->{'path'} } @{&music_folder_selection($selected)};
}

# The archived half of a listing. For the folders being looked at, the rows come
# from the archive machine's manifest - one small request instead of a walk over
# the tunnel - and each row keeps the machine it lives on, because that is where
# the player has to fetch the bytes from. An artist or album pick reads the same
# manifest down to that folder instead of a whole location.
sub music_archive_entries($data) {
	my $picked = $data->{'picked'} || [];
	my $misc = $data->{'misc_settings'} || &Manager::misc_setting_list();
	my $machine_settings = &music_machine_settings($misc);
	my $machines = $data->{'machines'} || &subs::archive_machines();
	my @lookups;
	foreach my $pick ( @{$picked} ) {
		if ($pick->{'location'}) {
			my $rm = &subs::archive_machine_for($pick->{'location'}, $machine_settings, $machines);
			next unless ($rm && ($rm->{'self'} || $rm->{'uuid'}));
			push @lookups, { location => $pick->{'location'}, rm => $rm, remote_uuid => ($rm->{'self'} ? '' : $rm->{'uuid'}), prefix => ($pick->{'relative'} // '') };
		}
		else {
			my $plan = &subs::archive_plan({
				items => [ { path => $pick->{'path'}, type => 'folder' } ],
				settings => $machine_settings,
				machines => $machines
			});
			foreach my $job ( @{$plan->{'jobs'}} ) {
				my $rm = $job->{'local'}
					? { self => 1, archive_dir => &subs::archive_root(), hostname => $job->{'remote_hostname'} }
					: { uuid => $job->{'remote_uuid'}, hostname => $job->{'remote_hostname'} };
				push @lookups, { location => $job->{'location'}, rm => $rm, remote_uuid => ($job->{'local'} ? '' : $job->{'remote_uuid'}), prefix => $job->{'relative'} };
			}
		}
	}
	my (@entries, %fetched);
	foreach my $lookup ( @lookups ) {
		my $key = $lookup->{'location'} . '|' . ($lookup->{'remote_uuid'} || 'self');
		my $manifest = $fetched{$key};
		unless (defined $manifest) {
			# the listing is an errand, not a transfer: a sleeping archive machine
			# must not hold the worker (and the window) for the long default
			$manifest = &subs::archive_manifest_for({ rm => $lookup->{'rm'}, location => $lookup->{'location'}, timeout => 6 });
			$fetched{$key} = $manifest;
		}
		next if $manifest->{'error'};
		my $folder = $manifest->{'folder'} || '';
		foreach my $row ( @{$manifest->{'rows'} || []} ) {
			my $type = &subs::archive_row_type($row);
			next unless ($type eq 'audio' || $type eq 'video');
			my $relative = $row->{'relative'} || '';
			next unless length $relative;
			# a sealed track waits for the padlock only when its album is hidden
			next if (!$music_permissive && $relative =~ /\.enc$/i && !music_app_visible($relative));
			if (length $lookup->{'prefix'}) {
				my $prefix = $lookup->{'prefix'};
				next unless ($relative eq $prefix || index($relative, $prefix . '/') == 0);
			}
			push @entries, {
				path => (length $folder ? $folder . '/' . $relative : $relative),
				location => $lookup->{'location'},
				relative => $relative,
				type => $type,
				info => $row->{'info'} || {},
				size => $row->{'size'},
				mtime => $row->{'mtime'},
				remote_uuid => $lookup->{'remote_uuid'},
				remote_hostname => $manifest->{'hostname'} || ''
			};
		}
	}
	return { entries => \@entries };
}

# The queue the window is showing, remembered as data rather than as the rendered
# shell. A list put together by the guide's play, by the folders app or by an
# artist pick cannot be reconstructed from the saved search, and the shell that
# used to carry it is only kept for the running code revision - so a deploy lost
# the list. These files are the list itself, in the order it was shown.
sub music_queue_remember($crate, $settings, $permissive) {
	# An unlocked render must not store a queue: its media grant dies with the
	# window, so the list could be replayed into a window that may not list
	# those tracks. The previous locked queue stays in place instead.
	return undef if $permissive;
	return undef unless $crate && (ref $crate->{'queue'} eq 'ARRAY' || ref $crate->{'songs'} eq 'ARRAY');
	# The queue is the whole ordered list, not the slice this render drew. A
	# remembered slice would lose every track beyond the window on the next open.
	my @files = ref $crate->{'queue'} eq 'ARRAY'
		? @{ $crate->{'queue'} }
		: map { $_->{'filename'} } grep { $_->{'filename'} } @{ $crate->{'songs'} || [] };
	@files = grep { defined $_ && length $_ } @files;
	# an empty result is not a queue: keep the one that is still worth coming
	# back to rather than storing a window with nothing in it
	return undef unless scalar @files;
	my $saved = &subs::rightNow();
	&subs::cache_set({ app => 'music', context => 'queue', warranty => '-6M' }, {
		files => \@files,
		library => ($settings->{'library'} || 'local'),
		# a record of how the list was assembled (a filter, not a gate: what may
		# be listed is decided per file when the queue is replayed)
		permissive => ($permissive ? 1 : 0),
		saved => $saved,
	});
	return $saved;
}

# The queue to replay when the window shell is not in the cache. Undef means
# "search as before": the remembered queue is from another library, nothing in
# it may be listed in this window, or the archive is on (a replayed list would
# wear its rows as plain local files, because the manifest walk is what gives
# them their machine).
sub music_queue_recall($settings, $unlocked) {
	return undef if (($settings->{'archive'} // '') eq 'on');
	my $queue = &subs::cache_get({ app => 'music', context => 'queue' });
	return undef unless &subs::music_queue_applies($queue, $settings->{'library'});
	# The queue is data, so it is filtered by the same rule the folder walk uses
	# rather than by the grant that happened to be on the window when it was
	# assembled. That is what lets a list built while unlocked come back in a
	# locked window - the ordinary case, since every window is reopened without a
	# token - while a sealed or private track still never appears in one that may
	# not list it.
	my @keep = grep { &music_queue_file_visible($_, $unlocked) } @{ $queue->{'files'} };
	return undef unless scalar @keep;
	return { files => \@keep, key => ($queue->{'saved'} || '0') };
}

# Would the folder walk have listed this file in a window holding this grant?
# The same tests process_file applies, so a replayed queue cannot show a name
# the walk would have hidden.
sub music_queue_file_visible($name, $permissive) {
	if (&music_app_private($name)) {
		return 0 unless &subs::private_reachable_now();
		return 0 unless $permissive == 1 || &subs::private_revealed();
	}
	return 1 if &playable_name($name);
	return 0 unless ($permissive == 1 || &music_app_visible($name)) && &playable_enc_name($name);
	return 1;
}

sub music_search($data) {
	my $search = $data->{'search'};
	my $now_playing = $data->{'now_playing'};
	my $settings = $data->{'settings'};
	my $c = $data->{'c'};
	my $misc_settings = $data->{'misc_settings'};
	my $port = $data->{'port'};
	my $misses = $data->{'misses'};
	$music_files = [];
	unless ($settings->{'uuid'}) {
		$settings = &subs::settings_grabber({ app => 'music' });
		$settings->{'artist'} = eval { return decode_json $settings->{'artist'} } || [];
		$settings->{'album'} = eval { return decode_json $settings->{'album'} } || [];
	}
	# the window's token decides this, not the secret left in settings: a
	# fresh open is locked even if an earlier window still holds one
	$music_permissive = $data->{'permissive'} ? 1 : 0;

	my %archive;
	if ($data->{'files'}) {
		$music_files = $data->{'files'};
	}
	else {
		my $roots = &music_location_roots($misc_settings);
		my $machines = &subs::archive_machines();
		my $picked = [];
		if (scalar @{$settings->{'album'}} > 0) {
			$picked = [ map { { path => $_->{'path'} } } @{$settings->{'album'}} ];
		}
		elsif (scalar @{$settings->{'artist'}} > 0) {
			$picked = [ map { { path => $_->{'path'} } } @{$settings->{'artist'}} ];
		}
		else {
			$picked = &music_folder_selection($data->{'folders'});
		}
		# A local copy wins. The selection resolves to a location and a path
		# inside it, whether the pick named this disk or the archive, so the
		# local folder is walked first and the archive is asked only for what
		# the walk did not find.
		my $plan = &music_selection_plan($picked, $roots, $machines);
		my @walk = grep { -d } @{ $plan->{'walk'} };
		&process_file($_) for &subs::dir_listing(\@walk);
		my %local_keys;
		foreach my $file ( @{$music_files} ) {
			my $parts = &music_local_parts(&subs::home($file), $roots);
			$local_keys{$parts->{'location'} . '|' . $parts->{'relative'}} = 1 if $parts;
		}
		# the archive is the fallback, when the app is asked to look there: its
		# manifest is the listing, and each row knows the machine its bytes come
		# from. A row whose relative path is already on this disk is left out.
		if (($settings->{'archive'} // '') eq 'on') {
			my $archived = &music_archive_entries({ picked => $plan->{'archive'}, misc_settings => $misc_settings, machines => $machines });
			foreach my $entry ( @{$archived->{'entries'}} ) {
				next if $local_keys{($entry->{'location'} // '') . '|' . ($entry->{'relative'} // '')};
				push @{$music_files}, $entry->{'path'};
				$archive{$entry->{'path'}} = $entry;
			}
		}
	}
	my @local_files = @{$music_files};
	if ($search && !$data->{'files'}) {	
		@local_files = grep { lc $_ =~ /($search)/gi } @{$music_files};
	}
	# a caller that only wants the matches (the guide's play_music) gets the file
	# list back instead of a rendered crate, so it can hand one file to the player
	if ($data->{'return_files'}) {
		return { files => \@local_files, count => scalar @local_files };
	}
	my $crate = &song_maker({ c => $c, port => $port, files => \@local_files, archive => \%archive, settings => $settings, now_playing => $now_playing, same_order => $data->{'same_order'}, window => $data->{'window'} });
	$music_permissive = 0;
	return $crate;
}

# A peer's name for the library label. A Termux machine's own hostname is
# 'localhost', which tells nobody which library they are on; its fqdn (or its
# address) does.
sub music_remote_label($rm) {
	return '' unless $rm;
	my $host = $rm->{'hostname'} || '';
	$host = $rm->{'fqdn'} || $rm->{'ip'} || '' if $host eq '' || lc($host) eq 'localhost' || lc($host) eq 'me';
	return $host || $rm->{'uuid'} || '';
}

# What the search bar should say the library is: this machine's own name for a
# local library, or the host the window was relayed from for a remote one. The
# caller passes library_name when it relays, because the page is then rendered
# by the remote machine and knows itself only as 'local'.
sub music_library_label($settings, $c) {
	my $passed = $c ? $c->param('library_name') : undef;
	return $passed if defined $passed && length $passed;
	my $library = $settings->{'library'} // '';
	if ($library eq '' || $library eq 'local') {
		return &subs::setting_grabber({ app => 'me', setting => 'computer_name' })
			|| &subs::config_reader()->{'name'}
			|| &subs::ui('Local');
	}
	return &subs::ui('None') if $library eq 'none';
	my $rm = &subs::db_query('select hostname,fqdn,ip from remote_machines where uuid=?', $library)->hashes->[0];
	my $host = &music_remote_label($rm);
	return $host if length $host;
	return $library;
}

1;
