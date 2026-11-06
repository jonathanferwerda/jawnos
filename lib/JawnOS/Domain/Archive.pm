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
	my $tx = eval {
		return $ua->post($manager . '/manager/folders/archive/discard' => form => {
			location => $data->{'location'},
			path => $data->{'relative'},
			source => $data->{'source'}
		})
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
	my $post_chunk = sub {
		my ($path, $offset, $final, $chunked) = @_;
		my %form = (
			location => $data->{'location'},
			path => $data->{'relative'},
			mtime => $data->{'mtime'},
			source => $source,
			file => { file => $path }
		);
		if ($chunked) {
			$form{'offset'} = $offset;
			$form{'total'} = $total;
			$form{'final'} = $final ? 1 : 0;
		}
		my $tx = eval {
			$ua->post($manager . '/manager/folders/archive/receive' => form => \%form)
		};
		return &archive_reply($tx);
	};
	if ($start == 0 && (!defined $total || $total == 0)) {
		# an empty file needs no chunk and no progress; everything else is
		# streamed in pieces so the bar moves while the bytes do
		my ($res, $err) = $post_chunk->($file, 0, 1, 0);
		if ($res && $res->{'status'} eq 'ok') {
			return ($total || 0, undef, { size => ($res->{'size'} || $total || 0), sha256 => $res->{'sha256'}, resumed => 0 });
		}
		return (0, ($res && $res->{'error'}) || $err || 'the upload did not land', { resumed => 0 });
	}
	my ($offset, $sent) = ($start, 0);
	my $last_sha;
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
			&archive_discard_remote({ ua => $ua, manager => $manager, location => $data->{'location'}, relative => $data->{'relative'}, source => $source });
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
		$sent += $take;
		$offset += $take;
	}
	return ($sent, undef, { size => $total, sha256 => $last_sha, resumed => $start > 0 });
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

1;
