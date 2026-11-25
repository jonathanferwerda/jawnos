# tests-for: lib/JawnOS/Controller/manager_misc9.pm perl/hooks.pl
# covers:    A relayed Studio request has no session on the target, so the
#            login gate must let the five relayed routes reach their own
#            check. That check proves a pinned peer signature (the app gate's
#            verdict when it ran, otherwise app_peer_ok), never a bare
#            `remoted=yes`, which a browser can type. remote_publish refuses a
#            relayed request and remote_target is local-only, so neither is
#            exempt.

use strict;
use warnings;

use FindBin;
use Test::More;
use File::Slurp qw(read_file);

my $root       = "$FindBin::Bin/..";
my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my $hooks      = read_file("$root/perl/hooks.pl");

# --- the five relayed routes reach their own check --------------------------
for my $path (qw(
	/manager/studio/remote_state
	/manager/studio/remote_command
	/manager/studio/remote_devices
	/manager/studio/remote_device
	/manager/studio/monitor_stream
)) {
	like($hooks, qr/\$path eq '\Q$path\E'/,
		"hooks.pl lets the login gate step aside for $path");
}

# --- and each action proves the caller --------------------------------------
like($controller, qr/sub studio_remote_peer_ok\(\$c\)/,
	'one helper answers whether the caller is a linked machine');
like($controller, qr/return 1 if \$c->stash\('peer_verified_key'\);/,
	'it keeps the app gate verdict when the gate ran');
like($controller, qr/return &Manager::app_peer_ok\(\$c\) \? 1 : 0;/,
	'and otherwise verifies the pinned key itself');

for my $action (qw(action_44040 action_44041 action_44042 action_44043 action_44044)) {
	my ($body) = $controller =~ /(sub \Q$action\E \{.*?\n\})/s;
	like($body // '', qr/if \(\$remoted && !&studio_remote_peer_ok\(\$c\)\)/,
		"$action refuses a relayed request with no verified peer");
	like($body // '', qr/status => 403/,
		"$action answers 403, not the target's state");
}

# --- publish and the local picker are not exempt ----------------------------
unlike($hooks, qr{\$path eq '/manager/studio/remote_publish'},
	'a relayed publish is never exempt (the route refuses it anyway)');
unlike($hooks, qr{\$path eq '/manager/studio/remote_machines'},
	'the local machine picker is not on the peer rail');
unlike($hooks, qr{\$path eq '/manager/studio/remote_target'},
	'nor is choosing a target');

done_testing();
