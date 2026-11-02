# tests-for: lib/JawnOS/Domain/Format.pm lib/JawnOS/Domain/Name.pm scripts/settings_orphans.pl templates/soft_keyboard.html.ep
# covers:    SQLite text is bytes; the formatters decode once, so a name never gains a mojibake
#            layer per save. Corrupt app keys get a short hidden __orphan_ name, never a delete.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use Encode qw(encode);
use Digest::SHA qw(sha256_hex);
use File::Slurp qw(read_file);
use JawnOSTest;

subs::preload('format_name unformat_name path_name html_name http_name kb_symbol_map settings_orphan_plan');

# The database handle is in byte mode, so this is what a stored app name looks
# like: UTF-8 bytes, not a decoded string.
my $bytes = "i" . pack('C*', 0xE2, 0x80, 0x99) . "m_confident";
my $expected = encode('UTF-8', "I’m Confident");

my $formatted = &subs::format_name($bytes);
is(encode('UTF-8', $formatted), $expected, 'format_name decodes a UTF-8 byte string once');
unlike($formatted, qr/[ÃÂâ]/, 'the displayed name carries no mojibake');

my $unformatted = &subs::unformat_name($bytes);
is(encode('UTF-8', $unformatted), $bytes, 'unformat_name returns the stored key');
is(&subs::path_name($bytes), 'i%E2%80%99m_confident', 'a path name keeps the encoded mark, not mojibake');
like(&subs::html_name($bytes), qr/^[A-Za-z0-9_-]+$/, 'a DOM name stays an ASCII token');

# The failure mode was a save growing the name. Ten round trips must not.
my $saved = $bytes;
$saved = &subs::unformat_name(&subs::format_name($saved)) for 1 .. 10;
is(encode('UTF-8', $saved), $bytes, 'ten display/save round trips leave the name unchanged');

my $plan = &subs::settings_orphan_plan([ 'home', "i’m_confident", 'im_confident' ]);
is($plan->{'count'}, 0, 'clean names are left alone');

my $mojibake = encode('UTF-8', "iâ€™m_confident");
my $plan = &subs::settings_orphan_plan([ $mojibake ]);
is($plan->{'count'}, 1, 'a mojibake byte key is quarantined');
my $orphan = $plan->{'rename'}->[0];
like($orphan->{'to'}, qr/^\Q__orphan_\E[0-9a-f]{12}$/, 'the replacement is a short hidden key');
cmp_ok(length($orphan->{'to'}), '<=', 26, 'the new key is small enough for every index');

my $repeated = 'i_do_programming_on_my_laptop' x 4;
$plan = &subs::settings_orphan_plan([ $repeated ]);
is($plan->{'count'}, 1, 'a repeated-name key is quarantined');

my $clean_mark = "i" . pack('C*', 0xE2, 0x80, 0x99) . "ll_go_to_new_york";
$plan = &subs::settings_orphan_plan([ $clean_mark ]);
is($plan->{'count'}, 0, 'a clean typographic apostrophe is not mistaken for mojibake');

my $base = '__orphan_' . substr(sha256_hex($mojibake), 0, 12);
$plan = &subs::settings_orphan_plan([ $mojibake, $base ]);
is($plan->{'count'}, 1, 'a taken orphan key still gets one rename');
is($plan->{'rename'}->[0]->{'to'}, $base . '_2', 'and the replacement is made unique');

$plan = &subs::settings_orphan_plan([ $base ]);
is($plan->{'count'}, 0, 'an already quarantined key is left alone');

my $kbmap = &subs::kb_symbol_map();
my %by_code = map { $kbmap->{$_} => $_ } keys %{$kbmap};
is(encode('UTF-8', $by_code{'GBP'}), encode('UTF-8', "£"), 'the pound mark is a character in the table');
is(encode('UTF-8', $by_code{'EUR'}), encode('UTF-8', "€"), 'the euro mark is a character in the table');
is(encode('UTF-8', $by_code{'KRW'}), encode('UTF-8', "₩"), 'the won mark is a character in the table');

my $repo = root();
my $keyboard = read_file("$repo/templates/soft_keyboard.html.ep");
like($keyboard, qr/kb_symbol_map/, 'the keyboard takes its fiat marks from the table');
unlike($keyboard, qr/\$kb_sym\{'£'\}/, 'the template no longer carries the fiat literals');
my $script = read_file("$repo/scripts/settings_orphans.pl");
like($script, qr/settings_orphan_plan/, 'the migration uses the tested plan');
like($script, qr/sqlite_backup_to_file/, 'it takes a backup before writing');
like($script, qr/reindex settings/i, 'it rebuilds the settings indexes after the rename');
like($script, qr/--apply/, 'writing is opt-in');

done_testing();
