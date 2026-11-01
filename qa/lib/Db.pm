package Db;

# Database contracts for the QA layer: is the database the app believes it has,
# and do the hot reads take the indexes the schema built for them?
#
# Everything here reads the *QA copy* through `sqlite3` in read-only mode. The
# live database is never opened. The checks are:
#
#   * PRAGMA integrity_check and foreign_key_check
#   * every table in database/schema.sql exists
#   * the synced tables carry ost and server_time (the rail skips a table
#     without both)
#   * EXPLAIN QUERY PLAN for the hot readers, with the index each one should use
#
# The query list is qa/db.checks.json, so a new hot read is a data change.

use strict;
use warnings;

use JSON::PP;
use File::Slurp qw(read_file);

our $VERSION = '1';

sub load_config {
	my ($path) = @_;
	my $json = -f $path ? read_file($path) : '{}';
	my $cfg = eval { JSON::PP->new->utf8->decode($json) };
	die "Db: $path is not valid JSON: $@" unless ref $cfg eq 'HASH';
	$cfg->{'synced'}  ||= [];
	$cfg->{'tables'}  ||= [];
	$cfg->{'queries'} ||= [];
	return $cfg;
}

sub run_sql {
	my ($db, $sql) = @_;
	my $uri = "file:$db?mode=ro";
	open(my $fh, '-|', 'sqlite3', '-batch', '-noheader', $uri, $sql)
		or return { out => "cannot run sqlite3: $!", ok => 0 };
	local $/;
	my $out = <$fh> // '';
	close $fh;
	my $ok = ($? == 0) ? 1 : 0;
	return { out => $out, ok => $ok };
}

sub schemas {
	my ($schema_file) = @_;
	my $text = read_file($schema_file);
	my @tables;
	while ($text =~ /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["']?([A-Za-z_][A-Za-z0-9_]*)["']?/gi) {
		push @tables, $1;
	}
	return \@tables;
}

sub columns {
	my ($db, $table) = @_;
	my $r = run_sql($db, "select name from pragma_table_info('$table')");
	return [] unless $r->{'ok'};
	my @cols = grep { length } split /\n/, $r->{'out'};
	return \@cols;
}

sub tables_in_db {
	my ($db) = @_;
	my $r = run_sql($db, "select name from sqlite_master where type='table' and name not like 'sqlite_%' order by name");
	return [] unless $r->{'ok'};
	return [ grep { length } split /\n/, $r->{'out'} ];
}

# Returns an arrayref of { name, ok, detail } rows. Never dies on a failed
# check; a broken database is a result, not a crash.
sub checks {
	my ($class, %opt) = @_;
	my $db     = $opt{'db'}     or die "Db: no database\n";
	my $schema = $opt{'schema'} or die "Db: no schema\n";
	my $cfg    = $opt{'config'} || {};
	my @rows;

	unless (-f $db) {
		return [ { name => 'database exists', ok => 0, detail => "$db is missing" } ];
	}

	my $int = run_sql($db, 'PRAGMA integrity_check');
	push @rows, {
		name => 'integrity_check',
		ok => ($int->{'ok'} && $int->{'out'} =~ /^\s*ok\s*$/m) ? 1 : 0,
		detail => ($int->{'out'} =~ s/\s+/ /gr),
	};

	my $fk = run_sql($db, 'PRAGMA foreign_key_check');
	push @rows, {
		name => 'foreign_key_check',
		ok => ($fk->{'ok'} && $fk->{'out'} !~ /\S/) ? 1 : 0,
		detail => ($fk->{'ok'} ? 'no violations' : $fk->{'out'}),
	};

	my $in_db = { map { $_ => 1 } @{ tables_in_db($db) } };
	my $want  = schemas($schema);
	my @missing = grep { !$in_db->{$_} } @$want;
	push @rows, {
		name => 'schema tables exist',
		ok => scalar(@missing) ? 0 : 1,
		detail => scalar(@missing) ? 'missing: ' . join(', ', @missing) : scalar(@$want) . ' tables',
	};

	# The sync rail skips a table without both stamps.
	my @no_stamp;
	for my $t (@{ $cfg->{'synced'} }) {
		my $cols = { map { $_ => 1 } @{ columns($db, $t) } };
		unless (scalar keys %$cols) {
			push @no_stamp, "$t (no table)";
			next;
		}
		my @lack;
		push @lack, 'ost'         unless $cols->{'ost'};
		push @lack, 'server_time' unless $cols->{'server_time'};
		push @no_stamp, "$t (" . join(',', @lack) . ')' if @lack;
	}
	push @rows, {
		name => 'synced tables carry ost + server_time',
		ok => scalar(@no_stamp) ? 0 : 1,
		detail => scalar(@no_stamp) ? join(', ', @no_stamp) : scalar(@{ $cfg->{'synced'} }) . ' tables',
	};

	for my $query (@{ $cfg->{'queries'} }) {
		my $plan = run_sql($db, 'EXPLAIN QUERY PLAN ' . $query->{'sql'});
		my $text = $plan->{'out'} // '';
		my $ok = $plan->{'ok'} ? 1 : 0;
		my $detail = $text;
		if (($query->{'expect'} || 'any') eq 'index') {
			$ok = 0 unless $text =~ /USING\s+(?:COVERING\s+)?INDEX/i;
		}
		push @rows, {
			name => 'plan: ' . ($query->{'name'} || 'query'),
			ok => $ok,
			detail => $detail,
		};
	}

	my $counts = run_sql($db, "select 'appointments', count(*) from appointments union all select 'settings', count(*) from settings");
	push @rows, { name => 'row counts', ok => 1, detail => ($counts->{'out'} =~ s/\s+/ /gr) };

	my @st = stat($db);
	push @rows, { name => 'database size', ok => 1, detail => int($st[7] / 1024) . ' KB' };

	return \@rows;
}

1;
