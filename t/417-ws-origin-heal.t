# tests-for: public/js/manager/websocket.js
# covers:    A page that fell back to its own origin while the websocket
#            listener was between boots goes back to the configured listener.
#            The origin answers the page's beats, so the page looked alive while
#            every server push (a remote Music play, a window opener) went to the
#            websocket worker and was delivered nowhere.

use strict;
use warnings;

use FindBin;
use Test::More;
use File::Slurp qw(read_file);

my $js = read_file("$FindBin::Bin/../public/js/manager/websocket.js");

# The fallback remembers when it happened, so the status beat can time the retry.
like($js, qr/var ws_origin_only_at = 0;/, 'the origin fallback is stamped');
like($js, qr/var ws_origin_retry_delay = 30000;/, 'the first retry is 30s away');
like($js, qr/var ws_origin_retry_max = 300000;/, 'and backs off to five minutes');

# onclose marks the fallback and its time.
like($js, qr/if \(!address && ws\[app\] && ws\[app\]\['status'\] == 'connect'\) \{\s*\n\s*ws_origin_only = 1;\s*\n\s*if \(!ws_origin_only_at\) \{ ws_origin_only_at = Date\.now\(\); \}/,
	'a socket that never opened starts the fallback clock');

# The status beat retries the configured listener and backs off.
like($js, qr/\$\.each\(ws, function\(i,v\) \{.*?\}\);\s*\n\s*\/\/ The origin fallback answers beats.*?\n\s*if \(windowVisible == 1 && ws_origin_only && !jawn_resting\(\)/s,
	'the retry runs on the status beat');
like($js, qr/\(timestamp - \(ws_origin_only_at \|\| 0\)\) > ws_origin_retry_delay/, 'the wait is measured from the fallback');
like($js, qr/ws_origin_only = 0;\s*\n\s*ws_origin_only_at = 0;\s*\n\s*ws_origin_retry_delay = Math\.min\(ws_origin_retry_max, ws_origin_retry_delay \* 2\);\s*\n\s*websocketRebuild\(\);/,
	'the retry clears the fallback and rebuilds onto the configured listener');

# A socket that opens on the configured listener forgets the fallback backoff.
like($js, qr/if \(!ws_origin_only\) \{\s*\n\s*ws_origin_only_at = 0;\s*\n\s*ws_origin_retry_delay = 30000;\s*\n\s*\}/,
	'a configured-listener open resets the fallback backoff');

done_testing();
