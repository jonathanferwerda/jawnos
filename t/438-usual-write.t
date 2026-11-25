# tests-for: lib/JawnOS/Domain/UsualWrite.pm lib/JawnOS/Manager/Part14.pm lib/JawnOS/Controller/manager_misc5.pm lib/JawnOS/Routes/manager_misc5.pm
# covers:    the usual/pre-usual write side - the parent is stamped at the press,
#           usual anchors its tasks a length before it and pre_usual a length
#           after it, an ambiguous profile asks and writes nothing (a chosen kind
#           writes), the remembered kind is stored only when the box was checked,
#           a transaction replays through the appointment writer and moves stock,
#           an image row is written before its capture, every movement has a
#           mode, and the reset branch and the GET route are wired as split.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json encode_json);
use JawnOSTest;

# Load every real domain sub before a test replaces it: the module defines the
# name when it loads and would otherwise overwrite the stub.
subs::preload($_) for qw(
	usual_task_replay usual_kind_set usual_summary_line usual_apply usual_mode
	usual_ask_payload db_insert db_update db_query appt_header_printer
	usual_appointment_maker rightNow setting_grabber settings_grabber
	setting_setter warehouse_place_for warehouse_movement run_command
	note_decrypter note_encrypter backup_now
	format_name unformat_name ui numeric_formatter
);

{
	package UsualCtx;
	sub new { bless { params => {}, suds => 'secret' }, shift }
	sub param {
		my ($self, $key, $value) = @_;
		if (@_ > 2) { $self->{'params'}{$key} = $value; return $value }
		return $self->{'params'}{$key};
	}
	sub tx { return undef }
}

{
	package UsualRows;
	sub new { my ($class, $rows) = @_; bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
}

my $ctx   = UsualCtx->new;
my $now   = 1_700_000_000_000;
my $press = 1_699_999_400_000;
my $D     = 600_000;

my (@inserted, @updated, @replays, @kind_writes, @stock, @writer_rows, @moved, @commands, @messages, @backups);
my %db_rows;

sub candidate {
	my ($signature, $template) = @_;
	my ($type) = split /:/, $signature, 2;
	return {
		signature => $signature,
		type => $type,
		count => 3,
		share => 0.5,
		template => ($template || {}),
	};
}

{
	no warnings 'redefine';
	local *subs::rightNow = sub { return $now };
	local *subs::db_insert = sub {
		my ($table, $row) = @_;
		push @inserted, { %{$row} };
		return 1;
	};
	local *subs::db_update = sub {
		my ($table, $set, $where) = @_;
		push @updated, { set => { %{$set} }, where => { %{$where} } };
		return 1;
	};
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		if (($args[1] // '') eq 'sms' && $db_rows{'sms'}) {
			return UsualRows->new([ $db_rows{'sms'} ]);
		}
		return UsualRows->new([]);
	};
	local *subs::note_decrypter = sub { my ($secret, $content) = @_; return defined $content ? "$content" : '' };
	local *subs::note_encrypter = sub { my ($secret, $content) = @_; return defined $content ? "$content" : undef };
	local *subs::backup_now = sub { push @backups, [ @_ ]; return { status => 'done' } };
	local *Manager::sms_message_send = sub { push @messages, [ @_ ]; return ($_[0], $_[1], 'test') };
	local *subs::appt_header_printer = sub { return ('<header/>', { app => $_[0]{'app'} }) };
	local *subs::usual_appointment_maker = sub { return ({}, [], undef, undef) };
	local *subs::usual_task_replay = sub {
		my ($c, $app, $parent, $start, $duration, $tasks, %opt) = @_;
		push @replays, {
			app => $app, parent => $parent, start => $start,
			duration => $duration, tasks => $tasks, %opt,
		};
		return { rows => [], apps => [] };
	};
	local *subs::usual_kind_set = sub {
		my ($app, $signature, $at) = @_;
		push @kind_writes, { app => $app, signature => $signature, at => $at };
		return $signature;
	};
	local *Manager::appointment_writer = sub {
		my ($c, $row) = @_;
		push @writer_rows, { %{$row} };
		return { %{$row}, uuid => ($row->{'uuid'} || 'written-uuid') };
	};
	local *Manager::appointment_stock_movement = sub {
		push @stock, [ @_ ];
		return;
	};
	local *subs::warehouse_place_for = sub { return 'pantry' };
	local *subs::warehouse_movement = sub { push @moved, { %{ $_[0] } }; return };
	local *subs::run_command = sub { push @commands, [ @_ ]; return 1 };
	local *subs::settings_grabber = sub { return {} };
	local *subs::setting_grabber = sub { return undef };
	local *subs::setting_setter = sub { return 1 };
	local *subs::ui = sub { return $_[0] };
	local *subs::format_name = sub { return $_[0] };
	local *subs::numeric_formatter = sub { return $_[0] };

	# ------------------------------------------------------------ usual stop
	@inserted = (); @updated = (); @replays = (); @kind_writes = ();
	my $stop_profile = {
		app => 'coffee',
		duration => $D,
		tasks => [ { task => 'sugar', uuid => 't1', fraction => 0.5 } ],
		candidates => [ candidate('stop') ],
		chosen => 'stop',
		ambiguous => 0,
	};
	my $stop = &subs::usual_apply($ctx,
		app => 'coffee', kind => 'usual', timestamp => $press, server_time => $now,
		uuid => 'uuid-stop', profile => $stop_profile, duration => $D, settings => {},
	);
	is($stop->{'uuid'}, 'uuid-stop', 'the stop usual keeps the press uuid');
	is(scalar @inserted, 1, 'one parent row is written');
	my $row = $inserted[0];
	is($row->{'timestamp'}, $press, 'the parent is stamped at the press');
	is($row->{'duration'}, $D, 'a usual end carries a positive length');
	is($row->{'type'}, 'stop', 'the parent is a stop row');
	is($row->{'status'}, 'usual', 'and says a usual wrote it');
	is($row->{'stop_seen'}, 'yes', 'and is already closed');
	ok(!exists $row->{'stop_timestamp'}, 'a usual row carries no stop_timestamp');
	is(scalar @replays, 1, 'the checklist is replayed once');
	is($replays[0]{'start'}, $press - $D, 'a usual task base is one length before the press');
	is($replays[0]{'duration'}, $D, 'the replay length is the learned length');
	is($replays[0]{'press_ms'}, $press, 'the checklist is marked at the press');
	is(scalar @stock, 0, 'a plain stop does not move stock');

	# -------------------------------------------------------- pre-usual stop
	@inserted = (); @updated = (); @replays = ();
	my $pre = &subs::usual_apply($ctx,
		app => 'coffee', kind => 'pre_usual', timestamp => $press, server_time => $now,
		uuid => 'uuid-pre', profile => $stop_profile, duration => $D, settings => {},
	);
	is($pre->{'uuid'}, 'uuid-pre', 'the pre-usual keeps the press uuid');
	$row = $inserted[0];
	is($row->{'timestamp'}, $press, 'a pre-usual parent is stamped at the press');
	is($row->{'type'}, 'stop', 'a pre-usual is a stop too');
	is($row->{'stop_seen'}, 'yes', 'and is already closed');
	is($row->{'duration'}, -$D, 'a pre-usual carries a negative length');
	is($replays[0]{'start'}, $press, 'a pre-usual task base is the press');
	is($replays[0]{'duration'}, $D, 'its tasks run forward over the learned length');

	# ------------------------------------------------------- ambiguous asks
	@inserted = (); @updated = (); @replays = (); @writer_rows = (); @moved = (); @kind_writes = ();
	my $ambiguous = {
		app => 'vape',
		duration => $D,
		tasks => [],
		candidates => [ candidate('stop'), candidate('transaction:consume:77 Vape:Geek Bar', { vendor => '77 Vape', item => 'Geek Bar', total => 57 }) ],
		chosen => undef,
		ambiguous => 1,
	};
	my $ask = &subs::usual_apply($ctx,
		app => 'vape', kind => 'usual', timestamp => $press, server_time => $now,
		profile => $ambiguous, duration => $D, settings => {},
	);
	ok($ask->{'usual_ask'}, 'an ambiguous press asks instead of guessing');
	my @asked = @{ $ask->{'usual_ask'}{'candidates'} || [] };
	is(scalar @asked, 2, 'both kinds are offered');
	is($asked[0]{'signature'}, 'stop', 'the first candidate is the one the profile ordered');
	ok(defined $asked[0]{'label'} && length $asked[0]{'label'}, 'each candidate has a label');
	ok(defined $asked[0]{'summary'}, 'and a summary');
	ok(defined $asked[0]{'side_effect'}, 'and a side_effect flag');
	is(scalar @inserted, 0, 'an ambiguous press writes no parent row');
	is(scalar @replays, 0, 'and replays no tasks');
	is(scalar @writer_rows, 0, 'and writes no writer row');
	is(scalar @moved, 0, 'and moves no stock');

	# --------------------------------------------------- a chosen kind writes
	my $chosen = &subs::usual_apply($ctx,
		app => 'vape', kind => 'usual', signature => 'stop', timestamp => $press,
		server_time => $now, uuid => 'uuid-chosen', profile => $ambiguous,
		duration => $D, settings => {},
	);
	is($chosen->{'uuid'}, 'uuid-chosen', 'the chosen kind writes');
	is(scalar @inserted, 1, 'with the parent row');
	is(scalar @kind_writes, 0, 'and remembers nothing unless asked');

	# -------------------------------------------------- remember on/off
	@kind_writes = ();
	&subs::usual_apply($ctx,
		app => 'vape', kind => 'usual', signature => 'stop', remember => 1,
		timestamp => $press, server_time => $now, profile => $ambiguous,
		duration => $D, settings => {},
	);
	is(scalar @kind_writes, 1, 'the checked box stores the choice');
	is($kind_writes[0]{'app'}, 'vape', 'for this app');
	is($kind_writes[0]{'signature'}, 'stop', 'the chosen signature');
	is($kind_writes[0]{'at'}, $now, 'and the moment it was chosen');

	@kind_writes = ();
	&subs::usual_apply($ctx,
		app => 'vape', kind => 'usual', signature => 'stop', remember => 0,
		timestamp => $press, server_time => $now, profile => $ambiguous,
		duration => $D, settings => {},
	);
	is(scalar @kind_writes, 0, 'an unchecked box stores nothing');

	# ------------------------------------------------------ transaction replay
	@inserted = (); @writer_rows = (); @moved = (); @stock = ();
	my $tx_template = {
		amount => -10, tax => -1.3, total => -11.3, quantity => 2, unit => 'each',
		item => 'Coke', vendor => 'Depot', account => 'cash', movement => 'expense',
		currency => 'CAD', state => 'paid',
		data_template => encode_json({
			expense => {
				'old-line' => { item => 'Old', quantity => 1, unit => 'each', amount => -5, tax => -0.65, total => -5.65 },
				totals => { amount => -5, tax => -0.65, total => -5.65, tendered => '10', change => '4.35' },
			},
		}),
	};
	my $tx_profile = {
		app => 'store', duration => 0, tasks => [],
		candidates => [ candidate('transaction:expense:Depot:Coke', $tx_template) ],
		chosen => 'transaction:expense:Depot:Coke', ambiguous => 0,
	};
	my $tx = &subs::usual_apply($ctx,
		app => 'store', kind => 'usual', signature => 'transaction:expense:Depot:Coke',
		timestamp => $press, server_time => $now, uuid => 'uuid-tx',
		profile => $tx_profile, duration => 0, settings => {},
	);
	is($tx->{'uuid'}, 'uuid-tx', 'the transaction keeps the press uuid');
	is(scalar @writer_rows, 1, 'the transaction goes through the appointment writer');
	my $written = $writer_rows[0];
	is($written->{'type'}, 'transaction', 'as a transaction');
	is($written->{'status'}, 'usual', 'stamped usual');
	is($written->{'timestamp'}, $press, 'at the press');
	is($written->{'item'}, 'Coke', 'with the learned item');
	is($written->{'total'}, -11.3, 'and the learned total');
	is($written->{'duration'}, 5000, 'a money row keeps the register length');
	ok($written->{'quiet_child'}, 'written as a quiet child so the press forks once');
	my $tx_data = decode_json($written->{'data'});
	is($tx_data->{'expense'}{'totals'}{'total'}, -11.3, 'the expense total is rebuilt from the learned template');
	is($tx_data->{'expense'}{'totals'}{'amount'}, -10, 'and its amount');
	ok(!exists $tx_data->{'expense'}{'totals'}{'tendered'}, 'a stale cash total is not carried');
	my ($tx_line) = grep { $_ ne 'totals' } keys %{ $tx_data->{'expense'} };
	is($tx_data->{'expense'}{$tx_line}{'total'}, -11.3, 'the line total matches the new row');
	is($tx_data->{'expense'}{$tx_line}{'item'}, 'Coke', 'and the learned item');
	is($tx_data->{'expense'}{$tx_line}{'quantity'}, 2, 'and quantity');
	is(scalar @moved, 1, 'stock moves once for the item');
	is($moved[0]{'place'}, 'pantry', 'at the item place');
	is($moved[0]{'quantity'}, 2, 'an expense puts the quantity in');
	is($moved[0]{'reason'}, 'expense', 'with the movement as its reason');

	# ------------------------------------------------- image row before capture
	@inserted = (); @updated = (); @replays = ();
	my $image_profile = {
		app => 'camera', duration => 0, tasks => [],
		candidates => [ candidate('image:1:phone', { camera => 1, data => { camera => 1, machine => 'phone' } }) ],
		chosen => 'image:1:phone', ambiguous => 0,
	};
	my $image = &subs::usual_apply($ctx,
		app => 'camera', kind => 'usual', signature => 'image:1:phone',
		timestamp => $press, server_time => $now, uuid => 'uuid-image',
		profile => $image_profile, duration => 0, settings => {},
	);
	is(scalar @inserted, 1, 'the image row is written first');
	my $image_row = $inserted[0];
	is($image_row->{'type'}, 'image', 'as an image');
	is($image_row->{'file'}, '[]', 'with an empty file list for the capture to fill');
	is($image_row->{'uuid'}, 'uuid-image', 'on the uuid the capture will name');
	my $meta = decode_json($image_row->{'data'});
	is($meta->{'camera'}, 1, 'the learned camera is in its data');
	is($meta->{'machine'}, 'phone', 'and the learned machine');
	ok($image->{'capture'}, 'the reply asks the client for the capture');
	is($image->{'capture'}{'kind'}, 'image', 'of an image');
	is($image->{'capture'}{'uuid'}, 'uuid-image', 'against the row just written');
		is($image->{'capture'}{'camera'}, 1, 'with the camera to open');
	is($image->{'capture'}{'machine'}, 'phone', 'and the machine to ask');
	is($image_row->{'duration'}, 5000, 'an image carries its own short length, not the session');
	my $image_pre = &subs::usual_apply($ctx,
		app => 'camera', kind => 'pre_usual', signature => 'image:1:phone',
		timestamp => $press, server_time => $now, uuid => 'uuid-image-pre',
		profile => $image_profile, duration => 0, settings => {},
	);
	is($inserted[1]{'duration'}, -5000, 'a pre-usual image keeps the anchor sign');

	# ------------------------------------------------------------- measure
	@inserted = (); @updated = ();
	my $measure_profile = {
		app => 'scale', duration => 0, tasks => [],
		candidates => [ candidate('measure', { measures => encode_json({ weight => 70 }), duration => 1500 }) ],
		chosen => 'measure', ambiguous => 0,
	};
	my $measure = &subs::usual_apply($ctx,
		app => 'scale', kind => 'usual', signature => 'measure',
		timestamp => $press, server_time => $now, uuid => 'uuid-measure',
		profile => $measure_profile, duration => 0, settings => {},
	);
	is($measure->{'uuid'}, 'uuid-measure', 'a measure row is written from the stored reading');
	is($inserted[0]{'measures'}, encode_json({ weight => 70 }), 'with the last stored value');
	is($inserted[0]{'duration'}, 1500, 'a measure keeps the row length, not the session');
	&subs::usual_apply($ctx,
		app => 'scale', kind => 'pre_usual', signature => 'measure',
		timestamp => $press, server_time => $now, uuid => 'uuid-measure-pre',
		profile => $measure_profile, duration => 0, settings => {},
	);
	is($inserted[1]{'duration'}, -1500, 'a pre-usual measure keeps the anchor sign');
	my $weather_profile = {
		app => 'weather_station', duration => 0, tasks => [],
		candidates => [ candidate('measure', { measures => encode_json({ temp => 20 }) }) ],
		chosen => 'measure', ambiguous => 0,
	};
	my $weather = &subs::usual_apply($ctx,
		app => 'weather_station', kind => 'usual', signature => 'measure',
		timestamp => $press, server_time => $now, profile => $weather_profile,
		duration => 0, settings => {},
	);
	ok($weather->{'no_usual'}, 'a weather measure refuses a stale reading');
	like($weather->{'error'} // '', qr/fresh reading/, 'and names why');

	# ----------------------------------------------------------------- sms
	$db_rows{'sms'} = {
		data => encode_json({ digits => '5551234567', message => 'on my way home' }),
		ost => '123',
	};
	my $sms_profile = {
		app => 'phone', duration => 0, tasks => [],
		candidates => [ candidate('sms') ], chosen => 'sms', ambiguous => 0,
	};
	my $sms_ask = &subs::usual_ask_payload($sms_profile, $ctx);
	is(scalar @{ $sms_ask->{'candidates'} }, 1, 'the sms kind is offered');
	is($sms_ask->{'candidates'}[0]{'summary'}, 'SMS to 5551234567: on my way home',
		'the consent line names the number and the message');
	@inserted = (); @messages = ();
	my $sms_unconfirmed = &subs::usual_apply($ctx,
		app => 'phone', kind => 'usual', signature => 'sms',
		timestamp => $press, server_time => $now, uuid => 'uuid-sms-ask',
		profile => $sms_profile, duration => 0, settings => {},
	);
	ok($sms_unconfirmed->{'usual_ask'}, 'a message press asks even when the kind is remembered');
	is(scalar @messages, 0, 'and sends nothing before the dialog is answered');
	is(scalar @inserted, 0, 'and writes no row before the dialog is answered');
	@inserted = (); @messages = ();
	my $sms = &subs::usual_apply($ctx,
		app => 'phone', kind => 'usual', signature => 'sms', confirm => 1,
		timestamp => $press, server_time => $now, uuid => 'uuid-sms',
		profile => $sms_profile, duration => 0, settings => {},
	);
	is(scalar @messages, 1, 'the SMS is sent through the one send helper');
	is($messages[0][0], '5551234567', 'to the learned number');
	is($messages[0][1], 'on my way home', 'with the learned message');
	is(scalar @inserted, 1, 'and a new sms row is written');
	is($inserted[0]{'type'}, 'sms', 'as an sms');
	is($inserted[0]{'status'}, 'usual', 'stamped usual');
	is($inserted[0]{'duration'}, 5000, 'with the message length');
	my $sms_data = decode_json($inserted[0]{'data'});
	is($sms_data->{'digits'}, '5551234567', 'the row carries the number');
	is($sms_data->{'message'}, 'on my way home', 'and the message');
	delete $db_rows{'sms'};

	# ------------------------------------------------------------- backup
	@inserted = (); @writer_rows = (); @backups = ();
	my $backup_profile = {
		app => 'me', duration => 0, tasks => [],
		candidates => [ candidate('backup') ], chosen => 'backup', ambiguous => 0,
	};
	my $backup = &subs::usual_apply($ctx,
		app => 'me', kind => 'usual', signature => 'backup',
		timestamp => $press, server_time => $now, uuid => 'uuid-backup',
		profile => $backup_profile, duration => 0, settings => {},
	);
	is(scalar @backups, 1, 'the backup rail is called once');
	ok(!length($ctx->param('reason') // ''), 'and the press reason is put back');
	is(scalar @writer_rows, 1, 'the press is recorded');
	is($writer_rows[0]{'type'}, 'backup', 'as a backup row');

	# --------------------------------------------------------- every movement
	ok(scalar @gb::movements > 0, 'the movement catalogue is loaded');
	my %known = map { $_ => 1 } qw(session capture money measure message command row control none);
	my (@empty, @unknown);
	foreach my $type ( @gb::movements ) {
		my $mode = &subs::usual_mode($type);
		push @empty, $type unless defined $mode && length $mode;
		push @unknown, "$type=$mode" unless $known{ $mode // '' };
	}
	is_deeply(\@empty, [], 'every movement has a defined, non-empty mode');
	is_deeply(\@unknown, [], 'and every mode is one of the documented ones');

	# `none` is only for actions that are not records at all.
	my %is_record = map { $_ => 1 } qw(
		stop start usual transaction purchase record video audio screen image
		camera scan measure sms email note text entry assign config encrypt
		software studio snapshot command kill backup
	);
	my @nones = grep { $is_record{$_} && &subs::usual_mode($_) eq 'none' } @gb::movements;
	is_deeply(\@nones, [], 'a record movement is never marked none');
	foreach my $type (qw(web view search calc scraper open file listen public all)) {
		is(&subs::usual_mode($type), 'none', "$type is a non-record action");
	}
	is(&subs::usual_mode('transaction'), 'money', 'a transaction is money');
	is(&subs::usual_mode('measure'), 'measure', 'a measure is a measure');
	is(&subs::usual_mode('command'), 'command', 'a command is a command');
	is(&subs::usual_mode('pause'), 'control', 'a pause is a control');

	# ------------------------------------------------------------- control
	@inserted = (); @writer_rows = (); @kind_writes = ();
	my $control_profile = {
		app => 'coffee', duration => 0, tasks => [],
		candidates => [ candidate('pause') ], chosen => 'pause', ambiguous => 0,
	};
	my $control = &subs::usual_apply($ctx,
		app => 'coffee', kind => 'usual', signature => 'pause', remember => 1,
		timestamp => $press, server_time => $now, profile => $control_profile,
		duration => 0, settings => {},
	);
	ok($control->{'no_usual'}, 'a control kind refuses the usual press');
	ok(defined $control->{'error'} && length $control->{'error'}, 'with a reason to show');
	is(scalar @inserted, 0, 'and writes nothing');
	is(scalar @writer_rows, 0, 'and hands nothing to the writer');
	is(scalar @kind_writes, 0, 'a refused press is never remembered as the usual');
}

# ------------------------------------------------------- the source wiring
my $root = root();
my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc5.pm");
like($routes, qr/\[\s*18253,\s*'get',\s*'\/manager\/usual',\s*'action_18253'\s*\]/,
	'the GET /manager/usual row is registered');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc5.pm");
like($controller, qr/sub action_18253\b/, 'the controller defines the usual read');
like($controller, qr/# GET \/manager\/usual/, 'its action carries the path it answers');
like($controller, qr/my \$gate_type = \(\$raw_type eq 'pre_usual'\) \? 'usual' : \$raw_type;/,
	'pre_usual is mapped to usual for the peer gate');
like($controller, qr/'reset ' \. \(\$c->param\('type'\) \/\/ '\?'\)/,
	'the reset log still names the actual type');
like($controller, qr/usual_ask_payload\(\$profile, \$c\)/,
	'the read passes the session to the ask payload');
like($controller, qr/Several usuals/, 'an ambiguous read line says so');

my $usualwrite = read_file("$root/lib/JawnOS/Domain/UsualWrite.pm");
like($usualwrite, qr/Manager::sms_message_send\(\$digits, \$message\)/,
	'the sms usual sends through the one helper');
like($usualwrite, qr/note_decrypter/, 'and reopens the stored sms text first');
like($usualwrite, qr/&subs::ui\('SMS to'\)/, 'the dialog previews the number and text');
like($usualwrite, qr/backup_now/, 'the backup usual uses the backup rail');
like($usualwrite, qr/\$result->\{'usual_ask'\}/, 'the remember gate reads the result');
like($usualwrite, qr/\$mode eq 'message' && !\$opt\{'confirm'\}/,
	'a message asks before it sends even when the kind is remembered');
like($usualwrite, qr/type => 'stop',/, 'the usual parent is a stop');
like($usualwrite, qr/stop_seen => 'yes',/, 'and is closed');

my $part14 = read_file("$root/lib/JawnOS/Manager/Part14.pm");
like($part14, qr/usual_confirm/, 'the reset press carries the dialog confirmation');
like($part14, qr/elsif \(\$type eq 'reset'\) \{/, 'reset has its own branch');
like($part14, qr/elsif \(\$type eq 'usual' \|\| \$type eq 'pre_usual'\) \{/,
	'usual and pre_usual share the replay branch');
unlike($part14, qr/elsif \(\$type =~ 'reset' \|\| \$type =~ 'usual'\)/,
	'the combined reset/usual branch is gone');
like($part14, qr/\$type !~ \/\^\(\?:stop\|cancel\|resume\|pause\|delay\|usual\|pre_usual\)\$\//,
	'a usual press on an app with no rows is not coerced to add');

done_testing();
