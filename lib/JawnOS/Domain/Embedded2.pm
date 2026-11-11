package subs;

# Embedded2: extracted from subroutines.pl (package subs). Loaded on
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

our $config;
our $device;
our $gb;
our $log;
our %m;
our %setting_defaults_memo;

sub embedded_wigi {
	my $data = shift;
	my $ip = $data->{'ip'};
	my $timestamp = $data->{'timestamp'};
	my $edt = $data->{'edt'};
	my $chip_id = $data->{'chip_id'};

	my $watch = &subs::device_lister($timestamp, $edt, undef, $chip_id);
	if ($watch->{'ip'}) {
		# The token rides this query, so only a house address is dialled.
		unless (&subs::board_host_allowed($watch->{'ip'})) {
			$log->info('embedded wigi refused: ' . ($chip_id || '?') . ' at ' . $watch->{'ip'}) if $log;
			return;
		}
		my $wat_set = &subs::embedded_operator_door($edt, $chip_id);
		my $watch_settings = eval { return decode_json $wat_set } || {};
		my $auth = $watch_settings->{'__specs'}->{'authorization'};
		# Decode in Perl: a shell would expand $(...) inside the quotes.
		my $author = decode_base64($auth // '');
		# A token must open under the real patience, never the legacy empty key.
		my $authorization = &subs::note_decrypter_strict($watch_settings->{'__shutup'}->{'patience'}, $author);


		# Plain HTTP board WebServer: TLS/HMAC is firmware work (jp/, jt/, jw/).
		my $wigi_url = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/wigi?timestamp=' . $timestamp . '&authorization=' . $auth;
		my $ua = Mojo::UserAgent->new();
		my $res = $ua->get($wigi_url)->result;

		my $wigi = eval { return decode_json $res->body } || {};
		my $rauth = $wigi->{'authorization'};
		# The device's answer is request data: decode it in Perl, never a shell.
		my $rauthorization = decode_base64($rauth // '');
		my $remote_auth = &subs::note_decrypter_strict($watch_settings->{'__shutup'}->{'patience'}, $rauthorization);

		if (secure_compare($remote_auth, $authorization)) {
			my $buttons = $wigi->{'buttons'};
			my $measures = $wigi->{'measures'};
			my $steps = $measures->{'steps'};
			my $files = $wigi->{'files'};

			foreach my $button ( @{$buttons}) {
				if ($button->{'room'} && $button->{'button'}) {
					my $returner = &subs::edt_button_presser({
						timestamp => ($button->{'timestamp'} * 1000),
						room => $button->{'room'},
						watch_settings => $watch_settings,
						button => $button->{'button'},
						toggle => $button->{'toggle'},
						edt => $edt,
						chip_id => $chip_id
					});
				}
			}
			&subs::step_ingest($steps);
		}

	}
}

sub embedded_location_grabber {
	my $returner = shift;
	$returner->{'signatorial'} = &subs::signatorial_designer() unless $returner->{'signatorial'};
	my $watch = &subs::device_lister($returner->{'timestamp'} || &subs::rightNow(),'teletype') || {};
	if (eval { $watch->{'ip'} }) {
		my $ping = 'timeout .2 ping -c 1 ' . &subs::shell_quote($watch->{'ip'});

		my $ping_test = `$ping`;
		if ($ping_test =~ /ttl/gi) {
			my $ua = Mojo::UserAgent->new();
			$ua = $ua->connect_timeout(1)->inactivity_timeout(2)->request_timeout(3);
			my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/my_position';
			my $res = eval { return $ua->get($watch_home)->result };
			if (eval { return decode_json $res->body }) {
				my $co = eval { return decode_json $res->body };
				$returner->{'latitude'} = $co->{'lat'};
				$returner->{'longitude'} = $co->{'lng'};
				$returner->{'accuracy'} = $co->{'accuracy'} if $co->{'accuracy'};
			}
		}
	}
	return $returner;
}

sub embedded_internal_jobs {
	my $op_d = shift;
	foreach my $k ( keys %{$op_d} ) {
		if ($gb::embedded_components->{$op_d->{$k}->{'component'}}->{'direction'} eq 'input') {
			foreach my $ko ( keys %{$op_d} ) {
				if ($op_d->{$ko}->{'app'} eq $op_d->{$k}->{'app'} && $gb::embedded_components->{$op_d->{$ko}->{'component'}}->{'direction'} eq 'output') {
					$op_d->{'__specs'}->{'internal_jobs'}->{$k} = [] if !$op_d->{'__specs'}->{'internal_jobs'}->{$k};
					# The board only needs the wiring. rgb is an array, and the Pico's
					# JSONVar re-stringify turns [190,253,231] into invalid [,,], which
					# makes the whole internal_jobs unreadable on the device.
					my %job = %{$op_d->{$ko}};
					delete @job{qw/colour rgb shorthand_name direction measure movement/};
					# Strings only: the Pico re-stringifies this map, and JSONVar writes a
					# numeric value as an empty token, which makes the map unparseable.
					$job{'toggle'} = (($job{'toggle'} // 0) ? '1' : '0');
					$job{'inverted'} = (defined $job{'inverted'} ? ($job{'inverted'} ? '1' : '0') : '0');
					$job{'numero'} = '' . ($job{'numero'} // '');
					push @{$op_d->{'__specs'}->{'internal_jobs'}->{$k}}, \%job;
				}
			}
		}
	}
	return $op_d;
}

sub intelligent_automation_toggle {
	my $data = shift;
	my $app = $data->{'app'};
	my $state = $data->{'state'};
	my $appt_uuid = $data->{'appt_uuid'};
	my $uuid = $data->{'uuid'};
	my $value = $data->{'value'};
	my $type = $data->{'type'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $remote_address = $data->{'remote_address'};
	my $now = &subs::rightNow();
	my $measure = $data->{'measure'};
	my $source_chip_id = $data->{'source_chip_id'} || '';
	$log->info('ia toggle: ' . ($app || '?') . ' state=' . (defined $data->{'state'} ? $data->{'state'} : '-') .
		' source_chip=' . ($source_chip_id || '-') . ' remote=' . ($remote_address || '-'));
	# An event the settings layer has already superseded must not drive relays
	# and LEDs. The panel's start and a switch thrown a moment later are exactly
	# this: the start arrives late, and applying it here turned the hardware back
	# on after the person had switched it off.
	if (&subs::toggle_event_is_older($app, $timestamp)) {
		$log->info('ia toggle: ' . ($app || '?') . ' @' . $timestamp . ' is older than the stored toggle, outputs left alone');
		return;
	}
	my $asets = &subs::settings_grabber({ app => $app, settings => ['ia','toggle'] });
	my $jia = $asets->{'ia'};
	my $ia = eval { return decode_json $jia } || {};
	# An unreadable wiring map used to leave a press with no trace at all: the
	# panel flipped, nothing clicked, and neither the log nor the device saw a
	# command. Name it, with the size, so a corrupt row is obvious.
	if (!scalar keys %{$ia} && $log) {
		$log->info('ia toggle: ' . ($app || '?') . ' has no readable wiring (ia '
			. (defined $jia ? length($jia) : 0) . ' bytes)');
	}
	my $counted = 0;
	foreach my $chip ( keys %{$ia} ) {
		# A switch/button is applied locally by the board that owns it; the
		# automation layer is for the output devices that are not that board.
		next if $source_chip_id && $chip eq $source_chip_id;
		foreach my $i ( keys %{$ia->{$chip}} ) {
			next if $remote_address && $ia->{$chip}->{$i}->{'ip'} eq $remote_address;
			if ($ia->{$chip}->{$i}->{'direction'} eq 'output') {
				my $when = 'later';
				if ($timestamp <= $now + 1000) {
					$when = 'now';
				}

				if ($data->{'measure'} && $measure ne $ia->{$chip}->{$i}->{'measure'}) {
				#	return;
				}
				if ($ia->{$chip}->{$i}->{'movement'} eq 'start') {
					# One output that dies must not silence the rest of the fan-out: a
					# press drives every wired relay and LED, and an unguarded call here
					# aborted the loop, leaving the board after it uncommanded with no
					# word in the log. Name the chip, pin and error, then keep going.
					my $ok = eval {
						&subs::embedded_toggle({
							app => $app,
							pin => $ia->{$chip}->{$i}->{'pin'},
							ip => $ia->{$chip}->{$i}->{'ip'},
							edt => $ia->{$chip}->{$i}->{'edt'},
							component => $ia->{$chip}->{$i}->{'component'},
							timestamp => $timestamp,
							'state' => $state,
							measure => $measure,
							chip_id => $chip,
							'when' => $when,
							uuid => $uuid,
							appt_uuid => $appt_uuid,
							value => $data->{'value'},
							counted => $counted
						});
						1;
					};
					if (!$ok && $log) {
						my $why = $@; $why =~ s/\s+/ /g;
						$log->info('ia toggle: ' . ($app || '?') . ' output ' . $chip . ' pin '
							. $ia->{$chip}->{$i}->{'pin'} . ' failed: ' . $why);
					}
				}
				elsif ($ia->{$chip}->{$i}->{'movement'} eq 'measure') {
					my $edt_data = {
						app => $app,
						pin => $ia->{$chip}->{$i}->{'pin'},
						ip => $ia->{$chip}->{$i}->{'ip'},
						edt => $ia->{$chip}->{$i}->{'edt'},
						component => $ia->{$chip}->{$i}->{'component'},
						timestamp => $timestamp,
						'state' => $state,
						measure => $measure,
						chip_id => $chip,
						'when' => $when,
						uuid => $uuid,
						appt_uuid => $appt_uuid,
						value => $data->{'value'},
						counted => $counted
					};
					if ($type eq 'text') {
						if ($data->{'measurement'} && $ia->{$chip}->{$i}->{'named_measure'}) {
							if ($data->{'measurement'} eq $ia->{$chip}->{$i}->{'named_measure'}) {
								$edt_data->{'state'} = 'on';
							}
							else {
								$edt_data->{'state'} = 'off';
							}
						}
					}
					else {
						if ($data->{'measurement'} && $ia->{$chip}->{$i}->{'threshold'}) {
							if ($ia->{$chip}->{$i}->{'comparison'} eq '>') {
								if ($data->{'measurement'} > $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							} elsif ($ia->{$chip}->{$i}->{'comparison'} eq '>=') {
								if ($data->{'measurement'} >= $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							} elsif ($ia->{$chip}->{$i}->{'comparison'} eq '<=') {
								if ($data->{'measurement'} <= $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							} elsif ($ia->{$chip}->{$i}->{'comparison'} eq '<') {
								if ($data->{'measurement'} < $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							}
							else {
								if ($data->{'measurement'} == $ia->{$chip}->{$i}->{'threshold'}) {
									$edt_data->{'state'} = 'on';
								}
								else {
									$edt_data->{'state'} = 'off';
								}
							}
							&subs::embedded_toggle($edt_data);
							$counted++;
						}
					}
				}
			}

		}
	}

}

sub name_change_pairs {
	my ($app, $new_app) = @_;
	my @pairs;
	my %seen;
	my %natural = map { $_ => 1 } qw/nfc app_measures phones emails/;
	# window and view state, not a choice: the uuid names the app, scrollTop and
	# jopen are where its window was left, dimensions is how big it was - nobody
	# merging two records wants to choose between two scroll positions.
	my %transient = map { $_ => 1 } qw/uuid scrollTop jopen dimensions s_scroll ci/;
	# who a person is, rather than how their app is set up: a contact either side
	# holds joins the record, so it is always on the panel - a number filed under
	# the number itself, renamed to a real person, must not quietly vanish.
	my %identity = map { $_ => 1 } qw/phone email phones emails/;
	my $olds = &subs::db_query('select setting, value from settings where app = ?', $app)->hashes;
	my $news = &subs::db_query('select setting, value from settings where app = ?', $new_app)->hashes;
	my (%new_by, %old_by);
	$new_by{$_->{'setting'}} ||= $_->{'value'} for @{$news};
	$old_by{$_->{'setting'}} ||= $_->{'value'} for @{$olds};
	my %settings = map { $_ => 1 } (keys %new_by, keys %old_by);
	foreach my $setting ( sort keys %settings ) {
		next if $seen{$setting}++;
		next if $transient{$setting};
		my $old_present = exists $old_by{$setting} ? 1 : 0;
		my $new_present = exists $new_by{$setting} ? 1 : 0;
		next unless $old_present || $new_present;
		# a setting only one side holds is carried over silently by the rename,
		# so it is only worth a row when it says who the person is
		next unless ($old_present && $new_present) || $identity{$setting};
		my $old_value = $old_by{$setting};
		my $new_value = $new_by{$setting};
		# nothing to choose when both sides already say the same thing: a row per
		# shared setting buried the handful that actually differ
		next if ($old_present && $new_present && defined $old_value && defined $new_value && $old_value eq $new_value);
		my $only = '';
		$only = 'old' if $old_present && !$new_present;
		$only = 'new' if $new_present && !$old_present;
		# A value that is still what a brand-new app would be born with is nothing
		# anybody chose, so between it and a value somebody set, the set one is the
		# one to keep: the panel pre-selects it rather than making every row be
		# decided by hand.
		my $old_default = $old_present ? (&subs::setting_is_default($setting, $app, $old_value) ? 1 : 0) : 0;
		my $new_default = $new_present ? (&subs::setting_is_default($setting, $new_app, $new_value) ? 1 : 0) : 0;
		# a list either side holds is a merge the moment both sides have one; a
		# one-sided row is just keep-or-drop, so it wears no merge option
		my $natural = ($natural{$setting} && !$only) ? 'merge' : '';
		my $prefer = '';
		if ($only eq 'old') {
			# the renaming app alone holds it: keeping it is the default, dropping
			# it the deliberate escape
			$prefer = 'new';
		}
		elsif ($only eq 'new') {
			# the record being renamed into alone holds it: it survives unless
			# somebody says to drop it
			$prefer = 'old';
		}
		else {
			$prefer = 'old' if $old_default && !$new_default;
			$prefer = 'new' if $new_default && !$old_default;
		}
		push @pairs, {
			setting => $setting,
			old_value => $old_value,
			new_value => $new_value,
			old_present => $old_present,
			new_present => $new_present,
			old_default => $old_default,
			new_default => $new_default,
			only => $only,
			prefer => $prefer,
			natural => $natural
		};
	}
	return \@pairs;
}

sub setting_is_default {
	my ($setting, $app, $value) = @_;
	return 0 unless defined $value && length $value;
	my %fixed = (
		permanent => 'checked', cost => '0', enc => 'on',
		public => 'off', schedule => 'once', navigation => 'none',
	);
	return 1 if exists $fixed{$setting} && $value eq $fixed{$setting};
	# a new app is born public; `checked` and `on` are the older defaults, kept
	# so a row written before the levels is still read as nothing anybody chose
	return 1 if $setting eq 'visible' && ($value eq 'public' || $value eq 'checked' || $value eq 'on');
	return 1 if $setting eq 'notification_text' && $value eq &subs::format_name($app || '');
	return 0 unless grep { $_ eq $setting } qw/worth duration currency unit warranty/;
	unless (scalar keys %setting_defaults_memo) {
		foreach my $k ( qw/worth duration currency unit warranty/ ) {
			my $rows = &subs::db_query('select value from settings where app = ? and setting = ?', 'me', $k)->hashes;
			foreach my $r ( @{$rows} ) {
				next unless defined $r->{'value'} && length $r->{'value'};
				$setting_defaults_memo{$k}->{ $r->{'value'} } = 1;
			}
		}
	}
	return 1 if $setting_defaults_memo{$setting} && $setting_defaults_memo{$setting}->{$value};
	return 0;
}

# How two values of a setting join: nfc, measures and the typed contact lists are
# lists at heart, so a natural merge keeps both sides; anything else keeps the
# renaming app's value. Merging with an empty side simply keeps the side that has
# a value - which is what a one-sided contact row does.
sub merge_setting_values {
	my ($setting, $old, $new) = @_;
	my $old_has = (defined $old && length $old) ? 1 : 0;
	my $new_has = (defined $new && length $new) ? 1 : 0;
	return $new if !$old_has;
	return $old if !$new_has;
	if ($setting eq 'nfc') {
		my $a = eval { return decode_json $old } || [];
		my $b = eval { return decode_json $new } || [];
		$a = [ $a ] if ref $a eq 'HASH';
		$b = [ $b ] if ref $b eq 'HASH';
		my %seen;
		my @merged = grep { !$seen{$_->{'uuid'} || $_}++ } (@{$b}, @{$a});
		return encode_json \@merged;
	}
	if ($setting eq 'app_measures') {
		my $a = eval { return decode_json $old } || {};
		my $b = eval { return decode_json $new } || {};
		my %merged = (%{$a}, %{$b});
		return encode_json \%merged;
	}
	if ($setting eq 'phones' || $setting eq 'emails') {
		# the typed contact lists join the same way: both sides' entries stay, and
		# an entry the same number or address already covers is not written twice
		my $kind = ($setting eq 'phones') ? 'phone' : 'email';
		my $a = eval { return decode_json $old } || [];
		my $b = eval { return decode_json $new } || [];
		$a = [ $a ] if ref $a eq 'HASH';
		$b = [ $b ] if ref $b eq 'HASH';
		my %seen;
		my @merged = grep {
			next unless ref $_ eq 'HASH';
			my $key = &subs::contact_normalizer($kind, $_->{'value'});
			$key ||= $_->{'uuid'};
			!$seen{$key}++;
		} (@{$b}, @{$a});
		return encode_json \@merged;
	}
	return $new;
}

# Applies the panel's choices and leaves only the rows the rename will carry:
# 'new' drops the target's row (the renaming app's value takes the name), 'old'
# drops the renaming app's row (the existing value stays), and 'merge' writes
# the joined value under the target name and drops both.
sub name_change_apply {
	my ($app, $new_app, $choices) = @_;
	foreach my $setting ( keys %{$choices} ) {
		my $pick = $choices->{$setting} || '';
		if ($pick eq 'new') {
			&subs::db_query('delete from settings where app = ? and setting = ?', $new_app, $setting);
		}
		elsif ($pick eq 'old') {
			&subs::db_query('delete from settings where app = ? and setting = ?', $app, $setting);
		}
		elsif ($pick eq 'merge') {
			# either side may be absent (a one-sided contact row), so read the row
			# rather than dereferencing a missing one
			my $old_row = &subs::db_query('select value from settings where app = ? and setting = ?', $app, $setting)->hashes->[0];
			my $new_row = &subs::db_query('select value from settings where app = ? and setting = ?', $new_app, $setting)->hashes->[0];
			my $oldv = ref $old_row ? $old_row->{'value'} : '';
			my $newv = ref $new_row ? $new_row->{'value'} : '';
			my $merged = &subs::merge_setting_values($setting, $oldv, $newv);
			&subs::db_query('delete from settings where app = ? and setting = ?', $app, $setting);
			&subs::db_query('delete from settings where app = ? and setting = ?', $new_app, $setting);
			&subs::setting_setter({ app => $new_app, setting => $setting, value => $merged })
				if defined $merged && length $merged;
		}
	}
}

# --- appointment history: what a rename into a known name would merge --------
# The settings merge above answers "which value keeps the name". This answers
# the other half: what happens to the app's events. The panel shows a compact
# per-side summary and a few policies, and the chosen policy's rows are
# tombstoned after the rename (under the unified name, so every peer agrees).
sub name_change_history_duration {
	my ($app) = @_;
	my $value = &subs::setting_grabber({ app => $app, setting => 'duration' });
	return undef unless defined $value && $value =~ /[0-9]/;
	my $ms = eval { &subs::time_abbrev_translator($value) };
	return defined $ms ? abs($ms) : undef;
}

sub name_change_history_sessions {
	my ($app) = @_;
	return [] unless defined $app && length $app;
	my $rows = &subs::db_query(
		'select rowid, uuid, type, timestamp, stop_timestamp, duration, stop_seen, server_time, device,'
		. ' case when notes is not null and length(notes) > 0 then 1 else 0 end has_notes'
		. ' from appointments where app = ? and lower(type) in (?,?,?,?)'
		. ' order by cast(timestamp as integer) asc',
		$app, 'stop', 'start', 'record', 'usual'
	)->hashes || [];
	my @sessions;
	foreach my $r ( @{$rows} ) {
		next unless defined $r->{'timestamp'} && $r->{'timestamp'} =~ /^-?\d+$/;
		my $start = 0 + $r->{'timestamp'};
		my $stop = (defined $r->{'stop_timestamp'} && $r->{'stop_timestamp'} =~ /^-?\d+$/ && $r->{'stop_timestamp'} > 0)
			? 0 + $r->{'stop_timestamp'} : undef;
		my $duration = (defined $r->{'duration'} && $r->{'duration'} =~ /^-?\d+(?:\.\d+)?$/)
			? 0 + $r->{'duration'} : undef;
		# Older stop rows carry a duration but no stop_timestamp; the duration is
		# the session length (negative on stop rows, positive on usual rows), so
		# the end is start + abs(duration) even though no press recorded it.
		my $end = $stop;
		my $end_implied = 0;
		if (!defined $end && defined $duration && abs($duration) > 0) {
			$end = $start + abs($duration);
			$end_implied = 1;
		}
		my $span = defined $end ? ($end - $start) : 0;
		$span = abs($span) if $span < 0 && !defined $stop;
		push @sessions, {
			rowid => 0 + $r->{'rowid'},
			uuid => $r->{'uuid'} || '',
			app => $app,
			type => lc($r->{'type'} || ''),
			start => $start,
			stop => $stop,
			end => $end,
			end_implied => $end_implied,
			duration => $duration,
			span => $span,
			server_time => $r->{'server_time'},
			device => $r->{'device'} || '',
			has_notes => (0 + ($r->{'has_notes'} || 0)) ? 1 : 0,
			malformed => (defined $stop && $stop < $start) ? 1 : 0,
		};
	}
	return \@sessions;
}

sub name_change_history_months {
	my ($counts) = @_;
	my @now = localtime(time);
	my ($year, $mon) = ($now[5] + 1900, $now[4] + 1);
	my @months;
	for (my $i = 11; $i >= 0; $i--) {
		my ($y, $m) = ($year, $mon - $i);
		while ($m < 1) { $m += 12; $y--; }
		my $key = sprintf('%04d-%02d', $y, $m);
		push @months, { month => $key, count => ($counts->{$key} || 0) };
	}
	return \@months;
}

sub name_change_history_summary {
	my ($app, $sessions) = @_;
	$sessions = &subs::name_change_history_sessions($app) unless ref $sessions eq 'ARRAY';
	my (%by_type, %days, %period, %month);
	my @spans;
	my ($first, $last);
	my ($open, $missing_stop, $malformed) = (0, 0, 0);
	foreach my $s ( @{$sessions} ) {
		$by_type{ $s->{'type'} }++;
		my @t = localtime($s->{'start'} / 1000);
		$days{ sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]) } = 1;
		$period{ $t[2] < 6 ? 'night' : $t[2] < 12 ? 'morning' : $t[2] < 18 ? 'afternoon' : 'evening' }++;
		$month{ sprintf('%04d-%02d', $t[5] + 1900, $t[4] + 1) }++;
		push @spans, $s->{'span'} if $s->{'span'} > 0;
		$first = $s->{'start'} if !defined $first || $s->{'start'} < $first;
		$last = $s->{'start'} if !defined $last || $s->{'start'} > $last;
		$open++ unless defined $s->{'end'};
		$missing_stop++ if $s->{'type'} eq 'stop' && !defined $s->{'stop'};
		$malformed++ if $s->{'malformed'};
	}
	my @sorted = sort { $a <=> $b } @spans;
	my $pct = sub {
		my ($p) = @_;
		return undef unless scalar @sorted;
		my $i = int((scalar @sorted - 1) * $p / 100 + 0.5);
		$i = 0 if $i < 0;
		$i = $#sorted if $i > $#sorted;
		return $sorted[$i];
	};
	my %exact;
	foreach my $s ( @{$sessions} ) {
		my $key = $s->{'start'} . '|' . (defined $s->{'end'} ? $s->{'end'} : '');
		$exact{$key}++;
	}
	my ($exact_groups, $exact_spare) = (0, 0);
	foreach my $n ( values %exact ) {
		next unless $n > 1;
		$exact_groups++;
		$exact_spare += $n - 1;
	}
	my %stops;
	$stops{ $_->{'stop'} }++ for grep { defined $_->{'stop'} } @{$sessions};
	my ($shared_groups, $shared_spare) = (0, 0);
	foreach my $n ( values %stops ) {
		next unless $n > 1;
		$shared_groups++;
		$shared_spare += $n - 1;
	}
	my $all = &subs::db_query('select count(*) c from appointments where app = ?', $app);
	my $rows = $all ? (0 + ($all->hash->{'c'} || 0)) : scalar @{$sessions};
	my $exp = &subs::db_query('select count(*) c from appointments where app = ? and cast(warranty as integer) > 0 and cast(warranty as integer) < ?', $app, &subs::rightNow());
	my $expired = $exp ? (0 + ($exp->hash->{'c'} || 0)) : 0;
	my $configured = &subs::name_change_history_duration($app);
	return {
		app => $app,
		label => &subs::format_name($app),
		rows => $rows,
		sessions => scalar @{$sessions},
		by_type => \%by_type,
		first => $first,
		last => $last,
		first_label => (defined $first ? &subs::iso_local($first) : ''),
		last_label => (defined $last ? &subs::iso_local($last) : ''),
		days => scalar keys %days,
		per_day => (scalar @{$sessions} && scalar keys %days) ? sprintf('%.2f', scalar @{$sessions} / scalar keys %days) : '0.00',
		median_ms => $pct->(50),
		p10_ms => $pct->(10),
		p90_ms => $pct->(90),
		open => $open,
		missing_stop => $missing_stop,
		malformed => $malformed,
		exact_groups => $exact_groups,
		exact_spare => $exact_spare,
		shared_groups => $shared_groups,
		shared_spare => $shared_spare,
		period => \%period,
		months => &subs::name_change_history_months(\%month),
		configured_ms => $configured,
		warranty => (&subs::setting_grabber({ app => $app, setting => 'warranty' }) || ''),
		expired => $expired,
	};
}

sub name_change_history_lower_bound {
	my ($rows, $value) = @_;
	my ($lo, $hi) = (0, scalar @{$rows});
	while ($lo < $hi) {
		my $mid = int(($lo + $hi) / 2);
		if ($rows->[$mid]->{'start'} < $value) { $lo = $mid + 1; }
		else { $hi = $mid; }
	}
	return $lo;
}

# 'full' when start and end both agree, 'open' when one side has no end.
sub name_change_history_match_kind {
	my ($ra, $rb, $tol) = @_;
	return undef unless abs($ra->{'start'} - $rb->{'start'}) <= $tol;
	my ($ea, $eb) = ($ra->{'end'}, $rb->{'end'});
	if (defined $ea && defined $eb) {
		return abs($ea - $eb) <= $tol ? 'full' : undef;
	}
	return 'full' unless defined $ea || defined $eb;
	return 'open';
}

sub name_change_history_pairs {
	my ($rows_a, $rows_b, $tol) = @_;
	my @pairs;
	foreach my $ra ( @{$rows_a} ) {
		my $lo = &subs::name_change_history_lower_bound($rows_b, $ra->{'start'} - $tol);
		for (my $i = $lo; $i < scalar @{$rows_b}; $i++) {
			my $rb = $rows_b->[$i];
			last if $rb->{'start'} > $ra->{'start'} + $tol;
			my $kind = &subs::name_change_history_match_kind($ra, $rb, $tol);
			next unless $kind;
			my $dstart = abs($ra->{'start'} - $rb->{'start'});
			my $dend = (defined $ra->{'end'} && defined $rb->{'end'}) ? abs($ra->{'end'} - $rb->{'end'}) : undef;
			my $score = $dstart + (defined $dend ? $dend : $tol / 2);
			my $category = ((defined $dend && $dend <= 1000 && $dstart <= 1000) || (!defined $dend && $dstart <= 1000)) ? 'exact' : 'near';
			push @pairs, {
				a => $ra, b => $rb, kind => $kind,
				dstart => $dstart, dend => $dend, score => $score,
				category => $category,
			};
		}
	}
	return \@pairs;
}

sub name_change_history_greedy {
	my ($rows_a, $rows_b, $tol) = @_;
	my $candidates = &subs::name_change_history_pairs($rows_a, $rows_b, $tol);
	my @sorted = sort { $a->{'score'} <=> $b->{'score'} } @{$candidates};
	my (%used_a, %used_b);
	my @pairs;
	foreach my $pair ( @sorted ) {
		next if $used_a{ $pair->{'a'}->{'rowid'} } || $used_b{ $pair->{'b'}->{'rowid'} };
		$used_a{ $pair->{'a'}->{'rowid'} } = 1;
		$used_b{ $pair->{'b'}->{'rowid'} } = 1;
		push @pairs, $pair;
	}
	return { pairs => \@pairs, used_a => \%used_a, used_b => \%used_b };
}

sub name_change_history_cross_shared {
	my ($rows_a, $rows_b, $start_tol) = @_;
	my @b_stop = sort { $a->{'stop'} <=> $b->{'stop'} } grep { defined $_->{'stop'} } @{$rows_b};
	my @out;
	foreach my $ra ( grep { defined $_->{'stop'} } @{$rows_a} ) {
		my ($lo, $hi) = (0, scalar @b_stop);
		while ($lo < $hi) {
			my $mid = int(($lo + $hi) / 2);
			if ($b_stop[$mid]->{'stop'} < $ra->{'stop'} - 1000) { $lo = $mid + 1; }
			else { $hi = $mid; }
		}
		for (my $i = $lo; $i < scalar @b_stop; $i++) {
			my $rb = $b_stop[$i];
			last if $rb->{'stop'} > $ra->{'stop'} + 1000;
			next if abs($ra->{'start'} - $rb->{'start'}) <= $start_tol;
			push @out, {
				a => $ra, b => $rb,
				dstart => abs($ra->{'start'} - $rb->{'start'}),
				dstop => abs($ra->{'stop'} - $rb->{'stop'}),
			};
		}
	}
	return \@out;
}

sub name_change_history_start_only {
	my ($rows_a, $rows_b, $tol) = @_;
	my @out;
	foreach my $ra ( @{$rows_a} ) {
		my $lo = &subs::name_change_history_lower_bound($rows_b, $ra->{'start'} - $tol);
		for (my $i = $lo; $i < scalar @{$rows_b}; $i++) {
			my $rb = $rows_b->[$i];
			last if $rb->{'start'} > $ra->{'start'} + $tol;
			next if &subs::name_change_history_match_kind($ra, $rb, $tol);
			push @out, {
				a => $ra, b => $rb,
				dstart => abs($ra->{'start'} - $rb->{'start'}),
				dend => (defined $ra->{'end'} && defined $rb->{'end'}) ? abs($ra->{'end'} - $rb->{'end'}) : undef,
			};
		}
	}
	return \@out;
}

1;
