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
	my $hostname = `hostname`;
	chomp($hostname);
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
	`shred -u $database`;
	`shred -u $database-shm`;
	`shred -u $database-wal`;
	`shred -u $logfile`;
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
	unless ($key eq 'mobile') {
		my $systemctl = `command -v systemctl 2>/dev/null`;
		my $loginctl = `command -v loginctl 2>/dev/null`;
		@actions = qw(restart shutdown sleep) if length $systemctl || length $loginctl;
	}
	$power_actions_cache{$key} = \@actions;
	return @actions;
}

# Run one of the menu's choices. The action is a fixed word from
# power_actions(), never the request body, and only a citizen session reaches
# the route. --no-block hands the job to systemd and returns, so the reply
# reaches the page before the machine goes down.
sub power_action($action) {
	$action = '' unless defined $action;
	my %allowed = map { $_ => 1 } &power_actions();
	return { ok => 0, error => 'unsupported' } unless $allowed{$action};
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
	my $rc = system(@cmd);
	# A desktop started outside the graphical session (a system unit, a
	# headless test) is not an active logind session, so polkit may refuse.
	# The live image grants passwordless sudo; -n never prompts and never hangs.
	if ($rc != 0) {
		my $sudo = `command -v sudo 2>/dev/null`;
		$rc = system('sudo', '-n', @cmd) if length $sudo;
	}
	&subs::say_it('power ' . $action . ($rc == 0 ? ' requested' : ' failed'));
	return $rc == 0 ? { ok => 1, action => $action } : { ok => 0, error => 'refused' };
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

sub coding_path($rel) {
	$rel = '' unless defined $rel;
	$rel =~ s{^\./+}{};
	$rel =~ s{^/+}{};
	return undef if $rel =~ /(^|\/)\.\.(\/|$)/;
	return undef if $rel =~ /[\x00-\x1f"`\\]/;
	return undef if $rel =~ m{^(?:\.git|\.secrets|\.president|releases|voices)(?:/|$)};
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

sub coding_repo { return &subs::home('~/jawnos'); }

1;
