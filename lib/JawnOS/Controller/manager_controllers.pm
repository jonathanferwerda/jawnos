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
	return qw/Documents Downloads Recordings Games Scans Pictures Videos Music/;
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
	my ($device, $machine) = &_controller_resolve($uuid);
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
	$c->render(json => {
		ok => 1,
		uuid => $uuid,
		archive_dir => $dir,
		archive => (($machine->{'archive'} // '') eq '1' ? 1 : 0),
		folders => $folders,
		present => (($is_this && length $dir && -d $dir) ? 1 : 0),
	});
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
	my $now = &subs::rightNow();
	if (keys %{$machine}) {
		my $where = $machine->{'uuid'} ? { uuid => $machine->{'uuid'} } : { signatorial => $machine->{'signatorial'} };
		&subs::db_update('remote_machines', { archive_dir => $dir, archive => $archive, server_time => $now }, $where);
	}
	else {
		# The roster row is the controller the house paired; the machine row is
		# the one that carries a drive, and this is where it first appears.
		my $signatorial = ($device && $device->{'signatorial'}) || ($uuid eq 'local' ? $key : '');
		&subs::db_insert('remote_machines', {
			uuid => $key,
			signatorial => $signatorial,
			hostname => ($device && $device->{'name'}) || '',
			archive_dir => $dir,
			archive => $archive,
			timestamp => $now,
			server_time => $now,
		});
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
	$log->info('controller storage: ' . (($device && $device->{'name'}) || $uuid) . ' archive_dir ' . $dir . ' archive ' . $archive);
	$c->render(json => {
		ok => 1,
		uuid => $uuid,
		archive_dir => $dir,
		archive => ($archive eq '1' ? 1 : 0),
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
	my ($c, $name, $hostname) = @_;
	my $secret = &subs::random_string_creator(40);
	my $now = &subs::rightNow();
	my $manager = &subs::house_manager_address(eval { $c->req->url->to_abs->to_string } || '');
	my $token = {
		kind => 'jawnos-controller-join',
		v => 1,
		secret => $secret,
		name => $name,
		hostname => $hostname,
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
	my ($fh, $path) = File::Temp::tempfile('controller_join_XXXXXXXX.json', DIR => $dir, UNLINK => 0);
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
	my $ssid = defined $c->param('wifi-ssid') ? $c->param('wifi-ssid') : $c->param('wifi_ssid');
	my $psk = defined $c->param('wifi-psk') ? $c->param('wifi-psk') : $c->param('wifi_psk');
	push @args, ('--wifi-ssid', substr($ssid, 0, 64)) if defined $ssid && length $ssid;
	# The password is handed over on the child's stdin: sudo keeps the argv
	# visible in `ps` to every user on the machine, and a secret does not belong
	# there.
	my $psk_stdin;
	if (defined $psk && length $psk) {
		push @args, '--wifi-psk-stdin';
		$psk_stdin = substr($psk, 0, 128);
	}
	my $hostname = $c->param('hostname');
	push @args, ('--hostname', substr($hostname, 0, 63)) if defined $hostname && length $hostname;
	# The token is the board's way into the house on its first boot; the
	# provisioner copies it into the flashed rootfs beside the WiFi profile.
	my $token = &_controller_join_token($c, (defined $hostname && length $hostname ? $hostname : 'Controller'), (defined $hostname && length $hostname ? $hostname : 'gou'));
	push @args, ('--join-token', $token->{'path'}) if $token->{'path'};
	my $answer = &_controller_gou_run(1, $psk_stdin, @args);
	unlink $token->{'path'} if $token->{'path'};
	&_controller_join_forget($token->{'secret'}) if $token->{'secret'} && !($answer->{'ok'});
	$c->render(json => $answer);
}

1;
