#!/usr/bin/perl




# Music is compiled into package Manager (this file has no package line), so it
# used to re-run the Lite import in Manager's namespace: that made a second app
# and re-pointed Manager::app/get/new at it. There is one app now (JawnOS, reached
# as Manager::app), so Music registers its routes on it explicitly.
use Mojo::Base -strict;
use feature 'signatures';
use Mojolicious::Static;
use Mojo::Log;
use Mojo::File;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::URL;
use Encode qw(encode decode);
use List::Util qw(shuffle);
use Data::Dumper;
use Data::UUID;
use Mojo::Util qw/term_escape html_unescape url_unescape url_escape/;
use File::Find;
use File::Slurp;
use Fcntl qw(F_SETPIPE_SZ);
Manager::app->plugin('RenderFile');
use LWP::UserAgent;
use Mojolicious::Sessions;
use URI::Encode qw(uri_encode uri_decode);
use MIME::Base64;
use strict;
use warnings;
no warnings 'uninitialized';
my $com = 'echo $HOME';
my $cwd = `$com`;
chomp $cwd;

require "./perl/subroutines.pl";
our $music_device = &subs::device_setter();
my $config_file = read_file('./config.json');
our $music_config = decode_json $config_file;
my $environment = $music_config->{'environment'};
my @folders = @{$music_config->{'folders'}};
our $logfile = &subs::home($music_config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
my (@results);
our $music_files = [];
our $music_thumb_files = [];
our $music_permissive = 0;

# The playable and cover extensions the walk looks for. The old wanted() tested
# them with /mp3$|m4a$|.../i - a ten-way case-insensitive suffix match run on
# every entry of every folder, and the one part of the walk that cost real time
# (about 0.15s of a 0.2s walk over a large library). A look-up of the final three
# or four lowercased characters answers the same question in constant time. The
# extensionless tail is still allowed ("WAV" ends in wav), exactly as before.
my %playable_suffix = map { $_ => 1 } qw/mp3 m4a wav flac mp4 mkv mov webm weba wmv/;
my %cover_suffix = map { $_ => 1 } qw/jpg png/;

sub playable_name($name) {
	my $tail = lc substr($name, -4);
	return 1 if $playable_suffix{$tail};
	return 1 if $playable_suffix{substr($tail, -3)};
	return 0;
}

sub playable_enc_name($name) {
	return 0 unless lc(substr($name, -4)) eq '.enc';
	return playable_name(substr($name, 0, -4));
}

# An album's own visibility decides whether its tracks need the padlock. The
# album is the folder above the file, the same part the walk names as `app`.
# The shared rule is read fresh: a cached answer would keep a track visible after
# a lockdown began or a place changed.
sub music_app_name($name) {
	my @part = split '/', $name;
	return '' unless scalar @part >= 2;
	my $app = &subs::unformat_name($part[-2]);
	return (defined $app && length $app) ? $app : '';
}

sub music_app_private($name) {
	my $app = &music_app_name($name);
	return 0 unless length $app;
	return &subs::app_private_now($app) ? 1 : 0;
}

sub music_app_visible($name) {
	my $app = &music_app_name($name);
	return 1 unless length $app;
	return &Manager::help_app_hidden($app) ? 0 : 1;
}

sub process_file($name) {
	# A private album is a lock, not a place level. Outside a private place its
	# tracks are not listed at all; inside one they still need a fingerprint (its
	# own Music padlock or the Security private grant).
	if (&music_app_private($name)) {
		return unless &subs::private_reachable_now();
		return unless $music_permissive == 1 || &subs::private_revealed();
	}
	return unless playable_name($name)
		|| (($music_permissive == 1 || music_app_visible($name)) && playable_enc_name($name));
	# A directory walk hands names back as UTF-8 bytes, but the music window is a
	# character string: an undecoded name gets upgraded as Latin-1 and served
	# double-encoded (Æ -> Ã), so the player then cannot open it. Decode only the
	# names that are kept, so the rest of the app sees them as the browser does.
	# Invalid UTF-8 is left as bytes, which is what it was before.
	utf8::decode($name) unless utf8::is_utf8($name);
	$name =~ s/^\.\///g;
	push @{$music_files}, $name;
}

sub process_thumbfile() {
	my $name = $File::Find::name;
	if ($cover_suffix{lc substr($name, -3)}) {
		$name =~ s/^\.\///g;
		push @{$music_thumb_files}, $name;
	}
}

Manager::app->routes->get('/manager/music' => sub ($c) {
	my $search = $c->param('search') || &subs::setting_grabber({ app => 'music', 'setting' => 'search' });
	my $window_maker = $c->param('window_maker');
	# an app opens locked: only the token this window holds, minted by the
	# phone's unlock, may list a sealed track. A refresh after that unlock
	# carries the token and stays open.
	my $unlocked = &Manager::media_unlock_open($c, 'music') ? 1 : 0;
	my $unlock = $unlocked ? $c->param('unlock') : '';
	my $content_cache = &subs::jawn_version() . ($unlocked ? '-unlocked' : '-locked');
	my $port = $c->req->url->base->port;
	my $misses = eval { return decode_json $c->param('misses') } || {};
	if (!$misses->{'video'}) {
		$misses->{'video'} = &subs::random_string_creator(25,"Aa");
	}
	$music_files = eval { return decode_json $c->param('files') } || undef;
	my $same_order = $c->param('same_order');
	my $settings = &subs::settings_grabber({ app => 'music' });
	$settings->{'artist'} = eval { return decode_json $settings->{'artist'} } || [];
	$settings->{'album'} = eval { return decode_json $settings->{'album'} } || [];
	if (($settings->{'library'} || '') ne 'local' && ($c->param('remoted') || '') ne 'yes') {
		my $rm = &subs::db_query('select * from remote_machines where uuid=? and connection=?', $settings->{'library'}, 'active')->hashes->[0];
		if ($rm->{'uuid'}) {
			$c->param('remote_uuid' => $rm->{'uuid'});
			$c->param('library_name' => &music_remote_label($rm));
			$c->param('subprocess' => 'yes');
			my $result = &Manager::remote_relay_request($c);
			if ($result =~ /music/gi) {
				$c->render(text => $result);
				return;
			}
		}
		else { &subs::setting_setter({ app => 'music', setting => 'library', value => 'local' }); $settings->{'library'} = 'local'; }
	}
	my $misc_settings = &Manager::misc_setting_list();
	# A relayed page carries the host it came from; do not answer it from the
	# cached shell, which was built for whichever library last filled it.
	# The window's shell is kept per code revision and per lock state, so the same
	# two windows can hold shells built from different lists - and a shell is
	# replayed wholesale. Keying it to the queue it was built for means a stale
	# one can never win: a shell is only served when it describes this exact list.
	my $shell_key = $content_cache;
	my $remembered;
	unless ($music_files || $c->param('library_name')) {
		$remembered = &music_queue_recall($settings, $unlocked);
		if ($remembered) { $shell_key .= '-q' . $remembered->{'key'}; }
		if (my $cache = &subs::cache_get({ app => 'music', context => 'content', subcontext => $shell_key })) {
			if ($cache->{'contents'}) {
				# one line per app open: the three ways a window can come back are
				# worth telling apart when someone reports the wrong list
				$log->info('music queue: window served from the cached shell');
				if ($c->param('window_maker')) {
					my $website = &Manager::window_maker({ app => 'music', title => 'music', contents => $cache->{'contents'} }, &subs::rightNow());
					$c->render(text => $website);
				}
				else {
					$c->render(text => $cache->{'contents'});
				}
				return;
			}
		}
		# The shell is only kept for the running code revision, so a deploy (and
		# every push bumps one) misses it. The queue itself is data, not markup:
		# replay the files the window was last showing, in the order it showed
		# them, rather than re-searching. That is what brings back a list the
		# guide, the folders app or an artist pick put together - the saved
		# search cannot reproduce any of those.
		if ($remembered) {
			$music_files = $remembered->{'files'};
			$same_order = 1;
			$log->info('music queue: replayed ' . scalar @{$remembered->{'files'}} . ' file(s)');
		}
		else {
			$log->info('music queue: no replayable queue, searching');
		}
	}
	my $crate = &music_search({ settings => $settings, c => $c, search => $search, now_playing => {}, port => $port, misc_settings => $misc_settings, files => $music_files, same_order => $same_order, permissive => $unlocked });
	$crate->{'unlock'} = $unlock;
	$crate->{'unlocked'} = $unlocked;
	# whatever this render put on screen is the queue a reopen should replay, and
	# the shell below is stored under its stamp so it can only be replayed for it
	my $queue_key = &music_queue_remember($crate, $settings, $unlocked);
	my $timestamp = &subs::rightNow();
	my $jmao = &subs::setting_grabber({ app => 'music', setting => 'mao' });
	my $player = &subs::cache_get({ app => 'music', context => 'player' });
	my $resizes = eval { return decode_json $settings->{'resizes'} } || {};
	my $contents;
	if ($c->param('window_maker')) {
		$contents = $c->render_to_string(
			crate => $crate,
			interface_colour => &subs::random_colour_grabber(),
			template => 'apps/music/music',
			window_maker => 'yes',
			folders => $misc_settings,
			device => &subs::device_setter(),
			mao => eval { return decode_json $jmao } || {},
			jmao => $jmao,
			search => $search,
			resizes => $resizes,
			misses => $misses,
		);
		my $website = &Manager::window_maker({ app => 'music', title => 'music', contents => $contents }, $timestamp);
		$c->render(text => $website);
	}
	else {
		$contents = $c->render_to_string(
			crate => $crate,
			interface_colour => &subs::random_colour_grabber(),
			template => 'apps/music/music',
			layout => 'music',
			window_maker => 'no',
			string => &subs::jawn_version(),
			folders => $misc_settings,
			device => &subs::device_setter(),
			mao => eval { return decode_json $jmao } || {},
			jmao => $jmao,
			search => $search,
			resizes => $resizes,
			misses => $misses
		);
		$c->render(text => $contents);
	}
	&subs::cache_set({ app => 'music', context => 'content', subcontext => ($content_cache . ($queue_key ? '-q' . $queue_key : '')) }, { contents => $contents });
	# The shell just written is the only one a read can reach: it is keyed by
	# this code revision and this queue. The shells left by an earlier version
	# or an earlier queue are dead the moment this one lands, and they used to
	# stay behind one per push; drop them so the music cache does not grow forever.
	&subs::db_query("delete from cache where app = 'music' and context = 'content' and subcontext is not ?", $content_cache . ($queue_key ? '-q' . $queue_key : ''));
});


Manager::app->routes->get('/play' => sub($c) {
	my $mao = eval { return decode_json &subs::setting_grabber({ app => 'music', setting => 'mao' }) } || {};
	# the query is already decoded by Mojo; decoding again would corrupt a name
	# with a literal %xx in it (see Manager::rock_and_roll)
	my $track_name = $c->param('track') // '';
	my $data;

	# The ahead tap is an <audio> element reading the same file. Without a Range
	# the file is answered as a live stream with no known length: its seekable
	# window moves and its clock wanders, so a seek lands somewhere else. A
	# whole-file range gives it the same fixed, seekable response a <video>
	# element asks for by itself.
	if ((($c->param('ahead') // $c->param('clone') // '') eq '1') && !$c->req->headers->header('Range')) {
		$c->req->headers->header('Range' => 'bytes=0-');
	}

	&Manager::rock_and_roll($c);

	# the ahead tap re-requests /play for the same file; it must not start the
	# server-side player a second time
	if ($mao->{'srv'} eq 'on' && $c->param('ahead') ne '1' && $c->param('clone') ne '1') {
		&subs::subprocessor(sub {

			# List form: the track name is request data, and terminal_name
			# escapes for a terminal, not for a shell (no ; | $ ` or newline).
			if ($music_device eq 'computer') {
				system('vlc', $track_name);
			}
			elsif ($music_device eq 'mobile') {
				system('play', $track_name);
			}
		}, { name => 'music play' });
		$c->render(text => 'play');
	}

});

require "./perl/Music/01_remote_audio_receiver.pl";
require "./perl/Music/02_remote_audio_stream.pl";
require "./perl/Music/03_remote_video.pl";
require "./perl/Music/04_music_websockets.pl";
require "./perl/Music/05_library_and_queue.pl";
require "./perl/Music/06_track_naming.pl";
require "./perl/Music/07_song_maker.pl";
require "./perl/Music/08_music_routes.pl";
1;
