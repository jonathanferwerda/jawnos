package subs;

# Ble2: extracted from subroutines.pl (package subs). Loaded on
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
use JawnOS::Ble::Drain qw(drain_new drain_feed);
use JawnOS::Ble::Guard qw(cpu_ticks cpu_hog);
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop::ReadWriteFork;
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

our $database;
our $device;
our $gb;
our $log;

sub ble_message_processor {
	my ($data, $mac) = @_;
	$mac = &ble_link_key($mac);
	# Frames from several radios can interleave now, so the reassembly buffer is
	# per link. Keying it by MAC (and falling back to a single bucket when a v1
	# daemon sends no MAC) keeps a watch's half-message from being joined to a
	# board's half-message. The desktop daemon reassembles before emitting; the
	# Android daemon may not, so this stays here too.
	my $rxkey = length($mac) ? $mac : '?';
	if ($data =~ /^(\d+)\/(\d+):(.*)\z/s) {
		my ($index, $total, $body) = (int($1), int($2), $3);
		if ($total > 0 && $total <= 5000 && $index >= 0 && $index < $total) {
			my $now = time();
			my $parts = $gb::ble_rx_parts->{$rxkey};
			my $ptotal = $gb::ble_rx_total->{$rxkey} || 0;
			my $pat = $gb::ble_rx_at->{$rxkey} || 0;
			# fill by index: parts can arrive out of order or twice, and one lost
			# part must not wipe the parts already in hand
			if ($index == 0 || !$parts || $ptotal != $total || $now - $pat > 5) {
				if ($parts && grep { !defined } @{$parts}) {
					my $missing = scalar grep { !defined } @{$parts};
					$log->info("$missing part(s) of a framed BLE message from " . ($rxkey eq '?' ? 'an unnamed link' : $rxkey) . " never arrived; dropped");
				}
				$parts = [ (undef) x $total ];
				$gb::ble_rx_parts->{$rxkey} = $parts;
				$gb::ble_rx_total->{$rxkey} = $total;
			}
			$parts->[$index] = $body;
			$gb::ble_rx_at->{$rxkey} = $now;
			return if grep { !defined } @{$parts};
			$data = join('', @{$parts});
			delete $gb::ble_rx_parts->{$rxkey};
			$gb::ble_rx_total->{$rxkey} = 0;
		}
	}
	# A BLE notification as JSON text from the watch/board. The payload carries
	# the url the old Tasker "rcv bt" task used to fetch, so all existing
	# server-side handling stays untouched.
	my $msg = eval { decode_json $data };
	if ($@ || !$msg || ref $msg ne 'HASH') {
		$log->error('BLE message could not be decoded: ' . ($@ || 'not an object'));
		return;
	}
	my $type = $msg->{'type'};
	# Every embedded device that speaks over the bridge is remembered here, so it
	# can still be listed in the Embedded app while it is off its access point
	# (see device_lister's Bluetooth fallback). The message names the chip, not
	# the radio, so the link's address comes from the bridge events the listener
	# tracks in $gb::ble_link_mac. A tap names its chip only in the url it carries,
	# so read that too - otherwise a connected watch that only ever taps would age
	# out of the list.
	my ($seen_chip, $seen_edt) = ($msg->{'chip_id'}, $msg->{'edt'});
	if (!$seen_chip && ($msg->{'url'} || '') =~ /[?&]chip_id=([^&]+)/) {
		$seen_chip = $1;
	}
	if (!$seen_edt && ($msg->{'url'} || '') =~ /[?&]edt=([^&]+)/) {
		$seen_edt = $1;
	}
	if ($seen_chip) {
		&subs::ble_device_record({
			chip_id => $seen_chip,
			edt => $seen_edt || 'watch',
			name => $msg->{'name'},
			mac => $mac || $gb::ble_primary_mac
		});
	}
	# A battery reply to ble_battery_poll: cache it for the levels scan. The
	# device may be linked to this machine alone, so this reply is what the
	# house will see when it asks this machine's /manager/health.
	if ($type && $type eq 'battery') {
		&subs::ble_battery_note({
			chip_id => $msg->{'chip_id'} || $seen_chip,
			edt => $msg->{'edt'} || $seen_edt || 'watch',
			battery => $msg->{'battery'},
			battery_mv => $msg->{'battery_mv'},
			battery_status => $msg->{'battery_status'},
			mac => $mac || $gb::ble_primary_mac,
		});
		return;
	}
	# the newer bridge messages are dispatches, not url fetches
	if ($type && $type eq 'relay') {
		# A device addressing another device through the house. Route it by chip
		# id: locally if this machine holds that link, otherwise through the
		# active peers (each applies the same homebase rule).
		&subs::ble_relay_route($msg, {});
		return;
	}
	if ($type && $type eq 'state_request') {
		my $chip_id = $msg->{'chip_id'};
		my $edt = $msg->{'edt'} || 'watch';
		# bridged to a machine that is not the watch's homebase? re-home it
		&subs::ble_rehome_check($edt, $chip_id, $msg->{'homebase'});
		my $toggles = {};
		my $rows = &subs::db_select('settings', undef, { setting => 'toggle' })->hashes;
		foreach my $row ( @{$rows} ) {
			next unless $row->{'app'};
			$toggles->{$row->{'app'}} = $row->{'value'} eq 'on' ? 'on' : 'off';
		}
		if ($edt eq 'microcontroller') {
			# A board only needs the apps its own components name; the house can
			# carry a thousand toggles, and sending them all would overflow a
			# board's small receive queue for no benefit.
			my $od = eval { decode_json &subs::embedded_operator_door($edt, $chip_id) } || {};
			my %wanted;
			foreach my $k ( keys %{$od} ) {
				next if $k =~ /^__/;
				$wanted{ $od->{$k}->{'app'} } = 1 if $od->{$k}->{'app'};
			}
			$toggles = { map { $_ => $toggles->{$_} } grep { $wanted{$_} } keys %{$toggles} };
		}
		$log->info('BLE state_request for ' . $chip_id . ': ' . scalar(keys %{$toggles}) . ' toggles');
		&subs::bluetooth_sender_async({
			intent => 'com.jawn.president.bt.connect',
			chip_id => $chip_id,
			edt => $edt,
			message => { type => 'toggles', data => $toggles }
		});
		return;
	}
	if ($type && $type eq 'room_request') {
		my $chip_id = $msg->{'chip_id'};
		my $edt = $msg->{'edt'} || 'watch';
		my $room = $msg->{'room'} || 1;
		if ($edt eq 'microcontroller') {
			# A board cannot inflate a compressed room push and has no use for the
			# chat lists, so it gets the compact role payload instead.
			my $board = &subs::board_config_payload({ edt => $edt, chip_id => $chip_id });
			if ($board) {
				$log->info('BLE board_request for ' . $chip_id);
				&subs::bluetooth_sender_async({
					intent => 'com.jawn.president.bt.connect',
					chip_id => $chip_id,
					edt => $edt,
					message => { type => 'board_config', data => $board }
				});
			}
		}
		else {
			my $payload = &subs::watch_room_payload({ edt => $edt, chip_id => $chip_id });
			if ($payload) {
				$log->info('BLE room_request for ' . $chip_id . ', room ' . $room);
				&subs::bluetooth_sender_async({
					intent => 'com.jawn.president.bt.connect',
					chip_id => $chip_id,
					edt => $edt,
					message => { type => 'room', data => { room => $room, payload => $payload } }
				});
			}
		}
		return;
	}
	if ($type && $type eq 'steps') {
		# the watch hands its pedometer over the BLE link instead of its own
		# access point; the same ingest the /wigi collection uses
		my $samples = $msg->{'data'};
		&subs::step_ingest($samples, $msg->{'base'});
		my $count = ref $samples eq 'ARRAY' ? scalar @{$samples} : 0;
		$log->info('BLE steps for ' . ($msg->{'chip_id'} || '?') . ': ' . $count . ' samples');
		return;
	}
	if ($type && $type eq 'voice') {
		# a clip the watch shipped over the bridge; base64 so it rides the JSON
		# wire. The same ingest the WiFi route runs, so both transports agree.
		my $b64 = $msg->{'data'};
		my $raw = $b64 ? eval { decode_base64 $b64 } : undef;
		if ($raw && &subs::voice_clip_fresh($msg->{'chip_id'}, $msg->{'ts'})) {
			# Tell the watch the clip arrived whole, at once: the watch holds the file
			# and retries it until this lands, so the ack must come off the reassembly
			# and not wait on whisper (seconds). voice_done follows after the file is
			# transcribed, and it is what deletes the watch's copy.
			&subs::bluetooth_sender_async({
				intent => 'com.jawn.president.bt.connect',
				chip_id => $msg->{'chip_id'},
				edt => $msg->{'edt'} || 'watch',
				message => { type => 'voice_recv', ts => (0 + ($msg->{'ts'} || 0)) }
			});
			# Off the listener: whisper takes seconds, and while it ran inline the
			# listener stopped taking the next clip's parts, which the phone then
			# dropped ("276 part(s) never arrived"). The forked worker re-dials the
			# database itself (see database_grabber).
			my ($edt, $chip_id, $ts) = ($msg->{'edt'} || 'watch', $msg->{'chip_id'}, $msg->{'ts'});
			&subs::subprocessor(sub {
				&subs::voice_ingest($raw, { edt => $edt, chip_id => $chip_id, ts => $ts, voice => $msg->{'voice'} });
			}, { name => 'voice ingest' });
		}
		return;
	}
	if ($type && $type eq 'voice_stream') {
		# A clip arriving while it is still being spoken: the watch encodes IMA
		# ADPCM as it records and sends it in parts (seq, last). Reassembled here
		# and wrapped in the same 60-byte WAV header the whole-clip path's file
		# carries, so the ingest does not know the difference. Nothing happens
		# until the last part: a half-clip must never be transcribed as if it were
		# the whole command.
		my $chip_id = $msg->{'chip_id'} || '?';
		my $ts = 0 + ($msg->{'ts'} || 0);
		my $seq = 0 + ($msg->{'seq'} || 0);
		my $key = $chip_id . '|' . $ts;
		my $now = time();
		# a clip nobody finished (the link went away) must not linger
		foreach my $k ( keys %{ $gb::voice_rx || {} } ) {
			delete $gb::voice_rx->{$k} if $now - ($gb::voice_rx->{$k}->{'at'} || 0) > 60;
		}
		if ($seq == 0) {
			$gb::voice_rx->{$key} = { data => '', at => $now, edt => $msg->{'edt'} || 'watch', chip_id => $chip_id, ts => $ts, voice => $msg->{'voice'} };
		}
		my $rec = $gb::voice_rx->{$key};
		if ($rec) {
			$rec->{'at'} = $now;
			my $raw = $msg->{'audio'} ? eval { decode_base64 $msg->{'audio'} } : '';
			$rec->{'data'} .= ($raw // '');
			if ($msg->{'last'}) {
				my $data = $rec->{'data'};
				delete $gb::voice_rx->{$key};
				if (length($data) > 100 && &subs::voice_clip_fresh($chip_id, $ts)) {
					my $wav = &subs::adpcm_wav_wrap($data);
					$log->info('BLE streamed clip for ' . $chip_id . ': ' . length($data) . ' encoded bytes');
					&subs::bluetooth_sender_async({
						intent => 'com.jawn.president.bt.connect',
						chip_id => $chip_id,
						edt => $rec->{'edt'},
						message => { type => 'voice_recv', ts => $ts }
					});
					my ($edt, $voice) = ($rec->{'edt'}, $rec->{'voice'});
					&subs::subprocessor(sub {
						&subs::voice_ingest($wav, { edt => $edt, chip_id => $chip_id, ts => $ts, voice => $voice });
					}, { name => 'voice ingest' });
				}
			}
		}
		return;
	}
	if ($type && $type eq 'button') {
		# A button tap the watch sent over the link. Apply it HERE, on the machine
		# holding the bridge, instead of fetching the url the tap carries: that url
		# names the watch's homebase, which is the wrong machine whenever this one
		# is serving as the fallback, and a machine fetching that url from itself
		# is a needless round trip (it timed out in practice, losing the tap). Runs
		# the same worker /watch/button runs, then pushes the resulting state back.
		my $payload = $msg->{'payload'} || {};
		my $edt = $msg->{'edt'} || 'watch';
		my $chip_id = $msg->{'chip_id'};
		if ((!$chip_id || !$msg->{'edt'}) && $msg->{'url'}) {
			my ($c) = $msg->{'url'} =~ /[?&]chip_id=([^&]+)/;
			my ($e) = $msg->{'url'} =~ /[?&]edt=([^&]+)/;
			$chip_id ||= $c;
			$edt = $e if $e && !$msg->{'edt'};
		}
		# Say so on arrival: the tap is otherwise applied silently, so a tap that
		# never lands (or lands with no chip) is invisible in the log. This is the
		# one line that tells the two apart.
		$log->info('BLE button for ' . ($chip_id || '?') . ': room ' . ($payload->{'room'} || '?') . ', button ' . ($payload->{'button'} || '?'));
		# The same tap can arrive twice (two bridge radios, or an older board
		# that scanned its buttons twice). Apply it once.
		my $ekey = join('|', 'button', $chip_id // '', $payload->{'button'} // '', $payload->{'toggle'} // '', $payload->{'timestamp'} // '');
		if (&subs::event_duplicate($ekey)) {
			$log->info('BLE button for ' . ($chip_id || '?') . ': duplicate tap ignored');
			return;
		}
		my $ws = eval { decode_json &subs::embedded_operator_door($edt, $chip_id) } || {};
		if (!$ws->{'__specs'}) {
			$log->info('BLE button for ' . ($chip_id || '?') . ': no placed settings, dropped');
			return;
		}
		my $tog = (($payload->{'toggle'} || 0) == 1) ? 'off' : 'on';
		# Write the pre-press state without a push before edt_button_presser
		# flips it, exactly like /watch/button. Without this the press flips
		# whatever the app happened to hold (one flip per output, and the
		# board's own relay clicked), instead of landing on the tap's state.
		my $btn_syl = ($edt eq 'microcontroller') ? 10 : 1;
		my $btn_b = $ws->{ &subs::shorthand_name('button', $btn_syl) . $payload->{'button'} } || {};
		&subs::setting_setter({ app => $btn_b->{'app'}, setting => 'toggle', value => $tog, sync => 1, source_chip_id => $chip_id }) if $btn_b->{'app'};
		# Applying a tap reaches the network (a command relayed to another machine)
		# and the database. On the listener's own reader that held up every message
		# behind it, so the next tap was not even logged until the relay returned -
		# the delay before a press appeared at all. The arrival line above stays
		# inline; the work rides a child. (In the child bluetooth_sender_async runs
		# inline, so its ack still follows the press.)
		my ($press_edt, $press_chip, $press_tog, $press_payload, $press_ws)
			= ($edt, $chip_id, $tog, $payload, $ws);
		&subs::subprocessor(sub {
			my $returner = eval {
				&subs::edt_button_presser({
					timestamp => (($press_payload->{'timestamp'} || 0) * 1000) || &subs::rightNow(),
					room => $press_payload->{'room'},
					watch_settings => $press_ws,
					button => $press_payload->{'button'},
					edt => $press_edt,
					chip_id => $press_chip,
					remote_address => 'bluetooth',
					toggle => $press_tog
				});
			};
			$log->error('BLE button press failed: ' . $@) if $@;
			if ($returner && ref $returner eq 'HASH') {
				&subs::bluetooth_sender_async({
					intent => 'com.jawn.president.bt.connect',
					chip_id => $press_chip,
					edt => $press_edt,
					message => { type => 'button', data => $returner }
				});
			}
		}, { name => 'ble button press', sync => 1 });
		return;
	}
	if ($type && $type eq 'switch') {
		# A board's physical switch changed. Apply the same work /watch/switch
		# does, on the machine holding the bridge: flip the app toggle and let
		# edt_button_presser run the movement. A switch has no display ack of its
		# own, so there is nothing to push back.
		my $payload = $msg->{'data'} || $msg->{'payload'} || {};
		my $edt = $msg->{'edt'} || 'microcontroller';
		my $chip_id = $msg->{'chip_id'};
		my $button = $payload->{'switch'} || $payload->{'button'};
		my $state = $payload->{'state'} || '';
		# The same movement can arrive twice (two bridge radios, or an older
		# board that still ran both of its input scanners). One flick applied
		# twice is a toggle that flashes and a relay that clicks on and off.
		my $ekey = join('|', 'switch', $chip_id // '', $button // '', $state);
		if (&subs::event_duplicate($ekey)) {
			$log->info('BLE switch for ' . ($chip_id || '?') . ': duplicate ' . ($state || '?') . ' ignored');
			return;
		}
		my $ws = eval { decode_json &subs::embedded_operator_door($edt, $chip_id) } || {};
		if (!$ws->{'__specs'} || !defined $button) {
			$log->info('BLE switch for ' . ($chip_id || '?') . ': no placed settings, dropped');
			return;
		}
		my $syl_count = ($edt eq 'microcontroller') ? 10 : 1;
		my $b = $ws->{ &subs::shorthand_name('switch', $syl_count) . $button } || {};
		my $toggle = ($state eq 'on') ? 'off' : 'on';
		$log->info('BLE switch for ' . ($chip_id || '?') . ': switch ' . $button . ' -> ' . $toggle . ' @' . ($payload->{'ms'} // '?'));
		# Same reason as a button: the movement can relay a command or run one.
		my ($sw_edt, $sw_chip, $sw_ws, $sw_button, $sw_b, $sw_payload, $sw_toggle)
			= ($edt, $chip_id, $ws, $button, $b, $payload, $toggle);
		&subs::subprocessor(sub {
			# The board already applied its own relay locally; write the pre-press
			# state without a push and with this chip excluded, exactly like
			# /watch/switch. Pushing the intermediate state back was a second relay
			# command (pin -1, or a visible click) and the flash the person saw.
			&subs::setting_setter({ app => $sw_b->{'app'}, setting => 'toggle', value => $sw_toggle, sync => 1, source_chip_id => $sw_chip }) if $sw_b->{'app'};
			eval {
				&subs::edt_button_presser({
					timestamp => (($sw_payload->{'timestamp'} || 0) * 1000) || &subs::rightNow(),
					room => $sw_payload->{'room'},
					watch_settings => $sw_ws,
					button => $sw_button,
					component => 'switch',
					edt => $sw_edt,
					chip_id => $sw_chip,
					remote_address => 'bluetooth',
					toggle => $sw_toggle,
					state => $sw_toggle
				});
			};
			$log->error('BLE switch press failed: ' . $@) if $@;
		}, { name => 'ble switch press', sync => 1 });
		return;
	}
	if ($type && $type eq 'measure') {
		# A pot on a board, over the bridge. Mirror /watch/measure: scale the raw
		# reading through the app's app_measures and hand it to the same worker.
		my $payload = $msg->{'data'} || $msg->{'payload'} || {};
		my $edt = $msg->{'edt'} || 'microcontroller';
		my $chip_id = $msg->{'chip_id'};
		my $component = $payload->{'component'} || 'pot';
		my $button = $payload->{'button'} || $payload->{'pin'};
		my $measure = $payload->{'measure'};
		my $ws = eval { decode_json &subs::embedded_operator_door($edt, $chip_id) } || {};
		if (!$ws->{'__specs'} || !defined $button) {
			$log->info('BLE measure for ' . ($chip_id || '?') . ': no placed settings, dropped');
			return;
		}
		my $syl_count = ($edt eq 'microcontroller') ? 10 : 1;
		my $b = $ws->{ &subs::shorthand_name($component, $syl_count) . $button } || {};
		my $emin = $payload->{'min'} || 0;
		my $emax = $payload->{'max'} || 1024;
		my $settings = &subs::settings_grabber({ app => $b->{'app'}, settings => ['app_measures'] });
		my $app_measures = eval { decode_json $settings->{'app_measures'} } || {};
		if (exists $app_measures->{$b->{'measure'}}->{'max'} && exists $app_measures->{$b->{'measure'}}->{'min'}) {
			my $etotal = $emax - $emin;
			my $estate = $measure - $emin;
			my $eratio = $etotal ? ($estate / $etotal) : 0;
			my $total = $app_measures->{$b->{'measure'}}->{'max'} - $app_measures->{$b->{'measure'}}->{'min'};
			my $state_total = $eratio * $total;
			$measure = sprintf("%.3f", $state_total + $app_measures->{$b->{'measure'}}->{'min'});
		}
		# A pot turn can run a command too, so it gets the same treatment as a tap.
		my ($m_edt, $m_chip, $m_ws, $m_button, $m_measure, $m_component, $m_payload)
			= ($edt, $chip_id, $ws, $button, $measure, $component, $payload);
		&subs::subprocessor(sub {
			eval {
				&subs::edt_button_presser({
					timestamp => &subs::rightNow(),
					room => $m_payload->{'room'},
					watch_settings => $m_ws,
					button => $m_button,
					edt => $m_edt,
					chip_id => $m_chip,
					measure => $m_measure,
					component => $m_component,
					remote_address => 'bluetooth'
				});
			};
			$log->error('BLE measure failed: ' . $@) if $@;
		}, { name => 'ble measure press' });
		return;
	}
	if ($type && $type eq 'state') {
		# A board confirming what it applied. The manager already stored the
		# intent; log it so a board that clamps a servo is visible, and leave the
		# record alone.
		my $payload = $msg->{'data'} || {};
		$log->info('BLE state ack from ' . ($msg->{'chip_id'} || '?') . ': ' . ($payload->{'component'} || '?') . ' ' . ($payload->{'pin'} || '?') . ' -> ' . ($payload->{'state'} || '?'));
		return;
	}
	my $url = $msg->{'url'};
	if (!$url) {
		$log->info('BLE message without url: ' . $data);
		return;
	}
	# The old check looked at the response before the asynchronous request had
	# any chance to complete, so a dead homebase and a good fetch looked alike.
	# One kept-alive user agent plus the completion callback log what happened.
	eval {
		$gb::ble_ua ||= Mojo::UserAgent->new(connect_timeout => 5, inactivity_timeout => 10);
		$gb::ble_ua->insecure(1)->get($url, sub {
			my ($ua, $tx) = @_;
			if ($tx->error) {
				$log->error('BLE message fetch failed: ' . $tx->error->{message} . ' for ' . $url);
			}
			else {
				$log->info('BLE message fetched: ' . $tx->res->code . ' ' . $url);
			}
		});
	};
	$log->error('BLE message fetch dispatch failed: ' . $@) if $@;
}

sub ble_listener_start {
	# One long-lived 'jawn-bt listen' child: every BLE message the daemon
	# receives ends up in ble_message_processor(). Restarted if it dies.
	return if $gb::ble_listener;
	my $client = &ble_bridge_client();
	return unless &ble_bridge_enabled() && $client;
	# Before the listener starts taking messages: put every bridge on the right
	# side of its link (drop a chase that is not ours, start one we must serve).
	# Best-effort: a failure here must not stop the listener from coming up.
	eval { &ble_enforce_hosts(); };
	# And keep it that way: the homebase may go quiet (a dead phone), when this
	# machine has to take the watch over, and come back, when it must hand it
	# back. One timer per process.
	unless ($gb::ble_enforce_timer) {
		$gb::ble_enforce_timer = 1;
		Mojo::IOLoop->recurring(60 => sub { eval { &ble_enforce_hosts(); }; });
	}
	# Ask every already-linked board for its battery on the same rhythm as
	# the levels pass; the reply lands in ble_message_processor.
	unless ($gb::ble_battery_timer) {
		$gb::ble_battery_timer = 1;
		Mojo::IOLoop->timer(8 => sub { eval { &ble_battery_poll(); }; });
		Mojo::IOLoop->recurring(120 => sub { eval { &ble_battery_poll(); }; });
	}
	# A child that is alive but stuck holds a core forever: on(close) only sees
	# an exit. Watch its CPU time and restart what sustains a core without
	# making progress (a runaway event stalled the client inside one read).
	unless ($gb::ble_listener_guard_timer) {
		$gb::ble_listener_guard_timer = 1;
		my $hz = do { local $@; eval { require POSIX; POSIX::sysconf(POSIX::_SC_CLK_TCK()) } } || 100;
		my ($watched, $ticks, $at, $runs) = (0, 0, 0, 0);
		Mojo::IOLoop->recurring(20 => sub {
			my $fork = $gb::ble_listener or return;
			my $now = time;
			my $child = eval { $fork->pid } || 0;
			my $cpu = &cpu_ticks($child);
			return unless defined $cpu;
			if ($child == $watched && $at) {
				$runs = &cpu_hog($cpu - $ticks, $now - $at, $hz) ? $runs + 1 : 0;
				if ($runs >= 2) {
					$log->error('BLE listener held a core for 40s without progress; restarting it');
					kill 'TERM', $child;
					($watched, $ticks, $at, $runs) = (0, 0, 0, 0);
					return;
				}
			}
			($watched, $ticks, $at) = ($child, $cpu, $now);
		});
	}
	$gb::ble_listener_buffer = drain_new();
	$gb::ble_listener = Mojo::IOLoop::ReadWriteFork->new;
	$gb::ble_listener->on(read => sub {
		my ($fork, $bytes) = @_;
		# Reads are arbitrary chunks: a JSON line longer than one chunk used to
		# be decoded in halves and silently dropped. drain_feed buffers until the
		# newline. An incomplete line is kept as chunks and joined only when a
		# newline arrives: splitting (or appending to) an unterminated tail on
		# every read was quadratic, and pinned a core while the bridge streamed
		# one long event.
		my ($lines, $dropped) = drain_feed($gb::ble_listener_buffer, $bytes, 8 * 1024 * 1024);
		foreach my $line (@$lines) {
			my $event = eval { decode_json $line };
			next unless $event && ref $event eq 'HASH';
			my $name = $event->{'event'} || '';
			# Keep the per-MAC link map current. Every link-scoped event names its
			# radio now, so a sighting, a send and a yield can all name the right
			# one instead of "the" link.
			if ($name eq 'connected' || $name eq 'disconnected' || $name eq 'status') {
				&ble_link_apply_event($event);
			}
			if ($name eq 'connected') {
				# Linked to a device this machine may not serve? Release that
				# radio at once, before it even speaks, so the homebase keeps it.
				my $chip = &ble_chip_by_mac($event->{'mac'});
				&ble_yield($chip->{'id'}, $event->{'mac'}) if $chip && !&ble_may_serve($chip->{'purpose'} || 'watch', $chip->{'id'});
			}
			elsif ($name eq 'status') {
				# The links can already be up when the listener attaches: release
				# any of them that is not ours to hold.
				foreach my $l ( @{ $event->{'links'} || [] } ) {
					next unless ref $l eq 'HASH' && $l->{'connected'};
					my $chip = &ble_chip_by_mac($l->{'mac'});
					&ble_yield($chip->{'id'}, $l->{'mac'}) if $chip && !&ble_may_serve($chip->{'purpose'} || 'watch', $chip->{'id'});
				}
				# A v1 daemon has no links[]; keep the top-level fallback.
				if (!@{ $event->{'links'} || [] } && $event->{'connected'}) {
					my $chip = &ble_chip_by_mac($event->{'mac'});
					&ble_yield($chip->{'id'}, $event->{'mac'}) if $chip && !&ble_may_serve($chip->{'purpose'} || 'watch', $chip->{'id'});
				}
			}
			elsif ($name eq 'message') {
				&ble_message_processor($event->{'data'}, $event->{'mac'});
			}
			elsif ($name eq 'error') {
				# The client gives up rather than spin when its select has gone
				# bad; say why in the log, because the process then exits and
				# the only other trace is the restart 30 s later.
				$log->error('BLE listener error: ' . ($event->{'error'} || 'unknown')
					. (defined $event->{'err'} ? " ($event->{'err'})" : ''));
			}
		}
		# Only the unterminated tail is dropped. The check used to run before the
		# drain, so one overlong event discarded the complete lines behind it too.
		if ($dropped) {
			$log->error('BLE listener buffer overflow; dropping partial data (' . $dropped . ' bytes)');
		}
	});
	$gb::ble_listener->on(close => sub {
		$gb::ble_listener = undef;
		Mojo::IOLoop->timer(30 => sub { &ble_listener_start(); });
	});
	print "Starting BLE bridge listener\n";
	$gb::ble_listener->start({ program => $^X, program_args => [ $client, 'listen' ] });
	return 1;
}

# The backups registry is merged across the mesh, so rows pile up for every
# machine's old archives - and the file-based prune in backup_now can only ever
# match this machine's own files, which is why a peer's rows (a phone's
# /data/data/... paths, say) were never cleaned and the table ran to thousands.
# Bound it: keep only the newest few rows per (reason, machine, recipient,
# destination) and delete the rest, with a tombstone so the deletion reaches the
# other machines too. Keeping the newest is what makes it safe: the newest
# remote_upgraded row of a group is the sync watermark (remote_machine's
# reconnector and remote_upgrade read it), and merge_database reads the newest
# one or two rows overall. Capped so one pass never floods the tombstone log;
# successive backups finish the job.
sub backup_registry_prune {
	my $keep = shift || 5;
	my ($db,$database,$sql) = &subs::database_grabber();
	return 0 unless $db;
	my $cap = 500;
	my $groups = &subs::db_query(
		"select ifnull(reason,'') reason, ifnull(signatorial,'') signatorial, ifnull(recipient,'') recipient, ifnull(destination,'') destination, count(*) c from backups group by reason, signatorial, recipient, destination having count(*) > ?",
		$keep
	)->hashes || [];
	my $deleted = 0;
	foreach my $g ( @{$groups} ) {
		last if $deleted >= $cap;
		my $rows = &subs::db_query(
			"select uuid, server_time from backups where ifnull(reason,'') = ? and ifnull(signatorial,'') = ? and ifnull(recipient,'') = ? and ifnull(destination,'') = ? order by cast(server_time as integer) desc",
			$g->{'reason'}, $g->{'signatorial'}, $g->{'recipient'}, $g->{'destination'}
		)->hashes || [];
		for (my $i = $keep; $i < scalar @{$rows}; $i++) {
			last if $deleted >= $cap;
			my $r = $rows->[$i];
			next unless $r->{'uuid'};
			&subs::deletion_registration({ table => 'backups', uuid => $r->{'uuid'}, scope => 'single', server_time => $r->{'server_time'} });
			&subs::db_delete('backups', { uuid => $r->{'uuid'} });
			$deleted++;
		}
	}
	return $deleted;
}

1;
