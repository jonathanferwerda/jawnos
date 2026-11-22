# tests-for: public/js/music.js templates/apps/music/files.html.ep
# covers:    The music list view (mounted offset and top row) is saved with the
#            player cache and restored on the next open, tied to the queue token
#            so a view of another library is never applied. The pure window
#            arithmetic clamps and snaps the saved slice.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);

my $music = read_file("$FindBin::Bin/../public/js/music.js");

# --- the helpers exist ------------------------------------------------------
my ($view_of)      = $music =~ /(function musicViewOf\(\)\s*\{.*?\n\})/s;
my ($view_window)  = $music =~ /(function musicViewWindow\(saved, total, limit, columns\)\s*\{.*?\n\})/s;
my ($view_pending) = $music =~ /(function musicViewPending\(saved\)\s*\{.*?\n\})/s;
my ($view_align)   = $music =~ /(function musicViewAlign\(view\)\s*\{.*?\n\})/s;
ok(defined $view_of,      'musicViewOf is found');
ok(defined $view_window,  'musicViewWindow is found');
ok(defined $view_pending, 'musicViewPending is found');
ok(defined $view_align,   'musicViewAlign is found');

# --- the saver writes the view ---------------------------------------------
my ($saver) = $music =~ /(function playerCacheSaver\(type, force\)\s*\{.*?\n\})/s;
ok(defined $saver, 'playerCacheSaver is found');
like($saver // '', qr/\bview: musicViewOf\(\)/,
	'the player cache carries the list view beside the resizes');
like($saver // '', qr/if \(musicUnlocked\(\)\) \{/,
	'and the unlocked window still refuses the write');

# The view is tied to the queue it was taken from, not just its offset.
like($view_of // '', qr/getElementById\('music_queue_data'\)/,
	'musicViewOf reads the queue element');
like($view_of // '', qr/getAttribute\('token'\)/,
	'and names the view by the queue token');
like($view_pending // '', qr/saved_token != current_token/,
	'a saved view from a different queue token is dropped');

# --- musicInit carries the saved view into the window ----------------------
my ($init) = $music =~ /(async function musicInit\(method\)\s*\{.*?\n\})/s;
ok(defined $init, 'musicInit is found');
like($init // '', qr/var saved_view = null;/,
	'musicInit starts with no saved view');
like($init // '',
	qr/saved_view = \(pd\.view && typeof pd\.view == 'object'\) \? pd\.view : null;/,
	'the player cache view is taken only when it is an object');
like($init // '', qr/musicWindowInit\(saved_view\);/,
	'and handed to the window init');

# --- the window init applies the view before the empty-slice fallback ------
my ($winit) = $music =~ /(function musicWindowInit\(restore\)\s*\{.*?\n\})/s;
ok(defined $winit, 'musicWindowInit takes an optional restore');
like($winit // '', qr/musicViewPending\(restore\)/,
	'the saved view is validated against this list');
like($winit // '', qr/musicViewWindow/,
	'and is clamped through the pure window arithmetic');
my $restore_at = index($winit // '', 'if (restore)');
my $empty_at   = index($winit // '', 'musicWindowFetch(0,');
ok($restore_at >= 0 && $empty_at >= 0 && $restore_at < $empty_at,
	'the restore branch runs before the unconditional top-of-list fetch');
like($winit // '', qr/if \(!restored && s\.total > 0/,
	'the empty-slice fetch is skipped once a view is restored');
like($winit // '', qr/playerCacheSaver\(undefined, true\)/,
	'the restored slice is saved again so the view is not lost');

# --- the fetch lets a caller wait for the mount ----------------------------
my ($fetch) = $music =~ /(function musicWindowFetch\(start, end, force, done\)\s*\{.*?\n\})/s;
ok(defined $fetch, 'musicWindowFetch takes a fourth parameter');
like($fetch // '', qr/typeof done == 'function'/,
	'and runs the callback only when it is one');
my ($succ, $err) = split(/error:\s*function\s*\(\)\s*\{/, $fetch // '', 2);
like($succ // '', qr/\bfinish\(\)/,
	'the waiter is settled after the mounted slice is measured and applied');
like($err // '', qr/\bfinish\(\)/,
	'and also when the request fails, so it cannot hang');

# --- the pure helper, run in node ------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node;
my @args = (
	[ { offset => 9999 }, 100, 60, 1 ],  # clamp to the last row
	[ { offset => -5 },   100, 60, 1 ],  # clamp below zero
	[ { offset => 7 },    100, 60, 3 ],  # snap down to a grid row
	[ { offset => 0 },    100, 61, 3 ],  # round the end up to a grid row
	[ { offset => 95 },   100, 60, 1 ],  # clamp the end at the total
	[ { offset => 5 },    0,   60, 1 ],  # an empty queue yields an empty slice
);
my @want = (
	{ offset => 99, start => 99, end => 100 },
	{ offset => 0,  start => 0,  end => 60 },
	{ offset => 6,  start => 6,  end => 66 },
	{ offset => 0,  start => 0,  end => 63 },
	{ offset => 95, start => 95, end => 100 },
	{ offset => 0,  start => 0,  end => 0 },
);
SKIP: {
	skip 'node is not installed', scalar(@args) + 1 unless length $node;
	skip 'musicViewWindow was not found', scalar(@args) + 1 unless defined $view_window;

	my $code = $view_window . "\n"
		. 'var cases = ' . encode_json(\@args) . ";\n"
		. "for (var i = 0; i < cases.length; i++) {\n"
		. "  console.log(JSON.stringify(musicViewWindow.apply(null, cases[i])));\n"
		. "}\n"
		. "console.log(typeof document);\n";
	my $dir = tempdir(CLEANUP => 1);
	my $tmp = "$dir/music-view-window.js";
	open(my $fh, '>', $tmp) or die "$tmp: $!";
	print {$fh} $code;
	close $fh;
	my @out = split /\n/, `$node "$tmp" 2>&1`;
	chomp @out;
	is(scalar @out, scalar(@args) + 1, 'the helper ran for every case');
	my $doc_type = pop @out;
	for my $i (0 .. $#args) {
		my $got = eval { decode_json($out[$i]) };
		is_deeply($got, $want[$i], "case $i clamps and snaps as expected")
			or diag("raw output: $out[$i]");
	}
	is($doc_type, 'undefined',
		'musicViewWindow touches no DOM (no document exists under node)');
}

done_testing();
