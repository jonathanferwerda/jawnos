# tests-for: qa/ui/frames.py qa/ui/frames.js
# covers:    the frame probe that turns "does the UI feel smooth" into a
#           measurement: it runs in the real Qt WebEngine view, takes the shell's
#           own graphics environment (so a run describes the machine as JawnOS
#           runs it), reports cadence, late and dropped frames per scenario, and
#           its deliberate main-thread stall scores worse than idle -- so a probe
#           that cannot see jank is caught instead of believed.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);
use JSON::PP qw(decode_json);

my $root = "$FindBin::Bin/..";
my $py = read_file("$root/qa/ui/frames.py");
my $js = read_file("$root/qa/ui/frames.js");
my $notes = read_file("$root/qa/ui/NOTES.md");

# The page side: intervals from the animation clock, reduced to late and
# dropped frames against the display's own cadence, with the main thread's own
# cost recorded beside them.
like($js, qr/requestAnimationFrame/, 'frames are sampled from the animation clock');
like($js, qr/lateFrames/, 'late frames are counted, not averaged away');
like($js, qr/dropped/, 'frames are counted against the display cadence');
like($js, qr/longtask/, 'Long Tasks are recorded beside the intervals');
like($js, qr/long-animation-frame/, 'and Long Animation Frames where the engine has them');
like($js, qr/UNMASKED_RENDERER_WEBGL/, 'the report names the renderer that paints');
like($js, qr/"scroll"/, 'a scroll scenario exists');
like($js, qr/"scrollpage"/, 'and one that scrolls the loaded page itself');
like($js, qr/"busy"/, 'the main-thread stall control exists');

# The driver side: the shell's own graphics setup, so a number describes the
# machine as JawnOS runs it rather than a probe's private idea of it.
like($py, qr/from jawnos_desktop import gpu/, "the probe uses the shell's own graphics setup");
like($py, qr/gpu\.prepare_env\(os\.environ\)/, 'including the qt.env escape hatches');
like($py, qr/--software/, 'and can ask for the software path CI has');
like($py, qr/--settle/, 'and lets a real page finish opening its windows first');
like($py, qr/def redact_url/, 'a ticket URL is redacted before it reaches a report');
like($py, qr/--hidden throttles/, 'and a hidden window is called out, not measured');
like($js, qr/the page does not scroll/,
	'a page with no scroll range is reported, not measured as smooth');

# The token is the credential: it must not survive into the report, a log or a
# paste. The ticket's path goes too -- only the host is a report's business.
my $redact = qx{cd "$root" && python3 -c 'import sys; sys.path.insert(0, "qa/ui"); import frames; print(frames.redact_url("https://h:3000/box_office/abc?s=SECRET"))' 2>&1};
is($redact, "https://h:3000\n", 'the ticket token and path do not survive redaction')
	or diag($redact);
like($py, qr/certificateError/, "accepts the house's certificate");
like($py, qr/"engine": "qtwebengine"/, 'the report names the engine');

like($notes, qr/frames\.py/, 'the probe is documented where the other qa/ui probes are');

# And it measures. The control has to be worse than idle, or the probe is only
# reporting a smooth run it assumed.
my $have_qt = system("python3 -c 'import PySide6.QtWebEngineWidgets' >/dev/null 2>&1") == 0;
my $have_xvfb = system('command -v xvfb-run >/dev/null 2>&1') == 0;

SKIP: {
	skip 'PySide6 Qt WebEngine is not installed here', 6 unless $have_qt;
	skip 'xvfb-run is not installed here', 6 unless $have_xvfb;

	my $tmp = tempdir(CLEANUP => 1);
	my $out = "$tmp/frames.json";
	my $run = `cd "$root" && timeout 180 xvfb-run -a python3 qa/ui/frames.py \\
		--software --no-sandbox --size 800x600 --scenario idle,busy \\
		--out "$out" 2>&1`;
	my $code = $? >> 8;

	is($code, 0, 'a measured run exits 0') or diag(substr($run, 0, 800));
	ok(-s $out, 'it wrote the JSON report');

	# read_file is list-context sensitive: assign first, then decode.
	my $json = -s $out ? read_file($out) : "";
	my $report = $json ? eval { decode_json($json) } : {};
	$report ||= {};
	my %by = map { $_->{scenario} => $_ } @{ $report->{scenarios} || [] };
	ok(($by{idle}{frames} || 0) > 20, 'idle recorded frames');
	ok(($by{busy}{p95} || 0) > ($by{idle}{p95} || 0),
		'the main-thread stall is slower than idle');
	ok(($by{busy}{latePct} || 0) > ($by{idle}{latePct} || 0),
		'and more of its frames are late');
	ok(length($report->{gpu} || ''), 'the report says which renderer painted');
}

done_testing();
