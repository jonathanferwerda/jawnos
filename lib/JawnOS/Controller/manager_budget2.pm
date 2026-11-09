package Manager;

# manager_budget2: route actions moved out of Manager.pl, one sub per route so a
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

# POST /manager/budget/payable/add
sub action_22114 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $vendor = &subs::unformat_name($c->param('vendor'));
	my $item = &subs::unformat_name($c->param('item'));
	my $total = &payable_amount($c->param('total'));
	my $tax = &payable_amount($c->param('tax'));
	$tax = 0 if $tax < 0;
	$tax = $total if $tax > $total && $total > 0;
	$app = $vendor unless length $app;
	$app = 'unknown' unless length $app;
	if ($total <= 0) { return $c->render(json => { error => &subs::ui('A bill needs an amount.') }); }
	my $date = $c->param('date');
	my $timestamp = length($date || '') ? (str2time($date) || 0) * 1000 : &subs::rightNow();
	$timestamp = &subs::rightNow() unless $timestamp;
	my $currency = $c->param('currency') || &subs::setting_grabber({ app => $app, setting => 'currency' });
	my $repeat = $c->param('repeat') || 'once';
	# The same reader the appointment schedule uses: a compact interval stays on
	# the fast path, and a phrase in words is read by the Guide. A phrase that
	# cannot be read yet leaves a pending row; the bill is still recorded and the
	# Associate finishes the repeats after its question is answered.
	my $result = &subs::schedule_from_text($repeat, $timestamp, kind => 'bill', max => 366);
	my $pending;
	if ($result->{'ask'}) {
		$pending = {
			kind => 'bill', app => $app, vendor => $vendor, item => $item,
			amount => $total, tax => $tax, currency => $currency,
			start => $timestamp, text => $repeat, created => &subs::rightNow()
		};
		$pending->{'token'} = &subs::random_string_creator(24);
	}
	elsif (($result->{'source'} || '') eq 'interval' && scalar @{ $result->{'dates'} || [] }) {
		# a compact repeat keeps its rule, so a long-running schedule needs no
		# list of dates and a monthly bill keeps its anchor day
		my $list = &payable_schedules();
		push @{$list}, {
			uuid => &subs::random_string_creator(20), app => $app, vendor => $vendor, item => $item,
			amount => $total, tax => $tax, currency => $currency,
			every => $result->{'every'}, anchor_day => (localtime(int($timestamp / 1000)))[3],
			until => $result->{'until'}, next => $timestamp, active => 'on'
		};
		&payable_schedules_save($list);
		my $made = &payable_schedule_run();
		return $c->render(json => { ok => 1, scheduled => 1, made => $made, payables => &accounting_payables(&subs::rightNow()) });
	}
	elsif (($result->{'source'} || '') eq 'guide' && scalar @{ $result->{'dates'} || [] }) {
		# a phrase's dates are already worked out; the first bill is the date
		# typed beside the rate, and the rest follow it
		my @dates = ($timestamp, @{ $result->{'dates'} });
		my $list = &payable_schedules();
		push @{$list}, {
			uuid => &subs::random_string_creator(20), app => $app, vendor => $vendor, item => $item,
			amount => $total, tax => $tax, currency => $currency,
			dates => \@dates, next => $timestamp, active => 'on'
		};
		&payable_schedules_save($list);
		my $made = &payable_schedule_run();
		return $c->render(json => { ok => 1, scheduled => 1, made => $made, payables => &accounting_payables(&subs::rightNow()) });
	}
	my $uuid = &subs::random_string_creator(40);
	&subs::db_insert('warehouse', {
		kind => 'money',
		type => 'transaction',
		movement => 'payable',
		account => 'accounts_payable',
		app => $app,
		vendor => $vendor,
		item => $item,
		amount => $total,
		tax => $tax,
		total => $total,
		currency => $currency,
		uuid => $uuid,
		timestamp => $timestamp,
		server_time => &subs::rightNow()
	});
	my $response = { ok => 1, uuid => $uuid, payables => &accounting_payables(&subs::rightNow()) };
	if ($pending) {
		&subs::pending_schedule_add($pending);
		$response->{'one_off'} = 1;
		$response->{'token'} = $pending->{'token'};
		$response->{'ask'} = 'I recorded the bill, but I could not read the repeat "' . $repeat . '": '
			. $result->{'ask'} . ' Ask me what you need, then call schedule with token "'
			. $pending->{'token'} . '" and the full schedule text.';
	}
	$c->render(json => $response);
}

# POST /manager/budget/payable/pay
sub action_22201 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $account = $c->param('account');
	my $bill = &subs::db_query("select * from warehouse where kind='money' and movement='payable' and uuid=? limit 1", $uuid)->hashes->[0];
	return $c->render(json => { error => &subs::ui('That bill was not found.') }) unless $bill;
	return $c->render(json => { error => &subs::ui('Choose an account to pay from.') }) unless $account && length $account;
	my $paid = &subs::db_query("select coalesce(sum(abs(cast(total as real))),0) as s from warehouse where kind='money' and movement='payment' and source_uuid=?", $uuid)->hashes->[0];
	my $paid_so_far = ($paid->{'s'} || 0) + 0;
	my $open = abs(($bill->{'total'} || 0) + 0) - $paid_so_far;
	return $c->render(json => { error => &subs::ui('That bill is already paid.') }) if $open <= 0.005;
	my $amount = &payable_amount($c->param('amount'));
	$amount = $open if $amount <= 0;
	$amount = $open if $amount > $open;
	my $date = $c->param('date');
	my $timestamp = length($date || '') ? (str2time($date) || 0) * 1000 : &subs::rightNow();
	$timestamp = &subs::rightNow() unless $timestamp;
	&subs::db_insert('warehouse', {
		kind => 'money',
		type => 'transaction',
		movement => 'payment',
		account => $account,
		app => ($bill->{'app'} || 'unknown'),
		vendor => ($bill->{'vendor'} || ''),
		item => ($bill->{'item'} || ''),
		amount => $amount * -1,
		total => $amount * -1,
		currency => ($bill->{'currency'} || &subs::setting_grabber({ app => $account, setting => 'currency' })),
		source_uuid => $uuid,
		uuid => &subs::random_string_creator(40),
		timestamp => $timestamp,
		server_time => &subs::rightNow()
	});
	$c->render(json => { ok => 1, payables => &accounting_payables(&subs::rightNow()), balance => &bank_ledger_balance($account, &subs::rightNow()) });
}

# POST /manager/budget/payable/delete
sub action_22236 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	return $c->render(json => { error => &subs::ui('That bill was not found.') }) unless $uuid && length $uuid;
	my $bill = &subs::db_query("select * from warehouse where kind='money' and movement='payable' and uuid=? limit 1", $uuid)->hashes->[0];
	# undoing a bill a notification made is also a decision that the notification
	# was not a bill, or the next read would book it again
	&payable_dismiss_add($bill->{'source_uuid'}) if $bill && substr($uuid,0,5) eq 'note-';
	&subs::db_query("delete from warehouse where kind='money' and movement='payment' and source_uuid=?", $uuid);
	&subs::db_query("delete from warehouse where kind='money' and movement='payable' and uuid=?", $uuid);
	$c->render(json => { ok => 1, payables => &accounting_payables(&subs::rightNow()) });
}

# POST /manager/budget/payable/schedule/delete
sub action_22249 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $list = &payable_schedules();
	@{$list} = grep { ($_->{'uuid'} || '') ne $uuid } @{$list};
	&payable_schedules_save($list);
	$c->render(json => { ok => 1, schedules => &payable_schedules() });
}

# POST /manager/budget/payable/schedule/toggle
sub action_22257 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $list = &payable_schedules();
	foreach my $s ( @{$list} ) {
		next unless ($s->{'uuid'} || '') eq $uuid;
		$s->{'active'} = (($s->{'active'} || 'on') eq 'off') ? 'on' : 'off';
	}
	&payable_schedules_save($list);
	$c->render(json => { ok => 1, schedules => &payable_schedules() });
}

# GET /manager/budget/current_information
sub action_22269 {
	my $c = shift;
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $circumstance = $c->param('circumstance');

	my $ci = &budget_current_information($app,$circumstance,$timestamp);

	$c->render(text => $ci->{'template'});
}

# GET /manager/budget/autocalc
sub action_22542 {
	my $c = shift;
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $circumstance = $c->param('circumstance');
	&subs::cache_delete({ app => $app, context => 'autocalc', subcontext => $circumstance });
	&subs::cache_delete({ app => $app, context => 'budget', subcontext => $circumstance });
	my $returner = &budget_autocalc({
		app => $app,
		circumstance => $circumstance,
	});
	$c->render(json => $returner );
}

1;
