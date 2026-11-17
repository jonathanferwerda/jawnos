package subs;

# Doctor: inspect and repair the house database.
#
# The old doctor compared `select count(*)` with the number of rows `select *`
# returned. That finds a table whose pages cannot be read, but it is blind to a
# broken index: the row is still there, only its index entry is missing, so both
# counts agree and the doctor reported a clean house while `pragma
# integrity_check` named the index. The house database was in exactly that state
# (idx8_continent, a few dozen rows), and the old confirm then rebuilt a whole
# new database without fixing them.
#
# The repair has two tiers, chosen from what integrity_check says:
#   1. index damage - REINDEX the named index. It is rewritten from the table's
#      own rows, in place; no row is copied and no data can be lost.
#   2. table damage - salvage into a fresh database built from the schema, copy
#      each table by SQL so values keep their exact bytes and types, and only
#      replace the live file after the new one passes integrity_check. A copy of
#      the original is kept beside it first.
#
# Copied by SQL, not through Perl: binding a numeric-looking string and letting
# a TEXT column coerce it round-trips through a decimal representation that need
# not map back to the same double, which made a fresh expression index
# inconsistent on the very first insert. Let SQLite copy its own values.

use strict;
use warnings;
use utf8;

use File::Basename ();
use File::Temp ();
use Mojo::SQLite;

# A table or index name as a quoted SQL identifier. Names come from
# sqlite_master, never from a person, but a quote still has to be doubled.
sub doctor_ident {
	my $name = shift // '';
	$name =~ s/"/""/g;
	return '"' . $name . '"';
}

# A path as a quoted SQL string literal (the ATTACH filename). shell_quote is
# for the shell and is not valid SQL, so keep the two apart.
sub doctor_sql_string {
	my $value = shift // '';
	$value =~ s/'/''/g;
	return "'" . $value . "'";
}

# The sqlite3 binary, when this machine has one. It can be a newer SQLite than
# the library the app links, and the newer integrity check is the one that
# named the house's expression index; using the same tool the person used is
# what makes the doctor's answer agree with theirs. Undef when it is absent.
sub doctor_sqlite_tool {
	my $tool = `command -v sqlite3 2>/dev/null`;
	chomp $tool if defined $tool;
	return (defined $tool && length $tool && -x $tool) ? $tool : undef;
}

# The lines `pragma integrity_check` reports from the app's own SQLite, and
# separately from the sqlite3 binary when it is installed. The two can disagree
# about an expression index whose key includes a REAL cast: each engine writes
# the key in its own representation and its own integrity check accepts that
# representation. A lookup through the index returns the right rows under both,
# so the disagreement is not corruption. The engine the app actually uses is
# the authority here; the binary is kept as a note for the person who ran it.
sub doctor_integrity_lines {
	my ($database, $db) = @_;
	my (@engine, %engine_seen);
	my $engine_failed = 0;
	if ($db) {
		my $rows = eval { $db->query('pragma integrity_check')->arrays };
		if ($@) {
			# A malformed page makes the pragma die rather than return a line.
			# That is damage to act on, not a database that cannot be opened.
			my $reason = $@ =~ s/\s+/ /gr;
			push @engine, 'database disk image is malformed (' . $reason . ')';
			$engine_failed = 1;
		}
		else {
			foreach my $row ( @{ $rows || [] } ) {
				my $line = defined $row->[0] ? $row->[0] : '';
				push @engine, $line if length $line && $line ne 'ok' && !$engine_seen{$line}++;
			}
		}
	}
	my (@cli, %cli_seen);
	my $tool = &doctor_sqlite_tool();
	if ($tool && defined $database && length $database) {
		my $command = &shell_quote($tool)
			. ' -cmd ' . &shell_quote('.timeout 15000')
			. ' ' . &shell_quote($database)
			. ' ' . &shell_quote('pragma integrity_check') . ' 2>&1';
		my $output = `$command`;
		$output = '' unless defined $output;
		foreach my $line ( split /\r?\n/, $output ) {
			next unless length $line;
			next if $line eq 'ok';
			next if $line =~ /^Error: stepping,/;   # the same damage, already named
			push @cli, $line unless $cli_seen{$line}++;
		}
	}
	return {
		engine => \@engine,
		engine_ok => (@engine ? 0 : 1),
		engine_failed => $engine_failed,
		fatal => $db ? 0 : 1,
		cli => \@cli,
		cli_ran => $tool ? 1 : 0,
		cli_ok => scalar @cli ? 0 : 1,
	};
}

# What a repair would do, read-only. Returns a hashref:
#   ok          the file passes integrity_check
#   integrity   the raw lines, for the person to read
#   indexes     the index names REINDEX could rebuild
#   data_damage a complaint that is not an index (needs a salvage)
#   leaks       "page never used" style notes; harmless, never a salvage
#   tables      one row per table: name, count, scanned, readable
#   error       the database could not be read at all
sub doctor_scan {
	my $database = shift;
	my $out = {
		database => $database,
		ok => 0,
		integrity => [],
		indexes => [],
		data_damage => 0,
		leaks => 0,
		tables => [],
		error => undef,
	};
	unless (defined $database && length $database && -e $database) {
		$out->{'error'} = 'no database to read';
		return $out;
	}
	# Its own connection: the app's shared handle must be left exactly as it was,
	# and a failed read on a corrupt page must not hold a read lock over the
	# salvage that follows. Both are released when this connection closes.
	my $scan_sql = Mojo::SQLite->new('sqlite:' . $database, sqlite_use_immediate_transaction => 0);
	$scan_sql->options({ AutoCommit => 1 });
	my $db = $scan_sql->db;
	# A damaged page is expected here; the eval below catches the refusal, and
	# PrintError would put the same sentence in the log twice.
	eval { $db->dbh->{PrintError} = 0 };
	eval { $db->query('pragma busy_timeout=15000') };
	my $check = &doctor_integrity_lines($database, $db);
	if ($check->{'fatal'}) {
		$out->{'error'} = 'the database could not be read';
		return $out;
	}
	my $lines = $check->{'engine'};
	# When the engine is unhappy but its own output stopped at the section
	# header, the binary's detail is the only description of the damage. The
	# binary is only consulted this way when the engine is already unhappy;
	# its cross-version expression-index note is not damage.
	my @evidence = @{$lines};
	push @evidence, @{ $check->{'cli'} } if !$check->{'engine_ok'};
	my %seen_line;
	@evidence = grep { defined $_ && length $_ && $_ ne 'ok' && !$seen_line{$_}++ } @evidence;
	$out->{'integrity'} = \@evidence;
	$out->{'ok'} = $check->{'engine_ok'};
	$out->{'data_damage'} = 1 if $check->{'engine_failed'};
	# The binary names the same index in its own representation. When the app's
	# engine is happy and only the binary objects, that is a note, not damage:
	# a repair would make the app's engine object in turn.
	$out->{'cli'} = $check->{'cli'};
	$out->{'cli_disagrees'} = ($check->{'engine_ok'} && $check->{'cli_ran'} && !$check->{'cli_ok'}) ? 1 : 0;

	my %index;
	foreach my $line ( @evidence ) {
		if ($line =~ /(?:missing from index|wrong # of entries in index)\s+(\S+)/) {
			$index{$1} = 1;
		}
		elsif ($line =~ /\bindex\s+(\S+)\s+is\b/i) {
			# A wording the two patterns above do not cover but that still names
			# an index: rebuilding it is safe, so offer that rather than a copy.
			$index{$1} = 1;
		}
	}
	$out->{'indexes'} = [ sort keys %index ];

	# Anything that is neither an index complaint nor a harmless unused-page
	# note is damage to the table itself. A bare "*** in database main ***"
	# is a corruption header with no detail: treat it as damage, not as a note,
	# because the engine may have stopped after printing it. Treat an unknown
	# wording the same way: guessing "fine" is how a repair loses data.
	foreach my $line ( @evidence ) {
		next if $line =~ /(?:missing from index|wrong # of entries in index)\s+\S+/;
		next if $line =~ /\bindex\s+\S+\s+is\b/i;
		if ($line =~ /(?:\bpage\s+\d+\s+is never used\b|\bunused page\b|\bfreelist\b)/i) {
			$out->{'leaks'}++;
			next;
		}
		$out->{'data_damage'} = 1;
	}

	my $tables = eval {
		$db->query(q{select name from sqlite_master where type = 'table' and name not like 'sqlite\_%' escape '\' order by name})->arrays;
	} || [];
	foreach my $row ( @{$tables} ) {
		my $name = $row->[0];
		next unless defined $name && length $name;
		my $ident = &doctor_ident($name);
		my $count = eval { $db->query('select count(*) from ' . $ident)->arrays->[0]->[0] };
		# NOT INDEXED forces a walk of the table's own b-tree, which is the way
		# to hear a corrupt page. A covering index would answer even when the
		# rows behind it cannot be read.
		my $scanned = eval { $db->query('select count(*) from ' . $ident . ' not indexed')->arrays->[0]->[0] };
		my $readable = defined $scanned && defined $count && $scanned == $count ? 1 : 0;
		$out->{'data_damage'} = 1 if !defined $scanned;
		push @{$out->{'tables'}}, {
			name => $name,
			count => defined $count ? $count : undef,
			scanned => defined $scanned ? $scanned : undef,
			readable => $readable,
		};
	}
	eval { $db->dbh->disconnect };
	return $out;
}

# Rebuild the indexes named by the scan with the engine the app uses, then let
# the caller re-check. The sqlite3 binary is deliberately not used here: its
# index representation is the one the app's engine objects to, so rebuilding
# with it would trade one complaint for the other.
sub doctor_reindex {
	my ($database, $db, $indexes) = @_;
	my @done;
	foreach my $index ( @{$indexes || []} ) {
		# do() reports a refused statement as undef; query() hands back a
		# result object either way, which made a failed rebuild look done.
		my $ok = eval { defined $db->dbh->do('reindex ' . &doctor_ident($index)) ? 1 : 0 } || 0;
		push @done, $index if $ok;
	}
	return \@done;
}

# Rescue a table whose own rows could not all be read. The named index is tried
# first because an index lookup can step over the corrupt page; failing that, a
# rowid range is split until single rows are reached, so every readable row is
# kept and only the page that cannot be read is lost.
sub doctor_salvage_table {
	my ($ndb, $table, $report) = @_;
	my $ident = &doctor_ident($table);
	# A table the old database does not have is not something to copy; the new
	# schema may be ahead of it.
	my $exists = eval { $ndb->query('select 1 from old.sqlite_master where type = ? and name = ?', 'table', $table)->arrays->[0] };
	return unless $exists;
	my $count = sub { eval { $ndb->query('select count(*) from main.' . $ident)->arrays->[0]->[0] } || 0 };
	my $before = $count->();
	# The count is taken from the table itself first: a corrupt index must not
	# decide how many rows the table has. If the table scan fails, the plain
	# count may still answer from an index.
	my $old_count = eval { $ndb->query('select count(*) from old.' . $ident . ' not indexed')->arrays->[0]->[0] };
	$old_count = eval { $ndb->query('select count(*) from old.' . $ident)->arrays->[0]->[0] } unless defined $old_count;
	my $known_count = defined $old_count;
	my $lost = 0;
	my $truncated = 0;

	# A single statement first, over the table's own b-tree. NOT INDEXED keeps a
	# broken index out of the read: a corrupt index can make a plain `select *`
	# return nothing even though every row is there. The statement may keep the
	# rows before a damaged page and stop there; those rows are valid, so nothing
	# is rolled back. Whatever is still missing is walked again below.
	eval {
		$ndb->query('insert into main.' . $ident . ' select * from old.' . $ident . ' not indexed')->rows;
	};
	my $incomplete = $known_count ? ($count->() < $before + $old_count) : 1;
	$incomplete and do {
		# Named apps are the cheapest partition: the app index can skip the
		# page the full scan could not read.
		my $has_app = eval { $ndb->query(q{select 1 from pragma_table_info(?) where name = 'app'}, $table)->arrays->[0] } ? 1 : 0;
		if ($has_app) {
			my $apps = eval { $ndb->query('select distinct app from old.' . $ident)->arrays } || [];
			foreach my $row ( @{$apps} ) {
				eval {
					$ndb->query('insert or ignore into main.' . $ident
						. ' select * from old.' . $ident . ' where app is ?', $row->[0])->rows;
				};
			}
		}
		# Whatever remains is reached by rowid, split until single rows, so a
		# page that cannot be read loses only its own rows. Bounds come from the
		# table scan when it can still answer; a valid index can name them when
		# the table's own pages cannot.
		my $bounds = eval { $ndb->query('select min(rowid), max(rowid) from old.' . $ident . ' not indexed')->arrays->[0] };
		unless ($bounds && defined $bounds->[0]) {
			my $indexes = eval { $ndb->query(q{select name from old.sqlite_master where type = 'index' and tbl_name = ? and sql is not null}, $table)->arrays } || [];
			foreach my $idxrow ( @{$indexes} ) {
				my $idx = $idxrow->[0];
				next unless defined $idx && length $idx;
				$bounds = eval { $ndb->query('select min(rowid), max(rowid) from old.' . $ident . ' indexed by ' . &doctor_ident($idx))->arrays->[0] };
				last if $bounds && defined $bounds->[0];
			}
		}
		# A damaged page can make sqlite report a min/max rowid that belongs
		# to no row of the table (a broken leaf answered 408890 for a table
		# of 500 rows). A range the engine cannot read is split in two, so a
		# bogus bound costs one visit per rowid and the repair never ends.
		# The walk carries a budget; spending it marks the table truncated
		# instead of letting the repair hang.
		my $budget = { left => 20_000 };
		&doctor_salvage_range($ndb, $ident, $bounds->[0], $bounds->[1], \$lost, $budget)
			if $bounds && defined $bounds->[0] && defined $bounds->[1];
		$truncated = 1 if $budget->{'left'} <= 0;
	};
	my $after = $count->();
	push @{$report}, {
		table => $table,
		before => $old_count,
		copied => $after - $before,
		lost => $lost,
		($truncated ? (truncated => 1) : ()),
	};
	return;
}

sub doctor_salvage_range {
	my ($ndb, $ident, $lo, $hi, $lost, $budget) = @_;
	$budget ||= { left => 20_000 };
	return unless defined $lo && defined $hi && $lo <= $hi;
	# A range that cannot be read splits in two, so an engine that refuses
	# every width costs one visit per rowid. The budget keeps a bound the
	# damage invented from becoming a hang; the caller marks the table
	# truncated when it is spent.
	return if $budget->{'left'} <= 0;
	$budget->{'left'}--;
	# Reading the rowids first is the cheap proof that the range's pages can be
	# read at all; NOT INDEXED keeps a broken index out of that read. A range
	# that cannot be read is split instead of copied.
	my $readable = eval { $ndb->query('select rowid from old.' . $ident . ' not indexed where rowid between ? and ?', $lo, $hi)->arrays; 1 };
	if ($readable) {
		my $count = sub { eval { $ndb->query('select count(*) from main.' . $ident)->arrays->[0]->[0] } || 0 };
		my $before = $count->();
		eval {
			$ndb->query('insert or ignore into main.' . $ident
				. ' select * from old.' . $ident . ' not indexed where rowid between ? and ?', $lo, $hi)->rows;
		};
		return if $count->() > $before;
	}
	if ($lo == $hi) {
		$$lost++;
		return;
	}
	my $mid = int(($lo + $hi) / 2);
	&doctor_salvage_range($ndb, $ident, $lo, $mid, $lost, $budget);
	&doctor_salvage_range($ndb, $ident, $mid + 1, $hi, $lost, $budget);
	return;
}

# Copy the original database to a file beside it, before the live one is
# replaced. Returns the path, or undef when sqlite3 could not make the copy.
sub doctor_snapshot {
	my ($database, $path) = @_;
	return undef unless defined $database && defined $path;
	my $command = 'sqlite3 ' . &shell_quote($database) . ' ' . &shell_quote(".backup '" . $path . "'");
	system($command);
	return (-e $path && -s $path > 5000) ? $path : undef;
}

# Salvage the tables into a fresh database and replace the live file when the
# new one passes integrity_check. Returns a result hashref.
sub doctor_salvage {
	my ($database, $progress) = @_;
	$progress ||= sub { };
	my $out = {
		ok => 0,
		salvaged => [],
		integrity_after => [],
		snapshot => undef,
		error => undef,
	};
	my ($db) = &database_grabber();
	unless ($db) {
		$out->{'error'} = 'no database to repair';
		return $out;
	}
	eval { $db->dbh->{PrintError} = 0 };
	my $dir = File::Basename::dirname($database);
	my $temp = File::Temp::tempdir('jawnos-doctor-XXXXXX', DIR => $dir, CLEANUP => 1);
	my $newdb = "$temp/new.db";
	my $schema_file = "$temp/schema.sql";

	# The schema is the shape the new database is built to. If it cannot be
	# read, a rebuild would silently drop whatever it did not see, so stop.
	my $dump = 'sqlite3 ' . &shell_quote($database)
		. q{ .schema 2>/dev/null | grep -vE 'sqlite_stat|sqlite_sequence' > } . &shell_quote($schema_file);
	system($dump);
	unless (-e $schema_file && -s $schema_file) {
		$out->{'error'} = 'could not read the schema; nothing was replaced';
		return $out;
	}
	my $import = 'sqlite3 ' . &shell_quote($newdb) . ' < ' . &shell_quote($schema_file);
	system($import);
	unless (-e $newdb && -s $newdb > 5000) {
		$out->{'error'} = 'could not build the fresh database; nothing was replaced';
		return $out;
	}

	my $nsql = Mojo::SQLite->new('sqlite:' . $newdb, sqlite_use_immediate_transaction => 0);
	$nsql->options({ AutoCommit => 1 });
	my $ndb = $nsql->db;
	# A damaged page is expected; the salvage reads around it and the refusal
	# would otherwise print for every split.
	eval { $ndb->dbh->{PrintError} = 0 };
	my $attached = eval { $ndb->query('attach database ' . &doctor_sql_string($database) . ' as old'); 1 };
	unless ($attached) {
		my $reason = $@ =~ s/\s+/ /gr;
		$out->{'error'} = 'could not attach the old database: ' . $reason;
		return $out;
	}

	my $tables = eval {
		$ndb->query(q{select name from main.sqlite_master where type = 'table' and name not like 'sqlite\_%' escape '\' order by name})->arrays;
	} || [];
	# The schema is what the fresh file is built from. If corruption hid a table
	# or one of its columns, a copy would silently drop what it could not see;
	# refuse before anything is replaced.
	my $old_tables = eval {
		$ndb->query(q{select name from old.sqlite_master where type = 'table' and name not like 'sqlite\_%' escape '\'})->arrays;
	} || [];
	my %new_table = map { $_->[0] => 1 } @{$tables};
	foreach my $row ( @{$old_tables} ) {
		my $name = $row->[0];
		next unless defined $name && length $name;
		unless ($new_table{$name}) {
			$out->{'error'} = 'the schema did not include ' . $name . '; nothing was replaced';
			return $out;
		}
		my $old_cols = eval { $ndb->query('select name from pragma_table_info(?, ?)', $name, 'old')->arrays } || [];
		my $new_cols = eval { $ndb->query('select name from pragma_table_info(?)', $name)->arrays } || [];
		my %new_col = map { $_->[0] => 1 } @{$new_cols};
		my @missing = grep { !$new_col{$_->[0]} } @{$old_cols};
		if (scalar @missing) {
			$out->{'error'} = 'the schema did not include every column of ' . $name . '; nothing was replaced';
			return $out;
		}
	}
	foreach my $row ( @{$tables} ) {
		my $name = $row->[0];
		next unless defined $name && length $name;
		$progress->('Salvaging ' . $name);
		&doctor_salvage_table($ndb, $name, $out->{'salvaged'});
	}
	eval { $ndb->query('detach database old') };

	# Rebuild the indexes with the engine the app uses, so the engine's own
	# integrity check accepts the result. The sqlite3 binary may keep its own
	# opinion about an expression index - a cross-version difference, not damage.
	eval { $ndb->query('reindex') };
	# Check the fresh file on its own connection: the working one still has the
	# corrupt original attached, and integrity_check would report that database
	# rather than the copy.
	eval { $ndb->dbh->disconnect } if $ndb->dbh;
	my $checksql = Mojo::SQLite->new('sqlite:' . $newdb, sqlite_use_immediate_transaction => 0);
	$checksql->options({ AutoCommit => 1 });
	my $checkdb = $checksql->db;
	my $check = &doctor_integrity_lines($newdb, $checkdb);
	my $lines = $check->{'engine'};
	$out->{'integrity_after'} = $lines;
	my $healthy = $check->{'engine_ok'};
	unless ($healthy) {
		my $last = $#{$lines} > 4 ? 4 : $#{$lines};
		my $first = $last >= 0 ? join('; ', @{$lines}[0 .. $last]) : 'the rebuilt database could not be checked';
		$out->{'error'} = 'the rebuilt database still reports: ' . $first;
		return $out;
	}
	eval { $checkdb->dbh->disconnect } if $checkdb->dbh;

	$progress->('Saving a copy of the original');
	my $snapshot = $dir . '/jawnos-before-doctor-' . time() . '.db';
	unless (&doctor_snapshot($database, $snapshot)) {
		$out->{'error'} = 'could not save a copy of the original; nothing was replaced';
		return $out;
	}
	chmod 0600, $snapshot;
	$out->{'snapshot'} = $snapshot;

	eval { $ndb->dbh->disconnect } if $ndb->dbh;
	my $holder = $gb::database_holder || {};
	eval { $holder->{'dbh'}->do('pragma wal_checkpoint(truncate)') } if $holder->{'dbh'};
	eval { $holder->{'dbh'}->disconnect } if $holder->{'dbh'};
	$gb::database_holder = {};
	# Copy the fresh file into the live one rather than renaming it over: a
	# server has several workers, and each holds its own handle. A rename leaves
	# them reading the old inode; the backup API writes through the live file and
	# its WAL, so every worker sees the repaired database. It is transactional
	# too, so a failed copy leaves the original exactly as it was.
	my $replace = 'sqlite3 ' . &shell_quote($newdb)
		. ' -cmd ' . &shell_quote('.timeout 15000')
		. ' ' . &shell_quote(".backup '" . $database . "'");
	system($replace);
	my $copied_ok = $? == 0;
	my $live = Mojo::SQLite->new('sqlite:' . $database, sqlite_use_immediate_transaction => 0);
	$live->options({ AutoCommit => 1 });
	my $live_check = eval { $live->db->query('pragma integrity_check')->arrays->[0]->[0] };
	eval { $live->db->dbh->disconnect };
	unless ($copied_ok && defined $live_check && $live_check eq 'ok') {
		$out->{'error'} = 'could not replace the database; the original was kept'
			. (defined $live_check ? ' (it now reports: ' . $live_check . ')' : '');
		return $out;
	}
	$out->{'ok'} = 1;
	return $out;
}

# The whole repair. Returns a hashref the controller renders:
#   ok, reindexed, salvaged, integrity_before, integrity_after, snapshot,
#   message, error
sub doctor_repair {
	my ($database, $progress) = @_;
	$progress ||= sub { };
	my $result = {
		ok => 0,
		reindexed => [],
		salvaged => [],
		integrity_before => [],
		integrity_after => [],
		snapshot => undef,
		message => '',
		error => undef,
	};
	my $scan = &doctor_scan($database);
	$result->{'integrity_before'} = $scan->{'integrity'};
	if ($scan->{'error'}) {
		$result->{'error'} = $scan->{'error'};
		return $result;
	}
	if ($scan->{'ok'}) {
		$result->{'ok'} = 1;
		$result->{'message'} = 'The database is already healthy.';
		return $result;
	}
	my ($db) = &database_grabber();
	unless ($db) {
		$result->{'error'} = 'no database to repair';
		return $result;
	}

	my @indexes = @{ $scan->{'indexes'} || [] };
	# A table that cannot be read is never answered with a rebuild in place: a
	# failed REINDEX on a damaged b-tree can leave the file worse. The fresh
	# database below rebuilds every index from copied rows instead.
	if (!$scan->{'data_damage'}) {
		if (@indexes) {
			$progress->('Rebuilding ' . scalar(@indexes) . ' index(es)');
			$result->{'reindexed'} = &doctor_reindex($database, $db, \@indexes);
		}
		else {
			# An unused page is not damage and no index is named: nothing here is
			# worth copying a database for.
			$result->{'ok'} = 1;
			$result->{'message'} = 'Only unused pages were reported; no repair was needed.';
			return $result;
		}
		my $after = &doctor_scan($database);
		$result->{'integrity_after'} = $after->{'integrity'};
		if ($after->{'ok'}) {
			$result->{'ok'} = 1;
			$result->{'message'} = 'The indexes were rebuilt.';
			return $result;
		}
		unless ($after->{'data_damage'} || scalar @{ $after->{'indexes'} || [] }) {
			$result->{'ok'} = 1;
			$result->{'message'} = 'The indexes were rebuilt; only unused pages remain.';
			return $result;
		}
	}

	$progress->('Salvaging the tables into a fresh database');
	my $salvage = &doctor_salvage($database, $progress);
	$result->{'salvaged'} = $salvage->{'salvaged'};
	$result->{'integrity_after'} = $salvage->{'integrity_after'};
	$result->{'snapshot'} = $salvage->{'snapshot'};
	if ($salvage->{'error'}) {
		$result->{'error'} = $salvage->{'error'};
		return $result;
	}
	$result->{'ok'} = 1;
	$result->{'message'} = 'The tables were salvaged into a fresh database.';
	return $result;
}

1;
