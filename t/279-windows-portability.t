# tests-for: lib/JawnOS/Domain/Tunnel.pm lib/JawnOS/Domain/Calendar.pm
# covers:    the house key is drawn from the OS on every platform — Windows has
#            no /dev/urandom, so a device-only draw produced an empty key, an
#            unkeyed vault and a ticket login that was always refused — and the
#            socket drain never asks Winsock for MSG_DONTWAIT, a constant Socket
#            exports and then dies on when it is called.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use MIME::Base64 qw(decode_base64);
use JawnOSTest;

my $root = root();

sub read_source {
	my ($rel) = @_;
	open(my $fh, '<', "$root/$rel") or die "read $rel: $!\n";
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

# --- the house key ----------------------------------------------------------

subs::preload('house_key');
my $tmp = tempdir('jawnos-housekey-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$subs::home_dir    = $tmp;
$subs::install_dir = $root;

my $path = "$tmp/.house.key";
ok(!-e $path, 'no key file before the first call');

my $first = eval { subs::house_key() };
ok(!$@, 'the key is drawn without dying') or diag($@);
ok(defined $first && length $first, 'a key is produced');
ok(-e $path, 'and written beside the house');
is(length(decode_base64($first)), 32, 'the key is 32 bytes of OS randomness');
is(subs::house_key(), $first, 'a second call reuses the file instead of drawing again');

like(read_source('lib/JawnOS/Domain/Tunnel.pm'), qr/Crypt::PRNG/,
	'the draw asks CryptX, so a platform without /dev/urandom still gets a key');

# An existing key that cannot be read is never replaced. The old call drew a
# new key and wrote it over the real one, so a home that was briefly
# unavailable (Android's external storage, a mount coming up) rotated the key
# and made every sealed row - the vault included - look corrupt.
SKIP: {
	skip 'root can read a 0000 file', 3 if $< == 0;
	my $guarded = tempdir('jawnos-housekey-guard-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	my $old_home = $subs::home_dir;
	$subs::home_dir = $guarded;
	my $gpath = "$guarded/.house.key";
	open(my $g, '>', $gpath) or die "$gpath: $!";
	print $g "an-existing-key\n";
	close $g;
	chmod 0000, $gpath;
	my $none = eval { subs::house_key() };
	my $err = $@;
	chmod 0600, $gpath;
	$subs::home_dir = $old_home;
	ok(!$err, 'an unreadable key file does not die') or diag($err);
	is($none, '', 'and yields no key instead of drawing a replacement');
	open(my $r, '<', $gpath) or die "$gpath: $!";
	local $/;
	my $after = <$r>;
	close $r;
	is($after, "an-existing-key\n", 'the existing key is left byte for byte');
}

# A create race must not replace the winner: an existing file is the key.
{
	my $race = tempdir('jawnos-housekey-race-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	my $old_home = $subs::home_dir;
	$subs::home_dir = $race;
	my $rpath = "$race/.house.key";
	open(my $w, '>', $rpath) or die "$rpath: $!";
	print $w "winner-key\n";
	close $w;
	is(subs::house_key(), 'winner-key', 'an existing key wins the create race');
	$subs::home_dir = $old_home;
}

my $tunnel = read_source('lib/JawnOS/Domain/Tunnel.pm');
like($tunnel, qr/Fcntl::O_EXCL/, 'the house key is created exclusively');
unlike($tunnel, qr/write_file\(\$path/, 'a house key is never written over an existing file');

# --- the socket drain -------------------------------------------------------

# Whole-line comments are removed first: the module explains in prose why the
# flag is avoided, and only the code is under test.
(my $calendar = read_source('lib/JawnOS/Domain/Calendar.pm')) =~ s/^\s*#.*$//mg;
unlike($calendar, qr/MSG_DONTWAIT/,
	'the drain never passes MSG_DONTWAIT (undefined on Winsock)');
like($calendar, qr/IO::Select/,
	'it asks IO::Select whether there is anything to read instead');

done_testing();
