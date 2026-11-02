# tests-for: scripts/privacy_permissions.pl
# covers:    the one-time permissions pass - what it tightens, what it leaves,
#           and that a dry run writes nothing

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Path qw(make_path);
use File::Slurp qw(write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# The tree ships with umask 077, but that only covers files created since. This
# pass fixes what is already on disk: the database, config.json, the secrets and
# the live ticket. Two rules matter and are easy to get wrong - it must not
# follow a symlink, and it must not strip a shebang file's execute bit.
#
# It takes --root and reads $HOME, so the whole run is done in a temporary tree.

my $script = "$FindBin::Bin/../scripts/privacy_permissions.pl";

sub mode {
	my ($path) = @_;
	return sprintf '%04o', (stat $path)[2] & 07777;
}

sub run_pass {
	my (%a) = @_;
	local $ENV{'HOME'} = $a{'home'};
	my @args = (@{ $a{'args'} || [] });
	my $err  = gensym;
	my $pid  = open3(my $in, my $out, $err, $^X, $script, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

sub fixture {
	my %a = @_;
	my $root = tempdir(CLEANUP => 1);
	my $home = tempdir(CLEANUP => 1);

	make_path("$root/perl", "$root/database/backups", "$root/.secrets", "$root/.shots");
	write_file("$root/perl/Manager.pl", "1;\n");            # identifies an install
	write_file("$root/database/jawnos.db", "db\n");
	write_file("$root/database/backups/old.enc", "sealed\n");
	write_file("$root/config.json", "{}\n");
	write_file("$root/.secrets/ssh.txt", "host\n");
	write_file("$root/.shots/ticket.txt", "https://example.invalid/ticket\n");

	make_path("$home/.president");
	write_file("$home/.president/status", "good\n");
	write_file("$home/manager.log", "log\n");

	# Already loose, the way an old install or a restore leaves them.
	chmod 0755, "$root/database", "$root/.secrets", "$root/.shots", "$home/.president";
	chmod 0644, "$root/database/jawnos.db", "$root/database/backups/old.enc",
		"$root/config.json", "$root/.secrets/ssh.txt", "$root/.shots/ticket.txt",
		"$home/.president/status", "$home/manager.log";

	# A target outside the tree, reached by a symlink that must not be followed.
	my $outside = tempdir(CLEANUP => 1);
	write_file("$outside/private.txt", "not mine\n");
	chmod 0644, "$outside/private.txt";
	symlink "$outside/private.txt", "$root/.secrets/link";

	return ($root, $home, "$outside/private.txt");
}

# --- the pass tightens what it names, and nothing else -----------------------
{
	my ($root, $home, $outside) = fixture();
	my ($rc, $out) = run_pass(home => $home, args => [ '--root', $root ]);
	is($rc, 0, 'the pass runs clean');
	like($out, qr/^tightened \d+ files?$/m, 'and reports how many it changed');

	is(mode("$root/database"), '0700', 'the database directory is private');
	is(mode("$root/database/jawnos.db"), '0600', 'the live database is 0600');
	is(mode("$root/database/backups/old.enc"), '0600', 'and so is a sealed backup');
	is(mode("$root/config.json"), '0600', 'config.json is 0600');
	is(mode("$root/.secrets"), '0700', 'the secrets directory is private');
	is(mode("$root/.secrets/ssh.txt"), '0600', 'and the credentials inside it');
	is(mode("$root/.shots/ticket.txt"), '0600', 'the live ticket is 0600');
	is(mode("$home/.president"), '0700', 'the master\'s state directory is private');
	is(mode("$home/.president/status"), '0600', 'and its files');
	is(mode("$home/manager.log"), '0600', 'the log is 0600');

	is(mode($outside), '0644', 'a symlink is not followed to its target');
	ok(-l "$root/.secrets/link", 'and the link is left alone');
}

# --- --dry-run reports and writes nothing -----------------------------------
{
	my ($root, $home) = fixture();
	my ($rc, $out) = run_pass(home => $home, args => [ '--root', $root, '--dry-run' ]);
	is($rc, 0, 'the dry run exits 0');
	like($out, qr/^would tighten \d+ files?$/m, 'and says nothing was written');
	is(mode("$root/database/jawnos.db"), '0644', 'the database keeps its mode');
	is(mode("$root/.secrets/ssh.txt"), '0644', 'and so do the credentials');
}

# --- a directory that is not an install is refused --------------------------
{
	my $not_a_tree = tempdir(CLEANUP => 1);
	my $home = tempdir(CLEANUP => 1);
	my ($rc, $out, $err) = run_pass(home => $home, args => [ '--root', $not_a_tree ]);
	isnt($rc, 0, 'a directory with no perl/Manager.pl is refused');
	like($err, qr/pass --root DIR/, 'with the way to point it at one');
}

# --- a shebang keeps its execute bit ----------------------------------------
{
	my ($root, $home) = fixture();
	write_file("$root/.secrets/probe.pl", "#!/usr/bin/perl\n1;\n");
	chmod 0755, "$root/.secrets/probe.pl";
	my ($rc) = run_pass(home => $home, args => [ '--root', $root ]);
	is($rc, 0, 'the pass runs with a script in the secrets tree');
	is(mode("$root/.secrets/probe.pl"), '0700', 'a shebang file stays executable');
	is(mode("$root/.secrets/ssh.txt"), '0600', 'while plain credentials do not');
}

done_testing();
