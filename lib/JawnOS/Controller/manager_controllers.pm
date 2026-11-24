package Manager;

# manager_controllers: the house's controller roster and the two halves of the
# join (ask from the device, approve at the desk). Pairing rides the existing
# device_requests/paired_devices machinery; no new table is added.
use strict;
use warnings;
use utf8;

use Cwd ();
use File::Path ();
use File::Temp ();
use Mojo::JSON qw(decode_json encode_json);
use POSIX ();

no warnings 'uninitialized';

our $log;

# GET /manager/controllers
sub action_54001 {
	my $c = shift;
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $content = $c->render_to_string(
		template => 'controllers/controllers',
		timestamp => $timestamp,
		config => &subs::config_reader(),
	);
	# The window belongs to Controllers (plural), the roster this route serves. The
	# handheld's own /manager/controller launcher is a different app, and a window
	# saved under its name would restore the wrong page after a reload.
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'controllers', title => &subs::ui('Controllers'), contents => $content }, $timestamp);
	$c->render(text => $contents);
}

# GET /manager/controllers/list
sub action_54002 {
	my $c = shift;
	&app_schema_ensure();
	my $rows = &subs::db_select('paired_devices', undef, { kind => 'controller', status => 'active' })->hashes;
	my $controllers = [];
	foreach my $device ( @{$rows || []} ) {
		# A paired key and a roster row name the same machine two ways: the
		# device may have been introduced by its signatorial, or by the uuid
		# the house minted. Try the one it carries, then either half.
		my $key = $device->{'signatorial'} || $device->{'uuid'};
		my $machine = ($key && &subs::db_select('remote_machines', undef, { uuid => $key })->hash)
			|| ($key && &subs::db_select('remote_machines', undef, { signatorial => $key })->hash)
			|| {};
		my $pending = &subs::db_select('device_requests', undef, { device_uuid => $device->{'uuid'}, kind => 'controller', status => 'pending' })->hash;
		push @{$controllers}, {
			uuid => $device->{'uuid'},
			name => $device->{'name'} || '',
			kind => $device->{'kind'} || 'controller',
			hostname => $machine->{'hostname'} || '',
			ip => $machine->{'ip'} || '',
			last_seen => $device->{'last_seen'} || $machine->{'server_time'} || '',
			pending => ($pending ? 1 : 0),
		};
	}
	$c->render(json => { ok => 1, controllers => $controllers, computer => (&_controller_is_computer() ? 1 : 0) });
}

# POST /manager/controllers/request
sub action_54003 {
	my $c = shift;
	&app_schema_ensure();
	my $now = &subs::rightNow();
	my $uuid = &subs::random_string_creator(25);
	my $code = &subs::device_request_code();
	my $name = substr($c->param('name') || 'Controller', 0, 60);
	my $agent = substr($c->req->headers->user_agent // '', 0, 400);
	&subs::db_insert('device_requests', {
		uuid => $uuid,
		kind => 'controller',
		name => $name,
		code => $code,
		status => 'pending',
		agent => $agent,
		remote_address => $c->tx->remote_address,
		timestamp => $now,
		server_time => $now,
	});
	$log->info('controller request: ' . $name . ' code ' . $code);
	$c->render(json => { ok => 1, uuid => $uuid, code => $code });
}

# POST /manager/controllers/approve
sub action_54004 {
	my $c = shift;
	&app_schema_ensure();
	my $uuid = $c->param('uuid') || '';
	my $code = $c->param('code') || '';
	my $request = ($uuid && &subs::db_select('device_requests', undef, { uuid => $uuid, kind => 'controller', status => 'pending' })->hash)
		|| ($code && &subs::db_select('device_requests', undef, { code => $code, kind => 'controller', status => 'pending' })->hash)
		|| undef;
	return $c->render(json => { ok => 0, error => 'no request' }) unless $request;
	unless (($c->session('authentication') || '') eq 'approved' && &subs::privilege_is_house($c->session('privilege'))) {
		return $c->render(json => { ok => 0, error => 'not allowed' });
	}
	my $now = &subs::rightNow();
	my $name = $request->{'name'} || 'Controller';
	my $device_uuid = $request->{'device_uuid'} || &subs::random_string_creator(25);
	my $existing = &subs::db_select('paired_devices', undef, { uuid => $device_uuid })->hash;
	my $data = {
		name => $name,
		kind => 'controller',
		status => 'active',
		pubkey => $request->{'pubkey'} || '',
		privilege => $request->{'privilege'} || 'resident',
		person_uuid => $c->session('person_uuid'),
		agent => $request->{'agent'} || '',
		server_time => $now,
	};
	if ($existing) {
		&subs::db_update('paired_devices', $data, { uuid => $device_uuid });
	}
	else {
		$data->{'uuid'} = $device_uuid;
		$data->{'timestamp'} = $now;
		&subs::db_insert('paired_devices', $data);
	}
	&subs::db_update('device_requests', { status => 'approved', device_uuid => $device_uuid, server_time => $now }, { uuid => $request->{'uuid'} });
	$log->info('controller approved: ' . $name . ' uuid ' . $device_uuid);
	$c->render(json => { ok => 1, uuid => $device_uuid, name => $name });
}

# ---------------------------------------------------------------------------
# Storage and ROMs (54005-54008). Storage lives on the controller's
# remote_machines row: archive_dir is the SD mount and archive is the flag the
# archive readers already consult. A blank archive_dir already means "not an
# archive" and a missing directory already disables merging (Domain/Archive.pm),
# so these actions only read and write the two columns and never re-decide it.

# The eight folders the storage card shows, and makes when this machine holds
# the drive. ROMs are the shelf under the one called Games.
sub _controller_folders {
	return qw/Documents Downloads Recordings Games Scans Pictures Videos Music Backups/;
}

sub _controller_rom_folder { return 'Games' }

# What a person typed into the archive_dir field. A blank stays blank: it is
# how the house says this controller is not an archive. Trailing slashes are
# dropped so "$dir/$name" is a path rather than a doubled slash.
sub _controller_archive_dir {
	my $dir = shift;
	$dir = '' unless defined $dir;
	$dir =~ s/^\s+|\s+$//g;
	$dir =~ s{/+$}{} unless $dir eq '/';
	return $dir;
}

# The write gate the approve action uses.
sub _controller_house_pass {
	my $c = shift;
	return (($c->session('authentication') || '') eq 'approved' && &subs::privilege_is_house($c->session('privilege'))) ? 1 : 0;
}

# This machine's device class is the tree's own answer (Domain/Say.pm
# device_setter): a desktop is 'computer', while a phone, a server or the
# handheld itself is not. The New button flashes a handheld over USB from the
# desktop that has the drive, so it is offered only here.
sub _controller_is_computer {
	return ((&subs::device_setter() // '') eq 'computer') ? 1 : 0;
}

# Run scripts/gou_provision.pl from an argv list, never a shell string. --scan
# only reads sysfs and runs as the manager; --flash writes a raw device and
# mounts its second partition, so it goes through sudo -n. The helper prints
# its answer as JSON on stdout and its progress on stderr, which stays in the
# worker log. 900s is the ceiling the flash warranty allows. $stdin is the
# WiFi password: a secret goes over the pipe, never onto the argv that `ps`
# shows to every user on the box.
sub _controller_gou_run {
	my ($as_root, $stdin, @args) = @_;
	my $script = Cwd::abs_path('scripts/gou_provision.pl');
	unless (defined $script && length $script && -f $script) {
		return { ok => 0, error => 'the Controller provisioner is missing' };
	}
	my @command = $as_root
		? ('sudo', '-n', $^X, $script, @args)
		: ($^X, $script, @args);
	my %params = (
		name => 'gou provision',
		stdout => 'capture',
		stderr => 'inherit',
		warranty => '900s',
	);
	$params{'stdin'} = $stdin if defined $stdin;
	my $run = eval {
		&subs::subprocessor_command(\@command, \%params);
	};
	unless (ref $run eq 'HASH' && $run->{'pid'}) {
		return { ok => 0, error => 'the provisioner could not start' };
	}
	my $answer = eval { decode_json($run->{'output'} // '') };
	return $answer if ref $answer eq 'HASH';
	my $error = $run->{'timed_out'}
		? 'the provisioner timed out'
		: 'the provisioner did not answer';
	return { ok => 0, error => $error };
}

# A roster row and its machine row. The roster names a machine by its
# signatorial or by the uuid the house minted, so the machine is looked up by
# the one the row carries, then by either half - the same link action_54002
# makes. `uuid => local` is the page's name for the machine holding the drive:
# remote_machines does not otherwise carry this machine, so its row is filed
# under this machine's signatorial. Returns (device, machine, key), where key
# is what a machine row this controller does not yet have would be filed under.
sub _controller_resolve {
	my $uuid = shift;
	$uuid = '' unless defined $uuid;
	my $device = ($uuid ne '' && $uuid ne 'local')
		? &subs::db_select('paired_devices', undef, { uuid => $uuid, kind => 'controller' })->hash
		: undef;
	my $key = ($device && $device->{'signatorial'}) || $uuid;
	$key = &subs::signatorial_designer() if ($key eq '' || $key eq 'local');
	$key = '' unless defined $key;
	my $machine = {};
	if ($key ne '') {
		$machine = &subs::db_select('remote_machines', undef, { uuid => $key })->hash
			|| &subs::db_select('remote_machines', undef, { signatorial => $key })->hash
			|| {};
	}
	return ($device, $machine, $key);
}

# "This controller is this machine" is decided by the controller's signatorial
# against this machine's - the identity the archive code uses for the drive -
# and `uuid => local` is accepted without a row. A peer is never probed: its
# paths are not mounted here.
sub _controller_is_this {
	my ($uuid, $device, $machine) = @_;
	return 1 if (defined $uuid && $uuid eq 'local');
	my $mine = &subs::signatorial_designer();
	return 0 unless defined $mine && length $mine;
	my $theirs = ($machine && $machine->{'signatorial'}) || ($device && $device->{'signatorial'}) || '';
	return ($theirs eq $mine) ? 1 : 0;
}

# The root a game folder sits under: this machine's own shelf, or the Games
# folder on the controller's drive. An empty string means there is no such
# root to read.
sub _controller_rom_root {
	my ($where, $machine) = @_;
	return &subs::home('~/roms') unless ($where // '') eq 'sd';
	my $root = &_controller_archive_dir($machine ? $machine->{'archive_dir'} : '');
	return '' unless length $root;
	return $root . '/' . &_controller_rom_folder();
}

# How many files one game folder holds, dotfiles skipped. The shelf needs a
# size to compare games by, and a walk is cheap next to a du.
sub _controller_rom_files {
	my $dir = shift;
	my $count = 0;
	my @queue = ($dir);
	while (defined(my $current = shift @queue)) {
		opendir(my $dh, $current) or next;
		foreach my $entry (readdir $dh) {
			next if $entry eq '.' || $entry eq '..' || $entry =~ /^\./;
			my $path = $current . '/' . $entry;
			if (-d $path && !-l $path) { push @queue, $path; }
			elsif (-f $path) { $count++; }
		}
		closedir $dh;
	}
	return $count;
}

# GET /manager/controllers/storage
sub action_54005 {
	my $c = shift;
	&app_schema_ensure();
	my $uuid = $c->param('uuid') || '';
	my ($device, $machine, $key) = &_controller_resolve($uuid);
	unless ($device || $uuid eq 'local') {
		return $c->render(json => { ok => 0, error => 'no controller' });
	}
	my $dir = &_controller_archive_dir($machine->{'archive_dir'});
	my $is_this = &_controller_is_this($uuid, $device, $machine);
	# A folder says whether it is there when this machine holds the drive: the
	# walkthrough steps on that answer, and a grid that called every folder present
	# because the card was mounted was telling the person nothing. A peer's mount is
	# not ours to stat, so its folders carry no answer at all.
	my $readable = ($is_this && length $dir) ? 1 : 0;
	my $folders = [ map { {
		name => $_,
		path => $dir . '/' . $_,
		($readable ? (present => (-d ($dir . '/' . $_)) ? 1 : 0) : ()),
	} } &_controller_folders() ];
	my $quota = $machine->{'backup_quota'};
	$quota = 10 unless defined $quota && $quota =~ /^\d{1,3}$/ && $quota <= 100;
	$c->render(json => {
		ok => 1,
		uuid => $uuid,
		archive_dir => $dir,
		archive => (($machine->{'archive'} // '') eq '1' ? 1 : 0),
		backup_quota => $quota + 0,
		backup_dir => (length $dir ? $dir . '/Backups' : ''),
		folders => $folders,
		present => (($is_this && length $dir && -d $dir) ? 1 : 0),
		card => &_controller_card_finding($device, $machine, $key),
	});
}

# What the controller's own first boot saw in its card slot, and the answer it
# is waiting for. The board writes the finding as a per-machine settings row
# under its signatorial (see scripts/gou_first_boot.pl); the row syncs, so this
# page can show it without the card being anywhere near this computer.
sub _controller_card_finding {
	my ($device, $machine, $key) = @_;
	my $sig = ($device && $device->{'signatorial'}) || ($machine && $machine->{'signatorial'}) || $key || '';
	return undef unless length $sig;
	my $row = &subs::db_select('settings', undef, { app => '__president', setting => 'card_finding', device => $sig })->hash;
	my $finding = eval { decode_json($row->{'value'} // '') } || {};
	return undef unless ref $finding eq 'HASH' && length($finding->{'state'} || '');
	my $choice = &subs::db_select('settings', undef, { app => '__president', setting => 'card_choice', device => $sig })->hash;
	$finding->{'choice'} = $choice ? ($choice->{'value'} // '') : '';
	return $finding;
}

# POST /manager/controllers/card
# The person's answer to that finding: adopt the card as it stands, or format
# it. The answer is written as the same kind of per-machine setting, and the
# board applies it the next time it starts. A card that already holds an
# archive is never formatted: the answer would throw the house's files away.
sub action_54011 {
	my $c = shift;
	&app_schema_ensure();
	unless (&_controller_house_pass($c)) {
		return $c->render(json => { ok => 0, error => 'not allowed' });
	}
	my $choice = $c->param('choice') // '';
	$choice = '' unless $choice eq 'adopt' || $choice eq 'format';
	return $c->render(json => { ok => 0, error => 'choose adopt or format' }) unless length $choice;
	my $uuid = $c->param('uuid') || '';
	my ($device, $machine, $key) = &_controller_resolve($uuid);
	unless ($device || $uuid eq 'local') {
		return $c->render(json => { ok => 0, error => 'no controller' });
	}
	my $finding = &_controller_card_finding($device, $machine, $key);
	my $state = ($finding && length($finding->{'state'} || '')) ? $finding->{'state'} : '';
	return $c->render(json => { ok => 0, error => 'this controller has not reported a card' }) unless length $state;
	return $c->render(json => { ok => 0, error => 'that card already holds the archive' })
		if $choice eq 'format' && $state eq 'archive';
	return $c->render(json => { ok => 0, error => 'a card with no filesystem can only be formatted' })
		if $choice eq 'adopt' && $state eq 'blank';
	my $sig = ($device && $device->{'signatorial'}) || ($machine && $machine->{'signatorial'}) || $key || '';
	my $now = &subs::rightNow();
	my $row = &subs::db_select('settings', undef, { app => '__president', setting => 'card_choice', device => $sig })->hash;
	if ($row) {
		&subs::db_update('settings', { value => $choice, server_time => $now }, { uuid => $row->{'uuid'} });
	}
	else {
		&subs::db_insert('settings', {
			uuid => &subs::random_string_creator(25),
			app => '__president',
			setting => 'card_choice',
			device => $sig,
			value => $choice,
			timestamp => $now,
			server_time => $now,
		});
	}
	$log->info('controller card: ' . (($device && $device->{'name'}) || $uuid) . ' choice ' . $choice);
	$c->render(json => { ok => 1, uuid => $uuid, choice => $choice });
}

# POST /manager/controllers/storage
sub action_54006 {
	my $c = shift;
	&app_schema_ensure();
	unless (&_controller_house_pass($c)) {
		return $c->render(json => { ok => 0, error => 'not allowed' });
	}
	my $uuid = $c->param('uuid') || '';
	my ($device, $machine, $key) = &_controller_resolve($uuid);
	unless ($device || $uuid eq 'local') {
		return $c->render(json => { ok => 0, error => 'no controller' });
	}
	# A blank archive_dir is meaningful, not missing: it says this controller is
	# not an archive, and every reader already honours that.
	my $dir = &_controller_archive_dir($c->param('archive_dir'));
	my $archive = ($c->param('archive') // '') eq '1' ? '1' : '0';
	my $quota = $c->param('backup_quota');
	$quota = 10 unless defined $quota && $quota =~ /^\d{1,3}$/ && $quota <= 100;
	# An install that has not run the migration yet keeps the old two-column
	# write; the next boot adds backup_quota and this starts persisting it.
	my $has_quota = eval { &subs::db_query('select 1 from pragma_table_info(?) where name = ?', 'remote_machines', 'backup_quota')->hashes->[0] ? 1 : 0 } || 0;
	my $now = &subs::rightNow();
	if (keys %{$machine}) {
		my $where = $machine->{'uuid'} ? { uuid => $machine->{'uuid'} } : { signatorial => $machine->{'signatorial'} };
		my $set = { archive_dir => $dir, archive => $archive, server_time => $now };
		$set->{'backup_quota'} = $quota if $has_quota;
		&subs::db_update('remote_machines', $set, $where);
	}
	else {
		# The roster row is the controller the house paired; the machine row is
		# the one that carries a drive, and this is where it first appears.
		my $signatorial = ($device && $device->{'signatorial'}) || ($uuid eq 'local' ? $key : '');
		my $row = {
			uuid => $key,
			signatorial => $signatorial,
			hostname => ($device && $device->{'name'}) || '',
			archive_dir => $dir,
			archive => $archive,
			timestamp => $now,
			server_time => $now,
		};
		$row->{'backup_quota'} = $quota if $has_quota;
		&subs::db_insert('remote_machines', $row);
	}
	my @created;
	my $is_this = &_controller_is_this($uuid, $device, $machine);
	# Only the machine holding the drive makes folders. A peer's mount is not
	# ours to touch and is not probed, so a remote save changes the row only.
	if ($is_this && length $dir && -d $dir) {
		foreach my $name (&_controller_folders()) {
			my $path = $dir . '/' . $name;
			next if -d $path;
			push @created, $name if mkdir $path;
		}
	}
	$log->info('controller storage: ' . (($device && $device->{'name'}) || $uuid) . ' archive_dir ' . $dir . ' archive ' . $archive . ' backup_quota ' . $quota);
	$c->render(json => {
		ok => 1,
		uuid => $uuid,
		archive_dir => $dir,
		archive => ($archive eq '1' ? 1 : 0),
		backup_quota => $quota + 0,
		created => \@created,
		present => (($is_this && length $dir && -d $dir) ? 1 : 0),
	});
}

# GET /manager/controllers/roms
sub action_54007 {
	my $c = shift;
	&app_schema_ensure();
	my $uuid = $c->param('uuid') || '';
	my $where = ($c->param('where') // '') eq 'sd' ? 'sd' : 'emmc';
	my ($device, $machine) = &_controller_resolve($uuid);
	unless ($device || $uuid eq 'local') {
		return $c->render(json => { ok => 0, error => 'no controller' });
	}
	# A peer's shelf is not mounted here, so say so instead of drawing an empty
	# list that would read as "no games".
	unless (&_controller_is_this($uuid, $device, $machine)) {
		return $c->render(json => { ok => 0, error => 'remote not wired yet' });
	}
	my $dir = &_controller_rom_root($where, $machine);
	unless (length $dir) {
		return $c->render(json => { ok => 0, error => 'no archive_dir' });
	}
	my @items;
	if (opendir my $dh, $dir) {
		foreach my $name (sort grep { $_ !~ /^\./ } readdir $dh) {
			my $path = $dir . '/' . $name;
			next unless -d $path;
			push @items, { name => $name, size => &_controller_rom_files($path), game => $name };
		}
		closedir $dh;
	}
	$c->render(json => { ok => 1, where => $where, dir => $dir, items => \@items });
}

# POST /manager/controllers/roms/copy
sub action_54008 {
	my $c = shift;
	&app_schema_ensure();
	unless (&_controller_house_pass($c)) {
		return $c->render(json => { ok => 0, error => 'not allowed' });
	}
	my $uuid = $c->param('uuid') || '';
	my $name = $c->param('name') || '';
	my $from = $c->param('from') || '';
	my $to = $c->param('to') || '';
	my $move = (($c->param('move') // '') eq '1') ? 1 : 0;
	my ($device, $machine) = &_controller_resolve($uuid);
	unless ($device || $uuid eq 'local') {
		return $c->render(json => { ok => 0, error => 'no controller' });
	}
	unless (&_controller_is_this($uuid, $device, $machine)) {
		return $c->render(json => { ok => 0, error => 'remote not wired yet' });
	}
	# The name is one entry under a root this action chose, never a path.
	unless (length $name && $name !~ m{/} && $name !~ /\.\./ && $name !~ /^\./) {
		return $c->render(json => { ok => 0, error => 'bad name' });
	}
	unless ($from =~ /^(?:emmc|sd)$/ && $to =~ /^(?:emmc|sd)$/) {
		return $c->render(json => { ok => 0, error => 'bad location' });
	}
	my $source_dir = &_controller_rom_root($from, $machine);
	my $dest_dir = &_controller_rom_root($to, $machine);
	unless (length $source_dir && length $dest_dir) {
		return $c->render(json => { ok => 0, error => 'no archive_dir' });
	}
	# A drive that is not mounted is never invented: the folders on it are made
	# only when the mount is there, which is the same rule the storage save uses.
	if ($to eq 'sd' && !-d &_controller_archive_dir($machine->{'archive_dir'})) {
		return $c->render(json => { ok => 0, error => 'no archive_dir' });
	}
	my $source = $source_dir . '/' . $name;
	my $is_file = (-f $source) ? 1 : 0;
	unless ($is_file || -d $source) {
		return $c->render(json => { ok => 0, error => 'missing' });
	}
	# A ROM sold as one file is still one game folder on the shelf: the folder
	# is the name without its extension and the file goes inside.
	my $game = $name;
	my $wrapped = 0;
	if ($is_file) {
		$game =~ s/\.[^.]*$//;
		$game = $name unless length $game;
		$wrapped = 1;
	}
	my $dest = $dest_dir . '/' . $game;
	if (-e $dest) {
		return $c->render(json => { ok => 0, error => 'exists' });
	}
	Mojo::File->new($dest_dir)->make_path unless -d $dest_dir;
	my $copied;
	if ($is_file) {
		my $target = $dest . '/' . $name;
		$copied = ((mkdir($dest) && system('cp', '-a', '--', $source, $target) == 0 && -f $target) ? 1 : 0);
	}
	else {
		$copied = ((system('cp', '-a', '--', $source, $dest) == 0 && -d $dest) ? 1 : 0);
	}
	unless ($copied) {
		# A refused copy can leave a partial directory behind, and a retry would
		# then answer 'exists' with no way through.
		system('rm', '-rf', '--', $dest);
		$log->info('controller roms copy failed: ' . $name . ' ' . $from . ' -> ' . $to);
		return $c->render(json => { ok => 0, error => 'copy failed' });
	}
	my $moved = 0;
	if ($move) {
		$moved = $is_file
			? (unlink($source) ? 1 : 0)
			: ((system('rm', '-rf', '--', $source) == 0) ? 1 : 0);
	}
	$log->info('controller roms ' . ($move ? 'move' : 'copy') . ': ' . $name . ' ' . $from . ' -> ' . $to . ($wrapped ? ' (wrapped)' : ''));
	$c->render(json => {
		ok => 1,
		name => $name,
		game => $game,
		from => $from,
		to => $to,
		wrapped => $wrapped,
		move => $move,
		moved => $moved,
	});
}

# ---------------------------------------------------------------------------
# The Controllers app's New button (54009-54010). The provisioner lives in
# scripts/gou_provision.pl and owns the device fingerprint: these actions only
# decide who may ask and pass the person's choices through as an argv list.

# A token the board can spend on its first boot, and nothing the house keeps in
# the clear. The secret is written to the machine-local cache (cache is never
# exported, so it does not sync to peers) and the file itself goes into the
# flashed rootfs; the boot script deletes it once it has been redeemed. A token
# costs one citizen press to mint, is single use, and expires in a day.
sub _controller_join_token {
	my ($c, $name, $hostname, $card) = @_;
	my $secret = &subs::random_string_creator(40);
	my $now = &subs::rightNow();
	my $manager = &subs::house_manager_address(eval { $c->req->url->to_abs->to_string } || '');
	my $token = {
		kind => 'jawnos-controller-join',
		v => 1,
		secret => $secret,
		name => $name,
		hostname => $hostname,
		# What the person chose for the card before the flash: the card is in the
		# board, so the answer travels here and the first boot applies it.
		card => ($card =~ /^(adopt|format)$/ ? $card : ''),
		house => {
			manager => $manager,
			signatorial => &subs::signatorial_designer() || '',
			pubkey => &subs::peer_pubkey() || '',
			name => &subs::machine_name() || '',
		},
		expires => $now + 86_400_000,
	};
	&subs::db_query('delete from cache where context = ? and server_time < ?', 'controller_join', $now - 7 * 86_400_000);
	&subs::db_insert('cache', {
		uuid => &subs::random_string_creator(18),
		context => 'controller_join',
		subcontext => $secret,
		app => '__president',
		data => encode_json({ name => $name, hostname => $hostname, created => $now }),
		timestamp => $now,
		server_time => $now,
	});
	my $dir = &subs::home('~/.president');
	eval { File::Path::make_path($dir) } unless -d $dir;
	$dir = File::Temp::tempdir('jawnos-join-XXXXXX', TMPDIR => 1, CLEANUP => 1) unless -d $dir;
	# A flash interrupted before the action could hand its file over leaves a
	# token with a live secret on disk; anything a day old is spent by then.
	foreach my $old (glob("$dir/controller_join_*.json")) {
		next unless -f $old;
		my $age = time - ((stat($old))[9] // 0);
		unlink $old if $age > 86_400;
	}
	# File::Temp wants the X's at the end of the template; a suffix after them
	# made every flash die here and the page showed only "The board was not
	# flashed." (2026-11-15), because the token is minted before the
	# provisioner runs. SUFFIX keeps the .json the cleanup glob looks for.
	my ($fh, $path) = File::Temp::tempfile('controller_join_XXXXXXXX', DIR => $dir, SUFFIX => '.json', UNLINK => 0);
	return { error => 'the join token could not be written' } unless $fh && $path;
	print {$fh} encode_json($token);
	close $fh;
	chmod 0600, $path;
	return { path => $path, secret => $secret };
}

# A flash that never wrote the board leaves a token nothing will ever redeem:
# spend it here rather than leave a way in for a day.
sub _controller_join_forget {
	my ($secret) = @_;
	return unless defined $secret && length $secret;
	&subs::db_delete('cache', { context => 'controller_join', subcontext => $secret });
}

# ---------------------------------------------------------------------------
# A flash job
#
# A flash writes a raw device for five to ten minutes, so it is not tied to one
# request, one worker or one panel lifetime: the provisioner runs in its own
# session and writes a progress file, and the page polls a status route. A
# restart therefore neither kills the write nor loses the count - the next poll
# (or a reopened Controllers window) reads the same file. Cancel signals the
# session's process group, which is the sudo wrapper and the zstd/dd under it.

sub _flash_now_ms { return int(time() * 1000) }

sub _flash_job_path {
	my $given = $ENV{'JAWNOS_FLASH_JOB'} // '';
	return $given if length $given;
	return &subs::home('~/.president') . '/gou_flash.json';
}

sub _flash_job_read {
	my ($path) = @_;
	$path = _flash_job_path() unless defined $path && length $path;
	return {} unless -f $path;
	my $raw = '';
	if (open(my $fh, '<', $path)) { local $/; $raw = <$fh> // ''; close $fh }
	my $job = eval { decode_json($raw) };
	return ref $job eq 'HASH' ? $job : {};
}

sub _flash_job_write {
	my ($job, $path) = @_;
	return 0 unless ref $job eq 'HASH';
	$path = _flash_job_path() unless defined $path && length $path;
	my $dir = $path;
	$dir =~ s{/[^/]+$}{};
	eval { File::Path::make_path($dir) } if length $dir && !-d $dir;
	my $tmp = $path . '.' . $$ . '.tmp';
	return 0 unless open(my $fh, '>', $tmp);
	print {$fh} encode_json($job);
	close $fh;
	return rename($tmp, $path) ? 1 : 0;
}

sub _flash_job_active {
	my ($state) = @_;
	$state = '' unless defined $state;
	return $state =~ /^(?:starting|checking|writing|verifying|preparing)$/ ? 1 : 0;
}

# The pid is the flash's session leader. Its start time is what tells "still my
# flash" from a recycled number, so a cancel never signals a stranger.
sub _flash_job_alive {
	my ($job) = @_;
	my $pid = (ref $job eq 'HASH' && $job->{'pid'}) ? $job->{'pid'} : '';
	return 0 unless defined $pid && $pid =~ /^\d+$/ && $pid > 1;
	require JawnOS::Platform::Process;
	return JawnOS::Platform::Process::same_process($pid, $job->{'start_ticks'} // '') ? 1 : 0;
}

# What the page draws: the same record plus the two numbers it would otherwise
# have to derive. A total of zero means the image's size is not known yet, so no
# percentage is invented.
sub _flash_job_view {
	my ($job) = @_;
	my %view = %{ ref $job eq 'HASH' ? $job : {} };
	delete $view{'token_path'};
	my $bytes = $view{'bytes'} // 0;
	my $total = $view{'total'} // 0;
	my $state = defined $view{'state'} ? $view{'state'} : '';
	# The flash is two passes over the same bytes: the write, then the read-back
	# that proves it. A bar counting only the write reaches 100% at the halfway
	# point and then has nothing to show for the length of the check, so the
	# percentage and the time left are both measured across the two passes.
	my $verifying = $state eq 'verifying' ? 1 : 0;
	my $span = $total > 0 ? ($verifying ? $total * 2 : $total) : 0;
	my $done = $verifying ? $total + $bytes : $bytes;
	$view{'percent'} = $span > 0 ? int($done * 100 / $span) : undef;
	$view{'percent'} = 100 if defined $view{'percent'} && $view{'percent'} > 100;
	$view{'phase'} = $verifying ? 'verifying' : $state;
	my $started = $view{'started_ms'} // 0;
	my $updated = $view{'updated_ms'} // 0;
	$view{'elapsed'} = ($started && $updated > $started) ? ($updated - $started) / 1000 : 0;
	$view{'rate'} = 0 unless defined $view{'rate'};
	# The rate is the phase's own: the read-back is faster than the write, so a
	# figure carried over from the write would promise the wrong wait.
	$view{'remaining'} = ($view{'rate'} > 0 && $span > $done)
		? int(($span - $done) / $view{'rate'}) : undef;
	$view{'ok'} = 1;
	return \%view;
}

# A finished job's token is settled exactly once. A done flash keeps the cache
# row (the board redeems it on its first boot) and drops the host's copy of the
# file; a failed or cancelled flash also spends the row, so a token nothing will
# redeem does not sit there for a day.
sub _flash_job_cleanup {
	my ($job) = @_;
	return unless ref $job eq 'HASH' && ($job->{'state'} // '') =~ /^(?:done|failed|cancelled)$/;
	return if $job->{'cleaned'};
	my $token = $job->{'token_path'} // '';
	my $secret = '';
	if (length $token && -f $token) {
		my $raw = '';
		if (open(my $fh, '<', $token)) { local $/; $raw = <$fh> // ''; close $fh }
		my $parsed = eval { decode_json($raw) } || {};
		$secret = $parsed->{'secret'} // '';
		unlink $token;
	}
	&_controller_join_forget($secret) if $job->{'state'} ne 'done' && length $secret;
	_flash_job_write({ %{ $job }, cleaned => 1 });
}

# POST /manager/controllers/new/scan
sub action_54009 {
	my $c = shift;
	unless (&_controller_house_pass($c)) {
		return $c->render(json => { ok => 0, error => 'not allowed' });
	}
	unless (&_controller_is_computer()) {
		return $c->render(json => { ok => 0, error => 'not a computer' });
	}
	$c->render(json => &_controller_gou_run(0, undef, '--scan'));
}

# POST /manager/controllers/new/flash
sub action_54010 {
	my $c = shift;
	unless (&_controller_house_pass($c)) {
		return $c->render(json => { ok => 0, error => 'not allowed' });
	}
	unless (&_controller_is_computer()) {
		return $c->render(json => { ok => 0, error => 'not a computer' });
	}
	$c->inactivity_timeout(900);
	my @args = ('--flash');
	my $image = $c->param('image');
	push @args, ('--image', substr($image, 0, 400)) if defined $image && length $image;
	# The board joins this house's Wi-Fi, and the house already knows it: the
	# Network app reads the connection the manager is on. Nothing is typed here,
	# and the key stays on the server - only the provisioner's stdin sees it.
	# A manager that is not on Wi-Fi (or a key it cannot read) flashes the board
	# with no network; the board's USB gadget still answers, and its Network app
	# can join one later.
	my $network = eval { &network_helper(['wifi_current']) };
	my ($wifi_ssid, $wifi_psk) = ('', '');
	if (ref $network eq 'HASH' && $network->{'ok'}) {
		my $candidate = $network->{'ssid'} // '';
		my $key = $network->{'passphrase'} // '';
		if (length $candidate && length($candidate) <= 32 && $candidate !~ /[\x00-\x1f\x7f]/
			&& ($key =~ /^[\x20-\x7e]{8,63}$/ || $key =~ /^[0-9A-Fa-f]{64}$/)) {
			($wifi_ssid, $wifi_psk) = ($candidate, $key);
		}
	}
	push @args, ('--wifi-ssid', $wifi_ssid) if length $wifi_ssid;
	# The password is handed over on the child's stdin: sudo keeps the argv
	# visible in `ps` to every user on the machine, and a secret does not belong
	# there.
	if (length $wifi_ssid) {
		push @args, '--wifi-psk-stdin';
	}
	my $hostname = $c->param('hostname');
	push @args, ('--hostname', substr($hostname, 0, 63)) if defined $hostname && length $hostname;
	# The token is the board's way into the house on its first boot; the
	# provisioner copies it into the flashed rootfs beside the WiFi profile. It
	# also carries what to do with the card, which is in the board and cannot be
	# looked at from here.
	my $card = $c->param('card') // '';
	$card = '' unless $card eq 'adopt' || $card eq 'format';
	my $token = &_controller_join_token($c, (defined $hostname && length $hostname ? $hostname : 'Controller'), (defined $hostname && length $hostname ? $hostname : 'gou'), $card);
	push @args, ('--join-token', $token->{'path'}) if $token->{'path'};
	my $job_path = _flash_job_path();
	my $running = _flash_job_read($job_path);
	if (_flash_job_active($running->{'state'}) && (_flash_job_alive($running)
		|| (!$running->{'pid'} && defined $running->{'started_ms'} && (_flash_now_ms() - $running->{'started_ms'}) < 5000))) {
		unlink $token->{'path'} if $token->{'path'};
		&_controller_join_forget($token->{'secret'}) if $token->{'secret'};
		# A second press - a double tap, or a press from a panel that reopened
		# mid-write - joins the flash that is already writing instead of replacing
		# a live bar with an error. The token it just minted is dropped above, so
		# one flash still has one token.
		return $c->render(json => { ok => 1, resumed => 1, job => &_flash_job_view($running) });
	}
	my $script = Cwd::abs_path('scripts/gou_provision.pl');
	unless (defined $script && length $script && -f $script) {
		unlink $token->{'path'} if $token->{'path'};
		&_controller_join_forget($token->{'secret'}) if $token->{'secret'};
		return $c->render(json => { ok => 0, error => 'the Controller provisioner is missing' });
	}
	push @args, ('--progress', $job_path);
	# The password rides the child's stdin, not its argv: sudo keeps argv in `ps`.
	my $psk_path;
	if (length $wifi_ssid) {
		my ($pfh, $path) = File::Temp::tempfile('gou_flash_psk_XXXXXXXX', TMPDIR => 1, UNLINK => 0);
		if ($pfh) {
			print {$pfh} $wifi_psk;
			close $pfh;
			chmod 0600, $path;
			$psk_path = $path;
		}
	}
	my $log_path = $job_path . '.log';
	_flash_job_write({
		state => 'starting',
		hostname => (defined $hostname ? $hostname : ''),
		token_path => ($token->{'path'} // ''),
		started_ms => _flash_now_ms(), bytes => 0, total => 0,
	}, $job_path);
	my $pid = fork();
	unless (defined $pid) {
		unlink $token->{'path'} if $token->{'path'};
		unlink $psk_path if $psk_path;
		&_controller_join_forget($token->{'secret'}) if $token->{'secret'};
		return $c->render(json => { ok => 0, error => 'the flash could not start' });
	}
	if (!$pid) {
		# Its own session: a worker restart must not kill the write, and a cancel
		# signals the whole group (sudo, perl, zstd, dd).
		eval { POSIX::setsid() };
		if ($psk_path) {
			# Open first, then drop the name: unlinking before the child gets here
			# left it reading /dev/null, so every flash saw an empty password.
			open(STDIN, '<', $psk_path) or open(STDIN, '<', '/dev/null');
			unlink $psk_path;
		}
		else { open(STDIN, '<', '/dev/null') }
		open(STDOUT, '>', $log_path);
		open(STDERR, '>&', \*STDOUT);
		$ENV{'JAWNOS_FLASH_TOKEN_PATH'} = $token->{'path'} // '';
		$ENV{'JAWNOS_FLASH_HOSTNAME'} = $hostname // '';
		exec('sudo', '-n', $^X, $script, @args) or POSIX::_exit(127);
	}
	# The child writes its own pid and start time on its first pass, before it
	# checks anything. Writing them here instead would be a read-modify-write over
	# the same file the child may have just finished in: a fast failure came back
	# as "starting" again and the route then called a finished run stopped.
	# The child drops the password file itself, once its stdin holds it.
	# This request waits for the answer, so a normal flash needs no polling. If
	# the worker dies, the session keeps writing and the status route reads on.
	my $deadline = time + 900;
	my $job;
	while (1) {
		$job = _flash_job_read($job_path);
		last if ($job->{'state'} // '') =~ /^(?:done|failed|cancelled)$/;
		my $reaped = waitpid($pid, POSIX::WNOHANG());
		if ($reaped == $pid) {
			# A provisioner that exits writes its last state just before the sudo
			# wrapper does; give the file a moment rather than calling a clean
			# failure "stopped before it finished".
			my $tries = 20;
			while ($tries-- > 0) {
				$job = _flash_job_read($job_path);
				last if ($job->{'state'} // '') =~ /^(?:done|failed|cancelled)$/;
				select(undef, undef, undef, 0.1);
			}
			$job = _flash_job_read($job_path);
			last if ($job->{'state'} // '') =~ /^(?:done|failed|cancelled)$/;
			$job = { %{ $job }, state => 'failed', error => 'the flash process stopped before it finished' };
			_flash_job_write($job, $job_path);
			last;
		}
		if (time > $deadline) {
			kill 'TERM', -$pid;
			$job = { %{ $job }, state => 'failed', error => 'the flash timed out' };
			_flash_job_write($job, $job_path);
			last;
		}
		select(undef, undef, undef, 0.5);
	}
	_flash_job_cleanup($job);
	my $state = $job->{'state'} // 'failed';
	if ($state eq 'done') {
		return $c->render(json => {
			ok => 1, state => 'done', device => $job->{'device'},
			bytes_written => $job->{'bytes'}, sha256_match => $job->{'sha256_match'},
			autopopulated => ($job->{'autopopulated'} || []), wifi => $wifi_ssid,
			reboot => ($job->{'reboot'} ? 1 : 0),
			rebooted => ($job->{'rebooted'} ? 1 : 0),
		});
	}
	if ($state eq 'cancelled') {
		return $c->render(json => { ok => 0, state => 'cancelled', cancelled => 1, error => 'cancelled', wifi => $wifi_ssid });
	}
	return $c->render(json => {
		ok => 0, state => 'failed',
		error => ($job->{'error'} || 'the board was not flashed'), wifi => $wifi_ssid,
	});
}

# GET /manager/controllers/new/flash/status
# The page polls this while a flash runs and once when the window opens, so a
# restarted panel picks the job up where it was rather than declaring failure.
sub action_54012 {
	my $c = shift;
	unless (&_controller_house_pass($c)) {
		return $c->render(json => { ok => 0, error => 'not allowed' });
	}
	unless (&_controller_is_computer()) {
		return $c->render(json => { ok => 0, error => 'not a computer' });
	}
	my $path = _flash_job_path();
	my $job = _flash_job_read($path);
	return $c->render(json => { ok => 1, state => 'idle' }) unless %$job;
	if (_flash_job_active($job->{'state'})) {
		my $waiting = !$job->{'pid'} && defined $job->{'started_ms'}
			&& (_flash_now_ms() - $job->{'started_ms'}) < 5000;
		if (!$waiting && !_flash_job_alive($job)) {
			$job = { %{ $job }, state => 'failed', error => 'the flash process stopped before it finished' };
			_flash_job_write($job, $path);
		}
	}
	my $view = _flash_job_view($job);
	_flash_job_cleanup($job) unless _flash_job_active($job->{'state'});
	$c->render(json => $view);
}

# POST /manager/controllers/new/flash/cancel
# A cancel is the person saying stop: TERM the whole session, then KILL it if it
# has not written a final state. The partial device is not a bootable board, so
# the token is spent with it.
sub action_54013 {
	my $c = shift;
	unless (&_controller_house_pass($c)) {
		return $c->render(json => { ok => 0, error => 'not allowed' });
	}
	unless (&_controller_is_computer()) {
		return $c->render(json => { ok => 0, error => 'not a computer' });
	}
	my $path = _flash_job_path();
	my $job = _flash_job_read($path);
	unless (_flash_job_active($job->{'state'}) && _flash_job_alive($job)) {
		return $c->render(json => { ok => 0, error => 'no flash is running' });
	}
	my $pid = $job->{'pid'};
	kill 'TERM', -$pid;
	my $until = time + 6;
	while (time < $until) {
		my $now = _flash_job_read($path);
		last unless _flash_job_active($now->{'state'});
		select(undef, undef, undef, 0.1);
	}
	my $now = _flash_job_read($path);
	if (_flash_job_active($now->{'state'})) {
		kill 'KILL', -$pid;
		$now = { %{ $now }, state => 'cancelled', error => 'cancelled' };
		_flash_job_write($now, $path);
	}
	_flash_job_cleanup($now);
	$c->render(json => { ok => 1, state => ($now->{'state'} // 'cancelled') });
}

1;
