package Manager;

# manager_transaction2: route actions moved out of Manager.pl, one sub per route so a
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

# POST /manager/transaction/record
sub action_16986 {
	my $c = shift;
	my ($db,$database,$sql) = &subs::database_grabber();

	my $app = &subs::unformat_name($c->param('app'));
	my $account = $c->param('account');
	my $project = $c->param('project');

	my $timestamp = &timestamp_adjuster($c);

	my $server_time = &subs::rightNow();
	my $duration = &duration_read($c->param('duration'));
	$duration = 5000 unless defined $duration;
	my $notes = &subs::note_encrypter(&subs::session_suds($c),$c->param('notes'));
	my $movement = $c->param('movement');
	my $transaction_information = $c->param('transaction_information');
	my $warranty = &warranty_resolve($c->param('warranty'), $timestamp, 1);
	$warranty = &subs::ago_calc('-7y', $timestamp) unless defined $warranty;

	my $uuid = &subs::random_string_creator(40);
	my $currency = $c->param('currency') || &subs::setting_grabber({ app => $app, setting => 'currency' });


	my $has_totes = $c->param('has_totes');
	my $has_tax = $c->param('has_tax');
	my $manufacturer = &subs::unformat_name($c->param('manufacturer'));
	my $vendor = &subs::unformat_name($c->param('vendor'));
	my $record_vendor = $c->param('record_vendor');
	my $unit = $c->param('unit');
	my $amount = $c->param('amount');
	my $tax = $c->param('tax');
	my $aux = $c->param('aux');
	my $aux_description = $c->param('aux_description');
	my $total = $c->param('total');
	my $item = &subs::unformat_name($c->param('item'));
	my $state = $c->param('state');
	my $quantity = $c->param('quantity');
	my $model = &subs::db_query('select * from model where uuid=?',$c->param('model'))->hashes->[0];
	my $transfer_amount = $c->param('transfer_amount');
	my $to_account = $c->param('to_account');
	my $jtransactions = $c->param('transactions');
	my $transactions = eval { return decode_json $c->param('transactions') } || {};

	# A transfer needs both ends and one figure. An empty amount used to write two
	# zero-value legs, and a destination equal to the source moved money in a
	# circle; say so before anything values or records the move.
	if ($movement eq 'transfer') {
		$transfer_amount = &subs::numeric_formatter($transfer_amount) + 0;
		if (!$transfer_amount) {
			$c->render(json => { error => &subs::ui('Enter the amount to transfer.') });
			return;
		}
		if (!defined $to_account || $to_account eq '' || $to_account eq $account) {
			$c->render(json => { error => &subs::ui('Choose a different account to receive the transfer.') });
			return;
		}
		$transfer_amount = abs($transfer_amount);
	}

	# ---- crypto wallets -----------------------------------------------------
	# A wallet account is read in its own coin: every figure on the form is a
	# native amount, so it is converted at the cached snapshot rate and the
	# native amount is kept beside the money value. The ledger itself stays in
	# the reporting currency, which is exactly what the statements, budgets and
	# account balances already sum - so no report has to learn about coins.
	my $wallet_asset = &subs::crypto_account_asset($account);
	if ($wallet_asset && ($movement eq 'income' || $movement eq 'expense')) {
		my $rate = &subs::crypto_rate($wallet_asset);
		if (!defined $rate) {
			$c->render(json => { error => 'No ' . $wallet_asset . ' rate is loaded yet. Refresh the rates in Configure -> Plat -> Crypto, then record this again.' });
			return;
		}
		my $native = &subs::crypto_amount_number($total, $wallet_asset);
		$native = &subs::crypto_amount_number($amount, $wallet_asset) unless defined $native;
		if (defined $native) {
			$transactions->{'crypto'} = {
				asset => $wallet_asset,
				amount => $native,
				rate => $rate,
				rate_at => &subs::rightNow(),
				value => &subs::crypto_value($native, $wallet_asset),
			};
			foreach my $ref ( \$amount, \$tax, \$aux, \$total ) {
				my $n = &subs::crypto_amount_number(${$ref}, $wallet_asset);
				${$ref} = &subs::crypto_value($n, $wallet_asset) if defined $n;
			}
			if (ref $transactions->{$movement} eq 'HASH') {
				foreach my $key ( keys %{ $transactions->{$movement} } ) {
					my $line = $transactions->{$movement}->{$key};
					next unless ref $line eq 'HASH';
					foreach my $f ( qw/amount tax aux total/ ) {
						next unless defined $line->{$f} && $line->{$f} ne '';
						my $n = &subs::crypto_amount_number($line->{$f}, $wallet_asset);
						$line->{$f} = &subs::crypto_value($n, $wallet_asset) if defined $n;
					}
				}
			}
			$jtransactions = encode_json $transactions;
		}
	}
	if ($movement eq 'transfer') {
		my $from_asset = &subs::crypto_account_asset($account);
		my $to_asset = &subs::crypto_account_asset($to_account);
		if ($from_asset || $to_asset) {
			# Between two wallets the one amount is native on both sides. Into or
			# out of a bank it is a sale or a purchase, not a move: a single
			# transfer figure cannot be both a coin and a dollar, so say so rather
			# than write a wrong number.
			if (!$from_asset || !$to_asset || $from_asset ne $to_asset) {
				$c->render(json => { error => 'A wallet transfer has to stay in the same coin on both sides. Record a sale and a purchase instead.' });
				return;
			}
			my $native = &subs::crypto_amount_number($transfer_amount, $from_asset);
			my $rate = &subs::crypto_rate($from_asset);
			if (!defined $native || !defined $rate) {
				$c->render(json => { error => 'No rate is loaded for ' . $from_asset . ' yet, so the transfer cannot be valued.' });
				return;
			}
			$native =~ s/^-//;
			my $value = &subs::crypto_value($native, $from_asset);
			$transfer_amount = abs($value) if defined $value;
			$transactions->{'crypto'} = { asset => $from_asset, amount => $native, rate => $rate, rate_at => &subs::rightNow(), value => $value };
			$jtransactions = encode_json $transactions;
		}
	}

	if ($quantity =~ /G$/gi) {
		$quantity =~ s/G$//gi;
	}


	my $returner = { uuid => $uuid, app => $app, timestamp => $timestamp, navigation => 'once' };

	if ($movement eq 'income' || $movement eq 'expense') {
	# The selected taxes are a snapshot of what this transaction charged, so a
	# later catalog change never rewrites an old bill. The line keeps its old
	# `tax` amount; these ride beside it.
	my $tax_snapshot = &subs::tax_transaction_snapshot(
		ref $transactions->{$movement} eq 'HASH' ? $transactions->{$movement} : {}
	);
	# The kept receipt is the paper's own record. Save is checked against it, not
	# against a hidden form field, so a stale tab cannot slip a wrong tax through.
	my $receipt_uuid = $c->param('receipt_uuid') || '';
	my ($receipt) = $receipt_uuid ne ''
		? grep { ($_->{'uuid'} || '') eq $receipt_uuid } @{ &market_receipts() }
		: ();
	my $receipt_tax;
	if ($receipt) {
		if (defined $receipt->{'tax_total'} && $receipt->{'tax_total'} =~ /[0-9]/) {
			$receipt_tax = &subs::tax_number($receipt->{'tax_total'});
		}
		elsif (defined $receipt->{'total'} && $receipt->{'total'} =~ /[0-9]/) {
			my $line_sum = 0;
			$line_sum += &subs::tax_number($_->{'price'}) for grep { ref $_ eq 'HASH' } @{ $receipt->{'lines'} || [] };
			$receipt_tax = &subs::tax_number($receipt->{'total'}) - $line_sum;
			$receipt_tax = 0 if $receipt_tax < 0;
		}
	}
	my $coded_tax = &subs::tax_snapshot_total($tax_snapshot);
	my $tax_delta = defined $receipt_tax ? &subs::tax_receipt_delta($receipt_tax, $tax_snapshot) : 0;
	my $tax_policy = 'block';
	if ($vendor ne '') {
		my $raw = &subs::setting_grabber({ app => $vendor, setting => 'tax_delta_save' });
		$tax_policy = $raw if defined $raw && $raw =~ /^(block|unattributed|warn)$/;
	}
	my $tax_exemption = (ref $transactions->{$movement} eq 'HASH' && ref $transactions->{$movement}->{'totals'} eq 'HASH')
		? ($transactions->{$movement}->{'totals'}->{'tax_exemption'} // '')
		: '';
	$tax_exemption = $c->param('tax_exemption') // '' unless length $tax_exemption;

		my $write = {
			timestamp => $timestamp,
			app => &subs::unformat_name($app),
			notes => $notes,
			total => $transactions->{$movement}->{'totals'}->{'total'} || $total,
			amount => $transactions->{$movement}->{'totals'}->{'amount'} || $amount,
			tax => $transactions->{$movement}->{'totals'}->{'tax'} || $tax,
			aux => $transactions->{$movement}->{'totals'}->{'aux'} || $aux,
			type => 'transaction',
			aux_description => $aux_description,
			duration => $duration,
			account => $account,
			project => $project,
			warranty => $warranty,
			item => $item,
			model => $model->{'uuid'},
			manufacturer => $manufacturer,
			vendor => $vendor,
			quantity => $quantity,
			movement => $movement,
			'state' => $state,
			has_tax => $has_tax,
			has_totes => $has_totes,
			unit => $unit,
			uuid => $uuid,
			data => $jtransactions,
			taxes => encode_json($tax_snapshot),
			tax_exemption => $tax_exemption,
			currency => $currency
		};

		# A receipt whose lines do not account for its printed tax is the one case
		# the vendor's policy governs. Block is the default; unattributed keeps the
		# paper's total and tax on the transaction; warn keeps the form's figures.
		if (defined $receipt_tax && abs($tax_delta) > 0.02) {
			if ($tax_policy eq 'block') {
				$c->render(json => { error => &subs::ui('The receipt tax does not match the lines. Tick the tax on the items, or change this vendor\'s receipt-tax policy.')
					. ' (' . sprintf('%.2f', $receipt_tax) . ' / ' . sprintf('%.2f', $coded_tax) . ')' });
				return;
			}
			if ($tax_policy eq 'unattributed') {
				my $gross = (defined $receipt->{'total'} && $receipt->{'total'} =~ /[0-9]/) ? &subs::tax_number($receipt->{'total'}) : abs($write->{'total'} || 0);
				my $net = $gross - $receipt_tax;
				$write->{'tax'} = $receipt_tax;
				$write->{'total'} = $movement eq 'expense' ? -abs($gross) : abs($gross);
				$write->{'amount'} = $movement eq 'expense' ? -abs($net) : abs($net);
			}
			$transactions->{$movement}->{'totals'} ||= {};
			$transactions->{$movement}->{'totals'}->{'receipt_tax'} = $receipt_tax;
			$transactions->{$movement}->{'totals'}->{'tax_delta'} = $tax_delta;
			$jtransactions = encode_json($transactions);
			$write->{'data'} = $jtransactions;
		}

		&appointment_writer($c,$write);
		# The item's tax choice is remembered from the line the person saved, so the
		# next receipt or transaction starts from it. Only an explicit choice is
		# written; an untouched picker leaves the item unknown.
		foreach my $key ( keys %{ ref $transactions->{$movement} eq 'HASH' ? $transactions->{$movement} : {} } ) {
			next if $key eq 'totals' || $key eq 'crypto';
			my $line = $transactions->{$movement}->{$key};
			next unless ref $line eq 'HASH' && $line->{'tax_known'};
			my $codes = &subs::tax_codes_value($line->{'taxes'});
			foreach my $item ( grep { length } map { &subs::unformat_name($_) } split /,/, ($line->{'item'} || '') ) {
				my $init = &subs::setting_initializer($item, &subs::rightNow());
				my $item_app = $init->{'app'} || $item;
				&subs::setting_setter({ app => $item_app, setting => 'tax_codes', value => encode_json($codes) });
			}
		}
		# The paper the shopping run was read off belongs to the purchase it paid
		# for: copy its pages onto this appointment (the category - clothes, say),
		# so they sit in that app's own Files and outlive the Receipts list.
		&market_receipt_attach({ app => $app, uuid => $uuid, receipt_uuid => $c->param('receipt_uuid') })
			if ($c->param('receipt_uuid') || '') ne '';
		if ($transaction_information && $transaction_information ne '' && $vendor) {
			my $inv = &subs::db_query('select * from appointments where app=? and uuid=?', $vendor, $transaction_information)->hashes->[0];
			if ($inv) {
				my $data = eval { return decode_json $inv->{'data'} };
				unless ($data->{'payments'}) {
					$data->{'payments'} = [];
				}
				my $payment = { account => $account, uuid => &subs::random_string_creator(12), appt_uuid => $uuid, amount => $total, timestamp => $timestamp, server_time => &subs::rightNow(), };
				push @{$data->{'payments'}}, $payment;
				$data->{'numbers'}->{'balance'} = $data->{'numbers'}->{'balance'} - $total;
				$inv->{'data'} = encode_json $data;
				$inv->{'server_time'} = &subs::rightNow();
				if ($data->{'numbers'}->{'balance'} == 0) {
					$inv->{'status'} = 'completed';
				}
				&subs::db_update('appointments', $inv, { uuid => $inv->{'uuid'}, app => $inv->{'app'} });
				&Websocket::send('server', { console => &Websocket::console_command('appointmentDetailGrabber', $vendor, $inv->{'uuid'})});
				# The backdated or hand-entered payment is on the invoice and its
				# balance is down; write the receipt and the paper that shows it.
				unless (eval { &store_payment_receipt({ app => $inv->{'app'}, uuid => $inv->{'uuid'}, tx_app => $write->{'app'}, payment => $payment }) }) {
					&subs::log_writer('receipt paper: ' . ($@ || 'the receipt was not written') . ' for ' . $inv->{'app'} . ' ' . $inv->{'uuid'});
				}
			}
		}
		if ($vendor && $record_vendor eq 'on') {
			my $vendor_uuid = &subs::random_string_creator(20);
			my $init = &subs::settings_grabber({ app => $vendor });

			$init = &subs::setting_initializer($vendor . ' vendor',$timestamp) unless $init->{'pos'};
			$vendor = $init->{'app'};
			&appointment_writer($c, {
				timestamp => $timestamp,
				type => 'purchase',
				account => $account,
				project => $project,
				warranty => $warranty,
				duration => $duration,
				app => $vendor,
				manufacturer => $manufacturer,
				quantity => $quantity,
				unit => $unit,
				movement => $movement,
				item => $item,
				uuid => $vendor_uuid,
				total => $transactions->{$movement}->{'totals'}->{'total'} || $total,
				amount => $transactions->{$movement}->{'totals'}->{'amount'} || $amount,
				tax => $transactions->{$movement}->{'totals'}->{'tax'} || $tax,
				aux => $transactions->{$movement}->{'totals'}->{'aux'} || $aux,
				taxes => encode_json($tax_snapshot),
				tax_exemption => $tax_exemption,
				source_uuid => $uuid
			});
			&market_receipt_attach({ app => $vendor, uuid => $vendor_uuid, receipt_uuid => $c->param('receipt_uuid') })
				if ($c->param('receipt_uuid') || '') ne '';
		}

		foreach my $t ( keys %{$transactions->{$movement}} ) {
			unless ($t eq 'totals') {
				my $tr = $transactions->{$movement}->{$t};
				if ($tr->{'manufacturer'} && $tr->{'record_manufacturer'} eq 'on') {
					my $init = &subs::setting_initializer($tr->{'manufacturer'} . ' manufacturer',$timestamp);
					$manufacturer = $init->{'app'};
					&appointment_writer($c, {
						timestamp => $timestamp,
						type => 'purchase',
						account => $account,
						project => $project,
						warranty => $warranty,
						duration => $duration,
						app => $manufacturer,
						manufacturer => $manufacturer,
						quantity => $tr->{'quantity'},
						unit => $tr->{'unit'},
						movement => $movement,
						item => $tr->{'item'},
						vendor => $vendor,
						uuid => &subs::random_string_creator(18),
						amount => $tr->{'amount'},
						tax => $tr->{'tax'},
						aux => $tr->{'aux'},
						total => $tr->{'total'},
						source_uuid => $uuid,
						currency => $currency
					});
				}
				if ($tr->{'item'} && $tr->{'record_item'} eq 'on') {


					my $item = $tr->{'item'};

					my @items = split ',', $item;
					foreach my $i ( @items ) {
						my $purchase = {
							timestamp => $timestamp,
							type => 'purchase',
							account => $account,
							project => $project,
							warranty => $warranty,
							duration => $duration,
							app => $i,
							amount => $tr->{'amount'} / scalar @items,
							tax => $tr->{'tax'} / scalar @items,
							aux => $tr->{'aux'} / scalar @items,
							total => $tr->{'total'} / scalar @items,
							vendor => $vendor,
							manufacturer => $tr->{'manufacturer'},
							uuid => $uuid . '-' . $t . '-' . scalar @items,
							has_tax => $tr->{'has_tax'},
							has_totes => $tr->{'has_totes'},
							'state' => $tr->{'state'} || $state,
							quantity => $tr->{'quantity'},
							unit => $tr->{'unit'},
							source_uuid => $uuid,
							taxes => encode_json(&subs::tax_transaction_snapshot({ $t => $tr })),
							tax_exemption => $tax_exemption,
							currency => $currency
						};
						&appointment_writer($c, $purchase);
						&market_receipt_attach({ app => $i, uuid => $purchase->{'uuid'}, receipt_uuid => $c->param('receipt_uuid') })
							if ($c->param('receipt_uuid') || '') ne '';
					}
				}
			}
		}

		my ($db,$database,$sql) = &subs::database_grabber();
		if ($model->{'uuid'}) {
			my $model_data = eval { return decode_json $model->{'inventory'} } || $gb::inventory_states;
			my $new_quantity = ($model->{'inventory'} || 0) + $quantity;
	#		&subs::db_query('update models set inventory=? where uuid=?', $new_quantity, $model->{'uuid'});
		}

		# move stock for the item(s) on this transaction: a sale (income) takes
		# stock out, a purchase (expense) puts it in. Only when we know the place.
		if ($item) {
			my $place = &subs::warehouse_place_for($app, $item);
			if ($place) {
				my $signed = ($movement eq 'income') ? -1 : 1;
				my $q = &subs::numeric_formatter($quantity) + 0;
				foreach my $i ( split ',', $item ) {
					next unless $i;
					&subs::warehouse_movement({
						item => $i,
						quantity => $q * $signed,
						unit => $unit,
						place => $place,
						model => $model->{'uuid'},
						account => $account,
						project => $project,
						warranty => $warranty,
						timestamp => $timestamp,
						app_uuid => $uuid,
						type => 'stock',
						reason => $movement,
						source => $app,
						source_uuid => $uuid
					});
				}
			}
		}
	}
	elsif ($movement eq 'transfer') {
		my $write1_uuid = &subs::random_string_creator(20);
		my $write2_uuid = &subs::random_string_creator(20);
		# Each leg carries its own signed native amount, so the wallet it belongs
		# to gains or loses exactly its half of the move.
		my $j1 = $jtransactions;
		my $j2 = $jtransactions;
		my $crypto = $transactions->{'crypto'};
		if (ref $crypto eq 'HASH') {
			my $positive = $crypto->{'amount'};
			$positive =~ s/^-//;
			$j1 = encode_json({ %{$transactions}, crypto => { %{$crypto}, amount => '-' . $positive } });
			$j2 = encode_json({ %{$transactions}, crypto => { %{$crypto}, amount => $positive } });
		}
		my $write1 = {
			app => $app,
			amount => $transfer_amount * -1,
			total => $transfer_amount * -1,
			type => 'transaction',
			movement => 'transfer',
			timestamp => $timestamp,
			server_time => &subs::rightNow(),
			account => $account,
			notes => $notes,
			uuid => $write1_uuid,
			warranty => $warranty,
			data => $j1,
			source_uuid => $write2_uuid,
			currency => $currency
		};
		my $write2 = {
			app => $app,
			amount => $transfer_amount,
			total => $transfer_amount,
			type => 'transaction',
			movement => 'transfer',
			timestamp => $timestamp,
			server_time => &subs::rightNow(),
			account => $to_account,
			notes => $notes,
			uuid => $write2_uuid,
			warranty => $warranty,
			data => $j2,
			source_uuid => $write1_uuid,
			currency => $currency
		};
		&subs::db_insert('appointments', $write1);
		&subs::db_insert('appointments', $write2);
		# a transfer is two money moves, one out and one in; the ledger mirrors both
		&warehouse_money_mirror($write1);
		&warehouse_money_mirror($write2);
	}
	elsif ($movement eq 'inventory') {

		my $write = {
			timestamp => $timestamp,
			app => &subs::unformat_name($app),
			notes => $notes,
			duration => $duration,
			total => $total,
			amount => $amount,
			total => $amount,
			type => 'transaction',
			account => $account,
			project => $project,
			warranty => $warranty,
			item => $item,
			model => $model->{'uuid'},
			quantity => $quantity,
			movement => $movement,
			'state' => $state,
			unit => $unit,
			uuid => $uuid,
			data => $jtransactions,
			currency => $currency
		};
		&subs::db_insert('appointments', $write);
		my $wdata = {
			server_time => &subs::rightNow(),
			timestamp => $timestamp,
			item => &subs::unformat_name($app),
			# kind names the face; type stays 'transaction' so the budget's movement
			# filter (which reads type) keeps the anchor, exactly as the appointment did
			type => 'transaction',
			kind => 'inventory',
			movement => 'inventory',
			app => &subs::unformat_name($app),
			unit => &subs::setting_grabber({ app => $account, setting => 'currency' }),
			quantity => $amount,
			amount => $amount,
			total => $amount,
			uuid => &subs::random_string_creator(40),
			app_uuid => $uuid,
			account => &subs::unformat_name($app),
			project => $project,
			warranty => $warranty
		};
		&subs::db_insert('warehouse', $wdata);



	}
	undef @appointments;
	my $appts = &log_reader({ app => $app, view => 'centre_view' });

#	&appt_measure_writer($c,{ app => $app, uuid => $uuid, timestamp => $timestamp });

	my $header = &subs::appt_header_printer({ appts => $appts, app => $app, timestamp => $timestamp });
	my $content = $c->render_to_string(
		template => 'appointment_wrapper',
		appointments => [ $app ],
		appts => $appts,
		timestamp => $timestamp,
		device => $device,
		header => $header,
		from => 'transaction',
		config => &subs::config_reader(),
		measures => $gb::measures
	);

#	&subs::cache_delete({ app => $app, context => 'template' });
	my $cv = &centre_view_grabber({ c => $c, app => $app, timestamp => $timestamp, cached => 'no' });
#	&Websocket::send('tab', { app => $app, window => $cv, timestamp => $timestamp });
	&budget_runner($app);

	&Websocket::send('server', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	$returner->{'cv'} = '';#&window_maker({ user_agent => $c->param('user_agent'), app => $app, contents => $content }, $timestamp);

	# a press that starts, stops, records, resumes, pauses or delays can change
	# which appointment owns the desktop theme; the request's own type is read
	# here because the branches above rewrite the local $type
	&subs::appointment_theme_push() if (($c->param('type') // '') =~ /^(?:start|stop|record|cancel|resume|pause|delay)$/);

	$c->render(json => $returner);
}

# GET /manager/transaction/movement
sub action_17895 {
	my $c = shift;
	my $movement = $c->param('movement');
	my $app = $c->param('app');
	&subs::setting_setter({ app => $app, setting => 't_movement', value => $movement });
	my $appts = &log_reader({ app => $app, view => 'centre_view' });
	my $informations = [];

	my $html = '<span class="purchase_details" uuid="' . &subs::random_string_creator(10) . '" app="' . $app . '" style=""><br>' .
		$c->render_to_string(
		template => 'apps/transaction/' . $movement,
		app => {},
		appts => $appts,
		a => $app,
	) . '</span>';
	$c->render(json => { html => $html, app => $app });
}

1;
