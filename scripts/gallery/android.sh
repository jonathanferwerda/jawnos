#!/bin/sh
# Android screenshot pipeline for jawnos.ca.
#
#   scripts/gallery/android.sh --seed             build the phone database + media
#   scripts/gallery/android.sh --seed --push      ...and push it to the emulator
#   scripts/gallery/android.sh --shoot            capture the #phone scenes
#   scripts/gallery/android.sh --publish          write WebP + rewrite the site
#   scripts/gallery/android.sh --all --push --deploy both
#   scripts/gallery/android.sh --shoot --only gallery
#
# The capture host is the table's x86_64 AVD (`table`, SSH 8022). It assumes the
# JawnOS APK is installed and its first run has finished (dependencies are in
# the app's tree). See scripts/gallery/README.md for the emulator setup.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TABLE=${TABLE:-jawn@table}
TABLE_SSH=${TABLE_SSH:-8022}
ADB=/home/jawn/android-sdk/platform-tools/adb
OUT=${OUT:-$ROOT/.shots/android-scenes}
SITE=${SITE:-$ROOT/../jawnos-website}
DEVICE_HOME=/data/data/com.termux/files/home
# The capture host's app package. Relative components below (".app.X") follow
# this, so one value covers a device on the JawnOS app (com.jawnos) and the old
# fork (com.termux).
APP_PACKAGE=${APP_PACKAGE:-com.termux}

DO_SEED=0
DO_PUSH=0
DO_SHOOT=0
DO_PUBLISH=0
DEPLOY=
ONLY=

for arg in "$@"; do
  case "$arg" in
    --seed) DO_SEED=1 ;;
    --push) DO_PUSH=1 ;;
    --shoot) DO_SHOOT=1 ;;
    --publish) DO_PUBLISH=1 ;;
    --all) DO_SEED=1; DO_PUSH=1; DO_SHOOT=1; DO_PUBLISH=1 ;;
    --deploy) DEPLOY=both ;;
    --deploy=*) DEPLOY=${arg#--deploy=} ;;
    --only=*) ONLY=${arg#--only=} ;;
    --only) PREV=--only ;;
    --help|-h) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      if [ "${PREV:-}" = "--only" ]; then ONLY=$arg; PREV=; continue; fi
      echo "android.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
  [ "$arg" = "--only" ] || PREV=$arg
done

[ "$DO_SEED$DO_SHOOT$DO_PUBLISH" = "000" ] && { DO_SHOOT=1; DO_PUBLISH=1; }

adb() {
  # -n: the list of scenes is on this shell's stdin; an ssh that reads it
  # swallows the rest of the loop.
  ssh -n -o BatchMode=yes -p "$TABLE_SSH" "$TABLE" \
    "export PATH=\$HOME/android-sdk/platform-tools:\$PATH; $ADB $*"
}

emu() {
  ssh -o BatchMode=yes -p "$TABLE_SSH" "$TABLE" \
    "export PATH=\$HOME/android-sdk/platform-tools:\$PATH; $ADB shell 'run-as com.termux sh -s'"
}

say() { printf '%s\n' "$*"; }

# ------------------------------------------------------------------ seed ----
if [ "$DO_SEED" = 1 ]; then
  say "== seed the phone database"
  if [ ! -d "$ROOT/.shots/demo_media/Pictures/Studio" ]; then
    say "  media missing; generating it"
    sh "$ROOT/scripts/gallery/seed/media.sh" --stage-only
  fi
  python3 "$ROOT/scripts/gallery/seed/phone_seed.py" \
    --home "$DEVICE_HOME" \
    --seed "$ROOT/.shots/demo.db" \
    --out "$ROOT/.shots/phone-demo.db"
fi

if [ "$DO_PUSH" = 1 ]; then
  say "== push media + database to the emulator"
  tar -C "$ROOT/.shots/demo_media" -cf /tmp/jawnos-android-media.tar Pictures Music Documents
  scp -q -P "$TABLE_SSH" /tmp/jawnos-android-media.tar "$TABLE:/tmp/jawnos-android-media.tar"
  scp -q -P "$TABLE_SSH" "$ROOT/.shots/phone-demo.db" "$TABLE:/tmp/phone-demo.db"

  APP_UID=$(ssh -o BatchMode=yes -p "$TABLE_SSH" "$TABLE" \
    "export PATH=\$HOME/android-sdk/platform-tools:\$PATH; $ADB shell stat -c %u $DEVICE_HOME" | tr -d '\r')
  [ -n "$APP_UID" ] || { echo "android.sh: could not read the app's uid" >&2; exit 1; }

  ssh -o BatchMode=yes -p "$TABLE_SSH" "$TABLE" \
    "export PATH=\$HOME/android-sdk/platform-tools:\$PATH
     $ADB push /tmp/jawnos-android-media.tar /data/local/tmp/ >/dev/null
     $ADB push /tmp/phone-demo.db /data/local/tmp/ >/dev/null
     $ADB shell \"cd $DEVICE_HOME && tar -xf /data/local/tmp/jawnos-android-media.tar && chown -R $APP_UID:$APP_UID Pictures Music Documents\"" \
    >/dev/null

  # Stop, swap the database, start. The dashboard is the app's own control
  # surface; its Start/Stop buttons sit in the first row at 1080x2400.
  adb shell am start -n "$APP_PACKAGE/.app.JawnDashboardActivity" >/dev/null 2>&1 || true
  sleep 3
  adb shell input tap 630 1167 >/dev/null 2>&1 || true
  sleep 4
  emu <<'REMOTE'
export HOME=/data/data/com.termux/files/home
export PREFIX=/data/data/com.termux/files/usr
export PATH=$PREFIX/bin:/system/bin
cd "$HOME/jawnos" || exit 1
cp -f /data/local/tmp/phone-demo.db database/jawnos.db
chmod 600 database/jawnos.db
rm -f database/jawnos.db-wal database/jawnos.db-shm
REMOTE
  emu <<'REMOTE'
export HOME=/data/data/com.termux/files/home
export PREFIX=/data/data/com.termux/files/usr
export PATH=$PREFIX/bin:/system/bin
cd "$HOME/jawnos" || exit 1
perl -MJSON::PP -0777 -i -pe 'my $d = decode_json($_); $d->{live} = JSON::PP::true; $_ = encode_json($d)' config.json 2>/dev/null || true
REMOTE
  adb shell input tap 189 1167 >/dev/null 2>&1 || true
  say "  waiting for the manager"
  i=0
  while [ $i -lt 60 ]; do
    if emu <<'REMOTE' 2>/dev/null | grep -q 'manager=200'
export HOME=/data/data/com.termux/files/home
export PREFIX=/data/data/com.termux/files/usr
export PATH=$PREFIX/bin:/system/bin
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 2 https://127.0.0.1:45545/manager 2>/dev/null || true)
echo "manager=$code"
REMOTE
    then break; fi
    i=$((i+1)); sleep 1
  done
  [ $i -ge 60 ] && { echo "android.sh: the manager did not come up" >&2; exit 1; }
  say "  manager is up"
fi

# ----------------------------------------------------------------- shoot ----
if [ "$DO_SHOOT" = 1 ]; then
  say "== capture the phone screens"
  mkdir -p "$OUT"
  python3 - "$ROOT/scripts/gallery/android-scenes.json" <<'PY' > /tmp/jawnos-android-scenes.txt
import json, sys
m = json.load(open(sys.argv[1]))
for s in m['scenes']:
    print(s['id'], s.get('activity', ''), s.get('app', ''), s['file'], sep='|')
PY

  while IFS='|' read -r id activity app file <&3; do
    [ -n "$ONLY" ] && [ "$ONLY" != "$id" ] && continue
    say "  $id"
    if [ "$activity" = "home" ]; then
      adb shell am start -n "$APP_PACKAGE/.app.JawnHomeActivity" >/dev/null 2>&1 || true
      sleep 6
      adb shell uiautomator dump /sdcard/jawn-ui.xml >/dev/null 2>&1 || true
      adb pull /sdcard/jawn-ui.xml /tmp/jawn-ui.xml >/dev/null 2>&1 || true
      if grep -q "not your Home screen" /tmp/jawn-ui.xml 2>/dev/null; then
        adb shell input tap 870 630 >/dev/null 2>&1 || true
        sleep 2
      fi
    else
      adb shell am start -n "$APP_PACKAGE/.app.JawnAppActivity" \
        --activity-clear-task --es app "$app" >/dev/null 2>&1 || true
      sleep 14
    fi
    adb shell screencap -p "/sdcard/$file.png" >/dev/null
    adb pull "/sdcard/$file.png" "/tmp/$file.png" >/dev/null
    adb shell rm "/sdcard/$file.png" >/dev/null 2>&1 || true
    scp -q -P "$TABLE_SSH" "$TABLE:/tmp/$file.png" "$OUT/$file.png"
  done 3< /tmp/jawnos-android-scenes.txt
  say "  captures in $OUT"
fi

# --------------------------------------------------------------- publish ----
if [ "$DO_PUBLISH" = 1 ]; then
  say "== publish the phone section"
  set -- --shots "$OUT" --site "$SITE"
  [ -n "$DEPLOY" ] && set -- "$@" --deploy "$DEPLOY"
  python3 "$ROOT/scripts/gallery/android_publish.py" "$@"
fi
