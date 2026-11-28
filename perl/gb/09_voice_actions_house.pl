package gb;
use strict;
use warnings;
no warnings 'once';

# The house-side actions voice was missing: the clock's alarms and timers, the
# task checklist, money in and out, bills and runway, the warehouse shelf and an
# app's inventory. Same shape as perl/gb/03_engines_and_tools.pl: an app whose
# help topic names it, a "do" the model may pick, a real route that answers
# JSON, the exact parameters that route reads, and a speech sub that reads only
# that JSON. A write carries a confirm, because the bridge proposes it before
# anything runs.
#
# Every route below returns JSON today. The clock's read (clock/timers) is
# already in 03, so it is not repeated. The clock's alarm route creates a new
# alarm on `action=add` and edits an existing one by its uuid on `action=save`;
# a single bridge call cannot chain the two, so the parameters expose both.
# Accounting owns the money routes: the transactions live under an app's own
# window, and the budget topic (app key `budget`) is the app-scoped home voice
# can name. Budget's /manager/budget/current_information renders text, so it is
# deliberately absent; the runway and account views below read the same main
# route, which answers JSON.

push @gb::app_actions, (

	# ---- Clock -----------------------------------------------------------
	{
		app => 'clock', do => 'alarm', kind => 'write',
		method => 'post', route => '/manager/clock/alarm',
		params => {
			action => 'add a new alarm, or delete, toggle, save, snooze, dismiss, skip or stop_all an existing one (required)',
			uuid => 'the alarm to change, from the clock state (save, delete, toggle, snooze, dismiss, skip)',
			hour => 'the hour of the day, 0 to 23 (save)',
			minute => 'the minute, 0 to 59 (save)',
			days => 'the days it repeats, comma separated (save)',
			label => 'the alarm\'s name (save)',
			enabled => '1 to arm it, 0 to leave it off (save)',
			sound => 'the ring sound (save)',
			volume => 'the volume, 0 to 100 (save)',
			ramp => 'the volume ramp in seconds (save)',
			snooze => 'the snooze length in minutes (save)',
			app => 'the app the alarm belongs to, optional',
			machines => 'the machines that carry the alarm, comma separated',
		},
		required => { action => 'the change to make' },
		confirm => 'I can change the alarms. Confirm it and I will.',
		desc => 'set an alarm, or change, snooze or dismiss one',
		speech => sub {
			my ($d, $p) = @_;
			$d = {} unless ref $d eq 'HASH';
			$p = {} unless ref $p eq 'HASH';
			my $err = $d->{'error'} // '';
			if (length $err) {
				my %why = (
					full => 'The clock already holds ten alarms.',
					missing => 'I could not find that alarm.',
				);
				return $why{$err} || ('I could not change the alarm: ' . $err . '.');
			}
			my $action = $p->{'action'} // '';
			return 'I removed that alarm.' if $action eq 'delete';
			return 'I silenced the alarm.' if $action eq 'dismiss' || $action eq 'stop_all';
			return 'I snoozed the alarm.' if $action eq 'snooze';
			return 'I skipped the next ring.' if $action eq 'skip';
			return 'I switched that alarm off.' if $action eq 'toggle'
				&& (!$p->{'enabled'} || $p->{'enabled'} =~ /^(?:0|off)$/i);
			return 'The alarm is set.';
		},
	},
	{
		app => 'clock', do => 'timer', kind => 'write',
		method => 'post', route => '/manager/clock/timer',
		params => {
			action => 'start a timer, or stop, delete, restore or clear_finished (start unless set)',
			hours => 'the timer hours (start)',
			minutes => 'the timer minutes (start)',
			seconds => 'the timer seconds (start)',
			label => 'what the timer is for (start)',
			app => 'the app to start or stop with the timer, optional',
			uuid => 'the timer to stop, delete or restore',
			sound => 'the timer sound (start)',
			volume => 'the volume (start)',
		},
		required => {},
		confirm => 'I can start that timer. Confirm it and I will.',
		desc => 'start a timer, or stop one',
		speech => sub {
			my ($d, $p) = @_;
			$d = {} unless ref $d eq 'HASH';
			$p = {} unless ref $p eq 'HASH';
			my $err = $d->{'error'} // '';
			if (length $err) {
				my %why = (
					full => 'There are already ten timers running.',
					time => 'That timer length is not valid.',
					missing => 'I could not find that timer.',
					running => 'That timer is already running.',
				);
				return $why{$err} || ('The timer could not be changed: ' . $err . '.');
			}
			my $action = $p->{'action'} // '';
			return 'The timer is stopped.' if $action eq 'stop' || $action eq 'delete';
			return 'The timer is running.';
		},
	},

	# ---- Tasks -----------------------------------------------------------
	{
		app => 'tasks', do => 'list', kind => 'read',
		method => 'get', route => '/manager/tasks',
		params => {
			app => 'the app whose checklist to read (required)',
			timestamp => 'the moment to read it at, optional',
		},
		required => { app => 'the app whose tasks to read' },
		desc => 'read an app\'s task checklist',
		speech => sub {
			my ($d, $p) = @_;
			$d = {} unless ref $d eq 'HASH';
			$p = {} unless ref $p eq 'HASH';
			my $rows = (ref $d->{'tasks'} eq 'ARRAY') ? $d->{'tasks'} : [];
			my @real = grep { ref $_ eq 'HASH' && ($_->{'uuid'} // '') ne 'new' } @{$rows};
			my $app = ($p->{'app'} // '') ne '' ? $p->{'app'} : 'this app';
			return 'There are no tasks for ' . $app . '.' unless @real;
			my $open = scalar grep { ($_->{'completed'} // '') ne 'on' } @real;
			my $done = scalar(@real) - $open;
			my $say = scalar(@real) . ' task' . (scalar(@real) == 1 ? '' : 's')
				. ' for ' . $app . ', ' . $open . ' open'
				. ($done ? ', ' . $done . ' done' : '');
			return ucfirst($say) . '.';
		},
	},
	{
		app => 'tasks', do => 'add', kind => 'write',
		method => 'post', route => '/manager/tasks',
		params => {
			app => 'the app whose checklist receives the task (required)',
			uuid => 'new to add a task (required)',
			name => 'the field to write: task for the words (required)',
			value => 'the task\'s words (required)',
			papp => 'the appointment app the checklist belongs to, optional',
			timestamp => 'the task\'s moment in milliseconds, optional',
			colour => 'the task\'s colour, optional',
		},
		required => {
			app => 'the app to add the task to',
			uuid => 'the new-task marker',
			name => 'the field to write',
			value => 'the task\'s words',
		},
		confirm => 'I can add that task. Confirm it and I will.',
		desc => 'add a task to an app\'s checklist',
		speech => sub {
			my ($d, $p) = @_;
			$p = {} unless ref $p eq 'HASH';
			my $value = ($p->{'value'} // '');
			return 'I added "' . $value . '" to the list.' if length $value;
			return 'I added the task.';
		},
	},
	{
		app => 'tasks', do => 'tick', kind => 'write',
		method => 'post', route => '/manager/tasks',
		params => {
			app => 'the app whose checklist holds the task (required)',
			uuid => 'the task to tick (required)',
			name => 'the field to write: completed (required)',
			value => 'on to tick it off, off to open it again (required)',
			papp => 'the appointment app the checklist belongs to, optional',
			timestamp => 'the moment in milliseconds, optional',
		},
		required => {
			app => 'the app that holds the task',
			uuid => 'the task to tick',
			name => 'the field to write',
			value => 'whether it is done or open',
		},
		confirm => 'I can tick that task. Confirm it and I will.',
		desc => 'tick a task off, or open it again',
		speech => sub {
			my ($d, $p) = @_;
			$p = {} unless ref $p eq 'HASH';
			my $value = lc($p->{'value'} // '');
			return 'I ticked that task off.' if $value eq 'on';
			return 'I opened that task again.' if $value eq 'off';
			return 'I updated the task.';
		},
	},

	# ---- Money (the budget topic owns the accounting routes) -------------
	{
		app => 'budget', do => 'record_spend', kind => 'write',
		method => 'post', route => '/manager/transaction/record',
		params => {
			app => 'the app the spend belongs to (required)',
			account => 'the account the money came from (required)',
			movement => 'expense for money out (required)',
			total => 'the total on the receipt (required)',
			vendor => 'who was paid, optional',
			item => 'what it was for, optional',
			notes => 'a note, optional',
			timestamp => 'the moment in milliseconds, optional',
			currency => 'the currency, optional',
			quantity => 'how much, optional',
			unit => 'the unit for the quantity, optional',
			transaction_information => 'the invoice uuid this pays, optional',
		},
		required => {
			app => 'the app the spend belongs to',
			account => 'the account the money left',
			movement => 'the direction, expense',
			total => 'the amount spent',
		},
		confirm => 'I can record that spend. Confirm it and I will.',
		desc => 'record a spend from an account',
		speech => sub {
			my ($d, $p) = @_;
			$d = {} unless ref $d eq 'HASH';
			$p = {} unless ref $p eq 'HASH';
			my $err = $d->{'error'} // '';
			return 'I could not record the spend: ' . $err if length $err;
			my $vendor = ($p->{'vendor'} // '');
			return 'I recorded the spend for ' . $vendor . '.' if length $vendor;
			return 'I recorded the spend.';
		},
	},
	{
		app => 'budget', do => 'account_balance', kind => 'read',
		method => 'get', route => '/manager/budget',
		params => {
			display => 'account_activity, the account balance view (required)',
			accounts => 'a JSON list of account names, e.g. ["cash"] (required)',
			timestamp => 'the moment to read it at, optional',
		},
		required => {
			display => 'the account activity view',
			accounts => 'the accounts to read',
		},
		desc => 'read the balance of the named accounts',
		speech => sub {
			my ($d, $p) = @_;
			$d = {} unless ref $d eq 'HASH';
			my $reports = (ref $d->{'reports'} eq 'HASH') ? $d->{'reports'} : {};
			my $activity = (ref $reports->{'activity'} eq 'ARRAY') ? $reports->{'activity'} : [];
			my @bits;
			foreach my $a ( @{$activity} ) {
				last if @bits >= 4;
				next unless ref $a eq 'HASH';
				my $name = ($a->{'app'} // '') ne '' ? $a->{'app'} : 'the account';
				next unless defined $a->{'closing'};
				push @bits, $name . ' at ' . sprintf('%.2f', $a->{'closing'} + 0);
			}
			return 'I could not read the balance.' unless @bits;
			return 'The balance is ' . join(', ', @bits) . '.';
		},
	},

	# ---- Budget ----------------------------------------------------------
	{
		app => 'budget', do => 'record_payable', kind => 'write',
		method => 'post', route => '/manager/budget/payable/add',
		params => {
			vendor => 'who is owed (required)',
			total => 'the amount owed (required)',
			item => 'what the bill is for, optional',
			tax => 'the tax included, optional',
			date => 'the bill\'s date, optional',
			currency => 'the currency, optional',
			repeat => 'once, or an interval or phrase for a repeating bill, optional',
			app => 'the app the bill belongs to, optional',
		},
		required => {
			vendor => 'who is owed',
			total => 'the amount owed',
		},
		confirm => 'I can record that bill. Confirm it and I will.',
		desc => 'record a bill that is owed',
		speech => sub {
			my ($d, $p) = @_;
			$d = {} unless ref $d eq 'HASH';
			$p = {} unless ref $p eq 'HASH';
			my $err = $d->{'error'} // '';
			return 'I could not record that bill: ' . $err if length $err;
			return 'I set up the repeating bill.' if $d->{'scheduled'};
			my $vendor = ($p->{'vendor'} // '');
			return 'I recorded the bill for ' . $vendor . '.' if length $vendor;
			return 'I recorded the bill.';
		},
	},
	{
		app => 'budget', do => 'runway', kind => 'read',
		method => 'get', route => '/manager/budget',
		params => {
			display => 'runway (required)',
			accounts => 'a JSON list of account names, optional',
			timestamp => 'the moment to read it at, optional',
		},
		required => { display => 'the runway view' },
		desc => 'read how long the money will last',
		speech => sub {
			my ($d, $p) = @_;
			$d = {} unless ref $d eq 'HASH';
			my $run = (ref $d->{'runway'} eq 'HASH') ? $d->{'runway'} : {};
			return 'I could not read the runway.' unless %{$run};
			my $say = defined $run->{'held'}
				? 'You hold ' . sprintf('%.2f', $run->{'held'} + 0)
				: 'The runway is ready';
			$say .= ', with ' . sprintf('%.2f', $run->{'available'} + 0) . ' available'
				if defined $run->{'available'};
			return ucfirst($say) . '.';
		},
	},

	# ---- Warehouse -------------------------------------------------------
	{
		app => 'warehouse', do => 'on_hand', kind => 'read',
		method => 'get', route => '/manager/warehouse/on_hand',
		params => {
			item => 'the item whose shelf to read (required)',
			target => 'a target amount, to plan a restock, optional',
		},
		required => { item => 'the item to read' },
		desc => 'read how much of an item is on hand',
		speech => sub {
			my ($d, $p) = @_;
			$d = {} unless ref $d eq 'HASH';
			$p = {} unless ref $p eq 'HASH';
			return 'I could not read the shelf.' unless keys %{$d};
			my $item = ($d->{'item'} // $p->{'item'} // '');
			$item = 'that item' unless length $item;
			my $stock = (ref $d->{'on_hand'} eq 'HASH') ? $d->{'on_hand'} : {};
			my @bits;
			foreach my $unit ( sort keys %{$stock} ) {
				my $amount = $stock->{$unit};
				next unless defined $amount && $amount != 0;
				push @bits, $amount . ' ' . $unit;
			}
			return 'There is no ' . $item . ' on hand.' unless @bits;
			return ucfirst($item) . ': ' . join(', ', @bits) . ' on hand.';
		},
	},
	{
		app => 'warehouse', do => 'stock_in', kind => 'write',
		method => 'post', route => '/manager/warehouse/stock_in',
		params => {
			item => 'the item that arrived (required)',
			place => 'where it is stored (required)',
			quantity => 'how much, with its unit, e.g. 12 each (required)',
			reason => 'gift, found, transfer or other, optional',
			timestamp => 'the moment in milliseconds, optional',
		},
		required => {
			item => 'the item that arrived',
			place => 'where it is stored',
			quantity => 'how much arrived',
		},
		confirm => 'I can add that stock. Confirm it and I will.',
		desc => 'record stock that arrived without a purchase',
		speech => sub {
			my ($d, $p) = @_;
			$d = {} unless ref $d eq 'HASH';
			$p = {} unless ref $p eq 'HASH';
			my $err = $d->{'error'} // '';
			if (length $err) {
				my %why = (
					item => 'I need the item\'s name.',
					place => 'I need the place it is stored.',
					unit => 'I do not know that unit.',
					quantity => 'I need a quantity above zero.',
				);
				return $why{$err} || 'I could not add that stock.';
			}
			my $item = ($d->{'item'} // $p->{'item'} // '');
			$item = 'the item' unless length $item;
			my $what = '';
			if (defined $d->{'quantity'}) {
				$what = $d->{'quantity'} . (defined $d->{'unit'} && length $d->{'unit'} ? ' ' . $d->{'unit'} : '');
			}
			return 'I added ' . (length $what ? $what . ' of ' : '') . $item . ' to the shelf.';
		},
	},

	# ---- Inventory -------------------------------------------------------
	{
		app => 'inventory', do => 'usage', kind => 'read',
		method => 'get', route => '/manager/inventory/details',
		params => {
			app => 'the app whose activity to read (required)',
			timestamp => 'the moment to read it at, optional',
			display => 'the reading to show: occurences, duration or a measure, optional',
		},
		required => { app => 'the app to read' },
		desc => 'read an app\'s record count and time logged',
		speech => sub {
			my ($d, $p) = @_;
			$d = {} unless ref $d eq 'HASH';
			$p = {} unless ref $p eq 'HASH';
			return 'I could not read the inventory.' unless keys %{$d};
			my $app = ($d->{'app'} // $p->{'app'} // '');
			$app = 'This app' unless length $app;
			my $n = defined $d->{'total_occurences'} ? $d->{'total_occurences'} + 0 : undef;
			return 'There is no record for ' . lc($app) . '.' unless defined $n && $n > 0;
			my $when = '';
			my $ms = defined $d->{'total_duration'} ? $d->{'total_duration'} + 0 : 0;
			if ($ms > 0) {
				my $mins = int($ms / 60000);
				if ($mins >= 60) {
					my $hours = int($mins / 60);
					my $rest = $mins % 60;
					$when = ' and about ' . $hours . ' hour' . ($hours == 1 ? '' : 's')
						. ($rest ? ' ' . $rest . ' minutes' : '');
				}
				else {
					$when = ' and about ' . ($mins || 1) . ' minutes';
				}
			}
			return ucfirst($app) . ' has ' . $n . ' record' . ($n == 1 ? '' : 's') . $when . '.';
		},
	},
);

1;
