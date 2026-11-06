package subs;

# Git: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Crypt::PK::ECC;
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

our %H;
our $config;
our @crypto_asset_list;
our $crypto_base58_alphabet;
our %crypto_base58_index;
our $crypto_bech32_charset;
our @crypto_fiat_table;
# ---- watch-only Bitcoin addresses (BIP32 public derivation) -------------------
# An account xpub is public: it derives receive addresses and cannot spend. A
# wallet that carries one gives every invoice its own address. OpenSSL does the
# scalar multiple (import the scalar as a private key, export its public point)
# and the hash/encoding work; the one step it does not expose - adding the
# parent point to IL*G - is a handful of BigInt operations below.
#
# Everything here is public data. There is deliberately no function that takes a
# private key, a seed phrase or an xprv.
our $crypto_secp256k1_p;
our $device;
our $git_watcher_blocked_note;
our $log;
our $logfile;
our %m;

sub git_watcher_check {
	# A tree seeded from the image has no .git until jawnos-update.service
	# bootstraps it; that unit owns the first checkout, so staying silent here is
	# correct (an hourly no-repo note would only be noise).
	return unless -d '.git';
	# Update method is the house's choice of authority: none stops auto-update,
	# the manual modes leave it off for the Dev panel's Update now button, github
	# follows origin/main alone, peers takes only a peer's fast-forward, and any
	# (the default) tries GitHub first, then a peer. An explicit update still
	# works whatever the method says.
	my $method = &subs::sync_update_method_get();
	return if $method eq 'none' || $method eq 'manual_github' || $method eq 'manual_peers';
	my $before = `git rev-parse HEAD 2>/dev/null`; chomp $before;
	# `any` keeps the old order: the checkout follows origin/main first, and only a
	# machine origin cannot move forward - the fetch failed (the mesh answers while
	# the internet does not), or it holds commits origin/main lacks - consults a
	# peer as the fallback. A peer pull must be a true fast-forward: the old order
	# ("whoever has the newest is it") let a peer whose advertised version outran
	# its actual tree reset this machine backward through the rewritten-history
	# path, so the watcher never accepts a peer reset. A peer with rewritten
	# history, or with work the whole house should ride, pushes to GitHub and the
	# authority carries it everywhere.
	my ($status, $out) = ('none', '');
	($status, $out) = &subs::git_repo_update({ repo => '.', force => 0 }) unless $method eq 'peers';
	unless ($status eq 'dirty' || $status eq 'updated' || $status eq 'reset' || $status eq 'current') {
		return unless $method eq 'peers' || $method eq 'any';
		my ($pst, $pout) = &subs::git_peer_update_best({ repo => '.' });
		if ($pst eq 'updated') { $status = 'peer/updated'; $out = $pout; }
		elsif ($pst ne 'none') { $status = $pst; $out = $pout; }
	}
	return if $status eq 'current';
	unless ($status eq 'updated' || $status eq 'reset' || $status eq 'peer/updated') {
		# A machine that cannot move names the reason once an hour: dirty tracked
		# files, local commits the authority does not have, or no fetch and no
		# newer peer. The silent versions of these looked exactly like a watcher
		# that was not running - which is how a phone sat ten versions behind.
		my $now = &subs::rightNow();
		if ((!$git_watcher_blocked_note || $now - $git_watcher_blocked_note > 3600000) && $subs::logfile) {
			$git_watcher_blocked_note = $now;
			my $detail = '';
			if ($status eq 'ahead' || $status eq 'diverged' || $status eq 'peer/diverged') {
				my $git = &subs::git_binary();
				$detail = `cd . && "$git" log --oneline --max-count=3 origin/main..HEAD 2>/dev/null`;
				$detail =~ s/\s+/ /g;
				$detail = ' commits: ' . $detail if $detail;
			}
			my $label = ($status eq 'dirty') ? 'tree is dirty' : ($status eq 'none' ? 'no newer peer' : $status);
			open(my $fh, '>>', $subs::logfile);
			print $fh $now . " git watcher: $label, left alone$detail\n";
			close $fh;
		}
		return;
	}
	if ($subs::logfile) {
		my $after = `git rev-parse HEAD 2>/dev/null`; chomp $after;
		# name the source in the log: origin is the authority, a peer the fallback
		my $label = ($status =~ m{^peer/}) ? $status : "origin/$status";
		open(my $fh, '>>', $subs::logfile);
		print $fh &subs::rightNow() . " git watcher: $label " . substr($before,0,10) . " -> " . substr($after,0,10) . ", restarting\n";
		close $fh;
	}
	# A desktop host keeps an installed copy of the app in
	# ~/.local/share/jawnos/desktop; the pulled code has to land there too, or the
	# old install keeps running. (An already-open GUI picks it up on next launch.)
	if (-d &subs::home('~/.local/share/jawnos/desktop') && -x './desktop/install.sh') {
		`./desktop/install.sh >/dev/null 2>&1`;
	}
	# a new version may name a new application to install (Piper, say) or a new
	# Perl module to `use`; both are user-side and best effort
	&subs::install_extras();
	&subs::install_local_modules('.');
	my $after_commit = `git rev-parse --short HEAD 2>/dev/null`;
	chomp $after_commit;
	my $from = substr($before, 0, 10);
	$from = '?' unless length $from;
	&subs::restart_request('the git watcher moved the tree ' . $from . ' -> ' . (length $after_commit ? $after_commit : '?'));
}

# A Mojo::UserAgent that speaks to a peer the way remote_useragent_maker builds
# one - the tunnel-aware manager url plus the session cookie we already hold for
# it. Kept in subroutines so the boot-time loops, which run before Manager.pl is
# loaded, can reach a peer without pulling the whole app in.
sub peer_useragent {
	my $rm = shift;
	return (undef, $rm) unless $rm && $rm->{'cookie'} && $rm->{'manager'};
	# A stored loopback manager is the hub's own tunnel route. On any other row it
	# is a leftover from a tunnel that no longer exists, and the peer's name is
	# the only address left - so call the name. Left unfixed, every peer call (the
	# health probe, the handshake that decides whether to pull, the advert) dials
	# 127.0.0.1 on a port that belongs to nothing, and the machine never syncs
	# while looking perfectly reachable in a browser.
	$rm->{'manager'} = &peer_live_manager($rm);
	$rm = &subs::remote_machine_tunnel_processor($rm);
	my ($secure_manager, $peer_verified) = &subs::peer_secure_url($rm, $rm->{'manager'});
	$rm->{'manager'} = $secure_manager if $peer_verified;
	my $jar = eval { decode_json $rm->{'cookie'} };
	return (undef, $rm) unless $jar && ref $jar eq 'ARRAY';
	require Mojo::Cookie::Response;
	my $ua = Mojo::UserAgent->new;
	$ua = $ua->max_response_size(0);
	foreach my $c ( @{$jar} ) {
		next unless $c->{'name'};
		$ua->cookie_jar->add(Mojo::Cookie::Response->new(
			name   => $c->{'name'},
			value  => $c->{'value'},
			domain => $c->{'domain'} || '',
			path   => $c->{'path'} || '/',
		));
	}
	if (!$peer_verified) { $ua->insecure(1) }
	# ride the same signed rail every other peer call rides: once a key is
	# pinned, an unsigned request is refused, and this UA serves the git bundle,
	# the APK sync and the voice sync - all peer_verify routes. (Unsigned was
	# only ever accepted while the peer had no key on file.)
	$ua->on(start => sub { my ($ua, $tx) = @_; &peer_sign_request($tx->req); });
	return ($ua, $rm);
}

# Append one line to the app-release sync's own log (the manager log). Quiet
# when there is no logfile yet (an early boot).
sub app_release_log {
	my $line = shift;
	return unless $subs::logfile;
	open(my $fh, '>>', $subs::logfile) or return;
	print $fh &subs::rightNow() . " app release: $line\n";
	close $fh;
}

# Fetch a URL into a string. curl first, forced to IPv4: on a network whose IPv6
# path to GitHub's asset CDN stalls, Mojo::UserAgent (which does not pin the
# address family) hangs where curl -4 completes. Falls back to Mojo when curl is
# absent, then to curl without -4 for a host that has no A record.
sub github_fetch {
	my ($url, $timeout) = @_;
	$timeout ||= 60;
	my $curl = `command -v curl 2>/dev/null`;
	chomp $curl;
	if ($curl) {
		foreach my $args ( ['-4'], [] ) {
			my $tmp = "/tmp/jawn_gh_" . $$ . "_" . int(rand(1_000_000));
			my $rc = system($curl, @{$args}, '-sSL', '--max-time', "$timeout", '-o', $tmp, $url);
			if ($rc == 0 && -s $tmp) {
				my $body;
				if (open(my $fh, '<', $tmp)) { binmode $fh; local $/; $body = <$fh>; close $fh; }
				unlink $tmp;
				return $body if defined $body && length $body;
			}
			unlink $tmp;
		}
	}
	my $ua = Mojo::UserAgent->new(connect_timeout => 10, inactivity_timeout => $timeout);
	$ua->max_response_size(0);
	$ua->max_redirects(5);
	my $res = eval { $ua->get($url)->result };
	return ($res && $res->is_success) ? $res->body : undef;
}

# The public app-release manifest on GitHub - a source that needs no peer to
# answer, or to hold a valid cookie for us. The release carries app_release.json
# (product, versionCode, versionName, filename, sha256) beside the APK, under a
# fixed tag so the URL never moves; the download is a plain github.com asset,
# not the rate-limited API. Returns the manifest plus the asset base url, or
# undef when there is no release (or no network).
sub github_release_manifest {
	my ($repo, $tag, $file) = @_;
	return undef unless $repo && $repo =~ m{^[^/\s]+/[^/\s]+\z};
	$tag ||= 'releases';
	$file ||= 'app_release.json';
	return undef unless $file =~ /^[A-Za-z0-9_.-]+$/;
	my $base = "https://github.com/$repo/releases/download/$tag";
	my $body = &github_fetch("$base/$file", 30);
	unless (defined $body && length $body) {
		&app_release_log('github manifest fetch failed (' . $base . '/' . $file . ')');
		return undef;
	}
	my $man = eval { decode_json $body };
	return undef unless $man && ref $man eq 'HASH'
		&& $man->{'product'} && $man->{'versionCode'} && $man->{'filename'};
	$man->{'base'} = $base;
	return $man;
}

# Reconcile the staged app releases (the APKs under releases/) with the newest a
# reachable peer holds: a device that is behind pulls the APK in, so every
# device becomes a holder and a source. The APK is a blob (gitignored) carried
# over http, not through git - a ~35 MB binary per version in git history would
# be untenable. Pull, on the watcher's slow tick; the code watcher keeps the
# Perl tree current. GitHub's release manifest is consulted too, so a device
# with no reachable peer (or no valid peer cookie) still updates.
# Cache each reachable peer's Ollama model list, so Plat can offer models by the
# machine they run on without waiting on the network. Runs on a slow tick; a
# peer that goes quiet keeps its last list until it answers again.
sub ollama_models_sync {
	my $me = &subs::signatorial_designer();
	my $rms = &subs::db_select('remote_machines')->hashes || [];
	foreach my $rm ( @{$rms} ) {
		my $rsig = $rm->{'signatorial'};
		next unless $rsig && $rsig ne $me;
		my ($ua, $p) = &subs::peer_useragent($rm);
		next unless $ua;
		my $res = eval { $ua->inactivity_timeout(15)->get($p->{'manager'} . '/manager/ollama_models?signatorial=' . $me)->result };
		next unless $res && $res->is_success;
		my $body = eval { decode_json $res->body };
		next unless $body && ref $body eq 'HASH';
		my $models = $body->{'models'};
		next unless ref $models eq 'ARRAY';
		my $update = { ollama_models => encode_json($models) };
		$update->{'hostname'} = $body->{'hostname'} if $body->{'hostname'};
		&subs::db_update('remote_machines', $update, { signatorial => $rsig });
	}
}

sub app_release_sync {
	my $dir = &subs::home('~/jawnos/releases');
	mkdir $dir unless -d $dir;
	my $me = &subs::signatorial_designer();
	my (%local, %best);
	# One product: a leftover jawnos-api APK on some peer is not an update to
	# carry (the API app is retired - its bridge lives in the main APK). Drop a
	# copy this machine already staged, and say so once per pass.
	foreach my $stale ( glob("$dir/jawnos-api-*.apk") ) {
		unlink $stale and &app_release_log('removed retired ' . ($stale =~ m{/([^/]+)$})[0]);
	}
	foreach my $f ( glob("$dir/jawnos-app-*.apk") ) {
		my ($vc) = ( $f =~ m{/jawnos-app-(\d+)-} );
		next unless $vc;
		$local{'app'} = $vc if !$local{'app'} || $vc > $local{'app'};
	}
	my $rms = &subs::db_select('remote_machines')->hashes || [];
	foreach my $rm ( @{$rms} ) {
		my $rsig = $rm->{'signatorial'};
		next unless $rsig && $rsig ne $me;
		my ($ua, $p) = &subs::peer_useragent($rm);
		next unless $ua;
		my $res = eval { $ua->inactivity_timeout(20)->get($p->{'manager'} . '/manager/app_release?signatorial=' . $me)->result };
		next unless $res && $res->is_success;
		my $body = eval { decode_json $res->body };
		unless ($body && ref $body eq 'HASH') {
			&app_release_log('peer ' . ($rm->{'hostname'} || $rsig) . ' did not answer app_release with JSON (stale session cookie?)');
			next;
		}
		my $phost = $body->{'hostname'} || $rm->{'hostname'} || $rsig;
		foreach my $rel ( @{ $body->{'releases'} || [] } ) {
			my ($product, $vc) = ($rel->{'product'}, ($rel->{'versionCode'} || 0) + 0);
			next unless $product && $product eq 'app' && $vc;
			next if $local{$product} && $vc <= $local{$product};
			next if $best{$product} && $vc <= $best{$product}->{'versionCode'};
			$best{$product} = { %$rel, versionCode => $vc, manager => $p->{'manager'}, ua => $ua, host => $phost };
		}
	}
	foreach my $product ( sort keys %best ) {
		next unless $product eq 'app';
		my $b = $best{$product};
		my $filename = $b->{'filename'};
		next unless $filename && $filename =~ /^jawnos-\Q$product\E-\d+-[^\/]+\.apk$/;
		my $url = $b->{'manager'} . '/manager/app_download?product=' . $product . '&versionCode=' . $b->{'versionCode'} . '&signatorial=' . $me;
		my $res = eval { $b->{'ua'}->inactivity_timeout(300)->get($url)->result };
		next unless $res && $res->is_success && defined $res->body && length $res->body;
		my $blob = $res->body;
		my $sha = eval { require Digest::SHA; Digest::SHA::sha256_hex($blob) };
		next if $b->{'sha256'} && $sha && $sha ne $b->{'sha256'};
		my $dest = "$dir/$filename";
		write_file("$dest.tmp", $blob);
		unlink $_ for grep { $_ ne "$dest.tmp" } glob("$dir/jawnos-$product-*.apk");
		rename("$dest.tmp", $dest) or next;
		&app_release_log('pulled ' . $product . ' v' . $b->{'versionCode'} . ' (' . length($blob) . ' bytes) from ' . $b->{'host'});
	}
	# GitHub last: a public source that needs no peer, so a device with no
	# reachable peer (or a stale peer cookie) still updates. It is deliberately
	# *after* the peer rail - a reachable peer on the LAN answers and serves in
	# seconds, while the phone's path to the asset CDN can crawl at 24 KB/s, so
	# a 37 MB APK takes ~25 minutes and held the peer fallback up behind it.
	# The app manifest. A product a peer already supplied is skipped here
	# ($local moved with it), and a peer that advertised a build it could not
	# deliver still leaves $local behind for this pass to catch. The api
	# manifest is gone with the API app; an older peer may still serve it, and
	# the product filter above ignores it.
	foreach my $manifest_file (qw(app_release.json)) {
		my $gh = &github_release_manifest(
			$config->{'github_repo'} || 'jonathanferwerda/jawnos',
			$config->{'github_release_tag'} || 'releases',
			$manifest_file);
		next unless $gh && $gh->{'product'} && ($gh->{'versionCode'} || 0) > 0;
		my $gp = $gh->{'product'};
		my $gv = $gh->{'versionCode'} + 0;
		my $gf = $gh->{'filename'};
		next unless (!$local{$gp} || $gv > $local{$gp})
			&& $gf && $gf =~ /^jawnos-\Q$gp\E-\d+-[^\/]+\.apk$/;
		my $blob = &github_fetch($gh->{'base'} . '/' . $gf, 600);
		unless (defined $blob && length $blob) {
			&app_release_log('github ' . $gp . ' v' . $gv . ' did not download; no peer supplied it either');
		}
		my $sha = (defined $blob && length $blob) ? eval { require Digest::SHA; Digest::SHA::sha256_hex($blob) } : undef;
		if (defined $blob && length $blob && (!$gh->{'sha256'} || ($sha && $sha eq $gh->{'sha256'}))) {
			my $dest = "$dir/$gf";
			write_file("$dest.tmp", $blob);
			unlink $_ for grep { $_ ne "$dest.tmp" } glob("$dir/jawnos-$gp-*.apk");
			if (rename("$dest.tmp", $dest)) {
				$local{$gp} = $gv;
				&app_release_log('pulled ' . $gp . ' v' . $gv . ' (' . length($blob) . ' bytes) from github');
			}
		}
	}
}

# Reconcile the voice models (voices/*.onnx and their json) with a reachable peer.
# Models are arch-independent, so they travel the same way the APKs do - a device
# that lacks one pulls it in and can then serve it, so every device ends up with
# the same voices. The piper binary is per-arch and stays local, so it is never
# part of this list. The models are immutable, so presence is enough: no version
# to compare, unlike an APK.
sub voice_sync {
my $dir = &subs::home('~/jawnos/voices');
mkdir $dir unless -d $dir;

	# The CC BY voices need their attribution with the models, not only in the
	# repository docs. The prune pass below only touches *.onnx, so this file
	# stays on every device that holds the voices.
	my $attribution = "$dir/ATTRIBUTION.md";
	unless (-f $attribution) {
		my @attrib = (
			'# Voice model attribution',
			'',
			'This directory carries Piper voice models. Two are fine-tuned from',
			'datasets licensed CC BY 4.0, which requires attribution:',
			'',
			'- en_US-libritts_r-medium: LibriTTS-R (OpenSLR 141), CC BY 4.0.',
			'  http://www.openslr.org/141/',
			'  https://creativecommons.org/licenses/by/4.0/',
			'- en_GB-alba-medium: Alba (Edinburgh DataShare 10283/3270), CC BY 4.0.',
			'  https://datashare.ed.ac.uk/handle/10283/3270',
			'  https://creativecommons.org/licenses/by/4.0/',
			'- en_US-ljspeech-medium: LJSpeech, public domain.',
			'  https://keithito.com/LJ-Speech-Dataset/',
			'',
			'See docs/voice-attribution.md in the JawnOS tree for the full notice.',
		);
		write_file($attribution, join("\n", @attrib) . "\n");
	}
my $me = &subs::signatorial_designer();
	my %local;
	foreach my $f ( glob("$dir/*.onnx"), glob("$dir/*.onnx.json") ) {
		my ($base) = $f =~ m{/([^/]+)$};
		$local{$base} = 1 if $base;
	}
my $rms = &subs::db_select('remote_machines')->hashes || [];
foreach my $rm ( @{$rms} ) {
	my $rsig = $rm->{'signatorial'};
	next unless $rsig && $rsig ne $me;
	my ($ua, $p) = &subs::peer_useragent($rm);
	next unless $ua;
	my $res = eval { $ua->inactivity_timeout(20)->get($p->{'manager'} . '/manager/voice_release?signatorial=' . $me)->result };
	next unless $res && $res->is_success;
	my $body = eval { decode_json $res->body } || {};
	my $phost = $body->{'hostname'} || $rm->{'hostname'} || $rsig;
	foreach my $v ( @{ $body->{'voices'} || [] } ) {
		my $filename = $v->{'filename'};
		next unless $filename && $filename =~ /^[A-Za-z0-9_.-]+\.onnx(\.json)?$/;
		next if $local{$filename};
		my $url = $p->{'manager'} . '/manager/voice_download?file=' . $filename . '&signatorial=' . $me;
		my $vres = eval { $ua->inactivity_timeout(300)->get($url)->result };
		next unless $vres && $vres->is_success && defined $vres->body && length $vres->body;
		my $blob = $vres->body;
		my $sha = eval { require Digest::SHA; Digest::SHA::sha256_hex($blob) };
		next if $v->{'sha256'} && $sha && $sha ne $v->{'sha256'};
		my $dest = "$dir/$filename";
		write_file("$dest.tmp", $blob);
		rename("$dest.tmp", $dest) or next;
		$local{$filename} = 1;
		if ($subs::logfile) {
			open(my $fh, '>>', $subs::logfile);
			print $fh &subs::rightNow() . " voice: pulled $filename (" . length($blob) . " bytes) from " . $phost . "\n";
			close $fh;
		}
	}
}

	# Keep only the voices the running code names. A model dropped from
	# say_voices() (a licence problem, say) is removed here, so no device goes on
	# serving or speaking with it. Never touches the per-arch piper/ bundle.
	# Only prune once every sanctioned voice is present: a device that could not
	# reach a peer keeps its old models rather than being left with none.
	my (%wanted, $complete);
	$complete = 1;
	foreach my $v ( &subs::say_voices() ) {
		next unless ($v->{'engine'} || '') eq 'piper' && $v->{'model'};
		$wanted{ $v->{'model'} . '.onnx' } = 1;
		$wanted{ $v->{'model'} . '.onnx.json' } = 1;
		$complete = 0 unless -e "$dir/" . $v->{'model'} . '.onnx';
	}
	if ($complete) {
		foreach my $f ( glob("$dir/*.onnx"), glob("$dir/*.onnx.json") ) {
			my ($base) = $f =~ m{/([^/]+)$};
			unlink $f if $base && !$wanted{$base};
		}
	}
}

sub crypto_fiat_table { return [ map { { %{$_} } } @crypto_fiat_table ] }

sub crypto_fiat_codes { return [ map { $_->{'code'} } @crypto_fiat_table ] }

sub crypto_fiat {
	my ($code) = @_;
	return undef unless defined $code && length $code;
	$code = uc $code;
	foreach my $f ( @crypto_fiat_table ) { return { %{$f} } if $f->{'code'} eq $code; }
	return undef;
}

sub crypto_assets {
	return [ map { { %{$_} } } @crypto_asset_list ];
}

sub crypto_asset {
	my ($code) = @_;
	return undef unless defined $code && length $code;
	$code = uc $code;
	foreach my $a ( @crypto_asset_list ) {
		return { %{$a} } if $a->{'code'} eq $code;
	}
	return undef;
}

sub crypto_enabled {
	my $v = &setting_grabber({ app => 'crypto', setting => 'enabled', device => 'all' });
	return 0 if defined $v && $v eq 'off';
	return 1;
}

sub crypto_enabled_assets {
	my $raw = &setting_grabber({ app => 'crypto', setting => 'assets', device => 'all' });
	my $list = eval { decode_json($raw) };
	$list = [] unless ref $list eq 'ARRAY';
	my %known = map { $_->{'code'} => 1 } @crypto_asset_list;
	$list = [ 'BTC', 'ETH', 'USDC', 'USDT' ] unless scalar @{$list};
	my @out = grep { $known{$_} } map { uc $_ } @{$list};
	return @out ? \@out : [ 'BTC', 'ETH', 'USDC', 'USDT' ];
}

# The house's reporting currency: the one the ledger, budgets and statements
# already speak. misc/currency can arrive as a JSON list, so read the first
# three-letter code from it.
sub crypto_report_currency {
	my $c = &setting_grabber({ app => 'misc', setting => 'currency', benign => 1 });
	$c = '' unless defined $c;
	$c =~ s/[^A-Za-z]//g;
	$c = uc substr($c, 0, 3);
	return $c =~ /^[A-Z]{3}$/ ? $c : 'CAD';
}

# The coin an account holds, or '' when it is not a wallet. The asset setting is
# what names it; an older wallet with only the tender set is Bitcoin, so a row
# never becomes unreadable.
sub crypto_account_asset {
	my ($app) = @_;
	return '' unless defined $app && length $app;
	my $tender = &setting_grabber({ app => $app, setting => 'payment_type' });
	return '' unless defined $tender && lc($tender) eq 'crypto';
	my $asset = &crypto_asset(&setting_grabber({ app => $app, setting => 'crypto_asset' }));
	$asset ||= &crypto_asset('BTC');
	return $asset->{'code'};
}

sub crypto_accounts {
	my $rows = &db_query("select distinct app from settings where setting = 'payment_type' and lower(value) = 'crypto' order by app")->hashes;
	my @out;
	foreach my $r ( @{$rows} ) {
		my $s = &settings_grabber({ app => $r->{'app'}, settings => [ qw/crypto_asset crypto_network wallet_address wallet_label currency/ ] });
		my $asset = &crypto_asset($s->{'crypto_asset'}) || &crypto_asset('BTC');
		my $xpub = &crypto_wallet_setting($r->{'app'}, 'wallet_xpub') || '';
		my $static_address = &crypto_wallet_setting($r->{'app'}, 'wallet_address') || '';
		push @out, {
			app => $r->{'app'},
			formatted_name => &format_name($r->{'app'}),
			asset => $asset->{'code'},
			asset_name => $asset->{'name'},
			decimals => $asset->{'decimals'},
			network => $s->{'crypto_network'} || $asset->{'network'},
			address => $static_address,
			label => $s->{'wallet_label'} || '',
			xpub => $xpub,
			per_invoice => ($xpub ne '' && $asset->{'code'} eq 'BTC') ? 1 : 0,
			currency => $s->{'currency'} || &crypto_report_currency(),
		};
	}
	return \@out;
}

# A typed amount becomes a plain decimal string, never a float: 18-decimal coins
# would lose their last places on the way through a Perl number. Commas are
# thousands separators (the same rule numeric_formatter uses) and only the last
# dot is a decimal point.
sub crypto_amount_number {
	my ($text, $asset) = @_;
	return undef unless defined $text;
	my $a = ref $asset eq 'HASH' ? $asset : &crypto_asset($asset);
	my $decimals = $a ? $a->{'decimals'} : 8;
	$text = "$text";
	$text = Text::Unidecode::unidecode($text) if $text =~ /[^\x00-\x7F]/;
	$text =~ s/[^0-9.,\-]//g;
	my $negative = $text =~ /-/ ? 1 : 0;
	$text =~ s/-//g;
	$text =~ s/,//g;
	$text =~ s/\.(?=.*\.)//g;
	$text = '0' if $text eq '' || $text eq '.';
	return undef unless $text =~ /^\d+(?:\.\d+)?$/;
	my ($int, $frac) = split /\./, $text, 2;
	$frac = '' unless defined $frac;
	$int =~ s/^0+(?=\d)//;
	$frac = substr($frac, 0, $decimals) if $decimals >= 0;
	$frac =~ s/0+$//;
	my $out = length $frac ? "$int.$frac" : $int;
	$out = "-$out" if $negative && $out ne '0';
	return $out;
}

# Display form: the coin's own decimals, trimmed, with at least two places so a
# small amount still reads as money rather than a bare integer.
sub crypto_amount_format {
	my ($amount, $asset) = @_;
	my $a = ref $asset eq 'HASH' ? $asset : &crypto_asset($asset);
	my $code = $a ? $a->{'code'} : (defined $asset && length $asset ? uc $asset : '');
	my $decimals = $a ? $a->{'decimals'} : 8;
	my $n = defined $amount ? "$amount" : '0';
	my $negative = $n =~ /^-/ ? 1 : 0;
	$n =~ s/^-//;
	$n =~ s/[^0-9.]//g;
	my ($int, $frac) = split /\./, $n, 2;
	$int = '0' unless defined $int && length $int;
	$frac = '' unless defined $frac;
	my $cap = $decimals > 8 ? 8 : $decimals;
	$frac = substr($frac, 0, $cap);
	$frac =~ s/0+$//;
	$frac .= ('0' x (2 - length $frac)) if length $frac < 2;
	my $out = ($negative ? '-' : '') . $int . '.' . $frac;
	return length $code ? "$out $code" : $out;
}

# A seed phrase pasted into an address field is refused before it is stored.
sub crypto_looks_like_secret {
	my ($text) = @_;
	return 0 unless defined $text && length $text;
	my $t = lc $text;
	return 1 if $t =~ /\b(seed phrase|mnemonic|private key|recovery phrase)\b/;
	my @words = grep { length } split /\s+/, $t;
	my $count = scalar @words;
	return 1 if ($count == 12 || $count == 15 || $count == 18 || $count == 21 || $count == 24)
		&& !grep { /[^a-z]/ } @words;
	return 0;
}

sub crypto_address_valid {
	my ($asset, $address) = @_;
	my $a = ref $asset eq 'HASH' ? $asset : &crypto_asset($asset);
	return 0 unless $a;
	my $s = defined $address ? $address : '';
	$s =~ s/\s+//g;
	return 0 unless length $s;
	my $net = lc($a->{'network'} || '');
	return $s =~ /^(bc1[02-9ac-hj-np-z]{11,71}|[13][1-9A-HJ-NP-Za-km-z]{25,34})$/ ? 1 : 0 if $a->{'code'} eq 'BTC';
	return $s =~ /^(ltc1[02-9ac-hj-np-z]{11,71}|[LM3][1-9A-HJ-NP-Za-km-z]{25,34})$/ ? 1 : 0 if $a->{'code'} eq 'LTC';
	return $s =~ /^[D9A][1-9A-HJ-NP-Za-km-z]{25,34}$/ ? 1 : 0 if $a->{'code'} eq 'DOGE';
	return $s =~ /^r[1-9A-HJ-NP-Za-km-z]{24,34}$/ ? 1 : 0 if $a->{'code'} eq 'XRP';
	return $s =~ /^(addr1[0-9a-z]{20,100}|Ae[0-9A-Za-z]{50,60}|DdzFF[0-9A-Za-z]{50,100})$/ ? 1 : 0 if $a->{'code'} eq 'ADA';
	return $s =~ /^1[1-9A-HJ-NP-Za-km-z]{45,47}$/ ? 1 : 0 if $a->{'code'} eq 'DOT';
	return $s =~ /^(bitcoincash:)?[qp][0-9a-z]{41}$/ ? 1 : 0 if $a->{'code'} eq 'BCH';
	return $s =~ /^G[A-Z2-7]{55}$/ ? 1 : 0 if $a->{'code'} eq 'XLM';
	return $s =~ /^cosmos1[0-9a-z]{38,60}$/ ? 1 : 0 if $a->{'code'} eq 'ATOM';
	return $s =~ /^(EQ|UQ|kQ|0Q)[A-Za-z0-9_-]{46,48}$/ ? 1 : 0 if $a->{'code'} eq 'TON';
	return $s =~ /^T[1-9A-HJ-NP-Za-km-z]{33}$/ ? 1 : 0 if $net eq 'tron';
	return $s =~ /^0x[0-9a-fA-F]{40}$/ ? 1 : 0 if $net eq 'ethereum' || $net eq 'bnb';
	return $s =~ /^([XPC][A-Za-z0-9-]{10,120}|0x[0-9a-fA-F]{40})$/ ? 1 : 0 if $net eq 'avalanche';
	return $s =~ /^[1-9A-HJ-NP-Za-km-z]{32,44}$/ ? 1 : 0 if $net eq 'solana';
	return $s =~ /^[A-Za-z0-9]{20,100}$/ ? 1 : 0;
}

# A private extended key or a WIF is a spending key, never a watch-only one.
sub crypto_xpub_is_private {
	my ($text) = @_;
	return 0 unless defined $text && length $text;
	my $s = $text;
	$s =~ s/^\s+|\s+$//g;
	return 1 if $s =~ /^(?:[xyztuv]prv)/i;
	return 1 if $s =~ /^[5KLc9][1-9A-HJ-NP-Za-km-z]{50,51}$/;
	return 0;
}

sub crypto_big_mod {
	my ($v) = @_;
	$v->bmod($crypto_secp256k1_p);
	$v->badd($crypto_secp256k1_p) if $v->is_neg;
	return $v;
}

sub crypto_secp256k1_add {
	my ($x1, $y1, $x2, $y2) = @_;
	return undef unless defined $x1 && defined $x2 && defined $y1 && defined $y2;
	my ($num, $den);
	if ($x1->bcmp($x2) == 0) {
		return undef if $y1->bcmp($y2) != 0 || $y1->is_zero;
		$num = &crypto_big_mod($x1->copy->bmul($x1)->bmul(3));
		$den = &crypto_big_mod($y1->copy->bmul(2));
	}
	else {
		$num = &crypto_big_mod($y2->copy->bsub($y1));
		$den = &crypto_big_mod($x2->copy->bsub($x1));
	}
	my $inv = eval { $den->copy->bmodinv($crypto_secp256k1_p) };
	return undef unless $inv;
	my $lambda = &crypto_big_mod($num->copy->bmul($inv));
	my $x3 = &crypto_big_mod($lambda->copy->bmul($lambda)->bsub($x1)->bsub($x2));
	my $y3 = &crypto_big_mod($lambda->copy->bmul(&crypto_big_mod($x1->copy->bsub($x3)))->bsub($y1));
	return ($x3, $y3);
}

sub crypto_secp256k1_pub_parse {
	my ($bytes) = @_;
	return undef unless defined $bytes && length($bytes) == 33
		&& (substr($bytes, 0, 1) eq "\x02" || substr($bytes, 0, 1) eq "\x03");
	my $pk = eval { Crypt::PK::ECC->new };
	return undef unless $pk;
	my $ok = eval { $pk->import_key_raw($bytes, 'secp256k1'); 1 };
	return undef unless $ok;
	my $u = eval { $pk->export_key_raw('public') };
	return undef unless defined $u && length($u) == 65 && substr($u, 0, 1) eq "\x04";
	return ( Math::BigInt->from_bytes(substr($u, 1, 32)), Math::BigInt->from_bytes(substr($u, 33, 32)) );
}

# IL*G. The scalar is imported as a secp256k1 private key and its public point
# exported, so the curve work stays in CryptX.
sub crypto_secp256k1_mul_g {
	my ($raw) = @_;
	return undef unless defined $raw && length($raw) == 32;
	my $pk = eval { Crypt::PK::ECC->new };
	return undef unless $pk;
	my $ok = eval { $pk->import_key_raw($raw, 'secp256k1'); 1 };
	return undef unless $ok;
	my $u = eval { $pk->export_key_raw('public') };
	return undef unless defined $u && length($u) == 65 && substr($u, 0, 1) eq "\x04";
	return ( Math::BigInt->from_bytes(substr($u, 1, 32)), Math::BigInt->from_bytes(substr($u, 33, 32)) );
}

sub crypto_secp256k1_compress {
	my ($x, $y) = @_;
	return undef unless $x && $y;
	my $hex = $x->as_hex;
	$hex =~ s/^0x//;
	$hex = ('0' x 64) . $hex;
	$hex = substr($hex, -64);
	return ($y->is_odd ? "\x03" : "\x02") . pack('H*', $hex);
}

sub crypto_base58_encode {
	my ($bytes) = @_;
	return '' unless defined $bytes && length $bytes;
	my $n = Math::BigInt->from_bytes($bytes);
	my $base = Math::BigInt->new(58);
	my $out = '';
	while (!$n->is_zero) {
		my $r = $n->copy->bmod($base)->numify;
		$out = substr($crypto_base58_alphabet, $r, 1) . $out;
		$n->bdiv($base);
	}
	my $zeros = ($bytes =~ /^(\x00*)/) ? length($1) : 0;
	return ('1' x $zeros) . $out;
}

sub crypto_base58_decode {
	my ($s) = @_;
	return undef unless defined $s && length $s;
	my $n = Math::BigInt->new(0);
	foreach my $c ( split //, $s ) {
		return undef unless exists $crypto_base58_index{$c};
		$n->bmul(58)->badd($crypto_base58_index{$c});
	}
	my $bytes = $n->is_zero ? '' : $n->to_bytes;
	my $zeros = ($s =~ /^(1*)/) ? length($1) : 0;
	return ("\x00" x $zeros) . $bytes;
}

sub crypto_base58check_encode {
	my ($payload) = @_;
	return undef unless defined $payload;
	return &crypto_base58_encode($payload . substr(Digest::SHA::sha256(Digest::SHA::sha256($payload)), 0, 4));
}

sub crypto_base58check_decode {
	my ($s) = @_;
	my $raw = &crypto_base58_decode($s);
	return undef unless defined $raw && length($raw) >= 4;
	my $payload = substr($raw, 0, -4);
	my $check = substr($raw, -4);
	return undef unless $check eq substr(Digest::SHA::sha256(Digest::SHA::sha256($payload)), 0, 4);
	return $payload;
}

sub crypto_hash160 {
	my ($bytes) = @_;
	return undef unless defined $bytes;
	my $ok = eval { require Crypt::Digest::RIPEMD160; 1 };
	return undef unless $ok;
	return Crypt::Digest::RIPEMD160::ripemd160(Digest::SHA::sha256($bytes));
}

sub crypto_bech32_polymod {
	my (@v) = @_;
	my @gen = (0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3);
	my $chk = 1;
	foreach my $v (@v) {
		my $top = $chk >> 25;
		$chk = (($chk & 0x1ffffff) << 5) ^ $v;
		for my $i (0 .. 4) {
			$chk ^= $gen[$i] if (($top >> $i) & 1);
		}
	}
	return $chk;
}

sub crypto_bech32_hrp_expand {
	my ($hrp) = @_;
	return ( (map { ord($_) >> 5 } split //, $hrp), 0, (map { ord($_) & 31 } split //, $hrp) );
}

sub crypto_bech32_convert_bits {
	my ($data, $from, $to, $pad) = @_;
	my ($acc, $bits, @out) = (0, 0);
	foreach my $b ( unpack('C*', $data) ) {
		$acc = (($acc << $from) | $b) & ((1 << ($from + $bits)) - 1);
		$bits += $from;
		while ($bits >= $to) {
			$bits -= $to;
			push @out, (($acc >> $bits) & ((1 << $to) - 1));
		}
	}
	push @out, (($acc << ($to - $bits)) & ((1 << $to) - 1)) if $pad && $bits > 0;
	return @out;
}

sub crypto_segwit_encode {
	my ($hrp, $version, $program) = @_;
	return undef unless defined $hrp && defined $program && length($program);
	my @data = ( $version, &crypto_bech32_convert_bits($program, 8, 5, 1) );
	my $const = $version == 0 ? 1 : 0x2bc830a3;
	my $polymod = &crypto_bech32_polymod(&crypto_bech32_hrp_expand($hrp), @data, (0) x 6) ^ $const;
	my @check = map { ($polymod >> (5 * (5 - $_))) & 31 } (0 .. 5);
	return $hrp . '1' . join('', map { substr($crypto_bech32_charset, $_, 1) } (@data, @check));
}

1;
