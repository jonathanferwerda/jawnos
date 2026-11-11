# tests-for: lib/JawnOS/Domain/Sync.pm lib/JawnOS/Manager/Part08.pm lib/JawnOS/Controller/manager_misc3.pm lib/JawnOS/Domain/House.pm lib/JawnOS/Domain/Loader.pm
# covers:    The AEAD cutover rolls: a puller names the seal it reads in a
#           signed query parameter, an older puller gets the legacy seal, and
#           the LAN probe (whose key is public anyway) keeps the old one.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

sub source { return read_file(root() . '/' . $_[0]) }

subs::preload('encrypter encrypter_legacy decrypter decrypter_strict');

# --- the legacy sealer is the old format, and both readers still read it ----
my $old = subs::encrypter_legacy('roll-key', 'legacy payload');
ok(defined $old && length $old, 'the legacy sealer writes a blob');
unlike($old, qr/\AJS1:/, 'it does not name the AEAD format');
is(subs::decrypter('roll-key', $old), 'legacy payload', 'the ordinary reader reads it');
is(subs::decrypter_strict('roll-key', $old), 'legacy payload', 'the strict reader reads it under the real key');
isnt(subs::decrypter_strict('other-key', $old), 'legacy payload', 'and not under another key');

# --- a new puller asks for JS1 in the signed query --------------------------
my $part08 = source('lib/JawnOS/Manager/Part08.pm');
like($part08, qr/&limit=500&seal=js1/, 'a row batch asks for the AEAD seal');
like($part08, qr/&band=' \. int\(\$band\) \. '&seal=js1/, 'a bucket map asks for it too');

# --- the donor seals to what the puller names -------------------------------
my $misc3 = source('lib/JawnOS/Controller/manager_misc3.pm');
my $choices = () = $misc3 =~ /\$c->param\('seal'\)/g;
cmp_ok($choices, '>=', 2, 'both sync rails read the seal parameter');
my $legacy = () = $misc3 =~ /&subs::encrypter_legacy\(\$secret, \$plain\)/g;
is($legacy, 2, 'and both fall back to the legacy seal');
my $aead = () = $misc3 =~ /&subs::encrypter\(\$secret, \$plain\)/g;
is($aead, 2, 'while a JS1 puller gets AEAD');

# --- the LAN probe keeps the seal every build reads -------------------------
my $house = source('lib/JawnOS/Domain/House.pm');
like($house, qr/&encrypter_legacy\(&shorthand_name/, 'the probe token uses the legacy seal');
unlike($house, qr/&encrypter\(&shorthand_name/, 'and no longer the AEAD one');

# --- the sealer is a registered domain sub ---------------------------------
like(source('lib/JawnOS/Domain/Loader.pm'), qr/encrypter encrypter_legacy decrypter/,
	'encrypter_legacy is in the domain map');

done_testing();
