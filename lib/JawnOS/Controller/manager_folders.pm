package Manager;

# manager_folders: route actions moved out of Manager.pl, one sub per route so a
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

# POST /manager/folders
sub action_29094 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	# a machine picked in the toolbar: the listing has to come from that machine,
	# which is also the only machine that can stat its own paths
	if ($c->param('remote_uuid') && $c->param('remoted') ne 'yes') {
		my $result = &Manager::remote_relay_request($c);
		if (length $result) {
			# the relay hands the reply back as a plain string and the browser
			# parses it as JSON, so put the content type back
			$c->res->headers->content_type('application/json');
			$c->render(text => $result);
			return;
		}
	}
	my $folder = $c->param('folder') || &subs::home('~');
	my $command = $c->param('command');
	# One id per window and one per tab. The id is what keeps two Folders
	# windows apart while windowMaker answers a refresh; the tab id is what the
	# window's own tab strip selects between.
	my $folders_id = $c->param('window_id') // '';
	$folders_id =~ s/[^A-Za-z0-9_\-]//g;
	$folders_id = substr($folders_id, 0, 64);
	$folders_id = 'f' . &subs::random_string_creator(12) if length($folders_id) < 4;
	my $tab_id = $c->param('tab_id') // '';
	$tab_id =~ s/[^A-Za-z0-9_\-]//g;
	$tab_id = substr($tab_id, 0, 64);
	$tab_id = 't' . &subs::random_string_creator(12) if length($tab_id) < 4;
	my $settings = &subs::settings_grabber({ app => 'folders' });
	# an app opens locked: only the token this window holds, minted by the
	# phone's unlock, may list a sealed name
	my $unlocked = media_unlock_open($c, 'folders') ? 1 : 0;
	my $unlock = $unlocked ? $c->param('unlock') : '';

	my $show_hidden = $c->param('show_hidden') ? 1 : 0;
	my $fo = &folders_opener({ folder => $folder, command => $command, c => $c, unlocked => $unlocked, show_hidden => $show_hidden });
	# the bar names the folder being read, not its whole path, in the same words
	# the address bar uses; every command still works on the real path
	my $named_folder = $fo->{'display_name'} || '';
	my $window_name = &subs::ui('Folders') . (length $named_folder ? ' - ' . $named_folder : '');
	my $remote_uuid = $c->param('remote_uuid') || '';
	my $machines = &subs::remote_machine_lister({ self => 'no' });
	# A remote listing is rendered by the machine being read, where that machine
	# is "self" and so absent from its peer list. Keep an option for it: the
	# toolbar must always name the machine whose files are on screen.
	if ($remote_uuid && !grep { ($_->{'uuid'} || '') eq $remote_uuid } @{$machines}) {
		my $rm = &subs::db_select('remote_machines', undef, { uuid => $remote_uuid })->hashes->[0] || {};
		my $label = $rm->{'hostname'} || $rm->{'fqdn'} || $rm->{'ip'} || '';
		unless (length $label) {
			# a relayed rendering: this uuid is the source's name for us
			if (($c->param('remoted') || '') eq 'yes') {
				$label = `hostname`;
				chomp $label;
			}
		}
		$label = $remote_uuid unless length $label;
		push @{$machines}, { uuid => $remote_uuid, hostname => $label };
	}
	my $contents = $c->render_to_string(
		template => 'folders/folders',
		settings => $settings,
		fo => $fo,
		folder => $folder,
		folders_id => $folders_id,
		tab_id => $tab_id,
		unlocked => $unlocked,
		unlock => $unlock,
		machines => $machines,
		remote_uuid => $remote_uuid
	);

	my $html = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'folders', window_id => $folders_id, window_name => $window_name, contents => $contents }, $timestamp);
	$c->render(json => { html => $html, fo => $fo, window_id => $folders_id, tab_id => $tab_id, window_name => $window_name, unlocked => $unlocked });
}

# The desk behind the manager: the same Folders listing drawn as icons on the
# desktop background, plus any app shortcuts pinned there. The padlock is the
# Folders window's own token, so a sealed name appears here only while this
# screen has Folders open.
# GET /manager/folders/desk
sub action_29220 {
	my $c = shift;
	my $folder = &folders_desk_folder();
	my $unlocked = media_unlock_open($c, 'folders') ? 1 : 0;
	my $show_hidden = $c->param('show_hidden') ? 1 : 0;
	my $listing = &folders_listing($folder, $unlocked, $c, $show_hidden);
	my @apps = map {
		{
			app => $_,
			name => &subs::format_name($_),
			icon => &subs::icon_for($gb::known_appts->{$_}->{'icon'})
		}
	} &folders_desk_pinned();
	my $trash = &folders_trash_files_dir();
	my $trash_count = &folders_trash_count();
	$c->render(json => {
		folder => $folder,
		files => $listing->{'files'},
		apps => \@apps,
		disk => $listing->{'disk'},
		# the two fixed places: Computer opens the root, the bin its own folder
		computer => {
			name => &subs::ui('Computer'),
			icon => &subs::icon_for('/images/decipherable/computer.png'),
			path => '/'
		},
		trash => {
			name => &subs::ui('Recycle Bin'),
			icon => &subs::icon_for('/icons/trash.png'),
			path => $trash,
			count => $trash_count
		},
		trash_folder => $trash,
		trash_count => $trash_count,
		unlocked => $unlocked
	});
}

# The app picker the desk's background menu opens.
# GET /manager/folders/desk/apps
sub action_29258 {
	my $c = shift;
	my %pinned = map { $_ => 1 } &folders_desk_pinned();
	my $content = $c->render_to_string(
		template => 'folders/app_picker',
		apps => &folders_pinable_apps(),
		pinned => \%pinned
	);
	my $uuid = &subs::random_string_creator(12);
	my $dialog = $c->render_to_string(
		template => 'folders/dialog_box',
		folders => { folder => &folders_desk_folder() },
		box => {
			name => &subs::ui('Pin apps to the desk'),
			command => 'pin_app',
			content => $content,
			height => '70%',
			width => 'min(680px, 94vw)',
			ok_label => &subs::ui('Pin'),
			cancel_label => &subs::ui('Cancel')
		},
		uuid => $uuid
	);
	$c->render(json => { dialog => $dialog });
}

# Save the pinned list. Only known, launchable apps are kept; the list is capped
# so the desk never turns into an app drawer.
# POST /manager/folders/desk/apps
sub action_29285 {
	my $c = shift;
	my $apps = eval { decode_json $c->param('apps') } || [];
	my %seen;
	my @clean;
	foreach my $app ( @{$apps} ) {
		next unless defined $app && $app =~ /^[a-z0-9_]+$/;
		next unless $gb::known_appts->{$app} && !$folders_desk_not_app{$app};
		push @clean, $app unless $seen{$app}++;
	}
	@clean = @clean[0 .. 19] if scalar @clean > 20;
	&subs::setting_setter({ app => 'folders', setting => 'desktop_apps', value => encode_json(\@clean) });
	$c->render(json => { ok => 1, apps => \@clean });
}

# Choose the folder the desk shows. An empty path returns to the automatic
# choice (~/Desktop when it has something in it, else home).
# POST /manager/folders/desk/folder
sub action_29301 {
	my $c = shift;
	my $folder = $c->param('folder');
	if (!defined $folder || !length $folder) {
		&subs::setting_deleter({ app => 'folders', setting => 'desktop_folder' });
		$c->render(json => { ok => 1, folder => &folders_desk_folder() });
		return;
	}
	$folder = &subs::home($folder);
	$folder =~ s{/+$}{} unless $folder eq '/';
	unless (-d $folder) {
		$c->render(json => { ok => 0, error => &subs::ui('That folder is not there.') });
		return;
	}
	&subs::setting_setter({ app => 'folders', setting => 'desktop_folder', value => $folder });
	$c->render(json => { ok => 1, folder => $folder });
}

# POST /manager/folders/context
sub action_29880 {
	my $c = shift;
	my $file = $c->param('file');
	my $folders = eval { return decode_json $c->param('folders') } || {};
	my $context = $c->param('context');
	my $returner = {
		call_uuid => &subs::random_string_creator(21),
		folders => $folders
	};

	$returner->{'html'} = $c->render_to_string(
		template => 'folders/context',
		folders => $folders,
		uuid => $returner->{'call_uuid'},
		context => $context
	);
	$c->render(json => $returner);
}

# GET /manager/folders/context/command
sub action_29898 {
	my $c = shift;
	my $command = $c->param('command');
	my $folders = eval { return decode_json $c->param('folders') } || {};
	my $folder = $c->param('folder');
	my $context = $c->param('context');
	my $uuid = &subs::random_string_creator(255);
	my $returner = {};
	my $box;
	my @items = &folders_command_items($folders);
	my @names = map { &subs::format_name( (split '/', $_->{'path'})[-1] ) } @items;

	if ($command eq 'new_file') {
		$box = {
			name => 'New File',
			inputs => [{
				placeholder => 'Filename',
				name => 'filename'
			}]
		};
	}
	elsif ($command eq 'new_folder') {
		$box = {
			name => 'New Folder',
			inputs => [{
				placeholder => 'Folder Name',
				name => 'foldername'
			}]
		};
	}
	elsif ($command eq 'rename') {
		my @parts = split '/', ($folders->{'path'} || '');
		my $name = pop @parts;
		$box = {
			name => 'Rename ' . (&subs::format_name($name) || ''),
			inputs => [{
				placeholder => 'Filename',
				name => 'filename',
				value => $name
			}]
		};
	}
	elsif ($command eq 'archive') {
		$box = {
			name => 'Archive'
		};
	}
	elsif ($command eq 'delete' || $command eq 'shred') {
		my $in_bin = &folders_in_trash($folders->{'folder'});
		my $text;
		if ($command eq 'delete') {
			$text = $in_bin
				? &subs::ui('Delete') . ' ' . scalar(@items) . ' ' . &subs::ui('item(s)? They are taken out of the Recycle Bin for good.') . "\n\n"
				: &subs::ui('Delete') . ' ' . scalar(@items) . ' ' . &subs::ui('item(s)? They go to the Recycle Bin. A folder goes with everything in it.') . "\n\n";
		}
		else {
			$text = &subs::ui('Shred') . ' ' . scalar(@items) . ' ' . &subs::ui('item(s)? Nothing shredded can be read again.') . "\n\n";
		}
		$box = {
			name => &subs::format_name($command),
			text => $text . join("\n", @names),
			height => '320px'
		};
	}
	elsif ($command eq 'empty_trash') {
		my $count = &folders_trash_count();
		$box = {
			name => &subs::ui('Empty Recycle Bin'),
			text => $count . ' ' . &subs::ui('item(s) will be permanently deleted. This cannot be undone.'),
			height => '260px'
		};
	}
	elsif ($command eq 'encrypt' || $command eq 'decrypt') {
		my $text = ($command eq 'encrypt')
			? 'Seal ' . scalar(@items) . " item(s) with the suds? Every file gets a name of its own and the plaintext is shredded behind it.\n\n"
			: 'Open ' . scalar(@items) . " sealed item(s) with the suds? The seal is shredded once the file is out.\n\n";
		$box = {
			name => &subs::format_name($command),
			text => $text . join("\n", @names),
			height => '320px'
		};
	}
	elsif ($command eq 'paste') {

	}
	elsif ($command eq 'properties') {
		# the background menu asks about the folder being looked at, which is
		# not a selection of anything
		@items = ( { path => $folders->{'folder'} } ) if (!scalar @items && $folders->{'folder'} && length $folders->{'folder'});
		my $total_size = 0;
		my @files;
		foreach my $item ( @items ) {
			my @parts = split '/', $item->{'path'};
			my $name = pop @parts;
			my $file = &folders_property_grabber({ file => $name, folder => join('/', @parts) });
			$file->{'parent'} = join('/', @parts) || '/';
			$total_size += $file->{'size'} unless (($file->{'type'} || '') eq 'folder');
			# a folder's own inode is not what the person wants to know; the
			# number of things inside it is
			$file->{'children'} = scalar &folders_entry_names($file->{'path'}) if (($file->{'type'} || '') eq 'folder');
			push @files, $file;
		}
		my $text = $c->render_to_string(
			template => 'folders/properties',
			total_size => $total_size,
			files => \@files,
			folders => $folders
		);


		$box = {
			ok => 'no',
			cancel => 'yes',
			cancel_label => &subs::ui('Close'),
			height => '70%',
			width => 'min(660px, 94vw)',
			name => &subs::ui('Properties'),
			content => $text
		};
	}
	if ($box) {
		$box->{'command'} = $command;
		my $dialog = $c->render_to_string(
			template => 'folders/dialog_box',
			folders => $folders,
			box => $box,
			uuid => $uuid
		);
		$returner->{'dialog'} = $dialog;
	}
	$c->render(json => $returner);
}

# What the OK of a folders dialog does. The things that only touch the folder
# being looked at happen here; anything that walks a disk - a paste, a seal, an
# opening - is queued for the worker, and the answer is a dialog the app keeps
# asking after until the job is done with.
# POST /manager/folders/context/command
sub action_30034 {
	my $c = shift;
	my $command = $c->param('command');
	my $inputs = eval { return decode_json $c->param('inputs') } || {};
	my $folders = eval { return decode_json $c->param('folders') } || {};
	my $folder = $folders->{'folder'};
	my $returner = {};
	my $answer = sub {
		my $box = shift;
		$returner->{'dialog'} = $c->render_to_string(
			template => 'folders/dialog_box',
			folders => $folders,
			box => $box,
			uuid => &subs::random_string_creator(10)
		);
		return;
	};

	if ($command eq 'new_file' || $command eq 'new_folder') {
		my $is_folder = ($command eq 'new_folder') ? 1 : 0;
		my $name = &folders_name_cleaner($inputs->{ $is_folder ? 'foldername' : 'filename' });
		my $name_of = $is_folder ? 'New Folder' : 'New File';
		if (!defined $name || !defined $folder || !length $folder) {
			$answer->({ name => $name_of, text => 'That is not a name a file can have.', cancel => 'no' });
		}
		elsif (-e $folder . '/' . $name) {
			$answer->({ name => $name_of, text => &subs::format_name($name) . ' is already there.', cancel => 'no' });
		}
		else {
			if ($is_folder) { Mojo::File->new($folder . '/' . $name)->make_path; }
			else { open my $fh, '>', $folder . '/' . $name; close $fh; }
			$returner->{'status'} = 'ok';
		}
	}
	elsif ($command eq 'rename') {
		my $path = $folders->{'path'};
		my $name = &folders_name_cleaner($inputs->{'filename'});
		my @parts = split '/', ($path || '');
		my $was = pop @parts;
		my $into = join '/', @parts;
		if (!defined $name || !defined $path || !length $path) {
			$answer->({ name => 'Rename', text => 'That is not a name a file can have.', cancel => 'no' });
		}
		elsif ($name eq $was) {
			$returner->{'status'} = 'ok';
		}
		elsif (-e $into . '/' . $name) {
			$answer->({ name => 'Rename', text => &subs::format_name($name) . ' is already there.', cancel => 'no' });
		}
		elsif (rename($path, $into . '/' . $name)) {
			$returner->{'status'} = 'ok';
		}
		else {
			$answer->({ name => 'Rename', text => &subs::format_name($was) . ' could not be renamed.', cancel => 'no' });
		}
	}
	elsif ($command eq 'delete' || $command eq 'shred') {
		my @errors = @{ &folders_delete_away($command, [ &folders_command_items($folders) ]) };
		if (scalar @errors) {
			$answer->({ name => &subs::format_name($command), text => join("\n", @errors), cancel => 'no' });
			$returner->{'status'} = 'error';
			$returner->{'error'} = join '; ', @errors;
		}
		else {
			$returner->{'status'} = 'ok';
		}
	}
	elsif ($command eq 'restore_trash') {
		my @items = &folders_command_items($folders);
		my @errors;
		foreach my $item ( @items ) {
			my @parts = split '/', ($item->{'path'} || '');
			my $name = pop @parts;
			my $restored = &folders_trash_restore($name);
			push @errors, $restored->{'error'} unless $restored->{'ok'};
		}
		if (scalar @errors) {
			$answer->({ name => &subs::ui('Restore'), text => join("\n", @errors), cancel => 'no' });
			$returner->{'status'} = 'error';
			$returner->{'error'} = join '; ', @errors;
		}
		else { $returner->{'status'} = 'ok'; }
	}
	elsif ($command eq 'empty_trash') {
		my $emptied = &folders_trash_empty();
		$returner->{'status'} = 'ok';
		$returner->{'emptied'} = $emptied;
	}
	elsif ($command eq 'paste') {
		my @items = @{$folders->{'clipboard'} || []};
		my $move = (($folders->{'command'} || '') eq 'cut') ? 1 : 0;
		if (!scalar @items) {
			$answer->({ name => 'Paste', text => 'The clipboard is empty.', cancel => 'no' });
		}
		elsif (!defined $folder || !length $folder || !-d $folder) {
			$answer->({ name => 'Paste', text => 'The folder to paste into is not there.', cancel => 'no' });
		}
		else {
			my $id = &subs::minion_grabber()->enqueue(folders_copy => [ { items => \@items, to => $folder, move => $move } ] => { retries => 1 });
			$answer->({
				name => $move ? 'Moving' : 'Copying',
				text => scalar(@items) . ' item(s) into ' . $folder,
				job => $id,
				progress => 'starting',
				ok => 'no',
				cancel => 'no',
				height => '220px'
			});
			$returner->{'status'} = 'ok';
		}
	}
	elsif ($command eq 'encrypt' || $command eq 'decrypt') {
		my @items = &folders_command_items($folders);
		my $suds = eval { &subs::suds_grabber() };
		if (!scalar @items) {
			$answer->({ name => &subs::format_name($command), text => 'Nothing is selected.', cancel => 'no' });
		}
		elsif (!defined $suds || !length $suds) {
			$answer->({ name => &subs::format_name($command), text => 'There is no suds on duty to use.', cancel => 'no' });
		}
		else {
			my $task = ($command eq 'encrypt') ? 'folders_encrypt' : 'folders_decrypt';
			my $id = &subs::minion_grabber()->enqueue($task => [ { items => \@items, suds => $suds } ] => { retries => 1 });
			$answer->({
				name => ($command eq 'encrypt') ? 'Encrypting' : 'Decrypting',
				text => scalar(@items) . ' item(s)',
				job => $id,
				progress => 'starting',
				ok => 'no',
				cancel => 'no',
				height => '220px'
			});
			$returner->{'status'} = 'ok';
		}
	}
	$c->render(json => $returner);
}

# How a job the folders app queued is getting on: the note the worker last
# wrote on it and where it ended, which is what the dialog box that started it
# shows while it runs.
# GET /manager/folders/job
sub action_30174 {
	my $c = shift;
	my $job = &subs::minion_grabber()->job($c->param('id'));
	unless ($job) {
		$c->render(json => { status => 'error', error => 'no such job' });
		return;
	}
	my $info = $job->info || {};
	my $payload = $info->{'result'} || $info->{'error'} || {};
	$payload = {} unless ref $payload;
	my $notes = $info->{'notes'} || {};
	my $archive = $notes->{'archive'};
	# a copy or seal job has no archive note of its own; only an archive task
	# gets a fallback state, so its dialog shows a bar and the others keep
	# their own progress sentence
	if (!$archive && ($info->{'task'} || '') =~ /^archive_/) {
		my $fallback = ($info->{'state'} || '') eq 'inactive' ? 'queued'
			: ($info->{'state'} || '') eq 'active' ? 'copying'
			: $info->{'state'};
		$archive = { state => $fallback };
	}
	$c->render(json => {
		status => 'ok',
		state => $info->{'state'},
		progress => $notes->{'progress'},
		archive => $archive,
		resumable => ($archive && $archive->{'resumable'} ? 1 : 0),
		cancelled => ($payload->{'cancelled'} ? 1 : 0),
		errors => $payload->{'errors'},
		payload => $payload
	});
}

# Stop a queued job, or ask a running one to stop. A job that has not started
# is simply removed; one that is already going cannot be killed from this
# process, so it is told instead and looks for the note between files.
# POST /manager/folders/job/cancel
sub action_30195 {
	my $c = shift;
	my $job = &subs::minion_grabber()->job($c->param('id'));
	unless ($job) {
		$c->render(json => { status => 'error', error => 'no such job' });
		return;
	}
	my $state = $job->info->{'state'};
	if ($state eq 'active') {
		$job->note(cancel => 1);
		$c->render(json => { status => 'ok', state => $state, asked => 1 });
		return;
	}
	$job->remove;
	$c->render(json => { status => 'ok', state => 'removed' });
}

# Open what is selected with whatever this machine opens that kind of file
# with: the desktop's own choice, which is the one thing a file manager can
# offer that the apps cannot. A remote listing is read-only and never gets
# here, so this always opens on the machine in front of the screen.
# POST /manager/folders/open_with
sub action_30215 {
	my $c = shift;
	my $folders = eval { return decode_json $c->param('folders') } || {};
	my @paths = map { $_->{'path'} } grep { -e $_->{'path'} } &folders_command_items($folders);
	&subs::subprocessor(sub {
		# The app opens it on Android; a desktop falls back to xdg-open.
		my $opener = -x '/usr/bin/xdg-open' ? '/usr/bin/xdg-open' : undef;
		foreach my $path ( @paths ) {
			next if &subs::device_call('open.url', { path => $path });
			system($opener, $path) if $opener;
		}
	}, { name => 'folders open with' });
	$c->render(json => { status => 'ok', opened => scalar @paths });
}

# POST /manager/folders/archive
sub action_30229 {
	my $c = shift;
	my $folders = eval { return decode_json $c->param('folders') } || {};
	my $items = $folders->{'selected'} || [];
	# the background menu archives the folder being looked at, which is not a
	# selection of anything
	@{$items} = ( { path => ($folders->{'path'} || $folders->{'folder'}), type => 'folder' } ) if !scalar @{$items} && ($folders->{'path'} || $folders->{'folder'});
	my $device = &subs::device_setter();
	my $misc = &Manager::misc_setting_list();
	my $delete_after = ($folders->{'delete_after'} || $c->param('delete_after')) ? 1 : 0;
	my $plan = &subs::archive_plan({
		items => $items,
		delete_after => $delete_after,
		settings => $misc->{$device} || {},
		machines => &subs::remote_machine_lister({})
	});
	my $minion = &subs::minion_grabber();
	my @queued;
	foreach my $item ( @{$plan->{'jobs'}} ) {
		push @queued, { %{$item}, id => $minion->enqueue(archive_transfer => [ $item ] => { retries => 3 }) };
	}
	$log->info('archive: queued ' . scalar(@queued) . ' item(s), refused ' . scalar @{$plan->{'refused'}});
	# the answer the folders app shows: plain text, the dialog template escapes it
	my @refused_text = map { $_->{'path'} . ' (' . $_->{'reason'} . ')' } @{$plan->{'refused'}};
	my $text = 'Nothing to archive.';
	if (scalar @queued && scalar @refused_text) {
		$text = scalar(@queued) . ' item(s) queued for the archive; not queued: ' . join '; ', @refused_text;
	}
	elsif (scalar @queued) {
		$text = scalar(@queued) . ' item(s) queued for the archive.';
	}
	elsif (scalar @refused_text) {
		$text = 'Nothing was queued: ' . join '; ', @refused_text;
	}
	$text .= ' The originals are removed once each copy is verified.' if ($delete_after && scalar @queued);
	my $dialog = $c->render_to_string(
		template => 'folders/dialog_box',
		folders => $folders,
		box => {
			name => 'Archive',
			text => $text,
			cancel => 'no',
			height => '220px',
			# one queued item keeps its own dialog with a live bar; several
			# report together in the queue drawer
			(scalar(@queued) == 1 ? (job => $queued[0]->{'id'}, progress => 'starting') : ())
		},
		uuid => &subs::random_string_creator(10)
	);
	$c->render(json => { status => 'ok', queued => \@queued, refused => $plan->{'refused'}, dialog => $dialog });
}

# Stop a queued item, or ask a running one to stop. A job that has not started
# is simply removed; one that is already going cannot be killed from this
# process, so it is told instead and the transfer checks between files.
# POST /manager/folders/archive/cancel
sub action_30272 {
	my $c = shift;
	my $minion = &subs::minion_grabber();
	my $job = $minion->job($c->param('id'));
	unless ($job) {
		$c->render(json => { status => 'error', error => 'no such job' });
		return;
	}
	my $state = $job->info->{'state'};
	if ($state eq 'active') {
		$job->note(cancel => 1);
		$c->render(json => { status => 'ok', state => $state, asked => 1 });
		return;
	}
	$job->remove;
	$c->render(json => { status => 'ok', state => 'removed' });
}

# Put a failed or finished item back on the queue. The transfer skips whatever
# already landed, so the retry only carries what did not.
# POST /manager/folders/archive/retry
sub action_30291 {
	my $c = shift;
	my $minion = &subs::minion_grabber();
	my $job = $minion->job($c->param('id'));
	unless ($job) {
		$c->render(json => { status => 'error', error => 'no such job' });
		return;
	}
	$job->retry({ delay => 0 });
	$c->render(json => { status => 'ok', id => $c->param('id') });
}

# POST /manager/folders/archive/locate
sub action_30317 {
	my $c = shift;
	unless (&archive_peer_allowed($c)) {
		$c->render(json => { status => 'error', error => 'not allowed' });
		return;
	}
	if ($c->param('remote_uuid') && $c->param('remoted') ne 'yes') {
		my $result = &Manager::remote_relay_request($c);
		if (length $result) {
			$c->res->headers->content_type('application/json');
			$c->render(text => $result);
			return;
		}
	}
	my $root = &subs::archive_root();
	if (!$root || !-d $root) {
		$c->render(json => { status => 'error', error => 'this machine is not an archive' });
		return;
	}
	my $path = $c->param('path');
	$path =~ s{/+$}{} if defined $path;
	foreach my $location ( &subs::location_types() ) {
		my $folder = &subs::archive_location_folder($root, $location);
		next unless (defined $path && $path =~ m{^\Q$folder\E/});
		$c->render(json => {
			status => 'ok',
			location => $location,
			relative => substr($path, length($folder) + 1),
			folder => $folder,
			folder_path => (-d $path ? 1 : 0)
		});
		return;
	}
	$c->render(json => { status => 'error', error => 'not inside any archive location' });
}

1;
