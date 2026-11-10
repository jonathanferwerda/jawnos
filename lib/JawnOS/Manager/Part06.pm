package Manager;

# Manager helpers, part 6 of 37. Moved out of Manager.pl so a
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
use JawnOS::Platform::Process ();
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

# Guess which account a printed tender names. An exact word always wins (a
# mastercard account for a mastercard receipt); with no exact word, a family with
# a single account takes it (a receipt saying "credit" selects the only credit
# account, which may be a mastercard; "debit" selects the only interac one).
sub market_payment_account {
	my ($method) = @_;
	my $want = lc($method || '');
	$want =~ s/[^a-z0-9 ]//g;
	$want =~ s/^\s+|\s+$//g;
	return '' unless $want ne '';
	my $rows = &subs::db_query("select app, value from settings where setting = 'payment_type' and value is not null and value != ''")->hashes;
	my ($best, $best_len) = ('', 0);
	my %family_of;
	foreach my $r ( @{$rows} ) {
		my $t = lc($r->{'value'} || '');
		$t =~ s/[^a-z0-9 ]//g;
		$t =~ s/^\s+|\s+$//g;
		next unless $t ne '';
		my $fam = '';
		foreach my $f ( keys %market_payment_family ) {
			if (grep { $_ eq $t } @{ $market_payment_family{$f} }) { $fam = $f; last; }
		}
		$fam = $t unless $fam ne '';
		push @{ $family_of{$fam} }, { app => $r->{'app'}, type => $t };
		if (length($t) >= 3 && ($want eq $t || $want =~ /\b\Q$t\E\b/)) {
			if (length($t) > $best_len) { $best = $r->{'app'}; $best_len = length($t); }
		}
	}
	return $best if $best ne '';
	foreach my $fam ( sort keys %family_of ) {
		my @acc = @{ $family_of{$fam} };
		next unless scalar @acc == 1;
		my @words = @{ $market_payment_family{$fam} || [ $fam ] };
		foreach my $w ( @words ) {
			return $acc[0]->{'app'} if $want eq $w || $want =~ /\b\Q$w\E\b/;
		}
		return $acc[0]->{'app'} if $want =~ /\b\Q$fam\E\b/;
	}
	return '';
}

# The device type a browser's user agent names. Only the types the capability
# table knows are returned; anything else is a computer (the house's default).
sub market_client_type {
	my ($ua) = @_;
	my $t = lc($ua || '');
	return 'mobile' if $t =~ /android|iphone|ipad|ipod|mobile/;
	return 'computer';
}

# --- a scan session: a rapid-fire run of codes a person confirms at the end ---
# The machine that pressed Scan owns the list and the session. A phone on its own
# jawn forwards each code to it over the peer rail; Done puts the collected items
# on the list, Cancel throws them away and stops the phone's scanner.
sub market_scan_session {
	my $raw = &subs::setting_grabber({ app => 'market', setting => 'scan_session' });
	my $s = eval { return decode_json $raw } || {};
	return ref $s eq 'HASH' ? $s : {};
}

sub market_scan_session_save {
	my ($s) = @_;
	&subs::setting_setter({ app => 'market', setting => 'scan_session', value => encode_json($s) });
}

# A run can have several inputs at once (the computer's webcam and two phones,
# say). Each has a stable id so the page can add, replace or stop one without
# disturbing the others.
sub market_scan_device_id {
	my ($d) = @_;
	return '' unless ref $d eq 'HASH';
	return 'local' unless ($d->{'kind'} || '') eq 'remote';
	return ($d->{'machine'} || '') . '|' . ($d->{'browser_tab_id'} || '');
}

sub market_scan_session_devices {
	my ($s) = @_;
	my @d = grep { ref $_ eq 'HASH' && &market_scan_device_id($_) ne '' } @{ $s->{'devices'} || [] };
	@d = ($s->{'device'}) if !scalar @d && ref $s->{'device'} eq 'HASH' && &market_scan_device_id($s->{'device'}) ne '';
	return @d;
}

# One resolved code into a session. The phone's relay and this machine's own
# webcam reader both come through here, so a product is looked up in our terms
# once and lands in the run the same way.
sub market_scan_session_add {
	my ($s, $code) = @_;
	$code = '' unless defined $code;
	$code =~ s/\s+//g;
	return undef unless $code =~ /\S/;
	my $map = &market_barcode_resolve($code);
	my $item = $map->{'item'} || $code;
	my $it = {
		code => $code,
		item => $item,
		raw => ($map->{'raw'} || ''),
		category => ($map->{'category'} || ''),
		unit => ($map->{'unit'} || ''),
		at => &subs::rightNow(),
	};
	push @{ $s->{'items'} }, $it;
	&market_scan_session_save($s);
	return $it;
}

# The computer's own webcam, read by zbar. A session on this machine watches the
# camera in the background; each poll folds the codes the reader printed since the
# last one into the run. A phone has its own scanner, and a server has neither.
sub market_camera_dir { return '/tmp/jawn_market_camera'; }

sub market_camera_available {
	return 0 unless &subs::device_setter() eq 'computer';
	return 0 unless grep { $_ eq 'webcam' } @{ $gb::capabilities->{'computer'}->{'camera'} || [] };
	return 0 unless -e '/dev/video0';
	my $which = `command -v zbarcam 2>/dev/null`;
	return ($which =~ /\S/) ? 1 : 0;
}

sub market_camera_stop {
	my $pidfile = &market_camera_dir() . '/pid';
	return 0 unless -e $pidfile;
	open my $pf, '<', $pidfile or return 0;
	my $pid = <$pf>;
	close $pf;
	unlink $pidfile;
	return 0 unless $pid && $pid =~ /^([0-9]+)/;
	$pid = $1;
	return 0 unless &market_camera_is_reader($pid);
	kill('TERM', $pid);
	return 1;
}

# A reused pid must not be taken for our reader.
sub market_camera_is_reader {
	my ($pid) = @_;
	my $cmd = JawnOS::Platform::Process::command_line($pid);
	return ($cmd && $cmd =~ /zbarcam/) ? 1 : 0;
}

# Is the reader this machine started still running?
sub market_camera_alive {
	my $pidfile = &market_camera_dir() . '/pid';
	return 0 unless -e $pidfile;
	open my $pf, '<', $pidfile or return 0;
	my $pid = <$pf>;
	close $pf;
	return ($pid && $pid =~ /^([0-9]+)/ && &market_camera_is_reader($1) && kill(0, $1)) ? 1 : 0;
}

# Start the reader for a fresh run: one zbarcam on the machine, writing each code
# it reads as a line, detached so the request can return at once.
sub market_camera_start {
	&market_camera_stop();
	my $dir = &market_camera_dir();
	`mkdir -p $dir` unless -e $dir;
	return 0 unless -d $dir;
	open my $codes, '>', $dir . '/codes'; close $codes;
	open my $log, '>', $dir . '/log'; close $log;
	my $pid = fork();
	return 0 unless defined $pid;
	if ($pid == 0) {
		eval { POSIX::setsid(); };
		$^F = 2;  # do not leak the manager's sockets into the reader
		open STDOUT, '>>', $dir . '/codes';
		open STDERR, '>>', $dir . '/log';
		exec('zbarcam', '--raw', '--nodisplay', '/dev/video0');
		exit 0;
	}
	open my $pf, '>', $dir . '/pid';
	print $pf $pid;
	close $pf;
	return $pid;
}

# Fold the lines the reader printed since the last poll into the session. zbar
# repeats a code while it stays in view, so the same read is ignored for a few
# seconds; a new item is taken at once.
sub market_camera_ingest {
	my ($s) = @_;
	return 0 unless ($s->{'camera'} || 0);
	# a run that was closed, or left open far too long, gives the camera back
	if (($s->{'status'} || '') ne 'scanning' || (($s->{'at'} || 0) + 0 > 0 && time - $s->{'at'} > 1800)) {
		&market_camera_stop();
		return 0;
	}
	my $file = &market_camera_dir() . '/codes';
	return 0 unless -e $file;
	my $offset = ($s->{'camera_offset'} || 0) + 0;
	my $size = -s $file;
	$offset = 0 if $size < $offset;
	open my $fh, '<', $file or return 0;
	seek($fh, $offset, 0);
	my @codes;
	while (my $line = <$fh>) {
		chomp $line;
		$line =~ s/^\s+|\s+$//g;
		next unless $line ne '';
		push @codes, $line;
	}
	my $new_offset = tell($fh);
	close $fh;
	$s->{'camera_offset'} = $new_offset;
	my $now = time;
	my $added = 0;
	foreach my $code ( @codes ) {
		if (($s->{'camera_last_code'} || '') eq $code && ($now - ($s->{'camera_last_at'} || 0)) < 5) { next; }
		$s->{'camera_last_code'} = $code;
		$s->{'camera_last_at'} = $now;
		&market_scan_session_add($s, $code);
		$added++;
	}
	&market_scan_session_save($s) if $new_offset != $offset || $added;
	return $added;
}

# Ask the Android app to put its scanner away. The page is paused behind Google's
# scan sheet, so the JS cannot do it; a broadcast reaches the bridge natively and
# it clears the sheet off the task.
sub market_scan_native_stop {
	return 0 unless &subs::device_setter() eq 'mobile';
	my $pid = fork();
	return 0 unless defined $pid;
	if ($pid == 0) {
		$^F = 2;
		open STDOUT, '>', '/dev/null';
		open STDERR, '>', '/dev/null';
		exec('am', 'broadcast', '-a', &subs::app_action('SCAN_STOP'), '-p', &subs::app_package());
		exit 0;
	}
	return 1;
}

# What the session page shows: the raw names stay in the record, the printed ones
# are formatted here so no caller has to remember to unformat an app name.
sub market_scan_session_view {
	my ($s) = @_;
	my @items;
	foreach my $it ( @{ $s->{'items'} || [] } ) {
		next unless ref $it eq 'HASH';
		push @items, {
			%$it,
			formatted => &subs::format_name($it->{'item'} || ''),
			raw_formatted => &subs::format_name($it->{'raw'} || ''),
		};
	}
	my @devices;
	foreach my $d ( &market_scan_session_devices($s) ) {
		push @devices, {
			id => &market_scan_device_id($d),
			kind => ($d->{'kind'} || 'local'),
			label => ($d->{'label'} || (($d->{'kind'} || '') eq 'remote' ? 'Device' : 'this machine')),
			machine => ($d->{'machine'} || ''),
			browser_tab_id => ($d->{'browser_tab_id'} || ''),
		};
	}
	return {
		uuid => ($s->{'uuid'} || ''),
		status => ($s->{'status'} || ''),
		device => ($s->{'device'} || {}),
		devices => \@devices,
		camera => ($s->{'camera'} ? 1 : 0),
		items => \@items,
		count => scalar @items,
	};
}

# Tell a device/tab to start (or stop) its scanner. A peer is reached over the
# signed rail; a tab on this machine gets the console command directly.
sub market_scan_device_send {
	my ($c, $device, $s, $stop) = @_;
	my $bti = $device->{'browser_tab_id'} || '';
	my $machine = $device->{'machine'} || '';
	my %opts = (
		session => $s->{'uuid'},
		device_id => &market_scan_device_id($device),
		origin_machine => &subs::signatorial_designer(),
		list => ($s->{'list'} || ''),
		vendor => ($s->{'vendor'} || ''),
		rapid => 1,
	);
	if (($device->{'kind'} || '') eq 'remote' && $machine ne '') {
		my $rm = &subs::db_select('remote_machines', undef, { ip => $machine })->hashes->[0]
			|| &subs::db_select('remote_machines', undef, { hostname => $machine })->hashes->[0];
		return 0 unless $rm;
		my $peer = &remote_useragent_maker({ rm => $rm });
		my $ua = $peer->{'ua'};
		unless ($ua) {
			$ua = Mojo::UserAgent->new();
			$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
		}
		$ua = $ua->insecure(1)->connect_timeout(2)->inactivity_timeout(4)->request_timeout(6);
		my $url = ($peer->{'manager'} || $rm->{'manager'}) . '/manager/market/scan/remote?peer=yes&signatorial=' . &subs::signatorial_designer();
		my $res = eval { $ua->post($url => form => { %opts, browser_tab_id => $bti, stop => ($stop ? 1 : 0), timestamp => &subs::rightNow() })->result };
		return ($res && $res->is_success) ? 1 : 0;
	}
	return 0 unless $bti ne '';
	&Websocket::send('server', {
		destination => $bti,
		console => ($stop ? &Websocket::console_command('marketPhoneScanStop') : &Websocket::console_command('marketPhoneCamera', \%opts)),
		timestamp => &subs::rightNow()
	});
	return 1;
}

# --- receipts: read a shop receipt into the cart ---
# A receipt is long, so it is scanned - the ADF feeds it in one pass - or
# photographed, and the vision model reads the pages into strict JSON. Each line
# is then matched to a house item: a printed code through the barcode cache, else
# the description folded into our terms by the same model that names a scan. The
# list is only touched once a person confirms, and confirming links each line to
# the list in the cart, so the familiar Checkout is still what writes purchases.
# Whether the house already has an app by this name (a scanned or typed item).
sub market_app_exists {
	my ($item) = @_;
	return 0 unless defined $item && $item ne '';
	my $row = &subs::db_query('select app from settings where app = ? limit 1', $item)->hashes->[0];
	return $row ? 1 : 0;
}

# The list row an item names, if the list already holds one (by our name or by
# what it was typed as).
sub market_list_row {
	my ($item) = @_;
	return undef unless defined $item && $item ne '';
	my $want = &subs::unformat_name($item);
	foreach my $it ( @{ &market_list() } ) {
		return $it if lc($it->{'text'} || '') eq lc($item) || &subs::unformat_name($it->{'text'} || '') eq $want;
	}
	return undef;
}

# Fold a receipt's unknown descriptions into our terms in ONE model call: a
# receipt has many lines, and one call each would be slow and wasteful. Returns
# a hash of description => house name, its misses left absent.
sub market_receipt_name_batch {
	my ($raws) = @_;
	my %out;
	return \%out unless $raws && scalar @{$raws};
	my $listed = join "\n", map { ($_ + 1) . ". " . $raws->[$_] } (0 .. $#{$raws});
	my ($text) = &subs::ai_chat_role('chatbot_model', [
		{ role => 'system', content => 'You name shop products for JawnOS. Give each one a short house name: the thing itself in one or two words (a milk carton is milk, a bar of soap is soap), never a category or a brand. Answer with strict JSON only.' },
		{ role => 'user', content => "Products:\n$listed\nReturn ONLY JSON: {\"names\":[{\"n\":the product number above,\"item\":\"a short house name, one or two words\"}]}." },
	]);
	my ($json) = ($text || '') =~ /(\{.*\})/s;
	my $o = eval { return decode_json $json } || {};
	foreach my $e ( @{ $o->{'names'} || [] } ) {
		next unless ref $e eq 'HASH';
		my $i = ($e->{'n'} || 0) - 1;
		next unless $i >= 0 && $i < scalar @{$raws};
		next unless ($e->{'item'} || '') =~ /\S/;
		$out{ $raws->[$i] } = &subs::unformat_name($e->{'item'});
	}
	return \%out;
}

# The pages of one receipt -> its lines as JSON. All pages go in one call so a
# total printed on the last page is read with the lines above it.
sub market_receipt_read {
	my ($pages) = @_;
	return (undef, 'no receipt image to read') unless $pages && scalar @{$pages};
	my $system = 'You read shop receipts for JawnOS and answer with strict JSON only, no prose.';
	my $ask = 'These images are the pages of ONE shop receipt, page one first. Return ONLY JSON: '
		. '{"vendor":"the shop name or empty","date":"YYYY-MM-DD or empty","total":the printed total as a number or null,'
		. '"payment_method":"the tender as printed (cash, debit, credit, visa, mastercard, amex, mobile, gift, other) or empty",'
		. '"payment_ref":"the card number\'s last 4 digits, or an approval/auth code printed with the tender, digits only, else empty",'
		. '"lines":[{"description":"the item text as printed, trimmed","code":"a barcode, UPC or ISBN printed on that line, digits only, else empty",'
		. '"qty":the quantity as a number (1 when not shown),"price":the line total as a number,"unit_price":the price per unit as a number or null}]}. '
		. 'Prices as plain numbers without symbols. Read the tender/payment rows only into payment_method and payment_ref, never as a line. Include only purchased lines; skip subtotal, tax, change, loyalty, savings and other summary rows.';
	my ($text, $err) = &subs::ai_chat_role('visual_assistant', [
		{ role => 'system', content => $system },
		{ role => 'user', content => $ask, images => $pages },
	], &subs::ai_role_thinking_effective('visual_assistant'));
	return (undef, $err || 'the vision model returned nothing') unless $text;
	my ($json) = $text =~ /(\{.*\})/s;
	my $out = eval { return decode_json $json } || {};
	return (undef, 'the vision model did not return a JSON receipt') unless ref $out eq 'HASH';
	return ($out, undef);
}

# Read a receipt's lines into rows a person can confirm. A printed code resolves
# through the barcode cache; a description the house already keeps is taken as
# is; only the genuinely new descriptions are handed to the batch fold. Every row
# carries what it matched by, so the confirm panel can say why.
sub market_receipt_lines {
	my ($out) = @_;
	my @raw = grep { ref $_ eq 'HASH' } @{ $out->{'lines'} || [] };
	my (@rows, @need);
	foreach my $l ( @raw ) {
		next unless ($l->{'description'} || '') =~ /\S/ || ($l->{'code'} || '') =~ /\S/;
		my $desc = &subs::unformat_name($l->{'description'} || '');
		my $code = $l->{'code'} || '';
		$code =~ s/[^0-9]//g;
		my ($item, $raw, $how) = ('', $desc, '');
		if (length $code >= 8) {
			my $map = &market_barcode_resolve($code);
			if ($map && $map->{'item'}) { $item = $map->{'item'}; $raw = $map->{'raw'} || $desc; $how = 'barcode'; }
		}
		if (!$item && $desc ne '' && (&market_app_exists($desc) || &market_list_row($desc))) { $item = $desc; $how = 'known'; }
		push @need, $desc if !$item && $desc ne '';
		push @rows, { line => $l, desc => $desc, code => $code, raw => $raw, item => $item, how => $how };
	}
	my %named = %{ &market_receipt_name_batch(\@need) } if scalar @need;
	foreach my $r ( @rows ) {
		if (!$r->{'item'}) {
			my $n = $named{ $r->{'desc'} };
			if (!$n && $r->{'desc'} ne '') {
				my $map = &market_barcode_consolidate($r->{'desc'});
				$n = $map->{'item'} if $map && $map->{'item'};
			}
			$r->{'item'} = $n || $r->{'desc'} || $r->{'code'};
			$r->{'how'} ||= 'name';
		}
	}
	my @lines;
	foreach my $r ( @rows ) {
		next unless $r->{'item'} =~ /\S/;
		my $l = $r->{'line'};
		push @lines, {
			description => ($l->{'description'} || ''),
			raw => $r->{'raw'},
			item => $r->{'item'},
			item_formatted => &subs::format_name($r->{'item'}),
			code => $r->{'code'},
			qty => (defined $l->{'qty'} && $l->{'qty'} =~ /[0-9]/) ? 0 + $l->{'qty'} : 1,
			price => (defined $l->{'price'} && $l->{'price'} =~ /[0-9]/) ? 0 + $l->{'price'} : undef,
			unit_price => (defined $l->{'unit_price'} && $l->{'unit_price'} =~ /[0-9]/) ? 0 + $l->{'unit_price'} : undef,
			matched_by => $r->{'how'},
			on_list => (&market_list_row($r->{'item'}) ? 1 : 0),
		};
	}
	return \@lines;
}

# Run the scanner for a receipt, into the market app's own scan folder so the
# pages can be filed as a document afterwards. Synchronous, because the person is
# at the printer waiting, and bounded so a jam cannot wedge the request. A run is
# named by the caller's scan_id so a second request can watch its pages arrive.
# Returns (error, [jpg paths]).
sub market_receipt_scan {
	my ($feed, $scan_id) = @_;
	$scan_id = '' unless defined $scan_id;
	$scan_id =~ s/[^A-Za-z0-9]//g;
	$scan_id = &subs::rightNow() unless length $scan_id;
	my $filename = &subs::home(&subs::setting_grabber({ app => 'misc', setting => 'scan_location', device => $device }) . '/market');
	`mkdir -p $filename` unless -e $filename;
	my $base = $filename . '/receipt_' . $scan_id;
	my $command = &scanner_scan_command($feed, $base);
	return ('the scanner does not offer that feed', []) unless $command;
	$command =~ s/;\s*$//;
	# keep the scanner's own words: the progress view shows them live, and a run
	# that produced nothing says why instead of the old bare "no pages"
	my $log = $base . '.log';
	my $pidfile = $base . '.pid';
	my $cancelfile = $base . '.cancel';
	unlink $cancelfile if -e $cancelfile;
	# run it in the background so its pid is on disk - Cancel can then stop the
	# feed - and wait for it as before, so the request still answers when done
	`timeout 120 $command 2> $log & echo \$! > $pidfile; wait`;
	unlink $pidfile;
	my @tiffs = &scanner_page_list($base);
	my $discard = sub {
		unlink glob("$base*.tiff");
		unlink glob("$base.preview_*.jpg");
		unlink $log;
	};
	if (-e $cancelfile) {
		unlink $cancelfile;
		$discard->();
		return ('the scan was cancelled', []);
	}
	unless (scalar @tiffs) {
		my $why = &scanner_log_reason($log);
		$discard->();
		return ('the scanner produced no pages' . ($why ne '' ? ': ' . $why : ''), []);
	}
	my $photo_size = &subs::setting_grabber({ app => 'misc', setting => 'scan_size', device => $device }) || 'Raw';
	my @jpgs;
	foreach my $t ( @tiffs ) {
		my $jpg = $t;
		$jpg =~ s/\.tiff$/.jpg/;
		if ($photo_size ne 'Raw') {
			my ($pw, $ph) = &subs::image_resolution_parts($photo_size);
			my $converted = ($pw && $ph) ? &subs::image_bridge_convert($t, $jpg, max_width => $pw, max_height => $ph) : undef;
			system('magick', 'convert', $t, '-resize', $photo_size, $jpg) unless $converted;
		}
		else {
			my $converted = &subs::image_bridge_convert($t, $jpg);
			system('magick', 'convert', $t, $jpg) unless $converted;
		}
		`shred -u $t`;
		push @jpgs, $jpg if -e $jpg;
	}
	unlink glob("$base.preview_*.jpg");
	unlink $log;
	return ('the scanned pages could not be read', []) unless scalar @jpgs;
	return (undef, \@jpgs);
}

# The last lines of a log, read from its tail so a chatty scanner (--progress
# writes a lot) does not make every poll slurp the whole file.
sub scanner_log_tail {
	my ($log, $bytes) = @_;
	$bytes ||= 4096;
	return () unless $log && -e $log;
	open(my $fh, '<', $log) or return ();
	my $size = -s $log;
	seek($fh, $size > $bytes ? $size - $bytes : 0, 0);
	my $tail = do { local $/; <$fh> };
	close $fh;
	return grep { /\S/ } split /[\r\n]+/, ($tail || '');
}

# The scanner's own last word on why a run produced nothing, in plain terms. The
# useful line is scanimage's error ("Document feeder out of documents", "Error
# during device I/O"), not the batch summary printed after it.
sub scanner_log_reason {
	my ($log) = @_;
	my @lines = &scanner_log_tail($log);
	my $why = '';
	foreach my $l ( @lines ) {
		$why = $l if $l =~ /scanimage:/;
	}
	return '' unless $why ne '';
	$why =~ s/^\s+|\s+$//g;
	$why =~ s/^scanimage:\s*//;
	$why =~ s/^sane_start:\s*//i;
	return 'the feeder has no paper' if $why =~ /out of documents|no documents/i;
	return 'the feeder could not pull the page (device I/O) - check it sits square in the tray, or use the flatbed' if $why =~ /device I\/O/i;
	return lcfirst $why;
}

# Save a bridged or uploaded receipt page into the market app's scan folder, so
# the paper can be filed like a scanned one. Returns the jpg path, or undef when
# it could not be converted.
sub market_receipt_store {
	my ($bytes) = @_;
	return undef unless $bytes && length $bytes;
	my $folder = &subs::home(&subs::setting_grabber({ app => 'misc', setting => 'scan_location', device => $device }) . '/market');
	`mkdir -p $folder` unless -e $folder;
	my $jpg = $folder . '/receipt_' . &subs::rightNow() . '.jpg';
	my $tmp = $jpg . '.in';
	write_file($tmp, $bytes);
	my $converted = &subs::image_bridge_convert($tmp, $jpg);
	system('magick', 'convert', $tmp, $jpg) unless $converted;
	unlink $tmp;
	return (-e $jpg && -s $jpg) ? $jpg : undef;
}

# Keep the receipt: its pages stay where the scanner put them (the market app's
# own folder) and a record of what it was - vendor, total, date, the lines read -
# is kept under the market app's own settings, beside the shopping list and the
# barcode cache rather than as an appointment, so nothing else about the app is
# touched by a receipt.
sub market_receipt_file {
	my ($data) = @_;
	my @files = grep { defined $_ && -e $_ } @{ $data->{'files'} || [] };
	return unless scalar @files;
	my $raw = &subs::setting_grabber({ app => 'market', setting => 'receipts' });
	my $receipts = eval { return decode_json $raw } || [];
	$receipts = [ grep { ref $_ eq 'HASH' } @{$receipts} ];
	my @lines;
	foreach my $l ( @{ $data->{'lines'} || [] } ) {
		next unless ref $l eq 'HASH';
		push @lines, {
			item => ($l->{'item'} || ''),
			qty => ($l->{'qty'} || 1),
			price => $l->{'price'},
		};
	}
	unshift @{$receipts}, {
		uuid => &subs::random_string_creator(20),
		at => &subs::rightNow(),
		date => ($data->{'date'} || ''),
		vendor => ($data->{'vendor'} || ''),
		total => (defined $data->{'total'} && $data->{'total'} =~ /[0-9]/) ? 0 + $data->{'total'} : undef,
		payment_method => ($data->{'payment_method'} || ''),
		payment_ref => ($data->{'payment_ref'} || ''),
		account => ($data->{'account'} || ''),
		files => \@files,
		lines => \@lines,
	};
	pop @{$receipts} while scalar @{$receipts} > 50;
	&subs::setting_setter({ app => 'market', setting => 'receipts', value => encode_json($receipts) });
}

# The scan feeds THIS machine can run: the capability table's answer for the host
# device. A computer has the ADF and the flatbed, a server neither, so the Market
# offers the scanner buttons only when this is non-empty (a phone reaching the
# house still scans on the computer that holds the scanner - the scan runs here).
sub market_scan_feeds {
	return [ @{ $gb::capabilities->{&subs::device_setter()}->{'scan'} || [] } ];
}

# The kept receipts, newest first (the raw `receipts` setting on the market app).
sub market_receipts {
	my $raw = &subs::setting_grabber({ app => 'market', setting => 'receipts' });
	my $receipts = eval { return decode_json $raw } || [];
	return [ grep { ref $_ eq 'HASH' } @{$receipts} ];
}

# The kept receipts prepared for the Market pane: the pages that are still on
# disk as /file_open links, and each receipt's lines ready to re-apply (so the
# pane can put the whole shop back on the list in one press).
sub market_receipts_prepared {
	my @out;
	foreach my $r ( @{ &market_receipts() } ) {
		my @files = grep { defined $_ && -e $_ } @{ $r->{'files'} || [] };
		my @pages;
		if ($r->{'uuid'}) {
			my $i = 0;
			foreach my $f ( @files ) {
				push @pages, { url => '/manager/market/receipt_page?uuid=' . $r->{'uuid'} . '&page=' . $i, path => $f };
				$i++;
			}
		}
		my @lines;
		foreach my $l ( @{ $r->{'lines'} || [] } ) {
			next unless ref $l eq 'HASH' && ($l->{'item'} || '') =~ /\S/;
			push @lines, { include => 1, item => $l->{'item'}, qty => (defined $l->{'qty'} ? $l->{'qty'} : 1), price => $l->{'price'} };
		}
		push @out, {
			%{$r},
			pages => \@pages,
			apply_json => encode_json(\@lines),
			files_json => encode_json(\@files),
		};
	}
	return \@out;
}

# Group warehouse rows for the warehouse app. The warehouse holds both money
# and stock: a money row is one that names an account (or is denominated in a
# currency measure), everything else is stock grouped by place, then item,
# then unit. Used for the place view and for item search.
sub warehouse_grabber($opts) {
	my $search = $opts->{'search'};
	my $places = $opts->{'places'} || [];
	my $rows;
	if (defined $search && $search ne '') {
		$rows = &subs::db_query('select * from warehouse where item like ? order by timestamp asc', '%' . $search . '%')->hashes;
	}
	elsif (scalar grep { $_ ne 'all' } @{$places}) {
		my @ps = grep { $_ ne 'all' } @{$places};
		my $in = join ',', map { '?' } @ps;
		# money rows carry no place, so keep them in view alongside the picked places
		$rows = &subs::db_query("select * from warehouse where place in ($in) or place is null or place = '' order by timestamp asc", @ps)->hashes;
	}
	else {
		$rows = &subs::db_select('warehouse')->hashes;
	}
	my $warehouse = { places => {}, accounts => {}, items => {}, expires => {}, latest => {} };
	my %expires_cache;
	foreach my $r ( @{$rows} ) {
		my $unit = $r->{'unit'} || 'each';
		my $qty = &subs::numeric_formatter($r->{'quantity'}) + 0;
		# the three faces: stock on a place, a money move, and the balance anchors
		# (inventory). The anchors and stock belong to the Levels view; the money
		# moves are the Moves view's, so they are left out here to keep a
		# snapshot from being counted twice.
		my $kind = $r->{'kind'};
		$kind = ($r->{'type'} eq 'inventory' ? 'inventory' : (($r->{'account'} && $r->{'account'} ne '') ? 'money' : 'stock')) if !defined $kind || $kind eq '';
		if ($kind eq 'money') { next; }
		next if $kind eq 'usage';
		if ($kind eq 'inventory') {
			my $acct = $r->{'account'} || $r->{'item'} || 'cash';
			my $cur = $r->{'currency'} || $unit;
			$warehouse->{'accounts'}->{$acct}->{$cur} = ($warehouse->{'accounts'}->{$acct}->{$cur} || 0) + $qty;
		}
		elsif ($r->{'item'}) {
			my $item = $r->{'item'};
			my $place = ($r->{'place'} && $r->{'place'} ne '') ? $r->{'place'} : 'unplaced';
			$warehouse->{'places'}->{$place}->{$item}->{$unit} = ($warehouse->{'places'}->{$place}->{$item}->{$unit} || 0) + $qty;
			$warehouse->{'items'}->{$item}->{$place}->{$unit} = ($warehouse->{'items'}->{$item}->{$place}->{$unit} || 0) + $qty;
			unless (defined $expires_cache{$item}) {
				$expires_cache{$item} = &subs::warehouse_item_expires($item);
			}
			if ($expires_cache{$item}) {
				$warehouse->{'expires'}->{$item} = $expires_cache{$item};
				my $ts = &subs::numeric_formatter($r->{'timestamp'}) + 0;
				$warehouse->{'latest'}->{$item} = $ts if $ts > ($warehouse->{'latest'}->{$item} || 0);
			}
		}
	}
	return $warehouse;
}

1;
