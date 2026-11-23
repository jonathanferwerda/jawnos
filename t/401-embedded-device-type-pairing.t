# tests-for: templates/embedded/body.html.ep public/js/manager/embedded.js perl/help/topics_configure.pl
# covers:    the Embedded type and device pickers follow each other: a chip
#            option carries the purpose the device reports, choosing a type
#            selects the device most recently chosen for that type (falling
#            back to the first), and choosing a chip sets the type from that
#            purpose.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $body = read_file("$root/templates/embedded/body.html.ep");
my $js   = read_file("$root/public/js/manager/embedded.js");
my $help = read_file("$root/perl/help/topics_configure.pl");

like($body, qr/<option value="<%= \$chip->\{'id'\} %>" data-purpose="<%= \$chip->\{'purpose'\} \/\/ '' %>"/,
	'every chip option carries the purpose the device reports');

like($js, qr/function embeddedChipMemory/, 'the panel keeps a per-type memory');
like($js, qr/embedded_chip_by_type/, 'in its own stored map');
like($js, qr/function embeddedRememberChip/, 'and can record a choice');
like($js, qr/embeddedRememberRenderedChip\(\);/, 'the selection on screen is remembered too');

my ($picker) = $js =~ /(\$\(document\)\.on\('change', '#embedded_device_picker'.*?\n\}\);)/s;
ok($picker, 'the type picker has its handler');
like($picker, qr/data-purpose/, 'it reads the purpose from the chip options');
like($picker, qr/embeddedChipMemory\(\)\[edt\]/, 'it looks up the device most recently chosen for the type');
like($picker, qr/\$\(this\)\.val\(\) === remembered/,
	'and prefers that device when it is still in the fleet list');
like($picker, qr/embeddedRememberChip\(current_purpose, current_id\)/,
	'it keeps the device it leaves behind as that type\'s most recent');
like($picker, qr/embeddedRememberChip\(edt, chosen\)/,
	'and records the device it settles on');
like($picker, qr/localStorage\.setItem\('embedded_chip_id'/, 'remembering the chosen chip');

my ($chip) = $js =~ /(\$\(document\)\.on\('change', '#embedded_device_chip_id'.*?\n\}\);)/s;
ok($chip, 'the device picker has its handler');
like($chip, qr/option:selected'\).attr\('data-purpose'\)/, 'it reads the selected chip\'s purpose');
like($chip, qr/embeddedRememberChip\(purpose, chip_id\)/,
	'choosing a device makes it that type\'s most recent');
like($chip, qr/picker\.val\(purpose\)/, 'and sets the type from it');
like($chip, qr/picker\.find\('option'\)\.filter/, 'only a purpose the type picker can show wins');

like($help, qr/pickers follow each other/, 'the Embedded help topic explains the pairing');
like($help, qr/chosen most recently/, 'and says the type returns to the device used last');

done_testing();
