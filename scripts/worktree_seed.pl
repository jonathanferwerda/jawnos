#!/usr/bin/perl

# Give a linked worktree the two install-local files the suite needs.
#
# A worktree is a checkout, not a clone: `config.json` is gitignored and
# `database/jawnos.db` is not in git, so a suite started from a worktree used to
# read neither. Config is read at load (perl/subroutines.pl), which failed every
# test file at once, and a few tests copy the live database's schema. The
# failure reads as "the suite broke", so an agent that forgot the copy landed a
# second time on work that was fine.
#
#   perl scripts/worktree_seed.pl           seed this worktree
#   perl scripts/worktree_seed.pl --quiet   only the failures
#
# `scripts/run_tests.pl` runs this before every suite, so iterating and landing
# both have what they need; run it by hand when something other than the suite
# boots the app (a probe, a script that reads config).
#
# It writes ONLY inside a linked worktree. The primary checkout holds the live
# config and the house database, and this script never touches them (it exits
# quietly there). Nothing it writes is tracked, so a checkout cannot go dirty.
# An existing file is never replaced, except a database file too small to be one
# (database_grabber ignores those, so it is the same as absent).

use strict;
use warnings;

use Cwd qw(abs_path);

my $quiet = grep { $_ eq '--quiet' } @ARGV;
my $help  = grep { $_ eq '--help' } @ARGV;
if ($help) {
	print <<'USAGE';
worktree_seed.pl - seed a linked worktree with config.json and a test database
  perl scripts/worktree_seed.pl [--quiet] [--help]
USAGE
	exit 0;
}

sub say_line { print STDERR "worktree_seed: $_[0]\n" unless $quiet }

sub capture {
	my @cmd = @_;
	open(my $fh, '-|', @cmd) or return (127, "cannot run @cmd: $!");
	local $/;
	my $out = <$fh>;
	$out = '' unless defined $out;
	close $fh;
	return ($? >> 8, $out);
}

sub git {
	my @args = @_;
	my ($code, $out) = capture('git', @args);
	$out =~ s/\s+$// if defined $out;
	return ($code, $out);
}

my ($rc, $root) = git('rev-parse', '--show-toplevel');
exit 0 if $rc != 0 || !length $root;    # not in a repository: nothing to seed
chdir $root or do { say_line("cannot enter $root: $!"); exit 0 };

# The primary checkout is the first worktree in the list and the one whose git
# dir IS the common dir. A linked worktree's git dir is <common>/worktrees/<name>,
# so the two differ - that is the whole test, and it keeps this script off the
# live config and database.
my (undef, $git_dir) = git('rev-parse', '--path-format=absolute', '--git-dir');
my (undef, $common)  = git('rev-parse', '--path-format=absolute', '--git-common-dir');
$git_dir = abs_path($git_dir) // $git_dir if defined $git_dir;
$common  = abs_path($common)  // $common  if defined $common;
exit 0 if !defined $git_dir || !defined $common || $git_dir eq $common;

if (!-e 'config.json') {
	# The tracked example is preferred over the primary's live file: it is checked
	# by t/00 to carry every key boot depends on, and it keeps a scratch tree from
	# carrying this machine's identity into tests that branch on it.
	if (-e 'config.json.example') {
		if (open(my $in, '<', 'config.json.example') && open(my $out, '>', 'config.json')) {
			local $/;
			print {$out} scalar <$in>;
			close $out;
			close $in;
			say_line('wrote config.json from config.json.example (gitignored, not tracked)');
		}
		else {
			say_line("cannot write config.json from config.json.example: $!");
		}
	}
	else {
		say_line('no config.json and no config.json.example; the suite will fail');
	}
}

# --- database/jawnos.db ----------------------------------------------------
# Built from the shipped schema, which carries every table (a fixture seed can
# predate one). Never the live database: that is the primary's, and a scratch
# copy would let a test write to it.
my $db      = 'database/jawnos.db';
my $schema  = 'database/schema.sql';
my $have_db = -e $db && -s $db > 5000;    # database_grabber's own threshold

if (!$have_db) {
	if (!-e $schema) {
		say_line("no $schema; cannot build a test database");
	}
	elsif (!open(my $in, '<', $schema)) {
		say_line("cannot read $schema: $!");
	}
	else {
		local $/;
		my $sql_text = <$in>;
		close $in;
		unlink $db if -e $db;    # too small to be a database; database_grabber ignores it
		if (open(my $pipe, '|-', 'sqlite3', $db)) {
			print {$pipe} $sql_text;
			close $pipe;
			if ($? == 0 && -s $db > 5000) {
				say_line('built database/jawnos.db from database/schema.sql');
			}
			else {
				say_line('sqlite3 could not build database/jawnos.db; tests that read it will fail');
			}
		}
		else {
			say_line('sqlite3 is not installed; tests that read the database will fail');
		}
	}
}

exit 0;
