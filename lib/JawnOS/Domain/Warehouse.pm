package subs;

# Warehouse: extracted from subroutines.pl (package subs). Loaded on
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
our %m;

# FIFO-walk the stock and write off whatever has outlived its packaging shelf
# life. Runs on a timer (see President.pl). Each write-off references the lot it
# expired via app_uuid, and since the write-off is itself a negative movement,
# the next pass consumes that lot and won't expire it twice.
sub warehouse_expiry_sweep {
	my $now = &rightNow();
	my $q = &db_query('select * from warehouse where item is not null and item != ? and place is not null and place != ? order by timestamp asc', '', '');
	my $rows = $q ? $q->hashes : [];
	my %lots;
	foreach my $r ( @{$rows} ) {
		my $unit = $r->{'unit'} || 'each';
		next if (($r->{'kind'} || '') eq 'usage');
		my $types = $gb::measures->{$unit}->{'types'} || [];
		next if ($r->{'account'} && $r->{'account'} ne '') || (grep { $_ eq 'currency' } @{$types});
		my $qty = &numeric_formatter($r->{'quantity'}) + 0;
		next if $qty == 0;
		my $key = $r->{'place'} . "\0" . $r->{'item'};
		my $queue = $lots{$key} ||= [];
		if ($qty > 0) {
			push @{$queue}, { uuid => $r->{'uuid'}, ts => &numeric_formatter($r->{'timestamp'}) + 0, remaining => $qty, row => $r };
		}
		else {
			my $need = -$qty;
			foreach my $lot ( @{$queue} ) {
				last if $need <= 0;
				next if $lot->{'remaining'} <= 0;
				my $take = $lot->{'remaining'} < $need ? $lot->{'remaining'} : $need;
				$lot->{'remaining'} -= $take;
				$need -= $take;
			}
		}
	}
	my $written = 0;
	foreach my $key ( keys %lots ) {
		my ($place,$item) = split /\0/, $key;
		my $expires = &warehouse_item_expires($item);
		next unless $expires;
		foreach my $lot ( @{$lots{$key}} ) {
			next unless $lot->{'remaining'} > 0;
			my $expiry = eval { &ago_calc('-' . $expires, $lot->{'ts'}) } || 0;
			next unless $expiry && $now > $expiry;
			my $src = $lot->{'row'};
			&warehouse_movement({
				item => $item,
				quantity => $lot->{'remaining'} * -1,
				unit => $src->{'unit'},
				place => $place,
				model => $src->{'model'},
				account => $src->{'account'},
				project => $src->{'project'},
				warranty => $src->{'warranty'},
				timestamp => $now,
				app_uuid => $lot->{'uuid'},
				type => 'expiry',
				reason => 'expired',
				source => $place,
				source_uuid => $lot->{'uuid'}
			});
			$lot->{'remaining'} = 0;
			$written++;
		}
	}
	return $written;
}

sub task_checker {
	my $one_app = shift;
	my $server_time = &subs::rightNow();
	my $tasks = $one_app ? [{ app => &subs::unformat_name($one_app) }] : &subs::db_query('select app from settings where setting = ? and value is not null','tasks')->hashes;
	foreach my $task ( @{$tasks} ) {
		my $app = $task->{'app'};
		my $taskskis = &subs::task_grabber($app);
	#	my $websockets = &subs::db_query('select * from websockets where app = ? and windows like ? and server_time > ? and windows is not null order by timestamp DESC',
	#	'tab', '%app":"' . $app . '%', $server_time - 5000)->hashes;
	#	if (scalar @{$websockets} > 0) {

			my $msg = {
				app => $app,
				type => 'html',
				selector => '.re_tasks[app="' . $app . '"]',
				content => $taskskis->{'html'}
			};
			&Websocket::send('server', $msg);

	#	}
	}

	return 0;
}

sub task_grabber {
	my $app = shift;
	my $parent = shift || 0;
	my $settings = &subs::settings_grabber({ app => $app });
	my $tasks_json = &subs::setting_grabber({ app => $app, setting => 'tasks' }) || '[]';
	my $tasks = decode_json $tasks_json;
	@{$tasks} = grep { $_->{'uuid'} } @{$tasks};
	@{$tasks} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$tasks};
	my $totals = {};
	foreach my $t ( @{$tasks} ) {
		my $tsettings = &subs::settings_grabber({ app => &unformat_name($t->{'task'}) });
		$t->{'colour'} = $tsettings->{'colour'} if $tsettings->{'colour'};
		foreach my $bm ( keys %{$gb::budget_modes} ) {
			if ($bm eq 'duration') {
				$totals->{$bm} += &subs::time_abbrev_translator($t->{$bm});
				$t->{$bm} = &subs::duration_sayer(&subs::time_abbrev_translator($t->{$bm}) / 1000);
			}
			elsif ($bm eq 'occurences') {
				$totals->{$bm} += $t->{$bm};
			}
		}
		# A task that has never been given a renewal has no renew_freq or
		# last_completed; the old direct arithmetic warned for every one of them on
		# every task_grabber call (the phone's log grew ~51 KB/min).
		my $renew_freq = $t->{'renew_freq'} // 0;
		my $last_completed = $t->{'last_completed'} // 0;
		if ($renew_freq + $last_completed < &subs::rightNow() && $renew_freq > 0) {
			$t->{'completed'} = 'off';
		#	$t->{'duration'} = abs $settings->{'duration'};
		}
		$t->{'renew_freq'} = &subs::duration_sayer($renew_freq / 1000);


		if (my $jt = eval { return decode_json $tsettings->{'tasks'} }) {
			if (scalar @{$jt} > 0) {

				$t->{'subsidiaries'} = &task_grabber(&unformat_name($t->{'task'}), $parent + 1);
				if (scalar @{$t->{'subsidiaries'}->{'tasks'}} == 0) {
					&subs::setting_deleter({ app => &subs::unformat_name($t->{'task'}), setting => 'tasks' });
					$t->{'subsidiaries'} = undef;
				}
			}

		}
	}
	$totals->{'duration'} = &subs::duration_sayer(($totals->{'duration'} || 0) / 1000);

	my $tasks_sort = $settings->{'tasks_sort'} || '';
	my $tasks_filter = $settings->{'tasks_filter'} || '';
	if ($tasks_sort eq 'new') {
		@{$tasks} = sort { $b->{'timestamp'} <=> $a->{'timestamp'} } @{$tasks};
	}
	elsif ($tasks_sort eq 'high') {
		@{$tasks} = sort { $b->{'priority'} <=> $a->{'priority'} } @{$tasks};
	}
	elsif ($tasks_sort eq 'low') {
		@{$tasks} = sort { $a->{'priority'} <=> $b->{'priority'} } @{$tasks};
	}
	elsif ($tasks_sort eq 'az') {
		@{$tasks} = sort { $a->{'task'} cmp $b->{'task'} } @{$tasks};
	}
	elsif ($tasks_sort eq 'za') {
		@{$tasks} = sort { $b->{'task'} cmp $a->{'task'} } @{$tasks};
	}
	elsif ($tasks_sort eq 'chk') {
		@{$tasks} = sort { $a->{'last_completed'} <=> $b->{'last_completed'} } @{$tasks};
	}
	elsif ($tasks_sort eq 'rchk') {
		@{$tasks} = sort { $b->{'last_completed'} <=> $a->{'last_completed'} } @{$tasks};
	}
	else {
		@{$tasks} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$tasks};
	}

	if ($tasks_filter eq 'done') {
		@{$tasks} = grep { $_->{'completed'} eq 'on' } @{$tasks};
	}
	elsif ($tasks_filter eq 'open') {
		@{$tasks} = grep { $_->{'completed'} eq 'off' } @{$tasks};
	}

	push @{$tasks}, { uuid => 'new', lock => 'locked', colour => '#' . &subs::random_colour_grabber() } unless $parent > 0;
	my $c = &subs::controller_builder();
	my $html = $c->render_to_string(
		template => 'apps/tasks',
		tasks => $tasks,
		app => $app,
		totals => $totals,
		settings => $settings,
		parent => $parent
	);
	return { html => $html, tasks => $tasks, totals => $totals };
}

sub task_writer {
	my $c = shift;
	my $data = shift;
	my $papp = &subs::unformat_name($data->{'papp'});
	my $app = &subs::unformat_name($data->{'app'});
	my $server_time = $c->param('server_time') || &subs::rightNow();
	my $timestamp = $data->{'timestamp'};
	my $uuid = $data->{'uuid'};
	my $name = $data->{'name'};
	my $value = $data->{'value'};
	my $colour = $data->{'colour'};
	my $tasks = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'tasks' }) } || [];

	if ($name eq 'duration') {
		$value = &subs::time_abbrev_translator($value);
	}
	elsif ($name eq 'occurences') {
		$value =~ s/[^0-9.]//gi;
		$value = abs $value;
	}
	elsif ($name eq 'renew_freq') {
		$value = &subs::time_abbrev_translator($value);
	}
	elsif ($name eq 'task') {
		$value = &subs::unformat_name($value);
	}
	if ($uuid eq 'new') {
		my $settings = &subs::settings_grabber({ app => $value });
		$settings->{'worth'} =~ s/[^0-9.]//gi;
		push @{$tasks}, {
			uuid => &subs::random_string_creator(),
			$name => $value,
			timestamp => $timestamp,
			colour => $settings->{'colour'} || $colour,
			duration => &subs::duration_sayer(abs &subs::time_abbrev_translator($settings->{'duration'}) / 1000),
			occurences => 1,
			priority => 0,
			completed => 'off',
		};
	}
	else {
		my @task = grep { $_->{'uuid'} eq $uuid } @{$tasks};


		my $task = $task[0];
		$task->{$name} = $value;
		my @tasks = grep { $_->{'uuid'} ne $uuid } @{$tasks};
		push @tasks, $task;
		@{$tasks} = @tasks;
		my $parent_task = eval { return decode_json &subs::setting_grabber({ app => $task->{'task'}, setting => 'tasks' }) } || [];
		foreach my $pt ( @{$parent_task} ) {
			my $tasks = &subs::task_writer($c,{
				papp => $papp,
				app => $pt->{'task'},
				timestamp => $timestamp,
				uuid => $pt->{'uuid'},
				name => $name,
				value => $value,
				colour => $pt->{'colour'},
			});
		}
		if ($name eq 'completed' && $value eq 'on') {

			my $running_appt = &subs::db_query('select * from appointments where app = ? and (type = ? or type = ?) and timestamp <= ? order by timestamp', $papp, 'start', 'record', $timestamp)->hashes->[0];
			$task->{'last_completed'} = &subs::rightNow();
			if ($task->{'appt'} eq 'on') {
				my $settings = &subs::settings_grabber({ app => $task->{'task'} });
				my $duration;
				if ($task->{'duration'} && $task->{'duration'} =~ /[0-9]/gi) {
					my $dur_text = $settings->{'duration'};
					$duration = defined $dur_text ? abs &subs::time_abbrev_translator($dur_text) : 0;
				}
				elsif ($settings->{'duration'} && $settings->{'duration'} =~ /[0-9]/gi) {
					$duration = abs &subs::time_abbrev_translator($settings->{'duration'});
				}
				else {
					$duration = abs &subs::time_abbrev_translator(&subs::setting_grabber({ 'app' => 'me', setting => 'duration'}) || '5m');
				}

				# keyed on the request alone (the timestamp is already in the uuid's prefix),
				# never on $running_appt: that is the earliest open session on THIS machine, so
				# hashing it in gave the same completion a different uuid on every machine and
				# the mesh kept each machine's copy as its own row
				my $md5_uuid = md5_sum $papp . '-' . $timestamp . '-' . $task->{'task'} . $data->{'project'} . $data->{'account'} . $data->{'movement'};
				my $data = {
					app => $task->{'task'},
					timestamp => $timestamp,
					type => 'usual',
					quantity => $task->{'occurences'},
					duration => (abs $duration),
					source_uuid => $running_appt->{'uuid'},
					project => $data->{'project'},
					account => $data->{'account'},
					movement => $data->{'movement'},
					uuid => $timestamp . '-' . $md5_uuid,
					server_time => $server_time
				};
				my $app = &Manager::appointment_writer($c,$data);
				$task->{'last_appt_uuid'} = $app->{'uuid'};
				$task->{'last_server_time'} = $app->{'server_time'};

			}

		}
		elsif ($name eq 'completed' && $task->{'appt'} eq 'on' && $value eq 'off') {
			&Manager::delete_app($task->{'task'},$task->{'last_appt_uuid'},$task->{'server_time'},'task');
		}
	}
	return $tasks;
}

sub note_retriever {
	my ($app,$uuid) = @_;
	my $noters = &subs::db_select('appointments', ['start_notes','notes','end_notes','server_time'], { app => $app, uuid => $uuid });
	my $noteskis = $noters->hashes;
	my $cred = &subs::db_select('security');
	my $creds = $cred->hashes;
	my $s = &subs::suds_grabber();
	my $notekeeper;
	foreach my $note ( @{$noteskis} ) {
		my $start_notes = &subs::note_decrypter($s, $note->{'start_notes'},$note->{'ost'}) if eval { &subs::note_decrypter($s, $note->{'start_notes'},$note->{'ost'}) };
		my $notes = &subs::note_decrypter($s, $note->{'notes'},$note->{'ost'}) if eval { &subs::note_decrypter($s, $note->{'notes'},$note->{'ost'}) };
		my $end_notes = &subs::note_decrypter($s, $note->{'end_notes'},$note->{'ost'}) if eval { &subs::note_decrypter($s, $note->{'end_notes'},$note->{'ost'}) };
		$notekeeper = "<br>" . $start_notes . "<br>" . $notes . "<br>" . $end_notes;
		$notekeeper =~ s/\n/<br>/gi;
	}
	return $notekeeper;
}

sub log_reader_file_preparer {
	my $file = shift;
	my $f = $file->{'f'};

	#	my ($destination,$asset) = &subs::file_device_renamer($f,$a->{'app'},$misc_settings);
	#	if ($f ne $destination . $asset) {
	#		$f = $destination . $asset;
	#	}
	my $tf = {
		file => $f,
		preview => $file->{'preview'},
		uuid => $file->{'uuid'},
		server_time => $file->{'server_time'},
		function => $file->{'function'},
		type => $file->{'type'},
		name => $file->{'name'},
		app => $a->{'app'}
	};
	my $kind = &media_file_type($f);
	$tf->{'file_type'} = $kind if defined $kind;
	return $tf;
}

# What a media row is, from its extension. The old inline test only knew
# jpg|png|bmp|tiff|xcf, so a phone's .jpeg, .webp, .heic or .tif filing got no
# file_type at all and app_file rendered nothing. Extension first, then a sealed
# `.enc` tail is dropped so a sealed photo still reads as its own kind.
sub media_file_type {
	my ($file) = @_;
	return undef unless defined $file && length $file;
	my $name = $file;
	$name =~ s/\.enc$//i;
	$name =~ s{.*/}{};
	my ($ext) = $name =~ /\.([A-Za-z0-9]+)$/;
	return undef unless defined $ext;
	$ext = lc $ext;
	my %kind = (
		(map { $_ => 'img' } qw(jpg jpeg jpe png webp heic heif bmp tif tiff xcf gif)),
		(map { $_ => 'snd' } qw(wav mp3 aiff aif weba m4a flac ogg oga opus)),
		(map { $_ => 'vid' } qw(mp4 avi mov webm mkv m4v)),
		pdf => 'pdf',
		(map { $_ => 'doc' } qw(doc docx xls xlsx pub pubx txt rtf odt ods csv)),
	);
	return $kind{$ext};
}

# The handshake and the tunnel heartbeat hand another machine a copy of this
# roster. A full row also carries `data` (the peer's login body), `cookie` (a
# live session), the deletion log and the mirror-of-mirrors blob; nothing on
# the receiving side reads any of those for a mirror, so send the routing and
# identity fields the picker, the roster proof and the LAN fallback use.
my @REMOTE_MACHINE_MIRROR_FIELDS = qw(
	uuid signatorial pubkey
	ip hostname fqdn port manager ws_port dock_port nic
	network tailnet_ip pseudonyms
	tunnel device connection status mirror
	buttons mac model capabilities purpose name domain
	archive archive_dir privilege grant_scope grant_expires
	server_time
);

sub remote_machine_mirror_row {
	my ($rm) = @_;
	return undef unless ref $rm eq 'HASH';
	my %row;
	foreach my $field (@REMOTE_MACHINE_MIRROR_FIELDS) {
		$row{$field} = $rm->{$field} if defined $rm->{$field};
	}
	return \%row;
}

# The login body stored in `data` was kept whole, including the debriefer (a
# multi-kilobyte audit log), the browser tab id and the password path. Callers
# read only these fields, so keep those and let the rest go.
my @REMOTE_MACHINE_DATA_FIELDS = qw(database device ssh_port manager_colour manager_file);

sub remote_machine_data_view {
	my ($body) = @_;
	return {} unless ref $body eq 'HASH';
	my %view;
	foreach my $field (@REMOTE_MACHINE_DATA_FIELDS) {
		$view{$field} = $body->{$field} if defined $body->{$field};
	}
	return \%view;
}

# One pass over rows written before the two views above. It rewrites only
# `data` and `mirrors`; server_time is the peer's freshness, not this write's
# time, so it is deliberately left alone. A blob that is not the expected JSON
# is left in place for the next handshake rather than destroyed.
sub remote_machine_payload_backfill {
	my $result = eval { &subs::db_query('select uuid, signatorial, data, mirrors from remote_machines') };
	return 0 unless $result;
	my $rows = $result->hashes || [];
	my ($changed, $skipped, $failed) = (0, 0, 0);
	foreach my $row ( @{$rows} ) {
		my $key = (defined $row->{'uuid'} && $row->{'uuid'} ne '') ? 'uuid'
			: (defined $row->{'signatorial'} && $row->{'signatorial'} ne '') ? 'signatorial' : '';
		unless ($key) { $skipped++; next; }

		my (@set, @args);
		if (defined $row->{'data'} && $row->{'data'} =~ /^\s*\{/) {
			my $data = eval { decode_json($row->{'data'}) };
			if (ref $data eq 'HASH') {
				my $view = encode_json &subs::remote_machine_data_view($data);
				if ($view ne $row->{'data'}) { push @set, 'data = ?'; push @args, $view; }
			}
			else { $skipped++ }
		}
		if (defined $row->{'mirrors'} && $row->{'mirrors'} =~ /^\s*\[/) {
			my $mirrors = eval { decode_json($row->{'mirrors'}) };
			if (ref $mirrors eq 'ARRAY') {
				my $view = encode_json [ grep { defined $_ } map { &subs::remote_machine_mirror_row($_) } @{$mirrors} ];
				if ($view ne $row->{'mirrors'}) { push @set, 'mirrors = ?'; push @args, $view; }
			}
			else { $skipped++ }
		}
		next unless @set;
		my $ok = eval { &subs::db_query('update remote_machines set ' . join(', ', @set) . ' where ' . $key . ' = ?', @args, $row->{$key}); 1 };
		if ($ok) { $changed++ } else { $failed++ }
	}
	&subs::say_it('backfill remote_machine_payload_prune_v1: rewrote ' . $changed . ' row(s)'
		. ($skipped ? ', skipped ' . $skipped : '')
		. ($failed ? ', failed ' . $failed : ''));
	return $failed ? 0 : 1;
}

sub remote_machine_lister {
	my $data = shift;
	my $remote_machines = &subs::db_select('remote_machines')->hashes || [];

	# A machine must never carry itself as a remote. A self row is poison: the
	# reconnecter keeps a turn for it, and the hub used to hand every remote row
	# back as `mirrors`, so a self-touch nested the previous copy - the row grew
	# without bound and the turn the real peers needed was spent decoding it. The
	# mirror payload is pruned now (remote_machine_mirror_row), but a self row
	# still wastes a turn. Drop it here so a hub that grew one heals, and keep
	# the current call clean too.
	my $self_signatorial = &signatorial_designer();
	if ($self_signatorial) {
		my @self = grep { ($_->{'signatorial'} || '') eq $self_signatorial } @{$remote_machines};
		if (scalar @self) {
			&subs::db_delete('remote_machines', { signatorial => $self_signatorial });
			@{$remote_machines} = grep { ($_->{'signatorial'} || '') ne $self_signatorial } @{$remote_machines};
		}
	}

	# A hub that a peer dialled into records the address it dialled from in that
	# peer's network blob and hands the row back as a mirror. The mirror itself is
	# dropped below when the peer already has a row of its own, so carry its
	# public address onto that row first: on a machine that is not the hub this is
	# the only place a NATed peer's public address is known.
	my %mirror_public;
	foreach my $rm ( @{$remote_machines} ) {
		next unless $rm->{'mirrors'};
		my $mirrors = eval { return decode_json $rm->{'mirrors'} } || [];
		foreach my $mirror ( @{$mirrors} ) {
			next unless ref $mirror eq 'HASH';
			my $net = ref $mirror->{'network'} eq 'HASH' ? $mirror->{'network'} : (eval { decode_json $mirror->{'network'} } || {});
			my $public = &public_ip_only($net->{'public_address'});
			next unless $public;
			foreach my $id ( $mirror->{'signatorial'}, $mirror->{'uuid'} ) {
				next unless defined $id && $id ne '';
				$mirror_public{$id} = $public;
			}
		}
	}
	foreach my $rm ( @{$remote_machines} ) {
		next if $rm->{'public_address'};
		foreach my $id ( $rm->{'signatorial'}, $rm->{'uuid'} ) {
			next unless defined $id && $id ne '' && $mirror_public{$id};
			$rm->{'public_address'} = $mirror_public{$id};
			last;
		}
	}

	# a mirror entry is how a machine the source knows about is reached through
	# it; when that machine already has a row of its own the list would show the
	# same machine twice (once, three times, with overlapping mirror sources),
	# so a mirror is only added when none of its identities is otherwise present.
	# Identities are alternatives, not a preference: a mirror of this machine
	# carries our own signatorial (and often the app's 127.0.0.1 as its fqdn),
	# and a mirror of a peer already listed carries that peer's uuid or
	# signatorial. Comparing only the first identity let both through, which put
	# "Laptop (mirror)" in the picker and sent Go to the local manager.
	my %already;
	$already{$self_signatorial} = 1 if $self_signatorial;
	foreach my $rm ( @{$remote_machines} ) {
		for my $id ( $rm->{'uuid'}, $rm->{'signatorial'} ) {
			$already{$id} = 1 if defined $id && $id ne '';
		}
	}
	foreach my $rm ( @{$remote_machines} ) {
		# A mirror pushed below is visited again by this same foreach (Perl
		# extends the array it iterates), and the old unconditional reset
		# cleared the very flag the remote_control picker uses to hide mirrors.
		$rm->{'mirror'} = 'no' unless ($rm->{'mirror'} || '') eq 'yes';
		if ($rm->{'mirrors'} && ($data->{'mirrors'} || '') ne 'none') {
			my $mirrors = eval { return decode_json $rm->{'mirrors'} } || [];
			foreach my $mirror ( @{$mirrors} ) {
				next if grep { defined $_ && $_ ne '' && $already{$_} }
					( $mirror->{'uuid'}, $mirror->{'signatorial'} );
				$already{$mirror->{'uuid'}} = 1 if $mirror->{'uuid'};
				$already{$mirror->{'signatorial'}} = 1 if $mirror->{'signatorial'};
				$mirror->{'hostname'} .= ' (mirror)';
				$mirror->{'source_ip'} = $rm->{'ip'};
				$mirror->{'source_domain'} = $rm->{'domain'};
				$mirror->{'source_fqdn'} = $rm->{'fqdn'};
				$mirror->{'mirror'} = 'yes';
			# When the mirror is on our own network, reach it directly rather than
			# through the source's tunnel: same-wifi peers talk on the LAN.
				my $lan = &subs::peer_lan_address($mirror, 1);
				if ($lan) {
					$mirror->{'ip'} = $lan->{'ip'};
					$mirror->{'manager'} = $lan->{'manager'};
					$mirror->{'port'} = $lan->{'port'} || $mirror->{'port'};
					$mirror->{'vip'} = $lan->{'ip'};
					$mirror->{'lan'} = 'yes';
				}
				push @{$remote_machines}, $mirror;
			}
		}
		$rm->{'vip'} = $rm->{'ip'};
		$rm = &subs::remote_machine_tunnel_processor($rm);
		# The LAN address while the peer shares our network: a display value, the
		# flag hub mode uses to keep a same-wifi peer in the pass, and the route
		# every lister-based caller should use. A stored manager can be a tailnet
		# name whose node is offline, so prefer the LAN manager here the way the
		# mirror block above does.
		my $lan = &subs::peer_lan_address($rm, 1);
		if ($lan) {
			$rm->{'lan_ip'} = $lan->{'ip'};
			$rm->{'lan'} = 'yes';
			$rm->{'manager'} = $lan->{'manager'};
			$rm->{'port'} = $lan->{'port'} || $rm->{'port'};
			$rm->{'ip'} = $lan->{'ip'};
		}
	}
	unless ( ($data->{'self'} || '') eq 'no' ) {
		unshift @{$remote_machines}, { hostname => 'me', signatorial => &subs::signatorial_designer(), ip => '127.0.0.1', uuid => &subs::random_string_creator(25) };
	}
	foreach my $t ( qw/signatorial uuid connection ip device tunnel mirror archive/ ) {
		if ($data->{$t}) {
			if ($data->{$t} eq 'yes') {
				@{$remote_machines} = grep { defined $_->{$t} && $_->{$t} ne '' && $_->{$t} ne 'null' && $_->{$t} ne 'NULL'	} @{$remote_machines};
			} else {
				@{$remote_machines} = grep { ($_->{$t} || '') eq $data->{$t} } @{$remote_machines};
			}
		}
	}
	if ($data->{'limit'}) {
		if ($data->{'limit'} == 1) {
			$remote_machines = $remote_machines->[0];
		} else {
			splice @{$remote_machines}, $data->{'limit'};
		}
	}
	return $remote_machines;



}

# A plain public IPv4 address, or '' for loopback, private, carrier-grade NAT
# and anything that is not an address at all.
sub public_ip_only {
	my $ip = shift || '';
	return '' unless $ip =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
	return '' if $1 > 255 || $2 > 255 || $3 > 255 || $4 > 255;
	return '' if $ip =~ /^(?:0\.|127\.)/;
	return '' if &ip_is_private($ip);
	return $ip;
}

# The public-IP echo services offered under Configure -> Plat -> DNS. `all`
# asks each in turn so one service having a bad day does not leave the panel
# blank; `none` stops the lookup entirely.
sub public_ip_check_choice {
	my $choice = &setting_grabber({ app => '__president', setting => 'public_ip_check', device => 'all' });
	$choice = &setting_grabber({ app => '__president', setting => 'public_ip_check' }) unless defined $choice && length $choice;
	$choice = 'all' unless defined $choice && length $choice;
	return $choice =~ /^(?:all|cloudflare|ipify|icanhazip|none)$/ ? $choice : 'all';
}

sub public_ip_check_urls {
	my $choice = &public_ip_check_choice();
	return () if $choice eq 'none';
	my %url = (
		cloudflare => 'https://1.1.1.1/cdn-cgi/trace',
		ipify      => 'https://api.ipify.org',
		icanhazip  => 'https://icanhazip.com',
	);
	return ($url{$choice}) if $choice ne 'all';
	return ($url{'cloudflare'}, $url{'ipify'}, $url{'icanhazip'});
}

# A machine's own public interface, without asking anyone outside. This is what
# a server shows when the external check is off: its NIC carries the address
# itself. A machine behind NAT has no public interface, so this returns ''.
sub public_interface_address {
	my $rm = shift;
	return '' unless ref $rm eq 'HASH';
	my $net = ref $rm->{'network'} eq 'HASH' ? $rm->{'network'} : (eval { decode_json $rm->{'network'} } || {});
	if (ref $net eq 'HASH') {
		foreach my $nic ( sort keys %{$net} ) {
			next if $nic eq 'public_address';
			next unless ref $net->{$nic} eq 'HASH';
			my $public = &public_ip_only($net->{$nic}->{'ip'});
			return $public if $public;
		}
	}
	return &public_ip_only($rm->{'ip'});
}

# The address a remote machine presents on the public internet, as far as this
# house knows it: the address a hub saw it dial from (kept in `public_address`,
# or still inside the network blob), or one of its own interfaces when the
# machine sits directly on a public address (a hosted server). Returns '' for a
# machine behind a router that no hub has seen.
sub remote_public_address {
	my $rm = shift;
	return '' unless ref $rm eq 'HASH';
	my $public = &public_ip_only($rm->{'public_address'});
	return $public if $public;
	my $net = ref $rm->{'network'} eq 'HASH' ? $rm->{'network'} : (eval { decode_json $rm->{'network'} } || {});
	if (ref $net eq 'HASH') {
		$public = &public_ip_only($net->{'public_address'});
		return $public if $public;
	}
	return &public_interface_address($rm);
}

sub remote_machine_tunnel_processor {
	my $rm = shift;
	if ($rm->{'tunnel'} eq 'yes' && !$rm->{'tuns'}) {
		my $tun = &subs::tunnel_port_mapper({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}  });
		$rm->{'tuns'} = $tun;

		# A tunnel flag can outlive its rows (the peer redialled, the hub retired
		# the batch, or the failure counter dropped them). Rewriting the manager
		# from an empty map writes a portless 'https://127.0.0.1:' that then
		# replaces the peer's real address until its next redial, so only rewrite
		# when the tunnel actually reserved a port; otherwise leave the advertised
		# manager (and the LAN fallback below) to reach the peer.
		if ($tun->{'PORT_AHOY'}) {
			$rm->{'port_dock'} = $tun->{'PORT_DOCK'};
			unless ($rm->{'manager_verified'}) {
				$rm->{'ip'} = '127.0.0.1';
				my $man = $rm->{'manager'};
				$rm->{'manager'} = 'https://' . $rm->{'ip'} . ':' . $tun->{'PORT_AHOY'};
				if ($man ne $rm->{'manager'}) {
					&subs::db_update('remote_machines', {
						manager => $rm->{'manager'},
					}, { uuid => $rm->{'uuid'} });
				}
			}
		}
	}
	# If reaching the peer by its stored manager would loop back home (its name
	# resolves to 127.0.0.1 on this box, or the hub tunnel points at 127.0.0.1
	# while we are not the hub), use the LAN address it advertised instead. A
	# manager that just answered the signed presence probe is kept: the caller
	# has already proved it, and the advertised LAN address may be the dead one.
	my $lan = $rm->{'manager_verified'} ? undef : &subs::peer_lan_address($rm);
	if ($lan) {
		$rm->{'ip'} = $lan->{'ip'};
		$rm->{'manager'} = $lan->{'manager'};
		$rm->{'port'} = $lan->{'port'} || $rm->{'port'};
		$rm->{'vip'} = $lan->{'ip'};
	}
	# The tailnet is the route between networks. Now that the app keeps the
	# device's own DNS (CorpDNS=false), a peer's domain may not resolve away
	# from its own LAN; its advertised 100.64.x address is the stable path.
	# Use it only when the stored name does not resolve and no LAN address won.
	unless ($rm->{'manager_verified'}) {
		my $tailnet = &subs::tailnet_address($rm);
		if ($tailnet) {
			$rm->{'tailnet_ip'} = $tailnet;
			# A tailnet address is the peer's own door, so it takes the peer's own
			# entry port first; the dock fields are only what older rows still carry.
			my $port = $rm->{'port'} || $rm->{'dock_port'} || $rm->{'port_dock'} || 3000;
			$rm->{'tailnet_manager'} = 'https://' . $tailnet . ':' . $port . '/manager';
			my ($host) = ($rm->{'manager'} || '') =~ m{^https?://([^/:]+)};
			my $resolved = 0;
			if ($host) {
				require Socket;
				$resolved = 1 if $host =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
				$resolved = 1 if gethostbyname($host);
			}
			if (!$resolved && !$lan) {
				$rm->{'manager'} = $rm->{'tailnet_manager'};
				$rm->{'ip'} = $tailnet;
				$rm->{'vip'} = $tailnet;
			}
		}
	}
	return $rm;
}

# ---- the tailnet: exit-node status and selection ---------------------------
# The remote_control panel's VPN button routes this machine's web traffic
# through a peer that offers an exit node, so sites see this device at that
# peer's address. A Linux peer drives its own tailscaled; the Android client
# answers through its own bridge instead (there is no tailscale binary or
# socket for the manager to call there).
sub tailnet_status {
	my $ttl = 3;
	our ($_TAILNET_STATUS, $_TAILNET_STATUS_AT);
	return $_TAILNET_STATUS if $_TAILNET_STATUS && ($_TAILNET_STATUS_AT || 0) > time() - $ttl;
	# The Android app runs its own embedded tailnet (libtailscale), not a
	# `tailscale` binary. It rewrites <filesDir>/tailnet/status.json atomically on
	# every status change. This tree's HOME is <filesDir>/home, so the file is one
	# level up. Only that exact canonical path is read (a symlinked directory or
	# file is rejected) and only the documented fields come back out - a key in
	# the file is never forwarded.
	{
		require Cwd;
		my $home = $ENV{'HOME'} || '';
		my $parent = length $home ? Cwd::abs_path($home . '/..') : undef;
		my $dir = defined $parent ? Cwd::abs_path($parent . '/tailnet') : undef;
		my $file = defined $dir ? Cwd::abs_path($dir . '/status.json') : undef;
		if (defined $file && defined $parent
			&& $dir eq $parent . '/tailnet' && $file eq $dir . '/status.json'
			&& -f $file && -r _) {
			my $raw = '';
			if (open my $fh, '<', $file) {
				binmode $fh;
				read($fh, $raw, 65536);
				close $fh;
			}
			my $data = length $raw ? eval { decode_json($raw) } : undef;
			if (ref $data eq 'HASH') {
				my $state = ref $data->{'state'} ? '' : (defined $data->{'state'} ? $data->{'state'} : '');
				$state =~ s/\s+/ /g;
				$state = substr($state, 0, 32);
				my $backend = ref $data->{'backend'} ? '' : (defined $data->{'backend'} ? $data->{'backend'} : '');
				$backend =~ s/\s+/ /g;
				$backend = substr($backend, 0, 64);
				my $attempts = (defined $data->{'attempts'} && !ref $data->{'attempts'}
					&& $data->{'attempts'} =~ /\A\d{1,9}\z/) ? 0 + $data->{'attempts'} : 0;
				my $at = (defined $data->{'at'} && !ref $data->{'at'}
					&& $data->{'at'} =~ /\A\d{1,16}\z/) ? 0 + $data->{'at'} : 0;
				my $app = {
					available => 1,
					source    => 'app',
					state     => $state,
					online    => ($data->{'online'} ? 1 : 0),
					has_key   => ($data->{'has_key'} ? 1 : 0),
					attempts  => $attempts,
					at        => $at,
					backend   => $backend,
					exit      => '',
					peers     => [],
				};
				$_TAILNET_STATUS = $app;
				$_TAILNET_STATUS_AT = time();
				return $app;
			}
		}
	}
	my $bin = $ENV{'TAILSCALE_BIN'} || 'tailscale';
	my $raw = `timeout 4 $bin status --json 2>/dev/null`;
	my $status = eval { decode_json($raw) } || {};
	my @peers;
	my $exit = '';
	foreach my $id ( keys %{ $status->{'Peer'} || {} } ) {
		my $p = $status->{'Peer'}->{$id} || {};
		# the tailnet is 100.64.0.0/10; skip the IPv6 line a peer also carries
		my ($ip) = grep { defined $_ && $_ =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./ } @{ $p->{'TailscaleIPs'} || [] };
		next unless $ip;
		push @peers, {
			ip => $ip,
			name => $p->{'HostName'} || $p->{'DNSName'} || $id,
			online => $p->{'Online'} ? 1 : 0,
			exit => $p->{'ExitNodeOption'} ? 1 : 0,
		};
		$exit = $ip if $p->{'ExitNode'};
	}
	my $available = (scalar(keys %{ $status->{'Peer'} || {} }) || ($status->{'BackendState'} // '') ne '') ? 1 : 0;
	my $result = { available => $available, exit => $exit, peers => \@peers };
	$_TAILNET_STATUS = $result;
	$_TAILNET_STATUS_AT = time();
	return $result;
}

sub tailnet_set_exit {
	my ($ip) = @_;
	$ip = '' unless defined $ip;
	if ($ip ne '' && $ip !~ /^[0-9a-fA-F:.]+$/) {
		return { ok => 0, error => 'not a tailnet address' };
	}
	if ($ip ne '') {
		my ($peer) = grep { $_->{'ip'} eq $ip && $_->{'exit'} } @{ &tailnet_status()->{'peers'} };
		return { ok => 0, error => 'that machine does not offer an exit node' } unless $peer;
	}
	my $bin = $ENV{'TAILSCALE_BIN'} || 'tailscale';
	my $cmd = $ip ne '' ? "$bin set --exit-node=$ip --exit-node-allow-lan-access" : "$bin set --exit-node=";
	my $out = `timeout 15 $cmd 2>&1`;
	my $rc = $? >> 8;
	our $_TAILNET_STATUS;
	undef $_TAILNET_STATUS;
	return { ok => ($rc == 0 ? 1 : 0), exit => $ip, error => ($rc == 0 ? undef : ($out || 'tailscale set failed')) };
}

# The tailnet address a roster row advertises, from its own network map first
# (a peer's ip column is often the LAN address) and its ip column second.
# The name this machine calls itself on. It is the configured domain with its
# first label replaced by `local` (oldtop.jonathanferwerda.com reads as
# local.jonathanferwerda.com), which the house's DNS points at 127.0.0.1: the
# router does it on the home LAN and Headscale carries the same record for the
# tailnet. The URL keeps the wildcard certificate, while the bytes never leave
# the device - so the manager opens without a VPN and without a round trip to
# another machine. `local_domain` in config.json overrides the derivation.
sub local_domain {
	my $config = eval { &config_reader() } || {};
	my $explicit = $config->{'local_domain'} || '';
	$explicit =~ s/^\s+|\s+$//g;
	return $explicit if $explicit ne '';
	# The name this machine answers on is the honest answer, and it is the one
	# the wildcard covers. A house with no per-device name keeps the older
	# local.<domain> convention.
	my $host = &public_host();
	return $host if length $host;
	my $domain = $config->{'domain'} || '';
	$domain =~ s/^\s+|\s+$//g;
	if ($domain eq '' || $domain =~ /^(?:127\.|localhost$|\[?::1\]?)$/i) {
		my $house = &house_domain();
		return length $house ? 'local.' . $house : '';
	}
	my @labels = split /\./, $domain;
	return $domain if scalar @labels < 2;
	shift @labels;
	return 'local.' . join '.', @labels;
}

1;
