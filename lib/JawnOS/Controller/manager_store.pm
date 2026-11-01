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

# GET /manager/store
sub action_5518 {
	my $c = shift;

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

	&Websocket::send('tab', { console => 'registerGrabber(\'' . $item . '\')' });
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
			item => &subs::format_name($d->{'item'} || ''),
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
		template => 'store/register',
		documents => \@documents,
		totals => \%totals,
		customer => $customer,
		settings => $settings
	);
	$c->render(json => { content => $content, cx => $cx, count => scalar @documents });
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

	if ($quantity =~ /[a-zA-Z]/) {
		my $gunit = $quantity;
		$gunit =~ s/[^a-zA-Z]//gi;
		$unit = $gunit if grep { $_ eq $gunit } keys %{$gb::measures};
		$quantity =~ s/[^0-9.]//gi;
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
		uuid => &subs::random_string_creator(50),
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
	if ($uuid eq 'new') {
		&subs::db_insert($att, $returner);
	}
	else {
		$returner->{'uuid'} = $uuid;
		&subs::db_update($att, $returner, { uuid => $uuid });
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
	&subs::db_delete($att, { uuid => $uuid });
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
		&Websocket::send($app, { console => 'appointmentDetailGrabber(\'' . $appt->{'app'} . '\',\'' . $appt->{'uuid'} .'\');' });
	}
	$c->render(json => $model);
}

1;
