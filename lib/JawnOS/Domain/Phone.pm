package subs;

# The phone's reception settings, read the same way everywhere.
#
# These live in the domain layer rather than on the Manager because a worker
# needs them without loading the whole panel: perl/Reception.pl arms the
# gateway from them with no request in flight. The IVR belongs to the house,
# not to the device that happened to save it - the phone turns it on, the
# gateway machine plays it - so the rows are read and written house-wide, with
# the older per-device rows still answering as a fallback.
use strict;
use warnings;
use Data::UUID;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json);

sub phone_ivr_defaults {
	return {
		enabled   => 'no',
		machine   => '',
		route     => 'unknown',
		voice     => &subs::say_default_voice(),
		# the adapter the phone must send call audio to, by Bluetooth name
		bluetooth => 'jawn-gateway',
		greeting  => &subs::ui('This automated system records calls.'),
		prompt    => &subs::ui('Please say your name after the tone.'),
		voicemail => &subs::ui('Please leave a message after the tone.'),
		thanks    => &subs::ui('Thank you.'),
		flows     => &subs::phone_ivr_flow_defaults('unknown'),
	};
}

# The six call-flow buckets. `route` is the older three-way knob; when a phone
# has no saved matrix, the matrix is derived from it so an existing phone keeps
# behaving the same way.
sub phone_ivr_flow_defaults {
	my ($route) = @_;
	my %flow = (
		unknown     => 'ivr',
		blacklisted => 'reject',
		enemy       => 'reject',
		stranger    => 'ivr',
		friend      => 'ring',
		self        => 'ring',
	);
	if (($route || '') eq 'off') {
		$flow{$_} = 'ring' for qw(unknown stranger friend self);
	}
	elsif (($route || '') eq 'all') {
		$flow{$_} = 'ivr' for qw(unknown stranger friend self);
	}
	return \%flow;
}

sub phone_ivr_flow_clean {
	my ($flows, $route) = @_;
	my $base = &subs::phone_ivr_flow_defaults($route);
	my %clean = %{$base};
	if (ref $flows eq 'HASH') {
		foreach my $bucket (qw(unknown blacklisted self friend stranger enemy)) {
			my $action = $flows->{$bucket};
			next unless defined $action && $action =~ /^(?:ring|ivr|voicemail|reject)$/;
			$clean{$bucket} = $action;
		}
	}
	return \%clean;
}

# One setting, the house row first and this device's older row second.
sub phone_ivr_grab {
	my ($setting) = @_;
	my $value = &subs::setting_grabber({ app => 'phone', setting => $setting, device => 'all', benign => 1 });
	if (!defined $value || !length $value) {
		$value = &subs::setting_grabber({ app => 'phone', setting => $setting, benign => 1 });
	}
	return defined $value ? $value : '';
}

sub phone_ivr_settings {
	my $settings = &subs::phone_ivr_defaults();
	foreach my $key ( keys %{$settings} ) {
		next if $key eq 'flows';
		my $value = &subs::phone_ivr_grab('ivr_' . $key);
		$settings->{$key} = $value if length $value;
	}
	$settings->{'enabled'} = ($settings->{'enabled'} eq 'yes') ? 'yes' : 'no';
	$settings->{'route'} = 'unknown' unless $settings->{'route'} =~ /^(?:unknown|all|off)$/;
	my %voices = map { $_->{'value'} => 1 } &subs::say_voices();
	$settings->{'voice'} = &subs::say_default_voice() unless $voices{ $settings->{'voice'} };
	my $stored_flows = &subs::phone_ivr_grab('ivr_flows');
	my $flows = eval { decode_json($stored_flows) } if length $stored_flows;
	$settings->{'flows'} = &subs::phone_ivr_flow_clean($flows, $settings->{'route'});
	return $settings;
}

# A screened call's transcript, filed into the Chat thread for the number.
#
# The gateway writes one JSONL file per call under ~/.president/sco/transcripts,
# but it never learns the caller's number: the number is the phone's, and the
# phone tells the house when it files the call. So the filing happens here, when
# the call appointment is written, and a transcript is spent once (a renamed
# .filed marker), so a retried call log cannot file the same words twice.
#
# When the gateway is another machine there is no local file; the live lines are
# still in its status, so the phone asks it for them instead. The header names
# the caller from this house's contact rows, because that is the half the
# gateway never sees.
#
# The call window picks the file: the gateway and the phone are the same house
# and a call is one at a time, but a transcript from minutes later belongs to a
# different call and is left alone. '' when there is nothing to file.
sub phone_call_transcript_note {
	my ($number, $started_ms, $ended_ms) = @_;
	my $digits = defined $number ? $number : '';
	$digits =~ s/\D+//g;
	$digits =~ s/^1//;
	return 0 unless length $digits;
	my ($file, $said) = &phone_call_transcript_lines($ended_ms);
	return 0 unless length $file && @{$said};
	# The number is the phone's, not the gateway's, so the header names the
	# caller from the house's own contact rows. An unknown number reads as the
	# number the phone received, not the digits the matching works on.
	my $app = eval { &subs::phone_number_app($digits) } || '';
	my $caller = (length $app && $app ne $digits) ? &subs::format_name($app) : '';
	$caller = $number if !length $caller && defined $number && length $number;
	$caller = $digits unless length $caller;
	my $body = 'Call from: ' . $caller . "\n\n" . join(' ', @{$said});
	$body = substr($body, 0, 4000);
	# A message the house cannot read again is not written: the key is missing
	# (a sandbox, a half-restored machine), and the transcript is left in place
	# for the next attempt.
	my $sealed = eval { &subs::note_encrypter(&subs::suds_grabber(), $body) };
	return 0 unless defined $sealed && length $sealed;
	my $msg = {
		uuid => Data::UUID->new->create_str(),
		timestamp => &phone_call_epoch($ended_ms) * 1000,
		server_time => &subs::rightNow(),
		body => $sealed,
		manager_file => '',
		status => 'sent',
		contact => $app,
		phone => $digits,
		email => undef,
		conversation_uuid => undef,
		attachments => undef,
	};
	my $ok = eval { &subs::db_insert('mailbox', $msg); 1 };
	return 0 unless $ok;
	# Only a local transcript has a file to spend. A remote status names its
	# call instead, and the next log (or a retry) asks the gateway again.
	rename $file, "$file.filed" if -f $file && $file =~ /\.jsonl$/;
	return 1;
}

# The transcript file for a call that ended at $ended_ms, and the words in it.
# A local .jsonl the gateway wrote wins; with none, the gateway's live status is
# asked, because the gateway may be another machine. Its lines carry their own
# timestamps, and a transcript from minutes later belongs to a different call
# and is left alone. A spent local transcript is renamed .filed, so a retried
# call log cannot file it twice. Returns () when there is nothing to file.
sub phone_call_transcript_lines {
	my ($ended_ms) = @_;
	my $dir = $ENV{'JAWNOS_SCO_DIR'}
		? $ENV{'JAWNOS_SCO_DIR'} . '/transcripts'
		: &subs::home('~/.president/sco/transcripts');
	my $ended = &phone_call_epoch($ended_ms);

	if (-d $dir) {
		opendir(my $dh, $dir);
		if ($dh) {
			my @files = sort grep { /\.jsonl$/ && -s "$dir/$_" } readdir $dh;
			closedir $dh;
			my ($pick, $best) = ('', undef);
			foreach my $name (@files) {
				my $mtime = (stat("$dir/$name"))[9] || 0;
				my $delta = abs($mtime - $ended);
				next if $delta > 300;   # another call's words
				if (!defined $best || $delta < $best) { $best = $delta; $pick = $name; }
			}
			if (length $pick) {
				my @said;
				foreach my $line ( split /\n/, read_file("$dir/$pick") ) {
					next unless $line =~ /\S/;
					my $row = eval { decode_json($line) };
					next unless ref $row eq 'HASH';
					my $text = $row->{'text'} // '';
					$text =~ s/^\s+|\s+$//g;
					push @said, $text if length $text;
				}
				return ("$dir/$pick", \@said) if @said;
				return ();
			}
		}
	}

	# No local transcript: the gateway is another machine's, but the phone still
	# knows when the call ended. Ask it for the lines it is holding. A missing
	# gateway (the ordinary desktop) answers { ok => 0 }, which is not an error.
	my $status = eval {
		require JawnOS::Sco::Client;
		JawnOS::Sco::Client->new()->call({ cmd => 'status' });
	};
	return () unless ref $status eq 'HASH' && $status->{'ok'};

	# A status whose call began after this one ended belongs to the next call.
	my $since = $status->{'since'};
	return () if defined $since && $since =~ /^\d+$/ && $since > $ended + 5;

	my @remote;
	my $rows = $status->{'transcript'};
	$rows = [] unless ref $rows eq 'ARRAY';
	foreach my $row ( @{$rows} ) {
		next unless ref $row eq 'HASH';
		my $at = $row->{'at'};
		next unless defined $at && $at =~ /^\d+$/;
		next if abs($at - $ended) > 300;   # another call's words
		my $text = $row->{'text'} // '';
		$text =~ s/^\s+|\s+$//g;
		push @remote, $text if length $text;
	}
	return () unless @remote;
	my $call_id = $status->{'call_id'} // '';
	# Not a path to a local file: the caller can tell this came from the
	# gateway's live status, and the note leaves it alone rather than renaming.
	return (length $call_id ? $call_id : 'remote', \@remote);
}

# A call's stamp arrives in milliseconds (the app's Date.now); an older caller
# may still send seconds. Either way, seconds out.
sub phone_call_epoch {
	my ($stamp) = @_;
	return time unless defined $stamp && $stamp =~ /^\d+(?:\.\d+)?$/ && $stamp > 0;
	return int($stamp / 1000) if $stamp > 100000000000;
	return int($stamp);
}

1;
