package Manager;

# manager_budget: route actions moved out of Manager.pl, one sub per route so a
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

# GET /manager/budget
sub action_21514 {
	my $c = shift;
	my $totals = {};
	my $tally = {};
	my $budgets = {};
	my $new_settings = eval { return decode_json $c->param('new_settings') } || {};
	foreach my $ns ( keys %{$new_settings} ) {
		if ($new_settings->{$ns} =~ /[A-Za-z0-9.,-]/gi) {
			if ($ns =~ /_time/gi) {
				$new_settings->{$ns} = &subs::ago_calc($new_settings->{$ns}, &subs::rightNow());
			}
			&subs::setting_setter({ app => 'budget', setting => $ns, value => $new_settings->{$ns} });
		}
		else {
			&subs::setting_deleter({ app => 'budget', setting => $ns });
		}
	}
	my @dollas = qw/amount tax aux total/;
	my @categories = qw/category subcategory/;
	my $categories = { };
	for (my $n = 1; $n <= 100; $n++) {
		my $u = 'subcategory' . $n;
		push @categories, $u;
	#	$categories->{$u} = {};
	}

	my $timestamp = $c->param('timestamp');
	my $time_machine = $c->param('time_machine');

	my $settings = &subs::settings_grabber({ app => 'budget' });
	my $display = $c->param('display') || $settings->{'display'};
	# the display used to carry a budget table; the app is a set of financial
	# statements now, so an old saved budget view lands on the income statement
	$display = 'income_statement' if !defined $display || $display eq '' || $display eq 'budgets';
	if ($settings->{$display . '_display'} ne '') {
		my $d = eval { decode_json $settings->{$display . '_displays'} };
		foreach my $k ( keys %{$d->{$settings->{$display . '_display'}}} ) {
			$c->param($k, $d->{$settings->{$display . '_display'}}->{$k});
			&subs::setting_setter({ app => 'budget', setting => $k, value => $d->{$settings->{$display . '_display'}}->{$k} });
		}
		$d->{$settings->{$display . '_display'}}->{$display . '_display'} = $settings->{$display . '_display'};
		$settings = &subs::settings_grabber({ app => 'budget' });
	}
	my $display_categorization = $settings->{'display_categorization'};
	my $scope = $settings->{'scope'} || 'hour';
	my $movement = eval { decode_json $c->param('movement') || $settings->{'movement'} } || ['all'];

	my $project = eval { decode_json $c->param('projects') || $settings->{'projects'} } || ['all'];
	my $account = eval { decode_json $c->param('accounts') || $settings->{'accounts'} } || ['all'];
	my $columns = eval { decode_json $c->param('columns') || $settings->{'columns'} } || ['all'];
	my $timeshift = $c->param('timeshift');
	my ($db,$database,$sql) = &subs::database_grabber();
	my @columns = qw/app when occurences occurence_budget duration duration_budget duration_percent total_budget manufacturer item vendor account project amount tax aux total/;
	my $tr = {};

	my @time_scopes = ('next', 'this','last');
	my @time_widths;

	my @time_lengths = qw/minute hour day week month year/;
	if ($settings->{'s_visual'} eq 'allocation') {
		@time_scopes = undef;
		for (my $n = 0; $n <= 366; $n++) {
			push @time_scopes, $n;
		}
		@time_lengths = qw/second minute hour mday month year wday yday isdst/;
		@time_widths = ( 60, 60, 24, 31, 12, 150, 7, 365, 2 );
	}
	else {
		for (my $n = 2; $n <= 30; $n++) {
			push @time_scopes, $n . 'last';
			unshift @time_scopes, $n . 'next';
		}
	}


	my ($bt,$t1,$t2);
	# a father_time window ends on the next period's first instant, so that bound
	# is exclusive; an end_time the user picked stays inclusive
	my $t2_comp = '<=';
	if ($settings->{'start_time'} || $settings->{'end_time'}) {
		$bt = $settings->{'start_time'};
		$t2 = $settings->{'end_time'};
		if ($settings->{'start_time'} && !$settings->{'end_time'}) {
			$t2 = &subs::rightNow();
		}
		elsif (!$settings->{'start_time'} && $settings->{'end_time'}) {
			$bt = &subs::rightNow();
		}
	}
	else {
		if ($time_machine) {
			$timestamp = &time_machine_resolve($time_machine,$timestamp);
		}
		if ($timeshift) {
			$timestamp = &subs::ago_calc($timeshift,$timestamp);
		}
		$bt = &subs::time_span($scope, $timestamp); #timestamp at beginning
		$t1 = ($timestamp - $bt);
		$t2 = ($timestamp);
		# the multiplier widens the window in whole periods, the same way the
		# inventory's Nnext windows read it
		($bt, $t2) = &father_time({
			scope => $scope,
			ts => $settings->{'time_when'},
			lock => $settings->{'s_lock'},
			timestamp => $timestamp,
			periods => $settings->{'when_multiplier'} || 1
		});
		$t2_comp = '<';
	}
	my $total_duration = $t2 - $bt;
	my $last_inventory = $bt;
	my $accountals = &subs::db_query('select distinct(app) from settings where (setting=? or setting =?) and value=? order by app', 'pos', 'mab', 'account');
	my $accounts = $accountals->hashes;

	push @{$accounts}, { app => 'gallery' };
	unshift @{$accounts}, { app => 'all' };

	my $all_accounts = $accounts;
	unless (grep { $_ eq 'all' } @{$account}) {
		my @acco;
		foreach my $a ( @{$account} ) {
			push @acco, grep { $_->{'app'} eq $a } @{$accounts};
		}
	$accounts = \@acco;
	}

	my $acc = {};

	my $all_columns = \@columns;
	if (grep { $_ eq 'all' } @{$columns}) {
		$columns = $all_columns;
	}

	my $projections = &subs::db_query('select distinct(app) from settings where (setting=? or setting=?) and value=? order by app', 'pos', 'mab', 'project');
	my $projects = $projections->hashes;
	unshift @{$projects}, { app => 'all' };
	my $all_projects = $projects;
	unless (grep { $_ eq 'all' } @{$project}) {
		my @proj;
		foreach my $a ( @{$project} ) {
			push @proj, grep { $_->{'app'} eq $a } @{$projects};
		}
		$projects = \@proj;
	}

	# the invoices display is a document ledger, not a money tally: collect the
	# documents once. (The old code ran this query inside the account loop as well,
	# which returned the same unrestricted window once per account and multiplied
	# every transaction - and its total - by the number of accounts.)
	my $documents = [];
	if ($display eq 'invoices') {
		my $docr = &subs::db_query("select * from appointments where type in ('invoice','quote') and timestamp >= ? and timestamp $t2_comp ? order by timestamp desc", $last_inventory, $t2)->hashes;
		foreach my $doc ( @{$docr} ) {
			$doc->{'data'} = eval { return decode_json $doc->{'data'} } || {};
			my $numbers = $doc->{'data'}->{'numbers'} || {};
			my $paid = 0;
			foreach my $p ( @{$doc->{'data'}->{'payments'} || []} ) {
				$paid += $p->{'amount'} if defined $p->{'amount'} && $p->{'amount'} =~ /[0-9]/;
			}
			$doc->{'paid'} = $paid;
			$doc->{'balance'} = defined $numbers->{'balance'} ? $numbers->{'balance'} : ($numbers->{'total'} || 0) - $paid;
			$doc->{'formatted_type'} = &subs::format_name($doc->{'type'});
			$doc->{'formatted_item'} = &subs::format_name($doc->{'data'}->{'item'});
			$doc->{'formatted_total'} = &subs::price_formatter($numbers->{'total'} || 0);
			$doc->{'formatted_paid'} = &subs::price_formatter($paid);
			$doc->{'formatted_balance'} = &subs::price_formatter($doc->{'balance'});
			$doc->{'formatted_status'} = $doc->{'status'} ? &subs::format_name($doc->{'status'}) : ($doc->{'type'} eq 'quote' ? 'Draft' : 'Open');
			$totals->{'documents'}->{'count'}++;
			$totals->{'documents'}->{$doc->{'type'}}->{'count'}++;
			foreach my $key ( qw/total paid balance/ ) {
				my $value = $key eq 'total' ? ($numbers->{'total'} || 0) : $key eq 'paid' ? $paid : $doc->{'balance'};
				$totals->{'documents'}->{$key} += $value;
				$totals->{'documents'}->{$doc->{'type'}}->{$key} += $value;
			}
		}
		push @{$documents}, @{$docr};
	}
	my $transactions;
	foreach my $accounting ( @{$accounts}) {
		next if $acc->{$accounting->{'app'}};
		$accounting->{'balance'} = 0;
		$accounting->{'settings'} = &subs::settings_grabber({ app => $accounting->{'app'} });
		my $inventory = &subs::db_query('select * from appointments where app=? and type=? and movement=? order by timestamp', $accounting->{'app'}, 'transaction','inventory');
		my $inv = $inventory->hashes;
		my $final_t = {};
		foreach my $i ( @{$inv} ) {
			if ($i->{'timestamp'} < $bt) {
				$accounting->{'balance'} = $i->{'amount'};
				$accounting->{'starting_balance'} = $i->{'amount'};
				push @{$accounting->{'journals'}}, { amount => $accounting->{'balance'}, timestamp => $i->{'timestamp'} };
				$last_inventory = $i->{'timestamp'};
				$final_t = $i;
				$final_t->{'timestamp'} = $bt;
			}
		}
#		push @{$transactions}, $final_t if $final_t->{'timestamp'};
		# the money moves now come from the warehouse ledger; the balance anchors
		# (inventory-movement appointments) are kept where they are for now, so the
		# statement is unchanged while the money it tallies lives on the ledger
		my $money_moves = &subs::db_query("select * from warehouse where kind = 'money' and account = ? and timestamp >= ? and timestamp $t2_comp ? order by timestamp",
			$accounting->{'app'},$last_inventory,$t2)->hashes;
		my $money_anchors = &subs::db_query("select * from appointments where account = ? and type != ? and movement = ? and timestamp >= ? and timestamp $t2_comp ? order by timestamp",
			$accounting->{'app'}, 'inventory', 'inventory', $last_inventory,$t2)->hashes;
		push @{$transactions}, sort { $a->{'timestamp'} <=> $b->{'timestamp'} } (@{$money_moves}, @{$money_anchors});
		if (grep { $_ eq 'all' } @{$movement}) {

		}
		else {
			my $transactionality = [];
			foreach my $m ( @{$movement} ) {
				push @{$transactionality}, grep { $_->{'type'} eq $m } @{$transactions};
			}
			$transactions = $transactionality;
		}
		$last_inventory = $bt;
		$acc->{$accounting->{'app'}} = $accounting;
	}
	unless ( grep { $_ eq 'all' } @{$project} ) {
		my $tp = [];
		foreach my $tr ( @{$project} ) {
			push @{$tp}, grep { $_->{'project'} eq $tr } @{$transactions};
		}
		$transactions = $tp;
	}

	foreach my $t ( @{$transactions} ) {
		if ($t->{'movement'} eq 'inventory') {
			$acc->{$t->{'account'}}->{'balance'} = $t->{'amount'};
			push @{$acc->{$t->{'account'}}->{'journals'}}, { amount => $acc->{$t->{'account'}}->{'balance'}, timestamp => $t->{'timestamp'} };
			$last_inventory = $t->{'timestamp'};
			next;
		}
		$tally->{$t->{'app'}} = {
			income => [],
			expense => [],
			transfer => [],
			totals => {},
			settings => &subs::settings_grabber({ app => $t->{'app' } })
		} unless $tally->{$t->{'app'}};


		my $pushable = $display_categorization;

		if ($display_categorization eq 'category') {
			$pushable = $tally->{$t->{'app'}}->{'settings'}->{'category'};
			if ($pushable eq '') {
				$pushable = 'unknown';
			}
		}
		elsif ($display_categorization eq undef || $display_categorization eq '') {
			$pushable = $t->{'app'};
		}
		else {
			$pushable = $t->{$display_categorization};
		}

		$tally->{$pushable} = {
			income => [],
			expense => [],
			transfer => [],
			totals => { },
			settings => &subs::settings_grabber({ app => $pushable })
		} unless $tally->{$pushable};

	#	$t->{'movement'} = 'expense' unless $t->{'movement'};
		$acc->{$t->{'account'}}->{'balance'} = $acc->{$t->{'account'}}->{'balance'} + $t->{'total'};
		push @{$acc->{$t->{'account'}}->{'journals'}}, { amount => $acc->{$t->{'account'}}->{'balance'}, timestamp => $t->{'timestamp'} };
		if ($t->{'timestamp'} < $bt) {
			$acc->{$t->{'account'}}->{'starting_balance'} = $acc->{$t->{'account'}}->{'balance'};
		}
		elsif ($t->{'timestamp'} >= $bt && $t->{'timestamp'} <= $t2) {
			foreach my $dolla (@dollas) {
				for (my $ca = 0; $ca <= scalar @categories; $ca++) {
					my $cat = $categories[$ca];
					my $cath = $cat;
					if ($tally->{$t->{'app'}}->{'settings'}->{$cat}) {
						my $distinct = $tally->{$t->{'app'}}->{'settings'}->{$cat};
						if (0 == 0) {
							$cath = $distinct;
						}
						unless ($categories->{$cath}->{'info'}->{$distinct}) {
							$categories->{$cath}->{'info'}->{$distinct} = &subs::settings_grabber({ app => $tally->{$t->{'app'}}->{'settings'}->{$cat} });
						}
						if ($ca > 1) {
							$cath = $categories->{$cath}->{'info'}->{'subcategory' . ($ca - 1)};
						}
						elsif ($ca > 0) {
							$cath = $categories->{$cath}->{'info'}->{'category'};
						}
						$categories->{$cath}->{$tally->{$t->{'app'}}->{'settings'}->{$cat}}->{'ca'} = $ca;
						if ($dolla eq 'amount') {
							push @{$categories->{$cath}->{$tally->{$t->{'app'}}->{'settings'}->{$cat}}->{'list'}}, $t;
						}
						$categories->{$cath}->{$tally->{$t->{'app'}}->{'settings'}->{$cat}}->{$dolla} += $t->{$dolla} if $t->{$dolla} =~ /[0-9]/;
					}
				}
			}
			if ($t->{'movement'} eq 'income') {
				$t->{'t'} = 'income';
				$t->{'occurences'} = 1;
				$t->{'duration'} = abs $t->{'duration'};
				foreach my $dolla ( @dollas ) {
					$t->{$dolla} = abs $t->{$dolla} if $t->{$dolla} =~ /[0-9]/;
				}
				foreach my $col ( @columns ) {
					$totals->{'income'}->{$col} += $t->{$col} unless $t->{$col} =~ /[a-zA-Z]/ || $t->{$col} !~ /[0-9]/;
				}
			}
			elsif ($t->{'movement'} eq 'transfer') {
				$t->{'t'} = 'transfer';
				$t->{'occurences'} = 1;
				$t->{'duration'} = abs $t->{'duration'};
				#unless (grep { $_->{'uuid'} eq $t->{'uuid'} } @{$tally->{$t->{'app'}}->{$t->{'movement'}}}) {
					foreach my $col ( @columns ) {
						$totals->{'transfer'}->{$col} += $t->{$col} unless $t->{$col} =~ /[a-zA-Z]/ || $t->{$col} !~ /[0-9]/;
					}
				#}
			}
			elsif ($t->{'movement'} eq 'expense') {
				$t->{'t'} = 'expense';
				$t->{'movement'} = 'expense';
				$t->{'occurences'} = 1;
				$t->{'duration'} = (abs $t->{'duration'}) * -1;
				foreach my $dolla ( @dollas ) {
					$t->{$dolla} = ($t->{$dolla});# * -1;
				}
				foreach my $col ( @columns ) {
					$totals->{'expense'}->{$col} += $t->{$col} unless $t->{$col} =~ /[a-zA-Z]/ || $t->{$col} !~ /[0-9]/;
				}
			}
			foreach my $col ( @columns ) {
				unless ($t->{$col} =~ /[a-zA-Z]/ || $t->{$col} !~ /[0-9]/) {
					$totals->{'total'}->{$col} += $t->{$col};
					$tally->{$pushable}->{'totals'}->{$t->{'movement'}}->{$col} += $t->{$col};
				}
			}
			push @{$tally->{$pushable}->{$t->{'movement'}}}, $t;
			@{$tally->{$pushable}->{$t->{'movement'}}} = sort { $b->{'timestamp'} <=> $a->{'timestamp'} } @{$tally->{$pushable}->{$t->{'movement'}}};
		}
	}
	foreach my $d ( keys %{$gb::transaction_types} ) {
		$totals->{$d}->{'duration_percent'} = &subs::percent_formatter(abs $totals->{$d}->{'duration'} / $total_duration);
		$totals->{$d}->{'duration'} = &subs::duration_sayer(abs $totals->{$d}->{'duration'} / 1000);
	}
	foreach my $app ( keys %{$tally} ) {
		foreach my $dr ( keys %{$gb::budget_modes} ) {
			my $budget = &budget_calculator({
				app => $app,
				budget => $tally->{$app}->{'settings'}->{'budget'},
				circumstance => $dr,
				scope => $scope,
				value => $tally->{$app}->{'totals'}->{$dr},
				settings => $tally->{$app}->{'settings'}
			});
			$tally->{$app}->{'budget'}->{$dr} = $budget if $budget->{'eval'};
		}
	}
	if ($display eq 'budgets') {
		$settings->{'budget_displays'} = eval { return decode_json $settings->{'budget_displays'} } || {};
	}
	elsif ($display eq 'statement') {
		$settings->{'statement_displays'} = eval { return decode_json $settings->{'statement_displays'} } || {};
	}
	elsif ($display eq 'daily_sheet') {
		$settings->{'daily_sheet_displays'} = eval { return decode_json $settings->{'daily_sheet_displays'} } || {};
	}
	my @display_options = (
		[ 'income_statement', &subs::ui('Income Statement') ],
		[ 'balance_sheet', &subs::ui('Balance Sheet') ],
		[ 'cash_flow', &subs::ui('Cash Flow') ],
		[ 'account_activity', &subs::ui('Account Activity') ],
		[ 'trial_balance', &subs::ui('Trial Balance') ],
		[ 'statement', &subs::ui('Ledger') ],
		[ 'receivables', &subs::ui('Receivables') ],
		[ 'payables', &subs::ui('Payables') ],
		[ 'invoices', &subs::ui('Invoices') ],
		[ 'daily_sheet', &subs::ui('Day Book') ],
		[ 'reconcile', &subs::ui('Reconcile') ]
	);
	my %known_display = map { $_->[0] => 1 } @display_options;
	$display = 'income_statement' unless $known_display{$display};
	my $reports = {};
	my $trial = {};
	my $payables = {};
	my $schedules = [];
	my $notification_booked = [];
	my @payable_apps;
	if ($display eq 'trial_balance') {
		# the journal is derived; bring it up to date before reading it so the
		# screen never shows the picture from before the last transaction
		&subs::accounting_journal_maybe_rebuild();
		$trial = &subs::accounting_trial_balance($t2);
	}
	if ($display eq 'payables') {
		$payables = &accounting_payables($t2);
		$schedules = &payable_schedules();
		$notification_booked = &notification_booked_bills(10);
		@payable_apps = map { $_->{'app'} } @{ &subs::db_query("select distinct(app) as app from warehouse where kind='money' and app is not null and app != '' order by app")->hashes || [] };
	}
	if ($display eq 'income_statement' || $display eq 'balance_sheet' || $display eq 'cash_flow' || $display eq 'account_activity' || $display eq 'receivables') {
		my @report_accounts = map { $_->{'app'} } grep { $_->{'app'} ne 'all' && $_->{'app'} ne 'gallery' } @{$accounts};
		$reports = &accounting_reports({ accounts => \@report_accounts, from => $bt, to => $t2 });
	}
	my $period_span = $t2 - $bt;
	my $period_start_label = POSIX::strftime('%b %e, %Y', localtime($bt / 1000));
	my $period_end_label = POSIX::strftime('%b %e, %Y', localtime($t2 / 1000));
	my $prior_start_label = POSIX::strftime('%b %e, %Y', localtime(($bt - $period_span) / 1000));
	my $prior_end_label = $period_start_label;
	my $data = {
		timestamp => $timestamp,
		accounts => $acc,
		categories => $categories,
		all_accounts => $all_accounts,
		account => $account,
		tally => $tally,
		transactions => $transactions,
		documents => $documents,
		budgets => $budgets,
		all_projects => $all_projects,
		projects => $projects,
		project => $project,
		totals => $totals,
		template => 'budget',
		time_machine => $time_machine,
		scope => $scope,
		movement => $movement,
		timeshift => $timeshift,
		display => $display,
		start => $bt,
		end => $t2,
		total_duration => $total_duration,
		settings => $settings,
		all_columns => $all_columns,
		columns => $columns,
		dollas => \@dollas,
		time_scopes => \@time_scopes,
		time_lengths => \@time_lengths,
		displays => \@display_options,
		reports => $reports,
		trial => $trial,
		payables => $payables,
		payable_apps => \@payable_apps,
		schedules => $schedules,
		notification_booked => $notification_booked,
		period_start => $period_start_label,
		period_end => $period_end_label,
		prior_start => $prior_start_label,
		prior_end => $prior_end_label
	};


	my $content = $c->render_to_string(%{$data});
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'budget', title => &subs::lang('accounting'), window_name => &subs::lang('accounting'), contents => $content },$timestamp);
	$data->{'html'} = $contents;
	$c->render(json => $data);
}

# POST /manager/budget/edit
sub action_21971 {
	my $c = shift;
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $circumstance = $c->param('circumstance');
	my $value = $c->param('value');
	my $previous = $c->param('previous');
	my $existing_budgets;
	&subs::cache_delete({ app => $app, context => 'autocalc' });
	if (defined $previous && length $previous) {
		# The entry this edit replaces is named exactly, so the app's other entries
		# are left alone and a recommendation keeps its own scope and measure. An
		# empty value removes it.
		my @entries = grep { length } split ',', (&subs::setting_grabber({ app => $app, setting => 'budget' }) || '');
		@entries = grep { $_ ne $previous } @entries;
		push @entries, $value if defined $value && length $value;
		$existing_budgets = join ',', @entries;
	}
	else {
		$existing_budgets = $value;
		foreach my $br ( keys %{$gb::budget_modes} ) {
			my $budget = &budget_calculator({
				app => $app,
				circumstance => $br,
				value => 1,
				scope => 'hour',
				budget => &subs::setting_grabber({ app => $app, setting => 'budget' })
			});

			if ($budget->{'circumstance'} && $budget->{'circumstance'} ne $circumstance) {
				if ($existing_budgets) {
					$existing_budgets = $existing_budgets . ',' . $budget->{'budget'};
				}
				else {
					$existing_budgets = $budget->{'budget'};
				}
			}

		}
	}
	# A letter-bearing budget (a measure like "8681.139steps/d", or a quantity like
	# "3.4quantity/week") is claimed by more than one mode as they are all re-read -
	# the duration pass takes any letters - so the same string can be appended twice;
	# keep it once.
	my %seen_budget;
	$existing_budgets = join ',', grep { !$seen_budget{$_}++ } split ',', ($existing_budgets // '');
	&subs::setting_setter({ app => $app, setting => 'budget', value => $existing_budgets });
	$c->render(json => { existing_budgets => $existing_budgets, new_budget => $value });
}

# POST /manager/budget/display/save
sub action_22020 {
	my $c = shift;
	my $name = &subs::unformat_name($c->param('name'));
	my $timestamp = $c->param('timestamp');
	my $data = eval { return decode_json $c->param('data') } || [];
	my $type = $c->param('type') || 'statement';

	if (scalar @{$data} == 0) {
		$c->render(json => {});
	}
	my $settings = &subs::settings_grabber({ app => 'budget' });

	my $display_settings = { start_time => $settings->{'start_time'}, end_time => $settings->{'end_time'} };
	foreach my $s ( keys %{$settings} ) {
		if (my @ds = grep { $_ eq $s } @{$data}) {
			$display_settings->{$s} = $settings->{$s};
		}
	}
	my $returner = { data => $data, config => $display_settings };

	my $cd = eval { return decode_json $settings->{$type . '_displays'} } || {};
	$cd->{$name} = $display_settings;
	my $jcd = encode_json $cd;
	&subs::setting_setter({ app => 'budget', setting => $type . '_displays', value => $jcd });


	$c->render(json => $returner);
}

# POST /manager/budget/display/delete
sub action_22048 {
	my $c = shift;
	my $name = &subs::unformat_name($c->param('name'));
	my $display = $c->param('display');
	my $sd = eval { return decode_json &subs::setting_grabber({ app => 'budget', setting => $display . '_displays' }) } || {};
	if ($sd->{$name}) {
		$sd->{$name} = undef;
	}
	my $jsd = encode_json $sd;
	&subs::setting_setter({ app => 'budget', setting => $display . '_displays', value => $jsd });
	$c->render(json => $sd);
}

# POST /manager/budget/import
sub action_22060 {
	my $c = shift;
	my $account = &subs::unformat_name($c->param('account'));
	my $date_order = ($c->param('date_order') || '') eq 'dmy' ? 'dmy' : 'mdy';
	my $upload = $c->req->uploads->[0];
	unless ($account) { return $c->render(json => { error => &subs::ui('Choose an account first.') }); }
	unless ($upload) { return $c->render(json => { error => &subs::ui('Choose a file to import.') }); }
	my $filename = $upload->filename || 'statement';
	my $text = $upload->slurp;
	utf8::decode($text);
	my ($lines,$file_balance,$parse_error,$statement_end) = &bank_statement_parse($filename, $text, $date_order);
	unless (scalar @{$lines}) {
		return $c->render(json => { error => $parse_error || &subs::ui('No dated lines with an amount were found in this file.') });
	}
	my $result = &bank_reconcile_result($account, $lines, $filename, $file_balance, $parse_error, $statement_end);
	my $html = $c->render_to_string(template => 'budget_reconcile', %{$result});
	$c->render(json => {
		html => $html,
		account => $account,
		lines => scalar @{$lines},
		matched => $result->{'matched_count'},
		unmatched => $result->{'unmatched_count'},
		ledger_balance => $result->{'ledger_balance'},
		statement_balance => $result->{'statement_balance'},
		delta => $result->{'delta'},
		filename => $filename
	});
}

# POST /manager/budget/reconcile
sub action_22088 {
	my $c = shift;
	my $account = &subs::unformat_name($c->param('account'));
	my $statement_end = $c->param('statement_end');
	my $ending = $c->param('ending_balance');
	my $lines = eval { decode_json $c->param('lines') } || [];
	my $result = &budget_reconcile_apply($account, $statement_end, $ending, $lines);
	$c->render(json => $result);
}

# The journal is derived from the ledger and the documents; a rebuild is safe and
# deterministic, so the trial balance screen can ask for a fresh one.
# POST /manager/budget/journal/rebuild
sub action_22099 {
	my $c = shift;
	my $result = &subs::accounting_journal_rebuild();
	$c->render(json => $result);
}

1;
