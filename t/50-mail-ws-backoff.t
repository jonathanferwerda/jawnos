# tests-for: public/js/mailbox.js
# covers:    The mail socket is opened by whatever just rendered a window, and the phone's WebView does not take the house'...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

# The mail socket is opened by whatever just rendered a window, and the phone's
# WebView does not take the house's self-signed certificate for a WebSocket
# (onReceivedSslError covers page loads, not the WebSocket handshake). Every
# caller then built another socket: one boot logged 12,089 TLS handshake
# failures, 2,784 'ws+() mail' console lines and 16,885 tailnet stderr lines in
# four minutes - about 25 handshakes a second - and the battery drew ~1.6 A
# with the screen off.
#
# The three parts of the fix: one attempt at a time with a growing delay while
# the page is visible, no attempt at all while it is hidden, and a visibility
# handler that is actually the visibility state (it read e.returnValue, which is
# not the state on a VisibilityStateEvent).

my $mailbox = read_file("$FindBin::Bin/../public/js/mailbox.js");

# 1. the state the retry needs exists
like($mailbox, qr/var mailwsRetryTimer;/, 'the retry timer is declared');
like($mailbox, qr/var mailwsFailures = 0;/, 'the failure count is declared');
like($mailbox, qr/var mailwsBlockedUntil = 0;/, 'the backoff deadline is declared');

# 2. start refuses while hidden, while a retry is pending, and inside backoff
my ($start) = $mailbox =~ /function mailWebSocketStart\(\) \{(.*?)\n\}/s;
ok(defined $start, 'mailWebSocketStart is found');
like($start // '', qr/if \(document\.hidden\) \{ return false; \}/,
	'a hidden page opens no socket');
like($start // '', qr/if \(mailwsRetryTimer\) \{ return false; \}/,
	'only one attempt is in flight at a time');
like($start // '', qr/if \(Date\.now\(\) < mailwsBlockedUntil\) \{ return false; \}/,
	'a caller cannot jump the backoff');

# 3. an open or connecting socket of the same address is kept
like($start // '', qr/mailws\.readyState == 0 \|\| mailws\.readyState == 1/,
	'a connecting socket is not torn down and rebuilt');

# 4. close does not start, and close is what a rebuild uses
my ($close) = $mailbox =~ /function mailWebSocketClose\(\) \{(.*?)\n\}/s;
ok(defined $close, 'mailWebSocketClose is found');
unlike($close // '', qr/mailWebSocketStart\(\)/,
	'closing a socket does not open another');

# 5. a lost socket schedules exactly one retry, with a growing capped delay
my ($onclose) = $mailbox =~ /mailws\.onclose = function \(event\) \{(.*?)\n\t\};/s;
ok(defined $onclose, 'the close handler is set');
like($onclose // '', qr/if \(this !== mailws\) \{ return; \}/,
	'a replaced socket does not schedule a retry');
like($onclose // '', qr/mailWebSocketRetry\(\)/,
	'a lost socket schedules a retry');
my ($retry) = $mailbox =~ /function mailWebSocketRetry\(\) \{(.*?)\n\}/s;
ok(defined $retry, 'mailWebSocketRetry is found');
like($retry // '', qr/Math\.min\(30000, 2000 \* Math\.pow\(2, mailwsFailures - 1\)\)/,
	'the retry delay doubles up to the cap');
like($retry // '', qr/if \(document\.hidden\) \{ return; \}/,
	'a hidden page schedules no timer to wake it');

# 6. the visibility handler reads the real state, not the legacy returnValue
unlike($mailbox, qr/returnValue/, 'no handler tests the legacy returnValue as visibility');
like($mailbox, qr/document\.addEventListener\("visibilitychange", function\(\) \{\s*\n(?:\s*\/\/[^\n]*\n)*\s*if \(!document\.hidden\) \{ mailWebSocketStart\(\); \}/,
	'a page coming back on screen opens the socket');

# 7. a wake with no handle reopens it instead of returning
my ($wake) = $mailbox =~ /function mailWebSocketWake\(\) \{(.*?)\n\}/s;
like($wake // '', qr/if \(typeof mailws != 'object' \|\| !mailws\) \{\s*\n\s*mailWebSocketStart\(\);/,
	'a wake with no socket opens one');

# 8. the rules themselves, run against a WebSocket that always fails its
#    handshake, so "one attempt at a time" and the delay curve are observed
#    rather than inferred from the source.
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my $harness = "$FindBin::Bin/lib/mail_ws_backoff.js";
	my $out = `$node "$harness" "$FindBin::Bin/../public/js/mailbox.js" 2>&1`;
	my $status = $? >> 8;
	my @lines = grep { /^(?:not )?ok / } split /\n/, $out;
	ok(scalar @lines >= 5, 'the reconnect harness ran');
	for my $line (@lines) {
		my ($verdict, $name) = $line =~ /^(ok|not ok) (.*)$/;
		ok($verdict eq 'ok', $name);
	}
	is($status, 0, 'the reconnect harness exits clean');
}
else {
	diag('node is not installed; the behavioural reconnect checks are skipped');
}

done_testing();
