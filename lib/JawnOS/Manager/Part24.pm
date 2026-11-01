package Manager;

# Manager helpers, part 24 of 37. Moved out of Manager.pl so a
# helper can be read and changed without opening 24k lines. The package is
# still Manager, and lib/JawnOS/Manager/Index.pm maps every sub name here to
# this file; Manager.pm loads it on the first call.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

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

sub folders_listing($folder, $unlocked, $c, $show_hidden) {
	my $formatted_folder = &subs::terminal_name($folder);
	my $files = [];
	my $total_size = 0;
	foreach my $f ( &folders_entry_names($folder, $show_hidden) ) {
		my $file = &folders_property_grabber({ folder => $folder, file => $f });
		$total_size += $file->{'size'} unless $file->{'type'} eq 'folder';
		push @{$files}, $file;
	}
	# a thing the person hid (visible ne checked) is not listed unless this
	# window holds a valid Folders token - the same per-window rule the gallery
	# reads, so a grant left by a closed window reveals nothing
	my $revealed = $unlocked ? 1 : 0;
	# a sealed name (.enc) is listed without a padlock when its app is marked
	# visible; only a name belonging to a hidden app waits for the unlock
	@{$files} = grep {
		my $app = folders_owning_app($_->{'path'});
		# Private is a lock, not a place level: outside a private place its files
		# are not listed at all, whatever the Folders padlock still holds.
		my $private_unreachable = $app && &subs::app_private_now($app) && !&subs::private_reachable_now();
		my $hidden = ($app && help_app_hidden($app) && (!$revealed || &subs::lockdown_active()));
		my $sealed_name = ((!$unlocked || &subs::lockdown_active()) && ($_->{'name'} // '') =~ /\.enc$/i && (!$app || help_app_hidden($app)));
		!$private_unreachable && !$hidden && !$sealed_name;
	} @{$files};
	my $archive_index = &folders_archive_index($folder);
	if ($archive_index->{'rows'}) {
		my $base_len = length($archive_index->{'base'}) + 1;
		foreach my $file ( @{$files} ) {
			my $path = $file->{'path'} // '';
			next unless length $path;
			my $rel = substr($path, $base_len);
			next unless defined $rel && length $rel;
			if (($file->{'type'} || '') eq 'folder') {
				$file->{'archived'} = $archive_index->{'dirs'}->{$rel} ? 1 : 0;
			}
			else {
				$file->{'archived'} = $archive_index->{'rows'}->{$rel} ? 1 : 0;
			}
		}
	}
	my @folders = grep { $_->{'type'} eq 'folder' } @{$files};
	@{$files} = grep { $_->{'type'} ne 'folder' } @{$files};
	# the names the house gave its own folders and seals, for the eye only: the
	# path every command works on is still the real one
	my $apps = &folders_app_names();
	foreach my $file ( @folders ) {
		next if defined $file->{'display'};
		my $display = &folders_app_folder_display($file->{'path'}, $apps);
		$file->{'display'} = $display if defined $display;
	}
	my @sealed = grep { ($_->{'name'} // '') =~ /\.enc$/i } @{$files};
	if (scalar @sealed) {
		my $references = &subs::file_reference_read();
		foreach my $file ( @sealed ) {
			next if defined $file->{'display'};
			my $display = &folders_sealed_display($file->{'path'}, $apps, $references);
			$file->{'display'} = $display if defined $display && length $display;
		}
	}
	my $disk = {
		folders => scalar @folders,
		files => scalar @{$files},
		total_size => &subs::data_size($total_size)
	};
	unshift @{$files}, @folders;
	# In the bin the stored name (name, name.1, ...) is only the move's own; the
	# person reads the name it had where it came from, so list by that.
	if (&folders_in_trash($folder)) {
		@{$files} = sort {
			lc($_->{'display'} || $_->{'name'}) cmp lc($_->{'display'} || $_->{'name'})
				|| ($_->{'display'} || $_->{'name'}) cmp ($_->{'display'} || $_->{'name'})
		} @{$files};
	}
	# the disk figures belong to the path being read; `--` keeps a path that
	# starts with a dash from being read as an option
	my $df = `df -h -- $formatted_folder 2>/dev/null`;
	my @df = split /\n/, $df;
	my @first_line = split(/\s+/, $df[0] // '');
	my @data_line = split(/\s+/, $df[1] // '');
	for ( my $n = 0; $n < scalar @first_line; $n++) {
		$disk->{$first_line[$n]} = $data_line[$n];
	}
	return { files => $files, folders => \@folders, disk => $disk };
}

sub folders_property_grabber($data) {
	my $folder = $data->{'folder'};
	my $f = $data->{'file'};
	my $path = $folder . '/' . $f;
	my $file = {
		name => $f,
		path => $path
	};
	my $ftype = &file_type_recognizer($path);
	$file->{'type'} = $ftype->{'type'} || 'file';
	$file->{'icon'} = $ftype->{'icon'};
	# In the Recycle Bin the stored name is only the move's own; show the name
	# it had where it came from, and remember the whole path for Properties.
	if (&folders_in_trash($folder)) {
		my $original = &folders_trash_original($f);
		if (length $original) {
			my @orig = split '/', $original;
			$file->{'display'} = pop @orig;
			$file->{'trash_original'} = $original;
		}
	}
	my $thumb_dir = $folder . '/.thumbs';
	if (-e $thumb_dir && $file->{'type'} eq 'video') {
		my $formatted_thumbs_dir = &subs::terminal_name($thumb_dir);
		my $thumbs = `ls $formatted_thumbs_dir`;
		my @f = split /\./, $f;
		pop @f;
		my $f_thumb = join '.', @f;
		my @thumbs = grep { $_ =~ /\Q$f_thumb/ } split /\n/, $thumbs;
		$file->{'thumbs'} = [ map { $thumb_dir . '/' . $_ }  @thumbs ];
		$file->{'icon'} = '/file_open?file=' . uri_encode $thumb_dir . '/' . $thumbs[0];

	}



	# A generic file, a folder, a track, subtitles and a sealed file fall back to
	# the hand-drawn pictures; an icon set names those same pictures, so the
	# listing (and the desk drawn from it) wears the chosen set like the rest of
	# the interface. A generated thumbnail is the file's own picture and stays.
	if (($file->{'icon'} || '') =~ m{^/(?:images|icons)/}) { $file->{'icon'} = &subs::icon_for($file->{'icon'}); }

	# in list context, so the template can read the mtime the way it reads any
	# other stat result; a scalar stat here gives back a count, not the fields
	my @stat = stat($path);
	$file->{'stat'} = \@stat;
	$file->{'size'} = -s $path;

	$file->{'path'} = $path;

	return $file;
}

sub folders_name_cleaner {
	my $name = shift;
	return undef unless defined $name;
	$name =~ s{^\s+|\s+$}{}g;
	return undef if ($name eq '' || $name eq '.' || $name eq '..');
	return undef if $name =~ m{/};
	return $name;
}

sub folders_command_items {
	my $folders = shift;
	my @items = grep { defined $_->{'path'} && length $_->{'path'} } @{$folders->{'selected'} || []};
	push @items, { path => $folders->{'path'} } if (!scalar @items && $folders->{'path'});
	return @items;
}

sub folders_trash_root {
	my $root = &subs::home('~/.local/share/Trash');
	$root =~ s{/+$}{};
	return $root;
}

sub folders_trash_files_dir {
	my $dir = &folders_trash_root() . '/files';
	File::Path::make_path($dir) unless -d $dir;
	return $dir;
}

sub folders_trash_info_dir {
	my $dir = &folders_trash_root() . '/info';
	File::Path::make_path($dir) unless -d $dir;
	return $dir;
}

sub folders_in_trash($folder) {
	return 0 unless defined $folder && length $folder;
	my $dir = &folders_trash_root();
	$folder =~ s{/+$}{} unless $folder eq '/';
	return ($folder eq $dir || $folder eq $dir . '/files' || $folder eq $dir . '/info') ? 1 : 0;
}

sub folders_move_path($from, $to) {
	return 0 unless defined $from && length $from && -e $from;
	return 1 if rename($from, $to);
	if (!-d $from) {
		return File::Copy::move($from, $to) ? 1 : 0;
	}
	File::Path::make_path($to) unless -d $to;
	opendir(my $dh, $from) or return 0;
	my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
	closedir $dh;
	foreach my $name ( @names ) {
		return 0 unless &folders_move_path($from . '/' . $name, $to . '/' . $name);
	}
	rmdir $from;
	return 1;
}

sub folders_trash_move($path) {
	return 'no path' unless (defined $path && length $path);
	return $path . ': it is not there' unless -e $path;
	my $files = &folders_trash_files_dir();
	my $info = &folders_trash_info_dir();
	my @parts = split '/', $path;
	my $name = pop @parts;
	$name = 'item' unless (defined $name && length $name);
	my $base = $name;
	my $n = 1;
	while (-e $files . '/' . $name || -e $info . '/' . $name . '.trashinfo') {
		$name = $base . '.' . $n++;
	}
	my $dest = $files . '/' . $name;
	return $path . ': it could not be moved to the Recycle Bin' unless &folders_move_path($path, $dest);
	my $when = POSIX::strftime('%Y-%m-%dT%H:%M:%S', localtime());
	my $encoded = uri_encode($path);
	write_file($info . '/' . $name . '.trashinfo', "[Trash Info]\nPath=" . $encoded . "\nDeletionDate=" . $when . "\n");
	return undef;
}

sub folders_trash_original($name) {
	return '' unless (defined $name && length $name && $name !~ m{/});
	my $file = &folders_trash_info_dir() . '/' . $name . '.trashinfo';
	return '' unless -e $file;
	my $raw = eval { read_file($file) } || '';
	return '' unless $raw =~ /^Path=(.*)$/m;
	my $path = $1;
	$path =~ s/\r$//;
	$path = uri_decode($path);
	return $path;
}

sub folders_trash_restore($name) {
	return { ok => 0, error => 'That is not a bin entry.' } unless (defined $name && length $name && $name !~ m{/} && $name ne '.' && $name ne '..');
	my $src = &folders_trash_files_dir() . '/' . $name;
	return { ok => 0, error => 'That item is no longer in the bin.' } unless -e $src;
	my $original = &folders_trash_original($name);
	return { ok => 0, error => 'The bin does not remember where that came from.' } unless length $original && $original =~ m{^/};
	my @parts = split '/', $original;
	my $base = pop @parts;
	my $parent = join('/', @parts) || '/';
	File::Path::make_path($parent) unless -d $parent;
	return { ok => 0, error => 'The folder it came from is not there.' } unless -d $parent;
	my $dest = $parent . '/' . $base;
	if (-e $dest) {
		$dest = $dest . '.restored';
		my $n = 1;
		while (-e $dest) { $dest = $parent . '/' . $base . '.restored.' . $n++; }
	}
	return { ok => 0, error => 'It could not be put back.' } unless &folders_move_path($src, $dest);
	unlink &folders_trash_info_dir() . '/' . $name . '.trashinfo';
	return { ok => 1, path => $dest, name => $name };
}

sub folders_trash_empty {
	my $files = &folders_trash_files_dir();
	my $info = &folders_trash_info_dir();
	my $count = 0;
	foreach my $name ( &folders_entry_names($files) ) {
		my $error = &subs::folders_job_take_away($files . '/' . $name);
		$count++ unless $error;
	}
	foreach my $entry ( &folders_entry_names($info) ) {
		unlink $info . '/' . $entry if $entry =~ /\.trashinfo$/;
	}
	return $count;
}

sub folders_trash_count {
	my @names = &folders_entry_names(&folders_trash_files_dir());
	return scalar @names;
}

sub folders_delete_away {
	my ($command, $items) = @_;
	my @errors;
	my $bin = &folders_trash_files_dir();
	foreach my $item ( @{$items} ) {
		my $path = $item->{'path'};
		# An item already in the bin has nowhere left to be moved to, so a delete
		# there (the keyboard's Delete, since the menu hides it) is permanent.
		my @leaf = split '/', ($path || '');
		my $leaf = pop @leaf;
		my $in_bin = (join('/', @leaf) eq $bin);
		my $shred = ($command eq 'shred' || ($command eq 'delete' && $in_bin)) ? 1 : 0;
		foreach my $attached ( @{ &subs::folders_appt_entries($path) } ) {
			&delete_file($attached);
		}
		&subs::folders_entry_trim($path);
		&folders_delete_backups($path);
		next unless -e $path;
		my $error = $shred ? &subs::folders_job_shred($path) : &folders_trash_move($path);
		# taking a bin entry away also takes its note, or the bin keeps an entry
		# it can no longer restore
		if (!$error && $shred && $in_bin) { unlink &folders_trash_info_dir() . '/' . $leaf . '.trashinfo'; }
		push @errors, $error if $error;
	}
	return \@errors;
}

sub folders_delete_backups {
	my $path = shift;
	return 0 unless (defined $path && length $path);
	my @names = (-d $path) ? &subs::folders_job_files([ { path => $path } ]) : ( $path );
	my %wanted = map { $_ => 1 } @names;
	my $backups = &subs::db_query('select uuid, server_time, enc_file from backups where enc_file is not null and enc_file != ?', '')->hashes;
	my $pruned = 0;
	foreach my $backup ( @{$backups} ) {
		next unless $wanted{ $backup->{'enc_file'} };
		&deletion_registration({ table => 'backups', uuid => $backup->{'uuid'}, scope => 'single', server_time => $backup->{'server_time'} });
		&subs::db_delete('backups', { uuid => $backup->{'uuid'} });
		$pruned++;
	}
	return $pruned;
}

sub archive_peer_allowed {
	my $c = shift;
	my $until = $c->session('app_until') || 0;
	return 1 if (($c->session('authentication') || '') eq 'approved' && $until > &subs::rightNow());
	return &app_peer_ok($c) ? 1 : 0;
}

sub file_type_recognizer($f) {

	# One extension table for every media caller. The old inline test missed
	# .jpeg/.webp/.heic/.tif and was case-sensitive, so a phone capture could get
	# no type at all and the details view skipped it.
	my %kind = (
		img => 'image', snd => 'audio', vid => 'video',
		pdf => 'pdf', doc => 'document',
	);
	my $file_type = $kind{ &subs::media_file_type($f) || '' };
	$file_type = 'subtitles' if $f =~ /vtt|srt/i;
	my $file = {
		type => $file_type,
		icon => '/images/decipherable/file.png'
	};
	if ( -d $f) {
		$file->{'type'} = 'folder';
		$file->{'icon'} = '/images/decipherable/folder.png';
	}
	elsif ($f =~ /\.enc$/i) {
		# a sealed file wears the extension of what it holds - sealing keeps
		# it so opening can hand the file back as itself - so a picture inside
		# can still show itself and open in the images app, which reads it
		# through /file_open like any other picture; anything else says only
		# that it is sealed
		if ($file_type && $file_type eq 'image') {
			$file->{'icon'} = '/file_open?file=' . uri_encode $f;
		}
		else {
			$file->{'type'} = 'encrypted';
			$file->{'icon'} = '/images/make believe/lock.png';
		}
	}
	elsif ($file_type eq 'image' || $file_type eq 'video') {
		$file->{'icon'} = '/file_open?file=' . uri_encode $f;
	}
	elsif ($file_type eq 'subtitles') {
		$file->{'icon'} = '/images/decipherable/list.png';
	}
	elsif ($file_type eq 'audio') {
		$file->{'icon'} = '/images/make believe/music.png';
	}
	return $file;
}

sub ide_opener($data) {
	my $timestamp = $data->{'timestamp'};
	my $c = &subs::controller_builder();
	my $settings = &subs::settings_grabber({ app => 'ide' });
	my $search = $data->{'search'};
	my $folder = $data->{'folder'};
	my $root = &subs::home($folder) || &subs::home($settings->{'folder_selector'}) || './';
	# Opening the editor lists only the root's own children; a folder's children
	# arrive from /manager/ide/folder_open when it unfolds. A search still has to
	# read the whole tree - that is what the person asked for - so it keeps the
	# full walk.
	my $files = $search ? &subs::ide_files($root) : &subs::ide_folder_listing($root);

	if ($search) {
		my $searched_files;
		foreach my $f ( @{$files} ) {
			my $fi = $folder . $f->{'file'};
			if ($folder ne './') { $fi = $f->{'file'}; }


			my $contents;
			if (-e $fi) {
				$contents = read_file($fi);
			}
			if ($contents =~ /\Q$search/gi || $fi =~ /\Q$search/gi ) {
				push @{$searched_files}, $f, unless grep { $_->{'file'} eq $f->{'file'} } @{$searched_files};
			}
			$files = $searched_files;
		}

	}


	my $open_tabs = eval { return decode_json $settings->{'open_tabs'} } || {};
	my $tabs = {};
	foreach my $f ( keys %{$open_tabs} ) {
		if ($open_tabs->{$f}->{'status'} eq 'open') {
			my ($tab,$content,$file) = &ide_file_open($f,'load');
			$tabs->{$f} = { tab => $tab, content => $content, file => $file};

		}
	}
	# the folders the person had unfolded, so the tree comes back the way they
	# left it; the client unfolds them from these paths, one level at a time
	my @open_folders = eval { @{ decode_json( $settings->{'open_folders'} || '[]' ) } };
	my $open_folders_json = encode_json(\@open_folders);
	# where the file list and each open file were scrolled to
	my $list_scroll = eval { decode_json( $settings->{'list_scroll'} || '{}' ) } || {};
	$list_scroll = {} unless ref $list_scroll eq 'HASH';
	my $editor_scroll = eval { decode_json( $settings->{'editor_scroll'} || '{}' ) } || {};
	$editor_scroll = {} unless ref $editor_scroll eq 'HASH';
	# which pane was showing: the file list or the editor
	my $view = ($settings->{'view'} && $settings->{'view'} eq 'editor') ? 'editor' : 'list';
	my $bgc = &subs::setting_grabber({ app => 'misc', setting => 'ide_sidebar_container_background_colour', device => $device });
	my $contents = $c->render_to_string(
		files => $files,
		template => 'ide',
		tabs => $tabs,
		window_maker => $c->param('window_maker'),
		background_colour => $bgc,
		misc_settings => &misc_setting_list(),
		device => $device,
		settings => $settings,
		search => $search,
		open_folders_json => $open_folders_json,
		list_scroll_json => encode_json($list_scroll),
		editor_scroll_json => encode_json($editor_scroll),
		view_json => encode_json($view)
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'ide', contents => $contents }, $timestamp);
	return { html => $website, tabs => $tabs, settings => $settings, open_folders => \@open_folders };
}

sub ide_file_open($file,$source) {
	my $content = `cat $file`;
	my @file_name = split '/', $file;
	my $status = '';
	if ($source eq 'open') {
		$status = 'active';
	}
	my $tab = '<span class="ide_tab ' . $status . ' hover" file="' . $file . '">' . $file_name[-1] . '<button class="ide_close_tab hover" file="' . $file . '">X</button></span>';
	return ($tab,$content,$file);
}

sub email_folder_is_builtin {
	my ($folder) = @_;
	return $folder =~ /^(inbox|starred|drafts|sent|outbox|archive|trash|contacts)$/ ? 1 : 0;
}

sub email_folder_rows {
	my ($folder) = @_;
	return [] unless defined $folder && length $folder;
	my %sql = (
		outbox  => "select * from mailbox where status = 'outbox'",
		drafts  => "select * from mailbox where status = 'draft'",
		inbox   => "select * from mailbox where status = 'inbox' and email is not null",
		sent    => "select * from mailbox where status = 'sent' and email is not null",
		archive => "select * from mailbox where status = 'archive'",
		trash   => "select * from mailbox where status = 'trash'",
		starred => "select * from mailbox where starred = 'yes' and status != 'trash'",
	);
	return &subs::db_query($sql{$folder})->hashes if $sql{$folder};
	return &subs::db_query('select * from mailbox where status = ?', $folder)->hashes;
}

sub email_extra_folders {
	my $raw = &subs::setting_grabber({ app => 'mail', setting => 'email_folders' });
	my $list = eval { &decode_json($raw) } || [];
	return [ grep { defined $_ && length $_ && !&email_folder_is_builtin($_) } @{$list} ];
}

sub email_sort {
	my $raw = &subs::setting_grabber({ app => 'mail', setting => 'email_sort' });
	my $s = eval { &decode_json($raw) } || {};
	my %by = map { $_ => 1 } qw/date sender subject/;
	my $choice = { by => ($by{$s->{'by'} || ''} ? $s->{'by'} : 'date'), dir => (($s->{'dir'} || '') eq 'asc' ? 'asc' : 'desc') };
	return $choice;
}

sub email_sort_threads {
	my ($threads, $suds, $sort) = @_;
	my $by = $sort->{'by'} || 'date';
	if ($by eq 'subject') {
		foreach my $t ( @{$threads} ) {
			$t->{'subject'} = &subs::note_decrypter($suds, $t->{'last'}->{'subject'} || '') unless defined $t->{'subject'};
		}
	}
	if ($by eq 'sender') {
		return [ sort { lc($a->{'last'}->{'email'} || '') cmp lc($b->{'last'}->{'email'} || '') || ($a->{'last'}->{'timestamp'} || 0) <=> ($b->{'last'}->{'timestamp'} || 0) } @{$threads} ];
	}
	if ($by eq 'subject') {
		return [ sort { lc($a->{'subject'} || '') cmp lc($b->{'subject'} || '') || ($a->{'last'}->{'timestamp'} || 0) <=> ($b->{'last'}->{'timestamp'} || 0) } @{$threads} ];
	}
	return [ sort { ($a->{'last'}->{'timestamp'} || 0) <=> ($b->{'last'}->{'timestamp'} || 0) } @{$threads} ];
}

sub email_snippet {
	my ($suds, $body) = @_;
	my $text = &subs::note_decrypter($suds, $body || '');
	return '' unless defined $text && length $text;
	$text =~ s/<[^>]*>/ /g;
	$text =~ s/&nbsp;/ /g;
	$text =~ s/&amp;/&/g;
	$text =~ s/&lt;/</g;
	$text =~ s/&gt;/>/g;
	$text =~ s/&quot;/"/g;
	$text =~ s/&#39;/'/g;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return substr($text, 0, 180);
}

sub email_threads {
	my ($emails) = @_;
	my (%threads, @order);
	foreach my $m ( @{$emails} ) {
		my $key = $m->{'thread'};
		$key = 'solo:' . $m->{'uuid'} unless defined $key && length $key;
		unless ($threads{$key}) { $threads{$key} = { key => $key, rows => [] }; push @order, $threads{$key}; }
		push @{ $threads{$key}->{'rows'} }, $m;
	}
	foreach my $t ( @order ) {
		$t->{'rows'} = [ sort { ($a->{'timestamp'} || 0) <=> ($b->{'timestamp'} || 0) } @{ $t->{'rows'} } ];
		$t->{'last'} = $t->{'rows'}->[-1];
	}
	return [ sort { ($b->{'last'}->{'timestamp'} || 0) <=> ($a->{'last'}->{'timestamp'} || 0) } @order ];
}

sub email_thread_annotate {
	my ($threads, $suds) = @_;
	foreach my $t ( @{$threads} ) {
		my $last = $t->{'last'};
		$t->{'party'} = $last->{'email'};
		$t->{'subject'} = &subs::note_decrypter($suds, $last->{'subject'} || '');
		$t->{'count'} = scalar @{ $t->{'rows'} };
		$t->{'unread'} = scalar grep { ($_->{'seen'} || '') ne 'yes' && ($_->{'status'} || '') eq 'inbox' } @{ $t->{'rows'} };
		$t->{'starred'} = scalar grep { ($_->{'starred'} || '') eq 'yes' } @{ $t->{'rows'} };
		$t->{'snippet'} = &email_snippet($suds, $last->{'body'} || '');
	}
	return $threads;
}

sub email_folder_counts {
	my %counts = (
		inbox   => scalar @{ &subs::db_query("select uuid from mailbox where status = 'inbox' and email is not null and (seen is null or seen != 'yes')")->hashes },
		starred => scalar @{ &subs::db_query("select uuid from mailbox where starred = 'yes' and status = 'inbox' and (seen is null or seen != 'yes')")->hashes },
		drafts  => scalar @{ &subs::db_query("select uuid from mailbox where status = 'draft'")->hashes },
		trash   => scalar @{ &subs::db_query("select uuid from mailbox where status = 'trash'")->hashes },
	);
	# a folder the person made wears its unread count, like the inbox
	foreach my $f ( @{ &email_extra_folders() } ) {
		$counts{$f} = scalar @{ &subs::db_query('select uuid from mailbox where status = ? and (seen is null or seen != ?)', $f, 'yes')->hashes };
	}
	return \%counts;
}

sub mail_scope_sections($scope) {
	return () unless $scope;
	my %groups = (
		email => [qw/email/],
		chat  => [qw/sms dial list tickets rooms lora/],
		pen   => [qw/pen/],
	);
	return @{ $groups{$scope} || [$scope] };
}

sub mail_text_chars {
	my ($text) = @_;
	utf8::decode($text) if defined $text && length $text;
	return $text;
}

1;
