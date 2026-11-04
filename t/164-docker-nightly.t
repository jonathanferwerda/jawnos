# tests-for: qa/docker/smoke.sh qa/systemd/jawnos-qa-docker.service qa/systemd/jawnos-qa-docker.timer compose.yaml .env.example
# covers:    the nightly Docker smoke is testing-only and cannot reach the live
#           house: it builds the committed tree, runs on loopback-only free
#           ports under its own project and image tag, checks the real image,
#           and removes its volumes. The unit lives where Docker is (like the
#           weekly build unit), not on the Configure -> Plat -> QA machine.

use strict;
use warnings;

use FindBin;
use File::Slurp qw(read_file);
use Test::More;

my $root = "$FindBin::Bin/..";
my $script  = read_file("$root/qa/docker/smoke.sh");
my $service = read_file("$root/qa/systemd/jawnos-qa-docker.service");
my $timer   = read_file("$root/qa/systemd/jawnos-qa-docker.timer");
my $compose = read_file("$root/compose.yaml");
my $env     = read_file("$root/.env.example");
my $readme  = read_file("$root/qa/README.md");

ok( -x "$root/qa/docker/smoke.sh", 'the nightly smoke is executable' );
is( system( 'bash', '-n', "$root/qa/docker/smoke.sh" ), 0, 'the smoke parses under bash' );

like( $script, qr/git -C "\$REPO" archive --format=tar HEAD/,
	'it builds the committed tree, not the worktree' );
like( $script, qr/^PROJECT=jawnos-nightly$/m, 'it has its own Compose project' );
like( $script, qr/^IMAGE=jawnos:nightly$/m,   'it has its own image tag' );
like( $script, qr/^BIND=127\.0\.0\.1$/m,      'the bind is loopback' );
like( $script, qr/JAWNOS_BIND_ADDR="\$BIND"/, 'published ports are bound to loopback' );
like( $script, qr/JAWNOS_IMAGE="\$IMAGE"/,    'the nightly image tag reaches Compose' );
like( $script, qr/down -v --remove-orphans/,  'it removes its volumes' );
like( $script, qr/^trap cleanup EXIT$/m,      'it cleans up on every exit' );
like( $script, qr/^\s*STARTED_DOCKER=1$/m,       'it remembers whether it started Docker' );
like( $script, qr/systemctl stop docker docker\.socket/, 'it stops Docker only when it started it' );
like( $script, qr/ip link del docker0/,       'it removes the bridge it created' );
like( $script, qr/usethreads/,                'it checks the threaded Perl' );
like( $script, qr/Mojolicious::VERSION/,      'it checks the pinned Mojolicious' );
like( $script, qr/ifconfig/,                  'it checks ifconfig' );
like( $script, qr/restart\.pl --status/,      'it checks the app control socket' );
like( $script, qr/restart\.pl --reason/,      'it checks the app restart path' );
like( $script, qr/SKIP: docker is not installed/, 'a missing Docker is a skip, not a pass' );

like( $service, qr{ExecStart=/bin/bash /home/jawn/jawnos/qa/docker/smoke\.sh},
	'the service runs the smoke' );
like( $service, qr/^User=jawn$/m, 'it runs as the tree owner' );
unlike( $service, qr/^ExecCondition=.*device_target/m,
	'it is not gated to the QA machine: it belongs where Docker is' );
unlike( $service, qr/^NoNewPrivileges=yes$/m, 'sudo can start and stop Docker' );
like( $service, qr/^MemoryMax=6G$/m, 'the build has a memory budget' );

like( $timer, qr/OnCalendar=\*-\*-\* 04:30:00/, 'the timer is nightly at 04:30' );
like( $timer, qr/Unit=jawnos-qa-docker\.service/, 'the timer drives the Docker service' );
like( $timer, qr/^Persistent=true$/m, 'a missed run is caught up' );

like( $compose, qr/\$\{JAWNOS_BIND_ADDR:-0\.0\.0\.0\}/, 'Compose can bind to loopback' );
like( $compose, qr/\$\{JAWNOS_IMAGE:-jawnos:local\}/,  'Compose can tag the nightly image' );
like( $env, qr/^# JAWNOS_BIND_ADDR=0\.0\.0\.0$/m, 'the env sample documents the bind' );
like( $env, qr/^# JAWNOS_IMAGE=jawnos:local$/m,   'the env sample documents the image tag' );
like( $readme, qr/Docker compose smoke \(04:30\)/,       'the QA map names the nightly smoke' );
like( $readme, qr/There are four nightly units/,   'the QA map counts the Docker unit' );

done_testing();
