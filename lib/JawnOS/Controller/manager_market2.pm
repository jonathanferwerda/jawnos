package Manager;

# manager_market2: route actions moved out of Manager.pl, one sub per route so a
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

# Capture the receipt, then read it. The ADF feeds a long receipt in one pass,
# the flatbed takes a page at a time; without a feed, an uploaded or bridged
# image is read. Nothing is written here.
# POST /manager/market/receipt
sub action_4700 {
	my $c = shift;
	my $feed = lc($c->param('feed') || '');
	my @pages;
	if ($feed eq 'adf' || $feed eq 'flatbed') {
		return $c->render(json => { error => 'this machine cannot scan' })
			unless grep { $_ eq $feed } @{ &market_scan_feeds() };
		my ($err, $paths) = &market_receipt_scan($feed, $c->param('scan_id'));
		return $c->render(json => { error => $err }) if $err;
		foreach my $p ( @{$paths} ) { push @pages, { base64 => encode_base64(read_file($p), ''), path => $p }; }
	}
	else {
		my @blobs;
		my $b64 = $c->param('image');
		# a bridged camera sends base64; an upload arrives as a file part, which
		# param() hands back as a Mojo::Upload, not a string
		if (defined $b64 && !ref $b64 && $b64 =~ /\S/) {
			$b64 =~ s/^data:[^,]*,//;
			my $bytes = b64_decode($b64);
			push @blobs, $bytes if $bytes && length $bytes;
		}
		foreach my $u ( @{ $c->req->uploads } ) {
			next unless ($u->headers->content_type || '') =~ m{^image/};
			my $b = $u->slurp;
			push @blobs, $b if $b && length $b;
		}
		foreach my $b ( @blobs ) { push @pages, { base64 => encode_base64($b, ''), bytes => $b }; }
	}
	return $c->render(json => { error => 'no receipt image was given' }) unless scalar @pages;
	# file the paper, so the receipt is kept beside the item apps it names
	my @files;
	foreach my $p ( @pages ) {
		if ($p->{'path'}) { push @files, $p->{'path'}; next; }
		my $saved = &market_receipt_store($p->{'bytes'});
		push @files, $saved if $saved;
	}
	my ($out, $err) = &market_receipt_read([ map { $_->{'base64'} } @pages ]);
	return $c->render(json => { error => $err }) if $err;
	my @images;
	my $page = 0;
	foreach my $f ( @files ) {
		next unless defined $f && -e $f;
		my $name = $f;
		$name =~ s{.*/}{};
		push @images, { page => $page, url => '/manager/market/receipt/image?file=' . $name };
		$page++;
	}
	$c->render(json => {
		vendor => &subs::unformat_name($out->{'vendor'} || ''),
		vendor_formatted => &subs::format_name($out->{'vendor'} || ''),
		date => $out->{'date'} || '',
		total => (defined $out->{'total'} && $out->{'total'} =~ /[0-9]/) ? 0 + $out->{'total'} : undef,
		payment_method => ($out->{'payment_method'} || ''),
		payment_ref => ($out->{'payment_ref'} || ''),
		account => &market_payment_account($out->{'payment_method'}),
		accounts => &market_accounts(),
		lines => &market_receipt_lines($out),
		files => \@files,
		images => \@images,
	});
}

# Confirm the read: link every line into the list and file the receipt. A row
# already on the list is ticked (what a shop does) and given the receipt's
# quantity and price; a row that is not is added in the cart. A printed code
# becomes the item's own product code, so the next scan of it is instant.
# POST /manager/market/receipt/apply
sub action_4765 {
	my $c = shift;
	my $vendor = &subs::unformat_name($c->param('vendor')) || '';
	my $list_name = $c->param('list') || '';
	my $account = &subs::unformat_name($c->param('account')) || '';
	my $lines = eval { return decode_json $c->param('lines') } || [];
	return $c->render(json => { error => 'nothing to add' }) unless ref $lines eq 'ARRAY' && scalar @{$lines};
	my $now = &subs::rightNow();
	my $list_key = &market_list_key($list_name);
	my $list = &market_list();
	my (@added, $linked);
	foreach my $l ( @{$lines} ) {
		next unless ref $l eq 'HASH';
		next if defined $l->{'include'} && !$l->{'include'};
		my $item = &subs::unformat_name($l->{'item'} || $l->{'description'} || '');
		next unless $item ne '';
		my $init = &subs::setting_initializer($item, $now);
		$item = $init->{'app'} if $init->{'app'};
		my $code = $l->{'code'} || '';
		$code =~ s/[^0-9]//g;
		if (length $code >= 8 && !&market_barcode_house($code)) {
			&subs::setting_setter({ app => $item, setting => 'product_code', value => $code });
			&market_barcode_remember($code, { item => $item, category => '', unit => '', raw => $item });
		}
		my $found;
		foreach my $it ( @{$list} ) {
			next unless lc($it->{'text'} || '') eq lc($item) || &subs::unformat_name($it->{'text'} || '') eq $item;
			$it->{'picked'} = 1;
			$it->{'account'} = $account if $account;
			$it->{'quantity'} = 0 + $l->{'qty'} if defined $l->{'qty'} && $l->{'qty'} =~ /[0-9]/;
			$it->{'price'} = 0 + $l->{'price'} if defined $l->{'price'} && $l->{'price'} =~ /[0-9]/;
			$found = 1;
			$linked++;
			last;
		}
		next if $found;
		my $row = {
			uuid => &subs::random_string_creator(21),
			text => $item,
			kind => &market_item_due($item) ? 'need' : 'want',
			vendor => $vendor,
			list => $list_key,
			timestamp => &subs::rightNow(),
			cart => 1,
			quantity => (defined $l->{'qty'} && $l->{'qty'} =~ /[0-9]/) ? 0 + $l->{'qty'} : 1,
		};
		$row->{'price'} = 0 + $l->{'price'} if defined $l->{'price'} && $l->{'price'} =~ /[0-9]/;
		$row->{'account'} = $account if $account;
		$row->{'barcode'} = $code if length $code >= 8;
		unshift @{$list}, $row;
		push @added, $item;
	}
	&market_save_list($list);
	&market_lists_touch_vendor($list_key, &subs::format_name($list_name), $vendor) if $list_key && $vendor;
	my $files = eval { return decode_json $c->param('files') } || [];
	&market_receipt_file({ files => $files, lines => $lines, date => $c->param('date'), vendor => $vendor, total => $c->param('total'), payment_method => $c->param('payment_method'), payment_ref => $c->param('payment_ref'), account => $account }) if scalar @{$files};
	$c->render(json => { added => scalar @added, linked => $linked });
}

# A running scan's pages and the scanner's own log, for the confirm panel's live
# view. The scan POST blocks on the scanner, so this is answered by another
# worker while it runs; pages are converted to a preview jpg the moment their
# tiff appears, and the page number is kept stable so a lagging conversion does
# not shuffle what is already shown.
# GET /manager/market/receipt/progress
sub action_4828 {
	my $c = shift;
	my $id = $c->param('scan_id') || '';
	$id =~ s/[^A-Za-z0-9]//g;
	return $c->render(json => { pages => [], log => [] }) unless length $id;
	my $folder = &subs::home(&subs::setting_grabber({ app => 'misc', setting => 'scan_location', device => $device }) . '/market');
	my $base = $folder . '/receipt_' . $id;
	my (@pages, %seen);
	my $n = 0;
	foreach my $t ( &scanner_page_list($base) ) {
		my $jpg = $base . '.preview_' . $n . '.jpg';
		unless (-e $jpg) {
			my $converted = &subs::image_bridge_convert($t, $jpg);
			system('magick', 'convert', $t, $jpg) unless $converted;
		}
		if (-e $jpg) {
			push @pages, { page => $n, url => '/manager/market/receipt/preview?scan_id=' . $id . '&page=' . $n };
			$seen{$n} = 1;
		}
		$n++;
	}
	# a finished page's own jpg is written before the vision read, so the paper
	# shows while the model is still working; scanimage's own page number is the
	# `_N` suffix (a flatbed page is the bare base name)
	foreach my $f ( grep { !/\.preview_/ } glob("$base*.jpg") ) {
		my $p = 0;
		$p = $1 - 1 if $f ne $base . '.jpg' && $f =~ /_([0-9]+)\.jpg$/;
		next if $seen{$p};
		my $name = $f;
		$name =~ s{.*/}{};
		push @pages, { page => $p, url => '/manager/market/receipt/image?file=' . $name };
		$seen{$p} = 1;
	}
	my @log = &scanner_log_tail($base . '.log');
	@log = @log[-6 .. -1] if scalar @log > 6;
	$c->render(json => { pages => \@pages, log => \@log });
}

# One page of a running scan, inline (the preview jpg the progress route made).
# GET /manager/market/receipt/preview
sub action_4866 {
	my $c = shift;
	my $id = $c->param('scan_id') || '';
	$id =~ s/[^A-Za-z0-9]//g;
	my $page = $c->param('page') || 0;
	$page = 0 unless $page =~ /^[0-9]+$/;
	my $jpg = &subs::home(&subs::setting_grabber({ app => 'misc', setting => 'scan_location', device => $device }) . '/market/receipt_' . $id . '.preview_' . $page . '.jpg');
	unless (length $id && -f $jpg) { $c->rendered(404); return; }
	my $data = read_file($jpg);
	unless (defined $data && length $data) { $c->rendered(404); return; }
	$c->res->headers->content_type('image/jpeg');
	$c->res->headers->cache_control('no-store');
	$c->render(data => $data);
}

# A scanned or uploaded receipt page for the review panel, inline. /file_open
# hands a file back as a download, which an <img> will not show; only a
# receipt-named file in the market scan folder is served, never a path.
# GET /manager/market/receipt/image
sub action_4883 {
	my $c = shift;
	my $name = $c->param('file') || '';
	unless ($name =~ /^receipt_[A-Za-z0-9_.-]+\.(?:jpg|jpeg|png)$/i && $name !~ /\.\./) { $c->rendered(404); return; }
	my $path = &subs::home(&subs::setting_grabber({ app => 'misc', setting => 'scan_location', device => $device }) . '/market/' . $name);
	unless (-f $path) { $c->rendered(404); return; }
	my $data = read_file($path);
	unless (defined $data && length $data) { $c->rendered(404); return; }
	$c->res->headers->content_type($data =~ /^\x89PNG/ ? 'image/png' : 'image/jpeg');
	$c->res->headers->cache_control('private, max-age=60');
	$c->render(data => $data);
}

# Stop a running scan. The worker running scanimage is blocked in its own shell,
# so the cancel is a marker plus a kill of that exact batch name; the scan then
# discards its pages and answers "cancelled" to the waiting request.
# POST /manager/market/receipt/cancel
sub action_4898 {
	my $c = shift;
	my $id = $c->param('scan_id') || '';
	$id =~ s/[^A-Za-z0-9]//g;
	return $c->render(json => { cancelled => 0 }) unless length $id;
	my $folder = &subs::home(&subs::setting_grabber({ app => 'misc', setting => 'scan_location', device => $device }) . '/market');
	my $base = $folder . '/receipt_' . $id;
	write_file($base . '.cancel', 1);
	`pkill -f "receipt_$id" 2>/dev/null`;
	$c->render(json => { cancelled => 1 });
}

# A kept receipt's page for the receipts pane. /file_open hands a file back as a
# download (Content-Disposition: attachment), which an <img> will not show, so a
# receipt's own page is served inline here - and only a page that receipt
# recorded, never an arbitrary path.
# GET /manager/market/receipt_page
sub action_4913 {
	my $c = shift;
	my $uuid = $c->param('uuid') || '';
	my $page = $c->param('page') || 0;
	$page = 0 unless $page =~ /^[0-9]+$/;
	my ($receipt) = grep { ($_->{'uuid'} || '') eq $uuid } @{ &market_receipts() };
	my $files = ($receipt && ref $receipt->{'files'} eq 'ARRAY') ? $receipt->{'files'} : [];
	my $file = $files->[$page] || '';
	unless ($file && -f $file) { $c->rendered(404); return; }
	my $data = read_file($file);
	unless (defined $data && length $data) { $c->rendered(404); return; }
	my $type = $data =~ /^\x89PNG/ ? 'image/png'
		: $data =~ /^\xFF\xD8\xFF/ ? 'image/jpeg'
		: $data =~ /^GIF8/ ? 'image/gif'
		: $data =~ /^RIFF....WEBP/s ? 'image/webp'
		: 'application/octet-stream';
	$c->res->headers->content_type($type);
	$c->res->headers->cache_control('private, max-age=60');
	$c->render(data => $data);
}

1;
