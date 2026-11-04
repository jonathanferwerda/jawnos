#!/bin/sh
# JawnOS container entry point.
#
# First boot does what an appliance does: scripts/jawnos_setup.pl --seed writes
# config.json and builds the encrypted database from database/initial.enc, with
# no browser and no prompts. Every later start reuses the volumes and only
# reconciles the settings the container owns (ports, open_browser, folders).
# The tree's own master then runs in the foreground and handles SIGTERM.
set -eu
umask 077

APP=/app
HOME_DIR=${HOME:-/home/jawn}
CONFIG="$HOME_DIR/config.json"

cd "$APP"

# ./jawn reads ./config.json from the tree root. Keep the file in the home
# volume so an image rebuild does not lose the signatorial, and point the tree
# at it. An operator who bind-mounted a config file instead is left alone.
if [ -L "$APP/config.json" ] || [ ! -e "$APP/config.json" ]; then
	ln -sfn "$CONFIG" "$APP/config.json"
else
	CONFIG="$APP/config.json"
fi

mkdir -p "$HOME_DIR/.president" "$APP/database/backups" "$APP/voices" "$APP/releases" "$APP/server"

# A container keeps its home volume across restarts, so the pid of the previous
# incarnation survives. In a fresh PID namespace that number can belong to this
# very process, which the master's one-jawn guard would read as a live master.
rm -f "$HOME_DIR/.president/pid"

need_seed=0
[ -s "$CONFIG" ] || need_seed=1
[ -s "$APP/database/jawnos.db" ] || need_seed=1

if [ "$need_seed" = 1 ]; then
	echo "JawnOS: first boot - writing config.json and the encrypted database"
	set -- perl scripts/jawnos_setup.pl --seed \
		--name "${JAWNOS_NAME:-JawnOS}" \
		--device "${JAWNOS_DEVICE:-server}" \
		--language "${JAWNOS_LANGUAGE:-en}"
	if [ -n "${JAWNOS_EMAIL:-}" ]; then set -- "$@" --email "$JAWNOS_EMAIL"; fi
	if [ -n "${JAWNOS_DOMAIN:-}" ]; then set -- "$@" --domain "$JAWNOS_DOMAIN"; fi
	if [ -n "${JAWNOS_THEME:-}" ]; then set -- "$@" --theme "$JAWNOS_THEME"; fi
	if [ -n "${JAWNOS_UNLOCK_CODE:-}" ]; then set -- "$@" --code "$JAWNOS_UNLOCK_CODE"; fi

	# The log holds the generated code, so keep it in the container's writable
	# layer (not the home volume) and remove it once the run is read.
	seed_log=/tmp/jawnos-seed.log
	set +e
	"$@" > "$seed_log" 2>&1
	seed_status=$?
	set -e
	cat "$seed_log"
	if [ "$seed_status" -ne 0 ]; then
		echo "JawnOS: setup failed (see $seed_log); not starting the tree." >&2
		exit "$seed_status"
	fi

	code=$(sed -n 's/^JAWNOS_UNLOCK_CODE=//p' "$seed_log" | tail -n 1)
	if [ -z "$code" ]; then
		code=$(sed -n 's/^  unlock code   //p' "$seed_log" | tail -n 1)
	fi
	rm -f "$seed_log"
	if [ -n "$code" ]; then
		echo
		echo "******************************"
		echo "  unlock code: $code"
		echo "  Save it now. It is the only key"
		echo "  to the database and is not"
		echo "  recoverable from the files."
		echo "******************************"
		echo
		if [ "${JAWNOS_SAVE_UNLOCK_CODE:-0}" = 1 ]; then
			printf '%s\n' "$code" > "$HOME_DIR/unlock-code.txt"
			chmod 600 "$HOME_DIR/unlock-code.txt"
			echo "JawnOS: also written to $HOME_DIR/unlock-code.txt"
		fi
	fi
else
	echo "JawnOS: using the existing config and database in the volumes"
fi

# Container-owned settings. The seed has no flags for these, and a settings
# panel must not silently point the published ports somewhere else. Anything
# not named by the environment keeps whatever config.json already says.
perl -MJSON::PP -MFile::Slurp=read_file,write_file -e '
	my $file = shift;
	my $json = read_file($file);
	my $cfg = decode_json($json);
	my $changed = 0;

	if (($cfg->{"open_browser"} // "") ne "no") { $cfg->{"open_browser"} = "no"; $changed = 1 }

	if (($ENV{"JAWNOS_LOCKER_PORT"} // "") =~ /^\d+$/) {
		$cfg->{"port"} = $ENV{"JAWNOS_LOCKER_PORT"} + 0;
		$changed = 1;
	}
	if (($ENV{"JAWNOS_WORKING_PORT"} // "") =~ /^\d+$/) {
		$cfg->{"working_port"} = $ENV{"JAWNOS_WORKING_PORT"} + 0;
		$changed = 1;
	}
	my $ws = $ENV{"JAWNOS_WS_PORT"};
	if (defined $ws && $ws =~ /^\d+$/) {
		$cfg->{"ws_port"} = $ws + 0;
		$changed = 1;
	}
	else {
		# President listens for websockets on working_port + 1; keep the
		# stored value truthful so peers and help text do not advertise a
		# port nothing listens on.
		my $port = $cfg->{"working_port"};
		my $want = ($port =~ /^\d+$/ ? $port + 1 : 45546);
		if (($cfg->{"ws_port"} // "") ne $want) {
			$cfg->{"ws_port"} = $want;
			$changed = 1;
		}
	}

	if (($ENV{"JAWNOS_MAIN_WORKERS"} // "") =~ /^\d+$/) {
		$cfg->{"main_workers"} = $ENV{"JAWNOS_MAIN_WORKERS"} + 0;
		$changed = 1;
	}
	if (defined $ENV{"JAWNOS_FOLDERS"} && length $ENV{"JAWNOS_FOLDERS"}) {
		my @folders = grep { length } map { s/^\s+|\s+$//gr } split /:/, $ENV{"JAWNOS_FOLDERS"};
		if (@folders) { $cfg->{"folders"} = \@folders; $changed = 1 }
	}

	write_file($file, JSON::PP->new->canonical->pretty->utf8->encode($cfg)) if $changed;
' "$CONFIG"

working=$(perl -MJSON::PP -MFile::Slurp=read_file -e '
	my $json = read_file(shift);
	my $cfg = decode_json($json);
	print(($cfg->{"working_port"} // "") =~ /^\d+$/ ? $cfg->{"working_port"} : 45545);
' "$CONFIG")
locker=$(perl -MJSON::PP -MFile::Slurp=read_file -e '
	my $json = read_file(shift);
	my $cfg = decode_json($json);
	print(($cfg->{"port"} // "") =~ /^\d+$/ ? $cfg->{"port"} : 3000);
' "$CONFIG")
domain=$(perl -MJSON::PP -MFile::Slurp=read_file -e '
	my $json = read_file(shift);
	my $cfg = decode_json($json);
	my $d = $cfg->{"domain"} // "127.0.0.1";
	$d = "127.0.0.1" unless length $d;
	print $d;
' "$CONFIG")

echo "JawnOS: manager https://$domain:$working/   locker https://$domain:$locker/"
echo "JawnOS: the certificate is self-signed; the browser will warn once."

# ./jawn's shebang is /usr/bin/perl, but the official perl image installs its
# interpreter in /usr/local/bin. Name the interpreter so the master (and the
# $^X it hands President.pl) is the Perl the modules were installed for.
exec perl ./jawn
