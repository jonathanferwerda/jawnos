package Manager;
use strict;
use warnings;
no warnings 'uninitialized';
use feature 'signatures';

use Mojo::JSON qw(decode_json encode_json);

our ($music_device, $music_files, $music_permissive);

# Which folders this device is looking at, by location name as well as by path.
# The window sends the buttons it has lit and the names are the intent -
# documents, downloads, and so on - while the path behind each one is this
# machine's own, so a library on another machine is asked for the same locations
# by name instead of by this machine's paths. Without a selection the stored
# toggles decide, which is what the first window build has to go on. A lit button
# with no path behind it on this machine is nothing to walk, and is left out
# rather than guessed at.
sub music_folder_selection($selected) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my @picked = ();
	my $settings = &Manager::misc_setting_list();
	my %wanted;
	my $chosen = defined $selected;
	foreach my $s ( @{$selected || []} ) {
		next unless $s =~ /_location$/;
		$wanted{$s} = 1;
	}
	foreach my $s ( sort keys %{$settings->{$music_device}} ) {
		if ($s =~ /_location$/gi) {
			my $status = &subs::setting_grabber({ app => 'music_folder_toggle', setting => $s, device => $music_device });
			if ($chosen) {
				next unless $wanted{$s};
			}
			elsif ($status ne 'on') {
				next;
			}
			my $path = $settings->{$music_device}->{$s};
			next unless (defined $path && length $path);
			my $location = $s;
			$location =~ s/_location$//;
			push @picked, { location => $location, path => $path };
		}
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
	my $device = &subs::device_setter();
	my $machines = &subs::remote_machine_lister({ self => 'no' });
	my @lookups;
	foreach my $pick ( @{$picked} ) {
		if ($pick->{'location'}) {
			my $rm = &subs::archive_machine_for($pick->{'location'}, $misc->{$device} || {}, $machines);
			next unless ($rm && $rm->{'uuid'});
			push @lookups, { location => $pick->{'location'}, remote_uuid => $rm->{'uuid'}, prefix => '' };
		}
		else {
			my $plan = &subs::archive_plan({
				items => [ { path => $pick->{'path'}, type => 'folder' } ],
				settings => $misc->{$device} || {},
				machines => $machines
			});
			foreach my $job ( @{$plan->{'jobs'}} ) {
				push @lookups, { location => $job->{'location'}, remote_uuid => $job->{'remote_uuid'}, prefix => $job->{'relative'} };
			}
		}
	}
	my (@entries, %fetched);
	foreach my $lookup ( @lookups ) {
		my $key = $lookup->{'location'} . '|' . $lookup->{'remote_uuid'};
		my $manifest = $fetched{$key};
		unless (defined $manifest) {
			# the listing is an errand, not a transfer: a sleeping archive machine
			# must not hold the worker (and the window) for the long default
			$manifest = &subs::archive_manifest_fetch({ remote_uuid => $lookup->{'remote_uuid'}, location => $lookup->{'location'}, timeout => 6 });
			$fetched{$key} = $manifest;
		}
		next if $manifest->{'error'};
		my $folder = $manifest->{'folder'} || '';
		foreach my $row ( @{$manifest->{'rows'} || []} ) {
			my $type = $row->{'type'} || '';
			next unless ($type eq 'audio' || $type eq 'video');
			my $relative = $row->{'relative'} || '';
			next unless length $relative;
			# a sealed track waits for the padlock only when its album is hidden
			next if (!$music_permissive && $relative =~ /\.enc$/i && !music_app_visible($relative));
			next if (length $lookup->{'prefix'} && index($relative, $lookup->{'prefix'}) != 0);
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
	return undef unless $crate && ref $crate->{'songs'} eq 'ARRAY';
	my @files = map { $_->{'filename'} } grep { $_->{'filename'} } @{ $crate->{'songs'} };
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

	my @folders;
	my %archive;
	if ($data->{'files'}) {
		$music_files = $data->{'files'};
	}
	else {
		my $picked = [];
		if (scalar @{$settings->{'album'}} > 0) { 
			push @folders, map { $_->{'path'} } @{$settings->{'album'}};
			$picked = [ map { { path => $_->{'path'} } } @{$settings->{'album'}} ];
		}
		elsif (scalar @{$settings->{'artist'}} > 0) {
			push @folders, map { $_->{'path'} } @{$settings->{'artist'}};
			$picked = [ map { { path => $_->{'path'} } } @{$settings->{'artist'}} ];
		}
		else {
			my $selection = &music_folder_selection($data->{'folders'});
			@folders = map { $_->{'path'} } @{$selection};
			$picked = $selection;
		}
		my @walk = grep { -d } map { &subs::home($_) } @folders;
		&process_file($_) for &subs::dir_listing(\@walk);
		# the archive is part of the collection too, when the app is asked to
		# look there: its manifest is the listing, and each row knows the
		# machine its bytes come from
		if ($settings->{'archive'} eq 'on') {
			my $archived = &music_archive_entries({ picked => $picked, misc_settings => $misc_settings });
			foreach my $entry ( @{$archived->{'entries'}} ) {
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
	my $crate = &song_maker({ c => $c, port => $port, files => \@local_files, archive => \%archive, settings => $settings, now_playing => $now_playing, same_order => $data->{'same_order'} });
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
