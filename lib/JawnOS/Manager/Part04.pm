package Manager;

# Manager helpers, part 4 of 37. Moved out of Manager.pl so a
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

sub rock_and_roll($c) {
	my $man = 'rejected';
	my $file = $c->param('file');
	# A pinned peer is a house machine: the archive rail already trusts one by
	# signature, and a remote library's covers and tracks come through this same
	# relay. Its stored session cookie dies with that machine's own tree, so a
	# track used to answer "no" while the signed manifest still worked. The
	# signature is the stronger proof, so it admits a file read on its own.
	my $peer_signed = &app_peer_ok($c) ? 1 : 0;
	# A private app's files are not served outside a private place, and inside one
	# they wait for a fingerprint: the private grant, or the Gallery/Folders/Music
	# padlock on this screen. The check is before the peer relay and before as_is,
	# so no route variant bypasses it. A signed peer relay is allowed through
	# because the asking machine already applied the same rule to its own screen.
	my $requested_file = $c->param('file') || $c->param('track') || '';
	my $private_owner = &subs::unformat_name($c->param('app') || '');
	$private_owner = &folders_owning_app($requested_file) unless length $private_owner;
	if (length $private_owner && &subs::app_private_now($private_owner)) {
		my $relay_trusted = $peer_signed && (($c->param('remoted') || '') eq 'yes' || ($c->param('subprocess') || '') eq 'yes');
		if (!$relay_trusted && (!&subs::private_reachable_now() || !&media_grant_open($c))) {
			$c->render(text => 'none');
			return;
		}
	}
	if ($c->param('remote_uuid') && $c->param('remoted') ne 'yes') {
		# a track is streamed; everything else on this relay is a bounded body
		if ($c->req->url->path eq '/play') {
			&remote_relay_media($c);
			return;
		}
		my $ru = $c->param('remote_uuid');
		# A peer that just timed out on a picture is not asked again for a minute.
		# Without this, a gallery of covers kept on an unreachable machine asked
		# the same dead peer once per image, and each attempt held a worker for the
		# connect timeout - exactly how a picture grid froze the whole manager.
		if ($file_relay_down{$ru} && &subs::rightNow() - $file_relay_down{$ru} < 60) {
			$c->render(text => 'none');
			return;
		}
		$c->param('subprocess' => 'yes');
		my $result = &remote_relay_request($c);
		if (defined $result && length $result) {
			delete $file_relay_down{$ru};
			# Relayed bytes carry no type or cache header at all, so the browser
			# had to fetch every cover again on each window open. Name the type and
			# let the picture be cached the way a local thumb is.
			my $type = &subs::plaintext_verdict(substr($result, 0, 65536));
			$c->res->headers->content_type($type) if defined $type && length $type;
			$c->res->headers->cache_control('private, max-age=3600');
			$c->render(data => $result);
		}
		else {
			$file_relay_down{$ru} = &subs::rightNow() if $c->stash('remote_relay_error');
			$c->render(text => 'none');
		}
		return;
	}
	# A thumbnail is a fixed frame of a file, so it can be cached; letting the
	# browser hold it keeps a repeat visit to the music library (which asks for a
	# thumbnail per song) from re-requesting every one. Captured before an existing
	# thumbnail swaps the file out and clears the parameter. The header itself is
	# set only on a successful response, so a rejected or 'none' one is not cached.
	my $wants_thumb = ($c->param('thumb') ? 1 : 0);
	# A hover preview asks for one frame at a position. It must be generated at
	# that position, not answered from the track's one cached cover thumbnail,
	# and it must not replace that cover.
	my $hover_position = $c->param('position');
	$hover_position = undef unless defined $hover_position && $hover_position =~ /^\d+(?:\.\d+)?$/;
	my ($db,$database,$sql) = &subs::database_grabber();

	my $mag;
	if ($peer_signed) {
		$man = 'approved';
	}
	elsif ( $c->session('authentication') ne 'approved' ) {
		my $uuid = $c->param('uuid');
		my $fq = &subs::db_query('select * from magazine where uuid = ?',$uuid );
		$mag = $fq->hashes->[0];
		if ($mag->{'status'} eq 'publish') {
			my $public = &subs::setting_grabber({ app => &subs::unformat_name($mag->{'title'}), setting => 'public' });

			if ($public eq 'on' && $mag->{'content'} =~ /$file/) {
				$man = 'approved';
			}
		}
	}
	else {
		$man = &authentication_passer($c);
	}
	if ($man eq 'approved') {
		my $tdir = $gb::tmp_dir;

		# Mojo has already decoded the query string, so use the parameter as-is. A
		# second uri_decode corrupts any name containing a literal %xx sequence
		# (100%20.mp3 -> 100 .mp3), which is exactly how a track failed to open.
		$file = $c->param('track') unless $file;
		if (!$file) {
			if ($c->param('appt_uuid') && $c->param('file_uuid') && $c->param('app')) {
				my $appt = &subs::db_select('appointments', undef, { uuid => $c->param('appt_uuid'), app => $c->param('app') })->hashes->[0];
				my $files = eval { return decode_json $appt->{'file'} } || [];
				foreach my $f ( @{$files} ) {
					if ($f->{'uuid'} eq $c->param('file_uuid')) {
						$file = $f->{'f'};
					}
				}
			}
		}
		my @ext = split /\./, $file;
		my $ext = $ext[-1];
		my $timestamp = $c->param('timestamp') || &subs::rightNow();
		my $filename = $file;
	#	return 'no' unless -e &subs::terminal_name($file);

		# as_is returns a file's bytes as-is. It is a relay for the app's own
		# files, not a general file reader: resolve the path and keep it inside
		# the app home (or the temp dir) or it is refused.
		if ($c->param('as_is')) {
			my @roots = grep { defined && length } (&subs::home('~'), $gb::tmp_dir);
			my $within = 0;
			for my $root (@roots) {
				$within = 1 if &subs::path_is_within($file, $root);
			}
			if ($within && -f $file) {
				my $data = read_file($file);
				$data = encode_base64 $data;
				$data ? $c->render(data => $data) : $c->render(text => 'none');
				return;
			}
			$c->render(text => 'not found');
			return;
		}
		my $app = &subs::unformat_name($c->param('app'));
		my $writer = {
			timestamp => $timestamp,
			app => &subs::unformat_name($mag->{'title'}) || $app,
			file => encode_json [ $file ],
			uuid => $mag->{'uuid'},
			type => 'file'
		};
		my @file_split = split /\//, $file;
		my $file_match = $file_split[-1];
		my $appt_q;
		if ($c->param('app_uuid')) {
			$appt_q = &subs::db_query('select * from appointments where uuid=? and app=? LIMIT 1',$c->param('app_uuid'), $app);
		}
		else {
			$appt_q = &subs::db_query('select * from appointments where file like ? and app=? and (server_time=? or timestamp=?) LIMIT 1','%' . $file_match . '%', $app,$timestamp,$timestamp);
		}
		my $appter = $appt_q->hashes;
		my $appt_server_time = $appter->[0]->{'server_time'};
		my $atf = eval { return decode_json $appter->[0]->{'file'} } || [];
		my $file_data = {};
		my $thumbnail_size = &subs::setting_grabber({ app => 'misc', setting => 'thumbnail_size' }) || 'none';
		foreach my $af ( @{$atf} ) {
			if ($file eq $af->{'f'}) {
				$appt_server_time = $af->{'server_time'};
				$file_data = $af;

				if ($af->{'thumb'} && $c->param('thumb') && $thumbnail_size ne 'none' && !defined $hover_position) {
					if (-e $af->{'thumb'} && (-s $af->{'thumb'}) > 100) {
						$file = $af->{'thumb'};
						$c->param('thumb' => undef);
					}
				}
			}
		}
		# A conditional request for an unchanged file stops here: no key walk, no
		# decryption, no body. The duty path is an internal collection (mail, file
		# information) and always wants the bytes, so it skips the revalidation.
		if (!$c->param('duty') && $file && -e $file && (!$wants_thumb || ($file_data->{'thumb'} && -e $file_data->{'thumb'}))) {
			my $cc = $wants_thumb ? 'private, max-age=3600' : 'private, no-cache';
			if (&file_response_cache_headers($c, $file, $cc)) {
				$c->res->code(304);
				$c->res->body('');
				return;
			}
		}
		# Do not decrypt an original and run ImageMagick while every other
		# worker is doing the same; a taken slot answers immediately instead.
		my $thumb_slot;
		if ($wants_thumb && $thumbnail_size ne 'none' && $file =~ /\.enc$/i
			&& $file_data->{'uuid'} && (!$file_data->{'thumb'} || !-e $file_data->{'thumb'})) {
			$thumb_slot = &thumb_generation_slot();
			unless ($thumb_slot) {
				&thumb_placeholder($c);
				return;
			}
		}
		if ($file =~ /\.enc$/gi) {
			# A measured track is answered before any decryption: the key walks and
			# the whole-file decrypt a sealed track needs are exactly what a cache
			# hit should skip.
			if ($c->param('loudness')) {
				if (my $cached = &media_loudness_cached($file)) {
					$c->render(json => { ok => 1, cached => 1, %{$cached} });
					return;
				}
			}
			my $encryption_standard = $appter->[0]->{'encryption_standard'} || &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || "aes-256-ctr";
			my @encryption_standards = ( $encryption_standard );
			if (!$appter->[0]->{'uuid'}) {
				my @file_splitter = split /\//, $file;

				# app=? is served by idx2_appts, so this leading-wildcard LIKE only
				# walks this app's rows; the first query above already uses a multi-index
				# OR on (app,server_time)/(app,timestamp). No table scan.
				$appt_q = &subs::db_query('select * from appointments where app = ? and file is not null and file like ?',$app,'%' . $file_splitter[-1] . '%' );
				my $apptser = $appt_q->hashes;
				# no `my` here: the timestamp found below belongs to the outer scope
				# and is what the credential history is filtered by.
				$appt_server_time = $apptser->[0]->{'server_time'};
				foreach my $at ( @{$apptser} ) {
					my $at_standard = $at->{'encryption_standard'};
					if (defined $at_standard && length $at_standard && !grep { $_ eq $at_standard } @encryption_standards) {
						push @encryption_standards, $at_standard;
					}
					my $atf = eval { return decode_json $at->{'file'} } || [];
					foreach my $af ( @{$atf} ) {
						if ($file eq ($af->{'file'} // $af->{'f'} // '')) {
							$appt_server_time = $af->{'server_time'};
							$file_data = $af;
							if ($af->{'thumb'} && $wants_thumb && $thumbnail_size ne 'none' && !defined $hover_position) {
								if (-e $af->{'thumb'} && (-s $af->{'thumb'}) > 100) {
									$file = $af->{'thumb'};
									$c->param('thumb' => undef);
								}
							}
						}
					}
				}
			}

			unless ($appt_server_time) {
				if (-e $file) {
					my @stat = stat($file);
					$appt_server_time = $stat[10] * 1000;
				}
			}
			my $suds = &subs::suds_grabber();
			my $passwords = &subs::db_query('select * from security where level != ? and level != ? and timestamp <= ? order by timestamp DESC','padlock','door',$appt_server_time);
			# Decrypt each stored credential once, then let sealed_file_open try them
			# against a 16 KB prefix instead of the whole file.
			my @secrets;
			# The current key is a candidate of its own: a file sealed while the
			# person was closing a window used the session suds, which need not be
			# one of the stored credentials below. WebM/thumb files here are sealed
			# with it, and without it they could not be opened at all.
			push @secrets, $suds if defined $suds && length $suds;
			foreach my $p ( @{ $passwords->hashes } ) {
				my $secret = &subs::decrypter($suds, $p->{'credential'}, $appt_server_time);
				push @secrets, $secret if defined $secret && length $secret;
			}
			# One Range is enough: read only the part the client asked for. A
			# thumbnail needs the whole file for ffmpeg/magick, and a PDF is handed
			# to the viewer whole, so those keep the full open.
			my $range;
			my $range_header = $c->req->headers->range;
			if (!$c->param('duty') && !$wants_thumb && $file !~ /\.pdf(?:\.enc)?$/i && defined $range_header && length $range_header) {
				if ($range_header =~ m/^bytes=(\d+)-(\d*)/) {
					my ($start, $end) = ($1, $2);
					if (!defined $end || !length $end) { $range = [ $start, undef ] }
					elsif ($end >= $start) { $range = [ $start, $end - $start + 1 ] }
				}
			}
			my $inspect = sub {
				# the plaintext's own magic, never the path: a webm that File::Type
				# calls octet-stream must still reject a wrong credential
				return &subs::plaintext_verdict($_[0]);
			};
			# A whole-file request for a big sealed file streams: the key is known
			# after the prefix probe, so the body can start before it is all decrypted.
			# A video thumbnail asks for the same pieces, but only to decrypt the head
			# of the file for ffmpeg rather than the whole thing.
			my $video_thumb = ($wants_thumb && $file =~ /\.(?:mp4|webm|mpg|mpeg|mov|mkv|avi)\.enc$/i) ? 1 : 0;
			my $want_stream = (!$range && ($video_thumb || (!$c->param('duty') && !$wants_thumb)) && $file !~ /\.pdf(?:\.enc)?$/i && (-s $file || 0) >= 2 * 1024 * 1024) ? 1 : 0;
			my $opened = &subs::sealed_file_open($file, \@secrets, \@encryption_standards, 1, $inspect, $range, $want_stream);
			if ($c->param('loudness') && $opened && !$opened->{'unsatisfiable'}) {
				my $base = $file;
				$base =~ s/\.enc$//i;
				my $ext = ($base =~ /\.([^.\/]+)$/) ? $1 : 'bin';
				my $tmp = $tdir . '/loudness_' . &subs::random_string_creator(20) . '.' . $ext;
				my $ok = 0;
				if ($opened->{'stream'}) { $ok = &sealed_file_to_path($opened, $tmp); }
				elsif (defined $opened->{'data'}) {
					write_file($tmp, $opened->{'data'});
					$ok = (-s $tmp) ? 1 : 0;
				}
				if ($ok) { &media_loudness_response($c, $tmp, $file); }
				else { $c->render(json => { ok => 0 }); }
				unlink $tmp;
				return;
			}
			if ($opened && $opened->{'stream'} && !$video_thumb) {
				if (&stream_sealed_file($c, $opened, $file, 'private, no-cache')) { return }
				# the stream could not start: fall back to the buffered body
				my $data = &subs::note_open_container($opened->{'container'}, $opened->{'secret'}, $opened->{'standard'}, 1);
				$c->render_file(data => $data) if defined $data && length $data;
				return;
			}
			if ($opened && $opened->{'unsatisfiable'}) {
				$c->res->code(416);
				$c->res->headers->content_range('bytes */' . $opened->{'total'});
				$c->res->headers->accept_ranges('bytes');
				$c->res->body('');
				return;
			}
			if ($opened) {
				my $data = $opened->{'data'};
				my $fd = $opened->{'verdict'};
				my $secret = $opened->{'secret'};
				my $filename = $file;
				$filename =~ s/\.enc$//i;
				my @ext = split /\./, $file;
				my $ext = $ext[-2];
				if ($c->param('duty')) {
							# The data URI is only read for images (the adopt list and the
							# file information card); building it for a video or PDF copied
							# the whole file for nothing.
							my $image;
							if (defined $fd && ($fd =~ m{^image/} || $file =~ /\.(?:jpe?g|png|bmp|gif|webp|tiff?)\.enc$/i)) {
								$image = 'data:' . $fd . ';base64,' . encode_base64($data,'');
							}
							return {
								data => $data,
								image => $image,
								fd => $fd,
								timestamp => $appt_server_time,
								ext => $ext
							};
						}
						elsif ($fd =~ /pdf/) {
							&file_response_headers($c, $file, 'private, no-cache');
							$data ? $c->render(format => 'pdf', data => $data) : $c->render(text => 'none');
							return;
						}
						else {
							my $full_data = $data;
							if ($c->param('thumb') eq 'ya') {

								my @filename = split /\./, $file;
								my $ext = $filename[-2];
								if (defined $hover_position || !(-e $file_data->{'thumb'} && (-s $file_data->{'thumb'}) > 100)) {
									my $filename = $tdir . '/' .&subs::random_string_creator(20) . '.' . $ext;
									if ($file =~ /webm/i) { $fd = 'video/webm'; }
									# The plaintext is already in hand for an image; for a sealed video
									# only the head is decrypted, and a prefix that yields no frame
									# falls back to the whole file below.
									if ($opened->{'stream'}) {
										&sealed_thumb_prefix($filename, $opened, 8 * 1024 * 1024);
									}
									else {
										write_file($filename, $full_data) if defined $full_data && length $full_data;
									}

									if ($file_data->{'type'} eq 'video' || grep { $_ eq $ext } qw/mp4 webm mpg mpeg mov mkv avi/ ) {
										my $seek = defined $hover_position ? sprintf('%.3f', $hover_position) : &subs::thumbnail_seek_position($c->param('duration'));
										my $command2 = 'ffmpeg -nostdin -ss ' . $seek . ' -f ' . $ext . ' -i ' . $filename . ' -vframes 1 -c:v png -f image2pipe - | magick - -resize ' . $thumbnail_size . ' - ';
										$file_data->{'type'} = 'video';
										$data = &native_thumb_png($filename, $thumbnail_size);
										$data = &run_thumb_command($command2) unless defined $data && length $data;
										if ($opened->{'stream'} && (!defined $data || !length $data)) {
											my $whole = &subs::note_open_container($opened->{'container'}, $opened->{'secret'}, $opened->{'standard'}, 1);
											if (defined $whole && length $whole) {
												write_file($filename, $whole);
												$data = &run_thumb_command($command2);
											}
										}
									}
									elsif ($file_data->{'type'} eq 'image' || grep { $_ eq $ext } qw/bmp tiff jpg png/) {
										if ($opened->{'stream'}) {
											my $whole = &subs::note_open_container($opened->{'container'}, $opened->{'secret'}, $opened->{'standard'}, 1);
											write_file($filename, $whole) if defined $whole && length $whole;
										}
										my $command2 = 'magick ' . $filename . ' -auto-orient -strip -resize ' . $thumbnail_size . ' -';
										$file_data->{'type'} = 'image';
										$data = &native_thumb_png($filename, $thumbnail_size);
										$data = &run_thumb_command($command2) unless defined $data && length $data;
									}
									if ($file_data->{'uuid'} && $data && $thumbnail_size ne 'none' && !defined $hover_position) {
										pop @file_split;
										my $folder = join '/', @file_split;
										$folder = $folder . '/.thumbs';
										`mkdir -p $folder`;
										my $worker_id = &subs::random_string_creator(10);
										my $priority = $folder . '/priority.txt';
										my $pr = eval { return decode_json read_file($priority) } || {};
										until ($pr->{$appter->[0]->{'uuid'}}->{'state'} ne 'working' || $pr->{$appter->[0]->{'uuid'}}->{'time'} < &subs::rightNow() - 6000) {
											sleep .5;
											$pr = eval { return decode_json read_file($priority) } || {};
										}
										$pr->{$appter->[0]->{'uuid'}}->{'state'} = 'working';
										$pr->{$appter->[0]->{'uuid'}}->{'time'} = &subs::rightNow();
										$pr->{$appter->[0]->{'uuid'}}->{'worker'} = $worker_id;
										my $jpr = encode_json $pr;
										write_file($priority, $jpr);
										my $path = $folder . '/' . &subs::random_string_creator(23) . '.png.enc';

										$file_data->{'thumb'} = $path;
										$file_data->{'server_time'} = &subs::rightNow();
										$file_data = &subs::file_media_information($file_data,$filename);
										write_file($filename, $data);
										&subs::seal_file($filename, $path, $secret, $encryption_standard);
										my $appt = &subs::db_select('appointments', undef, { uuid => $appter->[0]->{'uuid'}, app => $appter->[0]->{'app'} })->hashes->[0];
										$atf = eval { return decode_json $appt->{'file'} } || [];
										my @natf = grep { $_->{'uuid'} eq $file_data->{'uuid'} } @{$atf};
										if (-e $natf[0]->{'thumb'}) { my $natfthumb = $natf[0]->{'thumb'}; `shred -u $natfthumb`; }
										@{$atf} = grep { $_->{'uuid'} ne $file_data->{'uuid'} } @{$atf};

										push @{$atf}, $file_data;
										my $jdata = encode_json $atf;
										&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $jdata }, { uuid => $appter->[0]->{'uuid'}, app => $appter->[0]->{'app'} });
										$pr = eval { return decode_json read_file($priority) } || {};
										delete $pr->{$appter->[0]->{'uuid'}};
										if (scalar keys %{$pr} == 0) {`shred -u $priority`; }
										else {
											$jpr = encode_json $pr;
											write_file($priority, $jpr);
										}
									}
									&subs::subprocessor(sub {
								    Mojo::IOLoop->reset;

										`shred -u $filename`;
									}, { name => 'thumb shredder' });
								}
							}
							close($thumb_slot) if $thumb_slot;
							if (defined $hover_position && ($file_data->{'type'} // '') eq 'video') {
								$c->res->headers->cache_control('private, max-age=3600') if $data;
								$data ? $c->render_file(data => $data, content_type => 'image/png') : $c->render(text => 'none');
								return;
							}
							$data = $full_data unless (defined $data && length $data);
							$c->res->headers->accept_ranges('bytes');
							&file_response_headers($c, $file, $wants_thumb ? 'private, max-age=3600' : 'private, no-cache');
							my %media_args = &media_render_args($file, $fd);
							if (defined $opened->{'total'} && defined $opened->{'start'}) {
								# The slice is already decrypted. Drop the request's Range so the
								# render helper does not slice it a second time, and send 206.
								my $last_byte = $opened->{'start'} + $opened->{'length'} - 1;
								$c->res->headers->content_range('bytes ' . $opened->{'start'} . '-' . $last_byte . '/' . $opened->{'total'});
								$c->req->headers->remove('Range');
								$data ? $c->render_file(data => $data, status => 206, %media_args) : $c->render(text => 'none');
							}
							else {
								$data ? $c->render_file(data => $data, %media_args) : $c->render(text => 'none');
							}
							return;
						}
					}
		}
		elsif ($c->param('loudness') && -e $file) {
			&media_loudness_response($c, $file, $file);
			return;
		}
		elsif ($c->param('duty')) {
			my $data = read_file($file);
			my $fd = &subs::plaintext_verdict(substr($data, 0, 65536)) || 'application/octet-stream';
			my @ext = split /\./, $file;
			my $ext = $ext[-1];
			my $server_time;
			if (-e $file) {
				my @stat = stat($file);
				$server_time = $stat[10] * 1000;
			}
			return {
				data => $data,
				image => 'data:' . $fd . ';base64,' . encode_base64($data,''),
				fd => $fd,
				timestamp => $server_time,
				ext => $ext
			};
		}
		elsif ($device eq 'mobile') {
			if (-e $file) {
				&file_response_headers($c, $file, $wants_thumb ? 'private, max-age=3600' : 'private, no-cache');
				if ($c->param('subtitle')) {
					my $sub_file = $file . '.vtt';
					if (-e $sub_file) {
						my $data = read_file($sub_file);
						$sub_file ? $c->render_file(filepath => $sub_file, content_type => 'text/vtt', content_disposition => 'inline') : $c->render(text => 'WEBVTT');
						return;
					}
					else {
						my $command = 'timeout 25 ffmpeg -nostdin -i ' . &subs::terminal_name($file) . ' -map 0:s:0 ' . &subs::terminal_name($sub_file);
						`$command`;
						if (-e $sub_file) {
							my $data = read_file($sub_file);
							$data ? $c->render_file(data => $data, content_type => 'text/vtt', content_disposition => 'inline') : $c->render(text => 'WEBVTT');
							return;
						}
						else {
							return $c->reply->not_found;
						}
					}
				}
				if ($c->param('thumb')) {
					my $data;
					if ($file_data->{'uuid'} && ! -e $file_data->{'thumb'} && $thumbnail_size ne 'none') {
						my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $file, app => $appter->[0]->{'app'}, type => $file_data->{'type'}, is_thumb => 1 });
						$file_data->{'type'} = $type;
						$file_data->{'thumb'} = $destination . $asset;

						$file_data = &thumbnail_creator($file_data);
						$data = read_file($file_data->{'thumb'});
						$data ? $c->render(data => $data) : $c->render(text => 'none');
						return;
					}
					else {
						my $filename = $tdir . '/' . &subs::random_string_creator(20) . '.png';
						my $command = 'ffmpeg -nostdin -ss 00:01:30.010 -i ' . &subs::terminal_name($file) . ' -vframes 1 -c:v png -f image2pipe - | magick - -resize 200x200 -';
						my $data = &native_thumb_png($file, 200);
						$data = &run_thumb_command($command) unless defined $data && length $data;
						if ($c->param('position')) {
							$data ? $c->render_file(data => $data, content_type => 'image/png') : $c->render(text => 'none');
						}
						else {
							$data ? $c->render_file(data => $data) : $c->render(text => 'none');
						}
						return;
					}
				}
				elsif (grep { $ext eq $_ } qw/xcf tiff/) {
					my $t_file = &subs::terminal_name($file);
					my $c_command = 'magick "' . $file . '[0]" -alpha on -background none -flatten -resize 256x256 png:-';
					my $converted = &native_thumb_png($file, 256);
					$converted = `$c_command` unless defined $converted && length $converted;
					my $data =  $converted;
					$c->render_file(data => $data);
				}
				else {
					# filepath streams the file and supports Range; reading it into a
					# scalar copied the whole thing and then copied it again into the asset.
					# The FUSE-backed storage paths take the manual streamer above.
					if ($file && $file =~ m{^/(?:sdcard|storage)/} && &stream_fuse_media($c, $file)) { return; }
					$file ? $c->render_file('filepath' => $file, &media_render_args($file, undef)) : $c->render(text => 'none');
					return;
				}
			}
		}
		else {
			if (-e $file) {
				&file_response_headers($c, $file, $wants_thumb ? 'private, max-age=3600' : 'private, no-cache');
				if ($c->param('subtitle')) {
					my $sub_file = $file . '.vtt';
					if (-e $sub_file) {
						my $data = read_file($sub_file);
						$sub_file ? $c->render_file(filepath => $sub_file, content_type => 'text/vtt', content_disposition => 'inline') : $c->render(text => 'WEBVTT');
						return;
					}
					else {
						my $command = 'timeout 25 ffmpeg -nostdin -i ' . &subs::terminal_name($file) . ' -map 0:s:0 ' . &subs::terminal_name($sub_file);
						`$command`;
						if (-e $sub_file) {
							my $data = read_file($sub_file);
							$data ? $c->render_file(data => $data, content_type => 'text/vtt', content_disposition => 'inline') : $c->render(text => 'WEBVTT');
							return;
						}
						else {
							return $c->reply->not_found;
						}
					}
				}
				if ($c->param('thumb')) {
					my $data;
					if ($file_data->{'uuid'} && ! -e $file_data->{'thumb'} && $thumbnail_size ne 'none') {
						my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $file, app => $appter->[0]->{'app'}, type => $file_data->{'type'}, is_thumb => 1 });
						$file_data->{'type'} = $type;
						$file_data->{'thumb'} = $destination . $asset;

						$file_data = &thumbnail_creator($file_data);
						$data = read_file($file_data->{'thumb'});
						$data ? $c->render(data => $data) : $c->render(text => 'none');
						return;
					}
					else {
						my $filename = $tdir . '/' . &subs::random_string_creator(20) . '.png';
						my $duration = $c->param('duration');
						my @folder = split /\//, $file;
						my $tfile = pop @folder;
						my $folder = join '/', @folder;
						my $thumb_folder = $folder . '/.thumbs';
						my $tfd = &subs::terminal_name($thumb_folder);
						`mkdir -p $tfd` unless -e $thumb_folder;
						my @tfile = split /\./, $tfile;
						pop @tfile;
						if ($c->param('chapter') eq 'ya') {
							$tfile = (join '.', @tfile) . ' ' . $c->param('id') . '.png';
							if ($c->param('end_time')) {
								$duration = (($c->param('end_time') - $c->param('start_time')) / 2 + $c->param('start_time'));
							}
							else {
								$duration = $c->param('start_time') + 5;
							}
						}
						else {
							$tfile = (join '.', @tfile) . '.png';
						}
						$tfile = $thumb_folder . '/' . $tfile;
						if ( -e $tfile && !$c->param('position')) {
							$data = read_file($tfile);
						}
						else {
							my $save = 1;
							if ($c->param('position')) {
								$duration = $c->param('position');
								$save = 0;
							}
							elsif ($c->param('chapter') ne 'ya') {
								$duration = &subs::thumbnail_seek_position($duration);
							}
							my $command = 'ffmpeg -nostdin -ss ' . $duration . ' -i ' . &subs::terminal_name($file) . ' -vframes 1 -c:v png -f image2pipe - | magick - -resize 200x200 -';
							$data = &native_thumb_png($file, 200);
							$data = &run_thumb_command($command) unless defined $data && length $data;

							write_file($tfile, $data) if $save == 1 && defined $data && length $data;
						}
					}
					$data ? $c->render_file(data => $data) : $c->render(text => 'none');
					return;
				}
				elsif (grep { $ext eq $_ } qw/xcf tiff/) {
					my $t_file = &subs::terminal_name($file);
					my $c_command = 'magick "' . $file . '[0]" -alpha on -background none -flatten -resize 256x256 png:-';
					my $converted = &native_thumb_png($file, 256);
					$converted = `$c_command` unless defined $converted && length $converted;
					my $data =  $converted;
					$c->render_file(data => $data);
				}
				else {
					$file ? $c->render_file('filepath' => $file, &media_render_args($file, undef)) : $c->render(text => 'none');
					return;
				}
			}

			else {
				$c->render('text' => '');
				return;
			}
		}
		# A path this machine does not have (a photo kept on another machine, or
		# one that moved) used to fall out of the branches with no answer at all,
		# leaving the request open until the client gave up. One stale album
		# cover could pin a worker that way, and a few of them pinned the pool.
		unless ($c->res->body) {
			$c->res->code(404);
			$c->render(text => 'not found');
		}
	}
	else {
		# the gate may already have answered (a locked request for a file is
		# denied by the lock page); do not replace that answer with 'no'
		$c->render('text' => 'no') unless $c->res->code && $c->res->code == 423;
		return;
	}
}

1;
