# tests-for: templates/embedded/body.html.ep public/js/manager/embedded.js perl/help/topics_configure.pl
# covers:    the Embedded type and device pickers follow each other: a chip
#            option carries the purpose the device reports, choosing a type
#            selects the first known chip of that type, and choosing a chip
#            sets the type from that purpose.

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

my ($picker) = $js =~ /(\$\(document\)\.on\('change', '#embedded_device_picker'.*?\n\}\);)/s;
ok($picker, 'the type picker has its handler');
like($picker, qr/data-purpose/, 'it reads the purpose from the chip options');
like($picker, qr/\.val\(match\.length \? match\.val\(\) : ''\)/,
	'it selects the matching chip, or the blank choice when the fleet has none');
like($picker, qr/localStorage\.setItem\('embedded_chip_id'/, 'and remembers the chip it chose');

my ($chip) = $js =~ /(\$\(document\)\.on\('change', '#embedded_device_chip_id'.*?\n\}\);)/s;
ok($chip, 'the device picker has its handler');
like($chip, qr/option:selected'\).attr\('data-purpose'\)/, 'it reads the selected chip\'s purpose');
like($chip, qr/picker\.val\(purpose\)/, 'and sets the type from it');
like($chip, qr/picker\.find\('option'\)\.filter/, 'only a purpose the type picker can show wins');

like($help, qr/pickers follow each other/, 'the Embedded help topic explains the pairing');

done_testing();
