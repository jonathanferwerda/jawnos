# tests-for: lib/JawnOS/Domain/Render.pm
# covers:    a signatorial call with no context does not print an uninitialized-value warning on
#            every render (that warning filled a small terminal and blocked the workers); and the
#            bootstrap's read of an unreadable path stays as tolerant as the shell `cat` it
#            replaced, because the identity migration runs at boot.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use MIME::Base64 ();
use Mojo::Util ();
use JawnOSTest;

subs::preload('signatorial_establisher random_string_creator');

my @warnings;
{
	local $SIG{__WARN__} = sub { push @warnings, @_ };
	local $subs::config = {};
	my $secret = &subs::signatorial_establisher();
	like($secret, qr/^.{12}$/, 'a house with no signatorial image gets a 12-character fallback');
}
is(scalar @warnings, 0, 'no uninitialized-value warning is printed')
	or diag(@warnings);

# The bootstrap read the signatorial with `cat`, which contributed nothing when
# the path was a directory or unreadable. File::Slurp::read_file can die there
# instead, and the legacy identity migration runs at boot, so a crash here is a
# crash on every start. A directory therefore must still yield the md5 of the
# empty contribution - stable, never a die.
{
	my $dir = tempdir(CLEANUP => 1);
	my ($secret, $error);
	{
		local $subs::config = { signatorial => $dir };
		local $gb::secret_maker = undef;
		$secret = eval { &subs::signatorial_establisher('designer') };
		$error = $@;
	}
	is($error, '', 'a directory as the signatorial image does not die');
	like($secret, qr/^[0-9a-f]{32}$/, 'the identity is still a 32-hex md5');
	is($secret, Mojo::Util::md5_sum(MIME::Base64::encode_base64('')),
		'a path that contributes nothing hashes the empty base64 string');
}

done_testing();
