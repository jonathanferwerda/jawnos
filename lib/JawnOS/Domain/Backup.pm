package subs;

# Backup: extracted from subroutines.pl (package subs). Loaded on
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
use Mojo::SQLite;
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $config;
our $database;
our $device;
our $gb;
our $log;
our %m;
our $sync_bucket_band;
our $sync_bucket_low;
our $sync_digest_cache;
our $sync_table_cache;
our $universal_splitter;

# The encrypted SQLite snapshot is the archive / migration / v2 path now. A normal
# delta between peers runs the v3 row stream (`Manager::sync_rows_pull` and the
# `/manager/sync_rows` route), which shares merge_table_rows/merge_finish and never
# builds this temporary database.
#
# A sealed backup is the ciphertext plus its split footer, never the footer
# alone. A failed `openssl enc` used to leave a 96-byte header, which leave()
# then treated as a backup and shredded the database behind it. The restore
# path already refuses a database under 5001 bytes; use the same floor here.
sub backup_sealed_ok($path) {
	return 0 unless defined $path && length $path;
	return 0 unless -e $path && -s $path > 5000;
	return 1;
}

# Backups build a plaintext scratch database in ~/.president/ (see backup_now).
# The normal exits shred it, but a worker killed mid-build - the tree restarts
# on memory pressure, and a full disk kills it the same way - leaves the copy
# behind for good. Sixteen of them (4.5G) had accumulated on the house server
# and filled its disk, which wedged the master: the app could not write its own
# log, so nothing told the person and no restart request could be answered.
# Sweep anything clearly abandoned before the next build. No live build is
# three hours old - a local one takes a minute and a peer export is bounded by
# the ten-minute lock - so this cannot touch a copy still in use.
sub backup_scratch_tidy {
	my $dir = &subs::home('~/.president/');
	return 0 unless -d $dir;
	my $cutoff = time - (3 * 60 * 60);
	my $gone = 0;
	foreach my $f ( glob($dir . '*.sql'), glob($dir . '*.sql-journal') ) {
		my @st = stat $f;
		next unless @st && -f _;
		next unless $st[9] < $cutoff;
		unlink $f;
		$gone++ unless -e $f;
	}
	&subs::log_writer('backup scratch tidy: discarded ' . $gone . ' leftover copy(ies)') if $gone;
	return $gone;
}

sub backup_now {
	my $c = shift;
	my $start_time = &subs::rightNow();
	my $uuid = &subs::random_string_creator(25);
	my $auuid = &subs::random_string_creator(12);
	my $reason = $c->param('reason') || 'unknown';
	# A busy or crashed run must not leave its copy to the next one; this is
	# also the only place an abandoned copy is ever reached on a live machine.
	&backup_scratch_tidy();
	unless ($reason eq 'remote_update') {
		my $html = '<h2>Doing backup</h2>';
		&Websocket::send('tab', { yellow => $html, uuid => $auuid });
	}
	return unless $reason ne 'unknown';
	# A puller that can wait for a slow build asks for it asynchronously (async=1).
	# The request returns as soon as the snapshot row exists, and the puller polls
	# backup_status while the build runs. Older pullers never send the flag and
	# keep the synchronous reply, so a mixed house still syncs.
	my $async = ($reason eq 'remote_update' && ($c->param('async') || '') eq '1') ? 1 : 0;
	my $async_child = $gb::backup_async_child ? 1 : 0;
	if ($async && !$async_child) {
		my $snapshot = &subs::random_string_creator(24);
		my $now = &subs::rightNow();
		&subs::db_query('delete from sync_snapshots where cast(updated as integer) < ?', $now - (6 * 60 * 60 * 1000));
		&subs::db_insert('sync_snapshots', {
			uuid => $snapshot,
			caller => ($c->param('signatorial') || ''),
			state => 'building',
			timestamp => $now,
			server_time => $now,
			updated => $now
		}) or return { status => 'failed', error => 'could not record the snapshot' };
		&subs::subprocessor(sub {
			$gb::backup_async_child = 1;
			$gb::backup_async_snapshot = $snapshot;
			my $result = eval { &subs::backup_now($c) };
			my $err = $@;
			if ($err) {
				$err =~ s/\s+/ /g;
				eval { &subs::db_update('sync_snapshots', { state => 'failed', error => substr($err, 0, 500), updated => &subs::rightNow() }, { uuid => $snapshot }) };
				return;
			}
			if (ref $result eq 'HASH' && ($result->{'status'} || '') eq 'busy') {
				eval { &subs::db_update('sync_snapshots', { state => 'busy', error => 'peer was already exporting', updated => &subs::rightNow() }, { uuid => $snapshot }) };
				return;
			}
			if (ref $result eq 'HASH' && $result->{'archive_path'}) {
				# The puller fetches the file, so the inline copy is not needed - and
				# binary bytes through JSON do not survive the trip.
				delete $result->{'raw_data'};
				my $sha = eval { require Digest::SHA; Digest::SHA->new(256)->addfile($result->{'archive_path'})->hexdigest };
				eval { &subs::db_update('sync_snapshots', {
					state => 'ready',
					job => ($result->{'sync_job'} || ''),
					archive_path => $result->{'archive_path'},
					size => $result->{'size'},
					sha256 => $sha,
					result => encode_json($result),
					updated => &subs::rightNow()
				}, { uuid => $snapshot }) };
				return;
			}
			eval { &subs::db_update('sync_snapshots', { state => 'failed', error => 'no snapshot', updated => &subs::rightNow() }, { uuid => $snapshot }) };
		}, { name => 'remote snapshot', fork => 1 });
		return { status => 'building', job => $snapshot, signatorial => ($c->param('signatorial') || '') };
	}
	# A nightly reconciliation makes every peer ask this machine for its last few
	# days at the same moment; each request builds a windowed copy of every table
	# in memory and vacuums it, so a phone gets several of those at once and the
	# OOM killer takes the tree. One remote export at a time, here on the target:
	# a second caller is told to come back on its next tick instead.
	my $backup_lock;
	my $backup_lock_guard;
	if ($reason eq 'remote_update') {
		# Order by the newest row: a snapshot merge can bring another machine's
		# `remote_backup_lock` row (it is not in the durable settings subset, but a
		# full merge copies every table), and a bare scan returns the oldest one.
		# The claim was written to the newest row, so the confirm below must read
		# that same row or every export loses to a phantom rival and answers busy.
		my $held = &subs::db_query('select value,server_time from settings where app = ? and setting = ? order by cast(server_time as integer) desc limit 1', '__president', 'remote_backup_lock')->hashes->[0];
		# The lock value carries the holding worker's pid. This tree restarts every
		# few minutes under memory pressure, so an export's worker is often gone
		# before the export finishes; a lock whose owner is dead is recovered at
		# once instead of wedging every peer's sync for the full age bound. The age
		# bound stays as the fallback for an owner that is alive but hung.
		my ($held_uuid, $held_pid) = split /:/, ($held->{'value'} || ''), 2;
		my $owner_dead = 0;
		$owner_dead = 1 if ($held_pid && $held_pid =~ /^\d+$/ && $held_pid > 1 && !kill(0, $held_pid));
		my $stale = !$held->{'server_time'} || $held->{'server_time'} + (10 * 60 * 1000) < &subs::rightNow() || $owner_dead;
		if (($held->{'value'} || '') ne '' && ($held->{'value'} || '') ne '0' && !$stale) {
			$log->info('remote backup busy; told ' . $c->tx->remote_address . ' to retry') if $log;
			return { status => 'busy', reason => $reason };
		}
		$backup_lock = $auuid . ':' . $$;
		&subs::setting_setter({ app => '__president', setting => 'remote_backup_lock', value => $backup_lock });
		# two workers can pass the check above in the same instant; the last writer
		# keeps the lock and the loser steps aside rather than run a second export
		my $confirm = &subs::db_query('select value from settings where app = ? and setting = ? order by cast(server_time as integer) desc limit 1', '__president', 'remote_backup_lock')->hashes->[0];
		if (($confirm->{'value'} || '') ne $backup_lock) {
			$log->info('remote backup claim lost to another worker; told ' . $c->tx->remote_address . ' to retry') if $log;
			return { status => 'busy', reason => $reason };
		}
		$backup_lock_guard = Jawn::BackupLock->new($backup_lock);
	}
	# The peer's yellow dot watches this export from the other side, but this
	# machine's own dot should say what it is doing too: a serve job and one step
	# per table.
	my ($sync, $job);
	if ($reason eq 'remote_update') {
		$job = &subs::sync_job_start({
			direction => 'serve',
			peer => $c->tx->remote_address,
			phase => 'export',
			note => 'building a snapshot for a peer'
		});
		$sync = Jawn::SyncJob->new($job);
		&subs::sync_job_step($job, 'export', { label => 'export', state => 'running' });
	}
	# Per-table cuts: a table the caller already holds up to a point is exported
	# only above it. No cuts (an older caller) falls back to the legacy window.
	my $cuts = &subs::sync_map_decode($c->param('cuts'));
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my ($db,$database,$sql) = &subs::database_grabber();
	my $t = localtime;
	my $databaser = $database;
	$databaser =~ s/.db$//gi;
	my $filename = &subs::unformat_name( $databaser );
	$databaser =~ s/_\d+$//;
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
	my $suds = &subs::session_suds($c) || &subs::suds_grabber();
	# Bridge for peers still on the old fixed-key Crypt::Simple: the appended
	# encryption-standard must be readable by their decrypter, which only uses the
	# legacy key (md5 of an empty passphrase). Our decrypter falls back to the same
	# key, so this stays readable by updated peers too. Remove once every device runs
	# the per-secret code.
	my $appendage = $gb::universal_splitter . &subs::encrypter(undef,$encryption_standard);
	my $path = &subs::backups_dir() . '/' . (do { my $n = $databaser; $n =~ s{.*/}{}; $n });
	my $temporary_path = &subs::home('~/.president/') . &subs::random_string_creator() . '.sql';
	# Private from the instant it exists. sqlite3's .backup and the shell's `>`
	# create at 0666 minus the umask, which left a full plaintext copy of the
	# database readable by any local user for the length of the export, and a crash
	# before the shred left it behind. Creating it here fixes the mode, and the
	# chmod also catches a file left by an interrupted run.
	open(my $backup_guard, '>>', $temporary_path);
	close $backup_guard if $backup_guard;
	chmod 0600, $temporary_path;
	my $enc_file = $path . '.enc';
	my $signatorial = &subs::signatorial_designer();
	my $initializer = 1;

	my $size = -s $database;

	my $duration = &subs::rightNow() - $start_time;
#	&appointment_writer($c,{
#		app => 'customs',
#		type => 'backup',
#		timestamp => $timestamp,
#		duration => $duration,
#		file => $path
#	});
	my $warranty = $reason eq 'remote_update' ? &subs::ago_calc('-20m', $timestamp) : &subs::ago_calc(&subs::setting_grabber({ app => 'customs', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', $timestamp);

	my $secret = &subs::decrypter($suds,&subs::db_select('security', ['credential'], { level => 1 })->hash->{credential});

	my $ld_server_time = 0;
	my ($rm,$colour);

	if ($reason eq 'remote_update') {
		$path = &subs::home('~/.president/') . &subs::random_string_creator(21);
		$enc_file = $path . '.enc';

		$rm = &subs::db_select('remote_machines', undef, { signatorial => $c->param('signatorial') })->hashes->[0];
		$rm = &subs::remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
		$colour = $rm->{'data'}->{'manager_colour'};
		my $html = '<h2>Being synced by ' . $rm->{'ip'} || $c->tx->remote_address . '</h2>';
		&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $colour });
		# The completed watermark is `remote_upgraded` (remote_update is the
		# in-flight row), and `server_time` is a millisecond stamp: order it as a
		# number. The old string ordering plus the wrong reason left the window at
		# the 20 s fallback, so a peer that had been away re-pulled a tiny slice
		# while one that was up to date looked behind.
		my $last_updated = &subs::db_query('select * from backups where reason=? and recipient = ? and signatorial = ? order by cast(server_time as integer) DESC limit 1', 'remote_upgraded',$c->param('signatorial'), $signatorial)->hashes->[0];
		my $last_update = 10;
		if (($c->param('full') || '') eq '1') {
			# A migration: read the whole table, not a window. Unlike a gimme this
			# is a real reconciliation, so the caller confirms and advances the
			# watermark (remote_upgrade keeps gimme false for full).
			$last_update = 0;
			$ld_server_time = 0;
		}
		elsif (($c->param('gimme') || '') =~ /^\d{10,}$/) {
			# gimme is a millisecond stamp by the time remote_upgrade sends it
			# (ago_calc on this side). A duration string here is a caller bug, and
			# treating it as a timestamp exported the whole table once; ignore it
			# and let the watermark/cold branch decide.
			$last_update = $c->param('gimme');
			$ld_server_time = $last_update;
		}
		elsif ($last_updated->{'server_time'}) {
			$last_update = $last_updated->{'server_time'};
			$ld_server_time = $last_update;
		}
		else {
			# A peer with no watermark is cold. Exporting every table in full is
			# what let one slow tablet hold this machine's single export lock for
			# minutes at a time (appointments and continent are ~110k rows each),
			# while every other peer was told "already exporting". Bound the first
			# pull to the last day: the nightly three-day reconciliation and a
			# manual gimme are how older rows are reached. Every machine already
			# holds the older history; the rows it is missing are recent.
			$last_update = &subs::rightNow() - (24 * 60 * 60 * 1000);
			$ld_server_time = $last_update;
		}
		$ld_server_time = $ld_server_time - 20000;
		my $tables = `sqlite3 ` . &quote($database) . ' .tables';
		my @tables = sort split ' ', $tables;
		my $schema_file = $temporary_path . '.schema.sql';
		# the statistics and sequence tables are internal: replaying their CREATE is
		# a parse error ("object name reserved for internal use: sqlite_sequence"),
		# and SQLite builds them again where they are wanted
		`sqlite3 ` . &quote($database) . q{ .schema | grep -vE 'sqlite_stat|sqlite_sequence' > } . &quote($schema_file);
		chmod 0600, $schema_file;
		my $command = `sqlite3 ` . &quote($temporary_path) . ' < ' . &quote($schema_file);
		system('shred', '-u', $schema_file);
#		my $backup = `sqlite3 $database .schema $temporary_path`;
		my $tsql = Mojo::SQLite->new('sqlite:' . $temporary_path);
		my $tdb = $tsql->db;

		foreach my $t ( @{$gb::forbidden->{'tables'}} ) {
			@tables = grep { $_ ne $t } @tables;
			$tdb->query('DROP TABLE ' . $t);
		}
		# The snapshot is read once, in bounded rowid batches. Its indexes are
		# pure weight: leaving them on made a few hundred changed rows download
		# as megabytes of B-tree pages.
		my $snapshot_indexes = eval { $tdb->query("select name from sqlite_master where type='index' and name not like 'sqlite_autoindex%'")->hashes } || [];
		foreach my $si ( @{$snapshot_indexes} ) {
			eval { $tdb->query('DROP INDEX ' . $si->{'name'}) };
		}

		my $table_total = scalar @tables;
		my $table_n = 0;
		# One transaction for the whole snapshot. Each row used to commit on its
		# own, so a table the size of settings cost tens of thousands of fsyncs;
		# on a phone that ran past the prefork heartbeat and the worker was
		# restarted in the middle of settings, leaving the export and its lock
		# behind. One commit makes the same copy a fraction of the time.
		my $export_tx = $tdb->begin;
		foreach my $d ( @tables ) {
			next if grep { $_ eq $d } @{$gb::forbidden->{'tables'}};
			$table_n++;
			# A table without a server_time column cannot be windowed, and the query
			# below would die -- which killed the export, left its lock held, and
			# wedged every peer's sync until the ten-minute stale re-claim, over and
			# over. sync_cursors is such a table; guard generically rather than trust
			# every CREATE to carry the column.
			my $has_server_time = &subs::db_query('select name from pragma_table_info(?) where name = ?', $d, 'server_time')->hashes->[0];
			unless ($has_server_time) {
				$tdb->query('DROP TABLE ' . $d);
				next;
			}
			# An explicit cut is the caller's own newest row, so `>` is exact; the
			# legacy window keeps its inclusive 20 s overlap.
			my $has_cut = exists $cuts->{$d};
			my $cut = $has_cut ? $cuts->{$d} : $ld_server_time;
			my $op = $has_cut ? '>' : '>=';
			# Count cheaply, then stream the rows: a full pull of appointments or
			# continent used to materialise the whole table with ->hashes, and the
			# worker died under that allocation (the export then restarted every
			# tick and never finished). One row at a time keeps the memory flat.
			# Window/tab state belongs to the machine that drew it. Carrying it in a
			# snapshot made one machine's Libro Chequing window open on every other
			# machine; the digest already ignores these settings, and the export must
			# too. Everything durable still rides along.
			my $window_state = ($d eq 'settings') ? " and (setting is null or setting not in ('open_tabs','scrollTop','jopen','dimensions'))" : '';
			my $row_total = (&subs::db_query('select count(*) as c from ' . $d . ' where server_time ' . $op . ' ?' . $window_state, $cut)->hashes->[0]->{'c'} || 0) + 0;
			if ($job) {
				&subs::sync_job_step($job, 'export:' . $d, {
					label => 'export ' . $d, state => 'running', current => 0, total => $row_total,
					note => $row_total . ' row' . ($row_total == 1 ? '' : 's')
				});
			}
			if ($row_total > 0) {
	#			$tdb->query('delete from ' . $d . ' where server_time < ?', $ld_server_time);
				my $cursor = &subs::db_query('select * from ' . $d . ' where server_time ' . $op . ' ?' . $window_state, $cut);
				my $copied = 0;
				while (my $nd = $cursor->hash) {
					$tdb->insert($d, $nd);
					$copied++;
					# Keep the job's liveness stamp fresh, but do not go back through
					# database_grabber: its abandoned-statement sweep visits every open
					# handle and finishes THIS still-reading cursor, which ended the copy
					# at exactly 2000 rows no matter how many were left.
					if ($job && ($copied % 2000) == 0) {
						eval { $db->query('update sync_jobs set updated = ? where uuid = ?', &subs::rightNow(), $job) };
						# Keep the export lease young too: a very large table on a slow
						# machine can outlive the ten-minute stale bound, and the lock
						# must not be re-claimed while this worker is still copying.
						eval { $db->query('update settings set server_time = ? where app = ? and setting = ? and value = ?', &subs::rightNow(), '__president', 'remote_backup_lock', $backup_lock) } if $backup_lock;
					}
				}
				$cursor->finish if $cursor && $cursor->can('finish');
			} else {
				$tdb->query('DROP TABLE ' . $d);
			}
			&subs::sync_job_step($job, 'export:' . $d, {
				state => 'done', current => $row_total, total => $row_total
			}) if $job;
			&Websocket::send('tab', {
				yellow => '<h2>Being synced by ' . ($rm->{'ip'} || $c->tx->remote_address) . '</h2>',
				uuid => $auuid, colour => $colour,
				progress => ($table_total > 0 ? int($table_n / $table_total * 100) : 0),
				state => 'running'
			}) if $job;
		}
		$export_tx->commit if $export_tx;
		$tdb->query('VACUUM');

	}
	else {


		&subs::db_query('VACUUM');
		my $backup = `sqlite3 ` . &quote($database) . ' ' . &quote(".backup '$temporary_path'");
		my $tsql = Mojo::SQLite->new('sqlite:' . $temporary_path);
		my $tdb = $tsql->db;
		my $indexes = $tdb->query('select * from sqlite_master where name not like ? and type=?', '%autoindex%', 'index')->hashes;
		foreach my $index ( @{$indexes} ) {
			$tdb->query('DROP INDEX ' .  $index->{'name'});
		}
		$tdb->delete('cache', { context => 'template' });
		$tdb->delete('cache', { context => 'header' });
		$tdb->query('VACUUM');
		# Delete this machine's dated archives beyond its limit. The prune lives
		# beside the limit and the remover so a manual run deletes exactly what
		# the next scheduled backup would.
		&backup_prune();

	}

	# drop this machine's dead references and anyone's stale ones (see
	# backup_registry_prune); the file prune above only knew local paths
	&subs::backup_registry_prune();

	my $archive_path = $path . '_' . $timestamp;
	my $archive_enc = $archive_path . '.enc';
	my $encrypt = &openssl_file_crypt('e', $encryption_standard, $secret, $temporary_path, $archive_enc, 0, 1);
	# Do not append the split footer to a ciphertext that is not there. A bare
	# footer is 96 bytes, which the old code then copied over jawnos.enc and
	# treated as a backup - leave() shredded the only copy of the house behind
	# it. A failed seal keeps the plaintext temporary database until the shred
	# below, and the caller is told not to destroy the live database.
	unless ($encrypt && &backup_sealed_ok($archive_enc)) {
		unlink $archive_enc;
		`shred -u ` . &quote($temporary_path) . '*';
		$log->error('backup: could not seal ' . ($databaser || $database || 'the database') . '; nothing was archived') if $log;
		return { status => 'failed', error => 'could not seal the database' };
	}
	chmod 0600, $archive_enc;
	my $stat_path = `stat $temporary_path`;
	`echo "$appendage" >> $archive_enc`;

	unless ($reason eq 'remote_update') {
		# Stage the stable copy and rename it into place only after its size
		# matches the archive, so a failed copy cannot leave an older
		# jawnos.enc looking like the backup this leave just made.
		my $staged = $enc_file . '.new.' . $$;
		`cp -v $archive_enc $staged`;
		unless (-e $staged && (stat($staged))[7] == (stat($archive_enc))[7]) {
			unlink $staged;
			`shred -u ` . &quote($temporary_path) . '*';
			$log->error('backup: could not stage the sealed copy at ' . $enc_file) if $log;
			return { status => 'failed', error => 'could not copy the sealed backup' };
		}
		chmod 0600, $staged;
		unless (rename $staged, $enc_file) {
			unlink $staged;
			`shred -u ` . &quote($temporary_path) . '*';
			$log->error('backup: could not replace the sealed copy at ' . $enc_file) if $log;
			return { status => 'failed', error => 'could not copy the sealed backup' };
		}
		chmod 0600, $enc_file if -e $enc_file;
	}
	# Leave calls the backup, and its answer is rendered after this: an inline
	# run would reset the request worker's loop and take the gate reply with it.
	&subs::subprocessor(sub {
	    Mojo::IOLoop->reset;
		`shred -u ` . &quote($temporary_path) . '*';
	}, { name => 'backup shredder', fork => 1 });


	&Websocket::send('tab', { type => 'event', timestamp => $timestamp });
	my @folder = split '/', $archive_path;
	my $archive_name = pop @folder;
	my $folder = join '/', @folder;
	@folder = split '/', $path;
	my $current_name = pop @folder;
	my $backup_data = {
		timestamp => $timestamp,
		server_time => $server_time,
		size => $size,
		signatorial => $signatorial,
		destination => $database,
		reason => $reason,
		enc_file => $archive_path . ".enc",
		recipient => $c->param('signatorial'),
		warranty => $warranty,
		uuid => $uuid
	};
	&subs::db_insert('backups',$backup_data) unless $reason eq 'remote_update';
	# The number the person sees is the bytes of the snapshot that actually moved,
	# not this machine's whole database. The row was built before the archive
	# existed and used to record `-s $database` (~180 MB) for every sync, windowed
	# or not; write the encrypted archive's size over it once it is known.
	$size = -s $archive_path . '.enc';
	$backup_data->{'size'} = $size;
	unless ($reason eq 'remote_update') {
		&subs::db_update('backups', { size => $size }, { uuid => $uuid });
	}
	my $raw_data;
	if ($size < 2000000) {
		$raw_data = read_file($archive_path . ".enc");
	}
	# A small remote snapshot rides back inside the JSON body itself, so the file
	# under ~/.president is already redundant: sweep it here rather than leave it
	# for the next boot's ~/.president wipe. A large one is pulled over http, and
	# backup_serve deletes it once it has been served.
	if ($reason eq 'remote_update' && defined $raw_data && $archive_path =~ m{/\.president/} && !$gb::backup_async_child) {
		my $sweep = $archive_path . '.enc';
		`shred -u "$sweep"`;
	}


	my $returner = {
		database => $database,
		signatorial => $signatorial,
		folder => $folder,
		current => $current_name . ".enc",
		archive => $archive_name . ".enc",
		archive_path => $archive_path . ".enc",
		path => $enc_file,
		backup_data => $backup_data,
		misc_settings => &subs::misc_setting_list(),
		home => &subs::home('~/'),
		device => $device,
		server_time => $server_time,
		uuid => $uuid,
		size => $size,
		ld_server_time => $ld_server_time,
		raw_data => $raw_data,
		sync_job => ($job || ''),
	};
	if ($reason eq 'remote_update') {
		$returner->{'update_commands'} = &subs::update_database({ duty => 'list' });
	}
	if ($backup_lock) {
		my $lock_row = &subs::db_query('select value from settings where app = ? and setting = ? order by cast(server_time as integer) desc limit 1', '__president', 'remote_backup_lock')->hashes->[0];
		&subs::setting_setter({ app => '__president', setting => 'remote_backup_lock', value => '' }) if ($lock_row->{'value'} || '') eq $backup_lock;
	}
	&subs::sync_job_step($job, 'export', { state => 'done', current => 1, total => 1 }) if $job;
	$sync->done('done', 'snapshot served') if $sync;
	&Websocket::send('tab', { yellow => 'close', 'close' => 'yes', uuid => $auuid, colour => $colour, state => 'done', progress => 100 });
	return $returner;
}

# A cheap, truthful picture of what this machine's appointments hold, so a peer
# can tell whether it already has everything instead of pulling the window every
# tick. Appointments are only inserted or re-stamped, so if the count and the
# newest server_time are both unchanged there is nothing new to send.
sub appointment_watermark {
	my $row = &db_query('select count(*) as c, coalesce(max(server_time),0) as m from appointments')->hashes->[0];
	return { count => ($row->{'c'} || 0) + 0, max_server_time => ($row->{'m'} || 0) + 0 };
}

# What this machine holds above the watermark a peer already has (its ?since=):
# appointments with a newer server_time. A count, not the rows, so the check
# stays cheap on the two-minute tick; the reconciliation is what moves data.
sub appointments_since {
	my $since = shift;
	return undef unless defined $since && $since =~ /^[0-9]+$/;
	# A NULL or empty status is the common case for a freshly written appointment,
	# and `status != 'deleting'` is NULL (not true) for those rows - so the count
	# came back 0 while the peer plainly held newer appointments, and the caller
	# then skipped the pull and never synced. Include them explicitly.
	my $row = &db_query('select count(*) as c, coalesce(max(server_time),0) as m from appointments where server_time > ? and (status is null or status != ?)', $since, 'deleting')->hashes->[0];
	return { count => ($row->{'c'} || 0) + 0, max_server_time => ($row->{'m'} || 0) + 0, since => $since + 0 };
}

# --- the House digest -------------------------------------------------------
# `server_time` is the write time of every replicated row, so a per-table
# {count, sum(server_time), max} is a cheap fingerprint of the whole table. Two
# machines that hold the same rows have the same fingerprint even when the rows
# arrived by different paths; a machine that was offline and is missing an old
# row has a different count (or sum) and is caught. /remote_auth_test exchanges
# this map, and the caller plans a per-table pull from the difference.
sub durable_settings_where {
	# Settings churn constantly (window geometry, open tabs, timers, remote_*
	# state). Only app configuration may trigger a sync; the export still carries
	# every settings row when a pull happens.
	#
	# `@gb::protected` is the same list merge_database refuses to merge (me, misc,
	# terminal, config, security, ...). Those rows are deliberately local, so a
	# digest over them could never match a peer's: every tick would look like a
	# change and pull the whole settings table forever. Leave them out of the
	# trigger; they still ride along in a snapshot.
	#
	# The exception is a house-wide row (`device = 'all'`). It is not local by
	# definition - every machine reads the same row - and the QA nightly choice is
	# exactly that: a phone saves where the night runs and the table must hear it
	# before 06:00. Without the exception a `__president` house row never moved
	# the digest, so a quiet house could keep the old choice until some unrelated
	# appointment or app setting happened to pull a snapshot.
	#
	# The cards app is protected for its banks and file-browser state, but the
	# tarot mode and variant are house choices a person makes once. They are the
	# app's only per-device rows allowed to start a pull; the draw lists are house
	# rows and already pass above.
	my @apps = ('__president', 'cache', 'websocket_messages', 'ai_budget', 'ai_jobs', 'staged_fixes', 'staged_records', 'staged_appointments', 'sync_log', 'backups', 'sync_jobs', @gb::protected);
	my %seen;
	@apps = grep { !$seen{$_}++ } @apps;
	my $app_list = join ',', map { "'$_'" } @apps;
	# `operator_door` is a trigger on purpose. It carries the embedded device's
	# rotated Now Me pair, and a device that has to fall back to another House
	# machine probes it with that pair. Excluding the row left the fallback
	# holding the previous rotation (or none) until some unrelated setting moved
	# the digest, so a deck whose pair had just been re-issued was denied by a
	# peer that was otherwise live. Including it makes every Now Me rotate the
	# digest and the peers pull the new row on the next tick.
	return "(app not in ($app_list) or device = 'all' or (app = 'cards' and setting in ('mode','variant')))"
		. " and setting not in ('open_tabs','scrollTop','jopen','dimensions','utility_controller','remote_connect_timer','remote_upgrade','remote_backup_lock','remote_auth_probe_timer','ws_pa','chip_chyea','settings_sync_timer','remote_sync_state','log','schema_version','toggle','ci','errors','email_config')"
		. " and setting not like 'remote\\_%' escape '\\'";
}

# How many dated archives this machine keeps.
#
# The Misc setting is stored per device class (mobile, server, computer) and may
# also carry an override for this machine's own signatorial. A machine with
# neither keeps three. Resolved in one place so the prune and the panel cannot
# disagree, and so a missing class row falls through to the next choice instead
# of becoming an accidental 3.
sub backup_limit {
	my $misc = &subs::misc_setting_list();
	foreach my $key ( &subs::signatorial_designer(), &subs::device_setter() ) {
		next unless defined $key && length $key;
		my $value = $misc->{$key}->{'max_backups'};
		return $value + 0 if defined $value && $value =~ /^\d+$/;
	}
	return 3;
}

# Delete the dated archives beyond this machine's limit. Shared by backup_now
# (after the new archive is built) and by an operator run, so the panel, the
# schedule and a manual prune agree on the limit and on what is removed.
#
# Newest first: the newest `limit` archives survive, everything older goes with
# its registry row (and a tombstone, so the deletion syncs). Read in Perl rather
# than through `ls -t`, which word-splits a path with a space and used to leave
# the archive list empty.
sub backup_prune {
	my $database = ( &subs::database_grabber() )[1];
	my $databaser = $database || '';
	$databaser =~ s{.*/}{};
	$databaser =~ s/\.db$//i;
	$databaser =~ s/_\d+$//;
	my $path = &subs::backups_dir() . '/' . $databaser;
	my $enc_file = $path . '.enc';
	my $limit = &backup_limit();
	my @backups = sort { (stat $b)[9] <=> (stat $a)[9] }
		grep { $_ ne $enc_file } glob($path . '_*.enc');
	my $kept = scalar @backups;
	my $removed = 0;
	if ($kept > $limit) {
		for (my $n = $limit; $n < $kept; $n++) {
			my $backs = &subs::db_select('backups', undef, { enc_file => $backups[$n] })->hashes || [];
			foreach my $ba ( @{$backs} ) {
				&subs::deletion_registration({ table => 'backups', uuid => $ba->{'uuid'}, scope => 'single', server_time => $ba->{'server_time'} });
			}
			&subs::db_delete('backups', { enc_file => $backups[$n] });
			$removed++ if &backup_prune_remove($backups[$n]);
		}
	}
	return { limit => $limit, seen => $kept, kept => ($kept > $limit ? $limit : $kept), removed => $removed };
}

# Delete one dated archive.
#
# `shred -u` is the right tool where the platform has it; Termux does not, and
# the prune used to trust it anyway. The rows were already deleted, so the
# deletion looked done while the file stayed on disk - the phone reached 108
# archives against a limit of 20, 17GB in database/backups. The unlink is the
# answer that always works; shred is only the extra pass.
# The secure-delete tool this platform has, or '' when it has none (Termux).
# Resolved once per call: a prune is rare, and a path that exists is cheaper
# than a PATH search.
sub backup_shred_tool {
	foreach my $candidate ( '/usr/bin/shred', '/bin/shred' ) {
		return $candidate if -x $candidate;
	}
	my $found = `command -v shred 2>/dev/null`;
	chomp $found if defined $found;
	return (defined $found && length $found) ? $found : '';
}

sub backup_prune_remove {
	my ($file) = @_;
	return 0 unless defined $file && length $file;
	my $shred = &backup_shred_tool();
	system($shred, '-u', $file) if $shred ne '';
	unlink $file if -e $file;
	return (-e $file) ? 0 : 1;
}

sub sync_table_list {
	return $sync_table_cache if $sync_table_cache;
	my @tables;
	my %forbidden = map { $_ => 1 } @{ $gb::forbidden->{'tables'} || [] };
	foreach my $row ( @{ &db_query('select name from sqlite_master where type = ?', 'table')->hashes || [] } ) {
		my $t = $row->{'name'} || '';
		next if $t eq '' || $t =~ /^sqlite_/ || $forbidden{$t} || $t eq 'sync_jobs';
		my $has = &db_query('select name from pragma_table_info(?) where name = ?', $t, 'server_time')->hashes->[0];
		push @tables, $t if $has;
	}
	$sync_table_cache = \@tables;
	return $sync_table_cache;
}

sub sync_table_digest {
	my ($table, $durable) = @_;
	my $sql_table = $table eq 'settings_durable' ? 'settings' : $table;
	my $where = '';
	if ($sql_table eq 'appointments') { $where = " where (status is null or status != 'deleting')"; }
	elsif ($table eq 'settings_durable') { $where = ' where ' . &durable_settings_where(); }
	my $row = &db_query("select count(*) as c, coalesce(sum(cast(server_time as integer)),0) as s, coalesce(max(server_time),0) as m from $sql_table$where")->hashes->[0] || {};
	return { count => ($row->{'c'} || 0) + 0, sum => ($row->{'s'} || 0) + 0, max => ($row->{'m'} || 0) + 0 };
}

sub sync_bucket_normalize {
	my ($band) = @_;
	return $sync_bucket_band unless defined $band && $band =~ /^\d+$/ && $band > 0;
	return $band + 0;
}

sub sync_table_buckets {
	my ($table, $band) = @_;
	$band = &sync_bucket_normalize($band);
	my $sql_table = $table eq 'settings_durable' ? 'settings' : $table;
	my $where = '';
	if ($sql_table eq 'appointments') { $where = " where (status is null or status != 'deleting')"; }
	elsif ($table eq 'settings_durable') { $where = ' where ' . &durable_settings_where(); }
	my $rows = &db_query("select case when cast(server_time as integer) < 0 then 0 else cast(cast(server_time as integer) / $band as integer) end as b, count(*) as c, coalesce(sum(cast(server_time as integer)),0) as s, coalesce(max(server_time),0) as m from $sql_table$where group by b order by b")->hashes || [];
	my %buckets;
	foreach my $r (@{$rows}) {
		my $b = defined $r->{'b'} ? ($r->{'b'} + 0) : 0;
		$buckets{$b} = { count => ($r->{'c'} || 0) + 0, sum => ($r->{'s'} || 0) + 0, max => ($r->{'m'} || 0) + 0 };
	}
	return { band => $band, buckets => \%buckets };
}

sub sync_bucket_diff {
	my ($base, $now) = @_;
	return [] unless ref $base eq 'HASH' && ref $now eq 'HASH';
	my @moved;
	foreach my $b (keys %{$now}) {
		my $old = $base->{$b};
		unless (ref $old eq 'HASH') { push @moved, $b; next; }
		my $new = $now->{$b};
		next if (($old->{'count'} || 0) == ($new->{'count'} || 0)
			&& ($old->{'sum'} || 0) == ($new->{'sum'} || 0)
			&& ($old->{'max'} || 0) == ($new->{'max'} || 0));
		push @moved, $b;
	}
	return [ sort { $b <=> $a } @moved ];
}

sub sync_bands_peer {
	my ($version, $flag) = @_;
	return 1 if $flag;
	return 0 unless defined $version && $version =~ /^\d+(?:\.\d+)*$/;
	return &version_cmp($version, '0.1.1036') >= 0 ? 1 : 0;
}

sub sync_bucket_range {
	my ($band, $b) = @_;
	$band = &sync_bucket_normalize($band);
	$b = 0 unless defined $b && $b =~ /^-?\d+$/;
	$b += 0;
	my $from = ($b <= 0) ? $sync_bucket_low : $b * $band;
	my $to = ($b + 1) * $band;
	return ($from, $to);
}

sub sync_digest_map {
	my ($force) = @_;
	# The digest is a count/sum/max scan per table, and the reconnector asks for
	# it every tick. A short process cache keeps that from becoming a full scan
	# of appointments on every handshake; 30s is well inside one sync window, so
	# a change still starts a pull on the next tick after it lands.
	my $now = &rightNow();
	return $sync_digest_cache->{'map'}
		if (!$force && $sync_digest_cache && ($now - $sync_digest_cache->{'at'}) < 30000);
	# Not every column of every table is a reason to sync. `backups` is the sync's
	# own bookkeeping (a pull writes a row on both sides, so including it would
	# trigger the next pull forever), the AI day's purse is small bookkeeping, and
	# the location/notification streams move constantly without being a person's
	# change. Those still ride along inside any snapshot; they just cannot start
	# one by themselves. Appointments and durable settings are the triggers, and
	# so is the AI ledger: ai_jobs carries the evaluation dispatch and ai_house the
	# liveness it is addressed by, so a quiet house must still pull them when they
	# move (they are a few small rows).
	my %skip = map { $_ => 1 } qw(backups ai_budget ai_spend continent notifications);
	my %map;
	foreach my $t ( @{ &sync_table_list() } ) {
		next if $t eq 'settings' || $skip{$t};
		$map{$t} = &sync_table_digest($t);
	}
	$map{'settings_durable'} = &sync_table_digest('settings_durable');
	$sync_digest_cache = { at => $now, map => \%map };
	return \%map;
}

sub sync_table_above {
	my ($table, $cut) = @_;
	return undef unless defined $cut && $cut =~ /^[0-9]+$/;
	my $sql_table = $table eq 'settings_durable' ? 'settings' : $table;
	my $where = ' where server_time > ?';
	if ($sql_table eq 'appointments') { $where .= " and (status is null or status != 'deleting')"; }
	elsif ($table eq 'settings_durable') { $where .= ' and ' . &durable_settings_where(); }
	my $row = &db_query("select count(*) as c, coalesce(sum(cast(server_time as integer)),0) as s, coalesce(max(server_time),0) as m from $sql_table$where", $cut)->hashes->[0] || {};
	return { count => ($row->{'c'} || 0) + 0, sum => ($row->{'s'} || 0) + 0, max => ($row->{'m'} || 0) + 0 };
}

# Held for the life of a remote export. Releasing in DESTROY means the lock is
# cleared even when backup_now dies part-way, not only on its normal return.
#
# It lives here, beside the backup_now that blesses it, and must not be moved
# to another domain module: the Loader loads Backup.pm for `backup_now` alone,
# so a worker serving a peer's export has never seen those other files. The
# class used to sit in Domain/Ble2.pm, which only a Bluetooth/embedded call
# loads, and the export then died with "Can't locate object method \"new\" via
# package \"Jawn::BackupLock\"" at the line below - the tablet hit that on
# 2026-11-01 and every snapshot pull (the Upgrade button, a nightly deep sync)
# failed while the v3 row stream carried on. A package one call needs must be
# defined in the file the Loader names for that call.
{
	package Jawn::BackupLock;
	sub new { my ($class,$val) = @_; return bless { val => $val }, $class; }
	sub release {
		my $self = shift;
		return unless $self->{'val'};
		my $val = $self->{'val'};
		$self->{'val'} = undef;
		eval {
			my $row = &subs::db_query('select value from settings where app = ? and setting = ? order by cast(server_time as integer) desc limit 1', '__president', 'remote_backup_lock')->hashes->[0];
			&subs::setting_setter({ app => '__president', setting => 'remote_backup_lock', value => '' }) if (($row->{'value'} || '') eq $val);
		};
	}
	sub DESTROY { my $self = shift; $self->release; }
}

1;
