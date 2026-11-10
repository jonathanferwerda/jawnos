# tests-for: lib/JawnOS/Domain/Render.pm
# covers:    a signatorial call with no context does not print an uninitialized-value warning on
#            every render (that warning filled a small terminal and blocked the workers); the
#            bootstrap's read of an unreadable path stays as tolerant as the shell `cat` it
#            replaced, because the identity migration runs at boot; and the session key is chosen
#            once and persisted, so a boot that cannot read the signatorial image keeps the key an
#            earlier boot chose instead of invalidating every session cookie.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use MIME::Base64 ();
use Mojo::Util ();
use JawnOSTest;

subs::preload('signatorial_establisher session_secret_file session_secret_pin random_string_creator');

# ~/.president/session_secret must land in a throwaway home, not the runner's.
local $subs::home_dir = tempdir(CLEANUP => 1);
my $secret_file = &subs::session_secret_file();

sub reset_secret { unlink $secret_file; return }

my @warnings;
{
	reset_secret();
	local $SIG{__WARN__} = sub { push @warnings, @_ };
	local $subs::config = {};
	local $gb::secret_maker = undef;
	my $secret = &subs::signatorial_establisher();
	like($secret, qr/^[0-9a-f]{32}$/, 'a house with no signatorial image gets the deterministic key');
	is($secret, Mojo::Util::md5_sum('signatorial:jawnos'), 'the key is the fallback derivation');
}
is(scalar @warnings, 0, 'no uninitialized-value warning is printed')
	or diag(@warnings);

is((stat $secret_file)[2] & 07777, 0600, 'the secret file is private to its owner');
{
	open my $fh, '<', $secret_file or die "cannot read $secret_file: $!";
	local $/;
	my $stored = <$fh>;
	$stored =~ s/\s+\z//;
	is($stored, Mojo::Util::md5_sum('signatorial:jawnos'),
		'the file holds the key byte-for-byte (the trailing newline is trimmed)');
}

# The bootstrap read the signatorial with `cat`, which contributed nothing when
# the path was a directory or unreadable. File::Slurp::read_file can die there
# instead, and the legacy identity migration runs at boot, so a crash here is a
# crash on every start. A directory therefore must still yield the md5 of the
# empty contribution - stable, never a die.
{
	reset_secret();
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

# The regression: the signatorial image lives on external storage on Android and
# is not readable at every boot. Before the key was persisted, that made a boot
# derive the fallback while the previous boot had derived the image md5 - two
# different keys, so every cookie signed with the old one was rejected and the
# person had to sign in again. The key must now survive the image coming back.
{
	my $dir = tempdir(CLEANUP => 1);
	my $missing = "$dir/not-there.png";
	my $image = "$dir/portrait.png";
	reset_secret();

	my $fallback = Mojo::Util::md5_sum('signatorial:' . $missing);
	my ($first, $first_memo);
	{
		local $subs::config = { signatorial => $missing };
		local $gb::secret_maker = undef;
		$first = &subs::signatorial_establisher();
		$first_memo = $gb::secret_maker;
	}
	is($first, $fallback, 'a first boot with no readable image pins the fallback');
	is_deeply($first_memo, [ $fallback ], 'and signs this worker with it');

	open my $fh, '>', $image or die "cannot write $image: $!";
	print $fh "portrait\n";
	close $fh;
	my $image_key = Mojo::Util::md5_sum(MIME::Base64::encode_base64("portrait\n"));
	isnt($image_key, $fallback, 'the image really would derive a different key');

	my ($second, $second_memo);
	{
		local $subs::config = { signatorial => $image };
		local $gb::secret_maker = undef;
		$second = &subs::signatorial_establisher();
		$second_memo = $gb::secret_maker;
	}
	is($second, $first, 'the image becoming readable does not change the pinned key');
	isnt($second, $image_key, 'the worker does not switch to the image-derived key');
	is_deeply($second_memo, [ $first ], 'the next worker signs with the pinned key too');
}

# The other order, so landing this does not rotate a desktop's sessions: when
# the image was readable at the first boot, later unreadable boots keep its key.
{
	my $dir = tempdir(CLEANUP => 1);
	my $image = "$dir/portrait.png";
	reset_secret();

	open my $fh, '>', $image or die "cannot write $image: $!";
	print $fh "portrait\n";
	close $fh;
	my $image_key = Mojo::Util::md5_sum(MIME::Base64::encode_base64("portrait\n"));

	my $first;
	{
		local $subs::config = { signatorial => $image };
		local $gb::secret_maker = undef;
		$first = &subs::signatorial_establisher();
	}
	is($first, $image_key, 'a readable image still chooses its own bytes first');

	my $second;
	{
		local $subs::config = { signatorial => "$dir/gone.png" };
		local $gb::secret_maker = undef;
		$second = &subs::signatorial_establisher();
	}
	is($second, $image_key, 'a later boot without the image keeps the pinned key');
}

done_testing();
