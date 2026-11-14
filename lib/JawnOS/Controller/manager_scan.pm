package Manager;

# manager_scan: the Scan app. Paper that came off the scanner and has not been
# filed anywhere yet waits here, the way a capture taken in the Camera app waits
# in its unclaimed pool. A scan is an appointment (app=scan, source=unclaimed)
# holding ordinary file rows with a seven-day warranty, so /file_open shows the
# pages and /manager/unclaimed/claim files them onto an appointment later - the
# same routes the Camera pool uses, with holder=scan.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use Mojo::JSON qw(decode_json encode_json);
use MIME::Base64;

# GET /manager/scan
sub action_52326 {
	my $c = shift;
	my $content = $c->render_to_string(template => 'apps/scan');
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'scan', title => 'Scan', contents => $content }, $c->param('timestamp'));
	$c->render(text => $contents);
}

# The pool, and who would scan if a page went in now. The dispatcher is the same
# election the ADF watcher uses, so the app and the automatic path agree about
# which machine owns the printer.
# GET /manager/scan/pool
sub action_52327 {
	my $c = shift;
	my $last_error = eval { &subs::cache_get({ app => 'scan', context => 'last_error' }) };
	$last_error = undef unless ref $last_error eq 'HASH'
		&& (($last_error->{'at'} || 0) + 0) > &subs::rightNow() - 5 * 60 * 1000;
	$c->render(json => {
		ok => 1,
		items => &scan_pool_items($c),
		scanner => &subs::scan_dispatcher(),
		here => &subs::scan_dispatcher_here() ? 1 : 0,
		feeds => &scan_feeds(),
		scanners => &scan_scanner_rows(),
		pending => &scan_pending_job(),
		error => $last_error ? $last_error->{'message'} : undef,
	});
}

# Take a page. The press writes the holding row and the scanner fills it; the
# row is the appointment the person files later, so nothing is copied when they
# do. A feed this machine cannot run is handed to another machine by scan()
# itself, which is the same relay every app's scan button uses.
# POST /manager/scan/capture
sub action_52328 {
	my $c = shift;
	my $feed = lc($c->param('feed') || '');
	unless ($feed =~ /^(?:adf|flatbed)$/) {
		return $c->render(json => { ok => 0, error => 'choose the feeder or the flatbed' });
	}
	my $now = &subs::rightNow();
	$c->param('source' => 'unclaimed');
	$c->param('feed' => $feed);
	# A machine without a scanner does not write a row it cannot fill: the
	# elected machine gets the whole press, creates the holding row there, and
	# the row syncs back with the page in it. The relay carries the uuid, so the
	# two machines agree on which row the scan belongs to.
	my $me = &subs::scan_house_me();
	my $dispatcher = &subs::scan_dispatcher();
	my $can_here = grep { $_ eq $feed } @{ &scan_feeds() };
	if (!$can_here && $dispatcher ne '' && $dispatcher ne $me) {
		my $handed = &subs::random_string_creator(20);
		$c->param('uuid' => $handed);
		&subs::remote_relay_request($c, { remote_uuid => $dispatcher });
		return $c->render(json => { ok => 1, uuid => $handed, machine => $dispatcher, queued => 1 });
	}
	my $uuid = $c->param('uuid') || &subs::random_string_creator(20);
	$c->param('uuid' => $uuid);
	# An automatic edge names its scan id. The claim file makes the app window
	# that got there first the only one that takes the paper; the rest stand
	# down, and the row this press writes is the same id the job recorded.
	my $scan_id = $c->param('scan_id') || '';
	$scan_id =~ s/[^A-Za-z0-9]//g;
	$scan_id = substr($scan_id, 0, 64);
	if (length $scan_id) {
		unless (&scan_claim_once($scan_id)) {
			return $c->render(json => { ok => 1, claimed => 0, queued => 1, uuid => $uuid });
		}
		eval { &subs::scan_job_state($scan_id, 'running') };
		$c->param('uuid' => $scan_id);
		$uuid = $scan_id;
	}
	my $started = eval {
		&appointment_writer($c, {
			app => 'scan',
			type => 'scan',
			timestamp => $now,
			server_time => $now,
			uuid => $uuid,
			file => '[]',
			source => 'unclaimed',
			warranty => $now + (7 * 24 * 60 * 60 * 1000),
		});
		1;
	};
	unless ($started) {
		return $c->render(json => { ok => 0, error => 'the scan could not be started' });
	}
	# The row is the waiting place, not the scan: the same press the appointment
	# windows send fills it. scan() resolves the feeder, writes the pages into
	# this row and raises the house notice; it forks the run, so the answer below
	# is still immediate.
	&scan($c, {
		timestamp => $now,
		feed => $feed,
		uuid => $uuid,
		app => 'scan',
		source => 'unclaimed',
		scan_id => $scan_id,
	});
	$c->render(json => { ok => 1, uuid => $uuid });
}

# What the automatic scan service does for one scanner: watch the feeder or not,
# and where a loaded edge goes (Market's receipt reader, or the Scan app's pool).
# The rules are house-wide, so every machine edits and reads the same choice.
# POST /manager/scan/scanner
sub action_52330 {
	my $c = shift;
	my $key = $c->param('key') || '';
	my $row = (grep { ($_->{'key'} || '') eq $key } @{ &scan_scanner_rows() })[0];
	unless ($row) { return $c->render(json => { ok => 0, error => 'no such scanner' }); }
	my $auto = $c->param('auto') ? 1 : 0;
	my $target = ($c->param('target') || '') eq 'scan' ? 'scan' : 'market';
	&subs::scan_scanner_rule_save($key, $row->{'name'}, $auto, $target);
	eval {
		&Websocket::send('server', {
			console => &Websocket::console_command('scanScannersReload'),
			timestamp => &subs::rightNow(),
		});
		1;
	};
	$c->render(json => { ok => 1, scanners => &scan_scanner_rows() });
}

# Throw a scan away: the paper is not worth keeping, and the pool should not
# carry it for a week. delete_file unlinks the page and deletes a holder left
# with nothing in it, so discarding the last page and discarding the whole scan
# end the same way.
# POST /manager/scan/discard
sub action_52329 {
	my $c = shift;
	my $appt_uuid = $c->param('appt_uuid') || '';
	my $file_uuid = $c->param('file_uuid') || '';
	my $held = $appt_uuid ne ''
		? &subs::db_select('appointments', undef, { app => 'scan', uuid => $appt_uuid, source => 'unclaimed' })->hashes->[0]
		: undef;
	unless ($held) { return $c->render(json => { ok => 0, error => 'no such scan' }); }
	if ($file_uuid ne '') {
		my $files = eval { decode_json $held->{'file'} } || [];
		unless (grep { (($_->{'uuid'} || '') eq $file_uuid) } @{$files}) {
			return $c->render(json => { ok => 0, error => 'no such page in that scan' });
		}
		&delete_file({ file_uuid => $file_uuid, app_uuid => $appt_uuid, app => 'scan', reason => 'discarded' });
	}
	else {
		&delete_app('scan', $appt_uuid, $held->{'server_time'}, 'discarded');
	}
	$c->render(json => { ok => 1 });
}

1;
