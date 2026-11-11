package Manager;

# manager_misc8: route actions moved out of Manager.pl, one sub per route so a
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
use JawnOS::Platform::Shell ();
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

# The Browser's + Search button: look at the page the person is on for its
# OpenSearch description, then for a search parameter already in the address.
# Failing both, a plain /search?q= guess is offered; it can be removed from the
# settings panel if the site does not use it.
# POST /manager/search/engine/probe
sub action_26376 {
	my $c = shift;
	my $page = $c->param('url') // '';
	my $given = $c->param('name') // '';
	unless ($page =~ m{^https?://}i) {
		$c->render(json => { ok => 0, error => 'only an http(s) page can be added' });
		return;
	}
	my $ua = Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 6, request_timeout => 9, max_redirects => 5);
	$ua->transactor->name($user_agent);
	my ($name, $template);
	my $res = eval { $ua->get($page)->result };
	my $dom = ($res && $res->is_success) ? eval { Mojo::DOM->new($res->text || '') } : undef;
	my $base = Mojo::URL->new($page);
	if ($dom) {
		foreach my $link ( $dom->find('link[rel="search"]')->each ) {
			my $type = lc($link->attr('type') // '');
			my $href = $link->attr('href') // '';
			next unless $href =~ m{^https?://}i || $href =~ m{^/};
			next unless $type eq '' || $type =~ /opensearchdescription/;
			my $abs = eval { Mojo::URL->new($href)->to_abs($base)->to_string };
			next unless $abs;
			my $xres = eval { $ua->get($abs)->result };
			next unless $xres && $xres->is_success;
			my $xdom = eval { Mojo::DOM->new($xres->body || '') } || Mojo::DOM->new('');
			$name ||= eval { $xdom->at('ShortName')->text };
			foreach my $u ( $xdom->find('Url')->each ) {
				my $t = $u->attr('template') // '';
				next unless $t =~ /\{searchTerms\}/;
				my $utype = lc($u->attr('type') // '');
				next unless $utype eq '' || $utype eq 'text/html';
				$t =~ s/&amp;/&/g;
				$t =~ s/\{searchTerms\}/\{q\}/g;
				$template = $t;
				last;
			}
			last if $template;
		}
	}
	# a search parameter already in the address is the next best evidence
	if (!$template) {
		my $u = Mojo::URL->new($page);
		my $params = $u->query;
		foreach my $key (qw(q query search searchText search_text s keyword keywords text term terms k wd p)) {
			if ($params->param($key)) {
				$params->param($key => '{q}');
				$template = $u->to_string;
				last;
			}
		}
	}
	if (!$template) {
		my $u = Mojo::URL->new($page);
		my $origin = $u->scheme . '://' . $u->host . ($u->port ? ':' . $u->port : '');
		$template = $origin . '/search?q={q}';
	}
	if (!$name) {
		$name = $given;
		if (!$name && $dom) {
			my $title = eval { $dom->at('title')->text } || '';
			$title =~ s/\s+/ /g;
			$title =~ s/^\s+|\s+$//g;
			$title =~ s/\s*[|\-–—]\s*[^|\-–—]{1,40}$//;
			$name = $title;
		}
		$name ||= eval { Mojo::URL->new($page)->host } || 'Search';
	}
	my $entry = &search_engine_add_custom($name, $template);
	$c->render(json => {
		ok => 1,
		id => $entry->{'id'},
		name => $entry->{'name'},
		url => $entry->{'url'}
	});
}

# GET /manager/search/web
sub action_26590 {
	my $c = shift;
	my $q = $c->param('q') // '';
	$q =~ s/^\s+|\s+$//g;
	if (length($q) < 2) {
		$c->render(json => { engines => [] });
		return;
	}
	$c->render(json => { engines => &search_web_matches($q) });
}

# The AI tab: the Guide's own model answers in plain text. It is asked on Enter,
# not on every letter, so a search does not spend a call per keystroke.
# POST /manager/search/ai
sub action_26602 {
	my $c = shift;
	my $q = $c->param('q') // '';
	$q =~ s/^\s+|\s+$//g;
	if (!length $q) {
		$c->render(json => { ok => 0, error => &subs::ui('Ask something first.') });
		return;
	}
	my $system = 'You are the Search app\'s AI inside JawnOS, a personal, self-hosted operating environment. '
		. 'Answer the question directly in a few short paragraphs of plain text. '
		. 'No headings, no bullet lists, no markdown and no preamble. If you are unsure, say so plainly.';
	my ($text, $err) = &subs::evaluation_model_call_role('help_assistant', $system, $q, &subs::ai_role_thinking_effective('help_assistant'));
	unless (defined $text && length $text) {
		$c->render(json => { ok => 0, error => ($err || &subs::ui('The AI did not answer.')) });
		return;
	}
	$c->render(json => { ok => 1, answer => $text });
}

# POST /manager/clipboard_setter
sub action_26628 {
	my $c = shift;
	my $clipboard = $c->param('clipboard');
	if ($device eq 'mobile') {
	#	`echo "$clipboard" | termux-clipboard-set`;
	}
	elsif ($device eq 'computer') {
	#	`xclip -i "$clipboard"`;
	}
	# A clipboard can hold markup; returning it as a page would render it.
	$c->res->headers->content_type('text/plain');
	return $c->render(text => $clipboard);
}

# GET /manager/clipboard_getter
sub action_26639 {
	my $c = shift;
	my $returner;
	if ($device eq 'mobile') {
		my $clip = &subs::device_call('clipboard.get');
		$returner = $clip ? ($clip->{'text'} // '') : '';
	}
	elsif ($device eq 'computer') {
		$returner = JawnOS::Platform::Shell::clipboard_get();
	}
	$c->render(text => $returner);
}

# GET /manager/search_engine_grabber
sub action_26651 {
	my $c = shift;
	$c->render(text => &search_engine_grabber($c));
}

# GET /manager/web
sub action_26677 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');

	my $contents = $c->render_to_string(
		template => 'web/web',
		app => ''
	);


	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'web', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# GET /manager/web/measure/toggle
sub action_26690 {
	my $c = shift;
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');

	my $website = &subs::db_select('websites', undef, { app => $app, uuid => $uuid })->hashes->[0];

	my $dom = Mojo::DOM->new($website->{'content'});

	my $m = &subs::db_query('select * from settings where app=? and setting = ? and device = ?', $app, 'app_measures', $device)->hashes->[0];
	my $measures = eval { return decode_json $m->{'value'} } || {};
	foreach my $ma ( keys %{$measures} ) {
		$measures->{$ma}->{'formatted'} = &subs::format_name($ma);
	}
	$c->render(json => { app => $app, uuid => $uuid, measures => $measures });
}

# POST /manager/web/measure/set
sub action_26706 {
	my $c = shift;
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $selector = $c->param('selector');
	my $text = $c->param('text');
	my $index = $c->param('index') // 0;
	my $measure = $c->param('measure');
	my $website = &subs::db_select('websites', undef, { app => $app, uuid => $uuid })->hashes->[0];
	my $dom = Mojo::DOM->new($website->{'content'});

	# The prettyfier shows JSON as HTML, so the clicked span's id has to be
	# mapped back to a real path. Fetch the live document for that mapping; the
	# click is a one-off action and the page is already fetched on a schedule.
	my $json;
	if ((&subs::setting_value_for($app, 'web_format') || 'html') eq 'json') {
		my $url = &subs::setting_value_for($app, 'web');
		if (defined $url && length $url) {
			my $ua = Mojo::UserAgent->new(insecure => 1, inactivity_timeout => 8, connect_timeout => 4);
			my $res = eval { $ua->get($url => { user_agent => $gb::user_agent })->result };
			$json = eval { decode_json $res->body } if $res && $res->is_success;
		}
	}

	my $candidates = &subs::web_measure_candidates($dom, $json, $selector, $index);

	my $confirmation = $c->render_to_string(
		template => 'web/web_measure_confirm',
		candidates => $candidates,
		app => $app,
		measure => $measure,
		selector => $selector
	);

	$c->render(json => {
		app => $app,
		uuid => $uuid,
		selector => $selector,
		index => $index,
		candidates => $candidates,
		confirmation => $confirmation
	});

}

# POST /manager/web/measure/submit
sub action_26750 {
	my $c = shift;
	my $app = $c->param('app');
	my $measure = $c->param('measure');
	my $spec_json = $c->param('spec');

	my $data;
	if (defined $spec_json && length $spec_json) {
		my $chosen = eval { decode_json $spec_json };
		$data = ref $chosen eq 'HASH' ? $chosen : undef;
	}
	unless ($data) {
		# the old form: count/prev/next/selector
		$data = {
			count => $c->param('count'),
			prev => $c->param('prev'),
			next => $c->param('next'),
			selector => $c->param('selector')
		};
	}
	$data->{'measure'} = $measure;

	&subs::setting_setter({ app => $app, setting => 'web_measure_data', subsetting => $measure, value => encode_json $data });

	$c->render(json => $data);
}

# POST /manager/web/measure/delete
sub action_26776 {
	my $c = shift;
	my $app = $c->param('app');
	my $measure = $c->param('measure');

	my $web_measures = &subs::db_query('select * from settings where app=? and setting = ? and subsetting = ?', $app, 'web_measure_data', $measure)->hashes;
	foreach my $wm ( @{$web_measures} ) {
		&deletion_registration({ table => 'settings', uuid => $wm->{'uuid'}, scope => 'single', server_time => $wm->{'server_time'} });
		&subs::db_delete('settings', { app => $wm->{'app'}, setting => 'web_measure_data', uuid => $wm->{'uuid'} });
	}
	$c->render(json => $web_measures);

}

# POST /manager/web/delete
sub action_26789 {
	my $c = shift;
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $del = &subs::db_select('websites', undef, { uuid => $uuid, app => $app })->hashes->[0];
	&subs::db_delete('websites', { app => $app, uuid => $uuid });
	&deletion_registration({ table => 'websites', uuid => $uuid, scope => 'single', server_time => $del->{'server_time'} });
	$c->render(json => { app => $app, uuid => $uuid });

}

# POST /manager/usage/session
sub action_26810 {
	my $c = shift;
	my $kind = ($c->param('kind') // 'app') eq 'site' ? 'site' : 'app';
	my $key = $c->param('key') // '';
	$key =~ s/^\s+|\s+$//g;
	$key = substr($key, 0, 500);
	unless (length $key) { $c->render(json => { ok => 0, error => 'need a key' }); return; }
	my $now = &subs::rightNow();
	my $start = &usage_ms($c->param('started_at')) || $now;
	my $end = &usage_ms($c->param('ended_at')) || $now;
	$end = $now if $end > $now;
	$start = $end if $start > $end;
	my $span = $end - $start;
	unless ($span >= 1000 && $span <= 12 * 60 * 60 * 1000) {
		$c->render(json => { ok => 0, error => 'span out of range' });
		return;
	}
	my $idle = &usage_ms($c->param('idle_ms'));
	$idle = $span if $idle > $span;
	my $source = substr(($c->param('source') // ''), 0, 25);
	my $url = substr(($c->param('url') // ''), 0, 2000);
	my $title = substr(($c->param('title') // ''), 0, 1000);
	my $uuid = &subs::random_string_creator(15);
	&subs::db_insert('usage_sessions', {
		uuid => $uuid,
		device => $device,
		kind => $kind,
		key_name => $key,
		started_at => $start,
		ended_at => $end,
		idle_ms => $idle,
		source => $source,
		hostname => '',
		title => $title,
		url => $url,
		server_time => $now,
		ost => $now,
	});
	$c->render(json => { ok => 1, uuid => $uuid });
}

# GET /manager/usage/summary
sub action_26850 {
	my $c = shift;
	my $kind = ($c->param('kind') // 'app') eq 'site' ? 'site' : 'app';
	my $to = &usage_ms($c->param('to')) || &subs::rightNow();
	my $from = &usage_ms($c->param('from')) || ($to - 24 * 60 * 60 * 1000);
	my $rows = eval { &subs::db_query(q{
		select key_name as key,
			sum(max(0, cast(ended_at as integer) - cast(started_at as integer) - cast(coalesce(nullif(idle_ms, ''), '0') as integer))) as total_ms,
			count(*) as sessions,
			max(cast(ended_at as integer)) as last_at
		  from usage_sessions
		 where device = ? and kind = ? and cast(ended_at as integer) >= ? and cast(started_at as integer) <= ?
		 group by key_name
		 order by total_ms desc
	}, $device, $kind, $from, $to)->hashes } || [];
	foreach my $row ( @{$rows} ) {
		$row->{'total_ms'} = int($row->{'total_ms'} // 0);
		$row->{'sessions'} = int($row->{'sessions'} // 0);
		$row->{'last_at'} = int($row->{'last_at'} // 0);
	}
	$c->render(json => { from => $from, to => $to, kind => $kind, rows => $rows });
}

# GET /manager/usage/timeline
sub action_26872 {
	my $c = shift;
	my $kind = ($c->param('kind') // 'app') eq 'site' ? 'site' : 'app';
	my $to = &usage_ms($c->param('to')) || &subs::rightNow();
	my $from = &usage_ms($c->param('from')) || ($to - 24 * 60 * 60 * 1000);
	my $rows = eval { &subs::db_query(q{
		select strftime('%Y-%m-%dT%H', cast(started_at as integer) / 1000, 'unixepoch', 'localtime') as hour,
			key_name as key,
			sum(max(0, cast(ended_at as integer) - cast(started_at as integer) - cast(coalesce(nullif(idle_ms, ''), '0') as integer))) as total_ms
		  from usage_sessions
		 where device = ? and kind = ? and cast(ended_at as integer) >= ? and cast(started_at as integer) <= ?
		 group by hour, key_name
		 order by hour, total_ms desc
	}, $device, $kind, $from, $to)->hashes } || [];
	foreach my $row ( @{$rows} ) { $row->{'total_ms'} = int($row->{'total_ms'} // 0); }
	$c->render(json => { from => $from, to => $to, kind => $kind, rows => $rows });
}

# The browser clicked an element in a live page. The document arrives as text
# (never executed) and the same candidate finder the saved-page flow uses runs
# over it, so a measure picked in Browse is the same shape as one picked in Web.
# POST /manager/web/measure/live
sub action_26892 {
	my $c = shift;
	my $app = $c->param('app') // '';
	my $uuid = $c->param('uuid') // '';
	my $selector = $c->param('selector') // '';
	my $index = $c->param('index') // 0;
	my $measure = $c->param('measure') // '';
	my $html = $c->param('html') // '';
	my $url = substr(($c->param('url') // ''), 0, 2000);
	my $title = substr(($c->param('title') // ''), 0, 1000);
	unless (length $app && length $selector && length $html) {
		$c->render(json => { ok => 0, error => 'need app, selector and html' });
		return;
	}
	$html = substr($html, 0, 2_000_000);
	my $dom = Mojo::DOM->new($html);
	my $candidates = &subs::web_measure_candidates($dom, undef, $selector, $index);
	my $confirmation = $c->render_to_string(
		template => 'web/web_measure_confirm',
		candidates => $candidates,
		app => $app,
		measure => $measure,
		selector => $selector
	);
	$c->render(json => {
		ok => 1,
		app => $app,
		uuid => $uuid,
		selector => $selector,
		index => $index,
		candidates => $candidates,
		confirmation => $confirmation,
		url => $url,
		title => $title,
	});
}

# GET /manager/internet
sub action_26928 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = $c->render_to_string(
		template => 'internet/internet',
		app => 'internet'
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'internet', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# The native home's live half: the clothesline of running apps and the theme
# the manager is using, polled while the home is on screen. Gated like the
# manager (it carries the person's running apps), so the home sends its session
# cookie; before a session exists the start row still draws from /apps/start.
# GET /manager/home_status
sub action_27089 {
	my $c = shift;
	my $clothesline = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'clothesline' }) } || [];
	my (@running, %seen);
	foreach my $item (ref $clothesline eq 'ARRAY' ? @{$clothesline} : ()) {
		next unless ref $item eq 'HASH';
		my $app = $item->{'app'} || $item->{'name'} || '';
		next unless length $app;
		next if &help_app_hidden($app);
		next if $seen{$app}++;
		push @running, {
			app    => $app,
			title  => ($item->{'formatted_name'} || &subs::format_name($app)),
			colour => ($item->{'colour'} || ''),
			icon   => &app_icon_url($app),
		};
	}
	my $bg = &subs::setting_grabber({ app => 'misc', setting => 'manager_background_colour' });
	unless (defined $bg && $bg =~ /^\#?[0-9a-fA-F]{6}\z/) {
		my @palette = &subs::theme_palette();
		$bg = $palette[0] if scalar @palette && defined $palette[0];
	}
	$bg = '#f7f7f7' unless defined $bg && $bg =~ /^\#?[0-9a-fA-F]{6}\z/;
	$bg = '#' . $1 if $bg =~ /^([0-9a-fA-F]{6})\z/;
	my $ink = &subs::contrast_ink($bg);
	$c->render(json => {
		running => \@running,
		theme => {
			background => $bg,
			ink        => $ink,
			muted      => ($ink eq '#ffffff' ? '#c9c9c9' : '#3a3a3a'),
			dark       => ($ink eq '#ffffff' ? 1 : 0),
		},
		timestamp => &subs::rightNow(),
	});
}

# GET /manager/internet/sites
sub action_27129 {
	my $c = shift;
	my $now = &subs::rightNow();
	my $from = $now - 30 * 24 * 60 * 60 * 1000;
	my $map = &internet_domain_apps();
	my %sites;
	my $rows = eval { &subs::db_query(q{
		select key_name,
			sum(max(0, cast(ended_at as integer) - cast(started_at as integer) - cast(coalesce(nullif(idle_ms, ''), '0') as integer))) as total_ms,
			max(cast(ended_at as integer)) as last_at,
			max(url) as url
		  from usage_sessions
		 where device = ? and kind = 'site' and cast(ended_at as integer) >= ?
		 group by key_name
	}, $device, $from)->hashes } || [];
	foreach my $row ( @{$rows} ) {
		my $domain = $row->{'key_name'} || next;
		$sites{$domain} = {
			domain => $domain,
			total_ms => int($row->{'total_ms'} // 0),
			last_at => int($row->{'last_at'} // 0),
			url => $row->{'url'} || '',
		};
	}
	# a saved page is a bookmark even before it has been browsed for a minute
	my $saved = eval { &subs::db_query('select url from websites')->hashes } || [];
	foreach my $row ( @{$saved} ) {
		my $url = $row->{'url'} || next;
		my ($domain) = $url =~ m{^https?://([^/]+)}i;
		next unless $domain;
		$domain = lc $domain;
		$domain =~ s/^www\.//;
		$sites{$domain} ||= { domain => $domain, total_ms => 0, last_at => 0, url => $url };
	}
	my @out;
	foreach my $domain ( sort { ($sites{$b}->{'total_ms'} <=> $sites{$a}->{'total_ms'}) || ($a cmp $b) } keys %sites ) {
		my $site = $sites{$domain};
		$site->{'app'} = $map->{$domain} || '';
		$site->{'url'} = 'https://' . $domain . '/' unless length $site->{'url'};
		push @out, $site;
	}
	$c->render(json => { sites => \@out, apps => &internet_app_catalog({ visible_only => 1, any_appt => 1 }) });
}

# POST /manager/internet/site/app
sub action_27172 {
	my $c = shift;
	my $domain = lc($c->param('domain') // '');
	$domain =~ s{^https?://}{}i;
	$domain =~ s{/.*$}{};
	$domain =~ s/^www\.//;
	my $app = &subs::unformat_name($c->param('app') // '');
	unless (length $domain) { $c->render(json => { ok => 0, error => 'need a domain' }); return; }
	my $map = &internet_domain_apps();
	if (length $app) { $map->{$domain} = $app; }
	else { delete $map->{$domain}; }
	&subs::setting_setter({ app => 'internet', setting => 'domain_apps', value => encode_json($map) });
	$c->render(json => { ok => 1, domain => $domain, app => $app });
}

# GET /manager/website_get
sub action_27187 {
	my $c = shift;
	my $app = $c->param('app');
	my ($window,$internal_url,$uuid,$timestamp) = &website_grabber({
		app => $app,
		website => $c->param('website'),
		timestamp => $c->param('timestamp'),
		user_agent => $c->param('user_agent'),
		uuid => $c->param('uuid')
	});
	$c->render(json => { internal_url => $internal_url, window => $window, uuid => $uuid, app => &subs::format_name($app), timestamp => $timestamp });
}

# GET /manager/browser
sub action_27369 {
	my $c = shift;
	my $internal_url = $c->param('internal_url');
	my $app = &subs::unformat_name($c->param('app'));
	my $uuid = $c->param('uuid');

	my $timestamp = $c->param('timestamp');
	my ($db,$database,$sql) = &subs::database_grabber();
	if ($internal_url eq 'none') {
		$c->render(text => "<h1>None</h1>");
	}
	else {
		my $results;
		if ($uuid) {
			$results = &subs::db_select('websites', ['app','content','url','internal_url'],{ uuid => $uuid, app => $app });
		}
		else {
			$results = &subs::db_select('websites', ['app','content','url','internal_url'],{ internal_url => $internal_url });
		}
		my $saved_websites = $results->hashes;
		my $settings = &subs::settings_grabber({ app => $app, settings => [ 'web_format' ] });
		my $website = $saved_websites->[-1]->{'content'};



		#$saved_websites->[-1]->{'title'} = $saved_websites->[-1]->{'app'} + ' website';
		#my $window = &window_maker($saved_websites->[-1], $timestamp);

		$c->render(text => $website);
	}
}

# GET /manager/media_window
sub action_27400 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $settings = &subs::settings_grabber({ app => $app });
	my $id = $c->param('id');
	my $misses = eval { return decode_json $c->param('misses') } || {};
	if (!$misses->{$id}) {
		$misses->{$id} = &subs::random_string_creator(25,"Aa");
	}
	my $contents = $c->render_to_string(
		template => 'apps/video',
		id => $id,
		source => $c->param('source'),
		remote_address => $c->tx->remote_address,
		local_address => $c->tx->local_address,
		crate => { settings => $settings },
		misses => $misses
	);
	if ($c->param('window_maker')) {
		$c->render('text' => &window_maker({ user_agent => $c->param('user_agent'), app => $app, timestamp => $c->param('timestamp'), contents => $contents }, $timestamp));
	}
	else {
		$c->render(json => { html => $contents, settings => $settings, app => $app, timestamp => $timestamp });
	}
}

# GET /manager/window_maker
sub action_27426 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $contents = $c->param('contents');
	$c->render('text' => &window_maker({ user_agent => $c->param('user_agent'), app => $app, timestamp => $timestamp, contents => $contents },$timestamp));
}

# GET /manager/text_editor/create
sub action_27624 {
	my $c = shift;
	my $id = $c->param('id');
	my $contents = $c->param('contents');
	my $placeholder = $c->param('placeholder');
	my $context = &text_area_context($c->param('magic_vars'));
	my $p_id = $id . '_text_editor';
	my $html = $c->render_to_string(
		template => 'text_editor',
		id => $id,
		p_id => $p_id,
		contents => $contents,
		placeholder => $placeholder,
		variables => &text_editor_variables($context)
	);

	$c->render(json => { html => $html, p_id => $p_id, id => $id });
}

1;
