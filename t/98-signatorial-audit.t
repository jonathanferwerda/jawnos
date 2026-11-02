# tests-for: scripts/signatorial_audit.pl
# covers:    the machine-identity audit - direct columns, bare references, JSON
#           text, and what counts as unknown

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use DBI;
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# A signatorial is stored in three shapes, and this audit is how you find out
# whether a row still names a machine that exists. Getting the classification
# wrong either hides a stale reference or cries wolf about a historical backup,
# so the three shapes and the unknown bucket are pinned here against a fixture
# database (the script takes --db, so no live row is read).

my $script = "$FindBin::Bin/../scripts/signatorial_audit.pl";
my $local  = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';
my $peer   = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2';
my $ghost  = 'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3';

sub fixture {
	my $dir = tempdir(CLEANUP => 1);
	my $db  = "$dir/audit.db";
	my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 });
	$dbh->do('CREATE TABLE remote_machines (signatorial TEXT, hostname TEXT, data TEXT, buttons TEXT, mirrors TEXT)');
	$dbh->do('CREATE TABLE settings (device TEXT, value TEXT)');
	$dbh->do('CREATE TABLE backups (recipient TEXT, signatorial TEXT)');
	$dbh->do('CREATE TABLE devices (address TEXT)');

	$dbh->do('INSERT INTO remote_machines (signatorial, hostname, data) VALUES (?, ?, ?)',
		undef, $peer, 'laptop', qq({"signatorial":"$local"}));
	$dbh->do('INSERT INTO settings (device, value) VALUES (?, ?)', undef, 'm1', qq({"signatorial":"$local"}));
	$dbh->do('INSERT INTO settings (device, value) VALUES (?, ?)', undef, 'm2', '{"plain":"value"}');
	$dbh->do('INSERT INTO backups (recipient, signatorial) VALUES (?, ?)', undef, $ghost, $local);
	$dbh->do('INSERT INTO devices (address) VALUES (?)', undef, qq({"signatorial":"$peer"}));
	$dbh->disconnect;
	return $db;
}

sub audit {
	my @args = @_;
	my $err  = gensym;
	my $pid  = open3(my $in, my $out, $err, $^X, $script, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

my $db = fixture();

# --- the three shapes --------------------------------------------------------
{
	my ($rc, $out) = audit('--db', $db, '--id', $local, '--label', 'audit fixture');
	is($rc, 0, 'the audit runs');
	like($out, qr/^== audit fixture ==$/m, 'the label is the heading');
	like($out, qr/^local id: \Q$local\E$/m, 'and the local id is reported');
	like($out, qr/\Q$peer\E\s+peer laptop/, 'a signatorial in remote_machines is a peer');

	like($out, qr/^  backups\.signatorial$/m, 'a direct column is listed');
	like($out, qr/\Q$local\E\s+\d+\s+this machine/, 'and its rows are classified');

	like($out, qr/^  backups\.recipient$/m, 'a bare reference column is listed');
	like($out, qr/\Q$ghost\E\s+\d+\s+UNKNOWN/, 'an id nobody knows is UNKNOWN');

	like($out, qr/^  remote_machines\.data$/m, 'a JSON column is read for the key');
	like($out, qr/^  devices\.address$/m, 'including one that is not on the named list');

	like($out, qr/-- unknown ids \(not this machine and not in remote_machines\) --/,
		'the unknown bucket is reported');
	like($out, qr/\Q$ghost\E\s+backups\.recipient \(1\)/, 'with where it was found');
	unlike($out, qr/\Q$local\E[^\n]*UNKNOWN/, 'the local id is never called unknown');
}

# --- a machine with no id is refused ---------------------------------------
{
	my ($rc, $out, $err) = audit('--db', $db, '--id', 'not-an-id');
	isnt($rc, 0, 'an invalid id is refused');
	like($err, qr/no local id/, 'with the reason');
}

done_testing();
