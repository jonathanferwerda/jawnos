package Manager;

# manager_store: route actions moved out of Manager.pl, one sub per route so a
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

# GET /manager/store
sub action_5518 {
	my $c = shift;

	# The desk's opener sends window_maker=yes and store_maker returns the
	# window's contents. A browser opening this URL directly wants the Store
	# page, which /store already serves; without the flag store_maker renders
	# the page itself, and rendering again below left the response unfinished
	# (the request hung until the watchdog restarted the tree).
	return $c->redirect_to('/store') unless ($c->param('window_maker') || '') eq 'yes';

	my $timestamp = $c->param('timestamp');

	my $contents = &store_maker($c);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'store', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# GET /manager/store/custom_item/toggle
sub action_5955 {
	my $c = shift;
	my $type = $c->param('type');
	my $item = &subs::unformat_name($c->param('item'));
	my $item_categories = &subs::db_select('option_category', undef, { app => $item })->hashes;
	my $template = $c->render_to_string(
		template => 'store/custom_item_selection_input',
		item => $item,
		type => $type,
		item_categories => $item_categories
	);

	$c->render(json => { item => $item, type => $type, template => $template });
}

# POST /manager/store/custom_item/add
sub action_5969 {
	my $c = shift;
	my $item = &subs::unformat_name($c->param('item'));
	my $type = $c->param('type');
	my $name = &subs::unformat_name($c->param('name'));
	my $cost = $c->param('cost');
	$cost =~ s/[^0-9.]//gi;
	my $price = $c->param('price');
	$price =~ s/[^0-9.]//gi;
	my $tax = $c->param('tax');
	my $has_tax = $c->param('has_tax');
	my $description = $c->param('description');
	my $save_to_item = $c->param('save_to_item');
	my $uuid = &subs::random_string_creator(55);
	my $characteristics;
	if ($type eq 'option') {
		my $oc = &subs::db_select('option_category', undef, { uuid => $c->param('category'), app => $item })->hashes->[0];

		$characteristics = encode_json [{
			name => 'option_category',
			timestamp => &subs::rightNow(),
			uuid => &subs::random_string_creator(27),
			value => $oc->{'uuid'}
		}];
	}
	my $custom = {};
	if ($name) {
		$custom = {
			app => $item,
			name => $name,
			cost => $cost,
			price => $price,
			description => $description,
			uuid => $uuid,
			characteristics => $characteristics
		};
		if ($save_to_item eq 'on') {
			&subs::db_insert($type, $custom);
		}
	}

	&Websocket::send('tab', { console => &Websocket::console_command('registerGrabber', $item)});
	$c->render(json => $custom);
}

# GET /manager/store/customer_search
sub action_6013 {
	my $c = shift;
	my $search = $c->param('search');
	my $movement = $c->param('movement');
	if ($search) {
		my @search = split ' ', $search;
		my $s = join '%', @search;
		$search = '%' . $s . '%';

		my ($db) = &subs::database_grabber();
		my $results;
		if ($movement eq 'expense') {
			$results = &subs::db_query('select DISTINCT(app) from settings where app like ? and (setting=? or setting=?) and (value=? or value =? or value=? or value=? or value=? or value=?) LIMIT 20', $search,'pos','mab','vendor','vendor','person','government','institution','corporation')->hashes;
		}
		elsif ($movement eq 'income') {
			$results = &subs::db_query('select DISTINCT(app) from settings where app like ? and (setting=? or setting=?) and (value=? or value =? or value=? or value=? or value=? or value=?) LIMIT 20', $search,'pos','mab','vendor','customer','person','government','institution','corporation')->hashes;
		}
		foreach my $r ( @{$results} ) {
			$r->{'uuid'} = &subs::setting_grabber({ app => $r->{'app'}, setting => 'uuid' });
		}
		my $resulted = $c->render_to_string(template => 'search/customer', results => $results);
		$c->render(json => { results => $resulted, count => scalar @{$results} });
	}
	else {
		$c->render(json => { count => 0 });
	}
}

# GET /manager/store/customer_load
sub action_6041 {
	my $c = shift;
	my ($db) = &subs::database_grabber();
	my $cx = $c->param('cx');
	my $customer = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx })->hashes->[0];
	my $settings = &subs::settings_grabber({ app => $customer->{'app'} });
	my $content = $c->render_to_string(
		template => 'store/customer',
		cx => $cx,
		customer => $customer,
		settings => $settings,
	);
	$c->render(json => { content => $content, cx => $cx, formatted_name => &subs::format_name($customer->{'app'}), settings => $settings });
}

# GET /manager/store/customer_list
sub action_6378 {
	my $c = shift;
	my $cx = $c->param('cx');
	my $list_type = $c->param('list');
	my $type = $list_type;
	$type =~ s/s$//;
	my ($db) = &subs::database_grabber();
	my $customer = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx })->hashes->[0];
	if ($customer->{'app'}) {
		my $totals = {};
		my $settings = &subs::settings_grabber({ app => $customer->{'app'}});
		my $list = &subs::db_select('appointments', undef, { type => $type, app => $customer->{'app'} })->hashes;
		foreach my $l ( @{$list} ) {
			$l->{$type} = eval { return decode_json $l->{'data'} } || {};
			# A superseded invoice is shown as the reference, but the summary is
			# the live documents only.
			next if ($l->{'status'} || '') eq 'superseded';
			foreach my $number ( keys %{$l->{$type}->{'numbers'}} ) {
				$totals->{$number} += $l->{$type}->{'numbers'}->{$number};
			}
		}
		my $content = $c->render_to_string(
			template => 'store/list',
			list => $list,
			type => $type,
			settings => $settings,
			customer => $customer,
			totals => $totals
		);
		$c->render(json => { content => $content, cx => $cx, list => $list, settings => $settings });
	}
	else {
		$c->render(json => { content => 'no' });
	}
}

# GET /manager/store/customer_register
sub action_6410 {
	my $c = shift;
	my $cx = $c->param('cx');
	my $customer = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx })->hashes->[0];
	unless ($customer->{'app'}) {
		$c->render(json => { content => 'no' });
		return;
	}
	my $settings = &subs::settings_grabber({ app => $customer->{'app'} });
	my $rows = &subs::db_select('appointments', undef, { app => $customer->{'app'} })->hashes;
	my (@documents, %totals);
	$totals{'total'} = $totals{'paid'} = $totals{'balance'} = $totals{'count'} = 0;
	foreach my $r ( @{$rows} ) {
		next unless ($r->{'type'} || '') eq 'invoice' || ($r->{'type'} || '') eq 'sale';
		# A superseded invoice is the old copy of a revised one: it stays in the
		# invoice list as the reference, but it is not a second sale.
		next if ($r->{'status'} || '') eq 'superseded';
		my $d = eval { return decode_json $r->{'data'} } || {};
		my $n = $d->{'numbers'} || {};
		my $total = &subs::numeric_formatter($n->{'total'});
		my $balance = (defined $n->{'balance'} && $n->{'balance'} ne '') ? &subs::numeric_formatter($n->{'balance'}) : $total;
		$balance = 0 if $r->{'type'} eq 'sale';
		my $paid = $total - $balance;
		my @payments;
		foreach my $p ( @{ $d->{'payments'} || [] } ) {
			push @payments, {
				timestamp => &subs::numeric_formatter($p->{'timestamp'} || $p->{'server_time'} || 0),
				amount => &subs::numeric_formatter($p->{'amount'}),
				account => &subs::format_name($p->{'account'} || ''),
			};
		}
		@payments = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @payments;
		push @documents, {
			uuid => $r->{'uuid'},
			type => $r->{'type'},
			status => $r->{'status'},
			timestamp => &subs::numeric_formatter($r->{'timestamp'}),
			id => $d->{'id'} || '',
			item => &subs::store_document_item_label($d),
			total => $total,
			paid => $paid,
			balance => $balance,
			payments => \@payments,
		};
		$totals{'total'} += $total;
		$totals{'paid'} += $paid;
		$totals{'balance'} += $balance;
		$totals{'count'}++;
	}
	@documents = sort { $b->{'timestamp'} <=> $a->{'timestamp'} } @documents;
	my $content = $c->render_to_string(
		template => 'store/journal',
		documents => \@documents,
		totals => \%totals,
		customer => $customer,
		settings => $settings
	);
	$c->render(json => { content => $content, cx => $cx, count => scalar @documents });
}

# The cash register. An order lives in this worker's memory and is addressed by
# its own id, so nobody has to be a known customer and several people can be
# served at once. These helpers are not routes; the actions below answer with
# the same shape so the page can redraw from any reply.
sub store_register_customer_for {
	my ($cx) = @_;
	my $app = 'Customer';
	my $name = &subs::lang('common.customer');
	if (defined $cx && length $cx) {
		my $row = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx })->hashes->[0];
		if ($row && ($row->{'app'} || '') =~ /\S/) {
			$app = $row->{'app'};
			$name = &subs::format_name($app);
		}
	}
	my $tax_settings = &subs::store_tax_settings();
	my $tax_exemption = &subs::tax_exemption_for($app, $tax_settings->{'catalog'});
	return { app => $app, name => $name, cx => (defined $cx ? $cx : ''), tax_exemption => $tax_exemption };
}

sub store_register_payload {
	my ($order) = @_;
	my $settings = &subs::store_tax_settings();
	my $totals = &subs::store_register_totals($order->{'items'}, $settings);
	my $tax = 1;
	if ($settings->{'enabled'}) {
		my $entries = &subs::tax_entries_for_codes($settings->{'catalog'}, $settings->{'default_codes'});
		my $percent = 0;
		$percent += ($_->{'rate'} || 0) for @{$entries};
		$tax = 1 + ($percent / 100);
	}
	my $exemption = (ref $order->{'tax_exemption'} eq 'HASH')
		? $order->{'tax_exemption'}
		: &subs::tax_exemption_for(($order->{'customer'} || {})->{'app'} || 'Customer', $settings->{'catalog'});
	return {
		ok => 1,
		tax => 0 + $tax,
		tax_settings => $settings,
		tax_exemption => $exemption,
		cash_rounding => &subs::cash_rounding_setting(),
		order => { %{$order}, totals => $totals },
	};
}

# GET /manager/store/register
sub action_6411 {
	my $c = shift;
	my $cx = $c->param('cx') || '';
	my $content = $c->render_to_string(
		template => 'store/register',
		cx => $cx,
		webauthn_available => (scalar @{ &webauthn::credentials() } ? 1 : 0),
	);
	$c->render(json => { content => $content, cx => $cx });
}

# GET /manager/store/register/state
sub action_6412 {
	my $c = shift;
	my $settings = &subs::store_tax_settings();
	my $tax = 1;
	if ($settings->{'enabled'}) {
		my $entries = &subs::tax_entries_for_codes($settings->{'catalog'}, $settings->{'default_codes'});
		my $percent = 0;
		$percent += ($_->{'rate'} || 0) for @{$entries};
		$tax = 1 + ($percent / 100);
	}
	my @orders;
	foreach my $order ( @{ &subs::store_register_orders() } ) {
		push @orders, {
			%{$order},
			totals => &subs::store_register_totals($order->{'items'}, $settings),
		};
	}
	$c->render(json => {
		ok => 1,
		tax => 0 + $tax,
		tax_settings => $settings,
		cash_rounding => &subs::cash_rounding_setting(),
		orders => \@orders,
		methods => &subs::store_register_payment_methods(),
		denominations => &subs::store_register_denominations(),
	});
}

# POST /manager/store/register/order
sub action_6413 {
	my $c = shift;
	my $cx = $c->param('cx') || '';
	my $customer = &store_register_customer_for($cx);
	my $order = &subs::store_register_order_open({
		cx => $customer->{'cx'},
		app => $customer->{'app'},
		name => $customer->{'name'},
		tax_exemption => $customer->{'tax_exemption'},
	});
	return $c->render(json => { ok => 0, error => 'the order could not be opened' }) unless $order;
	$c->render(json => &store_register_payload($order));
}

# GET /manager/store/register/items
sub action_6414 {
	my $c = shift;
	no warnings 'once';
	my $search = &subs::unformat_name($c->param('search') || '');
	return $c->render(json => { ok => 1, items => [] }) if length($search) < 2;
	my $rows = &subs::db_query('select distinct(app) as app,* from settings where (setting= ? or setting = ?) and app like ? and device=?', 'pos', 'mab', '%' . $search . '%', $device)->hashes;
	my (%seen, @candidates);
	foreach my $type ( @gb::store_types ) {
		push @candidates, grep { ($_->{'value'} || '') eq $type && !$seen{ $_->{'app'} }++ } @{$rows};
	}
	my $items = &store_item_merchandiser(\@candidates, []);
	unless (($c->session('privilege') || '') eq 'citizen') {
		@{$items} = grep { (($_->{'settings'} || {})->{'public'} || '') eq 'on' } @{$items};
	}
	my @out;
	foreach my $item ( sort { lc($a->{'app'}) cmp lc($b->{'app'}) } @{$items} ) {
		last if scalar @out >= 30;
		push @out, {
			app => $item->{'app'},
			name => &subs::format_name($item->{'app'}),
			price => &subs::numeric_formatter($item->{'price'}),
			type => $item->{'type'} || 'product',
			tax_codes => &subs::tax_codes_value(($item->{'settings'} || {})->{'tax_codes'}),
		};
	}
	$c->render(json => { ok => 1, items => \@out });
}

# POST /manager/store/register/item
sub action_6415 {
	my $c = shift;
	my $id = $c->param('id');
	my $order = &subs::store_register_order($id);
	return $c->render(json => { ok => 0, error => 'no open order' }) unless $order;
	$order = &subs::store_register_order_add($id, {
		item => $c->param('item'),
		name => $c->param('name'),
		price => $c->param('price'),
		quantity => $c->param('quantity') || 1,
		tax_codes => $c->param('tax_codes'),
	});
	return $c->render(json => { ok => 0, error => 'the order could not be saved' }) unless $order;
	$c->render(json => &store_register_payload($order));
}

# POST /manager/store/register/quantity
sub action_6416 {
	my $c = shift;
	my $id = $c->param('id');
	my $order = &subs::store_register_order($id);
	return $c->render(json => { ok => 0, error => 'no open order' }) unless $order;
	$order = &subs::store_register_order_quantity($id, $c->param('line'), $c->param('quantity'));
	return $c->render(json => { ok => 0, error => 'the order could not be saved' }) unless $order;
	$c->render(json => &store_register_payload($order));
}

# POST /manager/store/register/remove
sub action_6417 {
	my $c = shift;
	my $id = $c->param('id');
	my $order = &subs::store_register_order($id);
	return $c->render(json => { ok => 0, error => 'no open order' }) unless $order;
	$order = &subs::store_register_order_remove($id, $c->param('line'));
	return $c->render(json => { ok => 0, error => 'the order could not be saved' }) unless $order;
	$c->render(json => &store_register_payload($order));
}

# POST /manager/store/register/cancel
sub action_6418 {
	my $c = shift;
	my $id = $c->param('id');
	my $cancelled = &subs::store_register_order_cancel($id);
	$c->render(json => { ok => $cancelled ? 1 : 0, cancelled => $id });
}

# POST /manager/store/register/sale
sub action_6419 {
	my $c = shift;
	my $id = $c->param('id');
	my $order = &subs::store_register_order($id);
	return $c->render(json => { ok => 0, error => 'no open order' }) unless $order;
	return $c->render(json => { ok => 0, error => 'the order is empty' }) unless scalar @{$order->{'items'}};
	my $tax_settings = &subs::store_tax_settings();
	my $app = $order->{'customer'}->{'app'} || 'Customer';
	# The customer's own exemption is the default; the till's toggle (and its
	# field) overrides it for this sale. Only an exempt sale records an id.
	my $exemption = &subs::tax_exemption_for($app, $tax_settings->{'catalog'});
	my $exempt_param = $c->param('tax_exempt');
	$exemption->{'exempt'} = ($exempt_param =~ /^(?:on|1|yes|true)$/i) ? 1 : 0
		if defined $exempt_param;
	my $exempt_id = $c->param('tax_exemption');
	$exemption->{'id'} = $exempt_id if defined $exempt_id && length $exempt_id;
	$exemption->{'id'} = '' unless $exemption->{'exempt'};
	my $built = &subs::store_register_sale_data($order, $c->param('payment'), $c->param('received'), $app, '', $tax_settings, $exemption);
	return $c->render(json => { ok => 0, error => $built->{'error'} || 'the sale could not be built' }) unless $built->{'ok'};
	if (($built->{'payment'}->{'method'} || '') eq 'cash' && $built->{'change'}->{'short'}) {
		return $c->render(json => { ok => 0, error => 'cash received is less than the total', short => 1, change => $built->{'change'} });
	}
	# A sale made at the counter belongs to the till that is open. With no shift
	# open the sale still records (a register that has never opened a drawer), and
	# data.register.shift_uuid simply stays absent; the house may refuse that by
	# turning store_shift_required on.
	my $shift = &subs::shift_current(&subs::device_setter());
	if (!$shift && &subs::store_shift_required() && ($built->{'payment'}->{'method'} || '') eq 'cash') {
		return $c->render(json => { ok => 0, error => 'no till is open; open a till first' });
	}
	$built->{'data'}->{'register'}->{'shift_uuid'} = $shift->{'uuid'} if $shift;
	my $minted = &subs::store_numbering_mint('invoice');
	return $c->render(json => { ok => 0, error => ($minted && $minted->{'error'}) || 'could not allocate an invoice number' })
		unless $minted && !$minted->{'error'} && defined $minted->{'id'};
	my $sale_id = $minted->{'id'};
	$built->{'data'}->{'id'} = $sale_id;
	my $appt = &appointment_writer($c, {
		app => $app,
		type => 'sale',
		movement => 'income',
		timestamp => &subs::rightNow(),
		duration => 0,
		data => encode_json($built->{'data'}),
		status => 'completed',
		item => $built->{'data'}->{'item'},
		taxes => encode_json($built->{'data'}->{'numbers'}->{'taxes'} || []),
		tax_exemption => $built->{'data'}->{'tax_exemption'} || '',
	});
	my $uuid = $appt->{'uuid'} || '';
	# A register sale is a payment too: the sale's own paper and a receipt are
	# stapled together on the receipt row, after the sale is written.
	if ($uuid && ref $built->{'data'}->{'payments'} eq 'ARRAY' && scalar @{$built->{'data'}->{'payments'}}) {
		unless (eval { &store_payment_receipt({ app => $app, uuid => $uuid, tx_app => $app, type => 'sale', payment => $built->{'data'}->{'payments'}->[0] }) }) {
			&subs::log_writer('receipt paper: ' . ($@ || 'the receipt was not written') . ' for ' . $app . ' ' . $uuid);
		}
	}
	&subs::store_register_order_cancel($id);
	my $receipt = '';
	if ($uuid) {
		my $printer = &store_printer({ type => 'sale', uuid => $uuid, customer_app => $app });
		$receipt = $c->render_to_string(%{$printer});
	}
	$c->render(json => {
		ok => 1,
		sale => {
			uuid => $uuid,
			id => $sale_id,
			app => $app,
			total => $built->{'totals'}->{'total'},
			payment => $built->{'payment'},
			items => $built->{'data'}->{'register'}->{'items'},
		},
		receipt => $receipt,
	});
}

# GET /manager/store/register/customer_search
# Names the house already knows, for the order in front of the counter. A
# customer is an app with a uuid settings row - the same row a person,
# corporation, vendor or institution is - so this searches every construct, not
# a separate customer table.
sub action_50201 {
	my $c = shift;
	my $search = &subs::unformat_name($c->param('search') || '');
	return $c->render(json => { ok => 1, customers => [] }) if length($search) < 2;
	my $rows = eval {
		&subs::db_query("select distinct app, value from settings where setting = 'uuid' and app like ? and app <> 'me' order by app limit 30", '%' . $search . '%')->hashes;
	} || [];
	my (%seen, @out);
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'} || '';
		my $cx = $row->{'value'} || '';
		next unless length $app && length $cx && !$seen{$app}++;
		push @out, { cx => $cx, app => $app, name => &subs::format_name($app) };
	}
	$c->render(json => { ok => 1, customers => \@out });
}

# POST /manager/store/register/customer
# Put a name on the order. An existing customer is named by their uuid (cx); a
# new one is a name and a kind, and the same settings row every construct has is
# written, so People, Configure and the rest of the house see them at once. A
# name that is already in use is refused rather than written twice: search finds
# the one that exists.
sub action_50202 {
	my $c = shift;
	no warnings 'once';
	my $id = $c->param('id');
	my $order = &subs::store_register_order($id);
	return $c->render(json => { ok => 0, error => 'no open order' }) unless $order;
	my $cx = $c->param('cx') || '';
	unless (length $cx) {
		my $name = &subs::unformat_name($c->param('name') || '');
		return $c->render(json => { ok => 0, error => 'a name is needed' }) unless length $name;
		return $c->render(json => { ok => 0, error => 'that name is too long' }) if length($name) > 100;
		my $kind = $c->param('kind') || 'person';
		my %known = map { $_->{'sing'} => 1 } values %{$gb::social_constructs};
		$kind = 'person' unless $known{$kind};
		my $exists = &subs::db_query('select 1 from settings where app = ? limit 1', $name)->hashes->[0];
		return $c->render(json => { ok => 0, error => 'that name is already in use; search for it instead' }) if $exists;
		my $now = &subs::rightNow();
		&subs::setting_initializer($name, $now);
		&subs::setting_setter({ app => $name, setting => 'pos', value => $kind, timestamp => $now });
		&people_link_sync() if $kind eq 'person';
		$cx = &subs::setting_grabber({ app => $name, setting => 'uuid' }) || '';
		return $c->render(json => { ok => 0, error => 'the customer could not be written' }) unless length $cx;
	}
	my $customer = &store_register_customer_for($cx);
	return $c->render(json => { ok => 0, error => 'that customer is not known' })
		unless ($customer->{'cx'} // '') eq $cx;
	# A tab is known by what identifies the order: the table when it is on the
	# floor, otherwise the customer's name. A walk-in keeps its Customer <n>.
	$customer->{'label'} = $customer->{'name'} unless length($order->{'seat'} // '');
	$order = &subs::store_register_order_customer($id, $customer);
	return $c->render(json => { ok => 0, error => 'the order could not be saved' }) unless $order;
	$c->render(json => &store_register_payload($order));
}

# GET /manager/store/register/floor
# The floor and the open orders in one answer: a seat is taken when an order
# names it, and the browser draws both from this.
sub action_50203 {
	my $c = shift;
	my $settings = &subs::store_tax_settings();
	my @orders;
	foreach my $order ( @{ &subs::store_register_orders() } ) {
		push @orders, {
			%{$order},
			totals => &subs::store_register_totals($order->{'items'}, $settings),
		};
	}
	$c->render(json => {
		ok => 1,
		floor => &subs::store_floorplan(),
		orders => \@orders,
		images => &subs::store_floorplan_images(),
	});
}

# POST /manager/store/register/floor/plan
# Save the room: the picture and the seats the editor placed on it. The picture
# is a data URI, resized by the editor before it is sent; a bigger one is
# refused rather than copied into every peer's snapshot.
sub action_50204 {
	my $c = shift;
	my $params = {};
	if (defined $c->param('name')) {
		$params->{'name'} = $c->param('name');
	}
	if (defined $c->param('image')) {
		my $image = $c->param('image') || '';
		return $c->render(json => { ok => 0, error => 'that picture is too large' }) if length($image) > 6_000_000;
		$params->{'image'} = $image;
	}
	if (defined $c->param('seats')) {
		my $seats = eval { decode_json($c->param('seats')) };
		return $c->render(json => { ok => 0, error => 'the seats could not be read' }) unless ref $seats eq 'ARRAY';
		$params->{'seats'} = $seats;
	}
	my $floor = &subs::store_floorplan_save($params);
	return $c->render(json => { ok => 0, error => 'the floor could not be saved' }) unless $floor;
	$c->render(json => { ok => 1, floor => $floor });
}

# POST /manager/store/register/floor/seat
# Sit an order at a seat, or take it off the floor. With no order named, one is
# opened first: a waiter taps an empty table and starts the order there, and the
# next tap on that table is the same order.
sub action_50205 {
	my $c = shift;
	my $seat = $c->param('seat') || '';
	my $floor = &subs::store_floorplan();
	my ($found) = grep { ($_->{'id'} // '') eq $seat } @{ $floor->{'seats'} || [] };
	return $c->render(json => { ok => 0, error => 'no such seat' }) if length $seat && !$found;
	my $id = $c->param('id') || '';
	my $order = length $id ? &subs::store_register_order($id) : undef;
	if (length $seat) {
		# A table holds one order. A tap that names no order on a taken table
		# answers with the order already there; naming another order at a taken
		# table is refused rather than writing a second order onto one seat.
		my ($taken) = grep { ($_->{'seat'} || '') eq $seat } @{ &subs::store_register_orders() };
		if ($taken && (!$order || ($taken->{'id'} || '') ne ($order->{'id'} || ''))) {
			return $c->render(json => { ok => 0, error => 'that table already has an order' }) if $order;
			$order = $taken;
		}
	}
	unless ($order) {
		my $customer = &store_register_customer_for($c->param('cx') || '');
		$order = &subs::store_register_order_open({
			cx => $customer->{'cx'},
			app => $customer->{'app'},
			name => $customer->{'name'},
			tax_exemption => $customer->{'tax_exemption'},
			label => ($found ? ($found->{'name'} || '') : ''),
			seat => $seat,
		});
		return $c->render(json => { ok => 0, error => 'the order could not be opened' }) unless $order;
	}
	$order = &subs::store_register_order_seat($order->{'id'}, $seat);
	return $c->render(json => { ok => 0, error => 'the order could not be saved' }) unless $order;
	$c->render(json => &store_register_payload($order));
}

# GET /manager/store/register/receipt
sub action_6420 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $app = $c->param('app');
	unless (defined $app && length $app) {
		my $row = &subs::db_select('appointments', undef, { uuid => $uuid, type => 'sale' })->hashes->[0];
		$app = $row->{'app'} if $row;
	}
	unless (defined $app && length $app) {
		return $c->render(text => 'no receipt', status => 404);
	}
	my $printer = &store_printer({ type => 'sale', uuid => $uuid, customer_app => $app });
	$c->render(text => $c->render_to_string(%{$printer}));
}

# POST /manager/store/shift/open
# The drawer is opened with a float and the associate working it. A person who
# unlocked the till on this screen is the associate; a typed name is still the
# fallback for a shop that has not set a PIN or written a tag.
sub action_6979 {
	my $c = shift;
	my $unlock = &subs::till_unlock_current($c);
	my $associate = $c->param('associate') // '';
	$associate =~ s/^\s+|\s+$//g;
	my $associate_uuid = '';
	if ($unlock) {
		$associate = $unlock->{'name'} // '';
		$associate_uuid = $unlock->{'person_uuid'} // '';
	}
	elsif (length $associate) {
		my $person = &subs::till_person_find($associate);
		$associate_uuid = $person->{'uuid'} if ref $person eq 'HASH' && length($person->{'uuid'} // '');
	}
	my $opened = &subs::shift_open({
		associate => $associate,
		associate_uuid => $associate_uuid,
		float => $c->param('float'),
		device => &subs::device_setter(),
	});
	return $c->render(json => { ok => 0, error => $opened->{'error'} || 'the till could not be opened' })
		unless $opened->{'ok'};
	$c->render(json => {
		ok => 1,
		shift => $opened->{'shift'},
		report => &subs::shift_report($opened->{'shift'}),
	});
}

# POST /manager/store/shift/close
# End of day: count the drawer, record the over or short, and lock the shift. A
# shift opened for a known person is closed only by that person's live unlock;
# the closer's own name is recorded either way.
sub action_6980 {
	my $c = shift;
	my $shift = &subs::shift_current(&subs::device_setter());
	return $c->render(json => { ok => 0, error => 'no till is open' }) unless $shift;
	my $unlock = &subs::till_unlock_current($c);
	# A citizen is the house's own hand: it may count and close a till whose
	# associate has gone home, and the report says who closed it. A resident
	# still needs the associate's own live unlock.
	my $override = (($c->session('privilege') || '') eq 'citizen');
	if (length($shift->{'associate_uuid'} // '') && !$override) {
		my $same = $unlock && ($unlock->{'person_uuid'} // '') eq $shift->{'associate_uuid'};
		return $c->render(json => {
			ok => 0,
			need_unlock => 1,
			error => 'this is ' . ($shift->{'associate'} || 'the associate') . "'s till - unlock as that person to close it",
		}) unless $same;
	}
	my $closer = $unlock
		? { name => $unlock->{'name'}, uuid => $unlock->{'person_uuid'} }
		: $override
		? { name => ($c->session('name') || 'the owner'), uuid => ($c->session('person_uuid') || '') }
		: undef;
	my $closed = &subs::shift_close($shift->{'uuid'}, $c->param('counted'), $c->param('notes'), $closer);
	return $c->render(json => { ok => 0, error => $closed->{'error'} || 'the till could not be closed' })
		unless $closed->{'ok'};
	$c->render(json => {
		ok => 1,
		shift => $closed->{'shift'},
		report => $closed->{'report'},
	});
}

# GET /manager/store/shift
# What the till bar draws: the current shift, what the drawer should hold,
# whether the house insists on an open till for a cash sale, and the person
# whose unlock is still live.
sub action_6981 {
	my $c = shift;
	my $shift = &subs::shift_current(&subs::device_setter());
	$c->render(json => {
		ok => 1,
		shift => $shift,
		report => $shift ? &subs::shift_report($shift) : undef,
		required => &subs::store_shift_required(),
		unlock => &subs::till_unlock_current($c),
	});
}

# POST /manager/store/shift/unlock
# The person at the drawer proves who they are before the till is opened or
# closed. A PIN names the person it belongs to; a tag token and a passkey name
# their own. The answer is a fifteen-minute unlock in the session, not a login.
sub action_6982 {
	my $c = shift;
	my $method = lc($c->param('method') // '');
	my $secret = $c->param('secret') // '';
	my $checked;
	if ($method eq 'pin') {
		my $person = &subs::till_person_find($c->param('associate'));
		return $c->render(json => { ok => 0, error => 'choose the person whose PIN it is' }) unless $person;
		$checked = &subs::till_pin_check($person->{'uuid'}, $secret);
	}
	elsif ($method eq 'token') {
		$checked = &subs::till_token_check($secret);
	}
	elsif ($method eq 'webauthn') {
		my $id = $c->param('id') // '';
		my $cred = &webauthn::credential_by_id($id);
		return $c->render(json => { ok => 0, error => 'no such passkey' }) unless $cred;
		my $cd = $c->param('client_data') // '';
		my $jd = eval { decode_json(&webauthn::b64u_decode($cd)) } || {};
		my $challenge = $jd->{'challenge'} // '';
		my $payload = &webauthn::challenge_take('login', $challenge);
		return $c->render(json => { ok => 0, error => 'the challenge expired - try again' }) unless $payload;
		my ($res, $err) = &webauthn::verify_assertion(
			$cred, $cd, $c->param('auth_data'), $c->param('signature'),
			$challenge, &webauthn::origin_of($c)
		);
		return $c->render(json => { ok => 0, error => $err }) unless $res;
		my $list = &webauthn::credentials();
		foreach my $row ( @{$list} ) {
			next unless ($row->{'id'} || '') eq $id;
			$row->{'sign_count'} = $res->{'sign_count'};
			$row->{'last_used'} = &subs::rightNow();
		}
		&webauthn::credentials_store($list);
		my $active = eval { &subs::db_select('people', undef, { uuid => $cred->{'person_uuid'}, status => 'active' })->hash };
		$checked = ($active && length($active->{'uuid'} // ''))
			? { ok => 1, person => { uuid => $active->{'uuid'}, name => $active->{'name'} // '' } }
			: { ok => 0, error => 'that passkey is not linked to an active person' };
	}
	else {
		return $c->render(json => { ok => 0, error => 'choose PIN, tag or passkey' });
	}
	return $c->render(json => { ok => 0, error => $checked->{'error'} || 'that did not unlock the till' })
		unless $checked->{'ok'};
	my $unlock = &subs::till_unlock_store($c, $checked->{'person'});
	return $c->render(json => { ok => 0, error => 'the unlock could not be kept' }) unless $unlock;
	$c->render(json => {
		ok => 1,
		method => $method,
		person => $checked->{'person'},
		expires => $unlock->{'expires'},
	});
}

# A peer asks the numbering authority for the next document number. The hub
# owns the counter; a machine that is not the hub reaches this over the signed
# relay rail (see subs::store_numbering_relay). A house session may also call
# it when the hub is opened locally.
# POST /manager/store/number_mint
sub action_6421 {
	my $c = shift;
	unless ((&subs::device_setter() // '') eq 'server') {
		return $c->render(json => { ok => 0, error => 'this machine is not the numbering authority' });
	}
	my $signatorial = $c->param('signatorial') || '';
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ((($c->session('authentication') || '') eq 'approved'
		&& !&subs::guest_browser_session($c->session('privilege'), $c->session('source')))
		|| ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted'))) {
		return $c->render(json => { ok => 0, error => 'not allowed' });
	}
	my $minted = &subs::store_numbering_mint_local($c->param('series'));
	return $c->render(json => { ok => 0, error => 'the series is not ready' }) unless $minted && defined $minted->{'number'};
	$c->render(json => {
		ok => 1,
		series => $minted->{'series'},
		number => $minted->{'number'},
		id => $minted->{'id'},
	});
}

# A device reserves a block of numbers for use when it cannot reach the hub.
# The counter advances by the whole block, so no other machine can be given a
# number in it; the device owns the block row and records how far it has used.
# POST /manager/store/number_block
sub action_6422 {
	my $c = shift;
	unless ((&subs::device_setter() // '') eq 'server') {
		return $c->render(json => { ok => 0, error => 'this machine is not the numbering authority' });
	}
	my $signatorial = $c->param('signatorial') || '';
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ((($c->session('authentication') || '') eq 'approved'
		&& !&subs::guest_browser_session($c->session('privilege'), $c->session('source')))
		|| ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted'))) {
		return $c->render(json => { ok => 0, error => 'not allowed' });
	}
	my $block = &subs::store_numbering_block_reserve_local($c->param('series'), $c->param('device') || $signatorial, $c->param('size'));
	return $c->render(json => { ok => 0, error => 'the series is not ready' }) unless $block;
	$c->render(json => { ok => 1, %{$block} });
}

# POST /manager/store/number_reserve
# The Configure -> Store card's one action: ask the hub for a fresh block of
# offline numbers for this device. The hub itself mints every number and has
# nothing to reserve, so it is simply reported as the authority.
sub action_6423 {
	my $c = shift;
	unless ((($c->session('authentication') || '') eq 'approved'
		&& !&subs::guest_browser_session($c->session('privilege'), $c->session('source')))) {
		return $c->render(json => { ok => 0, error => 'not allowed' });
	}
	my $status = &subs::store_numbering_status() || { series => {} };
	my $authority = $status->{'authority'} ? 1 : 0;
	my ($invoice_ok, $quote_ok) = (1, 1);
	unless ($authority) {
		$invoice_ok = &subs::store_numbering_block_ensure('invoice') ? 1 : 0;
		$quote_ok = &subs::store_numbering_block_ensure('quote') ? 1 : 0;
	}
	my $after = &subs::store_numbering_status() || $status;
	my $inv_left = ($after->{'series'}->{'invoice'}->{'remaining'} || 0) + 0;
	my $quo_left = ($after->{'series'}->{'quote'}->{'remaining'} || 0) + 0;
	my $error = '';
	if (!$authority && ((!$invoice_ok && !$inv_left) || (!$quote_ok && !$quo_left))) {
		$error = 'the numbering hub could not be reached';
	}
	$c->render(json => {
		ok => ($error ? 0 : 1),
		error => $error,
		authority => $authority,
		invoice => $after->{'series'}->{'invoice'} || {},
		quote => $after->{'series'}->{'quote'} || {},
		hub => $after->{'hub'} || '',
	});
}

# GET /manager/store/customer_correspondence
sub action_6466 {
	my $c = shift;
	# A journal of the mail and chat this customer and the house exchanged. The
	# store's customer bar is a citizen's desk, so the vault key is available.
	unless (($c->session('privilege') || '') eq 'citizen') {
		$c->render(json => { content => 'no' });
		return;
	}
	my $cx = $c->param('cx');
	my $customer = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx })->hashes->[0];
	unless ($customer->{'app'}) {
		$c->render(json => { content => 'no' });
		return;
	}
	my $app = $customer->{'app'};
	my $settings = &subs::settings_grabber({ app => $app });

	my %seen_id;
	my @contacts = grep { defined && length && !$seen_id{$_}++ } ($cx, $app, $settings->{'uuid'});
	my $tickets = &subs::db_query('select uuid from tickets where app=? or name=?', $app, $app)->hashes;
	foreach my $t ( @{$tickets} ) {
		push @contacts, $t->{'uuid'} if $t->{'uuid'} && !$seen_id{ $t->{'uuid'} }++;
	}
	my $email_lines = &subs::contact_lines('email', $app);
	my @emails = grep { defined && length } map { $_->{'value'} } @{ $email_lines->{$app} || [] };
	my $phone_lines = &subs::contact_lines('phone', $app);
	my @phones = grep { defined && length } map { &subs::contact_normalizer('phone', $_->{'value'}) } @{ $phone_lines->{$app} || [] };

	my (@where, @args);
	foreach my $value ( @contacts ) {
		push @where, 'contact = ?';
		push @args, $value;
	}
	push @where, 'person = ?';
	push @args, $app;
	if (scalar @emails) {
		push @where, 'email in (' . join(',', map { '?' } @emails) . ')';
		push @args, @emails;
	}
	if (scalar @phones) {
		push @where, 'phone in (' . join(',', map { '?' } @phones) . ')';
		push @args, @phones;
	}

	my $rows = [];
	if (scalar @where) {
		my $sql = 'select * from mailbox where (' . join(' or ', @where) . ") and coalesce(status, '') != 'ignored' order by timestamp desc limit 300";
		$rows = &subs::db_query($sql, @args)->hashes;
	}
	my $suds = &subs::session_suds($c) || &subs::suds_grabber();
	my %counts = (email => 0, chat => 0);
	my $last = 0;
	my $message_index = 0;
	foreach my $m ( @{$rows} ) {
		$message_index++;
		my $channel = $m->{'email'} ? 'email' : ($m->{'phone'} ? 'chat' : 'mail');
		$counts{$channel}++ if exists $counts{$channel};
		my $direction = (($m->{'status'} || '') =~ /^(sent|outbox|draft)$/) ? 'out' : 'in';
		my $subject = $m->{'subject'} || '';
		if ($subject && $suds) {
			$subject = &subs::note_decrypter($suds, $subject, $m->{'ost'}) || '';
		}
		my $body = $m->{'body'} || '';
		if ($body && $suds) {
			$body = &subs::note_decrypter($suds, $body, $m->{'ost'}) || '';
		}
		$subject =~ s/<[^>]+>/ /g;
		$body =~ s/<[^>]+>/ /g;
		$subject =~ s/\s+/ /g;
		$body =~ s/\s+/ /g;
		$subject =~ s/^\s+|\s+$//g;
		$body =~ s/^\s+|\s+$//g;
		my $preview = length($body) > 220 ? substr($body, 0, 220) . '…' : $body;
		$subject = substr($body, 0, 70) . (length($body) > 70 ? '…' : '') if $subject eq '' && $channel eq 'chat';
		my ($from, $to);
		if ($channel eq 'chat') {
			$from = $direction eq 'in' ? ($m->{'phone'} || '') : ($settings->{'phone'} || '');
			$to = $direction eq 'in' ? ($settings->{'phone'} || '') : ($m->{'phone'} || '');
		}
		else {
			$from = $direction eq 'in' ? ($m->{'email'} || $m->{'phone'} || '') : ($settings->{'email'} || $settings->{'phone'} || '');
			$to = $direction eq 'in' ? ($settings->{'email'} || $settings->{'phone'} || '') : ($m->{'email'} || $m->{'phone'} || '');
		}
		# The reader gets every preview. The full text rides along for the newest
		# messages only, so a mailbox of years does not become a page of megabytes.
		my $body_text = $message_index > 60 ? '' : $body;
		$body_text = substr($body_text, 0, 4000) . '…' if length($body_text) > 4000;
		$m->{'channel'} = $channel;
		$m->{'direction'} = $direction;
		$m->{'subject_text'} = $subject;
		$m->{'body_text'} = $body_text;
		$m->{'preview'} = $preview;
		$m->{'from_text'} = $from;
		$m->{'to_text'} = $to;
		$last = $m->{'timestamp'} if ($m->{'timestamp'} || 0) > $last;
	}
	my $content = $c->render_to_string(
		template => 'store/correspondence',
		messages => $rows,
		customer => $customer,
		settings => $settings,
		counts => \%counts,
		last => $last
	);
	$c->render(json => { content => $content, cx => $cx, count => scalar @{$rows} });
}

# POST /manager/store/:att/save
sub action_6625 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $name = &subs::unformat_name($c->param('name'));
	my $att = $c->stash('att');
	my $cost = $c->param('cost');
	my $price = $c->param('price');
	my $uuid = $c->param('uuid');
	my $timestamp = $c->param('timestamp');
	my $discount = $c->param('discount');
	my $unit = $c->param('unit') || $name;
	my $markup = $c->param('markup');
	my $category = $c->param('category');
	my $description = $c->param('description');
	my $manufacturer = $c->param('manufacturer');
	my $def = $c->param('def');
	my $def_month = $c->param('def_month');
	my $def_day = $c->param('def_day');
	my $def_hour = $c->param('def_hour');
	my $def_wday = $c->param('def_wday');
	my $save_app = $c->param('save_app');
	my $quantity = $c->param('quantity');
	my $delay_start = $c->param('delay_start');
	my $delay_stop = $c->param('delay_stop');
	my $option_category = $c->param('option_category') || '';

	if ($quantity =~ /[a-zA-Z]/) {
		my $gunit = $quantity;
		$gunit =~ s/[^a-zA-Z]//gi;
		$unit = $gunit if grep { $_ eq $gunit } keys %{$gb::measures};
		$quantity =~ s/[^0-9.]//gi;
	}

	# A catalogue row is named by its uuid, and the sync rail merges by uuid, so
	# two rows with the same key never join on their own. Register's Add used to
	# mint a fresh uuid on every press, which is how one entry came to be listed
	# twice. Adding a key the catalogue already holds is that row, not a twin: the
	# reply names it and leaves it alone. A model's key is app + name; an option's
	# is app + name + option category, because the same option name in two
	# categories is a real pair.
	my $duplicate;
	if ($uuid eq 'new' && $att eq 'model' && length $name) {
		my $existing = &subs::db_query(
			'select uuid from model where app = ? and name = ? order by cast(ost as integer) desc, rowid desc limit 1',
			$app, $name
		)->hashes;
		$duplicate = $existing->[0] if scalar @{$existing};
	}
	elsif ($uuid eq 'new' && $att eq 'option' && length $name) {
		my $existing = &subs::db_query(
			'select uuid, characteristics from option where app = ? and name = ? order by cast(ost as integer) desc, rowid desc',
			$app, $name
		)->hashes;
		foreach my $row ( @{$existing} ) {
			my $chars = eval { return decode_json($row->{'characteristics'} // '') } || [];
			my ($have) = map { $_->{'value'} } grep { ref $_ eq 'HASH' && ($_->{'name'} // '') eq 'option_category' } @{$chars};
			$have = '' unless defined $have;
			next unless $have eq $option_category;
			$duplicate = $row;
			last;
		}
	}

	if ($uuid ne 'new') {
		if ($def eq 'on' && $att eq 'model') {
#			&subs::db_update($att, { def => 'off' }, { app => $app })->hashes;
		}
	}

	my $server_time = &subs::rightNow();
	my $returner = {
		app => $app,
		name => $name,
		cost => $cost,
		price => $price,
		discount => $discount,
		markup => $markup,
		description => $description,
		uuid => ($duplicate ? $duplicate->{'uuid'} : &subs::random_string_creator(50)),
		timestamp => $timestamp,
		server_time => $server_time,
		manufacturer => $manufacturer,
		def => $def,
		def_month => $def_month,
		def_day => $def_day,
		def_hour => $def_hour,
		def_wday => $def_wday,
		save_app => $save_app,
		quantity => $quantity,
		unit => $unit,
		delay_start => $delay_start,
		delay_stop => $delay_stop
	};


	$returner->{'category'} = $category if $att eq 'option_category' || $att eq	'subcategory';
	# A new option carries the category chosen beside its name in the same press.
	# Once the row exists the category is set by the characteristic setter, as
	# before; the Add is where the key is decided, so the duplicate check above can
	# see it.
	if ($uuid eq 'new' && $att eq 'option' && length $option_category) {
		$returner->{'characteristics'} = encode_json([ {
			name => 'option_category',
			value => $option_category,
			timestamp => ($timestamp || &subs::rightNow()),
			uuid => &subs::random_string_creator(27),
		} ]);
	}
	if ($uuid eq 'new') {
		if ($duplicate) {
			$returner->{'duplicate'} = 1;
		}
		else {
			&subs::db_insert($att, $returner);
		}
	}
	else {
		$returner->{'uuid'} = $uuid;
		&subs::db_update($att, $returner, { uuid => $uuid });
	}
	# A model is one choice. The panel cleared the other checkboxes in the
	# browser only, so every model that had ever been set default stayed def='on'
	# in the database; with several defaults, which one a press started followed
	# the row order of whichever machine merged first. Clear the others here,
	# where the choice is actually written. Options may keep more than one
	# default (honey with milk), so they are left alone.
	if ($att eq 'model' && ($def // '') eq 'on' && length $app) {
		my $others = &subs::db_select('model', ['uuid'], { app => $app, def => 'on' })->hashes || [];
		foreach my $other ( @{$others} ) {
			next if ($other->{'uuid'} // '') eq ($returner->{'uuid'} // '');
			&subs::db_update('model', { def => 'off', server_time => $server_time }, { uuid => $other->{'uuid'}, app => $app });
		}
	}

	my $attd = $att;
	$attd = s/_//gi;

	$returner->{'template'} = $c->render_to_string(template => 'pos/attributes', att => $att, app => $app);
	$c->render(json => $returner);
}

# POST /manager/store/attribute_characteristic_setter
sub action_6809 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $att = &subs::unformat_name($c->param('att'));
	my $app = $c->param('app');
	my $att_uuid = $c->param('att_uuid');
	my $uuid = $c->param('uuid');
	my $input = $c->param('input');
	my $value = $c->param('value');
	my $unit;
	if ($value =~ /[a-zA-Z0-9]/) {
		my $gunit = $value;
		$gunit =~ s/[^a-zA-Z]//gi;
		if (grep { $_ eq $gunit } keys %{$gb::measures}) {
			$unit = $gunit;
			$value =~ s/[^0-9.]//gi;
		}
	}



	my $type = $c->param('type');
	my ($db,$database) = &subs::database_grabber();
	my $attributes = &subs::db_select($att, ['uuid','characteristics',], { uuid => $att_uuid })->hashes;
	my $attr = $attributes->[0];
	my $chars = eval { return decode_json $attr->{'characteristics'} } || [];

	my $data = {
		uuid => &subs::random_string_creator(25),
		$input => $value,
		timestamp => $timestamp
	};



	if ($type eq 'select') {
		$data = {
			name => $input,
			value => $value,
			timestamp => $timestamp,
			uuid => $uuid
		};
		if ($uuid eq 'new') {
			my $measurement = $value;
			$measurement =~ s/[0-9.,-]//gi;
			$data->{'uuid'} = &subs::random_string_creator(25);

		}
		else {
			@{$chars} = grep { $_->{'uuid'} ne $uuid } @{$chars};

		}
	}
	elsif ($uuid eq 'new') {
	}
	else {
		my @cdata = grep { $_->{'uuid'} eq $uuid } @{$chars};
		@{$chars} = grep { $_->{'uuid'} ne $uuid } @{$chars};
		$cdata[0]->{$input} = $value;
		$cdata[0]->{'timestamp'} = $timestamp;
		$data = $cdata[0];
		$data->{'unit'} = $unit if $unit;
	}
	unshift @{$chars}, $data;
	my $json_chars = encode_json $chars;
	&subs::db_update($att, { characteristics => $json_chars }, { uuid => $att_uuid });
	$c->render(json => { template => $c->render_to_string(template => 'pos/attributes', att => $att, app => $app), attribute => $data });

}

# POST /manager/store/characteristic_delete
sub action_6878 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $att_uuid = $c->param('att_uuid');
	my $att = $c->param('att');

	my ($db) = &subs::database_grabber();
	my $attribute = &subs::db_select($att, undef, { uuid => $att_uuid })->hashes->[0];
	my $chars = eval { return decode_json $attribute->{'characteristics'} } || [];
	@{$chars} = grep { $_->{'uuid'} ne $uuid } @{$chars};
	my $json_chars = encode_json $chars;
	&subs::db_update($att, { characteristics => $json_chars }, { uuid => $att_uuid });
	$c->render(json => { uuid => $uuid });

}

# POST /manager/store/attribute_delete
sub action_6893 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $att = $c->param('att');
	my ($db,$database) = &subs::database_grabber();
	# A catalogue row is deleted just like an appointment: the tombstone is what
	# stops a peer that still holds the row from handing it back on the next pull.
	# Without it the deleted model or option reappeared (and with it a default the
	# person had already removed). Read the row first, since the delete is what
	# the tombstone describes.
	my $original = &subs::db_select($att, undef, { uuid => $uuid })->hashes->[0];
	&subs::db_delete($att, { uuid => $uuid });
	&deletion_registration({ table => $att, uuid => $uuid, scope => 'single', server_time => ($original ? $original->{'server_time'} : &subs::rightNow()) }) if $original;
	$c->render('text' => 'ok');
}

# POST /manager/store/appointment_model_migration
sub action_6901 {
	my $c = shift;
	my $att = $c->param('att');
	my $matt = $c->param('matt');
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');

	my $original = &subs::db_select($att, undef, { app => $app, uuid => $uuid })->hashes->[0];

	&subs::db_delete($att, { app => $app, uuid => $uuid });
	&deletion_registration({ table => $att, uuid => $uuid, server_time => $original->{'server_time'} });

	$original->{'server_time'} = &subs::rightNow();
	&subs::db_insert($matt, $original);
	my $returner = &register_grabber($app);

	$c->render(json => $returner);
}

# POST /manager/store/appointment_model_selector
sub action_6919 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $appt_uuid = $c->param('appt_uuid');
	my $server_time = &subs::rightNow();
	my $quantity = $c->param('quantity');
	my $manufacturer = $c->param('manufacturer');
	my $unit = $c->param('unit');
	my $source = $c->param('source');
	if ($quantity =~ /[a-zA-Z]/) {
		my $gunit = $quantity;
		$gunit =~ s/[^a-zA-Z]//gi;
		$unit = $gunit if grep { $_ eq $gunit } keys %{$gb::measures};
		$quantity =~ s/[^0-9.]//gi;
	}

	my $app = $c->param('app');

	my $appt = &subs::db_query('select * from appointments where uuid=? and app =?', $appt_uuid, $app)->hashes->[0];

	my $cause = $c->param('cause');
	my $existing_model = eval { return decode_json $appt->{'model'} } || {};

	my $m = &subs::db_select('model', undef, { uuid => $uuid })->hashes->[0];
	if ($cause eq 'model') {
		$quantity = $m->{'quantity'};
		$unit = $m->{'unit'};
	}
	my $model = encode_json { uuid => $m->{'uuid'}, timestamp => $timestamp, quantity => ( $quantity), name => $m->{'name'}, unit => ( $unit) };
	if ($source ne 'transaction') {
		if ($existing_model->{'uuid'}) {

			my $del = &subs::db_select('appointments', undef, { source_uuid => $appt->{'uuid'}, app => $existing_model->{'name'} })->hashes;
			foreach my $d ( @{$del} ) {
				&delete_app($d->{'app'},$d->{'uuid'},$d->{'server_time'},'appointment_model_selector');
			}
		}
		if ( $m->{'save_app'} eq 'on') {
			&subs::source_appt_writer($m, {
				app => $appt->{'app'},
				uuid => $appt->{'uuid'},
				type => $appt->{'type'},
				duration => $appt->{'duration'},
				timestamp => $appt->{'timestamp'},
				unit => $unit,
				quantity => $quantity,
				project => $appt->{'project'},
				manufacturer => $manufacturer
			}, 'model');
		}
		$manufacturer = $m->{'manufacturer'} unless $manufacturer;

#		&subs::db_query('update appointments set server_time = ?, model=?, manufacturer=?, quantity=?, unit=? where uuid=?',$server_time,$model,$manufacturer,$quantity,$unit,$appt_uuid);
		&subs::db_update('appointments', { server_time => &subs::rightNow(), model => $model, manufacturer => $manufacturer, quantity => $quantity, unit => $unit }, { uuid => $appt_uuid, app => $appt->{'app'} });
		&Websocket::send($app, { console => &Websocket::console_command('appointmentDetailGrabber', $appt->{'app'}, $appt->{'uuid'})});
	}
	$c->render(json => $model);
}

1;
