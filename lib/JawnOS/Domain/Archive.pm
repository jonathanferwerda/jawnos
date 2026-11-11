package subs;

# Archive: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Minion;
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

# A short-lived copy of a manifest for callers that only need to know which
# local paths have an archived copy. Folders re-reads on every navigation, so
# one small request per location per fifteen seconds is enough; a finished
# archive shows up on the next read after that.
our %archive_manifest_memo;
our $device;
our %m;
# The queue for work that has to outlive the request that asked for it: its own
# SQLite file under ~/.president. The web process enqueues, the worker in
# President.pl runs, and the folders app lists the same rows, so there is one
# place that says what is waiting, running or failed.
our $minion;

# Make sure the archive root (config.json's archive_dir) has one folder per
# location type. A blank archive_dir — the default — means this machine is not
# an archive, so nothing is touched; an archive_dir that is not there yet is
# left alone rather than invented, since it may be a mount that has not come up.
# Folders that already exist are left exactly as they are, so this is safe to
# run at any time. Pass a path to check a specific root.
sub archive_scaffolder {
	my $dir = shift;
	my $root = (defined $dir && length $dir) ? &home($dir) : &archive_root();
	return { enabled => 0, reason => 'no archive_dir set' } unless $root;
	$root =~ s{/+$}{};
	return { enabled => 0, dir => $root, reason => 'archive_dir does not exist' } unless -d $root;
	my (@created, @existing, @failed);
	foreach my $location (&location_types()) {
		my $path = &archive_location_folder($root, $location);
		if (-d $path) { push @existing, $location; next; }
		if (mkdir $path) { push @created, $location; }
		else { push @failed, $location; }
	}
	return { enabled => 1, dir => $root, created => \@created, existing => \@existing, failed => \@failed };
}

sub minion_grabber {
	unless ($minion) {
		my $dir = &home('~/.president');
		mkdir $dir unless -d $dir;
		$minion = Minion->new(SQLite => $dir . '/minion.db');
		# every process registers the same list, so a job can only be enqueued
		# under a name the worker also knows
		my $tasks = &minion_task_list();
		foreach my $task ( keys %{$tasks} ) {
			$minion->add_task($task => $tasks->{$task});
		}
	}
	return $minion;
}

# A manager-to-manager agent for a job to use. The worker runs under
# President.pl and cannot see Manager.pl, so this is the small twin of
# subs::remote_useragent_maker: the cookie jar stored on the
# remote_machines row is the whole of the authentication, and the tunnel-aware
# manager url is the whole of the addressing.
sub remote_agent_for {
	my $remote_uuid = shift;
	my $rm = &remote_machine_lister({ uuid => $remote_uuid, limit => 1 });
	return { error => 'no machine is registered for ' . ($remote_uuid || '(nothing)') } unless (ref $rm && $rm->{'manager'});
	$rm = &remote_machine_tunnel_processor($rm);
	my ($secure_manager, $verified) = &subs::peer_secure_url($rm, $rm->{'manager'});
	$rm->{'manager'} = $secure_manager if $verified;
	my $ua = Mojo::UserAgent->new;
	$ua->max_response_size(0);
	if ($verified) { &subs::peer_tls_verify($ua) } else { $ua->insecure(1) }
	$ua->inactivity_timeout(3000);
	# A machine-to-machine archive request proves itself with the same pinned
	# peer signature the rest of the rail uses. The stored session cookie alone
	# is refused once the app gate is enforced, which is how an upload started
	# failing with the app-required page instead of reaching the archive route.
	$ua->on(start => sub { my ($ua, $tx) = @_; &peer_sign_request($tx->req); });
	if ($rm->{'cookie'}) {
		my $cookies = eval { return decode_json $rm->{'cookie'} } || [];
		foreach my $cookie ( @{$cookies} ) {
			$ua->cookie_jar->add(
				Mojo::Cookie::Response->new(
					name => $cookie->{'name'},
					value => $cookie->{'value'},
					domain => $cookie->{'domain'},
					path => $cookie->{'path'}
				)
			);
		}
	}
	return { ua => $ua, manager => $rm->{'manager'}, hostname => $rm->{'hostname'}, rm => $rm };
}

# A manager-to-manager answer as JSON, with a readable failure when the far
# machine returns an HTML error page instead (a missing archive folder, a
# refused upload). Without this the sender only knows "the upload did not
# land" and nobody sees the reason.
sub archive_reply {
	my $tx = shift;
	return (undef, 'the archive machine did not answer') unless $tx;
	my $res = $tx->res;
	my $json = eval { $res->json };
	return ($json, undef) if ref $json eq 'HASH';
	my $body = $res->body || '';
	$body =~ s{<script\b.*?</script>}{}gis;
	$body =~ s{<style\b.*?</style>}{}gis;
	$body =~ s{<[^>]+>}{ }g;
	$body =~ s/&nbsp;/ /g;
	$body =~ s/&amp;/&/g;
	$body =~ s/\s+/ /g;
	$body =~ s/^ //; $body =~ s/ $//;
	$body = substr($body, 0, 300) if length $body > 300;
	my $code = $res->code || 'no status';
	return (undef, "the archive machine answered $code" . (length $body ? ": $body" : ''));
}

# ---- archive progress, partial files and verification ----------------------
#
# A transfer is a push: this machine reads the file and the archive machine
# writes it. The bytes on the archive machine are the only copy in flight, so
# the partial lives there under <destination>.part with a small sidecar that
# records which source it belongs to. A resumed run asks the archive machine
# for that state (probe), compares the recorded identity and the hash of the
# prefix it already has, and only then continues at that offset.

sub archive_fraction {
	my ($done, $total) = @_;
	$done = 0 unless (defined $done && $done =~ /^-?\d+(?:\.\d+)?$/);
	$total = 0 unless (defined $total && $total =~ /^-?\d+(?:\.\d+)?$/);
	return 0 unless $total > 0;
	$done = 0 if $done < 0;
	$done = $total if $done > $total;
	# four decimal places is finer than a byte count needs and keeps the
	# percentage honest (floor, never a 100% that is not finished)
	return int(($done / $total) * 10000 + 0.5) / 10000;
}

# The shape the job note carries and the folders app draws: the state, the
# bytes of this file, the bytes of the whole job, and one percentage for each.
sub archive_progress_view {
	my $data = shift || {};
	my $file_done = $data->{'file_bytes_done'} || 0;
	my $file_total = $data->{'file_bytes_total'};
	my $done = $data->{'bytes_done'} || 0;
	my $total = $data->{'bytes_total'};
	my $file_fraction = &archive_fraction($file_done, $file_total);
	my $fraction = &archive_fraction($done, $total);
	return {
		state => $data->{'state'} || 'queued',
		file => $data->{'file'},
		files => defined $data->{'files'} ? 0 + $data->{'files'} : undef,
		index => defined $data->{'index'} ? 0 + $data->{'index'} : undef,
		file_bytes_done => 0 + $file_done,
		file_bytes_total => defined $file_total ? 0 + $file_total : undef,
		bytes_done => 0 + $done,
		bytes_total => defined $total ? 0 + $total : undef,
		file_fraction => $file_fraction,
		file_percent => int($file_fraction * 100),
		fraction => $fraction,
		percent => int($fraction * 100),
		resumable => $data->{'resumable'} ? 1 : 0,
		resume_reason => $data->{'resume_reason'},
		delete_source => $data->{'delete_source'} ? 1 : 0,
	};
}

sub archive_partial_path {
	my $path = shift;
	return undef unless (defined $path && length $path);
	return $path . '.part';
}

sub archive_partial_meta_path {
	my $path = shift;
	return undef unless (defined $path && length $path);
	return $path . '.part.json';
}

# sha256 of at most $limit bytes; the prefix is what a resume has to agree on.
sub archive_prefix_digest {
	my ($path, $limit) = @_;
	return undef unless (defined $path && -f $path);
	$limit = 4 * 1024 * 1024 unless (defined $limit && $limit =~ /^\d+$/ && $limit > 0);
	open(my $fh, '<:raw', $path) or return undef;
	my $data = '';
	my $buf;
	while (length($data) < $limit) {
		my $want = $limit - length($data);
		$want = 1024 * 1024 if $want > 1024 * 1024;
		my $n = read($fh, $buf, $want);
		last unless $n;
		$data .= $buf;
	}
	close $fh;
	return $data eq '' ? sha256_hex('') : sha256_hex($data);
}

sub archive_file_digest {
	my $path = shift;
	return undef unless (defined $path && -f $path);
	my $sha = Digest::SHA->new(256);
	eval { $sha->addfile($path) } or return undef;
	return $sha->hexdigest;
}

sub archive_partial_meta_write {
	my ($path, $meta) = @_;
	my $meta_path = &archive_partial_meta_path($path);
	return undef unless $meta_path;
	my $temp = $meta_path . '.tmp';
	eval { write_file($temp, encode_json($meta || {})) } or return undef;
	return rename($temp, $meta_path) ? $meta_path : undef;
}

sub archive_partial_state {
	my $data = shift || {};
	my $path = $data->{'path'};
	my $part = &archive_partial_path($path);
	return { exists => 0 } unless ($part && -e $part);
	my $meta_path = &archive_partial_meta_path($path);
	my $meta = {};
	if ($meta_path && -e $meta_path) {
		$meta = eval { return decode_json scalar read_file($meta_path) } || {};
		$meta = {} unless ref $meta eq 'HASH';
	}
	my $size = -s $part;
	$size = 0 unless defined $size;
	my $limit = (defined $data->{'digest_limit'} && $data->{'digest_limit'} =~ /^\d+$/ && $data->{'digest_limit'} > 0)
		? $data->{'digest_limit'} : 4 * 1024 * 1024;
	my $prefix_bytes = $size < $limit ? $size : $limit;
	return {
		exists => 1,
		path => $part,
		size => $size,
		prefix_bytes => $prefix_bytes,
		prefix_sha256 => &archive_prefix_digest($part, $prefix_bytes),
		total => $meta->{'total'},
		mtime => $meta->{'mtime'},
		source => $meta->{'source'},
		sender => $meta->{'sender'},
		started => $meta->{'started'},
	};
}

sub archive_partial_discard {
	my $path = shift;
	my $removed = 0;
	foreach my $file ( &archive_partial_path($path), &archive_partial_meta_path($path) ) {
		next unless (defined $file && -e $file);
		$removed++ if unlink $file;
	}
	return { removed => $removed };
}

# Continue only when the partial records the same source (path, size, time)
# and its first bytes hash to the same prefix as the file being sent. Anything
# else starts from zero, so two different sources can never be stitched.
sub archive_resume_offset {
	my $data = shift || {};
	my $file = $data->{'file'};
	my $total = defined $data->{'total'} ? $data->{'total'} : -s $file;
	my $partial = $data->{'partial'};
	return { offset => 0, resumed => 0, reason => 'no partial copy' }
		unless (ref $partial eq 'HASH' && $partial->{'exists'} && $partial->{'size'} > 0);
	return { offset => 0, resumed => 0, reason => 'the partial is not smaller than the source' }
		if (defined $total && $partial->{'size'} >= $total);
	return { offset => 0, resumed => 0, reason => 'the partial belongs to a different size' }
		if (defined $partial->{'total'} && defined $total && $partial->{'total'} != $total);
	my $mtime = $data->{'mtime'};
	return { offset => 0, resumed => 0, reason => 'the partial belongs to a different source' }
		if (defined $partial->{'mtime'} && defined $mtime && $partial->{'mtime'} != $mtime);
	my $limit = $partial->{'prefix_bytes'};
	my $local = &archive_prefix_digest($file, $limit);
	return { offset => 0, resumed => 0, reason => 'the partial does not match this file' }
		unless (defined $partial->{'prefix_sha256'} && defined $local && $local eq $partial->{'prefix_sha256'});
	return { offset => 0 + $partial->{'size'}, resumed => 1, reason => 'continuing the partial copy' };
}

# The only path to removing an original: the archive machine has said the copy
# is final, its size matches, and its checksum matches a fresh read of the
# source. A half-finished job never reaches the checksum comparison.
sub archive_delete_source {
	my $data = shift || {};
	my $source = $data->{'source'};
	return { error => 'no source to remove' } unless (defined $source && length $source);
	return { error => 'the archive is not verified yet' } unless $data->{'verified'};
	my $source_size = -s $source;
	return { error => 'the source is not there' } unless defined $source_size;
	my $dest_size = $data->{'dest_size'};
	return { error => 'the destination did not report its size' } unless defined $dest_size;
	return { error => 'the destination is a different size' } unless $dest_size == $source_size;
	my $dest_sha = $data->{'dest_sha256'};
	return { error => 'the destination has no checksum' } unless (defined $dest_sha && length $dest_sha);
	my $source_sha = &archive_file_digest($source);
	return { error => 'the source could not be read' } unless defined $source_sha;
	return { error => 'the checksums do not match' } unless $source_sha eq $dest_sha;
	return { error => 'the source could not be removed' } unless unlink $source;
	return { deleted => 1, bytes => $source_size, sha256 => $source_sha };
}

sub archive_discard_remote {
	my $data = shift;
	my ($ua, $manager) = ($data->{'ua'}, $data->{'manager'});
	return { status => 'error', error => 'no archive machine to ask' } unless ($ua && $manager);
	my $url = $data->{'url'} || '/manager/folders/archive/discard';
	my %form = (path => $data->{'relative'}, source => $data->{'source'});
	$form{'location'} = $data->{'location'} if defined $data->{'location'};
	$form{'base'} = $data->{'base'} if defined $data->{'base'};
	$form{'sender'} = $data->{'sender'} if defined $data->{'sender'};
	my $tx = eval {
		return $ua->post($manager . $url => form => \%form)
	};
	my ($res, $err) = &archive_reply($tx);
	return $res if ($res && $res->{'status'} eq 'ok');
	return { status => 'error', error => ($res && $res->{'error'}) || $err || 'the partial was not discarded' };
}

# The worker half of archiving: deliver one queued item. The far machine is
# asked first whether it already has the file at that size and time, because a
# retry after a failed folder re-runs the whole folder and everything already
# sent should cost one small request each instead of the file itself. Errors
# are collected rather than thrown on the first bad file, so one unreadable
# file does not hide the rest; a job with any of them fails at the end, and
# Minion's retry skips what did land.
# Send one file to the archive machine. A small file is one request; a large
# one is cut into 64 MB pieces so no single upload has to survive a long
# request or a whole film's worth of buffering. Each piece is written at its
# offset, and a retry starts again at zero, so a dropped connection never
# leaves a half-written file that looks complete. Returns (bytes, error).
sub archive_send_file {
	my $data = shift;
	my $ua = $data->{'ua'};
	my $manager = $data->{'manager'};
	my $file = $data->{'file'};
	my $total = -s $file;
	my $source = defined $data->{'source'} ? $data->{'source'} : $data->{'relative'};
	my $chunk = 8 * 1024 * 1024;
	my $start = $data->{'start'} || 0;
	$start = 0 unless ($start =~ /^\d+$/ && (!defined $total || $start < $total));
	my $progress = $data->{'progress'} || sub { return 0 };
	my $url = $data->{'url'} || '/manager/folders/archive/receive';
	my $discard_url = $data->{'discard_url'};
	$discard_url = '/manager/folders/archive/discard' if (!defined $discard_url && !$data->{'url'});
	my $post_chunk = sub {
		my ($path, $offset, $final, $chunked) = @_;
		my %form = (
			path => $data->{'relative'},
			mtime => $data->{'mtime'},
			source => $source,
			file => { file => $path }
		);
		$form{'location'} = $data->{'location'} if defined $data->{'location'};
		$form{'base'} = $data->{'base'} if defined $data->{'base'};
		$form{'sender'} = $data->{'sender'} if defined $data->{'sender'};
		if ($chunked) {
			$form{'offset'} = $offset;
			$form{'total'} = $total;
			$form{'final'} = $final ? 1 : 0;
		}
		my $tx = eval {
			$ua->post($manager . $url => form => \%form)
		};
		return &archive_reply($tx);
	};
	if ($start == 0 && (!defined $total || $total == 0)) {
		# an empty file needs no chunk and no progress; everything else is
		# streamed in pieces so the bar moves while the bytes do
		my ($res, $err) = $post_chunk->($file, 0, 1, 0);
		if ($res && $res->{'status'} eq 'ok') {
			return ($total || 0, undef, {
				size => ($res->{'size'} || $total || 0),
				sha256 => $res->{'sha256'},
				resumed => 0,
				kept => $res->{'kept'},
				deleted_at => $res->{'deleted_at'}
			});
		}
		return (0, ($res && $res->{'error'}) || $err || 'the upload did not land', { resumed => 0 });
	}
	my ($offset, $sent) = ($start, 0);
	my $last_sha;
	# The last chunk's answer is the receiver's verdict on the whole file;
	# the caller needs it (a CloudSync peer refuses a copy its tombstone
	# outlived and names the deletion the sender must take locally).
	my $last_res;
	$progress->($start, $total) if $start > 0;
	while ($offset < $total) {
		my $take = $total - $offset > $chunk ? $chunk : $total - $offset;
		my $chunk_path = &peer_temp_file('archive_chunk');
		my ($in, $out);
		unless (open($in, '<:raw', $file)) {
			unlink $chunk_path;
			return (0, "cannot read $file", { resumed => $start > 0 });
		}
		seek($in, $offset, 0);
		unless (open($out, '>:raw', $chunk_path)) {
			close $in;
			unlink $chunk_path;
			return (0, 'cannot write a chunk for ' . $file, { resumed => $start > 0 });
		}
		my $left = $take;
		my $read = 0;
		my $last_note = 0;
		my $buf;
		my $cancelled = 0;
		while ($left > 0) {
			my $want = $left > 1024 * 1024 ? 1024 * 1024 : $left;
			my $n = read($in, $buf, $want);
			last unless $n;
			print $out $buf;
			$left -= $n;
			$read += $n;
			# the note is written while the bytes move, not only at the end
			if ($read - $last_note >= 4 * 1024 * 1024 || $left == 0) {
				$last_note = $read;
				$cancelled = 1 if $progress->($offset + $read, $total);
				last if $cancelled;
			}
		}
		close $in;
		close $out;
		if ($cancelled) {
			unlink $chunk_path;
			&archive_discard_remote({
				ua => $ua, manager => $manager, url => $discard_url,
				location => $data->{'location'}, base => $data->{'base'},
				relative => $data->{'relative'}, source => $source,
				sender => $data->{'sender'}
			}) if defined $discard_url;
			return (0, 'cancelled', { cancelled => 1, resumed => $start > 0 });
		}
		if ($left > 0) {
			unlink $chunk_path;
			return (0, "could not read $file at $offset bytes", { resumed => $start > 0 });
		}
		my $final = ($offset + $take >= $total) ? 1 : 0;
		# the archive machine hashes the whole partial before renaming it; say
		# so, because that is where a large file pauses
		$progress->($offset + $take, $total, 'verifying') if $final;
		my ($res, $err) = $post_chunk->($chunk_path, $offset, $final, 1);
		unlink $chunk_path;
		if (!$res || $res->{'status'} ne 'ok') {
			return (0, ($res && $res->{'error'}) || $err || "the upload stopped at $offset bytes", { resumed => $start > 0 });
		}
		$last_sha = $res->{'sha256'} if defined $res->{'sha256'};
		$last_res = $res if $final;
		$sent += $take;
		$offset += $take;
	}
	return ($sent, undef, {
		size => $total,
		sha256 => $last_sha,
		resumed => $start > 0,
		kept => ($last_res ? $last_res->{'kept'} : undef),
		deleted_at => ($last_res ? $last_res->{'deleted_at'} : undef)
	});
}

# A transfer whose destination is this machine: the same job the queue shows,
# but the bytes are copied locally instead of posted to a peer. It keeps the
# partial/resume rule and the delete-original guard the remote path uses, and
# appends to the same manifest, so the queue reads the same either way.
sub archive_local_transfer_job {
	my ($job, $data) = @_;
	my $location = $data->{'location'};
	my @files;
	if ($data->{'folder'}) {
		@files = sort &dir_listing([$data->{'path'}], 1);
	}
	else { @files = ( $data->{'path'} ) }

	my $files_count = scalar @files;
	my $bytes_total = 0;
	foreach my $file ( @files ) {
		my $size = -s $file;
		$bytes_total += $size if defined $size;
	}
	my $delete_source = $data->{'delete_source'} ? 1 : 0;
	my ($sent, $skipped, $bytes, $count) = (0, 0, 0, 0);
	my ($deleted, $resumed_files) = (0, 0);
	my $bytes_done = 0;
	my (@errors, @rows);

	my $note_progress = sub {
		my ($state, %extra) = @_;
		$job->note(archive => &archive_progress_view({
			state => $state,
			files => $files_count,
			bytes_done => $bytes_done,
			bytes_total => $bytes_total,
			delete_source => $delete_source,
			%extra,
		}));
	};
	$note_progress->('copying', bytes_done => 0);

	my $root = &archive_root();
	foreach my $file ( @files ) {
		$count++;
		my $relative = $data->{'relative'};
		if ($data->{'folder'}) {
			my $tail = substr($file, length($data->{'path'}));
			$tail =~ s{^/+}{};
			$relative = length $relative ? $relative . '/' . $tail : $tail;
		}
		my $size = -s $file;
		my $mtime = (stat($file))[9];

		if (($job->info->{'notes'} || {})->{'cancel'}) {
			$note_progress->('cancelled', file => $relative, index => $count, file_bytes_done => 0, file_bytes_total => $size);
			$job->finish({ sent => $sent, skipped => $skipped, bytes => $bytes, files => $files_count, cancelled => 1, deleted => $deleted, resumed => $resumed_files });
			return;
		}

		my $dest = &archive_destination({ location => $location, path => $relative, root => $root });
		if ($dest->{'error'}) {
			push @errors, ($relative || $file) . ': ' . $dest->{'error'};
			next;
		}
		# a file already on the archive drive needs no copy, but the listing is
		# still kept in step (a rescan and a re-run both reach this)
		if ($root && $file =~ m{^\Q$root\E/}) {
			push @rows, &archive_manifest_row({ path => $file, relative => $relative });
			$skipped++;
			$bytes_done += $size if defined $size;
			next;
		}

		my $exists = -e $dest->{'path'} ? 1 : 0;
		my $dest_size = $exists ? -s $dest->{'path'} : undef;
		my $dest_mtime = $exists ? (stat($dest->{'path'}))[9] : undef;
		my $same = ($exists && defined $dest_size && defined $size && $dest_size == $size
			&& (!defined $dest_mtime || !defined $mtime || $dest_mtime == $mtime));
		if ($same && !$delete_source) {
			$skipped++;
			$bytes_done += $size if defined $size;
			next;
		}
		if ($same && $delete_source) {
			my $local_sha = &archive_file_digest($file);
			my $dest_sha = &archive_file_digest($dest->{'path'});
			if (defined $local_sha && defined $dest_sha && $local_sha eq $dest_sha) {
				my $removed = &archive_delete_source({ source => $file, verified => 1, dest_size => $dest_size, dest_sha256 => $dest_sha });
				if ($removed->{'deleted'}) { $deleted++; }
				else { push @errors, ($relative || $file) . ': ' . ($removed->{'error'} || 'the original was not removed'); }
				$skipped++;
				$bytes_done += $size if defined $size;
				next;
			}
		}

		File::Path::make_path($dest->{'parent'});
		my $part = &archive_partial_path($dest->{'path'});
		my $meta_path = &archive_partial_meta_path($dest->{'path'});
		my $resume = &archive_resume_offset({
			file => $file,
			total => $size,
			mtime => $mtime,
			partial => &archive_partial_state({ path => $dest->{'path'} }),
		});
		my $start = $resume->{'offset'} || 0;
		if ($start == 0) {
			&archive_partial_meta_write($dest->{'path'}, {
				source => $relative,
				total => 0 + ($size || 0),
				mtime => $mtime,
				started => &rightNow()
			});
		}
		my $start_bytes = $bytes_done;
		my $copied = eval {
			my ($in, $out);
			open($in, '<:raw', $file) or die "cannot read $file: $!";
			open($out, ($start > 0 ? '+<' : '>'), $part) or die "cannot write $part: $!";
			binmode $out;
			seek($out, $start, 0) if $start > 0;
			seek($in, $start, 0) if $start > 0;
			my $buf;
			my $read = 0;
			while (my $n = read($in, $buf, 1024 * 1024)) {
				print $out $buf;
				$read += $n;
				if ($read >= 8 * 1024 * 1024 || $start + $read >= ($size || 0)) {
					$note_progress->('copying',
						file => $relative, index => $count,
						file_bytes_done => $start + $read, file_bytes_total => $size,
						bytes_done => $start_bytes + $start + $read,
						resumable => ($start > 0 ? 1 : 0), resume_reason => $resume->{'reason'});
					$read = 0;
				}
			}
			close $in;
			close $out;
			1;
		};
		unless ($copied) {
			push @errors, ($relative || $file) . ': ' . ($@ || 'the copy failed');
			next;
		}
		my $part_size = -s $part;
		if (!defined $part_size || !defined $size || $part_size != $size) {
			push @errors, ($relative || $file) . ': the copy is incomplete';
			next;
		}
		$note_progress->('verifying', file => $relative, index => $count, file_bytes_done => $part_size, file_bytes_total => $size, bytes_done => $start_bytes + $part_size);
		my $sha = &archive_file_digest($part);
		unless (defined $sha && rename($part, $dest->{'path'})) {
			push @errors, ($relative || $file) . ': the verified copy could not be moved into place';
			next;
		}
		unlink $meta_path if ($meta_path && -e $meta_path);
		utime $mtime, $mtime, $dest->{'path'} if ($mtime && $mtime =~ /^\d+$/);
		$sent++;
		$bytes += $part_size;
		$bytes_done = $start_bytes + $part_size;
		$resumed_files++ if $start > 0;
		if ($delete_source) {
			my $removed = &archive_delete_source({ source => $file, verified => 1, dest_size => $part_size, dest_sha256 => $sha });
			if ($removed->{'deleted'}) { $deleted++; }
			else { push @errors, ($relative || $file) . ': ' . ($removed->{'error'} || 'the original was not removed'); }
		}
		push @rows, &archive_manifest_row({ path => $dest->{'path'}, relative => $relative });
	}

	my $appended = 0;
	if (scalar @rows) {
		my $batch_size = 500;
		for (my $n = 0; $n < scalar @rows; $n += $batch_size) {
			my $last = ($n + $batch_size - 1 > $#rows) ? $#rows : $n + $batch_size - 1;
			my $res = &archive_manifest_append({ location => $location, rows => [ @rows[$n .. $last] ] });
			if ($res->{'error'}) { push @errors, 'manifest: ' . $res->{'error'}; last; }
			$appended += $res->{'rows'} || 0;
		}
	}

	my $result = {
		sent => $sent,
		skipped => $skipped,
		bytes => $bytes,
		files => $files_count,
		resumed => $resumed_files,
		deleted => $deleted,
		manifest_rows => $appended,
		archive_host => &machine_name(),
		location => $location
	};
	$result->{'errors'} = \@errors if scalar @errors;
	$note_progress->('done', bytes_done => $bytes_total);
	$job->finish($result);
}

sub archive_transfer_job {
	my ($job, $data) = @_;
	return &archive_local_transfer_job($job, $data) if $data->{'local'};
	my $agent = &remote_agent_for($data->{'remote_uuid'});
	if ($agent->{'error'}) {
		$job->note(archive => &archive_progress_view({ state => 'failed', delete_source => $data->{'delete_source'} }));
		$job->fail($agent->{'error'});
		return;
	}
	my $ua = $agent->{'ua'};
	my $manager = $agent->{'manager'};

	my @files;
	if ($data->{'folder'}) {
		@files = &dir_listing([$data->{'path'}], 1);
		@files = sort @files;
	}
	else { @files = ( $data->{'path'} ) }

	my $files_count = scalar @files;
	my $bytes_total = 0;
	foreach my $file ( @files ) {
		my $size = -s $file;
		$bytes_total += $size if defined $size;
	}
	my $delete_source = $data->{'delete_source'} ? 1 : 0;
	my ($sent, $skipped, $bytes, $count) = (0, 0, 0, 0);
	my ($deleted, $resumed_files) = (0, 0);
	my $bytes_done = 0;
	my @errors;
	my @rows;

	# one note carries the whole picture: the state, this file's bytes and the
	# job's bytes, so the folders app can draw a per-file and an overall line
	# from the same poll
	my $note_progress = sub {
		my ($state, %extra) = @_;
		$job->note(archive => &archive_progress_view({
			state => $state,
			files => $files_count,
			bytes_done => $bytes_done,
			bytes_total => $bytes_total,
			delete_source => $delete_source,
			%extra,
		}));
	};
	$note_progress->('copying', bytes_done => 0);

	foreach my $file ( @files ) {
		$count++;
		my $relative = $data->{'relative'};
		if ($data->{'folder'}) {
			my $tail = substr($file, length($data->{'path'}));
			$tail =~ s{^/+}{};
			$relative = length $relative ? $relative . '/' . $tail : $tail;
		}
		my $size = -s $file;
		my $mtime = (stat($file))[9];

		# a cancel is a request the worker honours at the next file, and
		# during the copy through the progress callback below
		if (($job->info->{'notes'} || {})->{'cancel'}) {
			&archive_discard_remote({ ua => $ua, manager => $manager, location => $data->{'location'}, relative => $relative, source => $relative });
			$note_progress->('cancelled', file => $relative, index => $count, file_bytes_done => 0, file_bytes_total => $size);
			$job->finish({ sent => $sent, skipped => $skipped, bytes => $bytes, files => $files_count, cancelled => 1, deleted => $deleted, resumed => $resumed_files });
			return;
		}

		my $probe_tx = eval {
			$ua->post($manager . '/manager/folders/archive/probe' => form => {
				location => $data->{'location'},
				path => $relative,
				# deleting an original needs a checksum, not just size and time
				checksum => ($delete_source ? 1 : 0)
			})
		};
		my ($probe, $probe_error) = &archive_reply($probe_tx);
		if (!$probe || $probe->{'status'} ne 'ok') {
			push @errors, ($relative || $file) . ': ' . (($probe && $probe->{'error'}) || $probe_error || 'the archive machine did not answer');
			next;
		}
		my $resume = &archive_resume_offset({
			file => $file,
			total => $size,
			mtime => $mtime,
			partial => $probe->{'partial'},
		});
		my $start = $resume->{'offset'} || 0;
		if ($probe->{'exists'} && defined $probe->{'size'} && defined $size && $probe->{'size'} == $size
			&& (!defined $probe->{'mtime'} || !defined $mtime || $probe->{'mtime'} == $mtime)) {
			if ($delete_source) {
				my $local_sha = &archive_file_digest($file);
				if (defined $probe->{'sha256'} && defined $local_sha && $local_sha eq $probe->{'sha256'}) {
					my $removed = &archive_delete_source({ source => $file, verified => 1, dest_size => $probe->{'size'}, dest_sha256 => $probe->{'sha256'} });
					if ($removed->{'deleted'}) { $deleted++; }
					else { push @errors, ($relative || $file) . ': ' . ($removed->{'error'} || 'the original was not removed'); }
					$skipped++;
					$bytes_done += $size;
					next;
				}
			}
			else {
				$skipped++;
				$bytes_done += $size;
				next;
			}
		}

		my $start_bytes = $bytes_done;
		my $last_cancel_check = 0;
		my $progress = sub {
			my ($file_done, $file_total, $phase) = @_;
			my $state = (defined $phase && $phase eq 'verifying') ? 'verifying' : 'copying';
			$note_progress->($state,
				file => $relative,
				index => $count,
				file_bytes_done => $file_done,
				file_bytes_total => $file_total,
				bytes_done => $start_bytes + $file_done,
				resumable => ($start > 0 ? 1 : 0),
				resume_reason => $resume->{'reason'});
			# asking the queue once a second is enough to feel immediate and
			# avoids a database read for every four megabytes
			my $now = time;
			if ($now - $last_cancel_check >= 0.5) {
				$last_cancel_check = $now;
				return ((($job->info->{'notes'} || {})->{'cancel'}) ? 1 : 0);
			}
			return 0;
		};

		my ($sent_bytes, $send_error, $detail) = &archive_send_file({
			ua => $ua,
			manager => $manager,
			location => $data->{'location'},
			relative => $relative,
			source => $relative,
			file => $file,
			mtime => $mtime,
			start => $start,
			progress => $progress
		});
		$detail = {} unless ref $detail eq 'HASH';
		if ($detail->{'cancelled'} || (defined $send_error && $send_error eq 'cancelled')) {
			$note_progress->('cancelled', file => $relative, index => $count, file_bytes_done => 0, file_bytes_total => $size);
			$job->finish({ sent => $sent, skipped => $skipped, bytes => $bytes, files => $files_count, cancelled => 1, deleted => $deleted, resumed => $resumed_files });
			return;
		}
		if ($send_error) {
			# the partial is deliberately left in place; the next attempt resumes it
			push @errors, ($relative || $file) . ': ' . $send_error;
			next;
		}
		$sent++;
		$bytes += $sent_bytes;
		$bytes_done = $start_bytes + ($size || 0);
		$resumed_files++ if $start > 0;
		if ($delete_source) {
			my $removed = &archive_delete_source({
				source => $file,
				verified => 1,
				dest_size => (defined $detail->{'size'} ? $detail->{'size'} : $size),
				dest_sha256 => $detail->{'sha256'},
			});
			if ($removed->{'deleted'}) { $deleted++; }
			else { push @errors, ($relative || $file) . ': ' . ($removed->{'error'} || 'the original was not removed'); }
		}
		push @rows, &archive_manifest_row({ path => $file, relative => $relative });
		$note_progress->('copying', file => $relative, index => $count, file_bytes_done => ($size || 0), file_bytes_total => $size, bytes_done => $bytes_done);
	}

	my $result = {
		sent => $sent,
		skipped => $skipped,
		bytes => $bytes,
		files => $files_count,
		resumed => $resumed_files,
		deleted => $deleted,
		manifest_rows => scalar @rows,
		archive_host => $agent->{'hostname'},
		location => $data->{'location'}
	};

	# what was just delivered goes into the archive's manifest, in one request
	# per job rather than one per file: the far machine appends a line and only
	# rewrites the listing itself when the journal has piled up
	if (scalar @rows) {
		my $batch_size = 500;
		for (my $n = 0; $n < scalar @rows; $n += $batch_size) {
			my $last = ($n + $batch_size - 1 > $#rows) ? $#rows : $n + $batch_size - 1;
			my @batch = @rows[$n .. $last];
			my $manifest_tx = eval {
				$ua->post($manager . '/manager/folders/archive/manifest/append' => form => {
					location => $data->{'location'},
					rows => encode_json \@batch
				})
			};
			my ($res, $res_error) = &archive_reply($manifest_tx);
			if (!$res || $res->{'status'} ne 'ok') {
				push @errors, 'manifest: ' . (($res && $res->{'error'}) || $res_error || 'the listing could not be updated');
				last;
			}
		}
	}
	if (scalar @errors) {
		$result->{'errors'} = \@errors;
		$note_progress->('failed', file => undef, index => $count);
		$job->fail($result);
		return;
	}
	$note_progress->('done', bytes_done => $bytes_total, file => undef, index => $files_count);
	$job->note(progress => "sent $sent, skipped $skipped, $bytes bytes");
	$job->finish($result);
}

# The type an archive row carries, in the same words the folders app uses for a
# file, so a listing built from a manifest reads like a local one. A sealed
# name keeps its original extension under the .enc tail, so that tail is
# dropped first: a sealed photo is a photo for the gallery and the listing.
sub archive_media_type {
	my $path = shift || '';
	$path =~ s/\.enc$//i;
	return 'image' if $path =~ /\.(jpe?g|png|bmp|tiff?|xcf|webp|gif|heic)$/i;
	return 'audio' if $path =~ /\.(wav|mp3|aiff|weba|m4a|flac|aac|ogg|opus)$/i;
	return 'video' if $path =~ /\.(mp4|avi|mov|webm|mkv|m4v|wmv)$/i;
	return 'pdf' if $path =~ /\.pdf$/i;
	return 'document' if $path =~ /\.(docx?|xlsx?|pptx?|txt|rtf|odt)$/i;
	return 'subtitles' if $path =~ /\.(vtt|srt)$/i;
	return 'other';
}

# A manifest row's type. Rows written before sealed names were read through
# their .enc tail carry `other` for a photo or a track, so a caller that has to
# know what a row is derives it from the name when the stored word is not a
# media type. A rescan writes the right word from now on.
sub archive_row_type {
	my $row = shift || {};
	my $stored = $row->{'type'} || '';
	return $stored if $stored =~ /^(?:image|audio|video|pdf|document|subtitles)$/;
	return &archive_media_type($row->{'relative'} || '');
}

# One manifest row for a file: what it is and where it sits inside its location
# folder, with the media facts worked out once, so the apps reading a manifest
# never have to open the file. `relative` is what makes a row portable - it
# means the same thing on whichever machine is holding the drive.
sub archive_manifest_row {
	my $data = shift;
	my $path = $data->{'path'};
	my $type = &archive_media_type($path);
	my $row = {
		relative => $data->{'relative'},
		size => -s $path,
		mtime => (stat($path))[9],
		type => $type
	};
	# a sealed file's type comes from the name it was sealed from, but its bytes
	# are ciphertext: probing them would only ask ffmpeg to read noise
	if (($type eq 'image' || $type eq 'audio' || $type eq 'video') && $path !~ /\.enc$/i) {
		my $file_data = &file_media_information({ f => $path, type => $type });
		$row->{'info'} = $file_data->{'info'} if $file_data->{'info'};
	}
	return $row;
}

# What an archive holds for a location: the compacted manifest with the journal
# read over the top of it. An append is one line, so a transfer never rewrites
# the listing; a read is one file plus whatever has piled up since. A line that
# does not parse - a write caught mid-flight - is skipped rather than fatal,
# and the last row for a path wins.
sub archive_manifest_read {
	my $data = shift;
	my $dir = $data->{'dir'};
	my %rows;
	my $json = $dir . '/manifest.json';
	if (-e $json) {
		my $compacted = eval { return decode_json scalar read_file($json) } || [];
		foreach my $row ( @{$compacted} ) {
			next unless (ref $row && defined $row->{'relative'} && length $row->{'relative'});
			$rows{$row->{'relative'}} = $row;
		}
	}
	my ($lines, $skipped) = (0, 0);
	my $journal = $dir . '/manifest.jsonl';
	if (-e $journal) {
		foreach my $line ( read_file($journal) ) {
			chomp $line;
			next unless (defined $line && length $line);
			$lines++;
			my $batch = eval { return decode_json $line };
			unless (ref $batch eq 'ARRAY') { $skipped++; next }
			foreach my $row ( @{$batch} ) {
				next unless (ref $row && defined $row->{'relative'} && length $row->{'relative'});
				$rows{$row->{'relative'}} = $row;
			}
		}
	}
	return { rows => [ map { $rows{$_} } sort keys %rows ], journal_lines => $lines, journal_skipped => $skipped };
}

# Write the listing a reader sees. Rewriting the whole thing is the one
# expensive write there is, so it happens when the journal has piled up or a
# rescan asks for it, never per received file. A temporary file is renamed into
# place, so a reader can never catch half of one, and the journal is dropped
# once it is folded in.
sub archive_manifest_write {
	my $data = shift;
	my $dir = $data->{'dir'};
	my @rows = @{$data->{'rows'} || []};
	my $json = $dir . '/manifest.json';
	my $temp = $json . '.tmp';
	write_file($temp, encode_json [ map {
		{
			relative => $_->{'relative'},
			size => $_->{'size'},
			mtime => $_->{'mtime'},
			type => $_->{'type'},
			($_->{'info'} ? (info => $_->{'info'}) : ())
		}
	} @rows ]);
	rename $temp, $json;
	my $journal = $dir . '/manifest.jsonl';
	unlink $journal if -e $journal;
	return { rows => scalar @rows, path => $json };
}

# Read an archive location again from the drive itself and write the manifest
# from what is really there, for a drive filled by hand or shuffled outside the
# queue. It opens every media file it finds, so it runs as a job and says where
# it is in its notes.
sub archive_manifest_rescan_job {
	my ($job, $data) = @_;
	my $dest = &archive_destination({ location => $data->{'location'}, path => '' });
	if ($dest->{'error'}) { $job->fail($dest->{'error'}); return }
	unless (-d $dest->{'folder'}) {
		&archive_manifest_write({ dir => $dest->{'folder'}, rows => [] });
		$job->finish({ location => $data->{'location'}, rows => 0, files => 0 });
		return;
	}
	my @files = &dir_listing([$dest->{'folder'}], 1);
	my @rows;
	my $count = 0;
	foreach my $file ( sort @files ) {
		$count++;
		$job->note(progress => "read $count of " . scalar(@files)) if $count % 25 == 0;
		my $relative = substr($file, length($dest->{'folder'}) + 1);
		next unless (defined $relative && length $relative);
		# the listing is not part of the listing
		next if $relative =~ m{^manifest\.jsonl?$};
		push @rows, &archive_manifest_row({ path => $file, relative => $relative });
	}
	my $written = &archive_manifest_write({ dir => $dest->{'folder'}, rows => \@rows });
	$job->note(progress => 'read ' . scalar(@files) . ' files');
	$job->finish({ location => $data->{'location'}, rows => $written->{'rows'}, files => scalar @files });
}

# What an archive machine holds for a location, asked for by uuid, with the
# absolute folder those rows sit in - so a caller can address the files on that
# machine without ever mounting it. An unreachable machine is an answer too:
# the caller carries on without the archive instead of failing the whole
# listing.
sub archive_manifest_fetch {
	my $data = shift;
	my $agent = &remote_agent_for($data->{'remote_uuid'});
	return { error => $agent->{'error'} } if $agent->{'error'};
	# A listing that only wants the badge cannot wait on a dead peer; its own
	# caller passes a short bound. The archive transfer keeps the long one.
	if ($data->{'timeout'}) {
		$agent->{'ua'}->request_timeout($data->{'timeout'});
		$agent->{'ua'}->inactivity_timeout($data->{'timeout'});
		# a sleeping machine must not spend the long connect default either;
		# a reachable one that is slow to answer still answers inside the bound
		$agent->{'ua'}->connect_timeout($data->{'timeout'});
	}
	my $res = eval {
		return $agent->{'ua'}->post($agent->{'manager'} . '/manager/folders/archive/manifest' => form => {
			location => $data->{'location'}
		})->result->json;
	};
	return { error => 'the archive machine did not answer' } unless ($res && $res->{'status'} eq 'ok');
	return { %{$res}, hostname => $agent->{'hostname'} };
}

sub archive_manifest_cached {
	my $data = shift;
	my $key = ($data->{'remote_uuid'} || '') . '|' . ($data->{'location'} || '');
	my $now = &rightNow();
	my $hit = $archive_manifest_memo{$key};
	return $hit->{'manifest'} if ($hit && $now - $hit->{'at'} < 15000);
	my $manifest = &archive_manifest_fetch($data);
	$archive_manifest_memo{$key} = { at => $now, manifest => $manifest };
	%archive_manifest_memo = () if keys(%archive_manifest_memo) > 32;
	return $manifest;
}

# A manifest for a resolved archive machine, local or on a peer. The machine
# holding the drive reads its own folder directly; every other machine asks it
# over the peer rail. One shape either way, so a caller never branches on which
# machine it turned out to be.
sub archive_manifest_for {
	my $data = shift;
	my $rm = $data->{'rm'} || {};
	my $location = $data->{'location'};
	return { error => 'no archive machine' } unless (ref $rm eq 'HASH' && ($rm->{'self'} || $rm->{'uuid'}));
	if ($rm->{'self'}) {
		my $dest = &archive_destination({ location => $location, path => '', root => $rm->{'archive_dir'} });
		return { error => $dest->{'error'} } if $dest->{'error'};
		my $manifest = &archive_manifest_read({ dir => $dest->{'folder'} });
		return {
			status => 'ok',
			location => $location,
			folder => $dest->{'folder'},
			rows => $manifest->{'rows'},
			journal_lines => $manifest->{'journal_lines'},
			hostname => $rm->{'hostname'} || &machine_name()
		};
	}
	return &archive_manifest_cached({
		remote_uuid => $rm->{'uuid'},
		location => $location,
		(defined $data->{'timeout'} ? (timeout => $data->{'timeout'}) : ())
	});
}

# Put finished rows into a location's listing. An append is one line, so a
# transfer never rewrites the listing; the journal is folded into the compacted
# manifest only when it has piled up. The rows are resolved the way a receive
# would resolve them, so nothing can point outside the location folder. Used by
# the peer route and by a transfer that runs on this machine itself.
sub archive_manifest_append {
	my $data = shift;
	my $location = $data->{'location'};
	my $rows = $data->{'rows'} || [];
	my $dest = &archive_destination({ location => $location, path => '' });
	return { error => $dest->{'error'} } if $dest->{'error'};
	my @clean;
	foreach my $row ( @{$rows} ) {
		next unless (ref $row && defined $row->{'relative'} && length $row->{'relative'});
		my $into = &archive_destination({ location => $location, path => $row->{'relative'} });
		next if $into->{'error'};
		push @clean, { %{$row}, relative => $into->{'relative'} };
	}
	File::Path::make_path($dest->{'folder'});
	write_file($dest->{'folder'} . '/manifest.jsonl', { append => 1 }, encode_json(\@clean) . "\n") if scalar @clean;
	my $manifest = &archive_manifest_read({ dir => $dest->{'folder'} });
	my $compacted = 0;
	if ($manifest->{'journal_lines'} > 200) {
		&archive_manifest_write({ dir => $dest->{'folder'}, rows => $manifest->{'rows'} });
		$compacted = 1;
	}
	return { rows => scalar @clean, compacted => $compacted, folder => $dest->{'folder'} };
}

# Where a file that is no longer on this machine can be found: the location
# whose folder holds it, the archive machine that location archives to, and the
# path inside that machine's archive. `locate` answers one path at a time. The
# local machine is a candidate (it may hold the drive), and its rows are read
# from the drive directly instead of the machine asking itself over the rail.
sub archive_file_lookup {
	my $data = shift;
	my $misc = $data->{'misc_settings'} || &subs::misc_setting_list();
	my $device = &subs::device_setter();
	my $settings = $data->{'settings'} || $misc->{$device} || {};
	my $location = $data->{'location'};
	my $base = $data->{'base'};
	if (!$location) {
		($location, $base) = &archive_location_for($data->{'path'}, $settings);
	}
	elsif (!defined $base) {
		my $b = $settings->{$location . '_location'};
		$b = &home($b) if (defined $b && length $b);
		$b =~ s{/+$}{} if defined $b;
		$base = $b;
	}
	return {} unless ($location && defined $base && length $base);
	$base =~ s{/+$}{};
	my $machines = $data->{'machines'} || &subs::archive_machines();
	my $rm = &archive_machine_for($location, $settings, $machines);
	return {} unless ($rm && ($rm->{'self'} || $rm->{'uuid'}));
	my $manifest = &archive_manifest_for({
		rm => $rm,
		location => $location,
		timeout => (defined $data->{'timeout'} ? $data->{'timeout'} : 6)
	});
	return {} if $manifest->{'error'};
	my $folder = $manifest->{'folder'} || '';
	my %rows = map { $_->{'relative'} => $_ } @{$manifest->{'rows'} || []};
	my $types = $data->{'types'};
	my $locate = sub {
		my $path = shift;
		return undef unless (defined $path && length $path);
		my $relative;
		if ($path eq $base) { $relative = ''; }
		elsif ($path =~ m{^\Q$base\E/}) { $relative = substr($path, length($base) + 1); }
		else { return undef; }
		my $row = $rows{$relative};
		return undef unless $row;
		my $type = &archive_row_type($row);
		if ($types && ref $types eq 'ARRAY') {
			return undef unless grep { $_ eq $type } @{$types};
		}
		return {
			path => (length $folder ? $folder . '/' . $relative : $relative),
			relative => $relative,
			type => $type,
			size => $row->{'size'},
			mtime => $row->{'mtime'},
			remote_uuid => ($rm->{'self'} ? '' : $rm->{'uuid'}),
			remote_hostname => $manifest->{'hostname'} || ''
		};
	};
	return {
		locate => $locate,
		location => $location,
		base => $base,
		folder => $folder,
		remote_uuid => ($rm->{'self'} ? '' : $rm->{'uuid'}),
		hostname => $manifest->{'hostname'} || ''
	};
}

# Attach the archive copy to the file entries an appointment carries: a file
# whose local path is gone is looked up once per location, and the entry learns
# where the bytes are and which machine holds them. A file that is present is
# left exactly as it is.
sub archive_file_attach {
	my ($files, $data) = @_;
	return unless (ref $files eq 'ARRAY' && scalar @{$files});
	$data ||= {};
	my $cache = $data->{'cache'} ||= {};
	my $lookups = $cache->{'lookups'} ||= {};
	foreach my $file ( @{$files} ) {
		next unless (ref $file eq 'HASH');
		my $path = $file->{'file'};
		next unless (defined $path && length $path);
		next if ($file->{'remote_uuid'} || -e $path);
		# only a missing file pays for the settings and peer reads
		my $misc = $cache->{'misc'} ||= ($data->{'misc_settings'} || &subs::misc_setting_list());
		my $machines = $cache->{'machines'} ||= ($data->{'machines'} || &subs::archive_machines());
		# an appointment row synced from another machine keeps that machine's
		# path (a phone's /sdcard/DCIM seen on a computer), so the location is
		# matched against every device's folders, longest base first
		my ($location, $base, $settings);
		foreach my $device_settings ( values %{$misc} ) {
			next unless ref $device_settings eq 'HASH';
			my ($loc, $b) = &archive_location_for($path, $device_settings);
			next unless $loc;
			if (!defined $base || length($b) > length($base)) {
				($location, $base, $settings) = ($loc, $b, $device_settings);
			}
		}
		next unless $location;
		my $key = $location . '|' . $base;
		$lookups->{$key} ||= &archive_file_lookup({
			misc_settings => $misc,
			settings => $settings,
			location => $location,
			base => $base,
			machines => $machines
		});
		my $found = $lookups->{$key}->{'locate'} ? $lookups->{$key}->{'locate'}->($path) : undef;
		next unless $found;
		$file->{'file'} = $found->{'path'};
		$file->{'remote_uuid'} = $found->{'remote_uuid'} if length($found->{'remote_uuid'} || '');
		$file->{'remote_hostname'} = $found->{'remote_hostname'} if length($found->{'remote_hostname'} || '');
		$file->{'archived'} = 1;
	}
	return $files;
}

# Where a photo that has left this disk can still be found. The archive machine
# holding photo_location is asked for its manifest once, and `locate` then
# answers for one path at a time, by the path's place inside the location. Only
# missing files are ever asked about, so a listing of live files never waits on
# a machine, and a machine that cannot be reached answers with nothing rather
# than failing the listing.
sub archive_image_lookup {
	my $data = shift;
	my $misc = $data->{'misc_settings'} || &subs::misc_setting_list();
	my $device = &subs::device_setter();
	my $here = $misc->{$device}->{'photo_location'};
	return {} unless $here;
	my $base = &home($here);
	$base =~ s{/+$}{};
	return &archive_file_lookup({
		misc_settings => $misc,
		location => 'photo',
		base => $base,
		types => ['image'],
		timeout => 6
	});
}

# Where a fetched item lands here: the same place inside this machine's own
# folder for that location. The inverse of the archive plan, and the only path
# a fetch writes to; the relative path is resolved so it cannot climb out.
sub archive_local_destination {
	my $data = shift;
	my $location = $data->{'location'};
	my $relative = $data->{'relative'} || '';
	return { error => 'unknown location' } unless grep { $_ eq $location } &location_types();
	my $base = &setting_grabber({ app => 'misc', setting => $location . '_location' });
	return { error => 'this machine has no folder for ' . $location } unless (defined $base && length $base);
	$base = &home($base);
	$base =~ s{/+$}{};
	my @parts;
	foreach my $part ( split m{/+}, $relative ) {
		next if $part eq '' || $part eq '.';
		return { error => 'the path climbs out of the location' } if $part eq '..';
		push @parts, $part;
	}
	my $inside = join '/', @parts;
	my @upper = @parts;
	pop @upper if scalar @upper;
	return {
		base => $base,
		relative => $inside,
		parent => $base . (scalar @upper ? '/' . join('/', @upper) : ''),
		path => $base . (length $inside ? '/' . $inside : '')
	};
}

# Bring something the archive holds back to this machine, into the place it came
# from: a whole folder - a series, an album - or one file. A folder is read out
# of the archive's manifest, so nothing walks the far disk over the tunnel, and
# each file is streamed down rather than pulled into memory, since a fetched
# video is a video. Anything already here, at the same size, is left alone.
sub archive_fetch_home_job {
	my ($job, $data) = @_;
	my $agent = &remote_agent_for($data->{'remote_uuid'});
	if ($agent->{'error'}) { $job->fail($agent->{'error'}); return }
	my $ua = $agent->{'ua'};
	my $manager = $agent->{'manager'};
	my $dest = &archive_local_destination({ location => $data->{'location'}, relative => $data->{'relative'} });
	if ($dest->{'error'}) { $job->fail($dest->{'error'}); return }

	my @files;
	if ($data->{'folder'}) {
		my $manifest = &archive_manifest_fetch({ remote_uuid => $data->{'remote_uuid'}, location => $data->{'location'} });
		if ($manifest->{'error'}) { $job->fail($manifest->{'error'}); return }
		my $folder = $manifest->{'folder'} || '';
		my $prefix = length $dest->{'relative'} ? $dest->{'relative'} . '/' : '';
		foreach my $row ( @{$manifest->{'rows'} || []} ) {
			my $relative = $row->{'relative'} || '';
			next unless length $relative;
			next if (length $prefix && index($relative, $prefix) != 0);
			push @files, { relative => $relative, size => $row->{'size'}, mtime => $row->{'mtime'}, path => (length $folder ? $folder . '/' . $relative : $relative) };
		}
	}
	else {
		push @files, { relative => $dest->{'relative'}, path => $data->{'archive_path'}, mtime => $data->{'mtime'} };
	}

	my ($fetched, $skipped, $bytes, $count) = (0, 0, 0, 0);
	my @errors;
	foreach my $file ( @files ) {
		$count++;
		my $into = &archive_local_destination({ location => $data->{'location'}, relative => $file->{'relative'} });
		if ($into->{'error'}) { push @errors, $file->{'relative'} . ': ' . $into->{'error'}; next }
		next unless (defined $file->{'path'} && length $file->{'path'});
		if (-e $into->{'path'}) {
			my $size = -s $into->{'path'};
			if (defined $file->{'size'} && defined $size && $size == $file->{'size'}) { $skipped++; next }
		}
		Mojo::File->new($into->{'parent'})->make_path;
		my $url = $manager . '/file_open?file=' . url_escape $file->{'path'};
		# streamed to the file, draining what has arrived each time so a long
		# video never lands in memory whole
		my $fh;
		my $write_error;
		my $last_tx;
		my $done;
		$ua->get($url => sub {
			my ($ua, $tx) = @_;
			$last_tx = $tx;
			my $res = $tx->res;
			my $chunk = $res->body;
			if (defined $chunk && length $chunk) {
				unless ($fh) {
					open my $open, '>', $into->{'path'} or do { $write_error = 'cannot write ' . $into->{'path'}; return };
					$fh = $open;
				}
				print {$fh} $chunk;
				$res->body('');
			}
			$done = 1 if ($res->is_finished || $res->error);
		});
		# the callback form is the non-blocking one, so the loop has to be
		# driven until the response is in hand
		Mojo::IOLoop->one_tick until $done;
		close $fh if $fh;
		if ($write_error) { push @errors, $file->{'relative'} . ': ' . $write_error; next }
		# a callback form of get returns the transaction's id, not the
		# transaction, so the outcome is taken from the last one it handed back
		unless ($last_tx && $last_tx->res->is_success && -e $into->{'path'}) {
			my $why = ($last_tx && $last_tx->res->error) ? $last_tx->res->error->{'message'} : 'the download failed';
			push @errors, $file->{'relative'} . ': ' . $why;
			next;
		}
		utime $file->{'mtime'}, $file->{'mtime'}, $into->{'path'} if ($file->{'mtime'} && $file->{'mtime'} =~ /^\d+$/);
		$fetched++;
		$bytes += (-s $into->{'path'}) || 0;
		$job->note(progress => "fetched $fetched, skipped $skipped, $bytes bytes") if $count % 5 == 0;
	}

	my $result = {
		fetched => $fetched,
		skipped => $skipped,
		bytes => $bytes,
		files => scalar @files,
		location => $data->{'location'},
		relative => $data->{'relative'},
		archive_host => $agent->{'hostname'}
	};
	if (scalar @errors) {
		$result->{'errors'} = \@errors;
		$job->fail($result);
		return;
	}
	$job->note(progress => "fetched $fetched, skipped $skipped, $bytes bytes");
	$job->finish($result);
}

# Ask the machine holding a path what it is: which location it belongs to and
# where it sits inside it. Only the machine that owns the drive can answer,
# because only it knows its own archive root.
sub archive_remote_locate {
	my $data = shift;
	my $agent = &remote_agent_for($data->{'remote_uuid'});
	return { error => $agent->{'error'} } if $agent->{'error'};
	my $res = eval {
		return $agent->{'ua'}->post($agent->{'manager'} . '/manager/folders/archive/locate' => form => {
			path => $data->{'path'}
		})->result->json;
	};
	return { error => 'the archive machine did not answer' } unless ($res && $res->{'status'} eq 'ok');
	return $res;
}

# The files a folders selection names: every file, with folders walked, so a
# job can take a selection straight from the menu and a folder added to since
# the menu was drawn is still covered.
sub folders_job_files {
	my $items = shift || [];
	my @files;
	foreach my $item ( @{$items} ) {
		my $path = $item->{'path'};
		next unless (defined $path && length $path && -e $path);
		if (-d $path) {
			push @files, &dir_listing([$path], 1);
		}
		else { push @files, $path; }
	}
	return sort @files;
}

# Take something off the disk for good, folders with everything in them.
# Returns nothing when it went, and a line saying why not when it did not.
sub folders_job_take_away {
	my $path = shift;
	return 'no path' unless (defined $path && length $path);
	return $path . ': it is not there' unless -e $path;
	return undef if (!-d $path && unlink $path);
	my $errors;
	File::Path::remove_tree($path, { error => \$errors });
	return $path . ': it could not be taken away' if (ref $errors && scalar @{$errors});
	return undef;
}

# Shred something: every file is overwritten where it lies and the folders they
# sat in go with them. Shredding is for files that should not be readable
# again, which is why the encryption turns to it too.
sub folders_job_shred {
	my $path = shift;
	return 'no path' unless (defined $path && length $path);
	return $path . ': it is not there' unless -e $path;
	if (!-d $path) {
		my $status = system('shred', '-u', $path);
		return $path . ': it could not be shredded' if $status != 0;
		return undef;
	}
	foreach my $file ( &folders_job_files([ { path => $path } ]) ) {
		my $status = system('shred', '-u', $file);
		return $file . ': it could not be shredded' if $status != 0;
	}
	return &folders_job_take_away($path);
}

# The appointment entries that name a path, or a file under it when the path is
# a folder, so the folders app can hand a file an appointment has attached to
# the app's own file deletion - which lets the appointment go of it, takes the
# thumb with it, and tells the other machines - rather than pulling it out from
# under the row. Each answer is an appointment and the entry in it to delete.
sub folders_appt_entries {
	my $path = shift;
	return [] unless (defined $path && length $path);
	my @names = (-d $path) ? &folders_job_files([ { path => $path } ]) : ( $path );
	my %wanted = map { $_ => 1 } @names;
	my $appts = eval { &db_query('select app, uuid, file from appointments where file is not null and file != ?', '')->hashes } || [];
	my @found;
	foreach my $appt ( @{$appts} ) {
		my $entries = eval { return decode_json $appt->{'file'} };
		next unless ref $entries;
		$entries = [ $entries ] if (ref $entries eq 'HASH');
		foreach my $entry ( @{$entries} ) {
			next unless ref $entry;
			next unless (defined $entry->{'uuid'} && length $entry->{'uuid'});
			my $named = (defined $entry->{'f'} && $wanted{ $entry->{'f'} })
				|| (defined $entry->{'thumb'} && $wanted{ $entry->{'thumb'} });
			next unless $named;
			push @found, { app => $appt->{'app'}, app_uuid => $appt->{'uuid'}, file_uuid => $entry->{'uuid'} };
		}
	}
	return \@found;
}

# Whether a decoded thing names a path, anywhere inside it: an entry's f or
# thumb, an attachment wrapped around an entry, or a bare path in a list.
sub folders_entry_names {
	my ($blob, $wanted) = @_;
	return 0 unless ref $blob;
	if (ref $blob eq 'ARRAY') {
		foreach my $item ( @{$blob} ) {
			return 1 if &folders_entry_names($item, $wanted);
		}
	}
	elsif (ref $blob eq 'HASH') {
		foreach my $kind ( qw/f thumb/ ) {
			return 1 if (defined $blob->{$kind} && $wanted->{ $blob->{$kind} });
		}
		foreach my $key ( keys %{$blob} ) {
			next unless ref $blob->{$key};
			return 1 if &folders_entry_names($blob->{$key}, $wanted);
		}
	}
	return 0;
}

# ---- cloud sync -----------------------------------------------------------
#
# A CloudSync folder is a little mesh: every device that holds it watches its
# own copy and pushes what changed to the others. The machine that started the
# sync registers the folder on each chosen device, so each of them has the same
# member list and the same job.
#
# Each device keeps its own state (in this machine's cache table, never inside
# the folder): what it last agreed each file was, what it has seen deleted, and
# what it still has to deliver. That is what lets an offline device's edit and
# another device's deletion be compared by time instead of one silently
# winning. A conflict keeps both copies: the deterministic winner stays at the
# name and the loser is saved beside it as .conflict-<hash>.
#
# The cache table is this machine's own view and never syncs, which is why it
# holds both the registrations and the per-base state. It outlives a restart,
# unlike ~/.president; the old JSON files there are now only a migration source.

sub cloud_sync_state_empty {
	return { files => {}, deleted => {}, pending => [] };
}

sub cloud_sync_state_normalize {
	my $state = shift;
	$state = {} unless ref $state eq 'HASH';
	$state->{'files'} = {} unless ref $state->{'files'} eq 'HASH';
	$state->{'deleted'} = {} unless ref $state->{'deleted'} eq 'HASH';
	$state->{'pending'} = [] unless ref $state->{'pending'} eq 'ARRAY';
	return $state;
}

sub cloud_sync_state_dir {
	return &home('~/.president/cloud_sync');
}

# The old per-base state file. Nothing writes here any more: a state that is
# still on disk is adopted once, on the first read, and then left alone.
sub cloud_sync_state_path {
	my $base = defined $_[0] ? $_[0] : '';
	return &cloud_sync_state_dir() . '/' . sha256_hex($base) . '.json';
}

# A transient lock under ~/.president, not inside the folder, so two devices
# pushing the same path cannot write one partial at the same time. The lock
# file must never become sync content. It is runtime only: the cache holds the
# permanent state.
sub cloud_sync_lock_path {
	my $path = defined $_[0] ? $_[0] : '';
	my $dir = &cloud_sync_state_dir() . '/locks';
	File::Path::make_path($dir) unless -d $dir;
	return $dir . '/' . sha256_hex($path) . '.lock';
}

# Open one lock file and take it exclusively. The caller closes the handle to
# release the lock; the file itself is only a rendezvous, never data.
sub cloud_sync_lock_open {
	my $key = defined $_[0] ? $_[0] : '';
	my $path = &cloud_sync_lock_path($key);
	my $fh;
	open($fh, '>>', $path) or return undef;
	flock($fh, LOCK_EX);
	return $fh;
}

# The state as the cache has it, or undef when there is no row yet.
sub cloud_sync_state_cache {
	my $base = defined $_[0] ? $_[0] : '';
	my $state = eval { &subs::cache_get({
		app => 'folders', context => 'cloud_sync_state', subcontext => sha256_hex($base)
	}) };
	return undef unless ref $state eq 'HASH';
	return &cloud_sync_state_normalize($state);
}

# The state written before the cache held it, at the old per-base path.
sub cloud_sync_state_legacy {
	my $base = defined $_[0] ? $_[0] : '';
	my $path = &cloud_sync_state_path($base);
	return &cloud_sync_state_empty() unless -e $path;
	my $raw = eval { read_file($path) };
	my $state = (defined $raw && length $raw) ? eval { decode_json($raw) } : undef;
	return &cloud_sync_state_normalize($state);
}

sub cloud_sync_state_read {
	my $base = defined $_[0] ? $_[0] : '';
	my $state = &cloud_sync_state_cache($base);
	return $state if $state;
	# The first read after an upgrade adopts the old file, once. The lock keeps
	# two processes from migrating the same base at the same time. Without it,
	# serve what the old file has and write nothing rather than race a writer.
	my $lock = &cloud_sync_lock_open('state:' . $base);
	return &cloud_sync_state_legacy($base) unless $lock;
	$state = &cloud_sync_state_cache($base);
	unless ($state) {
		$state = &cloud_sync_state_legacy($base);
		&subs::cache_set({
			app => 'folders', context => 'cloud_sync_state', subcontext => sha256_hex($base), warranty => '100y'
		}, $state);
	}
	close $lock if $lock;
	return $state;
}

# Read, change and write one device's state under one exclusive lock, so a
# receive in the web process and a sweep in the worker cannot lose each
# other's entries.
sub cloud_sync_state_modify {
	my ($base, $code) = @_;
	$base = '' unless defined $base;
	my $lock = &cloud_sync_lock_open('state:' . $base);
	return { error => 'the state could not be locked' } unless $lock;
	my $state = &cloud_sync_state_cache($base) || &cloud_sync_state_legacy($base);
	my $answer = $code->($state);
	# A scan that found nothing must not rewrite a large state row every
	# minute. Callers that change state leave __dirty unset or true.
	my $dirty = $state->{'__dirty'};
	delete $state->{'__dirty'};
	if (!defined $dirty || $dirty) {
		&subs::cache_set({
			app => 'folders', context => 'cloud_sync_state', subcontext => sha256_hex($base), warranty => '100y'
		}, $state);
	}
	close $lock if $lock;
	return $answer;
}

sub cloud_sync_pending_id {
	return &rightNow() . '-' . &random_string_creator(8);
}

sub cloud_sync_pending_clear {
	my ($state, $rel) = @_;
	$state->{'pending'} = [ grep { ($_->{'rel'} || '') ne ($rel || '') } @{ $state->{'pending'} || [] } ];
	return;
}

sub cloud_sync_pending_add {
	my ($state, $change) = @_;
	my $entry = { %{$change || {}} };
	$entry->{'id'} = &cloud_sync_pending_id() unless $entry->{'id'};
	&cloud_sync_pending_clear($state, $entry->{'rel'});
	push @{ $state->{'pending'} }, $entry;
	return $entry;
}

sub cloud_sync_pending_remove {
	my ($state, $ids) = @_;
	my %drop = map { $_ => 1 } @{ $ids || [] };
	$state->{'pending'} = [ grep { !$drop{$_->{'id'} || ''} } @{ $state->{'pending'} || [] } ];
	return;
}

# Remember which undelivered changes a pass could not make, and whether a device
# answered at all, so the listing can show a red cross (a refusal) or a yellow
# question mark (nothing was reached). The mark rides the pending entry, which
# is already the record of what has not reached every device; a later pass that
# touches the same change clears it, and a change this pass did not try keeps
# whatever mark it already had.
sub cloud_sync_pending_mark {
	my ($state, $attempted, $errors, $unreached) = @_;
	my $tried = (ref $attempted eq 'HASH') ? $attempted : {};
	my $why = (ref $errors eq 'HASH') ? $errors : {};
	my $blind = (ref $unreached eq 'HASH') ? $unreached : {};
	foreach my $entry ( @{ $state->{'pending'} || [] } ) {
		my $id = defined $entry->{'id'} ? $entry->{'id'} : '';
		next unless (length $id && $tried->{$id});
		my $error = $why->{$id};
		if (defined $error && length $error) {
			$entry->{'error'} = $error;
			if ($blind->{$id}) { $entry->{'unreached'} = 1; }
			else { delete $entry->{'unreached'}; }
		}
		else {
			delete $entry->{'error'};
			delete $entry->{'unreached'};
		}
	}
	return;
}

# A deletion time travels as a form value between machines, and `time()` is the
# hi-res one in this package, so a queued change can carry a fraction
# (1794376135.87). stat() reports whole seconds, so floor it there. A missing or
# unreadable time is not epoch 0: that made every existing file look newer than
# the deletion and turned the delete into a silent "kept".
sub cloud_sync_deleted_at {
	my $value = shift;
	return undef unless (defined $value && $value =~ /^\s*(\d+)(?:\.\d*)?\s*$/);
	my $seconds = 0 + $1;
	return undef unless $seconds > 0;
	return $seconds;
}

sub cloud_sync_relative_for {
	my ($root, $file) = @_;
	return '' unless (defined $root && defined $file);
	my $relative = substr($file, length($root));
	$relative =~ s{^/+}{};
	return $relative;
}

# Which copy wins when two devices hold different bytes. Time first; an equal
# time is decided by the content hash, so both devices choose the same winner
# and the result cannot ping-pong.
sub cloud_sync_conflict_choice {
	my ($local_mtime, $incoming_mtime, $local_hash, $incoming_hash) = @_;
	$local_mtime = 0 unless (defined $local_mtime && $local_mtime =~ /^\d+$/);
	$incoming_mtime = 0 unless (defined $incoming_mtime && $incoming_mtime =~ /^\d+$/);
	return 'incoming' if $incoming_mtime > $local_mtime;
	return 'local' if $local_mtime > $incoming_mtime;
	return 'same' if (defined $local_hash && defined $incoming_hash
		&& length $local_hash && length $incoming_hash && $local_hash eq $incoming_hash);
	return 'local' unless (defined $incoming_hash && length $incoming_hash);
	return 'incoming' unless (defined $local_hash && length $local_hash);
	return ($incoming_hash gt $local_hash) ? 'incoming' : 'local';
}

# The name a losing copy is kept under. The hash makes the same loser get the
# same name on every device, so two devices that save it do not multiply it.
sub cloud_sync_conflict_path {
	my ($dest, $hash) = @_;
	my $tag = (defined $hash && $hash =~ /^([0-9a-f]{8})/i) ? lc $1 : 'copy';
	my $base = $dest->{'path'} . '.conflict-' . $tag;
	my $path = $base;
	my $n = 1;
	while (-e $path) {
		# The same loser may already be saved under this name on another
		# device. Reuse it rather than make a second copy of the same bytes.
		if (defined $hash && -f $path) {
			my $have = &archive_file_digest($path);
			return {
				path => $path,
				relative => &cloud_sync_relative_for($dest->{'root'}, $path),
				parent => $dest->{'parent'}
			} if (defined $have && $have eq $hash);
		}
		$path = $base . '.' . $n;
		$n++;
	}
	my @parts = split '/', $path;
	my $name = pop @parts;
	return {
		path => $path,
		relative => &cloud_sync_relative_for($dest->{'root'}, $path),
		parent => join('/', @parts)
	};
}

# A received upload's last step. The caller has the complete bytes in the
# partial; this decides whether they replace the local file, become a conflict
# copy, or lose to a newer deletion. State and files are changed under one
# state lock, so a sweep sees the result whole.
sub cloud_sync_finalize_upload {
	my $data = shift || {};
	my $base = $data->{'base'};
	my $dest = $data->{'dest'} || {};
	my $part = $data->{'part'};
	my $meta_path = $data->{'meta_path'};
	my $mtime = $data->{'mtime'};
	$mtime = 0 unless (defined $mtime && $mtime =~ /^\d+$/);
	my $incoming_hash = (defined $data->{'hash'} && length $data->{'hash'})
		? $data->{'hash'} : &archive_file_digest($part);
	return { error => 'the upload could not be read' } unless defined $incoming_hash;
	my $final_path = $dest->{'path'};
	my $rel = $dest->{'relative'};
	return { error => 'no destination' } unless (defined $final_path && defined $rel);

	my $answer = &cloud_sync_state_modify($base, sub {
		my $state = shift;
		my $tomb = $state->{'deleted'}->{$rel};
		my $exists = -f $final_path ? 1 : 0;
		my @stat = $exists ? stat($final_path) : ();
		my $local_mtime = $exists ? ($stat[9] || 0) : 0;
		my $local_size = $exists ? ($stat[7] || 0) : 0;
		my $incoming_size = -s $part;
		$incoming_size = 0 unless defined $incoming_size;
		# A copy the person deleted stays deleted, whichever side still holds
		# one. The tombstone is compared with the upload's time even when a copy
		# is already on disk here, because that copy is exactly the stale one a
		# peer keeps pushing back; asking only when the file was absent let the
		# next sweep bring it in on time alone. Nothing is written for a refusal:
		# a fresh tombstone time each pass would look like a new deletion to the
		# sender and the two sides would never agree.
		if (defined $tomb && $tomb >= $mtime) {
			unlink $part if -e $part;
			unlink $meta_path if ($meta_path && -e $meta_path);
			$state->{'__dirty'} = 0;
			return { accepted => 0, kept => 'deleted', deleted_at => 0 + $tomb };
		}
		my $local_hash;
		# A hash is only needed where it decides something: identical bytes
		# under different times, or a real tie. The common changed file is
		# settled by its time.
		if ($exists && ($local_size == $incoming_size || $local_mtime == $mtime)) {
			$local_hash = &archive_file_digest($final_path);
		}

		if ($exists && defined $local_hash && $local_hash eq $incoming_hash) {
			unless (rename($part, $final_path)) {
				return { error => 'the identical copy could not be moved into place' };
			}
			utime $mtime, $mtime, $final_path if $mtime;
			$state->{'files'}->{$rel} = { size => $local_size, mtime => $mtime, hash => $incoming_hash };
			delete $state->{'deleted'}->{$rel};
			&cloud_sync_pending_clear($state, $rel);
			unlink $meta_path if ($meta_path && -e $meta_path);
			return { accepted => 1, same => 1, hash => $incoming_hash };
		}

		my $choice = $exists
			? &cloud_sync_conflict_choice($local_mtime, $mtime, $local_hash, $incoming_hash)
			: 'incoming';

		if ($choice eq 'local') {
			# The local copy wins. Keep the incoming bytes beside it and mark
			# the local copy as changed, so the next sweep pushes the winner
			# back to the sender.
			my $conflict = &cloud_sync_conflict_path($dest, $incoming_hash);
			File::Path::make_path($conflict->{'parent'}) unless -d $conflict->{'parent'};
			unless (rename($part, $conflict->{'path'})) {
				return { error => 'the losing copy could not be kept' };
			}
			utime $mtime, $mtime, $conflict->{'path'} if $mtime;
			delete $state->{'files'}->{$rel};
			&cloud_sync_pending_clear($state, $rel);
			unlink $meta_path if ($meta_path && -e $meta_path);
			return {
				accepted => 0,
				kept => 'local',
				mtime => $local_mtime,
				hash => $local_hash,
				conflict => 1,
				saved => $conflict->{'relative'}
			};
		}

		# The incoming copy wins. A different local copy is kept under its
		# own conflict name before the winner takes the original place.
		my $saved;
		if ($exists) {
			my $loser_hash = $local_hash || &archive_file_digest($final_path);
			my $conflict = &cloud_sync_conflict_path($dest, $loser_hash);
			File::Path::make_path($conflict->{'parent'}) unless -d $conflict->{'parent'};
			unless (rename($final_path, $conflict->{'path'})) {
				return { error => 'the local copy could not be kept' };
			}
			utime $local_mtime, $local_mtime, $conflict->{'path'} if $local_mtime;
			$saved = $conflict->{'relative'};
		}
		unless (rename($part, $final_path)) {
			rename($saved ? $dest->{'root'} . '/' . $saved : '', $final_path) if $saved && -e $dest->{'root'} . '/' . $saved;
			return { error => 'the verified copy could not be moved into place' };
		}
		utime $mtime, $mtime, $final_path if $mtime;
		$state->{'files'}->{$rel} = { size => (-s $final_path || 0), mtime => $mtime, hash => $incoming_hash };
		delete $state->{'deleted'}->{$rel};
		&cloud_sync_pending_clear($state, $rel);
		unlink $meta_path if ($meta_path && -e $meta_path);
		return { accepted => 1, conflict => ($saved ? 1 : 0), saved => $saved, hash => $incoming_hash };
	});
	return $answer;
}

# A peer saying a path is gone. The local copy stays if it was edited after
# the deletion; that edit is then marked as changed so it travels back.
sub cloud_sync_apply_delete {
	my ($base, $dest, $deleted_at) = @_;
	$deleted_at = &cloud_sync_deleted_at($deleted_at);
	return { error => 'the deletion has no time' } unless defined $deleted_at;
	return { error => 'no destination' } unless (ref $dest eq 'HASH' && defined $dest->{'path'});
	my $rel = $dest->{'relative'};
	return &cloud_sync_state_modify($base, sub {
		my $state = shift;
		my $path = $dest->{'path'};
		my $exists = -f $path ? 1 : 0;
		my $mtime = $exists ? ((stat($path))[9] || 0) : 0;
		if ($exists && $mtime > $deleted_at) {
			# The local copy was edited after the deletion, so the edit wins.
			# Queue it as a change of its own: it travels back to the device
			# that deleted the file and supersedes its tombstone there. Without
			# this the sender's deletion stayed pending against a file nobody
			# would remove, or was cleared as if the peer had taken it.
			my $size = -s $path;
			$size = 0 unless defined $size;
			my $hash = &archive_file_digest($path);
			$state->{'files'}->{$rel} = { size => $size, mtime => $mtime, hash => $hash };
			&cloud_sync_pending_add($state, {
				kind => 'file',
				rel => $rel,
				size => $size,
				mtime => $mtime,
				hash => $hash
			});
			return { deleted => 0, kept => 1, mtime => $mtime, hash => $hash };
		}
		unlink $path if $exists;
		my $old = $state->{'deleted'}->{$rel};
		$state->{'deleted'}->{$rel} = ($old && $old > $deleted_at) ? $old : $deleted_at;
		delete $state->{'files'}->{$rel};
		&cloud_sync_pending_clear($state, $rel);
		return { deleted => $exists, kept => 0, deleted_at => $state->{'deleted'}->{$rel} };
	});
}

# The device list a CloudSync folder may use: every peer in the house, with the
# free space on the volume its copy would land on. A device that cannot answer,
# or cannot hold the source, is returned with ok => 0 and the reason, so the
# dialog can say why its box is disabled rather than silently omit it.
sub cloud_sync_space_rows {
	my ($base, $bytes) = @_;
	my $machines = &remote_machine_lister({ self => 'no' }) || [];
	my %seen;
	my @rows;
	foreach my $rm ( @{$machines} ) {
		next unless ref $rm eq 'HASH';
		next if (($rm->{'mirror'} || '') eq 'yes');
		my $uuid = $rm->{'uuid'} || '';
		next unless length $uuid && !$seen{$uuid}++;
		my $hostname = $rm->{'hostname'} || $rm->{'fqdn'} || $rm->{'ip'} || $uuid;
		my $space = { status => 'error', error => 'that machine did not answer' };
		my $agent = eval { return &remote_agent_for($uuid) };
		if ($agent && !$agent->{'error'}) {
			$agent->{'ua'}->request_timeout(6);
			$agent->{'ua'}->inactivity_timeout(6);
			$agent->{'ua'}->connect_timeout(6);
			my $tx = eval {
				return $agent->{'ua'}->post($agent->{'manager'} . '/manager/folders/cloud/space' => form => {
					base => $base
				})
			};
			my ($res, $err) = &archive_reply($tx);
			if ($res && $res->{'status'} eq 'ok') { $space = $res; }
			else { $space = { status => 'error', error => $err || ($res && $res->{'error'}) || 'that machine did not answer' }; }
		}
		else {
			$space = { status => 'error', error => ($agent && $agent->{'error'}) || 'that machine is not registered' };
		}
		my $free = (defined $space->{'free_bytes'} && $space->{'free_bytes'} =~ /^\d+$/) ? 0 + $space->{'free_bytes'} : undef;
		my $needed = (defined $bytes && $bytes =~ /^\d+$/) ? 0 + $bytes : 0;
		push @rows, {
			uuid => $uuid,
			signatorial => $rm->{'signatorial'},
			hostname => $hostname,
			free_bytes => $free,
			free_human => (defined $free ? &data_size($free) : ''),
			needed => $needed,
			enough => (defined $free && $free >= $needed) ? 1 : 0,
			ok => (defined $free && $free >= $needed) ? 1 : 0,
			error => $space->{'error'}
		};
	}
	return \@rows;
}

# The free space on the volume a path is (or will be) on. A copy folder that
# does not exist yet is measured on the nearest ancestor that does, because a
# mount that has not come up must never look like an empty disk.
sub cloud_sync_free_space {
	my $path = shift;
	return { status => 'error', error => 'no folder to measure' } unless (defined $path && length $path);
	my $probe = $path;
	$probe =~ s{/+$}{} unless $probe eq '/';
	$probe = '/' unless length $probe;
	while (!-e $probe && $probe ne '/') {
		$probe =~ s{/[^/]+$}{};
		$probe = '/' unless length $probe;
	}
	my @lines;
	if (open(my $df, '-|', 'df', '-Pk', '--', $probe)) {
		while (defined(my $line = <$df>)) { push @lines, $line; }
		close $df;
	}
	my @f = split /\s+/, ($lines[-1] // '');
	if (scalar @f < 4 || $f[3] !~ /^\d+$/) {
		return { status => 'error', error => 'the free space could not be read', path => $path, probe => $probe };
	}
	return {
		status => 'ok',
		path => $path,
		probe => $probe,
		free_bytes => 0 + $f[3] * 1024,
		used_bytes => 0 + $f[2] * 1024,
		total_bytes => 0 + $f[1] * 1024
	};
}

# The source folder named the way every device can resolve it: relative to
# home. CloudSync only carries folders inside the person's home, because that
# is the one root every member has (a phone's own home is not this machine's),
# so a folder outside home has no shared base at all.
sub cloud_sync_base_for {
	my $path = shift;
	return '' unless (defined $path && length $path);
	$path = &home($path);
	$path =~ s{/+$}{} unless $path eq '/';
	my $home = &home('~');
	$home =~ s{/+$}{} unless $home eq '/';
	return '' if ($path eq $home);
	return '' unless &subs::path_is_under($path, $home);
	return substr($path, length($home) + 1);
}

# A file's place on the destination, from the shared base and a path inside
# it. The base is always home-relative: an absolute one would name this
# machine's home on every other device. `..` resolves against what came before
# it and cannot climb above the base, because the source names both and the
# destination must never be talked into writing outside the folder the person
# chose.
sub cloud_sync_destination {
	my $data = shift || {};
	my $base = defined $data->{'base'} ? $data->{'base'} : '';
	return { error => 'no destination' } unless length $base;
	return { error => 'destination is outside the house' } if $base =~ m{^/};
	my $home = &home('~');
	$home =~ s{/+$}{} unless $home eq '/';
	my $root = &home('~/' . $base);
	$root =~ s{/+$}{} unless $root eq '/';
	return { error => 'no destination' } unless length $root;
	# The member list cannot nominate anything outside the person's home, so
	# a stale or hostile base cannot reach /etc or another user's directory.
	return { error => 'destination is outside the house' }
		unless &subs::path_is_under($root, $home);
	# A hidden folder is not a shared destination: it is where the house keeps
	# its secrets, and a peer names both halves of this path.
	foreach my $part (split m{/+}, $base . '/' . ($data->{'path'} // '')) {
		next if $part eq '' || $part eq '.';
		return { error => 'a hidden folder is not a sync destination' } if $part =~ /^\./ && $part ne '..';
	}
	my @parts;
	foreach my $part (split m{/+}, ($data->{'path'} // '')) {
		next if $part eq '' || $part eq '.';
		if ($part eq '..') { pop @parts; next; }
		push @parts, $part;
	}
	my $relative = join '/', @parts;
	my @parent = @parts;
	pop @parent if scalar @parent;
	my $path = $root . (length $relative ? '/' . $relative : '');
	return { error => 'destination is outside the house' }
		unless &subs::path_is_under($path, $home);
	return {
		base => $base,
		root => $root,
		relative => $relative,
		path => $path,
		parent => $root . (scalar @parent ? '/' . join('/', @parent) : '')
	};
}

# A registration names an absolute path on THIS machine, so it is local state,
# not a shared setting. It lived in a settings row, which the house syncs: the
# source's /home/jawn/Downloads/gptpres landed on the phone, whose own root is
# under /data/data/com.jawnos/files/home, and every receive there answered "this
# folder is not registered" while the folders had already been made (2026-11-11).
# It now lives in this machine's cache table, which never syncs and survives a
# restart; ~/.president is not durable across one.

sub cloud_sync_registrations_clean {
	my $list = shift;
	return [] unless ref $list eq 'ARRAY';
	return [ grep { ref $_ eq 'HASH' && defined $_->{'path'} && length $_->{'path'} } @{$list} ];
}

# A registration is only usable on a device that shares this home: the base
# sent to peers is home-relative, and this machine's own home is the only one
# its absolute path means. Anything else arrived from another machine.
sub cloud_sync_registrations_under_home {
	my $list = shift;
	$list = &cloud_sync_registrations_clean($list);
	my $home = &home('~');
	$home =~ s{/+$}{} unless $home eq '/';
	return [ grep { &subs::path_is_under($_->{'path'}, $home) } @{$list} ];
}

sub cloud_sync_registrations_cache {
	my $list = eval { &subs::cache_get({ app => 'folders', context => 'cloud_sync' }) };
	return undef unless ref $list eq 'ARRAY';
	return &cloud_sync_registrations_clean($list);
}

# The registrations written before the cache held them: the local JSON file if
# there is one, otherwise the synced setting row. The file wins because it was
# already this machine's own view; the setting is filtered to paths under home.
sub cloud_sync_registrations_legacy {
	my $file = &cloud_sync_state_dir() . '/registrations.json';
	my $list;
	if (-e $file) {
		my $raw = eval { read_file($file) };
		$list = eval { decode_json $raw } if defined $raw && length $raw;
	}
	return &cloud_sync_registrations_under_home($list) if ref $list eq 'ARRAY';
	my $blob = eval { return &setting_grabber({ app => 'folders', setting => 'cloud_sync' }) };
	my $legacy = eval { return decode_json $blob } if (defined $blob && length $blob);
	return &cloud_sync_registrations_under_home($legacy);
}

sub cloud_sync_registrations {
	my $list = &cloud_sync_registrations_cache();
	return $list if $list;
	# The first read after an upgrade adopts the old store, once. The lock keeps
	# two processes from migrating at the same time; the legacy files stay.
	# Without it, serve the old store and write nothing rather than race.
	my $lock = &cloud_sync_lock_open('registrations');
	return &cloud_sync_registrations_legacy() unless $lock;
	$list = &cloud_sync_registrations_cache();
	unless ($list) {
		$list = &cloud_sync_registrations_legacy();
		&cloud_sync_registrations_write($list);
	}
	close $lock if $lock;
	return $list;
}

sub cloud_sync_registrations_write {
	my $list = shift;
	$list = &cloud_sync_registrations_clean($list);
	&subs::cache_set({ app => 'folders', context => 'cloud_sync', warranty => '100y' }, $list);
	return $list;
}

# Registrations are one cache row, so every writer has to take the same lock
# or a worker's job id can overwrite a folder the person just started. The
# callback changes the list in place; the write happens under the lock.
sub cloud_sync_registrations_modify {
	my $code = shift;
	my $lock = &cloud_sync_lock_open('registrations');
	my $list = &cloud_sync_registrations_cache() || &cloud_sync_registrations_legacy();
	# No lock: let the caller change a private copy, but persist nothing, so a
	# write that cannot be serialized cannot lose a concurrent one.
	return $code->($list) unless $lock;
	my $answer = $code->($list);
	&cloud_sync_registrations_write($list);
	close $lock;
	return $answer;
}

sub cloud_sync_registration_for {
	my $path = shift;
	return undef unless (defined $path && length $path);
	foreach my $reg ( @{ &cloud_sync_registrations() } ) {
		return $reg if (($reg->{'path'} || '') eq $path);
	}
	return undef;
}

sub cloud_sync_registration_for_base {
	my $base = shift;
	my $dest = &cloud_sync_destination({ base => $base, path => '' });
	return undef if $dest->{'error'};
	return &cloud_sync_registration_for($dest->{'root'});
}

# Every file of a CloudSync folder, without the old one-way manifest. A folder
# that is empty is a real answer.
sub cloud_sync_files {
	my $path = shift;
	return [] unless (defined $path && length $path && -d $path);
	return [ grep { $_ !~ m{/\.cloudsync\.json$} } &dir_listing([$path], 1) ];
}

sub cloud_sync_totals {
	my $path = shift;
	my ($files, $bytes) = (0, 0);
	foreach my $file ( @{ &cloud_sync_files($path) } ) {
		my $size = -s $file;
		$bytes += $size if defined $size;
		$files++;
	}
	return { files => $files, bytes => $bytes };
}

# One file's badge in a listing. A pending change carries the reason a delivery
# could not be made: a refusal is the red cross, a device that never answered is
# the yellow question mark because that copy's state is unknown. Without an
# error the change is still on its way (blue). A file the state agrees with, and
# whose size and time have not moved since the last sweep, is synced (green);
# one edited since the last pass is not agreed yet, so it reads as syncing.
sub cloud_sync_status_file {
	my ($state, $rel, $entry) = @_;
	return undef unless (defined $rel && length $rel);
	$state = {} unless ref $state eq 'HASH';
	foreach my $change ( @{ $state->{'pending'} || [] } ) {
		next unless (($change->{'rel'} || '') eq $rel);
		return 'syncing' unless (defined $change->{'error'} && length $change->{'error'});
		return $change->{'unreached'} ? 'unreached' : 'failed';
	}
	my $known = $state->{'files'}->{$rel};
	return 'syncing' unless $known;
	my $stat = (ref $entry eq 'HASH' && ref $entry->{'stat'} eq 'ARRAY') ? $entry->{'stat'} : [];
	my $size = (ref $entry eq 'HASH' && defined $entry->{'size'}) ? $entry->{'size'} : $stat->[7];
	my $mtime = $stat->[9];
	return 'syncing' if (defined $size && ($known->{'size'} || 0) != $size);
	return 'syncing' if (defined $mtime && ($known->{'mtime'} || 0) != $mtime);
	return 'synced';
}

# A folder's badge is the worst of what sits under it: a refused file makes the
# folder failed, a file no device took makes it unreached, an undelivered one
# makes it syncing, and a folder whose known files are all agreed is synced. A
# prefix of '' asks about the whole folder. Nothing known under it means no
# badge at all, not a green one.
sub cloud_sync_status_under {
	my ($state, $prefix) = @_;
	$state = {} unless ref $state eq 'HASH';
	my $pre = (defined $prefix && length $prefix) ? $prefix . '/' : '';
	my ($known, $syncing, $failed, $unreached) = (0, 0, 0, 0);
	foreach my $change ( @{ $state->{'pending'} || [] } ) {
		my $rel = $change->{'rel'} || '';
		next if (length $pre && index($rel, $pre) != 0);
		if (defined $change->{'error'} && length $change->{'error'}) {
			if ($change->{'unreached'}) { $unreached = 1; }
			else { $failed = 1; }
		}
		else { $syncing = 1; }
	}
	foreach my $rel ( keys %{ $state->{'files'} || {} } ) {
		next if (length $pre && index($rel, $pre) != 0);
		$known = 1;
		last;
	}
	return 'failed' if $failed;
	return 'unreached' if $unreached;
	return 'syncing' if $syncing;
	return 'synced' if $known;
	return undef;
}

# The badge every entry of a listing should wear, keyed by its absolute path.
# A listed folder that is itself a CloudSync folder shows the whole folder's
# state; inside one, each entry is judged by its own relative path. A path no
# registration covers is simply absent from the answer.
sub cloud_sync_status_marks {
	my ($folder, $entries) = @_;
	my $marks = {};
	return $marks unless (defined $folder && length $folder && ref $entries eq 'ARRAY' && scalar @{$entries});
	$folder =~ s{/+$}{} unless $folder eq '/';
	foreach my $reg ( @{ &cloud_sync_registrations() } ) {
		my $root = $reg->{'path'} || '';
		next unless length $root;
		$root =~ s{/+$}{} unless $root eq '/';
		# inside the synced folder: one judgement per listed entry
		if ($folder eq $root || &subs::path_is_under($folder, $root)) {
			my $state = &cloud_sync_state_read($reg->{'base'});
			foreach my $entry ( @{$entries} ) {
				my $path = (ref $entry eq 'HASH') ? ($entry->{'path'} || '') : '';
				next unless length $path;
				my $rel = &cloud_sync_relative_for($root, $path);
				next unless length $rel;
				my $status = (($entry->{'type'} || '') eq 'folder')
					? &cloud_sync_status_under($state, $rel)
					: &cloud_sync_status_file($state, $rel, $entry);
				$marks->{$path} = $status if $status;
			}
			next;
		}
		# the listing is the folder that holds the registered one, so that one
		# entry wears the whole folder's state (the folder entry is the synced
		# thing, and an ancestor further up is not)
		my $parent = $root;
		$parent =~ s{/[^/]+$}{};
		next unless ($parent eq $folder);
		my $state = &cloud_sync_state_read($reg->{'base'});
		my $status = &cloud_sync_status_under($state, '');
		$marks->{$root} = $status if $status;
	}
	return $marks;
}

# What changed on this device since its own last agreed state. The state is
# brought forward as changes are queued, and the changes themselves stay in
# pending until a job has delivered them. Re-reading an unchanged file reuses
# the hash already in the state, so a large folder is not hashed every minute.
# Every file, for a device that has just joined an existing folder: the other
# members consider their copies settled, so only a one-time full list can seed
# the newcomer. Hashes already in the state are reused. A seed carries the
# folder's tombstones too: a deleted file is not on disk, so a list of files
# alone would never tell the peers to delete it, and a device that still held
# an old copy would go on offering it. A copy that is not newer than its own
# tombstone is not offered at all - the deletion is the later fact.
sub cloud_sync_full_changes {
	my ($path, $base) = @_;
	my $state = &cloud_sync_state_read($base);
	my @changes;
	my %seen;
	foreach my $file ( @{ &cloud_sync_files($path) } ) {
		my $rel = &cloud_sync_relative_for($path, $file);
		next unless length $rel;
		$seen{$rel} = 1;
		my @stat = stat($file);
		my $size = $stat[7] || 0;
		my $mtime = $stat[9] || 0;
		my $tomb = $state->{'deleted'}->{$rel};
		next if (defined $tomb && $tomb >= $mtime);
		my $old = $state->{'files'}->{$rel};
		my $hash = ($old && defined $old->{'hash'} && ($old->{'size'} || 0) == $size && ($old->{'mtime'} || 0) == $mtime)
			? $old->{'hash'} : &archive_file_digest($file);
		push @changes, {
			kind => 'file',
			rel => $rel,
			size => $size,
			mtime => $mtime,
			hash => $hash
		};
	}
	foreach my $rel ( keys %{ $state->{'deleted'} } ) {
		next if $seen{$rel};
		# An unreadable time is not re-stamped: the sweep already refuses to
		# invent one, and a seed must not turn an old tombstone into a new
		# deletion on every pass.
		my $deleted_at = &cloud_sync_deleted_at($state->{'deleted'}->{$rel});
		next unless defined $deleted_at;
		push @changes, {
			kind => 'delete',
			rel => $rel,
			deleted_at => $deleted_at
		};
	}
	return \@changes;
}

sub cloud_sync_collect_changes {
	my ($path, $base) = @_;
	my @pending;
	&cloud_sync_state_modify($base, sub {
		my $state = shift;
		$state->{'__dirty'} = 0;
		my %seen;
		foreach my $file ( @{ &cloud_sync_files($path) } ) {
			my $rel = &cloud_sync_relative_for($path, $file);
			next unless length $rel;
			$seen{$rel} = 1;
			my @stat = stat($file);
			my $size = $stat[7] || 0;
			my $mtime = $stat[9] || 0;
			my $old = $state->{'files'}->{$rel};
			my $hash;
			if ($old && defined $old->{'hash'} && ($old->{'size'} || 0) == $size && ($old->{'mtime'} || 0) == $mtime) {
				$hash = $old->{'hash'};
			}
			else {
				$hash = &archive_file_digest($file);
			}
			my $changed = !$old
				|| ($old->{'size'} || 0) != $size
				|| ($old->{'mtime'} || 0) != $mtime
				|| (defined $old->{'hash'} && defined $hash && $old->{'hash'} ne $hash);
			if ($changed) {
				&cloud_sync_pending_add($state, {
					kind => 'file',
					rel => $rel,
					size => $size,
					mtime => $mtime,
					hash => $hash
				});
				$state->{'files'}->{$rel} = { size => $size, mtime => $mtime, hash => $hash };
				delete $state->{'deleted'}->{$rel};
				$state->{'__dirty'} = 1;
			}
			elsif (defined $state->{'deleted'}->{$rel}) {
				delete $state->{'deleted'}->{$rel};
				$state->{'__dirty'} = 1;
			}
		}
		foreach my $rel ( keys %{ $state->{'files'} } ) {
			next if $seen{$rel};
			# Whole seconds: stat() reports whole seconds, and the peer reads the
			# time back from a form field. A fraction was read there as 0, which
			# made every file look newer than the deletion (2026-11-11).
			my $deleted_at = int(time());
			&cloud_sync_pending_add($state, {
				kind => 'delete',
				rel => $rel,
				deleted_at => $deleted_at
			});
			delete $state->{'files'}->{$rel};
			$state->{'deleted'}->{$rel} = $deleted_at;
			$state->{'__dirty'} = 1;
		}
		@pending = map { { %{$_} } } @{ $state->{'pending'} };
	});
	return \@pending;
}

# Take a peer's newer deletion locally. Used when a push is answered with
# "you were deleted after your copy's time", so the two sides do not wait for
# another round trip.
sub cloud_sync_delete_local {
	my ($path, $base, $rel, $deleted_at) = @_;
	$deleted_at = &cloud_sync_deleted_at($deleted_at);
	return { error => 'the deletion has no time' } unless defined $deleted_at;
	my $file = $path . '/' . $rel;
	my $mtime = -f $file ? ((stat($file))[9] || 0) : 0;
	return { deleted => 0, kept => 1, mtime => $mtime } if ($mtime > $deleted_at);
	unlink $file if -f $file;
	return &cloud_sync_state_modify($base, sub {
		my $state = shift;
		my $old = $state->{'deleted'}->{$rel};
		$state->{'deleted'}->{$rel} = ($old && $old > $deleted_at) ? $old : $deleted_at;
		delete $state->{'files'}->{$rel};
		&cloud_sync_pending_clear($state, $rel);
		return { deleted => 1 };
	});
}

sub cloud_sync_self_row {
	return {
		uuid => 'self',
		signatorial => &signatorial_designer(),
		hostname => &machine_name()
	};
}

# A chosen folder as it is registered on one peer. The peer resolves the
# member names against its own roster, drops itself, and remembers the rest as
# the devices it pushes to.
sub cloud_sync_register_peer {
	my ($device, $base, $members) = @_;
	my $agent = &remote_agent_for($device->{'uuid'});
	return { error => $agent->{'error'} } if $agent->{'error'};
	$agent->{'ua'}->request_timeout(20);
	$agent->{'ua'}->inactivity_timeout(20);
	$agent->{'ua'}->connect_timeout(6);
	my $tx = eval {
		return $agent->{'ua'}->post($agent->{'manager'} . '/manager/folders/cloud/register' => form => {
			base => $base,
			members => encode_json($members || [])
		})
	};
	my ($res, $err) = &archive_reply($tx);
	return $res if ($res && $res->{'status'} eq 'ok');
	return { error => ($res && $res->{'error'}) || $err || 'the device did not register the folder' };
}

sub cloud_sync_unregister_peer {
	my ($device, $base) = @_;
	my $agent = &remote_agent_for($device->{'uuid'});
	return { error => $agent->{'error'} } if $agent->{'error'};
	$agent->{'ua'}->request_timeout(15);
	$agent->{'ua'}->inactivity_timeout(15);
	$agent->{'ua'}->connect_timeout(6);
	my $tx = eval {
		return $agent->{'ua'}->post($agent->{'manager'} . '/manager/folders/cloud/unregister' => form => {
			base => $base
		})
	};
	my ($res, $err) = &archive_reply($tx);
	return $res if ($res && $res->{'status'} eq 'ok');
	return { error => ($res && $res->{'error'}) || $err || 'the device did not stop the folder' };
}

sub cloud_sync_delete_peer {
	my ($device, $base, $rel, $deleted_at) = @_;
	my $agent = &remote_agent_for($device->{'uuid'});
	return { error => $agent->{'error'} } if $agent->{'error'};
	my $tx = eval {
		return $agent->{'ua'}->post($agent->{'manager'} . '/manager/folders/cloud/delete' => form => {
			base => $base,
			path => $rel,
			deleted_at => $deleted_at
		})
	};
	my ($res, $err) = &archive_reply($tx);
	return $res if ($res && $res->{'status'} eq 'ok');
	return { error => ($res && $res->{'error'}) || $err || 'the device did not take the deletion' };
}

sub cloud_sync_delete_agent {
	my ($agent, $base, $rel, $deleted_at) = @_;
	return { error => 'no device to ask' } unless ($agent && !$agent->{'error'});
	my $tx = eval {
		return $agent->{'ua'}->post($agent->{'manager'} . '/manager/folders/cloud/delete' => form => {
			base => $base,
			path => $rel,
			deleted_at => $deleted_at
		})
	};
	my ($res, $err) = &archive_reply($tx);
	return $res if ($res && $res->{'status'} eq 'ok');
	return { error => ($res && $res->{'error'}) || $err || 'the device did not take the deletion' };
}

# The worker half of CloudSync. A job carries the pending changes of one
# folder and pushes each to every other member. A change matters only if the
# peer does not already have it; the receiver is the one that settles a
# genuine conflict. Nothing is removed from pending unless every device was
# reached, so a sleeping machine is retried without losing the change.
sub cloud_sync_job {
	my ($job, $data) = @_;
	my $path = $data->{'path'};
	my $base = $data->{'base'};
	unless (defined $path && length $path && -d $path) {
		$job->fail('the CloudSync folder is not there');
		return;
	}
	my @devices = grep { ref $_ eq 'HASH' && defined $_->{'uuid'} && length $_->{'uuid'} } @{ $data->{'devices'} || [] };
	unless (scalar @devices) {
		$job->fail('no device is chosen for CloudSync');
		return;
	}
	my @changes = grep { ref $_ eq 'HASH' && defined $_->{'rel'} && length $_->{'rel'} } @{ $data->{'changes'} || [] };
	if ($data->{'seed'}) {
		@changes = @{ &cloud_sync_full_changes($path, $base) };
	}
	elsif ($data->{'collect'}) {
		@changes = @{ &cloud_sync_collect_changes($path, $base) };
	}
	unless (scalar @changes) {
		$job->finish({ changes => 0, devices => scalar @devices });
		return;
	}
	my $device_count = scalar @devices;
	my $bytes_total = 0;
	foreach my $change ( @changes ) {
		$bytes_total += ($change->{'size'} || 0) * $device_count if (($change->{'kind'} || '') eq 'file');
	}
	my $files_total = scalar(@changes) * $device_count;
	my $bytes_done = 0;
	my $index = 0;
	my @errors;
	my %result;
	# which change a pass tried, and why a delivery to any device was refused,
	# keyed by the pending entry's id so the state can carry the red cross
	# which change a pass tried, why a delivery to any device was refused, and
	# whether that device answered at all, keyed by the pending entry's id so the
	# state can carry the red cross or the yellow question mark
	my (%attempted, %error_for, %unreached_for);
	my $remember = sub {
		my ($change, $error, $unreached) = @_;
		my $id = (ref $change eq 'HASH') ? $change->{'id'} : undef;
		return unless (defined $id && length $id);
		$error_for{$id} = $error;
		$unreached_for{$id} = 1 if $unreached;
		return;
	};
	# A change leaves pending only when every device acknowledged it. A device
	# that could not be reached, or that kept a newer local copy, leaves its
	# change here; the next sweep retries it.
	my %settled = map { (defined $_->{'id'} && length $_->{'id'}) ? ($_->{'id'} => 1) : () } @changes;
	my $settle = sub {
		my $change = shift;
		my $id = $change->{'id'};
		delete $settled{$id} if (defined $id && length $id);
		return;
	};
	my $kept_total = 0;

	my $note = sub {
		my ($state, %extra) = @_;
		$job->note(archive => &archive_progress_view({
			state => $state,
			files => $files_total,
			index => $index,
			bytes_done => $bytes_done,
			bytes_total => $bytes_total,
			%extra
		}));
	};
	$note->('copying', bytes_done => 0);

	foreach my $device ( @devices ) {
		my $host = $device->{'hostname'} || $device->{'uuid'};
		my $agent = &remote_agent_for($device->{'uuid'});
		if ($agent->{'error'}) {
			push @errors, $host . ': ' . $agent->{'error'};
			$result{$host} = { error => $agent->{'error'} };
			# no device answered: every queued change stays behind, and the
			# listing shows the yellow question mark until a pass reaches it
			foreach my $change ( @changes ) {
				my $id = $change->{'id'};
				next unless (defined $id && length $id);
				$attempted{$id} = 1;
				$remember->($change, $agent->{'error'}, 1);
			}
			$settle->($_) foreach @changes;
			next;
		}
		my ($sent, $removed, $skipped, $kept) = (0, 0, 0, 0);
		foreach my $change ( @changes ) {
			$index++;
			my $rel = $change->{'rel'};
			my $change_id = $change->{'id'};
			$attempted{$change_id} = 1 if (defined $change_id && length $change_id);
			my $kind = $change->{'kind'} || 'file';
			my $file = $path . '/' . $rel;
			if (($job->info->{'notes'} || {})->{'cancel'}) {
				$note->('cancelled', file => $rel, file_bytes_done => 0, file_bytes_total => ($change->{'size'} || 0));
				$job->finish({ cancelled => 1, changes => scalar @changes });
				return;
			}
			if ($kind eq 'file') {
				unless (-f $file) {
					$bytes_done += ($change->{'size'} || 0);
					next;
				}
				my @stat = stat($file);
				my $size = $stat[7] || 0;
				my $mtime = $stat[9] || 0;
				my $probe_tx = eval {
					return $agent->{'ua'}->post($agent->{'manager'} . '/manager/folders/cloud/probe' => form => {
						base => $base,
						path => $rel
					})
				};
				my ($probe, $probe_error) = &archive_reply($probe_tx);
				if (!$probe || $probe->{'status'} ne 'ok') {
					my $why = ($probe && $probe->{'error'}) || $probe_error || 'the machine did not answer';
					push @errors, $host . ': ' . $rel . ': ' . $why;
					# no transaction at all means the device never answered;
					# an answer that refused the copy is a red failure
					$remember->($change, $why, ($probe_tx ? 0 : 1));
					$settle->($change);
					$bytes_done += $size;
					next;
				}
				my $partial = $probe->{'partial'} || {};
				my $partial_sender = $partial->{'sender'};
				if (defined $partial_sender && length $partial_sender && $partial_sender ne &signatorial_designer()) {
					my $stale = (defined $partial->{'started'} && $partial->{'started'} =~ /^\d+$/
						&& (&rightNow() - $partial->{'started'}) > 600000) ? 1 : 0;
					unless ($stale) {
						push @errors, $host . ': ' . $rel . ': another device is sending this file';
						$remember->($change, 'another device is sending this file');
						$settle->($change);
						$bytes_done += $size;
						next;
					}
				}
				if ($probe->{'exists'} && defined $probe->{'size'} && $probe->{'size'} == $size
					&& (!defined $probe->{'mtime'} || $probe->{'mtime'} == $mtime)) {
					$skipped++;
					$bytes_done += $size;
					$note->('copying', file => $rel, file_bytes_done => $size, file_bytes_total => $size);
					next;
				}
				if (defined $probe->{'deleted_at'} && $probe->{'deleted_at'} >= $mtime) {
					# The peer's deletion is newer than this copy. Take it now;
					# waiting would leave the two sides disagreeing.
					&cloud_sync_delete_local($path, $base, $rel, $probe->{'deleted_at'});
					$skipped++;
					$bytes_done += $size;
					next;
				}
				my $resume = &archive_resume_offset({
					file => $file,
					total => $size,
					mtime => $mtime,
					partial => $probe->{'partial'}
				});
				my $start_bytes = $bytes_done;
				my $progress = sub {
					my ($file_done, $file_total, $phase) = @_;
					my $state = (defined $phase && $phase eq 'verifying') ? 'verifying' : 'copying';
					$note->($state,
						file => $rel,
						file_bytes_done => $file_done,
						file_bytes_total => $file_total,
						bytes_done => $start_bytes + $file_done
					);
					return ((($job->info->{'notes'} || {})->{'cancel'}) ? 1 : 0);
				};
				my ($sent_bytes, $send_error, $detail) = &archive_send_file({
					ua => $agent->{'ua'},
					manager => $agent->{'manager'},
					url => '/manager/folders/cloud/receive',
					discard_url => '/manager/folders/cloud/discard',
					base => $base,
					relative => $rel,
					source => $rel,
					file => $file,
					mtime => $mtime,
					start => $resume->{'offset'} || 0,
					sender => &signatorial_designer(),
					progress => $progress
				});
				$detail = {} unless ref $detail eq 'HASH';
				if (defined $send_error && $send_error eq 'cancelled') {
					$note->('cancelled', file => $rel, file_bytes_done => 0, file_bytes_total => $size);
					$job->finish({ cancelled => 1, changes => scalar @changes });
					return;
				}
				if ($send_error) {
					push @errors, $host . ': ' . $rel . ': ' . $send_error;
					$remember->($change, $send_error);
					$settle->($change);
					$bytes_done += $size;
					next;
				}
				$sent++;
				if (($detail->{'kept'} || '') eq 'deleted'
					&& defined $detail->{'deleted_at'} && $detail->{'deleted_at'} >= $mtime) {
					&cloud_sync_delete_local($path, $base, $rel, $detail->{'deleted_at'});
				}
				$bytes_done = $start_bytes + $size;
				$note->('copying', file => $rel, file_bytes_done => $size, file_bytes_total => $size, bytes_done => $bytes_done);
			}
			else {
				my $deleted_at = &cloud_sync_deleted_at($change->{'deleted_at'});
				$deleted_at = int(time()) unless defined $deleted_at;
				if (-f $file) {
					# The file is back locally, so this deletion is obsolete.
					next;
				}
				my $res = &cloud_sync_delete_agent($agent, $base, $rel, $deleted_at);
				if ($res->{'error'}) {
					push @errors, $host . ': ' . $rel . ': ' . $res->{'error'};
					$remember->($change, $res->{'error'});
					$settle->($change);
					next;
				}
				if ($res->{'kept'}) {
					# The peer edited its copy after the deletion, so the edit
					# wins. That is not an acknowledgement: the change stays
					# pending until the peer's newer file comes back and
					# supersedes it on arrival.
					$kept++;
					$kept_total++;
					$settle->($change);
					next;
				}
				$removed++;
			}
		}
		$result{$host} = { sent => $sent, removed => $removed, skipped => $skipped, kept => $kept };
	}

	$note->('done', bytes_done => $bytes_done);
	my $final = { changes => scalar @changes, devices => $device_count, files => scalar(@changes) };
	$final->{'kept'} = $kept_total if $kept_total;
	if (scalar @errors) {
		$final->{'errors'} = \@errors;
		&cloud_sync_state_modify($base, sub {
			my $state = shift;
			&cloud_sync_pending_mark($state, \%attempted, \%error_for, \%unreached_for);
			return 1;
		});
		$job->fail($final);
		return;
	}
	my @ids = map { $_->{'id'} } grep { defined $_->{'id'} && length $_->{'id'} } @changes;
	@ids = grep { $settled{$_} } @ids;
	&cloud_sync_state_modify($base, sub {
		my $state = shift;
		&cloud_sync_pending_remove($state, \@ids);
		&cloud_sync_pending_mark($state, \%attempted, \%error_for, \%unreached_for);
		return 1;
	});
	$job->finish($final);
}

# The sweep runs in the Minion worker: a registered folder with local changes
# or undelivered ones is queued. A job that is still active is not queued a
# second time. When no device answers, the pending list is the retry.
sub cloud_sync_sweep {
	my $registrations = &cloud_sync_registrations();
	return 0 unless scalar @{$registrations};
	my $minion = &minion_grabber();
	my $queued = 0;
	my @updates;
	foreach my $reg ( @{$registrations} ) {
		next unless -d $reg->{'path'};
		my @devices = grep { ref $_ eq 'HASH' && $_->{'uuid'} } @{ $reg->{'devices'} || [] };
		next unless scalar @devices;
		# A start that died between its write and its enqueue must not block the
		# sweep for ever.
		if ($reg->{'starting'}) {
			my $age = &rightNow() - $reg->{'starting'};
			next if ($age >= 0 && $age < 300000);
		}
		if ($reg->{'job'}) {
			my $old = $minion->job($reg->{'job'});
			my $state = ($old && $old->info) ? ($old->info->{'state'} || '') : '';
			next if ($state eq 'active' || $state eq 'inactive');
		}
		my $changes = &cloud_sync_collect_changes($reg->{'path'}, $reg->{'base'});
		next unless scalar @{$changes};
		my $job_id = $minion->enqueue(cloud_sync => [ {
			path => $reg->{'path'},
			base => $reg->{'base'},
			devices => \@devices,
			changes => $changes
		} ] => { retries => 1 });
		push @updates, { path => $reg->{'path'}, job => $job_id };
		$queued++;
	}
	if (scalar @updates) {
		&cloud_sync_registrations_modify(sub {
			my $list = shift;
			foreach my $u ( @updates ) {
				foreach my $reg ( @{$list} ) {
					next unless (($reg->{'path'} || '') eq $u->{'path'});
					$reg->{'job'} = $u->{'job'};
				}
			}
			return 1;
		});
	}
	return $queued;
}

our $cloud_sync_sweep_timer;
sub cloud_sync_sweep_start {
	return 0 if $cloud_sync_sweep_timer;
	$cloud_sync_sweep_timer = Mojo::IOLoop->recurring(60 => sub {
		eval { &cloud_sync_sweep() };
		&say_it('cloud sync sweep: ' . $@) if $@;
	});
	return 1;
}

1;
