package Manager;

# manager_folders2: route actions moved out of Manager.pl, one sub per route so a
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

# Bring something that lives in an archive back to this machine. The path as it
# is on the other machine is enough: that machine says which location it is and
# where it sits inside it, and this one puts it back where it came from. One
# item per request, folder or file, so a series or an album comes home whole.
# POST /manager/folders/archive/fetch
sub action_30356 {
	my $c = shift;
	my $remote_uuid = $c->param('remote_uuid');
	my $path = $c->param('path');
	unless ($remote_uuid && defined $path && length $path) {
		$c->render(json => { status => 'error', error => 'a path and the machine holding it are needed' });
		return;
	}
	my $located = &subs::archive_remote_locate({ remote_uuid => $remote_uuid, path => $path });
	if ($located->{'error'}) {
		$c->render(json => { status => 'error', error => $located->{'error' } });
		return;
	}
	my $into = &subs::archive_local_destination({ location => $located->{'location'}, relative => $located->{'relative'} });
	if ($into->{'error'}) {
		$c->render(json => { status => 'error', error => $into->{'error'} });
		return;
	}
	my $id = &subs::minion_grabber()->enqueue(archive_fetch_home => [ {
		remote_uuid => $remote_uuid,
		location => $located->{'location'},
		relative => $located->{'relative'},
		folder => $located->{'folder_path'},
		archive_path => $path
	} ] => { retries => 2 });
	$c->render(json => {
		status => 'ok',
		id => $id,
		location => $located->{'location'},
		relative => $located->{'relative'},
		to => $into->{'path'}
	});
}

# The queue as the folders app shows it: every archive job this machine holds,
# newest first, with the note the worker last wrote on it, and the locations
# this device archives so the panel can offer a rescan for one.
# GET /manager/folders/archive
sub action_30392 {
	my $c = shift;
	my $list = &subs::minion_grabber()->backend->list_jobs(0, 200, { tasks => ['archive_transfer', 'archive_manifest_rescan', 'archive_fetch_home', 'cloud_sync'] })->{'jobs'} || [];
	my @jobs;
	foreach my $job ( @{$list} ) {
		my $item = ($job->{'args'} || [])->[0] || {};
		my $result = $job->{'result'} || {};
		my $notes = $job->{'notes'} || {};
		my $archive = $notes->{'archive'};
		my $fallback = $job->{'state'} eq 'inactive' ? 'queued'
			: $job->{'state'} eq 'active' ? 'copying'
			: $job->{'state'};
		$archive ||= { state => $fallback };
		push @jobs, {
			id => $job->{'id'},
			task => $job->{'task'},
			state => $job->{'state'},
			attempts => $job->{'attempts'},
			retries => $job->{'retries'},
			created => $job->{'created'},
			finished => $job->{'finished'},
			item => $item,
			progress => $notes->{'progress'},
			archive => $archive,
			resumable => ($result->{'cancelled'} ? 0 : ($archive->{'resumable'} ? 1 : 0)),
			cancelled => ($result->{'cancelled'} ? 1 : 0),
			sent => $result->{'sent'},
			skipped => $result->{'skipped'},
			bytes => $result->{'bytes'},
			files => $result->{'files'},
			resumed => $result->{'resumed'},
			deleted => $result->{'deleted'},
			rows => $result->{'rows'},
			errors => $result->{'errors'}
		};
	}
	my $misc = &Manager::misc_setting_list();
	my $device = &subs::device_setter();
	my $machines = &subs::archive_machines();
	my @locations;
	foreach my $location ( &subs::location_types() ) {
		my $where = $misc->{$device}->{$location . '_location'};
		my $rm = &subs::archive_machine_for($location, $misc->{$device} || {}, $machines);
		next unless ($where && $rm);
		push @locations, {
			location => $location,
			where => $where,
			remote_uuid => ($rm->{'self'} ? '' : ($rm->{'uuid'} || '')),
			remote_hostname => $rm->{'hostname'} || ''
		};
	}
	$c->render(json => { status => 'ok', jobs => \@jobs, locations => \@locations });
}

# Where a finished transfer puts what it delivered: one line for the whole job,
# because the listing underneath is only rewritten when the journal piles up.
# POST /manager/folders/archive/manifest/append
sub action_30436 {
	my $c = shift;
	unless (&archive_peer_allowed($c)) {
		$c->render(json => { status => 'error', error => 'not allowed' });
		return;
	}
	my $location = $c->param('location');
	my $rows = eval { return decode_json $c->param('rows') } || [];
	my $appended = &subs::archive_manifest_append({ location => $location, rows => $rows });
	if ($appended->{'error'}) {
		$c->render(json => { status => 'error', error => $appended->{'error'} });
		return;
	}
	$log->info('archive: manifest for ' . ($location || '(nothing)') . ' +' . ($appended->{'rows'} || 0) . ' row(s)' . ($appended->{'compacted'} ? ', compacted' : ''));
	$c->render(json => { status => 'ok', rows => $appended->{'rows'} || 0, compacted => $appended->{'compacted'} ? 1 : 0 });
}

# What an archive holds for a location: relative paths, sizes, times and the
# media facts, so a library can be built from one small request instead of a
# walk over the tunnel.
# POST /manager/folders/archive/manifest
sub action_30474 {
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
	my $location = $c->param('location');
	my $dest = &subs::archive_destination({ location => $location, path => '' });
	if ($dest->{'error'}) {
		$c->render(json => { status => 'error', error => $dest->{'error'} });
		return;
	}
	my $manifest = &subs::archive_manifest_read({ dir => $dest->{'folder'} });
	$c->render(json => {
		status => 'ok',
		location => $location,
		folder => $dest->{'folder'},
		rows => $manifest->{'rows'},
		journal_lines => $manifest->{'journal_lines'}
	});
}

# Read an archive location again from the drive, as a job, because it opens
# every file it finds.
# POST /manager/folders/archive/manifest/rescan
sub action_30505 {
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
	my $location = $c->param('location');
	my $dest = &subs::archive_destination({ location => $location, path => '' });
	if ($dest->{'error'}) {
		$c->render(json => { status => 'error', error => $dest->{'error'} });
		return;
	}
	my $id = &subs::minion_grabber()->enqueue(archive_manifest_rescan => [ { location => $location } ] => { retries => 1 });
	$c->render(json => { status => 'ok', id => $id, location => $location });
}

# The archive root's per-location folders, made and checked on demand, so the
# folders app can show what an archive holds.
# GET /manager/folders/archive/dirs
sub action_30530 {
	my $c = shift;
	$c->render(json => &subs::archive_scaffolder());
}

# An archive machine answering for its own root. A sending machine asks first
# whether the item is already there, so a second pass over a folder costs one
# small request per file instead of the file itself.
# POST /manager/folders/archive/probe
sub action_30537 {
	my $c = shift;
	unless (&archive_peer_allowed($c)) {
		$c->render(json => { status => 'error', error => 'not allowed' });
		return;
	}
	my $dest = &subs::archive_destination({ location => $c->param('location'), path => $c->param('path') });
	if ($dest->{'error'}) {
		$c->render(json => { status => 'error', error => $dest->{'error'} });
		return;
	}
	my $exists = -e $dest->{'path'} ? 1 : 0;
	my @stat = $exists ? stat($dest->{'path'}) : ();
	my $partial = &subs::archive_partial_state({ path => $dest->{'path'} });
	$c->render(json => {
		status => 'ok',
		path => $dest->{'path'},
		exists => $exists,
		# so the sender can skip a file it has already delivered unchanged
		size => $exists ? -s $dest->{'path'} : undef,
		mtime => $exists ? $stat[9] : undef,
		# a partial is not a finished file; it is offered so the sender can
		# resume from it, never mistaken for the destination
		partial => $partial,
		# removing an original needs more than size and time, so the sender
		# asks for this only when the job carries delete_after
		sha256 => ($c->param('checksum') && $exists) ? &subs::archive_file_digest($dest->{'path'}) : undef
	});
}

# The upload half of archiving: the item is posted here and lands in
# <archive root>/<location>/<path>, so transfers ride the same tunnel and
# session as every other manager to manager request instead of rsync.
# POST /manager/folders/archive/receive
sub action_30562 {
	my $c = shift;
	unless (&archive_peer_allowed($c)) {
		$c->render(json => { status => 'error', error => 'not allowed' });
		return;
	}
	my @uploads = @{$c->req->uploads};
	my $upload = $uploads[0];
	unless ($upload) {
		$c->render(json => { status => 'error', error => 'no file in the request' });
		return;
	}
	my $dest = &subs::archive_destination({ location => $c->param('location'), path => $c->param('path') });
	if ($dest->{'error'}) {
		$c->render(json => { status => 'error', error => $dest->{'error'} });
		return;
	}
	Mojo::File->new($dest->{'parent'})->make_path;
	my $mtime = $c->param('mtime');
	my $offset = $c->param('offset');
	my $total = $c->param('total');
	my $source = $c->param('source');
	# The bytes land in <destination>.part with a sidecar naming the source, and
	# only the final piece renames it onto the destination. A half-written file
	# therefore never looks finished to the probe or to a delete-original check,
	# and the next attempt can continue from it instead of starting over.
	my $part = &subs::archive_partial_path($dest->{'path'});
	my $meta_path = &subs::archive_partial_meta_path($dest->{'path'});
	my $chunked = (defined $offset && $offset =~ /^\d+$/ && defined $total && $total =~ /^\d+$/) ? 1 : 0;
	my $written = 0;
	if ($chunked) {
		my $source_path = eval { $upload->asset->path };
		unless ($source_path && -e $source_path) {
			$c->render(json => { status => 'error', error => 'the upload has no file' });
			return;
		}
		my $resumed = 0;
		if ($offset > 0) {
			# resuming is only allowed onto a partial that recorded the same
			# source and the same total; the sender verified the prefix hash
			unless (-e $part) {
				$c->render(json => { status => 'error', error => 'there is no partial copy to resume', path => $dest->{'path'} });
				return;
			}
			my $have = -s $part;
			$have = 0 unless defined $have;
			if ($have < $offset) {
				$c->render(json => { status => 'error', error => 'the partial is shorter than the resume offset', path => $dest->{'path'}, size => $have });
				return;
			}
			my $meta = {};
			$meta = eval { return decode_json scalar read_file($meta_path) } || {} if ($meta_path && -e $meta_path);
			$meta = {} unless ref $meta eq 'HASH';
			if (defined $meta->{'total'} && $meta->{'total'} != $total) {
				$c->render(json => { status => 'error', error => 'the partial belongs to a different source', path => $dest->{'path'} });
				return;
			}
			if (defined $meta->{'source'} && length $meta->{'source'}
				&& defined $source && length $source && $meta->{'source'} ne $source) {
				$c->render(json => { status => 'error', error => 'the partial belongs to another source', path => $dest->{'path'} });
				return;
			}
			$resumed = 1;
		}
		my $mode = ($offset > 0) ? '+<' : '>';
		my ($in, $out);
		unless (open($out, $mode, $part)) {
			$c->render(json => { status => 'error', error => "cannot open $part: $!", path => $dest->{'path'} });
			return;
		}
		binmode $out;
		seek($out, $offset, 0) if $offset > 0;
		unless (open($in, '<:raw', $source_path)) {
			close $out;
			$c->render(json => { status => 'error', error => "cannot read the upload: $!", path => $dest->{'path'} });
			return;
		}
		binmode $in;
		my $buf;
		while (my $n = read($in, $buf, 1024 * 1024)) {
			print $out $buf;
			$written += $n;
		}
		close $in;
		close $out;
		my $asset_size = -s $source_path;
		if (defined $asset_size && $written != $asset_size) {
			$c->render(json => { status => 'error', error => "chunk wrote $written of $asset_size bytes", path => $dest->{'path'} });
			return;
		}
		if ($offset == 0) {
			&subs::archive_partial_meta_write($dest->{'path'}, {
				source => (defined $source && length $source ? $source : undef),
				total => 0 + $total,
				mtime => (defined $mtime && $mtime =~ /^\d+$/ ? 0 + $mtime : undef),
				started => &subs::rightNow()
			});
		}
		if ($c->param('final') && ($offset + $written) != $total) {
			$c->render(json => { status => 'error', error => 'the file is incomplete', path => $dest->{'path'}, size => -s $part });
			return;
		}
		my $size = -s $part;
		$size = 0 unless defined $size;
		my $sha;
		if ($c->param('final')) {
			if ($size != $total) {
				$c->render(json => { status => 'error', error => 'the file is incomplete', path => $dest->{'path'}, size => $size });
				return;
			}
			$sha = &subs::archive_file_digest($part);
			unless (defined $sha && rename($part, $dest->{'path'})) {
				$c->render(json => { status => 'error', error => 'the verified copy could not be moved into place', path => $dest->{'path'} });
				return;
			}
			unlink $meta_path if ($meta_path && -e $meta_path);
			utime $mtime, $mtime, $dest->{'path'} if ($mtime && $mtime =~ /^\d+$/);
			$log->info('archive: received ' . $dest->{'path'} . ' (' . $size . ' bytes)') if $log;
		}
		$c->render(json => {
			status => 'ok',
			path => $dest->{'path'},
			size => $size,
			offset => 0 + $offset,
			received => $written,
			resumed => $resumed,
			sha256 => $sha,
			final => $c->param('final') ? 1 : 0
		});
		return;
	}
	eval { $upload->move_to($part) };
	if ($@) {
		$c->render(json => { status => 'error', error => "$@", path => $dest->{'path'} });
		return;
	}
	$written = -s $part;
	$written = 0 unless defined $written;
	my $sha = &subs::archive_file_digest($part);
	unless (defined $sha && rename($part, $dest->{'path'})) {
		$c->render(json => { status => 'error', error => 'the verified copy could not be moved into place', path => $dest->{'path'} });
		return;
	}
	unlink $meta_path if ($meta_path && -e $meta_path);
	# keep the source's time, so the next pass over the same folder can tell an
	# unchanged file from a changed one by size and time instead of by the file
	utime $mtime, $mtime, $dest->{'path'} if ($mtime && $mtime =~ /^\d+$/);
	$log->info('archive: received ' . $dest->{'path'} . ' (' . $written . ' bytes)') if $log;
	$c->render(json => { status => 'ok', path => $dest->{'path'}, size => $written, sha256 => $sha });
}

# Throw away a partial copy, at the sender's request after a cancel. The
# original never leaves its machine; only <destination>.part and its sidecar go.
# A partial that records another source is refused rather than deleted, so a
# cancel for one job cannot remove another job's work.
# POST /manager/folders/archive/discard
sub action_30660 {
	my $c = shift;
	unless (&archive_peer_allowed($c)) {
		$c->render(json => { status => 'error', error => 'not allowed' });
		return;
	}
	my $dest = &subs::archive_destination({ location => $c->param('location'), path => $c->param('path') });
	if ($dest->{'error'}) {
		$c->render(json => { status => 'error', error => $dest->{'error'} });
		return;
	}
	my $state = &subs::archive_partial_state({ path => $dest->{'path'} });
	my $source = $c->param('source');
	if ($state->{'exists'} && defined $source && length $source
		&& defined $state->{'source'} && length $state->{'source'} && $state->{'source'} ne $source) {
		$c->render(json => { status => 'error', error => 'the partial belongs to another source', path => $dest->{'path'} });
		return;
	}
	my $removed = &subs::archive_partial_discard($dest->{'path'});
	$log->info('archive: discarded the partial copy of ' . $dest->{'path'}) if $log;
	$c->render(json => { status => 'ok', path => $dest->{'path'}, removed => $removed->{'removed'} });
}

# POST /manager/folders/file/open
sub action_30651 {
	my $c = shift;

	my $folders = eval { return decode_json $c->param('folders') } || {};
	my $type = $folders->{'type'};
	my $path = $folders->{'path'};
	my ($raw_files,$files) = [];
	my $app;
	# the same padlock this window holds for its own listing
	my $unlocked = media_unlock_open($c, 'folders') ? 1 : 0;

	if ($type eq 'image') {
		$app = 'gallery';
	} elsif ($type eq 'audio') {
		$app = 'music';
	} elsif ($type eq 'video') {
		$app = 'music';
	} elsif ($type eq 'document' || $type eq 'subtitles') {
		$app = 'ide';
	}
	# What the app is handed: the clicked file first, then its siblings of the
	# same kind from the same folder. A gallery and a player are a set, not one
	# file - opening a photo should offer the rest of the photos beside it, the
	# way a desktop viewer does; opening a track should queue the album. IDE is
	# deliberately left alone: each raw file opens its own editor tab, so handing
	# it a folder's worth would open a folder's worth of editors.
	my @chosen = grep { ($_->{'type'} || '') eq $type } @{ $folders->{'selected'} || [] };
	my $first = $folders->{'path'};
	$first = $chosen[0]->{'path'} if (!defined $first || !length $first) && scalar @chosen;
	if (defined $first && length $first) {
		my @front = grep { $_->{'path'} eq $first } @chosen;
		@chosen = ( @front, grep { $_->{'path'} ne $first } @chosen );
		@chosen = ( { path => $first, type => $type }, @chosen ) unless scalar @front;
	}
	# The folder these files came from is the album the gallery shows behind the
	# photo, so name it the way Folders names that folder.
	my $album = '';
	if (defined $first && length $first) {
		my $dir = $first;
		$dir =~ s{/[^/]*$}{};
		$dir = '/' unless length $dir;
		$album = &folders_display_name($dir);
		$album = '/' unless length $album;
	}
	if (!$folders->{'remote_uuid'} && $app && ($app eq 'gallery' || $app eq 'music') && scalar @chosen) {
		my $dir = $chosen[0]->{'path'};
		$dir =~ s{/[^/]*$}{};
		$dir = '/' unless length $dir;
		# the listing applies the same padlock and hidden-app rules the window
		# saw, so a sibling cannot be opened that the listing kept out of sight
		my $listing = &folders_listing($dir, $unlocked, $c, $folders->{'show_hidden'} ? 1 : 0);
		my %seen = map { $_->{'path'} => 1 } @chosen;
		foreach my $sibling ( @{ $listing->{'files'} || [] } ) {
			next if $seen{ $sibling->{'path'} }++;
			next unless (($sibling->{'type'} || '') eq $type);
			push @chosen, { path => $sibling->{'path'}, type => $sibling->{'type'} };
		}
	}
	foreach my $fs ( @chosen ) {
		my @stat = stat($fs->{'path'});
		my $temp = {};
		$temp->{'size'} = $stat[7];
		$temp->{'modified'} = $stat[9];
		$temp->{'created'} = $stat[10];
		$temp->{'accessed'} = $stat[8];
		push @{$raw_files}, $fs->{'path'};
		push @{$files},	{
			app => '__president',
			source => 'folders',
			f => $fs->{'path'},
			file => $fs->{'path'},
			uuid => &subs::random_string_creator(10),
			server_time => $temp->{'created'} * 1000,
			type => $fs->{'type'},
			label => $album
		};
	}
	# `target` is the file the person picked: the gallery opens it in the viewer
	# with this folder's photos behind it, so closing it lands on the album.
	my $returner = { raw_files => $raw_files, files => $files, app => $app, target => ($first // ''), album => $album };


	$c->render(json => $returner);

}

# ---- cloud sync -----------------------------------------------------------
# A folder in the house that keeps a copy on other devices. The dialog asks
# every peer how much room it has before it offers a box, so a device that
# cannot hold the folder is disabled rather than chosen and failed.
# POST /manager/folders/cloud
sub action_30700 {
	my $c = shift;
	my $folders = eval { return decode_json $c->param('folders') } || {};
	my $folder = $c->param('folder') || $folders->{'path'} || $folders->{'folder'} || '';
	if (defined $folder && length $folder) {
		$folder = &subs::home($folder);
		$folder =~ s{/+$}{} unless $folder eq '/';
	}
	my $box;
	if (!defined $folder || !length $folder || !-d $folder) {
		$box = { name => &subs::ui('CloudSync'), text => &subs::ui('That folder is not there.'), cancel => 'no', height => '220px' };
	}
	else {
		my $base = &subs::cloud_sync_base_for($folder);
		my $totals = &subs::cloud_sync_totals($folder);
		my $devices = &subs::cloud_sync_space_rows($base, $totals->{'bytes'});
		my $registered = &subs::cloud_sync_registration_for($folder);
		my %chosen = map { ($_->{'uuid'} || '') => 1 } @{ ($registered || {})->{'devices'} || [] };
		$devices = [ map {
			my $d = $_;
			my $selected = $d->{'ok'} ? ($registered ? ($chosen{ $d->{'uuid'} } ? 1 : 0) : 1) : 0;
			{ %{$d}, selected => $selected }
		} @{$devices} ];
		my $content = $c->render_to_string(
			template => 'folders/cloud_sync',
			folder => $folder,
			base => $base,
			totals => $totals,
			devices => $devices,
			registered => $registered
		);
		$box = {
			name => &subs::ui('CloudSync'),
			command => 'cloud_sync',
			content => $content,
			ok_label => &subs::ui('Start syncing'),
			height => '70%',
			width => 'min(620px, 94vw)'
		};
	}
	my $dialog = $c->render_to_string(
		template => 'folders/dialog_box',
		folders => { folder => $folder },
		box => $box,
		uuid => &subs::random_string_creator(10)
	);
	$c->render(json => { status => 'ok', dialog => $dialog });
}

# The dialog's OK: register the folder for the chosen devices and queue the
# first pass. Room is checked again here, because the dialog may have been open
# for a while and another copy could have filled the disk since.
# POST /manager/folders/cloud/start
sub action_30701 {
	my $c = shift;
	my $folder = $c->param('folder') || '';
	my $devices = eval { return decode_json $c->param('devices') } || [];
	my $returner = {};
	my $answer = sub {
		my $box = shift;
		$returner->{'dialog'} = $c->render_to_string(
			template => 'folders/dialog_box',
			folders => { folder => $folder },
			box => $box,
			uuid => &subs::random_string_creator(10)
		);
	};
	if (defined $folder && length $folder) {
		$folder = &subs::home($folder);
		$folder =~ s{/+$}{} unless $folder eq '/';
	}
	if (!defined $folder || !length $folder || !-d $folder) {
		$answer->({ name => &subs::ui('CloudSync'), text => &subs::ui('That folder is not there.'), cancel => 'no', height => '220px' });
		$c->render(json => $returner);
		return;
	}
	my $base = &subs::cloud_sync_base_for($folder);
	my $totals = &subs::cloud_sync_totals($folder);
	my $rows = &subs::cloud_sync_space_rows($base, $totals->{'bytes'});
	my %by_id = map { ($_->{'uuid'} || '') => $_ } @{$rows};
	my (@chosen, @refused);
	foreach my $uuid ( @{$devices} ) {
		next unless defined $uuid && length $uuid;
		my $row = $by_id{$uuid};
		if (!$row) { push @refused, $uuid . ': ' . &subs::ui('that device is not known in the house'); next; }
		if (!$row->{'ok'}) {
			push @refused, $row->{'hostname'} . ': ' . ($row->{'error'} || &subs::ui('there is not enough room'));
			next;
		}
		push @chosen, { uuid => $uuid, hostname => $row->{'hostname'} };
	}
	if (!scalar @chosen) {
		$answer->({ name => &subs::ui('CloudSync'), text => &subs::ui('No device was chosen, or none of them has room.'), cancel => 'no', height => '220px' });
		$c->render(json => $returner);
		return;
	}
	my $id = &subs::minion_grabber()->enqueue(cloud_sync => [ {
		path => $folder,
		base => $base,
		devices => \@chosen
	} ] => { retries => 1 });
	my $registrations = &subs::cloud_sync_registrations();
	my @keep = grep { ($_->{'path'} || '') ne $folder } @{$registrations};
	push @keep, {
		path => $folder,
		base => $base,
		devices => \@chosen,
		added => &subs::rightNow(),
		fingerprint => &subs::cloud_sync_fingerprint($folder),
		job => $id
	};
	&subs::cloud_sync_registrations_write(\@keep);
	my $text = &subs::ui('Syncing to') . ' ' . join(', ', map { $_->{'hostname'} } @chosen) . '.';
	$text .= ' ' . &subs::ui('Not used:') . ' ' . join('; ', @refused) if scalar @refused;
	$answer->({ name => &subs::ui('CloudSync'), text => $text, job => $id, progress => &subs::ui('starting'), ok => 'no', cancel => 'no', height => '240px' });
	$c->render(json => $returner);
}
# The list the Places column's CloudSync row opens: every folder registered on
# this machine, the devices it goes to, and its own Sync now and Stop controls.
# GET /manager/folders/cloud
sub action_30702 {
	my $c = shift;
	my @rows;
	foreach my $reg ( @{ &subs::cloud_sync_registrations() } ) {
		my @parts = split '/', ($reg->{'path'} || '');
		my $name = pop @parts;
		push @rows, {
			%{$reg},
			display => &subs::format_name($name || $reg->{'path'}),
			totals => &subs::cloud_sync_totals($reg->{'path'})
		};
	}
	my $content = $c->render_to_string(template => 'folders/cloud_list', registrations => \@rows);
	my $dialog = $c->render_to_string(
		template => 'folders/dialog_box',
		folders => { folder => '' },
		box => {
			name => &subs::ui('CloudSync'),
			command => 'cloud_list',
			content => $content,
			ok => 'no',
			cancel => 'yes',
			cancel_label => &subs::ui('Close'),
			height => '70%',
			width => 'min(620px, 94vw)'
		},
		uuid => &subs::random_string_creator(10)
	);
	$c->render(json => { status => 'ok', dialog => $dialog, folders => \@rows });
}

# Stop watching a folder. Copies already on the other devices are left alone;
# this only removes the registration on this machine.
# POST /manager/folders/cloud/remove
sub action_30703 {
	my $c = shift;
	my $folder = $c->param('folder') || '';
	my $reg = &subs::cloud_sync_registration_for($folder);
	if ($reg && $reg->{'job'}) {
		my $job = &subs::minion_grabber()->job($reg->{'job'});
		$job->note(cancel => 1) if ($job && ($job->info->{'state'} || '') eq 'active');
	}
	my @keep = grep { ($_->{'path'} || '') ne $folder } @{ &subs::cloud_sync_registrations() };
	&subs::cloud_sync_registrations_write(\@keep);
	$c->render(json => { status => 'ok', remaining => scalar @keep });
}

# Queue a registered folder again, for the person who does not want to wait for
# the sweep or is retrying after a device was unreachable.
# POST /manager/folders/cloud/now
sub action_30704 {
	my $c = shift;
	my $folder = $c->param('folder') || '';
	my $returner = {};
	my $answer = sub {
		my $box = shift;
		$returner->{'dialog'} = $c->render_to_string(
			template => 'folders/dialog_box',
			folders => { folder => $folder },
			box => $box,
			uuid => &subs::random_string_creator(10)
		);
	};
	my $reg = &subs::cloud_sync_registration_for($folder);
	if (!$reg) {
		$answer->({ name => &subs::ui('CloudSync'), text => &subs::ui('That folder is not set to CloudSync.'), cancel => 'no', height => '220px' });
		$c->render(json => $returner);
		return;
	}
	if ($reg->{'job'}) {
		my $running = &subs::minion_grabber()->job($reg->{'job'});
		my $state = ($running && $running->info) ? ($running->info->{'state'} || '') : '';
		if ($state eq 'active' || $state eq 'inactive') {
			$answer->({ name => &subs::ui('CloudSync'), text => &subs::ui('That folder is already syncing.'), ok => 'no', cancel => 'no', height => '220px' });
			$c->render(json => $returner);
			return;
		}
	}
	my $id = &subs::minion_grabber()->enqueue(cloud_sync => [ {
		path => $reg->{'path'},
		base => $reg->{'base'},
		devices => $reg->{'devices'}
	} ] => { retries => 1 });
	$reg->{'job'} = $id;
	$reg->{'fingerprint'} = &subs::cloud_sync_fingerprint($reg->{'path'});
	my $registrations = &subs::cloud_sync_registrations();
	foreach my $row ( @{$registrations} ) {
		%{$row} = %{$reg} if (($row->{'path'} || '') eq $folder);
	}
	&subs::cloud_sync_registrations_write($registrations);
	$answer->({ name => &subs::ui('CloudSync'), text => &subs::ui('Syncing now.'), job => $id, progress => &subs::ui('starting'), ok => 'no', cancel => 'no', height => '220px' });
	$c->render(json => $returner);
}
# A peer answering how much room its copy would have. It measures the nearest
# ancestor that exists, so a sync folder is not created just to ask.
# POST /manager/folders/cloud/space
sub action_30710 {
	my $c = shift;
	unless (&archive_peer_allowed($c)) {
		$c->render(json => { status => 'error', error => 'not allowed' });
		return;
	}
	my $dest = &subs::cloud_sync_destination({ base => $c->param('base'), path => '' });
	if ($dest->{'error'}) {
		$c->render(json => { status => 'error', error => $dest->{'error'} });
		return;
	}
	my $space = &subs::cloud_sync_free_space($dest->{'root'});
	$space->{'hostname'} = &subs::machine_name();
	$space->{'path'} = $dest->{'root'};
	$c->render(json => $space);
}

# Whether the destination already has a file at the same size and time, and
# whether a partial copy is waiting to be resumed.
# POST /manager/folders/cloud/probe
sub action_30711 {
	my $c = shift;
	unless (&archive_peer_allowed($c)) {
		$c->render(json => { status => 'error', error => 'not allowed' });
		return;
	}
	my $dest = &subs::cloud_sync_destination({ base => $c->param('base'), path => $c->param('path') });
	if ($dest->{'error'}) {
		$c->render(json => { status => 'error', error => $dest->{'error'} });
		return;
	}
	my $exists = -e $dest->{'path'} ? 1 : 0;
	my @stat = $exists ? stat($dest->{'path'}) : ();
	$c->render(json => {
		status => 'ok',
		path => $dest->{'path'},
		exists => $exists,
		size => $exists ? -s $dest->{'path'} : undef,
		mtime => $exists ? $stat[9] : undef,
		partial => &subs::archive_partial_state({ path => $dest->{'path'} })
	});
}
# The upload half of CloudSync. The same partial/resume rule as an archive
# transfer, but the destination is the folder named by the shared base, not an
# archive location.
# POST /manager/folders/cloud/receive
sub action_30712 {
	my $c = shift;
	unless (&archive_peer_allowed($c)) {
		$c->render(json => { status => 'error', error => 'not allowed' });
		return;
	}
	my @uploads = @{$c->req->uploads};
	my $upload = $uploads[0];
	unless ($upload) {
		$c->render(json => { status => 'error', error => 'no file in the request' });
		return;
	}
	my $dest = &subs::cloud_sync_destination({ base => $c->param('base'), path => $c->param('path') });
	if ($dest->{'error'}) {
		$c->render(json => { status => 'error', error => $dest->{'error'} });
		return;
	}
	Mojo::File->new($dest->{'parent'})->make_path;
	my $mtime = $c->param('mtime');
	my $offset = $c->param('offset');
	my $total = $c->param('total');
	my $source = $c->param('source');
	my $part = &subs::archive_partial_path($dest->{'path'});
	my $meta_path = &subs::archive_partial_meta_path($dest->{'path'});
	my $chunked = (defined $offset && $offset =~ /^\d+$/ && defined $total && $total =~ /^\d+$/) ? 1 : 0;
	if ($chunked) {
		my $source_path = eval { $upload->asset->path };
		unless ($source_path && -e $source_path) {
			$c->render(json => { status => 'error', error => 'the upload has no file' });
			return;
		}
		if ($offset > 0) {
			unless (-e $part) {
				$c->render(json => { status => 'error', error => 'there is no partial copy to resume', path => $dest->{'path'} });
				return;
			}
			my $have = -s $part;
			$have = 0 unless defined $have;
			if ($have < $offset) {
				$c->render(json => { status => 'error', error => 'the partial is shorter than the resume offset', path => $dest->{'path'}, size => $have });
				return;
			}
			my $meta = {};
			$meta = eval { return decode_json scalar read_file($meta_path) } || {} if ($meta_path && -e $meta_path);
			$meta = {} unless ref $meta eq 'HASH';
			if (defined $meta->{'total'} && $meta->{'total'} != $total) {
				$c->render(json => { status => 'error', error => 'the partial belongs to a different source', path => $dest->{'path'} });
				return;
			}
			if (defined $meta->{'source'} && length $meta->{'source'}
				&& defined $source && length $source && $meta->{'source'} ne $source) {
				$c->render(json => { status => 'error', error => 'the partial belongs to another source', path => $dest->{'path'} });
				return;
			}
		}
		my $mode = ($offset > 0) ? '+<' : '>';
		my ($in, $out);
		unless (open($out, $mode, $part)) {
			$c->render(json => { status => 'error', error => "cannot open $part: $!", path => $dest->{'path'} });
			return;
		}
		binmode $out;
		seek($out, $offset, 0) if $offset > 0;
		unless (open($in, '<:raw', $source_path)) {
			close $out;
			$c->render(json => { status => 'error', error => "cannot read the upload: $!", path => $dest->{'path'} });
			return;
		}
		binmode $in;
		my $written = 0;
		my $buf;
		while (my $n = read($in, $buf, 1024 * 1024)) {
			print $out $buf;
			$written += $n;
		}
		close $in;
		close $out;
		if ($offset == 0) {
			&subs::archive_partial_meta_write($dest->{'path'}, {
				source => (defined $source && length $source ? $source : undef),
				total => 0 + $total,
				mtime => (defined $mtime && $mtime =~ /^\d+$/ ? 0 + $mtime : undef),
				started => &subs::rightNow()
			});
		}
		if ($c->param('final') && ($offset + $written) != $total) {
			$c->render(json => { status => 'error', error => 'the file is incomplete', path => $dest->{'path'}, size => -s $part });
			return;
		}
		my $size = -s $part;
		$size = 0 unless defined $size;
		my $sha;
		if ($c->param('final')) {
			if ($size != $total) {
				$c->render(json => { status => 'error', error => 'the file is incomplete', path => $dest->{'path'}, size => $size });
				return;
			}
			$sha = &subs::archive_file_digest($part);
			unless (defined $sha && rename($part, $dest->{'path'})) {
				$c->render(json => { status => 'error', error => 'the verified copy could not be moved into place', path => $dest->{'path'} });
				return;
			}
			unlink $meta_path if ($meta_path && -e $meta_path);
			utime $mtime, $mtime, $dest->{'path'} if ($mtime && $mtime =~ /^\d+$/);
			$log->info('cloud sync: received ' . $dest->{'path'} . ' (' . $size . ' bytes)') if $log;
		}
		$c->render(json => {
			status => 'ok',
			path => $dest->{'path'},
			size => $size,
			offset => 0 + $offset,
			received => $written,
			sha256 => $sha,
			final => $c->param('final') ? 1 : 0
		});
		return;
	}
	eval { $upload->move_to($part) };
	if ($@) {
		$c->render(json => { status => 'error', error => "$@", path => $dest->{'path'} });
		return;
	}
	my $written = -s $part;
	$written = 0 unless defined $written;
	my $sha = &subs::archive_file_digest($part);
	unless (defined $sha && rename($part, $dest->{'path'})) {
		$c->render(json => { status => 'error', error => 'the verified copy could not be moved into place', path => $dest->{'path'} });
		return;
	}
	unlink $meta_path if ($meta_path && -e $meta_path);
	utime $mtime, $mtime, $dest->{'path'} if ($mtime && $mtime =~ /^\d+$/);
	$log->info('cloud sync: received ' . $dest->{'path'} . ' (' . $written . ' bytes)') if $log;
	$c->render(json => { status => 'ok', path => $dest->{'path'}, size => $written, sha256 => $sha });
}
# Throw away a partial copy at the sender's request after a cancel. Only the
# .part and its sidecar go; a finished copy and the source are untouched.
# POST /manager/folders/cloud/discard
sub action_30713 {
	my $c = shift;
	unless (&archive_peer_allowed($c)) {
		$c->render(json => { status => 'error', error => 'not allowed' });
		return;
	}
	my $dest = &subs::cloud_sync_destination({ base => $c->param('base'), path => $c->param('path') });
	if ($dest->{'error'}) {
		$c->render(json => { status => 'error', error => $dest->{'error'} });
		return;
	}
	my $state = &subs::archive_partial_state({ path => $dest->{'path'} });
	my $source = $c->param('source');
	if ($state->{'exists'} && defined $source && length $source
		&& defined $state->{'source'} && length $state->{'source'} && $state->{'source'} ne $source) {
		$c->render(json => { status => 'error', error => 'the partial belongs to another source', path => $dest->{'path'} });
		return;
	}
	my $removed = &subs::archive_partial_discard($dest->{'path'});
	$c->render(json => { status => 'ok', path => $dest->{'path'}, removed => $removed->{'removed'} });
}

# Apply the source's file list to the destination's tracked manifest, removing
# only files CloudSync itself placed that the source no longer has.
# POST /manager/folders/cloud/prune
sub action_30714 {
	my $c = shift;
	unless (&archive_peer_allowed($c)) {
		$c->render(json => { status => 'error', error => 'not allowed' });
		return;
	}
	my $files = eval { return decode_json $c->param('files') } || [];
	my $pruned = &subs::cloud_sync_prune_files($c->param('base'), $files);
	if ($pruned->{'error'}) {
		$c->render(json => { status => 'error', error => $pruned->{'error'} });
		return;
	}
	$c->render(json => { status => 'ok', removed => $pruned->{'removed'}, tracked => $pruned->{'tracked'} });
}

1;
