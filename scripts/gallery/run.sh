#!/bin/sh
# One command for the jawnos.ca screenshot gallery.
#
#   scripts/gallery/run.sh                 capture the live guest + publish the site
#   scripts/gallery/run.sh --all           reseed the guest first, then do both
#   scripts/gallery/run.sh --sync          fast-forward the guest tree to origin/main
#   scripts/gallery/run.sh --seed          only rebuild the guest's demo database
#   scripts/gallery/run.sh --shoot --only 14-clock
#   scripts/gallery/run.sh --all --deploy  and upload to Cloudflare Pages
#   scripts/gallery/run.sh --all --deploy-50webs   or to the 50webs host
#
# The shoot phase mints a citizen app ticket (`scripts/app_ticket.pl gallery`)
# and places its session cookie in the capture browser. The guest's own
# loopback alone is a resident session, which leaves the citizen-only apps
# (People) empty.
#
# SAFETY: every write goes to the QEMU guest on the table, reached as the
# table's SSH client -> 127.0.0.1:2222 -> guest. The table host's own
# ~/jawnos/database/jawnos.db is never opened or written. The seed step refuses
# unless the guest carries /etc/jawnos-demo-image.
#
# The capture uses the live image's loopback exemption: the guest's own sshd
# opens the last hop to 127.0.0.1:45545, so the manager sees "someone at the
# machine" and needs no ticket or gate. The table's existing tunnel on 14646
# may be left alone; this script uses its own ports and cleans them up.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TABLE=${TABLE:-jawn@table.jonathanferwerda.com}
TABLE_SSH=${TABLE_SSH:-8022}
GUEST_SSH=${GUEST_SSH:-2222}
LOCAL_PORT=${LOCAL_PORT:-14650}
TABLE_PORT=${TABLE_PORT:-14651}
CDP_PORT=${CDP_PORT:-9225}
PROFILE=${PROFILE:-/tmp/jawnos-gallery-chrome}
SHOTS=${SHOTS:-$ROOT/.shots/scenes-live}
SITE=${SITE:-$ROOT/../jawnos-website}
DEMO_SEED=${DEMO_SEED:-$ROOT/.shots/seed.db}
DEMO_DB=${DEMO_OUT:-$ROOT/.shots/demo.db}

DO_SEED=0
DO_SHOOT=0
DO_PUBLISH=0
DO_SYNC=0
DEPLOY=${DEPLOY:-}
NO_TUNNEL=0
DRY=0
ONLY=${ONLY:-}

for arg in "$@"; do
  case "$arg" in
    --all) DO_SEED=1; DO_SHOOT=1; DO_PUBLISH=1 ;;
    --seed) DO_SEED=1 ;;
    --shoot) DO_SHOOT=1 ;;
    --publish) DO_PUBLISH=1 ;;
    --sync) DO_SYNC=1 ;;
    --deploy) DO_PUBLISH=1; DEPLOY=pages ;;
    --deploy-50webs) DO_PUBLISH=1; DEPLOY=50webs ;;
    --deploy-both) DO_PUBLISH=1; DEPLOY=both ;;
    --no-tunnel) NO_TUNNEL=1 ;;
    --dry-run) DRY=1 ;;
    --only=*) ONLY=${arg#--only=} ;;
    --only) PREV=--only ;;
    --help|-h)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      # --only 14-clock (two words)
      if [ "${PREV:-}" = "--only" ]; then ONLY=$arg; PREV=; continue; fi
      echo "run.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
  [ "$arg" = "--only" ] || PREV=$arg
done

if [ "$DO_SEED" = 0 ] && [ "$DO_SHOOT" = 0 ] && [ "$DO_PUBLISH" = 0 ] && [ "$DO_SYNC" = 0 ]; then
  DO_SHOOT=1
  DO_PUBLISH=1
fi

say() { printf '%s\n' "$*"; }
phase() { echo; echo "== $* =="; }
now() { date +%s; }
elapsed() { echo "$(( $(now) - $1 ))s"; }

guest() {
  ssh -p "$TABLE_SSH" -o BatchMode=yes "$TABLE" \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p $GUEST_SSH jawn@127.0.0.1 sh -s"
}

CHROME_PID=
FWD_PID=
OUTER_PID=
TUNNEL_STARTED=0

cleanup() {
  [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null || true
  [ -n "$FWD_PID" ] && kill "$FWD_PID" 2>/dev/null || true
  [ -n "$OUTER_PID" ] && kill "$OUTER_PID" 2>/dev/null || true
  if [ -n "$TABLE_PORT" ] && [ "$TUNNEL_STARTED" = 1 ]; then
    ssh -p "$TABLE_SSH" -o BatchMode=yes "$TABLE" \
      "pkill -f 'ssh -N .* -L $TABLE_PORT:127.0.0.1:45545' 2>/dev/null" >/dev/null 2>&1 || true
  fi
  rm -f /tmp/jawnos-gallery-status
}
trap cleanup EXIT INT TERM

if [ "$DRY" = 1 ]; then
  say "sync:    $DO_SYNC"
  say "seed:    $DO_SEED ($DEMO_SEED -> $DEMO_DB)"
  say "shoot:   $DO_SHOOT ($SHOTS)"
  say "publish: $DO_PUBLISH ($SITE), deploy: ${DEPLOY:-no}"
  say "only:    ${ONLY:-all}"
  exit 0
fi

T0=$(now)

# ---------------------------------------------------------------- sync ------
if [ "$DO_SYNC" = 1 ]; then
  phase "update the guest tree"
  guest <<'REMOTE'
set -eu
cd /home/jawn/jawnos
git fetch --quiet --prune origin main
git reset --hard --quiet origin/main
echo "guest tree: $(cat VERSION) ($(git rev-parse --short HEAD))"
REMOTE
  guest <<'REMOTE'
set -eu
cd /home/jawn
python3 jawnos/desktop/jawnosctl stop >/dev/null 2>&1 || true
i=0
while [ $i -lt 20 ]; do
  pgrep -f 'President.pl' >/dev/null 2>&1 || break
  i=$((i+1)); sleep 1
done
python3 jawnos/desktop/jawnosctl start >/dev/null 2>&1 || true
i=0
while [ $i -lt 60 ]; do
  if curl -sk -o /dev/null https://127.0.0.1:45545/manager; then break; fi
  i=$((i+1)); sleep 1
done
if [ $i -ge 60 ]; then echo "guest did not come back after the sync" >&2; exit 1; fi
echo "guest restarted"
REMOTE
  say "sync: $(elapsed "$T0")"
fi

# ---------------------------------------------------------------- seed ------
if [ "$DO_SEED" = 1 ]; then
  phase "seed the guest"
  [ -f "$DEMO_SEED" ] || { echo "run.sh: no seed database at $DEMO_SEED (see scripts/gallery/README.md)" >&2; exit 1; }
  python3 "$ROOT/scripts/gallery/seed/demo_seed.py" --seed "$DEMO_SEED" --out "$DEMO_DB"

  scp -q -P "$TABLE_SSH" -o BatchMode=yes "$DEMO_DB" "$TABLE:/tmp/jawnos-demo.db"
  scp -q -P "$TABLE_SSH" -o BatchMode=yes \
    "$ROOT/scripts/gallery/seed/demo_extra_seed.py" \
    "$ROOT/scripts/gallery/seed/gallery_seed.py" \
    "$TABLE:/tmp/"
  ssh -p "$TABLE_SSH" -o BatchMode=yes "$TABLE" \
    "scp -q -P $GUEST_SSH -o BatchMode=yes /tmp/jawnos-demo.db /tmp/demo_extra_seed.py /tmp/gallery_seed.py jawn@127.0.0.1:/home/jawn/"

  guest <<'REMOTE'
set -eu
cd /home/jawn
test -e /etc/jawnos-demo-image || { echo "refusing to seed: not the demo image (no /etc/jawnos-demo-image)" >&2; exit 1; }
for d in Portraits "Plein Air" Studio T-Deck T-Watch Maps Backgrounds; do
  test -d "Pictures/$d" || { echo "missing ~/Pictures/$d; stage the demo media first (scripts/gallery/seed/media.sh)" >&2; exit 1; }
done
mkdir -p jawnos/database/backups
python3 jawnos/desktop/jawnosctl stop >/dev/null 2>&1 || true
i=0
while [ $i -lt 15 ]; do
  if ! pgrep -f 'President.pl' >/dev/null 2>&1; then break; fi
  i=$((i+1)); sleep 1
done
if pgrep -f 'President.pl' >/dev/null 2>&1; then
  echo "the tree did not stop; refusing to replace the database" >&2
  exit 1
fi
cp -f jawnos/database/jawnos.db jawnos/database/backups/jawnos.db.pre-demo
cp -f demo.db jawnos/database/jawnos.db
rm -f jawnos/database/jawnos.db-wal jawnos/database/jawnos.db-shm
python3 jawnos/desktop/jawnosctl start >/dev/null 2>&1 || true
i=0
while [ $i -lt 30 ]; do
  if curl -sk -o /dev/null https://127.0.0.1:45545/manager; then break; fi
  i=$((i+1)); sleep 1
done
if [ $i -ge 30 ]; then echo "guest did not come back after the seed" >&2; exit 1; fi
python3 demo_extra_seed.py jawnos/database/jawnos.db
python3 gallery_seed.py jawnos/database/jawnos.db
echo "guest appointments: $(sqlite3 jawnos/database/jawnos.db 'select count(*) from appointments')"
echo "guest albums:       $(sqlite3 jawnos/database/jawnos.db \"select app from appointments where app in ('t-watch','t-deck','studio','plein_air','portraits') group by app\" | wc -l)"
REMOTE
  say "seed: $(elapsed "$T0")"
fi

# ---------------------------------------------------------------- shoot -----
if [ "$DO_SHOOT" = 1 ]; then
  phase "capture the live guest"
  command -v node >/dev/null || { echo "run.sh: node is required" >&2; exit 1; }
  command -v chromium >/dev/null || { echo "run.sh: chromium is required" >&2; exit 1; }
  command -v magick >/dev/null || { echo "run.sh: ImageMagick (magick) is required" >&2; exit 1; }

  if [ "$NO_TUNNEL" = 0 ]; then
    TUNNEL_STARTED=1
    # The guest's sshd makes the final hop on its own loopback. The table is
    # only a relay; no listener is exposed beyond 127.0.0.1 on either side.
    ssh -T -o BatchMode=yes -p "$TABLE_SSH" "$TABLE" \
      "ssh -N -o BatchMode=yes -o StrictHostKeyChecking=no -p $GUEST_SSH jawn@127.0.0.1 -L $TABLE_PORT:127.0.0.1:45545" &
    OUTER_PID=$!
    ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -p "$TABLE_SSH" "$TABLE" \
      -L "$LOCAL_PORT:127.0.0.1:$TABLE_PORT" &
    FWD_PID=$!
    i=0
    while [ $i -lt 30 ]; do
      if curl -sk "https://127.0.0.1:$LOCAL_PORT/manager" 2>/dev/null | grep -q 'taskbar'; then break; fi
      i=$((i+1)); sleep 1
    done
    if [ $i -ge 30 ]; then
      echo "run.sh: the guest manager did not answer through the tunnel." >&2
      echo "        check: ssh -p $TABLE_SSH $TABLE 'pgrep -af qemu'" >&2
      exit 1
    fi
  fi

  # The guest's own loopback is a resident session; a citizen ticket is what
  # makes the citizen-only apps render. Mint/reuse it and hand its cookie to
  # the capture browser (it never navigates the ticket's own redirect).
  TICKET_COOKIE_NAME=${TICKET_COOKIE_NAME:-}
  TICKET_COOKIE=${TICKET_COOKIE:-}
  if [ "$NO_TUNNEL" = 0 ]; then
    phase "mint a citizen ticket"
    TICKET_URL=$(ssh -p "$TABLE_SSH" -o BatchMode=yes "$TABLE" \
      "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p $GUEST_SSH jawn@127.0.0.1 'cd /home/jawn/jawnos && perl scripts/app_ticket.pl gallery'" 2>/dev/null | tail -1)
    if [ -n "$TICKET_URL" ]; then
      TICKET_URL=$(printf '%s\n' "$TICKET_URL" | sed "s#^https://[^/]*#https://127.0.0.1:$LOCAL_PORT#")
      TICKET_JAR=$(mktemp)
      if curl -sk -c "$TICKET_JAR" -o /dev/null "$TICKET_URL"; then
        # skip libcurl's comment header; keep an HttpOnly row's #HttpOnly_ domain
        TICKET_COOKIE_NAME=$(awk '($1 !~ /^#/ || $1 ~ /^#HttpOnly_/) && NF >= 7 { print $6; exit }' "$TICKET_JAR")
        TICKET_COOKIE=$(awk '($1 !~ /^#/ || $1 ~ /^#HttpOnly_/) && NF >= 7 { print $7; exit }' "$TICKET_JAR")
      fi
      rm -f "$TICKET_JAR"
    fi
    if [ -z "$TICKET_COOKIE" ]; then
      say "warning: no citizen ticket; citizen-only apps (People) will be empty"
    else
      say "ticket: citizen session ready"
    fi
  fi

  URL=${JAWNOS_URL:-https://127.0.0.1:$LOCAL_PORT/manager}
  rm -rf "$PROFILE"
  chromium --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --ignore-certificate-errors --allow-insecure-localhost --hide-scrollbars \
    --no-first-run --no-default-browser-check \
    --remote-debugging-port="$CDP_PORT" --user-data-dir="$PROFILE" \
    --window-size=1920,1080 about:blank >/tmp/jawnos-gallery-chrome.log 2>&1 &
  CHROME_PID=$!
  i=0
  while [ $i -lt 20 ]; do
    if curl -s "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then break; fi
    i=$((i+1)); sleep 1
  done
  if [ $i -ge 20 ]; then echo "run.sh: chromium did not open its debug port" >&2; exit 1; fi

  rm -rf "$SHOTS"
  mkdir -p "$SHOTS"
  CDP_PORT="$CDP_PORT" JAWNOS_URL="$URL" OUT="$SHOTS" ONLY="$ONLY" \
    TICKET_COOKIE_NAME="$TICKET_COOKIE_NAME" TICKET_COOKIE="$TICKET_COOKIE" \
    node "$ROOT/scripts/gallery/capture.mjs"
  say "shoot: $(elapsed "$T0")"
fi

# ---------------------------------------------------------------- publish ---
if [ "$DO_PUBLISH" = 1 ]; then
  phase "publish the site"
  DEPLOY_ARG=
  [ -n "$DEPLOY" ] && DEPLOY_ARG="--deploy $DEPLOY"
  python3 "$ROOT/scripts/gallery/publish.py" \
    --shots "$SHOTS" --site "$SITE" --manifest "$ROOT/scripts/gallery/scenes.json" $DEPLOY_ARG
  say "publish: $(elapsed "$T0")"
fi

say "total: $(elapsed "$T0")"
