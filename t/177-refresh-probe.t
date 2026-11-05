# tests-for: scripts/tools/refresh-probe.pl scripts/tools/refresh-probe.js
# covers:    the two halves of the WebUI refresh probe. The Perl half turns a
#            browser dump into the reload it saw and the events just before it;
#            the browser half still parses and still carries the hooks that make
#            that report possible.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Temp qw(tempdir);

my $root = abs_path("$FindBin::Bin/..");
my $pl   = "$root/scripts/tools/refresh-probe.pl";
my $js   = "$root/scripts/tools/refresh-probe.js";

ok(-r $pl, 'the perl half is present');
ok(-r $js, 'the browser half is present');

my $src = do { local $/; open(my $fh, '<', $js) or die "$js: $!"; <$fh> };
like($src, qr/jawnosRefreshProbe/, 'the browser half exposes a dump handle');
like($src, qr/jawnosUpdateQuietReload/, 'it watches the quiet-reload path');
like($src, qr/jawnosRevisionArrived/, 'and the revision handler');

my $node = `command -v node 2>/dev/null`;
chomp $node;
SKIP: {
	skip 'node is not installed', 1 unless length $node;
	is(system($node, '--check', $js), 0, 'the browser half parses');
}

sub dump_to {
	my ($dir, $name, $json) = @_;
	my $path = "$dir/$name";
	open(my $fh, '>', $path) or die "$path: $!";
	print {$fh} $json;
	close $fh;
	return $path;
}

my $dir = tempdir(CLEANUP => 1);
my $dump = dump_to($dir, 'browser.json',
	'[{"t":1700000000000,"src":"browser","ev":"hidden"},'
	. '{"t":1700000000100,"src":"browser","ev":"page_load","nav":"reload","since_prev_ms":100,'
	. '"autoreload":"on","prev_events":[{"t":1700000000000,"ev":"hidden"}]}]');
my $out = "$dir/probe.jsonl";
my $report = `"$^X" "$pl" --report --out "$out" --browser "$dump" 2>&1`;
is($? >> 8, 0, 'the report exits 0');
like($report, qr/page loads: reload=1/, 'it counts the reload');
like($report, qr/reload #1/, 'it prints the reload');
like($report, qr/auto=on/, 'it carries the auto-reload setting');
like($report, qr/hidden/, 'it shows the event before the reload');
like($report, qr/browser remembered/, 'and the previous page\'s remembered events');

my $quiet = dump_to($dir, 'navigate.json',
	'[{"t":1700000000000,"src":"browser","ev":"page_load","nav":"navigate"}]');
my $quiet_report = `"$^X" "$pl" --report --out "$out" --browser "$quiet" 2>&1`;
like($quiet_report, qr/no page reloads/, 'a navigating load is not called a reload');

done_testing();
