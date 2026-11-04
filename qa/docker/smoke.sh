#!/usr/bin/env bash
# Nightly Docker compose smoke. TESTING ONLY: this never deploys the app and
# never touches the live tree, database, ports or the user's Docker project.
#
# It builds the image from the committed tree (git archive HEAD, so uncommitted
# work is not tested), runs it under its own Compose project on free
# loopback-only ports with a factory-seeded database, and checks:
#   first boot + unlock code + database
#   the manager/locker/websocket ports answer
#   the threaded Perl, Mojolicious 9.39 and ifconfig are in the image
#   a clean Compose restart reuses the volumes
#   the app's own scripts/restart.pl accepts a restart
# Then it removes its volumes and the extracted tree. Docker is started for the
# run only when it was inactive, and stopped again afterwards.
#
# A checkout without Docker is a SKIP. Docker installed but unusable (no compose
# plugin, daemon will not start) is a FAIL. Runs are logged under
# $QA_ROOT/docker/<stamp>/smoke.log; the last 14 are kept.
#
# Driven by qa/systemd/jawnos-qa-docker.timer (04:30, nightly) on the machine
# that carries Docker, not by the hardened 05:00 suite.

set -euo pipefail

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
QA_ROOT=${QA_ROOT:-$HOME/jawnos-qa}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$QA_ROOT/docker/$STAMP"
TREE="$RUN_DIR/tree"
LOG="$RUN_DIR/smoke.log"
PROJECT=jawnos-nightly
IMAGE=jawnos:nightly
UNLOCK=424242
BIND=127.0.0.1

DOCKER_SUDO=0
STARTED_DOCKER=0
TREE_MADE=0
ENVS=()

cleanup() {
	local rc=$?
	trap - EXIT
	set +e
	if [ "$TREE_MADE" = 1 ]; then
		( cd "$TREE" && docker_cmd compose -p "$PROJECT" down -v --remove-orphans ) >/dev/null 2>&1
		rm -rf "$TREE"
	fi
	if [ "$STARTED_DOCKER" = 1 ]; then
		sudo -n systemctl stop docker docker.socket >/dev/null 2>&1
		sudo -n ip link del docker0 >/dev/null 2>&1
	fi
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker_cmd() {
	if [ "$DOCKER_SUDO" = 1 ]; then
		sudo -n env "${ENVS[@]}" docker "$@"
	else
		env "${ENVS[@]}" docker "$@"
	fi
}

compose() {
	( cd "$TREE" && docker_cmd compose -p "$PROJECT" "$@" )
}

wait_http() {
	local deadline=$((SECONDS + 180)) code
	while [ "$SECONDS" -lt "$deadline" ]; do
		code=$(curl -ksS -o /dev/null -w '%{http_code}' "https://127.0.0.1:$WORKING/" 2>/dev/null || true)
		case "$code" in
			200|30*) return 0 ;;
		esac
		sleep 2
	done
	echo "FAIL: the manager did not answer on 127.0.0.1:$WORKING (last code ${code:-none})" >&2
	return 1
}

find_ports() {
	perl -MIO::Socket::INET -e '
		sub free {
			my $port = shift;
			my $sock = IO::Socket::INET->new(
				LocalAddr => "0.0.0.0", LocalPort => $port,
				Proto => "tcp", Listen => 1, ReuseAddr => 1,
			) or return 0;
			close $sock;
			return 1;
		}
		for my $base (20000 .. 40000) {
			next unless free($base) && free($base + 1);
			my $locker = $base + 1000;
			$locker++ while $locker < 60000 && !free($locker);
			next if $locker >= 60000;
			print "$locker $base " . ($base + 1) . "\n";
			last;
		}
	'
}

main() {
	echo "docker-smoke: $STAMP project=$PROJECT image=$IMAGE"

	if ! command -v git >/dev/null 2>&1; then
		echo "FAIL: git is required to build the committed tree"
		return 1
	fi
	if ! command -v curl >/dev/null 2>&1; then
		echo "FAIL: curl is required to check the published ports"
		return 1
	fi

	# Docker access: direct when this user can reach the socket, otherwise
	# passwordless sudo. The weekly build unit already requires that.
	if docker info >/dev/null 2>&1; then
		DOCKER_SUDO=0
	elif sudo -n docker info >/dev/null 2>&1; then
		DOCKER_SUDO=1
	elif ! command -v docker >/dev/null 2>&1; then
		echo "SKIP: docker is not installed"
		return 0
	elif ! sudo -n true >/dev/null 2>&1; then
		echo "SKIP: docker is not reachable and sudo -n is not available"
		return 0
	else
		echo "docker-smoke: starting the docker service for this run"
		sudo -n systemctl start docker
		STARTED_DOCKER=1
		for _ in $(seq 1 30); do
			sudo -n docker info >/dev/null 2>&1 && break
			sleep 1
		done
		if ! sudo -n docker info >/dev/null 2>&1; then
			echo "FAIL: the docker daemon did not start"
			return 1
		fi
		DOCKER_SUDO=1
	fi

	if ! docker_cmd compose version >/dev/null 2>&1; then
		echo "FAIL: the docker compose plugin is not available"
		return 1
	fi

	PORTS=$(find_ports)
	if [ -z "$PORTS" ]; then
		echo "FAIL: no free loopback port pair was found"
		return 1
	fi
	read -r LOCKER WORKING WS <<<"$PORTS"
	echo "docker-smoke: ports locker=$LOCKER manager=$WORKING ws=$WS (loopback only)"

	ENVS=(
		JAWNOS_BIND_ADDR="$BIND"
		JAWNOS_IMAGE="$IMAGE"
		JAWNOS_LOCKER_PORT="$LOCKER"
		JAWNOS_WORKING_PORT="$WORKING"
		JAWNOS_WS_PORT="$WS"
		JAWNOS_NAME=DockerNightly
		JAWNOS_DOMAIN=127.0.0.1
		JAWNOS_DEVICE=server
		JAWNOS_LANGUAGE=en
		JAWNOS_UNLOCK_CODE="$UNLOCK"
		JAWNOS_SAVE_UNLOCK_CODE=1
		TZ=UTC
	)

	mkdir -p "$TREE"
	git -C "$REPO" archive --format=tar HEAD | tar -x -C "$TREE"
	TREE_MADE=1

	echo "docker-smoke: building $IMAGE from HEAD"
	compose build
	echo "docker-smoke: starting $PROJECT"
	compose up -d
	wait_http

	usethreads=$(compose exec -T jawnos perl -V:usethreads | tr -d '\r\n')
	case "$usethreads" in
		*define*) ;;
		*) echo "FAIL: the container Perl is not threaded ($usethreads)"; return 1 ;;
	esac
	moo=$(compose exec -T jawnos perl -MMojolicious -e 'print $Mojolicious::VERSION' | tr -d '\r\n')
	if [ "$moo" != 9.39 ]; then
		echo "FAIL: Mojolicious is $moo, not the pinned 9.39"
		return 1
	fi
	if ! compose exec -T jawnos sh -c 'command -v ifconfig >/dev/null'; then
		echo "FAIL: ifconfig is missing from the image"
		return 1
	fi
	code=$(compose exec -T jawnos cat /home/jawn/unlock-code.txt | tr -d '\r\n')
	if [ "$code" != "$UNLOCK" ]; then
		echo "FAIL: the unlock code is '$code', not $UNLOCK"
		return 1
	fi
	if ! compose exec -T jawnos test -s /app/database/jawnos.db; then
		echo "FAIL: the seeded database is missing"
		return 1
	fi
	status=$(compose exec -T jawnos perl scripts/restart.pl --status 2>&1)
	case "$status" in
		*"status started"*) ;;
		*) echo "FAIL: the app control socket did not answer: $status"; return 1 ;;
	esac

	echo "docker-smoke: restarting the container"
	compose restart
	wait_http
	if ! compose logs --no-color 2>/dev/null | grep -q 'using the existing config and database'; then
		echo "FAIL: the restart did not reuse the volumes"
		return 1
	fi

	echo "docker-smoke: asking the app to restart its tree"
	restart=$(compose exec -T jawnos perl scripts/restart.pl --reason "nightly docker smoke" 2>&1)
	case "$restart" in
		*"restart accepted"*) ;;
		*) echo "FAIL: scripts/restart.pl: $restart"; return 1 ;;
	esac
	wait_http

	echo "PASS: docker compose smoke ($PROJECT, ports $LOCKER/$WORKING/$WS)"
	return 0
}

mkdir -p "$QA_ROOT/docker" "$RUN_DIR"
find "$QA_ROOT/docker" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} + 2>/dev/null || true

if command -v flock >/dev/null 2>&1; then
	exec 9>"$QA_ROOT/docker/.lock"
	if ! flock -n 9; then
		echo "docker-smoke: another run holds $QA_ROOT/docker/.lock; skipping"
		exit 0
	fi
fi

set +e
main 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "docker-smoke: log $LOG"
exit "$rc"
