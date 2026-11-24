# tests-for: public/js/universal/01_inventory_time_readings.js
# covers:    mouse_position reads the point kept by a native, capture-phase
#            mousemove recorder, so a handler that asks mid-event gets this move
#            (the seek preview no longer trails the pointer by one) and a timer
#            gets the live point outside an event. The delegated jQuery handler
#            that copied every move into window.event is gone; the point it
#            copied is recorded once, natively. lastX/lastY/lastTs are the
#            point and time the previous caller saw. The window.event and
#            window.mouse globals are still filled on every move, for a native
#            side script that may read them; the page itself reads the record.

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

my ($setter) = $js =~ /(function mouse_position_set\(x, y\) \{.*?\n\})/s;
ok($setter, 'the recorder that keeps the pointer is where the page expects it');
my ($recorder) = $js =~ /(document\.addEventListener\('mousemove'[\s\S]*?\}, \{ capture: true, passive: true \}\);)/;
ok($recorder, 'and the listener that feeds it');
my ($fn) = $js =~ /(function mouse_position\(\) \{.*?\n\})/s;
ok($fn, 'and so is mouse_position');

# --- one native recorder, in front of the handlers --------------------------
like($js, qr/document\.addEventListener\('mousemove',[\s\S]*?\{ capture: true, passive: true \}\);/,
	'the pointer is recorded natively, in the capture phase, and passively');
like($setter, qr/if \(!isFinite\(x\) \|\| !isFinite\(y\)\) \{ return; \}/,
	'a non-pointer pair cannot corrupt the point');
like($recorder, qr/window\.event = e;/, 'the old window.event is still filled for an injected reader');
like($recorder, qr/window\.mouse = e;/, 'and window.mouse with it');
unlike($fn, qr/window\.event/, 'mouse_position reads its own record, not whatever event is current');

SKIP: {
	skip 'node is not installed', 11 unless length(my $node = `command -v node 2>/dev/null`);
	chomp $node;
	skip 'the helpers were not found', 11 unless defined $setter && defined $recorder && defined $fn;

	my $code = "var mLastX = 0, mLastY = 0, mLastTs = Date.now();\n"
		. "var mPrevX = 0, mPrevY = 0, mPrevTs = mLastTs;\n"
		. "global.window = {};\n"
		. "var moveFn = null, opts = null;\n"
		. "global.document = { addEventListener: function (type, fn, o) { if (type === 'mousemove') { moveFn = fn; opts = o; } } };\n"
		. $setter . "\n"
		. $recorder . "\n"
		. $fn . "\n"
		. "var out = {};\n"
		. "out.opts = { capture: !!opts.capture, passive: !!opts.passive };\n"
		. "var ev1 = { clientX: 111, clientY: 222 };\n"
		. "moveFn(ev1);\n"
		. "out.globals = { event: window.event === ev1, mouse: window.mouse === ev1 };\n"
		. "out.a = mouse_position();\n"
		. "out.b = mouse_position();\n"
		. "window.event = { type: 'resize' };\n"
		. "out.c = mouse_position();\n"
		. "moveFn({ clientX: 333, clientY: 444 });\n"
		. "out.d = mouse_position();\n"
		. "mouse_position_set(555, 666);\n"
		. "out.e = mouse_position();\n"
		. "mouse_position_set(undefined, 7);\n"
		. "out.f = mouse_position();\n"
		. "console.log(JSON.stringify(out));\n";
	my $dir = tempdir(CLEANUP => 1);
	my $tmp = "$dir/mouse-position.js";
	open(my $fh, '>', $tmp) or die "$tmp: $!";
	print {$fh} $code;
	close $fh;
	my @out = split /\n/, `$node "$tmp" 2>&1`;
	my $got = eval { decode_json($out[0] // '') } || {};
	my $field = sub {
		my ($name, @keys) = @_;
		return [] unless ref $got->{$name} eq 'HASH';
		return [ @{$got->{$name}}{@keys} ];
	};

	is_deeply($got->{'opts'}, { capture => JSON::PP::true, passive => JSON::PP::true },
		'the recorder is registered in the capture phase and passively');
	is($got->{'globals'}{'event'}, JSON::PP::true, 'the move is still left on window.event');
	is($got->{'globals'}{'mouse'}, JSON::PP::true, 'and on window.mouse, for an injected reader');
	is_deeply($field->('a', qw(x y lastX lastY)), [111, 222, 0, 0],
		'the first ask is the recorded point, with no earlier one');
	is_deeply($field->('b', qw(x y lastX lastY)), [111, 222, 111, 222],
		'a second ask keeps the point and reports the previous one');
	is_deeply($field->('c', qw(x y)), [111, 222],
		'a non-pointer event current at the ask does not overwrite it');
	is($field->('d', 'x')->[0], 333, 'a later move is read at once, not one event behind');
	is($field->('d', 'lastX')->[0], 111, 'and lastX is the point the previous ask saw');
	is($field->('e', 'x')->[0], 555, 'a tap can move the shared point');
	is($field->('e', 'lastX')->[0], 333, 'and the ask before it still sees the move it saw');
	is($field->('f', 'x')->[0], 555, 'a non-finite tap leaves the point alone');
}

done_testing();
