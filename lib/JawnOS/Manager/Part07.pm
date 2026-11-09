package Manager;

# Manager helpers, part 7 of 37. Moved out of Manager.pl so a
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

sub warehouse_moves($opts) {
	my $limit = $opts->{'limit'} || 300;
	my $search = $opts->{'search'};
	my @places = grep { defined $_ && $_ ne '' } @{ $opts->{'places'} || [] };
	my @moves;
	# stock moves: a stock row on a place, already signed
	my $wfilter = "where kind = 'stock'";
	my @wargs;
	if (scalar @places) {
		$wfilter .= ' and place in (' . join(',', map { '?' } @places) . ')';
		push @wargs, @places;
	}
	if (defined $search && $search ne '') { $wfilter .= ' and item like ?'; push @wargs, '%' . $search . '%'; }
	push @wargs, $limit;
	foreach my $r ( @{ &subs::db_query('select * from warehouse ' . $wfilter . ' order by timestamp desc limit ?', @wargs)->hashes } ) {
		my $j = eval { return decode_json($r->{'data'}) } || {};
		push @moves, {
			timestamp => &subs::numeric_formatter($r->{'timestamp'}) + 0,
			kind => 'stock',
			item => $r->{'item'},
			place => $r->{'place'},
			quantity => &subs::numeric_formatter($r->{'quantity'}) + 0,
			unit => $r->{'unit'} || 'each',
			reason => $j->{'reason'} || $r->{'type'} || 'stock',
			source => $j->{'source'},
			source_uuid => $j->{'source_uuid'} || $r->{'app_uuid'},
		};
	}
	# usage moves: consumption that had no shelf to take from. They are not part
	# of the balance, but they are part of the story, so the moves view shows them
	my $ufilter = "where kind = 'usage'";
	my @uargs;
	if (scalar @places) {
		$ufilter .= ' and place in (' . join(',', map { '?' } @places) . ')';
		push @uargs, @places;
	}
	if (defined $search && $search ne '') { $ufilter .= ' and item like ?'; push @uargs, '%' . $search . '%'; }
	push @uargs, $limit;
	foreach my $r ( @{ &subs::db_query('select * from warehouse ' . $ufilter . ' order by timestamp desc limit ?', @uargs)->hashes } ) {
		my $j = eval { return decode_json($r->{'data'}) } || {};
		push @moves, {
			timestamp => &subs::numeric_formatter($r->{'timestamp'}) + 0,
			kind => 'usage',
			item => $r->{'item'},
			place => $r->{'place'},
			quantity => &subs::numeric_formatter($r->{'quantity'}) + 0,
			unit => $r->{'unit'} || 'each',
			reason => $j->{'reason'} || 'usage',
			source => $j->{'source'},
			source_uuid => $j->{'source_uuid'} || $r->{'app_uuid'},
		};
	}
	# money moves: the ledger's own rows, mirrored from the transactions that
	# carried them, so both this view and the budget read one store
	my $mfilter = "where kind = 'money'";
	my @margs;
	if (defined $search && $search ne '') { $mfilter .= ' and (account like ? or app like ?)'; push @margs, ('%' . $search . '%') x 2; }
	push @margs, $limit;
	foreach my $r ( @{ &subs::db_query('select * from warehouse ' . $mfilter . ' order by timestamp desc limit ?', @margs)->hashes } ) {
		my $amt = $r->{'total'};
		$amt = $r->{'amount'} unless defined $amt && $amt =~ /[0-9]/;
		$amt = &subs::numeric_formatter($amt) + 0;
		next unless $amt;
		push @moves, {
			timestamp => &subs::numeric_formatter($r->{'timestamp'}) + 0,
			kind => 'money',
			item => $r->{'account'},
			place => '',
			quantity => $amt,
			unit => $r->{'currency'} || 'CAD',
			reason => $r->{'movement'},
			source => $r->{'app'},
			source_uuid => $r->{'uuid'},
			money => 1,
		};
	}
	@moves = sort { $b->{'timestamp'} <=> $a->{'timestamp'} } @moves;
	# each source is capped at $limit before the merge; the list is not capped
	# again, or a busy money stream would crowd out the stock moves behind it
	return \@moves;
}

sub warehouse_money_mirror($row) {
	return &subs::warehouse_money_mirror($row);
}

sub appointment_stock_movement {
	my ($c, $app, $type, $quantity, $unit, $timestamp, $uuid) = @_;
	return unless defined $app && length $app;
	return unless defined $type && $type =~ /^(?:record|stop)$/;
	my $mode = &subs::setting_grabber({ app => $app, setting => 'stock_movement' }) || 'off';
	return unless $mode eq 'consume' || $mode eq 'produce';
	my $default_unit = &subs::setting_grabber({ app => $app, setting => 'unit' }) || 'each';
	my ($qty, $qunit) = &subs::quantity_unit_split($quantity, $unit || $default_unit);
	return unless $qty > 0;
	return unless $gb::measures->{$qunit};   # an unknown word (hours, packs) is not stock
	my $types = $gb::measures->{$qunit}->{'types'} || [];
	return if grep { $_ eq 'currency' or $_ eq 'time' } @{$types};
	my $item = &subs::setting_grabber({ app => $app, setting => 'stock_item' });
	$item = $app unless defined $item && $item =~ /\S/;
	$item = &subs::unformat_name($item);
	my $place = &subs::warehouse_place_for($app, $item);
	return unless $place;
	my $stamp = $timestamp || &subs::rightNow();
	if ($mode eq 'produce') {
		&subs::warehouse_movement({
			item => $item, quantity => $qty, unit => $qunit, place => $place,
			timestamp => $stamp, app_uuid => $uuid, type => 'stock',
			reason => 'produced', source => $app, source_uuid => $uuid,
		});
		return;
	}
	my $on_hand = &subs::warehouse_on_hand_at($item, $qunit, $place);
	my $take = $on_hand > 0 ? ($on_hand < $qty ? $on_hand : $qty) : 0;
	if ($take > 0) {
		&subs::warehouse_movement({
			item => $item, quantity => $take * -1, unit => $qunit, place => $place,
			timestamp => $stamp, app_uuid => $uuid, type => 'stock',
			reason => 'consumed', source => $app, source_uuid => $uuid,
		});
	}
	my $rest = $qty - $take;
	if ($rest > 0) {
		&subs::warehouse_usage({
			item => $item, quantity => $rest, unit => $qunit, place => $place,
			timestamp => $stamp, app_uuid => $uuid,
			reason => 'consumed_unstocked', source => $app, source_uuid => $uuid,
		});
	}
}

sub appointment_edit_stock_row {
	my ($app, $uuid, $item, $unit, $place, $quantity, $reason, $timestamp) = @_;
	return unless defined $item && length $item && $quantity;
	return unless defined $place && length $place;
	&subs::warehouse_movement({
		item => $item, quantity => $quantity, unit => $unit, place => $place,
		timestamp => $timestamp, app_uuid => $uuid, type => 'stock',
		reason => $reason, source => $app, source_uuid => $uuid,
	});
}

sub appointment_edit_usage_row {
	my ($app, $uuid, $item, $unit, $place, $quantity, $reason, $timestamp) = @_;
	return unless defined $item && length $item && $quantity;
	return unless defined $place && length $place;
	&subs::warehouse_usage({
		item => $item, quantity => $quantity, unit => $unit, place => $place,
		timestamp => $timestamp, app_uuid => $uuid,
		reason => $reason, source => $app, source_uuid => $uuid,
	});
}

sub appointment_edit_ledger($c, $before, $sdata) {
	my $uuid = $before->{'uuid'};
	return unless defined $uuid && length $uuid;
	my %touched = map { $_ => 1 } keys %{$sdata};
	my $after = { %{$before}, %{$sdata} };
	my $app = $after->{'app'};
	my $type = $after->{'type'} || '';
	my $now = &subs::rightNow();

	# --- stock: quantity, unit, item or time changed on a movement the row owns
	if (grep { $touched{$_} } qw/quantity unit item timestamp/ ) {
		my $mode = &subs::setting_grabber({ app => $app, setting => 'stock_movement' }) || 'off';
		if (($mode eq 'consume' || $mode eq 'produce') && $type =~ /^(?:record|stop)$/) {
			my $default_unit = &subs::setting_grabber({ app => $app, setting => 'unit' }) || 'each';
			my $q = &subs::db_query("select * from warehouse where app_uuid = ? and kind in ('stock','usage') order by timestamp", $uuid)->hashes || [];
			my @stock = grep { ($_->{'kind'} || '') eq 'stock' } @{$q};
			my @usage = grep { ($_->{'kind'} || '') eq 'usage' } @{$q};
			my ($old_item, $old_unit, $old_place) = ('', '', '');
			foreach my $r ( @{$q} ) {
				$old_item = $r->{'item'} if $old_item eq '';
				$old_unit = $r->{'unit'} if $old_unit eq '';
				$old_place = $r->{'place'} if $old_place eq '';
			}
			my ($old_stock, $old_usage) = (0, 0);
			$old_stock += &subs::numeric_formatter($_->{'quantity'}) + 0 foreach @stock;
			$old_usage += &subs::numeric_formatter($_->{'quantity'}) + 0 foreach @usage;
			my $old_total = ($mode eq 'consume') ? (($old_stock * -1) + $old_usage) : $old_stock;

			my ($qty, $qunit) = &subs::quantity_unit_split($after->{'quantity'}, $after->{'unit'} || $default_unit);
			my $item = &subs::setting_grabber({ app => $app, setting => 'stock_item' });
			$item = $app unless defined $item && $item =~ /\S/;
			$item = &subs::unformat_name($item);
			my $place = &subs::warehouse_place_for($app, $item);

			# A time-only edit follows the row: the movement keeps its amount and
			# reason, only the stamp moves.
			if (!grep { $touched{$_} } qw/quantity unit item/ ) {
				&subs::db_query('update warehouse set timestamp = ? where app_uuid = ? and kind in (\'stock\',\'usage\')', $after->{'timestamp'}, $uuid)
					if defined $after->{'timestamp'};
			}
			elsif ($place) {
				my $qty_changed = $touched{'quantity'};
				my $place_changed = (($old_item // '') ne $item || ($old_unit // '') ne $qunit);
				my $old_place_use = $old_place ne '' ? $old_place : $place;
				if ($place_changed && scalar @{$q}) {
					# the movement named another item/unit: give the old one back,
					# then take the new one - two documented moves, no rewrite
					if ($mode eq 'consume') {
						&appointment_edit_stock_row($app, $uuid, $old_item, $old_unit, $old_place_use, ($old_stock * -1), 'returned_to_shelf', $now);
						&appointment_edit_usage_row($app, $uuid, $old_item, $old_unit, $old_place_use, ($old_usage * -1), 'edit_adjust_unstocked', $now);
					}
					else {
						&appointment_edit_stock_row($app, $uuid, $old_item, $old_unit, $old_place_use, ($old_stock * -1), 'taken_from_shelf', $now);
					}
					$old_total = 0;
					$old_stock = 0;
					$old_usage = 0;
				}
				if ($mode eq 'produce') {
					my $delta = $qty - $old_total;
					if ($delta > 0) {
						&appointment_edit_stock_row($app, $uuid, $item, $qunit, $place, $delta, 'produced_adjust', $now);
					}
					elsif ($delta < 0) {
						&appointment_edit_stock_row($app, $uuid, $item, $qunit, $place, $delta, 'taken_from_shelf', $now);
					}
				}
				else {
					my $delta = $qty - $old_total;
					if ($delta > 0) {
						# more consumed: the shelf first, the rest as usage
						my $on_hand = &subs::warehouse_on_hand_at($item, $qunit, $place);
						my $take = $on_hand > 0 ? ($on_hand < $delta ? $on_hand : $delta) : 0;
						&appointment_edit_stock_row($app, $uuid, $item, $qunit, $place, ($take * -1), 'taken_from_shelf', $now) if $take > 0;
						&appointment_edit_usage_row($app, $uuid, $item, $qunit, $place, ($delta - $take), 'edit_adjust_unstocked', $now) if $delta - $take > 0;
					}
					elsif ($delta < 0) {
						# less consumed: undo unshelved use first, then return to the shelf
						my $back = $delta * -1;
						my $from_usage = $old_usage < $back ? $old_usage : $back;
						&appointment_edit_usage_row($app, $uuid, $item, $qunit, $place, ($from_usage * -1), 'edit_adjust_unstocked', $now) if $from_usage > 0;
						my $to_shelf = $back - $from_usage;
						&appointment_edit_stock_row($app, $uuid, $item, $qunit, $place, $to_shelf, 'returned_to_shelf', $now) if $to_shelf > 0;
					}
				}
				&subs::accounting_journal_maybe_rebuild();
			}
		}
	}

	# --- money: the mirror is one row at uuid = the appointment's uuid
	if (grep { $touched{$_} } qw/account project movement amount tax aux total item quantity unit timestamp/ ) {
		my %m;
		foreach my $k (qw/account project movement amount tax aux total item quantity unit timestamp/) {
			$m{$k} = $after->{$k} if exists $sdata->{$k};
		}
		my $money = &subs::db_select('warehouse', undef, { kind => 'money', uuid => $uuid })->hashes->[0];
		if ($money) {
			&subs::db_update('warehouse', \%m, { kind => 'money', uuid => $uuid });
			&subs::accounting_journal_maybe_rebuild();
		}
		elsif ($type eq 'transaction' && ($after->{'account'} // '') ne '') {
			# the edit gave a row an account it did not have; one mirror, once
			&subs::warehouse_money_mirror($after);
			&subs::accounting_journal_maybe_rebuild();
		}
	}
}

sub store_maker($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $cat = &subs::db_query('select * from settings where (setting=? or setting =?) and value=? and device=?','pos', 'mab','category',$device);
	my $categories = $cat->hashes;
	my $timestamp = &subs::rightNow();
	my $settings = &subs::settings_grabber({ app => 'store' });
	# A category used to be one row per pos/mab setting, so the same category could
	# appear twice; and every category appeared whether or not it held anything.
	# Keep one of each and drop the ones with no visible item - an empty shelf is
	# not a destination, it is a dead end.
	my %store_seen;
	my @store_categories;
	foreach my $s ( @{$categories} ) {
		next if $store_seen{ $s->{'app'} }++;
		my $app = $s->{'app'};
		$s->{'settings'} = &subs::settings_grabber({ app => $app });
		$s->{'count'} = &store_category_item_count($app, $c->session('privilege'));
		next unless $s->{'count'} > 0;
		push @store_categories, $s;
	}
	$categories = [ sort { lc($a->{'app'}) cmp lc($b->{'app'}) } @store_categories ];
	my $store_item_total = 0;
	$store_item_total += $_->{'count'} foreach @{$categories};
	my $store_type_counts = &store_type_counts($c->session('privilege'), [ map { $_->{'app'} } @{$categories} ]);
	my $mail_ws_url = &ws_url_for($c, '/mail/ws');
	my $paperboy_url = &ws_url_for($c, '/observer/ws');
	my $ws_url = &ws_url_for($c, '/manager/ws');
	my $advertise_watching = &subs::setting_grabber({ app => 'me', setting => 'advertise_watching' });
	if ($c->param('window_maker') eq 'yes') {
		return $c->render_to_string(
			template => 'store/store',
			string => $random_caching_string,
			categories => $categories,
			item_total => $store_item_total,
			type_counts => $store_type_counts,
			ws_url => $ws_url,
			mail_ws_url => $mail_ws_url,
			paperboy_url => $paperboy_url,
			config => &subs::config_reader(),
			advertise_watching => $advertise_watching,
			my_name => $c->session('name'),
			pseudonyms => &pseudonym_maker('manager',''),
			window_maker => $c->param('window_maker'),
			settings => $settings
		);
	}
	else {
		$c->render(
			template => 'store/store',
			layout => 'store',
			string => $random_caching_string,
			categories => $categories,
			item_total => $store_item_total,
			type_counts => $store_type_counts,
			ws_url => $ws_url,
			mail_ws_url => $mail_ws_url,
			paperboy_url => $paperboy_url,
			config => &subs::config_reader(),
			advertise_watching => $advertise_watching,
			my_name => $c->session('name'),
			pseudonyms => &pseudonym_maker('manager',''),
			settings => $settings,
			window_maker => $c->param('window_maker')
		);
	}

}

sub store_category_item_count {
	my ($category, $privilege) = @_;
	return 0 unless defined $category && length $category;
	my $sql = q{select count(*) as c from settings where setting='category' and value=? and device=?};
	my @args = ($category, $device);
	if (($privilege || '') ne 'citizen') {
		$sql .= q{ and app in (select app from settings where setting='public' and value='on' and device=?)};
		push @args, $device;
	}
	my $q = &subs::db_query($sql, @args);
	my $row = $q ? $q->hash : undef;
	return $row ? ($row->{'c'} + 0) : 0;
}

sub store_type_counts {
	my ($privilege, $category_apps) = @_;
	my %counts = map { $_ => 0 } @gb::store_types;
	my @cats = @{ $category_apps || [] };
	return \%counts unless scalar @cats;
	my $placeholders = join ',', map { '?' } @gb::store_types;
	my $cat_placeholders = join ',', map { '?' } @cats;
	# Count only items that actually sit on a shelf: an app wearing pos=event for
	# its own appointments is not a Store event.
	my $sql = "select value as type, count(distinct app) as c from settings where setting in ('pos','mab') and device=? and value in ($placeholders) and app in (select app from settings where setting='category' and device=? and value in ($cat_placeholders))";
	my @args = ($device, @gb::store_types, $device, @cats);
	if (($privilege || '') ne 'citizen') {
		$sql .= q{ and app in (select app from settings where setting='public' and value='on' and device=?)};
		push @args, $device;
	}
	$sql .= ' group by value';
	my $q = &subs::db_query($sql, @args);
	foreach my $r ( @{ $q ? $q->hashes : [] } ) {
		$counts{ $r->{'type'} } = $r->{'c'} + 0 if defined $r->{'type'};
	}
	return \%counts;
}

sub store_subcategory_counts {
	my ($category, $field, $privilege) = @_;
	$field = 'subcategory' unless defined $field && $field =~ /^subcategory\d*$/;
	$field = 'subcategory' if $field eq 'subcategory0';
	my $sql = "select value as name, count(*) as c from settings where setting=? and device=? and app in (select app from settings where setting='category' and value=? and device=?)";
	my @args = ($field, $device, $category, $device);
	if (($privilege || '') ne 'citizen') {
		$sql .= q{ and app in (select app from settings where setting='public' and value='on' and device=?)};
		push @args, $device;
	}
	$sql .= ' group by value';
	my $q = &subs::db_query($sql, @args);
	my %counts;
	foreach my $r ( @{ $q ? $q->hashes : [] } ) {
		$counts{ $r->{'name'} } = $r->{'c'} + 0 if defined $r->{'name'};
	}
	return \%counts;
}

sub markup_adjuster($markup) {
	if ($markup =~ /%$/gi) {
		$markup =~ s/[^0-9.]//gi;
		$markup = abs(($markup / 100)) + 1;
	}
	return $markup;
}

sub store_item_merchandiser($items,$types) {
	my $universal_markup = &subs::setting_grabber({ app => 'me', setting => 'markup' }) || '5%';
	my $markup = $universal_markup;
	if ($markup =~ /%$/gi) {
		$markup =~ s/[^0-9.]//gi;
		$markup = abs(($markup / 100));
	}

	foreach my $i ( @{$items} ) {
		$i->{'settings'} = &subs::settings_grabber({ app => $i->{'app'} });
		# What the card and the filter chips read. A type lives in either pos or mab
		# depending on how the item was entered; the first non-blank one is its face.
		my $type = $i->{'settings'}->{'pos'} || $i->{'settings'}->{'mab'} || 'product';
		$i->{'type'} = (grep { $_ eq $type } @gb::store_types) ? $type : 'product';
		$i->{'subcategory'} = $i->{'settings'}->{'subcategory'} || '';
		# The stored colour is kept as an accent, never as the card's fill: a shelf
		# painted in its own bright colour ignored the theme. Only a real hex value
		# is passed through, so a stray value cannot inject CSS.
		my $colour = $i->{'settings'}->{'colour'} || '';
		$colour =~ s/^\s+|\s+$//g;
		$i->{'colour'} = $colour =~ /^#?[0-9a-fA-F]{6}$/ ? ($colour =~ /^#/ ? $colour : '#' . $colour) : '';
		$markup = $i->{'settings'}->{'markup'} || $universal_markup;
		if ($markup =~ /%$/gi) {
			$markup =~ s/[^0-9.]//gi;
			$markup = abs(($markup / 100));
		}
		my $models = &subs::db_query('select * from model where app = ?', $i->{'app'})->hashes;
		my $options = &subs::db_query('select * from option where app = ?', $i->{'app'})->hashes;
		my $seen = 0;
		$i->{'price'} = &subs::numeric_formatter($i->{'price'});
		foreach my $mo ( @{$models}, @{$options} ) {
			# a blank quantity is no quantity at all; left as words it only earned a
			# warning and multiplied as zero anyway
			my $quantity = &subs::numeric_formatter($mo->{'quantity'});
			if ($mo->{'def'} eq 'on') {
				if ($mo->{'price'}) {
					$i->{'price'} += $mo->{'price'} * $quantity;
					$seen += 1;
				}
				elsif ($mo->{'cost'}) {
					$i->{'price'} += $mo->{'cost'} * $quantity * $markup;
					$seen += 1;
				}
			}
		}

		if ($seen == 0) {
			@{$i->{'models'}} = sort { $a->{'price'} cmp $b->{'price'} } @{$models};
			if (scalar @{$i->{'models'}} > 0) {
				if ($i->{'models'}[0]->{'price'}) {
					$i->{'price'} = &subs::numeric_formatter($i->{'models'}[0]->{'price'});
				}
				elsif ($i->{'models'}[0]->{'cost'}) {
					$i->{'price'} = $i->{'models'}[0]->{'cost'} * $markup;
				}
			}
		}
	}
	if (scalar @{$types} > 0) {
		my @temp_items;
		foreach my $type ( @{$types} ) {
			push @temp_items, grep { $_->{'settings'}->{'pos'} eq $type || $_->{'settings'}->{'mab'} eq $type } @{$items};
		}
		@{$items} = @temp_items;
	}
	return $items;

}

sub quote_id_maker($quote) {
	my $server_time = &subs::rightNow();
	my $time = localtime($server_time / 1000);

	my $id = ($time->[4] + 1) . ($time->[3]) . ($time->[5] + 1900);
	my $today_quotes = &subs::db_query('select type,data,uuid from appointments where ( type=? or type=? or type=? or type=? ) and timestamp > ? and timestamp < ? order by server_time',
		'order','invoice','quote','purchase', &subs::ago_calc('1d',$server_time), &subs::ago_calc('-1d',$server_time))->hashes;
	my $quote_number = 1;

	foreach my $q ( @{$today_quotes} ) {
		my $qd = eval { return decode_json $q->{'data'} } || {};
		my @qid = split '-', $qd->{'id'};
		$quote_number = $qid[1] + 1 unless $quote_number > $qid[1] + 1;
	}

	$id .= '-' . $quote_number . &subs::shorthand_name(&subs::signatorial_designer(),3);
	return $id;
}

sub store_quote_stock($appt,$sign) {
	return unless $appt && $appt->{'data'};
	my $q = eval { return decode_json $appt->{'data'} } || {};
	return unless $q->{'item'};
	return unless ($q->{'movement'} eq 'income' || $q->{'movement'} eq 'expense');
	my $place = &subs::warehouse_place_for($appt->{'app'}, $q->{'item'});
	return unless $place;
	my $quantity = &subs::numeric_formatter($q->{'model'}->{'quantity'} || 1) + 0;
	my $signed = ($q->{'movement'} eq 'income') ? -1 : 1;
	foreach my $i ( split ',', $q->{'item'} ) {
		next unless $i;
		&subs::warehouse_movement({
			item => $i,
			quantity => $quantity * $signed * $sign,
			unit => $q->{'model'}->{'unit'},
			place => $place,
			model => $q->{'model'}->{'uuid'},
			timestamp => $appt->{'timestamp'},
			app_uuid => $appt->{'uuid'},
			type => 'stock',
			reason => ($sign > 0 ? $q->{'movement'} : $q->{'movement'} . '_reversed'),
			source => $appt->{'app'},
			source_uuid => $appt->{'uuid'}
		});
	}
}

1;
