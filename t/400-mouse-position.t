# tests-for: public/js/universal/01_inventory_time_readings.js
# covers:    mouse_position keeps the last real pointer when a timer or an
#            init handler asks while the last dispatched event was not a mouse
#            move. The undefined pair it used to copy made the theatre's idle
#            check throw in elementsFromPoint, so the player bar stayed over
#            the picture after a reload.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);

my $root = "$FindBin::Bin/..";
my $js = read_file("$root/public/js/universal/01_inventory_time_readings.js");
my ($fn) = $js =~ /(function mouse_position\(\) \{.*?\n\})/s;
ok($fn, 'the pointer helper is where the page expects it');

my $node = `command -v node 2>/dev/null`;
chomp $node;
SKIP: {
	skip 'node is not installed', 3 unless length $node;
	skip 'the helper was not found', 3 unless defined $fn;

	my $code = "global.window = {};\n"
		. "var mLastX = 0, mLastY = 0, mLastTs = Date.now();\n"
		. $fn . "\n"
		. "window.event = { clientX: 111, clientY: 222 };\n"
		. "var a = mouse_position();\n"
		. "window.event = { type: 'resize' };\n"
		. "var b = mouse_position();\n"
		. "window.event = null;\n"
		. "var c = mouse_position();\n"
		. "console.log(JSON.stringify({ a: [a.x, a.y], b: [b.x, b.y], c: [c.x, c.y] }));\n";
	my $dir = tempdir(CLEANUP => 1);
	my $tmp = "$dir/mouse-position.js";
	open(my $fh, '>', $tmp) or die "$tmp: $!";
	print {$fh} $code;
	close $fh;
	my @out = split /\n/, `$node "$tmp" 2>&1`;
	my $got = eval { decode_json($out[0] // '') } || {};
	is_deeply($got->{'a'}, [111, 222], 'a pointer event sets the point');
	is_deeply($got->{'b'}, [111, 222], 'a later non-pointer event keeps it');
	is_deeply($got->{'c'}, [111, 222], 'and so does no event at all');
}

done_testing();
