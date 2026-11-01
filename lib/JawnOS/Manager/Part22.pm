package Manager;

# Manager helpers, part 22 of 37. Moved out of Manager.pl so a
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

sub search_engine_add_custom($name, $url) {
	my $state = &search_engine_state();
	$name =~ s/^\s+|\s+$//g;
	$url =~ s/^\s+|\s+$//g;
	$name = length($name) ? substr($name, 0, 80) : 'Search';
	$url =~ s/\{searchTerms\}/\{q\}/g;
	$url .= '{q}' unless $url =~ /\{q\}/;
	my ($all) = &search_engine_all();
	my ($existing) = grep { ($_->{'url'} // '') eq $url } @{$all};
	if ($existing) {
		my %enabled = map { $_ => 1 } @{ $state->{'enabled'} };
		$enabled{$existing->{'id'}} = 1;
		$state->{'enabled'} = [ sort keys %enabled ];
		&search_engine_save($state);
		return $existing;
	}
	my $id = 'custom_' . lc(&subs::random_string_creator(8));
	my $entry = { id => $id, name => $name, url => $url, kind => 'html', group => 'custom' };
	push @{ $state->{'custom'} }, $entry;
	push @{ $state->{'enabled'} }, $id unless grep { $_ eq $id } @{ $state->{'enabled'} };
	&search_engine_save($state);
	return $entry;
}

sub search_web_matches($q) {
	my @engines;
	my $ua = Mojo::UserAgent->new(
		connect_timeout => 4,
		inactivity_timeout => 6,
		request_timeout => 9,
		max_redirects => 5
	);
	$ua->transactor->name($user_agent);
	# Navigation, consent and footer links are not results. A search page's
	# real rows are thousands of characters of news; these words are the chrome
	# every engine puts around them.
	my %deny = map { $_ => 1 } (
		'here', 'feedback', 'sign in', 'log in', 'settings', 'privacy', 'terms',
		'about', 'help', 'images', 'videos', 'news', 'maps', 'shopping', 'more',
		'next', 'previous', 'advertise', 'business', 'how search works'
	);
	my $wanted = &search_enabled_engines();
	splice @{$wanted}, 8 if scalar @{$wanted} > 8;
	foreach my $engine ( @{$wanted} ) {
		my $name = $engine->{'name'} || 'Web';
		my $kind = $engine->{'kind'} || 'html';
		my $url = &search_engine_url($engine, $q);
		my (@results, $error);
		my $host = '';
		eval { $host = Mojo::URL->new($engine->{'url'} || '')->host || '' };

		if ($kind eq 'rss') {
			my $feed = ($engine->{'rss'} // '') ne '' ? &search_engine_url({ url => $engine->{'rss'} }, $q) : $url;
			my $res = eval { $ua->get($feed)->result };
			if (!$res || !$res->is_success) {
				$error = 'could not reach ' . ($res ? $res->code : 'the site');
			}
			else {
				my $dom = eval { Mojo::DOM->new($res->text || '') } || Mojo::DOM->new('');
				foreach my $item ( $dom->find('item')->each ) {
					my $title = eval { $item->at('title')->text } || '';
					my $link = eval { $item->at('link')->text } || '';
					my $desc = eval { $item->at('description')->text } || '';
					$desc =~ s/<[^>]+>//g;
					$title =~ s/\s+/ /g; $title =~ s/^\s+|\s+$//g;
					$desc =~ s/\s+/ /g; $desc =~ s/^\s+|\s+$//g;
					next unless length($title) && $link =~ m{^https?://}i;
					push @results, { title => $title, url => $link, snippet => $desc };
					last if scalar @results >= 8;
				}
			}
		}
		elsif ($kind eq 'ddg') {
			my $api = 'https://api.duckduckgo.com/?q=' . url_escape($q)
				. '&format=json&no_html=1&skip_disambig=1';
			my $res = eval { $ua->get($api)->result };
			if ($res && $res->is_success) {
				my $j = eval { $res->json } || {};
				push @results, { title => ($j->{'Heading'} || $q), url => $j->{'AbstractURL'} }
					if ($j->{'AbstractURL'} // '') ne '';
				my @topics = @{ $j->{'RelatedTopics'} || [] };
				while (scalar @topics && scalar @results < 8) {
					my $t = shift @topics;
					next unless ref $t eq 'HASH';
					if (ref $t->{'Topics'} eq 'ARRAY') { unshift @topics, @{$t->{'Topics'}}; next; }
					next unless ($t->{'FirstURL'} // '') ne '';
					my $text = $t->{'Text'} || $t->{'FirstURL'};
					$text =~ s/<[^>]+>//g;
					push @results, { title => $text, url => $t->{'FirstURL'} };
				}
			}
			else {
				$error = 'could not reach ' . ($res ? $res->code : 'the site');
			}
		}
		elsif ($kind eq 'mediawiki') {
			my $h = $host || 'en.wikipedia.org';
			my $api = 'https://' . $h . '/w/api.php?action=query&list=search&format=json&srlimit=8&srsearch=' . url_escape($q);
			my $res = eval { $ua->get($api)->result };
			if ($res && $res->is_success) {
				my $j = eval { $res->json } || {};
				foreach my $hit ( @{ $j->{'query'}->{'search'} || [] } ) {
					my $title = $hit->{'title'} || '';
					next unless length $title;
					(my $path = $title) =~ s/ /_/g;
					my $snippet = $hit->{'snippet'} || '';
					$snippet =~ s/<[^>]+>//g;
					push @results, { title => $title, url => 'https://' . $h . '/wiki/' . url_escape($path), snippet => $snippet };
					last if scalar @results >= 8;
				}
			}
			else {
				$error = 'could not reach ' . ($res ? $res->code : 'the site');
			}
		}
		else {
			my $res = eval { $ua->get($url)->result };
			if (!$res || !$res->is_success) {
				$error = 'could not reach ' . ($res ? $res->code : 'the site');
			}
			else {
				my $dom = eval { Mojo::DOM->new($res->text || '') } || Mojo::DOM->new('');
				my $base = Mojo::URL->new($url);
				my %seen;
				foreach my $a ( $dom->find('a[href]')->each ) {
					my $href = $a->attr('href') // '';
					my $text = $a->text // '';
					$text =~ s/\s+/ /g;
					$text =~ s/^\s+|\s+$//g;
					next if length($text) < 3;
					next if $deny{lc $text};
					next if $href =~ /^(?:javascript:|mailto:|tel:|#)/i;
					my $abs = eval { Mojo::URL->new($href)->to_abs($base)->to_string };
					next unless defined $abs && $abs =~ m{^https?://}i;
					# Google and DuckDuckGo wrap the real address in their own link
					if ($abs =~ m{^https?://(?:www\.)?google\.[^/]+/url\?(?:[^#]*&)?q=([^&]+)}i) {
						$abs = url_unescape($1);
						$abs =~ s/\+/ /g;
					}
					elsif ($abs =~ m{^https?://(?:[a-z0-9.-]*\.)?duckduckgo\.com/l/\?(?:[^#]*&)?uddg=([^&]+)}i) {
						$abs = url_unescape($1);
					}
					next unless $abs =~ m{^https?://}i;
					next if $abs =~ m{^https?://(?:www\.)?(?:google|duckduckgo|bing|wikipedia)\.[^/]+/(?:search|images|videos|news|maps|preferences|settings|account|html)\b}i;
					next if $seen{$abs}++;
					push @results, { title => $text, url => $abs };
					last if scalar @results >= 8;
				}
			}
		}

		# An engine that hands back only a JavaScript shell still belongs in the
		# list: one row for the words, which opens that engine in the browser.
		push @results, { title => $q, url => $url } unless scalar @results;
		push @engines, { id => $engine->{'id'}, name => $name, url => $url, results => \@results, error => $error };
	}
	return \@engines;
}

sub search_engine_grabber($c) {

	my $search_engines;
	my $timestamp = (&subs::rightNow());
	my $search = $c->param('search');
	my $website = $c->param('website');
	my $contents = &website_grabber({
		app => $c->param('app'),
		search => $search,
		website => $website,
		timestamp => $timestamp
	});
	my $window_data = { app=> $c->param('app'), contents => &website_grabber($c) };
	if ($c->param('view') eq 'iframe') {
		$window_data->{'iframe'} = $website;
	}
	my ($window,$internal_url) = &window_maker($window_data, $timestamp);

	return $window;
}

sub usage_ms {
	my $value = shift;
	return 0 unless defined $value && $value =~ /^\d+$/;
	return int($value);
}

sub internet_app_catalog {
	my ($opts) = @_;
	my $visible_only = $opts && $opts->{'visible_only'};
	my $any_appt = $opts && $opts->{'any_appt'};
	my @apps;
	my %skip = map { $_ => 1 } qw(citizen resident guest blacklisted web);
	foreach my $app ( sort { lc($a) cmp lc($b) } keys %{$gb::known_appts} ) {
		next if $skip{$app};
		next if $visible_only && &subs::app_hidden_now($app);
		push @apps, { app => $app, title => &subs::format_name($app) };
	}
	unshift @apps, { app => 'internet', title => &subs::lang('internet') }
		unless $visible_only && &subs::app_hidden_now('internet');
	my %seen = map { $_->{'app'} => 1 } @apps;
	# The person's own apps: an app with a main_image is one the manager draws as an
	# app. The appointments table holds every record's app, and `pos` is shared by
	# products, files and tiles, so neither is the launcher's list.
	my $rows = eval { &subs::db_query("select distinct app from settings where app is not null and app != '' and setting = 'main_image'")->hashes } || [];
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'} || next;
		next if $app =~ /^__/ || $seen{$app}++;
		next if $visible_only && &subs::app_hidden_now($app);
		push @apps, { app => $app, title => &subs::format_name($app) };
	}
	# Every appointment is an app a site can belong to, not only the ones with a
	# launcher icon. Visibility is loaded in one pass because this is the whole
	# house's record list, not a handful of built-ins.
	if ($any_appt) {
		my $appt_rows = eval { &subs::db_query("select distinct app from appointments where app is not null and app != ''")->hashes } || [];
		my @names = sort grep { defined $_ && length $_ && $_ !~ /^__/ } map { $_->{'app'} } @{$appt_rows};
		&subs::app_visibility_preload(\@names) if $visible_only;
		foreach my $app ( @names ) {
			next if $seen{$app}++;
			next if $visible_only && &subs::app_hidden_now($app);
			push @apps, { app => $app, title => &subs::format_name($app) };
		}
	}
	return \@apps;
}

sub app_icon_url {
	my ($app) = @_;
	return '' unless defined $app && length $app;
	return '/apps/icon?app=' . &subs::path_name($app);
}

sub internet_domain_apps {
	return &subs::internet_domain_app_map();
}

sub website_grabber($data) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $app = &subs::unformat_name($data->{'app'});
	my $settings = &subs::settings_grabber({ app => $app });
	# The URL and format are app facts, so read them from any device's row (local
	# first). Otherwise a phone acting as the headless browser would see no web
	# settings at all and fetch nothing.
	my $format = &subs::setting_value_for($app, 'web_format') || $settings->{'web_format'} || 'html';
	my $website = $data->{'website'} || &subs::setting_value_for($app, 'web') || $settings->{'web'};
	my $server_time = &subs::rightNow();
	my $uuid = $data->{'uuid'};
	my $timestamp = $data->{'timestamp'};
	my $user_agent = $data->{'user_agent'} || $user_agent;
	my $signatorial = &subs::signatorial_designer();
	my $saved_website;
	my $internal_url = $website;
	my $window;
	if ($uuid) {
		$saved_website = &subs::db_select('websites', ['app','timestamp','internal_url','url','content'], { app => $app, url => $website, uuid => $uuid })->hash;
		$timestamp = $saved_website->{'timestamp'} || &subs::rightNow();
		$window = $saved_website->{'content'};
	}
	else {
		$uuid = &subs::random_string_creator(39);

		$saved_website = &subs::db_select('websites', ['app','timestamp','internal_url','url','content'], { timestamp => $timestamp, url => $website })->hash;
		$timestamp = $saved_website->{'timestamp'} || &subs::rightNow();
		my $raw_html = $saved_website->{'content'};

		my $ua = Mojo::UserAgent->new;
		my $res = eval { $ua->get($website => {user_agent => $user_agent})->result } ;
		$internal_url = $website || $saved_website->{'internal_url'} || "No Page";
		my ($raw_body, $json);

		if (eval { $res->is_success } ) {
			$raw_body = $res->body;
			if ($format eq 'json') { $json = eval { decode_json $raw_body }; }
			$raw_html = $raw_body;
			if ($json) {
				# Decode a second copy: the prettyfier mutates the data it is given
				# (arrays become 1arr, 2arr), and the measure extractor needs the
				# original shape for a path.
				my $pretty_json = eval { decode_json $raw_body };
				if ($pretty_json) {
					my $c = &subs::controller_builder();
					$raw_html = $c->render_to_string(
						template => 'web/json_prettyfy',
						jdata => $pretty_json
					);
				}
			}
			my $hs = HTML::Strip->new(
				striptags   => [ 'iframe','script' ],
				emit_spaces => 0
			);
			my $content = $hs->parse( $raw_html );



			$internal_url = $saved_website->{'internal_url'};
			if ($saved_website->{url}) {
				$uuid = $saved_website->{'uuid'};
				&subs::db_update('websites',
					{
						content => $raw_html,
						timestamp => $timestamp,
						url => $website,
						internal_url => $internal_url,
						server_time => $server_time
					},
					{
						url => $website,
						app => $app
					}
				);
			}
			else {
				$internal_url = &subs::random_string_creator();
				&subs::db_insert('websites', {
					content => $raw_html,
					timestamp => $timestamp,
					url => $website,
					internal_url => $internal_url,
					app => $app,
					server_time => $server_time,
					uuid => $uuid
				});
			}
			&web_history_deleter($app);
			my $wmd = &subs::setting_rows_for($app, 'web_measure_data', 'subsetting');
			if (scalar @{$wmd}) {
				my $uuid;
				my $c = &subs::controller_builder();
				my $am = eval { decode_json &subs::setting_value_for($app, 'app_measures') } || {};
				my $ctx = {
					format => $format,
					json => $json,
					dom => Mojo::DOM->new($format eq 'json' ? $raw_html : $raw_body),
					raw => $raw_body,
				};
				foreach my $wm ( @{$wmd} ) {
					my $spec = eval { decode_json $wm->{'value'} } || {};
					$spec->{'measure'} ||= $wm->{'subsetting'};
					my $type = $am->{$wm->{'subsetting'}}->{'type'} || '';
					$spec->{'number'} = 1 if !exists $spec->{'number'} && ($type eq 'number' || $type eq 'range');
					$spec->{'unit'} ||= $am->{$wm->{'subsetting'}}->{'unit'};
					my $extracted = &subs::web_measure_extract($spec, $ctx);
					unless ($extracted->{'ok'}) {
						$log->info('web measure ' . $app . '/' . $wm->{'subsetting'} . ': ' . $extracted->{'error'});
						next;
					}
					my $measure = $extracted->{'value'};
					$uuid = &appt_measure_writer($c,{ app => $app, measure => $wm->{'subsetting'}, value => $measure, timestamp => &subs::rightNow(), uuid => $uuid });
					my $esc = defined $measure ? $measure : '';
					$esc =~ s/\\/\\\\/g;
					$esc =~ s/'/\\'/g;
					&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.app_measure[measure="' . $wm->{'subsetting'} . '"]\').val(\'' . $esc . '\');' });
					&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.app_measure_display[measure="' . $wm->{'subsetting'} . '"]\').text(\'' . $esc . '\');' });
				}
			}
		}
		elsif (eval {$saved_website->{'internal_url'}}) {
			$internal_url = $saved_website->{'internal_url'};
		}
		else {
			$internal_url = "No Page";
		}

		$saved_website->{'title'} = "web";
		my $c = &subs::controller_builder();
		my $web_toolbar = $c->render_to_string(
			template => 'web/web',
			app => $app
		);
		$window = &window_maker({ user_agent => $data->{'user_agent'}, app => 'web', contents => $web_toolbar . $saved_website->{'content'} }, $timestamp);
	}

	return ($window,$internal_url,$uuid,$timestamp);
}

sub web_history_deleter($app) {
	# The archive count is an app fact shared by every machine, like the URL and
	# the selectors. Read the workspace's value rather than only this device's
	# row: a machine that never saved its own (the server, once it became the
	# headless browser) used to fall back to one row, erasing the other URL's
	# last-run marker so the scheduler refetched it on the next tick.
	my $web_archives = &subs::setting_value_for($app, 'web_archives');
	$web_archives = 1 unless defined $web_archives && $web_archives =~ /^\d+$/ && $web_archives > 0;
	# Never keep fewer rows than the app has distinct configured URLs: each URL
	# needs its own last-run marker or it looks never fetched.
	my %url;
	foreach my $w ( @{ &subs::setting_rows_for($app, 'web') } ) {
		my $u = $w->{'value'};
		$url{$u} = 1 if defined $u && length $u;
	}
	my $keep = scalar keys %url;
	$keep = $web_archives if $web_archives > $keep;
	$keep = 1 if $keep < 1;
	my $history = &subs::db_query('select * from websites where app=? order by timestamp desc', $app)->hashes;
	if (scalar @{$history} > 1) {
		for (my $n = scalar @{$history}; $n >= $keep; $n--) {
			if ($history->[$n]){
				&deletion_registration({ table => 'websites', uuid => $history->[$n]->{'uuid'}, scope => 'single', server_time => $history->[$n]->{'server_time'} });
				&subs::db_delete('websites', { uuid => $history->[$n]->{'uuid'}, app => $app });
			}
		}
	}
}

sub window_maker($type,$timestamp) {
	$timestamp = &subs::rightNow() unless $timestamp;
	my $window = "Window";
	my $app = $type->{'app'};
	# An app the rule does not allow is not drawn, even when its static start-menu
	# icon is still on screen. A private app is a lock: outside a private place it
	# says why it cannot be found, and inside one it asks for the fingerprint.
	# During lockdown Security is the way in, a Dangerous app is deliberately
	# kept, and an Enemy's app appears only after a fingerprint.
	if ($app && &subs::app_hidden_now($app)) {
		my ($heading, $message) = (&subs::ui('Lockdown'), &subs::ui('An enemy is present, or this is a dangerous place. Open Security and confirm with your fingerprint to reveal the appointment so you can stop it.'));
		if (&subs::app_private_now($app)) {
			$heading = &subs::ui('Private apps');
			$message = &subs::private_reachable_now()
				? &subs::ui('This app is private. Open Security and confirm with your fingerprint to show private apps on this screen.')
				: &subs::ui('This app is private. It can only be found in a private place, with no enemy present.');
		}
		$type->{'contents'} = '<div class="lockdown_window" style="padding:22px;line-height:1.5;max-width:640px;">'
			. '<h2>' . $heading . '</h2>'
			. '<p>' . $message . '</p>'
			. '</div>';
		$type->{'title'} = $heading;
		$type->{'window_name'} = $heading;
	}
	my $window_settings = [ 'pos', 'main_image', 'dimensions', 'colour', 'dark_colour', 'uuid', 'navigation', 'ci', 'scrollTop', 'jopen' ];
	my $settings = $type->{'settings'} || &subs::settings_grabber({ app => $app, settings => $window_settings });
	my $temp_s = {};
	foreach my $win_s ( @{$window_settings} ) {
		$temp_s->{$win_s} = $settings->{$win_s};
	}
	$settings = $temp_s;


	unless ($settings->{'uuid'}) {
		$settings = &subs::setting_initializer($app,$timestamp);
	}
	my ($db,$database,$sql) = &subs::database_grabber();


	my $user_agent = $type->{'user_agent'};
	my $websockets = &subs::db_query('select * from websockets where app=? and user_agent = ? and windows like ? and windows is not null order by timestamp DESC',
		'tab', $user_agent, '%app":"' . $type->{'app'} . '%')->hashes;
	my $jws = undef;
	foreach my $w ( @{$websockets} ) {
		my $ws = eval { return decode_json $w->{'windows'} } || {};
		if ($ws->{$app}) {
			$jws = &subs::apostrophe_escape(encode_json $ws);
			last;
		}
	}

	my $contents;
	my $title;
	my $drawer;
	my $formatted_name = &subs::format_name($type->{'app'});
	my $unformatted_name = &subs::unformat_name($type->{'app'});
	my $window_name = (defined $type->{'window_name'} && length $type->{'window_name'}) ? $type->{'window_name'} : $formatted_name;
	my $html_name = &subs::html_name($type->{'app'});
	my $app_attr = &subs::html_text($unformatted_name);
	my $app_text = &subs::html_text($window_name);
	my $http_name = &subs::http_name($type->{'app'});
	my $apostrophe_escape = &subs::apostrophe_escape($type->{'app'});
	my $terminal_attr = '';
	if ($type->{'terminal_id'}) {
		my $tid = $type->{'terminal_id'};
		$tid =~ s/[^A-Za-z0-9_\-]//g;
		$terminal_attr = ' data-terminal-id="' . $tid . '"' if length $tid;
	}
	# A generic window instance: several windows of one app (Folders, now) are
	# told apart by this, the same way Terminal is by its session id.
	my $window_instance_attr = '';
	if ($type->{'window_id'}) {
		my $wid = $type->{'window_id'};
		$wid =~ s/[^A-Za-z0-9_\-]//g;
		$window_instance_attr = ' data-window-id="' . $wid . '"' if length $wid;
	}

	my $jp = $apostrophe_escape;
	if ($jp =~ /cam$|scr$|aud$/gi) {
		$jp =~ s/_cam$|_scr$|_aud$//gi;
	}
	if ($type->{'internal_url'}) {
		my $iframe_src = '"/manager/browser?internal_url=' . $type->{'internal_url'} . '&timestamp='.$timestamp.'"';
		$contents = '<iframe src=' . $iframe_src . ' style="width:100%;height:100%;"></iframe>';
		$title = 'browser';
	}
	elsif ($type->{'iframe'}) {
		my $iframe_src = '"' . $type->{'iframe'} . '"';
		$contents = '<iframe src=' . $iframe_src . ' style="width:100%;height:100%;"></iframe>';
		$title = 'browser';
	}
	else {
		$contents = $type->{'contents'};
	}
	if ($type->{'title'}){
		$title = $type->{'title'};
	}
	if ($settings->{'navigation'} && $settings->{'navigation'} ne 'once') {
		$settings->{'navigation'} = &subs::time_abbrev_translator($settings->{'navigation'});
	}

	my $main_image = &subs::main_icon_maker({ app => $unformatted_name, timestamp => $timestamp, settings => $settings, size => 'tiny', hint => $type->{'window_name'} });
	# the window controls wear the icon set when it offers them, and the old text
	# glyphs when it does not (the hand-drawn set, or no set at all)
	my $window_control = sub {
		my ($name, $glyph) = @_;
		my $icon = &subs::icon_path($name, '');
		return $icon ? '<img class="window_control_icon" src="' . $icon . '">' : $glyph;
	};
	# The page agent's own button: the Guide's associate, opened against this
	# window with page mode on, so it can read and fill the form in front of you.
	# Only the Internet window wears it, in place of the question mark: that is
	# where a page is actually filled in (an address, an app for a domain). Every
	# other window keeps Help.
	my $page_agent_icon = &subs::icon_for('/images/make believe/assistant.png');
	my $navbar_agent_control = ($app_attr eq 'internet')
		? '<button id="window_' . $timestamp . '_page_agent" class="' . $html_name . '_page_agent_button window_action page_agent_button" timestamp="' . $timestamp . '" app="' . $app_attr . '" hint="' . xml_escape(&subs::ui(q{Page agent — read and fill this window's form for you})) . '"><img class="window_control_icon" src="' . $page_agent_icon . '"></button>'
		: '<button id="window_' . $timestamp . '_help" class="' . $html_name . '_help_button window_action help_button" timestamp="' . $timestamp . '" app="' . $app_attr . '" hint="Help">' . $window_control->('help', '?') . '</button>';
	my $pre_dimensioned = 0;
	if ($settings->{'dimensions'} && ($user_agent !~ /Android/gi || $user_agent !~ /Mobile/gi)) {
		$settings->{'dimensions'} = eval { return decode_json $settings->{'dimensions'} } || {};
		$pre_dimensioned = 1;
	}
	else {
		$settings->{'dimensions'} = {};
	}
	if (!$settings->{'colour'} || $settings->{'colour'} !~ /^#/) {
		$settings->{'colour'} = '#' . &subs::random_colour_grabber();
		&subs::setting_setter({ app => $app, setting => 'colour', value => $settings->{'colour'} });
	}
	my $window_colour = $settings->{'colour'} || '#ffec1f';
	my $window_dark = $settings->{'dark_colour'} || &subs::dark_colour_for($window_colour);
	my $window_ink = &subs::contrast_ink($window_colour);
	my $window_dark_ink = &subs::contrast_ink($window_dark);

	# A fresh window's size. The appointment wrapper's collapsed content - the
	# header, tape row, app_act row, group toggles, five fields, notes and the
	# evaluation headline - fits with room to spare and no app_act panel open;
	# the width keeps the five fields readable without wrapping. A window the
	# person has sized for themselves keeps its own dimensions.
	my $default_width = 480;
	my $default_height = 640;

	my $display =
		'<div class="wind" id="window_' . $timestamp . '" pre_dimensioned="' . $pre_dimensioned . '"' . $terminal_attr . $window_instance_attr . '  style="background-color:var(--window, var(--panel));
			position:fixed;left:' . ($settings->{'dimensions'}->{'left'}) . 'px;top:' . ($settings->{'dimensions'}->{'top'} || 100) . 'px;width:' . ($settings->{'dimensions'}->{'width'} || $default_width) . 'px;height:' . ($settings->{'dimensions'}->{'height'} || $default_height) . 'px" app="'. $app_attr .'" visible="yes" timestamp="' . $timestamp . '" navigation="' . ($settings->{'navigation'} || 'once') . '"
			locked="yes" current_information="' . $settings->{'ci'} . '" scrollTop="' . $settings->{'scrollTop'} . '">
			<div id="top_navbar_' . $timestamp . '" class="top_navbar" app="' . $app_attr . '" background_colour="' . $window_colour . '" data-appt-tint="yes" style="--appt-dark:' . $window_dark . ';--appt-dark-ink:' . $window_dark_ink . ';height:var(--navbar_h, 36px);max-height:var(--navbar_h, 36px);position:absolute;width:100%;border:var(--window_border, 3px) solid var(--window_border_colour, var(--line));background-color:'.$window_colour .
				';" app="' . $app_attr .'">
					<span class="window_icon_holder">' . $main_image . '</span>
				<span class="appointment_name">
					<span class="appointment_name_marks">
						<img class="medium_thumb unlock droppable" app="' . $app_attr . '" style="display:none;" src="/images/make believe/lock.png">
						<img class="medium_thumb jack droppable" app="' . $app_attr . '" style="display:none;" src="/images/studio/jack.png">
					</span>

					<span class="name_text" data-appt-ink="yes" style="--appt-dark-ink:' . $window_dark_ink . ';color:' . $window_ink . ';"  app="' . $app_attr . '">' . $app_text . '</span>
				</span>
				<span class="navbar_buttons">
					' . $navbar_agent_control . '
					<button id="window_' . $timestamp . '_minify" class="' . $html_name . '_minify_button window_action minimize_button" timestamp="'. $timestamp . '" app="' . $app_attr . '">' . $window_control->('minimize', '_') . '</button>
					<button id="window_' . $timestamp . '_restore" style="display:none;" class="' . $html_name . '_restore_button window_action restore_button" timestamp="' . $timestamp . '" app="' . $app_attr . '">' . $window_control->('restore', '#') . '</button>
					<button id="window_' . $timestamp . '_maximize" class="' . $html_name . '_maximize_button window_action maximize_button">' . $window_control->('maximize', '&#9634;') . '</button>
					<button id="window_' . $timestamp . '_close" class="' . $html_name . '_close_button window_action close_button" timestamp="' . $timestamp . '" app="' . $app_attr . '">' . $window_control->('close', 'X') . '</button>
				</span>
			</div>
			<div id="window_drawer_' . $timestamp . '" class="window_drawer" data-appt-tint="yes" style="--appt-dark:' . $window_dark . ';--appt-dark-ink:' . $window_dark_ink . ';position:absolute;top:calc(var(--navbar_h, 36px) - 2px);background-color:' . $window_colour . ';width:100%;display:none;height:calc(100% - var(--navbar_h, 36px) + 2px);overflow:scroll;">
			<img src="/images/make believe/space.png" style="position:absolute;left:30%;height:24px;width:30%;" class="window_drawer_closer hover">
			<div id="window_drawer_contents_' . $timestamp . '" class="window_drawer_contents" style="padding-top:20px;background-color:var(--window, var(--panel));">' . $drawer . '</div></div>
			<div id="window_contents_' . $timestamp .'" class="window_contents" style="display:flex;background-color:var(--window, var(--panel));height:calc(100% - var(--navbar_h, 36px) + 2px);">' . $contents . '</div>

		<script id="window_script_' . $timestamp .'">
			jopen = \'' . $settings->{'jopen'} . '\';
			jws = \'' . $jws . '\';
			var w = $("#window_' . $timestamp . '");
			var wc = $("#window_contents_' . $timestamp . '");
			var t = $("#top_navbar_' . $timestamp . '");
			// the contents tuck a hair under the title bar (the navbar paints over
			// them, so there is no seam) and run right to the foot of the window:
			// the height below already carries the +2px the box needs, so a padding
			// of navbar-2 leaves the whole box exactly 100% tall and the frame bottom
			// edge lands on the contents bottom edge. Reading the same variable keeps
			// it right when the navbar slider moves the bar.
			wc.css({ \'padding-top\': \'calc(var(--navbar_h, 36px) - 2px)\' });
			$(\'#main_display\').css({ \'display\':\'flex\', \'height\':\'83%\', \'width\': \'93%\' });
			var wl = $("#little_window_' . $timestamp . '");
		</script>		</div>';
	return { window => $display, settings => $settings } if $type->{'source'} eq 'centre_view_grabber';
	return $display;
};

sub random_card_picker() {
	my $cards = `ls public/images/cards`;
	my @cards = shuffle split /\n/, $cards;

	@cards = shuffle grep { $_ ne 'title.png' && $_ ne 'back.png' } shuffle @cards;
	my $card = $cards[rand(scalar @cards)];

	return $card;
}

1;
