# tests-for: scripts/jawnos_setup.pl lib/JawnOS/Domain/Render.pm lib/JawnOS/Manager/Part02.pm
# covers:    The tenth audit pass: the setup code and the session key are drawn
#           from the OS, a legacy derived session key is rotated, and a filename
#           header cannot carry a newline.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

sub source { return read_file(root() . '/' . $_[0]) }

my $setup = source('scripts/jawnos_setup.pl');
like($setup, qr/Crypt::PRNG::random_bytes/, 'the setup code draws from the OS');
unlike($setup, qr/int\( rand\(100000000\) \)/, 'it is no longer an 8-digit rand()');
like($setup, qr/while \( length\(\$fresh\) < 12 \)/, 'and it is twelve digits, not eight');

my $render = source('lib/JawnOS/Domain/Render.pm');
like($render, qr/sub session_secret_rotate_legacy/, 'a legacy derived key can be rotated');
like($render, qr/session_secret_rotate_legacy\(\$pinned\)/, 'a boot calls the rotation');
like($render, qr/unpack 'H\*', Crypt::PRNG::random_bytes\(16\)/, 'a fresh key is random hex');
unlike($render, qr/print \$fh \$derived, "\\n";/, 'the derivation is no longer written as the key');
like($render, qr/sub session_secret_boot_key/, 'an unwritable home gets a private boot key');
like($render, qr/Fcntl::O_EXCL\(\), 0600\)/, 'created exclusively and private');

my $part02 = source('lib/JawnOS/Manager/Part02.pm');
like($part02, qr/\$name =~ s\/\[\\r\\n\]\+\/ \/g;/, 'a filename header loses its CR/LF');
like($part02, qr/\$name =~ s\/\[\^\\x20-\\x7e\]\/_\/g;/, 'and keeps only printable ASCII');

done_testing();
