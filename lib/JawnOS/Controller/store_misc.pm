package Manager;

# store_misc: route actions moved out of Manager.pl, one sub per route so a
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

# GET /store
sub action_5514 {
	my $c = shift;
	&store_maker($c);
}

# GET /store/category_grabber
sub action_5659 {
	my $c = shift;
	my $category = &subs::unformat_name($c->param('category'));
	my $subcategory = &subs::unformat_name($c->param('subcategory'));
	my $types = eval { return decode_json $c->param('types') } || [];
	my $count = &subs::numeric_formatter($c->param('count') || '');
	my $privilege = $c->session('privilege') || '';
	my ($db,$database,$sql) = &subs::database_grabber();
	my $itemq = &subs::db_query('select * from settings where setting=? and value=? and device=?','category',$category,$device);

	my $items = $itemq->hashes;
	$items = &store_item_merchandiser($items,$types);
	@{$items} = grep { ($_->{'settings'}->{'public'} || '') eq 'on' } @{$items} unless $privilege eq 'citizen';
	if ($subcategory) {
		@{$items} = grep { ($_->{'settings'}->{'subcategory' . $count} || '') eq $subcategory } @{$items};
	}
	if (scalar @{$types} > 0) {
		my @temp_items;
		foreach my $type ( @{$types} ) {
			push @temp_items, grep { $_->{'settings'}->{'pos'} eq $type || $_->{'settings'}->{'mab'} eq $type } @{$items};
		}
		@{$items} = @temp_items;
	}

	my $subcategories;
	if ($subcategory) {
		$subcategories = &subs::db_query('select * from subcategory where app=?', $subcategory)->hashes;
		$count++;
	}
	else {
		$subcategories = &subs::db_query('select * from subcategory where app=?', $category)->hashes;
	}
	my $depth_field = $count > 0 ? 'subcategory' . $count : 'subcategory';
	my $subcategory_counts = &store_subcategory_counts($category, $depth_field, $privilege);
	my @subcategory_rows;
	foreach my $sub ( @{$subcategories} ) {
		my $n = $subcategory_counts->{ $sub->{'name'} } || 0;
		next unless $n > 0;
		push @subcategory_rows, {
			name => $sub->{'name'},
			label => &subs::format_name($sub->{'name'}),
			count => $n + 0
		};
	}
	@subcategory_rows = sort { $b->{'count'} <=> $a->{'count'} || lc($a->{'name'}) cmp lc($b->{'name'}) } @subcategory_rows;

	my $rendered = $c->render_to_string(
		template => 'store/category',
		items => $items,
		category => $category
	);
	my $returner = {
		content => $rendered,
		category => $category,
		count => scalar @{$items},
		depth => $count + 0,
		subcategories => \@subcategory_rows
	};
	$c->render(json => $returner);
}

# POST /store/search
sub action_5719 {
	my $c = shift;
	my $search = &subs::unformat_name($c->param('search'));
	my $timestamp = $c->param('timestamp');
	my $types = eval { return decode_json $c->param('types') } || [];
	my $privilege = $c->session('privilege') || '';
	my $items = &subs::db_query('select distinct(app) as app,* from settings where (setting= ? or setting = ?) and app like ? and device=?', 'pos', 'mab', '%' . $search . '%',$device)->hashes;
	my %seen;
	my @temp_items;
	foreach my $st ( @gb::store_types ) {
		# one row per item: an item with both pos and mab was listed twice
		push @temp_items, grep { ($_->{'value'} || '') eq $st && !$seen{ $_->{'app'} }++ } @{$items};
	}
	$items = &store_item_merchandiser(\@temp_items,$types);
	@{$items} = grep { ($_->{'settings'}->{'public'} || '') eq 'on' } @{$items} unless $privilege eq 'citizen';
	@{$items} = sort { lc($a->{'app'}) cmp lc($b->{'app'}) } @{$items};

	my $rendered = $c->render_to_string(
		template => 'store/category',
		items => $items,
	);
	my $returner = {
		content => $rendered,
		count => scalar @{$items}
	};
	$c->render(json => $returner);
}

# GET /store/item
sub action_5823 {
	my $c = shift;
	my $item = {};
	my $manufacturer = &subs::unformat_name($c->param('manufacturer'));
	$item->{'app'} = &subs::unformat_name($c->param('item'));
	$item->{'settings'} = &subs::settings_grabber({ app => $item->{'app'} });
	my @manufacturers;
	$item->{'models'} = &subs::db_query('select * from model where app = ? order by price', $item->{'app'})->hashes;
	$item->{'options'} = &subs::db_query('select * from option where app = ?', $item->{'app'})->hashes;
	my $markup = &markup_adjuster($item->{'settings'}->{'markup'} || &subs::setting_grabber({ app => 'me', setting => 'markup' }) || '5%');

	if ($c->param('quote')) {
		my $q = eval { return decode_json $c->param('quote') } || {};
		foreach my $t ( keys %{$q->{'custom'}} ) {
			foreach my $mo ( @{$q->{'custom'}->{$t}} ) {
				unless ( grep { $mo->{'uuid'} eq $_->{'uuid'} } @{$item->{$t . 's'}}) {
				#	$mo->{'characteristics'} = eval { return encode_json $mo->{'characteristics'} } || undef;
					push @{$item->{$t . 's'}}, $mo
				}
			}
		}


		$item->{'quote'} = $q;
	}


	if (scalar @{$item->{'models'}} > 0) {
		if ($item->{'models'}[0]->{'markup'}) {
			$markup = &markup_adjuster($item->{'models'}[0]->{'markup'});
		}
		if ($item->{'models'}[0]->{'price'}) {
			$item->{'price'} = $item->{'models'}[0]->{'price'};
		}
		elsif ($item->{'models'}[0]->{'cost'}) {
			$item->{'price'} = $item->{'models'}[0]->{'cost'} * $markup;
			$item->{'cost'} = $item->{'models'}[0]->{'cost'};
		}
		else {
			$item->{'price'} = $item->{'settings'}->{'worth'} * $markup;
		}
		$item->{'models'}[0]->{'select'} = 'on';
		foreach my $m (@{$item->{'models'}}) {
			$m->{'table'} = 'model';
		}
	}
	else {
		$item->{'price'} = $item->{'settings'}->{'worth'} * $markup;
	}
	if (scalar @{$item->{'options'}} > 0) {
		foreach my $o (@{$item->{'options'}}) {
			$o->{'table'} = 'option';
		}
	}
	my $option_categories = {};
	foreach my $att ( @{$item->{'models'}}, @{$item->{'options'}} ) {
		if ($att->{'manufacturer'}) {
			push @manufacturers, $att->{'manufacturer'} unless grep { $_ eq $att->{'manufacturer'} } @manufacturers;
		}
		if ($att->{'markup'}) {
			$markup = &markup_adjuster($att->{'markup'});
		}
		if ($att->{'file'}) {
			$att->{'file'} = eval { return decode_json $att->{'file'} } || [];
		}
		if ($att->{'price'}) {

		}
		else {
			$att->{'price'} = &subs::numeric_formatter($att->{'cost'}) * $markup;
		}
		if ($att->{'discount'}) {
			if ($att->{'discount'} =~ /%$/gi) {
				$att->{'discount'} =~ s/[^0-9.]//gi;
				$att->{'discount'} = abs($att->{'price'} * ($att->{'discount'} / 100));
			}
			$att->{'discount'} = abs($att->{'discount'}) * -1;
		}
		$att->{'characteristics'} = eval { return decode_json $att->{'characteristics' } } || [];
		if (my @oc = grep { $_->{'name'} eq 'option_category' } @{$att->{'characteristics'}} ) {
			foreach my $o ( @oc ) {
				my $option_category = &subs::db_select('option_category', undef, { uuid => $o->{'value'} })->hashes;
				if ($option_category->[0]->{'file'}) {
					$option_category->[0]->{'file'} = eval { return decode_json $option_category->[0]->{'file'} } || [];
				}
				$option_category->[0]->{'characteristics'} = eval { return decode_json $option_category->[0]->{'characteristics'} } || [];
				$item->{'option_categories'}->{$option_category->[0]->{'name'}} = $option_category->[0];
				foreach my $occ ( @{$option_category->[0]->{'characteristics'}} ) {
					$item->{'option_categories'}->{$option_category->[0]->{'name'}}->{$occ->{'name'}} = $occ->{'value'};
				}
				push @{$option_categories->{$option_category->[0]->{'name'}}}, $att;
			}
			@{$att->{'characteristics'}} = grep { $_->{'name'} ne 'option_category' } @{$att->{'characteristics'}};
		}
		elsif ((!$att->{'option_category'} || $att->{'option_category'} eq '') && $att->{'table'} eq 'option') {
			push @{$option_categories->{'misc'}}, $att;
		}
	}
	if ($manufacturer) {
		@{$item->{'options'}} = grep { $_->{'manufacturer'} eq $manufacturer } @{$item->{'options'}};
		@{$item->{'models'}} = grep { $_->{'manufacturer'} eq $manufacturer } @{$item->{'models'}};
	}
	if ($item->{'settings'}->{'public'} eq 'on' || $c->session('privilege') eq 'citizen') {
		my $fapptsq = &subs::db_query('select file from appointments where app = ? and file is not null', $item->{'app'})->hashes;
		$item->{'files'} = [];
		foreach my $t ( qw/ specs description / ) {
			$item->{'settings'}->{$t} =~ s/\n/<br>/gi;
		}
		foreach my $f ( @{$fapptsq} ) {
			$f->{'files'} = eval { return decode_json $f->{'file'} } || [];
			foreach my $fi ( grep { $_->{'function'} ne 'receipt' } @{$f->{'files'}} ) {
				push @{$item->{'files'}}, $fi if -e $fi->{'f'} && $fi->{'visible'} ne 'unchecked';
			}
		}
		if (!$item->{'settings'}->{'main_image'} && scalar @{$item->{'files'}} > 0) {
			$item->{'settings'}->{'main_image'} = $item->{'files'}->[0]->{'f'};
		}
		$item->{'template'} = $c->render_to_string(
			template => 'store/item',
			item => $item,
			markup => $markup,
			option_categories => $option_categories,
			manufacturers => \@manufacturers,
			settings => &subs::settings_grabber({ app => 'store' }),
			c => $c
		);
	}
	else {
		$item = { template => $c->render_to_string(template => 'guest_layouts/denial') };
	}
	$c->render(json => $item);
}

# POST /store/quote/save
sub action_6055 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $item = $c->param('item');
	my $quote_uuid = $c->param('uuid');
	my $cx = $c->param('cx');
	my $movement = $c->param('movement');
	if ($cx) {
		my $quote = eval { return decode_json $c->param('quote') } || { info => {}, options => [], model => {}, numbers => {}};

		my $customer_s = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx })->hashes->[0];
		my $s = &subs::settings_grabber({ app => $customer_s->{'app'} });
		$quote->{'id'} = &quote_id_maker($quote);# unless $quote->{'id'};
		my $jquote = encode_json $quote;
		&appointment_writer($c, { data => $jquote, movement => $movement, app => $customer_s->{'app'}, duration => &subs::time_abbrev_translator('10s'), timestamp => $timestamp, type => 'quote' });

		$c->render(json => { quote => $quote });
	}
	else {
		$c->render(json => { error => 'no customer' });
	}
}

# POST /store/quote/delete
sub action_6126 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $cx_uuid = $c->param('cx_uuid');
	my $timestamp = $c->param('timestamp');
	my $type = $c->param('type');
	my $server_time = $c->param('server_time');
	my $customer_s = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx_uuid })->hashes->[0];
	my $data = { type => $type, app => $customer_s->{'app'}, uuid => $uuid };
	# deleting a sale/invoice puts the stock back (or takes it back out)
	if ($type eq 'invoice' || $type eq 'sale') {
		my $appt = &subs::db_select('appointments', undef, $data)->hashes->[0];
		&store_quote_stock($appt, -1);
	}
	&delete_app($customer_s->{'app'},$uuid,$server_time,'quote_delete');
	$c->render(text => $data);
}

# POST /store/quote/move
sub action_6143 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $cx_uuid = $c->param('cx_uuid');
	my $uuid = $c->param('uuid');
	my $action = $c->param('action');
	my $type = $c->param('type');
	my $customer_s = &subs::db_select('settings', undef, { setting => 'uuid', value => $cx_uuid })->hashes->[0];



	my $data = { type => $type, app => $customer_s->{'app'}, uuid => $uuid };
	my $appt = &subs::db_select('appointments', undef, $data)->hashes->[0];
	return $c->render(text => 'no document') unless $appt;
	my $was = $appt->{'type'};
	my $source_server_time = $appt->{'server_time'};
	if ($action eq 'invoice' && $appt->{'type'} eq 'quote') {
		my $d = eval { return decode_json $appt->{'data'} };
		$d->{'numbers'}->{'balance'} = $d->{'numbers'}->{'total'};
		$appt->{'data'} = encode_json $d;
	}
	$appt->{'type'} = $action;
	$appt->{'status'} = 'open';
	$appt->{'server_time'} = &subs::rightNow();
	$appt->{'uuid'} = &subs::random_string_creator(25);
	&subs::db_insert('appointments', $appt, $data);

	# a moved document that becomes a receivable is an invoice now: give it its
	# own receiving address (a quote had none)
	if (($appt->{'type'} || '') eq 'invoice' && ($appt->{'uuid'} || '') ne '') {
		my $wallet = &subs::crypto_invoice_wallet('BTC');
		&subs::crypto_invoice_address({ app => $wallet->{'app'}, invoice => $appt->{'uuid'} }) if $wallet;
	}

	# a quote becoming an invoice/sale moves stock; moving it back reverses
	if ($was eq 'quote' && ($action eq 'invoice' || $action eq 'sale')) {
		&store_quote_stock($appt, 1);
	}
	elsif (($was eq 'invoice' || $was eq 'sale') && $action eq 'quote') {
		&store_quote_stock($appt, -1);
	}

	# a move is a move: the document the new one was made from is gone, not
	# standing beside it. Its files go with it, and the new document's stock
	# movement stays put - delete_app does not reverse stock.
	&delete_app($data->{'app'}, $data->{'uuid'}, $source_server_time, 'quote_move');

	$c->render(text => 'ok');
}

# GET /store/quote/load
sub action_6192 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my ($db) = &subs::database_grabber();
	my $quote = &subs::db_select('appointments', undef, { uuid => $uuid })->hashes->[0];
	if ($quote->{'data'}) {
		my $data = decode_json $quote->{'data'};
		$c->render(json => $data);
	}
	else {
		$c->render(json => {});
	}
}

# GET /store/print
sub action_6205 {
	my $c = shift;
	my $type = $c->param('type');
	my $cx_uuid = $c->param('cx_uuid');
	my $uuid = $c->param('uuid');

	my $printer = &store_printer({
		type => $type,
		cx_uuid => $cx_uuid,
		uuid => $uuid
	});
	my $header = $c->render_to_string(
		%{$printer}
	);
	$c->render(text => $header);
}

# GET /store/print/printers
sub action_52030 {
	my $c = shift;
	my $printers = &subs::cups_printers();
	$c->render(json => {
		printers => $printers,
		default => &subs::printer_default_get(),
		# only look at the network when this machine has no queue at all; an
		# explicit Find printers in the Dev panel is what adds it
		discovered => (scalar @{$printers} ? [] : &subs::cups_discovered_printers()),
	});
}

# POST /store/print/send
sub action_52031 {
	my $c = shift;
	my $printer = $c->param('printer') || &subs::printer_default_get();
	return $c->render(json => { ok => 0, error => 'No printer is selected.' }) unless length $printer;
	my $customer_app = $c->param('customer_app');
	$customer_app = &subs::printer_customer_app($c->param('uuid'), $c->param('type')) unless defined $customer_app && length $customer_app;
	my $paper = &store_printer({
		type => $c->param('type'),
		cx_uuid => $c->param('cx_uuid'),
		uuid => $c->param('uuid'),
		customer_app => $customer_app,
	});
	my $html = $c->render_to_string(%{$paper});
	my ($pdf, $error) = &subs::printer_pdf_from_html($html);
	return $c->render(json => { ok => 0, error => $error }) unless $pdf;
	my $result = &subs::printer_cups_send($printer, $pdf);
	unlink $pdf;
	$c->render(json => $result);
}

# GET /store/print/pdf
sub action_52032 {
	my $c = shift;
	my $customer_app = $c->param('customer_app');
	$customer_app = &subs::printer_customer_app($c->param('uuid'), $c->param('type')) unless defined $customer_app && length $customer_app;
	my $paper = &store_printer({
		type => $c->param('type'),
		cx_uuid => $c->param('cx_uuid'),
		uuid => $c->param('uuid'),
		customer_app => $customer_app,
	});
	my $html = $c->render_to_string(%{$paper});
	my ($pdf, $error) = &subs::printer_pdf_from_html($html);
	return $c->render(text => $error || 'could not make the PDF', status => 500) unless $pdf;
	my $bytes = read_file($pdf, binmode => ':raw');
	unlink $pdf;
	return $c->render(text => 'could not read the PDF', status => 500) unless defined $bytes && length $bytes;
	my $name = 'receipt-' . &subs::rightNow() . '.pdf';
	$c->res->headers->content_type('application/pdf');
	$c->res->headers->content_disposition('attachment; filename="' . $name . '"');
	$c->render(data => $bytes);
}

# GET /store/email
sub action_31938 {
	my $c = shift;
	my $returner;
	my $uuid = $c->param('uuid');
	my $cx_uuid = $c->param('cx_uuid');
	my $type = $c->param('type');

	my $cx = &subs::db_query('select * from settings where setting=? and value=?', 'uuid', $cx_uuid)->hashes->[0];
	my $settings = &subs::settings_grabber({ app => $cx->{'app'} });
	my $draft = {};
	my $drafts = &subs::db_query('select * from mailbox where email=? and status=? order by server_time asc', $settings->{'email'}, 'draft')->hashes;
	if (scalar @{$drafts} > 0) {
		foreach my $e ( qw/from_email email subject body uuid/ ) {
			$drafts->[-1]->{$e} = &subs::note_decrypter(&subs::session_suds($c), $drafts->[-1]->{$e});
		}
		$draft = $drafts->[-1];
		$draft->{'attachments'} = eval { return decode_json $draft->{'attachments'} } || [];
	}
	my $printer = &store_printer({
		type => $type,
		cx_uuid => $cx_uuid,
		uuid => $uuid,
		visibility => 'show'
	});
	my $attachments = [{
			type => 'printer',
			html => $c->render_to_string(%{$printer}),
			printer => $printer,
			uuid => $printer->{'uuid'}
		}
	];


	my $content = $c->render_to_string(
		template => 'mail/email_compose',
		email => $settings->{'email'},
		draft => $draft,
		drafts => $drafts,
		timestamp => $draft->{'timestamp'} || &subs::rightNow(),
		attachments => $attachments,
		# ${self} in the body answers for this quote/invoice and its customer
		magic_vars => 'document:' . $uuid . ',customer:' . $cx_uuid
	);
	foreach my $att ( @{$attachments} ) {

	}

	$c->render(json => { html => $content });
}

1;
