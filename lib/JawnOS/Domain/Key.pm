package subs;

# Key: extracted from subroutines.pl (package subs). Loaded on
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

our %M;
our $config;
# One stable id per construct, independent of the name and of the device. The
# per-device `uuid` settings rows are the membership references and stay as
# they are; this is the id a name resolves to, and what an appointment carries
# (app_uuid) so a rename is not an identity change. Created lazily and memoised
# for the life of this worker.
our %construct_uuid_memo;
our $database;
our $database_holder;
our $device;
our $find_program;
our $gb;
# Resolve ~ once; this used to shell out to `echo $HOME` on every call. That
# helper is hit constantly (every settings/cache/db path), so caching it avoids
# a fork+exec per call.
our $home_dir;
our $ide_files;
our $install_dir;
our $log;
our %m;
our %setting_memo;

sub key_push_one {
	my ($rm, $proved) = @_;
	return unless $rm && $rm->{'signatorial'} && defined $proved && length $proved;
	my $manager = $rm->{'manager'};
	$manager = 'https://' . $rm->{'ip'} . ':' . ($rm->{'port'} || '45545') unless $manager;
	return unless $manager;
	my $ua = Mojo::UserAgent->new();
	$ua->max_response_size(0);
	$ua->insecure(1);
	$ua->on(start => sub { my ($ua, $tx) = @_; &peer_sign_request($tx->req); });
	my $url = $manager . '/manager/key_push';
	my $res = eval { $ua->inactivity_timeout(20)->post($url => form => { signatorial => &signatorial_designer(), proved => $proved })->result };
	return unless $res && $res->is_success;
	my $json = eval { decode_json $res->body };
	return unless $json;
	return { ok => $json->{'ok'} ? 1 : 0, already => $json->{'already'} ? 1 : 0, error => $json->{'error'} };
}

# The queue's half: push the envelope to every machine with a pinned key. The
# result names what happened; machines that do not answer ride the pull path
# instead, the next time their database syncs the new canary in.
sub key_push_job {
	my ($job, $data) = @_;
	my $env = &key_push_envelope();
	unless ($env) { $job->fail('nothing to push: no wrapped old key on this machine'); return }
	my $me = &signatorial_designer();
	# the route pushes to everyone; a driver may name the peers it wants (so a
	# probe never hands a probe key to the real machines)
	my %only = map { $_ => 1 } @{ (ref $data->{'only'} eq 'ARRAY') ? $data->{'only'} : [] };
	my $rms = &db_select('remote_machines')->hashes || [];
	my $summary = { asked => 0, ok => 0, refused => 0, unreachable => 0 };
	foreach my $rm ( @{$rms} ) {
		my $rsig = $rm->{'signatorial'};
		next unless $rsig && $rsig ne $me;
		next if (scalar keys %only) && !$only{$rsig};
		next unless $rm->{'pubkey'};
		next unless $rm->{'manager'} || $rm->{'ip'};
		$summary->{asked}++;
		my $got = eval { &key_push_one($rm, $env->{'proved'}) };
		if ($got && ($got->{'ok'} || $got->{'already'})) { $summary->{ok}++; }
		elsif ($got) { $summary->{refused}++; }
		else { $summary->{unreachable}++; }
	}
	$job->note(progress => 'key pushed: ' . $summary->{ok} . ' took it, ' . $summary->{refused} . ' on another key, ' . $summary->{unreachable} . ' not answering');
	$job->finish($summary);
}

# Every job the queue can run, in one place. The worker and the code that
# enqueues register the same list, so a name can never drift between them.
sub minion_task_list {
	return {
		archive_transfer => \&archive_transfer_job,
		archive_manifest_rescan => \&archive_manifest_rescan_job,
		archive_fetch_home => \&archive_fetch_home_job,
		folders_copy => \&folders_copy_job,
		folders_encrypt => \&folders_encrypt_job,
		folders_decrypt => \&folders_decrypt_job,
		folders_reseal => \&folders_reseal_job,
		key_push => \&key_push_job,
		appointment_evaluation => \&appointment_evaluation_job
	};
}

sub home {
	my ($inhabitant) = @_;
	unless (defined $home_dir) {
		$home_dir = $ENV{HOME};
		if (!defined $home_dir || $home_dir eq '') {
			$home_dir = (getpwuid($<))[7] || '';
		}
	}
	$inhabitant =~ s/~/$home_dir/;
	return $inhabitant;
}

sub newest_folder_checker {
	my $newest = 0;
	my %skip = map { $_ => 1 } qw(.git .pio build node_modules .shots icons);
	find({
		preprocess => sub { return grep { !$skip{$_} } @_ },
		wanted     => sub {
			return unless -f $_;
			my $m = (stat($_))[9] || 0;
			$newest = $m if $m > $newest;
		},
	}, './');
	return $newest * 1000;
}

sub dir_listing {
	my ($dirs, $files_only) = @_;
	my @dirs = grep { defined $_ && length $_ } @{ $dirs || [] };
	return () unless @dirs;
	my @out;
	my $listed = 0;
	my $find = &find_program();
	if ($find) {
		# find(1)'s -type f skips symlinks, so ask for links too and let the -f
		# test below follow them, the way File::Find's wanted did
		my @sel = $files_only ? ('(', '-type', 'f', '-o', '-type', 'l', ')') : ();
		if (open(my $fh, '-|', $find, @dirs, @sel, '-print0')) {
			$listed = 1;
			local $/ = "\0";
			while (defined(my $path = <$fh>)) {
				chop $path;
				push @out, $path if length $path;
			}
			close $fh;
		}
	}
	unless ($listed) {
		find({ no_chdir => 1, wanted => sub { push @out, $File::Find::name } }, @dirs);
	}
	return $files_only ? (grep { -f $_ } @out) : @out;
}

sub find_program {
	return $find_program if defined $find_program;
	for my $dir (split /:/, ($ENV{'PATH'} // '/usr/bin:/bin')) {
		my $candidate = "$dir/find";
		if (-x $candidate) { $find_program = $candidate; last }
	}
	$find_program = '' unless defined $find_program;
	return $find_program || undef;
}

sub ide_folder_listing {
	my ($folder) = @_;
	$folder = './' unless defined $folder && length $folder;
	my $dir = $folder;
	$dir =~ s{/+$}{};
	$dir = '.' if $dir eq '' || $dir eq '.';
	my $prefix = ($dir eq '.') ? '' : $dir . '/';
	opendir(my $dh, $dir) or return [];
	my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
	closedir $dh;
	my $tree = [];
	foreach my $name ( sort { lc $a cmp lc $b } @entries ) {
		my $path = $prefix . $name;
		my $temp = { file => $path, type => 'file' };
		my @stat = stat($path);
		my @temp_split = split '/', $path;
		$temp->{'short_name'} = $temp_split[-1];
		pop @temp_split;
		$temp->{'root_count'} = @temp_split;
		$temp->{'location'} = join '/', @temp_split;
		$temp->{'size'} = $stat[7];
		$temp->{'modified'} = $stat[9];
		$temp->{'created'} = $stat[10];
		$temp->{'accessed'} = $stat[8];
		$temp->{'type'} = 'folder' if -d $path;
		push @{$tree}, $temp;
	}
	return $tree;
}

sub ide_files {
	my $folder = shift;
	$ide_files = [];
	foreach my $name ( &dir_listing([$folder]) ) { $name =~ s/^\.\///g; push @{$ide_files}, $name }
	my $tree = [];
	foreach my $f (@{$ide_files}) {
		my $temp = { file => $f, type => 'file' };
		my @stat = stat($f);
		my @folder_split = split '/', $f;
		my @temp_split = @folder_split;
		$temp->{'short_name'} = $temp_split[-1];
		pop @temp_split;
		$temp->{'root_count'} = @temp_split;
		$temp->{'location'} = join '/', @temp_split;
		$temp->{'size'} = $stat[7];
		$temp->{'modified'} = $stat[9];
		$temp->{'created'} = $stat[10];
		$temp->{'accessed'} = $stat[8];
		if ( -d $f) {
			$temp->{'type'} = 'folder';
		}
		push @{$tree}, $temp;
	}
	return $tree;
}

sub install_dir { return $install_dir }

sub database_dir {
	my $dir = &subs::install_dir() . '/database';
	unless (-d $dir) { require File::Path; eval { File::Path::make_path($dir) }; }
	return $dir;
}

sub database_path { return &subs::database_dir() . '/jawnos.db' }

sub backups_dir {
	my $dir = &subs::database_dir() . '/backups';
	unless (-d $dir) { require File::Path; eval { File::Path::make_path($dir) }; }
	return $dir;
}

# A house with a way back in starts gated. The paper recovery code is the
# emergency door, so a house that has one gets the padlock row, General as its
# context, and Enforce as the mode the first time this runs, then the marker
# makes it a default rather than a policy: Turn the gate off stays off across
# restarts. A fresh house with no way in is left alone, because turning its
# gate on before there is a way in would lock it out - a paper recovery code or
# an already-paired phone is that way in.
sub padlock_seed_default {
	# An app padlock never survives a restart. The token lives in one window;
	# a tree that has just come up has no such window, and a grant left behind
	# would let a reopened gallery, music or folders window list the sealed
	# things without a fresh print. The old house-wide secret is cleared too.
	&subs::db_query('delete from cache where context = ?', 'media_unlock');
	&subs::db_query('delete from settings where setting = ? and app in (?,?,?)', 'combo_unlock', 'gallery', 'music', 'folders');
	return if (&subs::setting_grabber({ app => '__president', setting => 'padlock_gate_initialized' }) || '') eq 'yes';
	my $recovery = &subs::db_query('select server_time from settings where app = ? and setting = ? order by server_time desc limit 1', '__president', 'recovery')->hashes->[0];
	my $paired = &subs::db_select('paired_devices', undef, { status => 'active' })->hashes->[0];
	return unless $recovery || $paired;
	my $now = &subs::rightNow();
	my $padlock = &subs::db_select('security', undef, { level => 'padlock' })->hashes->[0];
	unless ($padlock) {
		&subs::db_insert('security', { level => 'padlock', credential => '', timestamp => $now, server_time => $now, uuid => &subs::random_string_creator(30) });
	}
	# A fresh gate gets a full inactivity window: the timer needs a baseline, and
	# without one a request would read as an expired lock and shut the house.
	my $pl = &subs::db_query('select server_time from settings where app = ? and setting = ? limit 1', '__president', 'pl_time')->hashes->[0];
	unless ($pl) {
		my $window = &subs::setting_grabber({ app => 'me', setting => 'activity_timeout' }) || '-2h';
		$window = abs &subs::time_abbrev_translator($window);
		&subs::setting_setter({ app => '__president', setting => 'pl_time', value => $now + $window });
	}
	my $contexts = eval { return decode_json &subs::setting_grabber({ app => '__president', setting => 'padlock_contexts' }) } || [];
	unless (scalar @{$contexts}) {
		&subs::setting_setter({ app => '__president', setting => 'padlock_contexts', value => '["general"]' });
	}
	my $mode = &subs::setting_grabber({ app => '__president', setting => 'padlock_gate' });
	unless (defined $mode && length $mode) {
		&subs::setting_setter({ app => '__president', setting => 'padlock_gate', value => 'enforce' });
	}
	&subs::setting_setter({ app => '__president', setting => 'padlock_gate_initialized', value => 'yes' });
}

# One machine, one database: anything else under database/ is an older
# database's leftover (server.enc, laptop_*.enc, a stray .db) and is discarded.
# The working set is the jawnos database and its sidecars, the factory seed, the
# schema, and the jawnos backups - everything else is shredded. Directories are
# never touched, so the backups/ dir itself is safe.
sub database_tidy {
	my $dir = &subs::database_dir();
	my $backups = &subs::backups_dir();
	my @gone;
	foreach my $f ( glob("$dir/*") ) {
		next if $f =~ m{/(?:jawnos\.db(?:-shm|-wal)?|schema\.sql|initial\.enc|backups)$};
		push @gone, $f;
	}
	foreach my $f ( glob("$backups/*") ) {
		next if $f =~ m{/jawnos(?:_\d+)?\.enc$};
		push @gone, $f;
	}
	@gone = grep { !-d $_ } @gone;
	foreach my $f ( @gone ) {
		`shred -u "$f" 2>/dev/null`;
		unlink $f;
	}
	&subs::log_writer('database tidy: discarded ' . scalar(@gone) . ' leftover file(s)') if scalar @gone;
	return scalar @gone;
}

# Adopt a pre-fixed-path install: move the database the old scan would have
# chosen, and the .enc backups beside it, into database/. Runs once, and only
# when the fixed database is missing, so pulling this build onto an existing
# machine needs no hand - the first database_grabber migrates it in place.
sub database_adopt_legacy {
	# A name change needs its own step first: a machine that already migrated into
	# the install still has database/initial.db (and initial*.enc backups) from
	# before the house took its own name, so rename those to jawnos.db /
	# jawnos*.enc. Without this the fixed path simply does not exist and the
	# machine is left with no database at all.
	my $dir_db = &subs::database_dir();
	if (-e "$dir_db/initial.db" && !-e "$dir_db/jawnos.db") {
		for my $ext ('', '-shm', '-wal') {
			rename "$dir_db/initial.db$ext", "$dir_db/jawnos.db$ext" if -e "$dir_db/initial.db$ext";
		}
	}
	my $bdir = &subs::backups_dir();
	foreach my $enc ( glob("$bdir/initial*.enc") ) {
		my $leaf = $enc;
		$leaf =~ s{.*/}{};
		$leaf =~ s/^initial/jawnos/;
		rename $enc, "$bdir/$leaf" if !-e "$bdir/$leaf";
	}

	my $dir = &subs::home($config->{'start_dir'} || '~/');
	$dir =~ s{/+$}{};
	my @dbs = grep { -s $_ > 5000 && $_ !~ /-(?:shm|wal)$/ } glob("$dir/*.db");
	return unless scalar @dbs;
	my ($legacy) = sort { (-M $b) <=> (-M $a) } @dbs;
	my $target = &subs::database_path();
	my $base = $legacy;
	$base =~ s{.*/}{};
	$base =~ s/\.db$//i;
	`mv -f "$legacy" "$target" 2>/dev/null`;
	`mv -f "$legacy-shm" "$target-shm" 2>/dev/null`;
	`mv -f "$legacy-wal" "$target-wal" 2>/dev/null`;
	my $backups = &subs::backups_dir();
	# the working database is jawnos.db now, so the legacy backups are renamed as
	# they move in (initial_<ts>.enc -> jawnos_<ts>.enc)
	foreach my $enc ( glob("$dir/$base*.enc") ) {
		my $leaf = $enc;
		$leaf =~ s{.*/}{};
		$leaf =~ s/^\Q$base\E/jawnos/;
		`mv -f "$enc" "$backups/$leaf" 2>/dev/null`;
	}
	&subs::log_writer('database adopted into the install: ' . $target);
	return $target;
}

sub database_grabber {
	my $connection = shift || '';
	# A forked child inherits the parent's handle. Detach it so our exit cannot
	# close a connection the parent is still using, then dial our own below.
	if (defined $gb::database_holder->{'pid'} && $gb::database_holder->{'pid'} != $$ && defined $gb::database_holder->{'sql'} ) {
		$gb::database_holder->{'sql'}->db->dbh->{InactiveDestroy} = 1;
		$gb::database_holder = {};
	}
	# One connection per process, not per call: opening the file costs about two
	# milliseconds, which every database touch of every request used to pay, while
	# a kept handle costs microseconds. Three rules keep it safe. It is only reused
	# by the process that opened it (pid). It is only reused while the same file is
	# still in place (dev+ino) - the database is shredded and replaced on leave, and
	# a handle on the old inode would quietly serve a dead file. And before it is
	# handed on, whatever the previous caller left unfinished is finished: a results
	# object that was never fetched from pins the connection's read snapshot, and
	# that is what stopped the WAL checkpointing and grew it to the size of the
	# database once. The callers here fetch their rows before making the next
	# database call, so nothing live is cut short.
	my $holder = $gb::database_holder;
	if ($holder->{'pid'} && $holder->{'pid'} == $$ && $holder->{'db'} && $holder->{'dbh'} && $holder->{'dev'}) {
		my @stat = stat($holder->{'database'});
		if (@stat && $stat[0] == $holder->{'dev'} && $stat[1] == $holder->{'ino'}) {
			# Only when a statement is actually abandoned: ActiveKids is a cheap
			# DBI counter, zero once every result has been fetched, while
			# visit_child_handles walks every child handle ever made on the
			# connection. The callers fetch their rows before the next call, so
			# on the common path there is nothing here to finish.
			eval { $holder->{'dbh'}->visit_child_handles(sub { my $sth = shift; $sth->finish }) }
				if $holder->{'dbh'}->{ActiveKids};
			return ($holder->{'db'}, $holder->{'database'}, $holder->{'sql'});
		}
	}
	# One machine, one database, at its fixed install path - no scan for the
	# newest .db, so a stray file can never become the database. An older build
	# kept it under start_dir, so the first run after this one adopts that.
	my $database = &subs::database_path();
	unless (-e $database) { &subs::database_adopt_legacy(); }

	if ($database && -e $database && -s $database > 5000) {

		my $sql = Mojo::SQLite->new('sqlite:' . $database, sqlite_use_immediate_transaction => 0);
		$sql->options({AutoCommit => 1 });
		my $db = $sql->db;
		my @stat = stat($database);
		# The handle and its dbh are kept on the holder: the pid so a forked child
		# knows to detach rather than share it, the dbh so the reuse guard above can
		# finish its abandoned statements, and dev+ino so a replaced file is noticed.
		# hooks.pl also looks here to tell that a database is up.
		$gb::database_holder = {
			server_time => &subs::rightNow(),
			database => $database,
			db => $db,
			dbh => $db->dbh,
			sql => $sql,
			pid => $$,
			dev => $stat[0],
			ino => $stat[1]
		};
		# Wait for other writers before anything else. SQLite's default is not to
		# wait at all, so any contention surfaced as an immediate "database is locked",
		# and even reading the journal mode below can meet a writer. Each is eval'd
		# because a transient lock must not take the request down with it.
		eval { $db->query('PRAGMA busy_timeout=15000;'); };
		eval { $db->query('PRAGMA synchronous=NORMAL;'); };
		# WAL is a property of the file rather than of the connection, so it only has
		# to be set once - it is already on for an existing database, and re-issuing
		# it every dial just took a write lock for nothing.
		eval {
			my $row = $db->query('PRAGMA journal_mode;')->hashes->[0] || {};
			$db->query('PRAGMA journal_mode=WAL;') if (($row->{'journal_mode'} || '') ne 'wal');
		};
		# The rest of the tuning only makes sense on a handle that lives past one
		# call: a page cache, sorts in memory, a read-only mapping of the file, and
		# a cap on the WAL. A handheld runs a score of these handles at once, so it
		# gets a smaller cache and mapping than a server: the 8MB/128MB pair cost a
		# tablet ~150MB of page cache across its workers that it never warms.
		my $mobile = &device_setter() eq 'mobile';
		eval { $db->query('PRAGMA cache_size=' . ($mobile ? -2000 : -8000) . ';'); };
		eval { $db->query('PRAGMA temp_store=MEMORY;'); };
		eval { $db->query('PRAGMA mmap_size=' . ($mobile ? 33554432 : 134217728) . ';'); };
		# Keep the write-ahead log small. A checkpoint that resets the WAL truncates
		# the file to this many bytes, so the cap IS the steady-state size - at 32MB
		# every machine carried a 32MB -wal beside its database (the health read
		# reports it now). 4MB matches the ~1000-page autocheckpoint, so the file is
		# reclaimed often without being truncated to nothing on every write.
		eval { $db->query('PRAGMA journal_size_limit=4194304;'); };
		return ($db,$database,$sql);
	}
	$gb::database_holder = {};
	return (undef,undef,undef);
}

sub dbs_insert {
  # Legacy name kept for the device scripts: inserts used to be posted through
  # the memory mirror's socket, and now they go straight to the database.
  my $success = &db_insert(@_);
  return $success ? $success->last_insert_id : undef;
}

sub construct_uuid {
	my ($app) = @_;
	return '' unless defined $app && length $app;
	return $construct_uuid_memo{$app} if $construct_uuid_memo{$app};
	my $uuid = &setting_grabber({ app => $app, setting => 'construct_uuid', device => 'all' });
	return $construct_uuid_memo{$app} = $uuid if defined $uuid && length $uuid;
	my $person = eval { &db_query('select uuid from people where app = ? limit 1', $app)->hashes->[0] };
	$uuid = $person->{'uuid'} if $person && $person->{'uuid'};
	unless (defined $uuid && length $uuid) {
		my $row = eval { &db_query("select value from settings where app=? and setting='uuid' order by server_time asc limit 1", $app)->hashes->[0] };
		$uuid = $row->{'value'} if $row && $row->{'value'};
	}
	$uuid = substr(&sha256_hex('jawnos-construct' . "\x1f" . $app), 0, 25) unless defined $uuid && length $uuid;
	&setting_setter({ app => $app, setting => 'construct_uuid', device => 'all', value => $uuid });
	return $construct_uuid_memo{$app} = $uuid;
}

sub db_insert {
	my $table = shift;
	my $data = shift;
	%setting_memo = () if ($table // '') eq 'settings';
	# An appointment names its construct by both the label and the stable id, so
	# a later rename (or two same-named constructs) never confuses the row.
	if ($table eq 'appointments' && !defined $data->{'app_uuid'} && defined $data->{'app'} && length $data->{'app'}) {
		$data->{'app_uuid'} = &construct_uuid($data->{'app'});
	}
	$data->{'ost'} = $data->{'ost'} || &rightNow();
	$data->{'server_time'} = $data->{'server_time'} ? $data->{'server_time'} : $data->{'ost'};
	$data->{'uuid'} = &random_string_creator(15) unless $data->{'uuid'};
	my ($db,$database,$sql) = &database_grabber();
	return unless $db;
	my $success;
	my $count = 0;
	# Whether the insert landed is the insert's own row count, not
	# last_insert_id: a refused write answers zero rows while last_insert_id
	# is either zero on a fresh connection or, worse, the *previous* insert's
	# id - which is how a refused write came back looking like a success and
	# was retried until the driver had complained twenty-five times. A retry
	# is for a statement that would not run at all, and it stays bounded.
	until ($success || $count >= 25) {
		my $results = eval { return $db->insert($table, $data); };
		if ($@) {
			# A refused insert used to vanish here: the caller's eval caught the
			# die, the row simply did not arrive, and a merge reported a table as
			# complete. Name the table and the reason instead.
			&log_writer('db_insert ' . $table . ' failed: ' . ($@ =~ s/\s+/ /gr));
		}
		if ($results && $results->rows) {
			$success = $results;
		}
		elsif ($results) {
			# the statement ran and was refused; asking again will not help
			last;
		}
		$count++;
	}
	&db_cache_updater($table, $data);
	return $success;
}

sub db_query {
	my $query = shift;
	my @params = @_;
	my ($db,$database,$sql) = &database_grabber();

	return eval { return $db->query($query, @params)  } if $db;
}

# The rows from a query as a plain arrayref of hashes - what db_query's
# ->hashes gives back, but over the shared handle with a statement cache and
# without the Mojo::SQLite::Results object and its per-call finalize. The hot
# readers (log_reader's per-poll selects) only ever ask for ->hashes, and that
# wrapper was a measurable slice of the poll. Anything needing more of the
# Results API still goes through db_query.
sub db_raw {
	my $query = shift;
	my @params = @_;
	my ($db) = &database_grabber();
	return [] unless $db;
	my $sth = eval { $db->dbh->prepare_cached($query) };
	return [] unless $sth;
	# Mojo::SQLite tolerated a bind count that did not match the placeholders
	# (some call sites interpolate a value into the SQL and then pass it as a bind
	# too, and one builds one clause too many); a direct execute fails on either
	# mismatch. Trim extras and NULL-fill any shortfall so the result matches what
	# the same SQL returned through db_query.
	my $n = $sth->{NUM_OF_PARAMS};
	if (defined $n) {
		splice(@params, $n) if @params > $n;
		push @params, undef while @params < $n;
	}
	return [] unless eval { $sth->execute(@params); 1 };
	my $rows = eval { $sth->fetchall_arrayref({}) };
	# finish it: a statement left active pins the connection's read snapshot in
	# SQLite, so later reads would see the world as it was here, not as it is
	eval { $sth->finish };
	return $rows || [];
}

# db_raw's fresh twin: the same read, but on a freshly prepared statement, so it
# cannot inherit a cached handle that a dead request left executed-but-unfetched
# - such a handle answers 0 rows to every later read of the same SQL, and the
# mailbox threads hit exactly that. A fresh prepare costs microseconds, which
# the once-per-render readers can spare; the per-poll hot paths stay on db_raw.
sub db_fresh {
	my $query = shift;
	my @params = @_;
	my ($db) = &database_grabber();
	return [] unless $db;
	my $sth = eval { $db->dbh->prepare($query) };
	return [] unless $sth;
	my $n = $sth->{NUM_OF_PARAMS};
	if (defined $n) {
		splice(@params, $n) if @params > $n;
		push @params, undef while @params < $n;
	}
	return [] unless eval { $sth->execute(@params); 1 };
	my $rows = eval { $sth->fetchall_arrayref({}) };
	eval { $sth->finish };
	return $rows || [];
}

sub db_update {
	my $table = shift;
	my $data = shift;
	my $params = shift;
	%setting_memo = () if ($table // '') eq 'settings';
	my ($db,$database,$sql) = &database_grabber();
	$data->{'server_time'} = &subs::rightNow() unless $data->{'server_time'};
	&db_cache_updater($table, $params);
	return $db->update($table, $data, $params) if $db;
}

sub dbs_update {
  # Straight to the database now; the memory mirror is retired.
  return &db_update(@_);
}

sub dbs_delete {
  # Straight to the database now; the memory mirror is retired.
  return &db_delete(@_);
}

sub db_delete {
	my $table = shift;
	my $params = shift;
	%setting_memo = () if ($table // '') eq 'settings';

	my ($db,$database,$sql) = &database_grabber();
	my ($lid,$success);
	if ($db) {
		if ($table && ref $params eq ref {}) {
			$success = $db->delete($table, $params);
		}
		else {
		}
	}
	&db_cache_updater($table, $params);
	return $success;
}

sub db_select {
	my $table = shift;
	my $columns = shift;
	my $params = shift;
	my $filters = shift;
	my ($db,$database,$sql) = &database_grabber();
	return unless $db;

	# SQL::Abstract re-derives the same statement on every call (hundreds of
	# microseconds), while almost every caller asks for one table, a flat hash of
	# scalar conditions, and no ORDER BY. Build that statement directly. Anything
	# this cannot express exactly - a $filters/ORDER BY, a ref condition value
	# (IN, operators), a non-identifier name, or a non-hash $params - falls
	# through to SQL::Abstract unchanged.
	if (!$filters && defined $table && $table =~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
		my $ok = 1;
		my @bind;
		my $where = '';
		if (defined $params && !(!ref($params) && $params eq '')) {
			if (ref($params) eq 'HASH') {
				my @w;
				foreach my $k (sort keys %{$params}) {
					my $v = $params->{$k};
					if (ref $v || $k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { $ok = 0; last; }
					if (defined $v) { push @w, qq{"$k" = ?}; push @bind, $v; }
					else { push @w, qq{"$k" is null}; }
				}
				$where = ' where ( ' . join(' and ', @w) . ' )' if $ok && @w;
			}
			else { $ok = 0; }
		}
		my $cols = '*';
		if ($ok && defined $columns) {
			if (ref($columns) eq 'ARRAY') {
				my @c;
				foreach my $col ( @{$columns} ) {
					if (ref $col || $col !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { $ok = 0; last; }
					push @c, qq{"$col"};
				}
				$cols = join(', ', @c) if $ok;
			}
			# a scalar $columns is handed through unquoted, exactly as
			# SQL::Abstract does (it is how callers pass an expression); an empty
			# one means every column there too
			elsif (!ref($columns)) { $cols = length($columns) ? $columns : '*'; }
			else { $ok = 0; }
		}
		return $db->query('select ' . $cols . ' from "' . $table . '"' . $where, @bind) if $ok;
	}

	return $db->select($table,$columns,$params,$filters);
}

# A raw-SQL fast path for the common db_select shape: one table, equality
# filters, and IS NULL for an undef value. SQL::Abstract was a measurable slice
# of a settings read (it re-derives the same WHERE every call). Anything richer
# - a ref filter value, or a $filters argument - falls back to db_select, so
# behaviour is unchanged.
sub db_select_simple {
	my ($table, $columns, $params, $filters) = @_;
	return &db_select($table, $columns, $params, $filters)
		if $filters || !$params || ref($params) ne 'HASH' || grep { ref $params->{$_} } keys %{$params};
	my (@w, @v);
	foreach my $k (sort keys %{$params}) {
		if (defined $params->{$k}) { push @w, "$k = ?"; push @v, $params->{$k}; }
		else { push @w, "$k is null"; }
	}
	my $cols = ref($columns) eq 'ARRAY' ? join(', ', @{$columns}) : (defined $columns ? $columns : '*');
	my $sql = 'select ' . $cols . ' from ' . $table;
	$sql .= ' where ' . join(' and ', @w) if @w;
	return &db_query($sql, @v);
}

sub db_close {

}

sub db_cache_updater {
	return;
	my ($table,$data) = @_;
	if ($table eq 'appointments') {
		if ($data->{'app'} && $data->{'uuid'}) {
			&subs::subprocessor(sub {
				Mojo::IOLoop->reset;
				&subs::db_delete('cache', { app => $data->{'app'} });
				&Manager::centre_view_grabber({ c => &subs::controller_builder(), app => $data->{'app'}, timestamp => &subs::rightNow(), resetting => 'yes' });
			}, { name => 'db cache updater' });
		}
	}
}

# ---- theme surfaces -----------------------------------------------------------
# Windows and panels should read as a step away from the page background, in a
# grey that still carries a hint of the theme's hue. These helpers turn a theme
# background colour into the --panel/--panel-2/--ink values the CSS uses.
sub _rgb_to_hsl {
	my ($r, $g, $b) = map { $_ / 255 } @_;
	my $max = $r > $g ? ( $r > $b ? $r : $b ) : ( $g > $b ? $g : $b );
	my $min = $r < $g ? ( $r < $b ? $r : $b ) : ( $g < $b ? $g : $b );
	my $l = ($max + $min) / 2;
	my ($h, $s) = (0, 0);
	if ($max != $min) {
		my $d = $max - $min;
		$s = $l > 0.5 ? $d / (2 - $max - $min) : $d / ($max + $min);
		if ($max == $r) { $h = ($g - $b) / $d + ($g < $b ? 6 : 0); }
		elsif ($max == $g) { $h = ($b - $r) / $d + 2; }
		else { $h = ($r - $g) / $d + 4; }
		$h *= 60;
	}
	return ($h, $s, $l);
}

sub _hsl_to_hex {
	my ($h, $s, $l) = @_;
	# Perl's % truncates its operands to integers: (($h/60) % 2) would throw the
	# hue's fraction away, collapse the interpolation and turn a blue into a cyan
	# (the JS mirror jawnosHslToHex uses a float %, so server and client panels
	# disagreed). Do the fractional wrap by hand.
	$h -= 360 * int($h / 360);
	$h += 360 if $h < 0;
	my $c = (1 - abs(2 * $l - 1)) * $s;
	my $seg = $h / 60;
	$seg -= 2 * int($seg / 2);
	my $x = $c * (1 - abs($seg - 1));
	my $m = $l - $c / 2;
	my ($r, $g, $b);
	if ($h < 60) { ($r, $g, $b) = ($c, $x, 0); }
	elsif ($h < 120) { ($r, $g, $b) = ($x, $c, 0); }
	elsif ($h < 180) { ($r, $g, $b) = (0, $c, $x); }
	elsif ($h < 240) { ($r, $g, $b) = (0, $x, $c); }
	elsif ($h < 300) { ($r, $g, $b) = ($x, 0, $c); }
	else { ($r, $g, $b) = ($c, 0, $x); }
	return sprintf('#%02X%02X%02X', map { int(($_ + $m) * 255 + 0.5) } ($r, $g, $b));
}

1;
