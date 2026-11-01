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

our %archive_manifest_memo;
our $device;
our %m;
our $minion;

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

sub remote_agent_for {
	my $remote_uuid = shift;
	my $rm = &remote_machine_lister({ uuid => $remote_uuid, limit => 1 });
	return { error => 'no machine is registered for ' . ($remote_uuid || '(nothing)') } unless (ref $rm && $rm->{'manager'});
	$rm = &remote_machine_tunnel_processor($rm);
	my $ua = Mojo::UserAgent->new;
	$ua->max_response_size(0);
	$ua->insecure(1);
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

sub archive_send_file {
	my $data = shift;
	my $ua = $data->{'ua'};
	my $manager = $data->{'manager'};
	my $file = $data->{'file'};
	my $total = -s $file;
	my $chunk = 64 * 1024 * 1024;
	my $post_chunk = sub {
		my ($path, $offset, $final, $chunked) = @_;
		my %form = (
			location => $data->{'location'},
			path => $data->{'relative'},
			mtime => $data->{'mtime'},
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
	if (!defined $total || $total <= $chunk) {
		my ($res, $err) = $post_chunk->($file, 0, 1, 0);
		return ($total || 0) if ($res && $res->{'status'} eq 'ok');
		return (0, ($res && $res->{'error'}) || $err || 'the upload did not land');
	}
	my ($offset, $sent) = (0, 0);
	while ($offset < $total) {
		my $take = $total - $offset > $chunk ? $chunk : $total - $offset;
		my $chunk_path = &peer_temp_file('archive_chunk');
		my ($in, $out);
		unless (open($in, '<:raw', $file)) {
			unlink $chunk_path;
			return (0, "cannot read $file");
		}
		seek($in, $offset, 0);
		unless (open($out, '>:raw', $chunk_path)) {
			close $in;
			unlink $chunk_path;
			return (0, 'cannot write a chunk for ' . $file);
		}
		my $left = $take;
		my $buf;
		while ($left > 0) {
			my $want = $left > 1024 * 1024 ? 1024 * 1024 : $left;
			my $n = read($in, $buf, $want);
			last unless $n;
			print $out $buf;
			$left -= $n;
		}
		close $in;
		close $out;
		if ($left > 0) {
			unlink $chunk_path;
			return (0, "could not read $file at $offset bytes");
		}
		my $final = ($offset + $take >= $total) ? 1 : 0;
		my ($res, $err) = $post_chunk->($chunk_path, $offset, $final, 1);
		unlink $chunk_path;
		if (!$res || $res->{'status'} ne 'ok') {
			return (0, ($res && $res->{'error'}) || $err || "the upload stopped at $offset bytes");
		}
		$sent += $take;
		$offset += $take;
	}
	return ($sent, undef);
}

sub archive_transfer_job {
	my ($job, $data) = @_;
	my $agent = &remote_agent_for($data->{'remote_uuid'});
	if ($agent->{'error'}) { $job->fail($agent->{'error'}); return; }
	my $ua = $agent->{'ua'};
	my $manager = $agent->{'manager'};

	my @files;
	if ($data->{'folder'}) {
		@files = &dir_listing([$data->{'path'}], 1);
		@files = sort @files;
	}
	else { @files = ( $data->{'path'} ) }

	my ($sent, $skipped, $bytes, $count) = (0, 0, 0, 0);
	my @errors;
	my @rows;
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

		my $probe_tx = eval {
			$ua->post($manager . '/manager/folders/archive/probe' => form => {
				location => $data->{'location'},
				path => $relative
			})
		};
		my ($probe, $probe_error) = &archive_reply($probe_tx);
		if (!$probe || $probe->{'status'} ne 'ok') {
			push @errors, ($relative || $file) . ': ' . (($probe && $probe->{'error'}) || $probe_error || 'the archive machine did not answer');
			next;
		}
		if ($probe->{'exists'} && defined $probe->{'size'} && defined $size && $probe->{'size'} == $size
			&& (!defined $probe->{'mtime'} || !defined $mtime || $probe->{'mtime'} == $mtime)) {
			$skipped++;
			next;
		}

		my ($sent_bytes, $send_error) = &archive_send_file({
			ua => $ua,
			manager => $manager,
			location => $data->{'location'},
			relative => $relative,
			file => $file,
			mtime => $mtime
		});
		if ($send_error) {
			push @errors, ($relative || $file) . ': ' . $send_error;
			next;
		}
		$sent++;
		$bytes += $sent_bytes;
		push @rows, &archive_manifest_row({ path => $file, relative => $relative });
		if ($count % 5 == 0) {
			$job->note(progress => "sent $sent, skipped $skipped, $bytes bytes");
			# a cancel asked for from the folders app cannot kill this process
			# from there, so the job stops itself at the next file
			if (($job->info->{'notes'} || {})->{'cancel'}) {
				$job->note(progress => "stopped after $count files");
				$job->finish({ sent => $sent, skipped => $skipped, bytes => $bytes, files => scalar @files, cancelled => 1 });
				return;
			}
		}
	}

	my $result = {
		sent => $sent,
		skipped => $skipped,
		bytes => $bytes,
		files => scalar @files,
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
		$job->fail($result);
		return;
	}
	$job->note(progress => "sent $sent, skipped $skipped, $bytes bytes");
	$job->finish($result);
}

sub archive_media_type {
	my $path = shift || '';
	return 'image' if $path =~ /\.(jpe?g|png|bmp|tiff?|xcf|webp|gif|heic)$/i;
	return 'audio' if $path =~ /\.(wav|mp3|aiff|weba|m4a|flac|aac|ogg|opus)$/i;
	return 'video' if $path =~ /\.(mp4|avi|mov|webm|mkv|m4v|wmv)$/i;
	return 'pdf' if $path =~ /\.pdf$/i;
	return 'document' if $path =~ /\.(docx?|xlsx?|pptx?|txt|rtf|odt)$/i;
	return 'subtitles' if $path =~ /\.(vtt|srt)$/i;
	return 'other';
}

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
	if ($type eq 'image' || $type eq 'audio' || $type eq 'video') {
		my $file_data = &file_media_information({ f => $path, type => $type });
		$row->{'info'} = $file_data->{'info'} if $file_data->{'info'};
	}
	return $row;
}

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

sub archive_image_lookup {
	my $data = shift;
	my $misc = $data->{'misc_settings'} || &subs::misc_setting_list();
	my $device = &subs::device_setter();
	my $here = $misc->{$device}->{'photo_location'};
	return {} unless $here;
	my $machines = &subs::remote_machine_lister({ self => 'no' });
	my $rm = &archive_machine_for('photo', $misc->{$device} || {}, $machines);
	return {} unless ($rm && $rm->{'uuid'});
	my $manifest = &archive_manifest_fetch({ remote_uuid => $rm->{'uuid'}, location => 'photo' });
	return {} if $manifest->{'error'};
	my $folder = $manifest->{'folder'} || '';
	my $base = &home($here);
	$base =~ s{/+$}{};
	my %rows = map { $_->{'relative'} => $_ } @{$manifest->{'rows'} || []};
	my $locate = sub {
		my $path = shift;
		return undef unless (defined $path && length $path);
		return undef unless $path =~ m{^\Q$base\E/};
		my $relative = substr($path, length($base) + 1);
		my $row = $rows{$relative};
		return undef unless ($row && ($row->{'type'} || '') eq 'image');
		return {
			path => (length $folder ? $folder . '/' . $relative : $relative),
			relative => $relative,
			remote_uuid => $rm->{'uuid'},
			remote_hostname => $manifest->{'hostname'} || ''
		};
	};
	return { locate => $locate, folder => $folder, remote_uuid => $rm->{'uuid'}, hostname => $manifest->{'hostname'} || '' };
}

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
