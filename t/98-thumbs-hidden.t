# tests-for: scripts/thumbs_hidden.pl
# covers:    the thumbnail-folder migration - move, merge, what it leaves alone,
#           and that a dry run writes nothing

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# Thumbnail folders used to be called `thumbs`; now they are `.thumbs`, so the
# media listings do not show them. This migrates what is already on disk, and the
# two dangerous cases are a half-finished run (both names exist - merge, never
# overwrite) and a `thumbs` that belongs to some other tool (a checkout's cache,
# a trash can) which must be left alone.

my $root   = "$FindBin::Bin/..";
my $script = "$root/scripts/thumbs_hidden.pl";

sub run_pass {
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

sub fixture {
	my $tree = tempdir(CLEANUP => 1);

	# A plain migration.
	make_path("$tree/Pictures/thumbs");
	write_file("$tree/Pictures/thumbs/a.enc", "a\n");
	write_file("$tree/Pictures/thumbs/b.enc", "b\n");

	# A half-finished run: both names exist, and one entry of each kind.
	make_path("$tree/Music/thumbs", "$tree/Music/.thumbs");
	write_file("$tree/Music/thumbs/c.enc", "old-c\n");
	write_file("$tree/Music/.thumbs/c.enc", "new-c\n");
	write_file("$tree/Music/thumbs/only-old.enc", "only-old\n");

	# Someone else's cache folder, which must not be touched.
	make_path("$tree/Trash/thumbs");
	write_file("$tree/Trash/thumbs/e.enc", "e\n");

	return $tree;
}

# --- a dry run says what it would do and writes nothing ---------------------
{
	my $tree = fixture();
	my ($rc, $out) = run_pass('--root', $tree, '--files-only');
	is($rc, 0, 'the dry run exits 0');
	like($out, qr/^move\s+\Q$tree\E\/Pictures\/thumbs -> \Q$tree\E\/Pictures\/\.thumbs$/m,
		'a plain folder is a move');
	like($out, qr/^merge\s+\Q$tree\E\/Music\/thumbs -> \Q$tree\E\/Music\/\.thumbs$/m,
		'a folder whose hidden twin exists is a merge');
	unlike($out, qr/Trash/, 'a trash can is not offered');
	ok(!-e "$tree/Pictures/.thumbs", 'and nothing is created');
	ok(-d "$tree/Pictures/thumbs", 'or removed');
}

# --- --apply moves what it can ----------------------------------------------
{
	my $tree = fixture();
	my ($rc, $out) = run_pass('--root', $tree, '--files-only', '--apply');
	is($rc, 0, 'the migration runs');
	like($out, qr/folders: 1 moved, 1 merged, 0 failed/, 'one move, one merge, nothing failed');

	ok(-d "$tree/Pictures/.thumbs", 'the plain folder is now hidden');
	ok(!-e "$tree/Pictures/thumbs", 'and the old name is gone');
	is(read_file("$tree/Pictures/.thumbs/a.enc"), "a\n", 'with its contents');
	is(read_file("$tree/Pictures/.thumbs/b.enc"), "b\n", 'all of them');

	# The merge kept the hidden copy, took the unique file, and removed the folder.
	is(read_file("$tree/Music/.thumbs/c.enc"), "new-c\n", 'a duplicate keeps the hidden copy');
	is(read_file("$tree/Music/.thumbs/only-old.enc"), "only-old\n", 'a unique file is carried over');
	ok(!-e "$tree/Music/thumbs", 'and the half-finished folder is gone');

	ok(-f "$tree/Trash/thumbs/e.enc", 'a trash can keeps its thumbs folder');
	}

	done_testing();
