package subs;

# UsualWrite: the write side of the usual/pre-usual press. Usual.pm learns the
# profile; this file turns one chosen signature into the row(s) a press writes.
# Both ends of a session are stamped at the press: `usual` (pressed at the end)
# carries a positive length and its tasks start a length before the press,
# `pre_usual` (pressed at the start) carries a negative length and its tasks run
# forward from the press. Nothing here asks a second time - the kind dialog is
# the consent gate - and a kind whose writer cannot be called with a template
# refuses instead of fabricating one.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Mojo::JSON qw(decode_json encode_json);

# Every movement the rail can send has a mode, so a usual press can say what it
# would do before it does it. `none` is a deliberate answer for an action that
# is not a record at all (a search, a view, a calculation); a real record never
# lands there.
my %MODE = map { $_ => 'row' } qw(
	add assign category config dingaling encrypt entry id mix note receipt
	register request snapshot software studio telephone text ticket
);
$MODE{$_} = 'session' for qw(stop start usual depart);
$MODE{$_} = 'capture' for qw(record video audio screen image camera scan upload);
$MODE{$_} = 'money'   for qw(transaction purchase);
$MODE{$_} = 'measure' for qw(measure);
$MODE{$_} = 'message' for qw(sms email msg);
$MODE{$_} = 'command' for qw(command kill);
$MODE{$_} = 'control' for qw(reset pause resume cancel delay complete renew quit);
$MODE{$_} = 'none'    for qw(all calc decrypt file listen open public scraper search view web);

# The kinds that can move money, send something, run a command or generate. The
# dialog marks these so the person knows what the checkbox consents to.
my %SIDE = map { $_ => 1 } qw(
	transaction purchase sms email msg dingaling command kill backup software studio
);

# A row's data column is JSON when present. A caller may already hold the hash.
my $data_hash = sub {
	my ($raw) = @_;
	return {} unless defined $raw;
	return $raw if ref $raw eq 'HASH';
	return {} unless length "$raw";
	my $decoded = eval { decode_json($raw) };
	return (ref $decoded eq 'HASH') ? $decoded : {};
};

# Where the press sits on the learned span. `usual` is pressed at the end, so
# the session is the D before it and its tasks run from press - D; `pre_usual`
# is pressed at the start, so the session is the D after it and its tasks run
# from the press. The parent row is stamped at the press either way.
my $anchors = sub {
	my ($kind, $press, $duration) = @_;
	$press = 0 + ($press // 0);
	my $D = abs(0 + ($duration // 0));
	my $pre = (($kind // '') eq 'pre_usual') ? 1 : 0;
	return {
		press => $press,
		D => $D,
		pre => $pre,
		signed => $pre ? -$D : $D,
		sign => $pre ? -1 : 1,
		start => $pre ? $press : $press - $D,
		task_start => $pre ? $press : $press - $D,
		end => $pre ? $press + $D : $press,
	};
};

# The length a point-kind row carries: the learned row length when the template
# has one, else the shape's own small default, keeping the anchor's sign.
my $point_duration = sub {
	my ($template, $fallback, $sign) = @_;
	my $value = $template->{'duration'};
	$value = $fallback
		unless defined $value && "$value" =~ /^-?[0-9]+(?:\.[0-9]+)?$/ && $value != 0;
	$value = abs($value);
	return (($sign // 1) < 0) ? -$value : $value;
};

# The learned SMS: the newest sms row's encrypted digits/message, falling back to
# its encrypted text when the data is not the JSON it once was. A message that
# cannot be opened is no source at all, so nothing is ever sent blank.
my $sms_source = sub {
	my ($app, $c) = @_;
	my $row = &subs::db_query(
		'select * from appointments where app = ? and type = ? order by cast(timestamp as integer) desc limit 1',
		$app, 'sms'
	)->hashes->[0];
	return undef unless ref $row eq 'HASH';
	my $suds = (ref $c) ? $c->{'suds'} : undef;
	my $plain = defined $row->{'data'}
		? eval { &subs::note_decrypter($suds, $row->{'data'}, $row->{'ost'}) }
		: '';
	my $info = (defined $plain && length "$plain") ? eval { decode_json($plain) } : undef;
	if (ref $info ne 'HASH' || !defined $info->{'message'} || !length "$info->{'message'}") {
		my $notes = eval { &subs::note_decrypter($suds, $row->{'start_notes'} // $row->{'notes'}, $row->{'ost'}) } // '';
		$info = { message => $notes, digits => (ref $info eq 'HASH' ? $info->{'digits'} : undef) };
	}
	my $message = $info->{'message'} // '';
	return undef unless length "$message";
	my $digits = $info->{'digits'};
	$digits = &subs::setting_grabber({ app => $app, setting => 'phone' })
		if !defined $digits || !length "$digits";
	return { digits => ($digits // ''), message => $message };
};

# Which mode a movement/type plays. An unknown type is treated as a plain row,
# which is the safe default: the row writer copies only scalar fields.
sub usual_mode {
	my ($type) = @_;
	$type = lc($type // '');
	return $MODE{$type} if defined $MODE{$type};
	return 'none' if !length $type;
	return 'row';
}

# The label and summary the choice dialog shows for one kind.
my $kind_label = sub {
	my ($signature, $template) = @_;
	$template ||= {};
	my ($type, @parts) = split /:/, ($signature // ''), -1;
	$type = '' unless defined $type;
	return &subs::ui('Stop') if $type eq 'stop';
	return &subs::ui('Image') if $type eq 'image' || $type eq 'camera';
	return &subs::ui('Scan') if $type eq 'scan';
	if ($type eq 'record') {
		my $recorder = $template->{'recorder'};
		$recorder = $parts[0] if !defined $recorder || !length "$recorder";
		return (defined $recorder && length "$recorder") ? &subs::format_name($recorder) : &subs::ui('Record');
	}
	return &subs::format_name($type) if length $type;
	return &subs::ui('Usual');
};

# The dialog's question: each candidate with the words a person reads, the
# learned summary and whether pressing it has an effect beyond the ledger.
sub usual_ask_payload {
	my ($profile, $c) = @_;
	$profile ||= {};
	my $app = $profile->{'app'} // '';
	my @candidates;
	foreach my $candidate ( @{ $profile->{'candidates'} || [] } ) {
		next unless ref $candidate eq 'HASH';
		my $signature = $candidate->{'signature'} // '';
		next unless length $signature;
		my $template = $candidate->{'template'} || {};
		my ($type) = split /:/, $signature, 2;
		$type = '' unless defined $type;
		my $summary = &subs::usual_summary_line($profile, $signature);
		if ($type eq 'command' || $type eq 'kill') {
			my $command = &subs::setting_grabber({ app => $app, setting => $type });
			$summary = &subs::ui('Command') . ': ' . $command
				if defined $command && length "$command";
		}
		if ($type eq 'sms') {
			my $source = $sms_source->($app, $c);
			if ($source) {
				my $message = $source->{'message'};
				$message =~ s/\s+/ /g;
				$message = substr($message, 0, 40) . '...' if length($message) > 40;
				$summary = &subs::ui('SMS to') . ' ' . ($source->{'digits'} // '') . ': ' . $message;
			}
			else {
				$summary = &subs::ui('SMS (no stored message)');
			}
		}
		push @candidates, {
			signature => $signature,
			label => $kind_label->($signature, $template),
			summary => $summary,
			side_effect => $SIDE{$type} ? 1 : 0,
		};
	}
	return {
		app => $app,
		candidates => \@candidates,
		chosen => $profile->{'chosen'},
	};
}

# The capture the client still has to take, filed on the row already written.
sub usual_capture_request {
	my ($app, $uuid, $kind, $timestamp, $template) = @_;
	$template ||= {};
	my %capture = (
		app => $app,
		uuid => $uuid,
		kind => $kind,
		timestamp => $timestamp,
	);
	foreach my $key (qw(camera machine feed recorder screen screen_name)) {
		next unless defined $template->{$key} && length "$template->{$key}";
		$capture{$key} = $template->{$key};
	}
	return \%capture;
}

# A stop (or a start-type) usual: one parent usual row stamped at the press,
# the default model/options the app would have started, the checklist replayed
# at its learned fractions, and the stock move a consuming app earns.
sub usual_stock_stop {
	my ($c, %opt) = @_;
	my $app = $opt{'app'};
	my $signature = $opt{'signature'} // 'stop';
	my $at = $anchors->($opt{'kind'}, $opt{'timestamp'}, $opt{'duration'});
	my $press = $at->{'press'};
	my $D = $at->{'D'};
	my $server_time = $opt{'server_time'} || &subs::rightNow();
	my $uuid = (defined $opt{'uuid'} && length $opt{'uuid'}) ? $opt{'uuid'} : &subs::random_string_creator(40);
	my $template = $opt{'template'} || {};

	my $quantity = (defined $opt{'quantity'} && length "$opt{'quantity'}") ? $opt{'quantity'} : $template->{'quantity'};
	my $unit = (defined $opt{'unit'} && length "$opt{'unit'}") ? $opt{'unit'} : $template->{'unit'};
	my $manufacturer = $opt{'manufacturer'};

	my %row = (
		app => $app,
		timestamp => $press,
		type => 'usual',
		status => 'usual',
		duration => $at->{'signed'},
		server_time => $server_time,
		uuid => $uuid,
	);
	foreach my $key (qw(project notes file pos warranty source browser_tab_id)) {
		next unless defined $opt{$key} && length "$opt{$key}";
		$row{ ($key eq 'notes' ? 'start_notes' : $key) } = $opt{$key};
	}
	$row{'seen'} = $opt{'seen'} if defined $opt{'seen'};
	$row{'quantity'} = $quantity if defined $quantity && length "$quantity";
	$row{'unit'} = $unit if defined $unit && length "$unit";
	&subs::db_insert('appointments', \%row);

	my ($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $press });

	my ($model, $options, $jmodel, $joptions) = &subs::usual_appointment_maker({
		app => $app,
		uuid => $uuid,
		timestamp => $press,
		duration => $D,
		type => 'usual',
	}, {
		project => $opt{'project'},
	});
	$model ||= {};
	$unit = $model->{'unit'} if (!defined $unit || !length "$unit") && $model->{'unit'};
	$quantity = $model->{'quantity'} if (!defined $quantity || !length "$quantity") && $model->{'quantity'};
	$manufacturer = $model->{'manufacturer'} if (!defined $manufacturer || !length "$manufacturer") && $model->{'manufacturer'};
	&subs::db_update('appointments', {
		server_time => &subs::rightNow(),
		model => $jmodel,
		options => $joptions,
		unit => $unit,
		quantity => $quantity,
		manufacturer => $manufacturer,
	}, { uuid => $uuid, app => $app });

	my $profile = ref $opt{'profile'} eq 'HASH' ? $opt{'profile'} : {};
	my $tasks = $profile->{'tasks'} || $opt{'tasks'} || [];
	&subs::usual_task_replay($c, $app, $uuid, $at->{'task_start'}, $D, $tasks,
		server_time => $server_time, press_ms => $press);

	if ($signature eq 'stop:stock') {
		&Manager::appointment_stock_movement($c, $app, 'stop', $quantity, $unit, $at->{'end'}, $uuid);
	}
	return {
		uuid => $uuid,
		appt_header => $appt_header,
		header_appts => $header_appts,
		signature => $signature,
	};
}

# A transaction/purchase replay: the template's money fields become a new row
# at the press, written through the one writer so the warehouse ledger mirrors
# it, then the stock move the register route makes when the place is known.
sub usual_transaction_write {
	my ($c, %opt) = @_;
	my $app = $opt{'app'};
	my $type = $opt{'type'} || 'transaction';
	my $template = $opt{'template'} || {};
	my $at = $anchors->($opt{'kind'}, $opt{'timestamp'}, $opt{'duration'});
	my $press = $at->{'press'};
	my $server_time = $opt{'server_time'} || &subs::rightNow();
	my $uuid = (defined $opt{'uuid'} && length $opt{'uuid'}) ? $opt{'uuid'} : &subs::random_string_creator(40);

	my %row = (
		app => $app,
		type => $type,
		status => 'usual',
		timestamp => $press,
		duration => 5000,
		server_time => $server_time,
		uuid => $uuid,
		quiet_child => 1,
	);
	foreach my $key (qw(amount tax total quantity unit item vendor account movement currency state)) {
		next unless defined $template->{$key} && length "$template->{$key}";
		$row{$key} = $template->{$key};
	}

	# The profile keeps the newest row's raw data, whose lines and totals are the
	# old transaction's. Rebuild the expense/income bucket from the learned
	# scalars so the details view matches the new row; keep one line's key (or
	# mint one) and never leave the old cash totals behind.
	my $data = $template->{'data_template'};
	my $doc = (defined $data && length "$data") ? eval { decode_json($data) } : undef;
	$doc = (ref $doc eq 'HASH') ? $doc : {};
	my $movement = $template->{'movement'} // '';
	$movement = 'expense' if !length $movement && $type eq 'purchase';
	if ($movement eq 'expense' || $movement eq 'income') {
		my $bucket = (ref $doc->{$movement} eq 'HASH') ? $doc->{$movement} : {};
		my ($line_key) = grep { $_ ne 'totals' } keys %{$bucket};
		$line_key = &subs::random_string_creator(12)
			unless defined $line_key && length $line_key;
		my %line;
		foreach my $key (qw(item quantity unit amount tax total state account)) {
			next unless defined $template->{$key} && length "$template->{$key}";
			$line{$key} = $template->{$key};
		}
		$line{'app'} = $app;
		my %totals;
		foreach my $key (qw(amount tax total quantity unit item account vendor)) {
			next unless defined $template->{$key} && length "$template->{$key}";
			$totals{$key} = $template->{$key};
		}
		$doc->{$movement} = { $line_key => \%line, totals => \%totals };
	}
	$row{'data'} = encode_json($doc) if keys %{$doc};

	my $written = &Manager::appointment_writer($c, \%row);
	$uuid = $written->{'uuid'}
		if ref $written eq 'HASH' && defined $written->{'uuid'} && length "$written->{'uuid'}";

	# Move stock exactly as the register does: a sale takes out, a purchase puts
	# in, and only when the place is known.
	my $item = $template->{'item'} // '';
	if (length $item) {
		my $place = &subs::warehouse_place_for($app, $item);
		if (defined $place && length $place) {
			my $movement = $template->{'movement'} // $type;
			my $sign = ($movement eq 'income') ? -1 : 1;
			my $quantity = &subs::numeric_formatter($template->{'quantity'}) + 0;
			my $unit = $template->{'unit'} // '';
			my $account = $template->{'account'};
			foreach my $line ( split ',', $item ) {
				next unless length $line;
				&subs::warehouse_movement({
					item => $line,
					quantity => $quantity * $sign,
					unit => $unit,
					place => $place,
					account => $account,
					timestamp => $press,
					app_uuid => $uuid,
					type => 'stock',
					reason => $movement,
					source => $app,
					source_uuid => $uuid,
				});
			}
		}
	}

	my ($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $press });
	return {
		uuid => $uuid,
		appt_header => $appt_header,
		header_appts => $header_appts,
		signature => $opt{'signature'},
	};
}

# An image or scan usual: the row is written first so the client's camera/scan
# post has a uuid to file the bytes on, and the reply names the capture to take.
sub usual_image_write {
	my ($c, %opt) = @_;
	my $app = $opt{'app'};
	my $type = $opt{'type'} || 'image';
	my $template = $opt{'template'} || {};
	my $data = $template->{'data'} || {};
	my $at = $anchors->($opt{'kind'}, $opt{'timestamp'}, $opt{'duration'});
	my $press = $at->{'press'};
	my $server_time = $opt{'server_time'} || &subs::rightNow();
	my $uuid = (defined $opt{'uuid'} && length $opt{'uuid'}) ? $opt{'uuid'} : &subs::random_string_creator(40);
	my @parts = split /:/, ($opt{'signature'} // ''), -1;

	my ($camera, $feed, $machine);
	if ($type eq 'scan') {
		$feed = defined $template->{'feed'} ? $template->{'feed'} : $data->{'feed'};
		$feed = $parts[1] if (!defined $feed || !length "$feed") && defined $parts[1] && length $parts[1];
		$machine = defined $data->{'machine'} ? $data->{'machine'} : $template->{'machine'};
		$machine = $parts[2] if (!defined $machine || !length "$machine") && defined $parts[2] && length $parts[2];
	}
	else {
		$camera = defined $template->{'camera'} ? $template->{'camera'} : $data->{'camera'};
		$camera = $parts[1] if (!defined $camera || !length "$camera") && defined $parts[1] && length $parts[1];
		$camera = 0 unless defined $camera && length "$camera";
		$machine = defined $data->{'machine'} ? $data->{'machine'} : $template->{'machine'};
		$machine = $parts[2] if (!defined $machine || !length "$machine") && defined $parts[2] && length $parts[2];
	}

	my %meta;
	$meta{'camera'} = $camera if defined $camera;
	$meta{'feed'} = $feed if defined $feed && length "$feed";
	$meta{'machine'} = $machine if defined $machine && length "$machine";

	&subs::db_insert('appointments', {
		app => $app,
		timestamp => $press,
		type => $type,
		status => 'usual',
		duration => $point_duration->($template, 5000, $at->{'sign'}),
		data => encode_json(\%meta),
		file => '[]',
		server_time => $server_time,
		uuid => $uuid,
		seen => $press <= &subs::rightNow() + 1000 ? 'yes' : undef,
	});

	my ($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $press });
	my $capture = usual_capture_request($app, $uuid, $type, $press, {
		camera => $camera,
		feed => $feed,
		machine => $machine,
	});
	return {
		uuid => $uuid,
		appt_header => $appt_header,
		header_appts => $header_appts,
		capture => $capture,
		signature => $opt{'signature'},
	};
}

# A record usual. Pressed at the start it is the live capture the record branch
# writes (unseen, so the Alarm starts the recorder on the named machine);
# pressed at the end it is the completed span, never a live capture.
sub usual_record_write {
	my ($c, %opt) = @_;
	my $app = $opt{'app'};
	my $template = $opt{'template'} || {};
	my $data = $template->{'data'} || {};
	my @parts = split /:/, ($opt{'signature'} // ''), -1;

	my $recorder = $template->{'recorder'};
	$recorder = $data->{'recorder'} if !defined $recorder || !length "$recorder";
	$recorder = $parts[1] if (!defined $recorder || !length "$recorder") && defined $parts[1] && length $parts[1];
	$recorder = &subs::setting_grabber({ app => $app, setting => 'record' }) if !defined $recorder || !length "$recorder";
	$recorder = 'system' if !defined $recorder || !length "$recorder";

	my $camera = defined $template->{'camera'} ? $template->{'camera'} : $data->{'camera'};
	$camera = $parts[2] if (!defined $camera || !length "$camera") && defined $parts[2] && length $parts[2];
	my $machine = defined $data->{'machine'} ? $data->{'machine'} : $template->{'machine'};
	$machine = $parts[3] if (!defined $machine || !length "$machine") && defined $parts[3] && length $parts[3];
	$machine = $opt{'capture_machine'}
		if (!defined $machine || !length "$machine") && defined $opt{'capture_machine'} && length "$opt{'capture_machine'}";
	my $screen = defined $data->{'screen'} ? $data->{'screen'} : $template->{'screen'};
	my $screen_name = defined $data->{'screen_name'} ? $data->{'screen_name'} : $template->{'screen_name'};

	my %rec = ( recorder => $recorder, machine => ($machine // '') );
	$rec{'camera'} = $camera if $recorder =~ /^video/ && defined $camera;
	$rec{'screen'} = $screen if defined $screen && length "$screen";
	$rec{'screen_name'} = $screen_name if defined $screen_name && length "$screen_name";

	my $at = $anchors->($opt{'kind'}, $opt{'timestamp'}, $opt{'duration'});
	my $press = $at->{'press'};
	my $server_time = $opt{'server_time'} || &subs::rightNow();
	my $uuid = (defined $opt{'uuid'} && length $opt{'uuid'}) ? $opt{'uuid'} : &subs::random_string_creator(40);

	my %row = (
		app => $app,
		type => 'record',
		status => 'usual',
		data => encode_json(\%rec),
		server_time => $server_time,
		uuid => $uuid,
	);
	if ($at->{'pre'}) {
		$row{'timestamp'} = $press;
		$row{'duration'} = $at->{'signed'};
		$row{'seen'} = undef;
		# The record branch starts system audio and security video inline; every
		# other source is started by the Alarm on the machine the row names.
		&Manager::record_video({ app => $app, uuid => $uuid, timestamp => $press }) if $recorder eq 'security';
		&Manager::record_audio({ app => $app, uuid => $uuid, timestamp => $press }) if $recorder eq 'system';
	}
	else {
		$row{'timestamp'} = $at->{'start'};
		$row{'duration'} = -$at->{'D'};
		$row{'stop_timestamp'} = $press;
		$row{'stop_seen'} = 'yes';
		$row{'seen'} = 'yes';
	}
	&subs::db_insert('appointments', \%row);

	my ($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $press });
	return {
		uuid => $uuid,
		appt_header => $appt_header,
		header_appts => $header_appts,
		signature => $opt{'signature'},
	};
}

# A measure usual repeats the last stored reading. A measure whose app fetches
# a fresh value (weather) is refused: a fabricated reading is worse than none.
sub usual_measure_write {
	my ($c, %opt) = @_;
	my $app = $opt{'app'};
	my $type = $opt{'type'} || 'measure';
	my $template = $opt{'template'} || {};

	# A weather-family app fetches its reading; a stored value is stale and is not
	# a new reading. Refuse by name rather than write yesterday's number.
	if (lc($app // '') =~ /^weather/ || lc($type) =~ /^weather/) {
		return { no_usual => 1, error => &subs::ui('This measure needs a fresh reading, not a repeat.') . ' (' . &subs::format_name($app) . ')' };
	}

	my $measures = $template->{'measures'};
	if (!defined $measures || !length "$measures") {
		my $last = &subs::db_query(
			'select measures from appointments where app = ? and type = ? and measures is not null order by cast(timestamp as integer) desc limit 1',
			$app, $type
		)->hashes->[0];
		$measures = $last->{'measures'} if $last;
	}
	return { no_usual => 1, error => &subs::ui('There is no reading to repeat yet.') . ' (' . &subs::format_name($type) . ')' }
		unless defined $measures && length "$measures";

	my $at = $anchors->($opt{'kind'}, $opt{'timestamp'}, $opt{'duration'});
	my $press = $at->{'press'};
	my $server_time = $opt{'server_time'} || &subs::rightNow();
	my $uuid = (defined $opt{'uuid'} && length $opt{'uuid'}) ? $opt{'uuid'} : &subs::random_string_creator(40);
	&subs::db_insert('appointments', {
		app => $app,
		timestamp => $press,
		type => $type,
		status => 'usual',
		duration => $point_duration->($template, 1000, $at->{'sign'}),
		measures => $measures,
		server_time => $server_time,
		uuid => $uuid,
	});
	my ($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $press });
	return {
		uuid => $uuid,
		appt_header => $appt_header,
		header_appts => $header_appts,
		signature => $opt{'signature'},
	};
}

# A message usual. Only SMS has a stored send template we can reopen: the
# newest sms row's encrypted digits and text. Re-sealing it and sending it again
# is the repeat; a row that cannot be opened refuses rather than sending blank.
# Email/msg have no reusable send template here, so they keep a named refusal.
sub usual_message_write {
	my ($c, %opt) = @_;
	my $app = $opt{'app'};
	my $type = $opt{'type'} || 'sms';
	return {
		no_usual => 1,
		error => &subs::ui('This message kind has no stored send template to repeat.')
			. ' (' . &subs::format_name($type) . ')',
	} if $type ne 'sms';

	my $source = $sms_source->($app, $c);
	return {
		no_usual => 1,
		error => &subs::ui('The SMS message could not be read.')
			. ' (' . &subs::format_name($app) . ')',
	} unless $source;
	my $digits = $source->{'digits'} // '';
	my $message = $source->{'message'} // '';
	return { no_usual => 1, error => &subs::ui('There is no phone number to send to.') }
		unless length $digits;
	return { no_usual => 1, error => &subs::ui('There is no message to send.') }
		unless length $message;

	my ($sent_digits, $sent_message) = &Manager::sms_message_send($digits, $message);
	$sent_digits = $digits unless defined $sent_digits && length "$sent_digits";
	$sent_message = $message unless defined $sent_message && length "$sent_message";

	my $at = $anchors->($opt{'kind'}, $opt{'timestamp'}, $opt{'duration'});
	my $press = $at->{'press'};
	my $server_time = $opt{'server_time'} || &subs::rightNow();
	my $uuid = (defined $opt{'uuid'} && length $opt{'uuid'}) ? $opt{'uuid'} : &subs::random_string_creator(40);
	my $suds = (ref $c) ? $c->{'suds'} : undef;
	my $data = &subs::note_encrypter($suds, encode_json({ digits => $sent_digits, message => $sent_message }));
	return { no_usual => 1, error => &subs::ui('The SMS could not be sealed for the ledger.') }
		unless defined $data && length "$data";

	my %row = (
		app => $app,
		timestamp => $press,
		type => 'sms',
		status => 'usual',
		duration => 5000,
		data => $data,
		server_time => $server_time,
		uuid => $uuid,
	);
	foreach my $key (qw(unit project file pos warranty source browser_tab_id)) {
		next unless defined $opt{$key} && length "$opt{$key}";
		$row{$key} = $opt{$key};
	}
	$row{'start_notes'} = $opt{'notes'} if defined $opt{'notes'} && length "$opt{'notes'}";
	$row{'seen'} = $opt{'seen'} if defined $opt{'seen'};
	&subs::db_insert('appointments', \%row);

	my ($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $press });
	return {
		uuid => $uuid,
		appt_header => $appt_header,
		header_appts => $header_appts,
		signature => $opt{'signature'},
	};
}

# A command usual runs the app's command again and writes the row it earned.
sub usual_command_write {
	my ($c, %opt) = @_;
	my $app = $opt{'app'};
	my $type = $opt{'type'} || 'command';
	my $settings = $opt{'settings'};
	my $command;
	$command = $settings->{$type} if ref $settings eq 'HASH';
	$command = &subs::setting_grabber({ app => $app, setting => $type })
		if !defined $command || !length "$command";
	$command = &subs::setting_grabber({ app => $app, setting => 'command' })
		if (!defined $command || !length "$command") && $type eq 'kill';
	return { no_usual => 1, error => &subs::ui('This app has no command to repeat.') . ' (' . &subs::format_name($app) . ')' }
		unless defined $command && length "$command";

	&subs::run_command($app, $command, $opt{'timestamp'});

	my $at = $anchors->($opt{'kind'}, $opt{'timestamp'}, $opt{'duration'});
	my $press = $at->{'press'};
	my $server_time = $opt{'server_time'} || &subs::rightNow();
	my $uuid = (defined $opt{'uuid'} && length $opt{'uuid'}) ? $opt{'uuid'} : &subs::random_string_creator(40);
	&subs::db_insert('appointments', {
		app => $app,
		timestamp => $press,
		type => $type,
		duration => 5000,
		status => 'usual',
		server_time => $server_time,
		uuid => $uuid,
	});
	my ($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $press });
	return {
		uuid => $uuid,
		appt_header => $appt_header,
		header_appts => $header_appts,
		signature => $opt{'signature'},
	};
}

# A control (pause, resume, cancel, delay, reset, complete, renew) is not a
# record the usual can repeat; it acts on the live session and needs its own
# press. Refuse with the reason the dialog shows.
sub usual_control_write {
	my ($c, %opt) = @_;
	my $type = $opt{'type'} || '';
	my $name = length $type ? &subs::format_name($type) : &subs::ui('action');
	return {
		no_usual => 1,
		error => &subs::ui('The usual can repeat a record, not a control.') . ' (' . $name . ')',
	};
}

# The scalar row replay: a note, text, entry, config, software, studio snapshot
# or other plain record becomes a new row at the press. Notes and files are one
# old row's and are never copied.
sub usual_row_write {
	my ($c, %opt) = @_;
	my $app = $opt{'app'};
	my $type = $opt{'type'} || '';
	my $template = $opt{'template'} || {};
	return { no_usual => 1, error => &subs::ui('There is no record to repeat.') } unless length $type;

	# A backup is not a template. It runs through the one backup rail, with a
	# reason set for this press; a failure is a named refusal, never a fake row.
	if ($type eq 'backup') {
		return { no_usual => 1, error => &subs::ui('A backup cannot run from this press.') }
			unless ref $c;
		my $had_reason = defined $c->param('reason') && length $c->param('reason');
		my $old_reason = $c->param('reason');
		$c->param('reason' => 'usual') unless $had_reason;
		my $disposition = eval { &subs::backup_now($c) };
		my $why = $@;
		# Put the request back as it was: the reason was this press's, not the
		# page's, and a later reader must not see it.
		$c->param('reason' => (defined $old_reason ? $old_reason : ''));
		if ($why) {
			$why =~ s/\s+/ /g;
			return { no_usual => 1, error => &subs::ui('The backup did not start.') . ' (' . $why . ')' };
		}
		if (ref $disposition eq 'HASH'
			&& (defined $disposition->{'error'} || ($disposition->{'status'} || '') eq 'failed')) {
			my $error = $disposition->{'error'} || 'failed';
			$error =~ s/\s+/ /g;
			return { no_usual => 1, error => &subs::ui('The backup did not start.') . ' (' . $error . ')' };
		}
	}

	my $at = $anchors->($opt{'kind'}, $opt{'timestamp'}, $opt{'duration'});
	my $press = $at->{'press'};
	my $server_time = $opt{'server_time'} || &subs::rightNow();
	my $uuid = (defined $opt{'uuid'} && length $opt{'uuid'}) ? $opt{'uuid'} : &subs::random_string_creator(40);

	my %row = (
		app => $app,
		type => $type,
		status => 'usual',
		timestamp => $press,
		duration => $point_duration->($template, 5000, $at->{'sign'}),
		server_time => $server_time,
		uuid => $uuid,
		quiet_child => 1,
	);
	foreach my $key (qw(amount tax total quantity unit item vendor account movement currency state)) {
		next unless defined $template->{$key} && length "$template->{$key}";
		$row{$key} = $template->{$key};
	}

	if ($type eq 'quote' || $type eq 'invoice') {
		my $data = $template->{'data_template'};
		if (!defined $data || !length "$data") {
			my $last = &subs::db_query(
				'select data from appointments where app = ? and type = ? order by cast(timestamp as integer) desc limit 1',
				$app, $type
			)->hashes->[0];
			$data = $last->{'data'} if $last;
		}
		return { no_usual => 1, error => &subs::ui('There is no document to rebuild.') . ' (' . &subs::format_name($type) . ')' }
			unless defined $data && length "$data";
		my $doc = eval { decode_json($data) };
		$doc = {} unless ref $doc eq 'HASH';
		my $mint = eval { &subs::store_numbering_mint($type) };
		return { no_usual => 1, error => &subs::ui('A new document number could not be allocated.') . ' (' . &subs::format_name($type) . ')' }
			unless $mint && !$mint->{'error'} && defined $mint->{'id'};
		$doc->{'id'} = $mint->{'id'};
		$doc->{'type'} = $type;
		$doc->{'timestamp'} = $press;
		$row{'data'} = encode_json($doc);
		$row{'item'} = &subs::store_document_item_label($doc);
	}

	my $written = &Manager::appointment_writer($c, \%row);
	$uuid = $written->{'uuid'}
		if ref $written eq 'HASH' && defined $written->{'uuid'} && length "$written->{'uuid'}";
	my ($appt_header, $header_appts) = &subs::appt_header_printer({ app => $app, timestamp => $press });
	return {
		uuid => $uuid,
		appt_header => $appt_header,
		header_appts => $header_appts,
		signature => $opt{'signature'},
	};
}

# The one entry point the press calls. It settles the kind (asking only when the
# profile cannot), records the choice when the person said it is the usual, and
# hands the write to the sub its mode names.
sub usual_apply {
	my ($c, %opt) = @_;
	my $app = &subs::unformat_name($opt{'app'});
	return { no_usual => 1, error => &subs::ui('There is no app to repeat.') }
		unless defined $app && length $app;

	my $profile = ref $opt{'profile'} eq 'HASH' ? $opt{'profile'} : {};
	my $signature = defined $opt{'signature'} ? "$opt{'signature'}" : '';

	if (!length $signature) {
		if ($profile->{'ambiguous'}) {
			return { usual_ask => usual_ask_payload($profile, $c) };
		}
		$signature = $profile->{'chosen'} // '';
	}
	if (!length $signature) {
		return { no_usual => 1, error => &subs::ui('There is no usual to repeat yet.') };
	}

	my ($candidate) = grep {
		ref $_ eq 'HASH' && ($_->{'signature'} // '') eq $signature
	} @{ $profile->{'candidates'} || [] };
	return { no_usual => 1, error => &subs::ui('The usual could not be chosen.') }
		unless $candidate;

	my ($type) = split /:/, $signature, 2;
	$type = '' unless defined $type;
	my $mode = usual_mode($type);
	# A message always asks before it sends, even when the choice was remembered:
	# the send is the thing being consented to. The dialog's OK carries
	# usual_confirm, which is the only thing that lets the send through.
	if ($mode eq 'message' && !$opt{'confirm'}) {
		my $forced = { %{$profile}, chosen => $signature };
		return { usual_ask => usual_ask_payload($forced, $c) };
	}
	my %common = (
		%opt,
		app => $app,
		kind => ($opt{'kind'} // 'usual'),
		signature => $signature,
		type => $type,
		candidate => $candidate,
		template => ($candidate->{'template'} || {}),
		profile => $profile,
		server_time => ($opt{'server_time'} || &subs::rightNow()),
	);

	my $result;
	if ($mode eq 'session') {
		$result = usual_stock_stop($c, %common);
	}
	elsif ($mode eq 'money') {
		$result = usual_transaction_write($c, %common);
	}
	elsif ($mode eq 'capture') {
		if ($type eq 'image' || $type eq 'camera' || $type eq 'scan') {
			$result = usual_image_write($c, %common);
		}
		elsif ($type eq 'record' || $type eq 'video' || $type eq 'audio' || $type eq 'screen') {
			$result = usual_record_write($c, %common);
		}
		else {
			$result = {
				no_usual => 1,
				error => &subs::ui('This kind cannot be repeated yet.') . ' (' . &subs::format_name($type) . ')',
			};
		}
	}
	elsif ($mode eq 'measure') {
		$result = usual_measure_write($c, %common);
	}
	elsif ($mode eq 'message') {
		$result = usual_message_write($c, %common);
	}
	elsif ($mode eq 'command') {
		$result = usual_command_write($c, %common);
	}
	elsif ($mode eq 'control') {
		$result = usual_control_write($c, %common);
	}
	elsif ($mode eq 'row') {
		$result = usual_row_write($c, %common);
	}
	else {
		$result = {
			no_usual => 1,
			error => &subs::ui('This kind is not a record the usual can repeat.') . ' (' . &subs::format_name($type) . ')',
		};
	}

	$result = { no_usual => 1, error => &subs::ui('The usual could not be repeated.') }
		unless ref $result eq 'HASH';
	$result->{'signature'} = $signature unless defined $result->{'signature'};

	# Only a write remembers the kind. A refusal (control, message we cannot
	# reopen, a missing reading) and a question are not a choice.
	if ($opt{'remember'}
		&& !$result->{'usual_ask'}
		&& !$result->{'no_usual'}
		&& !$result->{'usual_error'}) {
		&subs::usual_kind_set($app, $signature, $opt{'server_time'});
	}
	return $result;
}

1;
