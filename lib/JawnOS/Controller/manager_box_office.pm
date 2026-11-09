package Manager;

# manager_box_office: route actions moved out of Manager.pl, one sub per route so a
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

use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

# GET /manager/box_office
sub action_14039 {
	my $c = shift;
	# the desk lists every ticket's link and secret: only the citizen reads it
	unless (&ticket_desk_allowed($c)) {
		$c->render(text => '');
		return;
	}
	my $app = &subs::unformat_name('box_office');
	my $view = $c->param('view') || &subs::setting_grabber({ app => 'misc', setting => 'box_office_view' });
	my $timestamp = $c->param('timestamp');
	my ($db,$database,$sql) = &subs::database_grabber();
	&qrcode_updater($c);
	my $ticks = &subs::db_query('select * from tickets');
	my $tickets = $ticks->hashes;
	my $devices = &subs::device_lister($timestamp, '');
	my $addresses = $devices->[0]->{'address'};
	my $warranty = $c->param('warranty') || &subs::setting_grabber({ app => $app, setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' });
	my $projs = &subs::db_query('select * from settings where (setting=? or setting=?) and value=?', 'pos','mab', 'project');
	my $projects = $projs->hashes;
	my $persons = &subs::db_query('select * from settings where (setting=? or setting=?) and value=? or value = ?', 'pos','mab','person', 'customer');
	my $requests = [ grep { ($_->{'status'} || '') eq 'request' } @{$tickets} ];
	my $crest_index;
	foreach my $r ( @{$requests} ) {
		$r->{'access_log'} = [];
		$r->{'info'} = eval { return decode_json $r->{'information'} } || {};
		$r->{'known'} = &ticket_request_known($r->{'info'});
		# The crest the request carried: the desk sees who is asking, and
		# whether this house has met them, without the crest granting anything.
		my $crest = $r->{'info'}->{'crest'};
		my $crest_uuid = (ref $crest eq 'HASH' ? ($crest->{'uuid'} || '') : '') || ($r->{'crest_uuid'} || '');
		if (length $crest_uuid) {
			my $entry = &subs::crest_peer_find($crest_uuid);
			my $state = $entry ? &people_crest_state($entry) : { met => 0, introduced_by => '' };
			my $name = ref $crest eq 'HASH' ? ($crest->{'name'} || '') : '';
			my $fingerprint = ref $crest eq 'HASH' ? ($crest->{'fingerprint'} || '') : '';
			if ($entry && ref $entry->{'crest'} eq 'HASH') {
				$name ||= $entry->{'crest'}->{'name'} || '';
				$fingerprint ||= $entry->{'crest'}->{'fingerprint'} || '';
			}
			my $app = &subs::crest_contact_app_for_uuid($crest_uuid) || '';
			my $chips = [];
			if ($app) {
				$crest_index ||= &people_index();
				$chips = &people_chips($crest_index, $app);
			}
			$r->{'crest'} = {
				uuid => $crest_uuid,
				name => $name,
				fingerprint => $fingerprint,
				known => $entry ? 1 : 0,
				met => $state->{'met'} ? 1 : 0,
				introduced_by => $state->{'introduced_by'} || '',
				image => $entry ? &people_crest_entry_image($entry) : '',
				app => $app,
				chips => $chips,
			};
		}
	}
	foreach my $t ( @{$tickets} ) {
		my $al = eval { return decode_json $t->{'access_log'} } || [];
		$t->{'access_log'} = $al;
	}
	my $people = $persons->hashes;
	# this path rides the bare signed rail (see hooks.pl), so the device/string
	# stash the hook sets for a gated path is absent; the desk template and
	# window_maker both read them, so set them here for citizen and peer alike
	$Manager::random_caching_string = &subs::jawn_version();
	$c->stash('device' => &subs::device_setter(), 'string' => $Manager::random_caching_string);
	my $content = $c->render_to_string(
		template => 'box_office',
		timestamp => $timestamp,
		config => &subs::config_reader(),
		addresses => $addresses,
		tickets => $tickets,
		requests => $requests,
		blacklist => &ticket_blacklist(),
		policy => &ticket_policy(),
		nic => &subs::setting_grabber({ app => $app, setting => 'last_nic' }),
		name => &subs::setting_grabber({ app => $app, setting => 'last_name' }) || &subs::setting_grabber({ app => 'me', setting => 'my_name' }),
		privilege => &subs::setting_grabber({ app => $app, setting => 'last_privilege' }) || 'visitor',
		warranty => $warranty,
		projects => $projects,
		people => $people,
		config => &subs::config_reader(),
		view => $view
	);

	if ($c->param('source') ne 'list') {
		$content = &window_maker({ user_agent => $c->param('user_agent'), app => $app, contents => $content }, $timestamp);
	}
	$c->render('text' => $content);
}

# The desk's decisions, all citizen acts: approve mints the ticket the request
# asked for (and keeps its information and requesting tab), decline forgets
# the request, blacklist remembers the identifiers so the door refuses them
# before a request is ever queued.
# POST /manager/box_office/approve
sub action_14274 {
	my $c = shift;
	unless (&ticket_desk_allowed($c)) {
		$c->render(json => { error => 'denied' });
		return;
	}
	my $uuid = $c->param('ticket');
	my $privilege = $c->param('privilege') || 'guest';
	$privilege = 'guest' unless $gb::chairs->{$privilege};
	my $warranty = $c->param('warranty') || &ticket_policy()->{'guest_warranty'};
	my $request = &subs::db_query('select * from tickets where uuid=? and status=?', $uuid, 'request')->hashes->[0];
	unless ($request->{'uuid'}) {
		$c->render(json => { error => 'no request' });
		return;
	}
	my $minted = &ticket_request_mint($c, $request, $privilege, $warranty);
	unless ($minted) {
		$c->render(json => { error => 'no key' });
		return;
	}
	&subs::db_delete('tickets', { uuid => $uuid });
	&subs::db_insert('tickets', $minted);
	&subs::db_update('tickets', { crest_uuid => $request->{'crest_uuid'} }, { uuid => $minted->{'uuid'} }) if $request->{'crest_uuid'};
	&Websocket::send('server', { console => &Websocket::console_command('ticketList')});
	$c->render(json => { ticket => $minted->{'uuid'}, url => $minted->{'url'} });
}

# POST /manager/box_office/decline
sub action_14300 {
	my $c = shift;
	unless (&ticket_desk_allowed($c)) {
		$c->render(json => { error => 'denied' });
		return;
	}
	my $uuid = $c->param('ticket');
	my $request = &subs::db_query('select * from tickets where uuid=? and status=?', $uuid, 'request')->hashes->[0];
	unless ($request->{'uuid'}) {
		$c->render(json => { error => 'no request' });
		return;
	}
	$log->info('ticket request declined: ' . $request->{'name'});
	&subs::db_delete('tickets', { uuid => $uuid });
	$c->render(json => { declined => $uuid });
}

# POST /manager/box_office/blacklist
sub action_14316 {
	my $c = shift;
	unless (&ticket_desk_allowed($c)) {
		$c->render(json => { error => 'denied' });
		return;
	}
	my $uuid = $c->param('ticket');
	my $request = &subs::db_query('select * from tickets where uuid=? and status=?', $uuid, 'request')->hashes->[0];
	unless ($request->{'uuid'}) {
		$c->render(json => { error => 'no request' });
		return;
	}
	my $info = eval { return decode_json $request->{'information'} } || {};
	my $list = &ticket_blacklist();
	push @{$list}, {
		name => $info->{'name'},
		email => $info->{'email'},
		phone => $info->{'phone'},
		note => $info->{'description'},
		timestamp => &subs::rightNow()
	};
	&ticket_blacklist_save($list);
	&subs::db_delete('tickets', { uuid => $uuid });
	$c->render(json => { blacklisted => $info->{'name'} });
}

# POST /manager/box_office/blacklist/remove
sub action_14341 {
	my $c = shift;
	unless (&ticket_desk_allowed($c)) {
		$c->render(json => { error => 'denied' });
		return;
	}
	my $stamp = $c->param('stamp');
	my $list = &ticket_blacklist();
	@{$list} = grep { ($_->{'timestamp'} || '') ne $stamp } @{$list};
	&ticket_blacklist_save($list);
	$c->render(json => { count => scalar @{$list} });
}

# POST /manager/box_office/policy
sub action_14353 {
	my $c = shift;
	unless (&ticket_desk_allowed($c)) {
		$c->render(json => { error => 'denied' });
		return;
	}
	my $policy = &ticket_policy();
	$policy->{'issue_guest_on_request'} = $c->param('issue_guest_on_request') && $c->param('issue_guest_on_request') eq 'on' ? 1 : 0;
	$policy->{'guest_warranty'} = $c->param('guest_warranty') || '-1d';
	&ticket_policy_set($policy);
	$c->render(json => $policy);
}

# POST /manager/box_office/blacklist/number
sub action_24775 {
	my $c = shift;
	# Block a number by hand: the desk's own input, or the Phone app's Block on a
	# recent call. The list is the box office's, so one route serves both. A recent
	# call filed from the device's call log carries the caller's app but not always
	# the number, so an app with no number given is looked up the way the phone's
	# own rows hold it.
	unless (&ticket_desk_allowed($c)) {
		$c->render(json => { error => 'denied' });
		return;
	}
	my $number = $c->param('number') || '';
	my $app = $c->param('app') || '';
	unless ($number =~ /\d/) {
		$number = $app ? (&subs::setting_grabber({ app => $app, setting => 'phone' }) || '') : '';
	}
	my $blocked = &ticket_blacklist_block($number, $c->param('name') || $app, $c->param('note'));
	unless ($blocked) {
		$c->render(json => { ok => 0, error => 'no number' });
		return;
	}
	$log->info('call blacklist: ' . $blocked . ' blocked');
	$c->render(json => { ok => 1, number => $blocked, numbers => &ticket_blacklist_numbers() });
}

1;
