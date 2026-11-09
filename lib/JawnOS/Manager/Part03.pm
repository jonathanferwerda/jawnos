package Manager;

# Manager helpers, part 3 of 37. Moved out of Manager.pl so a
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

sub media_loudness_measure_path($path) {
	my $out = '';
	eval {
		local $SIG{ALRM} = sub { die "loudness measurement timed out\n" };
		alarm 120;
		my $cmd = 'ffmpeg -nostdin -nostats -i ' . &subs::terminal_name($path) . ' -vn -af volumedetect -f null - 2>&1';
		$out = `$cmd`;
		alarm 0;
	};
	alarm 0;
	return undef unless length $out;
	my ($mean, $max, $duration);
	foreach my $line ( split /\n/, $out ) {
		$mean = $1 if $line =~ /mean_volume:\s*(-?\d+(?:\.\d+)?) dB/;
		$max = $1 if $line =~ /max_volume:\s*(-?\d+(?:\.\d+)?) dB/;
		$duration = $1 if $line =~ /Duration:\s*(\d+:\d+:\d+(?:\.\d+)?)/;
	}
	return undef unless defined $mean;
	return { mean_volume => $mean + 0, max_volume => (defined $max ? $max + 0 : undef), duration => $duration };
}

sub media_loudness_key($path) {
	my @st = stat($path);
	require Digest::MD5;
	return 'loudness-' . Digest::MD5::md5_hex($path . ':' . ($st[7] || 0) . ':' . ($st[9] || 0));
}

sub media_loudness_cached($path) {
	my $key = &media_loudness_key($path);
	my $cached = &subs::cache_get({ app => 'music', context => 'loudness', subcontext => $key });
	return (ref $cached eq 'HASH' && defined $cached->{'mean_volume'}) ? $cached : undef;
}

sub media_loudness_response($c, $measure_path, $identity_path) {
	my $identity = defined $identity_path && length $identity_path ? $identity_path : $measure_path;
	my $cached = &media_loudness_cached($identity);
	if ($cached) {
		$c->render(json => { ok => 1, cached => 1, %{$cached} });
		return;
	}
	my $result = &media_loudness_measure_path($measure_path);
	if ($result) {
		&subs::cache_set({ app => 'music', context => 'loudness', subcontext => &media_loudness_key($identity), warranty => '-1y' }, $result);
		$c->render(json => { ok => 1, %{$result} });
		return;
	}
	$c->render(json => { ok => 0 });
	return;
}

sub thumb_generation_slot {
	my $path = $gb::tmp_dir . '/thumb_generation.lock';
	open(my $fh, '>>', $path) or return undef;
	unless (flock($fh, LOCK_EX | LOCK_NB)) { close $fh; return undef; }
	return $fh;
}

sub thumb_placeholder {
	my ($c) = @_;
	# a 1x1 transparent PNG: a cheap answer while another request generates
	my $png = pack('H*', '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c6360000200000500017a5eab3f0000000049454e44ae426082');
	$c->res->headers->content_type('image/png');
	$c->res->headers->cache_control('no-store');
	$c->render(data => $png);
}

sub native_thumb_png {
	my ($path, $size, $at_ms) = @_;
	return undef unless defined $path && length $path;
	my ($pixels) = (defined $size ? $size : '') =~ /(\d+)/;
	my $bytes = &subs::device_thumbnail($path, $pixels || 256, $at_ms);
	return (defined $bytes && length $bytes) ? $bytes : undef;
}

sub run_thumb_command {
	my ($command) = @_;
	my $out = '';
	eval {
		local $SIG{ALRM} = sub { die "thumbnail command timed out\n" };
		alarm 20;
		$out = `$command`;
		alarm 0;
	};
	alarm 0;
	return $out;
}

sub remote_relay_media($c) {
	my $agent = &subs::remote_agent_for($c->param('remote_uuid'));
	if ($agent->{'error'} || !$agent->{'manager'}) {
		$c->render(text => 'none');
		return;
	}
	my $ua = $agent->{'ua'};
	my $url = Mojo::URL->new($agent->{'manager'} . '/play');
	my $params = $c->req->query_params->to_hash;
	# the peer has no session for this window: the peer signature is the proof,
	# and a forwarded token would be meaningless there
	delete @{$params}{qw/remote_uuid unlock subprocess/};
	$params->{'remoted'} = 'yes';
	$url->query($params);

	# Ask for one byte first. The answer carries the file's length, its type and
	# whether the peer really speaks Range - and it cannot flood this worker even
	# if the peer ignores Range, because the probe aborts after a few kilobytes.
	# The player's own Range is then answered from those numbers, so the status
	# and Content-Range are set before the first body byte: Mojolicious sends its
	# headers with the first write and cannot change them afterwards.
	my $probe = $ua->inactivity_timeout(8)->connect_timeout(6)->request_timeout(12)->max_response_size(4096)
		->get($url, { Range => 'bytes=0-0' });
	my $pres = $probe ? $probe->res : undef;
	my $type = $pres ? $pres->headers->content_type : undef;
	my $size;
	if ($pres && !$pres->error) {
		my $content_range = $pres->headers->header('Content-Range');
		if (defined $content_range && $content_range =~ m{^bytes\s+\d+-\d+/(\d+)}i) {
			$size = $1;
		}
		elsif ($pres->code == 200) {
			my $length = $pres->headers->content_length;
			$size = $length if defined $length && $length =~ /^\d+$/;
		}
	}
	# a peer that ignores Range answers the probe with the whole file; the probe's
	# size cap ends that read, and the stream below falls back to a plain 200.
	# A peer that has not been updated (or whose own gate refused) answers its
	# app-required page with a tiny body instead; that is not a track.
	if ($pres && !$pres->error && $pres->code == 200) {
		my $ctype = $pres->headers->content_type || '';
		if ($ctype =~ m{^text/html} && length($pres->body // '') < 64) {
			$c->render(text => 'none');
			return;
		}
	}
	unless ($pres && $pres->code && $pres->code < 400) {
		$c->render(text => 'none');
		return;
	}

	# what the player asked for, clamped to what the peer said it holds
	my ($start, $end) = (0, defined $size ? $size - 1 : 0);
	my $ask = $c->req->headers->range;
	my $client_ranged = 0;
	if (defined $size && defined $ask && $ask =~ m{^bytes=(\d*)-(\d*)}i) {
		my ($s, $e) = ($1, $2);
		if ($s eq '' && $e ne '') {
			$start = $size - int($e);
			$start = 0 if $start < 0;
			$end = $size - 1;
			$client_ranged = 1;
		}
		elsif ($s ne '') {
			$start = int($s);
			$end = ($e ne '') ? int($e) : $size - 1;
			$client_ranged = 1;
		}
		$start = 0 if $start < 0;
		$end = $size - 1 if $end > $size - 1;
	}
	if (defined $size && $start >= $size) {
		$c->res->code(416);
		$c->res->headers->header('Content-Range' => 'bytes */' . $size);
		$c->render(text => '');
		return;
	}

	$c->res->headers->content_type($type) if defined $type && length $type;
	$c->res->headers->cache_control('private, no-cache');
	if (defined $size && $client_ranged) {
		$c->res->code(206);
		$c->res->headers->header('Content-Range' => "bytes $start-$end/$size");
		$c->res->headers->content_length($end - $start + 1);
		$c->res->headers->accept_ranges('bytes');
	}
	elsif (defined $size) {
		$c->res->code(200);
		$c->res->headers->content_length($size);
		$c->res->headers->accept_ranges('bytes');
	}
	else {
		# the peer answered a Range probe with the whole file: stream it as a
		# plain 200, because there is no length to divide up (no seeking)
		$c->res->code(200);
	}

	# the stream itself: a paused player sends nothing for a while, so only a
	# stalled peer trips the inactivity bound; the client ends the session
	$ua->inactivity_timeout(30)->connect_timeout(10)->request_timeout(0)->max_response_size(0);
	my $stream_headers = {};
	$stream_headers->{'Range'} = "bytes=$start-$end" if defined $size;
	my $tx = $ua->build_tx(GET => $url, $stream_headers);
	# the user agent must outlive this call: its destructor closes every open
	# connection, and the route returns before the first body chunk. The
	# controller keeps it (and the transaction) until the stream finishes.
	$c->stash('relay_media' => { ua => $ua, tx => $tx });
	my $client_gone = 0;
	$c->on(finish => sub { $client_gone = 1 });
	$tx->res->content->on(read => sub {
		my ($content, $bytes) = @_;
		return if $client_gone;
		$c->write($bytes);
	});
	# mark the response dynamic before the first byte arrives, so the request is
	# not finished empty while the peer is still opening the file
	$c->write(undef);
	$ua->start($tx => sub {
		$c->stash('relay_media' => undef);
		$c->finish unless $client_gone;
	});
}

1;
