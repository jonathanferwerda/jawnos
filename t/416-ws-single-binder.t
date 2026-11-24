# tests-for: lib/JawnOS/Manager/Core2_worker_boot.pm
# covers:    Only the websocket worker may bind the manager-to-page push
#            sockets. In development every purpose=main worker also ran that
#            setup, and the last binder owned the path: a console push from a
#            manager worker (a transport command, a window opener) landed in a
#            worker with no browser socket and was delivered nowhere. The
#            browser's socket is on the websocket worker's own listener, so the
#            main worker now leaves the path alone.

use strict;
use warnings;

use FindBin;
use Test::More;
use File::Slurp qw(read_file);

my $src = read_file("$FindBin::Bin/../lib/JawnOS/Manager/Core2_worker_boot.pm");

like($src, qr/if \(\$ENV\{PURPOSE\} && \$ENV\{PURPOSE\} eq 'websocket'\) \{/,
	'only the websocket worker sets up the push sockets');
unlike($src,
	qr/\$ENV\{PURPOSE\} eq 'websocket' \|\| \(\$ENV\{PORT_ENV\} eq 'development' && \$ENV\{PURPOSE\} eq 'main'\)/,
	'a development main worker no longer binds them too');
like($src,
	qr/sub ws_server_ensure\(\$app\) \{\s*\n\s*# A main worker can reach this through the websocket route.*\n\s*return undef unless \$ENV\{PURPOSE\} && \$ENV\{PURPOSE\} eq 'websocket';/s,
	'ensuring the listener refuses to bind outside the websocket worker');

done_testing();
