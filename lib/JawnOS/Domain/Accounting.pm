package subs;

# Accounting: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

# --- Double-entry journal ---------------------------------------------------
# A chart of accounts seeded from the money accounts and the apps that carry
# income and expenses, and a journal that posts every money move once with the
# other side on the account that earned or spent it. The journal is derived: a
# rebuild is deterministic (every entry is keyed by its source row's uuid), and
# both tables stay off the sync list, so each machine builds its own from the
# data it already holds.
our %accounting_account_cache;
our $database;
our $device;
our $gb;
our %m;

# Rebuild the whole journal from the ledger and the documents. Every entry is
# keyed by its source uuid, so the same data always yields the same journal.
sub accounting_journal_rebuild {
	&db_query('delete from journal');
	%accounting_account_cache = ();
	my %bank;
	my $account_rows = &db_query("select distinct(app) as app from settings where setting in ('pos','mab') and value='account' order by app")->hashes || [];
	foreach my $row ( @{$account_rows} ) { $bank{$row->{'app'}} = &accounting_bank_account($row->{'app'}); }
	my $ar = &accounting_account_ensure(1100, 'Accounts Receivable', 'asset', 'debit', '');
	my $inventory = &accounting_account_ensure(1200, 'Inventory', 'asset', 'debit', '');
	my $clearing = &accounting_account_ensure(1900, 'Transfers Clearing', 'asset', 'debit', '');
	my $ap = &accounting_account_ensure(2000, 'Accounts Payable', 'liability', 'credit', '');
	my $tax_account = &accounting_account_ensure(2100, 'Sales Tax Payable', 'liability', 'credit', '');
	my $equity = &accounting_account_ensure(3000, 'Opening Balance Equity', 'equity', 'credit', '');
	my $adjust = &accounting_account_ensure(3900, 'Balance Adjustments', 'equity', 'credit', '');
	my $cogs = &accounting_account_ensure(6000, 'Cost of Goods Sold', 'expense', 'debit', '');
	$bank{'accounts_payable'} = $ap;
	# only an item the warehouse actually stocks is inventory; a personal vape
	# purchase stays an expense
	my %stocked;
	my $stock_items = &db_query("select distinct(item) as item from warehouse where kind='stock' and item is not null and item != ''")->hashes || [];
	foreach my $row ( @{$stock_items} ) { $stocked{$row->{'item'}} = 1; }
	my (%inv_qty,%inv_value);

	my $money = &db_query("select * from warehouse where kind='money' and type='transaction' and movement != 'inventory' order by cast(timestamp as integer)")->hashes || [];
	my $invoices = &db_query("select * from appointments where type='invoice' order by cast(timestamp as integer)")->hashes || [];
	my $anchors = &db_query("select * from appointments where movement='inventory' and type='transaction' order by cast(timestamp as integer)")->hashes || [];

	# a transaction that settles an invoice is cash against the receivable, not
	# new revenue; the invoice itself carried the revenue
	my %pay_of;
	foreach my $inv ( @{$invoices} ) {
		my $data = eval { decode_json $inv->{'data'} } || {};
		foreach my $p ( @{$data->{'payments'} || []} ) {
			$pay_of{$p->{'appt_uuid'}} = 1 if $p->{'appt_uuid'};
		}
	}

	# pair the two legs of a transfer when both are present; an unpaired leg
	# posts against the clearing account and shows up there
	my %transfer;
	foreach my $m ( @{$money} ) { $transfer{$m->{'uuid'}} = $m if (($m->{'movement'} || '') eq 'transfer'); }
	my %paired;
	my @pairs;
	foreach my $m ( @{$money} ) {
		next unless (($m->{'movement'} || '') eq 'transfer');
		next if $paired{$m->{'uuid'}};
		my $other;
		if ($m->{'source_uuid'} && $transfer{$m->{'source_uuid'}} && !$paired{$m->{'source_uuid'}}) {
			$other = $transfer{$m->{'source_uuid'}};
		}
		next unless $other;
		$paired{$m->{'uuid'}} = 1;
		$paired{$other->{'uuid'}} = 1;
		my ($neg,$pos) = (($m->{'total'} || 0) < 0) ? ($m,$other) : ($other,$m);
		push @pairs, { neg => $neg, pos => $pos };
	}

	my @events;
	foreach my $pair ( @pairs ) { push @events, [ ($pair->{'neg'}->{'timestamp'} || 0) + 0, 0, 'pair', $pair ]; }
	foreach my $m ( @{$money} ) { push @events, [ ($m->{'timestamp'} || 0) + 0, 0, 'money', $m ] unless $paired{$m->{'uuid'}}; }
	foreach my $inv ( @{$invoices} ) { push @events, [ ($inv->{'timestamp'} || 0) + 0, 1, 'invoice', $inv ]; }
	foreach my $a ( @{$anchors} ) { push @events, [ ($a->{'timestamp'} || 0) + 0, 2, 'anchor', $a ]; }
	@events = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @events;

	my $lines = 0;
	foreach my $event ( @events ) {
		my ($ts,$pri,$kind,$row) = @{$event};
		if ($kind eq 'money') {
			my $account = $row->{'account'} || '';
			next unless length $account;
			my $code = $bank{$account} ||= &accounting_bank_account($account);
			my $movement = $row->{'movement'} || '';
			my $total = ($row->{'total'} || 0) + 0;
			my $app = $row->{'app'} || 'unknown';
			my $item = $row->{'item'} || '';
			my $qty = (($row->{'quantity'} || 0) + 0);
			my $entry = 'm-' . $row->{'uuid'};
			my @lines;
			if ($pay_of{$row->{'uuid'}}) {
				@lines = $total >= 0
					? ([$code,$total,0],[$ar,0,$total])
					: ([$ar,abs($total),0],[$code,0,abs($total)]);
			}
			elsif ($movement eq 'income') {
				if ($total >= 0) {
					my $tax_part = ($row->{'tax'} || 0) + 0;
					$tax_part = 0 if $tax_part < 0;
					my $revenue = $total - $tax_part;
					push @lines, [$code,$total,0], [&accounting_app_account($app,'income'),0,$revenue];
					push @lines, [$tax_account,0,$tax_part] if $tax_part > 0.004;
					# a stocked item sold carries its cost out of inventory
					if ($stocked{$item} && $qty > 0) {
						my $average = $inv_qty{$item} > 0 ? $inv_value{$item} / $inv_qty{$item} : 0;
						my $sold_cost = $average * $qty;
						if ($sold_cost > 0.004) {
							push @lines, [$cogs,$sold_cost,0], [$inventory,0,$sold_cost];
							$inv_qty{$item} -= $qty;
							$inv_value{$item} -= $sold_cost;
						}
					}
				}
				else {
					@lines = ([&accounting_app_account($app,'income'),abs($total),0],[$code,0,abs($total)]);
				}
			}
			elsif ($movement eq 'expense') {
				if ($total <= 0) {
					# the tax in the price is an input credit against the tax
					# collected, so the expense carries the net and the tax account
					# carries the tax
					my $tax_part = abs(($row->{'tax'} || 0) + 0);
					my $cost = abs($total) - $tax_part;
					$cost = 0 if $cost < 0;
					if ($stocked{$item} && $qty > 0) {
						# a stocked purchase adds to inventory, not to the expense
						push @lines, [$inventory,$cost,0];
						$inv_qty{$item} += $qty;
						$inv_value{$item} += $cost;
					}
					else {
						push @lines, [&accounting_app_account($app,'expense'),$cost,0];
					}
					push @lines, [$tax_account,$tax_part,0] if $tax_part > 0.004;
					push @lines, [$code,0,abs($total)];
				}
				else {
					@lines = ([$code,$total,0],[&accounting_app_account($app,'expense'),0,$total]);
				}
			}
			elsif ($movement eq 'transfer') {
				@lines = $total >= 0
					? ([$code,$total,0],[$clearing,0,$total])
					: ([$clearing,abs($total),0],[$code,0,abs($total)]);
			}
			elsif ($movement eq 'payable') {
				# a bill: the cost belongs to the day it was incurred, the cash
				# moves on the day it is paid
				my $owed = abs($total);
				my $tax_part = abs(($row->{'tax'} || 0) + 0);
				$tax_part = $owed if $tax_part > $owed;
				my $cost = $owed - $tax_part;
				push @lines, [&accounting_app_account($app,'expense'),$cost,0];
				push @lines, [$tax_account,$tax_part,0] if $tax_part > 0.004;
				push @lines, [$ap,0,$owed];
			}
			elsif ($movement eq 'payment') {
				# settling a bill: the payable goes down, the bank goes down
				my $paid = abs($total);
				@lines = ([$ap,$paid,0],[$code,0,$paid]);
			}
			else { next; }
			$lines += &accounting_journal_add($entry, $ts, \@lines, {
				memo => ($row->{'item'} || $row->{'app'} || ''),
				source_uuid => $row->{'uuid'}, source_kind => 'money',
				app => $app, account => $account, currency => ($row->{'currency'} || '')
			});
		}
		elsif ($kind eq 'pair') {
			my $neg = $row->{'neg'};
			my $pos = $row->{'pos'};
			my $from = $bank{$neg->{'account'}} ||= &accounting_bank_account($neg->{'account'});
			my $to = $bank{$pos->{'account'}} ||= &accounting_bank_account($pos->{'account'});
			my $amount = abs(($neg->{'total'} || 0) + 0);
			$lines += &accounting_journal_add('t-' . $neg->{'uuid'}, $ts,
				[ [$to,$amount,0], [$from,0,$amount] ], {
					memo => 'transfer between accounts',
					source_uuid => $neg->{'uuid'}, source_kind => 'transfer',
					app => ($neg->{'app'} || ''), account => ($neg->{'account'} || ''),
					currency => ($neg->{'currency'} || '')
				});
		}
		elsif ($kind eq 'invoice') {
			my $data = eval { decode_json $row->{'data'} } || {};
			my $numbers = $data->{'numbers'} || {};
			my $total = ($numbers->{'total'} || 0) + 0;
			next if abs($total) < 0.005;
			my $tax_part = ($numbers->{'tax'} || 0) + 0;
			my $revenue = $total - $tax_part;
			my $app = $data->{'item'} || $row->{'app'} || 'unknown';
			my @lines = ([$ar,$total,0], [&accounting_app_account($app,'income'),0,$revenue]);
			push @lines, [$tax_account,0,$tax_part] if abs($tax_part) > 0.004;
			$lines += &accounting_journal_add('i-' . $row->{'uuid'}, $ts, \@lines, {
				memo => ($data->{'id'} || $row->{'app'} || ''),
				source_uuid => $row->{'uuid'}, source_kind => 'invoice',
				app => $app, account => '', currency => ($row->{'currency'} || '')
			});
		}
		elsif ($kind eq 'anchor') {
			my $account = $row->{'account'} || '';
			next unless length $account;
			my $code = $bank{$account} ||= &accounting_bank_account($account);
			my $amount = ($row->{'amount'} || 0) + 0;
			my $sum = &db_query('select coalesce(sum(cast(debit as real)-cast(credit as real)),0) as s from journal where account_code=?', $code)->hashes->[0];
			my $current = ($sum->{'s'} || 0) + 0;
			my $diff = $amount - $current;
			next if abs($diff) < 0.005;
			my @lines = $diff > 0
				? ([$code,$diff,0],[$adjust,0,$diff])
				: ([$adjust,abs($diff),0],[$code,0,abs($diff)]);
			$lines += &accounting_journal_add('a-' . $row->{'uuid'}, $ts, \@lines, {
				memo => 'balance adjustment', source_uuid => $row->{'uuid'}, source_kind => 'anchor',
				app => $account, account => $account, currency => ''
			});
		}
	}
	return { entries => scalar @events, lines => $lines };
}

# Is the journal still the ledger's own picture? A missing source, a source
# deleted, or a source edited after the last rebuild all mean rebuild.
sub accounting_journal_stale {
	my $has = &db_query("select 1 from sqlite_master where type='table' and name='journal'")->hashes->[0];
	return 1 unless $has;
	my $missing = &db_query("select count(*) as n from warehouse w where kind='money' and type='transaction' and movement != 'inventory' and abs(cast(coalesce(total,0) as real)) > 0.004 and not exists (select 1 from journal j where j.source_uuid=w.uuid) and not (w.movement='transfer' and exists (select 1 from journal j where j.source_kind='transfer' and (j.source_uuid=w.uuid or j.source_uuid=w.source_uuid)))")->hashes->[0];
	return 1 if (($missing->{'n'} || 0) + 0) > 0;
	my $missing_doc = &db_query("select count(*) as n from appointments a where type='invoice' and abs(cast(coalesce(json_extract(a.data,'\$.numbers.total'),0) as real)) > 0.004 and not exists (select 1 from journal j where j.source_uuid=a.uuid and j.source_kind='invoice')")->hashes->[0];
	return 1 if (($missing_doc->{'n'} || 0) + 0) > 0;
	my $gone = &db_query("select count(*) as n from journal j where (j.source_kind='money' and not exists (select 1 from warehouse w where w.uuid=j.source_uuid)) or (j.source_kind='transfer' and not exists (select 1 from warehouse w where w.uuid=j.source_uuid)) or (j.source_kind='invoice' and not exists (select 1 from appointments a where a.uuid=j.source_uuid and a.type='invoice')) or (j.source_kind='anchor' and not exists (select 1 from appointments a where a.uuid=j.source_uuid and a.movement='inventory'))")->hashes->[0];
	return 1 if (($gone->{'n'} || 0) + 0) > 0;
	my $money_src = &db_query("select max(cast(server_time as integer)) as t from warehouse where kind='money' and type='transaction' and movement != 'inventory'")->hashes->[0];
	my $money_j = &db_query("select max(cast(server_time as integer)) as t from journal where source_kind='money'")->hashes->[0];
	return 1 if (($money_src->{'t'} || 0) + 0) > (($money_j->{'t'} || 0) + 0) + 2;
	my $doc_src = &db_query("select max(cast(server_time as integer)) as t from appointments where type='invoice' or (movement='inventory' and type='transaction')")->hashes->[0];
	my $doc_j = &db_query("select max(cast(server_time as integer)) as t from journal where source_kind in ('invoice','anchor')")->hashes->[0];
	return 1 if (($doc_src->{'t'} || 0) + 0) > (($doc_j->{'t'} || 0) + 0) + 2;
	return 0;
}

sub accounting_journal_maybe_rebuild {
	return { changed => 0 } unless &accounting_journal_stale();
	my $result = &accounting_journal_rebuild();
	$result->{'changed'} = 1;
	return $result;
}

# The trial balance as of a moment: each account's debit and credit balance.
sub accounting_trial_balance {
	my $to = shift || &rightNow();
	my $rows = &db_query(
		'select j.account_code, a.name, a.type, a.normal, ' .
		'sum(cast(j.debit as real)) as debit, sum(cast(j.credit as real)) as credit ' .
		'from journal j left join ledger_accounts a on a.code = j.account_code ' .
		'where cast(j.timestamp as integer) <= cast(? as integer) ' .
		'group by j.account_code, a.name, a.type, a.normal ' .
		'order by cast(j.account_code as integer), j.account_code', $to)->hashes || [];
	my @lines;
	my ($debit_total,$credit_total) = (0,0);
	foreach my $r ( @{$rows} ) {
		my $net = (($r->{'debit'} || 0) + 0) - (($r->{'credit'} || 0) + 0);
		my $dr = $net > 0.004 ? $net : 0;
		my $cr = $net < -0.004 ? -$net : 0;
		next if $dr == 0 && $cr == 0;
		$debit_total += $dr;
		$credit_total += $cr;
		push @lines, {
			code => $r->{'account_code'}, name => ($r->{'name'} || $r->{'account_code'}),
			type => ($r->{'type'} || ''), normal => ($r->{'normal'} || 'debit'),
			debit => $dr, credit => $cr, net => $net
		};
	}
	return {
		lines => \@lines, debit_total => $debit_total, credit_total => $credit_total,
		difference => $debit_total - $credit_total,
		entries => (&db_query('select count(distinct entry_uuid) as n from journal where cast(timestamp as integer) <= cast(? as integer)', $to)->hashes->[0]->{'n'} || 0) + 0
	};
}

# ---------------------------------------------------------------------------
# Data backfills. Schema migrations can be detected by inspecting the schema
# (subs::migration_already_applied); a data backfill cannot, so it is named
# here and recorded in the `backfills` table once it has run. A machine that
# receives this code runs any names it has not recorded - from the boot process
# (President) and from update_database (login / remote auth / merge) - so a
# code sync followed by the usual restart heals the data without a manual step.
#
# An entry returns true when it has run (recorded), false when its
# prerequisites are not ready yet (left for the next pass, e.g. the column the
# schema migration adds is not there), and dies on a real error (logged).
# ---------------------------------------------------------------------------

# The warranty a guide message expires on: the appointment's own when the thread
# is scoped to an app (its conversation name is app_<name>), otherwise the house
# default. It lives here - not in Manager - so the backfill below can stamp old
# turns from the boot process too, before the Manager worker is loaded.
sub guide_message_warranty {
	my ($name) = @_;
	my $now = &subs::rightNow();
	my $default = &subs::ago_calc(&subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', $now);
	if ($name && $name =~ /^app_(.+)$/) {
		my $app = $1;
		my $rows = &subs::db_query('select warranty from appointments where app = ? order by timestamp desc limit 1', $app)->hashes;
		if (scalar @{$rows} && defined $rows->[0]->{'warranty'} && ($rows->[0]->{'warranty'} + 0) > 0) {
			return $rows->[0]->{'warranty'} + 0;
		}
	}
	return $default;
}

	sub backfills() {
	return {
		'accounting_journal_v1' => sub {
			# The double-entry journal is derived from the money ledger and the
			# invoices. Build it once the schema pass has made its tables; a machine
			# that receives the code before its first request waits one pass.
			my $has = &db_query("select 1 from sqlite_master where type='table' and name='journal'")->hashes->[0];
			return 0 unless $has;
			my $result = &accounting_journal_rebuild();
			&say_it('backfill accounting_journal_v1: ' . $result->{'entries'} . ' entries, ' . $result->{'lines'} . ' lines');
			return 1;
		},
		'password_share_retired' => sub {
			# The password is a login, not a recovery share. Delete the sealed
			# copy a previous version minted; three paper or device shares are
			# the way back in when this machine's key file is gone.
			&db_query('delete from settings where app = ? and setting = ?', '__president', 'password_share');
			return 1;
		},
		'evaluation_days_all' => sub {
			# The days list read as blank when every night was meant, so an app
			# already running on its own looked as if no day had been chosen.
			# Make the wish explicit for every scope with a timed cadence; a scope
			# with specific days is left as the person chose it.
			my $device = &subs::device_setter();
			my $rows = &subs::db_query("select distinct app from settings where device = ? and setting in ('evaluation_cadence','nightly_evaluation')", $device)->hashes || [];
			my (%seen, $n);
			foreach my $row ( @{$rows} ) {
				my $app = (defined $row->{'app'} && $row->{'app'} ne '') ? $row->{'app'} : '__president';
				next if $seen{$app}++;
				my $cadence = &subs::evaluation_cadence($app);
				next unless $cadence ne 'off' && $cadence ne 'each_run';
				my $days = &subs::setting_grabber({ app => $app, setting => 'nightly_evaluation_days', device => $device });
				next if defined $days && $days =~ /\S/;
				&subs::setting_setter({ app => $app, setting => 'nightly_evaluation_days', device => $device, value => '0,1,2,3,4,5,6' });
				$n++;
			}
			&subs::say_it("backfill evaluation_days_all: set " . ($n || 0) . " evaluation schedule(s) to all days");
			return 1;
		},
		'warranty_house_wide' => sub {
			# A warranty is one value for the house, not one per device (see
			# warranty_device). Older builds wrote a row per device and the machines
			# could disagree - driving held -70d on one and -70M on another. Collapse
			# each app to the value written most recently onto the house row. The
			# per-device rows are left in place, because a read that names a device
			# may still want them; the normal path ignores them once this has run.
			my $apps = &db_query("select distinct app from settings where setting = 'warranty' and device != ?", &warranty_device())->hashes || [];
			my $made = 0;
			foreach my $row ( @{$apps} ) {
				my $app = defined $row->{'app'} ? $row->{'app'} : '';
				next unless length $app;
				my $house = &db_query('select 1 from settings where app = ? and setting = ? and device = ?', $app, 'warranty', &warranty_device())->hashes->[0];
				next if $house;
				my $winner = &db_query(
					'select value from settings where app = ? and setting = ? and device != ? and value is not null and value != ? '
					. 'order by cast(coalesce(server_time, timestamp, 0) as integer) desc, cast(coalesce(timestamp, 0) as integer) desc limit 1',
					$app, 'warranty', &warranty_device(), ''
				)->hashes->[0];
				next unless $winner && defined $winner->{'value'} && length $winner->{'value'};
				my $now = &rightNow();
				&db_insert('settings', {
					app => $app,
					setting => 'warranty',
					value => $winner->{'value'},
					device => &warranty_device(),
					timestamp => $now,
					server_time => $now,
					uuid => &random_string_creator(20)
				});
				$made++;
			}
			&say_it('backfill warranty_house_wide: ' . $made . ' app warranty(s) collapsed to the house row');
			return 1;
		},
		'weather_rules_home_place' => sub {
			# The Weather app's automations were house-wide before the tab became
			# per-location; they are the home's rules. Pin each place-less rule to the
			# saved place at the home plate, once per machine, so every machine at home
			# shows and runs the same list. A house with no home place yet waits for
			# the next pass instead of recording a migration it did not make.
			return &subs::weather_automation_adopt_home() ? 1 : 0;
		},
		'person_owner_devices' => sub {
			# A device with no person is not a citizen. Attach the devices that
			# were paired after the people table existed but before this rule,
			# once; a device paired later waits for a citizen to assign it.
			my $owner = &people_owner_ensure();
			return 0 unless $owner;
			&db_query('update paired_devices set person_uuid = ? where person_uuid is null or person_uuid = ?', $owner, '');
			return 1;
		},
		'door_seed' => sub {
			# the login password gets its own row so the key can stay put when
			# the password changes; on an existing machine the password and the
			# key are one thing, so the key itself is the door password
			return 0 if &door_row();
			my @vault = &vault_read();
			my $vault = $vault[0];
			return 0 unless $vault && &suds_current($vault);
			return &door_set($vault) ? 1 : 0;
		},
		'suds_canary_reseal' => sub {
			# the level-1 canary on older databases can be data written with
			# the empty passphrase, in which case a db copy decrypts to the key
			# for free. Re-seal it to the key itself - and only once the door
			# row exists, because the resealed canary no longer leaks the way in.
			return 0 unless &door_row();
			my @vault = &vault_read();
			my $vault = $vault[0];
			return 0 unless $vault && &suds_current($vault);
			my $q = &db_select('security', ['uuid','credential'], { level => 1 });
			my $row = $q ? $q->hash : undef;
			return 0 unless $row;
			my $leak = &decrypter(undef, $row->{'credential'});
			return 1 unless defined $leak && length $leak && $leak eq $vault;
			my $sealed = &encrypter($vault, $vault);
			return 0 unless $sealed && &decrypter($vault, $sealed) eq $vault;
			&db_update('security', { credential => $sealed }, { uuid => $row->{'uuid'} });
			return &suds_current($vault) ? 1 : 0;
		},
		'ticket_suds_retire' => sub {
			# tickets no longer carry a copy of the house key: the vault is the
			# only place it lives. Only scrub where the vault validates, so a
			# machine that still needs the legacy chain keeps it.
			my @vault = &vault_read();
			my $vault = $vault[0];
			return 0 unless $vault && &suds_current($vault);
			&db_query("update tickets set suds = '' where suds is not null and suds != ''");
			return 1;
		},
		'construct_app_uuids' => sub {
			# The stable id each appointment now carries. The column is added by the
			# same migration pass; the guard keeps a peer's older command list from
			# failing this. One UPDATE per app, not per row.
			my $has = &db_query('select 1 from pragma_table_info(?) where name=?', 'appointments', 'app_uuid')->hashes->[0];
			return 0 unless $has;
			my $apps = &db_query("select distinct app from appointments where app is not null and app <> ''")->hashes || [];
			foreach my $row ( @{$apps} ) {
				my $app = $row->{'app'};
				my $uuid = &construct_uuid($app);
				next unless defined $uuid && length $uuid;
				&db_query("update appointments set app_uuid=? where app=? and (app_uuid is null or app_uuid='')", $uuid, $app);
			}
			return 1;
		},
		'warehouse_money_ledger' => sub {
			# needs the ledger column; defer until the schema migration has run
			my $has = &subs::db_query('select 1 from pragma_table_info(?) where name=?', 'warehouse', 'kind')->hashes->[0];
			return 0 unless $has;
			&subs::db_query("update warehouse set kind = 'inventory' where (kind is null or kind = '') and type = 'inventory'");
			&subs::db_query("update warehouse set kind = 'stock' where (kind is null or kind = '')");
			&subs::db_query("update warehouse set movement = 'inventory' where kind = 'inventory' and (movement is null or movement = '')");
			my $rows = &subs::db_query("select * from appointments where type in ('transaction','purchase') and account is not null and account != '' and (movement is null or movement != 'inventory')")->hashes;
			my $n = 0;
			foreach my $row ( @{$rows} ) {
				next if &subs::db_query('select uuid from warehouse where kind=? and uuid=? limit 1', 'money', $row->{'uuid'})->hashes->[0];
				&subs::warehouse_money_mirror($row);
				$n++;
			}
			&subs::say_it("backfill warehouse_money_ledger: mirrored $n money transactions");
			return 1;
		},
		'money_ledger_transaction_rows' => sub {
			# The mirror used to copy type='purchase' rows as well as transactions.
			# A purchase row is the vendor/item breakdown of the transaction it names
			# in source_uuid (or shares a uuid with), so the ledger held the same
			# payment twice - three times when both a vendor and an item row existed.
			# Remove those rows once; the transaction beside each one is the money
			# move and stays. Deleting only kind='money' rows leaves stock and balance
			# anchors alone.
			my $has = &subs::db_query('select 1 from pragma_table_info(?) where name=?', 'warehouse', 'kind')->hashes->[0];
			return 0 unless $has;
			my $rows = &subs::db_query("select uuid from warehouse where kind='money' and type is not null and type != 'transaction'")->hashes || [];
			my $n = 0;
			foreach my $row ( @{$rows} ) {
				&subs::db_query("delete from warehouse where kind='money' and uuid=? and type != 'transaction'", $row->{'uuid'});
				$n++;
			}
			&subs::say_it("backfill money_ledger_transaction_rows: removed $n duplicated purchase row(s)");
			return 1;
		},
		'mugshot_to_file' => sub {
			# The mugshot was a multi-megabyte data URI in settings, which every
			# load and every sync paid for. Hold it as a sealed picture under the
			# photo location's `me` folder instead. Only the owning device converts
			# its own row: the sealed file lives on this machine's disk and is not
			# synced, so a machine that converted another device's row would leave
			# that device pointing at a file only this one has.
			my $dev = &subs::device_setter();
			my $folder = &subs::setting_grabber({ app => 'misc', setting => 'photo_location', device => $dev });
			return 0 unless $folder;
			my $location = &subs::home($folder) . '/me';
			my $rows = &subs::db_query("select device,value from settings where app='me' and setting='mugshot' and device=?", $dev)->hashes;
			foreach my $row ( @{$rows} ) {
				my $val = $row->{'value'} // '';
				next unless $val =~ /^data:image\/\w+;base64,(.*)$/s;
				my $img = MIME::Base64::decode_base64($1);
				next unless $img && length $img;
				system('mkdir', '-p', $location) unless -e $location;
				my $raw = "$location/mugshot.$dev.png";
				write_file($raw, $img);
				my $secret = &subs::suds_grabber();
				my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
				&openssl_file_crypt('e', $standard, $secret, $raw, "$location/mugshot.$dev.png.enc", 0, 1);
				system('shred', '-u', $raw);
				&subs::setting_setter({ app => 'me', setting => 'mugshot', device => $dev, value => "mugshot.$dev.png.enc" });
			}
			return 1;
		},
		'guess_to_me_folder' => sub {
			# A guessed map's picture was a loose png in the travel folder; it is
			# held sealed under the photo location's `me` folder now - the place the
			# mugshot lives - which is where the atlas and the delete path read it
			# from. Only the owning device converts its own rows: the sealed file
			# lives on this machine's disk and is not synced.
			my $dev = &subs::device_setter();
			my $folder = &subs::setting_grabber({ app => 'misc', setting => 'photo_location', device => $dev });
			return 0 unless $folder;
			my $row = &subs::db_select('settings', undef, { app => 'travel', setting => 'maps', device => $dev })->hashes->[0];
			return 1 unless $row;
			my $maps = eval { return decode_json $row->{'value'} } || [];
			my $location = &subs::home($folder) . '/me';
			my $secret = &subs::suds_grabber();
			my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
			my (@converted, $failed);
			foreach my $map ( @{$maps} ) {
				next unless $map->{'guessed'} && $map->{'f'};
				next if $map->{'f'} =~ /\.enc$/;
				next unless -e $map->{'f'};
				my $bytes = eval { read_file($map->{'f'}) };
				next unless $bytes && length $bytes;
				system('mkdir', '-p', $location) unless -e $location;
				my $raw = $location . '/guess_' . $map->{'uuid'} . '.png';
				my $sealed = $location . '/guess_' . $map->{'uuid'} . '.png.enc';
				write_file($raw, $bytes);
				&openssl_file_crypt('e', $standard, $secret, $raw, $sealed, 0, 1);
				unless (-e $sealed && -s $sealed) { unlink $raw; $failed++; next; }
				system('shred', '-u', $raw);
				push @converted, [ $map->{'uuid'}, $map->{'f'}, $sealed ];
				$map->{'f'} = $sealed;
			}
			if (@converted) {
				&subs::setting_setter({ app => 'travel', setting => 'maps', device => $dev, value => encode_json $maps });
				# the record has to name the sealed copy before the loose one is let
				# go, so a setter that did not land leaves a working picture behind
				my $now = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps', device => $dev }) } || [];
				my %sealed_for = map { $_->{'uuid'} => $_->{'f'} } @{$now};
				my $n = 0;
				foreach my $c ( @converted ) {
					my ($uuid, $old, $sealed) = @{$c};
					next unless ($sealed_for{$uuid} || '') eq $sealed;
					unlink $old if $old =~ m{/guess_[^/]+\.png$};
					$n++;
				}
				&subs::say_it("backfill guess_to_me_folder: sealed $n guess picture(s) into $location");
			}
			return $failed ? 0 : 1;
		},
		'guide_message_warranty' => sub {
			# Guide turns were saved before each message carried its own warranty;
			# stamp the ones missing it so they age out the way everything else does.
			my $rows = &subs::db_query("select setting, value from settings where app = ? and setting like ?", '__president', 'guide_conversation_%')->hashes;
			my $n = 0;
			foreach my $row ( @{$rows} ) {
				my $setting = $row->{'setting'} // '';
				next unless $setting =~ /^guide_conversation_(.+)$/;
				my $name = $1;
				my $transcript = eval { decode_json $row->{'value'} } || [];
				$transcript = [] unless ref $transcript eq 'ARRAY';
				my $warranty = &guide_message_warranty($name);
				my $changed = 0;
				foreach my $m ( @{$transcript} ) {
					next if defined $m->{'warranty'};
					$m->{'warranty'} = $warranty;
					$changed++;
				}
				next unless $changed;
				&subs::setting_setter({ app => '__president', setting => 'guide_conversation_' . $name, value => encode_json $transcript });
				$n += $changed;
			}
			&subs::say_it("backfill guide_message_warranty: stamped $n guide message(s)");
			return 1;
		},
		'relationship_types_v1' => sub {
			# Relationships are one of friend/stranger/enemy now, numbered on the
			# place scale. The old multiple_select lists and their words are mapped
			# (the most negative word in a list wins), so a person's card opens on
			# the right choice instead of a blank select.
			my $rows = &db_query("select uuid, app, value from settings where setting = 'app_measures' and value like '%relationship%'")->hashes || [];
			my $n = 0;
			foreach my $row ( @{$rows} ) {
				my $am = eval { decode_json($row->{'value'}) } || {};
				next unless ref $am eq 'HASH' && exists $am->{'relationship'};
				my $old = ref $am->{'relationship'} eq 'HASH' ? $am->{'relationship'}->{'value'} : $am->{'relationship'};
				my $new = &subs::relationship_value($old);
				# The stored measure definition is old (a multiple_select with the long
				# word list). Replace it with the single select gb.pl now declares, so
				# the card is one choice even before the render-time override runs.
				my $gb_rel = $gb::pos->{'person'}->{'app_measures'}->{'relationship'};
				my %def = ref $gb_rel eq 'HASH' ? %{$gb_rel} : ( type => 'select', options => [ 'friend', 'stranger', 'enemy' ], ratings => { friend => 1, stranger => 2, enemy => 3 } );
				$def{'value'} = $new if length $new;
				$am->{'relationship'} = \%def;
				&db_update('settings', { value => encode_json($am), server_time => &rightNow() }, { uuid => $row->{'uuid'} });
				$n++;
			}
			&visibility_cache_clear();
			&say_it("backfill relationship_types_v1: normalised $n relationship value(s)");
			return 1;
		},
		'relationship_setting_v1' => sub {
			# A relationship is a configuration setting now, not an app measure.
			# Move the old measure value onto the direct house-wide row, then remove
			# the measure key so the measure editor cannot rewrite it.
			my $rows = &db_query("select uuid, app, value from settings where setting = 'app_measures' and value like '%relationship%'")->hashes || [];
			my $n = 0;
			foreach my $row ( @{$rows} ) {
				my $am = eval { decode_json($row->{'value'}) } || {};
				next unless ref $am eq 'HASH' && exists $am->{'relationship'};
				my $old = ref $am->{'relationship'} eq 'HASH' ? $am->{'relationship'}->{'value'} : $am->{'relationship'};
				my $value = &subs::relationship_value($old);
				my $existing = &db_query("select value from settings where app = ? and setting = 'relationship' and device = 'all' order by cast(server_time as integer) desc limit 1", $row->{'app'})->hashes->[0];
				&subs::setting_setter({ app => $row->{'app'}, setting => 'relationship', value => $value, device => 'all' }) unless $existing;
				delete $am->{'relationship'};
				if (scalar keys %{$am}) {
					&db_update('settings', { value => encode_json($am), server_time => &rightNow() }, { uuid => $row->{'uuid'} });
				}
				else {
					&db_delete('settings', { uuid => $row->{'uuid'} });
				}
				$n++;
			}
			&visibility_cache_clear();
			&say_it("backfill relationship_setting_v1: moved $n relationship(s) onto settings");
			return 1;
		},
		'visibility_levels_v1' => sub {
			# Visibility is private/public/dangerous now. The old checkbox words and
			# the retired on/off map to the three levels: checked/on to public (the
			# new default), unchecked/off to private (the least visible level).
			my $rows = &db_query("select uuid, app, value from settings where setting = 'visible'")->hashes || [];
			my $n = 0;
			foreach my $row ( @{$rows} ) {
				my $old = $row->{'value'} // '';
				my $new = &visibility_normalize($old);
				next if lc($old) eq $new;
				&db_update('settings', { value => $new, server_time => &rightNow() }, { uuid => $row->{'uuid'} });
				$n++;
			}
			&visibility_cache_clear();
			&say_it("backfill visibility_levels_v1: rewrote $n visibility row(s)");
			return 1;
		},
		'settings_dedupe_null_keys' => sub {
			# A settings row is keyed by (app, setting, device, subsetting), but the
			# setter's delete used '=', so an undef in any key column (a missing
			# subsetting, or a window-state save with no app) matched nothing and every
			# write left its predecessor behind: thousands of invisible same-value
			# duplicates (342 groups, 1640 rows on one machine) that grew the table and
			# every sync - the 'Now merging N settings' that looked stuck. The setter is
			# fixed now; this collapses what is already there, and runs again (under this
			# new name) so a machine that had already run the first pass, and kept
			# accumulating the app-null rows it could not prevent, is cleaned too. Keep
			# the row the reader returns - settings_grabber assigns in row order, so the
			# last write (highest rowid) is the visible value - and drop the rest. A peer
			# that still carries a duplicate cannot bring it back: a merge skips a row it
			# already holds at >= server_time. Group by the column itself, not
			# coalesce(subsetting,''): SQLite groups NULLs together but apart from '', and
			# those are two keys, so a non-null subsetting row is never mistaken for a
			# duplicate of a null one.
			my $sth = eval { &subs::db_query(
				q{delete from settings
				   where rowid not in (
				     select max(rowid) from settings
				     group by app, setting, device, subsetting)}) };
			return 0 unless $sth;   # a locked database: retry on the next pass
			&subs::say_it('backfill settings_dedupe_null_keys: collapsed ' . $sth->rows . ' duplicate settings row(s)');
			return 1;
		},
		'remote_machine_payload_prune_v1' => sub {
			# Rows written before the mirror/data views still carry the whole
			# login body and each peer's full row. Rewrite them once; the live
			# write paths now use the views, so only this at-rest copy is left.
			return &subs::remote_machine_payload_backfill();
		},
	};
}

1;
