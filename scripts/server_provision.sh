#!/usr/bin/env bash
# Provision the JawnOS mail server: the scan stack that email_receiver calls.
#
# Run it on the host whose purpose is `server` (the machine that will pull mail),
# as root:
#
#   scp -P 8022 scripts/server_provision.sh agent@thejunderground.com:/tmp/
#   ssh -p 8022 agent@thejunderground.com 'echo <root-pw> | sudo -S -p "" bash /tmp/server_provision.sh'
#
# It installs and enables:
#   clamav / clamav-daemon / clamav-freshclam  - virus & malware scanning (clamd)
#   rspamd                                     - spam / phishing scoring
#   rkhunter                                   - host rootkit check (run nightly)
#
# Idempotent: safe to re-run. Nothing here reads or changes mail that exists.

set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

if command -v apt-get >/dev/null; then
	export DEBIAN_FRONTEND=noninteractive
	PKG=apt
	apt-get update -y
elif command -v dnf >/dev/null; then
	PKG=dnf
	dnf install -y epel-release || true
else
	echo "no supported package manager"; exit 1
fi

install_pkgs() {
	if [ "$PKG" = apt ]; then apt-get install -y "$@"; else dnf install -y "$@"; fi
}

echo "== clamav core =="
install_pkgs clamav clamav-daemon clamav-freshclam || install_pkgs clamav clamd clamav-update

# The signature updater and the resident scanner carry different unit names on
# Debian (clamav-*) and RHEL (freshclam/clamd).
FRESH=clamav-freshclam; CLAMD=clamav-daemon
systemctl list-unit-files 2>/dev/null | grep -q '^freshclam\.service' && FRESH=freshclam
systemctl list-unit-files 2>/dev/null | grep -q '^clamd\.service'     && CLAMD=clamd

systemctl enable --now "$FRESH" 2>/dev/null || true
# freshclam may already hold the log lock as a running service; only fetch here
# if it is not, so a re-run does not error on the lock.
if ! systemctl is-active --quiet "$FRESH"; then
	echo "fetching signatures..."
	freshclam 2>&1 | tail -2 || true
else
	echo "signatures: the freshclam service is running"
fi
systemctl enable --now "$CLAMD" 2>/dev/null || true
sleep 3

echo "== spam/phishing and rootkit =="
install_pkgs rspamd   || echo "rspamd not installed (continuing)"
install_pkgs rkhunter || echo "rkhunter not installed (continuing)"
systemctl enable --now rspamd 2>/dev/null || true
# a baseline so a later --cronjob run can report what changed
if command -v rkhunter >/dev/null; then
	rkhunter --update >/dev/null 2>&1 || true
	rkhunter --propupd >/dev/null 2>&1 || true
fi

echo "== status =="
clamdscan --version 2>/dev/null || clamscan --version 2>/dev/null || true
for s in "$CLAMD" "$FRESH" rspamd; do printf "%s=" "$s"; systemctl is-active "$s" 2>/dev/null || true; done
rkhunter --version 2>/dev/null | head -1 || true
free -m | awk 'NR==2 {print "ram used/avail MB:", $3"/"$6}'

echo "== live scan test (EICAR should read FOUND) =="
printf '%s\n' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /tmp/eicar.com
if systemctl is-active --quiet "$CLAMD"; then clamdscan --no-summary /tmp/eicar.com || true; else clamscan --no-summary /tmp/eicar.com || true; fi
rm -f /tmp/eicar.com

cat <<'NOTE'

Next, once JawnOS is wired to it:
  * the receiver runs only on this machine (its purpose is `server`)
  * each message's attachments are scanned with clamdscan before they are sealed
  * rkhunter belongs on a nightly timer, reporting into Dev/Sys:
      printf '#!/bin/sh\nrkhunter --cronjob --report-warnings-only\n' > /etc/cron.daily/rkhunter.local
      chmod +x /etc/cron.daily/rkhunter.local
NOTE
echo "== done =="
