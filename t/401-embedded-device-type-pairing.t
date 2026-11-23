# tests-for: templates/embedded/body.html.ep templates/embedded/embedded.html.ep public/js/manager/embedded.js lib/JawnOS/Manager/Part34.pm lib/JawnOS/Controller/manager_embedded.pm lib/JawnOS/Routes/manager_embedded.pm perl/help/topics_configure.pl
# covers:    the Embedded type and device pickers follow each other: a chip
#            option carries the purpose the device reports, choosing a type
#            selects the device most recently chosen for that type (falling
#            back to the first), and choosing a chip sets the type from that
#            purpose. The last choice per type is one house-wide settings row,
#            saved through its own route before the panel redraws.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $body    = read_file("$root/templates/embedded/body.html.ep");
my $panel   = read_file("$root/templates/embedded/embedded.html.ep");
my $js      = read_file("$root/public/js/manager/embedded.js");
my $part34  = read_file("$root/lib/JawnOS/Manager/Part34.pm");
my $control = read_file("$root/lib/JawnOS/Controller/manager_embedded.pm");
my $routes  = read_file("$root/lib/JawnOS/Routes/manager_embedded.pm");
my $help    = read_file("$root/perl/help/topics_configure.pl");

like($body, qr/<option value="<%= \$chip->\{'id'\} %>" data-purpose="<%= \$chip->\{'purpose'\} \/\/ '' %>"/,
	'every chip option carries the purpose the device reports');
like($panel, qr/data-chip-memory="<%= encode_json\(\$chip_memory\) %>"/,
	'the panel carries the house-wide memory into the page');

like($js, qr/function embeddedChipMemory/, 'the panel keeps a per-type memory');
like($js, qr/data-chip-memory/, 'read from the rendered panel');
like($js, qr#/manager/embedded/chip_memory#, 'and saved through its own route');
like($js, qr/function embeddedSaveChipMemory/, 'one save carries every pair the change touched');
like($js, qr/embeddedChipSave = embeddedChipSave\.then\(request, request\)/, 'saves run one at a time, in order');
like($js, qr/\$\.when\(embeddedSaveChipMemory\(\)\)\.always/,
	'the panel redraws only after the house has the choice');

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

like($part34, qr/setting => 'chip_' \. \$type, device => 'all'/,
	'the panel reads a house-wide row for each type');
like($control, qr/^sub action_43555\b/m, 'the chip-memory route has its handler');
like($control, qr/setting => 'chip_' \. \$edt/, 'it writes one setting per type');
like($control, qr/device => 'all'/, 'as a house-wide row');
like($control, qr/foreach my \$edt \( sort keys %wanted \)/, 'only the types the panel changed');
like($routes, qr/\[43555, 'post', '\/manager\/embedded\/chip_memory', 'action_43555'\]/,
	'the route row names the handler');

like($help, qr/pickers follow each other/, 'the Embedded help topic explains the pairing');
like($help, qr/chosen most recently/, 'and says the type returns to the device used last');
like($help, qr/house remembers that choice/, 'and that the choice is the house\'s, not one browser\'s');

done_testing();
