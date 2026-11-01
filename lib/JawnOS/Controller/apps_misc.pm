package Manager;

# apps_misc: route actions moved out of Manager.pl, one sub per route so a
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

# A PNG for the native home's row and clothesline. main_icon_source answers
# with the same picture main_icon_maker puts in the start menu and taskbar, so
# the launcher, the menu and the taskbar wear one icon. A set glyph is
# rasterised once per file change into database/.icons.
# GET /apps/icon
sub action_27002 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app') // '');
	my $missing = sub {
		$c->res->code(404);
		$c->render(text => 'none');
	};
	return $missing->() unless length $app;
	my $src = &subs::main_icon_source({ app => $app });
	return $missing->() unless length $src;
	# a person's own icon is sealed in the vault, and /file_open keeps the gate
	return $c->redirect_to($src) if $src =~ m{\A/file_open};
	# the hand-drawn set (and any set without a glyph) is already a PNG
	return $c->redirect_to($src) unless $src =~ /\.svgz?\z/i;
	my $file = 'public' . $src;
	return $missing->() unless -e $file;
	my @stat = stat($file);
	my $dir = &subs::database_dir() . '/.icons';
	mkdir $dir unless -d $dir;
	require Digest::MD5;
	my $cache = $dir . '/' . Digest::MD5::md5_hex($src . ':' . ($stat[7] // 0) . ':' . ($stat[9] // 0) . ':128') . '.png';
	my $png = -e $cache ? eval { read_file($cache) } : undef;
	unless (defined $png && length $png) {
		my $quoted = quote($file);
		$png = `rsvg-convert -w 128 -h 128 -o - $quoted 2>/dev/null`;
		$png = `magick -background none $quoted -resize 128x128 png:- 2>/dev/null` unless defined $png && length $png;
		return $missing->() unless defined $png && length $png;
		write_file($cache, $png);
	}
	$c->res->headers->cache_control('private, max-age=60');
	$c->render_file(data => $png, content_type => 'image/png');
}

# One JSON catalog for the launcher (public: app names and icons, no house
# data). The search index is richer but gated, and the launcher has to draw its
# JawnOS row before a session exists.
# GET /apps/list
sub action_27037 {
	my $c = shift;
	my $apps = &internet_app_catalog({ visible_only => 1 });
	foreach my $entry ( @{$apps} ) {
		$entry->{'icon'} = &app_icon_url($entry->{'app'});
	}
	$c->render(json => { apps => $apps });
}

# The start-menu app list, for the native home's JawnOS row (public: app
# names, titles and icon paths only). The list is the start menu's own markup,
# extracted here so the launcher shows exactly what the start menu offers and
# a new icon appears in both places from one edit.
# GET /apps/start
sub action_27049 {
	my $c = shift;
	$c->param('menu' => 'app');
	# The start menu template reads the device from the stash (the manager
	# layout normally sets it); this route is public, so set it here too.
	$c->stash(device => &subs::device_setter());
	my $menu = &start_menu_maker($c);
	my $html = $menu->{'html'} || '';
	# The handful of icons whose id is not <app>_toggle: the ticket maker is
	# Box Office, budget has a bare id, the gallery wears image_toggle, the
	# gear is Configure, and the Search app's icon carries search_app_toggle.
	my %special = ( ticketmaker => 'box_office', budget => 'budget', image_toggle => 'gallery', main_logo => 'configure', search_app_toggle => 'search' );
	# Things that are actions or tools, not apps the launcher opens.
	my %skip = map { $_ => 1 } qw( home_toggle torch_toggle sms_list_check web_toggle
		now_toggle site_type_toggle admin_console_toggle browser_toggle );
	my (@apps, %seen);
	while ($html =~ /<img\b([^>]*)>/g) {
		my $attr = $1;
		my ($id) = $attr =~ /\bid="([^"]*)"/;
		next unless defined $id && length $id;
		next if $skip{$id};
		my $app = $special{$id} || ($id =~ /^(.*)_toggle\z/ ? $1 : '');
		next unless length $app;
		next if &help_app_hidden($app);
		next if $seen{$app}++;
		my ($hint) = $attr =~ /\bhint="([^"]*)"/;
		# The start menu's src is the icon set's SVG, which Android cannot
		# decode; the route answers a PNG of the same picture.
		push @apps, {
			app   => $app,
			title => ($hint || &subs::format_name($app)),
			icon  => &app_icon_url($app),
		};
	}
	$c->render(json => { apps => \@apps });
}

1;
