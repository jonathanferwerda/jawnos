package Manager;

# Manager helpers, part 19 of 37. Moved out of Manager.pl so a
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

sub accounting_payables {
	my $to = shift;
	# a schedule whose date has come is a real bill; make them before reading
	&payable_schedule_run();
	# a payment notification becomes a bill and its payment with no prompt
	&notification_payable_autobook();
	my $returner = { rows => [], total => 0, count => 0, paid_count => 0, buckets => { current => 0, '31_60' => 0, '61_90' => 0, over_90 => 0 } };
	my $bills = &subs::db_query("select * from warehouse where kind='money' and type='transaction' and movement='payable' and cast(timestamp as integer) <= cast(? as integer) order by timestamp", $to)->hashes || [];
	my $payments = &subs::db_query("select * from warehouse where kind='money' and type='transaction' and movement='payment' and cast(timestamp as integer) <= cast(? as integer)", $to)->hashes || [];
	my %settled;
	foreach my $p ( @{$payments} ) {
		next unless $p->{'source_uuid'};
		$settled{$p->{'source_uuid'}} += abs(($p->{'total'} || 0) + 0);
	}
	foreach my $bill ( @{$bills} ) {
		my $total = abs(($bill->{'total'} || 0) + 0);
		next if $total < 0.005;
		my $paid = $settled{$bill->{'uuid'}} || 0;
		my $balance = $total - $paid;
		if ($balance <= 0.005) { $returner->{'paid_count'}++; next; }
		my $issued = ($bill->{'timestamp'} || 0) + 0;
		my $age = int(($to - $issued) / 86400000);
		$age = 0 if $age < 0;
		my $bucket = $age <= 30 ? 'current' : $age <= 60 ? '31_60' : $age <= 90 ? '61_90' : 'over_90';
		$returner->{'total'} += $balance;
		$returner->{'buckets'}->{$bucket} += $balance;
		$returner->{'count'}++;
		push @{$returner->{'rows'}}, {
			uuid => $bill->{'uuid'},
			app => $bill->{'app'},
			vendor => $bill->{'vendor'},
			item => $bill->{'item'},
			timestamp => $issued,
			age => $age,
			bucket => $bucket,
			total => $total,
			paid => $paid,
			balance => $balance
		};
	}
	@{$returner->{'rows'}} = sort { $b->{'age'} <=> $a->{'age'} } @{$returner->{'rows'}};
	return $returner;
}

sub payable_schedules {
	my $raw = &subs::setting_grabber({ app => 'budget', setting => 'payable_schedules' });
	my $list = eval { decode_json $raw || '[]' } || [];
	return [ grep { ref $_ eq 'HASH' } @{$list} ];
}

sub payable_schedules_save {
	my $list = shift || [];
	&subs::setting_setter({ app => 'budget', setting => 'payable_schedules', value => encode_json($list) });
}

sub payable_next_date {
	my ($ts,$every,$anchor_day) = @_;
	$every = 'monthly' unless defined $every && length $every;
	# The same interval reader the appointment schedule uses: months and years
	# step through the calendar, so a 31st bill shortens to February's last day
	# and returns to the 31st afterwards.
	my $next = &subs::schedule_next($ts,$every,$anchor_day);
	return defined $next ? $next : &subs::calendar_shift($ts,1,'month',$anchor_day);
}

sub payable_schedule_run {
	my $now = &subs::rightNow();
	my $list = &payable_schedules();
	my ($changed,$made) = (0,0);
	foreach my $s ( @{$list} ) {
		next if (($s->{'active'} || 'on') eq 'off');
		my $guard = 0;
		# A schedule read from words carries its dates outright. The queue's first
		# entry is the next bill; every due date already past is filled in here.
		if (ref $s->{'dates'} eq 'ARRAY') {
			my @queue = sort { $a <=> $b } grep { defined $_ } @{ $s->{'dates'} };
			while (@queue && $queue[0] <= $now && $guard++ < 240) {
				my $due = shift @queue;
				my $uuid = 'sched-' . $s->{'uuid'} . '-' . $due;
				my $exists = &subs::db_query("select 1 from warehouse where kind='money' and uuid=? limit 1", $uuid)->hashes->[0];
				unless ($exists) {
					my $total = ($s->{'amount'} || 0) + 0;
					my $tax = ($s->{'tax'} || 0) + 0;
					&subs::db_insert('warehouse', {
						kind => 'money', type => 'transaction', movement => 'payable',
						account => 'accounts_payable', app => ($s->{'app'} || 'unknown'),
						vendor => ($s->{'vendor'} || ''), item => ($s->{'item'} || ''),
						amount => $total, tax => $tax, total => $total,
						currency => ($s->{'currency'} || ''),
						uuid => $uuid, source_uuid => $s->{'uuid'},
						timestamp => $due, server_time => &subs::rightNow()
					});
					$made++;
				}
			}
			$s->{'dates'} = [ @queue ];
			$s->{'next'} = @queue ? $queue[0] : 0;
			if (!@queue) { $s->{'active'} = 'off'; $s->{'finished'} = 1; }
			$changed = 1;
			next;
		}
		my $until = ($s->{'until'} || 0) + 0;
		while ((($s->{'next'} || 0) + 0) <= $now && $guard++ < 240) {
			my $due = $s->{'next'} + 0;
			# a horizon ends the schedule before its next occurrence
			last if $until && $due >= $until;
			my $uuid = 'sched-' . $s->{'uuid'} . '-' . $due;
			my $exists = &subs::db_query("select 1 from warehouse where kind='money' and uuid=? limit 1", $uuid)->hashes->[0];
			unless ($exists) {
				my $total = ($s->{'amount'} || 0) + 0;
				my $tax = ($s->{'tax'} || 0) + 0;
				&subs::db_insert('warehouse', {
					kind => 'money', type => 'transaction', movement => 'payable',
					account => 'accounts_payable', app => ($s->{'app'} || 'unknown'),
					vendor => ($s->{'vendor'} || ''), item => ($s->{'item'} || ''),
					amount => $total, tax => $tax, total => $total,
					currency => ($s->{'currency'} || ''),
					uuid => $uuid, source_uuid => $s->{'uuid'},
					timestamp => $due, server_time => &subs::rightNow()
				});
				$made++;
			}
			$s->{'next'} = &payable_next_date($due, $s->{'every'}, $s->{'anchor_day'});
			$changed = 1;
		}
		# the horizon has passed, so the schedule has run its course; the bills
		# it already made stay, and Delete removes the row if it is no longer wanted
		if ($until && (($s->{'next'} || 0) + 0) >= $until) {
			$s->{'active'} = 'off';
			$s->{'finished'} = 1;
			$changed = 1;
		}
	}
	&payable_schedules_save($list) if $changed;
	return $made;
}

sub notification_account {
	my $n = shift;
	my $key = $n->{'key'} || '';
	my ($package) = $key =~ /\|([A-Za-z0-9_.]+)\|/;
	my %known = ( 'ca.koho' => 'koho', 'com.koho' => 'koho' );
	my $account = $known{lc($package || '')};
	if (!$account && ($n->{'message'} || '') =~ /spendable/i) { $account = 'koho'; }
	return undef unless $account && length $account;
	my $row = &subs::db_query("select 1 from settings where app=? and setting in ('pos','mab') and value='account' limit 1", $account)->hashes->[0];
	return $row ? $account : undef;
}

sub notification_bill_uuid {
	my $n = shift;
	my $seed = $n->{'key'} || $n->{'uuid'} || '';
	return 'note-' . &subs::md5_sum($seed);
}

sub notification_payment_of {
	my $n = shift;
	my $msg = $n->{'message'} || '';
	return undef unless $msg =~ /\b(spent|paid|purchase[d]?|charged|debited|payment made)\b/i;
	return undef unless $msg =~ /\$\s?([0-9][0-9,]*\.[0-9]{2})/;
	my $amount = $1;
	$amount =~ s/,//g;
	$amount += 0;
	return undef unless $amount > 0;
	my $merchant;
	if ($msg =~ /\bat\s+([A-Za-z0-9][^.\n]*?)(?:\.|\n|$)/) { $merchant = $1; }
	elsif (($n->{'title'} || '') !~ /transaction made/i) { $merchant = $n->{'title'}; }
	return undef unless $merchant;
	$merchant =~ s/^\s+//; $merchant =~ s/\s+$//; $merchant =~ s/^(the)\s+//i;
	return undef unless length $merchant;
	return { amount => $amount, merchant => $merchant };
}

sub payable_dismissed_keys {
	my $list = eval { decode_json &subs::setting_grabber({ app => 'budget', setting => 'payable_dismissed' }) || '[]' } || [];
	return map { $_ => 1 } @{$list};
}

sub payable_dismiss_add {
	my @keys = grep { defined $_ && length $_ } @_;
	return 0 unless scalar @keys;
	my $list = eval { decode_json &subs::setting_grabber({ app => 'budget', setting => 'payable_dismissed' }) || '[]' } || [];
	my %have = map { $_ => 1 } @{$list};
	my $changed = 0;
	foreach my $key ( @keys ) {
		next if $have{$key}++;
		push @{$list}, $key;
		$changed++;
	}
	&subs::setting_setter({ app => 'budget', setting => 'payable_dismissed', value => encode_json($list) }) if $changed;
	return $changed;
}

sub notification_same_day {
	my ($a,$b) = @_;
	return 0 unless $a && $b;
	my @x = localtime(int($a / 1000));
	my @y = localtime(int($b / 1000));
	return ($x[5] == $y[5] && $x[4] == $y[4] && $x[7] == $y[7]) ? 1 : 0;
}

sub notification_already_recorded {
	my ($n,$payment,$account) = @_;
	my $timestamp = ($n->{'timestamp'} || 0) + 0;
	return 0 unless $timestamp;
	my $rows = &subs::db_query(
		"select vendor, item, timestamp from warehouse where kind='money' and type='transaction' and movement='expense' and account=? and abs(cast(total as real) + ?) < 0.005 and abs(cast(timestamp as integer) - ?) <= ? limit 20",
		$account, $payment->{'amount'}, $timestamp, 36 * 3600000)->hashes || [];
	return 0 unless scalar @{$rows};
	my %want = map { $_ => 1 } &bank_merchant_tokens($payment->{'merchant'});
	foreach my $row ( @{$rows} ) {
		next unless &notification_same_day(($row->{'timestamp'} || 0) + 0, $timestamp);
		my @known = &bank_merchant_tokens($row->{'vendor'} || $row->{'item'} || '');
		# a recorded row that names a merchant has to name this one; a row that
		# names nothing is taken on the amount and the day alone
		return 1 if scalar @known && grep { $want{$_} } @known;
		return 1 unless scalar @known;
	}
	return 0;
}

sub notification_payable_autobook {
	my $rows = shift;
	$rows = &subs::db_query('select * from notifications order by cast(timestamp as integer) desc limit 400')->hashes || [] unless $rows;
	my %dismissed = &payable_dismissed_keys();
	my ($memory,$made);
	foreach my $n ( @{$rows} ) {
		my $payment = &notification_payment_of($n);
		next unless $payment;
		my $key = $n->{'key'} || $n->{'uuid'};
		next unless $key && length $key;
		next if $dismissed{$key};
		my $account = &notification_account($n);
		next unless $account;
		my $bill_uuid = &notification_bill_uuid($n);
		next if &subs::db_query("select 1 from warehouse where kind='money' and uuid=? limit 1", $bill_uuid)->hashes->[0];
		next if &notification_already_recorded($n, $payment, $account);
		$memory = &bank_merchant_memory() unless defined $memory;
		my $suggestion = &bank_merchant_lookup($memory, $payment->{'merchant'}, 'expense');
		my $app = $suggestion ? ($suggestion->{'app'} || '') : '';
		$app = &subs::unformat_name($payment->{'merchant'}) unless length $app;
		$app = 'unknown' unless length $app;
		my $vendor = &subs::unformat_name($payment->{'merchant'});
		# a title like "Transaction made" names no item; the vendor is the item then
		my $item = &subs::unformat_name($n->{'title'} || '');
		$item = '' if $item =~ /^transaction_made$/i;
		my $timestamp = ($n->{'timestamp'} || 0) + 0;
		$timestamp = &subs::rightNow() unless $timestamp;
		my $currency = &subs::setting_grabber({ app => $app, setting => 'currency' });
		$currency = &subs::setting_grabber({ app => $account, setting => 'currency' }) unless defined $currency && length $currency;
		&subs::db_insert('warehouse', {
			kind => 'money', type => 'transaction', movement => 'payable',
			account => 'accounts_payable', app => $app, vendor => $vendor, item => $item,
			amount => $payment->{'amount'}, tax => 0, total => $payment->{'amount'},
			currency => $currency,
			uuid => $bill_uuid, source_uuid => $key,
			timestamp => $timestamp, server_time => &subs::rightNow()
		});
		&subs::db_insert('warehouse', {
			kind => 'money', type => 'transaction', movement => 'payment',
			account => $account, app => $app, vendor => $vendor, item => $item,
			amount => $payment->{'amount'} * -1, total => $payment->{'amount'} * -1,
			currency => $currency,
			source_uuid => $bill_uuid, uuid => 'notepay-' . &subs::md5_sum($key),
			timestamp => $timestamp, server_time => &subs::rightNow()
		});
		$made++;
	}
	return $made || 0;
}

sub notification_booked_bills {
	my $limit = shift || 10;
	my $rows = &subs::db_query("select w.*, (select p.account from warehouse p where p.kind='money' and p.movement='payment' and p.source_uuid=w.uuid order by p.timestamp limit 1) as pay_account from warehouse w where w.kind='money' and w.movement='payable' and substr(w.uuid,1,5)='note-' order by cast(w.timestamp as integer) desc limit ?", $limit)->hashes || [];
	return $rows;
}

sub accounting_journal_report {
	my ($accounts,$from,$to,$pfrom,$pto) = @_;
	my @selected = grep { defined $_ && length $_ } @{$accounts || []};
	my $filter = ' and (j.account = \'\' or j.account = \'accounts_payable\'' .
		(scalar @selected ? ' or j.account in (' . join(',', map { '?' } @selected) . ')' : '') . ')';
	my $window = sub {
		my ($a,$b) = @_;
		return &subs::db_query(
			'select j.account_code, a.name, a.type, ' .
			'sum(cast(j.debit as real)) as d, sum(cast(j.credit as real)) as c ' .
			'from journal j left join ledger_accounts a on a.code = j.account_code ' .
			'where cast(j.timestamp as integer) >= cast(? as integer) and cast(j.timestamp as integer) <= cast(? as integer)' . $filter .
			' group by j.account_code, a.name, a.type', $a, $b, @selected)->hashes || [];
	};
	my $cur = $window->($from,$to);
	my $pri = $window->($pfrom,$pto);
	my (%income,%expense,%cogs,%pincome,%pexpense,%pcogs);
	my %names;
	my ($tax_in,$tax_out,$ptax_in,$ptax_out) = (0,0,0,0);
	foreach my $pair ( [ $cur, \%income, \%expense, \%cogs, \$tax_in, \$tax_out ],
		[ $pri, \%pincome, \%pexpense, \%pcogs, \$ptax_in, \$ptax_out ] ) {
		my ($rows,$inc,$exp,$cog,$tin,$tout) = @{$pair};
		foreach my $r ( @{$rows} ) {
			my $code = $r->{'account_code'};
			my $name = $r->{'name'} || $code;
			my $type = $r->{'type'} || '';
			my $d = ($r->{'d'} || 0) + 0;
			my $c = ($r->{'c'} || 0) + 0;
			$names{$code} = $name;
			if ($type eq 'income') { $inc->{$code} += $c - $d; }
			elsif ($type eq 'expense') {
				if ($code =~ /^6/) { $cog->{$code} += $d - $c; }
				else { $exp->{$code} += $d - $c; }
			}
			elsif ($code eq '2100') { $$tin += $c; $$tout += $d; }
		}
	}
	my $rows_for = sub {
		my ($now,$before) = @_;
		my @out;
		foreach my $code ( sort keys %{$now} ) {
			my $amount = $now->{$code};
			my $prior = $before->{$code} || 0;
			next if abs($amount) < 0.005 && abs($prior) < 0.005;
			push @out, { code => $code, name => ($names{$code} || $code), amount => $amount, prior => $prior };
		}
		return [ sort { $b->{'amount'} <=> $a->{'amount'} } @out ];
	};
	my $income_rows = $rows_for->(\%income,\%pincome);
	my $cogs_rows = $rows_for->(\%cogs,\%pcogs);
	my $expense_rows = $rows_for->(\%expense,\%pexpense);
	my $sum = sub { my $t = shift; my $s = 0; $s += $_ for values %{$t}; return $s; };
	my ($income_total,$cogs_total,$expense_total) = ($sum->(\%income),$sum->(\%cogs),$sum->(\%expense));
	my ($pincome_total,$pcogs_total,$pexpense_total) = ($sum->(\%pincome),$sum->(\%pcogs),$sum->(\%pexpense));
	# the balance sheet: the journal's own account balances at the moment
	my $bal = &subs::db_query(
		'select j.account_code, a.name, a.type, sum(cast(j.debit as real)) as d, sum(cast(j.credit as real)) as c ' .
		'from journal j left join ledger_accounts a on a.code = j.account_code ' .
		'where cast(j.timestamp as integer) <= cast(? as integer)' . $filter .
		' group by j.account_code, a.name, a.type', $to, @selected)->hashes || [];
	my (@asset_rows,@liability_rows);
	my ($assets,$liabilities,$receivables_balance) = (0,0,0);
	foreach my $r ( @{$bal} ) {
		my $code = $r->{'account_code'};
		my $type = $r->{'type'} || '';
		my $net = (($r->{'d'} || 0) + 0) - (($r->{'c'} || 0) + 0);
		next if abs($net) < 0.005;
		my $name = $r->{'name'} || $code;
		if ($type eq 'asset') {
			if ($code eq '1100') { $receivables_balance = $net; next; }
			if ($net > 0) { push @asset_rows, { code => $code, name => $name, balance => $net }; $assets += $net; }
			else { push @liability_rows, { code => $code, name => $name, balance => -$net }; $liabilities += -$net; }
		}
		elsif ($type eq 'liability') {
			my $owed = -$net;
			if ($owed > 0) { push @liability_rows, { code => $code, name => $name, balance => $owed }; $liabilities += $owed; }
			else { push @asset_rows, { code => $code, name => $name, balance => -$owed }; $assets += -$owed; }
		}
	}
	@asset_rows = sort { $a->{'code'} <=> $b->{'code'} } @asset_rows;
	@liability_rows = sort { $a->{'code'} <=> $b->{'code'} } @liability_rows;
	$assets += $receivables_balance;
	return {
		income => $income_rows, cogs => $cogs_rows, expense => $expense_rows,
		income_total => $income_total, cogs_total => $cogs_total, expense_total => $expense_total,
		gross_profit => $income_total - $cogs_total,
		prior_income_total => $pincome_total, prior_cogs_total => $pcogs_total, prior_expense_total => $pexpense_total,
		prior_gross_profit => $pincome_total - $pcogs_total,
		tax_in => $tax_in, tax_out => $tax_out,
		assets => \@asset_rows, liabilities => \@liability_rows,
		assets_total => $assets, liabilities_total => $liabilities,
		receivables_balance => $receivables_balance
	};
}

sub accounting_reports {
	my $args = shift;
	my $accounts = $args->{'accounts'} || [];
	my ($from,$to) = (($args->{'from'} || 0) + 0, ($args->{'to'} || 0) + 0);
	my $span = $to - $from;
	$span = 1 if $span <= 0;
	my ($pfrom,$pto) = ($from - $span, $from);
	my $moves = &accounting_moves($accounts, $from, $to);
	my $prior = &accounting_moves($accounts, $pfrom, $pto);
	# the statements' accrual side is the journal; bring it up to date first
	&subs::accounting_journal_maybe_rebuild();
	my $accrual = &accounting_journal_report($accounts, $from, $to, $pfrom, $pto);
	my $income_total = $accrual->{'income_total'};
	my $expense_total = $accrual->{'expense_total'};
	my $cogs_total = $accrual->{'cogs_total'};
	my $prior_income_total = $accrual->{'prior_income_total'};
	my $prior_expense_total = $accrual->{'prior_expense_total'};
	my $prior_cogs_total = $accrual->{'prior_cogs_total'};
	my @income_rows = @{$accrual->{'income'}};
	my @expense_rows = @{$accrual->{'expense'}};
	my @cogs_rows = @{$accrual->{'cogs'}};
	# every account's own activity in the window, opening to closing
	my @activity;
	my ($cash_opening,$cash_closing,$cash_prior_opening) = (0,0,0);
	foreach my $a ( sort @{$accounts} ) {
		my $opening = &bank_ledger_balance($a, $from);
		my $closing = &bank_ledger_balance($a, $to);
		my ($in,$out,$transfer) = (0,0,0);
		foreach my $t ( @{$moves} ) {
			next unless (($t->{'account'} || '') eq $a);
			my $total = ($t->{'total'} || 0) + 0;
			if (($t->{'movement'} || '') eq 'income') { $in += $total; }
			elsif (($t->{'movement'} || '') eq 'expense') { $out += -$total; }
			elsif (($t->{'movement'} || '') eq 'payment') { $out += -$total; }
			elsif (($t->{'movement'} || '') eq 'transfer') { $transfer += $total; }
		}
		$cash_opening += $opening;
		$cash_closing += $closing;
		$cash_prior_opening += &bank_ledger_balance($a, $pfrom);
		push @activity, { app => $a, opening => $opening, in => $in, out => $out, transfer => $transfer, closing => $closing };
	}
	# cash flow: the operating moves, the transfers' net, and whatever the
	# inventory anchors changed (the residual is what makes it tie)
	my ($op_in,$op_out,$transfers) = (0,0,0);
	foreach my $t ( @{$moves} ) {
		my $total = ($t->{'total'} || 0) + 0;
		if (($t->{'movement'} || '') eq 'income') { $op_in += $total; }
		elsif (($t->{'movement'} || '') eq 'expense') { $op_out += -$total; }
		elsif (($t->{'movement'} || '') eq 'payment') { $op_out += -$total; }
		elsif (($t->{'movement'} || '') eq 'transfer') { $transfers += $total; }
	}
	my ($prior_in,$prior_out,$prior_transfers) = (0,0,0);
	foreach my $t ( @{$prior} ) {
		my $total = ($t->{'total'} || 0) + 0;
		if (($t->{'movement'} || '') eq 'income') { $prior_in += $total; }
		elsif (($t->{'movement'} || '') eq 'expense') { $prior_out += -$total; }
		elsif (($t->{'movement'} || '') eq 'payment') { $prior_out += -$total; }
		elsif (($t->{'movement'} || '') eq 'transfer') { $prior_transfers += $total; }
	}
	my $change = $cash_closing - $cash_opening;
	my $adjustment = $change - ($op_in - $op_out + $transfers);
	# the prior period closes where this one opens, so its closing cash is this
	# window's opening figure
	my $prior_change = $cash_opening - $cash_prior_opening;
	my $prior_adjustment = $prior_change - ($prior_in - $prior_out + $prior_transfers);
	# balance sheet: the journal's account balances; an overdrawn bank account
	# is a liability, and the receivable line is the journal's own 1100
	my $ar = &accounting_receivables($to);
	my @asset_rows = @{$accrual->{'assets'}};
	my @liability_rows = @{$accrual->{'liabilities'}};
	my $assets = $accrual->{'assets_total'};
	my $liabilities = $accrual->{'liabilities_total'};
	return {
		income => \@income_rows,
		expense => \@expense_rows,
		cogs => \@cogs_rows,
		income_total => $income_total,
		expense_total => $expense_total,
		cogs_total => $cogs_total,
		gross_profit => $income_total - $cogs_total,
		prior_gross_profit => $prior_income_total - $prior_cogs_total,
		prior_cogs_total => $prior_cogs_total,
		net_income => $income_total - $cogs_total - $expense_total,
		prior_income_total => $prior_income_total,
		prior_expense_total => $prior_expense_total,
		prior_net_income => $prior_income_total - $prior_cogs_total - $prior_expense_total,
		tax_in => $accrual->{'tax_in'},
		tax_out => $accrual->{'tax_out'},
		activity => \@activity,
		activity_totals => { opening => $cash_opening, in => $op_in, out => $op_out, transfer => $transfers, closing => $cash_closing },
		assets => \@asset_rows,
		liabilities => \@liability_rows,
		assets_total => $assets,
		liabilities_total => $liabilities,
		equity => $assets - $liabilities,
		receivables => $ar,
		receivables_balance => $accrual->{'receivables_balance'},
		cash => {
			opening => $cash_opening,
			closing => $cash_closing,
			in => $op_in,
			out => $op_out,
			transfers => $transfers,
			change => $change,
			adjustment => $adjustment,
			prior_opening => $cash_prior_opening,
			prior_closing => $cash_opening,
			prior_in => $prior_in,
			prior_out => $prior_out,
			prior_transfers => $prior_transfers,
			prior_change => $prior_change,
			prior_adjustment => $prior_adjustment
		}
	};
}

sub payable_amount {
	my $value = shift;
	$value = '' unless defined $value;
	$value =~ s/[^0-9.\-]//g;
	return $value + 0;
}

sub budget_value_formatter {
	my ($circumstance, $value) = @_;
	my $mode = $gb::budget_modes->{$circumstance};
	if ($mode && $mode->{'formatted'}) {
		my $formatted = eval { &{$mode->{'formatted'}}($value) };
		return $formatted if defined $formatted;
	}
	return sprintf("%.3f", $value) . $circumstance;
}

sub budget_current_information($app,$circumstance,$timestamp) {

	my $autocalc = &subs::cache_get({ app => $app, context => 'autocalc', subcontext => $circumstance });
	my $budget = &subs::cache_get({ app => $app, context => 'budget', subcontext => $circumstance });
	unless ($autocalc->{$budget}) {
		$autocalc = &Manager::budget_autocalc({
			app => $app,
			circumstance => $circumstance,
		});
	}

	# A duration reading is a live meter while a session runs: the watcher only
	# passes every twenty minutes, and a light is otherwise redrawn only on a
	# start or stop, so an open panel would stand still while the session grows.
	# Re-read it at the moment the panel is asked for; the cache is left to the
	# watcher, so a poll cannot race it or leave a reading behind as the budget.
	# The panel is told whether it is live so its browser side can follow the
	# session without reading the header, which can lag behind the write.
	my $running = &subs::open_session_uuid($app) ? 1 : 0;
	if ($circumstance eq 'duration' && ($budget->{'budget'} || '') =~ /[0-9]/ && $running) {
		my $fresh = eval { return &budget_calculator({
			app => $app,
			circumstance => $circumstance,
			scope => $budget->{'scope_name'},
			budget => $budget->{'budget'},
		}) };
		$budget = $fresh if $fresh && ($fresh->{'is_scope'} || '') eq 'yes' && ($fresh->{'circumstance'} || '') eq $circumstance;
	}

	# Both comparisons are read for the same share of the period, so an hour or a
	# day only part done is not held against the whole of its budget and its whole
	# typical. A completed (or rolling) window has share 1 and reads as before.
	my $share = (defined $budget->{'elapsed'} && $budget->{'elapsed'} >= 0 && $budget->{'elapsed'} < 1) ? $budget->{'elapsed'} : 1;
	my $typical = $autocalc->{$budget->{'scope_name'}}->{'result'} || 0;
	my $budget_share = ($budget->{'budgeted'} || 0) * $share;
	# a duration target is held against the real window (25h/169h when the clocks
	# change), so its share widens with the day or week it belongs to
	if ($circumstance eq 'duration' && defined $budget->{'full_expected'} && defined $budget->{'scope'}) {
		$budget_share = $budget->{'full_expected'} * $budget->{'scope'} * $share;
	}
	my $typical_share = $typical * $share;
	my $value = $budget->{'value'} || 0;
	my $ov = sprintf("%.5f", $typical_share - $budget_share);
	my $improvement = {
		share => $share,
		difference => $value - $budget_share,
		overall_value => $ov,
		overall => &budget_value_formatter($circumstance, $ov),
		formatted_difference => &budget_value_formatter($circumstance, $value - $budget_share),
		percentage => eval { return &subs::percent_formatter(($value - $budget_share) / $typical_share) } || 0,
		overall_percentage => eval { return &subs::percent_formatter(($typical_share - $budget_share) / $typical_share) } || 0
	};
	my $goal = &goal_reading($app, $circumstance);
	my $c = &subs::controller_builder();
	my $template = $c->render_to_string(
		template => 'apps/budget_current_information',
		circumstance => $circumstance,
		improvement => $improvement,
		budget => $budget,
		autocalc => $autocalc,
		goal => $goal,
		running => $running
	);
	return { template => $template, circumstance => $circumstance, improvement => $improvement, autocalc => $autocalc, budget => $budget, goal => $goal, running => $running };
}

1;
