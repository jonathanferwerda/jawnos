# tests-for: scripts/worktree_seed.pl
# covers:    the worktree seeder - config.json from the tracked example, the test
#           database from the shipped schema, a no-op in the primary checkout, and
#           that a file already there is never replaced

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Cwd qw(getcwd);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

my $real = "$FindBin::Bin/../scripts/worktree_seed.pl";
ok(-f $real, 'the seeder exists');

my $sqlite3 = `command -v sqlite3 2>/dev/null`;
chomp $sqlite3 if defined $sqlite3;
my $have_sqlite = defined $sqlite3 && length $sqlite3;

# The schema is deliberately more than one page, so the built database clears the
# seeder's (and database_grabber's) "too small to be a database" threshold.
my $SCHEMA = <<'SQL';
create table seeded (id integer primary key, name text);
create table second (id integer primary key, note text);
create table third (id integer primary key, body text);
insert into seeded (name) values ('one'), ('two'), ('three');
SQL

my $EXAMPLE = "{\n\t\"device\": \"desktop\",\n\t\"port\": 3000\n}\n";

sub sh {
	my @cmd = @_;
	open(my $fh, '-|', @cmd) or return (127, "cannot run @cmd: $!");
	local $/;
	my $out = <$fh>;
	$out = '' unless defined $out;
	close $fh;
	return ($? >> 8, $out);
}

sub run_seed {
	my ($dir, @args) = @_;
	my $cwd = getcwd();
	chdir $dir or die "chdir $dir: $!";
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, 'scripts/worktree_seed.pl', @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	chdir $cwd or die "chdir back: $!";
	return ($? >> 8, $stdout . $stderr);
}

# A primary checkout and one linked worktree, shaped like the house: the config
# is gitignored, the database is not tracked.
my $dir     = tempdir(CLEANUP => 1);
my $primary = "$dir/primary";
my $wt      = "$dir/work";
make_path($primary, "$primary/scripts", "$primary/database");
write_file("$primary/config.json.example", $EXAMPLE);
write_file("$primary/database/schema.sql", $SCHEMA);
write_file("$primary/scripts/worktree_seed.pl", read_file($real));
write_file("$primary/.gitignore", "/config.json\n/database/jawnos.db\n");
sh('git', '-C', $primary, 'init', '-b', 'main');
sh('git', '-C', $primary, 'config', 'user.email', 'seed@example.test');
sh('git', '-C', $primary, 'config', 'user.name', 'seed test');
sh('git', '-C', $primary, 'add', '.');
my ($cc) = sh('git', '-C', $primary, 'commit', '-m', 'base');
is($cc, 0, 'the fixture commits');
my ($wc) = sh('git', '-C', $primary, 'worktree', 'add', $wt, '-b', 'agent/task');
is($wc, 0, 'the fixture has a linked worktree');

subtest 'a linked worktree is seeded' => sub {
	my ($rc, $out) = run_seed($wt);
	is($rc, 0, 'the seeder exits cleanly');
	like($out, qr/wrote config\.json from config\.json\.example/, 'it writes the config');
	is(read_file("$wt/config.json"), $EXAMPLE, 'from the tracked example, not the primary live file');
	like($out, qr/built database\/jawnos\.db from database\/schema\.sql/, 'and builds the database');
	ok(-s "$wt/database/jawnos.db", 'the database file is non-empty');

	my (undef, $status) = sh('git', '-C', $wt, 'status', '--porcelain');
	is($status, '', 'the seeded files are gitignored, so the worktree stays clean');
};

subtest 'the database carries the shipped schema' => sub {
	skip 'sqlite3 is not installed', 2 unless $have_sqlite;
	my (undef, $tables) = sh('sqlite3', "$wt/database/jawnos.db",
		"select name from sqlite_master where type='table' order by name");
	like($tables, qr/\bseeded\b/, 'the schema table is there');
	my (undef, $rows) = sh('sqlite3', "$wt/database/jawnos.db", 'select count(*) from seeded');
	is($rows, "3\n", 'with the schema rows');
};

subtest 'a second run changes nothing' => sub {
	my ($rc, $out) = run_seed($wt);
	is($rc, 0, 'it exits cleanly');
	is($out, '', 'and says nothing, because there is nothing to do');
	is(read_file("$wt/config.json"), $EXAMPLE, 'the config is untouched');
};

subtest 'the primary checkout is never seeded' => sub {
	my ($rc, $out) = run_seed($primary);
	is($rc, 0, 'it exits cleanly there too');
	is($out, '', 'and says nothing');
	ok(!-e "$primary/config.json", 'no config.json is written into the live checkout');
	ok(!-e "$primary/database/jawnos.db", 'and no database is built beside the house one');
};

subtest 'a config an agent already copied is left alone' => sub {
	write_file("$wt/config.json", "{\"mine\": 1}\n");
	my ($rc) = run_seed($wt);
	is($rc, 0, 'it exits cleanly');
	is(read_file("$wt/config.json"), "{\"mine\": 1}\n", 'the agent\'s file wins');
};

subtest 'a real database is never rebuilt' => sub {
	skip 'sqlite3 is not installed', 2 unless $have_sqlite;
	sh('sqlite3', "$wt/database/jawnos.db", 'create table keepme (x)');
	my $before = read_file("$wt/database/jawnos.db");
	my ($rc) = run_seed($wt);
	is($rc, 0, 'it exits cleanly');
	is(read_file("$wt/database/jawnos.db"), $before, 'the file is byte-for-byte the same');
};

subtest 'a file too small to be a database is replaced' => sub {
	skip 'sqlite3 is not installed', 2 unless $have_sqlite;
	write_file("$wt/database/jawnos.db", "x");
	my ($rc) = run_seed($wt);
	is($rc, 0, 'it exits cleanly');
	ok(-s "$wt/database/jawnos.db" > 5000, 'the stub is replaced with a schema database');
};

subtest '--quiet suppresses the notes' => sub {
	unlink "$wt/config.json";
	my ($rc, $out) = run_seed($wt, '--quiet');
	is($rc, 0, 'it exits cleanly');
	is($out, '', 'and prints nothing');
	ok(-e "$wt/config.json", 'though it still seeded the config');
};

done_testing();
