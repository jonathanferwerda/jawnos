# tests-for: scripts/media_stub_audit.pl
# covers:    the media stub audit - it lists exactly the sentinel stubs the old
#            sync merge wrote (0x9e, 0x9e 0x89 0xde, and an empty file) and
#            leaves real media alone. --apply refuses to run without a peer to
#            ask, and --check reports a finding through its exit code.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(write_file);
use File::Temp qw(tempdir);

my $root = "$FindBin::Bin/..";
require "$root/scripts/media_stub_audit.pl";

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/a", "$dir/b", "$dir/c");
write_file("$dir/a/one.jpg.enc", "\x9e");
write_file("$dir/a/three.jpg.enc", "\x9e\x89\xde");
write_file("$dir/b/empty.png.enc", '');
write_file("$dir/b/real.jpg.enc", 'Salted__' . ('x' x 32));
write_file("$dir/c/photo.jpg", "\xff\xd8\xff\xe0jpeg-picture");
write_file("$dir/c/notes.txt", "just some words\n");

my $scan = media_stub_scan([$dir]);
is( $scan->{'total'}, 3, 'three sentinel stubs are found' );
is( $scan->{'kind'}->{'one'}, 1, 'the one-byte "no" stub is counted' );
is( $scan->{'kind'}->{'three'}, 1, 'the three-byte "none" stub is counted' );
is( $scan->{'kind'}->{'empty'}, 1, 'an empty file is counted' );
is( $scan->{'bytes'}, 4, 'the byte total is the stubs, not the media' );
is_deeply(
	[ map { $_->{'path'} } @{ $scan->{'files'} } ],
	[ "$dir/a/one.jpg.enc", "$dir/a/three.jpg.enc", "$dir/b/empty.png.enc" ],
	'the real sealed file and the open picture/notes are not stubs'
);

# `main` prints; capture the answer and the exit code.
sub run_main {
	my (@args) = @_;
	my $buf = '';
	{
		open my $fh, '>', \$buf or die "in-memory stdout: $!";
		local *STDOUT = $fh;
		my $rc = main(@args);
		close $fh;
		return ($rc, $buf);
	}
}

my ($rc, $out) = run_main('--root', $dir, '--no-db', '--check');
is( $rc, 1, '--check exits 1 when a stub is found' );
like( $out, qr/3 stub\(s\)/, 'and names the count' );

($rc, $out) = run_main('--root', $dir, '--no-db', '--apply');
is( $rc, 1, '--apply without --from is refused' );
like( $out, qr/--apply needs --from/, 'and says which option is missing' );

my $clean = tempdir(CLEANUP => 1);
write_file("$clean/real.jpg.enc", 'Salted__' . ('x' x 32));
($rc, $out) = run_main('--root', $clean, '--no-db', '--check');
is( $rc, 0, '--check exits 0 on a clean tree' );
like( $out, qr/0 stub\(s\)/, 'and says there is nothing to do' );

done_testing();
