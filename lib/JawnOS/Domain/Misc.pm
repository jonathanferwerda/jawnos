package subs;

# Misc half of the domain layer: functions subroutines.pl calls that used
# to live in Manager.pl. Same package (subs) so every call site and the
# Manager:: aliases keep working; the Loader in lib/JawnOS/Domain/Loader.pm
# requires this file on the first call that needs it.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';

use File::Slurp qw(read_file write_file);
use Mojo::JSON qw(decode_json encode_json);
use Cwd ();

# File-scope state owned by subroutines.pl, in this same package.
our $config;
our $device;
our $log;
our $logfile;

sub leave($c) {
	if (!$c) {
		$c = &subs::controller_builder();
		$c->session('authentication', &subs::suds_grabber());
		$c->req->url->path('/manager/leave');
	}
	my ($db,$database,$sql) = &subs::database_grabber();
	&subs::say_it('leave');
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	$c->param('reason' => 'leave');
	my $server_time = &subs::rightNow();

	&subs::db_delete('settings',{app => '__DEBRIEFING__', device => $device});
	&subs::db_delete('settings',{app => 'keyboard'});
	&subs::db_delete('settings',{app => 'watch', setting => 'patience' });
#	&subs::db_delete('remote_machines');
	my $hostname = &subs::machine_hostname();
	if ($c->param('debriefer')) {
		my $d = $c->param('debriefer');
		my $settings = decode_json $d;
		&subs::db_insert('settings', {
			app => '__DEBRIEFING__',
			timestamp => $timestamp,
			setting => $hostname,
			value => $d,
			device => $device,
			uuid => &subs::random_string_creator(20)
		});
	}
	my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'customs', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', $timestamp);
	&subs::db_insert('appointments', { warranty => $warranty, uuid => &subs::random_string_creator(40), app => "customs", type => "depart", timestamp => $timestamp, server_time => $server_time });
	# Never shred the only copy of the house on a backup that did not seal.
	# backup_now now verifies the ciphertext; this is the second lock, because
	# the cost of being wrong is the whole database. Both the timestamped
	# archive and the stable jawnos.enc must hold real ciphertext.
	my $backup = &subs::backup_now($c);
	unless (ref $backup eq 'HASH'
		&& &subs::backup_sealed_ok($backup->{'archive_path'})
		&& &subs::backup_sealed_ok($backup->{'path'})) {
		&subs::say_it('leave refused: no sealed backup');
		return { ok => 0, error => 'Could not seal the database; it was kept.' };
	}
	&remote_relay_request($c, { mode => 'emergency' });
	# The answer is the gate, and the worker that draws it still reads the house:
	# its theme, its passkeys, the sealed copies it lists. Shredding here took
	# the database out from under that render, the port went silent and the
	# browser was told the seal had failed. The shred is its own process a
	# moment behind the response, so the gate is written first and the file is
	# gone before anyone could reach for it.
	&subs::subprocessor(sub {
		select undef, undef, undef, 2;
		`shred -u $database` if $database;
		`shred -u $database-shm` if $database;
		`shred -u $database-wal` if $database;
		`shred -u $logfile` if $logfile;
	}, { name => 'leave shredder', fork => 1 });
	delete $c->session->{'authentication'};
	delete $c->session->{'database'};
	delete $c->session->{'suds_id'};
	delete $c->session->{'device_uuid'};
	delete $c->session->{'reject_count'};
	delete $c->session->{'browser_tab_id'};
	delete $c->session->{'browser_tab'};
	$gb::suds = undef;

	$gb::database_holder = undef;
	&subs::say_it('Goodbye');
	$sql = undef;
	return { ok => 1 };
}

# The power choices the Leave menu may offer. A phone's app cannot power the
# phone, so a handheld gets none and the menu offers Exit alone; a machine
# with neither systemd nor logind has nothing to ask, so it does not grow
# buttons that can only fail.
our %power_actions_cache;
sub power_actions() {
	my $machine = &subs::device_setter() || '';
	my $key = ($machine eq 'mobile') ? 'mobile' : 'machine';
	return @{ $power_actions_cache{$key} } if $power_actions_cache{$key};
	my @actions;
	# Windows has no systemd, logind or xset, and `command -v` is a POSIX shell
	# builtin: each probe here would start cmd.exe on a page render. There is
	# nothing to offer, so answer without asking. (Exit in the Leave menu is the
	# page's own, not a power action.)
	if ($^O eq 'MSWin32') {
		$power_actions_cache{$key} = \@actions;
		return @actions;
	}
	unless ($key eq 'mobile') {
		my $systemctl = `command -v systemctl 2>/dev/null`;
		my $loginctl = `command -v loginctl 2>/dev/null`;
		if (length $systemctl || length $loginctl) {
			@actions = qw(restart shutdown);
			# A gateway has to stay reachable: system suspend would take the
			# radios down, so a controller is offered the dark idle instead.
			push @actions, 'sleep' unless $machine eq 'controller';
		}
		push @actions, 'screen_off' if &_screen_off_option();
		push @actions, 'logout' if length &_logind_session_id();
	}
	$power_actions_cache{$key} = \@actions;
	return @actions;
}

# The session logind can end on our behalf. XDG_SESSION_ID is the honest
# answer from a session's own environment; when this process was started by
# the system unit there is none, so ask logind for the session holding us.
# An id is used in a shell word below, so it is validated first.
sub _logind_session_id() {
	my $loginctl = `command -v loginctl 2>/dev/null`;
	chomp $loginctl;
	return '' unless length $loginctl;
	my $id = $ENV{'XDG_SESSION_ID'} || '';
	$id = `$loginctl show-session self -p Id --value 2>/dev/null` unless length $id;
	chomp $id;
	return '' unless $id =~ /^[A-Za-z0-9_.-]+$/;
	my $known = `$loginctl show-session '$id' -p Id --value 2>/dev/null`;
	chomp $known;
	return $known eq $id ? $id : '';
}

# Screen off is a dark panel, not a power state: xset owns an X session, the
# backlight and the framebuffer own the console. Any one of them is enough to
# offer the choice; _screen_off_run() tries them in that order and names the
# one that ran. A blanked framebuffer is repainted by whatever owns the panel,
# so the dark lasts only if the caller stops that painter first.
sub _screen_off_option() {
	my $xset = `command -v xset 2>/dev/null`;
	return 1 if length $xset;
	my @backlight = glob('/sys/class/backlight/*');
	return 1 if @backlight;
	return -d '/sys/class/graphics/fb0' ? 1 : 0;
}

sub _screen_off_run() {
	# A handheld with no backlight node has its own dark-idle helper. It is a
	# no-op (exit 3) elsewhere, so the generic paths below still run; the sudo
	# retry is what lets the unprivileged manager stop the kiosk and write fb0.
	my $helper = 'scripts/jawnos_screen.pl';
	if (-e $helper) {
		my $abs = Cwd::abs_path($helper) || $helper;
		my $rc = system($^X, $abs, 'off');
		return (0, 'screen helper') if $rc == 0;
		my $sudo = `command -v sudo 2>/dev/null`;
		chomp $sudo;
		if (length $sudo) {
			$rc = system($sudo, '-n', $^X, $abs, 'off');
			return (0, 'screen helper') if $rc == 0;
		}
	}
	my $xset = `command -v xset 2>/dev/null`;
	chomp $xset;
	if (length $xset) {
		my $rc = system($xset, '-display', ':0', 'dpms', 'force', 'off');
		return ($rc, 'xset') if $rc == 0;
	}
	my $sudo = `command -v sudo 2>/dev/null`;
	chomp $sudo;
	my $prefix = length $sudo ? [$sudo, '-n'] : [];
	my @backlight = glob('/sys/class/backlight/*');
	if (@backlight) {
		my $rc = system(@$prefix, 'sh', '-c', 'echo 4 > /sys/class/backlight/*/bl_power');
		return ($rc, 'backlight') if $rc == 0;
	}
	if (-d '/sys/class/graphics/fb0') {
		my $rc = system(@$prefix, 'sh', '-c', 'echo 4 > /sys/class/graphics/fb0/blank');
		return ($rc, 'framebuffer') if $rc == 0;
	}
	return (1, '');
}

# The idle timeout's own pair: dark the panel without stopping anything. `off`
# is the Leave menu's and it stops X, gou-rotate and the kiosk - nothing could
# wake that but a reboot. This leaves the page running behind a dark backlight,
# so the first press reaches it and it asks for the light back.
sub panel_blank {
	my ($on) = @_;
	my $helper = 'scripts/jawnos_screen.pl';
	return { ok => 0, error => 'the screen helper is missing' } unless -e $helper;
	my $abs = Cwd::abs_path($helper) || $helper;
	my $action = $on ? 'unblank' : 'blank';
	my $rc = system($^X, $abs, $action);
	# The board's manager runs as the tree's account and the backlight is root's.
	if ($rc != 0) {
		my $sudo = `command -v sudo 2>/dev/null`;
		chomp $sudo;
		$rc = system($sudo, '-n', $^X, $abs, $action) if length $sudo;
	}
	return { ok => 1, action => $action } if $rc == 0;
	return { ok => 0, action => $action, error => 'the panel could not be changed' };
}

# Run one of the menu's choices. The action is a fixed word from
# power_actions(), never the request body, and only a citizen session reaches
# the route. --no-block hands the job to systemd and returns, so the reply
# reaches the page before the machine goes down.
sub power_action($action) {
	$action = '' unless defined $action;
	my %allowed = map { $_ => 1 } &power_actions();
	return { ok => 0, error => 'unsupported' } unless $allowed{$action};
	my $rc = 1;
	my $method = '';
	if ($action eq 'logout') {
		my $id = &_logind_session_id();
		return { ok => 0, error => 'no session' } unless length $id;
		my $loginctl = `command -v loginctl 2>/dev/null`;
		chomp $loginctl;
		return { ok => 0, error => 'no power tool' } unless length $loginctl;
		$rc = system($loginctl, 'terminate-session', $id);
		if ($rc != 0) {
			my $sudo = `command -v sudo 2>/dev/null`;
			$rc = system('sudo', '-n', $loginctl, 'terminate-session', $id) if length $sudo;
		}
		$method = 'loginctl';
	}
	elsif ($action eq 'screen_off') {
		($rc, $method) = &_screen_off_run();
	}
	else {
		my %verb = ( restart => 'reboot', shutdown => 'poweroff', sleep => 'suspend' );
		my $verb = $verb{$action};
		my @cmd;
		my $systemctl = `command -v systemctl 2>/dev/null`;
		chomp $systemctl;
		if (length $systemctl) {
			@cmd = ($systemctl, '--no-block', $verb);
		}
		else {
			my $loginctl = `command -v loginctl 2>/dev/null`;
			chomp $loginctl;
			@cmd = ($loginctl, $verb) if length $loginctl;
		}
		return { ok => 0, error => 'no power tool' } unless @cmd;
		$rc = system(@cmd);
		# A desktop started outside the graphical session (a system unit, a
		# headless test) is not an active logind session, so polkit may refuse.
		# The live image grants passwordless sudo; -n never prompts and never hangs.
		if ($rc != 0) {
			my $sudo = `command -v sudo 2>/dev/null`;
			$rc = system('sudo', '-n', @cmd) if length $sudo;
		}
	}
	&subs::say_it('power ' . $action . ($rc == 0 ? ' requested' : ' failed'));
	return { ok => 0, error => 'refused' } unless $rc == 0;
	return { ok => 1, action => $action, ($method ? (method => $method) : ()) };
}

sub misc_setting_list {
    my ($db, $database, $sql) = &subs::database_grabber();
		my @locations = &subs::location_types();
    my @settings = qw/max_files thumbnail_size photo_size max_backups scan_size encryption_standard archive_dir say_voice language/;
		foreach my $l ( @locations ) {
			push @settings, $l . '_location';
			push @settings, $l . '_archive';
		}
    my $settings = {};
    my $signatorial = &subs::signatorial_designer();
    my $device = &subs::device_setter();

    # 1. Collect all target devices into a single list. 'all' carries the
    # house-wide choices (the interface language), which every machine and
    # every device tab reads.
    my @devices = ( 'all', @gb::device_types, $signatorial );

    # 2. Fetch ALL matching records in a single database call
    # This assumes db_select supports array references for IN clauses
    my $results = eval {
        &subs::db_select('settings', ['device', 'setting', 'value'], {
            app    => 'misc',
            setting => \@settings,
            device  => \@devices
        })->hashes || [];
    };
    if ($@) {
        $log->error("Database error in misc_setting_list: $@");
    }

    # 3. Map the flat database rows into your nested $settings hash
    foreach my $row (@{$results}) {
        # Check for lowercase 'null' or undef from your previous database quirk
        my $val = (defined $row->{value} && lc($row->{value}) ne 'null') ? $row->{value} : undef;
        $settings->{$row->{device}}->{$row->{setting}} = $val;
    }

    # 4. Apply fallback defaults for missing settings, ensuring structure exists
    foreach my $dt (@devices) {
        foreach my $s (@settings) {
            my $res = $settings->{$dt}->{$s};

            if ($dt eq $signatorial && !$res) {
                $settings->{$dt}->{$s} = $settings->{$device}->{$s};
            }
        }
    }

    return $settings;
}

sub ocr_reader($c,$filename) {
	my $text_file = $filename;
	# OCR is a convenience, never a condition of the capture. A device without
	# tesseract (the Android app's Termux image has none) used to run the shell
	# command, get no .txt, and then read_file() died - turning a successful
	# photo into HTTP 500 after the image was already on disk. Missing engine or
	# empty output means "no text", not "the capture failed".
	my $engine = `command -v tesseract 2>/dev/null`;
	return undef unless $engine =~ /\S/;
	my $src = &subs::shell_quote($filename);
	my $out = &subs::shell_quote($text_file);
	`tesseract $src $out 2>/dev/null`;
	$text_file = $text_file . '.txt';
	unless (-e $text_file) {
		return undef;
	}
	my $ocr = eval { read_file($text_file) };
	# Keep every printable character, including accented letters and CJK text.
	# Only the control bytes that OCR engines emit are removed; the old ASCII
	# filter silently erased whole languages from a scanned document.
	$ocr =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]+//g if defined $ocr;
	$ocr = &subs::note_encrypter(&subs::session_suds($c),$ocr);
	# `shred` is not in the Android runtime; secure_unlink falls back to unlink,
	# which is what stops the empty .txt files accumulating beside the pictures.
	&subs::secure_unlink($text_file);

	return $ocr;
}

# Resolve a repo-relative path, refusing anything that climbs out of the tree or
# reaches state the agent must not touch (git internals, local config, the blob
# stores whose files are large binaries kept out of git).
sub coding_path($rel) {
	$rel = '' unless defined $rel;
	$rel =~ s{^\./+}{};
	$rel =~ s{^/+}{};
	return undef if $rel =~ /(^|\/)\.\.(\/|$)/;
	return undef if $rel =~ /[\x00-\x1f"`\\\$;(){}|&<>]/;
	return undef if $rel =~ m{^(?:\.git|\.secrets|\.president|releases|voices)(?:/|$)};
	return undef if $rel =~ m{(?:^|/)\.env(?:$|\.)};
	return undef if $rel =~ m{(?:^|/)(?:jawnos\.db(?:-wal|-shm)?|initial\.enc)$};
	return undef if $rel eq 'config.json';
	# the live ticket is a credential, and it sits in a folder that is otherwise
	# the agent's scratch space
	return undef if $rel eq '.shots/ticket.txt';
	my $repo = &coding_repo();
	my $abs = $repo . ($rel eq '' ? '' : '/' . $rel);
	# The name is not the file: a symlink inside the repo can take a path out of
	# it. Judge where it really goes, and refuse it when that is outside.
	my $repo_real = &coding_real_path($repo);
	my $abs_real = &coding_real_path($abs);
	if (length $repo_real && length $abs_real) {
		return undef unless $abs_real eq $repo_real || index($abs_real, "$repo_real/") == 0;
	}
	# Hand back the path that was actually checked, not the name it was asked for,
	# so nothing between the check and the write can be redirected by a symlink.
	return length $abs_real ? $abs_real : $abs;
}

# A closed websocket is still worth keeping. The row already spans the session
# (`connected` is the connect time, `server_time` the last message), so retiring
# it rather than deleting it leaves the house a month of "this device was up"
# for the clothesline and for any app that reads activity later. The warranty is
# its own and bounded: the app/me warranties are years out, and reusing them is
# what once left hundreds of dead rows behind.
sub websocket_retire {
	my ($where, %opt) = @_;
	$where = {} unless ref $where eq 'HASH';
	my $now = $opt{'now'} || &subs::rightNow();
	my $keep = $opt{'warranty'} || &subs::ago_calc('-30d', $now);
	my @clause = (q{coalesce("type", '') != ?});
	my @bind = ('closed', $now, $keep, 'closed');
	foreach my $k ( sort keys %{$where} ) {
		next unless $k =~ /^[A-Za-z_][A-Za-z0-9_]*$/;
		my $v = $where->{$k};
		if (ref $v eq 'HASH' && defined $v->{'<'}) {
			push @clause, qq{cast("$k" as integer) < cast(? as integer)};
			push @bind, $v->{'<'};
		}
		elsif (defined $v) {
			push @clause, qq{"$k" = ?};
			push @bind, $v;
		}
		else {
			push @clause, qq{"$k" is null};
		}
	}
	my $res = &subs::db_query('update websockets set "type" = ?, "server_time" = ?, "warranty" = ? where '
		. join(' and ', @clause), @bind);
	return ($res && $res->rows) ? $res->rows : 0;
}

# The monthly cull for the retained sessions. It first retires a live row whose
# socket died without a finish (a day of silence is well past the heartbeat's
# cadence), then deletes the closed rows whose month is up. A row is deleted by
# itself, never by its tab: another live session for the same tab must survive.
sub websocket_sessions_cull {
	my ($now) = @_;
	$now ||= &subs::rightNow();
	&subs::websocket_retire({ room => undef, 'server_time' => { '<' => &subs::ago_calc('1d', $now) } }, now => $now);
	my $expired = eval {
		&subs::db_query(q{select uuid, browser_tab_id from websockets where coalesce("type", '') = ? and cast("warranty" as integer) < cast(? as integer)}, 'closed', $now)->hashes;
	} || [];
	my $gone = 0;
	foreach my $row ( @{$expired} ) {
		my $res = &subs::db_query(q{delete from websockets where "uuid" = ? and coalesce("type", '') = ?}, $row->{'uuid'}, 'closed');
		$gone += ($res && $res->rows) ? $res->rows : 0;
		my $tab = $row->{'browser_tab_id'};
		next unless defined $tab && length $tab;
		my $left = eval { &subs::db_query('select 1 from websockets where "browser_tab_id" = ? limit 1', $tab)->hashes } || [];
		eval { &subs::db_query('delete from drawings where browser_tab_id = ?', $tab) } unless @{$left};
	}
	return $gone;
}

# The house's device liveness, read from the month of retained sockets.
#
# A row is one socket, and a tab opens one per app, so a device's rows overlap
# and its span is the union of them, never the sum. The table has no
# device_uuid: the stable proxies a socket carries are its address and its user
# agent, so that pair is the key (the address alone merges every browser on a
# box, the agent alone merges every copy on a network). A row with neither falls
# back to its browser_tab_id - the tab session, the only identity left - so an
# anonymous session is never merged with another. hostname is the server's name,
# not the client's, and is not an identity at all. A device that changes network
# (phone Wi-Fi to cellular) looks like a new device, and two identical clients on
# one address look like one: the key is as good as the row's fields allow.
#
# A closed row's server_time is the moment websocket_retire closed it, so
# connected -> server_time is the session's real span; its timestamp (the last
# client beat) is earlier. A live row has no close moment, so its end is
# max(timestamp, server_time), the later reading of the last beat - client or
# house clock, whichever is ahead - and it keeps counting for a grace after that
# beat, because a socket seconds quiet is still up (the client beats every ten
# seconds and rebuilds after two missed). Without the close moment the row stays
# live until the cull retires it a day later; the grace is what keeps that stale
# tail out of `up`. `night` is undef when the retained rows cannot show one.
sub clothesline_device_liveness($now, %opt) {
	$now = &subs::rightNow() unless defined $now && $now =~ /^\s*\d+(?:\.\d+)?\s*$/;
	$now = int($now);
	my $limit = int($opt{'limit'} || 20000);
	my $grace = defined $opt{'grace_ms'} ? int($opt{'grace_ms'}) : 60_000;
	my $window = &subs::ago_calc('30d', $now);
	my $result = { devices => {}, down => [], up => 0, night => undef, now => $now };
	return $result unless $now > $window && $limit > 0;

	# Plain SQL: the retention window decides what is read, and the row cap keeps
	# a month of flapping tabs from turning this into a table scan's worth of
	# memory. The caller cannot name an app or a device here.
	my $rows = eval {
		&subs::db_query(
			q{select "connected", "timestamp", "server_time", "type", "browser_tab_id", "user_agent", "remote_address"
			  from websockets
			  where cast("connected" as integer) >= ?
			  order by cast("connected" as integer) desc
			  limit ?}, $window, $limit)->hashes;
	} || [];
	unless (@{$rows}) {
		# No sockets at all is the complement of no spans: the whole window is
		# down. A new house with nothing retained reads that way too, which is
		# honest - no device was seen - and the caller can say so.
		$result->{'down'} = [ [ $window, $now ] ];
		return $result;
	}

	my $num = sub {
		my ($value) = @_;
		return undef unless defined $value && $value =~ /^\s*\d+(?:\.\d+)?\s*$/;
		return int($value);
	};
	my $key_for = sub {
		my ($row) = @_;
		my $address = $row->{'remote_address'} // '';
		my $agent = $row->{'user_agent'} // '';
		$agent =~ s/\s+/ /g;
		$agent =~ s/^\s+|\s+$//g;
		return "$address|$agent" if length($address) || length($agent);
		my $tab = $row->{'browser_tab_id'} // '';
		return "tab|$tab" if length($tab);
		return 'unknown';
	};
	my $merge = sub {
		my ($spans) = @_;
		my @sorted = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @{$spans};
		my @out;
		foreach my $span ( @sorted ) {
			if (@out && $span->[0] <= $out[-1][1]) {
				$out[-1][1] = $span->[1] if $span->[1] > $out[-1][1];
				next;
			}
			push @out, [ $span->[0], $span->[1] ];
		}
		return \@out;
	};

	my (%dev, @all);
	foreach my $row ( @{$rows} ) {
		my $start = $num->($row->{'connected'});
		next unless defined $start && $start > 0;
		my $stamp = $num->($row->{'timestamp'});
		my $server = $num->($row->{'server_time'});
		my $closed = (($row->{'type'} // '') eq 'closed');
		my $end;
		if ($closed) {
			$end = defined $server ? $server : $stamp;
		}
		elsif (!defined $stamp) { $end = $server }
		elsif (!defined $server) { $end = $stamp }
		else { $end = $stamp > $server ? $stamp : $server }
		next unless defined $end;
		$end = $start if $end < $start;
		$end = $now if !$closed && $end < $now && ($now - $end) <= $grace;
		$end = $now if $end > $now;
		$start = $window if $start < $window;
		next if $end <= $start;
		my $key = $key_for->($row);
		push @{ $dev{$key}{'spans'} }, [ $start, $end ];
		$dev{$key}{'sessions'}++;
		$dev{$key}{'last_seen'} = $end if !defined $dev{$key}{'last_seen'} || $end > $dev{$key}{'last_seen'};
		push @all, [ $start, $end ];
	}
	unless (@all) {
		$result->{'down'} = [ [ $window, $now ] ];
		return $result;
	}

	my $span_ms = $now - $window;
	my %merged;
	foreach my $key ( sort keys %dev ) {
		my $spans = $merge->($dev{$key}{'spans'});
		my $ms = 0;
		$ms += $_->[1] - $_->[0] for @{$spans};
		$merged{$key} = $spans;
		$result->{'devices'}{$key} = {
			sessions   => $dev{$key}{'sessions'},
			span_ms    => $ms,
			coverage   => $span_ms > 0 ? $ms / $span_ms : 0,
			background => 0,
			last_seen  => $dev{$key}{'last_seen'},
		};
	}

	# Every device's spans unioned: anything not covered is a moment no socket
	# was open. That is what separates a house outage from a person asleep.
	my $union = $merge->(\@all);
	$result->{'up'} = (@{$union} && $union->[-1][1] >= $now) ? 1 : 0;
	my $cursor = $window;
	my @down;
	foreach my $span ( @{$union} ) {
		push @down, [ $cursor, $span->[0] ] if $span->[0] > $cursor;
		$cursor = $span->[1] if $span->[1] > $cursor;
	}
	push @down, [ $cursor, $now ] if $now > $cursor;
	$result->{'down'} = \@down;

	# A night is a house-clock fact, so the house zone is adopted for this pass
	# and put back at the end (the caller's numeric spans stay in ms).
	my $restore = &subs::clock_zone_adopt(&subs::clock_zone_house()) || sub { };
	my @segment;
	my $at = $window;
	while ($at < $now) {
		my @local = localtime(int($at / 1000));
		my $left = 3600 - (($local[1] || 0) * 60 + ($local[0] || 0));
		my $next = $at + $left * 1000;
		$next = $now if $next > $now || $next <= $at;
		push @segment, [ $at, $next, $local[2] || 0,
			sprintf('%04d-%02d-%02d', ($local[5] || 0) + 1900, ($local[4] || 0) + 1, $local[3] || 0) ];
		$at = $next;
	}

	my $since14 = &subs::ago_calc('14d', $now);
	my $first = $union->[0][0];
	my (%observed, %win, %win14, %on, %on14);
	my %cursor_at;
	foreach my $segment ( @segment ) {
		my ($from, $to, $hour, $day) = @{$segment};
		foreach my $key ( keys %merged ) {
			my $spans = $merged{$key};
			my $index = $cursor_at{$key} || 0;
			$index++ while $index < @{$spans} && $spans->[$index][1] <= $from;
			$cursor_at{$key} = $index;
			next unless $index < @{$spans} && $spans->[$index][0] < $to;
			my $low = $spans->[$index][0] > $from ? $spans->[$index][0] : $from;
			my $high = $spans->[$index][1] < $to ? $spans->[$index][1] : $to;
			next unless $high > $low;
			$on{$hour} += $high - $low;
			$observed{$day} = 1;
			my $low14 = $low > $since14 ? $low : $since14;
			$on14{$key}{$hour} += $high - $low14 if $high > $low14;
		}
	}
	foreach my $segment ( @segment ) {
		my ($from, $to, $hour, $day) = @{$segment};
		next unless $observed{$day} && $from >= $first;
		$win{$hour} += $to - $from;
		my $low14 = $from > $since14 ? $from : $since14;
		$win14{$hour} += $to - $low14 if $to > $low14;
	}

	# A quiet hour is one where fewer than half the known devices were
	# connected. A device that stays up all night is infrastructure, not company,
	# so it cannot by itself keep the night from being seen. Only days on which
	# the house was observed at all are counted: a fortnight before the first
	# socket is not fourteen quiet nights. The longest quiet run is the night.
	my $devices = scalar keys %merged;
	my @quiet;
	foreach my $hour ( 0 .. 23 ) {
		my $window_ms = $win{$hour} || 0;
		$quiet[$hour] = ($window_ms > 0 && ($on{$hour} || 0) <= 0.5 * $window_ms * $devices) ? 1 : 0;
	}
	my ($night_start, $night_len) = (undef, 0);
	if (grep { $_ } @quiet) {
		foreach my $hour ( 0 .. 23 ) {
			next unless $quiet[$hour];
			my $len = 0;
			$len++ while $len < 24 && $quiet[($hour + $len) % 24];
			if ($len > $night_len) { ($night_start, $night_len) = ($hour, $len) }
			last if $night_len == 24;
		}
	}
	if (defined $night_start && $night_len >= 3 && $night_len < 24) {
		$result->{'night'} = {
			start_hour => $night_start,
			end_hour   => ($night_start + $night_len) % 24,
		};
		my $total = 0;
		foreach my $hour ( 0 .. 23 ) {
			next unless (($hour - $night_start) % 24) < $night_len;
			$total += $win14{$hour} || 0;
		}
		foreach my $key ( keys %merged ) {
			my $up = 0;
			foreach my $hour ( 0 .. 23 ) {
				next unless (($hour - $night_start) % 24) < $night_len;
				$up += $on14{$key}{$hour} || 0;
			}
			# Infrastructure is up through most of the learned night (four
			# nights in five), not merely awake in the evening.
			$result->{'devices'}{$key}{'background'} = ($total > 0 && $up >= 0.8 * $total) ? 1 : 0;
		}
	}
	$restore->();
	return $result;
}

sub coding_repo { return &subs::home('~/jawnos'); }

1;
